# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    Set-StrictMode -Version Latest
    $ErrorActionPreference='Stop'
    $script:repositoryRoot=Split-Path -Parent $PSScriptRoot
    $sourceSkill=Join-Path $script:repositoryRoot 'skills/manage-confluence-docs-as-code'
    $sourceAccessSkill=Join-Path $script:repositoryRoot 'skills/configure-confluence-api-access'
    $script:pwsh=[string][Environment]::ProcessPath
    if([string]::IsNullOrWhiteSpace($script:pwsh)){$script:pwsh=Join-Path $PSHOME 'pwsh.exe'}
    $script:site='https://example.atlassian.net'
    $script:cloud='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    $script:apiBase="https://api.atlassian.com/ex/confluence/$($script:cloud)"

    function Set-PushMockState {
        param([string]$StatePath,[string]$Storage='<p>Published baseline</p>',[int]$Version=7,[int]$WriteCount=0)
        $state=[ordered]@{
            page=[ordered]@{id='101';status='current';spaceId='55';parentId='99';title='General';version=[ordered]@{number=$Version;message=''};body=[ordered]@{storage=[ordered]@{value=$Storage}}}
            requests=@();writeCount=$WriteCount
        }
        [IO.File]::WriteAllText($StatePath,($state|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
    }

    function Test-PushCliTempParent {
        param([string]$Parent)
        $probeRoot=Join-Path $Parent ('syp171-push-cli-probe-'+[Guid]::NewGuid().ToString('N'))
        $probeRepo=Join-Path $probeRoot 'repo'
        $created=$false
        try {
            New-Item -ItemType Directory -Path $probeRepo -Force|Out-Null
            $created=$true
            & git -C $probeRepo init --quiet 2>$null
            if($LASTEXITCODE -ne 0){return $false}
            & git -C $probeRepo config user.name 'SYP-171 temp probe' 2>$null
            if($LASTEXITCODE -ne 0){return $false}
            & git -C $probeRepo config user.email 'probe@example.invalid' 2>$null
            return ($LASTEXITCODE -eq 0)
        } catch { return $false }
        finally {
            if($created -and (Test-Path -LiteralPath $probeRoot)){
                $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $probeRoot).Path)
                $parent=[IO.Path]::GetFullPath($Parent).TrimEnd('\','/')
                if([IO.Path]::GetDirectoryName($resolved).TrimEnd('\','/') -cne $parent -or
                    [IO.Path]::GetFileName($resolved) -cnotmatch '^syp171-push-cli-probe-[a-f0-9]{32}$'){
                    throw 'Unsafe Push temp probe cleanup target.'
                }
                Remove-Item -LiteralPath $resolved -Recurse -Force
            }
        }
    }

    function Get-PushCliTempParent {
        $candidates=@([IO.Path]::GetTempPath(),(Split-Path -Parent $script:repositoryRoot))
        $checkout=[IO.Path]::GetFullPath($script:repositoryRoot).TrimEnd('\','/')
        foreach($candidate in $candidates){
            if([string]::IsNullOrWhiteSpace($candidate)){continue}
            $resolved=[IO.Path]::GetFullPath($candidate).TrimEnd('\','/')
            $relative=[IO.Path]::GetRelativePath($checkout,$resolved)
            $outside=$relative -ceq '..' -or
                $relative.StartsWith(('..'+[string][IO.Path]::DirectorySeparatorChar),[StringComparison]::Ordinal) -or
                [IO.Path]::IsPathRooted($relative)
            if(-not $outside){continue}
            if(Test-PushCliTempParent -Parent $resolved){return $resolved}
        }
        throw 'No writable Git temporary parent outside the source checkout is available.'
    }

    function New-PushCliFixture {
        $tempParent=Get-PushCliTempParent
        $root=Join-Path $tempParent ('syp171-push-cli-'+[Guid]::NewGuid().ToString('N'))
        $created=$false
        try {
        $installRoot=Join-Path $root 'installed'
        $skillInstall=Join-Path $installRoot 'manage-confluence-docs-as-code'
        $accessInstall=Join-Path $installRoot 'configure-confluence-api-access'
        $repo=Join-Path $root 'docs-repo'
        New-Item -ItemType Directory -Path $root -Force|Out-Null
        $created=$true
        Copy-Item -LiteralPath $sourceSkill -Destination $skillInstall -Recurse
        Copy-Item -LiteralPath $sourceAccessSkill -Destination $accessInstall -Recurse
        $originalTransport=Get-Content -LiteralPath (Join-Path $skillInstall 'scripts/ConfluenceTransport.psm1') -Raw
        $startMarker='function Invoke-ConfluenceWireRead {'
        $endMarker='function Test-SignedDownloadUri {'
        $start=$originalTransport.IndexOf($startMarker,[StringComparison]::Ordinal)
        $end=$originalTransport.IndexOf($endMarker,$start,[StringComparison]::Ordinal)
        if($start -lt 0 -or $end -le $start){throw 'Could not isolate copied transport wire boundary.'}
        $wireStub=@'
function Invoke-ConfluenceWireRead {
    param([object]$Request)
    $statePath=$env:SYP171_PUSH_MOCK_STATE
    $state=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($statePath)) -AsHashtable -Depth 20 -ErrorAction Stop
    $uri=[Uri]$Request.Uri
    $method=[string]$Request.Method
    $event=[ordered]@{method=$method;path=$uri.AbsolutePath;query=$uri.Query}
    if($method -cne 'GET'){$event.body=[string]$Request.Body}
    $state.requests+=@($event)
    [IO.File]::WriteAllText($statePath,($state|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
    if($method -ceq 'GET'){
        $body=$state.page
        if($uri.Query.Contains('status=draft')){$body.status='draft'}else{$body.status='current'}
        $bytes=[Text.Encoding]::UTF8.GetBytes(($body|ConvertTo-Json -Depth 20 -Compress))
        [IO.File]::WriteAllText($statePath,($state|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        return [pscustomobject]@{StatusCode=200;Headers=@{};BodyBytes=$bytes}
    }
    if($method -ceq 'PUT'){
        try{
            $incoming=ConvertFrom-Json -InputObject ([string]$Request.Body) -AsHashtable -Depth 20 -ErrorAction Stop
            $state.writeCount=[int]$state.writeCount+1
            $state.page.status='current'
            $state.page.title=[string]$incoming.title
            $state.page.body.storage.value=[string]$incoming.body.value
            $state.page.version.number=[int]$incoming.version.number
            $state.page.version.message=[string]$incoming.version.message
            $bytes=[Text.Encoding]::UTF8.GetBytes(($state.page|ConvertTo-Json -Depth 20 -Compress))
            [IO.File]::WriteAllText($statePath,($state|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
            return [pscustomobject]@{StatusCode=200;Headers=@{};BodyBytes=$bytes}
        }catch{
            $state.lastError=$_.Exception.Message
            [IO.File]::WriteAllText($statePath,($state|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
            throw
        }
    }
    throw 'MockWireMethodUnexpected'
}
'@
        $patched=$originalTransport.Substring(0,$start)+$wireStub+$originalTransport.Substring($end)
        $wirePath=Join-Path $skillInstall 'scripts/ConfluenceTransport.psm1'
        [IO.File]::WriteAllText($wirePath,$patched,[Text.UTF8Encoding]::new($false))
        if($patched.Substring(0,$start) -cne $originalTransport.Substring(0,$start) -or
            $patched.Substring($start+$wireStub.Length) -cne $originalTransport.Substring($end)){
            throw 'Temporary transport copy changed outside the fake wire boundary.'
        }
        foreach($name in @('Push-ConfluenceDocs.ps1','ConfluenceValidation.psm1','ConfluenceMarkdownWorkflow.psm1','ConfluencePlan.psm1','ConfluencePublish.psm1','MarkdownProjection.psm1','ConfluenceMapping.psm1')){
            $copy=Join-Path $skillInstall ('scripts/'+$name)
            $source=Join-Path $sourceSkill ('scripts/'+$name)
            if((Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash){throw "Copied production module differs: $name"}
        }

        $accessPath=Join-Path $accessInstall 'scripts/Test-ConfluenceApiAccess.ps1'
        $accessStub=@'
param([switch]$TestConnection)
if(-not $TestConnection){throw 'ConnectionCheckRequired'}
$ready=([string]$env:SYP171_ACCESS_READY -ceq 'true')
[pscustomobject]@{
    ReadyForRead=$ready;HostReloadRequired=$false;ConfigurationState='valid';TenantIdentityState='match'
    SpaceReadCheck=[pscustomobject]@{Category='success'};PageReadCheck=[pscustomobject]@{Category='success'}
    HostEnvironmentState='process-ready';MissingProcessSettings=@();ScopeConflictSettings=@()
}
'@
        [IO.File]::WriteAllText($accessPath,$accessStub,[Text.UTF8Encoding]::new($false))

        New-Item -ItemType Directory -Path (Join-Path $repo 'docs') -Force|Out-Null
        New-Item -ItemType Directory -Path (Join-Path $repo '.confluence') -Force|Out-Null
        [IO.File]::WriteAllText((Join-Path $repo 'docs/general.md'),"# Overview`n`nOrdinary **Markdown**.",[Text.UTF8Encoding]::new($false))
        $mapping=[ordered]@{
            schemaVersion=4;adapter=@{id='powershell-markdown';version='1'};siteOrigin=$script:site;cloudId=$script:cloud;sourceMode='git-markdown'
            entries=@(@{projectionId='general-doc';sourceArtifact='docs/general.md';sourceSectionId='document';pageId='101';spaceId='55';parentId='99';parentProjectionId='';title='General';assets=@();linkBindings=@();contentKind='general'})
        }
        $mappingPath=Join-Path $repo '.confluence/mapping.json'
        [IO.File]::WriteAllText($mappingPath,($mapping|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        & git -C $repo init --quiet|Out-Null
        & git -C $repo config user.name 'SYP-171 Push fixture'|Out-Null
        & git -C $repo config user.email 'fixture@example.invalid'|Out-Null
        & git -C $repo add -- docs/general.md .confluence/mapping.json|Out-Null
        & git -C $repo commit --quiet -m 'Committed plain Markdown mapping'|Out-Null
        $commit=(& git -C $repo rev-parse HEAD).Trim()

        $statePath=Join-Path $root 'wire-state.json'
        Set-PushMockState -StatePath $statePath
        return [pscustomobject]@{
            root=$root;tempParent=$tempParent;repo=$repo;installRoot=$installRoot;pushPath=(Join-Path $skillInstall 'scripts/Push-ConfluenceDocs.ps1')
            mappingPath=$mappingPath;commit=$commit;planPath=(Join-Path $root 'plan.json');statePath=$statePath
        }
        } catch {
            if($created){Remove-PushCliFixture -Root $root -Parent $tempParent}
            throw
        }
    }

    function Invoke-PushCli {
        param($Fixture,[switch]$Execute,[string]$AuthorizationPath='',[string]$PlanPath='')
        $args=@('-NoLogo','-NoProfile','-NonInteractive','-File',$Fixture.pushPath)
        if($Execute){$args+=@('-Execute','-PlanPath',$(if($PlanPath){$PlanPath}else{$Fixture.planPath}),'-AuthorizationPath',$AuthorizationPath)}
        else{$args+=@('-Root',$Fixture.repo,'-MappingPath',$Fixture.mappingPath,'-DocsCommit',$Fixture.commit,'-PlanPath',$(if($PlanPath){$PlanPath}else{$Fixture.planPath}))}
        $output=@(& $script:pwsh @args 2>&1)
        $exitCode=$LASTEXITCODE
        $outputText=($output|ForEach-Object {[string]$_}) -join "`n"
        $jsonStart=$outputText.IndexOf('{',[StringComparison]::Ordinal)
        if($jsonStart -lt 0){throw "Push CLI returned no JSON. Exit=$exitCode Output=$outputText"}
        $resultJson=$outputText.Substring($jsonStart).Trim()
        return [pscustomobject]@{exitCode=$exitCode;result=($resultJson|ConvertFrom-Json -ErrorAction Stop);output=$output}
    }

    function Read-PushMockState { param($Fixture) return (ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Fixture.statePath)) -AsHashtable -Depth 20) }

    function Remove-PushCliFixture {
        param([string]$Root,[string]$Parent)
        if(-not(Test-Path -LiteralPath $Root)){return}
        $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path)
        $parent=[IO.Path]::GetFullPath($Parent).TrimEnd('\','/')
        if($parent -ceq [IO.Path]::GetFullPath($script:repositoryRoot).TrimEnd('\','/') -or
            [IO.Path]::GetDirectoryName($resolved).TrimEnd('\','/') -cne $parent -or
            [IO.Path]::GetFileName($resolved) -cnotmatch '^syp171-push-cli-[a-f0-9]{32}$'){throw 'Unsafe Push fixture cleanup target.'}
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }

    function New-LegacyV4Plan {
        $operation='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';$assetHash='b'*64
        $remoteName="syp171-general-doc-$assetHash.png"
        $page=[ordered]@{
            projectionId='general-doc';pageId='101';spaceId='55';parentId='99';parentProjectionId='';title='General'
            action='update';expectedPublishedVersion=7;expectedPublishedBodySha256=('a'*64);expectedParentVersion=$null;expectedParentBodySha256=$null
            expectedDraftObservation='captured';expectedDraftVersion=1;expectedDraftBodySha256=('c'*64)
            draftBaselinePath="plan-assets/$operation/$assetHash-draft-baseline.storage.xml"
            payloadPath="plan-assets/$operation/$assetHash.storage.xml";payloadSha256=$assetHash
            assetChanges=@(@{localPath='docs/assets/a.png';displayFilename='a.png';mediaType='image/png';remoteFilename=$remoteName;sha256=$assetHash;byteLength=1;payloadPath="plan-assets/$operation/$assetHash.asset";action='upload';remoteAttachmentId='';remoteVersion=0})
            intermediateWrites=@('draft-attachment-upload-or-reuse','draft-body-update','draft-and-attachment-readback')
        }
        return [ordered]@{
            schemaVersion=4;publishMode='draft';attachmentStrategy='immutable-content-name';operationId=$operation;createdAtUtc='2026-10-13T00:00:00.0000000Z'
            siteOrigin=$script:site;cloudId=$script:cloud;docsCommit=('1'*40);specCommit=('2'*40);codeCommit=('3'*40)
            sourceDigest=('4'*64);mappingDigest=('5'*64);reviewDigest=('6'*64);validatorVersion='1.13.0';rendererVersion='1'
            scenarioIds=@('SYP171-SCN-001');pages=@($page);validationInputs=$null
        }
    }
}

Describe 'SYP-171 public Push Preview and Execute contract' {
    BeforeAll {
        $script:oldEnvironment=@{}
        foreach($name in @('CONFLUENCE_BASE_URL','CONFLUENCE_API_BASE_URL','CONFLUENCE_CLOUD_ID','CONFLUENCE_EMAIL','CONFLUENCE_API_TOKEN','SYP171_PUSH_MOCK_STATE','SYP171_ACCESS_READY')){
            $script:oldEnvironment[$name]=[Environment]::GetEnvironmentVariable($name,'Process')
        }
    }
    BeforeEach {
        $script:fixture=New-PushCliFixture
        $env:CONFLUENCE_BASE_URL=$script:site;$env:CONFLUENCE_API_BASE_URL=$script:apiBase;$env:CONFLUENCE_CLOUD_ID=$script:cloud
        $env:CONFLUENCE_EMAIL='fixture@example.invalid';$env:CONFLUENCE_API_TOKEN='fixture-token-only'
        $env:SYP171_PUSH_MOCK_STATE=$script:fixture.statePath
    }
    AfterEach {if($null -ne $script:fixture){Remove-PushCliFixture -Root $script:fixture.root -Parent $script:fixture.tempParent;$script:fixture=$null}}
    AfterAll {foreach($name in $script:oldEnvironment.Keys){[Environment]::SetEnvironmentVariable($name,$script:oldEnvironment[$name],'Process')}}

    # Scenario: A contributor previews, rejects old or mismatched authorization, then publishes and retries.
    # Purpose: Exercise the installed public Push entry with real source, plan, publish, readback, and no-op behavior.
    It 'InterT10_previews_get_only_rejects_legacy_and_bad_auth_then_readbacks_once_and_repeats_as_no_op' {
        $env:SYP171_ACCESS_READY='false'
        $notReady=Invoke-PushCli -Fixture $script:fixture
        $notReady.exitCode | Should -Be 10
        $notReady.result.status | Should -Be 'blocked'
        @($notReady.result.reasonCodes) | Should -Contain 'AccessNotReady'
        @((Read-PushMockState $script:fixture).requests).Count | Should -Be 0

        $env:SYP171_ACCESS_READY='true'
        $preview=Invoke-PushCli -Fixture $script:fixture
        $preview.exitCode | Should -Be 0
        $preview.result.status | Should -Be 'preview'
        $plan=Get-Content -LiteralPath $script:fixture.planPath -Raw|ConvertFrom-Json -AsHashtable -Depth 20
        $plan.schemaVersion | Should -Be 5
        $state=Read-PushMockState $script:fixture
        @($state.requests|Where-Object method -ne 'GET').Count | Should -Be 0
        @($state.requests|Where-Object method -eq 'GET').Count | Should -BeGreaterThan 0

        Set-PushMockState -StatePath $script:fixture.statePath
        $legacyPath=Join-Path $script:fixture.root 'legacy-v4-plan.json'
        $unusedAuthPath=Join-Path $script:fixture.root 'unused-auth.json'
        [IO.File]::WriteAllText($legacyPath,(New-LegacyV4Plan|ConvertTo-Json -Depth 16),[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($unusedAuthPath,'{}',[Text.UTF8Encoding]::new($false))
        $legacy=Invoke-PushCli -Fixture $script:fixture -Execute -PlanPath $legacyPath -AuthorizationPath $unusedAuthPath
        $legacy.exitCode | Should -Be 30
        $legacy.result.status | Should -Be 'invalid'
        @($legacy.result.reasonCodes) | Should -Contain 'PlanSchemaInvalid'
        @((Read-PushMockState $script:fixture).requests).Count | Should -Be 0

        $authPath=Join-Path $script:fixture.root 'authorization.json'
        $planDigest=(Get-FileHash -LiteralPath $script:fixture.planPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $auth=[ordered]@{schemaVersion=1;planSha256=('0'*64);operationId=$plan.operationId;siteOrigin=$script:site;cloudId=$script:cloud;approvedActions=@('update:101');approvalEvidenceRef='fixture-approval'}
        [IO.File]::WriteAllText($authPath,($auth|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        $badAuth=Invoke-PushCli -Fixture $script:fixture -Execute -AuthorizationPath $authPath
        $badAuth.exitCode | Should -Be 10
        $badAuth.result.status | Should -Be 'blocked'
        @($badAuth.result.reasonCodes) | Should -Contain 'AuthorizationMismatch'
        @((Read-PushMockState $script:fixture).requests).Count | Should -Be 0

        $auth.planSha256=$planDigest
        $auth.approvedActions=@('update:101')
        [IO.File]::WriteAllText($authPath,($auth|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        $accepted=Invoke-PushCli -Fixture $script:fixture -Execute -AuthorizationPath $authPath
        $acceptedState=Read-PushMockState $script:fixture
        $accepted.exitCode | Should -Be 0 -Because (ConvertTo-Json -InputObject @{result=$accepted.result;state=$acceptedState} -Compress -Depth 12)
        $accepted.result.status | Should -Be 'published'
        $state=Read-PushMockState $script:fixture
        $state.writeCount | Should -Be 1
        @($state.requests|Where-Object method -eq 'PUT').Count | Should -Be 1
        $state.page.version.number | Should -Be 8
        $payloadPath=Join-Path (Split-Path -Parent $script:fixture.planPath) ([string]$plan.pages[0].payloadPath)
        $state.page.body.storage.value | Should -Be ([IO.File]::ReadAllText($payloadPath))

        $again=Invoke-PushCli -Fixture $script:fixture -Execute -AuthorizationPath $authPath
        $again.exitCode | Should -Be 0
        $again.result.status | Should -Be 'no-op'
        $state=Read-PushMockState $script:fixture
        $state.writeCount | Should -Be 1
        @($state.requests|Where-Object method -eq 'PUT').Count | Should -Be 1
    }
}
