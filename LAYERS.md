# LAYERS.md

This is a plain-English description of each of the eight stability layers
applied by `patches/inplace-v7.txt`. The layers are numbered the way they
appear in the patch file's `layer` column, which matches the order they
were developed and deployed in.

Content rules for this document: no memory addresses of any kind, no
firmware-internal symbol names, no disassembly, no references to the
chip's CPU internals. We describe *what* each layer corrects and *what
symptom users see* when the layer is absent — not *where* or *how* the
underlying firmware is structured. If you want the concrete byte-level
facts, read `patches/inplace-v7.txt`; that file is the authoritative
description of the patch at the offset level.

Each layer below is one short paragraph. They are independent fixes: the
absence of any one of them is sufficient to crash the radio under the
right load, so all eight are applied together.

### Layer 1 — Watchdog thresholds

The WiFi firmware runs three internal stall detectors that reset the
radio when they think something has been hung for too long. Under heavy
monitor-mode load — especially when the injection path and the receive
path are both saturated — these detectors fire spuriously and reset a
perfectly healthy radio several times a minute. Layer 1 raises all three
thresholds from their stock "a handful of ticks" values to the maximum
the threshold field can hold, so the detectors effectively stop firing
during normal operation. **Symptom without this layer**: WiFi resets
every few seconds while the radio is busy capturing frames.

### Layer 2 — Fatal error suppression

When the firmware's internal health-reporting path decides something is
unrecoverable, its default action is to escalate the problem into a hard
radio reset and ship a crash event to the host driver. In practice,
every transient hiccup during heavy capture load walks through the same
reporting path and becomes a full reset. Layer 2 intercepts the
fatal-error reporting path and, instead of acting on it, just counts
that an error happened and returns. The three call sites that used to
invoke the fatal-error path are redirected to Layer 2's wrapper.
**Symptom without this layer**: every transient firmware hiccup becomes
a full radio reset, which in turn crashes whatever tool was holding
`wlan0mon` open.

### Layer 3 — Memory-fault recovery (primary)

Under specific rare frame patterns, the firmware's frame-handling code
hits a memory access fault. The stock firmware has no recovery path for
this — the faulting exception chains into an infinite death loop and
the radio has to be reset. Layer 3 installs a recovery routine that
notices the fault happened inside a known-safe memory-operation range,
counts the fault, resumes execution past the faulting instruction, and
lets the frame-handling code continue. The vector-table entry for the
relevant fault category is routed to this new recovery routine.
**Symptom without this layer**: the radio dies on a specific class of
incoming frames, with the tell-tale "firmware has halted" message in
the kernel log.

### Layer 4 — Bounds-checked memory operation

The firmware makes heavy use of a general-purpose memory-copy/initialise
routine that, in the stock image, has no bounds checking and no guard
against misaligned source or destination pointers. Under buffer
pressure, it occasionally walks off the end of a source buffer and
triggers the same fault category that Layer 3 catches. Layer 4 replaces
one specific call site with a bounds-checked, byte-at-a-time version so
that the common case never faults in the first place, and the failure
mode for the rare case is a clean exit instead of a fault. This is
Layer 3's sibling: Layer 4 is the pre-emptive fix, Layer 3 is the
fallback for when something else still manages to fault.
**Symptom without this layer**: occasional crashes when frame buffers
are pressured by simultaneous injection and receive.

### Layer 5 — Memory-fault recovery (secondary)

Not every memory fault routes through the same path that Layer 3
monitors; the firmware has a separate second-line fault-reporting
callback hook that receives a wider category of faults. Layer 5
installs a handler on that hook and registers it with the
fault-reporting system. It uses the same "count and skip" recovery
strategy as Layer 3, so faults that Layer 3 doesn't see are still
recovered cleanly. **Symptom without this layer**: the radio dies on a
wider set of rare frame patterns than Layer 3 alone can cover — fewer
than without Layer 3, but still enough to kill a long capture run.

### Layer 6 — Group-key rotation disable

The firmware runs a key-rotation step as part of its group-key
management. In managed-mode operation this is correct and necessary.
In monitor mode, with the radio injecting high volumes of crafted
frames, the rotation step triggers a cascade of spurious frame
reprocessing that drives the receive path into a state the firmware
cannot gracefully recover from. Layer 6 turns the rotation step into a
no-op — the radio still associates normally when you're not in
monitor mode, but the spurious cascade never starts.
**Symptom without this layer**: WiFi dies after a few minutes of
sustained monitor-mode activity, and it's very hard to reproduce in a
short test because it takes a while for the cascade to build up.

### Layer 7 — Universal fault recovery

Layers 3 and 5 cover memory-access faults specifically. The firmware
has several other fault categories — bus faults, usage faults,
maskable non-fault interrupts — that are rare enough that the stock
firmware treats them as unrecoverable. Under the kind of load this
patch set is designed for, they are no longer rare enough to ignore.
Layer 7 installs a universal recovery routine that covers the
remaining fault categories with the same count-and-skip strategy, and
reroutes every remaining fault-category vector-table entry into it.
**Symptom without this layer**: certain rare fault types still kill
the radio even with Layers 3 and 5 applied, though the mean time
between failures is much longer.

### Layer 8 — Signal-strength averaging null check

A signal-strength averaging step in the firmware's receive path
dereferences a pointer that can legitimately be null when a specific
class of frames arrives while certain internal counters are at a
specific state. The patched version of the step checks the pointer
before dereferencing it and skips the averaging step if the pointer is
null. Layer 8 was added in v7 after a specific long-duration stress
test pattern was still occasionally killing the radio with all of
Layers 1-7 applied. **Symptom without this layer**: a specific
long-running stress pattern still reliably crashes the radio, even
though the mean time to failure under normal load is much longer than
with the stock firmware.

---

If you're reading this as an auditor: everything above is **what** the
patch does, deliberately with no reference to any internal firmware
structure. The **where** and **how** are in `patches/inplace-v7.txt`
as raw offset / old bytes / new bytes tuples. The patch applier
(`scripts/install.sh`) asserts the old bytes at every offset before
writing the new bytes, so a firmware image that doesn't match the
expected pre-patch state is hard-refused.
