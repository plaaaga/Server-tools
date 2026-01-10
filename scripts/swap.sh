#!/usr/bin/env bash
# ======================================================
# Universal SWAP Manager (Ubuntu/Debian)
# Автор: plaga + ChatGPT
# - create/recreate swapfile
# - tune vm.swappiness / vm.vfs_cache_pressure
# ======================================================

set -Eeuo pipefail
IFS=$'\n\t'

SWAPFILE_DEFAULT="/swapfile"
SYSCTL_CONF="/etc/sysctl.d/99-swap-tuning.conf"

DEFAULT_SWAPPINESS=10
DEFAULT_VFS=50

# -------------------------
# logging / ui
# -------------------------
info() { printf "[INFO] %s\n" "$*"; }
warn() { printf "[WARN] %s\n" "$*"; }
err()  { printf "[ERROR] %s\n" "$*" >&2; }

pause_and_clear() {
  echo
  read -r -p "Нажмите Enter, чтобы очистить экран и продолжить..." _
  clear || true
}

require_root() {
  if [[ ${EUID:-1000} -ne 0 ]]; then
    err "Скрипт должен быть запущен от root (sudo)."
    exit 1
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

human_size() {
  local bytes="${1:-0}"
  if have_cmd numfmt; then
    numfmt --to=iec --suffix=B "$bytes"
  else
    # fallback: rough
    awk -v b="$bytes" 'BEGIN{
      split("B K M G T P",u," ");
      for(i=1;b>=1024 && i<6;i++) b/=1024;
      printf "%.2f%s", b, u[i];
    }'
  fi
}

# -------------------------
# system info
# -------------------------
get_mem_kb() { awk '/MemTotal/ {print $2; exit}' /proc/meminfo; }
get_root_fstype() { findmnt -n -o FSTYPE / 2>/dev/null || echo "unknown"; }

print_system_info() {
  local mem_kb mem_bytes avail_bytes
  mem_kb="$(get_mem_kb)"
  mem_bytes=$(( mem_kb * 1024 ))
  avail_bytes="$(df --output=avail -B1 / | tail -n1 | tr -d ' ')"

  echo "================= System info ================="
  echo "Kernel: $(uname -sr)"
  echo "Uptime: $(uptime -p 2>/dev/null || true)"
  echo "CPU: $(awk -F: '/model name/ {gsub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo)"
  echo "Cores: $(nproc --all 2>/dev/null || echo N/A)"
  echo "RAM: $(human_size "$mem_bytes")"
  echo "Root FS: $(get_root_fstype)"
  echo "Root FS available: $(human_size "$avail_bytes")"
  echo
  echo "Disk usage:"
  df -h --output=source,fstype,size,used,avail,target | sed '1d' || true
  echo
  echo "Swap currently active:"
  swapon --show --bytes || true
  echo
  echo "vm.swappiness: $(cat /proc/sys/vm/swappiness 2>/dev/null || echo N/A)"
  echo "vm.vfs_cache_pressure: $(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null || echo N/A)"
  echo "================================================"
}

# -------------------------
# swap detection
# -------------------------
any_swap_active() {
  swapon --noheadings --show=NAME 2>/dev/null | grep -q .
}

swapfile_active() {
  local swapfile="$1"
  swapon --noheadings --show=NAME 2>/dev/null | awk '{print $1}' | grep -Fxq "$swapfile"
}

# -------------------------
# explanations
# -------------------------
print_optimal_explanation() {
  cat <<EOF

Почему эти значения часто подходят для нод:

- swap по RAM:
  * если RAM ≤ 2 ГБ  → swap = RAM × 2
  * если RAM 2–8 ГБ → swap = RAM
  * если RAM > 8 ГБ → swap = RAM / 2
  Логика: на маленькой RAM swap нужен как "подушка", на большой — слишком большой swap увеличивает риск долгих I/O пауз.

- vm.swappiness=10:
  меньше агрессии свапа → меньше дискового I/O и задержек. Swap остаётся как страховка.

- vm.vfs_cache_pressure=50:
  ядро чуть дольше держит inode/dentry кэш, что часто полезно для workloads с частыми обращениями к файлам/БД.

EOF
}

print_tuning_hint() {
  cat <<EOF

Подсказка по параметрам:
- swappiness: 0..200
  ниже  → реже уходим в swap
  выше  → активнее используем swap
  для нод часто ставят 10

- vfs_cache_pressure: обычно 1..200 (можно выше)
  ниже  → держим inode/dentry кэш дольше
  выше  → быстрее выкидываем этот кэш
  для нод часто ставят 50

EOF
}

# -------------------------
# recommended swap size (your algorithm)
# -------------------------
recommended_swap_gb() {
  # compute in MiB to avoid decimals
  local mem_kb mem_mib swap_mib gb
  mem_kb="$(get_mem_kb)"
  mem_mib=$(( mem_kb / 1024 ))

  if (( mem_mib <= 2048 )); then
    swap_mib=$(( mem_mib * 2 ))
  elif (( mem_mib <= 8192 )); then
    swap_mib=$(( mem_mib ))
  else
    swap_mib=$(( mem_mib / 2 ))
  fi

  # round up to full GiB (MiB/1024)
  gb=$(( (swap_mib + 1023) / 1024 ))
  (( gb < 1 )) && gb=1
  echo "$gb"
}

# -------------------------
# validate input
# -------------------------
is_int() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

validate_range() {
  local name="$1" val="$2" min="$3" max="$4"
  if ! is_int "$val"; then
    err "$name: нужно целое число."
    return 1
  fi
  if (( val < min || val > max )); then
    err "$name: должно быть в диапазоне $min..$max."
    return 1
  fi
}

# -------------------------
# fstab management (safe)
# -------------------------
fstab_remove_swapfile_line() {
  local swapfile="$1"
  [[ -f /etc/fstab ]] || return 0

  # rewrite fstab without lines containing exact swapfile path
  awk -v sf="$swapfile" '
    BEGIN { removed=0 }
    {
      if ($0 ~ "^[[:space:]]*#") { print; next }
      # match first field exactly == swapfile
      if ($1 == sf && $3 == "swap") { removed=1; next }
      print
    }
    END { }
  ' /etc/fstab > /etc/fstab.swapsh.tmp

  cp -a /etc/fstab "/etc/fstab.bak.swapsh.$(date +%s)" 2>/dev/null || true
  cat /etc/fstab.swapsh.tmp > /etc/fstab
  rm -f /etc/fstab.swapsh.tmp
}

fstab_ensure_swapfile_line() {
  local swapfile="$1"
  fstab_remove_swapfile_line "$swapfile"
  echo "$swapfile none swap sw 0 0" >> /etc/fstab
}

# -------------------------
# sysctl
# -------------------------
apply_sysctl_and_save() {
  local sw="$1" vfs="$2"

  validate_range "swappiness" "$sw" 0 200
  validate_range "vfs_cache_pressure" "$vfs" 1 1000

  cat > "$SYSCTL_CONF" <<EOF
# written by swap.sh
vm.swappiness=$sw
vm.vfs_cache_pressure=$vfs
EOF

  # apply only this file
  sysctl -p "$SYSCTL_CONF" >/dev/null || true

  info "Применено: vm.swappiness=$sw, vm.vfs_cache_pressure=$vfs"
  info "Сохранено в: $SYSCTL_CONF"
}

# -------------------------
# create/remove swapfile
# -------------------------
btrfs_warn_or_exit() {
  local fstype
  fstype="$(get_root_fstype)"
  if [[ "$fstype" == "btrfs" ]]; then
    warn "Корневая FS: btrfs."
    warn "Swapfile на btrfs требует специальных условий (NOCOW/без compression и др.)."
    warn "Если не уверен — лучше использовать swap-раздел или другой FS."
    echo
    read -r -p "Продолжить создание swapfile на btrfs? (y/N): " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { info "Отмена."; exit 0; }
  fi
}

create_swapfile() {
  local swapfile="$1" size_gb="$2"

  if ! is_int "$size_gb" || (( size_gb < 1 )); then
    err "Размер swap должен быть целым числом >= 1 (в ГБ)."
    return 1
  fi

  btrfs_warn_or_exit

  local avail_bytes need_bytes
  avail_bytes="$(df --output=avail -B1 "$(dirname "$swapfile")" 2>/dev/null | tail -n1 | tr -d ' ')"
  need_bytes=$(( size_gb * 1024 * 1024 * 1024 ))

  if (( avail_bytes < need_bytes )); then
    err "Недостаточно места: нужно $(human_size "$need_bytes"), доступно $(human_size "$avail_bytes")."
    return 1
  fi

  local tmp="${swapfile}.tmp.$$"
  rm -f "$tmp" 2>/dev/null || true

  info "Создаю swapfile: $swapfile (${size_gb}G)"

  # allocate
  if have_cmd fallocate; then
    if ! fallocate -l "${size_gb}G" "$tmp" 2>/dev/null; then
      warn "fallocate не сработал, использую dd."
      dd if=/dev/zero of="$tmp" bs=1M count=$(( size_gb * 1024 )) conv=fsync status=progress
    fi
  else
    dd if=/dev/zero of="$tmp" bs=1M count=$(( size_gb * 1024 )) conv=fsync status=progress
  fi

  chmod 600 "$tmp"
  mkswap "$tmp" >/dev/null

  if swapfile_active "$swapfile"; then
    info "Отключаю активный swapfile: $swapfile"
    swapoff "$swapfile" || true
  fi

  mv -f "$tmp" "$swapfile"
  chmod 600 "$swapfile"

  swapon "$swapfile"

  # persist
  fstab_ensure_swapfile_line "$swapfile"

  info "Swapfile создан и активирован."
}

remove_swapfile() {
  local swapfile="$1"

  if swapfile_active "$swapfile"; then
    info "Отключаю swapfile: $swapfile"
    swapoff "$swapfile" || true
  fi

  if [[ -f "$swapfile" ]]; then
    rm -f "$swapfile"
    info "Удалён файл: $swapfile"
  else
    info "Файл $swapfile не найден."
  fi

  fstab_remove_swapfile_line "$swapfile"
  info "Запись в /etc/fstab для $swapfile (если была) удалена."
}

# -------------------------
# menus
# -------------------------
menu_no_swap() {
  local swapfile="$SWAPFILE_DEFAULT"
  while true; do
    echo "Swap не найден."
    echo
    echo "1) Создать swapfile с оптимальными настройками для нод (рекомендуется)"
    echo "2) Создать swapfile со своими настройками"
    echo "3) Выход"
    echo
    read -r -p "Выбор [1-3]: " c
    case "$c" in
      1)
        local rec_gb
        rec_gb="$(recommended_swap_gb)"

        print_optimal_explanation
        echo "Будет создано:"
        echo "  swapfile: $swapfile"
        echo "  размер:   ${rec_gb}G (по формуле от RAM)"
        echo "  swappiness=$DEFAULT_SWAPPINESS"
        echo "  vfs_cache_pressure=$DEFAULT_VFS"
        echo
        read -r -p "Нажмите Enter для продолжения..." _
        create_swapfile "$swapfile" "$rec_gb"
        apply_sysctl_and_save "$DEFAULT_SWAPPINESS" "$DEFAULT_VFS"
        echo
        info "Готово. Текущий swap:"
        swapon --show --bytes || true
        pause_and_clear
        return 0
        ;;
      2)
        local rec_gb sz sw vfs
        rec_gb="$(recommended_swap_gb)"
        print_tuning_hint
        echo "Рекомендуемый размер swap по RAM: ${rec_gb}G"
        echo
        read -r -p "Размер swap (ГБ) [по умолчанию ${rec_gb}]: " sz
        sz="${sz:-$rec_gb}"

        if ! is_int "$sz" || (( sz < 1 )); then
          err "Неверный размер swap."
          pause_and_clear
          continue
        fi

        read -r -p "swappiness [рекомендуется $DEFAULT_SWAPPINESS]: " sw
        sw="${sw:-$DEFAULT_SWAPPINESS}"

        read -r -p "vfs_cache_pressure [рекомендуется $DEFAULT_VFS]: " vfs
        vfs="${vfs:-$DEFAULT_VFS}"

        create_swapfile "$swapfile" "$sz"
        apply_sysctl_and_save "$sw" "$vfs"

        echo
        info "Swapfile успешно создан. Текущий swap:"
        swapon --show --bytes || true
        pause_and_clear
        return 0
        ;;
      3)
        clear || true
        exit 0
        ;;
      *)
        echo "Нужно выбрать 1-3."
        ;;
    esac
  done
}

menu_with_swap() {
  local swapfile="$SWAPFILE_DEFAULT"

  while true; do
    echo "Swap обнаружен."
    echo
    echo "Текущие значения:"
    swapon --show --bytes || true
    echo "vm.swappiness: $(cat /proc/sys/vm/swappiness 2>/dev/null || echo N/A)"
    echo "vm.vfs_cache_pressure: $(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null || echo N/A)"
    echo
    echo "1) Оставить существующий swap без изменений"
    echo "2) Применить оптимальные swappiness/vfs_cache_pressure (10/50)"
    echo "3) Изменить swappiness/vfs_cache_pressure вручную"
    echo "4) Пересоздать swapfile (удалить swapfile и создать заново)"
    echo "5) Выход"
    echo
    read -r -p "Выбор [1-5]: " c

    case "$c" in
      1)
        info "Оставляю как есть."
        pause_and_clear
        return 0
        ;;
      2)
        print_optimal_explanation
        apply_sysctl_and_save "$DEFAULT_SWAPPINESS" "$DEFAULT_VFS"
        pause_and_clear
        return 0
        ;;
      3)
        local sw vfs
        print_tuning_hint
        read -r -p "swappiness [рекомендуется $DEFAULT_SWAPPINESS]: " sw
        sw="${sw:-$DEFAULT_SWAPPINESS}"
        read -r -p "vfs_cache_pressure [рекомендуется $DEFAULT_VFS]: " vfs
        vfs="${vfs:-$DEFAULT_VFS}"
        apply_sysctl_and_save "$sw" "$vfs"
        pause_and_clear
        return 0
        ;;
      4)
        warn "Важно: скрипт гарантированно удаляет/пересоздаёт только swapfile по пути $swapfile."
        warn "Если у вас активен swap-раздел, он останется, если вы не отключите его вручную."
        echo
        read -r -p "Продолжить пересоздание swapfile? (y/N): " ans
        [[ "$ans" =~ ^[Yy]$ ]] || { info "Отмена."; pause_and_clear; continue; }

        remove_swapfile "$swapfile"

        # дальше как "нет swap"
        local rec_gb new_sz
        rec_gb="$(recommended_swap_gb)"
        print_optimal_explanation
        read -r -p "Размер нового swap (ГБ) [рекомендуется ${rec_gb}]: " new_sz
        new_sz="${new_sz:-$rec_gb}"
        if ! is_int "$new_sz" || (( new_sz < 1 )); then
          err "Неверный размер."
          pause_and_clear
          continue
        fi

        create_swapfile "$swapfile" "$new_sz"

        echo
        echo "Применить оптимальные sysctl (10/50)?"
        echo "1) Да"
        echo "2) Нет, задам вручную"
        read -r -p "Выбор [1-2]: " sc
        case "$sc" in
          1) apply_sysctl_and_save "$DEFAULT_SWAPPINESS" "$DEFAULT_VFS" ;;
          2)
            local sw vfs
            print_tuning_hint
            read -r -p "swappiness [рекомендуется $DEFAULT_SWAPPINESS]: " sw
            sw="${sw:-$DEFAULT_SWAPPINESS}"
            read -r -p "vfs_cache_pressure [рекомендуется $DEFAULT_VFS]: " vfs
            vfs="${vfs:-$DEFAULT_VFS}"
            apply_sysctl_and_save "$sw" "$vfs"
            ;;
          *) warn "Не понял выбор, оставляю как есть." ;;
        esac

        info "Готово. Текущий swap:"
        swapon --show --bytes || true
        pause_and_clear
        return 0
        ;;
      5)
        clear || true
        exit 0
        ;;
      *)
        echo "Нужно выбрать 1-5."
        ;;
    esac
  done
}

# -------------------------
# main
# -------------------------
main() {
  require_root
  clear || true
  print_system_info
  echo
  read -r -p "Нажмите Enter для продолжения..." _
  clear || true

  if any_swap_active; then
    menu_with_swap
  else
    menu_no_swap
  fi

  info "Операция завершена."
}

main "$@"
