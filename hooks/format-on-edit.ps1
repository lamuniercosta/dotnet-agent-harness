#!/usr/bin/env pwsh
<#
  PostToolUse hook: format the file that was just edited.

  Keeps the working tree formatted as the agent works, so `dotnet format
  --verify-no-changes` (verify phase 8) does not fail at the end of a session
  over whitespace nobody chose.

  Non-blocking by design: always exits 0. A formatter that can fail a turn is a
  formatter that gets disabled.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'

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
if (-not (Test-Path -LiteralPath $file)) { exit 0 }
if ([System.IO.Path]::GetExtension($file) -ne '.cs') { exit 0 }

# Never format generated or vendored output.
if (($file -replace '\\', '/') -match '/(bin|obj|node_modules)/') { exit 0 }

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { exit 0 }

# `dotnet format` needs a project or solution; find the nearest one upward.
$dir = Split-Path -LiteralPath $file -Parent
$project = $null
while ($dir -and -not $project) {
    $found = @(Get-ChildItem -LiteralPath $dir -Filter '*.csproj' -File -ErrorAction SilentlyContinue)
    if ($found.Count -gt 0) { $project = $found[0].FullName; break }
    $parent = Split-Path -LiteralPath $dir -Parent
    if ($parent -eq $dir) { break }
    $dir = $parent
}
if (-not $project) { exit 0 }

# --include scopes the run to the single edited file; formatting the whole
# project on every keystroke would be unusably slow on a large solution.
& dotnet format $project --include $file --verbosity quiet 2>&1 | Out-Null

exit 0
