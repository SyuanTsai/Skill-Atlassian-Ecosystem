# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    Set-StrictMode -Version Latest
    $repositoryRoot=Split-Path -Parent $PSScriptRoot
    $planModule=Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluencePlan.psm1'

    function New-LegacyConfluencePlan {
        param([int]$Version)
        $page=[ordered]@{
            projectionId='general-doc';pageId='101';spaceId='55';parentId='99';parentProjectionId='';title='General'
            action='update';expectedPublishedVersion=7;expectedPublishedBodySha256=('a'*64)
            expectedParentVersion=$null;expectedParentBodySha256=$null;expectedDraftObservation='same-as-published'
            payloadPath='plan-assets/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/general.storage.xml';payloadSha256=('b'*64)
            assetChanges=@();intermediateWrites=@('update')
        }
        if($Version -eq 2){$page.deferredTargets=@()}
        $plan=[ordered]@{
            schemaVersion=$Version;operationId='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';createdAtUtc='2026-10-13T00:00:00.0000000Z'
            siteOrigin='https://example.atlassian.net';cloudId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            docsCommit='1'*40;specCommit='2'*40;codeCommit='3'*40;sourceDigest='4'*64;mappingDigest='5'*64
            reviewDigest='6'*64;validatorVersion='1.13.0';rendererVersion='1';scenarioIds=@('SYP171-SCN-001')
            pages=@($page);validationInputs=$null
        }
        if($Version -eq 2){$plan.linkStrategy='identity-first'}
        return $plan
    }
}

Describe 'SYP-171 Markdown plan contract version' {
    # Scenario: A plan was created by the retired OpenSpec contract before Markdown mapping existed.
    # Purpose: Old plan and approval bytes cannot be reinterpreted under the new renderer and source contract.
    It 'UnitT10_rejects_legacy_publish_plan_versions' {
        Import-Module -Name $planModule -Force
        foreach($version in @(1,2,3,4)){
            (Test-ConfluencePlanShape -Plan (New-LegacyConfluencePlan -Version $version)) | Should -BeFalse
        }
    }
}
