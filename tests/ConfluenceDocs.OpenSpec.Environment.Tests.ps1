# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $script:repositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:sourceReaderPath = Join-Path $script:repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/source-reader.mjs'
    $script:modulePath = Join-Path $script:repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/OpenSpecSource.psm1'
    $configuredRuntimeRoot = [Environment]::GetEnvironmentVariable('SYP171_RUNTIME_ROOT', 'Process')
    if ([string]::IsNullOrWhiteSpace($configuredRuntimeRoot)) {
        $configuredRuntimeRoot = Join-Path $script:repositoryRoot 'skills/manage-confluence-docs-as-code/scripts'
    }
    $script:pinnedNodePath = Join-Path $configuredRuntimeRoot 'node/node.exe'
    if (-not (Test-Path -LiteralPath $script:pinnedNodePath -PathType Leaf)) {
        throw 'The pinned Node runtime is required for the native environment contract tests.'
    }

    function New-OpenSpecEnvironmentFixture {
        param([Parameter(Mandatory)][string] $FixtureRoot)

        $sourceRoot = Join-Path $FixtureRoot 'source'
        $runtimeRoot = Join-Path $FixtureRoot 'runtime'
        $changeRoot = Join-Path $sourceRoot 'openspec/changes/manage-confluence-docs-as-code'
        $specRoot = Join-Path $changeRoot 'specs/confluence-docs'
        $packageRoot = Join-Path $runtimeRoot 'node_modules/@fission-ai/openspec'
        $markdownRoot = Join-Path $runtimeRoot 'node_modules/markdown-it'

        foreach ($directory in @($specRoot, (Join-Path $packageRoot 'bin'), $markdownRoot)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        [IO.File]::WriteAllText((Join-Path $runtimeRoot 'package.json'), '{"name":"syp171-lp3-runtime-fixture","version":"1.0.0"}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $sourceRoot 'openspec/config.yaml'), "schema: spec-driven`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $changeRoot '.openspec.yaml'), "schema: spec-driven`n", [Text.UTF8Encoding]::new($false))
        foreach ($name in @('proposal.md', 'design.md', 'tasks.md')) {
            [IO.File]::WriteAllText((Join-Path $changeRoot $name), "# $name`n", [Text.UTF8Encoding]::new($false))
        }
        [IO.File]::WriteAllText((Join-Path $specRoot 'spec.md'), "# Fixture specification`n", [Text.UTF8Encoding]::new($false))

        [IO.File]::WriteAllText((Join-Path $packageRoot 'package.json'), '{"name":"@fission-ai/openspec","version":"1.13.0"}', [Text.UTF8Encoding]::new($false))
        $nativeCli = @'
const fs = require('node:fs');
const path = require('node:path');
fs.writeFileSync(path.join(__dirname, 'native-environment.json'), JSON.stringify(process.env), 'utf8');
process.stdout.write(JSON.stringify({ items: [{ id: 'manage-confluence-docs-as-code', type: 'change', valid: true, issues: [] }] }));
'@
        [IO.File]::WriteAllText((Join-Path $packageRoot 'bin/openspec.js'), $nativeCli, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $markdownRoot 'package.json'), '{"name":"markdown-it","version":"14.3.1","main":"index.js"}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $markdownRoot 'index.js'), 'module.exports = class MarkdownIt { parse() { return []; } };', [Text.UTF8Encoding]::new($false))

        return [pscustomobject]@{
            sourceRoot = $sourceRoot
            runtimeRoot = $runtimeRoot
            nativeCapturePath = Join-Path (Join-Path $packageRoot 'bin') 'native-environment.json'
        }
    }

    function New-ValidNativeEnvironmentContract {
        $variables = [ordered]@{}
        foreach ($name in @('PATH', 'SystemRoot', 'TEMP', 'TMP')) {
            $value = [Environment]::GetEnvironmentVariable($name, 'Process')
            if (-not [string]::IsNullOrWhiteSpace($value)) { $variables[$name] = $value }
        }
        if (-not $variables.Contains('PATH')) {
            $pathValue = [Environment]::GetEnvironmentVariable('Path', 'Process')
            if (-not [string]::IsNullOrWhiteSpace($pathValue)) { $variables['PATH'] = $pathValue }
        }
        $variables['CI'] = '1'
        $variables['OPENSPEC_TELEMETRY'] = '0'
        $variables['OPENSPEC_NO_UPDATE_CHECK'] = '1'
        return [ordered]@{
            contract = 'syp171-openspec-native-environment-v1'
            version = 1
            variables = $variables
        }
    }

    function New-HostileReaderEnvironment {
        $environment = [ordered]@{}
        foreach ($name in @('PATH', 'SystemRoot', 'TEMP', 'TMP')) {
            $value = [Environment]::GetEnvironmentVariable($name, 'Process')
            if (-not [string]::IsNullOrWhiteSpace($value)) { $environment[$name] = $value }
        }
        if (-not $environment.Contains('PATH')) {
            $pathValue = [Environment]::GetEnvironmentVariable('Path', 'Process')
            if (-not [string]::IsNullOrWhiteSpace($pathValue)) { $environment['PATH'] = $pathValue }
        }
        $environment['CI'] = '0'
        $environment['OPENSPEC_TELEMETRY'] = '1'
        $environment['OPENSPEC_NO_UPDATE_CHECK'] = '0'
        $environment['SYP171_LP3_SENTINEL_SECRET'] = 'synthetic-sentinel-only'
        $environment['NPM_CONFIG_USERCONFIG'] = 'synthetic-user-config-path'
        return $environment
    }

    function Invoke-DirectSourceReader {
        param(
            [Parameter(Mandatory)][string] $SourceRoot,
            [Parameter(Mandatory)][string] $RuntimeRoot,
            [Parameter(Mandatory)][System.Collections.IDictionary] $Request,
            [Parameter(Mandatory)][System.Collections.IDictionary] $ProcessEnvironment
        )

        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = $script:pinnedNodePath
        $start.ArgumentList.Add($script:sourceReaderPath)
        $start.ArgumentList.Add($RuntimeRoot)
        $start.WorkingDirectory = $SourceRoot
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardInput = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.StandardInputEncoding = [Text.UTF8Encoding]::new($false, $true)
        $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false, $true)
        $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false, $true)
        $start.Environment.Clear()
        foreach ($entry in $ProcessEnvironment.GetEnumerator()) {
            $start.Environment[[string]$entry.Key] = [string]$entry.Value
        }

        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $start
        try {
            if (-not $process.Start()) { throw 'The direct source reader did not start.' }
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
            $requestJson = $Request | ConvertTo-Json -Depth 8 -Compress
            $process.StandardInput.Write($requestJson)
            $process.StandardInput.Close()
            if (-not $process.WaitForExit(30000)) { $process.Kill($true); throw 'The direct source reader timed out.' }
            $stdout = $stdoutTask.GetAwaiter().GetResult()
            $stderr = $stderrTask.GetAwaiter().GetResult()
            if ($process.ExitCode -ne 0 -or $stdout.Length -gt 4MB) { throw "The direct source reader returned invalid output: $stderr" }
            return $stdout | ConvertFrom-Json -Depth 30 -ErrorAction Stop
        }
        finally { $process.Dispose() }
    }

    function Get-CapturedNativeEnvironment {
        param([Parameter(Mandatory)][string] $Path)
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'The synthetic native validator was not launched.' }
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    }
}

Describe 'SYP-171 native OpenSpec environment contract' {
    BeforeEach {
        $script:fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "syp171-lp3-env-$([Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:fixtureRoot | Out-Null
        $script:fixture = New-OpenSpecEnvironmentFixture -FixtureRoot $script:fixtureRoot
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:fixtureRoot) {
            $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $script:fixtureRoot).Path)
            $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
            if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\', '/') -cne $tempParent -or
                [IO.Path]::GetFileName($resolved) -cnotmatch '^syp171-lp3-env-[a-f0-9]{32}$') {
                throw 'The LP3 environment fixture escaped its expected temporary root.'
            }
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }

    # Scenario: a supported direct reader invocation omits the new native environment contract.
    # Purpose: the official validator must not run from an uncontracted invocation that could inherit caller secrets.
    It 'InterT10_rejects_direct_reader_request_without_environment_contract' {
        $request = [ordered]@{
            operation = 'validateOpenSpec'
            root = [IO.Path]::GetFullPath($script:fixture.sourceRoot)
            changeId = 'manage-confluence-docs-as-code'
        }
        $result = Invoke-DirectSourceReader -SourceRoot $script:fixture.sourceRoot -RuntimeRoot $script:fixture.runtimeRoot -Request $request -ProcessEnvironment (New-HostileReaderEnvironment)
        $result.status | Should -Be 'invalid'
        @($result.reasonCodes) | Should -Contain 'InvalidEnvironmentContract'
        (Test-Path -LiteralPath $script:fixture.nativeCapturePath) | Should -Be $false
    }

    # Scenario: a direct reader invocation includes a valid contract plus hostile process-only secrets and flags.
    # Purpose: only the explicit contract may reach the synthetic native validator.
    It 'InterT30_uses_validated_contract_instead_of_reader_process_environment' {
        $contract = New-ValidNativeEnvironmentContract
        $request = [ordered]@{
            operation = 'validateOpenSpec'
            root = [IO.Path]::GetFullPath($script:fixture.sourceRoot)
            changeId = 'manage-confluence-docs-as-code'
            environmentContract = $contract
        }
        $result = Invoke-DirectSourceReader -SourceRoot $script:fixture.sourceRoot -RuntimeRoot $script:fixture.runtimeRoot -Request $request -ProcessEnvironment (New-HostileReaderEnvironment)
        $result.status | Should -Be 'valid'
        $result.nativeValidation.valid | Should -Be $true
        $nativeEnvironment = Get-CapturedNativeEnvironment -Path $script:fixture.nativeCapturePath
        $nativeEnvironment['SYP171_LP3_SENTINEL_SECRET'] | Should -BeNullOrEmpty
        $nativeEnvironment['NPM_CONFIG_USERCONFIG'] | Should -BeNullOrEmpty
        $nativeEnvironment['PATH'] | Should -Be $contract.variables.PATH
        if ($contract.variables.Contains('SystemRoot')) {
            $nativeEnvironment['SystemRoot'] | Should -Be $contract.variables.SystemRoot
        }
        $nativeEnvironment['TEMP'] | Should -Be $contract.variables.TEMP
        $nativeEnvironment['TMP'] | Should -Be $contract.variables.TMP
        $nativeEnvironment['CI'] | Should -Be '1'
        $nativeEnvironment['OPENSPEC_TELEMETRY'] | Should -Be '0'
        $nativeEnvironment['OPENSPEC_NO_UPDATE_CHECK'] | Should -Be '1'
        $allowedNames = @('PATH', 'Path', 'SystemRoot', 'TEMP', 'TMP', 'CI', 'OPENSPEC_TELEMETRY', 'OPENSPEC_NO_UPDATE_CHECK')
        $unexpectedNames = @($nativeEnvironment.Keys | Where-Object { $allowedNames -cnotcontains [string]$_ })
        $unexpectedNames.Count | Should -Be 0
    }

    # Scenario: a direct reader invocation supplies an expanded or malformed native environment contract.
    # Purpose: enforce the explicit allowlist, one unambiguous path key, exact noninteractive flags, and valid values before launch.
    $invalidContractCases = @(
        @{ caseName = 'unapproved_key'; mutation = 'unapproved_key' }
        @{ caseName = 'missing_PATH'; mutation = 'missing_path' }
        @{ caseName = 'ambiguous_PATH_and_Path'; mutation = 'ambiguous_path' }
        @{ caseName = 'CI_flag'; mutation = 'ci_flag' }
        @{ caseName = 'telemetry_flag'; mutation = 'telemetry_flag' }
        @{ caseName = 'update_check_flag'; mutation = 'update_flag' }
        @{ caseName = 'null_value'; mutation = 'null_value' }
        @{ caseName = 'overlong_value'; mutation = 'overlong_value' }
        @{ caseName = 'embedded_NUL'; mutation = 'embedded_nul' }
    )
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $invalidContractCases += @{ caseName = 'missing_SystemRoot'; mutation = 'missing_systemroot' }
    }

    It 'InterT20_rejects_<caseName>_contract_before_native_launch' -TestCases $invalidContractCases {
        param($caseName, $mutation)
        $contract = New-ValidNativeEnvironmentContract
        switch -CaseSensitive ($mutation) {
            'unapproved_key' { $contract.variables['SYP171_LP3_SENTINEL_SECRET'] = 'synthetic-sentinel-only' }
            'missing_path' { $contract.variables.Remove('PATH') }
            'ambiguous_path' {
                $caseSensitiveVariables = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
                foreach ($entry in $contract.variables.GetEnumerator()) { $caseSensitiveVariables.Add([string]$entry.Key, $entry.Value) }
                $caseSensitiveVariables.Add('Path', [string]$caseSensitiveVariables['PATH'])
                $contract.variables = $caseSensitiveVariables
            }
            'ci_flag' { $contract.variables['CI'] = '0' }
            'telemetry_flag' { $contract.variables['OPENSPEC_TELEMETRY'] = '1' }
            'update_flag' { $contract.variables['OPENSPEC_NO_UPDATE_CHECK'] = '0' }
            'null_value' { $contract.variables['PATH'] = $null }
            'overlong_value' { $contract.variables['PATH'] = 'x' * 32768 }
            'embedded_nul' { $contract.variables['PATH'] = 'before' + [char]0 + 'after' }
            'missing_systemroot' { $contract.variables.Remove('SystemRoot') }
            default { throw "Unknown invalid environment-contract case: $mutation" }
        }
        $request = [ordered]@{
            operation = 'validateOpenSpec'
            root = [IO.Path]::GetFullPath($script:fixture.sourceRoot)
            changeId = 'manage-confluence-docs-as-code'
            environmentContract = $contract
        }
        $result = Invoke-DirectSourceReader -SourceRoot $script:fixture.sourceRoot -RuntimeRoot $script:fixture.runtimeRoot -Request $request -ProcessEnvironment (New-HostileReaderEnvironment)
        $result.status | Should -Be 'invalid'
        @($result.reasonCodes) | Should -Contain 'InvalidEnvironmentContract'
        (Test-Path -LiteralPath $script:fixture.nativeCapturePath) | Should -Be $false
    }

    # Scenario: the Windows host is missing a required OS variable while the verified runtime is otherwise valid.
    # Purpose: fail closed before launching the reader instead of producing an incomplete native child environment.
    $requiredWindowsEnvironmentCases = @()
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        foreach ($name in @('SystemRoot', 'TEMP', 'TMP')) { $requiredWindowsEnvironmentCases += @{ environmentKey = $name } }
    }
    It 'InterT35_parent_rejects_missing_<environmentKey>_before_native_launch' -TestCases $requiredWindowsEnvironmentCases {
        param($environmentKey)
        $receiptPath = "$($script:fixture.runtimeRoot).receipt.json"
        [IO.File]::WriteAllText($receiptPath, '{}', [Text.UTF8Encoding]::new($false))
        $previousFakeRuntime = [Environment]::GetEnvironmentVariable('SYP171_LP3_FAKE_RUNTIME', 'Process')
        $previousFakeNode = [Environment]::GetEnvironmentVariable('SYP171_LP3_FAKE_NODE', 'Process')
        $previousRequiredValue = [Environment]::GetEnvironmentVariable($environmentKey, 'Process')
        try {
            [Environment]::SetEnvironmentVariable('SYP171_LP3_FAKE_RUNTIME', $script:fixture.runtimeRoot, 'Process')
            [Environment]::SetEnvironmentVariable('SYP171_LP3_FAKE_NODE', $script:pinnedNodePath, 'Process')
            Import-Module -Name $script:modulePath -Force
            Mock -CommandName Test-ConfluenceDocsRuntimeReceipt -ModuleName OpenSpecSource -MockWith {
                [pscustomobject]@{
                    status = 'valid'
                    reasonCodes = @()
                    runtimeRoot = [Environment]::GetEnvironmentVariable('SYP171_LP3_FAKE_RUNTIME', 'Process')
                    nodePath = [Environment]::GetEnvironmentVariable('SYP171_LP3_FAKE_NODE', 'Process')
                }
            }
            [Environment]::SetEnvironmentVariable($environmentKey, $null, 'Process')

            $result = Test-OpenSpecSource -Root $script:fixture.sourceRoot -ChangeId 'manage-confluence-docs-as-code' -RuntimeRoot $script:fixture.runtimeRoot
            $result.status | Should -Be 'invalid'
            @($result.reasonCodes) | Should -Contain 'SourceEnvironmentContractInvalid'
            (Test-Path -LiteralPath $script:fixture.nativeCapturePath) | Should -Be $false
        }
        finally {
            [Environment]::SetEnvironmentVariable($environmentKey, $previousRequiredValue, 'Process')
            [Environment]::SetEnvironmentVariable('SYP171_LP3_FAKE_RUNTIME', $previousFakeRuntime, 'Process')
            [Environment]::SetEnvironmentVariable('SYP171_LP3_FAKE_NODE', $previousFakeNode, 'Process')
        }
    }

    # Scenario: Test-OpenSpecSource starts the reader with a fake receipt-valid runtime while the host has a sentinel secret.
    # Purpose: the parent must build, transmit, and apply the same minimal contract so the native validator remains isolated.
    It 'InterT40_parent_preserves_required_environment_and_excludes_host_secret' {
        $receiptPath = "$($script:fixture.runtimeRoot).receipt.json"
        [IO.File]::WriteAllText($receiptPath, '{}', [Text.UTF8Encoding]::new($false))
        $previousSecret = [Environment]::GetEnvironmentVariable('SYP171_LP3_SENTINEL_SECRET', 'Process')
        $previousFakeRuntime = [Environment]::GetEnvironmentVariable('SYP171_LP3_FAKE_RUNTIME', 'Process')
        $previousFakeNode = [Environment]::GetEnvironmentVariable('SYP171_LP3_FAKE_NODE', 'Process')
        try {
            [Environment]::SetEnvironmentVariable('SYP171_LP3_SENTINEL_SECRET', 'synthetic-sentinel-only', 'Process')
            [Environment]::SetEnvironmentVariable('SYP171_LP3_FAKE_RUNTIME', $script:fixture.runtimeRoot, 'Process')
            [Environment]::SetEnvironmentVariable('SYP171_LP3_FAKE_NODE', $script:pinnedNodePath, 'Process')
            Import-Module -Name $script:modulePath -Force
            Mock -CommandName Test-ConfluenceDocsRuntimeReceipt -ModuleName OpenSpecSource -MockWith {
                [pscustomobject]@{
                    status = 'valid'
                    reasonCodes = @()
                    runtimeRoot = [Environment]::GetEnvironmentVariable('SYP171_LP3_FAKE_RUNTIME', 'Process')
                    nodePath = [Environment]::GetEnvironmentVariable('SYP171_LP3_FAKE_NODE', 'Process')
                }
            }

            $result = Test-OpenSpecSource -Root $script:fixture.sourceRoot -ChangeId 'manage-confluence-docs-as-code' -RuntimeRoot $script:fixture.runtimeRoot
            $result.status | Should -Be 'valid'
            $result.nativeValidation.valid | Should -Be $true
            $nativeEnvironment = Get-CapturedNativeEnvironment -Path $script:fixture.nativeCapturePath
            $nativeEnvironment['SYP171_LP3_SENTINEL_SECRET'] | Should -BeNullOrEmpty
            $nativeEnvironment['CI'] | Should -Be '1'
            $nativeEnvironment['OPENSPEC_TELEMETRY'] | Should -Be '0'
            $nativeEnvironment['OPENSPEC_NO_UPDATE_CHECK'] | Should -Be '1'
            foreach ($name in @('PATH', 'SystemRoot', 'TEMP', 'TMP')) {
                $expectedValue = [Environment]::GetEnvironmentVariable($name, 'Process')
                if (-not [string]::IsNullOrWhiteSpace($expectedValue)) { $nativeEnvironment[$name] | Should -Be $expectedValue }
            }
        }
        finally {
            [Environment]::SetEnvironmentVariable('SYP171_LP3_SENTINEL_SECRET', $previousSecret, 'Process')
            [Environment]::SetEnvironmentVariable('SYP171_LP3_FAKE_RUNTIME', $previousFakeRuntime, 'Process')
            [Environment]::SetEnvironmentVariable('SYP171_LP3_FAKE_NODE', $previousFakeNode, 'Process')
        }
    }
}
