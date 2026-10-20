# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Source conformance Static bridge' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $source = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Invoke-SourceConformance.ps1') -Raw
        $start = $source.IndexOf(('$childRunnerText = @' + [char]39), [StringComparison]::Ordinal)
        if ($start -lt 0) { throw 'The source validation child was not found.' }
        $start = $source.IndexOf("`n", $start) + 1
        $end = $source.IndexOf(("`n" + [char]39 + '@'), $start, [StringComparison]::Ordinal)
        if ($end -lt $start) { throw 'The source validation child terminator was not found.' }
        $script:ChildSource = $source.Substring($start, $end - $start).TrimEnd("`r")
        $script:PowerShellPath = (Get-Process -Id $PID).Path

        function New-StaticBridgeFixture {
            param(
                [Parameter(Mandatory = $true)][string] $Root,
                [switch] $UseNullPrefixArguments
            )
            $candidate = Join-Path $Root 'candidate'
            $skill = Join-Path $candidate 'skills/manage-confluence-docs-as-code'
            $otherSkill = Join-Path $candidate 'skills/review-bitbucket-pull-request'
            $candidateScripts = Join-Path $candidate 'scripts'
            $output = Join-Path $Root 'output'
            [void](New-Item -ItemType Directory -Path $skill, $otherSkill, $candidateScripts, $output -Force)
            Set-Content -LiteralPath (Join-Path $skill 'SKILL.md') -Value '# Test skill' -Encoding utf8NoBOM
            Set-Content -LiteralPath (Join-Path $otherSkill 'SKILL.md') -Value '# Other test skill' -Encoding utf8NoBOM
            [IO.File]::Copy(
                (Join-Path $script:RepositoryRoot 'scripts/Invoke-ParallelSkillSpector.ps1'),
                (Join-Path $candidateScripts 'Invoke-ParallelSkillSpector.ps1'),
                $false)

            $child = Join-Path $Root 'child.ps1'
            $scanner = Join-Path $Root 'scanner.ps1'
            $wrapper = Join-Path $Root 'wrapper.ps1'
            $receipt = Join-Path $Root 'receipt-skillspector.json'
            $toolchain = Join-Path $Root 'toolchain.json'
            [IO.File]::WriteAllText($child, $script:ChildSource, [Text.UTF8Encoding]::new($false))
            Set-Content -LiteralPath $receipt -Value '{}' -Encoding utf8NoBOM
            Set-Content -LiteralPath $scanner -Encoding utf8NoBOM -Value @'
$skillRoot = [string]$args[1]
$skillId = Split-Path -Leaf $skillRoot
$reportPath = [string]$args[-1]
$reason = [string]$env:SOURCE_STATIC_TEST_REASON
$limitation = [string]$env:SOURCE_STATIC_TEST_LIMITATION
$isComplete = $skillId -cne 'manage-confluence-docs-as-code' -or [string]$env:SOURCE_STATIC_TEST_COMPLETE -ceq 'true'
$ledgerExceptions = [object[]]@()
$limitations = [string[]]@()
if (-not $isComplete) {
    $ledgerExceptions = [object[]]@([ordered]@{
        path = 'SKILL.md'; phase = 'static'; outcome = 'partial'; reason_code = $reason
        fatal = $false; analyzers = @('static_patterns_tool_misuse')
    })
    $limitations = [string[]]@($limitation)
}
$scannerStartedPath = "$($env:SOURCE_STATIC_TEST_SCANNER_MARKER).started"
$scannerFinishedPath = "$($env:SOURCE_STATIC_TEST_SCANNER_MARKER).finished"
[IO.File]::WriteAllText($scannerStartedPath, [DateTime]::UtcNow.Ticks.ToString(), [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText("$($env:SOURCE_STATIC_TEST_SCANNER_MARKER).$skillId.started", 'started', [Text.UTF8Encoding]::new($false))
if ([int]$env:SOURCE_STATIC_TEST_SCANNER_DELAY_MS -gt 0) { Start-Sleep -Milliseconds ([int]$env:SOURCE_STATIC_TEST_SCANNER_DELAY_MS) }
$report = [ordered]@{
    execution_successful = $true
    skill = [ordered]@{ name = $skillId; source = $skillRoot }
    analysis_completeness = [ordered]@{
        execution_successful = $true
        is_complete = $isComplete
        status = $(if ($isComplete) { 'complete' } else { 'partial' })
        coverage_percent = $(if ($isComplete) { 100 } else { 50 })
        ledger_exceptions = $ledgerExceptions
        scope_exclusions = @()
        limitations = $limitations
    }
    components = @([ordered]@{ path = 'SKILL.md' })
    issues = @($(if ($skillId -ceq 'manage-confluence-docs-as-code') {
                [ordered]@{ id = 'E1'; severity = 'medium'; message = 'Retained finding' }
            }))
}
[IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($scannerFinishedPath, [DateTime]::UtcNow.Ticks.ToString(), [Text.UTF8Encoding]::new($false))
'@
            if ($UseNullPrefixArguments) {
                Set-Content -LiteralPath (Join-Path $candidateScripts 'Invoke-ParallelSkillSpector.ps1') -Encoding utf8NoBOM -Value @'
param($ExecutablePath, $ExecutablePrefixArgumentsJson, $SkillsRoot, $SkillIdsJson, $OutputRoot, $SummaryPath)
if ($ExecutablePrefixArgumentsJson -cne '[]') {
    throw "Expected a normalized empty prefix argument array, received: $ExecutablePrefixArgumentsJson"
}
$skillIds = @($SkillIdsJson | ConvertFrom-Json)
foreach ($skillId in $skillIds) {
    $skillRoot = Join-Path $SkillsRoot $skillId
    $reportPath = Join-Path $OutputRoot "skillspector-$skillId.json"
    $isComplete = $skillId -cne 'manage-confluence-docs-as-code'
    $report = [ordered]@{
        execution_successful = $true
        skill = [ordered]@{ name = $skillId; source = $skillRoot }
        analysis_completeness = [ordered]@{
            execution_successful = $true; is_complete = $isComplete
            status = $(if ($isComplete) { 'complete' } else { 'partial' })
            coverage_percent = $(if ($isComplete) { 100 } else { 50 })
            ledger_exceptions = @($(if (-not $isComplete) { [ordered]@{
                            path = 'SKILL.md'; phase = 'static'; outcome = 'partial'; reason_code = $env:SOURCE_STATIC_TEST_REASON
                            fatal = $false; analyzers = @('static_patterns_tool_misuse')
                        } }))
            scope_exclusions = @(); limitations = @($(if (-not $isComplete) { $env:SOURCE_STATIC_TEST_LIMITATION }))
        }
        components = @([ordered]@{ path = 'SKILL.md' })
        issues = @()
    }
    [IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
}
$summary = [ordered]@{
    marker = 'atlassian-parallel-skillspector-v1'; skillIds = $skillIds
    processCount = $skillIds.Count; maxObservedConcurrency = 0
    reports = @($skillIds | ForEach-Object { [ordered]@{ skillId = $_; path = (Join-Path $OutputRoot "skillspector-$_.json") } })
}
[IO.File]::WriteAllText($SummaryPath, ($summary | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
'@
            }
            Set-Content -LiteralPath $wrapper -Encoding utf8NoBOM -Value @'
param($ToolReceiptPath, $ExpectedToolReceiptSha256, $ExpectedResolutionRunId, $SkillRoot,
    $SourceRevision, $CandidateIdentity, $ReportPath, $EvidencePath)
[IO.File]::WriteAllText($env:SOURCE_STATIC_TEST_WRAPPER_MARKER, 'called', [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText("$($env:SOURCE_STATIC_TEST_WRAPPER_MARKER).started", [DateTime]::UtcNow.Ticks.ToString(), [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText("$($env:SOURCE_STATIC_TEST_WRAPPER_MARKER).pid", $PID.ToString(), [Text.UTF8Encoding]::new($false))
$originalComplete = [string]$env:SOURCE_STATIC_TEST_COMPLETE -ceq 'true'
$originalExceptions = [object[]]@()
$originalLimitations = [string[]]@()
if (-not $originalComplete) {
    $originalExceptions = [object[]]@([ordered]@{
        path = 'SKILL.md'; phase = 'static'; outcome = 'partial'; reason_code = [string]$env:SOURCE_STATIC_TEST_REASON
        fatal = $false; analyzers = @('static_patterns_tool_misuse')
    })
    $originalLimitations = [string[]]@([string]$env:SOURCE_STATIC_TEST_LIMITATION)
}
$originalReport = [ordered]@{
    execution_successful = $true
    skill = [ordered]@{
        name = $(if ([string]$env:SOURCE_STATIC_TEST_ORIGINAL_IDENTITY_DRIFT -ceq 'true') { 'wrong-skill' } else { Split-Path -Leaf $SkillRoot })
        source = $SkillRoot
    }
    analysis_completeness = [ordered]@{
        execution_successful = $true
        is_complete = $originalComplete
        status = $(if ($originalComplete) { 'complete' } else { 'partial' })
        coverage_percent = $(if ($originalComplete) { 100 } else { 50 })
        ledger_exceptions = $originalExceptions; scope_exclusions = @(); limitations = $originalLimitations
    }
    components = @([ordered]@{ path = 'SKILL.md' })
    issues = @([ordered]@{ id = 'E1'; severity = 'medium'; message = 'Retained finding' })
}
[IO.File]::WriteAllText("$ReportPath.original.json", ($originalReport | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
if ([int]$env:SOURCE_STATIC_TEST_WRAPPER_DELAY_MS -gt 0) { Start-Sleep -Milliseconds ([int]$env:SOURCE_STATIC_TEST_WRAPPER_DELAY_MS) }
if ([string]$env:SOURCE_STATIC_TEST_WRAPPER_FAILS -ceq 'true') {
    [Console]::Error.WriteLine('fixture wrapper failure')
    exit 23
}
$report = [ordered]@{
    execution_successful = $true
    skill = [ordered]@{ name = (Split-Path -Leaf $SkillRoot); source = $SkillRoot }
    analysis_completeness = [ordered]@{
        execution_successful = $true; is_complete = $true; status = 'complete'; coverage_percent = 100
        ledger_exceptions = @(); scope_exclusions = @(); limitations = @()
    }
    components = @([ordered]@{ path = 'SKILL.md' })
    issues = @([ordered]@{ id = 'E1'; severity = 'medium'; message = 'Retained finding' })
}
[IO.File]::WriteAllText($ReportPath, ($report | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
foreach ($sidecar in @($EvidencePath, "$EvidencePath.profile.json")) {
    [IO.File]::WriteAllText($sidecar, '{}', [Text.UTF8Encoding]::new($false))
}
[IO.File]::WriteAllText("$($env:SOURCE_STATIC_TEST_WRAPPER_MARKER).finished", [DateTime]::UtcNow.Ticks.ToString(), [Text.UTF8Encoding]::new($false))
[pscustomobject]@{
    status = 'completed'; reportPath = $ReportPath; evidencePath = $EvidencePath
    applicabilityStatus = 'not-verified'; executionProvenanceStatus = 'not-verified'
    authorizationGranted = $false; authorizedOperations = @(); releaseEligible = $false
} | ConvertTo-Json -Compress
'@
            $toolchainValue = [ordered]@{
                skillSpectorPath = $script:PowerShellPath
                skillSpectorSha256 = (Get-FileHash -LiteralPath $script:PowerShellPath -Algorithm SHA256).Hash.ToLowerInvariant()
                skillSpectorPrefixArguments = $(if ($UseNullPrefixArguments) { $null } else { @('-NoProfile', '-NonInteractive', '-File', $scanner) })
            }
            [IO.File]::WriteAllText($toolchain, ($toolchainValue | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
            [pscustomobject]@{
                candidate = $candidate; skill = $skill; output = $output; child = $child
                wrapper = $wrapper; receipt = $receipt; toolchain = $toolchain
                marker = (Join-Path $Root 'wrapper-called.txt')
                scannerMarker = (Join-Path $Root 'scanner-called.txt')
            }
        }

        function Invoke-StaticBridgeFixture {
            param([Parameter(Mandatory = $true)] $Fixture, [Parameter(Mandatory = $true)][string] $Reason,
                [string] $Limitation = 'Analyzer static_patterns_tool_misuse status: degraded.',
                [int] $ScannerDelayMilliseconds = 0,
                [int] $WrapperDelayMilliseconds = 0,
                [switch] $Complete,
                [switch] $WrapperFails,
                [switch] $OriginalIdentityDrift)
            $previous = @{}
            foreach ($name in @('STANDARD_VALIDATION_CANDIDATE_ROOT', 'STANDARD_VALIDATION_CANDIDATE_ID',
                    'STANDARD_VALIDATION_ACTIVE_SKILLS', 'STANDARD_VALIDATION_SKILLS_ROOT',
                    'SOURCE_STATIC_TEST_REASON', 'SOURCE_STATIC_TEST_LIMITATION', 'SOURCE_STATIC_TEST_WRAPPER_MARKER',
                    'SOURCE_STATIC_TEST_SCANNER_MARKER', 'SOURCE_STATIC_TEST_SCANNER_DELAY_MS',
                    'SOURCE_STATIC_TEST_WRAPPER_DELAY_MS', 'SOURCE_STATIC_TEST_COMPLETE',
                    'SOURCE_STATIC_TEST_WRAPPER_FAILS', 'SOURCE_STATIC_TEST_ORIGINAL_IDENTITY_DRIFT')) {
                $previous[$name] = [Environment]::GetEnvironmentVariable($name)
            }
            try {
                $env:STANDARD_VALIDATION_CANDIDATE_ROOT = $Fixture.candidate
                $env:STANDARD_VALIDATION_CANDIDATE_ID = 'b' * 64
                $env:STANDARD_VALIDATION_ACTIVE_SKILLS = 'manage-confluence-docs-as-code;review-bitbucket-pull-request'
                $env:STANDARD_VALIDATION_SKILLS_ROOT = Join-Path $Fixture.candidate 'skills'
                $env:SOURCE_STATIC_TEST_REASON = $Reason
                $env:SOURCE_STATIC_TEST_LIMITATION = $Limitation
                $env:SOURCE_STATIC_TEST_WRAPPER_MARKER = $Fixture.marker
                $env:SOURCE_STATIC_TEST_SCANNER_MARKER = $Fixture.scannerMarker
                $env:SOURCE_STATIC_TEST_SCANNER_DELAY_MS = $ScannerDelayMilliseconds.ToString()
                $env:SOURCE_STATIC_TEST_WRAPPER_DELAY_MS = $WrapperDelayMilliseconds.ToString()
                $env:SOURCE_STATIC_TEST_COMPLETE = $Complete.ToString().ToLowerInvariant()
                $env:SOURCE_STATIC_TEST_WRAPPER_FAILS = $WrapperFails.ToString().ToLowerInvariant()
                $env:SOURCE_STATIC_TEST_ORIGINAL_IDENTITY_DRIFT = $OriginalIdentityDrift.ToString().ToLowerInvariant()
                Push-Location $Fixture.output
                try {
                    $lines = @(& $script:PowerShellPath -NoProfile -NonInteractive -File $Fixture.child `
                        -Mode static `
                        -ToolchainPath $Fixture.toolchain `
                        -ToolchainSha256 ((Get-FileHash -LiteralPath $Fixture.toolchain -Algorithm SHA256).Hash.ToLowerInvariant()) `
                        -SourceRevision ('a' * 40) `
                        -StaticWrapperPath $Fixture.wrapper `
                        -StaticWrapperSha256 ((Get-FileHash -LiteralPath $Fixture.wrapper -Algorithm SHA256).Hash.ToLowerInvariant()) `
                        -StaticReceiptPath $Fixture.receipt `
                        -StaticReceiptSha256 ((Get-FileHash -LiteralPath $Fixture.receipt -Algorithm SHA256).Hash.ToLowerInvariant()) `
                        -StaticResolutionRunId ('c' * 32) 2>&1)
                    [pscustomobject]@{ exitCode = $LASTEXITCODE; output = ($lines -join "`n") }
                }
                finally { Pop-Location }
            }
            finally {
                foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
            }
        }

        function New-InternalUseBridgeFixture {
            param([Parameter(Mandatory = $true)][string] $Root)
            $candidate = Join-Path $Root 'candidate'
            $skill = Join-Path $candidate 'skills/review-bitbucket-pull-request'
            $output = Join-Path $Root 'output'
            [void](New-Item -ItemType Directory -Path $skill, $output -Force)
            Set-Content -LiteralPath (Join-Path $skill 'SKILL.md') -Value '# Internal review fixture' -Encoding utf8NoBOM

            $child = Join-Path $Root 'child.ps1'
            $runner = Join-Path $Root 'Invoke-StandardValidation.ps1'
            $toolchain = Join-Path $Root 'toolchain.json'
            $powerShellTool = Join-Path $Root 'powershell.fixture'
            $gitTool = Join-Path $Root 'git.fixture'
            [IO.File]::WriteAllText($child, $script:ChildSource, [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($powerShellTool, 'frozen powershell', [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($gitTool, 'frozen git', [Text.UTF8Encoding]::new($false))
            Set-Content -LiteralPath $runner -Encoding utf8NoBOM -Value @'
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $CandidateRoot,
    [Parameter(Mandatory = $true)][string] $AdapterPath,
    [Parameter(Mandatory = $true)][string] $ArtifactsRoot,
    [Parameter(Mandatory = $true)][string] $SourceRepository,
    [Parameter(Mandatory = $true)][string] $SourceRevision,
    [Parameter(Mandatory = $true)][string] $BaseRevision,
    [switch] $DefineFunctionsOnly
)
function Resolve-StandardValidationInternalSkillUse {
    param($SkillRoot, $SourceRepository, $SourceRevision, $SkillId, $Purpose,
        [object[]] $ExpectedAuthorityFiles, [object[]] $ToolInventory)
    if ($SourceRepository -cne 'https://github.com/SyuanTsai/Skill-Atlassian-Ecosystem.git' -or
        $SourceRevision -cne ('f' * 40) -or
        $SkillId -cne 'review-bitbucket-pull-request' -or $Purpose -cne 'local-pr-review' -or
        (Split-Path -Leaf $SkillRoot) -cne $SkillId -or
        @($ExpectedAuthorityFiles).Count -ne 3 -or
        (@($ToolInventory.id | Sort-Object) -join ',') -cne 'git,powershell') {
        throw 'Internal Skill use reader received an invalid consumer binding.'
    }
    [ordered]@{
        schemaVersion = 1; contract = 'internal-skill-use-decision-v1'; status = 'approved'
        approvalId = 'atlassian-bitbucket-review-7e8228c'; sourceRepository = $SourceRepository
        sourceRevision = $SourceRevision; reviewedSourceRevision = '7e8228c393579d5d21ac9c0ad729c7b5d219bab6'
        skillId = $SkillId
        contentSha256 = $(if ([string]::IsNullOrWhiteSpace($env:SOURCE_INTERNAL_TEST_CONTENT_DRIFT)) {
                '056b8e520460e6612b10c8c9248fd7c217c6e4708ca65f3bc6c05b98ee84dec9'
            }
            else { '0' * 64 })
        policySha256 = ('b' * 64); authorizationGranted = $true
        authorizedOperations = @($Purpose); requiredTools = @()
        retainedFindings = @([ordered]@{ ruleId = 'LP3'; findingId = 'finding-1279bfce3ac3466f888a7b9f396e67c5'; severity = 'MEDIUM'; reportSha256 = '55c41e494fe318fcb0365c1addc1dd359162c1798ac67e12b8155caa2c7b16d0'; reportRelation = 'historical-context'; scannedSkillSha256 = ('d' * 64); disposition = 'accepted-host-mediated-internal-use' })
        conditions = @('Exact target/action authorization remains required.')
        hostToolPreauthorization = $false; requiresExactTargetActionAuthorization = $true
        releaseEligible = [bool]::Parse($(if ([string]::IsNullOrWhiteSpace($env:SOURCE_INTERNAL_TEST_RELEASE_ELIGIBLE)) { 'false' } else { $env:SOURCE_INTERNAL_TEST_RELEASE_ELIGIBLE }))
    }
}
if ($DefineFunctionsOnly) { return }
throw 'The fixture runner may only be loaded with DefineFunctionsOnly.'
'@
            $pins = @(
                [ordered]@{ path = 'scripts/Invoke-StandardValidation.ps1'; sha256 = (Get-FileHash -LiteralPath $runner -Algorithm SHA256).Hash.ToLowerInvariant() }
                [ordered]@{ path = 'docs/standards/internal-source-continuation.json'; sha256 = ('1' * 64) }
                [ordered]@{ path = 'docs/standards/schemas/internal-source-continuation-v1.schema.json'; sha256 = ('2' * 64) }
            )
            $tools = @(
                [ordered]@{ id = 'powershell'; version = '7.0'; path = $powerShellTool; sha256 = (Get-FileHash -LiteralPath $powerShellTool -Algorithm SHA256).Hash.ToLowerInvariant() }
                [ordered]@{ id = 'git'; version = '2.0'; path = $gitTool; sha256 = (Get-FileHash -LiteralPath $gitTool -Algorithm SHA256).Hash.ToLowerInvariant() }
            )
            $toolchainValue = [ordered]@{
                internalSkillUse = [ordered]@{
                    runnerPath = $runner
                    runnerSha256 = (Get-FileHash -LiteralPath $runner -Algorithm SHA256).Hash.ToLowerInvariant()
                    approvalId = 'atlassian-bitbucket-review-7e8228c'
                    reviewedSourceRevision = '7e8228c393579d5d21ac9c0ad729c7b5d219bab6'
                    skillId = 'review-bitbucket-pull-request'
                    contentSha256 = '056b8e520460e6612b10c8c9248fd7c217c6e4708ca65f3bc6c05b98ee84dec9'
                    purpose = 'local-pr-review'
                    retainedFindingId = 'finding-1279bfce3ac3466f888a7b9f396e67c5'
                    retainedReportSha256 = '55c41e494fe318fcb0365c1addc1dd359162c1798ac67e12b8155caa2c7b16d0'
                    authorityFiles = $pins
                    toolInventory = $tools
                }
            }
            [IO.File]::WriteAllText($toolchain, ($toolchainValue | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
            [pscustomobject]@{
                candidate = $candidate; output = $output; child = $child; runner = $runner
                toolchain = $toolchain
            }
        }

        function Invoke-InternalUseBridgeFixture {
            param(
                [Parameter(Mandatory = $true)] $Fixture,
                [switch] $ReleaseEligible,
                [switch] $ContentDrift,
                [switch] $DriftRunner
            )
            if ($DriftRunner) { Add-Content -LiteralPath $Fixture.runner -Value '# drift' -Encoding utf8NoBOM }
            $previous = @{}
            foreach ($name in @('STANDARD_VALIDATION_CANDIDATE_ROOT', 'STANDARD_VALIDATION_CANDIDATE_ID',
                    'STANDARD_VALIDATION_ACTIVE_SKILLS', 'STANDARD_VALIDATION_SKILLS_ROOT',
                    'SOURCE_INTERNAL_TEST_RELEASE_ELIGIBLE', 'SOURCE_INTERNAL_TEST_CONTENT_DRIFT')) {
                $previous[$name] = [Environment]::GetEnvironmentVariable($name)
            }
            try {
                $env:STANDARD_VALIDATION_CANDIDATE_ROOT = $Fixture.candidate
                $env:STANDARD_VALIDATION_CANDIDATE_ID = 'e' * 64
                $env:STANDARD_VALIDATION_ACTIVE_SKILLS = 'review-bitbucket-pull-request'
                $env:STANDARD_VALIDATION_SKILLS_ROOT = Join-Path $Fixture.candidate 'skills'
                $env:SOURCE_INTERNAL_TEST_RELEASE_ELIGIBLE = $ReleaseEligible.ToString().ToLowerInvariant()
                $env:SOURCE_INTERNAL_TEST_CONTENT_DRIFT = $(if ($ContentDrift) { 'true' } else { $null })
                Push-Location $Fixture.output
                try {
                    $lines = @(& $script:PowerShellPath -NoProfile -NonInteractive -File $Fixture.child `
                        -Mode internal-skill-use `
                        -ToolchainPath $Fixture.toolchain `
                        -ToolchainSha256 ((Get-FileHash -LiteralPath $Fixture.toolchain -Algorithm SHA256).Hash.ToLowerInvariant()) `
                        -SourceRepository 'https://github.com/SyuanTsai/Skill-Atlassian-Ecosystem.git' `
                        -SourceRevision ('f' * 40) 2>&1)
                    [pscustomobject]@{ exitCode = $LASTEXITCODE; output = ($lines -join "`n") }
                }
                finally { Pop-Location }
            }
            finally {
                foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
            }
        }
    }

    # Scenario: The native SkillSpector prefix is JSON null and a complete single-process scan reports an observed peak of zero after exiting quickly.
    # Purpose: Normalize the prefix while treating peak concurrency as diagnostic when exact report identities prove complete coverage.
    It 'InterT05_NormalizesNullNativePrefixAndAcceptsCompleteLowerPeakEvidence' {
        $fixture = New-StaticBridgeFixture -Root (Join-Path $TestDrive 'null-native-prefix') -UseNullPrefixArguments
        $result = Invoke-StaticBridgeFixture -Fixture $fixture -Reason 'static_parse_limit'
        $result.exitCode | Should -Be 0 -Because $result.output
        Test-Path -LiteralPath $fixture.marker | Should -BeTrue
    }

    # Scenario: the bound SkillSpector 2.12.0 report is partial only because of the supported PowerShell parser limit.
    # Purpose: Keep the native report while requiring the pinned central wrapper to produce a complete graph with findings intact.
    It 'InterT10_UsesTheCentralWrapperForSupportedStaticParseLimit' {
        $fixture = New-StaticBridgeFixture -Root (Join-Path $TestDrive 'supported')
        $result = Invoke-StaticBridgeFixture -Fixture $fixture -Reason 'static_parse_limit'
        $result.exitCode | Should -Be 0 -Because $result.output
        Test-Path -LiteralPath $fixture.marker | Should -BeTrue
        Test-Path -LiteralPath "$($fixture.scannerMarker).manage-confluence-docs-as-code.started" | Should -BeFalse
        Test-Path -LiteralPath "$($fixture.scannerMarker).review-bitbucket-pull-request.started" | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $fixture.output 'skillspector-manage-confluence-docs-as-code.corrected.json.original.json') | Should -BeTrue
        $envelope = $result.output | ConvertFrom-Json -Depth 20
        $envelope.status | Should -Be 'passed'
        (@($envelope.findings | ForEach-Object { "$($_.skillId):$($_.ruleId)" }) -join ',') | Should -Be 'manage-confluence-docs-as-code:E1'
        $envelope.findings[0].severity | Should -Be 'medium'
    }

    # Scenario: The pinned correction is independent of the native scan and both take measurable time.
    # Purpose: Prove the correction starts before the native scan finishes while preserving the native eligibility gate.
    It 'InterT15_OverlapsTheSpeculativeCentralCorrectionWithTheNativeScan' {
        $fixture = New-StaticBridgeFixture -Root (Join-Path $TestDrive 'overlap')
        $result = Invoke-StaticBridgeFixture -Fixture $fixture -Reason 'static_parse_limit' `
            -ScannerDelayMilliseconds 750 -WrapperDelayMilliseconds 750
        $result.exitCode | Should -Be 0 -Because $result.output
        [int64]$wrapperStarted = Get-Content -LiteralPath "$($fixture.marker).started" -Raw
        [int64]$scannerFinished = Get-Content -LiteralPath "$($fixture.scannerMarker).finished" -Raw
        $wrapperStarted | Should -BeLessThan $scannerFinished
    }

    # Scenario: The native report requires correction but the pinned correction process fails.
    # Purpose: Fail closed instead of accepting the known-incomplete native report or a partial correction artifact.
    It 'InterT18_FailsClosedWhenTheRequiredSpeculativeCorrectionFails' {
        $fixture = New-StaticBridgeFixture -Root (Join-Path $TestDrive 'required-correction-fails')
        $result = Invoke-StaticBridgeFixture -Fixture $fixture -Reason 'static_parse_limit' -WrapperFails
        $result.exitCode | Should -Not -Be 0
        $result.output | Should -Match 'central Static correction.*returned exit code 23'
    }

    # Scenario: The wrapper's native report names a different Skill while its corrected report looks complete.
    # Purpose: Bind the correction eligibility gate to the exact target before accepting the corrected result.
    It 'InterT19_RejectsAnUnboundWrapperNativeReport' {
        $fixture = New-StaticBridgeFixture -Root (Join-Path $TestDrive 'native-identity-drift')
        $result = Invoke-StaticBridgeFixture -Fixture $fixture -Reason 'static_parse_limit' -OriginalIdentityDrift
        $result.exitCode | Should -Not -Be 0
        $result.output | Should -Match 'SkillSpector report identity does not match'
    }

    # Scenario: the native report is partial for a different reason.
    # Purpose: Prevent a parser correction from laundering unknown incomplete coverage into a passing Stage 4.
    It 'InterT20_RejectsOtherPartialReasonsWithoutUsingTheSpeculativeCorrection' {
        $fixture = New-StaticBridgeFixture -Root (Join-Path $TestDrive 'unsupported')
        $result = Invoke-StaticBridgeFixture -Fixture $fixture -Reason 'reference_missing'
        $result.exitCode | Should -Not -Be 0
        Test-Path -LiteralPath $fixture.marker | Should -BeTrue
        $result.output | Should -Match 'SkillSpector did not prove complete static analysis'
    }

    # Scenario: The speculative correction is still running when the native report proves an unsupported partial state.
    # Purpose: Terminate the unused process before returning the native gate failure.
    It 'InterT25_StopsAnUnusedSpeculativeCorrectionProcess' {
        $fixture = New-StaticBridgeFixture -Root (Join-Path $TestDrive 'unsupported-cleanup')
        $result = Invoke-StaticBridgeFixture -Fixture $fixture -Reason 'reference_missing' -WrapperDelayMilliseconds 30000
        $result.exitCode | Should -Not -Be 0
        [int]$wrapperProcessId = Get-Content -LiteralPath "$($fixture.marker).pid" -Raw
        { Get-Process -Id $wrapperProcessId -ErrorAction Stop } | Should -Throw
        Test-Path -LiteralPath "$($fixture.marker).finished" | Should -BeFalse
    }

    # Scenario: the native report has the supported exception but an unrelated limitation.
    # Purpose: Do not convert unknown incomplete coverage into a passing Stage 4.
    It 'InterT30_RejectsUnrelatedLimitationWithoutUsingTheSpeculativeCorrection' {
        $fixture = New-StaticBridgeFixture -Root (Join-Path $TestDrive 'unrelated-limitation')
        $result = Invoke-StaticBridgeFixture -Fixture $fixture -Reason 'static_parse_limit' -Limitation 'Unrelated analyzer degraded.'
        $result.exitCode | Should -Not -Be 0
        Test-Path -LiteralPath $fixture.marker | Should -BeTrue
        $result.output | Should -Match 'SkillSpector did not prove complete static analysis'
    }

    # Scenario: The native report is already complete while the unused speculative correction fails.
    # Purpose: Keep the native result authoritative and clean up the unused correction without converting its failure into a gate failure.
    It 'InterT35_IgnoresAnUnusedSpeculativeCorrectionFailureForACompleteNativeReport' {
        $fixture = New-StaticBridgeFixture -Root (Join-Path $TestDrive 'complete-native')
        $result = Invoke-StaticBridgeFixture -Fixture $fixture -Reason 'static_parse_limit' -Complete -WrapperFails
        $result.exitCode | Should -Be 0 -Because $result.output
        Test-Path -LiteralPath $fixture.marker | Should -BeTrue
        $envelope = $result.output | ConvertFrom-Json -Depth 20
        $envelope.status | Should -Be 'passed'
    }

    # Scenario: The immutable consumer pins the central reader, exact reviewed package, local purpose, and frozen tools.
    # Purpose: Prove this repository consumes the central approval instead of parsing or declaring approval locally.
    It 'InterT40_UsesThePinnedCentralReaderForApprovedInternalUse' {
        $fixture = New-InternalUseBridgeFixture -Root (Join-Path $TestDrive 'internal-approved')
        $result = Invoke-InternalUseBridgeFixture -Fixture $fixture
        $result.exitCode | Should -Be 0 -Because $result.output
        $envelope = $result.output | ConvertFrom-Json -Depth 30
        $envelope.status | Should -Be 'passed'
        $envelope.domainAdapterResult.internalSkillUseDecision.status | Should -Be 'approved'
        ($envelope.domainAdapterResult.internalSkillUseDecision.authorizedOperations -join ',') | Should -Be 'local-pr-review'
        $envelope.domainAdapterResult.internalSkillUseDecision.retainedFindings[0].severity | Should -Be 'MEDIUM'
        $envelope.domainAdapterResult.internalSkillUseDecision.hostToolPreauthorization | Should -BeFalse
        $envelope.domainAdapterResult.internalSkillUseDecision.requiresExactTargetActionAuthorization | Should -BeTrue
        $envelope.domainAdapterResult.internalSkillUseDecision.releaseEligible | Should -BeFalse
    }

    # Scenario: The pinned central reader bytes change after the trusted toolchain is prepared.
    # Purpose: Fail before loading an untrusted replacement reader.
    It 'InterT50_RejectsCentralInternalUseReaderDrift' {
        $fixture = New-InternalUseBridgeFixture -Root (Join-Path $TestDrive 'internal-reader-drift')
        $result = Invoke-InternalUseBridgeFixture -Fixture $fixture -DriftRunner
        $result.exitCode | Should -Not -Be 0
        $result.output | Should -Match 'central internal Skill use reader changed or is missing'
    }

    # Scenario: A central result tries to turn internal review approval into release eligibility.
    # Purpose: Preserve the release, install, live-operation, and exact-action authorization boundary.
    It 'InterT60_RejectsAnUnsafeInternalUseDecision' {
        $fixture = New-InternalUseBridgeFixture -Root (Join-Path $TestDrive 'internal-unsafe-decision')
        $result = Invoke-InternalUseBridgeFixture -Fixture $fixture -ReleaseEligible
        $result.exitCode | Should -Not -Be 0
        $result.output | Should -Match 'unsafe internal Skill use decision'
    }

    # Scenario: A central result returns a different package digest under the expected approval identifier.
    # Purpose: Keep the consumer independently bound to the exact package bytes that were reviewed.
    It 'InterT70_RejectsAnUnexpectedInternalSkillContentIdentity' {
        $fixture = New-InternalUseBridgeFixture -Root (Join-Path $TestDrive 'internal-content-drift')
        $result = Invoke-InternalUseBridgeFixture -Fixture $fixture -ContentDrift
        $result.exitCode | Should -Not -Be 0
        $result.output | Should -Match 'unsafe internal Skill use decision'
    }
}
