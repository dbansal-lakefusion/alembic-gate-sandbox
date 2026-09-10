#!/usr/bin/env bash
# Check B — fail if any revision id present at $BASE_REF is missing at HEAD.
#
# Covers Part 7 Case A: the head (or any revision) is deleted. The remaining
# chain is genuinely valid in that case — Check A cannot see it, because
# there is nothing wrong with the files that remain. A deletion is only
# detectable by comparison against a prior state, which is what this does.
#
# Deliberately compares revision IDS, not filenames: Alembic identifies a
# revision by the `revision = '...'` value inside the file, not by its
# filename. A cosmetic rename (filename changes, id inside doesn't) must
# pass; a rename that changes the id inside must fail, because that is
# exactly equivalent to deleting the old id.
#
# Usage: check_ids.sh <versions-dir> <base-ref>
#   <base-ref> may be empty (e.g. a branch's first push has no prior state
#   to compare against) — that is treated as nothing to check, not a failure.

set -euo pipefail

VDIR="${1:?usage: check_ids.sh <versions-dir> <base-ref>}"
BASE_REF="${2:-}"

# All-zeros is what push events report as `before` on a ref's first push —
# there is no prior commit, so there is nothing to have deleted.
if [[ -z "$BASE_REF" || "$BASE_REF" =~ ^0+$ ]]; then
  echo "OK — no base ref to compare against (first push on this branch)"
  exit 0
fi

if ! git cat-file -e "${BASE_REF}^{commit}" 2>/dev/null; then
  echo "::warning::base ref '$BASE_REF' is not a reachable commit here — skipping Check B"
  echo "  (a shallow checkout may be missing history; consider fetch-depth: 0)"
  exit 0
fi

ids() {
  git grep -hoE "^revision(: str)? *= *['\"][^'\"]+" "$1" -- "$VDIR" 2>/dev/null \
    | grep -oE "[^'\"]+$" \
    | sort -u
}

vanished="$(comm -23 <(ids "$BASE_REF") <(ids HEAD))"

if [[ -z "$vanished" ]]; then
  echo "OK — no revision id present at $BASE_REF is missing at HEAD"
  exit 0
fi

echo "::error::a migration revision id was removed between $BASE_REF and HEAD:"
while IFS= read -r id; do
  echo "  - $id"
done <<< "$vanished"
echo
echo "Migration history is append-only: once a revision has been merged,"
echo "its file is never deleted and its id never changes. To undo a"
echo "migration, add one that reverses it."
exit 1
