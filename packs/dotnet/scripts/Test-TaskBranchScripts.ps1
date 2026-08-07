#!/usr/bin/env pwsh
# Regression tests for task-branch Git safety. Uses a local bare repository so
# no network or real remote can be contacted or mutated.

$ErrorActionPreference = 'Stop'

$rebaseScript = Join-Path $PSScriptRoot 'rebase-task-branch.ps1'
$checks = 0
$failures = 0

function Assert-That {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')

    $script:checks++
    if ($Condition) {
        Write-Host ("  ok    {0}" -f $Name)
    }
    else {
        Write-Host ("  FAIL  {0}" -f $Name) -ForegroundColor Red
        if ($Detail) { Write-Host "        $Detail" -ForegroundColor DarkRed }
        $script:failures++
    }
}

function Invoke-Git {
    param(
        [string]$WorkingDirectory,
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Arguments
    )

    $output = @(& git -C $WorkingDirectory @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "git -C '$WorkingDirectory' $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }
    return $output
}

function Remove-TestDirectory {
    param([string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $tempPath = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if (-not $fullPath.StartsWith($tempPath, [System.StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path $fullPath -Leaf) -notlike 'task-branch-tests-*') {
        throw "Refusing to remove unexpected test path '$fullPath'."
    }

    for ($attempt = 1; $attempt -le 10; $attempt++) {
        try {
            Remove-Item -LiteralPath $fullPath -Recurse -Force -ErrorAction Stop
            return
        }
        catch {
            if ($attempt -eq 10) { throw }
            Start-Sleep -Milliseconds 200
        }
    }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("task-branch-tests-{0}" -f [guid]::NewGuid())
$remote = Join-Path $tempRoot 'remote.git'
$seed = Join-Path $tempRoot 'seed'
$work = Join-Path $tempRoot 'work'
$taskBranch = 'feature/59-safe-force-push'

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    Invoke-Git $tempRoot init --bare --initial-branch=main $remote | Out-Null
    Invoke-Git $tempRoot init --initial-branch=main $seed | Out-Null
    Invoke-Git $seed config user.email 'harness-tests@example.invalid' | Out-Null
    Invoke-Git $seed config user.name 'Harness Tests' | Out-Null
    Set-Content -LiteralPath (Join-Path $seed 'README.md') -Value 'base'
    Invoke-Git $seed add README.md | Out-Null
    Invoke-Git $seed commit -m 'Base' | Out-Null
    Invoke-Git $seed remote add origin $remote | Out-Null
    Invoke-Git $seed push -u origin main | Out-Null
    Invoke-Git $tempRoot clone $remote $work | Out-Null
    Invoke-Git $work config user.email 'harness-tests@example.invalid' | Out-Null
    Invoke-Git $work config user.name 'Harness Tests' | Out-Null
    Invoke-Git $work switch -c $taskBranch origin/main | Out-Null
    Invoke-Git $work config push.default upstream | Out-Null

    Set-Content -LiteralPath (Join-Path $work 'feature.txt') -Value 'task change'
    Invoke-Git $work add feature.txt | Out-Null
    Invoke-Git $work commit -m 'Task change' | Out-Null

    $upstreamBefore = (Invoke-Git $work rev-parse --abbrev-ref --symbolic-full-name '@{upstream}').Trim()
    $mainBefore = (Invoke-Git $remote rev-parse refs/heads/main).Trim()

    Push-Location $work
    try {
        $pushOutput = (& $rebaseScript -BaseBranch main -Remote origin -Push 6>&1 | Out-String)
    }
    finally {
        Pop-Location
    }

    $mainAfter = (Invoke-Git $remote rev-parse refs/heads/main).Trim()
    $taskRemote = (Invoke-Git $remote rev-parse "refs/heads/$taskBranch").Trim()
    $taskLocal = (Invoke-Git $work rev-parse HEAD).Trim()
    $upstreamAfter = (Invoke-Git $work rev-parse --abbrev-ref --symbolic-full-name '@{upstream}').Trim()

    Assert-That 'fixture reproduces a task branch tracking origin/main' `
        ($upstreamBefore -eq 'origin/main') $upstreamBefore
    Assert-That 'explicit push leaves the protected main ref unchanged' `
        ($mainAfter -eq $mainBefore) "before=$mainBefore after=$mainAfter"
    Assert-That 'explicit push creates the remote task ref at local HEAD' `
        ($taskRemote -eq $taskLocal) "remote=$taskRemote local=$taskLocal"
    Assert-That 'successful push repairs upstream to the task branch' `
        ($upstreamAfter -eq "origin/$taskBranch") $upstreamAfter
    Assert-That 'push output names the explicit remote task destination' `
        ($pushOutput -match [regex]::Escape("origin/$taskBranch")) $pushOutput

    Push-Location $work
    try {
        $guidance = (& $rebaseScript -BaseBranch main -Remote origin 6>&1 | Out-String)
    }
    finally {
        Pop-Location
    }
    $expectedCommand = "git push --force-with-lease=refs/heads/$taskBranch --set-upstream -- origin HEAD:refs/heads/$taskBranch"
    Assert-That 'no-push guidance prints the same explicit safe refspec' `
        ($guidance -match [regex]::Escape($expectedCommand)) $guidance

    # Reject forced non-fast-forwards in the local bare remote to exercise the
    # helper's error without manufacturing a claim about why Git rejected it.
    Invoke-Git $remote config receive.denyNonFastForwards true | Out-Null
    Invoke-Git $work reset --hard origin/main | Out-Null
    Set-Content -LiteralPath (Join-Path $work 'replacement.txt') -Value 'replacement task history'
    Invoke-Git $work add replacement.txt | Out-Null
    Invoke-Git $work commit -m 'Replacement task change' | Out-Null
    $pushError = ''
    Push-Location $work
    try {
        try { & $rebaseScript -BaseBranch main -Remote origin -Push 6>&1 | Out-Null }
        catch { $pushError = $_.Exception.Message }
    }
    finally {
        Pop-Location
    }
    Assert-That 'push failure identifies the exact remote task ref' `
        ($pushError -match [regex]::Escape("origin/$taskBranch")) $pushError
    Assert-That 'push failure does not invent a concurrent-update diagnosis' `
        ($pushError -notmatch 'someone|concurrent') $pushError
    Assert-That 'rejected force push leaves the remote task ref unchanged' `
        (((Invoke-Git $remote rev-parse "refs/heads/$taskBranch").Trim()) -eq $taskRemote)

    Invoke-Git $work switch main | Out-Null
    $protectedError = ''
    Push-Location $work
    try {
        try { & $rebaseScript -BaseBranch main -Remote origin -Push | Out-Null }
        catch { $protectedError = $_.Exception.Message }
    }
    finally {
        Pop-Location
    }
    Assert-That 'the helper rejects a protected current branch before pushing' `
        ($protectedError -match "Refusing to rebase 'main'") $protectedError
    Assert-That 'protected-branch refusal leaves remote main unchanged' `
        (((Invoke-Git $remote rev-parse refs/heads/main).Trim()) -eq $mainBefore)
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-TestDirectory $tempRoot
    }
}

Write-Host ''
if ($failures -gt 0) {
    Write-Host "$failures of $checks checks FAILED." -ForegroundColor Red
    exit 1
}

Write-Host "All $checks checks passed."
exit 0
