# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Shared configure API access references' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:CheckScript = Join-Path $script:RepositoryRoot 'scripts/Test-SharedReferences.ps1'
        $script:SourceRelativePath = 'docs/shared-references/configure-api-access/manual-persistence-linux-macos.md'
        $script:DestinationRelativePaths = @(
            'skills/configure-bitbucket-api-access/references/manual-persistence-linux-macos.md'
            'skills/configure-confluence-api-access/references/manual-persistence-linux-macos.md'
            'skills/configure-jira-api-access/references/manual-persistence-linux-macos.md'
        )
        $script:PwshPath = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path

        function Invoke-SharedReferenceCheck {
            param(
                [Parameter(Mandatory)][string] $RepositoryRoot,
                [Parameter()][string] $TemporaryDirectory
            )

            $scriptPath = Join-Path $RepositoryRoot 'scripts/Test-SharedReferences.ps1'
            $startInfo = [Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $script:PwshPath
            $startInfo.UseShellExecute = $false
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $scriptPath)) {
                [void]$startInfo.ArgumentList.Add($argument)
            }
            if (-not [string]::IsNullOrEmpty($TemporaryDirectory)) {
                foreach ($variableName in @('TEMP', 'TMP', 'TMPDIR')) {
                    $startInfo.Environment[$variableName] = $TemporaryDirectory
                }
            }

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
            Copy-Item -LiteralPath $script:CheckScript -Destination (Join-Path $Root 'scripts/Test-SharedReferences.ps1')
            New-Item -ItemType Directory -Path (Join-Path $Root 'config') -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'config/standard-v1.json') -Destination (Join-Path $Root 'config/standard-v1.json')
            $runtimeManifestPath = Join-Path $script:RepositoryRoot 'scripts/platform-runtime.psd1'
            $runtimeManifest = Import-PowerShellDataFile -LiteralPath $runtimeManifestPath
            foreach ($runtimeRelativePath in @($runtimeManifest.FileList)) {
                $sourceRuntimePath = Join-Path (Join-Path $script:RepositoryRoot 'scripts') $runtimeRelativePath
                $destinationRuntimePath = Join-Path (Join-Path $Root 'scripts') $runtimeRelativePath
                New-Item -ItemType Directory -Path (Split-Path -Parent $destinationRuntimePath) -Force | Out-Null
                Copy-Item -LiteralPath $sourceRuntimePath -Destination $destinationRuntimePath
            }
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

        function Get-TestFileSnapshot {
            param([Parameter(Mandatory)][string] $Root)

            $snapshot = [ordered]@{}
            foreach ($file in @(Get-ChildItem -LiteralPath $Root -File -Recurse -Force | Sort-Object FullName)) {
                $relativePath = $file.FullName.Substring($Root.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
                $snapshot[$relativePath.Replace([IO.Path]::DirectorySeparatorChar, '/')] = [Convert]::ToBase64String([IO.File]::ReadAllBytes($file.FullName))
            }
            return ($snapshot | ConvertTo-Json -Compress)
        }
    }

    It 'checks the repository copies and their SHA-256 values' {
        $result = Invoke-SharedReferenceCheck -RepositoryRoot $script:RepositoryRoot
        $result.ExitCode | Should -Be 0 -Because $result.Stderr
        $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $script:RepositoryRoot $script:SourceRelativePath)).Hash
        foreach ($relativePath in $script:DestinationRelativePaths) {
            (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $script:RepositoryRoot $relativePath)).Hash | Should -BeExactly $sourceHash
        }
    }

    It 'reports a changed destination byte and passes after the developer copies source bytes' {
        $root = Join-Path $TestDrive 'changed-byte'
        New-MinimalSharedReferenceRepository -Root $root
        $changedRelativePath = $script:DestinationRelativePaths[1]
        $changedPath = Join-Path $root $changedRelativePath
        $bytes = [IO.File]::ReadAllBytes($changedPath)
        $bytes[0] = $bytes[0] -bxor 1
        [IO.File]::WriteAllBytes($changedPath, $bytes)

        $check = Invoke-SharedReferenceCheck -RepositoryRoot $root
        $check.ExitCode | Should -Not -Be 0
        ($check.Stdout + $check.Stderr) | Should -Match ([regex]::Escape($changedRelativePath))
        ($check.Stdout + $check.Stderr) | Should -Match ('Copy the bytes of {0} to each listed copy, then rerun this check\.' -f [regex]::Escape($script:SourceRelativePath))

        $sourceBytes = [IO.File]::ReadAllBytes((Join-Path $root $script:SourceRelativePath))
        foreach ($relativePath in $script:DestinationRelativePaths) {
            [IO.File]::WriteAllBytes((Join-Path $root $relativePath), $sourceBytes)
        }
        (Invoke-SharedReferenceCheck -RepositoryRoot $root).ExitCode | Should -Be 0
    }

    It 'reports a missing destination' {
        $root = Join-Path $TestDrive 'missing-copy'
        New-MinimalSharedReferenceRepository -Root $root
        $missingRelativePath = $script:DestinationRelativePaths[0]
        Remove-Item -LiteralPath (Join-Path $root $missingRelativePath) -Force

        $check = Invoke-SharedReferenceCheck -RepositoryRoot $root
        $check.ExitCode | Should -Not -Be 0
        ($check.Stdout + $check.Stderr) | Should -Match ([regex]::Escape($missingRelativePath))
    }

    It 'reports source drift' {
        $root = Join-Path $TestDrive 'source-drift'
        New-MinimalSharedReferenceRepository -Root $root
        [IO.File]::WriteAllBytes(
            (Join-Path $root $script:SourceRelativePath),
            [Text.UTF8Encoding]::new($false).GetBytes("changed source`n")
        )

        $check = Invoke-SharedReferenceCheck -RepositoryRoot $root
        $check.ExitCode | Should -Not -Be 0
        foreach ($relativePath in $script:DestinationRelativePaths) {
            ($check.Stdout + $check.Stderr) | Should -Match ([regex]::Escape($relativePath))
        }
    }

    It 'detects CRLF as byte drift' {
        $root = Join-Path $TestDrive 'crlf-drift'
        New-MinimalSharedReferenceRepository -Root $root
        $changedRelativePath = $script:DestinationRelativePaths[2]
        [IO.File]::WriteAllBytes(
            (Join-Path $root $changedRelativePath),
            [Text.UTF8Encoding]::new($false).GetBytes("alpha`r`nbeta`r`n")
        )

        $check = Invoke-SharedReferenceCheck -RepositoryRoot $root
        $check.ExitCode | Should -Not -Be 0
        ($check.Stdout + $check.Stderr) | Should -Match ([regex]::Escape($changedRelativePath))
    }

    It 'does not change any TestDrive file or create a file outside the repository' {
        $scope = Join-Path $TestDrive 'read-only-scope'
        $root = Join-Path $scope 'repository'
        New-MinimalSharedReferenceRepository -Root $root
        $temporaryDirectory = Join-Path $scope 'process-temp'
        New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $scope 'outside.bin'), [byte[]](1, 2, 3, 4))
        $changedPath = Join-Path $root $script:DestinationRelativePaths[0]
        [IO.File]::WriteAllBytes($changedPath, [byte[]](9, 8, 7))
        $before = Get-TestFileSnapshot -Root $scope

        (Invoke-SharedReferenceCheck -RepositoryRoot $root -TemporaryDirectory $temporaryDirectory).ExitCode | Should -Not -Be 0

        $after = Get-TestFileSnapshot -Root $scope
        $after | Should -BeExactly $before
        @(Get-ChildItem -LiteralPath $temporaryDirectory -Force) | Should -HaveCount 0
    }

    It 'uses only read-only authority runtime commands for path safety' {
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:CheckScript, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors) | Should -HaveCount 0

        $forbiddenCommands = @(
            'Test-Path'
            'Get-Item'
            'Get-ChildItem'
            'New-Item'
            'Remove-Item'
            'Copy-Item'
            'Move-Item'
            'Set-Content'
            'Out-File'
            'Publish-PlatformFile'
            'Remove-PlatformOwnedFile'
            'Move-PlatformOwnedDirectory'
            'Remove-PlatformOwnedDirectoryTree'
            'New-PlatformPrivateRoot'
            'Set-PlatformPermissions'
            'Get-PlatformCapabilities'
        )
        $commandViolations = @(
            $ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -cin $forbiddenCommands
            }, $true)
        )
        $commandViolations | Should -HaveCount 0

        $localFunctionNames = @(
            $ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst]
            }, $true) | ForEach-Object { $_.Name }
        )
        $readOnlyRuntimeCommands = @(
            'Assert-PlatformFileIdentity'
            'Assert-PlatformRuntimeInventory'
            'Open-PlatformDirectory'
            'Open-PlatformFile'
        )
        $runtimeCommands = @(
            $ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -like '*-Platform*' -and
                    $node.GetCommandName() -cnotin $localFunctionNames
            }, $true) |
                ForEach-Object { $_.GetCommandName() } |
                Sort-Object -Unique
        )
        @($runtimeCommands | Where-Object { $_ -cnotin $readOnlyRuntimeCommands }) | Should -HaveCount 0
        ($runtimeCommands -join [char]10) | Should -BeExactly ($readOnlyRuntimeCommands -join [char]10)

        $forbiddenStaticMembers = @(
            'IO.File::WriteAllBytes'
            'IO.File::WriteAllText'
            'IO.File::AppendAllText'
            'IO.File::Copy'
            'IO.File::Delete'
            'IO.File::Move'
            'IO.File::Replace'
            'IO.File::Create'
            'IO.File::OpenWrite'
            'IO.Directory::CreateDirectory'
            'IO.FileInfo::new'
            'IO.DirectoryInfo::new'
        )
        $staticViolations = @(
            $ast.FindAll({
                param($node)
                if ($node -isnot [Management.Automation.Language.InvokeMemberExpressionAst] -or -not $node.Static) {
                    return $false
                }
                $typeName = if ($node.Expression -is [Management.Automation.Language.TypeExpressionAst]) {
                    [string]$node.Expression.TypeName.FullName
                }
                else { '' }
                $signature = $typeName + '::' + [string]$node.Member.Value
                return $signature -cin $forbiddenStaticMembers
            }, $true)
        )
        $staticViolations | Should -HaveCount 0

        $writeModeOpenCalls = @(
            $ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
                    $node.Static -and
                    $node.Expression -is [Management.Automation.Language.TypeExpressionAst] -and
                    [string]$node.Expression.TypeName.FullName -ceq 'IO.File' -and
                    [string]$node.Member.Value -like 'Open*' -and
                    [string]$node.Member.Value -cne 'OpenRead'
            }, $true)
        )
        $writeModeOpenCalls | Should -HaveCount 0

        $openReadCalls = @(
            $ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
                    $node.Static -and
                    $node.Expression -is [Management.Automation.Language.TypeExpressionAst] -and
                    [string]$node.Expression.TypeName.FullName -ceq 'IO.File' -and
                    [string]$node.Member.Value -ceq 'OpenRead'
            }, $true)
        )
        $openReadCalls.Count | Should -Be 2
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

            $check = Invoke-SharedReferenceCheck -RepositoryRoot $root
            $check.ExitCode | Should -Not -Be 0
            ($check.Stdout + $check.Stderr) | Should -Match 'reparse point'
        }

        It 'rejects a dangling junction on Windows' {
            $root = Join-Path $TestDrive 'dangling-junction-destination'
            New-MinimalSharedReferenceRepository -Root $root
            $destinationPath = Join-Path $root $script:DestinationRelativePaths[0]
            Remove-Item -LiteralPath $destinationPath -Force
            $outsideTarget = Join-Path $TestDrive 'removed-junction-target'
            New-Item -ItemType Directory -Path $outsideTarget | Out-Null
            New-Item -ItemType Junction -Path $destinationPath -Target $outsideTarget | Out-Null
            Remove-Item -LiteralPath $outsideTarget -Force

            $check = Invoke-SharedReferenceCheck -RepositoryRoot $root

            $check.ExitCode | Should -Not -Be 0
            ($check.Stdout + $check.Stderr) | Should -Match 'reparse point'
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

            $check = Invoke-SharedReferenceCheck -RepositoryRoot $root
            $check.ExitCode | Should -Not -Be 0
            ($check.Stdout + $check.Stderr) | Should -Match 'reparse point'
        }

        It 'rejects a dangling symbolic-link destination on Unix' {
            $root = Join-Path $TestDrive 'dangling-symlink-destination'
            New-MinimalSharedReferenceRepository -Root $root
            $destinationPath = Join-Path $root $script:DestinationRelativePaths[0]
            Remove-Item -LiteralPath $destinationPath -Force
            $outsideTarget = Join-Path $TestDrive 'missing-symlink-target.md'
            New-Item -ItemType SymbolicLink -Path $destinationPath -Target $outsideTarget | Out-Null

            $check = Invoke-SharedReferenceCheck -RepositoryRoot $root

            $check.ExitCode | Should -Not -Be 0
            ($check.Stdout + $check.Stderr) | Should -Match 'reparse point'
            Test-Path -LiteralPath $outsideTarget | Should -BeFalse
        }
    }
}
