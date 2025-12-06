#!/bin/bash

# ============================
#   Universal SWAP Manager
# ============================

CLR_BLUE='\e[36m'
CLR_GREEN='\e[32m'
CLR_YELLOW='\e[33m'
CLR_RED='\e[31m'
CLR_RESET='\e[0m'

clear
echo -e "${CLR_BLUE}"
echo "🧊  Universal SWAP Manager — удобный модуль"
echo -e "${CLR_RESET}"

SWAPFILE="/swapfile"

# ============================
# Функция отображения параметров
# ============================
show_param_help() {
    echo -e "${CLR_BLUE}Пояснение параметров:${CLR_RESET}"

    echo -e "  ▸ ${CLR_GREEN}swappiness${CLR_RESET} — как активно будет использоваться swap"
    echo "       Значения:"
    echo "       0–10: Почти не использовать swap (только при реальном OOM)"
    echo "       10–20: Оптимально для серверов и нод (минимум лагов)"
    echo "       30–40: Нормально для десктопов (баланс)"
    echo "       60: Значение по умолчанию в Ubuntu"
    echo "       80–100: Агрессивное свопирование (маленькая RAM)"

    echo -e "\n  ▸ ${CLR_GREEN}vfs_cache_pressure${CLR_RESET} — как долго хранится файловый кэш в RAM"
    echo "       Значения:"
    echo "       1–50: Кэш держится дольше, лучше для серверов/нод"
    echo "       100: Значение по умолчанию в Ubuntu"
    echo "       150–200: Сильно ускоренное очищение кэша"
    echo
}

# ============================
# Функция настройки параметров
# ============================
set_sysctl_params() {
    clear
    show_param_help

    echo -e "${CLR_YELLOW}Выбор:${CLR_RESET}"
    echo -e "1) Применить значения по умолчанию (swappiness=10, vfs_cache_pressure=50) — рекомендовано для нод"
    echo -e "2) Ввести свои значения"
    echo -e "3) Отмена"

    read -rp "Выбор [1-3]: " pm

    case $pm in
        1)
            swp=10
            vfs=50
            ;;
        2)
            read -rp "Введите swappiness (0–100): " swp
            read -rp "Введите vfs_cache_pressure (1–200): " vfs
            ;;
        *)
            echo -e "${CLR_YELLOW}Отменено.${CLR_RESET}"
            return
            ;;
    esac

    echo "vm.swappiness=${swp}" | sudo tee /etc/sysctl.d/99-swappiness.conf >/dev/null
    echo "vm.vfs_cache_pressure=${vfs}" | sudo tee /etc/sysctl.d/99-vfs-cache.conf >/dev/null

    sudo sysctl -p /etc/sysctl.d/99-swappiness.conf >/dev/null
    sudo sysctl -p /etc/sysctl.d/99-vfs-cache.conf >/dev/null

    echo -e "${CLR_GREEN}✔ Параметры применены: swappiness=${swp}, vfs_cache_pressure=${vfs}${CLR_RESET}"
}

# ============================
# Удаление swap
# ============================
delete_swap() {
    clear
    echo -e "${CLR_RED}Удаляем swap...${CLR_RESET}"

    sudo swapoff -a 2>/dev/null

    if grep -q "$SWAPFILE" /etc/fstab; then
        sudo sed -i "\|$SWAPFILE|d" /etc/fstab
    fi

    [ -f "$SWAPFILE" ] && sudo rm -f "$SWAPFILE"

    echo -e "${CLR_GREEN}✔ Swap успешно удалён.${CLR_RESET}"
}

# ============================
# Создание swap
# ============================
create_swap() {
    clear
    read -rp "Введите размер swap файла в ГБ (например 8): " SIZE

    clear
    echo -e "${CLR_BLUE}По умолчанию создается swap с параметрами:${CLR_RESET}"
    echo "  ▸ Как активно будет использоваться swap: 10"
    echo "  ▸ Как долго хранится файловый кэш в RAM: 50"

    read -rp "Использовать значения по умолчанию? (Y/n): " ans

    if [[ "$ans" =~ ^[Nn]$ ]]; then
        set_sysctl_params
    else
        echo "vm.swappiness=10" | sudo tee /etc/sysctl.d/99-swappiness.conf >/dev/null
        echo "vm.vfs_cache_pressure=50" | sudo tee /etc/sysctl.d/99-vfs-cache.conf >/dev/null
        sudo sysctl -p /etc/sysctl.d/99-swappiness.conf >/dev/null
        sudo sysctl -p /etc/sysctl.d/99-vfs-cache.conf >/dev/null
    fi

    sudo fallocate -l "${SIZE}G" "$SWAPFILE"
    sudo chmod 600 "$SWAPFILE"
    sudo mkswap "$SWAPFILE" >/dev/null
    sudo swapon "$SWAPFILE"

    # В fstab избегаем дублей
    sudo sed -i "\|$SWAPFILE|d" /etc/fstab
    echo "$SWAPFILE none swap sw 0 0" | sudo tee -a /etc/fstab >/dev/null

    clear
    echo -e "${CLR_GREEN}✔ Swap размером ${SIZE}G создан и активирован.${CLR_RESET}"
    swapon --show
    free -h
}

# ============================
# Основная логика
# ============================

if swapon --show | grep -q "$SWAPFILE"; then
    clear
    echo -e "${CLR_GREEN}✔ Обнаружен активный swap. Информация:${CLR_RESET}"
    swapon --show
    free -h
    echo

    echo -e "${CLR_BLUE}Выберите действие:${CLR_RESET}"
    echo "1) Оставить существующий swap (ничего не делать)"
    echo "2) Настроить параметры swappiness / vfs_cache_pressure в существующем swap"
    echo "3) Пересоздать swap (удалить текущий и создать новый /swapfile)"
    echo "4) Удалить swap (отключить и удалить файл / запись)"
    echo "5) Отмена"

    read -rp "Ваш выбор [1-5]: " opt

    case $opt in
        1) exit 0 ;;
        2) set_sysctl_params ;;
        3) delete_swap; create_swap ;;
        4) delete_swap ;;
        *) exit 0 ;;
    esac

else
    clear
    echo -e "${CLR_YELLOW}Swap не найден.${CLR_RESET}"

    echo -e "${CLR_BLUE}Выберите действие:${CLR_RESET}"
    echo "1) Проверить статус swap"
    echo "2) Создать новый /swapfile"
    echo "3) Выход"

    read -rp "Выбор [1-3]: " opt

    case $opt in
        1) clear; swapon --show; free -h ;;
        2) create_swap ;;
        *) exit 0 ;;
    esac
fi
