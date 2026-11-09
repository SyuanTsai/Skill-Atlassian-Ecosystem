# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'SkillSpector human-approved exceptions' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:RegistryPath = Join-Path $script:RepositoryRoot 'config/skillspector-exceptions.json'
        $script:BaselineRoot = Join-Path $script:RepositoryRoot 'config/skillspector-exceptions'
        $script:Registry = Get-Content -LiteralPath $script:RegistryPath -Raw -Encoding utf8 | ConvertFrom-Json
        $script:Catalog = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/source.json') -Raw -Encoding utf8 | ConvertFrom-Json

        function Get-PropertyNames {
            param([object] $Value)
            return @($Value.PSObject.Properties.Name)
        }

        function Assert-SetEqual {
            param([object[]] $Expected, [object[]] $Actual, [string] $Because)
            $difference = @(Compare-Object -ReferenceObject @($Expected | Sort-Object) -DifferenceObject @($Actual | Sort-Object))
            $difference.Count | Should -Be 0 -Because $Because
        }
    }

    It 'validates the registry contract and review boundary' {
        $script:Registry.schemaVersion | Should -Be 1
        $script:Registry.contract | Should -Be 'skillspector-human-approved-exceptions-v1'
        $script:Registry.scanner.version | Should -Be '2.13.4'
        $script:Registry.scanner.fingerprintSchema | Should -Be 'skillspector-finding-fingerprint-v2'
        $script:Registry.approval.approver | Should -Be 'SyuanTsai'
        $script:Registry.approval.approvedOn | Should -Be '2026-11-09'
        $script:Registry.approval.tracking | Should -Be 'SYP-416'
        $script:Registry.approval.decision | Should -Be 'accepted-limited-risk'
        [string]::IsNullOrWhiteSpace([string]$script:Registry.approval.scope) | Should -BeFalse
        [string]::IsNullOrWhiteSpace([string]$script:Registry.gateEffect) | Should -BeFalse

        $approvedOn = [DateTime]::ParseExact($script:Registry.approval.approvedOn, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        $expiresOn = [DateTime]::ParseExact($script:Registry.review.expiresOn, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        $expiresOn | Should -BeGreaterThan $approvedOn
        @($script:Registry.review.reviewTriggers).Count | Should -BeGreaterThan 0
    }

    It 'binds every declared baseline one-to-one to an active catalog Skill' {
        $declaredPaths = @($script:Registry.baselines | ForEach-Object { [string]$_.path })
        $actualPaths = @(Get-ChildItem -LiteralPath $script:BaselineRoot -Filter '*.baseline.json' -File |
            ForEach-Object { 'config/skillspector-exceptions/' + $_.Name })
        Assert-SetEqual $declaredPaths $actualPaths 'declared and present baseline files must match exactly'

        @($script:Registry.baselines.skillId).Count | Should -Be @($script:Registry.baselines.skillId | Select-Object -Unique).Count
        foreach ($entry in $script:Registry.baselines) {
            $script:Catalog.skills | Should -Contain $entry.skillId
            $entry.path | Should -Be "config/skillspector-exceptions/$($entry.skillId).baseline.json"
        }
    }

    It 'maps 19 exact fingerprints bidirectionally without wildcard rules' {
        $baselineRecords = [Collections.Generic.List[object]]::new()
        foreach ($entry in $script:Registry.baselines) {
            $baseline = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot $entry.path) -Raw -Encoding utf8 | ConvertFrom-Json
            $baseline.version | Should -Be 2
            $baseline.scanner_version | Should -Be $script:Registry.scanner.version
            @($baseline.rules).Count | Should -Be 0

            foreach ($fingerprint in $baseline.fingerprints) {
                $fingerprint.hash | Should -Match '^sha256:[0-9a-f]{64}$'
                $fingerprint.rule_id | Should -BeIn @('E1', 'LP3')
                $fingerprint.reason | Should -Match '^SYP-416 human-approved'
                $matchingException = @($script:Registry.exceptions | Where-Object fingerprint -CEQ $fingerprint.hash)
                $matchingException.Count | Should -Be 1
                $fingerprint.reason | Should -Match ([regex]::Escape($matchingException[0].exceptionId))
                $baselineRecords.Add([pscustomobject]@{
                    fingerprint = [string]$fingerprint.hash
                    skillId = [string]$entry.skillId
                    ruleId = [string]$fingerprint.rule_id
                    file = [string]$fingerprint.file
                })
            }
        }

        $baselineRecords.Count | Should -Be 19
        @($baselineRecords.fingerprint | Select-Object -Unique).Count | Should -Be 19
        @($script:Registry.exceptions).Count | Should -Be 19
        @($script:Registry.exceptions.fingerprint | Select-Object -Unique).Count | Should -Be 19
        Assert-SetEqual @($baselineRecords.fingerprint) @($script:Registry.exceptions.fingerprint) 'registry and baseline fingerprints must match both ways'
        @($script:Registry.exceptions | Where-Object ruleId -CEQ 'E1').Count | Should -Be 18
        @($script:Registry.exceptions | Where-Object ruleId -CEQ 'LP3').Count | Should -Be 1

        foreach ($record in $baselineRecords) {
            $exception = @($script:Registry.exceptions | Where-Object fingerprint -CEQ $record.fingerprint)[0]
            $exception.skillId | Should -BeExactly $record.skillId
            $exception.ruleId | Should -BeExactly $record.ruleId
            $exception.file | Should -BeExactly $record.file
        }
    }

    It 'validates required approval evidence and exact source locations' {
        $requiredFields = @(
            'exceptionId', 'skillId', 'ruleId', 'severity', 'file', 'startLine', 'startColumn',
            'matchedText', 'fingerprint', 'capability', 'necessity', 'dataFlow', 'credentials',
            'redirectControl', 'riskAssessment', 'compensatingControls', 'owner', 'approvedOn'
        )
        $requiredStrings = @(
            'exceptionId', 'skillId', 'ruleId', 'severity', 'file', 'fingerprint', 'capability',
            'necessity', 'dataFlow', 'credentials', 'redirectControl', 'riskAssessment',
            'compensatingControls', 'owner', 'approvedOn'
        )

        @($script:Registry.exceptions.exceptionId | Select-Object -Unique).Count | Should -Be 19
        $actualOrder = @($script:Registry.exceptions | ForEach-Object {
            '{0}{1}{2}{1}{3:D10}' -f $_.skillId, [char]0, $_.file, [int]$_.startLine
        })
        $expectedOrder = [string[]]@($actualOrder)
        [Array]::Sort($expectedOrder, [StringComparer]::Ordinal)
        for ($index = 0; $index -lt $actualOrder.Count; $index++) {
            $actualOrder[$index] | Should -BeExactly $expectedOrder[$index]
        }
        foreach ($exception in $script:Registry.exceptions) {
            $propertyNames = Get-PropertyNames $exception
            foreach ($field in $requiredFields) { $propertyNames | Should -Contain $field }
            foreach ($field in $requiredStrings) {
                [string]::IsNullOrWhiteSpace([string]$exception.$field) | Should -BeFalse
            }
            $exception.severity | Should -BeExactly 'MEDIUM'
            $exception.owner | Should -BeExactly $script:Registry.approval.approver
            $exception.approvedOn | Should -BeExactly $script:Registry.approval.approvedOn
            ($exception.startLine -is [int] -or $exception.startLine -is [long]) | Should -BeTrue
            $exception.startLine | Should -BeGreaterThan 0

            if ($exception.ruleId -CEQ 'E1') {
                ($exception.startColumn -is [int] -or $exception.startColumn -is [long]) | Should -BeTrue
                $exception.startColumn | Should -BeGreaterOrEqual 0
                $exception.matchedText | Should -BeIn @('https://api.atlassian.com/', 'https://api.bitbucket.org/')
                $sourcePath = Join-Path $script:RepositoryRoot ("skills/{0}/{1}" -f $exception.skillId, $exception.file)
                Test-Path -LiteralPath $sourcePath -PathType Leaf | Should -BeTrue
                $lines = [IO.File]::ReadAllLines($sourcePath, [Text.Encoding]::UTF8)
                $exception.startLine | Should -BeLessOrEqual $lines.Count
                $line = $lines[$exception.startLine - 1]
                $exception.startColumn | Should -BeLessThan $line.Length
                $line.Substring($exception.startColumn).StartsWith($exception.matchedText, [StringComparison]::Ordinal) | Should -BeTrue
            }
            else {
                $exception.ruleId | Should -BeExactly 'LP3'
                $exception.skillId | Should -BeExactly 'review-bitbucket-pull-request'
                $exception.file | Should -BeExactly 'SKILL.md'
                $exception.startLine | Should -Be 1
                $null -eq $exception.startColumn | Should -BeTrue
                $null -eq $exception.matchedText | Should -BeTrue
                $skillPath = Join-Path $script:RepositoryRoot 'skills/review-bitbucket-pull-request/SKILL.md'
                $skillLines = [IO.File]::ReadAllLines($skillPath, [Text.Encoding]::UTF8)
                $skillLines[0] | Should -BeExactly '---'
                $frontmatterEnd = [Array]::IndexOf($skillLines, '---', 1)
                $frontmatterEnd | Should -BeGreaterThan 1
                ($skillLines[1..($frontmatterEnd - 1)] -join "`n") | Should -Not -Match '(?m)^allowed-tools\s*:'
            }
        }
    }
}
