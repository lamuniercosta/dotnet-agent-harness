#!/usr/bin/env pwsh
# Self-test for guard.ps1.
#
# A guard that is trusted but bypassable is worse than no guard, so its
# behaviour is asserted rather than assumed. Includes the escaped-quote payload
# that defeats a grep/sed-based extractor - the regression this hook exists to
# fix.
#
#   pwsh ./hooks/Test-Guard.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$guard = Join-Path $PSScriptRoot 'guard.ps1'
$failures = 0
$checks = 0

function Invoke-Guard {
    param([string]$Json)
    $Json | & pwsh -NoProfile -File $guard 2>&1 | Out-Null
    return $LASTEXITCODE
}

function Assert-Blocked {
    param([string]$Name, [string]$Json)
    $script:checks++
    if ((Invoke-Guard $Json) -eq 2) { Write-Host "  ok       blocked: $Name" }
    else { Write-Host "  FAIL     allowed: $Name" -ForegroundColor Red; $script:failures++ }
}

function Assert-Allowed {
    param([string]$Name, [string]$Json)
    $script:checks++
    if ((Invoke-Guard $Json) -eq 0) { Write-Host "  ok       allowed: $Name" }
    else { Write-Host "  FAIL     blocked: $Name" -ForegroundColor Red; $script:failures++ }
}

function Bash { param([string]$Cmd) (@{ tool_name = 'Bash'; tool_input = @{ command = $Cmd } } | ConvertTo-Json -Compress -Depth 5) }
function Edit { param([string]$Path) (@{ tool_name = 'Edit'; tool_input = @{ file_path = $Path } } | ConvertTo-Json -Compress -Depth 5) }
function Apply-Patch { param([string]$Command) (@{ tool_name = 'apply_patch'; tool_input = @{ command = $Command } } | ConvertTo-Json -Compress -Depth 5) }

Write-Host 'Destructive commands are blocked:'
Assert-Blocked 'rm -rf /'                (Bash 'rm -rf /')
Assert-Blocked 'rm -rf ~'                (Bash 'rm -rf ~')
Assert-Blocked 'rm -rf $HOME'            (Bash 'rm -rf $HOME')
Assert-Blocked 'rm -fr node_modules'     (Bash 'rm -fr node_modules')
Assert-Blocked 'rm -rf src/bin'          (Bash 'rm -rf src/bin')
Assert-Blocked 'force-push main'         (Bash 'git push --force origin main')
Assert-Blocked 'force-push -f develop'   (Bash 'git push -f origin develop')
Assert-Blocked 'lease-push main'         (Bash 'git push --force-with-lease origin main')
Assert-Blocked 'scoped lease-push main'  (Bash 'git push --force-with-lease=refs/heads/main origin HEAD:refs/heads/main')
Assert-Blocked 'bare lease push'         (Bash 'git push --force-with-lease')
Assert-Blocked 'reset --hard origin'     (Bash 'git reset --hard origin/main')
Assert-Blocked 'checkout -- .'           (Bash 'git checkout -- .')

Write-Host ''
Write-Host 'The escaped-quote bypass is closed:'
# A grep -o '"command"[^"]*"' extractor truncates at the escaped quote and sees
# only `echo `, so every pattern below it misses the rm that follows.
Assert-Blocked 'escaped quote then rm -rf /' (Bash 'echo \"safe\" && rm -rf /')
Assert-Blocked 'quoted arg then force-push'  (Bash 'git commit -m \"wip\" && git push --force origin main')

Write-Host ''
Write-Host 'Protected paths are blocked:'
Assert-Blocked 'write node_modules' (Edit '/repo/node_modules/pkg/index.js')
Assert-Blocked 'write obj'          (Edit 'C:\repo\src\obj\Debug\gen.cs')
Assert-Blocked 'write .git'         (Edit '/repo/.git/config')
Assert-Blocked 'patch Add bin'       (Apply-Patch "*** Begin Patch`n*** Add File: src/bin/Generated.cs`n*** End Patch")
Assert-Blocked 'patch Update obj'    (Apply-Patch "*** Begin Patch`n*** Update File: src/obj/Generated.cs`n*** End Patch")
Assert-Blocked 'patch Delete node_modules' (Apply-Patch "*** Begin Patch`n*** Delete File: node_modules/pkg/index.js`n*** End Patch")
Assert-Blocked 'patch Move to .git'  (Apply-Patch "*** Begin Patch`n*** Update File: src/Config.cs`n*** Move to: .git/config`n*** End Patch")

Write-Host ''
Write-Host 'Ordinary work is allowed:'
Assert-Allowed 'dotnet build'         (Bash 'dotnet build')
Assert-Allowed 'rm one file'          (Bash 'rm src/Temp.cs')
Assert-Allowed 'push a task branch'   (Bash 'git push -u origin feature/142-add-retry')
Assert-Allowed 'explicit force-with-lease' (Bash 'git push --force-with-lease=refs/heads/feature/142-add-retry --set-upstream -- origin HEAD:refs/heads/feature/142-add-retry')
Assert-Allowed 'reset --hard HEAD~1'  (Bash 'git reset --hard HEAD~1')
Assert-Allowed 'restore one path'     (Bash 'git checkout -- src/Foo.cs')
Assert-Allowed 'edit source'          (Edit '/repo/src/Api/Program.cs')
Assert-Allowed 'edit a file named bing.cs' (Edit '/repo/src/bing.cs')
Assert-Allowed 'patch source'         (Apply-Patch "*** Begin Patch`n*** Update File: src/Api/Program.cs`n*** End Patch")
Assert-Allowed 'unparseable payload'  'not json at all'

Write-Host ''
if ($failures -gt 0) {
    Write-Host "$failures of $checks checks FAILED." -ForegroundColor Red
    exit 1
}
Write-Host "All $checks checks passed." -ForegroundColor Green
exit 0
