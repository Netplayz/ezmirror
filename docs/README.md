# ezmirror

A self-hostable, production-grade Linux distribution mirror infrastructure. Mirrors served at `/{slug}/` via nginx fancyindex. Rust daemon for sync scheduling and Prometheus metrics. Python tools for setup and management.

## Quick Start

```bash
git clone https://github.com/Netplayz/ezmirror.git
cd ezmirror
sudo bash setup.sh
```

Unattended:
```bash
export EZMIRROR_LAB_NAME="My Lab"
export EZMIRROR_DOMAIN="mirror.example.com"
export EZMIRROR_MIRRORS="debian,ubuntu,arch"
sudo bash setup.sh --unattended
```

## Features

- **FancyIndex** — nginx fancyindex module with dark/light themed directory listings, client-side search/sort
- **Rust Daemon** (`ezmirord`) — Prometheus metrics, health checks, sync scheduling, upstream health checks
- **Admin Panel** — FastAPI-based web UI at `/admin/` for monitoring and managing mirrors
- **JSON catalog** — mirror definitions in `mirrors.json`
- **Docker** — multi-stage build, single-service deployment with docker-compose
- **No `/pub/` prefix** — mirrors served directly at `/{slug}/`

## Architecture

```
ezmirror/
  mirrors.json          # Mirror catalog (single source of truth)
  setup.sh              # Shell entry point for installation
  Cargo.toml            # Rust project config
  src/
    main.rs             # Daemon entry: CLI, signals, event loop
    config.rs           # mirrors.conf parser
    sync.rs             # rsync/rclone execution engine
    status.rs           # status.json reader/writer
    metrics.rs          # HTTP server: /metrics, /healthz
  web/
    panel.py            # FastAPI admin panel
  templates/            # Fancyindex header/footer/CSS
  python/
    setup.py            # Interactive/unattended installer
    manage.py           # Mirror selection TUI
```

## Components

| Component | Language | Purpose |
|-----------|----------|---------|
| `ezmirord` | Rust | Daemon: sync scheduling, Prometheus metrics, health endpoint |
| `web/panel.py` | Python (FastAPI) | Admin panel at `/admin/` |
| `setup.py` | Python | Installer: dependencies, nginx config, templates |
| `manage.py` | Python | Interactive mirror selection |
| shell wrappers | Bash | ezmirror-sync, ezmirror-logs, ezmirror-backup, etc. |

## Commands

```bash
sudo ezmirror-sync               # Sync all mirrors
sudo ezmirror-sync debian        # Sync specific mirror
ezmirror-status                   # Show sync status
ezmirror-logs                     # View sync logs
ezmirror-logs debian -f           # Follow logs for specific mirror
sudo ezmirror-manage              # Add/remove mirrors
sudo ezmirror-update              # Self-update from GitHub
sudo ezmirror-backup              # Backup configuration
```

## Endpoints

| Endpoint | Purpose |
|----------|---------|
| `https://{domain}/admin/` | Admin panel |
| `https://{domain}/status.json` | Machine-readable sync status |
| `https://{domain}/healthz` | Health check |
| `http://127.0.0.1:9633/metrics` | Prometheus metrics |

## License

GPL-3.0
