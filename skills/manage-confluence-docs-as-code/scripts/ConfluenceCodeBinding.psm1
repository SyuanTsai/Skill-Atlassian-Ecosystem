# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
Import-Module -Name (Join-Path $PSScriptRoot 'StrictJson.psm1') -Force -Scope Local

function New-BindingResult {
    param([string] $Status, [string[]] $ReasonCodes, [string] $DocsCommit, [string] $SpecCommit,
          [string] $CodeCommit, [string] $SourceDigest, [string[]] $ChangedRelevantPaths,
          [string] $CodeRepository='', [string[]] $CodeRelevantPaths=@(), [string] $SpecRepository='', [string[]] $SpecSourcePaths=@())
    return [pscustomobject]@{
        status=$Status; reasonCodes=@($ReasonCodes); docsCommit=$DocsCommit; specCommit=$SpecCommit
        codeCommit=$CodeCommit; codeRepository=$CodeRepository; codeRelevantPaths=@($CodeRelevantPaths); specRepository=$SpecRepository
        specSourcePaths=@($SpecSourcePaths); sourceDigest=$SourceDigest; changedRelevantPaths=@($ChangedRelevantPaths)
    }
}

function Test-GitPath {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -match '[\\\r\n]' -or $Path -match '^[A-Za-z]:' -or
        $Path.StartsWith('/', [StringComparison]::Ordinal)) { return $false }
    foreach ($part in ($Path -split '/')) { if ($part -in @('', '.', '..')) { return $false } }
    return $true
}

function Resolve-BindingRepo {
    param([string] $Root, [string] $RepositoryPath)
    if ([string]::IsNullOrWhiteSpace($RepositoryPath)) { return $null }
    if (-not [IO.Path]::IsPathRooted($RepositoryPath) -and $RepositoryPath -ne '.') {
        if (-not (Test-GitPath -Path $RepositoryPath)) { return $null }
    }
    $path = if ([IO.Path]::IsPathRooted($RepositoryPath)) { $RepositoryPath } else { Join-Path $Root $RepositoryPath }
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { return $null }
    $full = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $path).Path)
    $top = & git -C $full rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string] $top)) { return $null }
    return $full
}

function Test-ExactCommit {
    param([string] $Repo, [string] $Commit)
    if ($Commit -cnotmatch '^(?:[a-f0-9]{40}|[a-f0-9]{64})$') { return $false }
    $resolved = & git -C $Repo rev-parse --verify "$Commit`^{commit}" 2>$null
    return $LASTEXITCODE -eq 0 -and [string] $resolved -ceq $Commit
}

function Get-BindingBlob {
    param([string] $Repo, [string] $Commit, [string] $Path)
    if (-not (Test-GitPath -Path $Path)) { return $null }
    $oid = & git -C $Repo rev-parse --verify "$Commit`:$Path" 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string] $oid)) { return $null }
    $kind = & git -C $Repo cat-file -t $oid 2>$null
    if ($LASTEXITCODE -ne 0 -or [string] $kind -cne 'blob') { return $null }
    return [string] $oid
}

function Get-BindingSourceDigest {
    param([object] $Docs, [object] $Spec)
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($Docs, $Spec)) {
        foreach ($path in @($item.sourcePaths | Sort-Object -CaseSensitive)) {
            $oid = Get-BindingBlob -Repo $item.repo -Commit $item.commit -Path $path
            if ($null -eq $oid) { return $null }
            $lines.Add("$($item.kind):$($item.commit):${path}:$oid")
        }
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($lines -join "`n") + "`n")
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Resolve-ConfluenceCodeBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $BindingPath,
        [string] $ReviewPath
    )
    if (-not (Test-Path -LiteralPath $Root -PathType Container) -or -not (Test-Path -LiteralPath $BindingPath -PathType Leaf)) {
        return New-BindingResult -Status 'invalid' -ReasonCodes @('BindingUnavailable') -DocsCommit '' -SpecCommit '' -CodeCommit '' -SourceDigest '' -ChangedRelevantPaths @()
    }
    $rootFull = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path)
    $bindingFull = [IO.Path]::GetFullPath($BindingPath)
    $relative = [IO.Path]::GetRelativePath($rootFull, $bindingFull)
    if (-not (Test-GitPath -Path $relative)) {
        return New-BindingResult -Status 'invalid' -ReasonCodes @('BindingPathInvalid') -DocsCommit '' -SpecCommit '' -CodeCommit '' -SourceDigest '' -ChangedRelevantPaths @()
    }
    try { $binding = Read-Syp171StrictJsonFile -Path $bindingFull -Depth 15 }
    catch { return New-BindingResult -Status 'invalid' -ReasonCodes @('BindingSchemaInvalid') -DocsCommit '' -SpecCommit '' -CodeCommit '' -SourceDigest '' -ChangedRelevantPaths @() }
    if (-not (Test-Syp171JsonKeys -Value $binding -Expected @('schemaVersion','targetKind','docs','spec','code')) -or
        $binding.schemaVersion -ne 1 -or $binding.targetKind -notin @('current','historical','proposed') -or
        -not (Test-Syp171JsonKeys -Value $binding.docs -Expected @('repositoryPath','commit','sourcePaths')) -or
        -not (Test-Syp171JsonKeys -Value $binding.spec -Expected @('repositoryPath','commit','sourcePaths')) -or
        -not (Test-Syp171JsonKeys -Value $binding.code -Expected @('repositoryPath','baselineCommit','targetCommit','relevantPaths')) -or
        @($binding.docs.sourcePaths).Count -eq 0 -or @($binding.spec.sourcePaths).Count -eq 0 -or @($binding.code.relevantPaths).Count -eq 0) {
        return New-BindingResult -Status 'invalid' -ReasonCodes @('BindingSchemaInvalid') -DocsCommit '' -SpecCommit '' -CodeCommit '' -SourceDigest '' -ChangedRelevantPaths @()
    }
    $docsRepo = Resolve-BindingRepo -Root $rootFull -RepositoryPath $binding.docs.repositoryPath
    $specRepo = Resolve-BindingRepo -Root $rootFull -RepositoryPath $binding.spec.repositoryPath
    $codeRepo = Resolve-BindingRepo -Root $rootFull -RepositoryPath $binding.code.repositoryPath
    if ($null -eq $docsRepo -or $null -eq $specRepo -or $null -eq $codeRepo -or
        -not (Test-ExactCommit -Repo $docsRepo -Commit $binding.docs.commit) -or
        -not (Test-ExactCommit -Repo $specRepo -Commit $binding.spec.commit) -or
        -not (Test-ExactCommit -Repo $codeRepo -Commit $binding.code.baselineCommit) -or
        -not (Test-ExactCommit -Repo $codeRepo -Commit $binding.code.targetCommit)) {
        return New-BindingResult -Status 'invalid' -ReasonCodes @('RevisionUnresolved') -DocsCommit '' -SpecCommit '' -CodeCommit '' -SourceDigest '' -ChangedRelevantPaths @()
    }
    $docs = [pscustomobject]@{kind='docs';repo=$docsRepo;commit=$binding.docs.commit;sourcePaths=@($binding.docs.sourcePaths)}
    $spec = [pscustomobject]@{kind='spec';repo=$specRepo;commit=$binding.spec.commit;sourcePaths=@($binding.spec.sourcePaths)}
    $sourceDigest = Get-BindingSourceDigest -Docs $docs -Spec $spec
    if ($null -eq $sourceDigest) {
        return New-BindingResult -Status 'invalid' -ReasonCodes @('SourcePathUnresolved') -DocsCommit $binding.docs.commit -SpecCommit $binding.spec.commit -CodeCommit $binding.code.targetCommit -SourceDigest '' -ChangedRelevantPaths @()
    }
    foreach ($path in @($binding.code.relevantPaths)) {
        if (-not (Test-GitPath -Path [string] $path)) {
            return New-BindingResult -Status 'invalid' -ReasonCodes @('RelevantPathInvalid') -DocsCommit $binding.docs.commit -SpecCommit $binding.spec.commit -CodeCommit $binding.code.targetCommit -SourceDigest $sourceDigest -ChangedRelevantPaths @()
        }
    }
    $changed = @(& git -C $codeRepo diff --name-only --no-ext-diff $binding.code.baselineCommit $binding.code.targetCommit -- @($binding.code.relevantPaths))
    if ($LASTEXITCODE -ne 0) {
        return New-BindingResult -Status 'invalid' -ReasonCodes @('CodeDiffUnavailable') -DocsCommit $binding.docs.commit -SpecCommit $binding.spec.commit -CodeCommit $binding.code.targetCommit -SourceDigest $sourceDigest -ChangedRelevantPaths @()
    }
    $changed = @($changed | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $reasons = [System.Collections.Generic.List[string]]::new()
    if ($binding.targetKind -ceq 'current' -and $changed.Count -gt 0) {
        $reviewValid = $false
        if (-not [string]::IsNullOrWhiteSpace($ReviewPath) -and (Test-Path -LiteralPath $ReviewPath -PathType Leaf)) {
            try { $review = Read-Syp171StrictJsonFile -Path $ReviewPath -Depth 10 }
            catch { $review = $null }
            if ((Test-Syp171JsonKeys -Value $review -Expected @('schemaVersion','outcome','codeCommit','docsCommit','specCommit','sourceDigest','evidencePaths')) -and
                $review.schemaVersion -eq 1 -and $review.outcome -ceq 'still-correct' -and @($review.evidencePaths).Count -gt 0 -and
                $review.codeCommit -ceq $binding.code.targetCommit -and $review.docsCommit -ceq $binding.docs.commit -and
                $review.specCommit -ceq $binding.spec.commit -and $review.sourceDigest -ceq $sourceDigest) { $reviewValid = $true }
            else { $reasons.Add('ReviewRevisionMismatch') }
        }
        if (-not $reviewValid) { $reasons.Add('DocumentationStale') }
    }
    $unique = @($reasons | Select-Object -Unique)
    return New-BindingResult -Status $(if($unique.Count -eq 0){'valid'}else{'blocked'}) -ReasonCodes $unique -DocsCommit $binding.docs.commit -SpecCommit $binding.spec.commit -CodeCommit $binding.code.targetCommit -SourceDigest $sourceDigest -ChangedRelevantPaths $changed -CodeRepository $codeRepo -CodeRelevantPaths @($binding.code.relevantPaths) -SpecRepository $specRepo -SpecSourcePaths @($binding.spec.sourcePaths)
}

Export-ModuleMember -Function Resolve-ConfluenceCodeBinding
