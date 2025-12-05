#!/bin/bash

# ==============================
# Цвета для терминала
# ==============================
CLR_SUCCESS='\033[1;32m'
CLR_INFO='\033[1;34m'
CLR_WARNING='\033[1;33m'
CLR_ERROR='\033[1;31m'
CLR_RESET='\033[0m'

SWAPFILE="/swapfile"

# ==============================
# Логотип
# ==============================
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

# ==============================
# Проверка существующего swap
# ==============================
check_swap() {
    if swapon --show | grep -q "/" ; then
        echo -e "\n${CLR_SUCCESS}✔ Обнаружен активный swap. Информация:${CLR_RESET}"
        swapon --show
        echo
        free -h
        echo
        return 0
    else
        return 1
    fi
}

# ==============================
# Настройка параметров swappiness и vfs_cache_pressure
# ==============================
configure_params() {
    echo -e "\nВы можете применить значения по умолчанию для нод или задать свои."
    echo -e "Пояснение параметров:"
    echo -e "  ▸ swappiness — как активно будет использоваться swap (0–10 почти не использовать, 10–20 оптимально для нод)"
    echo -e "  ▸ vfs_cache_pressure — как долго будет храниться файловый кэш в RAM (50 рекомендовано для нод)\n"

    echo "Выбор:"
    echo "1) Применить значения по умолчанию (swappiness=10, vfs_cache_pressure=50)"
    echo "2) Ввести свои значения"
    echo "3) Отмена"
    read -rp "Выбор [1-3]: " choice

    case $choice in
        1)
            swappiness=10
            vfs_cache_pressure=50
            ;;
        2)
            read -rp "Введите swappiness (0–100, 10 рекомендовано для нод): " swappiness
            read -rp "Введите vfs_cache_pressure (1–200, 50 рекомендовано для нод): " vfs_cache_pressure
            ;;
        3) echo "Отмена"; return ;;
        *) echo "Неверный выбор"; return ;;
    esac

    echo -e "Применяем параметры: swappiness=$swappiness, vfs_cache_pressure=$vfs_cache_pressure"
    echo "vm.swappiness=$swappiness" | sudo tee /etc/sysctl.d/99-swappiness.conf
    echo "vm.vfs_cache_pressure=$vfs_cache_pressure" | sudo tee /etc/sysctl.d/99-vfs-cache.conf
    sudo sysctl -p /etc/sysctl.d/99-swappiness.conf
    sudo sysctl -p /etc/sysctl.d/99-vfs-cache.conf
    echo -e "${CLR_SUCCESS}✅ Параметры применены.${CLR_RESET}"
}

# ==============================
# Создание swap
# ==============================
create_swap() {
    read -rp "Введите размер swap файла в ГБ (например 8): " swapsize
    echo -e "\nПо умолчанию создается swap с параметрами:"
    echo "  ▸ Как активно будет использоваться swap: 10"
    echo "  ▸ Как долго хранится файловый кэш в RAM: 50"
    read -rp "Использовать значения по умолчанию? (Y/n): " yn
    case $yn in
        [Yy]|"") swappiness=10; vfs_cache_pressure=50 ;;
        *) 
            read -rp "Введите swappiness (0–100, 10 рекомендовано для нод): " swappiness
            read -rp "Введите vfs_cache_pressure (1–200, 50 рекомендовано для нод): " vfs_cache_pressure
            ;;
    esac

    # Отключаем старый swap, если есть
    sudo swapoff -a 2>/dev/null
    [ -f "$SWAPFILE" ] && sudo rm -f "$SWAPFILE"

    # Создаем swap
    sudo fallocate -l "${swapsize}G" "$SWAPFILE"
    sudo chmod 600 "$SWAPFILE"
    sudo mkswap "$SWAPFILE"
    sudo swapon "$SWAPFILE"

    # fstab
    if grep -q "$SWAPFILE" /etc/fstab; then
        sudo sed -i "/$SWAPFILE/d" /etc/fstab
    fi
    echo "$SWAPFILE none swap sw 0 0" | sudo tee -a /etc/fstab

    # Применяем параметры
    echo "vm.swappiness=$swappiness" | sudo tee /etc/sysctl.d/99-swappiness.conf
    echo "vm.vfs_cache_pressure=$vfs_cache_pressure" | sudo tee /etc/sysctl.d/99-vfs-cache.conf
    sudo sysctl -p /etc/sysctl.d/99-swappiness.conf
    sudo sysctl -p /etc/sysctl.d/99-vfs-cache.conf

    echo -e "${CLR_SUCCESS}✅ Swap размером ${swapsize}G создан и активирован.${CLR_RESET}"
    swapon --show
    free -h
}

# ==============================
# Меню при наличии swap
# ==============================
menu_existing_swap() {
    echo
    echo "Выберите действие:"
    echo "1) Оставить существующий swap (ничего не делать)"
    echo "2) Настроить параметры swappiness / vfs_cache_pressure в существующем swap"
    echo "3) Пересоздать swap (удалить текущий и создать новый /swapfile)"
    echo "4) Удалить swap (отключить и удалить файл / запись)"
    echo "5) Отмена"
    read -rp "Ваш выбор [1-5]: " choice

    case $choice in
        1) echo "Ничего не делаем";;
        2) configure_params;;
        3) create_swap;;
        4)
            sudo swapoff -a
            [ -f "$SWAPFILE" ] && sudo rm -f "$SWAPFILE"
            sudo sed -i "/$SWAPFILE/d" /etc/fstab
            echo -e "${CLR_SUCCESS}Swap удален.${CLR_RESET}";;
        5) echo "Отмена";;
        *) echo "Неверный выбор";;
    esac
}

# ==============================
# Меню при отсутствии swap
# ==============================
menu_no_swap() {
    echo
    echo "Swap не найден. Выберите действие:"
    echo "1) Проверить статус swap"
    echo "2) Создать новый /swapfile"
    echo "3) Выход"
    read -rp "Выбор [1-3]: " choice

    case $choice in
        1)
            echo "Статус swap:"
            swapon --show
            free -h
            ;;
        2) create_swap;;
        3) echo "Выход"; exit 0;;
        *) echo "Неверный выбор";;
    esac
}

# ==============================
# Основной блок
# ==============================
print_header
if check_swap; then
    menu_existing_swap
else
    menu_no_swap
fi
