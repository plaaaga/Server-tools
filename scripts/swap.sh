#!/bin/bash

# ╔════════════════════════════════════════════════╗
#   🧊 Universal SWAP Manager — удобный модуль
#   Автоматическая установка и настройка swap файла
# ╚════════════════════════════════════════════════╝

clear

# Проверка root
if [[ $EUID -ne 0 ]]; then
  echo "Этот скрипт нужно запускать от root."
  exit 1
fi

# Проверка текущего swap
check_swap() {
    swapon --show --bytes
}

# Статус swap в упрощённом виде
swap_exists() {
    [[ -n "$(swapon --show --noheadings)" ]]
}

# Установка параметров swappiness и vfs_cache_pressure
apply_sysctl_values() {
    local sw=$1
    local vfs=$2

    echo "Применение параметров swappiness=$sw, vfs_cache_pressure=$vfs..."

    sysctl vm.swappiness=$sw >/dev/null
    sysctl vm.vfs_cache_pressure=$vfs >/dev/null

    grep -q "vm.swappiness" /etc/sysctl.conf \
        && sed -i "s/^vm\.swappiness=.*/vm.swappiness=$sw/" /etc/sysctl.conf \
        || echo "vm.swappiness=$sw" >> /etc/sysctl.conf

    grep -q "vm.vfs_cache_pressure" /etc/sysctl.conf \
        && sed -i "s/^vm\.vfs_cache_pressure=.*/vm.vfs_cache_pressure=$vfs/" /etc/sysctl.conf \
        || echo "vm.vfs_cache_pressure=$vfs" >> /etc/sysctl.conf

    echo "✓ Параметры успешно применены."
}

# Создание swap-файла
create_swap() {
    clear
    echo "Создание нового swap файла"

    read -rp "Введите размер swap файла в ГБ (например 8): " SIZE

    clear
    echo "По умолчанию создается swap с параметрами:"
    echo "  ▸ swappiness: 10"
    echo "  ▸ vfs_cache_pressure: 50"
    read -rp "Использовать значения по умолчанию? (Y/n): " use_default

    if [[ "$use_default" =~ ^[Yy]$ || -z "$use_default" ]]; then
        SW=10
        VFS=50
    else
        clear
        echo "Пояснение параметров:"
        echo "  ▸ swappiness — как активно будет использоваться swap"
        echo "       Значения:"
        echo "       0–10: Почти не использовать swap (только при реальном OOM)"
        echo "       10–20: Оптимально для серверов и нод (минимум лагов)"
        echo "       30–40: Нормально для десктопов (баланс)"
        echo "       60: Значение по умолчанию в Ubuntu"
        echo "       80–100: Агрессивное свопирование (маленькая RAM)"
        echo
        echo "  ▸ vfs_cache_pressure — как долго хранится файловый кэш в RAM"
        echo "       Значения:"
        echo "       1–50: Кэш держится дольше, лучше для серверов/нод"
        echo "       100: Значение по умолчанию в Ubuntu"
        echo "       150–200: Сильно ускоренное очищение кэша"
        echo

        read -rp "Введите значение swappiness (0–100): " SW
        read -rp "Введите значение vfs_cache_pressure (1–200): " VFS
    fi

    clear
    echo "Создаю swap размером ${SIZE}G..."

    swapoff -a 2>/dev/null
    rm -f /swapfile

    fallocate -l ${SIZE}G /swapfile || dd if=/dev/zero of=/swapfile bs=1G count=$SIZE
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile

    if ! grep -q "/swapfile" /etc/fstab; then
        echo "/swapfile none swap sw 0 0" >> /etc/fstab
    fi

    apply_sysctl_values $SW $VFS

    clear
    echo "✓ Новый swap успешно создан!"
    check_swap
}

# Удаление swap
delete_swap() {
    clear
    echo "Удаление swap..."

    swapoff -a
    sed -i "/\/swapfile/d" /etc/fstab
    rm -f /swapfile

    clear
    echo "✓ Swap отключён и удалён."
}

# Меню, когда swap существует
menu_existing_swap() {
    clear
    echo "✔ Обнаружен активный swap."
    check_swap
    echo
    echo "Выберите действие:"
    echo "1) Оставить существующий swap"
    echo "2) Настроить swappiness / vfs_cache_pressure"
    echo "3) Пересоздать swap"
    echo "4) Удалить swap"
    echo "5) Выход"
    read -rp "Ваш выбор [1-5]: " CH

    case $CH in
        1) clear; echo "Ничего не изменено."; exit 0 ;;
        2)
            clear
            echo "Введите новые значения:"
            read -rp "swappiness (0–100): " SW
            read -rp "vfs_cache_pressure (1–200): " VFS
            apply_sysctl_values $SW $VFS
            exit 0
        ;;
        3) create_swap ;;
        4) delete_swap ;;
        5) exit 0 ;;
        *) menu_existing_swap ;;
    esac
}

# Меню, когда swap отсутствует
menu_no_swap() {
    clear
    echo "Swap не найден."
    echo "Выберите действие:"
    echo "1) Создать новый /swapfile"
    echo "2) Выход"
    read -rp "Выбор [1-2]: " CH

    case $CH in
        1) create_swap ;;
        2) exit 0 ;;
        *) menu_no_swap ;;
    esac
}

# Логика запуска
if swap_exists; then
    menu_existing_swap
else
    menu_no_swap
fi
