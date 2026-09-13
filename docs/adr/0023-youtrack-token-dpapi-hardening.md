# YouTrack token DPAPI hardening

We introduce an opt-in DPAPI-encrypted file option as a hardened persistence mechanism for `YOUTRACK_TOKEN` on Windows at `$env:USERPROFILE\.dotnet-agent-harness\youtrack-token`.

## Context

`YOUTRACK_TOKEN` persistence on Windows previously relied on User-scope environment variables stored in HKCU (`HKEY_CURRENT_USER\Environment`). Because environment variables are readable by any process running as the user, actively inherited by child processes, and easily enumerable via registry tools or environment listings, persistent plaintext storage in HKCU represents an unnecessary security exposure for long-lived permanent tokens.

## Decision

We introduce an opt-in DPAPI-encrypted file option as a hardened persistence mechanism for `YOUTRACK_TOKEN` on Windows at `$env:USERPROFILE\.dotnet-agent-harness\youtrack-token`.

Token resolution in `get-task.ps1` checks sources in the following order (token only — DPAPI resolution is strictly gated on `YOUTRACK_TOKEN`):

1. Process environment variable (`$env:YOUTRACK_TOKEN`) — explicit override.
2. DPAPI file at `$env:USERPROFILE\.dotnet-agent-harness\youtrack-token` (Windows only).
3. User-scope environment variable in HKCU (legacy/baseline fallback, Windows only).

`YOUTRACK_URL` remains stored only in environment variables; the DPAPI file holds only the token secret.

If the DPAPI file exists but fails decryption (corrupt, restored from backup, or wrong user/machine), the reader logs a one-line path-only warning (never leaking token material or ciphertext) and falls back to User-scope environment variables.

## Consequences

* **Same-user scope limit**: DPAPI `ConvertFrom-SecureString` encrypts token material using keys tied to the Windows user account. Any process running under the same user account can still decrypt the blob programmatically. However, unlike environment variables or HKCU registry keys, the token is not passively inherited by child processes or exposed via environment enumeration.
* **Windows-only feature**: DPAPI encryption/decryption via `ConvertFrom-SecureString` / `ConvertTo-SecureString` is available natively on Windows. On non-Windows platforms, DPAPI file resolution is skipped and resolution relies on process environment variables.
* **Non-portability & Backup Restores**: The DPAPI blob is tied to the local user profile and machine SID; it is non-portable across machines or different user accounts. Restoring from backups on a new machine or user profile will fail decryption (triggering a path-only warning) and requires running the hardened setup script again.
* **File ACLs**: The file inherits default ACLs from `$env:USERPROFILE\.dotnet-agent-harness`.
* **Stale token fallback mitigation**: A `YOUTRACK_TOKEN` left in User-scope env (not cleared during migration) silently resumes authority whenever the DPAPI file is unreadable — clearing it during hardened setup and rotation is the mitigation.

## Considered options

* **Windows Credential Manager (via P/Invoke)**: Rejected due to significant P/Invoke / interop complexity, non-trivial script maintenance overhead, and external dependency risks within pure PowerShell scripts.
* **`Microsoft.PowerShell.SecretManagement` / `SecretStore` module**: Rejected because it introduces an external PowerShell module dependency, conflicting with the harness requirement of using built-in PowerShell features without external module installations.
* **Documentation-only guidance**: Rejected because without tooling support in `get-task.ps1`, users would have no seamless way to utilize encrypted token persistence.
