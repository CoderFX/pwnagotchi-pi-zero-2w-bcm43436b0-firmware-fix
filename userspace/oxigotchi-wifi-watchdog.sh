#!/bin/bash
# WiFi Watchdog — continuous monitor for SDIO bus death
# Runs independently of pwnagotchi. If wlan0 disappears,
# performs GPIO power cycle to recover WiFi chip.
#
# This is the MISSING piece — boot recovery exists but
# runtime recovery did not. Now it does.

LOG=/var/log/wifi-watchdog.log
CHECK_INTERVAL=10
RECOVERY_COOLDOWN=60
last_recovery=0

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [wifi-watchdog] $1" | tee -a "$LOG"
}

gpio_recovery() {
    local now=$(date +%s)
    local elapsed=$((now - last_recovery))
    if [ "$elapsed" -lt "$RECOVERY_COOLDOWN" ]; then
        log "cooldown active (${elapsed}s/${RECOVERY_COOLDOWN}s), skipping"
        return 1
    fi
    last_recovery=$now

    log "=== GPIO POWER CYCLE START ==="

    # Stop services that use WiFi
    systemctl stop pwnagotchi 2>/dev/null
    systemctl stop bettercap 2>/dev/null
    systemctl stop oxigotchi-wlan-keepalive 2>/dev/null

    # Unload driver
    modprobe -r brcmfmac 2>/dev/null
    sleep 1

    # Unbind MMC controller
    echo '3f300000.mmcnr' > /sys/bus/platform/drivers/mmc-bcm2835/unbind 2>/dev/null
    sleep 1

    # Pull WL_REG_ON low (power off WiFi chip)
    pinctrl set 41 op dl 2>/dev/null
    log "WL_REG_ON LOW — WiFi chip powered off"
    sleep 3

    # Push WL_REG_ON high (power on WiFi chip)
    pinctrl set 41 op dh 2>/dev/null
    log "WL_REG_ON HIGH — WiFi chip powered on"
    sleep 2

    # Rebind MMC controller
    echo '3f300000.mmcnr' > /sys/bus/platform/drivers/mmc-bcm2835/bind 2>/dev/null
    sleep 3

    # Reload driver
    modprobe brcmfmac 2>/dev/null
    sleep 5

    # Check if wlan0 came back
    if [ -e /sys/class/net/wlan0 ]; then
        log "=== RECOVERY SUCCESS — wlan0 is back ==="
        # Restart services
        systemctl start oxigotchi-wlan-keepalive 2>/dev/null
        systemctl start bettercap 2>/dev/null
        sleep 3
        systemctl reset-failed pwnagotchi 2>/dev/null
        systemctl start pwnagotchi 2>/dev/null
        log "services restarted"
        return 0
    else
        log "=== RECOVERY FAILED — wlan0 did not return ==="
        # Last resort: full reboot
        log "initiating reboot"
        reboot
        return 1
    fi
}

log "started — monitoring wlan0 every ${CHECK_INTERVAL}s"

while true; do
    sleep "$CHECK_INTERVAL"

    if [ ! -e /sys/class/net/wlan0 ]; then
        log "wlan0 MISSING — WiFi chip has crashed!"

        # Double-check after 3 seconds (avoid false positives during driver reload)
        sleep 3
        if [ ! -e /sys/class/net/wlan0 ]; then
            log "confirmed: wlan0 still missing after 3s — starting recovery"
            gpio_recovery
        else
            log "false alarm — wlan0 came back"
        fi

    # Also check: wlan0 exists but monitor mode fails (firmware half-dead)
    elif [ ! -e /sys/class/net/wlan0mon ]; then
        log "wlan0mon MISSING but wlan0 exists — firmware may be stuck"
        sleep 10
        if [ ! -e /sys/class/net/wlan0mon ]; then
            log "wlan0mon still missing after 10s — GPIO recovery needed"
            gpio_recovery
        fi
    fi
done
