#!/usr/bin/env pwsh
# Measures a pushed commit with this branch's mutation gate and writes a compact,
# committable Mutation receipt per project.
#
# The commit is checked out detached into a temporary directory outside the repo, the
# gate tooling from the current checkout is overlaid onto it, and run-mutation.ps1 runs
# once per project while a process sampler records which test processes loaded which
# assemblies of the measured project's namespace. After the run the test project is
# rebuilt clean so the loaded assembly can be compared with an unmutated one. No other
# worktree is touched.
#
# Exits 0 when every receipt was written (the gate verdict is recorded inside them),
# 1 when a receipt could not be produced. Windows only: the sampler uses Win32_Process.
#
# Usage:
#   ./scripts/new-mutation-receipt.ps1 -Commit origin/feature/my-task `
#       -Project Contoso.Infrastructure,Contoso.Api -ReceiptDir specs/task/receipts

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Commit,
    [Parameter(Mandatory)][string[]]$Project,
    [Parameter(Mandatory)][string]$ReceiptDir,
    [string]$WorkRoot = '',
    # Optional; recorded in the receipt so a commit can be traced back to its task.
    [string]$Ticket = '',
    [switch]$KeepCheckout
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_gate-common.ps1')

$overlayFiles = @(
    '.config/dotnet-tools.json',
    'stryker-config.json',
    'scripts/run-mutation.ps1',
    'scripts/_gate-common.ps1',
    'scripts/_harness-config.ps1'
)

function Get-FileSha256 {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-MutationCounts {
    param($Report)

    $c = [ordered]@{ Killed = 0; Survived = 0; Timeout = 0; NoCoverage = 0; Ignored = 0; CompileError = 0 }
    foreach ($f in $Report.files.PSObject.Properties) {
        foreach ($m in @($f.Value.mutants)) {
            if ($c.Contains([string]$m.status)) { $c[[string]$m.status]++ }
        }
    }
    $tested = $c.Killed + $c.Survived + $c.Timeout + $c.NoCoverage
    $c['Tested'] = $tested
    $c['Score'] = if ($tested -gt 0) { [math]::Round(($c.Killed + $c.Timeout) * 100.0 / $tested, 2) } else { $null }
    return $c
}

function Get-ReceiptMutants {
    param($Report, [string]$Checkout)

    $names = @{}
    if ($Report.PSObject.Properties.Match('testFiles').Count -gt 0 -and $Report.testFiles) {
        foreach ($tf in $Report.testFiles.PSObject.Properties) {
            foreach ($t in @($tf.Value.tests)) { $names[[string]$t.id] = [string]$t.name }
        }
    }

    $mutants = foreach ($f in $Report.files.PSObject.Properties) {
        $rel = [System.IO.Path]::GetRelativePath($Checkout, $f.Name).Replace('\', '/')
        foreach ($m in @($f.Value.mutants)) {
            $killedBy = @(if ($m.PSObject.Properties.Match('killedBy').Count -gt 0) {
                    foreach ($id in @($m.killedBy | Where-Object { $_ })) {
                        if ($names.ContainsKey([string]$id)) { $names[[string]$id] } else { "unresolved:$id" }
                    }
                })
            [ordered]@{
                file         = $rel
                line         = [int]$m.location.start.line
                mutator      = [string]$m.mutatorName
                status       = [string]$m.status
                statusReason = if ($m.PSObject.Properties.Match('statusReason').Count -gt 0) { [string]$m.statusReason } else { '' }
                killedBy     = $killedBy
            }
        }
    }
    return @($mutants | Sort-Object { $_.file }, { $_.line }, { $_.mutator })
}

# Stryker compiles helper types into the mutated assembly under a namespace that starts
# with "Stryker"; an unmutated assembly has none.
$assemblyProbe = {
    function Get-AssemblyIdentity {
        param([string]$Path)

        Add-Type -AssemblyName System.Reflection.Metadata
        $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
        try {
            $sha = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($fs)).ToLowerInvariant()
            $fs.Position = 0
            $pe = [System.Reflection.PortableExecutable.PEReader]::new($fs, [System.Reflection.PortableExecutable.PEStreamOptions]::LeaveOpen)
            try {
                $md = [System.Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($pe)
                $stryker = 0
                foreach ($h in $md.TypeDefinitions) {
                    $ns = $md.GetString($md.GetTypeDefinition($h).Namespace)
                    if ($ns -match '^Stryker') { $stryker++ }
                }
            }
            finally { $pe.Dispose() }
        }
        finally { $fs.Dispose() }
        return [ordered]@{ sha256 = $sha; strykerTypes = $stryker }
    }
}

$samplerBody = {
    param([string]$LogPath, [string]$Checkout, [string[]]$TargetModules, [string]$ProbeText, [string]$ModulePattern)

    # MTP test servers are long-lived and load production assemblies lazily, when a test
    # first touches them, so each process is re-inspected until it exits. A record is
    # appended on first sight and whenever its loaded module set grows; the reader keeps
    # the last record per pid.
    . ([scriptblock]::Create($ProbeText))
    $live = @{}
    $seen = @{}
    while ($true) {
        $procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
                $cmd = ([string]$_.CommandLine).Replace([char]'/', [char]0x5C)
                $cmd.IndexOf($Checkout, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and
                $cmd -notmatch 'MSBuild\.dll|VBCSCompiler|dotnet-stryker' -and
                ($_.Name -match "^(testhost|$ModulePattern)" -or $cmd -match '\\bin\\[^"]*\.(dll|exe)')
            })
        foreach ($p in $procs) {
            $procId = [int]$p.ProcessId
            if ($seen.ContainsKey($procId)) { continue }
            $seen[$procId] = $true
            $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($p.ParentProcessId)" -ErrorAction SilentlyContinue
            $live[$procId] = [ordered]@{
                pid          = $procId
                name         = [string]$p.Name
                parentPid    = [int]$p.ParentProcessId
                parentName   = if ($parent) { [string]$parent.Name } else { '' }
                commandLine  = [string]$p.CommandLine
                firstSeenUtc = [DateTime]::UtcNow.ToString('o')
                modules      = [System.Collections.Generic.List[string]]::new()
                targets      = [System.Collections.Generic.List[object]]::new()
            }
            Add-Content -LiteralPath $LogPath -Value ($live[$procId] | ConvertTo-Json -Depth 6 -Compress)
        }
        foreach ($procId in @($live.Keys)) {
            $entry = $live[$procId]
            try {
                $mods = @((Get-Process -Id $procId -ErrorAction Stop).Modules | Where-Object { $_.ModuleName -match "^$ModulePattern" })
            }
            catch {
                $live.Remove($procId)
                continue
            }
            $grew = $false
            foreach ($m in $mods) {
                if ($entry.modules.Contains($m.FileName)) { continue }
                $entry.modules.Add($m.FileName)
                $grew = $true
                if ($TargetModules -contains $m.ModuleName) {
                    # A locked or vanished file must not end the sampler; record the load
                    # with a null hash, which the verdict never counts as a mutated load.
                    try { $id = Get-AssemblyIdentity -Path $m.FileName }
                    catch { $id = [ordered]@{ sha256 = $null; strykerTypes = $null } }
                    $entry.targets.Add([ordered]@{ path = $m.FileName; sha256 = $id.sha256; strykerTypes = $id.strykerTypes; seenUtc = [DateTime]::UtcNow.ToString('o') })
                }
            }
            if ($grew) { Add-Content -LiteralPath $LogPath -Value ($entry | ConvertTo-Json -Depth 6 -Compress) }
        }
        Start-Sleep -Milliseconds 500
    }
}

function ConvertTo-PortableText {
    # Replaces machine-specific roots with placeholders; handles raw, JSON-escaped and
    # forward-slash spellings.
    param([string]$Text, [System.Collections.Specialized.OrderedDictionary]$Roots)

    foreach ($root in $Roots.Keys) {
        $trimmed = $root.TrimEnd('\', '/')
        foreach ($variant in @($trimmed, $trimmed.Replace('\', '\\'), $trimmed.Replace('\', '/')) | Select-Object -Unique) {
            $Text = [regex]::Replace($Text, [regex]::Escape($variant), $Roots[$root].Replace('$', '$$'), 'IgnoreCase')
        }
    }
    return $Text
}

function Write-ReceiptMarkdown {
    param($Receipt, [string]$Path)

    $r = $Receipt
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("# Mutation receipt: $($r.project)")
    $lines.Add('')
    if ($r.ticket) {
        $lines.Add("Generated by ``scripts/new-mutation-receipt.ps1`` for $($r.ticket) on $($r.generatedUtc).")
    }
    else {
        $lines.Add("Generated by ``scripts/new-mutation-receipt.ps1`` on $($r.generatedUtc).")
    }
    $lines.Add('')
    $lines.Add('| Field | Value |')
    $lines.Add('|---|---|')
    $lines.Add("| Measured commit | ``$($r.measured.commit)`` ($($r.measured.remoteBranches -join ', ')) |")
    $lines.Add("| Merge base with $($r.measured.baseRef) | ``$($r.measured.mergeBase)`` |")
    $lines.Add("| Tooling commit | ``$($r.tooling.commit)``$(if ($r.tooling.dirty) { ' + uncommitted tooling (hashes in receipt.json)' }) |")
    $lines.Add("| Stryker | $($r.strykerVersion) |")
    $lines.Add("| Threshold (break) | $($r.threshold) |")
    $testProjectCells = @($r.testProjects | ForEach-Object { '`' + $_ + '`' }) -join ', '
    $lines.Add("| Test projects | $testProjectCells |")
    $lines.Add("| Exits | tool restore $($r.exits.toolRestore), gate $($r.exits.gate), Stryker $($r.exits.stryker), clean build $($r.exits.cleanBuild) |")
    $lines.Add("| Duration (gate wall time) | $($r.durationSeconds)s |")
    $c = $r.counts
    $lines.Add("| Mutants | Killed $($c.Killed), Survived $($c.Survived), Timeout $($c.Timeout), NoCoverage $($c.NoCoverage), Ignored $($c.Ignored), CompileError $($c.CompileError) |")
    $lines.Add("| Score | $(if ($null -ne $c.Score) { "$($c.Score)% of $($c.Tested) tested" } else { 'n/a (0 tested)' }) |")
    $lines.Add("| Assembly evidence | $($r.assembly.verdict) |")
    $lines.Add('')
    $lines.Add('Reproduce:')
    $lines.Add('')
    $lines.Add('```powershell')
    $lines.Add("./scripts/new-mutation-receipt.ps1 -Commit $($r.measured.commit) -Project $($r.project) -ReceiptDir <dir>")
    $lines.Add('```')
    $lines.Add('')
    if (@($r.gate.verdictLines).Count -gt 0) {
        $lines.Add('## Gate verdict')
        $lines.Add('')
        foreach ($v in $r.gate.verdictLines) { $lines.Add("    $v") }
        $lines.Add('')
    }
    $lines.Add('## Assembly identity')
    $lines.Add('')
    $lines.Add($r.assembly.note)
    $lines.Add('')
    if (@($r.assembly.observations).Count -gt 0) {
        $lines.Add('| Loaded path | pid | Run SHA256 | Stryker types | Clean SHA256 | Clean Stryker types |')
        $lines.Add('|---|---|---|---|---|---|')
        foreach ($o in $r.assembly.observations) {
            # Hashing a loaded DLL can fail in the sampler, leaving the run hash null.
            $runHashCell = if ($o.runSha256) { '`' + $o.runSha256.Substring(0, 12) + '`' } else { 'hash failed' }
            $cleanHashCell = if ($o.cleanSha256) { '`' + $o.cleanSha256.Substring(0, 12) + '`' } else { 'n/a (path gone or unreadable)' }
            $lines.Add("| ``$($o.path)`` | $($o.pid) | $runHashCell | $($o.runStrykerTypes) | $cleanHashCell | $($o.cleanStrykerTypes) |")
        }
        $lines.Add('')
    }
    $lines.Add('## Mutated files')
    $lines.Add('')
    foreach ($f in $r.mutatedFiles) { $lines.Add("- ``$f``") }
    $lines.Add('')
    $lines.Add('## Mutants')
    $lines.Add('')
    $lines.Add('| File:line | Mutator | Status | Killed by |')
    $lines.Add('|---|---|---|---|')
    foreach ($m in $r.mutants) {
        $killers = @($m.killedBy | Where-Object { $_ })
        $by = if ($killers.Count -gt 0) { ($killers | ForEach-Object { [regex]::Replace($_, $r.testNamePrefix, '') }) -join '<br>' } else { $m.statusReason }
        $lines.Add("| ``$($m.file):$($m.line)`` | $($m.mutator) | $($m.status) | $($by -replace '\|', '\|') |")
    }
    $lines.Add('')
    $lines.Add("Test names in the table drop the ``$($r.testNamePrefix)`` prefix; receipt.json has them in full.")
    [System.IO.File]::WriteAllText($Path, ($lines -join "`n") + "`n", [System.Text.UTF8Encoding]::new($false))
}

if (-not $IsWindows) {
    Write-Host 'Mutation receipt: FAILED - the process sampler needs Windows (Win32_Process).'
    exit 1
}

$repoRoot = (git rev-parse --show-toplevel).Trim()
$repoRoot = [System.IO.Path]::GetFullPath($repoRoot)
$sha = (git -C $repoRoot rev-parse --verify "$Commit^{commit}" 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $sha) {
    Write-Host "Mutation receipt: FAILED - '$Commit' does not resolve to a commit."
    exit 1
}
$sha = $sha.Trim()
$remoteBranches = @(git -C $repoRoot branch -r --contains $sha | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '->' })
if ($remoteBranches.Count -eq 0) {
    Write-Host "Mutation receipt: FAILED - $sha is not on any remote-tracking branch; push it first so the receipt is reproducible."
    exit 1
}

$projects = @($Project | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() -replace '\.csproj$', '' } | Where-Object { $_ })

# The measured assemblies and the test names both live under the projects' root
# namespace (Contoso.Core -> Contoso), so it is derived from -Project rather than
# hardcoded: the sampler needs it to recognise a test process and its modules,
# and the receipt uses it to shorten test names in the markdown table.
$moduleRoots = @($projects | ForEach-Object { ($_ -split '\.')[0] } | Select-Object -Unique | Sort-Object)
if ($moduleRoots.Count -eq 0) {
    Write-Host 'Mutation receipt: FAILED - -Project named no project.'
    exit 1
}
$modulePattern = '(' + (($moduleRoots | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')\.'
$testNamePrefix = '^' + (($moduleRoots | ForEach-Object { [regex]::Escape($_) }) -join '|') + '\.'

# Resolve from harness.yml rather than assuming origin/main: the base branch is a
# per-repo setting, and a receipt that diffs against the wrong branch records the
# wrong number of mutants.
$baseBranch = Get-HarnessValue -Key 'baseBranch' -RepoRoot $repoRoot
if ([string]::IsNullOrWhiteSpace($baseBranch)) { $baseBranch = 'main' }
$baseRef = "origin/$baseBranch"

$toolingCommit = (git -C $repoRoot rev-parse HEAD).Trim()
$toolingDirty = [bool](git -C $repoRoot status --porcelain -- @($overlayFiles + 'scripts/new-mutation-receipt.ps1'))
$overlay = @($overlayFiles | ForEach-Object { [ordered]@{ path = $_; sha256 = Get-FileSha256 -Path (Join-Path $repoRoot $_) } })
$overlay += [ordered]@{ path = 'scripts/new-mutation-receipt.ps1'; sha256 = Get-FileSha256 -Path $PSCommandPath }

$work = if ($WorkRoot) { [System.IO.Path]::GetFullPath($WorkRoot) } else {
    # The GUID suffix keeps two runs started in the same second out of one folder.
    Join-Path ([System.IO.Path]::GetTempPath()) ("stryker-receipt/" + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
}
$checkout = Join-Path $work 'checkout'
$receiptRoot = if ([System.IO.Path]::IsPathRooted($ReceiptDir)) { $ReceiptDir } else { Join-Path $repoRoot $ReceiptDir }
New-Item -ItemType Directory -Path $work -Force | Out-Null
Write-Host "Measuring $sha ($($remoteBranches -join ', ')) in $checkout"

$roots = [System.Collections.Specialized.OrderedDictionary]::new()
$roots[$checkout] = '<checkout>'
$roots[$work] = '<out>'
$roots[(Split-Path -Parent (Get-Command dotnet).Source)] = '<dotnet>'
$roots[[System.IO.Path]::GetTempPath()] = '<temp>'
$roots[$HOME] = '<home>'

$failed = $false
$worktreeAdded = $false
$previousHarnessRepoRoot = $env:HARNESS_REPO_ROOT
try {
    git -C $repoRoot worktree add --detach $checkout $sha
    if ($LASTEXITCODE -ne 0) { throw "git worktree add failed ($LASTEXITCODE)." }
    $worktreeAdded = $true
    foreach ($f in $overlayFiles) {
        Copy-Item -LiteralPath (Join-Path $repoRoot $f) -Destination (Join-Path $checkout $f) -Force
    }

    Push-Location $checkout
    try {
        dotnet tool restore | Out-Host
        $toolRestoreExit = $LASTEXITCODE
        $strykerLine = @(dotnet tool list --local | Where-Object { $_ -match '^\s*dotnet-stryker\s' }) | Select-Object -First 1
        $strykerVersion = if ($strykerLine -match '^\s*dotnet-stryker\s+(\S+)') { $Matches[1] } else { 'unknown' }
        $mergeBase = (git merge-base $sha $baseRef).Trim()
    }
    finally { Pop-Location }

    # The gate must resolve the temporary checkout as its repo root, not an inherited override.
    $env:HARNESS_REPO_ROOT = $null
    foreach ($proj in $projects) {
        $short = $proj -replace $testNamePrefix, ''
        $gateOut = Join-Path $work 'gate'
        $gateLog = Join-Path $work "$short.gate.log"
        $procLog = Join-Path $work "$short.processes.jsonl"
        Set-Content -LiteralPath $procLog -Value $null
        Write-Host "`n=== $proj ==="

        $sampler = Start-ThreadJob -ScriptBlock $samplerBody -ArgumentList $procLog, $checkout, @("$proj.dll"), $assemblyProbe.ToString(), $modulePattern
        $gateStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        Push-Location $checkout
        try {
            & pwsh -NoProfile -File (Join-Path $checkout 'scripts/run-mutation.ps1') -Project $proj -OutputRoot $gateOut 2>&1 |
                Tee-Object -FilePath $gateLog | Out-Host
            $gateExit = $LASTEXITCODE
        }
        finally {
            Pop-Location
            $gateStopwatch.Stop()
            Stop-Job $sampler -ErrorAction SilentlyContinue
            Remove-Job $sampler -Force -ErrorAction SilentlyContinue
        }
        $gateDurationSeconds = [math]::Round($gateStopwatch.Elapsed.TotalSeconds, 1)

        $log = @(Get-Content -LiteralPath $gateLog)
        $nativeLine = $log | Where-Object { $_ -match "^Stryker native exit for $([regex]::Escape($proj))\.csproj: (-?\d+)" } | Select-Object -First 1
        $strykerExit = if ($nativeLine -match ': (-?\d+)') { [int]$Matches[1] } else { $null }
        $verdictStart = [array]::FindLastIndex([string[]]$log, [Predicate[string]] { param($l) $l -match '^Mutation testing: ' })
        $verdictLines = if ($verdictStart -ge 0) { @($log[$verdictStart..($log.Count - 1)] | Where-Object { $_.Trim() }) } else { @() }

        $projOut = Join-Path $gateOut $proj
        $reportPath = Join-Path $projOut 'reports/mutation-report.json'
        $configPath = Join-Path $projOut 'stryker-config.json'
        if (-not (Test-Path -LiteralPath $reportPath) -or -not (Test-Path -LiteralPath $configPath)) {
            Write-Host "Mutation receipt: FAILED - no report or effective config for $proj under $projOut (gate exit $gateExit)."
            $failed = $true
            continue
        }
        $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
        $effective = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        $testProjects = @($effective.'stryker-config'.'test-projects')

        # Clean identity: rebuild the test projects unmutated, then hash the same paths.
        $cleanBuildExit = 0
        foreach ($tp in $testProjects) {
            dotnet build $tp -c Debug --no-incremental -nologo -v q | Out-Host
            if ($LASTEXITCODE -ne 0) { $cleanBuildExit = $LASTEXITCODE }
        }
        $processes = @(Get-Content -LiteralPath $procLog | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json -DateKind String } |
                Group-Object pid | ForEach-Object { $_.Group[-1] })
        . $assemblyProbe
        $observations = @(foreach ($p in $processes) {
                foreach ($t in @($p.targets)) {
                    $clean = $null
                    if (Test-Path -LiteralPath $t.path) {
                        try { $clean = Get-AssemblyIdentity -Path $t.path } catch { $clean = $null }
                    }
                    [ordered]@{
                        pid               = $p.pid
                        path              = $t.path
                        runSha256         = $t.sha256
                        runStrykerTypes   = $t.strykerTypes
                        cleanSha256       = if ($clean) { $clean.sha256 } else { $null }
                        cleanStrykerTypes = if ($clean) { $clean.strykerTypes } else { $null }
                    }
                }
            })
        # A load whose run hash could not be computed is never evidence of a mutated assembly.
        $mutatedLoads = @($observations | Where-Object { $_.runSha256 -and $_.runStrykerTypes -gt 0 -and $_.runSha256 -ne $_.cleanSha256 })
        $verdict, $note = if ($processes.Count -eq 0) {
            'not-observed', 'The sampler observed no test process for this run. This receipt carries no assembly-loading evidence; absence of evidence is not proof of linkage.'
        }
        elseif ($observations.Count -eq 0) {
            'not-observed', "The sampler observed $($processes.Count) process(es), but none loaded $proj.dll while it was sampled."
        }
        elseif ($mutatedLoads.Count -gt 0) {
            'mutated-assembly-loaded', "$($mutatedLoads.Count) of $($observations.Count) observed load(s) of $proj.dll contain Stryker types and differ from the clean rebuild of the same path (where that path still exists): the test process ran the mutated assembly."
        }
        else {
            'inconclusive', "$($observations.Count) load(s) of $proj.dll were observed, but none contained Stryker types that differ from the clean rebuild (for example only the initial unmutated test run was sampled)."
        }

        $mutants = @(Get-ReceiptMutants -Report $report -Checkout $checkout)
        $receipt = [ordered]@{
            ticket         = $Ticket
            project        = $proj
            testNamePrefix = $testNamePrefix
            generatedUtc   = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
            measured       = [ordered]@{ commit = $sha; remoteBranches = $remoteBranches; baseRef = $baseRef; mergeBase = $mergeBase }
            tooling        = [ordered]@{ commit = $toolingCommit; dirty = $toolingDirty; overlaid = $overlay }
            strykerVersion = $strykerVersion
            threshold      = $effective.'stryker-config'.thresholds.break
            effectiveConfig = $effective
            testProjects   = @($testProjects | ForEach-Object { [System.IO.Path]::GetRelativePath($checkout, $_).Replace('\', '/') })
            exits          = [ordered]@{ toolRestore = $toolRestoreExit; gate = $gateExit; stryker = $strykerExit; cleanBuild = $cleanBuildExit }
            durationSeconds = $gateDurationSeconds
            gate           = [ordered]@{ verdictLines = $verdictLines }
            mutatedFiles   = @($mutants | ForEach-Object { $_.file } | Select-Object -Unique)
            counts         = Get-MutationCounts -Report $report
            mutants        = $mutants
            processes      = @($processes | ForEach-Object {
                    [ordered]@{ pid = $_.pid; name = $_.name; parentPid = $_.parentPid; parentName = $_.parentName; commandLine = $_.commandLine; firstSeenUtc = $_.firstSeenUtc; modules = @($_.modules) }
                })
            assembly       = [ordered]@{ module = "$proj.dll"; verdict = $verdict; note = $note; observations = $observations }
        }

        $portable = ConvertTo-PortableText -Text ($receipt | ConvertTo-Json -Depth 20) -Roots $roots
        $outDir = Join-Path $receiptRoot $short
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $outDir 'receipt.json'), $portable + "`n", [System.Text.UTF8Encoding]::new($false))
        Write-ReceiptMarkdown -Receipt ($portable | ConvertFrom-Json -DateKind String) -Path (Join-Path $outDir 'receipt.md')
        Write-Host "Receipt written: $outDir (gate exit $gateExit, Stryker exit $strykerExit, evidence $verdict)"
    }
}
catch {
    Write-Host "Mutation receipt: FAILED - $($_.Exception.Message)"
    $failed = $true
}
finally {
    # Restore the caller's value; assigning $null leaves it unset if it was unset before.
    $env:HARNESS_REPO_ROOT = $previousHarnessRepoRoot
    if ($worktreeAdded -and -not $KeepCheckout) {
        git -C $repoRoot worktree remove --force $checkout
    }
    Write-Host "Work root (logs, full reports): $work"
}

exit ([int]$failed)
