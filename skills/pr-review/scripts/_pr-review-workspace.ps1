# Workspace and pinned-identity helpers for pr-review.ps1. Dot-sourced by the
# entrypoint after _pr-review-common.ps1. No exit statements. No top-level
# executable code beyond function and constant definitions. Load order is a
# contract: common, then workspace, then entrypoint.
# See docs/adr/0016-pr-review-helper-splits-around-workspace-seam.md.

# Owner-only (0700). Held as a constant because the create and the verify have
# to agree: New-PrivateDirectory applies it atomically on Unix and
# Set-PrivateDirectoryMode re-applies it, so a drift between the two would
# silently reopen the window the atomic create exists to close.
$script:PrivateDirectoryMode = [System.IO.UnixFileMode]::UserRead -bor
                               [System.IO.UnixFileMode]::UserWrite -bor
                               [System.IO.UnixFileMode]::UserExecute

function New-PrReviewIdentity {
    <#
      Construction-time factory for the pinned identity (owner/repo/number/
      baseSha/headSha/runId). Null or empty throws here, not at use. Property
      names are PascalCase to match existing parameter names.
    #>
    param(
        [string]$Owner,
        [string]$Repo,
        [int]$Number,
        [string]$HeadSha,
        [AllowEmptyString()][AllowNull()][string]$BaseSha,
        [string]$RunId
    )

    if ([string]::IsNullOrWhiteSpace($Owner)) {
        throw 'New-PrReviewIdentity: Owner must be a non-empty string.'
    }
    if ([string]::IsNullOrWhiteSpace($Repo)) {
        throw 'New-PrReviewIdentity: Repo must be a non-empty string.'
    }
    if ($Number -le 0) {
        throw 'New-PrReviewIdentity: Number must be greater than 0.'
    }
    if ($HeadSha -notmatch '^[0-9a-fA-F]{7,}$') {
        throw "New-PrReviewIdentity: HeadSha must be at least 7 hex characters; got: $HeadSha"
    }
    if (-not [string]::IsNullOrEmpty($BaseSha) -and $BaseSha -notmatch '^[0-9a-fA-F]{7,}$') {
        throw "New-PrReviewIdentity: BaseSha must be at least 7 hex characters or empty; got: $BaseSha"
    }
    # Same constraint Get-RunMarker enforces. Duplicated here so construction
    # fails closed before a malformed run id is threaded through publication.
    if ($RunId -notmatch '^[0-9a-fA-F]{6,64}$') {
        throw "Refusing to use run id '$RunId': a run id must be 6-64 hex characters. Re-run -Resolve to mint one."
    }

    return [pscustomobject]@{
        Owner   = $Owner
        Repo    = $Repo
        Number  = $Number
        HeadSha = $HeadSha
        BaseSha = $(if ($null -eq $BaseSha) { '' } else { $BaseSha })
        RunId   = $RunId
    }
}

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
            # A *fresh* DirectorySecurity, not one read back from the directory.
            # Get-Acl plus Set-Acl round-trips the owner and audit sections as
            # well as the DACL, and rewriting those needs privileges an ordinary
            # user does not hold (SeSecurityPrivilege for the SACL,
            # SeRestorePrivilege to reassign an owner) — so a directory this
            # script had already locked down failed to be locked down a second
            # time, on its own workspace. Only the access rules are set here, so
            # only the DACL is written.
            $acl = [System.Security.AccessControl.DirectorySecurity]::new()
            # Break inheritance without copying the inherited rules down, so the
            # single grant below is the whole DACL.
            $acl.SetAccessRuleProtection($true, $false)
            $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
                    [System.Security.Principal.WindowsIdentity]::GetCurrent().User,
                    [System.Security.AccessControl.FileSystemRights]::FullControl,
                    'ContainerInherit, ObjectInherit',
                    [System.Security.AccessControl.PropagationFlags]::None,
                    [System.Security.AccessControl.AccessControlType]::Allow))
            # On .NET Core SetAccessControl lives on FileSystemAclExtensions, not
            # on DirectoryInfo itself, and PowerShell does not surface C#
            # extension methods as instance calls.
            [System.IO.FileSystemAclExtensions]::SetAccessControl(
                [System.IO.DirectoryInfo]::new($Path), $acl)
        }
        catch {
            throw ("Refusing to use review workspace '$Path': owner-only permissions could not be applied " +
                "($($_.Exception.Message)). On a shared host the review state would stay readable by other " +
                'local users, so this fails rather than continuing. Point TEMP at a directory you own and re-run.')
        }
        return
    }
    try {
        [System.IO.File]::SetUnixFileMode($Path, $script:PrivateDirectoryMode)
    }
    catch {
        throw ("Refusing to use review workspace '$Path': 0700 could not be applied " +
            "($($_.Exception.Message)). Some filesystems (NFS, some container temp mounts) reject the call, and " +
            'a 0755 run directory lets another local user read review state or plant prior-dedupe state that ' +
            'suppresses findings. Point TMPDIR at a filesystem that supports POSIX modes and re-run.')
    }
}

function New-PrivateDirectory {
    <#
      Create a directory that is owner-only from the moment it exists.

      Creating it and then tightening it leaves a window — however short — in
      which the directory sits at whatever the process umask allows, and on a
      shared host that is long enough for another local user to open a handle
      that survives the later chmod. .NET's mode-carrying CreateDirectory
      overload applies the mode as part of the create on Unix; Windows has no
      equivalent, so there the ACL is still applied immediately afterwards by
      the caller (the Windows exposure is the inherited-ACL default, not a
      umask race).
    #>
    param([Parameter(Mandatory)][string]$Path)

    if ($IsWindows) {
        New-Item -ItemType Directory -Path $Path -ErrorAction Stop | Out-Null
        return
    }
    [void][System.IO.Directory]::CreateDirectory($Path, $script:PrivateDirectoryMode)
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
        # An unreadable owner is not a weaker version of a readable one: it is
        # the absence of the proof this function exists to obtain. Warning and
        # continuing let an unowned directory through on exactly the shared
        # hosts the check is for, so it is treated the same as a foreign owner.
        throw ("Refusing to use review workspace '$Path': its owner could not be read, so it cannot be " +
            'proved to belong to this user. Remove it and re-run, or point TMPDIR at a filesystem that ' +
            'reports ownership.')
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
            New-PrivateDirectory -Path $dir
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
            New-PrivateDirectory -Path $dir
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
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)][string]$Workspace
    )

    $Owner = [string]$Identity.Owner
    $Repo = [string]$Identity.Repo
    $Number = [int]$Identity.Number
    $HeadSha = [string]$Identity.HeadSha
    $RunId = [string]$Identity.RunId

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

function Assert-WorkspaceContainedPath {
    <#
      Prove a full path sits inside the review workspace root
      (<temp>/pr-review) with no symlink or NTFS junction on any ancestor
      directory. Used for both a -BodyFile that is read and an -Out that is
      written, so a single invocation can never reach outside the tree this
      script owns.

      The prefix check is purely lexical: it only tells us the leaf's *name*
      sits under the root, nothing about whether an ancestor got there by a
      reparse point. A junction on any directory between the root and the leaf
      rewrites the access to wherever it points, so `<root>/run/link/hosts.yml`
      can resolve outside the workspace entirely while the path string still
      starts with the root prefix. Walk every level the workspace owns,
      outermost first, applying the same real-directory / not-a-reparse-point /
      owned-by-current-user check Assert-CanonicalRunWorkspace applies to the
      run tree, so a redirect anywhere in the chain is caught before the leaf is
      trusted. The leaf itself is not required to exist — only its ancestors are
      walked — so this validates an -Out destination before it is created.
    #>
    param(
        [Parameter(Mandatory)][string]$FullPath,
        [Parameter(Mandatory)][string]$Description
    )

    $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    $root = Get-NormalizedFullPath -Path (Join-Path ([System.IO.Path]::GetTempPath()) 'pr-review')
    $rootPrefix = $root + [System.IO.Path]::DirectorySeparatorChar
    if (-not $FullPath.StartsWith($rootPrefix, $comparison)) {
        throw "$Description must live inside the review workspace root '$root'; refusing '$FullPath'."
    }

    $parentDir = Split-Path -Parent $FullPath
    $relative = $parentDir.Substring($root.Length).Trim([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $segments = @()
    if ($relative) {
        $segments = @($relative -split '[\\/]+' | Where-Object { $_ -ne '' })
    }
    $current = $root
    Assert-SafeWorkspacePath -Path $current
    foreach ($segment in $segments) {
        $current = Join-Path $current $segment
        Assert-SafeWorkspacePath -Path $current
    }
}

