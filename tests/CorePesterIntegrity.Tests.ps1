# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Complete Pester tree integrity' {
    BeforeAll {
        $script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $script:TestFiles = @(Get-ChildItem -LiteralPath (Join-Path $script:RepositoryRoot 'tests') -Recurse -File -Filter '*.Tests.ps1' -Force | Sort-Object FullName)
        function Get-DisallowedPesterControl {
            param([Parameter(Mandatory)][string]$LiteralPath)

            $tokens = $null
            $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile($LiteralPath, [ref]$tokens, [ref]$errors)
            if (@($errors).Count -gt 0) {
                throw "Cannot inspect unparseable PowerShell file: $LiteralPath"
            }

            @($ast.FindAll({
                param($node)
                if ($node -isnot [Management.Automation.Language.CommandAst]) {
                    return $false
                }

                $commandName = $node.GetCommandName()
                if ($commandName -ceq 'Set-ItResult') {
                    return $true
                }
                if ($commandName -cnotin @('Describe', 'Context', 'It')) {
                    return $false
                }

                return @($node.CommandElements | Where-Object {
                    $_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -ceq 'Skip'
                }).Count -gt 0
            }, $true))
        }
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

    It 'keeps the complete test tree free of skipped or inconclusive registrations' {
        foreach ($file in $script:TestFiles) {
            @(Get-DisallowedPesterControl -LiteralPath $file.FullName) | Should -HaveCount 0
        }
    }

    It 'distinguishes Pester skip registration from unrelated command parameters' {
        $pesterFixture = Join-Path $TestDrive 'pester-skip.ps1'
        $unrelatedFixture = Join-Path $TestDrive 'select-object-skip.ps1'
        Set-Content -LiteralPath $pesterFixture -Value @("Describe 'x' -Skip {}", "Context 'x' -Skip {}", "It 'x' -Skip {}")
        Set-Content -LiteralPath $unrelatedFixture -Value '1, 2 | Select-Object -Skip 1' -NoNewline

        @(Get-DisallowedPesterControl -LiteralPath $pesterFixture) | Should -HaveCount 3
        @(Get-DisallowedPesterControl -LiteralPath $unrelatedFixture) | Should -HaveCount 0
    }

    It 'keeps general checks free of Windows-only process dependencies' {
        foreach ($relative in @('scripts/Test-AtlassianRepository.ps1', 'scripts/Test-AtlassianSharedReferences.ps1')) {
            $text = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot $relative)
            $text | Should -Not -Match '(?i)pwsh\.exe|icacls|Microsoft\.Win32'
        }
    }
}
