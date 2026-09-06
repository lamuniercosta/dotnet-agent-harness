# Progressive disclosure for the code-review skill

`skills/code-review/SKILL.md` reached 17,189 bytes — the largest skill in the
tree. Its full content loaded into the invoking agent's context on every
`/code-review` call, including ~4,000 bytes of reference material consumed
only at step 6 (smell baseline, sub-agent brief templates). That reference
was dead weight during steps 0–4 (process setup) and 7–8 (verification and
reporting), where only the process skeleton matters.

ADR-0013 anticipated this work: "DEV-122 will restructure this skill for
progressive disclosure, and a size assertion would fight that work."

## Decision

Extract reference sections from SKILL.md into companion files in the same
skill directory. SKILL.md retains the full process skeleton — every step,
every gated phrase, the severity scale, the dispatch table, and the report
contract. Four companion files carry the reference material that sub-agents
or specific steps consume on demand.

### Companion files

| File | Content | Consumer |
|------|---------|----------|
| `./smell-baseline.md` | 12 Fowler smell entries (ch. 3 of _Refactoring_) | Standards sub-agent, via `./standards-brief.md` |
| `./risk-brief.md` | Risk axis review instructions and priority order | Risk sub-agent (`code-reviewer`) |
| `./standards-brief.md` | Standards axis review instructions; reads `./smell-baseline.md` | Standards sub-agent (`code-reviewer`) |
| `./spec-brief.md` | Spec axis review instructions | Spec sub-agent (inline or delegated) |

### Per-axis direct reads

Each sub-agent reads its own axis brief directly from its companion file,
rather than the parent reading all briefs and pasting them into sub-agent
prompts. The parent dispatches with operational context (the diff command,
commit list, blast-radius table, Roslyn pre-pass results) but not brief text.

This matches the progressive disclosure grain: the Risk sub-agent never loads
the Standards or Spec brief, and vice versa. The parent's context at step 6
carries only the dispatch table and routing instructions — not the reference
material that makes each axis's review specific.

The Standards brief references `./smell-baseline.md` directly, telling the
sub-agent to read the baseline and include it in its review. This is self-
contained: the sub-agent needs no knowledge of SKILL.md's step 5 to find the
baseline.

### Fail-closed on missing companion files

Step 6 carries an explicit fail-closed instruction: if any companion file
cannot be read, stop and report — do not proceed without it. This parallels
step 0's fail-closed for missing loop terms (closing bar, frozen scope, round
cap). The Read tool returns a file-not-found error if a companion file is
missing, so the agent does not silently proceed without content.

Path references use explicit relative links (`./risk-brief.md`, not
`risk-brief.md`) for clarity. "This skill's directory" resolves to the
directory containing the SKILL.md the agent is executing — `.claude/skills/
code-review/` on Claude, `.agents/skills/code-review/` on Codex, or the
authored `skills/code-review/` in the harness tree.

### What stays inline

The process skeleton stays in SKILL.md because it is either process-integral,
shared across multiple steps, or protected by grep gates:

- **Steps 0, 1, 7, 8** carry gated phrases checked by `Test-InstallArtifacts
  .ps1` and `lint-harness.yml`. Extracting any of them would require
  redesigning the gates.
- **The severity scale** (500 bytes) is shared across steps 6, 7, and 8, and
  referenced by all three sub-agent briefs. Extraction adds three reads for
  marginal savings.
- **The report format** (step 8) contains four gated phrases (`findings
  artifact as JSON`, `Never suppress the findings`, `Above the bar go to
  /remediate`, `Below the bar`). Extraction requires gate redesign.
- **The blast-radius table and Roslyn pre-pass** are process-integral at
  steps 2–3 and carry no reference-only material.

Both the severity scale and the report format are candidates for extraction in
a future ticket if the skill grows again, but neither is justified for this
change.

### Installation and adaptation

`install.ps1`'s `Copy-Tree` copies the entire `skills/` tree — including
companion files — to `.claude/skills/` and `.agents/skills/`. No install
change is needed. `Convert-CodexSkillReferences` processes all `.md` files
recursively in each skill directory, so `/name` → `$name` adaptation covers
the companion files automatically.

Companion files are bare Markdown with no YAML frontmatter, consistent with
existing companion files (`domain-modeling/ADR-FORMAT.md`,
`improve-codebase-architecture/HTML-REPORT.md`). Frontmatter gates check only
SKILL.md.

`Test-InstallArtifacts.ps1` carries sentinel-phrase assertions for each
companion file at both install destinations (`.claude/skills/code-review/`
and `.agents/skills/code-review/`), following the existing pattern of
characteristic-phrase grep rather than file-existence checks.

## Rejected alternatives

**One combined `briefs.md` read by the parent.** The parent reads all three
briefs and pastes them into sub-agent prompts. This keeps all brief text in
the parent's context at step 6, which is the waste this change removes.
Per-axis files match the progressive disclosure grain — each sub-agent reads
only its own. This was the original plan-DEV-122 draft design, superseded
after challenger review identified that sub-agents should read their own
briefs directly.

**Extract only the smell baseline.** Saves ~2,500 bytes but leaves all three
briefs inline (~1,300 bytes of dead weight during steps 0–4 and 7–8). The
brief extraction is the same mechanical pattern applied to a second block of
reference material.

**Appendix structure (single file, sections at the bottom).** Keeps
everything in SKILL.md with the process skeleton first and reference material
as appendices. The entire file still loads into context on invocation, so
this does not achieve progressive disclosure — it changes reading order, not
context cost.

**Inline collapse markers (`<details>`).** Platform-dependent (not all hosts
render them), not universally supported in agent skill processing, and the
content is still in the file's byte count. Does not reduce context cost.

**Extract the severity scale and report format.** The severity rubric
(500 bytes) is shared across three steps; extraction adds three reads for
marginal savings. The report format contains four gated phrases checked by
`lint-harness.yml` and `Test-InstallArtifacts.ps1`; extraction requires gate
redesign. Neither is justified for a progressive-disclosure restructure.
Both are follow-up candidates if the skill grows further.

**Move briefs to individual files without changing the dispatch model.** Three
files instead of one, but the parent still reads all three and pastes them
into sub-agent prompts. More files, same context cost at step 6. The per-axis
design is only valuable when paired with direct sub-agent reads.

## Accepted cost

The skill directory grows from one file to five. Four of the five are small
(300–2,500 bytes) and follow the established companion-file pattern. The
total content is unchanged (~17,250 bytes across all files); the invocation-
time load drops to ~13,400 bytes. Each sub-agent reads one additional file
(two for Standards: its brief plus the smell baseline), which adds one tool
call per axis at step 6. The sentinel-phrase assertions in `Test-Install
Artifacts.ps1` add maintenance surface for four files instead of zero, but
follow the existing assertion pattern and catch content deletion.

## Consequences

The invocation-time context load for `/code-review` drops by ~3,800 bytes.
Steps 0–5 and 7–8 run without any brief or baseline content in context.
Each sub-agent loads only its own axis brief, so the per-axis context is
also smaller than before (each axis reads ~300–600 bytes of brief instead
of the parent holding all 1,300 bytes).

ADR-0013's observation that the skill is the largest in the tree no longer
applies at its original magnitude. A future growth event may justify
extracting the severity scale or report format, but that requires gate
redesign — not a decision for this change.

The companion-file pattern used here — bare Markdown files alongside
SKILL.md, copied by `Copy-Tree`, adapted by `Convert-CodexSkillReferences`,
validated by sentinel-phrase assertions — is reusable by any skill that
grows large enough to benefit from progressive disclosure. The extraction
criteria are: the content is reference material consumed at a specific step,
not process-integral governance; it is not shared across multiple steps; and
it does not contain gated phrases.
