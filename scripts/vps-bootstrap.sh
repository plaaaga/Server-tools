#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ========= UI =========
c_info="\033[1;32m"; c_warn="\033[1;33m"; c_err="\033[1;31m"; c_dim="\033[2m"
c_ok="\033[1;32m"; c_bad="\033[1;31m"; c_mid="\033[1;33m"; c_reset="\033[0m"

log()  { echo -e "${c_info}[INFO]${c_reset} $*"; }
warn() { echo -e "${c_warn}[WARN]${c_reset} $*"; }
err()  { echo -e "${c_err}[ERR ]${c_reset} $*" >&2; }

pause() { read -r -p "Нажми Enter, чтобы продолжить..." _; }
confirm() {
  local prompt="${1:-Продолжить?}"
  read -r -p "$prompt [y/N]: " ans
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

need_root_or_warn() {
  if [[ "${EUID}" -ne 0 ]]; then
    warn "Для этого действия нужны права root. Запусти: sudo $0"
    return 1
  fi
  return 0
}

# ========= OS detect =========
OS_ID="unknown"; OS_NAME="unknown"; OS_VER="unknown"; OS_CODENAME=""
detect_os() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_NAME="${NAME:-unknown}"
    OS_VER="${VERSION_ID:-unknown}"
    OS_CODENAME="${VERSION_CODENAME:-}"
  fi
}
is_apt_os() { [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; }

# ========= State =========
USER_MODE="novice"           # novice|advanced
DID_APT_UPDATE="no"
DID_SYS_UPGRADE="no"

# ========= Packages / commands =========
BASE_PKGS=(
  ca-certificates
  apt-transport-https
  gnupg
  lsb-release
  software-properties-common
  curl
  wget
  nano
  screen
  tmux
  htop
  git
  jq
  unzip
  zip
  net-tools
  iproute2
  dnsutils
  ufw
  coreutils
)

AUDIT_CMDS=(
  curl wget nano screen tmux htop git jq unzip zip
  ip ifconfig dig ufw cat
  docker docker-compose
)

have_cmd() { command -v "$1" >/dev/null 2>&1; }
cmd_path() { command -v "$1" 2>/dev/null || true; }

cmd_version_line() {
  local c="$1"
  if ! have_cmd "$c"; then echo ""; return 0; fi

  local out=""
  case "$c" in
    docker) out="$(docker --version 2>/dev/null | head -n1 || true)" ;;
    docker-compose) out="$(docker-compose version 2>/dev/null | head -n1 || true)" ;;
    ufw) out="$(ufw version 2>/dev/null | head -n1 || true)" ;;
    ip) out="$(ip -V 2>/dev/null | head -n1 || true)" ;;
    ifconfig) out="$(ifconfig --version 2>/dev/null | head -n1 || true)" ;;
    dig) out="$(dig -v 2>/dev/null | head -n1 || true)" ;;
    *)
      if "$c" --version >/dev/null 2>&1; then out="$("$c" --version 2>/dev/null | head -n1 || true)"
      elif "$c" -V >/dev/null 2>&1; then out="$("$c" -V 2>/dev/null | head -n1 || true)"
      elif "$c" -v >/dev/null 2>&1; then out="$("$c" -v 2>/dev/null | head -n1 || true)"
      else out=""; fi
      ;;
  esac
  echo "$out" | tr -s ' ' | sed 's/[[:space:]]*$//'
}

# ========= Holds + versions =========
declare -A HOLDS
load_holds() {
  HOLDS=()
  local h
  while read -r h; do
    [[ -n "$h" ]] && HOLDS["$h"]="1"
  done < <(apt-mark showhold 2>/dev/null || true)
}
is_held() { [[ "${HOLDS[$1]:-}" == "1" ]]; }

installed_ver() {
  local p="$1"
  dpkg-query -W -f='${Status} ${Version}\n' "$p" 2>/dev/null | awk '/install ok installed/{print $5}' || true
}
candidate_ver() {
  local p="$1"
  apt-cache policy "$p" 2>/dev/null | awk -F': ' '/Candidate:/{print $2}' | head -n1 || true
}
ver_newer_available() {
  local inst="$1" cand="$2"
  [[ -z "$inst" || -z "$cand" || "$cand" == "(none)" ]] && return 1
  dpkg --compare-versions "$cand" gt "$inst"
}

# ========= System info =========
show_system_info() {
  echo
  log "Система:"
  echo "  OS:     $OS_NAME ($OS_ID) $OS_VER ${OS_CODENAME:+codename=$OS_CODENAME}"
  echo "  Kernel: $(uname -r)"
  echo "  Uptime: $(uptime -p 2>/dev/null || true)"
  echo "  User:   $(id -un) (uid=$(id -u))"
  echo "  Mode:   ${USER_MODE}"
  echo
  if is_apt_os; then
    echo "  APT:    $(apt-get --version 2>/dev/null | head -n1 || true)"
  else
    warn "Скрипт рассчитан на Ubuntu/Debian (apt). Обнаружено: $OS_ID"
  fi
  echo
}

# ========= Audit helpers =========
color_status_pkg() {
  local s="$1"
  case "$s" in
    OK) echo -e "${c_ok}${s}${c_reset}" ;;
    MISSING) echo -e "${c_bad}${s}${c_reset}" ;;
    UPGRADABLE) echo -e "${c_mid}${s}${c_reset}" ;;
    HELD) echo -e "${c_mid}${s}${c_reset}" ;;
    NO-CANDIDATE) echo -e "${c_mid}${s}${c_reset}" ;;
    *) echo "$s" ;;
  esac
}

color_status_cmd() {
  local s="$1"
  case "$s" in
    FOUND) echo -e "${c_ok}${s}${c_reset}" ;;
    MISSING) echo -e "${c_bad}${s}${c_reset}" ;;
    *) echo "$s" ;;
  esac
}

maybe_refresh_apt_lists_for_audit() {
  is_apt_os || return 0
  echo
  log "Пакетный аудит использует 'Candidate' версии из APT."
  echo "Если индексы пакетов давно не обновлялись, Candidate может быть неактуален."

  if [[ "${EUID}" -ne 0 ]]; then
    warn "Чтобы обновить индексы пакетов (apt-get update), запусти скрипт через sudo."
    return 0
  fi

  if confirm "Обновить индексы пакетов сейчас? (apt-get update)"; then
    apt-get update -y
    DID_APT_UPDATE="yes"
  else
    log "Ок, показываю данные без apt-get update."
  fi
}

show_command_audit() {
  local cnt_found=0 cnt_missing=0
  local missing_cmds=()

  echo
  log "Команды и версии:"
  printf "  %-16s %-8s %-28s %s\n" "COMMAND" "STATUS" "PATH" "VERSION"
  printf "  %-16s %-8s %-28s %s\n" "----------------" "--------" "----------------------------" "------------------------------"

  local c p v
  for c in "${AUDIT_CMDS[@]}"; do
    if have_cmd "$c"; then
      ((cnt_found+=1))
      p="$(cmd_path "$c")"
      v="$(cmd_version_line "$c")"
      [[ -z "$v" ]] && v="(version n/a)"
      printf "  %-16s %-8b %-28s %s\n" "$c" "$(color_status_cmd FOUND)" "$p" "$v"
    else
      ((cnt_missing+=1))
      missing_cmds+=("$c")
      printf "  %-16s %-8b %-28s %s\n" "$c" "$(color_status_cmd MISSING)" "-" "-"
    fi
  done

  echo
  log "Сводка команд: FOUND=${cnt_found}, MISSING=${cnt_missing}"
  if ((cnt_missing > 0)); then
    echo "  - Отсутствуют команды: ${missing_cmds[*]}"
  fi
  echo
}

show_docker_details() {
  echo
  log "Docker/Compose (дополнительно):"

  local has_docker="no" has_plugin="no" has_hyphen="no"
  local hyphen_path="" has_manual_hyphen="no"

  if have_cmd docker; then
    has_docker="yes"
    echo "  docker: OK"
    docker version 2>/dev/null | sed 's/^/  /' || true
  else
    echo "  Docker отсутствует (docker: NOT FOUND)"
  fi

  if have_cmd docker; then
    if docker compose version >/dev/null 2>&1; then
      has_plugin="yes"
      echo
      echo "  docker compose: $(docker compose version 2>/dev/null | tr -s ' ')"
    else
      echo
      echo "  docker compose: NOT FOUND (plugin)"
    fi
  fi

  if have_cmd docker-compose; then
    has_hyphen="yes"
    hyphen_path="$(command -v docker-compose)"
    echo "  docker-compose: $hyphen_path"
    docker-compose version 2>/dev/null | sed 's/^/  /' || true
    [[ "$hyphen_path" == "/usr/local/bin/docker-compose" ]] && has_manual_hyphen="yes"
  fi

  echo
  log "Проверка рисков/конфликтов:"
  local any_risk="no"

  if [[ "$has_docker" == "yes" && "$has_plugin" == "yes" && "$has_hyphen" == "yes" && "$has_manual_hyphen" == "yes" ]]; then
    any_risk="yes"
    warn "Найден ручной /usr/local/bin/docker-compose. Он может отличаться по версии от 'docker compose' (plugin)."
    echo "  Подсказка: в пункте Docker можно включить обёртку docker-compose -> docker compose."
  fi

  if [[ "$has_docker" == "yes" && "$has_plugin" == "no" ]]; then
    any_risk="yes"
    warn "Docker есть, но нет Compose v2 plugin (docker compose)."
    echo "  Подсказка: установить docker-compose-plugin (через пункт Docker или пакеты)."
  fi

  if [[ "$any_risk" == "no" ]]; then
    echo "  OK: явных конфликтов Compose не видно."
  fi
  echo
}

show_package_audit() {
  is_apt_os || { warn "Пакетный аудит доступен только для Ubuntu/Debian (apt)."; return; }
  [[ "${EUID}" -eq 0 ]] && load_holds || true

  local cnt_ok=0 cnt_missing=0 cnt_upg=0 cnt_held=0 cnt_noc=0
  local missing_list=() upg_list=() held_list=()

  echo
  log "Пакетный аудит (installed vs candidate):"
  printf "  %-24s %-16s %-16s %-14s\n" "PACKAGE" "INSTALLED" "CANDIDATE" "STATUS"
  printf "  %-24s %-16s %-16s %-14s\n" "------------------------" "----------------" "----------------" "--------------"

  local p inst cand status
  for p in "${BASE_PKGS[@]}"; do
    inst="$(installed_ver "$p")"
    cand="$(candidate_ver "$p")"

    status="OK"
    if [[ "${EUID}" -eq 0 ]] && is_held "$p"; then
      status="HELD"
      ((cnt_held+=1)); held_list+=("$p")
    elif [[ -z "$inst" ]]; then
      status="MISSING"
      ((cnt_missing+=1)); missing_list+=("$p")
    elif [[ -z "$cand" || "$cand" == "(none)" ]]; then
      status="NO-CANDIDATE"
      ((cnt_noc+=1))
    elif ver_newer_available "$inst" "$cand"; then
      status="UPGRADABLE"
      ((cnt_upg+=1)); upg_list+=("$p")
    else
      ((cnt_ok+=1))
    fi

    [[ -z "$inst" ]] && inst="(none)"
    [[ -z "$cand" ]] && cand="(unknown)"
    printf "  %-24s %-16s %-16s %-14b\n" "$p" "$inst" "$cand" "$(color_status_pkg "$status")"
  done

  echo
  log "Сводка пакетов: OK=${cnt_ok}, UPGRADABLE=${cnt_upg}, MISSING=${cnt_missing}, HELD=${cnt_held}, NO-CANDIDATE=${cnt_noc}"
  if ((cnt_missing > 0)); then echo "  - Не установлены: ${missing_list[*]}"; fi
  if ((cnt_upg > 0)); then echo "  - Есть обновления: ${upg_list[*]}"; fi
  if ((cnt_held > 0)); then echo "  - На hold: ${held_list[*]}"; fi
  echo
}

show_action_plan() {
  echo
  log "Подсказка по порядку действий:"

  if [[ "$USER_MODE" == "novice" ]]; then
    echo "  Рекомендуемый порядок: (1) Аудит → (2) Обновить систему → (3) Установить пакеты → (4) Docker (если нужен)."
  else
    echo "  Рекомендуемый порядок: apt update → (upgrade/full-upgrade по необходимости) → базовые пакеты → Docker."
  fi

  if [[ "$DID_APT_UPDATE" != "yes" ]]; then
    echo "  - Индексы пакетов могли быть неактуальны: запусти обновление системы или apt update (в продвинутом меню)."
  fi
  if [[ "$DID_SYS_UPGRADE" != "yes" ]]; then
    echo "  - Система ещё не обновлялась в этой сессии (пункт обновления системы)."
  fi

  if have_cmd docker-compose; then
    local hp; hp="$(command -v docker-compose)"
    if [[ "$hp" == "/usr/local/bin/docker-compose" ]]; then
      echo "  - Найден ручной docker-compose (/usr/local/bin): можно включить обёртку через пункт Docker."
    fi
  fi
  echo
}

action_1_audit_everything() {
  show_command_audit
  show_docker_details
  if is_apt_os; then
    maybe_refresh_apt_lists_for_audit
    show_package_audit
  fi
  show_action_plan
}

# ========= System update actions =========
count_upgradable() {
  # returns integer count (best-effort). requires updated lists for accuracy.
  apt list --upgradable 2>/dev/null | awk 'NR>1{c++} END{print c+0}'
}

novice_update_system() {
  is_apt_os || { err "Не apt-система. Обновление не поддерживается."; return; }
  need_root_or_warn || return

  echo
  log "Обновление системы (режим новичка)."
  echo "Сценарий: apt update → показать количество обновлений → подтверждение → upgrade + full-upgrade + autoremove"
  warn "Это может обновить многие пакеты системы."

  if ! confirm "Продолжить?"; then
    log "Отменено."
    return
  fi

  log "apt-get update..."
  apt-get update -y
  DID_APT_UPDATE="yes"

  local n
  n="$(count_upgradable || echo 0)"
  log "Доступно обновлений (примерно): $n"

  if ! confirm "Установить обновления сейчас?"; then
    log "Ок, индексы обновлены, но пакеты не обновлялись."
    return
  fi

  log "apt-get upgrade..."
  apt-get upgrade -y

  log "apt-get full-upgrade..."
  apt-get full-upgrade -y

  log "apt-get autoremove..."
  apt-get autoremove -y

  DID_SYS_UPGRADE="yes"

  if [[ -f /var/run/reboot-required ]]; then
    warn "Рекомендуется перезагрузка: найден /var/run/reboot-required"
  fi

  log "Готово."
}

advanced_update_menu() {
  is_apt_os || { err "Не apt-система. Обновление не поддерживается."; return; }
  need_root_or_warn || return

  while true; do
    echo
    echo "------------------------------"
    echo " Advanced: System Update Menu"
    echo "------------------------------"
    echo "1) apt update (обновить индексы)"
    echo "2) показать upgradable (apt list --upgradable)"
    echo "3) симуляция upgrade (apt-get -s upgrade)"
    echo "4) выполнить upgrade (apt-get upgrade)"
    echo "5) симуляция full-upgrade (apt-get -s full-upgrade)"
    echo "6) выполнить full-upgrade (apt-get full-upgrade)"
    echo "7) autoremove (apt-get autoremove)"
    echo "0) назад"
    echo
    read -r -p "Выбери (0-7): " ch
    case "$ch" in
      1)
        apt-get update -y
        DID_APT_UPDATE="yes"
        ;;
      2)
        apt list --upgradable 2>/dev/null | sed 's/^/  /' || true
        ;;
      3)
        apt-get -s upgrade | sed 's/^/  /' || true
        ;;
      4)
        warn "upgrade обновляет пакеты без удаления/замены сложных зависимостей."
        confirm "Выполнить apt-get upgrade?" && apt-get upgrade -y || true
        DID_SYS_UPGRADE="yes"
        ;;
      5)
        apt-get -s full-upgrade | sed 's/^/  /' || true
        ;;
      6)
        warn "full-upgrade может устанавливать/удалять пакеты ради согласованности зависимостей."
        confirm "Выполнить apt-get full-upgrade?" && apt-get full-upgrade -y || true
        DID_SYS_UPGRADE="yes"
        ;;
      7)
        confirm "Выполнить apt-get autoremove?" && apt-get autoremove -y || true
        ;;
      0) return ;;
      *) warn "Неверный выбор." ;;
    esac
  done
}

# ========= Packages install =========
install_or_upgrade_base_pkgs() {
  is_apt_os || { err "Не apt-система. Установка пакетов не поддерживается."; return; }
  need_root_or_warn || return

  echo
  log "Установка/обновление базовых пакетов:"
  echo "  ${BASE_PKGS[*]}"
  if [[ "$USER_MODE" == "novice" && "$DID_SYS_UPGRADE" != "yes" ]]; then
    warn "Подсказка: обычно сначала делают обновление системы, потом ставят пакеты."
  fi

  if ! confirm "Продолжить установку/обновление?"; then
    log "Отменено."
    return
  fi

  apt-get update -y
  DID_APT_UPDATE="yes"

  apt-get install -y "${BASE_PKGS[@]}"
  log "Готово."
}

# ========= Docker install =========
docker_ce_installed() { dpkg -s docker-ce >/dev/null 2>&1; }

ensure_docker_repo() {
  need_root_or_warn || return 1
  is_apt_os || return 1

  if [[ -z "$OS_CODENAME" ]]; then
    err "Не удалось определить codename (jammy/noble/bookworm). Проверь /etc/os-release."
    return 1
  fi

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  local arch
  arch="$(dpkg --print-architecture)"

  cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${OS_ID} ${OS_CODENAME} stable
EOF

  apt-get update -y
  DID_APT_UPDATE="yes"
}

wrap_docker_compose() {
  need_root_or_warn || return

  local p=""
  if have_cmd docker-compose; then p="$(command -v docker-compose)"; fi

  if [[ -z "$p" ]]; then
    warn "docker-compose не найден — обёртка не требуется."
    return
  fi

  if [[ "$p" != "/usr/local/bin/docker-compose" ]]; then
    warn "docker-compose найден по пути: $p"
    warn "Я не буду трогать его автоматически (не /usr/local/bin)."
    return
  fi

  log "Найден ручной /usr/local/bin/docker-compose. Сделаем обёртку на 'docker compose'."
  if ! confirm "Заменить docker-compose на обёртку (с бэкапом)?"; then
    log "Отменено."
    return
  fi

  mv /usr/local/bin/docker-compose "/usr/local/bin/docker-compose.bak.$(date +%F_%H%M%S)"
  cat >/usr/local/bin/docker-compose <<'EOF'
#!/usr/bin/env bash
exec docker compose "$@"
EOF
  chmod +x /usr/local/bin/docker-compose
  log "Готово. Теперь 'docker-compose' будет вызывать 'docker compose'."
}

install_docker_menu() {
  is_apt_os || { err "Не apt-система. Установка Docker не поддерживается."; return; }
  need_root_or_warn || return

  echo
  log "Установка Docker CE из официального репозитория Docker."
  warn "Если сейчас стоят docker.io/containerd/runc из репозиториев Ubuntu/Debian — возможны конфликты. Скрипт удалит конфликтующие пакеты."

  if docker_ce_installed; then
    log "docker-ce уже установлен."
    if confirm "Обновить docker-ce и плагины до доступных версий?"; then
      apt-get update -y
      DID_APT_UPDATE="yes"
      apt-get install -y --only-upgrade docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || true
      log "Обновление Docker выполнено."
    fi
  else
    if ! confirm "Продолжить установку Docker CE?"; then
      log "Отменено."
      return
    fi

    apt-get remove -y docker.io docker-compose docker-doc podman-docker containerd runc || true
    ensure_docker_repo
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable docker
    systemctl start docker
    log "Docker установлен и запущен."
  fi

  echo
  log "Опции Compose:"
  echo "  1) Ничего не делать"
  echo "  2) Сделать обёртку: docker-compose -> docker compose (рекомендуется, если есть /usr/local/bin/docker-compose)"
  echo
  read -r -p "Выбери (1-2): " sub
  case "$sub" in
    2) wrap_docker_compose ;;
    *) log "Пропущено." ;;
  esac
}

# ========= Mode chooser =========
choose_user_mode() {
  echo
  echo "Выбери режим:"
  echo "1) Новичок (простые действия, безопасные подсказки)"
  echo "2) Продвинутый (больше контроля над обновлениями)"
  echo
  read -r -p "Режим (1-2) [1]: " m
  case "${m:-1}" in
    2) USER_MODE="advanced" ;;
    *) USER_MODE="novice" ;;
  esac
}

# ========= Main menu =========
menu_loop() {
  while true; do
    echo
    echo "=============================="
    echo " VPS Bootstrap Menu"
    echo " Mode: $USER_MODE"
    echo "=============================="
    echo "1) Аудит: команды/версии + Docker + пакетный аудит + план действий"
    if [[ "$USER_MODE" == "novice" ]]; then
      echo "2) Обновить систему (рекомендуется первым шагом)"
    else
      echo "2) Обновление системы (advanced submenu: update/upgrade/full-upgrade)"
    fi
    echo "3) Установить/обновить базовые команды (пакеты)"
    echo "4) Установить/обновить Docker CE (+ опция обёртки compose)"
    echo "5) Переключить режим (новичок/продвинутый)"
    echo "6) Выход"
    echo
    read -r -p "Выбери пункт (1-6): " choice

    case "$choice" in
      1) action_1_audit_everything; pause ;;
      2)
        if [[ "$USER_MODE" == "novice" ]]; then
          novice_update_system
        else
          advanced_update_menu
        fi
        pause
        ;;
      3) install_or_upgrade_base_pkgs; pause ;;
      4) install_docker_menu; pause ;;
      5) choose_user_mode; clear; show_system_info ;;
      6) clear; exit 0 ;;
      *) warn "Неверный выбор."; pause ;;
    esac
  done
}

main() {
  detect_os
  clear
  choose_user_mode
  clear
  show_system_info
  menu_loop
}

main
