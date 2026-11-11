# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/StandardSourceDriver.psm1') -Force

Describe 'Standalone source helper copy consistency' {
    It 'keeps every AtlassianSourceCommon function identical to its top-level conformance copy' {
        $root = Split-Path -Parent $PSScriptRoot
        $tokens = $null; $parseErrors = $null
        $common = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts/AtlassianSourceCommon.psm1'), [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $conformance = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts/Invoke-SourceConformance.ps1'), [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $helpers = @($common.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))
        $helpers.Count | Should -BeGreaterThan 0
        $topLevelFunctions = @($conformance.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] })
        $differences = @(foreach ($helper in $helpers) {
            $copies = @($topLevelFunctions | Where-Object { $_.Name -ceq $helper.Name })
            if ($copies.Count -ne 1) {
                "$($helper.Name): expected one top-level definition, found $($copies.Count)"
            }
            elseif (($helper.Extent.Text -replace '\r\n?', "`n") -cne ($copies[0].Extent.Text -replace '\r\n?', "`n")) {
                "$($helper.Name): function text differs"
            }
        })
        $differences.Count | Should -Be 0 -Because ("helper copies must match: " + ($differences -join '; '))
    }
}

Describe 'Standalone source module dependency resolution without mocks' {
    It 'imports <ModuleName> and resolves all exports and external AST commands in a clean process' -ForEach @(
        @{ ModuleName = 'StandardSourceDriver' }
        @{ ModuleName = 'SkillSpectorExceptionCandidates' }
        @{ ModuleName = 'AtlassianSourceCommon' }
    ) {
        $modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) "scripts/$ModuleName.psm1"
        $probe = @'
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$path = '__MODULE_PATH__'
$module = Import-Module -Name $path -PassThru -ErrorAction Stop
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors.Message -join '; ') }
$defined = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object Name)
$missing = [Collections.Generic.List[string]]::new()
# Explicit export declarations are the contract, independent of the imported module.
$exports = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Export-ModuleMember' }, $true))
$expected = @($exports | ForEach-Object {
    $_.FindAll({ param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -in $defined }, $true) | ForEach-Object Value
})
if ($expected.Count -eq 0) { throw 'No explicit function exports found.' }
foreach ($name in $expected) {
    if (-not $module.ExportedFunctions.ContainsKey($name)) { $missing.Add("export:$name") }
    $null = & $module { param($Name) Get-Command -Name $Name -CommandType Function -ErrorAction Stop } $name
}
foreach ($name in @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true) |
    ForEach-Object { $_.GetCommandName() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)) {
    if ($name -in $defined) { continue }
    # Check even installed cmdlets in the module's own session state. No helper
    # allowlist, caller functions, Pester imports or mocks can satisfy this probe.
    $command = & $module { param($Name) Get-Command -Name $Name -ErrorAction SilentlyContinue } $name
    if ($null -eq $command) { $missing.Add($name) }
    else { Write-Output "$name => $($command.CommandType):$($command.Source)" }
}
if ($missing.Count) { throw "Unresolved commands: $($missing -join ', ')" }
'@
        $probe = $probe.Replace('__MODULE_PATH__', $modulePath.Replace("'", "''"))
        $pwsh = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path
        $output = @(& $pwsh -NoProfile -NonInteractive -EncodedCommand ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))) 2>&1)
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
    }

    It 'declares every late-bound Core command in the verified runner' {
        # Core functions are loaded locally only after runner hash verification;
        # they are not import-time dependencies on the caller's session state.
        $root = Split-Path -Parent $PSScriptRoot
        $tokens = $null; $errors = $null
        $driver = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts/StandardSourceDriver.psm1'), [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
        $runner = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts/Invoke-StandardValidation.ps1'), [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
        $definitions = @($runner.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object Name)
        $lookups = @($driver.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-Command' }, $true))
        foreach ($name in @('Invoke-StandardValidationProcess', 'Assert-StandardCoreFrozenFiles', 'Assert-StandardCoreSourceToolReceipts', 'Assert-StandardCoreSourceCheckReport')) {
            $definitions | Should -Contain $name
            @($lookups | Where-Object { $_.Extent.Text -ceq "Get-Command -Name '$name' -CommandType Function -ErrorAction Stop" }).Count | Should -BeGreaterThan 0
        }
    }
}

Describe 'Resolver GitHub token environment' {
    # Scenario: hosted runners rate-limit anonymous GitHub API calls made by the SkillSpector resolver.
    # Purpose: only the trusted resolver processes receive the namespaced token; nothing else does.
    BeforeAll {
        $script:DriverPathForToken = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/StandardSourceDriver.psm1'
        $script:OriginalGitHubToken = [Environment]::GetEnvironmentVariable('GITHUB_TOKEN')
        $script:OriginalStandardToken = [Environment]::GetEnvironmentVariable('STANDARD_VALIDATION_GITHUB_API_TOKEN')
        Import-Module $script:DriverPathForToken -Force
    }

    AfterEach {
        [Environment]::SetEnvironmentVariable('GITHUB_TOKEN', $script:OriginalGitHubToken)
        [Environment]::SetEnvironmentVariable('STANDARD_VALIDATION_GITHUB_API_TOKEN', $script:OriginalStandardToken)
    }

    It 'forwards GITHUB_TOKEN as the namespaced resolver token' {
        [Environment]::SetEnvironmentVariable('STANDARD_VALIDATION_GITHUB_API_TOKEN', $null)
        [Environment]::SetEnvironmentVariable('GITHUB_TOKEN', 'github-token-fixture')
        $environment = InModuleScope StandardSourceDriver { Get-AtlassianSourceResolverEnvironment }
        @($environment.Keys) | Should -Be @('STANDARD_VALIDATION_GITHUB_API_TOKEN')
        $environment['STANDARD_VALIDATION_GITHUB_API_TOKEN'] | Should -BeExactly 'github-token-fixture'
    }

    It 'prefers STANDARD_VALIDATION_GITHUB_API_TOKEN over GITHUB_TOKEN' {
        [Environment]::SetEnvironmentVariable('STANDARD_VALIDATION_GITHUB_API_TOKEN', 'standard-token-fixture')
        [Environment]::SetEnvironmentVariable('GITHUB_TOKEN', 'github-token-fixture')
        $environment = InModuleScope StandardSourceDriver { Get-AtlassianSourceResolverEnvironment }
        $environment['STANDARD_VALIDATION_GITHUB_API_TOKEN'] | Should -BeExactly 'standard-token-fixture'
    }

    It 'leaves the resolver environment anonymous when neither token exists' {
        [Environment]::SetEnvironmentVariable('STANDARD_VALIDATION_GITHUB_API_TOKEN', $null)
        [Environment]::SetEnvironmentVariable('GITHUB_TOKEN', $null)
        $environment = InModuleScope StandardSourceDriver { Get-AtlassianSourceResolverEnvironment }
        @($environment.Keys).Count | Should -Be 0
    }

    It 'passes the token environment only to the resolver process call' {
        $tokens = $null; $errors = $null
        $driver = [Management.Automation.Language.Parser]::ParseFile($script:DriverPathForToken, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
        $setup = @($driver.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Invoke-AtlassianSourceToolSetup' }, $true))[0]
        $calls = @($setup.Body.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.Extent.Text -match '-Environment\s' }, $true))
        $resolverCalls = @($calls | Where-Object { $_.Extent.Text -match "'-InstallRoot'" })
        $resolverCalls.Count | Should -Be 1
        $resolverCalls[0].Extent.Text | Should -Match '-Environment \$resolverEnvironment\b'
        $otherCalls = @($calls | Where-Object { $_.Extent.Text -notmatch "'-InstallRoot'" })
        $otherCalls.Count | Should -BeGreaterThan 0
        foreach ($call in $otherCalls) { $call.Extent.Text | Should -Not -Match 'resolverEnvironment' }
        $allUses = @($driver.FindAll({ param($n) $n -is [Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -ceq 'resolverEnvironment' }, $true))
        foreach ($use in $allUses) {
            $owner = $use.Parent
            while ($null -ne $owner -and $owner -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $owner = $owner.Parent }
            $owner.Name | Should -BeExactly 'Invoke-AtlassianSourceToolSetup'
        }
    }
}

Describe 'Protected Atlassian Core v2 source preparation' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:DriverPath = Join-Path $script:RepositoryRoot 'scripts/StandardSourceDriver.psm1'
        Import-Module $script:DriverPath -Force
        $script:BindingFixtureRunIds = [Collections.Generic.List[string]]::new()
        function Write-SourceBindingFixtureFile {
            param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][AllowEmptyString()][string] $Text)
            $fullPath = [IO.Path]::GetFullPath($Path)
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $fullPath) -Force)
            [IO.File]::WriteAllText($fullPath, $Text, [Text.UTF8Encoding]::new($false))
            return $fullPath
        }

        function Get-SourceBindingFixtureHash {
            param([Parameter(Mandatory)][string] $Path)
            return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        }

        function New-SourceBindingFixture {
            param(
                [Parameter(Mandatory)][string] $Root,
                [string] $AuthorityRevision = '472cbd6f533d3f6d0a5381862128ebcc87618a7c'
            )

            Import-Module -Name $script:DriverPath -Force
            $base = [IO.Path]::GetFullPath($Root)
            [void](New-Item -ItemType Directory -Path $base -Force)
            $runId = [guid]::NewGuid().ToString('N')
            $resolvedToolsRoot = Join-Path ([IO.Path]::GetTempPath()) "rt-$runId"
            if (Test-Path -LiteralPath $resolvedToolsRoot) { throw 'Fixture resolved tools root already exists.' }
            [void](New-Item -ItemType Directory -Path $resolvedToolsRoot -ErrorAction Stop)
            $script:BindingFixtureRunIds.Add($runId)
            $candidateRevision = 'a' * 40
            $ownedRoot = Join-Path $base "source-tools-$runId"
            $runtimeRoot = Join-Path $ownedRoot 'runtime'
            $runtimeExecutableName = if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' }
            $runtimeExecutable = Write-SourceBindingFixtureFile -Path (Join-Path $runtimeRoot $runtimeExecutableName) -Text 'fixture executable'
            $pesterModuleRoot = Join-Path $runtimeRoot 'Modules/Pester/6.2.0'
            $moduleManifest = Write-SourceBindingFixtureFile -Path (Join-Path $pesterModuleRoot 'Pester.psd1') -Text "@{ ModuleVersion = '6.2.0' }"
            $modulePayload = Write-SourceBindingFixtureFile -Path (Join-Path $pesterModuleRoot 'Pester.psm1') -Text '# fixture module payload'
            $closureLock = Write-SourceBindingFixtureFile -Path (Join-Path $ownedRoot 'pester-6.2.0-closure.lock.json') -Text '{"fixture":true}'
            $closureLockSha256 = Get-SourceBindingFixtureHash -Path $closureLock
            $setupReceiptPath = Write-SourceBindingFixtureFile -Path (Join-Path $ownedRoot 'pester-setup/setup-receipt.json') -Text '{}'
            $candidateArchivePath = Write-SourceBindingFixtureFile -Path (Join-Path $ownedRoot 'candidate.zip') -Text 'immutable candidate archive fixture'
            $manifestPath = Write-SourceBindingFixtureFile -Path (Join-Path $ownedRoot 'candidate-git-entry-modes.json') -Text '{"schemaVersion":3,"candidateCommit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","entries":[{"path":"skills/demo/SKILL.md","mode":"100644","sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]}'
            $sourceIdentityPath = Write-SourceBindingFixtureFile -Path (Join-Path $ownedRoot 'source-run-identity.json') -Text (([ordered]@{
                schemaVersion = 1; runId = $runId; sourceRevision = $candidateRevision
                authorityRevision = $AuthorityRevision
                candidateManifestPath = [IO.Path]::GetFullPath($manifestPath); candidateManifestSha256 = Get-SourceBindingFixtureHash -Path $manifestPath
                candidateArchivePath = [IO.Path]::GetFullPath($candidateArchivePath); candidateArchiveSha256 = Get-SourceBindingFixtureHash -Path $candidateArchivePath
            } | ConvertTo-Json -Depth 20 -Compress) + "`n")
            $wrapperPath = Write-SourceBindingFixtureFile -Path (Join-Path $ownedRoot 'Invoke-AtlassianValidationChild.ps1') -Text '# child fixture'
            $alternateWrapperPath = Write-SourceBindingFixtureFile -Path (Join-Path $ownedRoot 'alternate-frozen-script.ps1') -Text '# alternate frozen fixture script'
            $toolchainPath = Write-SourceBindingFixtureFile -Path (Join-Path $ownedRoot 'toolchain.json') -Text '{}'
            $resolverReceipts = @()
            $receiptPaths = @()
            $toolClosurePaths = @()
            foreach ($toolName in @('skill-validator', 'skill-tools', 'skillspector')) {
                $installRoot = Join-Path $resolvedToolsRoot $toolName
                $executablePath = Write-SourceBindingFixtureFile -Path (Join-Path $installRoot "$toolName.bin") -Text "$toolName executable"
                $executableSha256 = Get-SourceBindingFixtureHash -Path $executablePath
                $launcher = [pscustomobject]@{
                    kind = 'fixture-launcher'; shimPath = ''; shimSha256 = ''
                    payloadPath = ''; payloadSha256 = ''; runtimePath = ''; runtimeSha256 = ''
                }
                $receipt = [ordered]@{
                    toolName = $toolName; resolutionRunId = $runId; frozenForRun = $true
                    installRoot = [IO.Path]::GetFullPath($installRoot)
                    executablePath = $executablePath; executableSha256 = $executableSha256
                    entryPointPath = ''; entryPointSha256 = ''; nodePath = ''; nodeSha256 = ''
                    goRuntimePath = ''; goRuntimeSha256 = ''; resolverHelperPath = ''; resolverHelperSha256 = ''
                    launcher = $launcher
                }
                if ($toolName -ceq 'skill-tools') {
                    $shimPath = Write-SourceBindingFixtureFile -Path (Join-Path $installRoot 'skill-tools.cmd') -Text '@echo off'
                    $receipt.launcher.shimPath = $shimPath
                    $receipt.launcher.shimSha256 = Get-SourceBindingFixtureHash -Path $shimPath
                    $receipt.entryPointPath = $executablePath
                    $receipt.entryPointSha256 = $executableSha256
                    $receipt.nodePath = $executablePath
                    $receipt.nodeSha256 = $executableSha256
                }
                $receiptPath = Write-SourceBindingFixtureFile -Path (Join-Path $ownedRoot "receipt-$toolName.json") -Text (($receipt | ConvertTo-Json -Depth 20 -Compress) + "`n")
                $receiptPaths += $receiptPath
                $toolClosurePaths += @(Get-ChildItem -LiteralPath $installRoot -File -Recurse | ForEach-Object { [IO.Path]::GetFullPath($_.FullName) })
                $resolverReceipts += [pscustomobject]@{ path = $receiptPath; sha256 = (Get-SourceBindingFixtureHash -Path $receiptPath) }
            }

            $runtimeFiles = @(Get-ChildItem -LiteralPath $runtimeRoot -File -Recurse -Force | ForEach-Object {
                [pscustomobject]@{ path = [IO.Path]::GetFullPath($_.FullName); sha256 = (Get-SourceBindingFixtureHash -Path $_.FullName) }
            })
            $runtimeInventoryPath = Write-SourceBindingFixtureFile -Path (Join-Path $ownedRoot 'powershell-runtime-inventory.json') -Text '{}'
            $runtimeInventory = [ordered]@{
                schemaVersion = 1; root = [IO.Path]::GetFullPath($runtimeRoot)
                executablePath = [IO.Path]::GetFullPath($runtimeExecutable)
                executableSha256 = Get-SourceBindingFixtureHash -Path $runtimeExecutable
                files = @($runtimeFiles | Sort-Object -Property path -CaseSensitive)
            }
            [IO.File]::WriteAllText($runtimeInventoryPath, (($runtimeInventory | ConvertTo-Json -Depth 20) + "`n"), [Text.UTF8Encoding]::new($false))
            $runtimeInventorySha256 = Get-SourceBindingFixtureHash -Path $runtimeInventoryPath
            $setupTimingPath = Write-SourceBindingFixtureFile -Path (Join-Path $ownedRoot 'setup-timing.json') -Text (([ordered]@{
                schemaVersion = 1; runId = $runId; startedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
                stageTimingCapturedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
                stageSeconds = [ordered]@{ closureInventoryHashAndSortSeconds = 0.1 }
                resolverSeconds = [ordered]@{ 'skill-validator' = 0.1; 'skill-tools' = 0.1; skillspector = 0.1 }
                stageTimingBoundary = 'runtime copy, candidate manifest/archive, resolver, Pester setup, and first frozen-file inventory/hash/sort intervals only; excludes final verification and prepared metadata write'
            } | ConvertTo-Json -Depth 20 -Compress) + "`n")

            $setupReceipt = [ordered]@{
                schemaVersion = 1; report = 'verified-pester-runtime-setup-v1'; runId = $runId
                lockSha256 = $closureLockSha256; terminalStatus = 'verified'
                runtimeExecutable = [IO.Path]::GetFullPath($runtimeExecutable)
                runtimeModuleRoot = [IO.Path]::GetFullPath($pesterModuleRoot)
            }
            [IO.File]::WriteAllText($setupReceiptPath, (($setupReceipt | ConvertTo-Json -Depth 20 -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
            $setupReceiptSha256 = Get-SourceBindingFixtureHash -Path $setupReceiptPath

            $correctionWrapper = Write-SourceBindingFixtureFile -Path (Join-Path $ownedRoot 'Invoke-StandardStaticScan.ps1') -Text '# pinned correction fixture'
            $allSourceFiles = @($correctionWrapper, $candidateArchivePath, $manifestPath, $sourceIdentityPath, $wrapperPath, $alternateWrapperPath, $toolchainPath, $runtimeInventoryPath, $setupTimingPath, $closureLock) + $toolClosurePaths
            $pesterClosureFiles = @($moduleManifest, $modulePayload)
            $receiptFrozenPaths = @($toolClosurePaths)
            $receiptBindingPaths = @($receiptPaths)
            $receiptCommandPaths = @($resolverReceipts | ForEach-Object { [string]$_.path })
            $sourcePesterFiles = @($moduleManifest, $setupReceiptPath) + @($pesterClosureFiles)
            $sourceReceiptFiles = @($receiptFrozenPaths) + @($receiptBindingPaths) + @($receiptCommandPaths) + @($toolClosurePaths)
            $inventory = New-AtlassianSourceFrozenFileInventory -RuntimeFiles @($runtimeFiles | ForEach-Object { [string]$_.path }) `
                -SourceFiles $allSourceFiles -PesterFiles $sourcePesterFiles -ReceiptFiles $sourceReceiptFiles
            $frozenFiles = @($inventory.files)
            $toolchainSha256 = Get-SourceBindingFixtureHash -Path $toolchainPath
            $manifestSha256 = Get-SourceBindingFixtureHash -Path $manifestPath
            $sourceRepository = 'https://github.com/SyuanTsai/Skill-Atlassian-Ecosystem.git'
            $commonArguments = @('-NoProfile', '-NonInteractive', '-File', [IO.Path]::GetFullPath($wrapperPath),
                '-ToolchainPath', [IO.Path]::GetFullPath($toolchainPath), '-ToolchainSha256', $toolchainSha256,
                '-SourceRepository', $sourceRepository, '-SourceRevision', $candidateRevision,
                '-ArchiveSha256', (Get-SourceBindingFixtureHash -Path $candidateArchivePath),
                '-CoreSourceValidation')
            $sourceValidation = [pscustomobject]@{
                packageAdapter = [pscustomobject]@{ command = [IO.Path]::GetFullPath($runtimeExecutable); arguments = @($commonArguments + @('-Mode', 'package-adapter')) }
                skillValidator = [pscustomobject]@{ command = [IO.Path]::GetFullPath($runtimeExecutable); arguments = @($commonArguments + @('-Mode', 'skill-validator')) }
                skillTools = [pscustomobject]@{ command = [IO.Path]::GetFullPath($runtimeExecutable); arguments = @($commonArguments + @('-Mode', 'skill-tools')) }
                staticAnalyzer = [pscustomobject]@{ command = [IO.Path]::GetFullPath($runtimeExecutable); arguments = @($commonArguments + @('-Mode', 'static')) }
                frozenFiles = [object[]]$frozenFiles
                toolReceipts = [object[]]$resolverReceipts
            }
            $trustedRoot = Join-Path $base 'trusted-tools'
            [void](New-Item -ItemType Directory -Path $trustedRoot -Force)
            $prepared = [pscustomobject]@{
                schemaVersion = 1; preparation = 'atlassian-source-tools'; runId = $runId
                sourceRevision = $candidateRevision; authorityRevision = $AuthorityRevision
                ownedRoot = [IO.Path]::GetFullPath($ownedRoot)
                resolvedToolsRoot = [IO.Path]::GetFullPath($resolvedToolsRoot)
                candidateArchivePath = [IO.Path]::GetFullPath($candidateArchivePath)
                candidateArchiveSha256 = Get-SourceBindingFixtureHash -Path $candidateArchivePath
                sourceValidation = $sourceValidation
                pesterRuntime = [pscustomobject]@{
                    moduleManifestPath = [IO.Path]::GetFullPath($moduleManifest)
                    closureLockPath = [IO.Path]::GetFullPath($closureLock); closureLockSha256 = $closureLockSha256
                    setupReceiptPath = [IO.Path]::GetFullPath($setupReceiptPath); setupReceiptSha256 = $setupReceiptSha256
                    runtimeRoot = [IO.Path]::GetFullPath($runtimeRoot); runtimeExecutablePath = [IO.Path]::GetFullPath($runtimeExecutable)
                    runtimeExecutableSha256 = Get-SourceBindingFixtureHash -Path $runtimeExecutable
                    runtimeInventoryPath = [IO.Path]::GetFullPath($runtimeInventoryPath); runtimeInventorySha256 = $runtimeInventorySha256
                    sourceTrustedToolRoot = [IO.Path]::GetFullPath($trustedRoot)
                }
            }
            $preparedPath = Join-Path $base 'prepared-source-tools.json'
            [IO.File]::WriteAllText($preparedPath, (($prepared | ConvertTo-Json -Depth 80) + "`n"), [Text.UTF8Encoding]::new($false))
            return [pscustomobject]@{
                root = $base; runId = $runId; candidateRevision = $candidateRevision
                prepared = $prepared; preparedPath = [IO.Path]::GetFullPath($preparedPath)
                runtimeRoot = [IO.Path]::GetFullPath($runtimeRoot); runtimeExecutable = [IO.Path]::GetFullPath($runtimeExecutable)
                manifestPath = [IO.Path]::GetFullPath($manifestPath); authorityRevision = $AuthorityRevision
                toolClosurePaths = $toolClosurePaths; receiptPaths = $receiptPaths
            }
        }

    }

    AfterAll {
        foreach ($fixtureRunId in $script:BindingFixtureRunIds) {
            if ($fixtureRunId -cnotmatch '^[0-9a-f]{32}$') { throw 'Unsafe fixture cleanup identity.' }
            $fixtureRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) "rt-$fixtureRunId"))
            if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
        }
    }

    It 'passes the compact run-specific TEMP root to the actual resolver command' {
        $tokens = $null; $errors = $null
        $driver = [Management.Automation.Language.Parser]::ParseFile($script:DriverPath, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
        $setup = @($driver.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Invoke-AtlassianSourceToolSetup' }, $true))[0]
        $assignment = @($setup.Body.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$resolvedToolsRoot' }, $true))
        $assignment.Count | Should -Be 1
        $call = @($setup.Body.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.Extent.Text -match "'-InstallRoot'" }, $true))
        $call.Count | Should -Be 1
        & {
            param($AssignmentText, $CallText)
            function Invoke-StandardValidationProcess {
                param($Command, $Arguments, $WorkingDirectory, $Environment, $TimeoutSeconds, [switch]$CoreLifecycleOnly)
                $index = [array]::IndexOf($Arguments, '-InstallRoot')
                $index | Should -BeGreaterThan -1
                $Arguments[$index + 1] | Should -BeExactly (Join-Path ([IO.Path]::GetTempPath()) "rt-$runId")
                $Arguments[$index + 1].Length | Should -BeLessOrEqual ([IO.Path]::GetTempPath().Length + 35)
            }
            $runId = [guid]::NewGuid().ToString('N')
            $powerShell = 'fixture'; $resolver = 'resolver'; $policy = 'policy'; $toolName = 'skillspector'
            $goVersion = '1.0.0'; $receiptPath = 'receipt.json'; $ownedRoot = 'owned'; $timeoutSeconds = 60
            $resolverEnvironment = @{}
            . ([scriptblock]::Create($AssignmentText))
            . ([scriptblock]::Create($CallText))
        } $assignment[0].Extent.Text $call[0].Extent.Text
    }

    It 'rejects a rewritten resolved root and receipt paths outside the compact root' {
        $fixture = New-SourceBindingFixture -Root (Join-Path $TestDrive 'resolved-bindings')
        $arguments = @{
            Prepared = $fixture.prepared; PreparedPath = $fixture.preparedPath
            CandidateRevision = $fixture.candidateRevision; PowerShellPath = $fixture.runtimeExecutable
            SourceRepository = 'https://github.com/SyuanTsai/Skill-Atlassian-Ecosystem.git'
        }
        Assert-AtlassianSourcePreparedBindings @arguments | Should -BeTrue
        $originalRoot = $fixture.prepared.resolvedToolsRoot
        $fixture.prepared.resolvedToolsRoot = Join-Path $fixture.root 'other-tools'
        { Assert-AtlassianSourcePreparedBindings @arguments } | Should -Throw '*resolved tools root*'
        $fixture.prepared.resolvedToolsRoot = $originalRoot
        foreach ($field in @('installRoot', 'executablePath')) {
            $receiptPath = $fixture.receiptPaths[0]
            $originalText = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8
            $receipt = $originalText | ConvertFrom-Json -Depth 50
            $receipt.$field = $fixture.runtimeExecutable
            [IO.File]::WriteAllText($receiptPath, ($receipt | ConvertTo-Json -Depth 50), [Text.UTF8Encoding]::new($false))
            # Rebind hashes so the containment check itself must reject the receipt.
            $hash = Get-SourceBindingFixtureHash -Path $receiptPath
            $fixture.prepared.sourceValidation.toolReceipts[0].sha256 = $hash
            ($fixture.prepared.sourceValidation.frozenFiles | Where-Object path -EQ $receiptPath).sha256 = $hash
            { Assert-AtlassianSourcePreparedBindings @arguments } | Should -Throw '*must stay within*'
            [IO.File]::WriteAllText($receiptPath, $originalText, [Text.UTF8Encoding]::new($false))
            $hash = Get-SourceBindingFixtureHash -Path $receiptPath
            $fixture.prepared.sourceValidation.toolReceipts[0].sha256 = $hash
            ($fixture.prepared.sourceValidation.frozenFiles | Where-Object path -EQ $receiptPath).sha256 = $hash
        }
    }

    It 'allows a hash-bound external runtime below a junction while preserving its file check' {
        $base = Join-Path $TestDrive 'external-runtime-junction'
        $installRoot = Join-Path $base 'resolved/tool'
        $runtimeTarget = Join-Path $base 'runtime-target'
        $runtimeLink = Join-Path $base 'tool-cache-runtime'
        [void](New-Item -ItemType Directory -Path $installRoot -Force)
        [void](New-Item -ItemType Directory -Path $runtimeTarget -Force)
        $executable = Write-SourceBindingFixtureFile -Path (Join-Path $installRoot 'tool.bin') -Text 'tool'
        $runtime = Write-SourceBindingFixtureFile -Path (Join-Path $runtimeTarget 'go.exe') -Text 'go runtime'
        try {
            [void](New-Item -ItemType Junction -Path $runtimeLink -Target $runtimeTarget -ErrorAction Stop)
        }
        catch {
            # On hosts that cannot create junctions, exercise the same boundary by failing if the external path is sent to the ancestor checker.
            $runtimeLink = $runtimeTarget
            $module = Get-Module StandardSourceDriver
            $receipt = [pscustomobject]@{
                installRoot = $installRoot; executablePath = $executable; executableSha256 = Get-SourceBindingFixtureHash $executable
                entryPointPath = ''; entryPointSha256 = ''; nodePath = ''; nodeSha256 = ''
                goRuntimePath = (Join-Path $runtimeLink 'go.exe'); goRuntimeSha256 = Get-SourceBindingFixtureHash $runtime
                resolverHelperPath = ''; resolverHelperSha256 = ''
                launcher = [pscustomobject]@{ shimPath = ''; shimSha256 = ''; payloadPath = ''; payloadSha256 = ''; runtimePath = (Join-Path $runtimeLink 'go.exe'); runtimeSha256 = Get-SourceBindingFixtureHash $runtime }
            }
            & $module {
                param($Receipt, $Root, $ExternalRuntime)
                Mock Assert-NoReparseAncestors {
                    if ([IO.Path]::GetFullPath($Path) -ceq [IO.Path]::GetFullPath($ExternalRuntime)) { throw 'external path reached ancestor checker' }
                }
                Get-AtlassianSourceReceiptFrozenPaths -Receipt $Receipt -ResolvedToolsRoot $Root
            } $receipt (Join-Path $base 'resolved') (Join-Path $runtimeLink 'go.exe') | Should -Contain ([IO.Path]::GetFullPath((Join-Path $runtimeLink 'go.exe')))
            return
        }
        $linkedRuntime = Join-Path $runtimeLink 'go.exe'
        $receipt = [pscustomobject]@{
            installRoot = $installRoot; executablePath = $executable; executableSha256 = Get-SourceBindingFixtureHash $executable
            entryPointPath = ''; entryPointSha256 = ''; nodePath = ''; nodeSha256 = ''
            goRuntimePath = $linkedRuntime; goRuntimeSha256 = Get-SourceBindingFixtureHash $linkedRuntime
            resolverHelperPath = ''; resolverHelperSha256 = ''
            launcher = [pscustomobject]@{ shimPath = ''; shimSha256 = ''; payloadPath = ''; payloadSha256 = ''; runtimePath = $linkedRuntime; runtimeSha256 = Get-SourceBindingFixtureHash $linkedRuntime }
        }
        $module = Get-Module StandardSourceDriver
        $paths = & $module { param($Receipt, $Root) Get-AtlassianSourceReceiptFrozenPaths -Receipt $Receipt -ResolvedToolsRoot $Root } $receipt (Join-Path $base 'resolved')
        $paths | Should -Contain ([IO.Path]::GetFullPath($linkedRuntime))
    }

    It 'rejects an external runtime whose frozen hash does not match' {
        $installRoot = Join-Path $TestDrive 'external-runtime-hash/resolved/tool'
        $externalRoot = Join-Path $TestDrive 'external-runtime-hash/outside'
        $executable = Write-SourceBindingFixtureFile -Path (Join-Path $installRoot 'tool.bin') -Text 'tool'
        $runtime = Write-SourceBindingFixtureFile -Path (Join-Path $externalRoot 'node.exe') -Text 'node'
        $receipt = [pscustomobject]@{
            installRoot = $installRoot; executablePath = $executable; executableSha256 = Get-SourceBindingFixtureHash $executable
            entryPointPath = ''; entryPointSha256 = ''; nodePath = $runtime; nodeSha256 = ('0' * 64)
            goRuntimePath = ''; goRuntimeSha256 = ''; resolverHelperPath = ''; resolverHelperSha256 = ''; launcher = $null
        }
        $module = Get-Module StandardSourceDriver
        { & $module { param($Receipt, $Root) Get-AtlassianSourceReceiptFrozenPaths -Receipt $Receipt -ResolvedToolsRoot $Root } $receipt (Split-Path -Parent $installRoot) } |
            Should -Throw '*path/hash pair*'
    }

    It 'keeps rejecting a reparse ancestor inside the resolved install root' {
        $base = Join-Path $TestDrive 'install-root-reparse'
        $resolvedRoot = Join-Path $base 'resolved'
        $realRoot = Join-Path $base 'real-tool'
        $installRoot = Join-Path $resolvedRoot 'tool'
        [void](New-Item -ItemType Directory -Path $resolvedRoot -Force)
        [void](New-Item -ItemType Directory -Path $realRoot -Force)
        $executable = Write-SourceBindingFixtureFile -Path (Join-Path $realRoot 'tool.bin') -Text 'tool'
        try {
            [void](New-Item -ItemType Junction -Path $installRoot -Target $realRoot -ErrorAction Stop)
            $receipt = [pscustomobject]@{
                installRoot = $installRoot; executablePath = (Join-Path $installRoot 'tool.bin'); executableSha256 = Get-SourceBindingFixtureHash $executable
                entryPointPath = ''; entryPointSha256 = ''; nodePath = ''; nodeSha256 = ''
                goRuntimePath = ''; goRuntimeSha256 = ''; resolverHelperPath = ''; resolverHelperSha256 = ''; launcher = $null
            }
            $module = Get-Module StandardSourceDriver
            { & $module { param($Receipt, $Root) Get-AtlassianSourceReceiptFrozenPaths -Receipt $Receipt -ResolvedToolsRoot $Root } $receipt $resolvedRoot } |
                Should -Throw '*reparse point*'
        }
        catch {
            if ($_.Exception.Message -like '*reparse point*') { throw }
            # Junction creation can be denied by host policy; mock only the ancestor predicate in that environment.
            $module = Get-Module StandardSourceDriver
            & $module {
                param($Root)
                Mock Assert-NoReparseAncestors { throw 'Resolved source tool install root is backed by a reparse point: fixture' }
                $receipt = [pscustomobject]@{
                    installRoot = (Join-Path $Root 'tool'); executablePath = (Join-Path $Root 'tool/tool.bin'); executableSha256 = ('a' * 64)
                    entryPointPath = ''; entryPointSha256 = ''; nodePath = ''; nodeSha256 = ''
                    goRuntimePath = ''; goRuntimeSha256 = ''; resolverHelperPath = ''; resolverHelperSha256 = ''; launcher = $null
                }
                { Get-AtlassianSourceReceiptFrozenPaths -Receipt $receipt -ResolvedToolsRoot $Root } | Should -Throw '*reparse point*'
            } $resolvedRoot
        }
    }

    It 'passes every colliding runner parameter explicitly at each central runner dot-source' {
        $root = Split-Path -Parent $PSScriptRoot
        $tokens = $null; $errors = $null
        $runner = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts/Invoke-StandardValidation.ps1'), [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
        $runner.ParamBlock | Should -Not -BeNullOrEmpty
        $parameterNames = @($runner.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $driver = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts/StandardSourceDriver.psm1'), [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0

        # Actual runner bindings: setup's $runner, validation's $centralRunner,
        # and the runner path passed to the isolated New-Module script block.
        $imports = @($driver.FindAll({
            param($node)
            if ($node -isnot [Management.Automation.Language.CommandAst] -or
                $node.InvocationOperator -ne [Management.Automation.Language.TokenKind]::Dot) { return $false }
            $target = $node.CommandElements[0]
            return ($target -is [Management.Automation.Language.VariableExpressionAst] -and
                $target.VariablePath.UserPath -in @('runner', 'centralRunner', '__runnerPath')) -or
                ($target.Extent.Text -match 'Invoke-StandardValidation\.ps1')
        }, $true))
        $imports.Count | Should -BeGreaterThan 0
        $missing = @(foreach ($import in $imports) {
            $function = $import.Parent
            while ($null -ne $function -and $function -isnot [Management.Automation.Language.FunctionDefinitionAst]) {
                $function = $function.Parent
            }
            $function | Should -Not -BeNullOrEmpty -Because "runner import at line $($import.Extent.StartLineNumber) must have a containing function"
            $reads = @($function.Body.FindAll({
                param($node)
                if ($node -isnot [Management.Automation.Language.VariableExpressionAst] -or
                    $node.Extent.StartOffset -lt $import.Extent.EndOffset) { return $false }
                $owner = $node.Parent
                while ($null -ne $owner -and $owner -isnot [Management.Automation.Language.FunctionDefinitionAst]) {
                    $owner = $owner.Parent
                }
                if ($owner -ne $function) { return $false }
                $name = $node.VariablePath.UserPath
                if ($name -in @('_', 'PSItem', 'args', 'true', 'false', 'null', 'LASTEXITCODE', 'PSScriptRoot') -or
                    $name -like 'env:*') { return $false }
                # Declarations, foreach targets, and plain assignment targets
                # are writes. Member/index targets still read their base.
                if ($node.Parent -is [Management.Automation.Language.ParameterAst] -or
                    ($node.Parent -is [Management.Automation.Language.ForEachStatementAst] -and $node.Parent.Variable -eq $node) -or
                    ($node.Parent -is [Management.Automation.Language.AssignmentStatementAst] -and
                        $node.Parent.Left -eq $node -and $node.Parent.Operator -eq [Management.Automation.Language.TokenKind]::Equals)) {
                    return $false
                }
                return $true
            }, $true) | ForEach-Object {
                # Normalize scope qualifiers; -in/-notin compare without case.
                $_.VariablePath.UserPath -replace '^(local|private|script|global):', ''
            } | Sort-Object -Unique)
            $collisions = @($parameterNames | Where-Object { $_ -in $reads } | Sort-Object)
            $explicit = @($import.CommandElements | Where-Object {
                $_ -is [Management.Automation.Language.CommandParameterAst]
            } | ForEach-Object ParameterName)
            $absent = @($collisions | Where-Object { $_ -notin $explicit })
            if ($absent.Count -gt 0) {
                '{0}, line {1}: missing {2}' -f $function.Name, $import.Extent.StartLineNumber, (($absent | ForEach-Object { "-$_" }) -join ', ')
            }
        })
        $missing.Count | Should -Be 0 -Because ("runner imports must explicitly preserve colliding parameters: " + ($missing -join '; '))
    }

    It 'reproduces the original empty RunId binder failure when runner import omits RunId' {
        $runner = Join-Path $script:RepositoryRoot 'scripts/Invoke-StandardValidation.ps1'
        & {
            param($Runner, $Root)
            $runId = 'c' * 32
            $timeoutSeconds = 1800
            . $Runner -DefineFunctionsOnly -CandidateRoot $Root -AdapterPath (Join-Path $Root 'adapter.json') `
                -ArtifactsRoot $Root -SourceRepository 'fixture' -SourceRevision ('a' * 40) -BaseRevision ('a' * 40)
            $runId | Should -BeExactly ''
            $timeoutSeconds | Should -Be 300
            # Use the actual vendored binder. No child process can be launched:
            # binding fails before entering Invoke-StandardValidationProcess.
            $bindingError = $null
            try {
                Invoke-StandardValidationProcess -Command 'unused' -Arguments @('-RunId', $runId) `
                    -WorkingDirectory $Root -Environment @{} -TimeoutSeconds 1800 -CoreLifecycleOnly
            }
            catch { $bindingError = $_ }
            $bindingError | Should -Not -BeNullOrEmpty
            $bindingError.FullyQualifiedErrorId | Should -Match '^ParameterArgumentValidationErrorEmptyStringNotAllowed(?:,|$)'
            $bindingError.Exception.ParameterName | Should -BeExactly 'Arguments'
        } $runner $TestDrive
    }

    It 'locks the existing authority tuple and complete file closure' {
        $config = Get-Content (Join-Path $script:RepositoryRoot 'config/standard-v1.json') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 30
        $pin = Assert-AtlassianSourceAuthorityConfig -Config $config
        $pin.commit | Should -Be '472cbd6f533d3f6d0a5381862128ebcc87618a7c'
        $pin.archiveSha256 | Should -Be '357def24360566e9351af5c7b3bb8b8a7989f9ccb1eaf6f2401fa33e4069d8bf'
        foreach ($field in @('commit', 'archiveSha256')) {
            $changed = $config | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
            $changed.authority.$field = '0' * $changed.authority.$field.Length
            { Assert-AtlassianSourceAuthorityConfig -Config $changed } | Should -Throw
        }
        $config.authority.files[0].sha256 = '0' * 64
        { Assert-AtlassianSourceAuthorityConfig -Config $config } | Should -Throw '*identity mismatch*'
    }

    It 'rejects mixed modes, v1 adapters and missing setup identities' {
        $request = @{ SourceToolsPath = 'prepared.json'; AdapterVersion = 2; AuthorityCommit = (Get-PreparedSourceAuthorityPin).commit }
        Assert-AtlassianSourceRunRequest @request -PrepareSourceTools | Should -Be 'PrepareSourceTools'
        Assert-AtlassianSourceRunRequest @request -SourceValidation -RunId ('a' * 32) | Should -Be 'SourceValidation'
        { Assert-AtlassianSourceRunRequest @request -PrepareSourceTools -SourceValidation } | Should -Throw '*separate*'
        { Assert-AtlassianSourceRunRequest @request -SourceValidation } | Should -Throw '*RunId*'
        $request.AdapterVersion = 1
        { Assert-AtlassianSourceRunRequest @request -PrepareSourceTools } | Should -Throw '*adapter v2*'
    }

    It 'accepts the prepared closure and rejects changed dispatch, runtime and source identities' {
        $fixture = New-SourceBindingFixture -Root (Join-Path $TestDrive 'bindings')
        $arguments = @{
            Prepared = $fixture.prepared; PreparedPath = $fixture.preparedPath
            CandidateRevision = $fixture.candidateRevision; PowerShellPath = $fixture.runtimeExecutable
            SourceRepository = 'https://github.com/SyuanTsai/Skill-Atlassian-Ecosystem.git'
        }
        Assert-AtlassianSourcePreparedBindings @arguments | Should -BeTrue
        $original = $fixture.prepared.sourceValidation.staticAnalyzer.arguments[-1]
        $fixture.prepared.sourceValidation.staticAnalyzer.arguments[-1] = 'package-adapter'
        { Assert-AtlassianSourcePreparedBindings @arguments } | Should -Throw '*dispatch*'
        $fixture.prepared.sourceValidation.staticAnalyzer.arguments[-1] = $original
        $arguments.CandidateRevision = 'b' * 40
        { Assert-AtlassianSourcePreparedBindings @arguments } | Should -Throw
        $arguments.CandidateRevision = $fixture.candidateRevision
        Add-Content -LiteralPath $fixture.runtimeExecutable -Value 'drift'
        { Assert-AtlassianSourcePreparedBindings @arguments } | Should -Throw
    }

    It 'emits two full repository checks and the four source dispatches with frozen correction evidence' {
        $fixture = New-SourceBindingFixture -Root (Join-Path $TestDrive 'adapter')
        $adapter = New-AtlassianCoreAdapterV2 -PowerShellPath $fixture.runtimeExecutable -TrustedToolRoot $fixture.runtimeRoot `
            -CandidateAuthorityAdapterRunId $fixture.runId -CandidateRevision $fixture.candidateRevision `
            -CandidateGitEntryModeManifestPath $fixture.manifestPath -CandidateGitEntryModeManifestSha256 (Get-SourceBindingFixtureHash $fixture.manifestPath) `
            -ActiveSkillIds @('alpha', 'beta') -SourceValidation $fixture.prepared.sourceValidation -PesterRuntime $fixture.prepared.pesterRuntime
        $adapter.schemaVersion | Should -Be 2
        $adapter.adapter | Should -Be 'standard-core-adapter-v2'
        $adapter.skillsRoot | Should -Be 'skills'
        ($adapter.activeSkills -join ';') | Should -Be 'alpha;beta'
        ($adapter.checks.id -join ';') | Should -Be 'repository-general;repository-pester'
        ($adapter.checks.kind -join ';') | Should -Be 'general;pester'
        $adapter.checks[0].arguments | Should -Contain 'scripts/Test-Repository.ps1'
        $adapter.checks[0].arguments | Should -Contain '-ReadOnlySnapshot'
        $adapter.checks[1].arguments | Should -Contain 'scripts/Invoke-CorePester.ps1'
        foreach ($slot in @('packageAdapter', 'skillValidator', 'skillTools', 'staticAnalyzer')) {
            $adapter.sourceValidation.$slot.arguments | Should -Contain '-CoreSourceValidation'
        }
        @($adapter.sourceValidation.toolReceipts).Count | Should -Be 3
        $frozenNames = @($adapter.sourceValidation.frozenFiles | ForEach-Object { Split-Path -Leaf $_.path })
        $frozenNames | Should -Contain 'Invoke-StandardStaticScan.ps1'
        $frozenNames | Should -Contain 'receipt-skillspector.json'
        $driver = Get-Content $script:DriverPath -Raw -Encoding UTF8
        $driver | Should -Match '\$toolchain.staticResolutionRunId = \$runId'
        $driver | Should -Match '-SourceFiles @\([^\r\n]*\$toolchain.staticWrapperPath'
    }

    It 'retains the exact legacy source dispatch block' {
        $entry = (Get-Content (Join-Path $script:RepositoryRoot 'scripts/Validate.ps1') -Raw -Encoding UTF8) -replace "`r`n", "`n"
        $start = $entry.IndexOf('if ($SourceConformance -or (-not')
        $end = $entry.IndexOf('$script:IsWindowsHost', $start)
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($entry.Substring($start, $end - $start))
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
        $hash | Should -Be 'b918534908bfe609da194cea0fa7c40ba309c1fea718b1d1f125a8a6f89cf7ec'
    }

    It 'blocks changed exception candidates before any central source call and passes unchanged candidates through' {
        InModuleScope StandardSourceDriver -Parameters @{ Evidence = (Join-Path $TestDrive 'gate'); CandidateRoot = (Join-Path $TestDrive 'candidate') } {
            param($Evidence, $CandidateRoot)
            function Invoke-Syp482FixtureGit { $global:LASTEXITCODE = 0 }
            Mock Get-ResolvedGitPath { 'Invoke-Syp482FixtureGit' }
            Mock Resolve-GitRevision { if ($Revision -ceq 'HEAD') { 'a' * 40 } else { 'b' * 40 } }
            Mock Get-EventName { 'local' }
            Mock Read-JsonFile { [pscustomobject]@{ runId = ('a' * 32); pesterRuntime = [pscustomobject]@{ runtimeExecutablePath = 'fixture-pwsh' } } }
            Mock Assert-AtlassianSourceAuthorityConfig { Get-PreparedSourceAuthorityPin }
            Mock Get-ActiveSkillIds { @('alpha') }
            Mock Invoke-AtlassianSourceValidation {}
            Mock Test-SkillSpectorExceptionCandidateChange { $true }
            $arguments = @{
                RepositoryRoot = $CandidateRoot; ArtifactsRoot = $Evidence; OutputPath = (Join-Path $Evidence 'blocked.json')
                SourceValidation = $true; AdapterVersion = 2; SourceToolsPath = 'prepared.json'; AuthorityRepositoryRoot = 'authority'
            }
            Invoke-AtlassianSourceDriver @arguments | Should -Be 10
            Should -Invoke Invoke-AtlassianSourceValidation -Times 0 -Exactly
            $report = Get-Content $arguments.OutputPath -Raw | ConvertFrom-Json
            $report.state | Should -Be 'BLOCKED'
            $report.exitCode | Should -Be 10
            $report.message | Should -Be 'SkillSpector exception candidates changed; human approval and semantic review are required before source validation can pass.'
            Mock Test-SkillSpectorExceptionCandidateChange { $false }
            Invoke-AtlassianSourceDriver @arguments | Should -Be 0
            Should -Invoke Invoke-AtlassianSourceValidation -Times 1 -Exactly
            Resolve-SourceComparisonBaseInput -BaseCommit '' -EventName local | Should -Be 'HEAD^'
            { Resolve-SourceComparisonBaseInput -BaseCommit '' -EventName pre-push } | Should -Throw '*explicit base*'
        }
    }

    It 'accepts empty resident OutputPath and resolves the canonical validation default' {
        InModuleScope StandardSourceDriver -Parameters @{ Root = (Join-Path $TestDrive 'resident-default') } {
            param($Root)
            # Stop before any authority or native operation. Reaching this mock
            # proves the real resident parameter binder accepted an empty path.
            Mock Assert-AtlassianSourceAuthorityConfig { throw 'resident-empty-output-bound' }
            $arguments = @{
                GitPath = 'git'; PowerShellPath = 'pwsh'; RepositoryRoot = $Root
                CandidateRevision = ('a' * 40); BaseRevision = ('b' * 40)
                AuthorityConfig = @{}; AuthorityRepositoryRoot = $Root; SourceToolsPath = 'prepared.json'
                RunId = ('c' * 32); EventName = 'local'; ArtifactsRoot = $Root; OutputPath = ''
                ArtifactsRootWasExplicit = $false; ResidentEvidenceRoot = (Join-Path $Root 'evidence')
                ProtectedBaseRoot = $Root; TrustedToolRoot = $Root; TimeoutSeconds = 60
            }
            { Invoke-AtlassianSourceResidentTiming @arguments } | Should -Throw '*resident-empty-output-bound*'
            Should -Invoke Assert-AtlassianSourceAuthorityConfig -Times 1 -Exactly
            foreach ($explicit in @($false, $true)) {
                $resident = Get-AtlassianSourceCoreRunPaths -ArtifactsRoot $Root -ArtifactsRootWasExplicit $explicit -RunId $arguments.RunId -OutputPath $arguments.OutputPath
                $canonical = Get-AtlassianSourceCoreRunPaths -ArtifactsRoot $Root -ArtifactsRootWasExplicit $explicit -RunId $arguments.RunId
                $resident.outputPath | Should -BeExactly $canonical.outputPath
                $resident.outputPath | Should -BeExactly (Join-Path $resident.artifactsRoot 'standard-core-validation-v2-report.json')
            }
        }
    }

    It 'rejects new entry parameters mixed with legacy modes before dispatch' {
        $entry = Join-Path $script:RepositoryRoot 'scripts/Validate.ps1'
        $pwsh = (Get-Process -Id $PID).Path
        foreach ($mode in @('-SourceConformance', '-ProtectedPesterServerProxy', '-ProtectedPesterSupervisor')) {
            $output = @(& $pwsh -NoProfile -NonInteractive -File $entry -SourceValidation -AdapterVersion 2 $mode 2>&1)
            $LASTEXITCODE | Should -Not -Be 0
            ($output -join "`n") | Should -Match 'cannot be combined with legacy'
        }
        $output = @(& $pwsh -NoProfile -NonInteractive -File $entry -SourceValidation -AdapterVersion 1 2>&1)
        $LASTEXITCODE | Should -Not -Be 0
        ($output -join "`n") | Should -Match 'Select exactly one source mode'
    }
}
