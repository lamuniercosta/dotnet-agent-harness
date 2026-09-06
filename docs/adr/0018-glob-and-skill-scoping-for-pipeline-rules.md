# Glob and skill scoping for pipeline rules

Amends [ADR 0001](./0001-codex-adapter-distills-rather-than-imports.md) — the
Codex adapter still distils, but only the three always-on rules; the remaining
eight load through skill invocation.

## Context

All eleven pipeline rules under `rules/pipeline/` shipped with
`alwaysApply: true`. Every rule loads into every turn's context on every
platform, regardless of whether the agent is editing C#, running a gate, or
writing a spec. The always-on floor is paid per turn (DEV-102, DEV-119).

Three rules genuinely need to be always-on: `agent-pipeline` (stage order),
`delegation` (cost-aware agent routing), `documentation-sources` (MCP server
routing). The other eight fire only at specific pipeline stages or when editing
specific file types — their cost is pure overhead on every other turn.

The eight: `coding-conventions`, `cyclomatic-complexity`, `roslyn-analyzers`,
`jetbrains-inspections`, `refactor-gate`, `github-workflow`,
`readme-maintenance`, `architect-gate`.

## Decision

Move the eight rules out of the always-on floor using two scoping mechanisms,
chosen by trigger pattern.

### Glob-scoped (5 rules)

Rules whose natural trigger is editing a `.cs` file auto-load via platform-
native file matching:

| Rule | Glob |
|------|------|
| `coding-conventions.mdc` | `**/*.cs` |
| `cyclomatic-complexity.mdc` | `**/*.cs` |
| `roslyn-analyzers.mdc` | `**/*.cs` |
| `jetbrains-inspections.mdc` | `**/*.cs` |
| `refactor-gate.mdc` | `**/*.cs` |

Each source file carries both `globs:` (for Cursor) and `paths:` (for Claude
Code) in its frontmatter, with `alwaysApply: false`. Both platforms ignore the
other's key. This is the pattern already established by the vendored rules
(`rules/vendor/aaron-*.md`).

`install.ps1` copies all pipeline rules with `alwaysApply: false` (eight files)
to `.claude/rules/pipeline/` in the consumer repo, parallel to the existing
`.claude/rules/vendor/` copy. The five glob-scoped rules carry `paths:` and
auto-load in Claude Code; the three skill-load rules lack `paths:` and are
present but harmless. The three always-on rules are NOT copied — they reach
Claude via the remaining `@import` lines, avoiding double-loading.

### Skill-load-path (3 rules)

Rules that fire at pipeline stage boundaries rather than file edits load only
when the relevant skill is invoked:

| Rule | Load path |
|------|-----------|
| `github-workflow.mdc` | `/task` (stage 0), `/ship-review` (stage 10) |
| `readme-maintenance.mdc` | `/implement` (stage 6), `/ship-review` (stage 10) |
| `architect-gate.mdc` | `/architect` (stage 8) |

Their frontmatter is `alwaysApply: false` with no `globs:` or `paths:`. The
skill SKILL.md files reference them explicitly so the agent reads the rule at
invocation time. On Codex — which has no glob-scoped rule auto-load — the
skill SKILL.md is the sole load path for all eight rules.

### Platform mechanics

**Cursor**: reads `globs:` natively from `.cursor/rules/`. Skill-load rules
are referenced by skill agent profiles; Cursor agents read the file when
instructed.

**Claude Code**: the eight `@import` lines are removed from `CLAUDE.md` (three
remain). Glob-scoped rules reach Claude through `.claude/rules/pipeline/` with
`paths:` frontmatter. Skill-load rules are referenced by skill SKILL.md files.

**Codex**: `AGENTS.md` retains distilled content only for the three always-on
rules (amending ADR 0001's "distils in full" model). The removed sections —
coding conventions, gates table, refactor gate, architect gate, GitHub workflow,
README maintenance — were secondary copies of content the skills already carry
inline. After removal, the skill SKILL.md becomes the sole load path.

### Consumer migration

`install.ps1` SKIPs a consumer's `CLAUDE.md` when `@import` lines already exist
(lines 519–520). Existing consumers therefore keep their eleven imports after
re-install and must manually remove the eight stale imports (or delete and
re-install their `CLAUDE.md`) to benefit from the reduced context floor. New
installs receive three imports. A future ticket may add install-time detection
of the old import block.

## Rejected alternatives

### Glob-scope all eight

`github-workflow`, `readme-maintenance`, and `architect-gate` have no natural
file-pattern trigger. Giving them broad globs (`**/*.cs` for architect-gate)
would make them quasi-always-on — loading whenever any C# file is touched,
regardless of whether the agent is in the architect stage. Workflow rules
trigger at stage boundaries, not file edits.

### Skill-load all eight

Loses the auto-load benefit for the five C# gate rules. An agent editing a
`.cs` file should automatically get the coding conventions and analyzer
procedures without invoking a skill first. Between skill invocations, the
agent would lack the gate instructions — exactly the gap the always-on design
was originally built to prevent.

### Single-file cross-platform (keep @import only)

Claude Code's `@import` is unconditional — an imported rule is always-on.
File-scoped loading on Claude requires `paths:` frontmatter in
`.claude/rules/`. The two-copy approach (`.cursor/rules/` + `.claude/rules/
pipeline/`) is the established vendor pattern and prevents drift because both
copies are overwritten on every install.

### Remove rules from Codex entirely

The distilled sections in `AGENTS.md` represent significant guidance. Removing
them without a load-path leaves Codex agents operating without gate context
between skill invocations. Skill SKILL.md files carry the essential procedures
inline, so they provide that load-path, but only the three always-on rules
remain distilled directly.

### Pinned-binding the glob patterns per rule

Each of the five C# gate rules could receive a tailored glob pattern (e.g.
`refactor-gate` only on files in `src/`). Uniform `**/*.cs` was chosen because
it is correct and simple — all five rules apply whenever any C# file is
edited. A future ticket can add finer patterns if experience shows unnecessary
loading.

## Accepted costs

1. **Two installed copies for eight rules.** `.cursor/rules/` and
   `.claude/rules/pipeline/` each carry a copy. Drift is prevented by
   construction — both are overwritten on every `install.ps1` run — but the
   "one file, one home" property that held for always-on rules no longer
   holds for these eight.

2. **Codex coverage narrows to skills.** Between skill invocations, a Codex
   agent has no gate-rule context (the skills carry the procedures but only
   when invoked). This is the gap the always-on distillation previously
   filled. It was accepted because the token savings outweigh the risk: a
   Codex agent outside a skill invocation is either at task intake (no gate
   rules needed) or doing freeform work (where gate rules are advisory, not
   enforced).

3. **Existing consumers must manually update.** `install.ps1` does not
   overwrite `CLAUDE.md` when imports exist. Existing consumers keep eleven
   imports and the full always-on floor until they manually remove the eight
   stale imports.

4. **Glob-vs-skill-load classification is a judgment call.** The 5/3 split
   was chosen conservatively — the three skill-load rules have no clean file
   trigger. A follow-up can add glob patterns to any of the three if
   experience shows they are missed between skill invocations.
