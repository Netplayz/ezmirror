# ezmirror

A self-hostable, production-grade Linux distribution mirror infrastructure with fancyindex templates, a C daemon for metrics/scheduling, and Python/shell management tools.

## Features

- **FancyIndex** — nginx fancyindex module with dark/light themed directory listings
- **C Daemon** (`ezmirord`) — Prometheus metrics endpoint, health checks, sync scheduling
- **Python tools** — interactive and unattended setup, mirror management
- **JSON catalog** — mirror definitions in `mirrors.json`
- **Production-grade** — metrics, health checks, backup, performance tuning, security hardening
- **No `/pub/` prefix** — mirrors served directly at `/{slug}/`

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

## Architecture

```
ezmirror/
  mirrors.json       # Mirror catalog (JSON)
  setup.sh           # Shell entry point
  templates/         # FancyIndex header/footer/CSS
    header.html      #  - prepended to each directory listing
    footer.html      #  - appended with JS for search/sort
    style.css        #  - dark/light theme
  python/
    setup.py         # Interactive/unattended installer
    manage.py        # Add/remove mirrors
  src/
    main.c           # Daemon entry point
    config.c         # mirrors.conf parser
    sync.c           # Sync engine
    status.c         # Status.json reader/writer
    metrics.c        # HTTP server: /metrics, /healthz
  bin/               # Shell wrappers (installed to /usr/local/bin)
```

## Components

| Component | Language | Purpose |
|-----------|----------|---------|
| `ezmirord` | C | Daemon: sync scheduling, Prometheus metrics, health endpoint |
| `setup.py` | Python | Installer: dependencies, nginx config, templates |
| `manage.py` | Python | Interactive mirror selection |
| shell wrappers | Bash | ezmirror-sync, ezmirror-logs, ezmirror-backup, etc. |

## Production Features

### Monitoring
- **Prometheus metrics** at `http://127.0.0.1:9633/metrics`
- **Health endpoint** at `/healthz` (returns 200/503 for load balancers)
- **status.json** at `/status.json` with per-mirror sync state, disk usage, upstream health

### Backup
```bash
sudo ezmirror-backup              # Full config backup to /etc/ezmirror/backups/
```

### Performance
- nginx fancyindex (dynamic listings, no per-directory HTML generation)
- rsync with bandwidth limiting, hardlink support
- Sendfile, TCP_NOPUSH, TCP_NODELAY enabled

### Security
- nginx fancyindex hides dotfiles
- rsyncd host restrictions
- TLS via Let's Encrypt (auto-detected)
- Rate limiting ready

### Reliability
- `flock`-based sync lock prevents overlapping runs
- Per-mirror sync intervals (1h for Arch, 12h for Debian, etc.)
- Disk space pre-check before sync
- Upstream health check before syncing
- Failure alerts via Discord webhook + email

## Development

```bash
# Build C daemon
make build

# Install to system
sudo make install

# Full setup
sudo python3 python/setup.py
```

## License

GPL-3.0
