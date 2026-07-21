"""Custom Ansible filters for the DAELT/UTFPR labs.

eui64_linklocal: derive a NIC's IPv6 link-local address from its MAC via the
EUI-64 rule (RFC 4291). The MAC is fixed and recorded in inventory, so the
resulting address is stable and needs no DHCP, DNS, mDNS, or any server —
which is what lets the control node reach a freshly-imaged box that has no
unique name yet. Requires the control node on the same L2 segment; append the
uplink interface as a zone id (e.g. "...%eno1") when using it as ansible_host.

beacon_ip: the flip side — when EUI-64 IPv6 is unreliable (a machine that never
gets a v6 address), fall back to the address the machine last phoned home from.
The phone-home receiver logs one JSONL beacon per boot to
/var/log/phone-home/beacons.jsonl, and the server stamps the source IP it saw;
matching on the (stable, inventory-keyed) MAC yields a known-reachable address.
"""
import json


def eui64_ifid(mac):
    """Return the 64-bit EUI-64 interface identifier for a MAC, as four hex
    groups (e.g. 'e2d5:5eff:fef6:0818'). With IPv6 privacy extensions off this
    is the host's *actual* lower 64 bits under any prefix, so
    "{{ prefix }}{{ mac | eui64_ifid }}" is its stable global address."""
    mac = str(mac).replace("-", ":").strip().lower()
    parts = mac.split(":")
    if len(parts) != 6:
        raise ValueError("eui64_ifid: %r is not a 6-octet MAC" % mac)
    b = [int(p, 16) for p in parts]
    b[0] ^= 0x02  # flip the Universal/Local bit
    eui = b[0:3] + [0xFF, 0xFE] + b[3:6]
    return ":".join("%02x%02x" % (eui[i], eui[i + 1]) for i in range(0, 8, 2))


def eui64_linklocal(mac):
    """MAC -> IPv6 link-local address (fe80::/64 + EUI-64 interface id)."""
    return "fe80::" + eui64_ifid(mac)


def beacon_ip(log_text, mac):
    """Given the raw phone-home beacons.jsonl text and a NIC MAC, return the
    `src_ip` of the NEWEST beacon whose reported `macs` include that MAC — i.e.
    the address the machine last actually reached the hub from — or '' if the
    machine has never phoned home (or the log is absent/unreadable).

    Matching is on the MAC, not the hostname: the MAC is the inventory key and is
    stable across reflashes and before a clone has been renamed, whereas a fresh
    golden clone still carries the golden's hostname. Falls back to the beacon's
    self-reported `ip` if the server didn't stamp a src_ip."""
    if not log_text or not mac:
        return ""
    target = str(mac).replace("-", ":").strip().lower()
    best_ts, best_ip = "", ""
    for line in str(log_text).splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        b = rec.get("beacon") or {}
        macs = [str(m).replace("-", ":").strip().lower() for m in (b.get("macs") or [])]
        if target not in macs:
            continue
        ts = rec.get("recv_ts") or ""
        if ts >= best_ts:                       # newest wins (ISO ts sorts lexically)
            best_ts, best_ip = ts, (rec.get("src_ip") or b.get("ip") or "")
    return best_ip


class FilterModule(object):
    def filters(self):
        return {"eui64_ifid": eui64_ifid,
                "eui64_linklocal": eui64_linklocal,
                "beacon_ip": beacon_ip}
