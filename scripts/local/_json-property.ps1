# StrictMode-safe JSON note-property helpers.
# Dot-sourced by Set-IssueInProgress.ps1 and Test-JsonProperty.ps1.

function Test-JsonProperty {
    <#
      StrictMode-safe: $null -ne $obj.Missing throws when the note property is
      absent. Probe PSObject.Properties instead.
    #>
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return ($null -ne $Object) -and ($null -ne $Object.PSObject.Properties[$Name])
}

function Get-JsonPath {
    <#
      Walk a path of note properties. Returns $null if any segment is missing
      or null-valued — without throwing under Set-StrictMode.
    #>
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string[]]$Path
    )

    $current = $Object
    foreach ($segment in $Path) {
        if (-not (Test-JsonProperty -Object $current -Name $segment)) {
            return $null
        }
        $current = $current.$segment
        if ($null -eq $current) {
            return $null
        }
    }
    return $current
}
