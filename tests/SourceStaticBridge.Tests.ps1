# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Atlassian source safety statements' {
    BeforeAll {
        $script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    }

    It 'preserves the exact Bitbucket REST base rule' {
        $text = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'skills/review-bitbucket-pull-request/references/bitbucket-cloud-api.md')
        $text | Should -Match ([regex]::Escape('REST requires exactly the base composed of scheme `https`, host `api.bitbucket.org`, and base path `/2.0`'))
    }

    It 'preserves shared Error Handling pointers for all API access Skills' {
        $expected = [ordered]@{
            'configure-bitbucket-api-access' = 'For HTTP errors, use the **Safe HTTP classification** section in [references/shared-workflow.md](references/shared-workflow.md) as the sole handling location.'
            'configure-confluence-api-access' = 'For HTTP errors, use the **Safe HTTP classification** section in [references/shared-workflow.md](references/shared-workflow.md) as the sole handling location.'
            'configure-jira-api-access' = 'For HTTP errors, use Workflow step 8 and the **Safe HTTP classification** section in [references/shared-workflow.md](references/shared-workflow.md) as the sole classification location.'
        }
        foreach ($entry in $expected.GetEnumerator()) {
            $text = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot ('skills/' + $entry.Key + '/SKILL.md'))
            $text | Should -Match ([regex]::Escape([string]$entry.Value))
        }
    }

    It 'keeps API access validation as an offline repository regression' {
        $text = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'tests/validate-api-access.ps1')
        $text | Should -Match 'api\.bitbucket\.org/2\.0'
        $text | Should -Match 'api\.atlassian\.com/ex/confluence/'
        $text | Should -Match 'api\.atlassian\.com/ex/jira/'
    }
}
