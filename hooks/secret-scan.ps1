#!/usr/bin/env pwsh
<#
  Warns when content that looks like a credential is about to reach the model.

  This replaces three hooks the harness lost when SonarQube was dropped
  (beforeReadFile / preToolUse / beforeSubmitPrompt, each a `sonar hook`
  pass-through). Removing the vendor removed the capability with it, leaving no
  secret scanning at all - a regression worth naming rather than inheriting.

  It addresses a DIFFERENT problem from "don't commit secrets". A secret that
  reaches a model provider has left your machine; no later commit hook can
  recall it. gitleaks in CI covers the commit-time half.

  WARN-ONLY, deliberately. Regex credential detection false-positives on test
  fixtures, base64 blobs, and long hashes. A hook that blocks work on a guess
  gets switched off within a day, and a disabled hook protects nothing. Only
  guard.ps1 blocks, and only on things that are hard to undo.

  Exit 2 surfaces the warning to the agent. Exit 0 is silence.
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

# Both platforms, and both directions: a prompt being submitted, or a file
# about to be read into context.
$toolInput = Get-Prop $payload @('tool_input', 'toolInput', 'input', 'arguments')

$content = Get-Prop $payload @('prompt', 'text', 'message', 'content')
if (-not $content) { $content = Get-Prop $toolInput @('prompt', 'content', 'text') }

$file = Get-Prop $toolInput @('file_path', 'filePath', 'path', 'target_file')
if (-not $file) { $file = Get-Prop $payload @('file_path', 'filePath', 'path') }

if (-not $content -and $file) {
    if (-not (Test-Path -LiteralPath $file)) { exit 0 }

    # Skip binaries and anything large enough that scanning is not worth the
    # latency on every read.
    $info = Get-Item -LiteralPath $file
    if ($info.Length -gt 512KB) { exit 0 }
    if ($info.Extension -match '^\.(png|jpg|jpeg|gif|ico|pdf|zip|dll|exe|so|dylib|nupkg)$') { exit 0 }

    $content = Get-Content -LiteralPath $file -Raw
}

if ([string]::IsNullOrWhiteSpace($content)) { exit 0 }

# Shapes that are credentials by construction, not by naming convention.
# Ordered most-specific first so the reported reason is the useful one.
$patterns = [ordered]@{
    'AWS access key id'        = 'AKIA[0-9A-Z]{16}'
    'private key block'        = '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    'GitHub token'             = '\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}'
    'Slack token'              = '\bxox[abprs]-[A-Za-z0-9-]{10,}'
    'Google API key'           = '\bAIza[0-9A-Za-z_-]{35}\b'
    'Stripe secret key'        = '\b(sk|rk)_(live|test)_[A-Za-z0-9]{20,}'
    # `=` is in the class because these are base64 segments and routinely padded.
    'JetBrains/YouTrack token' = '\bperm:[A-Za-z0-9._=-]{20,}'
    'Mapbox secret token'      = '\bsk\.eyJ[A-Za-z0-9._-]{20,}'
    'JWT'                      = '\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
    'connection string password' = '(?i)(password|pwd)\s*=\s*[^;''"\s]{8,}'
    'assigned secret literal'  = '(?i)\b(api[_-]?key|secret|token|passwd|password)\b\s*[:=]\s*[''"][A-Za-z0-9_/+=.-]{20,}[''"]'
}

$hits = [System.Collections.Generic.List[string]]::new()

foreach ($name in $patterns.Keys) {
    $m = [regex]::Match($content, $patterns[$name])
    if (-not $m.Success) { continue }

    # Never echo the value. Reporting a secret to prove a secret was found
    # would put it in the transcript, which is the thing being prevented.
    $line = ($content.Substring(0, $m.Index) -split "`n").Count
    [void]$hits.Add("  - $name (line ~$line, $($m.Length) chars)")
}

if ($hits.Count -eq 0) { exit 0 }

$where = if ($file) { $file } else { 'the submitted prompt' }

[Console]::Error.WriteLine(@"
secret-scan: possible credential in $where

$($hits -join "`n")

Values are not printed - reporting one would put it in the transcript.

If real: stop, rotate it, and move it to a secret store or environment
variable before continuing. A credential that reached a model provider has
already left this machine and cannot be recalled by a later commit hook.

If a fixture or false positive: continue. This hook warns and never blocks,
because a scanner that halts work on a guess gets disabled, and a disabled
scanner protects nothing.
"@)

exit 2
