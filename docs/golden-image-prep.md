# Preparing the golden as the capture image

You capture the image **from the golden machine** (`cd108-test-01`). This page is
the ordered checklist to turn the running golden into a clean master, then hand
off to Clonezilla. The homes and the Windows VM are **not** part of the image —
they already live on the server and reach each machine later via `zfs recv`
(see [`architecture.md`](architecture.md)). The image is just the **ext4 Ubuntu
system** plus an **empty, labelled `zfs` partition**.

Do this at the machine (or over a session you're happy to lose) — the last step
wipes its identity and you power straight into Clonezilla afterwards.

---

## What "ready to be the image" means

Two things have to be true of the golden's ext4 system before you capture it:

1. **The deploy key is image-owned.** `daelt`'s `~/.ssh/authorized_keys` lives on
   ZFS, which isn't in the image — a fresh clone would boot with no way for
   Ansible to log in (the first-connect chicken-egg). The `common` role now also
   writes the key to `/etc/ssh/authorized_keys.d/daelt` with an sshd drop-in
   (`/etc/ssh/sshd_config.d/10-image-authkeys.conf`) that reads it. That path
   **is** in the image, so first-connect works on every clone.
2. **The machine is generalized.** No baked-in machine-id or SSH host keys, or
   every clone would be an identical twin (duplicate host keys is a real security
   problem). `prepare-golden-image.yml` blanks them so each clone regenerates its
   own on first boot.

---

## Step 1 — converge the golden one last time

Make sure the golden carries the current config **and** the image-owned key:

```bash
ansible-playbook site.yml --limit cd108-test-01 --tags common --check --diff --ask-vault-pass
ansible-playbook site.yml --limit cd108-test-01 --tags common --ask-vault-pass
```

Confirm the key landed in the image-owned path (this is what the sysprep checks):

```bash
ansible cd108-test-01 -b -m command -a 'cat /etc/ssh/authorized_keys.d/daelt'
```

## Step 2 — generalize (the last online step)

```bash
ansible-playbook prepare-golden-image.yml -e capture_now=true --ask-vault-pass
```

This flushes logs/caches, blanks the machine-id, and removes the SSH host keys.
**When it finishes, do not let the machine boot back into Ubuntu** — power it off
and go straight to Clonezilla. (If you do boot Ubuntu again, it just regenerates
those files; re-run the sysprep right before you actually capture.)

## Step 3 — power off and boot Clonezilla

Power off, insert the Clonezilla Live USB, boot from it, choose
`device-image`, mount the cd108 NFS repo
(`103.0.1.16:/mnt/ssdpool/cd108_images`) so re-imaging can pull it from the
network, and capture with **`saveparts`** (see below).

### The locked capture layout (decided 2026-07)

`savedisk` images the *whole* disk with no clean way to drop a partition, so use
**`saveparts`** (Expert mode) and capture exactly **three** partitions, leaving
the ZFS data partition out. On the golden (`sda`, 477 GB):

| Capture | Part | What |
|---|---|---|
| ✅ | `sda1` | EFI/ESP (vfat, 100 MB) |
| ✅ | `sda3` | ext4 root (Ubuntu, ~190 GB, 63 GB used) |
| ✅ | `sda7` | `clonezilla` recovery slot (vfat, 4 GB) |
| ❌ | `sda4` | `ssdpool`/`zfs` data — **must not** be in the image |
| ❌ | `sda2` | 16 MB Microsoft-reserved — not needed |

This is **non-destructive** to the golden — its live `ssdpool` is untouched.

### How clones are partitioned (and why it boots with no GRUB pain)

The `zfs` partition is **not** in the image; each target is repartitioned at
restore, with `zfs` **last** so it fills the disk. **ext4 keeps the golden's
190 GB** (exact restore, no shrink), so the head is identical everywhere and only
the `zfs` tail varies:

```bash
DISK=/dev/sda
sgdisk --zap-all "$DISK"
sgdisk -n1:0:+100M -t1:ef00 -c1:ESP      "$DISK"
sgdisk -n2:0:+190G -t2:8300 -c2:root     "$DISK"
sgdisk -n3:0:+4G   -t3:0700 -c3:recovery "$DISK"
sgdisk -n4:0:0     -t4:bf00 -c4:zfs      "$DISK"   # zfs = all remaining (≥ ~210 GB disk)
```

`restoreparts` writes ESP/root/recovery into `p1`–`p3`; Ansible builds `ssdpool`
on the empty labelled `p4`. **No GRUB/EFI surgery needed** — verified on the
golden: `fstab` and the ESP grub stub both resolve root by **fs-UUID** (which
`partclone` preserves), and the ESP already has the removable `\EFI\Boot\bootx64.efi`
fallback, so clones boot with an empty EFI NVRAM. Full roadmap:
[`imaging-automation.md`](imaging-automation.md); operator steps:
[`clonezilla-capture-for-operator.md`](clonezilla-capture-for-operator.md).

## Step 4 — verify the image restores clean

On the **first machine** you re-image from it (the shakeout —
[`first-lab-test.md`](first-lab-test.md)):

```bash
lsblk -o NAME,SIZE,LABEL,PARTLABEL           # p4 present, partlabel zfs, empty
cat /etc/machine-id                          # non-empty, and DIFFERENT per clone
ls /etc/ssh/ssh_host_*                       # regenerated (fresh mtime)
sudo cat /etc/ssh/authorized_keys.d/daelt    # deploy key present
```

Then `ansible <newhost> -m ping` should succeed **before** any ZFS exists —
that's the whole point of the image-owned key.

---

### Checklist

- [ ] `common` converged on the golden (image-owned key present)
- [ ] `prepare-golden-image.yml -e capture_now=true` run
- [ ] powered off **without** rebooting the OS
- [ ] Clonezilla `saveparts` of **`sda1` + `sda3` + `sda7`** (skip `sda4`/`sda2`),
      stored on `103.0.1.16:/mnt/ssdpool/cd108_images`
- [ ] verified on the first re-imaged machine (unique id/host keys, ping works)
