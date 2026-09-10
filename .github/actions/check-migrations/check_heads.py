#!/usr/bin/env python3
"""Check A — fail if the Alembic migration graph has more than one head.

Reads only the migration files under `script_location` via Alembic's
ScriptDirectory API. Never imports env.py, never touches a database — so
this is safe to run with no DB credentials, at any gate.

A dangling parent (Part 7's Case B — a middle node deleted without
re-pointing its children) also surfaces here, but as a bare KeyError rather
than Alembic's CommandError. That's why this catches broad Exception rather
than a narrower type: a narrower except would let that case through as an
unhandled crash instead of a clear diagnosis.

Usage: check_heads.py <path-to-alembic.ini>
"""
import sys
from pathlib import Path

from alembic.config import Config
from alembic.script import ScriptDirectory


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: check_heads.py <path-to-alembic.ini>", file=sys.stderr)
        return 2

    ini_path = Path(sys.argv[1]).resolve()
    if not ini_path.is_file():
        print(f"::error::alembic.ini not found at {ini_path}")
        return 2

    # script_location is a plain relative path, resolved against the process
    # CWD rather than the ini file's own directory — see the main doc's
    # Part 6. Match how `alembic` is normally invoked: from inside the
    # service directory.
    import os
    os.chdir(ini_path.parent)

    try:
        cfg = Config(ini_path.name)
        script = ScriptDirectory.from_config(cfg)
        heads = script.get_heads()
    except Exception as e:
        # Covers Part 7 Case B: a middle node was deleted without
        # re-pointing its children. get_heads() raises building the graph,
        # typically a bare KeyError with the useful detail only in a
        # UserWarning alongside it.
        print(f"::error::could not load the migration graph: {type(e).__name__}: {e}")
        print(
            "  A revision's down_revision likely names a migration that no "
            "longer exists — a middle node was deleted without re-pointing "
            "its children. Restore the missing file."
        )
        return 1

    if len(heads) <= 1:
        print(f"OK — single migration head: {heads[0] if heads else '(no revisions)'}")
        return 0

    print(f"::error::Multiple Alembic heads detected ({len(heads)}).")
    for h in heads:
        rev = script.get_revision(h)
        print(f"  - {h}  (down_revision={rev.down_revision!r})  {rev.doc}")
    print(
        "\nFix: cd " + str(ini_path.parent) + " && alembic merge -m \"merge heads\" "
        + " ".join(heads) + "\nthen commit the generated merge revision."
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
