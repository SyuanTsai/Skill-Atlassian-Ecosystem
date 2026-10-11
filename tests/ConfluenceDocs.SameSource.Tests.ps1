# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repositoryRoot=Split-Path -Parent $PSScriptRoot
$sourceModule=Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/OpenSpecSource.psm1'
$rendererModule=Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/StorageProjection.psm1'
$fixture=Join-Path $PSScriptRoot 'fixtures/syp171-import/native'
$runtime=if([string]::IsNullOrWhiteSpace($env:SYP171_RUNTIME_ROOT)){
    Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts'
}else{$env:SYP171_RUNTIME_ROOT}

function Get-SyntheticSource {
    Import-Module -Name $sourceModule -Force
    $source=Test-OpenSpecSource -Root $fixture -ChangeId 'synthetic-retry-import' -RuntimeRoot $runtime
    if($source.status -ne 'valid'){throw "Native source invalid: $($source.reasonCodes -join ',')"}
    return $source
}
function New-SyntheticValidation {
    return [pscustomobject]@{status='valid';docsCommit=('1'*40);specCommit=('2'*40);codeCommit=('3'*40);sourceDigest=('a'*64);approvalStatus='proposed';implementationStatus='proposed';scenarioAcceptance='incomplete';publishEligibility='preview-only'}
}
function Assert-SyntheticTransmissions {
    param($Native,[int]$Actual)
    $scenario=@($Native.scenarios|Where-Object id -eq 'SYN-SCN-001')[0]
    if(@($scenario.then).Count -ne 1 -or $scenario.then[0] -notmatch '\bonce\b'){throw 'Unsupported synthetic fixture expectation.'}
    if($Actual -ne 1){throw "Assertion failed for $($scenario.id): observed $Actual transmissions."}
}

}

Describe 'SYP-171 one native expectation for test and projection' {
    # Scenario: SYP171-SCN-013; native source is both the consumer's and projection's expectation.
    # Purpose: Renderer emits exact IDs and THEN with separate proposed/incomplete state.
    It 'InterT10_renders_same_native_scenario_and_status_without_fake_pass' {
        Import-Module -Name $rendererModule -Force
        $source=Get-SyntheticSource
        $r=ConvertTo-ConfluenceSpecStorage -SourceInventory $source -Validation (New-SyntheticValidation) -RequirementId 'SYN-REQ-001'
        $r.status | Should -Be 'supported'
        @($r.scenarioIds) | Should -Contain 'SYN-SCN-001'
        $r.storage | Should -Match 'The request is sent once'
        $r.storage | Should -Match 'scenarioAcceptance: incomplete'
        $r.storage | Should -Not -Match 'PASS'
        $xml=[Xml.XmlDocument]::new();$xml.XmlResolver=$null;$xml.LoadXml("<root>$($r.storage)</root>")
        $xml.DocumentElement.ChildNodes.Count | Should -BeGreaterThan 0
    }

    # Scenario: SYP171-SCN-013; synthetic behavior sends twice in contradiction to source THEN.
    # Purpose: Assertion fails while the native expected text and preview remain unchanged.
    It 'InterT20_fails_violating_behavior_without_rewriting_then' {
        Import-Module -Name $rendererModule -Force
        $source=Get-SyntheticSource
        $before=$source.scenarios[0].then[0]
        {Assert-SyntheticTransmissions -Native $source -Actual 2}|Should -Throw
        $r=ConvertTo-ConfluenceSpecStorage -SourceInventory $source -Validation (New-SyntheticValidation) -RequirementId 'SYN-REQ-001'
        $source.scenarios[0].then[0] | Should -Be $before
        $r.storage | Should -Match 'The request is sent once'
    }

    # Scenario: SYP171-SCN-016; there is no SYP-5 bundle in this native fixture.
    # Purpose: Same fixed input yields byte-stable storage and hash without that bundle.
    It 'InterT30_is_byte_stable_without_syp5_bundle' {
        Import-Module -Name $rendererModule -Force
        $source=Get-SyntheticSource
        $validation=New-SyntheticValidation
        $a=ConvertTo-ConfluenceSpecStorage -SourceInventory $source -Validation $validation -RequirementId 'SYN-REQ-001'
        $b=ConvertTo-ConfluenceSpecStorage -SourceInventory $source -Validation $validation -RequirementId 'SYN-REQ-001'
        $a.storage | Should -Be $b.storage
        $a.bodySha256 | Should -Be $b.bodySha256
        (Test-Path -LiteralPath (Join-Path $fixture 'syp5')) | Should -Be $false
    }
}
