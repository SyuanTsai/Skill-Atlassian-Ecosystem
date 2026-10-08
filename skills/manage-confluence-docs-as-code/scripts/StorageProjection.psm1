# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
Import-Module -Name (Join-Path $PSScriptRoot 'ConfluenceAssets.psm1') -Force -Scope Local

$script:acNamespace = 'http://atlassian.com/content'
$script:riNamespace = 'http://atlassian.com/resource/identifier'
$script:allowedNodes = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($name in @('p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'ul', 'ol', 'li', 'pre', 'code', 'table', 'thead', 'tbody', 'tr', 'th', 'td', 'strong', 'em', 'a', 'br', 'ac:image', 'ri:attachment')) {
    $null = $script:allowedNodes.Add($name)
}

function Get-ProjectionHash {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
}

function Get-NodeAttribute {
    param([Xml.XmlNode] $Node, [string] $Name)
    if ($null -eq $Node.Attributes) { return $null }
    foreach ($attribute in $Node.Attributes) { if ($attribute.get_Name() -ceq $Name) { return [string] $attribute.Value } }
    return $null
}

function Get-NodeLocation {
    param([Xml.XmlNode] $Node)
    $parts = [System.Collections.Generic.List[string]]::new()
    $current = $Node
    while ($null -ne $current -and $current.NodeType -eq [Xml.XmlNodeType]::Element) {
        $index = 1
        $previous = $current.PreviousSibling
        while ($null -ne $previous) {
            if ($previous.NodeType -eq [Xml.XmlNodeType]::Element -and $previous.get_Name() -ceq $current.get_Name()) { $index++ }
            $previous = $previous.PreviousSibling
        }
        $parts.Insert(0, "$($current.get_Name())[$index]")
        $current = $current.ParentNode
    }
    return '/' + ($parts -join '/')
}

function Add-UnsupportedNode {
    param([Xml.XmlNode] $Node, [string] $Code, [System.Collections.Generic.List[object]] $Records)
    $Records.Add([pscustomobject]@{
        code = $Code
        location = Get-NodeLocation -Node $Node
        sourceXml = $Node.OuterXml
        sourceSha256 = Get-ProjectionHash -Text $Node.OuterXml
    })
}

function Test-SafeLink {
    param([string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    if ($Value.StartsWith('#', [StringComparison]::Ordinal) -or $Value.StartsWith('/wiki/', [StringComparison]::Ordinal)) { return $true }
    $uri = $null
    return [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref] $uri) -and $uri.Scheme -ceq 'https' -and -not $uri.UserInfo
}

function Inspect-StorageNode {
    param([Xml.XmlNode] $Node, [System.Collections.Generic.List[object]] $Unsupported)
    if ($Node.NodeType -in @([Xml.XmlNodeType]::Whitespace, [Xml.XmlNodeType]::SignificantWhitespace)) { return }
    if ($Node.NodeType -eq [Xml.XmlNodeType]::Text) {
        if (-not [string]::IsNullOrWhiteSpace($Node.Value) -and $Node.ParentNode.get_Name() -ceq 'root') { Add-UnsupportedNode -Node $Node.ParentNode -Code 'UnsupportedNode' -Records $Unsupported }
        return
    }
    if ($Node.NodeType -ne [Xml.XmlNodeType]::Element) { Add-UnsupportedNode -Node $Node -Code 'UnsupportedNode' -Records $Unsupported; return }
    if ($Node.get_Name() -ceq 'ac:structured-macro') { Add-UnsupportedNode -Node $Node -Code 'UnsupportedMacro' -Records $Unsupported; return }
    if (-not $script:allowedNodes.Contains($Node.get_Name())) { Add-UnsupportedNode -Node $Node -Code 'UnsupportedNode' -Records $Unsupported; return }

    if ($Node.get_Name() -ceq 'a') {
        if (-not (Test-SafeLink -Value (Get-NodeAttribute -Node $Node -Name 'href'))) {
            Add-UnsupportedNode -Node $Node -Code 'UnsafeUrl' -Records $Unsupported
            return
        }
    }
    if ($Node.get_Name() -in @('td', 'th')) {
        foreach ($attributeName in @('rowspan', 'colspan')) {
            $value = Get-NodeAttribute -Node $Node -Name $attributeName
            if ($null -ne $value -and $value -cne '1') {
                Add-UnsupportedNode -Node $Node -Code 'MergedTableCell' -Records $Unsupported
                return
            }
        }
    }
    if ($Node.get_Name() -ceq 'ri:attachment') {
        if ($Node.ParentNode.get_Name() -cne 'ac:image') { Add-UnsupportedNode -Node $Node -Code 'UnsupportedAssetReference' -Records $Unsupported; return }
        $filename = Get-NodeAttribute -Node $Node -Name 'ri:filename'
        if ([string]::IsNullOrWhiteSpace($filename) -or $filename -match '[\\/]' -or $filename -in @('.', '..')) {
            Add-UnsupportedNode -Node $Node -Code 'UnsafeAssetName' -Records $Unsupported
            return
        }
    }
    if ($Node.get_Name() -ceq 'ac:image') {
        $children = @($Node.ChildNodes | Where-Object { $_.NodeType -eq [Xml.XmlNodeType]::Element })
        if ($children.Count -ne 1 -or $children[0].get_Name() -cne 'ri:attachment') {
            Add-UnsupportedNode -Node $Node -Code 'UnsupportedAssetReference' -Records $Unsupported
            return
        }
    }
    foreach ($child in $Node.ChildNodes) { Inspect-StorageNode -Node $child -Unsupported $Unsupported }
}

function Escape-MarkdownText {
    param([string] $Text, [switch] $TableCell)
    $slash = [string] [char] 92
    $value = $Text.Replace($slash, $slash + $slash)
    foreach ($symbol in @('*', '[', ']', '<', '>')) { $value = $value.Replace($symbol, $slash + $symbol) }
    if ($TableCell) { $value = $value.Replace('|', $slash + '|') }
    return $value
}

function Convert-ImageMarkdown {
    param([Xml.XmlNode] $Node, [System.Collections.Generic.List[object]] $Assets)
    $attachment = @($Node.ChildNodes | Where-Object { $_.get_Name() -ceq 'ri:attachment' })[0]
    $filename = Get-NodeAttribute -Node $attachment -Name 'ri:filename'
    $Assets.Add([pscustomobject]@{ filename = $filename; sourceLocation = Get-NodeLocation -Node $Node })
    $alt = Get-NodeAttribute -Node $Node -Name 'ac:alt'
    if ([string]::IsNullOrWhiteSpace($alt)) { $alt = $filename }
    $escapedName = [Uri]::EscapeDataString($filename)
    return "![$(Escape-MarkdownText -Text $alt)](assets/$escapedName)"
}

function Convert-InlineChildren {
    param([Xml.XmlNode] $Node, [System.Collections.Generic.List[object]] $Assets, [switch] $TableCell)
    $builder = [Text.StringBuilder]::new()
    foreach ($child in $Node.ChildNodes) {
        if ($child.NodeType -eq [Xml.XmlNodeType]::Text) {
            $null = $builder.Append((Escape-MarkdownText -Text $child.Value -TableCell:$TableCell))
            continue
        }
        if ($child.NodeType -ne [Xml.XmlNodeType]::Element) { continue }
        $value = if ($child.get_Name() -ceq 'code') { $child.InnerText } elseif ($child.get_Name() -ceq 'ac:image') { '' } else { Convert-InlineChildren -Node $child -Assets $Assets -TableCell:$TableCell }
        switch ($child.get_Name()) {
            'strong' { $null = $builder.Append("**$value**"); break }
            'em' { $null = $builder.Append("*$value*"); break }
            'code' {
                $ticks = '`'
                while ($value.Contains($ticks)) { $ticks += '`' }
                $null = $builder.Append("$ticks$value$ticks")
                break
            }
            'a' {
                $href = (Get-NodeAttribute -Node $child -Name 'href').Replace(')', '%29')
                $null = $builder.Append("[$value]($href)")
                break
            }
            'br' { $null = $builder.Append("`n"); break }
            'ac:image' { $null = $builder.Append((Convert-ImageMarkdown -Node $child -Assets $Assets)); break }
            default { $null = $builder.Append($value); break }
        }
    }
    return $builder.ToString()
}

function Convert-StorageBlock {
    param([Xml.XmlNode] $Node, [System.Collections.Generic.List[object]] $Assets)
    switch -Regex ($Node.get_Name()) {
        '^h[1-6]$' {
            $level = [int] ([string] $Node.get_Name()).Substring(1)
            return ('#' * $level) + ' ' + (Convert-InlineChildren -Node $Node -Assets $Assets).Trim() + "`n`n"
        }
        '^p$' { return (Convert-InlineChildren -Node $Node -Assets $Assets).Trim() + "`n`n" }
        '^(ul|ol)$' {
            $lines = [System.Collections.Generic.List[string]]::new()
            $number = 1
            foreach ($item in $Node.ChildNodes | Where-Object { $_.get_Name() -ceq 'li' }) {
                $marker = if ($Node.get_Name() -ceq 'ul') { '- ' } else { "$number. " }
                $lines.Add($marker + (Convert-InlineChildren -Node $item -Assets $Assets).Trim())
                $number++
            }
            return ($lines -join "`n") + "`n`n"
        }
        '^pre$' {
            $code = $Node.InnerText
            $fence = '```'
            while ($code.Contains($fence)) { $fence += '`' }
            return "$fence`n$code`n$fence`n`n"
        }
        '^table$' {
            $rows = @($Node.SelectNodes('.//tr'))
            if ($rows.Count -eq 0) { return "`n" }
            $rendered = [System.Collections.Generic.List[string]]::new()
            $firstCells = @($rows[0].ChildNodes | Where-Object { $_.get_Name() -in @('th', 'td') })
            $header = @($firstCells | ForEach-Object { (Convert-InlineChildren -Node $_ -Assets $Assets -TableCell).Trim() })
            $rendered.Add('| ' + ($header -join ' | ') + ' |')
            $rendered.Add('| ' + (@($header | ForEach-Object { '---' }) -join ' | ') + ' |')
            foreach ($row in $rows | Select-Object -Skip 1) {
                $cells = @($row.ChildNodes | Where-Object { $_.get_Name() -in @('th', 'td') })
                $rendered.Add('| ' + (@($cells | ForEach-Object { (Convert-InlineChildren -Node $_ -Assets $Assets -TableCell).Trim() }) -join ' | ') + ' |')
            }
            return ($rendered -join "`n") + "`n`n"
        }
        '^ac:image$' {
            return (Convert-ImageMarkdown -Node $Node -Assets $Assets) + "`n`n"
        }
        default { return '' }
    }
}

function New-StorageResult {
    param([string] $Status, [string[]] $ReasonCodes, [string] $Markdown, [object[]] $SourceBlocks, [object[]] $Assets, [object[]] $Unsupported, [string] $BodySha256)
    return [pscustomobject]@{
        status = $Status
        reasonCodes = @($ReasonCodes)
        markdown = $Markdown
        sourceBlocks = @($SourceBlocks)
        assets = @($Assets)
        unsupported = @($Unsupported)
        bodySha256 = $BodySha256
        projectionSha256 = Get-ProjectionHash -Text $Markdown
    }
}

function ConvertFrom-ConfluenceStorage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Storage,
        [Parameter(Mandatory)][ValidatePattern('^[0-9]+$')][string] $PageId,
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int] $PageVersion
    )
    $bodyHash = Get-ProjectionHash -Text $Storage
    if ([Text.Encoding]::UTF8.GetByteCount($Storage) -gt 4MB) {
        return New-StorageResult -Status 'invalid' -ReasonCodes @('StorageTooLarge') -Markdown '' -SourceBlocks @() -Assets @() -Unsupported @() -BodySha256 $bodyHash
    }
    if ($Storage.Contains('<!DOCTYPE', [StringComparison]::OrdinalIgnoreCase) -or $Storage.Contains('<!ENTITY', [StringComparison]::OrdinalIgnoreCase)) {
        return New-StorageResult -Status 'invalid' -ReasonCodes @('DtdForbidden') -Markdown '' -SourceBlocks @() -Assets @() -Unsupported @() -BodySha256 $bodyHash
    }
    $wrapped = "<root xmlns:ac=`"$script:acNamespace`" xmlns:ri=`"$script:riNamespace`">$Storage</root>"
    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $settings.MaxCharactersInDocument = 4MB
    $settings.MaxCharactersFromEntities = 0
    $document = [Xml.XmlDocument]::new()
    $document.XmlResolver = $null
    $document.PreserveWhitespace = $true
    try {
        $stringReader = [IO.StringReader]::new($wrapped)
        $reader = [Xml.XmlReader]::Create($stringReader, $settings)
        try { $document.Load($reader) }
        finally { $reader.Dispose(); $stringReader.Dispose() }
    } catch {
        return New-StorageResult -Status 'invalid' -ReasonCodes @('StorageXmlInvalid') -Markdown '' -SourceBlocks @() -Assets @() -Unsupported @() -BodySha256 $bodyHash
    }

    $unsupported = [System.Collections.Generic.List[object]]::new()
    $blocks = [System.Collections.Generic.List[object]]::new()
    $assets = [System.Collections.Generic.List[object]]::new()
    $markdown = [Text.StringBuilder]::new()
    $ordinal = 0
    foreach ($node in $document.DocumentElement.ChildNodes) {
        if ($node.NodeType -in @([Xml.XmlNodeType]::Whitespace, [Xml.XmlNodeType]::SignificantWhitespace)) { continue }
        $ordinal++
        $beforeUnsupported = $unsupported.Count
        Inspect-StorageNode -Node $node -Unsupported $unsupported
        $location = Get-NodeLocation -Node $node
        $nodeHash = Get-ProjectionHash -Text $node.OuterXml
        $blockId = Get-ProjectionHash -Text "$PageId`:$PageVersion`:$ordinal`:$nodeHash"
        $blocks.Add([pscustomobject]@{ id = "BLOCK-$($blockId.Substring(0, 20))"; location = $location; sourceSha256 = $nodeHash; sourceType = $node.get_Name(); supported = ($unsupported.Count -eq $beforeUnsupported) })
        if ($unsupported.Count -eq $beforeUnsupported -and $node.NodeType -eq [Xml.XmlNodeType]::Element) {
            $null = $markdown.Append((Convert-StorageBlock -Node $node -Assets $assets))
        }
    }
    $output = $markdown.ToString().TrimEnd() + "`n"
    $reasonCodes = @($unsupported | ForEach-Object code | Select-Object -Unique)
    $status = if ($unsupported.Count -eq 0) { 'supported' } else { 'unsupported' }
    return New-StorageResult -Status $status -ReasonCodes $reasonCodes -Markdown $output -SourceBlocks $blocks.ToArray() -Assets $assets.ToArray() -Unsupported $unsupported.ToArray() -BodySha256 $bodyHash
}

function Write-SpecInlineParts {
    param([Xml.XmlWriter]$Writer,[object[]]$Parts)
    foreach($part in @($Parts)){
        switch([string]$part.type){
            'text' {$Writer.WriteString([string]$part.text);break}
            'code' {$Writer.WriteStartElement('code');$Writer.WriteString([string]$part.text);$Writer.WriteEndElement();break}
            'link' {
                $Writer.WriteStartElement('a');$Writer.WriteAttributeString('href',[string]$part.href)
                if($null -ne $part.PSObject.Properties['children']){Write-SpecInlineParts -Writer $Writer -Parts @($part.children)}
                else{$Writer.WriteString([string]$part.text)}
                $Writer.WriteEndElement();break
            }
            'image' {
                $Writer.WriteStartElement('ac','image',$script:acNamespace)
                $Writer.WriteAttributeString('ac','alt',$script:acNamespace,[string]$part.alt)
                $Writer.WriteStartElement('ri','attachment',$script:riNamespace)
                $Writer.WriteAttributeString('ri','filename',$script:riNamespace,[string]$part.remoteFilename)
                $Writer.WriteEndElement();$Writer.WriteEndElement();break
            }
            'strong_open' {$Writer.WriteStartElement('strong');break}
            'strong_close' {$Writer.WriteEndElement();break}
            'em_open' {$Writer.WriteStartElement('em');break}
            'em_close' {$Writer.WriteEndElement();break}
        }
    }
}

function Test-SpecInlineParts {
    param([object[]]$Parts)
    foreach($part in @($Parts)){
        if([string]$part.type -notin @('text','code','link','image','strong_open','strong_close','em_open','em_close')){return $false}
        if([string]$part.type -ceq 'link' -and $null -ne $part.PSObject.Properties['children'] -and
            -not(Test-SpecInlineParts -Parts @($part.children))){return $false}
    }
    return $true
}

function ConvertTo-ConfluenceSpecStorage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$SourceInventory,
        [Parameter(Mandatory)][object]$Validation,
        [Parameter(Mandatory)][string]$RequirementId,
        [string]$Root='',
        [string]$ProjectionId='',
        [object[]]$ManagedAssets=@(),
        [object[]]$LinkBindings=@(),
        [object[]]$PageMappings=@()
    )
    $requirement=@($SourceInventory.requirements|Where-Object id -eq $RequirementId)
    $scenarios=@($SourceInventory.scenarios|Where-Object requirementId -eq $RequirementId)
    if($SourceInventory.status -cne 'valid' -or $Validation.status -cne 'valid' -or
        $requirement.Count -ne 1 -or $scenarios.Count -eq 0){
        return [pscustomobject]@{status='invalid';reasonCodes=@('ProjectionSourceInvalid');storage='';bodySha256='';scenarioIds=@()}
    }
    $scenarioLinkCount=0
    $scenarioImageCount=0
    foreach($item in $scenarios){
        if($null -ne $item.PSObject.Properties['links']){$scenarioLinkCount+=@($item.links).Count}
        if($null -ne $item.PSObject.Properties['images']){$scenarioImageCount+=@($item.images).Count}
    }
    if($scenarioLinkCount -gt 0){
        return [pscustomobject]@{status='unsupported';reasonCodes=@('LinkProjectionUnsupported');storage='';bodySha256='';scenarioIds=@($scenarios|ForEach-Object id)}
    }
    if($scenarioImageCount -gt 0){
        return [pscustomobject]@{status='unsupported';reasonCodes=@('AssetProjectionUnsupported');storage='';bodySha256='';scenarioIds=@($scenarios|ForEach-Object id)}
    }
    $blocks=@()
    if($null -ne $requirement[0].PSObject.Properties['bodyBlocks']){$blocks=@($requirement[0].bodyBlocks)}
    if($blocks.Count -eq 0 -and (@($requirement[0].links).Count -gt 0 -or @($requirement[0].images).Count -gt 0)){
        return [pscustomobject]@{status='unsupported';reasonCodes=@('LinkProjectionUnsupported','AssetProjectionUnsupported');storage='';bodySha256='';scenarioIds=@($scenarios|ForEach-Object id)}
    }
    $renderBlocks=[System.Collections.Generic.List[object]]::new()
    $imageRefs=[System.Collections.Generic.List[string]]::new()
    $deferredTargets=[System.Collections.Generic.List[string]]::new()
    $seenBindings=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($block in $blocks){
        if(-not(Test-SpecInlineParts -Parts @($block.parts))){
            return [pscustomobject]@{status='unsupported';reasonCodes=@('InlineProjectionUnsupported');storage='';bodySha256='';scenarioIds=@($scenarios|ForEach-Object id)}
        }
        $parts=[System.Collections.Generic.List[object]]::new()
        foreach($part in @($block.parts)){
            if($part.type -ceq 'link'){
                $url=$null
                $href=[string]$part.href
                if([string]::IsNullOrWhiteSpace([string]$part.text)){
                    return [pscustomobject]@{status='unsupported';reasonCodes=@('LinkProjectionUnsupported');storage='';bodySha256='';scenarioIds=@($scenarios|ForEach-Object id)}
                }
                if([Uri]::TryCreate($href,[UriKind]::Absolute,[ref]$url) -and $url.Scheme -ceq 'https' -and $url.UserInfo -eq ''){
                    $parts.Add([pscustomobject]@{type='link';href=$href;text=[string]$part.text;children=@($part.children)})
                }else{
                    if($Root -eq '' -or $ProjectionId -eq '' -or $href -match '^[a-z][a-z0-9+.-]*:' -or
                        $href.StartsWith('/',[StringComparison]::Ordinal) -or $href.StartsWith('#',[StringComparison]::Ordinal) -or
                        $href.Contains('?') -or [string]$Validation.siteOrigin -cnotmatch '^https://[^/]+$'){
                        return [pscustomobject]@{status='unsupported';reasonCodes=@('LinkProjectionUnsupported');storage='';bodySha256='';scenarioIds=@($scenarios|ForEach-Object id)}
                    }
                    $bindings=@($LinkBindings|Where-Object {[string]$_.href -ceq $href})
                    if($bindings.Count -ne 1){
                        return [pscustomobject]@{status='unsupported';reasonCodes=@('LinkProjectionUnsupported');storage='';bodySha256='';scenarioIds=@($scenarios|ForEach-Object id)}
                    }
                    $targetProjection=[string]$bindings[0].targetProjectionId
                    $targets=@($PageMappings|Where-Object {[string]$_.projectionId -ceq $targetProjection})
                    if($targets.Count -ne 1 -or $targetProjection -cnotmatch '^[a-z][a-z0-9-]{0,49}$'){
                        return [pscustomobject]@{status='unsupported';reasonCodes=@('LinkProjectionUnsupported');storage='';bodySha256='';scenarioIds=@($scenarios|ForEach-Object id)}
                    }
                    try{
                        $decoded=[Uri]::UnescapeDataString($href.Split('#',2)[0])
                        $hrefParts=$href.Split('#',2)
                        $anchor=if($hrefParts.Count -eq 2){[Uri]::UnescapeDataString($hrefParts[1])}else{''}
                        $sourceFile=[IO.Path]::GetFullPath((Join-Path $Root ([string]$part.path)))
                        $targetFile=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($sourceFile)) $decoded))
                        $targetArtifact=[IO.Path]::GetRelativePath([IO.Path]::GetFullPath($Root),$targetFile).Replace([string][IO.Path]::DirectorySeparatorChar,'/')
                    }catch{
                        return [pscustomobject]@{status='unsupported';reasonCodes=@('LinkProjectionUnsupported');storage='';bodySha256='';scenarioIds=@($scenarios|ForEach-Object id)}
                    }
                    if($targetArtifact -cne [string]$targets[0].sourceArtifact -or
                        ($hrefParts.Count -eq 2 -and ($anchor -eq '' -or $anchor -cne [string]$targets[0].sourceSectionId)) -or
                        ($hrefParts.Count -eq 1 -and @($PageMappings|Where-Object {[string]$_.sourceArtifact -ceq [string]$targetArtifact}).Count -ne 1) -or
                        ([string]$targets[0].pageId -ne '' -and [string]$targets[0].pageId -cnotmatch '^[0-9]+$')){
                        return [pscustomobject]@{status='unsupported';reasonCodes=@('LinkProjectionUnsupported');storage='';bodySha256='';scenarioIds=@($scenarios|ForEach-Object id)}
                    }
                    $null=$seenBindings.Add($href)
                    $pageId=[string]$targets[0].pageId
                    if($pageId -eq ''){
                        if($targetProjection -cnotin $deferredTargets){$deferredTargets.Add($targetProjection)}
                        $pageId="__SYP171_LINK_${targetProjection}__"
                    }
                    $mappedHref="$($Validation.siteOrigin.TrimEnd('/'))/wiki/pages/viewpage.action?pageId=$pageId"
                    $parts.Add([pscustomobject]@{type='link';href=$mappedHref;text=[string]$part.text;children=@($part.children)})
                }
            }elseif($part.type -ceq 'image'){
                $src=[string]$part.src
                if($Root -eq '' -or $ProjectionId -eq '' -or $src -match '^[a-z][a-z0-9+.-]*:' -or
                    $src.StartsWith('/',[StringComparison]::Ordinal) -or $src.Contains('?') -or $src.Contains('#')){
                    return [pscustomobject]@{status='unsupported';reasonCodes=@('AssetProjectionUnsupported');storage='';bodySha256='';scenarioIds=@($scenarios|ForEach-Object id)}
                }
                try{
                    $decoded=[Uri]::UnescapeDataString($src)
                    $sourceFile=[IO.Path]::GetFullPath((Join-Path $Root ([string]$part.path)))
                    $assetFile=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($sourceFile)) $decoded))
                    $localPath=[IO.Path]::GetRelativePath([IO.Path]::GetFullPath($Root),$assetFile).Replace([string][IO.Path]::DirectorySeparatorChar,'/')
                }catch{
                    return [pscustomobject]@{status='unsupported';reasonCodes=@('AssetProjectionUnsupported');storage='';bodySha256='';scenarioIds=@($scenarios|ForEach-Object id)}
                }
                $matches=@($ManagedAssets|Where-Object { [string]$_.localPath -ceq $localPath })
                if($matches.Count -ne 1){
                    return [pscustomobject]@{status='unsupported';reasonCodes=@('AssetProjectionUnsupported');storage='';bodySha256='';scenarioIds=@($scenarios|ForEach-Object id)}
                }
                $asset=Resolve-LocalManagedAsset -Root $Root -ProjectionId $ProjectionId -Asset $matches[0]
                if($asset.status -cne 'valid' -or $asset.mediaType -notin @('image/png','image/jpeg','image/gif')){
                    return [pscustomobject]@{status='unsupported';reasonCodes=@('AssetProjectionUnsupported');storage='';bodySha256='';scenarioIds=@($scenarios|ForEach-Object id)}
                }
                $imageRefs.Add([string]$asset.remoteFilename)
                $parts.Add([pscustomobject]@{type='image';alt=[string]$part.alt;remoteFilename=[string]$asset.remoteFilename})
            }else{$parts.Add($part)}
        }
        $renderBlocks.Add([pscustomobject]@{parts=$parts.ToArray()})
    }
    if(@($requirement[0].images).Count -ne $imageRefs.Count){
        return [pscustomobject]@{status='unsupported';reasonCodes=@('AssetProjectionUnsupported');storage='';bodySha256='';scenarioIds=@($scenarios|ForEach-Object id)}
    }
    if($seenBindings.Count -ne @($LinkBindings).Count){
        return [pscustomobject]@{status='unsupported';reasonCodes=@('LinkBindingUnused');storage='';bodySha256='';scenarioIds=@($scenarios|ForEach-Object id)}
    }
    $settings=[Xml.XmlWriterSettings]::new()
    $settings.OmitXmlDeclaration=$true
    $settings.ConformanceLevel=[Xml.ConformanceLevel]::Fragment
    $settings.Indent=$false
    $settings.NewLineHandling=[Xml.NewLineHandling]::None
    $sink=[IO.StringWriter]::new([Globalization.CultureInfo]::InvariantCulture)
    $writer=[Xml.XmlWriter]::Create($sink,$settings)
    try{
        $writer.WriteStartElement('h1');$writer.WriteString("Native OpenSpec SDD: $RequirementId");$writer.WriteEndElement()
        foreach($line in @(
            "docsCommit: $($Validation.docsCommit)","specCommit: $($Validation.specCommit)",
            "codeCommit: $($Validation.codeCommit)","sourceDigest: $($SourceInventory.sourceDigest)",
            "approvalStatus: $($Validation.approvalStatus)","implementationStatus: $($Validation.implementationStatus)",
            "scenarioAcceptance: $($Validation.scenarioAcceptance)","publishEligibility: $($Validation.publishEligibility)"
        )){$writer.WriteStartElement('p');$writer.WriteString($line);$writer.WriteEndElement()}
        $writer.WriteStartElement('h2');$writer.WriteString([string]$requirement[0].title);$writer.WriteEndElement()
        if($renderBlocks.Count -eq 0){
            foreach($paragraph in @($requirement[0].body)){
                $writer.WriteStartElement('p');$writer.WriteString([string]$paragraph);$writer.WriteEndElement()
            }
        }else{
            foreach($block in $renderBlocks){
                $writer.WriteStartElement('p')
                Write-SpecInlineParts -Writer $writer -Parts @($block.parts)
                $writer.WriteEndElement()
            }
        }
        foreach($scenario in $scenarios){
            $writer.WriteStartElement('h3');$writer.WriteString([string]$scenario.title);$writer.WriteEndElement()
            $writer.WriteStartElement('ul')
            foreach($keyword in @('GIVEN','WHEN','THEN')){
                $property=$keyword.ToLowerInvariant()
                foreach($value in @($scenario.$property)){
                    $writer.WriteStartElement('li');$writer.WriteString("${keyword}: $value");$writer.WriteEndElement()
                }
            }
            $writer.WriteEndElement()
        }
        $writer.Flush()
        $storage=$sink.ToString()
        $bytes=[Text.Encoding]::UTF8.GetBytes($storage)
        $sha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        if($deferredTargets.Count -gt 0){
            return [pscustomobject]@{status='deferred';reasonCodes=@('LinkTargetPending');storage='';storageTemplate=$storage;bodySha256='';templateSha256=$sha
                deferredTargets=$deferredTargets.ToArray();scenarioIds=@($scenarios|ForEach-Object id)}
        }
        return [pscustomobject]@{status='supported';reasonCodes=@();storage=$storage;bodySha256=$sha;scenarioIds=@($scenarios|ForEach-Object id)}
    }finally{$writer.Dispose();$sink.Dispose()}
}

Export-ModuleMember -Function ConvertFrom-ConfluenceStorage,ConvertTo-ConfluenceSpecStorage
