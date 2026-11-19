# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Repository validation helpers' {
    BeforeAll {
        $script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        function Invoke-ValidationHelper {
            param([Parameter(Mandatory)][string] $FileName)
            $start = [Diagnostics.ProcessStartInfo]::new()
            $start.FileName = (Get-Process -Id $PID).Path
            $start.WorkingDirectory = $script:RepositoryRoot
            $start.UseShellExecute = $false
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            $testRoot = Join-Path $script:RepositoryRoot 'tests'
            foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', (Join-Path $testRoot $FileName), '-RepositoryRoot', $script:RepositoryRoot)) {
                [void]$start.ArgumentList.Add($argument)
            }
            $process = [Diagnostics.Process]::new()
            $process.StartInfo = $start
            try {
                [void]$process.Start()
                $stdoutTask = $process.StandardOutput.ReadToEndAsync()
                $stderrTask = $process.StandardError.ReadToEndAsync()
                $process.WaitForExit()
                [pscustomobject]@{
                    ExitCode = $process.ExitCode
                    StandardOutput = $stdoutTask.GetAwaiter().GetResult()
                    StandardError = $stderrTask.GetAwaiter().GetResult()
                }
            }
            finally {
                $process.Dispose()
            }
        }
    }

    It 'executes the consumer repository helper with a successful exit code' {
        $result = Invoke-ValidationHelper -FileName 'validate-repository.ps1'
        $result.ExitCode | Should -Be 0 -Because $result.StandardError
    }

    It 'executes the standalone snapshot helper with a successful exit code' {
        $result = Invoke-ValidationHelper -FileName 'validate-repository-standalone.ps1'
        $result.ExitCode | Should -Be 0 -Because $result.StandardError
    }

    It 'executes the PowerShell syntax helper with a successful exit code' {
        $result = Invoke-ValidationHelper -FileName 'validate-windows-powershell.ps1'
        $result.ExitCode | Should -Be 0 -Because $result.StandardError
    }

    It 'executes the retained API-access helper with a successful exit code' {
        $result = Invoke-ValidationHelper -FileName 'validate-api-access.ps1'
        $result.ExitCode | Should -Be 0 -Because $result.StandardError
        $result.StandardOutput | Should -Match 'API access validation tests passed'
    }
}
