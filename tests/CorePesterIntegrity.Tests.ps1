# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Complete Pester tree integrity' {
    BeforeAll {
        $script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $script:TestFiles = @(Get-ChildItem -LiteralPath (Join-Path $script:RepositoryRoot 'tests') -Recurse -File -Filter '*.Tests.ps1' -Force | Sort-Object FullName)
        $script:ConversionTestNames = @(
            'AtomicOutput.Tests.ps1'
            'CanonicalValidation.Tests.ps1'
            'CentralRunner.Tests.ps1'
            'CorePesterIntegrity.Tests.ps1'
            'ProtectedRunner.Tests.ps1'
            'RepositoryValidation.Tests.ps1'
            'ShardedPesterQueue.Tests.ps1'
            'SharedReferences.Tests.ps1'
            'SkillSpectorExceptions.Tests.ps1'
            'SourcePackageBridge.Tests.ps1'
            'SourceStaticBridge.Tests.ps1'
            'SourceValidationPreparation.Tests.ps1'
            'StandardV1Conformance.Tests.ps1'
            'Test-Repository.Tests.ps1'
        )
    }

    It 'contains parseable test files with at least one case each' {
        foreach ($file in $script:TestFiles) {
            $tokens = $null
            $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
            @($errors) | Should -HaveCount 0
            @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'It' }, $true)).Count | Should -BeGreaterThan 0
        }
    }

    It 'keeps conversion-owned tests free of skipped or inconclusive registrations' {
        foreach ($name in $script:ConversionTestNames) {
            $file = Get-Item -LiteralPath (Join-Path (Join-Path $script:RepositoryRoot 'tests') $name) -Force
            $tokens = $null
            $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
            @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Set-ItResult' }, $true)) | Should -HaveCount 0
            @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandParameterAst] -and $node.ParameterName -ceq 'Skip' }, $true)) | Should -HaveCount 0
        }
    }

    It 'keeps general checks free of Windows-only process dependencies' {
        foreach ($relative in @('scripts/Test-AtlassianRepository.ps1', 'scripts/Test-AtlassianSharedReferences.ps1')) {
            $text = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot $relative)
            $text | Should -Not -Match '(?i)pwsh\.exe|icacls|Microsoft\.Win32'
        }
    }
}
