# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/StorageProjection.psm1'

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
}
