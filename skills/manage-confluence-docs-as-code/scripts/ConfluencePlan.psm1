# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
Import-Module -Name (Join-Path $PSScriptRoot 'ConfluenceTransport.psm1') -Force -Scope Local
Import-Module -Name (Join-Path $PSScriptRoot 'ConfluenceAssets.psm1') -Force -Scope Local
Import-Module -Name (Join-Path $PSScriptRoot 'StrictJson.psm1') -Force -Scope Local
Import-Module -Name (Join-Path $PSScriptRoot 'ConfluenceStorage.psm1') -Force -Scope Local

function New-PlanResult {
    param([string]$Status,[string[]]$ReasonCodes,[string]$PlanPath,[string]$PlanSha256)
    return [pscustomobject]@{status=$Status;reasonCodes=@($ReasonCodes);planPath=$PlanPath;planSha256=$PlanSha256}
}

function Test-ConfluencePlanShape {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Plan)
    if($Plan -is [System.Collections.IDictionary] -and $Plan.schemaVersion -in @(3,4)){return Test-DraftPlanShape -Plan $Plan}
    $version=[long]0
    if($Plan -isnot [System.Collections.IDictionary] -or
        -not(Test-Syp171JsonInteger -Value $Plan.schemaVersion -Minimum 1) -or
        -not [long]::TryParse([string]$Plan.schemaVersion,[ref]$version) -or
        $version -notin @(1,2)){return $false}
    $top=@('schemaVersion','operationId','createdAtUtc','siteOrigin','cloudId','docsCommit','specCommit','codeCommit',
        'sourceDigest','mappingDigest','reviewDigest','validatorVersion','rendererVersion','scenarioIds','pages','validationInputs')
    if($version -eq 2){$top+=@('linkStrategy')}
    if(-not(Test-Syp171JsonKeys -Value $Plan -Expected $top) -or
        [string]$Plan.operationId -cnotmatch '^[a-f0-9]{32}$' -or
        [string]$Plan.siteOrigin -cnotmatch '^https://[^/?#]+$' -or
        [string]$Plan.cloudId -cnotmatch '^[a-fA-F0-9-]{36}$' -or
        [string]$Plan.docsCommit -cnotmatch '^[a-f0-9]{40}$' -or
        [string]$Plan.specCommit -cnotmatch '^[a-f0-9]{40}$' -or
        [string]$Plan.codeCommit -cnotmatch '^[a-f0-9]{40}$' -or
        [string]$Plan.sourceDigest -cnotmatch '^[a-f0-9]{64}$' -or
        [string]$Plan.mappingDigest -cnotmatch '^[a-f0-9]{64}$' -or
        [string]$Plan.reviewDigest -cnotmatch '^[a-f0-9]{64}$' -or
        [string]::IsNullOrWhiteSpace([string]$Plan.validatorVersion) -or
        [string]::IsNullOrWhiteSpace([string]$Plan.rendererVersion) -or
        $Plan.scenarioIds -isnot [array] -or @($Plan.scenarioIds).Count -eq 0 -or
        @($Plan.scenarioIds|Where-Object {[string]::IsNullOrWhiteSpace([string]$_)}).Count -gt 0 -or
        @($Plan.scenarioIds|Select-Object -Unique).Count -ne @($Plan.scenarioIds).Count -or
        $Plan.pages -isnot [array] -or @($Plan.pages).Count -eq 0 -or @($Plan.pages).Count -gt 100 -or
        ($version -eq 2 -and [string]$Plan.linkStrategy -cne 'identity-first')){return $false}
    $created=$Plan.createdAtUtc
    if($created -is [datetime]){
        if($created.Kind -ne [DateTimeKind]::Utc){return $false}
    }elseif($created -is [datetimeoffset]){
        if($created.Offset -ne [TimeSpan]::Zero){return $false}
    }elseif($created -is [string]){
        $parsed=[DateTimeOffset]::MinValue
        if($created -cnotmatch 'Z$|\+00:00$' -or -not [DateTimeOffset]::TryParse(
            [string]$created,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed)){return $false}
    }else{return $false}
    if($null -ne $Plan.validationInputs){
        if($Plan.validationInputs -isnot [System.Collections.IDictionary]){return $false}
        $inputKeys=@($Plan.validationInputs.Keys|Sort-Object)
        $assetOnly=(Test-Syp171JsonKeys -Value $Plan.validationInputs -Expected @('root'))
        $full=(Test-Syp171JsonKeys -Value $Plan.validationInputs -Expected @('root','mappingPath','docsCommit','codeBindingPath','reviewPath','runtimeRoot'))
        if((-not $assetOnly -and -not $full) -or
            @($inputKeys|Where-Object {[string]::IsNullOrWhiteSpace([string]$Plan.validationInputs[$_])}).Count -gt 0 -or
            ($full -and [string]$Plan.validationInputs.docsCommit -cnotmatch '^[a-f0-9]{40}$')){return $false}
    }
    $projections=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $identities=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $allowedWrites=@('create','update','no-op','page-create-intermediate','page-create-readback','link-resolution',
        'attachment-upload','attachment-upload-or-reuse','final-page-body-update','page-body-update','attachment-and-page-readback')
    foreach($page in @($Plan.pages)){
        $pageKeys=@('projectionId','pageId','spaceId','parentId','parentProjectionId','title','action','expectedPublishedVersion',
            'expectedPublishedBodySha256','expectedParentVersion','expectedParentBodySha256','expectedDraftObservation',
            'payloadPath','payloadSha256','assetChanges','intermediateWrites')
        if($version -eq 2){$pageKeys+=@('deferredTargets')}
        if(-not(Test-Syp171JsonKeys -Value $page -Expected $pageKeys) -or
            [string]$page.projectionId -cnotmatch '^[a-z][a-z0-9-]{0,49}$' -or
            -not $projections.Add([string]$page.projectionId) -or
            [string]$page.pageId -cnotmatch '^([0-9]+)?$' -or
            [string]$page.spaceId -cnotmatch '^[0-9]+$' -or
            [string]$page.parentId -cnotmatch '^([0-9]+)?$' -or
            [string]$page.parentProjectionId -cnotmatch '^([a-z][a-z0-9-]{0,49})?$' -or
            [string]::IsNullOrWhiteSpace([string]$page.title) -or
            $page.action -notin @('create','update','no-op') -or
            -not(Test-Syp171JsonInteger -Value $page.expectedPublishedVersion) -or
            [string]$page.expectedPublishedBodySha256 -cnotmatch '^([a-f0-9]{64})?$' -or
            ($null -ne $page.expectedParentVersion -and -not(Test-Syp171JsonInteger -Value $page.expectedParentVersion -Minimum 1)) -or
            ($null -ne $page.expectedParentBodySha256 -and [string]$page.expectedParentBodySha256 -cnotmatch '^[a-f0-9]{64}$') -or
            $page.expectedDraftObservation -cne 'same-as-published' -or
            [string]::IsNullOrWhiteSpace([string]$page.payloadPath) -or
            [string]$page.payloadSha256 -cnotmatch '^[a-f0-9]{64}$' -or
            $page.assetChanges -isnot [array] -or @($page.assetChanges).Count -gt 25 -or
            $page.intermediateWrites -isnot [array] -or @($page.intermediateWrites).Count -eq 0 -or
            @($page.intermediateWrites|Where-Object {$_ -notin $allowedWrites}).Count -gt 0){return $false}
        $identity=if($page.action -ceq 'create'){"create:$($page.projectionId)"}else{"page:$($page.pageId)"}
        if(-not $identities.Add($identity)){return $false}
        if($page.action -ceq 'create'){
            if([string]$page.pageId -ne '' -or [long]$page.expectedPublishedVersion -ne 0){return $false}
        }elseif([string]$page.pageId -cnotmatch '^[0-9]+$' -or [long]$page.expectedPublishedVersion -lt 1){return $false}
        if([string]$page.parentProjectionId -ne '' -and
            ($page.action -cne 'create' -or [string]$page.parentId -ne '' -or
             $null -ne $page.expectedParentVersion -or $null -ne $page.expectedParentBodySha256)){return $false}
        if($version -eq 2 -and
            ($page.deferredTargets -isnot [array] -or @($page.deferredTargets).Count -gt 100 -or
             @($page.deferredTargets|Where-Object {[string]$_ -cnotmatch '^[a-z][a-z0-9-]{0,49}$'}).Count -gt 0 -or
             @($page.deferredTargets|Select-Object -Unique).Count -ne @($page.deferredTargets).Count)){return $false}
        foreach($asset in @($page.assetChanges)){
            if(-not(Test-Syp171JsonKeys -Value $asset -Expected @('localPath','displayFilename','mediaType','remoteFilename','sha256',
                    'byteLength','payloadPath','action','remoteAttachmentId','remoteVersion')) -or
                [string]::IsNullOrWhiteSpace([string]$asset.localPath) -or
                [string]::IsNullOrWhiteSpace([string]$asset.displayFilename) -or
                [string]::IsNullOrWhiteSpace([string]$asset.mediaType) -or
                [string]::IsNullOrWhiteSpace([string]$asset.remoteFilename) -or
                [string]$asset.sha256 -cnotmatch '^[a-f0-9]{64}$' -or
                -not(Test-Syp171JsonInteger -Value $asset.byteLength) -or [long]$asset.byteLength -gt 20MB -or
                [string]::IsNullOrWhiteSpace([string]$asset.payloadPath) -or
                $asset.action -notin @('upload','reuse') -or
                [string]$asset.remoteAttachmentId -cnotmatch '^([0-9]+)?$' -or
                -not(Test-Syp171JsonInteger -Value $asset.remoteVersion)){return $false}
            if($asset.action -ceq 'upload'){
                if([string]$asset.remoteAttachmentId -ne '' -or [long]$asset.remoteVersion -ne 0){return $false}
            }elseif([string]$asset.remoteAttachmentId -cnotmatch '^[0-9]+$' -or [long]$asset.remoteVersion -lt 1){return $false}
        }
        $expectedWrites=if($version -eq 2 -and $page.action -ceq 'create'){@('page-create-intermediate','page-create-readback','link-resolution','attachment-upload-or-reuse','final-page-body-update','attachment-and-page-readback')}
            elseif($version -eq 2 -and $page.action -ceq 'update'){@('link-resolution','attachment-upload-or-reuse','page-body-update','attachment-and-page-readback')}
            elseif($page.action -ceq 'no-op'){@('no-op')}
            elseif(@($page.assetChanges).Count -eq 0){@($page.action)}
            elseif($page.action -ceq 'create'){@('page-create-intermediate','page-create-readback','attachment-upload','final-page-body-update','attachment-and-page-readback')}
            else{@('attachment-upload-or-reuse','page-body-update','attachment-and-page-readback')}
        if((@($page.intermediateWrites)-join ',') -cne (@($expectedWrites)-join ',')){return $false}
    }
    return $true
}

function Test-DraftPlanShape {
    param([object]$Plan)
    if(-not(Test-Syp171JsonInteger $Plan.schemaVersion) -or $Plan.publishMode -cne 'draft'){return $false}
    $copy=ConvertFrom-Syp171StrictJson -Json ($Plan|ConvertTo-Json -Depth 18) -Depth 18
    if($Plan.schemaVersion -eq 4){
        if($copy.attachmentStrategy -cne 'immutable-content-name' -or @($copy.pages|Where-Object {@($_.assetChanges).Count -gt 0}).Count -eq 0){return $false}
        $null=$copy.Remove('attachmentStrategy')
    }
    $copy.schemaVersion=1;$null=$copy.Remove('publishMode')
    foreach($page in @($copy.pages)){
        if($page.action -cnotin @('update','no-op') -or ($Plan.schemaVersion -eq 3 -and @($page.assetChanges).Count -ne 0) -or
            $page.expectedDraftObservation -cne 'captured' -or $page.expectedDraftVersion -ne 1 -or
            -not(Test-Syp171JsonInteger $page.expectedDraftVersion) -or
            [string]$page.expectedDraftBodySha256 -cnotmatch '^[a-f0-9]{64}$' -or
            [string]$page.draftBaselinePath -cnotmatch '^plan-assets/[a-f0-9]{32}/[a-f0-9]{64}-draft-baseline\.storage\.xml$' -or
            $page.parentProjectionId -cne '' -or $null -ne $page.expectedParentVersion -or $null -ne $page.expectedParentBodySha256){return $false}
        $page.expectedDraftObservation='same-as-published'
        foreach($key in @('expectedDraftVersion','expectedDraftBodySha256','draftBaselinePath')){$null=$page.Remove($key)}
        if($Plan.schemaVersion -eq 4){
            $extensions=@{'image/png'='.png';'image/jpeg'='.jpg';'image/gif'='.gif';'application/pdf'='.pdf';'text/plain'='.txt';'application/octet-stream'='.bin'}
            foreach($asset in @($page.assetChanges)){
                if(-not $extensions.ContainsKey([string]$asset.mediaType) -or
                    $asset.remoteFilename -cne "syp171-$($page.projectionId)-$($asset.sha256)$($extensions[[string]$asset.mediaType])"){return $false}
            }
            $writes=if($page.action -ceq 'no-op'){@('no-op')}elseif(@($page.assetChanges).Count -eq 0){@('draft-body-update')}
                else{@('draft-attachment-upload-or-reuse','draft-body-update','draft-and-attachment-readback')}
            if((@($page.intermediateWrites)-join ',') -cne ($writes-join ',')){return $false}
            $page.intermediateWrites=@(if($page.action -ceq 'no-op'){'no-op'}elseif(@($page.assetChanges).Count -eq 0){'update'}
                else{'attachment-upload-or-reuse','page-body-update','attachment-and-page-readback'})
        }
    }
    return Test-ConfluencePlanShape -Plan $copy
}

function Test-PlanValidation {
    param([object]$Validation,[string]$ExpectedSiteOrigin)
    if($null -eq $Validation -or $Validation.status -cne 'valid' -or
        $Validation.siteOrigin -cne $ExpectedSiteOrigin -or [string]$Validation.cloudId -cnotmatch '^[a-fA-F0-9-]{36}$' -or
        $Validation.docsCommit -cnotmatch '^[a-f0-9]{40}$' -or $Validation.specCommit -cnotmatch '^[a-f0-9]{40}$' -or
        $Validation.codeCommit -cnotmatch '^[a-f0-9]{40}$' -or
        $Validation.sourceDigest -cnotmatch '^[a-f0-9]{64}$' -or $Validation.mappingDigest -cnotmatch '^[a-f0-9]{64}$' -or
        $Validation.reviewDigest -cnotmatch '^[a-f0-9]{64}$' -or @($Validation.scenarioIds).Count -eq 0){return $false}
    return $true
}

function Read-PlanRemotePage {
    param([string]$ApiBase,[string]$PageId,[bool]$Draft,[scriptblock]$HttpInvoker,[string]$ContentStatus='current')
    $query=if($ContentStatus -ceq 'draft'){'?body-format=storage&get-draft=true&status=draft'}elseif($Draft){'?body-format=storage&get-draft=true'}else{'?body-format=storage'}
    $request=[pscustomobject]@{
        Method='GET';Uri="$($ApiBase.TrimEnd('/'))/wiki/api/v2/pages/${PageId}$query";Headers=@{Accept='application/json'}
        Body=$null;TimeoutSec=30;ResponseLimitBytes=4MB;AuthAllowed=$true
    }
    try{$response=& $HttpInvoker $request}catch{return $null}
    if([int]$response.StatusCode -ne 200){return $null}
    $body=$response.Body
    if($body -is [byte[]]){
        try{$body=[Text.UTF8Encoding]::new($false,$true).GetString($body)|ConvertFrom-Json -AsHashtable -Depth 20 -ErrorAction Stop}catch{return $null}
    }
    if($null -eq $body -or [string]$body.id -cne $PageId -or [string]$body.status -cne $ContentStatus -or
        $null -eq $body.body.storage.value -or $null -eq $body.version.number -or [int]$body.version.number -lt 1){return $null}
    $message=''
    if($body.version -is [System.Collections.IDictionary] -and $body.version.Contains('message')){$message=[string]$body.version.message}
    elseif($null -ne $body.version.PSObject.Properties['message']){$message=[string]$body.version.message}
    return [pscustomobject]@{
        pageId=[string]$body.id;spaceId=[string]$body.spaceId;parentId=[string]$body.parentId
        title=[string]$body.title;version=[int]$body.version.number;storage=[string]$body.body.storage.value
        versionMessage=$message
    }
}

function Read-ConfluenceDraftPage {
    param([string]$ApiBase,[string]$PageId,[scriptblock]$HttpInvoker)
    return Read-PlanRemotePage -ApiBase $ApiBase -PageId $PageId -Draft $true -ContentStatus draft -HttpInvoker $HttpInvoker
}

function Test-CreateTitleAvailable {
    param([string]$SiteOrigin,[string]$ApiBase,[string]$CloudId,[string]$SpaceId,[string]$Title,[scriptblock]$HttpInvoker)
    if([string]::IsNullOrWhiteSpace($Title)){return $false}
    $path="/wiki/api/v2/spaces/$SpaceId/pages?title=$([Uri]::EscapeDataString($Title))&limit=50"
    $result=Get-ConfluenceCollection -ExpectedSiteOrigin $SiteOrigin -ConfiguredSiteOrigin $SiteOrigin -ApiBase $ApiBase -CloudId $CloudId -RelativePath $path -HttpInvoker $HttpInvoker
    if($result.status -cne 'complete'){return $false}
    foreach($item in @($result.items)){
        if([string]$item.title -ceq $Title -and [string]$item.spaceId -ceq $SpaceId){return $false}
    }
    return $true
}

function Get-PlanParentProjectionId {
    param([object]$Payload)
    if($Payload -is [System.Collections.IDictionary]){
        if($Payload.Contains('parentProjectionId')){return [string]$Payload['parentProjectionId']}
        return ''
    }
    if($null -ne $Payload.PSObject.Properties['parentProjectionId']){return [string]$Payload.parentProjectionId}
    return ''
}

function Test-PlanDeferredProperty {
    param([object]$Payload)
    if($Payload -is [System.Collections.IDictionary]){return $Payload.Contains('deferredTargets')}
    return $null -ne $Payload.PSObject.Properties['deferredTargets']
}

function Test-PlanDeferredLinks {
    param([object[]]$Payloads,[string]$SiteOrigin)
    $linked=$false
    foreach($payload in $Payloads){
        $has=Test-PlanDeferredProperty -Payload $payload
        if($has -and @($payload.deferredTargets).Count -gt 0){$linked=$true}
        if([string]$payload.bodyStorage -match '__SYP171_LINK_'){$linked=$true}
    }
    if(-not $linked){return [pscustomobject]@{status='valid';linked=$false}}
    $sitePattern=[regex]::Escape($SiteOrigin.TrimEnd('/'))
    $tokenPattern='__SYP171_LINK_([a-z][a-z0-9-]{0,49})__'
    $hrefPattern='href="'+$sitePattern+'/wiki/pages/viewpage\.action\?pageId='+$tokenPattern+'"'
    foreach($payload in $Payloads){
        if(-not(Test-PlanDeferredProperty -Payload $payload) -or $payload.deferredTargets -isnot [array]){
            return [pscustomobject]@{status='invalid';linked=$true}
        }
        $targets=@($payload.deferredTargets)
        if($targets.Count -gt 100 -or @($targets|Select-Object -Unique).Count -ne $targets.Count){
            return [pscustomobject]@{status='invalid';linked=$true}
        }
        $body=[string]$payload.bodyStorage
        $all=[regex]::Matches($body,$tokenPattern)
        $canonical=[regex]::Matches($body,$hrefPattern)
        $rawMarkerCount=([regex]::Matches($body,'__SYP171_LINK_')).Count
        if($rawMarkerCount -ne $all.Count -or
            $all.Count -ne $canonical.Count){return [pscustomobject]@{status='invalid';linked=$true}}
        $fromBody=@($all|ForEach-Object {$_.Groups[1].Value}|Select-Object -Unique)
        if(($fromBody|Sort-Object)-join ',' -cne (($targets|Sort-Object)-join ',')){
            return [pscustomobject]@{status='invalid';linked=$true}
        }
        foreach($targetId in $targets){
            if([string]$targetId -cnotmatch '^[a-z][a-z0-9-]{0,49}$' -or
                @($Payloads|Where-Object {[string]$_.projectionId -ceq [string]$targetId -and [string]$_.pageId -eq ''}).Count -ne 1){
                return [pscustomobject]@{status='invalid';linked=$true}
            }
        }
    }
    return [pscustomobject]@{status='valid';linked=$true}
}

function Resolve-PlanPayloadOrder {
    param([object[]]$Payloads)
    $byProjection=[System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach($payload in $Payloads){
        $projection=[string]$payload.projectionId
        if($projection -cnotmatch '^[a-z][a-z0-9-]{0,49}$' -or -not $byProjection.TryAdd($projection,$payload)){
            return [pscustomobject]@{status='invalid';payloads=@()}
        }
    }
    foreach($payload in $Payloads){
        $parentProjection=Get-PlanParentProjectionId -Payload $payload
        if($parentProjection -eq ''){continue}
        $parent=$null
        if([string]$payload.pageId -ne '' -or [string]$payload.parentId -ne '' -or
            $parentProjection -cnotmatch '^[a-z][a-z0-9-]{0,49}$' -or
            -not $byProjection.TryGetValue($parentProjection,[ref]$parent) -or
            [string]$parent.pageId -ne '' -or [string]$parent.spaceId -cne [string]$payload.spaceId){
            return [pscustomobject]@{status='invalid';payloads=@()}
        }
    }
    $ordered=[System.Collections.Generic.List[object]]::new()
    $remaining=[System.Collections.Generic.List[object]]::new()
    foreach($payload in $Payloads){$remaining.Add($payload)}
    $emitted=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    while($remaining.Count -gt 0){
        $found=$false
        for($index=0;$index -lt $remaining.Count;$index++){
            $payload=$remaining[$index]
            $dependency=Get-PlanParentProjectionId -Payload $payload
            if($dependency -eq '' -or $emitted.Contains($dependency)){
                $ordered.Add($payload)
                $emitted.Add([string]$payload.projectionId)|Out-Null
                $remaining.RemoveAt($index)
                $found=$true
                break
            }
        }
        if(-not $found){return [pscustomobject]@{status='invalid';payloads=@()}}
    }
    return [pscustomobject]@{status='valid';payloads=$ordered.ToArray()}
}

function New-ConfluencePreviewPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)][object]$Validation,
        [Parameter(Mandatory)][object[]]$Payloads,
        [Parameter(Mandatory)][string]$ExpectedSiteOrigin,
        [Parameter(Mandatory)][string]$ApiBase,
        [Parameter(Mandatory)][scriptblock]$HttpInvoker,
        [object]$ValidationInputs,
        [ValidateSet('current','draft')][string]$PublishMode='current'
    )
    if(-not(Test-PlanValidation -Validation $Validation -ExpectedSiteOrigin $ExpectedSiteOrigin)){
        return New-PlanResult -Status 'invalid' -ReasonCodes @('ValidationIncomplete') -PlanPath '' -PlanSha256 ''
    }
    if($ApiBase.TrimEnd('/') -cne "https://api.atlassian.com/ex/confluence/$($Validation.cloudId)" -or
        $Payloads.Count -eq 0 -or $Payloads.Count -gt 100){
        return New-PlanResult -Status 'invalid' -ReasonCodes @('PlanScopeInvalid') -PlanPath '' -PlanSha256 ''
    }
    $planFull=[IO.Path]::GetFullPath($PlanPath)
    $planDir=[IO.Path]::GetDirectoryName($planFull)
    if(-not(Test-Path -LiteralPath $planDir -PathType Container) -or (Test-Path -LiteralPath $planFull)){
        return New-PlanResult -Status 'invalid' -ReasonCodes @('PlanPathUnavailable') -PlanPath '' -PlanSha256 ''
    }
    $order=Resolve-PlanPayloadOrder -Payloads $Payloads
    if($order.status -cne 'valid'){
        return New-PlanResult -Status 'invalid' -ReasonCodes @('ParentDependencyInvalid') -PlanPath '' -PlanSha256 ''
    }
    $orderedPayloads=@($order.payloads)
    $deferred=Test-PlanDeferredLinks -Payloads $orderedPayloads -SiteOrigin $ExpectedSiteOrigin
    if($deferred.status -cne 'valid'){
        return New-PlanResult -Status 'invalid' -ReasonCodes @('DeferredLinkInvalid') -PlanPath '' -PlanSha256 ''
    }
    if($PublishMode -ceq 'draft' -and ($deferred.linked -or
        @($orderedPayloads|Where-Object {[string]$_.pageId -eq ''}).Count -gt 0)){
        return New-PlanResult -Status 'blocked' -ReasonCodes @('DraftScopeUnsupported') -PlanPath '' -PlanSha256 ''
    }
    if($PublishMode -ceq 'draft'){
        foreach($payload in $orderedPayloads){
            if(-not(Test-ConfluenceStorageEquivalent -Expected ([string]$payload.bodyStorage) -Actual ([string]$payload.bodyStorage))){
                return New-PlanResult -Status invalid -ReasonCodes @('DraftStorageInvalid') -PlanPath '' -PlanSha256 ''
            }
        }
    }
    $draftAssets=$PublishMode -ceq 'draft' -and @($orderedPayloads|Where-Object {@($_.assetChanges).Count -gt 0}).Count -gt 0
    $seen=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $validatedAssets=@{}
    $totalAssetBytes=[int64]0
    foreach($payload in $orderedPayloads){
        $id=[string]$payload.pageId
        $parentProjection=Get-PlanParentProjectionId -Payload $payload
        if(($id -ne '' -and $id -cnotmatch '^[0-9]+$') -or
            -not $seen.Add($(if($id -eq ''){"create:$($payload.projectionId)"}else{"page:$id"})) -or
            [string]$payload.spaceId -cnotmatch '^[0-9]+$' -or [string]$payload.projectionId -cnotmatch '^[a-z][a-z0-9-]{0,49}$' -or
            ($parentProjection -eq '' -and [string]$payload.parentId -cnotmatch '^[0-9]+$') -or $null -eq $payload.bodyStorage -or
            @($payload.assetChanges).Count -gt 25){
            return New-PlanResult -Status 'invalid' -ReasonCodes @('PayloadInvalid') -PlanPath '' -PlanSha256 ''
        }
        $assets=[System.Collections.Generic.List[object]]::new()
        if(@($payload.assetChanges).Count -gt 0){
            $assetRoot=''
            if($ValidationInputs -is [System.Collections.IDictionary]){$assetRoot=[string]$ValidationInputs['root']}
            elseif($null -ne $ValidationInputs -and $null -ne $ValidationInputs.PSObject.Properties['root']){$assetRoot=[string]$ValidationInputs.root}
            if([string]::IsNullOrWhiteSpace($assetRoot)){
                return New-PlanResult -Status 'invalid' -ReasonCodes @('AssetRootUnavailable') -PlanPath '' -PlanSha256 ''
            }
            $names=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach($candidate in @($payload.assetChanges)){
                $asset=Resolve-LocalManagedAsset -Root $assetRoot -ProjectionId ([string]$payload.projectionId) -Asset $candidate
                if($asset.status -cne 'valid'){
                    return New-PlanResult -Status 'invalid' -ReasonCodes $asset.reasonCodes -PlanPath '' -PlanSha256 ''
                }
                if(-not $names.Add([string]$asset.remoteFilename) -or
                    -not ([string]$payload.bodyStorage).Contains("ri:filename=`"$($asset.remoteFilename)`"",[StringComparison]::Ordinal)){
                    return New-PlanResult -Status 'invalid' -ReasonCodes @('AssetReferenceMismatch') -PlanPath '' -PlanSha256 ''
                }
                $totalAssetBytes+=[int64]$asset.byteLength
                if($totalAssetBytes -gt 200MB){
                    return New-PlanResult -Status 'invalid' -ReasonCodes @('PlanAssetsTooLarge') -PlanPath '' -PlanSha256 ''
                }
                $assets.Add($asset)
            }
        }
        $validatedAssets[[string]$payload.projectionId]=$assets.ToArray()
    }
    $observed=[System.Collections.Generic.List[object]]::new()
    foreach($payload in $orderedPayloads){
        $id=[string]$payload.pageId
        if($id -eq ''){
            $parent=$null
            if((Get-PlanParentProjectionId -Payload $payload) -eq ''){
                $parent=Read-PlanRemotePage -ApiBase $ApiBase -PageId ([string]$payload.parentId) -Draft $false -HttpInvoker $HttpInvoker
                $parentReread=Read-PlanRemotePage -ApiBase $ApiBase -PageId ([string]$payload.parentId) -Draft $false -HttpInvoker $HttpInvoker
                if($null -eq $parent -or $null -eq $parentReread -or $parent.spaceId -cne [string]$payload.spaceId -or
                    $parentReread.version -ne $parent.version -or $parentReread.storage -cne $parent.storage){
                    return New-PlanResult -Status 'blocked' -ReasonCodes @('CreateTargetUnverified') -PlanPath '' -PlanSha256 ''
                }
            }
            if(-not(Test-CreateTitleAvailable -SiteOrigin $ExpectedSiteOrigin -ApiBase $ApiBase -CloudId $Validation.cloudId -SpaceId ([string]$payload.spaceId) -Title ([string]$payload.title) -HttpInvoker $HttpInvoker)){
                return New-PlanResult -Status 'blocked' -ReasonCodes @('CreateTargetUnverified') -PlanPath '' -PlanSha256 ''
            }
            $createAssets=[System.Collections.Generic.List[object]]::new()
            foreach($asset in @($validatedAssets[[string]$payload.projectionId])){
                $createAssets.Add([pscustomobject]@{source=$asset;action='upload';remoteAttachmentId='';remoteVersion=0})
            }
            $observed.Add([pscustomobject]@{payload=$payload;published=$parent;action='create';assets=$createAssets.ToArray()})
            continue
        }
        $published=Read-PlanRemotePage -ApiBase $ApiBase -PageId $id -Draft $false -HttpInvoker $HttpInvoker
        $draft=if($PublishMode -ceq 'draft'){Read-ConfluenceDraftPage -ApiBase $ApiBase -PageId $id -HttpInvoker $HttpInvoker}
            else{Read-PlanRemotePage -ApiBase $ApiBase -PageId $id -Draft $true -HttpInvoker $HttpInvoker}
        $reread=Read-PlanRemotePage -ApiBase $ApiBase -PageId $id -Draft $false -HttpInvoker $HttpInvoker
        if($null -eq $published -or $null -eq $draft -or $null -eq $reread){
            return New-PlanResult -Status 'blocked' -ReasonCodes @('RemoteReadIncomplete') -PlanPath '' -PlanSha256 ''
        }
        if($published.spaceId -cne [string]$payload.spaceId -or $published.parentId -cne [string]$payload.parentId -or
            $reread.version -ne $published.version -or $reread.storage -cne $published.storage){
            return New-PlanResult -Status 'blocked' -ReasonCodes @('RemoteUnstable') -PlanPath '' -PlanSha256 ''
        }
        if($PublishMode -ceq 'current' -and ($draft.version -ne $published.version -or $draft.storage -cne $published.storage)){
            return New-PlanResult -Status 'blocked' -ReasonCodes @('DraftConflict') -PlanPath '' -PlanSha256 ''
        }
        if($PublishMode -ceq 'draft' -and ($draft.version -ne 1 -or $draft.spaceId -cne $published.spaceId -or
            $draft.parentId -cne $published.parentId -or $draft.title -cne $published.title -or $published.title -cne [string]$payload.title)){
            return New-PlanResult -Status 'blocked' -ReasonCodes @('DraftIdentityUnverified') -PlanPath '' -PlanSha256 ''
        }
        $remoteAssets=[System.Collections.Generic.List[object]]::new()
        $currentReferences=$null
        if($draftAssets -and @($validatedAssets[[string]$payload.projectionId]).Count -gt 0){
            $currentReferences=Get-ConfluenceStorageAttachmentNames -Storage $published.storage -SiteOrigin $ExpectedSiteOrigin -PageId $id
            if($currentReferences.status -cne 'valid'){
                return New-PlanResult -Status blocked -ReasonCodes @('PublishedAttachmentReferencesUnverified') -PlanPath '' -PlanSha256 ''
            }
        }
        foreach($asset in @($validatedAssets[[string]$payload.projectionId])){
            $remote=Get-ManagedAttachmentObservation -SiteOrigin $ExpectedSiteOrigin -ApiBase $ApiBase -CloudId $Validation.cloudId -PageId $id `
                -RemoteFilename $asset.remoteFilename -MediaType $asset.mediaType -Sha256 $asset.sha256 -ByteLength $asset.byteLength -HttpInvoker $HttpInvoker
            if($remote.status -cne 'ready'){
                return New-PlanResult -Status 'blocked' -ReasonCodes $remote.reasonCodes -PlanPath '' -PlanSha256 ''
            }
            if($draftAssets -and $remote.action -ceq 'upload' -and @($currentReferences.names) -ccontains $asset.remoteFilename){
                return New-PlanResult -Status blocked -ReasonCodes @('DraftAttachmentAffectsCurrent') -PlanPath '' -PlanSha256 ''
            }
            $remoteAssets.Add([pscustomobject]@{source=$asset;action=$remote.action;remoteAttachmentId=$remote.remoteAttachmentId;remoteVersion=$remote.remoteVersion})
        }
        $needsUpload=@($remoteAssets|Where-Object action -eq 'upload').Count -gt 0
        $bodyMatches=if($PublishMode -ceq 'draft'){Test-ConfluenceStorageEquivalent -Expected ([string]$payload.bodyStorage) -Actual $draft.storage}
            else{$published.storage -ceq [string]$payload.bodyStorage}
        $action=if($bodyMatches -and $published.title -ceq [string]$payload.title -and -not $needsUpload){'no-op'}else{'update'}
        $observed.Add([pscustomobject]@{payload=$payload;published=$published;draft=$draft;action=$action;assets=$remoteAssets.ToArray()})
    }
    $operationId=[Guid]::NewGuid().ToString('N')
    $assetRoot=Join-Path $planDir "plan-assets/$operationId"
    $stage="$assetRoot.staging"
    if((Test-Path -LiteralPath $assetRoot) -or (Test-Path -LiteralPath $stage)){
        return New-PlanResult -Status 'failed' -ReasonCodes @('PlanStagingConflict') -PlanPath '' -PlanSha256 ''
    }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    try {
        $pages=[System.Collections.Generic.List[object]]::new()
        foreach($item in $observed){
            $payload=$item.payload;$published=$item.published
            $bytes=[Text.Encoding]::UTF8.GetBytes([string]$payload.bodyStorage)
            $sha=Get-AssetHash -Bytes $bytes
            $filename="$(Get-AssetHash -Bytes ([Text.Encoding]::UTF8.GetBytes([string]$payload.projectionId))).storage.xml"
            [IO.File]::WriteAllBytes((Join-Path $stage $filename),$bytes)
            $assetRecords=[System.Collections.Generic.List[object]]::new()
            foreach($observedAsset in @($item.assets)){
                $asset=$observedAsset.source
                $assetFilename="$($asset.sha256).asset"
                $assetStagePath=Join-Path $stage $assetFilename
                if(-not(Test-Path -LiteralPath $assetStagePath)){
                    [IO.File]::WriteAllBytes($assetStagePath,[byte[]]$asset.bytes)
                }elseif((Get-AssetHash -Bytes ([IO.File]::ReadAllBytes($assetStagePath))) -cne $asset.sha256){
                    throw 'AssetStageCollision'
                }
                $assetRecords.Add([ordered]@{
                    localPath=$asset.localPath;displayFilename=$asset.displayFilename;mediaType=$asset.mediaType
                    remoteFilename=$asset.remoteFilename;sha256=$asset.sha256;byteLength=$asset.byteLength
                    payloadPath="plan-assets/$operationId/$assetFilename";action=$observedAsset.action
                    remoteAttachmentId=$observedAsset.remoteAttachmentId;remoteVersion=$observedAsset.remoteVersion
                })
            }
            $intermediateWrites=if($deferred.linked -and $item.action -ceq 'create'){@('page-create-intermediate','page-create-readback','link-resolution','attachment-upload-or-reuse','final-page-body-update','attachment-and-page-readback')}
                elseif($deferred.linked -and $item.action -ceq 'update'){@('link-resolution','attachment-upload-or-reuse','page-body-update','attachment-and-page-readback')}
                elseif($item.action -ceq 'no-op'){@('no-op')}
                elseif($assetRecords.Count -eq 0){@($item.action)}
                elseif($item.action -ceq 'create'){@('page-create-intermediate','page-create-readback','attachment-upload','final-page-body-update','attachment-and-page-readback')}
                else{@('attachment-upload-or-reuse','page-body-update','attachment-and-page-readback')}
            $pageRecord=[ordered]@{
                projectionId=[string]$payload.projectionId;pageId=[string]$payload.pageId
                spaceId=[string]$payload.spaceId;parentId=[string]$payload.parentId
                parentProjectionId=(Get-PlanParentProjectionId -Payload $payload);title=[string]$payload.title
                action=$item.action;expectedPublishedVersion=$(if($item.action -ceq 'create'){0}else{$published.version})
                expectedPublishedBodySha256=$(if($null -ne $published){Get-AssetHash -Bytes ([Text.Encoding]::UTF8.GetBytes($published.storage))}else{''})
                expectedParentVersion=$(if($item.action -ceq 'create' -and $null -ne $published){$published.version}else{$null})
                expectedParentBodySha256=$(if($item.action -ceq 'create' -and $null -ne $published){Get-AssetHash -Bytes ([Text.Encoding]::UTF8.GetBytes($published.storage))}else{$null})
                expectedDraftObservation='same-as-published';payloadPath="plan-assets/$operationId/$filename"
                payloadSha256=$sha;assetChanges=@($assetRecords.ToArray())
                intermediateWrites=@($intermediateWrites)
            }
            if($deferred.linked){$pageRecord['deferredTargets']=@($payload.deferredTargets)}
            if($PublishMode -ceq 'draft'){
                if($draftAssets){
                    $pageRecord.intermediateWrites=@(if($item.action -ceq 'no-op'){'no-op'}elseif($assetRecords.Count -eq 0){'draft-body-update'}
                        else{'draft-attachment-upload-or-reuse','draft-body-update','draft-and-attachment-readback'})
                }
                $draftBytes=[Text.Encoding]::UTF8.GetBytes([string]$item.draft.storage)
                $baselineFilename=$filename.Replace('.storage.xml','-draft-baseline.storage.xml')
                [IO.File]::WriteAllBytes((Join-Path $stage $baselineFilename),$draftBytes)
                $pageRecord.expectedDraftObservation='captured'
                $pageRecord['expectedDraftVersion']=1
                $pageRecord['expectedDraftBodySha256']=Get-AssetHash -Bytes $draftBytes
                $pageRecord['draftBaselinePath']="plan-assets/$operationId/$baselineFilename"
            }
            $pages.Add($pageRecord)
        }
        $plan=[ordered]@{
            schemaVersion=$(if($deferred.linked){2}else{1});operationId=$operationId;createdAtUtc=(Get-Date -AsUTC).ToString('o')
            siteOrigin=$Validation.siteOrigin;cloudId=$Validation.cloudId
            docsCommit=$Validation.docsCommit;specCommit=$Validation.specCommit;codeCommit=$Validation.codeCommit
            sourceDigest=$Validation.sourceDigest;mappingDigest=$Validation.mappingDigest;reviewDigest=$Validation.reviewDigest
            validatorVersion=$Validation.validatorVersion;rendererVersion=$Validation.rendererVersion
            scenarioIds=@($Validation.scenarioIds);pages=@($pages.ToArray())
            validationInputs=$ValidationInputs
        }
        if($deferred.linked){$plan['linkStrategy']='identity-first'}
        if($PublishMode -ceq 'draft'){
            $plan.schemaVersion=if($draftAssets){4}else{3};$plan['publishMode']='draft'
            if($draftAssets){$plan['attachmentStrategy']='immutable-content-name'}
        }
        $planBytes=[Text.Encoding]::UTF8.GetBytes(($plan|ConvertTo-Json -Depth 18))
        $digest=Get-AssetHash -Bytes $planBytes
        Move-Item -LiteralPath $stage -Destination $assetRoot
        [IO.File]::WriteAllBytes($planFull,$planBytes)
        [IO.File]::WriteAllText("$planFull.sha256",$digest+"`n",[Text.UTF8Encoding]::new($false))
        return New-PlanResult -Status 'preview' -ReasonCodes @() -PlanPath $planFull -PlanSha256 $digest
    } catch {
        return New-PlanResult -Status 'failed' -ReasonCodes @('PlanWriteFailed') -PlanPath '' -PlanSha256 ''
    }
}

function Test-ConfluencePlanDrift {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)][object]$CurrentValidation,
        [Parameter(Mandatory)][string]$ExpectedSiteOrigin,
        [Parameter(Mandatory)][string]$ApiBase,
        [Parameter(Mandatory)][scriptblock]$HttpInvoker
    )
    $full=[IO.Path]::GetFullPath($PlanPath)
    if(-not(Test-Path -LiteralPath $full -PathType Leaf) -or -not(Test-Path -LiteralPath "$full.sha256" -PathType Leaf)){
        return New-PlanResult -Status 'invalid' -ReasonCodes @('PlanUnavailable') -PlanPath $full -PlanSha256 ''
    }
    $bytes=[IO.File]::ReadAllBytes($full);$digest=Get-AssetHash -Bytes $bytes
    if((Get-Content -LiteralPath "$full.sha256" -Raw).Trim() -cne $digest){
        return New-PlanResult -Status 'blocked' -ReasonCodes @('PlanDigestMismatch') -PlanPath $full -PlanSha256 $digest
    }
    try{$plan=ConvertFrom-Syp171StrictJson -Json ([Text.UTF8Encoding]::new($false,$true).GetString($bytes)) -Depth 18}
    catch{return New-PlanResult -Status 'invalid' -ReasonCodes @('PlanSchemaInvalid') -PlanPath $full -PlanSha256 $digest}
    if(-not(Test-ConfluencePlanShape -Plan $plan)){
        return New-PlanResult -Status 'invalid' -ReasonCodes @('PlanSchemaInvalid') -PlanPath $full -PlanSha256 $digest
    }
    if($plan.siteOrigin -cne $ExpectedSiteOrigin -or $ApiBase.TrimEnd('/') -cne "https://api.atlassian.com/ex/confluence/$($plan.cloudId)"){
        return New-PlanResult -Status 'blocked' -ReasonCodes @('TenantMismatch') -PlanPath $full -PlanSha256 $digest
    }
    if(-not(Test-PlanValidation -Validation $CurrentValidation -ExpectedSiteOrigin $ExpectedSiteOrigin) -or
        $plan.docsCommit -cne $CurrentValidation.docsCommit -or $plan.specCommit -cne $CurrentValidation.specCommit -or
        $plan.codeCommit -cne $CurrentValidation.codeCommit -or $plan.sourceDigest -cne $CurrentValidation.sourceDigest){
        return New-PlanResult -Status 'blocked' -ReasonCodes @('SourceChanged') -PlanPath $full -PlanSha256 $digest
    }
    if($plan.mappingDigest -cne $CurrentValidation.mappingDigest -or $plan.reviewDigest -cne $CurrentValidation.reviewDigest -or
        $plan.validatorVersion -cne $CurrentValidation.validatorVersion -or $plan.rendererVersion -cne $CurrentValidation.rendererVersion -or
        (@($plan.scenarioIds)-join ',') -cne (@($CurrentValidation.scenarioIds)-join ',')){
        return New-PlanResult -Status 'blocked' -ReasonCodes @('ProjectionChanged') -PlanPath $full -PlanSha256 $digest
    }
    $planDir=[IO.Path]::GetDirectoryName($full)
    foreach($page in @($plan.pages)){
        $payload=[IO.Path]::GetFullPath((Join-Path $planDir ([string]$page.payloadPath)))
        $relative=[IO.Path]::GetRelativePath($planDir,$payload)
        if($relative -eq '..' -or $relative.StartsWith("..$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::Ordinal) -or
            -not(Test-Path -LiteralPath $payload -PathType Leaf) -or (Get-AssetHash -Bytes ([IO.File]::ReadAllBytes($payload))) -cne $page.payloadSha256){
            return New-PlanResult -Status 'blocked' -ReasonCodes @('PayloadChanged') -PlanPath $full -PlanSha256 $digest
        }
        if($plan.schemaVersion -in @(3,4)){
            $baseline=[IO.Path]::GetFullPath((Join-Path $planDir ([string]$page.draftBaselinePath)))
            $baselineRelative=[IO.Path]::GetRelativePath($planDir,$baseline)
            if($baselineRelative -eq '..' -or $baselineRelative.StartsWith("..$([IO.Path]::DirectorySeparatorChar)",[StringComparison]::Ordinal) -or
                -not(Test-Path -LiteralPath $baseline -PathType Leaf) -or
                (Get-AssetHash -Bytes ([IO.File]::ReadAllBytes($baseline))) -cne $page.expectedDraftBodySha256){
                return New-PlanResult -Status blocked -ReasonCodes @('DraftBaselineChanged') -PlanPath $full -PlanSha256 $digest
            }
        }
        foreach($asset in @($page.assetChanges)){
            $assetPath=[IO.Path]::GetFullPath((Join-Path $planDir ([string]$asset.payloadPath)))
            $assetRelative=[IO.Path]::GetRelativePath($planDir,$assetPath)
            if($assetRelative -eq '..' -or $assetRelative.StartsWith("..$([IO.Path]::DirectorySeparatorChar)",[StringComparison]::Ordinal) -or
                -not(Test-Path -LiteralPath $assetPath -PathType Leaf) -or
                (Get-Item -LiteralPath $assetPath).Length -ne [int64]$asset.byteLength -or
                (Get-AssetHash -Bytes ([IO.File]::ReadAllBytes($assetPath))) -cne $asset.sha256){
                return New-PlanResult -Status 'blocked' -ReasonCodes @('PayloadChanged') -PlanPath $full -PlanSha256 $digest
            }
        }
    }
    foreach($page in @($plan.pages)){
        if($page.action -ceq 'create'){
            if([string]$page.parentProjectionId -eq ''){
                $parent=Read-PlanRemotePage -ApiBase $ApiBase -PageId ([string]$page.parentId) -Draft $false -HttpInvoker $HttpInvoker
                if($null -eq $parent -or $parent.spaceId -cne $page.spaceId -or
                    $parent.version -ne [int]$page.expectedParentVersion -or
                    (Get-AssetHash -Bytes ([Text.Encoding]::UTF8.GetBytes($parent.storage))) -cne $page.expectedParentBodySha256){
                    return New-PlanResult -Status 'blocked' -ReasonCodes @('CreateTargetDrift') -PlanPath $full -PlanSha256 $digest
                }
            }
            if(-not(Test-CreateTitleAvailable -SiteOrigin $ExpectedSiteOrigin -ApiBase $ApiBase -CloudId $plan.cloudId -SpaceId ([string]$page.spaceId) -Title ([string]$page.title) -HttpInvoker $HttpInvoker)){
                return New-PlanResult -Status 'blocked' -ReasonCodes @('CreateTargetDrift') -PlanPath $full -PlanSha256 $digest
            }
            continue
        }
        $published=Read-PlanRemotePage -ApiBase $ApiBase -PageId ([string]$page.pageId) -Draft $false -HttpInvoker $HttpInvoker
        $draft=if($plan.schemaVersion -in @(3,4)){Read-ConfluenceDraftPage -ApiBase $ApiBase -PageId ([string]$page.pageId) -HttpInvoker $HttpInvoker}
            else{Read-PlanRemotePage -ApiBase $ApiBase -PageId ([string]$page.pageId) -Draft $true -HttpInvoker $HttpInvoker}
        if($null -eq $published -or $null -eq $draft){
            return New-PlanResult -Status 'blocked' -ReasonCodes @('RemoteReadIncomplete') -PlanPath $full -PlanSha256 $digest
        }
        if($plan.schemaVersion -in @(3,4)){
            if($draft.version -ne 1 -or $draft.spaceId -cne $page.spaceId -or $draft.parentId -cne $page.parentId -or
                $draft.title -cne $page.title -or (Get-AssetHash -Bytes ([Text.Encoding]::UTF8.GetBytes($draft.storage))) -cne $page.expectedDraftBodySha256){
                return New-PlanResult -Status 'blocked' -ReasonCodes @('DraftDrift') -PlanPath $full -PlanSha256 $digest
            }
        }elseif($draft.version -ne $published.version -or $draft.storage -cne $published.storage){
            return New-PlanResult -Status 'blocked' -ReasonCodes @('DraftConflict') -PlanPath $full -PlanSha256 $digest
        }
        if($published.version -ne [int]$page.expectedPublishedVersion -or
            (Get-AssetHash -Bytes ([Text.Encoding]::UTF8.GetBytes($published.storage))) -cne $page.expectedPublishedBodySha256 -or
            $published.title -cne $page.title -or $published.spaceId -cne $page.spaceId -or $published.parentId -cne $page.parentId){
            return New-PlanResult -Status 'blocked' -ReasonCodes @('RemoteDrift') -PlanPath $full -PlanSha256 $digest
        }
        foreach($asset in @($page.assetChanges)){
            $remote=Get-ManagedAttachmentObservation -SiteOrigin $ExpectedSiteOrigin -ApiBase $ApiBase -CloudId $plan.cloudId -PageId ([string]$page.pageId) `
                -RemoteFilename ([string]$asset.remoteFilename) -MediaType ([string]$asset.mediaType) -Sha256 ([string]$asset.sha256) -ByteLength ([int64]$asset.byteLength) -HttpInvoker $HttpInvoker
            if($remote.status -cne 'ready' -or $remote.action -cne $asset.action -or
                $remote.remoteAttachmentId -cne [string]$asset.remoteAttachmentId -or $remote.remoteVersion -ne [int]$asset.remoteVersion){
                return New-PlanResult -Status 'blocked' -ReasonCodes @('RemoteAttachmentDrift') -PlanPath $full -PlanSha256 $digest
            }
        }
    }
    return New-PlanResult -Status 'ready' -ReasonCodes @() -PlanPath $full -PlanSha256 $digest
}

Export-ModuleMember -Function New-ConfluencePreviewPlan,Test-ConfluencePlanDrift,Test-CreateTitleAvailable,Test-ConfluencePlanShape,Read-ConfluenceDraftPage
