# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

[CmdletBinding()]
param(
    [string] $RepositoryRoot
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
}
else {
    [IO.Path]::GetFullPath($RepositoryRoot)
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool] $Condition,
        [Parameter(Mandatory = $true)][string] $Message
    )
    if (-not $Condition) { throw $Message }
}

function Assert-ExactPropertySet {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string[]] $Expected,
        [Parameter(Mandatory = $true)][string] $Context
    )
    $actual = @($Value.PSObject.Properties | ForEach-Object { [string]$_.Name })
    Assert-True ($actual.Count -eq $Expected.Count -and
        @($Expected | Where-Object { $actual -cnotcontains $_ }).Count -eq 0 -and
        @($actual | Where-Object { $Expected -cnotcontains $_ }).Count -eq 0) "$Context has an invalid property set."
}

function Assert-StrictUtf8PowerShellFile {
    param([Parameter(Mandatory = $true)][string] $Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    $offset = if ($bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and
        $bytes[1] -eq 0xBB -and
        $bytes[2] -eq 0xBF) {
        3
    }
    else {
        0
    }
    $source = [Text.UTF8Encoding]::new($false, $true).GetString(
        $bytes,
        $offset,
        $bytes.Length - $offset
    )
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseInput(
        $source,
        $Path,
        [ref]$tokens,
        [ref]$errors
    ) | Out-Null
    if (@($errors).Count -ne 0) {
        throw "PowerShell parse failed for '$Path': $(@($errors | ForEach-Object { $_.Message }) -join '; ')"
    }
}

Assert-True ($PSVersionTable.PSVersion.Major -eq 5) 'This contract must execute under Windows PowerShell 5.1.'

$files = @()
foreach ($relativeRoot in @('scripts', 'skills')) {
    $rootPath = Join-Path $repositoryRoot $relativeRoot.Replace('/', [IO.Path]::DirectorySeparatorChar)
    if (Test-Path -LiteralPath $rootPath -PathType Container) {
        $files += @(Get-ChildItem -LiteralPath $rootPath -Recurse -File |
            Where-Object { $_.Extension -in @('.ps1', '.psm1') })
    }
}
$files += @(Get-Item -LiteralPath $PSCommandPath)
Assert-True (@($files).Count -gt 0) 'No PowerShell compatibility files were found.'
foreach ($file in $files) {
    Assert-StrictUtf8PowerShellFile -Path $file.FullName
}

$standardSourcePath = Join-Path $repositoryRoot 'catalog/source.json'
$standardAdapterPath = Join-Path $repositoryRoot 'config/standard-v1.json'
Assert-True (Test-Path -LiteralPath $standardSourcePath -PathType Leaf) 'The Atlassian source catalog is required.'
Assert-True (Test-Path -LiteralPath $standardAdapterPath -PathType Leaf) 'The Standard v1 adapter is required.'
$source = Get-Content -LiteralPath $standardSourcePath -Raw | ConvertFrom-Json
Assert-ExactPropertySet -Value $source -Expected @('schemaVersion', 'sourceId', 'repository', 'skillsRoot', 'skills') -Context 'catalog/source.json'
Assert-True ($source.schemaVersion -eq 2) 'catalog/source.json must remain schema v2.'
Assert-True ($source.sourceId -ceq 'atlassian-ecosystem') 'The Atlassian source identity is invalid.'
Assert-True ($source.repository -ceq 'https://github.com/SyuanTsai/Skill-Atlassian-Ecosystem.git') 'The Atlassian repository identity is invalid.'
Assert-True ($source.skillsRoot -ceq 'skills') 'The source root must be skills/.'
$expectedSkills = @('configure-bitbucket-api-access', 'configure-confluence-api-access', 'configure-jira-api-access', 'publish-requirements-to-confluence', 'review-bitbucket-pull-request', 'work-with-jira')
Assert-True ((@($source.skills) -join "`n") -ceq ($expectedSkills -join "`n")) 'The six-Skill Atlassian inventory is invalid.'
foreach ($skillId in $expectedSkills) {
    Assert-True (Test-Path -LiteralPath (Join-Path $repositoryRoot "skills/$skillId/SKILL.md") -PathType Leaf) "The catalogued Skill is missing: $skillId"
}
Write-Host 'Windows PowerShell 5.1 Atlassian Standard v1 repository contract passed.'

$workflow = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github/workflows/validate.yml') -Raw
Assert-True ($workflow -match 'shell: powershell') 'The required Windows PowerShell 5.1 contract is missing.'
Assert-True ($workflow -match "Join-Path\s+\`$PSHOME\s+'powershell\.exe'") 'The Windows PowerShell wrapper must resolve the child executable from the active Windows PowerShell installation.'
Assert-True ($workflow -match '&\s+\$windowsPowerShellPath\s+@protectedContractArguments') 'The Windows PowerShell wrapper must execute the trusted contract in an isolated child process.'
Assert-True ($workflow -match '\$protectedContractExitCode\s*=\s*\$LASTEXITCODE') 'The Windows PowerShell wrapper must capture the trusted script native exit state.'
Assert-True ($workflow -match 'if\s*\(\$protectedContractExitCode\s+-ne\s+0\)') 'The Windows PowerShell wrapper must reject a non-zero child process exit code.'
Assert-True ($workflow -match '\[IO\.File\]::ReadAllBytes\(\$candidatePath\)') 'The candidate parser must read raw PowerShell source bytes before decoding.'
Assert-True ($workflow -notmatch '\$candidateSource\s*=\s*\[IO\.File\]::ReadAllText\(') 'The candidate parser must not permit ReadAllText BOM auto-detection to select another encoding.'
Assert-True ($workflow -match '(?s)\$candidateBytes\[0\] -eq 0xEF.*?\$candidateBytes\[1\] -eq 0xBB.*?\$candidateBytes\[2\] -eq 0xBF') 'The candidate parser must recognize only the optional UTF-8 BOM.'
Assert-True ($workflow -match '(?s)\[Text\.UTF8Encoding\]::new\(\$false,\s*\$true\)\.GetString\(.*?\$candidateBytes.*?\$candidateOffset.*?\$candidateBytes\.Length - \$candidateOffset') 'The candidate parser must reject non-UTF-8 source bytes without encoding auto-detection.'
Assert-True ($workflow -match '\[Management\.Automation\.Language\.Parser\]::ParseInput\(') 'The candidate parser must parse the explicitly decoded UTF-8 source.'
Assert-True ($workflow -match "go-version: 'stable'") 'The workflow must use the latest stable Go channel.'
Assert-True ($workflow -match 'check-latest: true') 'The workflow must resolve the latest stable Go runtime per run.'
Assert-True ($workflow -notmatch "go-version: '[0-9]+\.[0-9]+\.[0-9]+'") 'The workflow must not pin a Go patch version.'

# Scenario: The protected wrapper runs a child PowerShell script that may succeed after handling a native failure, throw, or exit non-zero.
# Purpose: Bind the wrapper result to the child process outcome instead of stale in-process LASTEXITCODE state.
$wrapperProbeRoot = Join-Path ([IO.Path]::GetTempPath()) ('atlassian-windows-wrapper-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $wrapperProbeRoot -Force | Out-Null
try {
    $successScript = Join-Path $wrapperProbeRoot 'success.ps1'
    $handledNativeFailureScript = Join-Path $wrapperProbeRoot 'handled-native-failure.ps1'
    $exceptionScript = Join-Path $wrapperProbeRoot 'exception.ps1'
    $explicitExitScript = Join-Path $wrapperProbeRoot 'explicit-exit.ps1'
    Set-Content -LiteralPath $successScript -Value "Write-Output 'success'" -Encoding UTF8
    Set-Content -LiteralPath $handledNativeFailureScript -Value @'
& cmd.exe /c exit 7
if ($LASTEXITCODE -ne 7) { throw 'native probe did not return the expected code' }
Write-Output 'handled success'
'@ -Encoding UTF8
    Set-Content -LiteralPath $exceptionScript -Value "throw 'expected protected wrapper exception'" -Encoding UTF8
    Set-Content -LiteralPath $explicitExitScript -Value 'exit 7' -Encoding UTF8

    function Invoke-ProtectedWrapperProbe {
        param([Parameter(Mandatory = $true)][string] $ScriptPath)
        $windowsPowerShellPath = [IO.Path]::GetFullPath((Join-Path $PSHOME 'powershell.exe'))
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & $windowsPowerShellPath -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ScriptPath 2>&1 | Out-Null
            $childExitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        return $childExitCode
    }

    $successExitCode = Invoke-ProtectedWrapperProbe -ScriptPath $successScript
    Assert-True ($successExitCode -eq 0) 'A successful child PowerShell script must return exit code zero.'

    $handledNativeFailureExitCode = Invoke-ProtectedWrapperProbe -ScriptPath $handledNativeFailureScript
    Assert-True ($handledNativeFailureExitCode -eq 0) 'A child script that handles a native non-zero state and completes normally must return exit code zero.'

    $exceptionExitCode = Invoke-ProtectedWrapperProbe -ScriptPath $exceptionScript
    Assert-True ($exceptionExitCode -ne 0) 'An unhandled child PowerShell exception must return a non-zero exit code.'

    $explicitExitCode = Invoke-ProtectedWrapperProbe -ScriptPath $explicitExitScript
    Assert-True ($explicitExitCode -eq 7) 'An explicit child PowerShell exit code must be preserved for the wrapper.'
}
finally {
    if (Test-Path -LiteralPath $wrapperProbeRoot) {
        $resolvedProbeRoot = [IO.Path]::GetFullPath($wrapperProbeRoot)
        $expectedProbeParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
        if (-not [string]::Equals([IO.Path]::GetDirectoryName($resolvedProbeRoot), $expectedProbeParent, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($resolvedProbeRoot) -notmatch '^atlassian-windows-wrapper-[0-9a-f]{32}$') {
            throw 'The wrapper probe cleanup path is outside the task-owned temporary directory.'
        }
        Remove-Item -LiteralPath $resolvedProbeRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host 'Windows PowerShell 5.1 repository compatibility contract passed.'
