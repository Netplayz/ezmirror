# Architecture

## Overview

ezmirror is structured as three main services: a Rust daemon for sync/monitoring, a Python admin panel, and nginx for serving mirror content. All three sit behind a single nginx instance.

```
User ──https──▶ nginx ──proxy:9633──▶ Daemon (ezmirord)
                │                       │
                ├──fancyindex──▶ /debian/  ◀── rsync sync ──▶ Upstream
                ├──fancyindex──▶ /ubuntu/  │
                ├────proxy────▶ /admin/ ──▶ Admin Panel (FastAPI :8080)
                └───no-cache──▶ /status.json
                                        ▲
                                   Daemon writes
```

## Layer 1: nginx

- Serves mirror content via fancyindex at `/{slug}/`
- Enforces HTTP Basic Auth at `/admin/` via `/etc/ezmirror/.htpasswd`
- Proxies `/admin/` to the admin panel (`127.0.0.1:8080`)
- Proxies `/healthz` to the daemon (`127.0.0.1:9633/healthz`)
- Serves `status.json` with no-cache headers
- TLS auto-detected: checks for Let's Encrypt certificates

## Layer 2: Rust Daemon (`ezmirord`)

**CLI flags:**

| Flag | Description |
|------|-------------|
| `--daemon` | Fork into background (double-fork daemonization) |
| `--foreground` | Run in foreground with sync loop and metrics server |
| `--sync` | Run sync once and exit |
| `--sync-slug <SLUG>` | Sync a specific mirror only |
| `--dry-run` | Print rsync commands without executing |
| `--status` | Print pipe-delimited status for all mirrors |
| `--port <PORT>` | Metrics HTTP server port (default: 9633) |

**Default mode** (no flags) runs in foreground with sync loop and metrics server.

**Sync loop:**
1. Check if sync is already running (pid file / lock)
2. For each mirror in `mirrors.conf`:
   a. Check if enough time has passed since last sync
   b. Check upstream health (ping/rsync probe)
   c. Check disk space
   d. Execute rsync/rclone with configured bandwidth limit
   e. Update `status.json`
   f. Generate SHA256SUMS
3. Sleep until next scheduled sync

## Layer 3: Admin Panel (`web/panel.py`)

FastAPI server running on `127.0.0.1:8080`.

- Serves single-page admin UI
- REST API for monitoring and managing mirrors
- Creates/deletes mirrors (writes configs, manages nginx locations)
- Reads `status.json` for sync status
- Triggers syncs by spawning `ezmirord --sync`
- Reads config files from `/etc/ezmirror/`

## File System Layout

```
/var/www/html/                 # Web root + mirror data
  {slug}/                      # Mirror content (e.g., debian/, ubuntu/)
  status.json                  # Machine-readable sync status
  .templates/                  # Fancyindex templates
    header.html
    footer.html
    style.css
  index.html                   # Homepage

/etc/ezmirror/                 # Configuration
  mirrors.conf                 # Active mirror list (pipe-delimited)
  lab.conf                     # Lab branding
  paths.conf                   # Path configuration
  alert.conf                   # Alert webhook/email
  .htpasswd                    # Admin panel HTTP auth credentials
  version                      # Installed version

/var/log/ezmirror.log          # Sync + daemon logs
```

## Ports

| Port | Service | Bind | Purpose |
|------|---------|------|---------|
| 80/443 | nginx | 0.0.0.0 | HTTP/HTTPS |
| 9633 | ezmirord | 127.0.0.1 | Metrics + health |
| 8080 | Admin panel | 127.0.0.1 | Admin UI |
