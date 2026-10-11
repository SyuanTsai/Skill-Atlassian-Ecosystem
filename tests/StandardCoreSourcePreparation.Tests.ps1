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

    It 'UnitT45_Collects_eleven_distinct_frozen_candidate_and_setup_paths' {
        # Scenario: Preparation collects candidate and setup inputs before hashing the frozen inventory.
        # Purpose: Execute the production collector expression and preserve its exact eleven separate paths.
        $candidateRoot = Join-Path $TestDrive "frozen-candidate-$([guid]::NewGuid().ToString('N'))"
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
            (Join-Path $candidateRoot 'config/pester-6.2.0-closure.lock.json'),
            (Join-Path $candidateRoot 'config/standard-core-v2-preparation.json'),
            (Join-Path $candidateRoot '.gitattributes'),
            $setupLockPath,
            $bindingPath,
            $toolchainPath,
            $pesterReceiptPath
        )

        $actual = [string[]]@(& ([scriptblock]::Create($collectors[0].Condition.Extent.Text)))

        $actual.Count | Should -Be 11
        $unique = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        for ($index = 0; $index -lt $expected.Count; $index++) {
            $actual[$index] | Should -BeExactly $expected[$index]
            [void]$unique.Add($actual[$index])
        }
        $unique.Count | Should -Be 11
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
}
