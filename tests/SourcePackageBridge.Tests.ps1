# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Source conformance package bridge' {
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

        function New-PackageBridgeFixture {
            param([Parameter(Mandatory = $true)][string] $Root)
            $candidate = Join-Path $Root 'candidate'
            $skillsRoot = Join-Path $candidate 'skills'
            $trustedRoot = Join-Path $Root 'trusted'
            $outputRoot = Join-Path $Root 'output'
            [void](New-Item -ItemType Directory -Path $skillsRoot, $trustedRoot, $outputRoot -Force)
            foreach ($skillId in @('alpha-skill', 'beta-skill')) {
                $skillRoot = Join-Path $skillsRoot $skillId
                [void](New-Item -ItemType Directory -Path $skillRoot -Force)
                [IO.File]::WriteAllText((Join-Path $skillRoot 'SKILL.md'), "# $skillId`n", [Text.UTF8Encoding]::new($false))
            }

            $child = Join-Path $Root 'child.ps1'
            $validator = Join-Path $Root 'validator.ps1'
            $tools = Join-Path $Root 'tools.ps1'
            $toolchain = Join-Path $trustedRoot 'toolchain.json'
            [IO.File]::WriteAllText($child, $script:ChildSource, [Text.UTF8Encoding]::new($false))
            Set-Content -LiteralPath $validator -Encoding utf8NoBOM -Value @'
$skillRoot = [string]$args[-1]
$skillId = Split-Path -Leaf $skillRoot
$marker = Join-Path $env:SOURCE_PACKAGE_TEST_MARKERS "validator-$skillId"
[IO.File]::WriteAllText("$marker.started", [DateTime]::UtcNow.Ticks.ToString(), [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText("$marker.pid", $PID.ToString(), [Text.UTF8Encoding]::new($false))
if ($env:SOURCE_PACKAGE_TEST_FAIL -ceq "validator/$skillId") { [Console]::Error.WriteLine('fixture validator failure'); exit 23 }
$barrierCount = [int]$env:SOURCE_PACKAGE_TEST_BARRIER_COUNT
if ($barrierCount -gt 0) {
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while (@(Get-ChildItem -LiteralPath $env:SOURCE_PACKAGE_TEST_MARKERS -Filter '*.started').Count -lt $barrierCount) {
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Package test process barrier timed out.' }
        Start-Sleep -Milliseconds 50
    }
}
if ([int]$env:SOURCE_PACKAGE_TEST_DELAY_MS -gt 0) { Start-Sleep -Milliseconds ([int]$env:SOURCE_PACKAGE_TEST_DELAY_MS) }
[IO.File]::WriteAllText("$marker.finished", [DateTime]::UtcNow.Ticks.ToString(), [Text.UTF8Encoding]::new($false))
[ordered]@{
    skill_dir = $skillRoot; passed = $true; errors = 0; warnings = 0
    results = @([ordered]@{ level = 'pass'; category = 'structure'; message = 'valid'; file = (Join-Path $skillRoot 'SKILL.md') })
} | ConvertTo-Json -Depth 10 -Compress
'@
            Set-Content -LiteralPath $tools -Encoding utf8NoBOM -Value @'
$skillRoot = [string]$args[1]
$skillId = Split-Path -Leaf $skillRoot
$marker = Join-Path $env:SOURCE_PACKAGE_TEST_MARKERS "tools-$skillId"
[IO.File]::WriteAllText("$marker.started", [DateTime]::UtcNow.Ticks.ToString(), [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText("$marker.pid", $PID.ToString(), [Text.UTF8Encoding]::new($false))
if ($env:SOURCE_PACKAGE_TEST_FAIL -ceq "tools/$skillId") { [Console]::Error.WriteLine('fixture tools failure'); exit 24 }
$barrierCount = [int]$env:SOURCE_PACKAGE_TEST_BARRIER_COUNT
if ($barrierCount -gt 0) {
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while (@(Get-ChildItem -LiteralPath $env:SOURCE_PACKAGE_TEST_MARKERS -Filter '*.started').Count -lt $barrierCount) {
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Package test process barrier timed out.' }
        Start-Sleep -Milliseconds 50
    }
}
if ([int]$env:SOURCE_PACKAGE_TEST_DELAY_MS -gt 0) { Start-Sleep -Milliseconds ([int]$env:SOURCE_PACKAGE_TEST_DELAY_MS) }
[IO.File]::WriteAllText("$marker.finished", [DateTime]::UtcNow.Ticks.ToString(), [Text.UTF8Encoding]::new($false))
[ordered]@{
    version = '2.1.0'
    runs = @([ordered]@{ tool = [ordered]@{ driver = [ordered]@{ name = 'skill-tools'; rules = @() } }; results = @() })
} | ConvertTo-Json -Depth 10 -Compress
'@
            $toolchainValue = [ordered]@{
                skillValidatorPath = $script:PowerShellPath
                skillValidatorSha256 = (Get-FileHash -LiteralPath $script:PowerShellPath -Algorithm SHA256).Hash.ToLowerInvariant()
                skillValidatorPrefixArguments = @('-NoProfile', '-NonInteractive', '-File', $validator)
                skillToolsNodePath = $script:PowerShellPath
                skillToolsNodeSha256 = (Get-FileHash -LiteralPath $script:PowerShellPath -Algorithm SHA256).Hash.ToLowerInvariant()
                skillToolsEntryPointPath = $tools
                skillToolsEntryPointSha256 = (Get-FileHash -LiteralPath $tools -Algorithm SHA256).Hash.ToLowerInvariant()
            }
            [IO.File]::WriteAllText($toolchain, ($toolchainValue | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
            [pscustomobject]@{
                candidate = $candidate; skillsRoot = $skillsRoot; trustedRoot = $trustedRoot
                outputRoot = $outputRoot; child = $child; toolchain = $toolchain
                markers = (Join-Path $Root 'markers')
            }
        }

        function Invoke-PackageBridgeFixture {
            param(
                [Parameter(Mandatory = $true)] $Fixture,
                [Parameter(Mandatory = $true)][ValidateSet('skill-validator', 'skill-tools')][string] $Mode,
                [Parameter(Mandatory = $true)][string] $SkillId,
                [string] $CandidateId = ('b' * 64),
                [string] $ActiveSkills = 'alpha-skill;beta-skill',
                [int] $DelayMilliseconds = 0,
                [int] $BarrierCount = 0,
                [string] $Fail = ''
            )
            [void](New-Item -ItemType Directory -Path $Fixture.markers -Force)
            $output = Join-Path $Fixture.outputRoot "$Mode-$SkillId-$([guid]::NewGuid().ToString('N'))"
            [void](New-Item -ItemType Directory -Path $output -Force)
            $previous = @{}
            foreach ($name in @('STANDARD_VALIDATION_CANDIDATE_ROOT', 'STANDARD_VALIDATION_CANDIDATE_ID',
                    'STANDARD_VALIDATION_ACTIVE_SKILLS', 'STANDARD_VALIDATION_SKILLS_ROOT',
                    'STANDARD_VALIDATION_SKILL_ID', 'STANDARD_VALIDATION_SKILL_INVENTORY_SHA256',
                    'SOURCE_PACKAGE_TEST_MARKERS', 'SOURCE_PACKAGE_TEST_DELAY_MS', 'SOURCE_PACKAGE_TEST_BARRIER_COUNT',
                    'SOURCE_PACKAGE_TEST_FAIL')) {
                $previous[$name] = [Environment]::GetEnvironmentVariable($name)
            }
            try {
                $env:STANDARD_VALIDATION_CANDIDATE_ROOT = $Fixture.candidate
                $env:STANDARD_VALIDATION_CANDIDATE_ID = $CandidateId
                $env:STANDARD_VALIDATION_ACTIVE_SKILLS = $ActiveSkills
                $env:STANDARD_VALIDATION_SKILLS_ROOT = $Fixture.skillsRoot
                $env:STANDARD_VALIDATION_SKILL_ID = $SkillId
                $env:STANDARD_VALIDATION_SKILL_INVENTORY_SHA256 = 'c' * 64
                $env:SOURCE_PACKAGE_TEST_MARKERS = $Fixture.markers
                $env:SOURCE_PACKAGE_TEST_DELAY_MS = $DelayMilliseconds.ToString()
                $env:SOURCE_PACKAGE_TEST_BARRIER_COUNT = $BarrierCount.ToString()
                $env:SOURCE_PACKAGE_TEST_FAIL = $Fail
                Push-Location $output
                try {
                    $lines = @(& $script:PowerShellPath -NoProfile -NonInteractive -File $Fixture.child `
                        -Mode $Mode `
                        -ToolchainPath $Fixture.toolchain `
                        -ToolchainSha256 ((Get-FileHash -LiteralPath $Fixture.toolchain -Algorithm SHA256).Hash.ToLowerInvariant()) 2>&1)
                    [pscustomobject]@{ exitCode = $LASTEXITCODE; output = ($lines -join "`n") }
                }
                finally { Pop-Location }
            }
            finally {
                foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
            }
        }
    }

    # Scenario: The central environment repeats an active Skill identity before the package batch starts.
    # Purpose: Reject an ambiguous report inventory before creating cache paths or running native tools.
    It 'InterT08_RejectsDuplicateActiveSkillIdentities' {
        $fixture = New-PackageBridgeFixture -Root (Join-Path $TestDrive 'batch-duplicate-skill')
        $result = Invoke-PackageBridgeFixture -Fixture $fixture -Mode skill-validator -SkillId alpha-skill `
            -ActiveSkills 'alpha-skill;alpha-skill'
        $result.exitCode | Should -Not -Be 0
        $result.output | Should -Match 'Duplicate active Skill identity'
        Test-Path -LiteralPath (Join-Path $fixture.trustedRoot 'package-batch-v1') | Should -BeFalse
    }

    # Scenario: The first package dispatch has two active Skills and both mandatory tools take measurable time.
    # Purpose: Prove all four native checks overlap and later central dispatches reuse only candidate-bound validated reports.
    It 'InterT10_BatchesNativePackageChecksAndReusesBoundReports' {
        $fixture = New-PackageBridgeFixture -Root (Join-Path $TestDrive 'batch-success')
        $first = Invoke-PackageBridgeFixture -Fixture $fixture -Mode skill-validator -SkillId alpha-skill `
            -DelayMilliseconds 250 -BarrierCount 4
        $first.exitCode | Should -Be 0 -Because $first.output
        $second = Invoke-PackageBridgeFixture -Fixture $fixture -Mode skill-tools -SkillId beta-skill -Fail 'tools/beta-skill'
        $second.exitCode | Should -Be 0 -Because $second.output
        @(Get-ChildItem -LiteralPath $fixture.markers -Filter '*.started').Count | Should -Be 4
        [int64]$latestStart = Get-ChildItem -LiteralPath $fixture.markers -Filter '*.started' | ForEach-Object { [int64](Get-Content $_.FullName -Raw) } | Measure-Object -Maximum | Select-Object -ExpandProperty Maximum
        [int64]$earliestFinish = Get-ChildItem -LiteralPath $fixture.markers -Filter '*.finished' | ForEach-Object { [int64](Get-Content $_.FullName -Raw) } | Measure-Object -Minimum | Select-Object -ExpandProperty Minimum
        $latestStart | Should -BeLessThan $earliestFinish
    }

    # Scenario: A completed native package report is changed before its matching central dispatch consumes it.
    # Purpose: Reject report substitution instead of replaying unbound package evidence.
    It 'InterT20_FailsClosedWhenABatchedReportDrifts' {
        $fixture = New-PackageBridgeFixture -Root (Join-Path $TestDrive 'batch-drift')
        $first = Invoke-PackageBridgeFixture -Fixture $fixture -Mode skill-validator -SkillId alpha-skill
        $first.exitCode | Should -Be 0 -Because $first.output
        $report = Get-ChildItem -LiteralPath (Join-Path $fixture.trustedRoot 'package-batch-v1') -Filter 'skill-tools-beta-skill.json' | Select-Object -First 1
        Add-Content -LiteralPath $report.FullName -Value 'drift' -Encoding utf8NoBOM
        $drifted = Invoke-PackageBridgeFixture -Fixture $fixture -Mode skill-tools -SkillId beta-skill
        $drifted.exitCode | Should -Not -Be 0
        $drifted.output | Should -Match 'batched package report changed'
    }

    # Scenario: A completed batch is presented by a child process with a different central candidate identity.
    # Purpose: Prevent a successful native report set from being replayed across immutable candidates.
    It 'InterT25_RejectsABatchFromAnotherCandidate' {
        $fixture = New-PackageBridgeFixture -Root (Join-Path $TestDrive 'batch-candidate')
        $first = Invoke-PackageBridgeFixture -Fixture $fixture -Mode skill-validator -SkillId alpha-skill
        $first.exitCode | Should -Be 0 -Because $first.output
        $replayed = Invoke-PackageBridgeFixture -Fixture $fixture -Mode skill-tools -SkillId beta-skill -CandidateId ('d' * 64)
        $replayed.exitCode | Should -Not -Be 0
        $replayed.output | Should -Match 'does not match the current candidate'
    }

    # Scenario: One Skill changes after the batch captures and validates its complete file inventory.
    # Purpose: Revalidate the requested Skill bytes before consuming its cached native report.
    It 'InterT27_RejectsABatchAfterSkillInventoryDrift' {
        $fixture = New-PackageBridgeFixture -Root (Join-Path $TestDrive 'batch-inventory')
        $first = Invoke-PackageBridgeFixture -Fixture $fixture -Mode skill-validator -SkillId alpha-skill
        $first.exitCode | Should -Be 0 -Because $first.output
        Add-Content -LiteralPath (Join-Path $fixture.skillsRoot 'beta-skill/SKILL.md') -Value 'drift' -Encoding utf8NoBOM
        $drifted = Invoke-PackageBridgeFixture -Fixture $fixture -Mode skill-tools -SkillId beta-skill
        $drifted.exitCode | Should -Not -Be 0
        $drifted.output | Should -Match 'Skill inventory changed before batched package report consumption'
    }

    # Scenario: Either the first or last native tool fails while the remaining batch members are still running.
    # Purpose: Detect failure regardless of launch order and reap every child before any delayed sibling completes.
    It 'InterT30_ReapsTheWholeBatchWhenOneNativeCheckFails' {
        foreach ($failedCheck in @('validator/alpha-skill', 'tools/beta-skill')) {
            $fixture = New-PackageBridgeFixture -Root (Join-Path $TestDrive ('batch-failure-' + ($failedCheck -replace '/', '-')))
            $failed = Invoke-PackageBridgeFixture -Fixture $fixture -Mode skill-validator -SkillId alpha-skill `
                -DelayMilliseconds 5000 -Fail $failedCheck
            $failed.exitCode | Should -Not -Be 0
            $failed.output | Should -Match 'fixture (validator|tools) failure'
            @(Get-ChildItem -LiteralPath $fixture.markers -Filter '*.finished').Count | Should -Be 0
            Start-Sleep -Milliseconds 250
            foreach ($pidFile in Get-ChildItem -LiteralPath $fixture.markers -Filter '*.pid') {
                $workerId = [int](Get-Content -LiteralPath $pidFile.FullName -Raw)
                Get-Process -Id $workerId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            }
        }
    }
}
