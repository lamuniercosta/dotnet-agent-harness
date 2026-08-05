#!/usr/bin/env pwsh
# Shared helpers for the static-analysis gate scripts.
# Dot-source from a gate script:  . (Join-Path $PSScriptRoot '_gate-common.ps1')
#
# Provides repo/solution/base-ref discovery (so the gates are portable across
# repos) and "is this gate actually wired?" assertions (so a gate can never
# report PASS when its analyzer is not enabled).

Set-StrictMode -Version Latest

# MSBuild/Roslyn diagnostics are localized to the machine's UI language, and the
# gate parsers match English text ("warning", "error", the CA1502 message body).
# On a non-English machine they would match nothing and every gate would report
# a silent pass. Force English so parsing is deterministic everywhere.
$env:DOTNET_CLI_UI_LANGUAGE = 'en'

# harness.yml reader: Get-HarnessConfig / Get-HarnessValue. Kept in its own file
# because it is the one piece of this pack that is not about running a gate.
. (Join-Path $PSScriptRoot '_harness-config.ps1')

function Get-RepoRoot {
    <#
      Where the gates look for CodeMetricsConfig.txt, .config/dotnet-tools.json,
      .editorconfig, and harness.yml.

      Resolution order:
        1. $env:HARNESS_REPO_ROOT - an explicit override.
        2. The git toplevel.
        3. The parent of scripts/, so the gates still work outside git
           (-All and -Files need no change detection).

      The override exists because rule 2 walks UP. When the project being gated
      is nested inside a larger repository - a monorepo package, or this
      harness's own fixtures/BadCode - git reports the OUTER root, and every
      gate then looks for its config in a directory that does not have it. The
      gates correctly refuse to run at that point ("GATE NOT WIRED"), which is
      the right behaviour and a confusing one to debug. Setting
      HARNESS_REPO_ROOT pins them to the project you actually mean.
    #>
    if ($env:HARNESS_REPO_ROOT) {
        return (Resolve-Path -LiteralPath $env:HARNESS_REPO_ROOT).Path
    }

    $root = git -C $PSScriptRoot rev-parse --show-toplevel 2>$null
    if ($root) {
        return $root.Trim()
    }

    return (Split-Path $PSScriptRoot -Parent)
}

function Test-IsGitRepo {
    param([string]$RepoRoot)

    git -C $RepoRoot rev-parse --show-toplevel *> $null
    return ($LASTEXITCODE -eq 0)
}

function Resolve-AnalysisScope {
    <#
      Decides whether a gate should analyse the whole solution.
      Without git there is no "changed since" to compute, so rather than
      checking nothing we widen to the full solution and say so.
      Returns $true when the caller should treat the run as -All.
    #>
    param(
        [string]$RepoRoot,
        [bool]$All,
        [string[]]$Files
    )

    if ($All) { return $true }
    if ($Files.Count -gt 0) { return $false }

    if (-not (Test-IsGitRepo -RepoRoot $RepoRoot)) {
        Write-Warning 'Not a git repository - cannot detect changed files. Analysing the full solution instead.'
        return $true
    }

    return $false
}

function Resolve-BuildTarget {
    <#
      Finds the thing to hand to `dotnet build` / `jb inspectcode`.
      Order: explicit -Solution, then *.slnx/*.sln at repo root, then src/,
      then anywhere at depth <= 3, then a lone *.csproj.
      Throws with an actionable message when ambiguous or absent.
    #>
    param(
        [string]$RepoRoot,
        [string]$Explicit
    )

    if ($Explicit) {
        $path = if ([System.IO.Path]::IsPathRooted($Explicit)) { $Explicit } else { Join-Path $RepoRoot $Explicit }
        if (-not (Test-Path $path)) {
            throw "Solution not found: $Explicit"
        }
        return (Resolve-Path $path).Path
    }

    $found = @()
    foreach ($depth in 1, 2, 3) {
        $found = @(
            Get-ChildItem -Path $RepoRoot -Include '*.slnx', '*.sln' -File -Depth ($depth - 1) -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch '[\\/](bin|obj|node_modules|artifacts)[\\/]' }
        )
        if ($found.Count -gt 0) { break }
    }

    if ($found.Count -eq 1) {
        return $found[0].FullName
    }

    if ($found.Count -gt 1) {
        $list = ($found | ForEach-Object { '  ' + [System.IO.Path]::GetRelativePath($RepoRoot, $_.FullName) }) -join "`n"
        throw "Multiple solutions found; pass -Solution <path> to pick one:`n$list"
    }

    # No solution - fall back to a single project.
    $projects = @(
        Get-ChildItem -Path $RepoRoot -Include '*.csproj' -File -Depth 2 -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/](bin|obj|node_modules|artifacts)[\\/]' }
    )

    if ($projects.Count -eq 1) {
        return $projects[0].FullName
    }

    if ($projects.Count -gt 1) {
        throw "No solution file found and $($projects.Count) projects present. Pass -Solution <path/to.sln|csproj>."
    }

    throw 'No .sln, .slnx, or .csproj found in this repository.'
}

function Get-TestRunOutcome {
    <#
      Classifies a `dotnet test` run from its output, so a gate can tell "nothing
      to verify" from "verified something".

        Ran            - at least one test executed; judge it on the exit code
        NothingMatched - zero executed, and the runner said the filter matched nothing
        Unknown        - zero executed and no explanation; the gate cannot conclude

      Counting executed tests, rather than trusting the "no test matches" line, is
      what makes this correct on a solution with more than one test assembly. With
      two test projects, the one without matching tests prints that line while the
      other runs its tests normally - and matching the line alone reported SKIPPED
      while property tests had demonstrably passed. Two or more test assemblies is
      the ordinary shape of a .NET solution, so that read the gate as permanently
      skipped for most consumers.

      A run that matched nothing prints no summary line at all, which is why zero
      executed is not by itself enough to conclude either way.
    #>
    param([string[]]$Output)

    $executed = 0
    foreach ($line in $Output) {
        foreach ($m in [regex]::Matches($line, 'Total:\s*(\d+)')) {
            $executed += [int]$m.Groups[1].Value
        }
    }

    if ($executed -gt 0) {
        return [PSCustomObject]@{ Outcome = 'Ran'; Executed = $executed }
    }

    if (@($Output | Where-Object { $_ -match 'No test matches the given testcase filter' }).Count -gt 0) {
        return [PSCustomObject]@{ Outcome = 'NothingMatched'; Executed = 0 }
    }

    return [PSCustomObject]@{ Outcome = 'Unknown'; Executed = 0 }
}

function Resolve-TestProject {
    <#
      Finds a test project by name pattern (e.g. '*AcceptanceTests*').
      Returns $null when none match, so the caller decides whether that is a
      graceful skip or a failure.
    #>
    param(
        [string]$RepoRoot,
        [string]$Explicit,
        [string[]]$NamePatterns
    )

    if ($Explicit) {
        $path = if ([System.IO.Path]::IsPathRooted($Explicit)) { $Explicit } else { Join-Path $RepoRoot $Explicit }
        if (-not (Test-Path $path)) {
            throw "Test project not found: $Explicit"
        }
        return (Resolve-Path $path).Path
    }

    $candidates = @(
        Get-ChildItem -Path $RepoRoot -Include '*.csproj' -File -Depth 3 -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/](bin|obj|node_modules)[\\/]' } |
            Where-Object {
                $name = $_.BaseName
                foreach ($pattern in $NamePatterns) {
                    if ($name -like $pattern) { return $true }
                }
                return $false
            }
    )

    if ($candidates.Count -eq 0) {
        return $null
    }

    if ($candidates.Count -gt 1) {
        $list = ($candidates | ForEach-Object { '  ' + [System.IO.Path]::GetRelativePath($RepoRoot, $_.FullName) }) -join "`n"
        throw "Multiple matching test projects; pass -Project <path> to pick one:`n$list"
    }

    return $candidates[0].FullName
}

function Resolve-BaseRef {
    <#
      Picks the ref to diff against when the caller did not supply one.
      Prefers the remote's default branch, then common local branch names.
    #>
    param(
        [string]$RepoRoot,
        [string]$Explicit
    )

    if ($Explicit) {
        return $Explicit
    }

    $head = git -C $RepoRoot symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>$null
    if ($head) {
        return $head.Trim()
    }

    foreach ($candidate in 'main', 'master', 'development', 'develop') {
        git -C $RepoRoot rev-parse --verify --quiet $candidate *> $null
        if ($LASTEXITCODE -eq 0) {
            return $candidate
        }
    }

    return 'HEAD'
}

function Get-ChangedCsFiles {
    param(
        [string]$RepoRoot,
        [string]$Ref
    )

    $mergeBase = git -C $RepoRoot merge-base HEAD $Ref 2>$null
    if (-not $mergeBase) {
        $mergeBase = git -C $RepoRoot merge-base HEAD "origin/$Ref" 2>$null
    }

    if (-not $mergeBase) {
        Write-Warning "Could not resolve merge base with '$Ref'. Checking staged and unstaged .cs changes only."
        $diffArgs = @('--name-only', '--diff-filter=ACMRT', 'HEAD')
    }
    else {
        $diffArgs = @('--name-only', '--diff-filter=ACMRT', $mergeBase.Trim())
    }

    git -C $RepoRoot diff @diffArgs |
        Where-Object { $_ -match '\.cs$' } |
        ForEach-Object { $_.Replace('\', '/') } |
        Select-Object -Unique
}

function Get-TargetCsFiles {
    <#
      Resolves the file set a gate should act on: explicit -Files, or the
      changed-since-base-ref set plus untracked .cs files.
    #>
    param(
        [string]$RepoRoot,
        [string]$BaseRef,
        [string[]]$Files
    )

    if ($Files.Count -gt 0) {
        return @($Files | ForEach-Object { $_.Replace('\', '/') })
    }

    $changed = @(Get-ChangedCsFiles -RepoRoot $RepoRoot -Ref $BaseRef)
    $untracked = @(
        git -C $RepoRoot ls-files --others --exclude-standard |
            Where-Object { $_ -match '\.cs$' } |
            ForEach-Object { $_.Replace('\', '/') }
    )

    return @($changed + $untracked | Select-Object -Unique)
}

function Test-TargetsFile {
    param(
        [string]$IssuePath,
        [string[]]$TargetFiles,
        [string]$RepoRoot
    )

    $normalizedIssue = $IssuePath.Replace('\', '/')
    $relativeIssue = if ([System.IO.Path]::IsPathRooted($normalizedIssue)) {
        [System.IO.Path]::GetRelativePath($RepoRoot, $normalizedIssue).Replace('\', '/')
    }
    else {
        $normalizedIssue
    }

    foreach ($target in $TargetFiles) {
        $normalizedTarget = $target.Replace('\', '/')
        if ($relativeIssue -eq $normalizedTarget -or $relativeIssue.EndsWith($normalizedTarget)) {
            return $true
        }
    }

    return $false
}

function Get-EditorConfigFiles {
    param([string]$RepoRoot)

    return @(
        # -Force is required, not cosmetic. On Linux and macOS PowerShell treats
        # a dot-prefixed file as hidden, and Get-ChildItem omits hidden files
        # unless -Force is passed - so .editorconfig was invisible on every
        # non-Windows machine. The gates then reported GATE NOT WIRED and
        # refused to run, which is the correct failure for a missing config but
        # the wrong answer for a config that is right there.
        Get-ChildItem -Path $RepoRoot -Include '.editorconfig' -File -Force -Depth 3 -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/](bin|obj|node_modules)[\\/]' }
    )
}

function Get-BuildConfigFiles {
    param([string]$RepoRoot)

    return @(
        Get-ChildItem -Path $RepoRoot -Include 'Directory.Build.props', 'Directory.Packages.props', '*.csproj' -File -Depth 3 -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/](bin|obj|node_modules)[\\/]' }
    )
}

function Assert-GateWired {
    <#
      Refuses to let a gate report PASS when the analysis it claims to perform
      is not actually enabled. A silent vacuous pass is worse than no gate at
      all, so every failure here exits 1 with remediation.

      -Gate: 'roslyn' | 'cyclomatic' | 'inspectcode'
    #>
    param(
        [string]$RepoRoot,
        [ValidateSet('roslyn', 'cyclomatic', 'inspectcode')]
        [string]$Gate
    )

    $templateHint = 'Templates: scripts/templates/ in the dotnet-skills pack (Directory.Build.props, .editorconfig, CodeMetricsConfig.txt, dotnet-tools.json).'

    # Wrap in @() at the call site: PowerShell collapses an empty array returned
    # from a function to $null, and .Count on $null throws under StrictMode.
    $editorConfigs = @(Get-EditorConfigFiles -RepoRoot $RepoRoot)
    $editorConfigText = if ($editorConfigs.Count -gt 0) { ($editorConfigs | Get-Content -Raw) -join "`n" } else { '' }

    switch ($Gate) {
        'cyclomatic' {
            if ($editorConfigText -notmatch 'dotnet_diagnostic\.CA1502\.severity\s*=\s*(warning|error)') {
                Write-Host 'GATE NOT WIRED: CA1502 is disabled by default and is not enabled in any .editorconfig.'
                Write-Host '  Without it this gate would build, find nothing, and report a pass it did not earn.'
                Write-Host '  Fix: add  dotnet_diagnostic.CA1502.severity = warning  to .editorconfig.'
                Write-Host "  $templateHint"
                exit 1
            }

            $configPath = Join-Path $RepoRoot 'CodeMetricsConfig.txt'
            if (-not (Test-Path $configPath)) {
                Write-Host 'GATE NOT WIRED: CodeMetricsConfig.txt is missing.'
                Write-Host '  CA1502 would fall back to its built-in threshold of 25, not the configured value.'
                Write-Host "  $templateHint"
                exit 1
            }

            $buildFiles = @(Get-BuildConfigFiles -RepoRoot $RepoRoot)
            $buildText = if ($buildFiles.Count -gt 0) { ($buildFiles | Get-Content -Raw) -join "`n" } else { '' }
            if ($buildText -notmatch 'CodeMetricsConfig\.txt') {
                Write-Host 'GATE NOT WIRED: CodeMetricsConfig.txt exists but is not registered as an AdditionalFiles item.'
                Write-Host '  CA1502 cannot read the threshold, so it falls back to 25.'
                Write-Host '  Fix: add to Directory.Build.props -'
                Write-Host '    <ItemGroup><AdditionalFiles Include="$(MSBuildThisFileDirectory)CodeMetricsConfig.txt" /></ItemGroup>'
                Write-Host "  $templateHint"
                exit 1
            }
        }

        'roslyn' {
            if ($editorConfigText -notmatch 'dotnet_diagnostic\.(CA|IDE)\d+\.severity\s*=\s*(warning|error)') {
                Write-Host 'GATE NOT WIRED: no CA/IDE rule is set to warning or error in any .editorconfig.'
                Write-Host '  Most of the rules this gate looks for are off or informational by default,'
                Write-Host '  so it would report a pass without having checked anything.'
                Write-Host "  $templateHint"
                exit 1
            }
        }

        'inspectcode' {
            $manifest = Join-Path $RepoRoot '.config/dotnet-tools.json'
            if (-not (Test-Path $manifest)) {
                Write-Host 'GATE NOT WIRED: .config/dotnet-tools.json is missing, so `jb` cannot be restored.'
                Write-Host '  Fix: dotnet new tool-manifest && dotnet tool install jetbrains.resharper.globaltools'
                Write-Host "  $templateHint"
                exit 1
            }

            if ((Get-Content $manifest -Raw) -notmatch 'jetbrains\.resharper\.globaltools') {
                Write-Host 'GATE NOT WIRED: jetbrains.resharper.globaltools is not in the tool manifest.'
                Write-Host '  Fix: dotnet tool install jetbrains.resharper.globaltools'
                Write-Host "  $templateHint"
                exit 1
            }

            if ($editorConfigs.Count -eq 0) {
                Write-Warning 'No .editorconfig found - InspectCode will run with default settings rather than repo-tuned ones.'
            }
        }
    }
}
