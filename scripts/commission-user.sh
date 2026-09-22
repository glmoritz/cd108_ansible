#!/usr/bin/env bash
#
# commission-user.sh — provision a LabSC (ca307) user end to end. RUN FROM THE cd108 VM as an admin.
#
#   * FreeIPA account + group membership + optional RA/email/phone   (ipa CLI, LOCAL, your ticket)
#   * NFS home on a per-user ZFS dataset + quota                     (sigivestserver, hdmirror/remotehomes)
#
# Successor of labic-infra/scripts/commission-user.sh (the original labsc wizard), carrying the fixes
# made to its LABIC port (commission-user-labic.sh). What changed vs the original:
#   - AUTH: you run it AS YOURSELF. `kinit <you>` (a member of `admins`), and `ipa ...` runs locally
#     under YOUR ticket, audited as you. No more ssh-to-ipa1 + `kinit admin` with the shared account.
#   - random temp password (forced reset at first login) instead of typing one;
#   - username validated; RA/email/phone optional; flags for non-interactive re-runs;
#   - the group variable is USER_GROUPS, not GROUPS — `GROUPS` is a bash special variable, assigning
#     to it silently no-ops (this broke every LABIC run until 2026-09-16);
#   - sss_cache before resolving the new uid (stale SSSD cache);
#   - /etc/exports on sigivestserver is fingerprinted before/after and the run ABORTS if it changed.
#     It holds hand-written exports (moritz's simulation_results etc.) that are not ours to touch.
#     *** THIS SCRIPT MUST NEVER WRITE /etc/exports. *** Homes use ZFS sharenfs (/etc/exports.d/).
#   - realm guard: refuses to run against any realm but LABSCIPA (LABIC is a separate realm now).
#
# WHO RUNS IT: any IPA admin logged into the cd108 VM with their OWN IPA account. The NFS step goes
# through a forced-command key (/etc/labsc/mkhome_ed25519, group `admins`, 0640) that can only run
# identity/labsc-mkhome on sigivestserver — nobody needs a personal sudo account there. Until that key
# is installed (docs/identity/runbook.md §3) the script falls back to `ssh $NFS_SSH` + sudo.
#
# TOPOLOGY GOTCHA: the cd108 VM runs ON sigivestserver with a macvtap LAN NIC, and macvtap blocks
# guest<->own-host traffic — 103.0.1.37 is unreachable from here. Reach the host over the libvirt
# NAT side instead: 192.168.122.1 (virbr0). That is the default below.
#
set -euo pipefail

# ---------------- site config (labsc) ----------------
REALM="LABSCIPA.TUTU.ENG.BR"
DOMAIN="labscipa.tutu.eng.br"
ID_MIN=500600000; ID_MAX=500799999                 # labsc's IPA id range (LABIC uses 500800000+)
MKHOME_KEY="/etc/labsc/mkhome_ed25519"             # forced-command key → labsc-mkhome (preferred path)
MKHOME_SSH="svc-mkhome@192.168.122.1"
NFS_SSH="${NFS_SSH:-moritz@192.168.122.1}"         # fallback: sigivestserver via virbr0, an account with sudo there
NFS_NAME="nfs1.$DOMAIN"
ZFS_BASE="hdmirror/remotehomes"; ZFS_MP="/export/remotehomes"
# only used if the parent dataset doesn't exist yet (it does). `insecure` is REQUIRED at labsc:
# NAT'd clients arrive from non-privileged source ports -> "mount.nfs4: Operation not permitted".
SHAREOPTS="rw=@103.0.0.0/19,root_squash,no_subtree_check,insecure"
DEFAULT_GROUPS="students"; DEFAULT_QUOTA="10G"; LOGIN_SHELL="/bin/bash"
# ------------------------------------------------------

b(){ printf '\033[1m%s\033[0m\n' "$*"; }
die(){ printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---- args: any flag not given is prompted; RA/email/phone are OPTIONAL (blank = skip) ----
U="" FIRST="" LAST="" USER_GROUPS="" QUOTA="" RA="" EMAIL="" PHONE="" ASSUME_YES=0
while [ $# -gt 0 ]; do case "$1" in
  --user)  U="$2"; shift 2;;      --first) FIRST="$2"; shift 2;;   --last) LAST="$2"; shift 2;;
  --groups) USER_GROUPS="$2"; shift 2;; --quota) QUOTA="$2"; shift 2;;
  --ra) RA="$2"; shift 2;;         --email) EMAIL="$2"; shift 2;;  --phone) PHONE="$2"; shift 2;;
  --nfs-ssh) NFS_SSH="$2"; shift 2;; --yes) ASSUME_YES=1; shift;;
  -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
  *) die "unknown arg: $1";;
esac; done

SSHOPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
nfs_ssh(){ ssh "${SSHOPTS[@]}" "$NFS_SSH" "$@"; }
if [ -r "$MKHOME_KEY" ]; then NFS_MODE=svc; else NFS_MODE=sudo; fi

# ---- preflight: right realm, ipa CLI, YOUR Kerberos ticket ----
command -v ipa >/dev/null || die "no 'ipa' CLI — run this on the cd108 VM (it must be enrolled in $REALM)"
HOST_REALM="$(sed -n 's/^realm *= *//p' /etc/ipa/default.conf 2>/dev/null || true)"
[ "$HOST_REALM" = "$REALM" ] || die "this host is enrolled in '${HOST_REALM:-nothing}', not $REALM — wrong machine?"
if ! klist -s 2>/dev/null; then
  b "No Kerberos ticket. Run 'kinit <you>' — you act as yourself (in 'admins'), audited."
  kinit || die "kinit failed"
fi
WHOAMI="$(klist 2>/dev/null | sed -n 's/^Default principal: //p')"
case "$WHOAMI" in *@"$REALM") ;; *) die "ticket is for '$WHOAMI', not a $REALM principal";; esac
case "$WHOAMI" in admin@*) b "   (warning: you are using the shared 'admin' principal — prefer your own)";; esac

# ---- gather (prompt whatever wasn't passed) ----
[ -n "$U" ]      || read -rp "Username (login):              " U
printf '%s' "$U" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$' || die "invalid username '$U'"
[ -n "$FIRST" ]  || read -rp "First name:                    " FIRST
[ -n "$LAST" ]   || read -rp "Last name:                     " LAST
[ -n "$FIRST" ] && [ -n "$LAST" ] || die "first and last name required"
[ -n "$USER_GROUPS" ] || { read -rp "Groups (comma) [$DEFAULT_GROUPS]:   " USER_GROUPS; USER_GROUPS="${USER_GROUPS:-$DEFAULT_GROUPS}"; }
[ -n "$QUOTA" ]  || { read -rp "Home quota [$DEFAULT_QUOTA]:         " QUOTA; QUOTA="${QUOTA:-$DEFAULT_QUOTA}"; }
[ -n "$RA" ]     || read -rp "Registro Academico (optional): " RA
[ -n "$EMAIL" ]  || read -rp "E-mail (optional):             " EMAIL
[ -n "$PHONE" ]  || read -rp "Telefone (optional):           " PHONE

# ---- confirm ----
b "=== commission '$U' ($FIRST $LAST)  groups=[$USER_GROUPS]  quota=$QUOTA ==="
echo "  IPA (as $WHOAMI): user-add --random${EMAIL:+ +email}${PHONE:+ +phone}${RA:+ +RA}, add to [$USER_GROUPS]"
[ "$NFS_MODE" = svc ] && NFS_VIA="$MKHOME_SSH, forced-command key" || NFS_VIA="$NFS_SSH, your sudo"
echo "  sigivestserver ($NFS_VIA): ZFS $ZFS_BASE/$U quota $QUOTA, chown+skel, /etc/exports asserted untouched"
[ "$ASSUME_YES" = 1 ] || { read -rp "Proceed? [y/N]: " GO; [ "${GO:-N}" = y ] || { echo aborted; exit 0; }; }

# ---- 0) NFS host preflight (no sudo needed: both files are world-readable) ----
if [ "$NFS_MODE" = sudo ]; then
b ">> sigivestserver preflight"
PRE="$(nfs_ssh "zfs list -H -o name $ZFS_BASE >/dev/null && md5sum /etc/exports | awk '{print \"EXPORTS_MD5=\"\$1}'")" \
  || die "cannot reach $NFS_SSH or $ZFS_BASE missing (from the cd108 VM use 192.168.122.1, not 103.0.1.37 — macvtap)"
MD5_BEFORE="$(printf '%s\n' "$PRE" | sed -n 's/^EXPORTS_MD5=//p')"
[ -n "$MD5_BEFORE" ] || die "could not fingerprint /etc/exports"
echo "   reachable; /etc/exports md5 $MD5_BEFORE"
fi

# ---- 1) FreeIPA (LOCAL, under YOUR ticket) ----
b ">> FreeIPA (as $WHOAMI)"
for g in ${USER_GROUPS//,/ }; do ipa group-show "$g" >/dev/null 2>&1 || ipa group-add "$g" --desc="$g"; done
if ipa user-show "$U" >/dev/null 2>&1; then
  b "   user '$U' already exists — not re-adding"
else
  ADD=(--first="$FIRST" --last="$LAST" --homedir="/home/$U" --shell="$LOGIN_SHELL" --random)
  [ -n "$EMAIL" ] && ADD+=(--email="$EMAIL")
  [ -n "$PHONE" ] && ADD+=(--phone="$PHONE")
  OUT="$(ipa user-add "$U" "${ADD[@]}")" || die "ipa user-add failed"
  b "   $(printf '%s\n' "$OUT" | grep -i 'Random password:')   <-- give this to the user (forced reset on first login)"
fi
[ -n "$RA" ] && { ipa user-mod "$U" --addattr="employeeNumber=$RA" >/dev/null && echo "   RA saved (employeeNumber=$RA)"; }
for g in ${USER_GROUPS//,/ }; do ipa group-add-member "$g" --users="$U" >/dev/null 2>&1 || true; done
echo "   groups: $(ipa user-show "$U" --raw 2>/dev/null | sed -n 's/.*memberof_group: //p' | paste -sd, -)"

# ---- 2) resolve the IPA-assigned uid/gid on this client ----
b ">> resolving uid/gid (SSSD)"
sudo -n sss_cache -u "$U" 2>/dev/null || true
UIDN="" GIDN=""
for i in 1 2 3 4 5; do
  ENT="$(getent passwd "$U" 2>/dev/null || true)"
  [ -n "$ENT" ] && { UIDN="$(printf '%s' "$ENT" | cut -d: -f3)"; GIDN="$(printf '%s' "$ENT" | cut -d: -f4)"; break; }
  sleep 2
done
[ -n "$UIDN" ] || die "could not resolve uid for '$U' (SSSD lag). The IPA account WAS created — re-run; it skips user-add."
[ "$UIDN" -ge "$ID_MIN" ] && [ "$UIDN" -le "$ID_MAX" ] \
  || die "uid $UIDN for '$U' is outside labsc's IPA range $ID_MIN-$ID_MAX — a LOCAL user shadows it? (getent: $ENT)"
echo "   uid=$UIDN gid=$GIDN"

# ---- 3) ZFS home on sigivestserver ----
if [ "$NFS_MODE" = svc ]; then
  b ">> sigivestserver: ZFS home (via labsc-mkhome)"
  ssh "${SSHOPTS[@]}" -i "$MKHOME_KEY" -o IdentitiesOnly=yes "$MKHOME_SSH" mkhome "$U" "$UIDN" "$GIDN" "$QUOTA" \
    | sed 's/^/   /' || die "labsc-mkhome failed (IPA account exists — fix and re-run, it is idempotent)"
else
  b ">> sigivestserver: ZFS home (no mkhome key — using your sudo on $NFS_SSH; enter your password there)"
  TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
  cat >"$TMP" <<EOS
set -e
BASE='$ZFS_BASE'; MP='$ZFS_MP'; U='$U'; Q='$QUOTA'; UIDN='$UIDN'; GIDN='$GIDN'
zfs list "\$BASE" >/dev/null 2>&1 || zfs create -o mountpoint="\$MP" -o compression=lz4 -o atime=off -o sharenfs='$SHAREOPTS' "\$BASE"
if zfs list "\$BASE/\$U" >/dev/null 2>&1; then
  zfs set refquota="\$Q" "\$BASE/\$U"; echo "exists — quota set; owner left as \$(stat -c %u:%g "\$MP/\$U")"
else
  zfs create "\$BASE/\$U"; zfs set refquota="\$Q" "\$BASE/\$U"      # inherits sharenfs -> own export
  cp -a /etc/skel/. "\$MP/\$U/"; chown -R "\$UIDN:\$GIDN" "\$MP/\$U"; chmod 700 "\$MP/\$U"
fi
zfs list -o name,refquota,used "\$BASE/\$U"
EOS
  scp "${SSHOPTS[@]}" -q "$TMP" "$NFS_SSH:/tmp/commission_$U.sh"
  ssh -tt "${SSHOPTS[@]}" "$NFS_SSH" "sudo bash /tmp/commission_$U.sh; rc=\$?; rm -f /tmp/commission_$U.sh; exit \$rc" \
    || die "ZFS phase failed (IPA account exists — fix and re-run, it is idempotent)"
  # legacy-untouched assertion (labsc-mkhome does this itself in svc mode)
  MD5_AFTER="$(nfs_ssh "md5sum /etc/exports" | awk '{print $1}')"
  [ "$MD5_BEFORE" = "$MD5_AFTER" ] || die "/etc/exports CHANGED during provisioning ($MD5_BEFORE -> $MD5_AFTER) — investigate!"
  b "   /etc/exports unchanged — hand-written exports intact"
fi

echo
b "=== DONE: '$U' — uid $UIDN, groups [$USER_GROUPS], quota $QUOTA. Temp password shown above. ==="
echo "Home: $NFS_NAME:$ZFS_MP/$U  (auto-mounts to /home/$U on enrolled ca307 machines)."
echo "Check login policy:  ipa hbactest --user=$U --host=<ca307-host-fqdn> --service=sshd"
