#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# VPS Bootstrap (Ubuntu/Debian, apt-based)
# ==========================================
# Modes:
#   --check        : analyze only (no changes)
#   --apply        : apply changes
#
# Options:
#   --install-docker=auto|yes|no   (default: auto)
#   --prefer-compose-plugin        (replace /usr/local/bin/docker-compose with wrapper -> docker compose)
#   --no-upgrade                   (skip full system upgrade/full-upgrade; still installs/upgrades selected packages)
#
# Examples:
#   sudo bash vps-bootstrap.sh --check
#   sudo bash vps-bootstrap.sh --apply --prefer-compose-plugin
#   sudo bash vps-bootstrap.sh --apply --install-docker=no
#   sudo bash vps-bootstrap.sh --apply --no-upgrade
#

MODE="check"
INSTALL_DOCKER="auto"
PREFER_COMPOSE_PLUGIN="no"
DO_UPGRADE="yes"

for arg in "$@"; do
  case "$arg" in
    --check) MODE="check" ;;
    --apply) MODE="apply" ;;
    --install-docker=*) INSTALL_DOCKER="${arg#*=}" ;;
    --prefer-compose-plugin) PREFER_COMPOSE_PLUGIN="yes" ;;
    --no-upgrade) DO_UPGRADE="no" ;;
    *)
      echo "Unknown argument: $arg"
      exit 2
      ;;
  esac
done

export DEBIAN_FRONTEND=noninteractive

# -------- pretty logs --------
c_info="\033[1;32m"
c_warn="\033[1;33m"
c_err="\033[1;31m"
c_dim="\033[2m"
c_reset="\033[0m"

log()  { echo -e "${c_info}[INFO]${c_reset} $*"; }
warn() { echo -e "${c_warn}[WARN]${c_reset} $*"; }
err()  { echo -e "${c_err}[ERR ]${c_reset} $*" >&2; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }
dpkg_installed() { dpkg -s "$1" >/dev/null 2>&1; }

need_root_apply() {
  if [[ "$MODE" == "apply" && "${EUID}" -ne 0 ]]; then
    err "Run apply mode as root: sudo bash $0 --apply ..."
    exit 1
  fi
}

run_or_plan() {
  if [[ "$MODE" == "check" ]]; then
    echo -e "  ${c_dim}PLAN:${c_reset} $*"
  else
    eval "$@"
  fi
}

# -------- OS detect --------
OS_ID="unknown"
OS_NAME="unknown"
OS_VER="unknown"
OS_CODENAME=""

os_detect() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_NAME="${NAME:-unknown}"
    OS_VER="${VERSION_ID:-unknown}"
    OS_CODENAME="${VERSION_CODENAME:-}"
  fi
}

is_apt_os() {
  [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]
}

# -------- packages list (your list) --------
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

# -------- commands audit list --------
# Note: some are commands from packages above; also include docker tooling.
AUDIT_CMDS=(
  apt-get
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
  ip
  ifconfig
  dig
  ufw
  cat
  docker
  docker-compose
)

# -------- holds --------
declare -A HOLDS
load_holds() {
  local h
  while read -r h; do
    [[ -n "$h" ]] && HOLDS["$h"]="1"
  done < <(apt-mark showhold 2>/dev/null || true)
}

is_held() {
  local p="$1"
  [[ "${HOLDS[$p]:-}" == "1" ]]
}

# -------- version helpers --------
installed_ver() {
  local p="$1"
  dpkg-query -W -f='${Status} ${Version}\n' "$p" 2>/dev/null | awk '/install ok installed/{print $5}' || true
}

candidate_ver() {
  local p="$1"
  apt-cache policy "$p" 2>/dev/null | awk -F': ' '/Candidate:/{print $2}' | head -n1 || true
}

ver_newer_available() {
  local inst="$1"
  local cand="$2"
  [[ -z "$inst" || -z "$cand" || "$cand" == "(none)" ]] && return 1
  dpkg --compare-versions "$cand" gt "$inst"
}

# -------- command version helper --------
cmd_path() {
  command -v "$1" 2>/dev/null || true
}

cmd_version_line() {
  # Try a few common patterns; keep it short and safe.
  local c="$1"
  local out=""
  if ! have_cmd "$c"; then
    echo ""
    return
  fi

  # Special cases (more reliable):
  case "$c" in
    docker)
      out="$(docker --version 2>/dev/null | head -n1 || true)"
      ;;
    docker-compose)
      out="$(docker-compose version 2>/dev/null | head -n1 || true)"
      ;;
    ufw)
      out="$(ufw version 2>/dev/null | head -n1 || true)"
      ;;
    apt-get)
      out="$(apt-get --version 2>/dev/null | head -n1 || true)"
      ;;
    ip)
      out="$(ip -V 2>/dev/null | head -n1 || true)"
      ;;
    ifconfig)
      out="$(ifconfig --version 2>/dev/null | head -n1 || true)"
      ;;
    dig)
      out="$(dig -v 2>/dev/null | head -n1 || true)"
      ;;
    *)
      # Generic fallbacks:
      if "$c" --version >/dev/null 2>&1; then
        out="$("$c" --version 2>/dev/null | head -n1 || true)"
      elif "$c" -V >/dev/null 2>&1; then
        out="$("$c" -V 2>/dev/null | head -n1 || true)"
      elif "$c" -v >/dev/null 2>&1; then
        out="$("$c" -v 2>/dev/null | head -n1 || true)"
      else
        out=""
      fi
      ;;
  esac

  # Normalize whitespace a bit:
  echo "$out" | tr -s ' ' | sed 's/[[:space:]]*$//'
}

# -------- reports --------
print_header() {
  echo
  log "Mode: $MODE | Install Docker: $INSTALL_DOCKER | Prefer compose plugin: $PREFER_COMPOSE_PLUGIN | Upgrade: $DO_UPGRADE"
  log "OS: $OS_NAME ($OS_ID) $OS_VER ${OS_CODENAME:+codename=$OS_CODENAME}"
  echo
}

report_pkg_audit() {
  echo
  log "=== Package audit (installed vs candidate) ==="
  echo -e "  ${c_dim}Note:${c_reset} In --check mode, candidate versions may be stale if apt lists are old."
  echo

  printf "  %-24s %-16s %-16s %-14s\n" "PACKAGE" "INSTALLED" "CANDIDATE" "STATUS"
  printf "  %-24s %-16s %-16s %-14s\n" "------------------------" "----------------" "----------------" "--------------"

  local p inst cand status
  for p in "${BASE_PKGS[@]}"; do
    inst="$(installed_ver "$p")"
    cand="$(candidate_ver "$p")"

    if is_held "$p"; then
      status="HELD"
    elif [[ -z "$inst" ]]; then
      status="MISSING"
    elif [[ -z "$cand" || "$cand" == "(none)" ]]; then
      status="NO-CANDIDATE"
    elif ver_newer_available "$inst" "$cand"; then
      status="UPGRADABLE"
    else
      status="OK"
    fi

    [[ -z "$inst" ]] && inst="(none)"
    [[ -z "$cand" ]] && cand="(unknown)"

    printf "  %-24s %-16s %-16s %-14s\n" "$p" "$inst" "$cand" "$status"
  done
}

report_cmd_audit() {
  echo
  log "=== Command audit (installed / not installed) ==="
  printf "  %-18s %-8s %-28s %s\n" "COMMAND" "STATUS" "PATH" "VERSION"
  printf "  %-18s %-8s %-28s %s\n" "------------------" "--------" "----------------------------" "------------------------------"

  local c p v
  for c in "${AUDIT_CMDS[@]}"; do
    if have_cmd "$c"; then
      p="$(cmd_path "$c")"
      v="$(cmd_version_line "$c")"
      [[ -z "$v" ]] && v="(version n/a)"
      printf "  %-18s %-8s %-28s %s\n" "$c" "FOUND" "$p" "$v"
    else
      printf "  %-18s %-8s %-28s %s\n" "$c" "MISSING" "-" "-"
    fi
  done

  # Extra: plugin compose audit (docker compose)
  echo
  if have_cmd docker; then
    if docker compose version >/dev/null 2>&1; then
      echo "  docker compose: $(docker compose version 2>/dev/null | tr -s ' ')"
    else
      echo "  docker compose: NOT FOUND (plugin not available)"
    fi
  else
    echo "  docker compose: (docker missing)"
  fi
}

report_docker_state() {
  echo
  log "=== Docker / Compose audit (detailed) ==="

  if have_cmd docker; then
    echo "  docker: $(command -v docker)"
    docker version 2>/dev/null | sed 's/^/  /' || true
  else
    echo "  docker: NOT FOUND"
  fi

  echo
  if have_cmd docker-compose; then
    echo "  docker-compose: $(command -v docker-compose)"
    docker-compose version 2>/dev/null | sed 's/^/  /' || true
  else
    echo "  docker-compose: NOT FOUND"
  fi

  echo
  log "APT policy (docker.io / docker-ce / docker-compose / docker-compose-plugin):"
  apt-cache policy docker.io docker-ce docker-compose docker-compose-plugin 2>/dev/null | sed -n '1,120p' | sed 's/^/  /' || true
}

# -------- apt actions --------
apt_update_upgrade() {
  if ! is_apt_os; then
    warn "Non Ubuntu/Debian OS detected ($OS_ID). This script supports apt-based systems only."
    return
  fi

  if [[ "$MODE" == "apply" ]]; then
    log "Running apt-get update..."
    apt-get update -y
  else
    echo -e "  ${c_dim}PLAN:${c_reset} apt-get update -y"
  fi

  if [[ "$DO_UPGRADE" == "yes" ]]; then
    run_or_plan "apt-get upgrade -y"
    run_or_plan "apt-get full-upgrade -y"
    run_or_plan "apt-get autoremove -y"
  else
    warn "Skipping full system upgrade (--no-upgrade). Will still install/upgrade selected packages."
  fi
}

install_or_upgrade_base_pkgs() {
  if ! is_apt_os; then return; fi
  log "Installing/upgrading base packages (your list)..."
  run_or_plan "apt-get install -y ${BASE_PKGS[*]}"
}

# -------- Docker install/migrate --------
docker_ce_installed() { dpkg_installed docker-ce; }
docker_io_installed() { dpkg_installed docker.io; }

ensure_docker_ce_repo() {
  if ! is_apt_os; then return; fi
  if [[ "$OS_ID" != "ubuntu" && "$OS_ID" != "debian" ]]; then return; fi
  if [[ -z "$OS_CODENAME" ]]; then
    err "Cannot detect OS codename (e.g. jammy/noble/bookworm). Check /etc/os-release."
    exit 1
  fi

  run_or_plan "install -m 0755 -d /etc/apt/keyrings"
  run_or_plan "curl -fsSL https://download.docker.com/linux/${OS_ID}/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
  run_or_plan "chmod a+r /etc/apt/keyrings/docker.gpg"

  local arch
  arch="$(dpkg --print-architecture)"

  run_or_plan "cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${OS_ID} ${OS_CODENAME} stable
EOF"

  if [[ "$MODE" == "apply" ]]; then
    apt-get update -y
  else
    echo -e "  ${c_dim}PLAN:${c_reset} apt-get update -y"
  fi
}

install_or_migrate_docker() {
  if ! is_apt_os; then return; fi

  if [[ "$INSTALL_DOCKER" == "no" ]]; then
    log "Docker installation/migration disabled (--install-docker=no)."
    return
  fi

  if docker_ce_installed; then
    log "docker-ce already installed. Upgrading docker packages (if updates available)..."
    run_or_plan "apt-get install -y --only-upgrade docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || true"
    return
  fi

  if docker_io_installed; then
    warn "Detected docker.io from distro repo. Recommended to migrate to Docker CE to avoid containerd/compose conflicts."
  fi

  if [[ "$INSTALL_DOCKER" == "auto" || "$INSTALL_DOCKER" == "yes" ]]; then
    log "Installing Docker CE (official repo) + Compose v2 plugin..."
    run_or_plan "apt-get remove -y docker.io docker-compose docker-doc podman-docker containerd runc || true"
    ensure_docker_ce_repo
    run_or_plan "apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
    run_or_plan "systemctl enable docker"
    run_or_plan "systemctl start docker"
  fi
}

# -------- Compose unification --------
prefer_compose_plugin() {
  local p=""
  if have_cmd docker-compose; then
    p="$(command -v docker-compose)"
  fi

  if [[ -z "$p" ]]; then
    log "No docker-compose binary detected. OK."
    return
  fi

  if [[ "$p" == "/usr/local/bin/docker-compose" ]]; then
    warn "Found manually installed docker-compose at /usr/local/bin/docker-compose (can differ from plugin 'docker compose')."
    if [[ "$PREFER_COMPOSE_PLUGIN" == "yes" ]]; then
      log "Replacing it with wrapper to 'docker compose' (backup will be created)."
      run_or_plan "mv /usr/local/bin/docker-compose /usr/local/bin/docker-compose.bak.$(date +%F_%H%M%S)"
      run_or_plan "cat > /usr/local/bin/docker-compose <<'EOF'
#!/usr/bin/env bash
exec docker compose \"\$@\"
EOF"
      run_or_plan "chmod +x /usr/local/bin/docker-compose"
    else
      warn "Leaving it as-is. Run with --prefer-compose-plugin to unify."
    fi
  else
    warn "docker-compose is present at: $p (not /usr/local/bin). Leaving as-is."
  fi
}

# -------- Main --------
main() {
  need_root_apply
  os_detect

  print_header

  if ! is_apt_os; then
    warn "This script currently supports Ubuntu/Debian (apt). Detected: $OS_ID"
    exit 0
  fi

  load_holds

  # Audits before changes
  report_pkg_audit
  report_cmd_audit
  report_docker_state

  echo
  log "=== Planned/Applied actions ==="
  apt_update_upgrade
  install_or_upgrade_base_pkgs
  install_or_migrate_docker
  prefer_compose_plugin

  # Audits after changes (useful in --apply; harmless in --check)
  echo
  log "=== Final audit ==="
  load_holds
  report_pkg_audit
  report_cmd_audit
  report_docker_state

  echo
  if [[ "$MODE" == "check" ]]; then
    log "Done (check mode): no changes were applied."
  else
    log "Done (apply mode)."
    if [[ -f /var/run/reboot-required ]]; then
      warn "Reboot recommended: /var/run/reboot-required exists."
      sed 's/^/  /' /var/run/reboot-required 2>/dev/null || true
    fi
  fi
}

main
