#!/bin/bash
# verify.sh — standalone post-install sanity.
#
# Reads state.json for the source-of-truth hashes, verifies that what is
# actually on disk and running matches what we recorded at install time.
#
# Exit codes:
#   0 - all hard checks passed
#   1 - a hard check failed
#   2 - state.json missing — system is not installed or has been uninstalled

set -euo pipefail

KNOWN_FIRMWARE="/lib/firmware/brcm/brcmfmac43436-sdio.bin"
KNOWN_BINARY="/usr/local/bin/oxigotchi-wlan-keepalive"
STATE_FILE="/var/lib/pwnagotchi-bcm43436b0-fix/state.json"

PASS=0
FAIL=0
EXIT_CODE=0

pass() {
    printf '[verify] PASS  %s\n' "$*"
    PASS=$((PASS + 1))
}

fail() {
    printf '[verify] FAIL  %s\n' "$*" >&2
    FAIL=$((FAIL + 1))
    EXIT_CODE=1
}

warn() {
    printf '[verify] WARN  %s\n' "$*"
}

info() {
    printf '[verify] INFO  %s\n' "$*"
}

sha256_of() {
    sha256sum "$1" | awk '{print $1}'
}

# ------------------------------------------------------------------
# HARD CHECK 1: Raspberry Pi Zero 2 W
# ------------------------------------------------------------------
MODEL=""
if [ -r /proc/device-tree/model ]; then
    MODEL="$(tr -d '\0' < /proc/device-tree/model)"
fi
case "${MODEL}" in
    *"Raspberry Pi Zero 2 W"*)
        pass "hardware model: ${MODEL}"
        ;;
    *)
        fail "hardware model '${MODEL}' is not Raspberry Pi Zero 2 W"
        ;;
esac

# ------------------------------------------------------------------
# HARD CHECK 2: state.json exists and parses
# ------------------------------------------------------------------
if [ ! -f "${STATE_FILE}" ]; then
    printf '[verify] INFO  state.json missing: %s\n' "${STATE_FILE}"
    printf '[verify] system is not installed (or has been uninstalled)\n'
    exit 2
fi
if ! python3 -c "import json; json.load(open('${STATE_FILE}'))" 2>/dev/null; then
    fail "state.json at ${STATE_FILE} is not valid JSON"
    exit 1
fi
pass "state.json exists and parses"

# Slurp relevant fields
OUTPUT_SHA="$(python3 -c "import json; print(json.load(open('${STATE_FILE}'))['output_sha256'])" 2>/dev/null || echo "")"
BINARY_SHA="$(python3 -c "import json; print(json.load(open('${STATE_FILE}'))['binary_sha256'])" 2>/dev/null || echo "")"
ENTRY_NAME="$(python3 -c "import json; print(json.load(open('${STATE_FILE}')).get('entry_name') or '')" 2>/dev/null || echo "")"

SERVICES_JSON="$(python3 -c "
import json
data = json.load(open('${STATE_FILE}'))
services = (data.get('files') or {}).get('services') or []
print(' '.join(services))
" 2>/dev/null || echo "")"

# ------------------------------------------------------------------
# HARD CHECK 3: live firmware sha256 == state.output_sha256
# ------------------------------------------------------------------
if [ -z "${OUTPUT_SHA}" ]; then
    fail "state.output_sha256 is empty"
elif [ ! -f "${KNOWN_FIRMWARE}" ]; then
    fail "firmware file missing: ${KNOWN_FIRMWARE}"
else
    LIVE_FW_SHA="$(sha256_of "${KNOWN_FIRMWARE}")"
    if [ "${LIVE_FW_SHA}" = "${OUTPUT_SHA}" ]; then
        pass "firmware sha256 matches state.output_sha256"
    else
        fail "firmware sha256 mismatch: live=${LIVE_FW_SHA} expected=${OUTPUT_SHA}"
    fi
fi

# ------------------------------------------------------------------
# HARD CHECK 4: binary sha256 == state.binary_sha256
# ------------------------------------------------------------------
if [ -z "${BINARY_SHA}" ]; then
    fail "state.binary_sha256 is empty"
elif [ ! -f "${KNOWN_BINARY}" ]; then
    fail "binary file missing: ${KNOWN_BINARY}"
else
    LIVE_BIN_SHA="$(sha256_of "${KNOWN_BINARY}")"
    if [ "${LIVE_BIN_SHA}" = "${BINARY_SHA}" ]; then
        pass "binary sha256 matches state.binary_sha256"
    else
        fail "binary sha256 mismatch: live=${LIVE_BIN_SHA} expected=${BINARY_SHA}"
    fi
fi

# ------------------------------------------------------------------
# HARD CHECK 5: each unit in state.files.services
# ------------------------------------------------------------------
# Only the keepalive is started imperatively by install.sh. Everything else
# (the long-running watchdog AND the two boot oneshots) is only enabled at
# install time and doesn't run until next boot. verify.sh therefore only
# hard-requires is-active for the keepalive. The watchdog and boot oneshots
# are accepted in either "active" or "inactive" state.
LONG_RUNNING="oxigotchi-wlan-keepalive.service"
for unit in ${SERVICES_JSON}; do
    unit_path="/etc/systemd/system/${unit}"
    if [ ! -f "${unit_path}" ]; then
        fail "unit file missing: ${unit_path}"
        continue
    fi
    if systemctl is-enabled --quiet "${unit}" 2>/dev/null; then
        :
    else
        fail "unit not enabled: ${unit}"
        continue
    fi
    # Long-running services must be active; boot oneshots can be "inactive" after running
    if printf '%s\n' ${LONG_RUNNING} | grep -qx "${unit}"; then
        if systemctl is-active --quiet "${unit}" 2>/dev/null; then
            pass "unit running: ${unit}"
        else
            fail "unit not running: ${unit}"
        fi
    else
        state="$(systemctl is-active "${unit}" 2>/dev/null || echo unknown)"
        case "${state}" in
            active|inactive)
                pass "unit OK (${state}): ${unit}"
                ;;
            *)
                fail "unit in unexpected state '${state}': ${unit}"
                ;;
        esac
    fi
done

# ------------------------------------------------------------------
# HARD CHECK 6: wlan0 exists
# ------------------------------------------------------------------
if [ -e /sys/class/net/wlan0 ]; then
    pass "wlan0 interface present"
else
    fail "wlan0 interface missing"
fi

# ------------------------------------------------------------------
# HARD CHECK 7: keepalive is bound to the right interface
# ------------------------------------------------------------------
SVC_START="$(systemctl show -p ActiveEnterTimestamp --value oxigotchi-wlan-keepalive.service 2>/dev/null || echo "")"
if [ -z "${SVC_START}" ]; then
    warn "could not read oxigotchi-wlan-keepalive ActiveEnterTimestamp; skipping bind check"
else
    LAST_BIND="$(journalctl -u oxigotchi-wlan-keepalive.service -o cat --since "${SVC_START}" 2>/dev/null \
        | grep -E '^wlan_keepalive: listening on [^ ]+ \(promisc\)$' \
        | tail -1 || true)"
    BOUND_IFACE=""
    if [ -n "${LAST_BIND}" ]; then
        BOUND_IFACE="$(printf '%s\n' "${LAST_BIND}" | awk '{print $4}')"
    fi
    if [ "${BOUND_IFACE}" = "wlan0mon" ]; then
        pass "keepalive is bound to wlan0mon"
    elif [ -z "${BOUND_IFACE}" ] && [ ! -e /sys/class/net/wlan0mon ]; then
        warn "no bind yet; daemon is in its iface-wait loop until wlan0mon appears"
    elif [ -z "${BOUND_IFACE}" ] && [ -e /sys/class/net/wlan0mon ]; then
        fail "wlan0mon exists but daemon has not bound; check service health"
    else
        fail "daemon bound to wrong interface (${BOUND_IFACE}); keepalive is not protecting wlan0mon"
    fi
fi

# ------------------------------------------------------------------
# DIAGNOSTIC OUTPUT (always printed; never affects exit code)
# ------------------------------------------------------------------
printf '\n----- diagnostics (informational only) -----\n'

if command -v iw >/dev/null 2>&1; then
    printf '\n[iw list supported modes]\n'
    iw list 2>/dev/null | grep -A8 "Supported interface modes" || true
fi

printf '\n[ip link show wlan0 / wlan0mon]\n'
ip link show wlan0 2>/dev/null || true
ip link show wlan0mon 2>/dev/null || true

printf '\n[recent brcmfmac / mmc1 dmesg]\n'
dmesg 2>/dev/null | grep -E 'brcmfmac|mmc1' | tail -20 || true

printf '\n[systemctl status summary]\n'
for unit in ${SERVICES_JSON}; do
    status="$(systemctl is-active "${unit}" 2>/dev/null || echo unknown)"
    enabled="$(systemctl is-enabled "${unit}" 2>/dev/null || echo unknown)"
    printf '  %-36s %s / %s\n' "${unit}" "${enabled}" "${status}"
done

printf '\n[state.json]\n'
python3 -m json.tool "${STATE_FILE}" 2>/dev/null || cat "${STATE_FILE}" 2>/dev/null || true

printf '\n----- summary -----\n'
printf '  passed : %d\n' "${PASS}"
printf '  failed : %d\n' "${FAIL}"

exit "${EXIT_CODE}"
