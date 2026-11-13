# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:PreparerPath = Join-Path $script:RepositoryRoot 'scripts/Prepare-WorkflowPowerShell.ps1'
    $script:HostPlatform = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
    $script:HostArchitecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    $script:OtherArchitecture = if ($script:HostArchitecture -ceq 'arm64') { 'x64' } else { 'arm64' }
    $script:HostExecutableName = if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' }
    $script:AssetTemplate = 'PowerShell-{0}-test-x64.zip'
    $script:AssetName = 'PowerShell-7.9.1-test-x64.zip'
    $script:ReleasePrefix = 'https://github.com/PowerShell/PowerShell/releases/download/v7.9.1/'

    . $script:PreparerPath -Mode Verify -Platform $script:HostPlatform -ExpectedArchitecture $script:HostArchitecture `
        -ExecutableName $script:HostExecutableName -DefineFunctionsOnly

    function Get-TestSha256 {
        param([Parameter(Mandatory)][byte[]] $Bytes)
        return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
    }

    function New-TestReleaseAsset {
        param([Parameter(Mandatory)][string] $Name, [string] $Digest, [string] $Url)
        if (-not $PSBoundParameters.ContainsKey('Url')) { $Url = $script:ReleasePrefix + $Name }
        if (-not $PSBoundParameters.ContainsKey('Digest')) { $Digest = 'sha256:' + ('a' * 64) }
        return [pscustomobject]@{ name = $Name; browser_download_url = $Url; digest = $Digest }
    }

    function New-TestRelease {
        param([string] $Tag = 'v7.9.1', [bool] $Draft = $false, [bool] $Prerelease = $false, [object[]] $Assets)
        if (-not $PSBoundParameters.ContainsKey('Assets')) {
            $Assets = @(
                (New-TestReleaseAsset -Name $script:AssetName -Digest ('sha256:' + ('A' * 64))),
                (New-TestReleaseAsset -Name 'hashes.sha256' -Digest ('sha256:' + ('b' * 64)))
            )
        }
        return [pscustomobject]@{ tag_name = $Tag; draft = $Draft; prerelease = $Prerelease; assets = $Assets }
    }

    function New-TestReleaseBytes {
        param([Parameter(Mandatory)][string] $Root, [string] $ArchiveText = 'official archive bytes')
        [void](New-Item -ItemType Directory -Path $Root -Force)
        $archiveBytes = [Text.Encoding]::UTF8.GetBytes($ArchiveText)
        $archiveSha = Get-TestSha256 -Bytes $archiveBytes
        $manifestBytes = [Text.Encoding]::UTF8.GetBytes(('{0} *{1}' -f $archiveSha, $script:AssetName) + "`n" + ('{0}  other-asset.tar.gz' -f ('c' * 64)) + "`n")
        $archivePath = Join-Path $Root $script:AssetName
        $manifestPath = Join-Path $Root 'hashes.sha256'
        [IO.File]::WriteAllBytes($archivePath, $archiveBytes)
        [IO.File]::WriteAllBytes($manifestPath, $manifestBytes)
        return [pscustomobject]@{
            ArchivePath = $archivePath
            ManifestPath = $manifestPath
            ArchiveSha256 = $archiveSha
            ManifestSha256 = Get-TestSha256 -Bytes $manifestBytes
            ManifestBytes = $manifestBytes
        }
    }
}

Describe 'Prepare-WorkflowPowerShell parameter validation' {
    # Scenario: a caller passes a value outside the closed mode, platform, or architecture sets.
    # Purpose: reject unsupported workflow inputs before any network or file-system work starts.
    It 'UnitT01_rejects_values_outside_the_closed_parameter_sets' -ForEach @(
        @{ Mode = 'Download'; Platform = 'windows'; Architecture = 'x64'; Rejected = 'Mode' }
        @{ Mode = 'Verify'; Platform = 'freebsd'; Architecture = 'x64'; Rejected = 'Platform' }
        @{ Mode = 'Verify'; Platform = 'linux'; Architecture = 'x86'; Rejected = 'ExpectedArchitecture' }
    ) {
        $thrown = { & $script:PreparerPath -Mode $Mode -Platform $Platform -ExpectedArchitecture $Architecture -ExecutableName 'pwsh' -DefineFunctionsOnly } |
            Should -Throw -ExceptionType ([Management.Automation.ParameterBindingException]) -PassThru
        $thrown.Exception.ParameterName | Should -BeExactly $Rejected
        $thrown.FullyQualifiedErrorId | Should -BeLike 'ParameterArgumentValidationError*'
    }

    # Scenario: the runner architecture differs from the matrix expectation.
    # Purpose: fail before resolving or installing a runtime for the wrong architecture.
    It 'UnitT02_rejects_a_runner_architecture_mismatch' {
        { & $script:PreparerPath -Mode Verify -Platform $script:HostPlatform -ExpectedArchitecture $script:OtherArchitecture -ExecutableName $script:HostExecutableName } |
            Should -Throw ('*Expected {0} runner architecture*' -f $script:OtherArchitecture)
    }

    # Scenario: Install mode is missing a required input or receives a malformed digest.
    # Purpose: refuse to download or extract anything without the complete, well-formed verification inputs.
    It 'UnitT03_requires_complete_install_inputs_and_lowercase_digests' {
        $installArguments = @{
            Mode = 'Install'; Platform = $script:HostPlatform; ExpectedArchitecture = $script:HostArchitecture
            ExecutableName = $script:HostExecutableName; RuntimeRoot = (Join-Path $TestDrive 'runtime')
            OwnedRoot = $TestDrive; ArtifactsRoot = $TestDrive; Version = '7.9.1'; ReleaseTag = 'v7.9.1'
            AssetName = $script:AssetName; ArchiveUrl = ($script:ReleasePrefix + $script:AssetName)
            HashesUrl = ($script:ReleasePrefix + 'hashes.sha256'); OfficialArchiveSha256 = ('a' * 64)
            HashesManifestSha256 = ('b' * 64); FreshHashesPath = (Join-Path $TestDrive 'fresh.sha256')
        }
        $savedEnvironment = $env:GITHUB_ENV
        $savedPath = $env:GITHUB_PATH
        try {
            $env:GITHUB_ENV = Join-Path $TestDrive 'github-env.txt'
            $env:GITHUB_PATH = Join-Path $TestDrive 'github-path.txt'
            { & $script:PreparerPath @installArguments } | Should -Throw '*CacheRoot is required for workflow PowerShell Install mode*'
            $installArguments.CacheRoot = Join-Path $TestDrive 'cache'
            $installArguments.OfficialArchiveSha256 = 'A' * 64
            { & $script:PreparerPath @installArguments } | Should -Throw '*must be lowercase hex*'
            $installArguments.OfficialArchiveSha256 = 'a' * 64
            $env:GITHUB_PATH = $null
            { & $script:PreparerPath @installArguments } | Should -Throw '*GITHUB_PATH is required*'
            Test-Path -LiteralPath $installArguments.CacheRoot | Should -BeFalse
        }
        finally {
            $env:GITHUB_ENV = $savedEnvironment
            $env:GITHUB_PATH = $savedPath
        }
    }

    # Scenario: Verify mode runs without the runtime identity exported by Install mode.
    # Purpose: never treat an unbound step shell as the verified runtime.
    It 'UnitT04_requires_the_exported_runtime_identity_in_verify_mode' {
        $saved = @{
            Executable = $env:SOURCE_POWERSHELL_EXECUTABLE
            Version = $env:SOURCE_POWERSHELL_VERSION
            Sha = $env:SOURCE_POWERSHELL_ARCHIVE_SHA256
        }
        try {
            $env:SOURCE_POWERSHELL_EXECUTABLE = $null
            $env:SOURCE_POWERSHELL_VERSION = $null
            $env:SOURCE_POWERSHELL_ARCHIVE_SHA256 = $null
            { & $script:PreparerPath -Mode Verify -Platform $script:HostPlatform -ExpectedArchitecture $script:HostArchitecture -ExecutableName $script:HostExecutableName } |
                Should -Throw '*SOURCE_POWERSHELL_EXECUTABLE is required*'
            $env:SOURCE_POWERSHELL_EXECUTABLE = [Environment]::ProcessPath
            $env:SOURCE_POWERSHELL_VERSION = $PSVersionTable.PSVersion.ToString()
            $env:SOURCE_POWERSHELL_ARCHIVE_SHA256 = 'not-a-digest'
            { & $script:PreparerPath -Mode Verify -Platform $script:HostPlatform -ExpectedArchitecture $script:HostArchitecture -ExecutableName $script:HostExecutableName } |
                Should -Throw '*SOURCE_POWERSHELL_ARCHIVE_SHA256 is invalid*'
        }
        finally {
            $env:SOURCE_POWERSHELL_EXECUTABLE = $saved.Executable
            $env:SOURCE_POWERSHELL_VERSION = $saved.Version
            $env:SOURCE_POWERSHELL_ARCHIVE_SHA256 = $saved.Sha
        }
    }
}

Describe 'Prepare-WorkflowPowerShell release asset selection' {
    # Scenario: the latest release is stable and publishes the exact archive and hashes.sha256 with API digests.
    # Purpose: select only the templated platform archive and normalize the official digests.
    It 'UnitT10_selects_the_exact_platform_archive_and_manifest' {
        $selection = Select-WorkflowPowerShellReleaseAsset -Release (New-TestRelease) -AssetTemplate $script:AssetTemplate
        $selection.Version | Should -BeExactly '7.9.1'
        $selection.Tag | Should -BeExactly 'v7.9.1'
        $selection.AssetName | Should -BeExactly $script:AssetName
        $selection.ArchiveUrl | Should -BeExactly ($script:ReleasePrefix + $script:AssetName)
        $selection.HashesUrl | Should -BeExactly ($script:ReleasePrefix + 'hashes.sha256')
        $selection.ArchiveApiSha256 | Should -BeExactly ('a' * 64)
        $selection.ManifestApiSha256 | Should -BeExactly ('b' * 64)
    }

    # Scenario: the release is a draft, a prerelease, or not a plain semantic version tag.
    # Purpose: only the official latest stable release can supply the workflow runtime.
    It 'UnitT11_rejects_non_stable_releases' -ForEach @(
        @{ Tag = 'v7.9.1'; Draft = $true; Prerelease = $false }
        @{ Tag = 'v7.9.1'; Draft = $false; Prerelease = $true }
        @{ Tag = 'v7.9.1-rc.1'; Draft = $false; Prerelease = $false }
        @{ Tag = '7.9.1'; Draft = $false; Prerelease = $false }
    ) {
        { Select-WorkflowPowerShellReleaseAsset -Release (New-TestRelease -Tag $Tag -Draft $Draft -Prerelease $Prerelease) -AssetTemplate $script:AssetTemplate } |
            Should -Throw '*not a stable semantic-version release*'
    }

    # Scenario: the archive or hashes.sha256 is missing or published more than once.
    # Purpose: refuse ambiguous or incomplete release asset sets.
    It 'UnitT12_rejects_missing_or_duplicate_assets' {
        $archive = New-TestReleaseAsset -Name $script:AssetName
        $manifest = New-TestReleaseAsset -Name 'hashes.sha256'
        foreach ($assets in @(@($archive), @($manifest), @($archive, $archive, $manifest), @($archive, $manifest, $manifest))) {
            { Select-WorkflowPowerShellReleaseAsset -Release (New-TestRelease -Assets $assets) -AssetTemplate $script:AssetTemplate } |
                Should -Throw '*missing the exact platform archive or hashes.sha256*'
        }
    }

    # Scenario: an asset points outside the official tag download prefix or lacks a SHA-256 API digest.
    # Purpose: accept only immutable official GitHub release URLs with a published digest.
    It 'UnitT13_rejects_unofficial_urls_and_missing_digests' -ForEach @(
        @{ Url = 'http://github.com/PowerShell/PowerShell/releases/download/v7.9.1/PowerShell-7.9.1-test-x64.zip'; Digest = 'sha256:' + ('a' * 64) }
        @{ Url = 'https://example.invalid/PowerShell/PowerShell/releases/download/v7.9.1/PowerShell-7.9.1-test-x64.zip'; Digest = 'sha256:' + ('a' * 64) }
        @{ Url = 'https://github.com/PowerShell/PowerShell/releases/download/v7.9.0/PowerShell-7.9.1-test-x64.zip'; Digest = 'sha256:' + ('a' * 64) }
        @{ Url = 'https://github.com/PowerShell/PowerShell/releases/download/v7.9.1/PowerShell-7.9.1-test-x64.zip'; Digest = '' }
        @{ Url = 'https://github.com/PowerShell/PowerShell/releases/download/v7.9.1/PowerShell-7.9.1-test-x64.zip'; Digest = 'sha512:' + ('a' * 64) }
    ) {
        $assets = @(
            (New-TestReleaseAsset -Name $script:AssetName -Url $Url -Digest $Digest),
            (New-TestReleaseAsset -Name 'hashes.sha256')
        )
        { Select-WorkflowPowerShellReleaseAsset -Release (New-TestRelease -Assets $assets) -AssetTemplate $script:AssetTemplate } |
            Should -Throw '*lacks an official immutable URL or SHA-256 digest*'
    }
}

Describe 'Prepare-WorkflowPowerShell digest verification' {
    # Scenario: hashes.sha256 bytes and its archive entry agree with both release API digests.
    # Purpose: accept the double-verified official release metadata.
    It 'UnitT20_accepts_matching_api_and_manifest_digests' {
        $bytes = New-TestReleaseBytes -Root (Join-Path $TestDrive 'match')
        { Assert-WorkflowPowerShellManifestDigest -ManifestPath $bytes.ManifestPath -ArchiveName $script:AssetName `
            -ManifestApiSha256 $bytes.ManifestSha256 -ArchiveApiSha256 $bytes.ArchiveSha256 } | Should -Not -Throw
    }

    # Scenario: the downloaded manifest or its archive entry disagrees with the release API digest.
    # Purpose: fail closed instead of trusting either digest source alone.
    It 'UnitT21_fails_closed_when_api_and_manifest_digests_disagree' {
        $bytes = New-TestReleaseBytes -Root (Join-Path $TestDrive 'mismatch')
        { Assert-WorkflowPowerShellManifestDigest -ManifestPath $bytes.ManifestPath -ArchiveName $script:AssetName `
            -ManifestApiSha256 ('0' * 64) -ArchiveApiSha256 $bytes.ArchiveSha256 } | Should -Throw '*hashes.sha256 bytes differ*'
        { Assert-WorkflowPowerShellManifestDigest -ManifestPath $bytes.ManifestPath -ArchiveName $script:AssetName `
            -ManifestApiSha256 $bytes.ManifestSha256 -ArchiveApiSha256 ('0' * 64) } | Should -Throw '*archive API digest differs from hashes.sha256*'
    }

    # Scenario: hashes.sha256 has no entry or several entries for the selected archive.
    # Purpose: require exactly one official manifest digest for the archive name.
    It 'UnitT22_requires_one_exact_manifest_entry' {
        $manifestPath = Join-Path $TestDrive 'ambiguous.sha256'
        [IO.File]::WriteAllText($manifestPath, (('{0}  {1}' -f ('a' * 64), $script:AssetName) + "`n" + ('{0}  {1}' -f ('b' * 64), $script:AssetName) + "`n"))
        { Get-OfficialManifestArchiveSha256 -ManifestPath $manifestPath -ArchiveName $script:AssetName } | Should -Throw '*one exact*digest*'
        [IO.File]::WriteAllText($manifestPath, ('{0}  {1}.sig' -f ('a' * 64), $script:AssetName) + "`n")
        { Get-OfficialManifestArchiveSha256 -ManifestPath $manifestPath -ArchiveName $script:AssetName } | Should -Throw '*one exact*digest*'
    }

    # Scenario: the release metadata resolves but the downloaded hashes.sha256 differs from its API digest.
    # Purpose: Resolve mode fails closed before publishing any step output.
    It 'UnitT23_resolve_mode_fails_closed_without_writing_outputs' {
        $bytes = New-TestReleaseBytes -Root (Join-Path $TestDrive 'resolve-source')
        $release = New-TestRelease -Assets @(
            (New-TestReleaseAsset -Name $script:AssetName -Digest ('sha256:' + $bytes.ArchiveSha256)),
            (New-TestReleaseAsset -Name 'hashes.sha256' -Digest ('sha256:' + ('0' * 64)))
        )
        $releaseJsonPath = Join-Path $TestDrive 'resolve-release.json'
        [IO.File]::WriteAllText($releaseJsonPath, ($release | ConvertTo-Json -Depth 5))
        $quotedReleaseJsonPath = "'" + $releaseJsonPath.Replace("'", "''") + "'"
        $quotedManifestPath = "'" + $bytes.ManifestPath.Replace("'", "''") + "'"
        $webMock = [scriptblock]::Create((@(
            'if (-not [string]::IsNullOrEmpty($OutFile)) {'
            ('    [IO.File]::Copy({0}, $OutFile, $true)' -f $quotedManifestPath)
            '    return'
            '}'
            '[pscustomobject]@{'
            ('    Content = [IO.File]::ReadAllText({0})' -f $quotedReleaseJsonPath)
            '    BaseResponse = [pscustomobject]@{ RequestMessage = [pscustomobject]@{ RequestUri = [Uri]''https://api.github.com/repos/PowerShell/PowerShell/releases/latest'' } }'
            '}'
        ) -join "`n"))
        Mock Invoke-WebRequest -MockWith $webMock
        $saved = @{ Output = $env:GITHUB_OUTPUT; Tmp = $env:TMP; Temp = $env:TEMP; TmpDir = $env:TMPDIR }
        $tempRoot = Join-Path $TestDrive 'resolve-temp'
        [void](New-Item -ItemType Directory -Path $tempRoot -Force)
        $outputPath = Join-Path $TestDrive 'github-output.txt'
        try {
            $env:GITHUB_OUTPUT = $outputPath
            $env:TMP = $tempRoot; $env:TEMP = $tempRoot; $env:TMPDIR = $tempRoot
            { & $script:PreparerPath -Mode Resolve -Platform $script:HostPlatform -ExpectedArchitecture $script:HostArchitecture `
                -ExecutableName $script:HostExecutableName -AssetTemplate $script:AssetTemplate } | Should -Throw '*hashes.sha256 bytes differ*'
        }
        finally {
            $env:GITHUB_OUTPUT = $saved.Output; $env:TMP = $saved.Tmp; $env:TEMP = $saved.Temp; $env:TMPDIR = $saved.TmpDir
        }
        Test-Path -LiteralPath $outputPath | Should -BeFalse
        Should -Invoke Invoke-WebRequest -ParameterFilter { -not [string]::IsNullOrEmpty($OutFile) } -Times 1 -Exactly
        Should -Invoke Invoke-WebRequest -ParameterFilter { [string]::IsNullOrEmpty($OutFile) } -Times 1 -Exactly
    }

    # Scenario: the release metadata request is redirected away from the GitHub API host.
    # Purpose: never trust release metadata served by another host.
    It 'UnitT24_resolve_mode_rejects_a_redirected_metadata_host' {
        Mock Invoke-WebRequest -MockWith {
            [pscustomobject]@{
                Content = '{}'
                BaseResponse = [pscustomobject]@{ RequestMessage = [pscustomobject]@{ RequestUri = [Uri]'https://example.invalid/releases/latest' } }
            }
        }
        $savedOutput = $env:GITHUB_OUTPUT
        try {
            $env:GITHUB_OUTPUT = Join-Path $TestDrive 'redirect-output.txt'
            { & $script:PreparerPath -Mode Resolve -Platform $script:HostPlatform -ExpectedArchitecture $script:HostArchitecture `
                -ExecutableName $script:HostExecutableName -AssetTemplate $script:AssetTemplate } | Should -Throw '*redirected to an unexpected host*'
        }
        finally { $env:GITHUB_OUTPUT = $savedOutput }
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
    }
}

Describe 'Prepare-WorkflowPowerShell cache revalidation' {
    # Scenario: a restored cache entry matches both official digests and the manifest entry.
    # Purpose: reuse only fully revalidated cache bytes.
    It 'UnitT30_keeps_a_fully_matching_cache_entry' {
        $bytes = New-TestReleaseBytes -Root (Join-Path $TestDrive 'cache-valid')
        Test-WorkflowPowerShellCacheEntry -ArchivePath $bytes.ArchivePath -ManifestPath $bytes.ManifestPath -ArchiveName $script:AssetName `
            -OfficialArchiveSha256 $bytes.ArchiveSha256 -HashesManifestSha256 $bytes.ManifestSha256 | Should -BeTrue
        Test-Path -LiteralPath $bytes.ArchivePath | Should -BeTrue
        Test-Path -LiteralPath $bytes.ManifestPath | Should -BeTrue
    }

    # Scenario: the restored archive, manifest, or manifest entry no longer matches the official digests.
    # Purpose: discard the whole cache entry rather than trusting any part of it.
    It 'UnitT31_discards_a_cache_entry_that_fails_revalidation' -ForEach @(
        @{ Case = 'archive'; Reason = 'cached archive hash mismatch' }
        @{ Case = 'manifest'; Reason = 'cached manifest hash mismatch' }
        @{ Case = 'entry'; Reason = 'cached manifest entry mismatch' }
    ) {
        $bytes = New-TestReleaseBytes -Root (Join-Path $TestDrive ('cache-' + $Case))
        $officialArchive = $bytes.ArchiveSha256
        $officialManifest = $bytes.ManifestSha256
        switch ($Case) {
            'archive' { [IO.File]::WriteAllText($bytes.ArchivePath, 'tampered archive bytes') }
            'manifest' { [IO.File]::AppendAllText($bytes.ManifestPath, "# tampered`n") }
            'entry' {
                [IO.File]::WriteAllText($bytes.ManifestPath, ('{0}  {1}' -f ('d' * 64), $script:AssetName) + "`n")
                $officialManifest = (Get-FileHash -LiteralPath $bytes.ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
        $warnings = $null
        $result = Test-WorkflowPowerShellCacheEntry -ArchivePath $bytes.ArchivePath -ManifestPath $bytes.ManifestPath -ArchiveName $script:AssetName `
            -OfficialArchiveSha256 $officialArchive -HashesManifestSha256 $officialManifest -WarningVariable warnings -WarningAction SilentlyContinue
        $result | Should -BeFalse
        Test-Path -LiteralPath $bytes.ArchivePath | Should -BeFalse
        Test-Path -LiteralPath $bytes.ManifestPath | Should -BeFalse
        @($warnings).Count | Should -Be 1
        [string]$warnings[0] | Should -BeLike ('Discarded invalid PowerShell cache entry: {0}' -f $Reason)
    }

    # Scenario: only one half of a cache entry is present.
    # Purpose: treat a partial cache as a miss.
    It 'UnitT32_treats_a_partial_cache_entry_as_a_miss' {
        $bytes = New-TestReleaseBytes -Root (Join-Path $TestDrive 'cache-partial')
        Remove-Item -LiteralPath $bytes.ManifestPath
        Test-WorkflowPowerShellCacheEntry -ArchivePath $bytes.ArchivePath -ManifestPath $bytes.ManifestPath -ArchiveName $script:AssetName `
            -OfficialArchiveSha256 $bytes.ArchiveSha256 -HashesManifestSha256 $bytes.ManifestSha256 | Should -BeFalse
    }

    # Scenario: the cache is tampered and the replacement download also differs from the official digest.
    # Purpose: Install mode discards the cache, re-downloads once, and fails closed before extraction or export.
    It 'UnitT33_install_mode_fails_closed_after_discarding_a_tampered_cache' {
        $official = New-TestReleaseBytes -Root (Join-Path $TestDrive 'install-official')
        $cacheRoot = Join-Path $TestDrive 'install-cache'
        $cached = New-TestReleaseBytes -Root $cacheRoot -ArchiveText 'tampered cached archive'
        $runtimeRoot = Join-Path $TestDrive 'install-runtime'
        [void](New-Item -ItemType Directory -Path $runtimeRoot -Force)
        Mock Invoke-WebRequest -MockWith { [IO.File]::WriteAllText($OutFile, 'tampered download bytes') }
        $saved = @{ Environment = $env:GITHUB_ENV; Path = $env:GITHUB_PATH }
        $environmentPath = Join-Path $TestDrive 'install-github-env.txt'
        $pathFile = Join-Path $TestDrive 'install-github-path.txt'
        try {
            $env:GITHUB_ENV = $environmentPath
            $env:GITHUB_PATH = $pathFile
            {
                & $script:PreparerPath -Mode Install -Platform $script:HostPlatform -ExpectedArchitecture $script:HostArchitecture `
                    -ExecutableName $script:HostExecutableName -RuntimeRoot $runtimeRoot -OwnedRoot $TestDrive -ArtifactsRoot $TestDrive `
                    -CacheRoot $cacheRoot -Version '7.9.1' -ReleaseTag 'v7.9.1' -AssetName $script:AssetName `
                    -ArchiveUrl ($script:ReleasePrefix + $script:AssetName) -HashesUrl ($script:ReleasePrefix + 'hashes.sha256') `
                    -OfficialArchiveSha256 $official.ArchiveSha256 -HashesManifestSha256 $official.ManifestSha256 `
                    -FreshHashesPath $official.ManifestPath -WarningAction SilentlyContinue
            } | Should -Throw '*failed mandatory post-cache verification*'
        }
        finally {
            $env:GITHUB_ENV = $saved.Environment
            $env:GITHUB_PATH = $saved.Path
        }
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { [string]$Uri -ceq ($script:ReleasePrefix + $script:AssetName) }
        [IO.File]::ReadAllText($cached.ArchivePath) | Should -BeExactly 'tampered download bytes'
        @(Get-ChildItem -LiteralPath $runtimeRoot -Force).Count | Should -Be 0
        Test-Path -LiteralPath $environmentPath | Should -BeFalse
        Test-Path -LiteralPath $pathFile | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $TestDrive 'powershell-runtime-setup.json') | Should -BeFalse
    }

    # Scenario: the verified runtime root already contains entries.
    # Purpose: install only into a fresh empty runtime root.
    It 'UnitT34_requires_an_empty_fresh_runtime_root' {
        $runtimeRoot = Join-Path $TestDrive 'empty-powershell-runtime'
        [void](New-Item -ItemType Directory -Path $runtimeRoot -Force)
        { Assert-WorkflowRuntimeRootEmpty -Path $runtimeRoot } | Should -Not -Throw
        [IO.File]::WriteAllText((Join-Path $runtimeRoot 'unexpected.txt'), 'unexpected')
        { Assert-WorkflowRuntimeRootEmpty -Path $runtimeRoot } | Should -Throw '*fresh and empty*'
    }
}

Describe 'Prepare-WorkflowPowerShell source contract' {
    # Scenario: the helper source is reviewed for the protections that cannot run offline.
    # Purpose: keep Authenticode, physical-path identity, bounded retries, and repository-neutral names in place.
    It 'UnitT40_keeps_the_offline_unreachable_protections' {
        $source = Get-Content -LiteralPath $script:PreparerPath -Raw
        $source | Should -Match 'Get-AuthenticodeSignature'
        $source | Should -Match 'CN=Microsoft Corporation'
        $source | Should -Match '\$pshomeExecutable = Resolve-WorkflowPhysicalPath'
        $source | Should -Match '\$releaseUri\.Host -ceq ''api\.github\.com'''
        $source | Should -Match '\$attempt -le 3'
        $source | Should -Match '\$statusCode -eq 403 -or \$statusCode -eq 429 -or \$statusCode -ge 500'
        $source | Should -Not -Match 'PreserveAuthorizationOnRedirect\s+-'
        $source | Should -Not -Match '\$matches\s*='
        $source | Should -Not -Match '\bKC_|KnowledgeContent|Knowledge-Content'
        $source | Should -Not -Match 'Invoke-WebRequest -Uri \$selection\.HashesUrl.*-Headers'
    }
}
