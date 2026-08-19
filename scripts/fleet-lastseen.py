#!/usr/bin/env python3
"""When did each lab machine last phone home? — a dead-machine detector.

Every machine POSTs a boot beacon to the server (/var/log/phone-home/beacons.jsonl).
This maps each inventory host (by MAC) to its most recent beacon and prints how
long ago that was, oldest first, so long-silent (possibly dead) machines bubble
to the top. Machines that never beaconed show as "never".

Usage:
  scripts/fleet-lastseen.py                 # all lab machines, from the server log
  scripts/fleet-lastseen.py cd108           # filter to a room / name prefix
  scripts/fleet-lastseen.py --stale 3       # flag anything quiet > 3 days (default 2)
  scripts/fleet-lastseen.py beacons.jsonl   # read a local copy of the log
"""
import argparse
import datetime as dt
import json
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INVENTORY = os.path.join(REPO, "inventory", "hosts.yml")
DEFAULT_SERVER = "cd108.tutu.eng.br"
REMOTE_LOG = "/var/log/phone-home/beacons.jsonl"


def read_log(path, server):
    """Beacon text, whether run on the server (local read) or off (ssh pull)."""
    if path:
        return open(path).read()
    if os.path.exists(REMOTE_LOG):                       # running ON the server
        try:
            return open(REMOTE_LOG).read()
        except PermissionError:
            r = subprocess.run(["sudo", "-n", "cat", REMOTE_LOG],
                               capture_output=True, text=True)
            if r.returncode == 0:
                return r.stdout
    r = subprocess.run(["ssh", server, "cat %s || sudo -n cat %s" % (REMOTE_LOG, REMOTE_LOG)],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("could not read %s (locally or via ssh %s):\n%s"
                 % (REMOTE_LOG, server, r.stderr.strip()))
    return r.stdout


def host_macs(path):
    """{hostname: [mac,...]} for every inventory host that declares a MAC."""
    import yaml
    data = yaml.safe_load(open(path)) or {}
    out = {}

    def walk(node):
        if isinstance(node, dict):
            for k, v in node.items():
                if isinstance(v, dict) and "mac" in v:
                    out.setdefault(k, []).append(str(v["mac"]).lower())
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)
    walk(data)
    return out


def inventory_server(path):
    try:
        import yaml
        data = yaml.safe_load(open(path)) or {}
        srv = ((((data.get("all") or {}).get("children") or {})
                .get("server") or {}).get("hosts") or {})
        for name, hv in srv.items():
            return (hv or {}).get("ansible_host") or name
    except Exception:
        pass
    return DEFAULT_SERVER


def parse_ts(s):
    try:
        return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except Exception:
        return None


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("filter", nargs="?", default="",
                    help="host/room name prefix to filter (e.g. cd108, cd106-0)")
    ap.add_argument("--stale", type=float, default=2.0,
                    help="flag machines quiet longer than N days (default 2)")
    ap.add_argument("--server", default=None, help="ssh target for the hub")
    args = ap.parse_args()

    logpath = None
    if args.filter and (os.path.exists(args.filter) or args.filter.endswith(".jsonl")):
        logpath, args.filter = args.filter, ""

    server = args.server or inventory_server(INVENTORY)
    text = read_log(logpath, server)

    last = {}                                   # mac -> latest recv datetime
    for line in text.splitlines():
        try:
            r = json.loads(line)
        except ValueError:
            continue
        ts = parse_ts(r.get("recv_ts", "") or r.get("beacon", {}).get("ts", ""))
        if not ts:
            continue
        for m in (r.get("beacon", {}).get("macs") or []):
            m = m.lower()
            if m.startswith("52:54:00"):        # skip virtual/libvirt NICs
                continue
            if m not in last or ts > last[m]:
                last[m] = ts

    now = dt.datetime.now(dt.timezone.utc)
    rows = []
    for host, macs in host_macs(INVENTORY).items():
        if args.filter and not host.startswith(args.filter):
            continue
        seen = [last[m] for m in macs if m in last]
        if seen:
            ts = max(seen)
            age = (now - ts).total_seconds() / 86400.0
            rows.append((age, host, ts.astimezone().strftime("%Y-%m-%d %H:%M"), age))
        else:
            rows.append((float("inf"), host, "never", None))

    rows.sort(key=lambda r: r[0], reverse=True)     # most-stale first

    print("%-14s %-17s %-8s %s" % ("HOST", "LAST SEEN", "AGE", ""))
    for _, host, when, age in rows:
        if age is None:
            agestr, flag = "-", "never seen"
        else:
            agestr = "%.1fd" % age
            flag = "STALE?" if age > args.stale else ""
        print("%-14s %-17s %-8s %s" % (host, when, agestr, flag))


if __name__ == "__main__":
    main()
