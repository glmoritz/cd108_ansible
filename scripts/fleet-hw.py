#!/usr/bin/env python3
"""Lab hardware inventory from phone-home beacons.

Each machine POSTs a hardware inventory on boot (roles/common's phone-home ->
roles/server's receiver), logged to /var/log/phone-home/beacons.jsonl. This
prints the LATEST hardware seen per machine (keyed by machine_id, falling back
to hostname) as a table, or full JSON with --json.

Usage:
  scripts/fleet-hw.py                 # ssh-pull the log from the server
  scripts/fleet-hw.py beacons.jsonl   # read a local copy
  scripts/fleet-hw.py --json          # full JSON per machine (for jq/pipelines)
  scripts/fleet-hw.py --server host   # override the ssh target for the hub
"""
import argparse
import json
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INVENTORY = os.path.join(REPO, "inventory", "hosts.yml")
DEFAULT_SERVER = "cd108.tutu.eng.br"   # fallback only; normally read from inventory
REMOTE_LOG = "/var/log/phone-home/beacons.jsonl"


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


def read_log(path, server):
    """Return the raw beacons.jsonl text, seamlessly whether run on the server or off.

    On the server the receiver's log is now group-readable (roles/server runs the
    receiver as a static `phonehome` user, not a DynamicUser jail under
    /var/log/private), so a plain local/remote `cat` works with no sudo. We still
    fall back to a NON-interactive `sudo -n` for older/locked-down deployments —
    never an interactive one, so this can't hang on a password prompt.
    """
    if path:
        return open(path).read()
    # Running ON the server: read the local log directly (no ssh, no sudo).
    if os.path.exists(REMOTE_LOG):
        try:
            return open(REMOTE_LOG).read()
        except PermissionError:
            r = subprocess.run(["sudo", "-n", "cat", REMOTE_LOG],
                               capture_output=True, text=True)
            if r.returncode == 0:
                return r.stdout
            sys.exit(f"can't read {REMOTE_LOG} locally as {os.environ.get('USER', '?')} "
                     f"(permission). Re-converge roles/server, or run with sudo.")
    # Off the server: pull it over ssh. Plain cat first (log is group-readable),
    # sudo -n as a non-interactive fallback only.
    r = subprocess.run(
        ["ssh", server, f"cat {REMOTE_LOG} 2>/dev/null || sudo -n cat {REMOTE_LOG}"],
        capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"could not read {REMOTE_LOG} on {server}:\n{r.stderr.strip()}")
    return r.stdout


def load_latest(path, server):
    """Return {key: rec} — the newest beacon per machine (machine_id|hostname)."""
    raw = read_log(path, server)
    latest = {}
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        b = rec.get("beacon", {})
        key = b.get("machine_id") or b.get("hostname") or rec.get("src_ip")
        if not key:
            continue
        ts = rec.get("recv_ts", "")
        if key not in latest or ts > latest[key].get("recv_ts", ""):
            latest[key] = rec
    return latest


def cpu_str(c):
    model = c.get("model", "?")
    cps, tpc = c.get("cores_per_socket"), c.get("threads_per_core")
    socks = c.get("sockets")
    try:
        cores = int(cps) * int(socks or 1)
        threads = cores * int(tpc or 1)
        return f"{model} ({cores}c/{threads}t)"
    except (TypeError, ValueError):
        return model


def mem_str(m):
    if not m:
        return "?"
    g = m.get("total_gb")
    used = m.get("slots_used")
    s = f"{g:g}G" if isinstance(g, (int, float)) else "?"
    if used:
        speeds = {mod.get("speed") for mod in m.get("modules", []) if mod.get("speed")}
        sp = " " + "/".join(sorted(speeds)) if speeds else ""
        s += f" ({used} DIMM{'s' if used != 1 else ''}{sp})"
    return s


def disk_str(disks):
    parts = []
    for d in disks or []:
        gb = d.get("size_gb")
        if isinstance(gb, (int, float)):
            size = f"{gb/1000:.1f}T" if gb >= 1000 else f"{gb:g}G"
        else:
            size = "?"
        parts.append(f"{size} {d.get('kind', '')} {d.get('model') or ''}".strip())
    return "; ".join(parts) or "?"


def model_str(system):
    if not system:
        return "?"
    bits = [system.get("vendor"), system.get("product") or system.get("board")]
    return " ".join(b for b in bits if b) or "?"


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("beacons", nargs="?",
                    help="local beacons.jsonl (default: ssh-pull from server)")
    ap.add_argument("--server", help="ssh target for the hub (default: inventory server)")
    ap.add_argument("--json", action="store_true", help="dump full JSON per machine")
    args = ap.parse_args()

    server = args.server or inventory_server(INVENTORY) or DEFAULT_SERVER
    latest = load_latest(args.beacons, server)
    rows = sorted(latest.values(),
                  key=lambda r: r.get("beacon", {}).get("hostname", ""))

    if args.json:
        print(json.dumps([r["beacon"] for r in rows], indent=2, ensure_ascii=False))
        return

    if not rows:
        print("no beacons found.")
        return

    for r in rows:
        b = r.get("beacon", {})
        sp = b.get("specs", {})
        sysd = sp.get("system", {})
        print(f"\n{b.get('hostname', '?')}   [{r.get('recv_ts', '')[:19]}]  {r.get('src_ip', '')}")
        print(f"  model : {model_str(sysd)}"
              + (f"   sn:{sysd['serial']}" if sysd.get("serial") else ""))
        print(f"  cpu   : {cpu_str(sp.get('cpu', {}))}")
        print(f"  ram   : {mem_str(sp.get('memory', {}))}")
        print(f"  disk  : {disk_str(sp.get('disks'))}")
        gpu = sp.get("gpu")
        if gpu:
            print(f"  gpu   : {'; '.join(gpu)}")
        osd = sp.get("os", {})
        if osd:
            print(f"  os    : {osd.get('pretty', '?')}  kernel {osd.get('kernel', '?')}")


if __name__ == "__main__":
    main()
