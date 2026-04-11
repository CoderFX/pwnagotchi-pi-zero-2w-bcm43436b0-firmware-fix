# FAQ

## What does this actually do?

Three things, layered:

1. **Patches the WiFi chip's firmware** in place, 8 byte-level changes, so internal watchdogs don't fire spuriously, fault recovery works, a cascade-prone key-rotation step is disabled, and a null dereference in signal-strength averaging is fixed. See [`LAYERS.md`](https://github.com/CoderFX/pwnagotchi-pi-zero-2w-bcm43436b0-firmware-fix/blob/master/LAYERS.md) for plain-English layer descriptions and [`patches/inplace-v7.txt`](https://github.com/CoderFX/pwnagotchi-pi-zero-2w-bcm43436b0-firmware-fix/blob/master/patches/inplace-v7.txt) for the byte-level facts.
2. **Installs a userspace keepalive daemon** (`oxigotchi-wlan-keepalive`) that continuously reads from `wlan0mon` and injects a broadcast probe every 3 seconds so the SDIO bus between the Pi and the WiFi chip never goes idle. Without this the firmware tends to halt even with all the patches applied, because a silent SDIO bus is a different failure mode than the ones the firmware patches fix.
3. **Installs boot/runtime recovery scripts** that GPIO-power-cycle the WiFi chip via `WL_REG_ON` (GPIO 41) if `wlan0` disappears at boot or during runtime. This is the last-resort recovery for cases where the firmware patches don't prevent a hardware-level SDIO bus death.

## Is it safe? Will it brick my Pi?

It's about as safe as any userspace install can be:

- The firmware patch is byte-level, in-place. Total firmware size does not change (still 414,696 bytes).
- Every byte write is preceded by an "old bytes must equal expected" assertion. If anything mismatches, the installer aborts before touching the live firmware.
- The installer takes a SHA-keyed backup of your current firmware before patching, under `/var/lib/pwnagotchi-bcm43436b0-fix/backups/`. The uninstaller atomically restores from this backup.
- If anything goes wrong between the firmware write and the end of install, the installer automatically rolls back the firmware from the backup before exiting.
- Worst case if something inexplicable happens: reflash the SD card from a fresh pwnagotchi image. The Pi itself cannot be bricked by this — the firmware lives on the SD card, not in the chip's non-volatile memory.

## Why just the Pi Zero 2 W? Why not the Pi 3B+ / Pi 4 / Pi Zero W?

Different chips:

- Pi Zero 2 W: **BCM43436B0** — the chip this patch is for.
- Pi 3B+: BCM43455.
- Pi 4: BCM43455C0.
- Pi 5: (same-family BCM43455).
- Pi Zero W: BCM43438.

The byte offsets in the patch only make sense for the BCM43436B0 firmware revision `9_88_4_65`. Applying them to any other chip would either fail the pre-patch byte assertions or (if it got past them) produce corrupt firmware. The installer hard-refuses on any model string other than `Raspberry Pi Zero 2 W`, and the firmware SHA-256 check catches the chip-mismatch case before any write.

## Do I still need nexmon?

Yes. This patch set is layered **on top of** nexmon's monitor-mode patches. The supported input firmware is the nexmon-patched `brcmfmac43436-sdio.bin` that jayofelony's pwnagotchi image already ships. You also still need nexmon's kernel module (`brcmfmac`) for monitor-mode netlink and frame injection — this patch only touches the firmware blob and some userspace pieces, not the kernel driver.

## Can I use this with bettercap instead of AngryOxide?

Yes. The patch is tool-agnostic — it fixes the underlying WiFi chip, and anything that drives the chip hard benefits. Bettercap, AngryOxide, hcxdumptool, wireshark in monitor mode, or just plain `tcpdump -i wlan0mon` all work the same way. The only assumption the patch makes about your userspace tool is that something creates `wlan0mon` (which bettercap, pwnagotchi, and AngryOxide all do). If you're running on an image where `wlan0mon` is not automatically created at boot, the keepalive daemon will sit in its iface-wait loop until something else creates it.

## What happens if I `apt upgrade` and it replaces the firmware?

A system update that installs the `firmware-brcm80211` Debian package will overwrite `/lib/firmware/brcm/brcmfmac43436-sdio.bin` with stock Broadcom firmware, clobbering both nexmon's patches and this patch set. After the upgrade, `verify.sh` will fail with "firmware does not match state.output_sha256".

Recovery:

```
sudo ./scripts/uninstall.sh    # clean up state
# Reinstall jayofelony's nexmon-patched firmware. On a pwnagotchi image
# this usually means restoring from /root/firmware-bak/ or re-running
# whatever bootstrap script the image uses.
sudo ./scripts/install.sh      # re-apply this patch on top
```

To prevent this from happening again, either:

- Hold the firmware-brcm80211 package: `sudo apt-mark hold firmware-brcm80211`.
- Or stop running `apt upgrade` on your pwnagotchi image — pwnagotchi images are not usually meant to be upgraded in place anyway.

## What happens if pwnagotchi updates itself?

Pwnagotchi's auto-update touches pwnagotchi's Python code, not the firmware or the kernel module. This patch set is **not** affected by pwnagotchi updates. The keepalive daemon and recovery scripts live under `/usr/local/bin/` and `/etc/systemd/system/`, outside pwnagotchi's install tree.

The one exception: if a pwnagotchi update introduces a new systemd unit with the same name as one of ours (`oxigotchi-wifi-watchdog.service` etc.), there would be a collision. We prefixed everything with `oxigotchi-` specifically to make this unlikely; there is no pwnagotchi unit with that prefix.

## Can I reboot after installing?

Yes, a reboot is **recommended** after install so the boot oneshots (`oxigotchi-wifi-recovery`, `oxigotchi-fix-ndev`) run in their normal `Before=` ordering alongside pwnagotchi's startup. At install time we deliberately do not activate the boot oneshots — they only run on next boot — because doing so would race the installer's own `modprobe -r brcmfmac && modprobe brcmfmac` cycle.

The firmware patch and the `oxigotchi-wlan-keepalive` daemon are already active without a reboot.

## Can I install this without pwnagotchi?

Yes, but it's not a tested configuration. The requirements are:

- Pi Zero 2 W hardware.
- Raspberry Pi OS bookworm (aarch64 or armhf).
- nexmon's `brcmfmac` kernel module (for monitor-mode netlink and `wlan0mon`).
- nexmon's patched `brcmfmac43436-sdio.bin` firmware — currently only available via the jayofelony pwnagotchi image. If you're not on pwnagotchi, you'd have to build nexmon yourself and install its firmware first.

If any of these are missing, the installer will hard-refuse during its pre-checks and tell you exactly what's missing.

## Why no `curl | sudo bash` one-liner?

Because the installer depends on files in `patches/`, `userspace/`, and `services/` that ship alongside it. A standalone `install.sh` fetched via curl would abort at step 4 (manifest load) because there'd be no `manifest.json` next to it. We could have made the installer self-fetching and manifest-verified, but that adds real complexity (signed release archives, pinned commit SHAs, tarball verification) that the v1 release doesn't ship.

## Is the repo signed?

Not in v1. The `install.sh` hard-codes a `MANIFEST_TRUSTED_HASHES` table that pins every hash in the manifest (input firmware, output firmware, patch file, both binaries), so a single-file edit to `manifest.json` is caught. But a coordinated edit that modifies both `manifest.json` AND `install.sh` in the same commit defeats that tripwire — there's no cryptographic root of trust below the repo itself.

Signed git tags and tarball release verification are filed for v1.1. Until then, the `NOTICE` file documents the trust model loudly so users can make an informed decision.

## Can I re-install on top of an existing install?

Yes. Re-running `install.sh` on a system where a previous install completed successfully is a supported workflow. The installer snapshots your existing `state.json` to `state.json.previous` before overwriting it, so if the re-install crashes early the uninstaller can still recover from the snapshot.

Re-running `install.sh` on a system where a previous install crashed (`phase: "in_progress"`) is **not** automatic — the installer refuses and tells you to run `uninstall.sh` first. This is intentional: automatically overwriting an in-progress state file would destroy the only record of what the failed run placed on disk.

## Why doesn't `verify.sh` check the kernel module too?

Because the kernel module is nexmon's, not ours. We don't ship it, we don't patch it, and we don't have opinions about which version you're running. `verify.sh` checks the firmware SHA, the keepalive binary SHA, and the four systemd units — everything this repo put on disk.

## I want to report a bug

Open an issue at <https://github.com/CoderFX/pwnagotchi-pi-zero-2w-bcm43436b0-firmware-fix/issues>. Useful information to include:

- `cat /proc/device-tree/model`
- `sudo ./scripts/verify.sh` (full output)
- Relevant lines from `journalctl -u oxigotchi-wlan-keepalive.service`
- Relevant lines from `dmesg | grep -E 'brcmfmac|mmc1'`
- Which pwnagotchi image (jayofelony release tag or commit) you're running
- Which architecture (aarch64 vs armhf)

Please don't paste the full `dmesg` or journal — just the relevant brcmfmac / mmc1 / `oxigotchi-wlan-keepalive` lines.
