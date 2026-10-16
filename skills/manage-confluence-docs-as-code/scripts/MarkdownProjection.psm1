# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
Import-Module -Name (Join-Path $PSScriptRoot 'ConfluenceAssets.psm1') -Scope Local

$script:acNamespace = 'http://atlassian.com/content'
$script:riNamespace = 'http://atlassian.com/resource/identifier'
$script:allowedHtml = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($tag in @('p','h1','h2','h3','h4','h5','h6','ul','ol','li','table','thead','tbody','tr','th','td','pre','code','strong','em','a','img','br')) {
    $null = $script:allowedHtml.Add($tag)
}

function Get-MarkdownProjectionHash {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
}

function New-MarkdownProjectionResult {
    param(
        [string] $Status,
        [string[]] $ReasonCodes = @(),
        [string] $Storage = '',
        [object[]] $Assets = @(),
        [object[]] $Unsupported = @(),
        [string] $SourceSha256 = '',
        [string] $BodySha256 = '',
        [object[]] $DeferredTargets = @(),
        [string] $StorageTemplate = ''
    )
    return [pscustomobject]@{
        status = $Status
        reasonCodes = @($ReasonCodes)
        storage = $Storage
        storageTemplate = $StorageTemplate
        assets = @($Assets)
        unsupported = @($Unsupported)
        sourceSha256 = $SourceSha256
        bodySha256 = $BodySha256
        deferredTargets = @($DeferredTargets)
    }
}

function Add-MarkdownUnsupported {
    param([System.Collections.Generic.List[object]] $Records, [string] $Code, [string] $Location, [string] $Source)
    $value = [string]$Source
    $display = if ($value.Length -gt 512) { $value.Substring(0,512) } else { $value }
    $Records.Add([pscustomobject]@{
        code = $Code
        location = $Location
        source = $display
        sourceSha256 = Get-MarkdownProjectionHash -Text $value
    })
}

function Get-MarkdownLineNumber {
    param([string] $Markdown, [int] $Position)
    $bounded = [Math]::Max(0,[Math]::Min($Markdown.Length,$Position))
    $line = 1
    for ($index = 0; $index -lt $bounded; $index++) { if ($Markdown[$index] -eq [char]10) { $line++ } }
    return $line
}

function Test-MarkdownProjectRelativePath {
    param([string] $Root, [string] $RelativePath)
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or $RelativePath -match '[\\\r\n]' -or
        $RelativePath.StartsWith('/',[StringComparison]::Ordinal) -or $RelativePath -match '^[A-Za-z]:') { return $false }
    $segments = @($RelativePath -split '/')
    if (@($segments | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0) { return $false }
    try {
        $rootFull = [IO.Path]::GetFullPath($Root)
        $full = [IO.Path]::GetFullPath((Join-Path $rootFull $RelativePath))
        $relative = [IO.Path]::GetRelativePath($rootFull,$full)
        if ($relative -eq '..' -or $relative.StartsWith(('..' + [IO.Path]::DirectorySeparatorChar),[StringComparison]::Ordinal) -or [IO.Path]::IsPathRooted($relative)) { return $false }
        $current = $full
        while ($current -ne $rootFull) {
            if (Test-Path -LiteralPath $current) {
                $item = Get-Item -LiteralPath $current -Force
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
            }
            $current = [IO.Path]::GetDirectoryName($current)
            if ([string]::IsNullOrWhiteSpace($current)) { return $false }
        }
        return $true
    } catch { return $false }
}

function Get-MarkdownTargetRelativePath {
    param([string] $Root, [string] $SourcePath, [string] $Href)
    if ([string]::IsNullOrWhiteSpace($Href) -or $Href -match '[\\\r\n\?]' -or
        $Href.StartsWith('/',[StringComparison]::Ordinal) -or $Href -match '^[A-Za-z][A-Za-z0-9+.-]*:') { return $null }
    try {
        $parts = $Href.Split('#',2)
        $decoded = [Uri]::UnescapeDataString($parts[0])
        if ([string]::IsNullOrWhiteSpace($decoded)) { return $null }
        $sourceFull = [IO.Path]::GetFullPath((Join-Path $Root $SourcePath))
        $targetFull = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($sourceFull)) $decoded))
        $relative = [IO.Path]::GetRelativePath([IO.Path]::GetFullPath($Root),$targetFull)
        if ($relative -eq '..' -or $relative.StartsWith(('..' + [IO.Path]::DirectorySeparatorChar),[StringComparison]::Ordinal) -or [IO.Path]::IsPathRooted($relative)) { return $null }
        return $relative.Replace([string][IO.Path]::DirectorySeparatorChar,'/')
    } catch { return $null }
}

function Get-MarkdownSafeAbsoluteLink {
    param([string] $Href)
    $uri = $null
    return [Uri]::TryCreate($Href,[UriKind]::Absolute,[ref]$uri) -and
        $uri.Scheme -ceq 'https' -and $uri.UserInfo -eq '' -and -not [string]::IsNullOrWhiteSpace($uri.Host)
}

function Test-MarkdownHeadingAnchor {
    param([string] $Root, [string] $TargetPath, [string] $Anchor, [System.Collections.IDictionary] $SourceSnapshots)
    try {
        if ($null -ne $SourceSnapshots -and $SourceSnapshots.Contains($TargetPath)) {
            $markdown = [string]$SourceSnapshots[$TargetPath]
        } else {
            $path = [IO.Path]::GetFullPath((Join-Path $Root $TargetPath))
            $bytes = [IO.File]::ReadAllBytes($path)
            if ($bytes.Length -eq 0 -or $bytes.Length -gt 4MB) { return $false }
            $markdown = [Text.UTF8Encoding]::new($false,$true).GetString($bytes)
        }
        if ([Text.Encoding]::UTF8.GetByteCount($markdown) -eq 0 -or [Text.Encoding]::UTF8.GetByteCount($markdown) -gt 4MB) { return $false }
        $rendered = ConvertFrom-Markdown -InputObject $markdown
        if ($null -eq $rendered -or $null -eq $rendered.Html) { return $false }
        $document = [Xml.XmlDocument]::new()
        $document.XmlResolver = $null
        $document.LoadXml('<root>' + [string]$rendered.Html + '</root>')
        foreach ($heading in $document.SelectNodes('/root/h1|/root/h2|/root/h3|/root/h4|/root/h5|/root/h6')) {
            if ([string]$heading.GetAttribute('id') -ceq $Anchor) { return $true }
        }
        return $false
    } catch { return $false }
}

function Find-MarkdownLinkTarget {
    param([string] $Href, [string] $SourcePath, [object[]] $LinkBindings, [object[]] $PageMappings, [string] $Root,
        [System.Collections.IDictionary] $SourceSnapshots)
    $bindings = @($LinkBindings | Where-Object { [string]$_.href -ceq $Href })
    if ($bindings.Count -ne 1) { return $null }
    $targetId = [string]$bindings[0].targetProjectionId
    $target = @($PageMappings | Where-Object { [string]$_.projectionId -ceq $targetId })
    if ($target.Count -ne 1 -or $targetId -cnotmatch '^[a-z][a-z0-9-]{0,49}$') { return $null }
    $targetPath = Get-MarkdownTargetRelativePath -Root $Root -SourcePath $SourcePath -Href $Href
    $parts = $Href.Split('#',2)
    if ($null -eq $targetPath -or $targetPath -cne [string]$target[0].sourceArtifact) { return $null }
    $anchor = if ($parts.Count -eq 2) { [Uri]::UnescapeDataString($parts[1]) } else { '' }
    $anchorExists = if ($parts.Count -eq 2 -and [string]$target[0].sourceSectionId -ceq 'document') {
        Test-MarkdownHeadingAnchor -Root $Root -TargetPath $targetPath -Anchor $anchor -SourceSnapshots $SourceSnapshots
    } else { $true }
    if (($parts.Count -eq 2 -and (($target[0].sourceSectionId -ceq 'document' -and -not $anchorExists) -or
             ($target[0].sourceSectionId -cne 'document' -and $anchor -cne [string]$target[0].sourceSectionId))) -or
        ($parts.Count -eq 1 -and @($PageMappings | Where-Object { [string]$_.sourceArtifact -ceq $targetPath }).Count -ne 1) -or
        ([string]$target[0].pageId -ne '' -and [string]$target[0].pageId -cnotmatch '^[0-9]+$')) { return $null }
    return $target[0]
}

function Get-MarkdownHtmlLocation {
    param([Xml.XmlNode] $Node)
    $parts = [System.Collections.Generic.List[string]]::new()
    $current = $Node
    while ($null -ne $current -and $current.NodeType -eq [Xml.XmlNodeType]::Element -and $current.get_Name() -cne 'root') {
        $index = 1
        $previous = $current.PreviousSibling
        while ($null -ne $previous) {
            if ($previous.NodeType -eq [Xml.XmlNodeType]::Element -and $previous.get_Name() -ceq $current.get_Name()) { $index++ }
            $previous = $previous.PreviousSibling
        }
        $parts.Insert(0,"$($current.get_Name())[$index]")
        $current = $current.ParentNode
    }
    return '/' + ($parts -join '/')
}

function Write-MarkdownHtmlNode {
    param([Xml.XmlNode] $Node, [Xml.XmlWriter] $Writer, [System.Collections.Generic.Dictionary[string,object]] $Context)
    if ($Node.NodeType -in @([Xml.XmlNodeType]::Whitespace,[Xml.XmlNodeType]::SignificantWhitespace)) {
        $parentName = if ($null -ne $Node.ParentNode) { [string]$Node.ParentNode.get_Name() } else { '' }
        if ($parentName -in @('root','ul','ol','table','thead','tbody','tr')) { return $true }
        $Writer.WriteString([string]$Node.Value)
        return $true
    }
    if ($Node.NodeType -eq [Xml.XmlNodeType]::Text) {
        if ($Node.ParentNode.get_Name() -ceq 'root' -and -not [string]::IsNullOrWhiteSpace($Node.Value)) {
            Add-MarkdownUnsupported -Records $Context.unsupported -Code 'UnsupportedNode' -Location (Get-MarkdownHtmlLocation -Node $Node.ParentNode) -Source $Node.Value
            return $false
        }
        $Writer.WriteString([string]$Node.Value)
        return $true
    }
    if ($Node.NodeType -ne [Xml.XmlNodeType]::Element -or -not $script:allowedHtml.Contains($Node.get_Name())) {
        Add-MarkdownUnsupported -Records $Context.unsupported -Code 'UnsupportedElement' -Location (Get-MarkdownHtmlLocation -Node $Node) -Source ([string]$Node.OuterXml)
        return $false
    }

    $tag = $Node.get_Name()
    if ($tag -ceq 'a') {
        $href = [string]$Node.GetAttribute('href')
        $originalHref = $href
        if ([string]::IsNullOrWhiteSpace($href)) {
            Add-MarkdownUnsupported -Records $Context.unsupported -Code 'UnsafeUrl' -Location (Get-MarkdownHtmlLocation -Node $Node) -Source ([string]$Node.OuterXml)
            return $false
        }
        if ($href.StartsWith('#',[StringComparison]::Ordinal)) {
            $anchor = try { [Uri]::UnescapeDataString($href.Substring(1)) } catch { '' }
            if ($href -cnotmatch '^#[A-Za-z0-9._~-]+$' -or -not $Context.headingAnchors.Contains($anchor)) {
                Add-MarkdownUnsupported -Records $Context.unsupported -Code 'UnsafeUrl' -Location (Get-MarkdownHtmlLocation -Node $Node) -Source ([string]$Node.OuterXml)
                return $false
            }
        } elseif (-not (Get-MarkdownSafeAbsoluteLink -Href $href)) {
            $target = $null
            if (-not [string]::IsNullOrWhiteSpace($Context.siteOrigin)) {
                $target = Find-MarkdownLinkTarget -Href $href -SourcePath $Context.sourcePath -LinkBindings $Context.linkBindings `
                    -PageMappings $Context.pageMappings -Root $Context.root -SourceSnapshots $Context.sourceSnapshots
            }
            if ($null -eq $target) {
                $code = if ($href -match '^[A-Za-z][A-Za-z0-9+.-]*:') { 'UnsafeUrl' } else { 'LinkProjectionUnsupported' }
                Add-MarkdownUnsupported -Records $Context.unsupported -Code $code -Location (Get-MarkdownHtmlLocation -Node $Node) -Source ([string]$Node.OuterXml)
                return $false
            }
            if ([string]$target.pageId -eq '') {
                $href = "$($Context.siteOrigin.TrimEnd('/'))/wiki/pages/viewpage.action?pageId=__SYP171_LINK_$($target.projectionId)__"
                if ($Context.deferredTargets -cnotcontains [string]$target.projectionId) { $Context.deferredTargets.Add([string]$target.projectionId) }
                $fragment = $originalHref.Split('#',2)
                if ($fragment.Count -eq 2) { $href += '#' + [Uri]::EscapeDataString([Uri]::UnescapeDataString($fragment[1])) }
            } else {
                $href = "$($Context.siteOrigin.TrimEnd('/'))/wiki/pages/viewpage.action?pageId=$($target.pageId)"
                $fragment = $originalHref.Split('#',2)
                if ($fragment.Count -eq 2) { $href += '#' + [Uri]::EscapeDataString([Uri]::UnescapeDataString($fragment[1])) }
            }
            $Context.usedBindings.Add($originalHref) | Out-Null
        }
        $allowedAttributes = @('href','title')
    } elseif ($tag -ceq 'img') {
        $src = [string]$Node.GetAttribute('src')
        $alt = [string]$Node.GetAttribute('alt')
        $hasTitle = $false
        $title = ''
        foreach ($attribute in $Node.Attributes) {
            if ($attribute.NamespaceURI -cne '' -or $attribute.LocalName -cnotin @('src','alt','title')) {
                Add-MarkdownUnsupported -Records $Context.unsupported -Code 'UnsupportedAttribute' -Location (Get-MarkdownHtmlLocation -Node $Node) -Source ([string]$Node.OuterXml)
                return $false
            }
            if ($attribute.LocalName -ceq 'title') { $hasTitle = $true; $title = [string]$attribute.Value }
        }
        $localPath = Get-MarkdownTargetRelativePath -Root $Context.root -SourcePath $Context.sourcePath -Href $src
        if ($null -eq $localPath) {
            Add-MarkdownUnsupported -Records $Context.unsupported -Code 'AssetProjectionUnsupported' -Location (Get-MarkdownHtmlLocation -Node $Node) -Source ([string]$Node.OuterXml)
            return $false
        }
        $matches = @($Context.managedAssets | Where-Object { [string]$_.localPath -ceq $localPath })
        if ($matches.Count -ne 1) {
            Add-MarkdownUnsupported -Records $Context.unsupported -Code 'AssetProjectionUnsupported' -Location (Get-MarkdownHtmlLocation -Node $Node) -Source ([string]$Node.OuterXml)
            return $false
        }
        $asset = Resolve-LocalManagedAsset -Root $Context.root -ProjectionId $Context.projectionId -Asset $matches[0]
        if ($asset.status -cne 'valid' -or [string]$asset.mediaType -notin @('image/png','image/jpeg','image/gif')) {
            Add-MarkdownUnsupported -Records $Context.unsupported -Code 'AssetProjectionUnsupported' -Location (Get-MarkdownHtmlLocation -Node $Node) -Source ([string]$Node.OuterXml)
            return $false
        }
        if ($Context.usedAssets.Add([string]$localPath)) { $Context.assets.Add($asset) }
        $Writer.WriteStartElement('ac','image',$script:acNamespace)
        $Writer.WriteAttributeString('ac','alt',$script:acNamespace,$alt)
        if ($hasTitle) { $Writer.WriteAttributeString('ac','title',$script:acNamespace,$title) }
        $Writer.WriteStartElement('ri','attachment',$script:riNamespace)
        $Writer.WriteAttributeString('ri','filename',$script:riNamespace,[string]$asset.remoteFilename)
        $Writer.WriteEndElement()
        $Writer.WriteEndElement()
        return $true
    } elseif ($tag -ceq 'h1' -or $tag -ceq 'h2' -or $tag -ceq 'h3' -or $tag -ceq 'h4' -or $tag -ceq 'h5' -or $tag -ceq 'h6') {
        $allowedAttributes = @('id')
    } elseif ($tag -ceq 'ol') {
        $allowedAttributes = @('start')
    } elseif ($tag -ceq 'code') {
        $allowedAttributes = @('class')
    } elseif ($tag -ceq 'th' -or $tag -ceq 'td') {
        $allowedAttributes = @('style','colspan','rowspan')
    } else {
        $allowedAttributes = @()
    }

    foreach ($attribute in $Node.Attributes) {
        if ($attribute.NamespaceURI -cne '' -or $attribute.LocalName -cnotin $allowedAttributes) {
            Add-MarkdownUnsupported -Records $Context.unsupported -Code 'UnsupportedAttribute' -Location (Get-MarkdownHtmlLocation -Node $Node) -Source ([string]$Node.OuterXml)
            return $false
        }
        if ($tag -in @('h1','h2','h3','h4','h5','h6') -and $attribute.LocalName -ceq 'id' -and $attribute.Value -cnotmatch '^[\p{L}\p{Nd}_-]{1,256}$') {
            Add-MarkdownUnsupported -Records $Context.unsupported -Code 'UnsupportedAttribute' -Location (Get-MarkdownHtmlLocation -Node $Node) -Source ([string]$Node.OuterXml)
            return $false
        }
        if ($tag -ceq 'ol' -and $attribute.LocalName -ceq 'start' -and $attribute.Value -cnotmatch '^[1-9][0-9]{0,5}$') {
            Add-MarkdownUnsupported -Records $Context.unsupported -Code 'UnsupportedAttribute' -Location (Get-MarkdownHtmlLocation -Node $Node) -Source ([string]$Node.OuterXml)
            return $false
        }
        if ($tag -ceq 'code' -and $attribute.LocalName -ceq 'class' -and $attribute.Value -cnotmatch '^language-[A-Za-z0-9.+_-]{1,64}$') {
            Add-MarkdownUnsupported -Records $Context.unsupported -Code 'UnsupportedAttribute' -Location (Get-MarkdownHtmlLocation -Node $Node) -Source ([string]$Node.OuterXml)
            return $false
        }
        if (($tag -ceq 'td' -or $tag -ceq 'th') -and $attribute.LocalName -ceq 'style' -and $attribute.Value -cnotmatch '^text-align: (left|center|right);$') {
            Add-MarkdownUnsupported -Records $Context.unsupported -Code 'UnsupportedTableStyle' -Location (Get-MarkdownHtmlLocation -Node $Node) -Source ([string]$Node.OuterXml)
            return $false
        }
        if (($tag -ceq 'td' -or $tag -ceq 'th') -and $attribute.LocalName -in @('colspan','rowspan') -and $attribute.Value -cne '1') {
            Add-MarkdownUnsupported -Records $Context.unsupported -Code 'MergedTableCell' -Location (Get-MarkdownHtmlLocation -Node $Node) -Source ([string]$Node.OuterXml)
            return $false
        }
    }
    if ($tag -ceq 'a') {
        $hasHref = $false
        foreach ($attribute in $Node.Attributes) { if ($attribute.LocalName -ceq 'href') { $hasHref = $true } }
        if (-not $hasHref) {
            Add-MarkdownUnsupported -Records $Context.unsupported -Code 'UnsafeUrl' -Location (Get-MarkdownHtmlLocation -Node $Node) -Source ([string]$Node.OuterXml)
            return $false
        }
    }

    if ($tag -ceq 'br') { $Writer.WriteStartElement('br'); $Writer.WriteEndElement(); return $true }
    $Writer.WriteStartElement($tag)
    foreach ($attribute in $Node.Attributes) {
        if ($tag -ceq 'a' -and $attribute.LocalName -ceq 'href') { $Writer.WriteAttributeString('href',$href) }
        else { $Writer.WriteAttributeString($attribute.LocalName,[string]$attribute.Value) }
    }
    foreach ($child in $Node.ChildNodes) {
        if (-not (Write-MarkdownHtmlNode -Node $child -Writer $Writer -Context $Context)) { return $false }
    }
    $Writer.WriteEndElement()
    return $true
}

function Test-MarkdownRawHtml {
    param([object] $Block, [string] $Markdown, [System.Collections.Generic.List[object]] $Unsupported)
    if ($null -eq $Block) { return }
    $typeName = $Block.GetType().FullName
    if ($typeName -ceq 'Markdig.Syntax.HtmlBlock') {
        $position = [int]$Block.Span.Start
        Add-MarkdownUnsupported -Records $Unsupported -Code 'RawHtmlUnsupported' `
            -Location "line $(Get-MarkdownLineNumber -Markdown $Markdown -Position $position)" -Source ([string]$Block.Lines.ToString())
        return
    }
    $inlineProperty = $Block.PSObject.Properties['Inline']
    if ($null -ne $inlineProperty -and $null -ne $inlineProperty.Value) {
        Test-MarkdownRawInline -Inline $inlineProperty.Value.FirstChild -Markdown $Markdown -Unsupported $Unsupported
    }
    if ($Block -is [System.Collections.IEnumerable] -and $Block -isnot [string]) {
        foreach ($childBlock in $Block) { Test-MarkdownRawHtml -Block $childBlock -Markdown $Markdown -Unsupported $Unsupported }
    }
}

function Test-MarkdownRawInline {
    param([object] $Inline, [string] $Markdown, [System.Collections.Generic.List[object]] $Unsupported)
    $current = $Inline
    while ($null -ne $current) {
        if ($current.GetType().FullName -ceq 'Markdig.Syntax.Inlines.HtmlInline') {
            $position = [int]$current.Span.Start
            Add-MarkdownUnsupported -Records $Unsupported -Code 'RawHtmlUnsupported' `
                -Location "line $(Get-MarkdownLineNumber -Markdown $Markdown -Position $position)" -Source ([string]$current.ToString())
        }
        $children = $current.PSObject.Properties['FirstChild']
        if ($null -ne $children -and $null -ne $children.Value) {
            Test-MarkdownRawInline -Inline $children.Value -Markdown $Markdown -Unsupported $Unsupported
        }
        $current = $current.NextSibling
    }
}

function ConvertTo-ConfluenceMarkdownStorage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Markdown,
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $SourcePath,
        [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{0,49}$')][string] $ProjectionId,
        [object[]] $ManagedAssets = @(),
        [object[]] $LinkBindings = @(),
        [object[]] $PageMappings = @(),
        [System.Collections.IDictionary] $SourceSnapshots,
        [string] $SiteOrigin = ''
    )
    $sourceHash = Get-MarkdownProjectionHash -Text $Markdown
    if (-not (Test-Path -LiteralPath $Root -PathType Container) -or
        -not (Test-MarkdownProjectRelativePath -Root $Root -RelativePath $SourcePath)) {
        return New-MarkdownProjectionResult -Status 'invalid' -ReasonCodes @('SourcePathInvalid') -SourceSha256 $sourceHash
    }
    if ([Text.Encoding]::UTF8.GetByteCount($Markdown) -gt 4MB) {
        return New-MarkdownProjectionResult -Status 'invalid' -ReasonCodes @('SourceTooLarge') -SourceSha256 $sourceHash
    }
    if ([string]::IsNullOrWhiteSpace($Markdown)) {
        return New-MarkdownProjectionResult -Status 'invalid' -ReasonCodes @('SourceEmpty') -SourceSha256 $sourceHash
    }
    $converter = Get-Command -Name ConvertFrom-Markdown -ErrorAction SilentlyContinue
    if ($null -eq $converter) {
        return New-MarkdownProjectionResult -Status 'invalid' -ReasonCodes @('MarkdownRendererUnavailable') -SourceSha256 $sourceHash
    }
    try { $markdownInfo = ConvertFrom-Markdown -InputObject $Markdown }
    catch { return New-MarkdownProjectionResult -Status 'invalid' -ReasonCodes @('MarkdownRenderInvalid') -SourceSha256 $sourceHash }
    if ($null -eq $markdownInfo -or $null -eq $markdownInfo.Tokens -or $null -eq $markdownInfo.Html) {
        return New-MarkdownProjectionResult -Status 'invalid' -ReasonCodes @('MarkdownRendererUnavailable') -SourceSha256 $sourceHash
    }
    $unsupported = [System.Collections.Generic.List[object]]::new()
    foreach ($block in $markdownInfo.Tokens) { Test-MarkdownRawHtml -Block $block -Markdown $Markdown -Unsupported $unsupported }
    if ($unsupported.Count -gt 0) {
        return New-MarkdownProjectionResult -Status 'unsupported' -ReasonCodes @($unsupported | ForEach-Object code | Select-Object -Unique) `
            -Unsupported $unsupported.ToArray() -SourceSha256 $sourceHash
    }

    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $settings.MaxCharactersInDocument = 4MB
    $settings.MaxCharactersFromEntities = 0
    $document = [Xml.XmlDocument]::new()
    $document.XmlResolver = $null
    $document.PreserveWhitespace = $true
    $wrapped = '<root>' + [string]$markdownInfo.Html + '</root>'
    try {
        $stringReader = [IO.StringReader]::new($wrapped)
        $reader = [Xml.XmlReader]::Create($stringReader,$settings)
        try { $document.Load($reader) } finally { $reader.Dispose(); $stringReader.Dispose() }
    } catch { return New-MarkdownProjectionResult -Status 'invalid' -ReasonCodes @('MarkdownRenderInvalid') -SourceSha256 $sourceHash }

    $rootFull = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path)
    $linkBindings = @($LinkBindings)
    $context = [System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $context['root'] = $rootFull
    $context['sourcePath'] = $SourcePath
    $context['projectionId'] = $ProjectionId
    $context['managedAssets'] = @($ManagedAssets)
    $context['linkBindings'] = $linkBindings
    $context['pageMappings'] = @($PageMappings)
    $context['sourceSnapshots'] = $SourceSnapshots
    $context['siteOrigin'] = $SiteOrigin
    $context['sourceHref'] = ''
    $context['unsupported'] = [System.Collections.Generic.List[object]]::new()
    $context['assets'] = [System.Collections.Generic.List[object]]::new()
    $context['deferredTargets'] = [System.Collections.Generic.List[string]]::new()
    $headingAnchors = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($heading in $document.SelectNodes('/root/h1|/root/h2|/root/h3|/root/h4|/root/h5|/root/h6')) {
        $id = [string]$heading.GetAttribute('id')
        if ($id -ne '') { $headingAnchors.Add($id) | Out-Null }
    }
    $context['headingAnchors'] = $headingAnchors
    $context['usedAssets'] = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $context['usedBindings'] = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

    $writerSettings = [Xml.XmlWriterSettings]::new()
    $writerSettings.OmitXmlDeclaration = $true
    $writerSettings.ConformanceLevel = [Xml.ConformanceLevel]::Fragment
    $writerSettings.Indent = $false
    $writerSettings.NewLineHandling = [Xml.NewLineHandling]::None
    $sink = [IO.StringWriter]::new([Globalization.CultureInfo]::InvariantCulture)
    $writer = [Xml.XmlWriter]::Create($sink,$writerSettings)
    try {
        foreach ($node in $document.DocumentElement.ChildNodes) {
            if (-not (Write-MarkdownHtmlNode -Node $node -Writer $writer -Context $context)) { break }
        }
        $writer.Flush()
        $storageTemplate = $sink.ToString()
    } catch {
        $storageTemplate = ''
        if ($context.unsupported.Count -eq 0) {
            Add-MarkdownUnsupported -Records $context.unsupported -Code 'MarkdownProjectionInvalid' -Location '/root' -Source ([string]$markdownInfo.Html)
        }
    } finally { $writer.Dispose(); $sink.Dispose() }

    foreach ($asset in $ManagedAssets) {
        if ([string]$asset.localPath -cnotin $context.usedAssets) {
            Add-MarkdownUnsupported -Records $context.unsupported -Code 'AssetBindingUnused' -Location $SourcePath -Source ([string]$asset.localPath)
        }
    }
    foreach ($binding in $linkBindings) {
        if ([string]$binding.href -cnotin $context.usedBindings) {
            Add-MarkdownUnsupported -Records $context.unsupported -Code 'LinkBindingUnused' -Location $SourcePath -Source ([string]$binding.href)
        }
    }
    if ($context.unsupported.Count -gt 0) {
        return New-MarkdownProjectionResult -Status 'unsupported' -ReasonCodes @($context.unsupported | ForEach-Object code | Select-Object -Unique) `
            -Unsupported $context.unsupported.ToArray() -SourceSha256 $sourceHash
    }
    if ([Text.Encoding]::UTF8.GetByteCount($storageTemplate) -gt 4MB) {
        return New-MarkdownProjectionResult -Status 'invalid' -ReasonCodes @('ProjectionTooLarge') -SourceSha256 $sourceHash
    }
    $bodyHash = Get-MarkdownProjectionHash -Text $storageTemplate
    if ($context.deferredTargets.Count -gt 0) {
        return New-MarkdownProjectionResult -Status 'deferred' -ReasonCodes @('LinkTargetPending') -StorageTemplate $storageTemplate `
            -Assets $context.assets.ToArray() -SourceSha256 $sourceHash -BodySha256 $bodyHash -DeferredTargets $context.deferredTargets.ToArray()
    }
    return New-MarkdownProjectionResult -Status 'supported' -Storage $storageTemplate -Assets $context.assets.ToArray() `
        -SourceSha256 $sourceHash -BodySha256 $bodyHash
}

Export-ModuleMember -Function ConvertTo-ConfluenceMarkdownStorage
