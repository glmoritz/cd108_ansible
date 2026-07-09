# cd108_ansible — DAELT/UTFPR research lab automation

Configuration management for ~50 Ubuntu machines across 4 research labs.

## Philosophy (the phased plan)

The **Clonezilla golden image** carries the current semester. This repo captures
the *config layer* on top of a booted machine so next semester you edit text
instead of clicking. Over time the image gets leaner and the playbook grows.

- **Image owns:** ext4 Ubuntu partition, base OS, heavy proprietary/local
  binaries for now (MATLAB at `/usr/local/MATLAB`, full TeX; the ST/SEGGER
  stack — STM32CubeIDE/CubeMX, J-Link — rides in the received golden home).
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

- Homes are **local ZFS** (pool `ssdpool`), one dataset per **course account**
  (not per student), each with a separate `Downloads` **child dataset** so bulky
  downloads survive a home reset.
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
roles/desktop/            XFCE + xrdp, firefox captive-portal bookmark, clipboard group
roles/zfs/                build pool + sanoid + initial receive of homes/windows
roles/winvm/              Windows-VM revert wiring: scoped NOPASSWD sudo + launcher
roles/sdr/                full SDR++/UHD/LibreSDR build (your procedure)
roles/matlab/             LOCAL install; Ansible writes the network.lic
roles/server/             NFS exchange folder (sticky) + golden datasets
roles/freeipa/            join FreeIPA (only freeipa_members)
```

## Item map (your notes → where it lives)

| Note | Role | Notes |
|---|---|---|
| build-essential, git, nmap, wireshark, tcpdump, gparted, gimp, inkscape, pinta, xournalpp, mosquitto_clients, moserial, openocd, boot-repair | common | plain apt; wireshark debconf preseeded |
| vscode, docker | common | **managed external repos** — key/URL drift = one-file fix |
| enable ssh, prof's key on students | common | passwordless prof→student |
| user per course, docker sem sudo | common | **all** course accounts + daelt → docker group |
| grub (headless) | common | `/etc/default/grub` + update-grub, no GUI tool |
| rename PC por MAC | common | declarative via inventory hostname (native module) |
| swap, RTC, ipv6 privacy, WoL | common | swap=image swapfile; RTC=UTC (dropped); `use_tempaddr=0`; WoL via 70-wol.rules |
| idle-shutdown cron | — | **doesn't exist** — dropped |
| UART kit verify | common | ST-Link/J-Link/OpenOCD via `*-udev-rules` pkgs; generic UART symlink still TODO |
| firefox captive-portal bookmark | desktop | policies.json (snap path); net-new, not on golden yet |
| xrdp (RDP), prof "clipboard" | desktop | xrdp + `clipboardwriters` group + `ssdpool/clipboard` |
| wallpaper/desktop lockdown | desktop | **future** — not on the image yet |
| ZFS pool on free space, recv homes + windows | zfs | Ansible builds `ssdpool`; throttled recv |
| Windows emergency VM (revert-on-launch) | winvm | templated libvirt domain + NAT DHCP reservation; rolls disk to `@ltspice`; scoped NOPASSWD `zfs rollback`; `Windows VM (Reset)` launcher. Only the qcow2 is image-owned. **RDP password must be vaulted.** |
| sanoid snapshots | zfs | `sanoid.conf` templated (golden's was empty → no-op) |
| home reset | reset-homes.yml | deliberate `zfs recv` of golden |
| rtlsdr, pluto, sdr++, uhd, LibreSDR fw | sdr | your full procedure, idempotent |
| matlab (network license) | matlab | **LOCAL** install; Ansible writes `network.lic` |
| tex, stlink-tools, qucs-s | common | apt install (real packages) |
| STM32CubeIDE/CubeMX, ST-Link server, J-Link | zfs (golden home) | image-owned binaries delivered in the received home; udev rules baked into the image |
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

1. **Done:** harvested the cd108 golden (`cd108-test-01`); vars + roles are now
   grounded in reality (`harvest_out/` is gitignored, not committed).
2. **Next:** add real host entries to `inventory/hosts.yml`, then
   `ansible-playbook site.yml --check --limit <one-test-machine>` (dry run).
3. Converge the one test machine for real, validate, then roll out in waves.

Remaining TODO(harvest) (need a plugged-in device / the server, not the golden):
generic UART-kit stable-symlink udev rule; server-side golden dataset layout;
the xrdp `sesman.ini` clipboard wiring + `ssdpool/clipboard` automount.

## Phases

- **P1 – capture** (here) · **P2 – Ansible owns what varies** ·
  **P3 – thin the image** · **P4 – image built by Ansible** (optional)
