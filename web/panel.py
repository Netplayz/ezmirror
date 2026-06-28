#!/usr/bin/env python3
"""
ezmirror admin panel — FastAPI backend.
Serves admin UI and REST API for managing mirrors.
"""

import os
import sys
import json
import asyncio
import subprocess
from pathlib import Path
from datetime import datetime
from typing import Optional

try:
    from fastapi import FastAPI, HTTPException
    from fastapi.responses import HTMLResponse, JSONResponse
    from fastapi.staticfiles import StaticFiles
    from pydantic import BaseModel
    import uvicorn
except ImportError:
    print("Required: pip install fastapi uvicorn")
    sys.exit(1)

app = FastAPI(title="ezmirror Admin Panel", version="0.6.0")

STATUS_FILE = Path("/var/www/html/status.json")
MIRRORS_CONF = Path("/etc/ezmirror/mirrors.conf")
MIRRORS_JSON = Path("/opt/ezmirror/mirrors.json")
CONF_DIR = Path("/etc/ezmirror")
DAEMON_BIN = "/usr/local/sbin/ezmirord"
LOG_FILE = Path("/var/log/ezmirror.log")
NGINX_CONF = "/etc/nginx/sites-available/default"
MIRROR_DIR = Path("/var/www/html")


class MirrorCreate(BaseModel):
    slug: str
    name: str = ""
    description: str = ""
    upstream: str = ""
    method: str = "rsync"
    size: str = ""
    warn: str = ""
    interval: str = "6h"
    bandwidth: int = 0
    retention_days: int = 0
    retention_max_gib: int = 0


def read_mirrors_conf() -> list[dict]:
    mirrors = []
    if not MIRRORS_CONF.exists():
        return mirrors
    with open(MIRRORS_CONF) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split("|")
            m = {
                "slug": parts[0] if len(parts) > 0 else "",
                "name": parts[1] if len(parts) > 1 else "",
                "desc": parts[2] if len(parts) > 2 else "",
                "upstream": parts[3] if len(parts) > 3 else "",
                "method": parts[4] if len(parts) > 4 else "rsync",
                "size": parts[5] if len(parts) > 5 else "",
                "interval": parts[7] if len(parts) > 7 else "6h",
                "bandwidth": int(parts[8]) if len(parts) > 8 and parts[8] else 0,
                "retention_days": int(parts[9]) if len(parts) > 9 and parts[9] else 0,
                "retention_max_gib": int(parts[10]) if len(parts) > 10 and parts[10] else 0,
            }
            mirrors.append(m)
    return mirrors


def read_status_json() -> dict:
    if not STATUS_FILE.exists():
        return {"generated": 0, "mirrors": {}}
    try:
        with open(STATUS_FILE) as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return {"generated": 0, "mirrors": {}}


def read_config_file(name: str) -> dict:
    path = CONF_DIR / name
    if not path.exists():
        return {}
    config = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                config[k.strip()] = v.strip().strip('"')
    return config


def run_sync(slug: Optional[str] = None) -> dict:
    cmd = [DAEMON_BIN, "--sync"]
    if slug:
        cmd.extend(["--sync-slug", slug])
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=3600)
        return {"exit_code": result.returncode, "stdout": result.stdout, "stderr": result.stderr}
    except subprocess.TimeoutExpired:
        return {"exit_code": -1, "stdout": "", "stderr": "Sync timed out"}
    except FileNotFoundError:
        return {"exit_code": -1, "stdout": "", "stderr": "ezmirord not found"}


def mirror_to_conf_line(m: dict) -> str:
    return (f"{m['slug']}|{m.get('name','')}|{m.get('description','')}|"
            f"{m.get('upstream','')}|{m.get('method','rsync')}|{m.get('size','')}|"
            f"{m.get('warn','')}|{m.get('interval','6h')}|"
            f"{m.get('bandwidth',0)}|{m.get('retention_days',0)}|{m.get('retention_max_gib',0)}\n")


def write_mirrors_json(mirrors: list):
    with open(MIRRORS_JSON, "w") as f:
        json.dump(mirrors, f, indent=2)
        f.write("\n")


def add_mirror_to_conf(m: dict):
    with open(MIRRORS_CONF, "a") as f:
        f.write(mirror_to_conf_line(m))


def remove_mirror_from_conf(slug: str):
    if not MIRRORS_CONF.exists():
        return
    lines = MIRRORS_CONF.read_text().splitlines(keepends=True)
    with open(MIRRORS_CONF, "w") as f:
        for line in lines:
            if not line.startswith(slug + "|"):
                f.write(line)


def reload_nginx() -> dict:
    result = subprocess.run(["nginx", "-t"], capture_output=True, text=True)
    if result.returncode != 0:
        return {"ok": False, "error": result.stderr.strip()}
    subprocess.run(["nginx", "-s", "reload"], capture_output=True)
    return {"ok": True, "error": ""}


def add_nginx_location(slug: str):
    fancyindex_block = '''    fancyindex on;
    fancyindex_header "/.templates/header.html";
    fancyindex_footer "/.templates/footer.html";
    fancyindex_css_href "/.templates/style.css";
    fancyindex_show_path on;
    fancyindex_show_dotfiles off;
    fancyindex_default_sort name;
    fancyindex_name_length 255;
    fancyindex_time_format "%Y-%m-%d %H:%M";
'''
    new_location = f'''
    location /{slug}/ {{
        alias {MIRROR_DIR}/{slug}/;
{fancyindex_block}    }}
'''
    if not Path(NGINX_CONF).exists():
        return {"ok": False, "error": "nginx config not found"}
    content = Path(NGINX_CONF).read_text()
    marker = "\n    location / {"
    idx = content.find(marker)
    if idx == -1:
        return {"ok": False, "error": "could not find location / block in nginx config"}
    content = content[:idx] + new_location + content[idx:]
    Path(NGINX_CONF).write_text(content)
    return {"ok": True, "error": ""}


def remove_nginx_location(slug: str):
    if not Path(NGINX_CONF).exists():
        return {"ok": False, "error": "nginx config not found"}
    content = Path(NGINX_CONF).read_text()
    start = content.find(f"\n    location /{slug}/ {{")
    if start == -1:
        return {"ok": False, "error": "location block not found"}
    end = content.find("\n    }", start)
    if end == -1:
        return {"ok": False, "error": "could not find end of location block"}
    content = content[:start] + content[end+6:]
    Path(NGINX_CONF).write_text(content)
    return {"ok": True, "error": ""}


# --- API Routes ---

@app.get("/admin/api/mirrors")
def api_mirrors():
    mirrors = read_mirrors_conf()
    status = read_status_json()
    now = datetime.now().timestamp()

    result = []
    for m in mirrors:
        slug = m["slug"]
        st = status.get("mirrors", {}).get(slug, {})
        last_sync = st.get("last_sync", 0)
        result.append({
            **m,
            "status": st.get("status", "unknown"),
            "upstream_health": st.get("upstream_health", "unknown"),
            "last_sync": last_sync,
            "last_sync_ago": int(now - last_sync) if last_sync else None,
            "exit_code": st.get("exit_code", -1),
            "disk_bytes": st.get("disk_bytes", 0),
        })

    return {"mirrors": result, "generated": status.get("generated", 0)}


@app.get("/admin/api/mirrors/{slug}")
def api_mirror_detail(slug: str):
    mirrors = read_mirrors_conf()
    m = next((m for m in mirrors if m["slug"] == slug), None)
    if not m:
        raise HTTPException(404, "Mirror not found")

    status = read_status_json()
    st = status.get("mirrors", {}).get(slug, {})
    now = datetime.now().timestamp()
    last_sync = st.get("last_sync", 0)

    return {
        **m,
        "status": st.get("status", "unknown"),
        "upstream_health": st.get("upstream_health", "unknown"),
        "last_sync": last_sync,
        "last_sync_ago": int(now - last_sync) if last_sync else None,
        "exit_code": st.get("exit_code", -1),
        "disk_bytes": st.get("disk_bytes", 0),
        "upstream_response_time_ms": st.get("upstream_response_time_ms", 0),
        "upstream_health_checked": st.get("upstream_health_checked", 0),
    }


@app.post("/admin/api/mirrors")
def api_create_mirror(m: MirrorCreate):
    slug = m.slug.strip().lower().replace(" ", "-")
    if not slug:
        raise HTTPException(400, "slug is required")
    mirrors = read_mirrors_conf()
    if any(x["slug"] == slug for x in mirrors):
        raise HTTPException(409, f"Mirror '{slug}' already exists")

    d = m.model_dump()
    d["slug"] = slug
    d.setdefault("method", "rsync")
    d.setdefault("interval", "6h")

    mirrors.append(d)
    write_mirrors_json(mirrors)
    add_mirror_to_conf(d)
    (MIRROR_DIR / slug).mkdir(parents=True, exist_ok=True)
    add_nginx_location(slug)
    rl = reload_nginx()

    return {"ok": True, "slug": slug, "reload": rl, "mirror": d}


@app.delete("/admin/api/mirrors/{slug}")
def api_delete_mirror(slug: str):
    mirrors = read_mirrors_conf()
    if not any(m["slug"] == slug for m in mirrors):
        raise HTTPException(404, "Mirror not found")

    mirrors = [m for m in mirrors if m["slug"] != slug]
    write_mirrors_json(mirrors)
    remove_mirror_from_conf(slug)
    remove_nginx_location(slug)
    rl = reload_nginx()

    return {"ok": True, "slug": slug, "reload": rl}


@app.post("/admin/api/sync/{slug}")
def api_sync_slug(slug: str):
    mirrors = read_mirrors_conf()
    if not any(m["slug"] == slug for m in mirrors):
        raise HTTPException(404, "Mirror not found")
    result = run_sync(slug)
    return result


@app.post("/admin/api/sync")
def api_sync_all():
    result = run_sync(None)
    return result


@app.get("/admin/api/logs")
def api_logs(lines: int = 100, slug: Optional[str] = None):
    if not LOG_FILE.exists():
        return {"lines": []}

    try:
        with open(LOG_FILE) as f:
            all_lines = f.readlines()
    except OSError:
        return {"lines": []}

    # Filter by slug if specified
    if slug:
        all_lines = [l for l in all_lines if slug in l]

    # Return last N lines
    tail = all_lines[-lines:]
    return {"lines": tail, "total": len(all_lines), "showing": len(tail)}


@app.get("/admin/api/metrics")
def api_metrics():
    try:
        result = subprocess.run(
            ["curl", "-sf", "http://127.0.0.1:9633/metrics"],
            capture_output=True, text=True, timeout=5
        )
        return JSONResponse(
            content={"raw": result.stdout},
            headers={"Content-Type": "application/json"}
        )
    except (subprocess.SubprocessError, FileNotFoundError):
        return {"raw": ""}


@app.get("/admin/api/config")
def api_config():
    lab = read_config_file("lab.conf")
    paths = read_config_file("paths.conf")
    alert = read_config_file("alert.conf")

    # Read mirrors.json catalog
    catalog = []
    if MIRRORS_JSON.exists():
        try:
            with open(MIRRORS_JSON) as f:
                catalog = json.load(f)
        except (json.JSONDecodeError, OSError):
            pass

    return {
        "lab": lab,
        "paths": paths,
        "alert": alert,
        "catalog_count": len(catalog),
    }


# --- Serve admin UI ---

ADMIN_HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ezmirror Admin</title>
<style>
:root{--bg:#0f1117;--surface:#1a1d27;--border:#2a2d3a;--text:#e1e4ec;--muted:#8b8fa3;--accent:#4f8cff;--green:#3fb950;--red:#f85149;--yellow:#d29922;--font:'Inter',-apple-system,sans-serif;--mono:'JetBrains Mono','Fira Code',monospace}
*{margin:0;padding:0;box-sizing:border-box}
body{background:var(--bg);color:var(--text);font-family:var(--font);font-size:14px;line-height:1.5}
.topbar{background:var(--surface);border-bottom:1px solid var(--border);padding:0 24px;height:48px;display:flex;align-items:center;justify-content:space-between}
.topbar h1{font-size:15px;font-weight:600;letter-spacing:-.01em}
.topbar h1 span{color:var(--muted);font-weight:400}
.topbar .status-badge{font-family:var(--mono);font-size:12px;padding:4px 10px;border-radius:4px}
.status-badge.ok{background:rgba(63,185,80,.15);color:var(--green)}
.status-badge.degraded{background:rgba(210,153,34,.15);color:var(--yellow)}
.status-badge.error{background:rgba(248,81,73,.15);color:var(--red)}
.container{max-width:1200px;margin:0 auto;padding:24px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:12px}
.card{background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:16px;transition:border-color .15s}
.card:hover{border-color:var(--accent)}
.card-header{display:flex;justify-content:space-between;align-items:flex-start;margin-bottom:8px}
.card-title{font-size:15px;font-weight:600}
.card-subtitle{font-size:12px;color:var(--muted);margin-top:2px}
.card-stats{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin:12px 0}
.stat{font-size:12px}
.stat-label{color:var(--muted);font-size:11px}
.stat-value{font-family:var(--mono);font-size:13px}
.card-actions{display:flex;gap:6px;margin-top:12px;padding-top:12px;border-top:1px solid var(--border)}
.btn{font-family:var(--font);font-size:12px;padding:5px 12px;border-radius:4px;border:1px solid var(--border);background:var(--surface);color:var(--text);cursor:pointer;transition:all .15s}
.btn:hover{background:var(--border)}
.btn-primary{background:var(--accent);color:#fff;border-color:var(--accent)}
.btn-primary:hover{filter:brightness(1.1)}
.btn-danger{background:var(--red);color:#fff;border-color:var(--red)}
.btn-sm{font-size:11px;padding:3px 8px}
.tag{font-family:var(--mono);font-size:11px;padding:2px 6px;border-radius:3px}
.tag-ok{background:rgba(63,185,80,.15);color:var(--green)}
.tag-error{background:rgba(248,81,73,.15);color:var(--red)}
.tag-warn{background:rgba(210,153,34,.15);color:var(--yellow)}
.tag-idle{background:rgba(79,140,255,.15);color:var(--accent)}
.section{margin-bottom:24px}
.section h2{font-size:13px;font-weight:600;color:var(--muted);text-transform:uppercase;letter-spacing:.08em;margin-bottom:12px}
.log-viewer{background:var(--bg);border:1px solid var(--border);border-radius:6px;padding:12px;font-family:var(--mono);font-size:12px;max-height:400px;overflow-y:auto;white-space:pre-wrap;line-height:1.6}
.log-viewer .warn{color:var(--yellow)}
.log-viewer .error{color:var(--red)}
.log-viewer .info{color:var(--accent)}
.loading{text-align:center;padding:40px;color:var(--muted)}
.refresh-bar{display:flex;justify-content:space-between;align-items:center;margin-bottom:16px;gap:12px}
.search-box{background:var(--bg);border:1px solid var(--border);border-radius:4px;padding:6px 10px;color:var(--text);font-family:var(--mono);font-size:13px;width:200px}
.search-box:focus{outline:none;border-color:var(--accent)}
.detail-grid{display:grid;grid-template-columns:300px 1fr;gap:24px}
.detail-sidebar .info-row{display:flex;justify-content:space-between;padding:6px 0;border-bottom:1px solid var(--border);font-size:13px}
.detail-sidebar .info-label{color:var(--muted)}
pre.raw-json{background:var(--bg);border:1px solid var(--border);border-radius:6px;padding:12px;font-size:12px;overflow:auto;max-height:400px}
.hidden{display:none}
@media(max-width:768px){.detail-grid{grid-template-columns:1fr}}
</style>
</head>
<body>
<div class="topbar">
  <h1>ezmirror <span>Admin Panel</span></h1>
  <div>
    <span class="status-badge" id="top-status">loading...</span>
  </div>
</div>
<div class="container">
  <div class="refresh-bar">
    <div>
      <input class="search-box" id="search" placeholder="Search mirrors..." oninput="render()">
    </div>
    <div style="display:flex;gap:6px">
      <span style="font-size:12px;color:var(--muted)" id="last-refresh"></span>
      <button class="btn" onclick="refresh()">Refresh</button>
      <button class="btn btn-primary" onclick="showCreate()">+ Mirror</button>
      <button class="btn btn-primary btn-sm" onclick="syncAll()">Sync All</button>
    </div>
  </div>

  <div id="app">
    <div class="loading">Loading mirrors...</div>
  </div>
</div>

<div id="create-modal" class="modal hidden">
  <div class="modal-backdrop" onclick="hideCreate()"></div>
  <div class="modal-content">
    <div class="modal-header">
      <h2>Create Mirror</h2>
      <button class="btn" onclick="hideCreate()">&times;</button>
    </div>
    <div class="modal-body" id="create-form">
      <div class="form-row">
        <label>Slug</label>
        <input class="form-input" id="f-slug" placeholder="debian" oninput="document.getElementById('f-slug-display').textContent = '/' + this.value.toLowerCase().replace(/ /g,'-') + '/'">
        <span class="form-hint" id="f-slug-display">/debian/</span>
      </div>
      <div class="form-row">
        <label>Name</label>
        <input class="form-input" id="f-name" placeholder="Debian GNU/Linux">
      </div>
      <div class="form-row">
        <label>Description</label>
        <input class="form-input" id="f-desc" placeholder="Stable, testing, and unstable">
      </div>
      <div class="form-row">
        <label>Upstream</label>
        <input class="form-input" id="f-upstream" placeholder="rsync://rsync.debian.org/debian/">
      </div>
      <div class="form-row">
        <label>Method</label>
        <select class="form-input" id="f-method"><option value="rsync">rsync</option><option value="rclone">rclone</option></select>
      </div>
      <div class="form-row">
        <label>Interval</label>
        <input class="form-input" id="f-interval" placeholder="6h" value="6h">
      </div>
      <div class="form-row">
        <label>Size</label>
        <input class="form-input" id="f-size" placeholder="~2.0 TiB">
      </div>
      <div class="form-row">
        <label>Bandwidth (KB/s)</label>
        <input class="form-input" id="f-bandwidth" type="number" placeholder="0" value="0">
      </div>
      <div class="form-row">
        <label>Retention Days</label>
        <input class="form-input" id="f-retention-days" type="number" placeholder="0" value="0">
      </div>
      <div class="form-row">
        <label>Max GiB</label>
        <input class="form-input" id="f-retention-gib" type="number" placeholder="0" value="0">
      </div>
    </div>
    <div class="modal-footer">
      <span id="create-error" style="color:var(--red);font-size:12px"></span>
      <button class="btn" onclick="hideCreate()">Cancel</button>
      <button class="btn btn-primary" id="create-btn" onclick="createMirror()">Create</button>
    </div>
  </div>
</div>

<style>
.modal{position:fixed;top:0;left:0;width:100%;height:100%;display:flex;align-items:center;justify-content:center;z-index:1000}
.modal.hidden{display:none}
.modal-backdrop{position:absolute;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,.6)}
.modal-content{position:relative;background:var(--surface);border:1px solid var(--border);border-radius:8px;width:480px;max-height:80vh;overflow-y:auto}
.modal-header{display:flex;justify-content:space-between;align-items:center;padding:16px 20px;border-bottom:1px solid var(--border)}
.modal-header h2{font-size:15px;font-weight:600}
.modal-body{padding:16px 20px}
.modal-footer{display:flex;justify-content:flex-end;gap:8px;padding:12px 20px;border-top:1px solid var(--border)}
.form-row{margin-bottom:12px}
.form-row label{display:block;font-size:12px;color:var(--muted);margin-bottom:4px;text-transform:uppercase;letter-spacing:.05em}
.form-input{width:100%;background:var(--bg);border:1px solid var(--border);border-radius:4px;padding:7px 10px;color:var(--text);font-family:var(--mono);font-size:13px}
.form-input:focus{outline:none;border-color:var(--accent)}
.form-input[type=number]{width:120px}
.form-hint{font-family:var(--mono);font-size:12px;color:var(--muted);margin-top:2px;display:block}
select.form-input{appearance:none;cursor:pointer}
</style>

<script>
let data = { mirrors: [], generated: 0 };
let logs = [];
let autoRefresh = null;

async function refresh() {
  document.getElementById('last-refresh').textContent = 'refreshing...';
  try {
    const [mRes, lRes] = await Promise.all([
      fetch('/admin/api/mirrors'),
      fetch('/admin/api/logs?lines=50')
    ]);
    data = await mRes.json();
    logs = await lRes.json();
    render();
    updateTopbar();
    document.getElementById('last-refresh').textContent = new Date().toLocaleTimeString();
  } catch(e) {
    document.getElementById('app').innerHTML = '<div class="loading" style="color:var(--red)">Failed to load: ' + e.message + '</div>';
  }
}

function updateTopbar() {
  const badge = document.getElementById('top-status');
  const all = data.mirrors;
  const errors = all.filter(m => m.exit_code !== 0 && m.exit_code !== -1);
  const syncing = all.filter(m => m.status === 'syncing');
  if (errors.length > 0) {
    badge.className = 'status-badge error';
    badge.textContent = errors.length + '/' + all.length + ' errors';
  } else if (syncing.length > 0) {
    badge.className = 'status-badge degraded';
    badge.textContent = syncing.length + ' syncing';
  } else {
    badge.className = 'status-badge ok';
    badge.textContent = all.length + ' mirrors ok';
  }
}

function ago(seconds) {
  if (seconds === null || seconds === undefined) return 'never';
  if (seconds < 60) return 'just now';
  if (seconds < 3600) return Math.floor(seconds/60) + 'm ago';
  if (seconds < 86400) return Math.floor(seconds/3600) + 'h ago';
  return Math.floor(seconds/86400) + 'd ago';
}

function formatBytes(bytes) {
  if (!bytes) return '0 B';
  const units = ['B','KB','MB','GB','TB'];
  let i = 0;
  let val = bytes;
  while (val >= 1024 && i < units.length-1) { val /= 1024; i++; }
  return val.toFixed(i > 0 ? 1 : 0) + ' ' + units[i];
}

function statusTag(st) {
  if (st === 'ok' || st === 'healthy') return '<span class="tag tag-ok">ok</span>';
  if (st === 'error' || st === 'fail') return '<span class="tag tag-error">error</span>';
  if (st === 'syncing') return '<span class="tag tag-warn">syncing</span>';
  return '<span class="tag tag-idle">' + st + '</span>';
}

async function syncOne(slug) {
  const btn = document.querySelector('#sync-' + slug);
  if (btn) { btn.disabled = true; btn.textContent = 'syncing...'; }
  try {
    await fetch('/admin/api/sync/' + slug, { method: 'POST' });
    setTimeout(refresh, 2000);
  } catch(e) {
    alert('Sync failed: ' + e.message);
    if (btn) { btn.disabled = false; btn.textContent = 'Sync'; }
  }
}

async function syncAll() {
  if (!confirm('Sync all mirrors? This may take a long time.')) return;
  const btn = document.querySelector('#sync-all');
  if (btn) { btn.disabled = true; btn.textContent = 'syncing all...'; }
  try {
    await fetch('/admin/api/sync', { method: 'POST' });
    setTimeout(refresh, 3000);
  } catch(e) {
    alert('Sync failed: ' + e.message);
    if (btn) { btn.disabled = false; btn.textContent = 'Sync All'; }
  }
}

function render() {
  const app = document.getElementById('app');
  const q = document.getElementById('search').value.toLowerCase();
  const filtered = q ? data.mirrors.filter(m =>
    m.slug.toLowerCase().includes(q) ||
    m.name.toLowerCase().includes(q) ||
    m.upstream.toLowerCase().includes(q)
  ) : data.mirrors;

  let html = '<div class="grid" id="mirror-grid">';
  for (const m of filtered) {
    const disk = formatBytes(m.disk_bytes);
    html += '<div class="card">' +
      '<div class="card-header">' +
        '<div>' +
          '<div class="card-title">' + m.slug + '</div>' +
          '<div class="card-subtitle">' + m.name + ' — ' + m.method + '</div>' +
        '</div>' +
        '<div>' + statusTag(m.status) + '</div>' +
      '</div>' +
      '<div class="card-stats">' +
        '<div class="stat"><div class="stat-label">Disk</div><div class="stat-value">' + disk + '</div></div>' +
        '<div class="stat"><div class="stat-label">Upstream</div><div class="stat-value">' + statusTag(m.upstream_health) + '</div></div>' +
        '<div class="stat"><div class="stat-label">Last Sync</div><div class="stat-value">' + ago(m.last_sync_ago) + '</div></div>' +
        '<div class="stat"><div class="stat-label">Interval</div><div class="stat-value">' + m.interval + '</div></div>' +
      '</div>' +
      '<div class="card-actions">' +
        '<button class="btn btn-sm btn-primary" id="sync-' + m.slug + '" onclick="syncOne(\'' + m.slug + '\')">Sync</button>' +
        '<button class="btn btn-sm" onclick="showDetail(\'' + m.slug + '\')">Details</button>' +
      '</div>' +
    '</div>';
  }
  html += '</div>';

  // Logs section
  html += '<div class="section" style="margin-top:24px">' +
    '<h2>Recent Logs</h2>' +
    '<div class="log-viewer">';
  if (logs.lines && logs.lines.length) {
    for (const line of logs.lines) {
      const cls = line.includes('[ERROR]') ? 'error' : line.includes('[WARN]') ? 'warn' : line.includes('[INFO]') ? 'info' : '';
      html += '<div class="' + cls + '">' + escapeHtml(line) + '</div>';
    }
  } else {
    html += '<div style="color:var(--muted)">No log entries</div>';
  }
  html += '</div></div>';

  app.innerHTML = html;
}

function escapeHtml(s) {
  const d = document.createElement('div');
  d.textContent = s;
  return d.innerHTML;
}

function showDetail(slug) {
  window.location.hash = '#mirror-' + slug;
  const m = data.mirrors.find(x => x.slug === slug);
  if (!m) return;
  const app = document.getElementById('app');
  app.innerHTML = '<div class="loading">Loading details...</div>';
  fetch('/admin/api/mirrors/' + slug).then(r => r.json()).then(detail => {
    const disk = formatBytes(detail.disk_bytes);
    const code = detail.exit_code;
    const codeTag = code === 0 ? '<span class="tag tag-ok">0</span>' :
                    code === -1 ? '<span class="tag tag-idle">-</span>' :
                    '<span class="tag tag-error">' + code + '</span>';
    app.innerHTML =
      '<button class="btn" onclick="refresh(); window.location.hash=\'\'" style="margin-bottom:16px">&larr; Back</button>' +
      '<div class="detail-grid">' +
        '<div class="detail-sidebar">' +
          '<h2>' + detail.slug + '</h2>' +
          '<div class="info-row"><span class="info-label">Name</span><span>' + escapeHtml(detail.name) + '</span></div>' +
          '<div class="info-row"><span class="info-label">Method</span><span>' + detail.method + '</span></div>' +
          '<div class="info-row"><span class="info-label">Upstream</span><span style="font-family:var(--mono);font-size:12px;word-break:break-all">' + escapeHtml(detail.upstream) + '</span></div>' +
          '<div class="info-row"><span class="info-label">Interval</span><span>' + detail.interval + '</span></div>' +
          '<div class="info-row"><span class="info-label">Status</span><span>' + statusTag(detail.status) + '</span></div>' +
          '<div class="info-row"><span class="info-label">Exit Code</span><span>' + codeTag + '</span></div>' +
          '<div class="info-row"><span class="info-label">Disk Usage</span><span>' + disk + '</span></div>' +
          '<div class="info-row"><span class="info-label">Upstream Health</span><span>' + statusTag(detail.upstream_health) + '</span></div>' +
          '<div class="info-row"><span class="info-label">Response Time</span><span>' + detail.upstream_response_time_ms + 'ms</span></div>' +
          '<div class="info-row"><span class="info-label">Last Sync</span><span>' + ago(detail.last_sync_ago) + '</span></div>' +
          '<div class="card-actions" style="margin-top:16px">' +
            '<button class="btn btn-sm btn-primary" onclick="syncOne(\'' + slug + '\');refresh()">Sync Now</button>' +
            '<button class="btn btn-sm btn-danger" onclick="deleteMirror(\'' + slug + '\')">Delete</button>' +
          '</div>' +
        '</div>' +
        '<div>' +
          '<h2>Raw Status</h2>' +
          '<pre class="raw-json">' + JSON.stringify(detail, null, 2) + '</pre>' +
        '</div>' +
      '</div>';
  }).catch(e => {
    app.innerHTML = '<div class="loading" style="color:var(--red)">Failed: ' + e.message + '</div>';
  });
}

function showCreate() {
  document.getElementById('create-modal').classList.remove('hidden');
  document.getElementById('create-error').textContent = '';
  document.getElementById('create-btn').disabled = false;
  document.getElementById('create-btn').textContent = 'Create';
}

function hideCreate() {
  document.getElementById('create-modal').classList.add('hidden');
}

async function createMirror() {
  const btn = document.getElementById('create-btn');
  const err = document.getElementById('create-error');
  err.textContent = '';
  btn.disabled = true;
  btn.textContent = 'Creating...';

  const body = {
    slug: document.getElementById('f-slug').value,
    name: document.getElementById('f-name').value,
    description: document.getElementById('f-desc').value,
    upstream: document.getElementById('f-upstream').value,
    method: document.getElementById('f-method').value,
    interval: document.getElementById('f-interval').value,
    size: document.getElementById('f-size').value,
    bandwidth: parseInt(document.getElementById('f-bandwidth').value) || 0,
    retention_days: parseInt(document.getElementById('f-retention-days').value) || 0,
    retention_max_gib: parseInt(document.getElementById('f-retention-gib').value) || 0,
  };

  try {
    const res = await fetch('/admin/api/mirrors', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify(body),
    });
    const data = await res.json();
    if (!res.ok) {
      err.textContent = data.detail || 'Failed to create mirror';
      btn.disabled = false;
      btn.textContent = 'Create';
      return;
    }
    hideCreate();
    refresh();
  } catch(e) {
    err.textContent = e.message;
    btn.disabled = false;
    btn.textContent = 'Create';
  }
}

function deleteMirror(slug) {
  if (!confirm('Delete mirror "' + slug + '"? This will remove the nginx location but keep data on disk.')) return;
  fetch('/admin/api/mirrors/' + slug, { method: 'DELETE' }).then(r => r.json()).then(d => {
    if (d.ok) { window.location.hash = ''; refresh(); }
    else alert('Delete failed');
  });
}

// Hash routing
window.addEventListener('hashchange', () => {
  const hash = window.location.hash;
  if (hash.startsWith('#mirror-')) {
    const slug = hash.replace('#mirror-', '');
    showDetail(slug);
  } else {
    refresh();
  }
});

// Initial load
if (window.location.hash) {
  window.dispatchEvent(new Event('hashchange'));
} else {
  refresh();
}
// Auto-refresh every 30s
setInterval(refresh, 30000);
</script>
</body>
</html>"""


@app.get("/admin")
@app.get("/admin/")
@app.get("/admin/{path:path}")
async def admin_ui(request=None):
    return HTMLResponse(ADMIN_HTML)


def main():
    port = int(os.environ.get("EZMIRROR_ADMIN_PORT", "8080"))
    host = os.environ.get("EZMIRROR_ADMIN_HOST", "127.0.0.1")
    print(f"ezmirror admin panel starting on {host}:{port}")
    uvicorn.run(app, host=host, port=port, log_level="info")


if __name__ == "__main__":
    main()
