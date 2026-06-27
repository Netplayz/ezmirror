#!/usr/bin/env bash
# ezmirror — production-grade mirror infrastructure
# Usage: sudo bash setup.sh [--unattended]
# See mirrors.json for the mirror catalog
set -euo pipefail

EZMIRROR_ROOT="$(cd "$(dirname "$0")" && pwd)"
PYTHON="${PYTHON:-python3}"

R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' B='\033[1m' N='\033[0m'
ok()   { echo -e "  ${G}✓${N}  $*"; }
info() { echo -e "  ${C}→${N}  $*"; }
warn() { echo -e "  ${Y}!${N}  $*"; }
die()  { echo -e "  ${R}✗${N}  $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run with sudo: sudo bash setup.sh"

# Check Python
command -v "$PYTHON" >/dev/null || die "Python 3 is required: apt-get install python3"

hdr() {
  echo -e "\n${B}── $* ──${N}"
  echo "  $(printf '─%.0s' {1..66})"
}

# Export env vars for Python subprocess
[[ -n "${EZMIRROR_LAB_NAME:-}"  ]] && export EZMIRROR_LAB_NAME
[[ -n "${EZMIRROR_DOMAIN:-}"    ]] && export EZMIRROR_DOMAIN
[[ -n "${EZMIRROR_LOCATION:-}"  ]] && export EZMIRROR_LOCATION
[[ -n "${EZMIRROR_GH_USER:-}"   ]] && export EZMIRROR_GH_USER
[[ -n "${EZMIRROR_MIRRORS:-}"   ]] && export EZMIRROR_MIRRORS
[[ -n "${EZMIRROR_VOLUME:-}"    ]] && export EZMIRROR_VOLUME
[[ -n "${EZMIRROR_WEBHOOK:-}"   ]] && export EZMIRROR_WEBHOOK
[[ -n "${EZMIRROR_EMAIL:-}"     ]] && export EZMIRROR_EMAIL
[[ -n "${EZMIRROR_LOGO_URL:-}"  ]] && export EZMIRROR_LOGO_URL

echo -e "\n${B}ezmirror — Production Mirror Infrastructure${N}"
echo    "  https://github.com/netplayz/ezmirror"
echo ""

# Pre-flight checks
hdr "Pre-flight"
for cmd in curl git jq rsync; do
  command -v "$cmd" >/dev/null && ok "$cmd" || die "$cmd is required: apt-get install $cmd"
done

# Run Python installer
hdr "Installer"
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --unattended) ARGS+=("--unattended") ;;
  esac
done

"$PYTHON" "${EZMIRROR_ROOT}/python/setup.py" "${ARGS[@]}"

# Build daemon (if cargo is available)
hdr "Daemon"
if command -v cargo >/dev/null; then
  if make build 2>/dev/null && [[ -x "${EZMIRROR_ROOT}/ezmirord" ]]; then
    install -m 755 "${EZMIRROR_ROOT}/ezmirord" /usr/local/sbin/ezmirord
    ok "ezmirord built (Rust)"
  else
    warn "Daemon build failed (non-critical)"
  fi
else
  warn "cargo not found, skipping daemon build"
fi

# Post-install summary
hdr "Post-install"
echo ""
echo -e "  ${B}Commands:${N}"
echo -e "    ${C}sudo ezmirror-sync${N}      Sync all mirrors"
echo -e "    ${C}ezmirror-status${N}         Show sync status"
echo -e "    ${C}ezmirror-logs${N}           View sync logs"
echo -e "    ${C}ezmirror-health${N}         Check upstream health"
echo -e "    ${C}ezmirror-verify${N}         Verify mirror integrity"
echo -e "    ${C}sudo ezmirror-backup${N}    Backup configuration"
echo -e "    ${C}sudo ezmirror-manage${N}    Add/remove mirrors"
echo -e "    ${C}ezmirror-metrics${N}        View Prometheus metrics"
echo ""
echo -e "  ${B}Endpoints:${N}"
echo -e "    ${C}/status.json${N}            Machine-readable sync status"
echo -e "    ${C}/healthz${N}                Health check (load balancer)"
echo -e "    ${C}:9633/metrics${N}           Prometheus metrics (localhost)"
echo ""
echo -e "  ${G}${B}Setup complete!${N}"
echo ""
