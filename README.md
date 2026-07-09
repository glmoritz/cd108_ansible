# cd108_ansible — DAELT/UTFPR research lab automation

Configuration management for ~50 Ubuntu machines across 4 research labs
(**cd108, cd106, cb203, ca307**), plus the infra server that feeds them.

## 📖 Documentation — start here

| If you want to… | Read |
|---|---|
| **Understand how it all fits** (read this first) | [`docs/architecture.md`](docs/architecture.md) |
| **Do a task** — provision the server, harvest goldens, add a machine, converge, reset homes | [`docs/runbooks.md`](docs/runbooks.md) |
| **Fix something that broke** | [`docs/troubleshooting.md`](docs/troubleshooting.md) |

New here? Read the architecture doc, then follow **Day one** in the runbooks.

## What this is, in three sentences

Lab machines are cloned from a **Clonezilla golden image**; this repo adds the
**configuration layer** on top (packages, users, the ZFS pool, homes, per-lab
settings) so next semester you edit text instead of clicking. The **server** (an
Ubuntu VM) is the hub: apt cache, NFS exchange, the golden ZFS store, and the
SDR++ build. Machines have **no fixed IPs** — they're addressed by an IPv6
derived from their MAC (see the architecture doc).

## Quick reference — the playbooks

```
site.yml                 normal converge, safe to re-run (server + lab machines)
prepare-server.yml       just the server hub services (apt-cache, NFS, ZFS golden)
provision-server-vm.yml  build the server VM from the Ubuntu ISO (unattended)
harvest-golden.yml       snapshot the reference machine → server golden store
reset-homes.yml          DELIBERATE, destructive home reset (run by hand, not in site.yml)
```

Golden rules: **always `--check --diff` and `--limit` one machine first**;
`reset-homes.yml` wipes homes so confirm students have saved; automation uses the
deploy key `~/.ssh/id_cd108_ansible`.

## Repo layout

```
ansible.cfg              inventory dir, deploy key, roles/filter plugin paths
inventory/hosts.yml      static inventory: server + the 4 lab groups + their hosts
inventory/group_vars/    all.yml (central vars), labs.yml (MAC→IPv6 addressing), cd108/ (+vault)
filter_plugins/net.py    MAC → EUI-64 IPv6 address filter
provisioning/server-vm/  autoinstall templates for the server VM
roles/common/            packages, external repos, users, ssh + deploy key, hostname, WoL, ipv6
roles/desktop/           XFCE + xrdp, firefox captive-portal bookmark, clipboard group
roles/zfs/               build pool + sanoid snapshots + receive homes/windows (N at a time)
roles/winvm/             Windows emergency VM: revert-to-@ltspice wiring + launcher
roles/sdr/               build SDR++/UHD/LibreSDR once on the server, distribute artifact
roles/matlab/            local MATLAB; Ansible writes the network.lic
roles/server/            apt-cacher-ng, NFS "troca" exchange, ZFS golden pool + sharenfs
roles/freeipa/           join FreeIPA (only ca307)
```

## Item map (original notes → where it lives)

| Note | Role | Notes |
|---|---|---|
| build-essential, git, nmap, wireshark, tcpdump, gparted, gimp, inkscape, pinta, xournalpp, mosquitto-clients, moserial, openocd | common | plain apt; wireshark debconf preseeded |
| vscode, docker | common | managed external repos — key/URL drift = one-file fix |
| enable ssh, deploy key on admins | common | passwordless control-node → machine |
| user per course, docker without sudo | common | course accounts + daelt → docker group |
| grub (headless), hostname from inventory | common | native modules, no GUI tools |
| ipv6 privacy off, WoL | common | `use_tempaddr=0` (enables EUI-64 addressing); WoL udev rule per NIC |
| firefox captive-portal bookmark, xrdp, clipboard group | desktop | policies.json; `clipboardwriters` + `ssdpool/clipboard` |
| ZFS pool, receive homes + windows, sanoid | zfs | Ansible builds `ssdpool`; receive N at a time; sanoid 15min/hourly/daily/… |
| Windows emergency VM (revert-on-launch) | winvm | libvirt domain + NAT DHCP reservation; rolls disk to `@ltspice`; scoped NOPASSWD `zfs rollback`; RDP password **vaulted** |
| rtlsdr, pluto, sdr++, uhd, LibreSDR fw | sdr | built once on server, artifact distributed |
| matlab (network license) | matlab | local install; Ansible writes `network.lic` |
| tex, stlink-tools, qucs-s | common | apt install (real packages) |
| STM32CubeIDE/CubeMX, ST-Link server, J-Link | zfs (golden home) | image-owned, delivered in the received home; udev rules baked into the image |
| apt cache, NFS "troca", golden ZFS store | server | apt-cacher-ng (http only); troca mode 1777 sticky; `ssdpool/golden` shared to the lab subnet |
| freeipa join | freeipa | only ca307 |

## Dropped / out of scope

Samba, Squid, Windows dual-boot (now an emergency VM), `/var/tmp` symlink,
grub-customizer, cluster-ssh, idle-shutdown cron. Disk partitioning + the ext4
Ubuntu install stay in the Clonezilla image.

## Status

The server VM (`cd108-server`, Ubuntu 26.04) is up and Ansible-managed; its hub
services (apt-cacher-ng, NFS, ZFS golden store) are configured; the reference
golden has been harvested into it. Next: add real lab hosts to the inventory and
converge them in waves (see the runbooks). Longer term: bridge the server onto
the lab LAN, and thin the Clonezilla image as Ansible takes over more.
