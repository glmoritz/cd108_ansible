#!/bin/sh
# Work around the Intel I217/I218/I219 (e1000e) "Detected Hardware Unit Hang".
#
# Under sustained heavy TX (e.g. this box's cd108-server VM serving Clonezilla
# images over NFS to several machines at once) the e1000e controller wedges its
# transmit ring — dmesg shows repeated:
#     e1000e 0000:00:1f.6 eno1: Detected Hardware Unit Hang ... next_to_watch.status <0>
# and the WHOLE host drops off the network until a reboot re-inits the ring. The
# well-documented remedy is to stop handing the controller hardware-segmented
# frames: disable TSO/GSO (and GRO) so the kernel segments in software instead.
#
# This installs a systemd .link drop-in (applied by udev at device setup, so it
# survives reboots AND re-applies if the NIC resets — and works even though the
# uplink is NetworkManager-managed), matched by DRIVER so the same file fixes any
# e1000e host (moritz-desktop, sigivestserver, ...) regardless of interface name.
# It then applies the same settings live to any e1000e NIC already up.
#
# Run once per KVM host:  sudo sh scripts/fix-e1000e-hang.sh
set -eu

LINK=/etc/systemd/network/10-e1000e-no-tso.link

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)"; exit 1; }

cat > "$LINK" <<'EOF'
# cd108: work around the e1000e "Detected Hardware Unit Hang" under heavy TX.
# Disable hardware TX segmentation offload so the wedge never triggers.
[Match]
Driver=e1000e

[Link]
TCPSegmentationOffload=no
TCP6SegmentationOffload=no
GenericSegmentationOffload=no
GenericReceiveOffload=no
EOF
echo "installed $LINK"

# Re-apply link setup for matching devices without a reboot.
udevadm control --reload || true
for dev in /sys/class/net/*/device/driver; do
  drv=$(basename "$(readlink "$dev")" 2>/dev/null) || continue
  [ "$drv" = e1000e ] || continue
  ifn=$(echo "$dev" | cut -d/ -f5)
  udevadm trigger --action=add "/sys/class/net/$ifn" 2>/dev/null || true
  # Belt-and-suspenders: set live too (udev .link offload apply can be a no-op on
  # an already-configured link on some systemd versions).
  ethtool -K "$ifn" tso off gso off gro off 2>/dev/null || true
  echo "applied to $ifn:"
  ethtool -k "$ifn" | grep -E "^tcp-segmentation-offload|^generic-segmentation-offload|^generic-receive-offload" | sed 's/^/    /'
done

echo "done. Verify under load: dmesg -w should show NO 'Detected Hardware Unit Hang'."
