# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Shared configure API access references' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:CheckScript = Join-Path $script:RepositoryRoot 'scripts/Test-SharedReferences.ps1'
        $script:SyncScript = Join-Path $script:RepositoryRoot 'scripts/Sync-SharedReferences.ps1'
        $script:PathMappings = @(
            [pscustomobject]@{
                Source = 'docs/shared-references/configure-api-access/manual-persistence-linux-macos.md'
                Destinations = @(
                    'skills/configure-bitbucket-api-access/references/manual-persistence-linux-macos.md'
                    'skills/configure-confluence-api-access/references/manual-persistence-linux-macos.md'
                    'skills/configure-jira-api-access/references/manual-persistence-linux-macos.md'
                )
            }
            [pscustomobject]@{
                Source = 'docs/shared-references/configure-api-access/shared-workflow.md'
                Destinations = @(
                    'skills/configure-bitbucket-api-access/references/shared-workflow.md'
                    'skills/configure-confluence-api-access/references/shared-workflow.md'
                    'skills/configure-jira-api-access/references/shared-workflow.md'
                )
            }
            [pscustomobject]@{
                Source = 'docs/shared-references/environment-separation/environment-separation.md'
                Destinations = @(
                    'skills/configure-bitbucket-api-access/references/environment-separation.md'
                    'skills/configure-confluence-api-access/references/environment-separation.md'
                    'skills/configure-jira-api-access/references/environment-separation.md'
                    'skills/manage-confluence-docs-as-code/references/environment-separation.md'
                    'skills/publish-requirements-to-confluence/references/environment-separation.md'
                    'skills/work-with-jira/references/environment-separation.md'
                )
            }
        )
        $script:SourceRelativePath = $script:PathMappings[0].Source
        $script:DestinationRelativePaths = $script:PathMappings[0].Destinations
        $script:AllDestinationRelativePaths = @($script:PathMappings | ForEach-Object { $_.Destinations })
        $script:ReferenceRelativePaths = @(
            foreach ($mapping in $script:PathMappings) {
                $mapping.Source
                $mapping.Destinations
            }
        )
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
                [Parameter()][string] $TemporaryDirectory,
                [Parameter()][string] $PathValue,
                [Parameter()][int] $CaptureDelayMilliseconds,
                [Parameter()][scriptblock] $DuringExecution
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
            if (-not [string]::IsNullOrEmpty($PathValue)) {
                $startInfo.Environment['PATH'] = $PathValue
            }
            if ($CaptureDelayMilliseconds -gt 0) {
                $startInfo.Environment['SYP_SHARED_REFERENCES_TEST_CAPTURE_DELAY_MILLISECONDS'] = [string]$CaptureDelayMilliseconds
            }

            $process = [Diagnostics.Process]::new()
            $process.StartInfo = $startInfo
            $duringResult = $null
            try {
                [void]$process.Start()
                $stdoutTask = $process.StandardOutput.ReadToEndAsync()
                $stderrTask = $process.StandardError.ReadToEndAsync()
                if ($null -ne $DuringExecution) {
                    $duringResult = & $DuringExecution
                }
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
                    DuringResult = $duringResult
                }
            }
            finally {
                if (-not $process.HasExited) {
                    $process.Kill($true)
                    [void]$process.WaitForExit(5000)
                }
                $process.Dispose()
            }
        }

        function Invoke-SharedReferenceSync {
            param([Parameter(Mandatory)][string] $RepositoryRoot)

            $startInfo = [Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $script:PwshPath
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', (Join-Path $RepositoryRoot 'scripts/Sync-SharedReferences.ps1'))) {
                [void]$startInfo.ArgumentList.Add($argument)
            }

            $process = [Diagnostics.Process]::new()
            $process.StartInfo = $startInfo
            try {
                [void]$process.Start()
                $stdoutTask = $process.StandardOutput.ReadToEndAsync()
                $stderrTask = $process.StandardError.ReadToEndAsync()
                if (-not $process.WaitForExit(60000)) {
                    $process.Kill($true)
                    throw 'Shared reference fixture sync exceeded 60 seconds.'
                }
                return [pscustomobject]@{
                    ExitCode = $process.ExitCode
                    Stdout = $stdoutTask.GetAwaiter().GetResult()
                    Stderr = $stderrTask.GetAwaiter().GetResult()
                }
            }
            finally {
                if (-not $process.HasExited) {
                    $process.Kill($true)
                    [void]$process.WaitForExit(5000)
                }
                $process.Dispose()
            }
        }

        function Wait-SharedReferenceCaptureReady {
            param([Parameter(Mandatory)][string] $TemporaryDirectory)

            $deadline = [DateTimeOffset]::UtcNow.AddSeconds(15)
            while ([DateTimeOffset]::UtcNow -lt $deadline) {
                foreach ($directory in @(Get-ChildItem -LiteralPath $TemporaryDirectory -Directory -Filter 'shared-references-*' -ErrorAction SilentlyContinue)) {
                    $readyPath = Join-Path $directory.FullName '.capture-finalization-ready'
                    if (Test-Path -LiteralPath $readyPath -PathType Leaf) {
                        return $directory.FullName
                    }
                }
                Start-Sleep -Milliseconds 25
            }
            throw 'The shared reference capture fault-injection hook was not reached.'
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

            $fixtureContents = @(
                "alpha`nbeta`n"
                "gamma`ndelta`n"
                "epsilon`nzeta`n"
            )
            for ($mappingIndex = 0; $mappingIndex -lt $script:PathMappings.Count; $mappingIndex++) {
                $bytes = [Text.UTF8Encoding]::new($false).GetBytes($fixtureContents[$mappingIndex])
                foreach ($relativePath in @($script:PathMappings[$mappingIndex].Source) + @($script:PathMappings[$mappingIndex].Destinations)) {
                    $path = Join-Path $Root $relativePath
                    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
                    [IO.File]::WriteAllBytes($path, $bytes)
                }
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

        function Install-SharedReferenceSyncScript {
            param([Parameter(Mandatory)][string] $Root)

            Copy-Item -LiteralPath $script:SyncScript -Destination (Join-Path $Root 'scripts/Sync-SharedReferences.ps1')
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

        function Set-DistinctDestinationState {
            param(
                [Parameter(Mandatory)][string] $Root,
                [Parameter(Mandatory)][string] $Prefix
            )

            $state = @{}
            for ($index = 0; $index -lt $script:DestinationRelativePaths.Count; $index++) {
                $relativePath = $script:DestinationRelativePaths[$index]
                $path = Join-Path $Root $relativePath
                [IO.File]::WriteAllText($path, ('{0}-{1}' -f $Prefix, $index), [Text.UTF8Encoding]::new($false))
                [IO.File]::SetLastWriteTimeUtc($path, [DateTime]::UtcNow.AddDays(-10 - $index))
                $state[$relativePath] = [pscustomobject]@{
                    Bytes = [IO.File]::ReadAllBytes($path)
                    LastWriteTimeUtc = [IO.File]::GetLastWriteTimeUtc($path)
                }
            }
            return $state
        }

        function Assert-DestinationStateUnchanged {
            param(
                [Parameter(Mandatory)][string] $Root,
                [Parameter(Mandatory)][hashtable] $State,
                [Parameter(Mandatory)][string[]] $RelativePaths
            )

            foreach ($relativePath in $RelativePaths) {
                $path = Join-Path $Root $relativePath
                [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) | Should -BeExactly ([Convert]::ToBase64String($State[$relativePath].Bytes))
                [IO.File]::GetLastWriteTimeUtc($path) | Should -Be $State[$relativePath].LastWriteTimeUtc
            }
        }
    }

    It 'passes when every mapped stage 0 entry has mode 100644 and matches its source blob' {
        $root = New-SharedReferenceGitRepository -Root (Join-Path $TestDrive 'matching-index')

        $check = Invoke-SharedReferenceCheck -RepositoryRoot $root

        $check.ExitCode | Should -Be 0 -Because $check.Stderr
    }

    It 'checks the shipped source and copies have identical non-empty LF bytes' {
        $files = foreach ($relativePath in $script:ReferenceRelativePaths) {
            $path = Join-Path $script:RepositoryRoot $relativePath
            [pscustomobject]@{
                RelativePath = $relativePath
                FullPath = $path
                Exists = Test-Path -LiteralPath $path -PathType Leaf
            }
        }
        $missingPaths = @($files | Where-Object { -not $_.Exists } | ForEach-Object { $_.RelativePath })
        $repairInstruction = 'Copy the bytes of the source to each listed copy, stage them, then run scripts/Test-SharedReferences.ps1'
        $missingPaths | Should -BeNullOrEmpty -Because ('Missing shared-reference paths: {0}. {1}' -f ($missingPaths -join ', '), $repairInstruction)

        $inconsistentPaths = [Collections.Generic.List[string]]::new()
        foreach ($mapping in $script:PathMappings) {
            $sourceBytes = [IO.File]::ReadAllBytes((Join-Path $script:RepositoryRoot $mapping.Source))
            foreach ($relativePath in @($mapping.Source) + @($mapping.Destinations)) {
                $bytes = [IO.File]::ReadAllBytes((Join-Path $script:RepositoryRoot $relativePath))
                $sameAsSource = $bytes.Length -eq $sourceBytes.Length
                if ($sameAsSource) {
                    for ($index = 0; $index -lt $sourceBytes.Length; $index++) {
                        if ($bytes[$index] -cne $sourceBytes[$index]) {
                            $sameAsSource = $false
                            break
                        }
                    }
                }
                $hasCarriageReturn = $false
                foreach ($byte in $bytes) {
                    if ($byte -eq 0x0D) {
                        $hasCarriageReturn = $true
                        break
                    }
                }
                if ($bytes.Length -eq 0 -or -not $sameAsSource -or $hasCarriageReturn) {
                    [void]$inconsistentPaths.Add($relativePath)
                }
            }
        }

        @($inconsistentPaths) | Should -BeNullOrEmpty -Because ('Inconsistent shared-reference paths: {0}. {1}' -f ($inconsistentPaths -join ', '), $repairInstruction)
    }

    It 'requires the private MCP-only environment to stop instead of using a token' {
        $environmentReference = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'docs/shared-references/environment-separation/environment-separation.md') -Raw
        $jiraSkill = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'skills/work-with-jira/SKILL.md') -Raw

        $environmentReference | Should -Match ([regex]::Escape('If the private environment is configured for MCP only, an MCP failure stops the operation and must not fall back to an API token or another connection.'))
        $jiraSkill | Should -Match ([regex]::Escape("If the resolved environment's required connection method fails, stop and report it; do not fall back to an API token, MCP, Rovo, or another method."))
    }

    It 'requires the work token-only environment to stop instead of using MCP' {
        $environmentReference = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'docs/shared-references/environment-separation/environment-separation.md') -Raw
        $jiraSkill = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'skills/work-with-jira/SKILL.md') -Raw

        $environmentReference | Should -Match ([regex]::Escape('If the work environment is configured for API token only, a token failure stops the operation and must not fall back to MCP or another connection.'))
        $jiraSkill | Should -Match ([regex]::Escape("If the resolved environment's required connection method fails, stop and report it; do not fall back to an API token, MCP, Rovo, or another method."))
    }

    It 'stops when environment signals conflict' {
        $environmentReference = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'docs/shared-references/environment-separation/environment-separation.md') -Raw

        $environmentReference | Should -Match 'signals indicate different environments, stop and ask'
        $environmentReference | Should -Match 'instead of choosing one'
    }

    It 'keeps real prefix to environment mappings out of Skills and shared references' {
        $roots = @(
            Join-Path $script:RepositoryRoot 'skills'
            Join-Path $script:RepositoryRoot 'docs/shared-references'
        )
        $content = @(Get-ChildItem -LiteralPath $roots -File -Recurse | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join [char]10
        $mappingPattern = '(?im)^\s*(?:[-*+]\s+)?(?:\|\s*)?["'']?(?!<)[A-Z][A-Z0-9]{1,9}-?["'']?\s*(?:\|\s*|=>|->|=|→|:)\s*["'']?(?:private|work) environment\b["'']?(?:\s*\|)?'
        $positiveExamples = @(
            '- ZZQ: work environment'
            '"ZZQ": "work environment"'
            "'ZZQ': 'private environment'"
            'ZZQ => private environment'
            'ZZQ -> work environment'
            'ZZQ = private environment'
            '| ZZQ | work environment |'
        )
        $negativeExamples = @(
            'The ZZQ work environment is documented.'
            '- Use ZZQ in the work environment.'
            'ZZQ requires work environment review.'
            '<ZZQ>: work environment'
        )

        foreach ($example in $positiveExamples) {
            $example | Should -Match $mappingPattern
        }
        foreach ($example in $negativeExamples) {
            $example | Should -Not -Match $mappingPattern
        }
        $content | Should -Not -Match $mappingPattern
    }

    It 'loads resolvable environment separation references before access in all six Skills' {
        $skillIds = @(
            'configure-bitbucket-api-access'
            'configure-confluence-api-access'
            'configure-jira-api-access'
            'manage-confluence-docs-as-code'
            'publish-requirements-to-confluence'
            'work-with-jira'
        )

        foreach ($skillId in $skillIds) {
            $skillRoot = Join-Path $script:RepositoryRoot "skills/$skillId"
            $skill = Get-Content -LiteralPath (Join-Path $skillRoot 'SKILL.md') -Raw
            $skill | Should -Match 'Before any .+ access, load \[references/environment-separation\.md\]\(references/environment-separation\.md\)'
            Test-Path -LiteralPath (Join-Path $skillRoot 'references/environment-separation.md') -PathType Leaf | Should -BeTrue
        }
    }

    It 'fails closed and names a staged destination drift in the second shared-reference group' {
        $root = New-SharedReferenceGitRepository -Root (Join-Path $TestDrive 'blob-drift')
        $changedRelativePath = $script:PathMappings[1].Destinations[1]
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

    if ($IsWindows) {
        It 'fails closed when the first PATH git candidate has multiple hard links' {
            $root = New-SharedReferenceGitRepository -Root (Join-Path $TestDrive 'hard-link-git')
            $gitDirectory = Join-Path $TestDrive 'hard-link-bin'
            New-Item -ItemType Directory -Path $gitDirectory | Out-Null
            $candidate = Join-Path $gitDirectory 'git.exe'
            Copy-Item -LiteralPath $script:GitPath -Destination $candidate
            New-Item -ItemType HardLink -Path (Join-Path $gitDirectory 'git-second-link.exe') -Target $candidate | Out-Null
            $pathValue = $gitDirectory + [IO.Path]::PathSeparator + [Environment]::GetEnvironmentVariable('PATH', [EnvironmentVariableTarget]::Process)

            $check = Invoke-SharedReferenceCheck -RepositoryRoot $root -PathValue $pathValue

            $check.ExitCode | Should -Not -Be 0
            ($check.Stdout + $check.Stderr) | Should -Match 'exactly one link'
            ($check.Stdout + $check.Stderr) | Should -Not -Match 'Git index query failed'
        }

        It 'passes the single-link gate for the first PATH git candidate copied as one link' {
            $root = New-SharedReferenceGitRepository -Root (Join-Path $TestDrive 'single-link-git')
            $gitDirectory = Join-Path $TestDrive 'single-link-bin'
            New-Item -ItemType Directory -Path $gitDirectory | Out-Null
            Copy-Item -LiteralPath $script:GitPath -Destination (Join-Path $gitDirectory 'git.exe')
            $pathValue = $gitDirectory + [IO.Path]::PathSeparator + [Environment]::GetEnvironmentVariable('PATH', [EnvironmentVariableTarget]::Process)

            $check = Invoke-SharedReferenceCheck -RepositoryRoot $root -PathValue $pathValue

            $check.ExitCode | Should -Not -Be 0
            ($check.Stdout + $check.Stderr) | Should -Not -Match 'exactly one link'
            ($check.Stdout + $check.Stderr) | Should -Match 'Git index query failed'
        }
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

    It 'retains and reports a capture directory that is not empty' {
        $root = New-SharedReferenceGitRepository -Root (Join-Path $TestDrive 'capture-extra-leaf')
        $temporaryDirectory = Join-Path $TestDrive 'capture-extra-leaf-temp'
        New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null

        $check = Invoke-SharedReferenceCheck -RepositoryRoot $root -TemporaryDirectory $temporaryDirectory -CaptureDelayMilliseconds 8000 -DuringExecution {
            $captureDirectory = Wait-SharedReferenceCaptureReady -TemporaryDirectory $temporaryDirectory
            [IO.File]::WriteAllBytes((Join-Path $captureDirectory 'unexpected'), [byte[]](1))
            Remove-Item -LiteralPath (Join-Path $captureDirectory '.capture-finalization-ready') -Force
            return $captureDirectory
        }

        $check.ExitCode | Should -Not -Be 0
        ($check.Stdout + $check.Stderr) | Should -Match 'capture directory retained'
        $check.DuringResult | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $check.DuringResult 'unexpected') -PathType Leaf | Should -BeTrue
    }

    It 'does not delete a replacement capture leaf whose identity differs' {
        $root = New-SharedReferenceGitRepository -Root (Join-Path $TestDrive 'capture-replacement')
        $temporaryDirectory = Join-Path $TestDrive 'capture-replacement-temp'
        New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null

        $check = Invoke-SharedReferenceCheck -RepositoryRoot $root -TemporaryDirectory $temporaryDirectory -CaptureDelayMilliseconds 8000 -DuringExecution {
            $captureDirectory = Wait-SharedReferenceCaptureReady -TemporaryDirectory $temporaryDirectory
            [IO.File]::Move((Join-Path $captureDirectory 'stdout'), (Join-Path $captureDirectory 'stdout-original'))
            [IO.File]::WriteAllBytes((Join-Path $captureDirectory 'stdout'), [Text.UTF8Encoding]::new($false).GetBytes('replacement'))
            Remove-Item -LiteralPath (Join-Path $captureDirectory '.capture-finalization-ready') -Force
            return $captureDirectory
        }

        $check.ExitCode | Should -Not -Be 0
        ($check.Stdout + $check.Stderr) | Should -Match 'file identity or type changed'
        $check.DuringResult | Should -Not -BeNullOrEmpty
        [IO.File]::ReadAllText((Join-Path $check.DuringResult 'stdout')) | Should -BeExactly 'replacement'
    }

    It 'syncs every changed mapped copy and passes the staged shared reference check' {
        $root = New-SharedReferenceGitRepository -Root (Join-Path $TestDrive 'sync-end-to-end')
        Install-SharedReferenceSyncScript -Root $root
        for ($index = 0; $index -lt $script:AllDestinationRelativePaths.Count; $index++) {
            [IO.File]::WriteAllText((Join-Path $root $script:AllDestinationRelativePaths[$index]), ('changed-{0}' -f $index), [Text.UTF8Encoding]::new($false))
        }

        $sync = Invoke-SharedReferenceSync -RepositoryRoot $root
        Invoke-FixtureGit -Root $root -Arguments (@('add', '--') + $script:AllDestinationRelativePaths) | Out-Null
        $check = Invoke-SharedReferenceCheck -RepositoryRoot $root

        $sync.ExitCode | Should -Be 0 -Because $sync.Stderr
        $check.ExitCode | Should -Be 0 -Because $check.Stderr
        foreach ($mapping in $script:PathMappings) {
            $sourceBytes = [IO.File]::ReadAllBytes((Join-Path $root $mapping.Source))
            foreach ($relativePath in $mapping.Destinations) {
                [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $root $relativePath))) | Should -BeExactly ([Convert]::ToBase64String($sourceBytes))
            }
        }
    }

    It 'limits Sync writes to the fixed mapped destinations and leaves every sentinel unchanged' {
        function Get-SyncWriteSnapshot {
            param(
                [Parameter(Mandatory)][string] $Root,
                [Parameter(Mandatory)][string] $OutsideSentinel
            )

            $files = [ordered]@{}
            $directories = [ordered]@{}
            $items = @(Get-ChildItem -LiteralPath $Root -Force -Recurse | Sort-Object FullName)
            foreach ($item in $items) {
                $relativePath = $item.FullName.Substring($Root.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
                $relativePath = $relativePath.Replace([IO.Path]::DirectorySeparatorChar, '/')
                if ($item.PSIsContainer) {
                    $directories[$relativePath] = $item.LastWriteTimeUtc
                    continue
                }

                $hasher = [Security.Cryptography.SHA256]::Create()
                try {
                    $hash = [BitConverter]::ToString($hasher.ComputeHash([IO.File]::ReadAllBytes($item.FullName))).Replace('-', '').ToLowerInvariant()
                }
                finally {
                    $hasher.Dispose()
                }
                $files[$relativePath] = [pscustomobject]@{
                    Hash = $hash
                    LastWriteTimeUtc = $item.LastWriteTimeUtc
                }
            }

            $rootInfo = Get-Item -LiteralPath $Root -Force
            $directories['.'] = $rootInfo.LastWriteTimeUtc
            $outsideInfo = Get-Item -LiteralPath $OutsideSentinel -Force
            $outsideHasher = [Security.Cryptography.SHA256]::Create()
            try {
                $outsideHash = [BitConverter]::ToString($outsideHasher.ComputeHash([IO.File]::ReadAllBytes($OutsideSentinel))).Replace('-', '').ToLowerInvariant()
            }
            finally {
                $outsideHasher.Dispose()
            }
            $outsideRelativePath = '../' + $outsideInfo.Name
            $files[$outsideRelativePath] = [pscustomobject]@{
                Hash = $outsideHash
                LastWriteTimeUtc = $outsideInfo.LastWriteTimeUtc
            }

            return [pscustomobject]@{
                Files = $files
                Directories = $directories
            }
        }

        $root = New-SharedReferenceGitRepository -Root (Join-Path $TestDrive 'sync-write-sentinel')
        Install-SharedReferenceSyncScript -Root $root
        for ($index = 0; $index -lt $script:AllDestinationRelativePaths.Count; $index++) {
            $destinationBytes = [Text.UTF8Encoding]::new($false).GetBytes(('changed-copy-{0}' -f $index))
            [IO.File]::WriteAllBytes((Join-Path $root $script:AllDestinationRelativePaths[$index]), $destinationBytes)
        }

        $sameDirectorySentinel = Join-Path $root 'skills/configure-jira-api-access/references/sentinel.md'
        $rootSentinel = Join-Path $root 'root-sentinel.txt'
        $outsideSentinel = Join-Path $TestDrive 'sync-write-outside-sentinel.txt'
        $gitSentinel = Join-Path $root '.git/sync-write-sentinel.bin'
        [IO.File]::WriteAllBytes($sameDirectorySentinel, [byte[]](11, 22, 33, 44))
        [IO.File]::WriteAllBytes($rootSentinel, [byte[]](55, 66, 77, 88))
        [IO.File]::WriteAllBytes($outsideSentinel, [byte[]](99, 111, 123, 135))
        [IO.File]::WriteAllBytes($gitSentinel, [byte[]](147, 159, 171, 183))

        $past = [DateTime]::SpecifyKind([DateTime]::new(2020, 1, 2, 3, 4, 5), [DateTimeKind]::Utc)
        $sentinelPaths = @(
            $sameDirectorySentinel
            $rootSentinel
            (Join-Path $root $script:SourceRelativePath)
            $outsideSentinel
            $gitSentinel
        )
        foreach ($path in @($sentinelPaths) + @($script:AllDestinationRelativePaths | ForEach-Object { Join-Path $root $_ })) {
            [IO.File]::SetLastWriteTimeUtc($path, $past)
        }
        $destinationAncestorRelativePaths = @(
            'skills'
            'skills/configure-bitbucket-api-access'
            'skills/configure-bitbucket-api-access/references'
            'skills/configure-confluence-api-access'
            'skills/configure-confluence-api-access/references'
            'skills/configure-jira-api-access'
            'skills/configure-jira-api-access/references'
        )
        foreach ($relativePath in $destinationAncestorRelativePaths) {
            [IO.Directory]::SetLastWriteTimeUtc((Join-Path $root $relativePath), $past)
        }
        $repositoryDirectories = @(Get-ChildItem -LiteralPath $root -Directory -Force -Recurse)
        foreach ($directory in $repositoryDirectories) {
            [IO.Directory]::SetLastWriteTimeUtc($directory.FullName, $past)
        }
        [IO.Directory]::SetLastWriteTimeUtc($root, $past)

        $before = Get-SyncWriteSnapshot -Root $root -OutsideSentinel $outsideSentinel
        $sync = Invoke-SharedReferenceSync -RepositoryRoot $root
        $after = Get-SyncWriteSnapshot -Root $root -OutsideSentinel $outsideSentinel

        $sync.ExitCode | Should -Be 0 -Because $sync.Stderr
        (@($after.Files.Keys) -join [char]10) | Should -BeExactly (@($before.Files.Keys) -join [char]10)
        (@($after.Directories.Keys) -join [char]10) | Should -BeExactly (@($before.Directories.Keys) -join [char]10)
        foreach ($relativePath in $before.Files.Keys) {
            if ($relativePath -cnotin $script:AllDestinationRelativePaths) {
                $after.Files[$relativePath].Hash | Should -BeExactly $before.Files[$relativePath].Hash
                $after.Files[$relativePath].LastWriteTimeUtc | Should -Be $before.Files[$relativePath].LastWriteTimeUtc
            }
        }
        foreach ($relativePath in $before.Directories.Keys) {
            $after.Directories[$relativePath] | Should -Be $before.Directories[$relativePath]
        }
        foreach ($mapping in $script:PathMappings) {
            $sourceBytes = [IO.File]::ReadAllBytes((Join-Path $root $mapping.Source))
            foreach ($relativePath in $mapping.Destinations) {
                [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $root $relativePath))) | Should -BeExactly ([Convert]::ToBase64String($sourceBytes))
            }
        }
    }

    # Register only on the native host: link construction differs between Windows and Unix.
    if ($IsWindows) {
        It 'rejects a Windows destination junction before writing any copy' {
            $root = New-SharedReferenceGitRepository -Root (Join-Path $TestDrive 'sync-windows-destination-link')
            Install-SharedReferenceSyncScript -Root $root
            $before = @{}
            for ($index = 0; $index -lt 2; $index++) {
                $relativePath = $script:DestinationRelativePaths[$index]
                $path = Join-Path $root $relativePath
                [IO.File]::WriteAllText($path, ('old-copy-{0}' -f $index), [Text.UTF8Encoding]::new($false))
                [IO.File]::SetLastWriteTimeUtc($path, [DateTime]::UtcNow.AddDays(-7 - $index))
                $before[$relativePath] = [pscustomobject]@{
                    Bytes = [IO.File]::ReadAllBytes($path)
                    LastWriteTimeUtc = [IO.File]::GetLastWriteTimeUtc($path)
                }
            }
            $outsidePath = Join-Path $TestDrive 'windows-link-target'
            $outsideBytes = [byte[]](9, 8, 7, 6)
            New-Item -ItemType Directory -Path $outsidePath | Out-Null
            $outsideSentinel = Join-Path $outsidePath 'sentinel.bin'
            [IO.File]::WriteAllBytes($outsideSentinel, $outsideBytes)
            $linkedPath = Join-Path $root $script:DestinationRelativePaths[2]
            Remove-Item -LiteralPath $linkedPath -Force
            New-Item -ItemType Junction -Path $linkedPath -Target $outsidePath -ErrorAction Stop | Out-Null

            $sync = Invoke-SharedReferenceSync -RepositoryRoot $root

            $sync.ExitCode | Should -Not -Be 0
            ($sync.Stdout + $sync.Stderr) | Should -Match 'Destination must not be a link or reparse point'
            $linkedInfo = [IO.DirectoryInfo]::new($linkedPath)
            $linkedInfo.Refresh()
            $linkedInfo.LinkTarget | Should -Not -BeNullOrEmpty
            ($linkedInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) | Should -Not -Be 0
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($outsideSentinel)) | Should -BeExactly ([Convert]::ToBase64String($outsideBytes))
            foreach ($relativePath in $script:DestinationRelativePaths[0..1]) {
                $path = Join-Path $root $relativePath
                [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) | Should -BeExactly ([Convert]::ToBase64String($before[$relativePath].Bytes))
                [IO.File]::GetLastWriteTimeUtc($path) | Should -Be $before[$relativePath].LastWriteTimeUtc
            }
        }

        It 'rejects a Windows dangling destination junction before writing any copy' {
            $root = New-SharedReferenceGitRepository -Root (Join-Path $TestDrive 'sync-windows-dangling-link')
            Install-SharedReferenceSyncScript -Root $root
            $before = @{}
            for ($index = 0; $index -lt 2; $index++) {
                $relativePath = $script:DestinationRelativePaths[$index]
                $path = Join-Path $root $relativePath
                [IO.File]::WriteAllText($path, ('old-copy-{0}' -f $index), [Text.UTF8Encoding]::new($false))
                [IO.File]::SetLastWriteTimeUtc($path, [DateTime]::UtcNow.AddDays(-7 - $index))
                $before[$relativePath] = [pscustomobject]@{
                    Bytes = [IO.File]::ReadAllBytes($path)
                    LastWriteTimeUtc = [IO.File]::GetLastWriteTimeUtc($path)
                }
            }
            $linkedPath = Join-Path $root $script:DestinationRelativePaths[2]
            $missingTarget = Join-Path $TestDrive 'missing-windows-link-target'
            New-Item -ItemType Directory -Path $missingTarget | Out-Null
            Remove-Item -LiteralPath $linkedPath -Force
            New-Item -ItemType Junction -Path $linkedPath -Target $missingTarget -ErrorAction Stop | Out-Null
            Remove-Item -LiteralPath $missingTarget -Force

            $sync = Invoke-SharedReferenceSync -RepositoryRoot $root

            $sync.ExitCode | Should -Not -Be 0
            ($sync.Stdout + $sync.Stderr) | Should -Match 'Destination must not be a link or reparse point'
            $linkedInfo = [IO.DirectoryInfo]::new($linkedPath)
            $linkedInfo.Refresh()
            $linkedInfo.LinkTarget | Should -Not -BeNullOrEmpty
            ($linkedInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) | Should -Not -Be 0
            Test-Path -LiteralPath $missingTarget | Should -BeFalse
            foreach ($relativePath in $script:DestinationRelativePaths[0..1]) {
                $path = Join-Path $root $relativePath
                [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) | Should -BeExactly ([Convert]::ToBase64String($before[$relativePath].Bytes))
                [IO.File]::GetLastWriteTimeUtc($path) | Should -Be $before[$relativePath].LastWriteTimeUtc
            }
        }
    }

    # Register only on the native host: link construction differs between Windows and Unix.
    if (-not $IsWindows) {
        It 'rejects a Unix destination symbolic link before writing any copy' {
            $root = New-SharedReferenceGitRepository -Root (Join-Path $TestDrive 'sync-unix-destination-link')
            Install-SharedReferenceSyncScript -Root $root
            $before = @{}
            for ($index = 0; $index -lt 2; $index++) {
                $relativePath = $script:DestinationRelativePaths[$index]
                $path = Join-Path $root $relativePath
                [IO.File]::WriteAllText($path, ('old-copy-{0}' -f $index), [Text.UTF8Encoding]::new($false))
                [IO.File]::SetLastWriteTimeUtc($path, [DateTime]::UtcNow.AddDays(-7 - $index))
                $before[$relativePath] = [pscustomobject]@{
                    Bytes = [IO.File]::ReadAllBytes($path)
                    LastWriteTimeUtc = [IO.File]::GetLastWriteTimeUtc($path)
                }
            }
            $outsidePath = Join-Path $TestDrive 'unix-link-target.bin'
            $outsideBytes = [byte[]](9, 8, 7, 6)
            [IO.File]::WriteAllBytes($outsidePath, $outsideBytes)
            $linkedPath = Join-Path $root $script:DestinationRelativePaths[2]
            Remove-Item -LiteralPath $linkedPath -Force
            New-Item -ItemType SymbolicLink -Path $linkedPath -Target $outsidePath -ErrorAction Stop | Out-Null

            $sync = Invoke-SharedReferenceSync -RepositoryRoot $root

            $sync.ExitCode | Should -Not -Be 0
            ($sync.Stdout + $sync.Stderr) | Should -Match 'Destination must not be a link or reparse point'
            $linkedInfo = [IO.FileInfo]::new($linkedPath)
            $linkedInfo.Refresh()
            $linkedInfo.LinkTarget | Should -Not -BeNullOrEmpty
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($outsidePath)) | Should -BeExactly ([Convert]::ToBase64String($outsideBytes))
            foreach ($relativePath in $script:DestinationRelativePaths[0..1]) {
                $path = Join-Path $root $relativePath
                [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) | Should -BeExactly ([Convert]::ToBase64String($before[$relativePath].Bytes))
                [IO.File]::GetLastWriteTimeUtc($path) | Should -Be $before[$relativePath].LastWriteTimeUtc
            }
        }

        It 'rejects a Unix dangling destination symbolic link before writing any copy' {
            $root = New-SharedReferenceGitRepository -Root (Join-Path $TestDrive 'sync-unix-dangling-link')
            Install-SharedReferenceSyncScript -Root $root
            $before = @{}
            for ($index = 0; $index -lt 2; $index++) {
                $relativePath = $script:DestinationRelativePaths[$index]
                $path = Join-Path $root $relativePath
                [IO.File]::WriteAllText($path, ('old-copy-{0}' -f $index), [Text.UTF8Encoding]::new($false))
                [IO.File]::SetLastWriteTimeUtc($path, [DateTime]::UtcNow.AddDays(-7 - $index))
                $before[$relativePath] = [pscustomobject]@{
                    Bytes = [IO.File]::ReadAllBytes($path)
                    LastWriteTimeUtc = [IO.File]::GetLastWriteTimeUtc($path)
                }
            }
            $linkedPath = Join-Path $root $script:DestinationRelativePaths[2]
            $missingTarget = Join-Path $TestDrive 'missing-unix-link-target.bin'
            Remove-Item -LiteralPath $linkedPath -Force
            New-Item -ItemType SymbolicLink -Path $linkedPath -Target $missingTarget -ErrorAction Stop | Out-Null

            $sync = Invoke-SharedReferenceSync -RepositoryRoot $root

            $sync.ExitCode | Should -Not -Be 0
            ($sync.Stdout + $sync.Stderr) | Should -Match 'Destination must not be a link or reparse point'
            $linkedInfo = [IO.FileInfo]::new($linkedPath)
            $linkedInfo.Refresh()
            $linkedInfo.LinkTarget | Should -Not -BeNullOrEmpty
            Test-Path -LiteralPath $missingTarget | Should -BeFalse
            foreach ($relativePath in $script:DestinationRelativePaths[0..1]) {
                $path = Join-Path $root $relativePath
                [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) | Should -BeExactly ([Convert]::ToBase64String($before[$relativePath].Bytes))
                [IO.File]::GetLastWriteTimeUtc($path) | Should -Be $before[$relativePath].LastWriteTimeUtc
            }
        }
    }

    It 'rejects a linked destination ancestor without creating an outside file' {
        $root = New-SharedReferenceGitRepository -Root (Join-Path $TestDrive 'sync-linked-ancestor')
        Install-SharedReferenceSyncScript -Root $root
        $before = @{}
        for ($index = 0; $index -lt 2; $index++) {
            $relativePath = $script:DestinationRelativePaths[$index]
            $path = Join-Path $root $relativePath
            [IO.File]::WriteAllText($path, ('ancestor-old-copy-{0}' -f $index), [Text.UTF8Encoding]::new($false))
            [IO.File]::SetLastWriteTimeUtc($path, [DateTime]::UtcNow.AddDays(-7 - $index))
            $before[$relativePath] = [pscustomobject]@{
                Bytes = [IO.File]::ReadAllBytes($path)
                LastWriteTimeUtc = [IO.File]::GetLastWriteTimeUtc($path)
            }
        }
        $referenceDirectory = Split-Path -Parent (Join-Path $root $script:DestinationRelativePaths[2])
        Remove-Item -LiteralPath $referenceDirectory -Recurse -Force
        $outsideDirectory = Join-Path $TestDrive 'sync-linked-ancestor-outside'
        New-Item -ItemType Directory -Path $outsideDirectory | Out-Null
        if ($IsWindows) {
            New-Item -ItemType Junction -Path $referenceDirectory -Target $outsideDirectory -ErrorAction Stop | Out-Null
        }
        else {
            New-Item -ItemType SymbolicLink -Path $referenceDirectory -Target $outsideDirectory -ErrorAction Stop | Out-Null
        }

        $sync = Invoke-SharedReferenceSync -RepositoryRoot $root

        $sync.ExitCode | Should -Not -Be 0
        ($sync.Stdout + $sync.Stderr) | Should -Match 'Destination ancestor must not be a link or reparse point'
        Test-Path -LiteralPath (Join-Path $outsideDirectory 'manual-persistence-linux-macos.md') | Should -BeFalse
        foreach ($relativePath in $script:DestinationRelativePaths[0..1]) {
            $path = Join-Path $root $relativePath
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) | Should -BeExactly ([Convert]::ToBase64String($before[$relativePath].Bytes))
            [IO.File]::GetLastWriteTimeUtc($path) | Should -Be $before[$relativePath].LastWriteTimeUtc
        }
    }

    It 'rejects a directory at the third destination before writing any copy' {
        $root = New-SharedReferenceGitRepository -Root (Join-Path $TestDrive 'sync-directory-destination')
        Install-SharedReferenceSyncScript -Root $root
        $before = Set-DistinctDestinationState -Root $root -Prefix 'directory-old-copy'
        $directoryPath = Join-Path $root $script:DestinationRelativePaths[2]
        Remove-Item -LiteralPath $directoryPath -Force
        New-Item -ItemType Directory -Path $directoryPath | Out-Null
        $directorySentinel = Join-Path $directoryPath 'sentinel.bin'
        $directoryBytes = [byte[]](17, 34, 51, 68)
        [IO.File]::WriteAllBytes($directorySentinel, $directoryBytes)
        $past = [DateTime]::UtcNow.AddDays(-20)
        [IO.File]::SetLastWriteTimeUtc($directorySentinel, $past)
        [IO.Directory]::SetLastWriteTimeUtc($directoryPath, $past)
        $directoryMtime = [IO.Directory]::GetLastWriteTimeUtc($directoryPath)
        $sentinelMtime = [IO.File]::GetLastWriteTimeUtc($directorySentinel)

        $sync = Invoke-SharedReferenceSync -RepositoryRoot $root

        $sync.ExitCode | Should -Not -Be 0
        ($sync.Stdout + $sync.Stderr) | Should -Match 'Destination must be a regular file: skills/configure-jira-api-access/references/manual-persistence-linux-macos.md'
        Assert-DestinationStateUnchanged -Root $root -State $before -RelativePaths $script:DestinationRelativePaths[0..1]
        Test-Path -LiteralPath $directoryPath -PathType Container | Should -BeTrue
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($directorySentinel)) | Should -BeExactly ([Convert]::ToBase64String($directoryBytes))
        [IO.File]::GetLastWriteTimeUtc($directorySentinel) | Should -Be $sentinelMtime
        [IO.Directory]::GetLastWriteTimeUtc($directoryPath) | Should -Be $directoryMtime
    }

    It 'rejects a missing source before writing any destination' {
        $root = New-SharedReferenceGitRepository -Root (Join-Path $TestDrive 'sync-missing-source')
        Install-SharedReferenceSyncScript -Root $root
        $before = Set-DistinctDestinationState -Root $root -Prefix 'missing-source-copy'
        Remove-Item -LiteralPath (Join-Path $root $script:SourceRelativePath) -Force

        $sync = Invoke-SharedReferenceSync -RepositoryRoot $root

        $sync.ExitCode | Should -Not -Be 0
        ($sync.Stdout + $sync.Stderr) | Should -Match 'Source does not exist: docs/shared-references/configure-api-access/manual-persistence-linux-macos.md'
        Assert-DestinationStateUnchanged -Root $root -State $before -RelativePaths $script:DestinationRelativePaths
    }

    # Register only on the native host: source link construction differs between Windows and Unix.
    if ($IsWindows) {
        It 'rejects a Windows source junction before writing any destination' {
            $root = New-SharedReferenceGitRepository -Root (Join-Path $TestDrive 'sync-windows-source-link')
            Install-SharedReferenceSyncScript -Root $root
            $before = Set-DistinctDestinationState -Root $root -Prefix 'windows-source-link-copy'
            $sourcePath = Join-Path $root $script:SourceRelativePath
            Remove-Item -LiteralPath $sourcePath -Force
            $outsideDirectory = Join-Path $TestDrive 'windows-source-link-target'
            New-Item -ItemType Directory -Path $outsideDirectory | Out-Null
            $outsideSentinel = Join-Path $outsideDirectory 'sentinel.bin'
            $outsideBytes = [byte[]](21, 42, 63, 84)
            [IO.File]::WriteAllBytes($outsideSentinel, $outsideBytes)
            New-Item -ItemType Junction -Path $sourcePath -Target $outsideDirectory -ErrorAction Stop | Out-Null

            $sync = Invoke-SharedReferenceSync -RepositoryRoot $root

            $sync.ExitCode | Should -Not -Be 0
            ($sync.Stdout + $sync.Stderr) | Should -Match 'Source must not be a link or reparse point'
            Assert-DestinationStateUnchanged -Root $root -State $before -RelativePaths $script:DestinationRelativePaths
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($outsideSentinel)) | Should -BeExactly ([Convert]::ToBase64String($outsideBytes))
        }
    }

    # Register only on the native host: source link construction differs between Windows and Unix.
    if (-not $IsWindows) {
        It 'rejects a Unix source symbolic link before writing any destination' {
            $root = New-SharedReferenceGitRepository -Root (Join-Path $TestDrive 'sync-unix-source-link')
            Install-SharedReferenceSyncScript -Root $root
            $before = Set-DistinctDestinationState -Root $root -Prefix 'unix-source-link-copy'
            $sourcePath = Join-Path $root $script:SourceRelativePath
            Remove-Item -LiteralPath $sourcePath -Force
            $outsidePath = Join-Path $TestDrive 'unix-source-link-target.bin'
            $outsideBytes = [byte[]](21, 42, 63, 84)
            [IO.File]::WriteAllBytes($outsidePath, $outsideBytes)
            New-Item -ItemType SymbolicLink -Path $sourcePath -Target $outsidePath -ErrorAction Stop | Out-Null

            $sync = Invoke-SharedReferenceSync -RepositoryRoot $root

            $sync.ExitCode | Should -Not -Be 0
            ($sync.Stdout + $sync.Stderr) | Should -Match 'Source must not be a link or reparse point'
            Assert-DestinationStateUnchanged -Root $root -State $before -RelativePaths $script:DestinationRelativePaths
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($outsidePath)) | Should -BeExactly ([Convert]::ToBase64String($outsideBytes))
        }
    }

    It 'rejects an empty source before writing any destination' {
        $root = New-SharedReferenceGitRepository -Root (Join-Path $TestDrive 'sync-empty-source')
        Install-SharedReferenceSyncScript -Root $root
        $before = Set-DistinctDestinationState -Root $root -Prefix 'empty-source-copy'
        [IO.File]::WriteAllBytes((Join-Path $root $script:SourceRelativePath), [byte[]]::new(0))

        $sync = Invoke-SharedReferenceSync -RepositoryRoot $root

        $sync.ExitCode | Should -Not -Be 0
        ($sync.Stdout + $sync.Stderr) | Should -Match 'Source is empty: docs/shared-references/configure-api-access/manual-persistence-linux-macos.md'
        Assert-DestinationStateUnchanged -Root $root -State $before -RelativePaths $script:DestinationRelativePaths
    }

    It 'leaves matching destination modification times unchanged' {
        $root = New-SharedReferenceGitRepository -Root (Join-Path $TestDrive 'sync-unchanged-mtime')
        Install-SharedReferenceSyncScript -Root $root
        $past = [DateTime]::UtcNow.AddDays(-7)
        $before = @{}
        foreach ($relativePath in $script:DestinationRelativePaths) {
            $path = Join-Path $root $relativePath
            [IO.File]::SetLastWriteTimeUtc($path, $past)
            $before[$relativePath] = [IO.File]::GetLastWriteTimeUtc($path)
        }

        $sync = Invoke-SharedReferenceSync -RepositoryRoot $root

        $sync.ExitCode | Should -Be 0 -Because $sync.Stderr
        foreach ($relativePath in $script:DestinationRelativePaths) {
            [IO.File]::GetLastWriteTimeUtc((Join-Path $root $relativePath)) | Should -Be $before[$relativePath]
        }
    }

    It 'rejects a missing destination parent without creating directories or writing other copies' {
        $root = New-SharedReferenceGitRepository -Root (Join-Path $TestDrive 'sync-missing-parent')
        Install-SharedReferenceSyncScript -Root $root
        $oldBytes = [Text.UTF8Encoding]::new($false).GetBytes('old-copy')
        foreach ($relativePath in $script:DestinationRelativePaths[0..1]) {
            [IO.File]::WriteAllBytes((Join-Path $root $relativePath), $oldBytes)
        }
        $missingParent = Split-Path -Parent (Join-Path $root $script:DestinationRelativePaths[2])
        Remove-Item -LiteralPath $missingParent -Recurse -Force

        $sync = Invoke-SharedReferenceSync -RepositoryRoot $root

        $sync.ExitCode | Should -Not -Be 0
        ($sync.Stdout + $sync.Stderr) | Should -Match 'Destination parent directory does not exist'
        Test-Path -LiteralPath $missingParent | Should -BeFalse
        foreach ($relativePath in $script:DestinationRelativePaths[0..1]) {
            [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $root $relativePath))) | Should -BeExactly ([Convert]::ToBase64String($oldBytes))
        }
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
            'Assert-PlatformFileIdentity'
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
        $openPlatformFileCalls | Should -HaveCount 4
        @($openPlatformFileCalls | Where-Object {
            $_.Extent.Text -ceq 'Open-PlatformFile -ParentLease $gitExecutableDirectoryLease -Leaf ([IO.Path]::GetFileName($GitExecutablePath)) -Access Read -CreateMode OpenExisting'
        }) | Should -HaveCount 1

        $startPlatformProcessCalls = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -ceq 'Start-PlatformOwnedProcess'
        }, $true))
        $startPlatformProcessCalls | Should -HaveCount 1
        $startPlatformProcessCalls[0].Extent.Text | Should -Match '(?<![A-Za-z])-ExecutableLease\s+\$gitExecutableLease(?![A-Za-z])'
        $startPlatformProcessCalls[0].Extent.Text | Should -Not -Match '(?<![A-Za-z])-ExecutablePath(?![A-Za-z])'
        $startOffset = $startPlatformProcessCalls[0].Extent.StartOffset

        $gitBindingResolveCalls = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -ceq 'Resolve-PlatformPhysicalPath' -and
                $node.Extent.Text -match '(?<![A-Za-z])-Path\s+\$OriginalGitExecutablePath(?![A-Za-z])'
        }, $true))
        $gitBindingResolveCalls | Should -HaveCount 1
        $gitBindingResolveCalls[0].Extent.EndOffset | Should -BeLessThan $startOffset

        $gitIdentityCalls = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -ceq 'Assert-PlatformFileIdentity' -and
                $node.Extent.Text -match '(?<![A-Za-z])-Lease\s+\$gitExecutableLease(?![A-Za-z])'
        }, $true))
        $gitIdentityCalls | Should -HaveCount 1
        $gitIdentityCalls[0].Extent.Text | Should -Match '(?<![A-Za-z])-Expected\s+\$gitExecutableLease\.Observation(?![A-Za-z])'
        $gitIdentityCalls[0].Extent.Text | Should -Match '(?<![A-Za-z])-SingleLink(?![A-Za-z])'
        $gitIdentityCalls[0].Extent.EndOffset | Should -BeLessThan $startOffset

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
        @($staticSignatures | Where-Object { $_ -ceq 'IO.Directory::Delete' }) | Should -HaveCount 1

        $deleteCalls = @($staticCalls | Where-Object {
            $signature = if ($_.Expression -is [Management.Automation.Language.TypeExpressionAst]) {
                [string]$_.Expression.TypeName.FullName + '::' + [string]$_.Member.Value
            }
            else { '' }
            $signature -in @('IO.File::Delete', 'IO.Directory::Delete')
        })
        foreach ($deleteCall in $deleteCalls) {
            $parent = $deleteCall.Parent
            while ($null -ne $parent -and $parent -isnot [Management.Automation.Language.FunctionDefinitionAst]) {
                $parent = $parent.Parent
            }
            $parent | Should -Not -BeNullOrEmpty
            $parent.Name | Should -BeExactly 'Complete-GitCaptureCleanup'
        }

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

    # AST 為輔助檢查，契約以行為測試為準（總控 2026-11-14 裁示：產生器不在路徑安全規則範圍，AST 規則不再擴充）。
    # 行為 sentinel：limits Sync writes to the fixed mapped destinations and leaves every sentinel unchanged
    It 'keeps the developer sync generator within its fixed write whitelist' {
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:SyncScript, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors) | Should -HaveCount 0

        # The 2026-11-14 controller decision exempts this developer-only generator
        # from path-safety rules, following the Build-AiInstructions byte-compare precedent.
        $allowedCommands = @(
            'Assert-DestinationPreflight'
            'Assert-SafeRelativePath'
            'Set-StrictMode'
            'Split-Path'
            'Test-ByteArrayEqual'
            'Test-FileSystemInfoLink'
            'Write-SharedReferenceCopy'
        )
        $commandViolations = @($ast.FindAll({
            param($node)
            if ($node -isnot [Management.Automation.Language.CommandAst]) { return $false }
            $commandName = $node.GetCommandName()
            return [string]::IsNullOrEmpty($commandName) -or $commandName -cnotin $allowedCommands
        }, $true))
        $commandViolations | Should -HaveCount 0

        $allowedMemberSignatures = @(
            'Console::WriteLine'
            'IO.DirectoryInfo::new'
            'IO.DirectoryNotFoundException::new'
            'IO.File::ReadAllBytes'
            'IO.FileInfo::new'
            'IO.FileNotFoundException::new'
            'IO.InvalidDataException::new'
            'IO.IOException::new'
            'IO.Path::Combine'
            'IO.Path::GetDirectoryName'
            'IO.Path::GetFullPath'
            'IO.Path::IsPathRooted'
        )
        $memberCalls = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.InvokeMemberExpressionAst]
        }, $true))
        $memberViolations = @($memberCalls | Where-Object {
            if ($_.Static -and $_.Expression -is [Management.Automation.Language.TypeExpressionAst]) {
                $typeName = [string]$_.Expression.TypeName.FullName
                if ($typeName.StartsWith('System.', [StringComparison]::OrdinalIgnoreCase)) {
                    $typeName = $typeName.Substring(7)
                }
                $signature = $typeName + '::' + [string]$_.Member.Value
                if ($signature -ceq 'IO.File::WriteAllBytes') { return $false }
                return $signature -cnotin $allowedMemberSignatures
            }
            $instanceMember = [string]$_.Member.Value
            return $instanceMember -cnotin @('Equals', 'Refresh', 'Replace', 'Split', 'StartsWith', 'TrimEnd', 'WriteLine')
        })
        $memberViolations | Should -HaveCount 0

        $writeCalls = @($memberCalls | Where-Object {
            $_.Static -and
            $_.Expression -is [Management.Automation.Language.TypeExpressionAst] -and
                ([string]$_.Expression.TypeName.FullName -replace '^System\.', '') -ceq 'IO.File' -and
                [string]$_.Member.Value -ceq 'WriteAllBytes'
        })
        $writeCalls | Should -HaveCount 1
        $writeParent = $writeCalls[0].Parent
        while ($null -ne $writeParent -and $writeParent -isnot [Management.Automation.Language.FunctionDefinitionAst]) {
            $writeParent = $writeParent.Parent
        }
        $writeParent | Should -Not -BeNullOrEmpty
        $writeParent.Name | Should -BeExactly 'Write-SharedReferenceCopy'

        $assignments = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst]
        }, $true))
        $mappingAssignments = @($assignments | Where-Object {
            $_.Left -is [Management.Automation.Language.VariableExpressionAst] -and
                [string]$_.Left.VariablePath.UserPath -match '^(?:(?:global|local|private|script):)?pathMappings$'
        })
        $mappingAssignments | Should -HaveCount 1
        $mappingExpression = $mappingAssignments[0].Right
        $mappingExpression | Should -BeOfType [Management.Automation.Language.CommandExpressionAst]
        $mappingExpression.Expression | Should -BeOfType [Management.Automation.Language.ArrayExpressionAst]
        $mappedPathValues = @($mappingExpression.FindAll({
            param($node)
            $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
                [string]$node.Value -match '^(?:docs|skills)/'
        }, $true) | ForEach-Object { [string]$_.Value })
        $expectedMappedPathValues = @(
            foreach ($mapping in $script:PathMappings) {
                $mapping.Source
                $mapping.Destinations
            }
        )
        ($mappedPathValues -join [char]10) | Should -BeExactly ($expectedMappedPathValues -join [char]10)

        if ($null -ne $ast.ParamBlock) {
            @($ast.ParamBlock.Parameters) | Should -HaveCount 0
        }
        $environmentVariables = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.VariableExpressionAst] -and
                [string]$node.VariablePath.UserPath -like 'env:*'
        }, $true))
        $environmentVariables | Should -HaveCount 0

        $expandableSubexpressions = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.ExpandableStringExpressionAst] -and
                $node.NestedExpressions.Count -gt 0
        }, $true))
        $expandableSubexpressions | Should -HaveCount 0
        (Get-Content -LiteralPath $script:SyncScript -Raw -Encoding utf8) | Should -Not -Match '`\r?\n'
    }
}
