# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
Import-Module -Name (Join-Path $PSScriptRoot 'ConfluenceMapping.psm1') -Scope Local
Import-Module -Name (Join-Path $PSScriptRoot 'ConfluenceCodeBinding.psm1') -Scope Local
Import-Module -Name (Join-Path $PSScriptRoot 'ImportReview.psm1') -Scope Local
Import-Module -Name (Join-Path $PSScriptRoot 'StrictJson.psm1') -Scope Local

function New-ValidationResult {
    param([string]$Status,[string[]]$ReasonCodes,[object]$Fields)
    $defaults=[ordered]@{
        status=$Status;reasonCodes=@($ReasonCodes);siteOrigin='';cloudId='';docsCommit='';codeCommit=''
        sourceDigest='';mappingDigest='';mappingWorkingDigest='';reviewDigest='';validatorVersion='';rendererVersion='';sourceMode=''
    }
    if($null -ne $Fields){foreach($key in $Fields.Keys){$defaults[$key]=$Fields[$key]}}
    return [pscustomobject]$defaults
}

function Get-MarkdownGitBlob {
    param([string]$Root,[string]$Commit,[string]$Path)
    if([string]::IsNullOrWhiteSpace($Path) -or $Path -match '[\\\r\n]' -or $Path.StartsWith('/',[StringComparison]::Ordinal) -or
        @($Path -split '/'|Where-Object {$_ -in @('', '.', '..')}).Count -gt 0){return $null}
    $oid=& git -C $Root rev-parse --verify ("${Commit}:$Path") 2>$null
    if($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$oid)){return $null}
    $kind=& git -C $Root cat-file -t $oid 2>$null
    if($LASTEXITCODE -ne 0 -or [string]$kind -cne 'blob'){return $null}
    return [string]$oid
}

function Get-MarkdownReviewDigest {
    param([string[]]$Paths)
    $lines=[System.Collections.Generic.List[string]]::new()
    foreach($path in @($Paths|Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }|Select-Object -Unique|Sort-Object -CaseSensitive)){
        if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return ''}
        $bytes=[IO.File]::ReadAllBytes($path)
        $sha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        $lines.Add([IO.Path]::GetFileName([string]$path)+':'+$sha)
    }
    $content='SYP171/markdown-review/v1'+"`n"+($lines -join "`n")+"`n"
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($content))).ToLowerInvariant()
}

function Test-ConfluenceMappingBytesEquivalent {
    param([byte[]]$CommittedBytes,[byte[]]$WorkingBytes)
    try{
        $committedText=[Text.UTF8Encoding]::new($false,$true).GetString($CommittedBytes)
        $workingText=[Text.UTF8Encoding]::new($false,$true).GetString($WorkingBytes)
    }catch{return $false}
    $committedNormalized=$committedText.Replace("`r`n","`n")
    $workingNormalized=$workingText.Replace("`r`n","`n")
    if($committedNormalized.Contains("`r") -or $workingNormalized.Contains("`r")){return $false}
    return [string]::Equals($committedNormalized,$workingNormalized,[StringComparison]::Ordinal)
}

function Test-ConfluenceCommittedArtifactBytes {
    param([string]$Root,[string]$Commit,[string]$RelativePath,[long]$MaxBytes=4MB)
    $fullPath=Resolve-ReviewRelativePath -Root $Root -Relative $RelativePath
    if($null -eq $fullPath){return $false}
    try{$committed=Get-ConfluenceCommittedBlob -Root $Root -Commit $Commit -Path $RelativePath -MaxBytes $MaxBytes}
    catch{return $false}
    try{
        if(-not(Test-Path -LiteralPath $fullPath -PathType Leaf)){return $false}
        $item=Get-Item -LiteralPath $fullPath -Force
        if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or [long]$item.Length -gt $MaxBytes){return $false}
        $workingBytes=[IO.File]::ReadAllBytes($fullPath)
        if($workingBytes.Length -gt $MaxBytes -or $workingBytes.Length -ne $committed.bytes.Length){return $false}
        $committedHash=[Security.Cryptography.SHA256]::HashData([byte[]]$committed.bytes)
        $workingHash=[Security.Cryptography.SHA256]::HashData([byte[]]$workingBytes)
        return [Security.Cryptography.CryptographicOperations]::FixedTimeEquals($committedHash,$workingHash)
    }catch{return $false}
}

function Invoke-ConfluenceMarkdownValidation {
    param(
        [string]$Root,[string]$MappingPath,[string]$DocsCommit,[string]$CodeBindingPath,[string]$ReviewPath,
        [string]$CodeReviewPath,[string]$MappingDigestSnapshot,[object]$MappingData
    )
    $rootFull=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path)
    $mappingRelative=[IO.Path]::GetRelativePath($rootFull,[IO.Path]::GetFullPath($MappingPath)).Replace([string][IO.Path]::DirectorySeparatorChar,'/')
    $mapping=Test-ConfluenceMapping -Root $rootFull -MappingPath $MappingPath -ExpectedSiteOrigin ([string]$MappingData.siteOrigin)
    if($mapping.status -cne 'valid'){
        return New-ValidationResult -Status 'invalid' -ReasonCodes $mapping.reasonCodes -Fields $null
    }
    if($mapping.mappingSha256 -cne $MappingDigestSnapshot){
        return New-ValidationResult -Status 'blocked' -ReasonCodes @('MappingChangedDuringValidation') -Fields $null
    }
    if($DocsCommit -cnotmatch '^(?:[a-f0-9]{40}|[a-f0-9]{64})$'){
        return New-ValidationResult -Status 'invalid' -ReasonCodes @('CommitUnresolved') -Fields $null
    }
    $resolved=& git -C $rootFull rev-parse --verify ($DocsCommit+'^{commit}') 2>$null
    if($LASTEXITCODE -ne 0 -or [string]$resolved -cne $DocsCommit){
        return New-ValidationResult -Status 'invalid' -ReasonCodes @('CommitUnresolved') -Fields $null
    }
    try{
        $committedMapping=Get-ConfluenceCommittedBlob -Root $rootFull -Commit $DocsCommit -Path $mappingRelative
        $mappingItem=Get-Item -LiteralPath $MappingPath -Force
        if(($mappingItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or [long]$mappingItem.Length -gt 4MB){throw 'MappingWorkingFileInvalid'}
        $workingMappingBytes=[IO.File]::ReadAllBytes($MappingPath)
    }catch{
        return New-ValidationResult -Status 'blocked' -ReasonCodes @('MappingCommitMismatch') -Fields @{docsCommit=$DocsCommit;sourceMode=[string]$MappingData.sourceMode}
    }
    $workingMappingDigest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($workingMappingBytes)).ToLowerInvariant()
    if($workingMappingDigest -cne $MappingDigestSnapshot -or
        -not(Test-ConfluenceMappingBytesEquivalent -CommittedBytes $committedMapping.bytes -WorkingBytes $workingMappingBytes)){
        return New-ValidationResult -Status 'blocked' -ReasonCodes @('MappingCommitMismatch') -Fields @{docsCommit=$DocsCommit;sourceMode=[string]$MappingData.sourceMode}
    }
    $sourcePaths=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $null=$sourcePaths.Add($mappingRelative)
    foreach($entry in @($mapping.entries)){
        $null=$sourcePaths.Add([string]$entry.sourceArtifact)
        foreach($asset in @($entry.assets)){
            $assetPath=[string]$asset.localPath
            $null=$sourcePaths.Add($assetPath)
            if(-not(Test-ConfluenceCommittedArtifactBytes -Root $rootFull -Commit $DocsCommit -RelativePath $assetPath -MaxBytes 20MB)){
                return New-ValidationResult -Status 'blocked' -ReasonCodes @('AttachmentDestinationChanged') -Fields @{
                    docsCommit=$DocsCommit;mappingDigest=$mapping.mappingSha256;sourceMode=[string]$MappingData.sourceMode
                }
            }
        }
    }
    if($MappingData.sourceMode -ceq 'capture-markdown'){
        $rawCaptureLimits=[System.Collections.Generic.Dictionary[string,long]]::new([StringComparer]::Ordinal)
        if([string]::IsNullOrWhiteSpace($ReviewPath) -or -not(Test-Path -LiteralPath $ReviewPath -PathType Leaf)){
            return New-ValidationResult -Status 'blocked' -ReasonCodes @('ImportReviewRequired') -Fields @{
                siteOrigin=[string]$MappingData.siteOrigin;cloudId=[string]$MappingData.cloudId;docsCommit=$DocsCommit
                mappingDigest=$mapping.mappingSha256;sourceMode=[string]$MappingData.sourceMode
            }
        }
        try{$dossier=Read-Syp171StrictJsonFile -Path $ReviewPath -Depth 15}catch{$dossier=$null}
        if($null -eq $dossier -or -not(Test-Syp171JsonKeys -Value $dossier -Expected @('schemaVersion','capturePath','importReviewPath')) -or
            $dossier.schemaVersion -ne 2){
            return New-ValidationResult -Status 'invalid' -ReasonCodes @('ReviewDossierInvalid') -Fields @{sourceMode=[string]$MappingData.sourceMode}
        }
        $reviewRelative=[IO.Path]::GetRelativePath($rootFull,[IO.Path]::GetFullPath($ReviewPath)).Replace([string][IO.Path]::DirectorySeparatorChar,'/')
        if(-not(Test-SourceAtCommit -Root $rootFull -Commit $DocsCommit -SourcePaths @($reviewRelative))){
            return New-ValidationResult -Status 'blocked' -ReasonCodes @('ReviewSourceChanged') -Fields @{sourceMode=[string]$MappingData.sourceMode}
        }
        $capturePath=Resolve-ReviewRelativePath -Root $rootFull -Relative ([string]$dossier.capturePath)
        $importReviewPath=Resolve-ReviewRelativePath -Root $rootFull -Relative ([string]$dossier.importReviewPath)
        if($null -eq $capturePath -or $null -eq $importReviewPath){
            return New-ValidationResult -Status 'invalid' -ReasonCodes @('ReviewReferenceInvalid') -Fields @{sourceMode=[string]$MappingData.sourceMode}
        }
        $captureRelative=[IO.Path]::GetRelativePath($rootFull,$capturePath).Replace([string][IO.Path]::DirectorySeparatorChar,'/')
        $importRelative=[IO.Path]::GetRelativePath($rootFull,$importReviewPath).Replace([string][IO.Path]::DirectorySeparatorChar,'/')
        foreach($rawMetadataPath in @($reviewRelative,$captureRelative,$importRelative)){$rawCaptureLimits[$rawMetadataPath]=4MB}
        if(-not(Test-SourceAtCommit -Root $rootFull -Commit $DocsCommit -SourcePaths @($captureRelative,$importRelative))){
            return New-ValidationResult -Status 'blocked' -ReasonCodes @('ReviewSourceChanged') -Fields @{sourceMode=[string]$MappingData.sourceMode}
        }
        $import=Test-ConfluenceImportReview -CapturePath $capturePath -ReviewPath $importReviewPath
        if($import.status -cne 'valid'){
            return New-ValidationResult -Status 'blocked' -ReasonCodes $import.reasonCodes -Fields @{
                siteOrigin=[string]$MappingData.siteOrigin;cloudId=[string]$MappingData.cloudId;docsCommit=$DocsCommit
                mappingDigest=$mapping.mappingSha256;sourceMode=[string]$MappingData.sourceMode
            }
        }
        if([int]$import.nonReadyCount -gt 0){
            return New-ValidationResult -Status 'blocked' -ReasonCodes @('ImportDispositionNotReady') -Fields @{
                siteOrigin=[string]$MappingData.siteOrigin;cloudId=[string]$MappingData.cloudId;docsCommit=$DocsCommit
                mappingDigest=$mapping.mappingSha256;sourceMode=[string]$MappingData.sourceMode
            }
        }
        try{$capture=Read-Syp171StrictJsonFile -Path $capturePath -Depth 20}catch{$capture=$null}
        if($null -eq $capture -or $capture.siteOrigin -cne [string]$MappingData.siteOrigin -or
            (($capture.Keys -contains 'cloudId') -and [string]$capture.cloudId -cne [string]$MappingData.cloudId)){
            return New-ValidationResult -Status 'blocked' -ReasonCodes @('TenantMismatch') -Fields @{sourceMode=[string]$MappingData.sourceMode}
        }
        $acceptedDestinations=@($import.acceptedDestinations)
        foreach($destination in $acceptedDestinations){
            $destinationEntry=@($mapping.entries|Where-Object {
                [string]$_.sourceArtifact -ceq [string]$destination.sourceArtifact -and
                [string]$_.sourceSectionId -ceq [string]$destination.sourceSectionId
            })
            if($destinationEntry.Count -ne 1){
                return New-ValidationResult -Status 'blocked' -ReasonCodes @('DispositionDestinationMismatch') -Fields @{sourceMode=[string]$MappingData.sourceMode}
            }
            try{$destinationBlob=Get-ConfluenceCommittedBlob -Root $rootFull -Commit $DocsCommit -Path ([string]$destination.sourceArtifact)}
            catch{return New-ValidationResult -Status 'blocked' -ReasonCodes @('DispositionDestinationChanged') -Fields @{sourceMode=[string]$MappingData.sourceMode}}
            $destinationHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$destinationBlob.bytes)).ToLowerInvariant()
            if($destinationHash -cne [string]$destination.contentSha256){
                return New-ValidationResult -Status 'blocked' -ReasonCodes @('DispositionDestinationChanged') -Fields @{sourceMode=[string]$MappingData.sourceMode}
            }
        }
        $acceptedAttachments=@($import.acceptedAttachments)
        $mappedAttachments=[System.Collections.Generic.List[object]]::new()
        foreach($entry in @($mapping.entries)){
            foreach($asset in @($entry.assets)){
                $matches=@($acceptedAttachments|Where-Object {
                    [string]$_.localPath -ceq [string]$asset.localPath -and
                    [string]$_.displayFilename -ceq [string]$asset.displayFilename -and
                    [string]$_.mediaType -ceq [string]$asset.mediaType -and
                    [string]$_.sha256 -ceq [string]$asset.sha256
                })
                if($matches.Count -ne 1){
                    return New-ValidationResult -Status 'blocked' -ReasonCodes @('AttachmentDispositionMismatch') -Fields @{sourceMode=[string]$MappingData.sourceMode}
                }
                try{$assetBlob=Get-ConfluenceCommittedBlob -Root $rootFull -Commit $DocsCommit -Path ([string]$asset.localPath) -MaxBytes 20MB}
                catch{return New-ValidationResult -Status 'blocked' -ReasonCodes @('AttachmentDestinationChanged') -Fields @{sourceMode=[string]$MappingData.sourceMode}}
                $assetHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$assetBlob.bytes)).ToLowerInvariant()
                if($assetHash -cne [string]$asset.sha256 -or [long]$assetBlob.bytes.Length -ne [long]$matches[0].byteLength){
                    return New-ValidationResult -Status 'blocked' -ReasonCodes @('AttachmentDestinationChanged') -Fields @{sourceMode=[string]$MappingData.sourceMode}
                }
                $mappedAttachments.Add($matches[0])
            }
        }
        foreach($attachment in $acceptedAttachments){
            if(@($mappedAttachments|Where-Object {
                [string]$_.pageId -ceq [string]$attachment.pageId -and [string]$_.attachmentId -ceq [string]$attachment.attachmentId
            }).Count -ne 1){
                return New-ValidationResult -Status 'blocked' -ReasonCodes @('AttachmentDispositionMismatch') -Fields @{sourceMode=[string]$MappingData.sourceMode}
            }
        }
        foreach($entry in @($mapping.entries)){
            $approved=@($acceptedDestinations|Where-Object {
                [string]$_.sourceArtifact -ceq [string]$entry.sourceArtifact -and
                [string]$_.sourceSectionId -ceq [string]$entry.sourceSectionId
            })
            if($approved.Count -eq 0){
                return New-ValidationResult -Status 'blocked' -ReasonCodes @('DispositionDestinationMismatch') -Fields @{sourceMode=[string]$MappingData.sourceMode}
            }
        }
        $null=$sourcePaths.Add($reviewRelative);$null=$sourcePaths.Add($captureRelative);$null=$sourcePaths.Add($importRelative)
        foreach($page in @($capture.pages)){
            foreach($relativeArtifact in @($page.snapshotPath,$page.candidatePath)){
                if([string]::IsNullOrWhiteSpace([string]$relativeArtifact)){continue}
                $artifactFull=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($capturePath)) ([string]$relativeArtifact)))
                $artifactRelative=[IO.Path]::GetRelativePath($rootFull,$artifactFull).Replace([string][IO.Path]::DirectorySeparatorChar,'/')
                if($null -eq (Resolve-ReviewRelativePath -Root $rootFull -Relative $artifactRelative)){
                    return New-ValidationResult -Status 'invalid' -ReasonCodes @('CaptureArtifactInvalid') -Fields @{sourceMode=[string]$MappingData.sourceMode}
                }
                $null=$sourcePaths.Add($artifactRelative)
                $rawCaptureLimits[$artifactRelative]=4MB
            }
            foreach($attachment in @($page.attachments)){
                $relativeArtifact=[string]$attachment.assetPath
                if([string]::IsNullOrWhiteSpace($relativeArtifact)){continue}
                $artifactFull=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($capturePath)) $relativeArtifact))
                $artifactRelative=[IO.Path]::GetRelativePath($rootFull,$artifactFull).Replace([string][IO.Path]::DirectorySeparatorChar,'/')
                if($null -eq (Resolve-ReviewRelativePath -Root $rootFull -Relative $artifactRelative)){
                    return New-ValidationResult -Status 'invalid' -ReasonCodes @('CaptureArtifactInvalid') -Fields @{sourceMode=[string]$MappingData.sourceMode}
                }
                $null=$sourcePaths.Add($artifactRelative)
                if($rawCaptureLimits.ContainsKey($artifactRelative)){$rawCaptureLimits[$artifactRelative]=[Math]::Min($rawCaptureLimits[$artifactRelative],20MB)}
                else{$rawCaptureLimits[$artifactRelative]=20MB}
            }
        }
        foreach($rawArtifactPath in $rawCaptureLimits.Keys){
            if(-not(Test-ConfluenceCommittedArtifactBytes -Root $rootFull -Commit $DocsCommit -RelativePath $rawArtifactPath -MaxBytes $rawCaptureLimits[$rawArtifactPath])){
                return New-ValidationResult -Status 'blocked' -ReasonCodes @('CaptureArtifactBytesChanged') -Fields @{docsCommit=$DocsCommit;sourceMode=[string]$MappingData.sourceMode}
            }
        }
    }
    $paths=@($sourcePaths|Sort-Object -CaseSensitive)
    $codeCurrent=@($mapping.entries|Where-Object {$_.contentKind -ceq 'code-current'})
    $binding=$null
    if($codeCurrent.Count -gt 0){
        if([string]::IsNullOrWhiteSpace($CodeBindingPath) -or -not(Test-Path -LiteralPath $CodeBindingPath -PathType Leaf) -or
            [string]::IsNullOrWhiteSpace($CodeReviewPath) -or -not(Test-Path -LiteralPath $CodeReviewPath -PathType Leaf)){
            return New-ValidationResult -Status 'blocked' -ReasonCodes @('CodeCurrentEvidenceRequired') -Fields @{
                siteOrigin=[string]$MappingData.siteOrigin;cloudId=[string]$MappingData.cloudId;docsCommit=$DocsCommit
                mappingDigest=$mapping.mappingSha256;sourceMode=[string]$MappingData.sourceMode
            }
        }
        $binding=Resolve-ConfluenceMarkdownCodeBinding -Root $rootFull -BindingPath $CodeBindingPath -ReviewPath $CodeReviewPath `
            -DocsCommit $DocsCommit -RequiredDocsSourcePaths $paths
        if($binding.status -cne 'valid'){
            return New-ValidationResult -Status 'blocked' -ReasonCodes $binding.reasonCodes -Fields @{
                siteOrigin=[string]$MappingData.siteOrigin;cloudId=[string]$MappingData.cloudId;docsCommit=$DocsCommit
                mappingDigest=$mapping.mappingSha256;sourceMode=[string]$MappingData.sourceMode
            }
        }
        if(@($binding.docsSourcePaths|Where-Object {$_ -cnotin $paths}).Count -gt 0){
            return New-ValidationResult -Status 'blocked' -ReasonCodes @('BoundSourceIncomplete') -Fields @{sourceMode=[string]$MappingData.sourceMode}
        }
    }
    if(-not(Test-SourceAtCommit -Root $rootFull -Commit $DocsCommit -SourcePaths $paths)){
        return New-ValidationResult -Status 'blocked' -ReasonCodes @('CommittedSourceChanged') -Fields @{docsCommit=$DocsCommit;sourceMode=[string]$MappingData.sourceMode}
    }
    Import-Module -Name (Join-Path $PSScriptRoot 'MarkdownProjection.psm1') -Scope Local
    $fileRecords=[System.Collections.Generic.List[string]]::new()
    foreach($path in $paths){
        $oid=Get-MarkdownGitBlob -Root $rootFull -Commit $DocsCommit -Path $path
        if($null -eq $oid){return New-ValidationResult -Status 'blocked' -ReasonCodes @('CommittedSourceChanged') -Fields @{docsCommit=$DocsCommit;sourceMode=[string]$MappingData.sourceMode}}
        $fileRecords.Add($path+':'+$oid)
    }
    $sourceDigest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($fileRecords -join "`n")+"`n"))).ToLowerInvariant()
    $committedMappingDigest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$committedMapping.bytes)).ToLowerInvariant()
    foreach($entry in @($mapping.entries)){
        $path=[IO.Path]::GetFullPath((Join-Path $rootFull ([string]$entry.sourceArtifact)))
        try{
            $bytes=[IO.File]::ReadAllBytes($path)
            if($bytes.Length -gt 4MB){throw 'Source too large.'}
            $markdown=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)
        }catch{return New-ValidationResult -Status 'invalid' -ReasonCodes @('MarkdownSourceInvalid') -Fields @{sourceMode=[string]$MappingData.sourceMode}}
        $projection=ConvertTo-ConfluenceMarkdownStorage -Markdown $markdown -Root $rootFull -SourcePath ([string]$entry.sourceArtifact) `
            -ProjectionId ([string]$entry.projectionId) -ManagedAssets @($entry.assets) -LinkBindings @($entry.linkBindings) `
            -PageMappings @($mapping.entries) -SiteOrigin ([string]$MappingData.siteOrigin)
        if($projection.status -notin @('supported','deferred')){
            return New-ValidationResult -Status 'blocked' -ReasonCodes @($projection.reasonCodes) -Fields @{
                docsCommit=$DocsCommit;sourceDigest=$sourceDigest;mappingDigest=$mapping.mappingSha256
                siteOrigin=[string]$MappingData.siteOrigin;cloudId=[string]$MappingData.cloudId;sourceMode=[string]$MappingData.sourceMode
            }
        }
    }
    if(-not(Test-SourceAtCommit -Root $rootFull -Commit $DocsCommit -SourcePaths $paths)){
        return New-ValidationResult -Status 'blocked' -ReasonCodes @('SourceChangedDuringValidation') -Fields @{docsCommit=$DocsCommit;sourceMode=[string]$MappingData.sourceMode}
    }
    $currentMappingBytes=[IO.File]::ReadAllBytes([IO.Path]::GetFullPath((Resolve-Path -LiteralPath $MappingPath).Path))
    $currentMappingDigest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($currentMappingBytes)).ToLowerInvariant()
    if($currentMappingDigest -cne $MappingDigestSnapshot){
        return New-ValidationResult -Status 'blocked' -ReasonCodes @('MappingChangedDuringValidation') -Fields @{sourceMode=[string]$MappingData.sourceMode}
    }
    $reviewPaths=[System.Collections.Generic.List[string]]::new()
    if($MappingData.sourceMode -ceq 'capture-markdown'){$reviewPaths.AddRange([string[]]@($ReviewPath,$capturePath,$importReviewPath))}
    if($null -ne $binding){
        $reviewPaths.Add($CodeBindingPath);$reviewPaths.Add($CodeReviewPath)
    }
    $reviewDigest=''
    if($reviewPaths.Count -gt 0){$reviewDigest=Get-MarkdownReviewDigest -Paths $reviewPaths.ToArray()}
    if($null -ne $binding){
        $currentBinding=Resolve-ConfluenceMarkdownCodeBinding -Root $rootFull -BindingPath $CodeBindingPath -ReviewPath $CodeReviewPath `
            -DocsCommit $DocsCommit -RequiredDocsSourcePaths $paths
        if($currentBinding.status -cne 'valid' -or $currentBinding.bindingSha256 -cne $binding.bindingSha256 -or
            $currentBinding.reviewSha256 -cne $binding.reviewSha256 -or $currentBinding.docsCommit -cne $binding.docsCommit -or
            $currentBinding.codeCommit -cne $binding.codeCommit -or $currentBinding.sourceDigest -cne $binding.sourceDigest -or
            (@($currentBinding.docsSourcePaths) -join "`n") -cne (@($binding.docsSourcePaths) -join "`n") -or
            (@($currentBinding.codeRelevantPaths) -join "`n") -cne (@($binding.codeRelevantPaths) -join "`n")){
            return New-ValidationResult -Status 'blocked' -ReasonCodes @('CodeReviewChangedDuringValidation') -Fields @{sourceMode=[string]$MappingData.sourceMode}
        }
    }
    $boundSourceDigest=if($null -ne $binding){$binding.sourceDigest}else{''}
    $combinedSourceDigest=if($boundSourceDigest){
        $seed='SYP171/markdown-source/v1'+"`n"+$sourceDigest+"`n"+$binding.sourceDigest+"`n"+$binding.codeCommit+"`n"
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($seed))).ToLowerInvariant()
    }else{$sourceDigest}
    return New-ValidationResult -Status 'valid' -ReasonCodes @() -Fields @{
        siteOrigin=[string]$MappingData.siteOrigin;cloudId=[string]$MappingData.cloudId;docsCommit=$DocsCommit
        codeCommit=$(if($null -ne $binding){$binding.codeCommit}else{''});sourceDigest=$combinedSourceDigest
        mappingDigest=$committedMappingDigest;mappingWorkingDigest=$mapping.mappingSha256;reviewDigest=$reviewDigest
        validatorVersion='powershell-markdown-v1';rendererVersion='powershell-markdown-v1';sourceMode=[string]$MappingData.sourceMode
    }
}

function Resolve-ReviewRelativePath {
    param([string]$Root,[string]$Relative)
    if([string]::IsNullOrWhiteSpace($Relative) -or $Relative -match '[\\\r\n]' -or $Relative.StartsWith('/',[StringComparison]::Ordinal) -or $Relative -match '^[A-Za-z]:'){
        return $null
    }
    foreach($part in ($Relative -split '/')){if($part -in @('', '.', '..')){return $null}}
    $full=[IO.Path]::GetFullPath((Join-Path $Root $Relative))
    $fromRoot=[IO.Path]::GetRelativePath([IO.Path]::GetFullPath($Root),$full)
    if($fromRoot -eq '..' -or $fromRoot.StartsWith(('..' + [IO.Path]::DirectorySeparatorChar),[StringComparison]::Ordinal) -or
        -not(Test-Path -LiteralPath $full -PathType Leaf)){return $null}
    $rootFull=[IO.Path]::GetFullPath($Root)
    $current=$full
    while($current -ne $rootFull){
        $item=Get-Item -LiteralPath $current -Force
        if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){return $null}
        $current=[IO.Path]::GetDirectoryName($current)
        if([string]::IsNullOrWhiteSpace($current)){return $null}
    }
    return $full
}

function Test-SourceAtCommit {
    param([string]$Root,[string]$Commit,[string[]]$SourcePaths)
    if($Commit -cnotmatch '^(?:[a-f0-9]{40}|[a-f0-9]{64})$'){return $false}
    $resolved=& git -C $Root rev-parse --verify ($Commit + '^{commit}') 2>$null
    if($LASTEXITCODE -ne 0 -or [string]$resolved -cne $Commit){return $false}
    foreach($path in $SourcePaths){
        if($path -match '[\\\r\n]' -or $path -match '(?:^|/)\.\.(?:/|$)'){return $false}
        & git -C $Root ls-files --error-unmatch -- $path 1>$null 2>$null
        if($LASTEXITCODE -ne 0){return $false}
        $blob=& git -C $Root rev-parse --verify ([string]($Commit) + ':' + [string]($path)) 2>$null
        if($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$blob)){return $false}
        & git -C $Root diff --quiet --no-ext-diff $Commit -- $path 1>$null 2>$null
        if($LASTEXITCODE -ne 0){return $false}
    }
    return $true
}

function Invoke-ConfluenceValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$MappingPath,
        [Parameter(Mandatory)][string]$DocsCommit,
        [string]$CodeBindingPath,
        [string]$ReviewPath,
        [string]$CodeReviewPath
    )
    if(-not(Test-Path -LiteralPath $Root -PathType Container)){
        return New-ValidationResult -Status 'invalid' -ReasonCodes @('ValidationInputUnavailable') -Fields $null
    }
    $rootFull=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path)
    $mappingRelative=[IO.Path]::GetRelativePath($rootFull,[IO.Path]::GetFullPath($MappingPath)).Replace([string][IO.Path]::DirectorySeparatorChar,'/')
    $mappingFull=Resolve-ReviewRelativePath -Root $rootFull -Relative $mappingRelative
    if($null -eq $mappingFull){return New-ValidationResult -Status 'invalid' -ReasonCodes @('MappingPathInvalid') -Fields $null}
    try{
        $mappingBytes=[IO.File]::ReadAllBytes($mappingFull)
        if($mappingBytes.Length -eq 0 -or $mappingBytes.Length -gt 4MB){throw 'MappingSizeInvalid'}
        $mappingText=[Text.UTF8Encoding]::new($false,$true).GetString($mappingBytes)
        $mappingData=ConvertFrom-Syp171StrictJson -Json $mappingText -Depth 30
        $mappingDigestSnapshot=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($mappingBytes)).ToLowerInvariant()
    }catch{return New-ValidationResult -Status 'invalid' -ReasonCodes @('MappingSchemaInvalid') -Fields $null}
    if($mappingData -isnot [System.Collections.IDictionary] -or $mappingData.schemaVersion -ne 4){
        $unsupportedVersion=$mappingData -is [System.Collections.IDictionary] -and $mappingData.schemaVersion -in @(1,2,3)
        $reason=if($unsupportedVersion){'MappingContractUnsupported'}else{'MappingSchemaInvalid'}
        return New-ValidationResult -Status 'invalid' -ReasonCodes @($reason) -Fields $null
    }
    return Invoke-ConfluenceMarkdownValidation -Root $rootFull -MappingPath $mappingFull -DocsCommit $DocsCommit `
        -CodeBindingPath $CodeBindingPath -ReviewPath $ReviewPath -CodeReviewPath $CodeReviewPath `
        -MappingDigestSnapshot $mappingDigestSnapshot -MappingData $mappingData
}

Export-ModuleMember -Function Invoke-ConfluenceValidation
