# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool] $Condition,
        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    if (-not $Condition) { throw $Message }
}

function Invoke-StandaloneValidation {
    param(
        [ValidateSet('Preserve', 'LF', 'CRLF')]
        [string] $LineEnding = 'Preserve',
        [ValidateSet('None', 'Version', 'License', 'CatalogLicense', 'NoticeMissing')]
        [string] $InvalidMetadata = 'None'
    )

    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $exportRoot = Join-Path $tempRoot "skill-atlassian-export-$([Guid]::NewGuid().ToString('N'))"

    try {
        New-Item -ItemType Directory -Path $exportRoot | Out-Null
        Get-ChildItem -Force -LiteralPath $repositoryRoot |
            Where-Object Name -cne '.git' |
            ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination $exportRoot -Recurse -Force
            }

        Assert-True (-not (Test-Path -LiteralPath (Join-Path $exportRoot '.git'))) 'Standalone fixture unexpectedly contains Git metadata.'

        if ($LineEnding -cne 'Preserve') {
            $newline = if ($LineEnding -ceq 'CRLF') { "`r`n" } else { "`n" }
            $utf8 = New-Object System.Text.UTF8Encoding($false)
            Get-ChildItem -LiteralPath $exportRoot -Recurse -File | Where-Object {
                $_.Extension -in @('.md', '.ps1', '.yml', '.yaml', '.json', '.toml', '.txt') -or $_.Name -in @('LICENSE', 'NOTICE')
            } | ForEach-Object {
                $content = [IO.File]::ReadAllText($_.FullName) -replace "`r`n", "`n"
                [IO.File]::WriteAllText($_.FullName, $content.Replace("`n", $newline), $utf8)
            }
        }

        if ($InvalidMetadata -cne 'None') {
            $metadataPath = Join-Path $exportRoot 'REUSE.toml'
            $metadata = [IO.File]::ReadAllText($metadataPath)
            $metadata = switch ($InvalidMetadata) {
                'Version' { $metadata.Replace('version = 1', 'version = 2') }
                'License' { $metadata.Replace('SPDX-License-Identifier = "Apache-2.0"', 'SPDX-License-Identifier = "MIT"') }
                'CatalogLicense' {
                    $licensePattern = [regex] 'SPDX-License-Identifier = "Apache-2\.0"'
                    $licensePattern.Replace($metadata, 'SPDX-License-Identifier = "MIT"', 1)
                }
                'NoticeMissing' { $metadata.Replace('path = "NOTICE"', 'path = "unrelated.txt"') }
            }
            [IO.File]::WriteAllText($metadataPath, $metadata, (New-Object System.Text.UTF8Encoding($false)))
        }

        $exportedValidator = Join-Path $exportRoot 'tests/validate-repository.ps1'
        $failure = $null
        try { & $exportedValidator | Out-Null }
        catch { $failure = $_.Exception.Message }

        if ($InvalidMetadata -ceq 'None') {
            Assert-True ($null -eq $failure) "Standalone $LineEnding validation failed: $failure"
            Assert-True ($LASTEXITCODE -eq 0) 'Standalone repository validation leaked a non-zero native exit code.'
        } else {
            $expectedFailure = switch ($InvalidMetadata) {
                'Version' { 'REUSE.toml must use schema version 1.' }
                'License' { 'REUSE.toml must declare Apache-2.0 for uncommentable files.' }
                'CatalogLicense' { 'REUSE.toml must declare Apache-2.0 for catalog/source.json.' }
                'NoticeMissing' { 'REUSE.toml must contain exactly one annotation for NOTICE.' }
            }
            Assert-True ($failure -ceq $expectedFailure) "Invalid $InvalidMetadata metadata was not rejected for the expected reason: $failure"
        }
    }
    finally {
        if (Test-Path -LiteralPath $exportRoot) {
            $resolvedExport = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $exportRoot).Path)
            Assert-True ([IO.Path]::GetDirectoryName($resolvedExport).TrimEnd('\', '/') -ceq $tempRoot.TrimEnd('\', '/')) 'Refusing cleanup outside the temporary directory.'
            Assert-True ([IO.Path]::GetFileName($resolvedExport) -cmatch '^skill-atlassian-export-[a-f0-9]{32}$') 'Refusing cleanup of an unexpected fixture directory.'
            Remove-Item -LiteralPath $resolvedExport -Recurse -Force
        }
    }
}

# Scenario: Release automation validates an exported copy without Git metadata.
# Purpose: Repository validation remains usable outside a live working tree.
function UnitT10_Repository_contract_runs_without_git_metadata {
    Invoke-StandaloneValidation
}

# Scenario: An exported tree uses Unix LF line endings for every supported text file.
# Purpose: Licensing checks accept the canonical Git representation.
function UnitT20_Repository_contract_accepts_LF {
    Invoke-StandaloneValidation -LineEnding LF
}

# Scenario: Windows checkout converts all supported text files to CRLF.
# Purpose: Strict licensing checks must not reject valid metadata because of carriage returns.
function UnitT30_Repository_contract_accepts_CRLF {
    Invoke-StandaloneValidation -LineEnding CRLF
}

# Scenario: Either line-ending format contains an unsupported REUSE schema version.
# Purpose: Line-ending tolerance must not bypass version validation.
function UnitT40_Repository_contract_rejects_invalid_REUSE_version {
    foreach ($ending in @('LF', 'CRLF')) { Invoke-StandaloneValidation -LineEnding $ending -InvalidMetadata Version }
}

# Scenario: Either line-ending format declares a different license for uncommentable files.
# Purpose: Line-ending tolerance must not silently accept an incorrect license declaration.
function UnitT50_Repository_contract_rejects_invalid_REUSE_license {
    foreach ($ending in @('LF', 'CRLF')) { Invoke-StandaloneValidation -LineEnding $ending -InvalidMetadata License }
}

# Scenario: NOTICE keeps Apache-2.0 while the catalog annotation declares a different license.
# Purpose: A valid annotation elsewhere must not hide a wrong per-file license.
function UnitT60_Repository_contract_rejects_mismatched_catalog_license {
    foreach ($ending in @('LF', 'CRLF')) { Invoke-StandaloneValidation -LineEnding $ending -InvalidMetadata CatalogLicense }
}

# Scenario: The catalog remains annotated but NOTICE loses its own annotation.
# Purpose: Every uncommentable distributed file must retain licensing coverage.
function UnitT70_Repository_contract_rejects_missing_NOTICE_annotation {
    foreach ($ending in @('LF', 'CRLF')) { Invoke-StandaloneValidation -LineEnding $ending -InvalidMetadata NoticeMissing }
}

UnitT10_Repository_contract_runs_without_git_metadata
UnitT20_Repository_contract_accepts_LF
UnitT30_Repository_contract_accepts_CRLF
UnitT40_Repository_contract_rejects_invalid_REUSE_version
UnitT50_Repository_contract_rejects_invalid_REUSE_license
UnitT60_Repository_contract_rejects_mismatched_catalog_license
UnitT70_Repository_contract_rejects_missing_NOTICE_annotation
Write-Host 'Standalone repository validation test passed.'
