# DEV-205 — Post-merge smoke spec for `/code-review` refusal and C# paths

These two post-merge smoke runs validate DEV-113's `/code-review` C#-only
boundary on scratch consumer installs. They cannot execute inside this
harness repo (no production C#). This file is the deliverable: a runbook
with exact acceptance criteria, verifiable on any fresh `install.ps1`
target.

ADR 0022 records the deferral. Cross-reference from that ADR's Consequences
section is a separate deliverable and is not specified here.

## Hard constraints

- Scratch consumer installs only.
- **Never** `fixtures/BadCode/`. That tree is deliberately broken C# whose
  gates must exit non-zero; running these smokes against it corrupts the
  harness's own test surface.
- **Never** a real production repository.
- These smokes are post-merge validation, not automated gates inside this
  repository.

## Common setup (both smokes)

1. Create a fresh scratch directory that is **not** inside any existing
   repository, **not** `fixtures/BadCode/`, and **not** a real production
   repository.
2. Run `install.ps1 <scratch-dir>` to install the harness.
3. In that scratch directory: `git init` and make an **initial commit** of
   the installed files. Record that commit SHA. This is the fixed point.
4. Apply the smoke-specific changes described below, then **stage** them.
   Commit the staged smoke files so `HEAD` moves off the initial commit —
   otherwise `<initial-commit-SHA>...HEAD` is empty and `/code-review`
   reports **Could not run** instead of the intended path.
5. Invoke `/code-review` with the initial commit as the fixed point, using
   this exact transport (three-dot range; right endpoint is the literal
   `HEAD`):

   ```text
   Explicit diff range: <initial-commit-SHA>...HEAD
   ```

## Smoke 1 — Docs-only refusal path

**Setup (after common):** Change only `.md` / `.ps1` / `.yml` files (zero
`.cs` files). Stage and commit those files on top of the initial commit so
the three-dot range is non-empty. Classification uses that range's
extension list.

**Run:** Invoke `/code-review` with the three-dot range transport above.

**Accept when all hold:**

1. Classification fires before Step 0 loop-term fail-closed and before
   Step 2 blast-radius scoring.
2. Outcome is "out of scope for this skill" — not "Could not run", not
   "NEEDS FIXES", not a failed review.
3. Steps 0–7 are skipped: no loop-term resolution, no blast-radius scoring,
   no Step 3 Roslyn/tooling execution (`dotnet build`, `dotnet format`), no
   Step 3a pre-pass artifact creation, no Steps 4–7 fan-out. Verify from
   the run transcript that none of these steps executed. In particular:
   no `dotnet build` / `dotnet format` ran, and no Step 3a pre-pass
   artifact was created.
4. The skill names the deterministic gates that apply (consumer
   `./scripts/run-*.ps1` or harness PowerShell tests and lint grep gates).
5. Step 8 emits a findings artifact with `declined: true`, non-null
   `decline_reason`, and `findings: []`. Read the reported artifact path
   from run output and inspect the JSON file at that path (written to
   `<temp>/pr-review` or temp/scratch, outside the working tree). Do not
   treat console prose as the artifact.
6. No `/remediate` routing.
7. No generic language fallback, no prose blast-radius row.
8. Record the relevant transcript excerpt as evidence for items 1, 3, and
   5 — including a quote showing Step 3 / Step 3a did not run.

## Smoke 2 — C# path preservation

**Setup (after common):** Place a minimal buildable C# project in the
scratch directory — a single `.csproj` targeting a current TFM and one
`.cs` file. Seed a minimal `brief.md` in the pipeline feature directory
(the directory `/code-review` Step 0 resolves as `FEATURE_DIR`) with a
**closing bar**, **frozen scope**, and **round cap** so loop terms resolve.
Without `brief.md`, Step 0 fails closed and Steps 2–7 never execute,
defeating the smoke's purpose. Stage and commit a small diff that includes
at least one `.cs` change so the three-dot range is non-empty.

**Run:** Invoke `/code-review` with the three-dot range transport above.

**Accept when all hold:**

1. Classification identifies `.cs` presence and enters the C# path.
2. Step 0 loop-term resolution runs and resolves (the seeded `brief.md`
   provides the required terms).
3. Step 2 blast-radius scoring runs.
4. Step 3 attempts the `cwm-roslyn-navigator` pre-pass: the pre-pass is
   invoked; if the navigator is installed, it runs; if absent, the tooling
   line logs its absence. Either outcome is recorded. "Optional" means
   this attempt-or-log, not "skip silently".
5. Step 3 runs `dotnet build` and `dotnet format --verify-no-changes`.
6. Step 3 separates new-versus-pre-existing analyzer diagnostics. Only
   newly introduced diagnostics are review findings; pre-existing ones
   are mentioned once as context.
7. Steps 4–7 fan-out fires (three axis sub-agents or inline briefs).
8. Step 8 emits a findings artifact with `declined: false` (required, not
   absent) and `findings` as an array (empty or populated). Read the
   reported artifact path from run output and inspect the JSON file at
   that path (written to `<temp>/pr-review` or temp/scratch, outside the
   working tree). Do not treat console prose as the artifact.
9. The artifact is **not** a declined/out-of-scope artifact.

## What these smoke runs are NOT

- Not automated gates inside this repository (no C#, no consumer).
- Not part of the merge bar for DEV-113 (ADR 0022 records the deferral).
- Not a substitute for the lint-harness.yml wording checks that enforce
  DEV-113 structurally.
- Not to be run against `fixtures/BadCode/` or any real production
  repository.
