# Inline comment fingerprint markers

`review-threads.json` holds raw GraphQL `reviewThread` nodes — path, line,
rendered body — not structured findings. `Get-PriorFingerprints` extracts
nothing from them; every current finding comes back as `kept`. Meanwhile
`Get-PriorCoverageGap` reads the file's `complete` flag, so pointing `-Dedupe`
at it looks wired while suppressing nothing — a silent no-op.

This ADR records how the pr-review helper embeds and recovers fingerprint
markers in inline comment bodies so that `review-threads.json` becomes a usable
`-Dedupe` prior across head changes.

## Decision

### Marker format

Each posted inline comment carries an HTML comment appended after the finding
body:

```
<!-- pr-review:fp=<sha256-hex> sfp=<sha256-hex> -->
```

`fp` is the exact fingerprint (SHA-256 of `category|file|range|substance`,
produced by `Get-FindingFingerprint`). `sfp` is the semantic fingerprint
(SHA-256 of `category|file|context|substance`, produced by
`Get-FindingSemanticFingerprint`). This parallels the existing run marker
(`<!-- pr-review:run=<hex> -->`) on the review body, but lives on the
**comment** body instead.

The marker is appended by `New-ReviewCommentFromFinding` after
`Format-InlineCommentBody` returns the rendered body. This pin point is chosen
because `Format-InlineCommentBody` has an early-return path for findings that
supply an explicit `body` field; appending inside that function
would require guarding every exit. Pinning to `New-ReviewCommentFromFinding`
guarantees the marker is present on every inline comment regardless of how the
body was composed.

Summary-only findings (PLAUSIBLE or Low-without-rule) are not inline comments
and receive no marker.

### Null and empty behaviour

A finding whose fingerprint or semantic fingerprint computes to null or empty
(e.g. missing required fields) must not emit a partial marker. If either value
is absent, no marker is appended. On the read-back side, a comment body without
a marker is silently skipped — it represents a prior comment from before this
feature, a human comment, or a summary-only entry. A skipped node suppresses
nothing; the finding comes back as new. That is the safe direction.

### Untrusted-body and spoofing guard

PR content is untrusted input (ADR 0009). `Format-InlineCommentBody` renders
`summary` and `failure_scenario` verbatim (fields listed in
`$script:VerbatimFindingFields`). The existing `Test-CarriesFenceMarker` gate
checks for Markdown code fences but not HTML comments. An attacker-controlled
finding field could embed a spoofed `<!-- pr-review:fp=... sfp=... -->` that
the read-back parser would match, allowing a forged fingerprint to enter the
prior set and suppress a genuine finding.

Mitigation: `Format-InlineCommentBody` strips exact PR-review fingerprint
markers (`<!-- pr-review:fp=<64-hex> sfp=<64-hex> -->`) from every verbatim
field and from a caller-supplied raw body before rendering. Other HTML
comments are preserved. `-Post` / `-Preflight` run the same exact-marker
strip on payload comment bodies via `Protect-ReviewCommentBody`. A
BUILD-PAYLOAD digest match keeps the helper's last-line stamp; an unverified
or hand-built payload has every exact fingerprint marker stripped, including
a valid-looking last line, so later mining cannot treat a smuggled stamp as
genuine. Ordinary non-marker HTML comments are preserved. The test suite
includes a spoofed-marker injection test: a finding whose `summary` contains a
spoofed marker must not suppress a different finding on read-back.

### Bot-author filter

GitHub review threads are visible to everyone who can read the PR, and any
participant — including the PR author — can post comments into them. A PR author
could post a comment containing a forged fingerprint marker into an existing
thread. Without filtering, `Get-PriorFingerprints` would mine that forged
marker and add it to the prior set.

Mitigation: the GraphQL query in `Get-ReviewThreads` (pr-review.ps1)
adds `author { login }` to the `comments` node. `Get-PriorFingerprints` mines
only comments whose `author.login` matches the bot account that posted the
review. All other comments in the thread are ignored for fingerprint extraction.

Identity is resolved in order, and the source is recorded on the dedupe
result as one of: `explicit-binding`, `PR_REVIEW_BOT_LOGIN`, `gh-api-user`,
or `failure`. A successful `gh-api-user` lookup is cached with that source.
Failures are not cached, so a transient lookup error cannot poison later PRs.
Precedence is re-evaluated every call: a live binding or env var still wins
over the success cache.

When mineable prior threads exist and identity cannot be resolved, or when
identity resolves but matches no thread authors while marker-bearing `[bot]`
comments are present, `-Dedupe` warns and refuses `complete: true` coverage
unless `-AllowIncompletePrior` is passed. Empty thread lists and markerless
human-only threads skip normally — that is the safe direction and is not
fail-closed.

Last-line parsing trims trailing whitespace (newline, CR, tab, spaces) before
the anchored marker regex. The anchor stays; unanchored matching is rejected.

### Exclusive threads dispatch

When `Get-PriorFingerprints` receives a prior document with a `threads` array
(the shape `-Resolve` writes), it runs the thread-mining path and skips all
other fingerprint/findings extraction paths. `review-threads.json` is not a
findings file; it has no `findings` array, no `fingerprints` map, no
`semanticFingerprints` map, and no `priorFindings` array. Attempting the
findings-array path on it would hit the `Get-FindingsArray` try/catch,
which swallows exceptions from documents that lack a
`findings`/`severity` property. The threads path runs as a separate conditional
block, independent of the findings-array dispatch, so a future refactor that
modifies the swallowing catch cannot silently drop thread mining.

A document that carries `threads` **and** `fingerprints` / `semanticFingerprints`
is hybrid and invalid/ambiguous. Exclusive dispatch must not silently drop
one shape: `Get-PriorFingerprints` rejects the hybrid rather than giving
threads precedence.

### Resolved and outdated threads

GitHub marks threads as `isResolved` or `isOutdated` when the diff region they
anchor to changes or the thread is explicitly resolved. The decision is to mine
all threads regardless of these flags, matching the semantics of the findings
file: a prior findings file does not distinguish "findings the author
addressed" from "findings still open". If a prior finding was resolved, the
current run simply will not produce a matching finding (the code was fixed), so
the stale fingerprint in the prior set harms nothing. If the code regressed, the
current finding's fingerprint will differ (different line, different substance),
so it will not be suppressed.

### ABA trade-off

A marker from run A is read back in run C, but between them run B posted the
same inline comment with the same fingerprint at a different location. The
marker does not bind to a specific head SHA, so run C cannot distinguish whether
the prior finding was raised against the same diff region or a different one.

This is accepted. The exact fingerprint encodes `category`, `file`, line range,
`side`, and normalized substance — a different location produces a different
fingerprint. Two runs that post with identical fields are, by design, the same
finding. A false-positive suppression requires an attacker who controls both the
PR content and a prior run's inline comment body, which is GitHub-stored and
immutable after posting. The semantic fingerprint uses `context` instead of
line, making it even more location-stable.

If this trade-off proves insufficient, the marker format has room for a third
field (`h=<sha-prefix>`) to pin the fingerprint to a head SHA. Adding it now
would mean a head-changed rerun cannot suppress anything — defeating the purpose
of the feature.

## Rejected alternatives

**Pinned binding.** Tie each marker to the head SHA that produced it, refusing
to honour a marker from a different head. This is the maximally conservative
option but defeats the feature: the entire point is to suppress findings across
head changes. The fingerprint already encodes enough location information to
make ABA collisions require matching on all of category, file, range, side, and
substance simultaneously. If pinned binding is needed later, a `h=` field can
be added without breaking existing markers.

**Last-match parser.** Instead of stripping fingerprint markers from verbatim
fields, take the last match of the marker pattern (since the appended marker is
always last). Weaker — a sufficiently creative injection could place a spoofed
marker after the body by exploiting multi-line fields or future format changes.
Stripping the exact marker is simpler and parallels the existing fence-gate
pattern. Trailing-whitespace normalisation is `TrimEnd` before the *anchored*
last-line regex, not an unanchored search.

**Broad HTML-comment strip.** Removing every `<!-- ... -->` from raw bodies is
lossy for nested comments and for legitimate non-marker HTML. DEV-190 narrows
stripping to the exact fingerprint-marker form; the anti-spoof guard does not
need a general HTML comment parser.

**Delimiter sentinel.** Use a unique, non-spoofable delimiter (e.g. a
NUL-prefixed marker or a sentinel line the formatter controls) to separate the
marker from the body. More complex than stripping, and the NUL approach risks
GitHub's rendering pipeline normalising or dropping the character.

**Reconstruct full findings from thread bodies.** Parse `**Sev** · cat` from
the rendered body to reconstruct a finding object, then fingerprint it.
Fragile — the body format is a rendering concern, not a contract. Fingerprints
are sufficient for dedupe; full reconstruction is unnecessary.

## Accepted cost

- Inline comments grow by one line (~90 characters). The marker is an HTML
  comment, invisible in GitHub's rendered view.
- Findings posted before this feature carry no marker. They will not suppress
  future duplicates via the threads path. The first post-migration run may
  re-raise findings that are already on the PR. Subsequent runs will suppress
  correctly.
- The bot-author filter requires knowing the bot's login at mine time, and
  that resolution is now a recorded source rather than a hidden first-result
  cache. If the bot account changes between runs, markers from the old account
  are invisible to the new one unless `PR_REVIEW_BOT_LOGIN` (or the script
  binding) names the login that actually posted. Unresolved identity and
  app-slug `[bot]` mismatch on mineable threads are coverage refusals, not
  silent no-ops. Empty or markerless-human priors stay skip-normally.
- Stripping exact fingerprint-marker comments from verbatim fields is a
  one-way transform on the rendered body. Non-marker HTML comments are
  preserved. A model that puts a fingerprint marker in a finding summary
  still loses that spoofed stamp, which is the point of the guard.

## Consequences

- `review-threads.json` becomes a first-class `-Dedupe` prior. The caveat in
  `SKILL.md` and the `NOTE` block in `Get-PriorCoverageGap`
  that thread files are not usable priors must be removed.
- The trust-boundary pattern (`VerbatimFindingFields` +
  `Test-CarriesFenceMarker`) gains an exact fingerprint-marker strip, not a
  general HTML-comment parser. `-Post` strips exact markers from payload
  comment bodies; a BUILD-PAYLOAD digest match keeps the helper last-line
  stamp, and an unverified payload loses last-line stamps too.
- Dedupe results expose `identitySource` / `identityLogin` / `identityGap` so
  an unresolved or mismatched bot login cannot hide behind `complete: true`.
- Hybrid priors (`threads` plus `fingerprints` / `semanticFingerprints`) are
  rejected as invalid/ambiguous.
- The GraphQL query in `Get-ReviewThreads` gains `author { login }`, a
  non-breaking addition that requires no schema change on GitHub's side.
- Test-PrReviewHelper baselines (`expectedHelperFunctionCount`,
  `expectedConstantsLoaded`) may need rebaselining if the implementation adds
  new functions or constants.

## Cross-references

- **ADR 0009** (review publishing is separable from review judgment): establishes
  that PR content is untrusted input. The marker-spoofing guard and bot-author
  filter are direct applications of that principle.
- **ADR 0016** (pr-review helper splits around the workspace seam): records the
  split of `pr-review.ps1` into common, workspace, and entrypoint modules. The
  marker append lives in common (`New-ReviewCommentFromFinding`); the GraphQL
  query change lives in the entrypoint (`Get-ReviewThreads`).
