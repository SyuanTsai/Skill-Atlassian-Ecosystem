# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
Import-Module -Name (Join-Path $PSScriptRoot 'OpenSpecSource.psm1') -Force -Scope Local
Import-Module -Name (Join-Path $PSScriptRoot 'ConfluenceMapping.psm1') -Force -Scope Local
Import-Module -Name (Join-Path $PSScriptRoot 'ConfluenceCodeBinding.psm1') -Force -Scope Local
Import-Module -Name (Join-Path $PSScriptRoot 'ImportReview.psm1') -Force -Scope Local
Import-Module -Name (Join-Path $PSScriptRoot 'StrictJson.psm1') -Force -Scope Local

function New-ValidationResult {
    param([string]$Status,[string[]]$ReasonCodes,[object]$Fields)
    $defaults=[ordered]@{
        status=$Status;reasonCodes=@($ReasonCodes);siteOrigin='';cloudId='';docsCommit='';specCommit='';codeCommit=''
        sourceDigest='';mappingDigest='';reviewDigest='';validatorVersion='';rendererVersion='1'
        scenarioIds=@();coverageGaps=@();scenarioAcceptance='incomplete';publishEligibility='blocked'
        approvalStatus='unknown';implementationStatus='unknown';changeId=''
    }
    if($null -ne $Fields){foreach($key in $Fields.Keys){$defaults[$key]=$Fields[$key]}}
    return [pscustomobject]$defaults
}

function Resolve-ReviewRelativePath {
    param([string]$Root,[string]$Relative)
    if([string]::IsNullOrWhiteSpace($Relative) -or $Relative -match '[\\\r\n]' -or $Relative.StartsWith('/',[StringComparison]::Ordinal) -or $Relative -match '^[A-Za-z]:'){
        return $null
    }
    foreach($part in ($Relative -split '/')){if($part -in @('', '.', '..')){return $null}}
    $full=[IO.Path]::GetFullPath((Join-Path $Root $Relative))
    $fromRoot=[IO.Path]::GetRelativePath([IO.Path]::GetFullPath($Root),$full)
    if($fromRoot -eq '..' -or $fromRoot.StartsWith("..$([IO.Path]::DirectorySeparatorChar)",[StringComparison]::Ordinal) -or
        -not(Test-Path -LiteralPath $full -PathType Leaf)){return $null}
    return $full
}

function Test-SourceAtCommit {
    param([string]$Root,[string]$Commit,[string[]]$SourcePaths)
    if($Commit -cnotmatch '^(?:[a-f0-9]{40}|[a-f0-9]{64})$'){return $false}
    $resolved=& git -C $Root rev-parse --verify "$Commit`^{commit}" 2>$null
    if($LASTEXITCODE -ne 0 -or [string]$resolved -cne $Commit){return $false}
    foreach($path in $SourcePaths){
        if($path -match '[\\\r\n]' -or $path -match '(?:^|/)\.\.(?:/|$)'){return $false}
        & git -C $Root ls-files --error-unmatch -- $path 1>$null 2>$null
        if($LASTEXITCODE -ne 0){return $false}
        $blob=& git -C $Root rev-parse --verify "$Commit`:$path" 2>$null
        if($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$blob)){return $false}
        & git -C $Root diff --quiet --no-ext-diff $Commit -- $path 1>$null 2>$null
        if($LASTEXITCODE -ne 0){return $false}
    }
    return $true
}

function Test-BoundNativeSpecAtCommit {
    param([string]$Root,[string[]]$NativeSourcePaths,[string]$Repository,[string]$Commit,[string[]]$SpecSourcePaths)
    $required=@($NativeSourcePaths|Where-Object { $_ -cmatch '^openspec/changes/.+/specs/.+/spec\.md$' })
    if($required.Count -eq 0 -or [string]::IsNullOrWhiteSpace($Repository) -or
        @($required|Where-Object { $_ -cnotin $SpecSourcePaths }).Count -gt 0){return 'BoundSpecSourceIncomplete'}
    foreach($path in @($SpecSourcePaths|Where-Object { $_ -cin $NativeSourcePaths }|Select-Object -Unique)){
        $working=Resolve-ReviewRelativePath -Root $Root -Relative ([string]$path)
        if($null -eq $working){return 'BoundSpecSourceChanged'}
        $committed=& git -C $Repository rev-parse --verify "${Commit}:$path" 2>$null
        if($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$committed)){return 'BoundSpecSourceChanged'}
        $effective=& git -C $Repository hash-object "--path=$path" -- $working 2>$null
        if($LASTEXITCODE -ne 0 -or [string]$effective -cne [string]$committed){return 'BoundSpecSourceChanged'}
    }
    return $null
}

function Get-ReviewDigest {
    param([string[]]$Paths)
    $memory=[IO.MemoryStream]::new()
    try{
        foreach($path in $Paths){
            $name=[Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFileName($path)+"`n")
            $memory.Write($name)
            $bytes=[IO.File]::ReadAllBytes($path)
            $memory.Write($bytes)
            $memory.WriteByte(10)
        }
        return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($memory.ToArray())).ToLowerInvariant()
    }finally{$memory.Dispose()}
}

function Test-ScenarioTestCommit {
    param([string]$Repository,[string]$Commit)
    if([string]::IsNullOrWhiteSpace($Repository) -or $Commit -cnotmatch '^(?:[a-f0-9]{40}|[a-f0-9]{64})$'){return $false}
    $resolved=& git -C $Repository rev-parse --verify "$Commit`^{commit}" 2>$null
    return $LASTEXITCODE -eq 0 -and [string]$resolved -ceq $Commit
}

function Test-ScenarioTestCodeAlignment {
    param([string]$Repository,[string]$CodeCommit,[string]$TestCommit,[string[]]$RelevantPaths)
    if([string]::IsNullOrWhiteSpace($Repository) -or @($RelevantPaths).Count -eq 0 -or
        -not (Test-ScenarioTestCommit -Repository $Repository -Commit $CodeCommit) -or
        -not (Test-ScenarioTestCommit -Repository $Repository -Commit $TestCommit)){return $false}
    if($CodeCommit -ceq $TestCommit){return $true}
    & git -C $Repository diff --quiet --no-ext-diff $CodeCommit $TestCommit -- @($RelevantPaths) 2>$null
    return $LASTEXITCODE -eq 0
}

function Test-ScenarioTestArtifact {
    param([string]$Repository,[string]$Commit,[string]$TestPath,[string]$ScenarioId,[string]$TestId)
    if([string]::IsNullOrWhiteSpace($TestPath) -or $TestPath -match '[:\\\r\n]' -or
        $TestPath.StartsWith('/',[StringComparison]::Ordinal) -or
        [string]::IsNullOrWhiteSpace($ScenarioId) -or [string]::IsNullOrWhiteSpace($TestId)){return $false}
    foreach($part in ($TestPath -split '/')){if($part -in @('', '.', '..')){return $false}}
    $blob=& git -C $Repository rev-parse --verify "$Commit`:$TestPath" 2>$null
    if($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$blob)){return $false}
    $kind=& git -C $Repository cat-file -t $blob 2>$null
    if($LASTEXITCODE -ne 0 -or [string]$kind -cne 'blob'){return $false}
    $sizeText=& git -C $Repository cat-file -s $blob 2>$null
    [long]$size=0
    if($LASTEXITCODE -ne 0 -or -not [long]::TryParse([string]$sizeText,[ref]$size) -or $size -gt 1048576){return $false}
    $lines=@(& git -C $Repository cat-file -p $blob 2>$null)
    if($LASTEXITCODE -ne 0){return $false}
    $text=[string]::Join("`n",$lines)
    return $text.Contains($ScenarioId,[StringComparison]::Ordinal) -and
        $text.Contains($TestId,[StringComparison]::Ordinal)
}

function Test-ScenarioRunArtifact {
    param([string]$Root,[string]$EvidencePath,[string]$EvidenceSha256)
    if($EvidenceSha256 -cnotmatch '^[a-f0-9]{64}$'){return $false}
    $path=Resolve-ReviewRelativePath -Root $Root -Relative $EvidencePath
    if($null -eq $path){return $false}
    $actual=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    return $actual -ceq $EvidenceSha256
}

function Test-ScenarioAuxiliaryEvidence {
    param([object]$Evidence,[string]$CodeCommit,[string]$TestCommit,[string]$Root)
    if(-not(Test-Syp171JsonKeys -Value $Evidence.build -Expected @('id','codeCommit','testCommit','artifactPath','artifactSha256')) -or
        -not(Test-Syp171JsonKeys -Value $Evidence.environment -Expected @('id','artifactPath','artifactSha256')) -or
        [string]::IsNullOrWhiteSpace([string]$Evidence.build.id) -or
        [string]::IsNullOrWhiteSpace([string]$Evidence.environment.id) -or
        $Evidence.build.codeCommit -cne $CodeCommit -or $Evidence.build.testCommit -cne $TestCommit -or
        -not(Test-ScenarioRunArtifact -Root $Root -EvidencePath ([string]$Evidence.build.artifactPath) `
            -EvidenceSha256 ([string]$Evidence.build.artifactSha256)) -or
        -not(Test-ScenarioRunArtifact -Root $Root -EvidencePath ([string]$Evidence.environment.artifactPath) `
            -EvidenceSha256 ([string]$Evidence.environment.artifactSha256))){return $false}
    return $true
}

function Test-ScenarioEvidence {
    param([object]$Evidence,[string]$SpecCommit,[string]$CodeCommit,[string[]]$ScenarioIds,[string]$Root,[string]$CodeRepository,[string[]]$CodeRelevantPaths)
    $gaps=[System.Collections.Generic.List[string]]::new()
    $reported=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $legacyFixture=(Test-Syp171JsonKeys -Value $Evidence -Expected @('schemaVersion','specCommit','codeCommit','testCommit','runId','cases')) -and
        $Evidence.schemaVersion -eq 1 -and [string]$Evidence.runId -like 'synthetic-*'
    $versioned=(Test-Syp171JsonKeys -Value $Evidence -Expected @('schemaVersion','specCommit','codeCommit','testCommit','runId','build','environment','cases')) -and
        $Evidence.schemaVersion -eq 2 -and -not [string]::IsNullOrWhiteSpace([string]$Evidence.runId)
    $provenanceOk=$legacyFixture -or ($versioned -and
        (Test-ScenarioAuxiliaryEvidence -Evidence $Evidence -CodeCommit $CodeCommit -TestCommit ([string]$Evidence.testCommit) -Root $Root))
    $revisionOk=$provenanceOk -and $Evidence.specCommit -ceq $SpecCommit -and $Evidence.codeCommit -ceq $CodeCommit -and
        (Test-ScenarioTestCodeAlignment -Repository $CodeRepository -CodeCommit $CodeCommit -TestCommit ([string]$Evidence.testCommit) -RelevantPaths $CodeRelevantPaths) -and $Evidence.cases -is [array]
    if($revisionOk){
        foreach($case in @($Evidence.cases)){
            if(-not(Test-Syp171JsonKeys -Value $case -Expected @('scenarioId','testId','testPath','result','evidencePath','evidenceSha256')) -or
                $case.result -cne 'passed' -or [string]::IsNullOrWhiteSpace([string]$case.testId) -or
                -not (Test-ScenarioTestArtifact -Repository $CodeRepository -Commit ([string]$Evidence.testCommit) `
                    -TestPath ([string]$case.testPath) -ScenarioId ([string]$case.scenarioId) -TestId ([string]$case.testId)) -or
                -not (Test-ScenarioRunArtifact -Root $Root -EvidencePath ([string]$case.evidencePath) `
                    -EvidenceSha256 ([string]$case.evidenceSha256)) -or
                -not $reported.Add([string]$case.scenarioId)){continue}
        }
    }
    foreach($id in $ScenarioIds){if(-not $revisionOk -or -not $reported.Contains($id)){$gaps.Add($id)}}
    return @($gaps.ToArray())
}

function Invoke-ConfluenceValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$MappingPath,
        [Parameter(Mandatory)][string]$DocsCommit,
        [Parameter(Mandatory)][string]$CodeBindingPath,
        [Parameter(Mandatory)][string]$ReviewPath,
        [Parameter(Mandatory)][string]$RuntimeRoot
    )
    if(-not(Test-Path -LiteralPath $Root -PathType Container) -or -not(Test-Path -LiteralPath $ReviewPath -PathType Leaf)){
        return New-ValidationResult -Status 'invalid' -ReasonCodes @('ValidationInputUnavailable') -Fields $null
    }
    $rootFull=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path)
    try{$mappingData=Read-Syp171StrictJsonFile -Path $MappingPath -Depth 15}
    catch{return New-ValidationResult -Status 'invalid' -ReasonCodes @('MappingSchemaInvalid') -Fields $null}
    $mapping=Test-ConfluenceMapping -Root $rootFull -MappingPath $MappingPath -ExpectedSiteOrigin ([string]$mappingData.siteOrigin)
    if($mapping.status -cne 'valid'){return New-ValidationResult -Status 'invalid' -ReasonCodes $mapping.reasonCodes -Fields $null}
    $changes=@($mapping.entries|ForEach-Object{
        if($_.sourceArtifact -match '^openspec/changes/(?<change>[a-z][a-z0-9-]+)/'){$Matches.change}else{''}
    }|Select-Object -Unique)
    if($changes.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$changes[0])){
        return New-ValidationResult -Status 'invalid' -ReasonCodes @('MappingChangeUnknown') -Fields $null
    }
    $changeId=[string]$changes[0]
    $native=Test-OpenSpecSource -Root $rootFull -ChangeId $changeId -RuntimeRoot $RuntimeRoot
    if($native.status -cne 'valid'){return New-ValidationResult -Status 'invalid' -ReasonCodes $native.reasonCodes -Fields $null}
    if(-not(Test-SourceAtCommit -Root $rootFull -Commit $DocsCommit -SourcePaths @($native.sourcePaths))){
        return New-ValidationResult -Status 'blocked' -ReasonCodes @('CommittedSourceChanged') -Fields @{changeId=$changeId}
    }
    $ids=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($item in @($native.requirements)+@($native.scenarios)){$ids.Add([string]$item.id)|Out-Null}
    foreach($entry in @($mapping.entries)){
        if(-not $ids.Contains([string]$entry.sourceSectionId) -or [string]$entry.sourceArtifact -cnotin @($native.sourcePaths)){
            return New-ValidationResult -Status 'invalid' -ReasonCodes @('MappingSectionUnknown') -Fields @{changeId=$changeId}
        }
    }
    try{$dossier=Read-Syp171StrictJsonFile -Path $ReviewPath -Depth 15}
    catch{return New-ValidationResult -Status 'invalid' -ReasonCodes @('ReviewDossierInvalid') -Fields @{changeId=$changeId}}
    if(-not(Test-Syp171JsonKeys -Value $dossier -Expected @('schemaVersion','capturePath','importReviewPath','codeReviewPath','scenarioEvidencePath','approvalStatus','implementationStatus')) -or
        $dossier.schemaVersion -ne 1 -or $dossier.approvalStatus -notin @('approved','proposed','unknown') -or
        $dossier.implementationStatus -notin @('implemented','proposed','unknown')){
        return New-ValidationResult -Status 'invalid' -ReasonCodes @('ReviewDossierInvalid') -Fields @{changeId=$changeId}
    }
    $capturePath=Resolve-ReviewRelativePath -Root $rootFull -Relative ([string]$dossier.capturePath)
    $importReviewPath=Resolve-ReviewRelativePath -Root $rootFull -Relative ([string]$dossier.importReviewPath)
    $scenarioEvidencePath=Resolve-ReviewRelativePath -Root $rootFull -Relative ([string]$dossier.scenarioEvidencePath)
    $codeReviewPath=$null
    if(-not [string]::IsNullOrWhiteSpace([string]$dossier.codeReviewPath)){
        $codeReviewPath=Resolve-ReviewRelativePath -Root $rootFull -Relative ([string]$dossier.codeReviewPath)
    }
    if($null -eq $capturePath -or $null -eq $importReviewPath -or $null -eq $scenarioEvidencePath -or
        (-not [string]::IsNullOrWhiteSpace([string]$dossier.codeReviewPath) -and $null -eq $codeReviewPath)){
        return New-ValidationResult -Status 'invalid' -ReasonCodes @('ReviewReferenceInvalid') -Fields @{changeId=$changeId}
    }
    $import=Test-ConfluenceImportReview -CapturePath $capturePath -ReviewPath $importReviewPath
    if($import.status -cne 'valid'){return New-ValidationResult -Status 'blocked' -ReasonCodes $import.reasonCodes -Fields @{changeId=$changeId}}
    try{$capture=Read-Syp171StrictJsonFile -Path $capturePath -Depth 20}
    catch{return New-ValidationResult -Status 'invalid' -ReasonCodes @('ReviewDossierInvalid') -Fields @{changeId=$changeId}}
    if($capture.siteOrigin -cne $mappingData.siteOrigin -or
        (($capture.Keys -contains 'cloudId') -and $capture['cloudId'] -cne $mappingData.cloudId)){
        return New-ValidationResult -Status 'blocked' -ReasonCodes @('TenantMismatch') -Fields @{changeId=$changeId}
    }
    $bindingArgs=@{Root=$rootFull;BindingPath=$CodeBindingPath}
    if($null -ne $codeReviewPath){$bindingArgs.ReviewPath=$codeReviewPath}
    $binding=Resolve-ConfluenceCodeBinding @bindingArgs
    if($binding.status -cne 'valid'){return New-ValidationResult -Status $binding.status -ReasonCodes $binding.reasonCodes -Fields @{changeId=$changeId}}
    if($binding.docsCommit -cne $DocsCommit){return New-ValidationResult -Status 'blocked' -ReasonCodes @('DocsBindingMismatch') -Fields @{changeId=$changeId}}
    $boundSpecProblem=Test-BoundNativeSpecAtCommit -Root $rootFull -NativeSourcePaths @($native.sourcePaths) `
        -Repository $binding.specRepository -Commit $binding.specCommit -SpecSourcePaths @($binding.specSourcePaths)
    if($null -ne $boundSpecProblem){
        return New-ValidationResult -Status 'blocked' -ReasonCodes @($boundSpecProblem) -Fields @{changeId=$changeId}
    }
    try{$evidence=Read-Syp171StrictJsonFile -Path $scenarioEvidencePath -Depth 12}
    catch{$evidence=$null}
    $scenarioIds=@($native.scenarios|ForEach-Object id)
    $gaps=@(Test-ScenarioEvidence -Evidence $evidence -SpecCommit $binding.specCommit -CodeCommit $binding.codeCommit -ScenarioIds $scenarioIds -Root $rootFull -CodeRepository $binding.codeRepository -CodeRelevantPaths @($binding.codeRelevantPaths))
    $acceptance=if($gaps.Count -gt 0){'incomplete'}elseif([string]$evidence.runId -like 'synthetic-*'){'fixture-evidence-only'}else{'evidence-reported-complete'}
    $reviewPaths=@($ReviewPath,$capturePath,$importReviewPath,$scenarioEvidencePath)
    if($null -ne $codeReviewPath){$reviewPaths+=@($codeReviewPath)}
    if((Test-Syp171JsonKeys -Value $evidence -Expected @('schemaVersion','specCommit','codeCommit','testCommit','runId','build','environment','cases')) -and
        $evidence.schemaVersion -eq 2){
        foreach($artifact in @($evidence.build,$evidence.environment)){
            if($artifact -isnot [System.Collections.IDictionary]){continue}
            $path=Resolve-ReviewRelativePath -Root $rootFull -Relative ([string]$artifact.artifactPath)
            if($null -ne $path -and $path -cnotin $reviewPaths){$reviewPaths+=@($path)}
        }
    }
    if($null -ne $evidence -and $evidence -is [System.Collections.IDictionary] -and $evidence.cases -is [array]){
        foreach($case in @($evidence.cases | Sort-Object -Property evidencePath -CaseSensitive)){
            if($case -isnot [System.Collections.IDictionary]){continue}
            $path=Resolve-ReviewRelativePath -Root $rootFull -Relative ([string]$case.evidencePath)
            if($null -ne $path -and $path -cnotin $reviewPaths){$reviewPaths+=@($path)}
        }
    }
    $reviewDigest=Get-ReviewDigest -Paths $reviewPaths
    $operational=@($MappingPath,$CodeBindingPath,$ReviewPath,$importReviewPath,$scenarioEvidencePath)
    $metadataCommitted=$true
    foreach($path in $operational){
        $rel=[IO.Path]::GetRelativePath($rootFull,[IO.Path]::GetFullPath($path))
        if($rel -eq '..' -or $rel.StartsWith("..$([IO.Path]::DirectorySeparatorChar)",[StringComparison]::Ordinal)){$metadataCommitted=$false;break}
        & git -C $rootFull ls-files --error-unmatch -- $rel 1>$null 2>$null
        if($LASTEXITCODE -ne 0){$metadataCommitted=$false;break}
        & git -C $rootFull diff --quiet --no-ext-diff HEAD -- $rel 1>$null 2>$null
        if($LASTEXITCODE -ne 0){$metadataCommitted=$false;break}
    }
    $eligibility=if($metadataCommitted -and $acceptance -ne 'fixture-evidence-only'){'candidate'}else{'preview-only'}
    return New-ValidationResult -Status 'valid' -ReasonCodes @() -Fields @{
        siteOrigin=[string]$mappingData.siteOrigin;cloudId=[string]$mappingData.cloudId
        docsCommit=$DocsCommit;specCommit=$binding.specCommit;codeCommit=$binding.codeCommit
        sourceDigest=$native.sourceDigest;mappingDigest=$mapping.mappingSha256;reviewDigest=$reviewDigest
        validatorVersion=$native.validatorVersion;scenarioIds=$scenarioIds;coverageGaps=@($gaps)
        scenarioAcceptance=$acceptance;publishEligibility=$eligibility
        approvalStatus=$dossier.approvalStatus;implementationStatus=$dossier.implementationStatus;changeId=$changeId
    }
}

Export-ModuleMember -Function Invoke-ConfluenceValidation
