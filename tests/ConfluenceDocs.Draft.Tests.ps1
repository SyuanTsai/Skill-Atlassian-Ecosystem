# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $repositoryRoot=Split-Path -Parent $PSScriptRoot
    $planModule=Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluencePlan.psm1'
    $publishModule=Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluencePublish.psm1'
    $site='https://example.atlassian.net'
    $cloud='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    $api="https://api.atlassian.com/ex/confluence/$cloud"
    function New-DraftValidation {
        return [pscustomobject]@{status='valid';siteOrigin=$site;cloudId=$cloud;docsCommit=('a'*40);specCommit=('b'*40);codeCommit=('c'*40);sourceDigest=('d'*64);mappingDigest=('e'*64);reviewDigest=('f'*64);validatorVersion='1.13.0';rendererVersion='markdown-it@14.3.1';scenarioIds=@('SYN-SCN-001')}
    }
    function New-DraftHttp {
        return {
            param($Request)
            $script:calls.Add($Request)
            $id=if($Request.Uri -match '/pages/([0-9]+)'){$Matches[1]}else{throw 'Unexpected endpoint'}
            $remote=$script:remote[$id]
            if($Request.Method -ceq 'PUT') {
                $body=$Request.Body|ConvertFrom-Json -AsHashtable
                if($body.status -cne 'draft' -or $body.version.number -ne 1){throw 'Draft contract violated'}
                if($script:mode -ceq 'timeout-before'){throw 'Synthetic timeout'}
                if($script:mode -ceq 'partial-batch' -and $id -ceq '102'){throw 'Synthetic second page timeout'}
                $remote.draft=[string]$body.body.value;$remote.message=[string]$body.version.message
                if($script:mode -ceq 'bad-readback'){$remote.draft='<p>Unrelated edit</p>'}
                if($script:mode -ceq 'current-changed'){$remote.current='<p>Concurrent current</p>'; $remote.currentVersion++}
                if($script:mode -ceq 'timeout-after'){throw 'Synthetic lost response'}
            }
            $isDraft=$Request.Method -ceq 'PUT' -or $Request.Uri -match 'status=draft'
            $result=@{id=$id;spaceId='55';parentId='99';title='Synthetic draft';status=$(if($isDraft){'draft'}else{'current'});version=@{number=$(if($isDraft){1}else{$remote.currentVersion});message=$(if($isDraft){$remote.message}else{''})};body=@{storage=@{value=$(if($isDraft){$remote.draft}else{$remote.current})}}}
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=$result}
        }
    }
    function New-DraftFixture {
        param([string]$Body='<p>Candidate</p>',[string[]]$Ids=@('101'))
        Import-Module $planModule -Force
        $payloads=@($Ids|ForEach-Object {[pscustomobject]@{projectionId="req-$_";pageId=$_;spaceId='55';parentId='99';title='Synthetic draft';bodyStorage=$Body;assetChanges=@()}})
        $preview=New-ConfluencePreviewPlan -PlanPath (Join-Path $script:fixtureRoot 'plan.json') -Validation (New-DraftValidation) -Payloads $payloads -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-DraftHttp) -PublishMode draft
        if($preview.status -cne 'preview'){throw "Preview failed: $($preview.reasonCodes -join ',')"}
        $plan=Get-Content -LiteralPath $preview.planPath -Raw|ConvertFrom-Json -AsHashtable
        $auth=@{schemaVersion=2;planSha256=$preview.planSha256;operationId=$plan.operationId;siteOrigin=$site;cloudId=$cloud;publishMode='draft';approvedActions=@($plan.pages|Where-Object action -ne 'no-op'|ForEach-Object {"draft-update:$($_.pageId)"});approvalEvidenceRef='synthetic-fixture-only'}
        $authPath=Join-Path $script:fixtureRoot 'authorization.json'
        [IO.File]::WriteAllText($authPath,($auth|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        return [pscustomobject]@{plan=$preview.planPath;auth=$authPath;journal=(Join-Path $script:fixtureRoot 'journal.json');sync=(Join-Path $script:fixtureRoot 'sync.json')}
    }
    function Invoke-DraftFixture {
        param($Fixture)
        Import-Module $publishModule -Force
        return Invoke-ConfluencePlan -PlanPath $Fixture.plan -CurrentValidation (New-DraftValidation) -AuthorizationPath $Fixture.auth -JournalPath $Fixture.journal -SyncPath $Fixture.sync -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-DraftHttp)
    }
}

Describe 'SYP-171 Draft operation isolates published content' {
    BeforeEach {
        $script:fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('syp171-draft-tests-'+[Guid]::NewGuid().ToString('N'))
        $null=New-Item -ItemType Directory -Path $script:fixtureRoot
        $script:calls=[System.Collections.Generic.List[object]]::new()
        $script:mode='normal'
        $script:remote=@{'101'=@{current='<p>Published</p>';currentVersion=7;draft='<p>Previous draft</p>';message=''};'102'=@{current='<p>Published</p>';currentVersion=8;draft='<p>Previous draft</p>';message=''}}
    }
    AfterEach {
        $resolved=[IO.Path]::GetFullPath($script:fixtureRoot)
        if([IO.Path]::GetDirectoryName($resolved).TrimEnd('\','/') -cne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/') -or [IO.Path]::GetFileName($resolved) -cnotmatch '^syp171-draft-tests-[a-f0-9]{32}$'){throw 'Unexpected fixture path'}
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }

    # Scenario: SYP171-SCN-007/012; immutable Draft plan is approved and executed.
    # Purpose: Version 1 Draft readback advances sync while current bytes/version remain unchanged.
    It 'InterT10_writes_Draft_version_one_then_reruns_without_mutation' {
        $f=New-DraftFixture
        $plan=Get-Content -LiteralPath $f.plan -Raw|ConvertFrom-Json
        $plan.schemaVersion|Should -Be 3
        $plan.publishMode|Should -Be 'draft'
        (Invoke-DraftFixture $f).status|Should -Be 'drafted'
        $script:remote['101'].current|Should -Be '<p>Published</p>'
        $script:remote['101'].currentVersion|Should -Be 7
        $script:remote['101'].draft|Should -Be '<p>Candidate</p>'
        $script:calls.Clear()
        (Invoke-DraftFixture $f).status|Should -Be 'no-op'
        @($script:calls|Where-Object Method -ne 'GET').Count|Should -Be 0
        (Get-Content -LiteralPath $f.sync -Raw|ConvertFrom-Json).schemaVersion|Should -Be 4
    }

    # Scenario: SYP171-SCN-007; an old current authorization is presented to a Draft candidate.
    # Purpose: A different mode cannot inherit approval from a valid hash-bound action record.
    It 'UnitT20_rejects_current_authorization_before_any_remote_call' {
        $f=New-DraftFixture
        $auth=Get-Content -LiteralPath $f.auth -Raw|ConvertFrom-Json -AsHashtable
        $auth.schemaVersion=1;$null=$auth.Remove('publishMode');$auth.approvedActions=@('update:101')
        [IO.File]::WriteAllText($f.auth,($auth|ConvertTo-Json -Depth 8))
        $script:calls.Clear()
        (Invoke-DraftFixture $f).reasonCodes|Should -Contain 'AuthorizationMismatch'
        $script:calls.Count|Should -Be 0
    }

    # Scenario: SYP171-SCN-010; Draft changed after immutable preview.
    # Purpose: Concurrent remote work is not overwritten and sync does not advance.
    It 'UnitT30_blocks_Draft_drift_before_PUT' {
        $f=New-DraftFixture;$script:remote['101'].draft='<p>Concurrent edit</p>';$script:calls.Clear()
        (Invoke-DraftFixture $f).reasonCodes|Should -Contain 'DraftDrift'
        @($script:calls|Where-Object Method -ne 'GET').Count|Should -Be 0
        Test-Path -LiteralPath $f.sync|Should -BeFalse
    }

    # Scenario: SYP171-SCN-011; PUT reached the server but its response was lost.
    # Purpose: Original operation reconciles marked body without another PUT.
    It 'InterT40_reconciles_uncertain_Draft_under_original_operation' {
        $f=New-DraftFixture;$script:mode='timeout-after'
        (Invoke-DraftFixture $f).status|Should -Be 'uncertain'
        Test-Path -LiteralPath $f.sync|Should -BeFalse
        $script:mode='normal';$script:calls.Clear()
        (Invoke-DraftFixture $f).status|Should -Be 'drafted'
        @($script:calls|Where-Object Method -ne 'GET').Count|Should -Be 0
    }

    # Scenario: SYP171-SCN-011; delivery of an unacknowledged Draft write cannot be proved.
    # Purpose: An absent marker/body remains uncertain and is never blindly resent.
    It 'UnitT50_never_resends_an_unproved_Draft_write' {
        $f=New-DraftFixture;$script:mode='timeout-before'
        (Invoke-DraftFixture $f).status|Should -Be 'uncertain'
        $script:mode='normal';$script:calls.Clear()
        (Invoke-DraftFixture $f).status|Should -Be 'uncertain'
        @($script:calls|Where-Object Method -ne 'GET').Count|Should -Be 0
        Test-Path -LiteralPath $f.sync|Should -BeFalse
    }

    # Scenario: SYP171-SCN-012; HTTP success does not match the candidate or changes current.
    # Purpose: Failed Draft/current readback never creates a sync success baseline.
    It 'UnitT60_blocks_bad_readback_and_changed_published_content' {
        $f=New-DraftFixture;$script:mode='current-changed'
        (Invoke-DraftFixture $f).reasonCodes|Should -Contain 'PublishedContentChanged'
        Test-Path -LiteralPath $f.sync|Should -BeFalse
    }

    # Scenario: SYP171-SCN-012; a fresh Draft preview observes the candidate already stored.
    # Purpose: No-op is based on verified Draft body and unchanged current, not a copied sync record.
    It 'UnitT70_confirms_fresh_Draft_no_op_with_zero_writes' {
        $script:remote['101'].draft='<p>Candidate</p>'
        $f=New-DraftFixture;$script:calls.Clear()
        (Invoke-DraftFixture $f).status|Should -Be 'no-op'
        @($script:calls|Where-Object Method -ne 'GET').Count|Should -Be 0
    }

    # Scenario: SYP171-SCN-007; Draft receives unsupported create scope or an attachment without source validation inputs.
    # Purpose: Neither unsupported page creation nor incomplete attachment evidence can reach remote IO.
    It 'UnitT80_rejects_Draft_create_and_incomplete_attachment_scope' {
        Import-Module $planModule -Force
        $payload=[pscustomobject]@{projectionId='req-101';pageId='';spaceId='55';parentId='99';title='Synthetic draft';bodyStorage='<p>Candidate</p>';assetChanges=@()}
        $r=New-ConfluencePreviewPlan -PlanPath (Join-Path $script:fixtureRoot 'plan.json') -Validation (New-DraftValidation) -Payloads @($payload) -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-DraftHttp) -PublishMode draft
        $r.reasonCodes|Should -Contain 'DraftScopeUnsupported'
        $script:calls.Count|Should -Be 0
        $payload.pageId='101';$payload.assetChanges=@(@{localPath='synthetic.png'})
        $r=New-ConfluencePreviewPlan -PlanPath (Join-Path $script:fixtureRoot 'plan.json') -Validation (New-DraftValidation) -Payloads @($payload) -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-DraftHttp) -PublishMode draft
        $r.reasonCodes|Should -Contain 'AssetRootUnavailable'
        $script:calls.Count|Should -Be 0
    }

    # Scenario: SYP171-SCN-007/012; persisted Draft artifacts cross the public schema boundary.
    # Purpose: The emitted plan, authorization, journal and sync satisfy the same versioned contracts consumers read.
    It 'InterT81_emits_artifacts_that_validate_against_public_Draft_schemas' {
        $f=New-DraftFixture
        (Invoke-DraftFixture $f).status|Should -Be 'drafted'
        foreach($pair in @(@($f.plan,'publish-plan'),@($f.auth,'authorization'),@($f.journal,'operation-journal'),@($f.sync,'sync-state'))) {
            Test-Json -Json (Get-Content -LiteralPath $pair[0] -Raw) -SchemaFile (Join-Path $repositoryRoot "skills/manage-confluence-docs-as-code/references/$($pair[1]).schema.json")|Should -BeTrue
        }
    }

    # Scenario: SYP171-SCN-011/012; the second page cannot confirm its write.
    # Purpose: Partial batch preserves first-page evidence but creates no full-success sync and sends no blind retry.
    It 'InterT82_keeps_partial_batch_unconfirmed_without_resending' {
        $f=New-DraftFixture -Ids @('101','102');$script:mode='partial-batch'
        (Invoke-DraftFixture $f).status|Should -Be 'uncertain'
        $journal=Get-Content -LiteralPath $f.journal -Raw|ConvertFrom-Json
        $journal.pages[0].stage|Should -Be 'confirmed'
        $journal.pages[1].stage|Should -Be 'write-sent'
        Test-Path -LiteralPath $f.sync|Should -BeFalse
        $script:mode='normal';$script:calls.Clear()
        (Invoke-DraftFixture $f).status|Should -Be 'uncertain'
        @($script:calls|Where-Object Method -ne 'GET').Count|Should -Be 0
    }

    # Scenario: SYP171-SCN-007; staged page bytes changed after immutable approval.
    # Purpose: Static validation freezes exact bytes and rejects mutation before remote calls.
    It 'UnitT83_blocks_changed_payload_before_remote_preflight' {
        $f=New-DraftFixture
        $plan=Get-Content -LiteralPath $f.plan -Raw|ConvertFrom-Json
        [IO.File]::WriteAllText((Join-Path $script:fixtureRoot $plan.pages[0].payloadPath),'<p>Tampered</p>')
        $script:calls.Clear()
        (Invoke-DraftFixture $f).reasonCodes|Should -Contain 'PayloadChanged'
        $script:calls.Count|Should -Be 0
    }

    # Scenario: SYP171-SCN-007; preserved Draft baseline changed after preview.
    # Purpose: Both public drift inspection and execution reject altered recovery bytes.
    It 'UnitT84_blocks_changed_Draft_baseline_in_drift_and_execution' {
        $f=New-DraftFixture
        $plan=Get-Content -LiteralPath $f.plan -Raw|ConvertFrom-Json
        [IO.File]::WriteAllText((Join-Path $script:fixtureRoot $plan.pages[0].draftBaselinePath),'<p>Tampered baseline</p>')
        Import-Module $planModule -Force
        $script:calls.Clear()
        (Test-ConfluencePlanDrift -PlanPath $f.plan -CurrentValidation (New-DraftValidation) -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-DraftHttp)).reasonCodes|Should -Contain 'DraftBaselineChanged'
        $script:calls.Count|Should -Be 0
        (Invoke-DraftFixture $f).reasonCodes|Should -Contain 'DraftBaselineChanged'
        $script:calls.Count|Should -Be 0
    }

    # Scenario: SYP171-SCN-012; sync identity was edited after a confirmed Draft operation.
    # Purpose: A modified sync record cannot be used to manufacture no-op success.
    It 'UnitT85_rejects_changed_sync_before_remote_readback' {
        $f=New-DraftFixture
        (Invoke-DraftFixture $f).status|Should -Be 'drafted'
        $sync=Get-Content -LiteralPath $f.sync -Raw|ConvertFrom-Json -AsHashtable
        $sync.pages[0].pageId='102'
        [IO.File]::WriteAllText($f.sync,($sync|ConvertTo-Json -Depth 12))
        $script:calls.Clear()
        (Invoke-DraftFixture $f).reasonCodes|Should -Contain 'SyncJournalMismatch'
        $script:calls.Count|Should -Be 0
    }

    # Scenario: SYP171-SCN-012; successful PUT is followed by unrelated Draft body.
    # Purpose: HTTP 200 alone cannot advance sync or permit a second overwrite.
    It 'UnitT86_keeps_mismatched_Draft_readback_uncertain' {
        $f=New-DraftFixture;$script:mode='bad-readback'
        (Invoke-DraftFixture $f).status|Should -Be 'uncertain'
        Test-Path -LiteralPath $f.sync|Should -BeFalse
        $script:mode='normal';$script:calls.Clear()
        (Invoke-DraftFixture $f).status|Should -Be 'uncertain'
        @($script:calls|Where-Object Method -ne 'GET').Count|Should -Be 0
    }

    # Scenario: SYP171-SCN-009; a Draft payload cannot be parsed as safe storage XML.
    # Purpose: Invalid or oversized storage never reaches preflight or an immutable candidate.
    It 'UnitT87_rejects_invalid_Draft_storage_before_remote_reads' {
        Import-Module $planModule -Force
        $payload=[pscustomobject]@{projectionId='req-101';pageId='101';spaceId='55';parentId='99';title='Synthetic draft';bodyStorage='<p>';assetChanges=@()}
        $r=New-ConfluencePreviewPlan -PlanPath (Join-Path $script:fixtureRoot 'plan.json') -Validation (New-DraftValidation) -Payloads @($payload) -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-DraftHttp) -PublishMode draft
        $r.reasonCodes|Should -Contain 'DraftStorageInvalid'
        $script:calls.Count|Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:fixtureRoot 'plan.json')|Should -BeFalse
    }
}
