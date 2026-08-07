# Codex skills use a generated `.agents/skills` copy

The harness authors each workflow once under `skills/`. Cursor and Claude Code
discover the installed `.claude/skills/` copy and invoke skills as `/name`; Codex
discovers `.agents/skills/` and invokes them as `$name`. Codex does not scan the
Claude directory, so a single installed path cannot serve all three hosts.

## Decision

For `-Platform codex|all`, the installer copies the canonical skill tree to
`.agents/skills/` and deterministically rewrites explicit Markdown invocations:

- `/name` becomes `$name` when `name` is a directory in the canonical skill tree;
- `/speckit-*` becomes `$speckit-*`, matching Spec Kit's Codex integration; and
- URL and path segments are excluded from the rewrite.

The canonical `skills/` tree and the Cursor/Claude `.claude/skills/` delivery are
never rewritten. Tests assert that every canonical skill arrives, no slash-style
harness invocation survives in the Codex copy, and repeated installation produces
the same owned skill content.

## Ownership and limitations

The harness refreshes directories whose names collide with harness skill names,
but it does not delete unrelated project skills already under `.agents/skills/`.
This matches the existing additive `Copy-Tree` policy and avoids treating the
entire project skill registry as harness-owned.

Named profiles under `.claude/agents/` are not copied. Codex can spawn general
subagents using the complete briefs embedded in the relevant skills; when that is
not appropriate or available, the skill runs the work inline and discloses the
fallback.
