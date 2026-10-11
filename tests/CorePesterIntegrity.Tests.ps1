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
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Prepare-PesterRuntime.ps1') -Destination (Join-Path $candidateRoot 'scripts/Prepare-PesterRuntime.ps1')
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

        $closureLockPath = Join-Path $candidateRoot 'config/pester-6.2.0-closure.lock.json'
        $closureLock = Read-CorePesterClosureLock -LiteralPath $closureLockPath
        $runtimeModuleRoot = Join-Path $runtimeRoot 'Modules/Pester/6.2.0'
        $sourceCandidates = @(
            (Get-Module -Name Pester | Where-Object { $_.Version.ToString() -ceq '6.2.0' } | ForEach-Object { [string]$_.ModuleBase }) +
            (Get-Module -Name Pester -ListAvailable | Where-Object { $_.Version.ToString() -ceq '6.2.0' } | ForEach-Object { [string]$_.ModuleBase })
        ) | Select-Object -Unique
        $sourceModuleRoot = $null
        foreach ($candidateModuleRoot in $sourceCandidates) {
            $candidateClosure = Test-CorePesterClosure -ModuleRoot $candidateModuleRoot -Lock $closureLock.Value
            if ($candidateClosure.IsValid) { $sourceModuleRoot = [IO.Path]::GetFullPath($candidateModuleRoot); break }
        }
        if ($null -ne $sourceModuleRoot) {
            foreach ($payload in $closureLock.Value.modulePayload) {
                $relative = [string]$payload.path
                $sourcePath = Join-Path $sourceModuleRoot ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
                $targetPath = Join-Path $runtimeModuleRoot ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
                Test-Path -LiteralPath $sourcePath -PathType Leaf | Should -BeTrue -Because "verified 6.2.0 closure payload is available: $relative"
                $sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
                $sourceHash | Should -BeExactly ([string]$payload.sha256) -Because "available Pester payload matches the reviewed lock: $relative"
                [void][IO.Directory]::CreateDirectory((Split-Path -Parent $targetPath))
                [IO.File]::Copy($sourcePath, $targetPath, $false)
            }
        }
        else {
            # Do not require the test host to have Pester 6.2.0 loaded. Prepare the pinned official closure
            # inside this disposable owned runtime using the same bounded setup path used by Core v2.
            $powerShellPath = Join-Path $runtimeRoot ([IO.Path]::GetFileName([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName))
            $preparePath = Join-Path $candidateRoot 'scripts/Prepare-PesterRuntime.ps1'
            $prepareInfo = [Diagnostics.ProcessStartInfo]::new()
            $prepareInfo.FileName = $powerShellPath
            $prepareInfo.UseShellExecute = $false
            $prepareInfo.CreateNoWindow = $true
            $prepareInfo.RedirectStandardOutput = $true
            $prepareInfo.RedirectStandardError = $true
            $prepareInfo.WorkingDirectory = $candidateRoot
            foreach ($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',$preparePath,'-RuntimeExecutable',$powerShellPath,'-OwnedRoot',$runRoot)) {
                [void]$prepareInfo.ArgumentList.Add([string]$argument)
            }
            $prepareInfo.Environment.Clear()
            foreach ($name in @('SystemRoot','WINDIR','PATH','PATHEXT','TEMP','TMP','TMPDIR','USERPROFILE','COMSPEC','ProgramFiles','ProgramFiles(x86)','ProgramW6432')) {
                $value = [Environment]::GetEnvironmentVariable($name)
                if (-not [string]::IsNullOrWhiteSpace($value)) { $prepareInfo.Environment[$name] = $value }
            }
            $prepareInfo.Environment['STANDARD_VALIDATION_RUN_OWNED_ROOT'] = $runRoot
            $prepareProcess = [Diagnostics.Process]::new()
            $prepareProcess.StartInfo = $prepareInfo
            try {
                $prepareProcess.Start() | Should -BeTrue
                $prepareStdoutTask = $prepareProcess.StandardOutput.ReadToEndAsync()
                $prepareStderrTask = $prepareProcess.StandardError.ReadToEndAsync()
                if (-not $prepareProcess.WaitForExit(210000)) {
                    $prepareProcess.Kill($true); $prepareProcess.WaitForExit()
                    throw 'Pinned Pester fallback setup exceeded its owned 210-second test deadline.'
                }
                $prepareStdout = $prepareStdoutTask.GetAwaiter().GetResult()
                $prepareStderr = $prepareStderrTask.GetAwaiter().GetResult()
                $prepareProcess.ExitCode | Should -Be 0 -Because ($prepareStdout + $prepareStderr)
                Test-Path -LiteralPath (Join-Path $runRoot 'pester-setup/setup-receipt.json') -PathType Leaf | Should -BeTrue
            }
            finally { $prepareProcess.Dispose() }
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

    It 'UnitT61_Bounds_Pester_package_download_bytes_deadline_and_HTTPS_redirects' {
        # Scenario: A package acquisition follows one HTTPS redirect and streams a small body into a fresh owned path.
        # Purpose: Enforce the 32 MiB ceiling, a single total acquisition deadline, HTTPS-only redirects, and partial-file cleanup.
        if ($null -eq ('CorePesterQueuedHttpHandler' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
public sealed class CorePesterQueuedHttpHandler : HttpMessageHandler {
    private readonly Queue<HttpResponseMessage> responses;
    public List<string> RequestedUris { get; } = new List<string>();
    public int DelayMilliseconds { get; set; }
    public CorePesterQueuedHttpHandler(HttpResponseMessage[] items) { responses = new Queue<HttpResponseMessage>(items); }
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) {
        RequestedUris.Add(request.RequestUri.AbsoluteUri);
        if (DelayMilliseconds > 0) await Task.Delay(DelayMilliseconds, cancellationToken).ConfigureAwait(false);
        if (responses.Count == 0) throw new InvalidOperationException("No queued HTTP response remains.");
        return responses.Dequeue();
    }
}
'@ -ErrorAction Stop
        }
        $root = Join-Path $TestDrive ('pester-bounded-download-' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($root)
        $makeResponse = {
            param([int]$StatusCode, [byte[]]$Body, [string]$Location)
            $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]$StatusCode)
            if ($null -ne $Body) { $response.Content = [Net.Http.ByteArrayContent]::new($Body) }
            if (-not [string]::IsNullOrWhiteSpace($Location)) { $response.Headers.Location = [uri]$Location }
            return $response
        }.GetNewClosure()

        $bodyBytes = [Text.UTF8Encoding]::new($false).GetBytes('verified bytes')
        $successDestination = Join-Path $root 'success.nupkg'
        $successHandler = [CorePesterQueuedHttpHandler]::new([Net.Http.HttpResponseMessage[]]@(
            (& $makeResponse 302 $null '/redirected-package'),
            (& $makeResponse 200 $bodyBytes $null)
        ))
        $successClient = [Net.Http.HttpClient]::new($successHandler)
        try {
            $transfer = Receive-CorePesterBoundedPackage -Uri ([uri]'https://packages.example.invalid/start') `
                -DestinationPath $successDestination -MaximumBytes 65536 -TimeoutSeconds 10 -Client $successClient
            $transfer.finalUri | Should -BeExactly 'https://packages.example.invalid/redirected-package'
            $transfer.redirectCount | Should -Be 1
            $transfer.byteCount | Should -Be $bodyBytes.Length
            [Convert]::ToHexString([IO.File]::ReadAllBytes($successDestination)) | Should -BeExactly ([Convert]::ToHexString($bodyBytes))
            @($successHandler.RequestedUris) | Should -Be @('https://packages.example.invalid/start', 'https://packages.example.invalid/redirected-package')
        }
        finally { $successClient.Dispose() }

        $existingDestination = Join-Path $root 'preexisting.nupkg'
        $existingBytes = [Text.UTF8Encoding]::new($false).GetBytes('keep unrelated caller file')
        [IO.File]::WriteAllBytes($existingDestination, $existingBytes)
        $existingStream = [IO.MemoryStream]::new($bodyBytes, $false)
        try {
            { Copy-CorePesterBoundedStream -InputStream $existingStream -DestinationPath $existingDestination `
                -MaximumBytes 65536 -DeclaredLength $bodyBytes.Length } | Should -Throw '*destination already exists*'
        }
        finally { $existingStream.Dispose() }
        [Convert]::ToHexString([IO.File]::ReadAllBytes($existingDestination)) | Should -BeExactly ([Convert]::ToHexString($existingBytes))

        $existingFailureHandler = [CorePesterQueuedHttpHandler]::new([Net.Http.HttpResponseMessage[]]@(
            (& $makeResponse 503 $null $null)
        ))
        $existingFailureClient = [Net.Http.HttpClient]::new($existingFailureHandler)
        try {
            { Receive-CorePesterBoundedPackage -Uri ([uri]'https://packages.example.invalid/unavailable') `
                -DestinationPath $existingDestination -MaximumBytes 65536 -TimeoutSeconds 10 -Client $existingFailureClient } |
                Should -Throw '*HTTP status 503*'
        }
        finally { $existingFailureClient.Dispose() }
        [Convert]::ToHexString([IO.File]::ReadAllBytes($existingDestination)) | Should -BeExactly ([Convert]::ToHexString($existingBytes))

        # Exercise the owned-client path without downloading a package. The reserved .invalid host must fail at the transport layer.
        $defaultClientDestination = Join-Path $root 'default-client-failure.nupkg'
        $defaultClientTimer = [Diagnostics.Stopwatch]::StartNew()
        $defaultClientFailure = $null
        try {
            Receive-CorePesterBoundedPackage -Uri ([uri]'https://packages.example.invalid/unavailable') `
                -DestinationPath $defaultClientDestination -MaximumBytes 65536 -TimeoutSeconds 1 | Out-Null
        }
        catch { $defaultClientFailure = $_.Exception }
        finally { $defaultClientTimer.Stop() }
        $defaultClientFailure | Should -Not -BeNull -Because 'the reserved .invalid host must fail without obtaining a package'
        $transportFailureObserved = $false
        $failureCursor = $defaultClientFailure
        while ($null -ne $failureCursor) {
            if ($failureCursor -is [Net.Http.HttpRequestException] -or
                $failureCursor -is [OperationCanceledException]) {
                $transportFailureObserved = $true
                break
            }
            $failureCursor = $failureCursor.InnerException
        }
        $transportFailureObserved | Should -BeTrue -Because 'omitting Client must reach a real HTTP transport failure rather than a client-initialization error'
        $defaultClientFailure.ToString() | Should -Not -Match 'Cannot find type|Unable to find type|TypeNotFoundException'
        $defaultClientTimer.Elapsed.TotalSeconds | Should -BeLessThan 10 -Because 'the one-second acquisition deadline must remain bounded'
        Test-Path -LiteralPath $defaultClientDestination | Should -BeFalse

        $partialDestination = Join-Path $root 'partial.nupkg'
        $oversizedBody = [byte[]]::new(65537)
        $oversizedStream = [IO.MemoryStream]::new($oversizedBody, $false)
        try {
            { Copy-CorePesterBoundedStream -InputStream $oversizedStream -DestinationPath $partialDestination `
                -MaximumBytes 65536 -DeclaredLength -1 } | Should -Throw '*streaming limit*'
        }
        finally { $oversizedStream.Dispose() }
        Test-Path -LiteralPath $partialDestination | Should -BeFalse -Because 'a body that crosses the byte cap must remove its partial output'

        $declaredDestination = Join-Path $root 'declared-too-large.nupkg'
        $declaredHandler = [CorePesterQueuedHttpHandler]::new([Net.Http.HttpResponseMessage[]]@(
            (& $makeResponse 200 ([byte[]]::new(65537)) $null)
        ))
        $declaredClient = [Net.Http.HttpClient]::new($declaredHandler)
        try {
            { Receive-CorePesterBoundedPackage -Uri ([uri]'https://packages.example.invalid/large') `
                -DestinationPath $declaredDestination -MaximumBytes 65536 -TimeoutSeconds 10 -Client $declaredClient } |
                Should -Throw '*Content-Length exceeds*'
        }
        finally { $declaredClient.Dispose() }
        Test-Path -LiteralPath $declaredDestination | Should -BeFalse

        $httpRedirectDestination = Join-Path $root 'http-redirect.nupkg'
        $httpRedirectHandler = [CorePesterQueuedHttpHandler]::new([Net.Http.HttpResponseMessage[]]@(
            (& $makeResponse 302 $null 'http://packages.example.invalid/insecure')
        ))
        $httpRedirectClient = [Net.Http.HttpClient]::new($httpRedirectHandler)
        try {
            { Receive-CorePesterBoundedPackage -Uri ([uri]'https://packages.example.invalid/start') `
                -DestinationPath $httpRedirectDestination -MaximumBytes 65536 -TimeoutSeconds 10 -Client $httpRedirectClient } |
                Should -Throw '*HTTPS*'
        }
        finally { $httpRedirectClient.Dispose() }
        Test-Path -LiteralPath $httpRedirectDestination | Should -BeFalse

        $deadlineDestination = Join-Path $root 'deadline.nupkg'
        $deadlineHandler = [CorePesterQueuedHttpHandler]::new([Net.Http.HttpResponseMessage[]]@(
            (& $makeResponse 200 $bodyBytes $null)
        ))
        $deadlineHandler.DelayMilliseconds = 1500
        $deadlineClient = [Net.Http.HttpClient]::new($deadlineHandler)
        try {
            { Receive-CorePesterBoundedPackage -Uri ([uri]'https://packages.example.invalid/slow') `
                -DestinationPath $deadlineDestination -MaximumBytes 65536 -TimeoutSeconds 1 -Client $deadlineClient } |
                Should -Throw
        }
        finally { $deadlineClient.Dispose() }
        Test-Path -LiteralPath $deadlineDestination | Should -BeFalse

        $redirectLimitDestination = Join-Path $root 'redirect-limit.nupkg'
        $redirectResponses = [Collections.Generic.List[Net.Http.HttpResponseMessage]]::new()
        for ($index = 1; $index -le 4; $index++) {
            $redirectResponses.Add((& $makeResponse 302 $null "https://packages.example.invalid/redirect-$index"))
        }
        $redirectHandler = [CorePesterQueuedHttpHandler]::new([Net.Http.HttpResponseMessage[]]$redirectResponses.ToArray())
        $redirectClient = [Net.Http.HttpClient]::new($redirectHandler)
        try {
            { Receive-CorePesterBoundedPackage -Uri ([uri]'https://packages.example.invalid/start') `
                -DestinationPath $redirectLimitDestination -MaximumBytes 65536 -TimeoutSeconds 10 -Client $redirectClient } |
                Should -Throw '*maximum 3 HTTPS redirects*'
        }
        finally { $redirectClient.Dispose() }
        @($redirectHandler.RequestedUris).Count | Should -Be 4
        Test-Path -LiteralPath $redirectLimitDestination | Should -BeFalse
    }

    It 'UnitT62_Selects_the_verified_Pester_6_2_closure_when_the_host_has_6_3' {
        # Scenario: The host exposes Pester 6.3 while the isolated runtime contains the one pinned 6.2 manifest.
        # Purpose: Ignore a newer ambient host version, accept only the exact verified 6.2 candidate, and reject a foreign 6.2 shadow.
        $runtimeRoot = Join-Path $TestDrive 'pester-6.2-runtime'
        $expectedManifest = Join-Path $runtimeRoot 'Modules/Pester/6.2.0/Pester.psd1'
        $host63Manifest = Join-Path $TestDrive 'host-modules/Pester/6.3.0/Pester.psd1'
        $foreign62Manifest = Join-Path $TestDrive 'foreign-modules/Pester/6.2.0/Pester.psd1'
        $pinned = [pscustomobject]@{ Name='Pester'; Version=[version]'6.2.0'; Path=$expectedManifest }
        $host63 = [pscustomobject]@{ Name='Pester'; Version=[version]'6.3.0'; Path=$host63Manifest }
        $selected = Test-CorePesterModuleCandidates -ExpectedManifestPath $expectedManifest -Candidates @($pinned,$host63)
        $selected.IsValid | Should -BeTrue -Because (@($selected.Errors) -join '; ')
        $selected.SameVersionCount | Should -Be 1

        $newerWithoutPinned = Test-CorePesterModuleCandidates -ExpectedManifestPath $expectedManifest -Candidates @($host63)
        $newerWithoutPinned.IsValid | Should -BeFalse
        $newerWithoutPinned.SameVersionCount | Should -Be 0

        $foreign62 = [pscustomobject]@{ Name='Pester'; Version=[version]'6.2.0'; Path=$foreign62Manifest }
        $shadowed = Test-CorePesterModuleCandidates -ExpectedManifestPath $expectedManifest -Candidates @($pinned,$host63,$foreign62)
        $shadowed.IsValid | Should -BeFalse
        @($shadowed.Errors -join ';') | Should -Match 'outside the verified runtime'
    }
}
