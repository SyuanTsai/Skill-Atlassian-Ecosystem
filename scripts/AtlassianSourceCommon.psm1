# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:SourceRepository = 'https://github.com/SyuanTsai/Skill-Atlassian-Ecosystem.git'

function Assert-ExactPropertySet {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string[]] $Expected,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($null -eq $Value -or $Value -is [array] -or $Value -is [string] -or $null -eq $Value.PSObject) {
        throw "$Context must be a JSON object."
    }
    $actual = @($Value.PSObject.Properties | ForEach-Object { [string]$_.Name })
    $missing = @($Expected | Where-Object { $actual -cnotcontains $_ })
    $unexpected = @($actual | Where-Object { $Expected -cnotcontains $_ })
    if ($missing.Count -gt 0 -or $unexpected.Count -gt 0 -or $actual.Count -ne $Expected.Count) {
        throw "$Context has an invalid property set. Missing='$($missing -join ',')' Unexpected='$($unexpected -join ',')'."
    }
}

function Assert-NoDuplicateJsonProperties {
    param(
        [Parameter(Mandatory = $true)][System.Text.Json.JsonElement] $Element,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $names.Add($property.Name)) { throw "$Context contains duplicate JSON property '$($property.Name)'." }
            Assert-NoDuplicateJsonProperties -Element $property.Value -Context "$Context.$($property.Name)"
        }
    }
    elseif ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
        $index = 0
        foreach ($item in $Element.EnumerateArray()) {
            Assert-NoDuplicateJsonProperties -Element $item -Context "$Context[$index]"
            $index++
        }
    }
}

function Read-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Context is missing: $Path" }
    try {
        $text = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false, $true))
        $document = [System.Text.Json.JsonDocument]::Parse($text)
        try { Assert-NoDuplicateJsonProperties -Element $document.RootElement -Context $Context }
        finally { $document.Dispose() }
        return $text | ConvertFrom-Json -Depth 100
    }
    catch { throw "$Context is not valid unambiguous UTF-8 JSON: $($_.Exception.Message)" }
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string] $Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Test-PathWithinOrEqual {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Root)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    return $fullPath.Equals($fullRoot, $comparison) -or
        $fullPath.StartsWith($fullRoot + [IO.Path]::DirectorySeparatorChar, $comparison)
}

function Test-PathEqual {
    param([Parameter(Mandatory = $true)][string] $Left, [Parameter(Mandatory = $true)][string] $Right)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    return [IO.Path]::GetFullPath($Left).Equals([IO.Path]::GetFullPath($Right), $comparison)
}

function Assert-PathWithinRoot {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Context
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-PathWithinOrEqual -Path $fullPath -Root $Root)) { throw "$Context must stay within '$Root': $Path" }
    return $fullPath
}

function Assert-OutsideRoot {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Context
    )
    if (Test-PathWithinOrEqual -Path $Path -Root $Root) { throw "$Context must be outside '$Root': $Path" }
}

function Assert-NoReparseAncestors {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Context)
    $current = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Context is backed by a reparse point: $current" }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $current) { break }
        $current = $parent
    }
}

function Write-Utf8NoBomCreateNew {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Text)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
    $stream = $null
    try {
        $stream = [IO.File]::Open($fullPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally { if ($null -ne $stream) { $stream.Dispose() } }
}

function Get-ResolvedGitPath {
    $command = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
    return [IO.Path]::GetFullPath([string]$command.Path)
}

function Get-ResolvedPowerShellPath {
    $command = Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1
    return [IO.Path]::GetFullPath([string]$command.Path)
}

function Resolve-GitRevision {
    param(
        [Parameter(Mandatory = $true)][string] $GitPath,
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Revision,
        [Parameter(Mandatory = $true)][string] $Context
    )
    $output = @(& $GitPath -C $Root rev-parse --verify --end-of-options "$Revision^{commit}" 2>$null)
    if ($LASTEXITCODE -ne 0 -or $output.Count -ne 1 -or ([string]$output[0]).Trim() -cnotmatch '^[0-9a-f]{40}$') {
        throw "$Context '$Revision' does not resolve to one immutable commit."
    }
    return ([string]$output[0]).Trim()
}

function Resolve-GoRuntimeVersion {
    param([string] $Expected)
    if (-not [string]::IsNullOrWhiteSpace($Expected)) {
        if ($Expected -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { throw 'ExpectedGoRuntimeVersion must be a stable semantic Go version.' }
        return $Expected
    }
    $go = Get-Command go -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $output = @(& $go.Path version)
    if ($LASTEXITCODE -ne 0 -or $output.Count -ne 1 -or [string]$output[0] -notmatch '^go version go(?<version>[0-9]+\.[0-9]+\.[0-9]+)\s') {
        throw 'Could not resolve the current stable Go runtime version.'
    }
    return [string]$Matches.version
}

function Get-EventName {
    $event = [string]$env:GITHUB_EVENT_NAME
    switch ($event) {
        'pull_request' { return 'pull_request' }
        'push' { return 'push' }
        'workflow_dispatch' { return 'workflow_dispatch' }
        'pre-push' { return 'pre-push' }
        default { return 'local' }
    }
}

function Resolve-SourceComparisonBaseInput {
    param([string] $BaseCommit, [Parameter(Mandatory = $true)][string] $EventName)
    if ([string]::IsNullOrWhiteSpace($BaseCommit)) {
        if ($EventName -ceq 'pre-push') {
            throw 'Pre-push validation requires an explicit base revision for the complete pending range.'
        }
        return 'HEAD^'
    }
    return $BaseCommit
}

function Get-ActiveSkillIds {
    param([Parameter(Mandatory = $true)][string] $Root)
    $inventory = Read-JsonFile -Path (Join-Path $Root 'catalog/source.json') -Context 'catalog/source.json'
    Assert-ExactPropertySet -Value $inventory -Expected @('schemaVersion', 'sourceId', 'repository', 'skillsRoot', 'skills') -Context 'catalog/source.json'
    if ($inventory.schemaVersion -ne 2 -or $inventory.sourceId -cne 'atlassian-ecosystem' -or
        $inventory.repository -cne $script:SourceRepository -or $inventory.skillsRoot -cne 'skills' -or
        $inventory.skills -isnot [array] -or @($inventory.skills).Count -eq 0) {
        throw 'catalog/source.json is not the strict Atlassian source inventory.'
    }
    if (Test-Path -LiteralPath (Join-Path $Root 'catalog/skills-catalog.json') -PathType Leaf) {
        throw 'Legacy source-owned cross-source catalog must not coexist with catalog/source.json.'
    }
    if (Test-Path -LiteralPath (Join-Path $Root '.agents/skills')) {
        throw 'Legacy .agents/skills source root must not coexist with canonical skills/.'
    }
    [string[]]$declared = @($inventory.skills | ForEach-Object {
        if ($_ -isnot [string] -or [string]$_ -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "Invalid Skill ID in catalog/source.json: '$_'." }
        [string]$_
    })
    [string[]]$sorted = @($declared)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($skillId in $declared) { if (-not $seen.Add($skillId)) { throw "Duplicate Skill ID '$skillId'." } }
    if (($declared -join "`n") -cne ($sorted -join "`n")) { throw 'catalog/source.json skills must use ordinal ascending order.' }
    $skillsRoot = Join-Path $Root 'skills'
    if (-not (Test-Path -LiteralPath $skillsRoot -PathType Container)) { throw 'Canonical skills/ source root is missing.' }
    $actual = @(Get-ChildItem -LiteralPath $skillsRoot -Directory -Force | ForEach-Object { [string]$_.Name })
    [Array]::Sort($actual, [StringComparer]::Ordinal)
    if (($actual -join "`n") -cne ($sorted -join "`n")) { throw 'catalog/source.json inventory does not exactly match skills/ directories.' }
    return $sorted
}

Export-ModuleMember -Function @(
    'Assert-ExactPropertySet',
    'Assert-NoDuplicateJsonProperties',
    'Read-JsonFile',
    'Get-FileSha256',
    'Test-PathWithinOrEqual',
    'Test-PathEqual',
    'Assert-PathWithinRoot',
    'Assert-OutsideRoot',
    'Assert-NoReparseAncestors',
    'Write-Utf8NoBomCreateNew',
    'Get-ResolvedGitPath',
    'Get-ResolvedPowerShellPath',
    'Resolve-GitRevision',
    'Resolve-GoRuntimeVersion',
    'Get-EventName',
    'Resolve-SourceComparisonBaseInput',
    'Get-ActiveSkillIds'
)
