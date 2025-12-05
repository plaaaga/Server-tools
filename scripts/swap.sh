#!/bin/bash
# ==========================================
# swap.sh — универсальный модуль для управления swap
# ==========================================

# Цвета
CLR_SUCCESS='\033[1;32m'
CLR_INFO='\033[1;34m'
CLR_WARNING='\033[1;33m'
CLR_ERROR='\033[1;31m'
CLR_RESET='\033[0m'

SWAPFILE="/swapfile"

show_logo() {
    echo -e "${CLR_INFO}"
    echo "=========================================="
    echo "   Nodes, easy installation from Plagiarism"
    echo "=========================================="
    echo -e "${CLR_RESET}"
}

check_swap() {
    if swapon --show | grep -q "$SWAPFILE"; then
        echo -e "\n${CLR_SUCCESS}✔ Обнаружен активный swap. Информация:${CLR_RESET}"
        swapon --show
        free -h
        return 0
    else
        return 1
    fi
}

configure_params() {
    echo -e "\nВы можете применить значения по умолчанию для нод или задать свои."

    echo -e "\nПояснение параметров:"
    echo -e "  ▸ swappiness — как активно будет использоваться swap (0–10 почти не использовать, 10–20 оптимально для нод)"
    echo -e "       Значения:"
    echo -e "       0–10: Почти не использовать swap (только при реальном OOM)"
    echo -e "       10–20: Оптимально для серверов и нод (минимум лагов)"
    echo -e "       30–40: Нормально для десктопов (баланс)"
    echo -e "       60: Значение по умолчанию в Ubuntu"
    echo -e "       80–100: Агрессивное свопирование, только для систем с маленькой RAM\n"

    echo -e "  ▸ vfs_cache_pressure — как долго хранится файловый кэш в RAM (50 рекомендовано для нод)"
    echo -e "       Значения:"
    echo -e "       1–50: Кэш держится дольше, лучше для серверов/нод"
    echo -e "       100: Ubuntu default, средний уровень"
    echo -e "       150–200: Более агрессивное очищение кэша\n"

    echo "Выбор:"
    echo "1) Применить значения по умолчанию (swappiness=10, vfs_cache_pressure=50)"
    echo "2) Ввести свои значения (рекомендовано для нод)"
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

    echo -e "\nПрименяем параметры: swappiness=$swappiness, vfs_cache_pressure=$vfs_cache_pressure"
    echo "vm.swappiness=$swappiness" | sudo tee /etc/sysctl.d/99-swappiness.conf > /dev/null
    echo "vm.vfs_cache_pressure=$vfs_cache_pressure" | sudo tee /etc/sysctl.d/99-vfs-cache.conf > /dev/null
    sudo sysctl -p /etc/sysctl.d/99-swappiness.conf > /dev/null
    sudo sysctl -p /etc/sysctl.d/99-vfs-cache.conf > /dev/null
    echo -e "${CLR_SUCCESS}✅ Параметры применены.${CLR_RESET}"
}

create_swap() {
    read -rp "Введите размер swap файла в ГБ (например 8): " size_gb
    size_bytes=$((size_gb * 1024 * 1024 * 1024))

    echo -e "\nПо умолчанию создается swap с параметрами:"
    echo "  ▸ Как активно будет использоваться swap: 10"
    echo "  ▸ Как долго хранится файловый кэш в RAM: 50"
    read -rp "Использовать значения по умолчанию? (Y/n): " use_default

    if [[ "$use_default" =~ ^[Yy]$ || -z "$use_default" ]]; then
        swappiness=10
        vfs_cache_pressure=50
    else
        configure_params
    fi

    # Создание swap файла
    sudo swapoff -a 2>/dev/null
    [ -f "$SWAPFILE" ] && sudo rm -f "$SWAPFILE"
    sudo fallocate -l "$size_bytes" "$SWAPFILE"
    sudo chmod 600 "$SWAPFILE"
    sudo mkswap "$SWAPFILE" > /dev/null
    sudo swapon "$SWAPFILE"
    if ! grep -q "$SWAPFILE" /etc/fstab; then
        echo "$SWAPFILE none swap sw 0 0" | sudo tee -a /etc/fstab > /dev/null
    fi

    # Применяем параметры
    echo "vm.swappiness=$swappiness" | sudo tee /etc/sysctl.d/99-swappiness.conf > /dev/null
    echo "vm.vfs_cache_pressure=$vfs_cache_pressure" | sudo tee /etc/sysctl.d/99-vfs-cache.conf > /dev/null
    sudo sysctl -p /etc/sysctl.d/99-swappiness.conf > /dev/null
    sudo sysctl -p /etc/sysctl.d/99-vfs-cache.conf > /dev/null

    echo -e "${CLR_SUCCESS}✅ Swap размером ${size_gb}G создан и активирован.${CLR_RESET}"
    swapon --show
    free -h
}

remove_swap() {
    sudo swapoff -a
    [ -f "$SWAPFILE" ] && sudo rm -f "$SWAPFILE"
    sudo sed -i "\|$SWAPFILE|d" /etc/fstab
    echo -e "${CLR_SUCCESS}✅ Swap удален.${CLR_RESET}"
}

# =========================
# Основное меню
# =========================
show_logo

while true; do
    if check_swap; then
        echo -e "\nВыберите действие:"
        echo "1) Оставить существующий swap (ничего не делать)"
        echo "2) Настроить параметры swappiness / vfs_cache_pressure в существующем swap"
        echo "3) Пересоздать swap (удалить текущий и создать новый /swapfile)"
        echo "4) Удалить swap (отключить и удалить файл / запись)"
        echo "5) Отмена"
        read -rp "Ваш выбор [1-5]: " choice

        case $choice in
            1) echo "Ничего не делаем"; break ;;
            2) configure_params ;;
            3) create_swap ;;
            4) remove_swap ;;
            5) echo "Отмена"; exit 0 ;;
            *) echo "Неверный выбор" ;;
        esac
    else
        echo -e "\nSwap не найден. Выберите действие:"
        echo "1) Проверить статус swap"
        echo "2) Создать новый /swapfile"
        echo "3) Выход"
        read -rp "Выбор [1-3]: " choice

        case $choice in
            1) swapon --show; free -h ;;
            2) create_swap ;;
            3) echo "Выход"; exit 0 ;;
            *) echo "Неверный выбор" ;;
        esac
    fi
done
