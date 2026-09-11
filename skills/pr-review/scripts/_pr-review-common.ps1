# Offline helpers for pr-review.ps1. Dot-sourced by the entrypoint.
# No exit statements. No top-level executable code beyond function and constant
# definitions. Load order is a contract: common, then workspace, then entrypoint.
# See docs/adr/0016-pr-review-helper-splits-around-workspace-seam.md.

$script:SchemaPath = Join-Path $PSScriptRoot 'review-schema.json'
$script:SeverityEnum = @('Critical', 'High', 'Medium', 'Low')
$script:CategoryEnum = @('risk', 'security', 'standards', 'spec', 'coverage', 'performance')
$script:VerdictEnum = @('CONFIRMED', 'PLAUSIBLE')
$script:SideEnum = @('LEFT', 'RIGHT')
$script:PlacementEnum = @('inline', 'file', 'summary')

# Free-text finding fields that Format-InlineCommentBody renders verbatim into
# the comment body. A Markdown code fence in any of them can close an enclosing
# suggestion block early and continue with arbitrary Markdown — including a
# second, unverified suggestion fence that no gate inspected — so both -Validate
# and -BuildPayload refuse a finding that carries one. Exact PR-review
# fingerprint-marker HTML comments are stripped from the same fields before
# render so a spoofed marker cannot land in the posted body ahead of the
# helper's last-line marker. Other HTML comments are left in place.
$script:VerbatimFindingFields = @('summary', 'failure_scenario', 'evidence', 'fix')

# Axis statuses that count as coverage. Everything else — failed, timeout,
# rate-limited, unavailable, missing, or a spelling nobody anticipated — is a
# gap, because the failure mode this guards against is an unrecognised status
# being read as success.
$script:CleanAxisStatuses = @('complete', 'skipped')
$script:CleanFileDispositions = @('reviewed', 'generated', 'skipped')

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

    foreach ($verbatim in $script:VerbatimFindingFields) {
        if (-not (Test-HasProperty -Object $Finding -Name $verbatim)) { continue }
        $verbatimText = [string](Get-PropertyValue -Object $Finding -Name $verbatim)
        if (Test-CarriesFenceMarker -Text $verbatimText) {
            Add-Violation -List $Violations -Path "$Path.$verbatim" -Message ("must not contain a Markdown code fence. " + (Get-FenceRejectionDetail))
        }
    }

    $findingFile = [string](Get-PropertyValue -Object $Finding -Name 'file')
    foreach ($capped in @('summary', 'failure_scenario', 'fix')) {
        if (-not (Test-HasProperty -Object $Finding -Name $capped)) { continue }
        $raw = Get-PropertyValue -Object $Finding -Name $capped
        if ($null -eq $raw) { continue }
        $cappedText = [string]$raw
        if ($cappedText.Length -gt 500) {
            Add-Violation -List $Violations -Path "$Path.$capped" `
                -Message "exceeds 500-character cap (file: $findingFile, actual: $($cappedText.Length))"
        }
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

    foreach ($pair in @(@{ Line = 'line'; Side = 'side' }, @{ Line = 'start_line'; Side = 'start_side' })) {
        $sideProp = $pair.Side
        # An empty or whitespace side is as unusable to the location API as an
        # absent one, so it is treated as missing rather than falling through to
        # the enum check, which only fires on a non-empty value.
        $hasSide = (Test-HasProperty -Object $Comment -Name $sideProp) -and
                   -not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue -Object $Comment -Name $sideProp))
        if (-not $hasSide) {
            $hasLineProp = (Test-HasProperty -Object $Comment -Name $pair.Line) -and ($null -ne (Get-PropertyValue -Object $Comment -Name $pair.Line))
            if ($hasLineProp) {
                Add-Violation -List $Violations -Path "$Path.$sideProp" -Message "missing required property '$sideProp'"
            }
        }
        else {
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
            $script:PrReviewExitCode = 1
            return
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
        $script:PrReviewExitCode = 1
        return
    }

    Write-Output 'VALIDATION OK'
    $script:PrReviewExitCode = 0
}

function Get-NormalizedSubstance {
    param($Finding)
    # Locked substance: summary + failure_scenario + evidence. Remedy text
    # (body, suggestion, fix) must not split a defect identity.
    $parts = @(
        [string](Get-PropertyValue -Object $Finding -Name 'summary')
        [string](Get-PropertyValue -Object $Finding -Name 'failure_scenario')
        [string](Get-PropertyValue -Object $Finding -Name 'evidence')
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

function Use-SemanticOccurrenceCredit {
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

function Get-PrReviewBotIdentity {
    <#
      Resolve the login used to mine bot-authored review threads.

      Source is always one of: explicit-binding, PR_REVIEW_BOT_LOGIN,
      gh-api-user, failure. A successful gh-api-user result is cached with
      that source so a first lookup cannot later look like an explicit
      binding. Failures are not cached: a transient gh api user error must
      not poison later PRs in the same process.

      Precedence is re-evaluated every call: script binding, then
      PR_REVIEW_BOT_LOGIN, then the success cache, then gh api user. Tests
      inject lookup failure through $script:PrReviewGhApiUserLookup (a
      scriptblock that throws or returns an Invoke-Gh-shaped object with
      ExitCode/Text).
    #>
    $boundBot = Get-Variable -Name PrReviewBotLogin -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $boundBot -and -not [string]::IsNullOrWhiteSpace([string]$boundBot.Value)) {
        return [pscustomobject]@{
            Login  = [string]$boundBot.Value
            Source = 'explicit-binding'
            Reason = $null
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:PR_REVIEW_BOT_LOGIN)) {
        return [pscustomobject]@{
            Login  = $env:PR_REVIEW_BOT_LOGIN.Trim()
            Source = 'PR_REVIEW_BOT_LOGIN'
            Reason = $null
        }
    }

    $cache = Get-Variable -Name PrReviewBotIdentityCache -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $cache -and $null -ne $cache.Value -and
        [string]$cache.Value.Source -eq 'gh-api-user' -and
        -not [string]::IsNullOrWhiteSpace([string]$cache.Value.Login)) {
        return $cache.Value
    }

    $failureReason = $null
    try {
        $rawUser = $null
        $lookup = Get-Variable -Name PrReviewGhApiUserLookup -Scope Script -ErrorAction SilentlyContinue
        if ($null -ne $lookup -and $null -ne $lookup.Value) {
            if ($lookup.Value -is [scriptblock]) {
                $invoked = $lookup.Value.Invoke()
                if ($null -ne $invoked -and @($invoked).Count -eq 1) {
                    $rawUser = @($invoked)[0]
                }
                else {
                    $rawUser = $invoked
                }
            }
            else {
                $rawUser = $lookup.Value
            }
        }
        elseif ((Get-Command -Name Invoke-Gh -ErrorAction SilentlyContinue) -and
            (Get-Command -Name ConvertFrom-GhJson -ErrorAction SilentlyContinue)) {
            $rawUser = Invoke-Gh -Action 'resolving review bot login' -GhArgs @('api', 'user') -AllowFailure
        }
        else {
            $failureReason = 'gh api user lookup is unavailable'
        }

        if ([string]::IsNullOrWhiteSpace($failureReason) -and $null -eq $rawUser) {
            $failureReason = 'gh api user lookup returned nothing'
        }

        $exitCode = 0
        $text = $null
        if ([string]::IsNullOrWhiteSpace($failureReason) -and $rawUser -is [string]) {
            $text = $rawUser
        }
        elseif ([string]::IsNullOrWhiteSpace($failureReason)) {
            if (Test-HasProperty -Object $rawUser -Name 'ExitCode') {
                $exitCode = [int](Get-PropertyValue -Object $rawUser -Name 'ExitCode')
            }
            if (Test-HasProperty -Object $rawUser -Name 'Text') {
                $text = [string](Get-PropertyValue -Object $rawUser -Name 'Text')
            }
            elseif ($exitCode -eq 0 -and [string]::IsNullOrWhiteSpace($text)) {
                $failureReason = 'gh api user lookup returned no Text'
            }
        }

        if ([string]::IsNullOrWhiteSpace($failureReason) -and $exitCode -ne 0) {
            $failureReason = "gh api user exited $exitCode"
        }

        if ([string]::IsNullOrWhiteSpace($failureReason) -and [string]::IsNullOrWhiteSpace($text)) {
            $failureReason = 'gh api user returned no login payload'
        }

        if ([string]::IsNullOrWhiteSpace($failureReason)) {
            $user = ConvertFrom-GhJson -Text $text -Action 'parsing authenticated user'
            $botLogin = [string](Get-PropertyValue -Object $user -Name 'login')
            if ([string]::IsNullOrWhiteSpace($botLogin)) {
                $failureReason = 'gh api user returned no login'
            }
            else {
                $resolved = [pscustomobject]@{
                    Login  = $botLogin
                    Source = 'gh-api-user'
                    Reason = $null
                }
                $script:PrReviewBotIdentityCache = $resolved
                return $resolved
            }
        }
    }
    catch {
        $failureReason = $_.Exception.Message
    }

    $failed = [pscustomobject]@{
        Login  = $null
        Source = 'failure'
        Reason = $failureReason
    }
    return $failed
}

function Get-AnchoredFingerprintMarker {
    <#
      Parse a last-line PR-review fingerprint marker after trimming trailing
      whitespace (newline, CR, tab, spaces). The regex stays anchored; a
      quoted mid-body marker is ignored.
    #>
    param([string]$Body)
    if ([string]::IsNullOrWhiteSpace($Body)) { return $null }
    $lastLine = (($Body.TrimEnd() -split '\r?\n') | Select-Object -Last 1)
    if ($lastLine -notmatch '^<!-- pr-review:fp=([0-9a-f]{64}) sfp=([0-9a-f]{64}) -->$') {
        return $null
    }
    return [pscustomobject]@{
        Fingerprint         = $Matches[1]
        SemanticFingerprint = $Matches[2]
        Line                = $lastLine
    }
}

function Remove-PrReviewFingerprintMarkers {
    <#
      Strip PR-review fingerprint-marker HTML comments: the posted
      `<!-- pr-review:fp=<64 hex> sfp=<64 hex> -->` form and the
      `<!-- PR-review fingerprint: ... -->` prose form. Other HTML comments
      are preserved. -KeepAnchoredLastLine keeps a last-line helper marker
      that -BuildPayload appended; without it, last-line valid marker shapes
      are stripped too so a hand-built -Post payload cannot smuggle a stamp.
    #>
    param(
        [string]$Text,
        [switch]$KeepAnchoredLastLine
    )
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $stripExact = '<!-- pr-review:fp=[0-9a-f]{64} sfp=[0-9a-f]{64} -->'
    $stripNamed = '(?i)<!--\s*pr-review\s+fingerprint:[^>]*-->'
    if (-not $KeepAnchoredLastLine) {
        $Text = [regex]::Replace($Text, $stripExact, '')
        return [regex]::Replace($Text, $stripNamed, '')
    }

    $trimmed = $Text.TrimEnd()
    $lastLine = (($trimmed -split '\r?\n') | Select-Object -Last 1)
    $prefix = ''
    if ($trimmed.Length -gt $lastLine.Length) {
        $prefix = $trimmed.Substring(0, $trimmed.Length - $lastLine.Length).TrimEnd("`r", "`n")
    }
    $prefix = [regex]::Replace($prefix, $stripExact, '')
    $prefix = [regex]::Replace($prefix, $stripNamed, '')
    $prefix = $prefix.TrimEnd()
    if ($lastLine -match '^<!-- pr-review:fp=([0-9a-f]{64}) sfp=([0-9a-f]{64}) -->$') {
        if ([string]::IsNullOrEmpty($prefix)) { return $lastLine }
        return ($prefix + "`n" + $lastLine)
    }
    $cleanedLast = [regex]::Replace($lastLine, $stripExact, '')
    $cleanedLast = [regex]::Replace($cleanedLast, $stripNamed, '').TrimEnd()
    if ([string]::IsNullOrEmpty($prefix)) { return $cleanedLast }
    if ([string]::IsNullOrEmpty($cleanedLast)) { return $prefix }
    return ($prefix + "`n" + $cleanedLast)
}

function Protect-ReviewCommentBody {
    <#
      -Post/-Preflight anti-spoof: strip exact fingerprint markers from a
      payload comment, including a valid-looking last line. Pass
      -KeepAnchoredLastLine only for a BUILD-PAYLOAD digest match, where the
      helper itself appended the last-line stamp after verbatim stripping.
    #>
    param(
        $Comment,
        [switch]$KeepAnchoredLastLine
    )
    if ($null -eq $Comment) { return $Comment }
    $body = [string](Get-PropertyValue -Object $Comment -Name 'body')
    $clean = Remove-PrReviewFingerprintMarkers -Text $body -KeepAnchoredLastLine:$KeepAnchoredLastLine
    if ($clean -ceq $body) { return $Comment }
    $hash = [ordered]@{}
    foreach ($p in $Comment.PSObject.Properties) {
        $hash[$p.Name] = $p.Value
    }
    $hash['body'] = $clean
    return [pscustomobject]$hash
}

function Get-PriorFingerprints {
    param($PriorDocument)

    $exactSet = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    # Semantic keys are counted, not just present: the count is how many current
    # findings a prior review is entitled to silence for that key.
    $semanticCounts = [System.Collections.Generic.Dictionary[string, int]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    if ($null -eq $PriorDocument) {
        return [pscustomobject]@{
            exact          = $exactSet
            semantic       = $semanticCounts
            identityLogin  = $null
            identitySource = $null
            identityGap    = $null
        }
    }

    # Each shape below is an independent *view* of the same prior review, so the
    # counts are merged by maximum, not by sum. A document carrying both a
    # findings array and a matching semanticFingerprints list describes one
    # finding twice, and summing would hand it a budget of two — enough to
    # silence a genuinely distinct second site all over again.
    $views = [System.Collections.Generic.List[System.Collections.Generic.Dictionary[string, int]]]::new()

    # review-threads.json from -Resolve. Exclusive unless the document also
    # carries legacy fingerprint keys, which is rejected as hybrid/ambiguous
    # rather than silently dropping one shape. Thread nodes are not findings,
    # and sweeping them into a findings view yields null keys that corrupt the
    # view max-merge. This block is independent of the Get-FindingsArray
    # try/catch below so a future lift of that swallow cannot drop thread mining.
    $hasThreads = Test-HasProperty -Object $PriorDocument -Name 'threads'
    $hasLegacyFingerprints = (Test-HasProperty -Object $PriorDocument -Name 'fingerprints') -or
        (Test-HasProperty -Object $PriorDocument -Name 'semanticFingerprints')
    if ($hasThreads -and $hasLegacyFingerprints) {
        throw ("Refusing to mine a hybrid prior document: 'threads' is present together with " +
            "'fingerprints' and/or 'semanticFingerprints'. That combination is invalid/ambiguous — " +
            'supply a threads-only review-threads.json or a findings/fingerprints prior, not both.')
    }

    if ($hasThreads) {
        $view = [System.Collections.Generic.Dictionary[string, int]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        $threadList = @((Get-PropertyValue -Object $PriorDocument -Name 'threads'))
        $mineableBodies = 0
        foreach ($thread in $threadList) {
            if ($null -eq $thread) { continue }
            $comments = Get-PropertyValue -Object $thread -Name 'comments'
            if ($null -eq $comments) { continue }
            $nodes = Get-PropertyValue -Object $comments -Name 'nodes'
            if ($null -eq $nodes) { continue }
            $nodeList = @($nodes)
            if ($nodeList.Count -eq 0) { continue }
            $first = $nodeList[0]
            if ($null -eq $first) { continue }
            $probe = [string](Get-PropertyValue -Object $first -Name 'body')
            if (-not [string]::IsNullOrWhiteSpace($probe)) { $mineableBodies++ }
        }

        $identity = $null
        $identityGap = $null
        $botLogin = $null
        if ($mineableBodies -eq 0) {
            # Empty thread lists and empty/whitespace-only nodes skip normally.
        }
        else {
            $identity = Get-PrReviewBotIdentity
            $botLogin = $identity.Login
            if ($identity.Source -eq 'failure') {
                $reason = [string]$identity.Reason
                if ([string]::IsNullOrWhiteSpace($reason)) { $reason = 'bot login could not be resolved' }
                $identityGap = "unresolved bot identity (source=failure): $reason"
                Write-Warning $identityGap
            }
        }

        $matchedBotAuthorCount = 0
        $unmatchedBotMarkerCount = 0
        $canMine = ($null -ne $identity -and $identity.Source -ne 'failure' -and
            -not [string]::IsNullOrWhiteSpace($botLogin))

        foreach ($thread in $threadList) {
            if ($null -eq $thread) { continue }
            $comments = Get-PropertyValue -Object $thread -Name 'comments'
            if ($null -eq $comments) { continue }
            $nodes = Get-PropertyValue -Object $comments -Name 'nodes'
            if ($null -eq $nodes) { continue }
            $nodeList = @($nodes)
            if ($nodeList.Count -eq 0) { continue }
            $first = $nodeList[0]
            if ($null -eq $first) { continue }

            $body = [string](Get-PropertyValue -Object $first -Name 'body')
            if ([string]::IsNullOrWhiteSpace($body)) { continue }

            $marker = Get-AnchoredFingerprintMarker -Body $body
            $author = Get-PropertyValue -Object $first -Name 'author'
            $login = [string](Get-PropertyValue -Object $author -Name 'login')
            $authorMatches = $canMine -and -not [string]::IsNullOrWhiteSpace($login) -and
                $login.Equals($botLogin, [System.StringComparison]::OrdinalIgnoreCase)
            if ($authorMatches) { $matchedBotAuthorCount++ }

            if ($null -eq $marker) { continue }
            if (-not $authorMatches) {
                if (-not [string]::IsNullOrWhiteSpace($login) -and
                    $login.EndsWith('[bot]', [System.StringComparison]::OrdinalIgnoreCase)) {
                    $unmatchedBotMarkerCount++
                }
                continue
            }

            [void]$exactSet.Add($marker.Fingerprint)
            Add-SemanticOccurrence -Counts $view -Key $marker.SemanticFingerprint
        }

        if ([string]::IsNullOrWhiteSpace($identityGap) -and $canMine -and
            $exactSet.Count -eq 0 -and $matchedBotAuthorCount -eq 0 -and $unmatchedBotMarkerCount -gt 0) {
            $identityGap = ("resolved bot identity '$botLogin' (source=$($identity.Source)) matched no " +
                "prior thread authors; marker-bearing [bot] threads belong to other logins " +
                "(app-slug[bot] mismatch)")
            Write-Warning $identityGap
        }

        $views.Add($view)

        foreach ($view in $views) {
            foreach ($pair in $view.GetEnumerator()) {
                if (-not $semanticCounts.ContainsKey($pair.Key) -or $semanticCounts[$pair.Key] -lt $pair.Value) {
                    $semanticCounts[$pair.Key] = $pair.Value
                }
            }
        }
        return [pscustomobject]@{
            exact          = $exactSet
            semantic       = $semanticCounts
            identityLogin  = $botLogin
            identitySource = $(if ($null -ne $identity) { $identity.Source } else { $null })
            identityGap    = $identityGap
        }
    }

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

    return [pscustomobject]@{
        exact          = $exactSet
        semantic       = $semanticCounts
        identityLogin  = $null
        identitySource = $null
        identityGap    = $null
    }
}

function Get-PriorCoverageGap {
    <#
      Return the reason the prior review state is known to be partial, or $null
      when it is either complete or silent about its own completeness.

      A prior document that records its own coverage carries a 'complete' flag
      and an 'incompleteReason'; this guard reads them so -Dedupe can refuse to
      suppress against state it knows is only half enumerated. The unsafe
      direction is not a smaller prior set — that just lets a finding come back
      as new — but the reverse: a caller pointing at partial state and reading a
      'dropped-semantic' verdict is told a prior review raised this, when the
      prior review is only half known.

      NOTE: -Resolve records this flag in review-threads.json when it fails to
      enumerate every review thread. That file is a usable -Dedupe prior for
      bot-authored inline comments that carry a last-line fingerprint marker
      (`<!-- pr-review:fp=... sfp=... -->`). Markerless pre-feature threads,
      human comments, and summary-only entries are skipped — the finding comes
      back as new, which is the safe direction. `complete: false` still refuses
      suppression unless the caller passes -AllowIncompletePrior. Unresolved
      bot identity, or a resolved login that matches no marker-bearing [bot]
      thread, is a separate coverage gap recorded by Get-PriorFingerprints.

      Silence is treated as complete on purpose. Hand-written prior files and
      plain findings arrays carry no completeness flag, and demanding one would
      break every caller that legitimately has nothing to declare.
    #>
    param($PriorDocument)

    if ($null -eq $PriorDocument) { return $null }

    if (Test-HasProperty -Object $PriorDocument -Name 'complete') {
        $complete = Get-PropertyValue -Object $PriorDocument -Name 'complete'
        if ($complete -is [bool] -and -not $complete) {
            $reason = [string](Get-PropertyValue -Object $PriorDocument -Name 'incompleteReason')
            if ([string]::IsNullOrWhiteSpace($reason)) { $reason = 'no reason recorded' }
            return $reason
        }
    }
    return $null
}

function Invoke-Dedupe {
    param(
        [Parameter(Mandatory)][string]$FindingsPath,
        [Parameter(Mandatory)][string]$PriorPath,
        [switch]$AllowIncompletePrior
    )

    $doc = Read-JsonFile -Path $FindingsPath
    $prior = Read-JsonFile -Path $PriorPath
    $coverageGap = Get-PriorCoverageGap -PriorDocument $prior
    if ($coverageGap -and -not $AllowIncompletePrior) {
        throw ("Refusing to dedupe against '$PriorPath': the prior review state is incomplete " +
            "($coverageGap). Suppressing a finding as already-raised requires knowing what was raised, and " +
            'that is exactly what is missing here. Re-run -Resolve until thread coverage is complete, or pass ' +
            '-AllowIncompletePrior to accept suppression against partial prior state.')
    }
    $items = Get-FindingsArray -Document $doc
    $priorSets = Get-PriorFingerprints -PriorDocument $prior
    $identityGap = $null
    if (Test-HasProperty -Object $priorSets -Name 'identityGap') {
        $identityGap = [string](Get-PropertyValue -Object $priorSets -Name 'identityGap')
        if ([string]::IsNullOrWhiteSpace($identityGap)) { $identityGap = $null }
    }

    if ($identityGap -and -not $AllowIncompletePrior) {
        throw ("Refusing to dedupe against '$PriorPath': bot identity for thread mining is not usable " +
            "($identityGap). Available prior threads plus unresolved identity, or a resolved login that " +
            'matches no bot-authored marker thread, cannot claim complete coverage. Set PR_REVIEW_BOT_LOGIN ' +
            'or the script binding to the login that posted the markers, or pass -AllowIncompletePrior to ' +
            'proceed without suppressing against those threads.')
    }

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
            [void](Use-SemanticOccurrenceCredit -Counts $priorSets.semantic -Key $sfp)
            $hash['dedupe'] = 'dropped-identical'
            $dropped.Add([pscustomobject]$hash)
        }
        elseif (Use-SemanticOccurrenceCredit -Counts $priorSets.semantic -Key $sfp) {
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
        # Recorded rather than merely warned about: a run that suppressed
        # against partial prior state has to be able to say so afterwards.
        priorCoverage = if ($coverageGap -or $identityGap) { 'INCOMPLETE' } else { 'COMPLETE' }
        priorCoverageNote = if ($coverageGap) { $coverageGap } else { $identityGap }
        identitySource = Get-PropertyValue -Object $priorSets -Name 'identitySource'
        identityLogin = Get-PropertyValue -Object $priorSets -Name 'identityLogin'
        identityGap = $identityGap
    }
    Write-Output ($result | ConvertTo-Json -Depth 100)
}

function Invoke-Ledger {
    <#
      Compute the completion verdict from the coverage state.

      COMPLETE / COMPLETE WITH QUESTIONS / INCOMPLETE were a judgement the host
      made in prose, which meant a run with a timed-out reviewer and eleven
      clean ones could reasonably be written up as complete. The verdict is
      mechanical here, and the reasons are enumerated, so the summary cannot
      claim coverage the ledger does not show.

      A skipped axis or file counts as covered only in the sense that it was
      accounted for; it must still carry a reason, and a skip without one is a
      gap.
    #>
    param([Parameter(Mandatory)][string]$StatePath)

    $doc = Read-JsonFile -Path $StatePath
    if ($null -eq $doc) { throw "Ledger state '$StatePath' is empty or unreadable." }

    $gaps = [System.Collections.Generic.List[string]]::new()
    $questions = [System.Collections.Generic.List[string]]::new()

    foreach ($axis in @((Get-PropertyValue -Object $doc -Name 'axes'))) {
        if ($null -eq $axis) { continue }
        $name = [string](Get-PropertyValue -Object $axis -Name 'name')
        if ([string]::IsNullOrWhiteSpace($name)) { $name = '(unnamed axis)' }
        $status = ([string](Get-PropertyValue -Object $axis -Name 'status')).Trim().ToLowerInvariant()
        if ($script:CleanAxisStatuses -notcontains $status) {
            $shown = if ($status) { $status } else { 'no status recorded' }
            $gaps.Add("axis '$name' did not produce coverage ($shown)")
            continue
        }
        if ($status -eq 'skipped') {
            $reason = [string](Get-PropertyValue -Object $axis -Name 'reason')
            if ([string]::IsNullOrWhiteSpace($reason)) {
                $gaps.Add("axis '$name' was skipped with no reason recorded")
            }
        }
    }

    foreach ($file in @((Get-PropertyValue -Object $doc -Name 'files'))) {
        if ($null -eq $file) { continue }
        $path = [string](Get-PropertyValue -Object $file -Name 'path')
        if ([string]::IsNullOrWhiteSpace($path)) { $path = '(unnamed file)' }
        $disp = ([string](Get-PropertyValue -Object $file -Name 'disposition')).Trim().ToLowerInvariant()
        if ($script:CleanFileDispositions -notcontains $disp) {
            $shown = if ($disp) { $disp } else { 'no disposition recorded' }
            $gaps.Add("changed file '$path' has no accounted disposition ($shown)")
            continue
        }
        if ($disp -eq 'skipped') {
            $reason = [string](Get-PropertyValue -Object $file -Name 'reason')
            if ([string]::IsNullOrWhiteSpace($reason)) {
                $gaps.Add("changed file '$path' was skipped with no reason recorded")
            }
        }
    }

    # -Resolve, -Preflight and -Post already print these two; carrying them into
    # the ledger is what stops a partial changed-file map or a truncated thread
    # list from being reported as a complete review.
    foreach ($axisName in @('fileMapCoverage', 'threadCoverage')) {
        if (-not (Test-HasProperty -Object $doc -Name $axisName)) { continue }
        $value = ([string](Get-PropertyValue -Object $doc -Name $axisName)).Trim()
        if ($value -and -not $value.Equals('COMPLETE', [System.StringComparison]::OrdinalIgnoreCase)) {
            $gaps.Add("$axisName is $value")
        }
    }

    foreach ($f in @((Get-PropertyValue -Object $doc -Name 'findings'))) {
        if ($null -eq $f) { continue }
        $verdict = ([string](Get-PropertyValue -Object $f -Name 'verdict')).Trim()
        if ($verdict.Equals('PLAUSIBLE', [System.StringComparison]::OrdinalIgnoreCase)) {
            $file = [string](Get-PropertyValue -Object $f -Name 'file')
            $summary = [string](Get-PropertyValue -Object $f -Name 'summary')
            $questions.Add("PLAUSIBLE finding in '$file': $summary")
        }
    }
    foreach ($q in @((Get-PropertyValue -Object $doc -Name 'openQuestions'))) {
        if ([string]::IsNullOrWhiteSpace([string]$q)) { continue }
        $questions.Add([string]$q)
    }

    $verdict = if ($gaps.Count -gt 0) { 'INCOMPLETE' }
    elseif ($questions.Count -gt 0) { 'COMPLETE WITH QUESTIONS' }
    else { 'COMPLETE' }

    $result = [pscustomobject]@{
        verdict   = $verdict
        gaps      = @($gaps)
        questions = @($questions)
    }
    Write-Output ($result | ConvertTo-Json -Depth 100)
}

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

      Workspace-root containment is enforced on *every* -BodyFile read, -Out or
      not. -Out narrows the readable surface further — the body file must then
      sit in the payload's own directory — but it is an *additional* constraint
      layered on top of containment, never a replacement for it: an earlier
      version dropped the root check whenever -Out was set, and because -Out was
      itself never validated, a caller could pass -Out and -BodyFile as a pair
      of paths outside the workspace (a private key beside a payload written to
      the same foreign directory) and the same-directory check would pass. The
      root walk now runs first, so both paths are proven inside the owned tree
      before the same-directory constraint is even consulted.
    #>
    param([string]$BodyText, [string]$BodyFile, [string]$OutPath)

    if ([string]::IsNullOrEmpty($BodyFile)) {
        return $BodyText
    }

    $full = Get-NormalizedFullPath -Path $BodyFile
    $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }

    # Always: the body file must live inside the workspace root, with no reparse
    # point on any ancestor. This is the containment the trust boundary depends
    # on; it runs regardless of -Out.
    Assert-WorkspaceContainedPath -FullPath $full -Description '-BodyFile'

    if (-not [string]::IsNullOrWhiteSpace($OutPath)) {
        # Additionally pin the read to the payload's own directory. -Out is
        # always the run directory this invocation owns, so there is no reason
        # for the body to live anywhere else, and pinning the two together
        # shrinks the readable surface from all of <temp>/pr-review down to one
        # directory.
        $outDir = Get-NormalizedFullPath -Path (Split-Path -Parent (Get-NormalizedFullPath -Path $OutPath))
        $bodyDir = Get-NormalizedFullPath -Path (Split-Path -Parent $full)
        if (-not [string]::Equals($bodyDir, $outDir, $comparison)) {
            throw "-BodyFile must sit in the same directory as -Out ('$outDir'); refusing to read '$full'."
        }
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

function Test-CarriesFenceMarker {
    <#
      True when the text contains a line that opens or closes a Markdown code
      fence. Anchored per line because a fence is only a fence at the start of
      a line; a stray ``` inside prose is not one, and refusing it would reject
      legitimate findings that quote fence syntax mid-sentence.
    #>
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return $false }
    return [regex]::IsMatch($Text, '(?m)^[ \t]{0,3}(`{3,}|~{3,})')
}

function Get-FenceRejectionDetail {
    <#
      Shared tail for the messages that refuse a Markdown code fence in a
      verbatim-rendered finding field. Kept in one place so -Validate (which
      reports the violation) and the render path (which throws) explain the
      refusal identically.
    #>
    return ('It is rendered verbatim into the comment body, where a fence can open or close a ' +
        'committable suggestion block that no gate inspected, so it is refused rather than stripped. ' +
        'Remove the fence.')
}

function Format-InlineCommentBody {
    <#
      Compose (or pass through) the body GitHub will render.

      A committable ```suggestion fence is a one-click write to the head
      branch, so two things gate it. The replacement has to have been checked
      against the pinned head — 'suggestion_verified' — because an unchecked
      suggestion that looks plausible is the one a reviewer commits without
      reading. And the text itself must not carry a fence marker, in either the
      suggestion or a caller-supplied raw body: a suggestion whose text closes
      the fence early can continue past it with arbitrary Markdown, or open a
      second suggestion fence whose contents no gate here ever saw. Unverified
      text still gets shown, just as an inert code block rather than a button.

      Exact PR-review fingerprint-marker comments in verbatim fields (and in a
      caller-supplied raw body) are stripped rather than refused: a spoofed
      `<!-- pr-review:fp=... sfp=... -->` in summary or failure_scenario would
      otherwise sit in the posted body where a first-match parser could harvest
      it. Other HTML comments are preserved. The helper's real marker is
      appended after this function returns, as the last line.
    #>
    param($Finding)

    $explicit = Get-PropertyValue -Object $Finding -Name 'body'
    if (-not [string]::IsNullOrWhiteSpace([string]$explicit)) {
        if (Test-CarriesFenceMarker -Text ([string]$explicit)) {
            throw ("Finding for '$([string](Get-PropertyValue -Object $Finding -Name 'file'))' supplies a raw " +
                "'body' containing a code fence. A pre-rendered body bypasses the suggestion gates, so a fence " +
                'inside it could post a committable suggestion that was never verified. Drop the fence, or move ' +
                "the replacement into 'suggestion' with 'suggestion_verified': true.")
        }
        return (Remove-PrReviewFingerprintMarkers -Text ([string]$explicit))
    }

    $severity = [string](Get-PropertyValue -Object $Finding -Name 'severity')
    $category = [string](Get-PropertyValue -Object $Finding -Name 'category')
    $suggestion = [string](Get-PropertyValue -Object $Finding -Name 'suggestion')
    $stripped = @{}

    foreach ($verbatim in $script:VerbatimFindingFields) {
        $verbatimText = [string](Get-PropertyValue -Object $Finding -Name $verbatim)
        if (Test-CarriesFenceMarker -Text $verbatimText) {
            throw ("Finding for '$([string](Get-PropertyValue -Object $Finding -Name 'file'))' has a " +
                "'$verbatim' containing a Markdown code fence. " + (Get-FenceRejectionDetail))
        }
        $stripped[$verbatim] = Remove-PrReviewFingerprintMarkers -Text $verbatimText
    }

    $summary = $stripped['summary']
    $failure = $stripped['failure_scenario']

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("**${severity}** · ${category}")
    $lines.Add($summary)
    $lines.Add('')
    $lines.Add("Failure scenario: $failure")
    if ($suggestion) {
        if (Test-CarriesFenceMarker -Text $suggestion) {
            throw ("Finding for '$([string](Get-PropertyValue -Object $Finding -Name 'file'))' has a " +
                "'suggestion' containing a code fence. Fenced text cannot be nested inside a suggestion block " +
                'without ending it early, so this is refused rather than emitted. Remove the fence from the ' +
                'replacement text.')
        }
        $verified = Get-PropertyValue -Object $Finding -Name 'suggestion_verified'
        $lines.Add('')
        if ($verified -is [bool] -and $verified) {
            $lines.Add('```suggestion')
            $lines.Add($suggestion)
            $lines.Add('```')
        }
        else {
            $lines.Add('Suggested change (not verified against the pinned head, so not committable):')
            $lines.Add('```')
            $lines.Add($suggestion)
            $lines.Add('```')
        }
    }
    return ($lines -join "`n")
}

function Test-IsRuleCitation {
    <#
      True when the text looks like a citation of a written rule rather than an
      assertion that one exists.

      The Low-severity inline gate exists so a nit has to point at something
      the repository actually wrote down. A non-whitespace check does not do
      that: "team convention" or "best practice" passes it while citing
      nothing, which is exactly the unbacked nit the gate was added to keep out
      of the diff. A citation has to name a source — a file path, a rules
      document, or a section reference — so that is what is required. The bar
      is deliberately mechanical: it cannot tell whether the cited rule says
      what the finding claims, only that a source was named at all.
    #>
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $trimmed = $Text.Trim()

    # A path-like token: something with a directory separator or a file
    # extension (CLAUDE.md, rules/pipeline/delegation.mdc, src/Foo.cs:42).
    if ([regex]::IsMatch($trimmed, '(?i)[\w.\-]+[/\\][\w./\\-]+')) { return $true }
    if ([regex]::IsMatch($trimmed, '(?i)\b[\w-]+\.(md|mdc|json|yml|yaml|ps1|cs|editorconfig|props|targets|txt)\b')) { return $true }

    # A section reference: "§3.2", "section 4", "rule R-12", "ADR 0008".
    if ([regex]::IsMatch($trimmed, '(?i)(§\s*[\w.\-]+|\bsection\s+[\w.\-]+|\brule\s+[\w.\-]*\d|\badr[\s-]*\d+)')) { return $true }

    return $false
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

    <#
      Verdict and placement alone let a CONFIRMED Low finding with a file and
      line post inline with nothing behind it but the model's say-so. The
      Minimality rule (SKILL.md) and issue #83's acceptance criteria both say
      Low/nit feedback is not posted inline unless it violates an explicit
      repository rule, so a Low finding needs a citation to earn the same
      placement a Medium+ finding gets for free. Comparison is
      case-insensitive because severity casing is not something callers are
      required to normalize before this runs.
    #>
    $severity = [string](Get-PropertyValue -Object $Finding -Name 'severity')
    if ($severity.Equals('Low', [System.StringComparison]::OrdinalIgnoreCase)) {
        $rule = [string](Get-PropertyValue -Object $Finding -Name 'rule')
        if (-not (Test-IsRuleCitation -Text $rule)) { return $false }
    }

    if ($placement -eq 'inline' -or [string]::IsNullOrWhiteSpace($placement)) { return $true }
    return $false
}

function New-ReviewCommentFromFinding {
    param($Finding)

    $body = Format-InlineCommentBody -Finding $Finding
    $fp = Get-FindingFingerprint -Finding $Finding
    $sfp = Get-FindingSemanticFingerprint -Finding $Finding
    $marker = "<!-- pr-review:fp=$fp sfp=$sfp -->"
    if ([string]::IsNullOrEmpty($body)) {
        $body = $marker
    }
    else {
        $body = $body.TrimEnd("`r", "`n") + "`n" + $marker
    }

    $comment = [ordered]@{
        path = [string](Get-PropertyValue -Object $Finding -Name 'file')
        body = $body
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

function Get-NotInlineReasonTag {
    param($Finding)
    $verdict = [string](Get-PropertyValue -Object $Finding -Name 'verdict')
    if ($verdict.Equals('PLAUSIBLE', [System.StringComparison]::OrdinalIgnoreCase)) {
        return 'PLAUSIBLE'
    }
    $severity = [string](Get-PropertyValue -Object $Finding -Name 'severity')
    if ($severity.Equals('Low', [System.StringComparison]::OrdinalIgnoreCase)) {
        $rule = [string](Get-PropertyValue -Object $Finding -Name 'rule')
        if (-not (Test-IsRuleCitation -Text $rule)) {
            return 'Low, no rule'
        }
    }
    return 'not inline'
}

function ConvertTo-Lf {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return [string]$Text }
    return $Text.Replace("`r`n", "`n").Replace("`r", "`n")
}

function Convert-LegacyNotInlineHeadings {
    param([string]$Body)
    $text = ConvertTo-Lf $Body
    # Old helper headings are not a substitute for ## Not inline. Rewrite them
    # so demotions merge into one section instead of being skipped or doubled.
    $text = [regex]::Replace($text, '(?m)^##\s+Questions(?:\s*/\s*non-inline findings)?\s*$', '## Not inline')
    $text = [regex]::Replace($text, '(?m)^##\s+Unmappable findings\s*$', '## Not inline')
    return $text
}

function Merge-NotInlineSection {
    param(
        [string]$Body,
        [string[]]$Entries
    )
    $text = Convert-LegacyNotInlineHeadings -Body $Body
    $block = [System.Collections.Generic.List[string]]::new()
    if ($text -notmatch '(?m)^##\s+Not inline\b') {
        if (-not [string]::IsNullOrWhiteSpace($text)) { $block.Add('') }
        $block.Add('## Not inline')
        $block.Add('')
    }
    foreach ($entry in @($Entries)) {
        if ($null -ne $entry) { $block.Add([string]$entry) }
    }
    if ($block.Count -eq 0) { return $text }
    $joined = ($block -join "`n")
    if ([string]::IsNullOrWhiteSpace($text)) { return ($joined.TrimStart() + "`n") }
    return ($text.TrimEnd() + "`n" + $joined + "`n")
}

function Format-UnmappableNotInlineEntry {
    param($Comment)
    $path = [string](Get-PropertyValue -Object $Comment -Name 'path')
    $line = Get-PropertyValue -Object $Comment -Name 'line'
    $cbody = ConvertTo-Lf ([string](Get-PropertyValue -Object $Comment -Name 'body'))
    $kept = [System.Collections.Generic.List[string]]::new()
    foreach ($rawLine in @($cbody -split "`n")) {
        $trimmed = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        if ($trimmed -match '^(Evidence|Failure scenario):') { continue }
        if ($trimmed -match '^<!-- pr-review:') { continue }
        $kept.Add($trimmed)
    }
    $one = $null
    if ($kept.Count -ge 2 -and $kept[0] -match '^\*\*') {
        $one = $kept[1]
    }
    elseif ($kept.Count -ge 1) {
        $one = [regex]::Replace($kept[0], '\s+', ' ').Trim()
    }
    if ($one) {
        return "- [unmappable: not in diff] ``${path}:${line}`` — $one"
    }
    return "- [unmappable: not in diff] ``${path}:${line}``"
}

function Invoke-BuildPayload {
    param(
        [Parameter(Mandatory)][string]$FindingsPath,
        [Parameter(Mandatory)][string]$BaseSha,
        [Parameter(Mandatory)][string]$HeadSha,
        [string]$BodyText,
        [string]$BodyFile,
        # Writing the payload here (rather than piping stdout to a file) is what
        # lets the provenance sidecar be written beside it, so -Preflight and
        # -Post can tell a gated payload from a hand-assembled one.
        [string]$OutPath
    )

    $null = $BaseSha  # reserved for callers/workspace symmetry; payload uses head

    # -Out is written with a bare Set-Content (plus a provenance sidecar), so it
    # is a write primitive: an unvalidated -Out lets a caller drop the payload
    # anywhere on disk, and — because a -BodyFile beside -Out is trusted — read
    # any file it names into the published body. Prove -Out lives inside the
    # owned workspace before anything is read or written. Empty -Out is the
    # stdout path and touches no file.
    if (-not [string]::IsNullOrWhiteSpace($OutPath)) {
        Assert-WorkspaceContainedPath -FullPath (Get-NormalizedFullPath -Path $OutPath) -Description '-Out'
    }

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
        $script:PrReviewExitCode = 1
        return
    }

    # Not $bodyText: PowerShell variable names are case-insensitive, so that would
    # assign straight back into the $BodyText parameter. -OutPath is passed so a
    # body file is pinned to the payload's own directory when the payload is
    # written to a known -Out.
    $summaryBody = Get-BodyText -BodyText $BodyText -BodyFile $BodyFile -OutPath $OutPath
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

    # PLAUSIBLE / Low-without-rule / other non-inline findings stay out of
    # comments and land in one ## Not inline section. Caller headings such as
    # ## Questions are rewritten, never treated as a reason to skip.
    if ($summaryOnly.Count -gt 0) {
        $entries = [System.Collections.Generic.List[string]]::new()
        foreach ($f in $summaryOnly) {
            $sev = [string](Get-PropertyValue -Object $f -Name 'severity')
            $cat = [string](Get-PropertyValue -Object $f -Name 'category')
            $sum = [string](Get-PropertyValue -Object $f -Name 'summary')
            if (Test-CarriesFenceMarker -Text $sum) {
                throw ("Summary-only finding for '$([string](Get-PropertyValue -Object $f -Name 'file'))' has a " +
                    "'summary' containing a Markdown code fence. " + (Get-FenceRejectionDetail))
            }
            $file = [string](Get-PropertyValue -Object $f -Name 'file')
            $tag = Get-NotInlineReasonTag -Finding $f
            $entries.Add("- [$tag] **$sev**/$cat ``$file`` — $sum")
        }
        $summaryBody = Merge-NotInlineSection -Body $summaryBody -Entries @($entries)
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
        $script:PrReviewExitCode = 1
        return
    }

    $json = $payload | ConvertTo-Json -Depth 100
    if (-not [string]::IsNullOrWhiteSpace($OutPath)) {
        Set-Content -LiteralPath $OutPath -Value $json -Encoding utf8
        Write-PayloadProvenance -PayloadPath $OutPath
        Write-Output "payload: $OutPath"
        Write-Output "payloadSource: BUILD-PAYLOAD"
        return
    }
    Write-Output $json
}

function Get-PayloadProvenancePath {
    param([Parameter(Mandatory)][string]$PayloadPath)
    return ($PayloadPath + '.provenance.json')
}

function Get-FileDigest {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-PayloadProvenance {
    <#
      Record that these exact payload bytes came out of -BuildPayload.

      The inline-placement gates — CONFIRMED-only, the Low+citation rule, the
      suggestion-fence rules — all live in -BuildPayload. A payload handed
      straight to -Preflight or -Post skips every one of them: schema
      validation still runs, and schema validation has no opinion about whether
      a Low nit cited a rule. Nothing forces the caller through -BuildPayload,
      and nothing can, so the next best thing is that the two verbs which
      publish say out loud which kind of payload they were given.

      The digest is what makes the sidecar mean anything. A bare marker file
      would still be there after the payload beside it was edited by hand,
      which is exactly the case worth catching.
    #>
    param([Parameter(Mandatory)][string]$PayloadPath)

    $provenance = [pscustomobject]@{
        source    = 'BUILD-PAYLOAD'
        sha256    = Get-FileDigest -Path $PayloadPath
        builtAt   = [DateTime]::UtcNow.ToString('o')
    }
    Write-JsonFile -Value $provenance -Path (Get-PayloadProvenancePath -PayloadPath $PayloadPath)
}

function Get-PayloadSource {
    <#
      'BUILD-PAYLOAD' when a provenance sidecar vouches for these exact bytes,
      otherwise 'UNVERIFIED' — which covers a hand-written payload, an edited
      one, and a -BuildPayload run that streamed to stdout instead of -Out.
      UNVERIFIED is a statement about what is known, not an accusation.
    #>
    param([Parameter(Mandatory)][string]$PayloadPath)

    $sidecar = Get-PayloadProvenancePath -PayloadPath $PayloadPath
    if (-not (Test-Path -LiteralPath $sidecar)) { return 'UNVERIFIED (no provenance sidecar)' }

    $doc = $null
    try { $doc = Read-JsonFile -Path $sidecar }
    catch { return 'UNVERIFIED (provenance sidecar unreadable)' }
    if ($null -eq $doc) { return 'UNVERIFIED (provenance sidecar unreadable)' }

    $recorded = [string](Get-PropertyValue -Object $doc -Name 'sha256')
    if ([string]::IsNullOrWhiteSpace($recorded)) { return 'UNVERIFIED (provenance sidecar records no digest)' }
    if ($recorded.ToLowerInvariant() -ne (Get-FileDigest -Path $PayloadPath)) {
        return 'UNVERIFIED (payload was modified after -BuildPayload wrote it)'
    }
    return 'BUILD-PAYLOAD'
}

function ConvertTo-ReviewMarkdown {
    param($Payload)

    $lf = "`n"
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("# Pull request review (manual fallback)$lf")
    [void]$sb.Append($lf)
    [void]$sb.Append("commit_id: ``$($Payload.commit_id)``$lf")
    [void]$sb.Append("event: COMMENT$lf")
    [void]$sb.Append($lf)
    [void]$sb.Append("## Summary$lf")
    [void]$sb.Append($lf)
    [void]$sb.Append((ConvertTo-Lf ([string]$Payload.body)))
    [void]$sb.Append($lf)
    [void]$sb.Append($lf)

    $comments = @()
    if (Test-HasProperty -Object $Payload -Name 'comments') {
        $comments = @((Get-PropertyValue -Object $Payload -Name 'comments'))
    }
    if ($comments.Count -gt 0) {
        [void]$sb.Append("## Inline comments$lf")
        [void]$sb.Append($lf)
        $n = 1
        foreach ($c in $comments) {
            $path = [string](Get-PropertyValue -Object $c -Name 'path')
            $line = Get-PropertyValue -Object $c -Name 'line'
            $start = Get-PropertyValue -Object $c -Name 'start_line'
            $side = [string](Get-PropertyValue -Object $c -Name 'side')
            if (-not $side) { $side = 'RIGHT' }
            $loc = if ($null -ne $start) { "${path}:${start}-${line} ($side)" } else { "${path}:${line} ($side)" }
            [void]$sb.Append("### Comment $n — ``$loc``$lf")
            [void]$sb.Append($lf)
            [void]$sb.Append((ConvertTo-Lf ([string](Get-PropertyValue -Object $c -Name 'body'))))
            [void]$sb.Append($lf)
            [void]$sb.Append($lf)
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
        $script:PrReviewExitCode = 1
        return
    }
    Write-Output (ConvertTo-ReviewMarkdown -Payload $payload)
}

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
            # A file in the diff with no patch text at all is a different thing
            # from a file whose hunks simply do not cover the cited line, and
            # the two used to report identically. GitHub omits the patch for a
            # binary file and for one too large to inline, so the line was
            # never checkable — telling the reviewer "line 42 not in diff
            # hunks" sends them to re-derive a location that cannot exist.
            noPatch  = [string]::IsNullOrEmpty($patch)
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

    $entry = $DiffMap[$key]
    if ($entry.ContainsKey('noPatch') -and $entry['noPatch']) {
        $Problems.Add("no patch available for $path (binary or oversized), so no line is commentable")
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

function Move-UnmappableToSummary {
    param(
        $Payload,
        [object[]]$UnmappableComments,
        [string]$CoverageNote
    )

    $body = [string]$Payload.body
    $entries = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($CoverageNote)) {
        # Say which cause applies. A demotion because the map ran out of files is
        # a coverage gap, not a stale location, and reading it as the latter
        # sends the reader looking for a defect that is not there.
        $entries.Add("Note: the changed-file map was incomplete — $CoverageNote. Some of these may be map gaps rather than stale locations.")
        $entries.Add('')
    }
    foreach ($c in $UnmappableComments) {
        $entries.Add((Format-UnmappableNotInlineEntry -Comment $c))
    }

    $newBody = Merge-NotInlineSection -Body $body -Entries @($entries)

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
        body      = $newBody
        comments  = $kept
    }
}

