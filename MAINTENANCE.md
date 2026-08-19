# Lab maintenance runbook (cd108 / cd106)

Everything below is done **from the lab server** (`cd108-server`) with the
`./fleet` script at the repo root. You do **not** need to be in the lab — the
server can wake, patch, reboot and shut down every machine remotely.

```bash
ssh daelt@cd108.tutu.eng.br      # into the server (holds inventory + vault + WoL)
cd ~/cd108_ansible
git pull                         # make sure fleet + roles are current
./fleet status all
```

> Run `./fleet` with no arguments for the built-in help.
> A **TARGET** is a host (`cd108-05`), a comma list (`cd108-05,cd108-06`), a
> room/group (`cd108`, `cd106`, `labs`), or `all`.

---

## The four things you'll do most

| Task | Command |
|------|---------|
| See who's alive | `./fleet status all` |
| **Wake** a machine (or a room) | `./fleet wake cd108-05` · `./fleet wake cd108` |
| **Reboot** (waits for it to come back) | `./fleet reboot cd108-05` |
| **Shut down** (bring back with `wake`) | `./fleet shutdown cd108-05` |
| **Update** apt + VS Code | `./fleet update labs` |

### Wake → shut down cycle (the remote-friendly pattern)
```bash
./fleet wake cd108           # power the room on
# ...do the work...
./fleet update cd108         # patch it
./fleet shutdown cd108       # power it back off
```
`wake` sends the magic packet, waits are on you (give it 1–2 min), then
`./fleet status cd108` confirms they came up. `reboot` is self-verifying — it
blocks until each host answers SSH again, and reports any that don't return.

### Patching (includes VS Code)
```bash
./fleet update labs
```
This runs `apt update` + `apt full-upgrade`. VS Code ships from Microsoft's apt
repo as the `code` package, so it upgrades in the same pass. (If a machine ever
has VS Code as a snap instead, add `./fleet ssh <host>` → `sudo snap refresh`.)

---

## Occasional / heavier tasks

| Task | Command | Notes |
|------|---------|-------|
| Full re-converge | `./fleet converge cd108-11` | idempotent; safe to re-run |
| Re-apply the EFI (WoL-brick) fix only | `./fleet efifix cd108-07` | fast; no full converge |
| **Reset homes to the golden** | `./fleet restore-homes cd108` | **destructive** — see below |
| Inspect boot order | `./fleet boot cd108-05` | should read `BootOrder` with `ubuntu` first, no Windows |
| List MACs | `./fleet macs cd108` | |
| Shell into one box | `./fleet ssh cd108-05` | |
| Hardware inventory | `python3 scripts/fleet-hw.py` | from the phone-home beacons |

### Reset homes to a clean state
`./fleet restore-homes <target>` re-sends the freshly-built **golden home** from
the server onto each machine (wrapper around `reset-homes.yml`). It **wipes
whatever is in the local homes** — run it only after students have uploaded
their work to the cloud, typically 2–3× per semester. It rolls in waves of 4
machines and prompts before doing anything (`FLEET_YES=1` to skip the prompt).

---

## Before you leave the lab — one-time checks (important)

These are the things that will bite you 3 months from now if they're not true.
**Verify them while you can still physically touch the machines.**

1. **Prove Wake-on-LAN works from a full power-off.** We've confirmed *reboots*
   come back, but true WoL from S5 needs each machine's BIOS to have
   *Wake on LAN / PME / "Power On by PCIe"* enabled and *ErP/EuP disabled*. Test
   it for real, per model:
   ```bash
   ./fleet shutdown cd108-05
   # wait ~20s for it to power down, then:
   ./fleet wake cd108-05
   ./fleet status cd108-05        # UP within ~1 min = WoL-from-off works
   ```
   If it does **not** come up, fix it in that machine's BIOS now — you can't do
   it remotely. Repeat for at least one machine of each motherboard model.

2. **The server is the single point of control.** `./fleet` only works while
   `cd108-server` is powered and reachable. That means the host it runs on
   (moritz-pc) must stay on, the server VM must be running, and
   `cd108.tutu.eng.br:22` must be reachable from wherever you'll be. Confirm you
   can SSH in from **off-campus** (VPN or public route) — not just from the lab.

3. **Keep the vault password.** `~/.vault_pass` on the server decrypts the
   inventory and drives `sudo`. Without it, `fleet` converge/update/reset break.
   Make sure it's backed up somewhere you'll still have in 3 months.

4. **Addressing depends on the phone-home beacon.** Machines are reached at the
   IP from their last boot beacon. A box that's been off a long time and comes
   up on a new IP is unreachable until it beacons again — which it does right
   after `wake`. So the habit is always: **`wake` first, then act.**

---

## When something won't respond

- **`status` says DOWN after `wake`.** Either it's genuinely powered off with
  WoL disabled in BIOS (check #1 above), or it hasn't finished booting — wait a
  minute and re-check. A machine that never wakes needs a physical power button.
- **Reachable but `sudo`/converge fails.** Almost always a missing/renamed
  `~/.vault_pass`, or the machine isn't converged yet (`./fleet boot` /
  `converge`).
- **Boots into a Windows BSOD / dead to WoL.** That's the phantom Windows Boot
  Manager — `./fleet efifix <host>` (or a full `converge`) removes it. Every
  converged machine is already clean; see the `phantom-windows` history.
- **A whole room is gone.** Check the server itself is up and on the lab L2, and
  that the NIC uplink hasn't hung (`scripts/fix-e1000e-hang.sh` on the KVM host).

---

## Still open (not covered by `fleet`)

- **Auto-sleep is not armed.** No machine currently has `autosleep.timer`
  installed, so nothing suspends on its own. If you want nightly suspend + WoL
  to save power, that feature still needs to be enabled (it's vault-gated) — and
  it's only safe once check #1 (WoL-from-off) passes fleet-wide.
- **Unattended security updates** are not enabled; patching is manual via
  `./fleet update`. Consider `unattended-upgrades` if you'd rather not remember.
