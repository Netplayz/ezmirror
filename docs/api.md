# Admin Panel API

The admin panel runs at `127.0.0.1:8080` and is proxied by nginx at `/admin/`.

## Authentication

Currently **no authentication** is built in. The panel binds to `127.0.0.1` and relies on nginx for access control. Add basic auth or IP restrictions in the nginx `/admin/` location block as needed.

## Endpoints

### List Mirrors

```
GET /admin/api/mirrors
```

Returns all mirrors with their current sync status.

**Response:**
```json
{
  "mirrors": [
    {
      "slug": "debian",
      "name": "Debian GNU/Linux",
      "desc": "Stable, testing, and unstable package archive",
      "upstream": "rsync://rsync.debian.org/debian/",
      "method": "rsync",
      "size": "~2.0 TiB",
      "interval": "12h",
      "bandwidth": 0,
      "retention_days": 0,
      "retention_max_gib": 0,
      "status": "ok",
      "upstream_health": "healthy",
      "last_sync": 1718000000,
      "last_sync_ago": 3600,
      "exit_code": 0,
      "disk_bytes": 2199023255552
    }
  ],
  "generated": 1718000000
}
```

### Mirror Detail

```
GET /admin/api/mirrors/{slug}
```

**Response:** Same fields as list, plus `upstream_response_time_ms`, `upstream_health_checked`.

### Trigger Sync

```
POST /admin/api/sync/{slug}
POST /admin/api/sync
```

Triggers an immediate sync for a single mirror or all mirrors. Runs `ezmirord --sync` synchronously (may take minutes to hours).

**Response:**
```json
{
  "exit_code": 0,
  "stdout": "...",
  "stderr": ""
}
```

### Logs

```
GET /admin/api/logs?lines=100&slug=debian
```

**Query params:**
| Param | Default | Description |
|-------|---------|-------------|
| `lines` | 100 | Number of log lines to return |
| `slug` | — | Filter by mirror slug |

**Response:**
```json
{
  "lines": ["2024-06-10 12:00:00 [INFO] debian: sync complete"],
  "total": 500,
  "showing": 100
}
```

### Metrics

```
GET /admin/api/metrics
```

Proxies to `http://127.0.0.1:9633/metrics`. Returns raw Prometheus text wrapped in JSON.

**Response:**
```json
{
  "raw": "# HELP ...\n# TYPE ...\nezmirror_sync_duration_seconds{...} 123\n"
}
```

### Config

```
GET /admin/api/config
```

Returns parsed config files from `/etc/ezmirror/`.

**Response:**
```json
{
  "lab": {
    "LAB_NAME": "My Lab",
    "DOMAIN": "mirror.example.com",
    "LOCATION": "Anytown, US"
  },
  "paths": {
    "WEBROOT": "/var/www/html",
    "MIRROR_DIR": "/var/www/html"
  },
  "alert": {
    "ALERT_WEBHOOK": "",
    "ALERT_EMAIL": ""
  },
  "catalog_count": 14
}
```

## Frontend

The admin UI is a single-page application embedded directly in `web/panel.py` as an HTML/JS/CSS string. Features:

- Card grid of mirrors with status badges
- Search/filter by slug, name, or upstream
- Auto-refresh every 30 seconds
- Detail view with raw JSON
- Log viewer showing tail of `/var/log/ezmirror.log`
- Hash-based routing (`#mirror-{slug}`)
