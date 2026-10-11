# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Standard Core Pester closure and case evidence' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:IntegrityModule = Join-Path $script:RepositoryRoot 'scripts/CorePesterIntegrity.psm1'
        Import-Module -Name $script:IntegrityModule -Force -ErrorAction Stop
    }

    It 'UnitT32_Requires_a_complete_passed_case_partition_and_rejects_skipped_cases' {
        # Scenario: discovery and execution report a single identical passed case with a complete sidecar.
        # Purpose: Require exact case partitioning and make any skipped/inconclusive/unrun status fail closed.
        $identity = Get-CorePesterCaseIdentity -RelativeSourceFile 'tests/Example.Tests.ps1' -StartOffset 42 -ExpandedPath 'Example > passes'
        $discovered = [pscustomobject]@{ identity=$identity; sourceFile='tests/Example.Tests.ps1'; sourceStartLine=4; expandedPath='Example > passes'; result='Passed' }
        $executed = [pscustomobject]@{ identity=$identity; sourceFile='tests/Example.Tests.ps1'; sourceStartLine=4; expandedPath='Example > passes'; result='Passed' }
        $partition = Test-CorePesterCaseIdentityPartition -DiscoveryCases @($discovered) -ExecutionCases @($executed)
        $partition.IsValid | Should -BeTrue
        $shard = Test-CorePesterShardUnion -DiscoveredIdentities @($identity) -Shards @([pscustomobject]@{ id='core-full'; caseIdentities=@($identity) })
        $shard.IsValid | Should -BeTrue

        $valid = [pscustomobject]@{ TotalCount=1; PassedCount=1; FailedCount=0; SkippedCount=0; InconclusiveCount=0; NotRunCount=0; FailedBlocksCount=0; FailedContainersCount=0 }
        (Test-CorePesterRunAcceptance -Result $valid -CaseInventoryComplete $true -CaseInventoryLedgerWritten $true).IsValid | Should -BeTrue
        $skipped = [pscustomobject]@{ TotalCount=2; PassedCount=1; FailedCount=0; SkippedCount=1; InconclusiveCount=0; NotRunCount=0; FailedBlocksCount=0; FailedContainersCount=0 }
        $rejected = Test-CorePesterRunAcceptance -Result $skipped -CaseInventoryComplete $true -CaseInventoryLedgerWritten $true
        $rejected.IsValid | Should -BeFalse
        @($rejected.Errors -join ';') | Should -Match 'SkippedCount'

        $unmatched = Test-CorePesterCaseIdentityPartition -DiscoveryCases @($discovered) -ExecutionCases @()
        $unmatched.IsValid | Should -BeFalse
        $incompleteLedger = Test-CorePesterRunAcceptance -Result $valid -CaseInventoryComplete $false -CaseInventoryLedgerWritten $false
        $incompleteLedger.IsValid | Should -BeFalse
    }

    It 'UnitT33_Executes_unfiltered_Pester_and_writes_the_complete_case_inventory_sidecar' {
        # Scenario: The protected runner sees a canonical candidate snapshot, trusted run identity, closure lock, and one passing Pester case.
        # Purpose: Verify full discovery/execution agreement and durable run-owned sidecar creation in the executable path.
        $runId = [guid]::NewGuid().ToString('N')
        $runRoot = Join-Path $TestDrive "artifacts/runs/$runId"
        $candidateRoot = Join-Path $runRoot 'candidate'
        foreach ($relative in @('scripts', 'config', 'tests')) { [void][IO.Directory]::CreateDirectory((Join-Path $candidateRoot $relative)) }
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Invoke-CorePester.ps1') -Destination (Join-Path $candidateRoot 'scripts/Invoke-CorePester.ps1')
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/CorePesterIntegrity.psm1') -Destination (Join-Path $candidateRoot 'scripts/CorePesterIntegrity.psm1')
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'config/pester-6.2.0-closure.lock.json') -Destination (Join-Path $candidateRoot 'config/pester-6.2.0-closure.lock.json')
        $fixtureTest = @'
Describe 'Core runner fixture' {
    It 'passes one case' { 2 + 2 | Should -Be 4 }
}
'@
        [IO.File]::WriteAllText((Join-Path $candidateRoot 'tests/CoreRunner.Tests.ps1'), $fixtureTest, [Text.UTF8Encoding]::new($false))

        # Give the child an isolated, disposable PowerShell home. The legacy host's
        # PSHOME may have no Pester module (or a different one), and production
        # intentionally requires its exact 6.2.0 closure beneath the child PSHOME.
        # Copy the test host runtime as ordinary files, excluding every installed
        # Pester version, then place only the verified closure payload in the copy.
        $runtimeCopyWatch = [Diagnostics.Stopwatch]::StartNew()
        $hostRuntimeRoot = [IO.Path]::GetFullPath($PSHOME)
        $runtimeRoot = Join-Path $runRoot 'pester-runtime'
        [void][IO.Directory]::CreateDirectory($runtimeRoot)
        $hostItems = @(Get-ChildItem -LiteralPath $hostRuntimeRoot -Force -Recurse -ErrorAction Stop)
        foreach ($item in $hostItems) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "UnitT33 refuses a reparse point in the test host runtime: $($item.FullName)"
            }
            $relativePath = [IO.Path]::GetRelativePath($hostRuntimeRoot, $item.FullName)
            $normalizedRelativePath = $relativePath.Replace('\', '/')
            if ($normalizedRelativePath -match '(^|/)Modules/Pester(/|$)') { continue }
            $targetPath = [IO.Path]::GetFullPath((Join-Path $runtimeRoot $relativePath))
            $runtimePrefix = [IO.Path]::GetFullPath($runtimeRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
            if (-not $targetPath.StartsWith($runtimePrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "UnitT33 runtime copy path escaped its owned root: $relativePath"
            }
            if ($item.PSIsContainer) {
                [void][IO.Directory]::CreateDirectory($targetPath)
            }
            else {
                [void][IO.Directory]::CreateDirectory((Split-Path -Parent $targetPath))
                [IO.File]::Copy($item.FullName, $targetPath, $false)
            }
        }

        $loadedPester = @(Get-Module -Name Pester | Where-Object { $_.Version.ToString() -ceq '6.2.0' })
        $loadedPester.Count | Should -Be 1 -Because 'the fixture must copy the exact Pester closure already hosting this test'
        $closureLockPath = Join-Path $candidateRoot 'config/pester-6.2.0-closure.lock.json'
        $closureLock = Read-CorePesterClosureLock -LiteralPath $closureLockPath
        $sourceModuleRoot = [IO.Path]::GetFullPath([string]$loadedPester[0].ModuleBase)
        [IO.Path]::GetFileName($sourceModuleRoot) | Should -BeExactly '6.2.0'
        $runtimeModuleRoot = Join-Path $runtimeRoot 'Modules/Pester/6.2.0'
        foreach ($payload in $closureLock.Value.modulePayload) {
            $relative = [string]$payload.path
            $sourcePath = Join-Path $sourceModuleRoot ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
            $targetPath = Join-Path $runtimeModuleRoot ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
            Test-Path -LiteralPath $sourcePath -PathType Leaf | Should -BeTrue -Because "verified closure payload is available: $relative"
            $sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
            $sourceHash | Should -BeExactly ([string]$payload.sha256) -Because "loaded Pester payload matches the reviewed lock: $relative"
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $targetPath))
            [IO.File]::Copy($sourcePath, $targetPath, $false)
        }
        $runtimeClosure = Test-CorePesterClosure -ModuleRoot $runtimeModuleRoot -Lock $closureLock.Value
        $runtimeClosure.IsValid | Should -BeTrue -Because (@($runtimeClosure.Errors) -join '; ')
        $runtimeCopyWatch.Stop()

        $powerShellPath = Join-Path $runtimeRoot ([IO.Path]::GetFileName([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName))
        Test-Path -LiteralPath $powerShellPath -PathType Leaf | Should -BeTrue
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $powerShellPath
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.WorkingDirectory = $candidateRoot
        foreach ($argument in @('-NoLogo', '-NoProfile', '-File', (Join-Path $candidateRoot 'scripts/Invoke-CorePester.ps1'))) {
            [void]$startInfo.ArgumentList.Add([string]$argument)
        }
        $startInfo.Environment['STANDARD_VALIDATION_CORE_RUN_ID'] = $runId
        $startInfo.Environment['STANDARD_VALIDATION_CORE_CHECK_ID'] = 'repository-pester'
        $startInfo.Environment['PSModulePath'] = Join-Path $runtimeRoot 'Modules'
        $signalPath = Join-Path $candidateRoot "b-$runId.sig"
        [IO.File]::WriteAllBytes($signalPath, [Text.UTF8Encoding]::new($false).GetBytes('release' + [Environment]::NewLine))
        $startInfo.Environment['STANDARD_VALIDATION_BOOTSTRAP_RELEASE_PATH'] = $signalPath
        $startInfo.Environment['STANDARD_VALIDATION_BOOTSTRAP_COMMAND'] = $powerShellPath
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        try {
            $process.Start() | Should -BeTrue
            $stderrTask = $process.StandardError.ReadToEndAsync()
            $stdout = $process.StandardOutput.ReadToEnd()
            $stderr = $stderrTask.GetAwaiter().GetResult()
            $process.WaitForExit()
            $process.ExitCode | Should -Be 0 -Because $stderr
            $summary = $stdout.Trim() | ConvertFrom-Json -ErrorAction Stop
            $summary.report | Should -Be 'standard-core-pester-result-v1'
            [int]$summary.total | Should -Be 1
            [int]$summary.passed | Should -Be 1
            [int]$summary.skipped | Should -Be 0
            Test-Path -LiteralPath $signalPath | Should -BeFalse

            $ledgerPath = Join-Path $runRoot 'repository-pester-case-inventory-v1.json'
            Test-Path -LiteralPath $ledgerPath -PathType Leaf | Should -BeTrue
            $ledger = Get-Content -LiteralPath $ledgerPath -Raw | ConvertFrom-Json -Depth 12 -ErrorAction Stop
            $ledger.report | Should -Be 'standard-core-pester-case-inventory-v1'
            $ledger.coreRunId | Should -Be $runId
            $ledger.runScope | Should -Be 'complete-unfiltered-tests-tree'
            $ledger.complete | Should -BeTrue
            [int]$ledger.caseDiscoveryCount | Should -Be 1
            [int]$ledger.caseExecutionCount | Should -Be 1
            @($ledger.discoveryCases).Count | Should -Be 1
            @($ledger.executionCases).Count | Should -Be 1
            @($ledger.shardCaseIdentities).Count | Should -Be 1
        }
        finally { $process.Dispose() }
    }

    It 'UnitT34_Restricts_Pester_setup_to_the_registered_fresh_runtime_root' {
        # Scenario: Pester setup is invoked with a verified pwsh executable and a workflow-registered owned root.
        # Purpose: Prevent setup from ever populating the read-only golden runtime or another external PowerShell install.
        $ownedRoot = Join-Path $TestDrive "owned-runtime-$([guid]::NewGuid().ToString('N'))"
        $runtimeRoot = Join-Path $ownedRoot 'runtime'
        [void][IO.Directory]::CreateDirectory($runtimeRoot)
        $runtimeExecutable = Join-Path $runtimeRoot 'pwsh.exe'
        [IO.File]::WriteAllText($runtimeExecutable, 'fixture executable identity', [Text.UTF8Encoding]::new($false))
        $accepted = Assert-CorePesterOwnedRuntime -RuntimeExecutable $runtimeExecutable -OwnedRoot $ownedRoot -CurrentExecutable $runtimeExecutable
        $accepted.Executable | Should -Be ([IO.Path]::GetFullPath($runtimeExecutable))
        $accepted.ModuleRoot | Should -Be (Join-Path $runtimeRoot 'Modules/Pester/6.2.0')

        $goldenRoot = Join-Path $TestDrive 'golden-runtime'
        [void][IO.Directory]::CreateDirectory($goldenRoot)
        $goldenExecutable = Join-Path $goldenRoot 'pwsh.exe'
        [IO.File]::WriteAllText($goldenExecutable, 'read-only golden executable', [Text.UTF8Encoding]::new($false))
        { Assert-CorePesterOwnedRuntime -RuntimeExecutable $goldenExecutable -OwnedRoot $ownedRoot -CurrentExecutable $goldenExecutable } |
            Should -Throw '*outside the registered owned root*'
        { Assert-CorePesterOwnedRuntime -RuntimeExecutable $runtimeExecutable -OwnedRoot $ownedRoot -CurrentExecutable $goldenExecutable } |
            Should -Throw '*exact verified PowerShell executable*'
    }

    It 'UnitT35_Freezes_the_current_run_Pester_receipt_lock_and_all_17_runtime_payloads' {
        # Scenario: A prepared runtime includes its exact setup receipt, lock bytes and every installed payload.
        # Purpose: Preserve the complete Pester runtime identity for later Core report replay.
        $ownedRoot = Join-Path $TestDrive "owned-pester-evidence-$([guid]::NewGuid().ToString('N'))"
        $runtimeRoot = Join-Path $ownedRoot 'runtime'
        $moduleRoot = Join-Path $runtimeRoot 'Modules/Pester/6.2.0'
        $setupRoot = Join-Path $ownedRoot 'pester-setup'
        [void][IO.Directory]::CreateDirectory($moduleRoot)
        [void][IO.Directory]::CreateDirectory($setupRoot)
        $runtimeExecutable = Join-Path $runtimeRoot 'pwsh.exe'
        [IO.File]::WriteAllText($runtimeExecutable, 'fixture runtime executable', [Text.UTF8Encoding]::new($false))

        $baseLockPath = Join-Path $PSScriptRoot '../config/pester-6.2.0-closure.lock.json'
        $baseLock = Read-CorePesterClosureLock -LiteralPath $baseLockPath
        $lock = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $baseLock.Value -Depth 20 -Compress) -AsHashtable -Depth 20
        foreach ($entry in $lock.modulePayload) {
            $target = Join-Path $moduleRoot ([string]$entry.path).Replace('/', [IO.Path]::DirectorySeparatorChar)
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
            $body = 'fixture payload:' + [string]$entry.path
            [IO.File]::WriteAllText($target, $body, [Text.UTF8Encoding]::new($false))
            $entry.sha256 = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        $retainedLockPath = Join-Path $ownedRoot 'pester-6.2.0-closure.lock.json'
        [IO.File]::WriteAllText($retainedLockPath, (ConvertTo-Json -InputObject $lock -Depth 20) + "`n", [Text.UTF8Encoding]::new($false))
        $lockRecord = Read-CorePesterClosureLock -LiteralPath $retainedLockPath
        $closure = Test-CorePesterClosure -ModuleRoot $moduleRoot -Lock $lockRecord.Value
        $receipt = [ordered]@{
            schemaVersion = 1
            report = 'verified-pester-runtime-setup-v1'
            lockPath = $retainedLockPath
            runtimeExecutable = $runtimeExecutable
            runtimeModuleRoot = $moduleRoot
            lockSha256 = $lockRecord.Sha256
            closureSha256 = $closure.ClosureSha256
            payload = @($closure.Inventory)
            terminalStatus = 'verified'
        }
        $receiptPath = Join-Path $setupRoot 'setup-receipt.json'
        [IO.File]::WriteAllText($receiptPath, (ConvertTo-Json -InputObject $receipt -Depth 8 -Compress) + "`n", [Text.UTF8Encoding]::new($false))

        $frozen = Get-CorePesterFrozenRuntimeFiles -OwnedRoot $ownedRoot -RuntimeExecutable $runtimeExecutable `
            -SetupReceiptPath $receiptPath -ClosureLockPath $retainedLockPath
        @($frozen.frozenFiles).Count | Should -Be 20
        @($frozen.frozenFiles | Where-Object { [string]$_.path -ceq $receiptPath }).Count | Should -Be 1
        @($frozen.frozenFiles | Where-Object { [string]$_.path -ceq $retainedLockPath }).Count | Should -Be 1
        @($frozen.frozenFiles | Where-Object { [string]$_.path -like "$moduleRoot*" }).Count | Should -Be 17

        $mutated = Join-Path $moduleRoot ([string]$lock.modulePayload[0].path).Replace('/', [IO.Path]::DirectorySeparatorChar)
        [IO.File]::AppendAllText($mutated, ' changed')
        { Get-CorePesterFrozenRuntimeFiles -OwnedRoot $ownedRoot -RuntimeExecutable $runtimeExecutable `
                -SetupReceiptPath $receiptPath -ClosureLockPath $retainedLockPath } |
            Should -Throw '*runtime no longer matches its verified closure*'
    }
}
