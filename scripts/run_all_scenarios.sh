#!/usr/bin/env bash
# Run every scenario against both file-based checks and assert the outcome
# each one is supposed to produce. This is the Layer 1 proof: it needs no
# GitHub, no network and no database.
#
# Usage:  scripts/run_all_scenarios.sh [path-to-python]
#
# Python needs alembic installed. If you have no venv yet:
#     python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
#     scripts/run_all_scenarios.sh .venv/bin/python

set -uo pipefail
cd "$(dirname "$0")/.."

PY="${1:-python3}"
VDIR="alembic/versions"
pass_count=0
fail_count=0

# scenario | expected check A | expected check B
CASES=(
  "healthy|pass|pass"
  "two-heads|fail|pass"
  "delete-head|pass|fail"
  "delete-middle|fail|fail"
  "rename-id|pass|fail"
  "rename-cosmetic|pass|pass"
)

run_one() {
  local name="$1" want_a="$2" want_b="$3"

  bash scripts/make_scenario.sh "$name" >/dev/null 2>&1

  local got_a got_b
  $PY .github/actions/check-migrations/check_heads.py alembic.ini >/tmp/_a.txt 2>&1
  [[ $? -eq 0 ]] && got_a=pass || got_a=fail

  bash .github/actions/check-migrations/check_ids.sh "$VDIR" main >/tmp/_b.txt 2>&1
  [[ $? -eq 0 ]] && got_b=pass || got_b=fail

  local ok=1
  [[ "$got_a" == "$want_a" ]] || ok=0
  [[ "$got_b" == "$want_b" ]] || ok=0

  if (( ok )); then
    printf '  %-17s A:%-4s B:%-4s  as expected\n' "$name" "$got_a" "$got_b"
    (( pass_count++ ))
  else
    printf '  %-17s A:%-4s B:%-4s  EXPECTED A:%s B:%s\n' \
      "$name" "$got_a" "$got_b" "$want_a" "$want_b"
    echo "      --- check A output ---"; sed 's/^/      /' /tmp/_a.txt
    echo "      --- check B output ---"; sed 's/^/      /' /tmp/_b.txt
    (( fail_count++ ))
  fi
}

echo "Running all scenarios with: $PY"
echo

for c in "${CASES[@]}"; do
  IFS='|' read -r name want_a want_b <<< "$c"
  run_one "$name" "$want_a" "$want_b"
done

git checkout -q main

echo
echo "  $pass_count scenario(s) behaved as expected, $fail_count did not"
(( fail_count == 0 )) || exit 1
