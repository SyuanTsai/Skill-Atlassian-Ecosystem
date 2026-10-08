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
        $attributes.Add("{$($attribute.NamespaceURI)}$($attribute.LocalName)", [string]$attribute.Value)
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

Export-ModuleMember -Function Test-ConfluenceStorageEquivalent,Get-ConfluenceStorageAttachmentNames
