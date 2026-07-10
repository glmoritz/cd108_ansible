# Flash `cd108-flashtest` from zero, then converge (shakeout)

A turnkey run to validate the golden image **and** the Ansible converge on a VM that
mimics a real ~512 GB lab SSD, before touching hardware. Follow top to bottom.

## What's already prepared (done 2026-07-10)

- `cd108-flashtest` libvirt VM, **off**, on moritz-pc.
- **Blank 480 GB** disk (`sda`, sparse) — 190 G ext4 leaves ~286 G for zfs, so homes
  **and** windows fit (the 230 G VM starved zfs and failed windows-receive).
- **Clonezilla 3.3.2 ISO** on the cdrom (`sdb`), boot order 1 (disk is 2).
- NVRAM cleared.

The golden image is `cd108-golden-2026-07-09` on the NFS repo
`103.0.1.16:/mnt/ssdpool/cd108_images`, and `restore-cd108-golden.sh` lives in that
same repo (already uses the correct `1/3/7 + zfs(4)=rest` layout).

---

## 1. Flash the disk (Clonezilla)

```bash
# Boot Clonezilla from the ISO with pristine firmware
virsh start cd108-flashtest --reset-nvram
```

Open the VM console (`virt-manager`, or `virsh console cd108-flashtest`). In the
Clonezilla menu choose **"Enter shell / command line prompt"**. NAT gives the VM a
DHCP address automatically, and it can reach the NFS server (103.0.1.16) through the
host. Then:

```bash
sudo mount -t nfs -o vers=3 103.0.1.16:/mnt/ssdpool/cd108_images /home/partimag
sudo bash /home/partimag/restore-cd108-golden.sh /dev/sda
```

The script zaps `sda`, lays out `sda1`(ESP)/`sda3`(root 190 G)/`sda7`(recovery)/`sda4`(zfs=rest),
then `restoreparts` the three system partitions. Wait for it to finish.

## 2. Boot the restored system

```bash
sudo poweroff                                             # in the Clonezilla shell
virsh change-media cd108-flashtest sdb --eject --config   # remove the ISO
virsh start cd108-flashtest --reset-nvram                 # boot the disk
```

It should come up as `cd108-flashtest` with a fresh machine-id and freshly regenerated
SSH host keys. Get its address and confirm **first-connect via the baked deploy key**
(this is the whole point of the image-owned key — it works before any ZFS home exists):

```bash
virsh domifaddr cd108-flashtest
ssh -i ~/.ssh/id_cd108_ansible daelt@<ip>     # "Could not chdir to /home/daelt" is EXPECTED
```

> **If it won't boot** (black screen, qemu at ~0 % CPU): the two suspects are Secure
> Boot rejecting the removable `\EFI\Boot\bootx64.efi` if it's grub rather than the
> signed shim, or a stale GPT backup header. Quick escape hatch — switch the VM to
> non-Secure-Boot firmware: `virsh edit cd108-flashtest`, change the `<loader>` to
> `/usr/share/OVMF/OVMF_CODE_4M.fd` and the `<nvram template=...>` to
> `/usr/share/OVMF/OVMF_VARS_4M.fd`, drop `secure='yes'`, delete
> `/var/lib/libvirt/qemu/nvram/cd108-flashtest_VARS.fd`, then start again.

## 3. Converge with Ansible

You need a password file with the 6-char vault/become password (create it yourself —
it's not stored in the repo):

```bash
printf '%s' 'THEPASSWORD' > /tmp/.cdpw && chmod 600 /tmp/.cdpw
```

Set `ansible_host` in `flashtest-inv.yml` (repo root, gitignored) to the VM's current IP
from step 2, then:

```bash
cd /home/moritz/00_tmp/cd108_ansible

# dry run first
ansible-playbook site.yml --limit cd108-flashtest \
  -i inventory/hosts.yml -i flashtest-inv.yml \
  --vault-password-file /tmp/.cdpw --become-password-file /tmp/.cdpw \
  --diff --check        # note: command/shell tasks skip in --check; real run below is the test

# real converge
ansible-playbook site.yml --limit cd108-flashtest \
  -i inventory/hosts.yml -i flashtest-inv.yml \
  --vault-password-file /tmp/.cdpw --become-password-file /tmp/.cdpw \
  --diff
```

This runs `common` + the **zfs push rework** (server pushes `zfs send | ssh recv` as
`daelt` via the deploy key, delegated recv with `zfs allow`) + `winvm` etc. On the
480 G disk, **windows-receive should finally fit and succeed** — the missing piece.

## 4. Verify

```bash
ssh -i ~/.ssh/id_cd108_ansible daelt@<ip> \
  'ls /home; zfs list -o name,mountpoint,mounted; ls -d /ssdpool/windows 2>/dev/null || zfs list ssdpool/windows'
```

Success = all discipline homes mounted under `/home`, `ssdpool/windows` present, no
task failures. **Then** the uncommitted `roles/zfs` + `ansible.cfg` + `group_vars`
changes are proven and safe to commit.

---

## Reference: the scratch inventory

`flashtest-inv.yml` (repo root, gitignored) — recreate if missing:

```yaml
all:
  children:
    labs:
      children:
        cd108:
          hosts:
            cd108-flashtest:
              ansible_host: 192.168.122.230   # set to `virsh domifaddr cd108-flashtest`
              mac: "52:54:00:31:27:60"
```

## Caveat for real hardware

The captured image still has a **190 G ext4**. Fine on this 480 G VM, but a smaller lab
SSD (~240 G) leaves too little for zfs (homes+windows ≈ 47 G). Before a future
re-capture, shrink the ext4 (used ~65 G → target ~100–120 G). See
[`golden-image-prep.md`](golden-image-prep.md).
