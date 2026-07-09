# Automating the imaging (roadmap)

Goal: a machine boots, **prepares its disks and restores from the cd108 NFS with
minimal intervention**, reboots, and Ansible takes over. Later: no USB at all.
This is a solved pattern — Clonezilla is built for exactly this. Three stages,
from "works next week" to "fully hands-off".

## The key idea

Clonezilla Live reads **boot-time parameters** that let it run fully unattended
(batch mode, no prompts). The two that matter:

- **`ocs_prerun`** — a command run before imaging, used to mount the image repo
  from NFS. Clonezilla restores from `/home/partimag`:
  ```
  ocs_prerun="mount -t nfs cd108.tutu.eng.br:/srv/nfs/images /home/partimag"
  ```
- **`ocs_live_run`** — the batch restore command. `-batch` means no questions:
  ```
  ocs_live_run="ocs-sr -batch -r -j2 -p reboot restoredisk <image-name> <disk>"
  ```

Set the boot menu to auto-select that entry with a short timeout and you get:
insert media → power on → walk away → disk is repartitioned and restored →
reboot. **Zero keypresses.**

> Use **`restoredisk`** (whole disk), not `restoreparts` — it lays down the whole
> partition table, *including the empty labelled `zfs` partition*. That's your
> "prepares the disks". The image stays small because the homes and Windows VM
> aren't in it (they come later via `zfs recv`). Ansible builds ZFS on the empty
> partition on first converge.

You don't have to hand-edit bootloaders: Clonezilla can **generate** a custom
unattended restore device for you with **`ocs-iso`** / **`ocs-live-dev`** (it even
offers to build a "recovery Clonezilla live" right after you save an image). That
bakes in the image name, target disk, NFS prerun, and batch flags.

## Stage 1 — unattended restore USB (works next week)

Build one Clonezilla USB (via `ocs-iso`) that auto-restores the cd108 image from
NFS. To re-image a machine: plug it in, boot from USB, walk away. Good enough for
a handful of machines and for the shakeout test. **No Ansible change needed** —
the machine just needs the image on NFS and its disk laid out by `restoredisk`.

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
 restoredisk from NFS:                                  on first boot:
   • ext4 Ubuntu system partition                         • build ssdpool on the
   • empty, labelled `zfs` partition                        empty zfs partition
   • (homes/windows NOT in the image)                      • zfs recv homes + winvm
                                                           • apply config
```

So "an image that prepares the disks mounting from cd108 NFS with minimal
intervention" = an unattended `restoredisk` sourcing the image over NFS. Nothing
exotic — it's the standard Clonezilla mass-deployment workflow, and the
recovery-partition variant makes it remotely triggerable without a flash drive.

**Not built yet** — this is the roadmap. Prerequisite for all three: the image
lives on the server's NFS and the server is reachable from the lab LAN (i.e.
bridge the server VM first).
