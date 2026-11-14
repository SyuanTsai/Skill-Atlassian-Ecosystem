# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Shared configure API access references' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:SyncScript = Join-Path $script:RepositoryRoot 'scripts/Sync-SharedReferences.ps1'
        $script:SourceRelativePath = 'docs/shared-references/configure-api-access/manual-persistence-linux-macos.md'
        $script:DestinationRelativePaths = @(
            'skills/configure-bitbucket-api-access/references/manual-persistence-linux-macos.md'
            'skills/configure-confluence-api-access/references/manual-persistence-linux-macos.md'
            'skills/configure-jira-api-access/references/manual-persistence-linux-macos.md'
        )
        $script:PwshPath = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path

        function Invoke-SharedReferenceSync {
            param(
                [Parameter(Mandatory)][string] $RepositoryRoot,
                [Parameter()][switch] $Check,
                [Parameter()][int] $FailStagingIndex
            )

            $scriptPath = Join-Path $RepositoryRoot 'scripts/Sync-SharedReferences.ps1'
            $startInfo = [Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $script:PwshPath
            $startInfo.UseShellExecute = $false
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            [void]$startInfo.Environment.Remove('SYP_SHARED_REFERENCES_TEST_FAIL_STAGING_INDEX')
            if ($FailStagingIndex -gt 0) {
                $startInfo.Environment['SYP_SHARED_REFERENCES_TEST_FAIL_STAGING_INDEX'] = [string]$FailStagingIndex
            }
            foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $scriptPath)) {
                [void]$startInfo.ArgumentList.Add($argument)
            }
            if ($Check) { [void]$startInfo.ArgumentList.Add('-Check') }

            $process = [Diagnostics.Process]::new()
            $process.StartInfo = $startInfo
            try {
                [void]$process.Start()
                $stdout = $process.StandardOutput.ReadToEnd()
                $stderr = $process.StandardError.ReadToEnd()
                $process.WaitForExit()
                [pscustomobject]@{
                    ExitCode = $process.ExitCode
                    Stdout = $stdout
                    Stderr = $stderr
                }
            }
            finally {
                $process.Dispose()
            }
        }

        function New-MinimalSharedReferenceRepository {
            param(
                [Parameter(Mandatory)][string] $Root
            )

            New-Item -ItemType Directory -Path (Join-Path $Root 'scripts') -Force | Out-Null
            Copy-Item -LiteralPath $script:SyncScript -Destination (Join-Path $Root 'scripts/Sync-SharedReferences.ps1')
            $sourcePath = Join-Path $Root $script:SourceRelativePath
            New-Item -ItemType Directory -Path (Split-Path -Parent $sourcePath) -Force | Out-Null
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes("alpha`nbeta`n")
            [IO.File]::WriteAllBytes($sourcePath, $bytes)
            foreach ($relativePath in $script:DestinationRelativePaths) {
                $destinationPath = Join-Path $Root $relativePath
                New-Item -ItemType Directory -Path (Split-Path -Parent $destinationPath) -Force | Out-Null
                [IO.File]::WriteAllBytes($destinationPath, $bytes)
            }
        }
    }

    It 'checks the repository copies and their SHA-256 values' {
        $result = Invoke-SharedReferenceSync -RepositoryRoot $script:RepositoryRoot -Check
        $result.ExitCode | Should -Be 0 -Because $result.Stderr
        $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $script:RepositoryRoot $script:SourceRelativePath)).Hash
        foreach ($relativePath in $script:DestinationRelativePaths) {
            (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $script:RepositoryRoot $relativePath)).Hash | Should -BeExactly $sourceHash
        }
    }

    It 'reports a changed destination byte and repairs all copies' {
        $root = Join-Path $TestDrive 'changed-byte'
        New-MinimalSharedReferenceRepository -Root $root
        $changedRelativePath = $script:DestinationRelativePaths[1]
        $changedPath = Join-Path $root $changedRelativePath
        $bytes = [IO.File]::ReadAllBytes($changedPath)
        $bytes[0] = $bytes[0] -bxor 1
        [IO.File]::WriteAllBytes($changedPath, $bytes)

        $check = Invoke-SharedReferenceSync -RepositoryRoot $root -Check
        $check.ExitCode | Should -Not -Be 0
        ($check.Stdout + $check.Stderr) | Should -Match ([regex]::Escape($changedRelativePath))

        (Invoke-SharedReferenceSync -RepositoryRoot $root).ExitCode | Should -Be 0
        (Invoke-SharedReferenceSync -RepositoryRoot $root -Check).ExitCode | Should -Be 0
        $sourceBytes = [IO.File]::ReadAllBytes((Join-Path $root $script:SourceRelativePath))
        foreach ($relativePath in $script:DestinationRelativePaths) {
            [IO.File]::ReadAllBytes((Join-Path $root $relativePath)) | Should -Be $sourceBytes
        }
    }

    It 'reports a missing destination' {
        $root = Join-Path $TestDrive 'missing-copy'
        New-MinimalSharedReferenceRepository -Root $root
        $missingRelativePath = $script:DestinationRelativePaths[0]
        Remove-Item -LiteralPath (Join-Path $root $missingRelativePath) -Force

        $check = Invoke-SharedReferenceSync -RepositoryRoot $root -Check
        $check.ExitCode | Should -Not -Be 0
        ($check.Stdout + $check.Stderr) | Should -Match ([regex]::Escape($missingRelativePath))
    }

    It 'reports source drift before synchronization' {
        $root = Join-Path $TestDrive 'source-drift'
        New-MinimalSharedReferenceRepository -Root $root
        [IO.File]::WriteAllBytes(
            (Join-Path $root $script:SourceRelativePath),
            [Text.UTF8Encoding]::new($false).GetBytes("changed source`n")
        )

        (Invoke-SharedReferenceSync -RepositoryRoot $root -Check).ExitCode | Should -Not -Be 0
    }

    It 'detects CRLF as byte drift' {
        $root = Join-Path $TestDrive 'crlf-drift'
        New-MinimalSharedReferenceRepository -Root $root
        $changedRelativePath = $script:DestinationRelativePaths[2]
        [IO.File]::WriteAllBytes(
            (Join-Path $root $changedRelativePath),
            [Text.UTF8Encoding]::new($false).GetBytes("alpha`r`nbeta`r`n")
        )

        $check = Invoke-SharedReferenceSync -RepositoryRoot $root -Check
        $check.ExitCode | Should -Not -Be 0
        ($check.Stdout + $check.Stderr) | Should -Match ([regex]::Escape($changedRelativePath))
    }

    It 'does not change destination files or leave temporary files when staging fails' {
        $root = Join-Path $TestDrive 'staging-failure'
        New-MinimalSharedReferenceRepository -Root $root
        $originalBytes = @{}
        foreach ($relativePath in $script:DestinationRelativePaths) {
            $destinationPath = Join-Path $root $relativePath
            $changedBytes = [Text.UTF8Encoding]::new($false).GetBytes(("old {0}" -f $relativePath))
            [IO.File]::WriteAllBytes($destinationPath, $changedBytes)
            $originalBytes[$relativePath] = $changedBytes
        }

        $result = Invoke-SharedReferenceSync -RepositoryRoot $root -FailStagingIndex 2

        $result.ExitCode | Should -Not -Be 0
        ($result.Stdout + $result.Stderr) | Should -Match 'staging failed'
        foreach ($relativePath in $script:DestinationRelativePaths) {
            $destinationPath = Join-Path $root $relativePath
            [IO.File]::ReadAllBytes($destinationPath) | Should -Be $originalBytes[$relativePath]
            [IO.Directory]::GetFiles((Split-Path -Parent $destinationPath), '.*.tmp') | Should -HaveCount 0
        }
    }

    if ($IsWindows) {
        It 'rejects a junction destination on Windows' {
            $root = Join-Path $TestDrive 'junction-destination'
            New-MinimalSharedReferenceRepository -Root $root
            $destinationPath = Join-Path $root $script:DestinationRelativePaths[0]
            Remove-Item -LiteralPath $destinationPath -Force
            $targetDirectory = Join-Path $TestDrive 'junction-target'
            New-Item -ItemType Directory -Path $targetDirectory | Out-Null
            New-Item -ItemType Junction -Path $destinationPath -Target $targetDirectory | Out-Null

            $check = Invoke-SharedReferenceSync -RepositoryRoot $root -Check
            $check.ExitCode | Should -Not -Be 0
            ($check.Stdout + $check.Stderr) | Should -Match 'reparse point'
        }

        It 'rejects a dangling junction in check and synchronization modes on Windows' {
            $root = Join-Path $TestDrive 'dangling-junction-destination'
            New-MinimalSharedReferenceRepository -Root $root
            $destinationPath = Join-Path $root $script:DestinationRelativePaths[0]
            Remove-Item -LiteralPath $destinationPath -Force
            $outsideTarget = Join-Path $TestDrive 'removed-junction-target'
            New-Item -ItemType Directory -Path $outsideTarget | Out-Null
            New-Item -ItemType Junction -Path $destinationPath -Target $outsideTarget | Out-Null
            Remove-Item -LiteralPath $outsideTarget -Force

            $check = Invoke-SharedReferenceSync -RepositoryRoot $root -Check
            $sync = Invoke-SharedReferenceSync -RepositoryRoot $root

            $check.ExitCode | Should -Not -Be 0
            $sync.ExitCode | Should -Not -Be 0
            ($check.Stdout + $check.Stderr + $sync.Stdout + $sync.Stderr) | Should -Match 'reparse point'
            Test-Path -LiteralPath $outsideTarget | Should -BeFalse
        }
    }
    else {
        It 'rejects a symbolic-link destination on Unix' {
            $root = Join-Path $TestDrive 'symlink-destination'
            New-MinimalSharedReferenceRepository -Root $root
            $destinationPath = Join-Path $root $script:DestinationRelativePaths[0]
            Remove-Item -LiteralPath $destinationPath -Force
            $targetPath = Join-Path $TestDrive 'symlink-target.md'
            [IO.File]::WriteAllText($targetPath, 'target')
            New-Item -ItemType SymbolicLink -Path $destinationPath -Target $targetPath | Out-Null

            $check = Invoke-SharedReferenceSync -RepositoryRoot $root -Check
            $check.ExitCode | Should -Not -Be 0
            ($check.Stdout + $check.Stderr) | Should -Match 'reparse point'
        }

        It 'rejects a dangling symbolic-link destination in check and synchronization modes on Unix' {
            $root = Join-Path $TestDrive 'dangling-symlink-destination'
            New-MinimalSharedReferenceRepository -Root $root
            $destinationPath = Join-Path $root $script:DestinationRelativePaths[0]
            Remove-Item -LiteralPath $destinationPath -Force
            $outsideTarget = Join-Path $TestDrive 'missing-symlink-target.md'
            New-Item -ItemType SymbolicLink -Path $destinationPath -Target $outsideTarget | Out-Null

            $check = Invoke-SharedReferenceSync -RepositoryRoot $root -Check
            $sync = Invoke-SharedReferenceSync -RepositoryRoot $root

            $check.ExitCode | Should -Not -Be 0
            $sync.ExitCode | Should -Not -Be 0
            ($check.Stdout + $check.Stderr + $sync.Stdout + $sync.Stderr) | Should -Match 'reparse point'
            Test-Path -LiteralPath $outsideTarget | Should -BeFalse
        }
    }
}
