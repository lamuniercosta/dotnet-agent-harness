# Agent Harness

The agent harness coordinates local quality gates and reports whether each gate established a trustworthy verdict.

## Gate verdicts

**Pass**:
A gate completed its intended verification and found no blocking issue.
_Avoid_: Clean when the gate examined nothing

**Failure**:
A gate found a blocking issue or could not establish a trustworthy verdict.
_Avoid_: Error as the general verdict

**Skipped**:
A gate intentionally performed no verification because it was disabled or its requested scope matched no inputs.
_Avoid_: Pass, clean

**Could not run**:
A gate attempted verification but could not produce the evidence required for a trustworthy verdict.
_Avoid_: Skipped, pass
