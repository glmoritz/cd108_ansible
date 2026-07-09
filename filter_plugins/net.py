"""Custom Ansible filters for the DAELT/UTFPR labs.

eui64_linklocal: derive a NIC's IPv6 link-local address from its MAC via the
EUI-64 rule (RFC 4291). The MAC is fixed and recorded in inventory, so the
resulting address is stable and needs no DHCP, DNS, mDNS, or any server —
which is what lets the control node reach a freshly-imaged box that has no
unique name yet. Requires the control node on the same L2 segment; append the
uplink interface as a zone id (e.g. "...%eno1") when using it as ansible_host.
"""


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


class FilterModule(object):
    def filters(self):
        return {"eui64_ifid": eui64_ifid, "eui64_linklocal": eui64_linklocal}
