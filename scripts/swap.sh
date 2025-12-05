print_header() {
    clear
    echo -e "${CLR_INFO}"
    cat << "EOF"
   _____                             __  __          
  / ___/____  ____ _________  ____ _/ /_/ /___  _____
  \__ \/ __ \/ __ `/ ___/ _ \/ __ `/ __/ / __ \/ ___/
 ___/ / /_/ / /_/ (__  )  __/ /_/ / /_/ / /_/ (__  ) 
/____/ .___/\__,_/____/\___/\__,_/\__/_/\____/____/  
    /_/            Universal SWAP Manager
EOF
    echo -e "${CLR_RESET}"
    echo -e "${CLR_INFO}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CLR_RESET}"
    echo -e "${CLR_INFO}   🧊  Утилита управления SWAP для серверов   ${CLR_RESET}"
    echo -e "${CLR_INFO}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CLR_RESET}"
}

#!/usr/bin/env bash
# swap.sh — Универсальный модуль управления SWAP
# Работает на Ubuntu 22.04 / 24.04 и подобных системах
# Надёжно: проверяет, даёт выбор, защищает /etc/fstab, применяет sysctl

set -euo pipefail

# --------- цвета ----------
CLR_INFO='\033[1;34m'
CLR_SUCCESS='\033[1;32m'
CLR_WARNING='\033[1;33m'
CLR_ERROR='\033[1;31m'
CLR_RESET='\033[0m'

SWAPFILE="/swapfile"
DEFAULT_SWAPPINESS=10
DEFAULT_CACHE=50

# ---------- утилиты ----------
command_exists() { command -v "$1" >/dev/null 2>&1; }

human_size() {
    # вход: байты -> человеко-читаемо
    if ! command_exists numfmt; then
        # примитивный fallback
        awk 'function human(x){
            s="B K M G T"; n=split(s,a," ");
            for(i=n;i>1;i--){ if(x>=1024^(i-1)){ printf("%.2f %s\n", x/(1024^(i-1)), a[i]); return } }
            print x" B"
        }
        {human($1)}' <<<"$1"
    else
        numfmt --to=iec --format="%.2f" "$1"
    fi
}

# ---------- вывод заголовка ----------
print_header() {
    clear
    echo -e "${CLR_INFO}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CLR_RESET}"
    echo -e "${CLR_INFO}   🧊  Universal SWAP Manager — удобный модуль${CLR_RESET}"
    echo -e "${CLR_INFO}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CLR_RESET}"
}

# ---------- показать статус swap ----------
show_swap_status() {
    echo
    echo -e "${CLR_INFO}--- Текущий статус swap ---${CLR_RESET}"
    swapon --show || echo -e "${CLR_WARNING}swap не активен${CLR_RESET}"
    echo
    free -h
    echo
}

# ---------- узнать, активен ли swap ----------
is_swap_active() {
    swapon --show | awk 'NR>1{print $0}' | grep -q . && return 0 || return 1
}

# ---------- узнать путевые/тип swap записи ----------
get_swap_entries() {
    # вывод: строка(и) из swapon --show (заголовок включён)
    swapon --show || true
}

# ---------- проверить, есть ли /swapfile в списке ----------
swapfile_active() {
    swapon --show | awk 'NR>1{print $0}' | awk '{print $1}' | grep -qw "$SWAPFILE" && return 0 || return 1
}

# ---------- безопасное удаления записи /swapfile из /etc/fstab ----------
remove_swapfile_from_fstab() {
    if grep -qE "(^|[[:space:]])${SWAPFILE}([[:space:]]|$)" /etc/fstab 2>/dev/null; then
        sudo sed -i "\|${SWAPFILE}|d" /etc/fstab
    fi
}

# ---------- применение sysctl параметров ----------
apply_sysctl() {
    local sw="$1"
    local cache="$2"
    echo "vm.swappiness=${sw}" | sudo tee /etc/sysctl.d/99-swappiness.conf >/dev/null
    echo "vm.vfs_cache_pressure=${cache}" | sudo tee /etc/sysctl.d/99-vfs-cache.conf >/dev/null
    sudo sysctl -p /etc/sysctl.d/99-swappiness.conf >/dev/null || true
    sudo sysctl -p /etc/sysctl.d/99-vfs-cache.conf >/dev/null || true
}

# ---------- создание swap файла ----------
create_swapfile() {
    local size_g="$1"

    echo -e "${CLR_INFO}▶ Подготовка к созданию swap ${size_g}G...${CLR_RESET}"

    # Отключаем текущий swap (включая возможный /swapfile)
    sudo swapoff -a 2>/dev/null || true

    # Удаляем старый /swapfile, если есть
    sudo rm -f "$SWAPFILE" 2>/dev/null || true

    # Попытка fallocate, иначе dd
    if command_exists fallocate; then
        sudo fallocate -l "${size_g}G" "$SWAPFILE"
    else
        echo -e "${CLR_WARNING}fallocate не доступен — используем dd (может занять время)${CLR_RESET}"
        sudo dd if=/dev/zero of="$SWAPFILE" bs=1M count=$((size_g * 1024)) status=progress
    fi

    sudo chmod 600 "$SWAPFILE"
    sudo mkswap "$SWAPFILE" >/dev/null
    sudo swapon "$SWAPFILE"

    # Обновляем fstab (убираем дубли и добавляем)
    sudo sed -i "\|${SWAPFILE}|d" /etc/fstab 2>/dev/null || true
    echo "${SWAPFILE} none swap sw 0 0" | sudo tee -a /etc/fstab >/dev/null

    echo -e "${CLR_SUCCESS}✔ Swap ${size_g}G создан и включён (${SWAPFILE}).${CLR_RESET}"
    show_swap_status
}

# ---------- удалить swap полностью ----------
delete_swapfile() {
    echo -e "${CLR_WARNING}▶ Отключаю и удаляю swap...${CLR_RESET}"
    sudo swapoff -a 2>/dev/null || true
    sudo rm -f "$SWAPFILE" 2>/dev/null || true
    remove_swapfile_from_fstab
    echo -e "${CLR_SUCCESS}✔ Swap отключён и файл удалён.${CLR_RESET}"
}

# ---------- валидация чисел ----------
read_numeric() {
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
        echo -e "${CLR_ERROR}Ошибка: введите число в диапазоне ${min}-${max}.${CLR_RESET}"
    done
}

# ---------- меню если swap уже есть ----------
existing_swap_menu() {
    print_header
    echo -e "${CLR_INFO}Обнаружен активный swap. Информация:${CLR_RESET}"
    get_swap_entries
    echo
    free -h
    echo
    echo "Выберите действие:"
    echo "1) Оставить существующий swap (ничего не делать)"
    echo "2) Настроить параметры swappiness / vfs_cache_pressure"
    echo "3) Пересоздать swap (удалить текущий и создать новый /swapfile)"
    echo "4) Удалить swap (отключить и удалить файл / запись)"
    echo "5) Отмена"
    read -rp "Ваш выбор [1-5]: " choice_existing
    case "$choice_existing" in
        1) echo "Оставляем существующий swap. Выход."; exit 0 ;;
        2) configure_params_interactive && exit 0 ;;
        3)
            echo -e "${CLR_WARNING}Пересоздаём swap: сначала отключим существующий...${CLR_RESET}"
            sudo swapoff -a || true
            sudo rm -f "$SWAPFILE" 2>/dev/null || true
            remove_swapfile_from_fstab
            echo "Введите желаемый размер нового /swapfile (в ГБ):"
            SZ=$(read_numeric "Размер (ГБ): " 1 1024)
            choose_and_apply_params_then_create "$SZ"
            exit 0
            ;;
        4)
            delete_swapfile
            exit 0
            ;;
        5) echo "Отмена."; exit 0 ;;
        *) echo -e "${CLR_WARNING}Неверный выбор, выходим.${CLR_RESET}"; exit 1 ;;
    esac
}

# ---------- конфигурирование параметров без пересоздания ----------
configure_params_interactive() {
    print_header
    echo -e "${CLR_INFO}Настройка параметров swappiness и vfs_cache_pressure${CLR_RESET}"
    echo
    echo -e "Текущие значения (если настроены в /etc/sysctl.d):"
    echo "swappiness: $(sysctl -n vm.swappiness 2>/dev/null || echo 'не задано')"
    echo "vfs_cache_pressure: $(sysctl -n vm.vfs_cache_pressure 2>/dev/null || echo 'не задано')"
    echo
    echo "Хотите применить значения по умолчанию для нод?"
    echo " 1) Да — swappiness=${DEFAULT_SWAPPINESS}, vfs_cache_pressure=${DEFAULT_CACHE}"
    echo " 2) Ввести свои значения"
    echo " 3) Отмена"
    read -rp "Выбор [1-3]: " cfg_choice
    case "$cfg_choice" in
        1)
            apply_sysctl "${DEFAULT_SWAPPINESS}" "${DEFAULT_CACHE}"
            echo -e "${CLR_SUCCESS}✔ Параметры применены: swappiness=${DEFAULT_SWAPPINESS}, vfs_cache_pressure=${DEFAULT_CACHE}${CLR_RESET}"
            return 0
            ;;
        2)
            SWAPPINESS=$(read_numeric "Введите swappiness (0-100): " 0 100)
            CACHE=$(read_numeric "Введите vfs_cache_pressure (1-200): " 1 200)
            apply_sysctl "$SWAPPINESS" "$CACHE"
            echo -e "${CLR_SUCCESS}✔ Параметры применены: swappiness=${SWAPPINESS}, vfs_cache_pressure=${CACHE}${CLR_RESET}"
            return 0
            ;;
        3) echo "Отмена."; return 1 ;;
        *) echo "Неверный выбор."; return 1 ;;
    esac
}

# ---------- вспомогательная функция выбора параметров и создания ----------
choose_and_apply_params_then_create() {
    local size_g="$1"

    print_header
    echo -e "Создаём swap размером ${size_g}G."
    echo
    echo -e "${CLR_INFO}Параметры по умолчанию:${CLR_RESET}"
    echo -e "  ▸ Как активно будет использоваться swap (рекомендуемо для нод): ${DEFAULT_SWAPPINESS}"
    echo -e "  ▸ Как долго хранится файловый кэш в RAM: ${DEFAULT_CACHE}"
    echo
    echo -e "Использовать параметры по умолчанию? (Y/n)"
    read -r use_defaults_local
    use_defaults_local=${use_defaults_local,,}
    if [[ "$use_defaults_local" == "n" || "$use_defaults_local" == "no" ]]; then
        SWAPPINESS=$(read_numeric "Введите swappiness (0-100): " 0 100)
        CACHE=$(read_numeric "Введите vfs_cache_pressure (1-200): " 1 200)
    else
        SWAPPINESS=$DEFAULT_SWAPPINESS
        CACHE=$DEFAULT_CACHE
    fi

    create_swapfile "$size_g"
    apply_sysctl "$SWAPPINESS" "$CACHE"
    echo -e "${CLR_SUCCESS}✔ Swap создан и параметры применены.${CLR_RESET}"
}

# ---------- главное меню ----------
main_menu() {
    print_header
    echo -e "Выберите действие:"
    echo -e "1) Проверить статус swap"
    echo -e "2) Создать новый /swapfile"
    echo -e "3) Пересоздать /swapfile (удалить старый и создать новый)"
    echo -e "4) Удалить swap (disable + remove)"
    echo -e "5) Настроить параметры swappiness / vfs_cache_pressure"
    echo -e "6) Выход"
    read -rp "Выбор [1-6]: " main_choice
    case "$main_choice" in
        1) show_swap_status ;;
        2)
            SZ=$(read_numeric "Введите размер swap (ГБ): " 1 4096)
            choose_and_apply_params_then_create "$SZ"
            ;;
        3)
            echo -e "${CLR_WARNING}Пересоздать: сначала отключим и удалим существующий swap (если есть).${CLR_RESET}"
            sudo swapoff -a || true
            sudo rm -f "$SWAPFILE" 2>/dev/null || true
            remove_swapfile_from_fstab
            SZ=$(read_numeric "Введите новый размер swap (ГБ): " 1 4096)
            choose_and_apply_params_then_create "$SZ"
            ;;
        4) delete_swapfile ;;
        5) configure_params_interactive ;;
        6) echo "Выход."; exit 0 ;;
        *) echo -e "${CLR_WARNING}Неверный выбор.${CLR_RESET}" ;;
    esac
}

# ---------- основной сценарий ----------
print_header

if is_swap_active; then
    # если активен swap и это /swapfile или другой swap
    if swapfile_active; then
        # активен /swapfile
        echo -e "${CLR_INFO}Обнаружен активный swap-файл: ${SWAPFILE}${CLR_RESET}"
        show_swap_status
        echo
        echo "Хотите управлять существующим swap-файлом?"
        echo "1) Открыть расширенное меню управления swap"
        echo "2) Выйти"
        read -rp "Выбор [1-2]: " a
        if [[ "$a" == "1" ]]; then
            existing_swap_menu
        else
            echo "Выход."; exit 0
        fi
    else
        # активен swap но не /swapfile — может быть swap partition или другой файл
        echo -e "${CLR_INFO}Обнаружен активный swap (не ${SWAPFILE}):${CLR_RESET}"
        get_swap_entries
        echo
        echo "Варианты действий:"
        echo "1) Оставить как есть"
        echo "2) Отключить все swap и создать новый /swapfile"
        echo "3) Настроить параметры swappiness / vfs_cache_pressure"
        echo "4) Выход"
        read -rp "Выбор [1-4]: " b
        case "$b" in
            1) echo "Оставляем как есть. Выход."; exit 0 ;;
            2)
                sudo swapoff -a || true
                remove_swapfile_from_fstab
                SZ=$(read_numeric "Введите размер нового /swapfile (ГБ): " 1 4096)
                choose_and_apply_params_then_create "$SZ"
                exit 0
                ;;
            3) configure_params_interactive; exit 0 ;;
            4) echo "Выход."; exit 0 ;;
            *) echo "Неверный выбор. Выход."; exit 1 ;;
        esac
    fi
else
    # swap не активен
    echo -e "${CLR_INFO}Swap не найден${CLR_RESET}"
    echo
    main_menu
fi

# Если дошли сюда, заканчиваем
echo -e "${CLR_SUCCESS}Готово.${CLR_RESET}"
exit 0
