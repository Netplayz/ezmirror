#!/usr/bin/env python3
"""
ezmirror-manage — add, remove, or reconfigure mirrors.
"""

import os
import sys
import json
from pathlib import Path

CONF_DIR = Path("/etc/ezmirror")
MIRRORS_CONF = CONF_DIR / "mirrors.conf"
MIRRORS_JSON = Path(__file__).resolve().parent.parent / "mirrors.json"

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
    if MIRRORS_JSON.exists():
        with open(MIRRORS_JSON) as f:
            return json.load(f)
    return []


def read_active_mirrors():
    mirrors = []
    if not MIRRORS_CONF.exists():
        return mirrors
    with open(MIRRORS_CONF) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split("|")
            if parts:
                mirrors.append(parts[0])
    return mirrors


def write_active_mirrors(mirrors):
    catalog = {m["slug"]: m for m in load_mirrors()}
    with open(MIRRORS_CONF, "w") as f:
        f.write("# ezmirror - active mirrors\n")
        f.write("# Format: slug|Name|Description|Upstream|Method|Size|warn|interval|bandwidth|retention_days|retention_max_gib\n")
        f.write("#\n")
        for slug in mirrors:
            if slug in catalog:
                m = catalog[slug]
                f.write(f"{m['slug']}|{m.get('name','')}|{m.get('description','')}|"
                        f"{m.get('upstream','')}|{m.get('method','rsync')}|{m.get('size','')}|"
                        f"{m.get('warn','')}|{m.get('interval','6h')}|"
                        f"{m.get('bandwidth',0)}|{m.get('retention_days',0)}|{m.get('retention_max_gib',0)}\n")
            else:
                f.write(f"{slug}|||||unknown||6h|0|0|0\n")


def show_panel(catalog, active):
    os.system("clear")
    print(f"\n{B}  Mirror Selection{N}")
    print()
    for i, m in enumerate(catalog, 1):
        slug = m["slug"]
        name = m.get("name", "")
        size = m.get("size", "")
        interval = m.get("interval", "6h")
        sel = f"{G}*{N}" if slug in active else " "
        warn_flag = f" {Y}*{N}" if m.get("warn") == "large" else ""
        print(f"  [{sel}] {i:3d}. {slug:14s} {name:30s} {size:10s} {interval}{warn_flag}")
    print(f"\n  Selected: {len(active)} mirror(s)")
    print(f"  Enter numbers to toggle, 'a' all, 'n' none, 'd' done\n")


def main():
    if os.geteuid() != 0:
        die("Run with sudo: sudo ezmirror-manage")

    catalog = load_mirrors()
    if not catalog:
        catalog = [
            {"slug": "debian", "name": "Debian GNU/Linux", "interval": "12h"},
            {"slug": "ubuntu", "name": "Ubuntu", "interval": "12h"},
            {"slug": "arch", "name": "Arch Linux", "interval": "1h"},
            {"slug": "alpine", "name": "Alpine Linux", "interval": "6h"},
        ]

    active = read_active_mirrors()
    info(f"Loaded {len(active)} existing mirror(s)")

    while True:
        show_panel(catalog, active)
        choice = input("  > ").strip().lower()
        if choice in ("d", "done", ""):
            break
        elif choice == "a":
            active = [m["slug"] for m in catalog]
        elif choice == "n":
            active = []
        else:
            for token in choice.split():
                if token.isdigit():
                    idx = int(token) - 1
                    if 0 <= idx < len(catalog):
                        slug = catalog[idx]["slug"]
                        if slug in active:
                            active.remove(slug)
                        else:
                            active.append(slug)

    if not active:
        die("No mirrors selected.")

    write_active_mirrors(active)
    ok(f"Saved {len(active)} mirror(s) to {MIRRORS_CONF}")
    print(f"\n  Run 'sudo ezmirror-sync' to sync now.\n")


if __name__ == "__main__":
    main()
