# Changelog

All notable changes to this repository are documented here. The format is
loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project follows semantic-ish versioning.

## 0.1.0 - 2026-04-11

Initial public release.

### Added
- BCM43436B0 8-layer stability byte-patch (`patches/inplace-v7.txt`) targeted
  at the nexmon-patched `brcmfmac43436-sdio.bin` shipped by jayofelony's
  pwnagotchi image.
- `patches/manifest.json` binding input firmware SHA-256 to patch file,
  output firmware SHA-256, and userspace binary SHAs for the v7 entry.
- Userspace keepalive daemon (`wlan_keepalive.c`) plus two pre-built static
  binaries for aarch64 and armhf.
- Three userspace recovery/watchdog scripts renamed with an `oxigotchi-`
  prefix (`oxigotchi-wifi-watchdog.sh`, `oxigotchi-wifi-recovery.sh`,
  `oxigotchi-fix-ndev.sh`).
- Four systemd unit files with the same `oxigotchi-` prefix to avoid
  colliding with any existing user-installed services.
- `scripts/install.sh`, `scripts/uninstall.sh`, and `scripts/verify.sh`
  implementing the install/uninstall/verify flow described in the design
  document. The installer enforces a hard Raspberry Pi Zero 2 W model check,
  validates the manifest against a hard-coded trusted hash table, takes a
  SHA-keyed backup of the input firmware before touching anything, writes a
  `state.json` recovery anchor, and falls back to compile-from-source if the
  prebuilt binary fails a smoke test.
- `LAYERS.md` — plain-English description of each of the eight stability
  layers, with no firmware-internal symbol names, addresses, or disassembly
  artifacts.
- `tools/generate_inplace.py` — dev-only helper that re-derives
  `patches/inplace-vN.txt` from two firmware binaries. The layer and
  description columns are hand-annotated after generation.
- `NOTICE` describing the legal-hygiene stance of shipping byte-level patch
  facts without shipping any firmware bytes, and the unsigned-distribution
  tamper-evidence caveat.

### Known limitations
- Four accepted limitations (L1-L4) are documented in the design doc and
  planned for v1.1. Briefly: uninstall validates the backup after starting
  cleanup (rather than before); file contents are not explicitly fsynced
  before directory metadata sync; the durability-primitive description
  says "fsync" where coreutils actually does `syncfs`; and in-place
  `state.json` mutations are not wrapped in a temp-file + atomic-rename
  primitive. None of these have practical user impact on the supported
  target hardware and image.
- This release is unsigned. Cryptographic signing via signed git tags is
  filed as a v1.1 release blocker.
