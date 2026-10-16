# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
Import-Module -Name (Join-Path $PSScriptRoot 'ConfluencePlan.psm1') -Scope Local
Import-Module -Name (Join-Path $PSScriptRoot 'ConfluenceTransport.psm1') -Scope Local
Import-Module -Name (Join-Path $PSScriptRoot 'ConfluenceAssets.psm1') -Scope Local
Import-Module -Name (Join-Path $PSScriptRoot 'StrictJson.psm1') -Scope Local
Import-Module -Name (Join-Path $PSScriptRoot 'ConfluenceStorage.psm1') -Scope Local
$script:captureModule=Import-Module -Name (Join-Path $PSScriptRoot 'ConfluenceDocs.psm1') -Scope Local -PassThru

function New-PublishResult {
    param([string]$Status,[string[]]$ReasonCodes,[string]$JournalPath,[string]$SyncPath)
    return [pscustomobject]@{status=$Status;reasonCodes=@($ReasonCodes);journalPath=$JournalPath;syncPath=$SyncPath}
}

function Write-AtomicJson {
    param([string]$Path,[object]$Value)
    $full=[IO.Path]::GetFullPath($Path)
    $parent=[IO.Path]::GetDirectoryName($full)
    if(-not(Test-Path -LiteralPath $parent -PathType Container)){throw 'StateDirectoryUnavailable'}
    $stage="$full.$([Guid]::NewGuid().ToString('N')).staging"
    $bytes=[Text.Encoding]::UTF8.GetBytes(($Value|ConvertTo-Json -Depth 18))
    try{
        [IO.File]::WriteAllBytes($stage,$bytes)
        [IO.File]::Move($stage,$full,$true)
    }finally{if(Test-Path -LiteralPath $stage){Remove-Item -LiteralPath $stage -Force}}
}

function Get-PublishPage {
    param([string]$ApiBase,[string]$PageId,[bool]$Draft,[scriptblock]$HttpInvoker)
    $query=if($Draft){'?body-format=storage&get-draft=true'}else{'?body-format=storage'}
    $request=[pscustomobject]@{
        Method='GET';Uri=($ApiBase.TrimEnd('/') + '/wiki/api/v2/pages/' + $PageId + $query);Headers=@{Accept='application/json'}
        Body=$null;TimeoutSec=30;ResponseLimitBytes=4MB;AuthAllowed=$true
    }
    try{$response=& $HttpInvoker $request}catch{return $null}
    if([int]$response.StatusCode -ne 200){return $null}
    $body=$response.Body
    if($body -is [byte[]]){
        try{$body=[Text.UTF8Encoding]::new($false,$true).GetString($body)|ConvertFrom-Json -AsHashtable -Depth 20 -ErrorAction Stop}catch{return $null}
    }
    if($null -eq $body -or [string]$body.id -cne $PageId -or [string]$body.status -cne 'current' -or
        $null -eq $body.body.storage.value -or $null -eq $body.version.number){return $null}
    $message=''
    if($body.version -is [System.Collections.IDictionary]){
        if($body.version.Contains('message')){$message=[string]$body.version['message']}
    }elseif($null -ne $body.version.PSObject.Properties['message']){
        $message=[string]$body.version.message
    }
    return [pscustomobject]@{
        pageId=[string]$body.id;spaceId=[string]$body.spaceId;parentId=[string]$body.parentId
        title=[string]$body.title;version=[int]$body.version.number;storage=[string]$body.body.storage.value
        versionMessage=$message
    }
}

function Get-PublishCreateResponseId {
    param([object]$Response,[object]$Page)
    if($null -eq $Response -or [int]$Response.StatusCode -ne 200){return ''}
    $body=$Response.Body
    if($body -is [byte[]]){
        try{$body=[Text.UTF8Encoding]::new($false,$true).GetString($body)|ConvertFrom-Json -AsHashtable -Depth 20 -ErrorAction Stop}
        catch{return ''}
    }
    if([string]$body.id -cnotmatch '^[0-9]+$' -or [string]$body.spaceId -cne $Page.spaceId -or
        [string]$body.parentId -cne $Page.parentId -or [string]$body.title -cne $Page.title -or
        [string]$body.status -cne 'current'){return ''}
    return [string]$body.id
}

function Test-PublishAuthorization {
    param([object]$Authorization,[object]$Plan,[string]$Digest)
    if($Plan.publishMode -ceq 'draft'){
        $authKeys=@('schemaVersion','planSha256','operationId','siteOrigin','cloudId','publishMode','approvedActions','approvalEvidenceRef')
        $authKeys+=@('attachmentStrategy');$authVersion=4
        if(-not(Test-Syp171JsonKeys -Value $Authorization -Expected $authKeys) -or
            $Authorization.schemaVersion -ne $authVersion -or -not(Test-Syp171JsonInteger $Authorization.schemaVersion) -or
            $Authorization.attachmentStrategy -cne 'immutable-content-name' -or
            $Authorization.publishMode -cne 'draft' -or $Authorization.planSha256 -cne $Digest -or
            $Authorization.operationId -cne $Plan.operationId -or $Authorization.siteOrigin -cne $Plan.siteOrigin -or
            $Authorization.cloudId -cne $Plan.cloudId -or [string]::IsNullOrWhiteSpace([string]$Authorization.approvalEvidenceRef) -or
            $Authorization.approvedActions -isnot [array]){return $false}
        $approved=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach($action in @($Authorization.approvedActions)){
            $valid=[string]$action -cmatch '^draft-update:[0-9]+$' -or (
                [string]$action -cmatch '^draft-attachment-upload:[0-9]+:syp171-[a-z][a-z0-9-]{0,49}-[a-f0-9]{64}\.(png|jpg|gif|pdf|txt|bin)$')
            if(-not $valid -or -not $approved.Add([string]$action)){return $false}
        }
        $required=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach($page in @($Plan.pages|Where-Object action -ne 'no-op')){
            $null=$required.Add('draft-update:' + [string]$page.pageId)
        }
        if($Plan.attachmentStrategy -ceq 'immutable-content-name'){
            foreach($page in @($Plan.pages)){
                foreach($asset in @($page.assetChanges|Where-Object action -eq 'upload')){
                    $null=$required.Add('draft-attachment-upload:' + [string]$page.pageId + ':' + [string]$asset.remoteFilename)
                }
            }
        }
        return $approved.SetEquals($required)
    }
    if($Authorization -isnot [System.Collections.IDictionary] -or
        (($Authorization.Keys|Sort-Object)-join ',') -cne 'approvalEvidenceRef,approvedActions,cloudId,operationId,planSha256,schemaVersion,siteOrigin' -or
        $Authorization.schemaVersion -ne 1 -or $Authorization.planSha256 -cne $Digest -or
        $Authorization.operationId -cne $Plan.operationId -or $Authorization.siteOrigin -cne $Plan.siteOrigin -or
        $Authorization.cloudId -cne $Plan.cloudId -or [string]::IsNullOrWhiteSpace([string]$Authorization.approvalEvidenceRef)){
        return $false
    }
    $approved=@($Authorization.approvedActions)
    if($Authorization.approvedActions -isnot [array]){return $false}
    $unique=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($action in $approved){
        if([string]$action -cnotmatch '^(?:update:[0-9]+|create:[a-z][a-z0-9-]{0,49})$' -or
            -not $unique.Add([string]$action)){return $false}
    }
    $required=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($page in @($Plan.pages)){
        $identity=if($page.action -ceq 'create'){$page.projectionId}else{$page.pageId}
        if($page.action -cne 'no-op'){$null=$required.Add("$($page.action):$identity")}
    }
    return $unique.SetEquals($required)
}

function Test-PublishStatic {
    param([string]$PlanPath,[object]$Plan,[string]$Digest,[object]$Validation,[object]$Frozen)
    if(-not(Test-Path -LiteralPath "$PlanPath.sha256" -PathType Leaf) -or
        (Get-Content -LiteralPath "$PlanPath.sha256" -Raw).Trim() -cne $Digest){return 'PlanDigestMismatch'}
    if($Validation.status -cne 'valid' -or $Plan.docsCommit -cne $Validation.docsCommit -or
        $Plan.codeCommit -cne [string]$Validation.codeCommit -or $Plan.sourceMode -cne [string]$Validation.sourceMode -or
        $Plan.sourceDigest -cne $Validation.sourceDigest){return 'SourceChanged'}
    if($Plan.mappingDigest -cne $Validation.mappingDigest -or $Plan.reviewDigest -cne $Validation.reviewDigest -or
        $Plan.validatorVersion -cne $Validation.validatorVersion -or $Plan.rendererVersion -cne $Validation.rendererVersion){return 'ProjectionChanged'}
    $parent=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($PlanPath))
    foreach($page in @($Plan.pages)){
        $path=[IO.Path]::GetFullPath((Join-Path $parent ([string]$page.payloadPath)))
        $relative=[IO.Path]::GetRelativePath($parent,$path)
        if($relative -eq '..' -or $relative.StartsWith(('..' + [string]($([IO.Path]::DirectorySeparatorChar))),[StringComparison]::Ordinal) -or
            -not(Test-Path -LiteralPath $path -PathType Leaf)){return 'PayloadChanged'}
        $payloadBytes=[IO.File]::ReadAllBytes($path)
        if((Get-AssetHash -Bytes $payloadBytes) -cne $page.payloadSha256){return 'PayloadChanged'}
        try{$Frozen.payloads[[string]$page.projectionId]=[Text.UTF8Encoding]::new($false,$true).GetString($payloadBytes)}
        catch{return 'PayloadChanged'}
        foreach($asset in @($page.assetChanges)){
            $assetPath=[IO.Path]::GetFullPath((Join-Path $parent ([string]$asset.payloadPath)))
            $assetRelative=[IO.Path]::GetRelativePath($parent,$assetPath)
            if($assetRelative -eq '..' -or $assetRelative.StartsWith(('..' + [string]($([IO.Path]::DirectorySeparatorChar))),[StringComparison]::Ordinal) -or
                -not(Test-Path -LiteralPath $assetPath -PathType Leaf)){return 'PayloadChanged'}
            $assetBytes=[IO.File]::ReadAllBytes($assetPath)
            if($assetBytes.Length -ne [int64]$asset.byteLength -or
                (Get-AssetHash -Bytes $assetBytes) -cne [string]$asset.sha256){return 'PayloadChanged'}
            $Frozen.assets[([string]($($page.projectionId)) + ':' + [string]($($asset.remoteFilename)))]=$assetBytes
        }
    }
    return $null
}

function Save-DraftPrewriteSnapshot {
    param([string]$PlanPath,[object]$Page,[AllowNull()][byte[]]$Bytes)
    $root=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($PlanPath))
    $path=[IO.Path]::GetFullPath((Join-Path $root ([string]$Page.draftBaselinePath)))
    $relative=[IO.Path]::GetRelativePath($root,$path)
    if($relative -eq '..' -or $relative.StartsWith(('..' + [string]([IO.Path]::DirectorySeparatorChar)),[StringComparison]::Ordinal) -or
        [IO.Path]::IsPathRooted($relative)){return $false}
    try{
        & $script:captureModule { param($Root,$Path) Assert-CapturePathNoReparse -Root $Root -Path $Path } $root $path
        if(Test-Path -LiteralPath $path){
            if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return $false}
            $private=& $script:captureModule { param($Path) Test-CapturePrivatePathPermissions -Path $Path -IsDirectory $false } $path
            if(-not $private){return $false}
        }else{
            if($null -eq $Bytes){return $false}
            $supported=& $script:captureModule { Test-ConfluenceCapturePrivatePermissions }
            if(-not $supported){return $false}
            & $script:captureModule { param($Root,$Path,$Content) Write-CapturePrivateBytes -Root $Root -Path $Path -Bytes $Content } $root $path $Bytes
        }
        & $script:captureModule { param($Root,$Path) Assert-CapturePathNoReparse -Root $Root -Path $Path } $root $path
        $private=& $script:captureModule { param($Path) Test-CapturePrivatePathPermissions -Path $Path -IsDirectory $false } $path
        return $private -and (Get-AssetHash -Bytes ([IO.File]::ReadAllBytes($path))) -ceq [string]$Page.expectedDraftBodySha256
    }catch{return $false}
}

function Get-PublishAssetObservation {
    param($Plan,$Page,$Asset,[string]$ApiBase,[scriptblock]$HttpInvoker,[string]$Comment='')
    return Get-ManagedAttachmentObservation -SiteOrigin $Plan.siteOrigin -ApiBase $ApiBase -CloudId $Plan.cloudId `
        -PageId ([string]$Page.pageId) -RemoteFilename ([string]$Asset.remoteFilename) -MediaType ([string]$Asset.mediaType) `
        -Sha256 ([string]$Asset.sha256) -ByteLength ([int64]$Asset.byteLength) -HttpInvoker $HttpInvoker -ExpectedComment $Comment
}

function Get-IntermediateAssetCreateStorage {
    param([string]$OperationId,[string]$ProjectionId)
    if($OperationId -cnotmatch '^[a-f0-9]{32}$' -or $ProjectionId -cnotmatch '^[a-z][a-z0-9-]{0,49}$'){
        throw 'UnsafeIntermediateCreateIdentity'
    }
    return "<p>SYP171 operation $OperationId staging $ProjectionId</p>"
}

function Test-IntermediateAssetCreateReadback {
    param($Page,$Remote,[string]$PageId,[string]$Storage)
    return $null -ne $Remote -and $PageId -cmatch '^[0-9]+$' -and
        $Remote.pageId -ceq $PageId -and $Remote.spaceId -ceq $Page.spaceId -and
        $Remote.parentId -ceq $Page.parentId -and $Remote.title -ceq $Page.title -and
        $Remote.version -eq 1 -and $Remote.storage -ceq $Storage
}

function Test-PublishPageBaseline {
    param([object]$Page,[string]$ApiBase,[scriptblock]$HttpInvoker)
    $published=Get-PublishPage -ApiBase $ApiBase -PageId $Page.pageId -Draft $false -HttpInvoker $HttpInvoker
    $draft=Get-PublishPage -ApiBase $ApiBase -PageId $Page.pageId -Draft $true -HttpInvoker $HttpInvoker
    if($null -eq $published -or $null -eq $draft){return 'RemoteReadIncomplete'}
    if($draft.version -ne $published.version -or $draft.storage -cne $published.storage){return 'DraftConflict'}
    if($published.version -ne [int]$Page.expectedPublishedVersion -or
        (Get-AssetHash -Bytes ([Text.Encoding]::UTF8.GetBytes($published.storage))) -cne $Page.expectedPublishedBodySha256 -or
        $published.title -cne $Page.title -or $published.spaceId -cne $Page.spaceId -or $published.parentId -cne $Page.parentId){return 'RemoteDrift'}
    return $null
}

function Test-PublishCreateBaseline {
    param([object]$Page,[object]$Plan,[string]$ApiBase,[scriptblock]$HttpInvoker)
    if([string]$Page.parentProjectionId -eq ''){
        $parent=Get-PublishPage -ApiBase $ApiBase -PageId $Page.parentId -Draft $false -HttpInvoker $HttpInvoker
        if($null -eq $parent -or $parent.spaceId -cne $Page.spaceId -or
            $parent.version -ne [int]$Page.expectedParentVersion -or
            (Get-AssetHash -Bytes ([Text.Encoding]::UTF8.GetBytes($parent.storage))) -cne $Page.expectedParentBodySha256){
            return 'CreateTargetDrift'
        }
    }
    if(-not(Test-CreateTitleAvailable -SiteOrigin $Plan.siteOrigin -ApiBase $ApiBase -CloudId $Plan.cloudId -SpaceId $Page.spaceId -Title $Page.title -HttpInvoker $HttpInvoker)){
        return 'CreateTargetDrift'
    }
    return $null
}

function Get-LinkedJournalEntry {
    param([object]$Journal,[string]$ProjectionId)
    $matches=@($Journal.pages|Where-Object {[string]$_.projectionId -ceq $ProjectionId})
    if($matches.Count -ne 1){return $null}
    return $matches[0]
}

function Resolve-LinkedCreateParent {
    param([object]$Page,[object]$Plan,[object]$Journal,[object]$Frozen,[string]$ApiBase,[scriptblock]$HttpInvoker)
    if([string]$Page.parentProjectionId -eq ''){return [pscustomobject]@{status='ready';page=$Page}}
    $parentId=[string]$Page.parentProjectionId
    $parentPlan=@($Plan.pages|Where-Object {[string]$_.projectionId -ceq $parentId})
    $entry=Get-LinkedJournalEntry -Journal $Journal -ProjectionId $parentId
    if($parentPlan.Count -ne 1 -or $null -eq $entry -or $parentPlan[0].action -cne 'create' -or
        $parentPlan[0].spaceId -cne $Page.spaceId -or $entry.stage -notin @('identity-confirmed','asset-write-sent','assets-confirmed','final-ready','final-write-sent','final-confirmed') -or
        [string]$entry.pageId -cnotmatch '^[0-9]+$'){
        return [pscustomobject]@{status='blocked';page=$null}
    }
    $effectiveParent=$parentPlan[0]
    if([string]$parentPlan[0].parentProjectionId -ne ''){
        $resolvedGrandparent=Resolve-LinkedCreateParent -Page $parentPlan[0] -Plan $Plan -Journal $Journal -Frozen $Frozen -ApiBase $ApiBase -HttpInvoker $HttpInvoker
        if($resolvedGrandparent.status -cne 'ready'){return [pscustomobject]@{status='blocked';page=$null}}
        $effectiveParent=$resolvedGrandparent.page
    }
    $expectedParentId=$effectiveParent.parentId
    if([string]$entry.parentId -cne [string]$expectedParentId){return [pscustomobject]@{status='blocked';page=$null}}
    $remote=Get-PublishPage -ApiBase $ApiBase -PageId ([string]$entry.pageId) -Draft $false -HttpInvoker $HttpInvoker
    $draft=Get-PublishPage -ApiBase $ApiBase -PageId ([string]$entry.pageId) -Draft $true -HttpInvoker $HttpInvoker
    if(-not(Test-LinkedCreateParentReadback -Page $parentPlan[0] -Entry $entry -Remote $remote -Draft $draft `
        -Plan $Plan -Journal $Journal -Frozen $Frozen -ExpectedParentId $expectedParentId)){
        return [pscustomobject]@{status='blocked';page=$null}
    }
    $effective=@{}
    foreach($key in $Page.Keys){$effective[$key]=$Page[$key]}
    $effective.parentId=[string]$remote.pageId
    return [pscustomobject]@{status='ready';page=$effective}
}

function Get-LinkedCreateFinalStorage {
    param([object]$Page,[object]$Plan,[object]$Journal,[object]$Frozen)
    try{
        $body=[string]$Frozen.payloads[[string]$Page.projectionId]
        if([string]::IsNullOrEmpty($body)){return $null}
        foreach($targetId in @($Page.deferredTargets)){
            $token="__SYP171_LINK_${targetId}__"
            $targetPlan=@($Plan.pages|Where-Object {[string]$_.projectionId -ceq [string]$targetId})
            $targetEntry=Get-LinkedJournalEntry -Journal $Journal -ProjectionId ([string]$targetId)
            if($targetPlan.Count -ne 1 -or $null -eq $targetEntry -or [string]$targetEntry.pageId -cnotmatch '^[0-9]+$' -or
                -not $body.Contains($token,[StringComparison]::Ordinal)){return $null}
            $body=$body.Replace($token,[string]$targetEntry.pageId)
        }
        if($body.Contains('__SYP171_LINK_',[StringComparison]::Ordinal)){return $null}
        return $body
    }catch{return $null}
}

function Test-LinkedCreateParentReadback {
    param([object]$Page,[object]$Entry,[object]$Remote,[object]$Draft,[object]$Plan,[object]$Journal,[object]$Frozen,[object]$ExpectedParentId)
    if($null -eq $Remote -or $null -eq $Draft -or [string]$Entry.parentId -cne [string]$ExpectedParentId){return $false}
    $effective=@{}
    foreach($key in $Page.Keys){$effective[$key]=$Page[$key]}
    $effective.parentId=$ExpectedParentId
    $intermediate=Get-IntermediateAssetCreateStorage -OperationId ([string]$Plan.operationId) -ProjectionId ([string]$Page.projectionId)
    $intermediateMatches=(Test-IntermediateAssetCreateReadback -Page $effective -Remote $Remote -PageId ([string]$Entry.pageId) -Storage $intermediate) -and
        (Test-IntermediateAssetCreateReadback -Page $effective -Remote $Draft -PageId ([string]$Entry.pageId) -Storage $intermediate)
    switch([string]$Entry.stage){
        {$_ -in @('identity-confirmed','asset-write-sent','assets-confirmed','final-ready')} {return $intermediateMatches}
        'final-write-sent' {
            if($intermediateMatches){return $true}
            $final=Get-LinkedCreateFinalStorage -Page $Page -Plan $Plan -Journal $Journal -Frozen $Frozen
            if($null -eq $final){return $false}
            $sha=Get-AssetHash -Bytes ([Text.Encoding]::UTF8.GetBytes($final))
            if([string]$Entry.resolvedPayloadSha256 -cne $sha){return $false}
            $marker="SYP171:$($Plan.operationId):$($Entry.pageId):$sha"
            return (Test-LinkedFinalReadback -Page $Page -Entry $Entry -Remote $Remote -ExpectedStorage $final -Marker $marker -ExpectedParentId $ExpectedParentId) -and
                (Test-LinkedFinalReadback -Page $Page -Entry $Entry -Remote $Draft -ExpectedStorage $final -Marker $marker -ExpectedParentId $ExpectedParentId)
        }
        'final-confirmed' {
            $final=Get-LinkedCreateFinalStorage -Page $Page -Plan $Plan -Journal $Journal -Frozen $Frozen
            if($null -eq $final){return $false}
            $sha=Get-AssetHash -Bytes ([Text.Encoding]::UTF8.GetBytes($final))
            if([string]$Entry.resolvedPayloadSha256 -cne $sha){return $false}
            $marker="SYP171:$($Plan.operationId):$($Entry.pageId):$sha"
            return (Test-LinkedFinalReadback -Page $Page -Entry $Entry -Remote $Remote -ExpectedStorage $final -Marker $marker -ExpectedParentId $ExpectedParentId) -and
                (Test-LinkedFinalReadback -Page $Page -Entry $Entry -Remote $Draft -ExpectedStorage $final -Marker $marker -ExpectedParentId $ExpectedParentId)
        }
        default {return $false}
    }
}

function Test-LinkedFinalReadback {
    param([object]$Page,[object]$Entry,[object]$Remote,[string]$ExpectedStorage,[string]$Marker,[object]$ExpectedParentId)
    $parentId=if($PSBoundParameters.ContainsKey('ExpectedParentId')){[string]$ExpectedParentId}else{[string]$Entry.parentId}
    $expectedVersion=if($Page.action -ceq 'create'){2}else{[int]$Page.expectedPublishedVersion+1}
    return $null -ne $Remote -and $Remote.pageId -ceq [string]$Entry.pageId -and
        $Remote.spaceId -ceq [string]$Page.spaceId -and [string]$Remote.parentId -ceq $parentId -and
        $Remote.title -ceq [string]$Page.title -and $Remote.version -eq $expectedVersion -and
        $Remote.versionMessage -ceq $Marker -and
        (Test-ConfluenceStorageEquivalent -Expected $ExpectedStorage -Actual $Remote.storage)
}

function Test-LinkedJournalShape {
    param([object]$Journal)
    if(-not(Test-Syp171JsonKeys -Value $Journal -Expected @('schemaVersion','operationId','planSha256','status','pages')) -or
        -not(Test-Syp171JsonInteger -Value $Journal.schemaVersion -Minimum 1) -or $Journal.schemaVersion -ne 3 -or
        [string]$Journal.operationId -cnotmatch '^[a-f0-9]{32}$' -or [string]$Journal.planSha256 -cnotmatch '^[a-f0-9]{64}$' -or
        $Journal.status -cnotin @('planned','in-progress','uncertain','blocked','confirmed') -or
        $Journal.pages -isnot [array] -or @($Journal.pages).Count -lt 1 -or @($Journal.pages).Count -gt 100){return $false}
    foreach($page in @($Journal.pages)){
        if(-not(Test-Syp171JsonKeys -Value $page -Expected @('projectionId','pageId','parentId','stage','resolvedPayloadSha256','version','assets')) -or
            [string]$page.projectionId -cnotmatch '^[a-z][a-z0-9-]{0,49}$' -or [string]$page.pageId -cnotmatch '^([0-9]+)?$' -or
            [string]$page.parentId -cnotmatch '^([0-9]+)?$' -or
            $page.stage -cnotin @('no-op','planned','identity-write-sent','identity-response','identity-confirmed',
                'asset-write-sent','assets-confirmed','final-ready','final-write-sent','final-confirmed') -or
            [string]$page.resolvedPayloadSha256 -cnotmatch '^([a-f0-9]{64})?$' -or
            -not(Test-Syp171JsonInteger -Value $page.version -Minimum 0) -or
            $page.assets -isnot [array] -or @($page.assets).Count -gt 25){return $false}
        foreach($asset in @($page.assets)){
            if(-not(Test-Syp171JsonKeys -Value $asset -Expected @('remoteFilename','sha256','stage','remoteAttachmentId','remoteVersion')) -or
                [string]::IsNullOrWhiteSpace([string]$asset.remoteFilename) -or [string]$asset.sha256 -cnotmatch '^[a-f0-9]{64}$' -or
                $asset.stage -cnotin @('planned','write-sent','confirmed') -or [string]$asset.remoteAttachmentId -cnotmatch '^([0-9]+)?$' -or
                -not(Test-Syp171JsonInteger -Value $asset.remoteVersion -Minimum 0)){return $false}
        }
    }
    return $true
}

function Test-LinkedCreateJournalProgress {
    param([object]$Page,[object]$Entry)
    $pageId=[string]$Entry.pageId
    $assetStages=@($Entry.assets|ForEach-Object {[string]$_.stage})
    $allAssetsPlanned=@($assetStages|Where-Object {$_ -cne 'planned'}).Count -eq 0
    $allAssetsConfirmed=@($assetStages|Where-Object {$_ -cne 'confirmed'}).Count -eq 0
    $assetsHaveOnlyResumableProgress=@($assetStages|Where-Object {$_ -cnotin @('planned','confirmed')}).Count -eq 0
    $hasConfirmedAsset=@($assetStages|Where-Object {$_ -ceq 'confirmed'}).Count -gt 0
    switch([string]$Entry.stage){
        'planned' {return $pageId -ceq '' -and $allAssetsPlanned}
        'identity-write-sent' {return $pageId -ceq '' -and $allAssetsPlanned}
        'identity-response' {return $pageId -cmatch '^[0-9]+$' -and $allAssetsPlanned}
        'identity-confirmed' {return $pageId -cmatch '^[0-9]+$' -and @($assetStages|Where-Object {$_ -cnotin @('planned','confirmed')}).Count -eq 0}
        'asset-write-sent' {return $pageId -cmatch '^[0-9]+$' -and @($assetStages|Where-Object {$_ -ceq 'write-sent'}).Count -gt 0}
        'assets-confirmed' {return $pageId -cmatch '^[0-9]+$' -and $assetsHaveOnlyResumableProgress -and $hasConfirmedAsset}
        'final-ready' {
            return $pageId -cmatch '^[0-9]+$' -and $allAssetsConfirmed -and
                [string]$Entry.resolvedPayloadSha256 -cmatch '^[a-f0-9]{64}$'
        }
        {$_ -in @('final-write-sent','final-confirmed')} {
            return $pageId -cmatch '^[0-9]+$' -and $allAssetsConfirmed -and
                [string]$Entry.resolvedPayloadSha256 -cmatch '^[a-f0-9]{64}$'
        }
        default {return $false}
    }
}

function Test-LinkedSyncBaseline {
    param([string]$SyncPath,$Plan,[string]$Digest,$Journal)
    try{
        $sync=Read-Syp171StrictJsonFile -Path $SyncPath -Depth 18
        if($sync -isnot [System.Collections.IDictionary] -or
            (($sync.Keys|Sort-Object)-join ',') -cne 'operationId,pages,planSha256,schemaVersion,sourceDigest' -or
            $sync.schemaVersion -ne 3 -or $sync.operationId -cne $Plan.operationId -or
            $sync.planSha256 -cne $Digest -or $sync.sourceDigest -cne $Plan.sourceDigest -or
            $sync.pages -isnot [array] -or @($sync.pages).Count -ne @($Plan.pages).Count -or
            $Journal.status -cne 'confirmed'){return $false}
        for($i=0;$i -lt @($Plan.pages).Count;$i++){
            $page=$Plan.pages[$i];$record=$sync.pages[$i];$entry=$Journal.pages[$i]
            if($record -isnot [System.Collections.IDictionary] -or
                (($record.Keys|Sort-Object)-join ',') -cne 'action,assets,pageId,payloadSha256,projectionId,version' -or
                $record.projectionId -cne $page.projectionId -or $record.action -cne $page.action -or
                $record.pageId -cne [string]$entry.pageId -or [string]$record.pageId -cnotmatch '^[0-9]+$' -or
                ($page.action -cne 'create' -and [string]$record.pageId -cne [string]$page.pageId) -or
                $record.assets -isnot [array] -or @($record.assets).Count -ne @($entry.assets).Count){
                return $false
            }
            if($page.action -ceq 'no-op'){
                if($entry.stage -cne 'no-op' -or [int]$record.version -ne [int]$page.expectedPublishedVersion -or
                    $record.payloadSha256 -cne $page.payloadSha256){return $false}
            }else{
                if($entry.stage -cne 'final-confirmed' -or [int]$record.version -ne [int]$entry.version -or
                    $record.payloadSha256 -cne $entry.resolvedPayloadSha256){return $false}
            }
            for($j=0;$j -lt @($entry.assets).Count;$j++){
                $asset=$entry.assets[$j];$evidence=$record.assets[$j]
                if($asset.stage -cne 'confirmed' -or $evidence.remoteFilename -cne $asset.remoteFilename -or
                    $evidence.remoteAttachmentId -cne $asset.remoteAttachmentId -or
                    [int]$evidence.remoteVersion -ne [int]$asset.remoteVersion -or
                    $evidence.sha256 -cne $asset.sha256){return $false}
            }
        }
        return $true
    }catch{return $false}
}

function Invoke-PublishLinkedPages {
    param($Plan,[string]$Digest,[string]$PlanPath,$Validation,$Frozen,[string]$JournalPath,[string]$SyncPath,
        [string]$ExpectedSiteOrigin,[string]$ApiBase,[scriptblock]$HttpInvoker)
    if($Plan.schemaVersion -ne 5 -or $Plan.linkStrategy -cne 'identity-first' -or $Plan.publishMode -cne 'current'){
        return New-PublishResult -Status 'blocked' -ReasonCodes @('LinkedOperationShapeUnsupported') -JournalPath $JournalPath -SyncPath $SyncPath
    }
    if((Test-Path -LiteralPath $SyncPath -PathType Leaf) -and -not(Test-Path -LiteralPath $JournalPath -PathType Leaf)){
        return New-PublishResult -Status 'blocked' -ReasonCodes @('SyncJournalMismatch') -JournalPath $JournalPath -SyncPath $SyncPath
    }
    $journal=$null
    if(Test-Path -LiteralPath $JournalPath -PathType Leaf){
        try{$journal=Read-Syp171StrictJsonFile -Path $JournalPath -Depth 18}
        catch{return New-PublishResult -Status 'invalid' -ReasonCodes @('JournalInvalid') -JournalPath $JournalPath -SyncPath $SyncPath}
        if(-not(Test-LinkedJournalShape -Journal $journal)){
            return New-PublishResult -Status 'invalid' -ReasonCodes @('JournalInvalid') -JournalPath $JournalPath -SyncPath $SyncPath
        }
        if($journal.schemaVersion -ne 3 -or $journal.operationId -cne $Plan.operationId -or
            $journal.planSha256 -cne $Digest -or @($journal.pages).Count -ne @($Plan.pages).Count -or
            $journal.status -notin @('planned','in-progress','uncertain','confirmed')){
            return New-PublishResult -Status 'blocked' -ReasonCodes @('JournalPlanMismatch') -JournalPath $JournalPath -SyncPath $SyncPath
        }
        for($index=0;$index -lt @($Plan.pages).Count;$index++){
            $p=$Plan.pages[$index];$e=$journal.pages[$index]
            if($e.projectionId -cne $p.projectionId -or
                ($p.action -cne 'create' -and [string]$e.pageId -cne [string]$p.pageId) -or
                @($e.assets).Count -ne @($p.assetChanges).Count -or
                $e.stage -notin @('planned','no-op','identity-write-sent','identity-response','identity-confirmed','asset-write-sent','assets-confirmed','final-ready','final-write-sent','final-confirmed')){
                return New-PublishResult -Status 'blocked' -ReasonCodes @('JournalPlanMismatch') -JournalPath $JournalPath -SyncPath $SyncPath
            }
            for($assetIndex=0;$assetIndex -lt @($p.assetChanges).Count;$assetIndex++){
                if($e.assets[$assetIndex].remoteFilename -cne $p.assetChanges[$assetIndex].remoteFilename -or
                    $e.assets[$assetIndex].sha256 -cne $p.assetChanges[$assetIndex].sha256 -or
                    $e.assets[$assetIndex].stage -notin @('planned','write-sent','confirmed')){
                    return New-PublishResult -Status 'blocked' -ReasonCodes @('JournalAssetMismatch') -JournalPath $JournalPath -SyncPath $SyncPath
                }
            }
        }
    }else{
        $drift=Test-ConfluencePlanDrift -PlanPath $PlanPath -CurrentValidation $Validation -ExpectedSiteOrigin $ExpectedSiteOrigin -ApiBase $ApiBase -HttpInvoker $HttpInvoker
        if($drift.status -cne 'ready'){
            return New-PublishResult -Status 'blocked' -ReasonCodes $drift.reasonCodes -JournalPath $JournalPath -SyncPath $SyncPath
        }
        $entries=[System.Collections.Generic.List[object]]::new()
        foreach($p in @($Plan.pages)){
            $assets=@($p.assetChanges|ForEach-Object {@{remoteFilename=[string]$_.remoteFilename;sha256=[string]$_.sha256;stage='planned';remoteAttachmentId='';remoteVersion=0}})
            $entries.Add(@{projectionId=[string]$p.projectionId;pageId=$(if($p.action -ceq 'create'){''}else{[string]$p.pageId});
                parentId=[string]$p.parentId;stage=$(if($p.action -ceq 'no-op'){'no-op'}else{'planned'});resolvedPayloadSha256='';version=0;assets=$assets})
        }
        $journal=[ordered]@{schemaVersion=3;operationId=$Plan.operationId;planSha256=$Digest;status='planned';pages=@($entries.ToArray())}
        Write-AtomicJson -Path $JournalPath -Value $journal
    }
    if((Test-Path -LiteralPath $SyncPath -PathType Leaf) -and
        -not(Test-LinkedSyncBaseline -SyncPath $SyncPath -Plan $Plan -Digest $Digest -Journal $journal)){
        return New-PublishResult -Status 'blocked' -ReasonCodes @('SyncBaselineMismatch') -JournalPath $JournalPath -SyncPath $SyncPath
    }
    foreach($page in @($Plan.pages|Where-Object action -eq 'no-op')){
        $baseline=Test-PublishPageBaseline -Page $page -ApiBase $ApiBase -HttpInvoker $HttpInvoker
        if($null -ne $baseline){return New-PublishResult -Status 'blocked' -ReasonCodes @($baseline) -JournalPath $JournalPath -SyncPath $SyncPath}
    }
    foreach($page in @($Plan.pages|Where-Object action -eq 'update')){
        $entry=Get-LinkedJournalEntry -Journal $journal -ProjectionId ([string]$page.projectionId)
        if($null -eq $entry -or $entry.stage -notin @('planned','asset-write-sent','assets-confirmed','final-ready')){continue}
        $baseline=Test-PublishPageBaseline -Page $page -ApiBase $ApiBase -HttpInvoker $HttpInvoker
        if($null -ne $baseline){return New-PublishResult -Status 'blocked' -ReasonCodes @($baseline) -JournalPath $JournalPath -SyncPath $SyncPath}
    }
    $createEffectivePages=@{}
    foreach($page in @($Plan.pages|Where-Object action -eq 'create')){
        $entry=Get-LinkedJournalEntry -Journal $journal -ProjectionId ([string]$page.projectionId)
        if($null -eq $entry){return New-PublishResult -Status 'invalid' -ReasonCodes @('JournalPageUnknown') -JournalPath $JournalPath -SyncPath $SyncPath}
        if(-not(Test-LinkedCreateJournalProgress -Page $page -Entry $entry)){
            return New-PublishResult -Status 'blocked' -ReasonCodes @('JournalStateBlocked') -JournalPath $JournalPath -SyncPath $SyncPath
        }
        $effective=$page
        if([string]$page.parentProjectionId -ne ''){
            $resolvedParent=Resolve-LinkedCreateParent -Page $page -Plan $Plan -Journal $journal -Frozen $Frozen -ApiBase $ApiBase -HttpInvoker $HttpInvoker
            if($resolvedParent.status -cne 'ready'){
                return New-PublishResult -Status 'blocked' -ReasonCodes @('ParentCreateUnconfirmed') -JournalPath $JournalPath -SyncPath $SyncPath
            }
            $effective=$resolvedParent.page
        }
        $expectedJournalParent=[string]$effective.parentId
        $linkedPlannedParent=([string]$page.parentProjectionId -ne '' -and $entry.stage -ceq 'planned' -and [string]$entry.parentId -ceq '')
        if(-not $linkedPlannedParent -and [string]$entry.parentId -cne $expectedJournalParent){
            return New-PublishResult -Status 'blocked' -ReasonCodes @('LinkedCreateDrift') -JournalPath $JournalPath -SyncPath $SyncPath
        }
        $createEffectivePages[[string]$page.projectionId]=$effective
        if($entry.stage -in @('asset-write-sent','assets-confirmed','final-ready','final-write-sent','final-confirmed')){
            if([string]$entry.pageId -cnotmatch '^[0-9]+$'){
                return New-PublishResult -Status 'blocked' -ReasonCodes @('JournalPlanMismatch') -JournalPath $JournalPath -SyncPath $SyncPath
            }
            if($entry.stage -in @('asset-write-sent','assets-confirmed')){
                $intermediate=Get-IntermediateAssetCreateStorage -OperationId ([string]$Plan.operationId) -ProjectionId ([string]$page.projectionId)
                $remote=Get-PublishPage -ApiBase $ApiBase -PageId ([string]$entry.pageId) -Draft $false -HttpInvoker $HttpInvoker
                $draft=Get-PublishPage -ApiBase $ApiBase -PageId ([string]$entry.pageId) -Draft $true -HttpInvoker $HttpInvoker
                if(-not(Test-IntermediateAssetCreateReadback -Page $effective -Remote $remote -PageId ([string]$entry.pageId) -Storage $intermediate) -or
                    -not(Test-IntermediateAssetCreateReadback -Page $effective -Remote $draft -PageId ([string]$entry.pageId) -Storage $intermediate)){
                    return New-PublishResult -Status 'blocked' -ReasonCodes @('LinkedCreateDrift') -JournalPath $JournalPath -SyncPath $SyncPath
                }
            }
            continue
        }
        if($entry.stage -ceq 'identity-write-sent' -and [string]$entry.pageId -eq ''){
            return New-PublishResult -Status 'uncertain' -ReasonCodes @('CreateResultUncertain') -JournalPath $JournalPath -SyncPath $SyncPath
        }
        $intermediate=Get-IntermediateAssetCreateStorage -OperationId ([string]$Plan.operationId) -ProjectionId ([string]$page.projectionId)
        if($entry.stage -ceq 'planned'){
            $preflight=Test-PublishCreateBaseline -Page $effective -Plan $Plan -ApiBase $ApiBase -HttpInvoker $HttpInvoker
            if($null -ne $preflight){return New-PublishResult -Status 'blocked' -ReasonCodes @($preflight) -JournalPath $JournalPath -SyncPath $SyncPath}
            $body=[ordered]@{spaceId=[string]$effective.spaceId;status='current';title=[string]$effective.title;parentId=[string]$effective.parentId;
                body=@{representation='storage';value=$intermediate}}|ConvertTo-Json -Depth 8 -Compress
            $request=[pscustomobject]@{Method='POST';Uri="$($ApiBase.TrimEnd('/'))/wiki/api/v2/pages";
                Headers=@{Accept='application/json';'Content-Type'='application/json'};Body=$body;TimeoutSec=30;ResponseLimitBytes=4MB;AuthAllowed=$true}
            $entry.parentId=[string]$effective.parentId;$entry.stage='identity-write-sent';$journal.status='uncertain'
            Write-AtomicJson -Path $JournalPath -Value $journal
            $response=$null
            try{$response=& $HttpInvoker $request}catch{}
            $createdId=Get-PublishCreateResponseId -Response $response -Page $effective
            if($createdId -eq ''){return New-PublishResult -Status 'uncertain' -ReasonCodes @('CreateResultUncertain') -JournalPath $JournalPath -SyncPath $SyncPath}
            $entry.pageId=$createdId;$entry.stage='identity-response';$journal.status='in-progress'
            Write-AtomicJson -Path $JournalPath -Value $journal
        }
        if($entry.stage -notin @('identity-response','identity-confirmed')){
            return New-PublishResult -Status 'blocked' -ReasonCodes @('JournalStateBlocked') -JournalPath $JournalPath -SyncPath $SyncPath
        }
        $remote=Get-PublishPage -ApiBase $ApiBase -PageId ([string]$entry.pageId) -Draft $false -HttpInvoker $HttpInvoker
        $draft=Get-PublishPage -ApiBase $ApiBase -PageId ([string]$entry.pageId) -Draft $true -HttpInvoker $HttpInvoker
        if(-not(Test-IntermediateAssetCreateReadback -Page $effective -Remote $remote -PageId ([string]$entry.pageId) -Storage $intermediate) -or
            -not(Test-IntermediateAssetCreateReadback -Page $effective -Remote $draft -PageId ([string]$entry.pageId) -Storage $intermediate)){
            return New-PublishResult -Status 'uncertain' -ReasonCodes @('CreateReadbackUncertain') -JournalPath $JournalPath -SyncPath $SyncPath
        }
        $entry.stage='identity-confirmed';$entry.version=1;$journal.status='in-progress'
        Write-AtomicJson -Path $JournalPath -Value $journal
    }
    $identities=[System.Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $seenIds=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($page in @($Plan.pages)){
        $entry=Get-LinkedJournalEntry -Journal $journal -ProjectionId ([string]$page.projectionId)
        $id=if($page.action -ceq 'create'){[string]$entry.pageId}else{[string]$page.pageId}
        if($id -cnotmatch '^[0-9]+$' -or -not $seenIds.Add($id)){
            return New-PublishResult -Status 'blocked' -ReasonCodes @('LinkIdentityUnconfirmed') -JournalPath $JournalPath -SyncPath $SyncPath
        }
        $identities[[string]$page.projectionId]=$id
    }
    foreach($page in @($Plan.pages)){
        $entry=Get-LinkedJournalEntry -Journal $journal -ProjectionId ([string]$page.projectionId)
        for($assetIndex=0;$assetIndex -lt @($page.assetChanges).Count;$assetIndex++){
            $asset=$page.assetChanges[$assetIndex];$assetEntry=$entry.assets[$assetIndex]
            $comment="SYP171:$($Plan.operationId):$($page.projectionId):$($asset.sha256)"
            $requiredComment=if($asset.action -ceq 'upload'){$comment}else{''}
            $observation=Get-PublishAssetObservation -Plan $Plan -Page $entry -Asset $asset -ApiBase $ApiBase -HttpInvoker $HttpInvoker -Comment $requiredComment
            if($observation.status -cne 'ready'){
                return New-PublishResult -Status 'uncertain' -ReasonCodes (@('AttachmentResultUncertain')+@($observation.reasonCodes)) -JournalPath $JournalPath -SyncPath $SyncPath
            }
            if($observation.action -ceq 'upload'){
                if($asset.action -cne 'upload' -or $assetEntry.stage -cne 'planned' -or $page.action -ceq 'no-op'){
                    return New-PublishResult -Status 'uncertain' -ReasonCodes @('AttachmentResultUncertain') -JournalPath $JournalPath -SyncPath $SyncPath
                }
                if($page.action -ceq 'update'){
                    $baseline=Test-PublishPageBaseline -Page $page -ApiBase $ApiBase -HttpInvoker $HttpInvoker
                    if($null -ne $baseline){return New-PublishResult -Status 'blocked' -ReasonCodes @($baseline) -JournalPath $JournalPath -SyncPath $SyncPath}
                }elseif($page.action -ceq 'create'){
                    $effective=$createEffectivePages[[string]$page.projectionId]
                    if([string]$page.parentProjectionId -ne ''){
                        $resolvedParent=Resolve-LinkedCreateParent -Page $page -Plan $Plan -Journal $journal -Frozen $Frozen -ApiBase $ApiBase -HttpInvoker $HttpInvoker
                        if($resolvedParent.status -cne 'ready'){
                            return New-PublishResult -Status 'blocked' -ReasonCodes @('ParentCreateUnconfirmed') -JournalPath $JournalPath -SyncPath $SyncPath
                        }
                        $effective=$resolvedParent.page
                    }
                    if([string]$entry.parentId -cne [string]$effective.parentId){
                        return New-PublishResult -Status 'blocked' -ReasonCodes @('LinkedCreateDrift') -JournalPath $JournalPath -SyncPath $SyncPath
                    }
                    $intermediate=Get-IntermediateAssetCreateStorage -OperationId ([string]$Plan.operationId) -ProjectionId ([string]$page.projectionId)
                    $remote=Get-PublishPage -ApiBase $ApiBase -PageId ([string]$entry.pageId) -Draft $false -HttpInvoker $HttpInvoker
                    $draft=Get-PublishPage -ApiBase $ApiBase -PageId ([string]$entry.pageId) -Draft $true -HttpInvoker $HttpInvoker
                    if(-not(Test-IntermediateAssetCreateReadback -Page $effective -Remote $remote -PageId ([string]$entry.pageId) -Storage $intermediate) -or
                        -not(Test-IntermediateAssetCreateReadback -Page $effective -Remote $draft -PageId ([string]$entry.pageId) -Storage $intermediate)){
                        return New-PublishResult -Status 'blocked' -ReasonCodes @('LinkedCreateDrift') -JournalPath $JournalPath -SyncPath $SyncPath
                    }
                }
                $bytes=[byte[]]$Frozen.assets["$($page.projectionId):$($asset.remoteFilename)"]
                $request=New-ManagedAttachmentUploadRequest -ApiBase $ApiBase -PageId ([string]$entry.pageId) -Asset $asset `
                    -ProjectionId ([string]$page.projectionId) -OperationId ([string]$Plan.operationId) -Bytes $bytes
                $assetEntry.stage='write-sent';$entry.stage='asset-write-sent';$journal.status='uncertain'
                Write-AtomicJson -Path $JournalPath -Value $journal
                try{$null=& $HttpInvoker $request}catch{}
                $observation=Get-PublishAssetObservation -Plan $Plan -Page $entry -Asset $asset -ApiBase $ApiBase -HttpInvoker $HttpInvoker -Comment $comment
                if($observation.status -cne 'ready' -or $observation.action -cne 'reuse'){
                    return New-PublishResult -Status 'uncertain' -ReasonCodes (@('AttachmentResultUncertain')+@($observation.reasonCodes)) -JournalPath $JournalPath -SyncPath $SyncPath
                }
            }elseif($asset.action -ceq 'reuse' -and
                ($observation.remoteAttachmentId -cne [string]$asset.remoteAttachmentId -or $observation.remoteVersion -ne [int]$asset.remoteVersion)){
                return New-PublishResult -Status 'blocked' -ReasonCodes @('RemoteAttachmentDrift') -JournalPath $JournalPath -SyncPath $SyncPath
            }
            if($assetEntry.stage -ceq 'confirmed' -and
                ($assetEntry.remoteAttachmentId -cne $observation.remoteAttachmentId -or $assetEntry.remoteVersion -ne $observation.remoteVersion)){
                return New-PublishResult -Status 'blocked' -ReasonCodes @('ConfirmedAttachmentDrift') -JournalPath $JournalPath -SyncPath $SyncPath
            }
            $assetEntry.stage='confirmed';$assetEntry.remoteAttachmentId=$observation.remoteAttachmentId;$assetEntry.remoteVersion=$observation.remoteVersion
            if($page.action -ceq 'create' -and $entry.stage -in @('identity-confirmed','planned','asset-write-sent','assets-confirmed')){
                $remainingAssets=@($entry.assets|Where-Object stage -ne 'confirmed').Count
                $entry.stage=if($remainingAssets -eq 0){'assets-confirmed'}else{'identity-confirmed'}
            }elseif($entry.stage -in @('identity-confirmed','planned','asset-write-sent')){$entry.stage='assets-confirmed'}
            $journal.status='in-progress';Write-AtomicJson -Path $JournalPath -Value $journal
        }
    }
    $confirmed=[System.Collections.Generic.List[object]]::new()
    foreach($page in @($Plan.pages)){
        $entry=Get-LinkedJournalEntry -Journal $journal -ProjectionId ([string]$page.projectionId)
        $template=[string]$Frozen.payloads[[string]$page.projectionId]
        $body=$template
        foreach($targetId in @($page.deferredTargets)){
            $token="__SYP171_LINK_${targetId}__"
            if(-not $identities.ContainsKey([string]$targetId) -or -not $body.Contains($token,[StringComparison]::Ordinal)){
                return New-PublishResult -Status 'blocked' -ReasonCodes @('LinkIdentityUnconfirmed') -JournalPath $JournalPath -SyncPath $SyncPath
            }
            $body=$body.Replace($token,$identities[[string]$targetId])
        }
        if($body.Contains('__SYP171_LINK_',[StringComparison]::Ordinal)){
            return New-PublishResult -Status 'blocked' -ReasonCodes @('LinkIdentityUnconfirmed') -JournalPath $JournalPath -SyncPath $SyncPath
        }
        $sha=Get-AssetHash -Bytes ([Text.Encoding]::UTF8.GetBytes($body))
        if($entry.resolvedPayloadSha256 -ne '' -and $entry.resolvedPayloadSha256 -cne $sha){
            return New-PublishResult -Status 'blocked' -ReasonCodes @('ResolvedPayloadChanged') -JournalPath $JournalPath -SyncPath $SyncPath
        }
        $effective=$page;$expectedParentId=$page.parentId
        if($page.action -ceq 'create'){
            $effective=$createEffectivePages[[string]$page.projectionId]
            if([string]$page.parentProjectionId -ne ''){
                $resolvedParent=Resolve-LinkedCreateParent -Page $page -Plan $Plan -Journal $journal -Frozen $Frozen -ApiBase $ApiBase -HttpInvoker $HttpInvoker
                if($resolvedParent.status -cne 'ready'){
                    return New-PublishResult -Status 'blocked' -ReasonCodes @('ParentCreateUnconfirmed') -JournalPath $JournalPath -SyncPath $SyncPath
                }
                $effective=$resolvedParent.page
            }
            if([string]$entry.parentId -cne [string]$effective.parentId){
                return New-PublishResult -Status 'blocked' -ReasonCodes @('LinkedCreateDrift') -JournalPath $JournalPath -SyncPath $SyncPath
            }
            $expectedParentId=$effective.parentId
        }
        if($page.action -ceq 'no-op'){
            $baseline=Test-PublishPageBaseline -Page $page -ApiBase $ApiBase -HttpInvoker $HttpInvoker
            if($null -ne $baseline){return New-PublishResult -Status 'blocked' -ReasonCodes @($baseline) -JournalPath $JournalPath -SyncPath $SyncPath}
            $assetEvidence=@($entry.assets|ForEach-Object {@{remoteFilename=$_.remoteFilename;remoteAttachmentId=$_.remoteAttachmentId;remoteVersion=$_.remoteVersion;sha256=$_.sha256}})
            $confirmed.Add(@{projectionId=$page.projectionId;pageId=$page.pageId;version=$page.expectedPublishedVersion;payloadSha256=$page.payloadSha256;action='no-op';assets=$assetEvidence})
            continue
        }
        if($entry.stage -in @('planned','identity-confirmed','assets-confirmed')){
            $entry.resolvedPayloadSha256=$sha;$entry.stage='final-ready';$journal.status='in-progress'
            Write-AtomicJson -Path $JournalPath -Value $journal
        }
        $marker="SYP171:$($Plan.operationId):$($entry.pageId):$sha"
        if($entry.stage -in @('final-write-sent','final-confirmed')){
            $readback=Get-PublishPage -ApiBase $ApiBase -PageId ([string]$entry.pageId) -Draft $false -HttpInvoker $HttpInvoker
            if(-not(Test-LinkedFinalReadback -Page $page -Entry $entry -Remote $readback -ExpectedStorage $body -Marker $marker -ExpectedParentId $expectedParentId)){
                return New-PublishResult -Status $(if($entry.stage -ceq 'final-write-sent'){'uncertain'}else{'blocked'}) -ReasonCodes @('LinkedFinalReadbackUncertain') -JournalPath $JournalPath -SyncPath $SyncPath
            }
            $entry.stage='final-confirmed';$entry.version=$readback.version;$journal.status='in-progress'
            Write-AtomicJson -Path $JournalPath -Value $journal
            $assetEvidence=@($entry.assets|ForEach-Object {@{remoteFilename=$_.remoteFilename;remoteAttachmentId=$_.remoteAttachmentId;remoteVersion=$_.remoteVersion;sha256=$_.sha256}})
            $confirmed.Add(@{projectionId=$page.projectionId;pageId=$entry.pageId;version=$readback.version;payloadSha256=$sha;action=$page.action;assets=$assetEvidence})
            continue
        }
        if($entry.stage -cne 'final-ready'){return New-PublishResult -Status 'blocked' -ReasonCodes @('JournalStateBlocked') -JournalPath $JournalPath -SyncPath $SyncPath}
        if($page.action -ceq 'create'){
            $intermediate=Get-IntermediateAssetCreateStorage -OperationId ([string]$Plan.operationId) -ProjectionId ([string]$page.projectionId)
            if([string]$entry.parentId -cne [string]$effective.parentId){
                return New-PublishResult -Status 'blocked' -ReasonCodes @('LinkedCreateDrift') -JournalPath $JournalPath -SyncPath $SyncPath
            }
            $published=Get-PublishPage -ApiBase $ApiBase -PageId ([string]$entry.pageId) -Draft $false -HttpInvoker $HttpInvoker
            $draft=Get-PublishPage -ApiBase $ApiBase -PageId ([string]$entry.pageId) -Draft $true -HttpInvoker $HttpInvoker
            if(-not(Test-IntermediateAssetCreateReadback -Page $effective -Remote $published -PageId ([string]$entry.pageId) -Storage $intermediate) -or
                -not(Test-IntermediateAssetCreateReadback -Page $effective -Remote $draft -PageId ([string]$entry.pageId) -Storage $intermediate)){
                return New-PublishResult -Status 'blocked' -ReasonCodes @('LinkedCreateDrift') -JournalPath $JournalPath -SyncPath $SyncPath
            }
        }else{
            $baseline=Test-PublishPageBaseline -Page $page -ApiBase $ApiBase -HttpInvoker $HttpInvoker
            if($null -ne $baseline){return New-PublishResult -Status 'blocked' -ReasonCodes @($baseline) -JournalPath $JournalPath -SyncPath $SyncPath}
        }
        $expectedVersion=if($page.action -ceq 'create'){2}else{[int]$page.expectedPublishedVersion+1}
        $requestBody=[ordered]@{id=[string]$entry.pageId;status='current';title=[string]$page.title;spaceId=[string]$page.spaceId;
            body=@{representation='storage';value=$body};version=@{number=$expectedVersion;message=$marker}}|ConvertTo-Json -Depth 8 -Compress
        $request=[pscustomobject]@{Method='PUT';Uri="$($ApiBase.TrimEnd('/'))/wiki/api/v2/pages/$($entry.pageId)";
            Headers=@{Accept='application/json';'Content-Type'='application/json'};Body=$requestBody;TimeoutSec=30;ResponseLimitBytes=4MB;AuthAllowed=$true}
        $entry.stage='final-write-sent';$journal.status='uncertain';Write-AtomicJson -Path $JournalPath -Value $journal
        try{$null=& $HttpInvoker $request}catch{}
        $readback=Get-PublishPage -ApiBase $ApiBase -PageId ([string]$entry.pageId) -Draft $false -HttpInvoker $HttpInvoker
        if(-not(Test-LinkedFinalReadback -Page $page -Entry $entry -Remote $readback -ExpectedStorage $body -Marker $marker -ExpectedParentId $expectedParentId)){
            return New-PublishResult -Status 'uncertain' -ReasonCodes @('LinkedFinalReadbackUncertain') -JournalPath $JournalPath -SyncPath $SyncPath
        }
        foreach($asset in @($page.assetChanges)){
            $requiredComment=if($asset.action -ceq 'upload'){"SYP171:$($Plan.operationId):$($page.projectionId):$($asset.sha256)"}else{''}
            $again=Get-PublishAssetObservation -Plan $Plan -Page $entry -Asset $asset -ApiBase $ApiBase -HttpInvoker $HttpInvoker -Comment $requiredComment
            if($again.status -cne 'ready' -or $again.action -cne 'reuse'){
                return New-PublishResult -Status 'uncertain' -ReasonCodes @('AttachmentReadbackUncertain') -JournalPath $JournalPath -SyncPath $SyncPath
            }
        }
        $entry.stage='final-confirmed';$entry.version=$readback.version;$journal.status='in-progress'
        Write-AtomicJson -Path $JournalPath -Value $journal
        $assetEvidence=@($entry.assets|ForEach-Object {@{remoteFilename=$_.remoteFilename;remoteAttachmentId=$_.remoteAttachmentId;remoteVersion=$_.remoteVersion;sha256=$_.sha256}})
        $confirmed.Add(@{projectionId=$page.projectionId;pageId=$entry.pageId;version=$readback.version;payloadSha256=$sha;action=$page.action;assets=$assetEvidence})
    }
    $journal.status='confirmed';Write-AtomicJson -Path $JournalPath -Value $journal
    if(-not(Test-Path -LiteralPath $SyncPath -PathType Leaf)){
        Write-AtomicJson -Path $SyncPath -Value ([ordered]@{schemaVersion=3;operationId=$Plan.operationId;planSha256=$Digest;sourceDigest=$Plan.sourceDigest;pages=@($confirmed.ToArray())})
        $status=if(@($Plan.pages|Where-Object action -ne 'no-op').Count -eq 0){'no-op'}else{'published'}
        return New-PublishResult -Status $status -ReasonCodes @() -JournalPath $JournalPath -SyncPath $SyncPath
    }
    return New-PublishResult -Status 'no-op' -ReasonCodes @() -JournalPath $JournalPath -SyncPath $SyncPath
}

function Test-DraftJournal {
    param($Journal,$Plan,[string]$Digest)
    $schema=5
    if(-not(Test-Syp171JsonKeys $Journal @('schemaVersion','publishMode','operationId','planSha256','status','pages')) -or
        $Journal.schemaVersion -ne $schema -or -not(Test-Syp171JsonInteger $Journal.schemaVersion) -or $Journal.publishMode -cne 'draft' -or
        $Journal.operationId -cne $Plan.operationId -or $Journal.planSha256 -cne $Digest -or
        $Journal.status -cnotin @('planned','in-progress','uncertain','confirmed') -or $Journal.pages -isnot [array] -or
        @($Journal.pages).Count -ne @($Plan.pages).Count){return $false}
    for($i=0;$i -lt @($Plan.pages).Count;$i++){
        $entry=$Journal.pages[$i];$page=$Plan.pages[$i]
        $entryKeys=@('projectionId','pageId','stage','readbackBodySha256')
        if($schema -eq 5){$entryKeys+=@('assets')}
        if(-not(Test-Syp171JsonKeys $entry $entryKeys) -or
            $entry.projectionId -cne $page.projectionId -or $entry.pageId -cne $page.pageId -or
            $entry.stage -cnotin @('planned','write-sent','confirmed','no-op') -or
            [string]$entry.readbackBodySha256 -cnotmatch '^([a-f0-9]{64})?$' -or
            ($entry.stage -cin @('planned','write-sent') -and $entry.readbackBodySha256 -cne '') -or
            ($entry.stage -cin @('confirmed','no-op') -and [string]$entry.readbackBodySha256 -cnotmatch '^[a-f0-9]{64}$') -or
            ($entry.stage -ceq 'no-op' -and $page.action -cne 'no-op') -or
            ($entry.stage -cin @('write-sent','confirmed') -and $page.action -cne 'update') -or
            ($Journal.status -ceq 'confirmed' -and $entry.stage -cnotin @('confirmed','no-op'))){return $false}
        if($schema -eq 5){
            if($entry.assets -isnot [array] -or @($entry.assets).Count -ne @($page.assetChanges).Count){return $false}
            for($j=0;$j -lt @($entry.assets).Count;$j++){
                $actual=$entry.assets[$j];$asset=$page.assetChanges[$j]
                if(-not(Test-Syp171JsonKeys $actual @('remoteFilename','sha256','stage','remoteAttachmentId','remoteVersion')) -or
                    $actual.remoteFilename -cne $asset.remoteFilename -or $actual.sha256 -cne $asset.sha256 -or
                    $actual.stage -cnotin @('planned','write-sent','confirmed') -or $actual.remoteAttachmentId -isnot [string] -or
                    -not(Test-Syp171JsonInteger $actual.remoteVersion) -or
                    ($actual.stage -cne 'confirmed' -and ($actual.remoteAttachmentId -cne '' -or $actual.remoteVersion -ne 0)) -or
                    ($actual.stage -ceq 'confirmed' -and ($actual.remoteAttachmentId -cnotmatch '^[0-9]+$' -or $actual.remoteVersion -lt 1)) -or
                    ($actual.stage -ceq 'write-sent' -and $asset.action -cne 'upload') -or
                    ($actual.stage -ceq 'confirmed' -and $asset.action -ceq 'upload' -and $actual.remoteVersion -ne 1) -or
                    ($actual.stage -ceq 'confirmed' -and $asset.action -ceq 'reuse' -and
                        ($actual.remoteAttachmentId -cne $asset.remoteAttachmentId -or $actual.remoteVersion -ne $asset.remoteVersion)) -or
                    ($entry.stage -cne 'planned' -and $actual.stage -cne 'confirmed')){return $false}
            }
        }
    }
    return $true
}

function Get-DraftSyncRecord {
    param($Plan,$Journal,[string]$Digest)
    $pages=@(for($i=0;$i -lt @($Plan.pages).Count;$i++){
        $page=$Plan.pages[$i];$entry=$Journal.pages[$i]
        $record=[ordered]@{projectionId=$page.projectionId;pageId=$page.pageId;draftVersion=1;publishedVersion=$page.expectedPublishedVersion;
            publishedBodySha256=$page.expectedPublishedBodySha256;payloadSha256=$page.payloadSha256;readbackBodySha256=$entry.readbackBodySha256;action=$page.action}
        $record['assets']=@(for($j=0;$j -lt @($entry.assets).Count;$j++){
            $asset=$entry.assets[$j];$planned=$page.assetChanges[$j]
            [ordered]@{remoteFilename=$asset.remoteFilename;remoteAttachmentId=$asset.remoteAttachmentId;remoteVersion=$asset.remoteVersion;
                sha256=$asset.sha256;byteLength=$planned.byteLength}
        })
        $record
    })
    return [ordered]@{schemaVersion=5;publishMode='draft';operationId=$Plan.operationId;planSha256=$Digest;sourceDigest=$Plan.sourceDigest;pages=$pages}
}

function Test-DraftSyncRecord {
    param($Sync,$Expected)
    if(-not(Test-Syp171JsonKeys $Sync @('schemaVersion','publishMode','operationId','planSha256','sourceDigest','pages')) -or
        $Sync.schemaVersion -ne $Expected.schemaVersion -or -not(Test-Syp171JsonInteger $Sync.schemaVersion) -or $Sync.publishMode -cne 'draft' -or
        $Sync.operationId -cne $Expected.operationId -or $Sync.planSha256 -cne $Expected.planSha256 -or
        $Sync.sourceDigest -cne $Expected.sourceDigest -or $Sync.pages -isnot [array] -or @($Sync.pages).Count -ne @($Expected.pages).Count){return $false}
    for($i=0;$i -lt @($Expected.pages).Count;$i++){
        $actual=$Sync.pages[$i];$record=$Expected.pages[$i]
        if(-not(Test-Syp171JsonKeys $actual @($record.Keys))){return $false}
        foreach($key in @($record.Keys|Where-Object {$_ -cne 'assets'})){if($actual[$key] -cne $record[$key]){return $false}}
        if($Expected.schemaVersion -eq 5){
            if($actual.assets -isnot [array] -or @($actual.assets).Count -ne @($record.assets).Count){return $false}
            for($j=0;$j -lt @($record.assets).Count;$j++){
                $asset=$actual.assets[$j];$expectedAsset=$record.assets[$j]
                if(-not(Test-Syp171JsonKeys $asset @($expectedAsset.Keys)) -or
                    -not(Test-Syp171JsonInteger $asset.remoteVersion) -or -not(Test-Syp171JsonInteger $asset.byteLength)){return $false}
                foreach($key in $expectedAsset.Keys){if($asset[$key] -cne $expectedAsset[$key]){return $false}}
            }
        }
        if(-not(Test-Syp171JsonInteger $actual.draftVersion) -or -not(Test-Syp171JsonInteger $actual.publishedVersion)){return $false}
    }
    return $true
}

function Get-DraftRemoteState {
    param($Page,[string]$ApiBase,[scriptblock]$HttpInvoker)
    $current=Get-PublishPage -ApiBase $ApiBase -PageId $Page.pageId -Draft $false -HttpInvoker $HttpInvoker
    $draft=Read-ConfluenceDraftPage -ApiBase $ApiBase -PageId $Page.pageId -HttpInvoker $HttpInvoker
    if($null -eq $current -or $null -eq $draft){return [pscustomobject]@{error='RemoteReadIncomplete';draft=$null}}
    if($current.version -ne $Page.expectedPublishedVersion -or
        (Get-AssetHash -Bytes ([Text.Encoding]::UTF8.GetBytes($current.storage))) -cne $Page.expectedPublishedBodySha256){
        return [pscustomobject]@{error='PublishedContentChanged';draft=$null}
    }
    foreach($remote in @($current,$draft)){
        if($remote.pageId -cne $Page.pageId -or $remote.spaceId -cne $Page.spaceId -or $remote.parentId -cne $Page.parentId -or
            $remote.title -cne $Page.title){return [pscustomobject]@{error='DraftIdentityUnverified';draft=$null}}
    }
    if($draft.version -ne 1){return [pscustomobject]@{error='DraftVersionInvalid';draft=$null}}
    return [pscustomobject]@{error='';draft=$draft;current=$current}
}

function Confirm-DraftAssets {
    param($Plan,$Page,$Entry,$Journal,$Frozen,[string]$JournalPath,[string]$SyncPath,[string]$ApiBase,[scriptblock]$HttpInvoker,[switch]$AllowUpload)
    for($i=0;$i -lt @($Page.assetChanges).Count;$i++){
        $asset=$Page.assetChanges[$i];$record=$Entry.assets[$i]
        $marker=('SYP171:' + [string]($($Plan.operationId)) + ':' + [string]($($Page.projectionId)) + ':' + [string]($($asset.sha256)))
        $comment=if($asset.action -ceq 'upload' -and $record.stage -cne 'planned'){$marker}else { [string]::Empty }
        $observed=Get-PublishAssetObservation -Plan $Plan -Page $Page -Asset $asset -ApiBase $ApiBase -HttpInvoker $HttpInvoker -Comment $comment
        if($record.stage -ceq 'write-sent'){
            if($observed.status -cne 'ready' -or $observed.action -cne 'reuse' -or $observed.remoteVersion -ne 1){
                return New-PublishResult -Status uncertain -ReasonCodes (@('AttachmentResultUncertain')+@($observed.reasonCodes)) -JournalPath $JournalPath -SyncPath $SyncPath
            }
        }elseif($record.stage -ceq 'confirmed'){
            if($observed.status -cne 'ready' -or $observed.action -cne 'reuse' -or $observed.remoteAttachmentId -cne $record.remoteAttachmentId -or
                $observed.remoteVersion -ne $record.remoteVersion){
                return New-PublishResult -Status blocked -ReasonCodes @('ConfirmedAttachmentDrift') -JournalPath $JournalPath -SyncPath $SyncPath
            }
            continue
        }elseif($observed.status -cne 'ready' -or $observed.action -cne $asset.action -or
            ($asset.action -ceq 'reuse' -and ($observed.remoteAttachmentId -cne $asset.remoteAttachmentId -or $observed.remoteVersion -ne $asset.remoteVersion))){
            return New-PublishResult -Status blocked -ReasonCodes (@('RemoteAttachmentDrift')+@($observed.reasonCodes)) -JournalPath $JournalPath -SyncPath $SyncPath
        }elseif($asset.action -ceq 'upload'){
            if(-not $AllowUpload){continue}
            $state=Get-DraftRemoteState $Page $ApiBase $HttpInvoker
            if($state.error -cne ''){return New-PublishResult -Status blocked -ReasonCodes @($state.error) -JournalPath $JournalPath -SyncPath $SyncPath}
            $references=Get-ConfluenceStorageAttachmentNames -Storage $state.current.storage -SiteOrigin $Plan.siteOrigin -PageId $Page.pageId
            if($references.status -cne 'valid' -or @($references.names) -ccontains $asset.remoteFilename){
                return New-PublishResult -Status blocked -ReasonCodes @('DraftAttachmentAffectsCurrent') -JournalPath $JournalPath -SyncPath $SyncPath
            }
            $request=New-ManagedAttachmentUploadRequest -ApiBase $ApiBase -PageId $Page.pageId -Asset $asset -ProjectionId $Page.projectionId                  -OperationId $Plan.operationId -Bytes ([byte[]]$Frozen.assets[([string]($($Page.projectionId)) + ':' + [string]($($asset.remoteFilename)))])
            $record.stage='write-sent';$Journal.status='uncertain';Write-AtomicJson -Path $JournalPath -Value $Journal
            try{$response=& $HttpInvoker $request}catch{
                return New-PublishResult -Status uncertain -ReasonCodes @('AttachmentResultUncertain') -JournalPath $JournalPath -SyncPath $SyncPath
            }
            if([int]$response.StatusCode -cnotin @(200,201)){
                return New-PublishResult -Status uncertain -ReasonCodes @('AttachmentResultUncertain') -JournalPath $JournalPath -SyncPath $SyncPath
            }
            $observed=Get-PublishAssetObservation -Plan $Plan -Page $Page -Asset $asset -ApiBase $ApiBase -HttpInvoker $HttpInvoker -Comment $marker
            if($observed.status -cne 'ready' -or $observed.action -cne 'reuse' -or $observed.remoteVersion -ne 1){
                return New-PublishResult -Status uncertain -ReasonCodes (@('AttachmentResultUncertain')+@($observed.reasonCodes)) -JournalPath $JournalPath -SyncPath $SyncPath
            }
        }
        $record.stage='confirmed';$record.remoteAttachmentId=[string]$observed.remoteAttachmentId;$record.remoteVersion=$observed.remoteVersion
        $Journal.status='in-progress';Write-AtomicJson -Path $JournalPath -Value $Journal
    }
    return $null
}

function Invoke-PublishDraftPages {
    param($Plan,[string]$Digest,[string]$PlanPath,$Frozen,[string]$JournalPath,[string]$SyncPath,[string]$ApiBase,[scriptblock]$HttpInvoker)
    $journal=$null
    if(Test-Path -LiteralPath $JournalPath -PathType Leaf){
        try{$journal=Read-Syp171StrictJsonFile -Path $JournalPath -Depth 18}catch{
            return New-PublishResult -Status invalid -ReasonCodes @('JournalInvalid') -JournalPath $JournalPath -SyncPath $SyncPath
        }
        if(-not(Test-DraftJournal $journal $Plan $Digest)){
            return New-PublishResult -Status blocked -ReasonCodes @('JournalPlanMismatch') -JournalPath $JournalPath -SyncPath $SyncPath
        }
    }else{
        $entries=@($Plan.pages|ForEach-Object {
            $record=[ordered]@{projectionId=$_.projectionId;pageId=$_.pageId;stage='planned';readbackBodySha256=''}
            $record['assets']=@($_.assetChanges|ForEach-Object {[ordered]@{
                remoteFilename=$_.remoteFilename;sha256=$_.sha256;stage='planned';remoteAttachmentId='';remoteVersion=0}})
            $record
        })
        $journal=[ordered]@{schemaVersion=5;publishMode='draft';operationId=$Plan.operationId;planSha256=$Digest;status='planned';pages=$entries}
    }
    if(Test-Path -LiteralPath $SyncPath -PathType Leaf){
        try{$sync=Read-Syp171StrictJsonFile -Path $SyncPath -Depth 18}catch{$sync=$null}
        if($journal.status -cne 'confirmed' -or -not(Test-DraftSyncRecord $sync (Get-DraftSyncRecord $Plan $journal $Digest))){
            return New-PublishResult -Status blocked -ReasonCodes @('SyncJournalMismatch') -JournalPath $JournalPath -SyncPath $SyncPath
        }
    }
    $wasConfirmed=$journal.status -ceq 'confirmed'
    $pendingSnapshots=[System.Collections.Generic.List[object]]::new()
    # Check the entire batch before resuming any unstarted write.
    for($i=0;$i -lt @($Plan.pages).Count;$i++){
        $page=$Plan.pages[$i];$entry=$journal.pages[$i]
        $state=Get-DraftRemoteState $page $ApiBase $HttpInvoker
        if($state.error -cne ''){return New-PublishResult -Status blocked -ReasonCodes @($state.error) -JournalPath $JournalPath -SyncPath $SyncPath}
        $draft=$state.draft;$rawHash=Get-AssetHash -Bytes ([Text.Encoding]::UTF8.GetBytes($draft.storage))
        $snapshotBytes=$null
        $marker=('syp171:' + [string]($($Plan.operationId)) + ':' + [string]($($page.projectionId)) + ':' + [string]($($page.payloadSha256)))
        if($entry.stage -ceq 'planned'){
            if($rawHash -cne $page.expectedDraftBodySha256){return New-PublishResult -Status blocked -ReasonCodes @('DraftDrift') -JournalPath $JournalPath -SyncPath $SyncPath}
            if($page.action -ceq 'update'){
                $snapshotBytes=[Text.Encoding]::UTF8.GetBytes($draft.storage)
            }
        }elseif($entry.stage -ceq 'write-sent'){
            if($draft.versionMessage -cne $marker -or -not(Test-ConfluenceStorageEquivalent -Expected $Frozen.payloads[$page.projectionId] -Actual $draft.storage)){
                return New-PublishResult -Status uncertain -ReasonCodes @('DraftWriteUnresolved') -JournalPath $JournalPath -SyncPath $SyncPath
            }
            $entry.stage='confirmed';$entry.readbackBodySha256=$rawHash;$journal.status='in-progress'
            Write-AtomicJson -Path $JournalPath -Value $journal
        }elseif($rawHash -cne $entry.readbackBodySha256 -or
            -not(Test-ConfluenceStorageEquivalent -Expected $Frozen.payloads[$page.projectionId] -Actual $draft.storage) -or
            ($entry.stage -ceq 'confirmed' -and $draft.versionMessage -cne $marker)){
            return New-PublishResult -Status blocked -ReasonCodes @('DraftReadbackChanged') -JournalPath $JournalPath -SyncPath $SyncPath
        }
        if($page.action -ceq 'update'){
            $pendingSnapshots.Add([pscustomobject]@{page=$page;bytes=$snapshotBytes})
        }
    }
    foreach($snapshot in $pendingSnapshots){
        if(-not(Save-DraftPrewriteSnapshot -PlanPath $PlanPath -Page $snapshot.page -Bytes $snapshot.bytes)){
            return New-PublishResult -Status blocked -ReasonCodes @('DraftSnapshotUnavailable') -JournalPath $JournalPath -SyncPath $SyncPath
        }
    }
    foreach($page in @($Plan.pages)){
        $entry=@($journal.pages|Where-Object projectionId -CEQ $page.projectionId)[0]
        $assetError=Confirm-DraftAssets -Plan $Plan -Page $page -Entry $entry -Journal $journal -Frozen $Frozen -JournalPath $JournalPath                  -SyncPath $SyncPath -ApiBase $ApiBase -HttpInvoker $HttpInvoker
        if($null -ne $assetError){return $assetError}
    }
    Write-AtomicJson -Path $JournalPath -Value $journal
    for($i=0;$i -lt @($Plan.pages).Count;$i++){
        $page=$Plan.pages[$i];$entry=$journal.pages[$i]
        if($entry.stage -cin @('confirmed','no-op')){continue}
        $state=Get-DraftRemoteState $page $ApiBase $HttpInvoker
        if($state.error -cne ''){return New-PublishResult -Status blocked -ReasonCodes @($state.error) -JournalPath $JournalPath -SyncPath $SyncPath}
        if((Get-AssetHash -Bytes ([Text.Encoding]::UTF8.GetBytes($state.draft.storage))) -cne $page.expectedDraftBodySha256){
            return New-PublishResult -Status blocked -ReasonCodes @('DraftDrift') -JournalPath $JournalPath -SyncPath $SyncPath
        }
        $assetError=Confirm-DraftAssets -Plan $Plan -Page $page -Entry $entry -Journal $journal -Frozen $Frozen -JournalPath $JournalPath                  -SyncPath $SyncPath -ApiBase $ApiBase -HttpInvoker $HttpInvoker -AllowUpload
        if($null -ne $assetError){return $assetError}
        $state=Get-DraftRemoteState $page $ApiBase $HttpInvoker
        if($state.error -cne ''){return New-PublishResult -Status blocked -ReasonCodes @($state.error) -JournalPath $JournalPath -SyncPath $SyncPath}
        if((Get-AssetHash -Bytes ([Text.Encoding]::UTF8.GetBytes($state.draft.storage))) -cne $page.expectedDraftBodySha256){
            return New-PublishResult -Status blocked -ReasonCodes @('DraftDrift') -JournalPath $JournalPath -SyncPath $SyncPath
        }
        if($page.action -ceq 'no-op'){
            if(-not(Test-ConfluenceStorageEquivalent -Expected $Frozen.payloads[$page.projectionId] -Actual $state.draft.storage)){
                return New-PublishResult -Status blocked -ReasonCodes @('DraftReadbackChanged') -JournalPath $JournalPath -SyncPath $SyncPath
            }
            $entry.stage='no-op';$entry.readbackBodySha256=$page.expectedDraftBodySha256
            Write-AtomicJson -Path $JournalPath -Value $journal
            continue
        }
        $marker=('syp171:' + [string]($($Plan.operationId)) + ':' + [string]($($page.projectionId)) + ':' + [string]($($page.payloadSha256)))
        $body=[ordered]@{id=$page.pageId;status='draft';title=$page.title;spaceId=$page.spaceId;parentId=$page.parentId;
            body=@{representation='storage';value=$Frozen.payloads[$page.projectionId]};version=@{number=1;message=$marker}}|ConvertTo-Json -Depth 8 -Compress
        $request=[pscustomobject]@{Method='PUT';Uri=([string]($($ApiBase.TrimEnd('/'))) + '/wiki/api/v2/pages/' + [string]($($page.pageId)));
            Headers=@{Accept='application/json';'Content-Type'='application/json'};Body=$body;TimeoutSec=30;ResponseLimitBytes=4MB;AuthAllowed=$true}
        $entry.stage='write-sent';$journal.status='uncertain';Write-AtomicJson -Path $JournalPath -Value $journal
        try{$response=& $HttpInvoker $request}catch{
            return New-PublishResult -Status uncertain -ReasonCodes @('DraftWriteUnresolved') -JournalPath $JournalPath -SyncPath $SyncPath
        }
        if([int]$response.StatusCode -ne 200){return New-PublishResult -Status uncertain -ReasonCodes @('DraftWriteUnresolved') -JournalPath $JournalPath -SyncPath $SyncPath}
        $state=Get-DraftRemoteState $page $ApiBase $HttpInvoker
        if($state.error -cne ''){return New-PublishResult -Status blocked -ReasonCodes @($state.error) -JournalPath $JournalPath -SyncPath $SyncPath}
        if($state.draft.versionMessage -cne $marker -or -not(Test-ConfluenceStorageEquivalent -Expected $Frozen.payloads[$page.projectionId] -Actual $state.draft.storage)){
            return New-PublishResult -Status uncertain -ReasonCodes @('DraftWriteUnresolved') -JournalPath $JournalPath -SyncPath $SyncPath
        }
        $entry.stage='confirmed';$entry.readbackBodySha256=Get-AssetHash -Bytes ([Text.Encoding]::UTF8.GetBytes($state.draft.storage))
        $journal.status='in-progress';Write-AtomicJson -Path $JournalPath -Value $journal
    }
    # Recheck every confirmed page at the final checkpoint, including earlier batch writes.
    for($i=0;$i -lt @($Plan.pages).Count;$i++){
        $page=$Plan.pages[$i];$entry=$journal.pages[$i];$state=Get-DraftRemoteState $page $ApiBase $HttpInvoker
        if($state.error -cne ''){return New-PublishResult -Status blocked -ReasonCodes @($state.error) -JournalPath $JournalPath -SyncPath $SyncPath}
        if((Get-AssetHash -Bytes ([Text.Encoding]::UTF8.GetBytes($state.draft.storage))) -cne $entry.readbackBodySha256){
            return New-PublishResult -Status blocked -ReasonCodes @('DraftReadbackChanged') -JournalPath $JournalPath -SyncPath $SyncPath
        }
        $assetError=Confirm-DraftAssets -Plan $Plan -Page $page -Entry $entry -Journal $journal -Frozen $Frozen -JournalPath $JournalPath                  -SyncPath $SyncPath -ApiBase $ApiBase -HttpInvoker $HttpInvoker
        if($null -ne $assetError){return $assetError}
    }
    $journal.status='confirmed';Write-AtomicJson -Path $JournalPath -Value $journal
    Write-AtomicJson -Path $SyncPath -Value (Get-DraftSyncRecord $Plan $journal $Digest)
    if($wasConfirmed -or @($Plan.pages|Where-Object action -ne 'no-op').Count -eq 0){
        $status='no-op'
    }else{
        $status='drafted'
    }
    return New-PublishResult -Status $status -ReasonCodes @() -JournalPath $JournalPath -SyncPath $SyncPath
}

function Invoke-ConfluencePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)][object]$CurrentValidation,
        [Parameter(Mandatory)][string]$AuthorizationPath,
        [Parameter(Mandatory)][string]$JournalPath,
        [Parameter(Mandatory)][string]$SyncPath,
        [Parameter(Mandatory)][string]$ExpectedSiteOrigin,
        [Parameter(Mandatory)][string]$ApiBase,
        [Parameter(Mandatory)][scriptblock]$HttpInvoker
    )
    if(-not(Test-Path -LiteralPath $PlanPath -PathType Leaf) -or -not(Test-Path -LiteralPath $AuthorizationPath -PathType Leaf)){
        return New-PublishResult -Status 'invalid' -ReasonCodes @('PlanOrAuthorizationUnavailable') -JournalPath $JournalPath -SyncPath $SyncPath
    }
    $planBytes=[IO.File]::ReadAllBytes([IO.Path]::GetFullPath($PlanPath))
    $digest=Get-AssetHash -Bytes $planBytes
    try{
        $plan=ConvertFrom-Syp171StrictJson -Json ([Text.UTF8Encoding]::new($false,$true).GetString($planBytes)) -Depth 18
        $authorization=Read-Syp171StrictJsonFile -Path $AuthorizationPath -Depth 10
    }catch{return New-PublishResult -Status 'invalid' -ReasonCodes @('PlanOrAuthorizationInvalid') -JournalPath $JournalPath -SyncPath $SyncPath}
    if($plan -is [System.Collections.IDictionary] -and $plan.schemaVersion -eq 5 -and
        $plan.Contains('publishMode') -and $plan.publishMode -ceq 'draft' -and
        (-not $plan.Contains('draftSnapshotTiming') -or $plan.draftSnapshotTiming -cne 'prewrite')){
        return New-PublishResult -Status 'blocked' -ReasonCodes @('PlanRequiresRepreview') -JournalPath $JournalPath -SyncPath $SyncPath
    }
    if(-not(Test-ConfluencePlanShape -Plan $plan)){
        return New-PublishResult -Status 'invalid' -ReasonCodes @('PlanSchemaInvalid') -JournalPath $JournalPath -SyncPath $SyncPath
    }
    if(-not(Test-PublishAuthorization -Authorization $authorization -Plan $plan -Digest $digest) -or
        $plan.siteOrigin -cne $ExpectedSiteOrigin -or -not(Test-ConfluenceApiBaseIdentity -ApiBase $ApiBase -CloudId ([string]($($plan.cloudId))) -ComparisonMode RawTrimmed)){
        return New-PublishResult -Status 'blocked' -ReasonCodes @('AuthorizationMismatch') -JournalPath $JournalPath -SyncPath $SyncPath
    }
    $frozen=[pscustomobject]@{payloads=@{};assets=@{}}
    $staticError=Test-PublishStatic -PlanPath $PlanPath -Plan $plan -Digest $digest -Validation $CurrentValidation -Frozen $frozen
    if($null -ne $staticError){return New-PublishResult -Status 'blocked' -ReasonCodes @($staticError) -JournalPath $JournalPath -SyncPath $SyncPath}
    if($plan.publishMode -ceq 'current' -and @($plan.pages|Where-Object action -ne 'no-op').Count -eq 0){
        $baseline=Test-ConfluencePlanDrift -PlanPath $PlanPath -CurrentValidation $CurrentValidation -ExpectedSiteOrigin $ExpectedSiteOrigin -ApiBase $ApiBase -HttpInvoker $HttpInvoker
        if($baseline.status -cne 'ready'){
            return New-PublishResult -Status 'blocked' -ReasonCodes @($baseline.reasonCodes) -JournalPath $JournalPath -SyncPath $SyncPath
        }
        return New-PublishResult -Status 'no-op' -ReasonCodes @() -JournalPath $JournalPath -SyncPath $SyncPath
    }
    if((Test-Path -LiteralPath $SyncPath -PathType Leaf) -and -not(Test-Path -LiteralPath $JournalPath -PathType Leaf)){
        return New-PublishResult -Status 'blocked' -ReasonCodes @('SyncJournalMismatch') -JournalPath $JournalPath -SyncPath $SyncPath
    }
    $lockPath="$([IO.Path]::GetFullPath($JournalPath)).lock"
    $lock=$null
    try{$lock=[IO.FileStream]::new($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
    catch{return New-PublishResult -Status 'blocked' -ReasonCodes @('OperationAlreadyRunning') -JournalPath $JournalPath -SyncPath $SyncPath}
    try{
        if($plan.publishMode -ceq 'draft'){
            return Invoke-PublishDraftPages -Plan $plan -Digest $digest -PlanPath $PlanPath -Frozen $frozen `
                -JournalPath $JournalPath -SyncPath $SyncPath -ApiBase $ApiBase -HttpInvoker $HttpInvoker
        }
        return Invoke-PublishLinkedPages -Plan $plan -Digest $digest -PlanPath $PlanPath -Validation $CurrentValidation -Frozen $frozen `
            -JournalPath $JournalPath -SyncPath $SyncPath -ExpectedSiteOrigin $ExpectedSiteOrigin -ApiBase $ApiBase -HttpInvoker $HttpInvoker

    }catch{
        return New-PublishResult -Status 'failed' -ReasonCodes @('PublishFailure') -JournalPath $JournalPath -SyncPath $SyncPath
    }finally{if($null -ne $lock){$lock.Dispose()}}
}

Export-ModuleMember -Function Invoke-ConfluencePlan
