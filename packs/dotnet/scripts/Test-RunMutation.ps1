#!/usr/bin/env pwsh
# Behaviour fixture for run-mutation.ps1.
#
# run-mutation.ps1 sorts changed projects into eligible, configured-excluded,
# and unlisted-ineligible, and those three share exit codes: two of them can
# return 1 or 2 depending on the diff around them. The exit code alone therefore
# cannot tell a blank reason, a GATE NOT WIRED precondition, and an unlisted
# ineligible project apart, so every case here asserts verdict or classification
# text as well as the exit code.
#
# The fixture is SYNTHESISED, not taken from the repo this runs in: the harness
# has no C# solution of its own outside fixtures/BadCode, and a test that needed
# one would not run here. Each case builds a throwaway git repository holding a
# hand-written Contoso.sln, four production projects, a unit-test project and an
# architecture-test project, overlays the gate files under test (plus the shipped
# dotnet-tools.json and stryker-config.json templates, so a template the gate
# refuses fails here), commits a diff touching exactly the projects that case is
# about, and drives run-mutation.ps1 through HARNESS_REPO_ROOT.
#
# Contoso.Infrastructure deliberately sits at the repository root rather than
# under src/, so the suite proves that diff scope comes from project files and not
# from a path prefix.
#
# The whole-project cases additionally put a stub `dotnet` first on the child's
# PATH. The stub answers `dotnet stryker` by copying a fixture-authored
# mutation-report.json into the -O directory and exits 0 - no real Stryker run
# happens in the fixture - and forwards every other `dotnet` call (the solution
# listing Get-TestProjects needs) to the real dotnet recorded at setup.
#
# Exits 0 when every case holds, 1 when any case fails.
#
# Usage:
#   pwsh -NoProfile -File ./packs/dotnet/scripts/Test-RunMutation.ps1 [-KeepWorktree]

[CmdletBinding()]
param(
    [switch]$KeepWorktree
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$gateTimeoutMs = 300000

# One committed marker per selected project: the runner groups changed files by
# nearest ancestor csproj, so one added file puts exactly one project in the
# diff without disturbing any existing source.
$coreMarker = 'src/Contoso.Core/MutationFixtureMarker.cs'
$webMarker = 'src/Contoso.Web/MutationFixtureMarker.cs'
$infraMarker = 'Contoso.Infrastructure/MutationFixtureMarker.cs'
$legacyMarker = 'src/Contoso.Legacy/MutationFixtureMarker.cs'
$looseMarker = 'scripts/LooseHelper.cs'
$scriptsMarker = 'scripts/MutationFixtureMarker.txt'

$webReason = 'host proof lives in integration tests this gate does not drive'
$infraReason = 'listed only to prove a stale exclusion still warns'

$checks = 0
$failures = 0
$failed = $false

function Invoke-FixtureGit {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $output = & git -C $script:checkout @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit $LASTEXITCODE"
    }
    return @($output | ForEach-Object { [string]$_ })
}

function Reset-Fixture {
    Invoke-FixtureGit @('reset', '--hard', $script:fixtureBase) | Out-Null
    Invoke-FixtureGit @('clean', '-fdq') | Out-Null
}

function Write-FixtureFile {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$Content
    )

    $full = Join-Path $script:checkout $RelativePath
    New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force | Out-Null
    [System.IO.File]::WriteAllText($full, $Content, [System.Text.UTF8Encoding]::new($false))
}

function New-SolutionFile {
    <#
      A hand-written Contoso.sln. The SDK's own `dotnet new sln` would work but
      pulls in template-engine state and a different format per SDK; the parser
      reads this form back identically on 8.0 and 10.0, and the fixture needs no
      restore or build of its own.
    #>
    param([Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Projects)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('Microsoft Visual Studio Solution File, Format Version 12.00')
    $lines.Add('# Visual Studio Version 17')
    $index = 0
    $guids = [ordered]@{}
    foreach ($name in $Projects.Keys) {
        $index++
        $guid = '{' + ('00000000-0000-0000-0000-{0:D12}' -f $index) + '}'
        $guids[$name] = $guid
        $lines.Add("Project(`"{9A19103F-16F7-4668-BE54-9A1E7A4F7556}`") = `"$name`", `"$($Projects[$name])`", `"$guid`"")
        $lines.Add('EndProject')
    }
    $lines.Add('Global')
    $lines.Add("`tGlobalSection(SolutionConfigurationPlatforms) = preSolution")
    $lines.Add("`t`tDebug|Any CPU = Debug|Any CPU")
    $lines.Add("`tEndGlobalSection")
    $lines.Add("`tGlobalSection(ProjectConfigurationPlatforms) = postSolution")
    foreach ($name in $Projects.Keys) {
        $guid = $guids[$name]
        $lines.Add("`t`t$guid.Debug|Any CPU.ActiveCfg = Debug|Any CPU")
        $lines.Add("`t`t$guid.Debug|Any CPU.Build.0 = Debug|Any CPU")
    }
    $lines.Add("`tEndGlobalSection")
    $lines.Add("`tGlobalSection(SolutionProperties) = preSolution")
    $lines.Add("`t`tHideSolutionNode = FALSE")
    $lines.Add("`tEndGlobalSection")
    $lines.Add('EndGlobal')
    return ($lines -join "`n") + "`n"
}

function New-FixtureRepo {
    <#
      Writes the whole fixture tree and commits it. The gate files under test are
      then overlaid in a second commit, which becomes the diff base every case
      diffs against.
    #>
    $projects = [ordered]@{
        'Contoso.Core'               = 'src\Contoso.Core\Contoso.Core.csproj'
        'Contoso.Infrastructure'     = 'Contoso.Infrastructure\Contoso.Infrastructure.csproj'
        'Contoso.Web'                = 'src\Contoso.Web\Contoso.Web.csproj'
        'Contoso.Legacy'             = 'src\Contoso.Legacy\Contoso.Legacy.csproj'
        'Contoso.UnitTests'          = 'tests\Contoso.UnitTests\Contoso.UnitTests.csproj'
        'Contoso.ArchitectureTests'  = 'tests\Contoso.ArchitectureTests\Contoso.ArchitectureTests.csproj'
    }

    $library = '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net8.0</TargetFramework></PropertyGroup></Project>'
    Write-FixtureFile 'src/Contoso.Core/Contoso.Core.csproj' $library
    Write-FixtureFile 'Contoso.Infrastructure/Contoso.Infrastructure.csproj' $library
    Write-FixtureFile 'src/Contoso.Web/Contoso.Web.csproj' $library
    Write-FixtureFile 'src/Contoso.Legacy/Contoso.Legacy.csproj' $library

    Write-FixtureFile 'src/Contoso.Core/ScopeGuard.cs' @'
namespace Contoso.Core;

public static class ScopeGuard
{
    public static int Holds(int value) => value > 0 ? value : -value;
}
'@
    Write-FixtureFile 'src/Contoso.Core/Unchanged.cs' @'
namespace Contoso.Core;

public static class Unchanged
{
    public static string Describe(int value) => $"value {value}";
}
'@
    Write-FixtureFile 'Contoso.Infrastructure/Repository.cs' @'
namespace Contoso.Infrastructure;

public sealed class Repository
{
    public string? ConnectionString { get; init; }
}
'@
    Write-FixtureFile 'src/Contoso.Web/Program.cs' @'
namespace Contoso.Web;

public static class Program
{
    public static string Hello() => "hello";
}
'@
    Write-FixtureFile 'src/Contoso.Legacy/Dead.cs' @'
namespace Contoso.Legacy;

public static class Dead
{
    public static int Legacy(int value) => value + 1;
}
'@

    # The unit-test project references the three production projects whose
    # classification the cases depend on. Contoso.Legacy is referenced by nobody,
    # which is what makes it the unlisted-ineligible case.
    Write-FixtureFile 'tests/Contoso.UnitTests/Contoso.UnitTests.csproj' @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <IsTestProject>true</IsTestProject>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.11.1" />
  </ItemGroup>
  <ItemGroup>
    <ProjectReference Include="..\..\src\Contoso.Core\Contoso.Core.csproj" />
    <ProjectReference Include="..\..\Contoso.Infrastructure\Contoso.Infrastructure.csproj" />
    <ProjectReference Include="..\..\src\Contoso.Web\Contoso.Web.csproj" />
  </ItemGroup>
</Project>
'@
    Write-FixtureFile 'tests/Contoso.UnitTests/ScopeGuardTests.cs' @'
namespace Contoso.UnitTests;

public sealed class ScopeGuardTests
{
    public static int Holds() => 1;
}
'@

    # ArchitectureTests does reference Core, and must still never be eligible: it
    # fails on the Stryker.* types injected into the mutated assembly, which is an
    # artifact kill rather than a test-quality signal.
    Write-FixtureFile 'tests/Contoso.ArchitectureTests/Contoso.ArchitectureTests.csproj' @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <IsTestProject>true</IsTestProject>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.11.1" />
  </ItemGroup>
  <ItemGroup>
    <ProjectReference Include="..\..\src\Contoso.Core\Contoso.Core.csproj" />
  </ItemGroup>
</Project>
'@
    Write-FixtureFile 'tests/Contoso.ArchitectureTests/LayerTests.cs' @'
namespace Contoso.ArchitectureTests;

public sealed class LayerTests
{
    public static int Layers() => 1;
}
'@

    Write-FixtureFile 'Contoso.sln' (New-SolutionFile -Projects $projects)
    Write-FixtureFile 'README.md' "# Contoso`n`nSynthesised fixture for Test-RunMutation.ps1.`n"

    Invoke-FixtureGit @('-c', 'user.name=mutation fixture', '-c', 'user.email=fixture@contoso.invalid',
        '-c', 'commit.gpgsign=false', 'add', '--all') | Out-Null
    Invoke-FixtureGit @('-c', 'user.name=mutation fixture', '-c', 'user.email=fixture@contoso.invalid',
        '-c', 'commit.gpgsign=false', 'commit', '--quiet', '-m', 'fixture repository') | Out-Null
}

function Set-FixtureHarnessConfig {
    <#
      Writes the harness.yml the case is about. $Exclusions of $null leaves the
      key out entirely, which must read as an empty map, not as a missing gate.
    #>
    param(
        [AllowNull()][hashtable]$Exclusions,
        # $null leaves maxKillShare out entirely, so the gate reads its default of 50.
        [AllowNull()][string]$MaxKillShare = '50',
        # $null (the default) leaves maxKillFileSpan out, so the gate reads its default of 15.
        [AllowNull()][string]$MaxKillFileSpan = $null,
        # $null (the default) leaves concurrency out, so the gate reads its default of half the runner core count.
        [AllowNull()][string]$Concurrency = $null,
        # $null (the default) leaves wholeProject out, so -WholeProject auto-detects.
        [AllowNull()][string]$WholeProject = $null
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @('harnessVersion: 0.7.1', 'pack: dotnet', 'baseBranch: main', 'tracker: github',
            'solution: null', '', 'gates:', '  mutation:', '    threshold: 80')) {
        $lines.Add($line)
    }
    if ($null -ne $MaxKillShare) {
        $lines.Add("    maxKillShare: $MaxKillShare")
    }
    if ($null -ne $MaxKillFileSpan) {
        $lines.Add("    maxKillFileSpan: $MaxKillFileSpan")
    }
    if ($null -ne $Concurrency) {
        $lines.Add("    concurrency: $Concurrency")
    }
    if ($null -ne $WholeProject) {
        $lines.Add("    wholeProject: $WholeProject")
    }
    if ($null -ne $Exclusions) {
        $lines.Add('    exclusions:')
        foreach ($name in @($Exclusions.Keys | Sort-Object)) {
            $lines.Add("      ${name}: `"$($Exclusions[$name])`"")
        }
    }

    $path = Join-Path $script:checkout 'harness.yml'
    [System.IO.File]::WriteAllText($path, ($lines -join "`n") + "`n", [System.Text.UTF8Encoding]::new($false))
}

function Set-FixtureStrykerConfig {
    <#
      Rewrites the overlaid stryker-config.json: $Set entries replace or add a key,
      $Remove entries delete one. Reset-Fixture restores the template copy.
    #>
    param(
        [hashtable]$Set = @{},
        [string[]]$Remove = @()
    )

    $path = Join-Path $script:checkout 'stryker-config.json'
    $config = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    foreach ($key in $Remove) {
        $config.'stryker-config'.PSObject.Properties.Remove($key)
    }
    foreach ($key in $Set.Keys) {
        $config.'stryker-config' | Add-Member -NotePropertyName $key -NotePropertyValue $Set[$key] -Force
    }
    [System.IO.File]::WriteAllText($path, ($config | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
}

function Add-ChangedPaths {
    param([Parameter(Mandatory)][string[]]$Paths)

    foreach ($rel in $Paths) {
        Add-MarkerFile -Path $rel
    }
    Invoke-FixtureGit (@('add', '--') + $Paths) | Out-Null
    Invoke-FixtureGit @('-c', 'user.name=mutation fixture', '-c', 'user.email=fixture@contoso.invalid',
        '-c', 'commit.gpgsign=false', 'commit', '--quiet', '-m', "fixture diff: $($Paths -join ', ')") | Out-Null
}

function Add-MarkerFile {
    param([Parameter(Mandatory)][string]$Path)

    $full = Join-Path $script:checkout $Path
    New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force | Out-Null
    # Comment-only, so a marker can never break a build that a later case decides
    # to compile.
    Set-Content -LiteralPath $full -Value "// Mutation fixture marker: selects $Path for the diff under test."
}

function Invoke-MutationGate {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [hashtable]$Environment = @{}
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = (Get-Command pwsh).Source
    foreach ($arg in (@('-NoProfile', '-File', (Join-Path $script:checkout 'scripts/run-mutation.ps1')) + $Arguments)) {
        [void]$psi.ArgumentList.Add($arg)
    }
    $psi.WorkingDirectory = $script:checkout
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.Environment['HARNESS_REPO_ROOT'] = $script:checkout
    # The whole-project cases prepend a stub `dotnet` to PATH here; every other
    # variable (the stub's report source and output directory) rides along.
    foreach ($key in $Environment.Keys) {
        $psi.Environment[$key] = [string]$Environment[$key]
    }

    $proc = [System.Diagnostics.Process]::Start($psi)
    # Both streams are drained concurrently: a full pipe buffer on either one
    # would block the child before it could exit.
    $stdout = $proc.StandardOutput.ReadToEndAsync()
    $stderr = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($script:gateTimeoutMs)) {
        $proc.Kill($true)
        throw "run-mutation.ps1 $($Arguments -join ' ') exceeded $script:gateTimeoutMs ms and was killed"
    }

    return [PSCustomObject]@{
        Exit   = $proc.ExitCode
        Output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
    }
}

function Assert-MutationCase {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Setup,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][int]$ExpectedExit,
        [string[]]$MustContain = @(),
        [string[]]$MustNotContain = @(),
        [hashtable]$Environment = @{}
    )

    $script:checks++
    Reset-Fixture
    & $Setup

    $run = Invoke-MutationGate -Arguments $Arguments -Environment $Environment
    $problems = [System.Collections.Generic.List[string]]::new()

    if ($run.Exit -ne $ExpectedExit) {
        $problems.Add("exit $($run.Exit), expected $ExpectedExit")
    }
    foreach ($text in $MustContain) {
        if ($run.Output.IndexOf($text, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
            $problems.Add("output is missing '$text'")
        }
    }
    foreach ($text in $MustNotContain) {
        if ($run.Output.IndexOf($text, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $problems.Add("output must not contain '$text'")
        }
    }

    if ($problems.Count -eq 0) {
        Write-Host "  ok       $Name (exit $($run.Exit))"
        return
    }

    $script:failures++
    Write-Host "  FAIL     $Name" -ForegroundColor Red
    foreach ($problem in $problems) {
        Write-Host "           - $problem" -ForegroundColor Red
    }
    foreach ($line in @($run.Output -split "`r?`n" | Where-Object { $_.Trim() })) {
        Write-Host "           | $line" -ForegroundColor Red
    }
}

function Write-ScopeReport {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$FilesJson
    )

    $json = @"
{
  "schemaVersion": "2",
  "files": {
$FilesJson
  },
  "testFiles": {
    "tests/Contoso.UnitTests/ScopeGuardTests.cs": {
      "tests": [ { "id": "t1", "name": "Contoso.UnitTests.ScopeGuardTests.Holds" } ]
    }
  }
}
"@
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
}

function Write-KillShareReport {
    <#
      Writes a schema-2 report whose mutants all sit in $FileKey, one mutant per entry of
      $KillerSets. An entry is the test ids that killed that mutant, joined by '|', so
      't1|t2' is one mutant killed by two tests. Every id is declared under testFiles so
      each killer resolves to a name, as a real report does.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$FileKey,
        [Parameter(Mandatory)][string[]]$KillerSets
    )

    $mutants = [System.Collections.Generic.List[object]]::new()
    $testIds = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
    for ($i = 0; $i -lt $KillerSets.Count; $i++) {
        $ids = @($KillerSets[$i] -split '\|')
        foreach ($id in $ids) { [void]$testIds.Add($id) }
        $mutants.Add([ordered]@{
                id           = [string]($i + 1)
                status       = 'Killed'
                killedBy     = $ids
                mutatorName  = 'Statement'
                location     = [ordered]@{ start = [ordered]@{ line = $i + 1 } }
            })
    }
    $tests = @($testIds | ForEach-Object { [ordered]@{ id = $_; name = "Contoso.UnitTests.ScopeGuardTests.$_" } })
    $report = [ordered]@{
        schemaVersion = '2'
        files         = [ordered]@{ $FileKey = [ordered]@{ mutants = @($mutants) } }
        testFiles     = [ordered]@{ 'tests/Contoso.UnitTests/ScopeGuardTests.cs' = [ordered]@{ tests = $tests } }
    }
    [System.IO.File]::WriteAllText($Path, ($report | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
}

function Write-KillSpanReport {
    <#
      Writes a schema-2 report spread over $FileCount files, src/Contoso.Core/Span<i>.cs.
      Each file holds one mutant killed by the wide test 'wide' and two killed by a test
      local to that file, so 'wide' spans every file while its kill share stays at a third
      and the share rule never fires.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$FileCount
    )

    $files = [ordered]@{}
    $tests = [System.Collections.Generic.List[object]]::new()
    $tests.Add([ordered]@{ id = 'wide'; name = 'Contoso.UnitTests.ScopeGuardTests.wide' })
    $nextId = 1
    for ($i = 1; $i -le $FileCount; $i++) {
        $local = "f$i"
        $tests.Add([ordered]@{ id = $local; name = "Contoso.UnitTests.ScopeGuardTests.$local" })
        $mutants = foreach ($killer in @('wide', $local, $local)) {
            [ordered]@{
                id          = [string]$nextId
                status      = 'Killed'
                killedBy    = @($killer)
                mutatorName = 'Statement'
                location    = [ordered]@{ start = [ordered]@{ line = $nextId } }
            }
            $nextId++
        }
        $files["src/Contoso.Core/Span$i.cs"] = [ordered]@{ mutants = @($mutants) }
    }
    $report = [ordered]@{
        schemaVersion = '2'
        files         = $files
        testFiles     = [ordered]@{ 'tests/Contoso.UnitTests/ScopeGuardTests.cs' = [ordered]@{ tests = @($tests) } }
    }
    [System.IO.File]::WriteAllText($Path, ($report | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
}

function New-StrykerStubEnvironment {
    <#
      Child environment for a whole-project invocation whose `dotnet stryker` call
      is answered by the fixture stub. PATH puts the stub first; STRYKER_STUB_REAL_DOTNET
      forwards the solution listing Get-TestProjects needs, STRYKER_STUB_REPORT_SRC is the
      report the stub copies, and STRYKER_STUB_REPORT_DIR is the -O reports directory the
      script reads back.
    #>
    param(
        [Parameter(Mandatory)][string]$OutputRoot,
        [Parameter(Mandatory)][string]$ReportSource,
        [string]$Project = 'Contoso.Core'
    )

    $separator = [System.IO.Path]::PathSeparator
    return @{
        PATH                     = "$($script:stubDir)$separator$($env:PATH)"
        STRYKER_STUB_REAL_DOTNET = $script:realDotnet
        STRYKER_STUB_REPORT_SRC  = $ReportSource
        STRYKER_STUB_REPORT_DIR  = Join-Path (Join-Path $OutputRoot $Project) 'reports'
    }
}

function Assert-FixtureWiring {
    $manifest = Join-Path $script:checkout '.config/dotnet-tools.json'
    if (-not (Test-Path -LiteralPath $manifest)) { throw "overlay missing: $manifest" }
    if ((Get-Content -LiteralPath $manifest -Raw) -notmatch '"dotnet-stryker"') {
        throw 'overlay .config/dotnet-tools.json does not name dotnet-stryker'
    }

    # The config the fixture overlays is what the gate must accept. In the harness
    # repo that is the shipped template; in a consumer it is the repo's own file,
    # so a gate that refuses it fails here rather than at the next gate run.
    $strykerConfig = Join-Path $script:checkout 'stryker-config.json'
    if (-not (Test-Path -LiteralPath $strykerConfig)) { throw "overlay missing: $strykerConfig" }
    $baseStryker = (Get-Content -LiteralPath $strykerConfig -Raw | ConvertFrom-Json).'stryker-config'
    if ([string]::IsNullOrWhiteSpace([string]$baseStryker.'test-runner')) {
        throw 'the stryker-config.json under test does not declare test-runner, so the gate would refuse it (harness.yml gates.mutation.runner makes install.ps1 render one)'
    }
    if ([long]$baseStryker.'additional-timeout' -lt 30000) {
        throw 'the stryker-config.json under test does not set additional-timeout to at least 30000'
    }

    if (-not (Test-Path -LiteralPath (Join-Path $script:checkout 'Contoso.sln'))) {
        throw 'the fixture checkout carries no Contoso.sln, so no test project can be resolved'
    }

    # Every classification in every case follows from these references, so a
    # silent change to them must fail here rather than read as a gate bug.
    $unitTests = Join-Path $script:checkout 'tests/Contoso.UnitTests/Contoso.UnitTests.csproj'
    if (-not (Test-Path -LiteralPath $unitTests)) { throw "the fixture checkout carries no $unitTests" }
    $unitTestsText = Get-Content -LiteralPath $unitTests -Raw
    foreach ($required in @('Contoso\.Core\.csproj', 'Contoso\.Infrastructure\.csproj', 'Contoso\.Web\.csproj')) {
        if ($unitTestsText -notmatch $required) {
            throw "Contoso.UnitTests no longer references $required, so the classifications this suite asserts no longer follow"
        }
    }
}

function Find-RepoRoot {
    <#
      The nearest ancestor that looks like a repository root. The suite runs from
      packs/dotnet/scripts inside the harness repo and from scripts/ in a consumer,
      so neither a fixed number of levels nor $PSScriptRoot alone is right.
    #>
    param([Parameter(Mandatory)][string]$Start)

    $dir = $Start
    for ($i = 0; $i -lt 6; $i++) {
        if (Test-Path -LiteralPath (Join-Path $dir 'harness.yml')) { return $dir }
        if (Test-Path -LiteralPath (Join-Path $dir '.git')) { return $dir }
        $parent = Split-Path $dir -Parent
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    throw "could not find the repository root above '$Start'"
}

$repoRoot = Find-RepoRoot -Start $PSScriptRoot

# The gate files under test are taken from this script's own directory, so the
# suite tests the copies that actually run. The two configs come from the harness
# pack when this runs inside the harness repo, and from the repo's own files when
# the suite was installed into a consumer - which is the stronger check there,
# because it proves the consumer's real config is one the gate accepts.
$overlay = [ordered]@{
    'scripts/run-mutation.ps1'    = Join-Path $PSScriptRoot 'run-mutation.ps1'
    'scripts/_gate-common.ps1'    = Join-Path $PSScriptRoot '_gate-common.ps1'
    'scripts/_harness-config.ps1' = Join-Path $PSScriptRoot '_harness-config.ps1'
}
$packTemplates = Join-Path $repoRoot 'packs/dotnet/templates'
if (Test-Path -LiteralPath (Join-Path $packTemplates 'stryker-config.json')) {
    $overlay['.config/dotnet-tools.json'] = Join-Path $packTemplates 'dotnet-tools.json'
    $overlay['stryker-config.json'] = Join-Path $packTemplates 'stryker-config.json'
    $configSource = 'the shipped template'
}
else {
    $overlay['.config/dotnet-tools.json'] = Join-Path $repoRoot '.config/dotnet-tools.json'
    $overlay['stryker-config.json'] = Join-Path $repoRoot 'stryker-config.json'
    $configSource = "this repo's own config"
}

$script:work = Join-Path ([System.IO.Path]::GetTempPath()) `
    ('stryker-test-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$script:checkout = Join-Path $script:work 'checkout'

try {
    New-Item -ItemType Directory -Path $script:checkout -Force | Out-Null

    & git -C $script:checkout init --quiet --initial-branch=main
    if ($LASTEXITCODE -ne 0) { throw "git init failed with exit $LASTEXITCODE" }

    New-FixtureRepo

    foreach ($relativePath in $overlay.Keys) {
        $source = $overlay[$relativePath]
        if (-not (Test-Path -LiteralPath $source)) { throw "overlay source missing: $source" }
        $destination = Join-Path $script:checkout $relativePath
        New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }
    Invoke-FixtureGit (@('add', '--') + @($overlay.Keys)) | Out-Null
    Invoke-FixtureGit @('-c', 'user.name=mutation fixture', '-c', 'user.email=fixture@contoso.invalid',
        '-c', 'commit.gpgsign=false', 'commit', '--quiet', '-m', 'fixture tooling overlay') | Out-Null
    $script:fixtureBase = (@(Invoke-FixtureGit @('rev-parse', 'HEAD'))[0]).Trim()

    # The stub `dotnet` the whole-project cases put first on the child's PATH. It
    # answers a `stryker` call by copying the fixture report into the -O reports
    # directory and any other call (the solution listing Get-TestProjects needs) by
    # forwarding to the real dotnet recorded here, so project discovery stays real.
    $script:realDotnet = (Get-Command dotnet -CommandType Application | Select-Object -First 1).Source
    if (-not $script:realDotnet) { throw 'no dotnet application on PATH, so the stryker stub cannot forward solution discovery' }
    $script:stubDir = Join-Path $script:work 'stub-bin'
    New-Item -ItemType Directory -Path $script:stubDir -Force | Out-Null

    $stubCmd = @'
@echo off
if /i "%~1"=="stryker" (
  if not exist "%STRYKER_STUB_REPORT_DIR%" mkdir "%STRYKER_STUB_REPORT_DIR%" >nul 2>&1
  copy /y "%STRYKER_STUB_REPORT_SRC%" "%STRYKER_STUB_REPORT_DIR%\mutation-report.json" >nul
  exit /b 0
)
"%STRYKER_STUB_REAL_DOTNET%" %*
exit /b %ERRORLEVEL%
'@
    $stubSh = @'
#!/bin/sh
if [ "$1" = "stryker" ]; then
  mkdir -p "$STRYKER_STUB_REPORT_DIR"
  cp "$STRYKER_STUB_REPORT_SRC" "$STRYKER_STUB_REPORT_DIR/mutation-report.json"
  exit 0
fi
exec "$STRYKER_STUB_REAL_DOTNET" "$@"
'@
    [System.IO.File]::WriteAllText((Join-Path $script:stubDir 'dotnet.cmd'),
        ($stubCmd -replace "`r?`n", "`r`n"), [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $script:stubDir 'dotnet'),
        ($stubSh -replace "`r?`n", "`n"), [System.Text.UTF8Encoding]::new($false))
    try { & chmod +x (Join-Path $script:stubDir 'dotnet') *> $null } catch { }

    Assert-FixtureWiring

    Write-Host 'Fixture checkout: ' $script:checkout
    Write-Host "Diff base: $script:fixtureBase (overlay of the gate files under test, configs from $configSource)"
    Write-Host ''
    Write-Host 'Classification cases:'

    Assert-MutationCase -Name '1 listed Web plus eligible Core classifies both and exits 0' -Setup {
        Set-FixtureHarnessConfig -Exclusions @{ 'Contoso.Web' = $webReason }
        Add-ChangedPaths -Paths @($webMarker, $coreMarker)
    } -Arguments @('-DryRun', '-BaseRef', $script:fixtureBase) -ExpectedExit 0 -MustContain @(
        'NOT APPLICABLE',
        $webReason,
        'Contoso.Core.csproj',
        'tests/Contoso.UnitTests/Contoso.UnitTests.csproj'
    )

    $listedWebOnly = {
        Set-FixtureHarnessConfig -Exclusions @{ 'Contoso.Web' = $webReason }
        Add-ChangedPaths -Paths @($webMarker)
    }
    Assert-MutationCase -Name '2 listed Web only, -DryRun, exits 2 NOT APPLICABLE' -Setup $listedWebOnly `
        -Arguments @('-DryRun', '-BaseRef', $script:fixtureBase) -ExpectedExit 2 `
        -MustContain @('NOT APPLICABLE', $webReason, 'WARNING', 'tests/Contoso.UnitTests/Contoso.UnitTests.csproj') `
        -MustNotContain @('no eligible test project')

    # Web stays listed, so the real run measures nothing and must not start Stryker.
    Assert-MutationCase -Name '2 listed Web only, real run, exits 2 NOT APPLICABLE' -Setup $listedWebOnly `
        -Arguments @('-BaseRef', $script:fixtureBase) -ExpectedExit 2 `
        -MustContain @('NOT APPLICABLE', $webReason) -MustNotContain @('Stryker native exit')

    Assert-MutationCase -Name '3 unlisted project with no eligible test project exits 1' -Setup {
        Set-FixtureHarnessConfig -Exclusions $null
        Add-ChangedPaths -Paths @($legacyMarker)
    } -Arguments @('-DryRun', '-BaseRef', $script:fixtureBase) -ExpectedExit 1 -MustContain @(
        'Contoso.Legacy.csproj',
        'no eligible test project, not in policy'
    )

    Assert-MutationCase -Name '3 unlisted Web plus eligible Core classifies both and exits 0' -Setup {
        Set-FixtureHarnessConfig -Exclusions $null
        Add-ChangedPaths -Paths @($webMarker, $coreMarker)
    } -Arguments @('-DryRun', '-BaseRef', $script:fixtureBase) -ExpectedExit 0 -MustContain @(
        'Contoso.Web.csproj',
        'Contoso.Core.csproj',
        'tests/Contoso.UnitTests/Contoso.UnitTests.csproj'
    ) -MustNotContain @('no eligible test project')

    # ArchitectureTests references Core and must still never be listed as an
    # eligible test project: it fails on the injected Stryker types.
    Assert-MutationCase -Name '3b ArchitectureTests is never an eligible test project' -Setup {
        Set-FixtureHarnessConfig -Exclusions $null
        Add-ChangedPaths -Paths @($coreMarker)
    } -Arguments @('-DryRun', '-BaseRef', $script:fixtureBase) -ExpectedExit 0 `
        -MustContain @('Test projects for Contoso.Core.csproj: tests/Contoso.UnitTests/Contoso.UnitTests.csproj') `
        -MustNotContain @('Contoso.ArchitectureTests')

    # The diff touches no production C#, so an invalid policy has to be caught
    # before the scope-empty check instead of hiding behind SKIPPED.
    Assert-MutationCase -Name '4 blank reason exits 1 as a configuration error, ahead of scope-empty' -Setup {
        Set-FixtureHarnessConfig -Exclusions @{ 'Contoso.Web' = '   ' }
        Add-ChangedPaths -Paths @($scriptsMarker)
    } -Arguments @('-DryRun', '-BaseRef', $script:fixtureBase) -ExpectedExit 1 `
        -MustContain @('configuration') -MustNotContain @('SKIPPED')

    Assert-MutationCase -Name '5 listed project that has eligible tests warns and stays excluded' -Setup {
        Set-FixtureHarnessConfig -Exclusions @{ 'Contoso.Infrastructure' = $infraReason }
        Add-ChangedPaths -Paths @($infraMarker)
    } -Arguments @('-DryRun', '-BaseRef', $script:fixtureBase) -ExpectedExit 2 `
        -MustContain @('WARNING', 'NOT APPLICABLE', $infraReason)

    Write-Host ''
    Write-Host 'Scope cases:'

    # A change that only touches a test project measures nothing. It must read as
    # scope-empty rather than as a changed project with no eligible test project.
    Assert-MutationCase -Name '5b a test-project-only change exits 2 SKIPPED, never 1' -Setup {
        Set-FixtureHarnessConfig -Exclusions $null
        Add-ChangedPaths -Paths @('tests/Contoso.UnitTests/ScopeGuardTests.cs')
    } -Arguments @('-DryRun', '-BaseRef', $script:fixtureBase) -ExpectedExit 2 `
        -MustContain @('SKIPPED') -MustNotContain @('no eligible test project', 'Contoso.UnitTests.csproj')

    # A loose .cs file in no project can never produce mutants, so it is listed and
    # skipped instead of tripping the file-to-project mapping.
    Assert-MutationCase -Name '5c a changed .cs that belongs to no project is listed and skipped' -Setup {
        Set-FixtureHarnessConfig -Exclusions $null
        Add-ChangedPaths -Paths @($looseMarker)
    } -Arguments @('-DryRun', '-BaseRef', $script:fixtureBase) -ExpectedExit 2 `
        -MustContain @('Not in any project', $looseMarker, 'SKIPPED')

    # Production code outside src/ is in scope: the layout comes from the project
    # files, not from a path prefix.
    Assert-MutationCase -Name '5d production code outside src/ is in scope' -Setup {
        Set-FixtureHarnessConfig -Exclusions $null
        Add-ChangedPaths -Paths @($infraMarker)
    } -Arguments @('-DryRun', '-BaseRef', $script:fixtureBase) -ExpectedExit 0 `
        -MustContain @('Contoso.Infrastructure.csproj', 'tests/Contoso.UnitTests/Contoso.UnitTests.csproj')

    # Scope guard. The changed file is the diff; Unchanged.cs is the file the diff
    # does not touch. -ScopeFile is what makes containment run under -EvaluateReport,
    # which otherwise skips it.
    $scopeChanged = 'src/Contoso.Core/ScopeGuard.cs'
    $scopeUnchanged = 'src/Contoso.Core/Unchanged.cs'
    $scopeReport = Join-Path $script:work 'scope-guard-report.json'
    $killedInChangedFile = @"
    "$scopeChanged": {
      "mutants": [
        { "id": "1", "status": "Killed", "killedBy": ["t1"], "mutatorName": "Statement", "location": { "start": { "line": 10 } } }
      ]
    }
"@

    Write-Host ''
    Write-Host 'Scope guard cases:'

    Assert-MutationCase -Name '6 Ignored and CompileError in an unchanged file the mutate filter removed do not fail' -Setup {
        Write-ScopeReport -Path $scopeReport -FilesJson @"
$killedInChangedFile,
    "$scopeUnchanged": {
      "mutants": [
        { "id": "2", "status": "Ignored", "statusReason": "Removed by mutate filter" },
        { "id": "3", "status": "CompileError", "statusReason": "Mutant caused compile errors" }
      ]
    }
"@
    } -Arguments @('-EvaluateReport', $scopeReport, '-ScopeFile', $scopeChanged) -ExpectedExit 0 `
        -MustContain @('PASSED') -MustNotContain @('outside changed files', 'FAILED')

    Assert-MutationCase -Name '7 a survivor in a changed file still fails' -Setup {
        Write-ScopeReport -Path $scopeReport -FilesJson @"
    "$scopeChanged": {
      "mutants": [
        { "id": "1", "status": "Survived", "mutatorName": "Statement", "location": { "start": { "line": 12 } } }
      ]
    }
"@
    } -Arguments @('-EvaluateReport', $scopeReport, '-ScopeFile', $scopeChanged) -ExpectedExit 1 `
        -MustContain @('below threshold', $scopeChanged)

    Assert-MutationCase -Name '8 a CompileError in a changed file still fails' -Setup {
        Write-ScopeReport -Path $scopeReport -FilesJson @"
    "$scopeChanged": {
      "mutants": [
        { "id": "1", "status": "CompileError", "statusReason": "Mutant caused compile errors" }
      ]
    }
"@
    } -Arguments @('-EvaluateReport', $scopeReport, '-ScopeFile', $scopeChanged) -ExpectedExit 1 `
        -MustContain @('none were tested', $scopeChanged)

    Assert-MutationCase -Name '9 an unchanged file ignored for another reason still fails' -Setup {
        Write-ScopeReport -Path $scopeReport -FilesJson @"
$killedInChangedFile,
    "$scopeUnchanged": {
      "mutants": [
        { "id": "2", "status": "Ignored", "statusReason": "Removed by block already covered filter" }
      ]
    }
"@
    } -Arguments @('-EvaluateReport', $scopeReport, '-ScopeFile', $scopeChanged) -ExpectedExit 1 `
        -MustContain @('outside changed files', $scopeUnchanged)

    # Artifact-kill share rule (maxKillShare, default 50; exempt below 20 tested). Each
    # case writes a report with the kill counts it needs and evaluates it through -EvaluateReport.
    $shareReport = Join-Path $script:work 'share-report.json'
    $shareArgs = @('-EvaluateReport', $shareReport, '-ScopeFile', $scopeChanged)

    Write-Host ''
    Write-Host 'Artifact-kill share cases:'

    Assert-MutationCase -Name '14 one test killing 60 of 100 tested mutants fails as a suspected artifact kill' -Setup {
        Write-KillShareReport -Path $shareReport -FileKey $scopeChanged -KillerSets ((@('t1') * 60) + (@('t2') * 40))
    } -Arguments $shareArgs -ExpectedExit 1 -MustContain @(
        'Suspected artifact kill',
        'Contoso.UnitTests.ScopeGuardTests.t1 killed 60 of 100 tested mutants (60.0%), above the 50% limit',
        'FAILED'
    ) -MustNotContain @('Kill share: not applied')

    Assert-MutationCase -Name '15 largest share 49 of 100 is just under the limit and passes' -Setup {
        Write-KillShareReport -Path $shareReport -FileKey $scopeChanged -KillerSets ((@('t1') * 49) + (@('t2') * 49) + (@('t3') * 2))
    } -Arguments $shareArgs -ExpectedExit 0 -MustContain @(
        'PASSED',
        'largest single-test share 49.00% of 100 tested (limit 50%)'
    ) -MustNotContain @('Suspected artifact kill')

    Assert-MutationCase -Name '15b largest share exactly 50 of 100 is at the limit and passes' -Setup {
        Write-KillShareReport -Path $shareReport -FileKey $scopeChanged -KillerSets ((@('t1') * 50) + (@('t2') * 50))
    } -Arguments $shareArgs -ExpectedExit 0 -MustContain @(
        'PASSED',
        'largest single-test share 50.00% of 100 tested (limit 50%)'
    ) -MustNotContain @('Suspected artifact kill')

    Assert-MutationCase -Name '16 a 9 of 10 share below 20 tested is exempt and says so' -Setup {
        Write-KillShareReport -Path $shareReport -FileKey $scopeChanged -KillerSets ((@('t1') * 9) + @('t2'))
    } -Arguments $shareArgs -ExpectedExit 0 -MustContain @(
        'PASSED',
        'Kill share: not applied (10 tested is below the 20-mutant minimum)'
    ) -MustNotContain @('Suspected artifact kill')

    Assert-MutationCase -Name '17 four tests each killing every mutant report three and +1 more' -Setup {
        Write-KillShareReport -Path $shareReport -FileKey $scopeChanged -KillerSets (@('t1|t2|t3|t4') * 100)
    } -Arguments $shareArgs -ExpectedExit 1 -MustContain @(
        'Contoso.UnitTests.ScopeGuardTests.t1 killed 100 of 100 tested mutants (100.0%), above the 50% limit',
        'Contoso.UnitTests.ScopeGuardTests.t3 killed 100 of 100',
        '; +1 more.'
    ) -MustNotContain @('ScopeGuardTests.t4 killed')

    Assert-MutationCase -Name '18 maxKillShare 0 is a configuration error that exits 1 before evaluation' -Setup {
        Set-FixtureHarnessConfig -Exclusions $null -MaxKillShare '0'
        Write-KillShareReport -Path $shareReport -FileKey $scopeChanged -KillerSets ((@('t1') * 60) + (@('t2') * 40))
    } -Arguments $shareArgs -ExpectedExit 1 -MustContain @(
        'invalid mutation configuration in harness.yml gates.mutation.maxKillShare',
        'must be an integer from 1 to 100, got ''0'''
    ) -MustNotContain @('Suspected artifact kill')

    Assert-MutationCase -Name '19 maxKillShare 101 is a configuration error that exits 1 before evaluation' -Setup {
        Set-FixtureHarnessConfig -Exclusions $null -MaxKillShare '101'
        Write-KillShareReport -Path $shareReport -FileKey $scopeChanged -KillerSets ((@('t1') * 60) + (@('t2') * 40))
    } -Arguments $shareArgs -ExpectedExit 1 -MustContain @(
        'invalid mutation configuration in harness.yml gates.mutation.maxKillShare',
        'must be an integer from 1 to 100, got ''101'''
    ) -MustNotContain @('Suspected artifact kill')

    Assert-MutationCase -Name '20 a non-integer maxKillShare is a configuration error that exits 1' -Setup {
        Set-FixtureHarnessConfig -Exclusions $null -MaxKillShare 'fifty'
        Write-KillShareReport -Path $shareReport -FileKey $scopeChanged -KillerSets ((@('t1') * 60) + (@('t2') * 40))
    } -Arguments $shareArgs -ExpectedExit 1 -MustContain @('maxKillShare') -MustNotContain @('Suspected artifact kill')

    Assert-MutationCase -Name '21 an absent maxKillShare key reads the default 50 and fails a 60 percent share' -Setup {
        Set-FixtureHarnessConfig -Exclusions $null -MaxKillShare $null
        Write-KillShareReport -Path $shareReport -FileKey $scopeChanged -KillerSets ((@('t1') * 60) + (@('t2') * 40))
    } -Arguments $shareArgs -ExpectedExit 1 -MustContain @(
        'Suspected artifact kill',
        'above the 50% limit'
    )

    # Artifact-kill file-span rule (maxKillFileSpan, default 15; no sample minimum). The
    # span reports cover files outside any diff, so they are evaluated without -ScopeFile.
    $spanReport = Join-Path $script:work 'span-report.json'
    $spanArgs = @('-EvaluateReport', $spanReport)

    Write-Host ''
    Write-Host 'Artifact-kill file-span cases:'

    Assert-MutationCase -Name '22 one test killing mutants in 16 files fails as a suspected artifact kill' -Setup {
        Write-KillSpanReport -Path $spanReport -FileCount 16
    } -Arguments $spanArgs -ExpectedExit 1 -MustContain @(
        'Suspected artifact kill',
        'Contoso.UnitTests.ScopeGuardTests.wide killed mutants in 16 files, above the 15-file limit',
        'FAILED'
    ) -MustNotContain @('of 48 tested mutants')

    Assert-MutationCase -Name '23 a span of exactly 15 files is at the limit and passes' -Setup {
        Write-KillSpanReport -Path $spanReport -FileCount 15
    } -Arguments $spanArgs -ExpectedExit 0 -MustContain @(
        'PASSED',
        'largest single-test file span 15 file(s) (limit 15)'
    ) -MustNotContain @('Suspected artifact kill')

    Assert-MutationCase -Name '24 maxKillFileSpan 0 is a configuration error that exits 1 before evaluation' -Setup {
        Set-FixtureHarnessConfig -Exclusions $null -MaxKillFileSpan '0'
        Write-KillSpanReport -Path $spanReport -FileCount 16
    } -Arguments $spanArgs -ExpectedExit 1 -MustContain @(
        'invalid mutation configuration in harness.yml gates.mutation.maxKillFileSpan',
        'must be an integer of at least 1, got ''0'''
    ) -MustNotContain @('Suspected artifact kill')

    Assert-MutationCase -Name '25 a non-integer maxKillFileSpan is a configuration error that exits 1' -Setup {
        Set-FixtureHarnessConfig -Exclusions $null -MaxKillFileSpan 'wide'
        Write-KillSpanReport -Path $spanReport -FileCount 2
    } -Arguments $spanArgs -ExpectedExit 1 -MustContain @('maxKillFileSpan') -MustNotContain @('Suspected artifact kill', 'PASSED')

    Assert-MutationCase -Name '26 a configured maxKillFileSpan of 5 fails a 6-file span below the share minimum' -Setup {
        Set-FixtureHarnessConfig -Exclusions $null -MaxKillFileSpan '5'
        Write-KillSpanReport -Path $spanReport -FileCount 6
    } -Arguments $spanArgs -ExpectedExit 1 -MustContain @(
        'killed mutants in 6 files, above the 5-file limit',
        'Kill share: not applied (18 tested is below the 20-mutant minimum)'
    )

    Assert-MutationCase -Name '27 concurrency 0 is a configuration error that exits 1 before evaluation' -Setup {
        Set-FixtureHarnessConfig -Exclusions $null -Concurrency '0'
        Write-KillSpanReport -Path $spanReport -FileCount 2
    } -Arguments $spanArgs -ExpectedExit 1 -MustContain @(
        'invalid mutation configuration in harness.yml gates.mutation.concurrency',
        'must be an integer of at least 1, got ''0'''
    ) -MustNotContain @('Suspected artifact kill', 'PASSED')

    # Test-runner wiring. The gate never guesses the runner, so a config that does
    # not name one - or names mtp without the coverage setting mtp requires - is a
    # wiring defect and not a score of zero.
    Write-Host ''
    Write-Host 'Test-runner wiring cases:'

    Assert-MutationCase -Name '28 a stryker-config.json without test-runner is GATE NOT WIRED' -Setup {
        Set-FixtureHarnessConfig -Exclusions $null
        Add-ChangedPaths -Paths @($coreMarker)
        Set-FixtureStrykerConfig -Remove @('test-runner')
    } -Arguments @('-DryRun', '-BaseRef', $script:fixtureBase) -ExpectedExit 1 -MustContain @(
        'GATE NOT WIRED',
        'does not set ''test-runner'''
    ) -MustNotContain @('Generated config', 'Stryker config for')

    Assert-MutationCase -Name '29 test-runner mtp with coverage-analysis on is GATE NOT WIRED' -Setup {
        Set-FixtureHarnessConfig -Exclusions $null
        Add-ChangedPaths -Paths @($coreMarker)
        Set-FixtureStrykerConfig -Set @{ 'test-runner' = 'mtp'; 'coverage-analysis' = 'off' }
        Set-FixtureStrykerConfig -Set @{ 'coverage-analysis' = 'perTest' }
    } -Arguments @('-DryRun', '-BaseRef', $script:fixtureBase) -ExpectedExit 1 -MustContain @(
        'GATE NOT WIRED',
        'coverage-analysis is ''perTest'''
    )

    Assert-MutationCase -Name '30 an unknown test-runner value is GATE NOT WIRED' -Setup {
        Set-FixtureHarnessConfig -Exclusions $null
        Add-ChangedPaths -Paths @($coreMarker)
        Set-FixtureStrykerConfig -Set @{ 'test-runner' = 'nunit-console' }
    } -Arguments @('-DryRun', '-BaseRef', $script:fixtureBase) -ExpectedExit 1 -MustContain @(
        'GATE NOT WIRED',
        'test-runner'' to ''nunit-console'''
    )

    Assert-MutationCase -Name '30b a stryker-config.json without additional-timeout is GATE NOT WIRED' -Setup {
        Set-FixtureHarnessConfig -Exclusions $null
        Add-ChangedPaths -Paths @($coreMarker)
        Set-FixtureStrykerConfig -Remove @('additional-timeout')
    } -Arguments @('-DryRun', '-BaseRef', $script:fixtureBase) -ExpectedExit 1 -MustContain @(
        'GATE NOT WIRED',
        'does not set ''additional-timeout'' to an integer'
    ) -MustNotContain @('Generated config')

    Assert-MutationCase -Name '30c an additional-timeout below 30000 is GATE NOT WIRED' -Setup {
        Set-FixtureHarnessConfig -Exclusions $null
        Add-ChangedPaths -Paths @($coreMarker)
        Set-FixtureStrykerConfig -Set @{ 'additional-timeout' = 5000 }
    } -Arguments @('-DryRun', '-BaseRef', $script:fixtureBase) -ExpectedExit 1 -MustContain @(
        'GATE NOT WIRED',
        'sets ''additional-timeout'' to 5000 (expected at least 30000'
    ) -MustNotContain @('Generated config')

    # The generated config is the project's own config with only the gate-owned keys
    # replaced, so a project setting the gate does not own survives into the run. The
    # key is injected by the case, so the assertion holds whether the config under
    # test came from the shipped template or from a consumer repo.
    Assert-MutationCase -Name '30d the generated config keeps the settings the gate does not own' -Setup {
        Set-FixtureHarnessConfig -Exclusions $null
        Add-ChangedPaths -Paths @($coreMarker)
        Set-FixtureStrykerConfig -Set @{ 'ignore-methods' = @('Equals', 'GetHashCode'); 'log-level' = 'debug' }
    } -Arguments @('-DryRun', '-BaseRef', $script:fixtureBase) -ExpectedExit 0 -MustContain @(
        '"ignore-methods"',
        '"log-level": "debug"',
        '"additional-timeout": 30000',
        '"concurrency":',
        '"enabled": false'
    )

    # Whole-project mode. Classification and the zero-diff contrast run without the
    # stub; the invocation and both changed-file guards drive a stub `dotnet stryker`
    # so no real Stryker run happens in the fixture.
    #
    # A committed file, named rather than discovered: whole-project enumeration puts
    # every source file in the changed set, and discovery would pick up whichever
    # marker a previous case left behind.
    $coreChangedFile = 'src/Contoso.Core/ScopeGuard.cs'

    Write-Host ''
    Write-Host 'Whole-project mode cases:'

    Assert-MutationCase -Name '10 whole-project mutate paths are project-relative for nested project files' -Setup {
        Set-FixtureHarnessConfig -Exclusions @{ 'Contoso.Infrastructure' = $infraReason; 'Contoso.Web' = $webReason }
        Write-FixtureFile 'src/Contoso.Core/Domain/NestedFixture.cs' 'namespace Contoso.Core.Domain; public sealed class NestedFixture { }'
    } -Arguments @('-WholeProject', '-DryRun') -ExpectedExit 0 -MustContain @(
        'Whole-project mode: Contoso.Core.csproj',
        'tests/Contoso.UnitTests/Contoso.UnitTests.csproj',
        '    - ScopeGuard.cs',
        '    - Domain/NestedFixture.cs',
        '"Domain/NestedFixture.cs"',
        '"ScopeGuard.cs"',
        '"Unchanged.cs"',
        '"additional-timeout": 30000',
        '"concurrency":'
    ) -MustNotContain @(
        'SKIPPED',
        'Contoso.Infrastructure.csproj',
        '"src/Contoso.Core/Domain/NestedFixture.cs"',
        '"src/Contoso.Core/ScopeGuard.cs"',
        '"src/Contoso.Core/Unchanged.cs"'
    )

    Assert-MutationCase -Name '10b whole-project mode with two candidates names them and exits 1' -Setup {
        Set-FixtureHarnessConfig -Exclusions @{ 'Contoso.Web' = $webReason }
    } -Arguments @('-WholeProject', '-DryRun') -ExpectedExit 1 -MustContain @(
        'GATE NOT WIRED',
        'more than one candidate',
        'Contoso.Core, Contoso.Infrastructure',
        'gates.mutation.wholeProject'
    )

    Assert-MutationCase -Name '10g gates.mutation.wholeProject picks the target when two are eligible' -Setup {
        Set-FixtureHarnessConfig -Exclusions @{ 'Contoso.Web' = $webReason } -WholeProject 'Contoso.Core'
    } -Arguments @('-WholeProject', '-DryRun') -ExpectedExit 0 `
        -MustContain @('Whole-project mode: Contoso.Core.csproj') -MustNotContain @('Contoso.Infrastructure.csproj', 'more than one candidate')

    Assert-MutationCase -Name '10h gates.mutation.wholeProject naming an excluded project fails' -Setup {
        Set-FixtureHarnessConfig -Exclusions @{ 'Contoso.Infrastructure' = $infraReason } -WholeProject 'Contoso.Infrastructure'
    } -Arguments @('-WholeProject', '-DryRun') -ExpectedExit 1 `
        -MustContain @('FAILED', 'gates.mutation.exclusions lists as never mutated', $infraReason)

    Assert-MutationCase -Name '10i -Project overrides gates.mutation.wholeProject' -Setup {
        Set-FixtureHarnessConfig -Exclusions $null -WholeProject 'Contoso.Web'
    } -Arguments @('-WholeProject', '-Project', 'Contoso.Core', '-DryRun') -ExpectedExit 0 `
        -MustContain @('Whole-project mode: Contoso.Core.csproj') -MustNotContain @('Whole-project mode: Contoso.Web.csproj')

    Assert-MutationCase -Name '10c -WholeProject -Project names one candidate and mutates it alone' -Setup {
        Set-FixtureHarnessConfig -Exclusions $null
    } -Arguments @('-WholeProject', '-Project', 'Contoso.Infrastructure', '-DryRun') -ExpectedExit 0 `
        -MustContain @('Whole-project mode: Contoso.Infrastructure.csproj') -MustNotContain @('Whole-project mode: Contoso.Core')

    Assert-MutationCase -Name '10d -WholeProject naming an excluded project fails instead of overriding policy' -Setup {
        Set-FixtureHarnessConfig -Exclusions @{ 'Contoso.Infrastructure' = $infraReason }
    } -Arguments @('-WholeProject', '-Project', 'Contoso.Infrastructure', '-DryRun') -ExpectedExit 1 `
        -MustContain @('FAILED', 'gates.mutation.exclusions lists as never mutated', $infraReason)

    Assert-MutationCase -Name '10e -WholeProject naming a test project fails as no production project' -Setup {
        Set-FixtureHarnessConfig -Exclusions $null
    } -Arguments @('-WholeProject', '-Project', 'Contoso.UnitTests', '-DryRun') -ExpectedExit 1 `
        -MustContain @('FAILED', 'is not a production project')

    Assert-MutationCase -Name '10f diff-scoped mode on the same zero diff still exits 2 SKIPPED' -Setup {
        Set-FixtureHarnessConfig -Exclusions $null
    } -Arguments @('-DryRun', '-BaseRef', $script:fixtureBase) -ExpectedExit 2 -MustContain @('SKIPPED')

    $wpPassOut = Join-Path $script:work 'wp-pass-out'
    $wpPassReport = Join-Path $script:work 'wp-pass-report.json'
    Write-ScopeReport -Path $wpPassReport -FilesJson @"
    "$coreChangedFile": {
      "mutants": [
        { "id": "1", "status": "Killed", "killedBy": ["t1"], "mutatorName": "Statement", "location": { "start": { "line": 1 } } }
      ]
    },
    "src/Contoso.Core/Domain/NestedFixture.cs": {
      "mutants": [
        { "id": "2", "status": "Killed", "killedBy": ["t1"], "mutatorName": "Statement", "location": { "start": { "line": 1 } } }
      ]
    }
"@
    Assert-MutationCase -Name '11 whole-project invocation via the stub dotnet writes the report and passes' -Setup {
        Set-FixtureHarnessConfig -Exclusions @{ 'Contoso.Infrastructure' = $infraReason; 'Contoso.Web' = $webReason }
        Write-FixtureFile 'src/Contoso.Core/Domain/NestedFixture.cs' 'namespace Contoso.Core.Domain; public sealed class NestedFixture { }'
    } -Arguments @('-WholeProject', '-OutputRoot', $wpPassOut) -ExpectedExit 0 -MustContain @('PASSED', 'Mutation timing:', 'Stryker native exit for Contoso.Core.csproj: 0') `
        -Environment (New-StrykerStubEnvironment -OutputRoot $wpPassOut -ReportSource $wpPassReport)

    $script:checks++
    $timingPath = Join-Path $wpPassOut 'mutation-timing.json'
    $timingProblems = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath $timingPath)) {
        $timingProblems.Add("timing file missing at '$timingPath'")
    }
    else {
        $timing = Get-Content -LiteralPath $timingPath -Raw | ConvertFrom-Json
        if ($timing.projects.Count -ne 1) { $timingProblems.Add("expected 1 timed project, got $($timing.projects.Count)") }
        if ($timing.projects[0].totalMutants -ne 2) { $timingProblems.Add("expected 2 total mutants, got $($timing.projects[0].totalMutants)") }
        if ($timing.projects[0].tested -ne 2) { $timingProblems.Add("expected 2 tested mutants, got $($timing.projects[0].tested)") }
        if ([double]$timing.durationSeconds -lt 0) { $timingProblems.Add('total durationSeconds must not be negative') }
        if ([double]$timing.projects[0].durationSeconds -lt 0) { $timingProblems.Add('project durationSeconds must not be negative') }
        if ([int]$timing.concurrency -lt 1) { $timingProblems.Add('concurrency must be at least 1') }
        if ([int]$timing.threshold -ne 80) { $timingProblems.Add("expected threshold 80, got $($timing.threshold)") }
    }
    if ($timingProblems.Count -eq 0) {
        Write-Host '  ok       11b stub run writes mutation-timing.json with wall time and mutant counts'
    }
    else {
        $script:failures++
        Write-Host '  FAIL     11b stub run writes mutation-timing.json with wall time and mutant counts' -ForegroundColor Red
        foreach ($problem in $timingProblems) {
            Write-Host "           - $problem" -ForegroundColor Red
        }
    }

    $script:checks++
    $receiptProblems = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in @(
        @{ Line = 'Stryker native exit for Contoso.Core.csproj: 0 (12.3s wall time)'; Expected = 0 },
        @{ Line = 'Stryker native exit for Contoso.Core.csproj: 0'; Expected = 0 }
    )) {
        if ($entry.Line -match ': (-?\d+)') {
            if ([int]$Matches[1] -ne $entry.Expected) {
                $receiptProblems.Add("line '$($entry.Line)' parsed as $($Matches[1]), expected $($entry.Expected)")
            }
        }
        else {
            $receiptProblems.Add("receipt parse regex did not match '$($entry.Line)'")
        }
    }
    if ($receiptProblems.Count -eq 0) {
        Write-Host '  ok       11c receipt parse regex reads the Stryker native exit with and without the wall-time suffix'
    }
    else {
        $script:failures++
        Write-Host '  FAIL     11c receipt parse regex reads the Stryker native exit with and without the wall-time suffix' -ForegroundColor Red
        foreach ($problem in $receiptProblems) {
            Write-Host "           - $problem" -ForegroundColor Red
        }
    }

    $wpOutsideOut = Join-Path $script:work 'wp-outside-out'
    $wpOutsideReport = Join-Path $script:work 'wp-outside-report.json'
    Write-ScopeReport -Path $wpOutsideReport -FilesJson @"
    "src/Contoso.Web/Program.cs": {
      "mutants": [
        { "id": "1", "status": "Killed", "killedBy": ["t1"], "mutatorName": "Statement", "location": { "start": { "line": 1 } } }
      ]
    }
"@
    Assert-MutationCase -Name '12 a mutated file outside the whole-project changed set fails the run' -Setup {
        Set-FixtureHarnessConfig -Exclusions @{ 'Contoso.Infrastructure' = $infraReason; 'Contoso.Web' = $webReason }
    } -Arguments @('-WholeProject', '-OutputRoot', $wpOutsideOut) -ExpectedExit 1 `
        -MustContain @('outside changed files', 'src/Contoso.Web/Program.cs') `
        -Environment (New-StrykerStubEnvironment -OutputRoot $wpOutsideOut -ReportSource $wpOutsideReport)

    $wpNoneOut = Join-Path $script:work 'wp-nonetested-out'
    $wpNoneReport = Join-Path $script:work 'wp-nonetested-report.json'
    Write-ScopeReport -Path $wpNoneReport -FilesJson @"
    "$coreChangedFile": {
      "mutants": [
        { "id": "1", "status": "CompileError", "statusReason": "Mutant caused compile errors" }
      ]
    }
"@
    Assert-MutationCase -Name '13 a changed Core file with mutants but none tested fails the run' -Setup {
        Set-FixtureHarnessConfig -Exclusions @{ 'Contoso.Infrastructure' = $infraReason; 'Contoso.Web' = $webReason }
    } -Arguments @('-WholeProject', '-OutputRoot', $wpNoneOut) -ExpectedExit 1 `
        -MustContain @('none were tested', $coreChangedFile) `
        -Environment (New-StrykerStubEnvironment -OutputRoot $wpNoneOut -ReportSource $wpNoneReport)
}
catch {
    Write-Host "Mutation fixture: FAILED - $($_.Exception.Message)" -ForegroundColor Red
    $failed = $true
}
finally {
    if ($KeepWorktree) {
        Write-Host "Fixture checkout kept: $script:checkout"
    }
    else {
        Remove-Item -Recurse -Force $script:work -ErrorAction SilentlyContinue
    }
}

Write-Host ''
if ($failed -or $failures -gt 0) {
    Write-Host "$failures of $checks case invocations FAILED." -ForegroundColor Red
    exit 1
}
Write-Host "All $checks case invocations passed." -ForegroundColor Green
exit 0
