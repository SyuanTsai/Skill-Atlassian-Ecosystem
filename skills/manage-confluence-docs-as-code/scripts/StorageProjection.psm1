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
            'br' { $null = $builder.Append([string][char]10); break }
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
        '^p$' {
            $paragraph = (Convert-InlineChildren -Node $Node -Assets $Assets).Trim()
            $slash = [string] [char] 92
            $paragraph = [regex]::Replace($paragraph, '(?m)^( {0,3})([-+])(?= )', ('$1' + $slash + '$2'))
            $paragraph = [regex]::Replace($paragraph, '(?m)^( {0,3})(\d+)\.(?= )', ('$1$2' + $slash + '.'))
            $paragraph = [regex]::Replace($paragraph, '(?m)^( {0,3})(\d+)\)(?= )', ('$1$2' + $slash + ')'))
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
