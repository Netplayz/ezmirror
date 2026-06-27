#!/usr/bin/env python3
"""
ezmirror-update — self-update from GitHub releases.
Usage: sudo ezmirror-update [--list | --test VERSION | VERSION]
"""

import os
import sys
import json
import shutil
import subprocess
import tempfile
from pathlib import Path
from urllib.request import urlopen
from urllib.error import URLError

GH_REPO = None  # Set from lab.conf at runtime
BACKUP_DIR = Path("/etc/ezmirror/backups")
CONF_DIR = Path("/etc/ezmirror")
VERSION_FILE = CONF_DIR / "version"

R = "\033[0;31m"
G = "\033[0;32m"
Y = "\033[1;33m"
C = "\033[0;36m"
B = "\033[1m"
N = "\033[0m"


def log(msg): print(f"  {C}->{N}  {msg}")
def ok(msg): print(f"  {G}*{N}  {msg}")
def warn(msg): print(f"  {Y}!{N}  {msg}")
def die(msg): print(f"  {R}x{N}  {msg}", file=sys.stderr); sys.exit(1)


def get_current_version():
    if VERSION_FILE.exists():
        return VERSION_FILE.read_text().strip()
    return "unknown"


def fetch_releases(repo):
    api = f"https://api.github.com/repos/{repo}/releases"
    try:
        resp = urlopen(f"{api}?per_page=10", timeout=15)
        return json.loads(resp.read())
    except URLError as e:
        die(f"Failed to fetch releases: {e}")


def list_versions(repo):
    log("Fetching available versions...")
    releases = fetch_releases(repo)
    for r in releases:
        tag = r.get("tag_name", "").lstrip("v")
        print(f"    {tag}")
    sys.exit(0)


def download_release(version, repo):
    url = f"https://github.com/{repo}/archive/refs/tags/v{version}.tar.gz"
    log(f"Downloading ezmirror v{version}...")
    tmp = Path(tempfile.mkdtemp())
    archive = tmp / "release.tar.gz"
    try:
        resp = urlopen(url, timeout=30)
        archive.write_bytes(resp.read())
    except URLError as e:
        shutil.rmtree(tmp)
        die(f"Download failed: {e}")

    extract_dir = tmp / "extracted"
    extract_dir.mkdir()
    subprocess.run(["tar", "-xzf", str(archive), "-C", str(extract_dir)], check=True,
                   capture_output=True)
    # Find the extracted directory (it's named ezmirror-{version})
    extracted = list(extract_dir.iterdir())
    if not extracted:
        shutil.rmtree(tmp)
        die("Extraction failed: empty archive")
    repo_root = extracted[0]
    return repo_root, tmp


def backup_config():
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = subprocess.check_output(["date", "+%Y%m%d_%H%M%S"]).decode().strip()
    current = get_current_version()
    backup_file = BACKUP_DIR / f"ezmirror_{current}_{timestamp}.tar.gz"
    log(f"Backing up config to {backup_file}...")

    paths = ["/etc/ezmirror/", "/usr/local/bin/ezmirror-*", "/usr/local/sbin/ezmirord",
             "/etc/systemd/system/ezmirror-*", "/etc/logrotate.d/ezmirror",
             "/etc/nginx/sites-available/default"]

    cmd = ["tar", "-czf", str(backup_file)] + paths
    subprocess.run(cmd, capture_output=True, check=False)
    return backup_file


def run_setup(repo_root):
    """Run the new setup.py with existing config preserved."""
    log("Running new setup...")

    # Load existing config for env vars
    lab_conf = CONF_DIR / "lab.conf"
    if lab_conf.exists():
        with open(lab_conf) as f:
            for line in f:
                if "=" in line:
                    k, v = line.strip().split("=", 1)
                    if k == "LAB_NAME":
                        os.environ["EZMIRROR_LAB_NAME"] = v.strip('"')
                    elif k == "DOMAIN":
                        os.environ["EZMIRROR_DOMAIN"] = v.strip('"')
                    elif k == "LOCATION":
                        os.environ["EZMIRROR_LOCATION"] = v.strip('"')
                    elif k == "GH_USER":
                        os.environ["EZMIRROR_GH_USER"] = v.strip('"')

    # Load existing mirrors
    mirrors_conf = CONF_DIR / "mirrors.conf"
    if mirrors_conf.exists():
        slugs = []
        with open(mirrors_conf) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    slug = line.split("|")[0]
                    if slug:
                        slugs.append(slug)
        if slugs:
            os.environ["EZMIRROR_MIRRORS"] = ",".join(slugs)

    # Load existing paths
    paths_conf = CONF_DIR / "paths.conf"
    if paths_conf.exists():
        with open(paths_conf) as f:
            for line in f:
                if "=" in line:
                    k, v = line.strip().split("=", 1)
                    if k == "MIRROR_DIR":
                        os.environ["EZMIRROR_VOLUME"] = v.strip('"')

    alert_conf = CONF_DIR / "alert.conf"
    if alert_conf.exists():
        with open(alert_conf) as f:
            for line in f:
                if "=" in line:
                    k, v = line.strip().split("=", 1)
                    if k == "ALERT_WEBHOOK":
                        os.environ["EZMIRROR_WEBHOOK"] = v.strip('"')
                    elif k == "ALERT_EMAIL":
                        os.environ["EZMIRROR_EMAIL"] = v.strip('"')

    branding_conf = CONF_DIR / "branding.conf"
    if branding_conf.exists():
        with open(branding_conf) as f:
            for line in f:
                if "=" in line:
                    k, v = line.strip().split("=", 1)
                    if k == "LOGO_URL":
                        os.environ["EZMIRROR_LOGO_URL"] = v.strip('"')

    os.environ["EZMIRROR_UPDATE"] = "1"

    setup_py = repo_root / "python" / "setup.py"
    if not setup_py.exists():
        die(f"setup.py not found in release at {setup_py}")

    result = subprocess.run([sys.executable, str(setup_py), "--unattended"],
                           capture_output=True, text=True)
    if result.returncode != 0:
        print(result.stdout)
        print(result.stderr, file=sys.stderr)
        die("Update setup failed")
    return True


def main():
    if os.geteuid() != 0:
        die("Run with sudo: sudo ezmirror-update [VERSION]")

    current = get_current_version()
    log(f"Current version: {current}")

    # Read GH_USER from lab.conf for repo
    gh_user = "netplayz"
    lab_conf = CONF_DIR / "lab.conf"
    if lab_conf.exists():
        with open(lab_conf) as f:
            for line in f:
                if "=" in line:
                    k, v = line.strip().split("=", 1)
                    if k == "GH_USER":
                        gh_user = v.strip('"')
    repo = f"{gh_user}/ezmirror"

    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} [--list | --test VERSION | VERSION]")
        print(f"\n  Current version: {current}")
        print(f"  Latest:          fetch via --list")
        sys.exit(1)

    arg = sys.argv[1]

    if arg == "--list":
        list_versions(repo)

    if arg == "--test":
        if len(sys.argv) < 3:
            die("Usage: ezmirror-update --test VERSION")
        version = sys.argv[2]
        log(f"Testing update to v{version}...")
        repo_root, tmp = download_release(version, repo)
        log(f"  Downloaded and extracted v{version} to {repo_root}")
        shutil.rmtree(tmp)
        ok("Pre-flight checks passed")
        sys.exit(0)

    version = arg.lstrip("v")

    log(f"Updating ezmirror: v{current} -> v{version}")

    # Backup
    backup_file = backup_config()
    ok(f"Backup: {backup_file}")

    # Stop services
    log("Stopping services...")
    subprocess.run(["systemctl", "stop", "ezmirror-sync.timer",
                    "ezmirror-sync.service", "ezmirord.service"],
                   capture_output=True, check=False)

    # Download and install
    repo_root, tmp = download_release(version, repo)
    run_setup(repo_root)

    # Record version
    VERSION_FILE.write_text(version + "\n")

    # Restart
    log("Restarting services...")
    subprocess.run(["systemctl", "daemon-reload"], capture_output=True)
    subprocess.run(["systemctl", "enable", "--now", "ezmirror-sync.timer"],
                   capture_output=True, check=False)
    subprocess.run(["systemctl", "enable", "--now", "ezmirord.service"],
                   capture_output=True, check=False)

    # Cleanup
    shutil.rmtree(tmp)

    ok(f"Updated to v{version}")
    print(f"\n  Rollback: sudo ezmirror-rollback {backup_file}\n")


if __name__ == "__main__":
    main()
