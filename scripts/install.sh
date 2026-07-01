#!/bin/bash
# install.sh — pwnagotchi-pi-zero-2w-bcm43436b0-firmware-fix installer
#
# Applies the BCM43436B0 stability patch to the on-disk brcmfmac43436-sdio.bin
# firmware, installs the userspace keepalive daemon, installs the recovery
# and watchdog scripts, and installs four systemd units.
#
# Usage: sudo ./scripts/install.sh
#
# See README.md for the trust model and the full design doc for the
# step-by-step rationale behind every phase of this installer.

set -euo pipefail

# ------------------------------------------------------------------
# Trusted-hash table — every hash referenced by every manifest entry.
# The installer validates manifest.json against this table before
# reading any hash out of it, so a single-file edit to manifest.json
# is caught. See NOTICE for the full threat model.
# ------------------------------------------------------------------
declare -A MANIFEST_TRUSTED_HASHES
MANIFEST_TRUSTED_HASHES["v7:input"]="d23e3138716fffd3f4e1de861525d653ee7f52581db7dae3737277ae7298ba64"
MANIFEST_TRUSTED_HASHES["v7:output"]="a196d53d41feff34d874f67fdb4be681785ce1b71a7d5f72e572ca013cf87eb4"
MANIFEST_TRUSTED_HASHES["v7:patch_file"]="4990f92fd00282e92bb6931ce3a3e4c017698e955070b01716d89566c4b10721"
MANIFEST_TRUSTED_HASHES["v7:userspace_aarch64"]="2f79c708db3b49ded97f3e3ac11734c321ec31512e643e152eb119f2a81b148f"
MANIFEST_TRUSTED_HASHES["v7:userspace_armhf"]="55b2c5559bacf689f9de36033d9faa53c9153bad981ab948f890ddb89f6b98f0"

# ------------------------------------------------------------------
# Hard-coded KNOWN sets — duplicated from uninstall.sh for defense in
# depth. Every glob and every iteration of userspace/services also
# validates against these sets so that a malicious drop-in file in
# the repo cannot be installed.
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

# Board-specific symlink that the brcmfmac driver follows on Pi Zero 2W
# when the chip reports as BCM43430/1 (not BCM43430B0).
BOARD_SYMLINK="/lib/firmware/brcm/brcmfmac43430-sdio.raspberrypi,model-zero-2-w.bin"
BOARD_SYMLINK_EXPECTED_TARGET="brcmfmac43436-sdio.bin"

# Repo paths. Computed from the script's own location so the installer
# is safe to invoke from any working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PATCH_DIR="${REPO_DIR}/patches"
USERSPACE_DIR="${REPO_DIR}/userspace"
SERVICES_DIR="${REPO_DIR}/services"

# State directory on the live system.
STATE_DIR="/var/lib/pwnagotchi-bcm43436b0-fix"
STATE_FILE="${STATE_DIR}/state.json"
STATE_PREV="${STATE_DIR}/state.json.previous"
BACKUP_DIR="${STATE_DIR}/backups"

# Tracks which services we stopped in step 5, so we can restart them
# at the end (or on failure).
PWNAGOTCHI_WAS_RUNNING=0
BETTERCAP_WAS_RUNNING=0
STOPPED_OXIGOTCHI_UNITS=()

# Populated as we make decisions.
TARGET_ARCH=""              # "aarch64" | "armhf"
SELECTED_ENTRY=""           # "v7" ...
SELECTED_INPUT_SHA=""
SELECTED_OUTPUT_SHA=""
SELECTED_PATCH_FILE=""
SELECTED_PATCH_SHA=""
SELECTED_USERSPACE_SHA=""
SELECTED_USERSPACE_PATH=""  # repo-relative path to the chosen binary
FIRMWARE_PATH=""            # "patch" | "already-patched"
BACKUP_PATH=""              # /var/lib/.../backups/brcmfmac43436-sdio.<sha16>.bin
BINARY_SOURCE=""            # "prebuilt-aarch64" | "prebuilt-armhf" | "compiled-from-source"
INSTALLED_BINARY_SHA=""

log() {
    printf '[install] %s\n' "$*"
}

die() {
    # Routes through abort_with_rollback so controlled failure paths that
    # happen AFTER the firmware point-of-no-return still trigger the
    # firmware rollback (spec: fail-and-rollback on steps 7-10 when
    # firmware_written_this_run is true). Calling `exit` directly here
    # would skip the `trap ERR` handler and bypass rollback.
    printf '[install] ERROR: %s\n' "$*" >&2
    # If abort_with_rollback hasn't been defined yet (early steps), do a
    # plain exit. It is defined well before any step that could touch
    # firmware, so this is only reached by the initial "must be root" /
    # "must be Pi Zero 2 W" / toolchain checks, where there is nothing
    # to roll back.
    if declare -F abort_with_rollback >/dev/null 2>&1; then
        abort_with_rollback "$*"
    fi
    exit 1
}

sha256_of() {
    # Portable sha256: prefer sha256sum (common on Pi).
    sha256sum "$1" | awk '{print $1}'
}

json_get() {
    # Usage: json_get <file> <python-expression-over-data>
    python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
print($2)
" "$1"
}

json_patch_count() {
    python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
print(len(data['patches']))
" "$1"
}

json_get_patch_field() {
    # Usage: json_get_patch_field <file> <index> <field>
    python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
p = data['patches'][int(sys.argv[2])]
field = sys.argv[3]
if '.' in field:
    a, b = field.split('.', 1)
    print(p[a][b])
else:
    print(p[field])
" "$1" "$2" "$3"
}

sync_file() {
    # Flush the filesystem containing this file to stable storage (syncfs).
    # This is at least as strong as fsync(2) on a single file.
    sync -f "$1"
}

sync_dir() {
    # Flush directory metadata to stable storage (sync on a directory path).
    sync "$1"
}

# --- rollback helpers ----------------------------------------------

rollback_firmware() {
    # Only called when state.firmware_written_this_run is true.
    # Reads state.backup_path for the source and atomically restores it.
    # Fails loudly (returns non-zero, leaves the state file in place) on
    # any backup safety-check failure, rather than silently restoring the
    # wrong firmware. This parallels the hardening in uninstall.sh step 5.
    local backup expected_sha
    backup="$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('backup_path') or '')
except Exception:
    print('')
" "${STATE_FILE}" 2>/dev/null || true)"
    expected_sha="$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('input_sha256') or '')
except Exception:
    print('')
" "${STATE_FILE}" 2>/dev/null || true)"

    if [ -z "${backup}" ]; then
        log "rollback FAILED: state.backup_path is empty; cannot roll back firmware"
        return 1
    fi
    if [ -z "${expected_sha}" ]; then
        log "rollback FAILED: state.input_sha256 is empty; cannot verify backup"
        return 1
    fi
    if [ ! -e "${backup}" ]; then
        log "rollback FAILED: backup file does not exist: ${backup}"
        return 1
    fi
    if [ -L "${backup}" ]; then
        log "rollback FAILED: backup file is a symlink: ${backup}"
        return 1
    fi
    if [ ! -f "${backup}" ]; then
        log "rollback FAILED: backup file is not a regular file: ${backup}"
        return 1
    fi
    local derived_backup real_backup real_parent backup_size backup_sha
    derived_backup="${BACKUP_DIR}/brcmfmac43436-sdio.${expected_sha:0:16}.bin"
    if [ "${backup}" != "${derived_backup}" ]; then
        log "rollback FAILED: backup_path '${backup}' does not match derived value '${derived_backup}'"
        return 1
    fi
    real_backup="$(readlink -f "${backup}" 2>/dev/null || echo "")"
    if [ "${real_backup}" != "${backup}" ]; then
        log "rollback FAILED: backup realpath mismatch: '${real_backup}' != '${backup}'"
        return 1
    fi
    real_parent="$(dirname "${backup}")"
    if [ "${real_parent}" != "${BACKUP_DIR}" ]; then
        log "rollback FAILED: backup parent dir '${real_parent}' is not '${BACKUP_DIR}'"
        return 1
    fi
    backup_size="$(stat -c '%s' "${backup}" 2>/dev/null || echo 0)"
    if [ "${backup_size}" != "414696" ]; then
        log "rollback FAILED: backup size ${backup_size} != 414696"
        return 1
    fi
    backup_sha="$(sha256_of "${backup}")"
    if [ "${backup_sha}" != "${expected_sha}" ]; then
        log "rollback FAILED: backup sha ${backup_sha} != recorded input ${expected_sha}; refusing to restore unknown firmware"
        return 1
    fi

    log "rollback: restoring firmware from ${backup}"
    cp "${backup}" "${KNOWN_FIRMWARE}.new"
    mv "${KNOWN_FIRMWARE}.new" "${KNOWN_FIRMWARE}"
    sync_file "${KNOWN_FIRMWARE}"
    sync_dir "$(dirname "${KNOWN_FIRMWARE}")"
    modprobe -r brcmfmac 2>/dev/null || true
    sleep 1
    modprobe brcmfmac 2>/dev/null || true
    log "rollback: firmware restored"
    return 0
}

# Boot oneshots that should NOT be re-executed on failure rollback.
# These are Type=oneshot with RemainAfterExit=yes; restarting them would
# re-trigger GPIO recovery / driver reload logic during reinstall.
ONESHOT_UNITS=(
    "oxigotchi-wifi-recovery.service"
    "oxigotchi-fix-ndev.service"
)

is_oneshot() {
    local needle="$1"
    local u
    for u in "${ONESHOT_UNITS[@]}"; do
        if [ "${u}" = "${needle}" ]; then
            return 0
        fi
    done
    return 1
}

restart_paused_services() {
    # Restart any long-running oxigotchi-* units that were stopped for reinstall.
    # Skip boot oneshots to avoid re-triggering recovery logic.
    for unit in "${STOPPED_OXIGOTCHI_UNITS[@]}"; do
        if is_oneshot "${unit}"; then
            log "skipping restart of oneshot unit ${unit}"
        else
            systemctl start "${unit}" 2>/dev/null || true
        fi
    done
    if [ "${PWNAGOTCHI_WAS_RUNNING}" -eq 1 ]; then
        systemctl start pwnagotchi 2>/dev/null || true
    fi
    if [ "${BETTERCAP_WAS_RUNNING}" -eq 1 ]; then
        systemctl start bettercap 2>/dev/null || true
    fi
}

cleanup_temp_files() {
    rm -f "${KNOWN_FIRMWARE}.new" 2>/dev/null || true
    rm -f "${KNOWN_BINARY}.new" 2>/dev/null || true
    rm -f "${STATE_FILE}.tmp" 2>/dev/null || true
    rm -f "${STATE_DIR}/state.json.previous.new" 2>/dev/null || true
    rm -f "${BACKUP_DIR}"/*.new 2>/dev/null || true
}

abort_with_rollback() {
    local reason="$1"
    log "install failed: ${reason}"
    cleanup_temp_files
    # Determine whether to roll back the firmware. Only if
    # firmware_written_this_run is true AND the state file is readable.
    local fwrote="false"
    if [ -f "${STATE_FILE}" ]; then
        fwrote="$(python3 -c "
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    print('true' if data.get('firmware_written_this_run') else 'false')
except Exception:
    print('false')
" "${STATE_FILE}")"
    fi
    if [ "${fwrote}" = "true" ]; then
        rollback_firmware || log "rollback failed; the firmware may be in an inconsistent state"
    else
        log "firmware was not written this run; no firmware rollback needed"
        # Restore state.json from the previous snapshot if available, so that
        # a failed reinstall does not leave an in_progress state that wedges
        # the next install attempt.
        if [ -f "${STATE_PREV}" ]; then
            cp "${STATE_PREV}" "${STATE_FILE}"
            sync_file "${STATE_FILE}"
            sync_dir "${STATE_DIR}"
            log "restored state.json from state.json.previous"
        else
            # No previous snapshot (fresh install failure). Keep the
            # in_progress state.json so uninstall.sh can find and clean
            # any userspace artifacts that were already written.
            log "state.json left as in_progress; run 'sudo ./scripts/uninstall.sh' to clean up, then retry"
        fi
    fi
    restart_paused_services
    exit 1
}

trap 'abort_with_rollback "unexpected failure on line ${LINENO}"' ERR

# ------------------------------------------------------------------
# Step 1: must be root
# ------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    die "must run as root (try: sudo ./scripts/install.sh)"
fi

# ------------------------------------------------------------------
# Step 2: must be Pi Zero 2 W
# ------------------------------------------------------------------
MODEL=""
if [ -r /proc/device-tree/model ]; then
    MODEL="$(tr -d '\0' < /proc/device-tree/model)"
fi
case "${MODEL}" in
    *"Raspberry Pi Zero 2 W"*)
        log "detected: ${MODEL}"
        ;;
    *)
        die "unsupported hardware: '${MODEL}'. This repo only supports Raspberry Pi Zero 2 W."
        ;;
esac

# ------------------------------------------------------------------
# Step 3: detect userland architecture
# ------------------------------------------------------------------
DPKG_ARCH=""
if command -v dpkg >/dev/null 2>&1; then
    DPKG_ARCH="$(dpkg --print-architecture 2>/dev/null || true)"
fi
UNAME_M="$(uname -m 2>/dev/null || true)"
case "${DPKG_ARCH}:${UNAME_M}" in
    arm64:*|*:aarch64)
        TARGET_ARCH="aarch64"
        ;;
    armhf:*|*:armv7l|*:armv6l)
        TARGET_ARCH="armhf"
        ;;
    *)
        die "unsupported userland architecture: dpkg='${DPKG_ARCH}' uname='${UNAME_M}'"
        ;;
esac
log "detected userland arch: ${TARGET_ARCH}"

# ------------------------------------------------------------------
# Step 4: validate manifest.json against the trusted hash table
# ------------------------------------------------------------------
MANIFEST="${PATCH_DIR}/manifest.json"
[ -f "${MANIFEST}" ] || die "manifest.json not found at ${MANIFEST}"

MANIFEST_COUNT="$(json_patch_count "${MANIFEST}")"
if [ "${MANIFEST_COUNT}" -lt 1 ]; then
    die "manifest.json contains no patches[] entries"
fi

validate_manifest_against_trusted_table() {
    local i="$1"
    local name input_sha output_sha patch_sha ua_sha uh_sha
    name="$(json_get_patch_field "${MANIFEST}" "${i}" "name")"
    input_sha="$(json_get_patch_field "${MANIFEST}" "${i}" "input_sha256")"
    output_sha="$(json_get_patch_field "${MANIFEST}" "${i}" "output_sha256")"
    patch_sha="$(json_get_patch_field "${MANIFEST}" "${i}" "patch_sha256")"
    ua_sha="$(json_get_patch_field "${MANIFEST}" "${i}" "userspace.aarch64_sha256")"
    uh_sha="$(json_get_patch_field "${MANIFEST}" "${i}" "userspace.armhf_sha256")"

    local trusted_input="${MANIFEST_TRUSTED_HASHES[${name}:input]:-}"
    local trusted_output="${MANIFEST_TRUSTED_HASHES[${name}:output]:-}"
    local trusted_patch="${MANIFEST_TRUSTED_HASHES[${name}:patch_file]:-}"
    local trusted_ua="${MANIFEST_TRUSTED_HASHES[${name}:userspace_aarch64]:-}"
    local trusted_uh="${MANIFEST_TRUSTED_HASHES[${name}:userspace_armhf]:-}"

    [ -n "${trusted_input}" ] || die "manifest tampered: ${name}:input has no installer-embedded trusted value"
    [ -n "${trusted_output}" ] || die "manifest tampered: ${name}:output has no installer-embedded trusted value"
    [ -n "${trusted_patch}" ] || die "manifest tampered: ${name}:patch_file has no installer-embedded trusted value"
    [ -n "${trusted_ua}" ] || die "manifest tampered: ${name}:userspace_aarch64 has no installer-embedded trusted value"
    [ -n "${trusted_uh}" ] || die "manifest tampered: ${name}:userspace_armhf has no installer-embedded trusted value"

    [ "${input_sha}" = "${trusted_input}" ] || die "manifest tampered: ${name}:input_sha256 does not match installer-embedded trusted value"
    [ "${output_sha}" = "${trusted_output}" ] || die "manifest tampered: ${name}:output_sha256 does not match installer-embedded trusted value"
    [ "${patch_sha}" = "${trusted_patch}" ] || die "manifest tampered: ${name}:patch_sha256 does not match installer-embedded trusted value"
    [ "${ua_sha}" = "${trusted_ua}" ] || die "manifest tampered: ${name}:userspace.aarch64_sha256 does not match installer-embedded trusted value"
    [ "${uh_sha}" = "${trusted_uh}" ] || die "manifest tampered: ${name}:userspace.armhf_sha256 does not match installer-embedded trusted value"
}

for ((i=0; i<MANIFEST_COUNT; i++)); do
    validate_manifest_against_trusted_table "${i}"
done
log "manifest validated against installer-embedded trusted hashes (${MANIFEST_COUNT} entries)"

# ------------------------------------------------------------------
# Step 5: pre-patch quiesce
# ------------------------------------------------------------------

# 5a: state file guard
PRIOR_STATE="none"
if [ -f "${STATE_FILE}" ]; then
    STATE_SCHEMA="$(python3 -c "
import json, sys
try:
    print(json.load(open(sys.argv[1])).get('schema_version', ''))
except Exception:
    print('')
" "${STATE_FILE}")"
    STATE_PHASE="$(python3 -c "
import json, sys
try:
    print(json.load(open(sys.argv[1])).get('phase', ''))
except Exception:
    print('')
" "${STATE_FILE}")"

    if [ "${STATE_SCHEMA}" != "1" ]; then
        die "existing state.json at ${STATE_FILE} has unsupported schema_version '${STATE_SCHEMA}'; refusing to touch"
    fi
    case "${STATE_PHASE}" in
        complete)
            PRIOR_STATE="complete"
            log "existing complete install detected; this will re-install over it"
            ;;
        in_progress)
            die "previous install was interrupted and left a partially-installed state. Run 'sudo ./scripts/uninstall.sh' to clean it up before retrying."
            ;;
        *)
            die "existing state.json has unknown phase '${STATE_PHASE}'; refusing to touch"
            ;;
    esac
fi

# 5b/5c: pause conflicting services
if systemctl is-active --quiet pwnagotchi 2>/dev/null; then
    PWNAGOTCHI_WAS_RUNNING=1
    systemctl stop pwnagotchi 2>/dev/null || true
    log "stopped pwnagotchi (was running)"
fi
if systemctl is-active --quiet bettercap 2>/dev/null; then
    BETTERCAP_WAS_RUNNING=1
    systemctl stop bettercap 2>/dev/null || true
    log "stopped bettercap (was running)"
fi

# 5b2: on reinstall, stop any pre-existing oxigotchi-* units to prevent
# them from racing the driver reload or interfering with file overwrites.
if [ "${PRIOR_STATE}" = "complete" ]; then
    for unit in "${KNOWN_SERVICES[@]}"; do
        if systemctl is-active --quiet "${unit}" 2>/dev/null; then
            systemctl stop "${unit}" 2>/dev/null || true
            STOPPED_OXIGOTCHI_UNITS+=("${unit}")
            log "stopped pre-existing ${unit} for reinstall"
        fi
    done
fi

# 5d: state + backups dirs
mkdir -p "${STATE_DIR}"
mkdir -p "${BACKUP_DIR}"

# 5e: preserve prior state for re-install safety
if [ "${PRIOR_STATE}" = "complete" ]; then
    cp "${STATE_FILE}" "${STATE_PREV}.new"
    sync_file "${STATE_PREV}.new"
    mv "${STATE_PREV}.new" "${STATE_PREV}"
    sync_file "${STATE_PREV}"
    sync_dir "${STATE_DIR}"
    log "snapshotted complete state.json to state.json.previous"
fi

# 5f: write stub state.json, pre-populating files.* from previous if present
python3 <<PYEOF
import json, os, sys
state_file = "${STATE_FILE}"
state_prev = "${STATE_PREV}"
prev_files = {"services": [], "scripts": [], "binary": None, "firmware": None}
if os.path.isfile(state_prev):
    try:
        prev = json.load(open(state_prev))
        pf = prev.get("files", {}) or {}
        if isinstance(pf.get("services"), list):
            prev_files["services"] = [s for s in pf["services"] if isinstance(s, str)]
        if isinstance(pf.get("scripts"), list):
            prev_files["scripts"] = [s for s in pf["scripts"] if isinstance(s, str)]
        if isinstance(pf.get("binary"), str):
            prev_files["binary"] = pf["binary"]
        if isinstance(pf.get("firmware"), str):
            prev_files["firmware"] = pf["firmware"]
    except Exception:
        pass
stub = {
    "schema_version": 1,
    "phase": "in_progress",
    "repo_version": None,
    "entry_name": None,
    "input_sha256": None,
    "output_sha256": None,
    "firmware_written_this_run": False,
    "firmware_restorable_on_uninstall": False,
    "backup_path": None,
    "symlink_fixed": False,
    "symlink_path": None,
    "symlink_original_target": None,
    "binary_sha256": None,
    "binary_source": None,
    "installed_at": None,
    "files": prev_files,
}
tmp_path = state_file + ".tmp"
with open(tmp_path, "w") as f:
    json.dump(stub, f, indent=2, sort_keys=True)
    f.write("\n")
PYEOF

# 5g: atomic commit of stub state
sync_file "${STATE_FILE}.tmp"
mv "${STATE_FILE}.tmp" "${STATE_FILE}"
sync_file "${STATE_FILE}"
sync_dir "${STATE_DIR}"
log "stub state.json written (phase=in_progress)"

# Atomically write state.json: write to .tmp, sync filesystem, rename, sync dir.
write_state() {
    local content="$1"
    local tmp="${STATE_FILE}.tmp"
    printf '%s\n' "$content" > "$tmp"
    sync_file "$tmp"
    mv "$tmp" "${STATE_FILE}"
    sync_file "${STATE_FILE}"
    sync_dir "${STATE_DIR}"
}

# Helper: update one field in state.json atomically (write-to-tmp, sync, rename, sync dir).
state_set() {
    local key="$1"
    local value_py="$2"
    local new_content
    new_content="$(python3 - "$STATE_FILE" "$key" "$value_py" <<'PYEOF'
import json, sys
path = sys.argv[1]
key = sys.argv[2]
value_py = sys.argv[3]
data = json.load(open(path))
# Evaluate value in a restricted namespace. The value_py string comes
# from install.sh itself, not from the manifest or user input.
value = eval(value_py, {"__builtins__": {}}, {})
# Support dotted paths like "files.services" or "files.binary".
if "." in key:
    parts = key.split(".")
    d = data
    for p in parts[:-1]:
        d = d.setdefault(p, {})
    d[parts[-1]] = value
else:
    data[key] = value
print(json.dumps(data, indent=2, sort_keys=True))
PYEOF
)"
    write_state "$new_content"
}

state_append_unique() {
    # Append a string to a list field in state.json unless it's already there.
    local key="$1"
    local value="$2"
    local new_content
    new_content="$(python3 - "$STATE_FILE" "$key" "$value" <<'PYEOF'
import json, sys
path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(open(path))
if "." in key:
    parts = key.split(".")
    d = data
    for p in parts[:-1]:
        d = d.setdefault(p, {})
    lst = d.setdefault(parts[-1], [])
else:
    lst = data.setdefault(key, [])
if value not in lst:
    lst.append(value)
print(json.dumps(data, indent=2, sort_keys=True))
PYEOF
)"
    write_state "$new_content"
}

# ------------------------------------------------------------------
# Step 6: firmware phase
# ------------------------------------------------------------------
[ -f "${KNOWN_FIRMWARE}" ] || die "firmware file missing: ${KNOWN_FIRMWARE}"

LIVE_FW_SHA="$(sha256_of "${KNOWN_FIRMWARE}")"
log "live firmware sha256: ${LIVE_FW_SHA}"

# 6b: find a matching manifest entry
for ((i=0; i<MANIFEST_COUNT; i++)); do
    name="$(json_get_patch_field "${MANIFEST}" "${i}" "name")"
    in_sha="$(json_get_patch_field "${MANIFEST}" "${i}" "input_sha256")"
    out_sha="$(json_get_patch_field "${MANIFEST}" "${i}" "output_sha256")"
    pfile="$(json_get_patch_field "${MANIFEST}" "${i}" "patch_file")"
    psha="$(json_get_patch_field "${MANIFEST}" "${i}" "patch_sha256")"
    if [ "${LIVE_FW_SHA}" = "${in_sha}" ]; then
        SELECTED_ENTRY="${name}"
        SELECTED_INPUT_SHA="${in_sha}"
        SELECTED_OUTPUT_SHA="${out_sha}"
        SELECTED_PATCH_FILE="${pfile}"
        SELECTED_PATCH_SHA="${psha}"
        FIRMWARE_PATH="patch"
        break
    fi
    if [ "${LIVE_FW_SHA}" = "${out_sha}" ]; then
        SELECTED_ENTRY="${name}"
        SELECTED_INPUT_SHA="${in_sha}"
        SELECTED_OUTPUT_SHA="${out_sha}"
        SELECTED_PATCH_FILE="${pfile}"
        SELECTED_PATCH_SHA="${psha}"
        FIRMWARE_PATH="already-patched"
        break
    fi
done

if [ -z "${SELECTED_ENTRY}" ]; then
    cat >&2 <<EOF
[install] ERROR: live firmware sha256 ${LIVE_FW_SHA} does not match any
supported input or output hash in patches/manifest.json.

This installer is targeted at the nexmon-patched firmware shipped by
jayofelony's pwnagotchi image. Unsupported firmware sources are explicitly
not patched, because the byte diff would land on the wrong instructions.

Supported source: https://github.com/jayofelony/pwnagotchi

Do NOT 'apt install --reinstall firmware-brcm80211' — that would restore
the stock Broadcom firmware which this installer cannot patch either.
EOF
    die "unsupported firmware (sha256: ${LIVE_FW_SHA})"
fi

log "selected manifest entry: ${SELECTED_ENTRY} (firmware path: ${FIRMWARE_PATH})"

# 6c: write identity fields into state.json regardless of path
REPO_VERSION="$(json_get "${MANIFEST}" 'data["repo_version"]')"
state_set "entry_name" "'${SELECTED_ENTRY}'"
state_set "input_sha256" "'${SELECTED_INPUT_SHA}'"
state_set "output_sha256" "'${SELECTED_OUTPUT_SHA}'"
state_set "repo_version" "'${REPO_VERSION}'"
state_set "firmware_written_this_run" "False"
state_set "firmware_restorable_on_uninstall" "False"
state_set "backup_path" "None"
state_set "files.firmware" "'${KNOWN_FIRMWARE}'"

# Compute deterministic backup path keyed by input sha (first 16 chars).
SHA16="${SELECTED_INPUT_SHA:0:16}"
BACKUP_PATH="${BACKUP_DIR}/brcmfmac43436-sdio.${SHA16}.bin"

if [ "${FIRMWARE_PATH}" = "already-patched" ]; then
    # 6d: adopt an already-patched firmware; reuse backup if it exists
    if [ -f "${BACKUP_PATH}" ]; then
        EXISTING_BACKUP_SHA="$(sha256_of "${BACKUP_PATH}")"
        if [ "${EXISTING_BACKUP_SHA}" = "${SELECTED_INPUT_SHA}" ]; then
            state_set "backup_path" "'${BACKUP_PATH}'"
            state_set "firmware_restorable_on_uninstall" "True"
            log "adopted firmware: reusable backup present at ${BACKUP_PATH}"
        else
            log "adopted firmware: existing backup at ${BACKUP_PATH} is corrupted; leaving backup_path=null"
        fi
    else
        log "adopted firmware: no backup present; uninstall will not be able to restore the original firmware"
    fi
    log "firmware already patched (entry: ${SELECTED_ENTRY}); skipping firmware phase"
else
    # 6e: backup setup on the patch path
    if [ -f "${BACKUP_PATH}" ]; then
        EXISTING_BACKUP_SHA="$(sha256_of "${BACKUP_PATH}")"
        if [ "${EXISTING_BACKUP_SHA}" = "${SELECTED_INPUT_SHA}" ]; then
            log "reusing existing backup at ${BACKUP_PATH}"
        else
            die "existing backup at ${BACKUP_PATH} has unexpected SHA-256 (${EXISTING_BACKUP_SHA} instead of ${SELECTED_INPUT_SHA}); refusing to overwrite. Move or investigate the file manually before retrying."
        fi
    else
        cp "${KNOWN_FIRMWARE}" "${BACKUP_PATH}.new"
        NEW_BACKUP_SHA="$(sha256_of "${BACKUP_PATH}.new")"
        if [ "${NEW_BACKUP_SHA}" != "${SELECTED_INPUT_SHA}" ]; then
            rm -f "${BACKUP_PATH}.new"
            die "backup copy sha256 mismatch (${NEW_BACKUP_SHA} != ${SELECTED_INPUT_SHA}); probable in-flight corruption, aborting"
        fi
        mv "${BACKUP_PATH}.new" "${BACKUP_PATH}"
        sync_file "${BACKUP_PATH}"
        sync_dir "${BACKUP_DIR}"
        log "backup created: ${BACKUP_PATH}"
    fi
    state_set "backup_path" "'${BACKUP_PATH}'"
    state_set "firmware_restorable_on_uninstall" "True"

    # 6f: stage the firmware write
    cp "${KNOWN_FIRMWARE}" "${KNOWN_FIRMWARE}.new"

    # 6g: verify patch file sha matches both manifest and trusted table
    PATCH_FILE_PATH="${REPO_DIR}/${SELECTED_PATCH_FILE}"
    [ -f "${PATCH_FILE_PATH}" ] || die "patch file missing: ${PATCH_FILE_PATH}"
    ACTUAL_PATCH_SHA="$(sha256_of "${PATCH_FILE_PATH}")"
    TRUSTED_PATCH_SHA="${MANIFEST_TRUSTED_HASHES[${SELECTED_ENTRY}:patch_file]:-}"
    if [ "${ACTUAL_PATCH_SHA}" != "${SELECTED_PATCH_SHA}" ]; then
        die "patch file sha256 does not match manifest: on-disk=${ACTUAL_PATCH_SHA}, manifest=${SELECTED_PATCH_SHA}"
    fi
    if [ "${ACTUAL_PATCH_SHA}" != "${TRUSTED_PATCH_SHA}" ]; then
        die "patch file sha256 does not match installer-embedded trusted value: on-disk=${ACTUAL_PATCH_SHA}, trusted=${TRUSTED_PATCH_SHA}"
    fi

    # 6h: apply each patch line to the staged .new file
    python3 - "${KNOWN_FIRMWARE}.new" "${PATCH_FILE_PATH}" <<'PYEOF'
import sys, re
firmware_path, patch_path = sys.argv[1], sys.argv[2]
data = bytearray(open(firmware_path, "rb").read())
lines_applied = 0
with open(patch_path, "r", encoding="utf-8") as f:
    for lineno, raw in enumerate(f, 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) < 3:
            print(f"patch line {lineno}: not enough fields: {line!r}", file=sys.stderr)
            sys.exit(2)
        offset_s, old_s, new_s = parts[0], parts[1], parts[2]
        m = re.match(r"^0x([0-9A-Fa-f]+)$", offset_s)
        if not m:
            print(f"patch line {lineno}: bad offset: {offset_s!r}", file=sys.stderr)
            sys.exit(2)
        offset = int(m.group(1), 16)
        try:
            old_b = bytes.fromhex(old_s)
            new_b = bytes.fromhex(new_s)
        except ValueError:
            print(f"patch line {lineno}: bad hex: {line!r}", file=sys.stderr)
            sys.exit(2)
        if len(old_b) != len(new_b):
            print(f"patch line {lineno}: old/new length mismatch", file=sys.stderr)
            sys.exit(2)
        got = bytes(data[offset:offset+len(old_b)])
        if got != old_b:
            print(
                f"patch line {lineno}: expected {old_b.hex()} at offset 0x{offset:X}, "
                f"found {got.hex()}", file=sys.stderr,
            )
            sys.exit(2)
        data[offset:offset+len(new_b)] = new_b
        lines_applied += 1
with open(firmware_path, "wb") as f:
    f.write(bytes(data))
print(f"[install] applied {lines_applied} patch lines", file=sys.stderr)
PYEOF

    # 6i: verify output sha256
    STAGED_SHA="$(sha256_of "${KNOWN_FIRMWARE}.new")"
    if [ "${STAGED_SHA}" != "${SELECTED_OUTPUT_SHA}" ]; then
        rm -f "${KNOWN_FIRMWARE}.new"
        die "patched firmware sha256 ${STAGED_SHA} does not match expected ${SELECTED_OUTPUT_SHA}"
    fi
    log "staged firmware sha256 matches expected output"

    # 6j: atomic rename -- POINT OF NO RETURN
    mv "${KNOWN_FIRMWARE}.new" "${KNOWN_FIRMWARE}"
    sync_file "${KNOWN_FIRMWARE}"
    sync_dir "$(dirname "${KNOWN_FIRMWARE}")"

    # 6k: flip the flag
    state_set "firmware_written_this_run" "True"
    log "firmware patched in place"
fi

# ------------------------------------------------------------------
# Step 6l: board-specific symlink fixup
# ------------------------------------------------------------------
# On some Pi Zero 2W boards, the chip reports as BCM43430/1 (not B0) and
# the driver loads firmware via brcmfmac43430-sdio.raspberrypi,model-zero-2-w.bin.
# If this symlink points to the stock Cypress firmware (brcmfmac43436s-sdio.bin
# -> cyfmac43430-sdio.bin) instead of the nexmon firmware we just patched
# (brcmfmac43436-sdio.bin), the patched firmware is never loaded.
if [ -L "${BOARD_SYMLINK}" ]; then
    CURRENT_SYMLINK_TARGET="$(readlink "${BOARD_SYMLINK}")"
    if [ "${CURRENT_SYMLINK_TARGET}" != "${BOARD_SYMLINK_EXPECTED_TARGET}" ]; then
        state_set "symlink_path" "'${BOARD_SYMLINK}'"
        state_set "symlink_original_target" "'${CURRENT_SYMLINK_TARGET}'"
        ln -sf "${BOARD_SYMLINK_EXPECTED_TARGET}" "${BOARD_SYMLINK}"
        sync_dir "$(dirname "${BOARD_SYMLINK}")"
        state_set "symlink_fixed" "True"
        log "redirected board symlink: ${CURRENT_SYMLINK_TARGET} -> ${BOARD_SYMLINK_EXPECTED_TARGET}"
    else
        log "board symlink already correct: ${BOARD_SYMLINK} -> ${BOARD_SYMLINK_EXPECTED_TARGET}"
    fi
elif [ ! -e "${BOARD_SYMLINK}" ]; then
    ln -sf "${BOARD_SYMLINK_EXPECTED_TARGET}" "${BOARD_SYMLINK}"
    sync_dir "$(dirname "${BOARD_SYMLINK}")"
    state_set "symlink_path" "'${BOARD_SYMLINK}'"
    state_set "symlink_original_target" "''"
    state_set "symlink_fixed" "True"
    log "created board symlink: ${BOARD_SYMLINK} -> ${BOARD_SYMLINK_EXPECTED_TARGET}"
else
    log "board symlink path is not a symlink (regular file?): ${BOARD_SYMLINK}; skipping"
fi

# ------------------------------------------------------------------
# Step 7: userspace binary phase
# ------------------------------------------------------------------
case "${TARGET_ARCH}" in
    aarch64)
        SELECTED_USERSPACE_PATH="${USERSPACE_DIR}/wlan_keepalive.aarch64"
        SELECTED_USERSPACE_SHA="$(json_get_patch_field "${MANIFEST}" "$(python3 -c "
import json
data = json.load(open('${MANIFEST}'))
for i, p in enumerate(data['patches']):
    if p['name'] == '${SELECTED_ENTRY}':
        print(i); break
")" "userspace.aarch64_sha256")"
        TRUSTED_USERSPACE_SHA="${MANIFEST_TRUSTED_HASHES[${SELECTED_ENTRY}:userspace_aarch64]:-}"
        BINARY_SOURCE="prebuilt-aarch64"
        ;;
    armhf)
        SELECTED_USERSPACE_PATH="${USERSPACE_DIR}/wlan_keepalive.armhf"
        SELECTED_USERSPACE_SHA="$(json_get_patch_field "${MANIFEST}" "$(python3 -c "
import json
data = json.load(open('${MANIFEST}'))
for i, p in enumerate(data['patches']):
    if p['name'] == '${SELECTED_ENTRY}':
        print(i); break
")" "userspace.armhf_sha256")"
        TRUSTED_USERSPACE_SHA="${MANIFEST_TRUSTED_HASHES[${SELECTED_ENTRY}:userspace_armhf]:-}"
        BINARY_SOURCE="prebuilt-armhf"
        ;;
esac

[ -f "${SELECTED_USERSPACE_PATH}" ] || die "userspace binary missing: ${SELECTED_USERSPACE_PATH}"

ACTUAL_USERSPACE_SHA="$(sha256_of "${SELECTED_USERSPACE_PATH}")"
if [ "${ACTUAL_USERSPACE_SHA}" != "${SELECTED_USERSPACE_SHA}" ]; then
    die "userspace binary sha256 ${ACTUAL_USERSPACE_SHA} does not match manifest ${SELECTED_USERSPACE_SHA}"
fi
if [ "${ACTUAL_USERSPACE_SHA}" != "${TRUSTED_USERSPACE_SHA}" ]; then
    die "userspace binary sha256 ${ACTUAL_USERSPACE_SHA} does not match installer-embedded trusted value ${TRUSTED_USERSPACE_SHA}"
fi
log "userspace binary sha256 verified"

# 7c: copy to .new, chmod, then atomic rename
cp "${SELECTED_USERSPACE_PATH}" "${KNOWN_BINARY}.new"
chmod 0755 "${KNOWN_BINARY}.new"

# 7c2: record the FINAL path in state.json before the rename
state_set "files.binary" "'${KNOWN_BINARY}'"

# 7c3: reverify the copy
COPY_SHA="$(sha256_of "${KNOWN_BINARY}.new")"
if [ "${COPY_SHA}" != "${ACTUAL_USERSPACE_SHA}" ]; then
    rm -f "${KNOWN_BINARY}.new"
    die "copied binary sha256 ${COPY_SHA} does not match source ${ACTUAL_USERSPACE_SHA} (bit-rot?)"
fi

# 7c4: atomic rename + 7c5: durability
mv "${KNOWN_BINARY}.new" "${KNOWN_BINARY}"
sync_file "${KNOWN_BINARY}"
sync_dir "$(dirname "${KNOWN_BINARY}")"

# 7d: ELF arch sanity check
ARCH_SANE=1
FILE_OUT="$(file "${KNOWN_BINARY}" 2>/dev/null || true)"
case "${TARGET_ARCH}:${FILE_OUT}" in
    aarch64:*"ARM aarch64"*) ARCH_SANE=1 ;;
    armhf:*"ARM"*"EABI"*)    ARCH_SANE=1 ;;
    *)                       ARCH_SANE=0 ;;
esac

# 7e: functional smoke test
NEEDS_FALLBACK=0
if [ "${ARCH_SANE}" -ne 1 ]; then
    log "ELF arch sanity check failed: ${FILE_OUT}"
    NEEDS_FALLBACK=1
else
    set +e
    timeout 1s "${KNOWN_BINARY}" __nonexistent_iface__ 100 >/dev/null 2>&1
    SMOKE_RC=$?
    set -e
    case "${SMOKE_RC}" in
        124) log "smoke test OK (timeout while waiting for iface, as expected)" ;;
        126|127)
            log "smoke test exec failure (rc=${SMOKE_RC}); will try compile-from-source"
            NEEDS_FALLBACK=1
            ;;
        *)
            log "smoke test returned unexpected rc=${SMOKE_RC}; will try compile-from-source"
            NEEDS_FALLBACK=1
            ;;
    esac
fi

# 7f: compile-from-source fallback (compile to .new, then atomic rename)
if [ "${NEEDS_FALLBACK}" -eq 1 ]; then
    log "falling back to compile-from-source"
    if ! command -v gcc >/dev/null 2>&1; then
        log "gcc not found; installing gcc + libc6-dev"
        apt-get install -y gcc libc6-dev || die "apt-get install gcc libc6-dev failed"
    fi
    if ! gcc -O2 -static-pie -s -o "${KNOWN_BINARY}.new" "${USERSPACE_DIR}/wlan_keepalive.c"; then
        # Retry without static-pie (some toolchains lack rcrt1.o)
        if ! gcc -O2 -static -s -o "${KNOWN_BINARY}.new" "${USERSPACE_DIR}/wlan_keepalive.c"; then
            rm -f "${KNOWN_BINARY}.new" 2>/dev/null || true
            die "compile-from-source failed; cannot install keepalive daemon"
        fi
    fi
    chmod 0755 "${KNOWN_BINARY}.new"
    mv "${KNOWN_BINARY}.new" "${KNOWN_BINARY}"
    sync_file "${KNOWN_BINARY}"
    sync_dir "$(dirname "${KNOWN_BINARY}")"
    BINARY_SOURCE="compiled-from-source"
    log "compiled wlan_keepalive from source"
fi

# 7h: record the actual installed sha
INSTALLED_BINARY_SHA="$(sha256_of "${KNOWN_BINARY}")"
state_set "binary_sha256" "'${INSTALLED_BINARY_SHA}'"
state_set "binary_source" "'${BINARY_SOURCE}'"
log "userspace binary installed: source=${BINARY_SOURCE} sha256=${INSTALLED_BINARY_SHA}"

# ------------------------------------------------------------------
# Step 8: userspace scripts phase
# ------------------------------------------------------------------
# Pre-check: globbed scripts must exactly match the hard-coded set.
SCRIPT_MAP=(
    "oxigotchi-wifi-watchdog.sh:/usr/local/bin/oxigotchi-wifi-watchdog.sh"
    "oxigotchi-wifi-recovery.sh:/usr/local/bin/oxigotchi-wifi-recovery.sh"
    "oxigotchi-fix-ndev.sh:/usr/local/bin/oxigotchi-fix-ndev.sh"
)

EXPECTED_SCRIPTS=("oxigotchi-wifi-watchdog.sh" "oxigotchi-wifi-recovery.sh" "oxigotchi-fix-ndev.sh")

FOUND_SCRIPTS=()
shopt -s nullglob
for f in "${USERSPACE_DIR}"/oxigotchi-*.sh; do
    FOUND_SCRIPTS+=("$(basename "$f")")
done
shopt -u nullglob

# Strict set equality: every found script must be in the expected set and vice versa.
for name in "${FOUND_SCRIPTS[@]}"; do
    matched=0
    for want in "${EXPECTED_SCRIPTS[@]}"; do
        if [ "${name}" = "${want}" ]; then
            matched=1
            break
        fi
    done
    if [ "${matched}" -ne 1 ]; then
        die "repository contains an unexpected userspace script: ${name}; refusing to install"
    fi
done
for want in "${EXPECTED_SCRIPTS[@]}"; do
    missing=1
    for name in "${FOUND_SCRIPTS[@]}"; do
        if [ "${name}" = "${want}" ]; then
            missing=0
            break
        fi
    done
    if [ "${missing}" -ne 0 ]; then
        die "repository is missing expected userspace script: ${want}"
    fi
done

for entry in "${SCRIPT_MAP[@]}"; do
    src_name="${entry%%:*}"
    dest="${entry##*:}"
    src="${USERSPACE_DIR}/${src_name}"
    [ -f "${src}" ] || die "script source missing: ${src}"

    # 8a: pre-record dest in state.json BEFORE writing the file
    state_append_unique "files.scripts" "${dest}"

    # 8b: strip any stray CRLFs into a staging file
    sed 's/\r$//' "${src}" > "${dest}.new"
    chmod 0755 "${dest}.new"

    # 8c: atomic rename + durability
    mv "${dest}.new" "${dest}"
    sync_file "${dest}"
    log "installed script: ${dest}"
done
sync_dir "/usr/local/bin"

# ------------------------------------------------------------------
# Step 9: services phase (install only, do NOT start)
# ------------------------------------------------------------------
EXPECTED_UNITS=(
    "oxigotchi-wlan-keepalive.service"
    "oxigotchi-wifi-watchdog.service"
    "oxigotchi-wifi-recovery.service"
    "oxigotchi-fix-ndev.service"
)

FOUND_UNITS=()
shopt -s nullglob
for f in "${SERVICES_DIR}"/oxigotchi-*.service; do
    FOUND_UNITS+=("$(basename "$f")")
done
shopt -u nullglob

for name in "${FOUND_UNITS[@]}"; do
    matched=0
    for want in "${EXPECTED_UNITS[@]}"; do
        if [ "${name}" = "${want}" ]; then
            matched=1
            break
        fi
    done
    if [ "${matched}" -ne 1 ]; then
        die "repository contains an unexpected service unit: ${name}; refusing to install"
    fi
done
for want in "${EXPECTED_UNITS[@]}"; do
    missing=1
    for name in "${FOUND_UNITS[@]}"; do
        if [ "${name}" = "${want}" ]; then
            missing=0
            break
        fi
    done
    if [ "${missing}" -ne 0 ]; then
        die "repository is missing expected service unit: ${want}"
    fi
done

for unit in "${EXPECTED_UNITS[@]}"; do
    src="${SERVICES_DIR}/${unit}"
    dest="/etc/systemd/system/${unit}"
    [ -f "${src}" ] || die "service source missing: ${src}"

    # 9a: pre-record the bare unit name in state.json BEFORE writing the file
    state_append_unique "files.services" "${unit}"

    # 9b: atomic copy via temp + rename
    cp "${src}" "${dest}.new"
    mv "${dest}.new" "${dest}"

    # 9c: durability
    sync_file "${dest}"
    log "installed unit: ${unit}"
done

# 9d: commit directory entries
sync_dir "/etc/systemd/system"

# 9e: daemon reload
systemctl daemon-reload

# 9f: enable (NOT --now) each unit
systemctl enable \
    oxigotchi-wifi-recovery \
    oxigotchi-fix-ndev \
    oxigotchi-wifi-watchdog \
    oxigotchi-wlan-keepalive 2>&1 | while read -r line; do log "systemctl enable: ${line}"; done

# ------------------------------------------------------------------
# Step 10: driver reload + activation
# ------------------------------------------------------------------
log "reloading brcmfmac driver"
modprobe -r brcmfmac 2>/dev/null || true
sleep 1
modprobe brcmfmac

# 10c: wait up to 15s for wlan0
WLAN0_OK=0
for i in $(seq 1 15); do
    if [ -e /sys/class/net/wlan0 ]; then
        WLAN0_OK=1
        log "wlan0 present after ${i}s"
        break
    fi
    sleep 1
done
if [ "${WLAN0_OK}" -ne 1 ]; then
    die "wlan0 did not appear within 15s after modprobe; firmware may be broken"
fi

# 10d: best-effort wait for wlan0mon
WLAN0MON_OK=0
for i in $(seq 1 30); do
    if [ -e /sys/class/net/wlan0mon ]; then
        WLAN0MON_OK=1
        log "wlan0mon present after ${i}s"
        break
    fi
    sleep 1
done
if [ "${WLAN0MON_OK}" -ne 1 ]; then
    log "wlan0mon not yet present; keepalive will sit in its iface-wait loop until something else creates it (documented behavior)"
fi

# 10e/f: start only the long-running keepalive daemon; check it is active
systemctl start oxigotchi-wlan-keepalive
sleep 1
if ! systemctl is-active --quiet oxigotchi-wlan-keepalive; then
    die "oxigotchi-wlan-keepalive failed to start"
fi
log "oxigotchi-wlan-keepalive is running"

# 10g/h: restart anything we paused in step 5
restart_paused_services

# ------------------------------------------------------------------
# Step 11: finalize state.json
# ------------------------------------------------------------------
INSTALLED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
state_set "phase" "'complete'"
state_set "installed_at" "'${INSTALLED_AT}'"
state_set "repo_version" "'${REPO_VERSION}'"
state_set "files.firmware" "'${KNOWN_FIRMWARE}'"

# 11f: clean up the re-install snapshot if any
rm -f "${STATE_PREV}" || true

# ------------------------------------------------------------------
# Step 12: summary
# ------------------------------------------------------------------
trap - ERR
cat <<EOF

=========================================================
 pwnagotchi-bcm43436b0-fix ${REPO_VERSION} installed
=========================================================
 firmware    : ${KNOWN_FIRMWARE}
   entry     : ${SELECTED_ENTRY}
   input sha : ${SELECTED_INPUT_SHA}
   output sha: ${SELECTED_OUTPUT_SHA}
   path      : ${FIRMWARE_PATH}

 binary      : ${KNOWN_BINARY}
   source    : ${BINARY_SOURCE}
   sha256    : ${INSTALLED_BINARY_SHA}

 services    :
EOF
for unit in "${EXPECTED_UNITS[@]}"; do
    status="$(systemctl is-active "${unit}" 2>/dev/null || echo unknown)"
    enabled="$(systemctl is-enabled "${unit}" 2>/dev/null || echo unknown)"
    printf '   %-36s %s / %s\n' "${unit}" "${enabled}" "${status}"
done
cat <<EOF

 wlan0       : $( [ -e /sys/class/net/wlan0 ] && echo present || echo missing )
 wlan0mon    : $( [ -e /sys/class/net/wlan0mon ] && echo present || echo missing )
 state file  : ${STATE_FILE}

 reboot recommended so the boot oneshots run in their normal ordering.
=========================================================
EOF
