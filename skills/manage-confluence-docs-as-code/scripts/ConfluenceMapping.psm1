# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
Import-Module -Name (Join-Path $PSScriptRoot 'StrictJson.psm1') -Scope Local

function New-MappingResult {
    param([string] $Status, [string[]] $ReasonCodes, [object[]] $Entries, [string] $Digest)
    return [pscustomobject]@{ status = $Status; reasonCodes = @($ReasonCodes); entries = @($Entries); mappingSha256 = $Digest }
}

function Get-ConfluenceCommittedBlob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Commit,
        [Parameter(Mandatory)][string]$Path,
        [ValidateRange(1,20971520)][long]$MaxBytes=4MB
    )
    if([string]::IsNullOrWhiteSpace($Path) -or $Path -match '[\\\r\n]' -or $Path -match '^[A-Za-z]:' -or
        $Path.StartsWith('/',[StringComparison]::Ordinal) -or @($Path -split '/'|Where-Object {$_ -in @('', '.', '..')}).Count -gt 0){
        throw 'Committed source path is invalid.'
    }
    $oid=& git -C $Root rev-parse --verify ("${Commit}:$Path") 2>$null
    if($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$oid)){throw 'Committed source blob is unavailable.'}
    $oid=[string]$oid
    $kind=& git -C $Root cat-file -t $oid 2>$null
    if($LASTEXITCODE -ne 0 -or [string]$kind -cne 'blob'){throw 'Committed source is not a file blob.'}
    $sizeText=& git -C $Root cat-file -s $oid 2>$null
    [long]$size=0
    if($LASTEXITCODE -ne 0 -or -not [long]::TryParse([string]$sizeText,[ref]$size) -or $size -gt $MaxBytes){
        throw 'Committed source exceeds the size limit.'
    }
    $gitCommand=Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $start=[System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$gitCommand.Source
    $start.UseShellExecute=$false
    $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true
    $start.RedirectStandardError=$true
    foreach($argument in @('-C',$Root,'cat-file','blob',$oid)){$start.ArgumentList.Add($argument)}
    $process=[System.Diagnostics.Process]::new()
    $process.StartInfo=$start
    $memory=[IO.MemoryStream]::new()
    try{
        if(-not $process.Start()){throw 'Could not start Git blob reader.'}
        $stderrTask=$process.StandardError.ReadToEndAsync()
        $process.StandardOutput.BaseStream.CopyTo($memory)
        $process.WaitForExit()
        $null=$stderrTask.GetAwaiter().GetResult()
        if($process.ExitCode -ne 0 -or $memory.Length -ne $size){throw 'Git blob read failed.'}
        return [pscustomobject]@{objectId=$oid;bytes=$memory.ToArray()}
    }finally{
        $memory.Dispose()
        $process.Dispose()
    }
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
    $mappingRelative=[IO.Path]::GetRelativePath($rootFull,$mappingFull).Replace([IO.Path]::DirectorySeparatorChar,'/').Replace([IO.Path]::AltDirectorySeparatorChar,'/')
    if (-not (Test-RelativeSourcePath -Root $rootFull -RelativePath $mappingRelative) -or
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
    if ($mapping -is [System.Collections.IDictionary] -and $mapping.Contains('schemaVersion') -and $mapping.schemaVersion -in @(1,2,3)) {
        return New-MappingResult -Status 'invalid' -ReasonCodes @('MappingContractUnsupported') -Entries @() -Digest ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant())
    }
    if (-not (Test-Syp171JsonKeys -Value $mapping -Expected @('schemaVersion','adapter','siteOrigin','cloudId','sourceMode','entries')) -or
        $mapping.schemaVersion -ne 4 -or -not (Test-Syp171JsonKeys -Value $mapping.adapter -Expected @('id','version')) -or
        $mapping.adapter.id -cne 'powershell-markdown' -or $mapping.adapter.version -cne '1' -or
        $mapping.sourceMode -cnotin @('git-markdown','capture-markdown') -or
        $mapping.entries -isnot [array] -or @($mapping.entries).Count -eq 0) { $reasons.Add('MappingSchemaInvalid') }
    if ($mapping.siteOrigin -cne $ExpectedSiteOrigin -or [string] $mapping.cloudId -cnotmatch '^[a-fA-F0-9-]{36}$') { $reasons.Add('TenantMismatch') }
    $seenProjection = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $seenPage = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $seenArtifact = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $seenSpelling = @{}
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @($mapping.entries)) {
        $baseKeys=@('projectionId','sourceArtifact','sourceSectionId','pageId','spaceId','parentId','title','assets','parentProjectionId','linkBindings','contentKind')
        $hasParentProjection=$entry -is [System.Collections.IDictionary] -and $entry.Contains('parentProjectionId')
        $parentProjection=if($hasParentProjection){
            [string]$entry['parentProjectionId']
        }else{
            ''
        }
        $hasLinkBindings=$entry -is [System.Collections.IDictionary] -and $entry.Contains('linkBindings')
        $linkBindings=@()
        if($hasLinkBindings){$linkBindings=$entry['linkBindings']}
        if (-not (Test-Syp171JsonKeys -Value $entry -Expected $baseKeys) -or
            $entry.projectionId -isnot [string] -or $entry.sourceSectionId -isnot [string] -or $entry.assets -isnot [array] -or @($entry.assets).Count -gt 25 -or
            [string]$entry.projectionId -cnotmatch '^[a-z][a-z0-9-]{0,49}$' -or
            [string]$entry.sourceArtifact -cnotmatch '(?i)\.md$' -or [string]$entry.sourceSectionId -cne 'document' -or
                $entry.contentKind -cnotin @('general','code-current') -or
            ($null -ne $entry.pageId -and [string] $entry.pageId -cnotmatch '^[0-9]+$') -or
            [string] $entry.spaceId -cnotmatch '^[0-9]+$' -or
            (-not $hasParentProjection -or $entry['parentProjectionId'] -isnot [string]) -or
            (-not $hasLinkBindings -or $linkBindings -isnot [array] -or @($linkBindings).Count -gt 100) -or
            ($parentProjection -ne '' -and ($parentProjection -cnotmatch '^[a-z][a-z0-9-]{0,49}$' -or
                $null -ne $entry.pageId -or [string]$entry.parentId -ne '')) -or
            ($parentProjection -eq '' -and [string] $entry.parentId -cnotmatch '^[0-9]+$') -or
            [string]::IsNullOrWhiteSpace([string] $entry.title)) { $reasons.Add('MappingSchemaInvalid'); continue }
        if (-not $seenProjection.Add([string] $entry.projectionId)) { $reasons.Add('DuplicateProjectionId') }
        if (-not $seenArtifact.Add([string]$entry.sourceArtifact)) { $reasons.Add('DuplicateSourceArtifact') }
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
            title = [string] $entry.title; assets = @($entry.assets); contentKind=[string]$entry.contentKind
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
    if($mapping.schemaVersion -eq 4){
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
                $anchorValid=if($parts.Count -eq 2){
                    $anchor -match '^[\p{L}\p{Nd}_-]{1,256}$'
                }else{$true}
                if(($parts.Count -eq 2 -and -not $anchorValid) -or
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

Export-ModuleMember -Function Test-ConfluenceMapping,Get-ConfluenceCommittedBlob
