#!/usr/bin/env python3
"""Canonicalize a String Catalog (.xcstrings) for git.

Used as a git *clean* filter (see .gitattributes). Both Xcode and any
hand/script edit serialize .xcstrings with their own key ordering, which
produces enormous order-only diffs ("reorder noise"). This filter rewrites
the file into one deterministic order at the git boundary, so whatever order
the working file happens to be in, git always stores the same bytes — the
reorder diff becomes structurally impossible.

Reads JSON on stdin, writes canonical JSON on stdout. If the input is not
valid JSON (e.g. a merge conflict marker), it is passed through untouched so
the filter can never corrupt the file.

One-time per-clone setup (the filter command lives in .git/config, which is
not committed):

    git config filter.xcstrings.clean "python3 scripts/xcstrings-normalize.py"
"""
import json
import sys


def main() -> int:
    raw = sys.stdin.buffer.read()
    try:
        doc = json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        # Not parseable — never touch it.
        sys.stdout.buffer.write(raw)
        return 0
    # sort_keys gives a stable order at every level; separators/indent match
    # Xcode's own pretty-printing so non-reordered hunks stay readable.
    out = json.dumps(
        doc,
        ensure_ascii=False,
        sort_keys=True,
        indent=2,
        separators=(",", " : "),
    )
    sys.stdout.buffer.write(out.encode("utf-8"))
    sys.stdout.buffer.write(b"\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
