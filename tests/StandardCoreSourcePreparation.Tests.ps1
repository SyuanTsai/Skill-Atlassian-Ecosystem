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

        function New-CoreV2GitFixture {
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

            $clone = New-StandardCoreV2RawCandidateClone -GitPath $script:GitPath -SourceRoot $sourceRoot `
                -OwnedRoot $ownedRoot -Destination $candidateRoot -ExpectedRevision $revision
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

        $implicitSetup = @{
            SourceToolsPath = 'C:\artifacts\source-tools.json'
            AuthorityRepositoryRoot = 'C:\authority'
            TrustedToolRoot = 'C:\runtime'
            RepositoryRoot = 'C:\candidate'
        }
        { Resolve-StandardCoreV2Dispatch -BoundParameters $implicitSetup } | Should -Throw '*explicit PrepareSourceTools or SourceValidation*'
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
        # Scenario: The exact Python wheel probe path is compared under the run-derived temp parent and former artifact-root parent.
        # Purpose: Keep the authority's 248-character Windows limit unchanged while proving the shortened path fits.
        $runId=[guid]::NewGuid().ToString('N')
        $installParent=Get-StandardCoreV2ToolInstallParent -RunId $runId
        $deepInstallParent=Join-Path (Join-Path $TestDrive "source-tools-$runId") 'installed'
        $proof=Get-StandardCoreV2SkillSpectorPathHeadroom -InstallParent $installParent -DeepArtifactsInstallParent $deepInstallParent
        $proof.currentProbeLength | Should -BeLessThan 248
        $proof.currentHeadroom | Should -BeGreaterThan 0
        $proof.deepArtifactsProbeLength | Should -BeGreaterThan $proof.currentProbeLength
        $proof.deepArtifactsProbePath | Should -Match 'source-tools-[0-9a-f]{32}.*site-packages'
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
        if (-not $IsWindows) { Set-ItResult -Skipped -Because 'The controlled native fixture uses a Windows process.'; return }
        $root=Join-Path $TestDrive ('source-tool-fresh-'+[guid]::NewGuid().ToString('N'))
        $candidateRoot=Join-Path $root 'candidate'; $skillsRoot=Join-Path $candidateRoot 'skills'; $skillId='fixture-skill'
        $skillRoot=Join-Path $skillsRoot $skillId
        New-Item -ItemType Directory -Path $skillRoot -Force | Out-Null
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
            $fixtureExecutable=Join-Path $root 'native-fixture.exe'
            if (-not (Test-Path -LiteralPath $fixtureExecutable -PathType Leaf)) {
                $compiler=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
                if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { Set-ItResult -Skipped -Because 'The Windows .NET Framework C# compiler is unavailable.'; return }
                $fixtureSource=Join-Path $root 'native-fixture.cs'
                $source=@'
using System;
using System.IO;
internal static class NativeFixture {
    private static int Main() {
        string path = Environment.GetEnvironmentVariable("SYP304_FIXTURE_REPORT_PATH");
        string raw = Environment.GetEnvironmentVariable("SYP304_FIXTURE_RAW_STDERR");
        int exitCode = 0;
        if (String.IsNullOrEmpty(path) || !Int32.TryParse(Environment.GetEnvironmentVariable("SYP304_FIXTURE_EXIT_CODE"), out exitCode)) return 87;
        Console.Out.Write(File.ReadAllText(path));
        Console.Error.Write(raw ?? "fixture native stderr");
        return exitCode;
    }
}
'@
                [IO.File]::WriteAllText($fixtureSource,$source,[Text.UTF8Encoding]::new($false))
                $compile=[Diagnostics.ProcessStartInfo]::new();$compile.FileName=$compiler;$compile.WorkingDirectory=$root;$compile.UseShellExecute=$false;$compile.CreateNoWindow=$true
                $compile.RedirectStandardOutput=$true;$compile.RedirectStandardError=$true
                foreach($argument in @('/nologo','/target:exe',$fixtureSource)){[void]$compile.ArgumentList.Add($argument)}
                $compilerProcess=[Diagnostics.Process]::new();$compilerProcess.StartInfo=$compile
                try {
                    $compilerProcess.Start() | Should -BeTrue
                    $compileOut=$compilerProcess.StandardOutput.ReadToEndAsync();$compileErr=$compilerProcess.StandardError.ReadToEndAsync()
                    if(-not $compilerProcess.WaitForExit(30000)){$compilerProcess.Kill($true);$compilerProcess.WaitForExit();throw 'Native fixture compiler timed out.'}
                    if($compilerProcess.ExitCode -ne 0){throw "Native fixture compilation failed: $($compileOut.GetAwaiter().GetResult()) $($compileErr.GetAwaiter().GetResult())"}
                } finally { $compilerProcess.Dispose() }
                if(-not (Test-Path -LiteralPath $fixtureExecutable -PathType Leaf)){throw 'Native fixture compiler did not produce the expected executable.'}
            }
            $toolchain=[ordered]@{
                centralRunnerPath=$runnerPath;centralRunnerSha256=(Get-StandardCoreV2Sha256 -Path $runnerPath)
                sourceRepository='https://github.com/SyuanTsai/Skill-Atlassian-Ecosystem.git';sourceRevision=('a'*40)
                skillValidatorPath=$fixtureExecutable;skillValidatorSha256=(Get-StandardCoreV2Sha256 -Path $fixtureExecutable)
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
    }

    It 'UnitT42_Invokes_the_vendored_supervisor_with_the_namespaced_owned_root' {
        # Scenario: The repository-vendored process supervisor launches one bounded PowerShell child with its approved namespaced root.
        # Purpose: Exercise the actual child-environment validator and process lifecycle without external checkout dependencies.
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
    }

    It 'UnitT44_Binds_the_protected_timeout_to_bounded_resolver_acquisition' {
        # Scenario: The protected driver dispatches each approved resolver with its configured acquisition deadline.
        # Purpose: Preserve resolver identities and keep both default and explicit deadlines within the resolver's 1..3600 contract.
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
            [pscustomobject]@{ Arguments = $defaultArguments; ExpectedTimeout = '900' },
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

        $driverPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-ProtectedSourceValidation.ps1'
        $tokens = $null; $errors = $null
        $driverAst = [System.Management.Automation.Language.Parser]::ParseFile($driverPath, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0
        $driverAst.ParamBlock.Extent.Text | Should -Match '(?s)\[ValidateRange\(1\s*,\s*3600\)\]\[int\]\s*\$TimeoutSeconds\s*=\s*900'
        $dispatchCalls = @($driverAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -ceq 'New-StandardCoreV2ResolverArguments' }, $true))
        $dispatchCalls.Count | Should -Be 1
        $dispatchElements = @($dispatchCalls[0].CommandElements | ForEach-Object { [string]$_.Extent.Text })
        $dispatchElements | Should -Contain '-AcquisitionTimeoutSeconds'
        $dispatchElements | Should -Contain '$TimeoutSeconds'

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
        $resolverProcessExtent | Should -Match '-LimitSeconds\s+\$TimeoutSeconds'
    }

    It 'UnitT45_Collects_twelve_distinct_frozen_candidate_and_setup_paths' {
        # Scenario: Preparation collects candidate and setup inputs before hashing the frozen inventory.
        # Purpose: Execute the production collector expression and preserve its exact twelve paths, including the reviewed baseline artifact.
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
        $expected = [string[]]@(
            (Join-Path $candidateRoot 'scripts/Test-Repository.ps1'),
            (Join-Path $candidateRoot 'scripts/Invoke-CoreRepositoryGeneral.ps1'),
            (Join-Path $candidateRoot 'scripts/Invoke-CorePester.ps1'),
            (Join-Path $candidateRoot 'scripts/CorePesterIntegrity.psm1'),
            $candidateReviewedBaseline,
            (Join-Path $candidateRoot 'config/pester-6.2.0-closure.lock.json'),
            (Join-Path $candidateRoot 'config/standard-core-v2-preparation.json'),
            (Join-Path $candidateRoot '.gitattributes'),
            $setupLockPath,
            $bindingPath,
            $toolchainPath,
            $pesterReceiptPath
        )

        $actual = [string[]]@(& ([scriptblock]::Create($collectors[0].Condition.Extent.Text)))

        $actual.Count | Should -Be 12
        @($actual | Where-Object { $_ -ceq $candidateReviewedBaseline }).Count | Should -Be 1
        $unique = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        for ($index = 0; $index -lt $expected.Count; $index++) {
            $actual[$index] | Should -BeExactly $expected[$index]
            [void]$unique.Add($actual[$index])
        }
        $unique.Count | Should -Be 12
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
}
