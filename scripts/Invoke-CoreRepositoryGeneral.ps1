# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{64}$')]
    [string] $SourceBindingSha256
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$preparationModulePath = Join-Path $PSScriptRoot 'StandardCoreSourcePreparation.psm1'
Import-Module -Name $preparationModulePath -Force -ErrorAction Stop

$runId = [Environment]::GetEnvironmentVariable('STANDARD_VALIDATION_CORE_RUN_ID', 'Process')
$checkId = [Environment]::GetEnvironmentVariable('STANDARD_VALIDATION_CORE_CHECK_ID', 'Process')
$skillListText = [Environment]::GetEnvironmentVariable('STANDARD_VALIDATION_CORE_SKILLS', 'Process')
if ($runId -cnotmatch '^[0-9a-f]{32}$' -or $checkId -cne 'repository-general') {
    throw 'Core repository general check requires the trusted run identity and check id.'
}
if ([string]::IsNullOrWhiteSpace($skillListText)) { throw 'Core repository general check has no trusted active Skill inventory.' }
$expectedSkillIds = [string[]]@($skillListText.Split(';'))
$skillIdSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($skillId in $expectedSkillIds) {
    if ($skillId -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' -or -not $skillIdSet.Add($skillId)) {
        throw 'Core repository general check received a malformed or duplicate trusted Skill id.'
    }
}

$candidateRoot = [IO.Path]::GetFullPath((Get-Location).Path)
$verifiedPowerShellExecutable = [IO.Path]::GetFullPath([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
Assert-StandardCoreV2NoReparseAncestors -Path $verifiedPowerShellExecutable -Context 'Core PowerShell executable'
$releasePath = [Environment]::GetEnvironmentVariable('STANDARD_VALIDATION_BOOTSTRAP_RELEASE_PATH', 'Process')
$bootstrapCommand = [Environment]::GetEnvironmentVariable('STANDARD_VALIDATION_BOOTSTRAP_COMMAND', 'Process')
if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -or
    -not [string]::IsNullOrWhiteSpace($releasePath) -or -not [string]::IsNullOrWhiteSpace($bootstrapCommand)) {
    if ([string]::IsNullOrWhiteSpace($releasePath) -or [string]::IsNullOrWhiteSpace($bootstrapCommand)) {
        throw 'Core bootstrap signal metadata is incomplete.'
    }
    Remove-StandardCoreConsumedBootstrapSignal -CandidateRoot $candidateRoot -ReleasePath $releasePath `
        -BootstrapCommand $bootstrapCommand -VerifiedPowerShellExecutable $verifiedPowerShellExecutable
}

$runRoot = Split-Path -Parent $candidateRoot
$runsRoot = Split-Path -Parent $runRoot
$artifactsRoot = Split-Path -Parent $runsRoot
$adapterRoot = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $artifactsRoot) ".core-v2-adapter-$runId"))
$metadataRoot = [IO.Path]::GetFullPath((Join-Path $adapterRoot 'candidate-git'))
$gitPath = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path
Assert-StandardCoreV2NoReparseAncestors -Path $gitPath -Context 'Core Git executable'
$binding = Assert-StandardCoreV2SourceBinding -SnapshotRoot $candidateRoot -ExpectedSha256 $SourceBindingSha256 `
    -RunId $runId -MetadataRoot $metadataRoot -GitPath $gitPath

$profilePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'config/standard-core-v2-preparation.json'
$profile = Read-StandardCoreV2PreparationProfile -ConfigPath $profilePath
if ($profile.status -cne 'dormant') { throw 'Core repository general check selected a non-dormant preparation profile.' }

$validatorPath = Join-Path $PSScriptRoot 'Test-Repository.ps1'
Assert-StandardCoreV2NoReparseAncestors -Path $validatorPath -Context 'Core repository validator'
$validatorOutput = @(& $validatorPath -RepositoryRoot $candidateRoot -ReadOnlySnapshot `
    -GitMetadataRoot $binding.GitMetadataRoot -ExpectedRevision $binding.SourceRevision -TrustedGitPath $gitPath 6>$null)
if ($validatorOutput.Count -eq 0) { throw 'Core repository validator returned no report.' }
$reportText = [string]$validatorOutput[-1]
$report = $reportText | ConvertFrom-Json -Depth 30 -ErrorAction Stop
if ([int]$report.schemaVersion -ne 1 -or [string]$report.sourceId -cne 'atlassian-ecosystem' -or
    [string]$report.skillsRoot -cne 'skills' -or [string]$report.result -cne 'passed') {
    throw 'Core repository validator returned an invalid success report.'
}
$reportedSkillIds = [string[]]@($report.skills | ForEach-Object { [string]$_.skillId })
[Array]::Sort($expectedSkillIds, [StringComparer]::Ordinal)
[Array]::Sort($reportedSkillIds, [StringComparer]::Ordinal)
if ([int]$report.activeSkillCount -ne $expectedSkillIds.Count -or $reportedSkillIds.Count -ne $expectedSkillIds.Count -or
    -not [Linq.Enumerable]::SequenceEqual[string]($reportedSkillIds, $expectedSkillIds, [StringComparer]::Ordinal)) {
    throw 'Core repository validator did not cover the exact trusted active Skill inventory.'
}
ConvertTo-Json -InputObject $report -Depth 30 -Compress
