#!/usr/bin/env pwsh
<#
  PostToolUse hook: after a .cs write, remind that the gates are pending.

  The gates only help if they are actually run. The failure mode this addresses
  is an agent editing fifteen files and then declaring success, having run
  nothing - the gates were available the whole time and simply never invoked.

  Deliberately quiet:
    - fires only on .cs writes outside bin/obj
    - at most once every 10 minutes per repo, tracked in a temp stamp file
    - exits 2 so the message reaches the agent, but the edit is already applied
      (PostToolUse), so this is a nudge, not a block

  It does NOT run the gates. Running a build on every keystroke would be slower
  than the work itself; the agent decides when to spend that time.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'

$IntervalMinutes = 10

$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

try { $payload = ConvertFrom-Json -InputObject $raw } catch { exit 0 }
if (-not $payload) { exit 0 }

function Get-Prop {
    param($Object, [string[]]$Names)
    if (-not $Object) { return $null }
    $available = @($Object.PSObject.Properties.Name)
    foreach ($name in $Names) {
        if ($available -contains $name) { return $Object.$name }
    }
    return $null
}

$toolInput = Get-Prop $payload @('tool_input', 'toolInput', 'input', 'arguments')
$file = Get-Prop $toolInput @('file_path', 'filePath', 'path', 'target_file')

if ([string]::IsNullOrWhiteSpace($file)) { exit 0 }
if ([System.IO.Path]::GetExtension($file) -ne '.cs') { exit 0 }

$normalized = $file -replace '\\', '/'
if ($normalized -match '/(bin|obj|node_modules)/') { exit 0 }

# Tests are exercised by `dotnet test`; the analyzer gates target production code.
if ($normalized -match '/tests?/' -or $normalized -match '\.Tests?\.cs$') { exit 0 }

# Throttle per repository so a multi-file edit produces one nudge, not twenty.
$repo = (git -C (Split-Path -LiteralPath $file -Parent) rev-parse --show-toplevel 2>$null)
if (-not $repo) { $repo = Split-Path -LiteralPath $file -Parent }
$key = [System.BitConverter]::ToString(
    [System.Security.Cryptography.MD5]::HashData([System.Text.Encoding]::UTF8.GetBytes("$repo"))
).Replace('-', '').Substring(0, 12)

$stamp = Join-Path ([System.IO.Path]::GetTempPath()) "harness-gate-nudge-$key"
if (Test-Path -LiteralPath $stamp) {
    $age = (Get-Date) - (Get-Item -LiteralPath $stamp).LastWriteTime
    if ($age.TotalMinutes -lt $IntervalMinutes) { exit 0 }
}
Set-Content -LiteralPath $stamp -Value (Get-Date -Format 'o')

[Console]::Error.WriteLine(@'
gate-nudge: C# changed - the static-analysis gates have not run for this change.

  ./scripts/run-roslyn-analyzers.ps1
  ./scripts/run-cyclomatic-complexity.ps1

Delegate to the `gate-runner` agent to keep the output out of this conversation.
A change is not done until the gates are green - `dotnet build` alone surfaces
none of what they catch.
'@)

exit 2
