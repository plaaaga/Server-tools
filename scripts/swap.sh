#!/usr/bin/env bash
# ======================================================
#  🧊 Universal SWAP Manager
#  Универсальный скрипт для управления swap-файлом на Ubuntu/Debian
#  Автор: Plaga совместно с ChatGPT
#  Цели:
#  - показать текущую систему (CPU, RAM, диск, swap)
#  - создать / пересоздать swap-файл с опциями по умолчанию или пользовательскими
#  - сохранить vm.swappiness и vm.vfs_cache_pressure в /etc/sysctl.d/99-swap-tuning.conf
#  - аккуратно работать с /etc/fstab (добавлять/удалять запись про swap-файл)
#  - предупреждать про btrfs и swap-разделы
# ======================================================

set -o errexit
set -o nounset
set -o pipefail
IFS=$'\n\t'

SWAPFILE="/swapfile"
SYSCTL_CONF="/etc/sysctl.d/99-swap-tuning.conf"
DEFAULT_SWAPPINESS=10
DEFAULT_VFS=50

#########################
# Логирование
#########################
_info() { printf "[INFO] %s\n" "$*"; }
_warn() { printf "[WARN] %s\n" "$*"; }
_err() { printf "[ERROR] %s\n" "$*" >&2; }

#########################
# Проверки окружения
#########################
require_root() {
  if [[ $EUID -ne 0 ]]; then
    _err "Этот скрипт должен быть запущен от root (или sudo)."
    exit 1
  fi
}

require_commands() {
  local miss=()
  for cmd in awk df swapon swapoff mkswap dd sed grep findmnt sysctl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      miss+=("$cmd")
    fi
  done
  if ((${#miss[@]} > 0)); then
    _err "Не найдены нужные команды: ${miss[*]}. Установите их и повторите."
    exit 1
  fi
}

#########################
# Утилиты
#########################
human_size() {
  # принимает байты (integer), выводит человекочитаемо
  local bytes=${1:-0}
  # если не число, вернуть 0B
  if ! [[ "$bytes" =~ ^[0-9]+$ ]]; then
    printf "0B"
    return
  fi
  if (( bytes >= 1073741824 )); then
    awk -v b="$bytes" 'BEGIN{printf "%.2fG", b/1073741824}'
  elif (( bytes >= 1048576 )); then
    awk -v b="$bytes" 'BEGIN{printf "%.2fM", b/1048576}'
  elif (( bytes >= 1024 )); then
    awk -v b="$bytes" 'BEGIN{printf "%.2fK", b/1024}'
  else
    printf "%dB" "$bytes"
  fi
}

#########################
# Информация о системе
#########################
print_system_info() {
  echo "================= System info ================="
  echo "Kernel: $(uname -sr)"
  echo "Uptime: $(uptime -p 2>/dev/null || true)"
  echo "CPU: $(awk -F: '/model name/ {print $2; exit}' /proc/cpuinfo | sed 's/^ *//')"
  echo "Cores: $(nproc --all)"

  local mem_total_bytes
  mem_total_bytes=$(awk '/MemTotal/ {print $2*1024; exit}' /proc/meminfo || echo 0)
  echo "RAM: $(human_size "$mem_total_bytes")"

  local root_avail_bytes
  root_avail_bytes=$(df --output=avail -B1 / | tail -n1 2>/dev/null || echo 0)
  echo "Root FS available: $(human_size "$root_avail_bytes")"

  echo "Disk usage:"
  df -h --output=source,size,used,avail,target | sed '1d' || true
  echo
  echo "Swap currently active:"
  swapon --show --bytes || true
  echo "vm.swappiness: $(cat /proc/sys/vm/swappiness 2>/dev/null || echo 'N/A')"
  echo "vm.vfs_cache_pressure: $(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null || echo 'N/A')"
  echo "================================================"
}

#########################
# Проверки swap/fs
#########################
any_swap_active() {
  if swapon --noheadings --show=NAME --bytes | grep -q .; then
    return 0
  fi
  return 1
}

swapfile_active() {
  if swapon --noheadings --show=NAME | awk '{print $1}' | grep -Fxq "$SWAPFILE"; then
    return 0
  fi
  return 1
}

fstype_of_root() {
  findmnt -n -o FSTYPE / || true
}

check_btrfs_warn() {
  local fstype
  fstype=$(fstype_of_root)
  if [[ "$fstype" == "btrfs" ]]; then
    _warn "Файловая система корня: btrfs. Swap-файлы на btrfs могут работать некорректно (нужны специальные опции)."
    read -rp "Продолжить создание swap-файла на btrfs? (y/N): " ans
    [[ "$ans" =~ ^[Yy] ]] || { _info "Отмена по выбору пользователя."; exit 1; }
  fi
}

#########################
# Управление /etc/fstab
#########################
ensure_fstab_entry() {
  local entry="$SWAPFILE none swap sw 0 0"
  if grep -Fq "$SWAPFILE" /etc/fstab 2>/dev/null; then
    _info "Запись для $SWAPFILE уже есть в /etc/fstab"
  else
    echo "$entry" >> /etc/fstab
    _info "Добавлена запись $SWAPFILE в /etc/fstab"
  fi
}

remove_fstab_entry() {
  if grep -Fq "$SWAPFILE" /etc/fstab 2>/dev/null; then
    # используем \| как ограничитель, чтобы корректно обработать слэши в пути
    sed -i.bak "\|$SWAPFILE|d" /etc/fstab || true
    _info "Удалена запись о $SWAPFILE из /etc/fstab (backup: /etc/fstab.bak)"
  fi
}

#########################
# sysctl
#########################
apply_sysctl_and_save() {
  local sw="$1" vfs="$2"
  # валидация чисел
  if ! [[ "$sw" =~ ^[0-9]+$ ]] || (( sw < 0 || sw > 100 )); then
    _err "Неправильное значение swappiness: $sw"
    return 1
  fi
  if ! [[ "$vfs" =~ ^[0-9]+$ ]]; then
    _err "Неправильное значение vfs_cache_pressure: $vfs"
    return 1
  fi

  cat > "$SYSCTL_CONF" <<EOF
# Автоматически создано скриптом swap.sh
vm.swappiness = $sw
vm.vfs_cache_pressure = $vfs
EOF

  if command -v sysctl >/dev/null 2>&1; then
    sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1 || true
  fi
  _info "Записаны и применены sysctl: vm.swappiness=$sw vm.vfs_cache_pressure=$vfs"
}

#########################
# Создание swap
#########################
create_swap_file() {
  local size_gb=$1
  check_btrfs_warn

  local avail_bytes
  avail_bytes=$(df --output=avail -B1 / | tail -n1 || echo 0)
  local need_bytes=$(( size_gb * 1024 * 1024 * 1024 ))
  if (( avail_bytes < need_bytes )); then
    _err "На корневом разделе недостаточно места: нужно $(human_size "$need_bytes"), доступно $(human_size "$avail_bytes")."
    return 1
  fi

  local tmpfile="${SWAPFILE}.tmp.$$"
  if [[ -f "$SWAPFILE" ]]; then
    _warn "$SWAPFILE уже существует. Будет перезаписан (если вы подтвердите)."
  fi

  _info "Создаю swap-файл ($size_gb GB) — это может занять время..."
  dd if=/dev/zero of="$tmpfile" bs=1M count=$(( size_gb * 1024 )) conv=fsync status=progress || {
    _err "dd не удался"
    rm -f "$tmpfile" || true
    return 1
  }
  chmod 600 "$tmpfile"
  mkswap "$tmpfile" || { _err "mkswap не удался"; rm -f "$tmpfile"; return 1; }

  if swapfile_active; then
    _info "Отключаю существующий swap-файл $SWAPFILE"
    swapoff "$SWAPFILE" || { _warn "Не удалось отключить $SWAPFILE, продолжаю"; }
  fi

  mv -f "$tmpfile" "$SWAPFILE"
  chmod 600 "$SWAPFILE"

  if ! swapon "$SWAPFILE" 2>/dev/null; then
    _err "Не удалось активировать $SWAPFILE как swap"
    rm -f "$SWAPFILE"
    return 1
  fi

  if ! swapfile_active; then
    _err "$SWAPFILE не появился в swapon --show"
    rm -f "$SWAPFILE"
    return 1
  fi

  ensure_fstab_entry
  _info "Swap-файл $SWAPFILE создан и активирован"
  return 0
}

remove_swap_file() {
  if swapfile_active; then
    _info "Отключаю swap-файл $SWAPFILE"
    swapoff "$SWAPFILE" || { _warn "Не удалось отключить $SWAPFILE"; }
  fi
  if [[ -f "$SWAPFILE" ]]; then
    rm -f "$SWAPFILE"
    _info "$SWAPFILE удалён"
  else
    _info "Файл $SWAPFILE не найден, ничего не удаляю"
  fi
  remove_fstab_entry
}

#########################
# Помощь: рекомендованный размер swap
#########################
suggest_swap_size_gb() {
  local mem_kb
  mem_kb=$(awk '/MemTotal/ {print $2; exit}' /proc/meminfo || echo 0)
  local mem_gb=$(( mem_kb / 1024 / 1024 ))
  if (( mem_gb <= 2 )); then
    echo 2
  elif (( mem_gb <= 8 )); then
    echo "$mem_gb"
  else
    echo 4
  fi
}

#########################
# Вспомогательные валидации
#########################
read_positive_int() {
  local prompt="$1"
  local value
  while true; do
    read -rp "$prompt" value
    if [[ -z "$value" ]]; then
      echo ""
      return 0
    fi
    if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 0 )); then
      echo "$value"
      return 0
    fi
    echo "Введите целое неотрицательное число."
  done
}

read_sw_vfs() {
  local sw vfs
  sw=$(read_positive_int "swappiness (0-100): ")
  if [[ -z "$sw" ]]; then sw=$DEFAULT_SWAPPINESS; fi
  if ! [[ "$sw" =~ ^[0-9]+$ ]] || (( sw < 0 || sw > 100 )); then
    _err "swappiness должно быть числом 0-100"
    return 1
  fi
  vfs=$(read_positive_int "vfs_cache_pressure (обычно 1-200): ")
  if [[ -z "$vfs" ]]; then vfs=$DEFAULT_VFS; fi
  if ! [[ "$vfs" =~ ^[0-9]+$ ]]; then
    _err "vfs_cache_pressure должно быть числом"
    return 1
  fi
  printf "%s %s" "$sw" "$vfs"
  return 0
}

#########################
# Меню
#########################
menu_no_swap() {
  echo "На системе не найден активный swap. Что сделать?"
  select opt in "Создать swap с оптимальными настройками" "Создать swap с моими настройками" "Выход"; do
    case $REPLY in
      1)
        local size_gb
        size_gb=$(suggest_swap_size_gb)
        read -rp "Размер swap в ГБ (рекомендуется $size_gb GB): " input_sz
        input_sz=${input_sz:-$size_gb}
        if ! [[ $input_sz =~ ^[0-9]+$ ]]; then _err "Неправильный ввод"; return 1; fi
        create_swap_file "$input_sz" || return 1
        apply_sysctl_and_save "$DEFAULT_SWAPPINESS" "$DEFAULT_VFS"
        break
        ;;
      2)
        read -rp "Размер swap в ГБ: " sz
        if ! [[ $sz =~ ^[0-9]+$ ]]; then _err "Неправильный ввод"; return 1; fi
        read -rp "swappiness (0-100): " sw
        read -rp "vfs_cache_pressure (обычно 1-200): " vfs
        if ! [[ "$sw" =~ ^[0-9]+$ ]] || (( sw < 0 || sw > 100 )); then _err "Неправильный swappiness"; return 1; fi
        if ! [[ "$vfs" =~ ^[0-9]+$ ]]; then _err "Неправильный vfs_cache_pressure"; return 1; fi
        create_swap_file "$sz" || return 1
        apply_sysctl_and_save "$sw" "$vfs"
        break
        ;;
      3)
        _info "Выход"
        exit 0
        ;;
      *) echo "Выберите 1-3";;
    esac
  done
}

menu_with_swap() {
  echo "На системе найден активный swap (файл или раздел)."
  echo "Детали:"
  swapon --show --bytes
  PS3="Выберите действие: "
  select opt in "Оставить существующий swap" "Изменить настройки swappiness/vfs_cache_pressure" "Пересоздать swap-файл (удалить существующий swap-файл и создать новый)" "Выход"; do
    case $REPLY in
      1)
        _info "Ничего не делаю"
        break
        ;;
      2)
        echo "Выберите:"
        select sopt in "Использовать оптимальные ($DEFAULT_SWAPPINESS/$DEFAULT_VFS)" "Задать вручную" "Назад"; do
          case $REPLY in
            1)
              apply_sysctl_and_save "$DEFAULT_SWAPPINESS" "$DEFAULT_VFS"; break 2
              ;;
            2)
              read -rp "swappiness (0-100): " sw
              read -rp "vfs_cache_pressure: " vfs
              if ! [[ "$sw" =~ ^[0-9]+$ ]] || (( sw < 0 || sw > 100 )); then _err "Неправильный swappiness"; break; fi
              if ! [[ "$vfs" =~ ^[0-9]+$ ]]; then _err "Неправильный vfs_cache_pressure"; break; fi
              apply_sysctl_and_save "$sw" "$vfs"; break 2
              ;;
            3) break; ;;
            *) echo "Выберите 1-3";;
          esac
        done
        ;;
      3)
        if any_swap_active && ! swapfile_active; then
          _warn "На системе активен swap но он не является файлом (возможно это раздел)."
          read -rp "Вы хотите отключить существующий swap и создать swap-файл вместо него? (y/N): " ans
          if [[ ! "$ans" =~ ^[Yy]$ ]]; then
            _info "Отмена пересоздания."; break
          fi
        fi
        read -rp "Размер нового swap в ГБ (рекомендуется $(suggest_swap_size_gb) ): " new_sz
        if ! [[ $new_sz =~ ^[0-9]+$ ]]; then _err "Неправильный ввод"; return 1; fi
        if swapfile_active || [[ -f "$SWAPFILE" ]]; then
          _info "Отключаю и удаляю старый swap-файл (если есть)"
          remove_swap_file || _warn "Не удалось полностью удалить старый swap-файл"
        fi
        create_swap_file "$new_sz" || { _err "Не удалось создать новый swap"; return 1; }
        echo "Применить оптимальные sysctl настройки?"
        select a in "Да" "Нет, задан вручную"; do
          case $REPLY in
            1) apply_sysctl_and_save "$DEFAULT_SWAPPINESS" "$DEFAULT_VFS"; break;;
            2)
              read -rp "swappiness: " sw
              read -rp "vfs_cache_pressure: " vfs
              if ! [[ "$sw" =~ ^[0-9]+$ ]] || (( sw < 0 || sw > 100 )); then _err "Неправильный swappiness"; break; fi
              if ! [[ "$vfs" =~ ^[0-9]+$ ]]; then _err "Неправильный vfs_cache_pressure"; break; fi
              apply_sysctl_and_save "$sw" "$vfs"; break;;
            *) echo "Выберите 1-2";;
          esac
        done
        break
        ;;
      4)
        _info "Выход"
        exit 0
        ;;
      *) echo "Выберите 1-4";;
    esac
  done
}

#########################
# main
#########################
main() {
  require_root
  require_commands
  print_system_info

  if any_swap_active; then
    menu_with_swap
  else
    menu_no_swap
  fi

  _info "Операция завершена. Текущий swap:"
  swapon --show --bytes || true
  _info "Текущие параметры: vm.swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo N/A), vm.vfs_cache_pressure=$(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null || echo N/A)"
}

main "$@"
