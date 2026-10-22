#!/usr/bin/env pwsh
# Runs Stryker.NET mutation testing on the changed production C# files of a repo.
# Exits 0 on PASS, 1 on FAIL, 2 on SKIPPED (no production files changed) or NOT
# APPLICABLE (every changed project listed in gates.mutation.exclusions). -Help
# prints the exit-code table, and the adapters carry the same table.
#
# Worktree-safe replacement for `dotnet stryker --since`:
# In Stryker 4.16.0 the built-in `since` filter resolved linked git worktrees to the
# main checkout and measured nothing; it has not been re-verified on 5.0.0, so it stays
# disabled. This script discovers changed production files via git merge-base, maps them
# to project-relative mutate globs, generates temporary configs in the system temp
# directory with since disabled, and executes Stryker sequentially per project.
#
# Test runner: the tracked stryker-config.json names the runner, and this gate never
# guesses it. xUnit v3 test projects are executables, so under VSTest their tests run in
# a child of testhost that never sees the active mutant and every mutant survives; those
# repos set test-runner=mtp with coverage off, and every generated config carries the
# additional-timeout allowance and an explicit test-projects list that excludes
# *.ArchitectureTests and *.IntegrationTests. The first fails on the Stryker.* types
# injected into every mutated assembly, which is an artifact kill, and the second holds
# the real-database tests this run does not drive. See harness.yml.example
# for the config keys this gate reads.
#
# Usage:
#   ./scripts/run-mutation.ps1
#   ./scripts/run-mutation.ps1 -BaseRef origin/main
#   ./scripts/run-mutation.ps1 -DryRun
#   ./scripts/run-mutation.ps1 -Project <name> -OutputRoot <dir outside the repo>
#   ./scripts/run-mutation.ps1 -WholeProject -OutputRoot <dir outside the repo>
#   ./scripts/run-mutation.ps1 -EvaluateReport <path/to/mutation-report.json>

[CmdletBinding()]
param(
    [string]$BaseRef = '',
    [switch]$DryRun,
    [switch]$WholeProject,
    [string]$EvaluateReport = '',
    [string[]]$ScopeFile = @(),
    [string[]]$Project = @(),
    [string]$OutputRoot = '',
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_gate-common.ps1')

$gateStartUtc = [DateTime]::UtcNow

# The exit-code contract of this gate. -Help prints this table and the host
# adapters carry a copy of it, so the texts stay identical line for line after the
# leading whitespace on each line is trimmed.
<#
EXIT CODES:
| Exit | Verdict | Meaning | Blocking |
|---|---|---|---|
| 0 | `PASSED` | At least one eligible changed project was mutated, every eligible result is at or above `gates.mutation.threshold`, no test kills more than `gates.mutation.maxKillShare` percent of tested mutants (or the run tested fewer than 20), no test kills mutants in more than `gates.mutation.maxKillFileSpan` source files, each configured exclusion is printed as NOT APPLICABLE with its reason, and no unlisted ineligible project exists. | — |
| 1 | `FAILED` | A score below threshold, a Stryker failure, invalid configuration (including `gates.mutation.maxKillShare` outside 1 to 100 or not an integer, or `gates.mutation.maxKillFileSpan` below 1 or not an integer), a suspected artifact kill (one test killed more than `gates.mutation.maxKillShare` percent of tested mutants, or killed mutants in more than `gates.mutation.maxKillFileSpan` source files), or any changed project with no eligible test project that is not in `gates.mutation.exclusions`. | Yes, on every tier |
| 2 | `SKIPPED` | No production C# changed (scope-empty). | No; reported as `SKIPPED (scope-empty)`, never PASS |
| 2 | `NOT APPLICABLE` | Every changed project is explicitly listed in `gates.mutation.exclusions`; nothing was mutated. | No; reported as N/A, never PASS |

The table describes a real run. -DryRun starts no Stryker process, so its exit 0 means
classification passed and is never the `PASSED` row above.
#>

if ($Help) {
    Write-Output @'
Usage: run-mutation.ps1 [OPTIONS]

Runs Stryker.NET mutation testing on the changed production C# files of this repo.
The threshold is read from harness.yml at gates.mutation.threshold (default: 80).
The artifact-kill share limit is read from gates.mutation.maxKillShare (default: 50).
The artifact-kill file-span limit is read from gates.mutation.maxKillFileSpan (default: 15).

OPTIONS:
  -BaseRef <ref>          Git ref to diff against (default: origin/<baseBranch> from harness.yml)
  -DryRun                 Classify changed projects and generate temp configs without running Stryker; a clean exit is a classification verdict, never mutation proof
  -EvaluateReport <path>  Evaluate an existing Stryker mutation report without running Stryker (skips changed-file containment checks unless -ScopeFile is set)
  -ScopeFile <path[]>     With -EvaluateReport, repo-relative files that form the diff. Omit it and containment checks stay skipped
  -Project <name[]>       Only run these projects (e.g. Contoso.Api or Contoso.Api.csproj); a name with no changed files is an error
  -WholeProject           Mutate whole projects on every run, ignoring the diff scope (never scope-empty; since never enabled): the -Project names, else gates.mutation.wholeProject, else the one production project that has an eligible test project and is not excluded
  -OutputRoot <dir>       Where Stryker output goes, one <Project> folder each (default: <system temp>/stryker/<UTC yyyyMMdd-HHmmss>-<6 hex>, or <system temp>/stryker-whole in -WholeProject mode; must be outside the repo)
  -Help                   Show this help

CONFIGURATION:
  harness.yml gates.mutation.exclusions maps a changed project name (no .csproj
  suffix, matched ordinal-ignore-case) to the reason printed with its NOT APPLICABLE
  classification. A blank reason and a .csproj suffix are configuration errors that
  exit 1 before any Stryker run. A reason must not contain " #": the harness.yml
  subset treats a # that starts a token as a comment, so the rest of the line would
  be dropped. That limitation is documented here and not validated.

  gates.mutation.maxKillShare is an integer from 1 to 100 (default 50): the largest
  percentage of tested mutants one test may kill. A test above it fails the gate as a
  suspected artifact kill, because a test that fails on every run (state leaking across
  mutant runs) inflates the score. The share is killed mutants per test over tested
  mutants (killed, timeout, survived and no-coverage), and a value above the limit fails.
  The rule is not applied when fewer than 20 mutants were tested, since one test can then
  legitimately hold most of a small sample; the output says when it was skipped. Any other
  value, or a non-integer, is a configuration error that exits 1 before any Stryker run.

  gates.mutation.maxKillFileSpan is an integer of at least 1 (default 15): the most
  distinct source files one test may kill mutants in. A unit test exercises a few related
  types, so a test above it fails the gate as a suspected artifact kill. It catches a
  state-leaking test that fails for a run of consecutive mutants spread across unrelated
  files, which can stay under the share limit. A value below 1, or a non-integer, is a
  configuration error that exits 1 before any Stryker run.

  stryker-config.json must name its test-runner (vstest or mtp), and - when it names
  mtp - set coverage-analysis=off and an integer additional-timeout of at least 30000
  (milliseconds); the gate copies all of them into the config it generates. A smaller
  allowance lets a slow machine turn survivors into timeouts, which Stryker counts as
  detected, so the score rises without any test catching the mutant. `harness.yml
  gates.mutation.runner` is what install.ps1 renders into that file.

  gates.mutation.concurrency is an integer of at least 1 (default: half the
  runner's logical cores, Stryker's own default): how many test runners Stryker
  runs in parallel. The gate copies it into the config it generates. Higher
  values over-subscribe the runner and turn surviving mutants into timeouts,
  which Stryker counts as detected, so the score rises without any test
  catching the mutant. It is a measurement knob, not a speed knob.

  Scope: every changed *.cs file that belongs to a project which is not a test
  project, minus migrations under Persistence/Migrations and anything under
  bin, obj, node_modules, artifacts or a nested worktree. A changed file in no
  project at all cannot produce mutants, so it is listed and skipped. A repo
  whose production code does not live under src/ needs no configuration for
  this: the layout comes from the project files, not from a path prefix.

  Every real run writes mutation-timing.json next to the per-project folders under the
  output root: total and per-project wall time in seconds, mutant counts, score, and
  the concurrency used, so per-run gate time can be tracked over time.

EXAMPLES:
  ./scripts/run-mutation.ps1
  ./scripts/run-mutation.ps1 -BaseRef origin/main
  ./scripts/run-mutation.ps1 -DryRun
  ./scripts/run-mutation.ps1 -Project Contoso.Infrastructure,Contoso.Api
  ./scripts/run-mutation.ps1 -EvaluateReport <output root>/Contoso.Api/reports/mutation-report.json

EXIT CODES:
  A real run reports these outcomes; -DryRun starts no Stryker process, so its exit 0
  means classification passed and is never the PASSED row.

| Exit | Verdict | Meaning | Blocking |
|---|---|---|---|
| 0 | `PASSED` | At least one eligible changed project was mutated, every eligible result is at or above `gates.mutation.threshold`, no test kills more than `gates.mutation.maxKillShare` percent of tested mutants (or the run tested fewer than 20), no test kills mutants in more than `gates.mutation.maxKillFileSpan` source files, each configured exclusion is printed as NOT APPLICABLE with its reason, and no unlisted ineligible project exists. | — |
| 1 | `FAILED` | A score below threshold, a Stryker failure, invalid configuration (including `gates.mutation.maxKillShare` outside 1 to 100 or not an integer, or `gates.mutation.maxKillFileSpan` below 1 or not an integer), a suspected artifact kill (one test killed more than `gates.mutation.maxKillShare` percent of tested mutants, or killed mutants in more than `gates.mutation.maxKillFileSpan` source files), or any changed project with no eligible test project that is not in `gates.mutation.exclusions`. | Yes, on every tier |
| 2 | `SKIPPED` | No production C# changed (scope-empty). | No; reported as `SKIPPED (scope-empty)`, never PASS |
| 2 | `NOT APPLICABLE` | Every changed project is explicitly listed in `gates.mutation.exclusions`; nothing was mutated. | No; reported as N/A, never PASS |
'@
    exit 0
}

function Get-ReportTestIndex {
    # Maps each test id in a schema-2 report's testFiles to its name and file, so
    # killedBy ids can be attributed. Reports without testFiles yield an empty map.
    param($Report)

    $index = @{}
    if ($Report.PSObject.Properties.Match('testFiles').Count -eq 0 -or -not $Report.testFiles) {
        return $index
    }
    foreach ($tf in $Report.testFiles.PSObject.Properties) {
        if ($tf.Value.PSObject.Properties.Match('tests').Count -eq 0) { continue }
        foreach ($t in @($tf.Value.tests)) {
            $index[[string]$t.id] = [PSCustomObject]@{ Name = [string]$t.name; File = [string]$tf.Name }
        }
    }
    return $index
}

function Test-ArchitectureTestKiller {
    param($Test)

    return ($Test.File -match '[\\/]([^\\/]*\.)?ArchitectureTests[\\/]') -or
           ($Test.Name -match '(^|\.)ArchitectureTests\.')
}

function Get-EligibleTestProjects {
    # Test projects that directly reference the mutated project, minus ArchitectureTests and IntegrationTests.
    # Stryker's project mode needs a direct reference; listing them explicitly keeps
    # ArchitectureTests (artifact kills) and IntegrationTests (real-database tests) out of the run.
    param(
        [string[]]$TestProjects,
        [string]$MutatedProjectPath
    )

    $target = [System.IO.Path]::GetFullPath($MutatedProjectPath)
    $eligible = foreach ($tp in $TestProjects) {
        if ([System.IO.Path]::GetFileNameWithoutExtension($tp) -match '(^|\.)(ArchitectureTests|IntegrationTests)$') { continue }
        $tpDir = Split-Path $tp -Parent
        $xml = [xml](Get-Content -LiteralPath $tp -Raw)
        $refs = @($xml.SelectNodes('//*[local-name()="ProjectReference"]/@Include') | ForEach-Object { $_.Value })
        foreach ($ref in $refs) {
            $refFull = [System.IO.Path]::GetFullPath((Join-Path $tpDir ($ref -replace '[\\/]', [System.IO.Path]::DirectorySeparatorChar)))
            if ($refFull.Equals($target, [System.StringComparison]::OrdinalIgnoreCase)) {
                $tp
                break
            }
        }
    }
    return @($eligible | Sort-Object)
}

function Evaluate-MutationReport {
    param(
        [string]$ReportPath,
        [int]$NativeExitCode,
        [string]$ProjectName,
        [string[]]$ChangedFiles,
        [int]$Threshold,
        [string]$RepoRoot,
        [int]$MaxKillShare = 50,
        [int]$MaxKillFileSpan = 15
    )

    $failureReasons = [System.Collections.Generic.List[string]]::new()
    $survivingMutants = [System.Collections.Generic.List[PSCustomObject]]::new()
    $mutatedFiles = [System.Collections.Generic.List[string]]::new()
    $outsideFiles = [System.Collections.Generic.List[string]]::new()
    $filesWithMutantsNoneTested = [System.Collections.Generic.List[string]]::new()
    $artifactKillers = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
    $artifactKills = 0
    $unattributedKills = 0

    if ($NativeExitCode -ne 0) {
        $failureReasons.Add("Native exit code was non-zero ($NativeExitCode).")
    }

    if (-not $ReportPath -or -not (Test-Path -LiteralPath $ReportPath)) {
        $failureReasons.Add("Mutation report not found or was not generated.")
        return [PSCustomObject]@{
            ProjectName                = $ProjectName
            ReportPath                 = $ReportPath
            NativeExitCode             = $NativeExitCode
            Killed                     = 0
            Survived                   = 0
            Timeout                    = 0
            NoCoverage                 = 0
            Ignored                    = 0
            CompileError               = 0
            TotalMutants               = 0
            Tested                     = 0
            Score                      = $null
            SinceFilterIgnoredCount    = 0
            ArtifactKills              = 0
            UnattributedKills          = 0
            KillShareNote              = 'not applied (no report)'
            KillFileSpanNote           = 'not applied (no report)'
            MutatedFiles               = @()
            OutsideMutatedFiles        = @()
            FilesWithMutantsNoneTested = @()
            SurvivingMutants           = @()
            FailureReasons             = @($failureReasons)
            Passed                     = $false
        }
    }

    $report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
    $testIndex = Get-ReportTestIndex -Report $report

    $killed = 0
    $survived = 0
    $timeout = 0
    $noCoverage = 0
    $ignored = 0
    $compileError = 0
    $sinceFilterIgnoredCount = 0
    # Killed mutants per test id, for the artifact-kill share rule below.
    $killsByTest = @{}
    # Distinct source files each test id killed a mutant in, for the file-span rule below.
    $killFilesByTest = @{}

    if ($report.PSObject.Properties.Match('files').Count -gt 0 -and $report.files) {
        foreach ($fileProp in $report.files.PSObject.Properties) {
            $fileKey = $fileProp.Name
            $fileData = $fileProp.Value

            $fileRel = if ([System.IO.Path]::IsPathRooted($fileKey)) {
                [System.IO.Path]::GetRelativePath($RepoRoot, $fileKey).Replace('\', '/')
            }
            else {
                $fileKey.Replace('\', '/')
            }

            $mutants = @($fileData.mutants)
            $mutantCount = $mutants.Count

            if ($mutantCount -gt 0) {
                $mutatedFiles.Add($fileRel)

                $isChanged = $false
                foreach ($cf in $ChangedFiles) {
                    if ($cf.Equals($fileRel, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $isChanged = $true
                        break
                    }
                }

                $fileTested = 0
                $mutateFilterRemoved = 0
                $filterResidue = 0
                foreach ($m in $mutants) {
                    $status = [string]$m.status
                    $hasReason = ($m.PSObject.Properties.Match('statusReason').Count -gt 0)
                    $reason = if ($hasReason) { [string]$m.statusReason } else { '' }

                    if ($reason -match 'Removed by since filter') {
                        $sinceFilterIgnoredCount++
                    }

                    # "Removed by mutate filter" marks a file the mutate glob left out.
                    # A CompileError beside those is Stryker compiling that filtered
                    # mutant and rolling it back, so it stays out of the diff scope.
                    $removedByMutateFilter = $reason -match 'Removed by mutate filter'
                    if ($removedByMutateFilter) { $mutateFilterRemoved++ }
                    if ($removedByMutateFilter -or $status -eq 'CompileError') { $filterResidue++ }

                    switch ($status) {
                        'Killed' {
                            $killed++
                            $fileTested++
                            # Every kill must name a resolvable test, and none may come from
                            # ArchitectureTests (artifact kill on the injected Stryker.* types).
                            $killerIds = @(if ($m.PSObject.Properties.Match('killedBy').Count -gt 0) { $m.killedBy | Where-Object { $_ } })
                            $unresolved = ($killerIds.Count -eq 0)
                            $isArtifact = $false
                            foreach ($kid in $killerIds) {
                                $killer = $testIndex[[string]$kid]
                                if ($null -eq $killer) { $unresolved = $true; continue }
                                if (Test-ArchitectureTestKiller -Test $killer) {
                                    $isArtifact = $true
                                    [void]$artifactKillers.Add($killer.Name)
                                }
                            }
                            if ($unresolved) { $unattributedKills++ }
                            if ($isArtifact) { $artifactKills++ }
                            # One kill per test per mutant, even if killedBy names it twice.
                            foreach ($kid in @($killerIds | Select-Object -Unique)) {
                                $killsByTest[[string]$kid] = 1 + [int]$killsByTest[[string]$kid]
                                if (-not $killFilesByTest.ContainsKey([string]$kid)) {
                                    $killFilesByTest[[string]$kid] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                                }
                                [void]$killFilesByTest[[string]$kid].Add($fileRel)
                            }
                        }
                        'Survived' {
                            $survived++
                            $fileTested++
                            $hasLocation = ($m.PSObject.Properties.Match('location').Count -gt 0)
                            $line = if ($hasLocation -and $m.location -and $m.location.PSObject.Properties.Match('start').Count -gt 0 -and $m.location.start) { [int]$m.location.start.line } else { 0 }
                            $hasMutator = ($m.PSObject.Properties.Match('mutatorName').Count -gt 0)
                            $mutator = if ($hasMutator -and $m.mutatorName) { [string]$m.mutatorName } else { 'Unknown' }
                            $survivingMutants.Add([PSCustomObject]@{
                                File    = $fileRel
                                Line    = $line
                                Mutator = $mutator
                            })
                        }
                        'Timeout' {
                            $timeout++
                            $fileTested++
                        }
                        'NoCoverage' {
                            $noCoverage++
                            $fileTested++
                        }
                        'Ignored' {
                            $ignored++
                        }
                        'CompileError' {
                            $compileError++
                        }
                    }
                }

                $fileRemovedByMutateFilter = ($mutateFilterRemoved -gt 0) -and ($filterResidue -eq $mutantCount)
                if (-not $isChanged -and $ChangedFiles.Count -gt 0 -and -not $fileRemovedByMutateFilter) {
                    $outsideFiles.Add($fileRel)
                }

                if ($isChanged -and $fileTested -eq 0) {
                    $filesWithMutantsNoneTested.Add("$fileRel ($mutantCount mutant(s), 0 tested)")
                }
            }
        }
    }

    $tested = $killed + $timeout + $survived + $noCoverage
    $totalMutants = $killed + $survived + $timeout + $noCoverage + $ignored + $compileError

    $score = if ($tested -gt 0) {
        [double]($killed + $timeout) / [double]$tested * 100.0
    }
    else {
        $null
    }

    if ($sinceFilterIgnoredCount -gt 0) {
        $failureReasons.Add("$sinceFilterIgnoredCount mutant(s) ignored with 'Removed by since filter' (since filter leaked back in).")
    }

    if ($outsideFiles.Count -gt 0) {
        $failureReasons.Add("Mutated file(s) outside changed files: $($outsideFiles -join ', ').")
    }

    if ($filesWithMutantsNoneTested.Count -gt 0) {
        $failureReasons.Add("Changed file(s) have mutants but none were tested: $($filesWithMutantsNoneTested -join ', ').")
    }

    if ($totalMutants -gt 0 -and $tested -eq 0) {
        $failureReasons.Add("Invocation has $totalMutants mutant(s) but 0 tested (no score).")
    }

    if ($tested -gt 0 -and $killed -eq 0) {
        $failureReasons.Add("Killed 0 of $tested tested mutant(s) ($timeout timeout) - this indicates a mutant-to-test linkage or measurement failure, not a test-quality verdict.")
    }

    if ($artifactKills -gt 0) {
        $shown = @($artifactKillers | Select-Object -First 5)
        $more = if ($artifactKillers.Count -gt $shown.Count) { ", +$($artifactKillers.Count - $shown.Count) more" } else { '' }
        $failureReasons.Add("Artifact kill: $artifactKills killed mutant(s) attributed to ArchitectureTests test(s) ($($shown -join ', ')$more); these fail on Stryker's injected types, not on the mutation.")
    }

    if ($unattributedKills -gt 0) {
        $failureReasons.Add("$unattributedKills killed mutant(s) have no killedBy test names resolvable through testFiles; artifact kills cannot be ruled out.")
    }

    # Share rule: one test killing more than MaxKillShare percent of tested mutants is a
    # suspected artifact kill (a state-leaking test fails on every run and inflates the
    # score). Below 20 tested mutants one test can legitimately hold most of a small sample,
    # so the rule is not applied there and the output says so. The comparison is exact
    # integer arithmetic (kills * 100 > limit * tested), so a share exactly at the limit passes.
    $killShareMinTested = 20
    $killShareNote = ''
    if ($tested -lt $killShareMinTested) {
        $killShareNote = "not applied ($tested tested is below the $killShareMinTested-mutant minimum)"
    }
    else {
        $topSharePct = 0.0
        $overShare = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($testId in $killsByTest.Keys) {
            $count = [int]$killsByTest[$testId]
            $sharePct = [double]$count / [double]$tested * 100.0
            if ($sharePct -gt $topSharePct) { $topSharePct = $sharePct }
            if (($count * 100) -gt ($MaxKillShare * $tested)) {
                $killer = $testIndex[[string]$testId]
                $killerName = if ($null -ne $killer) { $killer.Name } else { [string]$testId }
                $overShare.Add([PSCustomObject]@{ Name = $killerName; Count = $count; Pct = $sharePct })
            }
        }
        # Invariant culture so the wording and decimal point do not change with the machine locale.
        $invariant = [System.Globalization.CultureInfo]::InvariantCulture
        $killShareNote = "largest single-test share $($topSharePct.ToString('N2', $invariant))% of $tested tested (limit $MaxKillShare%)"

        if ($overShare.Count -gt 0) {
            $ranked = @($overShare | Sort-Object -Property @{ Expression = { $_.Count }; Descending = $true }, Name)
            $shown = @($ranked | Select-Object -First 3 | ForEach-Object {
                    "$($_.Name) killed $($_.Count) of $tested tested mutants ($($_.Pct.ToString('N1', $invariant))%), above the $MaxKillShare% limit"
                })
            $more = if ($ranked.Count -gt $shown.Count) { "; +$($ranked.Count - $shown.Count) more" } else { '' }
            $failureReasons.Add("Suspected artifact kill: $($shown -join '; ')$more. A test that fails on every run inflates the score; check it for state shared across mutant runs.")
        }
    }

    # File-span rule: a unit test exercises a few related types, so one test killing mutants
    # in more than MaxKillFileSpan distinct source files is a suspected artifact kill. It
    # catches a contaminating mutant that the share rule misses: a test that fails for a
    # stride of consecutive mutant runs spread across unrelated files (measured on a real
    # repo: clean whole-project runs peaked at 9 files per test, a contaminated run at 26).
    # Unlike the share rule it needs no sample minimum, because a small run cannot reach
    # the span limit.
    $topSpan = 0
    $overSpan = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($testId in $killFilesByTest.Keys) {
        $span = $killFilesByTest[$testId].Count
        if ($span -gt $topSpan) { $topSpan = $span }
        if ($span -gt $MaxKillFileSpan) {
            $killer = $testIndex[[string]$testId]
            $killerName = if ($null -ne $killer) { $killer.Name } else { [string]$testId }
            $overSpan.Add([PSCustomObject]@{ Name = $killerName; Span = $span })
        }
    }
    $killFileSpanNote = "largest single-test file span $topSpan file(s) (limit $MaxKillFileSpan)"
    if ($overSpan.Count -gt 0) {
        $ranked = @($overSpan | Sort-Object -Property @{ Expression = { $_.Span }; Descending = $true }, Name)
        $shown = @($ranked | Select-Object -First 3 | ForEach-Object {
                "$($_.Name) killed mutants in $($_.Span) files, above the $MaxKillFileSpan-file limit"
            })
        $more = if ($ranked.Count -gt $shown.Count) { "; +$($ranked.Count - $shown.Count) more" } else { '' }
        $failureReasons.Add("Suspected artifact kill: $($shown -join '; ')$more. A unit test reaching that many unrelated files is failing for a reason outside the mutation; check for state shared across mutant runs.")
    }

    if ($score -ne $null -and $score -lt $Threshold) {
        $scoreStr = "{0:N2}%" -f $score
        $failureReasons.Add("Score $scoreStr is below threshold $Threshold%.")
    }

    $passed = ($failureReasons.Count -eq 0)

    return [PSCustomObject]@{
        ProjectName                = $ProjectName
        ReportPath                 = $ReportPath
        NativeExitCode             = $NativeExitCode
        Killed                     = $killed
        Survived                   = $survived
        Timeout                    = $timeout
        NoCoverage                 = $noCoverage
        Ignored                    = $ignored
        CompileError               = $compileError
        TotalMutants               = $totalMutants
        Tested                     = $tested
        Score                      = $score
        SinceFilterIgnoredCount    = $sinceFilterIgnoredCount
        ArtifactKills              = $artifactKills
        UnattributedKills          = $unattributedKills
        KillShareNote              = $killShareNote
        KillFileSpanNote           = $killFileSpanNote
        MutatedFiles               = @($mutatedFiles)
        OutsideMutatedFiles        = @($outsideFiles)
        FilesWithMutantsNoneTested = @($filesWithMutantsNoneTested)
        SurvivingMutants           = @($survivingMutants)
        FailureReasons             = @($failureReasons)
        Passed                     = $passed
    }
}

$repoRoot = if ($env:HARNESS_REPO_ROOT) {
    (Resolve-Path -LiteralPath $env:HARNESS_REPO_ROOT).Path
}
else {
    $currentGitRoot = git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($currentGitRoot)) {
        (Resolve-Path -LiteralPath $currentGitRoot.Trim()).Path
    }
    else {
        Get-RepoRoot
    }
}

# Precondition check: dotnet-tools manifest
$manifestPath = Join-Path $repoRoot '.config/dotnet-tools.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    Write-Host 'GATE NOT WIRED: .config/dotnet-tools.json is missing.'
    exit 1
}

$manifestContent = Get-Content -LiteralPath $manifestPath -Raw
if ($manifestContent -notmatch '"dotnet-stryker"') {
    Write-Host 'GATE NOT WIRED: dotnet-stryker is not present in .config/dotnet-tools.json.'
    exit 1
}

# Read threshold from harness.yml
$threshold = Get-HarnessValue -Key 'gates.mutation.threshold' -RepoRoot $repoRoot
if ($threshold -eq $null) {
    $threshold = 80
}

# Exclusion policy, keyed the way -Project names projects and matched ordinal-ignore-case.
# Read and validated here, above the scope-empty check, so an entry with a blank reason or
# a .csproj name is a configuration error even when the diff carries no production C#.
try {
    $exclusionReasons = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @(Get-HarnessMap -Key 'gates.mutation.exclusions' -RepoRoot $repoRoot)) {
        $exclusionReasons[[string]$entry.Project] = [string]$entry.Reason
    }
}
catch {
    Write-Host "Mutation testing: FAILED - invalid mutation configuration in harness.yml gates.mutation.exclusions: $($_.Exception.Message)"
    exit 1
}

# Artifact-kill share limit (percent of tested mutants). Validated before the scope-empty
# check, like the exclusions, so a bad value fails the same way on every diff.
try {
    $maxKillShare = Get-HarnessValue -Key 'gates.mutation.maxKillShare' -RepoRoot $repoRoot
    if ($null -eq $maxKillShare) { $maxKillShare = 50 }
    $maxKillShare = [int]$maxKillShare
    if ($maxKillShare -lt 1 -or $maxKillShare -gt 100) {
        throw "must be an integer from 1 to 100, got '$maxKillShare'"
    }
}
catch {
    Write-Host "Mutation testing: FAILED - invalid mutation configuration in harness.yml gates.mutation.maxKillShare: $($_.Exception.Message)"
    exit 1
}

# Artifact-kill file-span limit (distinct source files one test may kill mutants in).
try {
    $maxKillFileSpan = Get-HarnessValue -Key 'gates.mutation.maxKillFileSpan' -RepoRoot $repoRoot
    if ($null -eq $maxKillFileSpan) { $maxKillFileSpan = 15 }
    $maxKillFileSpan = [int]$maxKillFileSpan
    if ($maxKillFileSpan -lt 1) {
        throw "must be an integer of at least 1, got '$maxKillFileSpan'"
    }
}
catch {
    Write-Host "Mutation testing: FAILED - invalid mutation configuration in harness.yml gates.mutation.maxKillFileSpan: $($_.Exception.Message)"
    exit 1
}

# Test-runner parallelism. Defaults to half the runner's logical cores, Stryker's
# own default and recommended ceiling: full-core parallelism was measured to turn
# surviving mutants into timeouts and flip gate verdicts, and Stryker itself warns
# above half cores. An explicit harness value tunes it without touching the
# threshold.
try {
    $concurrency = Get-HarnessValue -Key 'gates.mutation.concurrency' -RepoRoot $repoRoot
    if ($null -eq $concurrency) { $concurrency = [Math]::Max(1, [int][Math]::Floor([Environment]::ProcessorCount / 2)) }
    $concurrency = [int]$concurrency
    if ($concurrency -lt 1) {
        throw "must be an integer of at least 1, got '$concurrency'"
    }
}
catch {
    Write-Host "Mutation testing: FAILED - invalid mutation configuration in harness.yml gates.mutation.concurrency: $($_.Exception.Message)"
    exit 1
}

# Direct report evaluation mode (e.g. fail-safe verification / regression check)
if (-not [string]::IsNullOrWhiteSpace($EvaluateReport)) {
    $evalPath = if ([System.IO.Path]::IsPathRooted($EvaluateReport)) {
        $EvaluateReport
    }
    else {
        Join-Path (Get-Location).Path $EvaluateReport
    }

    if (-not (Test-Path -LiteralPath $evalPath)) {
        Write-Host "Mutation testing: FAILED - report file not found at '$evalPath'."
        exit 1
    }

    Write-Host "Evaluating Stryker mutation report: $evalPath"
    $reportScope = @(
        $ScopeFile |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Trim().Replace('\', '/') }
    )
    $eval = Evaluate-MutationReport `
        -ReportPath $evalPath `
        -NativeExitCode 0 `
        -ProjectName (Split-Path $evalPath -Leaf) `
        -ChangedFiles $reportScope `
        -Threshold $threshold `
        -RepoRoot $repoRoot `
        -MaxKillShare $maxKillShare `
        -MaxKillFileSpan $maxKillFileSpan

    Write-Host "`nProject: $($eval.ProjectName)"
    Write-Host "  Report: $($eval.ReportPath)"
    Write-Host ("  Mutants: {0} | Killed: {1} | Survived: {2} | Timeout: {3} | NoCoverage: {4} | Ignored: {5} | CompileError: {6}" -f `
        $eval.TotalMutants, $eval.Killed, $eval.Survived, $eval.Timeout, $eval.NoCoverage, $eval.Ignored, $eval.CompileError)
    $scoreText = if ($eval.Score -ne $null) { ("{0:N2}%" -f $eval.Score) } else { 'N/A (0 tested)' }
    Write-Host ("  Tested:  {0} | Score: {1} (Threshold: {2}%, {3} timeout)" -f $eval.Tested, $scoreText, $threshold, $eval.Timeout)
    Write-Host "  Kill share: $($eval.KillShareNote)"
    Write-Host "  Kill file span: $($eval.KillFileSpanNote)"

    if ($eval.SurvivingMutants.Count -gt 0) {
        Write-Host "`nSurviving mutants ($($eval.SurvivingMutants.Count)):"
        foreach ($sm in $eval.SurvivingMutants) {
            Write-Host "  $($sm.File):$($sm.Line) [$($sm.Mutator)]"
        }
    }

    if ($eval.Passed) {
        Write-Host "`nMutation testing: PASSED (score >= $threshold% on tested mutants)."
        exit 0
    }
    else {
        Write-Host "`nMutation testing: FAILED"
        foreach ($reason in $eval.FailureReasons) {
            Write-Host "  - $reason"
        }
        exit 1
    }
}

# Whole-project mode: mutate whole projects on every run. It branches above the
# base-ref/merge-base resolution and diff discovery below, so a zero-diff run is
# never scope-empty and no origin/<base> lookup happens (the shallow checkout
# needs no fetch-depth change). The enumerated files under each project's mutate
# scope become the changed-file set, so the outside-changed-files and
# changed-files-none-tested guards in Evaluate-MutationReport still mean
# something instead of tripping on every file or silently never firing.
#
# The target comes from the repo's own project files, never a hardcoded path:
# -Project names it, else harness.yml gates.mutation.wholeProject does, else the
# one production project that has an eligible test project and is not excluded is
# chosen. More than one candidate is an error that names them all, because mutating
# whichever project happens to sort first would make a failing gate unauditable.
$projectGroups = [ordered]@{}
$projectDirs = @{}
$projectPaths = @{}
$changedFiles = @()
# Filled on demand: an empty diff exits before anything needs the solution.
$allTestProjects = $null

function Get-ProjectSourceFiles {
    <#
      A project's own C# files, as repo-relative mutate paths. Mirrors the diff
      scope: build output, nested checkouts and migrations are not mutated.
    #>
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $projectDir = Split-Path $ProjectPath -Parent
    return @(
        Get-ChildItem -LiteralPath $projectDir -Recurse -File -Filter '*.cs' |
            Where-Object { $_.FullName -notmatch '[\\/](bin|obj)[\\/]' } |
            Where-Object { -not (Test-HarnessExcludedPath -Path $_.FullName -RepoRoot $RepoRoot) } |
            Where-Object { $_.FullName -notmatch 'Persistence[\\/]Migrations[\\/]' } |
            ForEach-Object { [System.IO.Path]::GetRelativePath($RepoRoot, $_.FullName).Replace('\', '/') } |
            Sort-Object
    )
}

function Select-WholeProjectTargets {
    <#
      Every .csproj the repo has, minus the test projects, filtered to the ones
      -Project names or to the single eligible and non-excluded candidate.
      Emits GATE NOT WIRED lines and exits 1 rather than return an empty choice.
    #>
    param(
        [string[]]$Requested,
        [string]$ConfiguredTarget,
        [string]$RepoRoot,
        [string[]]$TestProjects,
        [Parameter(Mandatory)][System.Collections.Generic.Dictionary[string, string]]$ExclusionReasons
    )

    $production = @(
        Get-ChildItem -LiteralPath $RepoRoot -Recurse -File -Filter '*.csproj' -ErrorAction SilentlyContinue |
            Where-Object { -not (Test-HarnessExcludedPath -Path $_.FullName -RepoRoot $RepoRoot) } |
            ForEach-Object { $_.FullName } |
            Where-Object { $TestProjects -notcontains $_ } |
            Sort-Object
    )

    # -Project wins over the configured target: the command line is the narrower,
    # more explicit statement of intent.
    $named = @($Requested | ForEach-Object { $_ -split ',' } | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() -replace '\.csproj$', '' })
    if ($named.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($ConfiguredTarget)) {
        $named = @($ConfiguredTarget.Trim() -replace '\.csproj$', '')
    }

    if ($named.Count -gt 0) {
        $selected = [System.Collections.Generic.List[string]]::new()
        foreach ($name in $named) {
            $match = @($production | Where-Object { [System.IO.Path]::GetFileNameWithoutExtension($_) -eq $name })
            if ($match.Count -eq 0) {
                Write-Host "Mutation testing: FAILED - -Project '$name' is not a production project in this repo."
                Write-Host "  Production projects: $((@($production | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_) })) -join ', ')"
                exit 1
            }
            if ($ExclusionReasons.ContainsKey($name)) {
                Write-Host "Mutation testing: FAILED - -WholeProject names '$name', which gates.mutation.exclusions lists as never mutated: $($ExclusionReasons[$name])"
                exit 1
            }
            $selected.Add($match[0])
        }
        return $selected.ToArray()
    }

    $candidates = @(
        $production | Where-Object {
            $name = [System.IO.Path]::GetFileNameWithoutExtension($_)
            if ($ExclusionReasons.ContainsKey($name)) { return $false }
            @(Get-EligibleTestProjects -TestProjects $TestProjects -MutatedProjectPath $_).Count -gt 0
        }
    )

    if ($candidates.Count -eq 1) { return $candidates }
    if ($candidates.Count -eq 0) {        Write-Host 'GATE NOT WIRED: -WholeProject found no production project with an eligible test project that gates.mutation.exclusions does not list.'
        Write-Host '  A test project must reference the mutated project directly, and *.ArchitectureTests and *.IntegrationTests never count.'
        exit 1
    }

    $names = (@($candidates | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_) } | Sort-Object) -join ', ')
    Write-Host "GATE NOT WIRED: -WholeProject has more than one candidate ($names); name the one to mutate with -Project, or set gates.mutation.wholeProject in harness.yml."
    exit 1
}

if ($WholeProject) {
    $allTestProjects = @(Get-TestProjects -RepoRoot $repoRoot)
    $configuredWholeProject = Get-HarnessValue -Key 'gates.mutation.wholeProject' -RepoRoot $repoRoot
    $targets = @(Select-WholeProjectTargets -Requested $Project -ConfiguredTarget $configuredWholeProject -RepoRoot $repoRoot -TestProjects $allTestProjects -ExclusionReasons $exclusionReasons)

    foreach ($targetPath in $targets) {
        $projName = [System.IO.Path]::GetFileName($targetPath)
        $files = @(Get-ProjectSourceFiles -ProjectPath $targetPath -RepoRoot $repoRoot)
        if ($files.Count -eq 0) {
            Write-Host "GATE NOT WIRED: whole-project target '$targetPath' contains no C# files."
            exit 1
        }
        $projectDirs[$projName] = Split-Path $targetPath -Parent
        $projectPaths[$projName] = $targetPath
        $groupFiles = [System.Collections.Generic.List[string]]::new()
        $groupFiles.AddRange([string[]]$files)
        $projectGroups[$projName] = $groupFiles
        $changedFiles += $files
        Write-Host "Whole-project mode: $projName ($($files.Count) source file(s)); diff scope not consulted, since disabled."
    }
}
else {
    # Resolve base ref and merge-base
    $baseBranch = Get-HarnessValue -Key 'baseBranch' -RepoRoot $repoRoot
    if ([string]::IsNullOrWhiteSpace($baseBranch)) {
        $baseBranch = 'main'
    }

    $targetRef = if (-not [string]::IsNullOrWhiteSpace($BaseRef)) {
        $BaseRef
    }
    else {
        "origin/$baseBranch"
    }

    $mergeBase = git -C $repoRoot merge-base HEAD $targetRef 2>$null

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($mergeBase)) {
        Write-Host "Mutation testing: FAILED - could not resolve git merge-base between HEAD and '$targetRef'."
        if ([string]::IsNullOrWhiteSpace($BaseRef)) {
            Write-Host "  Fetch the remote branch with 'git fetch origin' or pass -BaseRef explicitly."
        }
        exit 1
    }

    $mergeBase = $mergeBase.Trim()

    # Every changed C# file the diff touched, wherever the repo keeps its code.
    # Which of them are production is decided by the project each one belongs to
    # below, not by a path prefix, so a repo that keeps code under source/ or
    # beside the solution root needs no configuration for this.
    $changedFiles = @(
        git -C $repoRoot diff --name-only --diff-filter=AMR $mergeBase HEAD -- '*.cs' |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Trim().Replace('\', '/') } |
            Where-Object { $_ -notmatch 'Persistence[\\/]Migrations[\\/]' } |
            Where-Object { -not (Test-HarnessExcludedPath -Path (Join-Path $repoRoot $_) -RepoRoot $repoRoot) } |
            Select-Object -Unique
    )

    if ($changedFiles.Count -eq 0) {
        Write-Host 'Mutation testing: SKIPPED - no production C# files changed (scope-empty).'
        exit 2
    }

    $allTestProjects = @(Get-TestProjects -RepoRoot $repoRoot)
}

# Group production files by nearest ancestor *.csproj. A changed file that belongs
# to a test project is not production scope: mutating tests measures nothing and a
# test-only change must read as scope-empty, not as a failing gate.
$unprojectedFiles = [System.Collections.Generic.List[string]]::new()

foreach ($file in $changedFiles) {
    if ($WholeProject) { break }

    $fullPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $file))
    $dir = Split-Path $fullPath -Parent
    $foundCsproj = $null

    while ($dir.Length -ge $repoRoot.Length) {
        $csProjs = @(Get-ChildItem -LiteralPath $dir -Filter '*.csproj' -File)
        if ($csProjs.Count -eq 1) {
            $foundCsproj = $csProjs[0]
            break
        }
        elseif ($csProjs.Count -gt 1) {
            throw "Multiple .csproj files found in $dir"
        }
        $parentDir = Split-Path $dir -Parent
        if ($parentDir -eq $dir) { break }
        $dir = $parentDir
    }

    if (-not $foundCsproj) {
        # No project, no mutants possible. Skip it loudly rather than fail a gate
        # over a loose .cs file that Stryker could never have measured.
        $unprojectedFiles.Add($file)
        continue
    }

    if ($allTestProjects -contains $foundCsproj.FullName) { continue }

    $projName = $foundCsproj.Name
    $projDir = $foundCsproj.DirectoryName
    $projectDirs[$projName] = $projDir
    $projectPaths[$projName] = $foundCsproj.FullName

    $relToProj = [System.IO.Path]::GetRelativePath($projDir, $fullPath).Replace('\', '/')
    if (-not $projectGroups.Contains($projName)) {
        $projectGroups[$projName] = [System.Collections.Generic.List[string]]::new()
    }
    $projectGroups[$projName].Add($relToProj)
}

if ($unprojectedFiles.Count -gt 0) {
    Write-Host "Not in any project, so no mutants are possible (skipped): $($unprojectedFiles -join ', ')"
}

if ($projectGroups.Count -eq 0) {
    Write-Host 'Mutation testing: SKIPPED - no production C# files changed (scope-empty).'
    exit 2
}

# Read tracked stryker-config.json
$strykerConfigPath = Join-Path $repoRoot 'stryker-config.json'
if (-not (Test-Path -LiteralPath $strykerConfigPath)) {
    Write-Host "GATE NOT WIRED: stryker-config.json is missing at '$strykerConfigPath'."
    exit 1
}

$baseConfigJson = Get-Content -LiteralPath $strykerConfigPath -Raw | ConvertFrom-Json
$baseStryker = $baseConfigJson.'stryker-config'

# stryker-config.json names the runner, and this gate never guesses it: a repo on
# xUnit v3 must say mtp. Under VSTest (or with coverage analysis on where the MTP
# runner cannot use it) no mutant reaches the xUnit v3 test executables and every
# mutant survives, which reads as a score of zero rather than as a wiring defect.
$declaredRunner = if ($baseStryker.PSObject.Properties.Match('test-runner').Count -gt 0) { ([string]$baseStryker.'test-runner').Trim() } else { '' }
if ([string]::IsNullOrWhiteSpace($declaredRunner)) {
    Write-Host "GATE NOT WIRED: stryker-config.json does not set 'test-runner' (vstest or mtp; mtp is required by xUnit v3 test projects). Set gates.mutation.runner in harness.yml and re-run install.ps1, or edit the file directly."
    exit 1
}
if ($declaredRunner -notin @('vstest', 'mtp')) {
    Write-Host "GATE NOT WIRED: stryker-config.json sets 'test-runner' to '$declaredRunner'; this gate knows vstest and mtp."
    exit 1
}
if ($declaredRunner -eq 'mtp') {
    $coverageAnalysis = if ($baseStryker.PSObject.Properties.Match('coverage-analysis').Count -gt 0) { ([string]$baseStryker.'coverage-analysis').Trim() } else { '' }
    if ($coverageAnalysis -ne 'off') {
        Write-Host "GATE NOT WIRED: stryker-config.json sets test-runner=mtp but coverage-analysis is '$coverageAnalysis'; the MTP runner requires 'off'."
        exit 1
    }
}

# A timeout counts as detected, so with a tight allowance a slow or busy machine turns
# survivors into timeouts and inflates the score. No ordinary mutant really hangs, so a
# large allowance costs nothing on a normal run. Require at least 30 s on top of the
# measured test time.
$minAdditionalTimeout = 30000
$additionalTimeoutValue = if ($baseStryker.PSObject.Properties.Match('additional-timeout').Count -gt 0) { $baseStryker.'additional-timeout' } else { $null }
if ($additionalTimeoutValue -isnot [long] -and $additionalTimeoutValue -isnot [int]) {
    Write-Host "GATE NOT WIRED: stryker-config.json does not set 'additional-timeout' to an integer (expected at least $minAdditionalTimeout ms)."
    exit 1
}
if ([long]$additionalTimeoutValue -lt $minAdditionalTimeout) {
    Write-Host "GATE NOT WIRED: stryker-config.json sets 'additional-timeout' to $additionalTimeoutValue (expected at least $minAdditionalTimeout ms)."
    exit 1
}

$sortedProjects = @($projectGroups.Keys | Sort-Object)

if ($Project.Count -gt 0) {
    $requested = @($Project | ForEach-Object { $_ -split ',' } | Where-Object { $_.Trim() } |
        ForEach-Object { $n = $_.Trim(); if ($n -notmatch '\.csproj$') { "$n.csproj" } else { $n } })
    $unknown = @($requested | Where-Object { $sortedProjects -notcontains $_ })
    if ($unknown.Count -gt 0) {
        Write-Host "Mutation testing: FAILED - -Project names with no changed production files: $($unknown -join ', ')."
        Write-Host "  Changed projects: $($sortedProjects -join ', ')"
        exit 1
    }
    $sortedProjects = @($sortedProjects | Where-Object { $requested -contains $_ })
}

# Classify every changed project before any Stryker run, so a project that is unmeasured
# never stops a project that can be measured. Eligibility is computed for all of them so
# the lines below say which policy applies before the verdict names what it failed on.
if ($null -eq $allTestProjects) { $allTestProjects = @(Get-TestProjects -RepoRoot $repoRoot) }
$testProjectsByProject = @{}
$eligibleProjects = [System.Collections.Generic.List[string]]::new()
$unlistedIneligibleProjects = [System.Collections.Generic.List[string]]::new()
$classifications = [ordered]@{}

foreach ($proj in $sortedProjects) {
    $eligible = @(Get-EligibleTestProjects -TestProjects $allTestProjects -MutatedProjectPath $projectPaths[$proj])
    $projShortName = $proj -replace '\.csproj$', ''
    $lines = [System.Collections.Generic.List[string]]::new()

    if ($exclusionReasons.ContainsKey($projShortName)) {
        $lines.Add("Classification for ${proj}: NOT APPLICABLE - listed in gates.mutation.exclusions: $($exclusionReasons[$projShortName])")
        if ($eligible.Count -gt 0) {
            $staleShown = ($eligible | ForEach-Object { [System.IO.Path]::GetRelativePath($repoRoot, $_).Replace('\', '/') }) -join ', '
            $lines.Add("Classification for ${proj}: WARNING - the exclusion may be stale: eligible test project(s) exist ($staleShown), and the project stays excluded.")
        }
    }
    elseif ($eligible.Count -gt 0) {
        $shown = ($eligible | ForEach-Object { [System.IO.Path]::GetRelativePath($repoRoot, $_).Replace('\', '/') }) -join ', '
        $lines.Add("Test projects for ${proj}: $shown")
        $testProjectsByProject[$proj] = $eligible
        $eligibleProjects.Add($proj)
    }
    else {
        $lines.Add("Classification for ${proj}: no eligible test project, not in policy")
        $unlistedIneligibleProjects.Add($proj)
    }

    $classifications[$proj] = $lines
}

# Every changed project is now either listed, measurable, or reported; the flag only says
# which of those three left nothing at all to measure. A configured exclusion that matches
# no changed project never reaches this point, because it is only ever looked up above.
$everyChangedProjectListed = $eligibleProjects.Count -eq 0 -and $unlistedIneligibleProjects.Count -eq 0

# A DryRun prints these classifications inside its own report below, so a real run, and the
# all-listed return that happens before that report exists, are what print them here.
if (-not $DryRun -or $everyChangedProjectListed) {
    foreach ($proj in $sortedProjects) {
        foreach ($line in $classifications[$proj]) {
            Write-Host $line
        }
    }
}

# Every changed project listed leaves nothing to measure, so no config is written, no
# output directory is created, and no Stryker is started.
if ($everyChangedProjectListed) {
    Write-Host "`nMutation testing: NOT APPLICABLE - every changed project is listed in gates.mutation.exclusions; nothing was mutated."
    exit 2
}

# Output root lives outside the repo so StrykerOutput never lands in the working tree.
$outputRootPath = if (-not [string]::IsNullOrWhiteSpace($OutputRoot)) {
    [System.IO.Path]::GetFullPath($OutputRoot)
}
elseif ($WholeProject) {
    # Deterministic location so CI and local runs write to one stable path under
    # <output root>/<Project>/ instead of a timestamped folder.
    Join-Path ([System.IO.Path]::GetTempPath()) 'stryker-whole'
}
else {
    # The GUID suffix keeps two runs started in the same second out of one folder.
    Join-Path ([System.IO.Path]::GetTempPath()) ("stryker/" + [System.DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
}
$outputRootPath = [System.IO.Path]::GetFullPath($outputRootPath)
$repoRootWithSep = $repoRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
if ($outputRootPath.Equals($repoRoot.TrimEnd('\', '/'), [System.StringComparison]::OrdinalIgnoreCase) -or
    $outputRootPath.StartsWith($repoRootWithSep, [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Host "Mutation testing: FAILED - -OutputRoot '$outputRootPath' is inside the repository; use a directory outside '$repoRoot'."
    exit 1
}
Write-Host "Output root: $outputRootPath"

# Write one temp config per project into the system temp directory
$tempConfigs = [ordered]@{}
$tempFilesToClean = [System.Collections.Generic.List[string]]::new()

try {
    foreach ($proj in $eligibleProjects) {
        $projShortName = $proj -replace '\.csproj$', ''
        $tempConfigPath = Join-Path ([System.IO.Path]::GetTempPath()) "stryker-$projShortName-$([System.Guid]::NewGuid().ToString('N').Substring(0, 8)).json"
        $tempFilesToClean.Add($tempConfigPath)

        $high = if ($baseStryker.thresholds.high -ne $null) { [int]$baseStryker.thresholds.high } else { 90 }
        $low = if ($baseStryker.thresholds.low -ne $null) { [int]$baseStryker.thresholds.low } else { [int]$threshold }

        # The tracked config is the project's own file, so the generated one is a
        # copy of it with only the keys this gate owns replaced. Rebuilding from a
        # fixed key list instead would silently drop whatever the project set -
        # ignore-methods and a solution path above all - and change the score
        # without changing the code.
        $generated = [ordered]@{}
        foreach ($property in $baseStryker.PSObject.Properties) {
            $generated[$property.Name] = $property.Value
        }
        $generated['test-runner'] = $declaredRunner
        $generated['additional-timeout'] = [long]$additionalTimeoutValue
        $generated['concurrency'] = $concurrency
        $generated['test-projects'] = @($testProjectsByProject[$proj])
        # Since stays disabled: the diff scope is applied through `mutate` instead,
        # because Stryker's since filter resolves linked worktrees to the main
        # checkout and then measures nothing.
        $generated['since'] = [ordered]@{ 'enabled' = $false }
        $generated['mutate'] = @($projectGroups[$proj])
        $generated['thresholds'] = [ordered]@{
            'high'  = $high
            'low'   = $low
            'break' = [int]$threshold
        }

        $strykerObj = [ordered]@{ 'stryker-config' = $generated }

        $configJson = $strykerObj | ConvertTo-Json -Depth 6
        [System.IO.File]::WriteAllText($tempConfigPath, $configJson, [System.Text.UTF8Encoding]::new($false))

        $hash = (Get-FileHash -LiteralPath $tempConfigPath -Algorithm SHA256).Hash
        Write-Host "Stryker config for ${proj}: $tempConfigPath"
        Write-Host "  SHA256: $hash"

        $tempConfigs[$proj] = @{
            Path = $tempConfigPath
            Hash = $hash
            Json = $configJson
        }
    }

    if ($DryRun) {
        Write-Host "`nMutation testing: DRY RUN - project groups:"
        foreach ($proj in $sortedProjects) {
            foreach ($line in $classifications[$proj]) {
                Write-Host "`n  $line"
            }
            if (-not $testProjectsByProject.ContainsKey($proj)) { continue }

            $filesList = @($projectGroups[$proj])
            Write-Host "`n  Project: $proj ($($filesList.Count) file(s))"
            foreach ($f in $filesList) {
                Write-Host "    - $f"
            }
            Write-Host "`n  Generated config ($($tempConfigs[$proj].Path)):"
            Write-Host $tempConfigs[$proj].Json
        }

        # A classification run measures no mutant, so exit 0 below is a classification
        # verdict and never mutation proof. An unlisted project with no eligible test
        # project is the one classification failure, and it fails here exactly as the
        # same project fails a real run, after the eligible ones have been reported.
        if ($unlistedIneligibleProjects.Count -gt 0) {
            Write-Host "`nMutation testing: FAILED - changed project(s) with no eligible test project (a test project that directly references it, excluding *.ArchitectureTests and *.IntegrationTests) that are not in gates.mutation.exclusions: $($unlistedIneligibleProjects -join ', ')."
            exit 1
        }

        Write-Host "`nMutation testing: Dry run complete (0 tests executed)."
        exit 0
    }

    # Run Stryker sequentially per eligible project, from the project directory, into <output root>/<project>
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    $durationsSeconds = [ordered]@{}

    foreach ($proj in $eligibleProjects) {
        Write-Host "`n================================================================================"
        Write-Host "Running Stryker for $proj..."
        Write-Host "================================================================================"

        $cfgPath = $tempConfigs[$proj].Path
        $projOut = Join-Path $outputRootPath ($proj -replace '\.csproj$', '')
        New-Item -ItemType Directory -Path $projOut -Force | Out-Null
        Copy-Item -LiteralPath $cfgPath -Destination (Join-Path $projOut 'stryker-config.json') -Force

        $projStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        Push-Location $projectDirs[$proj]
        try {
            & dotnet stryker -f $cfgPath -p $proj -O $projOut
            $nativeExit = $LASTEXITCODE
        }
        finally {
            Pop-Location
        }
        $projStopwatch.Stop()
        $durationsSeconds[$proj] = [math]::Round($projStopwatch.Elapsed.TotalSeconds, 1)
        Write-Host "Stryker native exit for ${proj}: $nativeExit ($($durationsSeconds[$proj])s wall time)"

        $candidateReport = Join-Path $projOut 'reports/mutation-report.json'
        $reportPath = if (Test-Path -LiteralPath $candidateReport) { (Resolve-Path -LiteralPath $candidateReport).Path } else { $null }

        $projEval = Evaluate-MutationReport `
            -ReportPath $reportPath `
            -NativeExitCode $nativeExit `
            -ProjectName $proj `
            -ChangedFiles $changedFiles `
            -Threshold $threshold `
            -RepoRoot $repoRoot `
            -MaxKillShare $maxKillShare `
            -MaxKillFileSpan $maxKillFileSpan

        $results.Add($projEval)
    }

    # Summary and evaluation
    Write-Host "`n================================================================================"
    Write-Host 'Mutation Testing Summary'
    Write-Host '================================================================================'

    $allSurvivingMutants = [System.Collections.Generic.List[PSCustomObject]]::new()
    $runFailureReasons = [System.Collections.Generic.List[string]]::new()
    $totalTestedOverall = 0

    foreach ($r in $results) {
        $totalTestedOverall += $r.Tested
        foreach ($sm in $r.SurvivingMutants) {
            $allSurvivingMutants.Add($sm)
        }

        Write-Host "`nProject: $($r.ProjectName)"
        Write-Host "  Report: $($r.ReportPath)"
        Write-Host ("  Mutants: {0} | Killed: {1} | Survived: {2} | Timeout: {3} | NoCoverage: {4} | Ignored: {5} | CompileError: {6}" -f `
            $r.TotalMutants, $r.Killed, $r.Survived, $r.Timeout, $r.NoCoverage, $r.Ignored, $r.CompileError)
        $scoreText = if ($r.Score -ne $null) { ("{0:N2}%" -f $r.Score) } else { 'N/A (0 tested)' }
        $statusText = if ($r.Passed) { 'PASS' } else { 'FAIL' }
        Write-Host ("  Tested:  {0} | Score: {1} (Threshold: {2}%, {3} timeout) -> {4}" -f $r.Tested, $scoreText, $threshold, $r.Timeout, $statusText)
        Write-Host "  Kill share: $($r.KillShareNote)"
        Write-Host "  Kill file span: $($r.KillFileSpanNote)"

        if (-not $r.Passed) {
            foreach ($fr in $r.FailureReasons) {
                $runFailureReasons.Add("$($r.ProjectName): $fr")
            }
        }
    }

    if ($allSurvivingMutants.Count -gt 0) {
        Write-Host "`nSurviving mutants ($($allSurvivingMutants.Count)):"
        foreach ($sm in $allSurvivingMutants) {
            Write-Host "  $($sm.File):$($sm.Line) [$($sm.Mutator)]"
        }
    }

    if ($unlistedIneligibleProjects.Count -gt 0) {
        $runFailureReasons.Add("Changed project(s) with no eligible test project (a test project that directly references it, excluding *.ArchitectureTests and *.IntegrationTests) that are not in gates.mutation.exclusions: $($unlistedIneligibleProjects -join ', ').")
    }

    if ($totalTestedOverall -eq 0) {
        $runFailureReasons.Add('Total number of tested mutants across all invocations is 0.')
    }

    Write-Host "`nOutput root: $outputRootPath"

    $gateEndUtc = [DateTime]::UtcNow
    $timingProjects = @($results | ForEach-Object {
            [ordered]@{
                project         = $_.ProjectName
                durationSeconds = $durationsSeconds[$_.ProjectName]
                totalMutants    = $_.TotalMutants
                tested          = $_.Tested
                score           = $_.Score
                passed          = $_.Passed
            }
        })
    $timing = [ordered]@{
        generatedUtc    = $gateEndUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
        durationSeconds = [math]::Round(($gateEndUtc - $gateStartUtc).TotalSeconds, 1)
        concurrency     = $concurrency
        threshold       = $threshold
        projects        = $timingProjects
    }
    $timingPath = Join-Path $outputRootPath 'mutation-timing.json'
    [System.IO.File]::WriteAllText($timingPath, ($timing | ConvertTo-Json -Depth 6) + "`n", [System.Text.UTF8Encoding]::new($false))
    Write-Host "Mutation timing: $($timing.durationSeconds)s wall time, $($totalTestedOverall) tested mutant(s), concurrency $concurrency (details: $timingPath)"

    Write-Host "`n--------------------------------------------------------------------------------"
    if ($runFailureReasons.Count -eq 0) {
        Write-Host "Mutation testing: PASSED (all projects scored at or above threshold $threshold%, total tested: $totalTestedOverall)."
        exit 0
    }
    else {
        Write-Host 'Mutation testing: FAILED'
        foreach ($fr in $runFailureReasons) {
            Write-Host "  - $fr"
        }
        exit 1
    }
}
finally {
    # Temp configs may be deleted at the end, but only after the report has been located
    foreach ($tmp in $tempFilesToClean) {
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}
