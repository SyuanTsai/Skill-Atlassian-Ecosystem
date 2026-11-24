# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'skills/manage-confluence-docs-as-code/scripts/ConfluenceStorage.psm1'
    if (Test-Path -LiteralPath $modulePath) { Import-Module $modulePath -Force }
}

Describe 'SYP-171 storage readback preserves structure and text' {
    # Scenario: SYP171-SCN-012; server serializes equivalent XML differently.
    # Purpose: Entity, CDATA, namespace prefix and attribute order do not cause a false mismatch.
    It 'UnitT10_accepts_only_equivalent_XML_serialization' {
        $expected='<p class="note" title="A &amp; B">A &amp; B</p><ac:structured-macro ac:name="mermaid"><ac:plain-text-body><![CDATA[graph TD; A-->B]]></ac:plain-text-body></ac:structured-macro>'
        $actual='<p title="A &#38; B" class="note">A &#38; B</p><ac:structured-macro ac:name="mermaid"><ac:plain-text-body>graph TD; A--&gt;B</ac:plain-text-body></ac:structured-macro>'
        Test-ConfluenceStorageEquivalent -Expected $expected -Actual $actual | Should -BeTrue
        Test-ConfluenceStorageEquivalent -Expected '<ac:structured-macro ac:name="info" />' -Actual '<other:structured-macro xmlns:other="http://atlassian.com/content" other:name="info" />' | Should -BeTrue
    }

    # Scenario: SYP171-SCN-012; server adds one missing structured macro UUID.
    # Purpose: Accept the documented server-only identity without losing explicit source identities.
    It 'UnitT20_accepts_a_server_UUID_only_where_source_has_no_macro_ID' {
        $expected='<ac:structured-macro ac:name="info"><ac:rich-text-body><p>Exact</p></ac:rich-text-body></ac:structured-macro>'
        $actual=$expected.Replace('ac:name="info"','ac:macro-id="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" ac:name="info"')
        Test-ConfluenceStorageEquivalent -Expected $expected -Actual $actual | Should -BeTrue
        Test-ConfluenceStorageEquivalent -Expected $actual -Actual $expected | Should -BeFalse
        Test-ConfluenceStorageEquivalent -Expected $actual -Actual $actual.Replace('aaaaaaaa','bbbbbbbb') | Should -BeFalse
    }

    # Scenario: The renderer emits heading ids and Confluence stores the same headings without them.
    # Purpose: Only the removal of a payload heading id is tolerated; changed, added, or non-heading ids still differ.
    It 'UnitT25_accepts_server_stripped_heading_ids_only' {
        $expected='<h1 id="overview">Overview</h1><h2 id="setup-steps">Setup <strong>steps</strong></h2><h6 id="x">X</h6><p>Body</p>'
        $actual='<h1>Overview</h1><h2>Setup <strong>steps</strong></h2><h6>X</h6><p>Body</p>'
        Test-ConfluenceStorageEquivalent -Expected $expected -Actual $actual | Should -BeTrue
        Test-ConfluenceStorageEquivalent -Expected $expected -Actual $expected | Should -BeTrue
        Test-ConfluenceStorageEquivalent -Expected $actual -Actual $expected | Should -BeFalse
        Test-ConfluenceStorageEquivalent -Expected '<h2 id="setup">Setup</h2>' -Actual '<h2 id="other">Setup</h2>' | Should -BeFalse
        Test-ConfluenceStorageEquivalent -Expected '<h2 id="setup">Setup</h2>' -Actual '<h2>Setup changed</h2>' | Should -BeFalse
        Test-ConfluenceStorageEquivalent -Expected '<h2 id="setup" class="a">Setup</h2>' -Actual '<h2>Setup</h2>' | Should -BeFalse
        Test-ConfluenceStorageEquivalent -Expected '<p id="setup">Setup</p>' -Actual '<p>Setup</p>' | Should -BeFalse
    }

    # Scenario: Confluence returns XHTML named entities such as &mdash; and &nbsp; where the payload has the literal characters.
    # Purpose: The shared storage reader decodes known named entities outside CDATA and still fails closed on unknown or malformed ones.
    It 'UnitT27_decodes_XHTML_named_entities_and_fails_closed_on_unknown_ones' {
        $dash=[string][char]0x2014;$nbsp=[string][char]0x00A0;$rsquo=[string][char]0x2019
        $payload="<h2>Design $dash notes</h2><p>Keep${nbsp}together, it${rsquo}s fine &amp; safe.</p><p><a href=`"https://example.atlassian.net/wiki/x`" title=`"A $dash B`">x</a></p>"
        $remote='<h2>Design &mdash; notes</h2><p>Keep&nbsp;together, it&rsquo;s fine &amp; safe.</p><p><a href="https://example.atlassian.net/wiki/x" title="A &mdash; B">x</a></p>'
        Test-ConfluenceStorageEquivalent -Expected $payload -Actual $remote | Should -BeTrue
        Test-ConfluenceStorageEquivalent -Expected $remote -Actual $payload | Should -BeTrue
        Test-ConfluenceStorageEquivalent -Expected '<p>A &ndash; B</p>' -Actual '<p>A &mdash; B</p>' | Should -BeFalse

        $cdata='<ac:structured-macro ac:name="code"><ac:plain-text-body><![CDATA[x &mdash; y]]></ac:plain-text-body></ac:structured-macro>'
        Test-ConfluenceStorageEquivalent -Expected $cdata -Actual $cdata | Should -BeTrue
        Test-ConfluenceStorageEquivalent -Expected $cdata -Actual $cdata.Replace('&mdash;',$dash) | Should -BeFalse

        Test-ConfluenceStorageEquivalent -Expected '<p>&bogusentity;</p>' -Actual '<p>&bogusentity;</p>' | Should -BeFalse
        Test-ConfluenceStorageEquivalent -Expected '<p>A &mdash B</p>' -Actual '<p>A &mdash B</p>' | Should -BeFalse

        $names=Get-ConfluenceStorageAttachmentNames -Storage '<p>Diagram &mdash; v2</p><ac:image><ri:attachment ri:filename="flow&ndash;v2.png" /></ac:image>' -SiteOrigin 'https://example.atlassian.net' -PageId '101'
        $names.status | Should -BeExactly 'valid'
        @($names.names) | Should -Be @("flow$([char]0x2013)v2.png")
        (Get-ConfluenceStorageAttachmentNames -Storage '<p>&bogusentity;</p>' -SiteOrigin 'https://example.atlassian.net' -PageId '101').status | Should -BeExactly 'invalid'
    }

    # Scenario: A real target body uses named entities around retained diagrams, links, and headings.
    # Purpose: The content-removal inventory parses it, compares it to a literal-character payload, and still fails closed on unknown entities.
    It 'UnitT28_content_inventory_reads_named_entities' {
        $dash=[string][char]0x2014;$nbsp=[string][char]0x00A0
        $macro='<ac:structured-macro ac:name="mermaid-cloud"><ac:parameter ac:name="filename">flow.mmd</ac:parameter></ac:structured-macro>'
        $baseline="<h2>Design &mdash; record</h2><p>Text&nbsp;here</p>$macro<p><ac:link><ri:page ri:content-title=`"Related &ndash; page`" /></ac:link></p>"
        $same="<h2>Design $dash record</h2><p>Text${nbsp}here</p>$macro<p><ac:link><ri:page ri:content-title=`"Related $([char]0x2013) page`" /></ac:link></p>"
        $result=Compare-ConfluenceStorageContent -Baseline $baseline -Payload $same -SiteOrigin 'https://example.atlassian.net'
        $result.status | Should -BeExactly 'valid'
        @($result.removed).Count | Should -Be 0
        $result.blocking | Should -BeFalse

        $dropped=Compare-ConfluenceStorageContent -Baseline $baseline -Payload "<h2>Design $dash record</h2><p>Text${nbsp}here</p>" -SiteOrigin 'https://example.atlassian.net'
        $dropped.status | Should -BeExactly 'valid'
        @($dropped.removed|ForEach-Object {"$($_.kind):$($_.key)"}) | Should -Be @('macro:mermaid-cloud','attachment:flow.mmd',"pageLink:title:Related $([char]0x2013) page")

        (Compare-ConfluenceStorageContent -Baseline '<p>&bogusentity;</p>' -Payload '<p>x</p>' -SiteOrigin 'https://example.atlassian.net').status | Should -BeExactly 'invalid'
    }

    # Scenario: Confluence saves a rendered page with editor ids, table layout defaults, no thead, <p>-wrapped cells, and indentation.
    # Purpose: The shared comparison accepts exactly that editor normalization so unchanged pages are no-ops and readback succeeds.
    It 'UnitT26_tolerates_Confluence_editor_normalization' {
        $payload='<h1 id="flow">Flow</h1><p>Intro <strong>bold</strong> and <code>code</code>.</p><table><thead><tr><th>Stage</th><th>Owner</th></tr></thead><tbody><tr><td>Build</td><td>CI</td></tr><tr><td>Ship</td><td></td></tr></tbody></table><ul><li>one</li><li>two <a href="https://example.atlassian.net/wiki/pages/viewpage.action?pageId=102#setup">Setup</a></li></ul>'
        $remote=@'
<h1 local-id="0a1b2c3d-0000-4000-8000-000000000001">Flow</h1>
<p local-id="5e6f7a8b9c0d">Intro <strong>bold</strong> and <code>code</code>.</p>
<table data-table-width="760" data-layout="default" ac:local-id="11111111-2222-4333-8444-555555555555">
  <tbody>
    <tr ac:local-id="a1"><th ac:local-id="b1"><p local-id="c1">Stage</p></th><th ac:local-id="b2"><p>Owner</p></th></tr>
    <tr><td ac:local-id="b3"><p>Build</p></td><td><p>CI</p></td></tr>
    <tr><td><p>Ship</p></td><td><p /></td></tr>
  </tbody>
</table>
<ul local-id="d1">
  <li local-id="e1">one</li>
  <li local-id="e2">two <a href="https://example.atlassian.net/wiki/pages/viewpage.action?pageId=102#setup">Setup</a></li>
</ul>
'@
        Test-ConfluenceStorageEquivalent -Expected $payload -Actual $remote | Should -BeTrue
        Test-ConfluenceStorageEquivalent -Expected $payload -Actual $remote.Replace('<tbody>','<thead><tr><th>Stage</th><th>Owner</th></tr></thead><tbody>').Replace('<tr ac:local-id="a1"><th ac:local-id="b1"><p local-id="c1">Stage</p></th><th ac:local-id="b2"><p>Owner</p></th></tr>','') | Should -BeTrue
        Test-ConfluenceStorageEquivalent -Expected $payload -Actual $payload | Should -BeTrue
    }

    # Scenario: A normalized Confluence body also differs in author-visible content or in an attribute outside the editor set.
    # Purpose: Editor normalization never hides changed text, structure, links, formatting, or unknown attributes.
    It 'UnitT29_editor_normalization_stays_conservative' {
        $payload='<p>Intro <strong>bold</strong> and <code>code</code>.</p><table><thead><tr><th>Stage</th><th>Owner</th></tr></thead><tbody><tr><td>Build</td><td>CI</td></tr></tbody></table><ul><li>one <a href="https://example.atlassian.net/wiki/pages/viewpage.action?pageId=102">x</a></li></ul>'
        $remote='<p local-id="p1">Intro <strong>bold</strong> and <code>code</code>.</p> <table data-table-width="760" data-layout="default" ac:local-id="t1"><tbody><tr><th><p>Stage</p></th><th><p>Owner</p></th></tr><tr><td><p>Build</p></td><td><p>CI</p></td></tr></tbody></table> <ul><li local-id="l1">one <a href="https://example.atlassian.net/wiki/pages/viewpage.action?pageId=102">x</a></li></ul>'
        Test-ConfluenceStorageEquivalent -Expected $payload -Actual $remote | Should -BeTrue
        $changes=[ordered]@{
            cellText=@('<p>CI</p>','<p>CD</p>')
            addedRow=@('</tbody>','<tr><td><p>New</p></td><td><p>Row</p></td></tr></tbody>')
            removedRow=@('<tr><td><p>Build</p></td><td><p>CI</p></td></tr>','')
            addedCell=@('<td><p>CI</p></td>','<td><p>CI</p></td><td><p>Extra</p></td>')
            removedCell=@('<td><p>CI</p></td>','')
            href=@('pageId=102">x','pageId=103">x')
            strong=@('<strong>bold</strong>','<em>bold</em>')
            code=@('<code>code</code>','code')
            cellFormatting=@('<p>Build</p>','<p><strong>Build</strong></p>')
            twoParagraphCell=@('<p>Build</p>','<p>Build</p><p>More</p>')
            unknownAttribute=@('data-layout="default"','data-layout="default" data-foo="x"')
            otherLayout=@('data-layout="default"','data-layout="wide"')
            classOnParagraph=@('<p local-id="p1">','<p local-id="p1" class="note">')
            localIdOnInline=@('<strong>bold</strong>','<strong local-id="s1">bold</strong>')
            textBetweenBlocks=@('</p> <table','</p> Extra <table')
            spaceInsideParagraph=@('Intro <strong>','Intro<strong>')
        }
        foreach($name in $changes.Keys){
            $changed=$remote.Replace($changes[$name][0],$changes[$name][1])
            $changed | Should -Not -BeExactly $remote -Because $name
            Test-ConfluenceStorageEquivalent -Expected $payload -Actual $changed | Should -BeFalse -Because $name
        }
        Test-ConfluenceStorageEquivalent -Expected $remote -Actual $payload | Should -BeFalse
    }

    # Scenario: SYP171-SCN-012; a remote field or node differs from the frozen payload.
    # Purpose: Serialization handling never erases body, attribute, ordering or whitespace differences.
    It 'UnitT30_rejects_changed_text_attributes_and_child_order' {
        $expected='<p title="exact">A B</p><p>C</p>'
        foreach($actual in @('<p title="exact">AB</p><p>C</p>','<p title="changed">A B</p><p>C</p>','<p>C</p><p title="exact">A B</p>')) {
            Test-ConfluenceStorageEquivalent -Expected $expected -Actual $actual | Should -BeFalse
        }
    }

    # Scenario: SYP171-SCN-009/012; remote adds a lookalike attribute or malformed identity.
    # Purpose: Ignore only the exact ac structured-macro identity addition, not arbitrary extra attributes.
    It 'UnitT40_rejects_macro_identity_exceptions_outside_the_exact_contract' {
        foreach($actual in @('<p ac:macro-id="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa">Exact</p>','<p extra="x">Exact</p>')) {
            Test-ConfluenceStorageEquivalent -Expected '<p>Exact</p>' -Actual $actual | Should -BeFalse
        }
        Test-ConfluenceStorageEquivalent -Expected '<ac:structured-macro ac:name="info" />' -Actual '<ac:structured-macro ac:name="info" ac:macro-id="unverified" />' | Should -BeFalse
    }

    # Scenario: SYP171-SCN-009; the remote response contains DTD or invalid XML.
    # Purpose: Readback comparison cannot resolve external entities or treat failed parsing as equality.
    It 'UnitT50_rejects_DTD_and_invalid_XML_without_resolution' {
        Test-ConfluenceStorageEquivalent -Expected '<p>Exact</p>' -Actual '<!DOCTYPE p [<!ENTITY injected SYSTEM "file:///synthetic-secret">]><p>&injected;</p>' | Should -BeFalse
        Test-ConfluenceStorageEquivalent -Expected '<p>' -Actual '<p>' | Should -BeFalse
    }
}
