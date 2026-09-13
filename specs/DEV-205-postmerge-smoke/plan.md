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
2. From the harness repo checkout (not from the scratch directory), run
   `pwsh ./install.ps1 <scratch-dir>` to install the harness.
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

   The skill name is the same across hosts: Claude/Cursor invoke
   `/code-review`; Codex invokes `$code-review`.

## Smoke 1 — Docs-only refusal path

**Setup (after common):** At the scratch root, create these files only
(zero `.cs` files): `notes/readme.md`, `tools/helper.ps1`, and
`ci/workflow.yml`. Do **not** modify the installed `skills/`, `rules/`,
`adapters/`, `hooks/`, `.claude/`, `.agents/skills/`, or `.cursor/rules/`
trees. Stage and commit those three
files on top of the initial commit so the three-dot range is non-empty.
Classification uses that range's extension list.

**Run:** Invoke `/code-review` (Codex: `$code-review`) with the three-dot
range transport above.

**Accept when all hold:**

1. Classification fires before Step 0 loop-term fail-closed and before
   Step 2 blast-radius scoring.
2. Outcome is "out of scope for this skill" — not "Could not run", not
   "NEEDS FIXES", not a failed review.
3. Steps 0–7 are skipped: no loop-term resolution, no blast-radius scoring,
   no Step 3 Roslyn/tooling execution (`dotnet build`, `dotnet format`), no
   Step 3a pre-pass artifact creation, no Steps 4–7 fan-out. Verify from
   the run transcript that none of these steps executed. In particular:
   no `dotnet build` / `dotnet format` ran.
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

### Prerequisites

- .NET SDK 10 is installed (`dotnet --version` reports a 10.x SDK that can
  build `net10.0`).
- `dotnet format` is available (`dotnet format --version`).
- The seeded C# project is format-clean before the smoke diff: `dotnet
  format --verify-no-changes` would pass on the committed seed. A later
  format failure on the smoke diff is a tooling line, not a setup error.
- `cwm-roslyn-navigator` is optional. If present it runs; if absent the
  tooling line logs its absence (see accept item 4).

**Invoked-and-recorded:** for `dotnet build` and `dotnet format
--verify-no-changes`, acceptance means the command was invoked and its
exit code is recorded in the transcript — not that the exit code was
zero. Command never invoked = smoke fail.

**Setup (after common):** Place a minimal buildable C# project in the
scratch directory — a single `.csproj` targeting `net10.0` and one `.cs`
file. A fresh consumer has no `/pipeline` task value and no `.specify/`
tree, so Step 0 cannot resolve `FEATURE_DIR` unless both of these exist:

1. Create a minimal stub at
   `.specify/scripts/powershell/check-prerequisites.ps1` that accepts
   `-Json` and writes a JSON object whose `FEATURE_DIR` property is the
   absolute path of `specs/001-smoke` under the scratch root. Example:

   ```powershell
   param([switch]$Json)
   if ($Json) {
       @{ FEATURE_DIR = (Join-Path (Get-Location) 'specs/001-smoke') } |
           ConvertTo-Json -Compress
   }
   ```

2. Place `brief.md` at that resolved path
   (`specs/001-smoke/brief.md`) with a **closing bar**, **frozen scope**,
   and **round cap** so loop terms resolve. Without this file at the JSON
   path, Step 0 fails closed and Steps 2–7 never execute, defeating the
   smoke's purpose.

Stage and commit a small diff that includes at least one `.cs` change so
the three-dot range is non-empty. The stub and `brief.md` may be in the
initial commit or in this smoke commit; they must be on disk before
`/code-review` runs.

**Run:** Invoke `/code-review` (Codex: `$code-review`) with the three-dot
range transport above.

**Accept when all hold:**

1. Classification identifies `.cs` presence and enters the C# path.
2. Step 0 loop-term resolution runs and resolves. Expected transcript
   line (evidence; **Could not run** / **NEEDS FIXES** is a smoke fail):

   ```text
   Step 0: FEATURE_DIR=specs/001-smoke via .specify/scripts/powershell/check-prerequisites.ps1 -Json; closing bar, frozen scope, and round cap resolved from specs/001-smoke/brief.md
   ```

   Transcript evidence (here and wherever else this runbook requires it) is matched substantively — step name plus resolved FEATURE_DIR plus loop terms present — not literally word-for-word.

3. Step 2 blast-radius scoring runs.
4. Step 3 attempts the `cwm-roslyn-navigator` pre-pass: the pre-pass is
   invoked; if the navigator is installed, it runs; if absent, the tooling
   line logs its absence. Either outcome is recorded. "Optional" means
   this attempt-or-log, not "skip silently".
5. Step 3 invokes `dotnet build` and `dotnet format --verify-no-changes`.
   Each command's exit code is recorded in the transcript (see
   Invoked-and-recorded above).
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
