# Alembic gate sandbox

A throwaway repo for testing the Alembic migration-safety gates before they
go anywhere near `lakefusion-universe`.

It contains a real three-migration Alembic chain, the checks, a composite
action, two workflows, and a script that reproduces each failure mode on
demand.

```
ef104e2e9cf3  create widgets table   (root)
      |
8835ab9cf385  add widgets.sku        (middle node — delete this for Case B)
      |
9d7d12606351  create orders table    (head — delete this for Case A)
```

## The three checks

| | What it asserts | Needs a DB? | Where it runs |
|---|---|---|---|
| **Check A** | exactly one head | no | every gate |
| **Check B** | no revision *id* has vanished | no | gates 1–4 |
| **Check C** | the DB's recorded revision still exists on disk, and `alembic_version` has one row | **yes** | gates 3–5 |

A and B are bundled in the composite action at
`.github/actions/check-migrations/`. C is standalone at
`scripts/check_db_revision.py`, because a check that needs credentials
cannot run at the pull-request gate.

**Check B compares revision ids, not filenames.** Alembic identifies a
revision by the `revision = '...'` value *inside* the file, so a cosmetic
rename is harmless while a rename that changes the id is exactly equivalent
to a deletion. The `rename-cosmetic` and `rename-id` scenarios below prove
both directions.

## Layer 1 — test the check logic locally (no GitHub needed)

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
bash scripts/run_all_scenarios.sh .venv/bin/python
```

Expected output:

```
  healthy           A:pass B:pass  as expected
  two-heads         A:fail B:pass  as expected
  delete-head       A:pass B:fail  as expected
  delete-middle     A:fail B:fail  as expected
  rename-id         A:pass B:fail  as expected
  rename-cosmetic   A:pass B:pass  as expected

  6 scenario(s) behaved as expected, 0 did not
```

The row that matters most is `delete-head`: **Check A passes it silently.**
That is the whole reason Check B exists.

### Check C, against a real database

```bash
.venv/bin/alembic upgrade head
.venv/bin/python scripts/check_db_revision.py "sqlite:///sandbox.db" alembic/versions
```

Then delete the head migration and run it again — it will name the missing
revision. To see the multiple-heads-in-the-database case:

```bash
sqlite3 sandbox.db "insert into alembic_version values ('8835ab9cf385');"
.venv/bin/python scripts/check_db_revision.py "sqlite:///sandbox.db" alembic/versions
```

## Layer 2 — test the gating on GitHub

Local tests prove the *logic*. They cannot prove the *gating* — a merge
button greying out, a merge queue re-testing PR-against-PR, an admin
bypassing a required check. Those are GitHub features and need a real repo.

See the numbered steps in the accompanying design doc, or in short:

1. Push this repo to a private GitHub repo.
2. Let the workflows run once on `main` so the check registers.
3. Add `check-migrations` as a required status check on `main`.
4. Push a `two-heads` PR and confirm the merge button is disabled.
5. Push a `healthy` PR and confirm it merges.
6. Push to `main` directly and watch Gate 2 report the bypass.
7. Optionally enable a merge queue and test the two-PR race.

## Reproducing a single scenario

```bash
bash scripts/make_scenario.sh two-heads     # creates branch scenario/two-heads
git push -u origin scenario/two-heads       # then open a PR
git checkout main                           # back to a clean tree
```

Available: `healthy`, `two-heads`, `delete-head`, `delete-middle`,
`rename-id`, `rename-cosmetic`.

## The workflows

**`.github/workflows/migration-gate.yml`** — Gates 1 and 2. One file, three
triggers: `pull_request` (blocks the merge), `merge_group` (so a merge queue
has something to run), `push` (reports a bypass after the fact). No `paths`
filter, deliberately: a path-filtered required check can never report, which
leaves a PR permanently unmergeable.

**`.github/workflows/pipeline.yml`** — Gate 3, and the point of the whole
sandbox. It mirrors the real `ci_all_service.yml` job graph, scaled from 13
build jobs to 2:

```
guard-migrations          <- the only job added
     |
detect-changes            <- needs: [guard-migrations]   (the only edit)
     |
build-service-a, build-service-b
     |
update-manifests          <- unchanged real condition
     |
report-status             <- unchanged real reporting logic
```

The real `update-manifests` already requires
`needs.detect-changes.result == 'success'`, so failing the guard skips the
whole deploy without editing it. **One `needs:` line blocks the entire
pipeline.**

`report-status` runs the existing reporting logic *and* a fixed version side
by side, so you can see the bug: the current logic only trips on a result of
`failure`, and a skipped job leaves the flag false — so today it would post
"no failures" while the guard had blocked everything. The fixed version
checks the guard's result explicitly.

## What this sandbox does NOT cover

- The Databricks path. The real repo ships the same migrations twice, and the
  second pipeline needs its own gate before `build_lakefusion_app.sh`.
- Baselining. The real repo has 11 permanently-deleted revision ids, so a
  full-history variant of Check B needs a machine-generated allowlist. This
  sandbox has clean history and needs none.
- Real database reachability from a runner, which is still an open question
  for Check C at gate 3.
