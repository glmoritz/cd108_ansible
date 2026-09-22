#!/usr/bin/env bash
#
# relocate-local-homes.sh NEW_BASE — move every LOCAL account's home out of /home so autofs can
# serve /home from NFS (IPA users). Run by identity/relocate-local-homes.yml as a detached
# systemd unit (cwd /), never from inside an SSH session whose cwd is a home being moved.
#
# ZFS-backed homes are moved by MOUNTPOINT, not by copying: the dataset mounted at /home gets
# mountpoint=NEW_BASE and its children follow (explicit child mountpoints are reset to inherit).
# Plain-directory homes on the root fs are renamed (mv on the same fs = instant).
# /etc/passwd is edited directly (usermod -d refuses while the user has processes).
# Idempotent: a second run finds nothing under /home and does nothing.
set -euo pipefail
# SAFETY: the ZFS dataset to move is passed EXPLICITLY (or "none") and must currently be mounted at
# /home — never auto-discovered. (Auto-discovery nearly re-pointed an admin workstation's live
# ssdpool/home when run in a container with /dev/zfs, 2026-09-22.) Also refuses on non-ca307 hosts.
NEW="${1:?usage: relocate-local-homes.sh NEW_BASE <home-dataset|none>}"
DS_ARG="${2:?usage: relocate-local-homes.sh NEW_BASE <home-dataset|none>}"
case "$(hostname -s)" in ca307-*|labsc[0-9]*) ;; *) echo "REFUSING: $(hostname -s) is not a ca307 machine" >&2; exit 2;; esac
log(){ echo "[relocate] $*"; }

mapfile -t USERS < <(awk -F: '$3>=1000 && $3<60000 && $6 ~ "^/home/" {print $1}' /etc/passwd)
HAVE_ZFS=0; command -v zfs >/dev/null && HAVE_ZFS=1
PARENT=""
if [ "$DS_ARG" != none ]; then
  [ "$HAVE_ZFS" = 1 ] || { echo "dataset given but no zfs here" >&2; exit 2; }
  MP_NOW="$(zfs get -H -o value mountpoint "$DS_ARG")" || { echo "no such dataset $DS_ARG" >&2; exit 2; }
  if [ "$MP_NOW" = /home ]; then PARENT="$DS_ARG"
  elif [ "$MP_NOW" = "$NEW" ]; then log "$DS_ARG already at $NEW"
  else echo "REFUSING: $DS_ARG is mounted at $MP_NOW, not /home" >&2; exit 2; fi
fi
if [ ${#USERS[@]} -eq 0 ] && [ -z "$PARENT" ]; then log "nothing under /home — already relocated"; exit 0; fi
log "local users with homes in /home: ${USERS[*]:-none}; ZFS dataset at /home: ${PARENT:-none}"

# autofs sits ON TOP of /home: it must be down to remount what's underneath
AUTOFS_WAS_ACTIVE=0
if systemctl is-active -q autofs; then AUTOFS_WAS_ACTIVE=1; systemctl stop autofs; log "autofs stopped"; fi
mkdir -p "$NEW"; chmod 0755 "$NEW"

# 1) ZFS: move the /home dataset; children with an explicit /home/... mountpoint re-inherit
if [ -n "$PARENT" ]; then
  zfs list -H -r -o name,mountpoint -s name "$PARENT" | awk -v p="$PARENT" '$1!=p' |
  while read -r ds mp; do
    if [ "$(zfs get -H -o source mountpoint "$ds")" = local ] && [ "${mp#/home/}" != "$mp" ]; then
      zfs inherit mountpoint "$ds"; log "inherit $ds"
    fi
  done
  zfs set mountpoint="$NEW" "$PARENT"; log "$PARENT -> $NEW"
fi
[ "$HAVE_ZFS" = 0 ] || zfs mount -a || true

# 2) plain directories + passwd
for u in "${USERS[@]}"; do
  old="$(getent passwd "$u" | cut -d: -f6)"; rel="${old#/home/}"; dst="$NEW/$rel"
  if [ -d "$old" ] && ! mountpoint -q "$old" && [ ! -e "$dst" ]; then mv "$old" "$dst"; log "mv $old -> $dst"; fi
  [ -d "$dst" ] || log "WARNING: $u: $dst does not exist (home was empty/absent?)"
  sed -i "s#^\($u:[^:]*:[^:]*:[^:]*:[^:]*:\)$old:#\1$dst:#" /etc/passwd
  log "passwd $u: $(getent passwd "$u" | cut -d: -f6)"
done

# 3) leftovers: anything still in /home would be hidden (and block nothing, but is confusing)
LEFT="$(find /home -mindepth 1 -maxdepth 1 2>/dev/null | head -20 || true)"
[ -z "$LEFT" ] || log "NOTE: still present in /home (hidden once autofs mounts over it): $LEFT"

if [ "$AUTOFS_WAS_ACTIVE" = 1 ]; then systemctl start autofs; log "autofs started"; fi
log "done"
