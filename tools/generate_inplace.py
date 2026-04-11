#!/usr/bin/env python3
"""
generate_inplace.py — dev-only tool to re-derive patches/inplace-vN.txt from
two firmware files.

Takes two equal-sized firmware binaries (an "input" and a "patched output")
and emits a plain-text byte-diff to stdout in the inplace-vN.txt format
documented in patches/README.md.

This script is intentionally simple: it walks both files byte-by-byte in
lockstep, groups consecutive differing bytes into contiguous runs, and
emits one line per run. It does NOT know which stability layer each run
belongs to — the `layer` and `description` columns are filled in by hand
after generation.

No external dependencies. Python 3.8+.

Usage:
    python3 tools/generate_inplace.py <input.bin> <output.bin> [--name vN]

Example:
    python3 tools/generate_inplace.py \\
        /path/to/nexmon-patched.bin \\
        /path/to/oxigotchi-v7.bin \\
        --name v7 \\
        > patches/inplace-v7.txt

Then hand-annotate the `layer` and `description` columns. The first three
single-byte changes (the watchdog thresholds) are the only ones the script
can detect deterministically; everything else is a "layerX" placeholder.
"""

import argparse
import hashlib
import sys
from pathlib import Path


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def diff_runs(a: bytes, b: bytes):
    """Yield (offset, old_bytes, new_bytes) for each contiguous run of
    differing bytes."""
    if len(a) != len(b):
        raise ValueError(
            f"firmware size mismatch: input={len(a)} bytes, output={len(b)} bytes"
        )
    i = 0
    n = len(a)
    while i < n:
        if a[i] != b[i]:
            start = i
            while i < n and a[i] != b[i]:
                i += 1
            yield (start, a[start:i], b[start:i])
        else:
            i += 1


def format_line(offset: int, old: bytes, new: bytes, layer: str, desc: str) -> str:
    return (
        f"0x{offset:06X} | "
        f"{old.hex().upper()} | "
        f"{new.hex().upper()} | "
        f"{layer} | "
        f"{desc}"
    )


def classify(offset: int) -> tuple[str, str]:
    """Return a (layer, description) tuple based ONLY on the file offset.

    We deliberately do not inspect the byte contents or disassemble anything.
    Only the three single-byte watchdog thresholds at known offsets are
    auto-annotated; everything else is a placeholder that a human must fill
    in by hand before publishing.
    """
    if offset == 0x0113F4:
        return ("layer1a", "watchdog threshold A raised")
    if offset == 0x011430:
        return ("layer1b", "watchdog threshold B raised")
    if offset == 0x011460:
        return ("layer1c", "watchdog threshold C raised")
    return ("layerX", "TODO: hand-annotate layer and description")


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("input", type=Path, help="input firmware (e.g. nexmon-patched)")
    p.add_argument("output", type=Path, help="output firmware (patched target)")
    p.add_argument("--name", default="vN", help="patch set name, e.g. v7 (used in the header only)")
    args = p.parse_args(argv)

    if not args.input.is_file():
        print(f"error: input not found: {args.input}", file=sys.stderr)
        return 2
    if not args.output.is_file():
        print(f"error: output not found: {args.output}", file=sys.stderr)
        return 2

    a = args.input.read_bytes()
    b = args.output.read_bytes()

    in_sha = sha256_file(args.input)
    out_sha = sha256_file(args.output)

    print(f"# BCM43436B0 stability patch — {args.name}")
    print(f"# Source firmware: nexmon-patched brcmfmac43436-sdio.bin ({len(a)} bytes)")
    print(f"# Source SHA-256:  {in_sha}")
    print(f"# Target SHA-256:  {out_sha}")
    print("#")
    print("# Format: offset_hex | old_bytes_hex | new_bytes_hex | layer | description")
    print("# - offset_hex:    absolute byte offset in the firmware file")
    print("# - old_bytes_hex: bytes the patcher expects to find (asserted before write)")
    print("# - new_bytes_hex: bytes the patcher writes")
    print("# - layer:         which of the 8 published stability layers this belongs to")
    print("# - description:   one-line plain-English purpose (no firmware-internal symbol names)")
    print("#")

    runs = 0
    for offset, old, new in diff_runs(a, b):
        layer, desc = classify(offset)
        print(format_line(offset, old, new, layer, desc))
        runs += 1

    print(f"# ({runs} runs total)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
