# Monday handoff — cd108 lab automation

State as of Fri 2026-07-10 EOD. Where we are, what's open, how to resume.

## Where we got to (good news)
- **Full green client converge** end-to-end on the `cd108-flashtest` VM (restored
  from `cd108-golden-2026-07-09`, on the campus bridge). Every role runs:
  first-connect, apt/repos behind the captive portal, zfs recv (homes **and**
  windows with its `@ltspice` baseline), winvm wiring, matlab.
- **Server (cd108-server) is on its real address `103.0.1.43`** (`::43`), DNS
  `cd108.tutu.eng.br` points there. apt-cacher (HTTPS passthrough), NFS, and the
  base services work. Internet stays via NAT so it's authenticated past the portal.
- **phone-home works** (beacon → server receiver).
- Big batch of fixes committed (see `git log`, ~20 commits 2026-07-10): ssh
  reboot-persistence, GRUB os-prober, captive-portal apt proxy, ra3xdh/ettus repo
  handling, zfs mount idempotency, Downloads not synced, lean server package set,
  lab-workstation stuff gated off the hub, etc.

## 🚨 CRITICAL — the golden image is NOT cleaned/re-captured
**All of today's fixes live in the Ansible repo (applied at converge time). The
captured image `cd108-golden-2026-07-09` is UNCHANGED** — it still has: ssh
disabled, the phantom Windows GRUB entry, the conflicting baked apt `.sources`
(docker/vscode/chrome/ettus/ra3xdh), the legacy `lab-zfs-restore`, `/mnt` garbage,
Downloads content in the home datasets, and a 190 GB ext4 (too big for smaller
SSDs). That's why a freshly-flashed clone still needs manual touch-ups.

**Before real deployment we must RE-CAPTURE the golden**, after:
1. Converge the golden with the current repo (`site.yml --limit <golden> --tags common`)
   so ssh-enable, os-prober-off, apt dedup, hostname fix, etc. are baked in.
2. Run `prepare-golden-image.yml -e capture_now=true` (sysprep: keyless, regen unit,
   blank machine-id).
3. **Shrink the ext4** to ~120 GB (see [[flashtest-vm-shakeout]] note; 190 GB
   starves zfs on ~240 GB SSDs).
4. Empty the golden's local `/mnt` junk and the Downloads dirs.
5. Re-capture via Clonezilla `saveparts sda1 sda3 sda7` (see
   [`golden-image-prep.md`](golden-image-prep.md), [`imaging-automation.md`](imaging-automation.md)).

Until then, the current image works but a clone needs the per-boot fixes a converge
provides.

## Open items
1. **Hostname still reverts to `lab-unknown-<id>` after reboot.** phone-home works
   but the machine reports lab-unknown. I added `cloud-init preserve_hostname: true`
   (common role) but it's **UNVERIFIED** — the machine was rebooted before the fix
   was converged onto it. Monday: converge a machine with the fix, reboot, confirm
   the hostname sticks. If it still reverts, the culprit is elsewhere — check
   `NetworkManager` hostname-mode (DHCP option 12) and systemd-hostnamed.
2. **`/mnt` garbage on the golden** — needs a strip task in `common` (or golden
   prep). Blocked today by flashtest SSH being down; inspect `/mnt` once reachable.
3. **`cd108clipboard` mount** — DECISION NEEDED: the cd108-server VM doesn't export
   a clipboard (it has the "troca" NFS exchange). Should the student clipboard mount
   the server's troca share, or a separate clipboard dataset? Then wire the client
   mount to `cd108.tutu.eng.br`.
4. **SDR++ not built** — the server play compiles/packages it (heavy). Run
   `site.yml --limit cd108.tutu.eng.br --tags sdr` once; clients then just pull the
   tarball (distribution logic is proven, currently skips gracefully when absent).
5. **Clonezilla not selectable at boot** — by design (USB-boot per runbook). Optional:
   add a GRUB chainload entry to the `sda7` recovery partition if on-disk recovery
   should be selectable.

## How to resume Monday
- **Bridge is ephemeral (option B).** After any **host reboot**, run
  `sudo scripts/labnet-bridge.sh up` before starting the VMs (the VM NICs are
  persistent, br0 is not). The server VM (ens7) has static `.43`; flashtest DHCPs
  on br0 — its NIC needs a manual `nmcli device connect <iface>` after a power-cycle
  (guest doesn't auto-DHCP a re-attached NIC).
- **Server converge** (installs the phone-home receiver + autosleep timer that are
  still missing, now lean):
  ```bash
  cd ~/cd108_ansible
  ansible-playbook site.yml --limit cd108.tutu.eng.br --tags common,server \
    --ask-vault-pass --ask-become-pass
  ```
- **Client converge**: update `flashtest-inv.yml` to the VM's current campus IP,
  then `site.yml --limit cd108-flashtest -i inventory/hosts.yml -i flashtest-inv.yml …`.
- Run from the server (`~/cd108_ansible`) or the host (`~/00_tmp/cd108_ansible`);
  keep them in sync by rsync from the host (there's no git remote on the server).
- **Don't use `--check`** on this playbook — too many produce-then-consume chains
  make it misleading.
