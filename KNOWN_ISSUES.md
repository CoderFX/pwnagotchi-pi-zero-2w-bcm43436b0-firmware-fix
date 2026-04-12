# Known Issues

No known CRITICAL, HIGH, or MEDIUM issues at this time.

## Resolved in v0.1.1

The following four limitations from v0.1.0 have been fixed:

- **L1 (HIGH)** — Uninstall partial cleanup on backup file corruption.
  Full backup safety checks (regular file, not symlink, realpath, parent dir,
  size 414696, SHA match) are now performed in step 2b before any destructive
  action. A bad backup aborts the entire uninstall.

- **L2 (HIGH)** — File data not explicitly synced before directory sync.
  Every staged-write-and-rename block now calls `sync -f $file` before
  `sync $parent_dir`. Scripts, unit files, and the gcc fallback path also
  use atomic temp+rename writes.

- **L3 (MEDIUM)** — Durability primitive description inaccurate.
  Helper functions renamed from `fsync_file`/`fsync_dir` to
  `sync_file`/`sync_dir` with accurate comments explaining that `sync -f`
  invokes `syncfs(2)` (flushes the containing filesystem), which is at least
  as strong as `fsync(2)`.

- **L4 (MEDIUM)** — `state.json` mutations not atomic.
  All state.json mutations now go through a `write_state()` helper that
  writes to `state.json.tmp`, syncs, atomically renames, and syncs the
  parent directory. Temp file is cleaned up on failure and by uninstall.

Additional hardening applied during the fix cycle (found by codex review):

- Unsupported-firmware exit now routes through `die`/`abort_with_rollback`
  instead of bare `exit 1`, so paused services are properly restarted.
- Reinstall stops pre-existing `oxigotchi-*` units before rewriting files
  and reloading the driver, preventing races.
- `abort_with_rollback` restores `state.json.previous` on reinstall failure;
  on fresh install failure, keeps the `in_progress` state so uninstall can
  clean artifacts.
- Oneshot boot units are not re-executed on rollback (only long-running
  services are restarted).
- Uninstall performs a defense-in-depth sweep of all KNOWN service/script/binary
  sets, catching artifacts missed by a partial or corrupted file list.
- Uninstall firmware restore warns if wlan0 does not reappear within 15s
  instead of silently reporting success.
- `verify.sh` fails when `state.files.services` is empty or has the wrong
  count for a complete install, instead of silently passing.

---

If you encounter any issues, please file a GitHub issue with reproduction
steps and the output of `sudo ./scripts/verify.sh`.
