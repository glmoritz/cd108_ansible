#!/bin/sh
# layout-disk.sh [DISK]  (default /dev/sda)
#
# Repartition a target lab SSD to receive the cd108 golden. Sizes the ZFS
# partition to THIS disk, so one image fits every SSD size. Partition NUMBERS
# must match the captured image (golden = sda1/sda3/sda7) because Clonezilla
# `restoreparts` restores each saved partition to the target of the SAME name;
# GPT allows the non-sequential numbering (the golden's MSR sat at sda2, left
# unused). See docs/imaging-automation.md.
#
# Managed by Ansible (roles/server) — deployed into the Clonezilla image repo.
# Runs from a Clonezilla Live shell (or as ocs_prerun) — NOT on a live OS.
set -eu

DISK="${1:-/dev/sda}"
[ -b "$DISK" ] || { echo "layout-disk: '$DISK' is not a block device" >&2; exit 1; }

echo ">> Repartitioning $DISK  (ESP + ext4 root + recovery + zfs=rest)"
sgdisk --zap-all "$DISK"
sgdisk -n1:0:+100M -t1:ef00 -c1:ESP      "$DISK"   # sda1  EFI/ESP (exact golden size)
sgdisk -n3:0:+190G -t3:8300 -c3:root     "$DISK"   # sda3  ext4 root (golden's size; -r grows on restore)
sgdisk -n7:0:+4G   -t7:0700 -c7:recovery "$DISK"   # sda7  Clonezilla recovery slot
sgdisk -n4:0:0     -t4:bf00 -c4:zfs      "$DISK"   # sda4  ZFS = ALL remaining (Ansible builds ssdpool here)
partprobe "$DISK" 2>/dev/null || true

echo ">> Layout:"
sgdisk -p "$DISK"
