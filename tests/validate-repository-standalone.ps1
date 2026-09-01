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

# Scenario: Release automation runs the repository contract from an exported copy without Git metadata.
# Purpose: Standalone validation must inspect the exported Skills instead of requiring a live working tree.
function UnitT10_Repository_contract_runs_without_git_metadata {
    $exportRoot = Join-Path ([IO.Path]::GetTempPath()) "skill-atlassian-export-$([Guid]::NewGuid().ToString('N'))"

    try {
        New-Item -ItemType Directory -Path $exportRoot | Out-Null
        Get-ChildItem -Force -LiteralPath $repositoryRoot |
            Where-Object Name -cne '.git' |
            ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination $exportRoot -Recurse -Force
            }

        Assert-True (-not (Test-Path -LiteralPath (Join-Path $exportRoot '.git'))) 'Standalone fixture unexpectedly contains Git metadata.'

        $exportedValidator = Join-Path $exportRoot 'tests/validate-repository.ps1'
        & $exportedValidator | Out-Null
        Assert-True ($LASTEXITCODE -eq 0) 'Standalone repository validation leaked a non-zero native exit code.'
    }
    finally {
        if (Test-Path -LiteralPath $exportRoot) {
            Remove-Item -LiteralPath $exportRoot -Recurse -Force
        }
    }
}

UnitT10_Repository_contract_runs_without_git_metadata
Write-Host 'Standalone repository validation test passed.'
