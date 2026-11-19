# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Atlassian consumer repository contract' {
    BeforeAll {
        $script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $script:Catalog = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/source.json') | ConvertFrom-Json
        $script:Gate = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'config/consumer-gate.json') | ConvertFrom-Json
        $script:Pin = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'config/authority-pin.json') | ConvertFrom-Json
    }

    It 'publishes both snapshot-safe general check interfaces' {
        foreach ($relative in @('scripts/Test-AtlassianRepository.ps1', 'scripts/Test-AtlassianSharedReferences.ps1')) {
            $command = Get-Command -Name (Join-Path $script:RepositoryRoot $relative) -CommandType ExternalScript
            @($command.Parameters.Keys) | Should -Contain 'RepositoryRoot'
            @($command.Parameters.Keys) | Should -Contain 'ReadOnlySnapshot'
            $command.Parameters['ReadOnlySnapshot'].ParameterType | Should -Be ([switch])
        }
    }

    It 'binds active Skills exactly to the source catalog' {
        (@($script:Gate.activeSkills) -join "`n") | Should -BeExactly (@($script:Catalog.skills) -join "`n")
    }

    It 'declares exactly two general checks and the complete tests tree' {
        @($script:Gate.repositoryChecks) | Should -HaveCount 3
        (@($script:Gate.repositoryChecks.id) -join "`n") | Should -BeExactly (@('repository-atlassian', 'repository-shared-references', 'repository-pester') -join "`n")
        (@($script:Gate.repositoryChecks.kind) -join "`n") | Should -BeExactly (@('general', 'general', 'pester') -join "`n")
        (@($script:Gate.repositoryChecks.path) -join "`n") | Should -BeExactly (@('scripts/Test-AtlassianRepository.ps1', 'scripts/Test-AtlassianSharedReferences.ps1', 'tests') -join "`n")
    }

    It 'uses a replaceable immutable authority pin' {
        (@($script:Pin.PSObject.Properties.Name) -join "`n") | Should -BeExactly (@('schemaVersion', 'repository', 'commit') -join "`n")
        $script:Pin.schemaVersion | Should -Be 1
        $script:Pin.repository | Should -BeExactly 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'
        $script:Pin.commit | Should -Match '^[0-9a-f]{40}$'
    }

    It 'preserves the Atlassian access-path and credential boundaries' {
        $jiraSkill = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'skills/work-with-jira/SKILL.md') -Raw
        $jiraSkill | Should -Match 'After resolving the target site, use only the access path required by the resolved environment'
        $jiraSkill | Should -Match 'Never print, log, persist'
        $jiraSkill | Should -Match 'JIRA_API_BASE_URL'
    }

    It 'keeps Jira Web route decisions and projection boundaries source-owned' {
        $skillRoot = Join-Path $script:RepositoryRoot 'skills/work-with-jira'
        $contract = Get-Content -LiteralPath (Join-Path $skillRoot 'references/web-capability-contract.json') -Raw |
            ConvertFrom-Json -Depth 20
        $fixture = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'tests/fixtures/work-with-jira-web-capabilities.json') -Raw |
            ConvertFrom-Json -Depth 20
        $skill = Get-Content -LiteralPath (Join-Path $skillRoot 'SKILL.md') -Raw

        $contract.schemaVersion | Should -Be 1
        $contract.skillId | Should -Be 'work-with-jira'
        $fixture.skillId | Should -Be $contract.skillId
        $contract.projection.sourceOwned | Should -BeTrue
        $contract.projection.secretsInProjection | Should -BeFalse
        $contract.sourceFixture | Should -Be 'tests/fixtures/work-with-jira-web-capabilities.json'
        $contract.paths.connector.localEnvironmentRequired | Should -BeFalse
        $contract.paths.rest.localEnvironmentRequired | Should -BeTrue
        $contract.routing.defaultDecision | Should -Be 'block'
        $contract.routing.selectedPathRequired | Should -BeTrue
        $contract.routing.fallbackAllowed | Should -BeFalse
        $skill | Should -Match 'references/web-capability-contract.json'
        @($fixture.cases).Count | Should -BeGreaterThan 10

        foreach ($case in @($fixture.cases)) {
            $decision = [string]$contract.routing.defaultDecision
            $selected = [string]$case.selectedPath
            if (-not [string]::IsNullOrWhiteSpace($selected) -and
                @($contract.paths.PSObject.Properties.Name) -ccontains $selected) {
                $required = if ($case.intent -ceq 'read') {
                    @($contract.routing.readRequirements)
                }
                elseif ($case.intent -cin @('write', 'create')) {
                    @($contract.routing.writeRequirements)
                }
                else { throw "Unexpected Jira fixture intent: $($case.intent)" }
                if ($case.intent -ceq 'create' -and $selected -ceq 'connector') {
                    $required += @($contract.routing.connectorCreateRequirements)
                }
                $missing = @($required | Where-Object {
                        $property = $case.PSObject.Properties[[string]$_]
                        $null -eq $property -or $property.Value -ne $true
                    })
                if ($missing.Count -eq 0) { $decision = $selected }
            }
            if ($decision -cne [string]$case.expected) {
                throw "Jira Web fixture '$($case.name)' resolved '$decision', expected '$($case.expected)'."
            }
        }
    }

    It 'rejects reparse points before binding installed Atlassian helpers' {
        foreach ($skillId in @('configure-jira-api-access', 'configure-bitbucket-api-access', 'configure-confluence-api-access')) {
            $skill = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot "skills/$skillId/SKILL.md") -Raw
            $skill | Should -Match 'scripts/Configure-'
            $skill | Should -Match 'scripts/Test-'
            $skill | Should -Match 'references/host-resolved-fast-path\.md'
            $referencePath = Join-Path $script:RepositoryRoot "skills/$skillId/references/host-resolved-fast-path.md"
            Test-Path -LiteralPath $referencePath -PathType Leaf | Should -BeTrue
            $reference = Get-Content -LiteralPath $referencePath -Raw
            $reference | Should -Match 'Assert-NoReparseAncestors'
            $reference | Should -Match 'scripts/Configure-'
            $reference | Should -Match 'scripts/Test-'
        }
    }
}
