# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $repositoryRoot = Split-Path -Parent $PSScriptRoot
    $transportModule = Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluenceTransport.psm1'
    $script:currentModule = Import-Module -Name $transportModule -Force -PassThru
    $script:currentCommand = $script:currentModule.Name + '\Test-ConfluenceApiBaseIdentity'
    $script:baselineCommand = 'Test-ConfluenceApiBaseIdentityBaseline671'

    # Frozen helper from ConfluenceTransport.psm1 at commit 671c1d08f2bb8a338b53c47475b2ceb41d4157cd.
    # Its containing module blob is bound by evidence/e1-structure/oracle-binding.json (67d916b520763acfdc198739883291942163cf3f).
    function Test-ConfluenceApiBaseIdentityBaseline671 {
        [CmdletBinding()]
        param(
            [string] $ApiBase,
            [string] $CloudId,
            [Parameter(Mandatory)][ValidateSet('RawTrimmed','AbsoluteUri')][string] $ComparisonMode
        )
        $expectedApiBase = 'https://api.atlassian.com/ex/confluence/' + [string] $CloudId
        if ($ComparisonMode -eq 'RawTrimmed') {
            return $ApiBase.TrimEnd('/') -ceq $expectedApiBase
        }
        $parsedApiBase = $null
        if (-not [Uri]::TryCreate($ApiBase, [UriKind]::Absolute, [ref] $parsedApiBase)) {
            return $false
        }
        return $parsedApiBase.AbsoluteUri.TrimEnd('/') -ceq $expectedApiBase
    }

    function Get-StringFingerprint {
        param([AllowNull()][object] $Value)
        if ($null -eq $Value) { return [pscustomobject]@{ isNull = $true; length = $null; sha256 = $null } }
        $text = [string]$Value
        $bytes = [Text.Encoding]::UTF8.GetBytes($text)
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hex = [Convert]::ToHexString($sha.ComputeHash($bytes)).ToLowerInvariant() }
        finally { $sha.Dispose() }
        [pscustomobject]@{ isNull = $false; length = $text.Length; sha256 = $hex }
    }

    $guid = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    $prefix = 'https://api.atlassian.com/ex/confluence/'
    $script:cases = @(
        [pscustomobject]@{ Label = 'canonical RawTrimmed'; Mode = 'RawTrimmed'; ApiBase = ($prefix + $guid); CloudId = $guid }
        [pscustomobject]@{ Label = 'canonical AbsoluteUri'; Mode = 'AbsoluteUri'; ApiBase = ($prefix + $guid); CloudId = $guid }
        [pscustomobject]@{ Label = 'trailing slash RawTrimmed'; Mode = 'RawTrimmed'; ApiBase = ($prefix + $guid + '///'); CloudId = $guid }
        [pscustomobject]@{ Label = 'trailing slash AbsoluteUri'; Mode = 'AbsoluteUri'; ApiBase = ($prefix + $guid + '///'); CloudId = $guid }
        [pscustomobject]@{ Label = 'uppercase scheme and host RawTrimmed'; Mode = 'RawTrimmed'; ApiBase = ('HTTPS://API.ATLASSIAN.COM/ex/confluence/' + $guid); CloudId = $guid }
        [pscustomobject]@{ Label = 'uppercase scheme and host AbsoluteUri'; Mode = 'AbsoluteUri'; ApiBase = ('HTTPS://API.ATLASSIAN.COM/ex/confluence/' + $guid); CloudId = $guid }
        [pscustomobject]@{ Label = 'default port RawTrimmed'; Mode = 'RawTrimmed'; ApiBase = ('https://api.atlassian.com:443/ex/confluence/' + $guid); CloudId = $guid }
        [pscustomobject]@{ Label = 'default port AbsoluteUri'; Mode = 'AbsoluteUri'; ApiBase = ('https://api.atlassian.com:443/ex/confluence/' + $guid); CloudId = $guid }
        [pscustomobject]@{ Label = 'leading-zero default port RawTrimmed'; Mode = 'RawTrimmed'; ApiBase = ('https://api.atlassian.com:0443/ex/confluence/' + $guid); CloudId = $guid }
        [pscustomobject]@{ Label = 'leading-zero default port AbsoluteUri'; Mode = 'AbsoluteUri'; ApiBase = ('https://api.atlassian.com:0443/ex/confluence/' + $guid); CloudId = $guid }
        [pscustomobject]@{ Label = 'empty userinfo AbsoluteUri'; Mode = 'AbsoluteUri'; ApiBase = ('https://@api.atlassian.com/ex/confluence/' + $guid); CloudId = $guid }
        [pscustomobject]@{ Label = 'userinfo RawTrimmed'; Mode = 'RawTrimmed'; ApiBase = ('https://user@api.atlassian.com/ex/confluence/' + $guid); CloudId = $guid }
        [pscustomobject]@{ Label = 'userinfo AbsoluteUri'; Mode = 'AbsoluteUri'; ApiBase = ('https://user@api.atlassian.com/ex/confluence/' + $guid); CloudId = $guid }
        [pscustomobject]@{ Label = 'query AbsoluteUri'; Mode = 'AbsoluteUri'; ApiBase = ($prefix + $guid + '?tenant=x'); CloudId = $guid }
        [pscustomobject]@{ Label = 'empty query AbsoluteUri'; Mode = 'AbsoluteUri'; ApiBase = ($prefix + $guid + '?'); CloudId = $guid }
        [pscustomobject]@{ Label = 'fragment AbsoluteUri'; Mode = 'AbsoluteUri'; ApiBase = ($prefix + $guid + '#tenant=x'); CloudId = $guid }
        [pscustomobject]@{ Label = 'empty fragment AbsoluteUri'; Mode = 'AbsoluteUri'; ApiBase = ($prefix + $guid + '#'); CloudId = $guid }
        [pscustomobject]@{ Label = 'path case RawTrimmed'; Mode = 'RawTrimmed'; ApiBase = ('https://api.atlassian.com/ex/Confluence/' + $guid); CloudId = $guid }
        [pscustomobject]@{ Label = 'path case AbsoluteUri'; Mode = 'AbsoluteUri'; ApiBase = ('https://api.atlassian.com/ex/Confluence/' + $guid); CloudId = $guid }
        [pscustomobject]@{ Label = 'non-default port RawTrimmed'; Mode = 'RawTrimmed'; ApiBase = ('https://api.atlassian.com:444/ex/confluence/' + $guid); CloudId = $guid }
        [pscustomobject]@{ Label = 'non-default port AbsoluteUri'; Mode = 'AbsoluteUri'; ApiBase = ('https://api.atlassian.com:444/ex/confluence/' + $guid); CloudId = $guid }
        [pscustomobject]@{ Label = 'dot segment RawTrimmed'; Mode = 'RawTrimmed'; ApiBase = ('https://api.atlassian.com/ex/foo/../confluence/' + $guid); CloudId = $guid }
        [pscustomobject]@{ Label = 'dot segment AbsoluteUri'; Mode = 'AbsoluteUri'; ApiBase = ('https://api.atlassian.com/ex/foo/../confluence/' + $guid); CloudId = $guid }
        [pscustomobject]@{ Label = 'backslash RawTrimmed'; Mode = 'RawTrimmed'; ApiBase = ('https://api.atlassian.com/ex/confluence\' + $guid); CloudId = $guid }
        [pscustomobject]@{ Label = 'backslash AbsoluteUri'; Mode = 'AbsoluteUri'; ApiBase = ('https://api.atlassian.com/ex/confluence\' + $guid); CloudId = $guid }
        [pscustomobject]@{ Label = 'backslash authority AbsoluteUri'; Mode = 'AbsoluteUri'; ApiBase = ('https:\\api.atlassian.com\ex\confluence\' + $guid); CloudId = $guid }
        [pscustomobject]@{ Label = 'leading URL whitespace RawTrimmed'; Mode = 'RawTrimmed'; ApiBase = (' ' + $prefix + $guid); CloudId = $guid }
        [pscustomobject]@{ Label = 'leading and trailing URL whitespace AbsoluteUri'; Mode = 'AbsoluteUri'; ApiBase = (' ' + $prefix + $guid + ' '); CloudId = $guid }
        [pscustomobject]@{ Label = 'encoded unreserved character RawTrimmed'; Mode = 'RawTrimmed'; ApiBase = ($prefix + $guid.Replace('aaaaaaaa-', '%61aaaaaaa-')); CloudId = $guid }
        [pscustomobject]@{ Label = 'encoded unreserved character AbsoluteUri'; Mode = 'AbsoluteUri'; ApiBase = ($prefix + $guid.Replace('aaaaaaaa-', '%61aaaaaaa-')); CloudId = $guid }
        [pscustomobject]@{ Label = 'cloud ID with spaces RawTrimmed'; Mode = 'RawTrimmed'; ApiBase = ($prefix + ' a '); CloudId = ' a ' }
        [pscustomobject]@{ Label = 'cloud ID with tab and newline RawTrimmed'; Mode = 'RawTrimmed'; ApiBase = ($prefix + "a`t`nb"); CloudId = "a`t`nb" }
        [pscustomobject]@{ Label = 'cloud ID with malformed percent RawTrimmed'; Mode = 'RawTrimmed'; ApiBase = ($prefix + '%zz'); CloudId = '%zz' }
        [pscustomobject]@{ Label = 'cloud ID with query delimiter RawTrimmed'; Mode = 'RawTrimmed'; ApiBase = ($prefix + 'a?b'); CloudId = 'a?b' }
        [pscustomobject]@{ Label = 'cloud ID with query delimiter AbsoluteUri'; Mode = 'AbsoluteUri'; ApiBase = ($prefix + 'a?b'); CloudId = 'a?b' }
        [pscustomobject]@{ Label = 'cloud ID with fragment delimiter RawTrimmed'; Mode = 'RawTrimmed'; ApiBase = ($prefix + 'a#b'); CloudId = 'a#b' }
        [pscustomobject]@{ Label = 'cloud ID with fragment delimiter AbsoluteUri'; Mode = 'AbsoluteUri'; ApiBase = ($prefix + 'a#b'); CloudId = 'a#b' }
        [pscustomobject]@{ Label = 'query CloudId plus API-base trailing slashes RawTrimmed'; Mode = 'RawTrimmed'; ApiBase = ($prefix + 'a?b///'); CloudId = 'a?b' }
        [pscustomobject]@{ Label = 'query CloudId plus API-base trailing slashes AbsoluteUri'; Mode = 'AbsoluteUri'; ApiBase = ($prefix + 'a?b///'); CloudId = 'a?b' }
        [pscustomobject]@{ Label = 'fragment CloudId plus API-base trailing slashes RawTrimmed'; Mode = 'RawTrimmed'; ApiBase = ($prefix + 'a#b///'); CloudId = 'a#b' }
        [pscustomobject]@{ Label = 'fragment CloudId plus API-base trailing slashes AbsoluteUri'; Mode = 'AbsoluteUri'; ApiBase = ($prefix + 'a#b///'); CloudId = 'a#b' }
        [pscustomobject]@{ Label = 'query CloudId ending slash RawTrimmed'; Mode = 'RawTrimmed'; ApiBase = ($prefix + 'a?b/'); CloudId = 'a?b/' }
        [pscustomobject]@{ Label = 'query CloudId ending slash AbsoluteUri'; Mode = 'AbsoluteUri'; ApiBase = ($prefix + 'a?b/'); CloudId = 'a?b/' }
        [pscustomobject]@{ Label = 'fragment CloudId ending slash RawTrimmed'; Mode = 'RawTrimmed'; ApiBase = ($prefix + 'a#b/'); CloudId = 'a#b/' }
        [pscustomobject]@{ Label = 'fragment CloudId ending slash AbsoluteUri'; Mode = 'AbsoluteUri'; ApiBase = ($prefix + 'a#b/'); CloudId = 'a#b/' }
        [pscustomobject]@{ Label = 'cloud ID with slash RawTrimmed'; Mode = 'RawTrimmed'; ApiBase = ($prefix + 'a/b'); CloudId = 'a/b' }
        [pscustomobject]@{ Label = 'cloud ID with percent escape RawTrimmed'; Mode = 'RawTrimmed'; ApiBase = ($prefix + '%2f'); CloudId = '%2f' }
        [pscustomobject]@{ Label = 'opaque 36-character non-hex RawTrimmed'; Mode = 'RawTrimmed'; ApiBase = ($prefix + 'gggggggg-gggg-gggg-gggg-gggggggggggg'); CloudId = 'gggggggg-gggg-gggg-gggg-gggggggggggg' }
        [pscustomobject]@{ Label = '36-character allowed alphabet non-GUID RawTrimmed'; Mode = 'RawTrimmed'; ApiBase = ($prefix + '-aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa'); CloudId = '-aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa' }
        [pscustomobject]@{ Label = '36-character allowed alphabet non-GUID AbsoluteUri'; Mode = 'AbsoluteUri'; ApiBase = ($prefix + '-aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa'); CloudId = '-aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa' }
        [pscustomobject]@{ Label = 'null API base RawTrimmed'; Mode = 'RawTrimmed'; ApiBase = $null; CloudId = $guid }
        [pscustomobject]@{ Label = 'null API base AbsoluteUri'; Mode = 'AbsoluteUri'; ApiBase = $null; CloudId = $guid }
        [pscustomobject]@{ Label = 'empty cloud ID RawTrimmed'; Mode = 'RawTrimmed'; ApiBase = $prefix; CloudId = '' }
        [pscustomobject]@{ Label = 'empty cloud ID AbsoluteUri'; Mode = 'AbsoluteUri'; ApiBase = $prefix; CloudId = '' }
        [pscustomobject]@{ Label = '70k cloud ID RawTrimmed'; Mode = 'RawTrimmed'; ApiBase = ($prefix + ('x' * 70000)); CloudId = ('x' * 70000) }
    )

    function Get-ApiBaseOutcome {
        param(
            [Parameter(Mandatory)][string] $CommandName,
            [Parameter(Mandatory)] $Case
        )

        try {
            $items = @(& $CommandName -ApiBase $Case.ApiBase -CloudId $Case.CloudId -ComparisonMode $Case.Mode -ErrorAction Stop)
            [pscustomobject]@{
                kind = 'return'
                count = $items.Count
                type = if ($items.Count -eq 1 -and $null -ne $items[0]) { $items[0].GetType().FullName } else { $null }
                value = if ($items.Count -eq 1) { $items[0] } else { $null }
            }
        }
        catch {
            $messageFingerprint = Get-StringFingerprint -Value $_.Exception.Message
            [pscustomobject]@{
                kind = 'throw'
                type = $_.Exception.GetType().FullName
                category = [string]$_.CategoryInfo.Category
                fullyQualifiedErrorId = $_.FullyQualifiedErrorId
                messageLength = $messageFingerprint.length
                messageSha256 = $messageFingerprint.sha256
            }
        }
    }
}

Describe 'SYP-171 API base URI component behavior' {
    # Scenario: SYP171-SCN-002; preserve the frozen API-base identity outcomes while implementation moves from flat-string comparison to URI components.
    # Purpose: Keep both comparison modes, URI normalization edges, opaque helper inputs, and exception behavior tied to the 671c1d08 oracle.
    It 'UnitT10_matches_frozen_671c1d08_outcomes_for_55_bounded_cases' {
        $script:cases.Count | Should -Be 55 -Because 'the full fixed corpus must execute'
        $observationRows = [Collections.Generic.List[object]]::new()
        foreach ($case in $script:cases) {
            $baseline = Get-ApiBaseOutcome -CommandName $script:baselineCommand -Case $case
            $actual = Get-ApiBaseOutcome -CommandName $script:currentCommand -Case $case
            $equal = ($actual | ConvertTo-Json -Compress) -ceq ($baseline | ConvertTo-Json -Compress)
            $observationRows.Add([pscustomobject]@{
                label = $case.Label
                mode = $case.Mode
                apiBase = Get-StringFingerprint -Value $case.ApiBase
                cloudId = Get-StringFingerprint -Value $case.CloudId
                baseline = $baseline
                actual = $actual
                equal = $equal
            })
            $actual | ConvertTo-Json -Compress | Should -BeExactly ($baseline | ConvertTo-Json -Compress) -Because $case.Label
        }

        if (-not [string]::IsNullOrWhiteSpace($env:E1_STRUCTURE_OUTCOME_RECEIPT)) {
            $receipt = [ordered]@{
                schemaVersion = 1
                baselineCommit = '671c1d08f2bb8a338b53c47475b2ceb41d4157cd'
                baselineTree = 'e3af2aef8133b00f6ca301236918d734a50bf373'
                caseCount = $observationRows.Count
                testPath = 'tests/ConfluenceDocs.ApiBaseStructure.Tests.ps1'
                testSha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
                rows = @($observationRows)
            }
            [IO.File]::WriteAllText($env:E1_STRUCTURE_OUTCOME_RECEIPT, ($receipt | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        }
    }
}
