# First lab-machine test — day-of guide

The goal: image one real lab machine from the Ubuntu golden and take it through
Ansible end-to-end. Do it on **one** machine, watch each stage, fix as you go.
This is a shakeout run — expect to hit the two blockers in "Sort these first".

Prerequisites and background live in [`architecture.md`](architecture.md) and
[`runbooks.md`](runbooks.md); this page is the ordered checklist for the day.

---

## Sort these first (or the test stalls)

Two things the lab machine depends on that aren't fully wired yet. Decide how you
handle each **before** you start:

### 1. The server is on NAT — lab machines can't reach it

The lab machine will need the server for **three** things during a converge: the
**apt cache** (`apt_proxy_url` → `cd108.tutu.eng.br:3142`), the **golden
`zfs recv`**, and the **SDR++ artifact**. The server VM is currently on NAT
(`192.168.122.150`), reachable only from the control node — a machine out on the
lab LAN can't see it.

- **Best:** bridge the server VM onto the lab LAN so it has a `103.0.x` address,
  then point `server_host` / the `server` host's `ansible_host` at it. (Ask for
  help with the bridge — it's a libvirt network change on the control node.)
- **Fallback for the shakeout:** skip the server-dependent parts this run. Set
  `apt_proxy_url: ""` for the test host (direct apt), and validate `common`,
  `desktop`, and ZFS **pool creation** only — defer the golden `zfs recv` and
  SDR to a manual test (below).

### 2. First-connect key bootstrap

A freshly imaged machine boots with the ext4 image but **no ZFS homes yet**, so
`daelt`'s `~/.ssh/authorized_keys` (which lives on ZFS) isn't there — Ansible's
deploy key has nothing to authenticate against until the pool is built and homes
received. Chicken-and-egg.

- **Simplest for one machine:** drop the deploy key in over the **console** right
  after boot (same move we used for the server — see
  [troubleshooting → serial console](troubleshooting.md#getting-into-a-vm-when-ssh-is-down-serial-console),
  but here it's the physical console/keyboard):
  ```bash
  # on the machine, as daelt:
  mkdir -p ~/.ssh && chmod 700 ~/.ssh
  echo '<contents of ~/.ssh/id_cd108_ansible.pub>' >> ~/.ssh/authorized_keys
  chmod 600 ~/.ssh/authorized_keys
  ```
- **Permanent fix (bake into the image):** put the deploy key in an image-owned
  location sshd reads regardless of ZFS, e.g. `/etc/ssh/authorized_keys.d/daelt`
  with `AuthorizedKeysFile .ssh/authorized_keys /etc/ssh/authorized_keys.d/%u`
  in `sshd_config`, then capture the image. Then first-connect just works.

---

## Stage 0 — pre-flight (from the control node)

```bash
cd <repo>
ansible server -m ping                 # server reachable + goldens present?
ssh -i ~/.ssh/id_cd108_ansible daelt@<server-ip> \
  'zfs list -t snapshot -r ssdpool/golden | grep -E "@(golden|ltspice)"'
```
Have ready: the Clonezilla Live USB, the Ubuntu golden image, the machine's
**MAC**, the vault password, and physical/console access to the machine.

## Stage 1 — image the machine

Follow [runbooks → Re-image a machine](runbooks.md#re-image-a-machine-clonezilla):
boot the machine from the Clonezilla USB, `device-image` → `restoreparts` the
ext4 system partition. Reboot when done.

## Stage 2 — boot and reach it

The machine comes up carrying the golden's hostname. Add it to
`inventory/hosts.yml` under `cd108` with its **MAC** (see
[runbooks → Add a lab machine](runbooks.md#add-a-lab-machine)); its IPv6
`ansible_host` is computed for you. Then, from the control node:

```bash
ansible <hostname> -m ping             # may fail until Stage 3 (key bootstrap)
```
If the IPv6 doesn't resolve yet, pin a temporary `ansible_host: <ipv4>` on the
host to get moving.

## Stage 3 — bootstrap Ansible access

Do the key bootstrap from "Sort these first #2". Re-test:
```bash
ansible <hostname> -m ping             # expect pong
```

## Stage 4 — converge, incrementally

Roles are tagged, so build up in safe steps rather than all at once. Dry-run each
before applying.

```bash
# 4a. base system — packages, users, hostname, WoL, deploy key
ansible-playbook site.yml --limit <hostname> --tags common --check --diff --ask-vault-pass
ansible-playbook site.yml --limit <hostname> --tags common --ask-vault-pass

# 4b. desktop — XFCE + xrdp
ansible-playbook site.yml --limit <hostname> --tags desktop --ask-vault-pass

# 4c. ZFS — builds the pool on the empty labelled partition (safe: guarded)
#     and receives the golden homes/windows (this part needs the server reachable)
ansible-playbook site.yml --limit <hostname> --tags zfs --check --diff --ask-vault-pass
ansible-playbook site.yml --limit <hostname> --tags zfs --ask-vault-pass
```
> If the server isn't bridged yet, 4c's **pool creation** still works, but the
> `zfs recv` steps will fail to reach the server — that's expected. Validate the
> pool, then test the receive manually (below) or after bridging.

Once the homes/Windows VM are in place, the rest:
```bash
ansible-playbook site.yml --limit <hostname> --tags winvm,sdr,matlab --ask-vault-pass
```

## Stage 5 — validate (checklist)

```bash
ssh -i ~/.ssh/id_cd108_ansible daelt@<hostname> '
  hostnamectl --static                 # real hostname set from inventory
  zpool list ssdpool                   # pool built
  zfs list -r ssdpool/home             # course homes received
  systemctl is-active xrdp             # remote desktop up
  getent group docker                  # course accounts in docker
  systemctl is-active sanoid.timer     # snapshots scheduled
  ls /mnt/ssdpool/windows 2>/dev/null  # Windows VM disk present (if winvm ran)
'
```
Then spot-check by hand: RDP into it, open a course account, confirm
STM32CubeIDE/MATLAB launch from the received home, and that the "Windows VM
(Reset)" launcher reverts and connects.

## If you need to test the golden receive manually

While the server is on NAT, you can prove the `zfs send/recv` concept by relaying
through the control node (same pattern as `harvest-golden.yml`), instead of the
role's server→student path:

```bash
ssh -i ~/.ssh/id_cd108_ansible daelt@<server-ip> \
  'sudo zfs send -R ssdpool/golden/home/estudante@golden' \
  | ssh -i ~/.ssh/id_cd108_ansible daelt@<hostname> \
      'sudo zfs recv -F ssdpool/home/estudante'
```

## Rollback

Nothing here is hard to undo: re-image the machine to start over, or
`sudo zpool destroy ssdpool` on the test machine to redo just the ZFS stage.
The server and the goldens are untouched by this test.

---

### What this shakeout will teach us

- Does the ext4 image + Ansible converge produce a working student machine?
- Is the **first-connect** bootstrap smooth enough, or do we need the image-baked
  key (fix #2)?
- Does the **server need bridging** before any real rollout? (Almost certainly
  yes — note it and plan it.)
- Does the `zfs` role's server→student receive path work, or should it relay
  through the control node like the harvest does?
