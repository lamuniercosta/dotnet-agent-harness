# Contributing

This doubles as the architecture tour. If you only read one section, read
[How it fits together](#how-it-fits-together).

## How it fits together

```
harness.yml.example   every setting, documented. The ONLY place thresholds live
VERSION               stamped into a consumer's harness.yml on install
install.ps1           adopt-first installer; new-project.sh calls it too
skills/               25 SKILL.md — canonical source for host discovery copies
.claude/agents/       7 canonical agents — rendered for all three hosts
rules/pipeline/       11 authored rules (3 always-on, 5 glob-scoped, 3 skill-load)
rules/vendor/         8 third-party .NET rules, glob-scoped (see NOTICE)
hooks/                4 hook scripts + self-tests
adapters/             the only per-platform files
packs/dotnet/         gate scripts + the templates they install
speckit/              extensions.yml — the entire coupling to Spec Kit
fixtures/BadCode/     one deliberate violation per gate — the proof
```

### The three rules that shape everything

**1. A gate that could not run has not passed.**
Exit `0` = pass, `1` = fail, `2` = **SKIPPED** or **OPT-OUT**. SKIPPED
(scope-empty) is blocking and never green; OPT-OUT (gate disabled in
harness.yml) is non-blocking SKIP. Every gate checks its own
preconditions and exits 1 with remediation rather than reporting an unearned
pass. Never fold SKIPPED, SKIP, or Could not run into a green verdict. If you
add a gate, it must be able to say "I verified nothing."

**2. A threshold lives in exactly one place.**
`harness.yml`. `install.ps1` renders it into `CodeMetricsConfig.txt`,
`stryker-config.json`, the `.editorconfig` severities, and the constitution.
Prose may quote the number, but only alongside its key — `≤ 6
(gates.complexity.refactor in harness.yml)`. CI fails if a quoted number and the
example disagree.

**3. One authored source, generated host projections.**
Skills live under `skills/`; agents live under `.claude/agents/` as their
canonical source. Installation generates the host discovery copies, including
syntax changes, without turning any installed copy into another source. Rules
are authored under `rules/pipeline/`. The three always-on rules install to
`.cursor/rules/` and `CLAUDE.md` `@import`s them from there. The eight scoped
rules also install to `.cursor/rules/`; Claude Code additionally receives them
under `.claude/rules/pipeline/` so the five C# gates auto-load via `paths:`.

Vendored rules are written to two trees because Cursor does not read
`.claude/rules/`, and the hosts use different frontmatter keys with different
semantics. That asymmetry is documented in `rules/vendor/README.md`.

## Adding things

**A skill** — `skills/<name>/SKILL.md`, frontmatter `name` (matching the
directory) and `description`. Route it from `skills/using-agent-skills/SKILL.md`
or nobody will find it.

**A rule** — `rules/pipeline/<name>.mdc`. Choose the scoping mechanism:

- Always-on (`alwaysApply: true`): only for rules that must load every turn
  (`agent-pipeline`, `delegation`, `documentation-sources`). Add an `@import`
  line to `adapters/claude/CLAUDE.md`. CI checks every import resolves. Distil
  the behavior into `adapters/codex/AGENTS.md`; Codex has no `@import`.
- Glob-scoped (`alwaysApply: false` plus `globs:` and `paths:`): C# gate
  procedures that should auto-load when matching files are touched. Do not
  `@import` them; Claude loads the copy under `.claude/rules/pipeline/`.
- Skill-load (`alwaysApply: false`, no globs/paths): procedure rules that fire
  at a stage boundary. Reference the rule from the relevant `skills/*/SKILL.md`
  so Codex and skill invocation still reach it. Do not `@import` them.

**An agent** — add one canonical `.claude/agents/<name>.md` profile with a valid
`tier`, `readonly`, and `tools` field. Do not add host copies. Extend
`install.ps1` only when a new canonical field needs host-specific projection;
`Test-InstallArtifacts.ps1` must prove all three rendered formats.

**A gate** — a script in `packs/dotnet/scripts/` that dot-sources
`_gate-common.ps1`, honours the 0/1/2 contract, reads its threshold via
`Get-HarnessValue`, and calls `Assert-GateWired` before doing any work. Then add
a violation to `fixtures/BadCode` and an assertion to its `Assert-Gates.ps1` —
**an unproven gate is not finished.**

**A config key** — add it to `$script:HarnessSchema` and `Get-HarnessDefaults`
in `_harness-config.ps1`, document it in `harness.yml.example`, and read it
somewhere. The schema is a closed allow-list and the self-test asserts the
example covers every key, so all three move together. A key nothing reads is
worse than no key: someone will set it and believe it did something.

**A vendored rule glob** — edit `globs:`, then run
`packs/dotnet/scripts/Sync-VendorRulePaths.ps1`. Never hand-write `paths:`;
Cursor and Claude glob semantics differ and a manual copy silently narrows the
rule to root-level files.

## Before you push

```bash
pwsh ./hooks/Test-Guard.ps1
pwsh ./packs/dotnet/scripts/Test-HarnessConfig.ps1
pwsh ./packs/dotnet/scripts/Test-InstallArtifacts.ps1
pwsh ./packs/dotnet/scripts/Sync-VendorRulePaths.ps1 -Check
```

Then the fixture round trip, which is the real test:

```bash
cd fixtures/BadCode
pwsh ../../install.ps1 .
pwsh ./scripts/restore-broken.ps1 && dotnet build
pwsh ./scripts/Assert-Gates.ps1 -Expect Fail
pwsh ./scripts/apply-fix.ps1 && dotnet build
pwsh ./scripts/Assert-Gates.ps1 -Expect Pass
```

Running this installs the harness into `fixtures/BadCode`, which your editor
will pick up as a second, directory-scoped copy of every skill for the rest of
the session. It is gitignored and harmless; restart the session to clear it.

## Pre-publish checklist

Generated syntax is structurally tested, but host discovery still needs a real
smoke test before tagging. Install into a throwaway repo and open Claude Code,
Cursor, and Codex. Confirm:

1. All seven agents appear in every host's agent list.
2. `gate-runner` and `code-reviewer` use the host's read-only control.
3. `edit-applier` can edit only when explicitly delegated writable work.
4. A fast agent shows the configured cheap model and low effort, while a
   balanced agent inherits.

Also confirm before a release:

- `dotnet build` and `dotnet test` run clean in `fixtures/BadCode` after
  `apply-fix.ps1`
- The gate scripts run on Linux and Windows — `self-tests` in
  `lint-harness.yml` is a `ubuntu-latest` + `windows-latest` matrix, the other
  jobs are `ubuntu-latest`, and the scripts are authored on Windows
- `README.md`'s displayed version, `CHANGELOG.md`, and `VERSION` agree

## Style

- Explain **why**, not what. A comment restating the code is noise; a comment
  saying which failure a line prevents is the reason the line survives review.
- Prefer failing loudly to degrading quietly. Most bugs found while building
  this were things that silently reported success.
- No emoji in shipped files.
