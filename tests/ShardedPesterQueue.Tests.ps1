# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Complete-suite discovery contract' {
    BeforeAll {
        $script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $script:TestFiles = @(Get-ChildItem -LiteralPath (Join-Path $script:RepositoryRoot 'tests') -Recurse -File -Filter '*.Tests.ps1' -Force)
    }

    It 'uses unique literal It names within every test file' {
        foreach ($file in $script:TestFiles) {
            $tokens = $null
            $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
            $names = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'It' }, $true) | ForEach-Object {
                    if ($_.CommandElements.Count -lt 2 -or $_.CommandElements[1] -isnot [Management.Automation.Language.StringConstantExpressionAst]) { throw "Non-literal It name in $($file.Name)." }
                    [string]$_.CommandElements[1].Value
                })
            @($names | Select-Object -Unique) | Should -HaveCount $names.Count
        }
    }

    It 'binds every validate helper to an executing Pester call point' {
        $testRoot = Join-Path $script:RepositoryRoot 'tests'
        $validationPath = Get-ChildItem -LiteralPath $testRoot -File -Filter 'RepositoryValidation.Tests.ps1' -Force | Select-Object -First 1
        $validationTest = Get-Content -Raw -LiteralPath $validationPath.FullName
        foreach ($name in @('validate-api-access.ps1', 'validate-repository.ps1', 'validate-repository-standalone.ps1', 'validate-windows-powershell.ps1')) {
            $validationTest | Should -Match ([regex]::Escape($name))
        }
        $validationTest | Should -Match 'ExitCode\s*\|\s*Should\s+-Be\s+0'
    }
}
