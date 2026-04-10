#!/usr/bin/env bash
# =============================================================================
# setup.sh — ezmirror
# Interactive mirror selection and full deploy script
# Usage: sudo bash setup.sh [--unattended]
#
# Unattended mode env vars:
#   EZMIRROR_LAB_NAME   EZMIRROR_DOMAIN    EZMIRROR_LOCATION
#   EZMIRROR_GH_USER    EZMIRROR_MIRRORS   EZMIRROR_VOLUME
#   EZMIRROR_WEBHOOK    EZMIRROR_EMAIL
#   EZMIRROR_TORRENTS   (yes/no)
# =============================================================================

set -euo pipefail

R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' B='\033[1m' N='\033[0m'
ok()   { echo -e "  ${G}✓${N}  $*"; }
info() { echo -e "  ${C}→${N}  $*"; }
warn() { echo -e "  ${Y}!${N}  $*"; }
die()  { echo -e "  ${R}✗${N}  $*" >&2; exit 1; }
hdr()  { echo -e "\n${B}── $* ──${N}"; }
rule() { printf '  %s\n' "$(printf '─%.0s' {1..66})"; }

[[ $EUID -eq 0 ]] || die "Run with sudo: sudo bash setup.sh"

# ── Unattended flag ───────────────────────────────────────────────────────────
UNATTENDED=false
for _arg in "$@"; do [[ "$_arg" == "--unattended" ]] && UNATTENDED=true; done

ask() {
    # ask "prompt text" VARNAME "default" [ENV_VAR]
    local prompt="$1" varname="$2" default="$3" envvar="${4:-}"
    if [[ -n "$envvar" && -n "${!envvar:-}" ]]; then
        printf -v "$varname" '%s' "${!envvar}"; return
    fi
    if [[ "$UNATTENDED" == true ]]; then
        printf -v "$varname" '%s' "$default"; return
    fi
    read -rp "  $prompt [$default]: " _tmp
    printf -v "$varname" '%s' "${_tmp:-$default}"
}

# =============================================================================
# Mirror catalog
# Format: slug|Display Name|Description|Upstream URL|Sync Method|Est. Size|warn|interval|bandwidth|retention_days|retention_max_gib
#
# Sync methods: rsync, rclone-sftp, rclone-http, original, mirror
# warn field         : "large" shows disk space caution; blank = none
# interval           : sync frequency, e.g. 1h, 6h, 12h, 24h (default 6h if blank)
# bandwidth          : rsync bandwidth limit in Mbps; 0 = unlimited (default)
# retention_days     : delete files older than N days; 0 = keep forever (default)
# retention_max_gib  : delete oldest files if total exceeds N GiB; 0 = no limit (default)
# =============================================================================

MIRROR_CATALOG=(
    "debian|Debian GNU/Linux|Stable, testing, and unstable package archive|rsync://rsync.debian.org/debian/|rsync|~2.0 TiB|large|12h"
    "ubuntu|Ubuntu|Canonical packages and LTS/current releases|rsync://rsync.ubuntu.com/ubuntu/|rsync|~2.0 TiB|large|12h"
    "arch|Arch Linux|Rolling release — x86_64 and arm|rsync://rsync.archlinux.org/archlinux/|rsync|~120 GiB||1h"
    "alpine|Alpine Linux|Lightweight, security-oriented distribution|rsync://dl-cdn.alpinelinux.org/alpine/|rsync|~100 GiB||6h"
    "mint|Linux Mint|Ubuntu-based beginner-friendly distribution|rsync://rsync.linuxmint.com/mint/|rsync|~5.0 TiB|large|24h"
    "gentoo|Gentoo Linux|Source-based meta-distribution + portage tree|rsync://rsync.gentoo.org/gentoo/|rsync|~500 GiB||6h"
    "fedora|Fedora Linux|RPM-based, sponsored by Red Hat|rsync://dl.fedoraproject.org/fedora-enchilada/linux/|rsync|~3.0 TiB|large|12h"
    "rocky|Rocky Linux|RHEL-compatible community enterprise distro|rsync://dl.rockylinux.org/pub/rocky/|rsync|~1.0 TiB|large|12h"
    "almalinux|AlmaLinux|Binary-compatible RHEL rebuild|rsync://repo.almalinux.org/almalinux/|rsync|~1.0 TiB|large|12h"
    "centos-stream|CentOS Stream|Upstream development branch of RHEL|rsync://rsync.centos.org/centos/|rsync|~500 GiB||12h"
    "kali|Kali Linux|Security-focused Debian derivative|rsync://rsync.kali.org/kali/|rsync|~600 GiB||6h"
    "opensuse|openSUSE|Community-supported SUSE variants|rsync://rsync.opensuse.org/opensuse/|rsync|~2.0 TiB|large|12h"
    "raspios|Raspberry Pi OS|Official OS for Raspberry Pi hardware|rsync://archive.raspberrypi.com/|rsync|~200 GiB||12h"
    "popos|Pop!_OS|System76 Ubuntu-based developer distro|rsync://apt.pop-os.org/release/|rsync|~300 GiB||12h"
    "nyarch|NyarchLinux|Arch-based anime desktop (SourceForge)|nyarch-sf:/home/frs/project/nyarchlinux/|rclone-sftp|~20 GiB||24h"
    )

SELECTED_MIRRORS=()
CUSTOM_MIRRORS=()
declare -A MIRROR_CREDS

# =============================================================================
# Panel helpers
# =============================================================================

catalog_field() { local entry="${MIRROR_CATALOG[$1]}"; IFS='|' read -ra p <<< "$entry"; echo "${p[$2]:-}"; }

is_selected() {
    local slug="$1"
    for s in "${SELECTED_MIRRORS[@]:-}"; do [[ "$s" == "$slug" ]] && return 0; done
    return 1
}

toggle_mirror() {
    local slug="$1" new=() found=false
    for s in "${SELECTED_MIRRORS[@]:-}"; do
        [[ "$s" == "$slug" ]] && found=true || new+=("$s")
    done
    [[ "$found" == true ]] && SELECTED_MIRRORS=("${new[@]:-}") || SELECTED_MIRRORS+=("$slug")
}

get_mirror_entry() {
    local target="$1"
    for (( i=0; i<${#MIRROR_CATALOG[@]}; i++ )); do
        local s; s=$(catalog_field "$i" 0)
        [[ "$s" == "$target" ]] && { echo "${MIRROR_CATALOG[$i]}"; return; }
    done
    for cm in "${CUSTOM_MIRRORS[@]:-}"; do
        local s; s=$(echo "$cm" | cut -d'|' -f1)
        [[ "$s" == "$target" ]] && { echo "$cm"; return; }
    done
}

show_panel() {
    clear
    echo -e "\n${B}  Mirror Selection${N}"
    echo -e "  Choose which distributions to host."
    echo ""
    rule
    printf "  %-3s  %-4s  %-14s  %-30s  %-10s  %s\n" "#" "Sel" "Slug" "Name" "Est. Size" "Interval"
    rule

    local catalog_count="${#MIRROR_CATALOG[@]}"
    for (( i=0; i<catalog_count; i++ )); do
        local slug name size warn interval
        slug=$(catalog_field "$i" 0); name=$(catalog_field "$i" 1)
        size=$(catalog_field "$i" 5); warn=$(catalog_field "$i" 6)
        interval=$(catalog_field "$i" 7); interval="${interval:-6h}"

        local marker="[ ]"; is_selected "$slug" && marker="[${G}✓${N}]"
        local warn_str=""; [[ "$warn" == "large" ]] && warn_str=" ${Y}⚠${N}"

        printf "  %-3s  " "$(( i+1 ))"
        echo -e "${marker}  $(printf '%-14s  %-30s  %-10s' "$slug" "$name" "$size")  ${interval}${warn_str}"
    done

    local custom_start=$(( catalog_count + 1 ))
    for (( j=0; j<${#CUSTOM_MIRRORS[@]}; j++ )); do
        local cslug cname csize cmethod cinterval
        cslug=$(echo "${CUSTOM_MIRRORS[$j]}" | cut -d'|' -f1)
        cname=$(echo "${CUSTOM_MIRRORS[$j]}" | cut -d'|' -f2)
        csize=$(echo "${CUSTOM_MIRRORS[$j]}" | cut -d'|' -f6)
        cmethod=$(echo "${CUSTOM_MIRRORS[$j]}" | cut -d'|' -f5)
        cinterval=$(echo "${CUSTOM_MIRRORS[$j]}" | cut -d'|' -f8); cinterval="${cinterval:-6h}"

        local cmarker="[ ]"; is_selected "$cslug" && cmarker="[${G}✓${N}]"
        local type_str=""
        [[ "$cmethod" == "original" ]] && type_str=" ${C}[origin]${N}"
        [[ "$cmethod" == "mirror"   ]] && type_str=" ${Y}[mirror]${N}"

        printf "  %-3s  " "$(( custom_start + j ))"
        echo -e "${cmarker}  $(printf '%-14s  %-30s  %-10s' "$cslug" "$cname" "$csize")  ${cinterval}${type_str}"
    done

    local add_n=$(( catalog_count + ${#CUSTOM_MIRRORS[@]} + 1 ))
    printf "  %-3s  %s\n" "$add_n" "     + Add custom mirror…"

    rule
    echo ""
    echo -e "  Selected: ${B}${#SELECTED_MIRRORS[@]}${N} mirror(s)   ${Y}⚠${N} = multi-TiB   ${C}[origin]${N} = no upstream   ${Y}[mirror]${N} = self-hosted upstream"
    echo ""
    echo -e "  Type a number to toggle  •  ${B}a${N} all  •  ${B}n${N} none  •  ${B}done${N} to continue"
    echo ""
}

prompt_custom_mirror() {
    echo ""
    echo -e "${B}  Add Custom Mirror${N}"
    echo ""

    local cslug cname cdesc cupstream cmethod csize cinterval

    read -rp "  Slug (e.g. alpine):                 " cslug
    [[ -z "$cslug" ]] && { warn "Slug cannot be empty."; return; }

    # Duplicate slug check
    local all_slugs=()
    for (( i=0; i<${#MIRROR_CATALOG[@]}; i++ )); do all_slugs+=("$(catalog_field "$i" 0)"); done
    for cm in "${CUSTOM_MIRRORS[@]:-}"; do all_slugs+=("$(echo "$cm" | cut -d'|' -f1)"); done
    for s in "${all_slugs[@]:-}"; do
        [[ "$s" == "$cslug" ]] && { warn "Slug '$cslug' already exists."; return; }
    done

    read -rp "  Display name:                       " cname
    read -rp "  Short description:                  " cdesc
    echo     "  Sync method:"
    echo     "    [1] rsync       — pull from a public rsync:// URL"
    echo     "    [2] rclone-http — pull from an HTTP/FTP upstream"
    echo     "    [3] original    — this server IS the origin; no upstream sync"
    echo     "    [4] mirror      — pull from a self-hosted rsync daemon"
    read -rp "  Choice [1]:                         " cmethod_n

    case "${cmethod_n:-1}" in
        2) cmethod="rclone-http" ;;
        3) cmethod="original"    ;;
        4) cmethod="mirror"      ;;
        *) cmethod="rsync"       ;;
    esac

    if [[ "$cmethod" == "original" ]]; then
        cupstream="none"
        echo ""; info "Original mirror — files pushed to: \${LINUX_DIR}/${cslug}/"; echo ""
    elif [[ "$cmethod" == "mirror" ]]; then
        echo ""
        echo -e "  ${B}Self-hosted mirror upstream${N}"
        echo -e "  Examples:  rsync://upstream.example.com/myproject   upstream.example.com::myproject"
        echo ""
        read -rp "  Upstream rsync URL:                 " cupstream
        [[ -z "$cupstream" ]] && { warn "Upstream URL cannot be empty for mirror type."; return; }
        read -rp "  Username [blank = anonymous]:        " cmirror_user
        if [[ -n "$cmirror_user" ]]; then
            read -rsp "  Password:                           " cmirror_pass; echo ""
            MIRROR_CREDS["${cslug}"]="${cmirror_user}:${cmirror_pass}"
            info "Credentials stored — will be written to /etc/ezmirror/${cslug}.secrets (mode 600)"
        else
            info "Anonymous — upstream accessed without credentials."
        fi
        echo ""
    else
        read -rp "  Upstream URL (rsync:// or https://): " cupstream
    fi

    read -rp "  Estimated size (e.g. ~50 GiB):      " csize
    read -rp "  Sync interval (e.g. 6h, 12h, 24h) [6h]: " cinterval
    cinterval="${cinterval:-6h}"

    CUSTOM_MIRRORS+=("${cslug}|${cname}|${cdesc}|${cupstream}|${cmethod}|${csize:-unknown}||${cinterval}")
    SELECTED_MIRRORS+=("$cslug")
    ok "Added '${cslug}' (${cmethod}, every ${cinterval}) and selected it."
    sleep 1
}

run_panel() {
    local catalog_count="${#MIRROR_CATALOG[@]}"

    while true; do
        show_panel
        local add_n=$(( catalog_count + ${#CUSTOM_MIRRORS[@]} + 1 ))

        read -rp "  > " input
        [[ -z "$input" || "${input,,}" == "done" || "${input,,}" == "d" ]] && break

        if [[ "${input,,}" == "a" ]]; then
            SELECTED_MIRRORS=()
            for (( i=0; i<catalog_count; i++ )); do SELECTED_MIRRORS+=("$(catalog_field "$i" 0)"); done
            for cm in "${CUSTOM_MIRRORS[@]:-}"; do SELECTED_MIRRORS+=("$(echo "$cm" | cut -d'|' -f1)"); done
            continue
        fi
        [[ "${input,,}" == "n" ]] && { SELECTED_MIRRORS=(); continue; }

        for token in $input; do
            if [[ "$token" =~ ^[0-9]+$ ]]; then
                local idx=$(( token - 1 ))
                if (( idx >= 0 && idx < catalog_count )); then
                    toggle_mirror "$(catalog_field "$idx" 0)"
                elif (( idx >= catalog_count && idx < catalog_count + ${#CUSTOM_MIRRORS[@]} )); then
                    toggle_mirror "$(echo "${CUSTOM_MIRRORS[$(( idx - catalog_count ))]}" | cut -d'|' -f1)"
                elif (( token == add_n )); then
                    prompt_custom_mirror
                fi
            fi
        done
    done

    if [[ ${#SELECTED_MIRRORS[@]} -eq 0 ]]; then
        warn "No mirrors selected — you must select at least one."
        read -rp "  Press Enter to go back…" _
        run_panel
    fi
}

# =============================================================================
# 0. Branding
# =============================================================================

echo -e "\n${B}ezmirror Setup${N}"
echo    "  Press Enter to accept the shown default."
echo    "  Pass --unattended and set EZMIRROR_* env vars to skip all prompts."
echo ""

ask "Lab name         " LAB_NAME  "MyOrg Open Source Lab" EZMIRROR_LAB_NAME
ask "Domain           " DOMAIN    "mirror.example.com"    EZMIRROR_DOMAIN
ask "Location         " LOCATION  "Anytown, ST, US"       EZMIRROR_LOCATION
ask "GitHub username  " GH_USER   "netplayz"              EZMIRROR_GH_USER

LOCATION_CITY="${LOCATION%, *}"

echo ""
echo -e "  ${B}Lab name${N}  $LAB_NAME"
echo -e "  ${B}Domain${N}    $DOMAIN"
echo -e "  ${B}Location${N}  $LOCATION"
echo ""
if [[ "$UNATTENDED" != true ]]; then
    read -rp "  Looks good? [Y/n] " _confirm
    [[ "${_confirm,,}" == "n" ]] && die "Aborted — re-run to try again."
fi

mkdir -p /etc/ezmirror
{
    echo "# ezmirror — lab configuration"
    echo "# Generated by setup.sh on $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "LAB_NAME=\"${LAB_NAME}\""
    echo "DOMAIN=\"${DOMAIN}\""
    echo "LOCATION=\"${LOCATION}\""
    echo "GH_USER=\"${GH_USER}\""
} > /etc/ezmirror/lab.conf

# =============================================================================
# 0b. Alert config
# =============================================================================

echo ""
echo -e "${B}  Alert Configuration${N}"
echo -e "  ezmirror can notify you when a sync fails."
echo ""

ask "Discord webhook URL [blank = skip]" ALERT_WEBHOOK "" EZMIRROR_WEBHOOK
ask "Alert email [blank = skip]        " ALERT_EMAIL   "" EZMIRROR_EMAIL

{
    echo "# ezmirror — alert configuration"
    echo "ALERT_WEBHOOK=\"${ALERT_WEBHOOK}\""
    echo "ALERT_EMAIL=\"${ALERT_EMAIL}\""
} > /etc/ezmirror/alert.conf
chmod 600 /etc/ezmirror/alert.conf
ok "Alert config saved (/etc/ezmirror/alert.conf)"

# =============================================================================
# 1. Volume / storage path selection
# =============================================================================

select_volume() {
    clear
    echo -e "\n${B}  Volume Selection${N}"
    echo -e "  Choose where mirror data will be stored."
    echo ""
    rule
    printf "  %-4s  %-28s  %-10s  %-10s  %s\n" "#" "Mount Point" "Total" "Available" "Device"
    rule

    mapfile -t VOLUME_MOUNTS < <(
        df -h --output=target,fstype,size,avail,source 2>/dev/null \
        | tail -n +2 \
        | awk '$2 !~ /^(tmpfs|devtmpfs|squashfs|overlay|efivarfs|devpts|sysfs|proc|cgroup|hugetlbfs|mqueue|debugfs|tracefs|fusectl|binfmt_misc|ramfs|securityfs|pstore|autofs|configfs)$/ \
               && $1 !~ /^\/sys|^\/proc|^\/dev\/pts|^\/run\/lock|^\/run\/user/ \
               {print $1"|"$3"|"$4"|"$5}' \
        | sort -u
    )

    if [[ ${#VOLUME_MOUNTS[@]} -eq 0 ]]; then
        warn "Could not detect any suitable volumes — using default path."
        MIRROR_BASE_DIR="/var/www/html"; return
    fi

    for (( i=0; i<${#VOLUME_MOUNTS[@]}; i++ )); do
        IFS='|' read -r mnt sz avail src <<< "${VOLUME_MOUNTS[$i]}"
        printf "  %-4s  %-28s  %-10s  %-10s  %s\n" "$(( i+1 ))" "$mnt" "$sz" "$avail" "$src"
    done

    local custom_n=$(( ${#VOLUME_MOUNTS[@]} + 1 ))
    printf "  %-4s  %s\n" "$custom_n" "Enter a custom path…"
    rule
    echo ""
    echo -e "  Mirror data will be stored under the chosen mount point."
    echo -e "  Recommended: at least ${Y}500 GiB${N} free (multi-TiB for large mirrors)."
    echo ""

    # Respect EZMIRROR_VOLUME env var
    if [[ -n "${EZMIRROR_VOLUME:-}" ]]; then
        MIRROR_BASE_DIR="${EZMIRROR_VOLUME%/}"
        ok "Volume (env): ${MIRROR_BASE_DIR}"; return
    fi

    if [[ "$UNATTENDED" == true ]]; then
        IFS='|' read -r MIRROR_MOUNT _ _ _ <<< "${VOLUME_MOUNTS[0]}"
        MIRROR_BASE_DIR="${MIRROR_MOUNT%/}/ezmirror"
        ok "Volume (auto): ${MIRROR_BASE_DIR}"; return
    fi

    while true; do
        read -rp "  Choice [1]: " _vol_choice
        _vol_choice="${_vol_choice:-1}"
        if [[ "$_vol_choice" =~ ^[0-9]+$ ]]; then
            local idx=$(( _vol_choice - 1 ))
            if (( idx >= 0 && idx < ${#VOLUME_MOUNTS[@]} )); then
                IFS='|' read -r MIRROR_MOUNT _ _ _ <<< "${VOLUME_MOUNTS[$idx]}"
                MIRROR_MOUNT="${MIRROR_MOUNT%/}"
                MIRROR_BASE_DIR="${MIRROR_MOUNT}/ezmirror"
                echo ""; ok "Volume: ${MIRROR_MOUNT}"; ok "Data path: ${MIRROR_BASE_DIR}/pub/"
                break
            elif (( _vol_choice == custom_n )); then
                read -rp "  Absolute path (e.g. /mnt/data/mirrors): " MIRROR_BASE_DIR
                [[ -z "$MIRROR_BASE_DIR" ]] && { warn "Path cannot be empty."; continue; }
                [[ "${MIRROR_BASE_DIR:0:1}" != "/" ]] && { warn "Path must be absolute."; continue; }
                MIRROR_BASE_DIR="${MIRROR_BASE_DIR%/}"
                echo ""; ok "Custom path: ${MIRROR_BASE_DIR}"; break
            else
                warn "Invalid choice — enter a number between 1 and ${custom_n}."
            fi
        else
            warn "Please enter a number."
        fi
    done
    sleep 1
}

select_volume

PUB_DIR="${MIRROR_BASE_DIR}/pub"
LINUX_DIR="${MIRROR_BASE_DIR}/pub/linux"
WEBROOT="/var/www/html"

if [[ "$MIRROR_BASE_DIR" != "$WEBROOT" ]]; then
    echo ""
    info "Mirror data:  ${MIRROR_BASE_DIR}/pub/"
    info "Symlink:      ${WEBROOT}/pub  →  ${MIRROR_BASE_DIR}/pub"
    echo ""
fi

# =============================================================================
# 2. Mirror selection panel
# =============================================================================

if [[ -n "${EZMIRROR_MIRRORS:-}" ]]; then
    IFS=',' read -ra SELECTED_MIRRORS <<< "$EZMIRROR_MIRRORS"
    info "Mirrors (env): ${SELECTED_MIRRORS[*]}"
else
    run_panel
fi

echo -e "\n${B}  Selected mirrors:${N}"
for slug in "${SELECTED_MIRRORS[@]}"; do
    entry="$(get_mirror_entry "$slug")"
    IFS='|' read -ra parts <<< "$entry"
    interval="${parts[7]:-6h}"
    method_label="${parts[4]}"
    [[ "$method_label" == "original" ]] && method_label="${C}original${N}"
    echo -e "    ${G}✓${N}  ${parts[0]}  —  ${parts[1]}  (${method_label}, every ${interval})"
done
echo ""

# =============================================================================
# 2b. Disk space pre-check
# =============================================================================

hdr "Disk Space Pre-check"

avail_bytes=$(df -B1 --output=avail "$MIRROR_BASE_DIR" 2>/dev/null | tail -1 || \
              df -B1 --output=avail "$(dirname "$MIRROR_BASE_DIR")" 2>/dev/null | tail -1 || echo 0)
avail_gib=$(( avail_bytes / 1073741824 ))
info "Available on target volume: ${avail_gib} GiB"

disk_warn=false
for slug in "${SELECTED_MIRRORS[@]}"; do
    warn_field="$(get_mirror_entry "$slug" | cut -d'|' -f7)"
    if [[ "$warn_field" == "large" ]]; then disk_warn=true; break; fi
done

if [[ "$disk_warn" == true ]]; then
    warn "One or more selected mirrors are multi-TiB."
    warn "Ensure ${avail_gib} GiB is sufficient before proceeding."
    echo ""
fi

if [[ "$UNATTENDED" != true ]]; then
    read -rp "  Proceed with setup? [Y/n] " _go
    [[ "${_go,,}" == "n" ]] && die "Aborted."
fi

# =============================================================================
# 2c. Torrent seeding option
# =============================================================================

ENABLE_TORRENTS=false
if [[ "${EZMIRROR_TORRENTS:-}" == "yes" ]]; then
    ENABLE_TORRENTS=true
elif [[ "$UNATTENDED" != true ]]; then
    echo ""
    read -rp "  Enable torrent seeding for .iso files? (installs mktorrent) [y/N] " _torrents
    [[ "${_torrents,,}" == "y" ]] && ENABLE_TORRENTS=true
fi

# =============================================================================
# Path constants
# =============================================================================

CONF_DIR="/etc/ezmirror"
MIRRORS_CONF="${CONF_DIR}/mirrors.conf"
SYNC_BIN="/usr/local/bin/ezmirror-sync"
MANAGE_BIN="/usr/local/bin/ezmirror-manage"
STATUS_BIN="/usr/local/bin/ezmirror-status"
LOGS_BIN="/usr/local/bin/ezmirror-logs"
LOGFILE="/var/log/ezmirror.log"

# =============================================================================
hdr "1. Dependencies"
# =============================================================================

apt-get update -qq

for pkg in nginx rsync jq curl git moreutils; do
    dpkg -s "$pkg" &>/dev/null && ok "$pkg" || { apt-get install -y -qq "$pkg" 2>/dev/null; ok "$pkg"; }
done

# mktorrent for torrent seeding
if [[ "$ENABLE_TORRENTS" == true ]]; then
    dpkg -s mktorrent &>/dev/null && ok "mktorrent" || { apt-get install -y -qq mktorrent 2>/dev/null; ok "mktorrent"; }
fi

# rclone — only if needed
needs_rclone=false
for slug in "${SELECTED_MIRRORS[@]}"; do
    method="$(get_mirror_entry "$slug" | cut -d'|' -f5)"
    [[ "$method" == rclone-* ]] && needs_rclone=true && break
done

if [[ "$needs_rclone" == true ]]; then
    if command -v rclone &>/dev/null; then
        ok "rclone  ($(rclone --version | awk 'NR==1{print $2}'))"
    else
        info "Installing rclone…"
        curl -fsSL https://rclone.org/install.sh | bash -s -- --quiet
        ok "rclone  ($(rclone --version | awk 'NR==1{print $2}'))"
    fi
fi

# =============================================================================
hdr "2. Directories"
# =============================================================================

mkdir -p "$CONF_DIR" "$LINUX_DIR"

if [[ "$MIRROR_BASE_DIR" != "$WEBROOT" ]]; then
    [[ -L "${WEBROOT}/pub" ]] && rm -f "${WEBROOT}/pub"
    [[ -d "${WEBROOT}/pub" && ! -L "${WEBROOT}/pub" ]] && \
        mv "${WEBROOT}/pub" "${WEBROOT}/pub.bak.$(date +%s)" && \
        info "Moved existing ${WEBROOT}/pub to backup"
    ln -sf "$PUB_DIR" "${WEBROOT}/pub"
    ok "Symlink: ${WEBROOT}/pub → ${PUB_DIR}"
fi

for slug in "${SELECTED_MIRRORS[@]}"; do
    mkdir -p "${LINUX_DIR}/${slug}"
    ok "/pub/linux/${slug}/"
done
chown -R www-data:www-data "$PUB_DIR"
chmod -R 755 "$PUB_DIR"

# =============================================================================
hdr "3. Config files"
# =============================================================================

{
    echo "# ezmirror — active mirrors"
    echo "# Generated by setup.sh on $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "# Format: slug|Name|Description|Upstream|Method|Size|warn|interval|bandwidth|retention_days|retention_max_gib"
    echo "#"
    for slug in "${SELECTED_MIRRORS[@]}"; do
        entry="$(get_mirror_entry "$slug")"
        IFS='|' read -ra p <<< "$entry"
        echo "${p[0]}|${p[1]}|${p[2]}|${p[3]}|${p[4]}|${p[5]:-}|${p[6]:-}|${p[7]:-6h}|${p[8]:-0}|${p[9]:-0}|${p[10]:-0}"
    done
} > "$MIRRORS_CONF"
ok "$MIRRORS_CONF"

{
    echo "# ezmirror — path configuration"
    echo "# Generated by setup.sh on $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "WEBROOT=\"${WEBROOT}\""
    echo "MIRROR_BASE_DIR=\"${MIRROR_BASE_DIR}\""
    echo "PUB_DIR=\"${PUB_DIR}\""
    echo "LINUX_DIR=\"${LINUX_DIR}\""
    echo "ENABLE_TORRENTS=\"${ENABLE_TORRENTS}\""
} > "${CONF_DIR}/paths.conf"
ok "${CONF_DIR}/paths.conf"

# Initialise status.json
echo '{"generated":0,"mirrors":{}}' > "${WEBROOT}/status.json"
chown www-data:www-data "${WEBROOT}/status.json"
ok "${WEBROOT}/status.json"

# =============================================================================
hdr "4. HTML pages"
# =============================================================================

# ── Shared CSS helpers ─────────────────────────────────────────────────────────

SHARED_FONTS='<link rel="preconnect" href="https://fonts.googleapis.com">
  <link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500&family=IBM+Plex+Sans:wght@300;400;500;600&display=swap" rel="stylesheet">'

THEME_TOGGLE_JS='<script>
(function(){
  var t=localStorage.getItem("em-theme")||"auto";
  if(t==="dark")document.documentElement.setAttribute("data-theme","dark");
  else if(t==="light")document.documentElement.setAttribute("data-theme","light");
})();
</script>'

THEME_TOGGLE_BTN='<button id="theme-btn" onclick="(function(){var h=document.documentElement,c=h.getAttribute(\"data-theme\")||\"auto\",n=c===\"dark\"?\"light\":\"dark\";h.setAttribute(\"data-theme\",n);localStorage.setItem(\"em-theme\",n);})();" title="Toggle dark/light mode" style="background:none;border:1px solid var(--border);color:var(--muted);padding:.3rem .6rem;border-radius:4px;cursor:pointer;font-family:var(--mono);font-size:.72rem;">◐</button>'

# ── Homepage ──────────────────────────────────────────────────────────────────
cat > "${WEBROOT}/index.html" << HOMEOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${LAB_NAME}</title>
  ${SHARED_FONTS}
  ${THEME_TOGGLE_JS}
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    :root {
      --bg: #0f0f0f; --surface: #161616; --border: #262626;
      --text: #e8e8e8; --muted: #737373; --dim: #404040; --accent: #4ea3e0;
      --mono: 'IBM Plex Mono', monospace; --sans: 'IBM Plex Sans', sans-serif;
    }
    [data-theme="light"] {
      --bg: #f8f8f6; --surface: #fff; --border: #e2e2dc;
      --text: #1a1a18; --muted: #6b6b63; --dim: #d0d0c8; --accent: #2563a8;
    }
    @media (prefers-color-scheme: light) {
      :root:not([data-theme="dark"]) {
        --bg: #f8f8f6; --surface: #fff; --border: #e2e2dc;
        --text: #1a1a18; --muted: #6b6b63; --dim: #d0d0c8; --accent: #2563a8;
      }
    }
    html { font-size: 15px; }
    body { background: var(--bg); color: var(--text); font-family: var(--sans); min-height: 100vh; display: flex; flex-direction: column; transition: background .2s, color .2s; }
    nav { border-bottom: 1px solid var(--border); padding: 1rem 2rem; display: flex; align-items: center; justify-content: space-between; }
    .nav-logo { font-family: var(--mono); font-size: .85rem; color: var(--text); text-decoration: none; letter-spacing: .02em; }
    .nav-links { display: flex; gap: 1.5rem; list-style: none; align-items: center; }
    .nav-links a { font-size: .8rem; color: var(--muted); text-decoration: none; transition: color .15s; }
    .nav-links a:hover { color: var(--text); }
    .hero { flex: 1; display: flex; flex-direction: column; justify-content: center; padding: 6rem 2rem 4rem; max-width: 760px; margin: 0 auto; width: 100%; }
    .hero-label { font-family: var(--mono); font-size: .72rem; color: var(--muted); letter-spacing: .1em; text-transform: uppercase; margin-bottom: 1.5rem; }
    .hero h1 { font-weight: 300; font-size: clamp(2rem, 5vw, 3.2rem); line-height: 1.15; letter-spacing: -.02em; margin-bottom: 1.5rem; }
    .hero h1 strong { font-weight: 600; }
    .hero p { font-size: .95rem; color: var(--muted); line-height: 1.75; max-width: 520px; margin-bottom: 3rem; }
    .mirrors { display: flex; flex-direction: column; gap: .75rem; margin-bottom: 3rem; }
    .mirror-row { display: grid; grid-template-columns: 1fr auto; align-items: center; gap: 1rem; padding: 1rem 1.25rem; background: var(--surface); border: 1px solid var(--border); border-radius: 6px; text-decoration: none; transition: border-color .15s, background .15s; }
    .mirror-row:hover { border-color: var(--dim); background: var(--surface); filter: brightness(1.05); }
    .mirror-row.origin-row { border-left: 2px solid var(--accent); }
    .mirror-name { font-family: var(--mono); font-size: .85rem; color: var(--text); margin-bottom: .2rem; }
    .mirror-desc { font-size: .78rem; color: var(--muted); }
    .mirror-meta { font-family: var(--mono); font-size: .68rem; color: var(--muted); margin-top: .3rem; }
    .mirror-meta .status-ok  { color: #4caf7d; }
    .mirror-meta .status-err { color: #e05a4e; }
    .origin-badge { font-family: var(--mono); font-size: .68rem; color: var(--accent); letter-spacing: .06em; text-transform: uppercase; margin-top: .2rem; }
    .mirror-arrow { color: var(--dim); font-size: .85rem; font-family: var(--mono); flex-shrink: 0; transition: color .15s; }
    .mirror-row:hover .mirror-arrow { color: var(--text); }
    .empty { font-family: var(--mono); font-size: .8rem; color: var(--muted); padding: 1.5rem 1.25rem; text-align: center; }
    .stats { display: flex; gap: 2.5rem; flex-wrap: wrap; padding-top: 2rem; border-top: 1px solid var(--border); }
    .stat .label { font-family: var(--mono); font-size: .68rem; color: var(--muted); letter-spacing: .08em; text-transform: uppercase; margin-bottom: .2rem; }
    .stat .value { font-size: .85rem; color: var(--text); }
    footer { border-top: 1px solid var(--border); padding: 1.25rem 2rem; display: flex; justify-content: space-between; flex-wrap: wrap; gap: .5rem; font-family: var(--mono); font-size: .72rem; color: var(--muted); }
    footer a { color: var(--muted); text-decoration: none; }
    footer a:hover { color: var(--text); }
    @media (max-width:520px) { nav { flex-direction: column; align-items: flex-start; gap: 1rem; } .stats { gap: 1.5rem; } footer { flex-direction: column; } }
  </style>
</head>
<body>
<nav>
  <a class="nav-logo" href="/">${DOMAIN}</a>
  <ul class="nav-links">
    <li><a href="/pub/">pub</a></li>
    <li><a href="/status.json" target="_blank">status.json</a></li>
    <li><a href="https://github.com/${GH_USER}" target="_blank" rel="noopener">github</a></li>
    <li>${THEME_TOGGLE_BTN}</li>
  </ul>
</nav>
<div class="hero">
  <p class="hero-label">${LAB_NAME}</p>
  <h1>Public software<br><strong>mirror infrastructure.</strong></h1>
  <p>Free, fast access to open source Linux distributions and software. Hosted in ${LOCATION_CITY}.</p>
  <div class="mirrors" id="mirror-list"><p class="empty">Loading mirrors…</p></div>
  <div class="stats">
    <div class="stat"><div class="label">Location</div><div class="value">${LOCATION}</div></div>
    <div class="stat"><div class="label">Protocol</div><div class="value">rsync / rclone</div></div>
    <div class="stat"><div class="label">Mirrors</div><div class="value" id="mirror-count">—</div></div>
    <div class="stat"><div class="label">Last Sync</div><div class="value" id="last-sync">—</div></div>
  </div>
</div>
<footer>
  <span>${LAB_NAME} — powered by <a href="https://github.com/netplayz/ezmirror" target="_blank" rel="noopener">ezmirror</a></span>
  <span><a href="/pub/">Browse all files →</a></span>
</footer>
<script>
function fmtAgo(ts){if(!ts)return'never';const s=Math.round(Date.now()/1000-ts);if(s<60)return s+'s ago';if(s<3600)return Math.round(s/60)+'m ago';if(s<86400)return Math.round(s/3600)+'h ago';return Math.round(s/86400)+'d ago';}
Promise.all([
  fetch('/mirrors.json').then(r=>r.json()).catch(()=>[]),
  fetch('/status.json').then(r=>r.json()).catch(()=>({}))
]).then(([mirrors, statusData]) => {
  const list = document.getElementById('mirror-list');
  document.getElementById('mirror-count').textContent = mirrors.length;
  const sm = statusData.mirrors || {};
  let newest = 0;
  Object.values(sm).forEach(m => { if(m.last_sync > newest) newest = m.last_sync; });
  document.getElementById('last-sync').textContent = fmtAgo(newest);
  if (!mirrors.length) { list.innerHTML = '<p class="empty">No mirrors configured.</p>'; return; }
  list.innerHTML = mirrors.map(m => {
    const isOrigin = m.method === 'original';
    const st = sm[m.slug] || {};
    let metaHtml = '';
    if(st.last_sync) {
      const cls = st.exit_code === 0 ? 'status-ok' : 'status-err';
      const icon = st.exit_code === 0 ? '✓' : '✗';
      metaHtml = '<div class="mirror-meta"><span class="'+cls+'">'+icon+' synced '+fmtAgo(st.last_sync)+'</span></div>';
    }
    return '<a class="mirror-row'+(isOrigin?' origin-row':'')+'" href="'+m.path+'">' +
      '<div><div class="mirror-name">'+m.path+'</div>' +
      '<div class="mirror-desc">'+m.name+' — '+m.desc+'</div>' +
      (isOrigin?'<div class="origin-badge">★ origin</div>':'') +
      metaHtml+'</div>' +
      '<span class="mirror-arrow">→</span></a>';
  }).join('');
});
</script>
</body>
</html>
HOMEOF
ok "index.html"

# ── Shared listing page generator ─────────────────────────────────────────────
generate_listing_page() {
    local title_path="$1" breadcrumbs="$2" files_json="$3" base_href="$4"
    local parent_href; parent_href="$(dirname "${base_href%/}")/"
    [[ "$parent_href" == "//" ]] && parent_href="/"

    cat << LISTEOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Index of ${title_path} — ${LAB_NAME}</title>
  ${SHARED_FONTS}
  ${THEME_TOGGLE_JS}
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    :root { --bg:#f8f8f6;--surface:#fff;--border:#e2e2dc;--text:#1a1a18;--muted:#6b6b63;--accent:#2563a8;--mono:'IBM Plex Mono',monospace;--sans:'IBM Plex Sans',sans-serif; }
    [data-theme="dark"] { --bg:#0f0f0f;--surface:#161616;--border:#262626;--text:#e8e8e8;--muted:#737373;--accent:#4ea3e0; }
    @media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) { --bg:#0f0f0f;--surface:#161616;--border:#262626;--text:#e8e8e8;--muted:#737373;--accent:#4ea3e0; } }
    html { font-size: 15px; } body { background:var(--bg);color:var(--text);font-family:var(--sans);line-height:1.5;transition:background .2s,color .2s; }
    .topbar { background:var(--surface);border-bottom:1px solid var(--border);padding:.6rem 0; }
    .topbar-inner { max-width:960px;margin:0 auto;padding:0 2rem;display:flex;gap:1rem;align-items:center;justify-content:space-between;font-size:.8rem;color:var(--muted);font-family:var(--mono); }
    .topbar-inner a { color:var(--accent);text-decoration:none; } .topbar-inner a:hover { text-decoration:underline; }
    .breadcrumb { display:flex;gap:1rem;align-items:center; }
    .sep { color:var(--border); }
    .main { max-width:960px;margin:0 auto;padding:2.5rem 2rem 5rem; }
    .page-head { margin-bottom:1.5rem;padding-bottom:1.25rem;border-bottom:1px solid var(--border);display:flex;justify-content:space-between;align-items:flex-end;flex-wrap:wrap;gap:1rem; }
    .page-head h1 { font-family:var(--mono);font-size:1.05rem;font-weight:500;margin-bottom:.35rem; }
    .page-head h1 .path { color:var(--accent); } .page-head p { font-size:.83rem;color:var(--muted); }
    .search-wrap { display:flex;gap:.5rem;align-items:center; }
    #search { background:var(--surface);border:1px solid var(--border);color:var(--text);font-family:var(--mono);font-size:.8rem;padding:.35rem .7rem;border-radius:4px;outline:none;width:180px;transition:border-color .15s; }
    #search:focus { border-color:var(--accent); }
    .file-table-wrap { background:var(--surface);border:1px solid var(--border);border-radius:6px;overflow:hidden;margin-bottom:2.5rem; }
    table { width:100%;border-collapse:collapse;font-family:var(--mono);font-size:.82rem; }
    thead tr { background:var(--bg);border-bottom:1px solid var(--border); }
    th { text-align:left;padding:.55rem 1rem;font-size:.72rem;font-weight:500;letter-spacing:.04em;text-transform:uppercase;color:var(--muted);cursor:pointer;user-select:none; }
    th:hover { color:var(--text); }
    tbody tr { border-bottom:1px solid var(--border);transition:background .1s; } tbody tr:last-child { border-bottom:none; } tbody tr:hover { background:var(--bg); }
    td { padding:.55rem 1rem;vertical-align:middle; } td.col-name { width:100%; }
    td.col-size,td.col-date { white-space:nowrap;color:var(--muted); }
    td.col-name a { color:var(--accent);text-decoration:none;display:inline-flex;align-items:center;gap:.45rem; } td.col-name a:hover { text-decoration:underline; }
    tr.hidden { display:none; }
    footer { border-top:1px solid var(--border);padding-top:1.25rem;font-size:.78rem;color:var(--muted);display:flex;flex-wrap:wrap;justify-content:space-between;gap:.5rem; }
    footer a { color:var(--muted);text-decoration:none; } footer a:hover { color:var(--accent); }
    @media(max-width:580px){th.col-date,td.col-date{display:none;} #search{width:120px;}}
  </style>
</head>
<body>
<div class="topbar"><div class="topbar-inner">
  <div class="breadcrumb">${breadcrumbs}</div>
  ${THEME_TOGGLE_BTN}
</div></div>
<div class="main">
  <div class="page-head">
    <div>
      <h1>Index of <span class="path">${title_path}</span></h1>
      <p>${LAB_NAME} — ${LOCATION}</p>
    </div>
    <div class="search-wrap">
      <input id="search" type="search" placeholder="filter…" autocomplete="off" spellcheck="false">
    </div>
  </div>
  <div class="file-table-wrap">
    <table id="listing">
      <thead><tr>
        <th class="col-name" onclick="sortTable(0)">Name ↕</th>
        <th class="col-date" onclick="sortTable(1)">Last Modified ↕</th>
        <th class="col-size" onclick="sortTable(2)">Size ↕</th>
      </tr></thead>
      <tbody>
        <tr><td class="col-name"><a href="${parent_href}">↑ Parent Directory</a></td><td class="col-date"></td><td class="col-size">—</td></tr>
      </tbody>
    </table>
  </div>
  <footer><span>${LAB_NAME}</span><span><a href="/">← Home</a></span></footer>
</div>
<script>
function fmtBytes(b){if(!b||isNaN(b))return'—';const u=['B','KiB','MiB','GiB'];let i=0,n=+b;while(n>=1024&&i<3){n/=1024;i++;}return n.toFixed(i?1:0)+'\u202f'+u[i];}
function fmtTime(t){if(!t)return'—';return new Date(t*1000).toISOString().slice(0,16).replace('T',' ');}
var rows=[];
function addRow(name,isDir,size,mtime){
  const ico=isDir?'📁':'📄',href='${base_href}'+name+(isDir?'/':'');
  const tr=document.createElement('tr');
  tr.dataset.name=name.toLowerCase(); tr.dataset.size=isDir?-1:(size||0); tr.dataset.mtime=mtime||0;
  tr.innerHTML='<td class="col-name"><a href="'+href+'">'+ico+' '+name+(isDir?'/':'')+'</a></td><td class="col-date">'+fmtTime(mtime)+'</td><td class="col-size">'+(isDir?'—':fmtBytes(size))+'</td>';
  document.querySelector('#listing tbody').appendChild(tr);
  rows.push(tr);
}
fetch('${files_json}').then(r=>r.json())
  .then(es=>es.filter(e=>e.name!=='index.html'&&e.name!=='files.json')
    .sort((a,b)=>(a.type==='directory')!==(b.type==='directory')?a.type==='directory'?-1:1:a.name.localeCompare(b.name))
    .forEach(e=>addRow(e.name,e.type==='directory',e.size,e.mtime))).catch(()=>{});
document.getElementById('search').addEventListener('input',function(){
  const q=this.value.toLowerCase().trim();
  rows.forEach(r=>{r.classList.toggle('hidden',!!q&&!r.dataset.name.includes(q));});
});
var sortDir={};
function sortTable(col){
  const keys=['name','mtime','size'];const k=keys[col];
  sortDir[k]=!sortDir[k];
  const tbody=document.querySelector('#listing tbody');
  const parent=tbody.firstElementChild;
  rows.sort((a,b)=>{
    let av=a.dataset[k],bv=b.dataset[k];
    if(col>0){av=+av;bv=+bv;}
    return(av<bv?-1:av>bv?1:0)*(sortDir[k]?1:-1);
  });
  rows.forEach(r=>tbody.appendChild(r));
}
</script>
</body>
</html>
LISTEOF
}

generate_listing_page \
    "/pub" \
    "<a href=\"/\">${DOMAIN}</a><span class=\"sep\">/</span><span>pub</span>" \
    "/pub/files.json" "/pub/" \
    > "${PUB_DIR}/index.html"
ok "pub/index.html"

generate_listing_page \
    "/pub/linux" \
    "<a href=\"/\">${DOMAIN}</a><span class=\"sep\">/</span><a href=\"/pub/\">pub</a><span class=\"sep\">/</span><span>linux</span>" \
    "/pub/linux/files.json" "/pub/linux/" \
    > "${LINUX_DIR}/index.html"
ok "pub/linux/index.html"

# ── Per-mirror index pages ─────────────────────────────────────────────────────
generate_mirror_page() {
    local slug="$1" name="$2" desc="$3" upstream="$4" method="$5"
    local mirror_dir="${LINUX_DIR}/${slug}"
    local subhead meta_upstream_html push_notice_html=""

    if [[ "$method" == "original" ]]; then
        subhead="Serving original content — this server is the primary source"
        meta_upstream_html='<div class="meta-item"><div class="label">Role</div><div class="value">Origin server<br><span style="color:var(--muted);font-size:.8rem">Files are maintained here directly.</span></div></div>'
        push_notice_html='<div class="notice origin-notice">★ This is an <strong>original mirror</strong> — content is published here first.</div>'
    elif [[ "$method" == "mirror" ]]; then
        local uh="${upstream#rsync://}"; uh="${uh%%/*}"; uh="${uh%%::*}"
        subhead="Mirrored from self-hosted origin <strong>${uh}</strong> — synced periodically"
        meta_upstream_html="<div class=\"meta-item\"><div class=\"label\">Upstream</div><div class=\"value\">${uh}<br><span style=\"color:var(--muted);font-size:.8rem\">Self-hosted mirror origin</span></div></div>"
        push_notice_html='<div class="notice mirror-notice">⇄ This is a <strong>downstream mirror</strong> of a self-hosted origin. Content is pulled automatically.</div>'
    else
        local uh="${upstream#rsync://}"; uh="${uh#sftp://}"; uh="${uh%%/*}"
        [[ "$uh" == *":"* ]] && uh="${uh#*:}"
        subhead="Mirrored from <a href=\"${upstream}\" target=\"_blank\" rel=\"noopener\">${uh}</a> — synced periodically"
        meta_upstream_html="<div class=\"meta-item\"><div class=\"label\">Upstream</div><div class=\"value\"><a href=\"${upstream}\" target=\"_blank\" rel=\"noopener\">${uh}</a></div></div>"
        push_notice_html='<div class="notice" id="sync-notice">Last sync time unavailable.</div>'
    fi

    cat > "${mirror_dir}/index.html" << MIREOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Index of /pub/linux/${slug} — ${LAB_NAME}</title>
  ${SHARED_FONTS}
  ${THEME_TOGGLE_JS}
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    :root { --bg:#f8f8f6;--surface:#fff;--border:#e2e2dc;--text:#1a1a18;--muted:#6b6b63;--accent:#2563a8;--origin:#1a7a5e;--mono:'IBM Plex Mono',monospace;--sans:'IBM Plex Sans',sans-serif; }
    [data-theme="dark"] { --bg:#0f0f0f;--surface:#161616;--border:#262626;--text:#e8e8e8;--muted:#737373;--accent:#4ea3e0;--origin:#3ab87a; }
    @media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) { --bg:#0f0f0f;--surface:#161616;--border:#262626;--text:#e8e8e8;--muted:#737373;--accent:#4ea3e0;--origin:#3ab87a; } }
    html { font-size: 15px; } body { background:var(--bg);color:var(--text);font-family:var(--sans);line-height:1.5;transition:background .2s,color .2s; }
    .topbar { background:var(--surface);border-bottom:1px solid var(--border);padding:.6rem 0; }
    .topbar-inner { max-width:960px;margin:0 auto;padding:0 2rem;display:flex;gap:1rem;align-items:center;justify-content:space-between;font-size:.8rem;color:var(--muted);font-family:var(--mono); }
    .topbar-inner a { color:var(--accent);text-decoration:none; } .topbar-inner a:hover { text-decoration:underline; }
    .breadcrumb { display:flex;gap:1rem;align-items:center; }
    .sep { color:var(--border); }
    .main { max-width:960px;margin:0 auto;padding:2.5rem 2rem 5rem; }
    .page-head { margin-bottom:1.5rem;padding-bottom:1.25rem;border-bottom:1px solid var(--border);display:flex;justify-content:space-between;align-items:flex-end;flex-wrap:wrap;gap:1rem; }
    .page-head h1 { font-family:var(--mono);font-size:1.05rem;font-weight:500;margin-bottom:.35rem; }
    .page-head h1 .path { color:var(--accent); }
    .page-head p { font-size:.83rem;color:var(--muted); } .page-head p a { color:var(--accent);text-decoration:none; }
    .status-badge { font-family:var(--mono);font-size:.72rem;padding:.3rem .7rem;border-radius:4px;border:1px solid var(--border); }
    .status-badge.ok  { color:#4caf7d;border-color:#4caf7d22; }
    .status-badge.err { color:#e05a4e;border-color:#e05a4e22; }
    .notice { font-size:.8rem;color:var(--muted);background:var(--surface);border:1px solid var(--border);border-left:3px solid var(--accent);border-radius:0 4px 4px 0;padding:.7rem 1rem;margin-bottom:2.5rem; }
    .origin-notice { color:var(--origin);border-left-color:var(--origin); }
    .mirror-notice  { color:#7a5e1a;border-left-color:#c9a227; }
    .search-wrap { display:flex;gap:.5rem;align-items:center; }
    #search { background:var(--surface);border:1px solid var(--border);color:var(--text);font-family:var(--mono);font-size:.8rem;padding:.35rem .7rem;border-radius:4px;outline:none;width:180px;transition:border-color .15s; }
    #search:focus { border-color:var(--accent); }
    .file-table-wrap { background:var(--surface);border:1px solid var(--border);border-radius:6px;overflow:hidden;margin-bottom:2.5rem; }
    table { width:100%;border-collapse:collapse;font-family:var(--mono);font-size:.82rem; }
    thead tr { background:var(--bg);border-bottom:1px solid var(--border); }
    th { text-align:left;padding:.55rem 1rem;font-size:.72rem;font-weight:500;letter-spacing:.04em;text-transform:uppercase;color:var(--muted);cursor:pointer; }
    th:hover { color:var(--text); }
    tbody tr { border-bottom:1px solid var(--border);transition:background .1s; } tbody tr:last-child { border-bottom:none; } tbody tr:hover { background:var(--bg); }
    td { padding:.55rem 1rem;vertical-align:middle; } td.col-name { width:100%; }
    td.col-size,td.col-date { white-space:nowrap;color:var(--muted); }
    td.col-name a { color:var(--accent);text-decoration:none;display:inline-flex;align-items:center;gap:.45rem; } td.col-name a:hover { text-decoration:underline; }
    tr.hidden { display:none; }
    .meta-grid { display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:1px;background:var(--border);border:1px solid var(--border);border-radius:6px;overflow:hidden;margin-bottom:2.5rem; }
    .meta-item { background:var(--surface);padding:1rem 1.25rem; }
    .meta-item .label { font-size:.7rem;letter-spacing:.06em;text-transform:uppercase;color:var(--muted);font-family:var(--mono);margin-bottom:.3rem; }
    .meta-item .value { font-size:.85rem;line-height:1.5; }
    .meta-item code { font-family:var(--mono);font-size:.78rem;background:var(--bg);border:1px solid var(--border);border-radius:3px;padding:.1rem .35rem; }
    footer { border-top:1px solid var(--border);padding-top:1.25rem;font-size:.78rem;color:var(--muted);display:flex;flex-wrap:wrap;justify-content:space-between;gap:.5rem; }
    footer a { color:var(--muted);text-decoration:none; } footer a:hover { color:var(--accent); }
    @media(max-width:580px){th.col-date,td.col-date{display:none;} #search{width:120px;}}
  </style>
</head>
<body>
<div class="topbar">
  <div class="topbar-inner">
    <div class="breadcrumb">
      <a href="/">${DOMAIN}</a><span class="sep">/</span>
      <a href="/pub/">pub</a><span class="sep">/</span>
      <a href="/pub/linux/">linux</a><span class="sep">/</span>
      <span>${slug}</span>
    </div>
    ${THEME_TOGGLE_BTN}
  </div>
</div>
<div class="main">
  <div class="page-head">
    <div>
      <h1>Index of <span class="path">/pub/linux/${slug}</span></h1>
      <p>${subhead}</p>
    </div>
    <div class="search-wrap">
      <span id="status-badge" class="status-badge" style="display:none"></span>
      <input id="search" type="search" placeholder="filter…" autocomplete="off" spellcheck="false">
    </div>
  </div>
  ${push_notice_html}
  <div class="file-table-wrap">
    <table id="listing">
      <thead><tr>
        <th class="col-name" onclick="sortTable(0)">Name ↕</th>
        <th class="col-date" onclick="sortTable(1)">Last Modified ↕</th>
        <th class="col-size" onclick="sortTable(2)">Size ↕</th>
      </tr></thead>
      <tbody>
        <tr><td class="col-name"><a href="/pub/linux/">↑ Parent Directory</a></td><td class="col-date"></td><td class="col-size">—</td></tr>
      </tbody>
    </table>
  </div>
  <div class="meta-grid">
    <div class="meta-item"><div class="label">Mirror</div><div class="value">${name}<br><span style="color:var(--muted);font-size:.8rem">${desc}</span></div></div>
    <div class="meta-item"><div class="label">Operator</div><div class="value">${LAB_NAME}<br>${LOCATION}</div></div>
    <div class="meta-item"><div class="label">Integrity</div><div class="value"><code>SHA256SUMS</code> in each directory.<br>Verify: <code>sha256sum -c SHA256SUMS</code></div></div>
    ${meta_upstream_html}
  </div>
  <footer>
    <span>${LAB_NAME}</span>
    <span id="gen-time"></span>
  </footer>
</div>
<script>
document.getElementById('gen-time').textContent='Generated '+new Date().toISOString().slice(0,16).replace('T',' ')+' UTC';
// Live status badge
fetch('/status.json').then(r=>r.json()).then(data=>{
  const m=(data.mirrors||{})['${slug}'];
  if(!m)return;
  const ago=Math.round((Date.now()/1000-m.last_sync)/3600);
  const badge=document.getElementById('status-badge');
  badge.style.display='';
  if(m.exit_code===0){badge.classList.add('ok');badge.textContent='✓ synced '+ago+'h ago';}
  else{badge.classList.add('err');badge.textContent='✗ last sync failed';}
}).catch(()=>{});
// Sync notice fallback
const syncNotice=document.getElementById('sync-notice');
if(syncNotice){fetch(window.location.href,{method:'HEAD'}).then(r=>{const lm=r.headers.get('Last-Modified');if(lm)syncNotice.textContent='Last modified: '+new Date(lm).toISOString().slice(0,16).replace('T',' ')+' UTC';}).catch(()=>{});}
// File listing
function fmtBytes(b){if(!b||isNaN(b))return'—';const u=['B','KiB','MiB','GiB'];let i=0,n=+b;while(n>=1024&&i<3){n/=1024;i++;}return n.toFixed(i?1:0)+'\u202f'+u[i];}
function fmtTime(t){if(!t)return'—';return new Date(t*1000).toISOString().slice(0,16).replace('T',' ');}
var rows=[];
function addRow(name,isDir,size,mtime){
  const ico=isDir?'📁':name.endsWith('.iso')?'💿':name==='SHA256SUMS'?'🔒':name.endsWith('.torrent')?'🌱':'📄';
  const href='/pub/linux/${slug}/'+name+(isDir?'/':'');
  const tr=document.createElement('tr');
  tr.dataset.name=name.toLowerCase(); tr.dataset.size=isDir?-1:(size||0); tr.dataset.mtime=mtime||0;
  tr.innerHTML='<td class="col-name"><a href="'+href+'">'+ico+' '+name+(isDir?'/':'')+'</a></td><td class="col-date">'+fmtTime(mtime)+'</td><td class="col-size">'+(isDir?'—':fmtBytes(size))+'</td>';
  document.querySelector('#listing tbody').appendChild(tr);
  rows.push(tr);
}
fetch('/pub/linux/${slug}/files.json').then(r=>r.json())
  .then(entries=>entries
    .filter(e=>e.name!=='index.html'&&e.name!=='files.json')
    .sort((a,b)=>(a.type==='directory')!==(b.type==='directory')?a.type==='directory'?-1:1:a.name.localeCompare(b.name))
    .forEach(e=>addRow(e.name,e.type==='directory',e.size,e.mtime))).catch(()=>{});
document.getElementById('search').addEventListener('input',function(){
  const q=this.value.toLowerCase().trim();
  rows.forEach(r=>{r.classList.toggle('hidden',!!q&&!r.dataset.name.includes(q));});
});
var sortDir={};
function sortTable(col){
  const keys=['name','mtime','size'];const k=keys[col];
  sortDir[k]=!sortDir[k];
  const tbody=document.querySelector('#listing tbody');
  rows.sort((a,b)=>{let av=a.dataset[k],bv=b.dataset[k];if(col>0){av=+av;bv=+bv;}return(av<bv?-1:av>bv?1:0)*(sortDir[k]?1:-1);});
  rows.forEach(r=>tbody.appendChild(r));
}
</script>
</body>
</html>
MIREOF
    ok "pub/linux/${slug}/index.html"
}

for slug in "${SELECTED_MIRRORS[@]}"; do
    entry="$(get_mirror_entry "$slug")"
    IFS='|' read -ra p <<< "$entry"
    generate_mirror_page "${p[0]}" "${p[1]}" "${p[2]}" "${p[3]}" "${p[4]}"
done
chown -R www-data:www-data "$PUB_DIR" "${WEBROOT}/index.html" 2>/dev/null || true

# =============================================================================
hdr "5. nginx config"
# =============================================================================

[[ -f /etc/nginx/sites-available/default ]] && \
    cp /etc/nginx/sites-available/default \
       "/etc/nginx/sites-available/default.bak.$(date +%s)" && \
    info "Backed up existing nginx config"

SSL_CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
SSL_KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
SSL_OPTS="/etc/letsencrypt/options-ssl-nginx.conf"

nginx_common="
    root ${WEBROOT};
    index index.html index.htm;
    include /etc/nginx/mime.types;

    # status.json — no cache so it's always fresh
    location = /status.json {
        add_header Cache-Control 'no-cache, no-store, must-revalidate';
        add_header Pragma no-cache;
        add_header Expires 0;
    }

    # Dynamic mirror locations — generated by ezmirror-sync
    include /etc/nginx/ezmirror-mirrors.conf;

    location /pub/ {
        alias ${PUB_DIR}/;
        index index.html;
        sendfile on; tcp_nopush on; tcp_nodelay on;
        autoindex on;
    }

    location / { try_files \$uri \$uri/ =404; }
"

if [[ -f "$SSL_CERT" && -f "$SSL_KEY" && -f "$SSL_OPTS" ]]; then
    cat > /etc/nginx/sites-available/default << NGINX
# ${LAB_NAME} — ${DOMAIN} — managed by ezmirror

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 301 https://${DOMAIN}\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl ipv6only=on;
    server_name ${DOMAIN} www.${DOMAIN};

    ssl_certificate     ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};
    include             ${SSL_OPTS};
    ssl_dhparam         /etc/letsencrypt/ssl-dhparams.pem;

    if (\$host = www.${DOMAIN}) {
        return 301 https://${DOMAIN}\$request_uri;
    }
${nginx_common}
}
NGINX
    ok "SSL nginx config written"
else
    cat > /etc/nginx/sites-available/default << NGINX
# ${LAB_NAME} — ${DOMAIN} — managed by ezmirror
# HTTP only. Enable HTTPS: sudo certbot --nginx -d ${DOMAIN} -d www.${DOMAIN}

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name ${DOMAIN} www.${DOMAIN} _;
${nginx_common}
}
NGINX
    warn "No SSL certs found — HTTP-only config written"
    warn "Run: sudo certbot --nginx -d ${DOMAIN} -d www.${DOMAIN}"
fi

# Create initial ezmirror-mirrors.conf (empty, will be populated by sync)
cat > /etc/nginx/ezmirror-mirrors.conf << 'MIRRORSEOF'
# ezmirror dynamic mirror locations
# Generated by ezmirror-sync — do not edit manually
MIRRORSEOF
chmod 644 /etc/nginx/ezmirror-mirrors.conf

if nginx -t 2>/dev/null; then
    systemctl reload nginx
    ok "nginx reloaded"
else
    warn "nginx config test failed — check /etc/nginx/sites-available/default"
    nginx -t
fi

# =============================================================================
hdr "6. rclone remotes"
# =============================================================================

for slug in "${SELECTED_MIRRORS[@]}"; do
    entry="$(get_mirror_entry "$slug")"
    IFS='|' read -ra p <<< "$entry"
    method="${p[4]}" upstream="${p[3]}"
    if [[ "$method" == "rclone-sftp" ]]; then
        remote_name="${upstream%%:*}"
        if rclone listremotes 2>/dev/null | grep -q "^${remote_name}:"; then
            ok "rclone remote '${remote_name}' already configured"
        elif [[ "$slug" == "nyarch" ]]; then
            rclone config create "${remote_name}" sftp \
                host "frs.sourceforge.net" user "anonymous" pass "" \
                set_modtime false no_check_updated true &>/dev/null
            ok "rclone remote '${remote_name}' created (NyarchLinux / SourceForge)"
        else
            warn "rclone-sftp remote '${remote_name}' for '${slug}' needs manual config:"
            warn "  sudo rclone config create ${remote_name} sftp host <host> user <user> ..."
        fi
    fi
done

# =============================================================================
hdr "7. rsyncd — push (original mirrors) + read-only pull (all mirrors)"
# =============================================================================

ORIGINAL_MIRRORS=()
MIRROR_TYPE_MIRRORS=()
for slug in "${SELECTED_MIRRORS[@]}"; do
    method="$(get_mirror_entry "$slug" | cut -d'|' -f5)"
    [[ "$method" == "original" ]] && ORIGINAL_MIRRORS+=("$slug")
    [[ "$method" == "mirror"   ]] && MIRROR_TYPE_MIRRORS+=("$slug")
done

# ── 7a. Credentials for mirror-type upstreams ────────────────────────────────
if [[ ${#MIRROR_TYPE_MIRRORS[@]} -gt 0 ]]; then
    for slug in "${MIRROR_TYPE_MIRRORS[@]}"; do
        secrets_file="${CONF_DIR}/${slug}.secrets"
        if [[ -n "${MIRROR_CREDS[$slug]:-}" ]]; then
            echo "${MIRROR_CREDS[$slug]}" > "$secrets_file"
            chmod 600 "$secrets_file"
            ok "${secrets_file}  (credentials saved, mode 600)"
        else
            echo "" > "$secrets_file"; chmod 600 "$secrets_file"
            ok "${secrets_file}  (anonymous)"
        fi
    done
fi

# ── 7b. rsyncd config (push for originals + read-only for all) ───────────────
RSYNCD_CONF="/etc/rsyncd.conf"

build_rsyncd_conf() {
    local push_user="${1:-mirrorpush}"
    {
        echo "# rsyncd.conf — ${LAB_NAME} — managed by ezmirror"
        echo "# Generated on $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo ""
        echo "uid             = www-data"
        echo "gid             = www-data"
        echo "use chroot      = yes"
        echo "max connections = 20"
        echo "log file        = /var/log/rsyncd.log"
        echo "pid file        = /var/run/rsyncd.pid"
        echo "lock file       = /var/run/rsyncd.lock"
        echo ""
        echo "# ── Read-only pull modules (public — anyone can mirror from us) ──"
        for slug in "${SELECTED_MIRRORS[@]}"; do
            entry="$(get_mirror_entry "$slug")"
            IFS='|' read -ra p <<< "$entry"
            cat << ROMOD

[${slug}]
    path        = ${LINUX_DIR}/${slug}
    comment     = ${p[1]} — ${p[2]}
    read only   = yes
    list        = yes
    # Restrict by IP for production: hosts allow = 1.2.3.4
ROMOD
        done

        if [[ ${#ORIGINAL_MIRRORS[@]} -gt 0 ]]; then
            echo ""
            echo "# ── Write modules for original mirrors (push access) ──"
            for slug in "${ORIGINAL_MIRRORS[@]}"; do
                entry="$(get_mirror_entry "$slug")"
                IFS='|' read -ra p <<< "$entry"
                cat << RWMOD

[${slug}-push]
    path         = ${LINUX_DIR}/${slug}
    comment      = ${p[1]} — push endpoint
    read only    = no
    write only   = no
    list         = yes
    auth users   = ${push_user}
    secrets file = /etc/rsyncd.secrets
    # Restrict to trusted IPs in production:
    # hosts allow = 1.2.3.4
    hosts deny   = *
    hosts allow  = *
RWMOD
            done
        fi
    } > "$RSYNCD_CONF"
}

if [[ ${#ORIGINAL_MIRRORS[@]} -eq 0 ]]; then
    build_rsyncd_conf "mirrorpush"
    ok "rsyncd.conf  (read-only pull modules for all mirrors)"
else
    echo ""
    echo -e "  Original mirrors detected: ${B}${ORIGINAL_MIRRORS[*]}${N}"
    echo ""
    if [[ "$UNATTENDED" != true ]]; then
        read -rp "  Set up rsyncd push daemon for original mirrors? [Y/n] " _rsyncd
    else
        _rsyncd="y"
    fi

    if [[ "${_rsyncd,,}" != "n" ]]; then
        ask "rsync push username" PUSH_USER "mirrorpush"
        read -rsp "  rsync push password:              " PUSH_PASS; echo ""

        if ! id "$PUSH_USER" &>/dev/null; then
            useradd --system --no-create-home --shell /usr/sbin/nologin "$PUSH_USER"
            ok "System user '${PUSH_USER}' created"
        else
            ok "System user '${PUSH_USER}' already exists"
        fi

        build_rsyncd_conf "$PUSH_USER"
        echo "${PUSH_USER}:${PUSH_PASS}" > /etc/rsyncd.secrets
        chmod 600 /etc/rsyncd.secrets
        ok "/etc/rsyncd.secrets (mode 600)"
        ok "$RSYNCD_CONF"

        systemctl enable rsync && systemctl restart rsync
        ok "rsyncd enabled and started"

        echo ""
        info "Push to an original mirror from a client:"
        for slug in "${ORIGINAL_MIRRORS[@]}"; do
            echo -e "    rsync -avz --progress /your/files/ ${PUSH_USER}@${DOMAIN}::${slug}-push/"
        done
        echo ""
        warn "Restrict 'hosts allow' in ${RSYNCD_CONF} to trusted IPs before going public."
    else
        build_rsyncd_conf "mirrorpush"
        ok "rsyncd.conf  (read-only pull modules only)"
    fi
fi

systemctl enable rsync 2>/dev/null || true
systemctl restart rsync 2>/dev/null && ok "rsyncd started" || warn "rsyncd start failed — check 'systemctl status rsync'"

info "Downstream mirrors can pull from this server:"
for slug in "${SELECTED_MIRRORS[@]}"; do
    echo -e "    rsync -avz rsync://${DOMAIN}/${slug}/ /your/local/${slug}/"
done

# =============================================================================
hdr "8. Logrotate"
# =============================================================================

cat > /etc/logrotate.d/ezmirror << LOGEOF
/var/log/ezmirror.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    dateext
    dateformat -%Y%m%d
}

/var/log/rsyncd.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    copytruncate
}
LOGEOF
ok "/etc/logrotate.d/ezmirror"

# =============================================================================
hdr "9. ezmirror-sync (with automatic index.html generation)"
# =============================================================================

cat > "$SYNC_BIN" << 'SYNCEOF'
#!/usr/bin/env bash
# ezmirror-sync — sync all (or one) configured mirrors
# Automatically generates index.html for all directories and dynamic nginx config
# Usage:
#   ezmirror-sync                     sync all due mirrors
#   ezmirror-sync --dry-run           simulate without writing
#   ezmirror-sync --mirror=arch       sync one mirror (ignores interval)
#   ezmirror-sync --force             sync all, ignoring intervals
set -euo pipefail

CONF_DIR="/etc/ezmirror"
CONF="${CONF_DIR}/mirrors.conf"
PATHS_CONF="${CONF_DIR}/paths.conf"
LAB_CONF="${CONF_DIR}/lab.conf"
ALERT_CONF="${CONF_DIR}/alert.conf"
LOGFILE="/var/log/ezmirror.log"
LOCKFILE="/var/run/ezmirror-sync.lock"
DRY_RUN=false
ONLY_SLUG=""
FORCE=false

[[ -f "$PATHS_CONF" ]] && source "$PATHS_CONF" || { WEBROOT="/var/www/html"; PUB_DIR="${WEBROOT}/pub"; LINUX_DIR="${WEBROOT}/pub/linux"; ENABLE_TORRENTS="false"; }
[[ -f "$LAB_CONF"   ]] && source "$LAB_CONF"   || { LAB_NAME="ezmirror"; DOMAIN="localhost"; LOCATION="Unknown"; }
[[ -f "$ALERT_CONF" ]] && source "$ALERT_CONF" || { ALERT_WEBHOOK=""; ALERT_EMAIL=""; }

for arg in "${@:-}"; do
    case "$arg" in
        --dry-run)   DRY_RUN=true ;;
        --force)     FORCE=true   ;;
        --mirror=*)  ONLY_SLUG="${arg#--mirror=}" ;;
    esac
done

log()  { local l="$1"; shift; echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$l] $*" | tee -a "$LOGFILE"; }
logq() { local l="$1"; shift; echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$l] $*" >> "$LOGFILE"; }

# ── Lock file — prevent overlapping syncs ─────────────────────────────────────
exec 200>"$LOCKFILE"
if ! flock -n 200; then
    log WARN "Another ezmirror-sync is already running (lock: ${LOCKFILE}). Exiting."
    exit 0
fi
trap 'flock -u 200; rm -f "$LOCKFILE"' EXIT INT TERM

# ── Alerting ──────────────────────────────────────────────────────────────────
send_alert() {
    local slug="$1" message="$2"
    local title="ezmirror sync failure: ${slug} on ${DOMAIN}"
    if [[ -n "${ALERT_WEBHOOK:-}" ]]; then
        curl -s -X POST "$ALERT_WEBHOOK" \
            -H 'Content-Type: application/json' \
            -d "{\"embeds\":[{\"title\":\"${title}\",\"description\":\"${message}\",\"color\":15158332}]}" \
            >> "$LOGFILE" 2>&1 || true
    fi
    if [[ -n "${ALERT_EMAIL:-}" ]]; then
        echo -e "Subject: ${title}\n\n${message}" | \
            mail -s "$title" "$ALERT_EMAIL" 2>/dev/null || true
    fi
}

# ── Generate index.html for a directory ────────────────────────────────────────
# FIX: breadcrumbs built root-to-leaf by collecting segments then reversing
generate_dir_index() {
    local dir="$1" base_href="$2" title_path="$3"
    [[ ! -d "$dir" ]] && return

    # Collect path segments in reverse order, then flip
    local crumb_parts=()
    local current_path="${base_href%/}"
    while [[ "$current_path" != "/" && "$current_path" != "." && -n "$current_path" ]]; do
        crumb_parts+=("${current_path}|$(basename "$current_path")")
        current_path=$(dirname "$current_path")
    done

    # Reverse into root-first order
    local n=${#crumb_parts[@]}
    local reversed=()
    for (( ci=n-1; ci>=0; ci-- )); do
        reversed+=("${crumb_parts[$ci]}")
    done

    # Build breadcrumb HTML: intermediate segments are links, last is a plain span
    local breadcrumbs="<a href=\"/\">${DOMAIN}</a>"
    local total=${#reversed[@]}
    for (( ci=0; ci<total; ci++ )); do
        local cpath="${reversed[$ci]%%|*}"
        local cname="${reversed[$ci]##*|}"
        if (( ci < total - 1 )); then
            breadcrumbs+="<span class=\"sep\">/</span><a href=\"${cpath}/\">${cname}</a>"
        else
            breadcrumbs+="<span class=\"sep\">/</span><span>${cname}</span>"
        fi
    done

    local parent_href; parent_href="$(dirname "${base_href%/}")/"
    [[ "$parent_href" == "//" ]] && parent_href="/"

    cat > "${dir}/index.html" << DIREOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Index of ${title_path} — ${LAB_NAME}</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500&family=IBM+Plex+Sans:wght@300;400;500;600&display=swap" rel="stylesheet">
  <script>
    (function(){
      var t=localStorage.getItem("em-theme")||"auto";
      if(t==="dark")document.documentElement.setAttribute("data-theme","dark");
      else if(t==="light")document.documentElement.setAttribute("data-theme","light");
    })();
  </script>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    :root { --bg:#f8f8f6;--surface:#fff;--border:#e2e2dc;--text:#1a1a18;--muted:#6b6b63;--accent:#2563a8;--mono:'IBM Plex Mono',monospace;--sans:'IBM Plex Sans',sans-serif; }
    [data-theme="dark"] { --bg:#0f0f0f;--surface:#161616;--border:#262626;--text:#e8e8e8;--muted:#737373;--accent:#4ea3e0; }
    @media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) { --bg:#0f0f0f;--surface:#161616;--border:#262626;--text:#e8e8e8;--muted:#737373;--accent:#4ea3e0; } }
    html { font-size: 15px; } body { background:var(--bg);color:var(--text);font-family:var(--sans);line-height:1.5;transition:background .2s,color .2s; }
    .topbar { background:var(--surface);border-bottom:1px solid var(--border);padding:.6rem 0; }
    .topbar-inner { max-width:960px;margin:0 auto;padding:0 2rem;display:flex;gap:1rem;align-items:center;justify-content:space-between;font-size:.8rem;color:var(--muted);font-family:var(--mono); }
    .topbar-inner a { color:var(--accent);text-decoration:none; } .topbar-inner a:hover { text-decoration:underline; }
    .breadcrumb { display:flex;gap:1rem;align-items:center; }
    .sep { color:var(--border); }
    .main { max-width:960px;margin:0 auto;padding:2.5rem 2rem 5rem; }
    .page-head { margin-bottom:1.5rem;padding-bottom:1.25rem;border-bottom:1px solid var(--border);display:flex;justify-content:space-between;align-items:flex-end;flex-wrap:wrap;gap:1rem; }
    .page-head h1 { font-family:var(--mono);font-size:1.05rem;font-weight:500;margin-bottom:.35rem; }
    .page-head h1 .path { color:var(--accent); } .page-head p { font-size:.83rem;color:var(--muted); }
    .search-wrap { display:flex;gap:.5rem;align-items:center; }
    #search { background:var(--surface);border:1px solid var(--border);color:var(--text);font-family:var(--mono);font-size:.8rem;padding:.35rem .7rem;border-radius:4px;outline:none;width:180px;transition:border-color .15s; }
    #search:focus { border-color:var(--accent); }
    .file-table-wrap { background:var(--surface);border:1px solid var(--border);border-radius:6px;overflow:hidden;margin-bottom:2.5rem; }
    table { width:100%;border-collapse:collapse;font-family:var(--mono);font-size:.82rem; }
    thead tr { background:var(--bg);border-bottom:1px solid var(--border); }
    th { text-align:left;padding:.55rem 1rem;font-size:.72rem;font-weight:500;letter-spacing:.04em;text-transform:uppercase;color:var(--muted);cursor:pointer;user-select:none; }
    th:hover { color:var(--text); }
    tbody tr { border-bottom:1px solid var(--border);transition:background .1s; } tbody tr:last-child { border-bottom:none; } tbody tr:hover { background:var(--bg); }
    td { padding:.55rem 1rem;vertical-align:middle; } td.col-name { width:100%; }
    td.col-size,td.col-date { white-space:nowrap;color:var(--muted); }
    td.col-name a { color:var(--accent);text-decoration:none;display:inline-flex;align-items:center;gap:.45rem; } td.col-name a:hover { text-decoration:underline; }
    tr.hidden { display:none; }
    footer { border-top:1px solid var(--border);padding-top:1.25rem;font-size:.78rem;color:var(--muted);display:flex;flex-wrap:wrap;justify-content:space-between;gap:.5rem; }
    footer a { color:var(--muted);text-decoration:none; } footer a:hover { color:var(--accent); }
    @media(max-width:580px){th.col-date,td.col-date{display:none;} #search{width:120px;}}
  </style>
</head>
<body>
<div class="topbar"><div class="topbar-inner">
  <div class="breadcrumb">${breadcrumbs}</div>
  <button onclick="(function(){var h=document.documentElement,c=h.getAttribute('data-theme')||'auto',n=c==='dark'?'light':'dark';h.setAttribute('data-theme',n);localStorage.setItem('em-theme',n);})();" title="Toggle dark/light mode" style="background:none;border:1px solid var(--border);color:var(--muted);padding:.3rem .6rem;border-radius:4px;cursor:pointer;font-family:var(--mono);font-size:.72rem;">◐</button>
</div></div>
<div class="main">
  <div class="page-head">
    <div>
      <h1>Index of <span class="path">${title_path}</span></h1>
      <p>${LAB_NAME} — ${LOCATION}</p>
    </div>
    <div class="search-wrap">
      <input id="search" type="search" placeholder="filter…" autocomplete="off" spellcheck="false">
    </div>
  </div>
  <div class="file-table-wrap">
    <table id="listing">
      <thead><tr>
        <th class="col-name" onclick="sortTable(0)">Name ↕</th>
        <th class="col-date" onclick="sortTable(1)">Last Modified ↕</th>
        <th class="col-size" onclick="sortTable(2)">Size ↕</th>
      </tr></thead>
      <tbody>
        <tr><td class="col-name"><a href="${parent_href}">↑ Parent Directory</a></td><td class="col-date"></td><td class="col-size">—</td></tr>
      </tbody>
    </table>
  </div>
  <footer><span>${LAB_NAME}</span><span><a href="/">← Home</a></span></footer>
</div>
<script>
function fmtBytes(b){if(!b||isNaN(b))return'—';const u=['B','KiB','MiB','GiB'];let i=0,n=+b;while(n>=1024&&i<3){n/=1024;i++;}return n.toFixed(i?1:0)+'\u202f'+u[i];}
function fmtTime(t){if(!t)return'—';return new Date(t*1000).toISOString().slice(0,16).replace('T',' ');}
var rows=[];
function addRow(name,isDir,size,mtime){
  const ico=isDir?'📁':name.endsWith('.iso')?'💿':name==='SHA256SUMS'?'🔒':name.endsWith('.torrent')?'🌱':'📄';
  const href='${base_href}'+name+(isDir?'/':'');
  const tr=document.createElement('tr');
  tr.dataset.name=name.toLowerCase(); tr.dataset.size=isDir?-1:(size||0); tr.dataset.mtime=mtime||0;
  tr.innerHTML='<td class="col-name"><a href="'+href+'">'+ico+' '+name+(isDir?'/':'')+'</a></td><td class="col-date">'+fmtTime(mtime)+'</td><td class="col-size">'+(isDir?'—':fmtBytes(size))+'</td>';
  document.querySelector('#listing tbody').appendChild(tr);
  rows.push(tr);
}
fetch('${base_href}files.json').then(r=>r.json())
  .then(es=>es.filter(e=>e.name!=='index.html'&&e.name!=='files.json')
    .sort((a,b)=>(a.type==='directory')!==(b.type==='directory')?a.type==='directory'?-1:1:a.name.localeCompare(b.name))
    .forEach(e=>addRow(e.name,e.type==='directory',e.size,e.mtime))).catch(()=>{});
document.getElementById('search').addEventListener('input',function(){
  const q=this.value.toLowerCase().trim();
  rows.forEach(r=>{r.classList.toggle('hidden',!!q&&!r.dataset.name.includes(q));});
});
var sortDir={};
function sortTable(col){
  const keys=['name','mtime','size'];const k=keys[col];
  sortDir[k]=!sortDir[k];
  const tbody=document.querySelector('#listing tbody');
  const parent=tbody.firstElementChild;
  rows.sort((a,b)=>{
    let av=a.dataset[k],bv=b.dataset[k];
    if(col>0){av=+av;bv=+bv;}
    return(av<bv?-1:av>bv?1:0)*(sortDir[k]?1:-1);
  });
  rows.forEach(r=>tbody.appendChild(r));
}
</script>
</body>
</html>
DIREOF
}

# ── Generate dynamic nginx mirror config ─────────────────────────────────────
# FIX: reads mirrors.conf directly instead of using undefined ${SELECTED_MIRRORS[@]}
generate_nginx_mirrors_conf() {
    {
        echo "# ezmirror dynamic mirror locations"
        echo "# Generated by ezmirror-sync on $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "# Do not edit manually — regenerated on every sync"
        echo ""
        while IFS='|' read -r slug _rest; do
            [[ -z "${slug:-}" || "${slug:0:1}" == "#" ]] && continue
            echo "location /pub/linux/${slug}/ {"
            echo "    alias ${LINUX_DIR}/${slug}/;"
            echo "    index index.html;"
            echo "    sendfile on; tcp_nopush on; tcp_nodelay on;"
            echo "    autoindex on;"
            echo "}"
            echo ""
        done < "$CONF"
    } > /etc/nginx/ezmirror-mirrors.conf
}

# Interval check ────────────────────────────────────────────────────────
interval_to_seconds() {
    local s="$1"
    local num="${s%[hHmMdD]}" unit="${s: -1}"
    case "${unit,,}" in
        h) echo $(( num * 3600 ))  ;;
        m) echo $(( num * 60 ))    ;;
        d) echo $(( num * 86400 )) ;;
        *) echo $(( num * 3600 ))  ;; # default: treat as hours
    esac
}

is_sync_due() {
    local slug="$1" interval_str="$2"
    [[ "$FORCE" == true || -n "$ONLY_SLUG" ]] && return 0
    local status_file="${WEBROOT}/status.json"
    [[ ! -f "$status_file" ]] && return 0
    local last_sync
    last_sync=$(jq -r --arg s "$slug" '.mirrors[$s].last_sync // 0' "$status_file" 2>/dev/null || echo 0)
    local interval_secs; interval_secs=$(interval_to_seconds "${interval_str:-6h}")
    local now; now=$(date +%s)
    (( now - last_sync >= interval_secs ))
}

# ── Disk space check ─────────────────────────────────────────────────────
check_disk_space() {
    local dir="$1"
    local avail_gib
    avail_gib=$(df -BG --output=avail "$dir" 2>/dev/null | tail -1 | tr -d 'G ' || echo 0)
    if (( avail_gib < 10 )); then
        log WARN "Low disk space: only ${avail_gib} GiB available on volume containing ${dir}"
        send_alert "disk" "Low disk space: ${avail_gib} GiB remaining on ${dir}"
    fi
}

# ── JSON helpers using jq ─────────────────────────────────────────────────────
build_files_json() {
    local dir="$1"
    local entries=()
    for f in "$dir"/*; do
        [[ -e "$f" ]] || continue
        local fname; fname=$(basename "$f")
        [[ "$fname" == "index.html" || "$fname" == "files.json" ]] && continue
        local ftype fsize fmtime
        ftype=$(  [[ -d "$f" ]] && echo "directory" || echo "file")
        fsize=$(  [[ -f "$f" ]] && stat -c%s "$f" || echo "null")
        fmtime=$( stat -c%Y "$f")
        entries+=("$(jq -n --arg n "$fname" --arg t "$ftype" --argjson s "${fsize}" --argjson m "${fmtime}" \
            '{name:$n,type:$t,size:$s,mtime:$m}')")
    done
    printf '['; local first=true
    for e in "${entries[@]:-}"; do
        [[ "$first" == false ]] && printf ','
        printf '%s' "$e"; first=false
    done
    printf ']'
}

update_status_json() {
    local slug="$1" exit_code="$2"
    local bw_limit="${3:-0}" upstream_health="${4:-ok}" upstream_check_time="${5:-0}" upstream_response_ms="${6:-0}"
    local retention_days="${7:-0}" retention_max_gib="${8:-0}"
    local status_file="${WEBROOT}/status.json"
    local now; now=$(date +%s)
    local disk_bytes=0
    [[ -d "${LINUX_DIR}/${slug}" ]] && disk_bytes=$(du -sb "${LINUX_DIR}/${slug}" 2>/dev/null | awk '{print $1}' || echo 0)
    local status_str; [[ "$exit_code" -eq 0 ]] && status_str="ok" || status_str="error"

    local current='{}'
    [[ -f "$status_file" ]] && current=$(cat "$status_file")
    echo "$current" | jq \
        --argjson now "$now" \
        --arg slug "$slug" \
        --argjson ec "$exit_code" \
        --argjson db "$disk_bytes" \
        --arg st "$status_str" \
        --argjson bwl "$bw_limit" \
        --arg uh "$upstream_health" \
        --argjson uct "$upstream_check_time" \
        --argjson urt "$upstream_response_ms" \
        --argjson rd "$retention_days" \
        --argjson rmg "$retention_max_gib" \
        '.generated=$now | .mirrors[$slug]={
            "last_sync":$now,"exit_code":$ec,"disk_bytes":$db,"status":$st,
            "bandwidth_limit_mbps":$bwl,
            "upstream_health":$uh,"upstream_health_checked":$uct,"upstream_response_time_ms":$urt,
            "retention_days":$rd,"retention_max_gib":$rmg
        }' \
        > "${status_file}.tmp" && mv "${status_file}.tmp" "$status_file"
    chown www-data:www-data "$status_file" 2>/dev/null || true
}

update_mirrors_json() {
    local mirror_json_entries=("$@")
    {
        printf '['
        local first=true
        for entry in "${mirror_json_entries[@]:-}"; do
            [[ "$first" == false ]] && printf ','
            printf '%s' "$entry"; first=false
        done
        printf ']'
    } > "${WEBROOT}/mirrors.json"
    chown www-data:www-data "${WEBROOT}/mirrors.json" 2>/dev/null || true
    log INFO "[JSON] mirrors.json (${#mirror_json_entries[@]} mirror(s))"
}

seed_torrents() {
    local slug="$1" local_dir="$2"
    [[ "${ENABLE_TORRENTS:-false}" != "true" ]] && return
    command -v mktorrent &>/dev/null || return
    find "$local_dir" -maxdepth 3 -name "*.iso" | while read -r iso; do
        local torrent="${iso%.iso}.torrent"
        [[ -f "$torrent" ]] && continue
        logq INFO "  [TORRENT] creating ${torrent##*/}"
        mktorrent -l 22 -a "udp://open.tracker.cl:1337/announce" \
            -a "udp://tracker.opentrackr.org:1337/announce" \
            -o "$torrent" "$iso" >> "$LOGFILE" 2>&1 || \
            logq WARN "  mktorrent failed for ${iso}"
    done
}

[[ -f "$CONF" ]] || { log ERROR "No mirrors.conf at $CONF — run setup.sh first."; exit 1; }

log INFO "=== ezmirror-sync started${DRY_RUN:+ [DRY RUN]}${FORCE:+ [FORCE]} ==="
check_disk_space "${LINUX_DIR}"

declare -a mirror_json_entries=()
declare -A sync_exit_codes=()

while IFS='|' read -r slug name desc upstream method _size _warn interval bw_limit retention_days retention_max_gib || [[ -n "${slug:-}" ]]; do
    [[ -z "${slug:-}" || "${slug:0:1}" == "#" ]] && continue
    [[ -n "$ONLY_SLUG" && "$slug" != "$ONLY_SLUG" ]] && continue
    interval="${interval:-6h}"
    bw_limit="${bw_limit:-0}"
    retention_days="${retention_days:-0}"
    retention_max_gib="${retention_max_gib:-0}"

    if ! is_sync_due "$slug" "$interval"; then
        log INFO "--- ${slug}: skipping (synced within ${interval}) ---"
        mirror_json_entries+=("$(jq -n --arg sl "$slug" --arg n "$name" --arg d "$desc" --arg m "$method" \
            '{slug:$sl,name:$n,desc:$d,path:("/pub/linux/"+$sl+"/"),method:$m}')")
        sync_exit_codes["$slug"]=0
        continue
    fi

    # ── Upstream health check ─────────────────────────────────────────────────
    upstream_health="ok"
    upstream_check_time=$(date +%s)
    upstream_response_ms=0
    if [[ "$method" != "original" ]]; then
        _t0=$(date +%s%3N)
        case "$method" in
            rsync|mirror)
                timeout 10 rsync --list-only "$upstream" > /dev/null 2>&1 || upstream_health="fail" ;;
            rclone-sftp)
                remote_name="${upstream%%:*}"
                timeout 10 rclone lsd "${remote_name}:" > /dev/null 2>&1 || upstream_health="fail" ;;
            rclone-http)
                timeout 10 curl -sI "$upstream" > /dev/null 2>&1 || upstream_health="fail" ;;
        esac
        upstream_response_ms=$(( $(date +%s%3N) - _t0 ))
        if [[ "$upstream_health" == "fail" ]]; then
            log WARN "--- ${slug}: upstream unreachable — skipping sync ---"
            send_alert "$slug" "Upstream is unreachable for '${slug}'. Sync skipped."
            update_status_json "$slug" "1" "$bw_limit" "$upstream_health" "$upstream_check_time" "$upstream_response_ms" "$retention_days" "$retention_max_gib"
            sync_exit_codes["$slug"]=1
            mirror_json_entries+=("$(jq -n --arg sl "$slug" --arg n "$name" --arg d "$desc" --arg m "$method" \
                '{slug:$sl,name:$n,desc:$d,path:("/pub/linux/"+$sl+"/"),method:$m}')")
            continue
        fi
    fi

    local_dir="${LINUX_DIR}/${slug}"
    mkdir -p "$local_dir"
    sync_exit=0

    case "$method" in
        original)
            log INFO "--- ${slug}: original mirror — skipping upstream sync ---"
            ;;

        rsync)
            log INFO "--- ${slug}: syncing via rsync (interval: ${interval}${bw_limit:+, bwlimit=${bw_limit}Mbps}) ---"
            flags=(-rlptv --delete --safe-links --hard-links
                   --timeout=300 --contimeout=60
                   --exclude="*.part" --exclude="*.tmp")
            [[ "$DRY_RUN" == true ]] && flags+=(--dry-run)
            (( bw_limit > 0 )) && flags+=(--bwlimit="${bw_limit}m")
            rsync "${flags[@]}" "${upstream}" "${local_dir}/" 2>&1 | tee -a "$LOGFILE" || {
                sync_exit=$?
                log WARN "rsync for ${slug} exited ${sync_exit} (partial sync?)"
                send_alert "$slug" "rsync exited with code ${sync_exit} for mirror '${slug}'. Check ${LOGFILE} for details."
            }
            ;;

        mirror)
            log INFO "--- ${slug}: syncing from self-hosted mirror (interval: ${interval}${bw_limit:+, bwlimit=${bw_limit}Mbps}) ---"
            flags=(-rlptv --delete --safe-links --hard-links
                   --timeout=300 --contimeout=60
                   --exclude="*.part" --exclude="*.tmp")
            [[ "$DRY_RUN" == true ]] && flags+=(--dry-run)
            (( bw_limit > 0 )) && flags+=(--bwlimit="${bw_limit}m")
            secrets_file="/etc/ezmirror/${slug}.secrets"
            if [[ -s "$secrets_file" ]]; then
                creds_user="$(cut -d: -f1 < "$secrets_file")"
                creds_pass="$(cut -d: -f2- < "$secrets_file")"
                RSYNC_PASSWORD="$creds_pass" rsync "${flags[@]}" --user="${creds_user}" \
                    "${upstream}" "${local_dir}/" 2>&1 | tee -a "$LOGFILE" || {
                    sync_exit=$?
                    log WARN "rsync (mirror) for ${slug} exited ${sync_exit}"
                    send_alert "$slug" "Mirror sync failed for '${slug}' (exit ${sync_exit})."
                }
            else
                rsync "${flags[@]}" "${upstream}" "${local_dir}/" 2>&1 | tee -a "$LOGFILE" || {
                    sync_exit=$?
                    log WARN "rsync (mirror, anon) for ${slug} exited ${sync_exit}"
                    send_alert "$slug" "Mirror sync (anon) failed for '${slug}' (exit ${sync_exit})."
                }
            fi
            ;;

        rclone-sftp)
            log INFO "--- ${slug}: syncing via rclone sftp (interval: ${interval}) ---"
            remote_name="${upstream%%:*}"; remote_path="${upstream#*:}"
            flags=(--transfers 4 --checkers 8 --retries 3 --low-level-retries 5
                   --sftp-concurrency 8 --stats 60s
                   --log-file "$LOGFILE" --log-level INFO --exclude "*.part")
            [[ "$DRY_RUN" == true ]] && flags+=(--dry-run)
            rclone sync "${remote_name}:${remote_path}" "${local_dir}/" "${flags[@]}" || {
                sync_exit=$?
                log WARN "rclone sftp for ${slug} exited ${sync_exit}"
                send_alert "$slug" "rclone sftp sync failed for '${slug}' (exit ${sync_exit})."
            }
            ;;

        rclone-http)
            log INFO "--- ${slug}: syncing via rclone http (interval: ${interval}) ---"
            flags=(--transfers 4 --checkers 8 --retries 3
                   --log-file "$LOGFILE" --log-level INFO --exclude "*.part")
            [[ "$DRY_RUN" == true ]] && flags+=(--dry-run)
            rclone sync ":http:" "${local_dir}/" --http-url "${upstream}" "${flags[@]}" || {
                sync_exit=$?
                log WARN "rclone http for ${slug} exited ${sync_exit}"
                send_alert "$slug" "rclone http sync failed for '${slug}' (exit ${sync_exit})."
            }
            ;;

        *)
            log WARN "Unknown method '${method}' for ${slug} — skipping"
            continue
            ;;
    esac

    sync_exit_codes["$slug"]=$sync_exit

    if [[ "$DRY_RUN" == true ]]; then
        log INFO "  [DRY RUN] skipping SHA256SUMS, files.json, torrent steps for ${slug}"
        mirror_json_entries+=("$(jq -n --arg sl "$slug" --arg n "$name" --arg d "$desc" --arg m "$method" \
            '{slug:$sl,name:$n,desc:$d,path:("/pub/linux/"+$sl+"/"),method:$m}')")
        continue
    fi

    # SHA256SUMS
    find "$local_dir" -mindepth 0 -maxdepth 3 -type d | while read -r dir; do
        mapfile -t regular < <(find "$dir" -maxdepth 1 -type f \
            ! -name "*.html" ! -name "SHA256SUMS" ! -name "files.json" ! -name "*.torrent" 2>/dev/null)
        [[ ${#regular[@]} -eq 0 ]] && continue
        (cd "$dir" && sha256sum -- "${regular[@]##*/}" 2>/dev/null \
            | grep -v "SHA256SUMS\|index\.html\|files\.json" > SHA256SUMS || true)
    done
    log INFO "  [SHA256] ${slug}"

    # files.json
    build_files_json "$local_dir" > "${local_dir}/files.json"
    log INFO "  [JSON]   ${slug}/files.json"

    # index.html for mirror root
    generate_dir_index "$local_dir" "/pub/linux/${slug}/" "/pub/linux/${slug}"
    log INFO "  [INDEX]  ${slug}/index.html"

    # index.html for all subdirectories
    # FIX: removed invalid 'local' declarations outside functions
    find "$local_dir" -mindepth 1 -type d | while read -r subdir; do
        build_files_json "$subdir" > "${subdir}/files.json"
        rel_path="${subdir#${LINUX_DIR}/}"
        href="/pub/linux/${rel_path}/"
        title="/pub/linux/${rel_path}"
        generate_dir_index "$subdir" "$href" "$title"
    done
    log INFO "  [INDEX]  ${slug}/* (all subdirectories)"

    # Torrent seeding
    seed_torrents "$slug" "$local_dir"

    # Retention / cleanup — runs after successful sync only
    # FIX: removed invalid 'local' declarations outside functions
    if [[ "$sync_exit" -eq 0 && "$DRY_RUN" != true ]]; then
        if (( retention_days > 0 || retention_max_gib > 0 )); then
            log INFO "  [CLEANUP] ${slug} (retention: ${retention_days}d / ${retention_max_gib}GiB)"
            if (( retention_days > 0 )); then
                find "$local_dir" -type f -mtime "+${retention_days}" -delete 2>/dev/null || true
                log INFO "  [CLEANUP] deleted files older than ${retention_days} days"
            fi
            if (( retention_max_gib > 0 )); then
                max_bytes=$(( retention_max_gib * 1073741824 ))
                cur_bytes=$(du -sb "$local_dir" 2>/dev/null | awk '{print $1}' || echo 0)
                if (( cur_bytes > max_bytes )); then
                    log WARN "  [CLEANUP] size limit exceeded ($(( cur_bytes / 1073741824 ))GiB > ${retention_max_gib}GiB), pruning oldest files"
                    find "$local_dir" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | cut -d' ' -f2- | \
                    while read -r _file; do
                        cur_bytes=$(du -sb "$local_dir" 2>/dev/null | awk '{print $1}' || echo 0)
                        (( cur_bytes <= max_bytes )) && break
                        rm -f "$_file"
                    done
                fi
            fi
        fi
    fi

    # Update per-mirror status
    update_status_json "$slug" "$sync_exit" "$bw_limit" "${upstream_health:-ok}" "${upstream_check_time:-0}" "${upstream_response_ms:-0}" "$retention_days" "$retention_max_gib"

    mirror_json_entries+=("$(jq -n --arg sl "$slug" --arg n "$name" --arg d "$desc" --arg m "$method" \
        '{slug:$sl,name:$n,desc:$d,path:("/pub/linux/"+$sl+"/"),method:$m}')")

done < "$CONF"

[[ "$DRY_RUN" == true ]] && { log INFO "=== Dry run complete ==="; exit 0; }

# Top-level files.json for pub/ and pub/linux/
for dir in "$PUB_DIR" "$LINUX_DIR"; do
    [[ -d "$dir" ]] || continue
    build_files_json "$dir" > "${dir}/files.json"
    log INFO "[JSON] ${dir}/files.json"
done

update_mirrors_json "${mirror_json_entries[@]:-}"

# Generate dynamic nginx config and reload
generate_nginx_mirrors_conf
nginx -t 2>/dev/null && systemctl reload nginx || logq WARN "nginx config reload failed"
log INFO "[NGINX] ezmirror-mirrors.conf regenerated"

chown -R www-data:www-data "$PUB_DIR" "${WEBROOT}/mirrors.json" "${WEBROOT}/status.json" 2>/dev/null || true
chmod -R 755 "$PUB_DIR"

# Final exit code: non-zero if any mirror failed
overall_exit=0
for slug in "${!sync_exit_codes[@]}"; do
    [[ "${sync_exit_codes[$slug]}" -ne 0 ]] && overall_exit=1
done
log INFO "=== ezmirror-sync complete (exit: ${overall_exit}) ==="
exit $overall_exit
SYNCEOF

chmod +x "$SYNC_BIN"
ok "$SYNC_BIN"

# =============================================================================
hdr "10. ezmirror-manage"
# =============================================================================

cat > "$MANAGE_BIN" << 'MEOF'
#!/usr/bin/env bash
# ezmirror-manage — add, remove, or reconfigure mirrors without re-running setup
# Usage: sudo ezmirror-manage
set -euo pipefail

R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' B='\033[1m' N='\033[0m'
ok()   { echo -e "  ${G}✓${N}  $*"; }
info() { echo -e "  ${C}→${N}  $*"; }
warn() { echo -e "  ${Y}!${N}  $*"; }
die()  { echo -e "  ${R}✗${N}  $*" >&2; exit 1; }
hdr()  { echo -e "\n${B}── $* ──${N}"; }
rule() { printf '  %s\n' "$(printf '─%.0s' {1..66})"; }

[[ $EUID -eq 0 ]] || die "Run with sudo: sudo ezmirror-manage"

CONF_DIR="/etc/ezmirror"
LAB_CONF="${CONF_DIR}/lab.conf"
PATHS_CONF="${CONF_DIR}/paths.conf"
MIRRORS_CONF="${CONF_DIR}/mirrors.conf"
LOGFILE="/var/log/ezmirror.log"
WEBROOT="/var/www/html"

[[ -f "$LAB_CONF"   ]] || die "Lab config not found — run setup.sh first."
[[ -f "$PATHS_CONF" ]] || die "Paths config not found — run setup.sh first."
source "$LAB_CONF"
source "$PATHS_CONF"
LOCATION_CITY="${LOCATION%, *}"

echo -e "\n${B}ezmirror — Manage Mirrors${N}"
echo ""
echo -e "  ${B}Lab${N}      ${LAB_NAME}"
echo -e "  ${B}Domain${N}   ${DOMAIN}"
echo -e "  ${B}Data${N}     ${MIRROR_BASE_DIR}/pub/"
echo ""
read -rp "  Continue to mirror selection? [Y/n] " _go
[[ "${_go,,}" == "n" ]] && { echo "  Aborted."; exit 0; }

MIRROR_CATALOG=(
    "debian|Debian GNU/Linux|Stable, testing, and unstable package archive|rsync://rsync.debian.org/debian/|rsync|~2.0 TiB|large|12h"
    "ubuntu|Ubuntu|Canonical packages and LTS/current releases|rsync://rsync.ubuntu.com/ubuntu/|rsync|~2.0 TiB|large|12h"
    "arch|Arch Linux|Rolling release — x86_64 and arm|rsync://rsync.archlinux.org/archlinux/|rsync|~120 GiB||1h"
    "alpine|Alpine Linux|Lightweight, security-oriented distribution|rsync://dl-cdn.alpinelinux.org/alpine/|rsync|~100 GiB||6h"
    "mint|Linux Mint|Ubuntu-based beginner-friendly distribution|rsync://rsync.linuxmint.com/mint/|rsync|~5.0 TiB|large|24h"
    "gentoo|Gentoo Linux|Source-based meta-distribution + portage tree|rsync://rsync.gentoo.org/gentoo/|rsync|~500 GiB||6h"
    "fedora|Fedora Linux|RPM-based, sponsored by Red Hat|rsync://dl.fedoraproject.org/fedora-enchilada/linux/|rsync|~3.0 TiB|large|12h"
    "rocky|Rocky Linux|RHEL-compatible community enterprise distro|rsync://dl.rockylinux.org/pub/rocky/|rsync|~1.0 TiB|large|12h"
    "almalinux|AlmaLinux|Binary-compatible RHEL rebuild|rsync://repo.almalinux.org/almalinux/|rsync|~1.0 TiB|large|12h"
    "centos-stream|CentOS Stream|Upstream development branch of RHEL|rsync://rsync.centos.org/centos/|rsync|~500 GiB||12h"
    "kali|Kali Linux|Security-focused Debian derivative|rsync://rsync.kali.org/kali/|rsync|~600 GiB||6h"
    "opensuse|openSUSE|Community-supported SUSE variants|rsync://rsync.opensuse.org/opensuse/|rsync|~2.0 TiB|large|12h"
    "raspios|Raspberry Pi OS|Official OS for Raspberry Pi hardware|rsync://archive.raspberrypi.com/|rsync|~200 GiB||12h"
    "popos|Pop!_OS|System76 Ubuntu-based developer distro|rsync://apt.pop-os.org/release/|rsync|~300 GiB||12h"
    "nyarch|NyarchLinux|Arch-based anime desktop (SourceForge)|nyarch-sf:/home/frs/project/nyarchlinux/|rclone-sftp|~20 GiB||24h"
)

SELECTED_MIRRORS=()
CUSTOM_MIRRORS=()
declare -A MIRROR_CREDS

# Pre-select mirrors from mirrors.conf
if [[ -f "$MIRRORS_CONF" ]]; then
    while IFS='|' read -r slug name desc upstream method _s _w interval || [[ -n "${slug:-}" ]]; do
        [[ -z "${slug:-}" || "${slug:0:1}" == "#" ]] && continue
        SELECTED_MIRRORS+=("$slug")
        found_in_catalog=false
        for (( i=0; i<${#MIRROR_CATALOG[@]}; i++ )); do
            IFS='|' read -ra cp <<< "${MIRROR_CATALOG[$i]}"
            [[ "${cp[0]}" == "$slug" ]] && { found_in_catalog=true; break; }
        done
        [[ "$found_in_catalog" == false ]] && \
            CUSTOM_MIRRORS+=("${slug}|${name}|${desc}|${upstream}|${method}||${interval}")
    done < "$MIRRORS_CONF"
    info "Loaded ${#SELECTED_MIRRORS[@]} existing mirror(s) from mirrors.conf"
fi

catalog_field() { local entry="${MIRROR_CATALOG[$1]}"; IFS='|' read -ra p <<< "$entry"; echo "${p[$2]:-}"; }
is_selected() { local slug="$1"; for s in "${SELECTED_MIRRORS[@]:-}"; do [[ "$s" == "$slug" ]] && return 0; done; return 1; }
toggle_mirror() {
    local slug="$1" new=() found=false
    for s in "${SELECTED_MIRRORS[@]:-}"; do [[ "$s" == "$slug" ]] && found=true || new+=("$s"); done
    [[ "$found" == true ]] && SELECTED_MIRRORS=("${new[@]:-}") || SELECTED_MIRRORS+=("$slug")
}
get_mirror_entry() {
    local target="$1"
    for (( i=0; i<${#MIRROR_CATALOG[@]}; i++ )); do
        local s; s=$(catalog_field "$i" 0); [[ "$s" == "$target" ]] && { echo "${MIRROR_CATALOG[$i]}"; return; }
    done
    for cm in "${CUSTOM_MIRRORS[@]:-}"; do
        local s; s=$(echo "$cm" | cut -d'|' -f1); [[ "$s" == "$target" ]] && { echo "$cm"; return; }
    done
}

show_panel() {
    clear; echo -e "\n${B}  Mirror Selection${N}"; echo -e "  Choose which distributions to host."; echo ""
    rule
    printf "  %-3s  %-4s  %-14s  %-30s  %-10s  %s\n" "#" "Sel" "Slug" "Name" "Est. Size" "Interval"
    rule
    local catalog_count="${#MIRROR_CATALOG[@]}"
    for (( i=0; i<catalog_count; i++ )); do
        local slug name size warn interval
        slug=$(catalog_field "$i" 0); name=$(catalog_field "$i" 1); size=$(catalog_field "$i" 5)
        warn=$(catalog_field "$i" 6); interval=$(catalog_field "$i" 7); interval="${interval:-6h}"
        local marker="[ ]"; is_selected "$slug" && marker="[${G}✓${N}]"
        local warn_str=""; [[ "$warn" == "large" ]] && warn_str=" ${Y}⚠${N}"
        printf "  %-3s  " "$(( i+1 ))"
        echo -e "${marker}  $(printf '%-14s  %-30s  %-10s' "$slug" "$name" "$size")  ${interval}${warn_str}"
    done
    local custom_start=$(( catalog_count + 1 ))
    for (( j=0; j<${#CUSTOM_MIRRORS[@]}; j++ )); do
        local cslug; cslug=$(echo "${CUSTOM_MIRRORS[$j]}" | cut -d'|' -f1)
        local cname; cname=$(echo "${CUSTOM_MIRRORS[$j]}" | cut -d'|' -f2)
        local csize; csize=$(echo "${CUSTOM_MIRRORS[$j]}" | cut -d'|' -f6)
        local cmethod; cmethod=$(echo "${CUSTOM_MIRRORS[$j]}" | cut -d'|' -f5)
        local cinterval; cinterval=$(echo "${CUSTOM_MIRRORS[$j]}" | cut -d'|' -f7); cinterval="${cinterval:-6h}"
        local cmarker="[ ]"; is_selected "$cslug" && cmarker="[${G}✓${N}]"
        local type_str=""
        [[ "$cmethod" == "original" ]] && type_str=" ${C}[origin]${N}"
        [[ "$cmethod" == "mirror"   ]] && type_str=" ${Y}[mirror]${N}"
        printf "  %-3s  " "$(( custom_start + j ))"
        echo -e "${cmarker}  $(printf '%-14s  %-30s  %-10s' "$cslug" "$cname" "${csize:-unknown}")  ${cinterval}${type_str}"
    done
    local add_n=$(( catalog_count + ${#CUSTOM_MIRRORS[@]} + 1 ))
    printf "  %-3s  %s\n" "$add_n" "     + Add custom mirror…"
    rule; echo ""
    echo -e "  Selected: ${B}${#SELECTED_MIRRORS[@]}${N} mirror(s)"
    echo -e "  Type a number to toggle  •  ${B}a${N} all  •  ${B}n${N} none  •  ${B}done${N} to continue"; echo ""
}

prompt_custom_mirror() {
    echo ""; echo -e "${B}  Add Custom Mirror${N}"; echo ""
    local cslug cname cdesc cupstream cmethod cinterval
    read -rp "  Slug:                               " cslug
    [[ -z "$cslug" ]] && { warn "Slug cannot be empty."; return; }
    local all_slugs=()
    for (( i=0; i<${#MIRROR_CATALOG[@]}; i++ )); do all_slugs+=("$(catalog_field "$i" 0)"); done
    for cm in "${CUSTOM_MIRRORS[@]:-}"; do all_slugs+=("$(echo "$cm" | cut -d'|' -f1)"); done
    for s in "${all_slugs[@]:-}"; do [[ "$s" == "$cslug" ]] && { warn "Slug '$cslug' already exists."; return; }; done
    read -rp "  Display name:                       " cname
    read -rp "  Short description:                  " cdesc
    echo "  Sync method: [1] rsync  [2] rclone-http  [3] original  [4] mirror"
    read -rp "  Choice [1]:                         " cmethod_n
    case "${cmethod_n:-1}" in 2) cmethod="rclone-http";; 3) cmethod="original";; 4) cmethod="mirror";; *) cmethod="rsync";; esac
    if [[ "$cmethod" == "original" ]]; then
        cupstream="none"
    elif [[ "$cmethod" == "mirror" ]]; then
        read -rp "  Upstream rsync URL:                 " cupstream
        [[ -z "$cupstream" ]] && { warn "URL cannot be empty."; return; }
        read -rp "  Username [blank = anon]:            " cmirror_user
        if [[ -n "$cmirror_user" ]]; then
            read -rsp "  Password:                           " cmirror_pass; echo ""
            MIRROR_CREDS["${cslug}"]="${cmirror_user}:${cmirror_pass}"
        fi
    else
        read -rp "  Upstream URL:                       " cupstream
    fi
    read -rp "  Estimated size:                     " csize
    read -rp "  Sync interval [6h]:                 " cinterval; cinterval="${cinterval:-6h}"
    read -rp "  Bandwidth limit Mbps [0=unlimited]: " cbw; cbw="${cbw:-0}"
    read -rp "  Retention days [0=forever]:         " cretdays; cretdays="${cretdays:-0}"
    read -rp "  Max size GiB [0=no limit]:          " cretgib; cretgib="${cretgib:-0}"
    CUSTOM_MIRRORS+=("${cslug}|${cname}|${cdesc}|${cupstream}|${cmethod}|${csize:-unknown}||${cinterval}|${cbw}|${cretdays}|${cretgib}")
    SELECTED_MIRRORS+=("$cslug")
    ok "Added '${cslug}' (${cmethod}) and selected it."; sleep 1
}

run_panel() {
    local catalog_count="${#MIRROR_CATALOG[@]}"
    while true; do
        show_panel
        local add_n=$(( catalog_count + ${#CUSTOM_MIRRORS[@]} + 1 ))
        read -rp "  > " input
        [[ -z "$input" || "${input,,}" == "done" || "${input,,}" == "d" ]] && break
        if [[ "${input,,}" == "a" ]]; then
            SELECTED_MIRRORS=()
            for (( i=0; i<catalog_count; i++ )); do SELECTED_MIRRORS+=("$(catalog_field "$i" 0)"); done
            for cm in "${CUSTOM_MIRRORS[@]:-}"; do SELECTED_MIRRORS+=("$(echo "$cm" | cut -d'|' -f1)"); done
            continue
        fi
        [[ "${input,,}" == "n" ]] && { SELECTED_MIRRORS=(); continue; }
        for token in $input; do
            if [[ "$token" =~ ^[0-9]+$ ]]; then
                local idx=$(( token - 1 ))
                if (( idx >= 0 && idx < catalog_count )); then
                    toggle_mirror "$(catalog_field "$idx" 0)"
                elif (( idx >= catalog_count && idx < catalog_count + ${#CUSTOM_MIRRORS[@]} )); then
                    toggle_mirror "$(echo "${CUSTOM_MIRRORS[$(( idx - catalog_count ))]}" | cut -d'|' -f1)"
                elif (( token == add_n )); then
                    prompt_custom_mirror
                fi
            fi
        done
    done
    if [[ ${#SELECTED_MIRRORS[@]} -eq 0 ]]; then
        warn "No mirrors selected."; read -rp "  Press Enter to go back…" _; run_panel
    fi
}

run_panel

echo -e "\n${B}  Selected mirrors:${N}"
for slug in "${SELECTED_MIRRORS[@]}"; do
    entry="$(get_mirror_entry "$slug")"; IFS='|' read -ra parts <<< "$entry"
    interval="${parts[7]:-6h}"
    echo -e "    ${G}✓${N}  ${parts[0]}  —  ${parts[1]}  (${parts[4]}, every ${interval})"
done
echo ""

read -rp "  Apply changes? [Y/n] " _apply
[[ "${_apply,,}" == "n" ]] && { echo "  Aborted — no changes made."; exit 0; }

hdr "Updating configuration"

mkdir -p "${LINUX_DIR}"
for slug in "${SELECTED_MIRRORS[@]}"; do
    mkdir -p "${LINUX_DIR}/${slug}"; ok "/pub/linux/${slug}/"
done
chown -R www-data:www-data "${PUB_DIR}"; chmod -R 755 "${PUB_DIR}"

{
    echo "# ezmirror — active mirrors"
    echo "# Updated by ezmirror-manage on $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "# Format: slug|Name|Description|Upstream|Method|Size|warn|interval|bandwidth|retention_days|retention_max_gib"
    echo "#"
    for slug in "${SELECTED_MIRRORS[@]}"; do
        entry="$(get_mirror_entry "$slug")"; IFS='|' read -ra p <<< "$entry"
        echo "${p[0]}|${p[1]}|${p[2]}|${p[3]}|${p[4]}|${p[5]:-}|${p[6]:-}|${p[7]:-6h}|${p[8]:-0}|${p[9]:-0}|${p[10]:-0}"
    done
} > "$MIRRORS_CONF"
ok "$MIRRORS_CONF"

for slug in "${SELECTED_MIRRORS[@]}"; do
    method="$(get_mirror_entry "$slug" | cut -d'|' -f5)"
    [[ "$method" != "mirror" ]] && continue
    secrets_file="${CONF_DIR}/${slug}.secrets"
    if [[ -n "${MIRROR_CREDS[$slug]:-}" ]]; then
        echo "${MIRROR_CREDS[$slug]}" > "$secrets_file"; chmod 600 "$secrets_file"
        ok "${secrets_file}  (credentials saved)"
    elif [[ ! -f "$secrets_file" ]]; then
        echo "" > "$secrets_file"; chmod 600 "$secrets_file"
        ok "${secrets_file}  (anonymous)"
    else
        ok "${secrets_file}  (existing credentials kept)"
    fi
done

echo ""
echo -e "${G}${B}Done.${N}"
echo ""
echo -e "  Run ${B}sudo ezmirror-sync${N} to sync all mirrors now."
echo -e "  Run ${B}sudo ezmirror-sync --mirror=<slug>${N} to sync one mirror."
echo -e "  Run ${B}ezmirror-status${N} to see sync status."
echo ""
MEOF
chmod +x "$MANAGE_BIN"
ok "$MANAGE_BIN"

# =============================================================================
hdr "11. ezmirror-status"
# =============================================================================

cat > "$STATUS_BIN" << 'SEOF'
#!/usr/bin/env bash
# ezmirror-status — show sync status for all configured mirrors
set -euo pipefail

CONF_DIR="/etc/ezmirror"
CONF="${CONF_DIR}/mirrors.conf"
PATHS_CONF="${CONF_DIR}/paths.conf"
WEBROOT="/var/www/html"

[[ -f "$PATHS_CONF" ]] && source "$PATHS_CONF"

B='\033[1m' G='\033[0;32m' R='\033[0;31m' Y='\033[1;33m' C='\033[0;36m' N='\033[0m'
rule() { printf '%s\n' "$(printf '─%.0s' {1..100})"; }

status_file="${WEBROOT}/status.json"

echo -e "\n${B}ezmirror status${N}"
echo -e "  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""
rule
printf "  %-14s  %-8s  %-10s  %-16s  %-10s  %-10s  %-8s  %-12s  %s\n" \
    "Mirror" "Method" "Interval" "Last Sync" "Disk Used" "Upstream" "BW Limit" "Retention" "Status"
rule

[[ -f "$CONF" ]] || { echo "  No mirrors.conf found — run setup.sh first."; exit 1; }

while IFS='|' read -r slug name desc upstream method _s _w interval bw_limit retention_days retention_max_gib || [[ -n "${slug:-}" ]]; do
    [[ -z "${slug:-}" || "${slug:0:1}" == "#" ]] && continue
    interval="${interval:-6h}"
    bw_limit="${bw_limit:-0}"
    retention_days="${retention_days:-0}"
    retention_max_gib="${retention_max_gib:-0}"

    last_sync="never"; disk_used="—"; status_str="unknown"; status_color="$Y"
    upstream_str="—"; bw_str="∞"; retention_str="forever"

    (( bw_limit > 0 )) && bw_str="${bw_limit} Mbps"
    [[ "$method" == "original" ]] && bw_str="—"

    if (( retention_days > 0 && retention_max_gib > 0 )); then
        retention_str="${retention_days}d/${retention_max_gib}G"
    elif (( retention_days > 0 )); then
        retention_str="${retention_days}d"
    elif (( retention_max_gib > 0 )); then
        retention_str="${retention_max_gib} GiB max"
    fi
    [[ "$method" == "original" ]] && retention_str="—"

    if [[ -f "$status_file" ]]; then
        m_data=$(jq -r --arg s "$slug" '.mirrors[$s] // empty' "$status_file" 2>/dev/null || true)
        if [[ -n "$m_data" ]]; then
            ts=$(echo "$m_data" | jq -r '.last_sync // 0')
            disk_bytes=$(echo "$m_data" | jq -r '.disk_bytes // 0')
            status_val=$(echo "$m_data" | jq -r '.status // "unknown"')
            uh=$(echo "$m_data" | jq -r '.upstream_health // "—"')

            if (( ts > 0 )); then
                ago=$(( ($(date +%s) - ts) / 3600 ))
                last_sync="${ago}h ago"
            fi
            if (( disk_bytes > 0 )); then
                disk_gib=$(echo "scale=1; $disk_bytes / 1073741824" | bc 2>/dev/null || echo "?")
                disk_used="${disk_gib} GiB"
            fi
            if [[ "$method" == "original" ]]; then
                upstream_str="—"
            elif [[ "$uh" == "ok" ]]; then
                upstream_str="${G}✓ ok${N}"
            elif [[ "$uh" == "fail" ]]; then
                upstream_str="${R}✗ down${N}"
            fi

            if [[ "$status_val" == "ok" ]]; then
                status_str="✓ ok"; status_color="$G"
            elif [[ "$status_val" == "error" ]]; then
                status_str="✗ error"; status_color="$R"
            else
                status_str="$status_val"; status_color="$Y"
            fi
        fi
    fi

    printf "  %-14s  %-8s  %-10s  %-16s  %-10s  " "$slug" "$method" "$interval" "$last_sync" "$disk_used"
    printf "%-10b  %-8s  %-12s  " "$upstream_str" "$bw_str" "$retention_str"
    echo -e "${status_color}${status_str}${N}"

done < "$CONF"

rule
echo ""

if systemctl is-active ezmirror-sync.timer &>/dev/null; then
   next_usec=$(systemctl show ezmirror-sync.timer --property=NextElapseUSecRealtime --value 2>/dev/null || echo "0")
if [[ "$next_usec" -gt 1000000000000000 ]]; then
    next=$(echo "$next_usec" | awk '{printf "%s", strftime("%Y-%m-%d %H:%M UTC", $1/1000000)}')
else
    next="pending/not scheduled"
fi
    echo -e "  ${G}✓${N} Timer active. Next run: ${next}"
else
    echo -e "  ${Y}!${N} ezmirror-sync.timer is not active."
fi
echo ""
SEOF
chmod +x "$STATUS_BIN"
ok "$STATUS_BIN"

# =============================================================================
hdr "12. ezmirror-logs"
# =============================================================================

cat > "$LOGS_BIN" << 'LEOF'
#!/usr/bin/env bash
# ezmirror-logs — view sync logs for all or a specific mirror
# Usage:
#   ezmirror-logs              show last 50 lines
#   ezmirror-logs arch         show all log entries for 'arch'
#   ezmirror-logs arch -f      follow log for 'arch'
#   ezmirror-logs --errors     show only errors and warnings

LOGFILE="/var/log/ezmirror.log"
[[ -f "$LOGFILE" ]] || { echo "No log file at ${LOGFILE}"; exit 1; }

SLUG=""
FOLLOW=false
ERRORS_ONLY=false

for arg in "$@"; do
    case "$arg" in
        -f|--follow) FOLLOW=true ;;
        --errors)    ERRORS_ONLY=true ;;
        -*)          ;;
        *)           SLUG="$arg" ;;
    esac
done

B='\033[1m' N='\033[0m'
echo -e "\n${B}ezmirror logs${N}${SLUG:+ — ${SLUG}}${ERRORS_ONLY:+ [errors only]}\n"

if [[ -n "$SLUG" ]]; then
    pattern="$SLUG"
    [[ "$ERRORS_ONLY" == true ]] && pattern="(${SLUG}).*(WARN|ERROR)"
    if [[ "$FOLLOW" == true ]]; then
        tail -f "$LOGFILE" | grep --line-buffered -i "$pattern"
    else
        grep -i "$pattern" "$LOGFILE" | tail -100
    fi
elif [[ "$ERRORS_ONLY" == true ]]; then
    if [[ "$FOLLOW" == true ]]; then
        tail -f "$LOGFILE" | grep --line-buffered -E "\[(WARN|ERROR)\]"
    else
        grep -E "\[(WARN|ERROR)\]" "$LOGFILE" | tail -100
    fi
else
    if [[ "$FOLLOW" == true ]]; then
        tail -f "$LOGFILE"
    else
        tail -50 "$LOGFILE"
    fi
fi
LEOF
chmod +x "$LOGS_BIN"
ok "$LOGS_BIN"

# =============================================================================
hdr "12b. ezmirror-verify"
# =============================================================================

VERIFY_BIN="/usr/local/bin/ezmirror-verify"
cat > "$VERIFY_BIN" << 'VEOF'
#!/usr/bin/env bash
# ezmirror-verify — verify mirror integrity vs upstream
# Usage:
#   ezmirror-verify [slug] [--quick] [--deep]
#   --quick  file count + size comparison vs upstream (default)
#   --deep   validate SHA256SUMS files locally
set -euo pipefail

CONF_DIR="/etc/ezmirror"
CONF="${CONF_DIR}/mirrors.conf"
PATHS_CONF="${CONF_DIR}/paths.conf"
WEBROOT="/var/www/html"
[[ -f "$PATHS_CONF" ]] && source "$PATHS_CONF"

B='\033[1m' G='\033[0;32m' R='\033[0;31m' Y='\033[1;33m' N='\033[0m'
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
ok()   { echo -e "  ${G}✓${N}  $*"; }
warn() { echo -e "  ${Y}!${N}  $*"; }
err()  { echo -e "  ${R:-\033[0;31m}✗${N}  $*"; }

ONLY_SLUG=""
MODE="quick"
for arg in "$@"; do
    case "$arg" in
        --quick) MODE="quick" ;;
        --deep)  MODE="deep"  ;;
        --*)     ;;
        *)       ONLY_SLUG="$arg" ;;
    esac
done

[[ -f "$CONF" ]] || { echo "No mirrors.conf — run setup.sh first."; exit 1; }

verify_quick() {
    local slug="$1" upstream="$2" method="$3"
    local mirror_dir="${LINUX_DIR}/${slug}"
    [[ -d "$mirror_dir" ]] || { warn "${slug}: mirror directory missing"; return 1; }

    local local_count; local_count=$(find "$mirror_dir" -type f ! -name "index.html" ! -name "files.json" ! -name "SHA256SUMS" | wc -l)
    local local_size; local_size=$(du -sb "$mirror_dir" 2>/dev/null | awk '{print $1}' || echo 0)

    if [[ "$method" == "original" ]]; then
        ok "${slug}: original mirror — ${local_count} files, $(( local_size / 1073741824 )) GiB"
        return 0
    fi

    local remote_size=0
    remote_size=$(timeout 60 rsync --list-only --no-motd "$upstream" 2>/dev/null | awk '{sum+=$2}END{print sum+0}' || echo 0)

    if (( remote_size > 0 )); then
        local delta=$(( (local_size - remote_size) * 100 / (remote_size + 1) ))
        if (( delta < -10 || delta > 10 )); then
            warn "${slug}: size mismatch — local=$(( local_size / 1048576 ))MiB remote=$(( remote_size / 1048576 ))MiB (${delta}%)"
            return 1
        fi
    fi
    ok "${slug}: ok — ${local_count} files, $(( local_size / 1073741824 )) GiB"

    local status_file="${WEBROOT}/status.json"
    local now; now=$(date +%s)
    if [[ -f "$status_file" ]]; then
        local current; current=$(cat "$status_file")
        echo "$current" | jq \
            --arg slug "$slug" --argjson now "$now" \
            --arg vs "ok" --arg vm "${local_count} files" --argjson fc "$local_count" \
            '.mirrors[$slug].last_verify=$now | .mirrors[$slug].verify_status=$vs | .mirrors[$slug].verify_message=$vm | .mirrors[$slug].file_count=$fc' \
            > "${status_file}.tmp" && mv "${status_file}.tmp" "$status_file"
    fi
    return 0
}

verify_deep() {
    local slug="$1"
    local mirror_dir="${LINUX_DIR}/${slug}"
    local fail=0
    find "$mirror_dir" -name "SHA256SUMS" 2>/dev/null | while read -r sums_file; do
        local dir; dir=$(dirname "$sums_file")
        if (cd "$dir" && sha256sum -c SHA256SUMS --quiet 2>/dev/null); then
            log "[VERIFY] ${dir##*/}: checksums ok"
        else
            log "[VERIFY] ERROR in ${dir}: hash mismatch"
            fail=1
        fi
    done
    if [[ $fail -eq 0 ]]; then
        ok "${slug}: deep verify passed"
    else
        err "${slug}: deep verify FAILED — hash mismatches found"
        return 1
    fi
}

echo -e "\n${B}ezmirror-verify [${MODE}]${N}\n"

while IFS='|' read -r slug name _desc upstream method _s _w _i || [[ -n "${slug:-}" ]]; do
    [[ -z "${slug:-}" || "${slug:0:1}" == "#" ]] && continue
    [[ -n "$ONLY_SLUG" && "$slug" != "$ONLY_SLUG" ]] && continue

    log "Verifying ${slug} (${method})…"
    case "$MODE" in
        quick) verify_quick "$slug" "$upstream" "$method" || true ;;
        deep)
            verify_quick "$slug" "$upstream" "$method" || true
            verify_deep  "$slug" || true
            ;;
    esac
done < "$CONF"

echo ""
VEOF
chmod +x "$VERIFY_BIN"
ok "$VERIFY_BIN"

# =============================================================================
hdr "12c. ezmirror-health"
# =============================================================================

HEALTH_BIN="/usr/local/bin/ezmirror-health"
cat > "$HEALTH_BIN" << 'HEOF'
#!/usr/bin/env bash
# ezmirror-health — check upstream reachability for all (or one) mirrors
# Usage:
#   ezmirror-health [slug]
#   ezmirror-health --all
#   ezmirror-health --alert    (only report failures)
set -euo pipefail

CONF_DIR="/etc/ezmirror"
CONF="${CONF_DIR}/mirrors.conf"
PATHS_CONF="${CONF_DIR}/paths.conf"
ALERT_CONF="${CONF_DIR}/alert.conf"
WEBROOT="/var/www/html"
[[ -f "$PATHS_CONF" ]] && source "$PATHS_CONF"
[[ -f "$ALERT_CONF" ]] && source "$ALERT_CONF" || { ALERT_WEBHOOK=""; ALERT_EMAIL=""; }

B='\033[1m' G='\033[0;32m' R='\033[0;31m' Y='\033[1;33m' N='\033[0m'
rule() { printf '%s\n' "$(printf '─%.0s' {1..70})"; }

ONLY_SLUG=""
ALERT_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --all)   ONLY_SLUG="" ;;
        --alert) ALERT_ONLY=true ;;
        --*)     ;;
        *)       ONLY_SLUG="$arg" ;;
    esac
done

send_alert() {
    local slug="$1" msg="$2"
    local title="ezmirror health: ${slug} upstream DOWN"
    [[ -n "${ALERT_WEBHOOK:-}" ]] && \
        curl -s -X POST "$ALERT_WEBHOOK" -H 'Content-Type: application/json' \
            -d "{\"embeds\":[{\"title\":\"${title}\",\"description\":\"${msg}\",\"color\":15158332}]}" > /dev/null 2>&1 || true
    [[ -n "${ALERT_EMAIL:-}" ]] && \
        echo -e "Subject: ${title}\n\n${msg}" | mail -s "$title" "$ALERT_EMAIL" 2>/dev/null || true
}

check_upstream() {
    local slug="$1" upstream="$2" method="$3"
    local t0; t0=$(date +%s%3N)
    local result="ok"
    case "$method" in
        original) echo "—"; return ;;
        rsync|mirror)
            timeout 10 rsync --list-only --no-motd "$upstream" > /dev/null 2>&1 || result="fail" ;;
        rclone-sftp)
            local rname="${upstream%%:*}"
            timeout 10 rclone lsd "${rname}:" > /dev/null 2>&1 || result="fail" ;;
        rclone-http)
            timeout 10 curl -sI "$upstream" > /dev/null 2>&1 || result="fail" ;;
    esac
    local ms=$(( $(date +%s%3N) - t0 ))

    local status_file="${WEBROOT}/status.json"
    local now; now=$(date +%s)
    if [[ -f "$status_file" ]]; then
        local current; current=$(cat "$status_file")
        echo "$current" | jq \
            --arg slug "$slug" --argjson now "$now" \
            --arg uh "$result" --argjson rt "$ms" \
            '.mirrors[$slug].upstream_health=$uh | .mirrors[$slug].upstream_health_checked=$now | .mirrors[$slug].upstream_response_time_ms=$rt' \
            > "${status_file}.tmp" && mv "${status_file}.tmp" "$status_file" 2>/dev/null || true
    fi

    echo "${result} (${ms}ms)"
}

[[ "$ALERT_ONLY" == false ]] && { echo -e "\n${B}ezmirror-health${N}\n"; rule; printf "  %-14s  %-8s  %s\n" "Mirror" "Method" "Health"; rule; }

[[ -f "$CONF" ]] || { echo "No mirrors.conf — run setup.sh first."; exit 1; }

while IFS='|' read -r slug _name _desc upstream method _s _w _i || [[ -n "${slug:-}" ]]; do
    [[ -z "${slug:-}" || "${slug:0:1}" == "#" ]] && continue
    [[ -n "$ONLY_SLUG" && "$slug" != "$ONLY_SLUG" ]] && continue

    result=$(check_upstream "$slug" "$upstream" "$method")

    if [[ "$result" == *"fail"* ]]; then
        [[ "$ALERT_ONLY" == false ]] && printf "  %-14s  %-8s  ${R}✗ DOWN${N} (%s)\n" "$slug" "$method" "$result"
        send_alert "$slug" "Upstream unreachable for mirror '${slug}' (${upstream})"
    else
        [[ "$ALERT_ONLY" == false ]] && printf "  %-14s  %-8s  ${G}✓ ok${N} — %s\n" "$slug" "$method" "$result"
    fi
done < "$CONF"

[[ "$ALERT_ONLY" == false ]] && { rule; echo ""; }
HEOF
chmod +x "$HEALTH_BIN"
ok "$HEALTH_BIN"

# =============================================================================
hdr "12d. ezmirror-update / ezmirror-rollback"
# =============================================================================

UPDATE_BIN="/usr/local/bin/ezmirror-update"
cat > "$UPDATE_BIN" << 'UEOF'
#!/usr/bin/env bash
# ezmirror-update — in-place update with zero downtime
# Usage:
#   ezmirror-update [--list]         list available versions
#   ezmirror-update --test VERSION   dry-run test only
#   ezmirror-update VERSION          perform update
set -euo pipefail

VERSION_FILE="/etc/ezmirror/version"
BACKUP_DIR="/etc/ezmirror/backups"
CURRENT_VERSION=$(cat "$VERSION_FILE" 2>/dev/null || echo "unknown")
GH_RELEASES="https://api.github.com/repos/netplayz/ezmirror/releases"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run with sudo: sudo ezmirror-update"

case "${1:-}" in
    --list)
        log "Fetching available versions…"
        curl -fsSL "${GH_RELEASES}" 2>/dev/null | \
            grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/' | head -10
        exit 0
        ;;
    --test)
        TARGET_VERSION="${2:-}" ; [[ -n "$TARGET_VERSION" ]] || die "Usage: ezmirror-update --test VERSION"
        TEST_DIR="/tmp/ezmirror-test-${TARGET_VERSION}"
        log "Testing update to ${TARGET_VERSION} (no changes made)…"
        mkdir -p "${TEST_DIR}"/{etc,usr/local/bin}
        cp -r /etc/ezmirror "${TEST_DIR}/etc/" 2>/dev/null || true
        while IFS='|' read -r slug rest; do
            [[ -z "$slug" || "$slug" == \#* ]] && continue
            [[ -z "$rest" ]] && { log "✗ Invalid mirrors.conf line: $slug"; rm -rf "$TEST_DIR"; exit 1; }
        done < "/etc/ezmirror/mirrors.conf"
        rm -rf "$TEST_DIR"
        log "✓ Pre-flight checks passed — safe to update"
        exit 0
        ;;
    "")
        die "Usage: ezmirror-update [--list | --test VERSION | VERSION]"
        ;;
esac

TARGET_VERSION="$1"

log "ezmirror update: ${CURRENT_VERSION} → ${TARGET_VERSION}"

# Step 1: Download
log "Downloading ezmirror ${TARGET_VERSION}…"
curl -fsSL "https://github.com/netplayz/ezmirror/releases/download/v${TARGET_VERSION}/setup.sh" \
    -o /tmp/ezmirror-setup-new.sh || die "Download failed"
log "✓ Downloaded"

# Step 2: Backup config
mkdir -p "$BACKUP_DIR"
BACKUP_TIME=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/ezmirror_${CURRENT_VERSION}_${BACKUP_TIME}.tar.gz"
tar -czf "$BACKUP_FILE" \
    /etc/ezmirror/ \
    /usr/local/bin/ezmirror-* \
    /etc/systemd/system/ezmirror-* \
    /etc/logrotate.d/ezmirror \
    /etc/nginx/ezmirror-mirrors.conf \
    2>/dev/null || true
log "✓ Backed up to ${BACKUP_FILE}"

# Step 3: Graceful sync stop — wait up to 5 min for active sync
log "Waiting for active syncs to finish…"
for i in {1..300}; do
    pgrep -f "/usr/local/bin/ezmirror-sync" > /dev/null 2>&1 || break
    sleep 1
done
systemctl stop ezmirror-sync.timer ezmirror-sync.service 2>/dev/null || true
log "✓ Syncs stopped"

# Step 4: Run migration script if available
MIGRATE_SCRIPT="/opt/ezmirror/migrate-${CURRENT_VERSION}-to-${TARGET_VERSION}.sh"
if [[ -f "$MIGRATE_SCRIPT" ]]; then
    log "Running migration: ${MIGRATE_SCRIPT}"
    bash "$MIGRATE_SCRIPT" || die "Migration failed — aborting"
    log "✓ Migration complete"
else
    MIRRORS_CONF="/etc/ezmirror/mirrors.conf"
    TEMP_CONF=$(mktemp)
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -z "$line" || "${line:0:1}" == "#" ]]; then
            echo "$line" >> "$TEMP_CONF"; continue
        fi
        IFS='|' read -ra fields <<< "$line"
        while (( ${#fields[@]} < 11 )); do fields+=("0"); done
        ( IFS='|'; echo "${fields[*]}" ) >> "$TEMP_CONF"
    done < "$MIRRORS_CONF"
    cp "$MIRRORS_CONF" "${MIRRORS_CONF}.pre-${TARGET_VERSION}.bak"
    mv "$TEMP_CONF" "$MIRRORS_CONF"
    log "✓ mirrors.conf auto-migrated (backup: ${MIRRORS_CONF}.pre-${TARGET_VERSION}.bak)"
fi

# Step 5: Install new binaries
# FIX: source existing config and export as EZMIRROR_* so --unattended
#      preserves lab settings, domain, mirrors, and alert config instead
#      of clobbering everything with placeholder defaults.
log "Exporting existing config for unattended install…"
source /etc/ezmirror/lab.conf 2>/dev/null || true
source /etc/ezmirror/paths.conf 2>/dev/null || true
source /etc/ezmirror/alert.conf 2>/dev/null || true

export EZMIRROR_LAB_NAME="${LAB_NAME:-MyOrg Open Source Lab}"
export EZMIRROR_DOMAIN="${DOMAIN:-mirror.example.com}"
export EZMIRROR_LOCATION="${LOCATION:-Anytown, ST, US}"
export EZMIRROR_GH_USER="${GH_USER:-netplayz}"
export EZMIRROR_VOLUME="${MIRROR_BASE_DIR:-}"
export EZMIRROR_WEBHOOK="${ALERT_WEBHOOK:-}"
export EZMIRROR_EMAIL="${ALERT_EMAIL:-}"

# Rebuild mirrors list from mirrors.conf
if [[ -f /etc/ezmirror/mirrors.conf ]]; then
    _update_slugs=()
    while IFS='|' read -r _slug _rest; do
        [[ -z "${_slug:-}" || "${_slug:0:1}" == "#" ]] && continue
        _update_slugs+=("$_slug")
    done < /etc/ezmirror/mirrors.conf
    if [[ ${#_update_slugs[@]} -gt 0 ]]; then
        export EZMIRROR_MIRRORS
        EZMIRROR_MIRRORS=$(IFS=','; echo "${_update_slugs[*]}")
        log "  Mirrors to preserve: ${EZMIRROR_MIRRORS}"
    fi
fi

log "Installing new binaries…"
bash /tmp/ezmirror-setup-new.sh --unattended || die "Update install failed"
log "✓ Binaries updated"

# Step 6: Record new version
echo "$TARGET_VERSION" > "$VERSION_FILE"

# Step 7: Restart services
log "Restarting services…"
systemctl daemon-reload
systemctl restart ezmirror-sync.timer 2>/dev/null || true
log "✓ Services restarted"

log "✓ Update to ${TARGET_VERSION} complete"
log "  Backup saved: ${BACKUP_FILE}"
log "  To rollback:  sudo ezmirror-rollback ${BACKUP_FILE}"
UEOF
chmod +x "$UPDATE_BIN"
ok "$UPDATE_BIN"

ROLLBACK_BIN="/usr/local/bin/ezmirror-rollback"
cat > "$ROLLBACK_BIN" << 'RBEOF'
#!/usr/bin/env bash
# ezmirror-rollback — restore a previous backup
# Usage: sudo ezmirror-rollback /etc/ezmirror/backups/ezmirror_4.0.0_20260407_134715.tar.gz
set -euo pipefail

BACKUP="${1:-}"
[[ -n "$BACKUP" ]] || { echo "Usage: sudo ezmirror-rollback BACKUP_FILE"; exit 1; }
[[ -f "$BACKUP"  ]] || { echo "Backup not found: $BACKUP"; exit 1; }
[[ $EUID -eq 0  ]] || { echo "Run with sudo"; exit 1; }

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log "Rolling back from ${BACKUP}…"
systemctl stop ezmirror-sync.timer ezmirror-sync.service 2>/dev/null || true
tar -xzf "$BACKUP" -C /
systemctl daemon-reload
systemctl restart ezmirror-sync.timer 2>/dev/null || true
log "✓ Rollback complete"
RBEOF
chmod +x "$ROLLBACK_BIN"
ok "$ROLLBACK_BIN"

# Write initial version file if not present
[[ -f /etc/ezmirror/version ]] || echo "4.1.0" > /etc/ezmirror/version

# =============================================================================
hdr "13. Shell aliases"
# =============================================================================

cat > /etc/profile.d/ezmirror.sh << 'ALIASEOF'
# ezmirror aliases
alias ezmirror-sync='sudo /usr/local/bin/ezmirror-sync'
alias ezmirror-sync-dry='sudo /usr/local/bin/ezmirror-sync --dry-run'
alias ezmirror-sync-force='sudo /usr/local/bin/ezmirror-sync --force'
alias ezmirror-verify='sudo /usr/local/bin/ezmirror-verify'
alias ezmirror-health='/usr/local/bin/ezmirror-health'
alias ezmirror-update='sudo /usr/local/bin/ezmirror-update'
alias ezmirror-rollback='sudo /usr/local/bin/ezmirror-rollback'
ALIASEOF
ok "/etc/profile.d/ezmirror.sh"

# =============================================================================
hdr "14. systemd timer"
# =============================================================================

cat > /etc/systemd/system/ezmirror-sync.service << EOF
[Unit]
Description=ezmirror Sync — ${LAB_NAME}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${SYNC_BIN}
StandardOutput=journal
StandardError=journal
User=root
EOF

# Find the shortest interval across all selected mirrors to set timer cadence
min_interval_h=6
for slug in "${SELECTED_MIRRORS[@]}"; do
    iv="$(get_mirror_entry "$slug" | cut -d'|' -f8)"; iv="${iv:-6h}"
    h="${iv%[hHdD]}"
    [[ "${iv: -1}" == "d" || "${iv: -1}" == "D" ]] && h=$(( h * 24 ))
    (( h < min_interval_h )) && min_interval_h=$h
done
[[ $min_interval_h -lt 1 ]] && min_interval_h=1

cat > /etc/systemd/system/ezmirror-sync.timer << EOF
[Unit]
Description=ezmirror Sync Timer (checks every ${min_interval_h}h, per-mirror intervals respected)

[Timer]
OnBootSec=5min
OnUnitActiveSec=${min_interval_h}h
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now ezmirror-sync.timer
ok "ezmirror-sync.timer  (fires every ${min_interval_h}h — per-mirror intervals enforced in sync script)"

# =============================================================================
hdr "15. Initial sync"
# =============================================================================

echo ""
echo -e "  Active mirrors (${#SELECTED_MIRRORS[@]}):"
for slug in "${SELECTED_MIRRORS[@]}"; do
    entry="$(get_mirror_entry "$slug")"
    IFS='|' read -ra p <<< "$entry"
    interval="${p[7]:-6h}"
    printf "    • %-14s %s  (%s, every %s)\n" "${p[0]}" "${p[1]}" "${p[4]}" "$interval"
done
echo ""

if [[ "$UNATTENDED" == true ]]; then
    ans="n"
else
    read -rp "  Run initial sync now? [y/N] " ans
fi

if [[ "${ans,,}" == "y" ]]; then
    info "Syncing…  (large mirrors will take a while)"
    "$SYNC_BIN" --force
    ok "Initial sync complete"
else
    warn "Skipped — timer fires in ~5 minutes"
    {
        printf '['; first_e=true
        for slug in "${SELECTED_MIRRORS[@]}"; do
            entry="$(get_mirror_entry "$slug")"
            IFS='|' read -ra p <<< "$entry"
            [[ "$first_e" == false ]] && printf ','
            printf '%s' "$(jq -n --arg sl "${p[0]}" --arg n "${p[1]}" --arg d "${p[2]}" --arg m "${p[4]}" \
                '{slug:$sl,name:$n,desc:$d,path:("/pub/linux/"+$sl+"/"),method:$m}')"
            first_e=false
        done
        printf ']'
    } > "${WEBROOT}/mirrors.json"
    chown www-data:www-data "${WEBROOT}/mirrors.json"
    ok "Wrote initial mirrors.json"
fi

# =============================================================================
echo ""
echo -e "${G}${B}ezmirror setup complete.${N}"
echo ""
echo -e "  ${B}Site${N}              https://${DOMAIN}"
echo -e "  ${B}Mirror list${N}       https://${DOMAIN}/pub/linux/"
echo -e "  ${B}Status JSON${N}       https://${DOMAIN}/status.json"
echo -e "  ${B}Data volume${N}       ${MIRROR_BASE_DIR}/pub/"
echo -e "  ${B}Logs${N}              ${LOGFILE}"
echo ""
echo -e "  ${B}Sync all${N}          sudo ezmirror-sync"
echo -e "  ${B}Dry run${N}           sudo ezmirror-sync --dry-run"
echo -e "  ${B}Force all${N}         sudo ezmirror-sync --force"
echo -e "  ${B}One mirror${N}        sudo ezmirror-sync --mirror=arch"
echo -e "  ${B}Add/remove${N}        sudo ezmirror-manage"
echo -e "  ${B}Status${N}            ezmirror-status"
echo -e "  ${B}Logs${N}              ezmirror-logs [slug] [-f] [--errors]"
echo -e "  ${B}Health check${N}      ezmirror-health [--all] [--alert]"
echo -e "  ${B}Verify${N}            ezmirror-verify [slug] [--quick|--deep]"
echo -e "  ${B}Update${N}            sudo ezmirror-update VERSION"
echo -e "  ${B}Rollback${N}          sudo ezmirror-rollback BACKUP_FILE"
echo -e "  ${B}Timer${N}             systemctl status ezmirror-sync.timer"
echo ""

if [[ ${#ORIGINAL_MIRRORS[@]} -gt 0 ]]; then
    echo -e "  ${B}Original mirrors — push paths:${N}"
    for slug in "${ORIGINAL_MIRRORS[@]}"; do
        echo -e "    ${C}${slug}${N}   ${LINUX_DIR}/${slug}/"
        [[ -f /etc/rsyncd.conf ]] && \
            echo -e "          rsync push: ${PUSH_USER:-mirrorpush}@${DOMAIN}::${slug}-push/"
    done
    echo ""
    echo -e "  After pushing files: sudo ezmirror-sync --mirror=<slug>"
fi

if [[ ${#MIRROR_TYPE_MIRRORS[@]} -gt 0 ]]; then
    echo -e "  ${B}Self-hosted upstream mirrors:${N}"
    for slug in "${MIRROR_TYPE_MIRRORS[@]}"; do
        entry="$(get_mirror_entry "$slug")"
        IFS='|' read -ra p <<< "$entry"
        auth_str="anonymous"
        [[ -s "${CONF_DIR}/${slug}.secrets" ]] && auth_str="user: $(cut -d: -f1 < "${CONF_DIR}/${slug}.secrets")"
        echo -e "    ${Y}${slug}${N}   ${p[3]}   (${auth_str})"
    done
    echo ""
fi

echo -e "  ${B}rsync pull (let others mirror from you):${N}"
for slug in "${SELECTED_MIRRORS[@]}"; do
    echo -e "    rsync -avz rsync://${DOMAIN}/${slug}/ /local/${slug}/"
done
echo ""
