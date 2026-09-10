#!/usr/bin/env python3
"""Check C — is the revision the database recorded still present in versions/?

NOT part of the composite action: this one needs a live database, so it only
belongs at gates 3-5 (pre-deploy against a target DB, or at app startup).
Checks A and B are file-only and run everywhere.

Catches two things nothing else can:

  1. The database is at a revision that no longer exists on disk.
     This is the deleted-head case. Check A cannot see it — the remaining
     chain is genuinely valid — and Check B goes quiet once the deletion is
     in history rather than in the diff. Only alembic_version remembers.

  2. alembic_version holds MORE THAN ONE row, i.e. the database is itself
     at multiple heads. That is the fingerprint of a past
     `alembic upgrade heads`. No file-based check can detect it at all.

It parses revision ids out of the files with a regex rather than walking the
Alembic graph, deliberately: walk_revisions() raises KeyError when a middle
node is missing, and this check has to keep working in exactly that case.

Usage: check_db_revision.py <sqlalchemy-url> <versions-dir>
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

from alembic.runtime.migration import MigrationContext

REVISION_RE = re.compile(r"^revision(?:: *str)? *= *['\"]([^'\"]+)", re.M)


def ids_on_disk(versions_dir: Path) -> set[str]:
    """Every revision id present as a file. Never raises on a broken graph."""
    found = set()
    for path in versions_dir.glob("*.py"):
        m = REVISION_RE.search(path.read_text(errors="ignore"))
        if m:
            found.add(m.group(1))
    return found


def check(connection, versions_dir: Path) -> list[str]:
    """Return a list of problems; empty means healthy."""
    problems: list[str] = []
    on_disk = ids_on_disk(versions_dir)
    current = MigrationContext.configure(connection).get_current_heads()

    if not current:
        print("  no alembic_version row — fresh database, nothing applied yet")
        return problems

    print(f"  database is at: {', '.join(current)}")
    print(f"  revision files on disk: {len(on_disk)}")

    missing = [r for r in current if r not in on_disk]
    if missing:
        problems.append(
            "the database is at a revision that no longer exists in versions/: "
            + ", ".join(repr(r) for r in missing)
            + "\n    A migration this database already applied has been deleted"
              " from the repo.\n    Restore the file rather than editing alembic_version."
        )

    if len(current) > 1:
        problems.append(
            f"alembic_version holds {len(current)} rows: {', '.join(current)}"
            + "\n    This database is itself at multiple heads — the symptom of a"
              " past\n    `alembic upgrade heads`. Apply a merge revision to converge it."
        )

    return problems


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: check_db_revision.py <sqlalchemy-url> <versions-dir>", file=sys.stderr)
        return 2

    from sqlalchemy import create_engine

    url, versions_dir = sys.argv[1], Path(sys.argv[2])
    if not versions_dir.is_dir():
        print(f"::error::no such versions directory: {versions_dir}")
        return 2

    engine = create_engine(url)
    with engine.connect() as connection:
        problems = check(connection, versions_dir)

    if not problems:
        print("OK — the database's revision exists in versions/, single row")
        return 0

    for p in problems:
        print(f"::error::{p}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
