# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluenceMapping.psm1'
$site = 'https://example.atlassian.net'
$cloud = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'

function New-MappingFixture {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('syp171-mapping-tests-'+[Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $root 'docs') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $root 'docs/spec.md'),'# Native source',[Text.UTF8Encoding]::new($false))
    return $root
}

function Remove-MappingFixture {
    param([string] $Root)
    if (-not (Test-Path -LiteralPath $Root)) { return }
    $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\','/') -cne $parent -or [IO.Path]::GetFileName($resolved) -cnotmatch '^syp171-mapping-tests-[a-f0-9]{32}$') { throw 'Unsafe mapping fixture delete.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

function New-MappingData {
    return [ordered]@{
        schemaVersion=1; adapter=@{ id='openspec-native'; version='1.13.0' }
        siteOrigin=$site; cloudId=$cloud
        entries=@(
            @{ projectionId='req-001'; sourceArtifact='docs/spec.md'; sourceSectionId='SYP171-REQ-001'; pageId='101'; spaceId='55'; parentId='99'; title='Original'; assets=@() },
            @{ projectionId='req-002'; sourceArtifact='docs/spec.md'; sourceSectionId='SYP171-REQ-002'; pageId='102'; spaceId='55'; parentId='99'; title='Second'; assets=@() }
        )
    }
}

function Invoke-MappingFixture {
    param($Data)
    if (-not (Test-Path -LiteralPath $modulePath)) { throw 'Mapping module missing.' }
    Import-Module -Name $modulePath -Force
    $path=Join-Path $script:fixtureRoot 'mapping.json'
    [IO.File]::WriteAllText($path,($Data|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
    return Test-ConfluenceMapping -Root $script:fixtureRoot -MappingPath $path -ExpectedSiteOrigin $site
}

}

Describe 'SYP-171 identity mapping' {
    BeforeEach { $script:fixtureRoot=New-MappingFixture }
    AfterEach { Remove-MappingFixture -Root $script:fixtureRoot }

    # Scenario: SYP171-SCN-005; one page identity may appear only once.
    # Purpose: Duplicated page IDs block title-based accidental ownership.
    It 'UnitT10_rejects_duplicate_page_identity' {
        $data=New-MappingData; $data.entries[1].pageId='101'
        $r=Invoke-MappingFixture $data
        $r.status | Should -Be 'invalid'
        @($r.reasonCodes) | Should -Contain 'DuplicatePageIdentity'
    }

    # Scenario: SYP171-SCN-005; source paths must stay inside the selected adopter root.
    # Purpose: Traversal and case collision are rejected before publication.
    It 'UnitT20_rejects_traversal_and_case_collision' {
        $data=New-MappingData; $data.entries[0].sourceArtifact='../outside.md'
        $r=Invoke-MappingFixture $data
        @($r.reasonCodes) | Should -Contain 'UnsafeSourcePath'
        $data=New-MappingData; $data.entries[1].sourceArtifact='DOCS/Spec.md'
        $r=Invoke-MappingFixture $data
        @($r.reasonCodes) | Should -Contain 'CaseCollision'
    }

    # Scenario: SYP171-SCN-005; a title changes but projection/page IDs do not.
    # Purpose: Rename stays bound to the selected page rather than creating a new page.
    It 'UnitT30_preserves_identity_when_title_changes' {
        $data=New-MappingData; $data.entries[0].title='Renamed'
        $r=Invoke-MappingFixture $data
        $r.status | Should -Be 'valid'
        $r.entries[0].pageId | Should -Be '101'
        $r.entries[0].projectionId | Should -Be 'req-001'
    }

    # Scenario: SYP171-SCN-005; accepted mapping bytes include their original whitespace.
    # Purpose: The returned identity digest covers the exact validated snapshot, not reserialized JSON.
    It 'UnitT35_hashes_the_exact_accepted_mapping_bytes' {
        $r=Invoke-MappingFixture (New-MappingData)
        $bytes=[IO.File]::ReadAllBytes((Join-Path $script:fixtureRoot 'mapping.json'))
        $expected=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        $r.status | Should -Be 'valid'
        $r.mappingSha256 | Should -BeExactly $expected
    }

    # Scenario: SYP171-SCN-005/008; malformed operational JSON is supplied at the public mapping entry.
    # Purpose: Duplicate keys, comments, trailing commas and invalid UTF-8 fail before publication.
    It 'UnitT36_rejects_invalid_json_bytes_and_duplicate_keys' {
        Import-Module -Name $modulePath -Force
        $path=Join-Path $script:fixtureRoot 'mapping.json'
        $valid=(New-MappingData)|ConvertTo-Json -Depth 10 -Compress
        $invalid=@(
            [Text.Encoding]::UTF8.GetBytes($valid.Replace('"schemaVersion":1','"schemaVersion":1,"schemaVersion":1')),
            [Text.Encoding]::UTF8.GetBytes($valid.Replace('"version":"1.13.0"','"version":"1.13.0","version":"1.13.0"')),
            [Text.Encoding]::UTF8.GetBytes($valid.Insert(1,'/* comment */')),
            [Text.Encoding]::UTF8.GetBytes($valid.Substring(0,$valid.Length-1)+',}'),
            [byte[]]@(0xff,0xfe),
            [byte[]]@()
        )
        foreach($bytes in $invalid){
            [IO.File]::WriteAllBytes($path,$bytes)
            $r=Test-ConfluenceMapping -Root $script:fixtureRoot -MappingPath $path -ExpectedSiteOrigin $site
            $r.status | Should -Be 'invalid'
            @($r.reasonCodes) | Should -Contain 'MappingSchemaInvalid'
            $r.mappingSha256 | Should -BeExactly ''
        }
    }

    # Scenario: SYP171-SCN-005; the original 4 MiB mapping limit is reached and exceeded by one byte.
    # Purpose: Shared parsing preserves the caller's exact inclusive size boundary and rejection result.
    It 'UnitT37_preserves_the_mapping_size_boundary' {
        $null=Invoke-MappingFixture (New-MappingData)
        $path=Join-Path $script:fixtureRoot 'mapping.json'
        $original=[IO.File]::ReadAllBytes($path)
        $bytes=[byte[]]::new(4MB)
        [Array]::Fill[byte]($bytes,32)
        [Array]::Copy($original,$bytes,$original.Length)
        [IO.File]::WriteAllBytes($path,$bytes)
        (Test-ConfluenceMapping -Root $script:fixtureRoot -MappingPath $path -ExpectedSiteOrigin $site).status | Should -Be 'valid'
        [IO.File]::WriteAllBytes($path,($bytes+[byte]32))
        $r=Test-ConfluenceMapping -Root $script:fixtureRoot -MappingPath $path -ExpectedSiteOrigin $site
        $r.status | Should -Be 'invalid'
        @($r.reasonCodes) | Should -Contain 'MappingSchemaInvalid'
    }

    # Scenario: SYP171-SCN-008; operational JSON cannot contain another THEN copy.
    # Purpose: Unknown schema fields do not become a second editable spec authority.
    It 'UnitT40_rejects_requirement_answer_in_mapping' {
        $data=New-MappingData; $data.entries[0].THEN='copied expected outcome'
        $r=Invoke-MappingFixture $data
        @($r.reasonCodes) | Should -Contain 'MappingSchemaInvalid'
    }

    # Scenario: SYP171-SCN-005/011; a new mapped page may depend on another new projection.
    # Purpose: The adopter's strict operational mapping carries a source-bound dependency without inventing a page ID.
    It 'UnitT50_accepts_exact_new_parent_projection_mapping' {
        $data=New-MappingData
        $data.schemaVersion=2;$data.entries[0].parentProjectionId=''
        $data.entries[0].pageId=$null
        $data.entries[1].pageId=$null;$data.entries[1].parentId='';$data.entries[1].parentProjectionId='req-001'
        $r=Invoke-MappingFixture $data
        $r.status | Should -Be 'valid'
        $r.entries[1].parentProjectionId | Should -Be 'req-001'
        $r.entries[1].parentId | Should -Be ''
    }

    # Scenario: SYP171-SCN-005/011; absent, cyclic, or cross-space dependencies cannot enter publication.
    # Purpose: Validation blocks unsafe hierarchy before the Push command forms payloads.
    It 'UnitT60_rejects_invalid_new_parent_projection_mapping' {
        $data=New-MappingData
        $data.schemaVersion=2
        $data.entries[0].pageId=$null;$data.entries[0].parentId='';$data.entries[0].parentProjectionId='req-002'
        $data.entries[1].pageId=$null;$data.entries[1].parentId='';$data.entries[1].parentProjectionId='req-001'
        (Invoke-MappingFixture $data).status | Should -Be 'invalid'
        $data.entries[0].parentProjectionId='req-missing'
        (Invoke-MappingFixture $data).status | Should -Be 'invalid'
        $data.entries[0].parentProjectionId='';$data.entries[0].parentId='99';$data.entries[1].spaceId='66'
        (Invoke-MappingFixture $data).status | Should -Be 'invalid'
    }

    # Scenario: SYP171-SCN-005; mapping shape changes must be explicit and reversible.
    # Purpose: A v1 mapping cannot silently acquire v2 parent-dependency metadata.
    It 'UnitT70_requires_explicit_mapping_schema_migration_for_parent_projection' {
        $data=New-MappingData;$data.entries[1].pageId=$null;$data.entries[1].parentId='';$data.entries[1].parentProjectionId='req-001'
        @((Invoke-MappingFixture $data).reasonCodes) | Should -Contain 'MappingSchemaInvalid'
    }

    # Scenario: SYP171-SCN-005/009; native local hrefs are bound to exact projection identities.
    # Purpose: Operational mapping v3 carries page identity only and can represent a still-new link target.
    It 'UnitT75_accepts_exact_source_href_to_projection_link_binding' {
        $data=New-MappingData
        $data.schemaVersion=3
        foreach($entry in $data.entries){$entry.parentProjectionId='';$entry.linkBindings=@()}
        $data.entries[0].linkBindings=@(@{href='spec.md#SYP171-REQ-002';targetProjectionId='req-002'})
        $data.entries[1].pageId=$null
        $r=Invoke-MappingFixture $data
        $r.status | Should -Be 'valid'
        @($r.entries[0].linkBindings).Count | Should -Be 1
        $r.entries[0].linkBindings[0].href | Should -Be 'spec.md#SYP171-REQ-002'
        $r.entries[0].linkBindings[0].targetProjectionId | Should -Be 'req-002'
        $r.entries[1].pageId | Should -Be ''
    }

    # Scenario: SYP171-SCN-009/011; link identity is absent, duplicated, or carries an unsafe URI.
    # Purpose: Preflight rejects ambiguous or untrusted bindings before renderer and remote I/O.
    It 'UnitT80_rejects_ambiguous_or_unsafe_link_binding' {
        $data=New-MappingData
        $data.schemaVersion=3
        foreach($entry in $data.entries){$entry.parentProjectionId='';$entry.linkBindings=@()}
        $data.entries[0].linkBindings=@(@{href='spec.md#SYP171-REQ-002';targetProjectionId='missing'})
        $r=Invoke-MappingFixture $data
        @($r.reasonCodes) | Should -Contain 'LinkBindingInvalid'
        $data.entries[0].linkBindings=@(@{href='spec.md#SYP171-REQ-002';targetProjectionId='req-002'},@{href='spec.md#SYP171-REQ-002';targetProjectionId='req-002'})
        $r=Invoke-MappingFixture $data
        @($r.reasonCodes) | Should -Contain 'LinkBindingInvalid'
        $data.entries[0].linkBindings=@(@{href='javascript:alert(1)';targetProjectionId='req-002'})
        $r=Invoke-MappingFixture $data
        @($r.reasonCodes) | Should -Contain 'LinkBindingInvalid'
    }

    # Scenario: SYP171-SCN-009; a source anchor names a different requirement or omits the section on a shared file.
    # Purpose: One source file cannot silently route a requirement link to the wrong projected page.
    It 'UnitT90_rejects_wrong_or_ambiguous_source_section_for_link' {
        $data=New-MappingData
        $data.schemaVersion=3
        foreach($entry in $data.entries){$entry.parentProjectionId='';$entry.linkBindings=@()}
        $data.entries[0].linkBindings=@(@{href='spec.md#SYP171-REQ-001';targetProjectionId='req-002'})
        @((Invoke-MappingFixture $data).reasonCodes) | Should -Contain 'LinkBindingInvalid'
        $data.entries[0].linkBindings=@(@{href='spec.md';targetProjectionId='req-002'})
        @((Invoke-MappingFixture $data).reasonCodes) | Should -Contain 'LinkBindingInvalid'
    }
}
