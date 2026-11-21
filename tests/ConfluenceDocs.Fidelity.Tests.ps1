# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $repositoryRoot = Split-Path -Parent $PSScriptRoot
    $markdownModule = Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/MarkdownProjection.psm1'
    $storageModule = Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/StorageProjection.psm1'
    $assetsModule = Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluenceAssets.psm1'
    $storageNamesModule = Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluenceStorage.psm1'
    $planModule = Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluencePlan.psm1'
    $site = 'https://example.atlassian.net'
    $cloud = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    $api = "https://api.atlassian.com/ex/confluence/$cloud"

    function Get-FidelitySha256 {
        param([Parameter(Mandatory)][byte[]] $Bytes)
        return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
    }

    function New-FidelityAsset {
        param(
            [Parameter(Mandatory)][string] $Root,
            [Parameter(Mandatory)][string] $LocalPath,
            [Parameter(Mandatory)][string] $DisplayFilename,
            [Parameter(Mandatory)][string] $MediaType,
            [Parameter(Mandatory)][byte[]] $Bytes
        )
        $path = Join-Path $Root $LocalPath
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [IO.File]::WriteAllBytes($path, $Bytes)
        return [pscustomobject]@{
            localPath = $LocalPath.Replace([IO.Path]::DirectorySeparatorChar, '/')
            displayFilename = $DisplayFilename
            mediaType = $MediaType
            sha256 = Get-FidelitySha256 -Bytes $Bytes
        }
    }

    function New-FidelityFixture {
        $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
        $root = Join-Path $tempParent ('syp344-fidelity-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $root 'docs') -Force | Out-Null
        $mmdBytes = [Text.UTF8Encoding]::new($false).GetBytes("flowchart LR`nA-->B`n")
        $pdfBytes = [Text.Encoding]::ASCII.GetBytes('%PDF-1.7 synthetic fidelity fixture')
        $textBytes = [Text.UTF8Encoding]::new($false).GetBytes("臺灣正體文字附件`n")
        $binaryBytes = [byte[]]@(0, 255, 13, 10, 42, 128)
        $pngBytes = [byte[]]@(137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3, 4)
        return [pscustomobject]@{
            root = $root
            mmdBytes = $mmdBytes
            assets = [pscustomobject]@{
                mmd = New-FidelityAsset -Root $root -LocalPath 'docs/diagrams/flow.mmd' -DisplayFilename 'flow.mmd' -MediaType 'text/plain' -Bytes $mmdBytes
                pdf = New-FidelityAsset -Root $root -LocalPath 'docs/files/spec.pdf' -DisplayFilename 'spec.pdf' -MediaType 'application/pdf' -Bytes $pdfBytes
                text = New-FidelityAsset -Root $root -LocalPath 'docs/files/notes.txt' -DisplayFilename 'notes.txt' -MediaType 'text/plain' -Bytes $textBytes
                binary = New-FidelityAsset -Root $root -LocalPath 'docs/files/archive.bin' -DisplayFilename 'archive.bin' -MediaType 'application/octet-stream' -Bytes $binaryBytes
                png = New-FidelityAsset -Root $root -LocalPath 'docs/files/diagram.png' -DisplayFilename 'diagram.png' -MediaType 'image/png' -Bytes $pngBytes
            }
        }
    }

    function Remove-FidelityFixture {
        param([Parameter(Mandatory)][string] $Root)
        if (-not (Test-Path -LiteralPath $Root)) { return }
        $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path)
        $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
        if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\', '/') -cne $parent -or
            [IO.Path]::GetFileName($resolved) -cnotmatch '^syp344-fidelity-[a-f0-9]{32}$') {
            throw 'Unsafe fidelity fixture delete.'
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }

    function ConvertTo-FidelityStorage {
        param(
            [Parameter(Mandatory)][string] $Markdown,
            [Parameter(Mandatory)] $Fixture,
            [object[]] $ManagedAssets = @()
        )
        Import-Module -Name $markdownModule -Force
        return ConvertTo-ConfluenceMarkdownStorage -Markdown $Markdown -Root $Fixture.root `
            -SourcePath 'docs/spec.md' -ProjectionId 'fidelity' -ManagedAssets $ManagedAssets
    }

    function ConvertFrom-FidelityStorage {
        param([Parameter(Mandatory)][string] $Storage)
        Import-Module -Name $storageModule -Force
        return ConvertFrom-ConfluenceStorage -Storage $Storage -PageId '101' -PageVersion 3
    }

    function ConvertTo-FidelityXml {
        param([Parameter(Mandatory)][AllowEmptyString()][string] $Storage)
        return [xml]('<root xmlns:ac="http://atlassian.com/content" xmlns:ri="http://atlassian.com/resource/identifier">' + $Storage + '</root>')
    }

    function New-FidelityNamespaceManager {
        param([Parameter(Mandatory)][xml] $Document)
        $manager = [Xml.XmlNamespaceManager]::new($Document.NameTable)
        $manager.AddNamespace('ac', 'http://atlassian.com/content')
        $manager.AddNamespace('ri', 'http://atlassian.com/resource/identifier')
        return $manager
    }

    function New-FidelityValidation {
        return [pscustomobject]@{
            status = 'valid'; siteOrigin = $site; cloudId = $cloud; docsCommit = ('1' * 40); codeCommit = ''
            sourceMode = 'git-markdown'; sourceDigest = ('a' * 64); mappingDigest = ('b' * 64); reviewDigest = ''
            validatorVersion = 'powershell-markdown-v1'; rendererVersion = 'powershell-markdown-v1'
        }
    }

    function New-FidelityPlanHttp {
        return {
            param($Request)
            $script:planCalls.Add([pscustomobject]@{ Method = [string]$Request.Method; Uri = [string]$Request.Uri })
            if ($Request.Uri -match '/pages/101/attachments') {
                $rows = @()
                if ($script:planMode -ceq 'mmd-version-2') {
                    $rows = @(@{
                        id = '900'; pageId = '101'; status = 'current'; title = $script:planRemoteFilename
                        mediaType = 'text/plain'; fileSize = $script:fixture.mmdBytes.Length; version = @{ number = 2 }
                        downloadLink = '/wiki/rest/api/content/101/child/attachment/900/download'
                    })
                }
                return [pscustomobject]@{ StatusCode = 200; Headers = @{}; Body = @{ results = $rows; _links = @{} } }
            }
            if ($Request.Uri -match '/child/attachment/900/download\?version=2$') {
                return [pscustomobject]@{ StatusCode = 200; Headers = @{}; BodyBytes = $script:fixture.mmdBytes; Body = $script:fixture.mmdBytes }
            }
            $page = @{
                id = '101'; spaceId = '55'; parentId = '99'; title = 'Synthetic fidelity page'; status = 'current'
                version = @{ number = 7 }; body = @{ storage = @{ value = '<p>Previous</p>' } }
            }
            return [pscustomobject]@{ StatusCode = 200; Headers = @{}; Body = $page }
        }
    }
}

Describe 'SYP-344 Confluence fidelity projection' {
    BeforeEach { $script:fixture = New-FidelityFixture }
    AfterEach { Remove-FidelityFixture -Root $script:fixture.root }

    # Scenario: Exact attribute-free br spellings appear inside ordinary Markdown paragraphs.
    # Purpose: Each controlled raw inline becomes one well-formed storage break without splitting the paragraph.
    It 'FidelityT10_projects_controlled_paragraph_br_spellings' {
        foreach ($markdown in @('a<br>b', 'a<br/>b')) {
            $result = ConvertTo-FidelityStorage -Markdown $markdown -Fixture $script:fixture
            $xml = ConvertTo-FidelityXml -Storage $result.storage
            $result.status | Should -BeExactly 'supported'
            @($result.unsupported).Count | Should -Be 0
            $xml.SelectNodes('/root/p').Count | Should -Be 1
            $xml.SelectNodes('/root/p/br').Count | Should -Be 1
            $xml.SelectSingleNode('/root/p').InnerText | Should -BeExactly 'ab'
        }
    }

    # Scenario: A Markdown table cell contains one controlled raw br.
    # Purpose: Projection preserves the table dimensions and keeps the break under the intended td.
    It 'FidelityT11_preserves_table_dimensions_for_controlled_br' {
        $markdown = "| H1 | H2 |`n| --- | --- |`n| x<br>y | z |"
        $result = ConvertTo-FidelityStorage -Markdown $markdown -Fixture $script:fixture
        $xml = ConvertTo-FidelityXml -Storage $result.storage
        $result.status | Should -BeExactly 'supported'
        $rows = @($xml.SelectNodes('/root/table//tr'))
        $rows.Count | Should -Be 2
        foreach ($row in $rows) { @($row.SelectNodes('./th|./td')).Count | Should -Be 2 }
        $xml.SelectNodes('/root/table//td/br').Count | Should -Be 1
    }

    # Scenario: Storage has a br in one table data cell.
    # Purpose: Capture uses inline br Markdown so the row remains one line and round-trips with identical shape.
    It 'FidelityT12_roundtrips_table_cell_br_without_splitting_rows' {
        $storage = '<table><tr><th>H1</th><th>H2</th></tr><tr><td>x<br/>y</td><td>z</td></tr></table>'
        $captured = ConvertFrom-FidelityStorage -Storage $storage
        $dataLines = @($captured.markdown -split "`r?`n" | Where-Object { $_ -match '\bx' -and $_ -match '\by' })
        $projected = ConvertTo-FidelityStorage -Markdown $captured.markdown -Fixture $script:fixture
        $xml = ConvertTo-FidelityXml -Storage $projected.storage
        $captured.status | Should -BeExactly 'supported'
        $captured.markdown | Should -Match 'x<br>y'
        $dataLines.Count | Should -Be 1
        $projected.status | Should -BeExactly 'supported'
        $rows = @($xml.SelectNodes('/root/table//tr'))
        $rows.Count | Should -Be 2
        @($rows[0].SelectNodes('./th|./td')).Count | Should -Be 2
        @($rows[1].SelectNodes('./th|./td')).Count | Should -Be 2
        $xml.SelectNodes('/root/table//td/br').Count | Should -Be 1
    }

    # Scenario: A storage heading contains an explicit br.
    # Purpose: Capture and publish keep one heading element with one inline break.
    It 'FidelityT13_roundtrips_heading_br_inside_one_heading' {
        $captured = ConvertFrom-FidelityStorage -Storage '<h2>before<br/>after</h2>'
        $projected = ConvertTo-FidelityStorage -Markdown $captured.markdown -Fixture $script:fixture
        $xml = ConvertTo-FidelityXml -Storage $projected.storage
        $captured.status | Should -BeExactly 'supported'
        $captured.markdown | Should -Match '(?m)^## before<br>after$'
        $projected.status | Should -BeExactly 'supported'
        $xml.SelectNodes('/root/h2').Count | Should -Be 1
        $xml.SelectNodes('/root/h2/br').Count | Should -Be 1
    }

    # Scenario: A root code macro has a language and a multiline CDATA body containing XML-sensitive text.
    # Purpose: Macro identity, language, and body survive storage-to-Markdown-to-storage conversion exactly.
    It 'FidelityT20_roundtrips_language_code_macro_body_exactly' {
        $body = "Write-Output '<tag>'`nif (`$a -lt 2) { `n  Write-Output 'A & B'`n}"
        $storage = '<ac:structured-macro ac:name="code" ac:schema-version="1"><ac:parameter ac:name="language">powershell</ac:parameter><ac:plain-text-body><![CDATA[' + $body + ']]></ac:plain-text-body></ac:structured-macro>'
        $captured = ConvertFrom-FidelityStorage -Storage $storage
        $projected = ConvertTo-FidelityStorage -Markdown $captured.markdown -Fixture $script:fixture
        $xml = ConvertTo-FidelityXml -Storage $projected.storage
        $ns = New-FidelityNamespaceManager -Document $xml
        $captured.status | Should -BeExactly 'supported'
        $captured.markdown | Should -Match '(?m)^```powershell \{data-confluence-macro=code\}$'
        $projected.status | Should -BeExactly 'supported'
        $xml.SelectSingleNode('/root/ac:structured-macro', $ns).GetAttribute('name', 'http://atlassian.com/content') | Should -BeExactly 'code'
        $xml.SelectSingleNode('/root/ac:structured-macro/ac:parameter[@ac:name="language"]', $ns).InnerText | Should -BeExactly 'powershell'
        $xml.SelectSingleNode('/root/ac:structured-macro/ac:plain-text-body', $ns).InnerText | Should -BeExactly $body
    }

    # Scenario: A root code macro omits the optional language parameter.
    # Purpose: The explicit macro marker remains present and the body round-trips without inventing a language.
    It 'FidelityT21_roundtrips_code_macro_without_language' {
        $body = "plain`nbody"
        $storage = '<ac:structured-macro ac:name="code" ac:schema-version="1"><ac:plain-text-body><![CDATA[' + $body + ']]></ac:plain-text-body></ac:structured-macro>'
        $captured = ConvertFrom-FidelityStorage -Storage $storage
        $projected = ConvertTo-FidelityStorage -Markdown $captured.markdown -Fixture $script:fixture
        $xml = ConvertTo-FidelityXml -Storage $projected.storage
        $ns = New-FidelityNamespaceManager -Document $xml
        $captured.markdown | Should -Match '(?m)^``` \{data-confluence-macro=code\}$'
        $projected.status | Should -BeExactly 'supported'
        $xml.SelectNodes('/root/ac:structured-macro/ac:parameter', $ns).Count | Should -Be 0
        $xml.SelectSingleNode('/root/ac:structured-macro/ac:plain-text-body', $ns).InnerText | Should -BeExactly $body
    }

    # Scenario: A code macro body itself contains a triple-backtick sequence.
    # Purpose: Capture selects a longer fence and still restores the exact body.
    It 'FidelityT22_uses_longer_fence_for_backticks_and_roundtrips_body' {
        $body = 'alpha ``` beta'
        $storage = '<ac:structured-macro ac:name="code" ac:schema-version="1"><ac:plain-text-body><![CDATA[' + $body + ']]></ac:plain-text-body></ac:structured-macro>'
        $captured = ConvertFrom-FidelityStorage -Storage $storage
        $projected = ConvertTo-FidelityStorage -Markdown $captured.markdown -Fixture $script:fixture
        $xml = ConvertTo-FidelityXml -Storage $projected.storage
        $ns = New-FidelityNamespaceManager -Document $xml
        $captured.markdown | Should -Match '(?m)^```` \{data-confluence-macro=code\}$'
        $projected.status | Should -BeExactly 'supported'
        $xml.SelectSingleNode('/root/ac:structured-macro/ac:plain-text-body', $ns).InnerText | Should -BeExactly $body
    }

    # Scenario: An ordinary fenced block has no Confluence macro marker.
    # Purpose: Existing native pre/code projection remains unchanged.
    It 'FidelityT23_keeps_unmarked_fence_as_native_pre_code' {
        $markdown = @'
```powershell
Write-Output ok
```
'@
        $result = ConvertTo-FidelityStorage -Markdown $markdown -Fixture $script:fixture
        $xml = ConvertTo-FidelityXml -Storage $result.storage
        $ns = New-FidelityNamespaceManager -Document $xml
        $result.status | Should -BeExactly 'supported'
        $xml.SelectNodes('/root/pre/code[@class="language-powershell"]').Count | Should -Be 1
        $xml.SelectNodes('/root/ac:structured-macro', $ns).Count | Should -Be 0
    }

    # Scenario: An unmarked Mermaid fence contains arrows, angle brackets, and an ampersand.
    # Purpose: It remains native pre/code and preserves the renderer payload exactly.
    It 'FidelityT24_projects_unmarked_mermaid_fence_as_native_code' {
        $body = 'A<node>-->B & C'
        $markdown = @'
```mermaid
A<node>-->B & C
```
'@
        $result = ConvertTo-FidelityStorage -Markdown $markdown -Fixture $script:fixture
        $xml = ConvertTo-FidelityXml -Storage $result.storage
        $result.status | Should -BeExactly 'supported'
        @($result.unsupported).Count | Should -Be 0
        $node = $xml.SelectSingleNode('/root/pre/code[@class="language-mermaid"]')
        $node | Should -Not -BeNullOrEmpty
        $node.InnerText | Should -BeExactly ($body + "`n")
    }

    # Scenario: A Mermaid fence explicitly opts in to the Confluence code macro.
    # Purpose: Projection emits a code macro with language mermaid and an exact body.
    It 'FidelityT25_projects_marked_mermaid_fence_as_code_macro' {
        $body = 'A-->B'
        $markdown = @'
```mermaid {data-confluence-macro=code}
A-->B
```
'@
        $result = ConvertTo-FidelityStorage -Markdown $markdown -Fixture $script:fixture
        $xml = ConvertTo-FidelityXml -Storage $result.storage
        $ns = New-FidelityNamespaceManager -Document $xml
        $result.status | Should -BeExactly 'supported'
        $xml.SelectSingleNode('/root/ac:structured-macro', $ns).GetAttribute('name', 'http://atlassian.com/content') | Should -BeExactly 'code'
        $xml.SelectSingleNode('/root/ac:structured-macro/ac:parameter[@ac:name="language"]', $ns).InnerText | Should -BeExactly 'mermaid'
        $xml.SelectSingleNode('/root/ac:structured-macro/ac:plain-text-body', $ns).InnerText | Should -BeExactly $body
    }

    # Scenario: A root mermaid-cloud macro names an attachment revision and includes server metadata.
    # Purpose: Capture emits the controlled image form and records filename plus integer revision.
    It 'FidelityT30_captures_mermaid_cloud_macro_and_revision_asset' {
        $storage = '<ac:structured-macro ac:name="mermaid-cloud" ac:schema-version="1" ac:macro-id="12345678-1234-1234-1234-1234567890ab"><ac:parameter ac:name="filename">flow.mmd</ac:parameter><ac:parameter ac:name="revision">3</ac:parameter></ac:structured-macro>'
        $result = ConvertFrom-FidelityStorage -Storage $storage
        $result.status | Should -BeExactly 'supported'
        $result.markdown.Trim() | Should -BeExactly '![mermaid-cloud](assets/flow.mmd)'
        @($result.assets).Count | Should -Be 1
        $result.assets[0].filename | Should -BeExactly 'flow.mmd'
        $result.assets[0].revision | Should -Be 3
        $result.assets[0].sourceLocation | Should -Not -BeNullOrEmpty
    }

    # Scenario: A block image binds to a managed text/plain .mmd asset.
    # Purpose: Projection replaces the paragraph with one root mermaid-cloud macro at revision one.
    It 'FidelityT31_projects_bound_mmd_image_as_root_mermaid_cloud_macro' {
        $result = ConvertTo-FidelityStorage -Markdown '![Flow](diagrams/flow.mmd)' -Fixture $script:fixture -ManagedAssets @($script:fixture.assets.mmd)
        $xml = ConvertTo-FidelityXml -Storage $result.storage
        $ns = New-FidelityNamespaceManager -Document $xml
        $macro = $xml.SelectSingleNode('/root/ac:structured-macro', $ns)
        $result.status | Should -BeExactly 'supported'
        $xml.SelectNodes('/root/p').Count | Should -Be 0
        $macro.GetAttribute('name', 'http://atlassian.com/content') | Should -BeExactly 'mermaid-cloud'
        $filename = $macro.SelectSingleNode('./ac:parameter[@ac:name="filename"]', $ns).InnerText
        $filename | Should -Match '^syp171-fidelity-[a-f0-9]{64}\.mmd$'
        $macro.SelectSingleNode('./ac:parameter[@ac:name="revision"]', $ns).InnerText | Should -BeExactly '1'
        @($result.assets).Count | Should -Be 1
        $result.assets[0].remoteFilename | Should -BeExactly $filename
    }

    # Scenario: Markdown links bind independently to managed PDF, text, and binary attachments.
    # Purpose: Each becomes ac:link/ri:attachment with the exact label and content-addressed remote filename.
    It 'FidelityT40_projects_managed_non_image_attachment_links' {
        $cases = @(
            [pscustomobject]@{ markdown = '[規格書](files/spec.pdf)'; asset = $script:fixture.assets.pdf; label = '規格書'; extension = 'pdf' }
            [pscustomobject]@{ markdown = '[說明](files/notes.txt)'; asset = $script:fixture.assets.text; label = '說明'; extension = 'txt' }
            [pscustomobject]@{ markdown = '[封存](files/archive.bin)'; asset = $script:fixture.assets.binary; label = '封存'; extension = 'bin' }
        )
        foreach ($case in $cases) {
            $result = ConvertTo-FidelityStorage -Markdown $case.markdown -Fixture $script:fixture -ManagedAssets @($case.asset)
            $xml = ConvertTo-FidelityXml -Storage $result.storage
            $ns = New-FidelityNamespaceManager -Document $xml
            $result.status | Should -BeExactly 'supported' -Because $case.markdown
            $link = $xml.SelectSingleNode('/root/p/ac:link', $ns)
            $link | Should -Not -BeNullOrEmpty
            $link.SelectSingleNode('./ri:attachment', $ns).GetAttribute('filename', 'http://atlassian.com/resource/identifier') | Should -Match ("\." + $case.extension + '$')
            $link.SelectSingleNode('./ac:plain-text-link-body', $ns).InnerText | Should -BeExactly $case.label
            @($result.assets).Count | Should -Be 1
        }
    }

    # Scenario: Storage contains an inline attachment link with a CDATA label.
    # Purpose: Capture emits the assets path link and records the referenced attachment.
    It 'FidelityT41_captures_storage_attachment_link_and_asset' {
        $storage = '<p>見 <ac:link><ri:attachment ri:filename="spec.pdf" /><ac:plain-text-link-body><![CDATA[規格書]]></ac:plain-text-link-body></ac:link></p>'
        $result = ConvertFrom-FidelityStorage -Storage $storage
        $result.status | Should -BeExactly 'supported'
        $result.markdown | Should -Match '\[規格書\]\(assets/spec\.pdf\)'
        @($result.assets).Count | Should -Be 1
        $result.assets[0].filename | Should -BeExactly 'spec.pdf'
    }

    # Scenario: Storage attachment discovery receives a mermaid-cloud macro.
    # Purpose: Its filename parameter participates in the same drift checks as ordinary attachment references.
    It 'FidelityT42_discovers_mermaid_cloud_filename_as_storage_attachment' {
        Import-Module -Name $storageNamesModule -Force
        $storage = '<ac:structured-macro ac:name="mermaid-cloud" ac:schema-version="1"><ac:parameter ac:name="filename">flow.mmd</ac:parameter><ac:parameter ac:name="revision">1</ac:parameter></ac:structured-macro>'
        $result = Get-ConfluenceStorageAttachmentNames -Storage $storage -SiteOrigin $site -PageId '101'
        $result.status | Should -BeExactly 'valid'
        @($result.names) | Should -Contain 'flow.mmd'
    }

    # Scenario: Managed text assets use .mmd and .txt local paths respectively.
    # Purpose: Only text/plain .mmd preserves the .mmd remote extension.
    It 'FidelityT43_resolves_mmd_text_extension_without_changing_txt' {
        Import-Module -Name $assetsModule -Force
        $mmd = Resolve-LocalManagedAsset -Root $script:fixture.root -ProjectionId 'fidelity' -Asset $script:fixture.assets.mmd
        $txt = Resolve-LocalManagedAsset -Root $script:fixture.root -ProjectionId 'fidelity' -Asset $script:fixture.assets.text
        $mmd.status | Should -BeExactly 'valid'
        $mmd.remoteFilename | Should -Match '\.mmd$'
        $txt.status | Should -BeExactly 'valid'
        $txt.remoteFilename | Should -Match '\.txt$'
    }

    # Scenario: Attribute-bearing, uppercase, and otherwise non-exact br spellings appear in Markdown.
    # Purpose: The narrow controlled exception does not admit any broader raw HTML.
    It 'FidelityT50_rejects_non_exact_br_html' {
        foreach ($markdown in @('<br class="x">', '<BR>', '<br data-a="1"/>')) {
            $result = ConvertTo-FidelityStorage -Markdown $markdown -Fixture $script:fixture
            $result.status | Should -BeExactly 'unsupported'
            @($result.reasonCodes) | Should -Contain 'RawHtmlUnsupported'
        }
    }

    # Scenario: Markdown contains a standalone raw HTML block.
    # Purpose: Controlled inline br support does not weaken HtmlBlock rejection.
    It 'FidelityT51_keeps_html_blocks_unsupported' {
        $result = ConvertTo-FidelityStorage -Markdown '<div>x</div>' -Fixture $script:fixture
        $result.status | Should -BeExactly 'unsupported'
        @($result.reasonCodes) | Should -Contain 'RawHtmlUnsupported'
    }

    # Scenario: Code macros use an unsupported parameter/body shape or invalid language.
    # Purpose: Each refusal reports UnsupportedMacroParameter with source XML and location evidence.
    It 'FidelityT52_rejects_unsupported_code_macro_shapes_with_evidence' {
        $cases = @(
            '<ac:structured-macro ac:name="code" ac:schema-version="1"><ac:parameter ac:name="title">Title</ac:parameter><ac:plain-text-body><![CDATA[x]]></ac:plain-text-body></ac:structured-macro>',
            '<ac:structured-macro ac:name="code" ac:schema-version="1"><ac:rich-text-body><p>x</p></ac:rich-text-body></ac:structured-macro>',
            '<ac:structured-macro ac:name="code" ac:schema-version="1"><ac:parameter ac:name="language">text</ac:parameter></ac:structured-macro>',
            '<ac:structured-macro ac:name="code" ac:schema-version="1"><ac:parameter ac:name="language">bad language!</ac:parameter><ac:plain-text-body><![CDATA[x]]></ac:plain-text-body></ac:structured-macro>'
        )
        foreach ($storage in $cases) {
            $result = ConvertFrom-FidelityStorage -Storage $storage
            $result.status | Should -BeExactly 'unsupported'
            @($result.reasonCodes) | Should -Contain 'UnsupportedMacroParameter'
            $record = @($result.unsupported | Where-Object code -ceq 'UnsupportedMacroParameter')[0]
            $record.location | Should -Not -BeNullOrEmpty
            $record.sourceXml | Should -Match 'ac:structured-macro'
        }
    }

    # Scenario: Unknown root macros and a code macro nested in a paragraph are captured.
    # Purpose: The new root-only allowlist does not broaden generic or nested macro support.
    It 'FidelityT53_keeps_unknown_and_nested_macros_unsupported' {
        foreach ($storage in @(
            '<ac:structured-macro ac:name="toc" />',
            '<ac:structured-macro ac:name="expand" />',
            '<p><ac:structured-macro ac:name="code" ac:schema-version="1"><ac:plain-text-body><![CDATA[x]]></ac:plain-text-body></ac:structured-macro></p>'
        )) {
            $result = ConvertFrom-FidelityStorage -Storage $storage
            $result.status | Should -BeExactly 'unsupported'
            @($result.reasonCodes) | Should -Contain 'UnsupportedMacro'
        }
    }

    # Scenario: Mermaid-cloud macros omit or corrupt required parameters or add an unsupported parameter.
    # Purpose: The accepted macro shape remains exactly filename plus positive revision.
    It 'FidelityT54_rejects_invalid_mermaid_cloud_parameters' {
        $cases = @(
            '<ac:structured-macro ac:name="mermaid-cloud" ac:schema-version="1"><ac:parameter ac:name="filename">flow.mmd</ac:parameter></ac:structured-macro>',
            '<ac:structured-macro ac:name="mermaid-cloud" ac:schema-version="1"><ac:parameter ac:name="filename">flow.mmd</ac:parameter><ac:parameter ac:name="revision">0</ac:parameter></ac:structured-macro>',
            '<ac:structured-macro ac:name="mermaid-cloud" ac:schema-version="1"><ac:parameter ac:name="filename">flow.mmd</ac:parameter><ac:parameter ac:name="revision">1</ac:parameter><ac:parameter ac:name="toolbar">true</ac:parameter></ac:structured-macro>',
            '<ac:structured-macro ac:name="mermaid-cloud" ac:schema-version="1"><ac:parameter ac:name="filename">dir/flow.mmd</ac:parameter><ac:parameter ac:name="revision">1</ac:parameter></ac:structured-macro>'
        )
        foreach ($storage in $cases) {
            $result = ConvertFrom-FidelityStorage -Storage $storage
            $result.status | Should -BeExactly 'unsupported'
            @($result.reasonCodes) | Should -Contain 'UnsupportedMacroParameter'
        }
    }

    # Scenario: A managed .mmd image shares its paragraph with ordinary text.
    # Purpose: Mermaid-cloud remains a root block and cannot silently discard adjacent content.
    It 'FidelityT55_rejects_non_block_mmd_image' {
        $result = ConvertTo-FidelityStorage -Markdown 'prefix ![Flow](diagrams/flow.mmd)' -Fixture $script:fixture -ManagedAssets @($script:fixture.assets.mmd)
        $result.status | Should -BeExactly 'unsupported'
        @($result.reasonCodes) | Should -Contain 'MermaidMacroNotBlock'
    }

    # Scenario: A fenced code attribute names an unsupported macro.
    # Purpose: Only the exact data-confluence-macro=code opt-in is accepted.
    It 'FidelityT56_rejects_wrong_code_macro_marker_value' {
        $markdown = @'
```text {data-confluence-macro=toc}
x
```
'@
        $result = ConvertTo-FidelityStorage -Markdown $markdown -Fixture $script:fixture
        $result.status | Should -BeExactly 'unsupported'
        @($result.reasonCodes) | Should -Contain 'UnsupportedAttribute'
    }

    # Scenario: A marked code fence body contains the CDATA terminator sequence.
    # Purpose: Projection blocks a body that cannot be represented by the explicit macro contract.
    It 'FidelityT57_rejects_unrepresentable_code_macro_body' {
        $markdown = @'
```text {data-confluence-macro=code}
a]]>b
```
'@
        $result = ConvertTo-FidelityStorage -Markdown $markdown -Fixture $script:fixture
        $result.status | Should -BeExactly 'unsupported'
        @($result.reasonCodes) | Should -Contain 'MacroBodyUnrepresentable'
    }

    # Scenario: Attachment links are unbound, changed, unsafe, image-typed, or have formatted labels.
    # Purpose: Existing safety reasons and the new label/media constraints remain fail closed.
    It 'FidelityT58_rejects_invalid_attachment_link_cases' {
        $unbound = ConvertTo-FidelityStorage -Markdown '[規格書](files/spec.pdf)' -Fixture $script:fixture
        $unbound.status | Should -BeExactly 'unsupported'
        @($unbound.reasonCodes) | Should -Contain 'LinkProjectionUnsupported'

        $changedAsset = [pscustomobject]@{
            localPath = $script:fixture.assets.pdf.localPath; displayFilename = 'spec.pdf'
            mediaType = 'application/pdf'; sha256 = ('f' * 64)
        }
        $changed = ConvertTo-FidelityStorage -Markdown '[規格書](files/spec.pdf)' -Fixture $script:fixture -ManagedAssets @($changedAsset)
        $changed.status | Should -Not -BeExactly 'supported'
        @($changed.reasonCodes) | Should -Contain 'AssetSourceChanged'

        $unsafe = ConvertTo-FidelityStorage -Markdown '[run](javascript:alert(1))' -Fixture $script:fixture
        $unsafe.status | Should -BeExactly 'unsupported'
        @($unsafe.reasonCodes) | Should -Contain 'UnsafeUrl'

        $imageLink = ConvertTo-FidelityStorage -Markdown '[diagram](files/diagram.png)' -Fixture $script:fixture -ManagedAssets @($script:fixture.assets.png)
        $imageLink.status | Should -BeExactly 'unsupported'
        @($imageLink.reasonCodes) | Should -Contain 'AssetProjectionUnsupported'

        $formatted = ConvertTo-FidelityStorage -Markdown '[**粗體**](files/spec.pdf)' -Fixture $script:fixture -ManagedAssets @($script:fixture.assets.pdf)
        $formatted.status | Should -BeExactly 'unsupported'
        @($formatted.reasonCodes) | Should -Contain 'AttachmentLinkLabelUnsupported'
    }

    # Scenario: Storage ac:link points to a page instead of an attachment.
    # Purpose: Attachment-link support does not admit other Confluence link shapes.
    It 'FidelityT59_keeps_page_ac_link_unsupported' {
        $storage = '<p><ac:link><ri:page ri:content-title="Other" /></ac:link></p>'
        $result = ConvertFrom-FidelityStorage -Storage $storage
        $result.status | Should -BeExactly 'unsupported'
        @($result.reasonCodes) | Should -Contain 'UnsupportedNode'
    }

    # Scenario: A mermaid managed asset already exists remotely at version two while the macro requires revision one.
    # Purpose: Preview blocks the plan after read-only observation and never issues a write request.
    It 'FidelityT60_blocks_mermaid_revision_conflict_with_get_only_preview' {
        Import-Module -Name $planModule -Force
        $script:planCalls = [System.Collections.Generic.List[object]]::new()
        $script:planMode = 'mmd-version-2'
        $script:planRemoteFilename = "syp171-fidelity-$($script:fixture.assets.mmd.sha256).mmd"
        $body = '<ac:structured-macro ac:name="mermaid-cloud" ac:schema-version="1"><ac:parameter ac:name="filename">' + $script:planRemoteFilename + '</ac:parameter><ac:parameter ac:name="revision">1</ac:parameter></ac:structured-macro>'
        $payload = @([pscustomobject]@{
            projectionId = 'fidelity'; pageId = '101'; spaceId = '55'; parentId = '99'; title = 'Synthetic fidelity page'
            bodyStorage = $body; assetChanges = @($script:fixture.assets.mmd)
        })
        $result = New-ConfluencePreviewPlan -PlanPath (Join-Path $script:fixture.root 'mermaid-plan.json') `
            -Validation (New-FidelityValidation) -Payloads $payload -ExpectedSiteOrigin $site -ApiBase $api `
            -HttpInvoker (New-FidelityPlanHttp) -ValidationInputs ([ordered]@{ root = $script:fixture.root; mappingPath = '.confluence/mapping.json'; docsCommit = ('1' * 40) })
        $result.status | Should -BeExactly 'blocked'
        @($result.reasonCodes) | Should -Contain 'MermaidRevisionConflict'
        $script:planCalls.Count | Should -BeGreaterThan 0
        @($script:planCalls | Where-Object Method -cne 'GET').Count | Should -Be 0
    }

    # Scenario: Preview stages a body containing a code macro and a managed PDF attachment link.
    # Purpose: Preview remains read-only even when the new fidelity constructs are present.
    It 'FidelityT61_previews_code_macro_and_attachment_link_with_get_only_http' {
        Import-Module -Name $planModule -Force
        $script:planCalls = [System.Collections.Generic.List[object]]::new()
        $script:planMode = 'empty'
        $script:planRemoteFilename = "syp171-fidelity-$($script:fixture.assets.pdf.sha256).pdf"
        $body = '<ac:structured-macro ac:name="code" ac:schema-version="1"><ac:parameter ac:name="language">powershell</ac:parameter><ac:plain-text-body><![CDATA[Write-Output ok]]></ac:plain-text-body></ac:structured-macro><p><ac:link><ri:attachment ri:filename="' + $script:planRemoteFilename + '" /><ac:plain-text-link-body><![CDATA[規格書]]></ac:plain-text-link-body></ac:link></p>'
        $payload = @([pscustomobject]@{
            projectionId = 'fidelity'; pageId = '101'; spaceId = '55'; parentId = '99'; title = 'Synthetic fidelity page'
            bodyStorage = $body; assetChanges = @($script:fixture.assets.pdf)
        })
        $result = New-ConfluencePreviewPlan -PlanPath (Join-Path $script:fixture.root 'readonly-plan.json') `
            -Validation (New-FidelityValidation) -Payloads $payload -ExpectedSiteOrigin $site -ApiBase $api `
            -HttpInvoker (New-FidelityPlanHttp) -ValidationInputs ([ordered]@{ root = $script:fixture.root; mappingPath = '.confluence/mapping.json'; docsCommit = ('1' * 40) })
        $result.status | Should -BeExactly 'preview'
        $script:planCalls.Count | Should -BeGreaterThan 0
        @($script:planCalls | Where-Object Method -cne 'GET').Count | Should -Be 0
    }
}
