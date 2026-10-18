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
            $candidateScripts = Join-Path $candidate 'scripts'
            $output = Join-Path $Root 'output'
            [void](New-Item -ItemType Directory -Path $skill, $candidateScripts, $output -Force)
            Set-Content -LiteralPath (Join-Path $skill 'SKILL.md') -Value '# Test skill' -Encoding utf8NoBOM
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
$reportPath = [string]$args[-1]
$reason = [string]$env:SOURCE_STATIC_TEST_REASON
$limitation = [string]$env:SOURCE_STATIC_TEST_LIMITATION
$report = [ordered]@{
    execution_successful = $true
    skill = [ordered]@{ name = (Split-Path -Leaf $skillRoot); source = $skillRoot }
    analysis_completeness = [ordered]@{
        execution_successful = $true; is_complete = $false; status = 'partial'; coverage_percent = 50
        ledger_exceptions = @([ordered]@{
            path = 'SKILL.md'; phase = 'static'; outcome = 'partial'; reason_code = $reason
            fatal = $false; analyzers = @('static_patterns_tool_misuse')
        })
        scope_exclusions = @(); limitations = @($limitation)
    }
    components = @([ordered]@{ path = 'SKILL.md' })
    issues = @([ordered]@{ id = 'E1'; severity = 'medium'; message = 'Retained finding' })
}
[IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
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
    $report = [ordered]@{
        execution_successful = $true
        skill = [ordered]@{ name = $skillId; source = $skillRoot }
        analysis_completeness = [ordered]@{
            execution_successful = $true; is_complete = $false; status = 'partial'; coverage_percent = 50
            ledger_exceptions = @([ordered]@{
                path = 'SKILL.md'; phase = 'static'; outcome = 'partial'; reason_code = $env:SOURCE_STATIC_TEST_REASON
                fatal = $false; analyzers = @('static_patterns_tool_misuse')
            })
            scope_exclusions = @(); limitations = @($env:SOURCE_STATIC_TEST_LIMITATION)
        }
        components = @([ordered]@{ path = 'SKILL.md' })
        issues = @([ordered]@{ id = 'E1'; severity = 'medium'; message = 'Retained finding' })
    }
    [IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
}
$summary = [ordered]@{
    marker = 'atlassian-parallel-skillspector-v1'; skillIds = $skillIds
    processCount = $skillIds.Count; maxObservedConcurrency = $skillIds.Count
}
[IO.File]::WriteAllText($SummaryPath, ($summary | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
'@
            }
            Set-Content -LiteralPath $wrapper -Encoding utf8NoBOM -Value @'
param($ToolReceiptPath, $ExpectedToolReceiptSha256, $ExpectedResolutionRunId, $SkillRoot,
    $SourceRevision, $CandidateIdentity, $ReportPath, $EvidencePath)
[IO.File]::WriteAllText($env:SOURCE_STATIC_TEST_WRAPPER_MARKER, 'called', [Text.UTF8Encoding]::new($false))
$sourcePath = Join-Path (Get-Location) ("skillspector-$(Split-Path -Leaf $SkillRoot).json")
$report = Get-Content -LiteralPath $sourcePath -Raw | ConvertFrom-Json -Depth 20
$report.analysis_completeness.is_complete = $true
$report.analysis_completeness.status = 'complete'
$report.analysis_completeness.coverage_percent = 100
$report.analysis_completeness.ledger_exceptions = @()
$report.analysis_completeness.limitations = @()
[IO.File]::WriteAllText($ReportPath, ($report | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
foreach ($sidecar in @($EvidencePath, "$EvidencePath.profile.json", "$ReportPath.original.json")) {
    [IO.File]::WriteAllText($sidecar, '{}', [Text.UTF8Encoding]::new($false))
}
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
            }
        }

        function Invoke-StaticBridgeFixture {
            param([Parameter(Mandatory = $true)] $Fixture, [Parameter(Mandatory = $true)][string] $Reason,
                [string] $Limitation = 'Analyzer static_patterns_tool_misuse status: degraded.')
            $previous = @{}
            foreach ($name in @('STANDARD_VALIDATION_CANDIDATE_ROOT', 'STANDARD_VALIDATION_CANDIDATE_ID',
                    'STANDARD_VALIDATION_ACTIVE_SKILLS', 'STANDARD_VALIDATION_SKILLS_ROOT',
                    'SOURCE_STATIC_TEST_REASON', 'SOURCE_STATIC_TEST_LIMITATION', 'SOURCE_STATIC_TEST_WRAPPER_MARKER')) {
                $previous[$name] = [Environment]::GetEnvironmentVariable($name)
            }
            try {
                $env:STANDARD_VALIDATION_CANDIDATE_ROOT = $Fixture.candidate
                $env:STANDARD_VALIDATION_CANDIDATE_ID = 'b' * 64
                $env:STANDARD_VALIDATION_ACTIVE_SKILLS = 'manage-confluence-docs-as-code'
                $env:STANDARD_VALIDATION_SKILLS_ROOT = Join-Path $Fixture.candidate 'skills'
                $env:SOURCE_STATIC_TEST_REASON = $Reason
                $env:SOURCE_STATIC_TEST_LIMITATION = $Limitation
                $env:SOURCE_STATIC_TEST_WRAPPER_MARKER = $Fixture.marker
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

    # Scenario: The resolved native SkillSpector toolchain represents its absent executable prefix as JSON null.
    # Purpose: Normalize an absent prefix to an empty argument list before crossing the child/helper process boundary.
    It 'InterT05_NormalizesNullNativePrefixArgumentsToAnEmptyArray' {
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
        Test-Path -LiteralPath (Join-Path $fixture.output 'skillspector-manage-confluence-docs-as-code.json') | Should -BeTrue
        $envelope = $result.output | ConvertFrom-Json -Depth 20
        $envelope.status | Should -Be 'passed'
        @($envelope.findings).Count | Should -Be 1
        $envelope.findings[0].severity | Should -Be 'medium'
    }

    # Scenario: the native report is partial for a different reason.
    # Purpose: Prevent a parser correction from laundering unknown incomplete coverage into a passing Stage 4.
    It 'InterT20_RejectsOtherPartialReasonsWithoutCallingTheWrapper' {
        $fixture = New-StaticBridgeFixture -Root (Join-Path $TestDrive 'unsupported')
        $result = Invoke-StaticBridgeFixture -Fixture $fixture -Reason 'reference_missing'
        $result.exitCode | Should -Not -Be 0
        Test-Path -LiteralPath $fixture.marker | Should -BeFalse
        $result.output | Should -Match 'SkillSpector did not prove complete static analysis'
    }

    # Scenario: the native report has the supported exception but an unrelated limitation.
    # Purpose: Do not convert unknown incomplete coverage into a passing Stage 4.
    It 'InterT30_RejectsUnrelatedLimitationWithoutCallingTheWrapper' {
        $fixture = New-StaticBridgeFixture -Root (Join-Path $TestDrive 'unrelated-limitation')
        $result = Invoke-StaticBridgeFixture -Fixture $fixture -Reason 'static_parse_limit' -Limitation 'Unrelated analyzer degraded.'
        $result.exitCode | Should -Not -Be 0
        Test-Path -LiteralPath $fixture.marker | Should -BeFalse
        $result.output | Should -Match 'SkillSpector did not prove complete static analysis'
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
