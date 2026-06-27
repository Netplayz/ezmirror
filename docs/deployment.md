# Deployment

## Standard Installation

### Requirements

- **OS:** Debian 12+ or Ubuntu 22.04+ (others may work)
- **Python:** 3.10+
- **Rust:** Only needed at build time (cargo)
- **nginx:** Built with fancyindex module (nginx-extras)
- **Root access:** Setup uses systemd, nginx, and writes to system paths

### Quick Install

```bash
git clone https://github.com/Netplayz/ezmirror.git
cd ezmirror
sudo bash setup.sh
```

The installer will:
1. Prompt for lab name, domain, location
2. Let you select which mirrors to sync
3. Install dependencies (nginx, rsync, etc.)
4. Build the Rust daemon
5. Configure nginx with fancyindex
6. Create systemd services
7. Optionally run initial sync

### Unattended Install

```bash
export EZMIRROR_LAB_NAME="My Open Source Lab"
export EZMIRROR_DOMAIN="mirror.example.com"
export EZMIRROR_LOCATION="Anytown, US"
export EZMIRROR_MIRRORS="debian,ubuntu,arch"  # comma-separated slugs

sudo bash setup.sh --unattended
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `EZMIRROR_LAB_NAME` | `"MyOrg Open Source Lab"` | Site display name |
| `EZMIRROR_DOMAIN` | `"mirror.example.com"` | Site domain |
| `EZMIRROR_LOCATION` | `"Anytown, ST, US"` | Geographic location |
| `EZMIRROR_GH_USER` | `"netplayz"` | GitHub username |
| `EZMIRROR_LOGO_URL` | `""` | Logo image URL |
| `EZMIRROR_MIRRORS` | all mirrors | Comma-separated slugs |
| `EZMIRROR_VOLUME` | `"/var/www/html"` | Mirror data path |
| `EZMIRROR_WEBHOOK` | `""` | Discord/ Slack webhook URL |
| `EZMIRROR_EMAIL` | `""` | Alert email address |
| `EZMIRROR_SKIP_DEPS` | `""` | Set `"1"` to skip apt install |
| `EZMIRROR_SKIP_INITIAL_SYNC` | `""` | Set `"1"` to skip initial sync |

## TLS Setup

ezmirror auto-detects Let's Encrypt certificates:

```bash
sudo certbot --nginx -d mirror.example.com
```

If certificates exist at `/etc/letsencrypt/live/{domain}/`, the nginx config will automatically include TLS. Otherwise, it generates a plain HTTP config.

## Post-Install

```bash
# Check service status
systemctl status ezmirord.service
systemctl status ezmirror-panel.service
systemctl status ezmirror-sync.timer

# View logs
journalctl -u ezmirord -f
tail -f /var/log/ezmirror.log

# Verify nginx
curl -sI http://localhost/debian/
curl -s http://localhost/status.json
```

## Docker Deployment

```bash
docker compose up -d
```

### Docker Compose Configuration

```yaml
services:
  ezmirror:
    build: .
    ports:
      - "80:80"
    environment:
      EZMIRROR_LAB_NAME: "My Docker Mirror"
      EZMIRROR_DOMAIN: "mirror.example.com"
      EZMIRROR_LOCATION: "Docker, US"
      EZMIRROR_MIRRORS: ""
    volumes:
      - ezmirror_data:/var/www/html
```

### Docker Environment Variables

Same as standard install, plus:

| Variable | Default | Description |
|----------|---------|-------------|
| `EZMIRROR_VOLUME` | `"/var/www/html"` | Volume mount path |

### Persistent Data

```bash
# Docker volumes
docker volume ls | grep ezmirror

# Config override (bind mount)
# Uncomment in docker-compose.yml:
#   - ./ezmirror-config:/etc/ezmirror
```

## Updating

```bash
# Standard install
sudo ezmirror-update

# Docker
docker compose pull && docker compose up -d
```

The updater downloads the latest release tarball from GitHub, backs up `/etc/ezmirror/`, runs `setup.py --unattended`, and restores config.

## Backup

```bash
sudo ezmirror-backup
# Creates: /etc/ezmirror/backups/ezmirror_YYYYMMDD_HHMMSS.tar.gz

sudo ezmirror-rollback /etc/ezmirror/backups/ezmirror_*.tar.gz
```
