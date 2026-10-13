# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
Import-Module -Name (Join-Path $PSScriptRoot 'StorageProjection.psm1') -Scope Local
Import-Module -Name (Join-Path $PSScriptRoot 'StrictJson.psm1') -Scope Local

function New-ImportResult {
    param([string]$Status,[string[]]$ReasonCodes,[int]$SourceBlockCount,[int]$UnknownCount,[int]$NonReadyCount,[object[]]$AcceptedDestinations=@(),[object[]]$AcceptedAttachments=@())
    return [pscustomobject]@{
        status=$Status;reasonCodes=@($ReasonCodes);sourceBlockCount=$SourceBlockCount;unknownCount=$UnknownCount
        nonReadyCount=$NonReadyCount;acceptedDestinations=@($AcceptedDestinations);acceptedAttachments=@($AcceptedAttachments)
    }
}

function Resolve-CaptureArtifact {
    param([string]$CaptureRoot,[string]$Relative)
    if([string]::IsNullOrWhiteSpace($Relative) -or $Relative -match '[:\\\r\n]' -or
        $Relative.StartsWith('/',[StringComparison]::Ordinal) -or
        @($Relative -split '/'|Where-Object {$_ -in @('', '.', '..')}).Count -gt 0){return $null}
    $root=[IO.Path]::GetFullPath($CaptureRoot).TrimEnd('\','/')
    $path=[IO.Path]::GetFullPath((Join-Path $root $Relative))
    if(-not $path.StartsWith(($root+[IO.Path]::DirectorySeparatorChar),[StringComparison]::OrdinalIgnoreCase) -or
        -not(Test-Path -LiteralPath $path -PathType Leaf)){return $null}
    $current=$path
    while($current -ne $root){
        if((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){return $null}
        $current=[IO.Path]::GetDirectoryName($current)
        if([string]::IsNullOrWhiteSpace($current)){return $null}
    }
    if((Get-Item -LiteralPath $root -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){return $null}
    return $path
}

function Test-CaptureManifest {
    param([object]$Capture,[string]$CapturePath)
    $top=@('schemaVersion','captureId','capturedAtUtc','siteOrigin','cloudId','scope','status','reasonCodes','incompletePageIds','pages')
    if(-not(Test-Syp171JsonKeys -Value $Capture -Expected $top) -or $Capture.schemaVersion -ne 1 -or
        [string]::IsNullOrWhiteSpace([string]$Capture.captureId) -or
        [string]$Capture.siteOrigin -cnotmatch '^https://[^/?#]+$' -or
        [string]$Capture.cloudId -cnotmatch '^[a-fA-F0-9-]{36}$' -or
        $Capture.status -notin @('complete','partial') -or $Capture.reasonCodes -isnot [array] -or
        $Capture.incompletePageIds -isnot [array] -or $Capture.pages -isnot [array]){return 'ReviewSchemaInvalid'}
    if($Capture.capturedAtUtc -is [datetime]){
        if($Capture.capturedAtUtc.Kind -ne [DateTimeKind]::Utc){return 'ReviewSchemaInvalid'}
    } elseif($Capture.capturedAtUtc -is [datetimeoffset]){
        if($Capture.capturedAtUtc.Offset -ne [TimeSpan]::Zero){return 'ReviewSchemaInvalid'}
    } elseif($Capture.capturedAtUtc -is [string] -and [string]$Capture.capturedAtUtc -cmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T.*Z$'){
        try{$null=[DateTimeOffset]::Parse([string]$Capture.capturedAtUtc,[Globalization.CultureInfo]::InvariantCulture)}
        catch{return 'ReviewSchemaInvalid'}
    } else{return 'ReviewSchemaInvalid'}
    if($Capture.status -ceq 'complete' -and (@($Capture.reasonCodes).Count -gt 0 -or @($Capture.incompletePageIds).Count -gt 0)){
        return 'ReviewSchemaInvalid'
    }
    $scope=$Capture.scope
    if($scope -isnot [System.Collections.IDictionary]){return 'ReviewSchemaInvalid'}
    if(($scope.kind -ceq 'page' -and (-not(Test-Syp171JsonKeys -Value $scope -Expected @('kind','pageIds')) -or
            $scope.pageIds -isnot [array] -or @($scope.pageIds).Count -eq 0 -or
            @($scope.pageIds|Where-Object {[string]$_ -cnotmatch '^[0-9]+$'}).Count -gt 0 -or
            @($scope.pageIds|Select-Object -Unique).Count -ne @($scope.pageIds).Count)) -or
        ($scope.kind -ceq 'space' -and (-not(Test-Syp171JsonKeys -Value $scope -Expected @('kind','spaceId')) -or
            [string]$scope.spaceId -cnotmatch '^[0-9]+$')) -or
        $scope.kind -notin @('page','space')){return 'ReviewSchemaInvalid'}
    if(@($Capture.reasonCodes|Where-Object {[string]::IsNullOrWhiteSpace([string]$_)}).Count -gt 0 -or
        @($Capture.reasonCodes|Select-Object -Unique).Count -ne @($Capture.reasonCodes).Count -or
        @($Capture.incompletePageIds|Where-Object {[string]$_ -cnotmatch '^[0-9]+$'}).Count -gt 0 -or
        @($Capture.incompletePageIds|Select-Object -Unique).Count -ne @($Capture.incompletePageIds).Count){return 'ReviewSchemaInvalid'}
    $root=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($CapturePath))
    $seen=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $requested=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $incomplete=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    if($scope.kind -ceq 'page'){
        foreach($id in @($scope.pageIds)){$null=$requested.Add([string]$id)}
        foreach($id in @($Capture.incompletePageIds)){
            if(-not $requested.Contains([string]$id) -or -not $incomplete.Add([string]$id)){return 'ReviewSchemaInvalid'}
        }
    }
    foreach($page in @($Capture.pages)){
        $pageKeys=@('pageId','spaceId','parentId','title','version','bodySha256','draftObservation','snapshotPath','candidatePath','projectionStatus','sourceBlocks','unsupported','attachments')
        if(-not(Test-Syp171JsonKeys -Value $page -Expected $pageKeys) -or
            [string]$page.pageId -cnotmatch '^[0-9]+$' -or -not $seen.Add([string]$page.pageId) -or
            ($scope.kind -ceq 'page' -and (-not $requested.Contains([string]$page.pageId) -or $incomplete.Contains([string]$page.pageId))) -or
            [string]$page.spaceId -cnotmatch '^[0-9]+$' -or
            ($scope.kind -ceq 'space' -and [string]$page.spaceId -cne [string]$scope.spaceId) -or
            [string]$page.parentId -cnotmatch '^([0-9]+)?$' -or
            [string]::IsNullOrWhiteSpace([string]$page.title) -or
            ($page.version -isnot [int] -and $page.version -isnot [long]) -or $page.version -lt 1 -or
            [string]$page.bodySha256 -cnotmatch '^[a-f0-9]{64}$' -or
            $page.draftObservation -notin @('same-as-published','diverged') -or
            $page.projectionStatus -notin @('supported','unsupported') -or
            $page.sourceBlocks -isnot [array] -or $page.unsupported -isnot [array] -or
            $page.attachments -isnot [array]){return 'ReviewSchemaInvalid'}
        $snapshot=Resolve-CaptureArtifact -CaptureRoot $root -Relative ([string]$page.snapshotPath)
        $candidate=Resolve-CaptureArtifact -CaptureRoot $root -Relative ([string]$page.candidatePath)
        if($null -eq $snapshot -or $null -eq $candidate){return 'CaptureSourceChanged'}
        try{
            $raw=[IO.File]::ReadAllBytes($snapshot)
            $candidateBytes=[IO.File]::ReadAllBytes($candidate)
            if($raw.Length -gt 4MB -or $candidateBytes.Length -gt 4MB){return 'CaptureSourceChanged'}
            $storage=[Text.UTF8Encoding]::new($false,$true).GetString($raw)
            $candidateText=[Text.UTF8Encoding]::new($false,$true).GetString($candidateBytes)
        }catch{return 'CaptureSourceChanged'}
        $sha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($raw)).ToLowerInvariant()
        if($sha -cne [string]$page.bodySha256){return 'CaptureSourceChanged'}
        $projection=ConvertFrom-ConfluenceStorage -Storage $storage -PageId ([string]$page.pageId) -PageVersion ([int]$page.version)
        if($projection.bodySha256 -cne $sha -or $projection.status -cne $page.projectionStatus -or
            $projection.markdown -cne $candidateText -or
            @($projection.sourceBlocks).Count -ne @($page.sourceBlocks).Count -or
            @($projection.unsupported).Count -ne @($page.unsupported).Count){return 'CaptureSourceChanged'}
        for($i=0;$i -lt @($page.sourceBlocks).Count;$i++){
            $block=$page.sourceBlocks[$i];$actual=$projection.sourceBlocks[$i]
            if(-not(Test-Syp171JsonKeys -Value $block -Expected @('id','location','sourceSha256','sourceType','supported')) -or
                $block.supported -isnot [bool] -or $block.id -cne $actual.id -or
                $block.location -cne $actual.location -or $block.sourceSha256 -cne $actual.sourceSha256 -or
                $block.sourceType -cne $actual.sourceType -or $block.supported -ne $actual.supported){
                return 'CaptureSourceChanged'
            }
        }
        for($i=0;$i -lt @($page.unsupported).Count;$i++){
            $item=$page.unsupported[$i];$actual=$projection.unsupported[$i]
            if(-not(Test-Syp171JsonKeys -Value $item -Expected @('code','location','sourceSha256')) -or
                $item.code -cne $actual.code -or $item.location -cne $actual.location -or
                $item.sourceSha256 -cne $actual.sourceSha256){return 'CaptureSourceChanged'}
        }
        foreach($asset in @($page.attachments)){
            if(-not(Test-Syp171JsonKeys -Value $asset -Expected @('attachmentId','version','filename','mediaType','byteLength','sha256','assetPath')) -or
                [string]$asset.attachmentId -cnotmatch '^[0-9]+$' -or
                ($asset.version -isnot [int] -and $asset.version -isnot [long]) -or $asset.version -lt 1 -or
                [string]::IsNullOrWhiteSpace([string]$asset.filename) -or [string]::IsNullOrWhiteSpace([string]$asset.mediaType) -or
                ($asset.byteLength -isnot [long] -and $asset.byteLength -isnot [int]) -or
                $asset.byteLength -lt 0 -or $asset.byteLength -gt 20MB -or
                [string]$asset.sha256 -cnotmatch '^[a-f0-9]{64}$'){return 'ReviewSchemaInvalid'}
            $path=Resolve-CaptureArtifact -CaptureRoot $root -Relative ([string]$asset.assetPath)
            if($null -eq $path){return 'CaptureSourceChanged'}
            try{$bytes=[IO.File]::ReadAllBytes($path)}catch{return 'CaptureSourceChanged'}
            if($bytes.Length -ne [long]$asset.byteLength -or
                [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant() -cne [string]$asset.sha256){
                return 'CaptureSourceChanged'
            }
        }
    }
    if($scope.kind -ceq 'page' -and ($seen.Count+$incomplete.Count) -ne $requested.Count){return 'ReviewSchemaInvalid'}
    return $null
}

function Test-ConfluenceImportReview {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CapturePath,[Parameter(Mandatory)][string]$ReviewPath)
    if(-not(Test-Path -LiteralPath $CapturePath -PathType Leaf) -or -not(Test-Path -LiteralPath $ReviewPath -PathType Leaf)){
        return New-ImportResult -Status 'invalid' -ReasonCodes @('ReviewInputUnavailable') -SourceBlockCount 0 -UnknownCount 0 -NonReadyCount 0
    }
    try {
        $capture=Read-Syp171StrictJsonFile -Path $CapturePath -Depth 20
        $review=Read-Syp171StrictJsonFile -Path $ReviewPath -Depth 20
    } catch {return New-ImportResult -Status 'invalid' -ReasonCodes @('ReviewSchemaInvalid') -SourceBlockCount 0 -UnknownCount 0 -NonReadyCount 0}
    $captureProblem=Test-CaptureManifest -Capture $capture -CapturePath $CapturePath
    if($null -ne $captureProblem){
        $resultStatus='blocked'
        if($captureProblem -ceq 'ReviewSchemaInvalid'){$resultStatus='invalid'}
        return New-ImportResult -Status $resultStatus -ReasonCodes @($captureProblem) -SourceBlockCount 0 -UnknownCount 0 -NonReadyCount 0
    }
    if($review.schemaVersion -ne 2 -or
        -not(Test-Syp171JsonKeys -Value $review -Expected @('schemaVersion','captureId','siteOrigin','dispositions','attachments')) -or
        $review.dispositions -isnot [array] -or $review.attachments -isnot [array] -or $capture.pages -isnot [array]){
        return New-ImportResult -Status 'invalid' -ReasonCodes @('ReviewSchemaInvalid') -SourceBlockCount 0 -UnknownCount 0 -NonReadyCount 0
    }
    $reasons=[System.Collections.Generic.List[string]]::new()
    if($capture.status -cne 'complete'){$reasons.Add('CaptureIncomplete')}
    if($capture.captureId -cne $review.captureId -or $capture.siteOrigin -cne $review.siteOrigin){$reasons.Add('CaptureRevisionMismatch')}
    $source=@{}
    foreach($page in @($capture.pages)){
        foreach($block in @($page.sourceBlocks)){
            $id=[string]$block.id
            if([string]::IsNullOrWhiteSpace($id) -or $source.ContainsKey($id)){$reasons.Add('DuplicateSourceBlock');continue}
            $source[$id]=[pscustomobject]@{hash=[string]$block.sourceSha256;location=[string]$block.location}
        }
    }
    $reviewed=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $unknownCount=0
    $nonReadyCount=0
    $acceptedDestinations=[System.Collections.Generic.List[object]]::new()
    $sourceAttachments=[System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach($page in @($capture.pages)){
        foreach($attachment in @($page.attachments)){
            $key=[string]$page.pageId+':'+[string]$attachment.attachmentId
            if($sourceAttachments.ContainsKey($key)){$reasons.Add('DuplicateCaptureAttachment');continue}
            $sourceAttachments[$key]=[pscustomobject]@{pageId=[string]$page.pageId;attachmentId=[string]$attachment.attachmentId;version=[long]$attachment.version;sha256=[string]$attachment.sha256;filename=[string]$attachment.filename;mediaType=[string]$attachment.mediaType;byteLength=[long]$attachment.byteLength}
        }
    }
    $reviewedAttachments=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $acceptedAttachments=[System.Collections.Generic.List[object]]::new()
    foreach($item in @($review.attachments)){
        $keys=@('pageId','attachmentId','version','sha256','status','ready','destination','reason')
        if(-not(Test-Syp171JsonKeys -Value $item -Expected $keys) -or
            [string]$item.pageId -cnotmatch '^[0-9]+$' -or [string]$item.attachmentId -cnotmatch '^[0-9]+$' -or
            ($item.version -isnot [int] -and $item.version -isnot [long]) -or $item.version -lt 1 -or
            [string]$item.sha256 -cnotmatch '^[a-f0-9]{64}$' -or
            $item.status -notin @('supported','manual','not-converted') -or $item.ready -isnot [bool] -or
            [string]::IsNullOrWhiteSpace([string]$item.reason)){$reasons.Add('AttachmentReviewInvalid');continue}
        $key=[string]$item.pageId+':'+[string]$item.attachmentId
        if(-not $reviewedAttachments.Add($key)){$reasons.Add('DuplicateAttachmentDisposition')}
        if(-not $sourceAttachments.ContainsKey($key)){$reasons.Add('UnexpectedAttachmentDisposition');continue}
        $sourceAttachment=$sourceAttachments[$key]
        if([long]$item.version -ne $sourceAttachment.version -or [string]$item.sha256 -cne $sourceAttachment.sha256){$reasons.Add('AttachmentHashMismatch')}
        $shouldBeReady=$item.status -ceq 'supported'
        if([bool]$item.ready -ne $shouldBeReady){$reasons.Add('AttachmentReadinessMismatch')}
        if(-not $shouldBeReady){$nonReadyCount++}
        if($shouldBeReady){
            $destination=$item.destination
            if(-not(Test-Syp171JsonKeys -Value $destination -Expected @('localPath','displayFilename','mediaType','byteLength','contentSha256')) -or
                [string]$destination.localPath -match '[\\:\r\n]|(?:^|/)\.\.(?:/|$)' -or
                [string]$destination.localPath -match '^(?:/|[A-Za-z]:)' -or
                @(([string]$destination.localPath -split '/')|Where-Object {$_ -in @('', '.', '..')}).Count -gt 0 -or
                [string]::IsNullOrWhiteSpace([string]$destination.displayFilename) -or
                [string]$destination.mediaType -cne $sourceAttachment.mediaType -or
                ($destination.byteLength -isnot [int] -and $destination.byteLength -isnot [long]) -or
                [long]$destination.byteLength -ne $sourceAttachment.byteLength -or
                [string]$destination.contentSha256 -cne $sourceAttachment.sha256){$reasons.Add('AttachmentDestinationInvalid');continue}
            $acceptedAttachments.Add([pscustomobject]@{
                pageId=$sourceAttachment.pageId;attachmentId=$sourceAttachment.attachmentId;version=$sourceAttachment.version
                sha256=$sourceAttachment.sha256;localPath=[string]$destination.localPath;displayFilename=[string]$destination.displayFilename
                mediaType=$sourceAttachment.mediaType;byteLength=$sourceAttachment.byteLength
            })
        }elseif($null -ne $item.destination){$reasons.Add('NonSupportedAttachmentDestinationForbidden')}
    }
    foreach($key in $sourceAttachments.Keys){if(-not $reviewedAttachments.Contains($key)){$reasons.Add('AttachmentDispositionMissing')}}
    foreach($item in @($review.dispositions)){
        if(-not(Test-Syp171JsonKeys -Value $item -Expected @('blockId','sourceSha256','location','status','ready','destinations','reason')) -or
            $item.status -notin @('accepted','unknown','retained','excluded') -or $item.ready -isnot [bool] -or
            $item.destinations -isnot [array] -or [string]::IsNullOrWhiteSpace([string]$item.reason)){$reasons.Add('ReviewSchemaInvalid');continue}
        $id=[string]$item.blockId
        if(-not $reviewed.Add($id)){$reasons.Add('DuplicateDisposition')}
        if(-not $source.ContainsKey($id)){$reasons.Add('UnexpectedSourceDisposition');continue}
        if([string]$item.sourceSha256 -cne $source[$id].hash -or [string]$item.location -cne $source[$id].location){$reasons.Add('SourceHashMismatch')}
        if($item.status -ceq 'unknown'){
            $unknownCount++
            if($item.ready){$reasons.Add('UnknownMarkedReady')}
        }
        $shouldBeReady=$item.status -ceq 'accepted'
        if([bool]$item.ready -ne $shouldBeReady){$reasons.Add('DispositionReadinessMismatch')}
        if(-not $shouldBeReady){$nonReadyCount++}
        if($shouldBeReady -and @($item.destinations).Count -eq 0){$reasons.Add('DispositionDestinationMissing')}
        if(-not $shouldBeReady -and @($item.destinations).Count -gt 0){$reasons.Add('NonAcceptedDestinationForbidden')}
        foreach($destination in @($item.destinations)){
            if(-not(Test-Syp171JsonKeys -Value $destination -Expected @('sourceArtifact','sourceSectionId','contentSha256')) -or
                [string]$destination.sourceArtifact -cnotmatch '\.[mM][dD]$' -or
                [string]$destination.sourceArtifact -match '[\\:\r\n]|//|(?:^|/)\.\.(?:/|$)' -or
                [string]$destination.sourceArtifact -match '^(?:/|[A-Za-z]:)' -or
                @(([string]$destination.sourceArtifact -split '/')|Where-Object {$_ -in @('', '.', '..')}).Count -gt 0 -or
                [string]$destination.sourceSectionId -cne 'document' -or
                [string]$destination.contentSha256 -cnotmatch '^[a-f0-9]{64}$'){
                $reasons.Add('ReviewSchemaInvalid');continue
            }
            if($shouldBeReady){
                $acceptedDestinations.Add([pscustomobject]@{
                    blockId=[string]$item.blockId;sourceSha256=[string]$item.sourceSha256
                    sourceArtifact=[string]$destination.sourceArtifact;sourceSectionId=[string]$destination.sourceSectionId
                    contentSha256=[string]$destination.contentSha256
                })
            }
        }
    }
    foreach($id in $source.Keys){if(-not $reviewed.Contains($id)){$reasons.Add('SourceDispositionMissing')}}
    $unique=@($reasons|Select-Object -Unique)
    return New-ImportResult -Status $(if($unique.Count -eq 0){'valid'}else{'blocked'}) -ReasonCodes $unique `
        -SourceBlockCount $source.Count -UnknownCount $unknownCount -NonReadyCount $nonReadyCount `
        -AcceptedDestinations $acceptedDestinations.ToArray() -AcceptedAttachments $acceptedAttachments.ToArray()
}

Export-ModuleMember -Function Test-ConfluenceImportReview
