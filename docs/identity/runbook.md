# LabSC identity runbook — admins, users, machines

Parameters and topology: [`README.md`](README.md). When a login fails:
[`login-debugging.md`](login-debugging.md).

---

## 0. Who does what — named IPA admins, like LABIC

Lesson carried over from LABIC: **nobody works as the shared `admin`.** Every administrator has
their own IPA account in the `admins` group, logs into the **cd108 VM** with it, runs `kinit <self>`,
and every IPA change is audited under their name. `admin`'s password goes to KeePass as break-glass.

| Who | Where they act | What they can do |
|---|---|---|
| `admins` (IPA group) | cd108 VM, own account + own ticket | create/modify any user, groups, HBAC, hosts |
| `interns` (not built at labsc yet) | same | LABIC design: create **students only** via a scoped RBAC role — see §6 |
| `students` | ca307 workstations (HBAC `students-on-public`) | log in, nothing else |

The NFS side follows the same rule: admins do **not** get personal accounts on sigivestserver.
The cd108 VM holds one forced-command key that can only run `labsc-mkhome` there (§3).

### 0.1 Create an admin (once per person, by an existing admin)
```bash
kinit <you>
scripts/commission-user.sh --user <login> --first <F> --last <L> --groups admins --quota 20G
ipa group-show admins                     # read it back — ipa exits 0 even when it did nothing
```

### 0.2 Admins may log into the cd108 VM (HBAC)
`allow_all` is disabled at labsc, so admins need an explicit rule for the admin host. Check first —
the rehearsal only built `students-on-public`:
```bash
ipa hbacrule-find                                    # is there already an admins rule?
ipa hostgroup-add admin-hosts --desc="LabSC admin hosts (cd108 VM)"
ipa hostgroup-add-member admin-hosts --hosts=cd108.labscipa.tutu.eng.br
ipa hbacrule-add admins-on-admin-hosts --servicecat=all
ipa hbacrule-add-user admins-on-admin-hosts --groups=admins
ipa hbacrule-add-host admins-on-admin-hosts --hostgroups=admin-hosts
ipa hbacrule-show admins-on-admin-hosts --all        # read back: users, hosts, service category
ipa hbactest --user=<an-admin> --host=cd108.labscipa.tutu.eng.br --service=sshd   # True
ipa hbactest --user=<a-student> --host=cd108.labscipa.tutu.eng.br --service=sshd  # False
```
`--hostgroups` takes **one** name; to add several, repeat the option. A comma list is looked up
as a single literal name, adds nothing, and still exits 0 (a LABIC trap).

---

## 1. Enroll the cd108 VM (the admin host) — PENDING

The user script needs the `ipa` CLI and SSSD on the cd108 VM. Not enrolled yet (checked
2026-09-22). Enroll it with **`machine_role=admin`**: IPA login + `ipa` CLI, no automount, `/home`
untouched (`daelt` lives there). Not `professor`: its `/mnt/labhomes` automount points at `nfs1`
(103.0.1.37), which the VM can't reach (macvtap), so it would only hang.

Use a **one-time host password** instead of handing out an admin password:
```bash
# an admin, anywhere enrolled (or web UI: Hosts → Add → Generate OTP):
ipa host-add cd108.labscipa.tutu.eng.br --random --force        # prints the OTP
# from the control node:
ansible-playbook identity/enroll-lab-client.yml -e target=server -e machine_role=admin \
  -e pc_name=cd108 -e ipa_otp='<otp>' -e ipa_admin_password='' --limit cd108.tutu.eng.br
```
(Dry run 2026-09-22 with `--check`: hostname → `cd108.labscipa.tutu.eng.br`, `/etc/hosts`
127.0.1.1 line, split-DNS drop-in, apt proxy file, `netgroup: nis` → `sss`, sssd dyndns on
`ens7`; the only failure was check-mode's "autofs service not found", expected before install.)
Then do §0.2 and install `sssd-tools` there (`sss_cache`).

**Done 2026-09-30.** Two things found on the way, both now handled in the repo:
- **sudo-rs:** Ubuntu 26.04's default `/usr/bin/sudo` is sudo-rs, which ignores SSSD, so
  `sysadmins-sudo` didn't apply ("I'm sorry glmoritz. I'm afraid I can't do that"). The enroll
  playbook now switches 25.10+ hosts to classic sudo (`update-alternatives --set sudo
  /usr/bin/sudo.ws`). Undo: `update-alternatives --auto sudo`.
- **Hostname:** enrollment sets the FQDN; `roles/common` now leaves the hostname alone on any
  host with `/etc/ipa/default.conf`, so converges no longer flip it back to `cd108`.
- The enrolled VM has no home for IPA admins (role `admin` = no mkhomedir/automount): create one
  per admin once, as `daelt`: `sudo mkhomedir_helper <login> 0077`.
- `sysadmins-everywhere` (HBAC) + `sysadmins-sudo` already cover login + sudo here, so §0.2's
  `admins-on-admin-hosts` rule is only needed for an admin who is NOT in `sysadmins`.

---

## 2. Enroll a ca307 workstation

The playbook `identity/enroll-lab-client.yml` covers everything learned at labsc and LABIC:
split-DNS, no `--mkhomedir`, `netgroup: sss`, local autofs map, dyndns, adding the host to
`public-workstations`, and relocating local users out of `/home`.
```bash
ansible-playbook identity/enroll-lab-client.yml -e target=ca307 \
  -e machine_role=public -e pc_name=ca307-NN --limit ca307-NN
```
ca307 gets **nothing golden** (decided 2026-09-30): no golden homes, no Windows VM; the course
accounts get fresh homes under `/var/local/home` (README §"Decided 2026-09-30"). A PC imaged
**before** that still has `ssdpool/home` mounted at `/home` (plus `ssdpool/windows`): **before
running on it**, destroy both from the console — README §TODO item 3.
⚠️ The enroll playbook's own `public` relocation does a plain `mv /home/<u> /var/local/<u>`:
on a ZFS-backed home that **copies** the data and leaves the dataset mounted underneath
(what happened on labsc06). Relocate first, so that step finds nothing to do.

**Verify on the client, never from the server:**
```bash
mount | grep ' /home '                   # autofs owns /home
ssh <real-student>@ca307-NN 'pwd; df -h ~'   # lands in /home/<u> from nfs1
sudo sshd -T | grep kbdinteractive       # ipa-client-install may have re-enabled passwords
```
Afterwards: `ipa hostgroup-show public-workstations` must list the host. The playbook adds it
best-effort and **can silently fail**. If it's missing, add it by hand.

---

## 3. One-time: the `labsc-mkhome` path (admins create homes without sudo on sigivestserver)

Needs someone with sudo on sigivestserver **once**:
```bash
# on sigivestserver
sudo install -m 0755 labsc-mkhome /usr/local/sbin/labsc-mkhome      # from identity/labsc-mkhome
sudo useradd --system --create-home --home-dir /var/lib/svc-mkhome --shell /bin/bash svc-mkhome
echo 'svc-mkhome ALL=(root) NOPASSWD: /usr/local/sbin/labsc-mkhome' | sudo tee /etc/sudoers.d/svc-mkhome
sudo chmod 0440 /etc/sudoers.d/svc-mkhome && sudo visudo -c

# on the cd108 VM (after §1, so the IPA group `admins` resolves)
sudo install -d -m 0755 /etc/labsc
sudo ssh-keygen -t ed25519 -N '' -C cd108-vm-mkhome -f /etc/labsc/mkhome_ed25519
sudo chgrp admins /etc/labsc/mkhome_ed25519 && sudo chmod 0640 /etc/labsc/mkhome_ed25519
sudo cat /etc/labsc/mkhome_ed25519.pub

# back on sigivestserver: the key can run ONLY the helper, only from the cd108 VM's NAT address
sudo install -d -m 0700 -o svc-mkhome -g svc-mkhome /var/lib/svc-mkhome/.ssh
echo 'restrict,from="192.168.122.150",command="/usr/local/sbin/labsc-mkhome" <PUBKEY>' \
  | sudo tee /var/lib/svc-mkhome/.ssh/authorized_keys
sudo chown svc-mkhome: /var/lib/svc-mkhome/.ssh/authorized_keys
```
The key file is owned by root and readable by the `admins` group. ssh only rejects a
group-readable key when the reader owns it, so IPA admins can use it and students can't read it.
Check `AllowUsers`/`AllowGroups` in sigivestserver's `sshd_config` too.
Test: `ssh -i /etc/labsc/mkhome_ed25519 svc-mkhome@192.168.122.1 id` must be **refused** (only
`mkhome ...` is allowed). The helper's own guards: uid/gid inside labsc's IPA range, an existing
home is never re-chowned, and `/etc/exports` is fingerprinted before and after the run.

Until this exists, `commission-user.sh` falls back to your own sudo account on sigivestserver
(`NFS_SSH=<you>@192.168.122.1`).

---

## 4. Create a user (day to day)

On the cd108 VM, as yourself:
```bash
kinit <you>
scripts/commission-user.sh                         # interactive
scripts/commission-user.sh --user jsilva --first João --last Silva \
  --groups students --quota 10G --ra 1234567 --email jsilva@alunos.utfpr.edu.br --yes
```
What it does: checks this host is in `LABSCIPA`, creates the user with a **random temp password**
(printed once, forced change at first login), sets the groups, resolves the uid through SSSD and
checks it falls in the labsc range, then creates `hdmirror/remotehomes/<u>` with its quota,
`/etc/skel`, owner, and mode `700`. Re-running is safe: an existing user or home is left as is and
only the quota is re-applied. Step-by-step manual (pt-BR):
[`../manuais/criar-novo-usuario.md`](../manuais/criar-novo-usuario.md).

Other day-to-day tasks:
```bash
ipa user-mod <u> --random            # reset password (new temp one printed)
ipa user-unlock <u>                  # after too many failures
ipa user-disable <u>                 # end of term; home stays on ZFS until reclaimed
ipa hbactest --user=<u> --host=<fqdn> --service=sshd
```

---

## 5. Backups

`ipa-backup` is **offline**, so it causes a ~30 s IPA outage. Losing the CA is unrecoverable. Today
the tool is still `labic-infra/scripts/ipa-backup-pull.sh`, run from moritzpc (it hard-codes
`moritz@103.0.1.40`). It moves here once the cd108 VM is the admin host. The replica `ipa2`
protects against losing hardware, but not against a bad change, because a bad change replicates.
Homes: sanoid/syncoid on `hdmirror/remotehomes` is still **not configured**.

---

## 6. Interns creating students (RBAC) — design only, not built at labsc

LABIC's model: an `Intern` role → privilege `Student Management` → three scoped permissions:
add users; modify users with target filter `(!(memberOf=cn=admins,…))`; manage members of the
`students` group **only**. The stock *User Administrator* role is **not** used, because it can
reset `admin`'s password. At LABIC the first build **created empty permissions while exiting 0**.
Build it by reading every object back, and verify adversarially **as the intern**. These must FAIL:
`ipa group-add-member admins --users=<self>`, `ipa group-add-member interns --users=<x>`,
`ipa user-mod <an-admin> --first=X`, `ipa passwd admin`. Reference:
`labic-infra/runbooks/hbac-access-control.md` §6.

---

## 7. Rebuild notes (if the realm is ever rebuilt)

- A realm **cannot be renamed**. Use a replica for the same realm; a fresh realm means re-applying
  config and moving homes with `zfs send`.
- The id range was **not pinned** at install; the default happened to land at `500600000`. Pin it
  on any rebuild: `--idstart=500600000 --idmax=500799999`. It must never overlap LABIC's `500800000+`.
- Set the forwarder to campus `200.134.25.49`, not 8.8.8.8, so clients can resolve realm + campus.
- `--no-reverse` and `--no-ntp` were used. Time sync is a prerequisite for Kerberos. Check it.
- Full historical build log: `labic-infra/docs/lab-identity-runbook.md` (labsc column) and
  `labic-infra/docs/logbook.md` §1–§4d.
