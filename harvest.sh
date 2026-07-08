#!/usr/bin/env bash
# Run this ON the golden machine (student PC and/or professor PC).
# It only READS state and writes to ./harvest_out/. Nothing is changed.
#   ./harvest.sh   then hand harvest_out/ back to translate into roles.
set -uo pipefail
OUT="harvest_out/$(hostname)"
mkdir -p "$OUT" "$OUT/firefox"
echo "Writing to $OUT"

# 1. packages installed on top of base Ubuntu
comm -23 <(apt-mark showmanual | sort) \
  <(gzip -dc /var/log/installer/initial-status.gz 2>/dev/null | sed -n 's/^Package: //p' | sort) \
  > "$OUT/manual-packages.txt" 2>/dev/null

# 2. third-party apt repos / keys, and the apt proxy config
grep -rhs ^deb /etc/apt/sources.list /etc/apt/sources.list.d/ > "$OUT/apt-repos.txt"
cp -a /etc/apt/apt.conf.d/*proxy* "$OUT/" 2>/dev/null
ls -la /etc/apt/keyrings/ /etc/apt/trusted.gpg.d/ > "$OUT/apt-keys.txt" 2>/dev/null
snap list > "$OUT/snaps.txt" 2>/dev/null

# 3. users/groups added, and docker group membership
awk -F: '$3>=1000 && $3<65534 {print $1, $3}' /etc/passwd > "$OUT/users.txt"
getent group docker sudo > "$OUT/groups.txt"

# 4. services, mounts, disks, zfs
systemctl list-unit-files --state=enabled --type=service > "$OUT/services.txt"
grep -v '^#' /etc/fstab > "$OUT/fstab.txt"
lsblk -f > "$OUT/lsblk.txt"
zpool status > "$OUT/zpool.txt" 2>/dev/null
zfs list -o name,mountpoint,used > "$OUT/zfs.txt" 2>/dev/null

# 5. proprietary / heavy apps
ls -la /opt/ > "$OUT/opt.txt" 2>/dev/null
find /opt -maxdepth 3 -iname '*.lic' -o -iname 'license*' 2>/dev/null > "$OUT/licenses.txt"

# 6. server-side services (harmless if absent)
cat /etc/exports > "$OUT/nfs-exports.txt" 2>/dev/null
testparm -s > "$OUT/samba.txt" 2>/dev/null
cp -a /etc/apt-cacher-ng/acng.conf /etc/squid/squid.conf "$OUT/" 2>/dev/null

# 7. desktop lockdown + firefox policy (your notes)
find /etc/dconf -type f > "$OUT/dconf-files.txt" 2>/dev/null
cp -a /etc/dconf "$OUT/dconf" 2>/dev/null
cp -a /etc/firefox/policies "$OUT/firefox/policies" 2>/dev/null
find / -name 'policies.json' 2>/dev/null > "$OUT/firefox/policies-locations.txt"

# 8. system tweaks (your notes)
sysctl -a 2>/dev/null | grep -i 'privacy\|use_tempaddr' > "$OUT/ipv6-privacy.txt"
timedatectl > "$OUT/timedatectl.txt"
cp -a /etc/netplan "$OUT/netplan" 2>/dev/null
find / -lname '*/var/tmp*' -o -path '*/var/tmp' -type l 2>/dev/null > "$OUT/var-tmp-symlink.txt"
ethtool eth0 2>/dev/null | grep -i wake > "$OUT/wol.txt"

# 9. scheduled jobs (the idle-shutdown cron, etc.)
for u in root daelt; do crontab -l -u "$u" 2>/dev/null | sed "s/^/[$u] /"; done > "$OUT/crontabs.txt"
cp -a /etc/cron.d "$OUT/cron.d" 2>/dev/null

echo "Done. Review $OUT/ then hand it back."
