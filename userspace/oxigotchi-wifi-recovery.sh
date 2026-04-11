#!/bin/bash
# WiFi SDIO Recovery Script for Pi Zero 2W (BCM43436B0)
#
# Runs at boot BEFORE bettercap/pwnagotchi. If wlan0 doesn't appear
# within 15 seconds, performs GPIO power cycle of the WiFi chip via
# WL_REG_ON (GPIO 41) to recover from SDIO bus death (error -22).
#
# This is the ONLY recovery for SDIO bus death — modprobe cycling
# cannot fix it, only physical power removal of the WiFi chip works.

LOG=/var/log/wifi-recovery.log

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG"
}

log "wifi-recovery: starting, waiting for wlan0..."

# Wait up to 15 seconds for wlan0 to appear naturally
for i in $(seq 1 15); do
    if [ -e /sys/class/net/wlan0 ]; then
        log "wifi-recovery: wlan0 appeared after ${i}s — no recovery needed"
        exit 0
    fi
    sleep 1
done

log "wifi-recovery: wlan0 not found after 15s — attempting GPIO recovery"

# Check if this is SDIO bus death
if dmesg | grep -qiE 'mmc1.*error|sdio.*error|card removed'; then
    log "wifi-recovery: SDIO bus death confirmed in dmesg"
fi

# Attempt 1: Simple modprobe cycle (works for soft crashes)
log "wifi-recovery: attempt 1 — modprobe cycle"
modprobe -r brcmfmac 2>/dev/null
sleep 2
modprobe brcmfmac 2>/dev/null
sleep 5

if [ -e /sys/class/net/wlan0 ]; then
    log "wifi-recovery: wlan0 recovered via modprobe cycle"
    exit 0
fi

# Attempt 2: GPIO power cycle (WL_REG_ON on GPIO 41)
log "wifi-recovery: attempt 2 — GPIO power cycle (WL_REG_ON)"

# Unload driver
modprobe -r brcmfmac 2>/dev/null
sleep 1

# Unbind MMC controller
echo '3f300000.mmcnr' > /sys/bus/platform/drivers/mmc-bcm2835/unbind 2>/dev/null
sleep 1

# Pull WL_REG_ON low (power off WiFi chip)
pinctrl set 41 op dl 2>/dev/null
log "wifi-recovery: WL_REG_ON LOW (WiFi chip powered off)"
sleep 3

# Push WL_REG_ON high (power on WiFi chip)
pinctrl set 41 op dh 2>/dev/null
log "wifi-recovery: WL_REG_ON HIGH (WiFi chip powered on)"
sleep 2

# Rebind MMC controller
echo '3f300000.mmcnr' > /sys/bus/platform/drivers/mmc-bcm2835/bind 2>/dev/null
sleep 3

# Reload driver
modprobe brcmfmac 2>/dev/null
sleep 5

if [ -e /sys/class/net/wlan0 ]; then
    log "wifi-recovery: wlan0 recovered via GPIO power cycle!"
    exit 0
fi

# Attempt 3: Retry GPIO with longer delays
log "wifi-recovery: attempt 3 — GPIO power cycle with extended timing"
modprobe -r brcmfmac 2>/dev/null
sleep 1
echo '3f300000.mmcnr' > /sys/bus/platform/drivers/mmc-bcm2835/unbind 2>/dev/null
pinctrl set 41 op dl 2>/dev/null
sleep 5
pinctrl set 41 op dh 2>/dev/null
sleep 3
echo '3f300000.mmcnr' > /sys/bus/platform/drivers/mmc-bcm2835/bind 2>/dev/null
sleep 5
modprobe brcmfmac 2>/dev/null
sleep 5

if [ -e /sys/class/net/wlan0 ]; then
    log "wifi-recovery: wlan0 recovered via extended GPIO cycle!"
    exit 0
fi

log "wifi-recovery: ALL ATTEMPTS FAILED — WiFi chip may need full power drain"
exit 1
