# cd108_ansible — DAELT/UTFPR research lab automation

Configuration management for ~50 Ubuntu machines across 4 research labs.

## Philosophy (the phased plan)

The **Clonezilla golden image** carries the current semester. This repo captures
the *config layer* on top of a booted machine so next semester you edit text
instead of clicking. Over time the image gets leaner and the playbook grows.

- **Image owns:** 250 GB **ext4** Ubuntu partition, base OS, heavy proprietary
  binaries for now (MATLAB, Code Composer, TeX).
- **Ansible owns:** everything that varies or changes over time — *and* the
  **ZFS pool** (Clonezilla can't do ZFS), user homes, and lab-specific config.

## Topology

- **`server`** = the professor's PC. It's a *student machine on steroids* (runs
  `common`/`desktop`/`sdr` so the prof demos exactly what students see) **plus**
  the infra hub: NFS server for the shared exchange folder, and holder of the
  **golden ZFS datasets** (per-course homes + the Windows emergency VM) that
  students receive. No Samba, no Squid (dropped as messy). Today it's
  `cd108.tutu.eng.br`; in production it becomes a dedicated **server VM** (IP).
- **`labs`** = the ~50 student machines across 4 labs: **cd108, cd106, cb203,
  ca307**. Only **ca307** joins FreeIPA. Each lab has its own `group_vars` file
  for particularities. Reference the hub via `server_host`.
- **apt cache** currently runs on the professor's **daily driver `103.0.1.16`**
  (transitional); it moves to the server/VM in production.

## Homes & the ZFS reset flow

- Homes are **local ZFS**, one dataset per **course account** (not per student).
- Students upload to the cloud at end of class; homes are reset between
  semesters by **`zfs recv` of a freshly-built golden** from the server — not a
  local `zfs rollback` (rollback breaks vscode: old config vs. updated binary).
- Reset flows **server → student** (matching the prof→student SSH keys) via
  `zfs send | mbuffer -r | ssh student zfs recv -F`, throttled over the break.
- Reset is **`reset-homes.yml`** — deliberate and destructive, never in `site.yml`.

## Layout

```
inventory/hosts.yml        groups: server, lab_a..lab_d, freeipa_members
inventory/group_vars/      server_host, ZFS/NFS/MATLAB/package vars
site.yml                   normal converge (safe to re-run)
reset-homes.yml            DELIBERATE home reset (run by hand over break)
harvest.sh                 run ON the golden machine to capture reality
roles/common/             packages, external repos, users, ssh, grub, tweaks
roles/desktop/            firefox captive-portal bookmark, dconf lockdown, VNC
roles/zfs/                build pool + initial receive of homes/winvm
roles/sdr/                full SDR++/UHD/LibreSDR build (your procedure)
roles/matlab/             NFS mount + campus network license
roles/server/             NFS exchange folder (sticky) + golden datasets
roles/freeipa/            join FreeIPA (only freeipa_members)
```

## Item map (your notes → where it lives)

| Note | Role | Notes |
|---|---|---|
| build-essential, git, nmap, wireshark, tcpdump, gparted, gimp, inkscape, pinta, xournalpp, mosquitto_clients, moserial, openocd, boot-repair | common | plain apt; wireshark debconf preseeded |
| vscode, docker | common | **managed external repos** — key/URL drift = one-file fix |
| enable ssh, prof's key on students | common | passwordless prof→student |
| user per course, docker sem sudo (redes) | common | `redes` → docker group |
| grub (headless) | common | `/etc/default/grub` + update-grub, no GUI tool |
| rename PC por MAC | common | declarative via inventory (TODO harvest) |
| swap, RTC local, ipv6 privacy off, WoL, idle-shutdown cron | common | TODO(harvest) exact values |
| UART kit verify | common | **udev rule** for stable /dev symlink (TODO harvest) |
| firefox captive-portal bookmark | desktop | policies.json (snap path) |
| VNC, prof "clipboard" | desktop | TODO(harvest) |
| wallpaper/desktop lockdown | desktop | **future** — not on the image yet |
| ZFS pool on free space, recv homes + winvm | zfs | Ansible builds pool; throttled recv |
| zfs-auto-snapshot | zfs | installed with pool |
| home reset | reset-homes.yml | deliberate `zfs recv` of golden |
| rtlsdr, pluto, sdr++, uhd, LibreSDR fw | sdr | your full procedure, idempotent |
| matlab (network license) | matlab | NFS mount + license server |
| tex, code composer | (heavy/NFS) | serve over NFS, cache on server |
| NFS exchange "troca" folder | server | mode 1777 sticky = prof files undeletable |
| freeipa join | freeipa | **only ca307**; domain/realm in group_vars/ca307.yml, secret in Vault |

## Dropped / out of scope

- **Samba, Squid** — removed (messy). NFS only.
- **Windows partition mount, /var/tmp symlink, grub-customizer, cluster-ssh** — gone.
- **Windows** is now an **emergency VM** (zfs-received), not dual-boot.
- Disk partitioning + ext4 Ubuntu install stay in the Clonezilla image.

## Settled operational decisions

- **Apt caching:** apt-cacher-ng on the server; clients proxy through it.
- **Heavy builds (SDR++):** built once on the server, artifact distributed to
  students (libs still apt-installed per machine).
- **Home reset cadence:** ~2–3× per semester (not just at break) → `reset-homes.yml`
  supports an incremental `zfs send -i` path to keep repeat resets cheap.

## Workflow

1. **Now:** skeleton + `harvest.sh` ready; package lists + SDR + external repos real.
2. **At UTFPR (SSH):** run `./harvest.sh` on the golden machine; hand back
   `harvest_out/` to fill the remaining TODO(harvest) stubs.
3. `ansible-playbook site.yml --limit <one-test-machine>`, then roll out.

## Phases

- **P1 – capture** (here) · **P2 – Ansible owns what varies** ·
  **P3 – thin the image** · **P4 – image built by Ansible** (optional)
