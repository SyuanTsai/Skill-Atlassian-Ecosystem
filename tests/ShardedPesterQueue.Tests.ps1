# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Pester worker queue claims' {
    BeforeAll {
        $helperPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Invoke-ShardedPester.ps1'
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($helperPath, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -ne 0) { throw 'The scheduler must parse before its worker can be tested.' }
        $assignments = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
                $node.Left.VariablePath.UserPath -ceq 'workerScript'
        }, $false))
        if ($assignments.Count -ne 1) { throw 'Expected one scheduler worker definition.' }
        $script:Worker = $assignments[0].Right.Expression.ScriptBlock.GetScriptBlock()
        $script:Module = Get-Module Pester | Select-Object -First 1
    }

    BeforeEach {
        $script:SavedWorkerEnvironment = @{}
        foreach ($name in @('SYP304_PESTER_MODULE', 'SYP304_PESTER_VERSION', 'SYP304_PESTER_QUEUE', 'SYP304_PESTER_WORKER_ROOT')) {
            $script:SavedWorkerEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        $fixtureRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:QueueRoot = Join-Path $fixtureRoot 'queue'
        $script:WorkerRoot = Join-Path $fixtureRoot 'worker'
        [void](New-Item -ItemType Directory -Path $script:QueueRoot, $script:WorkerRoot)
        $env:SYP304_PESTER_MODULE = Join-Path $script:Module.ModuleBase 'Pester.psd1'
        $env:SYP304_PESTER_VERSION = [string]$script:Module.Version
        $env:SYP304_PESTER_QUEUE = $script:QueueRoot
        $env:SYP304_PESTER_WORKER_ROOT = $script:WorkerRoot
        Mock Import-Module { }
        $script:HeadPath = Join-Path $script:QueueRoot 'task-0000.json'
        $script:NextPath = Join-Path $script:QueueRoot 'task-0001.json'
        foreach ($path in @($script:HeadPath, $script:NextPath)) {
            $payload = @{ isRecycleToken = $true; requiresFreshWorker = $false; exitWorkerAfterTask = $true }
            [IO.File]::WriteAllText($path, ($payload | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        }
    }

    AfterEach {
        foreach ($entry in $script:SavedWorkerEnvironment.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
        }
    }

    # Scenario: The head payload is readable, but another file handle prevents its atomic move.
    # Purpose: Fail closed instead of skipping priority work or consuming a later recycle boundary.
    It 'UnitT10_DoesNotSkipAnUnclaimedHeadWhenItsMoveFails' {
        $headHandle = [IO.File]::Open($script:HeadPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $claimError = $null
            try { & $script:Worker }
            catch { $claimError = $_.Exception.GetBaseException() }
            $claimError | Should -BeOfType ([IO.IOException])
            ($claimError.HResult -band 0xffff) | Should -Be 32
            Test-Path -LiteralPath $script:HeadPath | Should -BeTrue
            Test-Path -LiteralPath $script:NextPath | Should -BeTrue
            @(Get-ChildItem -LiteralPath $script:WorkerRoot -File).Count | Should -Be 0
        }
        finally { $headHandle.Dispose() }
        & $script:Worker
        Test-Path -LiteralPath $script:HeadPath | Should -BeFalse
        Test-Path -LiteralPath $script:NextPath | Should -BeTrue
    }

    # Scenario: A worker claims a recycle token at the head of an otherwise available queue.
    # Purpose: Claim exactly one boundary and exit without consuming work intended for a fresh process.
    It 'UnitT20_ExitsAtTheFirstRecycleBoundary' {
        & $script:Worker
        Test-Path -LiteralPath $script:HeadPath | Should -BeFalse
        Test-Path -LiteralPath $script:NextPath | Should -BeTrue
        @(Get-ChildItem -LiteralPath $script:WorkerRoot -File).Count | Should -Be 0
    }
}
