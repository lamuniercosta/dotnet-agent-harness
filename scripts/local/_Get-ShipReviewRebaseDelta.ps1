# Shared git semantics for DEV-209 ship-review rebase-delta scope.
# Dot-sourced by scripts/local/Test-ShipReviewRebaseScope.ps1.

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

function Resolve-ShipReviewNewBase {
    param(
        [Parameter(Mandatory)][string]$RepoRoot
    )

    foreach ($candidate in @('origin/main', 'origin/master', 'main', 'master')) {
        $resolve = Invoke-GitAtRoot -RepoRoot $RepoRoot -ArgumentList @('rev-parse', '--verify', $candidate)
        if (-not $resolve.Ok) {
            continue
        }

        $merge = Invoke-GitAtRoot -RepoRoot $RepoRoot -ArgumentList @('merge-base', 'HEAD', $candidate)
        if ($merge.Ok -and -not [string]::IsNullOrWhiteSpace($merge.Output)) {
            return $merge.Output.Trim()
        }
    }

    return $null
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
        [string]$Head = 'HEAD',
        [string]$DefaultBranchRef = 'origin/main'
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
    $newBase = Resolve-ShipReviewNewBase -RepoRoot $RepoRoot
    if ([string]::IsNullOrWhiteSpace($newBase)) {
        $newBaseResult = Invoke-GitAtRoot -RepoRoot $RepoRoot -ArgumentList @('merge-base', $headSha, $DefaultBranchRef)
        if (-not $newBaseResult.Ok -or [string]::IsNullOrWhiteSpace($newBaseResult.Output)) {
            throw "Could not resolve new_base: $($newBaseResult.Output)"
        }
        $newBase = $newBaseResult.Output.Trim()
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

    $threeDotNames = Invoke-GitAtRoot -RepoRoot $RepoRoot -ArgumentList @(
        'diff', '--name-only', "$stage9Sha...$headSha"
    )
    $threeDotFiles = @()
    if ($threeDotNames.Ok) {
        $threeDotFiles = @($threeDotNames.Output -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    $transport = "Explicit ship-review rebase-delta range: $stage9Sha..HEAD"
    $diffCommand = "git range-diff $oldBase..$stage9Sha $newBase..$headSha"

    return [pscustomobject]@{
        RepoRoot          = $RepoRoot
        Stage9Cleared     = $stage9Sha
        HeadSha           = $headSha
        OldBase           = $oldBase
        NewBase           = $newBase
        OldSeries         = $oldSeries
        NewSeries         = $newSeries
        FilteredCommits   = @($filteredCommits)
        ChangedFiles      = @($changedFiles | Sort-Object)
        ThreeDotFiles     = $threeDotFiles
        IsEmpty           = $isEmpty
        HasHunkDifferences = $hasHunkDifferences
        RangeDiffOutput   = $rangeDiff.Output
        DiffCommand       = $diffCommand
        TransportField    = $transport
        DiffRange         = $transport
        FixedPoint        = $stage9Sha
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
    if ($value -match '\.\.') {
        return [pscustomobject]@{ Ok = $false; Reason = 'two-dot range' }
    }

    if (($value.ToCharArray() | Where-Object { $_ -eq '.' }).Count -ne 3) {
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
