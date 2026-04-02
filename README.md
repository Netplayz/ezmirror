# ezmirror
<p align="center">
<img width="500" height="500" alt="EZMIRROR-removebg-preview" src="https://github.com/user-attachments/assets/816e7b15-6cc2-464a-a13c-c49643172774" />
</p>
A self-hostable Linux distribution mirror infrastructure. Interactive setup, multi-distro support, automated sync, and a clean web frontend.

## Quick Start

```bash
git clone https://github.com/Netplayz/ezmirror.git
cd ezmirror
sudo bash setup.sh
```

For unattended / CI deploys:

```bash
export EZMIRROR_LAB_NAME="Xyz Open Source Lab"
export EZMIRROR_DOMAIN="mirror.example.com"
export EZMIRROR_LOCATION="Philadelphia, PA, US"
export EZMIRROR_GH_USER="netplayz"
export EZMIRROR_MIRRORS="arch,alpine,kali"      # comma-separated slugs
export EZMIRROR_VOLUME="/mnt/data/mirrors"       # optional: storage path
export EZMIRROR_WEBHOOK="https://discord.com/api/webhooks/..."  # optional alerts
export EZMIRROR_TORRENTS="yes"                   # optional torrent seeding
sudo bash setup.sh --unattended
```

## What Gets Installed

| Path | Description |
|------|-------------|
| `/usr/local/bin/ezmirror-sync` | Sync all (or one) mirror |
| `/usr/local/bin/ezmirror-manage` | Add / remove mirrors interactively |
| `/usr/local/bin/ezmirror-status` | Show per-mirror sync status |
| `/usr/local/bin/ezmirror-logs` | View / follow sync logs |
| `/etc/ezmirror/` | Config directory |
| `/etc/ezmirror/lab.conf` | Lab branding config |
| `/etc/ezmirror/mirrors.conf` | Active mirror list |
| `/etc/ezmirror/paths.conf` | Volume/path config |
| `/etc/ezmirror/alert.conf` | Discord webhook + email alerts |
| `/var/log/ezmirror.log` | Sync log (rotated via logrotate) |
| `/var/www/html/status.json` | Machine-readable sync status |
| `/var/www/html/mirrors.json` | Mirror list for homepage |
| `/etc/systemd/system/ezmirror-sync.{service,timer}` | Systemd sync timer |
| `/etc/logrotate.d/ezmirror` | Log rotation config |

## Default Supported Mirrors

| Slug | Distro | Size | Default Interval |
|------|--------|------|-----------------|
| `debian` | Debian GNU/Linux | ~2 TiB | 12h |
| `ubuntu` | Ubuntu | ~2 TiB | 12h |
| `arch` | Arch Linux | ~120 GiB | 1h |
| `alpine` | Alpine Linux | ~100 GiB | 6h |
| `mint` | Linux Mint | ~5 TiB | 24h |
| `gentoo` | Gentoo Linux | ~500 GiB | 6h |
| `fedora` | Fedora Linux | ~3 TiB | 12h |
| `rocky` | Rocky Linux | ~1 TiB | 12h |
| `almalinux` | AlmaLinux | ~1 TiB | 12h |
| `centos-stream` | CentOS Stream | ~500 GiB | 12h |
| `kali` | Kali Linux | ~600 GiB | 6h |
| `opensuse` | openSUSE | ~2 TiB | 12h |
| `raspios` | Raspberry Pi OS | ~200 GiB | 12h |
| `popos` | Pop!_OS | ~300 GiB | 12h |

Plus any number of custom mirrors via the interactive panel or `ezmirror-manage`.

## CLI Reference

```bash
# Sync
sudo ezmirror-sync                    # sync all due mirrors (respects per-mirror intervals.) If you have just uploaded files you must use this command.
sudo ezmirror-sync --force            # sync all, ignoring intervals
sudo ezmirror-sync --dry-run          # simulate without writing
sudo ezmirror-sync --mirror=arch      # sync one mirror now

# Manage
sudo ezmirror-manage                  # add / remove mirrors interactively

# Status & Logs
ezmirror-status                       # per-mirror sync status table
ezmirror-logs                         # last 50 log lines
ezmirror-logs arch                    # logs for 'arch' only
ezmirror-logs arch -f                 # follow log for 'arch'
ezmirror-logs --errors                # only WARN / ERROR lines
ezmirror-logs --errors -f             # follow errors

# Timer
systemctl status ezmirror-sync.timer
```

## Sync Methods

| Method | Description |
|--------|-------------|
| `rsync` | Standard rsync pull from upstream `rsync://` URL |
| `rclone-sftp` | rclone pull via SFTP (e.g. SourceForge) |
| `rclone-http` | rclone pull via HTTP/FTP |
| `original` | This server **is** the origin; no upstream sync |
| `mirror` | Pull from another self-hosted ezmirror / rsync daemon |

## Features

- **Interactive TUI** — toggle mirrors, add custom entries, choose storage volume
- **Unattended mode** — full env-var-driven CI/cloud-init support
- **Per-mirror sync intervals** — Arch syncs every 1h, Debian every 12h, etc.
- **Sync lock file** — prevents overlapping runs via `flock`
- **Disk space pre-check** — warns before syncing if volume is low
- **Failure alerts** — Discord webhook + email on sync errors
- **Read-only rsync daemon** — lets others mirror from your server
- **rsyncd push daemon** — for original mirrors, contributors push via rsync
- **Torrent seeding** — auto-generates `.torrent` files for `.iso` files (optional)
- **status.json** — machine-readable per-mirror sync state at `/status.json`
- **Log rotation** — `logrotate` config keeps logs tidy (30-day retention)
- **Dark / light mode toggle** — `prefers-color-scheme` aware with manual toggle
- **File search** — client-side filter on all listing pages
- **Sortable columns** — click Name / Last Modified / Size to sort
- **Live status badge** — per-mirror pages show last sync time from `status.json`

## Upstream Registration

To be listed as an official mirror for a distribution, you typically need:

1. A public rsync endpoint: `rsync://your.domain/arch` (provided by ezmirror's rsyncd)
2. Verifiable sync freshness (ezmirror's `status.json` can help)
3. Contact the distro's mirror admin with your domain, location, and capacity

Each distro has its own mirror submission process — check their documentation.

## License

GPL-3.0

## Screenshots
<img width="1864" height="940" alt="Screenshot From 2026-03-29 09-56-57" src="https://github.com/user-attachments/assets/350660dc-66bd-4c11-8683-07a801910db3" />
<img width="1864" height="940" alt="Screenshot From 2026-03-29 09-57-37" src="https://github.com/user-attachments/assets/b4b5a9be-6a76-459f-a10b-413e07e3658a" />
<img width="1864" height="940" alt="Screenshot From 2026-03-29 09-57-22" src="https://github.com/user-attachments/assets/ed291a5a-a717-4506-a64b-6cd164320672" />

``Made with the assistance of Claude Haiku 4.5, A.S.A.S 13B paramatner internal model.``
