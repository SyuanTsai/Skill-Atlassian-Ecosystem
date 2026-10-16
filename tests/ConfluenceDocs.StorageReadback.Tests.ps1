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
