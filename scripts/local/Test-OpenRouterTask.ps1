#!/usr/bin/env pwsh
# Proves Invoke-OpenRouterTask.ps1 selects the documented per-tier default,
# derives the custom profile Junie requires for OpenRouter ids, keeps that
# profile current and free of per-tier reasoning state, and can be safely
# dry-run without launching Junie, calling the network, or exposing a
# credential.

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$runner = Join-Path $PSScriptRoot 'Invoke-OpenRouterTask.ps1'
$checks = 0
$failures = 0

function Assert-That {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')

    $script:checks++
    if ($Condition) {
        Write-Host "  ok    $Name"
    }
    else {
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        if ($Detail) { Write-Host "        $Detail" -ForegroundColor DarkGray }
        $script:failures++
    }
}

$helpText = Get-Help -Name $runner -Full | Out-String
Assert-That 'the help states the task is piped as JSON on stdin' ($helpText -match 'piped to Junie as JSON on stdin')
Assert-That 'the help warns not to put secrets in -Task' ($helpText -match 'do not include secrets in -Task')

$previousKey = $env:OPENROUTER_API_KEY
$previousPath = $env:PATH
$previousNativeCommandUseErrorActionPreference = $PSNativeCommandUseErrorActionPreference
$temporaryDir = $null
try {
    # Placeholder only: -WhatIf and -ProfileOnly stop before Junie is ever
    # launched, and nothing in this suite makes a network call, so this
    # value never has to be a working key. It also lets us assert the
    # profile never leaks it.
    $env:OPENROUTER_API_KEY = 'test-key-not-used'

    $default = & $runner -Task 'No-op test task' -WhatIf 6>&1 | Out-String
    Assert-That 'the deep tier (the default) resolves to GLM 5.2' ($default -match 'Model:\s+z-ai/glm-5\.2') $default
    Assert-That 'the default deep tier maps to high effort' ($default -match 'Tier:\s+deep \(effort=high\)') $default
    Assert-That 'the default profile is the derived custom id' ($default -match 'Profile:\s+custom:openrouter-z-ai-glm-5\.2') $default
    Assert-That 'a dry run does not launch Junie' ($default -match 'Dry run: Junie will not be launched\.') $default

    # This run passes no -ModelDir, so it exercises the parameter default.
    # That default is bound before any statement executes: a Windows-only
    # expression there takes the whole script down off Windows, which is a
    # CI leg. Asserting the platform-joined separator also catches
    # '.junie\models' collapsing into one literal filename on Linux.
    $defaultModelPath = Join-Path (Join-Path $HOME '.junie') 'models'
    Assert-That 'the default model directory resolves under the home directory' `
        ($default -match [regex]::Escape($defaultModelPath)) $default

    $fastDefault = & $runner -Task 'No-op test task' -Tier fast -WhatIf 6>&1 | Out-String
    Assert-That 'the fast tier resolves to its documented default model' ($fastDefault -match 'Model:\s+deepseek/deepseek-v4-flash') $fastDefault
    Assert-That 'the fast tier maps to low effort' ($fastDefault -match 'Tier:\s+fast \(effort=low\)') $fastDefault

    $balancedDefault = & $runner -Task 'No-op test task' -Tier balanced -WhatIf 6>&1 | Out-String
    Assert-That 'the balanced tier resolves to its documented default model' ($balancedDefault -match 'Model:\s+deepseek/deepseek-v4-pro') $balancedDefault
    Assert-That 'the balanced tier maps to medium effort' ($balancedDefault -match 'Tier:\s+balanced \(effort=medium\)') $balancedDefault

    $override = & $runner -Task 'No-op test task' -Tier balanced -Model 'qwen/qwen3-coder' -WhatIf 6>&1 | Out-String
    Assert-That 'an explicit -Model overrides the tier default' ($override -match 'Model:\s+qwen/qwen3-coder') $override
    Assert-That 'the override profile name is filename-safe' ($override -match 'Profile:\s+custom:openrouter-qwen-qwen3-coder') $override

    $temporaryDir = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ('openrouter-task-test-' + [guid]::NewGuid().ToString('N')))

    # -WhatIf must write nothing at all -- not the profile file, not even
    # the containing directory -- for a plain run and for -ProfileOnly.
    $whatIfModelDir = Join-Path $temporaryDir.FullName 'whatif-models'
    & $runner -Task 'No-op test task' -Tier fast -ModelDir $whatIfModelDir -WhatIf *>$null
    Assert-That '-WhatIf creates no model directory' (-not (Test-Path -LiteralPath $whatIfModelDir))

    $whatIfProfileOnlyModelDir = Join-Path $temporaryDir.FullName 'whatif-profileonly-models'
    & $runner -Task 'No-op test task' -Tier fast -ModelDir $whatIfProfileOnlyModelDir -ProfileOnly -WhatIf *>$null
    Assert-That '-ProfileOnly combined with -WhatIf creates no model directory' (-not (Test-Path -LiteralPath $whatIfProfileOnlyModelDir))

    # -ProfileOnly must render and write the profile, report doing so, and
    # exit 0 -- all without ever needing Junie on PATH, so run it before the
    # fake junie.cmd below is added to PATH.
    $profileOnlyModelDir = Join-Path $temporaryDir.FullName 'profileonly-models'
    $profileOnlyOutput = & $runner -Task 'No-op test task' -Tier deep -ModelDir $profileOnlyModelDir -ProfileOnly 6>&1 | Out-String
    $profileOnlyExitCode = $LASTEXITCODE
    Assert-That '-ProfileOnly exits 0' ($profileOnlyExitCode -eq 0) "Got $profileOnlyExitCode"
    Assert-That '-ProfileOnly reports it skipped launching Junie' ($profileOnlyOutput -match 'Profile-only run: Junie was not launched\.') $profileOnlyOutput
    Assert-That '-ProfileOnly reports the profile as created on first write' ($profileOnlyOutput -match 'Created Junie custom model profile:') $profileOnlyOutput

    $profileOnlyPath = Join-Path $profileOnlyModelDir 'openrouter-z-ai-glm-5.2.json'
    Assert-That '-ProfileOnly actually wrote the profile file' (Test-Path -LiteralPath $profileOnlyPath)
    if (Test-Path -LiteralPath $profileOnlyPath) {
        $rawProfile = Get-Content -LiteralPath $profileOnlyPath -Raw
        $parsedProfile = $rawProfile | ConvertFrom-Json

        Assert-That 'the profile targets the OpenRouter chat completions endpoint' ($parsedProfile.baseUrl -eq 'https://openrouter.ai/api/v1/chat/completions')
        Assert-That 'the profile carries the requested model id' ($parsedProfile.id -eq 'z-ai/glm-5.2')
        Assert-That 'the profile references the key from the environment, never a literal' ($parsedProfile.apiKey -eq '${OPENROUTER_API_KEY}')
        Assert-That 'the profile literally contains the ${OPENROUTER_API_KEY} reference' ($rawProfile -like '*${OPENROUTER_API_KEY}*')
        Assert-That 'the profile does not contain the actual key value' ($rawProfile -notmatch [regex]::Escape($env:OPENROUTER_API_KEY))
        Assert-That 'the profile sorts providers by price' ($parsedProfile.extraBody.provider.sort -eq 'price')
        Assert-That 'the profile has no top-level reasoning object' (-not ($parsedProfile.PSObject.Properties.Name -contains 'reasoning'))
        Assert-That 'the profile has no reasoning_effort field' (-not ($parsedProfile.PSObject.Properties.Name -contains 'reasoning_effort'))
        Assert-That 'the raw profile text never mentions reasoning_effort' ($rawProfile -notmatch 'reasoning_effort')
    }

    # A profile written before this script grew extraBody must be rewritten
    # to pick it up; one already current must be left alone (no message).
    $staleModelDir = Join-Path $temporaryDir.FullName 'stale-models'
    New-Item -ItemType Directory -Path $staleModelDir -Force | Out-Null
    $stalePath = Join-Path $staleModelDir 'openrouter-z-ai-glm-5.2.json'
    $staleContent = @"
{
  "baseUrl": "https://openrouter.ai/api/v1/chat/completions",
  "id": "z-ai/glm-5.2",
  "apiType": "OpenAICompletion",
  "apiKey": "`${OPENROUTER_API_KEY}",
  "temperature": 0.7
}
"@
    [System.IO.File]::WriteAllText($stalePath, $staleContent, [System.Text.UTF8Encoding]::new($false))

    $rewriteOutput = & $runner -Task 'No-op test task' -Tier deep -ModelDir $staleModelDir -ProfileOnly 6>&1 | Out-String
    Assert-That 'a stale profile is reported as updated, not created' ($rewriteOutput -match 'Updated Junie custom model profile:') $rewriteOutput
    if (Test-Path -LiteralPath $stalePath) {
        $rewrittenProfile = Get-Content -LiteralPath $stalePath -Raw | ConvertFrom-Json
        Assert-That 'the rewritten profile now carries extraBody' ($rewrittenProfile.extraBody.provider.sort -eq 'price')
    }

    $currentOutput = & $runner -Task 'No-op test task' -Tier deep -ModelDir $staleModelDir -ProfileOnly 6>&1 | Out-String
    Assert-That 'a profile already current is not reported as created' ($currentOutput -notmatch 'Created Junie custom model profile:') $currentOutput
    Assert-That 'a profile already current is not reported as updated' ($currentOutput -notmatch 'Updated Junie custom model profile:') $currentOutput

    # The derived profile name is a plain function of the model id, so a
    # deliberately hand-tuned profile can already own that filename. Rewriting
    # it would destroy real work silently, so it must survive untouched and the
    # run must say so rather than proceeding as if it had written the profile.
    $tunedModelDir = Join-Path $temporaryDir.FullName 'tuned-models'
    New-Item -ItemType Directory -Path $tunedModelDir -Force | Out-Null
    $tunedPath = Join-Path $tunedModelDir 'openrouter-z-ai-glm-5.2.json'
    $tunedContent = @"
{
  "baseUrl": "https://openrouter.ai/api/v1/chat/completions",
  "id": "z-ai/glm-5.2",
  "displayName": "Hand tuned, not written by the launcher",
  "apiType": "OpenAICompletion",
  "apiKey": "`${OPENROUTER_API_KEY}",
  "temperature": 1.0,
  "maxContextLength": 1048576
}
"@
    [System.IO.File]::WriteAllText($tunedPath, $tunedContent, [System.Text.UTF8Encoding]::new($false))

    $tunedOutput = & $runner -Task 'No-op test task' -Tier deep -ModelDir $tunedModelDir -ProfileOnly 3>&1 6>&1 | Out-String
    $tunedAfter = Get-Content -LiteralPath $tunedPath -Raw
    Assert-That 'a hand-tuned profile is left byte-for-byte untouched' ($tunedAfter -eq $tunedContent)
    Assert-That 'a hand-tuned profile is reported, not silently kept' ($tunedOutput -match 'hand-tuned') $tunedOutput
    Assert-That 'a hand-tuned profile is never reported as updated' ($tunedOutput -notmatch 'Updated Junie custom model profile:') $tunedOutput
    Assert-That 'a hand-tuned profile is never reported as created' ($tunedOutput -notmatch 'Created Junie custom model profile:') $tunedOutput

    # Now exercise the real launch path against a fake junie, which must only
    # be reachable once -ProfileOnly is out of the picture. The stub has to
    # match the platform: PATHEXT is Windows-only, so a .cmd is simply not
    # discoverable by Get-Command on the Linux CI leg.
    $modelDir = Join-Path $temporaryDir.FullName 'models'
    if ($IsWindows) {
        $fakeJunie = Join-Path $temporaryDir.FullName 'junie.cmd'
        [System.IO.File]::WriteAllText($fakeJunie, "@echo off`r`nexit /b 23`r`n", [System.Text.UTF8Encoding]::new($false))
    }
    else {
        $fakeJunie = Join-Path $temporaryDir.FullName 'junie'
        [System.IO.File]::WriteAllText($fakeJunie, "#!/bin/sh`nexit 23`n", [System.Text.UTF8Encoding]::new($false))
        chmod +x $fakeJunie
    }

    $env:PATH = $temporaryDir.FullName + [System.IO.Path]::PathSeparator + $previousPath
    $env:OPENROUTER_API_KEY = 'test-key-not-used'
    $PSNativeCommandUseErrorActionPreference = $true

    $nativeExit = (& $runner -Task 'No-op test task' -Tier deep -Model 'z-ai/glm-5.2' -ModelDir $modelDir 6>&1 | Out-String)
    Assert-That 'a native Junie failure preserves the native exit code' ($LASTEXITCODE -eq 23) "Got $LASTEXITCODE"
    Assert-That 'the launcher still runs through Junie when the command exists' ($nativeExit -match 'Provider:\s+OpenRouter \(via Junie\)')

    $writtenProfile = Join-Path $modelDir 'openrouter-z-ai-glm-5.2.json'
    Assert-That 'the launcher writes the custom profile before invoking Junie' (Test-Path -LiteralPath $writtenProfile)
    if (Test-Path -LiteralPath $writtenProfile) {
        $profile = Get-Content -LiteralPath $writtenProfile -Raw | ConvertFrom-Json
        Assert-That 'the profile targets the OpenRouter chat completions endpoint' ($profile.baseUrl -eq 'https://openrouter.ai/api/v1/chat/completions')
        Assert-That 'the profile carries the requested model id' ($profile.id -eq 'z-ai/glm-5.2')
        Assert-That 'the profile references the key from the environment, never a literal' ($profile.apiKey -eq '${OPENROUTER_API_KEY}')
    }
}
finally {
    if ($null -eq $previousKey) {
        Remove-Item Env:OPENROUTER_API_KEY -ErrorAction SilentlyContinue
    }
    else {
        $env:OPENROUTER_API_KEY = $previousKey
    }

    $env:PATH = $previousPath
    $PSNativeCommandUseErrorActionPreference = $previousNativeCommandUseErrorActionPreference

    if ($null -ne $temporaryDir -and (Test-Path -LiteralPath $temporaryDir.FullName)) {
        Remove-Item -LiteralPath $temporaryDir.FullName -Recurse -Force
    }
}

Write-Host ''
Write-Host "Checks: $checks  Failures: $failures"
if ($failures -gt 0) { exit 1 }
exit 0
