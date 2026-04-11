# Known Issues

This file records known issues in the current v0.1.0 release, grouped by
severity. These are documented here so that real users who encounter
them can file against a specific tracked item. Everything listed below is
an accepted v1 limitation; fixes are planned for v1.1.

## Accepted v1 limitations (from the design spec)

The following four limitations were explicitly accepted during the spec
review and are deferred to v1.1. All four are rare-crash-window edge
cases with negligible practical impact for the target user audience (a
single user running `sudo ./scripts/install.sh` once on a powered-up Pi
Zero 2 W to stop their WiFi from crashing).

### L1 — HIGH — Uninstall partial cleanup on backup file corruption

**Symptom:** If `state.firmware_restorable_on_uninstall` is true and the
live firmware matches `state.output_sha256`, `uninstall.sh` step 2b
classifies the outcome as `RESTORE` and proceeds with steps 3-4 (service
teardown + userspace cleanup) before step 5 actually validates the
backup file. If the backup file is missing, symlinked, wrong-sized, or
hash-corrupt when step 5 runs, uninstall hard-errors *after* services
and scripts have already been removed.

**Why v1 accepts it:** Requires the backup file in
`/var/lib/pwnagotchi-bcm43436b0-fix/backups/` to have been corrupted
between install and uninstall (bit-rot or third-party tampering —
rare). Recovery is reflash, which is the same recovery as for any
firmware-related corruption.

**v1.1 fix:** Hoist the full step-5 backup safety checks into step 2b
alongside the live-hash classification, so the entire decision is made
before any destructive cleanup.

### L2 — HIGH — File data not explicitly fsynced before directory sync

**Symptom:** The install flow uses `cp source dest.new && mv dest.new
dest && sync /parent_dir` for atomic file replacement. On Linux ext4
with the default `data=ordered` mount, directory metadata flushes in
practice also flush the file data before them, so this race window is
essentially zero on the supported target — but strictly speaking, a
power loss in the right window could leave a directory entry pointing
at non-durable file contents.

**Why v1 accepts it:** ext4 `data=ordered` on Raspberry Pi OS bookworm
handles this correctly in practice. The user audience runs the
installer once, on a Pi powered by USB or a PiSugar, in a controlled
state. Power loss during a 30-second install run is vanishingly rare.

**v1.1 fix:** Add explicit `sync -f "$dest"` before `sync
"$parent_dir"` in every staged-write-and-rename block.

### L3 — MEDIUM — Durability primitive description is technically inaccurate

**Symptom:** The design spec says `sync -f FILE` is "fsync a single
file" with a Python equivalent of `os.fsync(open(path).fileno())`. In
fact, GNU coreutils `sync -f` invokes `syncfs(2)`, which flushes the
*entire filesystem* containing the file — stronger than `fsync(2)`,
but the description is imprecise.

**Why v1 accepts it:** The actual behavior (syncfs) is at least as
strong as what the spec promises (file durability), so no
implementation is incorrect. Only the description is imprecise.

**v1.1 fix:** Rewrite the durability primitive subsection of the spec
to accurately describe each command.

### L4 — MEDIUM — `state.json` mutations are not atomic

**Symptom:** Every "set field; `sync -f` state.json" line in
`install.sh` is an in-place write. If the script (or the Pi) crashes
during the in-place write, `state.json` can be left truncated or
partially written, corrupting the recovery anchor.

**Why v1 accepts it:** `state.json` is small (<4 KB), Linux writes
sub-page blocks atomically in practice on ext4, and — importantly —
`state.json.previous` acts as a fallback identity source for uninstall
if `state.json` is corrupted during a re-install, so a corrupted
`state.json` is usually recoverable.

**v1.1 fix:** Define a "state.json mutation primitive" that does
write-to-`state.json.tmp` + `sync -f state.json.tmp` + `mv
state.json.tmp state.json` + `sync /var/lib/pwnagotchi-bcm43436b0-fix`.
Apply consistently to every state mutation.

---

If you hit any of L1-L4 in practice, please file an issue referencing
the limitation number. The patches are small and well-localized; v1.1
will address them together.
