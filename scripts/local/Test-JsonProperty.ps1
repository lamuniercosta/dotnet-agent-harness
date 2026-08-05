#!/usr/bin/env pwsh
# Self-test for StrictMode-safe JSON helpers used by Set-IssueInProgress.ps1.
#
# These are the shapes that previously crashed under Set-StrictMode -Version Latest:
# bad credentials (no data key), empty Status field object, and a normal path.
#
#   pwsh ./scripts/local/Test-JsonProperty.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_json-property.ps1')

$failures = 0
$checks = 0

function Assert-True {
    param([string]$Name, [bool]$Condition)
    $script:checks++
    if ($Condition) { Write-Host "  ok       $Name" }
    else { Write-Host "  FAIL     $Name" -ForegroundColor Red; $script:failures++ }
}

function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    $script:checks++
    if ($Expected -eq $Actual) { Write-Host "  ok       $Name" }
    else {
        Write-Host "  FAIL     $Name (expected=$Expected actual=$Actual)" -ForegroundColor Red
        $script:failures++
    }
}

Write-Host 'Test-JsonProperty / Get-JsonPath'

# 1. Bad credentials — {"message":"..."} with no data key must not throw.
$badToken = '{"message":"Bad credentials","documentation_url":"https://docs.github.com/rest","status":"401"}' | ConvertFrom-Json
Assert-True 'bad token: has message' (Test-JsonProperty -Object $badToken -Name 'message')
Assert-True 'bad token: no data property' (-not (Test-JsonProperty -Object $badToken -Name 'data'))
Assert-Equal 'bad token: data path is null' $null (Get-JsonPath -Object $badToken -Path @('data', 'repository', 'issue'))
Assert-Equal 'bad token: message value' 'Bad credentials' $badToken.message

# 2. field:{} — Status is not a single-select; .id must not throw.
$emptyField = '{"project":{"title":"Portfolio 2026","field":{}}}' | ConvertFrom-Json
$field = Get-JsonPath -Object $emptyField -Path @('project', 'field')
Assert-True 'empty field: object present' ($null -ne $field)
Assert-True 'empty field: no id property' (-not (Test-JsonProperty -Object $field -Name 'id'))
$fieldId = if (Test-JsonProperty -Object $field -Name 'id') { [string]$field.id } else { $null }
Assert-True 'empty field: treated as missing Status' ([string]::IsNullOrWhiteSpace($fieldId))

# 3. Headline path — field definition + empty item value is settable.
$ready = @'
{
  "data": {
    "repository": {
      "issue": {
        "projectItems": {
          "nodes": [
            {
              "id": "PVTI_test",
              "project": {
                "id": "PVT_test",
                "title": "Portfolio 2026",
                "field": {
                  "id": "PVTSSF_status",
                  "options": [
                    { "id": "opt_todo", "name": "Todo" },
                    { "id": "opt_ip", "name": "In Progress" },
                    { "id": "opt_done", "name": "Done" }
                  ]
                }
              },
              "fieldValueByName": null
            }
          ]
        }
      }
    }
  }
}
'@ | ConvertFrom-Json

$issue = Get-JsonPath -Object $ready -Path @('data', 'repository', 'issue')
Assert-True 'ready: issue present' ($null -ne $issue)
$node = @(Get-JsonPath -Object $issue -Path @('projectItems', 'nodes'))[0]
$statusField = Get-JsonPath -Object $node -Path @('project', 'field')
Assert-Equal 'ready: field id' 'PVTSSF_status' $statusField.id
$inProgress = @($statusField.options | Where-Object { $_.name -eq 'In Progress' } | Select-Object -First 1)
Assert-Equal 'ready: In Progress option' 'opt_ip' $inProgress[0].id
Assert-True 'ready: empty value is startable' (-not (Test-JsonProperty -Object $node -Name 'fieldValueByName') -or $null -eq $node.fieldValueByName)

# 4. Not-found — data.repository.issue is explicitly null.
$missing = '{"data":{"repository":{"issue":null}}}' | ConvertFrom-Json
$repoNode = Get-JsonPath -Object $missing -Path @('data', 'repository')
Assert-True 'missing: repository present' ($null -ne $repoNode)
Assert-True 'missing: issue property exists' (Test-JsonProperty -Object $repoNode -Name 'issue')
Assert-True 'missing: issue is null' ($null -eq $repoNode.issue)

Write-Host ""
if ($failures -eq 0) {
    Write-Host "All $checks checks passed."
    exit 0
}

Write-Host "$failures of $checks checks failed." -ForegroundColor Red
exit 1
