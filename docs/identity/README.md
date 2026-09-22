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
  host (now `enp0s31f6` again); the script fix is in the working tree of this repo.

## Open design question — ca307 homes vs the golden's local accounts

The golden image has local course accounts (`estudante`, `redes`, `microcontroladores`) with homes
on `ssdpool/home` **under `/home`**, and `daelt` at `/home/daelt`. An IPA "public" workstation
mounts `/home` from NFS via autofs — **a local user living in `/home` silently blocks that**
(LABIC hit it four times: autofs reports active, only `mount | grep ' /home '` shows it never took
over). Before `roles/freeipa` is written, decide per ca307 machine:

- **public** — IPA users own `/home`; local accounts move out (e.g. `/var/local/<u>`), or
- **professor-style** — local `/home` untouched, lab homes side-mounted at `/mnt/labhomes`.

`identity/enroll-lab-client.yml` implements both (`machine_role=public|professor`).
