#!/usr/bin/env pwsh
#
# Batch behavior self-test for format-on-edit.
#
#   pwsh ./hooks/Test-FormatOnEditBatch.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$hookPath = Join-Path $PSScriptRoot 'format-on-edit.ps1'

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Write-Host 'SKIP: dotnet SDK not installed'
    exit 0
}

function Invoke-FormatOnEditHook {
    param(
        [Parameter(Mandatory = $true)] [string] $Cwd,
        [string] $CommandText,
        [Parameter(Mandatory = $true)] [string] $StderrPath
    )
    if ($null -eq $CommandText) { throw 'CommandText cannot be null' }

    $payload = @{
        cwd       = $Cwd
        tool_name = 'Bash'
        tool_input = @{
            command = $CommandText
        }
    }
    $json = $payload | ConvertTo-Json -Compress -Depth 8

    $stdout = @($json | & pwsh -NoProfile -ExecutionPolicy Bypass -File $hookPath 2>$StderrPath)
    $exitCode = $LASTEXITCODE

    $stderrText = ''
    if (Test-Path -LiteralPath $StderrPath) {
        $stderrText = (Get-Content -LiteralPath $StderrPath -Raw -ErrorAction SilentlyContinue)
    }

    if (Test-Path -LiteralPath $StderrPath) {
        Remove-Item -LiteralPath $StderrPath -Force -ErrorAction SilentlyContinue
    }

    if ($null -eq $stderrText) { $stderrText = '' }

    return [PSCustomObject]@{
        ExitCode = $exitCode
        StdOut   = ($stdout -join [Environment]::NewLine).Trim()
        StdErr   = $stderrText.Trim()
    }
}

function Read-DotnetSpyLog {
    param([Parameter(Mandatory = $true)] [string] $LogFile)

    if (-not (Test-Path -LiteralPath $LogFile)) { return @() }
    $lines = Get-Content -LiteralPath $LogFile -ErrorAction SilentlyContinue
    if (-not $lines) { return @() }

    $entries = @()
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $entries += ($line | ConvertFrom-Json)
    }
    return $entries
}

function Get-DotnetFormatCalls {
    param([Parameter(Mandatory = $true)] [string] $LogFile)

    $entries = Read-DotnetSpyLog $LogFile
    $format = @()
    foreach ($e in $entries) {
        if (-not $e.argv) { continue }
        if ($e.argv.Count -gt 0 -and $e.argv[0] -eq 'format') {
            $format += $e
        }
    }
    return @($format)
}

function Extract-DotnetFormatProject {
    param(
        [Parameter(Mandatory = $true)] [object] $Call
    )
    $args = $Call.argv
    if ($args.Count -lt 2) { return $null }
    return $args[1]
}

function Extract-IncludesAfterIncludeFlag {
    param(
        [Parameter(Mandatory = $true)] [string[]] $Argv
    )

    $i = 0
    while ($i -lt $Argv.Count -and $Argv[$i] -ne '--include') { $i++ }
    if ($i -ge $Argv.Count) { return @() }

    $includes = [System.Collections.Generic.List[string]]::new()
    $j = $i + 1
    while ($j -lt $Argv.Count -and -not $Argv[$j].StartsWith('--')) {
        $null = $includes.Add($Argv[$j])
        $j++
    }
    return @($includes.ToArray())
}

function Create-DotnetSpyShim {
    param([Parameter(Mandatory = $true)] [string] $LogFile)

    $shimDir = Join-Path ([System.IO.Path]::GetTempPath()) ('format-on-edit-dotnet-spy-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $shimDir | Out-Null

    if ($IsWindows) {
        $shimPath = Join-Path $shimDir 'dotnet.ps1'
        $shimContent = @'
param([Parameter(ValueFromRemainingArguments=$true)] [string[]] $Args)

$argvOut = @($Args)
try {
    $projPath = $Args[1]
    $projDir = Split-Path -Parent $projPath
    $incIdx = -1
    for ($k = 0; $k -lt $Args.Count; $k++) {
        if ($Args[$k] -eq '--include') { $incIdx = $k; break }
    }
    if ($incIdx -ge 0 -and ($incIdx + 1) -lt $Args.Count) {
        $k = $incIdx + 1
        while ($k -lt $Args.Count -and -not $Args[$k].StartsWith('--')) {
            if (-not [System.IO.Path]::IsPathRooted($Args[$k])) {
                $argvOut[$k] = [System.IO.Path]::Combine($projDir, $Args[$k])
            }
            $k++
        }
    }
} catch { }
$record = @{ argv = @($argvOut) } | ConvertTo-Json -Compress -Depth 5
Add-Content -LiteralPath '__LOGFILE__' -Value $record

$real = Get-Command -CommandType Application dotnet -ErrorAction SilentlyContinue | Select-Object -Skip 1 -First 1
if (-not $real) {
    $real = Get-Command -CommandType Application dotnet -ErrorAction SilentlyContinue | Select-Object -First 1
}
if (-not $real) { exit 0 }

& $real.Source @Args
exit $LASTEXITCODE
'@
        $shimContent = $shimContent.Replace('__LOGFILE__', $LogFile)
        Set-Content -LiteralPath $shimPath -Value $shimContent -Encoding UTF8 -NoNewline
    } else {
        $shimPath = Join-Path $shimDir 'dotnet'
        $shimContent = @'
#!/usr/bin/env pwsh
param([Parameter(ValueFromRemainingArguments=$true)] [string[]] $Args)

$argvOut = @($Args)
try {
    $projPath = $Args[1]
    $projDir = Split-Path -Parent $projPath
    $incIdx = -1
    for ($k = 0; $k -lt $Args.Count; $k++) {
        if ($Args[$k] -eq '--include') { $incIdx = $k; break }
    }
    if ($incIdx -ge 0 -and ($incIdx + 1) -lt $Args.Count) {
        $k = $incIdx + 1
        while ($k -lt $Args.Count -and -not $Args[$k].StartsWith('--')) {
            if (-not [System.IO.Path]::IsPathRooted($Args[$k])) {
                $argvOut[$k] = [System.IO.Path]::Combine($projDir, $Args[$k])
            }
            $k++
        }
    }
} catch { }
$record = @{ argv = @($argvOut) } | ConvertTo-Json -Compress -Depth 5
Add-Content -LiteralPath '__LOGFILE__' -Value $record

$real = Get-Command -CommandType Application dotnet -ErrorAction SilentlyContinue | Select-Object -Skip 1 -First 1
if (-not $real) {
    $real = Get-Command -CommandType Application dotnet -ErrorAction SilentlyContinue | Select-Object -First 1
}
if (-not $real) { exit 0 }

& $real.Source @Args
exit $LASTEXITCODE
'@
        $shimContent = $shimContent.Replace('__LOGFILE__', $LogFile)
        Set-Content -LiteralPath $shimPath -Value $shimContent -Encoding UTF8 -NoNewline
        & chmod +x $shimPath | Out-Null
    }

    return $shimDir
}

function Clear-LogFile {
    param([Parameter(Mandatory = $true)] [string] $LogFile)
    if (Test-Path -LiteralPath $LogFile) {
        Remove-Item -LiteralPath $LogFile -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType File -Force -Path $LogFile | Out-Null
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('format-on-edit-batch-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Force -Path $tempRoot

$fixtureBase = Join-Path $tempRoot 'fixture'
$seqRoot = Join-Path $tempRoot 'seq'
$batchRoot = Join-Path $tempRoot 'batch'

$shimDir = $null
$logFile = Join-Path $tempRoot 'dotnet-spy-log.jsonl'
$success = $false

try {
    $null = New-Item -ItemType Directory -Force -Path $fixtureBase

    # Projects (10 .cs each).
    $projARoot = Join-Path $fixtureBase 'ProjectA'
    $projBRoot = Join-Path $fixtureBase 'ProjectB'
    $orphanRoot = Join-Path $fixtureBase 'Orphan'
    $null = New-Item -ItemType Directory -Force -Path $projARoot
    $null = New-Item -ItemType Directory -Force -Path $projBRoot
    $null = New-Item -ItemType Directory -Force -Path $orphanRoot

    Set-Content -LiteralPath (Join-Path $projARoot 'ProjectA.csproj') -Value @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <ImplicitUsings>disable</ImplicitUsings>
    <Nullable>enable</Nullable>
  </PropertyGroup>
</Project>
"@ -Encoding UTF8

    Set-Content -LiteralPath (Join-Path $projBRoot 'ProjectB.csproj') -Value @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <ImplicitUsings>disable</ImplicitUsings>
    <Nullable>enable</Nullable>
  </PropertyGroup>
</Project>
"@ -Encoding UTF8

    # ProjectA cs files: File1..File8 + File With Space + File9 (File10 omitted intentionally).
    for ($i = 1; $i -le 9; $i++) {
        $name = if ($i -eq 9) { 'File9.cs' } else { ('File' + $i + '.cs') }
        $className = if ($i -eq 9) { 'File9' } else { 'File' + $i }
        $path = Join-Path $projARoot $name
        Set-Content -LiteralPath $path -Value @"
namespace ProjectA;public class $className{public int X{get;set;}= $i;public $className(){ }}
"@ -Encoding UTF8
    }
    Set-Content -LiteralPath (Join-Path $projARoot 'File With Space.cs') -Value @"
namespace ProjectA;public class FileWithSpace{public int X{get;set;}= 99;public FileWithSpace(){ }}
"@ -Encoding UTF8

    # ProjectB cs files: File1..File10
    for ($i = 1; $i -le 10; $i++) {
        $path = Join-Path $projBRoot ('File' + $i + '.cs')
        Set-Content -LiteralPath $path -Value @"
namespace ProjectB;public class File$i{public int X{get;set;}= $i;public File$i(){ }}
"@ -Encoding UTF8
    }

    Set-Content -LiteralPath (Join-Path $fixtureBase 'README.md') -Value "readme"
    Set-Content -LiteralPath (Join-Path $orphanRoot 'Orphan.cs') -Value @"
namespace Orphan;public class Orphan{public int X{get;set;}}
"@ -Encoding UTF8

    # Payload: 20-file batch across both projects, includes duplicates and spaces.
    $payloadRel = @(
        (Join-Path 'ProjectA' 'File1.cs'),
        (Join-Path 'ProjectA' 'File1.cs'),
        (Join-Path 'ProjectA' 'File2.cs'),
        (Join-Path 'ProjectA' 'File3.cs'),
        (Join-Path 'ProjectA' 'File4.cs'),
        (Join-Path 'ProjectA' 'File5.cs'),
        (Join-Path 'ProjectA' 'File6.cs'),
        (Join-Path 'ProjectA' 'File7.cs'),
        (Join-Path 'ProjectA' 'File8.cs'),
        (Join-Path 'ProjectA' 'File With Space.cs'),

        (Join-Path 'ProjectB' 'File1.cs'),
        (Join-Path 'ProjectB' 'File2.cs'),
        (Join-Path 'ProjectB' 'File3.cs'),
        (Join-Path 'ProjectB' 'File4.cs'),
        (Join-Path 'ProjectB' 'File5.cs'),
        (Join-Path 'ProjectB' 'File6.cs'),
        (Join-Path 'ProjectB' 'File7.cs'),
        (Join-Path 'ProjectB' 'File8.cs'),
        (Join-Path 'ProjectB' 'File9.cs'),
        (Join-Path 'ProjectB' 'File10.cs')
    )

    # --- capture pre-format hashes for equivalence proof (B1) ---------------
    $preFormatHashes = @{}
    foreach ($rel in ($payloadRel | Select-Object -Unique)) {
        $srcFile = Join-Path $fixtureBase $rel
        $preFormatHashes[$rel] = (Get-FileHash -LiteralPath $srcFile -Algorithm SHA256).Hash
    }

    $null = Clear-LogFile $logFile
    $shimDir = Create-DotnetSpyShim -LogFile $logFile

    $oldPath = $env:PATH
    $sep = if ($IsWindows) { ';' } else { ':' }
    $env:PATH = $shimDir + $sep + $env:PATH
    $env:FORMAT_ON_EDIT_DOTNET_SEAM = '1'

    # --- sequential baseline (20 hook invocations) ------------------------
    $null = Remove-Item -LiteralPath $logFile -Force -ErrorAction SilentlyContinue
    $null = Clear-LogFile $logFile

    # Probe: ensure child pwsh can see the dotnet shim on PATH.
    $probe = & pwsh -NoProfile -ExecutionPolicy Bypass -Command 'dotnet --version' 1>$null 2>$null
    $probeLines = @()
    if (Test-Path -LiteralPath $logFile) { $probeLines = @(Get-Content -LiteralPath $logFile -ErrorAction SilentlyContinue) }
    if ($probeLines.Count -lt 1) { throw 'dotnet spy shim probe failed (no shim log entries)' }
    $null = Clear-LogFile $logFile

    $seqTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $hookInvocationCount = 0
    Copy-Item -Path $fixtureBase -Destination $seqRoot -Recurse -Force

    foreach ($rel in $payloadRel) {
        $abs = Join-Path $seqRoot $rel
        $command = ('*** Update File: ' + $abs)
        $stderrPath = Join-Path $tempRoot ('stderr-seq-' + [guid]::NewGuid().ToString('N') + '.txt')
        $res = Invoke-FormatOnEditHook -Cwd $seqRoot -CommandText $command -StderrPath $stderrPath
        $hookInvocationCount++

        if ($res.ExitCode -ne 0) { throw "hook exit code $($res.ExitCode) on sequential payload" }
        if ($res.StdOut -ne '') { throw "hook wrote stdout during sequential payload" }
    }
    $seqTimer.Stop() | Out-Null

    $seqFormatCalls = @(Get-DotnetFormatCalls -LogFile $logFile)
    $seqProcesses = $seqFormatCalls.Count
    if ($seqProcesses -ne 20) { throw "Expected 20 dotnet format processes in sequential baseline, got $seqProcesses" }

    # --- batch (1 hook invocation) --------------------------------------
    Copy-Item -Path $fixtureBase -Destination $batchRoot -Recurse -Force

    $null = Remove-Item -LiteralPath $logFile -Force -ErrorAction SilentlyContinue
    $null = Clear-LogFile $logFile

    $batchTimer = [System.Diagnostics.Stopwatch]::StartNew()

    $batchCommand = ($payloadRel | ForEach-Object { '*** Update File: ' + (Join-Path $batchRoot $_) }) -join "`n"
    $stderrPath = Join-Path $tempRoot ('stderr-batch-' + [guid]::NewGuid().ToString('N') + '.txt')
    $batchRes = Invoke-FormatOnEditHook -Cwd $batchRoot -CommandText $batchCommand -StderrPath $stderrPath

    if ($batchRes.ExitCode -ne 0) { throw "hook exit code $($batchRes.ExitCode) on batch payload" }
    if ($batchRes.StdOut -ne '') { throw "hook wrote stdout during batch payload" }

    $batchTimer.Stop() | Out-Null

    $batchFormatCalls = @(Get-DotnetFormatCalls -LogFile $logFile)
    $batchProcesses = $batchFormatCalls.Count
    if ($batchProcesses -ne 2) { throw "Expected 2 dotnet format processes in batch payload, got $batchProcesses" }

    $projects = @()
    foreach ($c in $batchFormatCalls) { $projects += Extract-DotnetFormatProject -Call $c }
    $uniqueProjects = $projects | Select-Object -Unique
    if ($uniqueProjects.Count -ne 2) { throw "Expected 2 projects formatted in batch payload" }

    # --- A4: assert batch --include values per project ---------------------
    $projACsproj = Join-Path (Join-Path $batchRoot 'ProjectA') 'ProjectA.csproj'
    $projBCsproj = Join-Path (Join-Path $batchRoot 'ProjectB') 'ProjectB.csproj'

    foreach ($call in $batchFormatCalls) {
        $proj = Extract-DotnetFormatProject -Call $call
        $includes = Extract-IncludesAfterIncludeFlag -Argv $call.argv

        if ($proj -eq $projACsproj) {
            $expectedA = @(
                (Join-Path (Join-Path $batchRoot 'ProjectA') 'File1.cs'),
                (Join-Path (Join-Path $batchRoot 'ProjectA') 'File2.cs'),
                (Join-Path (Join-Path $batchRoot 'ProjectA') 'File3.cs'),
                (Join-Path (Join-Path $batchRoot 'ProjectA') 'File4.cs'),
                (Join-Path (Join-Path $batchRoot 'ProjectA') 'File5.cs'),
                (Join-Path (Join-Path $batchRoot 'ProjectA') 'File6.cs'),
                (Join-Path (Join-Path $batchRoot 'ProjectA') 'File7.cs'),
                (Join-Path (Join-Path $batchRoot 'ProjectA') 'File8.cs'),
                (Join-Path (Join-Path $batchRoot 'ProjectA') 'File With Space.cs')
            ) | Sort-Object
            $actualA = @($includes) | Sort-Object
            $diffA = Compare-Object -ReferenceObject $expectedA -DifferenceObject $actualA
            if ($diffA) { throw "A4: ProjectA --include mismatch" }
        }
        elseif ($proj -eq $projBCsproj) {
            $expectedB = @(
                (Join-Path (Join-Path $batchRoot 'ProjectB') 'File1.cs'),
                (Join-Path (Join-Path $batchRoot 'ProjectB') 'File2.cs'),
                (Join-Path (Join-Path $batchRoot 'ProjectB') 'File3.cs'),
                (Join-Path (Join-Path $batchRoot 'ProjectB') 'File4.cs'),
                (Join-Path (Join-Path $batchRoot 'ProjectB') 'File5.cs'),
                (Join-Path (Join-Path $batchRoot 'ProjectB') 'File6.cs'),
                (Join-Path (Join-Path $batchRoot 'ProjectB') 'File7.cs'),
                (Join-Path (Join-Path $batchRoot 'ProjectB') 'File8.cs'),
                (Join-Path (Join-Path $batchRoot 'ProjectB') 'File9.cs'),
                (Join-Path (Join-Path $batchRoot 'ProjectB') 'File10.cs')
            ) | Sort-Object
            $actualB = @($includes) | Sort-Object
            $diffB = Compare-Object -ReferenceObject $expectedB -DifferenceObject $actualB
            if ($diffB) { throw "A4: ProjectB --include mismatch" }
        }
    }

    # Assert File9.cs in ProjectA was NOT in batch payload and remains untouched
    $file9Rel = Join-Path 'ProjectA' 'File9.cs'
    $file9Batch = Join-Path $batchRoot $file9Rel
    $file9Fixture = Join-Path $fixtureBase $file9Rel
    $file9BatchHash = (Get-FileHash -LiteralPath $file9Batch -Algorithm SHA256).Hash
    $file9FixtureHash = (Get-FileHash -LiteralPath $file9Fixture -Algorithm SHA256).Hash
    if ($file9BatchHash -ne $file9FixtureHash) {
        throw "A4: ProjectA/File9.cs was modified but was not in payload"
    }

    # --- required stdout literals (frozen-plan exactness) -----------------
    Write-Host ("Sequential: {0} invocations, {1} processes" -f $hookInvocationCount, $seqProcesses)
    Write-Host ("Batch: 1 invocation, {0} processes" -f $batchProcesses)

    Write-Host ("Sequential elapsed: {0:F0} ms" -f $seqTimer.Elapsed.TotalMilliseconds)
    Write-Host ("Batch elapsed: {0:F0} ms" -f $batchTimer.Elapsed.TotalMilliseconds)

    # --- formatting equivalence vs sequential baseline -------------------
    $uniquePayloadRel = $payloadRel | Select-Object -Unique
    foreach ($rel in $uniquePayloadRel) {
        $seqFile = Join-Path $seqRoot $rel
        $batchFile = Join-Path $batchRoot $rel

        $seqHash = (Get-FileHash -LiteralPath $seqFile -Algorithm SHA256).Hash
        $batchHash = (Get-FileHash -LiteralPath $batchFile -Algorithm SHA256).Hash
        if ($seqHash -ne $batchHash) {
            throw "Formatting mismatch for $rel"
        }
    }

    # --- B1: assert formatting actually happened (not vacuous) ---------------
    $formattedCount = 0
    foreach ($rel in ($payloadRel | Select-Object -Unique)) {
        $batchFile = Join-Path $batchRoot $rel
        $postHash = (Get-FileHash -LiteralPath $batchFile -Algorithm SHA256).Hash
        if ($postHash -ne $preFormatHashes[$rel]) {
            $formattedCount++
        }
    }
    if ($formattedCount -eq 0) {
        throw "B1: Formatting vacuity — no fixture file changed. dotnet format may be a no-op."
    }
    Write-Host "B1: Formatting verified — $formattedCount of $($preFormatHashes.Count) files changed by formatter"

    # --- A6: single-project 20-file batch (AC1 literal) --------------------
    $singleProjRoot = Join-Path $tempRoot 'single-proj'
    Copy-Item -Path $fixtureBase -Destination $singleProjRoot -Recurse -Force

    # Build 20-file payload targeting only ProjectA (reuse File1-8, File With Space, File9 = 10 files)
    # For 20 files, add 10 more entries (with duplicates allowed, will dedupe to 10 unique).
    $singleProjPayload = @()
    for ($i = 1; $i -le 10; $i++) {
        $name = switch ($i) {
            9 { 'File9.cs' }
            10 { 'File With Space.cs' }
            default { "File$i.cs" }
        }
        $singleProjPayload += (Join-Path 'ProjectA' $name)
    }
    # Duplicate to reach 20 entries
    $singleProjPayload += $singleProjPayload

    $null = Remove-Item -LiteralPath $logFile -Force -ErrorAction SilentlyContinue
    $null = Clear-LogFile $logFile

    $singleProjCmd = ($singleProjPayload | ForEach-Object { '*** Update File: ' + (Join-Path $singleProjRoot $_) }) -join "`n"
    $stderrPath = Join-Path $tempRoot ('stderr-single-proj-' + [guid]::NewGuid().ToString('N') + '.txt')
    $singleProjRes = Invoke-FormatOnEditHook -Cwd $singleProjRoot -CommandText $singleProjCmd -StderrPath $stderrPath

    if ($singleProjRes.ExitCode -ne 0) { throw "A6: hook exit code $($singleProjRes.ExitCode) on single-project 20-file payload" }

    $singleProjCalls = @(Get-DotnetFormatCalls -LogFile $logFile)
    if ($singleProjCalls.Count -ne 1) {
        throw "A6: Expected exactly 1 dotnet format call for single-project 20-file batch, got $($singleProjCalls.Count)"
    }
    Write-Host "A6: Single-project 20-file batch verified — 1 dotnet format call"

    # --- edge: empty payload ---------------------------------------------
    $null = Remove-Item -LiteralPath $logFile -Force -ErrorAction SilentlyContinue
    $null = Clear-LogFile $logFile
    $stderrPath = Join-Path $tempRoot ('stderr-empty-' + [guid]::NewGuid().ToString('N') + '.txt')
    $emptyRes = Invoke-FormatOnEditHook -Cwd $batchRoot -CommandText '' -StderrPath $stderrPath
    if ($emptyRes.ExitCode -ne 0) { throw "hook exit code $($emptyRes.ExitCode) on empty payload" }
    if ($emptyRes.StdOut -ne '') { throw "hook wrote stdout during empty payload" }
    $emptyCalls = @(Get-DotnetFormatCalls -LogFile $logFile)
    if ($emptyCalls.Count -ne 0) { throw "Expected 0 dotnet format calls for empty payload" }

    # --- edge: orphan .cs (no resolvable .csproj) -----------------------
    $null = Remove-Item -LiteralPath $logFile -Force -ErrorAction SilentlyContinue
    $null = Clear-LogFile $logFile
    $orphanAbs = Join-Path (Join-Path $batchRoot 'Orphan') 'Orphan.cs'
    $stderrPath = Join-Path $tempRoot ('stderr-orphan-' + [guid]::NewGuid().ToString('N') + '.txt')
    $orphanRes = Invoke-FormatOnEditHook -Cwd $batchRoot -CommandText ('*** Update File: ' + $orphanAbs) -StderrPath $stderrPath
    if ($orphanRes.ExitCode -ne 0) { throw "hook exit code $($orphanRes.ExitCode) on orphan payload" }
    if ($orphanRes.StdOut -ne '') { throw "hook wrote stdout during orphan payload" }
    $orphanCalls = @(Get-DotnetFormatCalls -LogFile $logFile)
    if ($orphanCalls.Count -ne 0) { throw "Expected 0 dotnet format calls for orphan payload" }

    # --- edge: single file includes parsing (with spaces) --------------
    $null = Remove-Item -LiteralPath $logFile -Force -ErrorAction SilentlyContinue
    $null = Clear-LogFile $logFile
    $spaceRel = Join-Path 'ProjectA' 'File With Space.cs'
    $spaceAbs = Join-Path $batchRoot $spaceRel
    $stderrPath = Join-Path $tempRoot ('stderr-single-' + [guid]::NewGuid().ToString('N') + '.txt')
    $singleRes = Invoke-FormatOnEditHook -Cwd $batchRoot -CommandText ('*** Update File: ' + $spaceAbs) -StderrPath $stderrPath
    if ($singleRes.ExitCode -ne 0) { throw "hook exit code $($singleRes.ExitCode) on single-file payload" }
    if ($singleRes.StdOut -ne '') { throw "hook wrote stdout during single-file payload" }

    $singleCalls = @(Get-DotnetFormatCalls -LogFile $logFile)
    if ($singleCalls.Count -ne 1) { throw "Expected 1 dotnet format call for single-file payload" }

    $argv = $singleCalls[0].argv
    $includes = Extract-IncludesAfterIncludeFlag -Argv $argv
    $includeArr = @($includes)
    if ($includeArr.Count -ne 1) { throw "Expected exactly 1 --include value, got $($includeArr.Count)" }
    if ($includeArr[0] -ne $spaceAbs) { throw "Single-file include did not match expected path (spaces case)" }

    # --- edge: non-.cs and nonexistent paths are ignored --------------
    $null = Remove-Item -LiteralPath $logFile -Force -ErrorAction SilentlyContinue
    $null = Clear-LogFile $logFile
    $readmeAbs = Join-Path $batchRoot 'README.md'
    $missingAbs = Join-Path (Join-Path $batchRoot 'ProjectA') 'DoesNotExist.cs'
    $stderrPath = Join-Path $tempRoot ('stderr-mixed-' + [guid]::NewGuid().ToString('N') + '.txt')
    $mixedCmd = @(
        ('*** Update File: ' + $readmeAbs),
        ('*** Update File: ' + $missingAbs)
    ) -join "`n"
    $mixedRes = Invoke-FormatOnEditHook -Cwd $batchRoot -CommandText $mixedCmd -StderrPath $stderrPath
    if ($mixedRes.ExitCode -ne 0) { throw "hook exit code $($mixedRes.ExitCode) on mixed payload" }
    if ($mixedRes.StdOut -ne '') { throw "hook wrote stdout during mixed payload" }
    $mixedCalls = @(Get-DotnetFormatCalls -LogFile $logFile)
    if ($mixedCalls.Count -ne 0) { throw "Expected 0 dotnet format calls for non-.cs/nonexistent payload" }

    $success = $true
} finally {
    if ($env:PATH -and $shimDir) {
        $env:PATH = $oldPath
    }
    $env:FORMAT_ON_EDIT_DOTNET_SEAM = $null
    if ($shimDir -and (Test-Path -LiteralPath $shimDir)) {
        if ($success) {
            Remove-Item -LiteralPath $shimDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if ($success) {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not $success) {
        Write-Host "DEBUG: preserved tempRoot at $tempRoot"
    }
}

exit 0
