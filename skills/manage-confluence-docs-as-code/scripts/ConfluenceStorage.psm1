# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest

function ConvertFrom-StorageNamedEntities {
    param([string]$Storage)
    # Confluence storage is XHTML and may use HTML named entities that a DTD-free XML parser rejects.
    # Replace each known named entity outside CDATA and comments with its XML-escaped character(s).
    # The five XML entities stay as they are; an unknown name throws, so callers keep failing closed.
    $xmlEntities = @('amp','lt','gt','quot','apos')
    $segments = [regex]::Split($Storage, '(<!\[CDATA\[.*?\]\]>|<!--.*?-->)', [Text.RegularExpressions.RegexOptions]::Singleline)
    $builder = [Text.StringBuilder]::new($Storage.Length)
    foreach ($segment in $segments) {
        if ($segment.StartsWith('<![CDATA[', [StringComparison]::Ordinal) -or $segment.StartsWith('<!--', [StringComparison]::Ordinal)) {
            $null = $builder.Append($segment); continue
        }
        $decoded = [regex]::Replace($segment, '&([A-Za-z][A-Za-z0-9]{0,31});', {
            param($match)
            $name = $match.Groups[1].Value
            if ($name -cin $xmlEntities) { return $match.Value }
            $value = [Net.WebUtility]::HtmlDecode($match.Value)
            if ($value -ceq $match.Value -or [string]::IsNullOrEmpty($value)) { throw 'StorageEntityUnknown' }
            return [Security.SecurityElement]::Escape($value)
        })
        $null = $builder.Append($decoded)
    }
    return $builder.ToString()
}

function Read-StorageFragment {
    param([string]$Storage)
    if ([Text.Encoding]::UTF8.GetByteCount($Storage) -gt 4MB) { throw 'StorageTooLarge' }
    $Storage = ConvertFrom-StorageNamedEntities $Storage
    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $settings.MaxCharactersInDocument = 4MB
    $document = [Xml.XmlDocument]::new()
    $document.PreserveWhitespace = $true
    $document.XmlResolver = $null
    $text = '<syp171-root xmlns:ac="http://atlassian.com/content" xmlns:ri="http://atlassian.com/resource/identifier">' + $Storage + '</syp171-root>'
    $stringReader = [IO.StringReader]::new($text)
    $reader = [Xml.XmlReader]::Create($stringReader, $settings)
    try { $document.Load($reader) } finally { $reader.Dispose(); $stringReader.Dispose() }
    return $document.DocumentElement
}

function Get-StorageAttributes {
    param([Xml.XmlNode]$Node)
    $attributes = [System.Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($attribute in $Node.Attributes) {
        if ($attribute.NamespaceURI -ceq 'http://www.w3.org/2000/xmlns/') { continue }
        $attributes.Add(('{' + $attribute.NamespaceURI + '}' + $attribute.LocalName), [string]$attribute.Value)
    }
    return ,$attributes
}

function Get-StorageChildren {
    param([Xml.XmlNode]$Node)
    $children = [System.Collections.Generic.List[object]]::new()
    foreach ($child in $Node.ChildNodes) {
        if ($child.NodeType -in @([Xml.XmlNodeType]::Text, [Xml.XmlNodeType]::CDATA, [Xml.XmlNodeType]::Whitespace, [Xml.XmlNodeType]::SignificantWhitespace)) {
            if ($children.Count -gt 0 -and $children[$children.Count - 1].kind -ceq 'text') {
                $children[$children.Count - 1].value += [string]$child.Value
            } else { $children.Add([pscustomobject]@{kind='text'; value=[string]$child.Value; node=$null}) }
        } else { $children.Add([pscustomobject]@{kind=[string]$child.NodeType; value=''; node=$child}) }
    }
    return ,$children
}

# Confluence editor normalization tolerated by the comparison. Each rule applies only in the direction
# "frozen payload (expected) -> remote body (actual)" and only to markup that Markdown cannot author:
#   1. Editor identity/layout attributes the payload lacks: local-id on block elements, ac:local-id on table
#      parts, and on table data-table-width (digits) and data-layout="default".
#   2. thead/tbody/tfoot wrappers without other attributes: a table compares as its ordered row sequence.
#   3. A th/td whose payload content has no block element may hold that content inside exactly one <p>.
#   4. Whitespace-only text between elements of element-only containers (the body root, table parts, ul/ol),
#      and inside li/th/td/blockquote whose element children are all blocks.
# Text, inline elements, element order, links, and every other attribute still compare exactly.
$script:editorLocalIdElements = @('h1','h2','h3','h4','h5','h6','p','ul','ol','li','table','thead','tbody','tfoot','tr','th','td','blockquote','pre')
$script:editorAcLocalIdElements = @('table','thead','tbody','tfoot','tr','th','td')
$script:tableWrapperElements = @('thead','tbody','tfoot')
$script:elementOnlyContainers = @('table','thead','tbody','tfoot','tr','ul','ol')
$script:blockAwareContainers = @('li','th','td','blockquote')
$script:blockElements = @('p','h1','h2','h3','h4','h5','h6','ul','ol','table','pre','blockquote','hr','div')

function Remove-EditorAttributes {
    param([Xml.XmlNode]$Node,[System.Collections.Generic.Dictionary[string,string]]$Expected,[System.Collections.Generic.Dictionary[string,string]]$Actual)
    if ($Node.NamespaceURI -cne '') { return }
    $name = $Node.LocalName
    $rules = @(
        @{key='{}local-id'; allowed=($name -cin $script:editorLocalIdElements); pattern='^[A-Za-z0-9-]{1,64}$'},
        @{key='{http://atlassian.com/content}local-id'; allowed=($name -cin $script:editorAcLocalIdElements); pattern='^[A-Za-z0-9-]{1,64}$'},
        @{key='{}data-table-width'; allowed=($name -ceq 'table'); pattern='^[0-9]{1,5}$'},
        @{key='{}data-layout'; allowed=($name -ceq 'table'); pattern='^default$'}
    )
    foreach ($rule in $rules) {
        if ($rule.allowed -and -not $Expected.ContainsKey($rule.key) -and $Actual.ContainsKey($rule.key) -and
            $Actual[$rule.key] -cmatch $rule.pattern) { $null = $Actual.Remove($rule.key) }
    }
}

function Test-EditorOnlyAttributes {
    param([Xml.XmlNode]$Node,[bool]$AllowEditor)
    $attributes = Get-StorageAttributes $Node
    if ($AllowEditor) { Remove-EditorAttributes -Node $Node -Expected ([System.Collections.Generic.Dictionary[string,string]]::new()) -Actual $attributes }
    return $attributes.Count -eq 0
}

function Test-StorageWhitespaceText {
    param($Item)
    return $Item.kind -ceq 'text' -and $Item.value -cmatch '^\s*$'
}

function Get-ComparableChildren {
    param([Xml.XmlNode]$Node,[bool]$IsActual)
    $items = Get-StorageChildren $Node
    $html = $Node.NamespaceURI -ceq ''
    if ($html -and $Node.LocalName -ceq 'table') {
        $flat = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $items) {
            if ($item.kind -ceq 'Element' -and $item.node.NamespaceURI -ceq '' -and $item.node.LocalName -cin $script:tableWrapperElements -and
                (Test-EditorOnlyAttributes -Node $item.node -AllowEditor $IsActual)) {
                foreach ($child in (Get-StorageChildren $item.node)) { $flat.Add($child) }
            } else { $flat.Add($item) }
        }
        $items = $flat
    }
    $dropWhitespace = $Node.ParentNode -is [Xml.XmlDocument] -or ($html -and $Node.LocalName -cin $script:elementOnlyContainers)
    if (-not $dropWhitespace -and $html -and $Node.LocalName -cin $script:blockAwareContainers) {
        $elements = @($items | Where-Object { $_.kind -ceq 'Element' })
        $dropWhitespace = $elements.Count -gt 0 -and @($items | Where-Object { $_.kind -ceq 'text' -and -not (Test-StorageWhitespaceText $_) }).Count -eq 0 -and
            @($elements | Where-Object { $_.node.NamespaceURI -cne '' -or $_.node.LocalName -cnotin $script:blockElements }).Count -eq 0
    }
    if ($dropWhitespace) {
        $kept = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $items) { if (-not (Test-StorageWhitespaceText $item)) { $kept.Add($item) } }
        $items = $kept
    }
    return ,$items
}

function Test-StorageChildren {
    param([System.Collections.Generic.List[object]]$Expected,[System.Collections.Generic.List[object]]$Actual)
    if ($Expected.Count -ne $Actual.Count) { return $false }
    for ($i = 0; $i -lt $Expected.Count; $i++) {
        $left = $Expected[$i]; $right = $Actual[$i]
        if ($left.kind -cne $right.kind) { return $false }
        if ($left.kind -ceq 'text') {
            if ($left.value -cne $right.value) { return $false }
        } elseif (-not (Test-StorageNode -Expected $left.node -Actual $right.node)) { return $false }
    }
    return $true
}

function Test-StorageNode {
    param([Xml.XmlNode]$Expected, [Xml.XmlNode]$Actual)
    if ($Expected.NodeType -ne $Actual.NodeType) { return $false }
    if ($Expected.NodeType -ne [Xml.XmlNodeType]::Element) {
        return $Expected.Name -ceq $Actual.Name -and $Expected.Value -ceq $Actual.Value
    }
    if ($Expected.LocalName -cne $Actual.LocalName -or $Expected.NamespaceURI -cne $Actual.NamespaceURI) { return $false }
    $expectedAttributes = Get-StorageAttributes $Expected
    $actualAttributes = Get-StorageAttributes $Actual
    $macroId = '{http://atlassian.com/content}macro-id'
    if ($Expected.NamespaceURI -ceq 'http://atlassian.com/content' -and $Expected.LocalName -ceq 'structured-macro' -and
        -not $expectedAttributes.ContainsKey($macroId) -and $actualAttributes.ContainsKey($macroId)) {
        if ($actualAttributes[$macroId] -cnotmatch '^[a-fA-F0-9]{8}-(?:[a-fA-F0-9]{4}-){3}[a-fA-F0-9]{12}$') { return $false }
        $null = $actualAttributes.Remove($macroId)
    }
    # Confluence drops the renderer's heading ids on save; only their absence is tolerated, never a changed id.
    $headingId = '{}id'
    if ($Expected.NamespaceURI -ceq '' -and $Expected.LocalName -cmatch '^h[1-6]$' -and
        $expectedAttributes.ContainsKey($headingId) -and -not $actualAttributes.ContainsKey($headingId)) {
        $null = $expectedAttributes.Remove($headingId)
    }
    Remove-EditorAttributes -Node $Expected -Expected $expectedAttributes -Actual $actualAttributes
    if ($expectedAttributes.Count -ne $actualAttributes.Count) { return $false }
    foreach ($key in $expectedAttributes.Keys) {
        if (-not $actualAttributes.ContainsKey($key) -or $expectedAttributes[$key] -cne $actualAttributes[$key]) { return $false }
    }
    $expectedChildren = Get-ComparableChildren -Node $Expected -IsActual $false
    $actualChildren = Get-ComparableChildren -Node $Actual -IsActual $true
    if (Test-StorageChildren -Expected $expectedChildren -Actual $actualChildren) { return $true }
    if ($Expected.NamespaceURI -ceq '' -and $Expected.LocalName -cin @('th','td') -and $actualChildren.Count -eq 1 -and
        $actualChildren[0].kind -ceq 'Element' -and $actualChildren[0].node.NamespaceURI -ceq '' -and $actualChildren[0].node.LocalName -ceq 'p' -and
        @($expectedChildren | Where-Object { $_.kind -ceq 'Element' -and $_.node.NamespaceURI -ceq '' -and $_.node.LocalName -cin $script:blockElements }).Count -eq 0 -and
        (Test-EditorOnlyAttributes -Node $actualChildren[0].node -AllowEditor $true)) {
        return Test-StorageChildren -Expected $expectedChildren -Actual (Get-StorageChildren $actualChildren[0].node)
    }
    return $false
}
function Test-ConfluenceStorageEquivalent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Expected, [Parameter(Mandatory)][AllowEmptyString()][string]$Actual)
    try { return Test-StorageNode -Expected (Read-StorageFragment $Expected) -Actual (Read-StorageFragment $Actual) }
    catch { return $false }
}

function Get-ConfluenceStorageAttachmentNames {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Storage,
        [Parameter(Mandatory)][string]$SiteOrigin,
        [Parameter(Mandatory)][ValidatePattern('^[0-9]+$')][string]$PageId
    )
    try {
        $origin=[Uri]::new($SiteOrigin,[UriKind]::Absolute)
        if($origin.Scheme -cne 'https' -or $origin.UserInfo -cne '' -or $origin.AbsolutePath -cne '/' -or
            $origin.Query -cne '' -or $origin.Fragment -cne ''){throw 'AttachmentOriginInvalid'}
        $root=Read-StorageFragment $Storage
        $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach($node in $root.SelectNodes('//*[local-name()="attachment" and namespace-uri()="http://atlassian.com/resource/identifier"]')){
            $name=$node.GetAttribute('filename','http://atlassian.com/resource/identifier')
            if([string]::IsNullOrWhiteSpace($name)){throw 'AttachmentReferenceInvalid'}
            $null=$names.Add($name)
        }
        foreach($macro in $root.SelectNodes('//*[local-name()="structured-macro" and namespace-uri()="http://atlassian.com/content" and @*[local-name()="name" and namespace-uri()="http://atlassian.com/content"]="mermaid-cloud"]')){
            $filenameParameters=@($macro.ChildNodes | Where-Object {
                $_.NodeType -eq [Xml.XmlNodeType]::Element -and $_.LocalName -ceq 'parameter' -and
                $_.NamespaceURI -ceq 'http://atlassian.com/content' -and
                $_.GetAttribute('name','http://atlassian.com/content') -ceq 'filename'
            })
            if($filenameParameters.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$filenameParameters[0].InnerText)){throw 'AttachmentReferenceInvalid'}
            $null=$names.Add([string]$filenameParameters[0].InnerText)
        }
        foreach($attribute in $root.SelectNodes('//@href | //@src | //*[local-name()="url" and namespace-uri()="http://atlassian.com/resource/identifier"]/@*[local-name()="value" and namespace-uri()="http://atlassian.com/resource/identifier"]')){
            $url=$null
            if(-not [Uri]::TryCreate($origin,[string]$attribute.Value,[ref]$url)){continue}
            if($url.Scheme -cne 'https' -or $url.Host -ine $origin.Host -or $url.Port -ne $origin.Port -or $url.UserInfo -cne ''){continue}
            if($url.AbsolutePath -cmatch '^/(?:wiki/)?download/attachments/([0-9]+)/([^/]+)$' -and $Matches[1] -ceq $PageId){
                $null=$names.Add([Uri]::UnescapeDataString($Matches[2]))
            }
        }
        return [pscustomobject]@{status='valid';names=@($names)}
    } catch {return [pscustomobject]@{status='invalid';names=@()}}
}

function Add-StorageInventoryItem {
    param([System.Collections.Generic.Dictionary[string,int]]$Counts,[string]$Kind,[string]$Key)
    if ([string]::IsNullOrWhiteSpace($Key)) { return }
    $name = $Kind + [char]0 + $Key
    $current = 0
    if ($Counts.TryGetValue($name, [ref]$current)) { $Counts[$name] = $current + 1 } else { $Counts[$name] = 1 }
}

function Get-StoragePageLinkKey {
    param([Uri]$Origin,[string]$Value)
    $url = $null
    if (-not [Uri]::TryCreate($Origin, $Value, [ref]$url) -or $url.Scheme -cne 'https' -or
        $url.Host -ine $Origin.Host -or $url.Port -ne $Origin.Port) { return '' }
    if ($url.AbsolutePath -ceq '/wiki/pages/viewpage.action' -and $url.Query -cmatch '(?:^\?|&)pageId=([0-9]+)(?:&|$)') { return 'pageId:' + $Matches[1] }
    if ($url.AbsolutePath -cmatch '^/wiki/spaces/[^/]+/pages/([0-9]+)(?:/.*)?$') { return 'pageId:' + $Matches[1] }
    return ''
}

function Get-StorageInventory {
    param([string]$Storage,[Uri]$Origin)
    $ac = 'http://atlassian.com/content'
    $ri = 'http://atlassian.com/resource/identifier'
    $root = Read-StorageFragment $Storage
    $counts = [System.Collections.Generic.Dictionary[string,int]]::new([StringComparer]::Ordinal)
    foreach ($macro in $root.SelectNodes('//*[(local-name()="structured-macro" or local-name()="macro") and namespace-uri()="http://atlassian.com/content"]')) {
        $name = $macro.GetAttribute('name', $ac)
        Add-StorageInventoryItem $counts 'macro' $name
        if ($name -ceq 'mermaid-cloud') {
            foreach ($parameter in $macro.ChildNodes) {
                if ($parameter.NodeType -eq [Xml.XmlNodeType]::Element -and $parameter.LocalName -ceq 'parameter' -and
                    $parameter.NamespaceURI -ceq $ac -and $parameter.GetAttribute('name', $ac) -ceq 'filename') {
                    Add-StorageInventoryItem $counts 'attachment' ([string]$parameter.InnerText).Trim()
                }
            }
        }
    }
    foreach ($attachment in $root.SelectNodes('//*[local-name()="attachment" and namespace-uri()="http://atlassian.com/resource/identifier"]')) {
        Add-StorageInventoryItem $counts 'attachment' $attachment.GetAttribute('filename', $ri)
    }
    foreach ($page in $root.SelectNodes('//*[local-name()="page" and namespace-uri()="http://atlassian.com/resource/identifier"]')) {
        $contentId = $page.GetAttribute('content-id', $ri)
        if ($contentId -cmatch '^[0-9]+$') { Add-StorageInventoryItem $counts 'pageLink' ('pageId:' + $contentId); continue }
        $space = $page.GetAttribute('space-key', $ri)
        $title = $page.GetAttribute('content-title', $ri)
        Add-StorageInventoryItem $counts 'pageLink' ('title:' + $(if ($space) { $space + '/' } else { '' }) + $title)
    }
    foreach ($attribute in $root.SelectNodes('//@href | //*[local-name()="url" and namespace-uri()="http://atlassian.com/resource/identifier"]/@*[local-name()="value" and namespace-uri()="http://atlassian.com/resource/identifier"]')) {
        Add-StorageInventoryItem $counts 'pageLink' (Get-StoragePageLinkKey -Origin $Origin -Value ([string]$attribute.Value))
    }
    foreach ($heading in $root.SelectNodes('//*[namespace-uri()="" and (local-name()="h1" or local-name()="h2" or local-name()="h3" or local-name()="h4" or local-name()="h5" or local-name()="h6")]')) {
        Add-StorageInventoryItem $counts 'heading' ([regex]::Replace([string]$heading.InnerText, '\s+', ' ').Trim())
    }
    return ,$counts
}

function Compare-ConfluenceStorageContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Baseline,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Payload,
        [Parameter(Mandatory)][string]$SiteOrigin
    )
    try {
        $origin = [Uri]::new($SiteOrigin, [UriKind]::Absolute)
        $before = Get-StorageInventory -Storage $Baseline -Origin $origin
        $after = Get-StorageInventory -Storage $Payload -Origin $origin
    } catch { return [pscustomobject]@{status='invalid';removed=@();blocking=$true} }
    $order = @('macro','attachment','pageLink','heading')
    $removed = [System.Collections.Generic.List[object]]::new()
    foreach ($kind in $order) {
        $keys = [System.Collections.Generic.List[string]]::new()
        foreach ($name in $before.Keys) {
            $parts = $name.Split([char]0, 2)
            if ($parts[0] -ceq $kind) { $keys.Add($parts[1]) }
        }
        $keys.Sort([StringComparer]::Ordinal)
        foreach ($key in $keys) {
            $name = $kind + [char]0 + $key
            $payloadCount = 0
            $null = $after.TryGetValue($name, [ref]$payloadCount)
            if ($before[$name] -gt $payloadCount) {
                $removed.Add([pscustomobject][ordered]@{kind=$kind;key=$key;baselineCount=$before[$name];payloadCount=$payloadCount})
            }
        }
    }
    $blocking = @($removed | Where-Object { $_.kind -cne 'heading' }).Count -gt 0
    return [pscustomobject]@{status='valid';removed=@($removed.ToArray());blocking=$blocking}
}

Export-ModuleMember -Function Test-ConfluenceStorageEquivalent,Get-ConfluenceStorageAttachmentNames,Compare-ConfluenceStorageContent
