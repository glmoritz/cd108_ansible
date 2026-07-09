# Troubleshooting

Real problems we hit setting this up, and how to fix them. Skim the headings.

## "Server accepts key" then Permission denied

```
debug1: Server accepts key: ... id_ed25519 ...
daelt@host: Permission denied (publickey).
```
The server has your key, but the client **couldn't sign the challenge** — almost
always because the private key is **passphrase-protected and there's no
ssh-agent** in the shell (common in scripts/cron). It is *not* a server problem.

**Fix:** use the passphrase-less **deploy key** for automation:
`-i ~/.ssh/id_cd108_ansible` (Ansible already does this via
`ansible_ssh_private_key_file`). Confirm a key is passphrase-less with
`ssh-keygen -y -P "" -f <key>` (succeeds = no passphrase).

## IPv6 in an NFS/sharenfs ACL breaks exportfs

```
exportfs: Failed to resolve c004
exportfs: Invalid IP address /64
```
`exportfs` splits an IPv6 prefix on its colons, even bracketed. We export NFS to
the **IPv4 subnet only** (`nfs_share_acl: "rw=@103.0.0.0/19"`). NFS ACLs are
by-subnet so dynamic IPs are fine; SSH/Ansible still use IPv6/EUI-64. If you see
mangled `[2801`, `<world>`, `82`, `c004` export entries, clear them:
```bash
sudo zfs set sharenfs=off ssdpool/golden && sudo exportfs -ra
# then re-run prepare-server.yml to set the correct IPv4-only share
```

## Getting into a VM when SSH is down (serial console)

```bash
virsh console cd108-server          # Escape is Ctrl+]  (^])
```
Log in with `daelt` + the password (SSH may be key-only, but the console isn't).
**Always log out (`exit`) before detaching** — if you detach with `^]` while
still logged in, the next `virsh console` lands in your old shell and scripts get
confused. If the console shows nothing, press Enter; if a script hangs on it,
`pkill -9 -f 'virsh console <vm>'`.

## Vault prompt when you just want a syntax check

Pointing Ansible at the inventory **directory** loads the encrypted
`group_vars/cd108/vault.yml`, which demands the vault password. For read-only
checks, point at the **file** instead (empty lab groups, no vault):
```bash
ansible-playbook --syntax-check site.yml -i inventory/hosts.yml
ansible-inventory --graph -i inventory/hosts.yml
```

## A group_vars file is silently ignored

If both `group_vars/cd108.yml` and `group_vars/cd108/` (a directory) exist,
Ansible loads the **directory** and ignores the file. Keep one form. We use the
directory (`cd108/main.yml` + `cd108/vault.yml`).

## New VM won't take config / cloud-init re-runs

If the autoinstall **seed ISO is still attached**, cloud-init can re-trigger on
boot. Eject and delete it after install:
```bash
virsh change-media cd108-server hdb --eject --config
virsh vol-delete --pool vmstore cd108-server-seed.iso
```

## `zfs recv` of a golden home tries to mount over /home

The golden's `ssdpool/home` has `mountpoint=/home`; received onto the server it
would shadow the server's own `/home`. Always receive with `-u` (no auto-mount)
and re-park it:
```bash
sudo zfs recv -u ssdpool/golden/home
sudo zfs set mountpoint=/mnt/ssdpool/golden/home ssdpool/golden/home
```
(`harvest-golden.yml` does both for you.)

## apt-cacher-ng: HTTPS repos fail through the proxy

apt-cacher-ng only proxies **http**. The `common` role writes the correct
`/etc/apt/apt.conf.d/01proxy` (http proxied, https disabled, IPv4 forced). If a
repo is https-only, it must bypass the cache — that's expected.

## WoL didn't enable on a machine

`wol_interface` defaults to the fact-discovered NIC
(`ansible_default_ipv4.interface`), because names vary (`eno1`/`enp3s0`/…). If a
machine has an odd default route, set `wol_interface` for that host explicitly.
