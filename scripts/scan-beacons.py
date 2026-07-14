#!/usr/bin/env python3
"""Reconcile boot beacons against the static inventory — find lost machines.

Each machine POSTs a boot beacon to the hub (roles/common -> roles/server), which
logs them to /var/log/phone-home/beacons.jsonl. This joins those beacons to
inventory/hosts.yml **by MAC** (the stable identity) and reports:

  UNKNOWN  a MAC beaconed that isn't declared in the inventory
  MOVED    a MAC is in the inventory but under a different hostname now
           (i.e. the machine was relocated/renamed — reconcile the inventory)
  SILENT   an inventory host whose MAC has never beaconed, or not in LOST_DAYS

Usage:
  scripts/scan-beacons.py                 # ssh-pull the log from the server
  scripts/scan-beacons.py beacons.jsonl   # read a local copy
  scripts/scan-beacons.py --days 3        # SILENT threshold (default 7)
"""
import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone, timedelta

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INVENTORY = os.path.join(REPO, "inventory", "hosts.yml")
DEFAULT_SERVER = "cd108.tutu.eng.br"   # fallback only; normally read from inventory
REMOTE_LOG = "/var/log/phone-home/beacons.jsonl"
# The hub only accepts the fleet deploy account + key (not your login user), and
# the beacon log is root-owned, so pull it as daelt (NOPASSWD sudo) over the key.
SSH_USER = os.environ.get("CD108_SSH_USER", "daelt")
SSH_KEY = os.path.expanduser(os.environ.get("CD108_SSH_KEY", "~/.ssh/id_cd108_ansible"))


def norm(mac):
    return (mac or "").strip().lower()


def load_inventory(path):
    """Return mac -> hostname from the static inventory (walks any nesting)."""
    try:
        import yaml
    except ImportError:
        sys.exit("PyYAML not found (pip install pyyaml, or run from the ansible venv)")
    with open(path) as f:
        data = yaml.safe_load(f) or {}
    mac2host = {}

    def walk(node):
        if not isinstance(node, dict):
            return
        hosts = node.get("hosts")
        if isinstance(hosts, dict):
            for name, hv in hosts.items():
                mac = norm((hv or {}).get("mac"))
                if mac:
                    mac2host[mac] = name
        children = node.get("children")
        if isinstance(children, dict):
            for child in children.values():
                walk(child)

    walk(data.get("all", data))
    return mac2host


def inventory_server(path):
    """SSH target for the hub: the server group's host (ansible_host if set)."""
    try:
        import yaml
        data = yaml.safe_load(open(path)) or {}
    except Exception:
        return None
    srv = ((((data.get("all") or {}).get("children") or {})
            .get("server") or {}).get("hosts") or {})
    for name, hv in srv.items():
        return (hv or {}).get("ansible_host") or name
    return None


def load_beacons(path, server):
    """Return mac -> latest {recv_ts, hostname, src_ip} across all beacons."""
    if path:
        raw = open(path).read()
    else:
        ssh_cmd = ["ssh", "-i", SSH_KEY, "-o", "IdentitiesOnly=yes",
                   "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=8",
                   f"{SSH_USER}@{server}", f"sudo cat {REMOTE_LOG}"]
        r = subprocess.run(ssh_cmd, capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit(f"could not read {REMOTE_LOG} on {SSH_USER}@{server}:\n{r.stderr.strip()}")
        raw = r.stdout
    latest = {}
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        beacon = rec.get("beacon", {})
        ts = rec.get("recv_ts", "")
        for mac in beacon.get("macs", []):
            mac = norm(mac)
            if not mac:
                continue
            if mac not in latest or ts > latest[mac]["recv_ts"]:
                latest[mac] = {"recv_ts": ts,
                               "hostname": beacon.get("hostname", ""),
                               "src_ip": rec.get("src_ip", "")}
    return latest


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("beacons", nargs="?", help="local beacons.jsonl (default: ssh-pull from server)")
    ap.add_argument("--days", type=int, default=7, help="SILENT threshold in days (default 7)")
    ap.add_argument("--server", help="ssh target for the hub (default: server group in the inventory)")
    args = ap.parse_args()

    mac2host = load_inventory(INVENTORY)
    server = args.server or inventory_server(INVENTORY) or DEFAULT_SERVER
    latest = load_beacons(args.beacons, server)
    now = datetime.now(timezone.utc)
    cutoff = now - timedelta(days=args.days)

    unknown, moved, ok = [], [], []
    for mac, b in sorted(latest.items()):
        inv = mac2host.get(mac)
        if inv is None:
            unknown.append((mac, b["hostname"], b["src_ip"], b["recv_ts"]))
        elif b["hostname"] and b["hostname"] != inv:
            moved.append((mac, inv, b["hostname"], b["recv_ts"]))
        else:
            ok.append((inv, mac))

    silent = []
    for mac, host in sorted(mac2host.items(), key=lambda x: x[1]):
        b = latest.get(mac)
        if b is None:
            silent.append((host, mac, "never"))
        else:
            try:
                if datetime.fromisoformat(b["recv_ts"]) < cutoff:
                    silent.append((host, mac, f"last {b['recv_ts'][:10]}"))
            except ValueError:
                pass

    def section(title, rows, fmt):
        print(f"\n=== {title} ({len(rows)}) ===")
        for r in rows:
            print("  " + fmt(r))

    section("UNKNOWN — beaconed, not in inventory", unknown,
            lambda r: f"{r[0]}  hostname={r[1] or '?'}  ip={r[2]}  ({r[3][:19]})")
    section("MOVED — MAC in inventory under a different name now", moved,
            lambda r: f"{r[0]}  inventory={r[1]}  ->  now reports {r[2]}  ({r[3][:19]})")
    section(f"SILENT — no beacon in {args.days}d (relocated? off? dead?)", silent,
            lambda r: f"{r[0]:<16} {r[1]}  ({r[2]})")

    print(f"\nOK: {len(ok)} host(s) beaconing under their inventory name; "
          f"{len(mac2host)} declared, {len(latest)} MAC(s) seen.")
    # exit non-zero if anything needs attention (handy in CI/cron)
    sys.exit(1 if (unknown or moved or silent) else 0)


if __name__ == "__main__":
    main()
