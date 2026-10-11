# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Dormant Standard Core v2 source preparation' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:PreparationModule = Join-Path $script:RepositoryRoot 'scripts/StandardCoreSourcePreparation.psm1'
        $script:PreparationProfile = Join-Path $script:RepositoryRoot 'config/standard-core-v2-preparation.json'
        $script:GitPath = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path
        Import-Module -Name $script:PreparationModule -Force -ErrorAction Stop

        function Invoke-CoreV2TestGit {
            param([Parameter(Mandatory)][string] $RepositoryRoot, [Parameter(Mandatory)][string[]] $Arguments)
            $output = & $script:GitPath -C $RepositoryRoot @Arguments 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Git fixture command failed ($($Arguments -join ' ')): $($output -join ' ')" }
            return @($output)
        }

        function New-CoreV2ManualRawCandidate {
            param([Parameter(Mandatory)][string] $RepositoryRoot, [Parameter(Mandatory)][string] $Revision, [Parameter(Mandatory)][string] $Destination)
            [void][IO.Directory]::CreateDirectory($Destination)
            Copy-Item -LiteralPath (Join-Path $RepositoryRoot '.git') -Destination (Join-Path $Destination '.git') -Recurse
            $tree = Get-StandardCoreV2GitTree -GitPath $script:GitPath -Root $RepositoryRoot -Revision $Revision
            foreach ($relativePath in $tree.Keys) {
                $targetPath = Join-Path $Destination $relativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)
                [void][IO.Directory]::CreateDirectory((Split-Path -Parent $targetPath))
                Write-StandardCoreV2GitBlob -GitPath $script:GitPath -RepositoryRoot $RepositoryRoot `
                    -ObjectId ([string]$tree[$relativePath].objectId) -Destination $targetPath
            }
            return [pscustomobject]@{ Root = $Destination; Revision = $Revision }
        }

        function New-CoreV2GitFixture {
            param([switch] $NoClone)
            $sourceRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $ownedRoot = Join-Path $TestDrive "owned-$([guid]::NewGuid().ToString('N'))"
            $candidateRoot = Join-Path $ownedRoot 'candidate'
            New-Item -ItemType Directory -Path $sourceRoot, $ownedRoot | Out-Null
            Invoke-CoreV2TestGit -RepositoryRoot $sourceRoot -Arguments @('init', '--quiet') | Out-Null
            Invoke-CoreV2TestGit -RepositoryRoot $sourceRoot -Arguments @('config', 'user.name', 'Core v2 fixture') | Out-Null
            Invoke-CoreV2TestGit -RepositoryRoot $sourceRoot -Arguments @('config', 'user.email', 'core-v2@example.invalid') | Out-Null
            Invoke-CoreV2TestGit -RepositoryRoot $sourceRoot -Arguments @('config', 'core.filemode', 'true') | Out-Null
            Invoke-CoreV2TestGit -RepositoryRoot $sourceRoot -Arguments @('config', 'core.autocrlf', 'true') | Out-Null
            Invoke-CoreV2TestGit -RepositoryRoot $sourceRoot -Arguments @('remote', 'add', 'origin', 'https://github.com/SyuanTsai/Skill-Atlassian-Ecosystem') | Out-Null
            [IO.File]::WriteAllText((Join-Path $sourceRoot '.gitattributes'), '*.txt text' + "`n", [Text.UTF8Encoding]::new($false))
            $rawBytes = [Text.UTF8Encoding]::new($false).GetBytes("line one`nline two`n")
            [IO.File]::WriteAllBytes((Join-Path $sourceRoot 'probe.txt'), $rawBytes)
            Invoke-CoreV2TestGit -RepositoryRoot $sourceRoot -Arguments @('add', '--', '.gitattributes', 'probe.txt') | Out-Null
            Invoke-CoreV2TestGit -RepositoryRoot $sourceRoot -Arguments @('update-index', '--chmod=+x', '--', 'probe.txt') | Out-Null
            Invoke-CoreV2TestGit -RepositoryRoot $sourceRoot -Arguments @('commit', '--quiet', '-m', 'raw candidate fixture') | Out-Null
            $revisionOutput = @(Invoke-CoreV2TestGit -RepositoryRoot $sourceRoot -Arguments @('rev-parse', 'HEAD'))
            $revision = ([string]$revisionOutput[-1]).Trim()
            if ($revision -cnotmatch '^[0-9a-f]{40}$') { throw "Fixture commit did not produce a full SHA-1 revision: $($revisionOutput -join ' | ')" }
            Invoke-CoreV2TestGit -RepositoryRoot $sourceRoot -Arguments @('config', 'core.filemode', 'false') | Out-Null

            # Force a second checkout under autocrlf=true so Windows has CRLF source bytes while the blob stays LF.
            Remove-Item -LiteralPath (Join-Path $sourceRoot 'probe.txt') -Force
            Invoke-CoreV2TestGit -RepositoryRoot $sourceRoot -Arguments @('checkout', '--quiet', '--', 'probe.txt') | Out-Null
            if ($IsWindows) {
                $sourceBytes = [IO.File]::ReadAllBytes((Join-Path $sourceRoot 'probe.txt'))
                if ($sourceBytes.Length -le $rawBytes.Length) { throw 'Fixture did not exercise autocrlf=true checkout bytes.' }
            }

            if ($NoClone) {
                $clone = New-CoreV2ManualRawCandidate -RepositoryRoot $sourceRoot -Revision $revision -Destination $candidateRoot
            }
            else {
                $clone = New-StandardCoreV2RawCandidateClone -GitPath $script:GitPath -SourceRoot $sourceRoot `
                    -OwnedRoot $ownedRoot -Destination $candidateRoot -ExpectedRevision $revision
            }
            return [pscustomobject]@{ SourceRoot = $sourceRoot; OwnedRoot = $ownedRoot; CandidateRoot = $candidateRoot; Revision = $revision; Clone = $clone; RawBytes = $rawBytes }
        }

        function New-CoreV2BindingFixture {
            $fixture = New-CoreV2GitFixture
            $runId = [guid]::NewGuid().ToString('N')
            $artifactsRoot = Join-Path $TestDrive "artifacts-$runId"
            $adapterRoot = Join-Path $TestDrive ".core-v2-adapter-$runId"
            $metadataRoot = Join-Path $adapterRoot 'candidate-git'
            $snapshotRoot = Join-Path $artifactsRoot "runs/$runId/candidate"
            New-Item -ItemType Directory -Path $adapterRoot, $snapshotRoot -Force | Out-Null
            $binding = New-StandardCoreV2GitMetadataClone -GitPath $script:GitPath -RawCandidateRoot $fixture.CandidateRoot `
                -OwnedRoot $adapterRoot -Destination $metadataRoot -ExpectedRevision $fixture.Revision -RunId $runId
            return [pscustomobject]@{ Fixture = $fixture; RunId = $runId; ArtifactsRoot = $artifactsRoot; AdapterRoot = $adapterRoot; MetadataRoot = $metadataRoot; SnapshotRoot = $snapshotRoot; Binding = $binding }
        }

        function New-CoreV2ValidatorFixture {
            $sourceRoot = Join-Path $TestDrive "validator-source-$([guid]::NewGuid().ToString('N'))"
            $stagingRoot = Join-Path $TestDrive "validator-stage-$([guid]::NewGuid().ToString('N'))"
            New-Item -ItemType Directory -Path $sourceRoot, $stagingRoot | Out-Null
            foreach ($entry in @('catalog', 'config', 'skills')) {
                Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot $entry) -Destination $sourceRoot -Recurse
            }
            New-Item -ItemType Directory -Path (Join-Path $sourceRoot 'scripts') | Out-Null
            foreach ($scriptName in @('Test-Repository.ps1', 'StandardCoreSourcePreparation.psm1', 'Invoke-CoreRepositoryGeneral.ps1')) {
                Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot "scripts/$scriptName") -Destination (Join-Path $sourceRoot "scripts/$scriptName")
            }
            Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot '.gitattributes') -Destination $sourceRoot
            Invoke-CoreV2TestGit -RepositoryRoot $sourceRoot -Arguments @('init', '--quiet') | Out-Null
            Invoke-CoreV2TestGit -RepositoryRoot $sourceRoot -Arguments @('config', 'user.name', 'Core v2 validator fixture') | Out-Null
            Invoke-CoreV2TestGit -RepositoryRoot $sourceRoot -Arguments @('config', 'user.email', 'core-v2@example.invalid') | Out-Null
            Invoke-CoreV2TestGit -RepositoryRoot $sourceRoot -Arguments @('config', 'core.filemode', 'true') | Out-Null
            Invoke-CoreV2TestGit -RepositoryRoot $sourceRoot -Arguments @('config', 'core.autocrlf', 'true') | Out-Null
            Invoke-CoreV2TestGit -RepositoryRoot $sourceRoot -Arguments @('remote', 'add', 'origin', 'https://github.com/SyuanTsai/Skill-Atlassian-Ecosystem.git') | Out-Null
            Invoke-CoreV2TestGit -RepositoryRoot $sourceRoot -Arguments @('add', '--all') | Out-Null
            Invoke-CoreV2TestGit -RepositoryRoot $sourceRoot -Arguments @('commit', '--quiet', '-m', 'Core v2 repository validator fixture') | Out-Null
            Invoke-CoreV2TestGit -RepositoryRoot $sourceRoot -Arguments @('config', 'core.filemode', 'false') | Out-Null
            $revisionOutput = @(Invoke-CoreV2TestGit -RepositoryRoot $sourceRoot -Arguments @('rev-parse', 'HEAD'))
            $revision = ([string]$revisionOutput[-1]).Trim()
            $rawCandidate = New-StandardCoreV2RawCandidateClone -GitPath $script:GitPath -SourceRoot $sourceRoot `
                -OwnedRoot $stagingRoot -Destination (Join-Path $stagingRoot 'raw-candidate') -ExpectedRevision $revision

            $runId = [guid]::NewGuid().ToString('N')
            $artifactsRoot = Join-Path $TestDrive "validator-artifacts-$runId"
            $adapterRoot = Join-Path $TestDrive ".core-v2-adapter-$runId"
            $metadataRoot = Join-Path $adapterRoot 'candidate-git'
            $snapshotRoot = Join-Path $artifactsRoot "runs/$runId/candidate"
            New-Item -ItemType Directory -Path $adapterRoot, $snapshotRoot -Force | Out-Null
            $binding = New-StandardCoreV2GitMetadataClone -GitPath $script:GitPath -RawCandidateRoot $rawCandidate.Root `
                -OwnedRoot $adapterRoot -Destination $metadataRoot -ExpectedRevision $revision -RunId $runId
            foreach ($item in @(Get-ChildItem -LiteralPath $rawCandidate.Root -Recurse -Force -File)) {
                $relativePath = [IO.Path]::GetRelativePath($rawCandidate.Root, $item.FullName).Replace([IO.Path]::DirectorySeparatorChar, '/')
                if ($relativePath -ceq '.git' -or $relativePath.StartsWith('.git/', [StringComparison]::OrdinalIgnoreCase)) { continue }
                $targetPath = Join-Path $snapshotRoot $relativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)
                [void][IO.Directory]::CreateDirectory((Split-Path -Parent $targetPath))
                [IO.File]::Copy($item.FullName, $targetPath, $false)
            }
            $catalog = Get-Content -LiteralPath (Join-Path $snapshotRoot 'catalog/source.json') -Raw | ConvertFrom-Json
            $skillIds = [string[]]@($catalog.skills | ForEach-Object { [string]$_ })
            return [pscustomobject]@{ RunId = $runId; SnapshotRoot = $snapshotRoot; MetadataRoot = $metadataRoot; Binding = $binding; SkillIds = $skillIds }
        }
    }

    It 'UnitT26_Pins_the_dormant_full32_authority_profile_and_check_argument_contract' {
        # Scenario: A caller loads the dormant v2 preparation profile.
        # Purpose: Keep the exact authority tuple and digest-only check handoff closed over.
        $profile = Read-StandardCoreV2PreparationProfile -ConfigPath $script:PreparationProfile
        $profile.status | Should -Be 'dormant'
        @($profile.authority.files).Count | Should -Be 32
        @($profile.authority.files | Where-Object set -CEq 'ordinary-core').Count | Should -Be 29
        @($profile.authority.files | Where-Object set -CEq 'linked-third-party-contract').Count | Should -Be 3
        $profile.checks[0].script | Should -Be 'scripts/Invoke-CoreRepositoryGeneral.ps1'
        @($profile.checks[0].arguments) | Should -Contain '<source-binding-sha256>'
        @($profile.checks[0].arguments) | Should -Not -Contain '-CoreSnapshot'
        $profile.checks[1].script | Should -Be 'scripts/Invoke-CorePester.ps1'
        @($profile.checks[1].arguments).Count | Should -Be 0
    }

    It 'UnitT27_Parses_valid_git_tree_and_preserves_raw_blobs_and_executable_modes_under_autocrlf_true' {
        # Scenario: A clean committed fixture uses text/eol attributes and a 100755 file mode.
        # Purpose: Bind the Core candidate snapshot to raw commit bytes without refusing benign attributes.
        $fixture = New-CoreV2GitFixture
        $tree = Assert-StandardCoreV2RawCheckout -GitPath $script:GitPath -Root $fixture.CandidateRoot -Revision $fixture.Revision
        $tree['probe.txt'].mode | Should -Be '100755'
        [IO.File]::ReadAllBytes((Join-Path $fixture.CandidateRoot 'probe.txt')) | Should -Be $fixture.RawBytes
        (git -C $fixture.CandidateRoot config --get core.autocrlf).Trim() | Should -Be 'false'
    }

    It 'UnitT28_Binds_isolated_git_metadata_to_exact_run_path_revision_and_digest' {
        # Scenario: The central candidate path and source Git binding are valid, then each binding field is altered.
        # Purpose: Reject a mismatched source or metadata root while carrying only the binding digest in check args.
        $fixture = New-CoreV2BindingFixture
        $valid = Assert-StandardCoreV2SourceBinding -SnapshotRoot $fixture.SnapshotRoot -ExpectedSha256 $fixture.Binding.BindingSha256 `
            -RunId $fixture.RunId -MetadataRoot $fixture.MetadataRoot -GitPath $script:GitPath
        $valid.SourceRevision | Should -Be $fixture.Fixture.Revision
        $metadataOrigin = Invoke-StandardCoreV2GitText -GitPath $script:GitPath `
            -Arguments @('-C', $fixture.MetadataRoot, 'config', '--local', '--get-all', 'remote.origin.url') -AllowedExitCodes @(0, 1)
        @($metadataOrigin.StdOut -split "\r?\n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count | Should -Be 0
        [void](Invoke-StandardCoreV2GitText -GitPath $script:GitPath -Arguments @('-C', $fixture.MetadataRoot, 'remote', 'add', 'origin', 'https://example.invalid/should-be-rejected.git'))
        { Assert-StandardCoreV2SourceBinding -SnapshotRoot $fixture.SnapshotRoot -ExpectedSha256 $fixture.Binding.BindingSha256 `
            -RunId $fixture.RunId -MetadataRoot $fixture.MetadataRoot -GitPath $script:GitPath } | Should -Throw '*standalone object-store contract*'
        [void](Invoke-StandardCoreV2GitText -GitPath $script:GitPath -Arguments @('-C', $fixture.MetadataRoot, 'remote', 'remove', 'origin'))

        { Assert-StandardCoreV2SourceBinding -SnapshotRoot $fixture.SnapshotRoot -ExpectedSha256 ('0' * 64) `
            -RunId $fixture.RunId -MetadataRoot $fixture.MetadataRoot -GitPath $script:GitPath } | Should -Throw '*SHA-256 differs*'
        { Assert-StandardCoreV2SourceBinding -SnapshotRoot $fixture.SnapshotRoot -ExpectedSha256 $fixture.Binding.BindingSha256 `
            -RunId ('0' * 32) -MetadataRoot $fixture.MetadataRoot -GitPath $script:GitPath } | Should -Throw
        { Assert-StandardCoreV2SourceBinding -SnapshotRoot $fixture.SnapshotRoot -ExpectedSha256 $fixture.Binding.BindingSha256 `
            -RunId $fixture.RunId -MetadataRoot (Join-Path $fixture.AdapterRoot 'elsewhere') -GitPath $script:GitPath } | Should -Throw '*derived candidate-git path*'

        $bindingPath = $fixture.Binding.BindingPath
        $binding = Get-Content -LiteralPath $bindingPath -Raw | ConvertFrom-Json
        $binding.sourceRevision = '0' * 40
        [IO.File]::WriteAllText($bindingPath, ($binding | ConvertTo-Json -Compress) + "`n", [Text.UTF8Encoding]::new($false))
        $changedDigest = Get-StandardCoreV2Sha256 -Path $bindingPath
        { Assert-StandardCoreV2SourceBinding -SnapshotRoot $fixture.SnapshotRoot -ExpectedSha256 $changedDigest `
            -RunId $fixture.RunId -MetadataRoot $fixture.MetadataRoot -GitPath $script:GitPath } | Should -Throw '*standalone object-store contract*'
    }

    It 'UnitT29_Consumes_only_exact_bootstrap_signal_and_rejects_lookalike_paths_or_payloads' {
        # Scenario: The central runner leaves one exact bootstrap signal in the candidate root.
        # Purpose: Remove only the verified one-shot signal and reject adjacent lookalikes.
        $candidateRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $candidateRoot | Out-Null
        $runId = [guid]::NewGuid().ToString('N')
        $powerShell = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $signalPath = Join-Path $candidateRoot "b-$runId.sig"
        [IO.File]::WriteAllBytes($signalPath, [Text.UTF8Encoding]::new($false).GetBytes('release' + [Environment]::NewLine))
        Remove-StandardCoreConsumedBootstrapSignal -CandidateRoot $candidateRoot -ReleasePath $signalPath `
            -BootstrapCommand $powerShell -VerifiedPowerShellExecutable $powerShell
        Test-Path -LiteralPath $signalPath | Should -BeFalse

        $wrongBytes = Join-Path $candidateRoot "b-$runId.sig"
        [IO.File]::WriteAllBytes($wrongBytes, [Text.UTF8Encoding]::new($false).GetBytes('release'))
        { Remove-StandardCoreConsumedBootstrapSignal -CandidateRoot $candidateRoot -ReleasePath $wrongBytes `
            -BootstrapCommand $powerShell -VerifiedPowerShellExecutable $powerShell } | Should -Throw '*signal bytes differ*'
        Test-Path -LiteralPath $wrongBytes | Should -BeTrue

        $nestedRoot = Join-Path $candidateRoot 'nested'
        New-Item -ItemType Directory -Path $nestedRoot | Out-Null
        $nestedSignal = Join-Path $nestedRoot "b-$runId.sig"
        [IO.File]::WriteAllBytes($nestedSignal, [Text.UTF8Encoding]::new($false).GetBytes('release' + [Environment]::NewLine))
        { Remove-StandardCoreConsumedBootstrapSignal -CandidateRoot $candidateRoot -ReleasePath $nestedSignal `
            -BootstrapCommand $powerShell -VerifiedPowerShellExecutable $powerShell } | Should -Throw '*exact candidate-root transport file*'

        { Remove-StandardCoreConsumedBootstrapSignal -CandidateRoot $candidateRoot -ReleasePath $wrongBytes `
            -BootstrapCommand 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -VerifiedPowerShellExecutable $powerShell } |
            Should -Throw '*verified PowerShell executable*'
    }

    It 'UnitT30_Runs_repository_general_against_the_bound_tracked_snapshot' {
        # Scenario: The dormant general-check wrapper receives a canonical candidate snapshot, trusted run variables, and one release signal.
        # Purpose: Exercise the protected wrapper end-to-end and ensure it reports exactly the central active Skill inventory.
        $fixture = New-CoreV2ValidatorFixture
        $envNames = @('STANDARD_VALIDATION_CORE_RUN_ID', 'STANDARD_VALIDATION_CORE_CHECK_ID', 'STANDARD_VALIDATION_CORE_SKILLS',
            'STANDARD_VALIDATION_BOOTSTRAP_RELEASE_PATH', 'STANDARD_VALIDATION_BOOTSTRAP_COMMAND')
        $savedEnvironment = @{}
        foreach ($name in $envNames) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
        $signalPath = Join-Path $fixture.SnapshotRoot "b-$([guid]::NewGuid().ToString('N')).sig"
        $powerShell = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        [IO.File]::WriteAllBytes($signalPath, [Text.UTF8Encoding]::new($false).GetBytes('release' + [Environment]::NewLine))
        try {
            $env:STANDARD_VALIDATION_CORE_RUN_ID = $fixture.RunId
            $env:STANDARD_VALIDATION_CORE_CHECK_ID = 'repository-general'
            $env:STANDARD_VALIDATION_CORE_SKILLS = $fixture.SkillIds -join ';'
            $env:STANDARD_VALIDATION_BOOTSTRAP_RELEASE_PATH = $signalPath
            $env:STANDARD_VALIDATION_BOOTSTRAP_COMMAND = $powerShell
            Push-Location -LiteralPath $fixture.SnapshotRoot
            try {
                $resultText = & (Join-Path $fixture.SnapshotRoot 'scripts/Invoke-CoreRepositoryGeneral.ps1') `
                    -SourceBindingSha256 $fixture.Binding.BindingSha256
            }
            finally { Pop-Location }
            $result = ([string]$resultText | ConvertFrom-Json -Depth 30 -ErrorAction Stop)
            $result.result | Should -Be 'passed'
            [int]$result.activeSkillCount | Should -Be $fixture.SkillIds.Count
            Test-Path -LiteralPath $signalPath | Should -BeFalse
        }
        finally {
            foreach ($name in $envNames) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process') }
        }
    }

    It 'UnitT31_Binds_authority_full32_to_origin_commit_and_raw_git_blobs' {
        # Scenario: A local SHA-1 authority repository contains the exact 29+3 tuple paths and origin.
        # Purpose: Verify revision, origin, object-store, ordered tuple paths, and raw cat-file blob hashes.
        $profile = Read-StandardCoreV2PreparationProfile -ConfigPath $script:PreparationProfile
        $authorityRoot = Join-Path $TestDrive "authority-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $authorityRoot | Out-Null
        Invoke-CoreV2TestGit -RepositoryRoot $authorityRoot -Arguments @('init', '--quiet') | Out-Null
        Invoke-CoreV2TestGit -RepositoryRoot $authorityRoot -Arguments @('config', 'user.name', 'Core v2 authority fixture') | Out-Null
        Invoke-CoreV2TestGit -RepositoryRoot $authorityRoot -Arguments @('config', 'user.email', 'core-v2@example.invalid') | Out-Null
        Invoke-CoreV2TestGit -RepositoryRoot $authorityRoot -Arguments @('config', 'core.filemode', 'true') | Out-Null
        Invoke-CoreV2TestGit -RepositoryRoot $authorityRoot -Arguments @('config', 'core.autocrlf', 'false') | Out-Null
        Invoke-CoreV2TestGit -RepositoryRoot $authorityRoot -Arguments @('remote', 'add', 'origin', $profile.authority.repository) | Out-Null

        $records = [Collections.Generic.List[object]]::new()
        foreach ($entry in $profile.authority.files) {
            $relativePath = [string]$entry.path
            $fullPath = Join-Path $authorityRoot $relativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $fullPath))
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes("authority tuple fixture $relativePath`n")
            [IO.File]::WriteAllBytes($fullPath, $bytes)
            $records.Add([pscustomobject]@{
                path = $relativePath
                sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
                set = [string]$entry.set
            })
        }
        $relativePaths = [string[]]@($records | ForEach-Object { [string]$_.path })
        Invoke-CoreV2TestGit -RepositoryRoot $authorityRoot -Arguments (@('add', '--') + $relativePaths) | Out-Null
        Invoke-CoreV2TestGit -RepositoryRoot $authorityRoot -Arguments @('update-index', '--chmod=+x', '--', $relativePaths[0]) | Out-Null
        Invoke-CoreV2TestGit -RepositoryRoot $authorityRoot -Arguments @('commit', '--quiet', '-m', 'Core v2 authority tuple fixture') | Out-Null
        Invoke-CoreV2TestGit -RepositoryRoot $authorityRoot -Arguments @('config', 'core.filemode', 'false') | Out-Null
        $revisionOutput = @(Invoke-CoreV2TestGit -RepositoryRoot $authorityRoot -Arguments @('rev-parse', 'HEAD'))
        $revision = ([string]$revisionOutput[-1]).Trim()
        $fixtureProfile = [pscustomobject]@{
            authority = [pscustomobject]@{
                repository = [string]$profile.authority.repository
                commit = $revision
                archiveSha256 = [string]$profile.authority.archiveSha256
                ordinaryFileCount = 29
                linkedThirdPartyFileCount = 3
                files = @($records.ToArray())
            }
        }

        $verified = Assert-StandardCoreV2AuthorityTuple -Profile $fixtureProfile -GitPath $script:GitPath -RepositoryRoot $authorityRoot
        $verified.Commit | Should -Be $revision
        $verified.FileCount | Should -Be 32
        $verified.OrdinaryFileCount | Should -Be 29
        $verified.LinkedThirdPartyFileCount | Should -Be 3
        $sourceCheckout = Assert-StandardCoreV2AuthorityTuple -Profile $fixtureProfile -GitPath $script:GitPath `
            -RepositoryRoot $authorityRoot -RequireWorkingTree
        $sourceCheckout.Commit | Should -Be $revision

        # Exercise the same raw-LF/no-hardlink clone used by the protected driver,
        # then require the exact selected authority bytes in its checked-out tree.
        $authorityCloneOwned = Join-Path $TestDrive "authority-clone-owned-$([guid]::NewGuid().ToString('N'))"
        [void][IO.Directory]::CreateDirectory($authorityCloneOwned)
        $authorityClone = New-StandardCoreV2RawCandidateClone -GitPath $script:GitPath -SourceRoot $authorityRoot `
            -OwnedRoot $authorityCloneOwned -Destination (Join-Path $authorityCloneOwned 'authority-git') `
            -ExpectedRevision $revision -ExpectedSourceRepository ([string]$profile.authority.repository)
        $clonedAuthority = Assert-StandardCoreV2AuthorityTuple -Profile $fixtureProfile -GitPath $script:GitPath `
            -RepositoryRoot $authorityClone.Root -RequireWorkingTree
        $clonedAuthority.FileCount | Should -Be 32
        (git -C $authorityClone.Root config --get core.eol).Trim() | Should -BeExactly 'lf'

        # The authority checkout is deliberately dirty after the commit. Materialization must read raw
        # cat-file bytes from the bound commit instead of copying anything from that worktree.
        $dirtyPath = Join-Path $authorityRoot $relativePaths[0].Replace('/', [IO.Path]::DirectorySeparatorChar)
        [IO.File]::WriteAllText($dirtyPath, 'dirty authority worktree bytes', [Text.UTF8Encoding]::new($false))
        { Assert-StandardCoreV2AuthorityTuple -Profile $fixtureProfile -GitPath $script:GitPath `
            -RepositoryRoot $authorityRoot -RequireWorkingTree } | Should -Throw '*raw worktree SHA-256 differs*'
        $ownedMaterialization = Join-Path $TestDrive "authority-owned-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $ownedMaterialization | Out-Null
        $materializedRoot = Join-Path $ownedMaterialization 'authority-materialized'
        $materialized = New-StandardCoreV2AuthorityMaterialization -Profile $fixtureProfile -GitPath $script:GitPath `
            -RepositoryRoot $authorityRoot -OwnedRoot $ownedMaterialization -Destination $materializedRoot
        $materialized.FileCount | Should -Be 32
        $firstMaterialized = $materialized.Files | Where-Object path -CEq $relativePaths[0]
        $firstMaterialized.mode | Should -Be '100755'
        $firstMaterialized.sha256 | Should -Be $records[0].sha256
        $materializedFirstPath = Join-Path $materializedRoot $relativePaths[0].Replace('/', [IO.Path]::DirectorySeparatorChar)
        (Get-FileHash -LiteralPath $materializedFirstPath -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $records[0].sha256
        (Get-Content -LiteralPath $materializedFirstPath -Raw) | Should -Not -Be 'dirty authority worktree bytes'
        { New-StandardCoreV2AuthorityMaterialization -Profile $fixtureProfile -GitPath $script:GitPath `
            -RepositoryRoot $authorityRoot -OwnedRoot $ownedMaterialization -Destination (Join-Path $TestDrive 'outside-owned') } |
            Should -Throw '*child of its owned root*'

        $tamperedRecords = @($records | ForEach-Object { [pscustomobject]@{ path=$_.path; sha256=$_.sha256; set=$_.set } })
        $tamperedRecords[0].sha256 = '0' * 64
        $tamperedProfile = [pscustomobject]@{
            authority = [pscustomobject]@{
                repository = [string]$profile.authority.repository
                commit = $revision
                archiveSha256 = [string]$profile.authority.archiveSha256
                ordinaryFileCount = 29
                linkedThirdPartyFileCount = 3
                files = $tamperedRecords
            }
        }
        { Assert-StandardCoreV2AuthorityTuple -Profile $tamperedProfile -GitPath $script:GitPath -RepositoryRoot $authorityRoot } |
            Should -Throw '*raw Git blob SHA-256 differs*'
        Invoke-CoreV2TestGit -RepositoryRoot $authorityRoot -Arguments @('config', 'remote.origin.url', 'https://example.invalid/wrong.git') | Out-Null
        { Assert-StandardCoreV2AuthorityTuple -Profile $fixtureProfile -GitPath $script:GitPath -RepositoryRoot $authorityRoot } |
            Should -Throw '*origin, revision*'
    }

    It 'UnitT36_Resolves_explicit_dormant_modes_without_weakening_the_legacy_default' {
        # Scenario: The caller either leaves source selection untouched or explicitly selects one v2 mode.
        # Purpose: Keep legacy v1 as the default and reject ambiguous or partially bound v2 requests.
        $legacy = Resolve-StandardCoreV2Dispatch -BoundParameters @{}
        $legacy.Mode | Should -Be 'LegacyV1'
        $legacy.IsCoreV2 | Should -BeFalse

        $bound = @{
            PrepareSourceTools = $true
            RepositoryRoot = 'C:\candidate'
            BaseCommit = ('a' * 40)
            SourceToolsPath = 'C:\artifacts\source-tools.json'
            AuthorityRepositoryRoot = 'C:\authority'
            TrustedToolRoot = 'C:\runtime'
        }
        $setup = Resolve-StandardCoreV2Dispatch -BoundParameters $bound
        $setup.Mode | Should -Be 'PrepareSourceTools'
        $setup.IsCoreV2 | Should -BeTrue

        $bound['PrepareSourceTools'] = $false
        $bound['SourceValidation'] = $true
        (Resolve-StandardCoreV2Dispatch -BoundParameters $bound).Mode | Should -Be 'SourceValidation'

        $both = @{} + $bound
        $both['PrepareSourceTools'] = $true
        { Resolve-StandardCoreV2Dispatch -BoundParameters $both } | Should -Throw '*separate setup and execution requests*'

        $missingTrustedRoot = @{} + $bound
        $missingTrustedRoot.Remove('TrustedToolRoot')
        { Resolve-StandardCoreV2Dispatch -BoundParameters $missingTrustedRoot } | Should -Throw '*TrustedToolRoot*'

        $missingBase = @{} + $bound
        $missingBase.Remove('BaseCommit')
        { Resolve-StandardCoreV2Dispatch -BoundParameters $missingBase } | Should -Throw '*BaseCommit*'

        { Resolve-StandardCoreV2Dispatch -BoundParameters @{ OperationTimeoutSeconds = 14400 } } |
            Should -Throw '*explicit PrepareSourceTools or SourceValidation*'

        $implicitSetup = @{
            SourceToolsPath = 'C:\artifacts\source-tools.json'
            AuthorityRepositoryRoot = 'C:\authority'
            TrustedToolRoot = 'C:\runtime'
            RepositoryRoot = 'C:\candidate'
        }
        { Resolve-StandardCoreV2Dispatch -BoundParameters $implicitSetup } | Should -Throw '*explicit PrepareSourceTools or SourceValidation*'

        $validatePath = Join-Path $script:RepositoryRoot 'scripts/Validate.ps1'
        $tokens = $null; $errors = $null
        $validateAst = [System.Management.Automation.Language.Parser]::ParseFile($validatePath, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0
        $validateAst.ParamBlock.Extent.Text | Should -Match '(?s)\[int\]\s*\$TimeoutSeconds\s*=\s*900'
        $validateAst.ParamBlock.Extent.Text | Should -Match '(?s)\[ValidateRange\(1\s*,\s*14400\)\]\[int\]\s*\$OperationTimeoutSeconds\s*=\s*14400'
        $validateAst.Extent.Text | Should -Match "Join-Path\s+\(\[IO\.Path\]::GetTempPath\(\)\)\s+'standard-core-artifacts'"
        $validateAst.Extent.Text | Should -Match '\$PSBoundParameters\.ContainsKey\(''TimeoutSeconds''\)\)\s*\{\s*\$TimeoutSeconds\s*\}\s*else\s*\{\s*3600'
    }

    It 'UnitT37_Binds_the_supervised_Core_runner_to_the_isolated_raw_candidate_clone' {
        # Scenario: The live Windows checkout may have CRLF worktree bytes while the raw clone has exact Git blob bytes.
        # Purpose: Ensure the outer Core runner always snapshots the clone bound to sourceRevision.
        $liveRoot = Join-Path $TestDrive 'live-source-checkout'
        $rawRoot = Join-Path $TestDrive 'source-tools-00000000000000000000000000000001/candidate-source'
        $arguments = New-StandardCoreV2CoreRunnerArguments -LiveCandidateRoot $liveRoot -RawCandidateRoot $rawRoot `
            -RunnerPath (Join-Path $TestDrive 'authority/scripts/Invoke-StandardValidation.ps1') `
            -AdapterPath (Join-Path $TestDrive 'adapter/standard-core-adapter.json') -ArtifactsRoot (Join-Path $TestDrive 'artifacts') `
            -OutputPath (Join-Path $TestDrive 'artifacts/report.json') -SourceRepository 'https://example.invalid/source.git' `
            -SourceRevision ('a' * 40) -BaseRevision ('b' * 40) -EventName 'local' -AuthorityRevision ('c' * 40) `
            -TimeoutSeconds '900' -TrustedToolRoot (Join-Path $TestDrive 'runtime') -RunId ('0' * 32)
        $candidateIndex = [Array]::IndexOf([string[]]$arguments, '-CandidateRoot')
        $candidateIndex | Should -BeGreaterThan -1
        $arguments[$candidateIndex + 1] | Should -BeExactly ([IO.Path]::GetFullPath($rawRoot))
        $arguments[$candidateIndex + 1] | Should -Not -BeExactly ([IO.Path]::GetFullPath($liveRoot))
        { New-StandardCoreV2CoreRunnerArguments -LiveCandidateRoot $liveRoot -RawCandidateRoot $liveRoot `
            -RunnerPath 'C:\authority\runner.ps1' -AdapterPath 'C:\artifacts\adapter.json' -ArtifactsRoot 'C:\artifacts' `
            -OutputPath 'C:\artifacts\report.json' -SourceRepository 'https://example.invalid/source.git' -SourceRevision ('a' * 40) `
            -BaseRevision ('b' * 40) -EventName 'local' -AuthorityRevision ('c' * 40) -TimeoutSeconds '900' `
            -TrustedToolRoot 'C:\runtime' -RunId ('0' * 32) } | Should -Throw '*isolated raw candidate clone*'
    }

    It 'UnitT38_All_supervised_source_process_calls_bind_the_trusted_runtime_root' {
        # Scenario: Each tool setup/install and full Core invocation uses the central owned-process lifecycle.
        # Purpose: Prevent a missing TrustedToolRoot binding or a child-scope root substitution.
        $driverPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-ProtectedSourceValidation.ps1'
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($driverPath,[ref]$tokens,[ref]$errors)
        $errors.Count | Should -Be 0
        $calls = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -ceq 'Invoke-StandardCoreSupervisedProcess' },$true))
        $calls.Count | Should -Be 3
        foreach($call in $calls){
            $parameters=@($call.CommandElements | ForEach-Object { [string]$_.Extent.Text })
            $parameters | Should -Contain '-TrustedToolRoot'
        }
        $supervisor=$ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Invoke-StandardCoreSupervisedProcess' },$true) | Select-Object -First 1
        $supervisor.Body.Extent.Text | Should -Match '\$RunId\s+\$TrustedToolRoot\s+\$PowerShell'
        $supervisor.Body.Extent.Text | Should -Match 'STANDARD_VALIDATION_RUN_OWNED_ROOT\s*=\s*\$Owned'
        $supervisor.Body.Extent.Text | Should -Not -Match '@\{\s*RUN_OWNED_ROOT\s*='
    }

    It 'UnitT39_Allows_only_the_receipted_external_Node_runtime_for_skill_tools' {
        # Scenario: The resolver stores skill-tools under its actual generated run-owned child, but Node is an approved external runtime.
        # Purpose: Preserve the authority runner's Node-outside-candidate-and-artifacts contract while hashing every launcher component.
        $candidateRoot=Join-Path $TestDrive 'candidate'; $artifactsRoot=Join-Path $TestDrive 'artifacts'
        $runId=[guid]::NewGuid().ToString('N'); $installParent=Join-Path $TestDrive "install-parent-$runId"
        $installRoot=Join-Path $installParent "skill-tools-$([guid]::NewGuid().ToString('N'))"
        $runtimeRoot=Join-Path $TestDrive 'runtime'; $packageRoot=Join-Path $installRoot 'node_modules/skill-tools'
        New-Item -ItemType Directory -Path $candidateRoot,$artifactsRoot,$runtimeRoot,$installParent,$packageRoot -Force | Out-Null
        $shim=Join-Path $installRoot 'node_modules/.bin/skill-tools.cmd'
        $entry=Join-Path $packageRoot 'bin/skill-tools.js'; $node=Join-Path $runtimeRoot 'node.exe'
        New-Item -ItemType Directory -Path (Split-Path -Parent $shim),(Split-Path -Parent $entry) -Force | Out-Null
        [IO.File]::WriteAllText($shim,'@echo off',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($entry,'console.log("fixture")',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($node,'fixture node',[Text.UTF8Encoding]::new($false))
        $shimHash=(Get-FileHash -LiteralPath $shim -Algorithm SHA256).Hash.ToLowerInvariant()
        $entryHash=(Get-FileHash -LiteralPath $entry -Algorithm SHA256).Hash.ToLowerInvariant()
        $nodeHash=(Get-FileHash -LiteralPath $node -Algorithm SHA256).Hash.ToLowerInvariant()
        $receipt=[pscustomobject]@{
            schemaVersion=1; resolutionRunId=$runId; frozenForRun=$true; installedClosureSha256=('a' * 64)
            toolName='skill-tools'; installRoot=$installRoot; executablePath=$shim; executableSha256=$shimHash
            entryPointPath=$entry; entryPointSha256=$entryHash; nodePath=$node; nodeSha256=$nodeHash
            launcher=[pscustomobject]@{kind='windows-cmd-shim';runtimePath=$node;runtimeSha256=$nodeHash;payloadPath=$entry;payloadSha256=$entryHash}
        }
        (Assert-StandardCoreV2ResolverReceiptPaths -Receipt $receipt -ExpectedInstallParent $installParent -ExpectedRunId $runId -CandidateRoot $candidateRoot -ArtifactsRoot $artifactsRoot).toolName |
            Should -BeExactly 'skill-tools'
        $invalidNode=Join-Path $artifactsRoot 'node.exe'; [IO.File]::WriteAllText($invalidNode,'fixture node',[Text.UTF8Encoding]::new($false))
        $badRuntime=$receipt.PSObject.Copy(); $badRuntime.nodePath=$invalidNode; $badRuntime.launcher.runtimePath=$invalidNode
        { Assert-StandardCoreV2ResolverReceiptPaths -Receipt $badRuntime -ExpectedInstallParent $installParent -ExpectedRunId $runId -CandidateRoot $candidateRoot -ArtifactsRoot $artifactsRoot } |
            Should -Throw '*outside candidate and ArtifactsRoot*'
        $invalidEntry=Join-Path $artifactsRoot 'outside.js'; [IO.File]::WriteAllText($invalidEntry,'fixture payload',[Text.UTF8Encoding]::new($false))
        $badPayload=$receipt.PSObject.Copy(); $badPayload.entryPointPath=$invalidEntry; $badPayload.launcher.payloadPath=$invalidEntry
        { Assert-StandardCoreV2ResolverReceiptPaths -Receipt $badPayload -ExpectedInstallParent $installParent -ExpectedRunId $runId -CandidateRoot $candidateRoot -ArtifactsRoot $artifactsRoot } |
            Should -Throw '*payload escaped its exact install root*'
        $badRun=$receipt.PSObject.Copy(); $badRun.resolutionRunId='0' * 32
        { Assert-StandardCoreV2ResolverReceiptPaths -Receipt $badRun -ExpectedInstallParent $installParent -ExpectedRunId $runId -CandidateRoot $candidateRoot -ArtifactsRoot $artifactsRoot } |
            Should -Throw '*current run or complete installed closure*'
        $badLeaf=$receipt.PSObject.Copy(); $badLeaf.installRoot=Join-Path $installParent 'skill-tools'
        { Assert-StandardCoreV2ResolverReceiptPaths -Receipt $badLeaf -ExpectedInstallParent $installParent -ExpectedRunId $runId -CandidateRoot $candidateRoot -ArtifactsRoot $artifactsRoot } |
            Should -Throw '*direct run-owned tool child*'
    }

    It 'UnitT40_Proves_short_temp_install_headroom_against_deep_artifact_path' {
        # Scenario: The exact Python wheel probe path is compared under a unique short temp parent and the former artifact-root parent.
        # Purpose: Keep the authority's 248-character Windows limit unchanged while proving the shortened path fits.
        $runId=[guid]::NewGuid().ToString('N')
        $deepInstallParent=Join-Path (Join-Path $TestDrive "source-tools-$runId") 'installed'
        $tempNames=@('TEMP','TMP','TMPDIR')
        $savedTempValues=@{}
        foreach($name in $tempNames){ $savedTempValues[$name]=[Environment]::GetEnvironmentVariable($name,'Process') }
        $shortTempRoot=$null
        $shortTempCreated=$false
        $isWindowsPlatform=[Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
        $shortTempAnchor=if($isWindowsPlatform){
            $localAppData=[Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
            if([string]::IsNullOrWhiteSpace($localAppData)){ throw 'Windows did not provide a LocalApplicationData folder for the temp-path fixture.' }
            Join-Path $localAppData 'Temp'
        } else { '/tmp' }
        $shortTempLeaf="tmp-$($runId.Substring(0,12))"
        try {
            if(-not [IO.Directory]::Exists($shortTempAnchor)){
                throw "The scoped headroom temp root is unavailable: $shortTempAnchor"
            }
            $shortTempAnchor=[IO.Path]::GetFullPath($shortTempAnchor)
            $shortTempRoot=Join-Path $shortTempAnchor $shortTempLeaf
            $expectedInstallParent=Join-Path $shortTempRoot "corev2-$runId"
            $probeLeaf='ss-000000000000'
            $probeSuffix=Join-Path 'venv/Lib/site-packages' (('p' * 96)+'.probe')
            # Preflight the exact production probe as strings before creating any temp directory or calling the helper.
            $expectedProbePath=[IO.Path]::GetFullPath((Join-Path (Join-Path $expectedInstallParent $probeLeaf) $probeSuffix))
            $expectedProbePath.Length | Should -BeLessThan 248 -Because 'the fixed 248-character authority limit is checked before the helper can reject a long path'
            [IO.Directory]::Exists($shortTempRoot) | Should -BeFalse -Because 'the full-GUID temp directory must be newly owned by this scenario'
            [void][IO.Directory]::CreateDirectory($shortTempRoot)
            $shortTempCreated=$true
            foreach($name in $tempNames){ [Environment]::SetEnvironmentVariable($name,$shortTempRoot,'Process') }

            $installParent=Get-StandardCoreV2ToolInstallParent -RunId $runId
            $installParent | Should -BeExactly $expectedInstallParent
            [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) |
                Should -BeExactly ([IO.Path]::GetFullPath($shortTempRoot).TrimEnd([IO.Path]::DirectorySeparatorChar))
            $proof=Get-StandardCoreV2SkillSpectorPathHeadroom -InstallParent $installParent -DeepArtifactsInstallParent $deepInstallParent
            $proof.currentProbePath | Should -BeExactly $expectedProbePath
            $proof.currentProbeLength | Should -Be $expectedProbePath.Length
            $proof.currentProbeLength | Should -BeLessThan 248
            $proof.currentHeadroom | Should -BeGreaterThan 0
            $proof.deepArtifactsProbeLength | Should -BeGreaterThan $proof.currentProbeLength
            $proof.deepArtifactsProbePath | Should -Match 'source-tools-[0-9a-f]{32}.*site-packages'
        }
        finally {
            foreach($name in $tempNames){ [Environment]::SetEnvironmentVariable($name,$savedTempValues[$name],'Process') }
            if($shortTempCreated -and $null -ne $shortTempRoot -and [IO.Directory]::Exists($shortTempRoot)){
                $ownedPath=[IO.Path]::GetFullPath($shortTempRoot)
                $ownedDirectory=Get-Item -LiteralPath $ownedPath -Force
                if($ownedDirectory.Attributes -band [IO.FileAttributes]::ReparsePoint){
                    throw 'The unique headroom temp directory became a reparse point; cleanup stopped without traversing it.'
                }
                $ownedParentPath=[IO.Path]::GetFullPath($ownedDirectory.Parent.FullName).TrimEnd([IO.Path]::DirectorySeparatorChar)
                $expectedParentPath=[IO.Path]::GetFullPath($shortTempAnchor).TrimEnd([IO.Path]::DirectorySeparatorChar)
                if($ownedDirectory.Name -cne $shortTempLeaf -or $ownedParentPath -cne $expectedParentPath){
                    throw 'The headroom temp cleanup target no longer matches its unique run-owned directory name.'
                }
                [IO.Directory]::Delete($ownedPath,$true)
            }
        }
    }

    It 'UnitT58_Creates_a_deterministic_source_bound_archive_with_create_new_semantics' {
        # Scenario: The adapter needs the exact candidate archive identity from the isolated metadata repository.
        # Purpose: Bind archive bytes to the verified revision and prevent archive output replacement.
        $fixture = New-CoreV2BindingFixture
        $firstPath = Join-Path $fixture.AdapterRoot 'source-archive.tar'
        $secondPath = Join-Path $fixture.AdapterRoot 'source-archive-repeat.tar'
        $first = New-StandardCoreV2GitArchive -GitPath $script:GitPath -RepositoryRoot $fixture.MetadataRoot `
            -OwnedRoot $fixture.AdapterRoot -Destination $firstPath -Revision $fixture.Fixture.Revision
        $first.path | Should -BeExactly ([IO.Path]::GetFullPath($firstPath))
        $first.revision | Should -BeExactly $fixture.Fixture.Revision
        $first.length | Should -BeGreaterThan 0
        $first.sha256 | Should -Match '^[0-9a-f]{64}$'
        (Get-StandardCoreV2Sha256 -Path $firstPath) | Should -BeExactly $first.sha256

        $second = New-StandardCoreV2GitArchive -GitPath $script:GitPath -RepositoryRoot $fixture.MetadataRoot `
            -OwnedRoot $fixture.AdapterRoot -Destination $secondPath -Revision $fixture.Fixture.Revision
        $second.sha256 | Should -BeExactly $first.sha256
        [IO.File]::ReadAllBytes($secondPath) | Should -Be ([IO.File]::ReadAllBytes($firstPath))
        { New-StandardCoreV2GitArchive -GitPath $script:GitPath -RepositoryRoot $fixture.MetadataRoot `
            -OwnedRoot $fixture.AdapterRoot -Destination $firstPath -Revision $fixture.Fixture.Revision } | Should -Throw '*CreateNew*'
        { New-StandardCoreV2GitArchive -GitPath $script:GitPath -RepositoryRoot $fixture.MetadataRoot `
            -OwnedRoot $fixture.AdapterRoot -Destination (Join-Path $fixture.AdapterRoot 'wrong-revision.tar') -Revision ('0' * 40) } |
            Should -Throw '*HEAD differs*'
    }

    It 'UnitT59_Validates_complete_upstream_adapter_report_and_archive_identity' {
        # Scenario: A frozen adapter reports detected surfaces or a complete not-applicable evaluation.
        # Purpose: Bind full report shape, component inventory, candidate identity, surfaces, and archive digest to source.
        $root=Join-Path $TestDrive ('adapter-report-'+[guid]::NewGuid().ToString('N'))
        $manifest=Join-Path $root '.codex-plugin/plugin.json'
        $bundledSkillFile=Join-Path $root 'skills/fixture-skill/SKILL.md'
        New-Item -ItemType Directory -Path (Split-Path -Parent $manifest),(Split-Path -Parent $bundledSkillFile) -Force | Out-Null
        [IO.File]::WriteAllText($manifest,'{"name":"fixture"}',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($bundledSkillFile,'fixture skill',[Text.UTF8Encoding]::new($false))
        $componentRows=[Collections.Generic.List[object]]::new()
        foreach($relative in @('.codex-plugin/plugin.json','skills/fixture-skill/SKILL.md')){
            $componentPath=Join-Path $root $relative.Replace('/',[IO.Path]::DirectorySeparatorChar)
            $componentRows.Add([pscustomobject][ordered]@{path=$relative;sha256=(Get-StandardCoreV2Sha256 -Path $componentPath)})
        }
        $inventory=[object[]]$componentRows.ToArray()
        $inventoryCanonical=([string[]]@($inventory|ForEach-Object{"$($_.path)`t$($_.sha256)`n"}) -join '')
        $packageHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($inventoryCanonical))).ToLowerInvariant()
        $repository='https://github.com/SyuanTsai/Skill-Atlassian-Ecosystem.git'; $revision='a'*40; $archiveSha='b'*64
        $identity=[pscustomobject][ordered]@{sourceRepository=$repository;sourceRevision=$revision;archiveSha256=$archiveSha;packageSha256=$packageHash}
        $report=[pscustomobject][ordered]@{
            schemaVersion=1;policy='upstream-interoperability-adapter-v1';adapterVersion='upstream-interoperability-adapter-v1'
            status='passed';packageRoot=$root;surfaces=[object[]]@('plugin','mcp')
            bundledSkills=[object[]]@([pscustomobject][ordered]@{path='./skills/fixture-skill';inventory=[object[]]@('SKILL.md')})
            candidateIdentity=$identity;componentInventory=$inventory;componentInventorySha256=$packageHash;decision='PASS'
        }
        $valid=Assert-StandardCoreV2UpstreamAdapterReport -Report $report -ExpectedPackageRoot $root `
            -ExpectedSourceRepository $repository -ExpectedSourceRevision $revision -ExpectedArchiveSha256 $archiveSha
        $valid.status | Should -BeExactly 'passed'
        @($valid.surfaces) | Should -Be @('plugin','mcp')
        $valid.bundledSkills[0].path | Should -BeExactly './skills/fixture-skill'

        $na=[pscustomobject][ordered]@{
            schemaVersion=1;policy='upstream-interoperability-adapter-v1';adapterVersion='upstream-interoperability-adapter-v1'
            status='not-applicable';packageRoot=$root;surfaces=[object[]]@();bundledSkills=[object[]]@()
            candidateIdentity=$null;componentInventory=[object[]]@();componentInventorySha256=''
            decision='NOT_APPLICABLE'
        }
        # The empty inventory digest is SHA-256 of the empty canonical UTF-8 sequence.
        $na.componentInventorySha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]@())).ToLowerInvariant()
        (Assert-StandardCoreV2UpstreamAdapterReport -Report $na -ExpectedPackageRoot $root `
            -ExpectedSourceRepository $repository -ExpectedSourceRevision $revision -ExpectedArchiveSha256 $archiveSha).status | Should -BeExactly 'not-applicable'

        $wrongArchive=$report.PSObject.Copy(); $wrongArchive.candidateIdentity=$identity.PSObject.Copy(); $wrongArchive.candidateIdentity.archiveSha256='c'*64
        { Assert-StandardCoreV2UpstreamAdapterReport -Report $wrongArchive -ExpectedPackageRoot $root `
            -ExpectedSourceRepository $repository -ExpectedSourceRevision $revision -ExpectedArchiveSha256 $archiveSha } | Should -Throw '*candidate identity*'
        $wrongSurface=$report.PSObject.Copy(); $wrongSurface.surfaces=[object[]]@('unknown')
        { Assert-StandardCoreV2UpstreamAdapterReport -Report $wrongSurface -ExpectedPackageRoot $root `
            -ExpectedSourceRepository $repository -ExpectedSourceRevision $revision -ExpectedArchiveSha256 $archiveSha } | Should -Throw '*surface*'
        $wrongHash=$report.PSObject.Copy()
        $wrongHash.componentInventory=[object[]]@($inventory | ForEach-Object {
            [pscustomobject][ordered]@{path=[string]$_.path;sha256=[string]$_.sha256}
        })
        $wrongHash.componentInventory[0].sha256='c'*64
        { Assert-StandardCoreV2UpstreamAdapterReport -Report $wrongHash -ExpectedPackageRoot $root `
            -ExpectedSourceRepository $repository -ExpectedSourceRevision $revision -ExpectedArchiveSha256 $archiveSha } | Should -Throw '*component changed*'

        $missingSkillResource=$report.PSObject.Copy(); $missingSkillResource.bundledSkills=$report.bundledSkills.Clone()
        $missingSkillResource.bundledSkills[0]=$report.bundledSkills[0].PSObject.Copy()
        $missingSkillResource.bundledSkills[0].inventory=[object[]]@('missing.txt')
        { Assert-StandardCoreV2UpstreamAdapterReport -Report $missingSkillResource -ExpectedPackageRoot $root `
            -ExpectedSourceRepository $repository -ExpectedSourceRevision $revision -ExpectedArchiveSha256 $archiveSha } |
            Should -Throw '*resource is absent*'
    }

    It 'UnitT60_Executes_the_frozen_upstream_adapter_and_preserves_its_actual_result' {
        # Scenario: The protected package adapter invokes a frozen upstream validator and captures its raw report.
        # Purpose: Preserve a successful NOT_APPLICABLE evaluation without projecting it as an upstream PASS, and reject malformed, mismatched, blocked, or nonzero reports.
        if (-not $IsWindows) { Set-ItResult -Skipped -Because 'The controlled adapter fixture exercises the Windows process boundary.'; return }
        $fixture=New-CoreV2ValidatorFixture
        $runRoot=Split-Path -Parent $fixture.SnapshotRoot
        $artifactsRoot=Split-Path -Parent (Split-Path -Parent $runRoot)
        $setupRoot=Join-Path $artifactsRoot "source-tools-$($fixture.RunId)"
        $childRoot=Join-Path $runRoot ('source-children/'+[guid]::NewGuid().ToString('N'))
        $adapterRoot=Split-Path -Parent $fixture.MetadataRoot
        $authorityRoot=Join-Path $adapterRoot 'authority-git'
        $validatorPath=Join-Path $authorityRoot 'scripts/Validate-UpstreamAdapter.ps1'
        $policyPath=Join-Path $authorityRoot 'docs/standards/upstream-adapter.json'
        New-Item -ItemType Directory -Path $setupRoot,(Split-Path -Parent $validatorPath),(Split-Path -Parent $policyPath),$childRoot -Force | Out-Null
        $sourceProfile=Get-Content -LiteralPath (Join-Path $fixture.SnapshotRoot 'config/standard-core-v2-preparation.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $archivePath=Join-Path $setupRoot "source-archive-$($fixture.RunId).tar"
        $archive=New-StandardCoreV2GitArchive -GitPath $script:GitPath -RepositoryRoot $fixture.Binding.Root -OwnedRoot $setupRoot `
            -Destination $archivePath -Revision $fixture.Binding.Revision
        [IO.File]::WriteAllText($policyPath,'{}',[Text.UTF8Encoding]::new($false))
        $fakeAdapter=@'
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackageRoot,[Parameter(Mandatory)][string]$PolicyPath,[Parameter(Mandatory)][string]$SourceRepository,
    [Parameter(Mandatory)][string]$SourceRevision,[Parameter(Mandatory)][string]$ArchiveSha256,[Parameter(Mandatory)][string]$OutputPath)
$ErrorActionPreference='Stop'
$mode=[string]$env:SYP304_ADAPTER_FIXTURE_MODE
if($mode -ceq 'blocked'){throw 'BLOCK: adapter fixture blocked'}
if($mode -ceq 'nonzero'){[Console]::Error.WriteLine('adapter fixture nonzero');exit 7}
$empty=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]@())).ToLowerInvariant()
$status='not-applicable';$surfaces=[object[]]@();$identity=$null;$decision='NOT_APPLICABLE'
if($mode -ceq 'wrong-archive'){
    $status='passed';$surfaces=[object[]]@('plugin');$decision='PASS'
    $identity=[ordered]@{sourceRepository=$SourceRepository;sourceRevision=$SourceRevision;archiveSha256=('0'*64);packageSha256=$empty}
}
$report=[ordered]@{schemaVersion=1;policy='upstream-interoperability-adapter-v1';adapterVersion='upstream-interoperability-adapter-v1';status=$status;
    packageRoot=[IO.Path]::GetFullPath($PackageRoot);surfaces=$surfaces;bundledSkills=[object[]]@();candidateIdentity=$identity;
    componentInventory=[object[]]@();componentInventorySha256=$empty;decision=$decision}
if($mode -ceq 'malformed'){[void]$report.Remove('decision')}
$json=ConvertTo-Json -InputObject $report -Depth 20
$bytes=[Text.UTF8Encoding]::new($false).GetBytes($json)
$stream=[IO.File]::Open($OutputPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
Write-Output $json
'@
        [IO.File]::WriteAllText($validatorPath,$fakeAdapter,[Text.UTF8Encoding]::new($false))
        $runtime=[IO.Path]::GetFullPath([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
        $toolchain=[ordered]@{
            sourceRepository=[string]$sourceProfile.source.repository;sourceRevision=[string]$fixture.Binding.Revision;sourceBindingSha256=[string]$fixture.Binding.BindingSha256
            sourceArchivePath=[string]$archive.path;sourceArchiveSha256=[string]$archive.sha256;sourceArchiveLength=[long]$archive.length
            upstreamAdapterValidatorPath=[IO.Path]::GetFullPath($validatorPath);upstreamAdapterValidatorSha256=(Get-StandardCoreV2Sha256 -Path $validatorPath)
            upstreamPolicyPath=[IO.Path]::GetFullPath($policyPath);upstreamPolicySha256=(Get-StandardCoreV2Sha256 -Path $policyPath)
            runtimeExecutable=$runtime;runtimeSha256=(Get-StandardCoreV2Sha256 -Path $runtime)
        }
        $toolchainPath=Join-Path $setupRoot 'toolchain.json'
        [IO.File]::WriteAllText($toolchainPath,(ConvertTo-Json -InputObject $toolchain -Depth 20 -Compress),[Text.UTF8Encoding]::new($false))
        $toolchainSha=Get-StandardCoreV2Sha256 -Path $toolchainPath
        $wrapper=Join-Path $script:RepositoryRoot 'scripts/Invoke-CoreSourceTool.ps1'
        $invokeFixture={
            param([string]$Mode)
            $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$runtime;$info.WorkingDirectory=$childRoot;$info.UseShellExecute=$false
            $info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
            foreach($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',$wrapper,'-Mode','package-adapter','-ToolchainPath',$toolchainPath,'-ToolchainSha256',$toolchainSha)){
                [void]$info.ArgumentList.Add([string]$argument)
            }
            $info.Environment['STANDARD_VALIDATION_CANDIDATE_ROOT']=[IO.Path]::GetFullPath($fixture.SnapshotRoot)
            $info.Environment['STANDARD_VALIDATION_CANDIDATE_ID']='fixture-candidate'
            $info.Environment['STANDARD_VALIDATION_ACTIVE_SKILLS']=($fixture.SkillIds -join ';')
            $info.Environment['SYP304_ADAPTER_FIXTURE_MODE']=$Mode
            $process=[Diagnostics.Process]::new();$process.StartInfo=$info
            try{
                if(-not $process.Start()){throw 'Could not start package adapter fixture.'}
                $stdoutTask=$process.StandardOutput.ReadToEndAsync();$stderrTask=$process.StandardError.ReadToEndAsync()
                if(-not $process.WaitForExit(90000)){$process.Kill($true);[void]$process.WaitForExit(5000);throw 'Package adapter fixture exceeded its 90-second bound.'}
                return [pscustomobject]@{exitCode=[int]$process.ExitCode;stdout=$stdoutTask.GetAwaiter().GetResult();stderr=$stderrTask.GetAwaiter().GetResult()}
            }finally{$process.Dispose()}
        }.GetNewClosure()

        $valid=& $invokeFixture 'not-applicable'
        $valid.exitCode | Should -Be 0
        $envelope=(@($valid.stdout -split "\r?\n" | Where-Object {-not [string]::IsNullOrWhiteSpace($_)})[-1]) | ConvertFrom-Json -Depth 80
        $envelope.domainAdapterResult.status | Should -BeExactly 'passed'
        $envelope.domainAdapterResult.decision | Should -BeExactly 'PASS'
        $envelope.domainAdapterResult.upstreamReport.status | Should -BeExactly 'not-applicable'
        $envelope.domainAdapterResult.upstreamReport.decision | Should -BeExactly 'NOT_APPLICABLE'
        $envelope.domainAdapterResult.upstreamExitCode | Should -Be 0
        (Get-StandardCoreV2Sha256 -Path $envelope.domainAdapterResult.upstreamReportPath) | Should -BeExactly $envelope.domainAdapterResult.upstreamReportSha256
        $runPrefix=[IO.Path]::GetFullPath($runRoot).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
        ([IO.Path]::GetFullPath($envelope.domainAdapterResult.upstreamReportPath).StartsWith($runPrefix,[StringComparison]::OrdinalIgnoreCase)) | Should -BeTrue

        foreach($scenario in @('malformed','wrong-archive','blocked','nonzero')){
            $rejected=& $invokeFixture $scenario
            $rejected.exitCode | Should -Not -Be 0 -Because "The package adapter must reject the $scenario fixture."
        }
    }

    It 'UnitT43_Accepts_only_the_pinned_live_source_origin_with_or_without_git_suffix' {
        # Scenario: A GitHub checkout action reports the pinned repository URL without a terminal .git suffix.
        # Purpose: Accept the two exact approved HTTPS forms while keeping the owned raw clone origin canonical.
        $fixture = New-CoreV2GitFixture
        $fixture.Clone.Origin | Should -BeExactly 'https://github.com/SyuanTsai/Skill-Atlassian-Ecosystem.git'
        $clonedOrigin = (Invoke-StandardCoreV2GitText -GitPath $script:GitPath -Arguments @('-C',$fixture.CandidateRoot,'config','--local','--get-all','remote.origin.url')).StdOut.Trim()
        $clonedOrigin | Should -BeExactly 'https://github.com/SyuanTsai/Skill-Atlassian-Ecosystem.git'

        Invoke-CoreV2TestGit -RepositoryRoot $fixture.SourceRoot -Arguments @('config','remote.origin.url','https://github.com/SyuanTsai/Skill-Atlassian-Ecosystem.git') | Out-Null
        $withSuffix = New-StandardCoreV2RawCandidateClone -GitPath $script:GitPath -SourceRoot $fixture.SourceRoot `
            -OwnedRoot $fixture.OwnedRoot -Destination (Join-Path $fixture.OwnedRoot ('suffix-' + [guid]::NewGuid().ToString('N'))) `
            -ExpectedRevision $fixture.Revision
        $withSuffix.Origin | Should -BeExactly 'https://github.com/SyuanTsai/Skill-Atlassian-Ecosystem.git'

        foreach ($wrongOrigin in @(
            'https://evil.example/SyuanTsai/Skill-Atlassian-Ecosystem',
            'https://github.com/SomeOtherOwner/Skill-Atlassian-Ecosystem'
        )) {
            Invoke-CoreV2TestGit -RepositoryRoot $fixture.SourceRoot -Arguments @('config','remote.origin.url',$wrongOrigin) | Out-Null
            $destination = Join-Path $fixture.OwnedRoot ('rejected-' + [guid]::NewGuid().ToString('N'))
            { New-StandardCoreV2RawCandidateClone -GitPath $script:GitPath -SourceRoot $fixture.SourceRoot `
                -OwnedRoot $fixture.OwnedRoot -Destination $destination -ExpectedRevision $fixture.Revision } |
                Should -Throw '*exact approved source repository*'
        }
    }

    It 'UnitT41_Validates_native_skill_validator_reports_in_a_fresh_source_tool_process' {
        # Scenario: A fresh trusted wrapper consumes a controlled native JSON fixture for clean, warning, and wrong-root reports.
        # Purpose: Protect report scope/severity checks and verify raw native stdout/stderr evidence survives rejection; this is not a native-tool gate.
        $root=Join-Path ([IO.Path]::GetTempPath()) ('s304-t41-'+[guid]::NewGuid().ToString('N'))
        $candidateRoot=Join-Path $root 'candidate'; $skillsRoot=Join-Path $candidateRoot 'skills'; $skillId='fixture-skill'
        $skillRoot=Join-Path $skillsRoot $skillId
        New-Item -ItemType Directory -Path $skillRoot -Force | Out-Null
        try {
        [IO.File]::WriteAllText((Join-Path $skillRoot 'SKILL.md'),'fixture',[Text.UTF8Encoding]::new($false))
        $wrapper=Join-Path $script:RepositoryRoot 'scripts/Invoke-CoreSourceTool.ps1'
        $runtime=[IO.Path]::GetFullPath([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
        $runnerSource=@'
param([switch]$DefineFunctionsOnly,[string]$CandidateRoot,[string]$AdapterPath,[string]$ArtifactsRoot,[string]$SourceRepository,[string]$SourceRevision,[string]$BaseRevision)
Set-StrictMode -Version Latest
function Get-StandardValidationFullPath([string]$Path) { [IO.Path]::GetFullPath($Path) }
function Get-StandardValidationCaseVariant([string]$Path) { $Path }
function Get-StandardValidationPathCaseBehavior([string]$Path) { 'case-sensitive' }
function Get-StandardValidationPathComparison { [StringComparison]::OrdinalIgnoreCase }
function Test-StandardValidationSameResolvedPath([string]$Left,[string]$Right) { [IO.Path]::GetFullPath($Left).Equals([IO.Path]::GetFullPath($Right),[StringComparison]::OrdinalIgnoreCase) }
function Assert-StandardValidationSkillValidatorReport {
    param([Parameter(Mandatory)]$Report,[Parameter(Mandatory)][string]$SkillRoot,[Parameter(Mandatory)][string]$SkillId)
    if (-not (Test-StandardValidationSameResolvedPath -Left ([string]$Report.skill_dir) -Right $SkillRoot)) { throw "skill-validator reported the wrong skill root for '$SkillId'." }
    if ($Report.passed -isnot [bool] -or -not $Report.passed -or [int]$Report.errors -ne 0 -or [int]$Report.warnings -ne 0) { throw "skill-validator reported warning or error findings for '$SkillId'." }
    return @($Report.results)
}
'@
        $runnerPath=Join-Path $root 'central-runner-fixture.ps1'
        [IO.File]::WriteAllText($runnerPath,$runnerSource,[Text.UTF8Encoding]::new($false))
        $rows=[Collections.Generic.List[object]]::new()
        foreach($scenario in @('clean-pass','warning','wrong-root','native-nonzero')) {
            $scenarioRoot=Join-Path $root $scenario; New-Item -ItemType Directory -Path $scenarioRoot | Out-Null
            $reportedRoot=if($scenario -eq 'wrong-root'){Join-Path $root 'different-skill'}else{$skillRoot}
            $native=[ordered]@{skill_dir=$reportedRoot;passed=($scenario -ne 'warning');errors=0;warnings=$(if($scenario -eq 'warning'){1}else{0});results=@([ordered]@{level=$(if($scenario -eq 'warning'){'warn'}else{'pass'});file='SKILL.md';message='focused fixture'})}
            $fixtureJson=Join-Path $scenarioRoot 'native-fixture.json'
            [IO.File]::WriteAllText($fixtureJson,($native|ConvertTo-Json -Depth 8 -Compress),[Text.UTF8Encoding]::new($false))
            $fixtureScript=Join-Path $scenarioRoot 'native-fixture.ps1'
            $fixtureSource=@'
param()
$expected=@('-o','json','validate','structure','--allow-dirs=agents')
if($args.Count -ne 6 -or ($args[0..4] -join "`n") -cne ($expected -join "`n") -or
   [string]$args[5] -cne [Environment]::GetEnvironmentVariable('SYP304_FIXTURE_SKILL_ROOT','Process')){exit 87}
$path=[Environment]::GetEnvironmentVariable('SYP304_FIXTURE_REPORT_PATH','Process')
$raw=[Environment]::GetEnvironmentVariable('SYP304_FIXTURE_RAW_STDERR','Process')
$code=0
if([string]::IsNullOrWhiteSpace($path) -or -not [int]::TryParse([Environment]::GetEnvironmentVariable('SYP304_FIXTURE_EXIT_CODE','Process'),[ref]$code)){exit 88}
[Console]::Out.Write([IO.File]::ReadAllText($path))
[Console]::Error.Write($raw)
exit $code
'@
            [IO.File]::WriteAllText($fixtureScript,$fixtureSource,[Text.UTF8Encoding]::new($false))
            $toolchain=[ordered]@{
                centralRunnerPath=$runnerPath;centralRunnerSha256=(Get-StandardCoreV2Sha256 -Path $runnerPath)
                sourceRepository='https://github.com/SyuanTsai/Skill-Atlassian-Ecosystem.git';sourceRevision=('a'*40)
                runtimeExecutable=$runtime;runtimeSha256=(Get-StandardCoreV2Sha256 -Path $runtime)
                skillValidatorPath=$runtime;skillValidatorSha256=(Get-StandardCoreV2Sha256 -Path $runtime)
                skillValidatorLauncherArguments=@('-NoProfile','-NonInteractive','-File',$fixtureScript)
                skillValidatorScriptSha256=(Get-StandardCoreV2Sha256 -Path $fixtureScript)
            }
            $toolchainPath=Join-Path $scenarioRoot 'toolchain.json'
            [IO.File]::WriteAllText($toolchainPath,($toolchain|ConvertTo-Json -Depth 8 -Compress),[Text.UTF8Encoding]::new($false))
            $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$runtime;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
            $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.WorkingDirectory=$scenarioRoot
            $start.Environment.Clear()
            foreach($name in @('SystemRoot','WINDIR','PATH','PATHEXT','TEMP','TMP','TMPDIR','USERPROFILE','COMSPEC','ProgramFiles','ProgramFiles(x86)','ProgramW6432')) {
                $value=[Environment]::GetEnvironmentVariable($name);if(-not [string]::IsNullOrWhiteSpace($value)){$start.Environment[$name]=$value}
            }
            $start.Environment['STANDARD_VALIDATION_CANDIDATE_ROOT']=$candidateRoot
            $start.Environment['STANDARD_VALIDATION_CANDIDATE_ID']='focused-candidate'
            $start.Environment['STANDARD_VALIDATION_ACTIVE_SKILLS']=$skillId
            $start.Environment['STANDARD_VALIDATION_SKILLS_ROOT']=$skillsRoot
            $start.Environment['STANDARD_VALIDATION_SKILL_ID']=$skillId
            $start.Environment['STANDARD_VALIDATION_SKILL_INVENTORY_SHA256']='b'*64
            $start.Environment['SYP304_FIXTURE_SKILL_ROOT']=$skillRoot
            $start.Environment['SYP304_FIXTURE_REPORT_PATH']=$fixtureJson
            $start.Environment['SYP304_FIXTURE_EXIT_CODE']=if($scenario -eq 'native-nonzero'){'1'}else{'0'}
            $start.Environment['SYP304_FIXTURE_RAW_STDERR']='fixture native stderr '+$scenario
            foreach($argument in @('-NoProfile','-NonInteractive','-File',$wrapper,'-Mode','skill-validator','-ToolchainPath',$toolchainPath,'-ToolchainSha256',(Get-StandardCoreV2Sha256 -Path $toolchainPath))){[void]$start.ArgumentList.Add($argument)}
            $process=[Diagnostics.Process]::new();$process.StartInfo=$start
            try {
                $process.Start() | Should -BeTrue
                $stdoutTask=$process.StandardOutput.ReadToEndAsync();$stderrTask=$process.StandardError.ReadToEndAsync()
                if(-not $process.WaitForExit(90000)){$process.Kill($true);$process.WaitForExit();throw 'Fresh source-tool fixture timed out.'}
                $stdout=$stdoutTask.GetAwaiter().GetResult();$stderr=$stderrTask.GetAwaiter().GetResult()
                $expectedExit=if($scenario -eq 'clean-pass'){0}else{1}
                $process.ExitCode | Should -Be $expectedExit -Because "scenario=$scenario stdout=$stdout stderr=$stderr"
                $rawStdout=@(Get-ChildItem -LiteralPath $scenarioRoot -Filter 'native-raw-skill-validator-*.stdout.bin' -File)
                $rawStderr=@(Get-ChildItem -LiteralPath $scenarioRoot -Filter 'native-raw-skill-validator-*.stderr.bin' -File)
                $rawStdout.Count | Should -Be 1; $rawStderr.Count | Should -Be 1
                ([Text.UTF8Encoding]::new($false,$true).GetString([IO.File]::ReadAllBytes($rawStdout[0].FullName))).Trim() |
                    Should -BeExactly ([IO.File]::ReadAllText($fixtureJson,[Text.UTF8Encoding]::new($false)))
                [Text.UTF8Encoding]::new($false,$true).GetString([IO.File]::ReadAllBytes($rawStderr[0].FullName)) |
                    Should -BeExactly ('fixture native stderr '+$scenario)
                if($scenario -eq 'clean-pass') {
                    $envelope=$stdout.Trim()|ConvertFrom-Json -Depth 60
                    $envelope.status | Should -BeExactly 'passed'
                    @($envelope.nativeReports).Count | Should -Be 1
                    $envelope.skillId | Should -BeExactly $skillId
                } else {
                    [string]::IsNullOrWhiteSpace($stdout) | Should -BeTrue
                    $stderr | Should -Match 'skill-validator'
                }
                $rows.Add([pscustomobject]@{scenario=$scenario;childProcessId=$process.Id;exitCode=$process.ExitCode;expectedExitCode=$expectedExit;stdoutPath=$rawStdout[0].FullName;stderrPath=$rawStderr[0].FullName})
            } finally { $process.Dispose() }
        }
        $rows.Count | Should -Be 4
        } finally {
            $resolvedRoot=[IO.Path]::GetFullPath($root)
            $resolvedTemp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
            $rootName=[IO.Path]::GetFileName($resolvedRoot)
            if ($rootName.StartsWith('s304-t41-', [StringComparison]::Ordinal) -and
                $resolvedRoot.StartsWith($resolvedTemp + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and
                (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
                Remove-Item -LiteralPath $resolvedRoot -Recurse -Force -ErrorAction Stop
            }
        }
    }

    It 'UnitT42_Enforces_an_aggregate_timeout_and_cleans_up_serial_child_processes' {
        # Scenario: The repository-vendored supervisor runs two serial children under a shorter aggregate wall-clock deadline.
        # Purpose: Prove the aggregate deadline terminates the serial process tree; UnitT44 separately verifies per-child budget enforcement.
        if (-not $IsWindows) { Set-ItResult -Skipped -Because 'The supervisor lifecycle fixture uses the Windows job-object boundary.'; return }
        $runnerPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-StandardValidation.ps1'
        $root = Join-Path $TestDrive ('supervisor-env-' + [guid]::NewGuid().ToString('N'))
        $candidateRoot = Join-Path $root 'candidate'; $artifactsRoot = Join-Path $root 'artifacts'
        $workingRoot = Join-Path $root 'working'; $trustedRoot = Join-Path $root 'runtime'
        New-Item -ItemType Directory -Path $candidateRoot,$artifactsRoot,$workingRoot,$trustedRoot | Out-Null
        $childPath = Join-Path $workingRoot 'verify-owned-root.ps1'
        $childSource = @'
param([Parameter(Mandatory)][string]$ExpectedRoot)
$actual = [Environment]::GetEnvironmentVariable('STANDARD_VALIDATION_RUN_OWNED_ROOT','Process')
if ([string]::IsNullOrWhiteSpace($actual) -or -not [IO.Path]::GetFullPath($actual).Equals([IO.Path]::GetFullPath($ExpectedRoot),[StringComparison]::OrdinalIgnoreCase)) {
    [Console]::Error.WriteLine('namespaced owned root missing or changed')
    exit 73
}
[Console]::Out.WriteLine('namespaced-owned-root-ok')
exit 0
'@
        [IO.File]::WriteAllText($childPath,$childSource,[Text.UTF8Encoding]::new($false))
        $current = [IO.Path]::GetFullPath([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
        . $runnerPath -DefineFunctionsOnly -CandidateRoot $candidateRoot -AdapterPath (Join-Path $root 'adapter.json') `
            -ArtifactsRoot $artifactsRoot -SourceRepository 'https://example.invalid/repo.git' -SourceRevision ('a' * 40) `
            -BaseRevision ('b' * 40) -EventName 'local' -TrustedToolRoot $trustedRoot

        { Get-StandardValidationChildEnvironment -Environment @{ RUN_OWNED_ROOT=$root } } |
            Should -Throw '*outside the runner namespace*'
        $result = Invoke-StandardValidationProcess -Command $current `
            -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-File',$childPath,$trustedRoot) `
            -WorkingDirectory $workingRoot -Environment @{ STANDARD_VALIDATION_RUN_OWNED_ROOT=$trustedRoot } `
            -TimeoutSeconds 45 -CoreLifecycleOnly
        $result.status | Should -BeExactly 'passed'
        $result.exitCode | Should -Be 0
        $result.cleanedUp | Should -BeTrue
        $result.stdout | Should -Match 'namespaced-owned-root-ok'
        [string]::IsNullOrWhiteSpace([string]$result.stderr) | Should -BeTrue

        $sleepChildPath = Join-Path $workingRoot 'serial-sleep-child.ps1'
        $serialParentPath = Join-Path $workingRoot 'serial-parent.ps1'
        $markerPath = Join-Path $workingRoot 'serial-child-markers.txt'
        $sleepChildSource = @'
param([Parameter(Mandatory)][int]$Step,[Parameter(Mandatory)][string]$MarkerPath)
[IO.File]::AppendAllText($MarkerPath,"child-$Step-started`n")
if ($Step -eq 1) { Start-Sleep -Milliseconds 250 } else { Start-Sleep -Seconds 30 }
[IO.File]::AppendAllText($MarkerPath,"child-$Step-completed`n")
'@
        $serialParentSource = @'
param([Parameter(Mandatory)][string]$PowerShell,[Parameter(Mandatory)][string]$ChildScript,[Parameter(Mandatory)][string]$MarkerPath)
for($step=1;$step -le 2;$step++){
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$PowerShell;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
    foreach($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',$ChildScript,[string]$step,$MarkerPath)){[void]$start.ArgumentList.Add($argument)}
    $child=[Diagnostics.Process]::new();$child.StartInfo=$start
    try{if(-not $child.Start()){exit 80};$child.WaitForExit();if($child.ExitCode -ne 0){exit $child.ExitCode}}finally{$child.Dispose()}
}
exit 0
'@
        [IO.File]::WriteAllText($sleepChildPath,$sleepChildSource,[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($serialParentPath,$serialParentSource,[Text.UTF8Encoding]::new($false))
        $serialResult=Invoke-StandardValidationProcess -Command $current `
            -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-File',$serialParentPath,$current,$sleepChildPath,$markerPath) `
            -WorkingDirectory $workingRoot -Environment @{STANDARD_VALIDATION_RUN_OWNED_ROOT=$trustedRoot} `
            -TimeoutSeconds 10 -CoreLifecycleOnly
        $serialResult.status | Should -BeExactly 'timeout'
        $serialResult.cleanedUp | Should -BeTrue
        $serialMarkers=[IO.File]::ReadAllText($markerPath)
        $serialMarkers | Should -Match 'child-1-completed'
        $serialMarkers | Should -Match 'child-2-started'
        $serialMarkers | Should -Not -Match 'child-2-completed'
    }

    It 'UnitT44_Budgets_each_supervised_child_against_the_aggregate_deadline' {
        # Scenario: Repeated tool acquisition consumes one shared operation budget while each child keeps its own cap.
        # Purpose: Prove remaining-time allocation shrinks, bounds each child, and rejects exhausted deadlines.
        $runId = 'a' * 32
        $authorityRoot = Join-Path $TestDrive "authority-$runId"
        $resolverPath = Join-Path $authorityRoot 'scripts/Resolve-StandardValidationTool.ps1'
        $policyPath = Join-Path $authorityRoot 'docs/standards/validation-toolchain.json'
        $installRoot = Join-Path $TestDrive "core-v2-$runId"
        $outputPath = Join-Path $TestDrive "receipt-$runId.json"
        $common = @{
            ResolverPath = $resolverPath
            PolicyPath = $policyPath
            ToolName = 'skillspector'
            InstallRoot = $installRoot
            RunId = $runId
            OutputPath = $outputPath
        }

        $defaultArguments = New-StandardCoreV2ResolverArguments @common
        foreach ($case in @(
            [pscustomobject]@{ Arguments = $defaultArguments; ExpectedTimeout = '3600' },
            [pscustomobject]@{ Arguments = (New-StandardCoreV2ResolverArguments @common -AcquisitionTimeoutSeconds 1); ExpectedTimeout = '1' },
            [pscustomobject]@{ Arguments = (New-StandardCoreV2ResolverArguments @common -AcquisitionTimeoutSeconds 3600); ExpectedTimeout = '3600' }
        )) {
            $arguments = [string[]]$case.Arguments
            $timeoutIndex = [Array]::IndexOf($arguments, '-AcquisitionTimeoutSeconds')
            $timeoutIndex | Should -BeGreaterThan -1
            @($arguments | Where-Object { $_ -ceq '-AcquisitionTimeoutSeconds' }).Count | Should -Be 1
            $arguments[$timeoutIndex + 1] | Should -BeExactly $case.ExpectedTimeout
            $arguments | Should -Contain '-Install'
            $arguments[[Array]::IndexOf($arguments, '-File') + 1] | Should -BeExactly $resolverPath
            $arguments[[Array]::IndexOf($arguments, '-PolicyPath') + 1] | Should -BeExactly $policyPath
            $arguments[[Array]::IndexOf($arguments, '-ToolName') + 1] | Should -BeExactly 'skillspector'
            $arguments[[Array]::IndexOf($arguments, '-InstallRoot') + 1] | Should -BeExactly $installRoot
            $arguments[[Array]::IndexOf($arguments, '-RunId') + 1] | Should -BeExactly $runId
            $arguments[[Array]::IndexOf($arguments, '-OutputPath') + 1] | Should -BeExactly $outputPath
        }

        { New-StandardCoreV2ResolverArguments @common -AcquisitionTimeoutSeconds 0 } | Should -Throw
        { New-StandardCoreV2ResolverArguments @common -AcquisitionTimeoutSeconds 3601 } | Should -Throw

        foreach ($case in @(
            [pscustomobject]@{ ElapsedMilliseconds = 0L; ChildLimitSeconds = 3600; Expected = 3600 },
            [pscustomobject]@{ ElapsedMilliseconds = 3600000L; ChildLimitSeconds = 3600; Expected = 3600 },
            [pscustomobject]@{ ElapsedMilliseconds = 10800000L; ChildLimitSeconds = 3600; Expected = 3600 },
            [pscustomobject]@{ ElapsedMilliseconds = 12600000L; ChildLimitSeconds = 3600; Expected = 1800 },
            [pscustomobject]@{ ElapsedMilliseconds = 14399000L; ChildLimitSeconds = 3600; Expected = 1 },
            [pscustomobject]@{ ElapsedMilliseconds = 10000L; ChildLimitSeconds = 1200; Expected = 1200 }
        )) {
            Get-StandardCoreV2ChildBudget -OperationTimeoutSeconds 14400 -ChildLimitSeconds $case.ChildLimitSeconds `
                -ElapsedMilliseconds $case.ElapsedMilliseconds -Context 'UnitT44 fixture' | Should -Be $case.Expected
        }
        { Get-StandardCoreV2ChildBudget -OperationTimeoutSeconds 14400 -ChildLimitSeconds 3600 -ElapsedMilliseconds 14400000 -Context 'UnitT44 fixture' } |
            Should -Throw '*aggregate operation deadline*'
        { Get-StandardCoreV2ChildBudget -OperationTimeoutSeconds 14400 -ChildLimitSeconds 3600 -ElapsedMilliseconds 14399500 -Context 'UnitT44 fixture' } |
            Should -Throw '*aggregate operation deadline*'
        $firstChildBudget = Get-StandardCoreV2ChildBudget -OperationTimeoutSeconds 14400 -ChildLimitSeconds 3600 -ElapsedMilliseconds 0 -Context 'UnitT44 first child'
        $firstChildElapsed = 3000
        $secondChildBudget = Get-StandardCoreV2ChildBudget -OperationTimeoutSeconds 14400 -ChildLimitSeconds 3600 `
            -ElapsedMilliseconds ([long]$firstChildElapsed * 1000) -Context 'UnitT44 second child'
        $remainingForOuterProcess = Get-StandardCoreV2RemainingSeconds -OperationTimeoutSeconds 14400 `
            -ElapsedMilliseconds ([long]$firstChildElapsed * 1000) -Context 'UnitT44 aggregate process'
        ($firstChildElapsed + $firstChildElapsed) | Should -BeGreaterThan $firstChildBudget
        $secondChildBudget | Should -Be 3600
        $remainingForOuterProcess | Should -Be 11400

        $driverPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-ProtectedSourceValidation.ps1'
        $tokens = $null; $errors = $null
        $driverAst = [System.Management.Automation.Language.Parser]::ParseFile($driverPath, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0
        $driverAst.ParamBlock.Extent.Text | Should -Match '(?s)\[ValidateRange\(1\s*,\s*14400\)\]\[int\]\s*\$OperationTimeoutSeconds\s*=\s*14400'
        $driverAst.ParamBlock.Extent.Text | Should -Match '(?s)\[ValidateRange\(1\s*,\s*3600\)\]\[int\]\s*\$TimeoutSeconds\s*=\s*3600'
        @($driverAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -ceq 'Get-StandardCoreV2ChildBudget' }, $true)).Count | Should -Be 3
        $driverAst.Extent.Text | Should -Match '-LimitSeconds\s+\$runnerProcessBudget'
        $driverAst.Extent.Text | Should -Match '\$reportReplayBudget\s*=\s*Get-StandardCoreV2RemainingSeconds'
        $driverAst.Extent.Text | Should -Match 'operationTimeoutSeconds=\$OperationTimeoutSeconds;childTimeoutSeconds=\$TimeoutSeconds'
        $driverAst.Extent.Text | Should -Match 'Get-Revision\s+\$git\s+\$repo\s+\$BaseCommit\s+''Base revision'''
        $overlapCheckIndex = $driverAst.Extent.Text.IndexOf('Test-Within $toolInstallParent $artifact')
        $installCreateIndex = $driverAst.Extent.Text.IndexOf('[IO.Directory]::CreateDirectory($toolInstallParent)')
        $overlapCheckIndex | Should -BeGreaterThan -1
        $overlapCheckIndex | Should -BeLessThan $installCreateIndex
        $dispatchCalls = @($driverAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -ceq 'New-StandardCoreV2ResolverArguments' }, $true))
        $dispatchCalls.Count | Should -Be 1
        $dispatchElements = @($dispatchCalls[0].CommandElements | ForEach-Object { [string]$_.Extent.Text })
        $dispatchElements | Should -Contain '-AcquisitionTimeoutSeconds'
        $dispatchElements | Should -Contain '$resolverBudget'

        $resolverProcessCalls = @($driverAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -ceq 'Invoke-StandardCoreSupervisedProcess' -and $node.Extent.Text -match '-Arguments\s+\$args' }, $true))
        $resolverProcessCalls.Count | Should -Be 1
        $resolverProcessExtent = $resolverProcessCalls[0].Extent.Text
        $resolverProcessExtent | Should -Match '-CandidateRoot\s+\$candidate\.Root'
        $resolverProcessExtent | Should -Match '-AdapterPath\s+\(Join-Path\s+\$adapterRoot\s+''adapter\.json''\)'
        $resolverProcessExtent | Should -Match '-ArtifactsRoot\s+\$artifact'
        $resolverProcessExtent | Should -Match '-SourceRepository\s+\(\[string\]\$profile\.source\.repository\)'
        $resolverProcessExtent | Should -Match '-SourceRevision\s+\$sourceRevision'
        $resolverProcessExtent | Should -Match '-AuthorityRevision\s+\(\[string\]\$profile\.authority\.commit\)'
        $resolverProcessExtent | Should -Match '-RunId\s+\$runId'
        $resolverProcessExtent | Should -Match '-TrustedToolRoot\s+\$trusted'
        $resolverProcessExtent | Should -Match '-LimitSeconds\s+\$resolverBudget'
    }

    It 'UnitT45_Collects_fourteen_distinct_frozen_candidate_and_setup_paths' {
        # Scenario: Preparation collects candidate and setup inputs before hashing the frozen inventory.
        # Purpose: Execute the production collector expression and preserve its exact fourteen paths, including the raw archive and direct module dependency.
        $candidateRoot = Join-Path $TestDrive "frozen-candidate-$([guid]::NewGuid().ToString('N'))"
        $candidateReviewedBaseline = Join-Path $candidateRoot 'scripts/SkillSpectorReviewedE1Baselines.json'
        $setupLockPath = Join-Path $TestDrive "frozen-setup-$([guid]::NewGuid().ToString('N')).lock"
        $bindingPath = Join-Path $TestDrive "frozen-binding-$([guid]::NewGuid().ToString('N')).json"
        $toolchainPath = Join-Path $TestDrive "frozen-toolchain-$([guid]::NewGuid().ToString('N')).json"
        $pesterReceiptPath = Join-Path $TestDrive "frozen-pester-$([guid]::NewGuid().ToString('N')).json"
        $driverPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-ProtectedSourceValidation.ps1'
        $tokens = $null; $errors = $null
        $driverAst = [System.Management.Automation.Language.Parser]::ParseFile($driverPath, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0
        $collectors = @($driverAst.FindAll({ param($node)
            if ($node -isnot [System.Management.Automation.Language.ForEachStatementAst]) { return $false }
            $conditionText = if ($null -eq $node.Condition) { '' } else { [string]$node.Condition.Extent.Text }
            $loopText = [string]$node.Extent.Text
            return $loopText.Contains('Add-Frozen') -and $conditionText.Contains('$candidate.Root')
        }, $true))
        $collectors.Count | Should -Be 1

        $candidate = [pscustomobject]@{ Root = $candidateRoot }
        $lockPath = $setupLockPath
        $binding = [pscustomobject]@{ BindingPath = $bindingPath }
        $pester = [pscustomobject]@{ setupReceiptPath = $pesterReceiptPath }
        $sourceArchive = [pscustomobject]@{ path = (Join-Path $TestDrive 'frozen-source-archive.tar') }
        $expected = [string[]]@(
            (Join-Path $candidateRoot 'scripts/Test-Repository.ps1'),
            (Join-Path $candidateRoot 'scripts/Invoke-CoreRepositoryGeneral.ps1'),
            (Join-Path $candidateRoot 'scripts/Invoke-CorePester.ps1'),
            (Join-Path $candidateRoot 'scripts/CorePesterIntegrity.psm1'),
            (Join-Path $candidateRoot 'scripts/StandardCoreSourcePreparation.psm1'),
            $candidateReviewedBaseline,
            (Join-Path $candidateRoot 'config/pester-6.2.0-closure.lock.json'),
            (Join-Path $candidateRoot 'config/standard-core-v2-preparation.json'),
            (Join-Path $candidateRoot '.gitattributes'),
            $sourceArchive.path,
            $setupLockPath,
            $bindingPath,
            $toolchainPath,
            $pesterReceiptPath
        )

        $actual = [string[]]@(& ([scriptblock]::Create($collectors[0].Condition.Extent.Text)))

        $actual.Count | Should -Be 14
        @($actual | Where-Object { $_ -ceq $candidateReviewedBaseline }).Count | Should -Be 1
        $unique = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        for ($index = 0; $index -lt $expected.Count; $index++) {
            $actual[$index] | Should -BeExactly $expected[$index]
            [void]$unique.Add($actual[$index])
        }
        $unique.Count | Should -Be 14
    }

    It 'UnitT46_Reconstructs_all_four_source_dispatches_without_overwriting_validated_entry_mode' {
        # Scenario: SourceValidation reconstructs the four protected tool slots after setup has completed.
        # Purpose: Preserve the validated entry Mode while checking each exact command and argument vector.
        $driverPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-ProtectedSourceValidation.ps1'
        $tokens = $null; $errors = $null
        $driverAst = [System.Management.Automation.Language.Parser]::ParseFile($driverPath, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0
        $modeParameters = @($driverAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -ceq 'Mode' })
        $modeParameters.Count | Should -Be 1
        $dispatchLoops = @($driverAst.FindAll({ param($node)
            $node -is [System.Management.Automation.Language.ForEachStatementAst] -and
            $node.Extent.Text.Contains('Source dispatch $slot') -and
            $node.Extent.Text.Contains('$expectedArgs')
        }, $true))
        $dispatchLoops.Count | Should -Be 1

        $fixtureText = @'
[CmdletBinding()]
param(
__MODE_PARAMETER__,
[string] $DriftSlot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$current = 'C:\trusted\pwsh.exe'
$sourceArgs = @('-NoProfile', '-File', 'C:\trusted\Invoke-CoreSourceTool.ps1', '-ToolchainPath', 'C:\setup\toolchain.json', '-ToolchainSha256', ('a' * 64))
$slotModes = [ordered]@{ packageAdapter = 'package-adapter'; skillValidator = 'skill-validator'; skillTools = 'skill-tools'; staticAnalyzer = 'static' }
$sourceValidation = [ordered]@{}
foreach ($slotName in $slotModes.Keys) {
    $sourceValidation[$slotName] = [pscustomobject]@{ command = $current; arguments = [string[]]@($sourceArgs + @('-Mode', [string]$slotModes[$slotName])) }
}
$plan = [pscustomobject]@{ sourceValidation = [pscustomobject]$sourceValidation }
function Assert-StandardCoreV2ExactProperties {
    param([object] $Value, [string[]] $Names, [string] $Context)
    Write-Output $Context
}
if (-not [string]::IsNullOrWhiteSpace($DriftSlot)) {
    $driftedArguments = [string[]]$plan.sourceValidation.$DriftSlot.arguments
    $driftedArguments[0] = 'tampered-tool-wrapper-argument'
    $plan.sourceValidation.$DriftSlot.arguments = $driftedArguments
}
__PRODUCTION_DISPATCH_LOOP__
$slotRecords = @(foreach ($slotName in $slotModes.Keys) {
    [pscustomobject]@{ slot = [string]$slotName; command = [string]$plan.sourceValidation.$slotName.command; arguments = [string[]]@($plan.sourceValidation.$slotName.arguments) }
})
[pscustomobject]@{ modeAfter = [string]$Mode; slots = $slotRecords }
'@
        $fixtureText = $fixtureText.Replace('__MODE_PARAMETER__', $modeParameters[0].Extent.Text).
            Replace('__PRODUCTION_DISPATCH_LOOP__', $dispatchLoops[0].Extent.Text)
        $dispatchFixture = [scriptblock]::Create($fixtureText)
        $sourceArgs = @('-NoProfile', '-File', 'C:\trusted\Invoke-CoreSourceTool.ps1', '-ToolchainPath', 'C:\setup\toolchain.json', '-ToolchainSha256', ('a' * 64))
        $current = 'C:\trusted\pwsh.exe'
        $slotModes = [ordered]@{ packageAdapter = 'package-adapter'; skillValidator = 'skill-validator'; skillTools = 'skill-tools'; staticAnalyzer = 'static' }

        $fixtureOutput = @(& $dispatchFixture -Mode 'SourceValidation')
        $fixtureOutput.Count | Should -Be 5
        $expectedContexts = @('Source dispatch packageAdapter', 'Source dispatch skillValidator', 'Source dispatch skillTools', 'Source dispatch staticAnalyzer')
        for ($index = 0; $index -lt $expectedContexts.Count; $index++) {
            $fixtureOutput[$index] | Should -BeExactly $expectedContexts[$index]
        }
        $summary = $fixtureOutput[-1]
        $summary.modeAfter | Should -BeExactly 'SourceValidation'
        $summary.slots.Count | Should -Be 4
        $expectedSlots = @($slotModes.Keys)
        for ($index = 0; $index -lt $expectedSlots.Count; $index++) {
            $slot = [string]$expectedSlots[$index]
            $summary.slots[$index].slot | Should -BeExactly $slot
            $summary.slots[$index].command | Should -BeExactly $current
            $expectedArguments = [string[]]@($sourceArgs + @('-Mode', [string]$slotModes[$slot]))
            $actualArguments = [string[]]@($summary.slots[$index].arguments)
            $actualArguments.Count | Should -Be $expectedArguments.Count
            for ($argumentIndex = 0; $argumentIndex -lt $expectedArguments.Count; $argumentIndex++) {
                $actualArguments[$argumentIndex] | Should -BeExactly $expectedArguments[$argumentIndex]
            }
        }

        { & $dispatchFixture -Mode 'SourceValidation' -DriftSlot 'skillTools' | Out-Null } |
            Should -Throw '*Source dispatch skillTools arguments differ from the protected tool wrapper.*'
        { & $dispatchFixture -Mode 'NotAValidatedEntryMode' | Out-Null } | Should -Throw
    }

    It 'UnitT47_Projects_static_findings_after_retaining_all_six_candidate_reports' {
        # Scenario: A fresh static-tool process scans every catalog Skill and emits controlled SkillSpector reports.
        # Purpose: Preserve all raw reports, bind findings to candidate files, and defer severity disposition to the central policy.
        if (-not $IsWindows) { Set-ItResult -Skipped -Because 'The native static scanner fixture uses a Windows process.'; return }

        $root = Join-Path $TestDrive ('static-findings-' + [guid]::NewGuid().ToString('N'))
        $candidateRoot = Join-Path $root 'candidate'
        $skillsRoot = Join-Path $candidateRoot 'skills'
        $wrapper = Join-Path $script:RepositoryRoot 'scripts/Invoke-CoreSourceTool.ps1'
        $centralRunner = Join-Path $script:RepositoryRoot 'scripts/Invoke-StandardValidation.ps1'
        $runtime = [IO.Path]::GetFullPath([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
        $skillIds = @((Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/source.json') -Raw | ConvertFrom-Json).skills)
        $skillIds.Count | Should -Be 6
        New-Item -ItemType Directory -Path $skillsRoot -Force | Out-Null
        foreach ($skillId in $skillIds) {
            $skillRoot = Join-Path $skillsRoot $skillId
            New-Item -ItemType Directory -Path $skillRoot -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $skillRoot 'SKILL.md'), "fixture $skillId`n", [Text.UTF8Encoding]::new($false))
            $referencesRoot = Join-Path $skillRoot 'references'
            New-Item -ItemType Directory -Path $referencesRoot -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $referencesRoot 'nested.md'), "nested fixture $skillId`n", [Text.UTF8Encoding]::new($false))
        }

        $compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
        if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { Set-ItResult -Skipped -Because 'The Windows .NET Framework C# compiler is unavailable.'; return }
        $scannerSource = Join-Path $root 'static-fixture.cs'
        $scannerExecutable = Join-Path $root 'static-fixture.exe'
        $source = @'
using System;
using System.IO;
internal static class StaticFixture {
    private static int Main(string[] args) {
        if (args.Length < 7 || args[0] != "scan") return 87;
        int outputIndex = Array.IndexOf(args, "--output");
        if (outputIndex < 0 || outputIndex + 1 >= args.Length) return 88;
        string skillId = Path.GetFileName(args[1]);
        string reportsRoot = Environment.GetEnvironmentVariable("SYP304_STATIC_REPORT_ROOT");
        if (String.IsNullOrEmpty(reportsRoot)) return 89;
        string sourcePath = Path.Combine(reportsRoot, skillId + ".json");
        if (!File.Exists(sourcePath)) return 90;
        File.Copy(sourcePath, args[outputIndex + 1], true);
        Console.Out.Write("static-fixture:" + skillId);
        Console.Error.Write("static-report:" + skillId);
        return 0;
    }
}
'@
        [IO.File]::WriteAllText($scannerSource, $source, [Text.UTF8Encoding]::new($false))
        $compile = [Diagnostics.ProcessStartInfo]::new()
        $compile.FileName = $compiler; $compile.WorkingDirectory = $root; $compile.UseShellExecute = $false; $compile.CreateNoWindow = $true
        $compile.RedirectStandardOutput = $true; $compile.RedirectStandardError = $true
        foreach ($argument in @('/nologo', '/target:exe', ('/out:' + $scannerExecutable), $scannerSource)) { [void]$compile.ArgumentList.Add($argument) }
        $compilerProcess = [Diagnostics.Process]::new(); $compilerProcess.StartInfo = $compile
        try {
            $compilerProcess.Start() | Should -BeTrue
            $compileOut = $compilerProcess.StandardOutput.ReadToEndAsync(); $compileErr = $compilerProcess.StandardError.ReadToEndAsync()
            if (-not $compilerProcess.WaitForExit(30000)) { $compilerProcess.Kill($true); $compilerProcess.WaitForExit(); throw 'Static fixture compiler timed out.' }
            if ($compilerProcess.ExitCode -ne 0) { throw "Static fixture compilation failed: $($compileOut.GetAwaiter().GetResult()) $($compileErr.GetAwaiter().GetResult())" }
        } finally { $compilerProcess.Dispose() }
        Test-Path -LiteralPath $scannerExecutable -PathType Leaf | Should -BeTrue

        function New-StaticFixtureIssue {
            param([string] $Severity, [string] $IssuePath = 'references/nested.md', [switch] $OmitSeverity, [switch] $Sparse)
            $issue = [ordered]@{
                id = 'E1'
                match_fingerprint = 'a' * 64
                category = 'Data Exfiltration'
                pattern = $null
                finding = $null
                code_snippet = $null
                explanation = 'The scanner matched a documented API endpoint.'
                location = [ordered]@{ file = $IssuePath; start_line = 1; end_line = 1; start_column = 1 }
            }
            if ($Sparse) { $issue.Remove('match_fingerprint') }
            if (-not $OmitSeverity) { $issue.severity = $Severity }
            return $issue
        }

        function Invoke-StaticFixtureProcess {
            param([Parameter(Mandatory)][string] $Scenario)
            $scenarioRoot = Join-Path $root $Scenario
            $reportsRoot = Join-Path $scenarioRoot 'reports'
            New-Item -ItemType Directory -Path $reportsRoot -Force | Out-Null
            foreach ($skillId in $skillIds) {
                $skillRoot = Join-Path $skillsRoot $skillId
                $issues = @()
                $sourcePath = $skillRoot
                $components = @([ordered]@{ path = 'SKILL.md' }, [ordered]@{ path = 'references/nested.md' })
                $completeness = [ordered]@{ execution_successful = $true; is_complete = $true; status = 'complete'; coverage_percent = 100; ledger_exceptions = @(); scope_exclusions = @(); limitations = @() }
                switch ($Scenario) {
                    'low-and-informational' {
                        if ($skillId -ceq $skillIds[0]) { $issues = @(New-StaticFixtureIssue -Severity 'LOW') }
                        if ($skillId -ceq $skillIds[1]) { $issues = @(New-StaticFixtureIssue -Severity 'INFORMATIONAL' -Sparse) }
                    }
                    'medium' { if ($skillId -ceq $skillIds[0]) { $issues = @(New-StaticFixtureIssue -Severity 'MEDIUM') } }
                    'high' { if ($skillId -ceq $skillIds[0]) { $issues = @(New-StaticFixtureIssue -Severity 'HIGH') } }
                    'critical' { if ($skillId -ceq $skillIds[0]) { $issues = @(New-StaticFixtureIssue -Severity 'CRITICAL') } }
                    'unknown-severity' { if ($skillId -ceq $skillIds[0]) { $issues = @(New-StaticFixtureIssue -Severity 'FUTURE') } }
                    'missing-severity' { if ($skillId -ceq $skillIds[0]) { $issues = @(New-StaticFixtureIssue -OmitSeverity) } }
                    'malformed-issue' { if ($skillId -ceq $skillIds[0]) { $issues = @('not-a-structured-issue') } }
                    'bad-location' { if ($skillId -ceq $skillIds[0]) { $issues = @(New-StaticFixtureIssue -Severity 'LOW' -IssuePath '../outside.md') } }
                    'bad-source' { if ($skillId -ceq $skillIds[0]) { $sourcePath = Join-Path $skillRoot 'nested-source' } }
                    'bad-inventory' { if ($skillId -ceq $skillIds[0]) { $components = @([ordered]@{ path = 'outside.md' }) } }
                    'incomplete' { if ($skillId -ceq $skillIds[0]) { $completeness.is_complete = $false; $completeness.status = 'partial' } }
                }
                $report = [ordered]@{
                    skill = [ordered]@{ name = $skillId; source = $sourcePath }
                    metadata = [ordered]@{ skillspector_version = '2.12.0' }
                    risk_assessment = [ordered]@{ severity = 'LOW'; recommendation = 'SAFE'; max_issue_severity = 'MEDIUM' }
                    components = $components
                    issues = $issues
                    suppressed_count = 0
                    suppressed = @()
                    execution_successful = $true
                    analysis_completeness = $completeness
                }
                [IO.File]::WriteAllText((Join-Path $reportsRoot ($skillId + '.json')), ($report | ConvertTo-Json -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))
            }

            $toolchainPath = Join-Path $scenarioRoot 'toolchain.json'
            $receiptPath = Join-Path $scenarioRoot 'receipt-skillspector.json'
            $scannerSha256 = Get-StandardCoreV2Sha256 -Path $scannerExecutable
            $receipt = [ordered]@{
                toolName = 'skillspector'; frozenForRun = $true; resolvedVersion = '2.12.0'
                executablePath = [IO.Path]::GetFullPath($scannerExecutable); executableSha256 = $scannerSha256
            }
            [IO.File]::WriteAllText($receiptPath, ($receipt | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
            $toolchain = [ordered]@{
                skillSpectorPath = $scannerExecutable; skillSpectorSha256 = $scannerSha256
                skillSpectorReceiptPath = [IO.Path]::GetFullPath($receiptPath); skillSpectorReceiptSha256 = Get-StandardCoreV2Sha256 -Path $receiptPath
            }
            [IO.File]::WriteAllText($toolchainPath, ($toolchain | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
            $start = [Diagnostics.ProcessStartInfo]::new()
            $start.FileName = $runtime; $start.UseShellExecute = $false; $start.CreateNoWindow = $true
            $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true; $start.WorkingDirectory = $scenarioRoot
            $start.Environment.Clear()
            foreach ($name in @('SystemRoot', 'WINDIR', 'PATH', 'PATHEXT', 'TEMP', 'TMP', 'TMPDIR', 'USERPROFILE', 'COMSPEC', 'ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432')) {
                $value = [Environment]::GetEnvironmentVariable($name)
                if (-not [string]::IsNullOrWhiteSpace($value)) { $start.Environment[$name] = $value }
            }
            $start.Environment['STANDARD_VALIDATION_CANDIDATE_ROOT'] = $candidateRoot
            $start.Environment['STANDARD_VALIDATION_CANDIDATE_ID'] = 'static-candidate-fixture'
            $start.Environment['STANDARD_VALIDATION_ACTIVE_SKILLS'] = $skillIds -join ';'
            $start.Environment['STANDARD_VALIDATION_SKILLS_ROOT'] = $skillsRoot
            $start.Environment['SYP304_STATIC_REPORT_ROOT'] = $reportsRoot
            foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $wrapper, '-Mode', 'static', '-ToolchainPath', $toolchainPath, '-ToolchainSha256', (Get-StandardCoreV2Sha256 -Path $toolchainPath))) {
                [void]$start.ArgumentList.Add([string]$argument)
            }
            $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
            try {
                $process.Start() | Should -BeTrue
                $stdoutTask = $process.StandardOutput.ReadToEndAsync(); $stderrTask = $process.StandardError.ReadToEndAsync()
                if (-not $process.WaitForExit(90000)) { $process.Kill($true); $process.WaitForExit(); throw "Static fixture timed out: $Scenario" }
                return [pscustomobject]@{ exitCode = [int]$process.ExitCode; stdout = $stdoutTask.GetAwaiter().GetResult(); stderr = $stderrTask.GetAwaiter().GetResult(); root = $scenarioRoot }
            } finally { $process.Dispose() }
        }

        $validScenarios = @('clean', 'low-and-informational', 'medium', 'high', 'critical')
        foreach ($scenario in $validScenarios) {
            $result = Invoke-StaticFixtureProcess -Scenario $scenario
            $result.exitCode | Should -Be 0 -Because "scenario=$scenario stderr=$($result.stderr)"
            $envelope = $result.stdout.Trim() | ConvertFrom-Json -Depth 80 -ErrorAction Stop
            $envelope.status | Should -BeExactly 'passed'
            $envelope.decision | Should -BeExactly 'PASS'
            $envelope.scannerIdentity | Should -BeExactly 'SkillSpector'
            $envelope.analyzerCompleteness | Should -BeExactly 'complete'
            @($envelope.nativeReports).Count | Should -Be 6
            $expectedFindingCount = switch ($scenario) { 'low-and-informational' { 2 } { $_ -in @('medium', 'high', 'critical') } { 1 } default { 0 } }
            @($envelope.findings).Count | Should -Be $expectedFindingCount
            $nativeSkillIds = @($envelope.nativeReports | ForEach-Object { [string]$_.skillId })
            $nativeSkillIds | Should -Be $skillIds
            $stdoutEvidence = @(Get-ChildItem -LiteralPath $result.root -Filter 'native-raw-static-*.stdout.bin' -File)
            $stderrEvidence = @(Get-ChildItem -LiteralPath $result.root -Filter 'native-raw-static-*.stderr.bin' -File)
            $stdoutEvidence.Count | Should -Be 6
            $stderrEvidence.Count | Should -Be 6
            $stdoutText = [string]::Join('', @($stdoutEvidence | ForEach-Object { [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($_.FullName)) }))
            $stderrText = [string]::Join('', @($stderrEvidence | ForEach-Object { [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($_.FullName)) }))
            foreach ($skillId in $skillIds) {
                $stdoutText | Should -Match ([regex]::Escape("static-fixture:$skillId"))
                $stderrText | Should -Match ([regex]::Escape("static-report:$skillId"))
            }
            foreach ($native in @($envelope.nativeReports)) {
                $native.exitCode | Should -Be 0
                $native.commandSha256 | Should -BeExactly (Get-StandardCoreV2Sha256 -Path $scannerExecutable)
                (Test-Path -LiteralPath $native.path -PathType Leaf) | Should -BeTrue
                (Get-StandardCoreV2Sha256 -Path $native.path) | Should -BeExactly ([string]$native.sha256)
                $nativeReport = Get-Content -LiteralPath $native.path -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 80
                $nativeReport.skill.name | Should -BeExactly ([string]$native.skillId)
                @($nativeReport.components).Count | Should -Be 2
            }
            foreach ($finding in @($envelope.findings)) {
                $propertyNames = @($finding.PSObject.Properties | ForEach-Object { [string]$_.Name } | Sort-Object -CaseSensitive)
                @($propertyNames | Where-Object { $_ -cnotin @('severity', 'fingerprint', 'ruleId', 'message', 'path') }).Count | Should -Be 0
                $finding.path | Should -Match '^skills/[^/]+/references/nested\.md$'
                if ($finding.PSObject.Properties['fingerprint']) {
                    $finding.fingerprint | Should -BeExactly ('a' * 64)
                } else {
                    $finding.PSObject.Properties['fingerprint'] | Should -BeNullOrEmpty
                }
                $finding.ruleId | Should -BeExactly 'E1'
                $finding.message | Should -BeExactly 'The scanner matched a documented API endpoint.'
            }

            $centralDecision = {
                param([string] $RunnerPath, [string] $FixtureRoot, [string] $ArtifactsRoot, [object[]] $Findings)
                . $RunnerPath -CandidateRoot $FixtureRoot -AdapterPath (Join-Path $ArtifactsRoot 'toolchain.json') -ArtifactsRoot $ArtifactsRoot `
                    -SourceRepository 'https://example.invalid/static-fixture.git' -SourceRevision ('a' * 40) -BaseRevision ('a' * 40) `
                    -TrustedToolRoot $script:RepositoryRoot -DefineFunctionsOnly
                return [bool](Assert-StandardValidationFindings -Envelope ([pscustomobject]@{ findings = $Findings }) -Context 'static fixture')
            }.GetNewClosure()
            if ($scenario -in @('high', 'critical')) {
                { & $centralDecision $centralRunner $candidateRoot $result.root @($envelope.findings) } |
                    Should -Throw "*contains a $scenario finding.*"
            } else {
                $requiresHuman = & $centralDecision $centralRunner $candidateRoot $result.root @($envelope.findings)
                $requiresHuman | Should -Be ($scenario -ceq 'medium')
            }
        }

        $invalidScenarios = @('unknown-severity', 'missing-severity', 'malformed-issue', 'bad-location', 'bad-source', 'bad-inventory', 'incomplete')
        foreach ($scenario in $invalidScenarios) {
            $result = Invoke-StaticFixtureProcess -Scenario $scenario
            $result.exitCode | Should -Be 1 -Because "scenario=$scenario stdout=$($result.stdout) stderr=$($result.stderr)"
            [string]::IsNullOrWhiteSpace($result.stdout) | Should -BeTrue
            $result.stderr | Should -Match 'rawStdout=.*\.stdout\.bin; rawStderr=.*\.stderr\.bin'
            @(Get-ChildItem -LiteralPath $result.root -Filter 'native-raw-static-*.stdout.bin' -File).Count | Should -Be 1
            @(Get-ChildItem -LiteralPath $result.root -Filter 'native-raw-static-*.stderr.bin' -File).Count | Should -Be 1
        }
    }

    It 'UnitT48_Binds_the_exact_reviewed_E1_policy_and_rejects_broad_rules' {
        # Scenario: Validate the reviewed policy as trusted pinned input before any per-Skill baseline can be used.
        # Purpose: Reject caller/candidate-authored broad suppression rules and protect the exact human-reviewed document.
        $artifactPath = Join-Path $script:RepositoryRoot 'scripts/SkillSpectorReviewedE1Baselines.json'
        Test-Path -LiteralPath $artifactPath -PathType Leaf | Should -BeTrue
        (Get-StandardCoreV2Sha256 -Path $artifactPath) | Should -BeExactly '05bf02ad11bc7f2430eb50f4a3e87c49b47c0eb92cb3453c1d8d0f44a443e2c2'

        $wrapperPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-CoreSourceTool.ps1'
        $tokens = $null; $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($wrapperPath, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $functionAst = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Assert-ReviewedE1BaselineContract' }, $true)
        $functionAst | Should -Not -BeNullOrEmpty
        . ([scriptblock]::Create($functionAst.Extent.Text))

        $document = Get-Content -LiteralPath $artifactPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 80
        { Assert-ReviewedE1BaselineContract -Document $document } | Should -Not -Throw
        $broadRules = $document | ConvertTo-Json -Depth 80 | ConvertFrom-Json -Depth 80
        $broadRules.skills[0].baseline.rules = @([pscustomobject]@{ rule_id = 'E1'; pattern = '.*'; reason = 'broad' })
        { Assert-ReviewedE1BaselineContract -Document $broadRules } | Should -Throw '*rules must be empty*'
        $changedCount = $document | ConvertTo-Json -Depth 80 | ConvertFrom-Json -Depth 80
        $changedCount.reviewedOccurrenceCount = 18
        { Assert-ReviewedE1BaselineContract -Document $changedCount } | Should -Throw '*reviewed occurrence count*'
    }

    It 'UnitT49_Applies_only_the_reviewed_baseline_partition_and_preserves_new_findings' {
        # Scenario: A fresh static-tool process receives a candidate with exact reviewed components and a candidate-authored broad policy.
        # Purpose: Bind only the protected per-Skill baseline, retain its raw report, skip it on byte drift, and preserve new findings for central disposition.
        if (-not $IsWindows) { Set-ItResult -Skipped -Because 'The native static scanner fixture uses a Windows process.'; return }

        $root = Join-Path $TestDrive ('reviewed-e1-baseline-' + [guid]::NewGuid().ToString('N'))
        $candidateRoot = Join-Path $root 'candidate'
        $skillsRoot = Join-Path $candidateRoot 'skills'
        $wrapper = Join-Path $script:RepositoryRoot 'scripts/Invoke-CoreSourceTool.ps1'
        $centralRunner = Join-Path $script:RepositoryRoot 'scripts/Invoke-StandardValidation.ps1'
        $runtime = [IO.Path]::GetFullPath([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
        $skillIds = @((Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/source.json') -Raw | ConvertFrom-Json).skills)
        $targetSkill = 'configure-bitbucket-api-access'
        $skillIds | Should -Contain $targetSkill
        $protectedArtifactPath = Join-Path $script:RepositoryRoot 'scripts/SkillSpectorReviewedE1Baselines.json'
        $policyDocument = Get-Content -LiteralPath $protectedArtifactPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 80
        $baselineSkill = @($policyDocument.skills | Where-Object { [string]$_.skillId -ceq $targetSkill })[0]
        $baselineSkill | Should -Not -BeNullOrEmpty
        $reviewedRows = [Collections.Generic.List[object]]::new()
        $reviewedFixtureBytes = [Collections.Generic.Dictionary[string, byte[]]]::new([StringComparer]::Ordinal)
        foreach ($component in $baselineSkill.components) {
            foreach ($occurrence in $component.reviewedFindings) {
                $approvedReasons = @($baselineSkill.baseline.fingerprints | Where-Object {
                    [string]$_.rule_id -ceq [string]$occurrence.ruleId -and [string]$_.file -ceq [string]$component.path
                } | ForEach-Object { [string]$_.reason } | Sort-Object -Unique -CaseSensitive)
                $approvedReasons.Count | Should -Be 1
                $reviewedRows.Add([pscustomobject]@{
                    id = [string]$occurrence.ruleId
                    severity = [string]$occurrence.severity
                    finding = [string]$occurrence.finding
                    location = [pscustomobject]@{ file = [string]$component.path; start_line = [int]$occurrence.line }
                    suppressed = $true
                    suppression_reason = [string]$approvedReasons[0]
                    match_fingerprint = ('f' * 64)
                    finding_id = [guid]::NewGuid().ToString('N')
                })
            }
        }
        $reviewedRows.Count | Should -Be 4

        New-Item -ItemType Directory -Path $skillsRoot -Force | Out-Null
        foreach ($skillId in $skillIds) {
            $skillRoot = Join-Path $skillsRoot $skillId
            New-Item -ItemType Directory -Path $skillRoot -Force | Out-Null
            if ($skillId -ceq $targetSkill) {
                foreach ($component in $baselineSkill.components) {
                    $repositoryPath = 'skills/' + $targetSkill + '/' + [string]$component.path
                    $sourcePath = Join-Path $script:RepositoryRoot $repositoryPath.Replace('/', [IO.Path]::DirectorySeparatorChar)
                    Test-Path -LiteralPath $sourcePath -PathType Leaf | Should -BeTrue -Because $repositoryPath
                    $destination = Join-Path $skillRoot ([string]$component.path).Replace('/', [IO.Path]::DirectorySeparatorChar)
                    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
                    $sourceBytes = [IO.File]::ReadAllBytes($sourcePath)
                    $fixtureBytes = $sourceBytes
                    $sourceHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($sourceBytes)).ToLowerInvariant()
                    if ($sourceHash -cne [string]$component.sha256 -or $sourceBytes.Length -ne [long]$component.length) {
                        # A normal Windows worktree may contain CRLF; normalize only this isolated fixture,
                        # then prove it exactly matches the pinned raw component length and SHA-256.
                        $sourceText = [Text.UTF8Encoding]::new($false, $true).GetString($sourceBytes)
                        $fixtureBytes = [Text.UTF8Encoding]::new($false).GetBytes($sourceText.Replace("`r`n", "`n"))
                    }
                    $fixtureHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($fixtureBytes)).ToLowerInvariant()
                    $fixtureHash | Should -BeExactly ([string]$component.sha256)
                    $fixtureBytes.Length | Should -Be ([long]$component.length)
                    $reviewedFixtureBytes[[string]$component.path] = [byte[]]$fixtureBytes.Clone()
                    [IO.File]::WriteAllBytes($destination, $fixtureBytes)
                    (Get-StandardCoreV2Sha256 -Path $destination) | Should -BeExactly ([string]$component.sha256)
                }
                [IO.File]::WriteAllText((Join-Path $skillRoot 'new.md'), 'unreviewed source finding fixture' + "`n", [Text.UTF8Encoding]::new($false))
            } else {
                [IO.File]::WriteAllText((Join-Path $skillRoot 'SKILL.md'), "fixture $skillId`n", [Text.UTF8Encoding]::new($false))
                [void][IO.Directory]::CreateDirectory((Join-Path $skillRoot 'references'))
                [IO.File]::WriteAllText((Join-Path $skillRoot 'references/nested.md'), "nested fixture $skillId`n", [Text.UTF8Encoding]::new($false))
            }
        }
        $candidatePolicyPath = Join-Path $candidateRoot 'scripts/SkillSpectorReviewedE1Baselines.json'
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $candidatePolicyPath))
        [IO.File]::WriteAllText($candidatePolicyPath, '{"policy":"candidate-authored","rules":[{"rule_id":"E1","pattern":".*"}]}', [Text.UTF8Encoding]::new($false))

        $compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
        if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { Set-ItResult -Skipped -Because 'The Windows .NET Framework C# compiler is unavailable.'; return }
        $scannerSource = Join-Path $root 'reviewed-e1-fixture.cs'
        $scannerExecutable = Join-Path $root 'reviewed-e1-fixture.exe'
        $source = @'
using System;
using System.IO;
internal static class ReviewedE1Fixture {
    private static int Main(string[] args) {
        if (args.Length < 7 || args[0] != "scan") return 87;
        int outputIndex = Array.IndexOf(args, "--output");
        if (outputIndex < 0 || outputIndex + 1 >= args.Length) return 88;
        string skillId = Path.GetFileName(args[1]);
        string reportsRoot = Environment.GetEnvironmentVariable("SYP304_STATIC_REPORT_ROOT");
        if (String.IsNullOrEmpty(reportsRoot)) return 89;
        string sourcePath = Path.Combine(reportsRoot, skillId + ".json");
        if (!File.Exists(sourcePath)) return 90;
        File.Copy(sourcePath, args[outputIndex + 1], true);
        return 0;
    }
}
'@
        [IO.File]::WriteAllText($scannerSource, $source, [Text.UTF8Encoding]::new($false))
        $compile = [Diagnostics.ProcessStartInfo]::new()
        $compile.FileName = $compiler; $compile.WorkingDirectory = $root; $compile.UseShellExecute = $false; $compile.CreateNoWindow = $true
        $compile.RedirectStandardOutput = $true; $compile.RedirectStandardError = $true
        foreach ($argument in @('/nologo', '/target:exe', ('/out:' + $scannerExecutable), $scannerSource)) { [void]$compile.ArgumentList.Add($argument) }
        $compilerProcess = [Diagnostics.Process]::new(); $compilerProcess.StartInfo = $compile
        try {
            $compilerProcess.Start() | Should -BeTrue
            $compileOut = $compilerProcess.StandardOutput.ReadToEndAsync(); $compileErr = $compilerProcess.StandardError.ReadToEndAsync()
            if (-not $compilerProcess.WaitForExit(30000)) { $compilerProcess.Kill($true); $compilerProcess.WaitForExit(); throw 'Reviewed E1 fixture compiler timed out.' }
            if ($compilerProcess.ExitCode -ne 0) { throw "Reviewed E1 fixture compilation failed: $($compileOut.GetAwaiter().GetResult()) $($compileErr.GetAwaiter().GetResult())" }
        } finally { $compilerProcess.Dispose() }

        function New-ReviewedE1Issue {
            param([Parameter(Mandatory)][string] $Severity)
            return [pscustomobject]@{
                id = if ($Severity -ceq 'MEDIUM') { 'E77' } else { 'E78' }
                severity = $Severity
                match_fingerprint = ('a' * 64)
                finding = "New unreviewed $Severity fixture finding."
                explanation = "New unreviewed $Severity fixture finding."
                location = [pscustomobject]@{ file = 'new.md'; start_line = 1; end_line = 1; start_column = 1 }
            }
        }

        function New-ReviewedE1Reports {
            param([Parameter(Mandatory)][string] $ScenarioRoot, [Parameter(Mandatory)][ValidateSet('applied', 'drift', 'missing-suppression', 'malformed-suppression', 'unexpected-suppression')][string] $Scenario)
            $reportsRoot = Join-Path $ScenarioRoot 'reports'
            New-Item -ItemType Directory -Path $reportsRoot -Force | Out-Null
            foreach ($skillId in $skillIds) {
                $skillRoot = Join-Path $skillsRoot $skillId
                $inventory = [string[]]@(Get-ChildItem -LiteralPath $skillRoot -Recurse -File -Force | ForEach-Object {
                    [IO.Path]::GetRelativePath($skillRoot, $_.FullName).Replace('\', '/')
                })
                [Array]::Sort($inventory, [StringComparer]::Ordinal)
                $issues = @()
                $suppressed = @()
                if ($skillId -ceq $targetSkill) {
                    switch ($Scenario) {
                        'applied' {
                            $issues = @(New-ReviewedE1Issue -Severity 'MEDIUM'; New-ReviewedE1Issue -Severity 'HIGH')
                            $suppressed = @($reviewedRows.ToArray())
                        }
                        'drift' { $issues = @(New-ReviewedE1Issue -Severity 'MEDIUM') }
                        'missing-suppression' { $suppressed = @($reviewedRows.ToArray() | Select-Object -Skip 1) }
                        'malformed-suppression' { $suppressed = @($reviewedRows.ToArray()) }
                        'unexpected-suppression' {
                            $unexpected = [Collections.Generic.List[object]]::new()
                            foreach ($row in $reviewedRows.ToArray() | Select-Object -Skip 1) { $unexpected.Add($row) }
                            $first = $reviewedRows[0]
                            $unexpected.Add([pscustomobject]@{
                                id = [string]$first.id; severity = [string]$first.severity; finding = [string]$first.finding
                                location = [pscustomobject]@{ file = [string]$first.location.file; start_line = 999 }
                                suppressed = $true; suppression_reason = [string]$first.suppression_reason
                                match_fingerprint = ('e' * 64); finding_id = [guid]::NewGuid().ToString('N')
                            })
                            $suppressed = @($unexpected.ToArray())
                        }
                    }
                }
                $suppressedValue = @($suppressed)
                if ($skillId -ceq $targetSkill -and $Scenario -ceq 'malformed-suppression') { $suppressedValue = 'not-an-array' }
                $report = [ordered]@{
                    skill = [ordered]@{ name = $skillId; source = $skillRoot }
                    metadata = [ordered]@{ skillspector_version = '2.12.0' }
                    risk_assessment = [ordered]@{ severity = 'LOW'; recommendation = 'SAFE'; max_issue_severity = 'MEDIUM' }
                    components = @($inventory | ForEach-Object { [ordered]@{ path = [string]$_ } })
                    issues = @($issues)
                    suppressed_count = @($suppressed).Count
                    suppressed = $suppressedValue
                    execution_successful = $true
                    analysis_completeness = [ordered]@{ execution_successful = $true; is_complete = $true; status = 'complete'; coverage_percent = 100; ledger_exceptions = @(); scope_exclusions = @(); limitations = @() }
                }
                [IO.File]::WriteAllText((Join-Path $reportsRoot ($skillId + '.json')), ($report | ConvertTo-Json -Depth 30 -Compress), [Text.UTF8Encoding]::new($false))
            }
            return $reportsRoot
        }

        function Invoke-ReviewedE1Wrapper {
            param([Parameter(Mandatory)][string] $WrapperPath, [Parameter(Mandatory)][string] $ScenarioRoot,
                [Parameter(Mandatory)][ValidateSet('applied', 'drift', 'missing-suppression', 'malformed-suppression', 'unexpected-suppression')][string] $Scenario,
                [string[]] $ExtraArguments = @())
            $reportsRoot = New-ReviewedE1Reports -ScenarioRoot $ScenarioRoot -Scenario $Scenario
            $toolchainPath = Join-Path $ScenarioRoot 'toolchain.json'
            $receiptPath = Join-Path $ScenarioRoot 'receipt-skillspector.json'
            $scannerSha256 = Get-StandardCoreV2Sha256 -Path $scannerExecutable
            $receipt = [ordered]@{ toolName = 'skillspector'; frozenForRun = $true; resolvedVersion = '2.12.0'; executablePath = [IO.Path]::GetFullPath($scannerExecutable); executableSha256 = $scannerSha256 }
            [IO.File]::WriteAllText($receiptPath, ($receipt | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
            $toolchain = [ordered]@{ skillSpectorPath = $scannerExecutable; skillSpectorSha256 = $scannerSha256; skillSpectorReceiptPath = [IO.Path]::GetFullPath($receiptPath); skillSpectorReceiptSha256 = Get-StandardCoreV2Sha256 -Path $receiptPath }
            [IO.File]::WriteAllText($toolchainPath, ($toolchain | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
            $start = [Diagnostics.ProcessStartInfo]::new()
            $start.FileName = $runtime; $start.UseShellExecute = $false; $start.CreateNoWindow = $true
            $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true; $start.WorkingDirectory = $ScenarioRoot
            $start.Environment.Clear()
            foreach ($name in @('SystemRoot', 'WINDIR', 'PATH', 'PATHEXT', 'TEMP', 'TMP', 'TMPDIR', 'USERPROFILE', 'COMSPEC', 'ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432')) {
                $value = [Environment]::GetEnvironmentVariable($name)
                if (-not [string]::IsNullOrWhiteSpace($value)) { $start.Environment[$name] = $value }
            }
            $start.Environment['STANDARD_VALIDATION_CANDIDATE_ROOT'] = $candidateRoot
            $start.Environment['STANDARD_VALIDATION_CANDIDATE_ID'] = 'reviewed-e1-fixture'
            $start.Environment['STANDARD_VALIDATION_ACTIVE_SKILLS'] = $skillIds -join ';'
            $start.Environment['STANDARD_VALIDATION_SKILLS_ROOT'] = $skillsRoot
            $start.Environment['SYP304_STATIC_REPORT_ROOT'] = $reportsRoot
            $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $WrapperPath, '-Mode', 'static', '-ToolchainPath', $toolchainPath, '-ToolchainSha256', (Get-StandardCoreV2Sha256 -Path $toolchainPath)) + @($ExtraArguments)
            foreach ($argument in $arguments) { [void]$start.ArgumentList.Add([string]$argument) }
            $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
            try {
                $process.Start() | Should -BeTrue
                $stdoutTask = $process.StandardOutput.ReadToEndAsync(); $stderrTask = $process.StandardError.ReadToEndAsync()
                if (-not $process.WaitForExit(90000)) { $process.Kill($true); $process.WaitForExit(); throw 'Reviewed E1 wrapper process timed out.' }
                return [pscustomobject]@{ exitCode = [int]$process.ExitCode; stdout = $stdoutTask.GetAwaiter().GetResult(); stderr = $stderrTask.GetAwaiter().GetResult(); reportsRoot = $reportsRoot; toolchainPath = $toolchainPath; root = $ScenarioRoot }
            } finally { $process.Dispose() }
        }

        $appliedRoot = Join-Path $root 'applied'
        New-Item -ItemType Directory -Path $appliedRoot -Force | Out-Null
        $applied = Invoke-ReviewedE1Wrapper -WrapperPath $wrapper -ScenarioRoot $appliedRoot -Scenario 'applied'
        $applied.exitCode | Should -Be 0 -Because $applied.stderr
        $envelope = $applied.stdout.Trim() | ConvertFrom-Json -Depth 80 -ErrorAction Stop
        @($envelope.nativeReports).Count | Should -Be 6
        @($envelope.findings).Count | Should -Be 2
        @($envelope.findings | Where-Object severity -CEq 'medium').Count | Should -Be 1
        @($envelope.findings | Where-Object severity -CEq 'high').Count | Should -Be 1
        foreach ($finding in $envelope.findings) { $finding.path | Should -BeExactly ('skills/' + $targetSkill + '/new.md') }
        $envelope.reviewedBaselinePolicy.artifactSha256 | Should -BeExactly '05bf02ad11bc7f2430eb50f4a3e87c49b47c0eb92cb3453c1d8d0f44a443e2c2'
        $envelope.reviewedBaselinePolicy.artifactPath | Should -BeExactly ([IO.Path]::GetFullPath($protectedArtifactPath))
        $envelope.reviewedBaselinePolicy.artifactPath | Should -Not -BeExactly $candidatePolicyPath
        $native = @($envelope.nativeReports | Where-Object { [string]$_.skillId -ceq $targetSkill })[0]
        $native.reviewedBaseline.decision | Should -BeExactly 'applied'
        $native.reviewedBaseline.applied | Should -BeTrue
        $native.reviewedBaseline.componentHashesMatched | Should -BeTrue
        $native.reviewedBaseline.expectedSuppressedCount | Should -Be 4
        $native.reviewedBaseline.actualSuppressedCount | Should -Be 4
        $native.reviewedBaseline.reviewer | Should -BeExactly 'Independent SYP-304 SOL'
        $native.reviewedBaseline.reviewFindingId | Should -BeExactly 'F304-SOL-22'
        $native.reviewedBaseline.nativeBaselinePath | Should -Not -BeNullOrEmpty
        (Get-StandardCoreV2Sha256 -Path $native.reviewedBaseline.nativeBaselinePath) | Should -BeExactly ([string]$native.reviewedBaseline.nativeBaselineSha256)
        $materialized = Get-Content -LiteralPath $native.reviewedBaseline.nativeBaselinePath -Raw | ConvertFrom-Json -Depth 80
        @($materialized.rules).Count | Should -Be 0
        @($materialized.fingerprints).Count | Should -Be 4
        $reportPath = [string]$native.path
        (Get-StandardCoreV2Sha256 -Path $reportPath) | Should -BeExactly ([string]$native.sha256)
        (Get-StandardCoreV2Sha256 -Path $reportPath) | Should -BeExactly (Get-StandardCoreV2Sha256 -Path (Join-Path $applied.reportsRoot ($targetSkill + '.json')))
        $rawReport = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 80
        @($rawReport.suppressed).Count | Should -Be 4
        $rawReport.suppressed[0].match_fingerprint | Should -BeExactly ('f' * 64)
        $rawReport.suppressed[0].finding_id | Should -Not -BeNullOrEmpty
        $rawReport.suppressed[0].suppression_reason | Should -BeExactly ([string]$baselineSkill.baseline.fingerprints[0].reason)
        $expectedArguments = @('scan', (Join-Path $skillsRoot $targetSkill), '--no-llm', '--format', 'json', '--output', $reportPath, '--baseline', [string]$native.reviewedBaseline.nativeBaselinePath, '--show-suppressed')
        $actualArguments = [string[]]@($native.arguments)
        $actualArguments.Count | Should -Be $expectedArguments.Count
        for ($index = 0; $index -lt $expectedArguments.Count; $index++) { $actualArguments[$index] | Should -BeExactly $expectedArguments[$index] }

        $centralDecision = {
            param([string] $RunnerPath, [string] $FixtureRoot, [string] $ArtifactsRoot, [object[]] $Findings)
            . $RunnerPath -CandidateRoot $FixtureRoot -AdapterPath (Join-Path $ArtifactsRoot 'toolchain.json') -ArtifactsRoot $ArtifactsRoot `
                -SourceRepository 'https://example.invalid/reviewed-e1-fixture.git' -SourceRevision ('a' * 40) -BaseRevision ('a' * 40) `
                -TrustedToolRoot $script:RepositoryRoot -DefineFunctionsOnly
            return [bool](Assert-StandardValidationFindings -Envelope ([pscustomobject]@{ findings = $Findings }) -Context 'reviewed E1 fixture')
        }.GetNewClosure()
        $mediumFinding = @($envelope.findings | Where-Object severity -CEq 'medium')
        (& $centralDecision $centralRunner $candidateRoot $applied.root $mediumFinding) | Should -BeTrue
        $highFinding = @($envelope.findings | Where-Object severity -CEq 'high')
        { & $centralDecision $centralRunner $candidateRoot $applied.root $highFinding } | Should -Throw '*contains a high finding*'

        # The same exact component inventory loses its baseline as soon as one reviewed byte changes.
        $driftComponent = Join-Path (Join-Path $skillsRoot $targetSkill) ([string]$baselineSkill.components[0].path).Replace('/', [IO.Path]::DirectorySeparatorChar)
        [IO.File]::WriteAllText($driftComponent, 'changed reviewed component bytes' + "`n", [Text.UTF8Encoding]::new($false))
        $driftRoot = Join-Path $root 'drift'
        New-Item -ItemType Directory -Path $driftRoot -Force | Out-Null
        $drift = Invoke-ReviewedE1Wrapper -WrapperPath $wrapper -ScenarioRoot $driftRoot -Scenario 'drift'
        $drift.exitCode | Should -Be 0 -Because $drift.stderr
        $driftEnvelope = $drift.stdout.Trim() | ConvertFrom-Json -Depth 80 -ErrorAction Stop
        @($driftEnvelope.findings).Count | Should -Be 1
        $driftEnvelope.findings[0].severity | Should -BeExactly 'medium'
        $driftNative = @($driftEnvelope.nativeReports | Where-Object { [string]$_.skillId -ceq $targetSkill })[0]
        $driftNative.reviewedBaseline.decision | Should -BeExactly 'component-hash-drift'
        $driftNative.reviewedBaseline.applied | Should -BeFalse
        $driftNative.reviewedBaseline.componentHashesMatched | Should -BeFalse
        $driftNative.reviewedBaseline.expectedSuppressedCount | Should -Be 0
        $driftNative.reviewedBaseline.actualSuppressedCount | Should -Be 0
        $driftArguments = [string[]]@($driftNative.arguments)
        $driftArguments | Should -Not -Contain '--baseline'
        $driftArguments | Should -Not -Contain '--show-suppressed'
        (& $centralDecision $centralRunner $candidateRoot $drift.root @($driftEnvelope.findings)) | Should -BeTrue

        # The suppression partition is exact: missing, unexpected, wrong-reason, and malformed rows fail closed.
        $tokens = $null; $parseErrors = $null
        $wrapperAst = [Management.Automation.Language.Parser]::ParseFile($wrapper, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $suppressionAst = $wrapperAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Assert-ReviewedE1SuppressionReport' }, $true)
        $suppressionAst | Should -Not -BeNullOrEmpty
        . ([scriptblock]::Create($suppressionAst.Extent.Text))
        $validSuppressionReport = [pscustomobject]@{
            metadata = [pscustomobject]@{ skillspector_version = '2.12.0' }
            suppressed_count = $reviewedRows.Count
            suppressed = @($reviewedRows.ToArray())
        }
        (Assert-ReviewedE1SuppressionReport -Report $validSuppressionReport -SkillPolicy $baselineSkill -ExpectedScannerVersion '2.12.0' -SkillId $targetSkill) | Should -Be 4
        $missingReport = [pscustomobject]@{ metadata = $validSuppressionReport.metadata; suppressed_count = 3; suppressed = @($reviewedRows.ToArray() | Select-Object -Skip 1) }
        { Assert-ReviewedE1SuppressionReport -Report $missingReport -SkillPolicy $baselineSkill -ExpectedScannerVersion '2.12.0' -SkillId $targetSkill } | Should -Throw '*suppression count differs*'
        $unexpectedRows = [Collections.Generic.List[object]]::new()
        foreach ($row in $reviewedRows.ToArray() | Select-Object -Skip 1) { $unexpectedRows.Add($row) }
        $firstRow = $reviewedRows[0]
        $unexpectedRows.Add([pscustomobject]@{
            id = [string]$firstRow.id; severity = [string]$firstRow.severity; finding = [string]$firstRow.finding
            location = [pscustomobject]@{ file = [string]$firstRow.location.file; start_line = 999 }
            suppressed = $true; suppression_reason = [string]$firstRow.suppression_reason
        })
        $unexpectedReport = [pscustomobject]@{ metadata = $validSuppressionReport.metadata; suppressed_count = 4; suppressed = @($unexpectedRows.ToArray()) }
        { Assert-ReviewedE1SuppressionReport -Report $unexpectedReport -SkillPolicy $baselineSkill -ExpectedScannerVersion '2.12.0' -SkillId $targetSkill } | Should -Throw '*unreviewed or duplicate occurrence*'
        $wrongReasonRows = @($reviewedRows.ToArray() | ForEach-Object { $_ })
        $wrongReasonRows[0] = [pscustomobject]@{
            id = [string]$reviewedRows[0].id; severity = [string]$reviewedRows[0].severity; finding = [string]$reviewedRows[0].finding
            location = [pscustomobject]@{ file = [string]$reviewedRows[0].location.file; start_line = [int]$reviewedRows[0].location.start_line }
            suppressed = $true; suppression_reason = 'candidate authored suppression reason'
        }
        $wrongReasonReport = [pscustomobject]@{ metadata = $validSuppressionReport.metadata; suppressed_count = 4; suppressed = $wrongReasonRows }
        { Assert-ReviewedE1SuppressionReport -Report $wrongReasonReport -SkillPolicy $baselineSkill -ExpectedScannerVersion '2.12.0' -SkillId $targetSkill } | Should -Throw '*structured reviewed E1/MEDIUM occurrence*'
        $malformedReport = [pscustomobject]@{ metadata = $validSuppressionReport.metadata; suppressed_count = 4; suppressed = 'not-an-array' }
        { Assert-ReviewedE1SuppressionReport -Report $malformedReport -SkillPolicy $baselineSkill -ExpectedScannerVersion '2.12.0' -SkillId $targetSkill } | Should -Throw '*malformed suppression ledger*'

        # The protected entry freezes the artifact at setup and replay; the wrapper exposes no caller-selected baseline path.
        $driverPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-ProtectedSourceValidation.ps1'
        $driverText = Get-Content -LiteralPath $driverPath -Raw -Encoding UTF8
        $driverText | Should -Match 'SkillSpectorReviewedE1Baselines\.json'
        @([regex]::Matches($driverText, [regex]::Escape("'scripts/SkillSpectorReviewedE1Baselines.json'"))).Count | Should -BeGreaterOrEqual 2
        $wrapperParameters = @($wrapperAst.ParamBlock.Parameters | ForEach-Object { [string]$_.Name.VariablePath.UserPath })
        $wrapperParameters | Should -Not -Contain 'ReviewedBaselinePath'

        # A copied protected wrapper detects tampering with the pinned raw policy bytes before scanning.
        $tamperRoot = Join-Path $root 'tampered-protected-driver'
        New-Item -ItemType Directory -Path $tamperRoot -Force | Out-Null
        foreach ($name in @('Invoke-CoreSourceTool.ps1', 'StandardCoreSourcePreparation.psm1', 'SkillSpectorReviewedE1Baselines.json')) {
            Copy-Item -LiteralPath (Join-Path (Join-Path $script:RepositoryRoot 'scripts') $name) -Destination (Join-Path $tamperRoot $name)
        }
        [IO.File]::AppendAllText((Join-Path $tamperRoot 'SkillSpectorReviewedE1Baselines.json'), "`n", [Text.UTF8Encoding]::new($false))
        $tampered = Invoke-ReviewedE1Wrapper -WrapperPath (Join-Path $tamperRoot 'Invoke-CoreSourceTool.ps1') -ScenarioRoot $appliedRoot -Scenario 'applied'
        $tampered.exitCode | Should -Be 1
        $tampered.stdout | Should -BeNullOrEmpty
        $tampered.stderr | Should -Match 'Protected reviewed E1 policy hash differs from the pinned review artifact'

        # Restore the pinned component after the drift case so suppression-ledger negatives reach partition validation.
        $firstComponentPath = [string]$baselineSkill.components[0].path
        $restorePath = Join-Path (Join-Path $skillsRoot $targetSkill) $firstComponentPath.Replace('/', [IO.Path]::DirectorySeparatorChar)
        [IO.File]::WriteAllBytes($restorePath, $reviewedFixtureBytes[$firstComponentPath])

        foreach ($negativeScenario in @(
            @{ Name = 'missing-suppression'; Error = 'suppression count differs' },
            @{ Name = 'malformed-suppression'; Error = 'missing or malformed suppression ledger' },
            @{ Name = 'unexpected-suppression'; Error = 'unreviewed or duplicate occurrence' }
        )) {
            $negativeRoot = Join-Path $root ('negative-' + $negativeScenario.Name)
            New-Item -ItemType Directory -Path $negativeRoot -Force | Out-Null
            $negative = Invoke-ReviewedE1Wrapper -WrapperPath $wrapper -ScenarioRoot $negativeRoot -Scenario $negativeScenario.Name
            $negative.exitCode | Should -Be 1 -Because $negative.stderr
            $negative.stdout | Should -BeNullOrEmpty
            $negative.stderr | Should -Match ([regex]::Escape([string]$negativeScenario.Error))
            $evidenceMatch = [regex]::Match($negative.stderr, 'report=(?<report>[^;]+\.json); rawStdout=(?<stdout>[^;]+\.stdout\.bin); rawStderr=(?<stderr>[^\s]+\.stderr\.bin)')
            $evidenceMatch.Success | Should -BeTrue -Because $negative.stderr
            foreach ($name in @('report', 'stdout', 'stderr')) { Test-Path -LiteralPath $evidenceMatch.Groups[$name].Value -PathType Leaf | Should -BeTrue }
            (Get-StandardCoreV2Sha256 -Path $evidenceMatch.Groups['report'].Value) | Should -BeExactly (Get-StandardCoreV2Sha256 -Path (Join-Path $negative.reportsRoot ($targetSkill + '.json')))
        }
    }

    It 'UnitT50_Rejects_long_native_json_paths_and_preserves_baseline_bytes' {
        # Scenario: The native scanner receives short run-owned outputs from a deep artifact working directory.
        # Purpose: Keep paths within Windows MAX_PATH while preserving exact baseline bytes and CreateNew semantics.
        $wrapper = Join-Path $script:RepositoryRoot 'scripts/Invoke-CoreSourceTool.ps1'
        $tokens = $null
        $parseErrors = $null
        $wrapperAst = [Management.Automation.Language.Parser]::ParseFile($wrapper, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0

        $functionAsts = @{}
        foreach ($name in @('Get-FileSha256', 'New-RunOwnedNativeJsonPath', 'Write-ReviewedE1NativeBaseline')) {
            $functionAst = $wrapperAst.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
            }, $true)
            $functionAst | Should -Not -BeNullOrEmpty -Because "the protected source tool should define $name"
            $functionAsts[$name] = $functionAst
            . ([scriptblock]::Create($functionAst.Extent.Text))
        }

        $functionAsts['Write-ReviewedE1NativeBaseline'].Extent.Text | Should -Match '\[IO\.File\]::Open\(\$path,\s*\[IO\.FileMode\]::CreateNew'

        $testDrivePath = [IO.Path]::GetFullPath($TestDrive)
        $segmentLength = 216 - $testDrivePath.Length - 1
        ($segmentLength -gt 0 -and $segmentLength -le 240) | Should -BeTrue -Because 'the real long working directory should fit within a single Windows path segment'
        $longWorkingDirectory = Join-Path $testDrivePath ('d' * $segmentLength)
        [void][IO.Directory]::CreateDirectory($longWorkingDirectory)
        $longWorkingDirectory.Length | Should -Be 216

        Push-Location -LiteralPath $longWorkingDirectory
        try {
            $reportPath = New-RunOwnedNativeJsonPath -Prefix 's'
            $reportPath.Length | Should -Be 256
            $reportPath | Should -Match ([regex]::Escape($longWorkingDirectory) + '\\s-[0-9a-f]{32}\.json$')
            Test-Path -LiteralPath $reportPath | Should -BeFalse

            $skillPolicy = [pscustomobject]@{
                skillId = 'probe'
                baseline = [ordered]@{ version = 2; scanner_version = '2.12.0'; rules = @(); fingerprints = @() }
            }
            $written = Write-ReviewedE1NativeBaseline -SkillPolicy $skillPolicy
            $written.path.Length | Should -Be 256
            $written.path | Should -Match ([regex]::Escape($longWorkingDirectory) + '\\b-[0-9a-f]{32}\.json$')
            $expectedJson = $skillPolicy.baseline | ConvertTo-Json -Depth 80 -Compress
            $expectedBytes = [Text.UTF8Encoding]::new($false).GetBytes($expectedJson + [char]10)
            $actualBytes = [IO.File]::ReadAllBytes($written.path)
            [Convert]::ToBase64String($actualBytes) | Should -BeExactly ([Convert]::ToBase64String($expectedBytes))
            (Get-FileSha256 -Path $written.path) | Should -BeExactly $written.sha256

            $collisionNonce = 'a' * 32
            $collisionPath = Join-Path $longWorkingDirectory ("b-$collisionNonce.json")
            [IO.File]::WriteAllText($collisionPath, 'occupied', [Text.UTF8Encoding]::new($false))
            { New-RunOwnedNativeJsonPath -Prefix 'b' -WorkingDirectory $longWorkingDirectory -Nonce $collisionNonce } |
                Should -Throw '*already exists*'
        } finally {
            Pop-Location
        }

        if ($IsWindows) {
            $limitWorkingDirectory = 'C:\' + ('l' * 216)
            $limitPath = New-RunOwnedNativeJsonPath -Prefix 's' -WorkingDirectory $limitWorkingDirectory -Nonce ('0' * 32)
            $limitPath.Length | Should -Be 259
            $tooLongWorkingDirectory = 'C:\' + ('l' * 217)
            { New-RunOwnedNativeJsonPath -Prefix 's' -WorkingDirectory $tooLongWorkingDirectory -Nonce ('1' * 32) } |
                Should -Throw '*exceeds the Windows MAX_PATH limit*'
        }
    }

    It 'UnitT51_Binds_critical_candidate_launchers_to_protected_event_base_bytes' {
        # Scenario: A prepared source commit is checked against exact files copied from the protected event-base driver.
        # Purpose: Refuse candidate-owned General/Pester launchers or direct loader modules that counterfeit a successful core result.
        $modulePath = Join-Path $script:RepositoryRoot 'scripts/StandardCoreSourcePreparation.psm1'
        $tokens = $null
        $parseErrors = $null
        $moduleAst = [Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $pinAst = $moduleAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Assert-StandardCoreV2ProtectedCandidateFiles'
        }, $true)
        $pinAst | Should -Not -BeNullOrEmpty -Because 'the protected driver must expose raw candidate-to-driver byte verification'
        . ([scriptblock]::Create($pinAst.Extent.Text))

        $fixture = New-CoreV2GitFixture -NoClone
        $trustedRoot = Join-Path $TestDrive ('protected-driver-' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($trustedRoot)
        $trustedProbe = Join-Path $trustedRoot 'trusted-probe.txt'
        [IO.File]::WriteAllBytes($trustedProbe, [byte[]]$fixture.RawBytes)
        $pinnedFile = [pscustomobject]@{
            candidatePath = 'probe.txt'
            protectedPath = $trustedProbe
            expectedMode = '100755'
            expectedSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$fixture.RawBytes)).ToLowerInvariant()
        }

        { Assert-StandardCoreV2ProtectedCandidateFiles -GitPath $script:GitPath -CandidateRoot $fixture.CandidateRoot `
                -ExpectedRevision $fixture.Revision -ProtectedFiles @($pinnedFile) } | Should -Not -Throw

        $changedBytes = [Text.UTF8Encoding]::new($false).GetBytes("changed commit bytes`n")
        [IO.File]::WriteAllBytes((Join-Path $fixture.SourceRoot 'probe.txt'), $changedBytes)
        Invoke-CoreV2TestGit -RepositoryRoot $fixture.SourceRoot -Arguments @('add', '--', 'probe.txt') | Out-Null
        Invoke-CoreV2TestGit -RepositoryRoot $fixture.SourceRoot -Arguments @('commit', '--quiet', '-m', 'changed protected candidate bytes') | Out-Null
        $changedRevision = ([string]@(Invoke-CoreV2TestGit -RepositoryRoot $fixture.SourceRoot -Arguments @('rev-parse', 'HEAD'))[-1]).Trim()
        $changedCandidate = New-CoreV2ManualRawCandidate -RepositoryRoot $fixture.SourceRoot -Revision $changedRevision `
            -Destination (Join-Path $fixture.OwnedRoot 'candidate-changed')
        { Assert-StandardCoreV2ProtectedCandidateFiles -GitPath $script:GitPath -CandidateRoot $changedCandidate.Root `
                -ExpectedRevision $changedRevision -ProtectedFiles @($pinnedFile) } | Should -Throw '*Protected candidate bytes differ from protected driver bytes*'

        [IO.File]::WriteAllBytes((Join-Path $fixture.SourceRoot 'probe.txt'), [byte[]]$fixture.RawBytes)
        Invoke-CoreV2TestGit -RepositoryRoot $fixture.SourceRoot -Arguments @('add', '--', 'probe.txt') | Out-Null
        Invoke-CoreV2TestGit -RepositoryRoot $fixture.SourceRoot -Arguments @('update-index', '--chmod=-x', '--', 'probe.txt') | Out-Null
        Invoke-CoreV2TestGit -RepositoryRoot $fixture.SourceRoot -Arguments @('commit', '--quiet', '-m', 'changed protected candidate mode') | Out-Null
        $modeRevision = ([string]@(Invoke-CoreV2TestGit -RepositoryRoot $fixture.SourceRoot -Arguments @('rev-parse', 'HEAD'))[-1]).Trim()
        $modeCandidate = New-CoreV2ManualRawCandidate -RepositoryRoot $fixture.SourceRoot -Revision $modeRevision `
            -Destination (Join-Path $fixture.OwnedRoot 'candidate-mode-changed')
        { Assert-StandardCoreV2ProtectedCandidateFiles -GitPath $script:GitPath -CandidateRoot $modeCandidate.Root `
                -ExpectedRevision $modeRevision -ProtectedFiles @($pinnedFile) } | Should -Throw '*Protected candidate mode differs from protected driver mode*'

        [IO.File]::AppendAllText($trustedProbe, 'tampered', [Text.UTF8Encoding]::new($false))
        { Assert-StandardCoreV2ProtectedCandidateFiles -GitPath $script:GitPath -CandidateRoot $fixture.CandidateRoot `
                -ExpectedRevision $fixture.Revision -ProtectedFiles @($pinnedFile) } | Should -Throw '*differ from protected driver bytes*'

        $driverPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-ProtectedSourceValidation.ps1'
        $driverText = Get-Content -LiteralPath $driverPath -Raw -Encoding UTF8
        foreach ($relativePath in @(
            'scripts/Invoke-CoreRepositoryGeneral.ps1',
            'scripts/Invoke-CorePester.ps1',
            'scripts/CorePesterIntegrity.psm1',
            'scripts/StandardCoreSourcePreparation.psm1'
        )) {
            $driverText | Should -Match ([regex]::Escape($relativePath))
        }
        @([regex]::Matches($driverText, [regex]::Escape('New-ProtectedCandidateFilePins'))).Count | Should -BeGreaterOrEqual 3
    }

    It 'UnitT52_Reconstructs_protected_raw_driver_copies_from_CRLF_worktrees' {
        # Scenario: A protected event-base checkout has CRLF worktree bytes while Git stores LF blobs.
        # Purpose: Materialize and revalidate trusted driver copies from raw Git blobs without weakening dirty-source checks.
        $driverPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-ProtectedSourceValidation.ps1'
        $driverTokens = $null
        $driverErrors = $null
        $driverAst = [Management.Automation.Language.Parser]::ParseFile($driverPath, [ref]$driverTokens, [ref]$driverErrors)
        @($driverErrors).Count | Should -Be 0
        foreach ($functionName in @('Get-Sha', 'Test-PathEqual', 'Get-Revision', 'New-ProtectedEventBaseDriverFiles')) {
            $targetFunctionName = $functionName
            $functionAst = $driverAst.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $targetFunctionName
            }, $true)
            $functionAst | Should -Not -BeNullOrEmpty -Because "the protected driver must define $functionName"
            . ([scriptblock]::Create($functionAst.Extent.Text))
        }

        $repositoryRoot = Join-Path $TestDrive ('protected-event-base-' + [guid]::NewGuid().ToString('N'))
        $scriptsRoot = Join-Path $repositoryRoot 'scripts'
        New-Item -ItemType Directory -Path $scriptsRoot -Force | Out-Null
        Invoke-CoreV2TestGit -RepositoryRoot $repositoryRoot -Arguments @('init', '--quiet') | Out-Null
        Invoke-CoreV2TestGit -RepositoryRoot $repositoryRoot -Arguments @('config', 'user.name', 'Core v2 protected driver fixture') | Out-Null
        Invoke-CoreV2TestGit -RepositoryRoot $repositoryRoot -Arguments @('config', 'user.email', 'core-v2-driver@example.invalid') | Out-Null
        Invoke-CoreV2TestGit -RepositoryRoot $repositoryRoot -Arguments @('config', 'core.autocrlf', 'true') | Out-Null
        $relativePath = 'scripts/RawFixture.ps1'
        [IO.File]::WriteAllText((Join-Path $repositoryRoot '.gitattributes'), 'scripts/*.ps1 text eol=lf' + "`n", [Text.UTF8Encoding]::new($false))
        $rawBytes = [Text.UTF8Encoding]::new($false).GetBytes("Write-Output 'raw fixture'`n")
        $sourcePath = Join-Path $scriptsRoot 'RawFixture.ps1'
        [IO.File]::WriteAllBytes($sourcePath, $rawBytes)
        Invoke-CoreV2TestGit -RepositoryRoot $repositoryRoot -Arguments @('add', '--', '.gitattributes', $relativePath) | Out-Null
        Invoke-CoreV2TestGit -RepositoryRoot $repositoryRoot -Arguments @('commit', '--quiet', '-m', 'protected driver raw blob') | Out-Null
        $revision = ([string]@(Invoke-CoreV2TestGit -RepositoryRoot $repositoryRoot -Arguments @('rev-parse', 'HEAD'))[-1]).Trim()

        $crlfBytes = [Text.UTF8Encoding]::new($false).GetBytes("Write-Output 'raw fixture'`r`n")
        [IO.File]::WriteAllBytes($sourcePath, $crlfBytes)
        $normalizedDiff = Invoke-StandardCoreV2GitText -GitPath $script:GitPath `
            -Arguments @('-C', $repositoryRoot, 'diff', '--quiet', $revision, '--', $relativePath) -AllowedExitCodes @(0,1)
        $normalizedDiff.ExitCode | Should -Be 0 -Because 'Git clean conversion treats the CRLF checkout as the same protected source'
        $rawBlobSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($rawBytes)).ToLowerInvariant()
        (Get-Sha $sourcePath) | Should -Not -Be $rawBlobSha -Because 'the old worktree-byte comparison would reject this legitimate CRLF checkout'

        $destinationRoot = Join-Path $TestDrive ('protected-driver-copy-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $destinationRoot | Out-Null
        $materialized = New-ProtectedEventBaseDriverFiles -GitPath $script:GitPath -ProtectedRepositoryRoot $repositoryRoot `
            -SourceScriptsRoot $scriptsRoot -DestinationRoot $destinationRoot -DriverNames @('RawFixture.ps1')
        [IO.File]::ReadAllBytes((Join-Path $destinationRoot 'RawFixture.ps1')) | Should -Be $rawBytes
        $expectedSha = $rawBlobSha
        $materialized[0].sha256 | Should -Be $expectedSha
        $validated = New-ProtectedEventBaseDriverFiles -GitPath $script:GitPath -ProtectedRepositoryRoot $repositoryRoot `
            -SourceScriptsRoot $scriptsRoot -DestinationRoot $destinationRoot -DriverNames @('RawFixture.ps1') -ValidateOnly
        $validated[0].sha256 | Should -Be $expectedSha

        [IO.File]::WriteAllText($sourcePath, "Write-Output 'tampered fixture'`n", [Text.UTF8Encoding]::new($false))
        { New-ProtectedEventBaseDriverFiles -GitPath $script:GitPath -ProtectedRepositoryRoot $repositoryRoot `
                -SourceScriptsRoot $scriptsRoot -DestinationRoot $destinationRoot -DriverNames @('RawFixture.ps1') -ValidateOnly } |
            Should -Throw '*uncommitted content or mode changes*'
    }

    It 'UnitT63_Uses_the_trusted_documented_driver_when_the_candidate_public_entry_is_tampered' {
        # Scenario: A candidate public Validate.ps1 is replaced with a sentinel writer while the trusted protected driver is launched directly.
        # Purpose: Keep the documented PR19 path anchored to the reviewed driver checkout and prove it fails closed on missing run registration before candidate use; this does not claim whole-pipeline success.
        $readme = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'README.md') -Raw -Encoding UTF8
        $sectionMatch = [regex]::Match($readme, '(?ms)^### Dormant Standard Core v2 source preparation\s*(?<section>.*?)(?=^## Source metadata)')
        $sectionMatch.Success | Should -BeTrue -Because 'the README must retain the dormant protected-driver instructions'
        $section = $sectionMatch.Groups['section'].Value
        $codeBlocks = [regex]::Matches($section, '(?s)```powershell\s*(.*?)```')
        $commands = [string]::Join("`n", @($codeBlocks | ForEach-Object { $_.Groups[1].Value }))
        $commands | Should -Match '\$protectedDriver\s*=\s*Join-Path\s+\$trustedDriverCheckout\s+''scripts/Invoke-ProtectedSourceValidation\.ps1'''
        $commands | Should -Match '(?s)-File\s+\$protectedDriver.*?-Mode\s+PrepareSourceTools'
        $commands | Should -Match '(?s)-File\s+\$protectedDriver.*?-Mode\s+SourceValidation'
        $commands | Should -Not -Match '(?i)-File\s+[^\r\n]*[/\\]Validate\.ps1\b'
        $commands | Should -Match '\$pwsh\s*=\s*Join-Path\s+\$trustedToolRoot\s+''pwsh\.exe'''
        $commands | Should -Match 'Get-FileHash.*runtimeArchivePath.*SHA256'
        $commands | Should -Match 'Expand-Archive.*runtimeArchivePath.*trustedToolRoot'
        $section | Should -Match 'driver revision and candidate source revision are intentionally the same commit'
        $section | Should -Match 'actual PR diff base'

        $root = Join-Path ([IO.Path]::GetTempPath()) ('s304-t63-' + [guid]::NewGuid().ToString('N'))
        $candidateScripts = Join-Path $root 'candidate/scripts'
        $artifactsRoot = Join-Path $root 'artifacts'
        $trustedToolRoot = Join-Path $root 'trusted-tools'
        $sentinel = Join-Path $root 'candidate-public-entry-invoked.txt'
        New-Item -ItemType Directory -Path $candidateScripts,$artifactsRoot,$trustedToolRoot -Force | Out-Null
        try {
            $sentinelLiteral = ConvertTo-Json -InputObject $sentinel -Compress
            [IO.File]::WriteAllText((Join-Path $candidateScripts 'Validate.ps1'),
                "[IO.File]::WriteAllText($sentinelLiteral, 'candidate entry executed'); exit 94`n",
                [Text.UTF8Encoding]::new($false))

            $trustedDriver = Join-Path $script:RepositoryRoot 'scripts/Invoke-ProtectedSourceValidation.ps1'
            $runtime = [IO.Path]::GetFullPath([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
            $start = [Diagnostics.ProcessStartInfo]::new()
            $start.FileName = $runtime
            $start.UseShellExecute = $false
            $start.CreateNoWindow = $true
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            $start.WorkingDirectory = $root
            $start.Environment.Clear()
            foreach ($name in @('SystemRoot','WINDIR','PATH','PATHEXT','TEMP','TMP','TMPDIR','USERPROFILE','COMSPEC','ProgramFiles','ProgramFiles(x86)','ProgramW6432')) {
                $value = [Environment]::GetEnvironmentVariable($name)
                if (-not [string]::IsNullOrWhiteSpace($value)) { $start.Environment[$name] = $value }
            }
            foreach ($name in @('RUN_OWNED_ROOT','STANDARD_VALIDATION_RUN_OWNED_ROOT')) { [void]$start.Environment.Remove($name) }
            foreach ($argument in @(
                '-NoProfile','-NonInteractive','-File',$trustedDriver,
                '-Mode','PrepareSourceTools',
                '-RepositoryRoot',(Join-Path $root 'candidate'),
                '-ArtifactsRoot',$artifactsRoot,
                '-AuthorityRepositoryRoot',$script:RepositoryRoot,
                '-TrustedToolRoot',$trustedToolRoot,
                '-SourceToolsPath',(Join-Path $artifactsRoot 'source-tools-plan.json'),
                '-BaseCommit',('a' * 40)
            )) { [void]$start.ArgumentList.Add([string]$argument) }

            $process = [Diagnostics.Process]::new()
            $process.StartInfo = $start
            try {
                $process.Start() | Should -BeTrue
                $stdoutTask = $process.StandardOutput.ReadToEndAsync()
                $stderrTask = $process.StandardError.ReadToEndAsync()
                if (-not $process.WaitForExit(90000)) { $process.Kill($true); $process.WaitForExit(); throw 'Trusted event-base driver fixture timed out.' }
                $stdout = $stdoutTask.GetAwaiter().GetResult()
                $stderr = $stderrTask.GetAwaiter().GetResult()
                $process.ExitCode | Should -Be 1 -Because "the trusted driver should stop at the absent run-owned-root registration; stdout=$stdout stderr=$stderr"
                $stderr | Should -Match 'TrustedToolRoot must equal the workflow-registered RUN_OWNED_ROOT'
            }
            finally { $process.Dispose() }
            Test-Path -LiteralPath $sentinel | Should -BeFalse -Because 'the directly invoked trusted driver must not execute the tampered candidate public entry'
        }
        finally {
            $resolvedRoot = [IO.Path]::GetFullPath($root)
            $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
            $rootName = [IO.Path]::GetFileName($resolvedRoot)
            if ($rootName.StartsWith('s304-t63-', [StringComparison]::Ordinal) -and
                $resolvedRoot.StartsWith($resolvedTemp + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and
                (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
                Remove-Item -LiteralPath $resolvedRoot -Recurse -Force -ErrorAction Stop
            }
        }
    }

    It 'UnitT53_Projects_strict_skill_tools_SARIF_notes_and_rejects_ambiguous_results' {
        # Scenario: skill-tools returns SARIF diagnostics with rule metadata, optional indices, and candidate paths.
        # Purpose: Preserve informational diagnostics while rejecting unknown levels and inconsistent rule references.
        $root = Join-Path $TestDrive ('skill-tools-sarif-' + [guid]::NewGuid().ToString('N'))
        $candidateRoot = Join-Path $root 'candidate'
        $skillsRoot = Join-Path $candidateRoot 'skills'
        $skillId = 'fixture-skill'
        $skillRoot = Join-Path $skillsRoot $skillId
        New-Item -ItemType Directory -Path (Join-Path $skillRoot 'references') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $skillRoot 'SKILL.md'), 'fixture skill', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $skillRoot 'references/nested.md'), 'fixture reference', [Text.UTF8Encoding]::new($false))

        $runtime = [IO.Path]::GetFullPath([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
        $wrapper = Join-Path $script:RepositoryRoot 'scripts/Invoke-CoreSourceTool.ps1'
        $centralRunner = Join-Path $script:RepositoryRoot 'scripts/Invoke-StandardValidation.ps1'
        $centralTokens = $null
        $centralErrors = $null
        $centralAst = [Management.Automation.Language.Parser]::ParseFile($centralRunner, [ref]$centralTokens, [ref]$centralErrors)
        @($centralErrors).Count | Should -Be 0
        foreach ($name in @(
            'Get-StandardValidationRequiredProperty',
            'Get-StandardValidationTextSha256',
            'Test-StandardValidationCanonicalSeverity',
            'Convert-StandardValidationFindingsToCanonicalJson'
        )) {
            $targetName = $name
            $functionAst = $centralAst.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $targetName
            }, $true)
            $functionAst | Should -Not -BeNullOrEmpty -Because "the central validator must define $name"
            . ([scriptblock]::Create($functionAst.Extent.Text))
        }
        $entry = Join-Path $root 'fake-skill-tools.ps1'
        $entrySource = @'
param([string]$Command, [string]$SkillRoot)
$json = [Environment]::GetEnvironmentVariable('SYP304_FIXTURE_SARIF', 'Process')
if ([string]::IsNullOrWhiteSpace($json)) { exit 91 }
[Console]::Out.Write($json)
exit 0
'@
        [IO.File]::WriteAllText($entry, $entrySource, [Text.UTF8Encoding]::new($false))
        $rows = [Collections.Generic.List[object]]::new()

        foreach ($scenario in @('valid-note', 'multiple-notes', 'no-findings', 'empty-rules', 'blocking-warning', 'unknown-level', 'mismatched-rule-index', 'unknown-rule')) {
            $scenarioRoot = Join-Path $root $scenario
            New-Item -ItemType Directory -Path $scenarioRoot -Force | Out-Null
            $rules = @(
                [ordered]@{ id='RULE-NOTE'; defaultConfiguration=[ordered]@{ level='note' } },
                [ordered]@{ id='RULE-WARNING'; defaultConfiguration=[ordered]@{ level='warning' } }
            )
            $result = [ordered]@{
                ruleId = 'RULE-NOTE'
                message = [ordered]@{ text='A stable informational diagnostic.' }
                locations = @([ordered]@{ physicalLocation=[ordered]@{ artifactLocation=[ordered]@{ uri='references/nested.md' } } })
                partialFingerprints = [ordered]@{ 'skill-tools/v1'='stable-note-fingerprint' }
            }
            $results = @($result)
            switch ($scenario) {
                'multiple-notes' { $result.locations += [ordered]@{ physicalLocation=[ordered]@{ artifactLocation=[ordered]@{ uri='SKILL.md' } } } }
                'no-findings' { $result.level='none'; $result.Remove('locations') }
                'empty-rules' { $rules=@(); $results=[object[]]@() }
                'blocking-warning' { $result.ruleId='RULE-WARNING'; $result.level='warning' }
                'unknown-level' { $result.level='NOTE' }
                'mismatched-rule-index' { $result.ruleIndex=1 }
                'unknown-rule' { $result.ruleId='RULE-MISSING'; $result.level='note' }
            }
            $sarif = [ordered]@{
                version='2.1.0'
                runs=@([ordered]@{ tool=[ordered]@{ driver=[ordered]@{ name='skill-tools'; rules=$rules } }; results=$results })
            }
            $toolchain = [ordered]@{
                skillToolsNodePath=$runtime
                skillToolsNodeSha256=(Get-StandardCoreV2Sha256 -Path $runtime)
                skillToolsEntryPointPath=$entry
                skillToolsEntryPointSha256=(Get-StandardCoreV2Sha256 -Path $entry)
            }
            $toolchainPath = Join-Path $scenarioRoot 'toolchain.json'
            [IO.File]::WriteAllText($toolchainPath, ($toolchain | ConvertTo-Json -Depth 30 -Compress), [Text.UTF8Encoding]::new($false))

            $start = [Diagnostics.ProcessStartInfo]::new()
            $start.FileName=$runtime; $start.UseShellExecute=$false; $start.CreateNoWindow=$true
            $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true; $start.WorkingDirectory=$scenarioRoot
            $start.Environment.Clear()
            foreach ($name in @('SystemRoot','WINDIR','PATH','PATHEXT','TEMP','TMP','TMPDIR','USERPROFILE','COMSPEC','ProgramFiles','ProgramFiles(x86)','ProgramW6432')) {
                $value=[Environment]::GetEnvironmentVariable($name); if(-not [string]::IsNullOrWhiteSpace($value)){$start.Environment[$name]=$value}
            }
            $start.Environment['STANDARD_VALIDATION_CANDIDATE_ROOT']=$candidateRoot
            $start.Environment['STANDARD_VALIDATION_CANDIDATE_ID']='sarif-fixture-candidate'
            $start.Environment['STANDARD_VALIDATION_ACTIVE_SKILLS']=$skillId
            $start.Environment['STANDARD_VALIDATION_SKILLS_ROOT']=$skillsRoot
            $start.Environment['STANDARD_VALIDATION_SKILL_ID']=$skillId
            $start.Environment['STANDARD_VALIDATION_SKILL_INVENTORY_SHA256']='b'*64
            $start.Environment['SYP304_FIXTURE_SARIF']=$sarif | ConvertTo-Json -Depth 30 -Compress
            foreach ($argument in @('-NoProfile','-NonInteractive','-File',$wrapper,'-Mode','skill-tools','-ToolchainPath',$toolchainPath,'-ToolchainSha256',(Get-StandardCoreV2Sha256 -Path $toolchainPath))) {
                [void]$start.ArgumentList.Add([string]$argument)
            }
            $process=[Diagnostics.Process]::new(); $process.StartInfo=$start
            try {
                $process.Start() | Should -BeTrue
                $stdoutTask=$process.StandardOutput.ReadToEndAsync(); $stderrTask=$process.StandardError.ReadToEndAsync()
                if(-not $process.WaitForExit(90000)){$process.Kill($true);$process.WaitForExit();throw "SARIF fixture timed out: $scenario"}
                $stdout=$stdoutTask.GetAwaiter().GetResult(); $stderr=$stderrTask.GetAwaiter().GetResult()
                if($scenario -in @('valid-note','multiple-notes','no-findings','empty-rules')) {
                    $process.ExitCode | Should -Be 0 -Because "scenario=$scenario; stderr=$stderr"
                    $envelope=$stdout.Trim() | ConvertFrom-Json -Depth 60
                    $expectedFindingCount = switch ($scenario) { 'multiple-notes' { 2 } { $_ -in @('no-findings','empty-rules') } { 0 } default { 1 } }
                    $envelope.findings -is [array] | Should -BeTrue -Because 'the report envelope must always carry an array for findings'
                    @($envelope.findings).Count | Should -Be $expectedFindingCount
                    foreach($finding in @($envelope.findings)) {
                        $finding -is [array] | Should -BeFalse -Because 'each envelope finding must be a structured finding object, not a nested array'
                        $finding.severity | Should -BeExactly 'informational'
                        $finding.fingerprint | Should -Not -BeNullOrEmpty
                        $finding.ruleId | Should -BeExactly 'RULE-NOTE'
                        $finding.message | Should -BeExactly 'A stable informational diagnostic.'
                        $finding.path | Should -Match '^skills/fixture-skill/(?:SKILL\.md|references/nested\.md)$'
                    }
                    if($scenario -eq 'valid-note') { $envelope.findings[0].fingerprint | Should -BeExactly 'stable-note-fingerprint' }
                    $canonical = Convert-StandardValidationFindingsToCanonicalJson -Findings ([object[]]$envelope.findings) -Context 'skill-tools SARIF fixture'
                    @($canonical.values).Count | Should -Be $expectedFindingCount
                    @($envelope.nativeReports).Count | Should -Be 1
                    $nativePath=[string]$envelope.nativeReports[0].path
                    (Get-StandardCoreV2Sha256 -Path $nativePath) | Should -BeExactly ([string]$envelope.nativeReports[0].sha256)
                } elseif ($scenario -eq 'blocking-warning') {
                    $process.ExitCode | Should -Be 1
                    $stdout | Should -BeNullOrEmpty
                    $stderr | Should -Match 'blocking'
                } else {
                    $process.ExitCode | Should -Be 1 -Because "scenario=$scenario stdout=$stdout stderr=$stderr"
                    $stdout | Should -BeNullOrEmpty
                }
                $rows.Add([pscustomobject]@{scenario=$scenario;exitCode=$process.ExitCode;stdout=$stdout;stderr=$stderr})
            } finally { $process.Dispose() }
        }
        $rows.Count | Should -Be 8
    }

    It 'UnitT54_Validates_candidate_paths_even_for_SARIF_none_results' {
        # Scenario: skill-tools includes a nonfinding result with a file location outside the frozen Skill inventory.
        # Purpose: Check every supplied native path even when SARIF level none is omitted from canonical findings.
        $wrapper = Join-Path $script:RepositoryRoot 'scripts/Invoke-CoreSourceTool.ps1'
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($wrapper, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        foreach ($name in @('Test-PathWithin', 'Resolve-CandidateFile', 'Convert-SkillToolsSarifFindings')) {
            $targetName = $name
            $functionAst = $ast.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $targetName
            }, $true)
            $functionAst | Should -Not -BeNullOrEmpty -Because "the source tool wrapper must define $name"
            . ([scriptblock]::Create($functionAst.Extent.Text))
        }

        $skillRoot = Join-Path $TestDrive 'sarif-none-path-skill'
        New-Item -ItemType Directory -Path $skillRoot -Force | Out-Null
        $report = [pscustomobject]@{
            runs = @([pscustomobject]@{
                tool = [pscustomobject]@{ driver = [pscustomobject]@{
                    rules = @([pscustomobject]@{ id='RULE-NONE'; defaultConfiguration=[pscustomobject]@{ level='none' } })
                } }
                results = @([pscustomobject]@{
                    ruleId='RULE-NONE'; level='none'
                    locations=@([pscustomobject]@{ physicalLocation=[pscustomobject]@{ artifactLocation=[pscustomobject]@{ uri='../outside.md' } } })
                })
            })
        }
        { Convert-SkillToolsSarifFindings -Report $report -SkillRoot $skillRoot -SkillId 'fixture-skill' -Inventory @('SKILL.md') } |
            Should -Throw '*escaped its candidate Skill*'
    }

    It 'UnitT55_Preserves_skill_validator_info_as_canonical_informational_findings' {
        # Scenario: A clean validator report contains pass rows and informational rows with and without file paths.
        # Purpose: Keep useful validator info visible while validating any reported file against the frozen inventory.
        $wrapper = Join-Path $script:RepositoryRoot 'scripts/Invoke-CoreSourceTool.ps1'
        $tokens = $null; $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($wrapper, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        foreach ($name in @('Test-PathWithin', 'Resolve-CandidateFile', 'Convert-SkillValidatorFindings')) {
            $targetName = $name
            $functionAst = $ast.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $targetName
            }, $true)
            $functionAst | Should -Not -BeNullOrEmpty -Because "the source tool wrapper must define $name"
            . ([scriptblock]::Create($functionAst.Extent.Text))
        }

        $skillRoot = Join-Path $TestDrive 'skill-validator-info-skill'
        New-Item -ItemType Directory -Path $skillRoot -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $skillRoot 'SKILL.md'), 'fixture', [Text.UTF8Encoding]::new($false))
        $results = @(
            [pscustomobject]@{ level = 'pass'; category = 'passed-check'; message = 'Passed'; file = 'SKILL.md' },
            [pscustomobject]@{ level = 'info'; category = 'document-hint'; message = 'Helpful information'; file = 'SKILL.md' },
            [pscustomobject]@{ level = 'info'; category = 'general-hint'; message = 'No file location' }
        )
        $findings = @(Convert-SkillValidatorFindings -Results $results -SkillRoot $skillRoot -SkillId 'fixture-skill' -Inventory @('SKILL.md'))
        $findings.Count | Should -Be 2
        $findings[0].severity | Should -BeExactly 'informational'
        $findings[0].fingerprint | Should -Match '^[0-9a-f]{64}$'
        $findings[0].ruleId | Should -BeExactly 'document-hint'
        $findings[0].message | Should -BeExactly 'Helpful information'
        $findings[0].path | Should -BeExactly 'skills/fixture-skill/SKILL.md'
        $findings[1].severity | Should -BeExactly 'informational'
        $findings[1].path | Should -BeNullOrEmpty
        (Convert-SkillValidatorFindings -Results $results -SkillRoot $skillRoot -SkillId 'fixture-skill' -Inventory @('SKILL.md'))[0].fingerprint |
            Should -BeExactly $findings[0].fingerprint

        $unknownLevel = @([pscustomobject]@{ level = 'INFO'; category = 'unknown'; message = 'Unknown case'; file = 'SKILL.md' })
        { Convert-SkillValidatorFindings -Results $unknownLevel -SkillRoot $skillRoot -SkillId 'fixture-skill' -Inventory @('SKILL.md') } |
            Should -Throw '*unknown or malformed level*'
        $outsidePath = @([pscustomobject]@{ level = 'info'; category = 'outside'; message = 'Outside'; file = '../outside.md' })
        { Convert-SkillValidatorFindings -Results $outsidePath -SkillRoot $skillRoot -SkillId 'fixture-skill' -Inventory @('SKILL.md') } |
            Should -Throw '*escaped its candidate Skill*'
    }

    It 'UnitT56_Bounds_native_stdout_and_stderr_and_terminates_the_process_tree' {
        # Scenario: a real child fills one redirected stream past the source-tool evidence cap and leaves a sleeping descendant.
        # Purpose: Keep bounded raw prefixes, record overflow, and terminate the complete native process tree promptly.
        $fixtureRoot = Join-Path $TestDrive ('native-bounds-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
        $runtime = [IO.Path]::GetFullPath([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
        $wrapperPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-CoreSourceTool.ps1'
        $modulePath = Join-Path $script:RepositoryRoot 'scripts/StandardCoreSourcePreparation.psm1'
        $floodPath = Join-Path $fixtureRoot 'flood-native-output.ps1'
        $harnessPath = Join-Path $fixtureRoot 'invoke-native-capture.ps1'
        $floodSource = @'
param([ValidateSet('stdout','stderr')][string]$StreamName, [string]$ChildMarker)
$ErrorActionPreference = 'Stop'
$runtime = [IO.Path]::GetFullPath([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$childStart = [Diagnostics.ProcessStartInfo]::new()
$childStart.FileName = $runtime
$childStart.UseShellExecute = $false
$childStart.CreateNoWindow = $true
foreach ($argument in @('-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 90')) { [void]$childStart.ArgumentList.Add($argument) }
$descendant = [Diagnostics.Process]::Start($childStart)
$identity = [ordered]@{ processId = [int]$descendant.Id; startTimeUtcTicks = [long]$descendant.StartTime.ToUniversalTime().Ticks }
[IO.File]::WriteAllText($ChildMarker, ($identity | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
$stream = if ($StreamName -ceq 'stdout') { [Console]::OpenStandardOutput() } else { [Console]::OpenStandardError() }
$buffer = [byte[]]::new(65536)
[Array]::Fill($buffer, [byte]0x58)
$bytesToWrite = 33L * 1024L * 1024L
$written = 0L
while ($written -lt $bytesToWrite) {
    $count = [int][Math]::Min([long]$buffer.Length, $bytesToWrite - $written)
    $stream.Write($buffer, 0, $count)
    $written += $count
}
$stream.Flush()
Start-Sleep -Seconds 90
'@
        $harnessSource = @'
param([string]$WrapperPath, [string]$ModulePath, [string]$FloodPath, [string]$StreamName, [string]$ChildMarker)
$ErrorActionPreference = 'Stop'
Import-Module -Name $ModulePath -Force -ErrorAction Stop
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($WrapperPath, [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count -ne 0) { throw 'The source-tool wrapper did not parse.' }
$targetName = 'Invoke-NativeProcessWithEvidence'
$functionAst = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $targetName }, $true)
if ($null -eq $functionAst) { throw 'The native process evidence helper was not found.' }
. ([scriptblock]::Create($functionAst.Extent.Text))
$script:Mode = 'native-bounds-fixture'
$runtime = [IO.Path]::GetFullPath([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
try {
    $null = Invoke-NativeProcessWithEvidence -Command $runtime -Arguments @('-NoProfile','-NonInteractive','-File',$FloodPath,$StreamName,$ChildMarker) -Context "bounded fixture $StreamName"
    [Console]::Out.WriteLine((ConvertTo-Json -Compress -InputObject @{ status='returned'; message='' }))
} catch {
    [Console]::Out.WriteLine((ConvertTo-Json -Compress -InputObject @{ status='overflow'; message=$_.Exception.Message }))
}
'@
        [IO.File]::WriteAllText($floodPath, $floodSource, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($harnessPath, $harnessSource, [Text.UTF8Encoding]::new($false))

        $limit = 32L * 1024L * 1024L
        foreach ($streamName in @('stdout','stderr')) {
            $childMarker = Join-Path $fixtureRoot "$streamName-child.pid"
            $start = [Diagnostics.ProcessStartInfo]::new()
            $start.FileName = $runtime
            $start.WorkingDirectory = $fixtureRoot
            $start.UseShellExecute = $false
            $start.CreateNoWindow = $true
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            foreach ($argument in @('-NoProfile','-NonInteractive','-File',$harnessPath,$wrapperPath,$modulePath,$floodPath,$streamName,$childMarker)) {
                [void]$start.ArgumentList.Add([string]$argument)
            }
            $outer = [Diagnostics.Process]::new()
            $outer.StartInfo = $start
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $ownedDescendantIdentity = $null
            try {
                $outer.Start() | Should -BeTrue
                $stdoutTask = $outer.StandardOutput.ReadToEndAsync()
                $stderrTask = $outer.StandardError.ReadToEndAsync()
                if (-not $outer.WaitForExit(15000)) {
                    try { $outer.Kill($true) } catch { }
                    [void]$outer.WaitForExit(5000)
                    throw "Bounded process-capture fixture exceeded its 15-second outer deadline for $streamName."
                }
                $clock.Stop()
                $outer.ExitCode | Should -Be 0
                Test-Path -LiteralPath $childMarker -PathType Leaf | Should -BeTrue
                $ownedDescendantIdentity = Get-Content -LiteralPath $childMarker -Raw | ConvertFrom-Json -Depth 5 -ErrorAction Stop
                $harnessStdout = $stdoutTask.GetAwaiter().GetResult().Trim()
                $harnessStderr = $stderrTask.GetAwaiter().GetResult()
                $summary = $harnessStdout | ConvertFrom-Json -Depth 10 -ErrorAction Stop
                $summary.status | Should -BeExactly 'overflow' -Because $summary.message
                $summary.message | Should -Match "overflow=$streamName"
                $summary.message | Should -Match 'exitCode=-?\d+'
                $summary.message | Should -Match 'stdoutPath=[^;]+'
                $summary.message | Should -Match 'stderrPath=[^;]+'
                $pathMatch = [regex]::Match([string]$summary.message, 'stdoutPath=(?<stdout>[^;]+);.*stderrPath=(?<stderr>.+)$')
                $pathMatch.Success | Should -BeTrue
                $stdoutPath = [string]$pathMatch.Groups['stdout'].Value
                $stderrPath = ([string]$pathMatch.Groups['stderr'].Value).TrimEnd([char]'.')
                (Get-Item -LiteralPath $stdoutPath).Length | Should -BeLessOrEqual $limit
                (Get-Item -LiteralPath $stderrPath).Length | Should -BeLessOrEqual $limit
                if ($streamName -ceq 'stdout') {
                    (Get-Item -LiteralPath $stdoutPath).Length | Should -Be $limit
                } else {
                    (Get-Item -LiteralPath $stderrPath).Length | Should -Be $limit
                }
                $clock.Elapsed.TotalSeconds | Should -BeLessThan 15
                $childPid = [int]$ownedDescendantIdentity.processId
                $killDeadline = [DateTime]::UtcNow.AddSeconds(5)
                $descendantProcess = Get-Process -Id $childPid -ErrorAction SilentlyContinue
                while ($null -ne $descendantProcess -and
                    $descendantProcess.StartTime.ToUniversalTime().Ticks -eq [long]$ownedDescendantIdentity.startTimeUtcTicks -and
                    [DateTime]::UtcNow -lt $killDeadline) {
                    Start-Sleep -Milliseconds 100
                    $descendantProcess = Get-Process -Id $childPid -ErrorAction SilentlyContinue
                }
                if ($null -ne $descendantProcess -and
                    $descendantProcess.StartTime.ToUniversalTime().Ticks -eq [long]$ownedDescendantIdentity.startTimeUtcTicks) {
                    $descendantProcess | Should -BeNullOrEmpty -Because 'the native process tree must be stopped on overflow'
                }
            } finally {
                try {
                    if (-not $outer.HasExited) { $outer.Kill($true); [void]$outer.WaitForExit(5000) }
                } catch { }
                if ($null -eq $ownedDescendantIdentity -and (Test-Path -LiteralPath $childMarker -PathType Leaf)) {
                    try { $ownedDescendantIdentity = Get-Content -LiteralPath $childMarker -Raw | ConvertFrom-Json -Depth 5 -ErrorAction Stop } catch { }
                }
                if ($null -ne $ownedDescendantIdentity) {
                    try {
                        $ownedDescendant = Get-Process -Id ([int]$ownedDescendantIdentity.processId) -ErrorAction SilentlyContinue
                        if ($null -ne $ownedDescendant -and $ownedDescendant.StartTime.ToUniversalTime().Ticks -eq [long]$ownedDescendantIdentity.startTimeUtcTicks) {
                            $ownedDescendant.Kill($true)
                            [void]$ownedDescendant.WaitForExit(5000)
                        }
                    } catch { }
                }
                $outer.Dispose()
            }
        }
    }

    It 'UnitT57_Rejects_an_oversized_native_json_file_before_parsing' {
        # Scenario: a native report file is a sparse file one byte above the raw JSON cap.
        # Purpose: Reject oversized file-based reports before allocating or parsing their contents.
        $wrapper = Join-Path $script:RepositoryRoot 'scripts/Invoke-CoreSourceTool.ps1'
        $tokens = $null; $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($wrapper, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $targetName = 'Read-BoundedNativeJsonFile'
        $functionAst = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $targetName }, $true)
        $functionAst | Should -Not -BeNullOrEmpty -Because 'all native JSON paths must use the bounded byte reader'
        . ([scriptblock]::Create($functionAst.Extent.Text))

        $validPath = Join-Path $TestDrive ('native-json-valid-' + [guid]::NewGuid().ToString('N') + '.json')
        [IO.File]::WriteAllText($validPath, '{"status":"passed"}', [Text.UTF8Encoding]::new($false))
        (Read-BoundedNativeJsonFile -Path $validPath -Context 'valid fixture').status | Should -BeExactly 'passed'

        $oversizedPath = Join-Path $TestDrive ('native-json-over-' + [guid]::NewGuid().ToString('N') + '.json')
        $file = [IO.File]::Open($oversizedPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        try { $file.SetLength((32L * 1024L * 1024L) + 1L) } finally { $file.Dispose() }
        { Read-BoundedNativeJsonFile -Path $oversizedPath -Context 'oversized fixture' } |
            Should -Throw '*exceeded the 33554432-byte JSON cap*'
    }
}
