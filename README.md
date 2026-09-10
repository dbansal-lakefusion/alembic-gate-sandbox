# Alembic gate sandbox

A throwaway repo for testing a set of Alembic migration-safety gates end to
end — the CI checks, the branch protection, and the pipeline cascade — before
any of it goes near a production monorepo.

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

Branch protection is only enforced on public repos, or private ones under a
paid plan. On a free account, make the repo public — there is nothing
sensitive here.

1. Push to GitHub and let both workflows run once on `main`. A status check
   only becomes selectable in branch protection after it has reported once.
2. Add a branch protection rule for `main`. Watch the counter under the
   pattern field: it must read **"applies to 1 branch"** before you save. A
   rule matching zero branches saves happily and protects nothing.
3. Require `check-migrations`, plus *require a pull request*, *require
   branches to be up to date*, and *do not allow bypassing*.
4. Open a `two-heads` PR — the merge button should be disabled.
5. Open a `healthy` PR — it should merge.
6. Push a scenario branch and watch `pipeline.yml` cascade: the guard fails
   and every build job plus `update-manifests` shows as skipped.
7. Optionally enable a merge queue and test the two-PR race.

Note on Gate 2 (the post-merge detector): once Gate 1 is required and
bypassing is disallowed, Gate 2 can no longer be made to fire here, because
nothing broken can reach `main` any more. That is the correct outcome, not a
gap — Gate 2 exists for organisations where admins *can* bypass, and it stays
silent when they cannot.

## Reproducing a single scenario

```bash
bash scripts/make_scenario.sh two-heads
git push -u origin scenario/two-heads
git checkout main
```

Then open a PR against `main`. Available scenarios: `healthy`, `two-heads`,
`delete-head`, `delete-middle`, `rename-id`, `rename-cosmetic`.

Pushing a `scenario/**` branch also runs `pipeline.yml`, so the same push
demonstrates both the PR gate and the whole-pipeline cascade.

`make_scenario.sh` refuses to run on a dirty tree, so commit or stash first.
It also leaves the scenario branch checked out — `git checkout main` when
you're done.

## The workflows

**`.github/workflows/migration-gate.yml`** — Gates 1 and 2. One file, three
triggers: `pull_request` (blocks the merge), `merge_group` (so a merge queue
has something to run), `push` (reports a bypass after the fact). No `paths`
filter, deliberately: a path-filtered required check can never report, which
leaves a PR permanently unmergeable.

**`.github/workflows/pipeline.yml`** — Gate 3, and the point of the whole
sandbox. It mirrors a typical monorepo build-and-deploy job graph, scaled
from a dozen-odd build jobs down to 2:

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

The realistic bit is `update-manifests`: pipelines of this shape usually
already require `needs.detect-changes.result == 'success'`, so failing the
guard skips the whole deploy without editing that job at all. **One `needs:`
line blocks the entire pipeline.**

`report-status` runs the existing reporting logic *and* a fixed version side
by side, so you can see the bug: the current logic only trips on a result of
`failure`, and a skipped job leaves the flag false — so today it would post
"no failures" while the guard had blocked everything. The fixed version
checks the guard's result explicitly.

## What this sandbox does NOT cover

- **A second deploy path.** If the same migrations get packaged into more
  than one deployable artifact, every pipeline that ships them needs its own
  gate — `needs:` cannot cross workflow files, so there is no single place to
  put one check that blocks both.
- **Baselining.** A long-lived repo may already have revision ids that were
  deleted and never restored, in which case a full-history variant of Check B
  fails immediately and forever until you give it a machine-generated
  allowlist of the known-missing ids. This sandbox has clean history and needs
  none. Note the pull-request form of Check B needs no baseline at all: it
  only asks whether *this change* removes an id.
- **Database reachability from a runner**, which is what decides whether
  Check C can run as a pre-deploy gate rather than only at app startup.
