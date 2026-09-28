# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0

[CmdletBinding()]
param(
    [ValidateSet('Enable', 'Disable')][string]$Mode = 'Enable',
    [string]$RepositoryRoot = (Join-Path $PSScriptRoot '..')
)

$ErrorActionPreference = 'Stop'
$createdSnapshot = $null
$configuredSnapshot = $false

function Assert-PlainSnapshotFile {
    param([string]$Root, [string]$RelativePath)
    $path = $Root
    foreach ($part in @('') + $RelativePath.Split('/')) {
        if ($part) { $path = Join-Path $path $part }
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Hook snapshot paths must not contain reparse points.'
        }
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Hook snapshot file is unavailable.' }
    return $path
}

function Remove-OwnedHookSnapshot {
    param([string]$Path, [string]$CommonGitDirectory)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\','/'))
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not [IO.Path]::GetDirectoryName($full).Equals($CommonGitDirectory, $comparison) -or
        [IO.Path]::GetFileName($full) -cnotmatch '^atlassian-prepush-[0-9a-f]{32}$') {
        throw 'Refusing to remove an unowned hook directory.'
    }
    $items = @((Get-Item -LiteralPath $full -Force)) + @(Get-ChildItem -LiteralPath $full -Recurse -Force)
    if (@($items | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -gt 0) {
        throw 'Refusing to remove a reparse-backed hook snapshot.'
    }
    foreach ($item in $items | Where-Object { -not $_.PSIsContainer }) { $item.IsReadOnly = $false }
    Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
}

try {
    $root = (Resolve-Path -LiteralPath $RepositoryRoot -ErrorAction Stop).Path
    $common = ([string](& git -C $root rev-parse --path-format=absolute --git-common-dir 2>$null)).Trim()
    if ($LASTEXITCODE -ne 0 -or -not [IO.Path]::IsPathFullyQualified($common)) { throw 'Git metadata is unavailable.' }
    $common = [IO.Path]::GetFullPath($common).TrimEnd([char[]]@('\','/'))
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (((Get-Item -LiteralPath $common -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Git metadata must not be reparse-backed.'
    }
    if ($Mode -ceq 'Disable') {
        $hookPath = ([string](& git -C $root config --local --get core.hooksPath 2>$null)).Trim()
        if ($LASTEXITCODE -eq 1) { Write-Output 'No local pre-push snapshot is configured.'; exit 0 }
        if ($LASTEXITCODE -ne 0 -or -not [IO.Path]::IsPathFullyQualified($hookPath)) {
            throw 'The configured hooksPath is not an owned snapshot.'
        }
        $manifest = Get-Content -LiteralPath (Assert-PlainSnapshotFile -Root $hookPath -RelativePath 'manifest.json') -Raw | ConvertFrom-Json
        if ($manifest.schemaVersion -ne 1 -or $manifest.artifactType -cne 'atlassian-trusted-prepush-v1' -or
            -not ([string]$manifest.commonGitDirectory).Equals($common, $comparison)) { throw 'Hook snapshot ownership does not match this repository.' }
        $fullHookPath = [IO.Path]::GetFullPath($hookPath).TrimEnd([char[]]@('\','/'))
        if (-not [IO.Path]::GetDirectoryName($fullHookPath).Equals($common, $comparison) -or
            [IO.Path]::GetFileName($fullHookPath) -cnotmatch '^atlassian-prepush-[0-9a-f]{32}$') {
            throw 'The configured hooksPath is not an owned snapshot.'
        }
        & git -C $root config --local --unset core.hooksPath
        if ($LASTEXITCODE -ne 0) { throw 'Could not restore the absent local hooksPath setting.' }
        Remove-OwnedHookSnapshot -Path $hookPath -CommonGitDirectory $common
        Write-Output 'Trusted pre-push snapshot disabled; the previous absent local setting is restored.'
        exit 0
    }

    $existing = @(& git -C $root config --get-all core.hooksPath 2>$null)
    if ($LASTEXITCODE -notin @(0, 1)) { throw 'Could not inspect existing hook configuration.' }
    if ($existing.Count -gt 0) { throw 'Existing hooksPath is preserved; integrate with its owner before enabling this hook.' }
    foreach ($command in @('git','pwsh','go','python','node','npm')) {
        if (-not (Get-Command $command -CommandType Application -ErrorAction SilentlyContinue)) {
            throw "Required pre-push prerequisite is unavailable: $command."
        }
    }
    $dirty = @(& git -C $root status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0 -or $dirty.Count -ne 0) { throw 'Enable the trusted snapshot only from a reviewed clean revision.' }
    # Enable records the operator's trust in the complete executable commit; it does not review its code.
    $revision = ([string](& git -C $root rev-parse --verify HEAD)).Trim()
    if ($LASTEXITCODE -ne 0 -or $revision -cnotmatch '^[0-9a-f]{40}$') { throw 'Trusted source revision is unavailable.' }
    $paths = @('.githooks/pre-push', '.githooks/Invoke-PrePushValidation.ps1',
        'scripts/Validate.ps1', 'scripts/Invoke-SourceConformance.ps1', 'config/standard-v1.json')
    $files = @($paths | ForEach-Object {
        $file = Assert-PlainSnapshotFile -Root $root -RelativePath $_
        [pscustomobject]@{ path=$_; sha256=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() }
    })
    $createdSnapshot = Join-Path $common ('atlassian-prepush-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $createdSnapshot -ErrorAction Stop)
    foreach ($file in $files) {
        $destination = Join-Path $createdSnapshot $file.path
        [void](New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($destination)) -Force)
        [IO.File]::Copy((Join-Path $root $file.path), $destination, $false)
        if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -cne $file.sha256) {
            throw 'Hook entry changed while creating the trusted snapshot.'
        }
    }
    $manifest = [ordered]@{ schemaVersion=1; artifactType='atlassian-trusted-prepush-v1';
        commonGitDirectory=$common; sourceRevision=$revision; files=$files }
    [IO.File]::WriteAllText((Join-Path $createdSnapshot 'manifest.json'), ($manifest | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    $guard = @'
# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
param([string]$RemoteName, [string]$RemoteUrl)
$ErrorActionPreference = 'Stop'
try {
    $root = ([string](& git rev-parse --show-toplevel 2>$null)).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Repository unavailable.' }
    $common = ([string](& git -C $root rev-parse --path-format=absolute --git-common-dir 2>$null)).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Git metadata unavailable.' }
    $common = [IO.Path]::GetFullPath($common).TrimEnd([char[]]@('\','/'))
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $m = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'manifest.json') -Raw | ConvertFrom-Json
    if ($m.schemaVersion -ne 1 -or $m.artifactType -cne 'atlassian-trusted-prepush-v1' -or
        -not ([string]$m.commonGitDirectory).Equals($common, $comparison) -or $m.sourceRevision -cnotmatch '^[0-9a-f]{40}$') { throw 'Snapshot binding invalid.' }
    $paths = @('.githooks/pre-push', '.githooks/Invoke-PrePushValidation.ps1',
        'scripts/Validate.ps1', 'scripts/Invoke-SourceConformance.ps1', 'config/standard-v1.json')
    if (@($m.files).Count -ne $paths.Count) { throw 'Snapshot inventory invalid.' }
    foreach ($relative in $paths) {
        $entry = @($m.files | Where-Object { $_.path -ceq $relative })
        if ($entry.Count -ne 1 -or $entry[0].sha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'Snapshot identity invalid.' }
        foreach ($base in @($root, $PSScriptRoot)) {
            $path = $base
            foreach ($part in @('') + $relative.Split('/')) {
                if ($part) { $path = Join-Path $path $part }
                $item = Get-Item -LiteralPath $path -Force
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Snapshot path invalid.' }
            }
            if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry[0].sha256) {
                throw 'Trusted hook entry changed.'
            }
        }
    }
    # Only the verified snapshot helper may perform ref-only early returns; it binds revision before candidate execution.
    & (Join-Path $PSScriptRoot '.githooks/Invoke-PrePushValidation.ps1') -RepositoryRoot $root -TrustedEntryRoot $PSScriptRoot -TrustedSourceRevision $m.sourceRevision -RemoteName $RemoteName -RemoteUrl $RemoteUrl
    exit $LASTEXITCODE
}
catch {
    Write-Error 'Trusted pre-push entry is changed or unavailable. Enable only from a reviewed complete clean commit; no candidate code was executed.'
    exit 1
}
'@
    [IO.File]::WriteAllText((Join-Path $createdSnapshot 'Invoke-TrustedPrePush.ps1'), $guard, [Text.UTF8Encoding]::new($false))
    $shell = @'
#!/bin/sh
# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
set -eu
hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec pwsh -NoProfile -NonInteractive -File "$hook_dir/Invoke-TrustedPrePush.ps1" -RemoteName "$1" -RemoteUrl "$2"
'@
    [IO.File]::WriteAllText((Join-Path $createdSnapshot 'pre-push'), $shell.Replace("`r`n","`n") + "`n", [Text.UTF8Encoding]::new($false))
    if (-not $IsWindows) {
        & chmod +x (Join-Path $createdSnapshot 'pre-push')
        if ($LASTEXITCODE -ne 0) { throw 'Could not make the trusted shell hook executable.' }
    }
    foreach ($file in Get-ChildItem -LiteralPath $createdSnapshot -File -Recurse -Force) { $file.IsReadOnly = $true }
    & git -C $root config --local core.hooksPath $createdSnapshot
    if ($LASTEXITCODE -ne 0) { throw 'Could not enable the trusted snapshot.' }
    $configuredSnapshot = $true
    Write-Output "Trusted pre-push snapshot enabled for complete reviewed repository revision $revision. Source validation at any different HEAD requires review of the complete commit and deliberate Disable/Enable; ref-only early returns execute no candidate code and trust is never refreshed automatically."
}
catch { Write-Error "Pre-push setup blocked: $($_.Exception.Message)"; exit 1 }
finally {
    if ($createdSnapshot -and -not $configuredSnapshot -and (Test-Path -LiteralPath $createdSnapshot)) {
        Remove-OwnedHookSnapshot -Path $createdSnapshot -CommonGitDirectory $common
    }
}
