# Shared host rendering for canonical harness skills.
# Dot-sourced by install.ps1 and the repo-local self-development bootstrap so
# Codex adaptation has one implementation.

function Convert-CodexSkillReferences {
    <#
      Codex exposes project skills as `$name`, while the same canonical
      Markdown uses `/name` for Claude and Cursor. Adapt only a generated Codex
      discovery tree.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$SkillsSource,

        [Parameter(Mandatory = $true)]
        [string]$CodexSkills
    )

    $skillNames = @(Get-ChildItem -LiteralPath $SkillsSource -Directory | ForEach-Object { $_.Name })
    $namePattern = @($skillNames | ForEach-Object { [regex]::Escape($_) }) -join '|'
    # The preceding character must not be part of a URL or path segment.
    $pattern = '(?<![A-Za-z0-9._-])/(?:' + $namePattern + '|speckit-[A-Za-z0-9-]+)(?=$|[^A-Za-z0-9_-])'

    if (-not (Test-Path -LiteralPath $CodexSkills)) { return }

    foreach ($skillName in $skillNames) {
        $ownedSkill = Join-Path $CodexSkills $skillName
        if (-not (Test-Path -LiteralPath $ownedSkill)) { continue }
        Get-ChildItem -LiteralPath $ownedSkill -File -Recurse -Filter '*.md' | ForEach-Object {
            $original = Get-Content -LiteralPath $_.FullName -Raw
            $adapted = [regex]::Replace($original, $pattern, {
                    param($match)
                    '$' + $match.Value.Substring(1)
                })
            if ($adapted -cne $original) {
                Set-Content -LiteralPath $_.FullName -Value $adapted -Encoding UTF8 -NoNewline
            }
        }
    }
}
