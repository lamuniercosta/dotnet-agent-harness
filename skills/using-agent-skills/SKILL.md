---
name: using-agent-skills
description: Meta-skill that discovers which skill(s) apply to the current task and governs how they are invoked. Use at the start of any non-trivial task, when unsure which skill fits, or to see how supporting skills slot into the gated pipeline.
---

# Using Agent Skills (router)

Adapted from [addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) `using-agent-skills` (MIT). Rewritten to route this harness's skill set.

## Two families of skills

1. **The gated pipeline** (feature delivery) — Spec Kit stages plus this harness's stages, with human gates. Use `/pipeline` to find the current stage. Order: `/task <issue>` (intake + branch) → `/grill-with-docs` (**mandatory** alignment) → `/speckit-specify` → `/speckit-clarify` → `/speckit-checklist` → `/speckit-plan` → `/speckit-tasks` → `/speckit-analyze` → **gate 1** → *(optional: `/gherkin` → gate 2)* → `/implement` → `/refactor` → `/architect` → **gate 3** → `/ship-review` → rebase → PR. Acceptance tests (Gherkin/Reqnroll) are **opt-in** — skip the Gherkin stage and gate 2 unless requested.
2. **Supporting skills** (non-gated) — pulled in as needed during the pipeline. This router maps tasks to them.

## Discovery decision tree

```
Task arrives
 ├─ Where am I in the pipeline? ─────────────→ /pipeline
 ├─ Starting ANY task (have an issue) ───────→ /task <issue>   (fetch issue + branch)
 ├─ Branch created, before spec/code ────────→ /grill-with-docs   (MANDATORY alignment)
 ├─ Alignment done → write the spec ─────────→ /speckit-specify
 ├─ Spec has ambiguities ────────────────────→ /speckit-clarify
 ├─ Need plan / tasks / consistency check ───→ /speckit-plan · /speckit-tasks · /speckit-analyze
 ├─ Acceptance scenarios (OPTIONAL, opt-in) ─→ /gherkin   (only if requested)
 ├─ Implementing (after gate 1, or gate 2) ──→ /implement
 │   ├─ Writing new C# ──────────────────────→ /modern-csharp
 │   ├─ New feature slice / command / query ─→ /scaffold
 │   ├─ Match project conventions ───────────→ /convention-learner
 │   ├─ Traces / metrics / spans ────────────→ /opentelemetry
 │   ├─ Retry / circuit breaker / timeouts ──→ /resilience
 │   ├─ Writing tests / coverage strategy ───→ /testing · /test-engineer
 │   └─ Verify against official docs ────────→ /grill-with-docs
 ├─ Is this change ready? ───────────────────→ /verify
 ├─ Refactor gate (CC, property tests) ─────→ /refactor
 ├─ Mutation / architect gate ───────────────→ /architect
 ├─ Something broke ─────────────────────────→ /diagnosing-bugs
 ├─ Reviewing code ──────────────────────────→ /code-review
 │   └─ Pre-PR consolidated review (gate 3) ─→ /ship-review
 ├─ Designing architecture / domain ─────────→ /codebase-design · /domain-modeling
 ├─ Broad architecture assessment ───────────→ /improve-codebase-architecture
 ├─ Performance / load / SLA ────────────────→ /k6-load-testing
 └─ Pausing / resuming later ────────────────→ /handoff
```

Every harness skill above ships on Cursor, Claude Code, and Codex. The installed
Codex copy renders explicit invocations as `$name`; Cursor and Claude Code use
`/name`. The `speckit-*` skills come from
[Spec Kit](https://github.com/github/spec-kit), not this harness, and resolve only
after the matching integration has been installed (`specify init --integration
codex` for Codex). Check before routing there.

## Agents

Four stages produce enough tool output to swamp the conversation. Delegate them rather than running inline:

| Instead of | Delegate to | Why |
|---|---|---|
| Running gate scripts inline | `gate-runner` | Returns `file:line` + cause, not raw analyzer output |
| Writing tests inline on a large change | `test-writer` | Keeps fixture/spec churn out of the main context |
| Reading Stryker's report | `mutation-analyst` | Survivor lists are long and mostly noise |
| Reviewing a whole diff | `code-reviewer` · `security-reviewer` | Independent perspectives, run in parallel |

The named profiles live in `.claude/agents/` for Cursor and Claude Code. Codex
does not load those profiles; spawn general subagents with the briefs embedded in
the calling skill, or run inline and disclose the fallback.

## Core operating behaviors (always on)

1. **Surface assumptions** before non-trivial work: list them and invite correction rather than silently guessing.
2. **Manage confusion actively.** On inconsistency: stop, name it, present the tradeoff/question, wait. ("Spec says X, code does Y — which wins?")
3. **Push back when warranted.** Not a yes-machine: state the concrete downside (quantify if possible), propose an alternative, accept an informed override.
4. **Enforce simplicity.** Prefer the boring, obvious solution; fewer lines; abstractions must earn their keep.
5. **Maintain scope discipline.** Touch only what's asked. No orthogonal cleanup, no deleting code you don't understand, no unrequested features.
6. **Verify, don't assume.** A task is done only with evidence — the gate scripts and `dotnet test` pass (see `/verify`). "Looks right" is never sufficient.

## Skill rules

1. Check for an applicable skill **before** starting work — skills encode processes that prevent mistakes.
2. Skills are workflows, not suggestions — follow steps in order; don't skip verification.
3. Multiple skills compose — a feature typically chains several (see the tree).
4. Respect the human gates — do not skip gate 1/2/3 unless the user explicitly approves.
5. When in doubt on a non-trivial task with no spec, start with `/speckit-specify`.

## How the pipeline uses this router

At the start of a task, consult this router (referenced from the `agent-pipeline` rule) to select the pipeline stage and any supporting skills, then load them. Re-consult when the task type changes — implementation → debugging → review.
