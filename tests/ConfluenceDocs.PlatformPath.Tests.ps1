# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeDiscovery {
    # Unix hosts may still mount a case-insensitive file system (macOS APFS default).
    # The case-sensitivity scenario registers only where the native file system distinguishes case.
    $script:caseSensitiveFileSystem = $false
    if (-not $IsWindows) {
        $probe = Join-Path ([IO.Path]::GetTempPath()) ('confluence-platform-path-probe-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $probe 'CaseProbe') -Force | Out-Null
        try { $script:caseSensitiveFileSystem = -not (Test-Path -LiteralPath (Join-Path $probe 'caseprobe')) }
        finally { Remove-Item -LiteralPath $probe -Recurse -Force }
    }
}

BeforeAll {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $repositoryRoot = Split-Path -Parent $PSScriptRoot
    $scriptRoot = Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts'
    foreach ($name in @('ConfluenceMapping','MarkdownProjection','ConfluenceAssets','ConfluenceValidation','ImportReview','ConfluenceCodeBinding')) {
        Import-Module -Name (Join-Path $scriptRoot ($name + '.psm1')) -Force
    }

    function New-PlatformPathFixture {
        $root = Join-Path $TestDrive ('CaseRoot-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path (Join-Path $root 'docs/nested') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'docs/nested/page.md'), 'page', [Text.UTF8Encoding]::new($false))
        return [IO.Path]::GetFullPath($root)
    }

    function Get-CaseVariant {
        param([string] $Path)
        $leaf = [IO.Path]::GetFileName($Path)
        return Join-Path ([IO.Path]::GetDirectoryName($Path)) $leaf.ToLowerInvariant()
    }

    function Get-PhysicalPath {
        param([string] $Path)
        $physical = & /bin/sh -c 'cd "$1" && pwd -P' sh $Path
        if ($LASTEXITCODE -ne 0) { throw 'Physical path lookup failed.' }
        return ([string]$physical).Trim()
    }

    function Invoke-PathHelper {
        param([string] $Helper, [string] $Root, [string] $Relative)
        switch ($Helper) {
            'Test-RelativeSourcePath' {
                return InModuleScope ConfluenceMapping -Parameters @{ R = $Root; P = $Relative } { param($R, $P) Test-RelativeSourcePath -Root $R -RelativePath $P }
            }
            'Test-MarkdownProjectRelativePath' {
                return InModuleScope MarkdownProjection -Parameters @{ R = $Root; P = $Relative } { param($R, $P) Test-MarkdownProjectRelativePath -Root $R -RelativePath $P }
            }
            'Test-AssetRelativePath' {
                return InModuleScope ConfluenceAssets -Parameters @{ R = $Root; P = $Relative } { param($R, $P) Test-AssetRelativePath -Root $R -RelativePath $P }
            }
            'Resolve-ReviewRelativePath' {
                return InModuleScope ConfluenceValidation -Parameters @{ R = $Root; P = $Relative } { param($R, $P) Resolve-ReviewRelativePath -Root $R -Relative $P }
            }
            'Resolve-CaptureArtifact' {
                return InModuleScope ImportReview -Parameters @{ R = $Root; P = $Relative } { param($R, $P) Resolve-CaptureArtifact -CaptureRoot $R -Relative $P }
            }
            default { throw ('Unknown helper {0}' -f $Helper) }
        }
    }

    function Assert-HelperAccepted {
        param([string] $Helper, [object] $Result, [string] $ExpectedFull)
        if ($Helper -in @('Resolve-ReviewRelativePath', 'Resolve-CaptureArtifact')) {
            $Result | Should -BeExactly $ExpectedFull
        } else {
            $Result | Should -BeTrue
        }
    }

    function New-CodeBindingFixture {
        $root = Join-Path $TestDrive ('BindRoot-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path (Join-Path $root 'src') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'docs') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root '.confluence') -Force | Out-Null
        & git -C $root init --quiet | Out-Null
        & git -C $root config user.name 'Platform path fixture' | Out-Null
        & git -C $root config user.email 'fixture@example.invalid' | Out-Null
        & git -C $root config core.autocrlf false | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'src/app.txt'), 'behavior', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root 'docs/current.md'), 'Current behavior', [Text.UTF8Encoding]::new($false))
        & git -C $root add -- src/app.txt docs/current.md | Out-Null
        & git -C $root commit --quiet -m 'Fixture baseline' | Out-Null
        $commit = (& git -C $root rev-parse HEAD).Trim()
        $bindingPath = Join-Path $root '.confluence/code-binding.json'
        $reviewPath = Join-Path $root '.confluence/code-review.json'
        $binding = [ordered]@{
            schemaVersion = 2; targetKind = 'current'
            docs = @{ repositoryPath = '.'; commit = $commit; sourcePaths = @('docs/current.md') }
            code = @{ repositoryPath = '.'; commit = $commit; relevantPaths = @('src/app.txt') }
        }
        [IO.File]::WriteAllText($bindingPath, ($binding | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
        $bindingHash = (Get-FileHash -LiteralPath $bindingPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $review = [ordered]@{
            schemaVersion = 1; outcome = 'still-correct'; docsCommit = $commit; codeCommit = $commit
            bindingSha256 = $bindingHash; evidencePaths = @('src/app.txt')
        }
        [IO.File]::WriteAllText($reviewPath, ($review | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        return [pscustomobject]@{ root = [IO.Path]::GetFullPath($root); commit = $commit }
    }

    function Invoke-CodeBinding {
        param([string] $Root, [string] $Commit)
        return Resolve-ConfluenceMarkdownCodeBinding -Root $Root -BindingPath (Join-Path $Root '.confluence/code-binding.json') -DocsCommit $Commit -RequiredDocsSourcePaths @('docs/current.md') -ReviewPath (Join-Path $Root '.confluence/code-review.json')
    }
}

Describe 'Confluence docs-as-code platform path comparison' {
    BeforeDiscovery {
        $script:helperCases = @(
            @{ Helper = 'Test-RelativeSourcePath' }
            @{ Helper = 'Test-MarkdownProjectRelativePath' }
            @{ Helper = 'Test-AssetRelativePath' }
            @{ Helper = 'Resolve-ReviewRelativePath' }
            @{ Helper = 'Resolve-CaptureArtifact' }
        )
        $script:existenceHelperCases = @(
            @{ Helper = 'Resolve-ReviewRelativePath' }
            @{ Helper = 'Resolve-CaptureArtifact' }
        )
    }

    Context 'Every host' {
        # Scenario: A nested project path is checked against the exact root spelling.
        # Purpose: The platform comparer stops the ancestor walk at the root on every host.
        It '<Helper> accepts a nested path under the root' -ForEach $script:helperCases {
            $root = New-PlatformPathFixture
            $result = Invoke-PathHelper -Helper $Helper -Root $root -Relative 'docs/nested/page.md'
            Assert-HelperAccepted -Helper $Helper -Result $result -ExpectedFull (Join-Path $root 'docs/nested/page.md')
        }

        # Scenario: Resolve-CaptureArtifact receives a capture root with a trailing separator.
        # Purpose: Root normalization trims only the trailing separator and keeps containment exact.
        It 'Resolve-CaptureArtifact accepts a capture root with a trailing separator' {
            $root = New-PlatformPathFixture
            $result = Invoke-PathHelper -Helper 'Resolve-CaptureArtifact' -Root ($root + [IO.Path]::DirectorySeparatorChar) -Relative 'docs/nested/page.md'
            $result | Should -BeExactly (Join-Path $root 'docs/nested/page.md')
        }

        # Scenario: Resolve-CaptureArtifact receives a missing artifact under a valid root.
        # Purpose: Containment success alone never resolves a missing artifact.
        It 'Resolve-CaptureArtifact rejects a missing artifact' {
            $root = New-PlatformPathFixture
            Invoke-PathHelper -Helper 'Resolve-CaptureArtifact' -Root $root -Relative 'docs/nested/missing.md' | Should -BeNullOrEmpty
        }

        # Scenario: A current-code binding resolves with the exact root spelling.
        # Purpose: Both binding ancestor walks terminate at the docs and code repository roots.
        It 'Resolve-ConfluenceMarkdownCodeBinding resolves with the exact root spelling' {
            $fixture = New-CodeBindingFixture
            $result = Invoke-CodeBinding -Root $fixture.root -Commit $fixture.commit
            $result.status | Should -BeExactly 'valid'
            $result.codeCommit | Should -BeExactly $fixture.commit
        }
    }

    # Register only on the native host: Windows treats a differently cased root as the same path.
    if ($IsWindows) {
        Context 'Windows native path comparison' {
            # Scenario: The caller spells the project root in a different case than the directory on disk.
            # Purpose: OrdinalIgnoreCase treats the differently cased root as the same Windows path.
            It '<Helper> accepts a differently cased root on Windows' -ForEach $script:helperCases {
                $root = New-PlatformPathFixture
                $variant = Get-CaseVariant -Path $root
                $variant | Should -Not -BeExactly $root
                $result = Invoke-PathHelper -Helper $Helper -Root $variant -Relative 'docs/nested/page.md'
                Assert-HelperAccepted -Helper $Helper -Result $result -ExpectedFull (Join-Path $variant 'docs/nested/page.md')
            }

            # Scenario: The capture root drive root keeps its separator after normalization.
            # Purpose: A drive root never becomes a drive-relative path such as C: during containment.
            It 'Resolve-CaptureArtifact keeps a drive root separator' {
                $root = New-PlatformPathFixture
                $driveRoot = [IO.Path]::GetPathRoot($root)
                $relative = $root.Substring($driveRoot.Length).Replace('\', '/') + '/docs/nested/page.md'
                $result = Invoke-PathHelper -Helper 'Resolve-CaptureArtifact' -Root $driveRoot -Relative $relative
                $result | Should -BeExactly (Join-Path $root 'docs/nested/page.md')
            }

            # Scenario: A current-code binding is resolved through a differently cased root.
            # Purpose: The binding ancestor walks treat the differently cased root as the same Windows path.
            It 'Resolve-ConfluenceMarkdownCodeBinding resolves through a differently cased root on Windows' {
                $fixture = New-CodeBindingFixture
                $variant = Get-CaseVariant -Path $fixture.root
                $variant | Should -Not -BeExactly $fixture.root
                $result = Invoke-CodeBinding -Root $variant -Commit $fixture.commit
                $result.status | Should -BeExactly 'valid'
            }
        }
    }

    # Register only on the native host: Unix hosts keep the root "/" and compare paths ordinally.
    if (-not $IsWindows) {
        Context 'Unix native path comparison' {
            # Scenario: The project root is the file system root "/".
            # Purpose: Root normalization keeps "/" and the ancestor walk stops at it.
            It '<Helper> accepts a nested path when the root is /' -ForEach $script:helperCases {
                $root = Get-PhysicalPath -Path (New-PlatformPathFixture)
                $relative = $root.TrimStart('/') + '/docs/nested/page.md'
                $result = Invoke-PathHelper -Helper $Helper -Root '/' -Relative $relative
                Assert-HelperAccepted -Helper $Helper -Result $result -ExpectedFull (Join-Path $root 'docs/nested/page.md')
            }

            if ($script:caseSensitiveFileSystem) {
                # Scenario: The caller spells the project root in a different case on a case-sensitive file system.
                # Purpose: Ordinal comparison treats the differently cased root as a different Unix path.
                It '<Helper> rejects a differently cased root on Unix' -ForEach $script:existenceHelperCases {
                    $root = New-PlatformPathFixture
                    $variant = Get-CaseVariant -Path $root
                    New-Item -ItemType Directory -Path (Join-Path $variant 'docs/nested') -Force | Out-Null
                    Invoke-PathHelper -Helper $Helper -Root $variant -Relative 'docs/nested/page.md' | Should -BeNullOrEmpty
                }

                # Scenario: A current-code binding is resolved through a differently cased root on Unix.
                # Purpose: The differently cased root is a different path, so the binding cannot resolve.
                It 'Resolve-ConfluenceMarkdownCodeBinding rejects a differently cased root on Unix' {
                    $fixture = New-CodeBindingFixture
                    $variant = Get-CaseVariant -Path $fixture.root
                    New-Item -ItemType Directory -Path $variant -Force | Out-Null
                    $result = Invoke-CodeBinding -Root $variant -Commit $fixture.commit
                    $result.status | Should -Not -Be 'valid'
                }
            }
        }
    }
}
