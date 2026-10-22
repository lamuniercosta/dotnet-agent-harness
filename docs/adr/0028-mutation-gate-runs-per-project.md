# Mutation testing runs per project, from a config the gate generates

`dotnet stryker --since:<merge-base>` was the pipeline's mutation command. It
does not work in the layout this harness creates for itself.

## Problem

- **`--since` measures nothing from a linked git worktree.** Stryker resolves the
  filter against the main checkout, so a task worktree — created by
  `new-task-branch.ps1`, by Claude Code's agent isolation, or by hand — scores
  code that is not in the branch. The task reports a pass it did not earn, or a
  failure that belongs to another branch. This was confirmed on Stryker 4.16.0 and
  has not been re-verified on 5.x, so it stays disabled either way.
- **The score was reported without any check that the measurement happened.**
  No report, a report from the previous run, a run that tested zero mutants, and a
  run whose kills all came from one leaking test were all indistinguishable from a
  genuine pass.
- **A test that fails on every mutant inflates the score.** In a project where
  xUnit v3 tests are executables under VSTest, they run in a child process that
  never sees the active mutant, so *every* mutant survives and the gate reports 0%.
  The reverse also happens: one test that fails for environmental reasons kills
  every mutant it is linked to, and the score rises while the code is untested.

## Decision

`packs/dotnet/scripts/run-mutation.ps1` replaces `dotnet stryker --since` as the
mutation gate, and the Gherkin mutation gate stays beside it (it mutates
scenarios, not C#).

1. **Scope comes from the diff, applied through `mutate`.** The gate resolves
   `git merge-base HEAD origin/<baseBranch>`, maps each changed `.cs` file to its
   nearest ancestor project, and writes one temporary Stryker config per project
   with `since.enabled: false` and `mutate` limited to those files. A changed file
   that belongs to a test project is not production scope; a changed file in no
   project cannot produce mutants and is listed and skipped. No `src/` prefix is
   assumed — the layout comes from the project files.
2. **The tracked `stryker-config.json` is the project's own file.** The generated
   config is a copy of it with only the gate-owned keys replaced (`mutate`,
   `test-projects`, `thresholds`, `since`, `concurrency`, `additional-timeout`,
   `test-runner`). Rebuilding from a fixed key list dropped `ignore-methods` and
   `solution` and changed the score without changing the code.
3. **The runner is named, never guessed.** A repo on xUnit v3 sets
   `test-runner: mtp` with `coverage-analysis: off`; `mtp` also requires
   `additional-timeout` of at least 30000 ms, because a timeout counts as detected
   and a tight allowance turns survivors into timeouts on a busy machine. A config
   that names no runner is `GATE NOT WIRED`, not a score of zero. `install.ps1`
   renders the runner from `harness.yml gates.mutation.runner` when it is declared
   and otherwise leaves the file's own value alone.
4. **A test may not carry the run.** `gates.mutation.maxKillShare` (default 50,
   not applied below 20 tested mutants) fails the gate when one test kills more
   than that share of tested mutants, and `gates.mutation.maxKillFileSpan`
   (default 15) when one test kills mutants across more files than that. Kills
   attributed to `*.ArchitectureTests` fail outright: those tests break on the
   `Stryker.*` types injected into the assembled mutant, which is an artifact kill,
   not a signal about the code.
5. **Nothing to measure is a verdict, not a pass.** Exit 2 means `SKIPPED`
   (scope-empty) or `NOT APPLICABLE` (every changed project is listed in
   `gates.mutation.exclusions` with its reason). A changed project with no eligible
   test project and no exclusion fails the gate rather than vanishing silently.

## Consequences

- The gate is minutes-expensive and writes outside the repo (`-OutputRoot` is
  rejected inside it), so it stays a pre-PR gate rather than a per-edit one.
- `mutation-timing.json` is written next to the per-project output so wall time,
  mutant counts and the concurrency used can be tracked across runs.
- `new-mutation-receipt.ps1` turns one pushed commit's run into a committable
  receipt, including whether the test process actually loaded the mutated
  assembly.
- A repo that keeps production code outside `src/` needs no configuration; a repo
  that keeps it in a test project's directory is out of scope by construction.
