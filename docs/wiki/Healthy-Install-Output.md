# Healthy install output

What a successful install and a healthy running system look like. Use these samples to compare against what you're seeing.

Output lines are illustrative — exact wording may shift between releases. The shapes and the order matter, not the exact bytes.

## `sudo ./scripts/install.sh` (clean install, patch path)

```
[install] pwnagotchi-pi-zero-2w-bcm43436b0-firmware-fix v0.1.0
[install] running as root: OK
[install] model: Raspberry Pi Zero 2 W: OK
[install] userland arch: aarch64
[install] manifest: 1 entry, all trusted hashes match installer-embedded table
[install] stopping pwnagotchi.service (was running)
[install] stopping bettercap.service (was not running, skipped)
[install] mkdir /var/lib/pwnagotchi-bcm43436b0-fix/backups
[install] stub state.json written (phase=in_progress)
[install] firmware phase: live SHA matches manifest entry "v7" input_sha256
[install] creating SHA-keyed backup at /var/lib/pwnagotchi-bcm43436b0-fix/backups/brcmfmac43436-sdio.d23e313871.bin
[install] applying 29 byte-level patches from patches/inplace-v7.txt
[install] post-patch SHA matches output_sha256: OK
[install] atomic rename: /lib/firmware/brcm/brcmfmac43436-sdio.bin
[install] userspace binary phase: installing wlan_keepalive.aarch64
[install] binary smoke test: OK
[install] userspace scripts: 3 installed
[install] service units: 4 installed
[install] daemon-reload + enable (no --now for boot oneshots)
[install] modprobe -r brcmfmac && modprobe brcmfmac
[install] wlan0 appeared after 3s: OK
[install] wlan0mon: not present (soft warning; pwnagotchi will create it)
[install] starting oxigotchi-wlan-keepalive: OK
[install] restarting pwnagotchi.service
[install] finalizing state.json (phase=complete)

[install] SUMMARY
  firmware:      v7 (sha a196d53d41feff34...)
  binary source: prebuilt-aarch64
  services:      oxigotchi-wlan-keepalive.service     active
                 oxigotchi-wifi-watchdog.service      enabled (next boot)
                 oxigotchi-wifi-recovery.service      enabled (next boot)
                 oxigotchi-fix-ndev.service           enabled (next boot)
  wlan0:         present
  wlan0mon:      not present (will appear when pwnagotchi starts)
  state file:    /var/lib/pwnagotchi-bcm43436b0-fix/state.json

[install] Done. A reboot is recommended so the boot oneshots run in order.
```

**Key things to notice:**

- `all trusted hashes match installer-embedded table` — the manifest wasn't tampered with.
- `live SHA matches manifest entry "v7" input_sha256` — your firmware is a supported input.
- `post-patch SHA matches output_sha256` — the byte patch worked.
- `wlan0 appeared after 3s` — the driver reload succeeded.
- `wlan0mon: not present (soft warning)` — this is fine. Pwnagotchi will create it.

## `sudo ./scripts/verify.sh` (healthy state, after reboot + pwnagotchi running)

```
[verify] /proc/device-tree/model: Raspberry Pi Zero 2 W
[verify] state.json: OK (phase=complete, entry=v7)
[verify] live firmware SHA: a196d53d41feff34... matches state.output_sha256
[verify] /usr/local/bin/oxigotchi-wlan-keepalive: OK (sha 2f79c708...)
[verify] oxigotchi-wlan-keepalive.service: active
[verify] oxigotchi-wifi-watchdog.service:   active
[verify] oxigotchi-wifi-recovery.service:   inactive (dead, exited 0) — normal for a oneshot
[verify] oxigotchi-fix-ndev.service:        inactive (dead, exited 0) — normal for a oneshot
[verify] /sys/class/net/wlan0: present
[verify] keepalive journal check: "listening on wlan0mon (promisc)" — bound to correct interface

--- DIAGNOSTIC ---
iw list (supported interface modes):
        * managed
        * monitor     <-- good

ip link show wlan0
3: wlan0: <BROADCAST,MULTICAST> mtu 1500 ...
ip link show wlan0mon
4: wlan0mon: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 ...

recent dmesg (brcmfmac / mmc1):
[    8.341234] brcmfmac: F1 signature read @0x18000000=0x15294345
[    8.582104] brcmfmac: brcmf_fw_alloc_request: using brcm/brcmfmac43436-sdio ...
[    8.612390] usbcore: registered new interface driver brcmfmac
(no "Firmware has halted", no "SDIO bus", no "card removed")

[verify] EXIT 0 (all hard checks passed)
```

**Key things to notice:**

- `listening on wlan0mon (promisc)` — this line comes from the keepalive daemon itself. If it's missing, the keepalive is in its iface-wait loop and not actually protecting `wlan0mon` yet.
- Boot oneshots showing `inactive (dead, exited 0)` is **normal** after they've run. `verify.sh` accepts that state.
- `supported interface modes: monitor` — if this is missing, the kernel module isn't a monitor-mode-capable brcmfmac and no amount of firmware patching will help.
- No crash strings in dmesg.

## `journalctl -u oxigotchi-wlan-keepalive.service -n 20`

```
systemd[1]: Started oxigotchi-wlan-keepalive.service - WiFi monitor-mode keepalive daemon.
wlan_keepalive[1234]: wlan_keepalive: interface=wlan0mon poll=100ms
wlan_keepalive[1234]: wlan_keepalive: listening on wlan0mon (promisc)
wlan_keepalive[1234]: wlan_keepalive: 1234 frames, probes every 3s
wlan_keepalive[1234]: wlan_keepalive: 5678 frames, probes every 3s
wlan_keepalive[1234]: wlan_keepalive: 12345 frames, probes every 3s
...
```

The `listening on wlan0mon (promisc)` line is what `verify.sh` greps for. The stats lines print roughly every 60 seconds and are just informational.

If you see:

```
wlan_keepalive[1234]: wlan_keepalive: can't open wlan0mon: No such device
wlan_keepalive[1234]: wlan_keepalive: interface=wlan0mon poll=100ms
```

followed by waiting silence — the daemon is in its iface-wait loop. It will bind as soon as `wlan0mon` exists. This is not an error; it's the documented behavior for the "no monitor interface yet" case.

## `dmesg | grep -E 'brcmfmac|mmc1'` on a healthy system

What you **should** see (normal driver init):

```
brcmfmac: brcmf_fw_alloc_request: using brcm/brcmfmac43436-sdio
brcmfmac: F1 signature read
mmc1: new high speed SDIO card at address 0001
```

What you **should not** see after install:

```
brcmfmac: Firmware has halted or crashed
brcmfmac: brcmf_sdio_bus_rxctl: resumed on timeout
mmc1: card removed
brcmfmac: bus is down
```

If you see any of those on a patched system, the crash path the patches were supposed to fix isn't being fully caught. Worth opening an issue.

## After a couple of hours

The firmware patch plus the keepalive daemon plus the watchdog services are supposed to let the radio run indefinitely under heavy load. A healthy system after a few hours of pwnagotchi + AngryOxide looks like:

- `systemctl is-active oxigotchi-wlan-keepalive` → `active`
- `ip link show wlan0mon` → UP, LOWER_UP, BROADCAST, MULTICAST
- `dmesg | grep brcmfmac | tail -5` → no new entries since the initial driver load (no resets, no halts)
- `journalctl -u oxigotchi-wlan-keepalive.service --since "1 hour ago" | wc -l` → ~60 lines (one stats log per minute)

If the `wlan_keepalive` journal has reconnect messages (`wlan_keepalive: wlan0mon error, reconnecting`), the daemon is recovering from interface flaps — probably pwnagotchi cycling `wlan0mon`, which is fine.

If you see `verify.sh` fail after a few hours, check which hard check failed and cross-reference it against [Troubleshooting](Troubleshooting).
