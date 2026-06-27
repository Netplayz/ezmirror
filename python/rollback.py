#!/usr/bin/env python3
"""
ezmirror-rollback — restore config from a backup tarball.
Usage: sudo ezmirror-rollback /etc/ezmirror/backups/ezmirror_*.tar.gz
"""

import os
import sys
import subprocess
import tempfile
from pathlib import Path

R = "\033[0;31m"
G = "\033[0;32m"
Y = "\033[1;33m"
C = "\033[0;36m"
N = "\033[0m"


def die(msg): print(f"  {R}x{N}  {msg}", file=sys.stderr); sys.exit(1)
def log(msg): print(f"  {C}->{N}  {msg}")
def ok(msg): print(f"  {G}*{N}  {msg}")


def main():
    if os.geteuid() != 0:
        die("Run with sudo: sudo ezmirror-rollback <backup.tar.gz>")

    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <backup.tar.gz>")
        sys.exit(1)

    backup_file = Path(sys.argv[1])
    if not backup_file.exists():
        die(f"Backup not found: {backup_file}")

    log(f"Rolling back from {backup_file}...")

    tmp = Path(tempfile.mkdtemp())
    subprocess.run(["tar", "-xzf", str(backup_file), "-C", str(tmp)], check=True)
    ok(f"Extracted to {tmp}")

    log("Stopping services...")
    subprocess.run(["systemctl", "stop", "ezmirror-sync.timer",
                    "ezmirror-sync.service", "ezmirord.service"],
                   capture_output=True, check=False)

    log("Restoring config...")
    for item in tmp.iterdir():
        if item.is_dir():
            shutil.copytree(item, Path("/") / item.name, dirs_exist_ok=True)
        elif item.name == "etc":
            shutil.copytree(item, Path("/etc"), dirs_exist_ok=True)

    log("Restarting services...")
    subprocess.run(["systemctl", "daemon-reload"], capture_output=True)
    subprocess.run(["systemctl", "enable", "--now", "ezmirror-sync.timer"],
                   capture_output=True, check=False)
    subprocess.run(["systemctl", "enable", "--now", "ezmirord.service"],
                   capture_output=True, check=False)

    subprocess.run(["systemctl", "reload", "nginx"], capture_output=True, check=False)

    ok("Rollback complete")


if __name__ == "__main__":
    import shutil
    main()
