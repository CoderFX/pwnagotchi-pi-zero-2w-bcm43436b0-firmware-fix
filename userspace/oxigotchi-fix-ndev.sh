#!/bin/bash
# fix_ndev_on_boot.sh — Runtime workaround for nexmon ndev_global dangling pointer bug.
# Only runs within first 120s of uptime. Waits for wlan0, checks dmesg for
# SDIO bus crash signatures. If wlan0 missing or bus crashed: modprobe cycle.

IFACE=wlan0
UPTIME=$(awk '{print int($1)}' /proc/uptime)

# Only run during early boot
[ "$UPTIME" -gt 120 ] && exit 0

# Wait up to 15s for wlan0 to appear
for i in $(seq 1 15); do
    ip link show $IFACE >/dev/null 2>&1 && break
    sleep 1
done

# If wlan0 exists and no bus crash in dmesg, all good
if ip link show $IFACE >/dev/null 2>&1; then
    if ! dmesg | tail -200 | grep -qE "bus is down|SDIO.*error"; then
        exit 0
    fi
fi

# Recovery: modprobe cycle
logger -t fix-ndev "wlan0 missing or SDIO bus crash detected, performing modprobe cycle"
rmmod brcmfmac 2>/dev/null
sleep 5
modprobe brcmfmac

# Wait for interface to reappear
for i in $(seq 1 15); do
    ip link show $IFACE >/dev/null 2>&1 && exit 0
    sleep 2
done

logger -t fix-ndev "wlan0 did not reappear after modprobe cycle"
exit 1
