# patches/ — auditor notes

This directory contains the machine-readable artifacts the installer
applies at install time. There are three files:

| File | Purpose |
|------|---------|
| `manifest.json` | binds input firmware SHA-256 to (patch file, patch file SHA-256, output firmware SHA-256, userspace binary SHAs) |
| `inplace-v7.txt` | the byte-level patch table for the v7 stability patch set |
| `inplace-v7.txt.sha256` | a one-line sha256sum of `inplace-v7.txt`, for casual re-verification |

Everything in this directory is **plain text** and is meant to be
reviewed by hand. There is no opaque binary "patch blob". If you are
auditing whether this repo is safe to run, these three files plus
`scripts/install.sh` contain every bit you need.

## `manifest.json`

Schema:

```json
{
  "schema_version": 1,
  "repo_version": "0.1.0",
  "patches": [
    {
      "name": "v7",
      "input_sha256":  "<64 hex chars>",
      "input_size":    414696,
      "patch_file":    "patches/inplace-v7.txt",
      "patch_sha256":  "<64 hex chars>",
      "output_sha256": "<64 hex chars>",
      "output_size":   414696,
      "userspace": {
        "aarch64_sha256": "<64 hex chars>",
        "armhf_sha256":   "<64 hex chars>"
      },
      "description": "..."
    }
  ]
}
```

Fields:

- `schema_version` — bumped whenever the manifest structure changes in
  a backward-incompatible way. The installer hard-refuses any value
  other than `1`.
- `repo_version` — semver-ish version of the repo as a whole.
- `patches` — an append-only array. When a new firmware revision
  becomes supported, a new entry is appended; existing entries are
  never modified.
- `patches[i].name` — short identifier for this patch set (e.g. `"v7"`).
- `patches[i].input_sha256` — SHA-256 the on-disk firmware file must
  equal before we will apply `patch_file` to it.
- `patches[i].input_size` — canonical size the on-disk firmware file
  must equal. A size mismatch always implies a SHA mismatch; the size
  field is informational.
- `patches[i].patch_file` — repo-relative path to the
  `inplace-vN.txt` file for this entry.
- `patches[i].patch_sha256` — SHA-256 the actual on-disk
  `inplace-vN.txt` file must equal. The installer recomputes this
  before reading the patch file.
- `patches[i].output_sha256` — SHA-256 the patched firmware must
  equal after the patch is applied. The installer recomputes this
  before renaming the patched firmware into place; any mismatch
  aborts without touching the live firmware file.
- `patches[i].userspace.aarch64_sha256` — SHA-256 of
  `userspace/wlan_keepalive.aarch64`.
- `patches[i].userspace.armhf_sha256` — SHA-256 of
  `userspace/wlan_keepalive.armhf`.
- `patches[i].description` — one-line human-readable summary.

### Trust model

The installer does **not** trust `manifest.json` blindly. Before it
reads any value out of the manifest, it validates every hash in every
entry against a hard-coded `MANIFEST_TRUSTED_HASHES` table embedded
inside `scripts/install.sh`. Any mismatch is a fatal
`"manifest tampered: <entry>:<field>"` error.

The installer also recomputes the actual on-disk SHA-256 of the patch
file and the userspace binary it is about to use, before using them,
and compares the computed values against **both** the manifest and
the trusted table.

This is a tripwire against single-file edits. It is **not**
cryptographic signing: an attacker who can rewrite both
`manifest.json` and `install.sh` in the same commit defeats it. See
`NOTICE` for the full tamper-evidence caveat. Cryptographic signing
is filed as a v1.1 release blocker.

## `inplace-v7.txt`

Plain text, one line per contiguous run of differing bytes. Lines
starting with `#` are comments and are skipped by the installer.

Format:

```
offset_hex | old_bytes_hex | new_bytes_hex | layer | description
```

Fields:

- `offset_hex` — absolute byte offset into the firmware file, as a
  `0x`-prefixed hex number.
- `old_bytes_hex` — the bytes the patcher expects to find at
  `offset_hex` before writing. The installer reads these bytes and
  hard-errors if they don't match, so a wrong-firmware image can never
  be mis-patched.
- `new_bytes_hex` — the bytes the patcher will write after asserting
  `old_bytes_hex`. Must have the same length as `old_bytes_hex`.
- `layer` — which of the eight published stability layers this run
  belongs to. See `../LAYERS.md` for plain-English descriptions of
  each layer.
- `description` — a one-line plain-English purpose. Deliberately does
  **not** contain firmware-internal symbol names, register names, or
  any other reverse-engineering artifacts.

The file header records the source and target SHA-256s so you can
recompute them from your own firmware and diff the result against this
file.

### How the installer applies it

For each non-comment line, the installer:

1. parses the offset / old / new / layer / description;
2. seeks to `offset` in a staged copy of the live firmware;
3. reads `len(old)` bytes and asserts they equal `old_bytes_hex`;
4. writes `new_bytes_hex` at the same position.

After every line has been applied, the installer recomputes the
SHA-256 of the staged file and asserts it equals the manifest's
`output_sha256`. Only then does it atomically rename the staged file
over the live firmware. A size or SHA mismatch aborts before any
rename.

## `inplace-v7.txt.sha256`

Single-line `sha256sum`-format file for casual re-verification:

```
<64 hex chars>  inplace-v7.txt
```

The installer does **not** trust this file. It computes the hash
itself and compares against `manifest.json` + the installer-embedded
trusted table. This `.sha256` sidecar is only here so you can quickly
check integrity by hand:

```
cd patches
sha256sum -c inplace-v7.txt.sha256
```

## Regenerating `inplace-vN.txt` from scratch

If you want to reproduce the patch table yourself — for example to
audit that the byte diff really does come from two specific firmware
files you obtained independently — use the dev tool:

```
python3 tools/generate_inplace.py INPUT.bin OUTPUT.bin --name v7 > patches/inplace-v7.txt
```

The tool will auto-annotate the three single-byte watchdog threshold
changes, but every other line will be emitted with a
`layerX | TODO: hand-annotate layer and description` placeholder. The
layer/description columns in the committed `inplace-v7.txt` were
filled in by hand from the commentary in `../LAYERS.md`.

The layer and description columns are **not** authoritative for what
the installer does — only the offset / old / new columns are. The
layer column is there for auditors who want to cross-reference a
specific byte-level change with the plain-English description in
`LAYERS.md`.
