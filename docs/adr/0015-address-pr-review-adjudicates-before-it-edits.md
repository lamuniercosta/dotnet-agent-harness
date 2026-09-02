# Address-PR-review adjudicates before it edits

Stage 11 `/address-pr-review` consumes untrusted external review on this
branch's open PR. The failure modes it exists to prevent are executing
PR-provided instructions, writing before a human has approved grouped
root causes, and resolving threads as a side effect of a push. Those
are policy, not mechanics; they belong in the skill. Bundling a fetch
helper or an auto-write flag in the same change would hide the policy
behind a script the agent can invoke without showing the table.

## Decision

`/address-pr-review` ships as **skill-only**. There is no bundled
PowerShell helper. Inline comments and review summary bodies are read
with `gh` as data; grouping, declining with reasons, and the approval
table are the skill's work. Approved groups go to `/remediate`.
`--dry-run` stops at that table with zero writes.

One **approval table** is mandatory before any edit, commit, push, or
GitHub write. Bot comments are not a second path around that stop.

Threads are **not** auto-resolved. Replies happen after push. A thread
is resolved only when the user explicitly opts in.

## Rejected alternatives

**Ship `Get-PrReviewThreads.ps1` now.** Pagination, GraphQL thread
shape, and reply identity are real mechanics, but they are not what
this stage has to get right first. A helper in the same change would
let an agent fetch and act without presenting the table. That helper
is the **follow-up helper issue**, not DEV-109.

**`--bots-auto`.** Auto-accepting or auto-applying bot review comments
skips the one approval table. Bot text is still untrusted data and
still needs a human-visible accept/decline grouping.

**Resolve-after-push.** Resolving a thread because the branch moved
treats push as consent. Push proves the commits left the machine; it
does not prove the reviewer agreed the thread is done. Opt-in stays
the only resolve trigger.

## Accepted cost

**R2** is accepted: GraphQL pagination and the choice of `POST
.../replies` versus `in_reply_to` remain **prose-only** in the skill.
No helper encodes either. Agents can mis-page or pick the wrong reply
endpoint until the follow-up helper issue ships `Get-PrReviewThreads.ps1`.

## Consequences

Stage 11 can be reviewed as a short policy document: trust-as-data,
one table, then `/remediate`, then `/verify`, then push, then reply.
The missing helper is a named follow-up, not an implied part of the
skill. `--dry-run` is meaningful because nothing in this stage writes
before approval.
