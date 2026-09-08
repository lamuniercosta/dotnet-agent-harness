# Phase 5 — Fix + regression test

Write the regression test **before the fix** — but only if there is a **correct seam** for it.

A correct seam is one where the test exercises the **real bug pattern** as it occurs at the call site. If the only available seam is too shallow (a single-caller test when the bug needs multiple callers, or a unit test against a mocked data-access interface when the bug lives in real query translation), a regression test there gives false confidence.

**If no correct seam exists, that itself is the finding.** Note it. The codebase architecture is preventing the bug from being locked down. Flag this for the next phase.

If a correct seam exists:

1. Turn the minimised repro into a failing xUnit test at that seam.
2. Watch it fail.
3. Apply the fix.
4. Watch it pass.
5. Re-run the Phase 1 feedback loop against the original (un-minimised) scenario.
6. Optionally run mutation testing scoped to the fix (`dotnet stryker --mutate "**/TheFixedFile.cs"`) to confirm the regression test actually kills mutants in the fixed code — a surviving mutant on the fixed line means the test is tautological.
