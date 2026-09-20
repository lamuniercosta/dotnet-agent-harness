# Shared git semantics for DEV-209 ship-review rebase-delta scope.
# Implements the patch-id-filtered / git range-diff contract from
# skills/ship-review/SKILL.md, skills/code-review/SKILL.md, and ADR 0014.
# Dot-sourced by scripts/local/Test-ShipReviewRebaseScope.ps1.
#
# Merge commits and empty commits may yield no patch-id from git patch-id;
# those commits are treated conservatively as delta commits (included), not
# silently dropped.

Set-StrictMode -Version Latest

function Invoke-GitAtRoot {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string[]]$ArgumentList
    )

    try {
        $raw = & git -C $RepoRoot @ArgumentList 2>&1
        $code = $LASTEXITCODE
    }
    catch {
        return [pscustomobject]@{
            Ok       = $false
            ExitCode = 1
            Output   = $_.Exception.Message
        }
    }

    if ($null -eq $code) {
        return [pscustomobject]@{
            Ok       = $false
            ExitCode = 1
            Output   = 'git did not report an exit code'
        }
    }

    $text = ''
    if ($null -ne $raw) {
        $text = (@($raw) | ForEach-Object { "$_" }) -join "`n"
    }

    return [pscustomobject]@{
        Ok       = ([int]$code -eq 0)
        ExitCode = [int]$code
        Output   = $text
    }
}

function Get-GitPatchId {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Commit
    )

    $show = Invoke-GitAtRoot -RepoRoot $RepoRoot -ArgumentList @('show', $Commit)
    if (-not $show.Ok) {
        return $null
    }

    $patchId = ($show.Output | & git -C $RepoRoot patch-id --stable 2>&1)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($patchId)) {
        return $null
    }

    return ($patchId.ToString().Trim().Split()[0])
}

function Get-GitPatchIdSet {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$RevRange
    )

    $list = Invoke-GitAtRoot -RepoRoot $RepoRoot -ArgumentList @('rev-list', $RevRange)
    if (-not $list.Ok) {
        return @()
    }

    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($commit in ($list.Output -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $patchId = Get-GitPatchId -RepoRoot $RepoRoot -Commit $commit
        if ($patchId) {
            $set.Add($patchId) | Out-Null
        }
    }

    return ,$set
}

function Ensure-OriginMainRef {
    param(
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $remote = Invoke-GitAtRoot -RepoRoot $RepoRoot -ArgumentList @('remote', 'get-url', 'origin')
    if (-not $remote.Ok) {
        return $false
    }

    $fetch = Invoke-GitAtRoot -RepoRoot $RepoRoot -ArgumentList @(
        'fetch', '--no-tags', '--depth=1', 'origin', '+refs/heads/main:refs/remotes/origin/main'
    )
    if (-not $fetch.Ok) {
        return $false
    }

    $verify = Invoke-GitAtRoot -RepoRoot $RepoRoot -ArgumentList @('rev-parse', '--verify', 'origin/main')
    if (-not $verify.Ok) {
        return $false
    }

    $remoteTip = Invoke-GitAtRoot -RepoRoot $RepoRoot -ArgumentList @('ls-remote', 'origin', 'refs/heads/main')
    if (-not $remoteTip.Ok -or [string]::IsNullOrWhiteSpace($remoteTip.Output)) {
        return $false
    }

    $remoteSha = ($remoteTip.Output.Trim().Split()[0])
    $localSha = $verify.Output.Trim()
    return ($remoteSha -eq $localSha)
}

function Test-OriginMainRefFreshness {
    param(
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $staleSha = (Invoke-GitAtRoot -RepoRoot $RepoRoot -ArgumentList @('rev-parse', 'origin/main')).Output.Trim()
    $advance = Invoke-GitAtRoot -RepoRoot $RepoRoot -ArgumentList @('checkout', '-q', 'main')
    if (-not $advance.Ok) {
        return [pscustomobject]@{ Ok = $false; Detail = "could not checkout main: $($advance.Output)" }
    }

    Set-Content -LiteralPath (Join-Path $RepoRoot 'freshness.txt') -Value 'advance' -Encoding utf8
    Invoke-GitAtRoot -RepoRoot $RepoRoot -ArgumentList @('add', 'freshness.txt') | Out-Null
    $commit = Invoke-GitAtRoot -RepoRoot $RepoRoot -ArgumentList @('commit', '-q', '-m', 'advance-main')
    if (-not $commit.Ok) {
        return [pscustomobject]@{ Ok = $false; Detail = "could not advance main: $($commit.Output)" }
    }

    $currentMain = (Invoke-GitAtRoot -RepoRoot $RepoRoot -ArgumentList @('rev-parse', 'HEAD')).Output.Trim()
    $push = Invoke-GitAtRoot -RepoRoot $RepoRoot -ArgumentList @('push', '-q', 'origin', 'main')
    if (-not $push.Ok) {
        return [pscustomobject]@{ Ok = $false; Detail = "could not push advanced main: $($push.Output)" }
    }

    $pinStale = Invoke-GitAtRoot -RepoRoot $RepoRoot -ArgumentList @('update-ref', 'refs/remotes/origin/main', $staleSha)
    if (-not $pinStale.Ok) {
        return [pscustomobject]@{ Ok = $false; Detail = "could not pin stale origin/main: $($pinStale.Output)" }
    }

    $stillStale = (Invoke-GitAtRoot -RepoRoot $RepoRoot -ArgumentList @('rev-parse', 'origin/main')).Output.Trim()
    if ($stillStale -eq $currentMain) {
        return [pscustomobject]@{ Ok = $false; Detail = 'origin/main was not left stale before refresh proof' }
    }

    if (-not (Ensure-OriginMainRef -RepoRoot $RepoRoot)) {
        return [pscustomobject]@{ Ok = $false; Detail = 'Ensure-OriginMainRef failed to refresh stale origin/main' }
    }

    $refreshed = (Invoke-GitAtRoot -RepoRoot $RepoRoot -ArgumentList @('rev-parse', 'origin/main')).Output.Trim()
    if ($refreshed -ne $currentMain) {
        return [pscustomobject]@{
            Ok     = $false
            Detail = "origin/main not fresh after fetch: expected=$currentMain actual=$refreshed stale=$staleSha"
        }
    }

    return [pscustomobject]@{
        Ok     = $true
        Detail = "origin/main refreshed from $staleSha to $refreshed"
    }
}

function Resolve-ShipReviewNewBase {
    param(
        [Parameter(Mandatory)][string]$RepoRoot
    )

    if (-not (Ensure-OriginMainRef -RepoRoot $RepoRoot)) {
        return $null
    }

    $merge = Invoke-GitAtRoot -RepoRoot $RepoRoot -ArgumentList @('merge-base', 'HEAD', 'origin/main')
    if ($merge.Ok -and -not [string]::IsNullOrWhiteSpace($merge.Output)) {
        return $merge.Output.Trim()
    }

    return $null
}

function Get-GitAncestryDiagnostics {
    param(
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $originMain = Invoke-GitAtRoot -RepoRoot $RepoRoot -ArgumentList @('rev-parse', 'origin/main')
    $head = Invoke-GitAtRoot -RepoRoot $RepoRoot -ArgumentList @('rev-parse', 'HEAD')
    $shallow = Invoke-GitAtRoot -RepoRoot $RepoRoot -ArgumentList @('rev-parse', '--is-shallow-repository')

    $originSha = if ($originMain.Ok) { $originMain.Output.Trim() } else { '<unresolved>' }
    $headSha = if ($head.Ok) { $head.Output.Trim() } else { '<unresolved>' }
    $shallowState = if ($shallow.Ok) { $shallow.Output.Trim() } else { '<unknown>' }

    return "origin/main=$originSha HEAD=$headSha shallow=$shallowState"
}

function Test-BranchBasedOnOriginMain {
    param(
        [Parameter(Mandatory)][string]$RepoRoot
    )

    if (-not (Ensure-OriginMainRef -RepoRoot $RepoRoot)) {
        return [pscustomobject]@{
            Ok     = $false
            Detail = 'could not resolve origin/main'
        }
    }

    $ancestor = Invoke-GitAtRoot -RepoRoot $RepoRoot -ArgumentList @(
        'merge-base', '--is-ancestor', 'origin/main', 'HEAD'
    )
    $ok = ($ancestor.Ok -and $ancestor.ExitCode -eq 0)
    $detail = if ($ok) {
        $diag = Get-GitAncestryDiagnostics -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($ancestor.Output)) { $diag } else { "$($ancestor.Output.Trim()) $diag" }
    }
    else {
        $diag = Get-GitAncestryDiagnostics -RepoRoot $RepoRoot
        $stderr = if ([string]::IsNullOrWhiteSpace($ancestor.Output)) { '' } else { " output=$($ancestor.Output.Trim())" }
        "merge-base --is-ancestor origin/main HEAD failed: exit=$($ancestor.ExitCode)$stderr $diag"
    }

    return [pscustomobject]@{
        Ok     = $ok
        Detail = $detail
    }
}

function Test-RangeDiffHasHunkDifferences {
    param([string]$RangeDiffOutput)

    if ([string]::IsNullOrWhiteSpace($RangeDiffOutput)) {
        return $false
    }

    foreach ($line in ($RangeDiffOutput -split "`n")) {
        if ($line -match '^\s*\d+:\s+\S+\s+[<>-]') {
            return $true
        }
    }

    return $false
}

function Get-ShipReviewRebaseDeltaScope {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Stage9Cleared,
        [string]$Head = 'HEAD'
    )

    $stage9Resolve = Invoke-GitAtRoot -RepoRoot $RepoRoot -ArgumentList @('rev-parse', '--verify', $Stage9Cleared)
    if (-not $stage9Resolve.Ok) {
        throw "Could not resolve stage-9-cleared commit: $($stage9Resolve.Output)"
    }

    $headResolve = Invoke-GitAtRoot -RepoRoot $RepoRoot -ArgumentList @('rev-parse', '--verify', $Head)
    if (-not $headResolve.Ok) {
        throw "Could not resolve HEAD: $($headResolve.Output)"
    }

    $stage9Sha = $stage9Resolve.Output.Trim()
    $headSha = $headResolve.Output.Trim()

    $oldBaseResult = Invoke-GitAtRoot -RepoRoot $RepoRoot -ArgumentList @('merge-base', $stage9Sha, $headSha)
    if (-not $oldBaseResult.Ok -or [string]::IsNullOrWhiteSpace($oldBaseResult.Output)) {
        throw "Could not resolve old_base via merge-base: $($oldBaseResult.Output)"
    }

    $oldBase = $oldBaseResult.Output.Trim()

    # Capture the naive three-dot expansion before origin/main fetch; shallow
    # fetches can make dangling stage-9 SHAs unmergeable afterward.
    $threeDotRange = '{0}...{1}' -f $stage9Sha, $headSha
    $threeDotNames = Invoke-GitAtRoot -RepoRoot $RepoRoot -ArgumentList @(
        'diff', '--name-only', $threeDotRange
    )
    $threeDotFiles = @()
    if ($threeDotNames.Ok) {
        $threeDotFiles = @($threeDotNames.Output -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    $newBase = Resolve-ShipReviewNewBase -RepoRoot $RepoRoot
    if ([string]::IsNullOrWhiteSpace($newBase)) {
        throw 'Could not resolve new_base from origin/main'
    }

    $oldSeries = "$oldBase..$stage9Sha"
    $newSeries = "$newBase..$headSha"
    $oldPatchIds = Get-GitPatchIdSet -RepoRoot $RepoRoot -RevRange $oldSeries

    $filteredCommits = [System.Collections.Generic.List[string]]::new()
    $newCommitList = Invoke-GitAtRoot -RepoRoot $RepoRoot -ArgumentList @('rev-list', $newSeries)
    if ($newCommitList.Ok) {
        foreach ($commit in ($newCommitList.Output -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
            $patchId = Get-GitPatchId -RepoRoot $RepoRoot -Commit $commit
            if ($patchId -and $oldPatchIds.Contains($patchId)) {
                continue
            }
            $filteredCommits.Add($commit.Trim()) | Out-Null
        }
    }

    $rangeDiff = Invoke-GitAtRoot -RepoRoot $RepoRoot -ArgumentList @(
        'range-diff',
        "$oldBase..$stage9Sha",
        "$newBase..$headSha"
    )
    if (-not $rangeDiff.Ok) {
        throw "git range-diff failed: $($rangeDiff.Output)"
    }

    $hasHunkDifferences = Test-RangeDiffHasHunkDifferences -RangeDiffOutput $rangeDiff.Output
    $isEmpty = ($filteredCommits.Count -eq 0) -and -not $hasHunkDifferences

    $changedFiles = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($commit in $filteredCommits) {
        $names = Invoke-GitAtRoot -RepoRoot $RepoRoot -ArgumentList @(
            'diff-tree', '--no-commit-id', '--name-only', '-r', $commit
        )
        if ($names.Ok) {
            foreach ($name in ($names.Output -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
                $changedFiles.Add($name.Trim()) | Out-Null
            }
        }
    }

    $transport = "Explicit ship-review rebase-delta range: $stage9Sha..HEAD"
    $diffCommand = "git range-diff $oldBase..$stage9Sha $newBase..$headSha"
    $commitList = Get-ShipReviewFilteredCommitList -RepoRoot $RepoRoot -FilteredCommits @($filteredCommits)

    return [pscustomobject]@{
        RepoRoot           = $RepoRoot
        Stage9Cleared      = $stage9Sha
        HeadSha            = $headSha
        OldBase            = $oldBase
        NewBase            = $newBase
        OldSeries          = $oldSeries
        NewSeries          = $newSeries
        FilteredCommits    = @($filteredCommits)
        FilteredCommitList = $commitList
        ChangedFiles       = @($changedFiles | Sort-Object)
        ThreeDotFiles      = $threeDotFiles
        IsEmpty            = $isEmpty
        HasHunkDifferences = $hasHunkDifferences
        RangeDiffOutput    = $rangeDiff.Output
        DiffCommand        = $diffCommand
        TransportField     = $transport
        DiffRange          = $transport
        FixedPoint         = $stage9Sha
    }
}

function Get-ShipReviewFilteredCommitList {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [AllowEmptyCollection()][string[]]$FilteredCommits = @()
    )

    if ($FilteredCommits.Count -eq 0) {
        return @()
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($commit in $FilteredCommits) {
        $log = Invoke-GitAtRoot -RepoRoot $RepoRoot -ArgumentList @(
            'log', '-1', '--oneline', $commit
        )
        if ($log.Ok -and -not [string]::IsNullOrWhiteSpace($log.Output)) {
            $lines.Add($log.Output.Trim()) | Out-Null
        }
    }

    return @($lines)
}

function Test-ShipReviewArtifactConsumer {
    param(
        [Parameter(Mandatory)]$Scope,
        [Parameter(Mandatory)][string]$ConsumerHeadSha,
        [string]$ConsumerDiffRange = '',
        [string]$ConsumerFixedPoint = ''
    )

    if ($ConsumerHeadSha -ne $Scope.HeadSha) {
        return [pscustomobject]@{
            Ok     = $false
            Reason = 'head_sha mismatch'
        }
    }

    if ($ConsumerDiffRange -and $ConsumerDiffRange -ne $Scope.DiffRange) {
        return [pscustomobject]@{
            Ok     = $false
            Reason = 'diff_range mismatch'
        }
    }

    if ($ConsumerFixedPoint -and $ConsumerFixedPoint -ne $Scope.FixedPoint) {
        return [pscustomobject]@{
            Ok     = $false
            Reason = 'fixed_point mismatch'
        }
    }

    return [pscustomobject]@{
        Ok     = $true
        Reason = 'accepted'
    }
}

function Test-ExplicitDiffRangeTransport {
    param([Parameter(Mandatory)][string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'empty line' }
    }

    if ($Line -notmatch '^Explicit diff range: ([^\s]+)$') {
        return [pscustomobject]@{ Ok = $false; Reason = 'missing prefix or whitespace in value' }
    }

    $value = $Matches[1]
    $dotCount = @($value.ToCharArray() | Where-Object { $_ -eq '.' }).Count
    if ($dotCount -eq 2) {
        return [pscustomobject]@{ Ok = $false; Reason = 'two-dot range' }
    }
    if ($dotCount -ne 3) {
        return [pscustomobject]@{ Ok = $false; Reason = 'separator count' }
    }
    if ($value -notmatch '^([^\.]+)\.\.\.HEAD$') {
        return [pscustomobject]@{ Ok = $false; Reason = 'grammar' }
    }

    $left = $Matches[1]
    if ($left.StartsWith('-')) {
        return [pscustomobject]@{ Ok = $false; Reason = 'dash-prefixed endpoint' }
    }

    if ([string]::IsNullOrWhiteSpace($left)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'empty left endpoint' }
    }

    return [pscustomobject]@{ Ok = $true; Reason = 'accepted' }
}

function Test-ShipReviewRebaseDeltaTransport {
    param([Parameter(Mandatory)][string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'empty line' }
    }

    if ($Line -notmatch '^Explicit ship-review rebase-delta range: ([^\s]+)$') {
        return [pscustomobject]@{ Ok = $false; Reason = 'missing prefix or whitespace in value' }
    }

    $value = $Matches[1]
    if ($value -match '\.\.\.') {
        return [pscustomobject]@{ Ok = $false; Reason = 'three-dot range' }
    }

    if (($value.ToCharArray() | Where-Object { $_ -eq '.' }).Count -ne 2) {
        return [pscustomobject]@{ Ok = $false; Reason = 'separator count' }
    }

    if ($value -notmatch '^([^\.]+)\.\.HEAD$') {
        return [pscustomobject]@{ Ok = $false; Reason = 'grammar' }
    }

    $left = $Matches[1]
    if ($left.StartsWith('-')) {
        return [pscustomobject]@{ Ok = $false; Reason = 'dash-prefixed endpoint' }
    }

    if ([string]::IsNullOrWhiteSpace($left)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'empty left endpoint' }
    }

    return [pscustomobject]@{ Ok = $true; Reason = 'accepted' }
}

function New-ShipReviewRebaseFixtureRepo {
    param(
        [Parameter(Mandatory)][string]$Root,
        [ValidateSet('clean', 'conflict-edit', 'multi-commit')]
        [string]$Scenario = 'clean'
    )

    if (Test-Path -LiteralPath $Root) {
        Remove-Item -LiteralPath $Root -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Root -Force | Out-Null

    $init = Invoke-GitAtRoot -RepoRoot $Root -ArgumentList @('init', '-q')
    if (-not $init.Ok) { throw $init.Output }

    Invoke-GitAtRoot -RepoRoot $Root -ArgumentList @('config', 'user.email', 'dev209@test.local') | Out-Null
    Invoke-GitAtRoot -RepoRoot $Root -ArgumentList @('config', 'user.name', 'dev209') | Out-Null
    Invoke-GitAtRoot -RepoRoot $Root -ArgumentList @('checkout', '-q', '-b', 'main') | Out-Null

    Set-Content -LiteralPath (Join-Path $Root 'main.txt') -Value 'main1' -Encoding utf8
    Invoke-GitAtRoot -RepoRoot $Root -ArgumentList @('add', '.') | Out-Null
    Invoke-GitAtRoot -RepoRoot $Root -ArgumentList @('commit', '-q', '-m', 'main1') | Out-Null

    Invoke-GitAtRoot -RepoRoot $Root -ArgumentList @('checkout', '-q', '-b', 'feature') | Out-Null
    Set-Content -LiteralPath (Join-Path $Root 'feature.txt') -Value 'feat1' -Encoding utf8
    Invoke-GitAtRoot -RepoRoot $Root -ArgumentList @('add', '.') | Out-Null
    Invoke-GitAtRoot -RepoRoot $Root -ArgumentList @('commit', '-q', '-m', 'feat1') | Out-Null

    if ($Scenario -eq 'multi-commit') {
        Set-Content -LiteralPath (Join-Path $Root 'feature.txt') -Value 'feat2' -Encoding utf8
        Invoke-GitAtRoot -RepoRoot $Root -ArgumentList @('add', '.') | Out-Null
        Invoke-GitAtRoot -RepoRoot $Root -ArgumentList @('commit', '-q', '-m', 'feat2') | Out-Null
    }

    $stage9 = (Invoke-GitAtRoot -RepoRoot $Root -ArgumentList @('rev-parse', 'HEAD')).Output.Trim()

    Invoke-GitAtRoot -RepoRoot $Root -ArgumentList @('checkout', '-q', 'main') | Out-Null
    Set-Content -LiteralPath (Join-Path $Root 'upstream.txt') -Value 'upstream' -Encoding utf8
    Invoke-GitAtRoot -RepoRoot $Root -ArgumentList @('add', '.') | Out-Null
    Invoke-GitAtRoot -RepoRoot $Root -ArgumentList @('commit', '-q', '-m', 'upstream') | Out-Null
    Invoke-GitAtRoot -RepoRoot $Root -ArgumentList @('branch', '-M', 'main') | Out-Null
    Invoke-GitAtRoot -RepoRoot $Root -ArgumentList @('remote', 'add', 'origin', $Root) | Out-Null
    Invoke-GitAtRoot -RepoRoot $Root -ArgumentList @('push', '-q', 'origin', 'main') | Out-Null

    Invoke-GitAtRoot -RepoRoot $Root -ArgumentList @('checkout', '-q', 'feature') | Out-Null
    $rebase = Invoke-GitAtRoot -RepoRoot $Root -ArgumentList @('rebase', 'main')
    if (-not $rebase.Ok) {
        throw "rebase failed: $($rebase.Output)"
    }

    if ($Scenario -eq 'conflict-edit') {
        Set-Content -LiteralPath (Join-Path $Root 'feature.txt') -Value 'feat1-edited' -Encoding utf8
        Invoke-GitAtRoot -RepoRoot $Root -ArgumentList @('add', '.') | Out-Null
        Invoke-GitAtRoot -RepoRoot $Root -ArgumentList @('commit', '-q', '--amend', '--no-edit') | Out-Null
    }

    $head = (Invoke-GitAtRoot -RepoRoot $Root -ArgumentList @('rev-parse', 'HEAD')).Output.Trim()
    $ancestor = Invoke-GitAtRoot -RepoRoot $Root -ArgumentList @('merge-base', '--is-ancestor', $stage9, $head)

    return [pscustomobject]@{
        Root        = $Root
        Stage9      = $stage9
        Head        = $head
        IsAncestor  = $ancestor.Ok
    }
}
