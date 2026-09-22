# LabSC (ca307) identity — FreeIPA + NFS homes

ca307 is the **hybrid** room: its PCs are imaged and converged like every other lab in this repo
(Clonezilla golden → `site.yml`), but its **identity** is the FreeIPA + per-user NFS home stack
rehearsed at LabSC and hardened in production at LABIC. The rest of the fleet (cd108/cd106/cb203)
keeps local per-course accounts.

This directory is the **labsc side of the split** from `labic-infra`. Until 2026-09 both labs'
identity docs and scripts lived in `labic-infra` with a two-column (labsc | LABIC) parameter table.
LABIC now has its own realm (`LABIC.INTERNAL`) and its own admin host (`ops`), so labsc material
lives here, next to the machines it manages, and is run from the **cd108 VM** (labsc's equivalent
of LABIC's `ops`).

| Doc | Use it to… |
|---|---|
| [`login-debugging.md`](login-debugging.md) | **someone can't log in** — the ladder, top to bottom |
| [`runbook.md`](runbook.md) | enroll a machine, create users, HBAC, backups, rebuild notes |
| [`../manuais/criar-novo-usuario.md`](../manuais/criar-novo-usuario.md) | manual (pt-BR) for whoever creates accounts |
| [`../../scripts/commission-user.sh`](../../scripts/commission-user.sh) | the user-creation tool |
| [`../../identity/enroll-lab-client.yml`](../../identity/enroll-lab-client.yml) | the client enrollment playbook (standalone, not in `site.yml` yet) |

## Parameters

| Item | Value |
|---|---|
| Realm / domain | `LABSCIPA.TUTU.ENG.BR` / `labscipa.tutu.eng.br` |
| IPA primary | `ipa1.labscipa.tutu.eng.br` = `103.0.1.40` — VM `ipa-server` on **sigivestserver** (Rocky 10, IPA 4.13) |
| IPA replica | `ipa2.labscipa.tutu.eng.br` = `103.0.1.42` — VM on **moritzpc** (full CA + DNS replica) |
| ID range | `500600000`–`500799999` (LABIC uses `500800000`+ on purpose — uids never collide) |
| NFS home server | **sigivestserver** (`nfs1.labscipa.tutu.eng.br` → `103.0.1.37`) |
| Home datasets | `hdmirror/remotehomes/<user>` → `/export/remotehomes/<user>`, `refquota` 10G default |
| Export | ZFS `sharenfs="rw=@103.0.0.0/19,root_squash,no_subtree_check,insecure"` (sec=sys) |
| HBAC | `students-on-public` (students → hostgroup `public-workstations`); `allow_all` **disabled** |
| Admin host | **cd108 VM** (`cd108.tutu.eng.br` = `103.0.1.43`, also on sigivestserver) |
| Campus DNS | `200.134.25.49` (IPA forwards to it) |

Credentials are offline (KeePass). Never commit them.

## Topology — the reachability rules that bite

```
                  campus LAN 103.0.0.0/19
   ───────┬──────────────┬──────────────────────┬──────────────┬──────────
          │ .37          │ .40 (macvtap)         │ .43 (macvtap) │ .42
   sigivestserver ── ipa-server VM          cd108 VM          ipa2 (moritzpc)
   (ZFS homes, NFS)                             │ ens2 192.168.122.150
          │ virbr0 192.168.122.1 ───────────────┘   (libvirt NAT)
```

- **macvtap blocks guest ↔ own host.** sigivestserver cannot reach `ipa1` (103.0.1.40), and the
  cd108 VM cannot reach sigivestserver at `103.0.1.37`. From the cd108 VM, reach the host at
  **`192.168.122.1`** (virbr0). Guest ↔ guest (cd108 VM ↔ ipa1) works.
- The cd108 VM reaches both IPA servers (443/88/53 verified 2026-09-22).
- Lab machines on the campus LAN reach everything directly.

## Status (2026-09-22)

- IPA, replica, homes, HBAC: live since 2026-07 (rehearsal, now going to real use).
- Existing IPA homes: `glmoritz`, `roliveira`, `testuser`, `yribeiro`.
- **cd108 VM is NOT yet enrolled** in the realm — the user script needs that (runbook §1).
- **ca307 has no hosts in `inventory/hosts.yml` yet**, and `roles/freeipa` is still a stub.
  Enrolled so far (outside this inventory): `pubws1`, labsc06, labsc11, labsc17.
- **sigivestserver lost its IP on 2026-09** after a kernel update: `scripts/fix-e1000e-hang.sh`'s
  `.link` file replaced the default NIC-naming policy, so the NIC came up as `eth0`. Fixed on the
  host (now `enp0s31f6` again) and in `scripts/fix-e1000e-hang.sh` (restates `NamePolicy`,
  rebuilds the initramfs).

## TODO — on site (next visit to ca307)

In order. Each item says what's already prepared in the repo.

1. **Yago's login loop** — `yribeiro` types the password at the Ubuntu login, the session starts
   and drops back to the greeter; GDM does show his full name, so NSS/SSSD↔IPA works.
   Ruled out remotely on 2026-09-22 (on labsc06, same realm): account resolves (uid 500600009,
   group `students`), **HBAC allows** him for `gdm-password` and `sshd` (`sssctl user-checks`),
   his NFS home mounts (20G) and is **writable as him**. But the home has never held a session
   (no `.cache`/`.config`) and labsc06's logs show no attempt by him — **the failing PC is a
   different one**. NFS server logs point at `103.0.2.12` (no SSH answer) or `103.0.2.14` (host
   key changed — probably reflashed; none of our keys log in).
   **Top suspect:** on that PC autofs never took `/home` (a local user in `/home`, or it wasn't
   enrolled as `public`) → `/home/yribeiro` missing → GDM aborts the session. On that PC:
   ```
   mount | grep ' /home '; ls -ld /home/yribeiro; getent passwd yribeiro
   sudo journalctl -b | grep -iE 'yribeiro|gdm|pam_sss' | tail -40
   ```
   then walk [`login-debugging.md`](login-debugging.md) §0. Also add our deploy key to that PC.
2. **Enroll the cd108 VM** — dry run clean (2026-09-22). Get a one-time host password
   (IPA web UI: Hosts → Add `cd108.labscipa.tutu.eng.br` → Generate OTP, or
   `ipa host-add cd108.labscipa.tutu.eng.br --random --force`), then runbook §1.
   Then: HBAC for admins on the admin host (runbook §0.2) and the `labsc-mkhome` key (§3).
3. **Relocate local homes on ca307 PCs** (golden course accounts out of `/home`, NFS gets `/home`).
   Prepared: `identity/relocate-local-homes.sh` (moves ZFS homes by mountpoint, dataset passed
   explicitly, refuses on non-ca307 hostnames). **Untested.** Still to write:
   `identity/relocate-local-homes.yml` (runs the script as a detached systemd unit so the Ansible
   session's cwd doesn't pin the home; reconnects to verify), and a `local_home_base` var
   (`/home` default, `/var/local/home` for ca307) used by `roles/zfs` + `roles/common`, which
   today hard-code `/home` and would move the homes back on the next converge.
   Test on ONE ca307 PC (or a disposable VM with its own disk) — **never on moritzpc**, whose
   `ssdpool/home` is the live `/home`.
4. **labsc06 cleanup** — the old enroll playbook `mv`'d `labsc`'s home to `/var/local/labsc`
   (ext4 copy) while ZFS `homepool/home/labsc` stays mounted, hidden, at `/home/labsc`. Two
   copies; decide which is current before touching either. (Installed `sssd-tools` there
   2026-09-22 for `sssctl`.)
5. **Decide the hostname rule** for enrolled hosts (`common` sets the short name, IPA sets the
   FQDN — runbook §1), then write `roles/freeipa` from `identity/enroll-lab-client.yml` and add
   the ca307 hosts to `inventory/hosts.yml`.
6. **ipa2 host key changed** (seen from moritzpc 2026-09-22) — confirm it was a rebuild, not
   something else, before trusting it.

## Decided 2026-09-22 — ca307 homes vs the golden's local accounts

The golden image has local course accounts (`estudante`, `redes`, `microcontroladores`, `daelt`)
with homes on `ssdpool/home` **under `/home`**. A local user living in `/home` silently blocks
autofs from serving `/home` from NFS (LABIC hit it four times: autofs reports active, only
`mount | grep ' /home '` shows it never took over).

**Decision:** on ca307, **the NFS mount owns `/home`; local accounts move elsewhere**
(`/var/local/home/<u>`), done by a separate playbook before enrollment (TODO item 3).
`identity/enroll-lab-client.yml` roles: `public` (ca307 PCs), `admin` (the cd108 VM),
`professor` (a personal box that keeps its local `/home`).
