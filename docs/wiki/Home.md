# pwnagotchi-pi-zero-2w-bcm43436b0-firmware-fix wiki

Stability fix for the Raspberry Pi Zero 2 W's BCM43436B0 WiFi chip when used with pwnagotchi / AngryOxide. The README in the repo covers what the fix is, how to install it, and what to expect from `verify.sh`. This wiki is for the questions the README doesn't have room to answer.

## Pages

- **[Troubleshooting](Troubleshooting)** — every error message the installer or verifier can print, what it means, and how to get past it.
- **[Healthy-Install-Output](Healthy-Install-Output)** — sample output of `install.sh`, `verify.sh`, `dmesg`, and `journalctl` on a successfully-installed Pi so you know what to compare against.
- **[FAQ](FAQ)** — common questions about compatibility, what it does and doesn't touch, whether it's safe to revert, how it interacts with pwnagotchi updates, and more.
- **[Recovery](Recovery)** — what to do when the install broke, the Pi doesn't boot, WiFi is dead, or you need to get back to a known-good state.

## Quick links

- Main repository: <https://github.com/CoderFX/pwnagotchi-pi-zero-2w-bcm43436b0-firmware-fix>
- Install guide: [`README.md`](https://github.com/CoderFX/pwnagotchi-pi-zero-2w-bcm43436b0-firmware-fix/blob/master/README.md)
- What the patches do: [`LAYERS.md`](https://github.com/CoderFX/pwnagotchi-pi-zero-2w-bcm43436b0-firmware-fix/blob/master/LAYERS.md)
- Byte-level diff (auditor-facing): [`patches/inplace-v7.txt`](https://github.com/CoderFX/pwnagotchi-pi-zero-2w-bcm43436b0-firmware-fix/blob/master/patches/inplace-v7.txt)
- Trust model and legal disclaimer: [`NOTICE`](https://github.com/CoderFX/pwnagotchi-pi-zero-2w-bcm43436b0-firmware-fix/blob/master/NOTICE)
- Accepted v1 limitations: [`KNOWN_ISSUES.md`](https://github.com/CoderFX/pwnagotchi-pi-zero-2w-bcm43436b0-firmware-fix/blob/master/KNOWN_ISSUES.md)

## Reporting issues

Open a GitHub issue at <https://github.com/CoderFX/pwnagotchi-pi-zero-2w-bcm43436b0-firmware-fix/issues>. Include:

- Output of `cat /proc/device-tree/model`
- Output of `sudo ./scripts/verify.sh` (redact hostnames / SSIDs if you want)
- Relevant lines from `journalctl -u oxigotchi-wlan-keepalive.service`
- Relevant lines from `dmesg | grep -E 'brcmfmac|mmc1'`
- Which pwnagotchi image you're running (jayofelony release tag or commit)
