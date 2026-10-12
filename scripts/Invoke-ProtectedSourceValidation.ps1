# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.2

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('PrepareSourceTools','SourceValidation')][string] $Mode,
    [Parameter(Mandatory)][string] $RepositoryRoot,
    [Parameter(Mandatory)][string] $ArtifactsRoot,
    [Parameter(Mandatory)][string] $AuthorityRepositoryRoot,
    [Parameter(Mandatory)][string] $TrustedToolRoot,
    [Parameter(Mandatory)][string] $SourceToolsPath,
    [string] $BaseCommit,
    [string] $ExpectedGoRuntimeVersion,
    [string] $ExpectedSourceToolsSha256,
    [string] $OutputPath,
    [ValidateRange(1,14400)][int] $OperationTimeoutSeconds = 14400,
    [ValidateRange(1,3600)][int] $TimeoutSeconds = 3600
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'StandardCoreSourcePreparation.psm1') -Force -ErrorAction Stop
Import-Module -Name (Join-Path $PSScriptRoot 'CorePesterIntegrity.psm1') -Force -ErrorAction Stop
$script:ReviewedE1BaselineSha256 = '1cca364cf34927eea12b28395ac7135ca706a689bf3d55ae5218fe051c5729fe'

function Assert-ProtectedSourceRuntimeClosure {
    param([Parameter(Mandatory)][string] $PlanPath, [Parameter(Mandatory)][string] $ExpectedPlanSha256,
          [Parameter(Mandatory)][string] $OwnedRoot, [Parameter(Mandatory)][string] $SupervisorExecutable)
    $comparison = [StringComparison]::OrdinalIgnoreCase
    $ownedPrefix = [IO.Path]::GetFullPath($OwnedRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ([IO.Path]::GetFullPath($SupervisorExecutable).StartsWith($ownedPrefix,$comparison)) { throw 'SourceValidation supervisor must run outside the owned runtime root.' }
    $planItem = Get-Item -LiteralPath $PlanPath -Force -ErrorAction Stop
    if ($planItem.PSIsContainer -or ($planItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $planItem.Length -gt 33554432) { throw 'Prepared source plan is unsafe or exceeds its size limit.' }
    # Read and authenticate the same bounded bytes; do not reopen a mutable plan after hashing.
    $stream=[IO.File]::Open($PlanPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        if($stream.Length -gt 33554432) { throw 'Prepared source plan exceeds its size limit.' }
        $bytes=[byte[]]::new([int]$stream.Length);$offset=0
        while($offset -lt $bytes.Length) {
            $read=$stream.Read($bytes,$offset,$bytes.Length-$offset)
            if($read -eq 0) { throw 'Prepared source plan is truncated.' }
            $offset += $read
        }
    } finally { $stream.Dispose() }
    $actualSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    if($ExpectedPlanSha256 -cnotmatch '^[0-9a-f]{64}$' -or $actualSha -cne $ExpectedPlanSha256) { throw 'Prepared source plan SHA differs from the trusted preparation output.' }
    $bom=if($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF){3}else{0}
    $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes,$bom,$bytes.Length-$bom)
    $document=[System.Text.Json.JsonDocument]::Parse($text)
    try {
        $checkDuplicate={param([System.Text.Json.JsonElement]$Element)
            if($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
                $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                foreach($property in $Element.EnumerateObject()) {
                    if(-not $names.Add($property.Name)) { throw 'Prepared source plan contains a duplicate JSON property.' }
                    & $checkDuplicate $property.Value
                }
            } elseif($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) { foreach($item in $Element.EnumerateArray()){ & $checkDuplicate $item } }
        }
        & $checkDuplicate $document.RootElement
    } finally { $document.Dispose() }
    $prepared=ConvertFrom-Json -InputObject $text -Depth 60 -ErrorAction Stop
    $exe = [IO.Path]::GetFullPath([string]$prepared.runtimeExecutable)
    if (-not $exe.StartsWith($ownedPrefix,$comparison) -or [IO.Path]::GetFileName($exe) -ine 'pwsh.exe') { throw 'Prepared PowerShell executable is outside the owned runtime.' }
    $runtimeRoot = Split-Path -Parent $exe
    $runtimePrefix = $runtimeRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $expected = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($record in $prepared.sourceValidation.frozenFiles) {
        $path = [IO.Path]::GetFullPath([string]$record.path)
        if ($path.StartsWith($runtimePrefix,$comparison)) {
            if ([string]$record.sha256 -cnotmatch '^[0-9a-f]{64}$' -or $expected.ContainsKey($path)) { throw 'Prepared runtime closure contains an invalid or duplicate record.' }
            $expected.Add($path,[string]$record.sha256)
        }
    }
    if (-not $expected.ContainsKey($exe)) { throw 'Prepared runtime closure omits its executable.' }
    $pending=[Collections.Generic.Stack[string]]::new();$pending.Push($runtimeRoot);$actualCount=0
    while($pending.Count -gt 0) {
        $directory=$pending.Pop()
        $directoryItem=Get-Item -LiteralPath $directory -Force -ErrorAction Stop
        if($directoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'PowerShell runtime closure contains a reparse point.' }
        foreach($path in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
            $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'PowerShell runtime closure contains a reparse point.' }
            if($item.PSIsContainer){$pending.Push($item.FullName);continue}
            $actualCount++
            if($actualCount -gt 10000 -or -not $expected.ContainsKey($item.FullName) -or (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expected[$item.FullName]) { throw 'PowerShell runtime closure changed before owned runtime launch.' }
        }
    }
    if($actualCount -ne $expected.Count) { throw 'PowerShell runtime closure changed: a prepared dependency is missing.' }
    return $prepared
}

function Get-Sha([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() }
function Test-Within([string]$Path,[string]$Root) {
    $p=[IO.Path]::GetFullPath($Path); $r=[IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $c=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    return $p.Equals($r,$c) -or $p.StartsWith($r+[IO.Path]::DirectorySeparatorChar,$c)
}
function Assert-Outside([string]$Path,[string]$Root,[string]$Context) { if(Test-Within $Path $Root){throw "$Context must be outside the protected root."} }
function Write-CreateNew([string]$Path,[string]$Text) {
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes($Text)
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}
function Write-JsonCreateNew([string]$Path,$Value) { Write-CreateNew $Path ((ConvertTo-Json -InputObject $Value -Depth 80)+"`n") }
function Get-Revision([string]$Git,[string]$Root,[string]$Revision,[string]$Context) {
    $r=Invoke-StandardCoreV2GitText -GitPath $Git -Arguments @('--no-replace-objects','-C',$Root,'rev-parse','--verify','--end-of-options',"$Revision^{commit}")
    $v=$r.StdOut.Trim(); if($v -cnotmatch '^[0-9a-f]{40}$'){throw "$Context is not one full SHA-1 commit."}; return $v
}
function Get-EventName {
    switch ([string]$env:GITHUB_EVENT_NAME) {'pull_request'{'pull_request'} 'push'{'push'} 'workflow_dispatch'{'workflow_dispatch'} 'pre-push'{'pre-push'} default{'local'}}
}
function Add-Frozen([Collections.Generic.List[object]]$List,[Collections.Generic.HashSet[string]]$Seen,[string]$Path) {
    $full=[IO.Path]::GetFullPath($Path); Assert-StandardCoreV2NoReparseAncestors -Path $full -Context 'Frozen source file'
    if(-not $Seen.Add($full)){return}; $item=Get-Item -LiteralPath $full -Force
    if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw "Frozen source file is not a regular file: $full"}
    $List.Add([pscustomobject]@{path=$full;sha256=(Get-Sha $full)})
}
function Assert-PlanPath([string]$Path,[string]$Root,[string]$Context) {
    $full=[IO.Path]::GetFullPath($Path); if(-not (Test-Within $full $Root)){throw "$Context is outside its expected root."}; return $full
}
function Test-PathEqual([string]$Left,[string]$Right) {
    $comparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    return [IO.Path]::GetFullPath($Left).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar).Equals(
        [IO.Path]::GetFullPath($Right).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar),$comparison)
}
function New-ProtectedEventBaseDriverFiles {
    param(
        [Parameter(Mandatory)][string] $GitPath,
        [Parameter(Mandatory)][string] $ProtectedRepositoryRoot,
        [Parameter(Mandatory)][string] $SourceScriptsRoot,
        [Parameter(Mandatory)][string] $DestinationRoot,
        [Parameter(Mandatory)][string[]] $DriverNames,
        [string] $ExpectedBaselineSha256,
        [switch] $ValidateOnly
    )
    $protectedRoot=[IO.Path]::GetFullPath($ProtectedRepositoryRoot)
    $sourceRoot=[IO.Path]::GetFullPath($SourceScriptsRoot)
    $destinationRoot=[IO.Path]::GetFullPath($DestinationRoot)
    Assert-StandardCoreV2NoReparseAncestors -Path $protectedRoot -Context 'Protected event-base repository root'
    Assert-StandardCoreV2NoReparseAncestors -Path $sourceRoot -Context 'Protected event-base scripts root'
    Assert-StandardCoreV2NoReparseAncestors -Path $destinationRoot -Context 'Protected driver copy root'
    $protectedRevision=Get-Revision $GitPath $protectedRoot 'HEAD' 'Protected driver revision'
    $protectedTree=Get-StandardCoreV2GitTree -GitPath $GitPath -Root $protectedRoot -Revision $protectedRevision
    $records=[Collections.Generic.List[object]]::new()
    foreach($name in $DriverNames){
        if($name -cnotmatch '^[A-Za-z0-9._-]+\.(?:ps1|psm1|json)$'){throw 'Protected driver inventory contains an unsafe source filename.'}
        $relativePath="scripts/$name"
        if(-not $protectedTree.ContainsKey($relativePath)){throw "Protected event-base commit omits driver source '$relativePath'."}
        $sourcePath=Join-Path $sourceRoot $name
        Assert-StandardCoreV2NoReparseAncestors -Path $sourcePath -Context "Protected event-base driver source '$name'"
        $workingTreeDiff=Invoke-StandardCoreV2GitText -GitPath $GitPath `
            -Arguments @('--no-replace-objects','-C',$protectedRoot,'diff','--quiet',$protectedRevision,'--',$relativePath) -AllowedExitCodes @(0,1)
        if($workingTreeDiff.ExitCode -ne 0){throw "Protected driver source has uncommitted content or mode changes: $relativePath"}
        $entry=$protectedTree[$relativePath]
        $sourceHash=Get-StandardCoreV2GitBlobSha256 -GitPath $GitPath -RepositoryRoot $protectedRoot -ObjectId ([string]$entry.objectId)
        if($name -ceq 'SkillSpectorReviewedE1Baselines.json' -and
            (-not [string]::IsNullOrWhiteSpace($ExpectedBaselineSha256) -and $sourceHash -cne $ExpectedBaselineSha256)){
            throw 'Protected reviewed E1 policy differs from the pinned review artifact.'
        }
        $destinationPath=[IO.Path]::GetFullPath((Join-Path $destinationRoot $name))
        if(-not (Test-PathEqual -Left (Split-Path -Parent $destinationPath) -Right $destinationRoot)){
            throw 'Protected driver copy path is not a direct child of the run-owned driver root.'
        }
        if($ValidateOnly){
            Assert-StandardCoreV2NoReparseAncestors -Path $destinationPath -Context "Protected driver copy '$name'"
            if((Get-Sha $destinationPath) -cne $sourceHash){throw "Protected driver copy differs from its raw event-base Git blob: $name"}
        }
        else{
            Write-StandardCoreV2GitBlob -GitPath $GitPath -RepositoryRoot $protectedRoot -ObjectId ([string]$entry.objectId) -Destination $destinationPath
            if((Get-Sha $destinationPath) -cne $sourceHash){throw "Protected driver copy differs from its raw event-base Git blob: $name"}
        }
        $records.Add([pscustomobject]@{name=$name;path=$destinationPath;sha256=$sourceHash})
    }
    return @($records.ToArray())
}
function New-ProtectedCandidateFilePins {
    param(
        [Parameter(Mandatory)][string] $GitPath,
        [Parameter(Mandatory)][string] $ProtectedRepositoryRoot,
        [Parameter(Mandatory)][string] $ProtectedDriverRoot,
        [Parameter(Mandatory)][object[]] $ProtectedDriverFiles,
        [Parameter(Mandatory)][string] $CandidateRoot,
        [Parameter(Mandatory)][string] $CandidateRevision
    )
    $protectedRoot=[IO.Path]::GetFullPath($ProtectedRepositoryRoot)
    $protectedRevision=Get-Revision $GitPath $protectedRoot 'HEAD' 'Protected driver revision'
    $protectedTree=Get-StandardCoreV2GitTree -GitPath $GitPath -Root $protectedRoot -Revision $protectedRevision
    $pins=[Collections.Generic.List[object]]::new()
    foreach($relativePath in @('scripts/Invoke-CoreRepositoryGeneral.ps1','scripts/Invoke-CorePester.ps1',
            'scripts/CorePesterIntegrity.psm1','scripts/StandardCoreSourcePreparation.psm1','scripts/Test-Repository.ps1')){
        if(-not $protectedTree.ContainsKey($relativePath)){throw "Protected event-base commit omits critical runner input '$relativePath'."}
        $entry=$protectedTree[$relativePath]
        $expectedSha=Get-StandardCoreV2GitBlobSha256 -GitPath $GitPath -RepositoryRoot $protectedRoot -ObjectId ([string]$entry.objectId)
        $name=[IO.Path]::GetFileName($relativePath)
        $driverRecord=@($ProtectedDriverFiles | Where-Object { [string]$_.name -ceq $name })
        $protectedCopy=[IO.Path]::GetFullPath((Join-Path $ProtectedDriverRoot $name))
        if($driverRecord.Count -ne 1 -or -not (Test-PathEqual -Left ([string]$driverRecord[0].path) -Right $protectedCopy) -or
            [string]$driverRecord[0].sha256 -cne $expectedSha -or (Get-Sha $protectedCopy) -cne $expectedSha){
            throw "Protected driver file differs from the event-base Git blob: $relativePath"
        }
        $pins.Add([pscustomobject]@{candidatePath=$relativePath;protectedPath=$protectedCopy;expectedMode=[string]$entry.mode;expectedSha256=$expectedSha})
    }
    [void](Assert-StandardCoreV2ProtectedCandidateFiles -GitPath $GitPath -CandidateRoot $CandidateRoot `
        -ExpectedRevision $CandidateRevision -ProtectedFiles @($pins.ToArray()))
    return @($pins.ToArray())
}
function Invoke-StandardCoreSupervisedProcess {
    param(
        [Parameter(Mandatory)][string] $RunnerPath,
        [Parameter(Mandatory)][string] $CandidateRoot,
        [Parameter(Mandatory)][string] $AdapterPath,
        [Parameter(Mandatory)][string] $ArtifactsRoot,
        [Parameter(Mandatory)][string] $SourceRepository,
        [Parameter(Mandatory)][string] $SourceRevision,
        [Parameter(Mandatory)][string] $AuthorityRevision,
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $TrustedToolRoot,
        [Parameter(Mandatory)][string] $PowerShell,
        [Parameter(Mandatory)][string[]] $Arguments,
        [Parameter(Mandatory)][string] $WorkingDirectory,
        [Parameter(Mandatory)][string] $OwnedRoot,
        [Parameter(Mandatory)][int] $LimitSeconds
    )
    return & {
        param($Runner,$Candidate,$Adapter,$Artifacts,$Repository,$Revision,$Authority,$Run,$Trusted,$HostPath,$ChildArgs,$Working,$Owned,$Limit)
        . $Runner -DefineFunctionsOnly -CandidateRoot $Candidate -AdapterPath $Adapter -ArtifactsRoot $Artifacts `
            -SourceRepository $Repository -SourceRevision $Revision -BaseRevision $Revision -AuthorityRevision $Authority `
            -RunId $Run -TimeoutSeconds $Limit -TrustedToolRoot $Trusted
        Invoke-StandardValidationProcess -Command $HostPath -Arguments $ChildArgs -WorkingDirectory $Working `
            -Environment @{STANDARD_VALIDATION_RUN_OWNED_ROOT=$Owned} -TimeoutSeconds $Limit -CoreLifecycleOnly
    } $RunnerPath $CandidateRoot $AdapterPath $ArtifactsRoot $SourceRepository $SourceRevision $AuthorityRevision `
        $RunId $TrustedToolRoot $PowerShell $Arguments $WorkingDirectory $OwnedRoot $LimitSeconds
}
function Invoke-StandardCoreSourcePlanIntegrity {
    param(
        [Parameter(Mandatory)][string] $RunnerPath,
        [Parameter(Mandatory)][string] $CandidateRoot,
        [Parameter(Mandatory)][string] $AdapterPath,
        [Parameter(Mandatory)][string] $ArtifactsRoot,
        [Parameter(Mandatory)][string] $SourceRepository,
        [Parameter(Mandatory)][string] $SourceRevision,
        [Parameter(Mandatory)][string] $AuthorityRevision,
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $TrustedToolRoot,
        [Parameter(Mandatory)][object[]] $FrozenFiles,
        [Parameter(Mandatory)][object[]] $ToolReceipts
    )
    return & {
        param($Runner,$Candidate,$Adapter,$Artifacts,$Repository,$Revision,$Authority,$Run,$Trusted,$Frozen,$Receipts)
        . $Runner -DefineFunctionsOnly -CandidateRoot $Candidate -AdapterPath $Adapter -ArtifactsRoot $Artifacts `
            -SourceRepository $Repository -SourceRevision $Revision -BaseRevision $Revision -AuthorityRevision $Authority `
            -RunId $Run -TrustedToolRoot $Trusted
        Assert-StandardCoreFrozenFiles -Files $Frozen
        Assert-StandardCoreSourceToolReceipts -Bindings $Receipts -FrozenFiles $Frozen -RunId $Run `
            -CandidateRoot $Candidate -ArtifactsRoot $Artifacts
        return $true
    } $RunnerPath $CandidateRoot $AdapterPath $ArtifactsRoot $SourceRepository $SourceRevision $AuthorityRevision $RunId `
        $TrustedToolRoot $FrozenFiles $ToolReceipts
}
function Invoke-StandardCoreSourceReportReplay {
    param(
        [Parameter(Mandatory)][string] $RunnerPath,
        [Parameter(Mandatory)][string] $CandidateRoot,
        [Parameter(Mandatory)][string] $AdapterPath,
        [Parameter(Mandatory)][string] $ArtifactsRoot,
        [Parameter(Mandatory)][string] $SourceRepository,
        [Parameter(Mandatory)][string] $SourceRevision,
        [Parameter(Mandatory)][string] $BaseRevision,
        [Parameter(Mandatory)][string] $AuthorityRevision,
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $TrustedToolRoot,
        [Parameter(Mandatory)][int] $LimitSeconds,
        [Parameter(Mandatory)] $Report,
        [Parameter(Mandatory)][string] $OutputPath,
        [Parameter(Mandatory)][string] $EventName,
        [Parameter(Mandatory)][int] $ProcessExitCode,
        [Parameter(Mandatory)][object[]] $FrozenFiles
    )
    return & {
        param($Runner,$Candidate,$Adapter,$Artifacts,$Repository,$Revision,$Base,$Authority,$Run,$Trusted,$Limit,$Value,$Output,$Event,$Exit,$Frozen)
        . $Runner -DefineFunctionsOnly -CandidateRoot $Candidate -AdapterPath $Adapter -ArtifactsRoot $Artifacts `
            -SourceRepository $Repository -SourceRevision $Revision -BaseRevision $Base -AuthorityRevision $Authority `
            -RunId $Run -TimeoutSeconds $Limit -TrustedToolRoot $Trusted
        Assert-StandardCoreFrozenFiles -Files $Frozen
        Assert-StandardCoreSourceCheckReport -Report $Value -ExpectedSourceRevision $Revision -ExpectedBaseRevision $Base `
            -ExpectedAuthorityRevision $Authority -ExpectedEventName $Event -ArtifactsRoot $Artifacts -OutputPath $Output -ProcessExitCode $Exit
        return $true
    } $RunnerPath $CandidateRoot $AdapterPath $ArtifactsRoot $SourceRepository $SourceRevision $BaseRevision $AuthorityRevision `
        $RunId $TrustedToolRoot $LimitSeconds $Report $OutputPath $EventName $ProcessExitCode $FrozenFiles
}
function Assert-StandardCoreV2DomainAdapterEvent {
    param(
        [Parameter(Mandatory)] $Envelope,
        [Parameter(Mandatory)] $Event,
        [Parameter(Mandatory)] $CoreReport,
        [Parameter(Mandatory)] $Plan,
        [Parameter(Mandatory)] $Toolchain,
        [Parameter(Mandatory)][string] $ExpectedPackageRoot,
        [Parameter(Mandatory)][string] $MetadataRoot
    )
    $domain = $Envelope.domainAdapterResult
    Assert-StandardCoreV2ExactProperties -Value $domain -Names @('status','decision','result','upstreamReportPath','upstreamReportSha256','upstreamReport',
        'upstreamCommand','upstreamCommandSha256','upstreamArguments','upstreamExitCode','sourceArchivePath','sourceArchiveSha256','sourceArchiveLength',
        'sourceRepository','sourceRevision') -Context 'Domain adapter event'
    if ([string]$domain.status -cne 'passed' -or [string]$domain.decision -cne 'PASS' -or
        [string]$domain.result -cne 'atlassian-ecosystem-source-adapter' -or [int]$domain.upstreamExitCode -ne 0 -or
        [string]$domain.sourceRepository -cne [string]$Toolchain.sourceRepository -or
        [string]$domain.sourceRevision -cne [string]$Plan.sourceRevision -or
        [string]$domain.sourceArchiveSha256 -cne [string]$Toolchain.sourceArchiveSha256 -or
        [long]$domain.sourceArchiveLength -ne [long]$Toolchain.sourceArchiveLength -or
        -not (Test-PathEqual -Left ([string]$domain.sourceArchivePath) -Right ([string]$Toolchain.sourceArchivePath))) {
        throw 'Domain adapter event does not bind the validated source repository, revision, archive, and successful evaluation.'
    }
    if (-not (Test-PathEqual -Left ([string]$domain.upstreamCommand) -Right ([string]$Toolchain.runtimeExecutable)) -or
        [string]$domain.upstreamCommandSha256 -cne [string]$Toolchain.runtimeSha256 -or
        (Get-Sha ([string]$domain.upstreamCommand)) -cne [string]$Toolchain.runtimeSha256) { throw 'Domain adapter event command or runtime hash differs from the frozen runtime.' }
    $expectedArguments=@('-NoLogo','-NoProfile','-NonInteractive','-File',[string]$Toolchain.upstreamAdapterValidatorPath,
        '-PackageRoot',[IO.Path]::GetFullPath($ExpectedPackageRoot),'-PolicyPath',[string]$Toolchain.upstreamPolicyPath,
        '-SourceRepository',[string]$Toolchain.sourceRepository,'-SourceRevision',[string]$Plan.sourceRevision,
        '-ArchiveSha256',[string]$Toolchain.sourceArchiveSha256,'-OutputPath',[string]$domain.upstreamReportPath)
    if ($domain.upstreamArguments -isnot [array] -or @($domain.upstreamArguments).Count -ne $expectedArguments.Count) { throw 'Domain adapter argument inventory is malformed.' }
    for ($index=0; $index -lt $expectedArguments.Count; $index++) {
        if ([string]$domain.upstreamArguments[$index] -cne [string]$expectedArguments[$index]) { throw 'Domain adapter arguments differ from the exact frozen ff85 invocation.' }
    }
    $runRoot=[IO.Path]::GetFullPath([string]$CoreReport.artifacts.runRoot)
    $eventPath=[IO.Path]::GetFullPath([string]$Event.outputPath)
    $expectedEventRoot=[IO.Path]::GetFullPath((Join-Path $runRoot 'package-validation'))
    $reportPath=[IO.Path]::GetFullPath([string]$domain.upstreamReportPath)
    $childRoot=[IO.Path]::GetFullPath((Split-Path -Parent $reportPath))
    $childrenRoot=[IO.Path]::GetFullPath((Join-Path $runRoot 'source-children'))
    if (-not (Test-PathEqual -Left (Split-Path -Parent $eventPath) -Right $expectedEventRoot) -or
        [IO.Path]::GetFileName($eventPath) -cne "event-$([string]$Event.eventId).json" -or
        -not (Test-PathEqual -Left (Split-Path -Parent $childRoot) -Right $childrenRoot) -or
        [IO.Path]::GetFileName($childRoot) -cnotmatch '^[0-9a-f]{32}$' -or
        -not (Test-Within -Path ([string]$domain.upstreamReportPath) -Root $childRoot) -or
        [IO.Path]::GetFileName($reportPath) -cnotmatch "^upstream-adapter-report-$([string]$Plan.runId)-[0-9a-f]{32}\.json$") {
        throw 'Domain adapter raw report path is outside its exact run-owned child working root.'
    }
    Assert-StandardCoreV2NoReparseAncestors -Path ([string]$domain.upstreamReportPath) -Context 'Domain adapter raw report'
    $archiveRecords=@($Plan.sourceValidation.frozenFiles | Where-Object {
        (Test-PathEqual -Left ([string]$_.path) -Right ([string]$Toolchain.sourceArchivePath)) -and [string]$_.sha256 -ceq [string]$Toolchain.sourceArchiveSha256
    })
    if ($archiveRecords.Count -ne 1 -or (Get-Sha ([string]$Toolchain.sourceArchivePath)) -cne [string]$Toolchain.sourceArchiveSha256 -or
        (Get-Item -LiteralPath ([string]$Toolchain.sourceArchivePath)).Length -ne [long]$Toolchain.sourceArchiveLength) { throw 'Domain adapter source archive is not exactly frozen.' }
    $expectedMetadataRoot=[IO.Path]::GetFullPath($MetadataRoot)
    $git=(Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path
    $replayPath=Join-Path (Split-Path -Parent ([string]$Toolchain.sourceArchivePath)) "source-archive-report-replay-$([string]$Plan.runId)-$([guid]::NewGuid().ToString('N')).tar"
    $replayedArchive=New-StandardCoreV2GitArchive -GitPath $git -RepositoryRoot $expectedMetadataRoot `
        -OwnedRoot (Split-Path -Parent ([string]$Toolchain.sourceArchivePath)) -Destination $replayPath -Revision ([string]$Plan.sourceRevision)
    if ([string]$replayedArchive.sha256 -cne [string]$Toolchain.sourceArchiveSha256 -or [long]$replayedArchive.length -ne [long]$Toolchain.sourceArchiveLength) {
        throw 'Domain adapter archive does not replay from the bound Git metadata revision.'
    }
    if ((Get-Sha ([string]$domain.upstreamReportPath)) -cne [string]$domain.upstreamReportSha256) { throw 'Domain adapter raw report hash differs from its event binding.' }
    $rawUpstream=Read-StandardCoreV2StrictJson -Path ([string]$domain.upstreamReportPath) -Context 'Domain adapter raw report'
    if ((ConvertTo-Json -InputObject $rawUpstream -Depth 60 -Compress) -cne (ConvertTo-Json -InputObject $domain.upstreamReport -Depth 60 -Compress)) {
        throw 'Domain adapter report bytes differ from the embedded report.'
    }
    [void](Assert-StandardCoreV2UpstreamAdapterReport -Report $rawUpstream -ExpectedPackageRoot $ExpectedPackageRoot `
        -ExpectedSourceRepository ([string]$Toolchain.sourceRepository) -ExpectedSourceRevision ([string]$Plan.sourceRevision) `
        -ExpectedArchiveSha256 ([string]$Toolchain.sourceArchiveSha256))
    if (([string]$rawUpstream.status -ceq 'passed' -and [string]$rawUpstream.decision -cne 'PASS') -or
        ([string]$rawUpstream.status -ceq 'not-applicable' -and [string]$rawUpstream.decision -cne 'NOT_APPLICABLE')) { throw 'Domain adapter upstream status was projected incorrectly.' }
    return $true
}

try {
    $operationWatch=[Diagnostics.Stopwatch]::StartNew()
    Set-StandardCoreV2GitOperationContext -Stopwatch $operationWatch -OperationTimeoutSeconds $OperationTimeoutSeconds
    if(-not $IsWindows){throw 'Protected Standard Core v2 source validation requires Windows PowerShell 7.'}
    if([string]::IsNullOrWhiteSpace($BaseCommit)){throw 'Explicit Core v2 source preparation and validation require a caller-supplied BaseCommit.'}
    $repo=[IO.Path]::GetFullPath($RepositoryRoot); $artifact=[IO.Path]::GetFullPath($ArtifactsRoot)
    $authority=[IO.Path]::GetFullPath($AuthorityRepositoryRoot); $trusted=[IO.Path]::GetFullPath($TrustedToolRoot)
    foreach($path in @($repo,$authority,$trusted)){Assert-StandardCoreV2NoReparseAncestors -Path $path -Context 'Protected input root'}
    if(-not (Test-Path -LiteralPath $artifact -PathType Container)){if($Mode -eq 'SourceValidation'){throw 'Artifacts root does not exist.'};[void][IO.Directory]::CreateDirectory($artifact)}
    Assert-StandardCoreV2NoReparseAncestors -Path $artifact -Context 'Artifacts root'
    foreach($root in @($repo,$authority,$trusted)){Assert-Outside $artifact $root 'Artifacts root'}
    Assert-Outside $trusted $repo 'Trusted runtime root'; Assert-Outside $trusted $authority 'Trusted runtime root'
    $current=[IO.Path]::GetFullPath([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    $registered=[Environment]::GetEnvironmentVariable('STANDARD_VALIDATION_RUN_OWNED_ROOT','Process')
    $workflowRegistered=[Environment]::GetEnvironmentVariable('RUN_OWNED_ROOT','Process')
    if(-not [string]::IsNullOrWhiteSpace($registered) -and -not [string]::IsNullOrWhiteSpace($workflowRegistered) -and
        -not [IO.Path]::GetFullPath($registered).Equals([IO.Path]::GetFullPath($workflowRegistered),[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Namespaced and workflow run-owned root registrations disagree.'
    }
    if([string]::IsNullOrWhiteSpace($registered)){$registered=$workflowRegistered}
    if([string]::IsNullOrWhiteSpace($registered) -or -not [IO.Path]::GetFullPath($registered).Equals($trusted,[StringComparison]::OrdinalIgnoreCase)) {throw 'TrustedToolRoot must equal the workflow-registered RUN_OWNED_ROOT.'}
    if ($Mode -ceq 'SourceValidation') {
        if ([string]::IsNullOrWhiteSpace($ExpectedSourceToolsSha256)) { throw 'SourceValidation requires ExpectedSourceToolsSha256 from trusted preparation output.' }
        $preflightPlan = Assert-ProtectedSourceRuntimeClosure -PlanPath $SourceToolsPath -ExpectedPlanSha256 $ExpectedSourceToolsSha256 -OwnedRoot $trusted -SupervisorExecutable $current
        $current = [string]$preflightPlan.runtimeExecutable
    }
    [void](Assert-CorePesterOwnedRuntime -RuntimeExecutable $current -OwnedRoot $trusted -CurrentExecutable $current)
    $profile=Read-StandardCoreV2PreparationProfile -ConfigPath (Join-Path $PSScriptRoot '../config/standard-core-v2-preparation.json')
    $git=(Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path
    $protectedDriverRepositoryRoot=(Invoke-StandardCoreV2GitText -GitPath $git -Arguments @('--no-replace-objects','-C',$PSScriptRoot,'rev-parse','--show-toplevel')).StdOut.Trim()
    Assert-StandardCoreV2NoReparseAncestors -Path $protectedDriverRepositoryRoot -Context 'Protected event-base repository root'
    $authorityTuple=Assert-StandardCoreV2AuthorityTuple -Profile $profile -GitPath $git -RepositoryRoot $authority
    $sourceRevision=Get-Revision $git $repo 'HEAD' 'Candidate revision'
    if($Mode -eq 'PrepareSourceTools') {
        $baseRevision=Get-Revision $git $repo $BaseCommit 'Base revision'
        $ancestor=Invoke-StandardCoreV2GitText -GitPath $git -Arguments @('--no-replace-objects','-C',$repo,'merge-base','--is-ancestor',$baseRevision,$sourceRevision) -AllowedExitCodes @(0,1)
        if($ancestor.ExitCode -ne 0 -or $baseRevision -ceq $sourceRevision){throw 'Base revision must be a distinct candidate ancestor.'}
        $runId=[guid]::NewGuid().ToString('N')
        $timings=[ordered]@{}
        $planPath=Assert-PlanPath $SourceToolsPath $artifact 'SourceToolsPath'
        if(-not (Test-PathEqual -Left (Split-Path -Parent $planPath) -Right $artifact) -or (Test-Path -LiteralPath $planPath)){throw 'SourceToolsPath must be a new direct child of ArtifactsRoot.'}
        $setupRoot=Join-Path $artifact "source-tools-$runId"; [void][IO.Directory]::CreateDirectory($setupRoot)
        Assert-StandardCoreV2NoReparseAncestors -Path $setupRoot -Context 'Source setup owned root'
        $installPathWatch=[Diagnostics.Stopwatch]::StartNew()
        $toolInstallParent=Get-StandardCoreV2ToolInstallParent -RunId $runId
        if(Test-Path -LiteralPath $toolInstallParent){throw 'Deterministic run-owned tool install parent already exists.'}
        if((Test-Within $toolInstallParent $artifact) -or (Test-Within $artifact $toolInstallParent)) {
            throw 'ArtifactsRoot and the deterministic tool install parent must not overlap.'
        }
        [void][IO.Directory]::CreateDirectory($toolInstallParent)
        Assert-StandardCoreV2NoReparseAncestors -Path $toolInstallParent -Context 'Short run-owned tool install parent'
        $skillSpectorPathHeadroom=Get-StandardCoreV2SkillSpectorPathHeadroom -InstallParent $toolInstallParent `
            -DeepArtifactsInstallParent (Join-Path $setupRoot 'installed')
        $installPathWatch.Stop(); $timings.toolInstallPathHeadroomCalculationMs=$installPathWatch.ElapsedMilliseconds
        $timings.skillSpectorWindowsPathHeadroom=$skillSpectorPathHeadroom
        $driverCopyWatch=[Diagnostics.Stopwatch]::StartNew()
        $trustedDriverRoot=[IO.Path]::GetFullPath((Join-Path $trusted "core-v2-source-$runId"))
        if(-not (Test-Within $trustedDriverRoot $trusted) -or (Test-PathEqual $trustedDriverRoot $trusted)){throw 'Protected source driver root is outside TrustedToolRoot.'}
        if(Test-Path -LiteralPath $trustedDriverRoot){throw 'Protected source driver root already exists.'}
        [void][IO.Directory]::CreateDirectory($trustedDriverRoot)
        $driverNames=@('Invoke-ProtectedSourceValidation.ps1','Invoke-CoreSourceTool.ps1','StandardCoreSourcePreparation.psm1','Prepare-PesterRuntime.ps1',
            'CorePesterIntegrity.psm1','SkillSpectorReviewedE1Baselines.json','Invoke-CoreRepositoryGeneral.ps1','Invoke-CorePester.ps1','Test-Repository.ps1')
        $driverFiles=New-ProtectedEventBaseDriverFiles -GitPath $git -ProtectedRepositoryRoot $protectedDriverRepositoryRoot `
            -SourceScriptsRoot $PSScriptRoot -DestinationRoot $trustedDriverRoot -DriverNames $driverNames `
            -ExpectedBaselineSha256 $script:ReviewedE1BaselineSha256
        $driverCopyWatch.Stop(); $timings.protectedDriverCopyMs=$driverCopyWatch.ElapsedMilliseconds
        $candidateWatch=[Diagnostics.Stopwatch]::StartNew()
        $candidate=New-StandardCoreV2RawCandidateClone -GitPath $git -SourceRoot $repo -OwnedRoot $setupRoot -Destination (Join-Path $setupRoot 'candidate-source') -ExpectedRevision $sourceRevision
        [void](New-ProtectedCandidateFilePins -GitPath $git -ProtectedRepositoryRoot $protectedDriverRepositoryRoot -ProtectedDriverRoot $trustedDriverRoot `
            -ProtectedDriverFiles @($driverFiles) -CandidateRoot $candidate.Root -CandidateRevision $sourceRevision)
        $candidateWatch.Stop(); $timings.candidateCloneMs=$candidateWatch.ElapsedMilliseconds
        $adapterRoot=[IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $artifact) ".core-v2-adapter-$runId"))
        if(Test-Path -LiteralPath $adapterRoot){throw 'Core adapter sibling already exists.'}; [void][IO.Directory]::CreateDirectory($adapterRoot)
        $binding=New-StandardCoreV2GitMetadataClone -GitPath $git -RawCandidateRoot $candidate.Root -OwnedRoot $adapterRoot -Destination (Join-Path $adapterRoot 'candidate-git') -ExpectedRevision $sourceRevision -RunId $runId
        $sourceArchivePath=Join-Path $setupRoot "source-archive-$runId.tar"
        $sourceArchive=New-StandardCoreV2GitArchive -GitPath $git -RepositoryRoot $binding.Root -OwnedRoot $setupRoot `
            -Destination $sourceArchivePath -Revision $sourceRevision
        $authorityWatch=[Diagnostics.Stopwatch]::StartNew()
        $authorityCheckout=New-StandardCoreV2RawCandidateClone -GitPath $git -SourceRoot $authority -OwnedRoot $adapterRoot `
            -Destination (Join-Path $adapterRoot 'authority-git') -ExpectedRevision ([string]$profile.authority.commit) `
            -ExpectedSourceRepository ([string]$profile.authority.repository)
        $authorityCheckoutTuple=Assert-StandardCoreV2AuthorityTuple -Profile $profile -GitPath $git -RepositoryRoot $authorityCheckout.Root -RequireWorkingTree
        $authorityFiles=New-StandardCoreV2AuthorityMaterialization -Profile $profile -GitPath $git -RepositoryRoot $authorityCheckout.Root `
            -OwnedRoot $adapterRoot -Destination (Join-Path $adapterRoot 'authority-tuple')
        $authorityWatch.Stop(); $timings.authorityCheckoutAndTupleMs=$authorityWatch.ElapsedMilliseconds
        $runner=Join-Path $authorityCheckout.Root 'scripts/Invoke-StandardValidation.ps1'
        $tree=Get-StandardCoreV2GitTree -GitPath $git -Root $candidate.Root -Revision $sourceRevision
        if(-not $tree.ContainsKey('scripts/SkillSpectorReviewedE1Baselines.json')){throw 'Tracked candidate reviewed E1 policy is missing.'}
        $candidateReviewedBaseline=Join-Path $candidate.Root 'scripts/SkillSpectorReviewedE1Baselines.json'
        if((Get-Sha $candidateReviewedBaseline) -cne $script:ReviewedE1BaselineSha256 -or
            (Get-StandardCoreV2GitBlobSha256 -GitPath $git -RepositoryRoot $candidate.Root -ObjectId ([string]$tree['scripts/SkillSpectorReviewedE1Baselines.json'].objectId)) -cne $script:ReviewedE1BaselineSha256){
            throw 'Tracked candidate reviewed E1 policy differs from the pinned raw review artifact.'
        }
        if(-not $tree.ContainsKey('config/pester-6.2.0-closure.lock.json')){throw 'Tracked candidate Pester closure lock is missing.'}
        $lockEntry=$tree['config/pester-6.2.0-closure.lock.json']; $lockPath=Join-Path $setupRoot 'pester-6.2.0-closure.lock.json'
        Write-StandardCoreV2GitBlob -GitPath $git -RepositoryRoot $candidate.Root -ObjectId $lockEntry.objectId -Destination $lockPath
        if((Get-Sha $lockPath) -cne '72df3af4707809f5e0974e77a4d8ea575033baa1fbea0d92fc7ef9bdbc545b52'){throw 'Tracked candidate Pester lock differs from the pinned closure.'}
        $pesterArgs=@('-NoProfile','-NonInteractive','-File',(Join-Path $trustedDriverRoot 'Prepare-PesterRuntime.ps1'),'-RuntimeExecutable',$current,'-OwnedRoot',$trusted,'-ClosureLockPath',$lockPath)
        $pesterBudget=Get-StandardCoreV2ChildBudget -OperationTimeoutSeconds $OperationTimeoutSeconds -ChildLimitSeconds $TimeoutSeconds `
            -ElapsedMilliseconds ([long]$operationWatch.ElapsedMilliseconds) -Context 'Pester runtime preparation'
        $pesterWatch=[Diagnostics.Stopwatch]::StartNew()
        $pesterSetup=Invoke-StandardCoreSupervisedProcess -RunnerPath $runner -CandidateRoot $candidate.Root -AdapterPath (Join-Path $adapterRoot 'adapter.json') `
            -ArtifactsRoot $artifact -SourceRepository ([string]$profile.source.repository) -SourceRevision $sourceRevision -AuthorityRevision ([string]$profile.authority.commit) `
            -RunId $runId -TrustedToolRoot $trusted -PowerShell $current -Arguments $pesterArgs -WorkingDirectory $setupRoot -OwnedRoot $trusted -LimitSeconds $pesterBudget
        $pesterWatch.Stop(); $timings.pesterSetupMs=$pesterWatch.ElapsedMilliseconds
        Write-JsonCreateNew (Join-Path $setupRoot 'pester-setup-process.json') $pesterSetup
        if($pesterSetup.status -cne 'passed' -or $pesterSetup.exitCode -ne 0 -or -not $pesterSetup.cleanedUp){throw "Pester runtime preparation failed: $($pesterSetup.status), exit=$($pesterSetup.exitCode), cleanup=$($pesterSetup.cleanedUp). $($pesterSetup.stderr)"}
        $pesterInventoryWatch=[Diagnostics.Stopwatch]::StartNew()
        $pester=Get-CorePesterFrozenRuntimeFiles -OwnedRoot $trusted -EvidenceRoot $setupRoot -RuntimeExecutable $current `
            -SetupReceiptPath (Join-Path $trusted 'pester-setup/setup-receipt.json') -ClosureLockPath $lockPath
        $pesterInventoryWatch.Stop(); $timings.pesterRuntimeInventoryHashAndSortMs=$pesterInventoryWatch.ElapsedMilliseconds
        $receipts=[Collections.Generic.List[object]]::new()
        $toolResolutionTimings=[Collections.Generic.List[object]]::new()
        foreach($tool in @('skill-validator','skill-tools','skillspector')){
            $receiptPath=Join-Path $setupRoot "receipt-$tool.json"
            $resolverBudget=Get-StandardCoreV2ChildBudget -OperationTimeoutSeconds $OperationTimeoutSeconds -ChildLimitSeconds $TimeoutSeconds `
                -ElapsedMilliseconds ([long]$operationWatch.ElapsedMilliseconds) -Context "Resolver acquisition for $tool"
            $args=New-StandardCoreV2ResolverArguments -ResolverPath (Join-Path $authorityCheckout.Root 'scripts/Resolve-StandardValidationTool.ps1') `
                -PolicyPath (Join-Path $authorityCheckout.Root 'docs/standards/validation-toolchain.json') -ToolName $tool -InstallRoot $toolInstallParent `
                -RunId $runId -OutputPath $receiptPath -ExpectedGoRuntimeVersion $ExpectedGoRuntimeVersion -AcquisitionTimeoutSeconds $resolverBudget
            $toolWatch=[Diagnostics.Stopwatch]::StartNew()
            $resolved=Invoke-StandardCoreSupervisedProcess -RunnerPath $runner -CandidateRoot $candidate.Root -AdapterPath (Join-Path $adapterRoot 'adapter.json') `
                -ArtifactsRoot $artifact -SourceRepository ([string]$profile.source.repository) -SourceRevision $sourceRevision -AuthorityRevision ([string]$profile.authority.commit) `
                -RunId $runId -TrustedToolRoot $trusted -PowerShell $current -Arguments $args -WorkingDirectory $setupRoot -OwnedRoot $trusted -LimitSeconds $resolverBudget
            $toolWatch.Stop(); $toolResolutionTimings.Add([pscustomobject]@{tool=$tool;milliseconds=$toolWatch.ElapsedMilliseconds})
            Write-JsonCreateNew (Join-Path $setupRoot "resolve-$tool-process.json") $resolved
            if($resolved.status -cne 'passed' -or $resolved.exitCode -ne 0 -or -not $resolved.cleanedUp){throw "Source tool resolution failed for ${tool}: $($resolved.stderr)"}
            $receipts.Add([pscustomobject]@{path=[IO.Path]::GetFullPath($receiptPath);sha256=(Get-Sha $receiptPath)})
        }
        $receiptData=@{}; foreach($entry in $receipts){
            $record=Read-StandardCoreV2StrictJson -Path ([string]$entry.path) -Context 'Source resolver receipt'
            [void](Assert-StandardCoreV2ResolverReceiptPaths -Receipt $record -ExpectedInstallParent $toolInstallParent -ExpectedRunId $runId `
                -CandidateRoot $candidate.Root -ArtifactsRoot $artifact)
            $receiptData[[string]$record.toolName]=$record
        }
        $toolchain=[ordered]@{
            centralRunnerPath=$runner; centralRunnerSha256=(Get-Sha $runner)
            sourceRepository=[string]$profile.source.repository; sourceRevision=$sourceRevision; sourceBindingSha256=$binding.BindingSha256
            sourceArchivePath=[IO.Path]::GetFullPath([string]$sourceArchive.path); sourceArchiveSha256=[string]$sourceArchive.sha256; sourceArchiveLength=[long]$sourceArchive.length
            runtimeExecutable=$current; runtimeSha256=(Get-Sha $current)
            sourceToolWrapperPath=(Join-Path $trustedDriverRoot 'Invoke-CoreSourceTool.ps1'); sourceToolWrapperSha256=(Get-Sha (Join-Path $trustedDriverRoot 'Invoke-CoreSourceTool.ps1'))
            preparePesterRuntimePath=(Join-Path $trustedDriverRoot 'Prepare-PesterRuntime.ps1'); preparePesterRuntimeSha256=(Get-Sha (Join-Path $trustedDriverRoot 'Prepare-PesterRuntime.ps1'))
            upstreamAdapterValidatorPath=(Join-Path $authorityCheckout.Root 'scripts/Validate-UpstreamAdapter.ps1'); upstreamAdapterValidatorSha256=(Get-Sha (Join-Path $authorityCheckout.Root 'scripts/Validate-UpstreamAdapter.ps1'))
            upstreamPolicyPath=(Join-Path $authorityCheckout.Root 'docs/standards/upstream-adapter.json'); upstreamPolicySha256=(Get-Sha (Join-Path $authorityCheckout.Root 'docs/standards/upstream-adapter.json'))
            skillValidatorPath=[string]$receiptData.'skill-validator'.executablePath; skillValidatorSha256=[string]$receiptData.'skill-validator'.executableSha256
            skillToolsNodePath=[string]$receiptData.'skill-tools'.nodePath; skillToolsNodeSha256=[string]$receiptData.'skill-tools'.nodeSha256
            skillToolsEntryPointPath=[string]$receiptData.'skill-tools'.entryPointPath; skillToolsEntryPointSha256=[string]$receiptData.'skill-tools'.entryPointSha256
            skillSpectorPath=[string]$receiptData.skillspector.executablePath; skillSpectorSha256=[string]$receiptData.skillspector.executableSha256
            skillSpectorReceiptPath=[string]$receipts[2].path; skillSpectorReceiptSha256=[string]$receipts[2].sha256
        }
        $toolchainPath=Join-Path $setupRoot 'toolchain.json'; Write-JsonCreateNew $toolchainPath $toolchain; $toolchainSha=Get-Sha $toolchainPath
        $sourceArgs=@('-NoProfile','-NonInteractive','-File',(Join-Path $trustedDriverRoot 'Invoke-CoreSourceTool.ps1'),'-ToolchainPath',$toolchainPath,'-ToolchainSha256',$toolchainSha)
        $frozen=[Collections.Generic.List[object]]::new(); $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $freezeWatch=[Diagnostics.Stopwatch]::StartNew()
        foreach($entry in $pester.frozenFiles){Add-Frozen $frozen $seen ([string]$entry.path)}
        foreach($entry in $profile.authority.files){Add-Frozen $frozen $seen (Join-Path $authorityCheckout.Root ([string]$entry.path).Replace('/',[IO.Path]::DirectorySeparatorChar))}
        foreach($entry in $authorityFiles.Files){Add-Frozen $frozen $seen (Join-Path $authorityFiles.Root ([string]$entry.path).Replace('/',[IO.Path]::DirectorySeparatorChar))}
        foreach($entry in $receipts){Add-Frozen $frozen $seen ([string]$entry.path)}
        foreach($path in @(
            (Join-Path $candidate.Root 'scripts/Test-Repository.ps1')
            (Join-Path $candidate.Root 'scripts/Invoke-CoreRepositoryGeneral.ps1')
            (Join-Path $candidate.Root 'scripts/Invoke-CorePester.ps1')
            (Join-Path $candidate.Root 'scripts/CorePesterIntegrity.psm1')
            (Join-Path $candidate.Root 'scripts/StandardCoreSourcePreparation.psm1')
            $candidateReviewedBaseline
            (Join-Path $candidate.Root 'config/pester-6.2.0-closure.lock.json')
            (Join-Path $candidate.Root 'config/standard-core-v2-preparation.json')
            (Join-Path $candidate.Root '.gitattributes')
            $sourceArchive.path
            $lockPath
            $binding.BindingPath
            $toolchainPath
            $pester.setupReceiptPath
        )) {Add-Frozen $frozen $seen $path}
        foreach($entry in $driverFiles){Add-Frozen $frozen $seen ([string]$entry.path)}
        foreach($receipt in $receiptData.Values){foreach($key in @('executablePath','nodePath','entryPointPath')){if($receipt.PSObject.Properties[$key]){Add-Frozen $frozen $seen ([string]$receipt.$key)}}}
        $freezeWatch.Stop(); $timings.sourceFrozenFileInventoryAndHashMs=$freezeWatch.ElapsedMilliseconds
        $sourceSpec=[ordered]@{frozenFiles=@($frozen.ToArray());toolReceipts=@($receipts.ToArray())}
        $sourceSpec.packageAdapter=[ordered]@{command=$current;arguments=@($sourceArgs+@('-Mode','package-adapter'))}
        $sourceSpec.skillValidator=[ordered]@{command=$current;arguments=@($sourceArgs+@('-Mode','skill-validator'))}
        $sourceSpec.skillTools=[ordered]@{command=$current;arguments=@($sourceArgs+@('-Mode','skill-tools'))}
        $sourceSpec.staticAnalyzer=[ordered]@{command=$current;arguments=@($sourceArgs+@('-Mode','static'))}
        $plan=[ordered]@{schemaVersion=1;preparation='standard-core-v2-source-validation';runId=$runId;sourceRevision=$sourceRevision;baseRevision=$baseRevision;authorityRevision=[string]$profile.authority.commit;operationTimeoutSeconds=$OperationTimeoutSeconds;childTimeoutSeconds=$TimeoutSeconds;artifactsRoot=$artifact;ownedRoot=$setupRoot;adapterRoot=$adapterRoot;candidateSourceRoot=$candidate.Root;authorityCheckoutRoot=$authorityCheckout.Root;authorityTupleRoot=$authorityFiles.Root;bindingPath=$binding.BindingPath;bindingSha256=$binding.BindingSha256;runtimeExecutable=$current;runtimeSha256=(Get-Sha $current);trustedDriverRoot=$trustedDriverRoot;protectedDriverFiles=@($driverFiles);toolInstallParent=$toolInstallParent;skillSpectorPathHeadroom=$skillSpectorPathHeadroom;toolchainPath=$toolchainPath;toolchainSha256=$toolchainSha;sourceArchivePath=$sourceArchive.path;sourceArchiveSha256=$sourceArchive.sha256;sourceArchiveLength=[long]$sourceArchive.length;pesterClosureLockSha256=$pester.closureLockSha256;toolResolutionTimings=@($toolResolutionTimings.ToArray());timings=$timings;sourceValidation=$sourceSpec}
        [void](Get-StandardCoreV2RemainingSeconds -OperationTimeoutSeconds $OperationTimeoutSeconds `
            -ElapsedMilliseconds ([long]$operationWatch.ElapsedMilliseconds) -Context 'Source setup plan publication')
        $planWriteWatch=[Diagnostics.Stopwatch]::StartNew(); Write-JsonCreateNew $planPath $plan; $planWriteWatch.Stop(); $timings.planWriteMs=$planWriteWatch.ElapsedMilliseconds
        Write-JsonCreateNew (Join-Path $setupRoot 'setup-timings.json') ([ordered]@{timings=$timings;toolResolutionTimings=@($toolResolutionTimings.ToArray());pesterSetupProcess=$pesterSetup})
        [void](Get-StandardCoreV2RemainingSeconds -OperationTimeoutSeconds $OperationTimeoutSeconds `
            -ElapsedMilliseconds ([long]$operationWatch.ElapsedMilliseconds) -Context 'Source setup completion')
        [Console]::Out.WriteLine((ConvertTo-Json -InputObject ([ordered]@{status='prepared';runId=$runId;sourceRevision=$sourceRevision;sourceToolsPath=$planPath;sourceToolsSha256=(Get-Sha $planPath);frozenFileCount=$frozen.Count}) -Compress))
        exit 0
    }
    $planFile=Assert-PlanPath $SourceToolsPath $artifact 'SourceToolsPath'
    if(-not (Test-PathEqual -Left (Split-Path -Parent $planFile) -Right $artifact)){throw 'SourceToolsPath must be a direct child of ArtifactsRoot.'}
    Assert-StandardCoreV2NoReparseAncestors -Path $planFile -Context 'Prepared source plan'
    $plan=$preflightPlan
    $planProperties=@('schemaVersion','preparation','runId','sourceRevision','baseRevision','authorityRevision','operationTimeoutSeconds','childTimeoutSeconds','artifactsRoot','ownedRoot','adapterRoot',
        'candidateSourceRoot','authorityCheckoutRoot','authorityTupleRoot','bindingPath','bindingSha256','runtimeExecutable','runtimeSha256','trustedDriverRoot',
        'protectedDriverFiles','toolInstallParent','skillSpectorPathHeadroom','toolchainPath','toolchainSha256','sourceArchivePath','sourceArchiveSha256','sourceArchiveLength',
        'pesterClosureLockSha256','toolResolutionTimings','timings','sourceValidation')
    Assert-StandardCoreV2ExactProperties -Value $plan -Names $planProperties -Context 'Prepared source plan'
    if($plan.operationTimeoutSeconds -isnot [int] -and $plan.operationTimeoutSeconds -isnot [long]) { throw 'Prepared operation deadline must be an integer.' }
    if($plan.childTimeoutSeconds -isnot [int] -and $plan.childTimeoutSeconds -isnot [long]) { throw 'Prepared child timeout must be an integer.' }
    if($plan.schemaVersion -ne 1 -or $plan.preparation -cne 'standard-core-v2-source-validation' -or $plan.authorityRevision -cne $profile.authority.commit -or
        [int]$plan.operationTimeoutSeconds -ne $OperationTimeoutSeconds -or [int]$plan.childTimeoutSeconds -ne $TimeoutSeconds -or
        $plan.runtimeExecutable -cne $current -or $plan.runtimeSha256 -cne (Get-Sha $current) -or $plan.sourceRevision -cnotmatch '^[0-9a-f]{40}$' -or
        $plan.baseRevision -cnotmatch '^[0-9a-f]{40}$' -or $plan.runId -cnotmatch '^[0-9a-f]{32}$' -or
        $plan.bindingSha256 -cnotmatch '^[0-9a-f]{64}$' -or $plan.toolchainSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $plan.sourceArchiveSha256 -cnotmatch '^[0-9a-f]{64}$' -or [long]$plan.sourceArchiveLength -le 0 -or
        $plan.pesterClosureLockSha256 -cne '72df3af4707809f5e0974e77a4d8ea575033baa1fbea0d92fc7ef9bdbc545b52') {throw 'Prepared source plan does not bind this authority, source, runtime, and closure.'}
    if(-not (Test-PathEqual -Left ([string]$plan.artifactsRoot) -Right $artifact)){throw 'Prepared source plan belongs to a different artifacts root.'}
    if((Get-Revision $git $repo $BaseCommit 'Base revision') -cne [string]$plan.baseRevision){throw 'Requested base revision differs from prepared source setup.'}
    $revision=Get-Revision $git $repo 'HEAD' 'Candidate revision'
    if($revision -cne [string]$plan.sourceRevision){throw 'Candidate revision differs from the prepared setup.'}
    [void](Invoke-StandardCoreV2GitText -GitPath $git -Arguments @('--no-replace-objects','-C',$repo,'merge-base','--is-ancestor',[string]$plan.baseRevision,$revision))

    $setupRoot=[IO.Path]::GetFullPath((Join-Path $artifact "source-tools-$($plan.runId)"))
    $adapterRoot=[IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $artifact) ".core-v2-adapter-$($plan.runId)"))
    $candidateSourceRoot=[IO.Path]::GetFullPath((Join-Path $setupRoot 'candidate-source'))
    $authorityCheckoutRoot=[IO.Path]::GetFullPath((Join-Path $adapterRoot 'authority-git'))
    $authorityTupleRoot=[IO.Path]::GetFullPath((Join-Path $adapterRoot 'authority-tuple'))
    $bindingPath=[IO.Path]::GetFullPath((Join-Path $adapterRoot 'source-git-binding.json'))
    $trustedDriverRoot=[IO.Path]::GetFullPath((Join-Path $trusted "core-v2-source-$($plan.runId)"))
    $toolchainPath=[IO.Path]::GetFullPath((Join-Path $setupRoot 'toolchain.json'))
    $toolInstallParent=Get-StandardCoreV2ToolInstallParent -RunId ([string]$plan.runId)
    if(-not (Test-PathEqual -Left ([string]$plan.toolInstallParent) -Right $toolInstallParent) -or -not (Test-Path -LiteralPath $toolInstallParent -PathType Container)){
        throw 'Prepared source tool install parent differs from the exact run-derived OS temporary root.'
    }
    Assert-StandardCoreV2NoReparseAncestors -Path $toolInstallParent -Context 'Prepared short tool install parent'
    $expectedSkillSpectorPathHeadroom=Get-StandardCoreV2SkillSpectorPathHeadroom -InstallParent $toolInstallParent `
        -DeepArtifactsInstallParent (Join-Path $setupRoot 'installed')
    Assert-StandardCoreV2ExactProperties -Value $plan.skillSpectorPathHeadroom -Names @('limitExclusive','currentProbePath','currentProbeLength','currentHeadroom','deepArtifactsProbePath','deepArtifactsProbeLength','deepArtifactsWouldPass') -Context 'Prepared SkillSpector path headroom'
    if([int]$plan.skillSpectorPathHeadroom.limitExclusive -ne [int]$expectedSkillSpectorPathHeadroom.limitExclusive -or
        -not (Test-PathEqual -Left ([string]$plan.skillSpectorPathHeadroom.currentProbePath) -Right ([string]$expectedSkillSpectorPathHeadroom.currentProbePath)) -or
        [int]$plan.skillSpectorPathHeadroom.currentProbeLength -ne [int]$expectedSkillSpectorPathHeadroom.currentProbeLength -or
        [int]$plan.skillSpectorPathHeadroom.currentHeadroom -ne [int]$expectedSkillSpectorPathHeadroom.currentHeadroom -or
        -not (Test-PathEqual -Left ([string]$plan.skillSpectorPathHeadroom.deepArtifactsProbePath) -Right ([string]$expectedSkillSpectorPathHeadroom.deepArtifactsProbePath)) -or
        [int]$plan.skillSpectorPathHeadroom.deepArtifactsProbeLength -ne [int]$expectedSkillSpectorPathHeadroom.deepArtifactsProbeLength -or
        [bool]$plan.skillSpectorPathHeadroom.deepArtifactsWouldPass -ne [bool]$expectedSkillSpectorPathHeadroom.deepArtifactsWouldPass){
        throw 'Prepared SkillSpector Windows path headroom proof differs from the exact resolver path contract.'
    }
    foreach($pair in @(@([string]$plan.ownedRoot,$setupRoot),@([string]$plan.adapterRoot,$adapterRoot),@([string]$plan.candidateSourceRoot,$candidateSourceRoot),
        @([string]$plan.authorityCheckoutRoot,$authorityCheckoutRoot),@([string]$plan.authorityTupleRoot,$authorityTupleRoot),@([string]$plan.bindingPath,$bindingPath),
        @([string]$plan.trustedDriverRoot,$trustedDriverRoot),@([string]$plan.toolchainPath,$toolchainPath))){
        if(-not (Test-PathEqual -Left $pair[0] -Right $pair[1])){throw 'Prepared source plan contains a path outside the exact run-owned layout.'}
    }
    foreach($directory in @($setupRoot,$adapterRoot,$candidateSourceRoot,$authorityCheckoutRoot,$authorityTupleRoot,$trustedDriverRoot)){
        if(-not (Test-Path -LiteralPath $directory -PathType Container)){throw "Prepared source directory is missing: $directory"}
        Assert-StandardCoreV2NoReparseAncestors -Path $directory -Context 'Prepared source directory'
    }
    foreach($root in @($setupRoot)) { Assert-Outside $root $repo 'Prepared source root'; Assert-Outside $root $authority 'Prepared source root' }
    foreach($root in @($adapterRoot,$trustedDriverRoot,$toolInstallParent)) { Assert-Outside $root $repo 'Prepared source root'; Assert-Outside $root $authority 'Prepared source root'; Assert-Outside $root $artifact 'Prepared source root' }

    $bindingHash=Get-Sha $bindingPath
    if($bindingHash -cne [string]$plan.bindingSha256){throw 'Prepared source binding record changed.'}
    $bindingRecord=Read-StandardCoreV2StrictJson -Path $bindingPath -Context 'Prepared source binding record'
    Assert-StandardCoreV2ExactProperties -Value $bindingRecord -Names @('schemaVersion','runId','sourceRevision','gitMetadataRoot') -Context 'Prepared source binding record'
    $candidateMetadataRoot=[IO.Path]::GetFullPath((Join-Path $adapterRoot 'candidate-git'))
    if($bindingRecord.schemaVersion -ne 1 -or [string]$bindingRecord.runId -cne [string]$plan.runId -or [string]$bindingRecord.sourceRevision -cne $revision -or
        -not (Test-PathEqual -Left ([string]$bindingRecord.gitMetadataRoot) -Right $candidateMetadataRoot)){throw 'Prepared source binding record differs from the exact run, source revision, or metadata path.'}
    $metadataTop=(Invoke-StandardCoreV2GitText -GitPath $git -Arguments @('--no-replace-objects','-C',$candidateMetadataRoot,'rev-parse','--show-toplevel')).StdOut.Trim()
    $metadataHead=Get-Revision $git $candidateMetadataRoot 'HEAD' 'Bound source metadata revision'
    $metadataFormat=(Invoke-StandardCoreV2GitText -GitPath $git -Arguments @('--no-replace-objects','-C',$candidateMetadataRoot,'rev-parse','--show-object-format=storage')).StdOut.Trim()
    $metadataAlternates=(Invoke-StandardCoreV2GitText -GitPath $git -Arguments @('-C',$candidateMetadataRoot,'rev-parse','--git-path','objects/info/alternates')).StdOut.Trim()
    if(-not [IO.Path]::GetFullPath($metadataTop).Equals($candidateMetadataRoot,[StringComparison]::OrdinalIgnoreCase) -or $metadataHead -cne $revision -or $metadataFormat -cne 'sha1') {throw 'Prepared source Git metadata root differs from the exact source repository contract.'}
    if(-not [IO.Path]::IsPathRooted($metadataAlternates)){$metadataAlternates=Join-Path $candidateMetadataRoot $metadataAlternates}
    if(Test-Path -LiteralPath $metadataAlternates){throw 'Prepared source Git metadata root uses an alternate object database.'}
    $metadataOrigins=(Invoke-StandardCoreV2GitText -GitPath $git -Arguments @('-C',$candidateMetadataRoot,'config','--local','--get-all','remote.origin.url') -AllowedExitCodes @(0,1)).StdOut
    [string[]]$metadataOriginValues=@($metadataOrigins -split "\r?\n" | Where-Object {-not [string]::IsNullOrWhiteSpace($_)})
    if($metadataOriginValues.Count -ne 0){throw 'Prepared source metadata-only Git clone must not retain any origin remote.'}
    [void](Assert-StandardCoreV2RawCheckout -GitPath $git -Root $candidateSourceRoot -Revision $revision)
    $candidateOrigins=(Invoke-StandardCoreV2GitText -GitPath $git -Arguments @('-C',$candidateSourceRoot,'config','--local','--get-all','remote.origin.url') -AllowedExitCodes @(0,1)).StdOut
    [string[]]$candidateOriginValues=@($candidateOrigins -split "\r?\n" | Where-Object {-not [string]::IsNullOrWhiteSpace($_)})
    if($candidateOriginValues.Count -ne 1 -or $candidateOriginValues[0] -cne [string]$profile.source.repository){throw 'Prepared raw candidate clone origin differs from the pinned repository.'}

    $authorityCheckoutTuple=Assert-StandardCoreV2AuthorityTuple -Profile $profile -GitPath $git -RepositoryRoot $authorityCheckoutRoot -RequireWorkingTree
    [void](Assert-StandardCoreV2RawCheckout -GitPath $git -Root $authorityCheckoutRoot -Revision ([string]$profile.authority.commit))
    $authorityTupleTree=Get-ChildItem -LiteralPath $authorityTupleRoot -File -Recurse -Force
    if($authorityTupleTree.Count -ne 32){throw 'Retained raw authority tuple materialization must contain exactly 32 files.'}
    foreach($entry in $profile.authority.files){
        $tupleFile=Join-Path $authorityTupleRoot ([string]$entry.path).Replace('/',[IO.Path]::DirectorySeparatorChar)
        if((Get-Sha $tupleFile) -cne [string]$entry.sha256){throw "Retained raw authority tuple materialization changed: $($entry.path)"}
    }
    $runner=Join-Path $authorityCheckoutRoot 'scripts/Invoke-StandardValidation.ps1'
    if(-not (Test-Path -LiteralPath $runner -PathType Leaf)){throw 'Retained full32 authority runner is missing.'}

    $driverNames=@('Invoke-ProtectedSourceValidation.ps1','Invoke-CoreSourceTool.ps1','StandardCoreSourcePreparation.psm1','Prepare-PesterRuntime.ps1','CorePesterIntegrity.psm1','SkillSpectorReviewedE1Baselines.json','Invoke-CoreRepositoryGeneral.ps1','Invoke-CorePester.ps1','Test-Repository.ps1')
    if($plan.protectedDriverFiles -isnot [array] -or @($plan.protectedDriverFiles).Count -ne $driverNames.Count){throw 'Prepared protected driver file inventory is incomplete.'}
    $driverFiles=New-ProtectedEventBaseDriverFiles -GitPath $git -ProtectedRepositoryRoot $protectedDriverRepositoryRoot `
        -SourceScriptsRoot $PSScriptRoot -DestinationRoot $trustedDriverRoot -DriverNames $driverNames `
        -ExpectedBaselineSha256 $script:ReviewedE1BaselineSha256 -ValidateOnly
    for($index=0;$index -lt $driverNames.Count;$index++){
        $entry=$plan.protectedDriverFiles[$index]
        Assert-StandardCoreV2ExactProperties -Value $entry -Names @('name','path','sha256') -Context 'Prepared protected driver file'
        if([string]$entry.name -cne $driverNames[$index] -or -not (Test-PathEqual -Left ([string]$entry.path) -Right ([string]$driverFiles[$index].path)) -or
            [string]$entry.sha256 -cne [string]$driverFiles[$index].sha256){throw "Protected source helper changed after preparation: $($driverNames[$index])"}
        if($driverNames[$index] -ceq 'SkillSpectorReviewedE1Baselines.json' -and [string]$entry.sha256 -cne $script:ReviewedE1BaselineSha256){throw 'Prepared protected reviewed E1 policy differs from its pinned artifact.'}
    }

    $tree=Get-StandardCoreV2GitTree -GitPath $git -Root $candidateSourceRoot -Revision $revision
    foreach($required in @('catalog/source.json','scripts/Test-Repository.ps1','scripts/Invoke-CoreRepositoryGeneral.ps1','scripts/Invoke-CorePester.ps1','scripts/CorePesterIntegrity.psm1',
        'scripts/SkillSpectorReviewedE1Baselines.json',
        'config/pester-6.2.0-closure.lock.json','config/standard-core-v2-preparation.json','.gitattributes')){
        if(-not $tree.ContainsKey($required)){throw "Prepared candidate commit is missing required source input '$required'."}
    }
    [void](New-ProtectedCandidateFilePins -GitPath $git -ProtectedRepositoryRoot $protectedDriverRepositoryRoot -ProtectedDriverRoot $trustedDriverRoot `
        -ProtectedDriverFiles @($driverFiles) -CandidateRoot $candidateSourceRoot -CandidateRevision $revision)
    $candidateReviewedBaseline=Join-Path $candidateSourceRoot 'scripts/SkillSpectorReviewedE1Baselines.json'
    if((Get-Sha $candidateReviewedBaseline) -cne $script:ReviewedE1BaselineSha256 -or
        (Get-StandardCoreV2GitBlobSha256 -GitPath $git -RepositoryRoot $candidateSourceRoot -ObjectId ([string]$tree['scripts/SkillSpectorReviewedE1Baselines.json'].objectId)) -cne $script:ReviewedE1BaselineSha256){
        throw 'Tracked candidate reviewed E1 policy differs from the pinned raw review artifact.'
    }
    $candidateLock=Join-Path $candidateSourceRoot 'config/pester-6.2.0-closure.lock.json'
    if((Get-Sha $candidateLock) -cne [string]$plan.pesterClosureLockSha256 -or
        (Get-StandardCoreV2GitBlobSha256 -GitPath $git -RepositoryRoot $candidateSourceRoot -ObjectId ([string]$tree['config/pester-6.2.0-closure.lock.json'].objectId)) -cne [string]$plan.pesterClosureLockSha256){
        throw 'Tracked candidate Pester closure lock differs from the pinned raw closure.'
    }
    $setupLock=Join-Path $setupRoot 'pester-6.2.0-closure.lock.json'
    if((Get-Sha $setupLock) -cne [string]$plan.pesterClosureLockSha256){throw 'Retained Pester closure lock differs from the tracked candidate lock.'}
    $pester=Get-CorePesterFrozenRuntimeFiles -OwnedRoot $trusted -EvidenceRoot $setupRoot -RuntimeExecutable $current `
        -SetupReceiptPath (Join-Path $trusted 'pester-setup/setup-receipt.json') -ClosureLockPath $setupLock
    if($pester.closureLockSha256 -cne [string]$plan.pesterClosureLockSha256){throw 'Verified Pester runtime receipt differs from the prepared closure.'}

    $receiptNames=@('skill-validator','skill-tools','skillspector')
    $receipts=[Collections.Generic.List[object]]::new(); $receiptData=@{}
    foreach($name in $receiptNames){
        $receiptPath=[IO.Path]::GetFullPath((Join-Path $setupRoot "receipt-$name.json"))
        Assert-StandardCoreV2NoReparseAncestors -Path $receiptPath -Context "Resolver receipt $name"
        $record=Read-StandardCoreV2StrictJson -Path $receiptPath -Context "Resolver receipt $name"
        if([string]$record.toolName -cne $name -or [string]$record.resolutionRunId -cne [string]$plan.runId){throw "Resolver receipt does not bind this source setup: $name"}
        [void](Assert-StandardCoreV2ResolverReceiptPaths -Receipt $record -ExpectedInstallParent $toolInstallParent -ExpectedRunId ([string]$plan.runId) `
            -CandidateRoot $candidateSourceRoot -ArtifactsRoot $artifact)
        $receiptData[$name]=$record
        $receipts.Add([pscustomobject]@{path=$receiptPath;sha256=(Get-Sha $receiptPath)})
    }
    if($plan.sourceValidation -isnot [pscustomobject]){throw 'Prepared source validation specification must be a JSON object.'}
    $requiredSlots=@($profile.sourceValidation.requiredSlots)
    Assert-StandardCoreV2ExactProperties -Value $plan.sourceValidation -Names $requiredSlots -Context 'Prepared source validation specification'
    $toolchain=Read-StandardCoreV2StrictJson -Path $toolchainPath -Context 'Prepared source toolchain'
    $toolchainProperties=@('centralRunnerPath','centralRunnerSha256','sourceRepository','sourceRevision','sourceBindingSha256','sourceToolWrapperPath','sourceToolWrapperSha256',
        'preparePesterRuntimePath','preparePesterRuntimeSha256','upstreamAdapterValidatorPath','upstreamAdapterValidatorSha256','upstreamPolicyPath','upstreamPolicySha256',
        'sourceArchivePath','sourceArchiveSha256','sourceArchiveLength','runtimeExecutable','runtimeSha256',
        'skillValidatorPath','skillValidatorSha256','skillToolsNodePath','skillToolsNodeSha256','skillToolsEntryPointPath','skillToolsEntryPointSha256',
        'skillSpectorPath','skillSpectorSha256','skillSpectorReceiptPath','skillSpectorReceiptSha256')
    Assert-StandardCoreV2ExactProperties -Value $toolchain -Names $toolchainProperties -Context 'Prepared source toolchain'
    $expectedToolchain=[ordered]@{
        centralRunnerPath=$runner; centralRunnerSha256=(Get-Sha $runner); sourceRepository=[string]$profile.source.repository; sourceRevision=$revision; sourceBindingSha256=$bindingHash
        sourceArchivePath=[IO.Path]::GetFullPath((Join-Path $setupRoot "source-archive-$($plan.runId).tar")); sourceArchiveSha256=[string]$plan.sourceArchiveSha256; sourceArchiveLength=[long]$plan.sourceArchiveLength
        runtimeExecutable=$current; runtimeSha256=(Get-Sha $current)
        sourceToolWrapperPath=(Join-Path $trustedDriverRoot 'Invoke-CoreSourceTool.ps1'); sourceToolWrapperSha256=(Get-Sha (Join-Path $trustedDriverRoot 'Invoke-CoreSourceTool.ps1'))
        preparePesterRuntimePath=(Join-Path $trustedDriverRoot 'Prepare-PesterRuntime.ps1'); preparePesterRuntimeSha256=(Get-Sha (Join-Path $trustedDriverRoot 'Prepare-PesterRuntime.ps1'))
        upstreamAdapterValidatorPath=(Join-Path $authorityCheckoutRoot 'scripts/Validate-UpstreamAdapter.ps1'); upstreamAdapterValidatorSha256=(Get-Sha (Join-Path $authorityCheckoutRoot 'scripts/Validate-UpstreamAdapter.ps1'))
        upstreamPolicyPath=(Join-Path $authorityCheckoutRoot 'docs/standards/upstream-adapter.json'); upstreamPolicySha256=(Get-Sha (Join-Path $authorityCheckoutRoot 'docs/standards/upstream-adapter.json'))
        skillValidatorPath=[string]$receiptData.'skill-validator'.executablePath; skillValidatorSha256=[string]$receiptData.'skill-validator'.executableSha256
        skillToolsNodePath=[string]$receiptData.'skill-tools'.nodePath; skillToolsNodeSha256=[string]$receiptData.'skill-tools'.nodeSha256
        skillToolsEntryPointPath=[string]$receiptData.'skill-tools'.entryPointPath; skillToolsEntryPointSha256=[string]$receiptData.'skill-tools'.entryPointSha256
        skillSpectorPath=[string]$receiptData.skillspector.executablePath; skillSpectorSha256=[string]$receiptData.skillspector.executableSha256
        skillSpectorReceiptPath=[string]$receipts[2].path; skillSpectorReceiptSha256=[string]$receipts[2].sha256
    }
    foreach($name in $toolchainProperties){if([string]$toolchain.$name -cne [string]$expectedToolchain[$name]){throw "Prepared source toolchain binding differs from its verified inputs: $name"}}
    if(-not (Test-PathEqual -Left ([string]$plan.sourceArchivePath) -Right ([string]$expectedToolchain.sourceArchivePath)) -or
       [string]$plan.sourceArchiveSha256 -cne [string]$toolchain.sourceArchiveSha256 -or [long]$plan.sourceArchiveLength -ne [long]$toolchain.sourceArchiveLength -or
       [string]$toolchain.sourceArchivePath -cne [string]$expectedToolchain.sourceArchivePath) {throw 'Prepared source archive path differs from its run-derived binding.'}
    if(-not (Test-Path -LiteralPath $toolchain.sourceArchivePath -PathType Leaf) -or (Get-Sha ([string]$toolchain.sourceArchivePath)) -cne [string]$toolchain.sourceArchiveSha256 -or
       (Get-Item -LiteralPath $toolchain.sourceArchivePath).Length -ne [long]$toolchain.sourceArchiveLength){throw 'Prepared source archive bytes or length changed.'}
    $replayArchivePath=Join-Path $setupRoot "source-archive-replay-$($plan.runId).tar"
    $replayArchive=New-StandardCoreV2GitArchive -GitPath $git -RepositoryRoot $candidateMetadataRoot -OwnedRoot $setupRoot `
        -Destination $replayArchivePath -Revision $revision
    if([string]$replayArchive.sha256 -cne [string]$toolchain.sourceArchiveSha256 -or [long]$replayArchive.length -ne [long]$toolchain.sourceArchiveLength){
        throw 'Recomputed bound source archive differs from the frozen prepared archive.'
    }
    if((Get-Sha $toolchainPath) -cne [string]$plan.toolchainSha256){throw 'Prepared source toolchain bytes changed.'}
    $sourceArgs=@('-NoProfile','-NonInteractive','-File',(Join-Path $trustedDriverRoot 'Invoke-CoreSourceTool.ps1'),'-ToolchainPath',$toolchainPath,'-ToolchainSha256',[string]$plan.toolchainSha256)
    foreach($slot in @('packageAdapter','skillValidator','skillTools','staticAnalyzer')){
        Assert-StandardCoreV2ExactProperties -Value $plan.sourceValidation.$slot -Names @('command','arguments') -Context "Source dispatch $slot"
        $toolDispatchMode= switch($slot){'packageAdapter'{'package-adapter'} 'skillValidator'{'skill-validator'} 'skillTools'{'skill-tools'} 'staticAnalyzer'{'static'}}
        $expectedArgs=@($sourceArgs+@('-Mode',$toolDispatchMode))
        if([string]$plan.sourceValidation.$slot.command -cne $current -or @($plan.sourceValidation.$slot.arguments).Count -ne $expectedArgs.Count){throw "Source dispatch $slot differs from the protected tool wrapper."}
        for($i=0;$i -lt $expectedArgs.Count;$i++){if([string]$plan.sourceValidation.$slot.arguments[$i] -cne [string]$expectedArgs[$i]){throw "Source dispatch $slot arguments differ from the protected tool wrapper."}}
    }

    $frozen=[Collections.Generic.List[object]]::new(); $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($entry in $pester.frozenFiles){Add-Frozen $frozen $seen ([string]$entry.path)}
    foreach($entry in $profile.authority.files){Add-Frozen $frozen $seen (Join-Path $authorityCheckoutRoot ([string]$entry.path).Replace('/',[IO.Path]::DirectorySeparatorChar))}
    foreach($entry in $profile.authority.files){Add-Frozen $frozen $seen (Join-Path $authorityTupleRoot ([string]$entry.path).Replace('/',[IO.Path]::DirectorySeparatorChar))}
    foreach($entry in $receipts){Add-Frozen $frozen $seen ([string]$entry.path)}
    foreach($path in @((Join-Path $candidateSourceRoot 'scripts/Test-Repository.ps1'),(Join-Path $candidateSourceRoot 'scripts/Invoke-CoreRepositoryGeneral.ps1'),
        (Join-Path $candidateSourceRoot 'scripts/Invoke-CorePester.ps1'),(Join-Path $candidateSourceRoot 'scripts/CorePesterIntegrity.psm1'),
        (Join-Path $candidateSourceRoot 'scripts/StandardCoreSourcePreparation.psm1'),
        $candidateReviewedBaseline,
        (Join-Path $candidateSourceRoot 'config/pester-6.2.0-closure.lock.json'),(Join-Path $candidateSourceRoot 'config/standard-core-v2-preparation.json'),
        (Join-Path $candidateSourceRoot '.gitattributes'),$setupLock,$bindingPath,$toolchainPath,[string]$toolchain.sourceArchivePath,$pester.setupReceiptPath)){Add-Frozen $frozen $seen $path}
    foreach($entry in $driverFiles){Add-Frozen $frozen $seen ([string]$entry.path)}
    foreach($receipt in $receiptData.Values){foreach($key in @('executablePath','nodePath','entryPointPath')){if($receipt.PSObject.Properties[$key]){Add-Frozen $frozen $seen ([string]$receipt.$key)}}}
    if($plan.sourceValidation.frozenFiles -isnot [array] -or @($plan.sourceValidation.frozenFiles).Count -ne $frozen.Count){throw 'Prepared frozen-file inventory differs from the reconstructed protected inputs.'}
    $actualFrozen=@($plan.sourceValidation.frozenFiles | Sort-Object -Property path -CaseSensitive); $expectedFrozen=@($frozen.ToArray() | Sort-Object -Property path -CaseSensitive)
    for($i=0;$i -lt $expectedFrozen.Count;$i++){
        Assert-StandardCoreV2ExactProperties -Value $actualFrozen[$i] -Names @('path','sha256') -Context 'Prepared frozen-file record'
        if(-not (Test-PathEqual -Left ([string]$actualFrozen[$i].path) -Right ([string]$expectedFrozen[$i].path)) -or [string]$actualFrozen[$i].sha256 -cne [string]$expectedFrozen[$i].sha256){throw 'Prepared frozen-file inventory differs from the reconstructed protected inputs.'}
    }
    $sourceReceipts=@($plan.sourceValidation.toolReceipts | Sort-Object -Property path -CaseSensitive)
    $expectedReceipts=@($receipts.ToArray() | Sort-Object -Property path -CaseSensitive)
    if($sourceReceipts.Count -ne 3){throw 'Prepared source tool receipt inventory is incomplete.'}
    for($i=0;$i -lt 3;$i++){
        Assert-StandardCoreV2ExactProperties -Value $sourceReceipts[$i] -Names @('path','sha256') -Context 'Prepared source tool receipt binding'
        if(-not (Test-PathEqual -Left ([string]$sourceReceipts[$i].path) -Right ([string]$expectedReceipts[$i].path)) -or [string]$sourceReceipts[$i].sha256 -cne [string]$expectedReceipts[$i].sha256){throw 'Prepared source tool receipt inventory differs from resolver outputs.'}
    }
    [void](Invoke-StandardCoreSourcePlanIntegrity -RunnerPath $runner -CandidateRoot $candidateSourceRoot -AdapterPath (Join-Path $adapterRoot 'standard-core-adapter.json') `
        -ArtifactsRoot $artifact -SourceRepository ([string]$profile.source.repository) -SourceRevision $revision -AuthorityRevision ([string]$profile.authority.commit) `
        -RunId ([string]$plan.runId) -TrustedToolRoot $trusted -FrozenFiles @($plan.sourceValidation.frozenFiles) -ToolReceipts @($plan.sourceValidation.toolReceipts))

    $catalog=Read-StandardCoreV2StrictJson -Path (Join-Path $candidateSourceRoot 'catalog/source.json') -Context 'Candidate Skill catalog'
    $skills=[string[]]@($catalog.skills | ForEach-Object {[string]$_}); if($skills.Count -eq 0 -or @($skills|Select-Object -Unique).Count -ne $skills.Count){throw 'Candidate active Skill inventory is invalid.'}
    $checks=@(); foreach($check in $profile.checks){
        $checkArgs=@('-NoProfile','-NonInteractive','-File',[string]$check.script)+@($check.arguments | ForEach-Object {if($_ -ceq '<source-binding-sha256>'){[string]$plan.bindingSha256}else{[string]$_}})
        $checks+=,[ordered]@{id=[string]$check.id;kind=[string]$check.kind;executable=$current;executableSha256=(Get-Sha $current);arguments=$checkArgs}
    }
    $adapterPath=Join-Path $adapterRoot 'standard-core-adapter.json'
    $adapter=[ordered]@{schemaVersion=2;adapter='standard-core-adapter-v2';skillsRoot=[string]$profile.source.skillsRoot;activeSkills=$skills;checks=$checks;sourceValidation=$plan.sourceValidation}
    Write-JsonCreateNew $adapterPath $adapter
    $output=if([string]::IsNullOrWhiteSpace($OutputPath)){Join-Path $artifact "standard-core-validation-v2-$($plan.runId).json"}else{Assert-PlanPath $OutputPath $artifact 'OutputPath'}
    if(Test-Path -LiteralPath $output){throw 'Core report output path already exists.'}
    $eventName=Get-EventName
    $runnerBudget=Get-StandardCoreV2ChildBudget -OperationTimeoutSeconds $OperationTimeoutSeconds -ChildLimitSeconds $TimeoutSeconds `
        -ElapsedMilliseconds ([long]$operationWatch.ElapsedMilliseconds) -Context 'Full source validation'
    $runnerProcessBudget=Get-StandardCoreV2RemainingSeconds -OperationTimeoutSeconds $OperationTimeoutSeconds `
        -ElapsedMilliseconds ([long]$operationWatch.ElapsedMilliseconds) -Context 'Full source validation process boundary'
    $runnerArgs=New-StandardCoreV2CoreRunnerArguments -LiveCandidateRoot $repo -RawCandidateRoot $candidateSourceRoot -RunnerPath $runner -AdapterPath $adapterPath `
        -ArtifactsRoot $artifact -OutputPath $output -SourceRepository ([string]$profile.source.repository) -SourceRevision $revision `
        -BaseRevision ([string]$plan.baseRevision) -EventName $eventName -AuthorityRevision ([string]$profile.authority.commit) `
        -TimeoutSeconds ([string]$runnerBudget) -TrustedToolRoot $trusted -RunId ([string]$plan.runId)
    $fullSourceStarted=[DateTimeOffset]::UtcNow
    $fullSourceWatch=[Diagnostics.Stopwatch]::StartNew()
    $coreResult=Invoke-StandardCoreSupervisedProcess -RunnerPath $runner -CandidateRoot $candidateSourceRoot -AdapterPath $adapterPath -ArtifactsRoot $artifact `
        -SourceRepository ([string]$profile.source.repository) -SourceRevision $revision -AuthorityRevision ([string]$profile.authority.commit) -RunId ([string]$plan.runId) `
        -TrustedToolRoot $trusted -PowerShell $current -Arguments $runnerArgs -WorkingDirectory $setupRoot -OwnedRoot $trusted -LimitSeconds $runnerProcessBudget
    $fullSourceWatch.Stop()
    $processEvidencePath=Join-Path $setupRoot "source-validation-process-$($plan.runId).json"
    $timingEvidencePath=Join-Path $setupRoot "source-validation-timings-$($plan.runId).json"
    $processEvidence=[ordered]@{startedAtUtc=$fullSourceStarted.ToString('o');elapsedMilliseconds=$fullSourceWatch.ElapsedMilliseconds;status=[string]$coreResult.status;
        exitCode=[int]$coreResult.exitCode;cleanedUp=[bool]$coreResult.cleanedUp;stdout=[string]$coreResult.stdout;stderr=[string]$coreResult.stderr;result=$coreResult}
    Write-JsonCreateNew $processEvidencePath $processEvidence
    Write-JsonCreateNew $timingEvidencePath ([ordered]@{fullSourceValidationMilliseconds=$fullSourceWatch.ElapsedMilliseconds;startedAtUtc=$fullSourceStarted.ToString('o');
        setupTimingsPath=(Join-Path $setupRoot 'setup-timings.json');processEvidencePath=$processEvidencePath})
    if($coreResult.status -cne 'passed' -or $coreResult.exitCode -ne 0 -or -not $coreResult.cleanedUp){throw "Protected source validation runner failed: $($coreResult.status), exit=$($coreResult.exitCode), cleanup=$($coreResult.cleanedUp). $($coreResult.stderr)"}
    if(-not (Test-Path -LiteralPath $output -PathType Leaf)){throw 'Core source run did not publish its report.'}
    $report=Read-StandardCoreV2StrictJson -Path $output -Context 'Core source report'
    $snapshot=[string]$report.artifacts.snapshotRoot
    $reportReplayBudget=Get-StandardCoreV2RemainingSeconds -OperationTimeoutSeconds $OperationTimeoutSeconds `
        -ElapsedMilliseconds ([long]$operationWatch.ElapsedMilliseconds) -Context 'Strict source report replay'
    [void](Invoke-StandardCoreSourceReportReplay -RunnerPath $runner -CandidateRoot $snapshot -AdapterPath $adapterPath -ArtifactsRoot $artifact `
        -SourceRepository ([string]$profile.source.repository) -SourceRevision $revision -BaseRevision ([string]$plan.baseRevision) -AuthorityRevision ([string]$profile.authority.commit) `
        -RunId ([string]$plan.runId) -TrustedToolRoot $trusted -LimitSeconds $reportReplayBudget -Report $report -OutputPath $output -EventName $eventName `
        -ProcessExitCode ([int]$coreResult.exitCode) -FrozenFiles @($plan.sourceValidation.frozenFiles))
    [void](Get-StandardCoreV2RemainingSeconds -OperationTimeoutSeconds $OperationTimeoutSeconds `
        -ElapsedMilliseconds ([long]$operationWatch.ElapsedMilliseconds) -Context 'Strict source report replay')
    $packageAdapterEvents=@($report.sourceValidation.events | Where-Object { [string]$_.toolId -ceq 'package-adapter' })
    if($packageAdapterEvents.Count -ne 1){throw 'Source report must contain exactly one package-adapter event for domain evidence replay.'}
    $packageAdapterEvent=$packageAdapterEvents[0]
    $packageAdapterRawEvent=Read-StandardCoreV2StrictJson -Path ([string]$packageAdapterEvent.outputPath) -Context 'Package adapter event output'
    $packageAdapterEnvelope=([string]$packageAdapterRawEvent.stdout) | ConvertFrom-Json -Depth 80 -ErrorAction Stop
    [void](Get-StandardCoreV2RemainingSeconds -OperationTimeoutSeconds $OperationTimeoutSeconds `
        -ElapsedMilliseconds ([long]$operationWatch.ElapsedMilliseconds) -Context 'Domain adapter report replay')
    [void](Assert-StandardCoreV2DomainAdapterEvent -Envelope $packageAdapterEnvelope -Event $packageAdapterEvent -CoreReport $report `
        -Plan $plan -Toolchain $toolchain -ExpectedPackageRoot $snapshot -MetadataRoot $candidateMetadataRoot)
    [void](Get-StandardCoreV2RemainingSeconds -OperationTimeoutSeconds $OperationTimeoutSeconds `
        -ElapsedMilliseconds ([long]$operationWatch.ElapsedMilliseconds) -Context 'Domain adapter report replay')
    [void](Assert-StandardCoreV2SourceBinding -SnapshotRoot $snapshot -ExpectedSha256 ([string]$plan.bindingSha256) -RunId ([string]$plan.runId) `
        -MetadataRoot $candidateMetadataRoot -GitPath $git)
    $snapshotLock=Join-Path $snapshot 'config/pester-6.2.0-closure.lock.json'
    if((Get-Sha $snapshotLock) -cne [string]$plan.pesterClosureLockSha256){throw 'Central candidate snapshot Pester lock differs from the frozen setup lock.'}
    [void](Get-StandardCoreV2RemainingSeconds -OperationTimeoutSeconds $OperationTimeoutSeconds `
        -ElapsedMilliseconds ([long]$operationWatch.ElapsedMilliseconds) -Context 'Core v2 source operation completion')
    [Console]::Out.WriteLine((ConvertTo-Json -InputObject ([ordered]@{status='passed';runId=$plan.runId;reportPath=$output;snapshotRoot=$snapshot}) -Compress))
    exit 0
}
catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
finally { Clear-StandardCoreV2GitOperationContext }
