#!/bin/bash

# Цвета
CLR_GREEN="\e[32m"
CLR_RED="\e[31m"
CLR_YELLOW="\e[33m"
CLR_BLUE="\e[36m"
CLR_RESET="\e[0m"

clear

# ==========================================
# ЛОГОТИП
# ==========================================
echo -e "${CLR_BLUE}"
cat << "EOF"
🧊  Universal SWAP Manager — удобный модуль
EOF
echo -e "${CLR_RESET}"


# ==========================================
# ПРИМЕНЕНИЕ ПАРАМЕТРОВ СИСТЕМЫ
# ==========================================
apply_sysctl() {
    sysctl -w vm.swappiness=$1 >/dev/null 2>&1
    sysctl -w vm.vfs_cache_pressure=$2 >/dev/null 2>&1

    sed -i '/vm.swappiness/d' /etc/sysctl.conf
    sed -i '/vm.vfs_cache_pressure/d' /etc/sysctl.conf

    echo "vm.swappiness=$1" >> /etc/sysctl.conf
    echo "vm.vfs_cache_pressure=$2" >> /etc/sysctl.conf
}

# ==========================================
# МЕНЮ НАСТРОЙКИ swappiness / vfs_cache_pressure
# ==========================================
set_sysctl_params() {
    clear
    echo -e "${CLR_BLUE}Пояснение параметров:${CLR_RESET}"

    echo -e "  ▸ ${CLR_YELLOW}swappiness${CLR_RESET} — как активно будет использоваться swap"
    echo -e "       Значения:"
    echo -e "       0–10: Почти не использовать swap (только при реальном OOM)"
    echo -e "       10–20: Оптимально для серверов и нод (минимум лагов)"
    echo -e "       30–40: Нормально для десктопов (баланс)"
    echo -e "       60: Значение по умолчанию в Ubuntu"
    echo -e "       80–100: Агрессивное свопирование (маленькая RAM)"
    echo ""

    echo -e "  ▸ ${CLR_YELLOW}vfs_cache_pressure${CLR_RESET} — как долго хранится файловый кэш в RAM"
    echo -e "       Значения:"
    echo -e "       1–50: Кэш держится дольше, лучше для серверов/нод"
    echo -e "       100: Значение по умолчанию в Ubuntu"
    echo -e "       150–200: Сильно ускоренное очищение кэша"
    echo ""

    echo -e "${CLR_GREEN}Выбор:${CLR_RESET}"
    echo "1) Применить значения по умолчанию (swappiness=10, vfs_cache_pressure=50) — рекомендовано для нод"
    echo "2) Ввести свои значения"
    echo "3) Отмена"
    read -rp "Выбор [1-3]: " opt

    case $opt in
        1)
            apply_sysctl 10 50
            clear
            echo -e "${CLR_GREEN}✔ Параметры применены: swappiness=10, vfs_cache_pressure=50${CLR_RESET}"
            return 0
            ;;
        2)
            read -rp "Введите swappiness (0–100): " SWP
            read -rp "Введите vfs_cache_pressure (1–200): " VFS
            apply_sysctl "$SWP" "$VFS"
            clear
            echo -e "${CLR_GREEN}✔ Параметры применены: swappiness=$SWP, vfs_cache_pressure=$VFS${CLR_RESET}"
            return 0
            ;;
        3)
            clear
            echo "Отмена."
            return 0
            ;;
        *)
            clear
            echo -e "${CLR_RED}Некорректный ввод.${CLR_RESET}"
            return 1
            ;;
    esac
}

# ==========================================
# СОЗДАНИЕ SWAP
# ==========================================
create_swap() {
    echo ""
    read -rp "Введите размер swap файла в ГБ (например 8): " SIZE

    echo ""
    echo -e "${CLR_YELLOW}По умолчанию создается swap с параметрами:${CLR_RESET}"
    echo "  ▸ Как активно будет использоваться swap: 10"
    echo "  ▸ Как долго хранится файловый кэш в RAM: 50"
    read -rp "Использовать значения по умолчанию? (Y/n): " use_default

    if [[ "$use_default" =~ ^[Nn]$ ]]; then
        set_sysctl_params
    else
        apply_sysctl 10 50
    fi

    swapoff -a 2>/dev/null
    rm -f /swapfile 2>/dev/null

    fallocate -l ${SIZE}G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile

    if ! grep -q "/swapfile" /etc/fstab; then
        echo "/swapfile none swap sw 0 0" >> /etc/fstab
    fi

    clear
    echo -e "${CLR_GREEN}✔ Swap размером ${SIZE}G создан и активирован.${CLR_RESET}"
    swapon --show
}

# ==========================================
# УДАЛЕНИЕ SWAP
# ==========================================
delete_swap() {
    swapoff -a
    sed -i '/\/swapfile/d' /etc/fstab
    rm -f /swapfile

    clear
    echo -e "${CLR_GREEN}✔ Swap удалён.${CLR_RESET}"
}

# ==========================================
# ОСНОВНАЯ ЛОГИКА
# ==========================================

if swapon --show | grep -q "/"; then
    echo -e "${CLR_GREEN}✔ Обнаружен активный swap. Информация:${CLR_RESET}"
    swapon --show
    free -h

    echo ""
    echo "Выберите действие:"
    echo "1) Оставить существующий swap (ничего не делать)"
    echo "2) Настроить параметры swappiness / vfs_cache_pressure в существующем swap"
    echo "3) Пересоздать swap (удалить текущий и создать новый /swapfile)"
    echo "4) Удалить swap (отключить и удалить файл / запись)"
    echo "5) Отмена"
    read -rp "Ваш выбор [1-5]: " CHOICE

    case $CHOICE in
        1)
            clear
            exit 0
            ;;
        2)
            set_sysctl_params
            ;;
        3)
            clear
            create_swap
            ;;
        4)
            delete_swap
            ;;
        5)
            clear
            exit 0
            ;;
        *)
            clear
            echo -e "${CLR_RED}Некорректный ввод.${CLR_RESET}"
            ;;
    esac

else
    echo -e "${CLR_YELLOW}Swap не найден.${CLR_RESET}"
    echo "Выберите действие:"
    echo "1) Проверить статус swap"
    echo "2) Создать новый /swapfile"
    echo "3) Выход"
    read -rp "Выбор [1-3]: " CHOICE2

    case $CHOICE2 in
        1)
            clear
            swapon --show
            ;;
        2)
            clear
            create_swap
            ;;
        3)
            clear
            exit 0
            ;;
        *)
            clear
            echo -e "${CLR_RED}Некорректный ввод.${CLR_RESET}"
            ;;
    esac
fi
