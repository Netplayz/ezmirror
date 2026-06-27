#!/usr/bin/env python3
"""
ezmirror setup — interactive or unattended installation.
Reads mirrors.json for catalog, configures nginx with fancyindex,
installs management scripts, and sets up systemd timer.
"""

import os
import sys
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

EZMIRROR_ROOT = Path(__file__).resolve().parent.parent
MIRRORS_JSON = EZMIRROR_ROOT / "mirrors.json"
TEMPLATES_DIR = EZMIRROR_ROOT / "templates"
SCRIPTS_DIR = EZMIRROR_ROOT / "bin"

CONF_DIR = Path("/etc/ezmirror")
WEBROOT = Path("/var/www/html")
SYNC_BIN = Path("/usr/local/bin/ezmirror-sync")
MANAGE_BIN = Path("/usr/local/bin/ezmirror-manage")
STATUS_BIN = Path("/usr/local/bin/ezmirror-status")
LOGS_BIN = Path("/usr/local/bin/ezmirror-logs")
VERIFY_BIN = Path("/usr/local/bin/ezmirror-verify")
HEALTH_BIN = Path("/usr/local/bin/ezmirror-health")
BACKUP_BIN = Path("/usr/local/bin/ezmirror-backup")
METRICS_BIN = Path("/usr/local/bin/ezmirror-metrics")
DAEMON_BIN = Path("/usr/local/sbin/ezmirord")
PANEL_BIN = Path("/usr/local/bin/ezmirror-panel")
LOGFILE = Path("/var/log/ezmirror.log")

R = "\033[0;31m"
G = "\033[0;32m"
Y = "\033[1;33m"
C = "\033[0;36m"
B = "\033[1m"
N = "\033[0m"


def ok(msg): print(f"  {G}*{N}  {msg}")
def info(msg): print(f"  {C}->{N}  {msg}")
def warn(msg): print(f"  {Y}!{N}  {msg}")
def die(msg): print(f"  {R}x{N}  {msg}", file=sys.stderr); sys.exit(1)


def load_mirrors():
    if not MIRRORS_JSON.exists():
        die(f"Mirrors catalog not found: {MIRRORS_JSON}")
    with open(MIRRORS_JSON) as f:
        return json.load(f)


def run(cmd, check=True, silent=False, cwd=None):
    kwargs = {}
    if silent:
        kwargs["stdout"] = subprocess.DEVNULL
        kwargs["stderr"] = subprocess.DEVNULL
    if cwd:
        kwargs["cwd"] = cwd
    if check:
        subprocess.run(cmd, **kwargs, check=True)
    else:
        subprocess.run(cmd, **kwargs)


def install_deps():
    if os.environ.get("EZMIRROR_SKIP_DEPS"):
        info("Skipping dependencies (EZMIRROR_SKIP_DEPS)")
        return
    info("Installing dependencies...")
    pkgs = ["nginx", "rsync", "jq", "curl", "git", "moreutils", "build-essential",
            "libpcre3-dev", "libssl-dev", "zlib1g-dev", "apache2-utils"]
    run(["apt-get", "update", "-qq"], silent=True)
    for pkg in pkgs:
        run(["apt-get", "install", "-y", "-qq", pkg], silent=True)
    ok("Dependencies installed")

    # Install fancyindex module if not present
    result = subprocess.run(["nginx", "-V"], capture_output=True, text=True)
    if "fancyindex" not in result.stderr:
        info("fancyindex module not found, installing nginx-extras...")
        run(["apt-get", "install", "-y", "-qq", "nginx-extras"], silent=True)
        ok("nginx-extras (fancyindex)")

    # Install Python deps for admin panel
    info("Installing Python packages (fastapi, uvicorn)...")
    run(["pip3", "install", "-q", "fastapi", "uvicorn"], silent=True)
    ok("fastapi + uvicorn")


def install_templates(mirror_dir: Path):
    """Install fancyindex templates to webroot."""
    tmpl_dir = WEBROOT / ".templates"
    tmpl_dir.mkdir(parents=True, exist_ok=True)

    lab_conf = CONF_DIR / "lab.conf"
    lab = {}
    if lab_conf.exists():
        with open(lab_conf) as f:
            for line in f:
                if "=" in line:
                    k, v = line.strip().split("=", 1)
                    lab[k] = v.strip('"')

    replacements = {
        "__LAB_NAME__": lab.get("LAB_NAME", "ezmirror"),
        "__DOMAIN__": lab.get("DOMAIN", "localhost"),
        "__LOCATION__": lab.get("LOCATION", "Unknown"),
    }

    for tmpl_name in ["header.html", "footer.html", "style.css"]:
        src = TEMPLATES_DIR / tmpl_name
        if not src.exists():
            warn(f"Template {tmpl_name} not found, skipping")
            continue
        content = src.read_text()
        for key, val in replacements.items():
            content = content.replace(key, val)
        (tmpl_dir / tmpl_name).write_text(content)
        ok(f".templates/{tmpl_name}")


def generate_homepage(mirrors: list, lab: dict):
    """Generate a static homepage."""
    domain = lab.get("DOMAIN", "localhost")
    lab_name = lab.get("LAB_NAME", "ezmirror")
    location = lab.get("LOCATION", "Unknown")
    gh_user = lab.get("GH_USER", "netplayz")
    logo_url = lab.get("LOGO_URL", "")

    logo_html = f'<img src="{logo_url}" alt="Logo" class="nav-logo-img">' if logo_url else ""
    mirror_rows = []
    for m in mirrors:
        meta = ""
        is_origin = m.get("method") == "original"
        origin_cls = ' origin-row' if is_origin else ''
        origin_badge = '<div class="origin-badge">* origin</div>' if is_origin else ''
        mirror_rows.append(f'''<a class="mirror-row{origin_cls}" href="/{m['slug']}/">
  <div><div class="mirror-name">/{m['slug']}/</div>
  <div class="mirror-desc">{m.get('name','')} - {m.get('description','')}</div>
  {origin_badge}{meta}</div>
  <span class="mirror-arrow">-></span></a>''')

    html = f'''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{lab_name}</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500&family=IBM+Plex+Sans:wght@300;400;500;600&display=swap" rel="stylesheet">
<link rel="stylesheet" href="/.templates/style.css">
<style>
.hero {{ flex:1;display:flex;flex-direction:column;justify-content:center;padding:6rem 2rem 4rem;max-width:760px;margin:0 auto;width:100%; }}
.hero-label {{ font-family:var(--mono);font-size:.72rem;color:var(--muted);letter-spacing:.1em;text-transform:uppercase;margin-bottom:1.5rem; }}
.hero h1 {{ font-weight:300;font-size:clamp(2rem,5vw,3.2rem);line-height:1.15;letter-spacing:-.02em;margin-bottom:1.5rem; }}
.hero h1 strong {{ font-weight:600; }}
.hero p {{ font-size:.95rem;color:var(--muted);line-height:1.75;max-width:520px;margin-bottom:3rem; }}
.mirrors {{ display:flex;flex-direction:column;gap:.75rem;margin-bottom:3rem; }}
.mirror-row {{ display:grid;grid-template-columns:1fr auto;align-items:center;gap:1rem;padding:1rem 1.25rem;background:var(--surface);border:1px solid var(--border);border-radius:6px;text-decoration:none;transition:border-color .15s,background .15s; }}
.mirror-row:hover {{ border-color:var(--dim);filter:brightness(1.05); }}
.mirror-row.origin-row {{ border-left:2px solid var(--accent); }}
.mirror-name {{ font-family:var(--mono);font-size:.85rem;color:var(--text);margin-bottom:.2rem; }}
.mirror-desc {{ font-size:.78rem;color:var(--muted); }}
.origin-badge {{ font-family:var(--mono);font-size:.68rem;color:var(--accent);letter-spacing:.06em;text-transform:uppercase;margin-top:.2rem; }}
.mirror-arrow {{ color:var(--dim);font-size:.85rem;font-family:var(--mono);flex-shrink:0; }}
.mirror-row:hover .mirror-arrow {{ color:var(--text); }}
.stats {{ display:flex;gap:2.5rem;flex-wrap:wrap;padding-top:2rem;border-top:1px solid var(--border); }}
.stat .label {{ font-family:var(--mono);font-size:.68rem;color:var(--muted);letter-spacing:.08em;text-transform:uppercase;margin-bottom:.2rem; }}
.stat .value {{ font-size:.85rem;color:var(--text); }}
</style>
</head>
<body>
<div class="topbar"><div class="topbar-inner">
  <a href="/" class="nav-logo" style="font-family:var(--mono);font-size:.85rem;color:var(--text);text-decoration:none;display:flex;align-items:center;gap:.5rem;">{logo_html}{domain}</a>
  <button onclick="(function(){{var h=document.documentElement,c=h.getAttribute('data-theme')||'auto',n=c==='dark'?'light':'dark';h.setAttribute('data-theme',n);localStorage.setItem('ez-theme',n);}})();" class="theme-btn">O</button>
</div></div>
<div class="hero">
  <p class="hero-label">{lab_name}</p>
  <h1>Public software<br><strong>mirror infrastructure.</strong></h1>
  <p>Free, fast access to open source Linux distributions and software. Hosted in {location.split(",")[0]}.</p>
  <div class="mirrors" id="mirror-list">{"".join(mirror_rows)}</div>
  <div class="stats">
    <div class="stat"><div class="label">Location</div><div class="value">{location}</div></div>
    <div class="stat"><div class="label">Protocol</div><div class="value">rsync / rclone</div></div>
    <div class="stat"><div class="label">Mirrors</div><div class="value">{len(mirrors)}</div></div>
    <div class="stat"><div class="label">Status</div><div class="value" id="status-badge">loading...</div></div>
  </div>
</div>
<footer><span>{lab_name} — powered by <a href="https://github.com/netplayz/ezmirror">ezmirror</a></span>
<span><a href="/status.json">status.json</a></span></footer>
<script>
fetch('/status.json').then(function(r){{return r.json()}}).then(function(d){{
  var sm=d.mirrors||{{}},total=0,ok=0;
  Object.keys(sm).forEach(function(k){{total++;if(sm[k].exit_code===0)ok++;}});
  document.getElementById('status-badge').textContent=ok+'/'+total+' healthy';
}}).catch(function(){{document.getElementById('status-badge').textContent='unknown';}});
</script>
</body>
</html>'''
    (WEBROOT / "index.html").write_text(html)
    ok("index.html")


def generate_nginx_config(mirrors: list, lab: dict, mirror_dir: Path,
                          ssl_cert: str = "", ssl_key: str = "",
                          ssl_opts: str = ""):
    domain = lab.get("DOMAIN", "localhost")
    fancyindex_block = f'''
    fancyindex on;
    fancyindex_header "/.templates/header.html";
    fancyindex_footer "/.templates/footer.html";
    fancyindex_css_href "/.templates/style.css";
    fancyindex_show_path on;
    fancyindex_show_dotfiles off;
    fancyindex_default_sort name;
    fancyindex_name_length 255;
    fancyindex_time_format "%Y-%m-%d %H:%M";
'''

    locations = ""
    for m in mirrors:
        slug = m["slug"]
        locations += f'''
    location /{slug}/ {{
        alias {mirror_dir}/{slug}/;
        {fancyindex_block}
    }}
'''

    common = f'''
    root {WEBROOT};
    index index.html index.htm;
    include /etc/nginx/mime.types;

    location = /status.json {{
        root {WEBROOT};
        add_header Cache-Control 'no-cache, no-store, must-revalidate';
    }}

    location = /healthz {{
        proxy_pass http://127.0.0.1:9633/healthz;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }}

    location /.templates/ {{
        alias {WEBROOT}/.templates/;
    }}

    location /admin/ {{
        auth_basic "ezmirror Admin Panel";
        auth_basic_user_file /etc/ezmirror/.htpasswd;
        proxy_pass http://127.0.0.1:8080/admin/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }}

    {locations}

    location / {{
        root {WEBROOT};
        try_files $uri $uri/ =404;
    }}
'''

    if ssl_cert and ssl_key and ssl_opts:
        config = f'''
server {{
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 301 https://{domain}$request_uri;
}}
server {{
    listen 443 ssl;
    listen [::]:443 ssl ipv6only=on;
    server_name {domain} www.{domain};
    ssl_certificate {ssl_cert};
    ssl_certificate_key {ssl_key};
    include {ssl_opts};
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
    if ($host = www.{domain}) {{ return 301 https://{domain}$request_uri; }}
{common}
}}
'''
    else:
        config = f'''
server {{
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name {domain} www.{domain} _;
{common}
}}
'''

    (Path("/etc/nginx/sites-available/default")).write_text(config)
    ok("nginx config")


def write_mirrors_conf(mirrors: list, path: Path):
    with open(path, "w") as f:
        f.write("# ezmirror - active mirrors\n")
        f.write(f"# Generated by setup.py on {subprocess.check_output(['date','-u','+%Y-%m-%d %H:%M:%S UTC']).decode().strip()}\n")
        f.write("# Format: slug|Name|Description|Upstream|Method|Size|warn|interval|bandwidth|retention_days|retention_max_gib\n")
        f.write("#\n")
        for m in mirrors:
            f.write(f"{m['slug']}|{m.get('name','')}|{m.get('description','')}|"
                    f"{m.get('upstream','')}|{m.get('method','rsync')}|{m.get('size','')}|"
                    f"{m.get('warn','')}|{m.get('interval','6h')}|"
                    f"{m.get('bandwidth',0)}|{m.get('retention_days',0)}|{m.get('retention_max_gib',0)}\n")
    ok(f"{path}")


def write_lab_conf(lab: dict):
    with open(CONF_DIR / "lab.conf", "w") as f:
        f.write("# ezmirror - lab configuration\n")
        for k, v in lab.items():
            f.write(f'{k}="{v}"\n')
    ok("lab.conf")


def write_paths_conf(mirror_dir: Path):
    with open(CONF_DIR / "paths.conf", "w") as f:
        f.write("# ezmirror - path configuration\n")
        f.write(f'WEBROOT="{WEBROOT}"\n')
        f.write(f'MIRROR_DIR="{mirror_dir}"\n')
        f.write(f'ENABLE_TORRENTS="false"\n')
    ok("paths.conf")


def write_alert_conf(webhook: str = "", email: str = ""):
    with open(CONF_DIR / "alert.conf", "w") as f:
        f.write("# ezmirror - alert configuration\n")
        f.write(f'ALERT_WEBHOOK="{webhook}"\n')
        f.write(f'ALERT_EMAIL="{email}"\n')
    os.chmod(CONF_DIR / "alert.conf", 0o600)
    ok("alert.conf")


def build_daemon():
    cargo_toml = EZMIRROR_ROOT / "Cargo.toml"
    if not cargo_toml.exists():
        warn("Cargo.toml not found, skipping Rust build")
        return False
    if not shutil.which("cargo"):
        warn("cargo not found, skipping daemon build")
        return False
    info("Building ezmirord (Rust)...")
    run(["cargo", "build", "--release"], cwd=str(EZMIRROR_ROOT), silent=True)
    shutil.copy2(EZMIRROR_ROOT / "target" / "release" / "ezmirord", DAEMON_BIN)
    DAEMON_BIN.chmod(0o755)
    ok(f"ezmirord ({DAEMON_BIN})")
    return True


def write_version():
    src = EZMIRROR_ROOT / "VERSION"
    if src.exists():
        version = src.read_text().strip()
        (CONF_DIR / "version").write_text(version + "\n")
        ok(f"version {version}")


def install_admin_panel():
    src = EZMIRROR_ROOT / "web" / "panel.py"
    if not src.exists():
        warn("web/panel.py not found, skipping admin panel")
        return False
    shutil.copy2(src, PANEL_BIN)
    PANEL_BIN.chmod(0o755)
    ok(f"ezmirror-panel ({PANEL_BIN})")

    svc = EZMIRROR_ROOT / "web" / "ezmirror-panel.service"
    if svc.exists() and Path("/run/systemd/system").is_dir():
        shutil.copy2(svc, Path("/etc/systemd/system/ezmirror-panel.service"))
        ok("systemd: ezmirror-panel.service")
        subprocess.run(["systemctl", "daemon-reload"], capture_output=True)
        subprocess.run(["systemctl", "enable", "--now", "ezmirror-panel.service"], capture_output=True)
        ok("ezmirror-panel.service enabled")
    return True


def setup_admin_auth(unattended: bool):
    htpasswd = CONF_DIR / ".htpasswd"
    user = os.environ.get("EZMIRROR_ADMIN_USER", "")
    passwd = os.environ.get("EZMIRROR_ADMIN_PASS", "")

    if user and passwd:
        run(["htpasswd", "-cb", str(htpasswd), user, passwd], silent=True)
        ok(f"admin auth: {user}")
        return

    if htpasswd.exists():
        info("admin auth: .htpasswd already exists")
        return

    if unattended:
        info("admin auth: skipped (no EZMIRROR_ADMIN_USER/PASS)")
        return

    print()
    user = input("  Admin username [admin]: ").strip() or "admin"
    import getpass
    while True:
        passwd = getpass.getpass("  Admin password: ")
        if len(passwd) < 8:
            warn("Password must be at least 8 characters")
            continue
        confirm = getpass.getpass("  Confirm password: ")
        if passwd != confirm:
            warn("Passwords do not match")
            continue
        break
    run(["htpasswd", "-cb", str(htpasswd), user, passwd], silent=True)
    ok(f"admin auth: {user}")
    htpasswd.chmod(0o600)


def install_scripts():
    scripts_py = {
        "ezmirror-manage": EZMIRROR_ROOT / "python" / "manage.py",
        "ezmirror-update": EZMIRROR_ROOT / "python" / "update.py",
        "ezmirror-rollback": EZMIRROR_ROOT / "python" / "rollback.py",
    }
    for name, src in scripts_py.items():
        dst = Path("/usr/local/bin") / name
        shutil.copy2(src, dst)
        dst.chmod(0o755)
        ok(f"{dst}")


def install_shell_wrappers():
    """Install shell wrappers for quick CLI access."""
    wrappers = {
        "ezmirror-sync": '''#!/usr/bin/env bash
exec /usr/local/sbin/ezmirord --sync "$@"
''',
        "ezmirror-status": '''#!/usr/bin/env bash
exec /usr/local/sbin/ezmirord --status
''',
        "ezmirror-logs": '''#!/usr/bin/env bash
LOGFILE=/var/log/ezmirror.log
SLUG=""; FOLLOW=false; ERRORS=false
for arg in "$@"; do
    case "$arg" in
        -f|--follow) FOLLOW=true ;;
        --errors) ERRORS=true ;;
        -*) ;;
        *) SLUG="$arg" ;;
    esac
done
if [[ -n "$SLUG" ]]; then
    pattern="$SLUG"; [[ "$ERRORS" == true ]] && pattern="($SLUG).*(WARN|ERROR)"
    if [[ "$FOLLOW" == true ]]; then tail -f "$LOGFILE" | grep --line-buffered -i "$pattern"
    else grep -i "$pattern" "$LOGFILE" | tail -100; fi
elif [[ "$ERRORS" == true ]]; then
    if [[ "$FOLLOW" == true ]]; then tail -f "$LOGFILE" | grep --line-buffered -E "\\[(WARN|ERROR)\\]"
    else grep -E "\\[(WARN|ERROR)\\]" "$LOGFILE" | tail -100; fi
else
    if [[ "$FOLLOW" == true ]]; then tail -f "$LOGFILE"
    else tail -50 "$LOGFILE"; fi
fi
''',
        "ezmirror-verify": '''#!/usr/bin/env bash
exec python3 /usr/local/bin/ezmirror-verify-py "$@"
''',
        "ezmirror-health": '''#!/usr/bin/env bash
exec /usr/local/sbin/ezmirord --status "$@"
''',
        "ezmirror-backup": '''#!/usr/bin/env bash
BACKUP_DIR=/etc/ezmirror/backups
mkdir -p "$BACKUP_DIR"
BACKUP_FILE="$BACKUP_DIR/ezmirror_$(date +%Y%m%d_%H%M%S).tar.gz"
tar -czf "$BACKUP_FILE" /etc/ezmirror/ /usr/local/bin/ezmirror-* /usr/local/sbin/ezmirord /etc/systemd/system/ezmirror-* /etc/logrotate.d/ezmirror /etc/nginx/ezmirror-mirrors.conf 2>/dev/null || true
echo "Backup: $BACKUP_FILE"
''',
        "ezmirror-metrics": '''#!/usr/bin/env bash
curl -s http://127.0.0.1:9633/metrics
''',
    }

    for name, content in wrappers.items():
        dst = Path("/usr/local/bin") / name
        with open(dst, "w") as f:
            f.write(content)
        dst.chmod(0o755)
        ok(f"{dst}")


def setup_systemd(mirrors: list):
    # Find shortest interval
    min_interval_h = 6
    for m in mirrors:
        iv = m.get("interval", "6h")
        h = int(iv[:-1]) if iv[:-1] else 6
        if iv[-1] in ("d", "D"):
            h *= 24
        if h < min_interval_h:
            min_interval_h = h
    if min_interval_h < 1:
        min_interval_h = 1

    # Service
    service = f'''[Unit]
Description=ezmirror Sync
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart={DAEMON_BIN} --sync
StandardOutput=journal
StandardError=journal
User=root
'''
    (Path("/etc/systemd/system/ezmirror-sync.service")).write_text(service)

    # Timer
    timer = f'''[Unit]
Description=ezmirror Sync Timer (every {min_interval_h}h)
[Timer]
OnBootSec=5min
OnUnitActiveSec={min_interval_h}h
Persistent=true
[Install]
WantedBy=timers.target
'''
    (Path("/etc/systemd/system/ezmirror-sync.timer")).write_text(timer)

    # Daemon service (for metrics + continuous scheduling)
    daemon_svc = f'''[Unit]
Description=ezmirord - Mirror Sync Daemon
After=network-online.target
[Service]
ExecStart={DAEMON_BIN} --daemon
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
'''
    (Path("/etc/systemd/system/ezmirord.service")).write_text(daemon_svc)
    ok("systemd units")

    subprocess.run(["systemctl", "daemon-reload"], capture_output=True)
    subprocess.run(["systemctl", "enable", "--now", "ezmirror-sync.timer"], capture_output=True)
    ok("ezmirror-sync.timer enabled")


def cleanup_old_pub():
    """Remove old /pub/ symlink and directory if present."""
    pub_link = WEBROOT / "pub"
    if pub_link.is_symlink():
        pub_link.unlink()
        info("Removed old /pub/ symlink")
    elif pub_link.is_dir():
        shutil.rmtree(pub_link)
        info("Removed old /pub/ directory")


def main():
    if os.geteuid() != 0:
        die("Run with sudo: sudo python3 setup.py")

    unattended = "--unattended" in sys.argv

    print(f"\n{B}ezmirror Setup{N}")
    print(f"  Python-based installer with fancyindex support\n")

    # 0. Load catalog
    mirrors = load_mirrors()
    info(f"Loaded {len(mirrors)} mirrors from mirrors.json")

    # 1. Branding
    lab = {}
    lab["LAB_NAME"] = os.environ.get("EZMIRROR_LAB_NAME", "MyOrg Open Source Lab")
    lab["DOMAIN"] = os.environ.get("EZMIRROR_DOMAIN", "mirror.example.com")
    lab["LOCATION"] = os.environ.get("EZMIRROR_LOCATION", "Anytown, ST, US")
    lab["GH_USER"] = os.environ.get("EZMIRROR_GH_USER", "netplayz")
    lab["LOGO_URL"] = os.environ.get("EZMIRROR_LOGO_URL", "")

    if not unattended:
        for key in ["LAB_NAME", "DOMAIN", "LOCATION", "GH_USER"]:
            default = lab[key]
            val = input(f"  {key.replace('_',' ').title()} [{default}]: ").strip()
            if val:
                lab[key] = val

    write_lab_conf(lab)

    # 2. Mirror selection
    selected = []
    if unattended and "EZMIRROR_MIRRORS" not in os.environ:
        selected = list(mirrors)
        info(f"Unattended: selecting all {len(selected)} mirrors")
    elif "EZMIRROR_MIRRORS" in os.environ:
        slugs = [s.strip() for s in os.environ["EZMIRROR_MIRRORS"].split(",")]
        selected = [m for m in mirrors if m["slug"] in slugs]
        info(f"Mirrors (env): {[m['slug'] for m in selected]}")
    else:
        # Interactive selection
        print(f"\n{B}  Mirror Selection{N}")
        for i, m in enumerate(mirrors, 1):
            size = m.get("size", "")
            interval = m.get("interval", "6h")
            warn_flag = f" {Y}*{N}" if m.get("warn") == "large" else ""
            print(f"  [{i:2d}] {m['slug']:14s} {m['name']:30s} {size:10s} {interval}{warn_flag}")
        print(f"  [ a] Select all")
        print(f"  [ n] Select none")
        print(f"  [ d] Done")
        choice = input(f"\n  Enter numbers (space-separated), a, n, or d: ").strip()
        if choice.lower() == "a":
            selected = list(mirrors)
        elif choice.lower() != "n" and choice.lower() != "d":
            indices = [int(x) for x in choice.split() if x.isdigit()]
            selected = [mirrors[i-1] for i in indices if 1 <= i <= len(mirrors)]

    if not selected:
        die("No mirrors selected. Re-run to select mirrors.")

    # 3. Volume
    mirror_dir = Path(os.environ.get("EZMIRROR_VOLUME", "/var/www/html"))
    if not unattended:
        vol = input(f"  Mirror storage path [{mirror_dir}]: ").strip()
        if vol:
            mirror_dir = Path(vol)

    mirror_dir.mkdir(parents=True, exist_ok=True)
    info(f"Mirror data: {mirror_dir}")

    # 4. Install dependencies
    install_deps()

    CONF_DIR.mkdir(parents=True, exist_ok=True)

    # 5. Write configs
    write_mirrors_conf(selected, CONF_DIR / "mirrors.conf")
    write_paths_conf(mirror_dir)

    # 6. Alerts
    webhook = os.environ.get("EZMIRROR_WEBHOOK", "")
    email = os.environ.get("EZMIRROR_EMAIL", "")
    if webhook or email:
        write_alert_conf(webhook, email)

    # 7. Version tracking
    write_version()

    # 8. Generate status.json
    status_file = WEBROOT / "status.json"
    status_file.write_text('{"generated":0,"mirrors":{}}')
    ok("status.json")

    # 8. Install fancyindex templates
    install_templates(mirror_dir)

    # 9. Generate homepage
    generate_homepage(selected, lab)

    # 10. Create mirror directories
    for m in selected:
        (mirror_dir / m["slug"]).mkdir(parents=True, exist_ok=True)
        ok(f"/{m['slug']}/")

    # 11. Generate nginx config
    ssl_cert = f"/etc/letsencrypt/live/{lab['DOMAIN']}/fullchain.pem"
    ssl_key = f"/etc/letsencrypt/live/{lab['DOMAIN']}/privkey.pem"
    ssl_opts = "/etc/letsencrypt/options-ssl-nginx.conf"

    if Path(ssl_cert).exists() and Path(ssl_key).exists() and Path(ssl_opts).exists():
        generate_nginx_config(selected, lab, mirror_dir, ssl_cert, ssl_key, ssl_opts)
    else:
        generate_nginx_config(selected, lab, mirror_dir)

    # Test nginx config
    result = subprocess.run(["nginx", "-t"], capture_output=True, text=True)
    if result.returncode != 0:
        warn(f"nginx config error: {result.stderr}")

    # Reload nginx (only if systemd is active)
    if Path("/run/systemd/system").is_dir():
        subprocess.run(["systemctl", "reload", "nginx"], capture_output=True)
        ok("nginx reloaded")
    else:
        ok("nginx config written (no systemd)")

    # 12. Build and install daemon
    built = build_daemon()
    if built:
        install_scripts()
        install_shell_wrappers()
        # Only set up systemd if available
        if Path("/run/systemd/system").is_dir():
            setup_systemd(selected)
            subprocess.run(["systemctl", "enable", "--now", "ezmirord.service"], capture_output=True)
            ok("ezmirord.service started")

    # 13. Install admin panel
    if built:
        install_admin_panel()
        setup_admin_auth(unattended)

    # 14. Logrotate
    logrotate = f"""/var/log/ezmirror.log {{
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    dateext
    dateformat -%Y%m%d
}}
"""
    (Path("/etc/logrotate.d/ezmirror")).write_text(logrotate)
    ok("logrotate")

    # 15. Cleanup old pub
    cleanup_old_pub()

    # 16. Initial sync?
    if unattended and os.environ.get("EZMIRROR_SKIP_INITIAL_SYNC"):
        warn("Skipped initial sync (EZMIRROR_SKIP_INITIAL_SYNC)")
    elif unattended or input(f"\n  Run initial sync now? [y/N]: ").lower() == "y":
        info("Syncing...")
        subprocess.run([str(DAEMON_BIN), "--sync"], capture_output=True)
        ok("Initial sync complete")
    else:
        warn("Skipped initial sync")

    # 17. Summary
    print(f"\n{G}{B}ezmirror setup complete.{N}")
    print(f"\n  Site:           https://{lab['DOMAIN']}")
    print(f"  Admin Panel:    https://{lab['DOMAIN']}/admin/")
    print(f"  Status JSON:    https://{lab['DOMAIN']}/status.json")
    print(f"  Metrics:        http://127.0.0.1:9633/metrics")
    print(f"  Health:         http://127.0.0.1:9633/healthz")
    print(f"  Data volume:    {mirror_dir}")
    print(f"\n  Sync all:       sudo ezmirror-sync")
    print(f"  Status:         ezmirror-status")
    print(f"  Logs:           ezmirror-logs [slug] [-f]")
    print(f"  Verify:         ezmirror-verify [slug]")
    print(f"  Health:         ezmirror-health")
    print(f"  Backup:         sudo ezmirror-backup")
    print(f"  Manage:         sudo ezmirror-manage")
    print(f"  Update:         sudo ezmirror-update")
    print(f"  Rollback:       sudo ezmirror-rollback /etc/ezmirror/backups/*.tar.gz")
    print()


if __name__ == "__main__":
    main()
