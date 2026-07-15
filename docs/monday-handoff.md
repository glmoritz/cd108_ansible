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

## ✅ DONE 2026-07-13 — golden cleaned + re-captured, hostname fixed
- **Clean image `cd108-golden-2026-07-13` (27 GB) is captured and ocs-chkimg-verified
  restorable** (sda1/sda3/sda7). The old `cd108-golden-2026-07-09` is kept as a
  fallback. Cleaning was done **offline from the live USB** (`ubuntu@103.0.2.13`,
  golden's OS wasn't running): mounted sda3 rw + imported ssdpool, then removed the
  legacy units/scripts (`set-hostname.service`, `lab-zfs-restore.*`, clipboard
  mount), stripped `/mnt` junk, removed baked dup/dead apt sources, set
  `GRUB_DISABLE_OS_PROBER=true` + chroot `update-grub` (**0 Windows menuentries**,
  was 2), and emptied the Downloads datasets (+destroyed their `@golden` child
  snapshots). Capture needed **`--nogui`** (see the runbook gotcha).
- **Hostname bug FIXED.** Root cause was the golden's `set-hostname.service` →
  `set-hostname-from-mac.sh` re-stamping `lab-unknown-<mac>` every boot — **not**
  cloud-init (which is disabled). The `common` role now purges it; verified on
  `cd108-flashtest` (converge → reboot → `hostnamectl` = `cd108-flashtest`, sticks).
  Also removed from the golden image itself.
- **No ext4 shrink** — the fleet SSDs are 480 GB with a 190 GB ext4 root by design
  (the earlier "shrink to 120 GB" note was a flashtest-VM sizing mistake).

Repeatable cleaning is also codified in `prepare-golden-image.yml` (strips `/mnt`
junk, empties Downloads) for the next time a *running* golden is sysprepped.

## Open items
1. **`cd108clipboard` mount** — DECISION NEEDED: the cd108-server VM doesn't export
   a clipboard (it has the "troca" NFS exchange). Should the student clipboard mount
   the server's troca share, or a separate clipboard dataset? Then wire the client
   mount to `cd108.tutu.eng.br`.
2. **SDR++ not built** — the server play compiles/packages it (heavy). Run
   `site.yml --limit cd108.tutu.eng.br --tags sdr` once; clients then just pull the
   tarball (distribution logic is proven, currently skips gracefully when absent).
3. **Clonezilla not selectable at boot** — by design (USB-boot per runbook). Optional:
   add a GRUB chainload entry to the `sda7` recovery partition if on-disk recovery
   should be selectable.
4. **Validate the new golden end-to-end** — restore `cd108-golden-2026-07-13` to a
   fresh machine/VM, confirm first boot is clean (right hostname after converge, no
   Windows GRUB entry, ssh accepts Ansible) and a full converge stays green.

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
  sync flow (since 2026-07-15): commit + push to GitHub
  (`https://github.com/glmoritz/cd108_ansible.git`, branch `harvest-cd108-golden`),
  then on the server `git -C ~/cd108_ansible pull --ff-only`. No more rsync.
- **Don't use `--check`** on this playbook — too many produce-then-consume chains
  make it misleading.
