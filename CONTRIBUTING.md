# Contributing

This doubles as the architecture tour. If you only read one section, read
[How it fits together](#how-it-fits-together).

## How it fits together

```
harness.yml.example   every setting, documented. The ONLY place thresholds live
VERSION               stamped into a consumer's harness.yml on install
install.ps1           adopt-first installer; new-project.sh calls it too
skills/               25 SKILL.md — shared verbatim by both platforms
.claude/agents/       5 agents — read natively by Cursor AND Claude Code
rules/pipeline/       10 authored always-on rules
rules/vendor/         8 third-party .NET rules, glob-scoped (see NOTICE)
hooks/                3 hook scripts + a self-test
adapters/             the only per-platform files
packs/dotnet/         gate scripts + the templates they install
speckit/              extensions.yml — the entire coupling to Spec Kit
fixtures/BadCode/     one deliberate violation per gate — the proof
```

### The three rules that shape everything

**1. A gate that could not run has not passed.**
Exit `0` = pass, `1` = fail, `2` = **SKIPPED**. Every gate checks its own
preconditions and exits 1 with remediation rather than reporting an unearned
pass. Nothing folds a 2 into a green verdict. If you add a gate, it must be able
to say "I verified nothing."

**2. A threshold lives in exactly one place.**
`harness.yml`. `install.ps1` renders it into `CodeMetricsConfig.txt`,
`stryker-config.json`, the `.editorconfig` severities, and the constitution.
Prose may quote the number, but only alongside its key — `≤ 6
(gates.complexity.refactor in harness.yml)`. CI fails if a quoted number and the
example disagree.

**3. One file, one home.**
Skills and agents live under `.claude/` because Cursor reads those paths
natively. Rules live under `.cursor/rules/` because only Cursor can auto-load
them, and `CLAUDE.md` `@import`s them from there.

The single exception is `rules/vendor/`, written to both trees — Cursor does not
read `.claude/rules/`, and the two use different frontmatter keys with different
semantics. That asymmetry is documented in `rules/vendor/README.md`.

## Adding things

**A skill** — `skills/<name>/SKILL.md`, frontmatter `name` (matching the
directory) and `description`. Route it from `skills/using-agent-skills/SKILL.md`
or nobody will find it.

**A rule** — `rules/pipeline/<name>.mdc` with `alwaysApply: true`, and add an
`@import` line to `adapters/claude/CLAUDE.md`. CI checks every import resolves.

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

One thing cannot be verified from a script, and it is load-bearing.

**Agent frontmatter carries a key each platform does not document.** Every file
in `.claude/agents/` has `readonly:` (Cursor's field) *and* `tools:` (Claude
Code's). Neither vendor documents ignoring the other's key, and Claude Code is
known to reject some malformed frontmatter outright. If either rejects it,
agents silently fail to load on that platform.

Before tagging a release, open **both** editors on a repo with the harness
installed and confirm:

1. All five agents appear in the agent list.
2. `gate-runner` and `code-reviewer` refuse to edit a file when asked.

If one platform rejects the other's key, the fallback is to split agents into
`.cursor/agents/` (`readonly` only) and `.claude/agents/` (`tools` only) in
`install.ps1`. That reintroduces a duplicated artifact, which is why it is the
fallback and not the default.

Also confirm before a release:

- `dotnet build` and `dotnet test` run clean in `fixtures/BadCode` after
  `apply-fix.ps1`
- The gate scripts run on Linux — CI is `ubuntu-latest` and the scripts are
  authored on Windows
- `CHANGELOG.md` and `VERSION` agree

## Style

- Explain **why**, not what. A comment restating the code is noise; a comment
  saying which failure a line prevents is the reason the line survives review.
- Prefer failing loudly to degrading quietly. Most bugs found while building
  this were things that silently reported success.
- No emoji in shipped files.
