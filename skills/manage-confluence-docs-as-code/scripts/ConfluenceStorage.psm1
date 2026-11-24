# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest

function Read-StorageFragment {
    param([string]$Storage)
    if ([Text.Encoding]::UTF8.GetByteCount($Storage) -gt 4MB) { throw 'StorageTooLarge' }
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
    if ($expectedAttributes.Count -ne $actualAttributes.Count) { return $false }
    foreach ($key in $expectedAttributes.Keys) {
        if (-not $actualAttributes.ContainsKey($key) -or $expectedAttributes[$key] -cne $actualAttributes[$key]) { return $false }
    }
    $expectedChildren = Get-StorageChildren $Expected
    $actualChildren = Get-StorageChildren $Actual
    if ($expectedChildren.Count -ne $actualChildren.Count) { return $false }
    for ($i = 0; $i -lt $expectedChildren.Count; $i++) {
        $left = $expectedChildren[$i]; $right = $actualChildren[$i]
        if ($left.kind -cne $right.kind) { return $false }
        if ($left.kind -ceq 'text') {
            if ($left.value -cne $right.value) { return $false }
        } elseif (-not (Test-StorageNode -Expected $left.node -Actual $right.node)) { return $false }
    }
    return $true
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
