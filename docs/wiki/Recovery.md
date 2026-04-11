# Recovery

What to do when something is wrong. Ordered from least invasive (run the uninstaller) to most invasive (reflash the SD card).

## First: what state are you in?

Before taking any recovery action, figure out what's actually broken. The most useful commands:

```
sudo ./scripts/verify.sh
cat /proc/device-tree/model
ls /lib/firmware/brcm/brcmfmac43436-sdio.bin
ls -la /var/lib/pwnagotchi-bcm43436b0-fix/
sha256sum /lib/firmware/brcm/brcmfmac43436-sdio.bin
systemctl status oxigotchi-wlan-keepalive.service
journalctl -u oxigotchi-wlan-keepalive.service -n 30
dmesg | grep -E 'brcmfmac|mmc1' | tail -20
ip link show
```

Run those first. They will tell you which of the paths below to take.

## Path 1: install crashed partway through, system half-installed

**Symptom:** `state.json` exists with `phase: "in_progress"`. Services might be partially installed. WiFi may or may not be working.

**Recovery:**

```
sudo ./scripts/uninstall.sh
```

The uninstaller is designed for exactly this case. It reads `state.json.previous` (if a previous successful install was snapshotted), merges the file lists across both records, and uses the live firmware SHA to decide whether to restore the firmware. If the firmware was written by the failed run, it's rolled back to `state.backup_path`. If the failed run crashed before touching the firmware, step 5 skips the restore and just cleans up userspace.

After the uninstaller completes cleanly, you can re-run `sudo ./scripts/install.sh`.

## Path 2: firmware is patched, services are running, but something is wrong

**Symptom:** `verify.sh` reports one of the hard checks failing (binary SHA mismatch, wrong interface binding, service not active, etc.). Install looks "done" but is not healthy.

**Recovery:**

Start with the least invasive option:

```
# Restart just the keepalive
sudo systemctl restart oxigotchi-wlan-keepalive.service
sudo ./scripts/verify.sh
```

If that doesn't fix it:

```
# Reload the kernel module to rebuild wlan0mon
sudo systemctl stop oxigotchi-wlan-keepalive.service
sudo modprobe -r brcmfmac
sleep 2
sudo modprobe brcmfmac
sleep 3
# If pwnagotchi is running, it will re-create wlan0mon at its next epoch.
# Otherwise, re-create it manually, e.g.:
# sudo airmon-ng start wlan0
sudo systemctl start oxigotchi-wlan-keepalive.service
sudo ./scripts/verify.sh
```

If that still doesn't fix it, reinstall on top:

```
sudo ./scripts/uninstall.sh
sudo ./scripts/install.sh
sudo ./scripts/verify.sh
```

## Path 3: WiFi is fully dead, even after reboot

**Symptom:** `wlan0` does not appear at all. `dmesg | grep brcmfmac` shows errors. `ip link show` has no wlan device.

**Diagnosis first:**

```
dmesg | grep -E 'brcmfmac|mmc1'
```

Look for:

- `card removed` → SDIO bus death. The chip needs a full power cycle.
- `Firmware has halted` → firmware crashed before it could be driven hard enough to benefit from the patches.
- `bus is down` → same category as card removed.

**Recovery — try in order:**

### 3a. Let the boot recovery do its job

If you rebooted and `wlan0` is still missing 15 seconds after boot, the `oxigotchi-wifi-recovery.service` oneshot should have already tried to recover it. Check whether it ran:

```
systemctl status oxigotchi-wifi-recovery.service
journalctl -u oxigotchi-wifi-recovery.service
```

If the service exited successfully but `wlan0` is still missing, its GPIO power cycle didn't help. Move to 3b.

### 3b. Manual GPIO power cycle

If for some reason the recovery service didn't run, or you're on a system where it's not installed, you can manually do what it does:

```
sudo systemctl stop pwnagotchi
sudo systemctl stop bettercap
sudo modprobe -r brcmfmac
echo '3f300000.mmcnr' | sudo tee /sys/bus/platform/drivers/mmc-bcm2835/unbind
sudo pinctrl set 41 op dl    # WL_REG_ON LOW (chip power off)
sleep 3
sudo pinctrl set 41 op dh    # WL_REG_ON HIGH (chip power on)
sleep 2
echo '3f300000.mmcnr' | sudo tee /sys/bus/platform/drivers/mmc-bcm2835/bind
sleep 3
sudo modprobe brcmfmac
sleep 5
ip link show wlan0
```

If `wlan0` appears, restart pwnagotchi:

```
sudo systemctl start pwnagotchi
```

If `wlan0` still does not appear, move to 3c.

### 3c. Full Pi power cycle

Shut down the Pi and unplug power for at least 30 seconds. The BCM43436B0 retains some state across soft reboots; only a true power-off drains it fully.

```
sudo shutdown -h now
# wait for the ACT LED to stop blinking
# unplug USB power for 30+ seconds
# reconnect power
```

If WiFi still does not work after a full power cycle, the SD card or the pre-install firmware state is corrupted. Move to Path 4.

## Path 4: restore the firmware from backup without using the uninstaller

**Symptom:** You need to put the original firmware back but for some reason the uninstaller isn't working (corrupted `state.json`, deleted scripts, etc.).

The installer's SHA-keyed backup file is preserved across uninstalls specifically for this case. Its location is deterministic:

```
ls /var/lib/pwnagotchi-bcm43436b0-fix/backups/
```

You should see one file named `brcmfmac43436-sdio.<sha16>.bin` where `<sha16>` is the first 16 characters of the input firmware's SHA-256. Verify its SHA matches the expected input hash (you can find it in `patches/manifest.json` under `input_sha256`, or in `install.sh` under `MANIFEST_TRUSTED_HASHES["v7:input"]`):

```
sha256sum /var/lib/pwnagotchi-bcm43436b0-fix/backups/brcmfmac43436-sdio.*.bin
```

If that matches `input_sha256`, copy it back to its live location:

```
sudo cp /var/lib/pwnagotchi-bcm43436b0-fix/backups/brcmfmac43436-sdio.<sha16>.bin /lib/firmware/brcm/brcmfmac43436-sdio.bin.new
sudo mv /lib/firmware/brcm/brcmfmac43436-sdio.bin.new /lib/firmware/brcm/brcmfmac43436-sdio.bin
sync /lib/firmware/brcm
sudo modprobe -r brcmfmac
sudo modprobe brcmfmac
```

Then verify the live firmware now has the original hash:

```
sha256sum /lib/firmware/brcm/brcmfmac43436-sdio.bin
```

## Path 5: reflash the SD card

**Last resort** when every other path has failed. Flash a fresh pwnagotchi image from jayofelony's release and start over.

This is not a disaster — it's the documented full-reset path, and it's faster than many of the intermediate paths. You lose your handshakes, your pwnagotchi's learned peer state, and any captures you haven't exfiltrated. Back those up first if you can (`scp pi@<ip>:/home/pi/handshakes ./` or similar).

After reflashing:

1. Boot the fresh image.
2. Wait for first-boot setup to complete.
3. `git clone https://github.com/CoderFX/pwnagotchi-pi-zero-2w-bcm43436b0-firmware-fix.git`
4. `cd pwnagotchi-pi-zero-2w-bcm43436b0-firmware-fix`
5. `sudo ./scripts/install.sh`

## When to open an issue vs. when to just recover

**Just recover:** intermittent `wlan0mon` drop that the watchdog fixed, one-off crashes that the patch recovered from, a failed install that the uninstaller cleaned up, normal operation after the install.

**Open a GitHub issue:** `Firmware has halted` messages on a patched system, crashes the keepalive daemon can't recover, an install that the uninstaller cannot clean up, hash mismatches on a freshly-cloned repo. Include the diagnostics from the "what state are you in?" section above.
