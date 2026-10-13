# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $repositoryRoot = Split-Path -Parent $PSScriptRoot
    $modulePath = Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/MarkdownProjection.psm1'

    function New-MarkdownFixture {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('syp171-markdown-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $root 'docs') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'assets') -Force | Out-Null
        $bytes = [byte[]]@(137,80,78,71,13,10,26,10,1,2,3,4)
        [IO.File]::WriteAllBytes((Join-Path $root 'assets/diagram.png'), $bytes)
        $sha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        return [pscustomobject]@{
            root = $root
            asset = [pscustomobject]@{ localPath = 'assets/diagram.png'; displayFilename = 'diagram.png'; mediaType = 'image/png'; sha256 = $sha }
        }
    }

    function Remove-MarkdownFixture {
        param([Parameter(Mandatory)][string] $Root)
        $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path)
        $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
        if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\','/') -cne $parent -or
            [IO.Path]::GetFileName($resolved) -cnotmatch '^syp171-markdown-[a-f0-9]{32}$') { throw 'Unsafe Markdown fixture delete' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }

    function Invoke-MarkdownProjection {
        param(
            [Parameter(Mandatory)][string] $Markdown,
            [Parameter(Mandatory)] $Fixture,
            [object[]] $ManagedAssets = @(),
            [object[]] $LinkBindings = @(),
            [object[]] $PageMappings = @(),
            [System.Collections.IDictionary] $SourceSnapshots,
            [string] $SiteOrigin = ''
        )
        if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) { throw 'MarkdownProjection production module is missing.' }
        Import-Module -Name $modulePath -Force
        return ConvertTo-ConfluenceMarkdownStorage -Markdown $Markdown -Root $Fixture.root -SourcePath 'docs/spec.md' `
            -ProjectionId 'docs-spec' -ManagedAssets $ManagedAssets -LinkBindings $LinkBindings `
            -PageMappings $PageMappings -SourceSnapshots $SourceSnapshots -SiteOrigin $SiteOrigin
    }
}

Describe 'SYP-171 general Markdown projection' {
    BeforeEach { $script:fixture = New-MarkdownFixture }
    AfterEach { Remove-MarkdownFixture -Root $script:fixture.root }

    # Scenario: A UTF-8 Markdown document uses headings, lists, tables, code, safe links, and a bound local image.
    # Purpose: Test projection must preserve supported content in Confluence storage using PowerShell alone.
    It 'UnitT10_projects_common_document_content_and_bound_attachment_without_runtime' {
        $markdown = @'
# 概覽

保留 **重點**、*強調*、`inline-code` 與 [來源](https://example.invalid/guide)。

- 第一項
- 第二項

| 欄位 | 值 |
| --- | --- |
| 狀態 | 已確認 |

```powershell
Write-Output 'exact bytes'
```

![流程圖](../assets/diagram.png)
'@
        $result = Invoke-MarkdownProjection -Markdown $markdown -Fixture $script:fixture -ManagedAssets @($script:fixture.asset)
        $result.status | Should -Be 'supported'
        $result.storage | Should -Match '<h1(?: id="[^"]+")?>概覽</h1>'
        $result.storage | Should -Match '<strong>重點</strong>'
        $result.storage | Should -Match '<em>強調</em>'
        $result.storage | Should -Match '<code>inline-code</code>'
        $result.storage | Should -Match '<ul>'
        $result.storage | Should -Match '<table>'
        $result.storage | Should -Match 'Write-Output ''exact bytes'''
        $result.storage | Should -Match 'href="https://example.invalid/guide"'
        $result.storage | Should -Match 'ri:filename="syp171-docs-spec-'
        @($result.assets).Count | Should -Be 1
        $result.bodySha256 | Should -Match '^[a-f0-9]{64}$'
    }

    # Scenario: A Markdown link uses an executable URL scheme.
    # Purpose: Unsafe targets must block the projection instead of becoming ordinary text or a publishable link.
    It 'UnitT20_rejects_unsafe_links' {
        $result = Invoke-MarkdownProjection -Markdown '[run](javascript:alert(1))' -Fixture $script:fixture
        $result.status | Should -Be 'unsupported'
        @($result.reasonCodes) | Should -Contain 'UnsafeUrl'
        @($result.unsupported).Count | Should -BeGreaterThan 0
    }

    # Scenario: Markdown code contains text that resembles HTML markup.
    # Purpose: Fenced and inline code must preserve literal source text without treating it as active HTML.
    It 'UnitT25_preserves_HTML_like_text_inside_code' {
        $markdown = @'
`inline <script>`

````html
<script>literal</script>
````
'@
        $result = Invoke-MarkdownProjection -Markdown $markdown -Fixture $script:fixture
        $result.status | Should -Be 'supported'
        $result.storage | Should -Match '&lt;script&gt;'
    }

    # Scenario: A code payload contains only spaces and a line ending, beside inline emphasis and link elements.
    # Purpose: XML projection must preserve whitespace-only code bytes and separators between adjacent inline elements.
    It 'UnitT27_preserves_code_whitespace_and_inline_separators' {
        $markdown = @'
` `

```text
__WHITESPACE_ONLY_CODE_LINE__
```

**First** **Second** and *one* *two*.

**bold** *italic* [link](https://example.invalid)
'@
        $markdown = $markdown.Replace('__WHITESPACE_ONLY_CODE_LINE__', (' ' * 3))
        $result = Invoke-MarkdownProjection -Markdown $markdown -Fixture $script:fixture
        $result.status | Should -Be 'supported'
        $result.storage | Should -Match '<code> </code>'
        $result.storage | Should -Match '<pre><code(?: class="language-text")?>\s{3}\r?\n</code></pre>'
        $result.storage | Should -Match '<strong>First</strong> <strong>Second</strong> and <em>one</em> <em>two</em>\.'
        $result.storage | Should -Match '</strong> <em>italic</em> <a href="https://example.invalid">link</a>'
    }

    # Scenario: A Markdown document embeds raw HTML that can bypass the supported Markdown projection.
    # Purpose: Unreviewed markup must remain a blocking unsupported item.
    It 'UnitT30_rejects_raw_html' {
        $result = Invoke-MarkdownProjection -Markdown '<script>alert(1)</script>' -Fixture $script:fixture
        $result.status | Should -Be 'unsupported'
        @($result.reasonCodes) | Should -Contain 'RawHtmlUnsupported'
    }

    # Scenario: A Markdown file contains an HTML comment that the rendered output would otherwise omit.
    # Purpose: Comments and other non-Markdown blocks must not silently disappear from a source projection.
    It 'UnitT35_rejects_HTML_comments' {
        $result = Invoke-MarkdownProjection -Markdown "<!-- reviewer note -->`n`nVisible paragraph" -Fixture $script:fixture
        $result.status | Should -Be 'unsupported'
        @($result.reasonCodes) | Should -Contain 'RawHtmlUnsupported'
    }

    # Scenario: A Markdown image refers to an external or unbound file.
    # Purpose: Image targets must bind to an exact checked attachment before preview can carry them forward.
    It 'UnitT40_rejects_unbound_images' {
        $external = Invoke-MarkdownProjection -Markdown '![remote](https://example.invalid/image.png)' -Fixture $script:fixture
        $external.status | Should -Be 'unsupported'
        @($external.reasonCodes) | Should -Contain 'AssetProjectionUnsupported'

        $missingBinding = Invoke-MarkdownProjection -Markdown '![flow](../assets/diagram.png)' -Fixture $script:fixture
        $missingBinding.status | Should -Be 'unsupported'
        @($missingBinding.reasonCodes) | Should -Contain 'AssetProjectionUnsupported'
    }

    # Scenario: The same managed image appears more than once and includes a Markdown title.
    # Purpose: Repeated references must remain in the page while the immutable attachment is planned once and title text is preserved.
    It 'UnitT45_preserves_repeated_images_and_titles' {
        $markdown = '![flow](../assets/diagram.png "Flow overview") and ![flow again](../assets/diagram.png "Flow overview")'
        $result = Invoke-MarkdownProjection -Markdown $markdown -Fixture $script:fixture -ManagedAssets @($script:fixture.asset)
        $result.status | Should -Be 'supported'
        @($result.assets).Count | Should -Be 1
        ([regex]::Matches($result.storage,'<ac:image')).Count | Should -Be 2
        ([regex]::Matches($result.storage,'ac:title="Flow overview"')).Count | Should -Be 2
    }

    # Scenario: A link points to another mapped page that will be created in the same operation and names its section.
    # Purpose: Identity-first link resolution must retain the destination fragment until the new page identity is known.
    It 'UnitT47_preserves_fragment_for_deferred_target' {
        $bindings = @([pscustomobject]@{ href='../docs/setup.md#setup'; targetProjectionId='setup-guide' })
        [IO.File]::WriteAllText((Join-Path $script:fixture.root 'docs/setup.md'),'# Setup',[Text.UTF8Encoding]::new($false))
        $mappings = @([pscustomobject]@{
            projectionId='setup-guide'; sourceArtifact='docs/setup.md'; sourceSectionId='document'; pageId=''
        })
        $result = Invoke-MarkdownProjection -Markdown '[Setup](../docs/setup.md#setup)' -Fixture $script:fixture `
            -LinkBindings $bindings -PageMappings $mappings -SiteOrigin 'https://example.atlassian.net'
        $result.status | Should -Be 'deferred'
        @($result.deferredTargets) | Should -Contain 'setup-guide'
        $result.storageTemplate | Should -Match 'pageId=__SYP171_LINK_setup-guide__#setup'
        $bindings[0].href='../docs/setup.md#missing'
        $wrongAnchor = Invoke-MarkdownProjection -Markdown '[Setup](../docs/setup.md#missing)' -Fixture $script:fixture `
            -LinkBindings $bindings -PageMappings $mappings -SiteOrigin 'https://example.atlassian.net'
        $wrongAnchor.status | Should -Be 'unsupported'
        @($wrongAnchor.reasonCodes) | Should -Contain 'LinkProjectionUnsupported'
    }

    # Scenario: The checkout target contains a heading absent from the selected committed-source snapshot.
    # Purpose: Cross-page fragments must resolve against the exact content bytes bound to docsCommit, not mutable worktree files.
    It 'UnitT47b_uses_committed_source_snapshot_for_cross_page_heading_anchors' {
        [IO.File]::WriteAllText((Join-Path $script:fixture.root 'docs/setup.md'),'# Setup',[Text.UTF8Encoding]::new($false))
        $snapshots=[System.Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
        $snapshots.Add('docs/setup.md','# Different title')
        $bindings=@([pscustomobject]@{href='../docs/setup.md#setup';targetProjectionId='setup-guide'})
        $mappings=@([pscustomobject]@{projectionId='setup-guide';sourceArtifact='docs/setup.md';sourceSectionId='document';pageId=''})
        $result=Invoke-MarkdownProjection -Markdown '[Setup](../docs/setup.md#setup)' -Fixture $script:fixture `
            -LinkBindings $bindings -PageMappings $mappings -SourceSnapshots $snapshots -SiteOrigin 'https://example.atlassian.net'
        $result.status | Should -Be 'unsupported'
        @($result.reasonCodes) | Should -Contain 'LinkProjectionUnsupported'
    }

    # Scenario: A Markdown link refers to a heading in its own document or to an absent fragment.
    # Purpose: Local anchors are publishable only when the renderer created the matching heading id.
    It 'UnitT48_validates_local_heading_anchor' {
        $valid = Invoke-MarkdownProjection -Markdown "# Setup`n`n[Jump](#setup)" -Fixture $script:fixture
        $valid.status | Should -Be 'supported'
        $missing = Invoke-MarkdownProjection -Markdown "# Setup`n`n[Jump](#absent)" -Fixture $script:fixture
        $missing.status | Should -Be 'unsupported'
        @($missing.reasonCodes) | Should -Contain 'UnsafeUrl'
    }

    # Scenario: A Markdown document contains a syntactically valid block outside the supported projection set.
    # Purpose: Unsupported content must stop preview rather than disappear from the generated page body.
    It 'UnitT50_rejects_unsupported_block_content' {
        $result = Invoke-MarkdownProjection -Markdown '> quoted content' -Fixture $script:fixture
        $result.status | Should -Be 'unsupported'
        @($result.unsupported).Count | Should -BeGreaterThan 0
    }
}
