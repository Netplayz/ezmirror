# Changelog

## v0.6.0 (2026-06-26)
- Complete rewrite from monolithic bash script to modular architecture
- C daemon (ezmirord) for sync scheduling, metrics, and health checks
- Python-based setup (`python/setup.py`) and management (`python/manage.py`)
- JSON mirror catalog (`mirrors.json`) — no more hardcoded pipe-delimited entries
- nginx fancyindex templates with dark/light theme, search, and column sorting
- Prometheus metrics endpoint (`:9633/metrics`)
- Health check endpoint (`:9633/healthz`)
- Backup/restore (`ezmirror-update`, `ezmirror-rollback`)
- Self-update from GitHub releases (`ezmirror-update`)
- Flat path structure — mirrors served directly at `/{slug}/`
- Interactive TUI for mirror selection
- systemd timer and daemon service units
