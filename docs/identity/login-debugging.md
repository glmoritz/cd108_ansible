# Login debugging — an IPA user can't log in on a ca307 machine

Work **top to bottom**; each step assumes the ones above pass. Every check runs **on the client**
unless it says otherwise — server-side evidence (`showmount -e`, "the user exists in the web UI")
has repeatedly looked fine while the client was broken.

Useful variables for the commands below:
```bash
U=<login>                                  # a REAL user, never `admin` (it has no NFS home)
H=$(hostname -f)                           # must end in .labscipa.tutu.eng.br
```

## 0. Classify the symptom first

| What the user sees | Most likely layer | Jump to |
|---|---|---|
| `Permission denied` immediately, password surely right | HBAC or wrong password/expired | §4, §5 |
| Login **hangs** 30–90 s, then fails or succeeds | DNS, NIS netgroup, SSSD automount | §1, §3 |
| Logs in but lands in `/` or "Could not chdir to home directory" | autofs / NFS home | §6 |
| Key login refused, password login works | stale SSSD cache / sshd | §7 |
| Worked yesterday, fails today everywhere | IPA server down, clock skew, account locked | §2, §5 |
| Works on one machine, not another | that machine: enrollment, host group, local /home users | §4, §6 |

## 1. DNS — the realm must resolve

```bash
resolvectl query ipa1.labscipa.tutu.eng.br     # → 103.0.1.40
resolvectl query nfs1.labscipa.tutu.eng.br     # → 103.0.1.37
cat /etc/systemd/resolved.conf.d/ipa-split.conf
```
Expect `DNS=103.0.1.40 103.0.1.42` + `Domains=~labscipa.tutu.eng.br`. Campus DNS knows nothing
about the realm; without the split drop-in every Kerberos/SSSD call hangs. Stale `/etc/hosts`
lines pointing at an old IPA IP also knock SSSD offline — `grep -i labscipa /etc/hosts`.

## 2. Server + time

```bash
curl -sk -o /dev/null -w '%{http_code}\n' https://ipa1.labscipa.tutu.eng.br/ipa/ui/   # 200/301
timedatectl | grep synchronized          # yes; Kerberos rejects > 5 min skew
chronyc tracking 2>/dev/null | grep -E 'System time|Leap'
```
If `ipa1` is down, SSSD fails over to `ipa2` **only if** `ipa2` is in the resolver list (§1) and
SRV discovery works (`dig +short _ldap._tcp.labscipa.tutu.eng.br SRV @103.0.1.40`).
From the cd108 VM you can check the server: `ssh` to `ipa1` works; from sigivestserver it never
will (macvtap — not a fault).

## 3. SSSD — does the client see the user?

```bash
getent passwd $U                         # uid must be 500600000–500799999
id $U                                    # groups: expect `students` (or professors/admins)
sudo sssctl domain-status labscipa.tutu.eng.br     # "Online status: Online"
grep -E '^(passwd|group|netgroup|automount):' /etc/nsswitch.conf
```
- **Nothing from `getent`** → `sudo sss_cache -u $U` (or `-E` for all), retry. Still nothing →
  `sudo journalctl -u sssd -n 50`; offline domain → back to §1/§2.
- **uid outside the range** → a **local** user of the same name shadows the IPA one
  (`grep "^$U:" /etc/passwd`). Rename/remove the local account.
- **`netgroup: nis sss`** → change to `netgroup: sss`. `ipa-client-install` leaves NIS in, and
  with no NIS server every login hangs.
- **`automount: sss`** → must be `automount: files` (SSSD's automount responder hangs; we use a
  local map). Then `sudo systemctl restart autofs`.

## 4. HBAC — is the user allowed on this host?

On the cd108 VM (or any enrolled box), with your own ticket:
```bash
kinit <you>
ipa hbactest --user=$U --host=$H --service=sshd      # Access granted: True/False + matched rule
ipa hostgroup-show public-workstations | grep -i "member hosts"
ipa user-show $U | grep -i "member of groups"
```
`allow_all` is **disabled** at labsc, so a user logs in only where a rule says so:
`students-on-public` = group `students` × hostgroup `public-workstations` × all services.
- Host missing from `public-workstations` → `ipa hostgroup-add-member public-workstations --hosts=$H`
  (the enroll playbook does this, best-effort — it can silently fail if `kinit` timed out).
- User not in `students` → `ipa group-add-member students --users=$U`.
- Graphical login (GDM/LightDM/xrdp) uses a **different PAM service** than sshd; test that one
  too (`--service=gdm-password`, `lightdm`, `xrdp-sesman`). A rule with *no* service matches nothing.

The client's own verdict: `sudo journalctl -u sssd --since -10min | grep -i hbac`, or
`/var/log/auth.log` → `pam_sss(sshd:account): Access denied for user $U: 6 (Permission denied)`
= HBAC said no.

## 5. The account itself

```bash
ipa user-status $U          # failed logins, lockout per server
ipa user-show $U --all | grep -iE 'krbpasswordexpiration|nsaccountlock|krblastfailedauth'
```
- **New user, first login** — the temp password must be changed at first login. The Kerberos
  policy's `min-lifetime` blocks a second change for 1 h: if the user fumbled it, reset with
  `ipa user-mod $U --random` and hand them the new one.
- **Locked out** (too many failures) → `ipa user-unlock $U`.
- **Disabled** (`nsaccountlock: TRUE`) → `ipa user-enable $U`.

## 6. The home — logged in but no home

```bash
mount | grep ' /home '                  # autofs on /home?  THIS is the real check
ls /home/$U/ && mount | grep "/home/$U"  # triggers the mount; must show nfs4 from nfs1
cat /etc/auto.master.d/home.autofs /etc/auto.home
awk -F: '$3>=1000 && $6 ~ /^\/home\//' /etc/passwd   # must be EMPTY on a public box
```
- **Any local user with a home under `/home` blocks autofs** from taking `/home` — and nothing
  errors. Relocate them (see runbook §2) and `sudo systemctl restart autofs`. This is the #1
  LABIC failure; the golden's course accounts are exactly this shape.
- autofs reads maps **only at start**: maps written after `systemctl start autofs` → restart it.
- `mount.nfs4: Operation not permitted` → the export lacks `insecure` (NAT'd client). Check on
  sigivestserver: `zfs get sharenfs hdmirror/remotehomes`.
- `mount.nfs4: access denied` → client IP outside `103.0.0.0/19`.
- Home mounts but `Permission denied` inside → ownership: on sigivestserver
  `ls -ldn /export/remotehomes/$U` must show the user's IPA uid (the script chowns by uid).
- No dataset at all → the user was created without running the ZFS step; re-run
  `scripts/commission-user.sh --user $U ...` (idempotent: it skips the IPA part).
- `pam_mkhomedir` enabled on a public box + `root_squash` → login hangs creating the home. It must
  be commented out in `/etc/pam.d/common-session`.

## 7. SSH-specific

```bash
sudo sss_ssh_authorizedkeys $U          # prints the user's keys; EMPTY = stale cache
sudo sshd -T | grep -E 'kbdinteractive|passwordauth|authorizedkeyscommand'
```
- A key added to an existing user is invisible until `sudo sss_cache -u $U` (deleting
  `/var/lib/sss/db/*` does **not** fix it). Needs `sssd-tools`, which `freeipa-client` doesn't pull.
- `ipa-client-install` drops `/etc/ssh/sshd_config.d/04-ipa.conf` with
  `ChallengeResponseAuthentication yes`, which re-enables password login even if the main config
  says no. Trust `sshd -T`, not the files.

## Logs, in order of usefulness

| Where | What it tells you |
|---|---|
| client `/var/log/auth.log` (or `journalctl -t sshd`) | which PAM phase failed (auth vs account vs session) |
| client `journalctl -u sssd` / `/var/log/sssd/sssd_labscipa.tutu.eng.br.log` | offline domain, HBAC denials, Kerberos errors. Raise with `debug_level = 6` under `[domain/...]` in `/etc/sssd/sssd.conf`, restart sssd, reproduce, lower it again |
| client `journalctl -u autofs` | map lookups, NFS mount errors |
| `ipa1` `/var/log/krb5kdc.log` | `PREAUTH_FAILED` (wrong password), `CLIENT_NOT_FOUND`, clock skew |
| `ipa1` `/var/log/dirsrv/slapd-LABSCIPA-TUTU-ENG-BR/access` | LDAP binds/searches from the client |
