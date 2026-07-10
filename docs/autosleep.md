# Auto-sleep — nightly scan-and-sleep of idle lab machines

One timer on the **hub** (`server` role) powers down idle machines at night, so
labs don't burn electricity overnight. It replaces a per-machine sleep unit: the
hub reads a target list rendered from the inventory, probes each machine, and for
any that answers it SSHes in as `{{ admin_user }}` (the deploy key) and runs
`systemctl <action>`. Machines that don't answer are already off — skipped.

Wake-up in the morning is Wake-on-LAN (the `common` role enables the magic-packet
`wol g` on each NIC).

## What gets slept

Every host in the `labs` group **minus** the groups in `autosleep_exclude_groups`
(default `[ca307, no_autosleep]`). The list is regenerated from the inventory on
every server converge, into `/etc/cd108/autosleep-targets` on the hub.

## Spare a machine or a room

- **A whole room** — add its group to `autosleep_exclude_groups` in
  `inventory/group_vars/all.yml` (e.g. `ca307` is already spared).
- **One machine** (a professor PC, a server-ish box) — add it to the
  `no_autosleep` group in `inventory/hosts.yml`. It stays in its lab group too:
  ```yaml
  no_autosleep:
    hosts:
      cd108-00:      # professor PC
      cb203-05:      # add each lab's professor machine
  ```

## Change the schedule / action / on-off

In `inventory/group_vars/all.yml`:

| var | default | notes |
|---|---|---|
| `autosleep_enabled` | `true` | `false` stops & disables the timer |
| `autosleep_oncalendar` | `*-*-* 00:00:00` | any systemd `OnCalendar` (e.g. `Mon..Fri 01:30`) |
| `autosleep_action` | `suspend` | `suspend` \| `poweroff` \| `hibernate` |

## Apply changes

Re-converge the hub — this re-renders the targets and updates the units:

```bash
ansible-playbook site.yml --limit cd108.tutu.eng.br --tags server \
  --vault-password-file <pw> --become-password-file <pw>
```

## Run it now / test it

On the hub:

```bash
sudo systemctl start autosleep.service     # run the sweep immediately
journalctl -u autosleep.service -n 50      # see what it slept / skipped
systemctl list-timers autosleep.timer      # next scheduled run
```

The script logs one line per machine (`slept … / offline, skipped …`) plus a
summary count.

## Requirements & caveats

- **The hub must reach the lab LAN.** While the server VM is on NAT
  (`192.168.122.150`) it can't reach the machines' EUI-64 IPv6 addresses, so
  auto-sleep is a no-op until the server is bridged onto the lab network.
- Sleeping over SSH works because `common` installs a **scoped** sudoers rule
  (`/etc/sudoers.d/30-autosleep`) allowing `{{ admin_user }}` to run only
  `systemctl suspend|poweroff|hibernate` without a password.
- It sleeps **any** machine that's on — it does not check for logged-in users or
  running jobs. Spare boxes that must stay up via `no_autosleep`.
