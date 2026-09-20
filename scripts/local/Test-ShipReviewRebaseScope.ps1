#!/usr/bin/env pwsh
# DEV-209 repository-local proof for ship-review post-rebase scope semantics.
# Exercises positive git/range behavior, empty-delta confirmation, artifact-field
# synchronization, malformed-range fail-closed transport, and base.

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '_Get-ShipReviewRebaseDelta.ps1')

$checks = 0
$failures = 0
$temporaryRoots = [System.Collections.Generic.List[string]]::new()

function Assert-That {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Condition,
        [string]$Detail = ''
    )

    $script:checks++
    if ($Condition) {
        Write-Host "  ok    $Name"
    }
    else {
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        if ($Detail) { Write-Host "        $Detail" -ForegroundColor DarkGray }
        $script:failures++
    }
}

function New-TempRepoRoot {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("dev209-scope-" + [Guid]::NewGuid().ToString('n'))
    $temporaryRoots.Add($root) | Out-Null
    return $root
}

try {
    Write-Host "DEV-209 ship-review rebase-delta scope tests"
    Write-Host "cwd: $repoRoot"

    $cleanRoot = New-TempRepoRoot
    $clean = New-ShipReviewRebaseFixtureRepo -Root $cleanRoot -Scenario clean
    Assert-That 'post-rebase stage-9-cleared is not an ancestor of HEAD' `
        (-not $clean.IsAncestor) `
        "stage9=$($clean.Stage9) head=$($clean.Head)"
    $cleanScope = Get-ShipReviewRebaseDeltaScope -RepoRoot $cleanRoot -Stage9Cleared $clean.Stage9
    Assert-That 'clean rebase delta is empty under patch-id / range-diff semantics' `
        $cleanScope.IsEmpty `
        $cleanScope.RangeDiffOutput
    Assert-That 'three-dot merge-base diff would expand beyond the filtered delta on clean rebase' `
        (($cleanScope.ThreeDotFiles.Count -gt 0) -and ($cleanScope.ChangedFiles.Count -eq 0)) `
        ("three-dot=$($cleanScope.ThreeDotFiles -join ', '); filtered=$($cleanScope.ChangedFiles -join ', ')")

    $conflictRoot = New-TempRepoRoot
    $conflict = New-ShipReviewRebaseFixtureRepo -Root $conflictRoot -Scenario conflict-edit
    $conflictScope = Get-ShipReviewRebaseDeltaScope -RepoRoot $conflictRoot -Stage9Cleared $conflict.Stage9
    Assert-That 'conflict-resolution rebase delta is non-empty' `
        (-not $conflictScope.IsEmpty) `
        $conflictScope.RangeDiffOutput
    Assert-That 'non-empty delta scopes to the resolution file only' `
        (($conflictScope.ChangedFiles.Count -eq 1) -and ($conflictScope.ChangedFiles[0] -eq 'feature.txt')) `
        ("changed=$($conflictScope.ChangedFiles -join ', ')")
    $conflictFilteredCommits = @($conflictScope.FilteredCommits)
    $conflictCommitLines = @($conflictScope.FilteredCommitList)
    Assert-That 'non-empty delta filtered commit list matches the delta commits' `
        (($conflictFilteredCommits.Count -gt 0) -and
         ($conflictCommitLines.Count -eq $conflictFilteredCommits.Count) -and
         ($conflictCommitLines -join '|' -match 'feat1')) `
        ("commits=$($conflictCommitLines -join '; ')")

    $multiRoot = New-TempRepoRoot
    $multi = New-ShipReviewRebaseFixtureRepo -Root $multiRoot -Scenario multi-commit
    $multiScope = Get-ShipReviewRebaseDeltaScope -RepoRoot $multiRoot -Stage9Cleared $multi.Stage9
    Assert-That 'cleared multi-commit feature replayed by rebase stays empty when stage-9 cleared the tip' `
        $multiScope.IsEmpty `
        $multiScope.RangeDiffOutput

    Assert-That 'artifact diff_range uses the discriminated ship-review transport' `
        ($cleanScope.DiffRange -match '^Explicit ship-review rebase-delta range: [0-9a-f]{40}\.\.HEAD$') `
        $cleanScope.DiffRange
    Assert-That 'artifact fixed_point matches the stage-9-cleared commit' `
        ($cleanScope.FixedPoint -eq $cleanScope.Stage9Cleared) `
        "fixed_point=$($cleanScope.FixedPoint)"
    Assert-That 'artifact diff command matches the filtered range-diff command' `
        ($cleanScope.DiffCommand -eq "git range-diff $($cleanScope.OldBase)..$($cleanScope.Stage9Cleared) $($cleanScope.NewBase)..$($cleanScope.HeadSha)") `
        $cleanScope.DiffCommand
    Assert-That 'empty delta keeps an empty filtered commit list' `
        (@($cleanScope.FilteredCommits).Count -eq 0) `
        "commits=$(@($cleanScope.FilteredCommits).Count)"

    $goodTransport = "Explicit ship-review rebase-delta range: $($clean.Stage9)..HEAD"
    $goodThreeDot = "Explicit diff range: $($clean.Stage9)...HEAD"
    Assert-That 'discriminated ship-review transport accepts a valid two-dot range' `
        (Test-ShipReviewRebaseDeltaTransport -Line $goodTransport).Ok `
        $goodTransport
    Assert-That 'ordinary explicit diff range accepts a valid three-dot range' `
        (Test-ExplicitDiffRangeTransport -Line $goodThreeDot).Ok `
        $goodThreeDot
    Assert-That 'ordinary explicit diff range rejects a dropped-dot two-dot typo' `
        (-not (Test-ExplicitDiffRangeTransport -Line "Explicit diff range: $($clean.Stage9)..HEAD").Ok) `
        'ROUND_BASE..HEAD must fail closed on the common three-dot field'
    Assert-That 'ordinary explicit diff range rejects a dash-prefixed endpoint' `
        (-not (Test-ExplicitDiffRangeTransport -Line 'Explicit diff range: -bad...HEAD').Ok) `
        'dash-prefixed endpoints must fail closed on the common field'
    Assert-That 'ordinary explicit diff range rejects whitespace in the value' `
        (-not (Test-ExplicitDiffRangeTransport -Line "Explicit diff range: $($clean.Stage9) ...HEAD").Ok) `
        'whitespace-bearing range values must fail closed'
    Assert-That 'discriminated ship-review transport rejects a three-dot range' `
        (-not (Test-ShipReviewRebaseDeltaTransport -Line "Explicit ship-review rebase-delta range: $($clean.Stage9)...HEAD").Ok) `
        'ship-review transport must reject three-dot ranges'
    Assert-That 'discriminated ship-review transport rejects a dash-prefixed endpoint' `
        (-not (Test-ShipReviewRebaseDeltaTransport -Line 'Explicit ship-review rebase-delta range: -bad..HEAD').Ok) `
        'dash-prefixed endpoints must fail closed'

    $missingRef = '0000000000000000000000000000000000000000'
    $missingThrown = $false
    try {
        Get-ShipReviewRebaseDeltaScope -RepoRoot $cleanRoot -Stage9Cleared $missingRef | Out-Null
    }
    catch {
        $missingThrown = $true
    }
    Assert-That 'unresolved stage-9-cleared commit fails closed' $missingThrown 'expected exception for missing ref'

    $consumerOk = Test-ShipReviewArtifactConsumer -Scope $cleanScope -ConsumerHeadSha $cleanScope.HeadSha `
        -ConsumerDiffRange $cleanScope.DiffRange -ConsumerFixedPoint $cleanScope.FixedPoint
    Assert-That 'artifact consumer accepts synchronized head_sha fixed_point and diff_range' `
        $consumerOk.Ok `
        $consumerOk.Reason
    $consumerHeadMismatch = Test-ShipReviewArtifactConsumer -Scope $cleanScope `
        -ConsumerHeadSha ('0' * 40)
    Assert-That 'artifact consumer fails closed on head_sha mismatch' `
        (-not $consumerHeadMismatch.Ok) `
        $consumerHeadMismatch.Reason
    $consumerRangeMismatch = Test-ShipReviewArtifactConsumer -Scope $cleanScope `
        -ConsumerHeadSha $cleanScope.HeadSha -ConsumerDiffRange 'Explicit ship-review rebase-delta range: deadbeef..HEAD'
    Assert-That 'artifact consumer fails closed on diff_range mismatch' `
        (-not $consumerRangeMismatch.Ok) `
        $consumerRangeMismatch.Reason

    $freshRoot = New-TempRepoRoot
    New-ShipReviewRebaseFixtureRepo -Root $freshRoot -Scenario clean | Out-Null
    $freshnessProof = Test-OriginMainRefFreshness -RepoRoot $freshRoot
    Assert-That 'origin/main freshness is established by fetch before use' `
        $freshnessProof.Ok `
        $freshnessProof.Detail

    $baseProof = Test-BranchBasedOnOriginMain -RepoRoot $repoRoot
    Assert-That 'branch is based on origin/main' `
        ($baseProof.Ok -and -not [string]::IsNullOrWhiteSpace($baseProof.Detail)) `
        $baseProof.Detail

    $n1Root = New-TempRepoRoot
    New-ShipReviewRebaseFixtureRepo -Root $n1Root -Scenario clean | Out-Null
    # Divergent HEAD: commit on a root not reachable from origin/main.
    Invoke-GitAtRoot -RepoRoot $n1Root -ArgumentList @('checkout','-q','--orphan','divergent') | Out-Null
    Invoke-GitAtRoot -RepoRoot $n1Root -ArgumentList @('commit','-q','--allow-empty','-m','divergent-root') | Out-Null
    $n1 = Test-BranchBasedOnOriginMain -RepoRoot $n1Root
    Assert-That 'branch not based on origin/main fails closed' `
        ($n1.Ok -eq $false) `
        $n1.Detail

    $n2Root = New-TempRepoRoot
    New-Item -ItemType Directory -Force -Path $n2Root | Out-Null
    Invoke-GitAtRoot -RepoRoot $n2Root -ArgumentList @('init','-q') | Out-Null
    if (-not (Test-Path -LiteralPath (Join-Path $n2Root '.git'))) {
        throw "N2 fixture: git init failed in $n2Root"
    }
    Assert-That 'origin/main resolution fails closed when no origin remote exists' `
        (-not (Ensure-OriginMainRef -RepoRoot $n2Root)) `
        'Ensure-OriginMainRef must return false when the origin remote cannot be resolved'
}
finally {
    foreach ($root in $temporaryRoots) {
        if (Test-Path -LiteralPath $root) {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host ""
Write-Host "checks=$checks failures=$failures"
if ($failures -gt 0) {
    exit 1
}

Write-Host 'DEV-209 ship-review rebase-delta scope tests passed.'
exit 0
