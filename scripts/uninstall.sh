#!/bin/bash
# uninstall.sh — reverse what install.sh did.
#
# Fully idempotent. Every removal is conditional; running twice is a no-op
# the second time, not an error. Only touches files that we recorded in
# state.json; never touches files we did not install.

set -euo pipefail

# ------------------------------------------------------------------
# Hard-coded KNOWN sets — duplicated from install.sh. The state file
# contributes *whether* to delete an item, but never *which path* to
# delete. Any string in state.json that is not in these sets is
# silently dropped from cleanup with a log line.
# ------------------------------------------------------------------
KNOWN_SERVICES=(
    "oxigotchi-wlan-keepalive.service"
    "oxigotchi-wifi-watchdog.service"
    "oxigotchi-wifi-recovery.service"
    "oxigotchi-fix-ndev.service"
)
KNOWN_SCRIPTS=(
    "/usr/local/bin/oxigotchi-wifi-watchdog.sh"
    "/usr/local/bin/oxigotchi-wifi-recovery.sh"
    "/usr/local/bin/oxigotchi-fix-ndev.sh"
)
KNOWN_BINARY="/usr/local/bin/oxigotchi-wlan-keepalive"
KNOWN_FIRMWARE="/lib/firmware/brcm/brcmfmac43436-sdio.bin"

STATE_DIR="/var/lib/pwnagotchi-bcm43436b0-fix"
STATE_FILE="${STATE_DIR}/state.json"
STATE_PREV="${STATE_DIR}/state.json.previous"
BACKUP_DIR="${STATE_DIR}/backups"

log() {
    printf '[uninstall] %s\n' "$*"
}

die() {
    printf '[uninstall] ERROR: %s\n' "$*" >&2
    exit 1
}

sha256_of() {
    sha256sum "$1" | awk '{print $1}'
}

in_set() {
    # usage: in_set "value" "${array[@]}"
    local needle="$1"; shift
    local v
    for v in "$@"; do
        if [ "${v}" = "${needle}" ]; then
            return 0
        fi
    done
    return 1
}

# ------------------------------------------------------------------
# Step 1: must be root
# ------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    die "must run as root (try: sudo ./scripts/uninstall.sh)"
fi

# ------------------------------------------------------------------
# Step 2: read + validate both candidate state files.
#
# Heavy lifting in Python: parse, validate structurally, validate the
# identity tuple and the file lists independently, then pick an
# IDENTITY record using the live-hash-first algorithm from the spec.
# We emit a small shell-sourceable envelope describing what we
# decided and a JSON blob of the effective file lists.
# ------------------------------------------------------------------

if [ ! -f "${STATE_FILE}" ] && [ ! -f "${STATE_PREV}" ]; then
    log "no install state found; nothing to uninstall"
    exit 0
fi

# If the live firmware exists we want to classify against it; otherwise
# we'll pass a sentinel and let the python validator handle it.
LIVE_FW_SHA=""
if [ -f "${KNOWN_FIRMWARE}" ]; then
    LIVE_FW_SHA="$(sha256_of "${KNOWN_FIRMWARE}")"
fi

# Write inputs to a temp file so Python doesn't have to parse argv carefully.
VALIDATE_OUT="$(mktemp)"

python3 - "${STATE_FILE}" "${STATE_PREV}" "${LIVE_FW_SHA}" "${KNOWN_BINARY}" "${KNOWN_FIRMWARE}" > "${VALIDATE_OUT}" <<'PYEOF'
import json, os, re, sys

state_file, state_prev, live_sha, known_binary, known_firmware = sys.argv[1:6]

KNOWN_SERVICES = {
    "oxigotchi-wlan-keepalive.service",
    "oxigotchi-wifi-watchdog.service",
    "oxigotchi-wifi-recovery.service",
    "oxigotchi-fix-ndev.service",
}
KNOWN_SCRIPTS = {
    "/usr/local/bin/oxigotchi-wifi-watchdog.sh",
    "/usr/local/bin/oxigotchi-wifi-recovery.sh",
    "/usr/local/bin/oxigotchi-fix-ndev.sh",
}
BACKUP_DIR = "/var/lib/pwnagotchi-bcm43436b0-fix/backups"

HEX64 = re.compile(r"^[0-9a-f]{64}$")
ENTRY_NAME = re.compile(r"^[A-Za-z0-9_.-]+$")


def warn(msg):
    print(f"# WARN {msg}", file=sys.stderr)


def load(path):
    if not os.path.isfile(path):
        return None
    try:
        with open(path, "r") as f:
            return json.load(f)
    except Exception as e:
        warn(f"ignoring {path}: invalid JSON ({e})")
        return None


def common_valid(label, data, allowed_phases):
    if not isinstance(data, dict):
        warn(f"ignoring {label}: top-level is not an object")
        return False
    if data.get("schema_version") != 1:
        warn(f"ignoring {label}: schema_version != 1")
        return False
    if "phase" not in data:
        warn(f"ignoring {label}: missing 'phase'")
        return False
    if data["phase"] not in allowed_phases:
        warn(f"ignoring {label}: phase '{data['phase']}' not allowed here")
        return False
    return True


def identity_valid(label, data):
    name = data.get("entry_name")
    if not isinstance(name, str) or not name or not ENTRY_NAME.match(name):
        warn(f"{label}: entry_name is not a valid non-empty string")
        return False
    for fld in ("input_sha256", "output_sha256"):
        v = data.get(fld)
        if not isinstance(v, str) or not HEX64.match(v):
            warn(f"{label}: {fld} is not a 64-character lowercase hex string")
            return False
    for fld in ("firmware_written_this_run", "firmware_restorable_on_uninstall"):
        if not isinstance(data.get(fld), bool):
            warn(f"{label}: {fld} is not a boolean")
            return False
    restorable = data["firmware_restorable_on_uninstall"]
    bpath = data.get("backup_path")
    derived = f"{BACKUP_DIR}/brcmfmac43436-sdio.{data['input_sha256'][:16]}.bin"
    if restorable:
        if bpath != derived:
            warn(f"{label}: backup_path does not match derived value (stored={bpath!r}, derived={derived!r})")
            return False
    else:
        if bpath not in (None, ""):
            warn(f"{label}: firmware_restorable_on_uninstall=false but backup_path is set")
            return False
    return True


def file_list_valid(label, data):
    files = data.get("files")
    if not isinstance(files, dict):
        warn(f"{label}: files is not an object")
        return False
    total = 0
    bad = 0
    services = files.get("services", [])
    if not isinstance(services, list):
        warn(f"{label}: files.services is not a list")
        return False
    scripts = files.get("scripts", [])
    if not isinstance(scripts, list):
        warn(f"{label}: files.scripts is not a list")
        return False
    for s in services:
        total += 1
        if not (isinstance(s, str) and s in KNOWN_SERVICES):
            warn(f"{label}: dropping unknown service '{s}'")
            bad += 1
    for s in scripts:
        total += 1
        if not (isinstance(s, str) and s in KNOWN_SCRIPTS):
            warn(f"{label}: dropping unknown script '{s}'")
            bad += 1
    binary = files.get("binary")
    if binary is not None:
        total += 1
        if binary != known_binary:
            warn(f"{label}: dropping unknown binary '{binary}'")
            bad += 1
    firmware = files.get("firmware")
    if firmware is not None:
        total += 1
        if firmware != known_firmware:
            warn(f"{label}: dropping unknown firmware '{firmware}'")
            bad += 1
    if total > 0 and bad * 2 > total:
        warn(f"{label}: more than half of file-list entries failed validation; treating file-list role as failed")
        return False
    return True


def effective_files(*records):
    """Union file lists across validated records, deduplicated, clipped to known sets."""
    services = []
    scripts = []
    binary = None
    firmware = None
    for r in records:
        if r is None:
            continue
        files = r.get("files", {}) or {}
        for s in files.get("services", []) or []:
            if isinstance(s, str) and s in KNOWN_SERVICES and s not in services:
                services.append(s)
        for s in files.get("scripts", []) or []:
            if isinstance(s, str) and s in KNOWN_SCRIPTS and s not in scripts:
                scripts.append(s)
        b = files.get("binary")
        if b is not None and b == known_binary and binary is None:
            binary = b
        f = files.get("firmware")
        if f is not None and f == known_firmware and firmware is None:
            firmware = f
    return {
        "services": services,
        "scripts": scripts,
        "binary": binary,
        "firmware": firmware,
    }


state_data = load(state_file)
prev_data = load(state_prev)

state_struct_ok = state_data is not None and common_valid(
    f"state.json", state_data, {"complete", "in_progress"}
)
prev_struct_ok = prev_data is not None and common_valid(
    f"state.json.previous", prev_data, {"complete"}
)

state_ident_ok = state_struct_ok and identity_valid("state.json", state_data)
prev_ident_ok = prev_struct_ok and identity_valid("state.json.previous", prev_data)

state_files_ok = state_struct_ok and file_list_valid("state.json", state_data)
prev_files_ok = prev_struct_ok and file_list_valid("state.json.previous", prev_data)

# --- Identity selection -------------------------------------------
identity = None
identity_source = None

if state_ident_ok and live_sha:
    if live_sha == state_data["input_sha256"] or live_sha == state_data["output_sha256"]:
        identity = state_data
        identity_source = "state.json"
if identity is None and prev_ident_ok and live_sha:
    if live_sha == prev_data["input_sha256"] or live_sha == prev_data["output_sha256"]:
        identity = prev_data
        identity_source = "state.json.previous"
if identity is None and state_ident_ok:
    identity = state_data
    identity_source = "state.json"
if identity is None and prev_ident_ok:
    identity = prev_data
    identity_source = "state.json.previous"
if identity is None and state_struct_ok:
    identity = state_data
    identity_source = "state.json (non-identity)"
if identity is None and prev_struct_ok:
    identity = prev_data
    identity_source = "state.json.previous (non-identity)"

if identity is None:
    if state_data is None and prev_data is None:
        # already covered by the bash-side pre-check, but reassert here.
        print("NOTHING_TO_DO=1")
        sys.exit(0)
    else:
        warn("all candidate state files failed structural validation")
        print("HARD_ERROR=1")
        sys.exit(0)

# --- File list selection ------------------------------------------
records_for_files = []
if state_files_ok:
    records_for_files.append(state_data)
if prev_files_ok:
    records_for_files.append(prev_data)

effective = effective_files(*records_for_files)

# --- Firmware outcome pre-check -----------------------------------
has_ident = identity_source in ("state.json", "state.json.previous")
entry_name = identity.get("entry_name") if has_ident else None
input_sha = identity.get("input_sha256") if has_ident else None
output_sha = identity.get("output_sha256") if has_ident else None
restorable = bool(identity.get("firmware_restorable_on_uninstall", False))
backup_path = identity.get("backup_path") if has_ident else None
phase = identity.get("phase", "")

if not live_sha:
    outcome = "SKIP_UNKNOWN_IDENTITY"
    reason = "live firmware file not present"
elif not has_ident or not input_sha or not output_sha:
    outcome = "SKIP_UNKNOWN_IDENTITY"
    reason = "no identity fields on any usable record"
elif live_sha == input_sha:
    outcome = "SKIP_UNPATCHED"
    reason = "live firmware is at the recorded input (unpatched) hash"
elif live_sha == output_sha and restorable:
    outcome = "RESTORE"
    reason = "live firmware is at the recorded output hash; backup available"
elif live_sha == output_sha and not restorable:
    outcome = "SKIP_NO_BACKUP"
    reason = "live firmware is at the recorded output hash; no backup recorded"
else:
    outcome = "UNKNOWN"
    reason = f"live firmware sha does not match input or output of the selected record"

def sh_quote(s):
    if s is None:
        return "''"
    return "'" + str(s).replace("'", "'\"'\"'") + "'"

# Emit sourceable envelope + JSON file lists
print(f"EFFECTIVE_PHASE={sh_quote(phase)}")
print(f"EFFECTIVE_ENTRY_NAME={sh_quote(entry_name)}")
print(f"EFFECTIVE_INPUT_SHA={sh_quote(input_sha)}")
print(f"EFFECTIVE_OUTPUT_SHA={sh_quote(output_sha)}")
print(f"EFFECTIVE_BACKUP_PATH={sh_quote(backup_path)}")
print(f"EFFECTIVE_RESTORABLE={'1' if restorable else '0'}")
print(f"EFFECTIVE_IDENTITY_SOURCE={sh_quote(identity_source)}")
print(f"UNINSTALL_FIRMWARE_OUTCOME={sh_quote(outcome)}")
print(f"UNINSTALL_FIRMWARE_REASON={sh_quote(reason)}")
print(f"EFFECTIVE_FILES_JSON={sh_quote(json.dumps(effective))}")
PYEOF

# shellcheck disable=SC1090
source "${VALIDATE_OUT}"
rm -f "${VALIDATE_OUT}"

if [ "${NOTHING_TO_DO:-0}" = "1" ]; then
    log "no install state found; nothing to uninstall"
    exit 0
fi
if [ "${HARD_ERROR:-0}" = "1" ]; then
    die "all candidate state files failed validation; refusing to act. Remove the files manually if you are sure no install is active."
fi

log "identity source: ${EFFECTIVE_IDENTITY_SOURCE}"
log "firmware outcome (pre-check): ${UNINSTALL_FIRMWARE_OUTCOME} (${UNINSTALL_FIRMWARE_REASON})"

# Parse file list JSON into bash arrays via python
EFFECTIVE_SERVICES=()
EFFECTIVE_SCRIPTS=()
EFFECTIVE_BINARY=""
EFFECTIVE_FIRMWARE=""
while IFS= read -r line; do
    EFFECTIVE_SERVICES+=("${line}")
done < <(python3 -c "import json,sys; d=json.loads(sys.argv[1]); [print(s) for s in d.get('services') or []]" "${EFFECTIVE_FILES_JSON}")
while IFS= read -r line; do
    EFFECTIVE_SCRIPTS+=("${line}")
done < <(python3 -c "import json,sys; d=json.loads(sys.argv[1]); [print(s) for s in d.get('scripts') or []]" "${EFFECTIVE_FILES_JSON}")
EFFECTIVE_BINARY="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('binary') or '')" "${EFFECTIVE_FILES_JSON}")"
EFFECTIVE_FIRMWARE="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('firmware') or '')" "${EFFECTIVE_FILES_JSON}")"

# --- Step 2b: refuse the uninstall entirely if UNKNOWN ------------
case "${UNINSTALL_FIRMWARE_OUTCOME}" in
    UNKNOWN)
        cat >&2 <<EOF
[uninstall] ERROR: live firmware on ${KNOWN_FIRMWARE} has unexpected
SHA-256 (${LIVE_FW_SHA}); does not match the recorded input or output
hash for this install (${EFFECTIVE_INPUT_SHA} / ${EFFECTIVE_OUTPUT_SHA}).

Some other tool has modified the firmware. Refusing to uninstall to avoid
leaving the system in a worse state.

Investigate manually, then either
  (a) restore the firmware to a recognized state and re-run uninstall, or
  (b) rm -rf /var/lib/pwnagotchi-bcm43436b0-fix
      to forget the install record without touching the firmware.
EOF
        exit 1
        ;;
esac

# ------------------------------------------------------------------
# Step 3: service teardown
# ------------------------------------------------------------------
for unit in "${EFFECTIVE_SERVICES[@]}"; do
    if ! in_set "${unit}" "${KNOWN_SERVICES[@]}"; then
        log "refusing to act on unrecognized unit name '${unit}' from state file"
        continue
    fi
    if systemctl is-active --quiet "${unit}" 2>/dev/null; then
        systemctl stop "${unit}" 2>/dev/null || true
        log "stopped ${unit}"
    fi
    if systemctl is-enabled --quiet "${unit}" 2>/dev/null; then
        systemctl disable "${unit}" 2>/dev/null || true
        log "disabled ${unit}"
    fi
    systemctl reset-failed "${unit}" 2>/dev/null || true
    rm -f "/etc/systemd/system/${unit}"
done
systemctl daemon-reload 2>/dev/null || true

# ------------------------------------------------------------------
# Step 4: userspace cleanup
# ------------------------------------------------------------------
# 4a: scripts
for sp in "${EFFECTIVE_SCRIPTS[@]}"; do
    if ! in_set "${sp}" "${KNOWN_SCRIPTS[@]}"; then
        log "refusing to act on unrecognized script path '${sp}' from state file"
        continue
    fi
    rm -f "${sp}"
    log "removed ${sp}"
done

# 4b: binary
if [ -n "${EFFECTIVE_BINARY}" ]; then
    if [ "${EFFECTIVE_BINARY}" != "${KNOWN_BINARY}" ]; then
        log "refusing to act on unrecognized binary path '${EFFECTIVE_BINARY}' from state file"
    else
        rm -f "${EFFECTIVE_BINARY}"
        log "removed ${EFFECTIVE_BINARY}"
    fi
fi

# 4c/d/e/f: hardcoded stale-temp sweep
rm -f "${KNOWN_BINARY}.new" 2>/dev/null || true
rm -f "${KNOWN_FIRMWARE}.new" 2>/dev/null || true
rm -f "${STATE_PREV}.new" 2>/dev/null || true
if [ -d "${BACKUP_DIR}" ]; then
    rm -f "${BACKUP_DIR}"/*.new 2>/dev/null || true
fi

# ------------------------------------------------------------------
# Step 5: firmware restore (using UNINSTALL_FIRMWARE_OUTCOME from 2b)
# ------------------------------------------------------------------
DID_RESTORE=0
case "${UNINSTALL_FIRMWARE_OUTCOME}" in
    SKIP_UNPATCHED)
        log "firmware NOT restored: already at unpatched state"
        ;;
    SKIP_NO_BACKUP)
        log "firmware NOT restored: install was an adoption-on-already-patched run with no available backup; firmware left in the patched state"
        ;;
    SKIP_UNKNOWN_IDENTITY)
        log "firmware NOT restored: install was interrupted before identity fields were recorded and no previous-install snapshot was available; firmware left at current state"
        ;;
    RESTORE)
        [ -n "${EFFECTIVE_INPUT_SHA}" ] || die "RESTORE decided but input_sha is missing from effective state"
        [ -n "${EFFECTIVE_BACKUP_PATH}" ] || die "RESTORE decided but backup_path is missing from effective state"

        # filesystem hardening on the backup source
        DERIVED_BACKUP="${BACKUP_DIR}/brcmfmac43436-sdio.${EFFECTIVE_INPUT_SHA:0:16}.bin"
        if [ "${EFFECTIVE_BACKUP_PATH}" != "${DERIVED_BACKUP}" ]; then
            die "backup_path '${EFFECTIVE_BACKUP_PATH}' does not match derived value '${DERIVED_BACKUP}'"
        fi
        if [ ! -e "${EFFECTIVE_BACKUP_PATH}" ]; then
            die "backup file does not exist: ${EFFECTIVE_BACKUP_PATH}"
        fi
        if [ -L "${EFFECTIVE_BACKUP_PATH}" ]; then
            die "backup file is a symlink: ${EFFECTIVE_BACKUP_PATH}"
        fi
        if [ ! -f "${EFFECTIVE_BACKUP_PATH}" ]; then
            die "backup file is not a regular file: ${EFFECTIVE_BACKUP_PATH}"
        fi
        REAL_BACKUP="$(readlink -f "${EFFECTIVE_BACKUP_PATH}")"
        if [ "${REAL_BACKUP}" != "${EFFECTIVE_BACKUP_PATH}" ]; then
            die "backup file realpath mismatch: ${REAL_BACKUP} != ${EFFECTIVE_BACKUP_PATH}"
        fi
        REAL_PARENT="$(dirname "${EFFECTIVE_BACKUP_PATH}")"
        if [ "${REAL_PARENT}" != "${BACKUP_DIR}" ]; then
            die "backup file parent dir is not ${BACKUP_DIR}: ${REAL_PARENT}"
        fi
        BACKUP_SIZE="$(stat -c '%s' "${EFFECTIVE_BACKUP_PATH}")"
        if [ "${BACKUP_SIZE}" != "414696" ]; then
            die "backup file size ${BACKUP_SIZE} != 414696"
        fi
        BACKUP_SHA="$(sha256_of "${EFFECTIVE_BACKUP_PATH}")"
        if [ "${BACKUP_SHA}" != "${EFFECTIVE_INPUT_SHA}" ]; then
            die "backup file corrupted: sha ${BACKUP_SHA} != recorded input ${EFFECTIVE_INPUT_SHA}; refusing to restore unknown firmware"
        fi

        log "restoring firmware from ${EFFECTIVE_BACKUP_PATH}"
        cp "${EFFECTIVE_BACKUP_PATH}" "${KNOWN_FIRMWARE}.new"
        mv "${KNOWN_FIRMWARE}.new" "${KNOWN_FIRMWARE}"
        sync -f "${KNOWN_FIRMWARE}"
        sync "$(dirname "${KNOWN_FIRMWARE}")"
        modprobe -r brcmfmac 2>/dev/null || true
        sleep 1
        modprobe brcmfmac 2>/dev/null || true
        for i in $(seq 1 15); do
            if [ -e /sys/class/net/wlan0 ]; then
                break
            fi
            sleep 1
        done
        DID_RESTORE=1
        log "firmware restored"
        ;;
    *)
        die "internal error: unknown UNINSTALL_FIRMWARE_OUTCOME=${UNINSTALL_FIRMWARE_OUTCOME}"
        ;;
esac

# ------------------------------------------------------------------
# Step 6: state cleanup
# ------------------------------------------------------------------
rm -f "${STATE_FILE}" || true
rm -f "${STATE_PREV}" || true
rmdir --ignore-fail-on-non-empty "${BACKUP_DIR}" 2>/dev/null || true
rmdir --ignore-fail-on-non-empty "${STATE_DIR}" 2>/dev/null || true

# ------------------------------------------------------------------
# Step 7: completion message
# ------------------------------------------------------------------
case "${EFFECTIVE_PHASE}" in
    in_progress)
        log "cleaned up after failed install"
        ;;
    complete)
        if [ "${DID_RESTORE}" -eq 1 ]; then
            log "uninstalled, reboot recommended"
        else
            cat <<EOF
[uninstall] userspace cleaned up; no firmware backup exists for this install
(probably an adoption install on already-patched firmware), so the firmware
is left in the patched state. To revert the firmware itself, restore from
your own backup or reflash the SD card.
EOF
        fi
        ;;
    *)
        log "uninstall complete"
        ;;
esac

exit 0
