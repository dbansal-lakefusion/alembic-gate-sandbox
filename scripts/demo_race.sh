#!/usr/bin/env bash
# Demonstrate the staleness race locally, with no GitHub involved.
#
# The scenario: two pull requests, each individually correct, that together
# leave the base branch with two heads.
#
#   main:    ... -> C
#   race-a:  ... -> C -> A      one head. valid.
#   race-b:  ... -> C -> B      one head. valid.
#   merged:  ... -> C -> A
#                     \-> B     TWO heads. broken.
#
# Neither pull-request check is wrong. Each tested a base that did not yet
# contain the other. This is why a required status check on its own is not
# sufficient, and why you need one of:
#
#   * "Require branches to be up to date before merging" — forces the second
#     PR to absorb the first, which re-runs its check, which then fails.
#   * A merge queue — tests each PR against the base PLUS everything ahead
#     of it in the queue, so the conflict is found before either lands.
#
# Usage: bash scripts/demo_race.sh [path-to-python]

set -uo pipefail
cd "$(dirname "$0")/.."

PY="${1:-.venv/bin/python}"
CHECK=".github/actions/check-migrations/check_heads.py"

hr() { printf '%s\n' "----------------------------------------------------------------"; }

if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: working tree is not clean — commit or stash first." >&2
  exit 1
fi

START_BRANCH="$(git branch --show-current)"
cleanup() {
  git checkout -q "$START_BRANCH" 2>/dev/null || git checkout -q main
  git branch -D demo/race-merged >/dev/null 2>&1 || true
}
trap cleanup EXIT

hr
echo "STEP 1 — build the two branches, each from the current head"
hr
bash scripts/make_scenario.sh race-a >/dev/null || exit 1
bash scripts/make_scenario.sh race-b >/dev/null || exit 1
echo "  created scenario/race-a and scenario/race-b"

hr
echo "STEP 2 — check each one ON ITS OWN (this is what CI sees per PR)"
hr
for b in race-a race-b; do
  git checkout -q "scenario/$b"
  printf '  scenario/%-8s ' "$b"
  if $PY "$CHECK" alembic.ini >/tmp/_race.txt 2>&1; then
    echo "PASS  -> $(grep -o 'single migration head.*' /tmp/_race.txt)"
  else
    echo "FAIL  <-- unexpected"; sed 's/^/      /' /tmp/_race.txt
  fi
done
echo
echo "  Both green. Both PRs are mergeable. Nothing is wrong yet."

hr
echo "STEP 3 — now merge BOTH, the way main would end up after two merges"
hr
git checkout -q main
git checkout -q -b demo/race-merged
git merge -q --no-edit scenario/race-a >/dev/null 2>&1
git merge -q --no-edit scenario/race-b >/dev/null 2>&1
echo "  merged race-a then race-b into a scratch branch"
echo
if $PY "$CHECK" alembic.ini >/tmp/_race.txt 2>&1; then
  echo "  PASS  <-- unexpected; the race did not reproduce"
  sed 's/^/      /' /tmp/_race.txt
else
  echo "  FAIL — exactly as predicted:"
  sed 's/^/      /' /tmp/_race.txt
fi

hr
echo "WHAT THIS MEANS"
hr
cat <<'EOF'
  Each PR check was correct. Merging the first did not re-run the second's
  check, so the second could merge on a stale pass — and main ends up in the
  state you just saw.

  A required status check alone does NOT close this. You need one of:

    Require branches to be up to date before merging
      The second PR must absorb the first before its merge button enables.
      That push re-runs its check, which then fails. Manual, per PR.

    A merge queue
      GitHub tests each PR against the base plus everything queued ahead of
      it, and ejects the one that breaks. Automatic, scales to N PRs.

  Note both of these are BRANCH PROTECTION settings, not workflow changes.
  The gate itself is already correct; what is missing is re-running it at
  the right moment.
EOF
