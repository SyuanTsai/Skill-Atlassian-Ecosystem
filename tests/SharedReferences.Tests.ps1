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
        $script:ReferenceRelativePaths = @($script:SourceRelativePath) + $script:DestinationRelativePaths
        $script:PwshPath = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path
        $script:GitPath = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path

        function Resolve-TestPhysicalPath {
            param([Parameter(Mandatory)][string] $Path)

            if ($IsWindows) {
                return [IO.Path]::GetFullPath($Path)
            }
            $physical = & /bin/sh -c 'cd "$1" && pwd -P' sh $Path
            if ($LASTEXITCODE -ne 0) {
                throw ('Physical path lookup failed: {0}' -f $Path)
            }
            return ([string]$physical).Trim()
        }

        function Invoke-FixtureGit {
            param(
                [Parameter(Mandatory)][string] $Root,
                [Parameter(Mandatory)][string[]] $Arguments
            )

            $output = & $script:GitPath -C $Root @Arguments 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw ('Fixture git failed: git -C {0} {1}: {2}' -f $Root, ($Arguments -join ' '), ($output -join [char]10))
            }
            return @($output)
        }

        function Invoke-SharedReferenceCheck {
            param(
                [Parameter(Mandatory)][string] $RepositoryRoot,
                [Parameter()][AllowEmptyString()][string] $GitExecutable = '',
                [Parameter()][string] $TemporaryDirectory
            )

            $scriptPath = Join-Path $RepositoryRoot 'scripts/Test-SharedReferences.ps1'
            $startInfo = [Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $script:PwshPath
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $scriptPath)) {
                [void]$startInfo.ArgumentList.Add($argument)
            }
            if (-not [string]::IsNullOrEmpty($GitExecutable)) {
                [void]$startInfo.ArgumentList.Add('-GitExecutable')
                [void]$startInfo.ArgumentList.Add($GitExecutable)
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
                $stdoutTask = $process.StandardOutput.ReadToEndAsync()
                $stderrTask = $process.StandardError.ReadToEndAsync()
                if (-not $process.WaitForExit(60000)) {
                    $process.Kill($true)
                    throw 'Shared reference fixture check exceeded 60 seconds.'
                }
                $stdout = $stdoutTask.GetAwaiter().GetResult()
                $stderr = $stderrTask.GetAwaiter().GetResult()
                return [pscustomobject]@{
                    ExitCode = $process.ExitCode
                    Stdout = $stdout
                    Stderr = $stderr
                }
            }
            finally {
                $process.Dispose()
            }
        }

        function New-SharedReferenceGitRepository {
            param([Parameter(Mandatory)][string] $Root)

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

            $bytes = [Text.UTF8Encoding]::new($false).GetBytes("alpha`nbeta`n")
            foreach ($relativePath in $script:ReferenceRelativePaths) {
                $path = Join-Path $Root $relativePath
                New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
                [IO.File]::WriteAllBytes($path, $bytes)
            }

            $physicalRoot = Resolve-TestPhysicalPath -Path $Root
            Invoke-FixtureGit -Root $physicalRoot -Arguments @('init', '--quiet') | Out-Null
            foreach ($setting in @(
                [pscustomobject]@{ Key = 'maintenance.auto'; Value = 'false' }
                [pscustomobject]@{ Key = 'maintenance.autoDetach'; Value = 'false' }
                [pscustomobject]@{ Key = 'gc.auto'; Value = '0' }
                [pscustomobject]@{ Key = 'gc.autoDetach'; Value = 'false' }
            )) {
                Invoke-FixtureGit -Root $physicalRoot -Arguments @('config', $setting.Key, $setting.Value) | Out-Null
            }
            Invoke-FixtureGit -Root $physicalRoot -Arguments (@('add', '--') + $script:ReferenceRelativePaths) | Out-Null
            return $physicalRoot
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

    It 'passes when all four stage 0 entries have mode 100644 and the same blob' {
        $root = New-SharedReferenceGitRepository -Root (Join-Path $TestDrive 'matching-index')

        $check = Invoke-SharedReferenceCheck -RepositoryRoot $root

        $check.ExitCode | Should -Be 0 -Because $check.Stderr
    }

    It 'fails closed and names a staged destination with a different blob' {
        $root = New-SharedReferenceGitRepository -Root (Join-Path $TestDrive 'blob-drift')
        $changedRelativePath = $script:DestinationRelativePaths[1]
        [IO.File]::WriteAllText((Join-Path $root $changedRelativePath), "changed`n", [Text.UTF8Encoding]::new($false))
        Invoke-FixtureGit -Root $root -Arguments @('add', '--', $changedRelativePath) | Out-Null

        $check = Invoke-SharedReferenceCheck -RepositoryRoot $root

        $check.ExitCode | Should -Not -Be 0
        ($check.Stdout + $check.Stderr) | Should -Match ([regex]::Escape($changedRelativePath))
        ($check.Stdout + $check.Stderr) | Should -Match 'mode=100644 blob='
    }

    It 'fails closed and names a destination whose index mode is 100755' {
        $root = New-SharedReferenceGitRepository -Root (Join-Path $TestDrive 'mode-drift')
        $changedRelativePath = $script:DestinationRelativePaths[0]
        Invoke-FixtureGit -Root $root -Arguments @('update-index', '--chmod=+x', '--', $changedRelativePath) | Out-Null

        $check = Invoke-SharedReferenceCheck -RepositoryRoot $root

        $check.ExitCode | Should -Not -Be 0
        ($check.Stdout + $check.Stderr) | Should -Match ([regex]::Escape($changedRelativePath))
        ($check.Stdout + $check.Stderr) | Should -Match 'mode=100755 blob='
    }

    It 'fails closed and reports a destination that is not in the index' {
        $root = New-SharedReferenceGitRepository -Root (Join-Path $TestDrive 'missing-index-entry')
        $missingRelativePath = $script:DestinationRelativePaths[2]
        Invoke-FixtureGit -Root $root -Arguments @('rm', '--cached', '--', $missingRelativePath) | Out-Null

        $check = Invoke-SharedReferenceCheck -RepositoryRoot $root

        $check.ExitCode | Should -Not -Be 0
        ($check.Stdout + $check.Stderr) | Should -Match ([regex]::Escape($missingRelativePath))
        ($check.Stdout + $check.Stderr) | Should -Match 'not in index'
    }

    It 'fails closed and names an index entry registered as a symlink' {
        $root = New-SharedReferenceGitRepository -Root (Join-Path $TestDrive 'symlink-index-entry')
        $changedRelativePath = $script:DestinationRelativePaths[0]
        $blobOutput = @(Invoke-FixtureGit -Root $root -Arguments @('rev-parse', (':' + $script:SourceRelativePath)))
        $blob = [string]$blobOutput[0]
        Invoke-FixtureGit -Root $root -Arguments @('update-index', '--add', '--cacheinfo', ('120000,{0},{1}' -f $blob.Trim(), $changedRelativePath)) | Out-Null

        $check = Invoke-SharedReferenceCheck -RepositoryRoot $root

        $check.ExitCode | Should -Not -Be 0
        ($check.Stdout + $check.Stderr) | Should -Match ([regex]::Escape($changedRelativePath))
        ($check.Stdout + $check.Stderr) | Should -Match 'mode=120000 blob='
    }

    It 'fails closed when the requested git executable is unavailable' {
        $root = New-SharedReferenceGitRepository -Root (Join-Path $TestDrive 'missing-git')
        $missingGit = Join-Path $root 'missing-git-executable'

        $check = Invoke-SharedReferenceCheck -RepositoryRoot $root -GitExecutable $missingGit

        $check.ExitCode | Should -Not -Be 0
        ($check.Stdout + $check.Stderr) | Should -Match 'failed closed'
    }

    It 'uses the index when a destination has an unstaged working-tree modification' {
        $root = New-SharedReferenceGitRepository -Root (Join-Path $TestDrive 'unstaged-working-tree-drift')
        $changedRelativePath = $script:DestinationRelativePaths[1]
        [IO.File]::WriteAllText((Join-Path $root $changedRelativePath), "unstaged change`n", [Text.UTF8Encoding]::new($false))

        $check = Invoke-SharedReferenceCheck -RepositoryRoot $root

        $check.ExitCode | Should -Be 0 -Because $check.Stderr
    }

    It 'does not change repository bytes, the Git index, or other TestDrive files' {
        $scope = Join-Path $TestDrive 'read-only-scope'
        $root = New-SharedReferenceGitRepository -Root (Join-Path $scope 'repository')
        $temporaryDirectory = Join-Path $scope 'process-temp'
        New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $scope 'outside.bin'), [byte[]](1, 2, 3, 4))
        $before = Get-TestFileSnapshot -Root $scope

        $check = Invoke-SharedReferenceCheck -RepositoryRoot $root -TemporaryDirectory $temporaryDirectory

        $check.ExitCode | Should -Be 0 -Because $check.Stderr
        $after = Get-TestFileSnapshot -Root $scope
        $after | Should -BeExactly $before
        @(Get-ChildItem -LiteralPath $temporaryDirectory -Force) | Should -HaveCount 0
    }

    It 'keeps the checker limited to authority loading and owned read-only Git inspection' {
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
            'Start-Process'
            'Publish-PlatformFile'
            'Remove-PlatformOwnedFile'
            'Move-PlatformOwnedDirectory'
            'Remove-PlatformOwnedDirectoryTree'
            'New-PlatformPrivateRoot'
            'Set-PlatformPermissions'
            'Get-PlatformCapabilities'
            'Assert-PlatformFileIdentity'
        )
        $commandViolations = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -cin $forbiddenCommands
        }, $true))
        $commandViolations | Should -HaveCount 0

        $localFunctionNames = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst]
        }, $true) | ForEach-Object { $_.Name })
        $allowedRuntimeCommands = @(
            'Assert-PlatformRuntimeInventory'
            'Open-PlatformDirectory'
            'Open-PlatformFile'
            'Resolve-PlatformPhysicalPath'
            'Start-PlatformOwnedProcess'
            'Stop-PlatformOwnedProcess'
        )
        $runtimeCommands = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -like '*-Platform*' -and
                $node.GetCommandName() -cnotin $localFunctionNames
        }, $true) | ForEach-Object { $_.GetCommandName() } | Sort-Object -Unique)
        @($runtimeCommands | Where-Object { $_ -cnotin $allowedRuntimeCommands }) | Should -HaveCount 0
        ($runtimeCommands -join [char]10) | Should -BeExactly (($allowedRuntimeCommands | Sort-Object) -join [char]10)

        $openPlatformFileCalls = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -ceq 'Open-PlatformFile'
        }, $true))
        $openPlatformFileCalls | Should -HaveCount 1
        $openPlatformFileCalls[0].Extent.Text | Should -BeExactly 'Open-PlatformFile -ParentLease $gitExecutableDirectoryLease -Leaf ([IO.Path]::GetFileName($GitExecutablePath)) -Access Read -CreateMode OpenExisting'

        $startPlatformProcessCalls = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -ceq 'Start-PlatformOwnedProcess'
        }, $true))
        $startPlatformProcessCalls | Should -HaveCount 1
        $startPlatformProcessCalls[0].Extent.Text | Should -Match '(?<![A-Za-z])-ExecutableLease\s+\$gitExecutableLease(?![A-Za-z])'
        $startPlatformProcessCalls[0].Extent.Text | Should -Not -Match '(?<![A-Za-z])-ExecutablePath(?![A-Za-z])'

        $stopPlatformProcessCalls = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -ceq 'Stop-PlatformOwnedProcess'
        }, $true))
        $stopPlatformProcessCalls | Should -HaveCount 2
        $lastStopOffset = ($stopPlatformProcessCalls | ForEach-Object { $_.Extent.EndOffset } | Measure-Object -Maximum).Maximum
        $gitExecutableLeaseDisposeCalls = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
                -not $node.Static -and
                [string]$node.Member.Value -ceq 'Dispose' -and
                $node.Expression -is [Management.Automation.Language.VariableExpressionAst] -and
                [string]$node.Expression.VariablePath.UserPath -ceq 'gitExecutableLease'
        }, $true))
        $gitExecutableLeaseDisposeCalls | Should -HaveCount 1
        $gitExecutableLeaseDisposeCalls[0].Extent.StartOffset | Should -BeGreaterThan $lastStopOffset

        $directInvocations = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
                $node.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Ampersand
        }, $true))
        $directInvocations | Should -HaveCount 0

        $forbiddenStaticMembers = @(
            'IO.File::WriteAllBytes'
            'IO.File::WriteAllText'
            'IO.File::AppendAllText'
            'IO.File::Copy'
            'IO.File::Move'
            'IO.File::Replace'
            'IO.File::Create'
            'IO.File::OpenWrite'
            'IO.Directory::CreateDirectory'
            'IO.FileInfo::new'
            'IO.DirectoryInfo::new'
            'Diagnostics.Process::Start'
        )
        $staticCalls = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Static
        }, $true))
        $staticSignatures = @($staticCalls | ForEach-Object {
            $typeName = if ($_.Expression -is [Management.Automation.Language.TypeExpressionAst]) {
                [string]$_.Expression.TypeName.FullName
            }
            else { '' }
            $typeName + '::' + [string]$_.Member.Value
        })
        @($staticSignatures | Where-Object { $_ -cin $forbiddenStaticMembers }) | Should -HaveCount 0
        @($staticSignatures | Where-Object { $_ -ceq 'IO.File::Delete' }) | Should -HaveCount 2

        $writeModeOpenCalls = @($staticCalls | Where-Object {
            $_.Expression -is [Management.Automation.Language.TypeExpressionAst] -and
                [string]$_.Expression.TypeName.FullName -ceq 'IO.File' -and
                [string]$_.Member.Value -like 'Open*' -and
                [string]$_.Member.Value -cne 'OpenRead'
        })
        $writeModeOpenCalls | Should -HaveCount 0
        @($staticSignatures | Where-Object { $_ -ceq 'IO.File::OpenRead' }) | Should -HaveCount 2

        $expandableSubexpressions = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.ExpandableStringExpressionAst] -and
                $node.NestedExpressions.Count -gt 0
        }, $true))
        $expandableSubexpressions | Should -HaveCount 0
        (Get-Content -LiteralPath $script:CheckScript -Raw -Encoding utf8) | Should -Not -Match '`\r?\n'
    }
}
