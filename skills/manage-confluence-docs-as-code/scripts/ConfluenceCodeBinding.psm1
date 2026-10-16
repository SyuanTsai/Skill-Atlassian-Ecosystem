# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
Import-Module -Name (Join-Path $PSScriptRoot 'StrictJson.psm1') -Scope Local

function Test-GitPath {
    param([string]$Path)
    if([string]::IsNullOrWhiteSpace($Path) -or $Path -match '[\\\r\n]' -or $Path -match '^[A-Za-z]:' -or
        $Path.StartsWith('/',[StringComparison]::Ordinal)){return $false}
    foreach($part in ($Path -split '/')){if($part -in @('', '.', '..')){return $false}}
    return $true
}

function Resolve-BindingRepo {
    param([string]$Root,[string]$RepositoryPath)
    if([string]::IsNullOrWhiteSpace($RepositoryPath)){return $null}
    if(-not [IO.Path]::IsPathRooted($RepositoryPath) -and $RepositoryPath -cne '.'){
        if(-not(Test-GitPath -Path $RepositoryPath)){return $null}
    }
    $path=if([IO.Path]::IsPathRooted($RepositoryPath)){$RepositoryPath}else{Join-Path $Root $RepositoryPath}
    if(-not(Test-Path -LiteralPath $path -PathType Container)){return $null}
    $full=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $path).Path)
    $top=& git -C $full rev-parse --show-toplevel 2>$null
    if($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$top)){return $null}
    return $full
}

function Test-ExactCommit {
    param([string]$Repo,[string]$Commit)
    if($Commit -cnotmatch '^(?:[a-f0-9]{40}|[a-f0-9]{64})$'){return $false}
    $resolved=& git -C $Repo rev-parse --verify ($Commit+'^{commit}') 2>$null
    return $LASTEXITCODE -eq 0 -and [string]$resolved -ceq $Commit
}

function Get-BindingBlob {
    param([string]$Repo,[string]$Commit,[string]$Path)
    if(-not(Test-GitPath -Path $Path)){return $null}
    $oid=& git -C $Repo rev-parse --verify ($Commit+':'+$Path) 2>$null
    if($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$oid)){return $null}
    $kind=& git -C $Repo cat-file -t $oid 2>$null
    if($LASTEXITCODE -ne 0 -or [string]$kind -cne 'blob'){return $null}
    return [string]$oid
}

function Resolve-ConfluenceMarkdownCodeBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$BindingPath,
        [Parameter(Mandatory)][string]$DocsCommit,
        [Parameter(Mandatory)][string[]]$RequiredDocsSourcePaths,
        [Parameter(Mandatory)][string]$ReviewPath
    )
    $failure = { param($reason) [pscustomobject]@{status='invalid';reasonCodes=@($reason);docsCommit='';codeCommit='';docsSourcePaths=@();codeRelevantPaths=@();bindingSha256=''} }
    if (-not (Test-Path -LiteralPath $Root -PathType Container) -or -not (Test-Path -LiteralPath $BindingPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $ReviewPath -PathType Leaf)) { return & $failure 'CodeCurrentEvidenceRequired' }
    $rootFull=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path)
    $bindingFull=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $BindingPath).Path)
    $bindingRelative=[IO.Path]::GetRelativePath($rootFull,$bindingFull).Replace([IO.Path]::DirectorySeparatorChar,'/').Replace([IO.Path]::AltDirectorySeparatorChar,'/')
    if (-not (Test-GitPath -Path $bindingRelative)) { return & $failure 'BindingPathInvalid' }
    try {
        $bindingBytes=[IO.File]::ReadAllBytes($bindingFull)
        if($bindingBytes.Length -eq 0 -or $bindingBytes.Length -gt 1048576){throw 'BindingSizeInvalid'}
        $bindingText=[Text.UTF8Encoding]::new($false,$true).GetString($bindingBytes)
        $binding=ConvertFrom-Syp171StrictJson -Json $bindingText -Depth 12
        $bindingHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bindingBytes)).ToLowerInvariant()
    }
    catch { return & $failure 'BindingSchemaInvalid' }
    if (-not (Test-Syp171JsonKeys $binding @('schemaVersion','targetKind','docs','code')) -or
        $binding.schemaVersion -ne 2 -or $binding.targetKind -cne 'current' -or
        -not (Test-Syp171JsonKeys $binding.docs @('repositoryPath','commit','sourcePaths')) -or
        -not (Test-Syp171JsonKeys $binding.code @('repositoryPath','commit','relevantPaths')) -or
        $binding.docs.commit -cne $DocsCommit -or
        $binding.docs.sourcePaths -isnot [array] -or @($binding.docs.sourcePaths).Count -eq 0 -or
        $binding.code.relevantPaths -isnot [array] -or @($binding.code.relevantPaths).Count -eq 0) { return & $failure 'BindingSchemaInvalid' }
    $docsRepo=Resolve-BindingRepo -Root $rootFull -RepositoryPath ([string]$binding.docs.repositoryPath)
    $codeRepo=Resolve-BindingRepo -Root $rootFull -RepositoryPath ([string]$binding.code.repositoryPath)
    if ($null -eq $docsRepo -or $null -eq $codeRepo -or
        -not (Test-ExactCommit -Repo $docsRepo -Commit ([string]$binding.docs.commit)) -or
        -not (Test-ExactCommit -Repo $codeRepo -Commit ([string]$binding.code.commit))) { return & $failure 'RevisionUnresolved' }
    $sourceSet=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in @($binding.docs.sourcePaths)) {
        if (-not (Test-GitPath -Path ([string]$path)) -or -not $sourceSet.Add([string]$path)) { return & $failure 'SourcePathInvalid' }
        $working=[IO.Path]::GetFullPath((Join-Path $rootFull ([string]$path)))
        $workingRelative=[IO.Path]::GetRelativePath($rootFull,$working)
        if ($workingRelative -eq '..' -or $workingRelative.StartsWith(('..'+[IO.Path]::DirectorySeparatorChar),[StringComparison]::Ordinal) -or
            [IO.Path]::IsPathRooted($workingRelative) -or -not (Test-Path -LiteralPath $working -PathType Leaf)) { return & $failure 'SourcePathUnresolved' }
        $current=$working
        while ($current -ne $rootFull) {
            if (Test-Path -LiteralPath $current) {
                $item=Get-Item -LiteralPath $current -Force
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return & $failure 'SourcePathInvalid' }
            }
            $current=[IO.Path]::GetDirectoryName($current)
            if ([string]::IsNullOrWhiteSpace($current)) { return & $failure 'SourcePathInvalid' }
        }
        $committed=Get-BindingBlob -Repo $docsRepo -Commit ([string]$binding.docs.commit) -Path ([string]$path)
        if ($null -eq $committed) { return & $failure 'SourcePathUnresolved' }
        $effective=& git -C $docsRepo hash-object "--path=$path" -- $working 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]$effective -cne $committed) { return & $failure 'BoundSourceChanged' }
    }
    foreach ($path in @($RequiredDocsSourcePaths)) {
        if ($path -cnotin $sourceSet) { return & $failure 'BoundSourceIncomplete' }
    }
    $reviewFull=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $ReviewPath).Path)
    $reviewRelative=[IO.Path]::GetRelativePath($rootFull,$reviewFull).Replace([IO.Path]::DirectorySeparatorChar,'/').Replace([IO.Path]::AltDirectorySeparatorChar,'/')
    if (-not (Test-GitPath -Path $reviewRelative)) { return & $failure 'ReviewPathInvalid' }
    $requiredSet=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($path in @($RequiredDocsSourcePaths)){ $null=$requiredSet.Add([string]$path) }
    if(@($requiredSet|Where-Object { $_ -cnotin $sourceSet }).Count -gt 0){ return & $failure 'BoundSourceIncomplete' }
    $docLines=[System.Collections.Generic.List[string]]::new()
    foreach($path in @($binding.docs.sourcePaths|Sort-Object -CaseSensitive)){
        $oid=Get-BindingBlob -Repo $docsRepo -Commit ([string]$binding.docs.commit) -Path ([string]$path)
        if($null -eq $oid){return & $failure 'SourcePathUnresolved'}
        $docLines.Add('docs:'+([string]$binding.docs.commit)+':'+[string]$path+':'+$oid)
    }
    foreach ($path in @($binding.code.relevantPaths)) {
        if (-not (Test-GitPath -Path ([string]$path))) { return & $failure 'RelevantPathInvalid' }
        $committedCode=Get-BindingBlob -Repo $codeRepo -Commit ([string]$binding.code.commit) -Path ([string]$path)
        if ($null -eq $committedCode) { return & $failure 'RelevantPathInvalid' }
        $headCommit=& git -C $codeRepo rev-parse --verify 'HEAD^{commit}' 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$headCommit)) { return & $failure 'BoundCodePathInvalid' }
        $headCode=Get-BindingBlob -Repo $codeRepo -Commit ([string]$headCommit) -Path ([string]$path)
        if ($null -eq $headCode -or [string]$headCode -cne [string]$committedCode) { return & $failure 'BoundCodeChanged' }
        $workingCode=[IO.Path]::GetFullPath((Join-Path $codeRepo ([string]$path)))
        $codeRelative=[IO.Path]::GetRelativePath($codeRepo,$workingCode)
        if ($codeRelative -eq '..' -or $codeRelative.StartsWith(('..'+[IO.Path]::DirectorySeparatorChar),[StringComparison]::Ordinal) -or
            [IO.Path]::IsPathRooted($codeRelative) -or -not (Test-Path -LiteralPath $workingCode -PathType Leaf)) { return & $failure 'BoundCodePathInvalid' }
        $currentCodePath=$workingCode
        while ($currentCodePath -ne $codeRepo) {
            $codeItem=Get-Item -LiteralPath $currentCodePath -Force -ErrorAction SilentlyContinue
            if ($null -eq $codeItem -or ($codeItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return & $failure 'BoundCodePathInvalid' }
            $currentCodePath=[IO.Path]::GetDirectoryName($currentCodePath)
            if ([string]::IsNullOrWhiteSpace($currentCodePath)) { return & $failure 'BoundCodePathInvalid' }
        }
        $workingCodeObject=& git -C $codeRepo hash-object "--path=$path" -- $workingCode 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]$workingCodeObject -cne [string]$committedCode) { return & $failure 'BoundCodeChanged' }
    }
    try{
        $reviewFull=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $ReviewPath).Path)
        $reviewBytes=[IO.File]::ReadAllBytes($reviewFull)
        if($reviewBytes.Length -eq 0 -or $reviewBytes.Length -gt 1048576){throw 'ReviewSizeInvalid'}
        $reviewText=[Text.UTF8Encoding]::new($false,$true).GetString($reviewBytes)
        $review=ConvertFrom-Syp171StrictJson -Json $reviewText -Depth 10
        $reviewHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($reviewBytes)).ToLowerInvariant()
    }catch{$review=$null;$reviewBytes=[byte[]]@();$reviewHash=''}
    $reviewValid=(Test-Syp171JsonKeys -Value $review -Expected @('schemaVersion','outcome','docsCommit','codeCommit','bindingSha256','evidencePaths')) -and
        $review.schemaVersion -eq 1 -and $review.outcome -ceq 'still-correct' -and
        $review.docsCommit -ceq [string]$binding.docs.commit -and $review.codeCommit -ceq [string]$binding.code.commit -and
        $review.bindingSha256 -ceq $bindingHash -and $review.evidencePaths -is [array] -and @($review.evidencePaths).Count -gt 0
    if(-not $reviewValid){ return & $failure 'CodeReviewRequired' }
    $reviewedPaths=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($path in @($review.evidencePaths)){
        if(-not (Test-GitPath -Path ([string]$path)) -or -not $reviewedPaths.Add([string]$path) -or
            $null -eq (Get-BindingBlob -Repo $codeRepo -Commit ([string]$binding.code.commit) -Path ([string]$path))){return & $failure 'CodeReviewEvidenceInvalid'}
    }
    foreach($path in @($binding.code.relevantPaths)){if(-not $reviewedPaths.Contains([string]$path)){return & $failure 'CodeReviewEvidenceIncomplete'}}
    $sourceDigest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($docLines -join "`n")+"`n"))).ToLowerInvariant()
    $bindingAfter=[IO.File]::ReadAllBytes($bindingFull)
    $reviewAfter=[IO.File]::ReadAllBytes($reviewFull)
    if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bindingAfter)).ToLowerInvariant() -cne $bindingHash -or
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($reviewAfter)).ToLowerInvariant() -cne $reviewHash){
        return & $failure 'CodeReviewChangedDuringValidation'
    }
    return [pscustomobject]@{
        status='valid';reasonCodes=@();docsCommit=[string]$binding.docs.commit;codeCommit=[string]$binding.code.commit
        docsSourcePaths=@($binding.docs.sourcePaths);codeRelevantPaths=@($binding.code.relevantPaths)
        bindingSha256=$bindingHash
        reviewSha256=$reviewHash;sourceDigest=$sourceDigest;codeRepository=$codeRepo
    }
}

Export-ModuleMember -Function Resolve-ConfluenceMarkdownCodeBinding
