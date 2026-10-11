# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
Import-Module -Name (Join-Path $PSScriptRoot 'StrictJson.psm1') -Force -Scope Local

function New-MappingResult {
    param([string] $Status, [string[]] $ReasonCodes, [object[]] $Entries, [string] $Digest)
    return [pscustomobject]@{ status = $Status; reasonCodes = @($ReasonCodes); entries = @($Entries); mappingSha256 = $Digest }
}

function Test-RelativeSourcePath {
    param([string] $Root, [string] $RelativePath)
    $segments = @($RelativePath -split '/')
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or $RelativePath -match '[\\\r\n]' -or
        $RelativePath.StartsWith('/', [StringComparison]::Ordinal) -or $RelativePath -match '^[a-zA-Z]:' -or
        @($segments | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0) { return $false }
    $full = [IO.Path]::GetFullPath((Join-Path $Root $RelativePath))
    $relative = [IO.Path]::GetRelativePath([IO.Path]::GetFullPath($Root), $full)
    if ($relative -eq '..' -or $relative.StartsWith(('..' + [IO.Path]::DirectorySeparatorChar), [StringComparison]::Ordinal) -or [IO.Path]::IsPathRooted($relative)) { return $false }
    $current = $full
    while ($current -ne [IO.Path]::GetFullPath($Root)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        }
        $current = [IO.Path]::GetDirectoryName($current)
        if ([string]::IsNullOrWhiteSpace($current)) { return $false }
    }
    return $true
}

function Test-ConfluenceMapping {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $MappingPath,
        [Parameter(Mandatory)][string] $ExpectedSiteOrigin
    )
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return New-MappingResult -Status 'invalid' -ReasonCodes @('RootUnavailable') -Entries @() -Digest '' }
    $rootFull = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path)
    $mappingFull = [IO.Path]::GetFullPath($MappingPath)
    if (-not (Test-RelativeSourcePath -Root $rootFull -RelativePath ([IO.Path]::GetRelativePath($rootFull, $mappingFull))) -or
        -not (Test-Path -LiteralPath $mappingFull -PathType Leaf)) {
        return New-MappingResult -Status 'invalid' -ReasonCodes @('MappingPathInvalid') -Entries @() -Digest ''
    }
    $bytes = [IO.File]::ReadAllBytes($mappingFull)
    if ($bytes.Length -gt 4MB -or $bytes.Length -eq 0) { return New-MappingResult -Status 'invalid' -ReasonCodes @('MappingSchemaInvalid') -Entries @() -Digest '' }
    try {
        $jsonText = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        $mapping = ConvertFrom-Syp171StrictJson -Json $jsonText -Depth 30
    } catch { return New-MappingResult -Status 'invalid' -ReasonCodes @('MappingSchemaInvalid') -Entries @() -Digest '' }
    $reasons = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Syp171JsonKeys -Value $mapping -Expected @('schemaVersion','adapter','siteOrigin','cloudId','entries')) -or
        $mapping.schemaVersion -notin @(1,2,3) -or -not (Test-Syp171JsonKeys -Value $mapping.adapter -Expected @('id','version')) -or
        $mapping.adapter.id -cne 'openspec-native' -or $mapping.adapter.version -cne '1.13.0' -or
        $mapping.entries -isnot [array] -or @($mapping.entries).Count -eq 0) { $reasons.Add('MappingSchemaInvalid') }
    if ($mapping.siteOrigin -cne $ExpectedSiteOrigin -or [string] $mapping.cloudId -cnotmatch '^[a-fA-F0-9-]{36}$') { $reasons.Add('TenantMismatch') }
    $seenProjection = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $seenPage = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $seenSpelling = @{}
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @($mapping.entries)) {
        $baseKeys=@('projectionId','sourceArtifact','sourceSectionId','pageId','spaceId','parentId','title','assets')
        $hasParentProjection=$entry -is [System.Collections.IDictionary] -and $entry.Contains('parentProjectionId')
        $parentProjection=if($hasParentProjection){
            [string]$entry['parentProjectionId']
        }else{
            ''
        }
        $hasLinkBindings=$entry -is [System.Collections.IDictionary] -and $entry.Contains('linkBindings')
        $linkBindings=@()
        if($hasLinkBindings){$linkBindings=$entry['linkBindings']}
        if (-not (Test-Syp171JsonKeys -Value $entry -Expected $(if($mapping.schemaVersion -eq 3){@($baseKeys)+@('parentProjectionId','linkBindings')}elseif($mapping.schemaVersion -eq 2){@($baseKeys)+@('parentProjectionId')}else{$baseKeys})) -or
            $entry.projectionId -isnot [string] -or $entry.sourceSectionId -isnot [string] -or $entry.assets -isnot [array] -or
            [string]$entry.projectionId -cnotmatch '^[a-z][a-z0-9-]{0,49}$' -or
            ($null -ne $entry.pageId -and [string] $entry.pageId -cnotmatch '^[0-9]+$') -or
            [string] $entry.spaceId -cnotmatch '^[0-9]+$' -or
            ($mapping.schemaVersion -in @(2,3) -and (-not $hasParentProjection -or $entry['parentProjectionId'] -isnot [string])) -or
            ($mapping.schemaVersion -eq 3 -and (-not $hasLinkBindings -or $linkBindings -isnot [array] -or @($linkBindings).Count -gt 100)) -or
            ($parentProjection -ne '' -and ($parentProjection -cnotmatch '^[a-z][a-z0-9-]{0,49}$' -or
                $null -ne $entry.pageId -or [string]$entry.parentId -ne '')) -or
            ($parentProjection -eq '' -and [string] $entry.parentId -cnotmatch '^[0-9]+$') -or
            [string]::IsNullOrWhiteSpace([string] $entry.title)) { $reasons.Add('MappingSchemaInvalid'); continue }
        if (-not $seenProjection.Add([string] $entry.projectionId)) { $reasons.Add('DuplicateProjectionId') }
        if ($null -ne $entry.pageId -and -not $seenPage.Add(([string]($($mapping.cloudId)) + ':' + [string]($($entry.pageId))))) { $reasons.Add('DuplicatePageIdentity') }
        $path = [string] $entry.sourceArtifact
        $folded = $path.ToLowerInvariant()
        if ($seenSpelling.ContainsKey($folded) -and $seenSpelling[$folded] -cne $path) { $reasons.Add('CaseCollision') }
        else { $seenSpelling[$folded] = $path }
        if (-not (Test-RelativeSourcePath -Root $rootFull -RelativePath $path)) { $reasons.Add('UnsafeSourcePath') }
        $entries.Add([pscustomobject]@{
            projectionId = $entry.projectionId; sourceArtifact = $path; sourceSectionId = $entry.sourceSectionId
            pageId = [string] $entry.pageId; spaceId = [string] $entry.spaceId; parentId = [string] $entry.parentId
            parentProjectionId = $parentProjection
            title = [string] $entry.title; assets = @($entry.assets)
            linkBindings = @($linkBindings)
        })
    }
    $byProjection=[System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach($entry in $entries){$byProjection[[string]$entry.projectionId]=$entry}
    foreach($entry in $entries){
        if($entry.parentProjectionId -eq ''){continue}
        $seenChain=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $current=$entry
        while($current.parentProjectionId -ne ''){
            if(-not $seenChain.Add([string]$current.projectionId)){$reasons.Add('ParentDependencyInvalid');break}
            $parent=$null
            if(-not $byProjection.TryGetValue([string]$current.parentProjectionId,[ref]$parent) -or
                $parent.pageId -ne '' -or $parent.spaceId -cne $current.spaceId){
                $reasons.Add('ParentDependencyInvalid');break
            }
            $current=$parent
        }
    }
    if($mapping.schemaVersion -eq 3){
        foreach($entry in $entries){
            $seenHref=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach($binding in @($entry.linkBindings)){
                if(-not(Test-Syp171JsonKeys -Value $binding -Expected @('href','targetProjectionId')) -or
                    $binding['href'] -isnot [string] -or $binding['targetProjectionId'] -isnot [string]){
                    $reasons.Add('LinkBindingInvalid');continue
                }
                $href=[string]$binding.href
                $targetProjection=[string]$binding.targetProjectionId
                $target=$null
                if($href.Length -eq 0 -or $href.Length -gt 1024 -or $href -match '[\\\r\n\?]' -or
                    $href.StartsWith('/',[StringComparison]::Ordinal) -or $href.StartsWith('#',[StringComparison]::Ordinal) -or
                    $href -match '^[A-Za-z][A-Za-z0-9+.-]*:' -or -not $seenHref.Add($href) -or
                    $targetProjection -cnotmatch '^[a-z][a-z0-9-]{0,49}$' -or
                    -not $byProjection.TryGetValue($targetProjection,[ref]$target)){
                    $reasons.Add('LinkBindingInvalid');continue
                }
                $relative=$href.Split('#',2)[0]
                if([string]::IsNullOrWhiteSpace($relative)){$reasons.Add('LinkBindingInvalid');continue}
                try{
                    $decoded=[Uri]::UnescapeDataString($relative)
                    $parts=$href.Split('#',2)
                    $anchor=if($parts.Count -eq 2){[Uri]::UnescapeDataString($parts[1])}else{''}
                    $sourceFile=[IO.Path]::GetFullPath((Join-Path $rootFull ([string]$entry.sourceArtifact)))
                    $targetFile=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($sourceFile)) $decoded))
                    $targetRelative=[IO.Path]::GetRelativePath($rootFull,$targetFile).Replace([string][IO.Path]::DirectorySeparatorChar,'/')
                }catch{$reasons.Add('LinkBindingInvalid');continue}
                if(-not(Test-RelativeSourcePath -Root $rootFull -RelativePath $targetRelative) -or
                    $targetRelative -cne [string]$target.sourceArtifact){$reasons.Add('LinkBindingInvalid')}
                if(($parts.Count -eq 2 -and ($anchor -eq '' -or $anchor -cne [string]$target.sourceSectionId)) -or
                    ($parts.Count -eq 1 -and @($entries|Where-Object {[string]$_.sourceArtifact -ceq [string]$target.sourceArtifact}).Count -ne 1)){
                    $reasons.Add('LinkBindingInvalid')
                }
            }
        }
    }
    $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    $unique = @($reasons | Select-Object -Unique)
    return New-MappingResult -Status $(if($unique.Count -eq 0){'valid'}else{'invalid'}) -ReasonCodes $unique -Entries $entries.ToArray() -Digest $digest
}

Export-ModuleMember -Function Test-ConfluenceMapping
