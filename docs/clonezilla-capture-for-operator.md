# Capturing the cd108 golden image with Clonezilla

Hi — thanks for helping. You'll make a full **disk image** of one already-prepared
Ubuntu PC and save it onto a network share, so it can be cloned to other lab
machines later. About **30–60 minutes**, mostly waiting. You don't need to know
anything about the project — just follow the steps.

## What you need

- **The prepared PC** (labelled *cd108 golden*). It's been set up and powered off.
  **Do not boot its normal Ubuntu** — you'll boot Clonezilla from USB instead.
- A **Clonezilla Live USB stick**. To make one: download the *Clonezilla Live*
  ISO from <https://clonezilla.org/downloads.php> and write it to a USB stick with
  balenaEtcher, Rufus, or `dd`.
- The PC plugged into the lab network with an **Ethernet cable** (not Wi-Fi).
- These fixed values (you'll type them in):
  | Thing | Value |
  |---|---|
  | NFS server | `103.0.1.16` |
  | Shared folder | `/mnt/ssdpool/cd108_images` |
  | Image name to type | `cd108-golden-ubuntu2404-<date>` (no spaces, e.g. `cd108-golden-ubuntu2404-20260710`) |

## What goes in the image (important)

Capture **three** partitions: the **EFI/ESP**, the **ext4 Ubuntu root**, and the
small **`clonezilla` recovery** partition. **Skip the ZFS data partition** — the
one labelled `ssdpool` / `zfs`. That one holds the course homes and a Windows VM
distributed separately (via Ansible `zfs recv`), so it must **not** be in the
image; clones get an empty, labelled `zfs` partition built by Ansible instead.
That's why this uses **`saveparts`**, not `savedisk`.

## Steps

1. Insert the Clonezilla USB and power on. Open the **boot menu** (tap `F12`,
   `F10`, `Esc`, or `F9` at power-on — varies by PC) and pick the **USB stick**.
2. Take the default **"Clonezilla live"** and let it boot. Choose **English**,
   keep the default keyboard, then **Start Clonezilla**.
3. **Confirm the layout first.** Drop to a shell (option *"Enter command line
   prompt"* → `2` for a shell, or `Ctrl-Alt-F2`) and run:
   ```
   lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL
   ```
   Note the internal disk (e.g. `sda` / `nvme0n1`) and which partitions are the
   **EFI (vfat/ESP)** and **ext4 root** vs the data one labelled **`zfs` /
   `ssdpool`**. Type `exit` / `ocs-live` (or `Ctrl-Alt-F1`) to return to the menu.
4. Choose **`device-image`**.
5. Point it at the share — **`nfs_server`** → **`NFSv3`** → networking by
   **`dhcp`** → server **`103.0.1.16`** → directory **`/mnt/ssdpool/cd108_images`**.
   It mounts and prints free space (plenty). *If it errors, see Troubleshooting.*
6. Choose **`Expert`** mode.
7. Choose **`saveparts`** (save selected partitions, not the whole disk).
8. **Image name:** **`cd108-golden-ubuntu2404-<date>`** (today's date, no spaces).
9. **Select partitions:** tick these **three** —
   - **`sda1`** — vfat, **100 MB**, mounts `/boot/efi` (the EFI partition)
   - **`sda3`** — ext4, **~190 GB**, mounts `/` (the Ubuntu root)
   - **`sda7`** — vfat, **4 GB**, labelled `clonezilla` (the recovery partition)

   **Leave unticked:** **`sda4`** (the `ssdpool`/`zfs` data partition — must **not**
   be in the image) and **`sda2`** (16 MB Microsoft-reserved, not needed). Note
   there are two vfat partitions — the **100 MB** one (`sda1`, EFI) and the **4 GB**
   one (`sda7`, recovery) — tick both, but don't mix them up. Confirm against your
   own `lsblk` from step 3 in case the disk isn't `sda`.
10. Extra parameters: accept the defaults (Clonezilla also records the disk's
    partition table alongside the image — keep that). Compression default is fine.
    Confirm **`y`** to proceed; it writes to the share (the long part).
11. On **"finished successfully"**, choose **Power off**, remove the USB, leave
    the PC off and hand it back. **Do not boot its Ubuntu.**

## How to know it worked

The final screen must say **"finished successfully"** with **no red errors**. On
the share you'll get a folder `cd108-golden-ubuntu2404-<date>` containing the two
three partition images (EFI, root, recovery) **and** the disk's partition-table
files (`*-pt.sf`, `*-gpt.*`, `*-mbr`) — kept as a reference for restores. If the
folder contains an image of the `zfs`/`ssdpool` partition, the wrong partition was
ticked — redo step 9 (that partition must **not** be in the image).

> Simplest fallback if `saveparts` gives you trouble: use **`savedisk`** (whole
> disk) instead. It just works but the image is much larger (it includes the
> homes + Windows VM) — fine for a quick test, not ideal long-term. Tell
> Guilherme if you fall back to this.

## Troubleshooting

- **NFS mount fails / "connection refused" / "no route":** check the Ethernet
  cable is in and the link light is on; make sure you chose `dhcp`; re-enter the
  server `103.0.1.16` and path `/mnt/ssdpool/cd108_images` exactly (leading slash,
  lowercase).
- **Two (or more) disks listed:** choose the **internal** SATA/NVMe disk (big),
  never the Clonezilla USB (small, ~8–32 GB).
- **It asks about a partition it "cannot recognise":** that's expected — accept
  the default and continue.
- **Anything red, or you're unsure:** stop and send a **photo of the screen** to
  Guilherme before continuing.

*Note: capturing only reads the disk — nothing on the machine is modified.*
