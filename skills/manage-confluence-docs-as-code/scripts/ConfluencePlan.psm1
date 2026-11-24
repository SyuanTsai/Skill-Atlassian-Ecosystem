# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
Import-Module -Name (Join-Path $PSScriptRoot 'ConfluenceTransport.psm1') -Scope Local
Import-Module -Name (Join-Path $PSScriptRoot 'ConfluenceAssets.psm1') -Scope Local
Import-Module -Name (Join-Path $PSScriptRoot 'StrictJson.psm1') -Scope Local
Import-Module -Name (Join-Path $PSScriptRoot 'ConfluenceStorage.psm1') -Scope Local
Import-Module -Name (Join-Path $PSScriptRoot 'ConfluenceMapping.psm1') -Scope Local

function New-PlanResult {
    param([string]$Status,[string[]]$ReasonCodes,[string]$PlanPath,[string]$PlanSha256,[object[]]$Blockers=@(),[object[]]$Disclosures=@())
    return [pscustomobject]@{status=$Status;reasonCodes=@($ReasonCodes);planPath=$PlanPath;planSha256=$PlanSha256;blockers=@($Blockers);disclosures=@($Disclosures)}
}

function New-ConfluenceScopeBlocker {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectionId,[Parameter(Mandatory)][string[]]$ReasonCodes,[string[]]$LinkTargets=@(),
        [AllowEmptyString()][string]$PageId='',[System.Collections.IDictionary]$Details=[ordered]@{})
    $targets=[System.Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    foreach($target in @($LinkTargets)){if(-not [string]::IsNullOrEmpty($target)){$null=$targets.Add($target)}}
    return [pscustomobject][ordered]@{projectionId=$ProjectionId;pageId=$PageId;reasonCodes=@($ReasonCodes);linkTargets=@($targets);details=$Details}
}

function Get-ConfluenceSortedScopeBlockers {
    param([System.Collections.Generic.List[object]]$Blockers)
    $Blockers.Sort([Comparison[object]]{param($left,$right)[string]::CompareOrdinal([string]$left.projectionId,[string]$right.projectionId)})
    return @($Blockers.ToArray())
}

function Get-ConfluenceDraftScopeBlockers {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Payloads)
    $blockers=[System.Collections.Generic.List[object]]::new()
    foreach($payload in $Payloads){
        $codes=[System.Collections.Generic.List[string]]::new()
        if([string]$payload.pageId -eq ''){$codes.Add('PageIdMissing')}
        $targets=[System.Collections.Generic.List[string]]::new()
        if(Test-PlanDeferredProperty -Payload $payload){foreach($target in @($payload.deferredTargets)){$targets.Add([string]$target)}}
        foreach($match in [regex]::Matches([string]$payload.bodyStorage,'__SYP171_LINK_([a-z][a-z0-9-]{0,49})__')){$targets.Add($match.Groups[1].Value)}
        if($targets.Count -gt 0){$codes.Add('LinkTargetPageIdMissing')}
        if($codes.Count -gt 0){
            $blockers.Add((New-ConfluenceScopeBlocker -ProjectionId ([string]$payload.projectionId) -PageId ([string]$payload.pageId) -ReasonCodes $codes.ToArray() -LinkTargets $targets.ToArray()))
        }
    }
    return Get-ConfluenceSortedScopeBlockers -Blockers $blockers
}

function New-ConfluenceProjectionScopeRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entries,[Parameter(Mandatory)][AllowEmptyCollection()][AllowNull()][string[]]$ProjectionIds)
    $requested=@($ProjectionIds)
    if($requested.Count -eq 0 -or $requested.Count -gt 100){return $null}
    $scope=[System.Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    foreach($id in $requested){
        if([string]$id -cnotmatch '^[a-z][a-z0-9-]{0,49}$' -or -not $scope.Add([string]$id)){return $null}
    }
    $entriesById=[System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach($entry in $Entries){
        if(-not $entriesById.TryAdd([string]$entry.projectionId,$entry)){return $null}
    }
    foreach($id in $scope){if(-not $entriesById.ContainsKey($id)){return $null}}
    $excluded=[System.Collections.Generic.List[object]]::new()
    foreach($id in [System.Collections.Generic.SortedSet[string]]::new([string[]]@($entriesById.Keys),[StringComparer]::Ordinal)){
        if($scope.Contains($id)){continue}
        $codes=@('ExcludedByProjectionScope')
        if([string]$entriesById[$id].pageId -eq ''){$codes+='PageIdMissing'}
        $excluded.Add([ordered]@{projectionId=$id;reasonCodes=@($codes)})
    }
    return [ordered]@{projectionIds=@($scope);excludedEntries=@($excluded.ToArray())}
}

function Get-ConfluenceProjectionScopeKey {
    param([object]$Scope)
    $excluded=@($Scope.excludedEntries|ForEach-Object {([string]$_.projectionId)+'='+(@($_.reasonCodes)-join '+')})
    return (@($Scope.projectionIds)-join ',')+'|'+($excluded-join ',')
}

function Test-ConfluenceProjectionScopeShape {
    param([object]$Scope,[object[]]$Pages)
    if(-not(Test-Syp171JsonKeys -Value $Scope -Expected @('projectionIds','excludedEntries')) -or
        $Scope.projectionIds -isnot [array] -or $Scope.excludedEntries -isnot [array]){return $false}
    $ids=@($Scope.projectionIds)
    $excluded=@($Scope.excludedEntries)
    if($ids.Count -eq 0 -or ($ids.Count + $excluded.Count) -gt 100){return $false}
    $previous=$null
    $all=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($id in $ids){
        if($id -isnot [string] -or $id -cnotmatch '^[a-z][a-z0-9-]{0,49}$' -or
            ($null -ne $previous -and [string]::CompareOrdinal($previous,$id) -ge 0) -or -not $all.Add($id)){return $false}
        $previous=$id
    }
    $previous=$null
    foreach($entry in $excluded){
        if(-not(Test-Syp171JsonKeys -Value $entry -Expected @('projectionId','reasonCodes')) -or
            $entry.projectionId -isnot [string] -or [string]$entry.projectionId -cnotmatch '^[a-z][a-z0-9-]{0,49}$' -or
            ($null -ne $previous -and [string]::CompareOrdinal($previous,[string]$entry.projectionId) -ge 0) -or
            -not $all.Add([string]$entry.projectionId) -or $entry.reasonCodes -isnot [array] -or
            (@($entry.reasonCodes)-join ',') -cnotin @('ExcludedByProjectionScope','ExcludedByProjectionScope,PageIdMissing')){return $false}
        $previous=[string]$entry.projectionId
    }
    $pageIds=@($Pages|ForEach-Object {[string]$_.projectionId})
    [Array]::Sort($pageIds,[StringComparer]::Ordinal)
    return ($pageIds-join ',') -ceq ($ids-join ',')
}

function Get-PlanCurrentMappingEntries {
    param([object]$Plan,[object]$Validation)
    $inputs=$Plan.validationInputs
    if($inputs -isnot [System.Collections.IDictionary] -or -not $inputs.Contains('root') -or -not $inputs.Contains('mappingPath')){return $null}
    $mapping=Test-ConfluenceMapping -Root ([string]$inputs.root) -MappingPath ([string]$inputs.mappingPath) -ExpectedSiteOrigin ([string]$Plan.siteOrigin)
    if($mapping.status -cne 'valid' -or [string]$mapping.mappingSha256 -cne [string]$Validation.mappingWorkingDigest){return $null}
    return ,@($mapping.entries)
}

function New-ConfluenceDraftLinkPolicyRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entries,[Parameter(Mandatory)][AllowEmptyCollection()][AllowNull()][string[]]$ProjectionIds)
    $requested=@($ProjectionIds)
    if($requested.Count -eq 0 -or $requested.Count -gt 100){return $null}
    $ids=[System.Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    foreach($id in $requested){if([string]$id -cnotmatch '^[a-z][a-z0-9-]{0,49}$' -or -not $ids.Add([string]$id)){return $null}}
    $byId=[System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach($entry in $Entries){if(-not $byId.TryAdd([string]$entry.projectionId,$entry)){return $null}}
    $targets=[System.Collections.Generic.List[object]]::new()
    foreach($id in $ids){
        $entry=$null
        if(-not $byId.TryGetValue($id,[ref]$entry) -or [string]$entry.pageId -cnotmatch '^[0-9]+$'){return $null}
        $targets.Add([ordered]@{projectionId=$id;pageId=[string]$entry.pageId})
    }
    return [ordered]@{draftEditorTargets=@($targets.ToArray())}
}

function Get-ConfluenceDraftLinkPolicyKey {
    param([object]$Policy)
    return (@($Policy.draftEditorTargets|ForEach-Object {([string]$_.projectionId)+'='+([string]$_.pageId)})-join ',')
}

function Test-ConfluenceDraftLinkPolicyShape {
    param([object]$Policy)
    if(-not(Test-Syp171JsonKeys -Value $Policy -Expected @('draftEditorTargets')) -or $Policy.draftEditorTargets -isnot [array]){return $false}
    $targets=@($Policy.draftEditorTargets)
    if($targets.Count -eq 0 -or $targets.Count -gt 100){return $false}
    $previous=$null
    foreach($target in $targets){
        if(-not(Test-Syp171JsonKeys -Value $target -Expected @('projectionId','pageId')) -or
            $target.projectionId -isnot [string] -or $target.projectionId -cnotmatch '^[a-z][a-z0-9-]{0,49}$' -or
            $target.pageId -isnot [string] -or $target.pageId -cnotmatch '^[0-9]+$' -or
            ($null -ne $previous -and [string]::CompareOrdinal($previous,$target.projectionId) -ge 0)){return $false}
        $previous=$target.projectionId
    }
    return $true
}

function Test-ConfluencePlanDraftLinkPolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Plan,[Parameter(Mandatory)][object]$Validation)
    if($Plan -isnot [System.Collections.IDictionary] -or -not $Plan.Contains('draftLinkPolicy')){return $true}
    try{
        if($Plan.publishMode -cne 'draft'){return $false}
        $entries=Get-PlanCurrentMappingEntries -Plan $Plan -Validation $Validation
        if($null -eq $entries){return $false}
        $expected=New-ConfluenceDraftLinkPolicyRecord -Entries $entries -ProjectionIds ([string[]]@($Plan.draftLinkPolicy.draftEditorTargets|ForEach-Object {[string]$_.projectionId}))
        if($null -eq $expected){return $false}
        return (Get-ConfluenceDraftLinkPolicyKey -Policy $expected) -ceq (Get-ConfluenceDraftLinkPolicyKey -Policy $Plan.draftLinkPolicy)
    }catch{return $false}
}

function Test-ConfluencePlanProjectionScope {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Plan,[Parameter(Mandatory)][object]$Validation)
    if($Plan -isnot [System.Collections.IDictionary] -or -not $Plan.Contains('projectionScope')){return $true}
    try{
        $entries=Get-PlanCurrentMappingEntries -Plan $Plan -Validation $Validation
        if($null -eq $entries){return $false}
        $expected=New-ConfluenceProjectionScopeRecord -Entries $entries -ProjectionIds ([string[]]@($Plan.projectionScope.projectionIds))
        if($null -eq $expected){return $false}
        return (Get-ConfluenceProjectionScopeKey -Scope $expected) -ceq (Get-ConfluenceProjectionScopeKey -Scope $Plan.projectionScope)
    }catch{return $false}
}

function Get-PlanStorageAssetReferences {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Storage)
    try {
        if([Text.Encoding]::UTF8.GetByteCount($Storage) -gt 4MB){throw 'StorageTooLarge'}
        $settings=[Xml.XmlReaderSettings]::new()
        $settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver=$null
        $settings.MaxCharactersInDocument=4MB
        $document=[Xml.XmlDocument]::new()
        $document.XmlResolver=$null
        $stringReader=[IO.StringReader]::new('<root xmlns:ac="http://atlassian.com/content" xmlns:ri="http://atlassian.com/resource/identifier">'+$Storage+'</root>')
        $reader=[Xml.XmlReader]::Create($stringReader,$settings)
        try{$document.Load($reader)}finally{$reader.Dispose();$stringReader.Dispose()}
        $all=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $mermaid=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach($attachment in $document.SelectNodes('//*[local-name()="attachment" and namespace-uri()="http://atlassian.com/resource/identifier"]')){
            $filename=$attachment.GetAttribute('filename','http://atlassian.com/resource/identifier')
            if([string]::IsNullOrWhiteSpace($filename)){throw 'AssetReferenceInvalid'}
            $null=$all.Add($filename)
        }
        foreach($macro in $document.SelectNodes('//*[local-name()="structured-macro" and namespace-uri()="http://atlassian.com/content" and @*[local-name()="name" and namespace-uri()="http://atlassian.com/content"]="mermaid-cloud"]')){
            $parameters=@($macro.ChildNodes|Where-Object{
                $_.NodeType -eq [Xml.XmlNodeType]::Element -and $_.LocalName -ceq 'parameter' -and
                $_.NamespaceURI -ceq 'http://atlassian.com/content' -and
                $_.GetAttribute('name','http://atlassian.com/content') -ceq 'filename'
            })
            if($parameters.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$parameters[0].InnerText)){throw 'AssetReferenceInvalid'}
            $filename=[string]$parameters[0].InnerText
            $null=$all.Add($filename);$null=$mermaid.Add($filename)
        }
        return [pscustomobject]@{status='valid';names=$all;mermaidNames=$mermaid}
    } catch {return [pscustomobject]@{status='invalid';names=$null;mermaidNames=$null}}
}

function Test-ConfluencePlanPathReparsePoint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if([string]::IsNullOrWhiteSpace($Path)){return $false}
    $full=[IO.Path]::GetFullPath($Path)
    $root=[IO.Path]::GetPathRoot($full)
    if([string]::IsNullOrWhiteSpace($root)){return $false}
    $current=$root
    $remainder=$full.Substring($root.Length)
    $components=@($remainder.Split([char[]]@([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar),[StringSplitOptions]::RemoveEmptyEntries))
    foreach($component in $components){
        $current=[IO.Path]::Combine($current,$component)
        $item=$null
        try{$item=Get-Item -LiteralPath $current -Force -ErrorAction Stop}catch{$item=$null}
        if($null -ne $item -and
            (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
             ($null -ne $item.PSObject.Properties['LinkTarget'] -and -not [string]::IsNullOrEmpty([string]$item.LinkTarget)))){
            return $true
        }
        if($null -eq $item){
            foreach($metadata in @([IO.FileInfo]::new($current),[IO.DirectoryInfo]::new($current))){
                try{
                    if(-not [string]::IsNullOrEmpty([string]$metadata.LinkTarget)){return $true}
                }catch{}
            }
            break
        }
    }
    return $false
}

function Test-ConfluencePlanSafeAssetRelativePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if([string]::IsNullOrWhiteSpace($Path) -or $Path -match '[\\\r\n]' -or
        $Path.StartsWith('/',[StringComparison]::Ordinal) -or $Path -match '^[A-Za-z]:' -or
        @($Path -split '/'|Where-Object {$_ -in @('', '.', '..')}).Count -gt 0){return $false}
    return $true
}

function Test-ConfluencePlanShape {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Plan)
    if($Plan -is [System.Collections.IDictionary] -and $Plan.schemaVersion -eq 5 -and
        $Plan.Contains('publishMode') -and $Plan['publishMode'] -ceq 'draft'){
        return Test-DraftPlanShape -Plan $Plan
    }
    $version=[long]0
    if($Plan -isnot [System.Collections.IDictionary] -or
        -not(Test-Syp171JsonInteger -Value $Plan.schemaVersion -Minimum 1) -or
        -not [long]::TryParse([string]$Plan.schemaVersion,[ref]$version) -or
        $version -ne 5){return $false}
    $top=@('schemaVersion','operationId','createdAtUtc','siteOrigin','cloudId','publishMode','docsCommit','codeCommit','sourceMode',
        'sourceDigest','mappingDigest','reviewDigest','validatorVersion','rendererVersion','pages','validationInputs','linkStrategy')
    if($Plan.Contains('projectionScope')){
        $top+='projectionScope'
        if($Plan.pages -isnot [array] -or $Plan.validationInputs -isnot [System.Collections.IDictionary] -or
            -not(Test-ConfluenceProjectionScopeShape -Scope $Plan.projectionScope -Pages @($Plan.pages))){return $false}
    }
    if(-not(Test-Syp171JsonKeys -Value $Plan -Expected $top) -or
        [string]$Plan.operationId -cnotmatch '^[a-f0-9]{32}$' -or
        [string]$Plan.siteOrigin -cnotmatch '^https://[^/?#]+$' -or
        [string]$Plan.cloudId -cnotmatch '^[a-fA-F0-9-]{36}$' -or
        [string]$Plan.docsCommit -cnotmatch '^(?:[a-f0-9]{40}|[a-f0-9]{64})$' -or
        [string]$Plan.codeCommit -cnotmatch '^(?:[a-f0-9]{40}|[a-f0-9]{64})?$' -or
        $Plan.publishMode -cne 'current' -or $Plan.sourceMode -cnotin @('git-markdown','capture-markdown') -or
        [string]$Plan.sourceDigest -cnotmatch '^[a-f0-9]{64}$' -or
        [string]$Plan.mappingDigest -cnotmatch '^[a-f0-9]{64}$' -or
        [string]$Plan.reviewDigest -cnotmatch '^([a-f0-9]{64})?$' -or
        [string]::IsNullOrWhiteSpace([string]$Plan.validatorVersion) -or
        [string]::IsNullOrWhiteSpace([string]$Plan.rendererVersion) -or
        $Plan.pages -isnot [array] -or @($Plan.pages).Count -eq 0 -or @($Plan.pages).Count -gt 100 -or
        [string]$Plan.linkStrategy -cne 'identity-first'){return $false}
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
        $requiredInputs=@('docsCommit','mappingPath','root')
        $optionalInputs=@('codeBindingPath','codeReviewPath','reviewPath')
        if(@($requiredInputs|Where-Object {$_ -cnotin $inputKeys}).Count -gt 0 -or
            @($inputKeys|Where-Object {$_ -cnotin ($requiredInputs+$optionalInputs)}).Count -gt 0 -or
            @($requiredInputs|Where-Object {[string]::IsNullOrWhiteSpace([string]$Plan.validationInputs[$_])}).Count -gt 0 -or
            [string]$Plan.validationInputs.docsCommit -cnotmatch '^(?:[a-f0-9]{40}|[a-f0-9]{64})$'){return $false}
    }
    $projections=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $identities=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $allowedWrites=@('create','update','no-op','page-create-intermediate','page-create-readback','link-resolution',
        'attachment-upload','attachment-upload-or-reuse','final-page-body-update','page-body-update','attachment-and-page-readback')
    foreach($page in @($Plan.pages)){
        $pageKeys=@('projectionId','pageId','spaceId','parentId','parentProjectionId','title','action','expectedPublishedVersion',
            'expectedPublishedBodySha256','expectedParentVersion','expectedParentBodySha256','expectedDraftObservation',
            'payloadPath','payloadSha256','assetChanges','intermediateWrites')
        $pageKeys+=@('deferredTargets')
        if($page -is [System.Collections.IDictionary] -and $page.Contains('targetContentRemovals')){
            $pageKeys+=@('targetContentRemovals')
            if(-not(Test-PlanTargetContentRemovals -Removals $page.targetContentRemovals)){return $false}
        }
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
        if($page.action -ceq 'create'){
            $identity='create:' + [string]$page.projectionId
        }else{
            $identity='page:' + [string]$page.pageId
        }
        if(-not $identities.Add($identity)){return $false}
        if($page.action -ceq 'create'){
            if([string]$page.pageId -ne '' -or [long]$page.expectedPublishedVersion -ne 0){return $false}
        }elseif([string]$page.pageId -cnotmatch '^[0-9]+$' -or [long]$page.expectedPublishedVersion -lt 1){return $false}
        if([string]$page.parentProjectionId -ne '' -and
            ($page.action -cne 'create' -or [string]$page.parentId -ne '' -or
             $null -ne $page.expectedParentVersion -or $null -ne $page.expectedParentBodySha256)){return $false}
        if($page.deferredTargets -isnot [array] -or @($page.deferredTargets).Count -gt 100 -or
             @($page.deferredTargets|Where-Object {[string]$_ -cnotmatch '^[a-z][a-z0-9-]{0,49}$'}).Count -gt 0 -or
            @($page.deferredTargets|Select-Object -Unique).Count -ne @($page.deferredTargets).Count){return $false}
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
        $expectedWrites=if(@($page.deferredTargets).Count -gt 0 -and $page.action -ceq 'create'){@('page-create-intermediate','page-create-readback','link-resolution','attachment-upload-or-reuse','final-page-body-update','attachment-and-page-readback')}
            elseif(@($page.deferredTargets).Count -gt 0 -and $page.action -ceq 'update'){@('link-resolution','attachment-upload-or-reuse','page-body-update','attachment-and-page-readback')}
            elseif($page.action -ceq 'no-op'){@('no-op')}
            elseif($page.action -ceq 'create' -and @($page.assetChanges).Count -eq 0){@('page-create-intermediate','page-create-readback','final-page-body-update','attachment-and-page-readback')}
            elseif(@($page.assetChanges).Count -eq 0){@($page.action)}
            elseif($page.action -ceq 'create'){@('page-create-intermediate','page-create-readback','attachment-upload','final-page-body-update','attachment-and-page-readback')}
            else{@('attachment-upload-or-reuse','page-body-update','attachment-and-page-readback')}
        if((@($page.intermediateWrites)-join ',') -cne (@($expectedWrites)-join ',')){return $false}
    }
    return $true
}

function Test-PlanTargetContentRemovals {
    param([object]$Removals)
    if($Removals -isnot [array] -or @($Removals).Count -eq 0 -or @($Removals).Count -gt 1000){return $false}
    $seen=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($item in @($Removals)){
        if(-not(Test-Syp171JsonKeys -Value $item -Expected @('kind','key','baselineCount','payloadCount')) -or
            $item.kind -cne 'heading' -or $item.key -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$item.key) -or
            -not(Test-Syp171JsonInteger -Value $item.baselineCount -Minimum 1) -or -not(Test-Syp171JsonInteger -Value $item.payloadCount) -or
            [long]$item.payloadCount -ge [long]$item.baselineCount -or -not $seen.Add([string]$item.key)){return $false}
    }
    return $true
}

function Test-DraftPlanShape {
    param([object]$Plan)
    if(-not(Test-Syp171JsonInteger $Plan.schemaVersion) -or $Plan.schemaVersion -ne 5 -or
        $Plan.publishMode -cne 'draft' -or -not $Plan.Contains('attachmentStrategy') -or
        $Plan.attachmentStrategy -cne 'immutable-content-name' -or -not $Plan.Contains('draftSnapshotTiming') -or
        $Plan.draftSnapshotTiming -cne 'prewrite'){return $false}
    if($Plan.Contains('draftLinkPolicy') -and ($Plan.validationInputs -isnot [System.Collections.IDictionary] -or
        -not(Test-ConfluenceDraftLinkPolicyShape -Policy $Plan.draftLinkPolicy))){return $false}
    $copy=ConvertFrom-Syp171StrictJson -Json ($Plan|ConvertTo-Json -Depth 18) -Depth 18
    $null=$copy.Remove('attachmentStrategy');$null=$copy.Remove('draftSnapshotTiming');$null=$copy.Remove('draftLinkPolicy');$copy['publishMode']='current'
    foreach($page in @($copy.pages)){
        if($page.action -cnotin @('update','no-op') -or
            $page.expectedDraftObservation -cne 'captured' -or $page.expectedDraftVersion -ne 1 -or
            -not(Test-Syp171JsonInteger $page.expectedDraftVersion) -or
            [string]$page.expectedDraftBodySha256 -cnotmatch '^[a-f0-9]{64}$' -or
            $page.parentProjectionId -cne '' -or $null -ne $page.expectedParentVersion -or $null -ne $page.expectedParentBodySha256){return $false}
        if(($page.action -ceq 'update' -and [string]$page.draftBaselinePath -cnotmatch '^plan-assets/[a-f0-9]{32}/[a-f0-9]{64}-draft-baseline\.storage\.xml$') -or
            ($page.action -ceq 'no-op' -and $page.Contains('draftBaselinePath'))){return $false}
        $page.expectedDraftObservation='same-as-published'
        foreach($key in @('expectedDraftVersion','expectedDraftBodySha256','draftBaselinePath')){$null=$page.Remove($key)}
        $writes=if($page.action -ceq 'no-op'){@('no-op')}elseif(@($page.assetChanges).Count -eq 0){@('draft-body-update')}
            else{@('draft-attachment-upload-or-reuse','draft-body-update','draft-and-attachment-readback')}
        if((@($page.intermediateWrites)-join ',') -cne ($writes-join ',')){return $false}
        $page.intermediateWrites=@(if($page.action -ceq 'no-op'){'no-op'}elseif(@($page.assetChanges).Count -eq 0){'update'}
            else{'attachment-upload-or-reuse','page-body-update','attachment-and-page-readback'})
        if(@($page.assetChanges).Count -gt 0){
            foreach($asset in @($page.assetChanges)){
                $extension=Get-ManagedAssetRemoteExtension -MediaType ([string]$asset.mediaType) -LocalPath ([string]$asset.localPath)
                if($null -eq $extension -or
                    $asset.remoteFilename -cne "syp171-$($page.projectionId)-$($asset.sha256)$extension"){return $false}
            }
        }
    }
    return Test-ConfluencePlanShape -Plan $copy
}

function Test-PlanValidation {
    param([object]$Validation,[string]$ExpectedSiteOrigin)
    if($null -eq $Validation -or $Validation.status -cne 'valid' -or
        $Validation.siteOrigin -cne $ExpectedSiteOrigin -or [string]$Validation.cloudId -cnotmatch '^[a-fA-F0-9-]{36}$' -or
        $Validation.docsCommit -cnotmatch '^(?:[a-f0-9]{40}|[a-f0-9]{64})$' -or
        [string]$Validation.codeCommit -cnotmatch '^(?:[a-f0-9]{40}|[a-f0-9]{64})?$' -or
        $Validation.sourceDigest -cnotmatch '^[a-f0-9]{64}$' -or $Validation.mappingDigest -cnotmatch '^[a-f0-9]{64}$' -or
        [string]$Validation.reviewDigest -cnotmatch '^([a-f0-9]{64})?$' -or
        ([string]$Validation.sourceMode -cnotin @('git-markdown','capture-markdown',''))){return $false}
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
    $fragmentPattern='(?:#(?:[A-Za-z0-9._~-]|%[A-Fa-f0-9]{2})+)?'
    $hrefPattern='href="'+$sitePattern+'/wiki/pages/viewpage\.action\?pageId='+$tokenPattern+$fragmentPattern+'"'
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
        [ValidateSet('current','draft')][string]$PublishMode='current',
        [System.Collections.IDictionary]$ProjectionScope,
        [System.Collections.IDictionary]$DraftLinkPolicy
    )
    if(-not(Test-PlanValidation -Validation $Validation -ExpectedSiteOrigin $ExpectedSiteOrigin)){
        return New-PlanResult -Status 'invalid' -ReasonCodes @('ValidationIncomplete') -PlanPath '' -PlanSha256 ''
    }
    $PublishMode=$PublishMode.ToLowerInvariant()
    if(-not(Test-ConfluenceApiBaseIdentity -ApiBase $ApiBase -CloudId ([string]($($Validation.cloudId))) -ComparisonMode RawTrimmed) -or
        $Payloads.Count -eq 0 -or $Payloads.Count -gt 100){
        return New-PlanResult -Status 'invalid' -ReasonCodes @('PlanScopeInvalid') -PlanPath '' -PlanSha256 ''
    }
    if($null -ne $ProjectionScope -and
        ($ValidationInputs -isnot [System.Collections.IDictionary] -or
         -not(Test-ConfluenceProjectionScopeShape -Scope $ProjectionScope -Pages $Payloads))){
        return New-PlanResult -Status 'invalid' -ReasonCodes @('ProjectionScopeInvalid') -PlanPath '' -PlanSha256 ''
    }
    if($null -ne $DraftLinkPolicy -and
        ($PublishMode -cne 'draft' -or $ValidationInputs -isnot [System.Collections.IDictionary] -or
         -not(Test-ConfluenceDraftLinkPolicyShape -Policy $DraftLinkPolicy))){
        return New-PlanResult -Status 'invalid' -ReasonCodes @('DraftLinkPolicyInvalid') -PlanPath '' -PlanSha256 ''
    }
    $planFull=[IO.Path]::GetFullPath($PlanPath)
    $planDir=[IO.Path]::GetDirectoryName($planFull)
    $planDigestPath=[string]($planFull + '.sha256')
    $planAssetsRoot=Join-Path $planDir 'plan-assets'
    if((Test-ConfluencePlanPathReparsePoint -Path $planFull) -or
        (Test-ConfluencePlanPathReparsePoint -Path $planDigestPath) -or
        (Test-ConfluencePlanPathReparsePoint -Path $planAssetsRoot)){
        return New-PlanResult -Status 'invalid' -ReasonCodes @('ReparsePointRejected') -PlanPath '' -PlanSha256 ''
    }
    $validationInputRoot=''
    if($ValidationInputs -is [System.Collections.IDictionary] -and $ValidationInputs.Contains('root')){
        $validationInputRoot=[string]$ValidationInputs['root']
    }elseif($null -ne $ValidationInputs -and $null -ne $ValidationInputs.PSObject.Properties['root']){
        $validationInputRoot=[string]$ValidationInputs.root
    }
    if(-not [string]::IsNullOrWhiteSpace($validationInputRoot) -and
        (Test-ConfluencePlanPathReparsePoint -Path $validationInputRoot)){
        return New-PlanResult -Status 'invalid' -ReasonCodes @('ReparsePointRejected') -PlanPath '' -PlanSha256 ''
    }
    if(-not(Test-Path -LiteralPath $planDir -PathType Container) -or
        (Test-Path -LiteralPath $planFull) -or (Test-Path -LiteralPath $planDigestPath)){
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
    if($PublishMode -ceq 'draft'){
        $draftBlockers=@(Get-ConfluenceDraftScopeBlockers -Payloads $orderedPayloads)
        if($draftBlockers.Count -gt 0){
            return New-PlanResult -Status 'blocked' -ReasonCodes @('DraftScopeUnsupported') -PlanPath '' -PlanSha256 '' -Blockers $draftBlockers
        }
    }
    if($PublishMode -ceq 'draft'){
        foreach($payload in $orderedPayloads){
            if(-not(Test-ConfluenceStorageEquivalent -Expected ([string]$payload.bodyStorage) -Actual ([string]$payload.bodyStorage))){
                return New-PlanResult -Status invalid -ReasonCodes @('DraftStorageInvalid') -PlanPath '' -PlanSha256 ''
            }
        }
    }
    $draftAssets=$PublishMode -ceq 'draft' -and @($orderedPayloads | Where-Object { @($_.assetChanges).Count -gt 0 }).Count -gt 0
    $seen=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $validatedAssets=@{}
    $mermaidReferences=@{}
    $totalAssetBytes=[int64]0
    foreach($payload in $orderedPayloads){
        $id=[string]$payload.pageId
        $parentProjection=Get-PlanParentProjectionId -Payload $payload
        if(($id -ne '' -and $id -cnotmatch '^[0-9]+$') -or
            -not $seen.Add($(if($id -eq ''){('create:' + [string]($($payload.projectionId)))}else{('page:' + [string]($id))})) -or
            [string]$payload.spaceId -cnotmatch '^[0-9]+$' -or [string]$payload.projectionId -cnotmatch '^[a-z][a-z0-9-]{0,49}$' -or
            ($parentProjection -eq '' -and [string]$payload.parentId -cnotmatch '^[0-9]+$') -or $null -eq $payload.bodyStorage -or
            @($payload.assetChanges).Count -gt 25){
            return New-PlanResult -Status 'invalid' -ReasonCodes @('PayloadInvalid') -PlanPath '' -PlanSha256 ''
        }
        $assets=[System.Collections.Generic.List[object]]::new()
        $mermaidReferences[[string]$payload.projectionId]=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        if(@($payload.assetChanges).Count -gt 0){
            $storageReferences=Get-PlanStorageAssetReferences -Storage ([string]$payload.bodyStorage)
            if($storageReferences.status -cne 'valid'){
                return New-PlanResult -Status 'invalid' -ReasonCodes @('PayloadInvalid') -PlanPath '' -PlanSha256 ''
            }
            $mermaidReferences[[string]$payload.projectionId]=$storageReferences.mermaidNames
            $assetRoot=''
            if($ValidationInputs -is [System.Collections.IDictionary]){$assetRoot=[string]$ValidationInputs['root']}
            elseif($null -ne $ValidationInputs -and $null -ne $ValidationInputs.PSObject.Properties['root']){$assetRoot=[string]$ValidationInputs.root}
            if([string]::IsNullOrWhiteSpace($assetRoot)){
                return New-PlanResult -Status 'invalid' -ReasonCodes @('AssetRootUnavailable') -PlanPath '' -PlanSha256 ''
            }
            $names=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach($candidate in @($payload.assetChanges)){
                $localAssetPath=''
                if($candidate -is [System.Collections.IDictionary] -and $candidate.Contains('localPath')){
                    $localAssetPath=[string]$candidate['localPath']
                }elseif($null -ne $candidate -and $null -ne $candidate.PSObject.Properties['localPath']){
                    $localAssetPath=[string]$candidate.localPath
                }
                if(-not [string]::IsNullOrWhiteSpace($validationInputRoot) -and
                    -not [string]::IsNullOrWhiteSpace($localAssetPath) -and
                    (Test-ConfluencePlanSafeAssetRelativePath -Path $localAssetPath)){
                    $assetSourcePath=[IO.Path]::GetFullPath((Join-Path $validationInputRoot $localAssetPath))
                    if(Test-ConfluencePlanPathReparsePoint -Path $assetSourcePath){
                        return New-PlanResult -Status 'invalid' -ReasonCodes @('ReparsePointRejected') -PlanPath '' -PlanSha256 ''
                    }
                }
                $asset=Resolve-LocalManagedAsset -Root $assetRoot -ProjectionId ([string]$payload.projectionId) -Asset $candidate
                if($asset.status -cne 'valid'){
                    return New-PlanResult -Status 'invalid' -ReasonCodes $asset.reasonCodes -PlanPath '' -PlanSha256 ''
                }
                if(-not $names.Add([string]$asset.remoteFilename) -or -not $storageReferences.names.Contains([string]$asset.remoteFilename)){
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
    $createTitles=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($payload in $orderedPayloads){
        if([string]$payload.pageId -ceq ''){
            $spaceId=[string]$payload.spaceId
            $title=[string]$payload.title
            $titleKey=('{0}:{1}:{2}' -f $spaceId.Length,$spaceId,$title)
            if(-not $createTitles.Add($titleKey)){
                return New-PlanResult -Status 'blocked' -ReasonCodes @('CreateTitleCollision') -PlanPath '' -PlanSha256 ''
            }
        }
    }
    $observed=[System.Collections.Generic.List[object]]::new()
    $pageBlockers=[System.Collections.Generic.List[object]]::new()
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
        if($reread.version -ne $published.version -or $reread.storage -cne $published.storage){
            return New-PlanResult -Status 'blocked' -ReasonCodes @('RemoteUnstable') -PlanPath '' -PlanSha256 ''
        }
        $pageCodes=[System.Collections.Generic.List[string]]::new()
        $pageDetails=[ordered]@{}
        if($published.spaceId -cne [string]$payload.spaceId){
            $pageCodes.Add('TargetSpaceMismatch');$pageDetails['space']=[ordered]@{expected=[string]$payload.spaceId;actual=[string]$published.spaceId}
        }
        if($published.parentId -cne [string]$payload.parentId){
            $pageCodes.Add('TargetParentMismatch');$pageDetails['parent']=[ordered]@{expected=[string]$payload.parentId;actual=[string]$published.parentId}
        }
        if($PublishMode -ceq 'current' -and ($draft.version -ne $published.version -or $draft.storage -cne $published.storage)){
            return New-PlanResult -Status 'blocked' -ReasonCodes @('DraftConflict') -PlanPath '' -PlanSha256 ''
        }
        if($PublishMode -ceq 'draft' -and ($draft.version -ne 1 -or $draft.spaceId -cne $published.spaceId -or
            $draft.parentId -cne $published.parentId -or $draft.title -cne $published.title -or $published.title -cne [string]$payload.title)){
            return New-PlanResult -Status 'blocked' -ReasonCodes @('DraftIdentityUnverified') -PlanPath '' -PlanSha256 ''
        }
        $baselineStorage=if($PublishMode -ceq 'draft'){[string]$draft.storage}else{[string]$published.storage}
        $content=Compare-ConfluenceStorageContent -Baseline $baselineStorage -Payload ([string]$payload.bodyStorage) -SiteOrigin $ExpectedSiteOrigin
        if($content.status -cne 'valid'){$pageCodes.Add('TargetContentUnverified')}
        elseif($content.blocking){$pageCodes.Add('TargetContentRemoved');$pageDetails['removedContent']=@($content.removed)}
        if($pageCodes.Count -gt 0){
            $pageBlockers.Add((New-ConfluenceScopeBlocker -ProjectionId ([string]$payload.projectionId) -PageId $id -ReasonCodes $pageCodes.ToArray() -Details $pageDetails))
            continue
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
            $remoteArguments = @{
                SiteOrigin = $ExpectedSiteOrigin
                ApiBase = $ApiBase
                CloudId = $Validation.cloudId
                PageId = $id
                RemoteFilename = $asset.remoteFilename
                MediaType = $asset.mediaType
                Sha256 = $asset.sha256
                ByteLength = $asset.byteLength
                HttpInvoker = $HttpInvoker
            }
            $remote = Get-ManagedAttachmentObservation @remoteArguments
            if($remote.status -cne 'ready'){
                return New-PlanResult -Status 'blocked' -ReasonCodes $remote.reasonCodes -PlanPath '' -PlanSha256 ''
            }
            if($mermaidReferences[[string]$payload.projectionId].Contains([string]$asset.remoteFilename) -and
                -not (($remote.action -ceq 'upload' -and [int]$remote.remoteVersion -eq 0) -or
                    ($remote.action -ceq 'reuse' -and [int]$remote.remoteVersion -eq 1))){
                return New-PlanResult -Status 'blocked' -ReasonCodes @('MermaidRevisionConflict') -PlanPath '' -PlanSha256 ''
            }
            if($draftAssets -and $remote.action -ceq 'upload' -and @($currentReferences.names) -ccontains $asset.remoteFilename){
                return New-PlanResult -Status blocked -ReasonCodes @('DraftAttachmentAffectsCurrent') -PlanPath '' -PlanSha256 ''
            }
            $remoteAssets.Add([pscustomobject]@{source=$asset;action=$remote.action;remoteAttachmentId=$remote.remoteAttachmentId;remoteVersion=$remote.remoteVersion})
        }
        $needsUpload=@($remoteAssets|Where-Object action -eq 'upload').Count -gt 0
        $bodyMatches=Test-ConfluenceStorageEquivalent -Expected ([string]$payload.bodyStorage) -Actual $(if($PublishMode -ceq 'draft'){$draft.storage}else{$published.storage})
        $action=if($bodyMatches -and $published.title -ceq [string]$payload.title -and -not $needsUpload){'no-op'}else{'update'}
        $observed.Add([pscustomobject]@{payload=$payload;published=$published;draft=$draft;action=$action;assets=$remoteAssets.ToArray();removedContent=@($content.removed)})
    }
    if($pageBlockers.Count -gt 0){
        $sortedBlockers=Get-ConfluenceSortedScopeBlockers -Blockers $pageBlockers
        $codes=@(@('TargetSpaceMismatch','TargetParentMismatch','TargetContentUnverified','TargetContentRemoved')|
            Where-Object {$code=$_;@($sortedBlockers|Where-Object {@($_.reasonCodes) -ccontains $code}).Count -gt 0})
        return New-PlanResult -Status 'blocked' -ReasonCodes $codes -PlanPath '' -PlanSha256 '' -Blockers $sortedBlockers
    }
    $disclosures=@($observed|Where-Object {$null -ne $_.PSObject.Properties['removedContent'] -and @($_.removedContent).Count -gt 0}|ForEach-Object {
        [pscustomobject][ordered]@{projectionId=[string]$_.payload.projectionId;pageId=[string]$_.payload.pageId;removedContent=@($_.removedContent)}
    })
    $operationId=[Guid]::NewGuid().ToString('N')
    $assetRoot=Join-Path $planDir "plan-assets/$operationId"
    $stage="$assetRoot.staging"
    if((Test-ConfluencePlanPathReparsePoint -Path $planFull) -or
        (Test-ConfluencePlanPathReparsePoint -Path $planDigestPath) -or
        (Test-ConfluencePlanPathReparsePoint -Path $planAssetsRoot) -or
        (Test-ConfluencePlanPathReparsePoint -Path $assetRoot) -or
        (Test-ConfluencePlanPathReparsePoint -Path $stage)){
        return New-PlanResult -Status 'invalid' -ReasonCodes @('ReparsePointRejected') -PlanPath '' -PlanSha256 ''
    }
    if((Test-Path -LiteralPath $planFull) -or (Test-Path -LiteralPath $planDigestPath)){
        return New-PlanResult -Status 'invalid' -ReasonCodes @('PlanPathUnavailable') -PlanPath '' -PlanSha256 ''
    }
    if((Test-Path -LiteralPath $assetRoot) -or (Test-Path -LiteralPath $stage)){
        return New-PlanResult -Status 'failed' -ReasonCodes @('PlanStagingConflict') -PlanPath '' -PlanSha256 ''
    }
    try {
        if((Test-ConfluencePlanPathReparsePoint -Path $planFull) -or
            (Test-ConfluencePlanPathReparsePoint -Path $planDigestPath) -or
            (Test-ConfluencePlanPathReparsePoint -Path $planAssetsRoot) -or
            (Test-ConfluencePlanPathReparsePoint -Path $assetRoot) -or
            (Test-ConfluencePlanPathReparsePoint -Path $stage)){
            throw 'ReparsePointRejected'
        }
        if((Test-Path -LiteralPath $planFull) -or (Test-Path -LiteralPath $planDigestPath)){
            throw 'PlanPathUnavailable'
        }
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        $pages=[System.Collections.Generic.List[object]]::new()
        foreach($item in $observed){
            $payload=$item.payload;$published=$item.published
            $bytes=[Text.Encoding]::UTF8.GetBytes([string]$payload.bodyStorage)
            $sha=Get-AssetHash -Bytes $bytes
            $filename="$(Get-AssetHash -Bytes ([Text.Encoding]::UTF8.GetBytes([string]$payload.projectionId))).storage.xml"
            $storageStagePath=Join-Path $stage $filename
            if((Test-ConfluencePlanPathReparsePoint -Path $stage) -or
                (Test-ConfluencePlanPathReparsePoint -Path $storageStagePath)){
                throw 'ReparsePointRejected'
            }
            if(Test-Path -LiteralPath $storageStagePath){throw 'PlanStagingConflict'}
            [IO.File]::WriteAllBytes($storageStagePath,$bytes)
            $assetRecords=[System.Collections.Generic.List[object]]::new()
            foreach($observedAsset in @($item.assets)){
                $asset=$observedAsset.source
                $assetFilename="$($asset.sha256).asset"
                $assetStagePath=Join-Path $stage $assetFilename
                if((Test-ConfluencePlanPathReparsePoint -Path $stage) -or
                    (Test-ConfluencePlanPathReparsePoint -Path $assetStagePath)){
                    throw 'ReparsePointRejected'
                }
                if(-not(Test-Path -LiteralPath $assetStagePath)){
                    [IO.File]::WriteAllBytes($assetStagePath,[byte[]]$asset.bytes)
                }else{
                    if(Test-ConfluencePlanPathReparsePoint -Path $assetStagePath){throw 'ReparsePointRejected'}
                    if((Get-AssetHash -Bytes ([IO.File]::ReadAllBytes($assetStagePath))) -cne $asset.sha256){
                        throw 'AssetStageCollision'
                    }
                }
                $assetRecords.Add([ordered]@{
                    localPath=$asset.localPath;displayFilename=$asset.displayFilename;mediaType=$asset.mediaType
                    remoteFilename=$asset.remoteFilename;sha256=$asset.sha256;byteLength=$asset.byteLength
                    payloadPath=('plan-assets/' + [string]($operationId) + '/' + [string]($assetFilename));action=$observedAsset.action
                    remoteAttachmentId=$observedAsset.remoteAttachmentId;remoteVersion=$observedAsset.remoteVersion
                })
            }
            $hasDeferredTargets=$deferred.linked -and @($payload.deferredTargets).Count -gt 0
            $intermediateWrites=if($hasDeferredTargets -and $item.action -ceq 'create'){@('page-create-intermediate','page-create-readback','link-resolution','attachment-upload-or-reuse','final-page-body-update','attachment-and-page-readback')}
                elseif($hasDeferredTargets -and $item.action -ceq 'update'){@('link-resolution','attachment-upload-or-reuse','page-body-update','attachment-and-page-readback')}
                elseif($item.action -ceq 'no-op'){@('no-op')}
                elseif($item.action -ceq 'create' -and $assetRecords.Count -eq 0){@('page-create-intermediate','page-create-readback','final-page-body-update','attachment-and-page-readback')}
                elseif($assetRecords.Count -eq 0){@($item.action)}
                elseif($item.action -ceq 'create'){@('page-create-intermediate','page-create-readback','attachment-upload','final-page-body-update','attachment-and-page-readback')}
                else{@('attachment-upload-or-reuse','page-body-update','attachment-and-page-readback')}
            $pageRecord=[ordered]@{
                projectionId=[string]$payload.projectionId;pageId=[string]$payload.pageId
                spaceId=[string]$payload.spaceId;parentId=[string]$payload.parentId
                parentProjectionId=(Get-PlanParentProjectionId -Payload $payload);title=[string]$payload.title
                action=$item.action;expectedPublishedVersion=$(if($item.action -ceq 'create'){0}else{$published.version})
                expectedPublishedBodySha256=$(if($null -ne $published){Get-AssetHash -Bytes ([Text.Encoding]::UTF8.GetBytes($published.storage))}else { [string]::Empty })
                expectedParentVersion=$(if($item.action -ceq 'create' -and $null -ne $published){$published.version}else{$null})
                expectedParentBodySha256=$(if($item.action -ceq 'create' -and $null -ne $published){Get-AssetHash -Bytes ([Text.Encoding]::UTF8.GetBytes($published.storage))}else{$null})
                expectedDraftObservation='same-as-published';payloadPath=('plan-assets/' + [string]($operationId) + '/' + [string]($filename))
                payloadSha256=$sha;assetChanges=@($assetRecords.ToArray())
                intermediateWrites=@($intermediateWrites);deferredTargets=@(if($deferred.linked){$payload.deferredTargets})
            }
            if($null -ne $item.PSObject.Properties['removedContent'] -and @($item.removedContent).Count -gt 0){
                $pageRecord['targetContentRemovals']=@($item.removedContent|ForEach-Object {
                    [ordered]@{kind=[string]$_.kind;key=[string]$_.key;baselineCount=[int]$_.baselineCount;payloadCount=[int]$_.payloadCount}})
            }
            if($PublishMode -ceq 'draft'){
                if ($item.action -ceq 'no-op') {
                    $pageRecord.intermediateWrites = @('no-op')
                } elseif ($assetRecords.Count -eq 0) {
                    $pageRecord.intermediateWrites = @('draft-body-update')
                } else {
                    $pageRecord.intermediateWrites = @('draft-attachment-upload-or-reuse','draft-body-update','draft-and-attachment-readback')
                }
                $draftBytes=[Text.Encoding]::UTF8.GetBytes([string]$item.draft.storage)
                $baselineFilename=$filename.Replace('.storage.xml','-draft-baseline.storage.xml')
                $pageRecord.expectedDraftObservation='captured'
                $pageRecord['expectedDraftVersion']=1
                $pageRecord['expectedDraftBodySha256']=Get-AssetHash -Bytes $draftBytes
                if($item.action -ceq 'update'){
                    $pageRecord['draftBaselinePath']="plan-assets/$operationId/$baselineFilename"
                }
            }
            $pages.Add($pageRecord)
        }
        $plan=[ordered]@{
            schemaVersion=5;publishMode=$PublishMode;operationId=$operationId;createdAtUtc=(Get-Date -AsUTC).ToString('o')
            siteOrigin=$Validation.siteOrigin;cloudId=$Validation.cloudId
            docsCommit=$Validation.docsCommit;codeCommit=$(if([string]$Validation.sourceMode -in @('git-markdown','capture-markdown')){[string]$Validation.codeCommit}else{''})
            sourceMode=$(if([string]$Validation.sourceMode -in @('git-markdown','capture-markdown')){[string]$Validation.sourceMode}else{'git-markdown'})
            sourceDigest=$Validation.sourceDigest;mappingDigest=$Validation.mappingDigest;reviewDigest=$Validation.reviewDigest
            validatorVersion=$Validation.validatorVersion;rendererVersion=$Validation.rendererVersion
            linkStrategy='identity-first';pages=@($pages.ToArray())
            validationInputs=$ValidationInputs
        }
        if($null -ne $ProjectionScope){
            $plan['projectionScope']=[ordered]@{
                projectionIds=@($ProjectionScope.projectionIds|ForEach-Object {[string]$_})
                excludedEntries=@($ProjectionScope.excludedEntries|ForEach-Object {[ordered]@{projectionId=[string]$_.projectionId;reasonCodes=@($_.reasonCodes|ForEach-Object {[string]$_})}})
            }
        }
        if($PublishMode -ceq 'draft'){
            $plan['publishMode']='draft';$plan['attachmentStrategy']='immutable-content-name';$plan['draftSnapshotTiming']='prewrite'
            if($null -ne $DraftLinkPolicy){
                $plan['draftLinkPolicy']=[ordered]@{draftEditorTargets=@($DraftLinkPolicy.draftEditorTargets|ForEach-Object {[ordered]@{projectionId=[string]$_.projectionId;pageId=[string]$_.pageId}})}
            }
        }
        if(-not(Test-ConfluencePlanShape -Plan $plan)){throw 'PlanContractInvalid'}
        $planBytes=[Text.Encoding]::UTF8.GetBytes(($plan|ConvertTo-Json -Depth 18))
        $digest=Get-AssetHash -Bytes $planBytes
        if((Test-ConfluencePlanPathReparsePoint -Path $planFull) -or
            (Test-ConfluencePlanPathReparsePoint -Path $planDigestPath) -or
            (Test-ConfluencePlanPathReparsePoint -Path $stage) -or
            (Test-ConfluencePlanPathReparsePoint -Path $assetRoot)){
            throw 'ReparsePointRejected'
        }
        if((Test-Path -LiteralPath $planFull) -or (Test-Path -LiteralPath $planDigestPath) -or
            (Test-Path -LiteralPath $assetRoot)){
            throw 'PlanPathUnavailable'
        }
        Move-Item -LiteralPath $stage -Destination $assetRoot
        if((Test-ConfluencePlanPathReparsePoint -Path $planFull) -or
            (Test-ConfluencePlanPathReparsePoint -Path $planDigestPath) -or
            (Test-ConfluencePlanPathReparsePoint -Path $assetRoot)){
            throw 'ReparsePointRejected'
        }
        if((Test-Path -LiteralPath $planFull) -or (Test-Path -LiteralPath $planDigestPath)){
            throw 'PlanPathUnavailable'
        }
        [IO.File]::WriteAllBytes($planFull,$planBytes)
        if(Test-ConfluencePlanPathReparsePoint -Path $planDigestPath){throw 'ReparsePointRejected'}
        if(Test-Path -LiteralPath $planDigestPath){throw 'PlanPathUnavailable'}
        [IO.File]::WriteAllText($planDigestPath,$digest+('' + ([string][char]10) + ''),[Text.UTF8Encoding]::new($false))
        return New-PlanResult -Status 'preview' -ReasonCodes @() -PlanPath $planFull -PlanSha256 $digest -Disclosures $disclosures
    } catch {
        if($_.Exception.Message -ceq 'ReparsePointRejected'){
            return New-PlanResult -Status 'invalid' -ReasonCodes @('ReparsePointRejected') -PlanPath '' -PlanSha256 ''
        }
        if($_.Exception.Message -ceq 'PlanPathUnavailable'){
            return New-PlanResult -Status 'invalid' -ReasonCodes @('PlanPathUnavailable') -PlanPath '' -PlanSha256 ''
        }
        if($_.Exception.Message -ceq 'PlanStagingConflict'){
            return New-PlanResult -Status 'failed' -ReasonCodes @('PlanStagingConflict') -PlanPath '' -PlanSha256 ''
        }
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
    $digestPath=[string]($full + '.sha256')
    if((Test-ConfluencePlanPathReparsePoint -Path $full) -or
        (Test-ConfluencePlanPathReparsePoint -Path $digestPath)){
        return New-PlanResult -Status 'invalid' -ReasonCodes @('ReparsePointRejected') -PlanPath $full -PlanSha256 ''
    }
    if(-not(Test-Path -LiteralPath $full -PathType Leaf) -or -not(Test-Path -LiteralPath $digestPath -PathType Leaf)){
        return New-PlanResult -Status 'invalid' -ReasonCodes @('PlanUnavailable') -PlanPath $full -PlanSha256 ''
    }
    if((Test-ConfluencePlanPathReparsePoint -Path $full) -or
        (Test-ConfluencePlanPathReparsePoint -Path $digestPath)){
        return New-PlanResult -Status 'invalid' -ReasonCodes @('ReparsePointRejected') -PlanPath $full -PlanSha256 ''
    }
    $bytes=[IO.File]::ReadAllBytes($full);$digest=Get-AssetHash -Bytes $bytes
    if(Test-ConfluencePlanPathReparsePoint -Path $digestPath){
        return New-PlanResult -Status 'invalid' -ReasonCodes @('ReparsePointRejected') -PlanPath $full -PlanSha256 $digest
    }
    if((Get-Content -LiteralPath $digestPath -Raw).Trim() -cne $digest){
        return New-PlanResult -Status 'blocked' -ReasonCodes @('PlanDigestMismatch') -PlanPath $full -PlanSha256 $digest
    }
    try{$plan=ConvertFrom-Syp171StrictJson -Json ([Text.UTF8Encoding]::new($false,$true).GetString($bytes)) -Depth 18}
    catch{return New-PlanResult -Status 'invalid' -ReasonCodes @('PlanSchemaInvalid') -PlanPath $full -PlanSha256 $digest}
    if($plan -is [System.Collections.IDictionary] -and $plan.schemaVersion -eq 5 -and
        $plan.Contains('publishMode') -and $plan.publishMode -ceq 'draft' -and
        (-not $plan.Contains('draftSnapshotTiming') -or $plan.draftSnapshotTiming -cne 'prewrite')){
        return New-PlanResult -Status 'blocked' -ReasonCodes @('PlanRequiresRepreview') -PlanPath $full -PlanSha256 $digest
    }
    if(-not(Test-ConfluencePlanShape -Plan $plan)){
        return New-PlanResult -Status 'invalid' -ReasonCodes @('PlanSchemaInvalid') -PlanPath $full -PlanSha256 $digest
    }
    $isDraftPlan = $plan.publishMode -ceq 'draft'
    if($plan.siteOrigin -cne $ExpectedSiteOrigin -or -not(Test-ConfluenceApiBaseIdentity -ApiBase $ApiBase -CloudId ([string]($($plan.cloudId))) -ComparisonMode RawTrimmed)){
        return New-PlanResult -Status 'blocked' -ReasonCodes @('TenantMismatch') -PlanPath $full -PlanSha256 $digest
    }
    if(-not(Test-PlanValidation -Validation $CurrentValidation -ExpectedSiteOrigin $ExpectedSiteOrigin) -or
        $plan.docsCommit -cne $CurrentValidation.docsCommit -or $plan.codeCommit -cne [string]$CurrentValidation.codeCommit -or
        $plan.sourceMode -cne [string]$CurrentValidation.sourceMode -or $plan.sourceDigest -cne $CurrentValidation.sourceDigest){
        return New-PlanResult -Status 'blocked' -ReasonCodes @('SourceChanged') -PlanPath $full -PlanSha256 $digest
    }
    if($plan.mappingDigest -cne $CurrentValidation.mappingDigest -or $plan.reviewDigest -cne $CurrentValidation.reviewDigest -or
        $plan.validatorVersion -cne $CurrentValidation.validatorVersion -or $plan.rendererVersion -cne $CurrentValidation.rendererVersion){
        return New-PlanResult -Status 'blocked' -ReasonCodes @('ProjectionChanged') -PlanPath $full -PlanSha256 $digest
    }
    if(-not(Test-ConfluencePlanProjectionScope -Plan $plan -Validation $CurrentValidation)){
        return New-PlanResult -Status 'blocked' -ReasonCodes @('ProjectionScopeChanged') -PlanPath $full -PlanSha256 $digest
    }
    if(-not(Test-ConfluencePlanDraftLinkPolicy -Plan $plan -Validation $CurrentValidation)){
        return New-PlanResult -Status 'blocked' -ReasonCodes @('DraftLinkPolicyChanged') -PlanPath $full -PlanSha256 $digest
    }
    $planDir=[IO.Path]::GetDirectoryName($full)
    foreach($page in @($plan.pages)){
        $payload=[IO.Path]::GetFullPath((Join-Path $planDir ([string]$page.payloadPath)))
        $relative=[IO.Path]::GetRelativePath($planDir,$payload)
        if($relative -eq '..' -or $relative.StartsWith(('..' + [string]($([IO.Path]::DirectorySeparatorChar))), [StringComparison]::Ordinal) -or
            [IO.Path]::IsPathRooted($relative)){
            return New-PlanResult -Status 'blocked' -ReasonCodes @('PayloadChanged') -PlanPath $full -PlanSha256 $digest
        }
        if(Test-ConfluencePlanPathReparsePoint -Path $payload){
            return New-PlanResult -Status 'blocked' -ReasonCodes @('ReparsePointRejected') -PlanPath $full -PlanSha256 $digest
        }
        if(-not(Test-Path -LiteralPath $payload -PathType Leaf)){
            return New-PlanResult -Status 'blocked' -ReasonCodes @('PayloadChanged') -PlanPath $full -PlanSha256 $digest
        }
        if(Test-ConfluencePlanPathReparsePoint -Path $payload){
            return New-PlanResult -Status 'blocked' -ReasonCodes @('ReparsePointRejected') -PlanPath $full -PlanSha256 $digest
        }
        $payloadBytes=[IO.File]::ReadAllBytes($payload)
        if((Get-AssetHash -Bytes $payloadBytes) -cne $page.payloadSha256){
            return New-PlanResult -Status 'blocked' -ReasonCodes @('PayloadChanged') -PlanPath $full -PlanSha256 $digest
        }
        foreach($asset in @($page.assetChanges)){
            $assetPath=[IO.Path]::GetFullPath((Join-Path $planDir ([string]$asset.payloadPath)))
            $assetRelative=[IO.Path]::GetRelativePath($planDir,$assetPath)
            if($assetRelative -eq '..' -or $assetRelative.StartsWith(('..' + [string]($([IO.Path]::DirectorySeparatorChar))),[StringComparison]::Ordinal) -or
                [IO.Path]::IsPathRooted($assetRelative)){
                return New-PlanResult -Status 'blocked' -ReasonCodes @('PayloadChanged') -PlanPath $full -PlanSha256 $digest
            }
            if(Test-ConfluencePlanPathReparsePoint -Path $assetPath){
                return New-PlanResult -Status 'blocked' -ReasonCodes @('ReparsePointRejected') -PlanPath $full -PlanSha256 $digest
            }
            if(-not(Test-Path -LiteralPath $assetPath -PathType Leaf)){
                return New-PlanResult -Status 'blocked' -ReasonCodes @('PayloadChanged') -PlanPath $full -PlanSha256 $digest
            }
            if(Test-ConfluencePlanPathReparsePoint -Path $assetPath){
                return New-PlanResult -Status 'blocked' -ReasonCodes @('ReparsePointRejected') -PlanPath $full -PlanSha256 $digest
            }
            $assetItem=Get-Item -LiteralPath $assetPath -Force
            if($assetItem.Length -ne [int64]$asset.byteLength){
                return New-PlanResult -Status 'blocked' -ReasonCodes @('PayloadChanged') -PlanPath $full -PlanSha256 $digest
            }
            if(Test-ConfluencePlanPathReparsePoint -Path $assetPath){
                return New-PlanResult -Status 'blocked' -ReasonCodes @('ReparsePointRejected') -PlanPath $full -PlanSha256 $digest
            }
            $assetBytes=[IO.File]::ReadAllBytes($assetPath)
            if((Get-AssetHash -Bytes $assetBytes) -cne $asset.sha256){
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
        $draft=if($isDraftPlan){Read-ConfluenceDraftPage -ApiBase $ApiBase -PageId ([string]$page.pageId) -HttpInvoker $HttpInvoker}
            else{Read-PlanRemotePage -ApiBase $ApiBase -PageId ([string]$page.pageId) -Draft $true -HttpInvoker $HttpInvoker}
        if($null -eq $published -or $null -eq $draft){
            return New-PlanResult -Status 'blocked' -ReasonCodes @('RemoteReadIncomplete') -PlanPath $full -PlanSha256 $digest
        }
        if($isDraftPlan){
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

Export-ModuleMember -Function New-ConfluencePreviewPlan,Test-ConfluencePlanDrift,Test-CreateTitleAvailable,Test-ConfluencePlanShape,Read-ConfluenceDraftPage,
    Get-ConfluenceDraftScopeBlockers,New-ConfluenceScopeBlocker,New-ConfluenceProjectionScopeRecord,Test-ConfluencePlanProjectionScope,
    New-ConfluenceDraftLinkPolicyRecord,Test-ConfluencePlanDraftLinkPolicy
