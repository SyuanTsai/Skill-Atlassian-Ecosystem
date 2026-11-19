# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Consumer workflow cleanup compatibility' {
    BeforeAll {
        $script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        function Assert-ConsumerWorkflowSet {
            param([Parameter(Mandatory)][string] $Root)
            $workflowRoot = Join-Path $Root '.github/workflows'
            [string[]]$names = @(Get-ChildItem -LiteralPath $workflowRoot -File -Force | ForEach-Object Name)
            [Array]::Sort($names, [StringComparer]::Ordinal)
            $permanent = @('consumer-gate.yml')
            $transition = @('consumer-gate-transition.yml', 'consumer-gate.yml')
            if (($names -join "`n") -cne ($permanent -join "`n") -and ($names -join "`n") -cne ($transition -join "`n")) {
                throw 'Workflow directory contains an unsupported file set.'
            }
        }
    }

    It 'accepts the conversion workflow set' {
        { Assert-ConsumerWorkflowSet -Root $script:RepositoryRoot } | Should -Not -Throw
    }

    It 'accepts cleanup with only the permanent workflow' {
        $root = Join-Path $TestDrive 'cleanup'
        $directory = Join-Path $root '.github/workflows'
        [void](New-Item -ItemType Directory -Path $directory -Force)
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/consumer-gate.yml') -Destination $directory
        { Assert-ConsumerWorkflowSet -Root $root } | Should -Not -Throw
    }

    It 'rejects a third workflow' {
        $root = Join-Path $TestDrive 'extra'
        $directory = Join-Path $root '.github/workflows'
        [void](New-Item -ItemType Directory -Path $directory -Force)
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/consumer-gate.yml') -Destination $directory
        [IO.File]::WriteAllText((Join-Path $directory 'unexpected.yml'), 'name: unexpected', [Text.UTF8Encoding]::new($false))
        { Assert-ConsumerWorkflowSet -Root $root } | Should -Throw
    }
}
