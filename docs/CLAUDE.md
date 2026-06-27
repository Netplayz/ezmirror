# ezmirror — Project Context

## What it is
Self-hostable Linux distro mirror infrastructure. Mirrors served at `/{slug}/` via nginx fancyindex. Rust daemon for sync scheduling + metrics. Python for setup/management.

## Tech Stack
- **Rust** — `ezmirord` daemon (clap, serde, serde_json, libc)
- **Python** — setup/manage/update/rollback scripts + FastAPI admin panel
- **nginx** — fancyindex module for directory listings
- **Docker** — multi-stage build (rust:bookworm → debian-slim)

## Key Commands
```
cargo build --release        # build daemon
cargo test                    # run tests
cargo clippy                  # lint
python3 web/panel.py          # start admin panel (dev)
sudo python3 python/setup.py --unattended   # full install
```

## Code Conventions
- Rust: snake_case, `//!` module docs, uppercase constants
- Python: snake_case, type hints
- Config: pipe-delimited (`slug|Name|Desc|upstream|method|size|warn|interval|bandwidth|retention_days|retention_max_gib`)
- JSON APIs: camelCase keys
- No `/pub/` prefix — flat `/{slug}/` paths only

## Architecture
| Layer | Component |
|---|---|
| Web | nginx fancyindex at `/{slug}/` |
| Daemon | `src/main.rs` → sync, metrics, health |
| Admin UI | `web/panel.py` FastAPI at `/admin/` |
| Setup | `python/setup.py` with `setup.sh` entry point |
| Runtime paths | `/etc/ezmirror/`, `/var/www/html/`, port 9633 (metrics), 8080 (admin) |

## Rules
- `mirrors.json` is the single source of truth
- Backward compat with `mirrors.conf` format always
- Never commit secrets/keys
- Linear history on main, squash feature branches
