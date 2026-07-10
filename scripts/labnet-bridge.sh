#!/usr/bin/env bash
# labnet-bridge.sh — put the KVM host + lab VMs on ONE L2 bridge so they share
# the campus network, killing macvtap host<->guest isolation. On demand and
# fully reversible: it writes NOTHING persistent, so `down` OR a reboot restores
# the normal setup (host IP back on the physical NIC, VMs back on NAT).
#
# Runs on the hypervisor host (moritz-desktop). NOT an Ansible-managed file.
#
#   sudo scripts/labnet-bridge.sh up       # move host IP -> br0, enslave NIC, attach VMs
#   sudo scripts/labnet-bridge.sh down      # restore the normal setup
#   sudo scripts/labnet-bridge.sh status
#
# While UP, the host and every VM in VMS sit on br0 with the campus uplink, so
# they all reach each other and the campus LAN (VMs get campus DHCP). Ansible can
# then converge the VMs from this host.
set -euo pipefail

# --- host specifics (edit here if the box changes) -------------------------
BRIDGE=br0
UPLINK=eno1
UPLINK_MAC=a0:ad:9f:1a:2f:00
V4=103.0.1.16/19
V4GW=103.0.0.1
V6=2801:82:c004:103::16/64
V6GW=2801:82:c004:103::1
# Spare USB-Ethernet dongle. Enslaved to the bridge but left DOWN, so plugging a
# cable into it (then `ip link set <dongle> up`) drops that device straight onto
# br0. Leave empty ("") to skip. WARNING: only plug it into a DIFFERENT device/
# segment — cabling it to the SAME campus switch as the uplink makes an L2 loop
# (STP is off for fast host failover).
DONGLE=enxc8a362519eae
# VMs to place on the bridge while UP (attached live only). Add/remove freely.
VMS=(cd108-flashtest cd108-server)
# Where we remember macvtap NICs we moved off the uplink, so `down` restores them.
STATE=/run/labnet-bridge-macvtap.state
# ---------------------------------------------------------------------------

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo ">> $*"; }
command -v ip >/dev/null   || die "iproute2 not found"

have_bridge() { ip link show "$BRIDGE" &>/dev/null; }
uplink_enslaved() { [[ "$(cat /sys/class/net/$UPLINK/master/uifindex 2>/dev/null; readlink -f /sys/class/net/$UPLINK/master 2>/dev/null | xargs -r basename)" == "$BRIDGE" ]]; }

# A NIC can't be enslaved to a bridge while it has a macvtap child, so any VM
# using macvtap on the uplink (e.g. ipa2) blocks `up` with EBUSY. Move those onto
# the bridge with their ORIGINAL MAC (guest keeps its IP; same campus L2), and
# remember them so `down` puts the macvtap back.
iface_mode() {   # $1=vm $2=mac -> the <source mode=...> of that interface
  virsh dumpxml "$1" 2>/dev/null | python3 -c "
import sys,xml.etree.ElementTree as ET
r=ET.parse(sys.stdin).getroot()
for i in r.iter('interface'):
    m=i.find('mac'); s=i.find('source')
    if m is not None and m.get('address')=='$2' and s is not None and s.get('mode'):
        print(s.get('mode')); break" 2>/dev/null
}

migrate_macvtaps() {
  command -v virsh >/dev/null || return
  : > "$STATE"
  local vm mac model mode
  for vm in $(virsh list --name 2>/dev/null); do
    [[ -n "$vm" ]] || continue
    while read -r mac model; do
      [[ -n "$mac" ]] || continue
      mode=$(iface_mode "$vm" "$mac"); mode=${mode:-bridge}
      echo "$vm $mac $mode ${model:-virtio}" >> "$STATE"
      info "moving $vm macvtap $mac off $UPLINK -> $BRIDGE (stays on campus)"
      virsh detach-interface "$vm" --type direct --mac "$mac" --live || true
      virsh attach-interface "$vm" --type bridge --source "$BRIDGE" --mac "$mac" --model "${model:-virtio}" --live || true
    done < <(virsh domiflist "$vm" 2>/dev/null | awk -v u="$UPLINK" '$2=="direct" && $3==u {print $5, $4}')
  done
}

restore_macvtaps() {   # reverse migrate_macvtaps; needs $UPLINK free of the bridge
  [[ -f "$STATE" ]] || return
  command -v virsh >/dev/null || return
  local vm mac mode model
  while read -r vm mac mode model; do
    [[ -n "$vm" ]] || continue
    info "restoring $vm macvtap $mac on $UPLINK (mode $mode)"
    virsh detach-interface "$vm" --type bridge --mac "$mac" --live 2>/dev/null || true
    virsh attach-interface "$vm" --type direct --source "$UPLINK" --mode "${mode:-bridge}" \
      --mac "$mac" --model "${model:-virtio}" --live \
      || info "  (could not reattach macvtap for $vm — reboot $vm to restore)"
  done < "$STATE"
  rm -f "$STATE"
}

attach_vms() {
  command -v virsh >/dev/null || { info "no virsh, skipping VM attach"; return; }
  for vm in "${VMS[@]}"; do
    virsh domstate "$vm" &>/dev/null || { info "skip $vm (not defined)"; continue; }
    [[ "$(virsh domstate "$vm" 2>/dev/null)" == "running" ]] || { info "skip $vm (not running)"; continue; }
    if virsh domiflist "$vm" 2>/dev/null | awk '{print $3}' | grep -qx "$BRIDGE"; then
      info "$vm already on $BRIDGE"; continue
    fi
    info "attaching $vm -> $BRIDGE"
    virsh attach-interface "$vm" --type bridge --source "$BRIDGE" --model virtio --live \
      || info "  (attach failed for $vm)"
  done
}

detach_vms() {
  command -v virsh >/dev/null || return
  for vm in "${VMS[@]}"; do
    virsh domstate "$vm" &>/dev/null || continue
    # detach every interface of this VM whose source is our bridge
    while read -r mac; do
      [[ -n "$mac" ]] || continue
      info "detaching $vm iface $mac from $BRIDGE"
      virsh detach-interface "$vm" --type bridge --mac "$mac" --live || true
    done < <(virsh domiflist "$vm" 2>/dev/null | awk -v b="$BRIDGE" '$3==b {print $5}')
  done
}

rollback() {
  info "rolling back partial bridge setup..."
  ip link set "$UPLINK" nomaster 2>/dev/null || true
  [[ -n "$DONGLE" ]] && ip link set "$DONGLE" nomaster 2>/dev/null || true
  restore_macvtaps
  have_bridge && { ip addr flush dev "$BRIDGE" 2>/dev/null || true; ip link del "$BRIDGE" 2>/dev/null || true; }
  nmcli dev set "$UPLINK" managed yes 2>/dev/null || true
  info "rolled back — the host NIC and macvtap VMs should return to normal (or reboot)."
}

up() {
  [[ $EUID -eq 0 ]] || die "run as root (sudo $0 up)"
  uplink_enslaved && { info "already UP ($UPLINK is on $BRIDGE)"; status; return; }
  ip link show "$UPLINK" &>/dev/null || die "uplink $UPLINK not found"
  trap rollback ERR

  info "detaching $UPLINK from NetworkManager"
  nmcli dev set "$UPLINK" managed no 2>/dev/null || info "  (nmcli not managing $UPLINK)"

  info "creating $BRIDGE"
  have_bridge || ip link add name "$BRIDGE" type bridge
  ip link set "$BRIDGE" address "$UPLINK_MAC" || true   # same MAC as the uplink
  nmcli dev set "$BRIDGE" managed no 2>/dev/null || true
  ip link set "$BRIDGE" up

  info "clearing macvtap NICs off $UPLINK (they block enslaving it)"
  migrate_macvtaps

  info "moving $UPLINK into $BRIDGE and relocating the host IP"
  ip addr flush dev "$UPLINK"
  ip link set "$UPLINK" master "$BRIDGE"
  ip link set "$UPLINK" up
  ip addr add "$V4" dev "$BRIDGE"
  ip -6 addr add "$V6" dev "$BRIDGE" 2>/dev/null || true
  ip route replace default via "$V4GW" dev "$BRIDGE"
  ip -6 route replace default via "$V6GW" dev "$BRIDGE" 2>/dev/null || true

  if [[ -n "$DONGLE" ]] && ip link show "$DONGLE" &>/dev/null; then
    info "enslaving spare NIC $DONGLE (left DOWN — bring up when you plug a cable)"
    ip addr flush dev "$DONGLE" 2>/dev/null || true
    ip link set "$DONGLE" master "$BRIDGE"
    ip link set "$DONGLE" down
  fi

  trap - ERR
  info "attaching VMs"
  attach_vms
  echo; status
  echo; info "UP. Host + VMs share the campus L2 via $BRIDGE. 'down' or reboot to revert."
  [[ -n "$DONGLE" ]] && info "To use the dongle: plug a cable, then 'sudo ip link set $DONGLE up'."
}

down() {
  [[ $EUID -eq 0 ]] || die "run as root (sudo $0 down)"
  info "detaching VMs from $BRIDGE"
  detach_vms
  [[ -n "$DONGLE" ]] && ip link show "$DONGLE" &>/dev/null && ip link set "$DONGLE" nomaster 2>/dev/null || true
  if uplink_enslaved || have_bridge; then
    info "tearing down $BRIDGE, IP back on $UPLINK"
    ip link set "$UPLINK" nomaster 2>/dev/null || true
    have_bridge && { ip addr flush dev "$BRIDGE" 2>/dev/null || true; ip link set "$BRIDGE" down 2>/dev/null || true; ip link del "$BRIDGE" 2>/dev/null || true; }
  fi
  info "handing $UPLINK back to NetworkManager (restores static $V4)"
  nmcli dev set "$UPLINK" managed yes 2>/dev/null || true
  nmcli con up netplan-"$UPLINK" 2>/dev/null || true
  sleep 2
  # fallback if NM didn't reassert the address
  if ! ip -4 addr show "$UPLINK" | grep -q "${V4%/*}"; then
    info "NM didn't restore the IP; setting it manually"
    ip addr add "$V4" dev "$UPLINK" 2>/dev/null || true
    ip route replace default via "$V4GW" dev "$UPLINK" 2>/dev/null || true
  fi
  info "restoring macvtap VMs onto $UPLINK"
  restore_macvtaps
  echo; status
  echo; info "DOWN. Normal setup restored."
}

status() {
  echo "bridge : $(have_bridge && echo "$BRIDGE present" || echo "no $BRIDGE")"
  if have_bridge; then
    echo "members: $(ls /sys/class/net/$BRIDGE/brif 2>/dev/null | paste -sd' ' || echo none)"
    echo "addr   : $(ip -br addr show $BRIDGE 2>/dev/null | awk '{$1=$2="";print}' | xargs)"
  fi
  echo "uplink : $(ip -br addr show $UPLINK 2>/dev/null | xargs)"
  [[ -n "$DONGLE" ]] && echo "dongle : $(ip -br link show $DONGLE 2>/dev/null | xargs || echo "$DONGLE absent")"
  echo "def rt : $(ip route show default | xargs)"
  if command -v virsh >/dev/null; then
    for vm in "${VMS[@]}"; do
      virsh domstate "$vm" &>/dev/null || continue
      on=$(virsh domiflist "$vm" 2>/dev/null | awk -v b="$BRIDGE" '$3==b{print $5}' | paste -sd, )
      echo "vm $vm: ${on:-not on $BRIDGE}"
    done
  fi
}

case "${1:-}" in
  up)     up ;;
  down)   down ;;
  status) status ;;
  *) echo "usage: sudo $0 {up|down|status}"; exit 2 ;;
esac
