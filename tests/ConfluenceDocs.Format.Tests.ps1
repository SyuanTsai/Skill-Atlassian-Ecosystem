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

    # Scenario: SYP171-SCN-009; inline code includes an asterisk that has no Markdown meaning inside code.
    # Purpose: The source code token must remain exact instead of inheriting paragraph escaping.
    It 'UnitT18_preserves_inline_code_characters' {
        $result = Invoke-StorageConversion -Storage '<p>use <code>a*b</code></p>'
        $result.status | Should -Be 'supported'
        $result.markdown.Trim() | Should -Be 'use `a*b`'
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
}
