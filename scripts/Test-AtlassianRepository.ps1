# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0

[CmdletBinding()]
param(
    [string] $RepositoryRoot,
    [switch] $ReadOnlySnapshot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-ExactPropertySet {
    param(
        [Parameter(Mandatory)] $Value,
        [Parameter(Mandatory)][string[]] $Expected,
        [Parameter(Mandatory)][string] $Context
    )

    $actual = @($Value.PSObject.Properties | ForEach-Object { [string]$_.Name })
    $missing = @($Expected | Where-Object { $actual -cnotcontains $_ })
    $unexpected = @($actual | Where-Object { $Expected -cnotcontains $_ })
    if ($missing.Count -gt 0 -or $unexpected.Count -gt 0 -or $actual.Count -ne $Expected.Count) {
        throw "$Context has an invalid property set. Missing='$($missing -join ',')' Unexpected='$($unexpected -join ',')'."
    }
}

function Assert-NoDuplicateJsonProperties {
    param(
        [Parameter(Mandatory)][Text.Json.JsonElement] $Element,
        [Parameter(Mandatory)][string] $Context
    )

    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $names.Add($property.Name)) {
                throw "$Context contains duplicate JSON property '$($property.Name)'."
            }
            Assert-NoDuplicateJsonProperties -Element $property.Value -Context ($Context + '.' + $property.Name)
        }
    }
    elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
        $index = 0
        foreach ($item in $Element.EnumerateArray()) {
            Assert-NoDuplicateJsonProperties -Element $item -Context ($Context + '[' + $index + ']')
            $index++
        }
    }
}

function Read-StrictJson {
    param([Parameter(Mandatory)][string] $Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) {
        throw "JSON must not contain a UTF-8 BOM: $Path"
    }
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    $document = [Text.Json.JsonDocument]::Parse($text)
    try {
        Assert-NoDuplicateJsonProperties -Element $document.RootElement -Context '$'
    }
    finally {
        $document.Dispose()
    }
    $text | ConvertFrom-Json -Depth 50
}

function Get-UnicodeScalarCount {
    param([Parameter(Mandatory)][string] $Value, [Parameter(Mandatory)][string] $Context)

    $count = 0
    for ($index = 0; $index -lt $Value.Length; $index++) {
        if ([char]::IsHighSurrogate($Value[$index])) {
            if ($index + 1 -ge $Value.Length -or -not [char]::IsLowSurrogate($Value[$index + 1])) {
                throw "$Context contains an invalid UTF-16 surrogate sequence."
            }
            $index++
        }
        elseif ([char]::IsLowSurrogate($Value[$index])) {
            throw "$Context contains an invalid UTF-16 surrogate sequence."
        }
        $count++
    }
    $count
}

function ConvertFrom-RestrictedYamlString {
    param([Parameter(Mandatory)][string] $Value, [Parameter(Mandatory)][string] $Context)

    if ($Value -cmatch '^"(?:[^"\\]|\\.)*"$') {
        $decoded = $Value | ConvertFrom-Json
        if ($decoded -isnot [string]) { throw "$Context must be a string." }
        return [string]$decoded
    }
    if ($Value.StartsWith("'", [StringComparison]::Ordinal)) {
        if ($Value -cnotmatch "^'(?:[^']|'')*'$" ) { throw "$Context contains an invalid single-quoted string." }
        return $Value.Substring(1, $Value.Length - 2).Replace("''", "'")
    }
    if ($Value -cmatch '^[\[\]{},&*!|>"%@`]' -or $Value -cmatch '^[?:-](?:\s|$)' -or $Value -cmatch ':\s' -or $Value -cmatch '(?:^|\s)#') {
        throw "$Context must be an unambiguous YAML string scalar."
    }
    $Value
}

function Read-SkillFrontmatter {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $ExpectedSkillId)

    $text = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false, $true)).Replace("`r`n", "`n").Replace("`r", "`n")
    if ($text -cnotmatch '(?s)\A---\n(?<frontmatter>.*?)\n---\n(?<body>.*)\z' -or [string]::IsNullOrWhiteSpace([string]$Matches.body)) {
        throw "SKILL.md for '$ExpectedSkillId' must contain closed frontmatter and a non-empty body."
    }
    $values = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    foreach ($line in ([string]$Matches.frontmatter).Split("`n")) {
        if ($line -cnotmatch '^(?<key>[a-z][a-z-]*):\s+(?<value>\S.*)$') {
            throw "SKILL.md for '$ExpectedSkillId' has malformed frontmatter syntax."
        }
        $key = [string]$Matches.key
        $value = ConvertFrom-RestrictedYamlString -Value ([string]$Matches.value).Trim() -Context "SKILL.md $key for '$ExpectedSkillId'"
        if ($key -cnotin @('name', 'description', 'license') -or -not $values.TryAdd($key, $value)) {
            throw "SKILL.md for '$ExpectedSkillId' has an unsupported or duplicate frontmatter key '$key'."
        }
    }
    if (-not $values.ContainsKey('name') -or -not $values.ContainsKey('description') -or $values['name'] -cne $ExpectedSkillId) {
        throw "SKILL.md name or description contract failed for '$ExpectedSkillId'."
    }
    $description = $values['description']
    if ([string]::IsNullOrWhiteSpace($description) -or (Get-UnicodeScalarCount -Value $description -Context "$ExpectedSkillId description") -gt 1024 -or $description.Contains('<') -or $description.Contains('>')) {
        throw "SKILL.md description for '$ExpectedSkillId' violates the text contract."
    }
}

function Read-OpenAiMetadata {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $ExpectedSkillId
    )

    $text = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false, $true)).Replace("`r`n", "`n").Replace("`r", "`n")
    if ($text.Contains("`t")) { throw "agents/openai.yaml for '$ExpectedSkillId' must not contain tabs." }

    $topSections = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $interface = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $tools = [Collections.Generic.List[object]]::new()
    $policy = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $section = ''
    $inTools = $false
    $sawTools = $false
    $currentTool = $null

    foreach ($line in $text.Split("`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -cmatch '^# SPDX-FileCopyrightText: 2026 SyuanTsai$' -or
            $line -cmatch ('^# SPDX-License' + '-Identifier: Apache-2\.0$')) { continue }
        if ($line -cmatch '^\s*["'']') {
            throw "agents/openai.yaml for '$ExpectedSkillId' contains a quoted mapping key."
        }
        if ($line -cmatch '^(?<section>[a-z_]+):$') {
            if ($null -ne $currentTool) {
                $tools.Add([pscustomobject]$currentTool)
                $currentTool = $null
            }
            $section = [string]$Matches.section
            if ($section -cnotin @('interface', 'dependencies', 'policy') -or -not $topSections.Add($section)) {
                throw "agents/openai.yaml for '$ExpectedSkillId' has unsupported or duplicate section '$section'."
            }
            $inTools = $false
            continue
        }

        if ($section -ceq 'interface' -and $line -cmatch '^  (?<key>[a-z_]+): (?<json>"(?:[^"\\]|\\.)*")$') {
            $key = [string]$Matches.key
            if ($key -cnotin @('display_name', 'short_description', 'default_prompt', 'icon_small', 'icon_large', 'brand_color') -or $interface.ContainsKey($key)) {
                throw "agents/openai.yaml for '$ExpectedSkillId' has unsupported or duplicate interface key '$key'."
            }
            try { $interface.Add($key, [string](([string]$Matches.json) | ConvertFrom-Json)) }
            catch { throw "agents/openai.yaml for '$ExpectedSkillId' has invalid quoted string '$key'." }
            continue
        }

        if ($section -ceq 'dependencies' -and $line -ceq '  tools:') {
            if ($inTools) { throw "agents/openai.yaml for '$ExpectedSkillId' has duplicate dependencies.tools." }
            $inTools = $true
            $sawTools = $true
            continue
        }
        if ($section -ceq 'dependencies' -and $inTools -and $line -cmatch '^    - type: (?<json>"(?:[^"\\]|\\.)*")$') {
            if ($null -ne $currentTool) { $tools.Add([pscustomobject]$currentTool) }
            $currentTool = [ordered]@{}
            try { $currentTool.type = [string](([string]$Matches.json) | ConvertFrom-Json) }
            catch { throw "agents/openai.yaml for '$ExpectedSkillId' has invalid dependency type." }
            continue
        }
        if ($section -ceq 'dependencies' -and $inTools -and $null -ne $currentTool -and $line -cmatch '^      (?<key>[a-z_]+): (?<json>"(?:[^"\\]|\\.)*")$') {
            $key = [string]$Matches.key
            if ($key -cnotin @('value', 'description', 'transport', 'url') -or $currentTool.Contains($key)) {
                throw "agents/openai.yaml for '$ExpectedSkillId' has unsupported or duplicate dependency key '$key'."
            }
            try { $currentTool[$key] = [string](([string]$Matches.json) | ConvertFrom-Json) }
            catch { throw "agents/openai.yaml for '$ExpectedSkillId' has invalid dependency string '$key'." }
            continue
        }

        if ($section -ceq 'policy' -and $line -cmatch '^  (?<key>[a-z_]+): (?<value>true|false)$') {
            $key = [string]$Matches.key
            if (-not $policy.TryAdd($key, ([string]$Matches.value -ceq 'true'))) {
                throw "agents/openai.yaml for '$ExpectedSkillId' has duplicate policy key '$key'."
            }
            continue
        }

        throw "agents/openai.yaml for '$ExpectedSkillId' has unsupported or malformed syntax: '$line'."
    }
    if ($null -ne $currentTool) { $tools.Add([pscustomobject]$currentTool) }

    foreach ($required in @('display_name', 'short_description', 'default_prompt')) {
        if (-not $interface.ContainsKey($required) -or [string]::IsNullOrWhiteSpace($interface[$required])) {
            throw "agents/openai.yaml for '$ExpectedSkillId' is missing interface.$required."
        }
    }
    $shortLength = Get-UnicodeScalarCount -Value $interface['short_description'] -Context "$ExpectedSkillId short_description"
    if ($shortLength -lt 25 -or $shortLength -gt 64) {
        throw "agents/openai.yaml interface.short_description for '$ExpectedSkillId' must contain 25 to 64 Unicode scalar values."
    }
    $token = '$' + $ExpectedSkillId
    if ($interface['default_prompt'] -cnotmatch ("(?<![A-Za-z0-9-]){0}(?![A-Za-z0-9-])" -f [regex]::Escape($token))) {
        throw "agents/openai.yaml interface.default_prompt for '$ExpectedSkillId' must reference exact token '$token'."
    }
    if ($topSections.Contains('dependencies') -and (-not $sawTools -or $tools.Count -eq 0)) {
        throw "agents/openai.yaml dependencies for '$ExpectedSkillId' must contain a non-empty tools list."
    }
    if ($topSections.Contains('policy') -and
        ($policy.Count -ne 1 -or -not $policy.ContainsKey('allow_implicit_invocation'))) {
        throw "agents/openai.yaml policy for '$ExpectedSkillId' must contain only allow_implicit_invocation."
    }
    $skillRoot = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent (Split-Path -Parent $Path)) '.'))
    foreach ($iconKey in @('icon_small', 'icon_large')) {
        if ($interface.ContainsKey($iconKey)) {
            $iconValue = [string]$interface[$iconKey]
            if ($iconValue -cnotmatch '^\./assets/[^\r\n]+$') {
                throw "agents/openai.yaml interface.$iconKey for '$ExpectedSkillId' must be a relative ./assets/ path."
            }
            $relativeIconPath = $iconValue.Substring(2).Replace('/', [IO.Path]::DirectorySeparatorChar)
            $iconSegments = $relativeIconPath.Split([IO.Path]::DirectorySeparatorChar)
            if ($iconValue.Contains('\') -or $relativeIconPath.Contains(':') -or
                $iconSegments -contains '' -or $iconSegments -contains '.' -or $iconSegments -contains '..') {
                throw "agents/openai.yaml interface.$iconKey for '$ExpectedSkillId' contains an unsafe asset path."
            }
            $iconPath = [IO.Path]::GetFullPath((Join-Path $skillRoot $relativeIconPath))
            $rootPrefix = $skillRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
            if (-not $iconPath.StartsWith($rootPrefix, [StringComparison]::Ordinal) -or
                -not (Test-Path -LiteralPath $iconPath -PathType Leaf)) {
                throw "agents/openai.yaml interface.$iconKey for '$ExpectedSkillId' must identify an existing file inside ./assets/."
            }
            $iconItem = Get-Item -LiteralPath $iconPath -Force
            if (($iconItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "agents/openai.yaml interface.$iconKey for '$ExpectedSkillId' must not identify a reparse point."
            }
        }
    }
    if ($interface.ContainsKey('brand_color') -and [string]$interface['brand_color'] -cnotmatch '^#[0-9A-Fa-f]{6}$') {
        throw "agents/openai.yaml interface.brand_color for '$ExpectedSkillId' must be a six-digit hexadecimal color."
    }
    foreach ($tool in $tools) {
        if ($tool.type -cne 'mcp' -or $null -eq $tool.PSObject.Properties['value'] -or [string]::IsNullOrWhiteSpace([string]$tool.value)) {
            throw "agents/openai.yaml dependency for '$ExpectedSkillId' must declare quoted type 'mcp' and a non-empty value."
        }
        foreach ($name in @('description', 'transport')) {
            if ($null -ne $tool.PSObject.Properties[$name] -and [string]::IsNullOrWhiteSpace([string]$tool.$name)) {
                throw "agents/openai.yaml dependency.$name for '$ExpectedSkillId' cannot be empty."
            }
        }
        if ($null -ne $tool.PSObject.Properties['url']) {
            $uri = $null
            if ([string]::IsNullOrWhiteSpace([string]$tool.url) -or
                -not [Uri]::TryCreate([string]$tool.url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -cne 'https') {
                throw "agents/openai.yaml dependency.url for '$ExpectedSkillId' must be absolute HTTPS."
            }
        }
    }
}

function Assert-WindowsPortableRelativePath {
    param([Parameter(Mandatory)][string] $RelativePath, [Parameter(Mandatory)][string] $Context)

    foreach ($segment in $RelativePath.Split('/')) {
        if ([string]::IsNullOrEmpty($segment) -or $segment -cin @('.', '..') -or $segment -cmatch '[\x00-\x1f\x7f<>:"/\\|?*]' -or $segment.EndsWith('.') -or $segment.EndsWith(' ')) {
            throw "$Context contains a non-portable path '$RelativePath'."
        }
        $baseName = ($segment -split '\.', 2)[0]
        if ($baseName -cmatch '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
            throw "$Context contains a Windows-reserved path '$RelativePath'."
        }
    }
}

function Get-ContentInventory {
    param([Parameter(Mandatory)][string] $Root, [Parameter(Mandatory)][string] $SkillId)

    $skillRoot = [IO.Path]::GetFullPath((Join-Path $Root ('skills/' + $SkillId)))
    $skillRootItem = Get-Item -LiteralPath $skillRoot -Force
    if (-not $skillRootItem.PSIsContainer -or ($skillRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Skill '$SkillId' root must be a regular non-reparse directory."
    }
    $pathToFile = [Collections.Generic.Dictionary[string, IO.FileInfo]]::new([StringComparer]::Ordinal)
    $nfcPaths = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $foldedPaths = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in @(Get-ChildItem -LiteralPath $skillRoot -Recurse -Force)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Skill '$SkillId' contains a reparse point." }
        if ($item.PSIsContainer) { continue }
        if ($item -isnot [IO.FileInfo]) { throw "Skill '$SkillId' contains a non-regular entry." }
        $relative = [IO.Path]::GetRelativePath($skillRoot, $item.FullName).Replace('\', '/')
        Assert-WindowsPortableRelativePath -RelativePath $relative -Context "Skill '$SkillId'"
        if (-not $pathToFile.TryAdd($relative, $item)) { throw "Skill '$SkillId' contains duplicate path '$relative'." }
        $nfc = $relative.Normalize([Text.NormalizationForm]::FormC)
        if ($nfcPaths.ContainsKey($nfc) -or $foldedPaths.ContainsKey($nfc)) { throw "Skill '$SkillId' contains a path collision '$relative'." }
        $nfcPaths.Add($nfc, $relative)
        $foldedPaths.Add($nfc, $relative)
    }
    if ($pathToFile.Count -eq 0) { throw "Skill '$SkillId' has an empty package inventory." }
    [string[]]$paths = @($pathToFile.Keys)
    [Array]::Sort($paths, [StringComparer]::Ordinal)
    $canonical = [Text.StringBuilder]::new()
    $files = foreach ($path in $paths) {
        $sha256 = (Get-FileHash -LiteralPath $pathToFile[$path].FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        [void]$canonical.Append($path).Append("`t100644`t").Append($sha256).Append("`n")
        [pscustomobject][ordered]@{ path = $path; mode = '100644'; sha256 = $sha256; rawSha256 = $sha256 }
    }
    $hashBytes = [Text.UTF8Encoding]::new($false).GetBytes($canonical.ToString())
    $contentHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($hashBytes)).ToLowerInvariant()
    [pscustomobject][ordered]@{ skillId = $SkillId; contentSha256 = $contentHash; files = @($files) }
}

$repoRoot = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
}
else {
    [IO.Path]::GetFullPath($RepositoryRoot)
}
if (-not (Test-Path -LiteralPath $repoRoot -PathType Container)) { throw "Repository root does not exist: $repoRoot" }

$inventory = Read-StrictJson -Path (Join-Path $repoRoot 'catalog/source.json')
Assert-ExactPropertySet -Value $inventory -Expected @('schemaVersion', 'sourceId', 'repository', 'skillsRoot', 'skills') -Context 'catalog/source.json'
if (($inventory.schemaVersion -isnot [int] -and $inventory.schemaVersion -isnot [long]) -or [int64]$inventory.schemaVersion -ne 2) {
    throw 'catalog/source.json schemaVersion must be integer 2.'
}
if ([string]$inventory.sourceId -cne 'atlassian-ecosystem' -or [string]$inventory.repository -cne 'https://github.com/SyuanTsai/Skill-Atlassian-Ecosystem.git' -or [string]$inventory.skillsRoot -cne 'skills') {
    throw 'catalog/source.json identity is invalid.'
}
if ($inventory.skills -isnot [array] -or @($inventory.skills).Count -eq 0) { throw 'catalog/source.json skills must be a non-empty array.' }
if (Test-Path -LiteralPath (Join-Path $repoRoot 'catalog/skills-catalog.json')) { throw 'Legacy source-owned cross-source catalog must not coexist with catalog/source.json.' }
if (Test-Path -LiteralPath (Join-Path $repoRoot '.agents/skills')) { throw 'Legacy .agents/skills source root must not coexist with canonical skills/.' }

$skillIds = @($inventory.skills | ForEach-Object {
        if ($_ -isnot [string] -or [string]$_ -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') { throw "Invalid Skill ID: $_" }
        [string]$_
    })
$unique = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($skillId in $skillIds) { if (-not $unique.Add($skillId)) { throw "Duplicate Skill ID '$skillId'." } }
[string[]]$sorted = @($skillIds)
[Array]::Sort($sorted, [StringComparer]::Ordinal)
if (($sorted -join "`n") -cne ($skillIds -join "`n")) { throw 'catalog/source.json skills must use ordinal ascending order.' }

$skillsRoot = Join-Path $repoRoot 'skills'
$entries = @(Get-ChildItem -LiteralPath $skillsRoot -Force)
foreach ($entry in $entries) {
    if (-not $entry.PSIsContainer -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Canonical skills root contains a non-package entry '$($entry.Name)'." }
}
[string[]]$actualSkillIds = @($entries | ForEach-Object Name)
[Array]::Sort($actualSkillIds, [StringComparer]::Ordinal)
if (($actualSkillIds -join "`n") -cne ($skillIds -join "`n")) { throw 'catalog/source.json inventory does not exactly match skills directories.' }

function Get-PublisherSkillDiscoveryPaths {
    param(
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][string] $SkillsRoot
    )

    $discovered = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    function Add-PublisherSkillPath {
        param([Parameter(Mandatory)][string] $Path)

        $item = $null
        try {
            $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        }
        catch [Management.Automation.ItemNotFoundException] {
            return
        }
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Publisher-discoverable Skill path must be a regular non-reparse file: $Path"
        }
        $relativePath = [IO.Path]::GetRelativePath($RepositoryRoot, $item.FullName).Replace('\', '/')
        if (-not $discovered.Add($relativePath)) {
            throw "Publisher-discoverable Skill path was discovered more than once: $relativePath"
        }
    }

    foreach ($entry in @(Get-ChildItem -LiteralPath $RepositoryRoot -Directory -Force)) {
        if ([string]$entry.Name -ceq '.git' -or ([string]$entry.Name).StartsWith('.')) { continue }
        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Publisher discovery root contains a reparse directory: $($entry.FullName)"
        }
        Add-PublisherSkillPath -Path (Join-Path $entry.FullName 'SKILL.md')
    }

    foreach ($scopeEntry in @(Get-ChildItem -LiteralPath $SkillsRoot -Directory -Force)) {
        if (($scopeEntry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Publisher discovery canonical scope contains a reparse directory: $($scopeEntry.FullName)"
        }
        Add-PublisherSkillPath -Path (Join-Path $scopeEntry.FullName 'SKILL.md')
        foreach ($packageEntry in @(Get-ChildItem -LiteralPath $scopeEntry.FullName -Directory -Force)) {
            if (($packageEntry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Publisher discovery nested canonical package contains a reparse directory: $($packageEntry.FullName)"
            }
            Add-PublisherSkillPath -Path (Join-Path $packageEntry.FullName 'SKILL.md')
        }
    }

    $pluginsRoot = Join-Path $RepositoryRoot 'plugins'
    if (Test-Path -LiteralPath $pluginsRoot -PathType Container) {
        $pluginsRootItem = Get-Item -LiteralPath $pluginsRoot -Force -ErrorAction Stop
        if (($pluginsRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Publisher discovery plugins root is a reparse directory: $pluginsRoot"
        }
        foreach ($scopeEntry in @(Get-ChildItem -LiteralPath $pluginsRoot -Directory -Force)) {
            if (($scopeEntry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Publisher discovery plugin scope contains a reparse directory: $($scopeEntry.FullName)"
            }
            $pluginSkillsRoot = Join-Path $scopeEntry.FullName 'skills'
            if (-not (Test-Path -LiteralPath $pluginSkillsRoot -PathType Container)) { continue }
            $pluginSkillsRootItem = Get-Item -LiteralPath $pluginSkillsRoot -Force -ErrorAction Stop
            if (($pluginSkillsRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Publisher discovery plugin skills root is a reparse directory: $pluginSkillsRoot"
            }
            foreach ($packageEntry in @(Get-ChildItem -LiteralPath $pluginSkillsRoot -Directory -Force)) {
                if (($packageEntry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "Publisher discovery plugin package contains a reparse directory: $($packageEntry.FullName)"
                }
                Add-PublisherSkillPath -Path (Join-Path $packageEntry.FullName 'SKILL.md')
            }
        }
    }

    [string[]]$sortedPaths = @($discovered)
    [Array]::Sort($sortedPaths, [StringComparer]::Ordinal)
    @($sortedPaths)
}

$expectedSkillPaths = @($skillIds | ForEach-Object { 'skills/' + $_ + '/SKILL.md' })
$actualSkillPaths = @(Get-PublisherSkillDiscoveryPaths -RepositoryRoot $repoRoot -SkillsRoot $skillsRoot)
if (($actualSkillPaths -join "`n") -cne ($expectedSkillPaths -join "`n")) { throw 'Publisher-discoverable Skill inventory does not exactly match catalog/source.json.' }

$packages = foreach ($skillId in $skillIds) {
    $skillRoot = Join-Path $skillsRoot $skillId
    $skillPath = Join-Path $skillRoot 'SKILL.md'
    $metadataPath = Join-Path $skillRoot 'agents/openai.yaml'
    if (-not (Test-Path -LiteralPath $skillPath -PathType Leaf) -or -not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) { throw "Skill '$skillId' is missing required metadata." }
    Read-SkillFrontmatter -Path $skillPath -ExpectedSkillId $skillId
    Read-OpenAiMetadata -Path $metadataPath -ExpectedSkillId $skillId
    Get-ContentInventory -Root $repoRoot -SkillId $skillId
}

[pscustomobject][ordered]@{
    schemaVersion = 1
    sourceId = 'atlassian-ecosystem'
    skillsRoot = 'skills'
    activeSkillCount = $skillIds.Count
    skills = @($packages)
    result = 'passed'
} | ConvertTo-Json -Depth 20
