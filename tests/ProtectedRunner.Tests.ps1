# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Atlassian protected runner contracts' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:ValidatorPath = Join-Path $script:RepositoryRoot 'scripts/Validate.ps1'
        $script:Validator = Get-Content -LiteralPath $script:ValidatorPath -Raw
        $tokens = $null
        $parseErrors = $null
        $script:ValidatorAst = [Management.Automation.Language.Parser]::ParseFile($script:ValidatorPath, [ref]$tokens, [ref]$parseErrors)
        if (@($parseErrors).Count -ne 0) { throw 'Validator does not parse.' }
    }

    # Scenario: The validator declares the immutable test files required for every run.
    # Purpose: A newly added repository test cannot silently be excluded from formal evidence.
    It 'UnitT10_RequiresEveryActualAtlassianPesterTestFileExactlyOnce' {
        $definitions = @($script:ValidatorAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-RequiredPesterTests'
        }, $false))
        $definitions.Count | Should -Be 1
        . ([scriptblock]::Create($definitions[0].Extent.Text))
        $required = @(Get-RequiredPesterTests)
        @($required | Sort-Object -Unique).Count | Should -Be $required.Count
        $actual = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' -File | Select-Object -ExpandProperty Name | Sort-Object)
        @($required | Sort-Object) | Should -Be $actual
    }

    # Scenario: A candidate is evaluated through a materialized trusted test tree.
    # Purpose: Keep event-bound tests and completion proof outside candidate-controlled output.
    It 'UnitT20_BindsTestsAndCompletionToTheTrustedSupervisor' {
        $script:Validator | Should -Match 'Invoke-ProtectedPesterRunspace'
        $script:Validator | Should -Match 'CreateOutOfProcessRunspace'
        $script:Validator | Should -Match "completionAttestation = 'trusted-parent-post-exit'"
        $script:Validator | Should -Match '\$trustedPesterCommit = if \(\$isGitHubActions\) \{ \[string\]\$env:GITHUB_SHA \} else \{ \$candidateCommit \}'
        $script:Validator | Should -Match 'Assert-TrustedGitTreeFile'
        $script:Validator | Should -Not -Match 'NamedPipeServerStream|NamedPipeClientStream|CompletionPipeName|CompletionToken'
        $script:Validator | Should -Match '\$pesterConfiguration.Run.Path = \$requiredPesterPaths'
        $script:Validator | Should -Match '\$pesterConfiguration.Run.PassThru = \$true'
        $script:Validator | Should -Match '\$pesterConfiguration.TestRegistry.Enabled = \$false'
        $script:Validator | Should -Match 'Invoke-Pester -Configuration \$pesterConfiguration'
    }

    # Scenario: The Windows canonical adapter executes candidate processes.
    # Purpose: Retain restricted-token, Job Object, and offline boundaries after the ordinary Linux route retires.
    It 'UnitT30_RequiresWindowsContainmentAndOfflineCandidateExecution' {
        $script:Validator | Should -Match '\$script:IsSupportedProcessBoundaryHost = \$script:IsWindowsHost'
        $script:Validator | Should -Match 'CreateRestrictedToken'
        $script:Validator | Should -Match 'SetInformationJobObject'
        $script:Validator | Should -Match '\[string\] \$NetworkProfile = ''Offline'''
        $script:Validator | Should -Match '-NetworkProfile TrustedSemantic'
    }

    # Scenario: A Windows child is started suspended before candidate code can run.
    # Purpose: Assign the child to the owned Job Object before releasing it.
    It 'UnitT40_AssignsWindowsJobBeforeCandidateRelease' {
        $definition = @($script:ValidatorAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-NativeChecked'
        }, $false))
        $definition.Count | Should -Be 1
        $invokeNative = $definition[0].Extent.Text
        $startOffset = $invokeNative.IndexOf('Start-WindowsSuspendedProcess')
        $attachOffset = $invokeNative.IndexOf('Assign-WindowsProcessToJob')
        $releaseOffset = $invokeNative.IndexOf('$childProcess.Resume()')
        $startOffset | Should -BeGreaterThan -1
        $attachOffset | Should -BeGreaterThan $startOffset
        $releaseOffset | Should -BeGreaterThan $attachOffset
        $invokeNative | Should -Match 'New-WindowsKillOnCloseJob'
        $invokeNative | Should -Match 'Stop-ProcessTree'
    }

    # Scenario: A real Windows child emits ordinary and excessive output, then another exits nonzero.
    # Purpose: Exercise the validator's bounded stream reader against actual pipes and preserve process exit evidence.
    It 'InterT50_BoundsRealWindowsChildOutputAndPreservesExit' -Skip:(-not $IsWindows) {
        $definition = @($script:ValidatorAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Get-WindowsSuspendedProcessBoundaryType'
        }, $false))
        $definition.Count | Should -Be 1
        . ([scriptblock]::Create($definition[0].Extent.Text))
        $boundary = Get-WindowsSuspendedProcessBoundaryType
        $pwsh = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path

        foreach ($case in @(
            @{ command = "[Console]::Out.Write('ordinary'); exit 0"; limit = 128; text = 'ordinary'; truncated = $false; exitCode = 0 },
            @{ command = "[Console]::Out.Write('x' * 8193); exit 0"; limit = 8192; text = $null; truncated = $true; exitCode = 0 },
            @{ command = "[Console]::Error.Write('failed'); exit 7"; limit = 128; text = ''; truncated = $false; exitCode = 7 }
        )) {
            $info = [Diagnostics.ProcessStartInfo]::new()
            $info.FileName = $pwsh
            $info.UseShellExecute = $false
            $info.CreateNoWindow = $true
            $info.RedirectStandardOutput = $true
            $info.RedirectStandardError = $true
            foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $case.command)) {
                [void]$info.ArgumentList.Add($argument)
            }
            $process = [Diagnostics.Process]::new()
            $process.StartInfo = $info
            try {
                $process.Start() | Should -BeTrue
                $stdout = $boundary::ReadBoundedAsync($process.StandardOutput, [int]$case.limit)
                $stderr = $boundary::ReadBoundedAsync($process.StandardError, [int]$case.limit)
                if (-not $process.WaitForExit(10000)) { throw 'Real child exceeded the test timeout.' }
                $stdout.Wait(5000) | Should -BeTrue
                $stderr.Wait(5000) | Should -BeTrue
                $out = $stdout.GetAwaiter().GetResult()
                $err = $stderr.GetAwaiter().GetResult()
                $process.ExitCode | Should -Be ([int]$case.exitCode)
                $out.Truncated | Should -Be ([bool]$case.truncated)
                if ($null -ne $case.text) { $out.Text | Should -Be ([string]$case.text) }
                if ($case.exitCode -eq 7) { $err.Text | Should -Be 'failed' }
            }
            finally {
                if (-not $process.HasExited) { $process.Kill($true); [void]$process.WaitForExit(5000) }
                $process.Dispose()
            }
        }
    }

    # Scenario: A contained Windows child launches one descendant after Job assignment.
    # Purpose: Closing the owned Job Object must terminate both processes within a bounded wait.
    It 'InterT60_ClosingWindowsJobTerminatesOwnedDescendant' -Skip:(-not $IsWindows) {
        $script:IsWindowsHost = $true
        foreach ($name in @('Get-WindowsProcessBoundaryType', 'New-WindowsKillOnCloseJob',
                'Assign-WindowsProcessToJob', 'Close-WindowsProcessJob')) {
            $definition = @($script:ValidatorAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
            }, $false))
            $definition.Count | Should -Be 1
            . ([scriptblock]::Create($definition[0].Extent.Text))
        }
        $root = Join-Path $TestDrive 'job-descendant'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $flag = Join-Path $root 'release.flag'
        $pidFile = Join-Path $root 'descendant.pid'
        $childScript = Join-Path $root 'descendant.ps1'
        $parentScript = Join-Path $root 'parent.ps1'
        Set-Content -LiteralPath $childScript -Value 'Start-Sleep -Seconds 30' -Encoding utf8NoBOM
        Set-Content -LiteralPath $parentScript -Value @'
param([string] $Flag, [string] $PidFile, [string] $ChildScript)
$deadline = [DateTime]::UtcNow.AddSeconds(10)
while (-not (Test-Path -LiteralPath $Flag)) {
    if ([DateTime]::UtcNow -ge $deadline) { exit 3 }
    Start-Sleep -Milliseconds 50
}
$inner = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-File',$ChildScript) -PassThru -WindowStyle Hidden
[IO.File]::WriteAllText($PidFile, [string]$inner.Id)
Start-Sleep -Seconds 30
'@ -Encoding utf8NoBOM
        $pwsh = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = $pwsh
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        foreach ($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',$parentScript,$flag,$pidFile,$childScript)) {
            [void]$info.ArgumentList.Add($argument)
        }
        $job = [IntPtr]::Zero
        $parent = [Diagnostics.Process]::new()
        $parent.StartInfo = $info
        $descendant = $null
        try {
            $parent.Start() | Should -BeTrue
            $job = New-WindowsKillOnCloseJob -Context 'SYP-159 descendant probe'
            Assign-WindowsProcessToJob -JobHandle $job -Process $parent -Context 'SYP-159 descendant probe'
            [IO.File]::WriteAllText($flag, 'go')
            $deadline = [DateTime]::UtcNow.AddSeconds(10)
            while (-not (Test-Path -LiteralPath $pidFile)) {
                if ([DateTime]::UtcNow -ge $deadline) { throw 'Contained descendant was not started.' }
                Start-Sleep -Milliseconds 50
            }
            $descendantId = [int][IO.File]::ReadAllText($pidFile)
            $descendant = [Diagnostics.Process]::GetProcessById($descendantId)
            $descendant.HasExited | Should -BeFalse
            Close-WindowsProcessJob -JobHandle $job
            $job = [IntPtr]::Zero
            $parent.WaitForExit(5000) | Should -BeTrue
            $descendant.WaitForExit(5000) | Should -BeTrue
        }
        finally {
            if ($job -ne [IntPtr]::Zero) { Close-WindowsProcessJob -JobHandle $job }
            if (-not $parent.HasExited) { $parent.Kill($true); [void]$parent.WaitForExit(5000) }
            if ($null -ne $descendant) {
                if (-not $descendant.HasExited) { $descendant.Kill($true); [void]$descendant.WaitForExit(5000) }
                $descendant.Dispose()
            }
            $parent.Dispose()
        }
    }

    # Scenario: A real contained Windows child outlives the one-second execution deadline.
    # Purpose: Prove the retained Job Object path terminates the timed-out child promptly.
    It 'InterT70_TerminatesTimedOutWindowsChild' -Skip:(-not $IsWindows) {
        $script:IsWindowsHost = $true
        foreach ($name in @('Get-WindowsProcessBoundaryType', 'New-WindowsKillOnCloseJob',
                'Assign-WindowsProcessToJob', 'Stop-WindowsProcessJob', 'Close-WindowsProcessJob')) {
            $definition = @($script:ValidatorAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
            }, $false))
            $definition.Count | Should -Be 1
            . ([scriptblock]::Create($definition[0].Extent.Text))
        }
        $pwsh = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = $pwsh
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        foreach ($argument in @('-NoLogo','-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 30')) {
            [void]$info.ArgumentList.Add($argument)
        }
        $job = [IntPtr]::Zero
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $info
        try {
            $process.Start() | Should -BeTrue
            $job = New-WindowsKillOnCloseJob -Context 'SYP-159 timeout probe'
            Assign-WindowsProcessToJob -JobHandle $job -Process $process -Context 'SYP-159 timeout probe'
            $process.WaitForExit(1000) | Should -BeFalse
            Stop-WindowsProcessJob -JobHandle $job
            $process.WaitForExit(5000) | Should -BeTrue
        }
        finally {
            if ($job -ne [IntPtr]::Zero) { Close-WindowsProcessJob -JobHandle $job }
            if (-not $process.HasExited) { $process.Kill($true); [void]$process.WaitForExit(5000) }
            $process.Dispose()
        }
    }
}
