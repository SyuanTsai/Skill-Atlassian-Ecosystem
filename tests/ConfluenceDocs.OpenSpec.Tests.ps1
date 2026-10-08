# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/OpenSpecSource.psm1'
$projectionModulePath = Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/StorageProjection.psm1'
$planModulePath = Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluencePlan.psm1'
$runtimeRoot = if ([string]::IsNullOrWhiteSpace($env:SYP171_RUNTIME_ROOT)) {
    Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts'
} else { $env:SYP171_RUNTIME_ROOT }

function New-SddFixture {
    $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
    $fixture = Join-Path $tempParent "syp171-openspec-tests-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $fixture | Out-Null
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'openspec') -Destination (Join-Path $fixture 'openspec') -Recurse
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'docs') -Destination (Join-Path $fixture 'docs') -Recurse
    return $fixture
}

function Remove-SddFixture {
    param([Parameter(Mandatory)][string] $Fixture)
    if (-not (Test-Path -LiteralPath $Fixture)) { return }
    $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Fixture).Path)
    $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
    if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\', '/') -cne $tempParent) { throw 'Fixture escaped temporary root.' }
    if ([IO.Path]::GetFileName($resolved) -cnotmatch '^syp171-openspec-tests-[a-f0-9]{32}$') { throw 'Unexpected fixture name.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

function Invoke-SourceValidation {
    param([Parameter(Mandatory)][string] $Root, [string] $SelectedRuntimeRoot = $runtimeRoot)
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) { throw 'OpenSpecSource production module is missing.' }
    Import-Module -Name $modulePath -Force
    return Test-OpenSpecSource -Root $Root -ChangeId 'manage-confluence-docs-as-code' -RuntimeRoot $SelectedRuntimeRoot
}

}

Describe 'SYP-171 native OpenSpec source gate' {
    BeforeEach { $script:fixtureRoot = New-SddFixture }
    AfterEach { Remove-SddFixture -Fixture $script:fixtureRoot }

    # Scenario: SYP171-SCN-008; the fixed native change has 11 requirements and 17 scenarios.
    # Purpose: The reader and official validator must preserve the sole spec inventory and original bytes.
    It 'UnitT10_accepts_valid_native_change_with_complete_inventory' {
        $spec = Join-Path $script:fixtureRoot 'openspec/changes/manage-confluence-docs-as-code/specs/confluence-docs/spec.md'
        $before = (Get-FileHash -LiteralPath $spec -Algorithm SHA256).Hash
        $result = Invoke-SourceValidation -Root $script:fixtureRoot
        $result.status | Should -Be 'valid'
        @($result.requirements).Count | Should -Be 11
        @($result.scenarios).Count | Should -Be 17
        $result.nativeValidation.valid | Should -Be $true
        (Get-FileHash -LiteralPath $spec -Algorithm SHA256).Hash | Should -Be $before
    }

    # Scenario: SYP171-SCN-008; a noninteractive Windows host uses Big5 while Node emits native UTF-8 JSON.
    # Purpose: Host code pages cannot corrupt Chinese requirement text or make valid source unreadable.
    It 'InterT15_preserves_native_UTF8_inventory_under_a_Big5_host' {
        $inputEncoding=[Console]::InputEncoding;$outputEncoding=[Console]::OutputEncoding
        try{
            [Console]::InputEncoding=[Text.Encoding]::GetEncoding(950)
            [Console]::OutputEncoding=[Text.Encoding]::GetEncoding(950)
            $result=Invoke-SourceValidation -Root $script:fixtureRoot
            $result.status|Should -Be 'valid'
            $result.requirements[0].title|Should -Be '[SYP171-REQ-001] 完整擷取候選與來源'
            @($result.scenarios).Count|Should -Be 17
        }finally{[Console]::InputEncoding=$inputEncoding;[Console]::OutputEncoding=$outputEncoding}
    }

    # Scenario: SYP171-SCN-008; one accepted scenario loses its THEN while its heading remains valid.
    # Purpose: The project gate must reject missing expected behavior even when the official CLI passes.
    It 'UnitT20_rejects_missing_THEN_after_native_PASS' {
        $spec = Join-Path $script:fixtureRoot 'openspec/changes/manage-confluence-docs-as-code/specs/confluence-docs/spec.md'
        $text = Get-Content -LiteralPath $spec -Raw -Encoding utf8
        $changed = ([regex]::new('(?m)^- \*\*THEN\*\* [^\r\n]*(?:\r?\n)?')).Replace($text, '', 1)
        $changed | Should -Not -Be $text
        [IO.File]::WriteAllText($spec, $changed, (New-Object System.Text.UTF8Encoding($false)))
        $result = Invoke-SourceValidation -Root $script:fixtureRoot
        $result.nativeValidation.valid | Should -Be $true
        $result.status | Should -Be 'invalid'
        @($result.reasonCodes) | Should -Contain 'MissingThen'
    }

    # Scenario: SYP171-SCN-008; a THEN marker remains but has no expected outcome.
    # Purpose: A blank expectation must not become an implementation-ready scenario.
    It 'UnitT25_rejects_empty_THEN_content' {
        $spec = Join-Path $script:fixtureRoot 'openspec/changes/manage-confluence-docs-as-code/specs/confluence-docs/spec.md'
        $text = Get-Content -LiteralPath $spec -Raw -Encoding utf8
        $changed = ([regex]::new('(?m)^- \*\*THEN\*\* [^\r\n]*')).Replace($text, '- **THEN**', 1)
        [IO.File]::WriteAllText($spec, $changed, (New-Object System.Text.UTF8Encoding($false)))
        $result = Invoke-SourceValidation -Root $script:fixtureRoot
        $result.status | Should -Be 'invalid'
        @($result.reasonCodes) | Should -Contain 'MissingThen'
    }

    # Scenario: SYP171-SCN-008; two native Scenario titles carry the same stable project ID.
    # Purpose: A native PASS must not conceal an ambiguous test and projection identity.
    It 'UnitT30_rejects_duplicate_scenario_ID_after_native_PASS' {
        $spec = Join-Path $script:fixtureRoot 'openspec/changes/manage-confluence-docs-as-code/specs/confluence-docs/spec.md'
        $text = Get-Content -LiteralPath $spec -Raw -Encoding utf8
        [IO.File]::WriteAllText($spec, $text.Replace('[SYP171-SCN-002]', '[SYP171-SCN-001]'), (New-Object System.Text.UTF8Encoding($false)))
        $result = Invoke-SourceValidation -Root $script:fixtureRoot
        $result.nativeValidation.valid | Should -Be $true
        $result.status | Should -Be 'invalid'
        @($result.reasonCodes) | Should -Contain 'DuplicateScenarioId'
    }

    # Scenario: SYP171-SCN-008; two native Requirement titles share one stable project ID.
    # Purpose: Requirement traceability cannot depend on a validator that ignores project IDs.
    It 'UnitT35_rejects_duplicate_requirement_ID' {
        $spec = Join-Path $script:fixtureRoot 'openspec/changes/manage-confluence-docs-as-code/specs/confluence-docs/spec.md'
        $text = Get-Content -LiteralPath $spec -Raw -Encoding utf8
        [IO.File]::WriteAllText($spec, $text.Replace('[SYP171-REQ-002]', '[SYP171-REQ-001]'), (New-Object System.Text.UTF8Encoding($false)))
        $result = Invoke-SourceValidation -Root $script:fixtureRoot
        $result.status | Should -Be 'invalid'
        @($result.reasonCodes) | Should -Contain 'DuplicateRequirementId'
    }

    # Scenario: SYP171-SCN-008; the fixed validator is unavailable in the selected runtime.
    # Purpose: Publishing must stop instead of downgrading the spec to plain Markdown.
    It 'UnitT40_rejects_missing_validator_without_fallback' {
        $missingRuntime = Join-Path $script:fixtureRoot 'absent-runtime'
        $result = Invoke-SourceValidation -Root $script:fixtureRoot -SelectedRuntimeRoot $missingRuntime
        $result.status | Should -Be 'invalid'
        @($result.reasonCodes) | Should -Contain 'ValidatorUnavailable'
    }

    # Scenario: SYP171-SCN-008; an installed CLI advertises another OpenSpec version.
    # Purpose: Source validation must stop before executing an unreviewed validator revision.
    It 'UnitT45_rejects_validator_version_mismatch' {
        $otherRuntime = Join-Path $script:fixtureRoot 'other-runtime'
        $packageRoot = Join-Path $otherRuntime 'node_modules/@fission-ai/openspec'
        New-Item -ItemType Directory -Path (Join-Path $packageRoot 'bin') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $packageRoot 'package.json'), '{"version":"9.9.9"}', (New-Object System.Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText((Join-Path $packageRoot 'bin/openspec.js'), '', (New-Object System.Text.UTF8Encoding($false)))
        $result = Invoke-SourceValidation -Root $script:fixtureRoot -SelectedRuntimeRoot $otherRuntime
        $result.status | Should -Be 'invalid'
        @($result.reasonCodes) | Should -Contain 'ValidatorVersionMismatch'
    }

    # Scenario: SYP171-SCN-008; a native artifact links to a local file that is absent.
    # Purpose: Source provenance must remain resolvable at the selected Git revision.
    It 'UnitT50_rejects_unresolved_local_reference' {
        $design = Join-Path $script:fixtureRoot 'openspec/changes/manage-confluence-docs-as-code/design.md'
        [IO.File]::AppendAllText($design, "`n[missing](../../../docs/syp171/missing.md)`n", (New-Object System.Text.UTF8Encoding($false)))
        $result = Invoke-SourceValidation -Root $script:fixtureRoot
        $result.status | Should -Be 'invalid'
        @($result.reasonCodes) | Should -Contain 'ReferenceMissing'
    }

    # Scenario: SYP171-SCN-008; a Scenario heading uses the wrong native level.
    # Purpose: The real pinned CLI must contribute its own structural rejection evidence.
    It 'UnitT55_rejects_native_structural_failure' {
        $spec = Join-Path $script:fixtureRoot 'openspec/changes/manage-confluence-docs-as-code/specs/confluence-docs/spec.md'
        $text = Get-Content -LiteralPath $spec -Raw -Encoding utf8
        $changed = $text.Replace('#### Scenario: [SYP171-SCN-001]', '### Scenario: [SYP171-SCN-001]').Replace('#### Scenario: [SYP171-SCN-002]', '### Scenario: [SYP171-SCN-002]')
        [IO.File]::WriteAllText($spec, $changed, (New-Object System.Text.UTF8Encoding($false)))
        $result = Invoke-SourceValidation -Root $script:fixtureRoot
        $result.nativeValidation.valid | Should -Be $false
        $result.status | Should -Be 'invalid'
        @($result.reasonCodes) | Should -Contain 'NativeValidationFailed'
    }

    # Scenario: SYP171-SCN-009; the native requirement can contain a valid local Markdown link.
    # Purpose: Preserve link provenance in inventory and block projection while clickable link resolution is unsupported.
    It 'UnitT60_keeps_native_link_provenance_and_blocks_literal_text_projection' {
        $spec=Join-Path $script:fixtureRoot 'openspec/changes/manage-confluence-docs-as-code/specs/confluence-docs/spec.md'
        $text=Get-Content -LiteralPath $spec -Raw -Encoding utf8
        $heading='### Requirement: [SYP171-REQ-001] 完整擷取候選與來源'
        $relative='../../../../../docs/syp171/implementation-plan.md'
        $text=$text.Replace($heading,"$heading`n`n[Related design]($relative)")
        [IO.File]::WriteAllText($spec,$text,[Text.UTF8Encoding]::new($false))
        $source=Invoke-SourceValidation -Root $script:fixtureRoot
        $source.status | Should -Be 'valid'
        @($source.requirements[0].links).Count | Should -Be 1
        $source.requirements[0].links[0].href | Should -Be $relative
        Import-Module -Name $projectionModulePath -Force
        $state=[pscustomobject]@{status='valid';docsCommit=('1'*40);specCommit=('2'*40);codeCommit=('3'*40);approvalStatus='proposed';implementationStatus='proposed';scenarioAcceptance='incomplete';publishEligibility='preview-only'}
        $projection=ConvertTo-ConfluenceSpecStorage -SourceInventory $source -Validation $state -RequirementId 'SYP171-REQ-001'
        $projection.status | Should -Be 'unsupported'
        @($projection.reasonCodes) | Should -Contain 'LinkProjectionUnsupported'
    }

    # Scenario: SYP171-SCN-009; a native requirement may embed an image with a valid local source.
    # Purpose: Record its exact source and block projection until the managed attachment path can represent it.
    It 'UnitT65_keeps_native_image_source_and_blocks_dropped_asset_projection' {
        $spec=Join-Path $script:fixtureRoot 'openspec/changes/manage-confluence-docs-as-code/specs/confluence-docs/spec.md'
        $image=Join-Path $script:fixtureRoot 'docs/syp171/synthetic-image.png'
        [IO.File]::WriteAllBytes($image,[byte[]]@(0,255,1,2))
        $text=Get-Content -LiteralPath $spec -Raw -Encoding utf8
        $heading='### Requirement: [SYP171-REQ-001] 完整擷取候選與來源'
        $relative='../../../../../docs/syp171/synthetic-image.png'
        $text=$text.Replace($heading,"$heading`n`n![Architecture]($relative)")
        [IO.File]::WriteAllText($spec,$text,[Text.UTF8Encoding]::new($false))
        $source=Invoke-SourceValidation -Root $script:fixtureRoot
        $source.status | Should -Be 'valid'
        @($source.requirements[0].images).Count | Should -Be 1
        $source.requirements[0].images[0].src | Should -Be $relative
        Import-Module -Name $projectionModulePath -Force
        $state=[pscustomobject]@{status='valid';docsCommit=('1'*40);specCommit=('2'*40);codeCommit=('3'*40);approvalStatus='proposed';implementationStatus='proposed';scenarioAcceptance='incomplete';publishEligibility='preview-only'}
        $projection=ConvertTo-ConfluenceSpecStorage -SourceInventory $source -Validation $state -RequirementId 'SYP171-REQ-001'
        $projection.status | Should -Be 'unsupported'
        @($projection.reasonCodes) | Should -Contain 'AssetProjectionUnsupported'
    }

    # Scenario: SYP171-SCN-009; an absolute HTTPS link in a native requirement has a safe, exact destination.
    # Purpose: Projection must retain the clickable href and text without rewriting the spec authority.
    It 'UnitT70_projects_sourced_https_link_as_clickable_storage' {
        $spec=Join-Path $script:fixtureRoot 'openspec/changes/manage-confluence-docs-as-code/specs/confluence-docs/spec.md'
        $text=Get-Content -LiteralPath $spec -Raw -Encoding utf8
        $heading='### Requirement: [SYP171-REQ-001] 完整擷取候選與來源'
        $text=$text.Replace($heading,"$heading`n`nRead the [official guide](https://developer.atlassian.com/cloud/confluence/rest/v2/api-group-page/) before release.")
        [IO.File]::WriteAllText($spec,$text,[Text.UTF8Encoding]::new($false))
        $source=Invoke-SourceValidation -Root $script:fixtureRoot
        $source.status | Should -Be 'valid'
        Import-Module -Name $projectionModulePath -Force
        $state=[pscustomobject]@{status='valid';docsCommit=('1'*40);specCommit=('2'*40);codeCommit=('3'*40);approvalStatus='proposed';implementationStatus='proposed';scenarioAcceptance='incomplete';publishEligibility='preview-only'}
        $projection=ConvertTo-ConfluenceSpecStorage -SourceInventory $source -Validation $state -RequirementId 'SYP171-REQ-001'
        $projection.status | Should -Be 'supported'
        $projection.storage | Should -Match '<a href="https://developer.atlassian.com/cloud/confluence/rest/v2/api-group-page/">official guide</a>'
        $projection.storage | Should -Match 'Read the <a'
        $projection.storage | Should -Match '</a> before release'
    }

    # Scenario: SYP171-SCN-009; a native image is bound to the same exact local file and managed filename.
    # Purpose: The image stays in body storage and the attachment is independently checked by the plan.
    It 'UnitT75_projects_native_image_with_exact_managed_asset_binding' {
        $spec=Join-Path $script:fixtureRoot 'openspec/changes/manage-confluence-docs-as-code/specs/confluence-docs/spec.md'
        $image=Join-Path $script:fixtureRoot 'docs/syp171/synthetic-image.png'
        $bytes=[byte[]]@(137,80,78,71,13,10,26,10)
        [IO.File]::WriteAllBytes($image,$bytes)
        $sha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        $text=Get-Content -LiteralPath $spec -Raw -Encoding utf8
        $heading='### Requirement: [SYP171-REQ-001] 完整擷取候選與來源'
        $relative='../../../../../docs/syp171/synthetic-image.png'
        $text=$text.Replace($heading,"$heading`n`nThe diagram ![Architecture]($relative) records the source.")
        [IO.File]::WriteAllText($spec,$text,[Text.UTF8Encoding]::new($false))
        $source=Invoke-SourceValidation -Root $script:fixtureRoot
        $source.status | Should -Be 'valid'
        Import-Module -Name $projectionModulePath -Force
        $state=[pscustomobject]@{status='valid';docsCommit=('1'*40);specCommit=('2'*40);codeCommit=('3'*40);approvalStatus='proposed';implementationStatus='proposed';scenarioAcceptance='incomplete';publishEligibility='preview-only'}
        $asset=[pscustomobject]@{localPath='docs/syp171/synthetic-image.png';displayFilename='synthetic-image.png';mediaType='image/png';sha256=$sha}
        $projection=ConvertTo-ConfluenceSpecStorage -SourceInventory $source -Validation $state -RequirementId 'SYP171-REQ-001' -Root $script:fixtureRoot -ProjectionId 'req-001' -ManagedAssets @($asset)
        $projection.status | Should -Be 'supported'
        $projection.storage | Should -Match '<ac:image ac:alt="Architecture"'
        $projection.storage | Should -Match "<ri:attachment ri:filename=`"syp171-req-001-$sha.png`""
        $projection.storage | Should -Match 'The diagram <ac:image'
    }

    # Scenario: SYP171-SCN-009; a native link label carries meaningful emphasis and inline code.
    # Purpose: A clickable link cannot be marked supported if its source formatting is flattened.
    It 'UnitT80_keeps_rich_native_link_label_in_storage' {
        $spec=Join-Path $script:fixtureRoot 'openspec/changes/manage-confluence-docs-as-code/specs/confluence-docs/spec.md'
        $text=Get-Content -LiteralPath $spec -Raw -Encoding utf8
        $heading='### Requirement: [SYP171-REQ-001] 完整擷取候選與來源'
        $text=$text.Replace($heading,"$heading`n`nRead [**important** ``API``](https://developer.atlassian.com/cloud/confluence/rest/v2/api-group-page/).")
        [IO.File]::WriteAllText($spec,$text,[Text.UTF8Encoding]::new($false))
        $source=Invoke-SourceValidation -Root $script:fixtureRoot
        $source.status | Should -Be 'valid'
        Import-Module -Name $projectionModulePath -Force
        $state=[pscustomobject]@{status='valid';docsCommit=('1'*40);specCommit=('2'*40);codeCommit=('3'*40);approvalStatus='proposed';implementationStatus='proposed';scenarioAcceptance='incomplete';publishEligibility='preview-only'}
        $projection=ConvertTo-ConfluenceSpecStorage -SourceInventory $source -Validation $state -RequirementId 'SYP171-REQ-001'
        $projection.status | Should -Be 'supported'
        $projection.storage | Should -Match '<a href="https://developer.atlassian.com/cloud/confluence/rest/v2/api-group-page/"><strong>important</strong> <code>API</code></a>'
    }

    # Scenario: SYP171-SCN-009; native Markdown can contain an inline construct the storage renderer lacks.
    # Purpose: The affected requirement stays blocked with provenance instead of dropping that construct.
    It 'UnitT85_blocks_unhandled_native_inline_formatting' {
        $spec=Join-Path $script:fixtureRoot 'openspec/changes/manage-confluence-docs-as-code/specs/confluence-docs/spec.md'
        $text=Get-Content -LiteralPath $spec -Raw -Encoding utf8
        $heading='### Requirement: [SYP171-REQ-001] 完整擷取候選與來源'
        $text=$text.Replace($heading,"$heading`n`nDo not ~~delete~~ the source.")
        [IO.File]::WriteAllText($spec,$text,[Text.UTF8Encoding]::new($false))
        $source=Invoke-SourceValidation -Root $script:fixtureRoot
        $source.status | Should -Be 'valid'
        Import-Module -Name $projectionModulePath -Force
        $state=[pscustomobject]@{status='valid';docsCommit=('1'*40);specCommit=('2'*40);codeCommit=('3'*40);approvalStatus='proposed';implementationStatus='proposed';scenarioAcceptance='incomplete';publishEligibility='preview-only'}
        $projection=ConvertTo-ConfluenceSpecStorage -SourceInventory $source -Validation $state -RequirementId 'SYP171-REQ-001'
        $projection.status | Should -Be 'unsupported'
        @($projection.reasonCodes) | Should -Contain 'InlineProjectionUnsupported'
    }

    # Scenario: SYP171-SCN-009; one native local href points to an already identified mapped page.
    # Purpose: Projection keeps source label and uses only the mapped page ID, never a page title guess.
    It 'UnitT88_resolves_source_bound_local_link_to_exact_existing_page_id' {
        $spec=Join-Path $script:fixtureRoot 'openspec/changes/manage-confluence-docs-as-code/specs/confluence-docs/spec.md'
        $text=Get-Content -LiteralPath $spec -Raw -Encoding utf8
        $heading='### Requirement: [SYP171-REQ-001] 完整擷取候選與來源'
        $href='spec.md#SYP171-REQ-002'
        $text=$text.Replace($heading,"$heading`n`nSee [the second requirement]($href).")
        [IO.File]::WriteAllText($spec,$text,[Text.UTF8Encoding]::new($false))
        $source=Invoke-SourceValidation -Root $script:fixtureRoot
        $source.status | Should -Be 'valid'
        Import-Module -Name $projectionModulePath -Force
        $state=[pscustomobject]@{status='valid';siteOrigin='https://example.atlassian.net';docsCommit=('1'*40);specCommit=('2'*40);codeCommit=('3'*40);approvalStatus='proposed';implementationStatus='proposed';scenarioAcceptance='incomplete';publishEligibility='preview-only'}
        $artifact=$source.requirements[0].path
        $bindings=@([pscustomobject]@{href=$href;targetProjectionId='req-002'})
        $pages=@([pscustomobject]@{projectionId='req-001';sourceArtifact=$artifact;sourceSectionId='SYP171-REQ-001';pageId='101'},[pscustomobject]@{projectionId='req-002';sourceArtifact=$artifact;sourceSectionId='SYP171-REQ-002';pageId='102'})
        $projection=ConvertTo-ConfluenceSpecStorage -SourceInventory $source -Validation $state -RequirementId 'SYP171-REQ-001' -Root $script:fixtureRoot -ProjectionId 'req-001' -LinkBindings $bindings -PageMappings $pages
        $projection.status | Should -Be 'supported'
        $projection.storage | Should -Match '<a href="https://example.atlassian.net/wiki/pages/viewpage.action\?pageId=102">the second requirement</a>'
    }

    # Scenario: SYP171-SCN-009/011; a valid native local href points to a new mapped page without a server ID.
    # Purpose: Renderer records a frozen deferred target and never exposes an incomplete href as publishable body.
    It 'UnitT89_keeps_new_page_link_as_deferred_identity_template' {
        $spec=Join-Path $script:fixtureRoot 'openspec/changes/manage-confluence-docs-as-code/specs/confluence-docs/spec.md'
        $text=Get-Content -LiteralPath $spec -Raw -Encoding utf8
        $heading='### Requirement: [SYP171-REQ-001] 完整擷取候選與來源'
        $href='spec.md#SYP171-REQ-002'
        $text=$text.Replace($heading,"$heading`n`nSee [the second requirement]($href).")
        [IO.File]::WriteAllText($spec,$text,[Text.UTF8Encoding]::new($false))
        $source=Invoke-SourceValidation -Root $script:fixtureRoot
        $source.status | Should -Be 'valid'
        Import-Module -Name $projectionModulePath -Force
        $state=[pscustomobject]@{status='valid';siteOrigin='https://example.atlassian.net';docsCommit=('1'*40);specCommit=('2'*40);codeCommit=('3'*40);approvalStatus='proposed';implementationStatus='proposed';scenarioAcceptance='incomplete';publishEligibility='preview-only'}
        $artifact=$source.requirements[0].path
        $bindings=@([pscustomobject]@{href=$href;targetProjectionId='req-002'})
        $pages=@([pscustomobject]@{projectionId='req-001';sourceArtifact=$artifact;sourceSectionId='SYP171-REQ-001';pageId='101'},[pscustomobject]@{projectionId='req-002';sourceArtifact=$artifact;sourceSectionId='SYP171-REQ-002';pageId=''})
        $projection=ConvertTo-ConfluenceSpecStorage -SourceInventory $source -Validation $state -RequirementId 'SYP171-REQ-001' -Root $script:fixtureRoot -ProjectionId 'req-001' -LinkBindings $bindings -PageMappings $pages
        $projection.status | Should -Be 'deferred'
        $projection.storage | Should -Be ''
        @($projection.deferredTargets) | Should -Contain 'req-002'
        $projection.storageTemplate | Should -Match 'pageId=__SYP171_LINK_req-002__'
    }

    # Scenario: SYP171-SCN-009/012; a native image and its managed asset traverse the same immutable preview path.
    # Purpose: Parser, renderer, exact local hash, body reference, and staged upload bytes must agree.
    It 'InterT90_stages_native_image_binary_from_sourced_projection' {
        $spec=Join-Path $script:fixtureRoot 'openspec/changes/manage-confluence-docs-as-code/specs/confluence-docs/spec.md'
        $image=Join-Path $script:fixtureRoot 'docs/syp171/synthetic-image.png'
        $bytes=[byte[]]@(137,80,78,71,13,10,26,10)
        [IO.File]::WriteAllBytes($image,$bytes)
        $sha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        $text=Get-Content -LiteralPath $spec -Raw -Encoding utf8
        $heading='### Requirement: [SYP171-REQ-001] 完整擷取候選與來源'
        $text=$text.Replace($heading,"$heading`n`n![Architecture](../../../../../docs/syp171/synthetic-image.png)")
        [IO.File]::WriteAllText($spec,$text,[Text.UTF8Encoding]::new($false))
        $source=Invoke-SourceValidation -Root $script:fixtureRoot
        $source.status | Should -Be 'valid'
        Import-Module -Name $projectionModulePath -Force
        Import-Module -Name $planModulePath -Force
        $site='https://example.atlassian.net'
        $cloud='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        $api="https://api.atlassian.com/ex/confluence/$cloud"
        $state=[pscustomobject]@{status='valid';siteOrigin=$site;cloudId=$cloud;docsCommit=('1'*40);specCommit=('2'*40);codeCommit=('3'*40);sourceDigest=$source.sourceDigest;mappingDigest=('a'*64);reviewDigest=('b'*64);validatorVersion='1.13.0';rendererVersion='1';approvalStatus='proposed';implementationStatus='proposed';scenarioAcceptance='incomplete';publishEligibility='preview-only';scenarioIds=@('SYP171-SCN-001')}
        $asset=[pscustomobject]@{localPath='docs/syp171/synthetic-image.png';displayFilename='synthetic-image.png';mediaType='image/png';sha256=$sha}
        $projection=ConvertTo-ConfluenceSpecStorage -SourceInventory $source -Validation $state -RequirementId 'SYP171-REQ-001' -Root $script:fixtureRoot -ProjectionId 'req-001' -ManagedAssets @($asset)
        $projection.status | Should -Be 'supported'
        $payload=[pscustomobject]@{projectionId='req-001';pageId='101';spaceId='55';parentId='99';title='Native SDD';bodyStorage=$projection.storage;assetChanges=@($asset)}
        $http={
            param($Request)
            if($Request.Method -cne 'GET'){throw 'Preview attempted a write'}
            if($Request.Uri -match '/pages/101/attachments'){
                return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{results=@();_links=@{}}}
            }
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{id='101';spaceId='55';parentId='99';title='Native SDD';status='current';version=@{number=1};body=@{storage=@{value='<p>Before</p>'}}}}
        }
        $preview=New-ConfluencePreviewPlan -PlanPath (Join-Path $script:fixtureRoot 'native-image-plan.json') -Validation $state -Payloads @($payload) -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker $http -ValidationInputs ([pscustomobject]@{root=$script:fixtureRoot})
        if($preview.status -cne 'preview'){throw "Native image preview failed: $($preview.reasonCodes -join ',')"}
        $preview.status | Should -Be 'preview'
        $plan=Get-Content -LiteralPath $preview.planPath -Raw|ConvertFrom-Json
        $plan.pages[0].assetChanges[0].remoteFilename | Should -Be "syp171-req-001-$sha.png"
        $staged=Join-Path $script:fixtureRoot $plan.pages[0].assetChanges[0].payloadPath
        [Convert]::ToHexString([IO.File]::ReadAllBytes($staged)) | Should -Be ([Convert]::ToHexString($bytes))
    }
}
