# ezmirror — Agent Guide

## Overview
ezmirror is a self-hostable Linux distribution mirror infrastructure.  
Mirrors are served at `/{slug}/` via nginx with fancyindex.  
A Rust daemon (`ezmirord`) handles sync scheduling, health checks, and Prometheus metrics.  
Python scripts handle setup, management, and updates.

## Key Files

| File | Purpose |
|---|---|
| `mirrors.json` | Mirror catalog (slug, name, upstream, method, interval) |
| `src/main.rs` | Daemon entry — CLI, signals, daemonization, sync loop |
| `src/config.rs` | Pipe-delimited `mirrors.conf` parser |
| `src/sync.rs` | rsync/rclone execution, status update, SHA256SUMS |
| `src/status.rs` | JSON status read/write (`/var/www/html/status.json`) |
| `src/metrics.rs` | HTTP server on `:9633` — `/metrics` (Prometheus), `/healthz` |
| `web/panel.py` | FastAPI admin panel (`/admin/`) — monitor, trigger syncs, view logs |
| `python/setup.py` | Interactive/unattended installer |
| `python/manage.py` | Mirror selection TUI |
| `templates/` | Fancyindex templates (`header.html`, `footer.html`, `style.css`) |
| `Dockerfile` | Multi-stage Rust build + debian-slim runtime |
| `docker-entrypoint.sh` | Starts nginx, ezmirord, and admin panel in container |

## Build & Test

```bash
# Build daemon
cargo build --release

# Run tests
cargo test

# Typecheck (Python)
python3 -m py_compile python/setup.py web/panel.py

# Lint
cargo clippy

# Full install (requires sudo + nginx)
sudo python3 python/setup.py --unattended
```

## Conventions

- Rust daemon: snake_case for functions/vars, uppercase for constants, `//!` for module docs
- Python: snake_case, type hints on function signatures
- Config files: pipe-delimited (`slug|Name|Description|upstream|method|size|warn|interval|bandwidth|retention_days|retention_max_gib`)
- JSON API: camelCase keys
- Git: squash feature branches, linear history on main

## Paths (runtime)

| Path | Purpose |
|---|---|
| `/etc/ezmirror/` | Config files |
| `/etc/ezmirror/mirrors.conf` | Active mirror list |
| `/usr/local/sbin/ezmirord` | Daemon binary |
| `/usr/local/bin/ezmirror-*` | CLI tools |
| `/var/www/html/` | Web root + mirror data |
| `/var/www/html/status.json` | Machine-readable sync status |
| `/var/log/ezmirror.log` | Log file |
| `127.0.0.1:9633` | Metrics/health endpoint |
| `127.0.0.1:8080` | Admin panel (proxied by nginx at `/admin/`) |

## Important Rules

- NEVER expose secrets or keys
- Keep `mirrors.json` as the single source of truth for mirror definitions
- Flat path structure — no `/pub/` or category prefixes
- All new features must maintain backward compat with existing `mirrors.conf` format
- Python setup must remain invocable via `sudo bash setup.sh`
