# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repositoryRoot=Split-Path -Parent $PSScriptRoot
$planModule=Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluencePlan.psm1'
$publishModule=Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluencePublish.psm1'
$site='https://example.atlassian.net'
$cloud='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
$api="https://api.atlassian.com/ex/confluence/$cloud"
$newStorage='<h2>General Markdown</h2><p>Expected once</p>'

function New-PublishFixture {
    $root=Join-Path ([IO.Path]::GetTempPath()) ('syp171-publish-tests-'+[Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    return $root
}
function Remove-PublishFixture {
    param([string]$Root)
    if(-not(Test-Path -LiteralPath $Root)){return}
    $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    if([IO.Path]::GetDirectoryName($resolved).TrimEnd('\','/') -cne $parent -or [IO.Path]::GetFileName($resolved) -cnotmatch '^syp171-publish-tests-[a-f0-9]{32}$'){throw 'Unsafe publish fixture delete.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
function New-PublishValidation {
    return [pscustomobject]@{status='valid';siteOrigin=$site;cloudId=$cloud;docsCommit=('1'*40);codeCommit='';sourceMode='git-markdown';sourceDigest=('a'*64);mappingDigest=('b'*64);reviewDigest='';validatorVersion='powershell-markdown-v1';rendererVersion='powershell-markdown-v1'}
}
function New-PublishHttp {
    return {
        param($Request)
        $script:calls.Add([pscustomobject]@{Method=$Request.Method;Uri=[string]$Request.Uri})
        if($Request.Method -eq 'PUT'){
            $body=$Request.Body|ConvertFrom-Json -AsHashtable
            if($script:tamperPayloadPath -ne '' -and [string]$body.body.value -cne $newStorage){throw 'Write used changed staged bytes after preflight'}
            $script:remoteVersion++
            $script:remoteStorage=$body.body.value
            $script:remoteMessage=$body.version.message
            if($script:mode -eq 'timeout-after-put'){$script:remoteMessage='';throw 'Synthetic response timeout'}
            if($script:mode -eq 'wrong-readback'){$script:remoteStorage='<p>Different body</p>'}
            if($script:mode -eq 'normalized-readback'){$script:remoteStorage='<p title="A &#38; B" class="note">A &#38; B</p>'}
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{id='101';version=@{number=$script:remoteVersion}}}
        }
        if($script:tamperPayloadPath -ne '' -and -not $script:tamperedPayload){
            [IO.File]::WriteAllText($script:tamperPayloadPath,'<p>Changed after preflight</p>',[Text.UTF8Encoding]::new($false))
            $script:tamperedPayload=$true
        }
        $page=@{id='101';spaceId='55';parentId='99';title='Synthetic SDD';status='current';version=@{number=$script:remoteVersion;message=$script:remoteMessage};body=@{storage=@{value=$script:remoteStorage}}}
        return [pscustomobject]@{StatusCode=200;Headers=@{};Body=$page}
    }
}
function New-PublishPlanFixture {
    param([string]$BodyStorage=$newStorage,[string]$PlanName='plan')
    Import-Module -Name $planModule -Force
    $payload=@([pscustomobject]@{projectionId='req-001';pageId='101';spaceId='55';parentId='99';title='Synthetic SDD';bodyStorage=$BodyStorage;assetChanges=@()})
    $r=New-ConfluencePreviewPlan -PlanPath (Join-Path $script:fixtureRoot "$PlanName.json") -Validation (New-PublishValidation) -Payloads $payload -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-PublishHttp)
    if($r.status -ne 'preview'){throw "Fixture preview failed: $($r.reasonCodes -join ',')"}
    $plan=Get-Content -LiteralPath $r.planPath -Raw|ConvertFrom-Json
    $approved=@(foreach($page in @($plan.pages|Where-Object action -ne 'no-op')){
        $identity=if($page.action -ceq 'create'){$page.projectionId}else{$page.pageId}
        "$($page.action):$identity"
    })
    $authorization=@{schemaVersion=1;planSha256=$r.planSha256;operationId=$plan.operationId;siteOrigin=$site;cloudId=$cloud;approvedActions=$approved;approvalEvidenceRef='synthetic-test-fixture-only'}
    $authPath=Join-Path $script:fixtureRoot "$PlanName-authorization.json"
    [IO.File]::WriteAllText($authPath,($authorization|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{plan=$r.planPath;auth=$authPath;journal=(Join-Path $script:fixtureRoot "$PlanName-journal.json");sync=(Join-Path $script:fixtureRoot "$PlanName-sync.json")}
}
function Invoke-PublishFixture {
    param($Fixture)
    if(-not(Test-Path -LiteralPath $publishModule)){throw 'Publish module missing.'}
    Import-Module -Name $publishModule -Force
    return Invoke-ConfluencePlan -PlanPath $Fixture.plan -CurrentValidation (New-PublishValidation) -AuthorizationPath $Fixture.auth -JournalPath $Fixture.journal -SyncPath $Fixture.sync -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-PublishHttp)
}

}

Describe 'SYP-171 write journal, readback and no-op' {
    BeforeEach{$script:fixtureRoot=New-PublishFixture;$script:calls=[System.Collections.Generic.List[object]]::new();$script:remoteVersion=7;$script:remoteStorage='<p>Previous</p>';$script:remoteMessage='';$script:mode='normal';$script:tamperPayloadPath='';$script:tamperedPayload=$false}
    AfterEach{Remove-PublishFixture -Root $script:fixtureRoot}

    # Scenario: SYP171-SCN-012; exact update succeeds and is read back.
    # Purpose: Only verified identity/version/body advances sync; rerun adds no version.
    It 'InterT10_updates_once_reads_back_and_reruns_no_op' {
        $f=New-PublishPlanFixture
        $r=Invoke-PublishFixture $f
        $r.status | Should -Be 'published'
        $script:remoteVersion | Should -Be 8
        (Test-Path -LiteralPath $f.sync) | Should -Be $true
        foreach($pair in @(@($f.plan,'publish-plan'),@($f.auth,'authorization'),@($f.journal,'operation-journal'),@($f.sync,'sync-state'))){
            Test-Json -Json (Get-Content -LiteralPath $pair[0] -Raw) -SchemaFile (Join-Path $repositoryRoot "skills/manage-confluence-docs-as-code/references/$($pair[1]).schema.json") | Should -BeTrue
        }
        $script:calls.Clear()
        $r=Invoke-PublishFixture $f
        $r.status | Should -Be 'no-op'
        $script:remoteVersion | Should -Be 8
        @($script:calls|Where-Object Method -ne 'GET').Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-011; PUT may have reached the server but response timed out.
    # Purpose: An uncertain operation is investigated under the same ID and never blindly resent.
    It 'UnitT20_keeps_uncertain_timeout_without_second_put' {
        $f=New-PublishPlanFixture
        $script:mode='timeout-after-put'
        $r=Invoke-PublishFixture $f
        $r.status | Should -Be 'uncertain'
        (Test-Path -LiteralPath $f.sync) | Should -Be $false
        $script:calls.Clear();$script:mode='normal'
        $r=Invoke-PublishFixture $f
        @($script:calls|Where-Object Method -eq 'PUT').Count | Should -Be 0
        $r.status | Should -BeIn @('uncertain','published')
    }

    # Scenario: SYP171-SCN-012; remote body differs after an accepted response.
    # Purpose: A false-success readback does not advance sync.
    It 'UnitT30_keeps_journal_when_readback_body_mismatches' {
        $f=New-PublishPlanFixture
        $script:mode='wrong-readback'
        $r=Invoke-PublishFixture $f
        $r.status | Should -Be 'uncertain'
        (Test-Path -LiteralPath $f.journal) | Should -Be $true
        (Test-Path -LiteralPath $f.sync) | Should -Be $false
    }

    # Scenario: SYP171-SCN-011/012; a confirmed operation journal gains an unknown authority field.
    # Purpose: Resume rejects changed operation state before treating remote readback as a no-op.
    It 'UnitT32_rejects_changed_journal_shape_before_HTTP' {
        $f=New-PublishPlanFixture
        (Invoke-PublishFixture $f).status | Should -Be 'published'
        $journal=Get-Content -LiteralPath $f.journal -Raw|ConvertFrom-Json -AsHashtable
        $journal['THEN']='Synthetic expected result shadow'
        [IO.File]::WriteAllText($f.journal,($journal|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
        $script:calls.Clear()
        $r=Invoke-PublishFixture $f
        $r.status | Should -Be 'invalid'
        @($r.reasonCodes) | Should -Contain 'JournalInvalid'
        $script:calls.Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-012; the confirmed sync baseline changes after readback.
    # Purpose: File existence alone cannot turn a changed baseline into a no-op.
    It 'UnitT35_rejects_changed_sync_baseline_before_HTTP' {
        $f=New-PublishPlanFixture
        (Invoke-PublishFixture $f).status | Should -Be 'published'
        $sync=Get-Content -LiteralPath $f.sync -Raw|ConvertFrom-Json -AsHashtable
        $sync.sourceDigest='f'*64
        [IO.File]::WriteAllText($f.sync,($sync|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
        $script:calls.Clear()
        $r=Invoke-PublishFixture $f
        $r.status | Should -Be 'blocked'
        @($r.reasonCodes) | Should -Contain 'SyncBaselineMismatch'
        $script:calls.Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-007; approval is for a different immutable candidate.
    # Purpose: No external request is sent when the plan authorization digest differs.
    It 'UnitT40_blocks_different_candidate_authorization_before_HTTP' {
        $f=New-PublishPlanFixture
        $auth=Get-Content -LiteralPath $f.auth -Raw|ConvertFrom-Json -AsHashtable
        $auth.planSha256='f'*64
        [IO.File]::WriteAllText($f.auth,($auth|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
        $script:calls.Clear()
        $r=Invoke-PublishFixture $f
        @($r.reasonCodes) | Should -Contain 'AuthorizationMismatch'
        $script:calls.Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-007; authorization repeats an action scope.
    # Purpose: Approval scope is an exact set and cannot contain ambiguous duplicate entries.
    It 'UnitT42_rejects_duplicate_authorization_action_before_HTTP' {
        $f=New-PublishPlanFixture
        $auth=Get-Content -LiteralPath $f.auth -Raw|ConvertFrom-Json -AsHashtable
        $auth.approvedActions=@('update:101','update:101')
        [IO.File]::WriteAllText($f.auth,($auth|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
        $script:calls.Clear()
        $r=Invoke-PublishFixture $f
        $r.status | Should -Be 'blocked'
        @($r.reasonCodes) | Should -Contain 'AuthorizationMismatch'
        $script:calls.Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-007; authorization includes an action absent from the immutable plan.
    # Purpose: Approval scope must equal the candidate write set and cannot grant unrelated future work.
    It 'UnitT43_rejects_extra_authorization_action_before_HTTP' {
        $f=New-PublishPlanFixture
        $auth=Get-Content -LiteralPath $f.auth -Raw|ConvertFrom-Json -AsHashtable
        $auth.approvedActions=@('update:101','create:unrelated')
        [IO.File]::WriteAllText($f.auth,($auth|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
        $script:calls.Clear()
        $r=Invoke-PublishFixture $f
        $r.status | Should -Be 'blocked'
        @($r.reasonCodes) | Should -Contain 'AuthorizationMismatch'
        $script:calls.Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-007/008; a digest-matched plan contains a second expected-result authority field.
    # Purpose: Human authorization of bytes cannot make an unknown plan property part of the publication contract.
    It 'UnitT45_rejects_THEN_shadow_in_digest_matched_plan_before_HTTP' {
        $f=New-PublishPlanFixture
        $plan=Get-Content -LiteralPath $f.plan -Raw|ConvertFrom-Json -AsHashtable -Depth 18
        $plan['THEN']='Synthetic expected result shadow'
        $bytes=[Text.Encoding]::UTF8.GetBytes(($plan|ConvertTo-Json -Depth 18))
        [IO.File]::WriteAllBytes($f.plan,$bytes)
        $digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        [IO.File]::WriteAllText("$($f.plan).sha256",$digest+[char]10,[Text.UTF8Encoding]::new($false))
        $auth=Get-Content -LiteralPath $f.auth -Raw|ConvertFrom-Json -AsHashtable
        $auth.planSha256=$digest
        [IO.File]::WriteAllText($f.auth,($auth|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
        $script:calls.Clear()
        $r=Invoke-PublishFixture $f
        $r.status | Should -Be 'invalid'
        @($r.reasonCodes) | Should -Contain 'PlanSchemaInvalid'
        $script:calls.Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-007; a valid immutable plan is executed with an API base that URI parsing would normalize.
    # Purpose: Publish authorization must retain the plan's raw-string endpoint identity check before any HTTP request.
    It 'UnitT46_blocks_uri_normalized_api_base_before_HTTP' {
        $f=New-PublishPlanFixture
        $script:calls.Clear()
        Import-Module -Name $publishModule -Force
        $r=Invoke-ConfluencePlan -PlanPath $f.plan -CurrentValidation (New-PublishValidation) -AuthorizationPath $f.auth -JournalPath $f.journal -SyncPath $f.sync -ExpectedSiteOrigin $site -ApiBase ($api.Replace('api.atlassian.com', 'api.atlassian.com:443')) -HttpInvoker (New-PublishHttp)
        $r.status | Should -Be 'blocked'
        @($r.reasonCodes) | Should -Contain 'AuthorizationMismatch'
        $script:calls.Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-007/008; a digest-matched plan repeats the same schema key.
    # Purpose: Duplicate JSON keys are invalid even when both values happen to match and authorization names those bytes.
    It 'UnitT47_rejects_duplicate_plan_property_before_HTTP' {
        $f=New-PublishPlanFixture
        $json=Get-Content -LiteralPath $f.plan -Raw
        $json=$json.Replace('"schemaVersion": 5,','"schemaVersion": 5, "schemaVersion": 5,')
        $bytes=[Text.UTF8Encoding]::new($false).GetBytes($json)
        [IO.File]::WriteAllBytes($f.plan,$bytes)
        $digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        [IO.File]::WriteAllText("$($f.plan).sha256",$digest+[char]10,[Text.UTF8Encoding]::new($false))
        $auth=Get-Content -LiteralPath $f.auth -Raw|ConvertFrom-Json -AsHashtable
        $auth.planSha256=$digest
        [IO.File]::WriteAllText($f.auth,($auth|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
        $script:calls.Clear()
        $r=Invoke-PublishFixture $f
        $r.status | Should -Be 'invalid'
        @($r.reasonCodes) | Should -Contain 'PlanOrAuthorizationInvalid'
        $script:calls.Count | Should -Be 0
    }

    # Scenario: Ordinary authored Markdown is previewed and published without imported-source or code-current evidence.
    # Purpose: The v5 plan carries no synthetic specification commit, code commit, or scenario acceptance state.
    It 'InterT50_publishes_ordinary_markdown_without_invented_evidence' {
        $f=New-PublishPlanFixture
        $plan=Get-Content -LiteralPath $f.plan -Raw|ConvertFrom-Json -AsHashtable
        $plan.schemaVersion | Should -Be 5
        $plan.sourceMode | Should -Be 'git-markdown'
        $plan.codeCommit | Should -Be ''
        $plan.Contains('specCommit') | Should -Be $false
        $plan.Contains('scenarioIds') | Should -Be $false
        $r=Invoke-PublishFixture $f
        $r.status | Should -Be 'published'
        $script:remoteStorage | Should -Be $newStorage
        $script:remoteStorage | Should -Not -Match '\b(approvalStatus|implementationStatus|scenarioAcceptance|publishEligibility|PASS)\b'
        @($script:calls|Where-Object Method -notin @('GET','PUT')).Count | Should -Be 0
        $script:calls.Clear()
        (Invoke-PublishFixture $f).status | Should -Be 'no-op'
        @($script:calls|Where-Object Method -ne 'GET').Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-007/010/012; staged bytes can change after static validation but before PUT.
    # Purpose: The write must use frozen validated bytes, and the next invocation must reject changed staged files.
    It 'UnitT60_freezes_validated_body_bytes_before_remote_preflight_and_write' {
        $f=New-PublishPlanFixture
        $plan=Get-Content -LiteralPath $f.plan -Raw|ConvertFrom-Json
        $script:tamperPayloadPath=Join-Path $script:fixtureRoot ([string]$plan.pages[0].payloadPath)
        $script:calls.Clear()
        (Invoke-PublishFixture $f).status | Should -Be 'published'
        $script:tamperedPayload | Should -Be $true
        $script:remoteStorage | Should -Be $newStorage
        $script:calls.Clear()
        $again=Invoke-PublishFixture $f
        $again.status | Should -Be 'blocked'
        @($again.reasonCodes) | Should -Contain 'PayloadChanged'
        @($script:calls|Where-Object Method -eq 'PUT').Count | Should -Be 0
    }

    # Scenario: Current storage contains the same XML structure and text with entity spelling and attribute order changed by Confluence.
    # Purpose: Preview and publish treat only the existing storage helper's equivalence contract as a no-op.
    # Given: The remote current page is serialization-equivalent to the requested body.
    # When: A plan is previewed, executed, previewed again, and executed again.
    # Then: Both plans remain no-op and neither execution sends a PUT.
    It 'UnitT65_keeps_serialization_equivalent_current_storage_no_op_across_preview_and_execute' {
        $expected='<p class="note" title="A &amp; B">A &amp; B</p>'
        $script:remoteStorage='<p title="A &#38; B" class="note">A &#38; B</p>'
        $f=New-PublishPlanFixture -BodyStorage $expected -PlanName 'normalized-current'
        $plan=Get-Content -LiteralPath $f.plan -Raw|ConvertFrom-Json
        $plan.pages[0].action | Should -Be 'no-op'
        (Invoke-PublishFixture $f).status | Should -Be 'no-op'
        @($script:calls|Where-Object Method -eq 'PUT').Count | Should -Be 0

        $script:calls.Clear()
        $again=New-PublishPlanFixture -BodyStorage $expected -PlanName 'normalized-current-again'
        $againPlan=Get-Content -LiteralPath $again.plan -Raw|ConvertFrom-Json
        $againPlan.pages[0].action | Should -Be 'no-op'
        (Invoke-PublishFixture $again).status | Should -Be 'no-op'
        (Invoke-PublishFixture $again).status | Should -Be 'no-op'
        @($script:calls|Where-Object Method -eq 'PUT').Count | Should -Be 0
    }

    # Scenario: A current page PUT succeeds, then Confluence returns equivalent XML with different attribute order and entity spelling.
    # Purpose: Readback confirms the intended storage without repeating a final write on resume.
    # Given: The target page needs an update and the HTTP fixture normalizes server readback serialization.
    # When: The same operation executes twice.
    # Then: The first run publishes, the second is no-op, and exactly one PUT is sent.
    It 'UnitT66_accepts_equivalent_current_write_readback_without_second_put' {
        $expected='<p class="note" title="A &amp; B">A &amp; B</p>'
        $f=New-PublishPlanFixture -BodyStorage $expected -PlanName 'normalized-write'
        $script:mode='normalized-readback'

        (Invoke-PublishFixture $f).status | Should -Be 'published'
        @($script:calls|Where-Object Method -eq 'PUT').Count | Should -Be 1
        $script:remoteStorage | Should -Be '<p title="A &#38; B" class="note">A &#38; B</p>'

        $script:mode='normal';$script:calls.Clear()
        (Invoke-PublishFixture $f).status | Should -Be 'no-op'
        @($script:calls|Where-Object Method -eq 'PUT').Count | Should -Be 0
    }
}
