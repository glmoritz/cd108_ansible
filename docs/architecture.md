# Architecture — how the lab automation fits together

Read this once before touching anything. The runbooks in
[`runbooks.md`](runbooks.md) assume you understand the pieces below.

## The big picture

```
                    ┌──────────────────────────────────────────┐
   control node     │  moritz-pc  (103.0.1.16)                  │
   = where YOU run  │  • runs ansible-playbook                  │
     ansible        │  • holds the deploy key (~/.ssh/id_cd108_ansible)
                    │  • hosts the server as a VM (libvirt)     │
                    └───────────────┬──────────────────────────┘
                                    │ manages over SSH
                 ┌──────────────────┴───────────────────┐
                 ▼                                       ▼
   ┌───────────────────────────┐        ┌───────────────────────────────┐
   │  server = cd108-server VM │        │  labs = ~50 student machines   │
   │  (Ubuntu 26.04, on NAT)   │        │  cd108 / cd106 / cb203 / ca307 │
   │  • apt-cacher-ng          │  zfs   │  • local ZFS pool `ssdpool`    │
   │  • NFS "troca" exchange   │ send/  │  • homes received from server  │
   │  • golden ZFS store ──────┼─recv──►│  • Windows emergency VM        │
   │  • builds SDR++ once      │        │  • only ca307 joins FreeIPA    │
   └───────────────────────────┘        └───────────────────────────────┘
```

There are **three kinds of machine**. Keep them straight:

| Role | What it is | How you reach it |
|------|-----------|------------------|
| **control node** | `moritz-pc`, `103.0.1.16`. Where you run `ansible-playbook`. Also the KVM host that runs the server VM. | you're already on it |
| **server** | `cd108-server`, an Ubuntu 26.04 **VM** on the control node. The infra hub. Inventory name `cd108.tutu.eng.br`. | deploy key → `daelt@192.168.122.150` (NAT) |
| **lab machine** | one of ~50 student PCs in labs cd108/cd106/cb203/ca307. | deploy key → MAC-derived IPv6 (see *Addressing*) |

## The two-layer model (image vs Ansible)

The lab machines are **not** installed by Ansible. They're cloned from a
**Clonezilla golden image**. Ansible adds the *configuration layer* on top.

- **The image owns:** the ext4 Ubuntu partition, the base OS, and heavy
  proprietary binaries (MATLAB at `/usr/local/MATLAB`, full TeX; the ST/SEGGER
  toolchain — STM32CubeIDE/CubeMX, J-Link — rides in the received home).
- **Ansible owns:** everything that changes semester to semester, **plus** the
  ZFS pool (Clonezilla can't make ZFS), the user homes, and per-lab config.

The long-term plan is to thin the image and grow the playbook, but today both
matter. If something is missing after a converge, ask: *is this the image's job
or Ansible's?*

**Imaging is out-of-band.** Clonezilla runs from its own live environment, so a
machine must **reboot into Clonezilla** to be imaged — you can't do it from the
running OS or remotely from the control node. Clonezilla lays down the ext4
system partition and leaves an empty, labelled `zfs` partition; Ansible then
builds the pool and receives the homes. See
[`runbooks.md` → Re-image a machine](runbooks.md#re-image-a-machine-clonezilla).

## Addressing — no fixed IPs, no registry

Lab IPs are **not fixed** and there is **no external host registry**. Instead we
address each machine by the one thing that's stable and known before any config:
its **MAC**, recorded per host in `inventory/hosts.yml`.

Because IPv6 privacy extensions are disabled (`use_tempaddr=0`, set by the
`common` role), a machine's lower-64 address bits are a deterministic **EUI-64**
derived from its MAC. So `filter_plugins/net.py` computes each host's routable
IPv6 as `lab_ipv6_prefix + EUI-64` (prefix `2801:82:c004:103::`), and
`group_vars/labs.yml` sets that as `ansible_host`. See the filter and
`inventory/group_vars/labs.yml`.

Why this matters: a freshly-imaged clone still carries the golden's hostname, so
you *can't* address it by name (they'd collide). But its MAC — and therefore its
IPv6 — is unique and reachable immediately. This dissolves the
"name-it-before-you-can-reach-it" bootstrap. A per-host `ansible_host` override
(e.g. a pinned IPv4) always wins, which is how the golden box and the NAT server
are reached today.

## Golden distribution — how homes and the Windows VM get to students

1. A **reference machine** (the "golden", currently `cd108-test-01`) holds the
   canonical state: per-course homes under `ssdpool/home/<course>` (each with a
   `Downloads` child so downloads survive a reset) and the Windows emergency VM
   at `ssdpool/windows`.
2. `harvest-golden.yml` snapshots those `@golden` and `zfs send`s them to the
   **server's** `ssdpool/golden/*` store.
3. `roles/zfs` (during `site.yml`) `zfs send`s each course home and the Windows
   VM from the server onto each student machine, **N machines at a time**
   (`throttle`/`serial` = `zfs_send_concurrency`, *not* a bandwidth cap).
4. Between semesters, `reset-homes.yml` re-sends a clean golden home (a
   deliberate, destructive `zfs recv`, never part of `site.yml`).

The Windows VM reverts to its `@ltspice` snapshot on every launch, so students
always get a clean teaching baseline (see `roles/winvm`).

## Snapshots

Homes are snapshotted by **sanoid** (installed with the pool): every 15 min,
hourly, daily, weekly, monthly (`sanoid_retention` in `group_vars/all.yml`,
rendered by `roles/zfs/templates/sanoid.conf.j2`). This is a safety net for
accidental deletions between the heavier golden resets.

## Access & secrets

- **Deploy key** — `~/.ssh/id_cd108_ansible` on the control node (passphrase-less
  ed25519). All unattended/overnight Ansible runs authenticate with it; the
  `common` role installs its public half on every admin account. Your personal
  passphrase-protected key can't sign non-interactively, which is why this
  exists. See [`runbooks.md` → Keys & secrets](runbooks.md#keys--secrets).
- **Vault** — secrets (the Windows RDP password, cd108 specifics) live in
  ansible-vault files (`inventory/group_vars/cd108/vault.yml`), never plaintext.
- **Sudo** — the server's `daelt` has passwordless sudo. The reference golden
  still needs a sudo password (it isn't Ansible-managed yet).

## Where things live

```
ansible.cfg                inventory dir, deploy key, roles/filter paths
site.yml                   normal converge (safe to re-run) — server + labs plays
prepare-server.yml         converge ONLY the hub services onto the server
provision-server-vm.yml    build the server VM from scratch (autoinstall)
harvest-golden.yml         snapshot the reference machine → server golden store
reset-homes.yml            DELIBERATE, destructive home reset (run by hand)
filter_plugins/net.py      MAC → EUI-64 IPv6 address filter
inventory/hosts.yml        static inventory: server + the 4 lab groups + hosts
inventory/group_vars/      all.yml (central vars) + labs.yml (addressing) + cd108/ (vault)
provisioning/server-vm/    autoinstall templates for the server VM
roles/common/              packages, repos, users, ssh, hostname, WoL, ipv6, deploy key
roles/desktop/             XFCE + xrdp, firefox captive-portal bookmark, clipboard group
roles/zfs/                 build pool + sanoid + receive homes/windows (N at a time)
roles/winvm/               Windows emergency VM: revert wiring + launcher
roles/sdr/                 build SDR++/UHD/LibreSDR once on server, distribute
roles/matlab/              local MATLAB; Ansible writes network.lic
roles/server/              apt-cacher-ng, NFS troca, ZFS golden pool + sharenfs
roles/freeipa/             join FreeIPA (only ca307)
```
