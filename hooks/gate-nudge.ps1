#!/usr/bin/env pwsh
<#
  PostToolUse hook: after a .cs write, remind that the gates are pending.

  The gates only help if they are actually run. The failure mode this addresses
  is an agent editing fifteen files and then declaring success, having run
  nothing - the gates were available the whole time and simply never invoked.

  Deliberately quiet:
    - fires only on .cs writes outside bin/obj
    - at most once every 10 minutes per repo, tracked in a temp stamp file
    - uses the host's explicit output contract so the message reaches the agent
      after the edit is already applied (PostToolUse), as a nudge, not a block

  It does NOT run the gates. Running a build on every keystroke would be slower
  than the work itself; the agent decides when to spend that time.
#>

param(
    [ValidateSet('Legacy', 'Codex', 'Cursor')]
    [string]$OutputContract = 'Legacy'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'

$IntervalMinutes = 10

function Allow {
    if ($OutputContract -eq 'Cursor') { [Console]::Out.WriteLine('{}') }
    exit 0
}

$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) { Allow }

try { $payload = ConvertFrom-Json -InputObject $raw } catch { Allow }
if (-not $payload) { Allow }

function Get-Prop {
    param($Object, [string[]]$Names)
    if (-not $Object) { return $null }
    $available = @($Object.PSObject.Properties.Name)
    foreach ($name in $Names) {
        if ($available -contains $name) { return $Object.$name }
    }
    return $null
}

function Get-EditedFiles {
    param($Payload, $ToolInput)
    $direct = Get-Prop $ToolInput @('file_path', 'filePath', 'path', 'target_file')
    if (-not [string]::IsNullOrWhiteSpace($direct)) { return @($direct) }

    $command = Get-Prop $ToolInput @('command', 'cmd')
    if ([string]::IsNullOrWhiteSpace($command)) { return @() }

    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($command -split "`r?`n")) {
        if ($line -match '^\*\*\*\s+(?:Add|Update|Delete) File:\s*(.+?)\s*$' -or
            $line -match '^\*\*\*\s+Move to:\s*(.+?)\s*$') {
            [void]$paths.Add($Matches[1])
        }
    }
    return $paths
}

function Resolve-HookPath {
    param([string]$Path, $Payload, $ToolInput)
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    $cwd = Get-Prop $Payload @('cwd', 'working_directory', 'workingDirectory')
    if (-not $cwd) { $cwd = Get-Prop $ToolInput @('cwd', 'working_directory', 'workingDirectory') }
    if (-not $cwd) { return $Path }
    return [System.IO.Path]::GetFullPath($Path, $cwd)
}

$toolInput = Get-Prop $payload @('tool_input', 'toolInput', 'input', 'arguments')
$file = $null
foreach ($candidate in (Get-EditedFiles $payload $toolInput)) {
    $resolved = Resolve-HookPath $candidate $payload $toolInput
    if ([System.IO.Path]::GetExtension($resolved) -ne '.cs') { continue }
    $normalized = $resolved -replace '\\', '/'
    if ($normalized -match '/(bin|obj|node_modules)/') { continue }
    # Tests are exercised by `dotnet test`; the analyzer gates target production code.
    if ($normalized -match '/tests?/' -or $normalized -match '\.Tests?\.cs$') { continue }
    $file = $resolved
    break
}
if (-not $file) { Allow }

# Throttle per repository so a multi-file edit produces one nudge, not twenty.
$repo = (git -C (Split-Path -LiteralPath $file -Parent) rev-parse --show-toplevel 2>$null)
if (-not $repo) { $repo = Split-Path -LiteralPath $file -Parent }
$key = [System.BitConverter]::ToString(
    [System.Security.Cryptography.MD5]::HashData([System.Text.Encoding]::UTF8.GetBytes("$repo"))
).Replace('-', '').Substring(0, 12)

$stamp = Join-Path ([System.IO.Path]::GetTempPath()) "harness-gate-nudge-$key"
if (Test-Path -LiteralPath $stamp) {
    $age = (Get-Date) - (Get-Item -LiteralPath $stamp).LastWriteTime
    if ($age.TotalMinutes -lt $IntervalMinutes) { Allow }
}
Set-Content -LiteralPath $stamp -Value (Get-Date -Format 'o')

$nudge = @'
gate-nudge: C# changed - the static-analysis gates have not run for this change.

  ./scripts/run-roslyn-analyzers.ps1
  ./scripts/run-cyclomatic-complexity.ps1

Run them before reporting the change complete. `dotnet build` alone surfaces none
of what they catch.
'@

if ($OutputContract -eq 'Cursor') {
    [Console]::Error.WriteLine($nudge)
    $message = $nudge | ConvertTo-Json -Compress
    [Console]::Out.WriteLine("{`"additional_context`":$message}")
    exit 0
}

if ($OutputContract -eq 'Codex') {
    @{
        systemMessage = $nudge
        hookSpecificOutput = @{
            hookEventName = 'PostToolUse'
            additionalContext = $nudge
        }
    } | ConvertTo-Json -Compress -Depth 5
    exit 0
}

[Console]::Error.WriteLine($nudge)

exit 2
