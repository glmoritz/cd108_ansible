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

## Steps

1. Insert the Clonezilla USB and power on. Open the **boot menu** (tap `F12`,
   `F10`, `Esc`, or `F9` at power-on — varies by PC) and pick the **USB stick**.
2. At the Clonezilla screen, take the default **"Clonezilla live"** and let it
   boot. Choose **English**, keep the default keyboard, then **Start Clonezilla**.
3. Choose **`device-image`** (work with disks/partitions using an image).
4. Point it at the network share — choose **`nfs_server`** → **`NFSv3`** →
   set up networking by **`dhcp`** → server IP **`103.0.1.16`** → directory
   **`/mnt/ssdpool/cd108_images`**. It mounts the share and prints the free space
   (there's plenty). *If it errors here, see Troubleshooting.*
5. Choose **`Beginner`** mode.
6. Choose **`savedisk`** (save the whole internal disk to an image).
7. **Image name:** type **`cd108-golden-ubuntu2404-<date>`** (use today's date).
8. **Source disk:** pick the PC's **internal disk** — usually **`sda`** or
   **`nvme0n1`**, the big one (hundreds of GB). **Not** the Clonezilla USB.
9. Accept the defaults for the rest (skip filesystem check; default compression).
   When it asks to proceed, type **`y`** / Enter. It now writes the image to the
   share — this is the long part.
10. When it says **"finished successfully"**, choose **Power off**. Remove the USB.
    Leave the PC off and hand it back. **Do not boot its Ubuntu.**

## How to know it worked

The final screen says whether it succeeded — you want **"finished successfully"**
with **no red error lines**. The image is saved as a folder named
`cd108-golden-ubuntu2404-<date>` on the share.

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

*Note: this captures the whole disk. That's intentional and safe — nothing on the
machine is modified, only read.*
