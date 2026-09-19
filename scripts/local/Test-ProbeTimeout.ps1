#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Deterministic timeout hardening test for Test-ModelProbe's tree-kill path.

.DESCRIPTION
  Creates a minimal probe-kit + local shims for the probe host binary, then
  runs Test-ModelProbe against the built-in Timeout scenario with a short
  probe wait. The hung shim sleeps for 600s; the probe wait is much shorter,
  forcing the tree-kill path and asserting the timeout exit contract.
#>

[CmdletBinding()]
param(
    [int]$ProbeWaitSeconds = 5,
    [int]$HungChildSeconds = 600,
    [string]$ProbeHost = 'claude',
    [string]$ModelName = 'timeout-test'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory)]
        [bool]$Condition,
        [Parameter(Mandatory)]
        [string]$Message
    )
    if (-not $Condition) { throw $Message }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("probe-timeout-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

$kitRoot = Join-Path $tempRoot 'probe-kit'
$tasksDir = Join-Path $kitRoot 'tasks'
New-Item -ItemType Directory -Force -Path $tasksDir | Out-Null

# The Timeout task file is only used as stdin content for some hosts.
Set-Content -LiteralPath (Join-Path $kitRoot 'README.md') -Value 'minimal probe kit for timeout test' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $tasksDir 's1-hello.txt') -Value 'timeout task input (ignored by shim)' -Encoding UTF8

$shimRoot = Join-Path $tempRoot 'shims'
New-Item -ItemType Directory -Force -Path $shimRoot | Out-Null

$shimRanMarker = Join-Path $tempRoot 'shim-ran.txt'

if ($IsWindows) {
    # `Start-Process -FilePath 'claude'` does not reliably resolve `.cmd`
    # shims. Build a real executable shim instead.
    $children = 4
    $env:PROBE_TIMEOUT_SHIM_MARKER = $shimRanMarker
    $env:PROBE_TIMEOUT_HUNG_CHILD_SECONDS = [string]$HungChildSeconds
    $env:PROBE_TIMEOUT_SHIM_CHILDREN = [string]$children
    $env:PROBE_TIMEOUT_SHIM_ROOT_LINGER_MS = [string]([int]($ProbeWaitSeconds * 1000 + 2))

    $shimProjDir = Join-Path $shimRoot 'shim-clg'
    New-Item -ItemType Directory -Force -Path $shimProjDir | Out-Null
    $csprojPath = Join-Path $shimProjDir 'claude.csproj'
    $programPath = Join-Path $shimProjDir 'Program.cs'
    Set-Content -LiteralPath $csprojPath -Value @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net8.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
  </PropertyGroup>
</Project>
'@ -Encoding UTF8

    Set-Content -LiteralPath $programPath -Value @'
using System;
using System.Diagnostics;
using System.IO;
using System.Threading;

public static class Program
{
    public static int Main(string[] args)
    {
        var marker = Environment.GetEnvironmentVariable("PROBE_TIMEOUT_SHIM_MARKER");
        if (!string.IsNullOrWhiteSpace(marker))
        {
            try { File.WriteAllText(marker, "ran"); } catch { /* best-effort */ }
        }

        int seconds = 600;
        var secondsStr = Environment.GetEnvironmentVariable("PROBE_TIMEOUT_HUNG_CHILD_SECONDS");
        if (!string.IsNullOrWhiteSpace(secondsStr) && int.TryParse(secondsStr, out var parsedSeconds))
            seconds = parsedSeconds;

        int children = 12;
        var childrenStr = Environment.GetEnvironmentVariable("PROBE_TIMEOUT_SHIM_CHILDREN");
        if (!string.IsNullOrWhiteSpace(childrenStr) && int.TryParse(childrenStr, out var parsedChildren))
            children = parsedChildren;

        var sw = System.Diagnostics.Stopwatch.StartNew();

        for (int i = 0; i < children; i++)
        {
            try
            {
                var psi = new ProcessStartInfo
                {
                    FileName = "pwsh",
                    Arguments = $"-NoProfile -Command \"Start-Sleep -Seconds {seconds}\"",
                    UseShellExecute = false,
                    CreateNoWindow = true
                };
                Process.Start(psi);
            }
            catch { /* best-effort */ }
        }

        int lingerMs = 5200;
        var lingerStr = Environment.GetEnvironmentVariable("PROBE_TIMEOUT_SHIM_ROOT_LINGER_MS");
        if (!string.IsNullOrWhiteSpace(lingerStr) && int.TryParse(lingerStr, out var parsedLingerMs))
            lingerMs = parsedLingerMs;

        while (sw.ElapsedMilliseconds < lingerMs)
        {
            Thread.SpinWait(64);
        }
        return 0;
    }
}
'@ -Encoding UTF8

    # Build to a dedicated temp output, then copy to shimRoot as `claude`.
    & dotnet build $csprojPath -c Release -v:q *> $null
    $builtExe = Get-ChildItem -LiteralPath $shimProjDir -Recurse -File -Filter 'claude.exe' |
        Sort-Object FullName |
        Select-Object -First 1
    if (-not $builtExe) { throw 'Failed to build claude.exe shim.' }

    $builtDir = Split-Path -Parent $builtExe.FullName
    # Copy the full framework-dependent bundle so the `claude.exe` host stub can
    # locate `claude.dll` and its deps/runtime config.
    Copy-Item -Path (Join-Path $builtDir 'claude.*') -Destination $shimRoot -Force

    Assert-True (Test-Path -LiteralPath (Join-Path $shimRoot 'claude.exe')) 'Expected shimRoot/claude.exe to exist.'
    Assert-True (Test-Path -LiteralPath (Join-Path $shimRoot 'claude.dll')) 'Expected shimRoot/claude.dll to exist.'

    # Smoke-test the shim itself so we fail fast if env var plumbing or runtime
    # resolution is broken. Keep it short to avoid slowing the real timeout test.
    $smokePath = Join-Path $shimRoot 'claude.exe'
    Remove-Item -LiteralPath $shimRanMarker -Force -ErrorAction SilentlyContinue
    $env:PROBE_TIMEOUT_HUNG_CHILD_SECONDS = '1'
    $env:PROBE_TIMEOUT_SHIM_CHILDREN = '0'
    $env:PROBE_TIMEOUT_SHIM_ROOT_LINGER_MS = '50'
    Start-Process -FilePath $smokePath -NoNewWindow -Wait | Out-Null
    Assert-True (Test-Path -LiteralPath $shimRanMarker) 'Shim smoke-test failed to write the marker.'

    Remove-Item -LiteralPath $shimRanMarker -Force -ErrorAction SilentlyContinue
    $env:PROBE_TIMEOUT_HUNG_CHILD_SECONDS = [string]$HungChildSeconds
    $env:PROBE_TIMEOUT_SHIM_CHILDREN = [string]$children
    $env:PROBE_TIMEOUT_SHIM_ROOT_LINGER_MS = [string]([int]($ProbeWaitSeconds * 1000 + 2))
}
else {
    # On Unix we ignore TERM so the tree-kill timeout path observes a
    # still-alive root PID (Survived=true).
    $claudePath = Join-Path $shimRoot 'claude'
    $script = @(
        '#!/usr/bin/env bash',
        'trap "" TERM',
        'trap "" INT',
        "echo ran > '$shimRanMarker'",
        "sleep $HungChildSeconds"
    ) -join "`n"
    Set-Content -LiteralPath $claudePath -Value $script -Encoding ASCII
    & chmod +x $claudePath | Out-Null
}

if ($IsWindows) {
    $env:PATH = $shimRoot + ';' + $env:PATH
}
else {
    $env:PATH = $shimRoot + ':' + $env:PATH
}

$env:PROBE_KIT_ROOT = $kitRoot
$env:PROBE_TIMEOUT_SECONDS = [string]$ProbeWaitSeconds

$resolvedClaude = Get-Command -Name 'claude' -ErrorAction SilentlyContinue
$resolvedClaudeSource = if ($resolvedClaude) { [string]$resolvedClaude.Source } else { '<unresolved>' }

$testModelProbe = Join-Path $PSScriptRoot 'Test-ModelProbe.ps1'
$stdoutPath = Join-Path $tempRoot 'stdout.txt'
$stderrPath = Join-Path $tempRoot 'stderr.txt'
Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue

$args = @(
    '-NoProfile',
    '-File', $testModelProbe,
    '-Host', $ProbeHost,
    '-Model', $ModelName,
    '-Test', 'Timeout'
)

$p = Start-Process -FilePath 'pwsh' -ArgumentList $args `
    -NoNewWindow -Wait -PassThru `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath

$exitCode = $p.ExitCode
$stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue } else { '' }
$stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue } else { '' }
$stdout = [string]$stdout
$stderr = [string]$stderr

$shimRan = Test-Path -LiteralPath $shimRanMarker
Assert-True $shimRan "Shim did not run (missing $shimRanMarker). Get-Command claude => $resolvedClaudeSource. stdout=`n$stdout`nstderr=`n$stderr"

Assert-True ($exitCode -eq 1) "Expected Test-ModelProbe exit code 1, got $exitCode. stdout=`n$stdout`nstderr=`n$stderr"

$combined = $stdout + "`n" + $stderr
$orphanPid = $null
$json = $null

# stdout must stay either empty or parseable JSON (scout mode).
$trim = $stdout.Trim()
if (-not [string]::IsNullOrWhiteSpace($trim)) {
    try {
        $jsonText = $null
        # PowerShell warnings can prefix stdout; keep contract by extracting the trailing JSON.
        if ($trim -match '(?s)\{.*\}\s*$') {
            $jsonText = $matches[0]
        }
        else {
            $jsonText = $trim
        }

        $json = $jsonText | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Expected stdout to contain parseable JSON (or only warnings + parseable trailing JSON), but it was not. stdout=`n$stdout"
    }
    # The probe result contract should include at least exitCode and metadata.
    Assert-True ($null -ne $json.exitCode) 'stdout JSON missing exitCode.'
    Assert-True ($null -ne $json.metadata) 'stdout JSON missing metadata.'
}

# Orphan PID contract: prefer the probed processGroupId from metadata (never 0).
$expectedPid = $null
if ($null -ne $json -and $null -ne $json.metadata -and $null -ne $json.metadata.processGroupId) {
    $expectedPid = [int]$json.metadata.processGroupId
}

if ($null -ne $expectedPid -and $expectedPid -gt 0) {
    $pidRe = "(?i)(?:orphan PID\s+|\bPID\s+)$expectedPid\b"
    Assert-True ($combined -match $pidRe) "Expected output to contain orphan PID=$expectedPid. exitCode=$exitCode stdout=`n$stdout`nstderr=`n$stderr"
    $orphanPid = $expectedPid
}
else {
    # Fallback: older/benign timeout races may surface PID in a kill warning.
    $m = [regex]::Match($combined, '(?i)orphan PID\\s+(\\d+)')
    if (-not $m.Success) {
        $m = [regex]::Match($combined, '(?i)\\bPID\\s+(\\d+)\\b')
    }
    Assert-True ($m.Success) "Expected output to contain a non-zero PID for orphan detection. exitCode=$exitCode"
    $orphanPid = [int]$m.Groups[1].Value
    Assert-True ($orphanPid -gt 0) "Expected orphan PID to be non-zero, got $orphanPid."
}

# Cleanup: avoid leaving a 600s sleep in place.
if ($orphanPid -gt 0) {
    if ($IsWindows) {
        Stop-Process -Id $orphanPid -Force -ErrorAction SilentlyContinue | Out-Null
    }
    else {
        & kill -9 $orphanPid 2>$null | Out-Null
    }
}

Write-Host "Test-ProbeTimeout passed (exit=1, orphanPid=$orphanPid)."
exit 0

