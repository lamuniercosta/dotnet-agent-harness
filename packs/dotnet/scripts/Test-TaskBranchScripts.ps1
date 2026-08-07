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

    # ── Worktree intake ──────────────────────────────────────────────────────
    #
    # new-task-branch.ps1 resolves the repo from its OWN location
    # (git -C $PSScriptRoot), not the caller's cwd, so the pack copy would target
    # this harness repo however the test is invoked. Copying the scripts into the
    # fixture is both the fix and the honest simulation: a consumer runs an
    # installed copy under <repo>/scripts/.
    $wtWork = Join-Path $tempRoot 'wt-work'
    Invoke-Git $tempRoot clone $remote $wtWork | Out-Null
    Invoke-Git $wtWork config user.email 'harness-tests@example.invalid' | Out-Null
    Invoke-Git $wtWork config user.name 'Harness Tests' | Out-Null

    $fixtureScripts = Join-Path $wtWork 'scripts'
    New-Item -ItemType Directory -Path $fixtureScripts -Force | Out-Null
    foreach ($dep in 'new-task-branch.ps1', '_gate-common.ps1', '_harness-config.ps1') {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $dep) -Destination $fixtureScripts -Force
    }
    $newScript = Join-Path $fixtureScripts 'new-task-branch.ps1'

    # The derived root is a SIBLING of the repo, so an in-repo recursive tool
    # never walks another task's checkout.
    $expectedRoot = Join-Path $tempRoot 'wt-work.worktrees'

    # A configured threshold that is not the harness default: if the worktree
    # loses harness.yml, the gates there silently fall back to 15 and this is the
    # value that proves it did not happen.
    Set-Content -LiteralPath (Join-Path $wtWork 'harness.yml') -Encoding UTF8 -Value @(
        'baseBranch: main'
        'task:'
        '  worktree: true'
        'gates:'
        '  complexity:'
        '    implement: 11'
    )

    # Uncommitted work in the main checkout. Worktree intake must not care - that
    # serialisation is the whole reason worktrees are the default.
    Set-Content -LiteralPath (Join-Path $wtWork 'scratch.txt') -Value 'work in progress'

    $mainBranchBefore = (Invoke-Git $wtWork rev-parse --abbrev-ref HEAD).Trim()
    $firstOutput = (& $newScript -Description 'Add upload retry' -Type feature -BaseBranch main -Remote origin 3>&1 6>&1 | Out-String)

    $firstBranch = 'feature/add-upload-retry'
    $firstPath = Join-Path $expectedRoot 'feature-add-upload-retry'

    Assert-That 'worktree intake creates the worktree beside the repo, not inside it' `
        (Test-Path -LiteralPath $firstPath) $firstOutput
    Assert-That 'the new branch is checked out in the worktree' `
        (((Invoke-Git $firstPath rev-parse --abbrev-ref HEAD).Trim()) -eq $firstBranch)
    Assert-That 'worktree intake leaves the main checkout on its own branch' `
        (((Invoke-Git $wtWork rev-parse --abbrev-ref HEAD).Trim()) -eq $mainBranchBefore)
    Assert-That 'a dirty main checkout does not block worktree intake' `
        ((Get-Content -LiteralPath (Join-Path $wtWork 'scratch.txt') -Raw).Trim() -eq 'work in progress')
    Assert-That 'the branch is created from the remote base, not local HEAD' `
        (((Invoke-Git $firstPath rev-parse HEAD).Trim()) -eq ((Invoke-Git $remote rev-parse refs/heads/main).Trim()))

    # The silent-threshold-drift guard. harness.yml is gitignored, so git does not
    # carry it into a worktree and every configured gate would quietly revert to
    # the harness default.
    $copiedConfig = Join-Path $firstPath 'harness.yml'
    Assert-That 'gitignored harness.yml is copied into the worktree' `
        (Test-Path -LiteralPath $copiedConfig) $firstOutput
    if (Test-Path -LiteralPath $copiedConfig) {
        Assert-That 'the copied harness.yml keeps the configured threshold' `
            ((Get-Content -LiteralPath $copiedConfig -Raw) -match 'implement: 11')
    }
    Assert-That 'the worktree path is reported to the caller' `
        ($firstOutput -match [regex]::Escape($firstPath)) $firstOutput

    # Parallelism, stated as an assertion: a second task while the first is live.
    $secondOutput = (& $newScript -Description 'Fix null ref' -Type bug -BaseBranch main -Remote origin 3>&1 6>&1 | Out-String)
    $secondPath = Join-Path $expectedRoot 'bug-fix-null-ref'
    Assert-That 'a second task gets its own worktree while the first still exists' `
        ((Test-Path -LiteralPath $secondPath) -and (Test-Path -LiteralPath $firstPath)) $secondOutput
    Assert-That 'the two worktrees hold different branches' `
        (((Invoke-Git $secondPath rev-parse --abbrev-ref HEAD).Trim()) -eq 'bug/fix-null-ref')

    # Both directions: reusing a name must refuse rather than adopt a stale tree.
    $collisionError = ''
    try { & $newScript -Description 'Add upload retry' -Type feature -BaseBranch main -Remote origin 3>&1 6>&1 | Out-Null }
    catch { $collisionError = $_.Exception.Message }
    Assert-That 'an existing branch name refuses instead of reusing a worktree' `
        ($collisionError -match 'already exists') $collisionError

    # A worktree inside the repo is the one layout every doc forbids. The default
    # root is a sibling, but an override must not reach back in - a relative root
    # is joined to the repo, and an absolute in-repo path is just as wrong. Both
    # must refuse before `git worktree add` runs, so no branch and no checkout is
    # left behind. Fresh branch names, so the branch-exists guard cannot mask the
    # containment error.
    $relInRepoError = ''
    try { & $newScript -Description 'Relative in repo root' -Type feature -WorktreeRoot '.inside-worktrees' -BaseBranch main -Remote origin 3>&1 6>&1 | Out-Null }
    catch { $relInRepoError = $_.Exception.Message }
    Assert-That 'a relative WorktreeRoot that lands inside the repo is rejected' `
        ($relInRepoError -match 'inside the repository') $relInRepoError
    Assert-That 'the rejected relative in-repo root created no checkout' `
        (-not (Test-Path -LiteralPath (Join-Path $wtWork '.inside-worktrees')))
    Assert-That 'the rejected relative in-repo root created no branch' `
        (-not (Invoke-Git $wtWork branch --list 'feature/relative-in-repo-root'))

    $absInRepoRoot = Join-Path $wtWork 'nested-worktrees'
    $absInRepoError = ''
    try { & $newScript -Description 'Absolute in repo root' -Type feature -WorktreeRoot $absInRepoRoot -BaseBranch main -Remote origin 3>&1 6>&1 | Out-Null }
    catch { $absInRepoError = $_.Exception.Message }
    Assert-That 'an absolute WorktreeRoot inside the repo is rejected' `
        ($absInRepoError -match 'inside the repository') $absInRepoError
    Assert-That 'the rejected absolute in-repo root created no checkout' `
        (-not (Test-Path -LiteralPath $absInRepoRoot))

    # The escape valve stays open: a root OUTSIDE the repo is accepted, proving
    # the check rejects containment specifically, not every override.
    $outsideRoot = Join-Path $tempRoot 'custom-worktrees'
    $outsideOutput = (& $newScript -Description 'Outside root ok' -Type feature -WorktreeRoot $outsideRoot -BaseBranch main -Remote origin 3>&1 6>&1 | Out-String)
    Assert-That 'a WorktreeRoot outside the repo is accepted' `
        (Test-Path -LiteralPath (Join-Path $outsideRoot 'feature-outside-root-ok')) $outsideOutput

    # -NoWorktree keeps the old contract, dirty-tree refusal included.
    $dirtyError = ''
    try { & $newScript -Description 'Switch in place' -Type feature -BaseBranch main -Remote origin -NoWorktree 3>&1 6>&1 | Out-Null }
    catch { $dirtyError = $_.Exception.Message }
    Assert-That '-NoWorktree still refuses a dirty working tree' `
        ($dirtyError -match 'not clean') $dirtyError
    Assert-That 'the refused in-place switch created no branch' `
        (-not (Invoke-Git $wtWork branch --list 'feature/switch-in-place'))

    Assert-That '-Worktree and -NoWorktree together are rejected' `
        ((& {
            try { & $newScript -Description 'Both flags' -Worktree -NoWorktree -BaseBranch main 2>&1 | Out-Null; return '' }
            catch { return $_.Exception.Message }
        }) -match 'not both')

    # A missing harness.yml must SAY the worktree is on defaults. A silent
    # fallback is indistinguishable from a correctly configured run.
    Remove-Item -LiteralPath (Join-Path $wtWork 'harness.yml') -Force
    $noConfigOutput = (& $newScript -Description 'No config here' -Type feature -BaseBranch main -Remote origin 3>&1 6>&1 | Out-String)
    Assert-That 'a missing harness.yml is reported, not silently defaulted' `
        ($noConfigOutput -match 'harness defaults') $noConfigOutput
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
