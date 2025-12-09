#!/usr/bin/env bash
# ======================================================
#  🧊 Universal SWAP Manager — удобный модуль от Plaaaga
# ======================================================

set -o errexit
set -o pipefail
set -o nounset

# require root
if [[ $EUID -ne 0 ]]; then
  echo "Этот скрипт нужно запускать от root (sudo)."
  exit 1
fi

# ---- colors ----
CLR_GREEN="\e[32m"
CLR_YELLOW="\e[33m"
CLR_CYAN="\e[36m"
CLR_RESET="\e[0m"
CLR_BOLD="\e[1m"

# ---- config ----
SWAPFILE="/swapfile"
SYSCTL_CONF="/etc/sysctl.d/99-swap-tuning.conf"
BLOCK_SIZE_BYTES=$((4 * 1024 * 1024))   # 4 MiB per block for progress
BAR_WIDTH=30

# ---------- helpers ----------
human_readable_bytes() {
  # input: bytes
  local bytes=$1
  if [[ $bytes -lt 1024 ]]; then
    echo "${bytes}B"
  elif [[ $bytes -lt $((1024**2)) ]]; then
    printf "%.1fK" "$(bc -l <<< "$bytes/1024")"
  elif [[ $bytes -lt $((1024**3)) ]]; then
    printf "%.1fM" "$(bc -l <<< "$bytes/1024/1024")"
  else
    printf "%.1fG" "$(bc -l <<< "$bytes/1024/1024/1024")"
  fi
}

get_total_ram() {
  awk '/MemTotal/ {printf "%.1f", $2/1024/1024}' /proc/meminfo
}
get_available_ram() {
  awk '/MemAvailable/ {printf "%.1f", $2/1024/1024}' /proc/meminfo
}
get_root_disk_total() {
  df -h / | awk 'NR==2 {print $2}'
}
get_root_disk_avail() {
  df -h / | awk 'NR==2 {print $4}'
}
get_swap_size_bytes() {
  # returns bytes or 0 if no swap
  local bytes
  bytes=$(swapon --show --bytes --noheadings --raw 2>/dev/null | awk '{sum += $3} END {print (sum ? sum : 0)}')
  echo "${bytes:-0}"
}
get_swappiness() {
  sysctl -n vm.swappiness 2>/dev/null || echo "не задано"
}
get_vfs_cache_pressure() {
  sysctl -n vm.vfs_cache_pressure 2>/dev/null || echo "не задано"
}

# ---------- show system info with descriptions ----------
show_system_info() {
  clear
  echo -e "${CLR_CYAN}${CLR_BOLD}🧊  Universal SWAP Manager — удобный модуль${CLR_RESET}"
  echo ""

  local ram_total ram_avail disk_total disk_avail swap_bytes swap_hr swappiness vfs
  ram_total=$(get_total_ram)
  ram_avail=$(get_available_ram)
  disk_total=$(get_root_disk_total)
  disk_avail=$(get_root_disk_avail)
  swap_bytes=$(get_swap_size_bytes)
  swap_hr=$(human_readable_bytes "$swap_bytes")
  swappiness=$(get_swappiness)
  vfs=$(get_vfs_cache_pressure)

  echo -e "${CLR_CYAN}📌 Информация о системе:${CLR_RESET}"
  printf "  ▸ RAM (объём оперативной памяти):\t%s GiB (доступно: %s GiB)\n" "$ram_total" "$ram_avail"
  printf "  ▸ Disk / (объём диска):\t\t%s (свободно: %s)\n" "$disk_total" "$disk_avail"

  if [[ "$swap_bytes" -gt 0 ]]; then
    printf "  ▸ SWAP (объём файла подкачки):\t%s\n" "$swap_hr"
  else
    printf "  ▸ SWAP (объём файла подкачки):\t%s\n" "не найден"
  fi

  printf "  ▸ swappiness*:\t\t\t%s\n" "$swappiness"
  printf "  ▸ vfs_cache_pressure**:\t\t%s\n" "$vfs"
  echo ""
  echo -e "* swappiness — параметр, отвечающий за то, как активно будет использоваться swap (связан с файлом подкачки)"
  echo -e "** vfs_cache_pressure — параметр, отвечающий за то, как долго хранится файловый кэш; работает всегда и влияет на RAM независимо от swap"
  echo
}

# ---------- sysctl apply & save ----------
apply_sysctl_and_save() {
  local sw="$1"
  local vfs="$2"
  # Write to /etc/sysctl.d/99-swap-tuning.conf
  cat > "$SYSCTL_CONF" <<EOF
# Applied by swap.sh
vm.swappiness = $sw
vm.vfs_cache_pressure = $vfs
EOF
  # Apply immediately
  sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1 || true
}

# ---------- safe fstab remove ----------
remove_swapfile_from_fstab() {
  if grep -qF "$SWAPFILE" /etc/fstab 2>/dev/null; then
    sed -i "\|$SWAPFILE|d" /etc/fstab
  fi
}

# ---------- progress bar functions ----------
print_progress_bar() {
  # args: written_bytes total_bytes elapsed_seconds
  local written="$1"
  local total="$2"
  local elapsed="$3"
  local percent=0
  if [[ "$total" -gt 0 ]]; then
    percent=$(( written * 100 / total ))
  fi
  local filled=$(( percent * BAR_WIDTH / 100 ))
  local empty=$(( BAR_WIDTH - filled ))
  local bar=""
  for ((i=0;i<filled;i++)); do bar+="#"; done
  for ((i=0;i<empty;i++)); do bar+="-"; done

  # speed MB/s
  local speed=0
  if [[ "$elapsed" -gt 0 ]]; then
    speed=$(( written / 1024 / 1024 / elapsed ))
  fi

  # human
  local written_hr total_hr
  written_hr=$(human_readable_bytes "$written")
  total_hr=$(human_readable_bytes "$total")

  printf "\r[%s] %3d%%  (%s / %s) | %s MB/s | прошли %s сек" "$bar" "$percent" "$written_hr" "$total_hr" "$speed" "$elapsed"
}

# ---------- create swap with manual loop and progress ----------
create_swap_file_with_progress() {
  local size_gb="$1"
  local total_bytes=$(( size_gb * 1024 * 1024 * 1024 ))
  local block="$BLOCK_SIZE_BYTES"
  local blocks=$(( total_bytes / block ))
  if [[ blocks -le 0 ]]; then
    echo "Неправильный размер"
    return 1
  fi

  # ensure no leftover
  swapoff -a 2>/dev/null || true
  remove_swapfile_from_fstab
  rm -f "$SWAPFILE" 2>/dev/null

  # create empty file with correct permissions first to avoid partial permission window
  : > "$SWAPFILE"
  chmod 600 "$SWAPFILE"

  local written=0
  local start_ts=$(date +%s)
  local last_update_ts=$start_ts

  # We'll append blocks of zeros using dd bs=4M count=1 oflag=append conv=notrunc
  # dd output suppressed
  for ((i=1;i<=blocks;i++)); do
    # write one block
    dd if=/dev/zero bs="$block" count=1 of="$SWAPFILE" oflag=append conv=notrunc status=none || {
      echo -e "\nОшибка записи блока. Прерывание."
      return 1
    }
    written=$(( written + block ))

    local now_ts=$(date +%s)
    # update roughly once per second
    if (( now_ts > last_update_ts )); then
      last_update_ts=$now_ts
      local elapsed=$(( now_ts - start_ts ))
      print_progress_bar "$written" "$total_bytes" "$elapsed"
    fi
  done

  # if there's remainder bytes (when size isn't multiple of block) write it
  local remainder=$(( total_bytes - written ))
  if (( remainder > 0 )); then
    dd if=/dev/zero bs=1 count="$remainder" of="$SWAPFILE" oflag=append conv=notrunc status=none || true
    written=$(( written + remainder ))
  fi

  # finalize
  printf "\n"
  # mkswap & swapon
  mkswap "$SWAPFILE" >/dev/null 2>&1 || true
  swapon "$SWAPFILE" >/dev/null 2>&1 || true

  # ensure fstab entry
  remove_swapfile_from_fstab
  echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
  return 0
}

# ---------- input helpers ----------
read_number() {
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

# ---------- main menu logic ----------
main_menu_with_swap() {
  while true; do
    echo ""
    echo "Выберите действие:"
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
        # configure params: show help then choose
        clear
        echo -e "${CLR_CYAN}Пояснение параметров:${CLR_RESET}"
        echo ""
        echo "  ▸ swappiness — как активно будет использоваться swap"
        echo "       0–10: Почти не использовать swap (только при реальном OOM)"
        echo "       10–20: Оптимально для серверов и нод (минимум лагов)"
        echo "       30–40: Нормально для десктопов (баланс)"
        echo "       60: Значение по умолчанию в Ubuntu"
        echo "       80–100: Агрессивное свопирование (маленькая RAM)"
        echo ""
        echo "  ▸ vfs_cache_pressure — как долго хранится файловый кэш"
        echo "       1–50: Кэш держится дольше, лучше для серверов/нод"
        echo "       100: Значение по умолчанию в Ubuntu"
        echo "       150–200: Быстрое очищение кэша"
        echo ""
        echo "Выбор:"
        echo "1) Применить значения по умолчанию (10 / 50) — оптимально для нод"
        echo "2) Ввести свои значения"
        echo "3) Отмена"
        read -rp "Выбор [1-3]: " optp
        case "$optp" in
          1)
            apply_sysctl_and_save 10 50
            clear
            echo -e "${CLR_GREEN}✔ Параметры применены: swappiness=10, vfs_cache_pressure=50${CLR_RESET}"
            ;;
          2)
            sw=$(read_number "Введите swappiness (0–100): " 0 100)
            cpv=$(read_number "Введите vfs_cache_pressure (1–200): " 1 200)
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
        # Recreate swap: ask size, ask default or custom params
        clear
        echo "Пересоздание swap (существующая запись будет удалена)."
        sz=$(read_number "Введите размер нового swap в ГБ (например 8): " 1 65536)
        echo ""
        echo "По умолчанию используются параметры (оптимально для нод):"
        echo "  ▸ swappiness: 10"
        echo "  ▸ vfs_cache_pressure: 50"
        read -rp "Использовать значения по умолчанию (10 / 50)? (Y/n): " yn
        if [[ "$yn" =~ ^[Nn]$ ]]; then
          clear
          echo -e "${CLR_CYAN}Пояснение параметров:${CLR_RESET}"
          echo ""
          echo "  ▸ swappiness — как активно будет использоваться swap"
          echo "       0–10: Почти не использовать swap (только при реальном OOM)"
          echo "       10–20: Оптимально для серверов и нод (минимум лагов)"
          echo "       30–40: Нормально для десктопов (баланс)"
          echo "       60: Значение по умолчанию в Ubuntu"
          echo "       80–100: Агрессивное свопирование (маленькая RAM)"
          echo ""
          echo "  ▸ vfs_cache_pressure — как долго хранится файловый кэш"
          echo "       1–50: Кэш держится дольше, лучше для серверов/нод"
          echo "       100: Значение по умолчанию в Ubuntu"
          echo "       150–200: Быстрое очищение кэша"
          echo ""
          sw=$(read_number "Введите swappiness (0–100): " 0 100)
          cpv=$(read_number "Введите vfs_cache_pressure (1–200): " 1 200)
        else
          sw=10
          cpv=50
        fi

        echo -e "${CLR_YELLOW}Начинаю пересоздание swap файла (${sz}G). Это может занять несколько минут...${CLR_RESET}"
        echo ""
        # Perform creation with progress
        if create_swap_file_with_progress "$sz"; then
          # apply sysctl and save
          apply_sysctl_and_save "$sw" "$cpv"
          clear
          echo -e "${CLR_GREEN}✔ Swap пересоздан и параметры применены.${CLR_RESET}"
          echo "Текущий swap:"
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

main_menu_no_swap() {
  while true; do
    echo ""
    echo "Swap не найден."
    echo "Выберите действие:"
    echo "1) Создать swap"
    echo "2) Выход"
    read -rp "Выбор [1-2]: " ch
    case "$ch" in
      1)
        clear
        sz=$(read_number "Введите размер swap в ГБ (например 8): " 1 65536)
        echo ""
        echo "По умолчанию используются параметры (оптимально для нод):"
        echo "  ▸ swappiness: 10"
        echo "  ▸ vfs_cache_pressure: 50"
        read -rp "Использовать значения по умолчанию (10 / 50)? (Y/n): " yn
        if [[ "$yn" =~ ^[Nn]$ ]]; then
          clear
          echo -e "${CLR_CYAN}Пояснение параметров:${CLR_RESET}"
          echo ""
          echo "  ▸ swappiness — как активно будет использоваться swap"
          echo "  ▸ vfs_cache_pressure — как долго хранится файловый кэш"
          echo ""
          sw=$(read_number "Введите swappiness (0–100): " 0 100)
          cpv=$(read_number "Введите vfs_cache_pressure (1–200): " 1 200)
        else
          sw=10
          cpv=50
        fi

        echo -e "${CLR_YELLOW}Создание swap файла (${sz}G). Это может занять несколько минут...${CLR_RESET}"
        echo ""
        if create_swap_file_with_progress "$sz"; then
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

# ---------- run ----------
show_system_info

if get_swap_size_bytes | grep -qv '^0$'; then
  # swap exists
  main_menu_with_swap
else
  main_menu_no_swap
fi

# end
