# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $script:repositoryRoot = Split-Path -Parent $PSScriptRoot
    Import-Module -Name (Join-Path $script:repositoryRoot 'scripts/CorePesterIntegrity.psm1') -Force
    $script:closureLockPath = Join-Path $script:repositoryRoot 'config/pester-6.2.0-closure.lock.json'
    $script:closureLock = Read-CorePesterClosureLock -LiteralPath $script:closureLockPath
    $script:loadedPester = @(Get-Module -Name Pester | Where-Object { $_.Version -eq [version]'6.2.0' }) | Select-Object -First 1
    if ($null -eq $script:loadedPester) { throw 'Integrity tests require the explicitly prepared Pester 6.2.0 test host.' }

    function New-IntegrityPackageFixture {
        param([Parameter(Mandatory)][string] $Path, [string] $Variant = 'valid')

        $stream = [IO.FileStream]::new($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
            try {
                foreach ($payload in $script:closureLock.Value.modulePayload) {
                    $entryName = [string]$payload.path
                    if ($Variant -eq 'case-mismatch' -and $entryName -ceq 'Pester.psd1') { $entryName = 'pester.psd1' }
                    $entry = $zip.CreateEntry($entryName)
                    if ($entryName -ceq 'Pester.psm1') {
                        if ($Variant -eq 'unix-regular-file') { $entry.ExternalAttributes = [int]0x81A40000 }
                        elseif ($Variant -eq 'unix-symlink') { $entry.ExternalAttributes = [int]0xA1FF0000 }
                    }
                    $target = $entry.Open()
                    try {
                        if ($Variant -eq 'hash-mismatch' -and [string]$payload.path -ceq 'Pester.psm1') {
                            $badBytes = [Text.Encoding]::UTF8.GetBytes('unexpected module bytes')
                            $target.Write($badBytes, 0, $badBytes.Length)
                        }
                        else {
                            $sourcePath = Join-Path $script:loadedPester.ModuleBase ([string]$payload.path)
                            $bytes = [IO.File]::ReadAllBytes($sourcePath)
                            $target.Write($bytes, 0, $bytes.Length)
                        }
                    }
                    finally { $target.Dispose() }
                }
                foreach ($name in @('_rels/.rels', '[Content_Types].xml', 'package/services/metadata/core-properties/nuget.psmdcp')) {
                    $entry = $zip.CreateEntry($name)
                    $target = $entry.Open()
                    try { $target.WriteByte(0x20) } finally { $target.Dispose() }
                }
                $nuspec = '<package><metadata><id>Pester</id><version>6.2.0</version></metadata></package>'
                $entry = $zip.CreateEntry('Pester.nuspec')
                $target = $entry.Open()
                try {
                    $bytes = [Text.Encoding]::UTF8.GetBytes($nuspec)
                    $target.Write($bytes, 0, $bytes.Length)
                }
                finally { $target.Dispose() }
                if ($Variant -eq 'extra') { [void]$zip.CreateEntry('extra.ps1') }
                if ($Variant -eq 'duplicate') { [void]$zip.CreateEntry('_rels/.rels') }
                if ($Variant -eq 'unsafe') { [void]$zip.CreateEntry('../outside.ps1') }
            }
            finally { $zip.Dispose() }
        }
        finally { $stream.Dispose() }
    }

    function New-IntegrityReparseDirectoryLink {
        param(
            [Parameter(Mandatory)][string] $Path,
            [Parameter(Mandatory)][string] $Target
        )

        $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
        [void](New-Item -ItemType $linkType -Path $Path -Target $Target -ErrorAction Stop)
        $linkItem = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (($linkItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
            throw "The $linkType fixture did not create a reparse-point directory: $Path"
        }
        return $linkItem
    }
}

Describe 'Pester setup owned-root environment compatibility' {
    # Scenario: setup passes the new namespaced key while the legacy key is absent.
    # Purpose: consume a fully qualified registered root without relying on string coercion for null values.
    It 'UnitT90_resolves_a_namespaced_owned_root_with_a_null_legacy_value' {
        Import-Module -Name (Join-Path $script:repositoryRoot 'scripts/CorePesterIntegrity.psm1') -Force -ErrorAction Stop
        Get-Command -Name Resolve-CorePesterSetupOwnedRoot -CommandType Function -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        $ownedRoot = [IO.Path]::GetFullPath((Join-Path $TestDrive ("source-tools-" + [guid]::NewGuid().ToString('N'))))
        [void](New-Item -ItemType Directory -Path $ownedRoot -Force)

        Resolve-CorePesterSetupOwnedRoot -OwnedRoot $ownedRoot -NamespacedRoot $ownedRoot -LegacyRoot $null |
            Should -BeExactly $ownedRoot
    }

    # Scenario: an older caller supplies only the legacy environment key.
    # Purpose: keep the documented compatibility path while returning the same canonical root.
    It 'UnitT91_resolves_a_legacy_owned_root_with_a_null_namespaced_value' {
        Import-Module -Name (Join-Path $script:repositoryRoot 'scripts/CorePesterIntegrity.psm1') -Force -ErrorAction Stop
        Get-Command -Name Resolve-CorePesterSetupOwnedRoot -CommandType Function -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        $ownedRoot = [IO.Path]::GetFullPath((Join-Path $TestDrive ("source-tools-" + [guid]::NewGuid().ToString('N'))))
        [void](New-Item -ItemType Directory -Path $ownedRoot -Force)

        Resolve-CorePesterSetupOwnedRoot -OwnedRoot $ownedRoot -NamespacedRoot $null -LegacyRoot $ownedRoot |
            Should -BeExactly $ownedRoot
    }

    # Scenario: both accepted environment names carry the same fully qualified value.
    # Purpose: permit exact dual-key compatibility during an orderly transition.
    It 'UnitT92_accepts_matching_namespaced_and_legacy_owned_roots' {
        Import-Module -Name (Join-Path $script:repositoryRoot 'scripts/CorePesterIntegrity.psm1') -Force -ErrorAction Stop
        Get-Command -Name Resolve-CorePesterSetupOwnedRoot -CommandType Function -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        $ownedRoot = [IO.Path]::GetFullPath((Join-Path $TestDrive ("source-tools-" + [guid]::NewGuid().ToString('N'))))
        [void](New-Item -ItemType Directory -Path $ownedRoot -Force)

        Resolve-CorePesterSetupOwnedRoot -OwnedRoot $ownedRoot -NamespacedRoot $ownedRoot -LegacyRoot $ownedRoot |
            Should -BeExactly $ownedRoot
        $segment = Join-Path $ownedRoot 'segment'
        [void](New-Item -ItemType Directory -Path $segment -Force)
        $normalizedAlias = Join-Path $segment '..'
        $resolvedAlias = Resolve-CorePesterSetupOwnedRoot -OwnedRoot $ownedRoot -NamespacedRoot $ownedRoot -LegacyRoot $normalizedAlias
        $resolvedAlias | Should -BeExactly $ownedRoot
    }

    # Scenario: the two environment names use paths that differ only in letter casing.
    # Purpose: apply Windows ordinal-ignore-case and Unix ordinal path comparison rules.
    It 'UnitT93_compares_owned_roots_using_the_platform_path_rules' {
        Import-Module -Name (Join-Path $script:repositoryRoot 'scripts/CorePesterIntegrity.psm1') -Force -ErrorAction Stop
        Get-Command -Name Resolve-CorePesterSetupOwnedRoot -CommandType Function -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        $ownedRoot = [IO.Path]::GetFullPath((Join-Path $TestDrive 'PesterOwnedRoot'))
        $caseVariant = [IO.Path]::GetFullPath((Join-Path $TestDrive 'pesterownedroot'))
        [void](New-Item -ItemType Directory -Path $ownedRoot -Force)
        if (-not (Test-Path -LiteralPath $caseVariant -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $caseVariant -Force)
        }

        if ($IsWindows) {
            $resolved = Resolve-CorePesterSetupOwnedRoot -OwnedRoot $ownedRoot -NamespacedRoot $ownedRoot -LegacyRoot $caseVariant
            [string]::Equals([string]$resolved, $ownedRoot, [StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
        }
        else {
            { Resolve-CorePesterSetupOwnedRoot -OwnedRoot $ownedRoot -NamespacedRoot $ownedRoot -LegacyRoot $caseVariant } |
                Should -Throw
        }
    }

    # Scenario: no environment root, conflicting aliases, or values outside the registered root are supplied.
    # Purpose: reject missing and ambiguous setup identities instead of guessing which value to trust.
    It 'UnitT94_rejects_missing_conflicting_and_unregistered_owned_roots' {
        Import-Module -Name (Join-Path $script:repositoryRoot 'scripts/CorePesterIntegrity.psm1') -Force -ErrorAction Stop
        Get-Command -Name Resolve-CorePesterSetupOwnedRoot -CommandType Function -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        $ownedRoot = [IO.Path]::GetFullPath((Join-Path $TestDrive ("source-tools-" + [guid]::NewGuid().ToString('N'))))
        $otherRoot = [IO.Path]::GetFullPath((Join-Path $TestDrive ("source-tools-" + [guid]::NewGuid().ToString('N'))))
        [void](New-Item -ItemType Directory -Path $ownedRoot -Force)
        [void](New-Item -ItemType Directory -Path $otherRoot -Force)

        { Resolve-CorePesterSetupOwnedRoot -OwnedRoot $ownedRoot -NamespacedRoot $null -LegacyRoot $null } | Should -Throw
        { Resolve-CorePesterSetupOwnedRoot -OwnedRoot $ownedRoot -NamespacedRoot $ownedRoot -LegacyRoot $otherRoot } | Should -Throw
        { Resolve-CorePesterSetupOwnedRoot -OwnedRoot $ownedRoot -NamespacedRoot $otherRoot -LegacyRoot $otherRoot } | Should -Throw
    }

    # Scenario: one malformed environment value is paired with a valid alias.
    # Purpose: validate every present value independently, including Windows drive-relative and root-relative paths.
    It 'UnitT95_rejects_invalid_environment_values_even_when_the_other_key_is_valid' {
        Import-Module -Name (Join-Path $script:repositoryRoot 'scripts/CorePesterIntegrity.psm1') -Force -ErrorAction Stop
        Get-Command -Name Resolve-CorePesterSetupOwnedRoot -CommandType Function -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        $ownedRoot = [IO.Path]::GetFullPath((Join-Path $TestDrive ("source-tools-" + [guid]::NewGuid().ToString('N'))))
        [void](New-Item -ItemType Directory -Path $ownedRoot -Force)
        $invalidValues = @(
            [pscustomobject]@{ Name = 'empty'; Value = '' },
            [pscustomobject]@{ Name = 'whitespace'; Value = '   ' },
            [pscustomobject]@{ Name = 'relative'; Value = 'relative-root' },
            [pscustomobject]@{ Name = 'invalid-path'; Value = [string][char]0 },
            [pscustomobject]@{ Name = 'non-string'; Value = [pscustomobject]@{ path = $ownedRoot } }
        )
        if ($IsWindows) {
            $invalidValues += [pscustomobject]@{ Name = 'drive-relative'; Value = 'C:relative-root' }
            $invalidValues += [pscustomobject]@{ Name = 'root-relative'; Value = [IO.Path]::DirectorySeparatorChar + 'root-relative' }
        }

        foreach ($invalidValue in $invalidValues) {
            $badRoot = $invalidValue.Value
            { Resolve-CorePesterSetupOwnedRoot -OwnedRoot $ownedRoot -NamespacedRoot $badRoot -LegacyRoot $ownedRoot } |
                Should -Throw -Because "namespaced value '$($invalidValue.Name)' must not be masked by the legacy value"
            { Resolve-CorePesterSetupOwnedRoot -OwnedRoot $ownedRoot -NamespacedRoot $ownedRoot -LegacyRoot $badRoot } |
                Should -Throw -Because "legacy value '$($invalidValue.Name)' must not be masked by the namespaced value"
        }
    }
}

Describe 'Consumed Core process bootstrap signal' {
    BeforeAll {
        $wrapperPath = Join-Path $script:repositoryRoot 'scripts/Invoke-CorePester.ps1'
        $wrapper = Get-Content -LiteralPath $wrapperPath -Raw
        $tokens = $null
        $parseErrors = $null
        $wrapperAst = [Management.Automation.Language.Parser]::ParseFile($wrapperPath, [ref]$tokens, [ref]$parseErrors)
        if (@($parseErrors).Count -ne 0) { throw 'Core Pester wrapper could not be parsed for bootstrap gate tests.' }
        $bootstrapStart = $wrapperAst.Find({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -ceq '$bootstrapReleasePath'
        }, $true)
        $snapshotStart = $wrapperAst.Find({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -ceq '$candidateSnapshotBefore'
        }, $true)
        if ($null -eq $bootstrapStart -or $null -eq $snapshotStart -or
            $snapshotStart.Extent.StartOffset -le $bootstrapStart.Extent.StartOffset) {
            throw 'Core Pester bootstrap gate could not be isolated before the first candidate snapshot.'
        }
        $bootstrapGateText = $wrapper.Substring(
            $bootstrapStart.Extent.StartOffset,
            $snapshotStart.Extent.StartOffset - $bootstrapStart.Extent.StartOffset)
        $script:corePesterBootstrapGate = [scriptblock]::Create($bootstrapGateText)

        function Invoke-CorePesterBootstrapGateFixture {
            param(
                [AllowNull()][string] $ReleasePath,
                [AllowNull()][string] $BootstrapCommand
            )

            $releaseName = 'STANDARD_VALIDATION_BOOTSTRAP_RELEASE_PATH'
            $commandName = 'STANDARD_VALIDATION_BOOTSTRAP_COMMAND'
            $previousReleasePath = [Environment]::GetEnvironmentVariable($releaseName, 'Process')
            $previousBootstrapCommand = [Environment]::GetEnvironmentVariable($commandName, 'Process')
            try {
                [Environment]::SetEnvironmentVariable($releaseName, $ReleasePath, 'Process')
                [Environment]::SetEnvironmentVariable($commandName, $BootstrapCommand, 'Process')
                $calls = [Collections.Generic.List[object]]::new()
                function Remove-CorePesterConsumedBootstrapSignal {
                    param(
                        [Parameter(Mandatory)][string] $CandidateRoot,
                        [Parameter(Mandatory)][string] $ReleasePath,
                        [Parameter(Mandatory)][string] $BootstrapCommand,
                        [Parameter(Mandatory)][string] $VerifiedPowerShellExecutable
                    )

                    [void]$calls.Add([pscustomobject]@{
                        CandidateRoot = $CandidateRoot
                        ReleasePath = $ReleasePath
                        BootstrapCommand = $BootstrapCommand
                        VerifiedPowerShellExecutable = $VerifiedPowerShellExecutable
                    })
                }

                $candidateSnapshotRoot = [IO.Path]::GetFullPath((Join-Path $TestDrive 'candidate'))
                $verifiedPowerShellExecutable = [IO.Path]::GetFullPath((Join-Path $TestDrive 'verified/pwsh.exe'))
                & $script:corePesterBootstrapGate
                return @($calls)
            }
            finally {
                [Environment]::SetEnvironmentVariable($releaseName, $previousReleasePath, 'Process')
                [Environment]::SetEnvironmentVariable($commandName, $previousBootstrapCommand, 'Process')
            }
        }
    }

    # Scenario: The owned bootstrap has released the child before its snapshot is bound.
    # Purpose: Remove only the exact consumed transport file while hashing every source byte.
    It 'UnitT10_restores_the_full_source_snapshot_and_preserves_other_signal_like_files' {
        $root = Join-Path $TestDrive 'source-candidate'
        [void](New-Item -ItemType Directory -Path $root)
        $source = Join-Path $root 'b-11111111111111111111111111111111.sig'
        [IO.File]::WriteAllText($source, 'tracked source bytes')
        $before = Get-CorePesterTreeSnapshot -Root $root
        $signal = Join-Path $root 'b-22222222222222222222222222222222.sig'
        [IO.File]::WriteAllText($signal, ('release' + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        (Get-CorePesterTreeSnapshot -Root $root).Sha256 | Should -Not -Be $before.Sha256
        $executableName = if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' }
        $verifiedExecutable = [IO.Path]::GetFullPath((Join-Path $TestDrive "verified/$executableName"))
        Remove-CorePesterConsumedBootstrapSignal -CandidateRoot $root -ReleasePath $signal -BootstrapCommand $verifiedExecutable -VerifiedPowerShellExecutable $verifiedExecutable
        Test-Path -LiteralPath $signal | Should -BeFalse
        (Get-CorePesterTreeSnapshot -Root $root).Sha256 | Should -Be $before.Sha256
        [IO.File]::ReadAllText($source) | Should -Be 'tracked source bytes'
    }

    # Scenario: Bootstrap metadata selects a foreign path, name, payload or command.
    # Purpose: Fail closed without deleting any file rather than excluding it from integrity checks.
    It 'UnitT20_rejects_invalid_bootstrap_metadata_<Variant>' -ForEach @(
        @{ Variant = 'outside' }, @{ Variant = 'name' }, @{ Variant = 'bytes' },
        @{ Variant = 'command' }, @{ Variant = 'missing' }, @{ Variant = 'directory' }
    ) {
        $root = Join-Path $TestDrive ("invalid-$Variant-candidate")
        [void](New-Item -ItemType Directory -Path $root)
        $signal = Join-Path $root 'b-22222222222222222222222222222222.sig'
        if ($Variant -eq 'outside') { $signal = Join-Path $TestDrive 'b-22222222222222222222222222222222.sig' }
        if ($Variant -eq 'name') { $signal = Join-Path $root 'source.ps1' }
        $bytes = if ($Variant -eq 'bytes') { 'wrong' } else { 'release' + [Environment]::NewLine }
        if ($Variant -eq 'directory') { [void](New-Item -ItemType Directory -Path $signal) }
        elseif ($Variant -ne 'missing') { [IO.File]::WriteAllText($signal, $bytes, [Text.UTF8Encoding]::new($false)) }
        $executableName = if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' }
        $verifiedExecutable = [IO.Path]::GetFullPath((Join-Path $TestDrive "verified/$executableName"))
        $unverifiedExecutable = [IO.Path]::GetFullPath((Join-Path $TestDrive "unverified/$executableName"))
        $command = if ($Variant -eq 'command') { $unverifiedExecutable } else { $verifiedExecutable }
        { Remove-CorePesterConsumedBootstrapSignal -CandidateRoot $root -ReleasePath $signal -BootstrapCommand $command -VerifiedPowerShellExecutable $verifiedExecutable } | Should -Throw '*Core Pester bootstrap*'
        if ($Variant -ne 'missing') { Test-Path -LiteralPath $signal | Should -BeTrue }
    }

    # Scenario: A candidate directory is redirected through a junction.
    # Purpose: Prevent consumed-signal cleanup from crossing a reparse ancestor.
    It 'UnitT30_rejects_reparse_ancestry_without_deleting_the_signal' {
        $outside = Join-Path $TestDrive 'outside'
        [void](New-Item -ItemType Directory -Path $outside)
        $link = Join-Path $TestDrive 'reparse-candidate'
        $linkItem = New-IntegrityReparseDirectoryLink -Path $link -Target $outside
        ($linkItem.Attributes -band [IO.FileAttributes]::ReparsePoint) | Should -Not -Be 0
        $signal = Join-Path $link 'b-22222222222222222222222222222222.sig'
        [IO.File]::WriteAllText($signal, ('release' + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $executableName = if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' }
        $verifiedExecutable = [IO.Path]::GetFullPath((Join-Path $TestDrive "verified/$executableName"))
        try {
            { Remove-CorePesterConsumedBootstrapSignal -CandidateRoot $link -ReleasePath $signal -BootstrapCommand $verifiedExecutable -VerifiedPowerShellExecutable $verifiedExecutable } | Should -Throw -ExpectedMessage '*non-reparse ancestry*'
            Test-Path -LiteralPath $signal | Should -BeTrue
        }
        finally { Remove-Item -LiteralPath $link -Force }
    }

    # Scenario: The canonical wrapper binds its first full snapshot after trusted identity checks.
    # Purpose: Keep transport cleanup before both before/after source integrity snapshots.
    It 'UnitT40_cleans_consumed_signal_after_authority_verification_before_first_snapshot' {
        $wrapper = Get-Content -LiteralPath (Join-Path $script:repositoryRoot 'scripts/Invoke-CorePester.ps1') -Raw
        $authority = $wrapper.IndexOf('$verifiedAuthoritySnapshotRoot = Get-VerifiedCoreAuthoritySnapshotPath', [StringComparison]::Ordinal)
        $cleanup = $wrapper.IndexOf('Remove-CorePesterConsumedBootstrapSignal -CandidateRoot', [StringComparison]::Ordinal)
        $snapshot = $wrapper.IndexOf('$candidateSnapshotBefore = Get-CorePesterTreeSnapshot', [StringComparison]::Ordinal)
        ($authority -ge 0 -and $cleanup -gt $authority -and $snapshot -gt $cleanup) | Should -BeTrue
    }

    # Scenario: The authority runner omits both legacy bootstrap environment values.
    # Purpose: Continue without calling cleanup or binding an empty mandatory release path.
    It 'UnitT50_skips_cleanup_when_legacy_bootstrap_environment_is_absent' {
        $calls = @(Invoke-CorePesterBootstrapGateFixture -ReleasePath $null -BootstrapCommand $null)
        $calls.Count | Should -Be 0
    }

    # Scenario: The authority runner supplies only one legacy bootstrap environment value.
    # Purpose: Fail closed rather than accepting a partial trusted-supervisor signal.
    It 'UnitT60_rejects_partial_legacy_bootstrap_environment_<PresentValue>' -ForEach @(
        @{ PresentValue = 'release-path'; ReleasePath = 'release.sig'; BootstrapCommand = $null },
        @{ PresentValue = 'command'; ReleasePath = $null; BootstrapCommand = 'pwsh.exe' }
    ) {
        { Invoke-CorePesterBootstrapGateFixture -ReleasePath $ReleasePath -BootstrapCommand $BootstrapCommand } |
            Should -Throw -ExpectedMessage 'Core Pester bootstrap signal requires both trusted supervisor release path and command.'
    }

    # Scenario: An older authority runner supplies both legacy bootstrap environment values.
    # Purpose: Preserve the exact cleanup call and parameter bindings for the compatibility path.
    It 'UnitT70_cleans_consumed_signal_when_legacy_bootstrap_environment_is_complete' {
        $releasePath = [IO.Path]::GetFullPath((Join-Path $TestDrive 'candidate/b-22222222222222222222222222222222.sig'))
        $bootstrapCommand = [IO.Path]::GetFullPath((Join-Path $TestDrive 'verified/pwsh.exe'))
        $calls = @(Invoke-CorePesterBootstrapGateFixture -ReleasePath $releasePath -BootstrapCommand $bootstrapCommand)
        $calls.Count | Should -Be 1
        $calls[0].CandidateRoot | Should -BeExactly ([IO.Path]::GetFullPath((Join-Path $TestDrive 'candidate')))
        $calls[0].ReleasePath | Should -BeExactly $releasePath
        $calls[0].BootstrapCommand | Should -BeExactly $bootstrapCommand
        $calls[0].VerifiedPowerShellExecutable | Should -BeExactly $bootstrapCommand
    }
}

Describe 'Verified Pester 6.2.0 module closure' {
    # Scenario: The trusted package lock is consumed before any module import.
    # Purpose: Reject malformed, ambiguous, unsafe, or unpinned closure declarations.
    It 'UnitT10_rejects_malformed_or_ambiguous_lock_documents' {
        $lock = Get-Content -LiteralPath $script:closureLockPath -Raw -Encoding utf8
        $duplicateProperty = $lock -replace '"schemaVersion": 1,', '"schemaVersion": 1, "schemaVersion": 1,'
        $duplicatePath = Join-Path $TestDrive 'duplicate-property.json'
        [IO.File]::WriteAllText($duplicatePath, $duplicateProperty, [Text.UTF8Encoding]::new($false))
        { Read-CorePesterClosureLock -LiteralPath $duplicatePath } | Should -Throw '*duplicate*'

        $object = Get-Content -LiteralPath $script:closureLockPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        $object.modulePayload[1].path = '../escape.ps1'
        $unsafePath = Join-Path $TestDrive 'unsafe-path.json'
        $object | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $unsafePath -Encoding utf8
        { Read-CorePesterClosureLock -LiteralPath $unsafePath } | Should -Throw '*unsafe relative path*'

        $object = Get-Content -LiteralPath $script:closureLockPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        $object.modulePayload[1].path = $object.modulePayload[0].path
        $duplicateEntryPath = Join-Path $TestDrive 'duplicate-entry.json'
        $object | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $duplicateEntryPath -Encoding utf8
        { Read-CorePesterClosureLock -LiteralPath $duplicateEntryPath } | Should -Throw '*duplicate*'
    }

    # Scenario: An explicit module root is checked as a complete relative path and hash inventory.
    # Purpose: Detect missing, extra, altered, or reparse-backed payload before import and after execution.
    It 'UnitT20_rejects_missing_extra_hash_mismatch_and_reparse_payloads' {
        $moduleRoot = Join-Path $TestDrive 'module-closure'
        [void](New-Item -ItemType Directory -Path $moduleRoot)
        $content = @{
            'Pester.psd1' = '@{ ModuleVersion = ''6.2.0'' }'
            'Pester.psm1' = 'function Invoke-Pester { }'
        }
        $payload = @(
            foreach ($path in $content.Keys) {
                $fullPath = Join-Path $moduleRoot $path
                [IO.File]::WriteAllText($fullPath, $content[$path], [Text.UTF8Encoding]::new($false))
                [pscustomobject]@{ path = $path; sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant() }
            }
        )
        $fixtureLock = [pscustomobject]@{ modulePayload = $payload }
        (Test-CorePesterClosure -ModuleRoot $moduleRoot -Lock $fixtureLock).IsValid | Should -BeTrue

        Remove-Item -LiteralPath (Join-Path $moduleRoot 'Pester.psm1') -Force
        (Test-CorePesterClosure -ModuleRoot $moduleRoot -Lock $fixtureLock).Errors | Should -Contain 'Pester closure payload is missing: Pester.psm1'
        [IO.File]::WriteAllText((Join-Path $moduleRoot 'Pester.psm1'), 'changed bytes', [Text.UTF8Encoding]::new($false))
        (Test-CorePesterClosure -ModuleRoot $moduleRoot -Lock $fixtureLock).Errors | Should -Contain 'Pester closure hash mismatch: Pester.psm1'
        [IO.File]::WriteAllText((Join-Path $moduleRoot 'unexpected.ps1'), 'not pinned', [Text.UTF8Encoding]::new($false))
        (Test-CorePesterClosure -ModuleRoot $moduleRoot -Lock $fixtureLock).Errors | Should -Contain 'Pester closure contains unpinned file: unexpected.ps1'
        Remove-Item -LiteralPath (Join-Path $moduleRoot 'unexpected.ps1') -Force

        $outsideRoot = Join-Path $TestDrive 'outside-module'
        [void](New-Item -ItemType Directory -Path $outsideRoot)
        $outsideFile = Join-Path $outsideRoot 'payload.ps1'
        [IO.File]::WriteAllText($outsideFile, 'outside', [Text.UTF8Encoding]::new($false))
        $link = Join-Path $moduleRoot 'linked'
        $linkItem = New-IntegrityReparseDirectoryLink -Path $link -Target $outsideRoot
        ($linkItem.Attributes -band [IO.FileAttributes]::ReparsePoint) | Should -Not -Be 0
        try {
            $closureResult = Test-CorePesterClosure -ModuleRoot $moduleRoot -Lock $fixtureLock
            $closureResult.Errors | Should -Contain "Pester closure contains a reparse point: $link"
        }
        finally { Remove-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue }
    }

    It 'UnitT25_rejects_escaped_paths_and_reparse_point_ancestors' {
        $boundary = Join-Path $TestDrive 'runtime-boundary'
        $outside = Join-Path $TestDrive 'outside-boundary'
        [void](New-Item -ItemType Directory -Path $boundary)
        [void](New-Item -ItemType Directory -Path $outside)

        (Test-CorePesterPathBoundary -Path (Join-Path $boundary 'Modules/Pester/6.2.0') -Boundary $boundary).IsValid | Should -BeTrue
        (Test-CorePesterPathBoundary -Path $outside -Boundary $boundary).Errors | Should -Contain 'Path escaped its registered boundary.'

        $link = Join-Path $boundary 'redirected'
        $linkItem = New-IntegrityReparseDirectoryLink -Path $link -Target $outside
        ($linkItem.Attributes -band [IO.FileAttributes]::ReparsePoint) | Should -Not -Be 0
        try {
            $redirected = Test-CorePesterPathBoundary -Path (Join-Path $link 'Modules/Pester/6.2.0') -Boundary $boundary
            $redirected.IsValid | Should -BeFalse
            @($redirected.Errors | Where-Object { $_ -like 'Path ancestry contains a reparse point:*' }).Count | Should -BeGreaterThan 0
            $redirected.Errors | Should -Contain "Path ancestry contains a reparse point: $link"

            $linkedBoundary = Test-CorePesterPathBoundary -Path (Join-Path $link 'Modules') -Boundary $link
            $linkedBoundary.IsValid | Should -BeFalse
            @($linkedBoundary.Errors | Where-Object { $_ -like 'Path ancestry contains a reparse point:*' }).Count | Should -BeGreaterThan 0
            $linkedBoundary.Errors | Should -Contain "Path ancestry contains a reparse point: $link"
        }
        finally { Remove-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue }
    }

    # Scenario: The runtime exposes the exact locked manifest alongside an injected ambient copy.
    # Purpose: Ensure same-version module search results cannot redirect child imports.
    It 'UnitT30_accepts_only_the_single_manifest_under_the_verified_runtime' {
        $manifest = Join-Path $TestDrive 'runtime/Modules/Pester/6.2.0/Pester.psd1'
        $same = @([pscustomobject]@{ Version = [version]'6.2.0'; Path = $manifest })
        (Test-CorePesterModuleCandidates -ExpectedManifestPath $manifest -Candidates $same).IsValid | Should -BeTrue
        $injected = @($same) + @([pscustomobject]@{ Version = [version]'6.2.0'; Path = (Join-Path $TestDrive 'ambient/Pester.psd1') })
        $rejected = Test-CorePesterModuleCandidates -ExpectedManifestPath $manifest -Candidates $injected
        $rejected.IsValid | Should -BeFalse
        $rejected.Errors | Should -Contain "An ambient Pester 6.2.0 module candidate exists outside the verified runtime: $(Join-Path $TestDrive 'ambient/Pester.psd1')"
        (Test-CorePesterModuleCandidates -ExpectedManifestPath $manifest -Candidates @()).IsValid | Should -BeFalse
    }

    It 'UnitT35_binds_imported_module_to_manifest_entry_point_and_runtime_root' {
        $manifest = Join-Path $script:loadedPester.ModuleBase ([string]$script:closureLock.Value.runtime.manifestRelativePath)
        $expectedPath = Get-CorePesterExpectedLoadedModulePath -ManifestPath $manifest -ModuleRoot $script:loadedPester.ModuleBase -Lock $script:closureLock.Value
        $expectedPath | Should -Be ([IO.Path]::GetFullPath([string]$script:loadedPester.Path))

        $accepted = Test-CorePesterLoadedModuleIdentity -Modules @($script:loadedPester) -ExpectedVersion '6.2.0' -ExpectedPath $expectedPath -ExpectedModuleBase $script:loadedPester.ModuleBase
        $accepted.IsValid | Should -BeTrue
        (Test-CorePesterLoadedModuleIdentity -Modules @($script:loadedPester) -ExpectedVersion '6.2.0' -ExpectedPath $manifest -ExpectedModuleBase $script:loadedPester.ModuleBase).Errors | Should -Contain 'Loaded Pester module path differs from the manifest RootModule entry point.'
        (Test-CorePesterLoadedModuleIdentity -Modules @($script:loadedPester) -ExpectedVersion '6.2.0' -ExpectedPath $expectedPath -ExpectedModuleBase (Join-Path $TestDrive 'wrong-runtime')).Errors | Should -Contain 'Loaded Pester module base differs from the verified runtime module root.'
        (Test-CorePesterLoadedModuleIdentity -Modules @($script:loadedPester, $script:loadedPester) -ExpectedVersion '6.2.0' -ExpectedPath $expectedPath -ExpectedModuleBase $script:loadedPester.ModuleBase).Errors | Should -Contain 'Exactly one Pester module must be loaded in the Core child.'

        $fixtureRoot = Join-Path $TestDrive 'manifest-root-module'
        [void](New-Item -ItemType Directory -Path $fixtureRoot)
        $fixtureManifest = Join-Path $fixtureRoot 'Pester.psd1'
        [IO.File]::WriteAllText($fixtureManifest, "@{ RootModule = '../outside.psm1' }`n", [Text.UTF8Encoding]::new($false))
        $fixtureLock = [pscustomobject]@{
            runtime = [pscustomobject]@{ manifestRelativePath = 'Pester.psd1' }
            modulePayload = @([pscustomobject]@{ path = 'outside.psm1' })
        }
        { Get-CorePesterExpectedLoadedModulePath -ManifestPath $fixtureManifest -ModuleRoot $fixtureRoot -Lock $fixtureLock } | Should -Throw
    }

    # Scenario: A one-invocation Core run records every full case identity in exactly one shard.
    # Purpose: Prevent counts-only acceptance, identity truncation, duplicate cases, and shard omissions.
    It 'UnitT40_requires_a_complete_duplicate_free_core_full_case_union' {
        $first = Get-CorePesterCaseIdentity -RelativeSourceFile 'Core.Tests.ps1' -StartOffset 11 -ExpandedPath 'Same name'
        $sameNameOtherBlock = Get-CorePesterCaseIdentity -RelativeSourceFile 'Core.Tests.ps1' -StartOffset 80 -ExpandedPath 'Same name'
        $sameNameOtherFile = Get-CorePesterCaseIdentity -RelativeSourceFile 'Other.Tests.ps1' -StartOffset 11 -ExpandedPath 'Same name'
        $longIdentity = Get-CorePesterCaseIdentity -RelativeSourceFile 'Core.Tests.ps1' -StartOffset 220 -ExpandedPath ('Long ' + ('case' * 100))
        @($first, $sameNameOtherBlock, $sameNameOtherFile, $longIdentity | Select-Object -Unique).Count | Should -Be 4
        $shard = [pscustomobject]@{ id = 'core-full'; caseIdentities = @($first, $sameNameOtherBlock, $sameNameOtherFile, $longIdentity) }
        (Test-CorePesterShardUnion -DiscoveredIdentities @($first, $sameNameOtherBlock, $sameNameOtherFile, $longIdentity) -Shards @($shard)).IsValid | Should -BeTrue

        (Test-CorePesterShardUnion -DiscoveredIdentities @($first, $sameNameOtherBlock) -Shards @([pscustomobject]@{ id = 'core-full'; caseIdentities = @($first) })).IsValid | Should -BeFalse
        (Test-CorePesterShardUnion -DiscoveredIdentities @($first) -Shards @([pscustomobject]@{ id = 'core-full'; caseIdentities = @($first, $first) })).IsValid | Should -BeFalse
        (Test-CorePesterShardUnion -DiscoveredIdentities @($first) -Shards @([pscustomobject]@{ id = 'unknown'; caseIdentities = @($first) })).IsValid | Should -BeFalse
        (Test-CorePesterShardUnion -DiscoveredIdentities @($first) -Shards @()).IsValid | Should -BeFalse
    }

    # Scenario: ForEach rows use the central identity tuple and require unique expanded paths.
    # Purpose: Reject same-name rows without placeholders and accept rows with distinguishing placeholders.
    It 'InterT41_rejects_same_name_ForEach_rows_and_accepts_placeholder_rows' {
        $duplicateIdentity = Get-CorePesterCaseIdentity -RelativeSourceFile 'same-name.Tests.ps1' -StartOffset 41 -ExpandedPath 'Same block.Same name'
        $duplicateRows = @(
            [pscustomobject]@{ identity = $duplicateIdentity; sourceFile = 'same-name.Tests.ps1'; sourceStartLine = 4; expandedPath = 'Same block.Same name'; result = 'Passed' }
            [pscustomobject]@{ identity = $duplicateIdentity; sourceFile = 'same-name.Tests.ps1'; sourceStartLine = 4; expandedPath = 'Same block.Same name'; result = 'Passed' }
        )
        $duplicate = Test-CorePesterCaseIdentityPartition -DiscoveryCases $duplicateRows -ExecutionCases $duplicateRows
        $duplicate.IsValid | Should -BeFalse
        $duplicate.Errors | Should -Contain 'Pester discovered duplicate or ambiguous case identity: same-name.Tests.ps1:4 Same block.Same name'

        $placeholderRows = @(
            [pscustomobject]@{
                identity = Get-CorePesterCaseIdentity -RelativeSourceFile 'same-name.Tests.ps1' -StartOffset 80 -ExpandedPath 'Same block.Same name alpha'
                sourceFile = 'same-name.Tests.ps1'; sourceStartLine = 9; expandedPath = 'Same block.Same name alpha'; result = 'Passed'
            }
            [pscustomobject]@{
                identity = Get-CorePesterCaseIdentity -RelativeSourceFile 'same-name.Tests.ps1' -StartOffset 80 -ExpandedPath 'Same block.Same name beta'
                sourceFile = 'same-name.Tests.ps1'; sourceStartLine = 9; expandedPath = 'Same block.Same name beta'; result = 'Passed'
            }
        )
        $accepted = Test-CorePesterCaseIdentityPartition -DiscoveryCases $placeholderRows -ExecutionCases $placeholderRows
        $accepted.IsValid | Should -BeTrue
        $shard = [pscustomobject]@{ id = 'core-full'; caseIdentities = @($placeholderRows.identity) }
        (Test-CorePesterShardUnion -DiscoveredIdentities $placeholderRows.identity -Shards @($shard)).IsValid | Should -BeTrue
    }

    # Scenario: Case result partitions preserve full identity and completion semantics.
    # Purpose: Reject the discovered-but-not-executed escape while counting expanded Pester names correctly.
    It 'UnitT45_rejects_missing_execution_and_pairs_parameterized_progress_lines' {
        $discovered = @(
            [pscustomobject]@{ identity = 'case-alpha'; sourceFile = 'fixture.Tests.ps1'; sourceStartLine = 4; expandedPath = 'Fixture.Case alpha'; result = 'Passed' }
            [pscustomobject]@{ identity = 'case-beta'; sourceFile = 'fixture.Tests.ps1'; sourceStartLine = 9; expandedPath = 'Fixture.Case beta'; result = 'Passed' }
        )
        $complete = Test-CorePesterCaseIdentityPartition -DiscoveryCases $discovered -ExecutionCases $discovered
        $complete.IsValid | Should -BeTrue
        $missing = Test-CorePesterCaseIdentityPartition -DiscoveryCases $discovered -ExecutionCases @($discovered[0])
        $missing.IsValid | Should -BeFalse
        $missing.Errors | Should -Contain 'Pester discovered a case with no execution status: fixture.Tests.ps1:9 Fixture.Case beta'
        $duplicate = Test-CorePesterCaseIdentityPartition -DiscoveryCases @($discovered[0], $discovered[0]) -ExecutionCases @($discovered[0])
        $duplicate.Errors | Should -Contain 'Pester discovered duplicate or ambiguous case identity: fixture.Tests.ps1:4 Fixture.Case alpha'

        $start = ConvertFrom-CorePesterProgressLine -Line '  [|] Case <Value>...' -ActiveCaseStarts 0
        $start.IsRecognized | Should -BeTrue
        $start.Phase | Should -Be 'case-start'
        $start.ActiveCaseStarts | Should -Be 1
        $start.CompletedDelta | Should -Be 0
        $end = ConvertFrom-CorePesterProgressLine -Line '  [+] Case alpha' -ActiveCaseStarts $start.ActiveCaseStarts
        $end.Phase | Should -Be 'case-end'
        $end.ActiveCaseStarts | Should -Be 0
        $end.CompletedDelta | Should -Be 1
        $unpaired = ConvertFrom-CorePesterProgressLine -Line '  [+] unrelated' -ActiveCaseStarts 0
        $unpaired.CompletedDelta | Should -Be 0
        (ConvertFrom-CorePesterProgressLine -Line 'unrelated diagnostic' -ActiveCaseStarts 0).IsRecognized | Should -BeFalse
    }

    # Scenario: Official package entries are classified and bound to the exact module payload lock.
    # Purpose: Reject extra, duplicate, unsafe, or byte-mismatched archive contents before runtime staging.
    It 'UnitT50_accepts_exact_package_inventory_and_rejects_unclassified_archive_entries' {
        $validPath = Join-Path $TestDrive 'pester-valid.nupkg'
        New-IntegrityPackageFixture -Path $validPath
        (Test-CorePesterPackageArchive -ArchivePath $validPath -Lock $script:closureLock.Value).IsValid | Should -BeTrue

        $unixRegularPath = Join-Path $TestDrive 'pester-unix-regular.nupkg'
        New-IntegrityPackageFixture -Path $unixRegularPath -Variant 'unix-regular-file'
        $unixRegular = Test-CorePesterPackageArchive -ArchivePath $unixRegularPath -Lock $script:closureLock.Value
        $unixRegular.IsValid | Should -BeTrue

        $unixSymlinkPath = Join-Path $TestDrive 'pester-unix-symlink.nupkg'
        New-IntegrityPackageFixture -Path $unixSymlinkPath -Variant 'unix-symlink'
        $unixSymlink = Test-CorePesterPackageArchive -ArchivePath $unixSymlinkPath -Lock $script:closureLock.Value
        $unixSymlink.IsValid | Should -BeFalse
        $unixSymlink.Errors | Should -Contain 'Pester package archive contains a symbolic link: Pester.psm1'

        foreach ($variant in @('extra', 'duplicate', 'unsafe', 'hash-mismatch', 'case-mismatch')) {
            $badPath = Join-Path $TestDrive "pester-$variant.nupkg"
            New-IntegrityPackageFixture -Path $badPath -Variant $variant
            $result = Test-CorePesterPackageArchive -ArchivePath $badPath -Lock $script:closureLock.Value
            $result.IsValid | Should -BeFalse -Because "variant $variant must fail closed"
            $result.Errors.Count | Should -BeGreaterThan 0
        }
    }

    # Scenario: Normal Core wrapper is source-bound to the exact runtime and performs no acquisition.
    # Purpose: Keep setup separate from execution and prevent ambient-module fallback or runtime downloads.
    It 'UnitT60_keeps_the_core_child_source_bound_and_rechecks_its_runtime' {
        $wrapper = Get-Content -LiteralPath (Join-Path $script:repositoryRoot 'scripts/Invoke-CorePester.ps1') -Raw -Encoding utf8
        $wrapper | Should -Not -Match '(?i)Invoke-WebRequest|Invoke-RestMethod|Install-PSResource|Install-Module|Save-Module|Save-PSResource'
        $wrapper | Should -Match 'Assert-CorePesterRuntimeInventory'
        $wrapper | Should -Match '\$moduleSearchRoot = Join-Path \$verifiedPowerShellRuntimeRoot ''Modules'''
        $wrapper | Should -Match 'SetEnvironmentVariable\(''PSModulePath'', \[IO\.Path\]::GetFullPath\(\$moduleSearchRoot\), ''Process''\)'
        $wrapper | Should -Match 'Test-CorePesterClosure'
        $wrapper | Should -Match 'Get-CorePesterExpectedLoadedModulePath'
        $wrapper | Should -Match 'Test-CorePesterLoadedModuleIdentity'
        $inventoryCall = 'Assert-CorePesterRuntimeInventory -RuntimeRoot $verifiedPowerShellRuntimeRoot'
        $preImportOffset = $wrapper.IndexOf($inventoryCall, [StringComparison]::Ordinal)
        $moduleImportOffset = $wrapper.IndexOf('Import-CorePesterModuleWithWarningsOnStderr -ManifestPath $verifiedPesterManifest', [StringComparison]::Ordinal)
        $pesterRunOffset = $wrapper.IndexOf('$result = Invoke-Pester -Configuration $pesterConfig', [StringComparison]::Ordinal)
        $postRunOffset = $wrapper.LastIndexOf($inventoryCall, [StringComparison]::Ordinal)
        $preImportOffset | Should -BeGreaterThan -1
        ($moduleImportOffset -gt $preImportOffset) | Should -BeTrue
        ($pesterRunOffset -gt $moduleImportOffset) | Should -BeTrue
        ($postRunOffset -gt $pesterRunOffset) | Should -BeTrue
        $acceptanceGateOffset = $wrapper.IndexOf('if (-not $caseInventoryLedgerWritten', [StringComparison]::Ordinal)
        $successReportOffset = $wrapper.IndexOf('[Console]::Out.WriteLine((ConvertTo-Json -InputObject $summary -Compress))', [StringComparison]::Ordinal)
        ($acceptanceGateOffset -ge 0 -and $successReportOffset -gt $acceptanceGateOffset) | Should -BeTrue
        $setup = Get-Content -LiteralPath (Join-Path $script:repositoryRoot 'scripts/Prepare-PesterRuntime.ps1') -Raw -Encoding utf8
        $setup | Should -Match 'https://www\.powershellgallery\.com/api/v2/package/Pester/6\.2\.0'
        $setup | Should -Match 'Invoke-WebRequest.*-PassThru'
        $setup | Should -Match 'observedFinalPackageUri'
        $setup | Should -Match 'Test-CorePesterPackageArchive'
        $setup | Should -Match 'Test-CorePesterPathBoundary'
        $setup | Should -Match 'Refusing unsafe recursive runtime cleanup'
        $setup | Should -Match 'Refusing unsafe recursive staging cleanup'
        $setup | Should -Not -Match 'Install-PSResource|Install-Module|CurrentUser'
    }

    # Scenario: Pester 6.2 and built-in PowerShell modules share the verified runtime Modules directory.
    # Purpose: Keep module discovery inside the owned runtime while making CimCmdlets available to Pester.
    It 'UnitT65_uses_the_verified_runtime_modules_directory_for_module_search' {
        $wrapperPath = Join-Path $script:repositoryRoot 'scripts/Invoke-CorePester.ps1'
        $tokens = $null
        $parseErrors = $null
        $wrapperAst = [System.Management.Automation.Language.Parser]::ParseFile($wrapperPath, [ref]$tokens, [ref]$parseErrors)
        $parseErrors.Count | Should -Be 0

        $moduleSearchAssignments = @($wrapperAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $node.Left.VariablePath.UserPath -ceq 'moduleSearchRoot'
        }, $true))
        $moduleSearchAssignments.Count | Should -Be 1

        $verifiedPowerShellRuntimeRoot = [IO.Path]::GetFullPath($PSHOME)
        $verifiedPesterManifest = [IO.Path]::GetFullPath((Join-Path $verifiedPowerShellRuntimeRoot 'Modules/Pester/6.2.0/Pester.psd1'))

        $moduleSearchRoot = $null
        . ([scriptblock]::Create($moduleSearchAssignments[0].Extent.Text))
        $expectedModuleSearchRoot = [IO.Path]::GetFullPath((Join-Path $verifiedPowerShellRuntimeRoot 'Modules'))
        $moduleSearchRoot | Should -BeExactly $expectedModuleSearchRoot

        $pesterOnlySearchRoot = [IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $verifiedPesterManifest)))
        $moduleSearchRoot | Should -Not -BeExactly $pesterOnlySearchRoot
        (Test-Path -LiteralPath (Join-Path $moduleSearchRoot 'CimCmdlets') -PathType Container) | Should -BeTrue
    }

    # Scenario: A valid frozen SHA-256 is checked before the binding path is returned.
    # Purpose: Keep PowerShell's automatic Matches variable from replacing the selected file record.
    It 'UnitT70_returns_a_frozen_binding_after_valid_SHA256_validation' {
        $wrapperPath = Join-Path $script:repositoryRoot 'scripts/Invoke-CorePester.ps1'
        $tokens = $null
        $parseErrors = $null
        $wrapperAst = [System.Management.Automation.Language.Parser]::ParseFile($wrapperPath, [ref]$tokens, [ref]$parseErrors)
        $parseErrors.Count | Should -Be 0
        $helperNodes = @($wrapperAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-CorePesterFrozenBinding'
        }, $true))
        $helperNodes.Count | Should -Be 1

        $sourcePath = Join-Path $TestDrive 'candidate-git-entry-modes.json'
        [IO.File]::WriteAllText($sourcePath, '{}', [Text.UTF8Encoding]::new($false))
        $sourceSpec = [pscustomobject]@{
            frozenFiles = @([pscustomobject]@{
                path = [IO.Path]::GetFullPath($sourcePath)
                sha256 = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
            })
        }
        $invokeBindingHelper = {
            param([string] $FunctionText, [pscustomobject] $BindingSource, [string] $Name)
            $sourceSpec = $BindingSource
            Invoke-Expression -Command $FunctionText
            try { Get-CorePesterFrozenBinding -Name $Name }
            finally { Remove-Item -Path 'Function:\Get-CorePesterFrozenBinding' -Force -ErrorAction SilentlyContinue }
        }
        $binding = & $invokeBindingHelper $helperNodes[0].Extent.Text $sourceSpec 'candidate-git-entry-modes.json'
        $binding.path | Should -Be ([IO.Path]::GetFullPath($sourcePath))
        $binding.sha256 | Should -Be (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()

        $invalidHashSourceSpec = [pscustomobject]@{
            frozenFiles = @([pscustomobject]@{ path = [IO.Path]::GetFullPath($sourcePath); sha256 = 'invalid-sha256' })
        }
        { & $invokeBindingHelper $helperNodes[0].Extent.Text $invalidHashSourceSpec 'candidate-git-entry-modes.json' } | Should -Throw '*exactly one frozen*'
        $ambiguousSourceSpec = [pscustomobject]@{
            frozenFiles = @($sourceSpec.frozenFiles[0], $sourceSpec.frozenFiles[0])
        }
        { & $invokeBindingHelper $helperNodes[0].Extent.Text $ambiguousSourceSpec 'candidate-git-entry-modes.json' } | Should -Throw '*exactly one frozen*'
    }

    # Scenario: A pinned Pester module emits a warning while it is imported.
    # Purpose: Preserve the warning on stderr while keeping stdout as a single machine report.
    It 'UnitT80_routes_Pester_import_warnings_to_stderr_without_polluting_machine_output' {
        $wrapperPath = Join-Path $script:repositoryRoot 'scripts/Invoke-CorePester.ps1'
        $tokens = $null
        $parseErrors = $null
        $wrapperAst = [System.Management.Automation.Language.Parser]::ParseFile($wrapperPath, [ref]$tokens, [ref]$parseErrors)
        $parseErrors.Count | Should -Be 0
        $helperNodes = @($wrapperAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Import-CorePesterModuleWithWarningsOnStderr'
        }, $true))
        $helperNodes.Count | Should -Be 1

        $moduleName = 'PesterImportWarningFixture' + [guid]::NewGuid().ToString('N')
        $commandName = 'Get-' + $moduleName
        $modulePath = Join-Path $TestDrive ($moduleName + '.psm1')
        $warningText = 'fixture import diagnostic ' + [guid]::NewGuid().ToString('N')
        $moduleText = "Write-Warning '$warningText'`nfunction $commandName { 'loaded' }`nExport-ModuleMember -Function $commandName`n"
        [IO.File]::WriteAllText($modulePath, $moduleText, [Text.UTF8Encoding]::new($false))
        $failingModuleName = $moduleName + 'Failure'
        $failingModulePath = Join-Path $TestDrive ($failingModuleName + '.psm1')
        $failureWarningText = 'fixture warning before import failure ' + [guid]::NewGuid().ToString('N')
        $failureMessage = 'fixture import failure ' + [guid]::NewGuid().ToString('N')
        $failingModuleText = "Write-Warning '$failureWarningText'`nthrow '$failureMessage'`n"
        [IO.File]::WriteAllText($failingModulePath, $failingModuleText, [Text.UTF8Encoding]::new($false))

        function Invoke-ImportBoundaryFixtureChild {
            param([Parameter(Mandatory)][string] $ScriptPath)

            $startInfo = [Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $ScriptPath)) { [void]$startInfo.ArgumentList.Add($argument) }
            $startInfo.UseShellExecute = $false
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $child = [Diagnostics.Process]::new()
            $child.StartInfo = $startInfo
            $stdout = [IO.MemoryStream]::new()
            $stderr = [IO.MemoryStream]::new()
            try {
                if (-not $child.Start()) { throw 'Could not start the import boundary fixture child.' }
                $stdoutTask = $child.StandardOutput.BaseStream.CopyToAsync($stdout)
                $stderrTask = $child.StandardError.BaseStream.CopyToAsync($stderr)
                $child.WaitForExit()
                [void]$stdoutTask.GetAwaiter().GetResult()
                [void]$stderrTask.GetAwaiter().GetResult()
                return [pscustomobject]@{ ExitCode = $child.ExitCode; Stdout = $stdout.ToArray(); Stderr = $stderr.ToArray() }
            }
            finally {
                $child.Dispose()
                $stdout.Dispose()
                $stderr.Dispose()
            }
        }

        $quotedModulePath = "'" + $modulePath.Replace("'", "''") + "'"
        $quotedCommandName = "'" + $commandName.Replace("'", "''") + "'"
        $successScriptPath = Join-Path $TestDrive 'import-warning-success.ps1'
        $successScript = @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
$($helperNodes[0].Extent.Text)
Import-CorePesterModuleWithWarningsOnStderr -ManifestPath $quotedModulePath
if (-not (Get-Command -Name $quotedCommandName -ErrorAction Stop)) { throw 'Warning fixture module command was not imported.' }
[Console]::Out.WriteLine((ConvertTo-Json -InputObject @{ report = 'machine' } -Compress))
"@
        [IO.File]::WriteAllText($successScriptPath, $successScript, [Text.UTF8Encoding]::new($false))
        $success = Invoke-ImportBoundaryFixtureChild -ScriptPath $successScriptPath
        $success.ExitCode | Should -Be 0
        $successStdout = [Text.UTF8Encoding]::new($false, $true).GetString([byte[]]$success.Stdout)
        $successStdout | Should -Be ('{"report":"machine"}' + [Environment]::NewLine)
        [Text.Encoding]::ASCII.GetString([byte[]]$success.Stderr) | Should -Match ([regex]::Escape("Pester import warning: $warningText"))

        $quotedFailingModulePath = "'" + $failingModulePath.Replace("'", "''") + "'"
        $failureScriptPath = Join-Path $TestDrive 'import-warning-failure.ps1'
        $failureScript = @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
$($helperNodes[0].Extent.Text)
Import-CorePesterModuleWithWarningsOnStderr -ManifestPath $quotedFailingModulePath
[Console]::Out.WriteLine('unexpected import success')
"@
        [IO.File]::WriteAllText($failureScriptPath, $failureScript, [Text.UTF8Encoding]::new($false))
        $failure = Invoke-ImportBoundaryFixtureChild -ScriptPath $failureScriptPath
        $failure.ExitCode | Should -Not -Be 0
        $failureStdout = [Text.UTF8Encoding]::new($false, $true).GetString([byte[]]$failure.Stdout)
        $failureStdout | Should -BeExactly ''
        $failureStderr = [Text.Encoding]::ASCII.GetString([byte[]]$failure.Stderr)
        $failureStderr | Should -Match ([regex]::Escape("Pester import warning: $failureWarningText"))
        $failureStderr | Should -Match ([regex]::Escape($failureMessage))
        Remove-Item -LiteralPath 'Function:\Invoke-ImportBoundaryFixtureChild' -Force -ErrorAction SilentlyContinue
    }
}
