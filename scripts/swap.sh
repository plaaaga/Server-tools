#!/usr/bin/env bash
# ======================================================
# Swap Manager for Ubuntu/Debian (под ноды)
# - создание/пересоздание swapfile
# - настройка vm.swappiness / vm.vfs_cache_pressure
# - красивый интерфейс (цвета/баннер/меню)
# ======================================================

set -Eeuo pipefail
IFS=$'\n\t'

# -------------------------
# Defaults
# -------------------------
SWAPFILE_DEFAULT="/swapfile"
SYSCTL_CONF="/etc/sysctl.d/99-swap-tuning.conf"

DEFAULT_SWAPPINESS=10
DEFAULT_VFS=50

# -------------------------
# UI / Colors
# -------------------------
is_tty() { [[ -t 1 ]]; }

supports_color() {
  # уважаем стандарт NO_COLOR
  [[ -n "${NO_COLOR:-}" ]] && return 1

  # принудительное включение цветов
  [[ "${FORCE_COLOR:-0}" == "1" ]] && return 0

  is_tty || return 1
  [[ -n "${TERM:-}" && "${TERM:-}" != "dumb" ]] || return 1

  # если есть tput — проверим, что цветов хватает
  if command -v tput >/dev/null 2>&1; then
    local n
    n="$(tput colors 2>/dev/null || echo 0)"
    [[ "$n" -ge 8 ]] || return 1
  fi

  return 0
}

if supports_color; then
  C_RESET=$'\e[0m'
  C_BOLD=$'\e[1m'
  C_DIM=$'\e[2m'
  C_RED=$'\e[31m'
  C_GREEN=$'\e[32m'
  C_YELLOW=$'\e[33m'
  C_BLUE=$'\e[34m'
  C_MAGENTA=$'\e[35m'
  C_CYAN=$'\e[36m'
  C_GRAY=$'\e[90m'
else
  C_RESET="" C_BOLD="" C_DIM=""
  C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_MAGENTA="" C_CYAN="" C_GRAY=""
fi

supports_utf8() {
  local loc="${LC_ALL:-${LANG:-}}"
  [[ "$loc" == *"UTF-8"* || "$loc" == *"utf8"* ]]
}

if supports_utf8; then
  I_OK="✔"
  I_WARN="⚠"
  I_ERR="✖"
else
  I_OK="OK"
  I_WARN="!"
  I_ERR="X"
fi

ui_hr() { printf "%b\n" "${C_DIM}------------------------------------------------------------${C_RESET}"; }

ui_title() {
  ui_hr
  printf "%b%s%b\n" "${C_BOLD}${C_CYAN}" "$1" "${C_RESET}"
  ui_hr
}

ui_ok()   { printf "%b%s%b %s\n" "${C_GREEN}${C_BOLD}" "$I_OK"   "${C_RESET}" "$*"; }
ui_info() { printf "%b[INFO]%b %s\n" "${C_CYAN}${C_BOLD}" "${C_RESET}" "$*"; }
ui_warn() { printf "%b%s%b %s\n" "${C_YELLOW}${C_BOLD}" "$I_WARN" "${C_RESET}" "$*"; }
ui_err()  { printf "%b%s%b %s\n" "${C_RED}${C_BOLD}" "$I_ERR"  "${C_RESET}" "$*" >&2; }

ui_ln() { printf "%b\n" "$*"; }
ui_no_ln() { printf "%b" "$*"; }

ui_pause() {
  echo
  read -r -p "Нажмите Enter, чтобы продолжить..." _
}

ui_pause_clear() {
  echo
  read -r -p "Нажмите Enter, чтобы очистить экран и продолжить..." _
  clear || true
}

print_banner() {
  clear || true

  # Если есть toilet/figlet — используем (красиво), иначе fallback на встроенный баннер.
  if command -v toilet >/dev/null 2>&1; then
    printf "%b" "${C_MAGENTA}"
    toilet -f big -F border "SWAP" 2>/dev/null || true
    printf "%b" "${C_RESET}"
  elif command -v figlet >/dev/null 2>&1; then
    printf "%b" "${C_MAGENTA}"
    figlet -w 120 "SWAP" 2>/dev/null || true
    printf "%b" "${C_RESET}"
  else
    printf "%b\n" "${C_MAGENTA}${C_BOLD}"
    cat <<'EOF'
███████╗██╗    ██╗ █████╗ ██████╗ 
██╔════╝██║    ██║██╔══██╗██╔══██╗
███████╗██║ █╗ ██║███████║██████╔╝
╚════██║██║███╗██║██╔══██║██╔═══╝ 
███████║╚███╔███╔╝██║  ██║██║     
╚══════╝ ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝     
EOF
    printf "%b\n" "${C_RESET}"
  fi

  printf "%b\n\n" "${C_DIM}Универсальный менеджер swap для Ubuntu/Debian (под ноды)${C_RESET}"

}

# -------------------------
# Helpers / Requirements
# -------------------------
require_root() {
  if [[ ${EUID:-1000} -ne 0 ]]; then
    ui_err "Скрипт должен быть запущен от root (sudo)."
    exit 1
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { ui_err "Не найдена команда: $1"; exit 1; }
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

human_size() {
  local bytes="${1:-0}"
  if have_cmd numfmt; then
    numfmt --to=iec --suffix=B "$bytes"
  else
    awk -v b="$bytes" 'BEGIN{
      split("B K M G T P",u," ");
      for(i=1;b>=1024 && i<6;i++) b/=1024;
      printf "%.2f%s", b, u[i];
    }'
  fi
}

get_mem_kb() { awk '/MemTotal/ {print $2; exit}' /proc/meminfo; }
get_mem_bytes() { local kb; kb="$(get_mem_kb)"; echo $(( kb * 1024 )); }

get_root_fstype() { findmnt -n -o FSTYPE / 2>/dev/null || echo "unknown"; }

is_int() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

validate_range() {
  local name="$1" val="$2" min="$3" max="$4"
  if ! is_int "$val"; then
    ui_err "$name: нужно целое число."
    return 1
  fi
  if (( val < min || val > max )); then
    ui_err "$name: должно быть в диапазоне $min..$max."
    return 1
  fi
}

# -------------------------
# Swap detection
# -------------------------
any_swap_active() {
  swapon --noheadings --show=NAME 2>/dev/null | grep -q .
}

swapfile_active() {
  local swapfile="$1"
  swapon --noheadings --show=NAME 2>/dev/null | awk '{print $1}' | grep -Fxq "$swapfile"
}

has_any_swap_partition_active() {
  # Если среди активных swap-устройств есть /dev/*
  swapon --noheadings --show=NAME 2>/dev/null | awk '{print $1}' | grep -qE '^/dev/'
}

# -------------------------
# Explanations
# -------------------------
print_optimal_explanation_full() {
  cat <<EOF

${C_BOLD}Почему эти значения часто подходят для нод:${C_RESET}

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

print_sysctl_explanation_only() {
  cat <<EOF

${C_BOLD}Почему vm.swappiness=10 и vm.vfs_cache_pressure=50 часто подходят для нод:${C_RESET}

- vm.swappiness=10:
  меньше агрессии свапа → меньше дискового I/O и задержек. Swap остаётся как страховка.

- vm.vfs_cache_pressure=50:
  ядро чуть дольше держит inode/dentry кэш (метаданные ФС), что часто полезно для нод.

${C_DIM}(Важно) В этом пункте swapfile НЕ изменяется — меняются только параметры ядра.${C_RESET}

EOF
}

print_tuning_hint() {
  cat <<EOF

${C_BOLD}Подсказка по параметрам:${C_RESET}
- swappiness: 0..200
  ниже  → реже уходим в swap
  выше  → активнее используем swap
  для нод часто ставят 10

- vfs_cache_pressure: 1..1000
  ниже  → держим inode/dentry кэш дольше
  выше  → быстрее выкидываем этот кэш
  для нод часто ставят 50

EOF
}

extreme_value_notes() {
  local sw="$1" vfs="$2"
  # мягкие предупреждения, без запретов
  if (( sw == 0 )); then
    ui_warn "swappiness=0: swap почти не будет использоваться (может быть норм, но риск OOM выше)."
  elif (( sw > 100 )); then
    ui_warn "swappiness>$((100)): система может чаще уводить страницы в swap (возможны I/O-лаги)."
  fi

  if (( vfs > 200 )); then
    ui_warn "vfs_cache_pressure>200: метаданные ФС будут агрессивно очищаться (возможны просадки на I/O)."
  fi
}

# -------------------------
# Recommended swap size (your algorithm)
# -------------------------
recommended_swap_gb() {
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

  gb=$(( (swap_mib + 1023) / 1024 )) # round up
  (( gb < 1 )) && gb=1
  echo "$gb"
}

# -------------------------
# System info
# -------------------------
print_system_info() {
  local mem_bytes avail_bytes
  mem_bytes="$(get_mem_bytes)"
  avail_bytes="$(df --output=avail -B1 / | tail -n1 | tr -d ' ')"

  ui_title "System info"
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
  if any_swap_active; then
    swapon --show --bytes || true
    echo "${C_DIM}USED=0 — это нормально: swap будет использоваться только при нехватке RAM.${C_RESET}"
  else
    echo "  (swap не обнаружен: ни swapfile, ни swap-раздел не активны)"
  fi
  echo
  echo "vm.swappiness: $(cat /proc/sys/vm/swappiness 2>/dev/null || echo N/A)"
  echo "vm.vfs_cache_pressure: $(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null || echo N/A)"
}

print_system_info_legend() {
  cat <<'EOF'

Пояснения:
- Kernel: версия ядра Linux (влияет на поведение памяти/свапа).
- Uptime: сколько система работает без перезагрузки.
- CPU: модель процессора.
- Cores: число логических ядер (потоков), которые видит система.
- RAM: общий объём оперативной памяти.
- Root FS: файловая система раздела / (ext4/xfs/btrfs и т.д.).
- Root FS available: свободное место на разделе / (важно для swapfile).
- Disk usage: использование смонтированных файловых систем (df -h).
- Swap currently active: активные swap-устройства/файлы (если пусто — swap не включен).
- vm.swappiness: насколько агрессивно система будет использовать swap (если swap есть).
- vm.vfs_cache_pressure: как быстро система будет очищать inode/dentry-кэш (метаданные ФС).

EOF
}

show_system_info_flow() {
  print_banner
  print_system_info
  echo
  read -r -p "Показать пояснения к строкам? (y/N): " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    print_system_info_legend
  fi
  ui_pause
  clear || true
}

# -------------------------
# fstab management (safe)
# -------------------------
fstab_remove_swapfile_line() {
  local swapfile="$1"
  [[ -f /etc/fstab ]] || return 0

  awk -v sf="$swapfile" '
    {
      if ($0 ~ "^[[:space:]]*#") { print; next }
      if ($1 == sf && $3 == "swap") { next }
      print
    }
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

  local old_sw old_vfs
  old_sw="$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "")"
  old_vfs="$(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null || echo "")"

  extreme_value_notes "$sw" "$vfs"

  cat > "$SYSCTL_CONF" <<EOF
# written by swap.sh
vm.swappiness=$sw
vm.vfs_cache_pressure=$vfs
EOF

  # apply only this file
  sysctl -p "$SYSCTL_CONF" >/dev/null || true

  if [[ -n "$old_sw" && -n "$old_vfs" ]]; then
    ui_info "vm.swappiness: $old_sw -> $sw"
    ui_info "vm.vfs_cache_pressure: $old_vfs -> $vfs"
  else
    ui_info "Применено: vm.swappiness=$sw, vm.vfs_cache_pressure=$vfs"
  fi

  ui_info "Сохранено в: $SYSCTL_CONF"
}

# -------------------------
# create/remove swapfile
# -------------------------
TMP_SWAPFILE=""
cleanup_tmp() {
  [[ -n "${TMP_SWAPFILE:-}" && -f "${TMP_SWAPFILE:-}" ]] && rm -f "$TMP_SWAPFILE" || true
}
trap cleanup_tmp EXIT

btrfs_warn_or_exit() {
  local fstype
  fstype="$(get_root_fstype)"
  if [[ "$fstype" == "btrfs" ]]; then
    ui_warn "Корневая FS: btrfs."
    ui_warn "Swapfile на btrfs требует специальных условий (NOCOW/без compression и др.)."
    ui_warn "Если не уверен — лучше использовать swap-раздел или другой FS."
    echo
    read -r -p "Продолжить создание swapfile на btrfs? (y/N): " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { ui_info "Отмена."; exit 0; }
  fi
}

create_swapfile() {
  local swapfile="$1" size_gb="$2"

  if ! is_int "$size_gb" || (( size_gb < 1 )); then
    ui_err "Размер swap должен быть целым числом >= 1 (в ГБ)."
    return 1
  fi

  btrfs_warn_or_exit

  local avail_bytes need_bytes
  avail_bytes="$(df --output=avail -B1 "$(dirname "$swapfile")" 2>/dev/null | tail -n1 | tr -d ' ')"
  need_bytes=$(( size_gb * 1024 * 1024 * 1024 ))

  ui_info "Свободно на $(dirname "$swapfile"): $(human_size "$avail_bytes")"
  ui_info "Требуется под swapfile: $(human_size "$need_bytes")"

  if (( avail_bytes < need_bytes )); then
    ui_err "Недостаточно места для swapfile."
    return 1
  fi

  local tmp="${swapfile}.tmp.$$"
  TMP_SWAPFILE="$tmp"
  rm -f "$tmp" 2>/dev/null || true

  ui_info "Создаю swapfile: $swapfile (${size_gb}G)"

  if have_cmd fallocate; then
    if ! fallocate -l "${size_gb}G" "$tmp" 2>/dev/null; then
      ui_warn "fallocate не сработал, использую dd."
      dd if=/dev/zero of="$tmp" bs=1M count=$(( size_gb * 1024 )) conv=fsync status=progress
    fi
  else
    dd if=/dev/zero of="$tmp" bs=1M count=$(( size_gb * 1024 )) conv=fsync status=progress
  fi

  chmod 600 "$tmp"
  mkswap "$tmp" >/dev/null

  if swapfile_active "$swapfile"; then
    ui_info "Отключаю активный swapfile: $swapfile"
    swapoff "$swapfile" || true
  fi

  mv -f "$tmp" "$swapfile"
  TMP_SWAPFILE=""
  chmod 600 "$swapfile"

  swapon "$swapfile"

  fstab_ensure_swapfile_line "$swapfile"
  ui_info "Добавлено в /etc/fstab для автоподключения."

  ui_ok "Swapfile создан и активирован."
}

remove_swapfile() {
  local swapfile="$1"

  if swapfile_active "$swapfile"; then
    ui_info "Отключаю swapfile: $swapfile"
    swapoff "$swapfile" || true
  fi

  if [[ -f "$swapfile" ]]; then
    rm -f "$swapfile"
    ui_info "Удалён файл: $swapfile"
  else
    ui_info "Файл $swapfile не найден."
  fi

  fstab_remove_swapfile_line "$swapfile"
  ui_info "Запись в /etc/fstab для $swapfile (если была) удалена."
}

# -------------------------
# Menus
# -------------------------
menu_no_swap() {
  local swapfile="$SWAPFILE_DEFAULT"
  local mem_bytes rec_gb
  mem_bytes="$(get_mem_bytes)"
  rec_gb="$(recommended_swap_gb)"

  while true; do
    print_banner
    ui_title "Swap не найден"

    ui_ln "${C_DIM}Рекомендуемый swap по RAM (${C_BOLD}$(human_size "$mem_bytes")${C_DIM}): ${C_BOLD}${rec_gb}G${C_RESET}"
    ui_ln "${C_DIM}Режим 1 минимизирует риск OOM и снижает I/O-лаг за счёт low swappiness.${C_RESET}"
    echo

    ui_ln " ${C_GRAY}0)${C_RESET} Показать системную информацию ещё раз"
    ui_ln " ${C_GREEN}1)${C_RESET} Создать swapfile ${C_BOLD}${rec_gb}G${C_RESET} + swappiness=${DEFAULT_SWAPPINESS} + vfs_cache_pressure=${DEFAULT_VFS} ${C_DIM}(рекомендуется)${C_RESET}"
    ui_ln " ${C_CYAN}2)${C_RESET} Создать swapfile со своими настройками"
    ui_ln " ${C_RED}3)${C_RESET} Выход"
    echo
    read -r -p "Введите номер действия: " c

    case "$c" in
      0)
        show_system_info_flow
        ;;
      1)
        print_banner
        ui_title "Создание swapfile (рекомендуется)"
        print_optimal_explanation_full

        ui_ln "${C_BOLD}Было:${C_RESET}"
        echo "  swap: (нет)"
        echo "  vm.swappiness: $(cat /proc/sys/vm/swappiness 2>/dev/null || echo N/A)"
        echo "  vm.vfs_cache_pressure: $(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null || echo N/A)"
        echo
        ui_ln "${C_BOLD}Будет создано:${C_RESET}"
        echo "  swapfile: $swapfile"
        echo "  размер:   ${rec_gb}G (по формуле от RAM)"
        echo "  swappiness=$DEFAULT_SWAPPINESS"
        echo "  vfs_cache_pressure=$DEFAULT_VFS"
        echo "  swap будет активирован (swapon) и добавлен в /etc/fstab"
        echo

        echo "Enter — создать swapfile, Ctrl+C — отмена."
        ui_pause

        create_swapfile "$swapfile" "$rec_gb"
        apply_sysctl_and_save "$DEFAULT_SWAPPINESS" "$DEFAULT_VFS"

        echo
        ui_info "Готово. Текущий swap:"
        swapon --show --bytes || true
        echo "${C_DIM}USED=0 — это нормально: swap будет использоваться только при нехватке RAM.${C_RESET}"

        ui_pause_clear
        ui_info "Операция завершена."
        return 0
        ;;
      2)
        local sz sw vfs
        print_banner
        ui_title "Создание swapfile (свои настройки)"

        print_tuning_hint
        ui_ln "Рекомендуемый размер swap по RAM: ${C_BOLD}${rec_gb}G${C_RESET}"
        echo

        read -r -p "Размер swap (ГБ) [по умолчанию ${rec_gb}]: " sz
        sz="${sz:-$rec_gb}"

        if ! is_int "$sz" || (( sz < 1 )); then
          ui_err "Неверный размер swap."
          ui_pause_clear
          continue
        fi

        read -r -p "swappiness [рекомендуется ${DEFAULT_SWAPPINESS}]: " sw
        sw="${sw:-$DEFAULT_SWAPPINESS}"

        read -r -p "vfs_cache_pressure [рекомендуется ${DEFAULT_VFS}]: " vfs
        vfs="${vfs:-$DEFAULT_VFS}"

        echo
        echo "Enter — создать swapfile, Ctrl+C — отмена."
        ui_pause

        create_swapfile "$swapfile" "$sz"
        apply_sysctl_and_save "$sw" "$vfs"

        echo
        ui_ok "Swapfile успешно создан. Текущий swap:"
        swapon --show --bytes || true
        echo "${C_DIM}USED=0 — это нормально: swap будет использоваться только при нехватке RAM.${C_RESET}"

        ui_pause_clear
        ui_info "Операция завершена."
        return 0
        ;;
      3)
        clear || true
        exit 0
        ;;
      *)
        ui_warn "Нужно выбрать 0-3."
        sleep 1
        ;;
    esac
  done
}

menu_with_swap() {
  local swapfile="$SWAPFILE_DEFAULT"
  local mem_bytes rec_gb
  mem_bytes="$(get_mem_bytes)"
  rec_gb="$(recommended_swap_gb)"

  while true; do
    print_banner
    ui_title "Swap обнаружен"

    ui_ln "${C_BOLD}Текущие значения:${C_RESET}"
    swapon --show --bytes || true
    echo "vm.swappiness: $(cat /proc/sys/vm/swappiness 2>/dev/null || echo N/A)"
    echo "vm.vfs_cache_pressure: $(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null || echo N/A)"
    echo "${C_DIM}USED=0 — это нормально: swap будет использоваться только при нехватке RAM.${C_RESET}"
    echo

    ui_ln "${C_DIM}Рекомендуемый swap по RAM (${C_BOLD}$(human_size "$mem_bytes")${C_DIM}): ${C_BOLD}${rec_gb}G${C_RESET}"
    echo

    # Подпись для пункта 4 (в зависимости от того, есть ли swap-раздел)
    local opt4_label
    if has_any_swap_partition_active; then
      opt4_label="Создать/пересоздать swapfile ${swapfile} (не трогая swap-раздел)"
    else
      opt4_label="Пересоздать swapfile ${swapfile} (удалить и создать заново)"
    fi

    ui_ln " ${C_GRAY}0)${C_RESET} Показать системную информацию ещё раз"
    ui_ln " ${C_GREEN}1)${C_RESET} Оставить существующий swap без изменений"
    ui_ln " ${C_CYAN}2)${C_RESET} Применить оптимальные swappiness/vfs_cache_pressure (10/50) ${C_DIM}(рекомендуется для нод)${C_RESET}"
    ui_ln " ${C_CYAN}3)${C_RESET} Изменить swappiness/vfs_cache_pressure вручную"
    ui_ln " ${C_YELLOW}4)${C_RESET} ${opt4_label}"
    ui_ln " ${C_RED}5)${C_RESET} Выход"
    echo
    read -r -p "Введите номер действия: " c

    case "$c" in
      0)
        show_system_info_flow
        ;;
      1)
        ui_info "Оставляю как есть."
        # (по желанию) короткая сводка
        ui_info "Swap: $(swapon --noheadings --show=NAME,SIZE,USED 2>/dev/null | head -n1 | tr -s ' ' | sed 's/^ *//')"
        ui_info "vm.swappiness=$(cat /proc/sys/vm/swappiness), vm.vfs_cache_pressure=$(cat /proc/sys/vm/vfs_cache_pressure)"
        ui_pause_clear
        ui_info "Операция завершена."
        return 0
        ;;
      2)
        print_banner
        ui_title "Применение оптимальных sysctl (10/50)"
        print_sysctl_explanation_only
        apply_sysctl_and_save "$DEFAULT_SWAPPINESS" "$DEFAULT_VFS"
        ui_pause_clear
        ui_info "Операция завершена."
        return 0
        ;;
      3)
        local sw vfs cur_sw cur_vfs
        print_banner
        ui_title "Ручная настройка sysctl"
        print_tuning_hint

        cur_sw="$(cat /proc/sys/vm/swappiness 2>/dev/null || echo N/A)"
        cur_vfs="$(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null || echo N/A)"
        ui_ln "${C_DIM}Сейчас: swappiness=${cur_sw}, vfs_cache_pressure=${cur_vfs}${C_RESET}"
        echo

        read -r -p "swappiness [рекомендуется ${DEFAULT_SWAPPINESS}]: " sw
        sw="${sw:-$DEFAULT_SWAPPINESS}"

        read -r -p "vfs_cache_pressure [рекомендуется ${DEFAULT_VFS}]: " vfs
        vfs="${vfs:-$DEFAULT_VFS}"

        apply_sysctl_and_save "$sw" "$vfs"
        ui_pause_clear
        ui_info "Операция завершена."
        return 0
        ;;
      4)
        print_banner
        ui_title "Пересоздание swapfile"
        ui_warn "Важно: скрипт гарантированно удаляет/пересоздаёт только swapfile по пути ${swapfile}."
        if has_any_swap_partition_active; then
          ui_warn "Обнаружен активный swap-раздел: он останется и не будет изменён автоматически."
        fi
        echo
        read -r -p "Продолжить? (y/N): " ans
        [[ "$ans" =~ ^[Yy]$ ]] || { ui_info "Отмена."; ui_pause_clear; continue; }

        remove_swapfile "$swapfile"
        ui_warn "Swap сейчас отключён."
        ui_warn "Не закрывайте сессию и завершите создание нового swapfile."
        echo

        print_optimal_explanation_full
        read -r -p "Размер нового swap (ГБ) [рекомендуется ${rec_gb}]: " new_sz
        new_sz="${new_sz:-$rec_gb}"
        if ! is_int "$new_sz" || (( new_sz < 1 )); then
          ui_err "Неверный размер."
          ui_pause_clear
          continue
        fi

        create_swapfile "$swapfile" "$new_sz"

        echo
        ui_ln "${C_BOLD}Текущие sysctl сейчас:${C_RESET} swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo N/A), vfs_cache_pressure=$(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null || echo N/A)"
        echo "Применить оптимальные sysctl (10/50) и сохранить для перезагрузки?"
        ui_ln " ${C_GREEN}1)${C_RESET} Да"
        ui_ln " ${C_CYAN}2)${C_RESET} Нет, задам вручную"
        read -r -p "Выбор [1-2]: " sc

        case "$sc" in
          1)
            apply_sysctl_and_save "$DEFAULT_SWAPPINESS" "$DEFAULT_VFS"
            ;;
          2)
            local sw2 vfs2
            print_tuning_hint
            read -r -p "swappiness [рекомендуется ${DEFAULT_SWAPPINESS}]: " sw2
            sw2="${sw2:-$DEFAULT_SWAPPINESS}"
            read -r -p "vfs_cache_pressure [рекомендуется ${DEFAULT_VFS}]: " vfs2
            vfs2="${vfs2:-$DEFAULT_VFS}"
            apply_sysctl_and_save "$sw2" "$vfs2"
            ;;
          *)
            ui_warn "Не понял выбор — sysctl оставляю как есть."
            ;;
        esac

        echo
        ui_ok "Готово. Текущий swap:"
        swapon --show --bytes || true
        echo "${C_DIM}USED=0 — это нормально: swap будет использоваться только при нехватке RAM.${C_RESET}"

        ui_pause_clear
        ui_info "Операция завершена."
        return 0
        ;;
      5)
        clear || true
        exit 0
        ;;
      *)
        ui_warn "Нужно выбрать 0-5."
        sleep 1
        ;;
    esac
  done
}

# -------------------------
# Main
# -------------------------
main() {
  require_root
  need_cmd swapon
  need_cmd swapoff
  need_cmd mkswap
  need_cmd sysctl
  need_cmd df
  need_cmd findmnt

  # Стартовый экран: инфо + легенда по желанию
  show_system_info_flow

  # Основное меню по наличию swap
  if any_swap_active; then
    menu_with_swap
  else
    menu_no_swap
  fi
}

main "$@"
