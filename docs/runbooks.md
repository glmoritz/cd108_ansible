# Runbooks — step-by-step procedures

Practical, copy-pasteable procedures. Read [`architecture.md`](architecture.md)
first so the commands make sense. Run everything from the repo root on the
**control node** (`moritz-pc`) unless a step says otherwise.

Jump to: [Day one](#day-one-first-time-setup) · [Keys & secrets](#keys--secrets)
· [Build the server VM](#build-or-rebuild-the-server-vm) · [Prepare the
server](#prepare-the-server-services) · [Harvest goldens](#harvest-the-goldens)
· [Add a lab machine](#add-a-lab-machine) · [Re-image
(Clonezilla)](#re-image-a-machine-clonezilla) ·
[Converge](#converge-a-machine-siteyml) · [Reset
homes](#reset-homes-destructive) · [Windows VM](#the-windows-emergency-vm) ·
[Everyday changes](#everyday-changes)

---

## Day one (first-time setup)

You need this on the control node:

1. **Ansible + collections + tools**
   ```bash
   sudo apt install ansible ansible-lint python3-libvirt xorriso sshpass
   ansible-galaxy collection install community.general community.libvirt ansible.posix
   ```
2. **The deploy key** must exist at `~/.ssh/id_cd108_ansible` (see
   [Keys & secrets](#keys--secrets) if it's missing).
3. **The vault password** for the encrypted cd108 secrets. Store it somewhere
   Ansible can read, e.g. `~/.vault_pass` (chmod 600), or type it with
   `--ask-vault-pass`. `.vault_pass` is gitignored — never commit it.
4. **Verify you can reach the server:**
   ```bash
   ansible server -m ping        # expect: cd108.tutu.eng.br | SUCCESS ... "ping": "pong"
   ```
   If this fails, see [Troubleshooting → can't SSH](troubleshooting.md#server-accepts-key-then-permission-denied).

---

## Keys & secrets

### The deploy key (fleet authentication)

Ansible authenticates to every machine with a **passphrase-less** ed25519 key so
unattended/overnight runs work without a human. It lives at
`~/.ssh/id_cd108_ansible` and is wired in `group_vars/all.yml`
(`ansible_ssh_private_key_file` + `professor_ssh_pubkey`).

If you ever need to recreate it:
```bash
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_cd108_ansible -C "cd108-ansible-control-node"
# then update professor_ssh_pubkey in inventory/group_vars/all.yml to the new .pub,
# and re-run site.yml so every machine authorizes the new key.
```
The public half is baked into new server/golden builds via the autoinstall
templates, and installed on running machines by `roles/common`.

### The vault (secrets)

Secrets never go in the repo as plaintext. They're in ansible-vault files, e.g.
`inventory/group_vars/cd108/vault.yml` (holds `winvm_rdp_password`).

```bash
ansible-vault view inventory/group_vars/cd108/vault.yml     # look
ansible-vault edit inventory/group_vars/cd108/vault.yml     # change
```
Any play that touches cd108 hosts needs `--ask-vault-pass` (or `~/.vault_pass`).

---

## Build (or rebuild) the server VM

The server is a libvirt VM on the control node, built unattended from the Ubuntu
26.04 ISO. You only do this to create it or start over.

```bash
# ISO must be at /home/moritz/Downloads/ubuntu-26.04-live-server-amd64.iso
ansible-playbook provision-server-vm.yml
```
This creates a 60G OS disk + 700G data disk in the `vmstore` pool, runs the
unattended install (key-only `daelt` + passwordless sudo), and starts the VM.
It takes ~15–20 min. When it finishes:

```bash
# find the VM's NAT IP
virsh domifaddr cd108-server --source agent 2>/dev/null || \
  virsh net-dhcp-leases default
# put that IP in inventory/hosts.yml under the `server` host's ansible_host,
# then confirm:
ansible server -m ping
```

To throw it away and rebuild: `virsh destroy cd108-server; virsh undefine
cd108-server --nvram --remove-all-storage`, then re-run the playbook.

> The VM is on **NAT** today (reachable from the control node). Bridging it onto
> the lab LAN so student machines can reach `cd108.tutu.eng.br` is a later step.

---

## Prepare the server (services)

Configures the hub services — apt-cacher-ng, NFS `troca`, and the ZFS golden
pool/share — **without** the heavy desktop/SDR build:

```bash
ansible-playbook prepare-server.yml --check --diff   # dry run first
ansible-playbook prepare-server.yml                  # apply
```
Verify:
```bash
ssh -i ~/.ssh/id_cd108_ansible daelt@<server-ip> \
  'zpool list ssdpool; zfs list -r ssdpool/golden; sudo exportfs -v'
```
You should see the `ssdpool` pool, an `ssdpool/golden` dataset shared to
`103.0.0.0/19`, and `/srv/troca` exported.

To run the *full* server build (desktop + SDR++ compile too), use the normal
converge instead: `ansible-playbook site.yml --limit cd108.tutu.eng.br`.

---

## Harvest the goldens

Copy the reference machine's live state into the server's golden store. Do this
to seed the store the first time, or whenever you've updated the reference
machine and want students to get the new state.

```bash
ansible-playbook harvest-golden.yml      # prompts for the golden's sudo password
```
This snapshots the reference machine's `ssdpool/home` (recursive) and
`ssdpool/windows` as `@golden`, then `zfs send`s them to `ssdpool/golden/*` on
the server (relayed through the control node). ~50G, so it takes a while.

Verify on the server:
```bash
ssh -i ~/.ssh/id_cd108_ansible daelt@<server-ip> \
  'zfs list -r ssdpool/golden; zfs list -t snapshot -r ssdpool/golden | grep -E "@(golden|ltspice)"'
```
You must see `@golden` on the homes and **both `@golden` and `@ltspice`** on
windows (winvm reverts to `@ltspice`).

---

## Add a lab machine

1. Get its **MAC address** (from the switch, DHCP, or `ip link` on the machine).
2. Add it under the right lab group in `inventory/hosts.yml`:
   ```yaml
   labs:
     children:
       cd108:
         hosts:
           cd108-b12:                 # hostname (prefix = lab)
             mac: "e0:d5:5e:aa:bb:cc"
   ```
   That's it — `group_vars/labs.yml` computes its IPv6 `ansible_host` from the
   MAC automatically. **No fixed IP needed.** (If a machine isn't yet reachable
   by IPv6, pin a temporary `ansible_host: <ip>` on the host — it overrides.)
3. Check it resolves:
   ```bash
   ansible cd108-b12 -m ping
   ```

---

## Re-image a machine (Clonezilla)

> **Key fact:** Clonezilla runs from its own **live environment**, not the
> installed OS. You **cannot image a machine's system disk from the control
> node** — the machine has to **reboot into Clonezilla**. Ansible only takes
> over *after* the machine is imaged and booted. So re-imaging is a physical
> (USB) or netboot (PXE) operation, not a remote `ansible-playbook` step.

### What Clonezilla owns vs what Ansible owns

Clonezilla restores the **ext4 Ubuntu system partition** (the base OS + local
binaries like MATLAB under `/usr/local`). It does **not** provide the ZFS data:
the disk also has an empty, **partlabel-`zfs`** partition
(`zfs_data_device` in `group_vars/all.yml`) that Clonezilla leaves
unformatted. After the restore, Ansible builds the `ssdpool` pool on that
partition and `zfs recv`s the homes + Windows VM. So:

```
Clonezilla restore  →  boot  →  site.yml (builds ZFS, receives homes/windows)
   = base OS image        = machine reachable    = fully configured machine
```

The course **homes and the Windows VM are NOT in the Clonezilla image** — they
come from the server via `zfs send/recv` (see [Converge](#converge-a-machine-siteyml)).
Keep the master image small by excluding the ZFS data partition.

### A) Restore an image onto a machine (the common case)

1. **Boot the target into Clonezilla** — from a Clonezilla Live USB (make one
   once: download `clonezilla-live-*.iso`, `dd` it to a USB stick), press the
   boot-menu key (often F12), pick the USB.
2. Choose **`device-image`**, then the image **source**: the NFS repo
   (`103.0.1.16:/mnt/ssdpool/cd108_images`), or a local USB with the image on it.
3. **Partition to fit this disk (only if it's blank or a different size than the
   golden).** The image is system-partitions-only, so lay a fresh table with a
   fixed head and the `zfs` partition **last**, filling the rest:
   ```bash
   DISK=/dev/sda
   sgdisk --zap-all "$DISK"
   # Numbers match the captured image (golden = sda1/sda3/sda7): restoreparts
   # restores each saved partition to the target of the SAME name.
   sgdisk -n1:0:+100M -t1:ef00 -c1:ESP      "$DISK"   # sda1  EFI (exact golden size)
   sgdisk -n3:0:+190G -t3:8300 -c3:root     "$DISK"   # sda3  ext4 root (golden's size)
   sgdisk -n7:0:+4G   -t7:0700 -c7:recovery "$DISK"   # sda7  Clonezilla recovery
   sgdisk -n4:0:0     -t4:bf00 -c4:zfs      "$DISK"   # sda4  zfs = all remaining space
   ```
   Needs a disk ≥ ~210 GB. Re-imaging a machine that already has this layout?
   Skip this — just reuse it.
4. **`restoreparts <image> sda1 sda3 sda7`** — writes the ESP + ext4 root +
   recovery images onto the same-named targets (with `-k -r`).
   Do **not** write the `zfs` partition — it stays empty+labelled and Ansible
   (re)builds the pool on it. It boots with no GRUB/EFI surgery: `fstab` and the
   ESP grub stub are UUID-based (`partclone` preserves UUIDs) and the ESP carries
   the removable `\EFI\Boot\bootx64.efi` fallback (boots with empty NVRAM).
5. Reboot. The machine comes up carrying the golden's hostname; it's reachable
   by its MAC-derived IPv6 (see [architecture → Addressing](architecture.md#addressing--no-fixed-ips-no-registry)).
6. Make sure it's in `inventory/hosts.yml` (see [Add a lab
   machine](#add-a-lab-machine)), then converge it — this sets its real
   hostname, builds ZFS, and receives homes:
   ```bash
   ansible-playbook site.yml --limit <hostname> --check --diff --ask-vault-pass
   ansible-playbook site.yml --limit <hostname> --ask-vault-pass
   ```

### B) Capture a new master image (from the reference machine)

When you've improved the reference machine's base OS and want a new image, first
**prepare the golden**: converge it, bake the image-owned deploy key, and
generalize its identity so clones aren't twins. That's its own checklist —
**[`golden-image-prep.md`](golden-image-prep.md)** — do it before you capture.
Then, in Clonezilla:

1. Boot the (already-generalized) reference machine into Clonezilla.
2. `device-image` → mount the NFS repo (`103.0.1.16:/mnt/ssdpool/cd108_images`) →
   **Expert** → **`saveparts`**, selecting the **EFI/ESP + ext4 root + Clonezilla
   recovery** partitions (`sda1`, `sda3`, `sda7`) and leaving the `zfs`/`ssdpool`
   partition (`sda4`) **unticked**. Clonezilla still records the disk's partition
   table, so on restore the `zfs` partition comes back **empty and labelled**. The
   homes/Windows VM are received separately by the `zfs` role, not by Clonezilla.
3. The image lands on the NFS repo so restores can pull it from there.

> **Can't boot Clonezilla?** Any live Linux with the `clonezilla` + `partclone`
> packages captures an identical image: `apt install clonezilla partclone nfs-common`,
> mount the repo at `/home/partimag`, unmount the target partitions, then
> `ocs-sr -q2 -z1p -senc -sfsck -p true -batch --nogui saveparts <image> "sda1 sda3 sda7"`.
> This is how `cd108-golden-2026-07-09` and the clean `cd108-golden-2026-07-13`
> were captured (from a full live Ubuntu boot; Clonezilla Live wouldn't boot).
>
> ⚠️ **`--nogui` is mandatory when there's no terminal** (running via `systemd-run`,
> `nohup`, or ssh without a pty). Without it, ocs-sr passes `-N` to partclone, which
> opens an ncurses UI that fails to init (`partclone ncurses initial error`) and
> writes **zero** partition data — the run "ends" in seconds with only metadata files.
> Launch detached and verify:
> ```
> sudo systemd-run --unit=recapture ocs-sr -q2 -z1p -senc -sfsck -p true \
>   --nogui -batch saveparts <image> sda1 sda3 sda7
> sudo ocs-chkimg -b -nogui <image>   # NOT -batch; that flag is invalid here
> ```
> (Don't `pkill -f 'ocs-sr|partclone'` to clean up — it matches your own ssh command
> line and kills your session. Use `pkill -f 'ocs[-]sr'` + `pkill -x partclone.ext4`.)

> Confirm the partitions against the golden's `lsblk` before ticking — the
> principle (system partitions in the image, `zfs` partition out and empty) is
> what matters. Full details, the operator-facing capture guide, and the
> non-destructive rationale: [`golden-image-prep.md`](golden-image-prep.md) and
> [`clonezilla-capture-for-operator.md`](clonezilla-capture-for-operator.md).

### Automating it (unattended USB → recovery partition → PXE)

Walking a USB to 50 machines doesn't scale, and the manual Clonezilla menu is
error-prone. Clonezilla runs fully unattended from boot parameters (batch
`ocs-sr` + an `ocs_prerun` NFS mount), so you can build a USB that boots, wipes,
repartitions, and restores from the cd108 NFS with **zero keypresses** — and
later put that same Clonezilla on a **recovery partition** so re-imaging needs no
USB and can be **triggered remotely** (`grub-reboot` + reboot over SSH), or PXE
netboot + DRBL multicast for whole-lab rebuilds. Full roadmap:
[`imaging-automation.md`](imaging-automation.md).

---

## Converge a machine (`site.yml`)

`site.yml` is the normal, **safe-to-re-run** configuration. It never resets
homes.

**Always dry-run one machine first:**
```bash
ansible-playbook site.yml --limit cd108-b12 --check --diff --ask-vault-pass
```
Then apply to that one machine, validate it by hand, and only then roll out:
```bash
ansible-playbook site.yml --limit cd108-b12 --ask-vault-pass          # one machine
ansible-playbook site.yml --limit cd108 --ask-vault-pass              # a whole lab
ansible-playbook site.yml --ask-vault-pass                            # everything
```
The `zfs` role receives the golden homes + Windows VM **N machines at a time**
(`zfs_send_concurrency`, default 4). To have more than 4 truly in parallel,
raise `forks` in `ansible.cfg`.

**Wake sleeping machines first** (WoL is enabled per NIC by `roles/common`):
```bash
ansible-playbook site.yml --limit cd108 ...   # after waking them, e.g. wakeonlan <MAC>
```

---

## Reset homes (destructive)

Between semesters, after students have uploaded their work. This **wipes** the
course homes and re-sends the clean golden. It is **not** in `site.yml`.

```bash
ansible-playbook reset-homes.yml --limit cd108 --ask-vault-pass
```
It rolls in waves of 4 machines (`serial`, override with `-e reset_serial=N`).
Confirm students have saved their work before running.

---

## The Windows emergency VM

Managed by `roles/winvm`. Each machine runs a libvirt Windows VM whose disk
**rolls back to `@ltspice` on every launch**, so students always start clean.
The `roles/winvm` tasks set up: scoped passwordless `zfs rollback` sudo, the
`Windows VM (Reset)` desktop launcher, the NAT DHCP reservation, and the libvirt
domain. The RDP password comes from the vault (`winvm_rdp_password`) — rotate it
if it leaks.

---

## Everyday changes

- **Add an apt package everyone gets:** add it to `common_packages` in
  `inventory/group_vars/all.yml`, then `ansible-playbook site.yml --limit
  <test> --check` → apply → roll out.
- **Change a per-lab setting:** edit that lab's file under
  `inventory/group_vars/` (e.g. `cd108/main.yml`).
- **Before committing playbook changes:** `ansible-playbook --syntax-check
  site.yml -i inventory/hosts.yml` (using the file, not the dir, skips the vault
  prompt).
- **See what a play would do without changing anything:** always `--check
  --diff`.
