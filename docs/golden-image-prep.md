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

### Leave the `zfs` partition empty in the image

The golden's `zfs` partition (partlabel `zfs`, pool `ssdpool`) is **full** of the
golden homes and the Windows VM — but the image must ship that partition **empty**
(clones build the pool and receive homes via Ansible). So you must **not** copy
that partition's contents. `savedisk` images the *whole* disk with no clean way to
drop a partition, so instead use **`saveparts`** (Expert mode) and select **only
the EFI/ESP + ext4 root** partitions — leave the `zfs`/`ssdpool` partition
**unticked**:

- Clonezilla still records the disk's **partition table** (`*-pt.sf`, `*-gpt.*`)
  alongside the partition images, so the `zfs` partlabel and layout are preserved.
- On restore you lay that table (empty `zfs` partition included) then
  `restoreparts` the system partitions → an empty, labelled `zfs` partition.
  Exactly what [`imaging-automation.md`](imaging-automation.md) and the `zfs` role
  expect.
- The image stays small (system only), so it moves fast over NFS and multicast.

This is **non-destructive** to the golden — its live `ssdpool` is untouched.
(Fallback if `saveparts` gives trouble: `savedisk` the whole disk — foolproof but
a much larger image that includes the homes/Windows VM. Fine for a quick test.)
The operator-facing version of this is
[`clonezilla-capture-for-operator.md`](clonezilla-capture-for-operator.md).

## Step 4 — verify the image restores clean

On the **first machine** you re-image from it (the shakeout —
[`first-lab-test.md`](first-lab-test.md)):

```bash
lsblk -o NAME,SIZE,LABEL,PARTLABEL           # sda4 present, labelled zfs, empty
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
- [ ] Clonezilla `savedisk`, **`sda4` deselected**, stored on cd108 NFS
- [ ] verified on the first re-imaged machine (unique id/host keys, ping works)
