#!/usr/bin/env pwsh
# Self-test for skills/pr-review/scripts/pr-review.ps1.
#
# Guards the defects found in review of #86 that no test caught:
#
#   1. `gh api --paginate` emits one JSON document per page, so any PR crossing a
#      page of files/commits/reviews/check-runs aborted resolve and post.
#   2. The posting receipt was keyed by head SHA, so a deliberate re-review of an
#      unchanged head exited as an idempotent no-op and published nothing.
#   3. A run id alone did not isolate a run: concurrent runs over one head shared
#      pinned.json and traded receipts.
#   4. Publication checked only head.sha against a mutable PR files view, so a
#      base advance went undetected and a mid-run push remapped comments.
#   5. A POST that reached GitHub but died before its receipt was written
#      republished on retry.
#   6. GraphQL partial success (data + top-level errors) was recorded as complete
#      thread coverage, which makes dedupe repost existing comments.
#   7. `-Body` read its value as a file whenever that value named one.
#   8. The line map came only from compare/, which caps its file list at 300, so
#      findings past that cap were demoted out of inline comments.
#   9. -Post trusted any directory holding a payload and a pinned.json, letting a
#      crafted pair pick the destination and route every write through it.
#  10. The semantic dedupe key dropped location entirely, so two distinct defects
#      worded the same way collapsed and the second was dropped.
#
# Unit checks dot-source the helper's top-level functions out of its AST (the
# script's own dispatch calls exit, so it cannot be dot-sourced directly).
# End-to-end checks run the real script against a fake `gh` on PATH.
#
#   pwsh ./scripts/local/Test-PrReviewHelper.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$helper = Join-Path $repoRoot 'skills/pr-review/scripts/pr-review.ps1'
if (-not (Test-Path -LiteralPath $helper)) {
    throw "Helper not found: $helper"
}

$failures = 0
$checks = 0

function Assert-True {
    param([string]$Name, [bool]$Condition)
    $script:checks++
    if ($Condition) { Write-Host "  ok       $Name" }
    else { Write-Host "  FAIL     $Name" -ForegroundColor Red; $script:failures++ }
}

function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    $script:checks++
    if ($Expected -eq $Actual) { Write-Host "  ok       $Name" }
    else {
        Write-Host "  FAIL     $Name (expected=$Expected actual=$Actual)" -ForegroundColor Red
        $script:failures++
    }
}

# ---------------------------------------------------------------------------
# Load the helper's top-level functions without running its dispatch block.
# ---------------------------------------------------------------------------

$parseErrors = $null
$tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($helper, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors -and $parseErrors.Count -gt 0) {
    throw "Helper does not parse: $($parseErrors[0].Message)"
}
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}

Write-Host ''
Write-Host 'pr-review helper: pagination, receipts, and workspace safety'
Write-Host ''
Write-Host 'Split-JsonDocuments'

# 1. The exact shape `gh api --paginate` produces: one document per page.
$twoPages = "[{`"filename`":`"a.cs`"}]`n[{`"filename`":`"b.cs`"}]"
$docs = @(Split-JsonDocuments -Text $twoPages)
Assert-Equal 'two concatenated pages split into two documents' 2 $docs.Count

# 2. Brackets and braces inside string values must not move the nesting depth —
#    a diff patch routinely contains `new[] { 1 }`.
$withBrackets = '[{"patch":"@@ -1,2 +1,3 @@\n var x = new[] { 1 };\n"}]'
$docs = @(Split-JsonDocuments -Text $withBrackets)
Assert-Equal 'brackets inside a string stay in one document' 1 $docs.Count
Assert-True 'that document round-trips' (($docs[0] | ConvertFrom-Json).patch -match 'new\[\] \{ 1 \}')

# 3. An escaped quote must not end the string early.
$withEscape = '[{"body":"he said \"]\" and left"}]'
$docs = @(Split-JsonDocuments -Text $withEscape)
Assert-Equal 'escaped quote does not terminate the string' 1 $docs.Count

# 4. Degenerate inputs.
Assert-Equal 'single document stays single' 1 @(Split-JsonDocuments -Text '[]').Count
Assert-Equal 'empty text yields no documents' 0 @(Split-JsonDocuments -Text '').Count

$threw = $false
try { [void](Split-JsonDocuments -Text '[{"a":1}') } catch { $threw = $true }
Assert-True 'truncated JSON is reported, not silently accepted' $threw

Write-Host ''
Write-Host 'Merge-CheckRunPages'

$page1 = '{"total_count":1,"check_runs":[{"name":"build"}]}' | ConvertFrom-Json
$page2 = '{"total_count":1,"check_runs":[{"name":"lint"}]}' | ConvertFrom-Json
$merged = Merge-CheckRunPages -Pages @($page1, $page2)
Assert-Equal 'check-run pages merge into one envelope' 2 @($merged.check_runs).Count
Assert-Equal 'merged total_count reflects every page' 2 $merged.total_count
Assert-Equal 'a page without check_runs is skipped, not fatal' 1 `
    @((Merge-CheckRunPages -Pages @($page1, ('{"message":"Not Found"}' | ConvertFrom-Json))).check_runs).Count

Write-Host ''
Write-Host 'Receipts and run markers'

$ws = Join-Path ([System.IO.Path]::GetTempPath()) 'pr-review-receipt-shape'
Assert-True 'the receipt lives in the run directory' `
    ((Get-PostResultPath -RunDirectory (Join-Path $ws 'runs/aaaa1111')) -match 'post-result\.json$')
Assert-True 'two runs get two receipts' `
    ((Get-PostResultPath -RunDirectory (Join-Path $ws 'runs/aaaa1111')) -ne
     (Get-PostResultPath -RunDirectory (Join-Path $ws 'runs/bbbb2222')))

# The run marker is what makes an unreceipted retry safe, so it has to be
# deterministic and it must not accumulate on a payload that already carries it.
Assert-Equal 'the run marker is deterministic' (Get-RunMarker -RunId 'abc123') (Get-RunMarker -RunId 'abc123')
Assert-True 'two runs get different markers' ((Get-RunMarker -RunId 'abc123') -ne (Get-RunMarker -RunId 'def456'))

$markerPayload = [pscustomobject]@{ commit_id = 'aa'; event = 'COMMENT'; body = 'Summary.'; comments = @() }
$stamped = Add-RunMarker -Payload $markerPayload -RunId 'abc123'
Assert-True 'the marker is stamped into the body' ($stamped.body -like "*$(Get-RunMarker -RunId 'abc123')*")
$stampedTwice = Add-RunMarker -Payload $stamped -RunId 'abc123'
Assert-Equal 'stamping twice does not duplicate the marker' $stamped.body $stampedTwice.body

Write-Host ''
Write-Host 'Get-BodyText (body text is not a file path)'

# The defect: -Body read its value as a file whenever that value named one, so a
# review body naming a local path published that file's contents.
$bodyRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'pr-review'
$bodyDir = Join-Path $bodyRoot 'bodytext-selftest'
New-Item -ItemType Directory -Path $bodyDir -Force | Out-Null
$insideFile = Join-Path $bodyDir 'summary.md'
Set-Content -LiteralPath $insideFile -Value 'body from an owned file' -Encoding utf8
$outsideFile = Join-Path ([System.IO.Path]::GetTempPath()) 'pr-review-outside-secret.txt'
Set-Content -LiteralPath $outsideFile -Value 'SECRET' -Encoding utf8

try {
    Assert-Equal 'body text naming an existing file is used verbatim' `
        $insideFile (Get-BodyText -BodyText $insideFile)
    Assert-Equal 'a body file inside the workspace root is read' `
        'body from an owned file' ((Get-BodyText -BodyFile $insideFile).Trim())

    $threw = $false
    try { [void](Get-BodyText -BodyFile $outsideFile) } catch { $threw = $true }
    Assert-True 'a body file outside the workspace root is refused' $threw
}
finally {
    Remove-Item -LiteralPath $bodyDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $outsideFile -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host 'Fingerprints survive an unrelated line shift'

# A finding whose line moved because an unrelated line was inserted above it is
# the same finding; reposting it is the defect the semantic key exists to stop.
$findingA = [pscustomobject]@{
    repo = 'acme/widgets'; pr = '7'; category = 'risk'; file = 'src/a.cs'
    side = 'RIGHT'; line = 120
    summary = 'Null deref on empty input'; failure_scenario = 'Empty list throws'
}
$findingB = [pscustomobject]@{
    repo = 'acme/widgets'; pr = '7'; category = 'risk'; file = 'src/a.cs'
    side = 'RIGHT'; line = 124
    summary = 'Null deref on empty input'; failure_scenario = 'Empty list throws'
}
Assert-True 'the exact key changes when the line moves' `
    ((Get-FindingFingerprint -Finding $findingA) -ne (Get-FindingFingerprint -Finding $findingB))
Assert-Equal 'the semantic key survives the line move' `
    (Get-FindingSemanticFingerprint -Finding $findingA) (Get-FindingSemanticFingerprint -Finding $findingB)

$findingC = [pscustomobject]@{
    repo = 'acme/widgets'; pr = '7'; category = 'risk'; file = 'src/a.cs'
    side = 'RIGHT'; line = 120
    summary = 'Unrelated defect'; failure_scenario = 'Something else entirely'
}
Assert-True 'a different finding still gets a different semantic key' `
    ((Get-FindingSemanticFingerprint -Finding $findingA) -ne (Get-FindingSemanticFingerprint -Finding $findingC))

# Two defects, two sites, one wording. Dropping location from the semantic key
# made these one finding, and the second one disappeared.
$sameWordingElsewhere = [pscustomobject]@{
    repo = 'acme/widgets'; pr = '7'; category = 'risk'; file = 'src/a.cs'
    side = 'RIGHT'; line = 480
    summary = 'Null deref on empty input'; failure_scenario = 'Empty list throws'
}
Assert-True 'identical wording at two sites shares the semantic key without context' `
    ((Get-FindingSemanticFingerprint -Finding $findingA) -eq (Get-FindingSemanticFingerprint -Finding $sameWordingElsewhere))

$withSymbolA = [pscustomobject]@{
    repo = 'acme/widgets'; pr = '7'; category = 'risk'; file = 'src/a.cs'
    side = 'RIGHT'; line = 120; symbol = 'Parse'
    summary = 'Null deref on empty input'; failure_scenario = 'Empty list throws'
}
$withSymbolB = [pscustomobject]@{
    repo = 'acme/widgets'; pr = '7'; category = 'risk'; file = 'src/a.cs'
    side = 'RIGHT'; line = 480; symbol = 'Render'
    summary = 'Null deref on empty input'; failure_scenario = 'Empty list throws'
}
Assert-True 'a symbol tells two identically-worded findings apart' `
    ((Get-FindingSemanticFingerprint -Finding $withSymbolA) -ne (Get-FindingSemanticFingerprint -Finding $withSymbolB))
$withSymbolAMoved = [pscustomobject]@{
    repo = 'acme/widgets'; pr = '7'; category = 'risk'; file = 'src/a.cs'
    side = 'RIGHT'; line = 131; symbol = 'Parse'
    summary = 'Null deref on empty input'; failure_scenario = 'Empty list throws'
}
Assert-Equal 'the symbol-keyed finding still survives a line shift' `
    (Get-FindingSemanticFingerprint -Finding $withSymbolA) (Get-FindingSemanticFingerprint -Finding $withSymbolAMoved)

Write-Host ''
Write-Host 'Dedupe matches one prior finding to one current finding'

$dedupeDir = Join-Path ([System.IO.Path]::GetTempPath()) ("pr-review-dedupe-{0}" -f [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $dedupeDir -Force | Out-Null
try {
    # The prior review raised this defect once, at a line that has since shifted.
    $priorPath = Join-Path $dedupeDir 'prior.json'
    Set-Content -LiteralPath $priorPath -Encoding UTF8 -Value (
        ConvertTo-Json -Depth 10 -InputObject @(
            [pscustomobject]@{
                repo = 'acme/widgets'; pr = '7'; category = 'risk'; file = 'src/a.cs'
                severity = 'Medium'; verdict = 'CONFIRMED'; side = 'RIGHT'; line = 41
                summary = 'Null deref on empty input'; failure_scenario = 'Empty list throws'
            }
        ))

    # This run finds it at two distinct sites, described in the same words.
    $currentPath = Join-Path $dedupeDir 'current.json'
    Set-Content -LiteralPath $currentPath -Encoding UTF8 -Value (
        ConvertTo-Json -Depth 10 -InputObject @(
            [pscustomobject]@{
                repo = 'acme/widgets'; pr = '7'; category = 'risk'; file = 'src/a.cs'
                severity = 'Medium'; verdict = 'CONFIRMED'; side = 'RIGHT'; line = 40
                summary = 'Null deref on empty input'; failure_scenario = 'Empty list throws'
            },
            [pscustomobject]@{
                repo = 'acme/widgets'; pr = '7'; category = 'risk'; file = 'src/a.cs'
                severity = 'Medium'; verdict = 'CONFIRMED'; side = 'RIGHT'; line = 200
                summary = 'Null deref on empty input'; failure_scenario = 'Empty list throws'
            }
        ))

    $dedupe = Invoke-Dedupe -FindingsPath $currentPath -PriorPath $priorPath | ConvertFrom-Json
    Assert-Equal 'one prior finding silences exactly one of two same-wording findings' 1 $dedupe.keptCount
    Assert-Equal 'the other same-wording finding is dropped as semantic' 1 $dedupe.droppedCount
    Assert-True 'the surviving finding keeps its own location' `
        (@($dedupe.kept).Count -eq 1 -and @($dedupe.kept)[0].line -in @(40, 200))

    # An unchanged rerun still dedupes both: two prior occurrences, two drops.
    $dedupeSelf = Invoke-Dedupe -FindingsPath $currentPath -PriorPath $currentPath | ConvertFrom-Json
    Assert-Equal 'a rerun against itself still drops every repeat' 0 $dedupeSelf.keptCount
    Assert-Equal 'both repeats are recognised, not just the first' 2 $dedupeSelf.droppedCount

    # A prior document that lists the same finding twice — once as a finding,
    # once as a bare semantic fingerprint — is one prior finding, not two, so it
    # must not buy a second drop.
    $priorFinding = [pscustomobject]@{
        repo = 'acme/widgets'; pr = '7'; category = 'risk'; file = 'src/a.cs'
        severity = 'Medium'; verdict = 'CONFIRMED'; side = 'RIGHT'; line = 41
        summary = 'Null deref on empty input'; failure_scenario = 'Empty list throws'
    }
    $doubleListedPath = Join-Path $dedupeDir 'prior-double-listed.json'
    Set-Content -LiteralPath $doubleListedPath -Encoding UTF8 -Value (
        ConvertTo-Json -Depth 10 -InputObject ([pscustomobject]@{
                findings            = @($priorFinding)
                semanticFingerprints = @(Get-FindingSemanticFingerprint -Finding $priorFinding)
            }))
    $dedupeDouble = Invoke-Dedupe -FindingsPath $currentPath -PriorPath $doubleListedPath | ConvertFrom-Json
    Assert-Equal 'one finding listed twice in prior state still silences only one' 1 $dedupeDouble.keptCount
}
finally {
    Remove-Item -LiteralPath $dedupeDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# End-to-end against a fake gh.
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host 'End-to-end (-Resolve / -Post) against a fake gh'

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("pr-review-selftest-{0}" -f [guid]::NewGuid().ToString('n'))
$fixtures = Join-Path $sandbox 'fixtures'
$shimDir = Join-Path $sandbox 'bin'
$tempHome = Join-Path $sandbox 'temp'
New-Item -ItemType Directory -Path $fixtures -Force | Out-Null
New-Item -ItemType Directory -Path $shimDir -Force | Out-Null
New-Item -ItemType Directory -Path $tempHome -Force | Out-Null

$headSha = '2222222222222222222222222222222222222222'
$baseSha = '1111111111111111111111111111111111111111'

# Two pages, one file each — plus brackets inside a patch string.
Set-Content -LiteralPath (Join-Path $fixtures 'files.json') -Encoding UTF8 -Value @'
[{"filename":"src/a.cs","status":"modified","patch":"@@ -1,2 +1,3 @@\n var x = new[] { 1 };\n+added\n"}]
[{"filename":"src/b.cs","status":"modified","patch":"@@ -1,2 +1,3 @@\n context\n+added\n"}]
'@

# compare/<base>...<head> wraps its files in an envelope and carries that array
# on the first page only — later pages continue the commit list. Modelling
# `files` on every page hid the 300-file cap entirely.
Set-Content -LiteralPath (Join-Path $fixtures 'compare.json') -Encoding UTF8 -Value @'
{"status":"ahead","files":[{"filename":"src/a.cs","status":"modified","patch":"@@ -1,2 +1,3 @@\n var x = new[] { 1 };\n+added\n"},{"filename":"src/b.cs","status":"modified","patch":"@@ -1,2 +1,3 @@\n context\n+added\n"}]}
{"status":"ahead"}
'@

# The boundary that a compare-only map cannot see: compare/ truncates its file
# list at 300 entries, so file 301 of a 301-file PR is simply absent.
$bigPatch = '"status":"modified","patch":"@@ -1,2 +1,3 @@\n context\n+added\n"'
$first300 = (1..300 | ForEach-Object { '{"filename":"src/f' + $_ + '.cs",' + $bigPatch + '}' }) -join ','
$file301 = '{"filename":"src/f301.cs",' + $bigPatch + '}'
Set-Content -LiteralPath (Join-Path $fixtures 'compare-capped.json') -Encoding UTF8 -Value @(
    '{"status":"ahead","files":[' + $first300 + ']}'
    '{"status":"ahead"}'
)
Set-Content -LiteralPath (Join-Path $fixtures 'files-301.json') -Encoding UTF8 -Value @(
    '[' + $first300 + ']'
    '[' + $file301 + ']'
)

# A GraphQL partial success: HTTP 200 carrying both data and top-level errors.
Set-Content -LiteralPath (Join-Path $fixtures 'threads-partial.json') -Encoding UTF8 -Value @'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}},
 "errors":[{"message":"Although you appear to have the correct authorization credentials, the org has enabled OAuth App access restrictions"}]}
'@

Set-Content -LiteralPath (Join-Path $fixtures 'commits.json') -Encoding UTF8 -Value @"
[{"sha":"$headSha","commit":{"message":"work"}}]
"@

Set-Content -LiteralPath (Join-Path $fixtures 'empty.json') -Encoding UTF8 -Value '[]'

Set-Content -LiteralPath (Join-Path $fixtures 'threads.json') -Encoding UTF8 -Value @'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}
'@

Set-Content -LiteralPath (Join-Path $fixtures 'check-runs.json') -Encoding UTF8 -Value @'
{"total_count":1,"check_runs":[{"name":"build","conclusion":"success"}]}
{"total_count":1,"check_runs":[{"name":"lint","conclusion":"success"}]}
'@

$shimScript = Join-Path $shimDir 'gh-shim.ps1'
Set-Content -LiteralPath $shimScript -Encoding UTF8 -Value @'
[CmdletBinding(PositionalBinding = $false)]
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$CommandArgs)

$joined = ($CommandArgs -join ' ')
Add-Content -LiteralPath $env:PRREVIEW_TEST_LOG -Value $joined

function Emit([string]$Name) {
    Write-Output (Get-Content -LiteralPath (Join-Path $env:PRREVIEW_TEST_FIXTURES $Name) -Raw)
    exit 0
}

# The PR view is rendered from the environment so a test can move base or head
# under a run that already pinned them.
if ($joined -match 'pulls/7$' -or ($joined -match 'pulls/7 ' -and $joined -notmatch 'pulls/7/')) {
    $pr = [ordered]@{
        number        = 7
        title         = 'Test PR'
        html_url      = 'https://github.com/acme/widgets/pull/7'
        changed_files = [int]$env:PRREVIEW_TEST_CHANGED_FILES
        base          = [ordered]@{ sha = $env:PRREVIEW_TEST_BASE; ref = 'main' }
        head          = [ordered]@{ sha = $env:PRREVIEW_TEST_HEAD; ref = 'feature/x' }
    }
    Write-Output (ConvertTo-Json $pr -Depth 20)
    exit 0
}

# Posting appends to a mutable review list, so a later GET sees what was posted.
# That is what lets the test simulate a crash after a successful POST.
if ($joined -match '--method\s+POST' -and $joined -match 'pulls/7/reviews') {
    $inputPath = $null
    for ($i = 0; $i -lt $CommandArgs.Count - 1; $i++) {
        if ($CommandArgs[$i] -eq '--input') { $inputPath = $CommandArgs[$i + 1]; break }
    }
    $body = ''
    if ($inputPath -and (Test-Path -LiteralPath $inputPath)) {
        $body = [string](Get-Content -LiteralPath $inputPath -Raw | ConvertFrom-Json).body
    }
    $db = @(Get-Content -LiteralPath $env:PRREVIEW_TEST_REVIEWS_DB -Raw | ConvertFrom-Json)
    $id = 4242 + $db.Count
    $review = [pscustomobject]@{ id = $id; state = 'COMMENTED'; body = $body; submitted_at = '2026-08-10T00:00:00Z' }
    $next = @($db) + @($review)
    Set-Content -LiteralPath $env:PRREVIEW_TEST_REVIEWS_DB -Encoding UTF8 `
        -Value (ConvertTo-Json @($next) -Depth 20)
    Write-Output (ConvertTo-Json $review -Depth 20)
    exit 0
}

if ($joined -match 'reviews/\d+/comments') { Emit 'empty.json' }
if ($joined -match '^api graphql')         { Emit $env:PRREVIEW_TEST_THREADS }
if ($joined -match 'check-runs')           { Emit 'check-runs.json' }
if ($joined -match 'compare/') {
    if ($env:PRREVIEW_TEST_BIG -eq '1') { Emit 'compare-capped.json' }
    Emit 'compare.json'
}
if ($joined -match 'pulls/7/files') {
    if ($env:PRREVIEW_TEST_BIG -eq '1') { Emit 'files-301.json' }
    Emit 'files.json'
}
if ($joined -match 'pulls/7/commits')      { Emit 'commits.json' }
if ($joined -match 'pulls/7/reviews') {
    Write-Output (Get-Content -LiteralPath $env:PRREVIEW_TEST_REVIEWS_DB -Raw)
    exit 0
}

Write-Error "fake gh: unexpected arguments: $joined"
exit 1
'@

if ($IsWindows) {
    Set-Content -LiteralPath (Join-Path $shimDir 'gh.cmd') -Encoding Ascii -Value @(
        '@echo off'
        'pwsh -NoProfile -File "%~dp0gh-shim.ps1" %*'
        'exit /b %ERRORLEVEL%'
    )
}
else {
    $unixShim = Join-Path $shimDir 'gh'
    Set-Content -LiteralPath $unixShim -Encoding UTF8 -Value @(
        '#!/bin/sh'
        'exec pwsh -NoProfile -File "$(dirname "$0")/gh-shim.ps1" "$@"'
    )
    & chmod +x $unixShim
}

$ghLog = Join-Path $sandbox 'gh-calls.log'
Set-Content -LiteralPath $ghLog -Value '' -Encoding UTF8

$reviewsDb = Join-Path $sandbox 'reviews-db.json'
Set-Content -LiteralPath $reviewsDb -Value '[]' -Encoding UTF8

$script:testBase = $baseSha
$script:testThreads = 'threads.json'
$script:testBig = '0'
$script:testChangedFiles = '2'

function Invoke-Helper {
    param([string[]]$HelperArgs)

    $sep = [System.IO.Path]::PathSeparator
    $env:PATH = "$shimDir$sep$($script:originalPath)"
    $env:PRREVIEW_TEST_FIXTURES = $fixtures
    $env:PRREVIEW_TEST_LOG = $ghLog
    $env:PRREVIEW_TEST_HEAD = $headSha
    $env:PRREVIEW_TEST_BASE = $script:testBase
    $env:PRREVIEW_TEST_THREADS = $script:testThreads
    $env:PRREVIEW_TEST_REVIEWS_DB = $reviewsDb
    $env:PRREVIEW_TEST_BIG = $script:testBig
    $env:PRREVIEW_TEST_CHANGED_FILES = $script:testChangedFiles
    # Keep every workspace this test creates inside the sandbox.
    $env:TMPDIR = $tempHome
    $env:TEMP = $tempHome
    $env:TMP = $tempHome

    $out = & pwsh -NoProfile -File $helper @HelperArgs 2>&1 | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = $out }
}

function Get-PostCount {
    return @(Get-Content -LiteralPath $ghLog | Where-Object { $_ -match '--method POST' }).Count
}

$script:originalPath = $env:PATH
$originalTmpdir = $env:TMPDIR
$originalTemp = $env:TEMP
$originalTmp = $env:TMP

try {
    $target = 'https://github.com/acme/widgets/pull/7'

    # ── Resolve: the multi-page fetch that used to abort ─────────────────────
    $resolve1 = Invoke-Helper -HelperArgs @('-Resolve', $target)
    Assert-Equal 'resolve succeeds against a multi-page PR' 0 $resolve1.ExitCode
    if ($resolve1.ExitCode -ne 0) { Write-Host $resolve1.Text -ForegroundColor DarkYellow }

    $workspace = $null
    if ($resolve1.Text -match '(?m)^workspace:\s*(.+)$') { $workspace = $Matches[1].Trim() }
    Assert-True 'resolve reports a workspace' (-not [string]::IsNullOrWhiteSpace($workspace))

    if ($workspace -and (Test-Path -LiteralPath $workspace)) {
        $changed = @(Get-Content -LiteralPath (Join-Path $workspace 'changed-files.json') -Raw | ConvertFrom-Json)
        Assert-Equal 'both pages of changed files survive pagination' 2 $changed.Count
        Assert-True 'a patch containing brackets round-trips intact' `
            (@($changed | Where-Object { $_.patch -match 'new\[\] \{ 1 \}' }).Count -eq 1)

        $ci = Get-Content -LiteralPath (Join-Path $workspace 'ci.json') -Raw | ConvertFrom-Json
        Assert-Equal 'both pages of check runs survive pagination' 2 @($ci.check_runs).Count

        $threadState = Get-Content -LiteralPath (Join-Path $workspace 'review-threads.json') -Raw | ConvertFrom-Json
        Assert-True 'thread coverage is recorded as complete' ([bool]$threadState.complete)

        $pinned1 = Get-Content -LiteralPath (Join-Path $workspace 'pinned.json') -Raw | ConvertFrom-Json
        Assert-True 'resolve mints a run id' (-not [string]::IsNullOrWhiteSpace([string]$pinned1.runId))
        Assert-True 'the run owns its own directory' `
            ((Split-Path -Leaf $workspace) -eq [string]$pinned1.runId)
        Assert-True 'the run directory sits under runs/' `
            ((Split-Path -Leaf (Split-Path -Parent $workspace)) -eq 'runs')

        # ── Post: first publish ──────────────────────────────────────────────
        $payloadPath = Join-Path $workspace 'review.input.json'
        Set-Content -LiteralPath $payloadPath -Encoding UTF8 -Value @"
{"commit_id":"$headSha","event":"COMMENT","body":"Summary for run one.","comments":[]}
"@
        $postsBefore = Get-PostCount
        $post1 = Invoke-Helper -HelperArgs @('-Post', '-Payload', $payloadPath)
        Assert-Equal 'first post succeeds' 0 $post1.ExitCode
        if ($post1.ExitCode -ne 0) { Write-Host $post1.Text -ForegroundColor DarkYellow }
        Assert-Equal 'first post reaches GitHub' ($postsBefore + 1) (Get-PostCount)
        $receipt1 = Join-Path $workspace 'post-result.json'
        Assert-True 'the receipt lands in the run directory' (Test-Path -LiteralPath $receipt1)
        Assert-True 'the line map is built from the pinned compare, not the PR files view' `
            (@(Get-Content -LiteralPath $ghLog | Where-Object { $_ -match "compare/$baseSha\.\.\.$headSha" }).Count -ge 1)
        Assert-True 'the published body carries the run marker' `
            ((Get-Content -LiteralPath (Join-Path $workspace 'review.json') -Raw) -match [regex]::Escape($pinned1.runId))

        # ── Post again, same run: a retry must stay idempotent ───────────────
        $postsBefore = Get-PostCount
        $post2 = Invoke-Helper -HelperArgs @('-Post', '-Payload', $payloadPath)
        Assert-Equal 'retrying the same run succeeds' 0 $post2.ExitCode
        Assert-True 'retrying the same run is a no-op' ($post2.Text -match 'idempotent no-op')
        Assert-Equal 'retrying the same run posts nothing new' $postsBefore (Get-PostCount)

        # ── Crash after a successful POST: the retry must reconcile ──────────
        # The receipt is written after GitHub creates the review, so a process
        # that died in between used to republish. The run marker closes that.
        Remove-Item -LiteralPath $receipt1 -Force
        $postsBefore = Get-PostCount
        $post2b = Invoke-Helper -HelperArgs @('-Post', '-Payload', $payloadPath)
        Assert-Equal 'a retry with no receipt succeeds' 0 $post2b.ExitCode
        Assert-Equal 'a retry with no receipt posts no duplicate' $postsBefore (Get-PostCount)
        Assert-True 'the retry recovers the receipt from the run marker' `
            ($post2b.Text -match 'already published review')
        Assert-True 'the recovered receipt is written back' (Test-Path -LiteralPath $receipt1)

        # ── -RunId must match the run that owns the payload ──────────────────
        $wrongRun = Invoke-Helper -HelperArgs @('-Post', '-Payload', $payloadPath, '-RunId', 'not-this-run')
        Assert-Equal 'posting with a foreign run id fails' 1 $wrongRun.ExitCode
        Assert-True 'the foreign run id is named in the error' ($wrongRun.Text -match 'not-this-run')

        # ── Re-review the same head: a new run must publish ──────────────────
        $resolve2 = Invoke-Helper -HelperArgs @('-Resolve', $target)
        Assert-Equal 'a second resolve on the same head succeeds' 0 $resolve2.ExitCode
        $workspace2 = $null
        if ($resolve2.Text -match '(?m)^workspace:\s*(.+)$') { $workspace2 = $Matches[1].Trim() }
        Assert-True 'the second run gets a different directory' ($workspace2 -ne $workspace)
        $pinned2 = Get-Content -LiteralPath (Join-Path $workspace2 'pinned.json') -Raw | ConvertFrom-Json
        Assert-True 'a second resolve mints a different run id' ([string]$pinned2.runId -ne [string]$pinned1.runId)
        $pinned1Again = Get-Content -LiteralPath (Join-Path $workspace 'pinned.json') -Raw | ConvertFrom-Json
        Assert-Equal 'the first run''s pinned state is untouched by the second' `
            ([string]$pinned1.runId) ([string]$pinned1Again.runId)

        $payloadPath2 = Join-Path $workspace2 'review.input.json'
        Set-Content -LiteralPath $payloadPath2 -Encoding UTF8 -Value @"
{"commit_id":"$headSha","event":"COMMENT","body":"Summary for run two, with a new finding.","comments":[]}
"@
        $postsBefore = Get-PostCount
        $post3 = Invoke-Helper -HelperArgs @('-Post', '-Payload', $payloadPath2)
        Assert-Equal 'the new run posts successfully' 0 $post3.ExitCode
        Assert-Equal 'an explicit re-review of an unchanged head still publishes' ($postsBefore + 1) (Get-PostCount)

        # ── A base-branch advance must abort publication ─────────────────────
        # Checking only head.sha left this undetected, yet moving the base
        # changes what the diff means.
        $resolve3 = Invoke-Helper -HelperArgs @('-Resolve', $target)
        Assert-Equal 'a third resolve succeeds' 0 $resolve3.ExitCode
        $workspace3 = $null
        if ($resolve3.Text -match '(?m)^workspace:\s*(.+)$') { $workspace3 = $Matches[1].Trim() }
        $payloadPath3 = Join-Path $workspace3 'review.input.json'
        Set-Content -LiteralPath $payloadPath3 -Encoding UTF8 -Value @"
{"commit_id":"$headSha","event":"COMMENT","body":"Summary for run three.","comments":[]}
"@
        $script:testBase = '9999999999999999999999999999999999999999'
        $postsBefore = Get-PostCount
        $post4 = Invoke-Helper -HelperArgs @('-Post', '-Payload', $payloadPath3)
        $script:testBase = $baseSha
        Assert-Equal 'a moved base aborts the post' 1 $post4.ExitCode
        Assert-True 'the abort names the base as the mover' ($post4.Text -match 'base moved')
        Assert-Equal 'a moved base publishes nothing' $postsBefore (Get-PostCount)

        # ── GraphQL partial success is incomplete coverage, not clean ────────
        $script:testThreads = 'threads-partial.json'
        $resolve4 = Invoke-Helper -HelperArgs @('-Resolve', $target)
        $script:testThreads = 'threads.json'
        Assert-Equal 'resolve survives a partial GraphQL response' 0 $resolve4.ExitCode
        $workspace4 = $null
        if ($resolve4.Text -match '(?m)^workspace:\s*(.+)$') { $workspace4 = $Matches[1].Trim() }
        $threadState4 = Get-Content -LiteralPath (Join-Path $workspace4 'review-threads.json') -Raw | ConvertFrom-Json
        Assert-True 'top-level GraphQL errors mark coverage incomplete' (-not [bool]$threadState4.complete)
        Assert-True 'the GraphQL error message is preserved' `
            ([string]$threadState4.incompleteReason -match 'OAuth App access restrictions')
        Assert-True 'incomplete thread coverage is reported to the caller' `
            ($resolve4.Text -match 'threadCoverage: INCOMPLETE')

        # ── A payload outside its canonical run directory is refused ─────────
        # pinned.json was trusted purely for sitting beside the payload, so a
        # crafted pair could name the authenticated destination while routing
        # the review, the receipt, and the fallback through a directory this
        # helper never created.
        $forgedDir = Join-Path $sandbox 'forged-run'
        New-Item -ItemType Directory -Path $forgedDir -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $workspace 'pinned.json') -Destination $forgedDir
        $forgedPayload = Join-Path $forgedDir 'review.input.json'
        Set-Content -LiteralPath $forgedPayload -Encoding UTF8 -Value @"
{"commit_id":"$headSha","event":"COMMENT","body":"Summary from a directory the helper never created.","comments":[]}
"@
        $postsBefore = Get-PostCount
        $forgedPost = Invoke-Helper -HelperArgs @('-Post', '-Payload', $forgedPayload)
        Assert-Equal 'posting from outside the canonical run directory fails' 1 $forgedPost.ExitCode
        Assert-True 'the refusal says where the run belongs' ($forgedPost.Text -match 'belongs in')
        Assert-Equal 'a non-canonical workspace publishes nothing' $postsBefore (Get-PostCount)
        Assert-True 'no receipt is written into the non-canonical directory' `
            (-not (Test-Path -LiteralPath (Join-Path $forgedDir 'post-result.json')))
        Assert-True 'no review payload is written into the non-canonical directory' `
            (-not (Test-Path -LiteralPath (Join-Path $forgedDir 'review.json')))

        # ── A 301-file PR still maps inline ─────────────────────────────────
        # compare/ stops at 300 files, so a compare-only map treated every
        # finding past the cap as an unmappable location.
        $script:testBig = '1'
        $script:testChangedFiles = '301'
        $resolve5 = Invoke-Helper -HelperArgs @('-Resolve', $target)
        Assert-Equal 'resolve succeeds on a 301-file PR' 0 $resolve5.ExitCode
        $workspace5 = $null
        if ($resolve5.Text -match '(?m)^workspace:\s*(.+)$') { $workspace5 = $Matches[1].Trim() }
        $payloadPath5 = Join-Path $workspace5 'review.input.json'
        Set-Content -LiteralPath $payloadPath5 -Encoding UTF8 -Value @"
{"commit_id":"$headSha","event":"COMMENT","body":"Summary for the large PR.","comments":[{"path":"src/f301.cs","line":2,"side":"RIGHT","body":"Past the compare cap."}]}
"@
        $post5 = Invoke-Helper -HelperArgs @('-Post', '-Payload', $payloadPath5)
        $script:testBig = '0'
        $script:testChangedFiles = '2'
        Assert-Equal 'the 301-file PR posts' 0 $post5.ExitCode
        if ($post5.ExitCode -ne 0) { Write-Host $post5.Text -ForegroundColor DarkYellow }
        Assert-True 'the map falls back to the paginated file list past the cap' `
            ($post5.Text -match 'fileMapSource: pulls/7/files')
        Assert-True 'the fallback map is not reported incomplete' `
            (-not ($post5.Text -match 'fileMapCoverage: INCOMPLETE'))
        $map5 = @(Get-Content -LiteralPath (Join-Path $workspace5 'changed-files.json') -Raw | ConvertFrom-Json)
        Assert-Equal 'the pinned map holds every changed file, not the first 300' 301 $map5.Count
        $posted5 = Get-Content -LiteralPath (Join-Path $workspace5 'review.json') -Raw | ConvertFrom-Json
        Assert-Equal 'a finding past the 300-file cap stays inline' 1 @($posted5.comments).Count
        Assert-True 'nothing is demoted to the summary on a 301-file PR' `
            (-not ([string]$posted5.body -match 'Unmappable findings'))
    }
    else {
        Assert-True 'workspace exists on disk' $false
    }
}
finally {
    $env:PATH = $script:originalPath
    $env:TMPDIR = $originalTmpdir
    $env:TEMP = $originalTemp
    $env:TMP = $originalTmp
    foreach ($name in @('PRREVIEW_TEST_FIXTURES', 'PRREVIEW_TEST_LOG', 'PRREVIEW_TEST_HEAD',
            'PRREVIEW_TEST_BASE', 'PRREVIEW_TEST_THREADS', 'PRREVIEW_TEST_REVIEWS_DB',
            'PRREVIEW_TEST_BIG', 'PRREVIEW_TEST_CHANGED_FILES')) {
        Remove-Item -LiteralPath "Env:\$name" -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failures -gt 0) {
    Write-Host "$failures of $checks checks FAILED" -ForegroundColor Red
    exit 1
}
Write-Host "$checks checks passed" -ForegroundColor Green
exit 0
