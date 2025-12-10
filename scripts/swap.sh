#!/usr/bin/env bash
# ======================================================
#  🧊 Universal SWAP Manager — удобный модуль
#  Поддержка: Ubuntu, Debian
#  - Показ системы (CPU / RAM / Disk / SWAP / параметры)
#  - Настройка swappiness и vfs_cache_pressure
#  - Создать / Пересоздать swap с красивым progress-bar
# ======================================================

set -o errexit
set -o nounset
set -o pipefail

# ---------------- config ----------------
SWAPFILE="/swapfile"
SYSCTL_CONF="/etc/sysctl.d/99-swap-tuning.conf"
BLOCK_SIZE_BYTES=$((4 * 1024 * 1024))   # 4 MiB block
BAR_WIDTH=30

# colors (may be absent or minimal in some terminals)
CLR_BOLD="\e[1m"
CLR_RESET="\e[0m"
CLR_CYAN="\e[36m"
CLR_GREEN="\e[32m"
CLR_YELLOW="\e[33m"
CLR_RED="\e[31m"

# require root
if [[ $EUID -ne 0 ]]; then
  echo "Этот скрипт нужно запускать от root (sudo)."
  exit 1
fi

# ---------- helpers ----------
human_readable_bytes() {
  # input: bytes -> nice string like 7.7G
  awk -v b="$1" 'BEGIN{
    if (b < 1024) { printf "%dB", b; exit }
    if (b < 1024*1024) { printf "%.1fK", b/1024; exit }
    if (b < 1024*1024*1024) { printf "%.1fM", b/1024/1024; exit }
    printf "%.1fG", b/1024/1024/1024
  }'
}

get_total_ram_gb() { awk '/MemTotal/ {printf "%.1f", $2/1024/1024}' /proc/meminfo; }
get_avail_ram_gb()  { awk '/MemAvailable/ {printf "%.1f", $2/1024/1024}' /proc/meminfo; }
get_root_disk_total() { df -h / | awk 'NR==2 {print $2}'; }
get_root_disk_avail()  { df -h / | awk 'NR==2 {print $4}'; }
get_swap_bytes() { awk 'BEGIN{sum=0} {sum+=$3} END{print (sum?sum:0)}' < <(swapon --show --bytes --noheadings 2>/dev/null || true); }

get_swappiness() { sysctl -n vm.swappiness 2>/dev/null || echo "не задано"; }
get_vfs_cache_pressure() { sysctl -n vm.vfs_cache_pressure 2>/dev/null || echo "не задано"; }

get_cpu_info() {
  local cores=$(nproc --all 2>/dev/null || echo "?")
  # average MHz across CPUs (if available)
  local mhz=$(awk '/cpu MHz/ {sum+=$4; n++} END{if(n>0) printf "%.1f", sum/n/1000; else print "?"}' /proc/cpuinfo 2>/dev/null)
  # print like: "4 vCore @ 2.9 GHz"
  if [[ "$mhz" == "?" ]]; then
    echo "${cores} vCore"
  else
    printf "%s vCore @ %s GHz" "$cores" "$mhz"
  fi
}

# ---------- show system info ----------
show_system_info() {
  clear
  echo -e "${CLR_CYAN}${CLR_BOLD}🧊  Universal SWAP Manager — удобный модуль${CLR_RESET}"
  echo ""
  echo -e "${CLR_CYAN}📌 Информация о системе:${CLR_RESET}"
  echo -n "  ▸ CPU (процессор):      "
  echo -e "${CLR_YELLOW}$(get_cpu_info)${CLR_RESET}"
  echo -n "  ▸ RAM (объём оперативной памяти):  "
  echo -e "${CLR_YELLOW}$(get_total_ram_gb) GiB (доступно: $(get_avail_ram_gb) GiB)${CLR_RESET}"
  echo -n "  ▸ Disk / (объём диска): "
  echo -e "${CLR_YELLOW}$(get_root_disk_total) (свободно: $(get_root_disk_avail))${CLR_RESET}"

  local swap_bytes
  swap_bytes=$(get_swap_bytes)
  if [[ -n "$swap_bytes" && "$swap_bytes" -gt 0 ]]; then
    echo -n "  ▸ SWAP (объём файла подкачки): "
    echo -e "${CLR_YELLOW}$(human_readable_bytes "$swap_bytes")${CLR_RESET}"
  else
    echo -n "  ▸ SWAP (объём файла подкачки): "
    echo -e "${CLR_YELLOW}не найден${CLR_RESET}"
  fi

  echo -n "  ▸ swappiness*:          "
  echo -e "${CLR_YELLOW}$(get_swappiness)${CLR_RESET}"
  echo -n "  ▸ vfs_cache_pressure**: "
  echo -e "${CLR_YELLOW}$(get_vfs_cache_pressure)${CLR_RESET}"
  echo ""
  echo -e "* swappiness — параметр, отвечающий за то, как активно будет использоваться swap (связан с файлом подкачки)"
  echo -e "** vfs_cache_pressure — параметр, отвечающий за то, как долго хранится файловый кэш; работает всегда и влияет на RAM независимо от swap"
  echo ""
}

# ---------- sysctl apply ----------
save_and_apply_sysctl() {
  local sw="$1"; local vfs="$2"
  cat > "$SYSCTL_CONF" <<EOF
# Applied by swap.sh
vm.swappiness = $sw
vm.vfs_cache_pressure = $vfs
EOF
  sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1 || true
}

# ---------- safe fstab ----------
ensure_fstab_entry() {
  # remove duplicates then append
  sed -i "\|$SWAPFILE|d" /etc/fstab 2>/dev/null || true
  echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
}
remove_swap_from_fstab() {
  sed -i "\|$SWAPFILE|d" /etc/fstab 2>/dev/null || true
}

# ---------- progress bar ----------
print_progress_bar_line() {
  # args: written_bytes total_bytes elapsed_seconds
  local written=$1 total=$2 elapsed=$3
  local percent=0
  if (( total > 0 )); then
    percent=$(( written * 100 / total ))
  fi
  local filled=$(( percent * BAR_WIDTH / 100 ))
  local empty=$(( BAR_WIDTH - filled ))
  local bar=""
  for ((i=0;i<filled;i++)); do bar+="#"; done
  for ((i=0;i<empty;i++)); do bar+="-"; done

  # speed in MB/s, avoid division by zero
  local speed=0
  if (( elapsed > 0 )); then
    speed=$(( written / 1024 / 1024 / elapsed ))
  fi

  local written_hr total_hr
  written_hr=$(human_readable_bytes "$written")
  total_hr=$(human_readable_bytes "$total")

  printf "\r[%s] %3d%%  (%s / %s) | %s MB/s | прошло %s сек" "$bar" "$percent" "$written_hr" "$total_hr" "$speed" "$elapsed"
}

# ---------- create swap with manual blocks and progress ----------
create_swap_with_progress() {
  local size_gb="$1"
  local total_bytes=$(( size_gb * 1024 * 1024 * 1024 ))
  local block=$BLOCK_SIZE_BYTES
  local blocks=$(( total_bytes / block ))
  if (( blocks <= 0 )); then
    echo "Неверный размер"
    return 1
  fi

  # ensure previous swapped off and file removed
  swapoff -a 2>/dev/null || true
  remove_swap_from_fstab
  rm -f "$SWAPFILE" 2>/dev/null || true

  # create empty file and set perm
  : > "$SWAPFILE"
  chmod 600 "$SWAPFILE"

  local written=0
  local start_ts=$(date +%s)
  local last_update_ts=$start_ts

  # write blocks with dd (append) — dd status suppressed, update once per second
  for ((i=1;i<=blocks;i++)); do
    dd if=/dev/zero bs="$block" count=1 of="$SWAPFILE" oflag=append conv=notrunc status=none 2>/dev/null || {
      echo -e "\nОшибка записи блока. Прерывание."
      return 1
    }
    written=$(( written + block ))
    local now_ts=$(date +%s)
    if (( now_ts > last_update_ts )); then
      last_update_ts=$now_ts
      local elapsed=$(( now_ts - start_ts ))
      print_progress_bar_line "$written" "$total_bytes" "$elapsed"
    fi
  done

  # remainder
  local remainder=$(( total_bytes - written ))
  if (( remainder > 0 )); then
    dd if=/dev/zero bs=1 count="$remainder" of="$SWAPFILE" oflag=append conv=notrunc status=none 2>/dev/null || true
    written=$(( written + remainder ))
  fi

  # finalize: mkswap and swapon
  printf "\n"
  mkswap "$SWAPFILE" >/dev/null 2>&1 || { echo "mkswap failed"; return 1; }
  swapon "$SWAPFILE" >/dev/null 2>&1 || { echo "swapon failed"; return 1; }

  ensure_fstab_entry

  return 0
}

# ---------- input validation ----------
read_integer() {
  local prompt="$1"
  local min=${2:-0}
  local max=${3:-999999}
  local val
  while true; do
    read -rp "$prompt" val
    if [[ "$val" =~ ^[0-9]+$ ]] && (( val >= min && val <= max )); then
      echo "$val"
      return 0
    fi
    echo "Ошибка: введите целое число от $min до $max."
  done
}

# ---------- Main menus ----------
menu_when_swap_exists() {
  while true; do
    echo ""
    echo -e "${CLR_CYAN}Выберите действие:${CLR_RESET}"
    echo "1) Оставить существующий swap"
    echo "2) Настроить параметры (swappiness / vfs_cache_pressure)"
    echo "3) Пересоздать swap"
    echo "4) Выход"
    read -rp "Выбор [1-4]: " CH
    case "$CH" in
      1)
        clear
        echo "Ничего не изменено. Выход."
        exit 0
        ;;
      2)
        clear
        echo -e "${CLR_CYAN}Пояснение параметров:${CLR_RESET}"
        echo ""
        echo "  ▸ swappiness — как активно будет использоваться swap"
        echo "       0–10: Почти не использовать swap (только при реальном OOM)"
        echo "       10–20: Оптимально для серверов и нод"
        echo "       30–40: Нормально для десктопов"
        echo "       60: Значение по умолчанию в Ubuntu"
        echo "       80–100: Агрессивное свопирование"
        echo ""
        echo "  ▸ vfs_cache_pressure — как долго хранится файловый кэш"
        echo "       1–50: Кэш хранится дольше (лучше для серверов/нод)"
        echo "       100: Значение по умолчанию в Ubuntu"
        echo "       150–200: Быстрое очищение кэша"
        echo ""
        echo "Выбор:"
        echo "1) Применить значения по умолчанию (10 / 50) — оптимально для нод"
        echo "2) Ввести свои значения"
        echo "3) Отмена"
        read -rp "Выбор [1-3]: " opt
        case "$opt" in
          1)
            apply_sysctl_and_save 10 50
            clear
            echo -e "${CLR_GREEN}✔ Параметры применены: swappiness=10, vfs_cache_pressure=50${CLR_RESET}"
            ;;
          2)
            sw=$(read_integer "Введите swappiness (0–100): " 0 100)
            cpv=$(read_integer "Введите vfs_cache_pressure (1–200): " 1 200)
            apply_sysctl_and_save "$sw" "$cpv"
            clear
            echo -e "${CLR_GREEN}✔ Параметры применены: swappiness=${sw}, vfs_cache_pressure=${cpv}${CLR_RESET}"
            ;;
          *)
            clear
            echo "Отмена."
            ;;
        esac
        ;;
      3)
        clear
        echo "Пересоздание swap (существующий swap будет удалён)."
        sz=$(read_integer "Введите размер нового swap в ГБ (например 8): " 1 65536)
        echo ""
        echo "По умолчанию используются параметры (оптимально для нод):"
        echo "  ▸ swappiness: 10"
        echo "  ▸ vfs_cache_pressure: 50"
        read -rp "Использовать значения по умолчанию (10 / 50)? (Y/n): " yn
        if [[ "$yn" =~ ^[Nn]$ ]]; then
          sw=$(read_integer "Введите swappiness (0–100): " 0 100)
          cpv=$(read_integer "Введите vfs_cache_pressure (1–200): " 1 200)
        else
          sw=10; cpv=50
        fi

        echo -e "${CLR_YELLOW}Начинаю пересоздание swap (${sz}G). Это может занять несколько минут...${CLR_RESET}"
        if create_swap_with_progress "$sz"; then
          apply_sysctl_and_save "$sw" "$cpv"
          clear
          echo -e "${CLR_GREEN}✔ Swap пересоздан и параметры применены.${CLR_RESET}"
          swapon --show || true
        else
          echo -e "${CLR_RED}Ошибка при создании swap.${CLR_RESET}"
        fi
        ;;
      4)
        clear
        echo "Выход."
        exit 0
        ;;
      *)
        echo "Неверный выбор."
        ;;
    esac
  done
}

menu_when_no_swap() {
  while true; do
    echo ""
    echo -e "${CLR_CYAN}Swap не найден.${CLR_RESET}"
    echo "Выберите действие:"
    echo "1) Создать swap"
    echo "2) Выход"
    read -rp "Выбор [1-2]: " ch
    case "$ch" in
      1)
        clear
        sz=$(read_integer "Введите размер swap в ГБ (например 8): " 1 65536)
        echo ""
        echo "По умолчанию используются параметры (оптимально для нод):"
        echo "  ▸ swappiness: 10"
        echo "  ▸ vfs_cache_pressure: 50"
        read -rp "Использовать значения по умолчанию (10 / 50)? (Y/n): " yn
        if [[ "$yn" =~ ^[Nn]$ ]]; then
          sw=$(read_integer "Введите swappiness (0–100): " 0 100)
          cpv=$(read_integer "Введите vfs_cache_pressure (1–200): " 1 200)
        else
          sw=10; cpv=50
        fi
        echo -e "${CLR_YELLOW}Создание swap файла (${sz}G). Это может занять несколько минут...${CLR_RESET}"
        if create_swap_with_progress "$sz"; then
          apply_sysctl_and_save "$sw" "$cpv"
          clear
          echo -e "${CLR_GREEN}✔ Swap создан и параметры применены.${CLR_RESET}"
          swapon --show || true
        else
          echo -e "${CLR_RED}Ошибка при создании swap.${CLR_RESET}"
        fi
        ;;
      2)
        clear
        echo "Выход."
        exit 0
        ;;
      *)
        echo "Неверный выбор."
        ;;
    esac
  done
}

# ---------------- run ----------------
show_system_info
# determine if swap exists
swap_bytes=$(get_swap_bytes)
if [[ -n "$swap_bytes" && "$swap_bytes" -gt 0 ]]; then
  menu_when_swap_exists
else
  menu_when_no_swap
fi

# end
