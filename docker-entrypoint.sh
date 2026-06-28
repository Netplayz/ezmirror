#!/usr/bin/env bash
set -euo pipefail

EZMIRROR_ROOT="/opt/ezmirror"
CONF_DIR="/etc/ezmirror"
WEBROOT="/var/www/html"
MIRROR_DIR="${EZMIRROR_VOLUME:-/var/www/html}"
NGINX_CONF="/etc/nginx/sites-available/default"

export EZMIRROR_LAB_NAME="${EZMIRROR_LAB_NAME:-MyOrg Docker Mirror}"
export EZMIRROR_DOMAIN="${EZMIRROR_DOMAIN:-localhost}"
export EZMIRROR_LOCATION="${EZMIRROR_LOCATION:-Docker Container}"
export EZMIRROR_GH_USER="${EZMIRROR_GH_USER:-netplayz}"
[[ -n "${EZMIRROR_MIRRORS:-}" ]] && export EZMIRROR_MIRRORS
export EZMIRROR_VOLUME="${EZMIRROR_VOLUME:-/var/www/html}"
export EZMIRROR_SKIP_DEPS=1
export EZMIRROR_SKIP_INITIAL_SYNC=1

if [[ ! -f "${CONF_DIR}/mirrors.conf" ]]; then
    echo "-> First run: setting up ezmirror config..."

    mkdir -p "${CONF_DIR}" "${WEBROOT}" "${MIRROR_DIR}"

    # Generate mirrors.conf from mirrors.json (all mirrors by default)
    python3 "${EZMIRROR_ROOT}/python/setup.py" --unattended 2>&1 | sed 's/^/   /'

    # Fix nginx config for Docker: no systemd, just write config and start nginx
    # Override the listen directive to 0.0.0.0:80
    if [[ -f "${NGINX_CONF}" ]]; then
        sed -i 's/listen 80 default_server;/listen 0.0.0.0:80 default_server;/g' "${NGINX_CONF}"
        sed -i 's/listen \[::\]:80 /listen \[::\]:80 /g' "${NGINX_CONF}"
        ln -sf "${NGINX_CONF}" /etc/nginx/sites-enabled/default
    fi

    echo "-> Setup complete."
fi

# Ensure site symlink exists on subsequent runs too
[[ -L /etc/nginx/sites-enabled/default ]] || ln -sf "${NGINX_CONF}" /etc/nginx/sites-enabled/default

# Start nginx
echo "-> Starting nginx..."
nginx -g "daemon off;" &
NGINX_PID=$!

# Start admin panel
echo "-> Starting admin panel..."
/opt/ezmirror/web/panel.py &
PANEL_PID=$!

# Cleanup handler
cleanup() {
    echo "-> Shutting down..."
    kill "${NGINX_PID}" 2>/dev/null || true
    kill "${EZMIRORD_PID}" 2>/dev/null || true
    kill "${PANEL_PID}" 2>/dev/null || true
    wait
    exit 0
}
trap cleanup SIGTERM SIGINT

# Start ezmirord in foreground
echo "-> Starting ezmirord..."
/usr/local/sbin/ezmirord &
EZMIRORD_PID=$!

echo "-> ezmirror running (nginx pid=${NGINX_PID}, ezmirord pid=${EZMIRORD_PID}, panel pid=${PANEL_PID})"

# Wait for any child to exit
wait -n
