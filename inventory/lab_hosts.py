#!/usr/bin/env python3
"""Dynamic inventory for the DAELT/UTFPR labs.

The single source of truth for the fleet is the registry ``hosts.txt`` served
by the hub -- the very same file the golden's boot scripts fetched. Each line
is ``<mac> <hostname>`` (comments with ``#`` and blank lines are ignored). The
lab group is derived from the hostname prefix, e.g. ``cd108-test-01`` -> lab
``cd108``.

This is the "ansible way" replacement for the golden's PULL model: instead of
each machine fetching the registry at boot to self-name/self-restore, the
CONTROL NODE reads the registry and pushes config out (site.yml / reset-homes).

Config:
  * ``LAB_HOSTS_URL`` env var overrides the registry URL.
If the registry is unreachable the inventory comes back empty (with a warning)
so a hub outage can't wedge every playbook run.

The static group hierarchy (labs -> {cd108,cd106,cb203,ca307}, freeipa_members,
server) lives alongside this file in ``hosts.yml``; Ansible merges the two.
"""
import json
import os
import sys
import urllib.request

REGISTRY_URL = os.environ.get(
    "LAB_HOSTS_URL", "http://cd108.tutu.eng.br:8888/hosts.txt"
)
KNOWN_LABS = ("cd108", "cd106", "cb203", "ca307")


def fetch_registry():
    try:
        with urllib.request.urlopen(REGISTRY_URL, timeout=5) as resp:
            return resp.read().decode("utf-8", "replace")
    except Exception as exc:  # network/HTTP/timeout — degrade gracefully
        sys.stderr.write(
            "[lab_hosts] warning: could not fetch %s: %s\n" % (REGISTRY_URL, exc)
        )
        return ""


def build_inventory():
    inv = {"_meta": {"hostvars": {}}}
    for lab in KNOWN_LABS:
        inv[lab] = {"hosts": []}

    for raw in fetch_registry().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 2:
            sys.stderr.write("[lab_hosts] skipping malformed line: %r\n" % raw)
            continue
        mac, host = parts[0].lower(), parts[1]
        lab = host.split("-", 1)[0]
        group = lab if lab in inv else "unknown_lab"
        inv.setdefault(group, {"hosts": []})["hosts"].append(host)
        # ansible_host stays the hostname: resolution is via campus DNS / mDNS
        # (avahi). Set a per-host ansible_host in host_vars to pin an IP if a
        # given machine isn't resolvable yet.
        inv["_meta"]["hostvars"][host] = {"ansible_host": host, "mac": mac}

    return inv


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "--host":
        # all vars are returned in _meta by --list, so per-host is empty
        print(json.dumps({}))
    else:
        print(json.dumps(build_inventory(), indent=2))


if __name__ == "__main__":
    main()
