#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Deterministic helper for the /pr-review skill.

.DESCRIPTION
  Owns only mechanical PR-review operations: resolve/pin a PR, manage the
  off-repo workspace, validate findings/payloads against review-schema.json,
  fingerprint and dedupe findings, build one COMMENT review payload, post it
  via gh api, and render a Markdown fallback.

  Semantic analysis stays with the model. This script never pattern-matches
  code to invent findings.

  Verbs (exactly one per invocation):
    -Resolve [number-or-url]
    -Preflight -Payload <path>
    -Post -Payload <path>
    -NewWorkspace -Owner <o> -Repo <r> -Pr <n> -HeadSha <sha>
    -Validate -Findings <path> | -Payload <path>
    -Fingerprint -Findings <path>
    -Dedupe -Findings <path> -Prior <path> [-AllowIncompletePrior]
    -BuildPayload -Findings <path> -BaseSha <sha> -HeadSha <sha> (-BodyText <text> | -BodyFile <path>) [-Out <path>]
    -MarkdownFallback -Payload <path>
    -Ledger -State <path>
    -Help

.EXAMPLE
  pwsh ./skills/pr-review/scripts/pr-review.ps1 -Help

.EXAMPLE
  pwsh ./skills/pr-review/scripts/pr-review.ps1 -Validate -Findings $env:TEMP/findings.json
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Resolve,

    [switch]$Preflight,
    [switch]$Post,
    [switch]$NewWorkspace,
    [switch]$Validate,
    [switch]$Fingerprint,
    [switch]$Dedupe,
    [switch]$BuildPayload,
    [switch]$MarkdownFallback,
    [switch]$Ledger,
    [switch]$Help,

    # -Dedupe suppresses findings against a prior review. When the prior state
    # is known to be partial, that suppression is unsound, so it is refused
    # unless the caller says out loud that a partial prior is acceptable.
    [switch]$AllowIncompletePrior,

    [string]$Payload,
    [string]$Findings,
    [string]$Prior,
    [string]$Owner,
    [string]$Repo,
    [int]$Pr,
    [string]$HeadSha,
    [string]$BaseSha,

    # Body text and body file are deliberately separate. A single -Body that read
    # its value as a file whenever that value happened to name one turned review
    # prose into a local-file read primitive.
    [string]$BodyText,
    [string]$BodyFile,

    # -BuildPayload destination. Writing the payload here rather than piping
    # stdout is what lets a provenance sidecar be written beside it.
    [string]$Out,

    # State document for the -Ledger pure decision verb.
    [string]$State,

    # Optional guard: -Post refuses a payload whose workspace belongs to a
    # different run.
    [string]$RunId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Load order is a contract. Workspace helpers depend on constants and functions
# defined in common; reversing these two lines produces undefined-variable
# bindings at runtime while AST-replayed tests can still pass. See ADR 0016.
. (Join-Path $PSScriptRoot '_pr-review-common.ps1')
. (Join-Path $PSScriptRoot '_pr-review-workspace.ps1')

# gh is given a bounded wall-clock budget. Without one, a stuck proxy, an
# interactive auth prompt, or a hung TLS handshake parks -Resolve or -Post
# forever with a half-prepared workspace, and the Markdown-fallback path that
# exists for exactly that failure is never reached. Override for a slow link
# with PRREVIEW_GH_TIMEOUT_SECONDS.
$script:GhTimeoutSeconds = 120

# How long a -Post waits for another -Post on the same run to release the lock
# before giving up. Long enough to outlast a normal publish, short enough that a
# genuinely abandoned lock does not hang a session. Override with
# PRREVIEW_POST_LOCK_TIMEOUT_SECONDS.
$script:PostLockTimeoutSeconds = 60

# GitHub's compare endpoint carries `files` on the first page only and caps that
# list at 300 entries, whatever the PR's real size.
$script:CompareFileCap = 300

function Show-Usage {
    @'
pr-review.ps1 — deterministic helper for /pr-review

USAGE (exactly one verb):
  -Help
  -Resolve [<number-or-url>]
  -Preflight -Payload <path> [-RunId <id>]
  -Post -Payload <path> [-RunId <id>]
  -NewWorkspace -Owner <o> -Repo <r> -Pr <n> -HeadSha <sha>
  -Validate (-Findings <path> | -Payload <path>)
  -Fingerprint -Findings <path>
  -Dedupe -Findings <path> -Prior <path> [-AllowIncompletePrior]
  -BuildPayload -Findings <path> -BaseSha <sha> -HeadSha <sha> (-BodyText <text> | -BodyFile <path>) [-Out <path>]
  -MarkdownFallback -Payload <path>
  -Ledger -State <path>

NOTES
  - Requires PowerShell 7+ and (for -Resolve/-Preflight/-Post) an authenticated
    gh CLI. There is no connector fallback: every publication guarantee lives in
    this script, so a second path would have to reimplement all of them.
  - -Preflight is the --dry-run path. It runs every pre-publication check -Post
    runs — schema, canonical workspace, run-id binding, closing base/head re-read,
    run-marker reconciliation, diff-location validation — writes review.json and
    review.md, and stops. It reads from the API and writes nothing to GitHub.
  - Each -Resolve mints a run id and owns one run directory:
      <temp>/pr-review/<owner>-<repo>/<pr>-<headsha>/runs/<runid>/
    Pinned state, the outgoing payload, and the receipt live there, so
    concurrent runs over one head cannot overwrite each other.
  - -BodyText is used verbatim and is never probed as a path. -BodyFile is read
    only from inside the workspace root this script owns; with -Out it must sit
    in the payload's own directory.
  - Exit 0 on success; non-zero on failure. Offline verbs do no network I/O.
'@ | Write-Output
}

function Test-ResolveRequested {
    <#
      -Resolve may be bound as an empty string (current-branch resolution), so
      presence has to be tested rather than truthiness.

      The script's bound parameters must be passed in: inside a function,
      $PSBoundParameters is that function's own binding, which is always empty
      here — reading it directly made every `-Resolve` invocation fail with
      "No verb specified".
    #>
    param([Parameter(Mandatory)]$BoundParameters)
    return $BoundParameters.ContainsKey('Resolve')
}

function Assert-GhPresent {
    if (-not (Get-GhCommandPath)) {
        throw 'gh CLI not found. Install https://cli.github.com and run: gh auth login'
    }
}

function Get-GhCommandPath {
    <#
      Resolve gh to a concrete executable once. The bounded-timeout runner below
      starts it through System.Diagnostics.Process rather than the call
      operator, and that needs a path rather than a command name.
    #>
    $cmd = Get-Command gh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $cmd) { return $null }
    return [string]$cmd.Source
}

function Get-GhTimeoutSeconds {
    $configured = [System.Environment]::GetEnvironmentVariable('PRREVIEW_GH_TIMEOUT_SECONDS')
    if ([string]::IsNullOrWhiteSpace($configured)) { return $script:GhTimeoutSeconds }
    $parsed = 0
    if (-not [int]::TryParse($configured.Trim(), [ref]$parsed) -or $parsed -le 0) {
        throw "PRREVIEW_GH_TIMEOUT_SECONDS must be a positive whole number of seconds; got '$configured'."
    }
    return $parsed
}

function Get-PostLockTimeoutSeconds {
    $configured = [System.Environment]::GetEnvironmentVariable('PRREVIEW_POST_LOCK_TIMEOUT_SECONDS')
    if ([string]::IsNullOrWhiteSpace($configured)) { return $script:PostLockTimeoutSeconds }
    $parsed = 0
    if (-not [int]::TryParse($configured.Trim(), [ref]$parsed) -or $parsed -le 0) {
        throw "PRREVIEW_POST_LOCK_TIMEOUT_SECONDS must be a positive whole number of seconds; got '$configured'."
    }
    return $parsed
}

function Invoke-Gh {
    <#
      Run gh under a bounded wall clock, capture merged stdout/stderr, assert
      exit 0, return the text.

      The call operator has no timeout, and every verb here is a network call:
      a stuck proxy, a hung TLS handshake, or a gh build that decides to prompt
      for credentials parks -Resolve or -Post indefinitely, holding a
      half-prepared workspace open and never reaching the Markdown fallback
      that exists for exactly that failure. Process gives a wall clock and a
      tree kill; the call operator gives neither.

      Two details are load-bearing. stdin is closed immediately, so a gh that
      tries to prompt reads EOF and exits rather than waiting out the whole
      budget. And stderr is placed *before* stdout in the merged text: the JSON
      parsers downstream anchor on a document at the end of the stream, so a
      deprecation notice arriving after the payload would otherwise make a
      successful call unparseable.
    #>
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string[]]$GhArgs,
        [switch]$AllowFailure
    )

    $exe = Get-GhCommandPath
    if (-not $exe) {
        throw 'gh CLI not found. Install https://cli.github.com and run: gh auth login'
    }

    $timeoutSeconds = Get-GhTimeoutSeconds
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $exe
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($a in $GhArgs) { [void]$psi.ArgumentList.Add([string]$a) }

    $proc = $null
    $timedOut = $false
    $stdoutText = ''
    $stderrText = ''
    # Captured inside the try: ExitCode is not readable once the Process is
    # disposed, and the finally below disposes it.
    $exitCode = 0
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        try { $proc.StandardInput.Close() } catch { }

        # Read both pipes concurrently. Draining one to completion first
        # deadlocks as soon as the other fills its buffer, which a large
        # paginated response does routinely.
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()

        if (-not $proc.WaitForExit($timeoutSeconds * 1000)) {
            $timedOut = $true
            # Kill the tree: on Windows gh may be reached through a shim that
            # is itself the direct child, and killing only that leaves the real
            # process holding the pipes open.
            try { $proc.Kill($true) } catch { }
            [void]$proc.WaitForExit(5000)
        }

        [void][System.Threading.Tasks.Task]::WaitAll(@($outTask, $errTask), 5000)
        if ($outTask.IsCompletedSuccessfully) { $stdoutText = [string]$outTask.Result }
        if ($errTask.IsCompletedSuccessfully) { $stderrText = [string]$errTask.Result }

        # 124 is what timeout(1) reports, and it keeps a killed run
        # distinguishable from a gh that genuinely exited non-zero.
        $exitCode = if ($timedOut) { 124 } else { $proc.ExitCode }
    }
    finally {
        if ($null -ne $proc) { $proc.Dispose() }
    }

    $output = ($stderrText + $stdoutText)
    if ($timedOut) {
        $output = ("gh timed out after ${timeoutSeconds}s while $Action and was terminated. " +
            "Set PRREVIEW_GH_TIMEOUT_SECONDS to raise the budget.`n" + $output)
    }

    if (-not $AllowFailure -and $exitCode -ne 0) {
        $detail = if ([string]::IsNullOrWhiteSpace($output)) { '(no output)' } else { $output.Trim() }
        throw "gh failed while $Action (exit $exitCode): $detail"
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Text     = $output
    }
}

function ConvertFrom-GhJson {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Action
    )

    $jsonText = $Text
    if ($Text -match '(?s)(\[.*\]|\{.*\})\s*$') {
        $jsonText = $Matches[1]
    }

    try {
        return $jsonText | ConvertFrom-Json -Depth 100
    }
    catch {
        throw "Failed to parse gh JSON while $Action`: $($_.Exception.Message)`nRaw: $($Text.Trim())"
    }
}

function Split-JsonDocuments {
    <#
      `gh api --paginate` emits one complete JSON document per page, so a PR that
      crosses a page boundary produces `[...]\n[...]` — not parseable as a single
      document. Split the stream back into top-level documents. String- and
      escape-aware so brackets inside string values do not move the depth.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $docs = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($Text)) { return $docs }

    $depth = 0
    $inString = $false
    $escaped = $false
    $start = -1

    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = [string]$Text[$i]

        if ($inString) {
            if ($escaped) { $escaped = $false }
            elseif ($ch -eq '\') { $escaped = $true }
            elseif ($ch -eq '"') { $inString = $false }
            continue
        }

        if ($ch -eq '"') { $inString = $true; continue }

        if ($ch -eq '[' -or $ch -eq '{') {
            if ($depth -eq 0) { $start = $i }
            $depth++
            continue
        }

        if ($ch -eq ']' -or $ch -eq '}') {
            if ($depth -gt 0) { $depth-- }
            if ($depth -eq 0 -and $start -ge 0) {
                $docs.Add($Text.Substring($start, $i - $start + 1))
                $start = -1
            }
        }
    }

    if ($depth -ne 0) {
        throw "Unbalanced JSON in gh output (truncated response?)."
    }

    return $docs
}

function Invoke-GhPaginated {
    <#
      Run a paginated `gh api` call and return every page parsed, plus the pages
      flattened into one item list. Callers that need per-page envelopes (such as
      check-runs, which wraps its array in an object) read .Pages; callers over a
      plain array endpoint read .Items.
    #>
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowFailure
    )

    $result = Invoke-Gh -Action $Action -GhArgs @('api', $Path, '--paginate') -AllowFailure:$AllowFailure

    $pages = [System.Collections.Generic.List[object]]::new()
    if ($result.ExitCode -eq 0) {
        foreach ($doc in (Split-JsonDocuments -Text $result.Text)) {
            $pages.Add((ConvertFrom-GhJson -Text $doc -Action $Action))
        }
    }

    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($page in $pages) {
        foreach ($item in @($page)) {
            if ($null -ne $item) { $items.Add($item) }
        }
    }

    return [pscustomobject]@{
        ExitCode = $result.ExitCode
        Text     = $result.Text
        Pages    = $pages.ToArray()
        Items    = $items.ToArray()
    }
}

function Parse-PrTarget {
    param([string]$Target)

    $owner = $null
    $repo = $null
    $number = $null

    if ([string]::IsNullOrWhiteSpace($Target)) {
        Assert-GhPresent
        $raw = Invoke-Gh -Action 'resolving PR for current branch' -GhArgs @(
            'pr', 'view', '--json', 'number,url,baseRefName,headRefName'
        )
        $pr = ConvertFrom-GhJson -Text $raw.Text -Action 'parsing current-branch PR'
        $number = [int]$pr.number
        $repoRaw = Invoke-Gh -Action 'resolving current repository' -GhArgs @(
            'repo', 'view', '--json', 'nameWithOwner', '-q', '.nameWithOwner'
        )
        $full = $repoRaw.Text.Trim()
        if ($full -notmatch '^([^/]+)/([^/]+)$') {
            throw "Unexpected repo nameWithOwner: $full"
        }
        $owner = $Matches[1]
        $repo = $Matches[2]
        return [pscustomobject]@{ Owner = $owner; Repo = $repo; Number = $number }
    }

    if ($Target -match '^(?:https://)?(?:www\.)?github\.com/([^/]+)/([^/]+)/pull/([0-9]+)') {
        return [pscustomobject]@{
            Owner  = $Matches[1]
            Repo   = $Matches[2]
            Number = [int]$Matches[3]
        }
    }

    if ($Target -match '^[0-9]+$') {
        Assert-GhPresent
        $repoRaw = Invoke-Gh -Action 'resolving current repository' -GhArgs @(
            'repo', 'view', '--json', 'nameWithOwner', '-q', '.nameWithOwner'
        )
        $full = $repoRaw.Text.Trim()
        if ($full -notmatch '^([^/]+)/([^/]+)$') {
            throw "Unexpected repo nameWithOwner: $full"
        }
        return [pscustomobject]@{
            Owner  = $Matches[1]
            Repo   = $Matches[2]
            Number = [int]$Target
        }
    }

    throw "Unrecognized -Resolve target (expected integer, GitHub PR URL, or empty): $Target"
}

function Merge-CheckRunPages {
    <#
      The check-runs endpoint wraps its array in an envelope, so paginating it
      yields one `{ total_count, check_runs }` object per page. Merge them into a
      single envelope with the true total.
    #>
    param([object[]]$Pages)

    $runs = [System.Collections.Generic.List[object]]::new()
    foreach ($page in @($Pages)) {
        if ($null -eq $page) { continue }
        if (-not (Test-HasProperty -Object $page -Name 'check_runs')) { continue }
        foreach ($run in @((Get-PropertyValue -Object $page -Name 'check_runs'))) {
            if ($null -ne $run) { $runs.Add($run) }
        }
    }

    return [pscustomobject]@{
        total_count = $runs.Count
        check_runs  = $runs.ToArray()
    }
}

function Get-ReviewThreads {
    <#
      Cursor-page every review thread. Coverage that stopped short is reported
      rather than silently truncated: dedupe treats "no prior thread" as "new
      finding", so a quietly capped fetch reposts comments that already exist.

      Returns { threads, complete, incompleteReason, truncatedThreads, pagesFetched }.
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$Number,
        [int]$MaxPages = 20
    )

    $query = @'
query($owner:String!, $repo:String!, $number:Int!, $cursor:String) {
  repository(owner:$owner, name:$repo) {
    pullRequest(number:$number) {
      reviewThreads(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          isResolved
          isOutdated
          comments(first: 100) {
            totalCount
            pageInfo { hasNextPage }
            nodes {
              id
              databaseId
              body
              path
              diffHunk
              originalCommit { oid }
              commit { oid }
            }
          }
        }
      }
    }
  }
}
'@

    $nodes = [System.Collections.Generic.List[object]]::new()
    $truncated = [System.Collections.Generic.List[string]]::new()
    $complete = $true
    $reason = $null
    $cursor = $null
    $pagesFetched = 0

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("pr-review-threads-{0}.graphql" -f [guid]::NewGuid().ToString('n'))
    try {
        Set-Content -LiteralPath $tmp -Value $query -Encoding utf8

        while ($true) {
            $ghArgs = @(
                'api', 'graphql',
                '-f', "owner=$Owner",
                '-f', "repo=$Repo",
                '-F', "number=$Number",
                '-F', "query=@$tmp"
            )
            if (-not [string]::IsNullOrEmpty($cursor)) { $ghArgs += @('-f', "cursor=$cursor") }

            $raw = Invoke-Gh -Action 'fetching review threads' -GhArgs $ghArgs -AllowFailure
            if ($raw.ExitCode -ne 0) {
                Write-Warning "Could not fetch review threads (continuing without them): $($raw.Text.Trim())"
                $complete = $false
                $reason = "GraphQL request failed: $($raw.Text.Trim())"
                break
            }

            $root = $null
            # Invoke-Gh merges gh's stderr into stdout (:292), so a deprecation
            # or auth warning line can sit in front of the JSON body. A raw
            # ConvertFrom-Json chokes on that prefix and drops the whole thread
            # page as "no data"; route through ConvertFrom-GhJson, which strips a
            # leading warning line before parsing. A genuinely malformed body
            # still throws here and degrades gracefully via the null branch below.
            try { $root = ConvertFrom-GhJson -Text $raw.Text -Action 'parsing review threads' }
            catch { $root = $null }

            if (Test-HasProperty -Object $root -Name 'errors') {
                $errs = Get-PropertyValue -Object $root -Name 'errors'
                if ($null -ne $errs -and @($errs).Count -gt 0) {
                    $complete = $false
                    $msgs = [System.Collections.Generic.List[string]]::new()
                    foreach ($e in @($errs)) {
                        # Parenthesise the first operand: an unparenthesised
                        # `cmd -a x -and ...` binds `-and` as an argument to the
                        # command instead of composing a boolean, silently
                        # dropping the null guard.
                        $msg = Get-PropertyValue -Object $e -Name 'message'
                        if (-not [string]::IsNullOrWhiteSpace([string]$msg)) {
                            $msgs.Add([string]$msg)
                        }
                        else {
                            $msgs.Add([string]$e)
                        }
                    }
                    $errText = ($msgs -join '; ')
                    if ([string]::IsNullOrEmpty($reason)) {
                        $reason = $errText
                    } else {
                        $reason += "; $errText"
                    }
                }
            }

            $rt = $null
            try {
                if ($null -ne $root -and (Test-HasProperty -Object $root -Name 'data')) {
                    $rt = $root.data.repository.pullRequest.reviewThreads
                }
            }
            catch { $rt = $null }

            if ($null -eq $rt) {
                Write-Warning 'Review threads response contained no thread data (continuing without them).'
                $complete = $false
                $noData = 'GraphQL response contained no reviewThreads data'
                if ([string]::IsNullOrEmpty($reason)) {
                    $reason = $noData
                } else {
                    $reason += "; $noData"
                }
                break
            }

            foreach ($node in @($rt.nodes)) {
                if ($null -eq $node) { continue }
                $nodes.Add($node)
                $moreComments = $false
                try { $moreComments = [bool]$node.comments.pageInfo.hasNextPage } catch { $moreComments = $false }
                if ($moreComments) { $truncated.Add([string]$node.id) }
            }
            $pagesFetched++

            $hasNext = $false
            try { $hasNext = [bool]$rt.pageInfo.hasNextPage } catch { $hasNext = $false }
            if (-not $hasNext) { break }

            if ($pagesFetched -ge $MaxPages) {
                $complete = $false
                $reason = "Stopped after $MaxPages pages of review threads; later threads were not fetched."
                break
            }
            $cursor = [string]$rt.pageInfo.endCursor
        }
    }
    finally {
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    }

    if ($truncated.Count -gt 0) {
        $complete = $false
        if ([string]::IsNullOrEmpty($reason)) {
            $reason = "$($truncated.Count) thread(s) hold more than 100 comments; the later comments were not fetched."
        }
    }

    return [pscustomobject]@{
        threads          = $nodes.ToArray()
        complete         = $complete
        incompleteReason = $reason
        truncatedThreads = $truncated.ToArray()
        pagesFetched     = $pagesFetched
    }
}

function Invoke-Resolve {
    param([string]$Target)

    Assert-GhPresent
    # Not $target: PowerShell variable names are case-insensitive, so assigning
    # here would land back in the [string]-typed $Target parameter and stringify
    # the parsed object.
    $parsed = Parse-PrTarget -Target $Target
    $owner = $parsed.Owner
    $repo = $parsed.Repo
    $number = $parsed.Number
    $apiBase = "repos/$owner/$repo"

    $prRaw = Invoke-Gh -Action "fetching PR #$number" -GhArgs @(
        'api', "$apiBase/pulls/$number"
    )
    $pr = ConvertFrom-GhJson -Text $prRaw.Text -Action "parsing PR #$number"

    $baseSha = [string]$pr.base.sha
    $headSha = [string]$pr.head.sha
    $baseRef = [string]$pr.base.ref
    $headRef = [string]$pr.head.ref

    # The diff itself comes from the SHA-addressed compare endpoint, with the
    # same pinned-tree proof the post path uses before it will trust the mutable
    # /pulls/<n>/files fallback. The closing pair re-read below cannot substitute
    # for this: an author controls the branch, so pushing a decoy and force-
    # pushing back before that check is cheap, and it would leave a B-shaped file
    # list under a pair that still reads as A. Publication would stay safe — it
    # re-derives placements from the pin — but every review pass reasons from
    # this evidence, so the review itself would be about the wrong diff.
    $expectedFileCount = 0
    if (Test-HasProperty -Object $pr -Name 'changed_files') {
        $expectedFileCount = [int](Get-PropertyValue -Object $pr -Name 'changed_files')
    }
    $resolvedFiles = Get-PinnedDiffFiles -Owner $owner -Repo $repo -Number $number `
        -BaseSha $baseSha -HeadSha $headSha -ExpectedFileCount $expectedFileCount
    $files = @($resolvedFiles.Files)

    $commits = @((Invoke-GhPaginated -Action 'fetching commits' -Path "$apiBase/pulls/$number/commits").Items)
    $reviews = @((Invoke-GhPaginated -Action 'fetching reviews' -Path "$apiBase/pulls/$number/reviews").Items)

    # Review threads (GraphQL) — resolved/unresolved state for incremental dedupe.
    # Cursor-paged: a busy PR has more than one page of threads, and silently
    # keeping the first 100 would make dedupe repost findings already commented on.
    $threads = Get-ReviewThreads -Owner $owner -Repo $repo -Number $number

    $ciResult = Invoke-GhPaginated -Action 'fetching check status' -Path "$apiBase/commits/$headSha/check-runs" -AllowFailure
    $ci = $null
    if ($ciResult.ExitCode -eq 0) {
        $ci = Merge-CheckRunPages -Pages $ciResult.Pages
    }
    else {
        # Fallback: combined status
        $statusRaw = Invoke-Gh -Action 'fetching combined status' -GhArgs @(
            'api', "$apiBase/commits/$headSha/status"
        ) -AllowFailure
        if ($statusRaw.ExitCode -eq 0) {
            $ci = ConvertFrom-GhJson -Text $statusRaw.Text -Action 'parsing combined status'
        }
        else {
            Write-Warning 'Could not fetch CI/check state; continuing without it.'
            $ci = [pscustomobject]@{ warning = 'CI state unavailable' }
        }
    }

    # Everything above is six paginated reads of mutable state taken one after
    # another. A push — or a push and a revert — during that window leaves files
    # from one diff beside commits, reviews and checks from another, under a
    # pinned.json that looks perfectly valid; nothing downstream can tell. Close
    # the gather by re-reading the pair and abort if either moved, matching what
    # publication does. Aborting rather than recording partial coverage is
    # deliberate: this evidence is what every later pass reasons from, and a
    # resolve is cheap to redo. It runs before the workspace exists, so a run
    # that fails here leaves nothing half-written behind.
    [void](Assert-PinnedPair -Owner $owner -Repo $repo -Number $number `
            -PinnedBase $baseSha -PinnedHead $headSha -PayloadHead $headSha `
            -Stage 'trust the gathered evidence')

    $headWorkspace = New-OrGetWorkspace -Owner $owner -Repo $repo -Pr $number -HeadSha $headSha

    # Each explicit -Resolve mints a run id and owns a directory named by it. The
    # receipt lives there, so retrying one run stays idempotent while a
    # deliberate re-review of an unchanged head still publishes its own summary —
    # and two concurrent runs over one head cannot overwrite each other's state.
    $runId = [guid]::NewGuid().ToString('n').Substring(0, 12)
    $identity = New-PrReviewIdentity -Owner $owner -Repo $repo -Number $number `
        -HeadSha $headSha -BaseSha $baseSha -RunId $runId
    $workspace = New-RunWorkspace -Workspace $headWorkspace -RunId $identity.RunId

    $pinned = [pscustomobject]@{
        owner     = $identity.Owner
        repo      = $identity.Repo
        pr        = $identity.Number
        runId     = $identity.RunId
        baseSha   = $identity.BaseSha
        headSha   = $identity.HeadSha
        baseRef   = $baseRef
        headRef   = $headRef
        title     = [string]$pr.title
        htmlUrl   = [string]$pr.html_url
        resolvedAt = (Get-Date).ToUniversalTime().ToString('o')
        workspace = $workspace
        headWorkspace = $headWorkspace
    }

    Write-JsonFile -Value $pinned -Path (Join-Path $workspace 'pinned.json')
    Write-JsonFile -Value $pr -Path (Join-Path $workspace 'pr.json')
    Write-JsonFile -Value $files -Path (Join-Path $workspace 'changed-files.json')
    Write-JsonFile -Value $commits -Path (Join-Path $workspace 'commits.json')
    Write-JsonFile -Value $reviews -Path (Join-Path $workspace 'reviews.json')
    Write-JsonFile -Value $threads -Path (Join-Path $workspace 'review-threads.json')
    Write-JsonFile -Value $ci -Path (Join-Path $workspace 'ci.json')

    # Head-level pointer so a human reading the workspace has one obvious entry
    # point. Runs never read it, so a concurrent run overwriting it is harmless.
    Write-JsonFile -Value ([pscustomobject]@{
            runId     = $identity.RunId
            workspace = $workspace
            headSha   = $identity.HeadSha
            resolvedAt = $pinned.resolvedAt
        }) -Path (Join-Path $headWorkspace 'latest-run.json')

    Write-Output "Resolved PR $($identity.Owner)/$($identity.Repo)#$($identity.Number)"
    Write-Output "baseSha: $($identity.BaseSha)"
    Write-Output "headSha: $($identity.HeadSha)"
    Write-Output "runId: $($identity.RunId)"
    Write-Output "workspace: $workspace"
    Write-Output "changedFiles: $($files.Count)  commits: $($commits.Count)  reviews: $($reviews.Count)  threads: $($threads.threads.Count)"
    if (-not $resolvedFiles.Complete) {
        Write-Output "fileMapCoverage: INCOMPLETE — $($resolvedFiles.Reason)"
    }
    if (-not $threads.complete) {
        Write-Output "threadCoverage: INCOMPLETE — $($threads.incompleteReason)"
    }
}

function Open-PostLock {
    <#
      Take an exclusive, OS-enforced lock on the run directory for the whole
      reconcile → POST → receipt sequence.

      Receipt reconciliation makes a *retry* safe, which is a different problem
      from concurrency: two -Post processes for one run can both read
      "unpublished", both pass the run-marker check, and both publish, leaving
      two public reviews on the PR that no later run can retract. Run-directory
      isolation does not help — same run, same directory, by construction.

      The lock is a file held open with FileShare.None, because that is the one
      form of exclusion both Windows and Unix enforce in the kernel rather than
      by convention, and it is released even if the process is killed. The file
      itself is left behind on release: deleting it would open a window where a
      waiter has the path open and a third process creates it fresh, and an
      empty post.lock in a run directory costs nothing.
    #>
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [int]$TimeoutSeconds = 0
    )

    if ($TimeoutSeconds -le 0) { $TimeoutSeconds = Get-PostLockTimeoutSeconds }
    $lockPath = Join-Path $RunDirectory 'post.lock'
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($true) {
        try {
            $stream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            # Record who holds it, so a human staring at a blocked run has
            # something to look up rather than an empty file.
            $writer = [System.IO.StreamWriter]::new($stream, [System.Text.UTF8Encoding]::new($false), 1024, $true)
            try {
                $stream.SetLength(0)
                $writer.WriteLine("pid=$PID acquiredAt=$([DateTime]::UtcNow.ToString('o'))")
                $writer.Flush()
            }
            finally { $writer.Dispose() }
            return $stream
        }
        catch [System.IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) {
                throw ("Another pr-review post is already in progress for this run (lock '$lockPath' held " +
                    "for more than ${TimeoutSeconds}s). Publishing concurrently would post two reviews to the " +
                    'same PR, so this run stops. Wait for the other post to finish, or re-run -Resolve to ' +
                    'start a new run.')
            }
            Start-Sleep -Milliseconds 250
        }
    }
}

function Close-PostLock {
    param($Lock)

    if ($null -eq $Lock) { return }
    try { $Lock.Dispose() } catch { }
}

function Get-PostResultPath {
    <#
      The receipt lives in the run's own directory, so it is scoped by run
      rather than by head SHA. Keying it by head made a deliberate re-review of
      an unchanged head a silent no-op even when it had new findings; scoping it
      by run keeps retries of one run idempotent while letting the next explicit
      run publish its own summary. The runId recorded inside the receipt is
      checked too, so a legacy flat workspace cannot pass one run's receipt off
      as another's.
    #>
    param([Parameter(Mandatory)][string]$RunDirectory)
    return Join-Path $RunDirectory 'post-result.json'
}

function Get-RunMarker {
    <#
      A deterministic, machine-findable stamp for one run, embedded in the
      published review body. It is what makes an unreceipted retry safe: if the
      POST reached GitHub but the response, the parse, or the process died
      before the receipt was written, the retry finds this marker on the
      existing review instead of publishing a duplicate.

      The id is constrained to the shape -Resolve mints. It is read back out of
      pinned.json, which lives on disk, and both marker searches are substring
      matches: a runId of `*` would match the first review body it met and
      suppress publication of a review that was never posted. Failing closed on
      a malformed id is not a loss, since no real run has one.
    #>
    param([Parameter(Mandatory)][string]$RunId)
    if ($RunId -notmatch '^[0-9a-fA-F]{6,64}$') {
        throw "Refusing to use run id '$RunId': a run id must be 6-64 hex characters. Re-run -Resolve to mint one."
    }
    return "<!-- pr-review:run=$RunId -->"
}

function Add-RunMarker {
    param(
        [Parameter(Mandatory)]$Payload,
        [Parameter(Mandatory)][string]$RunId
    )

    $marker = Get-RunMarker -RunId $RunId
    $body = [string](Get-PropertyValue -Object $Payload -Name 'body')
    if ($body.Contains($marker, [System.StringComparison]::Ordinal)) { return $Payload }

    return [pscustomobject]@{
        commit_id = [string](Get-PropertyValue -Object $Payload -Name 'commit_id')
        event     = 'COMMENT'
        body      = ($body.TrimEnd() + "`n`n" + $marker)
        comments  = @((Get-PropertyValue -Object $Payload -Name 'comments'))
    }
}

function Find-ReviewByRunMarker {
    <#
      Look for a review this run already published. Returns the review object or
      $null. A failure to list is reported as $null by the caller's choice of
      -AllowFailure; the caller must treat "could not check" as "do not post".
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$RunId
    )

    $marker = Get-RunMarker -RunId $RunId
    $result = Invoke-GhPaginated -Action 'listing existing reviews to reconcile a retry' `
        -Path "repos/$Owner/$Repo/pulls/$Number/reviews" -AllowFailure
    if ($result.ExitCode -ne 0) {
        return [pscustomobject]@{ Checked = $false; Review = $null }
    }

    foreach ($review in @($result.Items)) {
        $body = [string](Get-PropertyValue -Object $review -Name 'body')
        # Ordinal substring, not -like: the marker is literal text, and wildcard
        # matching here would let a crafted id match a review it did not write.
        if ($body.Contains($marker, [System.StringComparison]::Ordinal)) {
            return [pscustomobject]@{ Checked = $true; Review = $review }
        }
    }
    return [pscustomobject]@{ Checked = $true; Review = $null }
}

function Assert-RunUnpublished {
    <#
      The gate every submission attempt passes through: reconcile against the
      run marker and only return when this run has demonstrably published
      nothing. Returning is the sole "go ahead" path — a review already on the
      PR recovers its receipt and exits 0, and a failure to list exits 1,
      because "could not check" has to mean "do not post".

      It is a function rather than a block because both the first attempt and
      the remap retry need it. The retry originally skipped it and resubmitted
      on a rejection matched by a deliberately broad regex, so a POST that
      reached GitHub and then failed in the response, the parse, or the
      transport published a second public review.
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$HeadSha,
        [Parameter(Mandatory)][string]$ResultPath
    )

    $existing = Find-ReviewByRunMarker -Owner $Owner -Repo $Repo -Number $Number -RunId $RunId
    if (-not $existing.Checked) {
        # Messages return with the halt object. Callers that assign
        # Get-SubmissionPlan (or this function) would otherwise capture
        # Write-Output and drop the user-facing lines — the original `exit`
        # flushed them to the process before the assignment completed.
        $script:PrReviewHalt = $true
        $script:PrReviewExitCode = 1
        return [pscustomobject]@{
            Halt     = $true
            Messages = @(
                ''
                'Could not post'
                "Could not list existing reviews to confirm whether run $RunId already published."
                'Refusing to post rather than risk a duplicate review. Retry when the API is reachable.'
            )
        }
    }
    if ($null -ne $existing.Review) {
        $recoveredId = (Get-PropertyValue -Object $existing.Review -Name 'id')
        $recovered = [pscustomobject]@{
            reviewId   = $recoveredId
            commentIds = @()
            runId      = $RunId
            headSha    = $HeadSha
            postedAt   = [string](Get-PropertyValue -Object $existing.Review -Name 'submitted_at')
            reconciled = $true
        }
        Write-JsonFile -Value $recovered -Path $ResultPath
        $script:PrReviewHalt = $true
        $script:PrReviewExitCode = 0
        return [pscustomobject]@{
            Halt     = $true
            Messages = @(
                "Run $RunId already published review $recoveredId; recovered its receipt (no duplicate posted)."
                "reviewId: $recoveredId"
            )
        }
    }
}

function Assert-PinnedPair {
    <#
      Re-read base and head and refuse to act unless both still match what the
      review was built against.

      Checking only head.sha left two holes. A push between gathering and
      posting could validate one diff and publish against the commit it was no
      longer describing, and a base-branch advance — which changes what the diff
      even means — was never detected at all.

      Both are re-checked immediately before every submission, not once at the
      start: the submission-time call lives inside Submit-Review rather than at
      its call sites, so no amount of work growing between the early check and
      the POST can widen that window again. The earlier calls — entering -Post,
      entering the remap retry, and closing the paginated changed-file list —
      are cheap early aborts that keep expensive work off a PR that has already
      moved, and Invoke-Resolve closes its gather the same way.
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$PinnedBase,
        [Parameter(Mandatory)][string]$PinnedHead,
        [Parameter(Mandatory)][string]$PayloadHead,
        [Parameter(Mandatory)][string]$Stage
    )

    $raw = Invoke-Gh -Action "re-fetching pinned base/head before $Stage" -GhArgs @(
        'api', "repos/$Owner/$Repo/pulls/$Number"
    )
    $live = ConvertFrom-GhJson -Text $raw.Text -Action "parsing PR #$Number for pin check"
    $liveHead = [string]$live.head.sha
    $liveBase = [string]$live.base.sha

    $problems = [System.Collections.Generic.List[string]]::new()
    if ($liveHead -ne $PinnedHead -or $liveHead -ne $PayloadHead) {
        $problems.Add("head moved (pinned=$PinnedHead payload=$PayloadHead live=$liveHead)")
    }
    if ($liveBase -ne $PinnedBase) {
        $problems.Add("base moved (pinned=$PinnedBase live=$liveBase)")
    }
    if ($problems.Count -gt 0) {
        throw ("Refusing to $Stage — " + ($problems -join '; ') + '. Re-run -Resolve and revalidate.')
    }

    return [pscustomobject]@{
        BaseSha      = $liveBase
        HeadSha      = $liveHead
        ChangedFiles = [int](Get-PropertyValue -Object $live -Name 'changed_files')
    }
}

function Get-PinnedHeadTreeBlobMap {
    <#
      Fetch the pinned head commit's tree in one non-paginated Git trees API call.
      Returns a path→blob-sha map when the response is complete; $null when the
      fetch fails or GitHub marks the tree truncated.
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$HeadSha
    )

    $raw = Invoke-Gh -Action 'fetching the pinned head tree' -GhArgs @(
        # `-f` supplies a request field, which switches `gh api` to POST unless
        # `--method GET` is given explicitly. The Git Trees endpoint only
        # accepts GET, so without this the pinned-tree proof 404s on every PR
        # past the 300-file compare cap and the fallback is refused outright.
        'api', '--method', 'GET', "repos/$Owner/$Repo/git/trees/$HeadSha", '-f', 'recursive=1'
    ) -AllowFailure
    if ($raw.ExitCode -ne 0) { return $null }

    $tree = ConvertFrom-GhJson -Text $raw.Text -Action 'parsing the pinned head tree'
    if ([bool](Get-PropertyValue -Object $tree -Name 'truncated')) { return $null }

    $map = [System.Collections.Generic.Dictionary[string, string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @((Get-PropertyValue -Object $tree -Name 'tree'))) {
        if ($null -eq $entry) { continue }
        if ([string](Get-PropertyValue -Object $entry -Name 'type') -ne 'blob') { continue }
        $path = Normalize-PathKey -Path ([string](Get-PropertyValue -Object $entry -Name 'path'))
        if (-not $path) { continue }
        $map[$path] = [string](Get-PropertyValue -Object $entry -Name 'sha')
    }
    return $map
}

function Assert-FallbackFilesMatchPinnedTree {
    <#
      Prove a mutable /pulls/<n>/files list describes the pinned head before it
      replaces the compare-derived map. compare/ is SHA-addressed; pulls/files
      follows whatever the PR points at right now, so an ABA race can leave a
      closing Assert-PinnedPair satisfied while the file entries came from an
      intermediate push. The pinned head tree is addressed by HeadSha and is the
      proof source: every non-removed entry's path must exist with the same blob
      sha, and every removed entry's path must be absent.
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$HeadSha,
        [Parameter(Mandatory)][object[]]$Files,
        [Parameter(Mandatory)][string]$Stage
    )

    $treeMap = Get-PinnedHeadTreeBlobMap -Owner $Owner -Repo $Repo -HeadSha $HeadSha
    if ($null -eq $treeMap) {
        return [pscustomobject]@{
            Proven  = $false
            Reason  = 'the beyond-300 fallback could not be proven against the pinned head tree'
        }
    }

    $problems = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $Files) {
        if ($null -eq $f) { continue }
        $status = [string](Get-PropertyValue -Object $f -Name 'status')
        $path = Normalize-PathKey -Path ([string](Get-PropertyValue -Object $f -Name 'filename'))
        if (-not $path) { continue }

        if ($status -eq 'removed') {
            if ($treeMap.ContainsKey($path)) {
                $problems.Add("removed file still present in the pinned head tree ($path)")
            }
            continue
        }

        $entrySha = [string](Get-PropertyValue -Object $f -Name 'sha')
        if (-not $treeMap.ContainsKey($path)) {
            $problems.Add("file missing from the pinned head tree ($path)")
            continue
        }
        if (-not $entrySha) {
            # A non-removed entry with no blob sha cannot be pinned to the head
            # tree. Skipping the comparison here (the old `if ($entrySha -and …)`
            # guard) let a sha-less entry pass as proven, which is exactly the
            # ABA hole this proof exists to close. Refuse it instead.
            $problems.Add("no blob sha to prove against the pinned head tree ($path)")
            continue
        }
        if ($treeMap[$path] -ne $entrySha) {
            $problems.Add("blob sha mismatch at $path (list=$entrySha tree=$($treeMap[$path]))")
        }
    }

    if ($problems.Count -gt 0) {
        throw ("Refusing to $Stage — " + ($problems -join '; ') + '. Re-run -Resolve and revalidate.')
    }

    return [pscustomobject]@{ Proven = $true; Reason = '' }
}

function Get-PinnedDiffFiles {
    <#
      Build the line map from the pinned base...head pair rather than the PR's
      mutable files view. /pulls/<n>/files always describes whatever the PR
      points at right now, so a push mid-run silently remapped comments onto a
      diff nobody reviewed. The compare endpoint is addressed by SHA, so it
      returns the same diff every time or nothing at all.

      That pin alone was not enough coverage. compare/ returns `files` on its
      first page only and truncates at 300 entries, so on a larger PR every file
      past the cap was missing from the map and its findings were demoted out of
      inline comments — reported as unmappable locations when the real cause was
      a map that stopped early.

      Past the cap, fall back to the paginated /pulls/<n>/files list, which is
      complete but mutable. A closing base/head check catches a push that stays
      moved, but not an ABA race: the PR can move to B while the endpoint
      responds, then be force-pushed back to the pinned base/head before that
      check, leaving a B file map that passes as A. Before trusting the fallback,
      every entry is verified against the pinned head tree (itself addressed by
      HeadSha); mismatch aborts, and a truncated or unavailable tree keeps the
      compare-derived files and reports the map incomplete.
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$BaseSha,
        [Parameter(Mandatory)][string]$HeadSha,
        [int]$ExpectedFileCount = 0
    )

    $result = Invoke-GhPaginated -Action 'fetching the pinned base...head diff' `
        -Path "repos/$Owner/$Repo/compare/$BaseSha...$HeadSha"

    # compare/ wraps its file array in an envelope; only the first page carries one.
    $files = [System.Collections.Generic.List[object]]::new()
    foreach ($page in @($result.Pages)) {
        if (-not (Test-HasProperty -Object $page -Name 'files')) { continue }
        foreach ($f in @((Get-PropertyValue -Object $page -Name 'files'))) {
            if ($null -ne $f) { $files.Add($f) }
        }
    }

    $source = "compare/$BaseSha...$HeadSha"
    $complete = $true
    $reason = ''

    $capped = $files.Count -ge $script:CompareFileCap
    $short = $ExpectedFileCount -gt 0 -and $files.Count -lt $ExpectedFileCount
    if ($capped -or $short) {
        $prResult = Invoke-GhPaginated -Action 'fetching the full changed-file list' `
            -Path "repos/$Owner/$Repo/pulls/$Number/files" -AllowFailure
        $prFiles = @($prResult.Items)

        if ($prResult.ExitCode -eq 0 -and $prFiles.Count -gt $files.Count) {
            # Closing pin: the list above is the PR's live view, so it is only
            # usable if base and head are still what the compare was pinned to.
            [void](Assert-PinnedPair -Owner $Owner -Repo $Repo -Number $Number `
                    -PinnedBase $BaseSha -PinnedHead $HeadSha -PayloadHead $HeadSha `
                    -Stage 'trust the paginated changed-file list')
            $proof = Assert-FallbackFilesMatchPinnedTree -Owner $Owner -Repo $Repo `
                -HeadSha $HeadSha -Files $prFiles `
                -Stage 'trust the paginated changed-file list against the pinned head tree'
            if ($proof.Proven) {
                $files = [System.Collections.Generic.List[object]]::new()
                foreach ($f in $prFiles) { if ($null -ne $f) { $files.Add($f) } }
                $source = "pulls/$Number/files (bracketed by the pinned base/head pair)"
            }
            else {
                $complete = $false
                $reason = ("compare/ returned $($files.Count) files (its cap is $script:CompareFileCap) " +
                    "and $($proof.Reason)")
            }
        }
        elseif ($prResult.ExitCode -ne 0) {
            $complete = $false
            $reason = ("compare/ returned $($files.Count) files (its cap is $script:CompareFileCap) " +
                'and the paginated changed-file list could not be fetched')
        }

        if ($complete -and $ExpectedFileCount -gt 0 -and $files.Count -lt $ExpectedFileCount) {
            $complete = $false
            $reason = "the changed-file map holds $($files.Count) of the PR's $ExpectedFileCount files"
        }
    }

    return [pscustomobject]@{
        Files    = $files.ToArray()
        Source   = $source
        Complete = $complete
        Reason   = $reason
    }
}

function Get-SubmissionPlan {
    param(
        [Parameter(Mandatory)][string]$PayloadPath,
        [string]$ExpectedRunId,
        [Parameter(Mandatory)][string]$Stage
    )

    Assert-GhPresent
    $payload = Read-JsonFile -Path $PayloadPath

    $violations = [System.Collections.Generic.List[string]]::new()
    Test-ReviewPayloadObject -Payload $payload -Path 'payload' -Violations $violations
    if ($violations.Count -gt 0) {
        $script:PrReviewHalt = $true
        $script:PrReviewExitCode = 1
        $failed = [System.Collections.Generic.List[string]]::new()
        $failed.Add('VALIDATION FAILED')
        foreach ($v in $violations) { $failed.Add(" - $v") }
        return [pscustomobject]@{ Halt = $true; Messages = $failed.ToArray() }
    }

    $headSha = [string]$payload.commit_id

    # The payload's own directory is where pinned.json is read from, so guard it
    # before reading: a junction here would redirect that read and every later
    # write. Canonicality is proved below, once the pinned identity is known.
    $workspace = Split-Path -Parent $PayloadPath
    if ([string]::IsNullOrWhiteSpace($workspace)) {
        $workspace = (Get-Location).Path
    }
    Assert-SafeWorkspacePath -Path $workspace

    $pinnedPath = Join-Path $workspace 'pinned.json'
    $pinned = $null
    if (Test-Path -LiteralPath $pinnedPath) {
        $pinned = Read-JsonFile -Path $pinnedPath
    }
    if ($null -eq $pinned) {
        throw "Cannot locate pinned.json beside payload ($pinnedPath). Run -Resolve first and post from the workspace."
    }

    $owner = [string]$pinned.owner
    $repo = [string]$pinned.repo
    $number = [int]$pinned.pr
    $pinnedHead = [string]$pinned.headSha
    $pinnedBase = ''
    if (Test-HasProperty -Object $pinned -Name 'baseSha') {
        $pinnedBase = [string](Get-PropertyValue -Object $pinned -Name 'baseSha')
    }
    if ([string]::IsNullOrWhiteSpace($pinnedBase)) {
        throw "pinned.json has no baseSha, so publication cannot be pinned to a base/head pair. Re-run -Resolve."
    }

    $runId = ''
    if (Test-HasProperty -Object $pinned -Name 'runId') {
        $runId = [string](Get-PropertyValue -Object $pinned -Name 'runId')
    }
    if ([string]::IsNullOrWhiteSpace($runId)) {
        throw "pinned.json has no runId. Re-run -Resolve to mint one."
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedRunId) -and $ExpectedRunId -ne $runId) {
        throw "-RunId '$ExpectedRunId' does not match the run that owns this payload ('$runId'). Post from that run's own workspace."
    }

    # Construction-time validation: malformed owner/repo/number/sha/runId throw
    # here rather than flowing into publication. Existing pinned.json messages
    # above still fire first so their trigger conditions stay unchanged.
    $identity = New-PrReviewIdentity -Owner $owner -Repo $repo -Number $number `
        -HeadSha $pinnedHead -BaseSha $pinnedBase -RunId $runId

    # The pinned identity now decides where this run lives — not the path the
    # caller happened to pass. Everything below writes to the canonical path.
    $workspace = Assert-CanonicalRunWorkspace -Identity $identity -Workspace $workspace

    # Everything from here to the receipt is one critical section. The caller
    # owns releasing it: -Preflight drops it as soon as the plan comes back,
    # -Post holds it across the submission and the receipt write. Taken before
    # the receipt is read, because a check that another process can invalidate
    # between the read and the POST is not a check.
    $lock = Open-PostLock -RunDirectory $workspace

    # Idempotent retry: this run already posted. A later -Resolve mints a new run
    # id in its own directory, so re-reviewing an unchanged head still publishes
    # a fresh summary. The runId is re-checked here as well as being implied by
    # the directory, so a legacy flat workspace cannot pass one run's receipt off
    # as another's.
    $resultPath = Get-PostResultPath -RunDirectory $workspace
    if (Test-Path -LiteralPath $resultPath) {
        # An unreadable receipt is treated as no receipt, not as a fatal error.
        # Dying here would skip the run-marker reconciliation below, which is the
        # one mechanism that can tell whether the POST actually landed — turning
        # a recoverable state into an unrecoverable one.
        $prior = $null
        try { $prior = Read-JsonFile -Path $resultPath }
        catch {
            Write-Warning "Ignoring unreadable post receipt '$resultPath' ($($_.Exception.Message)). Reconciling against the run marker instead."
        }
        if ($null -ne $prior) {
            $priorRun = [string](Get-PropertyValue -Object $prior -Name 'runId')
            if ($priorRun -eq $runId -and [string]$prior.headSha -eq $headSha -and $prior.reviewId) {
                return [pscustomobject]@{
                    AlreadyPosted = $true
                    Prior         = $prior
                    Identity      = $identity
                    RunId         = $identity.RunId
                    HeadSha       = $headSha
                    Lock          = $lock
                }
            }
        }
    }

    # 1. Re-fetch base and head; refuse if either moved.
    $pinCheck = Assert-PinnedPair -Owner $identity.Owner -Repo $identity.Repo -Number $identity.Number `
        -PinnedBase $identity.BaseSha -PinnedHead $identity.HeadSha -PayloadHead $headSha -Stage $Stage

    # 2. No receipt, but the POST may still have reached GitHub on an earlier
    #    attempt that died before writing one. Reconcile against the run marker
    #    before publishing anything. "Could not check" is treated as "do not
    #    post": a duplicate public review is worse than a failed run.
    $unpublished = Assert-RunUnpublished -Owner $identity.Owner -Repo $identity.Repo -Number $identity.Number `
        -RunId $identity.RunId -HeadSha $headSha -ResultPath $resultPath
    if ($script:PrReviewHalt) { return $unpublished }

    # 3. Validate comments against the diff pinned to base...head, not the PR's
    #    mutable files view.
    $fileMap = Get-PinnedDiffFiles -Owner $identity.Owner -Repo $identity.Repo -Number $identity.Number `
        -BaseSha $identity.BaseSha -HeadSha $identity.HeadSha -ExpectedFileCount $pinCheck.ChangedFiles
    $files = @($fileMap.Files)
    Write-JsonFile -Value $files -Path (Join-Path $workspace 'changed-files.json')
    $coverageNote = ''
    if (-not $fileMap.Complete) {
        $coverageNote = $fileMap.Reason
        Write-Warning ("Changed-file map is incomplete — $($fileMap.Reason). " +
            'Findings in the missing files cannot be placed inline.')
    }
    $diffMap = Get-DiffLineMap -Files $files

    $working = $payload
    $comments = @()
    if (Test-HasProperty -Object $working -Name 'comments') {
        $comments = @((Get-PropertyValue -Object $working -Name 'comments'))
    }

    $unmappable = [System.Collections.Generic.List[object]]::new()
    $mappable = [System.Collections.Generic.List[object]]::new()
    foreach ($c in $comments) {
        $problems = [System.Collections.Generic.List[string]]::new()
        Test-CommentAgainstDiff -Comment $c -DiffMap $diffMap -Problems $problems
        if ($problems.Count -gt 0) {
            $unmappable.Add($c)
        }
        else {
            $mappable.Add($c)
        }
    }

    if ($unmappable.Count -gt 0) {
        # Pre-flight remap: drop known-bad from inline before first post attempt.
        $working = Move-UnmappableToSummary -Payload $working -UnmappableComments @($unmappable) `
            -CoverageNote $coverageNote
    }
    else {
        $working = [pscustomobject]@{
            commit_id = [string]$payload.commit_id
            event     = 'COMMENT'
            body      = [string]$payload.body
            comments  = @($mappable)
        }
    }

    # Stamp the run marker here rather than at the submission, so preflight
    # validates and preserves the exact bytes -Post sends instead of a near-copy.
    $working = Add-RunMarker -Payload $working -RunId $identity.RunId

    return [pscustomobject]@{
        AlreadyPosted   = $false
        Prior           = $null
        Lock            = $lock
        SourcePayload   = $payload
        PayloadSource   = Get-PayloadSource -PayloadPath $PayloadPath
        Payload         = $working
        Workspace       = $workspace
        Identity        = $identity
        Owner           = $identity.Owner
        Repo            = $identity.Repo
        Number          = $identity.Number
        RunId           = $identity.RunId
        HeadSha         = $headSha
        PinnedBase      = $identity.BaseSha
        PinnedHead      = $identity.HeadSha
        ResultPath      = $resultPath
        PinCheck        = $pinCheck
        FileMap         = $fileMap
        CoverageNote    = $coverageNote
        MappableCount   = $mappable.Count
        UnmappableCount = $unmappable.Count
    }
}

function Invoke-Preflight {
    param(
        [Parameter(Mandatory)][string]$PayloadPath,
        [string]$ExpectedRunId
    )

    $plan = Get-SubmissionPlan -PayloadPath $PayloadPath -ExpectedRunId $ExpectedRunId -Stage 'preflight'
    if ($script:PrReviewHalt) {
        foreach ($line in @($plan.Messages)) { Write-Output $line }
        return
    }

    # The plan holds the run's post lock. Preflight performs no write to GitHub,
    # so it releases at every exit rather than holding the run hostage; an
    # exception on the way out unwinds to the top-level handler, which exits the
    # process and lets the OS drop the handle.
    if ($plan.AlreadyPosted) {
        Close-PostLock -Lock $plan.Lock
        Write-Output "PREFLIGHT: run $($plan.RunId) already published review $($plan.Prior.reviewId) at head $($plan.HeadSha)."
        Write-Output 'A -Post would be an idempotent no-op. Run -Resolve again to start a new run.'
        return
    }

    $workspace = $plan.Workspace
    $working = $plan.Payload

    # The same artefacts -Post preserves, minus the submission itself.
    Write-JsonFile -Value $working -Path (Join-Path $workspace 'review.json')
    $mdPath = Join-Path $workspace 'review.md'
    Set-Content -LiteralPath $mdPath -Value (ConvertTo-ReviewMarkdown -Payload $working) -Encoding utf8
    Close-PostLock -Lock $plan.Lock

    Write-Output 'PREFLIGHT PASSED — no GitHub write was performed.'
    Write-Output "target: $($plan.Owner)/$($plan.Repo)#$($plan.Number)"
    Write-Output "runId: $($plan.RunId)"
    Write-Output "pinned: base $($plan.PinnedBase) head $($plan.PinnedHead)"
    # UNVERIFIED means the inline-placement gates in -BuildPayload were not
    # proved to have run over these bytes, not that the payload is wrong.
    Write-Output "payloadSource: $($plan.PayloadSource)"
    Write-Output 'checks:'
    Write-Output '  - payload validated against review-schema.json'
    Write-Output '  - run workspace recomputed from pinned identity and proved canonical'
    Write-Output '  - run id bound to this payload'
    Write-Output '  - base and head re-read; neither moved'
    Write-Output '  - run marker reconciled against existing reviews; this run has not published'
    Write-Output "  - diff line map built from $($plan.FileMap.Source)"
    Write-Output '  - every inline comment located against the pinned diff'
    Write-Output '  - run marker stamped on the outgoing body'
    Write-Output "inlineComments: $($plan.MappableCount)"
    Write-Output "movedToSummary: $($plan.UnmappableCount)"
    if (-not [string]::IsNullOrWhiteSpace($plan.CoverageNote)) {
        Write-Output "fileMapCoverage: INCOMPLETE — $($plan.CoverageNote)"
    }
    Write-Output "payload: $(Join-Path $workspace 'review.json')"
    Write-Output "fallback: $mdPath"
    Write-Output ''
    Write-Output 'Preflight proves the payload is internally valid and correctly located'
    Write-Output 'against the pinned diff. It cannot prove GitHub would accept it — only'
    Write-Output 'the submission itself does that.'
}

function Invoke-Post {
    param(
        [Parameter(Mandatory)][string]$PayloadPath,
        [string]$ExpectedRunId
    )

    $plan = Get-SubmissionPlan -PayloadPath $PayloadPath -ExpectedRunId $ExpectedRunId -Stage 'post'
    if ($script:PrReviewHalt) {
        foreach ($line in @($plan.Messages)) { Write-Output $line }
        return
    }

    # The plan handed over the run's post lock. It is held across the submission
    # and released only once the receipt exists on disk, so a second -Post for
    # this run either waits and then sees the receipt, or times out — it never
    # publishes a second review. Every early exit below releases explicitly;
    # anything that throws unwinds to the top-level handler, and the process
    # exit drops the handle.
    if ($plan.AlreadyPosted) {
        Close-PostLock -Lock $plan.Lock
        $prior = $plan.Prior
        Write-Output "Already posted for run $($plan.RunId) at head $($plan.HeadSha) (idempotent no-op)"
        Write-Output "reviewId: $($prior.reviewId)"
        Write-Output ("commentIds: " + ((@($prior.commentIds) | ForEach-Object { $_ }) -join ', '))
        Write-Output "postedAt: $($prior.postedAt)"
        Write-Output 'Run -Resolve again to start a new run against this head.'
        return
    }

    $payload = $plan.SourcePayload
    $working = $plan.Payload
    $workspace = $plan.Workspace
    $identity = $plan.Identity
    $owner = $identity.Owner
    $repo = $identity.Repo
    $number = $identity.Number
    $runId = $identity.RunId
    $headSha = $plan.HeadSha
    $pinnedBase = $identity.BaseSha
    $pinnedHead = $identity.HeadSha
    $resultPath = $plan.ResultPath
    $pinCheck = $plan.PinCheck
    $fileMap = $plan.FileMap
    $coverageNote = $plan.CoverageNote

    function Submit-Review {
        param(
            $ReviewPayload,
            [Parameter(Mandatory)][string]$Stage
        )
        # The pair is re-read here, inside the submission itself, rather than at
        # the call sites. "Immediately before every submission attempt" was true
        # of the code that first made the claim and had already drifted: between
        # the outer check and the POST sat the run-marker lookup, the file-map
        # fetch, and payload assembly, and a truncated map added a whole
        # pagination plus a nested pin check to that window. Owning the check
        # here makes the claim structural — a new call site cannot forget it,
        # and the outer checks stay as the cheap early abort that keeps
        # expensive work off a PR that has already moved.
        [void](Assert-PinnedPair -Owner $owner -Repo $repo -Number $number `
                -PinnedBase $pinnedBase -PinnedHead $pinnedHead -PayloadHead $headSha -Stage $Stage)
        $tmp = Join-Path $workspace 'review.post.json'
        Write-JsonFile -Value $ReviewPayload -Path $tmp
        return Invoke-Gh -Action 'posting pull request review' -GhArgs @(
            'api',
            '--method', 'POST',
            "repos/$owner/$repo/pulls/$number/reviews",
            '--input', $tmp
        ) -AllowFailure
    }

    # Preserve exact outgoing payload before attempt. The run marker — which lets
    # a retry that lost its receipt recognise this review on GitHub — is already
    # stamped by Get-SubmissionPlan, so these bytes are the ones preflight saw.
    Write-JsonFile -Value $working -Path (Join-Path $workspace 'review.json')

    $response = Submit-Review -ReviewPayload $working -Stage 'post'

    # 3. If gh rejects line locations, refresh + remap exactly once.
    if ($response.ExitCode -ne 0 -and $response.Text -match '(?i)(line|position|pull_request_review_thread|Path)') {
        Write-Warning 'GitHub rejected one or more line locations; refreshing diff and retrying once.'

        # A non-zero exit is not proof the POST never landed: it also covers a
        # request GitHub accepted whose response, parse, or transport then
        # failed. The regex above is deliberately broad — a 5xx or permission
        # body containing the word "Path" reaches here — so reconcile against
        # the run marker again before resubmitting, exactly as the first
        # attempt did. Without this the retry publishes a second public review.
        $unpublished = Assert-RunUnpublished -Owner $identity.Owner -Repo $identity.Repo -Number $identity.Number `
            -RunId $identity.RunId -HeadSha $headSha -ResultPath $resultPath
        if ($script:PrReviewHalt) {
            foreach ($line in @($unpublished.Messages)) { Write-Output $line }
            return
        }

        # Re-pin before the second submission too. The rejection may itself be
        # the first sign that the PR moved under us, and this is a separate
        # publication attempt, not a continuation of the first.
        [void](Assert-PinnedPair -Owner $owner -Repo $repo -Number $number `
                -PinnedBase $pinnedBase -PinnedHead $pinnedHead -PayloadHead $headSha -Stage 'retry the post')

        $fileMap2 = Get-PinnedDiffFiles -Owner $owner -Repo $repo -Number $number `
            -BaseSha $pinnedBase -HeadSha $pinnedHead -ExpectedFileCount $pinCheck.ChangedFiles
        $files2 = @($fileMap2.Files)
        Write-JsonFile -Value $files2 -Path (Join-Path $workspace 'changed-files.json')
        if (-not $fileMap2.Complete) { $coverageNote = $fileMap2.Reason }
        $diffMap2 = Get-DiffLineMap -Files $files2

        $stillBad = [System.Collections.Generic.List[object]]::new()
        $stillGood = [System.Collections.Generic.List[object]]::new()
        $retryComments = @()
        if (Test-HasProperty -Object $working -Name 'comments') {
            $retryComments = @((Get-PropertyValue -Object $working -Name 'comments'))
        }
        foreach ($c in $retryComments) {
            $problems = [System.Collections.Generic.List[string]]::new()
            Test-CommentAgainstDiff -Comment $c -DiffMap $diffMap2 -Problems $problems
            if ($problems.Count -gt 0) { $stillBad.Add($c) } else { $stillGood.Add($c) }
        }

        # If GitHub rejected but our map still thinks lines are fine, treat ALL
        # remaining inline comments as unmappable rather than looping.
        if ($stillBad.Count -eq 0 -and $retryComments.Count -gt 0) {
            $stillBad = [System.Collections.Generic.List[object]]::new()
            foreach ($c in $retryComments) { $stillBad.Add($c) }
            $stillGood = [System.Collections.Generic.List[object]]::new()
        }

        # Rebuild the body from the original payload, not from $working. By this
        # point $working's body may already carry a pre-flight "## Not inline"
        # section and a run marker; reusing it would append a second
        # section below the first and leave the reader with two contradictory
        # lists of what was demoted.
        $working = [pscustomobject]@{
            commit_id = [string]$payload.commit_id
            event     = 'COMMENT'
            body      = [string]$payload.body
            comments  = @($stillGood)
        }
        if ($stillBad.Count -gt 0) {
            $working = Move-UnmappableToSummary -Payload $working -UnmappableComments @($stillBad) `
                -CoverageNote $coverageNote
        }

        $working = Add-RunMarker -Payload $working -RunId $runId
        Write-JsonFile -Value $working -Path (Join-Path $workspace 'review.json')
        $response = Submit-Review -ReviewPayload $working -Stage 'retry the post'
    }

    if ($response.ExitCode -ne 0) {
        # 4. Auth / rate-limit / API failure — preserve payload + markdown fallback.
        $mdPath = Join-Path $workspace 'review.md'
        $md = ConvertTo-ReviewMarkdown -Payload $working
        Set-Content -LiteralPath $mdPath -Value $md -Encoding utf8
        Write-JsonFile -Value $working -Path (Join-Path $workspace 'review.json')
        Close-PostLock -Lock $plan.Lock

        Write-Output ''
        Write-Output 'Could not post'
        Write-Output "Fallback markdown: $mdPath"
        Write-Output "Preserved payload: $(Join-Path $workspace 'review.json')"
        Write-Output "gh error: $($response.Text.Trim())"
        $script:PrReviewHalt = $true
        $script:PrReviewExitCode = 1
        return
    }

    $created = ConvertFrom-GhJson -Text $response.Text -Action 'parsing created review'
    $reviewId = $created.id
    $postedAt = (Get-Date).ToUniversalTime().ToString('o')

    # Write the receipt the moment the review id is known, before the comment-id
    # fetch. Anything that fails after this point leaves a retry a no-op instead
    # of a duplicate; a crash before it is caught by the run marker on retry.
    $result = [pscustomobject]@{
        reviewId   = $reviewId
        commentIds = @()
        runId      = $runId
        headSha    = $headSha
        postedAt   = $postedAt
    }
    Write-JsonFile -Value $result -Path $resultPath
    # The receipt is on disk: a concurrent -Post can now safely take the lock,
    # read it, and no-op. Everything below only enriches the receipt.
    Close-PostLock -Lock $plan.Lock

    # Collect comment ids from the review comments endpoint (paginated: a large
    # review exceeds one page, and a short receipt makes retries look wrong).
    $commentIds = @()
    $cResult = Invoke-GhPaginated -Action 'listing review comments' -Path "repos/$owner/$repo/pulls/$number/reviews/$reviewId/comments" -AllowFailure
    if ($cResult.ExitCode -eq 0) {
        $commentIds = @($cResult.Items | ForEach-Object { $_.id })
        $result = [pscustomobject]@{
            reviewId   = $reviewId
            commentIds = $commentIds
            runId      = $runId
            headSha    = $headSha
            postedAt   = $postedAt
        }
        Write-JsonFile -Value $result -Path $resultPath
    }

    Write-JsonFile -Value $working -Path (Join-Path $workspace 'review.json')

    Write-Output "Posted COMMENT review $reviewId on $owner/$repo#$number"
    Write-Output "reviewId: $reviewId"
    Write-Output ("commentIds: " + ($commentIds -join ', '))
    Write-Output "headSha: $headSha"
    Write-Output "postedAt: $postedAt"
    Write-Output "payloadSource: $($plan.PayloadSource)"
    Write-Output "fileMapSource: $($fileMap.Source)"
    if (-not [string]::IsNullOrWhiteSpace($coverageNote)) {
        Write-Output "fileMapCoverage: INCOMPLETE — $coverageNote"
    }
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------

try {
    $script:PrReviewHalt = $false
    $script:PrReviewExitCode = 0

    if ($Help) {
        Show-Usage
        exit 0
    }

    $resolveRequested = Test-ResolveRequested -BoundParameters $PSBoundParameters
    $verbCount = 0
    if ($resolveRequested) { $verbCount++ }
    if ($Preflight) { $verbCount++ }
    if ($Post) { $verbCount++ }
    if ($NewWorkspace) { $verbCount++ }
    if ($Validate) { $verbCount++ }
    if ($Fingerprint) { $verbCount++ }
    if ($Dedupe) { $verbCount++ }
    if ($BuildPayload) { $verbCount++ }
    if ($MarkdownFallback) { $verbCount++ }
    if ($Ledger) { $verbCount++ }

    if ($verbCount -eq 0) {
        Show-Usage
        Write-Error 'No verb specified. Pass -Help or one of the documented switches.'
        exit 1
    }
    if ($verbCount -gt 1) {
        Write-Error 'Specify exactly one verb per invocation.'
        exit 1
    }

    if ($resolveRequested) {
        Invoke-Resolve -Target $Resolve
        exit 0
    }

    if ($NewWorkspace) {
        if ([string]::IsNullOrWhiteSpace($Owner) -or [string]::IsNullOrWhiteSpace($Repo) -or
            $Pr -le 0 -or [string]::IsNullOrWhiteSpace($HeadSha)) {
            throw '-NewWorkspace requires -Owner, -Repo, -Pr, and -HeadSha'
        }
        $path = New-OrGetWorkspace -Owner $Owner -Repo $Repo -Pr $Pr -HeadSha $HeadSha
        Write-Output $path
        exit 0
    }

    if ($Validate) {
        Invoke-Validate -FindingsPath $Findings -PayloadPath $Payload
        exit $script:PrReviewExitCode
    }

    if ($Fingerprint) {
        if ([string]::IsNullOrWhiteSpace($Findings)) {
            throw '-Fingerprint requires -Findings <path>'
        }
        Invoke-Fingerprint -FindingsPath $Findings
        exit 0
    }

    if ($Dedupe) {
        if ([string]::IsNullOrWhiteSpace($Findings) -or [string]::IsNullOrWhiteSpace($Prior)) {
            throw '-Dedupe requires -Findings <path> and -Prior <path>'
        }
        Invoke-Dedupe -FindingsPath $Findings -PriorPath $Prior -AllowIncompletePrior:$AllowIncompletePrior
        exit 0
    }

    if ($BuildPayload) {
        if ([string]::IsNullOrWhiteSpace($Findings) -or [string]::IsNullOrWhiteSpace($BaseSha) -or
            [string]::IsNullOrWhiteSpace($HeadSha)) {
            throw '-BuildPayload requires -Findings, -BaseSha, and -HeadSha'
        }
        $hasText = $PSBoundParameters.ContainsKey('BodyText')
        $hasFile = -not [string]::IsNullOrWhiteSpace($BodyFile)
        if ($hasText -and $hasFile) {
            throw '-BuildPayload takes -BodyText or -BodyFile, not both.'
        }
        if (-not $hasText -and -not $hasFile) {
            throw '-BuildPayload requires -BodyText <text> or -BodyFile <path>'
        }
        Invoke-BuildPayload -FindingsPath $Findings -BaseSha $BaseSha -HeadSha $HeadSha `
            -BodyText $BodyText -BodyFile $BodyFile -OutPath $Out
        exit $script:PrReviewExitCode
    }

    if ($MarkdownFallback) {
        if ([string]::IsNullOrWhiteSpace($Payload)) {
            throw '-MarkdownFallback requires -Payload <path>'
        }
        Invoke-MarkdownFallback -PayloadPath $Payload
        exit $script:PrReviewExitCode
    }

    if ($Ledger) {
        if ([string]::IsNullOrWhiteSpace($State)) {
            throw '-Ledger requires -State <path>'
        }
        Invoke-Ledger -StatePath $State
        exit 0
    }

    if ($Preflight) {
        if ([string]::IsNullOrWhiteSpace($Payload)) {
            throw '-Preflight requires -Payload <path>'
        }
        Invoke-Preflight -PayloadPath $Payload -ExpectedRunId $RunId
        exit $script:PrReviewExitCode
    }

    if ($Post) {
        if ([string]::IsNullOrWhiteSpace($Payload)) {
            throw '-Post requires -Payload <path>'
        }
        Invoke-Post -PayloadPath $Payload -ExpectedRunId $RunId
        exit $script:PrReviewExitCode
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
