<!--
SPDX-FileCopyrightText: 2026 SyuanTsai
SPDX-License-Identifier: Apache-2.0
-->

# Host-resolved Bitbucket Fast Path

Resolve the installed Skill root supplied by the host before invoking either helper. The consumer repository must not provide the executable. Bind both helper paths under that root, reject reparse-point ancestors, and never place a real token in an argument:

```powershell
$skillRoot = [IO.Path]::GetFullPath('<host-resolved installed Skill root>')
$rootPrefix = $skillRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
function Assert-NoReparseAncestors([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Installed Skill path must not use a reparse point: $current" }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $current) { break }
        $current = $parent
    }
}
Assert-NoReparseAncestors $skillRoot
$configureScript = [IO.Path]::GetFullPath((Join-Path $skillRoot 'scripts/Configure-BitbucketApiAccess.ps1'))
$testScript = [IO.Path]::GetFullPath((Join-Path $skillRoot 'scripts/Test-BitbucketApiAccess.ps1'))
if (-not $configureScript.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -or -not $testScript.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $configureScript -PathType Leaf) -or -not (Test-Path -LiteralPath $testScript -PathType Leaf)) { throw 'Installed Skill helper path is not bound to the host-resolved Skill root.' }
Assert-NoReparseAncestors $configureScript
Assert-NoReparseAncestors $testScript
pwsh -NoProfile -File $configureScript -Email '<account-email>' -Workspace '<workspace>' -TargetScope Process -TestConnection
pwsh -NoProfile -File $configureScript -Email '<account-email>' -Workspace '<workspace>' -TargetScope User -PersistTokenToUser -TestConnection
```

Bitbucket access, through an approved connector or the REST API token, is for the work environment only. If the request comes from a personal environment, stop and ask the user before any Bitbucket access.

## Manual persistence on Linux and macOS

On Linux and macOS, this Fast Path configures only the current process. User scope is supported on Windows only, so the configure script rejects `-TargetScope User` on these hosts.

To keep Bitbucket settings across sessions, you can add the non-secret `BITBUCKET_*` values to your own shell startup file yourself, and inject `BITBUCKET_API_TOKEN` through an approved secret-store launcher when you start the Agent host. Never write the token in plain text to a shell startup file.

After you change these settings, recreate the Agent host process; only processes started after the change inherit them.

This Skill never edits shell startup files or OS secret stores.
