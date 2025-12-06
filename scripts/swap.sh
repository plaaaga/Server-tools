#!/bin/bash

clear

# ====== COLORS ======
GREEN="\e[32m"
CYAN="\e[36m"
GRAY="\e[90m"
RESET="\e[0m"

# ====== FUNCTIONS ======
show_header() {
    clear
    echo -e "${CYAN}"
    echo -e "🧊  Universal SWAP Manager — удобный модуль"
    echo -e "${RESET}"

    echo -e "${GRAY}📌 Информация о системе:${RESET}"

    # RAM info
    RAM_TOTAL=$(free -h | awk '/Mem:/ {print $2}')
    echo -e "  ▸ RAM: ${CYAN}$RAM_TOTAL${RESET}"

    # Disk info
    DISK_TOTAL=$(df -h / | awk 'NR==2 {print $2}')
    echo -e "  ▸ Disk /: ${CYAN}$DISK_TOTAL${RESET}"

    # Swap info
    if swapon --show | grep -q "swapfile"; then
        SWAP_SIZE=$(swapon --show --bytes | awk 'NR==2 {printf "%.1fG", $3/1024/1024/1024}')
        echo -e "  ▸ Swap: ${CYAN}$SWAP_SIZE${RESET}"
    else
        echo -e "  ▸ Swap: ${CYAN}не найден${RESET}"
    fi

    # sysctl parameters
    SWAPPINESS=$(sysctl -n vm.swappiness 2>/dev/null)
    CACHE_PRESSURE=$(sysctl -n vm.vfs_cache_pressure 2>/dev/null)
    echo -e "  ▸ swappiness: ${CYAN}${SWAPPINESS}${RESET}"
    echo -e "  ▸ vfs_cache_pressure: ${CYAN}${CACHE_PRESSURE}${RESET}"

    echo ""
}

apply_sysctl() {
    sed -i '/vm.swappiness/d' /etc/sysctl.conf
    sed -i '/vm.vfs_cache_pressure/d' /etc/sysctl.conf

    echo "vm.swappiness = $1" >> /etc/sysctl.conf
    echo "vm.vfs_cache_pressure = $2" >> /etc/sysctl.conf

    sysctl -p >/dev/null 2>&1
}

show_params_help() {
    clear
    echo -e "${CYAN}Пояснение параметров:${RESET}"
    echo ""
    echo "  ▸ swappiness — как активно будет использоваться swap"
    echo "       Значения:"
    echo "       0–10: Почти не использовать swap (OOM protection)"
    echo "       10–20: Оптимально для серверов и нод"
    echo "       30–40: Нормально для десктопов"
    echo "       60: Значение по умолчанию в Ubuntu"
    echo "       80–100: Очень агрессивное свопирование"
    echo ""
    echo "  ▸ vfs_cache_pressure — как долго хранится файловый кэш"
    echo "       Значения:"
    echo "       1–50: Кэш хранится дольше (лучше для серверов/нод)"
    echo "       100: Значение по умолчанию в Ubuntu"
    echo "       150–200: Быстрое очищение кэша"
    echo ""
}

create_or_recreate_swap() {
    clear
    echo -ne "Введите размер swap файла в ГБ (например 8): "
    read SWAP_GB

    if swapon --show | grep -q "swapfile"; then
        echo -e "${GRAY}Отключаю и удаляю существующий swap...${RESET}"
        swapoff -a
        rm -f /swapfile
    fi

    echo ""
    echo "По умолчанию используются параметры:"
    echo "  ▸ swappiness: 10"
    echo "  ▸ vfs_cache_pressure: 50"
    echo -ne "Использовать значения по умолчанию (10 / 50)? (Y/n): "
    read DEF

    if [[ "$DEF" =~ ^[Nn]$ ]]; then
        show_params_help
        echo -ne "Введите swappiness (0–100): "
        read SW
        echo -ne "Введите vfs_cache_pressure (1–200): "
        read CP
    else
        SW=10
        CP=50
    fi

    echo -e "${GRAY}Создание нового swap...${RESET}"
    dd if=/dev/zero of=/swapfile bs=1G count=$SWAP_GB status=none
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile

    if ! grep -q "/swapfile" /etc/fstab; then
        echo "/swapfile none swap sw 0 0" >> /etc/fstab
    fi

    apply_sysctl $SW $CP

    clear
    echo -e "${GREEN}✔ Новый swap (${SWAP_GB}G) создан и активирован.${RESET}"
    echo -e "${GREEN}✔ Параметры применены: swappiness=${SW}, vfs_cache_pressure=${CP}${RESET}"
}

tune_existing_params() {
    show_params_help

    echo "Выбор:"
    echo "1) Применить значения по умолчанию (10 / 50) — рекомендовано для нод"
    echo "2) Ввести свои значения"
    echo "3) Отмена"
    echo -ne "Выбор [1-3]: "
    read CH

    case "$CH" in
        1)
            apply_sysctl 10 50
            clear
            echo -e "${GREEN}✔ Параметры применены: swappiness=10, vfs_cache_pressure=50${RESET}"
        ;;
        2)
            echo -ne "Введите swappiness (0–100): "
            read SW
            echo -ne "Введите vfs_cache_pressure (1–200): "
            read CP
            apply_sysctl $SW $CP
            clear
            echo -e "${GREEN}✔ Параметры применены: swappiness=${SW}, vfs_cache_pressure=${CP}${RESET}"
        ;;
        3)
            clear
        ;;
    esac
}

# ====== MAIN MENU ======
show_header

if ! swapon --show | grep -q "swapfile"; then
    echo -e "${CYAN}Swap не найден.${RESET}"
    echo ""
    echo "Выберите действие:"
    echo "1) Создать swap"
    echo "2) Выход"
    echo -ne "Выбор [1-2]: "
    read CH

    case "$CH" in
        1) create_or_recreate_swap ;;
        *) clear ;;
    esac

    exit 0
fi

# If swap exists
echo "Выберите действие:"
echo "1) Оставить существующий swap"
echo "2) Настроить параметры (swappiness / cache_pressure)"
echo "3) Создать / пересоздать swap"
echo "4) Выход"
echo -ne "Выбор [1-4]: "
read CH

case "$CH" in
    1) clear ;;
    2) tune_existing_params ;;
    3) create_or_recreate_swap ;;
    4) clear ;;
esac
