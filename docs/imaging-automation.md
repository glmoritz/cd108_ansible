# Automating the imaging (roadmap)

Goal: a machine boots, **prepares its disks and restores from the cd108 NFS with
minimal intervention**, reboots, and Ansible takes over. Later: no USB at all.
This is a solved pattern — Clonezilla is built for exactly this. Three stages,
from "works next week" to "fully hands-off".

## The key idea

Clonezilla Live reads **boot-time parameters** that let it run fully unattended
(batch mode, no prompts). The two that matter:

- **`ocs_prerun`** — commands run *before* imaging. We use it for two things:
  mount the image repo from NFS, **and partition the target disk sized to itself**
  (this is what makes any SSD size work — see below). Clonezilla restores from
  `/home/partimag`:
  ```
  ocs_prerun1="mount -t nfs 103.0.1.16:/mnt/ssdpool/cd108_images /home/partimag"
  ocs_prerun2="/home/partimag/layout-disk.sh"   # sgdisk: ESP + ext4 + zfs=rest
  ```
- **`ocs_live_run`** — the batch restore. `-batch` = no questions. Because the
  image is *system partitions only*, we `restoreparts` (not `restoredisk`), and
  `-r` resizes the restored ext4 to its partition:
  ```
  ocs_live_run="ocs-sr -batch -r -j2 -p reboot restoreparts <image> <esp> <root>"
  ```

Set the boot menu to auto-select that entry with a short timeout and you get:
insert media → power on → walk away → disk is repartitioned and restored →
reboot. **Zero keypresses.**

### Why partition at restore instead of replaying the golden's table

The lab SSDs are **different sizes**, so we must **not** bake the golden's disk
geometry into the image. The image is `saveparts` of the **EFI + ext4 root** only
— no `zfs` partition, no fixed whole-disk table. Each target gets a *fresh* table
sized to its own disk, with the `zfs` partition taking **whatever is left**:

```bash
# layout-disk.sh — runs in ocs_prerun, sizes the zfs partition to THIS disk
DISK=/dev/sda                       # detect the internal disk at runtime
sgdisk --zap-all "$DISK"
sgdisk -n1:0:+1G   -t1:ef00 -c1:ESP  "$DISK"   # EFI system partition
sgdisk -n2:0:+120G -t2:8300 -c2:root "$DISK"   # ext4 root (fixed, > used size)
sgdisk -n3:0:0     -t3:bf00 -c3:zfs  "$DISK"   # ZFS = ALL remaining space
```

`restoreparts` then writes the ESP + ext4 images into `p1`/`p2` (partclone stores
only *used* blocks, `-r` grows the ext4 fs to the 120 G partition). Partition `p3`
is left empty but **labelled `zfs`**, so `/dev/disk/by-partlabel/zfs` resolves and
Ansible's `zpool create` fills it — 256 GB SSD → ~130 G pool, 2 TB → ~1.8 T pool,
**same image**. This is ZFS's "use the whole disk" doing the size-adaptation for
us; the homes and Windows VM arrive afterward via `zfs recv`.

You don't have to hand-edit bootloaders: Clonezilla can **generate** a custom
unattended restore device for you with **`ocs-iso`** / **`ocs-live-dev`** (it even
offers to build a "recovery Clonezilla live" right after you save an image). That
bakes in the image name, target disk, NFS prerun, and batch flags.

## Stage 1 — unattended restore USB (works next week)

Build one Clonezilla USB (via `ocs-iso`) that auto-restores the cd108 image from
NFS. To re-image a machine: plug it in, boot from USB, walk away. Good enough for
a handful of machines and for the shakeout test. **No Ansible change needed** —
the machine just needs the image on NFS and its disk laid out by the `ocs_prerun`
partitioning step (ESP + ext4 + `zfs`=rest), then `restoreparts`.

## Stage 2 — recovery partition on the disk (your idea — no USB)

Put a small **recovery partition** on each machine's disk holding Clonezilla Live
+ the unattended parameters, and add a **GRUB entry** that boots it. Then:

- **No USB:** pick the "Recovery — re-image" GRUB entry.
- **Remotely triggerable — this is the important part:** from the control node,
  ```bash
  ansible <host> -b -m command -a 'grub-reboot "Recovery — re-image"'
  ansible <host> -b -m reboot
  ```
  The machine reboots into Clonezilla, restores from NFS, and reboots into a fresh
  OS — **no physical presence, no keypress**. The imaging still runs out-of-band
  (not from the running OS), but you *trigger* it over SSH. This is the piece that
  turns "must walk to the machine" into "re-image from your desk".
- **Space trade-off:** keep the recovery partition thin and pull the image from
  **NFS** each time (small footprint, needs the network) rather than storing a
  local copy of the (large) image.

After the recovery run, the machine boots the fresh image and is a normal
inventory host again — Ansible rebuilds ZFS and receives homes.

## Stage 3 — PXE / DRBL (mass rebuilds)

No USB, no recovery partition: **netboot** Clonezilla SE (DRBL) from the server
and **multicast** one image to a whole lab at once. Best when you're rebuilding
many machines together (start of semester). Needs the server bridged onto the lab
LAN plus a DHCP/TFTP/PXE setup on it. Complementary to Stage 2: PXE for mass
rebuilds, the recovery partition for one-off remote re-images.

## How it all lines up with our model

```
 unattended Clonezilla (USB / recovery part / PXE)     Ansible (site.yml)
 ─────────────────────────────────────────────────     ──────────────────────
 ocs_prerun: partition THIS disk to fit +              on first boot:
             mount images over NFS                       • build ssdpool on the
 restoreparts from NFS:                                     zfs=rest partition
   • ESP + ext4 root (system only)                       • zfs recv homes + winvm
   • zfs partition = rest of disk, empty+labelled        • apply config
   • (homes/windows NOT in the image)
```

So "an image that prepares the disks mounting from cd108 NFS with minimal
intervention" = **partition the disk to its own size** (`ocs_prerun`) then an
unattended `restoreparts` of the system partitions over NFS. Nothing exotic — it's
the standard Clonezilla mass-deployment workflow, and sizing the `zfs` partition
per-disk is what lets **one image fit every SSD**. The recovery-partition variant
makes it remotely triggerable without a flash drive.

**Not built yet** — this is the roadmap. Prerequisite for all three: the image
lives on the NFS repo (`103.0.1.16:/mnt/ssdpool/cd108_images` today) and that repo
is reachable from the lab LAN.
