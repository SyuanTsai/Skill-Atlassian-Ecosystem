# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
Import-Module -Name (Join-Path $PSScriptRoot 'ConfluenceAssets.psm1') -Force -Scope Local

$script:acNamespace = 'http://atlassian.com/content'
$script:riNamespace = 'http://atlassian.com/resource/identifier'
$script:allowedNodes = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($name in @('p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'ul', 'ol', 'li', 'pre', 'code', 'table', 'thead', 'tbody', 'tr', 'th', 'td', 'strong', 'em', 'a', 'br', 'ac:image', 'ac:link', 'ri:attachment')) {
    $null = $script:allowedNodes.Add($name)
}
$script:convertibleRootNodes = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($name in @('p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'ul', 'ol', 'pre', 'table', 'ac:image', 'ac:structured-macro')) {
    $null = $script:convertibleRootNodes.Add($name)
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

function Test-QualifiedStorageNode {
    param([Xml.XmlNode] $Node, [string] $LocalName, [string] $NamespaceUri)
    return $null -ne $Node -and $Node.NodeType -eq [Xml.XmlNodeType]::Element -and
        $Node.LocalName -ceq $LocalName -and $Node.NamespaceURI -ceq $NamespaceUri
}

function Get-QualifiedStorageAttribute {
    param([Xml.XmlNode] $Node, [string] $LocalName, [string] $NamespaceUri)
    if ($null -eq $Node.Attributes) { return $null }
    foreach ($attribute in $Node.Attributes) {
        if ($attribute.LocalName -ceq $LocalName -and $attribute.NamespaceURI -ceq $NamespaceUri) { return [string] $attribute.Value }
    }
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

function Test-SafeAttachmentFilename {
    param([string] $Filename)
    return -not [string]::IsNullOrWhiteSpace($Filename) -and $Filename.Length -le 255 -and
        $Filename -cnotmatch '[\\/\x00-\x1f\x7f]' -and $Filename -cnotin @('.', '..')
}

function Test-StorageTextContent {
    param([Xml.XmlNode] $Node)
    foreach ($child in $Node.ChildNodes) {
        if ($child.NodeType -notin @([Xml.XmlNodeType]::Text, [Xml.XmlNodeType]::CDATA,
            [Xml.XmlNodeType]::Whitespace, [Xml.XmlNodeType]::SignificantWhitespace)) { return $false }
    }
    return $true
}

function Test-StorageMacroAttributes {
    param([Xml.XmlNode] $Node)
    foreach ($attribute in $Node.Attributes) {
        if ($attribute.LocalName -ceq 'name' -and $attribute.NamespaceURI -ceq $script:acNamespace) { continue }
        if ($attribute.LocalName -ceq 'schema-version' -and $attribute.NamespaceURI -ceq $script:acNamespace -and [string]$attribute.Value -ceq '1') { continue }
        if ($attribute.LocalName -ceq 'macro-id' -and $attribute.NamespaceURI -ceq $script:acNamespace -and [string]$attribute.Value -cmatch '^[a-fA-F0-9]{8}-(?:[a-fA-F0-9]{4}-){3}[a-fA-F0-9]{12}$') { continue }
        return $false
    }
    return $null -ne (Get-QualifiedStorageAttribute -Node $Node -LocalName 'name' -NamespaceUri $script:acNamespace)
}

function Test-StorageMacroShape {
    param([Xml.XmlNode] $Node)
    if ($Node.ParentNode.get_Name() -cne 'root') { return 'UnsupportedMacro' }
    $name = Get-QualifiedStorageAttribute -Node $Node -LocalName 'name' -NamespaceUri $script:acNamespace
    if ($name -cnotin @('code','mermaid-cloud')) { return 'UnsupportedMacro' }
    if (-not (Test-StorageMacroAttributes -Node $Node)) { return 'UnsupportedMacroParameter' }
    $elements = @($Node.ChildNodes | Where-Object { $_.NodeType -eq [Xml.XmlNodeType]::Element })
    $nonWhitespace = @($Node.ChildNodes | Where-Object {
        $_.NodeType -notin @([Xml.XmlNodeType]::Element,[Xml.XmlNodeType]::Whitespace,[Xml.XmlNodeType]::SignificantWhitespace) -and
        -not ($_.NodeType -eq [Xml.XmlNodeType]::Text -and [string]::IsNullOrWhiteSpace([string]$_.Value))
    })
    if ($nonWhitespace.Count -gt 0) { return 'UnsupportedMacroParameter' }
    if ($name -ceq 'code') {
        $bodies = @($elements | Where-Object { Test-QualifiedStorageNode -Node $_ -LocalName 'plain-text-body' -NamespaceUri $script:acNamespace })
        $parameters = @($elements | Where-Object { Test-QualifiedStorageNode -Node $_ -LocalName 'parameter' -NamespaceUri $script:acNamespace })
        if ($bodies.Count -ne 1 -or $elements.Count -ne ($bodies.Count + $parameters.Count) -or
            $bodies[0].Attributes.Count -ne 0 -or -not (Test-StorageTextContent -Node $bodies[0])) { return 'UnsupportedMacroParameter' }
        if ($parameters.Count -gt 1) { return 'UnsupportedMacroParameter' }
        if ($parameters.Count -eq 1) {
            $parameter = $parameters[0]
            if ($parameter.Attributes.Count -ne 1 -or (Get-QualifiedStorageAttribute -Node $parameter -LocalName 'name' -NamespaceUri $script:acNamespace) -cne 'language' -or
                -not (Test-StorageTextContent -Node $parameter) -or $parameter.InnerText -cnotmatch '^[A-Za-z0-9.+_-]{1,64}$') { return 'UnsupportedMacroParameter' }
        }
        return $null
    }
    if ($elements.Count -ne 2) { return 'UnsupportedMacroParameter' }
    $values = @{}
    foreach ($parameter in $elements) {
        if (-not (Test-QualifiedStorageNode -Node $parameter -LocalName 'parameter' -NamespaceUri $script:acNamespace) -or $parameter.Attributes.Count -ne 1 -or
            -not (Test-StorageTextContent -Node $parameter)) { return 'UnsupportedMacroParameter' }
        $parameterName = Get-QualifiedStorageAttribute -Node $parameter -LocalName 'name' -NamespaceUri $script:acNamespace
        if ($parameterName -cnotin @('filename','revision') -or $values.ContainsKey($parameterName)) { return 'UnsupportedMacroParameter' }
        $values[$parameterName] = [string]$parameter.InnerText
    }
    if (-not $values.ContainsKey('filename') -or -not (Test-SafeAttachmentFilename -Filename $values['filename']) -or
        -not $values.ContainsKey('revision') -or $values['revision'] -cnotmatch '^[1-9][0-9]{0,8}$') { return 'UnsupportedMacroParameter' }
    return $null
}

function Inspect-StorageNode {
    param([Xml.XmlNode] $Node, [System.Collections.Generic.List[object]] $Unsupported)
    if ($Node.NodeType -in @([Xml.XmlNodeType]::Whitespace, [Xml.XmlNodeType]::SignificantWhitespace)) { return }
    if ($Node.NodeType -eq [Xml.XmlNodeType]::Text) {
        if (-not [string]::IsNullOrWhiteSpace($Node.Value) -and $Node.ParentNode.get_Name() -ceq 'root') { Add-UnsupportedNode -Node $Node.ParentNode -Code 'UnsupportedNode' -Records $Unsupported }
        return
    }
    if ($Node.NodeType -ne [Xml.XmlNodeType]::Element) { Add-UnsupportedNode -Node $Node -Code 'UnsupportedNode' -Records $Unsupported; return }
    $isControlledMacro = Test-QualifiedStorageNode -Node $Node -LocalName 'structured-macro' -NamespaceUri $script:acNamespace
    if ($isControlledMacro -or $Node.get_Name() -ceq 'ac:structured-macro') {
        if (-not $isControlledMacro) { Add-UnsupportedNode -Node $Node -Code 'UnsupportedMacro' -Records $Unsupported; return }
        $macroError = Test-StorageMacroShape -Node $Node
        if ($null -ne $macroError) { Add-UnsupportedNode -Node $Node -Code $macroError -Records $Unsupported }
        return
    }
    if (-not $script:allowedNodes.Contains($Node.get_Name())) { Add-UnsupportedNode -Node $Node -Code 'UnsupportedNode' -Records $Unsupported; return }

    if ($Node.get_Name() -ceq 'em') {
        $ancestor = $Node.ParentNode
        while ($null -ne $ancestor -and $ancestor.get_Name() -cne 'root') {
            if ($ancestor.get_Name() -ceq 'em') {
                Add-UnsupportedNode -Node $Node -Code 'NestedEmphasisUnsupported' -Records $Unsupported
                return
            }
            $ancestor = $ancestor.ParentNode
        }
    }

    if ($Node.get_Name() -in @('ul','ol')) {
        $ancestor = $Node.ParentNode
        while ($null -ne $ancestor -and $ancestor.get_Name() -cne 'root') {
            if ($ancestor.get_Name() -in @('ul','ol')) {
                Add-UnsupportedNode -Node $Node -Code 'NestedListUnsupported' -Records $Unsupported
                return
            }
            $ancestor = $ancestor.ParentNode
        }
        if ($Node.get_Name() -ceq 'ol') {
            $start = Get-NodeAttribute -Node $Node -Name 'start'
            if ($null -ne $start -and $start -cne '1') {
                Add-UnsupportedNode -Node $Node -Code 'ListStartUnsupported' -Records $Unsupported
                return
            }
        }
    }
    if ($Node.get_Name() -ceq 'table') {
        $rows = @($Node.SelectNodes('.//tr'))
        if ($rows.Count -gt 0) {
            foreach ($row in $rows) {
                $cells = @($row.ChildNodes | Where-Object { $_.get_Name() -in @('th', 'td') })
                $headerCells = @($cells | Where-Object { $_.get_Name() -ceq 'th' }).Count
                $dataCells = @($cells | Where-Object { $_.get_Name() -ceq 'td' }).Count
                if ($headerCells -gt 0 -and $dataCells -gt 0) {
                    Add-UnsupportedNode -Node $Node -Code 'MixedTableCellsUnsupported' -Records $Unsupported
                    return
                }
            }
            $firstCells = @($rows[0].ChildNodes | Where-Object { $_.get_Name() -in @('th','td') })
            if ($firstCells.Count -eq 0 -or @($firstCells | Where-Object { $_.get_Name() -ceq 'th' }).Count -eq 0) {
                Add-UnsupportedNode -Node $Node -Code 'HeaderlessTableUnsupported' -Records $Unsupported
            }
        }
    }

    if ($Node.get_Name() -ceq 'a') {
        $href = Get-NodeAttribute -Node $Node -Name 'href'
        if (-not (Test-SafeLink -Value $href)) {
            Add-UnsupportedNode -Node $Node -Code 'UnsafeUrl' -Records $Unsupported
            return
        }
        if (($href.Contains('(') -or $href.Contains(')')) -and $href -match '[<>\r\n]') {
            Add-UnsupportedNode -Node $Node -Code 'UnrepresentableHref' -Records $Unsupported
            return
        }
        $title = Get-NodeAttribute -Node $Node -Name 'title'
        if ($null -ne $title -and $title.Length -gt 0) {
            Add-UnsupportedNode -Node $Node -Code 'UnsupportedLinkTitle' -Records $Unsupported
            return
        }
    }
    $isControlledAttachmentLink = Test-QualifiedStorageNode -Node $Node -LocalName 'link' -NamespaceUri $script:acNamespace
    if ($isControlledAttachmentLink -or $Node.get_Name() -ceq 'ac:link') {
        if (-not $isControlledAttachmentLink) { Add-UnsupportedNode -Node $Node -Code 'UnsupportedNode' -Records $Unsupported; return }
        if ($Node.Attributes.Count -ne 0) { Add-UnsupportedNode -Node $Node -Code 'UnsupportedNode' -Records $Unsupported; return }
        $elements = @($Node.ChildNodes | Where-Object { $_.NodeType -eq [Xml.XmlNodeType]::Element })
        $other = @($Node.ChildNodes | Where-Object {
            $_.NodeType -notin @([Xml.XmlNodeType]::Element,[Xml.XmlNodeType]::Whitespace,[Xml.XmlNodeType]::SignificantWhitespace) -and
            -not ($_.NodeType -eq [Xml.XmlNodeType]::Text -and [string]::IsNullOrWhiteSpace([string]$_.Value))
        })
        $attachments = @($elements | Where-Object { Test-QualifiedStorageNode -Node $_ -LocalName 'attachment' -NamespaceUri $script:riNamespace })
        $bodies = @($elements | Where-Object { Test-QualifiedStorageNode -Node $_ -LocalName 'plain-text-link-body' -NamespaceUri $script:acNamespace })
        if ($other.Count -gt 0 -or $attachments.Count -ne 1 -or $bodies.Count -gt 1 -or
            $elements.Count -ne ($attachments.Count + $bodies.Count) -or
            ($bodies.Count -eq 1 -and ($bodies[0].Attributes.Count -ne 0 -or -not (Test-StorageTextContent -Node $bodies[0])))) {
            Add-UnsupportedNode -Node $Node -Code 'UnsupportedNode' -Records $Unsupported
            return
        }
        $attachment = $attachments[0]
        $filename = Get-QualifiedStorageAttribute -Node $attachment -LocalName 'filename' -NamespaceUri $script:riNamespace
        if ($attachment.Attributes.Count -ne 1 -or -not (Test-SafeAttachmentFilename -Filename $filename) -or
            $attachment.ChildNodes.Count -ne 0) {
            Add-UnsupportedNode -Node $Node -Code 'UnsupportedNode' -Records $Unsupported
        }
        return
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
        if ($Node.ParentNode.get_Name() -cnotin @('ac:image','ac:link')) { Add-UnsupportedNode -Node $Node -Code 'UnsupportedAssetReference' -Records $Unsupported; return }
        $filename = Get-NodeAttribute -Node $Node -Name 'ri:filename'
        if (-not (Test-SafeAttachmentFilename -Filename $filename)) {
            Add-UnsupportedNode -Node $Node -Code 'UnsafeAssetName' -Records $Unsupported
            return
        }
    }
    if ($Node.get_Name() -ceq 'ac:image') {
        $imageTitle = Get-NodeAttribute -Node $Node -Name 'ac:title'
        if ($null -ne $imageTitle -and $imageTitle -match '[\x00-\x1f\x7f]') {
            Add-UnsupportedNode -Node $Node -Code 'UnsupportedImageTitle' -Records $Unsupported
            return
        }
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
    foreach ($symbol in @('*', '_', '[', ']', '<', '>', '`', '#')) { $value = $value.Replace($symbol, $slash + $symbol) }
    if ($TableCell) { $value = $value.Replace('|', $slash + '|') }
    return $value
}

function Escape-MarkdownImageTitle {
    param([string] $Title)
    $slash = [string] [char] 92
    return $Title.Replace($slash, $slash + $slash).Replace('"', $slash + '"')
}

function Convert-ImageMarkdown {
    param([Xml.XmlNode] $Node, [System.Collections.Generic.List[object]] $Assets)
    $attachment = @($Node.ChildNodes | Where-Object { $_.get_Name() -ceq 'ri:attachment' })[0]
    $filename = Get-NodeAttribute -Node $attachment -Name 'ri:filename'
    $Assets.Add([pscustomobject]@{ filename = $filename; sourceLocation = Get-NodeLocation -Node $Node })
    $alt = Get-NodeAttribute -Node $Node -Name 'ac:alt'
    if ([string]::IsNullOrWhiteSpace($alt)) { $alt = $filename }
    $title = Get-NodeAttribute -Node $Node -Name 'ac:title'
    $escapedName = [Uri]::EscapeDataString($filename)
    $titleSuffix = if ($null -ne $title) { ' "' + (Escape-MarkdownImageTitle -Title $title) + '"' } else { '' }
    return "![$(Escape-MarkdownText -Text $alt)](assets/$escapedName$titleSuffix)"
}

function Convert-AttachmentLinkMarkdown {
    param([Xml.XmlNode] $Node, [System.Collections.Generic.List[object]] $Assets, [switch] $TableCell)
    $attachment = @($Node.ChildNodes | Where-Object { Test-QualifiedStorageNode -Node $_ -LocalName 'attachment' -NamespaceUri $script:riNamespace })[0]
    $filename = Get-QualifiedStorageAttribute -Node $attachment -LocalName 'filename' -NamespaceUri $script:riNamespace
    $body = @($Node.ChildNodes | Where-Object { Test-QualifiedStorageNode -Node $_ -LocalName 'plain-text-link-body' -NamespaceUri $script:acNamespace })
    $label = if ($body.Count -eq 1) { [string]$body[0].InnerText } else { $filename }
    $Assets.Add([pscustomobject]@{ filename = $filename; sourceLocation = Get-NodeLocation -Node $Node })
    return "[$(Escape-MarkdownText -Text $label -TableCell:$TableCell)](assets/$([Uri]::EscapeDataString($filename)))"
}

function Convert-StorageMacroMarkdown {
    param([Xml.XmlNode] $Node, [System.Collections.Generic.List[object]] $Assets)
    $name = Get-QualifiedStorageAttribute -Node $Node -LocalName 'name' -NamespaceUri $script:acNamespace
    if ($name -ceq 'mermaid-cloud') {
        $filenameNode = @($Node.ChildNodes | Where-Object { Test-QualifiedStorageNode -Node $_ -LocalName 'parameter' -NamespaceUri $script:acNamespace } | Where-Object { (Get-QualifiedStorageAttribute -Node $_ -LocalName 'name' -NamespaceUri $script:acNamespace) -ceq 'filename' })[0]
        $revisionNode = @($Node.ChildNodes | Where-Object { Test-QualifiedStorageNode -Node $_ -LocalName 'parameter' -NamespaceUri $script:acNamespace } | Where-Object { (Get-QualifiedStorageAttribute -Node $_ -LocalName 'name' -NamespaceUri $script:acNamespace) -ceq 'revision' })[0]
        $filename = [string]$filenameNode.InnerText
        $Assets.Add([pscustomobject]@{ filename = $filename; sourceLocation = Get-NodeLocation -Node $Node; revision = [int]$revisionNode.InnerText })
        return "![mermaid-cloud](assets/$([Uri]::EscapeDataString($filename)))`n`n"
    }
    $languageNode = @($Node.ChildNodes | Where-Object { Test-QualifiedStorageNode -Node $_ -LocalName 'parameter' -NamespaceUri $script:acNamespace })
    $language = if ($languageNode.Count -eq 1) { [string]$languageNode[0].InnerText } else { '' }
    $body = [string](@($Node.ChildNodes | Where-Object { Test-QualifiedStorageNode -Node $_ -LocalName 'plain-text-body' -NamespaceUri $script:acNamespace })[0].InnerText)
    $fence = '```'
    while ($body.Contains($fence)) { $fence += '`' }
    $opening = if ($language -ceq '') { "$fence {data-confluence-macro=code}" } else { "$fence$language {data-confluence-macro=code}" }
    return $opening + "`n" + $body + "`n" + $fence + "`n`n"
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
        if (Test-QualifiedStorageNode -Node $child -LocalName 'link' -NamespaceUri $script:acNamespace) {
            $null = $builder.Append((Convert-AttachmentLinkMarkdown -Node $child -Assets $Assets -TableCell:$TableCell))
            continue
        }
        $value = if ($child.get_Name() -ceq 'code') { $child.InnerText } elseif ($child.get_Name() -in @('ac:image','ac:link')) { '' } else { Convert-InlineChildren -Node $child -Assets $Assets -TableCell:$TableCell }
        switch ($child.get_Name()) {
            'strong' { $null = $builder.Append("**$value**"); break }
            'em' { $null = $builder.Append("*$value*"); break }
            'code' {
                $ticks = '`'
                while ($value.Contains($ticks)) { $ticks += '`' }
                $hasBothEdgeSpaces = $value.Length -ge 2 -and $value[0] -eq [char] 32 -and $value[$value.Length - 1] -eq [char] 32
                $hasEdgeBacktick = $value.Length -gt 0 -and ($value[0] -eq [char] 96 -or $value[$value.Length - 1] -eq [char] 96)
                $isOnlySpaces = $value.Length -gt 0 -and [regex]::IsMatch($value, '^[ ]+$')
                $codeContent = if (-not $isOnlySpaces -and ($hasBothEdgeSpaces -or $hasEdgeBacktick)) { ' ' + $value + ' ' } else { $value }
                $null = $builder.Append("$ticks$codeContent$ticks")
                break
            }
            'a' {
                $href = Get-NodeAttribute -Node $child -Name 'href'
                if ($href.Contains('(') -or $href.Contains(')')) {
                    $null = $builder.Append("[$value](<$href>)")
                } else {
                    $null = $builder.Append("[$value]($href)")
                }
                break
            }
            'br' {
                if ($Node.get_Name() -in @('td','th','h1','h2','h3','h4','h5','h6')) { $null = $builder.Append('<br>') }
                else { $null = $builder.Append(('  ' + [string][char]10)) }
                break
            }
            'ac:image' { $null = $builder.Append((Convert-ImageMarkdown -Node $child -Assets $Assets)); break }
            default { $null = $builder.Append($value); break }
        }
    }
    return $builder.ToString()
}

function Convert-StorageBlock {
    param([Xml.XmlNode] $Node, [System.Collections.Generic.List[object]] $Assets)
    if (Test-QualifiedStorageNode -Node $Node -LocalName 'structured-macro' -NamespaceUri $script:acNamespace) {
        return Convert-StorageMacroMarkdown -Node $Node -Assets $Assets
    }
    switch -Regex ($Node.get_Name()) {
        '^h[1-6]$' {
            $level = [int] ([string] $Node.get_Name()).Substring(1)
            return ('#' * $level) + ' ' + (Convert-InlineChildren -Node $Node -Assets $Assets).Trim() + "`n`n"
        }
        '^p$' {
            $paragraph = (Convert-InlineChildren -Node $Node -Assets $Assets).Trim()
            $slash = [string] [char] 92
            $paragraph = [regex]::Replace($paragraph, '(?m)^( {0,3})([-+])(?= )', ('$1' + $slash + '$2'))
            $paragraph = [regex]::Replace($paragraph, '(?m)^( {0,3})(\d+)\.(?= )', ('$1$2' + $slash + '.'))
            $paragraph = [regex]::Replace($paragraph, '(?m)^( {0,3})(\d+)\)(?=[ \t])', ('$1$2' + $slash + ')'))
            $paragraph = [regex]::Replace(
                $paragraph,
                '(?m)^( {0,3})(?=(?:-{1,}[ \t]*|={1,}[ \t]*|(?:-[ \t]*){3,}|(?:\*[ \t]*){3,}|(?:_[ \t]*){3,})$)([-=_*])',
                ('$1' + $slash + '$2')
            )
            return $paragraph + "`n`n"
        }
        '^(ul|ol)$' {
            $lines = [System.Collections.Generic.List[string]]::new()
            $number = 1
            foreach ($item in $Node.ChildNodes | Where-Object { $_.get_Name() -ceq 'li' }) {
                $marker = if ($Node.get_Name() -ceq 'ul') { '- ' } else { "$number. " }
                $lines.Add($marker + (Convert-InlineChildren -Node $item -Assets $Assets).Trim())
                $number++
            }
            return ($lines -join ('' + ([string][char]10) + '')) + ('' + ([string][char]10) + '' + ([string][char]10) + '')
        }
        '^pre$' {
            $code = $Node.InnerText
            $fence = '```'
            while ($code.Contains($fence)) { $fence += '`' }
            $lf = [string][char]10
            return $fence + $lf + $code + $lf + $fence + $lf + $lf
        }
        '^table$' {
            $rows = @($Node.SelectNodes('.//tr'))
            if ($rows.Count -eq 0) { return ('' + ([string][char]10) + '') }
            $rendered = [System.Collections.Generic.List[string]]::new()
            $firstCells = @($rows[0].ChildNodes | Where-Object { $_.get_Name() -in @('th', 'td') })
            $header = @($firstCells | ForEach-Object { (Convert-InlineChildren -Node $_ -Assets $Assets -TableCell).Trim() })
            $rendered.Add('| ' + ($header -join ' | ') + ' |')
            $rendered.Add('| ' + (@($header | ForEach-Object { '---' }) -join ' | ') + ' |')
            foreach ($row in $rows | Select-Object -Skip 1) {
                $cells = @($row.ChildNodes | Where-Object { $_.get_Name() -in @('th', 'td') })
                $rendered.Add('| ' + (@($cells | ForEach-Object { (Convert-InlineChildren -Node $_ -Assets $Assets -TableCell).Trim() }) -join ' | ') + ' |')
            }
            return ($rendered -join ('' + ([string][char]10) + '')) + ('' + ([string][char]10) + '' + ([string][char]10) + '')
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
    $wrapped = ('<root xmlns:ac="' + [string]($script:acNamespace) + '" xmlns:ri="' + [string]($script:riNamespace) + '">' + [string]($Storage) + '</root>')
    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $settings.MaxCharactersInDocument = 4MB
    $settings.MaxCharactersFromEntities = 0
    $depthExceeded = $false
    try {
        $stringReader = [IO.StringReader]::new($wrapped)
        $reader = [Xml.XmlReader]::Create($stringReader, $settings)
        try {
            while ($reader.Read()) {
                if ($reader.NodeType -eq [Xml.XmlNodeType]::Element -and $reader.Depth -gt 128) { $depthExceeded = $true }
            }
        }
        finally { $reader.Dispose(); $stringReader.Dispose() }
    } catch {
        return New-StorageResult -Status 'invalid' -ReasonCodes @('StorageXmlInvalid') -Markdown '' -SourceBlocks @() -Assets @() -Unsupported @() -BodySha256 $bodyHash
    }

    if ($depthExceeded) {
        $location = '/root[1]'
        $blockHash = Get-ProjectionHash -Text ([string]($PageId) + ':' + [string]($PageVersion) + ':whole-fragment:' + [string]($bodyHash))
        $block = [pscustomobject]@{
            id = ('BLOCK-' + $blockHash.Substring(0, 20)); location = $location
            sourceSha256 = $bodyHash; sourceType = 'whole-storage'; supported = $false
        }
        $finding = [pscustomobject]@{ code = 'StorageDepthExceeded'; location = $location; sourceXml = ''; sourceSha256 = $bodyHash }
        return New-StorageResult -Status 'unsupported' -ReasonCodes @('StorageDepthExceeded') -Markdown '' `
            -SourceBlocks @($block) -Assets @() -Unsupported @($finding) -BodySha256 $bodyHash
    }

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
        $isControlledMacro = $node.NodeType -eq [Xml.XmlNodeType]::Element -and
            (Test-QualifiedStorageNode -Node $node -LocalName 'structured-macro' -NamespaceUri $script:acNamespace)
        if ($node.NodeType -eq [Xml.XmlNodeType]::Element -and
            -not $script:convertibleRootNodes.Contains($node.get_Name()) -and
            -not $isControlledMacro -and $node.get_Name() -cne 'ac:structured-macro') {
            Add-UnsupportedNode -Node $node -Code 'UnsupportedNode' -Records $unsupported
        } else {
            Inspect-StorageNode -Node $node -Unsupported $unsupported
        }
        $location = Get-NodeLocation -Node $node
        $nodeHash = Get-ProjectionHash -Text $node.OuterXml
        $blockId = Get-ProjectionHash -Text ([string]($PageId) + ':' + [string]($PageVersion) + ':' + [string]($ordinal) + ':' + [string]($nodeHash))
        $blocks.Add([pscustomobject]@{ id = ('BLOCK-' + [string]($($blockId.Substring(0, 20)))); location = $location; sourceSha256 = $nodeHash; sourceType = $node.get_Name(); supported = ($unsupported.Count -eq $beforeUnsupported) })
        if ($unsupported.Count -eq $beforeUnsupported -and $node.NodeType -eq [Xml.XmlNodeType]::Element) {
            $null = $markdown.Append((Convert-StorageBlock -Node $node -Assets $assets))
        }
    }
    $output = $markdown.ToString().TrimEnd() + ('' + ([string][char]10) + '')
    $reasonCodes = @($unsupported | ForEach-Object code | Select-Object -Unique)
    $status = if ($unsupported.Count -eq 0) { 'supported' } else { 'unsupported' }
    return New-StorageResult -Status $status -ReasonCodes $reasonCodes -Markdown $output -SourceBlocks $blocks.ToArray() -Assets $assets.ToArray() -Unsupported $unsupported.ToArray() -BodySha256 $bodyHash
}

Export-ModuleMember -Function ConvertFrom-ConfluenceStorage
