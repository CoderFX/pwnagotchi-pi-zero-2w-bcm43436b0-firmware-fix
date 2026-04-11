# Troubleshooting

Every error message the installer, uninstaller, or verifier can print, what it means in plain English, and how to get past it. Sorted roughly by what phase of the install the user is in.

## Before install

### `install.sh must be run as root`

You invoked the installer without `sudo`. Re-run as:

```
sudo ./scripts/install.sh
```

The installer refuses to run as an unprivileged user because it writes to `/lib/firmware/brcm/`, `/etc/systemd/system/`, `/usr/local/bin/`, and `/var/lib/`.

### `this hardware is not a Raspberry Pi Zero 2 W (read "<...>" from /proc/device-tree/model); refusing to install`

The installer checks `/proc/device-tree/model` and refuses to run on anything that isn't a Pi Zero 2 W. If you see this:

- Confirm you're actually running on the Pi (not in a chroot or an emulator).
- `cat /proc/device-tree/model` should print `Raspberry Pi Zero 2 W` followed by a null byte.
- If you're on a different Pi (Pi 3, 4, 5, Zero W), this patch set is not for you. The other Pis use different WiFi chips (BCM43455, BCM43438, BCM43436) and those chips have different firmware that this patch would not apply to.

There is no bypass for this check. The patch is specific to the BCM43436B0 and would either refuse to apply or silently corrupt firmware on any other chip.

### `unsupported userland architecture: <arch>`

The installer checks `dpkg --print-architecture` (fallback `uname -m`) and expects `arm64` / `aarch64` or `armhf` / `armv7l`. Anything else is refused. If you see this on a Pi Zero 2 W, something unusual is going on — the Pi Zero 2 W physically can only run one of these two userlands.

### `previous install was interrupted and left a partially-installed state. Run sudo ./scripts/uninstall.sh to clean it up before retrying.`

A previous run of `install.sh` crashed or was interrupted before it could finalize. The state file `/var/lib/pwnagotchi-bcm43436b0-fix/state.json` has `phase: "in_progress"`, which means "a previous run placed files on disk but never committed success".

Fix: run `sudo ./scripts/uninstall.sh` to clean up everything the failed run left behind, then re-run `install.sh`. The uninstaller is idempotent, so if there's nothing to clean up it just exits 0.

**Do not delete `state.json` by hand.** It is the only record of what the failed run placed on disk. If you remove it, the next uninstall becomes a no-op and you're left with stray scripts, units, or a partially-patched firmware with nothing to recover it.

## During the firmware phase

### `manifest tampered: <entry>:<field> does not match installer-embedded trusted value`

`patches/manifest.json` was edited after the repo was cloned, and one of its hashes no longer matches the hard-coded `MANIFEST_TRUSTED_HASHES` table inside `install.sh`. The installer refuses to trust either file if they don't agree.

Fix: re-clone the repo from GitHub. Don't edit `manifest.json` by hand.

If you believe you're seeing this error on a freshly-cloned repo, open a GitHub issue and include the first ten lines of your `patches/manifest.json` and the `MANIFEST_TRUSTED_HASHES[...]` entries from your `install.sh`.

### `live firmware SHA-256 <...> does not match any manifest entry`

Your `/lib/firmware/brcm/brcmfmac43436-sdio.bin` is not one of the supported input firmwares. The installer ships with one supported input: the nexmon-patched firmware that jayofelony's pwnagotchi image ships by default.

Common causes and fixes:

- **You're on stock Raspberry Pi OS, not jayofelony's pwnagotchi image.** The patch requires nexmon-patched firmware as its input. Install jayofelony's pwnagotchi image first, then re-run this installer.
- **You're on a newer jayofelony image than this patch was tested against.** If jayofelony updated the nexmon firmware to a different revision, our manifest needs a new entry. Open a GitHub issue with your firmware's SHA-256 (`sha256sum /lib/firmware/brcm/brcmfmac43436-sdio.bin`) and we will add support.
- **You ran another tool that modified the firmware.** Restore jayofelony's nexmon-patched firmware from your pwnagotchi image, then re-run.

The installer deliberately does **not** suggest `apt install --reinstall firmware-brcm80211` here, because that would restore the stock Broadcom firmware rather than the nexmon-patched one we need as input.

### `patch file SHA-256 mismatch`

The `patches/inplace-v7.txt` file was modified after cloning. Re-clone the repo.

### `post-patch SHA-256 mismatch: got <actual>, expected <expected>`

The installer applied the byte patch to a temporary copy of the firmware but the result's SHA-256 doesn't match what `manifest.json` promised. This should never happen on a freshly-cloned repo; the byte diff and the expected output hash come from the same source of truth.

If you see this, do not panic: the live firmware on disk was not touched. The installer aborts before the atomic rename, so the original firmware is still in place. Re-clone the repo and try again. If the error persists, open a GitHub issue.

### `existing backup at <path> has unexpected SHA-256`

There's already a file at `/var/lib/pwnagotchi-bcm43436b0-fix/backups/brcmfmac43436-sdio.<hash>.bin`, but its SHA-256 doesn't match what we expected for that filename. The installer refuses to overwrite it because it might be a legitimate backup from a previous install that the user still needs.

Fix: move or delete the offending file manually (`sudo mv /var/lib/pwnagotchi-bcm43436b0-fix/backups/brcmfmac43436-sdio.<hash>.bin ~/firmware-backup-offending.bin`), then re-run the installer. It will recreate the backup fresh.

## During the userspace phase

### `prebuilt binary failed smoke test, compiling from source`

Not an error — informational. The prebuilt aarch64 or armhf binary in the repo didn't run correctly on your system (wrong arch, missing libc features, etc.), so the installer is falling back to compile-from-source. You'll need `gcc` and `libc6-dev`. The installer will apt-install them automatically if they're missing.

### `wlan_keepalive compile failed; triggering rollback`

Both the prebuilt binary and the compile-from-source fallback failed. This is a real problem — the installer cannot continue and will roll back the firmware patch (if it was applied this run).

Diagnosis:

```
gcc --version
apt-get install -y gcc libc6-dev
```

Confirm you have a working C compiler and headers, then re-run the installer.

## After install

### `verify.sh` reports `wlan0mon not present; keepalive is waiting`

This is a **soft warning**, not a failure. `verify.sh` exits 0 with this warning.

The keepalive daemon is running correctly and sitting in its iface-wait loop, but `wlan0mon` doesn't exist yet because nothing has set monitor mode. On jayofelony's pwnagotchi image, pwnagotchi itself creates `wlan0mon` at startup — so this warning usually means pwnagotchi isn't running (yet). Once pwnagotchi is up, the keepalive will automatically bind to `wlan0mon` and the warning will go away.

### `verify.sh` reports `daemon bound to wrong interface`

Hard failure. Something configured the keepalive service to listen on a different interface than `wlan0mon`. Unlikely to happen unless someone edited `oxigotchi-wlan-keepalive.service` by hand.

Fix: `sudo systemctl stop oxigotchi-wlan-keepalive`, edit `/etc/systemd/system/oxigotchi-wlan-keepalive.service` and verify `ExecStart=/usr/local/bin/oxigotchi-wlan-keepalive wlan0mon 100`, then `sudo systemctl daemon-reload && sudo systemctl start oxigotchi-wlan-keepalive`.

### `verify.sh` reports `firmware does not match state.output_sha256`

Hard failure. The firmware on disk isn't the patched version anymore, even though `state.json` says it should be. Usually means:

- A system update (`apt upgrade`) replaced `firmware-brcm80211`, clobbering your patched firmware.
- Another tool wrote to `/lib/firmware/brcm/brcmfmac43436-sdio.bin`.
- The SD card had bit-rot in exactly the wrong byte.

Fix: `sudo ./scripts/uninstall.sh` (to clean up state), then `sudo ./scripts/install.sh` (to re-apply the patch). If you don't want to lose your existing install state, you can copy `/var/lib/pwnagotchi-bcm43436b0-fix/backups/brcmfmac43436-sdio.<hash>.bin` back to `/lib/firmware/brcm/brcmfmac43436-sdio.bin` manually and then re-run the installer — the SHA-keyed backup is preserved across uninstalls specifically for this case.

### `verify.sh` reports `binary SHA mismatch`

The installed `/usr/local/bin/oxigotchi-wlan-keepalive` has a different SHA than `state.binary_sha256`. Usually means the binary was replaced out-of-band. Re-run the installer to restore it.

## During uninstall

### `no install state found; nothing to uninstall`

Informational, not an error. Exit 0. There's no install to remove. Common after a completed uninstall or on a system that never had this repo installed.

### `backup file at <path> failed safety check`

The uninstaller tried to restore the firmware from `state.backup_path`, but the backup file failed one of the safety checks (missing, wrong size, is a symlink, resolves outside the backups directory, SHA doesn't match what the install recorded). The uninstaller refuses to restore an unknown firmware and leaves `state.json` in place so you can investigate.

Fix: check `/var/lib/pwnagotchi-bcm43436b0-fix/backups/` and compare file sizes and SHAs to what `state.json` says. If the backup is corrupted, your recovery path is either (a) restore jayofelony's original nexmon firmware from the pwnagotchi image and then `rm -rf /var/lib/pwnagotchi-bcm43436b0-fix` to forget the install record, or (b) flash a fresh pwnagotchi image to the SD card.

### `firmware NOT restored: install was an adoption-on-already-patched run`

Soft warning at uninstall time, not an error. Exit 0.

This happens when you ran `install.sh` on a system whose firmware was *already* at the patched state (someone installed it before, or the image pre-baked it). In that case the installer did not take a backup, because there was nothing unpatched to back up. When you uninstall, we cannot revert the firmware, because we never had the unpatched bytes. All the userspace bits (keepalive, watchdog, recovery services, scripts) *are* uninstalled cleanly. The firmware is left in the patched state with this warning.

If you specifically want stock firmware back, reflash the SD card from a known source.
