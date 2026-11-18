<!--
SPDX-FileCopyrightText: 2026 SyuanTsai
SPDX-License-Identifier: Apache-2.0
-->

# Host-resolved Jira Fast Path

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
$configureScript = [IO.Path]::GetFullPath((Join-Path $skillRoot 'scripts/Configure-JiraApiAccess.ps1'))
$testScript = [IO.Path]::GetFullPath((Join-Path $skillRoot 'scripts/Test-JiraApiAccess.ps1'))
if (-not $configureScript.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -or -not $testScript.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $configureScript -PathType Leaf) -or -not (Test-Path -LiteralPath $testScript -PathType Leaf)) { throw 'Installed Skill helper path is not bound to the host-resolved Skill root.' }
Assert-NoReparseAncestors $configureScript
Assert-NoReparseAncestors $testScript
pwsh -NoProfile -File $configureScript -BaseUrl '<confirmed-jira-site-root>' -Email '<account-email>' -TargetScope Process -TestConnection
pwsh -NoProfile -File $configureScript -BaseUrl '<confirmed-jira-site-root>' -Email '<account-email>' -TargetScope User -PersistTokenToUser -TestConnection
```

## Manual persistence on Linux and macOS

[Read the manual persistence guidance for this Skill.](manual-persistence-linux-macos.md)
