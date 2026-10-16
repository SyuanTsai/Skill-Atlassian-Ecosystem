# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/StorageProjection.psm1'
$markdownModulePath = Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/MarkdownProjection.psm1'

function Invoke-StorageConversion {
    param([Parameter(Mandatory)][string] $Storage)
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) { throw 'StorageProjection production module is missing.' }
    Import-Module -Name $modulePath -Force
    return ConvertFrom-ConfluenceStorage -Storage $Storage -PageId '101' -PageVersion 3
}

function Invoke-StorageTraversalProbe {
    param([Parameter(Mandatory)][string[]] $Storage)
    $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
    $probeRoot = Join-Path $tempParent "syp171-storage-depth-$([Guid]::NewGuid().ToString('N'))"
    $moduleName = 'StorageProjection'
    $tracePath = Join-Path $probeRoot 'traversal-events.txt'
    New-Item -ItemType Directory -Path $probeRoot -Force | Out-Null
    try {
        $probeModulePath = Join-Path $probeRoot 'StorageProjection.psm1'
        $assetsModulePath = Join-Path $probeRoot 'ConfluenceAssets.psm1'
        $transportModulePath = Join-Path $probeRoot 'ConfluenceTransport.psm1'
        Copy-Item -LiteralPath $modulePath -Destination $probeModulePath
        $scriptsRoot = Split-Path -Parent $modulePath
        Copy-Item -LiteralPath (Join-Path $scriptsRoot 'ConfluenceAssets.psm1') -Destination $assetsModulePath
        Copy-Item -LiteralPath (Join-Path $scriptsRoot 'ConfluenceTransport.psm1') -Destination $transportModulePath
        $source = [IO.File]::ReadAllText($probeModulePath)
        $traceLineTemplate = '    if(-not [string]::IsNullOrWhiteSpace($env:SYP171_STORAGE_TRACE)){[IO.File]::AppendAllText($env:SYP171_STORAGE_TRACE,''__EVENT__''+[string][char]10)}'
        $newline = [Environment]::NewLine
        $outerXmlTrace = $traceLineTemplate.Replace('__EVENT__', 'OuterXml')
        $outerXmlHelper = @(
            'function Write-StorageProbeOuterXml {'
            '    param([Xml.XmlNode] $Node)'
            $outerXmlTrace
            '    return $Node.OuterXml'
            '}'
        ) -join $newline
        $patches = @(
            @{ needle = 'function Get-NodeLocation {' + $newline + '    param([Xml.XmlNode] $Node)'; event = 'GetNodeLocation' },
            @{ needle = 'function Inspect-StorageNode {' + $newline + '    param([Xml.XmlNode] $Node, [System.Collections.Generic.List[object]] $Unsupported)'; event = 'InspectStorageNode' },
            @{ needle = 'function Convert-InlineChildren {' + $newline + '    param([Xml.XmlNode] $Node, [System.Collections.Generic.List[object]] $Assets, [switch] $TableCell)'; event = 'ConvertInlineChildren' },
            @{ needle = 'function Convert-StorageBlock {' + $newline + '    param([Xml.XmlNode] $Node, [System.Collections.Generic.List[object]] $Assets)'; event = 'ConvertStorageBlock' },
            @{ needle = 'function Convert-ImageMarkdown {' + $newline + '    param([Xml.XmlNode] $Node, [System.Collections.Generic.List[object]] $Assets)'; event = 'ConvertImageMarkdown' }
        )
        foreach ($patch in $patches) {
            $first = $source.IndexOf($patch.needle, [StringComparison]::Ordinal)
            $second = if ($first -ge 0) { $source.IndexOf($patch.needle, $first + $patch.needle.Length, [StringComparison]::Ordinal) } else { -1 }
            if ($first -lt 0 -or $second -ge 0) {
                throw "Could not uniquely instrument $($patch.event)."
            }
            $traceLine = $traceLineTemplate.Replace('__EVENT__', [string] $patch.event)
            $replacement = $patch.needle + [Environment]::NewLine + $traceLine
            $source = $source.Substring(0, $first) + $replacement + $source.Substring($first + $patch.needle.Length)
        }
        $extraPatches = @(
            @{ needle = '    $document = [Xml.XmlDocument]::new()'; event = 'XmlDocumentCreated' },
            @{ needle = '        try { $document.Load($reader) }'; event = 'XmlDocumentLoad' }
        )
        foreach ($patch in $extraPatches) {
            $first = $source.IndexOf($patch.needle, [StringComparison]::Ordinal)
            if ($first -lt 0) { throw "Could not instrument $($patch.event)." }
            $traceLine = $traceLineTemplate.Replace('__EVENT__', [string] $patch.event)
            $replacement = $traceLine + [Environment]::NewLine + $patch.needle
            $source = $source.Substring(0, $first) + $replacement + $source.Substring($first + $patch.needle.Length)
        }
        $source = $source.Replace('$Node.OuterXml', '(Write-StorageProbeOuterXml -Node $Node)')
        $source = $source.Replace('$node.OuterXml', '(Write-StorageProbeOuterXml -Node $node)')
        $source = $outerXmlHelper + $newline + $source
        [IO.File]::WriteAllText($probeModulePath, $source, [Text.UTF8Encoding]::new($false))
        $previousTracePath = $env:SYP171_STORAGE_TRACE
        $env:SYP171_STORAGE_TRACE = $tracePath
        try {
            Import-Module -Name $probeModulePath -Force
            $observations = [System.Collections.Generic.List[object]]::new()
            foreach ($storageItem in $Storage) {
                if (Test-Path -LiteralPath $tracePath -PathType Leaf) { Remove-Item -LiteralPath $tracePath -Force }
                $result = ConvertFrom-ConfluenceStorage -Storage $storageItem -PageId '101' -PageVersion 3
                $events = if (Test-Path -LiteralPath $tracePath -PathType Leaf) { @([IO.File]::ReadAllLines($tracePath)) } else { @() }
                $observations.Add([pscustomobject]@{ result = $result; events = $events })
            }
            return @($observations.ToArray())
        } finally {
            $env:SYP171_STORAGE_TRACE = $previousTracePath
            Remove-Module -Name $moduleName -Force -ErrorAction SilentlyContinue
        }
    } finally {
        $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $probeRoot).Path)
        if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\', '/') -cne $tempParent -or
            [IO.Path]::GetFileName($resolved) -cnotmatch '^syp171-storage-depth-[a-f0-9]{32}$') {
            throw 'Storage traversal probe escaped its unique temporary directory.'
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}

}

Describe 'SYP-171 storage projection completeness' {
    # Scenario: SYP171-SCN-001 and SYP171-SCN-009; a synthetic page contains supported nodes and an attached image.
    # Purpose: Candidate bytes, source blocks, attachment identity and rendering must be stable without inventing requirements.
    It 'UnitT10_preserves_supported_Chinese_code_table_link_and_attachment' {
        $storage = @'
<h2>臺灣正體 🧪</h2>
<p>需求原文 <strong>重點</strong> 與 <a href="https://example.invalid/doc">來源</a></p>
<ul><li>第一項</li><li>第二項</li></ul>
<pre><code>line 1
  line 2 &lt;x&gt;</code></pre>
<table><tbody><tr><th>欄位</th><th>值</th></tr><tr><td>A</td><td>甲</td></tr></tbody></table>
<ac:image><ri:attachment ri:filename="diagram.png" /></ac:image>
'@
        $first = Invoke-StorageConversion -Storage $storage
        $second = Invoke-StorageConversion -Storage $storage
        $first.status | Should -Be 'supported'
        $first.markdown | Should -Match '臺灣正體 🧪'
        $first.markdown | Should -Match '  line 2 <x>'
        $first.markdown | Should -Match '\| 欄位 \| 值 \|'
        @($first.assets).Count | Should -Be 1
        $first.assets[0].filename | Should -Be 'diagram.png'
        @($first.sourceBlocks).Count | Should -BeGreaterThan 4
        $second.markdown | Should -Be $first.markdown
        $second.bodySha256 | Should -Be $first.bodySha256
    }

    # Scenario: SYP171-SCN-009; ordinary text contains Markdown metacharacters and one literal backslash.
    # Purpose: Escaping must preserve displayed characters without introducing extra slash bytes.
    It 'UnitT15_escapes_Markdown_metacharacters_once' {
        $result = Invoke-StorageConversion -Storage '<p>literal * [ ] &lt;tag&gt; \</p>'
        $result.status | Should -Be 'supported'
        $result.markdown.Trim() | Should -Be 'literal \* \[ \] \<tag\> \\'
    }

    # Scenario: SYP171-SCN-009; nested emphasis appears directly and through another inline node between supported blocks.
    # Purpose: Preserve original node evidence and omit only unsupported source blocks while retaining supported emphasis combinations.
    It 'UnitT17_marks_nested_emphasis_unsupported_without_dropping_other_blocks' {
        Import-Module -Name $markdownModulePath -Force
        $storage = '<p>lead</p><p><em>outer direct <em>nested-direct</em> tail</em></p><p>middle</p><p><em>outer via strong <strong>middle <em>nested-through-strong</em></strong> tail</em></p><p><em>single emphasis</em></p><p><strong>bold <em>inside bold</em></strong></p><p><em>italic <strong>inside italic</strong></em></p><p>tail</p>'
        $first = Invoke-StorageConversion -Storage $storage
        $second = Invoke-StorageConversion -Storage $storage
        $expectedBodySha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($storage))).ToLowerInvariant()
        $records = @($first.unsupported)
        $expectedLocations = @('/root[1]/p[2]/em[1]/em[1]', '/root[1]/p[4]/em[1]/strong[1]/em[1]')
        $sourceRecordsValid = $records.Count -eq 2
        if ($sourceRecordsValid) {
            for ($index = 0; $index -lt $records.Count; $index++) {
                $sourceSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes([string]$records[$index].sourceXml))).ToLowerInvariant()
                $expectedSource = if ($index -eq 0) { '<em>nested-direct</em>' } else { '<em>nested-through-strong</em>' }
                $sourceRecordsValid = $sourceRecordsValid -and $records[$index].code -ceq 'NestedEmphasisUnsupported' -and
                    $records[$index].location -ceq $expectedLocations[$index] -and
                    $records[$index].sourceXml -ceq $expectedSource -and $records[$index].sourceSha256 -ceq $sourceSha
            }
        }
        $expectedBlockSupport = 'True,False,True,False,True,True,True,True'
        $actualBlockSupport = (@($first.sourceBlocks | ForEach-Object { [bool]$_.supported }) -join ',')
        $nestedTextOmitted = -not $first.markdown.Contains('outer direct', [StringComparison]::Ordinal) -and
            -not $first.markdown.Contains('nested-direct', [StringComparison]::Ordinal) -and
            -not $first.markdown.Contains('nested-through-strong', [StringComparison]::Ordinal)
        $supportedText = @('lead', 'middle', 'single emphasis', 'inside bold', 'inside italic', 'tail')
        $supportedTextRetained = @($supportedText | Where-Object { -not $first.markdown.Contains($_, [StringComparison]::Ordinal) }).Count -eq 0
        $renderedDom = [xml]('<root>' + (ConvertFrom-Markdown -InputObject $first.markdown).Html + '</root>')
        $renderedControlsValid = $renderedDom.SelectNodes('/root/p/em').Count -eq 2 -and
            $renderedDom.SelectNodes('/root/p/strong/em').Count -eq 1 -and
            $renderedDom.SelectNodes('/root/p/em/strong').Count -eq 1 -and
            $renderedDom.SelectSingleNode('/root/p/strong/em').InnerText -ceq 'inside bold' -and
            $renderedDom.SelectSingleNode('/root/p/em/strong').InnerText -ceq 'inside italic'
        $storageProjection = ConvertTo-ConfluenceMarkdownStorage -Markdown $first.markdown -Root $repositoryRoot -SourcePath 'docs/unrelated.md' -ProjectionId 'nested-emphasis'
        $storageDom = [xml]('<root>' + $storageProjection.storage + '</root>')
        $storageControlsValid = $storageProjection.status -ceq 'supported' -and
            $storageDom.SelectNodes('/root/p/em').Count -eq 2 -and
            $storageDom.SelectNodes('/root/p/strong/em').Count -eq 1 -and
            $storageDom.SelectNodes('/root/p/em/strong').Count -eq 1 -and
            $storageDom.SelectSingleNode('/root/p/strong/em').InnerText -ceq 'inside bold' -and
            $storageDom.SelectSingleNode('/root/p/em/strong').InnerText -ceq 'inside italic'
        $firstEvidence = ConvertTo-Json -InputObject @($first.unsupported | ForEach-Object { [ordered]@{ code = $_.code; location = $_.location; sourceXml = $_.sourceXml; sourceSha256 = $_.sourceSha256 } }) -Compress -Depth 5
        $secondEvidence = ConvertTo-Json -InputObject @($second.unsupported | ForEach-Object { [ordered]@{ code = $_.code; location = $_.location; sourceXml = $_.sourceXml; sourceSha256 = $_.sourceSha256 } }) -Compress -Depth 5
        $first.status | Should -Be 'unsupported'
        @($first.reasonCodes) | Should -Contain 'NestedEmphasisUnsupported'
        @($first.sourceBlocks).Count | Should -Be 8
        $actualBlockSupport | Should -BeExactly $expectedBlockSupport
        $first.bodySha256 | Should -BeExactly $expectedBodySha
        $sourceRecordsValid | Should -BeTrue
        $nestedTextOmitted | Should -BeTrue
        $supportedTextRetained | Should -BeTrue
        $renderedControlsValid | Should -BeTrue
        $storageControlsValid | Should -BeTrue
        $firstEvidence | Should -BeExactly $secondEvidence
        $first.markdown | Should -BeExactly $second.markdown
    }

    # Scenario: SYP171-SCN-009; inline code includes an asterisk that has no Markdown meaning inside code.
    # Purpose: The source code token must remain exact instead of inheriting paragraph escaping.
    It 'UnitT18_preserves_inline_code_characters' {
        $result = Invoke-StorageConversion -Storage '<p>use <code>a*b</code></p>'
        $result.status | Should -Be 'supported'
        $result.markdown.Trim() | Should -Be 'use `a*b`'
    }

    # Scenario: SYP171-SCN-009; inline code contains delimiter-sensitive edge spaces or backticks.
    # Purpose: Preserve code characters exactly through both real Markdown DOM renderers without changing fenced-code behavior.
    It 'UnitT19_roundtrips_inline_code_edge_spaces_and_backticks' {
        Import-Module -Name $markdownModulePath -Force
        $cases = @(
            [pscustomobject]@{ name = 'ordinary'; text = 'plain value' },
            [pscustomobject]@{ name = 'one leading space'; text = ' leading' },
            [pscustomobject]@{ name = 'one trailing space'; text = 'trailing ' },
            [pscustomobject]@{ name = 'both edges multiple spaces'; text = '  both edges  ' },
            [pscustomobject]@{ name = 'all spaces'; text = '   ' },
            [pscustomobject]@{ name = 'internal backtick'; text = 'inside`tick' },
            [pscustomobject]@{ name = 'leading backtick'; text = '`leading' },
            [pscustomobject]@{ name = 'trailing backtick'; text = 'trailing`' },
            [pscustomobject]@{ name = 'both edge backticks'; text = '`both`' }
        )
        $failures = [System.Collections.Generic.List[object]]::new()
        $caseIndex = 0
        foreach ($case in $cases) {
            try {
                $caseIndex++
                $captured = Invoke-StorageConversion -Storage ('<p><code>' + $case.text + '</code></p>')
                $renderedDom = [Xml.XmlDocument]::new()
                $renderedDom.PreserveWhitespace = $true
                $renderedDom.LoadXml('<root>' + (ConvertFrom-Markdown -InputObject $captured.markdown).Html + '</root>')
                $renderedCodes = @($renderedDom.SelectNodes('/root/p/code'))
                $projected = ConvertTo-ConfluenceMarkdownStorage -Markdown $captured.markdown -Root $repositoryRoot -SourcePath 'docs/unrelated.md' -ProjectionId ('inline-code-case-' + $caseIndex)
                $storageDom = [Xml.XmlDocument]::new()
                $storageDom.PreserveWhitespace = $true
                $storageDom.LoadXml('<root>' + $projected.storage + '</root>')
                $storedCodes = @($storageDom.SelectNodes('/root/p/code'))
                if ($captured.status -cne 'supported' -or $projected.status -cne 'supported' -or
                    $renderedCodes.Count -ne 1 -or $storedCodes.Count -ne 1 -or
                    $renderedCodes[0].InnerText -cne $case.text -or $storedCodes[0].InnerText -cne $case.text) {
                    $failures.Add([ordered]@{
                        name = $case.name; sourceCode = $case.text; candidateMarkdown = $captured.markdown
                        captureStatus = $captured.status; renderedCount = $renderedCodes.Count
                        renderedValue = if ($renderedCodes.Count -eq 1) { $renderedCodes[0].InnerText } else { $null }
                        projectionStatus = $projected.status; storageCodeCount = $storedCodes.Count
                        storageValue = if ($storedCodes.Count -eq 1) { $storedCodes[0].InnerText } else { $null }
                    })
                }
            } catch {
                $failures.Add([ordered]@{ name = $case.name; sourceCode = $case.text; errorType = $_.Exception.GetType().FullName; error = $_.Exception.Message })
            }
        }
        $preCode = '  fenced ``` value  '
        $fencedExpected = $preCode + [string][char] 10
        try {
            $pre = Invoke-StorageConversion -Storage ('<pre><code>' + $preCode + '</code></pre>')
            $preRenderedDom = [Xml.XmlDocument]::new()
            $preRenderedDom.PreserveWhitespace = $true
            $preRenderedDom.LoadXml('<root>' + (ConvertFrom-Markdown -InputObject $pre.markdown).Html + '</root>')
            $preRenderedCodes = @($preRenderedDom.SelectNodes('/root/pre/code'))
            $preProjection = ConvertTo-ConfluenceMarkdownStorage -Markdown $pre.markdown -Root $repositoryRoot -SourcePath 'docs/unrelated.md' -ProjectionId 'fenced-code-control'
            $preStorageDom = [Xml.XmlDocument]::new()
            $preStorageDom.PreserveWhitespace = $true
            $preStorageDom.LoadXml('<root>' + $preProjection.storage + '</root>')
            $preStoredCodes = @($preStorageDom.SelectNodes('/root/pre/code'))
            if ($pre.status -cne 'supported' -or $preProjection.status -cne 'supported' -or
                $preRenderedCodes.Count -ne 1 -or $preStoredCodes.Count -ne 1 -or
                $preRenderedCodes[0].InnerText -cne $fencedExpected -or $preStoredCodes[0].InnerText -cne $fencedExpected) {
                $failures.Add([ordered]@{
                    name = 'fenced code control'; sourceCode = $preCode; expectedCode = $fencedExpected
                    candidateMarkdown = $pre.markdown; captureStatus = $pre.status; renderedCount = $preRenderedCodes.Count
                    renderedValue = if ($preRenderedCodes.Count -eq 1) { $preRenderedCodes[0].InnerText } else { $null }
                    renderedLength = if ($preRenderedCodes.Count -eq 1) { $preRenderedCodes[0].InnerText.Length } else { $null }
                    projectionStatus = $preProjection.status; storageCodeCount = $preStoredCodes.Count
                    storageValue = if ($preStoredCodes.Count -eq 1) { $preStoredCodes[0].InnerText } else { $null }
                    storageLength = if ($preStoredCodes.Count -eq 1) { $preStoredCodes[0].InnerText.Length } else { $null }
                })
            }
        } catch {
            $failures.Add([ordered]@{ name = 'fenced code control'; sourceCode = $preCode; errorType = $_.Exception.GetType().FullName; error = $_.Exception.Message })
        }
        $failures.Count | Should -Be 0 -Because (ConvertTo-Json -InputObject @($failures.ToArray()) -Compress -Depth 8)
    }

    # Scenario: SYP171-SCN-009; a structured macro sits between ordinary paragraphs.
    # Purpose: Its source XML and location remain reviewable while the affected page is not publishable.
    It 'UnitT20_reports_macro_without_dropping_original_node' {
        $storage = '<p>before</p><ac:structured-macro ac:name="toc"><ac:parameter ac:name="style">disc</ac:parameter></ac:structured-macro><p>after</p>'
        $result = Invoke-StorageConversion -Storage $storage
        $result.status | Should -Be 'unsupported'
        @($result.reasonCodes) | Should -Contain 'UnsupportedMacro'
        @($result.unsupported).Count | Should -Be 1
        $result.unsupported[0].sourceXml | Should -Match 'ac:structured-macro'
        $result.unsupported[0].location | Should -Not -BeNullOrEmpty
    }

    # Scenario: SYP171-SCN-009; storage attempts to declare an external entity.
    # Purpose: Parsing must not resolve DTDs or access local/external resources.
    It 'UnitT30_rejects_DTD_and_external_entity' {
        $storage = '<!DOCTYPE test [<!ENTITY xxe SYSTEM "file:///C:/private.txt">]><p>&xxe;</p>'
        $result = Invoke-StorageConversion -Storage $storage
        $result.status | Should -Be 'invalid'
        @($result.reasonCodes) | Should -Contain 'DtdForbidden'
        @($result.sourceBlocks).Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-009; a source link uses an executable URL scheme.
    # Purpose: No unsafe link is rendered or silently changed into a safe but false link.
    It 'UnitT40_rejects_unsafe_URL_with_source_location' {
        $storage = '<p><a href="javascript:alert(1)">click</a></p>'
        $result = Invoke-StorageConversion -Storage $storage
        $result.status | Should -Be 'unsupported'
        @($result.reasonCodes) | Should -Contain 'UnsafeUrl'
        @($result.unsupported).Count | Should -Be 1
        $result.unsupported[0].sourceXml | Should -Match 'javascript:'
    }

    # Scenario: SYP171-SCN-009; safe hrefs contain balanced/nested parentheses or their literal percent-encoded spellings.
    # Purpose: Preserve exact href spelling and link text through the existing native HTML and storage DOM stages.
    It 'UnitT45_roundtrips_parenthesized_href_spellings' {
        Import-Module -Name $markdownModulePath -Force
        $cases = @(
            [pscustomobject]@{ name = 'balanced parentheses'; href = 'https://example.invalid/path_(one)'; label = 'Balanced label' },
            [pscustomobject]@{ name = 'nested parentheses'; href = 'https://example.invalid/path_(one_(two))'; label = 'Nested label' },
            [pscustomobject]@{ name = 'percent-encoded parentheses'; href = 'https://example.invalid/path_%28one%29'; label = 'Encoded label' }
        )
        $failures = [System.Collections.Generic.List[object]]::new()
        foreach ($case in $cases) {
            try {
                $storage = '<p><a href="' + $case.href + '">' + $case.label + '</a></p>'
                $captured = Invoke-StorageConversion -Storage $storage
                $renderedDom = [xml]('<root>' + (ConvertFrom-Markdown -InputObject $captured.markdown).Html + '</root>')
                $projected = ConvertTo-ConfluenceMarkdownStorage -Markdown $captured.markdown -Root $repositoryRoot -SourcePath 'docs/unrelated.md' -ProjectionId 'href-parentheses'
                $storageDom = [xml]('<root>' + $projected.storage + '</root>')
                $renderedAnchors = @($renderedDom.SelectNodes('/root/p/a'))
                $storedAnchors = @($storageDom.SelectNodes('/root/p/a'))
                $renderedHref = if ($renderedAnchors.Count -eq 1) { [string]$renderedAnchors[0].GetAttribute('href') } else { $null }
                $storedHref = if ($storedAnchors.Count -eq 1) { [string]$storedAnchors[0].GetAttribute('href') } else { $null }
                $renderedLabel = if ($renderedAnchors.Count -eq 1) { $renderedAnchors[0].InnerText } else { $null }
                $storedLabel = if ($storedAnchors.Count -eq 1) { $storedAnchors[0].InnerText } else { $null }
                if ($captured.status -cne 'supported' -or @($captured.unsupported).Count -ne 0 -or
                    $projected.status -cne 'supported' -or $renderedAnchors.Count -ne 1 -or $storedAnchors.Count -ne 1 -or
                    $renderedHref -cne $case.href -or $storedHref -cne $case.href -or
                    $renderedLabel -cne $case.label -or $storedLabel -cne $case.label) {
                    $failures.Add([ordered]@{
                        name = $case.name; sourceHref = $case.href; sourceLabel = $case.label
                        captureStatus = $captured.status; unsupportedCount = @($captured.unsupported).Count; candidateMarkdown = $captured.markdown
                        renderedAnchorCount = $renderedAnchors.Count; renderedHref = $renderedHref; renderedLabel = $renderedLabel
                        projectionStatus = $projected.status; projectionReasons = @($projected.reasonCodes)
                        storageAnchorCount = $storedAnchors.Count; storedHref = $storedHref; storedLabel = $storedLabel
                    })
                }
            } catch {
                $failures.Add([ordered]@{ name = $case.name; sourceHref = $case.href; errorType = $_.Exception.GetType().FullName; error = $_.Exception.Message })
            }
        }
        $failures.Count | Should -Be 0 -Because (ConvertTo-Json -InputObject @($failures.ToArray()) -Compress -Depth 8)
    }

    # Scenario: SYP171-SCN-009; a safe-scheme href that needs angle-delimited Markdown contains an angle bracket or an actual newline.
    # Purpose: Preserve unsupported-node location, original source XML, and digest instead of corrupting an unrepresentable href.
    It 'UnitT46_preserves_evidence_for_unrepresentable_parenthesized_hrefs' {
        $newlineHref = 'https://example.invalid/path' + [string][char]10 + '_(x)'
        $cases = @(
            [pscustomobject]@{ name = 'angle bracket'; href = 'https://example.invalid/path_<one>_(x)'; storage = '<p><a href="https://example.invalid/path_&lt;one&gt;_(x)">Angle label</a></p>' },
            [pscustomobject]@{ name = 'actual newline'; href = $newlineHref; storage = '<p><a href="https://example.invalid/path&#10;_(x)">Newline label</a></p>' }
        )
        $failures = [System.Collections.Generic.List[object]]::new()
        foreach ($case in $cases) {
            $result = Invoke-StorageConversion -Storage $case.storage
            $records = @($result.unsupported)
            $record = if ($records.Count -eq 1) { $records[0] } else { $null }
            $sourceShaValid = $false
            $sourceHrefPreserved = $false
            if ($null -ne $record) {
                $expectedSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes([string]$record.sourceXml))).ToLowerInvariant()
                $sourceShaValid = [string]$record.sourceSha256 -ceq $expectedSha
                try {
                    $sourceNode = [xml]::new()
                    $sourceNode.LoadXml([string]$record.sourceXml)
                    $sourceHrefPreserved = $sourceNode.DocumentElement.GetAttribute('href') -ceq $case.href
                } catch { }
            }
            if ($result.status -cne 'unsupported' -or @($result.reasonCodes) -cnotcontains 'UnrepresentableHref' -or
                $records.Count -ne 1 -or $null -eq $record -or $record.code -cne 'UnrepresentableHref' -or
                $record.location -cne '/root[1]/p[1]/a[1]' -or $record.sourceXml -cnotmatch 'https://example\.invalid/path' -or
                $record.sourceSha256 -cnotmatch '^[a-f0-9]{64}$' -or -not $sourceShaValid -or -not $sourceHrefPreserved) {
                $failures.Add([ordered]@{
                    name = $case.name; status = $result.status; reasonCodes = @($result.reasonCodes)
                    unsupportedCount = $records.Count; code = if ($record) { $record.code } else { $null }
                    location = if ($record) { $record.location } else { $null }; sourceXml = if ($record) { $record.sourceXml } else { $null }
                    sourceSha256 = if ($record) { $record.sourceSha256 } else { $null }; sourceShaValid = $sourceShaValid
                    sourceHrefPreserved = $sourceHrefPreserved; expectedHref = $case.href
                    candidateMarkdown = $result.markdown
                })
            }
        }
        $failures.Count | Should -Be 0 -Because (ConvertTo-Json -InputObject @($failures.ToArray()) -Compress -Depth 8)
    }

    # Scenario: The native Markdown renderer emits a safe HTTPS anchor with a nonempty title.
    # Purpose: Refuse the enclosing storage block and preserve the anchor and parent digests instead of silently losing the title.
    It 'UnitT47_refuses_native_https_links_with_nonempty_titles_and_preserves_evidence' {
        Import-Module -Name $markdownModulePath -Force
        $nativeMarkdown = '[Titled HTTPS](https://docs.example.invalid/spec "Specification title")' + "`n`n" + 'Ordinary sibling content.'
        $nativeHtml = ConvertFrom-Markdown -InputObject $nativeMarkdown
        $nativeHtmlDocument = [Xml.XmlDocument]::new()
        $nativeHtmlDocument.LoadXml('<root>' + [string]$nativeHtml.Html + '</root>')
        $nativeAnchor = $nativeHtmlDocument.SelectSingleNode('/root/p[1]/a')
        $nativeAnchor | Should -Not -BeNullOrEmpty
        $nativeAnchor.GetAttribute('href') | Should -BeExactly 'https://docs.example.invalid/spec'
        $nativeAnchor.GetAttribute('title') | Should -BeExactly 'Specification title'

        $forward = ConvertTo-ConfluenceMarkdownStorage -Markdown $nativeMarkdown -Root $repositoryRoot `
            -SourcePath 'docs/unrelated.md' -ProjectionId 'native-link-title'
        $forward.status | Should -BeExactly 'supported'
        $forwardDocument = [Xml.XmlDocument]::new()
        $forwardDocument.PreserveWhitespace = $true
        $forwardDocument.LoadXml('<root>' + [string]$forward.storage + '</root>')
        $sourceAnchor = $forwardDocument.SelectSingleNode('/root/p[1]/a')
        $sourceAnchor | Should -Not -BeNullOrEmpty
        $sourceAnchor.GetAttribute('href') | Should -BeExactly 'https://docs.example.invalid/spec'
        $sourceAnchor.GetAttribute('title') | Should -BeExactly 'Specification title'

        $sourceBlock = $sourceAnchor.ParentNode
        $sourceAnchorSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($sourceAnchor.OuterXml))).ToLowerInvariant()
        $sourceBlockSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($sourceBlock.OuterXml))).ToLowerInvariant()
        $bodySha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes([string]$forward.storage))).ToLowerInvariant()
        $result = Invoke-StorageConversion -Storage ([string]$forward.storage)

        $result.status | Should -BeExactly 'unsupported'
        @($result.reasonCodes) | Should -Contain 'UnsupportedLinkTitle'
        @($result.unsupported).Count | Should -Be 1
        $result.unsupported[0].code | Should -BeExactly 'UnsupportedLinkTitle'
        $result.unsupported[0].location | Should -BeExactly '/root[1]/p[1]/a[1]'
        $result.unsupported[0].sourceXml | Should -BeExactly $sourceAnchor.OuterXml
        $result.unsupported[0].sourceSha256 | Should -BeExactly $sourceAnchorSha
        $result.sourceBlocks[0].supported | Should -BeFalse
        $result.sourceBlocks[0].sourceSha256 | Should -BeExactly $sourceBlockSha
        $result.sourceBlocks[0].sourceSha256 | Should -Not -BeExactly $result.unsupported[0].sourceSha256
        $result.bodySha256 | Should -BeExactly $bodySha
        $result.markdown | Should -Not -Match 'Titled HTTPS'
        $result.markdown | Should -Match 'Ordinary sibling content\.'
    }

    # Scenario: Link titles are absent, empty, whitespace-only, or paired with a URL that already has a refusal reason.
    # Purpose: Keep legacy link admission for absent/empty titles and preserve the existing URL-refusal priority.
    It 'UnitT48_preserves_link_admission_and_existing_url_reason_priority' {
        $titleless = Invoke-StorageConversion -Storage '<p><a href="https://example.invalid/plain">Plain link</a></p>'
        $titleless.status | Should -BeExactly 'supported'
        @($titleless.unsupported).Count | Should -Be 0

        $emptyTitle = Invoke-StorageConversion -Storage '<p><a href="https://example.invalid/empty" title="">Empty title link</a></p>'
        $emptyTitle.status | Should -BeExactly 'supported'
        @($emptyTitle.unsupported).Count | Should -Be 0

        $whitespaceTitle = Invoke-StorageConversion -Storage '<p><a href="https://example.invalid/whitespace" title=" ">Whitespace title link</a></p>'
        $whitespaceTitle.status | Should -BeExactly 'unsupported'
        @($whitespaceTitle.reasonCodes) | Should -Contain 'UnsupportedLinkTitle'

        $unsafeTitle = Invoke-StorageConversion -Storage '<p><a href="javascript:alert(1)" title="Unsafe URL reason">Unsafe link</a></p>'
        $unsafeTitle.status | Should -BeExactly 'unsupported'
        @($unsafeTitle.reasonCodes) | Should -Contain 'UnsafeUrl'
        @($unsafeTitle.reasonCodes) | Should -Not -Contain 'UnsupportedLinkTitle'

        $unrepresentableTitle = Invoke-StorageConversion -Storage '<p><a href="https://example.invalid/path_&lt;one&gt;_(x)" title="Unrepresentable URL reason">Unrepresentable link</a></p>'
        $unrepresentableTitle.status | Should -BeExactly 'unsupported'
        @($unrepresentableTitle.reasonCodes) | Should -Contain 'UnrepresentableHref'
        @($unrepresentableTitle.reasonCodes) | Should -Not -Contain 'UnsupportedLinkTitle'
    }

    # Scenario: SYP171-SCN-009; a table merges two source cells.
    # Purpose: V1 cannot represent the merge in Markdown and must preserve the original table.
    It 'UnitT50_rejects_merged_table_cell' {
        $storage = '<table><tr><td colspan="2">merged</td></tr></table>'
        $result = Invoke-StorageConversion -Storage $storage
        $result.status | Should -Be 'unsupported'
        @($result.reasonCodes) | Should -Contain 'MergedTableCell'
        $result.unsupported[0].sourceXml | Should -Match 'colspan'
    }

    # Scenario: SYP171-SCN-009; raw script markup appears in otherwise readable storage.
    # Purpose: Unknown executable nodes are captured for review without running their content.
    It 'UnitT60_rejects_unknown_script_node' {
        $storage = '<p>before</p><script>alert(1)</script>'
        $result = Invoke-StorageConversion -Storage $storage
        $result.status | Should -Be 'unsupported'
        @($result.reasonCodes) | Should -Contain 'UnsupportedNode'
        $result.unsupported[0].sourceXml | Should -Match '<script>'
    }

    # Scenario: SYP171-SCN-009; a native projection embeds its managed image inside a source paragraph.
    # Purpose: Re-import must keep the image and attachment provenance at its original inline position.
    It 'UnitT70_preserves_inline_image_and_surrounding_text_on_import' {
        $storage='<p>before <ac:image ac:alt="Architecture"><ri:attachment ri:filename="diagram.png" /></ac:image> after</p>'
        $result=Invoke-StorageConversion -Storage $storage
        $result.status | Should -Be 'supported'
        $result.markdown.Trim() | Should -Be 'before ![Architecture](assets/diagram.png) after'
        @($result.assets).Count | Should -Be 1
        $result.assets[0].filename | Should -Be 'diagram.png'
        $result.assets[0].sourceLocation | Should -Match 'ac:image'
    }

    # Scenario: A captured image has a tooltip title containing Markdown delimiter characters.
    # Purpose: Capture must preserve the title through Markdown conversion so a later publish/readback retains it.
    It 'UnitT72_preserves_image_title_when_escaping_markdown' {
        $result=Invoke-StorageConversion -Storage '<p><ac:image ac:alt="Architecture" ac:title="Open &quot;details&quot; \ guide"><ri:attachment ri:filename="diagram.png" /></ac:image></p>'
        $result.status | Should -Be 'supported'
        $result.markdown.Trim() | Should -Be '![Architecture](assets/diagram.png "Open \"details\" \\ guide")'
        $rendered=ConvertFrom-Markdown -InputObject $result.markdown
        $renderedHtml=[xml]('<root>'+$rendered.Html+'</root>')
        $renderedHtml.SelectSingleNode('/root/p/img').GetAttribute('title') | Should -Be 'Open "details" \ guide'
    }

    # Scenario: A supported storage paragraph contains an explicit Confluence line break between inline text.
    # Purpose: The captured Markdown must use the existing renderer's hard-break form so a storage round trip retains one br node.
    It 'UnitT74_roundtrips_supported_storage_break_as_a_hard_break' {
        Import-Module -Name $markdownModulePath -Force
        $captured = Invoke-StorageConversion -Storage '<p>a<br/>b</p>'
        $projected = ConvertTo-ConfluenceMarkdownStorage -Markdown $captured.markdown -Root $repositoryRoot -SourcePath 'docs/unrelated.md' -ProjectionId 'storage-break'
        $storageDom = [xml]('<root>' + $projected.storage + '</root>')

        $captured.status | Should -BeExactly 'supported'
        $projected.status | Should -BeExactly 'supported'
        $captured.markdown | Should -BeExactly ("a  `nb`n")
        $storageDom.SelectNodes('/root/p').Count | Should -Be 1
        $storageDom.SelectNodes('/root/p/br').Count | Should -Be 1
        $storageDom.SelectSingleNode('/root/p').InnerText | Should -BeExactly ("a`nb")
    }

    # Scenario: Plain captured text begins with a hash and contains paired underscores and backticks.
    # Purpose: Validate capture fidelity through the actual Markdown renderer and storage XML writer.
    # Given: These characters are ordinary text inside one published paragraph.
    # When: Storage is converted to Markdown and then through Markdown-to-XML projection.
    # Then: Text remains in one paragraph with no heading, emphasis, or code elements.
    It 'UnitT75_roundtrips_plain_hash_underscore_and_backtick_text_semantically' {
        $captured = Invoke-StorageConversion -Storage '<p># Heading marker, _plain underscored_, and `literal ticks`.</p>'
        $captured.status | Should -Be 'supported'
        Import-Module -Name $markdownModulePath -Force
        $projected = ConvertTo-ConfluenceMarkdownStorage -Markdown $captured.markdown -Root $repositoryRoot `
            -SourcePath 'docs/unrelated.md' -ProjectionId 'capture-text'
        $projected.status | Should -Be 'supported'
        $xml = [xml]('<root>' + $projected.storage + '</root>')
        $xml.SelectNodes('/root/p').Count | Should -Be 1
        $xml.SelectNodes('/root/h1|/root/h2|/root/em|/root/strong|/root/code').Count | Should -Be 0
        $xml.SelectSingleNode('/root/p').InnerText | Should -Be '# Heading marker, _plain underscored_, and `literal ticks`.'
    }

    # Scenario: Valid Confluence storage exceeds the current V1 Markdown subset.
    # Purpose: Preserve raw source with location and digest instead of silently changing list starts, nesting, or table headers.
    # Given: The storage contains a list starting at five, a nested list, or a headerless table.
    # When: Capture converts the page to a candidate Markdown projection.
    # Then: Each unsupported block is marked unsupported with its exact source XML and location evidence.
    It 'UnitT76_marks_unsupported_start5_nested_list_and_headerless_table_with_source_evidence' {
        $cases = @(
            [pscustomobject]@{ name='ordered list start'; storage='<ol start="5"><li>five</li><li>six</li></ol>' }
            [pscustomobject]@{ name='nested list'; storage='<ul><li>outer<ul><li>inner</li></ul></li></ul>' }
            [pscustomobject]@{ name='headerless table'; storage='<table><tbody><tr><td>value</td></tr></tbody></table>' }
        )
        foreach ($case in $cases) {
            $result = Invoke-StorageConversion -Storage $case.storage
            $result.status | Should -Be 'unsupported' -Because $case.name
            @($result.unsupported).Count | Should -BeGreaterThan 0 -Because $case.name
            $result.unsupported[0].sourceXml | Should -Not -BeNullOrEmpty -Because $case.name
            $result.unsupported[0].location | Should -Not -BeNullOrEmpty -Because $case.name
            $result.unsupported[0].sourceSha256 | Should -Match '^[a-f0-9]{64}$' -Because $case.name
        }
    }

    # Scenario: A table row mixes header and data cells in either column order while valid all-header/all-data rows remain supported.
    # Purpose: Preserve ambiguous source markup and its digest instead of turning data cells into Markdown header cells.
    It 'UnitT77_marks_mixed_table_rows_unsupported_with_raw_source_evidence' {
        $cases = @(
            '<table><tr><th>Header</th><td>Value</td></tr><tr><td>A</td><td>甲</td></tr></table>',
            '<table><tr><td>Header</td><th>Value</th></tr><tr><td>A</td><td>甲</td></tr></table>'
        )
        foreach ($storage in $cases) {
            $result = Invoke-StorageConversion -Storage $storage
            $result.status | Should -Be 'unsupported'
            @($result.reasonCodes) | Should -Contain 'MixedTableCellsUnsupported'
            $result.bodySha256 | Should -BeExactly ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($storage))).ToLowerInvariant())
            @($result.sourceBlocks).Count | Should -Be 1
            $result.sourceBlocks[0].supported | Should -BeFalse
            $result.sourceBlocks[0].location | Should -Match '/table\[1\]$'
            $result.sourceBlocks[0].sourceSha256 | Should -Match '^[a-f0-9]{64}$'
            $result.unsupported[0].code | Should -BeExactly 'MixedTableCellsUnsupported'
            $result.unsupported[0].location | Should -Match '/table\[1\]$'
            $result.unsupported[0].sourceXml | Should -Match '^<table>'
            $result.unsupported[0].sourceSha256 | Should -Match '^[a-f0-9]{64}$'
        }

        $valid = Invoke-StorageConversion -Storage '<table><tr><th>Header</th><th>Value</th></tr><tr><td>A</td><td>甲</td></tr></table>'
        $valid.status | Should -Be 'supported'
        @($valid.unsupported).Count | Should -Be 0
        @($valid.sourceBlocks | Where-Object supported).Count | Should -Be 1
    }

    # Scenario: Plain captured paragraph lines begin with unordered or ordered Markdown markers, including a line after a source break.
    # Purpose: Verify with the real renderer that ordinary text remains in paragraphs while actual source lists remain lists.
    It 'UnitT78_renders_plain_list_markers_as_paragraph_text' {
        $cases = @(
            [pscustomobject]@{ storage='<p>- text</p>'; expected='- text' },
            [pscustomobject]@{ storage='<p>+ text</p>'; expected='+ text' },
            [pscustomobject]@{ storage='<p>1. text</p>'; expected='1. text' },
            [pscustomobject]@{ storage='<p>before<br/>- after</p>'; expected=('before' + [string][char]10 + '- after') }
        )
        foreach ($case in $cases) {
            $captured = Invoke-StorageConversion -Storage $case.storage
            $captured.status | Should -Be 'supported'
            $rendered = ConvertFrom-Markdown -InputObject $captured.markdown
            $renderedDom = [xml]('<root>' + $rendered.Html + '</root>')
            $paragraphs = @($renderedDom.SelectNodes('/root/p'))
            $paragraphs.Count | Should -Be 1
            $paragraphs[0].InnerText | Should -BeExactly $case.expected
            $renderedDom.SelectNodes('/root//ul|/root//ol|/root//li').Count | Should -Be 0
        }

        $actualLists = Invoke-StorageConversion -Storage '<ul><li>Bullet item</li></ul><ol><li>Numbered item</li></ol>'
        $actualLists.status | Should -Be 'supported'
        $listDom = [xml]('<root>' + (ConvertFrom-Markdown -InputObject $actualLists.markdown).Html + '</root>')
        $listDom.SelectNodes('/root/ul/li').Count | Should -Be 1
        $listDom.SelectNodes('/root/ol/li').Count | Should -Be 1
        $listDom.SelectNodes('/root/ul/li').Item(0).InnerText | Should -BeExactly 'Bullet item'
        $listDom.SelectNodes('/root/ol/li').Item(0).InnerText | Should -BeExactly 'Numbered item'
    }

    # Scenario: SYP171-SCN-009; a paragraph begins with the parenthesized numeric marker followed by an actual TAB, including after a source break.
    # Purpose: Preserve the original TAB and inline nodes as paragraph content through both existing native DOM stages.
    It 'UnitT79_roundtrips_actual_tabs_after_parenthesized_numeric_markers' {
        Import-Module -Name $markdownModulePath -Force
        $tab = [string][char]9
        $cases = @(
            [pscustomobject]@{ name = 'paragraph start'; storage = ('<p>1)' + $tab + 'text</p>'); expected = ('1)' + $tab + 'text') },
            [pscustomobject]@{ name = 'after break with inline formatting'; storage = ('<p>before<br/>1)' + $tab + '<strong>bold</strong> and <code>code</code></p>'); expected = ('before' + [string][char]10 + '1)' + $tab + 'bold and code'); inline = $true }
        )
        $failures = [System.Collections.Generic.List[object]]::new()
        foreach ($case in $cases) {
            try {
                $captured = Invoke-StorageConversion -Storage $case.storage
                $renderedDom = [xml]('<root>' + (ConvertFrom-Markdown -InputObject $captured.markdown).Html + '</root>')
                $projected = ConvertTo-ConfluenceMarkdownStorage -Markdown $captured.markdown -Root $repositoryRoot -SourcePath 'docs/unrelated.md' -ProjectionId 'actual-tab-marker'
                $storageDom = [xml]('<root>' + $projected.storage + '</root>')
                $renderedParagraphs = @($renderedDom.SelectNodes('/root/p'))
                $storageParagraphs = @($storageDom.SelectNodes('/root/p'))
                $renderedText = if ($renderedParagraphs.Count -eq 1) { $renderedParagraphs[0].InnerText } else { $null }
                $storedText = if ($storageParagraphs.Count -eq 1) { $storageParagraphs[0].InnerText } else { $null }
                $renderedForbiddenCount = $renderedDom.SelectNodes('/root//ul|/root//ol|/root//li|/root//h1|/root//h2|/root//h3|/root//h4|/root//h5|/root//h6|/root//hr').Count
                $storageForbiddenCount = $storageDom.SelectNodes('/root//ul|/root//ol|/root//li|/root//h1|/root//h2|/root//h3|/root//h4|/root//h5|/root//h6|/root//hr').Count
                $inlineValid = $true
                if ($case.PSObject.Properties['inline']) {
                    $inlineValid = $renderedParagraphs[0].SelectNodes('.//strong').Count -eq 1 -and
                        $renderedParagraphs[0].SelectNodes('.//code').Count -eq 1 -and
                        $storageParagraphs[0].SelectNodes('.//strong').Count -eq 1 -and
                        $storageParagraphs[0].SelectNodes('.//code').Count -eq 1
                }
                if ($captured.status -cne 'supported' -or @($captured.unsupported).Count -ne 0 -or
                    $renderedParagraphs.Count -ne 1 -or $renderedText -cne $case.expected -or $renderedForbiddenCount -ne 0 -or
                    $projected.status -cne 'supported' -or $storageParagraphs.Count -ne 1 -or $storedText -cne $case.expected -or
                    $storageForbiddenCount -ne 0 -or -not $inlineValid) {
                    $failures.Add([ordered]@{
                        name = $case.name; captureStatus = $captured.status; unsupportedCount = @($captured.unsupported).Count
                        candidateMarkdown = $captured.markdown; renderedParagraphCount = $renderedParagraphs.Count; renderedText = $renderedText
                        renderedForbiddenNodeCount = $renderedForbiddenCount; renderedInlineValid = $inlineValid
                        projectionStatus = $projected.status; projectionReasons = @($projected.reasonCodes)
                        storageParagraphCount = $storageParagraphs.Count; storedText = $storedText; storageForbiddenNodeCount = $storageForbiddenCount
                    })
                }
            } catch {
                $failures.Add([ordered]@{ name = $case.name; errorType = $_.Exception.GetType().FullName; error = $_.Exception.Message })
            }
        }
        $failures.Count | Should -Be 0 -Because (ConvertTo-Json -InputObject @($failures.ToArray()) -Compress -Depth 8)
    }

    # Scenario: Captured paragraphs start with list or thematic markers, or contain setext-like delimiter lines after a break.
    # Purpose: The real renderer and storage projector retain exact paragraph text while genuine headings, lists and inline formats stay structured.
    It 'UnitT80_roundtrips_paragraph_list_and_delimiter_boundaries' {
        Import-Module -Name $markdownModulePath -Force
        $cases=@(
            [pscustomobject]@{name='parenthesized ordered marker';storage='<p>1) text</p>';expected='1) text'},
            [pscustomobject]@{name='parenthesized marker after break';storage='<p>before<br/>1) <strong>bold</strong> and <code>code</code></p>';expected="before`n1) bold and code";inline=$true},
            [pscustomobject]@{name='hyphen thematic delimiter';storage='<p>---</p>';expected='---'},
            [pscustomobject]@{name='asterisk thematic delimiter';storage='<p>* * *</p>';expected='* * *'},
            [pscustomobject]@{name='underscore thematic delimiter';storage='<p>___</p>';expected='___'},
            [pscustomobject]@{name='setext level two after break';storage='<p>title<br/>---</p>';expected="title`n---"},
            [pscustomobject]@{name='setext level one after break';storage='<p>title<br/>===</p>';expected="title`n==="}
        )
        $failures=[System.Collections.Generic.List[object]]::new()
        foreach($case in $cases){
            try {
                $captured=Invoke-StorageConversion -Storage $case.storage
                $rendered=(ConvertFrom-Markdown -InputObject $captured.markdown).Html
                $renderedDom=[xml]('<root>' + $rendered + '</root>')
                $paragraphs=@($renderedDom.SelectNodes('/root/p'))
                $projected=ConvertTo-ConfluenceMarkdownStorage -Markdown $captured.markdown -Root $repositoryRoot -SourcePath 'docs/unrelated.md' -ProjectionId 'capture-text'
                $storageDom=[xml]('<root>' + $projected.storage + '</root>')
                $storageParagraphs=@($storageDom.SelectNodes('/root/p'))
                $renderedText=if($paragraphs.Count -eq 1){$paragraphs[0].InnerText}else{$null}
                $storedText=if($storageParagraphs.Count -eq 1){$storageParagraphs[0].InnerText}else{$null}
                $needsInlineFormatting=($null -ne $case.PSObject.Properties['inline']) -and [bool]$case.inline
                $renderedInlineValid=if($needsInlineFormatting){$paragraphs[0].SelectNodes('.//strong').Count -eq 1 -and $paragraphs[0].SelectNodes('.//code').Count -eq 1}else{$true}
                $storedInlineValid=if($needsInlineFormatting){$storageParagraphs[0].SelectNodes('.//strong').Count -eq 1 -and $storageParagraphs[0].SelectNodes('.//code').Count -eq 1}else{$true}
                $bad=[ordered]@{
                    name=$case.name;captureStatus=$captured.status;unsupportedCount=@($captured.unsupported).Count
                    renderedParagraphCount=$paragraphs.Count;renderedText=$renderedText
                    renderedListCount=$renderedDom.SelectNodes('/root//ul|/root//ol|/root//li').Count
                    renderedHeadingCount=$renderedDom.SelectNodes('/root//h1|/root//h2|/root//h3|/root//h4|/root//h5|/root//h6').Count
                    renderedHrCount=$renderedDom.SelectNodes('/root//hr').Count;renderedInlineValid=$renderedInlineValid
                    projectionStatus=$projected.status;projectionReasons=@($projected.reasonCodes)
                    storageParagraphCount=$storageParagraphs.Count;storedText=$storedText
                    storageListCount=$storageDom.SelectNodes('/root//ul|/root//ol|/root//li').Count
                    storageHeadingCount=$storageDom.SelectNodes('/root//h1|/root//h2|/root//h3|/root//h4|/root//h5|/root//h6').Count
                    storageHrCount=$storageDom.SelectNodes('/root//hr').Count;storedInlineValid=$storedInlineValid
                }
                if($captured.status -cne 'supported' -or @($captured.unsupported).Count -ne 0 -or
                    $paragraphs.Count -ne 1 -or $renderedText -cne $case.expected -or
                    $renderedDom.SelectNodes('/root//ul|/root//ol|/root//li|/root//h1|/root//h2|/root//h3|/root//h4|/root//h5|/root//h6|/root//hr').Count -ne 0 -or
                    -not $renderedInlineValid -or $projected.status -cne 'supported' -or
                    $storageParagraphs.Count -ne 1 -or $storedText -cne $case.expected -or
                    $storageDom.SelectNodes('/root//ul|/root//ol|/root//li|/root//h1|/root//h2|/root//h3|/root//h4|/root//h5|/root//h6|/root//hr').Count -ne 0 -or
                    -not $storedInlineValid){
                    $failures.Add($bad)
                }
            } catch {
                $failures.Add([ordered]@{name=$case.name;error=$_.Exception.Message})
            }
        }

        $realBlocks=Invoke-StorageConversion -Storage '<h2>Real heading</h2><ul><li>Bullet item</li></ul><ol><li>Numbered item</li></ol>'
        $realHtml=(ConvertFrom-Markdown -InputObject $realBlocks.markdown).Html
        $realDom=[xml]('<root>' + $realHtml + '</root>')
        $realProjection=ConvertTo-ConfluenceMarkdownStorage -Markdown $realBlocks.markdown -Root $repositoryRoot -SourcePath 'docs/unrelated.md' -ProjectionId 'native-blocks'
        $realStorageDom=[xml]('<root>' + $realProjection.storage + '</root>')
        $realBlocks.status | Should -Be 'supported'
        $realProjection.status | Should -Be 'supported'
        $realDom.SelectNodes('/root/h2').Count | Should -Be 1
        $realDom.SelectNodes('/root/ul/li').Count | Should -Be 1
        $realDom.SelectNodes('/root/ol/li').Count | Should -Be 1
        $realStorageDom.SelectNodes('/root/h2').Count | Should -Be 1
        $realStorageDom.SelectNodes('/root/ul/li').Count | Should -Be 1
        $realStorageDom.SelectNodes('/root/ol/li').Count | Should -Be 1
        $failures.Count | Should -Be 0 -Because (ConvertTo-Json -InputObject @($failures.ToArray()) -Compress -Depth 8)
    }

    # Scenario: SYP171-SCN-009; valid storage contains more nested content elements than the bounded renderer accepts.
    # Purpose: The complete XML fragment must become one deterministic unsupported record before recursive conversion.
    It 'UnitT81_marks_valid_storage_over_depth_as_one_stable_unsupported_fragment' {
        $depth = 129
        $storage = ('<strong>' * $depth) + 'bounded text' + ('</strong>' * $depth)
        $first = Invoke-StorageConversion -Storage $storage
        $second = Invoke-StorageConversion -Storage $storage
        $bodyHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($storage))).ToLowerInvariant()
        $blockSeed = '101:3:whole-fragment:' + $bodyHash
        $blockHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($blockSeed))).ToLowerInvariant()

        $first.status | Should -Be 'unsupported'
        @($first.reasonCodes) | Should -Contain 'StorageDepthExceeded'
        $first.markdown | Should -BeExactly ''
        $first.bodySha256 | Should -BeExactly $bodyHash
        @($first.sourceBlocks).Count | Should -Be 1
        $first.sourceBlocks[0].id | Should -BeExactly ('BLOCK-' + $blockHash.Substring(0, 20))
        $first.sourceBlocks[0].location | Should -BeExactly '/root[1]'
        $first.sourceBlocks[0].sourceType | Should -BeExactly 'whole-storage'
        $first.sourceBlocks[0].sourceSha256 | Should -BeExactly $bodyHash
        $first.sourceBlocks[0].supported | Should -BeFalse
        @($first.unsupported).Count | Should -Be 1
        $first.unsupported[0].code | Should -BeExactly 'StorageDepthExceeded'
        $first.unsupported[0].location | Should -BeExactly '/root[1]'
        $first.unsupported[0].sourceSha256 | Should -BeExactly $bodyHash
        ($second | ConvertTo-Json -Depth 12 -Compress) | Should -BeExactly ($first | ConvertTo-Json -Depth 12 -Compress)
    }

    # Scenario: SYP171-SCN-009; storage is at the supported depth boundary or becomes invalid after a deep subtree.
    # Purpose: Accept depth 128 exactly, keep malformed/DTD reason precedence, and never skip the end of the fragment.
    It 'UnitT82_preserves_depth_boundary_and_invalid_xml_reason_precedence' {
        $atLimit = '<p>' + ('<strong>' * 127) + 'bounded text' + ('</strong>' * 127) + '</p>'
        $valid = Invoke-StorageConversion -Storage $atLimit
        $valid.status | Should -Be 'supported'
        @($valid.unsupported).Count | Should -Be 0
        @($valid.sourceBlocks).Count | Should -Be 1

        $deepMalformed = ('<strong>' * 129) + 'bounded text' + ('</strong>' * 129) + '<'
        $malformed = Invoke-StorageConversion -Storage $deepMalformed
        $malformed.status | Should -Be 'invalid'
        @($malformed.reasonCodes) | Should -Contain 'StorageXmlInvalid'
        @($malformed.sourceBlocks).Count | Should -Be 0

        $deepWithDtd = ('<strong>' * 129) + 'bounded text' + ('</strong>' * 129) + '<!DOCTYPE forbidden>'
        $dtd = Invoke-StorageConversion -Storage $deepWithDtd
        $dtd.status | Should -Be 'invalid'
        @($dtd.reasonCodes) | Should -Contain 'DtdForbidden'
        @($dtd.sourceBlocks).Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-009; a valid fragment contains many shallow sibling elements.
    # Purpose: The depth bound is independent of ordinary sibling count and all blocks remain available.
    It 'UnitT83_accepts_many_shallow_storage_siblings' {
        $storage = '<p>item</p>' * 2000
        $result = Invoke-StorageConversion -Storage $storage
        $result.status | Should -Be 'supported'
        @($result.reasonCodes).Count | Should -Be 0
        @($result.sourceBlocks).Count | Should -Be 2000
        $result.markdown.StartsWith('item', [StringComparison]::Ordinal) | Should -BeTrue
        $result.markdown.TrimEnd().EndsWith('item', [StringComparison]::Ordinal) | Should -BeTrue
    }

    # Scenario: SYP171-SCN-009; valid storage contains 2,000 nested inline elements.
    # Purpose: The streaming depth refusal must occur before DOM load, recursive inspection, inline conversion, location lookup, or OuterXml access.
    It 'UnitT84_bounds_2000_deep_valid_storage_before_dom_and_recursive_traversal' {
        $depth = 2000
        $deepStorage = ('<strong>' * $depth) + 'bounded text' + ('</strong>' * $depth)
        $shallowStorage = '<p>ordinary shallow paragraph</p>'
        $probe = @(Invoke-StorageTraversalProbe -Storage @($shallowStorage, $deepStorage, $deepStorage))
        $shallow = $probe[0]
        $deep = $probe[1]
        $deepRepeat = $probe[2]

        $shallow.result.status | Should -BeExactly 'supported'
        @($shallow.events) | Should -Contain 'XmlDocumentCreated'
        @($shallow.events) | Should -Contain 'XmlDocumentLoad'
        @($shallow.events) | Should -Contain 'InspectStorageNode'
        @($shallow.events) | Should -Contain 'ConvertStorageBlock'
        @($shallow.events) | Should -Contain 'ConvertInlineChildren'
        @($shallow.events) | Should -Contain 'GetNodeLocation'
        @($shallow.events) | Should -Contain 'OuterXml'

        $deep.result.status | Should -BeExactly 'unsupported'
        @($deep.result.reasonCodes) | Should -Contain 'StorageDepthExceeded'
        $deep.result.markdown | Should -BeExactly ''
        @($deep.result.sourceBlocks).Count | Should -Be 1
        $bodyHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($deepStorage))).ToLowerInvariant()
        $deep.result.bodySha256 | Should -BeExactly $bodyHash
        $deep.result.sourceBlocks[0].location | Should -BeExactly '/root[1]'
        $deep.result.sourceBlocks[0].sourceSha256 | Should -BeExactly $bodyHash
        $deep.result.sourceBlocks[0].id | Should -BeExactly $deepRepeat.result.sourceBlocks[0].id
        ($deep.result | ConvertTo-Json -Depth 12 -Compress) | Should -BeExactly ($deepRepeat.result | ConvertTo-Json -Depth 12 -Compress)
        @($deep.events).Count | Should -Be 0 -Because (ConvertTo-Json -InputObject @($deep.events) -Compress -Depth 4)
        @($deepRepeat.events).Count | Should -Be 0 -Because (ConvertTo-Json -InputObject @($deepRepeat.events) -Compress -Depth 4)
    }

    # Scenario: SYP171-SCN-009; known inline elements occur at the storage-fragment root without a block converter.
    # Purpose: Preserve exact unsupported source evidence for unconverted roots while allowing the same inline nodes under a paragraph.
    It 'UnitT85_rejects_fragment_root_nodes_without_a_block_converter' {
        $cases = @(
            [pscustomobject]@{ name = 'strong'; xml = '<strong>root bold</strong>' },
            [pscustomobject]@{ name = 'a'; xml = '<a href="https://example.invalid/root">root link</a>' },
            [pscustomobject]@{ name = 'code'; xml = '<code>root code</code>' },
            [pscustomobject]@{ name = 'tr'; xml = '<tr><td>root row</td></tr>' }
        )
        foreach ($case in $cases) {
            $result = Invoke-StorageConversion -Storage $case.xml
            $expectedSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($case.xml))).ToLowerInvariant()
            $result.status | Should -BeExactly 'unsupported' -Because $case.name
            @($result.reasonCodes) | Should -Contain 'UnsupportedNode' -Because $case.name
            $result.markdown | Should -BeExactly ([string][char] 10) -Because $case.name
            @($result.sourceBlocks).Count | Should -Be 1 -Because $case.name
            $result.sourceBlocks[0].sourceType | Should -BeExactly $case.name -Because $case.name
            $result.sourceBlocks[0].location | Should -BeExactly ("/root[1]/$($case.name)[1]") -Because $case.name
            $result.sourceBlocks[0].sourceSha256 | Should -BeExactly $expectedSha -Because $case.name
            $result.sourceBlocks[0].supported | Should -BeFalse -Because $case.name
            @($result.unsupported).Count | Should -Be 1 -Because $case.name
            $result.unsupported[0].code | Should -BeExactly 'UnsupportedNode' -Because $case.name
            $result.unsupported[0].location | Should -BeExactly ("/root[1]/$($case.name)[1]") -Because $case.name
            $result.unsupported[0].sourceXml | Should -BeExactly $case.xml -Because $case.name
            $result.unsupported[0].sourceSha256 | Should -BeExactly $expectedSha -Because $case.name
        }

        Import-Module -Name $markdownModulePath -Force
        $inlineStorage = '<p><strong>bold</strong> <a href="https://example.invalid/root">link</a> <code>code</code></p>'
        $inline = Invoke-StorageConversion -Storage $inlineStorage
        $rendered = ConvertFrom-Markdown -InputObject $inline.markdown
        $renderedDom = [xml]('<root>' + $rendered.Html + '</root>')
        $projected = ConvertTo-ConfluenceMarkdownStorage -Markdown $inline.markdown -Root $repositoryRoot -SourcePath 'docs/unrelated.md' -ProjectionId 'root-inline-control'
        $storageDom = [xml]('<root>' + $projected.storage + '</root>')

        $inline.status | Should -BeExactly 'supported'
        @($inline.unsupported).Count | Should -Be 0
        @($inline.sourceBlocks).Count | Should -Be 1
        $inline.sourceBlocks[0].supported | Should -BeTrue
        $projected.status | Should -BeExactly 'supported'
        $renderedDom.SelectNodes('/root/p/strong').Count | Should -Be 1
        $renderedDom.SelectNodes('/root/p/a').Count | Should -Be 1
        $renderedDom.SelectNodes('/root/p/code').Count | Should -Be 1
        $storageDom.SelectNodes('/root/p/strong').Count | Should -Be 1
        $storageDom.SelectNodes('/root/p/a').Count | Should -Be 1
        $storageDom.SelectNodes('/root/p/code').Count | Should -Be 1
    }
}
