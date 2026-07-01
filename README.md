# pwnagotchi-pi-zero-2w-bcm43436b0-firmware-fix

Stability fix for the Raspberry Pi Zero 2 W's BCM43436B0 WiFi chip when used
with pwnagotchi / AngryOxide for long monitor-mode captures. Combines a
byte-level firmware patch, a tiny userspace keepalive daemon, and a set of
boot-time and runtime recovery scripts so that the WiFi chip stops crashing
every 2-5 minutes under sustained load.

## What it fixes

Without this repo, a Pi Zero 2 W running pwnagotchi with AngryOxide (or any
other monitor-mode tool that drives the BCM43436B0 hard) tends to:

- Crash the WiFi firmware every 2-5 minutes under injection + passive scan
  load ("Firmware has halted" in dmesg, radio resets, restart storms).
- Drop the SDIO bus entirely, so `wlan0` disappears and even `modprobe -r
  brcmfmac && modprobe brcmfmac` cannot bring it back — only a GPIO power
  cycle of the chip or a full reboot does.
- Lose `wlan0mon` separately when the firmware is alive but the monitor path
  is stuck.
- Cascade into a reboot loop when pwnagotchi keeps restarting on top of a
  dead radio.

With this repo installed:

- The firmware is patched in place (8 layers, all within the existing
  414,696-byte image — nothing appended) to relax internal watchdog
  thresholds, recover from fault categories that used to kill the radio,
  disable a key-rotation step that triggers cascade failures, and harden
  signal-strength averaging against a specific stress pattern.
- A ~20 KB userspace daemon (`oxigotchi-wlan-keepalive`) reads from
  `wlan0mon` continuously and injects a broadcast probe every 3 seconds so
  the SDIO bus never goes idle.
- A boot oneshot (`oxigotchi-wifi-recovery`) runs before pwnagotchi /
  bettercap and, if `wlan0` is missing at boot, power-cycles the WiFi chip
  via the WL_REG_ON GPIO pin to recover from SDIO bus death.
- A runtime watchdog (`oxigotchi-wifi-watchdog`) continuously monitors
  `wlan0` / `wlan0mon` and does the same GPIO power cycle if they
  disappear later.
- An early-boot helper (`oxigotchi-fix-ndev`) runs a modprobe cycle within
  the first 120 seconds of uptime if the kernel reports SDIO bus errors in
  dmesg.

## What it does NOT fix

- This repo does **not** replace nexmon's `brcmfmac.ko` kernel module. You
  still need the nexmon monitor-mode module for any of this to be useful,
  because without monitor mode there is nothing to keep alive. On
  jayofelony's pwnagotchi image the module is already installed; that's
  the assumed target audience.
- This repo only addresses the **BCM43436B0** chip used on the Pi Zero 2 W.
  The Pi 3B+, Pi 4, and Pi 5 use BCM43455 / BCM43438 / entirely different
  chips; their firmware is not touched and is not supported.
- This repo does not install, configure, or manage pwnagotchi or AngryOxide
  themselves. You're expected to already have your attack tool of choice.

## Check if you need this

Not all Pi Zero 2 W boards have the same WiFi chip. Check yours first:

```bash
dmesg | grep -oP 'chip BCM\S+'
```

- **BCM43436B0** → you likely have the crash bug. This fix is for you.
- **BCM43430/1** → your chip does not have this bug. No fix needed.

The installer will also detect this automatically and exit if your chip
doesn't need patching.

## Compatibility

- **Hardware**: Raspberry Pi Zero 2 W only. The installer hard-refuses any
  other model (checked against `/proc/device-tree/model`).
- **Chip**: BCM43436B0 only. BCM43430/1 chips do not suffer from this crash
  bug and the firmware patch is incompatible with them. The installer
  detects the chip and exits cleanly if it's not BCM43436B0.
- **OS**: Raspberry Pi OS bookworm (aarch64 or armhf userland). The
  installer auto-detects the userland arch via `dpkg --print-architecture`
  (with `uname -m` as fallback) and installs the matching prebuilt
  `wlan_keepalive` binary. If the prebuilt binary fails a smoke test, the
  installer falls back to compile-from-source using `gcc`.
- **Firmware source**: tested on the nexmon-patched
  `brcmfmac43436-sdio.bin` shipped by jayofelony's pwnagotchi image
  (<https://github.com/jayofelony/pwnagotchi>). Other sources may also work
  if their SHA-256 happens to match a manifest entry, but we do not test
  anything else.

## Read this before installing

This release is **unsigned**. The installer hard-codes a trusted hash table
for every file it's going to apply and refuses to run against a tampered
`manifest.json`, but that is a tripwire, not a cryptographic signature.
See [`NOTICE`](NOTICE) for the full tamper-evidence caveat and the
good-faith legal stance on shipping byte-level patch facts without
shipping any firmware bytes.

No `curl | sudo bash` one-liner is offered. The installer needs files
from `patches/`, `userspace/`, and `services/` that ship alongside it, so
running the script alone would fail.

## Install

```
git clone https://github.com/CoderFX/pwnagotchi-pi-zero-2w-bcm43436b0-firmware-fix.git
cd pwnagotchi-pi-zero-2w-bcm43436b0-firmware-fix
sudo ./scripts/install.sh
```

The installer will:

1. Verify you're on a Pi Zero 2 W.
2. Validate every hash in `patches/manifest.json` against the trusted
   table hard-coded inside `install.sh`.
3. Take a SHA-keyed backup of your current firmware into
   `/var/lib/pwnagotchi-bcm43436b0-fix/backups/`.
4. Apply the byte patch to a temp file, verify the resulting SHA matches
   the expected output hash, then atomically rename into place.
5. Install the `oxigotchi-wlan-keepalive` daemon (prebuilt binary if it
   passes a smoke test; compile-from-source otherwise).
6. Install the three recovery/watchdog shell scripts and their four
   systemd units.
7. Reload `brcmfmac` and start the keepalive daemon. The boot oneshots
   are **enabled but not started** — they run on next boot in their
   normal `Before=` / `After=` ordering.
8. Write a `state.json` recovery anchor so `uninstall.sh` knows exactly
   what to clean up.

A reboot is recommended after install so the boot oneshots run in their
normal ordering, but the firmware patch and keepalive are already active.

## Verify

```
sudo ./scripts/verify.sh
```

Hard checks: model is Pi Zero 2 W, `state.json` exists and parses, live
firmware SHA matches `state.output_sha256`, keepalive binary SHA matches
`state.binary_sha256`, every recorded service is installed + enabled + in
the right active state, `wlan0` is present, and the keepalive daemon has
bound to `wlan0mon` (read out of its own journal self-report).

Exit codes:

- `0` all hard checks passed
- `1` a hard check failed
- `2` `state.json` missing — not installed (or already uninstalled)

## Uninstall

```
sudo ./scripts/uninstall.sh
```

Fully idempotent: running it twice is a no-op the second time. Only
touches files that `state.json` records as having been placed by this
repo. Never touches files we didn't install. If the install took a valid
backup of your original firmware, uninstall will atomically restore it
and reload `brcmfmac`; otherwise (adoption-on-already-patched install
path) it cleans up the userspace artifacts and leaves the firmware in
the patched state with a loud warning.

## What the patch does

See [`LAYERS.md`](LAYERS.md) for a plain-English description of each of
the eight stability layers. Short version: three internal watchdog
thresholds are raised, fatal-error reporting is softened into a counter,
three memory-fault recovery paths catch progressively wider categories of
hardware exceptions, a key-rotation step that triggers cascade failures is
disabled, and a signal-strength averaging step gets a null check it was
missing.

The concrete byte-level changes are in [`patches/inplace-v7.txt`](patches/inplace-v7.txt).
Format and auditor-facing notes are in [`patches/README.md`](patches/README.md).

## Stress test results

On a Pi Zero 2 W running pwnagotchi + AngryOxide against a saturated 2.4
GHz environment, the patched firmware has survived 27,982 frames captured
in a 5-minute window with zero WiFi crashes. Before the patch, the same
setup would reliably kill the radio within 2-5 minutes.

## Credits

- [nexmon](https://github.com/seemoo-lab/nexmon) — the upstream
  monitor-mode kernel module and firmware patch framework that this work
  layers on top of.
- [jayofelony/pwnagotchi](https://github.com/jayofelony/pwnagotchi) — the
  maintained pwnagotchi image this fix is targeted at.
- CoderFX — authored the 8-layer stability patch set and the
  userspace plumbing in this repo.

## License

MIT. See [`LICENSE`](LICENSE) for the license text and [`NOTICE`](NOTICE)
for the legal disclaimer about shipping byte-level patch facts for a
proprietary firmware without shipping the firmware itself.
