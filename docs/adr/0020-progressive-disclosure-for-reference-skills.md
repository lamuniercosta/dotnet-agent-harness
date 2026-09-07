# Progressive disclosure for reference skills

Five reference skills — `k6-load-testing` (14,743 B), `resilience` (13,638 B),
`testing` (12,381 B), `opentelemetry` (10,832 B), `modern-csharp` (7,642 B) —
shipped as monolithic SKILL.md files. Every invocation loaded the full file into
context (~59 KB combined) even though the agent typically needs only the
overview and decision guide to route the user, then reads one or two topics.
We restructured each into a compact index SKILL.md (~2.5–3.5 KB each, ~15 KB
total) plus 31 companion `.md` files holding the extracted reference material,
following the companion-file distribution pattern established by `domain-modeling`
(`ADR-FORMAT.md`, `CONTEXT-FORMAT.md`) and planned for `code-review` (DEV-122).
The index + Topics routing structure — a compact SKILL.md that lists each
companion with a read instruction — is new to this change.

## Decision

### Index + topic companions

Each SKILL.md becomes an index that retains:

- **Frontmatter** (unchanged — skill discovery depends on it)
- **Intro / overview / core principles** (routing context)
- **Decision guide table** or equivalent routing table (e.g. Test Types for
  `k6-load-testing`, which has no Decision Guide)
- **Topics section** listing each companion file with a one-line description
  and a read instruction using the exact relative path:
  `Read ./topic.md in this skill's directory`

Each major section moves verbatim — no editorial changes, no reordering, no
topic deletions — into a companion file named by kebab-case topic slug. Each
companion is bare markdown with a `# Topic Name` header and no frontmatter.

### Companion file manifest

| Skill | Companions | Count |
|-------|------------|-------|
| k6-load-testing | `basics.md`, `test-config.md`, `http-testing.md`, `browser-testing.md`, `websocket-testing.md`, `data-handling.md`, `thresholds.md`, `custom-metrics.md`, `ci-cd.md`, `results.md`, `examples.md` | 11 |
| resilience | `http-resilience.md`, `non-http-pipelines.md`, `hedging.md`, `telemetry.md`, `rate-limiting.md`, `anti-patterns.md` | 6 |
| testing | `integration-tests.md`, `xunit-basics.md`, `snapshot-testing.md`, `test-data-builders.md`, `time-testing.md`, `anti-patterns.md` | 6 |
| opentelemetry | `setup.md`, `custom-metrics.md`, `tracing.md`, `logging.md`, `anti-patterns.md` | 5 |
| modern-csharp | `field-keyword.md`, `extension-members.md`, `anti-patterns.md` | 3 |

### Install and distribution

`install.ps1`'s `Copy-Tree` already copies the entire `skills/` tree —
including subdirectory contents — to both `.claude/skills/` and
`.agents/skills/`. `Convert-CodexSkillReferences` processes all `.md` files
recursively, so `/name` → `$name` adaptation covers companion files without
any install.ps1 change.

The relative read-instruction path (`./topic.md`) resolves identically at both
install destinations because the directory layout is mirrored. This is the same
mechanism that already works for `domain-modeling`'s `ADR-FORMAT.md` and
`CONTEXT-FORMAT.md`.

### Lint gate compatibility

The frontmatter gate in `lint-harness.yml` uses the glob `skills/*/SKILL.md`,
which matches only SKILL.md files. Companion files at paths like
`skills/k6-load-testing/basics.md` do not match and are not checked for
frontmatter — correctly, since they are not skills.

No lint gates in `lint-harness.yml` target any of these five skills by name or
content. No adapter template (`adapters/claude/CLAUDE.md`,
`adapters/codex/AGENTS.md`), root doc (`CLAUDE.md`, `AGENTS.md`), or other
skill references these five by content — all external references use the
`/name` invocation syntax, which is unaffected.

### Content preservation

The extractions are mechanical relocations verified at diff review. Every `##`
heading from the original SKILL.md appears in either the index or a companion
file. The `Test-InstallArtifacts.ps1` assertion enumerates all 31 companion
files by name and verifies their presence at both `.claude/skills/` and
`.agents/skills/` install paths.

No intra-skill `](#anchor)` links, `see above/below` patterns, or navigable
cross-references exist in any of the five skills (verified by grep). The sole
cross-reference is a `(see Anti-patterns)` string inside a fenced code block
in `opentelemetry`, which is a code comment — not a navigable markdown
reference — and moves with its surrounding section.

## Rejected alternatives

**Extract only the largest skills.** `modern-csharp` (7,642 B) is the smallest
of the five and arguably could stay monolithic. But applying the same pattern
uniformly is simpler than maintaining an exception, and the extraction is
mechanical — the cost of including it is negligible while the consistency
benefit is real.

**Single companion file per skill (patterns + anti-patterns).** Fewer files
but still loads reference material the agent doesn't need. The per-topic split
matches how agents actually consume these skills: they need one topic at a
time, not all patterns at once.

**Appendix structure (sections at the bottom of SKILL.md).** Keeps everything
in one file with the process skeleton first. Does not achieve progressive
disclosure — the entire file still loads into context on invocation.

**Inline collapse markers (`<details>`).** Platform-dependent, not universally
supported by all agent hosts, and the content is still in the file's byte
count.

**Extract more aggressively (principles, decision guides).** Core principles
and the decision guide are routing context — the agent needs them to decide
which companion to read. Moving them defeats the index's purpose.

**Automated hash/parity gate for content preservation.** The extractions are a
one-time mechanical operation, not a recurring process. The diff review at
merge time makes omissions visible. Adding a content-hash gate is
over-engineering for this shape of change; the 31-file install assertion
catches structural drift.

## Accepted cost

- **31 new files across 5 directories.** This is a meaningful increase in file
  count. Each skill's index lists only its own companions (3–11 files), so the
  agent never sees the full 31 — it reads one index and at most a few topics.

- **Agent must read two files instead of one.** An invocation that needs a
  specific topic now requires the index read plus one companion read. This is
  the same cost already paid by `domain-modeling` and is offset by the ~44 KB
  reduction in invocation-time context load.

- **Companion files can drift from what the index promises.** The index's
  Topics section names each companion by exact path. If a companion is renamed
  or removed without updating the index, the read instruction breaks silently.
  The install assertion catches missing files; the diff review catches index/
  companion mismatches.

- **No size-budget enforcement.** The index sizes (~2.5–3.5 KB) are
  informational targets, not gated thresholds. Context-floor measurement
  tooling is the scope of the parent epic (DEV-119), not this ticket.

- **k6 Test Types table lives only in the index.** The `k6-load-testing` index
  retains the Test Types table for routing (it has no Decision Guide).
  `test-config.md` does not duplicate it — the table was removed from the
  companion during review to eliminate drift risk.

## Consequences

- Invocation-time context load for these five skills drops from ~59 KB to
  ~15 KB — a ~44 KB reduction per invocation that touches one of them.

- The companion-file pattern is now established at scale (31 files across 5
  skills), beyond the 2-file precedent in `domain-modeling`. Future reference
  skills should follow the same pattern when they exceed a reasonable size
  threshold.

- `Test-InstallArtifacts.ps1` gains assertions for all 31 companion files,
  providing a regression gate against files being dropped from the install
  tree.

## Cross-references

- **DEV-119** (context-floor reduction epic): parent ticket. This ADR covers
  the Tier 2 reference-skill slice.
- **DEV-122** (progressive disclosure for code-review): applies the same
  companion-file pattern to a procedural skill. Separate ticket, independent
  implementation.
- **ADR 0013** (code-review gate contract travels with the skill): anticipated
  DEV-122 and noted that a size assertion would fight progressive disclosure.
  This ADR extends the same reasoning to reference skills.
- **`domain-modeling`**: the skill that established the companion-file pattern
  with `ADR-FORMAT.md` and `CONTEXT-FORMAT.md`.
