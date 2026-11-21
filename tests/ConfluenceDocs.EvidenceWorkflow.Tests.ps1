# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $repositoryRoot = Split-Path -Parent $PSScriptRoot
    $skillRoot = Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code'
    $skillPath = Join-Path $skillRoot 'SKILL.md'
    $workflowPath = Join-Path $skillRoot 'references/code-evidence-workflow.md'
    $examplePath = Join-Path $skillRoot 'references/examples/code-evidence-case.md'
    $ordinal = [StringComparison]::Ordinal

    function Read-Utf8Text {
        param([Parameter(Mandatory)][string] $Path)
        return [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false, $true))
    }
}

Describe 'SYP-393 code-evidence documentation workflow contract' {
    It 'ContractT10_links_the_skill_to_an_executable_five_stage_workflow' {
        Test-Path -LiteralPath $workflowPath -PathType Leaf | Should -BeTrue
        $skill = Read-Utf8Text -Path $skillPath
        $workflow = Read-Utf8Text -Path $workflowPath

        $skill.Contains('references/code-evidence-workflow.md', $ordinal) | Should -BeTrue
        foreach ($heading in @(
            '## 1. Fix scope and versions',
            '## 2. Gather evidence',
            '## 3. Reconcile the evidence table',
            '## 4. Write and verify locally',
            '## 5. Sync and read back'
        )) {
            $workflow.Contains($heading, $ordinal) | Should -BeTrue
        }
        $workflow.Contains('## Lean and full workflows', $ordinal) | Should -BeTrue
        $workflow.Contains('## Project-specific inputs', $ordinal) | Should -BeTrue
        $workflow.Contains('## Delegating', $ordinal) | Should -BeTrue
    }

    It 'ContractT20_provides_a_version_bound_multi_path_evidence_case' {
        Test-Path -LiteralPath $examplePath -PathType Leaf | Should -BeTrue
        $example = Read-Utf8Text -Path $examplePath

        foreach ($status in @('confirmed in code', 'confirmed not mapped', 'unconfirmed')) {
            $example.Contains($status, $ordinal) | Should -BeTrue
        }
        $example | Should -Match '(?i)\bcreate\b'
        $example | Should -Match '(?i)\bupdate\b'

        $tableMatch = [regex]::Match(
            $example,
            '(?ms)^<!-- evidence-table:start -->\r?\n(?<table>.*?)^<!-- evidence-table:end -->'
        )
        $tableMatch.Success | Should -BeTrue
        $rows = @($tableMatch.Groups['table'].Value -split '\r?\n' | Where-Object {
            $_ -match '^\|' -and $_ -notmatch '^\|\s*-'
        } | Select-Object -Skip 1)
        $rows.Count | Should -BeGreaterOrEqual 6

        $expectedCommit = (git -C $repositoryRoot rev-parse e85f886).Trim()
        $LASTEXITCODE | Should -Be 0
        $expectedCommit | Should -Match '^[a-f0-9]{40}$'

        foreach ($row in $rows) {
            $cells = @($row.Trim('|').Split('|') | ForEach-Object { $_.Trim() })
            $cells.Count | Should -Be 7
            $commit = $cells[4]
            $path = $cells[5].Replace('`', '')
            $symbol = $cells[6].Replace('`', '')
            $commit | Should -BeExactly $expectedCommit
            $path | Should -Match '^skills/manage-confluence-docs-as-code/scripts/[^/]+\.psm1$'
            $symbol | Should -Match '^[A-Za-z][A-Za-z0-9-]+$'

            $source = @(git -C $repositoryRoot show "${commit}:$path")
            $LASTEXITCODE | Should -Be 0
            ($source -join "`n") | Should -Match ('(?m)^function\s+' + [regex]::Escape($symbol) + '(?:\s|\{)')
        }
    }

    It 'ContractT30_states_that_usage_data_is_unavailable_without_savings_claims' {
        $example = Read-Utf8Text -Path $examplePath
        $usageMatch = [regex]::Match($example, '(?ms)^## Usage\s*$\r?\n(?<usage>.*?)(?=^##\s|\z)')
        $usageMatch.Success | Should -BeTrue
        $usage = $usageMatch.Groups['usage'].Value

        $usage.Contains('actual usage/credits data are unavailable', $ordinal) | Should -BeTrue
        $usage | Should -Not -Match '%'
        $usage | Should -Not -Match '(?i)(?:saved|savings)\D{0,20}\d|\d\D{0,20}(?:saved|savings)'
    }
}
