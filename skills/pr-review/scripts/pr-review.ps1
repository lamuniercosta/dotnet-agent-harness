#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Deterministic helper for the /pr-review skill.

.DESCRIPTION
  Owns only mechanical PR-review operations: resolve/pin a PR, manage the
  off-repo workspace, validate findings/payloads against review-schema.json,
  fingerprint and dedupe findings, build one COMMENT review payload, post it
  via gh api, and render a Markdown fallback.

  Semantic analysis stays with the model. This script never pattern-matches
  code to invent findings.

  Verbs (exactly one per invocation):
    -Resolve [number-or-url]
    -Preflight -Payload <path>
    -Post -Payload <path>
    -NewWorkspace -Owner <o> -Repo <r> -Pr <n> -HeadSha <sha>
    -Validate -Findings <path> | -Payload <path>
    -Fingerprint -Findings <path>
    -Dedupe -Findings <path> -Prior <path>
    -BuildPayload -Findings <path> -BaseSha <sha> -HeadSha <sha> (-BodyText <text> | -BodyFile <path>)
    -MarkdownFallback -Payload <path>
    -Help

.EXAMPLE
  pwsh ./skills/pr-review/scripts/pr-review.ps1 -Help

.EXAMPLE
  pwsh ./skills/pr-review/scripts/pr-review.ps1 -Validate -Findings $env:TEMP/findings.json
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Resolve,

    [switch]$Preflight,
    [switch]$Post,
    [switch]$NewWorkspace,
    [switch]$Validate,
    [switch]$Fingerprint,
    [switch]$Dedupe,
    [switch]$BuildPayload,
    [switch]$MarkdownFallback,
    [switch]$Help,

    [string]$Payload,
    [string]$Findings,
    [string]$Prior,
    [string]$Owner,
    [string]$Repo,
    [int]$Pr,
    [string]$HeadSha,
    [string]$BaseSha,

    # Body text and body file are deliberately separate. A single -Body that read
    # its value as a file whenever that value happened to name one turned review
    # prose into a local-file read primitive.
    [string]$BodyText,
    [string]$BodyFile,

    # Optional guard: -Post refuses a payload whose workspace belongs to a
    # different run.
    [string]$RunId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SchemaPath = Join-Path $PSScriptRoot 'review-schema.json'
$script:SeverityEnum = @('Critical', 'High', 'Medium', 'Low')
$script:CategoryEnum = @('risk', 'security', 'standards', 'spec', 'coverage', 'performance')
$script:VerdictEnum = @('CONFIRMED', 'PLAUSIBLE')
$script:SideEnum = @('LEFT', 'RIGHT')
$script:PlacementEnum = @('inline', 'file', 'summary')

# ---------------------------------------------------------------------------
# Usage / dispatch helpers
# ---------------------------------------------------------------------------

function Show-Usage {
    @'
pr-review.ps1 — deterministic helper for /pr-review

USAGE (exactly one verb):
  -Help
  -Resolve [<number-or-url>]
  -Preflight -Payload <path> [-RunId <id>]
  -Post -Payload <path> [-RunId <id>]
  -NewWorkspace -Owner <o> -Repo <r> -Pr <n> -HeadSha <sha>
  -Validate (-Findings <path> | -Payload <path>)
  -Fingerprint -Findings <path>
  -Dedupe -Findings <path> -Prior <path>
  -BuildPayload -Findings <path> -BaseSha <sha> -HeadSha <sha> (-BodyText <text> | -BodyFile <path>)
  -MarkdownFallback -Payload <path>

NOTES
  - Requires PowerShell 7+ and (for -Resolve/-Preflight/-Post) an authenticated
    gh CLI. There is no connector fallback: every publication guarantee lives in
    this script, so a second path would have to reimplement all of them.
  - -Preflight is the --dry-run path. It runs every pre-publication check -Post
    runs — schema, canonical workspace, run-id binding, closing base/head re-read,
    run-marker reconciliation, diff-location validation — writes review.json and
    review.md, and stops. It reads from the API and writes nothing to GitHub.
  - Each -Resolve mints a run id and owns one run directory:
      <temp>/pr-review/<owner>-<repo>/<pr>-<headsha>/runs/<runid>/
    Pinned state, the outgoing payload, and the receipt live there, so
    concurrent runs over one head cannot overwrite each other.
  - -BodyText is used verbatim and is never probed as a path. -BodyFile is read
    only from inside the workspace root this script owns.
  - Exit 0 on success; non-zero on failure. Offline verbs do no network I/O.
'@ | Write-Output
}

function Test-ResolveRequested {
    <#
      -Resolve may be bound as an empty string (current-branch resolution), so
      presence has to be tested rather than truthiness.

      The script's bound parameters must be passed in: inside a function,
      $PSBoundParameters is that function's own binding, which is always empty
      here — reading it directly made every `-Resolve` invocation fail with
      "No verb specified".
    #>
    param([Parameter(Mandatory)]$BoundParameters)
    return $BoundParameters.ContainsKey('Resolve')
}

# ---------------------------------------------------------------------------
# Common utilities
# ---------------------------------------------------------------------------

function Assert-GhPresent {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw 'gh CLI not found. Install https://cli.github.com and run: gh auth login'
    }
}

function Invoke-Gh {
    <#
      Run gh, capture merged stdout/stderr, assert exit 0, return trimmed text.
    #>
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string[]]$GhArgs,
        [switch]$AllowFailure
    )

    $output = & gh @GhArgs 2>&1 | Out-String
    if (-not $AllowFailure -and $LASTEXITCODE -ne 0) {
        $detail = if ([string]::IsNullOrWhiteSpace($output)) { '(no output)' } else { $output.Trim() }
        throw "gh failed while $Action (exit $LASTEXITCODE): $detail"
    }
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Text     = $output
    }
}

function ConvertFrom-GhJson {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Action
    )

    $jsonText = $Text
    if ($Text -match '(?s)(\[.*\]|\{.*\})\s*$') {
        $jsonText = $Matches[1]
    }

    try {
        return $jsonText | ConvertFrom-Json -Depth 100
    }
    catch {
        throw "Failed to parse gh JSON while $Action`: $($_.Exception.Message)`nRaw: $($Text.Trim())"
    }
}

function Split-JsonDocuments {
    <#
      `gh api --paginate` emits one complete JSON document per page, so a PR that
      crosses a page boundary produces `[...]\n[...]` — not parseable as a single
      document. Split the stream back into top-level documents. String- and
      escape-aware so brackets inside string values do not move the depth.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $docs = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($Text)) { return $docs }

    $depth = 0
    $inString = $false
    $escaped = $false
    $start = -1

    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = [string]$Text[$i]

        if ($inString) {
            if ($escaped) { $escaped = $false }
            elseif ($ch -eq '\') { $escaped = $true }
            elseif ($ch -eq '"') { $inString = $false }
            continue
        }

        if ($ch -eq '"') { $inString = $true; continue }

        if ($ch -eq '[' -or $ch -eq '{') {
            if ($depth -eq 0) { $start = $i }
            $depth++
            continue
        }

        if ($ch -eq ']' -or $ch -eq '}') {
            if ($depth -gt 0) { $depth-- }
            if ($depth -eq 0 -and $start -ge 0) {
                $docs.Add($Text.Substring($start, $i - $start + 1))
                $start = -1
            }
        }
    }

    if ($depth -ne 0) {
        throw "Unbalanced JSON in gh output (truncated response?)."
    }

    return $docs
}

function Invoke-GhPaginated {
    <#
      Run a paginated `gh api` call and return every page parsed, plus the pages
      flattened into one item list. Callers that need per-page envelopes (such as
      check-runs, which wraps its array in an object) read .Pages; callers over a
      plain array endpoint read .Items.
    #>
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowFailure
    )

    $result = Invoke-Gh -Action $Action -GhArgs @('api', $Path, '--paginate') -AllowFailure:$AllowFailure

    $pages = [System.Collections.Generic.List[object]]::new()
    if ($result.ExitCode -eq 0) {
        foreach ($doc in (Split-JsonDocuments -Text $result.Text)) {
            $pages.Add((ConvertFrom-GhJson -Text $doc -Action $Action))
        }
    }

    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($page in $pages) {
        foreach ($item in @($page)) {
            if ($null -ne $item) { $items.Add($item) }
        }
    }

    return [pscustomobject]@{
        ExitCode = $result.ExitCode
        Text     = $result.Text
        Pages    = $pages.ToArray()
        Items    = $items.ToArray()
    }
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "File not found: $Path"
    }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "File is empty: $Path"
    }
    try {
        return $raw | ConvertFrom-Json -Depth 100
    }
    catch {
        throw "Invalid JSON in ${Path}: $($_.Exception.Message)"
    }
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string]$Path
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    # Serialize first, then write to a sibling temp file and move it into place.
    # A crash partway through writing the post receipt used to leave truncated
    # JSON, and every later retry then died parsing it — before reaching the
    # run-marker reconciliation that exists for exactly that case. Either the
    # whole file lands or the previous one stays.
    $json = ($Value | ConvertTo-Json -Depth 100)
    $temp = "$Path.$([guid]::NewGuid().ToString('n').Substring(0, 8)).tmp"
    try {
        Set-Content -LiteralPath $temp -Value $json -Encoding utf8
        Move-Item -LiteralPath $temp -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}

function Get-PropertyValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [hashtable] -or $Object -is [System.Collections.IDictionary]) {
        if ($Object.ContainsKey($Name)) { return $Object[$Name] }
        return $null
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Test-HasProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $false }
    if ($Object -is [hashtable] -or $Object -is [System.Collections.IDictionary]) {
        return $Object.ContainsKey($Name)
    }
    return $null -ne $Object.PSObject.Properties[$Name]
}

function Normalize-PathKey {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    return (($Path -replace '\\', '/').Trim().TrimStart('./')).ToLowerInvariant()
}

function Get-SchemaDocument {
    if (-not (Test-Path -LiteralPath $script:SchemaPath)) {
        throw "Missing schema file: $script:SchemaPath"
    }
    return Read-JsonFile -Path $script:SchemaPath
}

# ---------------------------------------------------------------------------
# Workspace
# ---------------------------------------------------------------------------

function Get-WorkspaceRoot {
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$Pr,
        [Parameter(Mandatory)][string]$HeadSha
    )

    $safeOwner = ($Owner -replace '[^A-Za-z0-9._-]', '_')
    $safeRepo = ($Repo -replace '[^A-Za-z0-9._-]', '_')
    $safeSha = ($HeadSha -replace '[^A-Fa-f0-9]', '').ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($safeSha)) {
        throw "HeadSha must be a hex git SHA; got: $HeadSha"
    }

    $base = Join-Path ([System.IO.Path]::GetTempPath()) 'pr-review'
    $repoKey = "${safeOwner}-${safeRepo}"
    $prKey = "${Pr}-${safeSha}"
    return Join-Path (Join-Path $base $repoKey) $prKey
}

function Set-PrivateDirectoryMode {
    <#
      Restrict a workspace directory to the current user: 0700 on POSIX, and the
      ACL equivalent on Windows. Windows temp directories are per-user by
      default, but a default is not an enforcement — TEMP is routinely
      redirected to a shared location on build and dev machines — so the
      restriction is applied rather than assumed.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if ($IsWindows) {
        try {
            $acl = Get-Acl -LiteralPath $Path
            # Break inheritance without copying the inherited rules down, then
            # drop whatever explicit rules survive, so only the grant below
            # remains.
            $acl.SetAccessRuleProtection($true, $false)
            foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRule($rule) }
            $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
                    [System.Security.Principal.WindowsIdentity]::GetCurrent().User,
                    [System.Security.AccessControl.FileSystemRights]::FullControl,
                    'ContainerInherit, ObjectInherit',
                    [System.Security.AccessControl.PropagationFlags]::None,
                    [System.Security.AccessControl.AccessControlType]::Allow))
            Set-Acl -LiteralPath $Path -AclObject $acl
        }
        catch {
            Write-Warning "Could not restrict permissions on '$Path' ($($_.Exception.Message)). On a shared host, review state may be readable by other users."
        }
        return
    }
    try {
        $mode = [System.IO.UnixFileMode]::UserRead -bor
                [System.IO.UnixFileMode]::UserWrite -bor
                [System.IO.UnixFileMode]::UserExecute
        [System.IO.File]::SetUnixFileMode($Path, $mode)
    }
    catch {
        Write-Warning "Could not restrict permissions on '$Path' ($($_.Exception.Message)). On a shared host, review state may be readable by other users."
    }
}

function Assert-WindowsWorkspaceOwner {
    <#
      The POSIX branch proves the workspace belongs to the current user; Windows
      needs the same proof. "Windows temp is per-user" is a default, not an
      enforcement: with TEMP redirected to a shared location, another local
      account can pre-create the predictable pr-review/<owner>-<repo>/<pr>-<sha>
      tree as real directories, which passes the reparse-point and container
      checks, and then read review state or plant prior-dedupe state that
      suppresses findings.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $ownerSid = (Get-Acl -LiteralPath $Path).GetOwner([System.Security.Principal.SecurityIdentifier])
    }
    catch {
        throw "Refusing to use review workspace '$Path': its owner could not be read ($($_.Exception.Message)). Remove it and re-run."
    }
    if (-not $ownerSid) {
        throw "Refusing to use review workspace '$Path': it reports no owner. Remove it and re-run."
    }
    if ($ownerSid.Value -eq $me.User.Value) { return }

    # Windows can be configured to stamp BUILTIN\Administrators as the owner of
    # everything an elevated member of that group creates. Accept that only when
    # this process is itself elevated — otherwise it is someone else's directory.
    $administrators = [System.Security.Principal.SecurityIdentifier]::new(
        [System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
    if ($ownerSid.Value -eq $administrators.Value -and
        ([System.Security.Principal.WindowsPrincipal]::new($me)).IsInRole(
            [System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        return
    }

    $ownerName = $ownerSid.Value
    try { $ownerName = $ownerSid.Translate([System.Security.Principal.NTAccount]).Value } catch { }
    throw "Refusing to use review workspace '$Path': owned by '$ownerName', not '$($me.Name)'. Remove it and re-run."
}

function Assert-SafeWorkspacePath {
    <#
      The workspace path is predictable (temp/pr-review/<owner>-<repo>/<pr>-<sha>),
      so on a shared host another user can pre-create it — or plant a symlink or
      NTFS junction aimed at somewhere sensitive — and then read the review or
      have this script write through it. Refuse anything that is not a real
      directory belonging to the current user.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop

    if ($item.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
        throw "Refusing to use review workspace '$Path': it is a symlink or junction, not a directory. Remove it and re-run."
    }
    if (-not $item.PSIsContainer) {
        throw "Refusing to use review workspace '$Path': it exists and is not a directory. Remove it and re-run."
    }

    if ($IsWindows) {
        Assert-WindowsWorkspaceOwner -Path $Path
        return
    }

    $owner = $null
    try { $owner = ([string]$item.User).Trim() } catch { $owner = $null }
    if ([string]::IsNullOrWhiteSpace($owner)) {
        # Say so rather than skipping in silence: an unreadable owner means the
        # ownership guarantee is not in force, and the operator needs to know
        # which of the two states they are in.
        Write-Warning "Could not read the owner of review workspace '$Path'. Its ownership could not be verified; on a shared host, treat the review state as untrusted."
        return
    }
    $ownerName = ($owner -split '\s+')[0]
    if ($ownerName -ne [System.Environment]::UserName) {
        throw "Refusing to use review workspace '$Path': owned by '$ownerName', not '$([System.Environment]::UserName)'. Remove it and re-run."
    }
}

function New-OrGetWorkspace {
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$Pr,
        [Parameter(Mandatory)][string]$HeadSha
    )

    $path = Get-WorkspaceRoot -Owner $Owner -Repo $Repo -Pr $Pr -HeadSha $HeadSha

    # Create and lock down every level this script owns — <temp>/pr-review and
    # below — so a pre-existing hostile parent is caught before anything is
    # written under it. The OS temp root itself is not ours to police.
    $repoDir = Split-Path -Parent $path
    $baseDir = Split-Path -Parent $repoDir
    foreach ($dir in @($baseDir, $repoDir, $path)) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -ErrorAction Stop | Out-Null
        }
        Assert-SafeWorkspacePath -Path $dir
        Set-PrivateDirectoryMode -Path $dir
    }

    return $path
}

function New-RunWorkspace {
    <#
      Each -Resolve gets its own directory under <head-workspace>/runs/<runId>.

      A run id alone did not isolate anything while every run still wrote the
      same pinned.json, payload, and evidence files: if run A resolved, run B
      resolved before A posted, then A read B's run id, published under it, and
      B later found that receipt and no-opped — losing B's review entirely.
      Separate directories make that race impossible rather than unlikely.
    #>
    param(
        [Parameter(Mandatory)][string]$Workspace,
        [Parameter(Mandatory)][string]$RunId
    )

    $safeRun = ($RunId -replace '[^A-Za-z0-9._-]', '_')
    if ([string]::IsNullOrWhiteSpace($safeRun)) {
        throw "RunId must contain at least one usable character; got: $RunId"
    }

    $runsDir = Join-Path $Workspace 'runs'
    $runDir = Join-Path $runsDir $safeRun
    foreach ($dir in @($runsDir, $runDir)) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -ErrorAction Stop | Out-Null
        }
        Assert-SafeWorkspacePath -Path $dir
        Set-PrivateDirectoryMode -Path $dir
    }
    return $runDir
}

function Get-WorkspaceMetaPath {
    param([Parameter(Mandatory)][string]$Workspace)
    return Join-Path $Workspace 'pinned.json'
}

function Read-WorkspacePinned {
    param([Parameter(Mandatory)][string]$Workspace)
    $meta = Get-WorkspaceMetaPath -Workspace $Workspace
    if (-not (Test-Path -LiteralPath $meta)) {
        throw "Workspace is missing pinned.json: $Workspace"
    }
    return Read-JsonFile -Path $meta
}

function Find-WorkspaceForPr {
    <#
      Locate an existing workspace for owner/repo/pr (any head). Prefers the
      pinned head recorded in the newest workspace folder.
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$Pr
    )

    $safeOwner = ($Owner -replace '[^A-Za-z0-9._-]', '_')
    $safeRepo = ($Repo -replace '[^A-Za-z0-9._-]', '_')
    $repoDir = Join-Path (Join-Path ([System.IO.Path]::GetTempPath()) 'pr-review') "${safeOwner}-${safeRepo}"
    if (-not (Test-Path -LiteralPath $repoDir)) { return $null }

    $prefix = "$Pr-"
    $candidates = @(Get-ChildItem -LiteralPath $repoDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name.StartsWith($prefix) } |
            Sort-Object LastWriteTime -Descending)
    if ($candidates.Count -eq 0) { return $null }
    return $candidates[0].FullName
}

function Get-NormalizedFullPath {
    param([Parameter(Mandatory)][string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full.Length -gt 3) { $full = $full.TrimEnd([char]'\', [char]'/') }
    return $full
}

function Assert-CanonicalRunWorkspace {
    <#
      -Post is handed a payload path and reads pinned.json from beside it, which
      made the containing directory an input rather than a fact. A crafted
      payload/pinned pair could name the authenticated destination — owner,
      repo, PR — while routing review.json, the receipt, and the markdown
      fallback through a directory this helper never created, a junction
      included.

      So recompute where the run must live from the pinned identity, require an
      exact match, and re-run the workspace safety checks on every ancestor
      before anything is read from or written to it. Returns the canonical path
      for callers to use in place of whatever they were handed.
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$HeadSha,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Workspace
    )

    $safeRun = ($RunId -replace '[^A-Za-z0-9._-]', '_')
    if ([string]::IsNullOrWhiteSpace($safeRun)) {
        throw "pinned.json runId must contain at least one usable character; got: $RunId"
    }

    $canonicalHead = Get-WorkspaceRoot -Owner $Owner -Repo $Repo -Pr $Number -HeadSha $HeadSha
    $runsDir = Join-Path $canonicalHead 'runs'
    $canonicalRun = Get-NormalizedFullPath (Join-Path $runsDir $safeRun)
    $actual = Get-NormalizedFullPath $Workspace

    $comparison = if ($IsWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }
    if (-not [string]::Equals($actual, $canonicalRun, $comparison)) {
        throw ("Refusing to post from '$actual': the run this payload claims " +
            "($Owner/$Repo#$Number run $RunId at head $HeadSha) belongs in '$canonicalRun'. " +
            'Post from the workspace -Resolve created.')
    }

    # Every level this script owns, outermost first, so a hostile parent is
    # caught before the run directory is trusted.
    $repoDir = Split-Path -Parent $canonicalHead
    $baseDir = Split-Path -Parent $repoDir
    foreach ($dir in @($baseDir, $repoDir, $canonicalHead, $runsDir, $canonicalRun)) {
        if (-not (Test-Path -LiteralPath $dir)) {
            throw "Refusing to post: expected run directory '$dir' does not exist. Re-run -Resolve."
        }
        Assert-SafeWorkspacePath -Path $dir
    }

    return $canonicalRun
}

# ---------------------------------------------------------------------------
# Schema validation (native walk — required/enum/const/line shape)
# ---------------------------------------------------------------------------

function Add-Violation {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Path,
        [string]$Message
    )
    $List.Add("${Path}: $Message")
}

function Test-FindingObject {
    param(
        $Finding,
        [string]$Path,
        [System.Collections.Generic.List[string]]$Violations
    )

    foreach ($req in @('severity', 'category', 'file', 'verdict')) {
        if (-not (Test-HasProperty -Object $Finding -Name $req) -or
            $null -eq (Get-PropertyValue -Object $Finding -Name $req) -or
            [string]::IsNullOrWhiteSpace([string](Get-PropertyValue -Object $Finding -Name $req))) {
            Add-Violation -List $Violations -Path $Path -Message "missing required property '$req'"
        }
    }

    $severity = [string](Get-PropertyValue -Object $Finding -Name 'severity')
    if ($severity -and $severity -notin $script:SeverityEnum) {
        Add-Violation -List $Violations -Path "$Path.severity" -Message "must be one of: $($script:SeverityEnum -join ', ')"
    }

    $category = [string](Get-PropertyValue -Object $Finding -Name 'category')
    if ($category -and $category -notin $script:CategoryEnum) {
        Add-Violation -List $Violations -Path "$Path.category" -Message "must be one of: $($script:CategoryEnum -join ', ')"
    }

    $verdict = [string](Get-PropertyValue -Object $Finding -Name 'verdict')
    if ($verdict -and $verdict -notin $script:VerdictEnum) {
        Add-Violation -List $Violations -Path "$Path.verdict" -Message "must be one of: $($script:VerdictEnum -join ', ')"
    }

    foreach ($sideProp in @('side', 'start_side')) {
        if (Test-HasProperty -Object $Finding -Name $sideProp) {
            $sideVal = [string](Get-PropertyValue -Object $Finding -Name $sideProp)
            if ($sideVal -and $sideVal -notin $script:SideEnum) {
                Add-Violation -List $Violations -Path "$Path.$sideProp" -Message "must be LEFT or RIGHT"
            }
        }
    }

    if (Test-HasProperty -Object $Finding -Name 'placement') {
        $placement = [string](Get-PropertyValue -Object $Finding -Name 'placement')
        if ($placement -and $placement -notin $script:PlacementEnum) {
            Add-Violation -List $Violations -Path "$Path.placement" -Message "must be one of: $($script:PlacementEnum -join ', ')"
        }
        if ($placement -eq 'inline' -and $verdict -eq 'PLAUSIBLE') {
            Add-Violation -List $Violations -Path $Path -Message "PLAUSIBLE findings cannot use placement 'inline' (summary-only)"
        }
    }

    $hasLine = (Test-HasProperty -Object $Finding -Name 'line') -and ($null -ne (Get-PropertyValue -Object $Finding -Name 'line'))
    $hasStart = (Test-HasProperty -Object $Finding -Name 'start_line') -and ($null -ne (Get-PropertyValue -Object $Finding -Name 'start_line'))
    if ($hasStart -and -not $hasLine) {
        Add-Violation -List $Violations -Path $Path -Message "start_line requires line"
    }
    if ($hasStart -and $hasLine) {
        $startLine = [int](Get-PropertyValue -Object $Finding -Name 'start_line')
        $line = [int](Get-PropertyValue -Object $Finding -Name 'line')
        if ($startLine -gt $line) {
            Add-Violation -List $Violations -Path $Path -Message "start_line ($startLine) must be <= line ($line)"
        }
    }
}

function Test-ReviewCommentObject {
    param(
        $Comment,
        [string]$Path,
        [System.Collections.Generic.List[string]]$Violations
    )

    foreach ($req in @('path', 'body')) {
        $val = Get-PropertyValue -Object $Comment -Name $req
        if ([string]::IsNullOrWhiteSpace([string]$val)) {
            Add-Violation -List $Violations -Path $Path -Message "missing required property '$req'"
        }
    }

    $hasLine = (Test-HasProperty -Object $Comment -Name 'line') -and ($null -ne (Get-PropertyValue -Object $Comment -Name 'line'))
    $hasStart = (Test-HasProperty -Object $Comment -Name 'start_line') -and ($null -ne (Get-PropertyValue -Object $Comment -Name 'start_line'))
    if (-not $hasLine) {
        Add-Violation -List $Violations -Path $Path -Message "must include 'line' (single-line) or 'start_line'+'line' (multi-line)"
    }
    if ($hasStart -and $hasLine) {
        $startLine = [int](Get-PropertyValue -Object $Comment -Name 'start_line')
        $line = [int](Get-PropertyValue -Object $Comment -Name 'line')
        if ($startLine -gt $line) {
            Add-Violation -List $Violations -Path $Path -Message "start_line ($startLine) must be <= line ($line)"
        }
    }

    foreach ($sideProp in @('side', 'start_side')) {
        if (Test-HasProperty -Object $Comment -Name $sideProp) {
            $sideVal = [string](Get-PropertyValue -Object $Comment -Name $sideProp)
            if ($sideVal -and $sideVal -notin $script:SideEnum) {
                Add-Violation -List $Violations -Path "$Path.$sideProp" -Message "must be LEFT or RIGHT"
            }
        }
    }
}

function Test-ReviewPayloadObject {
    param(
        $Payload,
        [string]$Path,
        [System.Collections.Generic.List[string]]$Violations
    )

    foreach ($req in @('commit_id', 'event', 'body')) {
        if (-not (Test-HasProperty -Object $Payload -Name $req) -or
            $null -eq (Get-PropertyValue -Object $Payload -Name $req) -or
            ($req -ne 'body' -and [string]::IsNullOrWhiteSpace([string](Get-PropertyValue -Object $Payload -Name $req)))) {
            Add-Violation -List $Violations -Path $Path -Message "missing required property '$req'"
        }
    }

    $event = [string](Get-PropertyValue -Object $Payload -Name 'event')
    if ($event -and $event -ne 'COMMENT') {
        Add-Violation -List $Violations -Path "$Path.event" -Message "const must be 'COMMENT' (never APPROVE or REQUEST_CHANGES)"
    }

    $commitId = [string](Get-PropertyValue -Object $Payload -Name 'commit_id')
    if ($commitId -and $commitId.Length -lt 7) {
        Add-Violation -List $Violations -Path "$Path.commit_id" -Message "must be a git SHA (at least 7 chars)"
    }

    if (Test-HasProperty -Object $Payload -Name 'comments') {
        # ConvertFrom-Json unwraps a single-element JSON array to a lone object,
        # so a one-comment payload arrives here as a scalar, not an array. Wrap
        # with @() before iterating (as every other comments reader in this file
        # does); a genuine non-array scalar like a string is still rejected, and
        # malformed items are still caught per-item by Test-ReviewCommentObject.
        $comments = Get-PropertyValue -Object $Payload -Name 'comments'
        if ($null -ne $comments -and $comments -is [string]) {
            Add-Violation -List $Violations -Path "$Path.comments" -Message "must be an array of comment objects"
        }
        else {
            $i = 0
            foreach ($c in @($comments)) {
                Test-ReviewCommentObject -Comment $c -Path "$Path.comments[$i]" -Violations $Violations
                $i++
            }
        }
    }
}

function Get-FindingsArray {
    param($Document)
    if ($null -eq $Document) { return @() }
    if ($Document -is [System.Collections.IEnumerable] -and $Document -isnot [string] -and $Document -isnot [pscustomobject] -and $Document -isnot [hashtable]) {
        return @($Document)
    }
    # ConvertFrom-Json arrays become Object[]
    if ($Document -is [System.Array]) {
        return @($Document)
    }
    if (Test-HasProperty -Object $Document -Name 'findings') {
        $inner = Get-PropertyValue -Object $Document -Name 'findings'
        if ($null -eq $inner) { return @() }
        return @($inner)
    }
    # Single finding object
    if (Test-HasProperty -Object $Document -Name 'severity') {
        return @($Document)
    }
    throw 'Findings JSON must be an array, a { findings: [...] } object, or a single finding object.'
}

function Invoke-Validate {
    param(
        [string]$FindingsPath,
        [string]$PayloadPath
    )

    # Touch schema so missing file fails early (and keeps the schema coupled).
    $null = Get-SchemaDocument

    $violations = [System.Collections.Generic.List[string]]::new()

    if ($FindingsPath) {
        $doc = Read-JsonFile -Path $FindingsPath
        try {
            $items = Get-FindingsArray -Document $doc
        }
        catch {
            Write-Error $_.Exception.Message
            exit 1
        }
        if ($items.Count -eq 0) {
            $violations.Add('findings: array is empty (expected at least one finding to validate)')
        }
        $i = 0
        foreach ($f in $items) {
            Test-FindingObject -Finding $f -Path "findings[$i]" -Violations $violations
            $i++
        }
    }
    elseif ($PayloadPath) {
        $doc = Read-JsonFile -Path $PayloadPath
        Test-ReviewPayloadObject -Payload $doc -Path 'payload' -Violations $violations
    }
    else {
        throw '-Validate requires -Findings <path> or -Payload <path>'
    }

    if ($violations.Count -gt 0) {
        Write-Output 'VALIDATION FAILED'
        foreach ($v in $violations) {
            Write-Output " - $v"
        }
        exit 1
    }

    Write-Output 'VALIDATION OK'
    exit 0
}

# ---------------------------------------------------------------------------
# Fingerprint / dedupe
# ---------------------------------------------------------------------------

function Get-NormalizedSubstance {
    param($Finding)
    $parts = @(
        [string](Get-PropertyValue -Object $Finding -Name 'summary')
        [string](Get-PropertyValue -Object $Finding -Name 'failure_scenario')
        [string](Get-PropertyValue -Object $Finding -Name 'evidence')
        [string](Get-PropertyValue -Object $Finding -Name 'body')
    )
    $text = ($parts -join ' ')
    $text = $text.ToLowerInvariant()
    $text = [regex]::Replace($text, '\s+', ' ').Trim()
    return $text
}

function Get-Sha256Hex {
    param([string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }
    return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

function Get-FindingFingerprint {
    <#
      Exact dedupe key: category, file, range, and normalized substance.

      Repo and PR are deliberately absent. Dedupe is per-PR by workflow — prior
      state is read from this PR's own run directory — so they discriminate
      nothing, and as optional model-populated fields they made the key depend
      on whether the model happened to fill them in: the same defect
      fingerprinted two ways across runs and got reposted, failing open.

      Current findings are model-produced after reading untrusted PR content, so
      any fingerprint already present on the input is ignored — a prompt-injected
      PR can steer a finding to carry an older key and make Invoke-Dedupe drop a
      genuinely new defect as dropped-identical. Keys are always derived for
      current findings; pass -HonorStored only when reading prior review state
      written by an earlier run, which may carry stored keys for backward
      compatibility, falling back to recompute when absent.
    #>
    param(
        $Finding,
        [switch]$HonorStored
    )

    if ($HonorStored) {
        $existing = Get-PropertyValue -Object $Finding -Name 'fingerprint'
        if (-not [string]::IsNullOrWhiteSpace([string]$existing)) {
            return [string]$existing
        }
    }

    $category = [string](Get-PropertyValue -Object $Finding -Name 'category')
    $file = Normalize-PathKey -Path ([string](Get-PropertyValue -Object $Finding -Name 'file'))
    $line = Get-PropertyValue -Object $Finding -Name 'line'
    $startLine = Get-PropertyValue -Object $Finding -Name 'start_line'
    $side = [string](Get-PropertyValue -Object $Finding -Name 'side')
    if (-not $side) { $side = 'RIGHT' }
    $range = if ($null -ne $startLine -and $null -ne $line) {
        "${side}:${startLine}-${line}"
    }
    elseif ($null -ne $line) {
        "${side}:${line}"
    }
    else {
        'none'
    }
    $substance = Get-NormalizedSubstance -Finding $Finding

    $material = (@($category, $file, $range, $substance) -join '|')
    return Get-Sha256Hex -Text $material
}

function Get-FindingContextKey {
    <#
      A line-independent location discriminator: the enclosing symbol, or any
      context/hunk text the reviewer supplied. Line numbers are deliberately
      excluded — surviving an unrelated line shift is the whole point of the
      semantic key. Where a finding carries none of these the key is 'none',
      and one-for-one matching in Invoke-Dedupe is what keeps two
      identically-worded findings apart.
    #>
    param($Finding)

    foreach ($name in @('symbol', 'context', 'hunk_context')) {
        $value = [string](Get-PropertyValue -Object $Finding -Name $name)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return ([regex]::Replace($value.ToLowerInvariant(), '\s+', ' ')).Trim()
        }
    }
    return 'none'
}

function Get-FindingSemanticFingerprint {
    <#
      A location-independent key, so a finding whose line only shifted is
      recognised as the same defect on a rerun.

      Removing location entirely went one step too far: category + file +
      wording cannot tell two separate defects apart when the reviewer
      describes them identically — two methods with the same empty-input null
      deref and the same summary collapsed, and the second finding vanished.
      Any line-independent context the finding carries is folded back in, and
      Invoke-Dedupe matches one-for-one so two sites can never both be spent
      against a single prior finding.

      Current findings are untrusted input for the same reason as the exact
      key: a supplied semanticFingerprint is ignored unless -HonorStored is set
      while reading prior review state. Keys are derived, never accepted from
      model output.
    #>
    param(
        $Finding,
        [switch]$HonorStored
    )

    if ($HonorStored) {
        $existing = Get-PropertyValue -Object $Finding -Name 'semanticFingerprint'
        if (-not [string]::IsNullOrWhiteSpace([string]$existing)) {
            return [string]$existing
        }
    }

    $category = [string](Get-PropertyValue -Object $Finding -Name 'category')
    $file = Normalize-PathKey -Path ([string](Get-PropertyValue -Object $Finding -Name 'file'))
    $context = Get-FindingContextKey -Finding $Finding
    $substance = Get-NormalizedSubstance -Finding $Finding

    $material = (@($category, $file, $context, $substance) -join '|')
    return Get-Sha256Hex -Text $material
}

function Add-SemanticOccurrence {
    param(
        [Parameter(Mandatory)][System.Collections.Generic.Dictionary[string, int]]$Counts,
        [string]$Key
    )
    if ([string]::IsNullOrWhiteSpace($Key)) { return }
    if ($Counts.ContainsKey($Key)) { $Counts[$Key] = $Counts[$Key] + 1 }
    else { $Counts[$Key] = 1 }
}

function Use-SemanticOccurrence {
    <#
      Consume one prior occurrence of a semantic key, returning whether one was
      available. Semantic matching is one-for-one: a prior review that raised a
      defect once can silence exactly one current finding, so a second distinct
      site described in the same words survives instead of disappearing.
    #>
    param(
        [Parameter(Mandatory)][System.Collections.Generic.Dictionary[string, int]]$Counts,
        [string]$Key
    )
    if ([string]::IsNullOrWhiteSpace($Key)) { return $false }
    if (-not $Counts.ContainsKey($Key)) { return $false }
    if ($Counts[$Key] -le 0) { return $false }
    $Counts[$Key] = $Counts[$Key] - 1
    return $true
}

function Invoke-Fingerprint {
    param([Parameter(Mandatory)][string]$FindingsPath)

    $doc = Read-JsonFile -Path $FindingsPath
    $items = Get-FindingsArray -Document $doc
    $clean = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $items) {
        $clean.Add([pscustomobject]@{
                file                = [string](Get-PropertyValue -Object $f -Name 'file')
                category            = [string](Get-PropertyValue -Object $f -Name 'category')
                severity            = [string](Get-PropertyValue -Object $f -Name 'severity')
                verdict             = [string](Get-PropertyValue -Object $f -Name 'verdict')
                fingerprint         = Get-FindingFingerprint -Finding $f
                semanticFingerprint = Get-FindingSemanticFingerprint -Finding $f
            })
    }
    Write-Output ($clean | ConvertTo-Json -Depth 10)
}

function Get-PriorFingerprints {
    param($PriorDocument)

    $exactSet = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    # Semantic keys are counted, not just present: the count is how many current
    # findings a prior review is entitled to silence for that key.
    $semanticCounts = [System.Collections.Generic.Dictionary[string, int]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    if ($null -eq $PriorDocument) { return [pscustomobject]@{ exact = $exactSet; semantic = $semanticCounts } }

    # Each shape below is an independent *view* of the same prior review, so the
    # counts are merged by maximum, not by sum. A document carrying both a
    # findings array and a matching semanticFingerprints list describes one
    # finding twice, and summing would hand it a budget of two — enough to
    # silence a genuinely distinct second site all over again.
    $views = [System.Collections.Generic.List[System.Collections.Generic.Dictionary[string, int]]]::new()

    # Accept: findings array/object, { fingerprints: [...] }, { findings: [...] },
    # or prior review state with nested findings.
    if (Test-HasProperty -Object $PriorDocument -Name 'fingerprints') {
        foreach ($fp in @((Get-PropertyValue -Object $PriorDocument -Name 'fingerprints'))) {
            if (-not [string]::IsNullOrWhiteSpace([string]$fp)) { [void]$exactSet.Add([string]$fp) }
        }
    }
    if (Test-HasProperty -Object $PriorDocument -Name 'semanticFingerprints') {
        $view = [System.Collections.Generic.Dictionary[string, int]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        foreach ($sfp in @((Get-PropertyValue -Object $PriorDocument -Name 'semanticFingerprints'))) {
            Add-SemanticOccurrence -Counts $view -Key ([string]$sfp)
        }
        $views.Add($view)
    }

    try {
        $items = Get-FindingsArray -Document $PriorDocument
        $view = [System.Collections.Generic.Dictionary[string, int]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        foreach ($f in $items) {
            $fp = Get-FindingFingerprint -Finding $f -HonorStored
            if ($fp) { [void]$exactSet.Add($fp) }

            Add-SemanticOccurrence -Counts $view -Key (Get-FindingSemanticFingerprint -Finding $f -HonorStored)
        }
        $views.Add($view)
    }
    catch {
        # Prior may be a posting-result style object without findings — ignore.
    }

    if (Test-HasProperty -Object $PriorDocument -Name 'priorFindings') {
        $view = [System.Collections.Generic.Dictionary[string, int]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        foreach ($f in @((Get-PropertyValue -Object $PriorDocument -Name 'priorFindings'))) {
            $fp = Get-FindingFingerprint -Finding $f -HonorStored
            if ($fp) { [void]$exactSet.Add($fp) }

            Add-SemanticOccurrence -Counts $view -Key (Get-FindingSemanticFingerprint -Finding $f -HonorStored)
        }
        $views.Add($view)
    }

    foreach ($view in $views) {
        foreach ($pair in $view.GetEnumerator()) {
            if (-not $semanticCounts.ContainsKey($pair.Key) -or $semanticCounts[$pair.Key] -lt $pair.Value) {
                $semanticCounts[$pair.Key] = $pair.Value
            }
        }
    }

    return [pscustomobject]@{ exact = $exactSet; semantic = $semanticCounts }
}

function Invoke-Dedupe {
    param(
        [Parameter(Mandatory)][string]$FindingsPath,
        [Parameter(Mandatory)][string]$PriorPath
    )

    $doc = Read-JsonFile -Path $FindingsPath
    $prior = Read-JsonFile -Path $PriorPath
    $items = Get-FindingsArray -Document $doc
    $priorSets = Get-PriorFingerprints -PriorDocument $prior

    $kept = [System.Collections.Generic.List[object]]::new()
    $dropped = [System.Collections.Generic.List[object]]::new()

    foreach ($f in $items) {
        $fp = Get-FindingFingerprint -Finding $f
        $sfp = Get-FindingSemanticFingerprint -Finding $f
        # Attach fingerprint onto a shallow copy dictionary for output.
        $hash = [ordered]@{}
        foreach ($p in $f.PSObject.Properties) {
            $hash[$p.Name] = $p.Value
        }
        $hash['fingerprint'] = $fp
        $hash['semanticFingerprint'] = $sfp

        if ($priorSets.exact.Contains($fp)) {
            # An identical prior finding also accounts for one occurrence of the
            # semantic key. Without spending it here, a second distinct site
            # worded the same way would be dropped against a budget this
            # finding already consumed.
            [void](Use-SemanticOccurrence -Counts $priorSets.semantic -Key $sfp)
            $hash['dedupe'] = 'dropped-identical'
            $dropped.Add([pscustomobject]$hash)
        }
        elseif (Use-SemanticOccurrence -Counts $priorSets.semantic -Key $sfp) {
            $hash['dedupe'] = 'dropped-semantic'
            $dropped.Add([pscustomobject]$hash)
        }
        else {
            $hash['dedupe'] = 'kept'
            $kept.Add([pscustomobject]$hash)
        }
    }

    $result = [pscustomobject]@{
        kept    = @($kept)
        dropped = @($dropped)
        keptCount = $kept.Count
        droppedCount = $dropped.Count
    }
    Write-Output ($result | ConvertTo-Json -Depth 100)
}

# ---------------------------------------------------------------------------
# Build payload / markdown
# ---------------------------------------------------------------------------

function Get-BodyText {
    <#
      Text and file are separate inputs on purpose.

      The old single -Body read its value as a file whenever that value happened
      to name an existing one. In a workflow whose whole job is to summarize
      untrusted PR text and then publish the result, that made any body naming a
      local path — `~/.config/gh/hosts.yml`, an .env, a private key — silently
      swap itself for that file's contents and post them to GitHub. Body text is
      therefore never probed as a path, and a body file must live inside the
      workspace root this script owns.
    #>
    param([string]$BodyText, [string]$BodyFile)

    if ([string]::IsNullOrEmpty($BodyFile)) {
        return $BodyText
    }

    $full = [System.IO.Path]::GetFullPath($BodyFile)
    $root = [System.IO.Path]::GetFullPath((Join-Path ([System.IO.Path]::GetTempPath()) 'pr-review'))
    $rootPrefix = $root.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) +
        [System.IO.Path]::DirectorySeparatorChar
    $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    if (-not $full.StartsWith($rootPrefix, $comparison)) {
        throw "-BodyFile must live inside the review workspace root '$root'; refusing to read '$full'."
    }

    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ($item.PSIsContainer) {
        throw "-BodyFile is a directory, not a file: $full"
    }
    if ($item.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
        # Otherwise the containment check above is decorative: a symlink inside
        # the workspace can point anywhere.
        throw "-BodyFile is a symlink or reparse point; refusing to read '$full'."
    }

    return (Get-Content -LiteralPath $full -Raw -Encoding utf8)
}

function Format-InlineCommentBody {
    param($Finding)

    $explicit = Get-PropertyValue -Object $Finding -Name 'body'
    if (-not [string]::IsNullOrWhiteSpace([string]$explicit)) {
        return [string]$explicit
    }

    $severity = [string](Get-PropertyValue -Object $Finding -Name 'severity')
    $category = [string](Get-PropertyValue -Object $Finding -Name 'category')
    $summary = [string](Get-PropertyValue -Object $Finding -Name 'summary')
    $failure = [string](Get-PropertyValue -Object $Finding -Name 'failure_scenario')
    $evidence = [string](Get-PropertyValue -Object $Finding -Name 'evidence')
    $suggestion = [string](Get-PropertyValue -Object $Finding -Name 'suggestion')

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("**${severity}** · ${category}")
    if ($summary) { $lines.Add($summary) }
    if ($failure) { $lines.Add(""); $lines.Add("Failure scenario: $failure") }
    if ($evidence) { $lines.Add(""); $lines.Add("Evidence: $evidence") }
    if ($suggestion) {
        $lines.Add('')
        $lines.Add('```suggestion')
        $lines.Add($suggestion)
        $lines.Add('```')
    }
    return ($lines -join "`n")
}

function Test-IsInlineEligible {
    param($Finding)

    $verdict = [string](Get-PropertyValue -Object $Finding -Name 'verdict')
    if ($verdict -ne 'CONFIRMED') { return $false }

    $placement = [string](Get-PropertyValue -Object $Finding -Name 'placement')
    if ($placement -eq 'summary' -or $placement -eq 'file') { return $false }

    $file = [string](Get-PropertyValue -Object $Finding -Name 'file')
    $line = Get-PropertyValue -Object $Finding -Name 'line'
    if ([string]::IsNullOrWhiteSpace($file)) { return $false }
    if ($null -eq $line) { return $false }
    if ($placement -eq 'inline' -or [string]::IsNullOrWhiteSpace($placement)) { return $true }
    return $false
}

function New-ReviewCommentFromFinding {
    param($Finding)

    $comment = [ordered]@{
        path = [string](Get-PropertyValue -Object $Finding -Name 'file')
        body = Format-InlineCommentBody -Finding $Finding
        line = [int](Get-PropertyValue -Object $Finding -Name 'line')
    }

    $side = Get-PropertyValue -Object $Finding -Name 'side'
    if ($side) { $comment['side'] = [string]$side } else { $comment['side'] = 'RIGHT' }

    $startLine = Get-PropertyValue -Object $Finding -Name 'start_line'
    if ($null -ne $startLine) {
        $comment['start_line'] = [int]$startLine
        $startSide = Get-PropertyValue -Object $Finding -Name 'start_side'
        if ($startSide) {
            $comment['start_side'] = [string]$startSide
        }
        else {
            $comment['start_side'] = [string]$comment['side']
        }
    }

    return [pscustomobject]$comment
}

function Invoke-BuildPayload {
    param(
        [Parameter(Mandatory)][string]$FindingsPath,
        [Parameter(Mandatory)][string]$BaseSha,
        [Parameter(Mandatory)][string]$HeadSha,
        [string]$BodyText,
        [string]$BodyFile
    )

    $null = $BaseSha  # reserved for callers/workspace symmetry; payload uses head
    $doc = Read-JsonFile -Path $FindingsPath
    $items = Get-FindingsArray -Document $doc
    $violations = [System.Collections.Generic.List[string]]::new()
    $i = 0
    foreach ($f in $items) {
        Test-FindingObject -Finding $f -Path "findings[$i]" -Violations $violations
        $i++
    }
    if ($violations.Count -gt 0) {
        Write-Output 'VALIDATION FAILED (findings)'
        foreach ($v in $violations) { Write-Output " - $v" }
        exit 1
    }

    # Not $bodyText: PowerShell variable names are case-insensitive, so that would
    # assign straight back into the $BodyText parameter.
    $summaryBody = Get-BodyText -BodyText $BodyText -BodyFile $BodyFile
    $comments = [System.Collections.Generic.List[object]]::new()
    $summaryOnly = [System.Collections.Generic.List[object]]::new()

    foreach ($f in $items) {
        if (Test-IsInlineEligible -Finding $f) {
            $comments.Add((New-ReviewCommentFromFinding -Finding $f))
        }
        else {
            $summaryOnly.Add($f)
        }
    }

    # PLAUSIBLE / non-inline findings are never inline; surface them briefly if
    # the caller did not already mention them (append only when summary-only list
    # is non-empty and body lacks an explicit Questions heading).
    if ($summaryOnly.Count -gt 0 -and $summaryBody -notmatch '(?m)^##\s+Questions\b') {
        $q = [System.Collections.Generic.List[string]]::new()
        $q.Add('')
        $q.Add('## Questions / non-inline findings')
        foreach ($f in $summaryOnly) {
            $verdict = [string](Get-PropertyValue -Object $f -Name 'verdict')
            $sev = [string](Get-PropertyValue -Object $f -Name 'severity')
            $cat = [string](Get-PropertyValue -Object $f -Name 'category')
            $sum = [string](Get-PropertyValue -Object $f -Name 'summary')
            $file = [string](Get-PropertyValue -Object $f -Name 'file')
            $q.Add("- [$verdict] **$sev**/$cat ``$file`` — $sum")
        }
        $summaryBody = $summaryBody.TrimEnd() + "`n" + ($q -join "`n") + "`n"
    }

    $payload = [pscustomobject]@{
        commit_id = $HeadSha
        event     = 'COMMENT'
        body      = $summaryBody
        comments  = @($comments)
    }

    $payloadViolations = [System.Collections.Generic.List[string]]::new()
    Test-ReviewPayloadObject -Payload $payload -Path 'payload' -Violations $payloadViolations
    if ($payloadViolations.Count -gt 0) {
        Write-Output 'VALIDATION FAILED (payload)'
        foreach ($v in $payloadViolations) { Write-Output " - $v" }
        exit 1
    }

    Write-Output ($payload | ConvertTo-Json -Depth 100)
}

function ConvertTo-ReviewMarkdown {
    param($Payload)

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('# Pull request review (manual fallback)')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("commit_id: ``$($Payload.commit_id)``")
    [void]$sb.AppendLine('event: COMMENT')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('## Summary')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine([string]$Payload.body)
    [void]$sb.AppendLine()

    $comments = @()
    if (Test-HasProperty -Object $Payload -Name 'comments') {
        $comments = @((Get-PropertyValue -Object $Payload -Name 'comments'))
    }
    if ($comments.Count -gt 0) {
        [void]$sb.AppendLine('## Inline comments')
        [void]$sb.AppendLine()
        $n = 1
        foreach ($c in $comments) {
            $path = [string](Get-PropertyValue -Object $c -Name 'path')
            $line = Get-PropertyValue -Object $c -Name 'line'
            $start = Get-PropertyValue -Object $c -Name 'start_line'
            $side = [string](Get-PropertyValue -Object $c -Name 'side')
            if (-not $side) { $side = 'RIGHT' }
            $loc = if ($null -ne $start) { "${path}:${start}-${line} ($side)" } else { "${path}:${line} ($side)" }
            [void]$sb.AppendLine("### Comment $n — ``$loc``")
            [void]$sb.AppendLine()
            [void]$sb.AppendLine([string](Get-PropertyValue -Object $c -Name 'body'))
            [void]$sb.AppendLine()
            $n++
        }
    }

    return $sb.ToString()
}

function Invoke-MarkdownFallback {
    param([Parameter(Mandatory)][string]$PayloadPath)
    $payload = Read-JsonFile -Path $PayloadPath
    $violations = [System.Collections.Generic.List[string]]::new()
    Test-ReviewPayloadObject -Payload $payload -Path 'payload' -Violations $violations
    if ($violations.Count -gt 0) {
        Write-Output 'VALIDATION FAILED'
        foreach ($v in $violations) { Write-Output " - $v" }
        exit 1
    }
    Write-Output (ConvertTo-ReviewMarkdown -Payload $payload)
}

# ---------------------------------------------------------------------------
# Diff line map (for publish-time path/range checks)
# ---------------------------------------------------------------------------

function Get-DiffLineMap {
    <#
      Parse unified patches from the PR files list into a map:
        path -> @{ RIGHT = HashSet[int]; LEFT = HashSet[int] }

      Each hunk consumes exactly the line counts its header declares. An empty
      patch line has to count as context — GitHub strips the single leading
      space from a blank context line, so a blank line inside a hunk arrives as
      '' — but that also makes any stray trailing '' look like one more context
      line. A patch ending in a newline splits to a final '' and used to admit a
      phantom EOF+1 line on both sides: it passes local validation, GitHub 422s
      the whole review, and the remap retry then finds nothing left to fix and
      demotes *every* inline comment to the summary. Honouring the declared
      counts makes the phantom unrepresentable rather than merely unlikely.
    #>
    param($Files)

    $map = @{}
    foreach ($f in @($Files)) {
        $filename = [string](Get-PropertyValue -Object $f -Name 'filename')
        if (-not $filename) { continue }
        $key = Normalize-PathKey -Path $filename
        $right = [System.Collections.Generic.HashSet[int]]::new()
        $left = [System.Collections.Generic.HashSet[int]]::new()

        $patch = [string](Get-PropertyValue -Object $f -Name 'patch')
        if ($patch) {
            $oldLine = 0
            $newLine = 0
            # Lines still owed to the current hunk. Zero outside a hunk, so a
            # patch whose first line is not a header contributes nothing rather
            # than mapping lines from an assumed origin.
            $oldRemaining = 0
            $newRemaining = 0
            foreach ($raw in ($patch -split "`n")) {
                $line = $raw.TrimEnd("`r")
                if ($line -match '^@@\s+-([0-9]+)(?:,([0-9]+))?\s+\+([0-9]+)(?:,([0-9]+))?\s@@') {
                    $oldLine = [int]$Matches[1]
                    $newLine = [int]$Matches[3]
                    # An absent count means 1 line, per the unified-diff format.
                    $oldRemaining = if ($Matches[2]) { [int]$Matches[2] } else { 1 }
                    $newRemaining = if ($Matches[4]) { [int]$Matches[4] } else { 1 }
                    continue
                }
                if ($line.StartsWith('+++') -or $line.StartsWith('---') -or $line.StartsWith('\') -or $line.StartsWith('diff ')) {
                    continue
                }
                if ($line.StartsWith('+')) {
                    if ($newRemaining -le 0) { continue }
                    [void]$right.Add($newLine)
                    $newLine++
                    $newRemaining--
                }
                elseif ($line.StartsWith('-')) {
                    if ($oldRemaining -le 0) { continue }
                    [void]$left.Add($oldLine)
                    $oldLine++
                    $oldRemaining--
                }
                elseif ($line.StartsWith(' ') -or $line -eq '') {
                    # Context spends one line on each side, so it is only a real
                    # context line while both sides still owe one.
                    if ($oldRemaining -le 0 -or $newRemaining -le 0) { continue }
                    [void]$right.Add($newLine)
                    [void]$left.Add($oldLine)
                    $newLine++
                    $oldLine++
                    $newRemaining--
                    $oldRemaining--
                }
            }
        }

        $map[$key] = @{
            RIGHT    = $right
            LEFT     = $left
            filename = $filename
            status   = [string](Get-PropertyValue -Object $f -Name 'status')
        }
    }
    return $map
}

function Test-CommentAgainstDiff {
    param(
        $Comment,
        $DiffMap,
        [System.Collections.Generic.List[string]]$Problems
    )

    $path = [string](Get-PropertyValue -Object $Comment -Name 'path')
    $key = Normalize-PathKey -Path $path
    if (-not $DiffMap.ContainsKey($key)) {
        $Problems.Add("path not in pinned diff: $path")
        return
    }

    $side = [string](Get-PropertyValue -Object $Comment -Name 'side')
    if (-not $side) { $side = 'RIGHT' }
    $line = [int](Get-PropertyValue -Object $Comment -Name 'line')
    $set = $DiffMap[$key][$side]
    if ($null -eq $set -or -not $set.Contains($line)) {
        $Problems.Add("line $line ($side) not in diff hunks for $path")
    }

    $startLine = Get-PropertyValue -Object $Comment -Name 'start_line'
    if ($null -ne $startLine) {
        $startSide = [string](Get-PropertyValue -Object $Comment -Name 'start_side')
        if (-not $startSide) { $startSide = $side }
        $startSet = $DiffMap[$key][$startSide]
        if ($null -eq $startSet -or -not $startSet.Contains([int]$startLine)) {
            $Problems.Add("start_line $startLine ($startSide) not in diff hunks for $path")
        }
    }
}

# ---------------------------------------------------------------------------
# Resolve
# ---------------------------------------------------------------------------

function Parse-PrTarget {
    param([string]$Target)

    $owner = $null
    $repo = $null
    $number = $null

    if ([string]::IsNullOrWhiteSpace($Target)) {
        Assert-GhPresent
        $raw = Invoke-Gh -Action 'resolving PR for current branch' -GhArgs @(
            'pr', 'view', '--json', 'number,url,baseRefName,headRefName'
        )
        $pr = ConvertFrom-GhJson -Text $raw.Text -Action 'parsing current-branch PR'
        $number = [int]$pr.number
        $repoRaw = Invoke-Gh -Action 'resolving current repository' -GhArgs @(
            'repo', 'view', '--json', 'nameWithOwner', '-q', '.nameWithOwner'
        )
        $full = $repoRaw.Text.Trim()
        if ($full -notmatch '^([^/]+)/([^/]+)$') {
            throw "Unexpected repo nameWithOwner: $full"
        }
        $owner = $Matches[1]
        $repo = $Matches[2]
        return [pscustomobject]@{ Owner = $owner; Repo = $repo; Number = $number }
    }

    if ($Target -match '^(?:https://)?(?:www\.)?github\.com/([^/]+)/([^/]+)/pull/([0-9]+)') {
        return [pscustomobject]@{
            Owner  = $Matches[1]
            Repo   = $Matches[2]
            Number = [int]$Matches[3]
        }
    }

    if ($Target -match '^[0-9]+$') {
        Assert-GhPresent
        $repoRaw = Invoke-Gh -Action 'resolving current repository' -GhArgs @(
            'repo', 'view', '--json', 'nameWithOwner', '-q', '.nameWithOwner'
        )
        $full = $repoRaw.Text.Trim()
        if ($full -notmatch '^([^/]+)/([^/]+)$') {
            throw "Unexpected repo nameWithOwner: $full"
        }
        return [pscustomobject]@{
            Owner  = $Matches[1]
            Repo   = $Matches[2]
            Number = [int]$Target
        }
    }

    throw "Unrecognized -Resolve target (expected integer, GitHub PR URL, or empty): $Target"
}

function Merge-CheckRunPages {
    <#
      The check-runs endpoint wraps its array in an envelope, so paginating it
      yields one `{ total_count, check_runs }` object per page. Merge them into a
      single envelope with the true total.
    #>
    param([object[]]$Pages)

    $runs = [System.Collections.Generic.List[object]]::new()
    foreach ($page in @($Pages)) {
        if ($null -eq $page) { continue }
        if (-not (Test-HasProperty -Object $page -Name 'check_runs')) { continue }
        foreach ($run in @((Get-PropertyValue -Object $page -Name 'check_runs'))) {
            if ($null -ne $run) { $runs.Add($run) }
        }
    }

    return [pscustomobject]@{
        total_count = $runs.Count
        check_runs  = $runs.ToArray()
    }
}

function Get-ReviewThreads {
    <#
      Cursor-page every review thread. Coverage that stopped short is reported
      rather than silently truncated: dedupe treats "no prior thread" as "new
      finding", so a quietly capped fetch reposts comments that already exist.

      Returns { threads, complete, incompleteReason, truncatedThreads, pagesFetched }.
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$Number,
        [int]$MaxPages = 20
    )

    $query = @'
query($owner:String!, $repo:String!, $number:Int!, $cursor:String) {
  repository(owner:$owner, name:$repo) {
    pullRequest(number:$number) {
      reviewThreads(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          isResolved
          isOutdated
          comments(first: 100) {
            totalCount
            pageInfo { hasNextPage }
            nodes {
              id
              databaseId
              body
              path
              diffHunk
              originalCommit { oid }
              commit { oid }
            }
          }
        }
      }
    }
  }
}
'@

    $nodes = [System.Collections.Generic.List[object]]::new()
    $truncated = [System.Collections.Generic.List[string]]::new()
    $complete = $true
    $reason = $null
    $cursor = $null
    $pagesFetched = 0

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("pr-review-threads-{0}.graphql" -f [guid]::NewGuid().ToString('n'))
    try {
        Set-Content -LiteralPath $tmp -Value $query -Encoding utf8

        while ($true) {
            $ghArgs = @(
                'api', 'graphql',
                '-f', "owner=$Owner",
                '-f', "repo=$Repo",
                '-F', "number=$Number",
                '-F', "query=@$tmp"
            )
            if (-not [string]::IsNullOrEmpty($cursor)) { $ghArgs += @('-f', "cursor=$cursor") }

            $raw = Invoke-Gh -Action 'fetching review threads' -GhArgs $ghArgs -AllowFailure
            if ($raw.ExitCode -ne 0) {
                Write-Warning "Could not fetch review threads (continuing without them): $($raw.Text.Trim())"
                $complete = $false
                $reason = "GraphQL request failed: $($raw.Text.Trim())"
                break
            }

            $root = $null
            try { $root = $raw.Text | ConvertFrom-Json -Depth 100 }
            catch { $root = $null }

            if (Test-HasProperty -Object $root -Name 'errors') {
                $errs = Get-PropertyValue -Object $root -Name 'errors'
                if ($null -ne $errs -and @($errs).Count -gt 0) {
                    $complete = $false
                    $msgs = [System.Collections.Generic.List[string]]::new()
                    foreach ($e in @($errs)) {
                        # Parenthesise the first operand: an unparenthesised
                        # `cmd -a x -and ...` binds `-and` as an argument to the
                        # command instead of composing a boolean, silently
                        # dropping the null guard.
                        $msg = Get-PropertyValue -Object $e -Name 'message'
                        if (-not [string]::IsNullOrWhiteSpace([string]$msg)) {
                            $msgs.Add([string]$msg)
                        }
                        else {
                            $msgs.Add([string]$e)
                        }
                    }
                    $errText = ($msgs -join '; ')
                    if ([string]::IsNullOrEmpty($reason)) {
                        $reason = $errText
                    } else {
                        $reason += "; $errText"
                    }
                }
            }

            $rt = $null
            try {
                if ($null -ne $root -and (Test-HasProperty -Object $root -Name 'data')) {
                    $rt = $root.data.repository.pullRequest.reviewThreads
                }
            }
            catch { $rt = $null }

            if ($null -eq $rt) {
                Write-Warning 'Review threads response contained no thread data (continuing without them).'
                $complete = $false
                $noData = 'GraphQL response contained no reviewThreads data'
                if ([string]::IsNullOrEmpty($reason)) {
                    $reason = $noData
                } else {
                    $reason += "; $noData"
                }
                break
            }

            foreach ($node in @($rt.nodes)) {
                if ($null -eq $node) { continue }
                $nodes.Add($node)
                $moreComments = $false
                try { $moreComments = [bool]$node.comments.pageInfo.hasNextPage } catch { $moreComments = $false }
                if ($moreComments) { $truncated.Add([string]$node.id) }
            }
            $pagesFetched++

            $hasNext = $false
            try { $hasNext = [bool]$rt.pageInfo.hasNextPage } catch { $hasNext = $false }
            if (-not $hasNext) { break }

            if ($pagesFetched -ge $MaxPages) {
                $complete = $false
                $reason = "Stopped after $MaxPages pages of review threads; later threads were not fetched."
                break
            }
            $cursor = [string]$rt.pageInfo.endCursor
        }
    }
    finally {
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    }

    if ($truncated.Count -gt 0) {
        $complete = $false
        if ([string]::IsNullOrEmpty($reason)) {
            $reason = "$($truncated.Count) thread(s) hold more than 100 comments; the later comments were not fetched."
        }
    }

    return [pscustomobject]@{
        threads          = $nodes.ToArray()
        complete         = $complete
        incompleteReason = $reason
        truncatedThreads = $truncated.ToArray()
        pagesFetched     = $pagesFetched
    }
}

function Invoke-Resolve {
    param([string]$Target)

    Assert-GhPresent
    # Not $target: PowerShell variable names are case-insensitive, so assigning
    # here would land back in the [string]-typed $Target parameter and stringify
    # the parsed object.
    $parsed = Parse-PrTarget -Target $Target
    $owner = $parsed.Owner
    $repo = $parsed.Repo
    $number = $parsed.Number
    $apiBase = "repos/$owner/$repo"

    $prRaw = Invoke-Gh -Action "fetching PR #$number" -GhArgs @(
        'api', "$apiBase/pulls/$number"
    )
    $pr = ConvertFrom-GhJson -Text $prRaw.Text -Action "parsing PR #$number"

    $baseSha = [string]$pr.base.sha
    $headSha = [string]$pr.head.sha
    $baseRef = [string]$pr.base.ref
    $headRef = [string]$pr.head.ref

    # The diff itself comes from the SHA-addressed compare endpoint, with the
    # same pinned-tree proof the post path uses before it will trust the mutable
    # /pulls/<n>/files fallback. The closing pair re-read below cannot substitute
    # for this: an author controls the branch, so pushing a decoy and force-
    # pushing back before that check is cheap, and it would leave a B-shaped file
    # list under a pair that still reads as A. Publication would stay safe — it
    # re-derives placements from the pin — but every review pass reasons from
    # this evidence, so the review itself would be about the wrong diff.
    $expectedFileCount = 0
    if (Test-HasProperty -Object $pr -Name 'changed_files') {
        $expectedFileCount = [int](Get-PropertyValue -Object $pr -Name 'changed_files')
    }
    $resolvedFiles = Get-PinnedDiffFiles -Owner $owner -Repo $repo -Number $number `
        -BaseSha $baseSha -HeadSha $headSha -ExpectedFileCount $expectedFileCount
    $files = @($resolvedFiles.Files)

    $commits = @((Invoke-GhPaginated -Action 'fetching commits' -Path "$apiBase/pulls/$number/commits").Items)
    $reviews = @((Invoke-GhPaginated -Action 'fetching reviews' -Path "$apiBase/pulls/$number/reviews").Items)

    # Review threads (GraphQL) — resolved/unresolved state for incremental dedupe.
    # Cursor-paged: a busy PR has more than one page of threads, and silently
    # keeping the first 100 would make dedupe repost findings already commented on.
    $threads = Get-ReviewThreads -Owner $owner -Repo $repo -Number $number

    $ciResult = Invoke-GhPaginated -Action 'fetching check status' -Path "$apiBase/commits/$headSha/check-runs" -AllowFailure
    $ci = $null
    if ($ciResult.ExitCode -eq 0) {
        $ci = Merge-CheckRunPages -Pages $ciResult.Pages
    }
    else {
        # Fallback: combined status
        $statusRaw = Invoke-Gh -Action 'fetching combined status' -GhArgs @(
            'api', "$apiBase/commits/$headSha/status"
        ) -AllowFailure
        if ($statusRaw.ExitCode -eq 0) {
            $ci = ConvertFrom-GhJson -Text $statusRaw.Text -Action 'parsing combined status'
        }
        else {
            Write-Warning 'Could not fetch CI/check state; continuing without it.'
            $ci = [pscustomobject]@{ warning = 'CI state unavailable' }
        }
    }

    # Everything above is six paginated reads of mutable state taken one after
    # another. A push — or a push and a revert — during that window leaves files
    # from one diff beside commits, reviews and checks from another, under a
    # pinned.json that looks perfectly valid; nothing downstream can tell. Close
    # the gather by re-reading the pair and abort if either moved, matching what
    # publication does. Aborting rather than recording partial coverage is
    # deliberate: this evidence is what every later pass reasons from, and a
    # resolve is cheap to redo. It runs before the workspace exists, so a run
    # that fails here leaves nothing half-written behind.
    [void](Assert-PinnedPair -Owner $owner -Repo $repo -Number $number `
            -PinnedBase $baseSha -PinnedHead $headSha -PayloadHead $headSha `
            -Stage 'trust the gathered evidence')

    $headWorkspace = New-OrGetWorkspace -Owner $owner -Repo $repo -Pr $number -HeadSha $headSha

    # Each explicit -Resolve mints a run id and owns a directory named by it. The
    # receipt lives there, so retrying one run stays idempotent while a
    # deliberate re-review of an unchanged head still publishes its own summary —
    # and two concurrent runs over one head cannot overwrite each other's state.
    $runId = [guid]::NewGuid().ToString('n').Substring(0, 12)
    $workspace = New-RunWorkspace -Workspace $headWorkspace -RunId $runId

    $pinned = [pscustomobject]@{
        owner     = $owner
        repo      = $repo
        pr        = $number
        runId     = $runId
        baseSha   = $baseSha
        headSha   = $headSha
        baseRef   = $baseRef
        headRef   = $headRef
        title     = [string]$pr.title
        htmlUrl   = [string]$pr.html_url
        resolvedAt = (Get-Date).ToUniversalTime().ToString('o')
        workspace = $workspace
        headWorkspace = $headWorkspace
    }

    Write-JsonFile -Value $pinned -Path (Join-Path $workspace 'pinned.json')
    Write-JsonFile -Value $pr -Path (Join-Path $workspace 'pr.json')
    Write-JsonFile -Value $files -Path (Join-Path $workspace 'changed-files.json')
    Write-JsonFile -Value $commits -Path (Join-Path $workspace 'commits.json')
    Write-JsonFile -Value $reviews -Path (Join-Path $workspace 'reviews.json')
    Write-JsonFile -Value $threads -Path (Join-Path $workspace 'review-threads.json')
    Write-JsonFile -Value $ci -Path (Join-Path $workspace 'ci.json')

    # Head-level pointer so a human reading the workspace has one obvious entry
    # point. Runs never read it, so a concurrent run overwriting it is harmless.
    Write-JsonFile -Value ([pscustomobject]@{
            runId     = $runId
            workspace = $workspace
            headSha   = $headSha
            resolvedAt = $pinned.resolvedAt
        }) -Path (Join-Path $headWorkspace 'latest-run.json')

    Write-Output "Resolved PR $owner/$repo#$number"
    Write-Output "baseSha: $baseSha"
    Write-Output "headSha: $headSha"
    Write-Output "runId: $runId"
    Write-Output "workspace: $workspace"
    Write-Output "changedFiles: $($files.Count)  commits: $($commits.Count)  reviews: $($reviews.Count)  threads: $($threads.threads.Count)"
    if (-not $resolvedFiles.Complete) {
        Write-Output "fileCoverage: INCOMPLETE — $($resolvedFiles.Reason)"
    }
    if (-not $threads.complete) {
        Write-Output "threadCoverage: INCOMPLETE — $($threads.incompleteReason)"
    }
}

# ---------------------------------------------------------------------------
# Post
# ---------------------------------------------------------------------------

function Get-PostResultPath {
    <#
      The receipt lives in the run's own directory, so it is scoped by run
      rather than by head SHA. Keying it by head made a deliberate re-review of
      an unchanged head a silent no-op even when it had new findings; scoping it
      by run keeps retries of one run idempotent while letting the next explicit
      run publish its own summary. The runId recorded inside the receipt is
      checked too, so a legacy flat workspace cannot pass one run's receipt off
      as another's.
    #>
    param([Parameter(Mandatory)][string]$RunDirectory)
    return Join-Path $RunDirectory 'post-result.json'
}

function Get-RunMarker {
    <#
      A deterministic, machine-findable stamp for one run, embedded in the
      published review body. It is what makes an unreceipted retry safe: if the
      POST reached GitHub but the response, the parse, or the process died
      before the receipt was written, the retry finds this marker on the
      existing review instead of publishing a duplicate.

      The id is constrained to the shape -Resolve mints. It is read back out of
      pinned.json, which lives on disk, and both marker searches are substring
      matches: a runId of `*` would match the first review body it met and
      suppress publication of a review that was never posted. Failing closed on
      a malformed id is not a loss, since no real run has one.
    #>
    param([Parameter(Mandatory)][string]$RunId)
    if ($RunId -notmatch '^[0-9a-fA-F]{6,64}$') {
        throw "Refusing to use run id '$RunId': a run id must be 6-64 hex characters. Re-run -Resolve to mint one."
    }
    return "<!-- pr-review:run=$RunId -->"
}

function Add-RunMarker {
    param(
        [Parameter(Mandatory)]$Payload,
        [Parameter(Mandatory)][string]$RunId
    )

    $marker = Get-RunMarker -RunId $RunId
    $body = [string](Get-PropertyValue -Object $Payload -Name 'body')
    if ($body.Contains($marker, [System.StringComparison]::Ordinal)) { return $Payload }

    return [pscustomobject]@{
        commit_id = [string](Get-PropertyValue -Object $Payload -Name 'commit_id')
        event     = 'COMMENT'
        body      = ($body.TrimEnd() + "`n`n" + $marker)
        comments  = @((Get-PropertyValue -Object $Payload -Name 'comments'))
    }
}

function Find-ReviewByRunMarker {
    <#
      Look for a review this run already published. Returns the review object or
      $null. A failure to list is reported as $null by the caller's choice of
      -AllowFailure; the caller must treat "could not check" as "do not post".
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$RunId
    )

    $marker = Get-RunMarker -RunId $RunId
    $result = Invoke-GhPaginated -Action 'listing existing reviews to reconcile a retry' `
        -Path "repos/$Owner/$Repo/pulls/$Number/reviews" -AllowFailure
    if ($result.ExitCode -ne 0) {
        return [pscustomobject]@{ Checked = $false; Review = $null }
    }

    foreach ($review in @($result.Items)) {
        $body = [string](Get-PropertyValue -Object $review -Name 'body')
        # Ordinal substring, not -like: the marker is literal text, and wildcard
        # matching here would let a crafted id match a review it did not write.
        if ($body.Contains($marker, [System.StringComparison]::Ordinal)) {
            return [pscustomobject]@{ Checked = $true; Review = $review }
        }
    }
    return [pscustomobject]@{ Checked = $true; Review = $null }
}

function Assert-RunUnpublished {
    <#
      The gate every submission attempt passes through: reconcile against the
      run marker and only return when this run has demonstrably published
      nothing. Returning is the sole "go ahead" path — a review already on the
      PR recovers its receipt and exits 0, and a failure to list exits 1,
      because "could not check" has to mean "do not post".

      It is a function rather than a block because both the first attempt and
      the remap retry need it. The retry originally skipped it and resubmitted
      on a rejection matched by a deliberately broad regex, so a POST that
      reached GitHub and then failed in the response, the parse, or the
      transport published a second public review.
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$HeadSha,
        [Parameter(Mandatory)][string]$ResultPath
    )

    $existing = Find-ReviewByRunMarker -Owner $Owner -Repo $Repo -Number $Number -RunId $RunId
    if (-not $existing.Checked) {
        Write-Output ''
        Write-Output 'Could not post'
        Write-Output "Could not list existing reviews to confirm whether run $RunId already published."
        Write-Output 'Refusing to post rather than risk a duplicate review. Retry when the API is reachable.'
        exit 1
    }
    if ($null -ne $existing.Review) {
        $recoveredId = (Get-PropertyValue -Object $existing.Review -Name 'id')
        $recovered = [pscustomobject]@{
            reviewId   = $recoveredId
            commentIds = @()
            runId      = $RunId
            headSha    = $HeadSha
            postedAt   = [string](Get-PropertyValue -Object $existing.Review -Name 'submitted_at')
            reconciled = $true
        }
        Write-JsonFile -Value $recovered -Path $ResultPath
        Write-Output "Run $RunId already published review $recoveredId; recovered its receipt (no duplicate posted)."
        Write-Output "reviewId: $recoveredId"
        exit 0
    }
}

function Assert-PinnedPair {
    <#
      Re-read base and head and refuse to act unless both still match what the
      review was built against.

      Checking only head.sha left two holes. A push between gathering and
      posting could validate one diff and publish against the commit it was no
      longer describing, and a base-branch advance — which changes what the diff
      even means — was never detected at all.

      Both are re-checked immediately before every submission, not once at the
      start: the submission-time call lives inside Submit-Review rather than at
      its call sites, so no amount of work growing between the early check and
      the POST can widen that window again. The earlier calls — entering -Post,
      entering the remap retry, and closing the paginated changed-file list —
      are cheap early aborts that keep expensive work off a PR that has already
      moved, and Invoke-Resolve closes its gather the same way.
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$PinnedBase,
        [Parameter(Mandatory)][string]$PinnedHead,
        [Parameter(Mandatory)][string]$PayloadHead,
        [Parameter(Mandatory)][string]$Stage
    )

    $raw = Invoke-Gh -Action "re-fetching pinned base/head before $Stage" -GhArgs @(
        'api', "repos/$Owner/$Repo/pulls/$Number"
    )
    $live = ConvertFrom-GhJson -Text $raw.Text -Action "parsing PR #$Number for pin check"
    $liveHead = [string]$live.head.sha
    $liveBase = [string]$live.base.sha

    $problems = [System.Collections.Generic.List[string]]::new()
    if ($liveHead -ne $PinnedHead -or $liveHead -ne $PayloadHead) {
        $problems.Add("head moved (pinned=$PinnedHead payload=$PayloadHead live=$liveHead)")
    }
    if ($liveBase -ne $PinnedBase) {
        $problems.Add("base moved (pinned=$PinnedBase live=$liveBase)")
    }
    if ($problems.Count -gt 0) {
        throw ("Refusing to $Stage — " + ($problems -join '; ') + '. Re-run -Resolve and revalidate.')
    }

    return [pscustomobject]@{
        BaseSha      = $liveBase
        HeadSha      = $liveHead
        ChangedFiles = [int](Get-PropertyValue -Object $live -Name 'changed_files')
    }
}

# GitHub's compare endpoint carries `files` on the first page only and caps that
# list at 300 entries, whatever the PR's real size.
$script:CompareFileCap = 300

function Get-PinnedHeadTreeBlobMap {
    <#
      Fetch the pinned head commit's tree in one non-paginated Git trees API call.
      Returns a path→blob-sha map when the response is complete; $null when the
      fetch fails or GitHub marks the tree truncated.
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$HeadSha
    )

    $raw = Invoke-Gh -Action 'fetching the pinned head tree' -GhArgs @(
        'api', "repos/$Owner/$Repo/git/trees/$HeadSha", '-f', 'recursive=1'
    ) -AllowFailure
    if ($raw.ExitCode -ne 0) { return $null }

    $tree = ConvertFrom-GhJson -Text $raw.Text -Action 'parsing the pinned head tree'
    if ([bool](Get-PropertyValue -Object $tree -Name 'truncated')) { return $null }

    $map = [System.Collections.Generic.Dictionary[string, string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @((Get-PropertyValue -Object $tree -Name 'tree'))) {
        if ($null -eq $entry) { continue }
        if ([string](Get-PropertyValue -Object $entry -Name 'type') -ne 'blob') { continue }
        $path = Normalize-PathKey -Path ([string](Get-PropertyValue -Object $entry -Name 'path'))
        if (-not $path) { continue }
        $map[$path] = [string](Get-PropertyValue -Object $entry -Name 'sha')
    }
    return $map
}

function Assert-FallbackFilesMatchPinnedTree {
    <#
      Prove a mutable /pulls/<n>/files list describes the pinned head before it
      replaces the compare-derived map. compare/ is SHA-addressed; pulls/files
      follows whatever the PR points at right now, so an ABA race can leave a
      closing Assert-PinnedPair satisfied while the file entries came from an
      intermediate push. The pinned head tree is addressed by HeadSha and is the
      proof source: every non-removed entry's path must exist with the same blob
      sha, and every removed entry's path must be absent.
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$HeadSha,
        [Parameter(Mandatory)][object[]]$Files,
        [Parameter(Mandatory)][string]$Stage
    )

    $treeMap = Get-PinnedHeadTreeBlobMap -Owner $Owner -Repo $Repo -HeadSha $HeadSha
    if ($null -eq $treeMap) {
        return [pscustomobject]@{
            Proven  = $false
            Reason  = 'the beyond-300 fallback could not be proven against the pinned head tree'
        }
    }

    $problems = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $Files) {
        if ($null -eq $f) { continue }
        $status = [string](Get-PropertyValue -Object $f -Name 'status')
        $path = Normalize-PathKey -Path ([string](Get-PropertyValue -Object $f -Name 'filename'))
        if (-not $path) { continue }

        if ($status -eq 'removed') {
            if ($treeMap.ContainsKey($path)) {
                $problems.Add("removed file still present in the pinned head tree ($path)")
            }
            continue
        }

        $entrySha = [string](Get-PropertyValue -Object $f -Name 'sha')
        if (-not $treeMap.ContainsKey($path)) {
            $problems.Add("file missing from the pinned head tree ($path)")
            continue
        }
        if ($entrySha -and $treeMap[$path] -ne $entrySha) {
            $problems.Add("blob sha mismatch at $path (list=$entrySha tree=$($treeMap[$path]))")
        }
    }

    if ($problems.Count -gt 0) {
        throw ("Refusing to $Stage — " + ($problems -join '; ') + '. Re-run -Resolve and revalidate.')
    }

    return [pscustomobject]@{ Proven = $true; Reason = '' }
}

function Get-PinnedDiffFiles {
    <#
      Build the line map from the pinned base...head pair rather than the PR's
      mutable files view. /pulls/<n>/files always describes whatever the PR
      points at right now, so a push mid-run silently remapped comments onto a
      diff nobody reviewed. The compare endpoint is addressed by SHA, so it
      returns the same diff every time or nothing at all.

      That pin alone was not enough coverage. compare/ returns `files` on its
      first page only and truncates at 300 entries, so on a larger PR every file
      past the cap was missing from the map and its findings were demoted out of
      inline comments — reported as unmappable locations when the real cause was
      a map that stopped early.

      Past the cap, fall back to the paginated /pulls/<n>/files list, which is
      complete but mutable. A closing base/head check catches a push that stays
      moved, but not an ABA race: the PR can move to B while the endpoint
      responds, then be force-pushed back to the pinned base/head before that
      check, leaving a B file map that passes as A. Before trusting the fallback,
      every entry is verified against the pinned head tree (itself addressed by
      HeadSha); mismatch aborts, and a truncated or unavailable tree keeps the
      compare-derived files and reports the map incomplete.
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$BaseSha,
        [Parameter(Mandatory)][string]$HeadSha,
        [int]$ExpectedFileCount = 0
    )

    $result = Invoke-GhPaginated -Action 'fetching the pinned base...head diff' `
        -Path "repos/$Owner/$Repo/compare/$BaseSha...$HeadSha"

    # compare/ wraps its file array in an envelope; only the first page carries one.
    $files = [System.Collections.Generic.List[object]]::new()
    foreach ($page in @($result.Pages)) {
        if (-not (Test-HasProperty -Object $page -Name 'files')) { continue }
        foreach ($f in @((Get-PropertyValue -Object $page -Name 'files'))) {
            if ($null -ne $f) { $files.Add($f) }
        }
    }

    $source = "compare/$BaseSha...$HeadSha"
    $complete = $true
    $reason = ''

    $capped = $files.Count -ge $script:CompareFileCap
    $short = $ExpectedFileCount -gt 0 -and $files.Count -lt $ExpectedFileCount
    if ($capped -or $short) {
        $prResult = Invoke-GhPaginated -Action 'fetching the full changed-file list' `
            -Path "repos/$Owner/$Repo/pulls/$Number/files" -AllowFailure
        $prFiles = @($prResult.Items)

        if ($prResult.ExitCode -eq 0 -and $prFiles.Count -gt $files.Count) {
            # Closing pin: the list above is the PR's live view, so it is only
            # usable if base and head are still what the compare was pinned to.
            [void](Assert-PinnedPair -Owner $Owner -Repo $Repo -Number $Number `
                    -PinnedBase $BaseSha -PinnedHead $HeadSha -PayloadHead $HeadSha `
                    -Stage 'trust the paginated changed-file list')
            $proof = Assert-FallbackFilesMatchPinnedTree -Owner $Owner -Repo $Repo `
                -HeadSha $HeadSha -Files $prFiles `
                -Stage 'trust the paginated changed-file list against the pinned head tree'
            if ($proof.Proven) {
                $files = [System.Collections.Generic.List[object]]::new()
                foreach ($f in $prFiles) { if ($null -ne $f) { $files.Add($f) } }
                $source = "pulls/$Number/files (bracketed by the pinned base/head pair)"
            }
            else {
                $complete = $false
                $reason = ("compare/ returned $($files.Count) files (its cap is $script:CompareFileCap) " +
                    "and $($proof.Reason)")
            }
        }
        elseif ($prResult.ExitCode -ne 0) {
            $complete = $false
            $reason = ("compare/ returned $($files.Count) files (its cap is $script:CompareFileCap) " +
                'and the paginated changed-file list could not be fetched')
        }

        if ($complete -and $ExpectedFileCount -gt 0 -and $files.Count -lt $ExpectedFileCount) {
            $complete = $false
            $reason = "the changed-file map holds $($files.Count) of the PR's $ExpectedFileCount files"
        }
    }

    return [pscustomobject]@{
        Files    = $files.ToArray()
        Source   = $source
        Complete = $complete
        Reason   = $reason
    }
}

function Move-UnmappableToSummary {
    param(
        $Payload,
        [object[]]$UnmappableComments,
        [string]$CoverageNote
    )

    $body = [string]$Payload.body
    $section = [System.Collections.Generic.List[string]]::new()
    $section.Add('')
    $section.Add('## Unmappable findings')
    $section.Add('')
    $section.Add('The following findings could not be mapped to a current diff location and were moved out of inline comments:')
    $section.Add('')
    if (-not [string]::IsNullOrWhiteSpace($CoverageNote)) {
        # Say which cause applies. A demotion because the map ran out of files is
        # a coverage gap, not a stale location, and reading it as the latter
        # sends the reader looking for a defect that is not there.
        $section.Add("Note: the changed-file map was incomplete — $CoverageNote. Some of these may be map gaps rather than stale locations.")
        $section.Add('')
    }
    foreach ($c in $UnmappableComments) {
        $path = [string](Get-PropertyValue -Object $c -Name 'path')
        $line = Get-PropertyValue -Object $c -Name 'line'
        $cbody = [string](Get-PropertyValue -Object $c -Name 'body')
        $section.Add("### ``${path}:${line}``")
        $section.Add('')
        $section.Add($cbody)
        $section.Add('')
    }

    # Evict by object identity, never by a rendered-content key. Every caller
    # partitions $Payload.comments and hands back the same object references, so
    # reference equality removes exactly the demoted comments and nothing else.
    # The former path|line|body-hash key omitted start_line — and collapsed on
    # GetHashCode collisions — so an unmappable comment could delete a *mappable*
    # one that merely rendered identically. The evicted comment then appeared
    # nowhere at all, because only the unmappable list reaches the summary.
    $kept = @()
    if (Test-HasProperty -Object $Payload -Name 'comments') {
        $all = @((Get-PropertyValue -Object $Payload -Name 'comments'))
        $kept = @(
            foreach ($c in $all) {
                $demoted = $false
                foreach ($u in $UnmappableComments) {
                    if ([object]::ReferenceEquals($c, $u)) {
                        $demoted = $true
                        break
                    }
                }
                if (-not $demoted) { $c }
            }
        )
    }

    return [pscustomobject]@{
        commit_id = [string]$Payload.commit_id
        event     = 'COMMENT'
        body      = ($body.TrimEnd() + "`n" + ($section -join "`n"))
        comments  = $kept
    }
}

# Everything publication needs, proved, with no GitHub write performed.
#
# This is split out of Invoke-Post so that --dry-run can mean something. A dry
# run implemented by skipping the POST leaves schema validation, the canonical
# workspace proof, the closing pinned-pair check, run-marker reconciliation and
# diff-location validation unexecuted — which is precisely the part worth
# rehearsing before a public review. -Preflight runs this and stops; -Post runs
# it and submits the payload it returns. API *reads* happen here; writes do not.
function Get-SubmissionPlan {
    param(
        [Parameter(Mandatory)][string]$PayloadPath,
        [string]$ExpectedRunId,
        [Parameter(Mandatory)][string]$Stage
    )

    Assert-GhPresent
    $payload = Read-JsonFile -Path $PayloadPath

    $violations = [System.Collections.Generic.List[string]]::new()
    Test-ReviewPayloadObject -Payload $payload -Path 'payload' -Violations $violations
    if ($violations.Count -gt 0) {
        Write-Output 'VALIDATION FAILED'
        foreach ($v in $violations) { Write-Output " - $v" }
        exit 1
    }

    $headSha = [string]$payload.commit_id

    # The payload's own directory is where pinned.json is read from, so guard it
    # before reading: a junction here would redirect that read and every later
    # write. Canonicality is proved below, once the pinned identity is known.
    $workspace = Split-Path -Parent $PayloadPath
    if ([string]::IsNullOrWhiteSpace($workspace)) {
        $workspace = (Get-Location).Path
    }
    Assert-SafeWorkspacePath -Path $workspace

    $pinnedPath = Join-Path $workspace 'pinned.json'
    $pinned = $null
    if (Test-Path -LiteralPath $pinnedPath) {
        $pinned = Read-JsonFile -Path $pinnedPath
    }
    if ($null -eq $pinned) {
        throw "Cannot locate pinned.json beside payload ($pinnedPath). Run -Resolve first and post from the workspace."
    }

    $owner = [string]$pinned.owner
    $repo = [string]$pinned.repo
    $number = [int]$pinned.pr
    $pinnedHead = [string]$pinned.headSha
    $pinnedBase = ''
    if (Test-HasProperty -Object $pinned -Name 'baseSha') {
        $pinnedBase = [string](Get-PropertyValue -Object $pinned -Name 'baseSha')
    }
    if ([string]::IsNullOrWhiteSpace($pinnedBase)) {
        throw "pinned.json has no baseSha, so publication cannot be pinned to a base/head pair. Re-run -Resolve."
    }

    $runId = ''
    if (Test-HasProperty -Object $pinned -Name 'runId') {
        $runId = [string](Get-PropertyValue -Object $pinned -Name 'runId')
    }
    if ([string]::IsNullOrWhiteSpace($runId)) {
        throw "pinned.json has no runId. Re-run -Resolve to mint one."
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedRunId) -and $ExpectedRunId -ne $runId) {
        throw "-RunId '$ExpectedRunId' does not match the run that owns this payload ('$runId'). Post from that run's own workspace."
    }

    # The pinned identity now decides where this run lives — not the path the
    # caller happened to pass. Everything below writes to the canonical path.
    $workspace = Assert-CanonicalRunWorkspace -Owner $owner -Repo $repo -Number $number `
        -HeadSha $pinnedHead -RunId $runId -Workspace $workspace

    # Idempotent retry: this run already posted. A later -Resolve mints a new run
    # id in its own directory, so re-reviewing an unchanged head still publishes
    # a fresh summary. The runId is re-checked here as well as being implied by
    # the directory, so a legacy flat workspace cannot pass one run's receipt off
    # as another's.
    #
    # Sequential, not concurrent: this reconciliation and the marker lookup below
    # make a *retry* safe, and nothing here is an inter-process lock. Two -Post
    # processes started together for one run can both read "unpublished" before
    # either writes, and both publish. Run-directory isolation covers concurrent
    # runs, not concurrent posts of one run; SKILL.md states the one-post-at-a-
    # time constraint. A lock would have to cover the read and the POST together.
    $resultPath = Get-PostResultPath -RunDirectory $workspace
    if (Test-Path -LiteralPath $resultPath) {
        # An unreadable receipt is treated as no receipt, not as a fatal error.
        # Dying here would skip the run-marker reconciliation below, which is the
        # one mechanism that can tell whether the POST actually landed — turning
        # a recoverable state into an unrecoverable one.
        $prior = $null
        try { $prior = Read-JsonFile -Path $resultPath }
        catch {
            Write-Warning "Ignoring unreadable post receipt '$resultPath' ($($_.Exception.Message)). Reconciling against the run marker instead."
        }
        if ($null -ne $prior) {
            $priorRun = [string](Get-PropertyValue -Object $prior -Name 'runId')
            if ($priorRun -eq $runId -and [string]$prior.headSha -eq $headSha -and $prior.reviewId) {
                return [pscustomobject]@{
                    AlreadyPosted = $true
                    Prior         = $prior
                    RunId         = $runId
                    HeadSha       = $headSha
                }
            }
        }
    }

    # 1. Re-fetch base and head; refuse if either moved.
    $pinCheck = Assert-PinnedPair -Owner $owner -Repo $repo -Number $number `
        -PinnedBase $pinnedBase -PinnedHead $pinnedHead -PayloadHead $headSha -Stage $Stage

    # 2. No receipt, but the POST may still have reached GitHub on an earlier
    #    attempt that died before writing one. Reconcile against the run marker
    #    before publishing anything. "Could not check" is treated as "do not
    #    post": a duplicate public review is worse than a failed run.
    Assert-RunUnpublished -Owner $owner -Repo $repo -Number $number `
        -RunId $runId -HeadSha $headSha -ResultPath $resultPath

    # 3. Validate comments against the diff pinned to base...head, not the PR's
    #    mutable files view.
    $fileMap = Get-PinnedDiffFiles -Owner $owner -Repo $repo -Number $number `
        -BaseSha $pinnedBase -HeadSha $pinnedHead -ExpectedFileCount $pinCheck.ChangedFiles
    $files = @($fileMap.Files)
    Write-JsonFile -Value $files -Path (Join-Path $workspace 'changed-files.json')
    $coverageNote = ''
    if (-not $fileMap.Complete) {
        $coverageNote = $fileMap.Reason
        Write-Warning ("Changed-file map is incomplete — $($fileMap.Reason). " +
            'Findings in the missing files cannot be placed inline.')
    }
    $diffMap = Get-DiffLineMap -Files $files

    $working = $payload
    $comments = @()
    if (Test-HasProperty -Object $working -Name 'comments') {
        $comments = @((Get-PropertyValue -Object $working -Name 'comments'))
    }

    $unmappable = [System.Collections.Generic.List[object]]::new()
    $mappable = [System.Collections.Generic.List[object]]::new()
    foreach ($c in $comments) {
        $problems = [System.Collections.Generic.List[string]]::new()
        Test-CommentAgainstDiff -Comment $c -DiffMap $diffMap -Problems $problems
        if ($problems.Count -gt 0) {
            $unmappable.Add($c)
        }
        else {
            $mappable.Add($c)
        }
    }

    if ($unmappable.Count -gt 0) {
        # Pre-flight remap: drop known-bad from inline before first post attempt.
        $working = Move-UnmappableToSummary -Payload $working -UnmappableComments @($unmappable) `
            -CoverageNote $coverageNote
    }
    else {
        $working = [pscustomobject]@{
            commit_id = [string]$payload.commit_id
            event     = 'COMMENT'
            body      = [string]$payload.body
            comments  = @($mappable)
        }
    }

    # Stamp the run marker here rather than at the submission, so preflight
    # validates and preserves the exact bytes -Post sends instead of a near-copy.
    $working = Add-RunMarker -Payload $working -RunId $runId

    return [pscustomobject]@{
        AlreadyPosted   = $false
        Prior           = $null
        SourcePayload   = $payload
        Payload         = $working
        Workspace       = $workspace
        Owner           = $owner
        Repo            = $repo
        Number          = $number
        RunId           = $runId
        HeadSha         = $headSha
        PinnedBase      = $pinnedBase
        PinnedHead      = $pinnedHead
        ResultPath      = $resultPath
        PinCheck        = $pinCheck
        FileMap         = $fileMap
        CoverageNote    = $coverageNote
        MappableCount   = $mappable.Count
        UnmappableCount = $unmappable.Count
    }
}

function Invoke-Preflight {
    param(
        [Parameter(Mandatory)][string]$PayloadPath,
        [string]$ExpectedRunId
    )

    $plan = Get-SubmissionPlan -PayloadPath $PayloadPath -ExpectedRunId $ExpectedRunId -Stage 'preflight'

    if ($plan.AlreadyPosted) {
        Write-Output "PREFLIGHT: run $($plan.RunId) already published review $($plan.Prior.reviewId) at head $($plan.HeadSha)."
        Write-Output 'A -Post would be an idempotent no-op. Run -Resolve again to start a new run.'
        return
    }

    $workspace = $plan.Workspace
    $working = $plan.Payload

    # The same artefacts -Post preserves, minus the submission itself.
    Write-JsonFile -Value $working -Path (Join-Path $workspace 'review.json')
    $mdPath = Join-Path $workspace 'review.md'
    Set-Content -LiteralPath $mdPath -Value (ConvertTo-ReviewMarkdown -Payload $working) -Encoding utf8

    Write-Output 'PREFLIGHT PASSED — no GitHub write was performed.'
    Write-Output "target: $($plan.Owner)/$($plan.Repo)#$($plan.Number)"
    Write-Output "runId: $($plan.RunId)"
    Write-Output "pinned: base $($plan.PinnedBase) head $($plan.PinnedHead)"
    Write-Output 'checks:'
    Write-Output '  - payload validated against review-schema.json'
    Write-Output '  - run workspace recomputed from pinned identity and proved canonical'
    Write-Output '  - run id bound to this payload'
    Write-Output '  - base and head re-read; neither moved'
    Write-Output '  - run marker reconciled against existing reviews; this run has not published'
    Write-Output "  - diff line map built from $($plan.FileMap.Source)"
    Write-Output '  - every inline comment located against the pinned diff'
    Write-Output '  - run marker stamped on the outgoing body'
    Write-Output "inlineComments: $($plan.MappableCount)"
    Write-Output "movedToSummary: $($plan.UnmappableCount)"
    if (-not [string]::IsNullOrWhiteSpace($plan.CoverageNote)) {
        Write-Output "fileMapCoverage: INCOMPLETE — $($plan.CoverageNote)"
    }
    Write-Output "payload: $(Join-Path $workspace 'review.json')"
    Write-Output "fallback: $mdPath"
    Write-Output ''
    Write-Output 'Preflight proves the payload is internally valid and correctly located'
    Write-Output 'against the pinned diff. It cannot prove GitHub would accept it — only'
    Write-Output 'the submission itself does that.'
}

function Invoke-Post {
    param(
        [Parameter(Mandatory)][string]$PayloadPath,
        [string]$ExpectedRunId
    )

    $plan = Get-SubmissionPlan -PayloadPath $PayloadPath -ExpectedRunId $ExpectedRunId -Stage 'post'

    if ($plan.AlreadyPosted) {
        $prior = $plan.Prior
        Write-Output "Already posted for run $($plan.RunId) at head $($plan.HeadSha) (idempotent no-op)"
        Write-Output "reviewId: $($prior.reviewId)"
        Write-Output ("commentIds: " + ((@($prior.commentIds) | ForEach-Object { $_ }) -join ', '))
        Write-Output "postedAt: $($prior.postedAt)"
        Write-Output 'Run -Resolve again to start a new run against this head.'
        return
    }

    $payload = $plan.SourcePayload
    $working = $plan.Payload
    $workspace = $plan.Workspace
    $owner = $plan.Owner
    $repo = $plan.Repo
    $number = $plan.Number
    $runId = $plan.RunId
    $headSha = $plan.HeadSha
    $pinnedBase = $plan.PinnedBase
    $pinnedHead = $plan.PinnedHead
    $resultPath = $plan.ResultPath
    $pinCheck = $plan.PinCheck
    $fileMap = $plan.FileMap
    $coverageNote = $plan.CoverageNote

    function Submit-Review {
        param(
            $ReviewPayload,
            [Parameter(Mandatory)][string]$Stage
        )
        # The pair is re-read here, inside the submission itself, rather than at
        # the call sites. "Immediately before every submission attempt" was true
        # of the code that first made the claim and had already drifted: between
        # the outer check and the POST sat the run-marker lookup, the file-map
        # fetch, and payload assembly, and a truncated map added a whole
        # pagination plus a nested pin check to that window. Owning the check
        # here makes the claim structural — a new call site cannot forget it,
        # and the outer checks stay as the cheap early abort that keeps
        # expensive work off a PR that has already moved.
        [void](Assert-PinnedPair -Owner $owner -Repo $repo -Number $number `
                -PinnedBase $pinnedBase -PinnedHead $pinnedHead -PayloadHead $headSha -Stage $Stage)
        $tmp = Join-Path $workspace 'review.post.json'
        Write-JsonFile -Value $ReviewPayload -Path $tmp
        return Invoke-Gh -Action 'posting pull request review' -GhArgs @(
            'api',
            '--method', 'POST',
            "repos/$owner/$repo/pulls/$number/reviews",
            '--input', $tmp
        ) -AllowFailure
    }

    # Preserve exact outgoing payload before attempt. The run marker — which lets
    # a retry that lost its receipt recognise this review on GitHub — is already
    # stamped by Get-SubmissionPlan, so these bytes are the ones preflight saw.
    Write-JsonFile -Value $working -Path (Join-Path $workspace 'review.json')

    $response = Submit-Review -ReviewPayload $working -Stage 'post'

    # 3. If gh rejects line locations, refresh + remap exactly once.
    if ($response.ExitCode -ne 0 -and $response.Text -match '(?i)(line|position|pull_request_review_thread|Path)') {
        Write-Warning 'GitHub rejected one or more line locations; refreshing diff and retrying once.'

        # A non-zero exit is not proof the POST never landed: it also covers a
        # request GitHub accepted whose response, parse, or transport then
        # failed. The regex above is deliberately broad — a 5xx or permission
        # body containing the word "Path" reaches here — so reconcile against
        # the run marker again before resubmitting, exactly as the first
        # attempt did. Without this the retry publishes a second public review.
        Assert-RunUnpublished -Owner $owner -Repo $repo -Number $number `
            -RunId $runId -HeadSha $headSha -ResultPath $resultPath

        # Re-pin before the second submission too. The rejection may itself be
        # the first sign that the PR moved under us, and this is a separate
        # publication attempt, not a continuation of the first.
        [void](Assert-PinnedPair -Owner $owner -Repo $repo -Number $number `
                -PinnedBase $pinnedBase -PinnedHead $pinnedHead -PayloadHead $headSha -Stage 'retry the post')

        $fileMap2 = Get-PinnedDiffFiles -Owner $owner -Repo $repo -Number $number `
            -BaseSha $pinnedBase -HeadSha $pinnedHead -ExpectedFileCount $pinCheck.ChangedFiles
        $files2 = @($fileMap2.Files)
        Write-JsonFile -Value $files2 -Path (Join-Path $workspace 'changed-files.json')
        if (-not $fileMap2.Complete) { $coverageNote = $fileMap2.Reason }
        $diffMap2 = Get-DiffLineMap -Files $files2

        $stillBad = [System.Collections.Generic.List[object]]::new()
        $stillGood = [System.Collections.Generic.List[object]]::new()
        $retryComments = @()
        if (Test-HasProperty -Object $working -Name 'comments') {
            $retryComments = @((Get-PropertyValue -Object $working -Name 'comments'))
        }
        foreach ($c in $retryComments) {
            $problems = [System.Collections.Generic.List[string]]::new()
            Test-CommentAgainstDiff -Comment $c -DiffMap $diffMap2 -Problems $problems
            if ($problems.Count -gt 0) { $stillBad.Add($c) } else { $stillGood.Add($c) }
        }

        # If GitHub rejected but our map still thinks lines are fine, treat ALL
        # remaining inline comments as unmappable rather than looping.
        if ($stillBad.Count -eq 0 -and $retryComments.Count -gt 0) {
            $stillBad = [System.Collections.Generic.List[object]]::new()
            foreach ($c in $retryComments) { $stillBad.Add($c) }
            $stillGood = [System.Collections.Generic.List[object]]::new()
        }

        # Rebuild the body from the original payload, not from $working. By this
        # point $working's body may already carry a pre-flight "## Unmappable
        # findings" section and a run marker; reusing it would append a second
        # section below the first and leave the reader with two contradictory
        # lists of what was demoted.
        $working = [pscustomobject]@{
            commit_id = [string]$payload.commit_id
            event     = 'COMMENT'
            body      = [string]$payload.body
            comments  = @($stillGood)
        }
        if ($stillBad.Count -gt 0) {
            $working = Move-UnmappableToSummary -Payload $working -UnmappableComments @($stillBad) `
                -CoverageNote $coverageNote
        }

        $working = Add-RunMarker -Payload $working -RunId $runId
        Write-JsonFile -Value $working -Path (Join-Path $workspace 'review.json')
        $response = Submit-Review -ReviewPayload $working -Stage 'retry the post'
    }

    if ($response.ExitCode -ne 0) {
        # 4. Auth / rate-limit / API failure — preserve payload + markdown fallback.
        $mdPath = Join-Path $workspace 'review.md'
        $md = ConvertTo-ReviewMarkdown -Payload $working
        Set-Content -LiteralPath $mdPath -Value $md -Encoding utf8
        Write-JsonFile -Value $working -Path (Join-Path $workspace 'review.json')

        Write-Output ''
        Write-Output 'Could not post'
        Write-Output "Fallback markdown: $mdPath"
        Write-Output "Preserved payload: $(Join-Path $workspace 'review.json')"
        Write-Output "gh error: $($response.Text.Trim())"
        exit 1
    }

    $created = ConvertFrom-GhJson -Text $response.Text -Action 'parsing created review'
    $reviewId = $created.id
    $postedAt = (Get-Date).ToUniversalTime().ToString('o')

    # Write the receipt the moment the review id is known, before the comment-id
    # fetch. Anything that fails after this point leaves a retry a no-op instead
    # of a duplicate; a crash before it is caught by the run marker on retry.
    $result = [pscustomobject]@{
        reviewId   = $reviewId
        commentIds = @()
        runId      = $runId
        headSha    = $headSha
        postedAt   = $postedAt
    }
    Write-JsonFile -Value $result -Path $resultPath

    # Collect comment ids from the review comments endpoint (paginated: a large
    # review exceeds one page, and a short receipt makes retries look wrong).
    $commentIds = @()
    $cResult = Invoke-GhPaginated -Action 'listing review comments' -Path "repos/$owner/$repo/pulls/$number/reviews/$reviewId/comments" -AllowFailure
    if ($cResult.ExitCode -eq 0) {
        $commentIds = @($cResult.Items | ForEach-Object { $_.id })
        $result = [pscustomobject]@{
            reviewId   = $reviewId
            commentIds = $commentIds
            runId      = $runId
            headSha    = $headSha
            postedAt   = $postedAt
        }
        Write-JsonFile -Value $result -Path $resultPath
    }

    Write-JsonFile -Value $working -Path (Join-Path $workspace 'review.json')

    Write-Output "Posted COMMENT review $reviewId on $owner/$repo#$number"
    Write-Output "reviewId: $reviewId"
    Write-Output ("commentIds: " + ($commentIds -join ', '))
    Write-Output "headSha: $headSha"
    Write-Output "postedAt: $postedAt"
    Write-Output "fileMapSource: $($fileMap.Source)"
    if (-not [string]::IsNullOrWhiteSpace($coverageNote)) {
        Write-Output "fileMapCoverage: INCOMPLETE — $coverageNote"
    }
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------

try {
    if ($Help) {
        Show-Usage
        exit 0
    }

    $resolveRequested = Test-ResolveRequested -BoundParameters $PSBoundParameters
    $verbCount = 0
    if ($resolveRequested) { $verbCount++ }
    if ($Preflight) { $verbCount++ }
    if ($Post) { $verbCount++ }
    if ($NewWorkspace) { $verbCount++ }
    if ($Validate) { $verbCount++ }
    if ($Fingerprint) { $verbCount++ }
    if ($Dedupe) { $verbCount++ }
    if ($BuildPayload) { $verbCount++ }
    if ($MarkdownFallback) { $verbCount++ }

    if ($verbCount -eq 0) {
        Show-Usage
        Write-Error 'No verb specified. Pass -Help or one of the documented switches.'
        exit 1
    }
    if ($verbCount -gt 1) {
        Write-Error 'Specify exactly one verb per invocation.'
        exit 1
    }

    if ($resolveRequested) {
        Invoke-Resolve -Target $Resolve
        exit 0
    }

    if ($NewWorkspace) {
        if ([string]::IsNullOrWhiteSpace($Owner) -or [string]::IsNullOrWhiteSpace($Repo) -or
            $Pr -le 0 -or [string]::IsNullOrWhiteSpace($HeadSha)) {
            throw '-NewWorkspace requires -Owner, -Repo, -Pr, and -HeadSha'
        }
        $path = New-OrGetWorkspace -Owner $Owner -Repo $Repo -Pr $Pr -HeadSha $HeadSha
        Write-Output $path
        exit 0
    }

    if ($Validate) {
        Invoke-Validate -FindingsPath $Findings -PayloadPath $Payload
    }

    if ($Fingerprint) {
        if ([string]::IsNullOrWhiteSpace($Findings)) {
            throw '-Fingerprint requires -Findings <path>'
        }
        Invoke-Fingerprint -FindingsPath $Findings
        exit 0
    }

    if ($Dedupe) {
        if ([string]::IsNullOrWhiteSpace($Findings) -or [string]::IsNullOrWhiteSpace($Prior)) {
            throw '-Dedupe requires -Findings <path> and -Prior <path>'
        }
        Invoke-Dedupe -FindingsPath $Findings -PriorPath $Prior
        exit 0
    }

    if ($BuildPayload) {
        if ([string]::IsNullOrWhiteSpace($Findings) -or [string]::IsNullOrWhiteSpace($BaseSha) -or
            [string]::IsNullOrWhiteSpace($HeadSha)) {
            throw '-BuildPayload requires -Findings, -BaseSha, and -HeadSha'
        }
        $hasText = $PSBoundParameters.ContainsKey('BodyText')
        $hasFile = -not [string]::IsNullOrWhiteSpace($BodyFile)
        if ($hasText -and $hasFile) {
            throw '-BuildPayload takes -BodyText or -BodyFile, not both.'
        }
        if (-not $hasText -and -not $hasFile) {
            throw '-BuildPayload requires -BodyText <text> or -BodyFile <path>'
        }
        Invoke-BuildPayload -FindingsPath $Findings -BaseSha $BaseSha -HeadSha $HeadSha `
            -BodyText $BodyText -BodyFile $BodyFile
        exit 0
    }

    if ($MarkdownFallback) {
        if ([string]::IsNullOrWhiteSpace($Payload)) {
            throw '-MarkdownFallback requires -Payload <path>'
        }
        Invoke-MarkdownFallback -PayloadPath $Payload
        exit 0
    }

    if ($Preflight) {
        if ([string]::IsNullOrWhiteSpace($Payload)) {
            throw '-Preflight requires -Payload <path>'
        }
        Invoke-Preflight -PayloadPath $Payload -ExpectedRunId $RunId
        exit 0
    }

    if ($Post) {
        if ([string]::IsNullOrWhiteSpace($Payload)) {
            throw '-Post requires -Payload <path>'
        }
        Invoke-Post -PayloadPath $Payload -ExpectedRunId $RunId
        exit 0
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
