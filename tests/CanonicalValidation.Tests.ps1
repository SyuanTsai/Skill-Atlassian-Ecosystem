# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Canonical Standard v1 validation adapter' {
    BeforeAll {
        function Get-CanonicalValidationObserverRunScript {
            param([Parameter(Mandatory)][string] $WorkflowPath)

            $lines = [IO.File]::ReadAllLines($WorkflowPath)
            $stepIndex = -1
            for ($index = 0; $index -lt $lines.Length; $index++) {
                if ($lines[$index] -ceq '      - name: Observe Stage 4 scanner evidence (diagnostic)') {
                    $stepIndex = $index
                    break
                }
            }
            if ($stepIndex -lt 0) { throw 'The named Stage 4 observer step is absent.' }

            $runIndex = -1
            for ($index = $stepIndex + 1; $index -lt $lines.Length; $index++) {
                if ($lines[$index] -ceq '        run: |') { $runIndex = $index; break }
                if ($lines[$index] -match '^      - name:') { break }
            }
            if ($runIndex -lt 0) { throw 'The named Stage 4 observer has no literal run block.' }

            $bodyLines = [System.Collections.Generic.List[string]]::new()
            for ($index = $runIndex + 1; $index -lt $lines.Length; $index++) {
                $line = $lines[$index]
                if ([string]::IsNullOrWhiteSpace($line)) { $bodyLines.Add(''); continue }
                if (-not $line.StartsWith('          ', [System.StringComparison]::Ordinal)) { break }
                $bodyLines.Add($line.Substring(10))
            }
            $body = [string]::Join("`n", $bodyLines.ToArray())
            $tokens = $null
            $parseErrors = $null
            [Management.Automation.Language.Parser]::ParseInput($body, [ref]$tokens, [ref]$parseErrors) | Out-Null
            if (@($parseErrors).Count -gt 0) { throw 'The extracted Stage 4 observer script does not parse.' }
            return $body
        }

        function Get-CanonicalWorkflowRunScript {
            param(
                [Parameter(Mandatory)][string] $WorkflowPath,
                [Parameter(Mandatory)][string] $StepName
            )

            $lines = [IO.File]::ReadAllLines($WorkflowPath)
            $stepIndex = -1
            for ($index = 0; $index -lt $lines.Length; $index++) {
                if ($lines[$index] -ceq "      - name: $StepName") { $stepIndex = $index; break }
            }
            if ($stepIndex -lt 0) { throw "The named workflow step '$StepName' is absent." }

            $runIndex = -1
            for ($index = $stepIndex + 1; $index -lt $lines.Length; $index++) {
                if ($lines[$index] -ceq '        run: |') { $runIndex = $index; break }
                if ($lines[$index] -match '^      - name:') { break }
            }
            if ($runIndex -lt 0) { throw "The named workflow step '$StepName' has no literal run block." }

            $bodyLines = [System.Collections.Generic.List[string]]::new()
            for ($index = $runIndex + 1; $index -lt $lines.Length; $index++) {
                $line = $lines[$index]
                if ([string]::IsNullOrWhiteSpace($line)) { $bodyLines.Add(''); continue }
                if (-not $line.StartsWith('          ', [StringComparison]::Ordinal)) { break }
                $bodyLines.Add($line.Substring(10))
            }
            $body = [string]::Join("`n", $bodyLines.ToArray())
            $tokens = $null
            $parseErrors = $null
            [Management.Automation.Language.Parser]::ParseInput($body, [ref]$tokens, [ref]$parseErrors) | Out-Null
            if (@($parseErrors).Count -gt 0) { throw "The extracted workflow step '$StepName' does not parse." }
            return $body
        }

        function Invoke-CanonicalWorkflowChild {
            param(
                [Parameter(Mandatory)][string] $ScriptPath,
                [Parameter(Mandatory)][System.Collections.IDictionary] $Environment
            )

            $pwshPath = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path
            $startInfo = [Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $pwshPath
            $startInfo.UseShellExecute = $false
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $ScriptPath)) {
                [void]$startInfo.ArgumentList.Add($argument)
            }
            foreach ($key in $Environment.Keys) { $startInfo.Environment[[string]$key] = [string]$Environment[$key] }

            $process = [Diagnostics.Process]::new()
            $process.StartInfo = $startInfo
            [void]$process.Start()
            $stdout = $process.StandardOutput.ReadToEnd()
            $stderr = $process.StandardError.ReadToEnd()
            $process.WaitForExit()
            [pscustomobject]@{ ExitCode = $process.ExitCode; Stdout = $stdout; Stderr = $stderr }
        }

        function New-CanonicalExitPropagationFixture {
            param(
                [Parameter(Mandatory)][string] $Root,
                [Parameter(Mandatory)][string] $WorkflowPath
            )

            $checkout = Join-Path $Root 'checkout'
            $runnerTemp = Join-Path $Root 'runner-temp'
            $scripts = Join-Path $checkout 'scripts'
            New-Item -ItemType Directory -Path $scripts -Force | Out-Null
            New-Item -ItemType Directory -Path $runnerTemp -Force | Out-Null

            $validateStub = @'
param(
    [switch] $SourceConformance,
    [string] $ArtifactsRoot,
    [string] $BaseCommit,
    [string] $ExpectedGoRuntimeVersion,
    [string] $OutputPath
)
if (-not $SourceConformance -or $ArtifactsRoot -cne $env:RUNNER_TEMP) { throw 'Invalid isolated Validate boundary invocation.' }
[IO.File]::WriteAllBytes($OutputPath, [IO.File]::ReadAllBytes($env:SYP171_CANONICAL_REPORT_TEMPLATE))
$global:LASTEXITCODE = [int]$env:SYP171_CANONICAL_EXIT_CODE
'@
            $validatePath = Join-Path $scripts 'Validate.ps1'
            [IO.File]::WriteAllText($validatePath, $validateStub, [Text.UTF8Encoding]::new($false))

            $gitPath = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path
            & $gitPath -C $checkout init --quiet
            if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the isolated canonical-exit repository.' }
            & $gitPath -C $checkout add -- scripts/Validate.ps1
            if ($LASTEXITCODE -ne 0) { throw 'Could not stage the isolated Validate boundary stub.' }
            & $gitPath -C $checkout -c user.name=CanonicalValidationTest -c user.email=canonical-validation@example.invalid commit --quiet -m fixture
            if ($LASTEXITCODE -ne 0) { throw 'Could not commit the isolated Validate boundary stub.' }
            $candidateSha = ([string](& $gitPath -C $checkout rev-parse HEAD)).Trim()
            if ($LASTEXITCODE -ne 0 -or $candidateSha -notmatch '^[0-9a-f]{40}$') { throw 'Could not resolve the isolated workflow candidate.' }

            $canonicalRun = Get-CanonicalWorkflowRunScript -WorkflowPath $WorkflowPath -StepName 'Run canonical Standard v1 validation'
            $launchPath = Join-Path $Root 'run-canonical-validation.ps1'
            $launchText = "Set-Location -LiteralPath (Join-Path `$PSScriptRoot 'checkout')`n" + $canonicalRun + "`n"
            [IO.File]::WriteAllText($launchPath, $launchText, [Text.UTF8Encoding]::new($false))
            $reportTemplatePath = Join-Path $Root 'report-template.json'
            [IO.File]::WriteAllText($reportTemplatePath, '{"fixture":"canonical-exit-propagation"}', [Text.UTF8Encoding]::new($false))

            [pscustomobject]@{
                Root = $Root
                RunnerTemp = $runnerTemp
                LaunchPath = $launchPath
                CandidateSha = $candidateSha
                ReportTemplatePath = $reportTemplatePath
            }
        }

        function New-CanonicalSourcePassLaterFailureReport {
            param([Parameter(Mandatory)][string] $CandidateSha)

            $candidateId = 'b' * 64
            $contentSha = 'c' * 64
            $stages = @(0..9 | ForEach-Object {
                [pscustomobject][ordered]@{
                    id = "stage-$($_ + 1)"
                    order = $_ + 1
                    status = if ($_ -lt 5) { 'passed' } elseif ($_ -eq 5) { 'blocked' } else { 'not-run' }
                    events = @()
                }
            })
            [ordered]@{
                schemaVersion = 1
                evidence = 'standard-validation-evidence-v1'
                contract = 'standard-validation-contract-v1'
                state = 'BLOCKED'
                exitCode = 10
                releaseEligible = $false
                candidate = [ordered]@{ sourceRevision = $CandidateSha; candidateId = $candidateId; contentSha256 = $contentSha }
                stages = $stages
                sourceConformance = [ordered]@{
                    schemaVersion = 1
                    contract = 'standard-source-conformance-v1'
                    scope = 'source-stages-1-5'
                    status = 'passed'
                    sourceRevision = $CandidateSha
                    candidateId = $candidateId
                    contentSha256 = $contentSha
                    checkedStages = @('s1', 's2', 's3', 's4', 's5')
                    pester = [ordered]@{ eventCount = 1; testInventoryCount = 1; total = 1; passed = 1; failed = 0 }
                    canonicalValidation = [ordered]@{ state = 'BLOCKED'; exitCode = 10; releaseEligible = $false; stage6Status = 'blocked' }
                    releaseEligible = $false
                    failureReasons = @()
                }
            }
        }

        function New-CanonicalValidationObserverFixture {
            param(
                [Parameter(Mandatory)][string] $RepositoryRoot,
                [switch] $Mismatch,
                [switch] $IncludeSensitiveSentinel,
                [switch] $TaintedFields,
                [switch] $LargeProjection,
                [switch] $LargeArray,
                [switch] $NestedUntrustedValue,
                [switch] $DuplicateProvider,
                [switch] $ReparseProvider,
                [switch] $EventOutputOutsideRunsRoot,
                [switch] $MissingProvider,
                [switch] $InvalidIdentity,
                [switch] $SourceMismatch,
                [switch] $ExecutionMismatch,
                [switch] $CleanupFalse,
                [ValidateSet('utf8', 'bom', 'invalid')][string] $ProviderEncoding = 'utf8',
                [ValidateRange(0, 2097153)][int] $ProviderByteCount = 0
            )

            $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('syp171-observer-' + [guid]::NewGuid().ToString('N'))
            $runnerTemp = Join-Path $tempRoot 'runner-temp'
            New-Item -ItemType Directory -Path $runnerTemp -Force | Out-Null
            $runId = 'a' * 64
            $candidateId = 'b' * 64
            $contentSha256 = 'c' * 64
            $sourceRevision = 'd' * 40
            $eventGuid = [guid]'8f0b2041-6d9a-4ff7-9a09-0a285a8f2a72'
            $eventId = $eventGuid.ToString('D')
            $runDirectory = Join-Path (Join-Path $runnerTemp 'runs') $runId
            $candidateSkillRoot = Join-Path $runDirectory 'candidate-snapshot/skills/manage-confluence-docs-as-code'
            $inventory = @(
                'SKILL.md', 'agents/openai.yaml', 'references/authorization.schema.json',
                'references/capture.schema.json', 'references/confluence-mapping.schema.json',
                'references/import-review.md', 'references/import-review.schema.json',
                'references/operation-journal.schema.json', 'references/publish-plan.schema.json',
                'references/sync-state.schema.json', 'scripts/ConfluenceAssets.psm1',
                'scripts/ConfluenceCodeBinding.psm1', 'scripts/ConfluenceDocs.psm1',
                'scripts/ConfluenceMapping.psm1', 'scripts/ConfluenceMarkdownWorkflow.psm1',
                'scripts/ConfluencePlan.psm1', 'scripts/ConfluencePublish.psm1',
                'scripts/ConfluenceStorage.psm1', 'scripts/ConfluenceTransport.psm1',
                'scripts/ConfluenceValidation.psm1', 'scripts/ImportReview.psm1',
                'scripts/MarkdownProjection.psm1', 'scripts/Pull-ConfluenceDocs.ps1',
                'scripts/Push-ConfluenceDocs.ps1', 'scripts/StorageProjection.psm1',
                'scripts/StrictJson.psm1', 'scripts/Test-ConfluenceDocs.ps1'
            )
            foreach ($relative in $inventory) {
                $path = Join-Path $candidateSkillRoot ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
                $parent = Split-Path -Parent $path
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
                [IO.File]::WriteAllText($path, "line one`nline two`n", [Text.UTF8Encoding]::new($false))
            }

            $completeness = [pscustomobject][ordered]@{
                total_components = 27
                scanned_components = 17
                coverage_percent = 63.0
                is_complete = $false
                status = 'partial'
                execution_successful = $true
                fully_inspected_files = 17
                partially_inspected_files = 10
                entirely_uninspected_files = 0
                ledger_exceptions = @([pscustomobject][ordered]@{
                    outcome = 'partial'; phase = 'static'; reason_code = 'static_parse_limit'
                    message = 'SYNTHETIC_PRIVATE_MESSAGE'; path = 'scripts/ConfluenceTransport.psm1'
                    start_line = 1; end_line = 2; fatal = $false; analyzers = @('static_patterns_tool_misuse')
                })
                scope_exclusions = @()
                analyzer_statuses = @([pscustomobject][ordered]@{
                    analyzer_id = 'static_patterns_tool_misuse'; status = 'degraded'
                    planned_work = 27; completed = 17; partial = 10; skipped = 0; failed = 0; unaccounted = 0
                    reason_code = 'disabled_by_configuration'; message = 'SYNTHETIC_PRIVATE_ANALYZER_MESSAGE'
                })
                references = @([pscustomobject][ordered]@{
                    source_path = 'SKILL.md'; line = 1; column = 1; evidence = 'SYNTHETIC_PRIVATE_EVIDENCE'
                    target_path = 'scripts/ConfluenceTransport.psm1'; status = 'resolved'
                    disposition = 'analyzed'; reference_kind = 'markdown_link'
                })
                limitations = @('SYNTHETIC_PRIVATE_LIMITATION')
                findings_before_filtering = 4
                findings_after_filtering = 4
            }
            if ($Mismatch) { $completeness.scanned_components = 16 }
            if ($TaintedFields) {
                $completeness.coverage_percent = '63.0'
                $completeness.scanned_components = $null
                $completeness.status = 'SYP171_PRIVATE_ENUM_SENTINEL'
                $completeness.ledger_exceptions[0].start_line = 2
                $completeness.ledger_exceptions[0].end_line = 1
                $completeness.ledger_exceptions = @($completeness.ledger_exceptions) + @([pscustomobject][ordered]@{
                    outcome = 'partial'; phase = 'static'; reason_code = 'reference_missing'
                    message = 'SYP171_PRIVATE_TAINTED_LEDGER_MESSAGE'; path = 'references/SYP171_PRIVATE_SENTINEL_59b62.txt'
                    start_line = 1; end_line = 2; fatal = $false; analyzers = @('static_patterns_tool_misuse')
                })
                $completeness.references[0].line = 99
                $completeness.references[0].target_path = '../SYP171_PRIVATE_SENTINEL_59b62.txt'
            }
            if ($LargeProjection) {
                $largeLedger = [System.Collections.Generic.List[object]]::new()
                for ($itemIndex = 0; $itemIndex -lt 220; $itemIndex++) {
                    $largeLedger.Add([pscustomobject][ordered]@{
                        outcome = 'partial'; phase = 'static'; reason_code = 'static_parse_limit'
                        message = 'SYNTHETIC_PRIVATE_MESSAGE'; path = 'scripts/ConfluenceTransport.psm1'
                        start_line = 1; end_line = 2; fatal = $false; analyzers = @('static_patterns_tool_misuse')
                    })
                }
                $completeness.ledger_exceptions = $largeLedger.ToArray()
            }
            if ($LargeArray) { $completeness.limitations = @((1..1100 | ForEach-Object { 'SYNTHETIC_PRIVATE_LIMITATION' })) }
            $provider = [ordered]@{
                skill = [ordered]@{ name = 'manage-confluence-docs-as-code'; source = $candidateSkillRoot }
                execution_successful = (-not $ExecutionMismatch)
                analysis_completeness = $completeness
            }
            if ($InvalidIdentity) { $provider.skill.name = 'other-skill' }
            if ($SourceMismatch) { $provider.skill.source = Join-Path $tempRoot 'other-candidate' }
            if ($IncludeSensitiveSentinel) {
                $provider['diagnostic_probe'] = 'SYP171_PRIVATE_SENTINEL_59b62 ::add-mask::SYP171_PRIVATE_SENTINEL_59b62'
                $provider['workflow_command'] = '::add-mask::SYP171_PRIVATE_SENTINEL_59b62'
                $provider['unknown_path'] = '../SYP171_PRIVATE_SENTINEL_59b62.txt'
                $provider['SYP171_PRIVATE_KEY_SENTINEL'] = 'SYP171_PRIVATE_SENTINEL_59b62'
                $provider.skill['SYP171_PRIVATE_SKILL_KEY'] = 'SYP171_PRIVATE_SENTINEL_59b62'
                $completeness | Add-Member -NotePropertyName 'SYP171_PRIVATE_COMPLETENESS_KEY' -NotePropertyValue 'SYP171_PRIVATE_SENTINEL_59b62'
            }
            if ($NestedUntrustedValue) {
                $nestedUntrusted = 'SYP171_PRIVATE_NESTED_SENTINEL'
                for ($depth = 0; $depth -lt 40; $depth++) { $nestedUntrusted = [pscustomobject]@{ child = $nestedUntrusted; value = 'SYP171_PRIVATE_NESTED_SENTINEL' } }
                $provider['SYP171_PRIVATE_DEEP_PROPERTY'] = $nestedUntrusted
            }

            $providerDirectory = Join-Path (Join-Path (Join-Path $runnerTemp 'child-work') ('e' * 32)) $eventGuid.ToString('N')
            $providerKeyDirectory = Split-Path -Parent $providerDirectory
            New-Item -ItemType Directory -Path $providerKeyDirectory -Force | Out-Null
            $providerPath = Join-Path $providerDirectory 'skillspector-manage-confluence-docs-as-code.json'
            $providerJson = ConvertTo-Json -InputObject $provider -Compress -Depth 100
            $providerBytes = [Text.UTF8Encoding]::new($false).GetBytes($providerJson)
            if ($ProviderByteCount -gt 0) {
                if ($ProviderByteCount -lt $providerBytes.Length) { throw 'The requested provider byte count is smaller than its JSON fixture.' }
                $providerJson += ' ' * ($ProviderByteCount - $providerBytes.Length)
                $providerBytes = [Text.UTF8Encoding]::new($false).GetBytes($providerJson)
            }
            switch ($ProviderEncoding) {
                'bom' { $providerBytes = [byte[]](@(0xEF, 0xBB, 0xBF) + $providerBytes) }
                'invalid' { $providerBytes[0] = 0xFF }
            }
            $outsideProviderDirectory = $null
            $providerDirectoryLinkType = $null
            if ($ReparseProvider) {
                $outsideProviderDirectory = Join-Path $tempRoot 'outside-provider-directory'
                New-Item -ItemType Directory -Path $outsideProviderDirectory -Force | Out-Null
                [IO.File]::WriteAllBytes((Join-Path $outsideProviderDirectory 'skillspector-manage-confluence-docs-as-code.json'), $providerBytes)
                if ($IsWindows) {
                    $providerDirectoryLinkType = 'Junction'
                    New-Item -ItemType Junction -Path $providerDirectory -Target $outsideProviderDirectory -ErrorAction Stop | Out-Null
                }
                else {
                    $providerDirectoryLinkType = 'SymbolicLink'
                    New-Item -ItemType SymbolicLink -Path $providerDirectory -Target $outsideProviderDirectory -ErrorAction Stop | Out-Null
                }
                $providerDirectoryLink = Get-Item -LiteralPath $providerDirectory -Force
                if (($providerDirectoryLink.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                    throw 'The provider directory fixture is not a reparse point.'
                }
                $resolvedProviderTarget = [IO.DirectoryInfo]::new($providerDirectory).ResolveLinkTarget($true)
                $pathComparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
                if ($null -eq $resolvedProviderTarget -or
                    -not [string]::Equals(
                        [IO.Path]::GetFullPath($resolvedProviderTarget.FullName),
                        [IO.Path]::GetFullPath($outsideProviderDirectory),
                        $pathComparison
                    )) {
                    throw 'The provider directory fixture resolved outside its owned target.'
                }
            }
            else { New-Item -ItemType Directory -Path $providerDirectory -Force | Out-Null }
            if (-not $MissingProvider) { [IO.File]::WriteAllBytes($providerPath, $providerBytes) }
            if ($DuplicateProvider -and -not $MissingProvider) {
                $duplicateDirectory = Join-Path (Join-Path (Join-Path $runnerTemp 'child-work') ('f' * 32)) $eventGuid.ToString('N')
                New-Item -ItemType Directory -Path $duplicateDirectory -Force | Out-Null
                [IO.File]::WriteAllBytes((Join-Path $duplicateDirectory 'skillspector-manage-confluence-docs-as-code.json'), $providerBytes)
            }

            $stderrDetail = [pscustomobject][ordered]@{ completeness = $completeness; executionSuccessful = $true }
            if ($Mismatch) {
                $stderrCompleteness = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $completeness -Compress -Depth 100) -Depth 100
                $stderrCompleteness.scanned_components = 17
                $stderrDetail.completeness = $stderrCompleteness
            }
            $stderrPrefix = "SkillSpector did not prove complete static analysis for 'manage-confluence-docs-as-code': "
            $stderr = $stderrPrefix + (ConvertTo-Json -InputObject $stderrDetail -Compress -Depth 100)
            $stdout = ''
            $composite = $stdout + [char]10 + '---stderr---' + [char]10 + $stderr
            $outputHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($composite))).ToLowerInvariant()
            $event = [ordered]@{
                eventId = $eventId; stageId = 'skillspector-static'; toolId = 'staticAnalyzer'; skillId = $null
                candidateId = $candidateId; status = 'failed'; exitCode = 20
                commandSha256 = '1' * 64; outputSha256 = $outputHash; cleanedUp = (-not $CleanupFalse)
                outputPath = if ($EventOutputOutsideRunsRoot) {
                    Join-Path $tempRoot "event-$eventId.json"
                }
                else {
                    Join-Path (Join-Path (Join-Path $runnerTemp 'runs') $runId) ("skillspector-static/event-$eventId.json")
                }
            }
            $rawEvent = [ordered]@{
                schemaVersion = 1; eventId = $eventId; stageId = 'skillspector-static'; toolId = 'staticAnalyzer'
                skillId = $null; candidateId = $candidateId
                process = [ordered]@{
                    status = 'failed'; exitCode = 20; cleanedUp = (-not $CleanupFalse); outputQuotaExceeded = $false
                    stdout = $stdout; stderr = $stderr
                }
                stdout = $stdout; stderr = $stderr
            }
            $eventDirectory = Split-Path -Parent $event.outputPath
            New-Item -ItemType Directory -Path $eventDirectory -Force | Out-Null
            [IO.File]::WriteAllText($event.outputPath, (ConvertTo-Json -InputObject $rawEvent -Compress -Depth 100), [Text.UTF8Encoding]::new($false))

            $stages = [System.Collections.Generic.List[object]]::new()
            for ($index = 0; $index -lt 10; $index++) {
                $stages.Add([pscustomobject][ordered]@{ id = "stage-$($index + 1)"; order = $index + 1; status = 'passed'; events = @() })
            }
            $stages[3] = [pscustomobject][ordered]@{ id = 'skillspector-static'; order = 4; status = 'failed'; events = @([pscustomobject]$event) }
            $stages[5] = [pscustomobject][ordered]@{ id = 'canonical-validation'; order = 6; status = 'not-run'; events = @() }
            $report = [ordered]@{
                schemaVersion = 1; evidence = 'standard-validation-evidence-v1'; contract = 'standard-validation-contract-v1'
                state = 'FAILED'; exitCode = 20; releaseEligible = $false
                candidate = [ordered]@{ sourceRevision = $sourceRevision; candidateId = $candidateId; contentSha256 = $contentSha256 }
                sourceConformance = [ordered]@{
                    schemaVersion = 1; contract = 'standard-source-conformance-v1'; status = 'failed'; scope = 'source-stages-1-5'
                    sourceRevision = $sourceRevision; candidateId = $candidateId; contentSha256 = $contentSha256
                    releaseEligible = $false; checkedStages = @('s1','s2','s3','s4','s5'); failureReasons = @('stage-failed')
                    canonicalValidation = [ordered]@{ state = 'FAILED'; exitCode = 20; releaseEligible = $false; stage6Status = 'not-run' }
                }
                stages = $stages.ToArray()
            }
            [IO.File]::WriteAllText((Join-Path $runnerTemp 'atlassian-source-conformance-report.json'), (ConvertTo-Json -InputObject $report -Compress -Depth 100), [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $runnerTemp 'atlassian-central-exit.txt'), '20', [Text.UTF8Encoding]::new($false))
            return [pscustomobject]@{
                Root = $tempRoot
                RunnerTemp = $runnerTemp
                SourceRevision = $sourceRevision
                ReparseProvider = [bool]$ReparseProvider
                ProviderDirectoryPath = $providerDirectory
                ProviderDirectoryLinkType = $providerDirectoryLinkType
                OutsideProviderDirectoryPath = $outsideProviderDirectory
                OutsideProviderPath = if ($ReparseProvider) { Join-Path (Join-Path $tempRoot 'outside-provider-directory') 'skillspector-manage-confluence-docs-as-code.json' } else { $null }
            }
        }

        function Invoke-CanonicalValidationObserverFixture {
            param(
                [Parameter(Mandatory)] $Fixture,
                [Parameter(Mandatory)][string] $WorkflowPath,
                [ValidateRange(0, 2)][int] $FailCanonicalCall = 0,
                [switch] $FailDiagnosticTransport
            )
            $oldRunnerTemp = [Environment]::GetEnvironmentVariable('RUNNER_TEMP', 'Process')
            $oldGitHubSha = [Environment]::GetEnvironmentVariable('GITHUB_SHA', 'Process')
            $oldGitHubEnv = [Environment]::GetEnvironmentVariable('GITHUB_ENV', 'Process')
            $oldGitHubOutput = [Environment]::GetEnvironmentVariable('GITHUB_OUTPUT', 'Process')
            $oldFail = [Environment]::GetEnvironmentVariable('SYP171_OBSERVER_TEST_FAIL_CALL', 'Process')
            $oldCount = [Environment]::GetEnvironmentVariable('SYP171_OBSERVER_TEST_CALL_COUNT', 'Process')
            $oldTransportFail = [Environment]::GetEnvironmentVariable('SYP171_OBSERVER_TEST_FAIL_TRANSPORT', 'Process')
            $transcriptPath = Join-Path $Fixture.Root 'observer-transcript.txt'
            $githubEnvPath = Join-Path $Fixture.Root 'github-env.txt'
            $githubOutputPath = Join-Path $Fixture.Root 'github-output.txt'
            [IO.File]::WriteAllText($githubEnvPath, 'ENV-FILE-MUST-STAY-UNCHANGED', [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($githubOutputPath, 'OUTPUT-FILE-MUST-STAY-UNCHANGED', [Text.UTF8Encoding]::new($false))
            $stepText = Get-CanonicalValidationObserverRunScript -WorkflowPath $WorkflowPath
            if ($FailCanonicalCall -gt 0) {
                $tokens = $null
                $parseErrors = $null
                $ast = [Management.Automation.Language.Parser]::ParseInput($stepText, [ref]$tokens, [ref]$parseErrors)
                $functionAst = @($ast.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                        $node.Name -ceq 'ConvertTo-ScannerEvidenceCanonicalJson'
                }, $true))
                if ($functionAst.Count -ne 1) { throw 'The test serializer seam could not locate exactly one canonicalizer.' }
                $definition = $functionAst[0].Extent
                $originalFunction = $definition.Text.Replace('ConvertTo-ScannerEvidenceCanonicalJson', 'ConvertTo-ScannerEvidenceCanonicalJsonOriginal')
                $wrapper = @'
        function ConvertTo-ScannerEvidenceCanonicalJson {
          param([AllowNull()] $Value)
          $callCount = [int]$env:SYP171_OBSERVER_TEST_CALL_COUNT + 1
          $env:SYP171_OBSERVER_TEST_CALL_COUNT = [string]$callCount
          if ($callCount -eq [int]$env:SYP171_OBSERVER_TEST_FAIL_CALL) { throw 'SYP171_PRIVATE_SERIALIZER_SENTINEL' }
          return ConvertTo-ScannerEvidenceCanonicalJsonOriginal -Value $Value
        }
'@
                $stepText = $stepText.Remove($definition.StartOffset, $definition.EndOffset - $definition.StartOffset).Insert(
                    $definition.StartOffset,
                    $originalFunction + "`n" + $wrapper
                )
            }
            if ($FailDiagnosticTransport) {
                $transportCall = "Write-Host ('STANDARD_STATIC_PROVIDER_DIAGNOSTIC|' + `$terminalJson)"
                $transportReplacement = @'
        if ($env:SYP171_OBSERVER_TEST_FAIL_TRANSPORT -eq '1') {
          $env:SYP171_OBSERVER_TEST_FAIL_TRANSPORT = '0'
          throw 'SYP171_PRIVATE_TRANSPORT_SENTINEL'
        }
        Write-Host ('STANDARD_STATIC_PROVIDER_DIAGNOSTIC|' + $terminalJson)
'@
                if ([regex]::Matches($stepText, [regex]::Escape($transportCall)).Count -ne 1) { throw 'The test transport seam could not locate exactly one terminal diagnostic write.' }
                $stepText = $stepText.Replace($transportCall, $transportReplacement.TrimEnd())
            }

            $transportFailSetting = if ($FailDiagnosticTransport) { '1' } else { '0' }
            [Environment]::SetEnvironmentVariable('RUNNER_TEMP', $Fixture.RunnerTemp, 'Process')
            [Environment]::SetEnvironmentVariable('GITHUB_SHA', $Fixture.SourceRevision, 'Process')
            [Environment]::SetEnvironmentVariable('GITHUB_ENV', $githubEnvPath, 'Process')
            [Environment]::SetEnvironmentVariable('GITHUB_OUTPUT', $githubOutputPath, 'Process')
            [Environment]::SetEnvironmentVariable('SYP171_OBSERVER_TEST_FAIL_CALL', [string]$FailCanonicalCall, 'Process')
            [Environment]::SetEnvironmentVariable('SYP171_OBSERVER_TEST_CALL_COUNT', '0', 'Process')
            [Environment]::SetEnvironmentVariable('SYP171_OBSERVER_TEST_FAIL_TRANSPORT', $transportFailSetting, 'Process')
            $invocationFailure = $false
            try {
                Start-Transcript -LiteralPath $transcriptPath -Force | Out-Null
                try { & ([scriptblock]::Create($stepText)) }
                catch { $invocationFailure = $true }
                finally { Stop-Transcript | Out-Null }
            }
            finally {
                [Environment]::SetEnvironmentVariable('RUNNER_TEMP', $oldRunnerTemp, 'Process')
                [Environment]::SetEnvironmentVariable('GITHUB_SHA', $oldGitHubSha, 'Process')
                [Environment]::SetEnvironmentVariable('GITHUB_ENV', $oldGitHubEnv, 'Process')
                [Environment]::SetEnvironmentVariable('GITHUB_OUTPUT', $oldGitHubOutput, 'Process')
                [Environment]::SetEnvironmentVariable('SYP171_OBSERVER_TEST_FAIL_CALL', $oldFail, 'Process')
                [Environment]::SetEnvironmentVariable('SYP171_OBSERVER_TEST_CALL_COUNT', $oldCount, 'Process')
                [Environment]::SetEnvironmentVariable('SYP171_OBSERVER_TEST_FAIL_TRANSPORT', $oldTransportFail, 'Process')
            }
            $transcript = Get-Content -LiteralPath $transcriptPath -Raw
            $providerChunks = @($transcript -split "`r?`n" | Where-Object { $_ -match 'STANDARD_STATIC_EVIDENCE_CHUNK\|provider\|' })
            $providerRecordLines = @($transcript -split "`r?`n" | Where-Object { $_ -match 'STANDARD_STATIC_PROVIDER_DIAGNOSTIC\|' })
            $captureStatusLines = @($transcript -split "`r?`n" | Where-Object { $_ -match 'STANDARD_STATIC_PROVIDER_CAPTURE_STATUS=' })
            $captureReasonLines = @($transcript -split "`r?`n" | Where-Object { $_ -match 'STANDARD_STATIC_PROVIDER_CAPTURE_REASON=' })
            $observerDiagnosticLines = @($transcript -split "`r?`n" | Where-Object {
                $_.StartsWith('STANDARD_STATIC_PROVIDER_DIAGNOSTIC|', [StringComparison]::Ordinal) -or
                    $_.StartsWith('STANDARD_STATIC_PROVIDER_CAPTURE_STATUS=', [StringComparison]::Ordinal) -or
                    $_.StartsWith('STANDARD_STATIC_PROVIDER_CAPTURE_REASON=', [StringComparison]::Ordinal) -or
                    $_.Contains('The provider report could not be retained by the diagnostic observer.')
            })
            $records = foreach ($line in $providerRecordLines) {
                $json = $line.Substring($line.IndexOf('STANDARD_STATIC_PROVIDER_DIAGNOSTIC|', [StringComparison]::Ordinal) + 'STANDARD_STATIC_PROVIDER_DIAGNOSTIC|'.Length)
                try { ConvertFrom-Json -InputObject $json -Depth 20 } catch { $null }
            }
            $diagnosticPayloadBytes = 0
            $diagnosticTransportBytes = 0
            foreach ($line in $providerRecordLines) {
                $separatorIndex = $line.IndexOf('STANDARD_STATIC_PROVIDER_DIAGNOSTIC|', [StringComparison]::Ordinal)
                $prefixLength = 'STANDARD_STATIC_PROVIDER_DIAGNOSTIC|'.Length
                $diagnosticPayloadBytes += [Text.UTF8Encoding]::new($false, $true).GetByteCount($line.Substring($separatorIndex + $prefixLength))
                $diagnosticTransportBytes += [Text.UTF8Encoding]::new($false, $true).GetByteCount($line.Substring($separatorIndex))
            }
            return [pscustomobject]@{
                TranscriptPath = $transcriptPath
                Transcript = $transcript
                ProviderChunks = $providerChunks
                ProviderRecordLines = $providerRecordLines
                ProviderRecords = @($records | Where-Object { $null -ne $_ })
                DiagnosticPayloadBytes = $diagnosticPayloadBytes
                DiagnosticTransportBytes = $diagnosticTransportBytes
                CaptureStatusLines = $captureStatusLines
                CaptureReasonLines = $captureReasonLines
                ObserverDiagnosticLines = $observerDiagnosticLines
                GitHubEnvContent = [IO.File]::ReadAllText($githubEnvPath)
                GitHubOutputContent = [IO.File]::ReadAllText($githubOutputPath)
                InvocationFailed = $invocationFailure
            }
        }

        function Remove-CanonicalValidationObserverFixture {
            param([Parameter(Mandatory)] $Fixture)
            $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Fixture.Root).Path)
            $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
            if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\', '/') -cne $tempRoot -or
                [IO.Path]::GetFileName($resolved) -cnotmatch '^syp171-observer-[0-9a-f]{32}$') {
                throw 'Unsafe canonical-observer test fixture cleanup target.'
            }
            if ($Fixture.ReparseProvider) {
                $pathComparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
                $linkPath = [IO.Path]::GetFullPath($Fixture.ProviderDirectoryPath)
                $fixturePrefix = $resolved.TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar
                if (-not $linkPath.StartsWith($fixturePrefix, $pathComparison)) {
                    throw 'Unsafe canonical-observer reparse link cleanup target.'
                }
                $linkItem = Get-Item -LiteralPath $linkPath -Force -ErrorAction SilentlyContinue
                if ($null -ne $linkItem) {
                    if (($linkItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                        throw 'Refusing to remove a provider path that is not a reparse point.'
                    }
                    $resolvedTarget = [IO.DirectoryInfo]::new($linkPath).ResolveLinkTarget($true)
                    $expectedTarget = [IO.Path]::GetFullPath($Fixture.OutsideProviderDirectoryPath)
                    if ($null -eq $resolvedTarget -or -not [string]::Equals(
                        [IO.Path]::GetFullPath($resolvedTarget.FullName),
                        $expectedTarget,
                        $pathComparison
                    )) {
                        throw 'Unsafe canonical-observer reparse target cleanup.'
                    }
                    Remove-Item -LiteralPath $linkPath -Force
                    if (Test-Path -LiteralPath $linkPath) { throw 'The canonical-observer reparse link could not be removed.' }
                }
                $targetPath = [IO.Path]::GetFullPath($Fixture.OutsideProviderDirectoryPath)
                $targetFile = [IO.Path]::GetFullPath($Fixture.OutsideProviderPath)
                if ([IO.Path]::GetDirectoryName($targetPath) -cne $resolved -or
                    [IO.Path]::GetFileName($targetPath) -cne 'outside-provider-directory' -or
                    [IO.Path]::GetDirectoryName($targetFile) -cne $targetPath -or
                    [IO.Path]::GetFileName($targetFile) -cne 'skillspector-manage-confluence-docs-as-code.json') {
                    throw 'Unsafe canonical-observer reparse target cleanup path.'
                }
                if (Test-Path -LiteralPath $targetFile -PathType Leaf) { Remove-Item -LiteralPath $targetFile -Force }
                if (Test-Path -LiteralPath $targetPath -PathType Container) { Remove-Item -LiteralPath $targetPath -Force }
            }
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }

        function Get-CanonicalValidationObserverPrivacyAssessment {
            param(
                [Parameter(Mandatory)][string] $Transcript,
                [string] $ExpectedInjectedRuntimeError
            )
            $privatePattern = 'SYP171_PRIVATE_SENTINEL_59b62|SYP171_PRIVATE_KEY_SENTINEL|SYP171_PRIVATE_SKILL_KEY|SYP171_PRIVATE_COMPLETENESS_KEY|SYP171_PRIVATE_DEEP_PROPERTY|SYP171_PRIVATE_NESTED_SENTINEL|SYP171_PRIVATE_ENUM_SENTINEL|SYP171_PRIVATE_TAINTED_LEDGER_MESSAGE|SYP171_PRIVATE_SERIALIZER_SENTINEL|::add-mask::'
            $lines = @($Transcript -split "`r?`n")
            $privateLines = @($lines | Where-Object { $_ -match $privatePattern })
            $injectedRuntimePattern = if ($ExpectedInjectedRuntimeError -ceq 'SYP171_PRIVATE_SERIALIZER_SENTINEL') {
                '^PS>TerminatingError\(\): "' + [regex]::Escape($ExpectedInjectedRuntimeError) + '"$'
            }
            else { $null }
            $existingStreamPrivateLines = @($privateLines | Where-Object {
                $_ -cmatch '^STANDARD_STATIC_EVIDENCE_CHUNK\|(?:stdout|stderr)\|[0-9]{6}\|'
            })
            $injectedRuntimeLines = if ($null -ne $injectedRuntimePattern) {
                @($privateLines | Where-Object { $_ -cmatch $injectedRuntimePattern })
            }
            else { @() }
            $unclassifiedPrivateLines = @($privateLines | Where-Object {
                $_ -cnotmatch '^STANDARD_STATIC_EVIDENCE_CHUNK\|(?:stdout|stderr)\|[0-9]{6}\|' -and
                    ($null -eq $injectedRuntimePattern -or $_ -cnotmatch $injectedRuntimePattern)
            })
            $observerDiagnosticLines = @($lines | Where-Object {
                $_.StartsWith('STANDARD_STATIC_PROVIDER_DIAGNOSTIC|', [StringComparison]::Ordinal) -or
                    $_.StartsWith('STANDARD_STATIC_PROVIDER_CAPTURE_STATUS=', [StringComparison]::Ordinal) -or
                    $_.StartsWith('STANDARD_STATIC_PROVIDER_CAPTURE_REASON=', [StringComparison]::Ordinal) -or
                    $_.Contains('The provider report could not be retained by the diagnostic observer.')
            })
            [pscustomobject]@{
                PrivateLines = $privateLines
                ExistingStreamPrivateLines = $existingStreamPrivateLines
                InjectedRuntimeLines = $injectedRuntimeLines
                UnclassifiedPrivateLines = $unclassifiedPrivateLines
                ObserverDiagnosticLines = $observerDiagnosticLines
            }
        }

        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:ValidatorPath = Join-Path $script:RepositoryRoot 'scripts/Validate.ps1'
        $script:Validator = Get-Content -LiteralPath $script:ValidatorPath -Raw
        $script:Adapter = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'config/standard-v1.json') -Raw |
            ConvertFrom-Json -Depth 20
        $script:GitPath = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path
    }

    # Scenario: The ordinary entry point is called on a non-Windows host.
    # Purpose: Retire the legacy Linux namespace/cgroup route before any source or candidate process starts.
    It 'UnitT05_RequiresWindowsBeforeOrdinaryValidationDispatch' {
        $sourceEntry = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Invoke-SourceConformance.ps1') -Raw
        $validatorPrelude = $script:Validator.Substring(0, $script:Validator.IndexOf('if ($SourceConformance'))
        $sourcePrelude = $sourceEntry.Substring(0, $sourceEntry.IndexOf('function Assert-ExactPropertySet'))
        $validatorPrelude | Should -Match 'if \(-not \$IsWindows\) \{ throw ''Standard v1 canonical validation requires Windows with PowerShell 7\.'' \}'
        $sourcePrelude | Should -Match 'if \(-not \$IsWindows\) \{ throw ''Standard v1 canonical validation requires Windows with PowerShell 7\.'' \}'
    }

    It 'UnitT06_DoesNotRequireRetiredWindowsPowerShell51Contract' {
        # Scenario: Source regression runs on the supported PowerShell 7 host.
        # Purpose: Keep the retired PS5.1 check out of the ordinary candidate gate.
        $sourceEntry = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Invoke-SourceConformance.ps1') -Raw
        $sourceEntry | Should -Not -Match '(?i)Get-Command powershell\.exe|windowsPowerShell51'
        $sourceEntry | Should -Match 'Pester repository regression did not complete successfully'
    }

    It 'UnitT10_PinsApprovedAuthorityAndExactArchiveBoundary' {
        # Scenario: The validator obtains the normative Standard v1 snapshot.
        # Purpose: Reject mutable branches, broad archive URLs, or an unbound authority.
        $script:Adapter.authority.commit | Should -Be '3d00939e76e8ae6108ff793ef7e6c41d94815ebc'
        $script:Adapter.authority.archiveUrl | Should -Match '/zip/[0-9a-f]{40}$'
        $script:Adapter.authority.archiveSha256 | Should -Be 'befc8c1395da90af7ecbcbf5b7036765bde4bea4aa84204315139ffa3037727f'
        $script:Adapter.authority.files.Count | Should -Be 34
        $script:Validator | Should -Match 'Artifacts root must be outside the candidate repository'
        $script:Validator | Should -Match 'baseCommit = \$resolvedBaseCommit'
    }

    It 'scans the complete candidate tree when comparison base is absent' {
        # Scenario: A push or manual run has no trusted event base.
        # Purpose: Check every committed candidate path instead of only HEAD's parent.
        $script:Validator | Should -Match 'emptyTreeObject = ''4b825dc642cb6eb9a060e54bf8d69288fbee4904'''
        $script:Validator | Should -Match ([regex]::Escape("'diff'") + '.*' + [regex]::Escape("'--check'") + '.*' + [regex]::Escape('$emptyTreeObject') + '.*' + [regex]::Escape("'HEAD'"))
        $script:Validator | Should -Not -Match 'diff-tree.*--root.*HEAD'
    }

    It 'UnitT20_BindsThePullRequestMergeRevisionAndComparisonBase' {
        # Scenario: GitHub validates the pull_request merge ref in a read-only job.
        # Purpose: Keep the checked-out revision, canonical report, and event base aligned.
        $workflow = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/validate.yml') -Raw
        $sourceEntry = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Invoke-SourceConformance.ps1') -Raw
        $workflow | Should -Match 'checkoutHead -cne \$env:GITHUB_SHA'
        $workflow | Should -Match 'PULL_REQUEST_BASE_SHA'
        $workflow | Should -Match 'scripts/Validate\.ps1 -SourceConformance.*-BaseCommit \$baseCommit'
        $workflow | Should -Match 'report\.candidate\.sourceRevision -ceq \$env:GITHUB_SHA'
        $sourceEntry | Should -Match 'merge-base --is-ancestor \$baseRevision \$candidateCommit'
        $sourceEntry | Should -Match 'diff --find-renames=100% --name-only "\$baseRevision\.\.\.\$candidateCommit"'
        $script:Validator | Should -Match '\[ValidateSet\('
        $script:Validator | Should -Match 'safe-full-tree-no-merge-base'
        $script:Validator | Should -Match 'baseCommitSource = \$resolvedBaseCommitSource'
        $script:Validator | Should -Match 'baseCommitInput = \$BaseCommitInput'
    }

    It 'UnitT21_RejectsAValidAncestorThatIsNotTheTrustedEventMergeBase' {
        # Scenario: The event base and candidate branch diverged, then the candidate gained a second commit.
        # Purpose: Bind trusted evidence to the actual unique merge-base instead of accepting any candidate ancestor.
        $tokens = $null
        $parseErrors = $null
        $validatorAst = [Management.Automation.Language.Parser]::ParseFile($script:ValidatorPath, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $definitions = @($validatorAst.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                        $node.Name -ceq 'Resolve-BaseCommitEvidence'
                }, $false))
        $definitions.Count | Should -Be 1
        . ([scriptblock]::Create($definitions[0].Extent.Text))

        $root = Join-Path $TestDrive 'merge-base-evidence-fixture'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $gitArguments = @('-c', "safe.directory=$root", '-c', "core.worktree=$root", '-C', $root)
        $invokeGit = {
            param([string[]] $Arguments)
            $output = @(& $script:GitPath @gitArguments @Arguments 2>&1)
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) { throw "Git test fixture command failed: $($Arguments -join ' ')`n$($output -join "`n")" }
            return $output
        }
        & $invokeGit @('init', '--quiet') | Out-Null
        & $invokeGit @('config', 'user.email', 'review@example.test') | Out-Null
        & $invokeGit @('config', 'user.name', 'Review Test') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'root.txt'), 'root')
        & $invokeGit @('add', '--', 'root.txt') | Out-Null
        & $invokeGit @('commit', '--quiet', '-m', 'root') | Out-Null
        $rootCommit = ([string]((& $invokeGit @('rev-parse', 'HEAD')) | Select-Object -First 1)).Trim()
        [IO.File]::WriteAllText((Join-Path $root 'event.txt'), 'event')
        & $invokeGit @('add', '--', 'event.txt') | Out-Null
        & $invokeGit @('commit', '--quiet', '-m', 'event') | Out-Null
        $eventBase = ([string]((& $invokeGit @('rev-parse', 'HEAD')) | Select-Object -First 1)).Trim()
        & $invokeGit @('checkout', '--quiet', '--detach', $rootCommit) | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'candidate-one.txt'), 'candidate-one')
        & $invokeGit @('add', '--', 'candidate-one.txt') | Out-Null
        & $invokeGit @('commit', '--quiet', '-m', 'candidate-one') | Out-Null
        $candidateAncestor = ([string]((& $invokeGit @('rev-parse', 'HEAD')) | Select-Object -First 1)).Trim()
        [IO.File]::WriteAllText((Join-Path $root 'candidate-two.txt'), 'candidate-two')
        & $invokeGit @('add', '--', 'candidate-two.txt') | Out-Null
        & $invokeGit @('commit', '--quiet', '-m', 'candidate-two') | Out-Null
        $candidateCommit = ([string]((& $invokeGit @('rev-parse', 'HEAD')) | Select-Object -First 1)).Trim()

        $trustedArguments = @{
            GitPath = $script:GitPath
            GitConfigArguments = @('-c', "safe.directory=$root", '-c', "core.worktree=$root")
            RepositoryRoot = $root
            CandidateCommit = $candidateCommit
            BaseCommitInput = $eventBase
            BaseCommitSource = 'trusted-event-merge-base'
        }
        {
            Resolve-BaseCommitEvidence @trustedArguments -BaseCommit $candidateAncestor
        } | Should -Throw '*does not match the actual unique merge-base*'

        $validEvidence = Resolve-BaseCommitEvidence @trustedArguments -BaseCommit $rootCommit
        $validEvidence.baseCommit | Should -Be $rootCommit
        $validEvidence.baseCommitInput | Should -Be $eventBase
        $validEvidence.baseCommitSource | Should -Be 'trusted-event-merge-base'

        {
            Resolve-BaseCommitEvidence @trustedArguments -BaseCommit '' -BaseCommitInput $eventBase -BaseCommitSource 'safe-full-tree-no-merge-base'
        } | Should -Throw '*distinct merge-base*'
        {
            Resolve-BaseCommitEvidence @trustedArguments -BaseCommit '' -BaseCommitInput $eventBase -BaseCommitSource 'safe-full-tree-invalid-event-range'
        } | Should -Throw '*non-full event input*'

        $invalidEventEvidence = Resolve-BaseCommitEvidence @trustedArguments -BaseCommit '' -BaseCommitInput 'invalid-event-base' -BaseCommitSource 'safe-full-tree-invalid-event-range'
        $invalidEventEvidence.baseCommit | Should -Be ''
        $invalidEventEvidence.baseCommitInput | Should -Be 'invalid-event-base'
        $invalidEventEvidence.baseCommitSource | Should -Be 'safe-full-tree-invalid-event-range'

        & $invokeGit @('checkout', '--quiet', '--orphan', 'unrelated-candidate') | Out-Null
        Get-ChildItem -LiteralPath $root -Force |
            Where-Object { $_.Name -cne '.git' } |
            Remove-Item -Recurse -Force
        [IO.File]::WriteAllText((Join-Path $root 'unrelated.txt'), 'unrelated')
        & $invokeGit @('add', '--', 'unrelated.txt') | Out-Null
        & $invokeGit @('commit', '--quiet', '-m', 'unrelated') | Out-Null
        $unrelatedCandidate = ([string]((& $invokeGit @('rev-parse', 'HEAD')) | Select-Object -First 1)).Trim()
        $noMergeEvidence = Resolve-BaseCommitEvidence `
            -GitPath $script:GitPath `
            -GitConfigArguments @('-c', "safe.directory=$root", '-c', "core.worktree=$root") `
            -RepositoryRoot $root `
            -CandidateCommit $unrelatedCandidate `
            -BaseCommit '' `
            -BaseCommitInput $eventBase `
            -BaseCommitSource 'safe-full-tree-no-merge-base'
        $noMergeEvidence.baseCommit | Should -Be ''
        $noMergeEvidence.baseCommitInput | Should -Be $eventBase
        $noMergeEvidence.baseCommitSource | Should -Be 'safe-full-tree-no-merge-base'

        {
            Resolve-BaseCommitEvidence @trustedArguments -BaseCommit '' -BaseCommitSource 'trusted-event-merge-base'
        } | Should -Throw '*requires a distinct immutable comparison base*'
        {
            Resolve-BaseCommitEvidence @trustedArguments -BaseCommit '' -BaseCommitInput $eventBase -BaseCommitSource 'safe-full-tree-no-event-base'
        } | Should -Throw '*must be empty*'
        {
            Resolve-BaseCommitEvidence @trustedArguments -BaseCommit '' -BaseCommitInput 'invalid-event-base' -BaseCommitSource 'safe-full-tree-no-merge-base'
        } | Should -Throw '*must be one lowercase full commit SHA*'
        $safeEvidence = Resolve-BaseCommitEvidence @trustedArguments -BaseCommit '' -BaseCommitSource 'safe-full-tree-no-event-base' -BaseCommitInput ''
        $safeEvidence.baseCommit | Should -Be ''
        $safeEvidence.baseCommitSource | Should -Be 'safe-full-tree-no-event-base'

        $implicitSafeEvidence = Resolve-BaseCommitEvidence `
            -GitPath $script:GitPath `
            -GitConfigArguments @('-c', "safe.directory=$root", '-c', "core.worktree=$root") `
            -RepositoryRoot $root `
            -CandidateCommit $candidateCommit `
            -BaseCommitSource 'caller-supplied'
        $implicitSafeEvidence.baseCommit | Should -Be ''
        $implicitSafeEvidence.baseCommitInput | Should -Be ''
        $implicitSafeEvidence.baseCommitSource | Should -Be 'safe-full-tree-no-supplied-base'
    }

    # Scenario: a pre-push caller has several pending commits and omits the comparison base.
    # Purpose: Reject a one-parent comparison that would omit earlier pending source changes.
    It 'UnitT22_RequiresExplicitPrePushBaseForTheCompletePendingRange' {
        $sourcePath = Join-Path $script:RepositoryRoot 'scripts/Invoke-SourceConformance.ps1'
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $definition = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Resolve-SourceComparisonBaseInput'
        }, $false))
        $definition.Count | Should -Be 1
        . ([scriptblock]::Create($definition[0].Extent.Text))
        { Resolve-SourceComparisonBaseInput -BaseCommit '' -EventName 'pre-push' } |
            Should -Throw '*explicit base revision*'
        Resolve-SourceComparisonBaseInput -BaseCommit ('a' * 40) -EventName 'pre-push' |
            Should -Be ('a' * 40)
        Resolve-SourceComparisonBaseInput -BaseCommit '' -EventName 'local' |
            Should -Be 'HEAD^'
        (Get-Content -LiteralPath $sourcePath -Raw) |
            Should -Match 'Resolve-SourceComparisonBaseInput -BaseCommit \$BaseCommit -EventName \$eventName'
    }

    It 'uses isolated receipts and candidate-bound tool identities' {
        # Scenario: The canonical gate resolves its external toolchain for one run.
        # Purpose: Prevent persistent installs or unbound tool output from entering release evidence.
        $script:Validator | Should -Match ([regex]::Escape("Assert-ExternalReceiptFile -Receipt `$receipts.'skill-tools' -PathProperty 'nodePath'"))
        $script:Validator | Should -Match ([regex]::Escape("Assert-ReceiptFile -Receipt `$receipts.'skill-tools' -PathProperty 'entryPointPath'"))
        $script:Validator | Should -Match "'skillspector' = 'NVIDIA/SkillSpector'"
        $script:Validator | Should -Match "'skill-validator' = 'github.com/agent-ecosystem/skill-validator/cmd/skill-validator'"
        $script:Validator | Should -Match "'skill-tools' = 'npm:skill-tools'"
    }

    It 'UnitT32_CompletesSkillToolsPackageCheckBeforeStaticScanning' {
        # Scenario: The canonical adapter schedules the required formal tools.
        # Purpose: Enforce authority section 8.3 package validation before Static Scan.
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:ValidatorPath, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $calls = @($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Invoke-NativeChecked'
        }, $true))
        $packageCheck = @($calls | Where-Object { $_.Extent.Text.Contains('$skillToolsEntryPoint') -and $_.Extent.Text.Contains("'check'") })
        $staticScan = @($calls | Where-Object { $_.Extent.Text.Contains("'--no-llm'") })
        $packageCheck.Count | Should -Be 1
        $staticScan.Count | Should -Be 1
        $packageCheck[0].Extent.StartOffset | Should -BeLessThan $staticScan[0].Extent.StartOffset
    }

    # Scenario: A central semantic trigger is true or false with no opt-in switch.
    # Purpose: Execute required semantic review whenever the authority requires it.
    It 'UnitT35_UsesTheCentralSemanticTriggerWithoutAnOptInSwitch' -ForEach @(
        @{ Trigger = $true },
        @{ Trigger = $false }
    ) {
        $parseErrors = $null
        $tokens = $null
        $validatorAst = [Management.Automation.Language.Parser]::ParseFile($script:ValidatorPath, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $assignments = @($validatorAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -ceq '$semanticTriggered'
        }, $true))
        $assignments.Count | Should -Be 1
        $result = & {
            param($assignmentText, $triggerValue)
            $semanticTriggerCandidate = $triggerValue
            $EnableSemanticScan = $false
            . ([scriptblock]::Create($assignmentText))
            return $semanticTriggered
        } $assignments[0].Extent.Text $Trigger
        $result | Should -Be $Trigger
    }

    It 'UnitT40_KeepsValidationStageOrderingFailClosed' {
        $tokens = $null
        $parseErrors = $null
        $validatorAst = [Management.Automation.Language.Parser]::ParseFile(
            $script:ValidatorPath,
            [ref]$tokens,
            [ref]$parseErrors
        )
        @($parseErrors).Count | Should -Be 0
        $semanticAssignments = @($validatorAst.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Left.Extent.Text -ceq '$semanticTriggered'
                }, $true))
        $semanticAssignments.Count | Should -Be 1
        $semanticAssignments[0].Right.Extent.Text.Trim() | Should -Be '$semanticTriggerCandidate'
        $script:Validator | Should -Not -Match '\[switch\]\s+\$EnableSemanticScan'

        $script:Validator | Should -Match 'Test-SecurityRelevantSkillChange'
        $script:Validator | Should -Match '\$staticFindingCount -gt 0'
        $script:Validator | Should -Match 'Triggered SkillSpector semantic scan did not complete'
        $script:Validator | Should -Match 'repository-validation-post-pester'
        $script:Validator | Should -Match 'Invoke-ProtectedPesterRunspace'
        $script:Validator | Should -Match 'CreateOutOfProcessRunspace'
        $script:Validator | Should -Match '\$trustedPesterSupervisorMarker'
        $script:Validator | Should -Match '\$completionAttestationNonce'
        $script:Validator | Should -Match "completionAttestation = 'trusted-parent-post-exit'"
        $script:Validator | Should -Not -Match 'NamedPipeServerStream|NamedPipeClientStream|CompletionPipeName|CompletionToken|workerResultMarker'
        $script:Validator | Should -Match "ValidateSet\('Offline', 'TrustedSemantic'\)"
        $script:Validator | Should -Match '\[string\] \$NetworkProfile = ''Offline'''
        $script:Validator | Should -Match '-NetworkProfile TrustedSemantic'
        $script:Validator | Should -Match 'IsolateRunnerCommandFiles'
        $script:Validator | Should -Match 'TerminateProcessTree'
        $script:Validator | Should -Match 'ProtectRunnerCommandFiles'
        $script:Validator | Should -Match 'function New-ContainedProcessEnvironment'
        $script:Validator | Should -Match 'function Protect-ProcessCredentialEnvironment'
        $script:Validator | Should -Match 'SemanticCredentialNames'
        $script:Validator | Should -Match 'AdditionalEnvironmentVariables'
        $script:Validator | Should -Match 'EnvironmentVariables\.Clear\(\)'
        $script:Validator | Should -Match 'ACTIONS_RUNTIME_TOKEN'
        $script:Validator | Should -Match 'Assert-RunnerCommandFilesUnchanged'
        $script:Validator | Should -Match 'standard_v1_evidence_sha256'
        $script:Validator | Should -Not -Match 'pesterResultPath'
        $script:Validator | Should -Not -Match ([regex]::Escape("'-OutputPath', `$pesterResultPath"))
        $script:Validator | Should -Match 'postPesterCandidateCommit'
        $script:Validator | Should -Match 'postPesterTree'
        $script:Validator | Should -Match 'prePesterGitIndexSha256'
        $script:Validator | Should -Match 'Get-RepositoryRawSnapshot'
        $script:Validator | Should -Match 'Assert-RepositoryRawSnapshotUnchanged'
        $script:Validator | Should -Match 'postPesterRepositoryRawSnapshot'
        $script:Validator | Should -Match 'SkillSpector semantic scanner'
        $script:Validator | Should -Match 'Assert-ReceiptFile -Receipt \$receipts\.skillspector'
        $script:Validator | Should -Match 'Assert-ReceiptInstalledClosure'
        $script:Validator | Should -Match 'installedClosureSha256'
        $script:Validator | Should -Match 'installed closure contains a reparse-backed entry'
        $script:Validator | Should -Match 'Get-ChildItem -LiteralPath \$root -Recurse -Force'
        $script:Validator | Should -Match 'GIT_CONFIG_NOSYSTEM'
        $script:Validator | Should -Match 'core\.hooksPath'
        $script:Validator | Should -Match '\$repositoryValidatorPath'
        $script:Validator | Should -Match 'pesterRunnerPath'
        $script:Validator | Should -Match 'Invoke-TrustedPowerShellProcess -Command \$powerShellPath'
        $script:Validator | Should -Match "'-NoProfile'"
        $script:Validator | Should -Match "'route'"
        $script:Validator | Should -Match 'skill-tools route did not return exactly one result'
        $script:Validator | Should -Match '\$routeResults = @\(Read-JsonFile'
        $script:Validator | Should -Not -Match '\$routeResults -isnot \[array\]'
        $script:Validator | Should -Not -Match 'semantic.*continue|continue.*semantic'
        $postPesterInventoryIndex = $script:Validator.IndexOf('$postPesterRepositoryRawSnapshot')
        $semanticScanIndex = $script:Validator.IndexOf('Post-Pester SkillSpector semantic scan')
        $postPesterInventoryIndex | Should -BeGreaterThan -1
        $semanticAssignments[0].Extent.StartOffset | Should -BeGreaterThan $postPesterInventoryIndex
        $semanticScanIndex | Should -BeGreaterThan $postPesterInventoryIndex
    }

    It 'UnitT50_RequiresExplicitCredentialsAndCompleteValidation' {
        # Scenario: GitHub Actions invokes the same canonical validator as a local caller.
        # Purpose: Keep credentials explicit while preserving mandatory semantic and test gates.
        $workflow = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/validate.yml') -Raw
        $workflow | Should -Not -Match 'EnableSemanticScan'
        $script:Validator | Should -Match '\[string\[\]\] \$SemanticCredentialNames = @\(\)'
        $script:Validator | Should -Not -Match '\[switch\]\s+\$EnableSemanticScan'
        $script:Validator | Should -Match 'SkippedCount -ne 0'
        $script:Validator | Should -Match 'security-preflight\.json'
        $script:Validator | Should -Match 'candidate-executing repository tests are not started'
    }

    It 'fails closed when base-commit evidence is absent for a security-relevant change' {
        # Scenario: A caller omits BaseCommit while validating a candidate that may change a Skill.
        # Purpose: Prevent conditional semantic scanning from being skipped by an incomplete invocation.
        $detector = $script:Validator.Substring($script:Validator.IndexOf('function Test-SecurityRelevantSkillChange'))
        $detector | Should -Match 'IsNullOrWhiteSpace\(\$BaseCommit\)'
    }

    It 'preserves the Atlassian access-path and credential boundaries' {
        # Scenario: A user selects a connector or REST path and validates credentials.
        # Purpose: Keep migration focused on contract hardening without weakening the product Skill rules.
        $jiraSkill = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'skills/work-with-jira/SKILL.md') -Raw
        $jiraSkill | Should -Match 'After resolving the target site, use only the access path selected by the user'
        $jiraSkill | Should -Match 'Never print, log, persist'
        $jiraSkill | Should -Match 'JIRA_API_BASE_URL'
    }

    It 'keeps Jira Web route decisions and projection boundaries source-owned' {
        # Scenario: A projected Skill runs with or without a connector and receives read or write intent.
        # Purpose: Verify the declared source contract blocks site, permission, authorization, and readback gaps without switching paths.
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
        # Scenario: A writable installed Skill tree redirects a helper through a symlink.
        # Purpose: Keep hidden credentials inside the host-resolved helper root.
        foreach ($skillId in @('configure-jira-api-access', 'configure-bitbucket-api-access', 'configure-confluence-api-access')) {
            $skill = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot "skills/$skillId/SKILL.md") -Raw
            $skill | Should -Match 'scripts/Configure-'
            $skill | Should -Match 'scripts/Test-'
            if ($skillId -ceq 'configure-jira-api-access') {
                $skill | Should -Match 'Assert-NoReparseAncestors'
            }
            else {
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

    It 'UnitT70_PreservesNestedSecurityFindingIdentityInSummary' {
        # Scenario: SkillSpector returns rule identity inside its nested issue object.
        # Purpose: Keep the final security summary traceable without exposing finding text or secrets.
        $tokens = $null
        $parseErrors = $null
        $validatorAst = [Management.Automation.Language.Parser]::ParseFile($script:ValidatorPath, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $definitions = @($validatorAst.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                        $node.Name -ceq 'Get-SanitizedSecurityFindingValue'
                }, $false))
        $definitions.Count | Should -Be 1
        . ([scriptblock]::Create($definitions[0].Extent.Text))

        $finding = [pscustomobject][ordered]@{
            stage = 'skillspector-static'
            skillId = 'configure-jira-api-access'
            issue = [pscustomobject][ordered]@{
                id = 'nested-rule-identity'
                finding_id = 'nested-finding-identity'
            }
        }
        Get-SanitizedSecurityFindingValue -Finding $finding -Names @('ruleId', 'rule', 'check', 'id') |
            Should -Be 'nested-rule-identity'
        Get-SanitizedSecurityFindingValue -Finding $finding -Names @('reportId', 'report', 'path', 'finding_id') |
            Should -Be 'nested-finding-identity'
    }

    # Scenario: The privacy helper sees the one expected serializer-failure runtime record.
    # Purpose: Allow only the exact injected PowerShell transcript line when its test context is explicitly named.
    It 'UnitT75_ClassifiesOnlyTheExactKnownInjectedSerializerRuntimeLine' {
        $expected = 'SYP171_PRIVATE_SERIALIZER_SENTINEL'
        $runtimeLine = 'PS>TerminatingError(): "' + $expected + '"'
        $withContext = Get-CanonicalValidationObserverPrivacyAssessment -Transcript $runtimeLine -ExpectedInjectedRuntimeError $expected
        $withContext.PrivateLines.Count | Should -Be 1
        $withContext.InjectedRuntimeLines.Count | Should -Be 1
        $withContext.UnclassifiedPrivateLines | Should -BeNullOrEmpty

        $withoutContext = Get-CanonicalValidationObserverPrivacyAssessment -Transcript $runtimeLine
        $withoutContext.PrivateLines.Count | Should -Be 1
        $withoutContext.InjectedRuntimeLines.Count | Should -Be 0
        $withoutContext.UnclassifiedPrivateLines.Count | Should -Be 1
    }

    # Scenario: Similar text appears as raw host output, a warning, or a malformed runtime record.
    # Purpose: Keep every serializer-sentinel spelling private and unclassified unless the exact injected record matches.
    It 'UnitT76_RejectsUntrustedSerializerSentinelOutputVariants' {
        $expected = 'SYP171_PRIVATE_SERIALIZER_SENTINEL'
        $runtimeLine = 'PS>TerminatingError(): "' + $expected + '"'
        $untrustedLines = @(
            $expected,
            ('HOST OUTPUT: ' + $expected),
            ('WARNING: ' + $expected),
            ('prefix ' + $runtimeLine),
            ($runtimeLine + ' suffix'),
            $runtimeLine.ToLowerInvariant(),
            ('PS>TerminatingError(): "' + $expected + '_OTHER"')
        )

        foreach ($line in $untrustedLines) {
            $assessment = Get-CanonicalValidationObserverPrivacyAssessment -Transcript $line -ExpectedInjectedRuntimeError $expected
            $assessment.PrivateLines.Count | Should -Be 1
            $assessment.InjectedRuntimeLines.Count | Should -Be 0
            $assessment.UnclassifiedPrivateLines.Count | Should -Be 1
        }
    }
    # Scenario: A locally extracted Stage 4 observer sees a verified provider report that cannot be canonicalized.
    # Purpose: Preserve a typed failure phase and terminal diagnostic without printing the provider JSON.
    It 'InterT80_ReportsProviderCanonicalizationFailureWithoutRawProvider' {
        $fixture = New-CanonicalValidationObserverFixture -RepositoryRoot $script:RepositoryRoot
        try {
            $result = Invoke-CanonicalValidationObserverFixture -Fixture $fixture -WorkflowPath (Join-Path $script:RepositoryRoot '.github/workflows/validate.yml') -FailCanonicalCall 1
            $result.InvocationFailed | Should -BeFalse
            $result.ProviderRecords.Count | Should -Be 2 -Because 'The observer emits a pre-record and terminal record around provider canonicalization.'
            $result.ProviderRecords[0].recordKind | Should -Be 'pre'
            $terminal = $result.ProviderRecords[1]
            $terminal.phase | Should -Be 'provider-canonicalization'
            $terminal.phaseState.providerCanonicalization.started | Should -BeTrue
            $terminal.phaseState.providerCanonicalization.completed | Should -BeFalse
            $terminal.comparison.state | Should -Be 'not-run'
            $terminal.originalProviderRetained | Should -BeFalse
            $terminal.diagnosticOnly | Should -BeTrue
            $privacy = Get-CanonicalValidationObserverPrivacyAssessment -Transcript $result.Transcript -ExpectedInjectedRuntimeError 'SYP171_PRIVATE_SERIALIZER_SENTINEL'
            ($privacy.ObserverDiagnosticLines -join "`n") | Should -Not -Match 'SYP171_PRIVATE_SERIALIZER_SENTINEL'
            $privacy.UnclassifiedPrivateLines | Should -BeNullOrEmpty
            $result.ProviderChunks.Count | Should -Be 0
        }
        finally { Remove-CanonicalValidationObserverFixture -Fixture $fixture }
    }

    # Scenario: Provider and verified stderr canonicalize successfully but report different known completeness counts.
    # Purpose: Distinguish a completed unequal comparison from either serializer failure without preserving raw values.
    It 'InterT81_ReportsCompletedCompletenessMismatchWithoutRawProvider' {
        $fixture = New-CanonicalValidationObserverFixture -RepositoryRoot $script:RepositoryRoot -Mismatch
        try {
            $result = Invoke-CanonicalValidationObserverFixture -Fixture $fixture -WorkflowPath (Join-Path $script:RepositoryRoot '.github/workflows/validate.yml')
            $result.InvocationFailed | Should -BeFalse
            $result.ProviderRecords.Count | Should -Be 2 -Because 'The observer emits a pre-record and terminal record after the existing whole-object comparison.'
            $terminal = $result.ProviderRecords[1]
            $terminal.phase | Should -Be 'comparison'
            $terminal.phaseState.providerCanonicalization.completed | Should -BeTrue
            $terminal.phaseState.stderrCanonicalization.completed | Should -BeTrue
            $terminal.phaseState.comparison.started | Should -BeTrue
            $terminal.phaseState.comparison.completed | Should -BeTrue
            $terminal.comparison.state | Should -Be 'mismatch'
            @($terminal.comparison.knownFieldDifferences) | Should -Contain 'scanned_components'
            $terminal.originalProviderRetained | Should -BeFalse
            $result.ProviderChunks.Count | Should -Be 0
        }
        finally { Remove-CanonicalValidationObserverFixture -Fixture $fixture }
    }

    # Scenario: A matching report carries a synthetic secret sentinel, a workflow command, and an untrusted path.
    # Purpose: Ensure even the successful provider observation uses only the allowlisted typed derivative.
    It 'InterT82_MatchingProviderNeverEmitsRawOrUntrustedProviderFields' {
        $fixture = New-CanonicalValidationObserverFixture -RepositoryRoot $script:RepositoryRoot -IncludeSensitiveSentinel -NestedUntrustedValue
        try {
            $result = Invoke-CanonicalValidationObserverFixture -Fixture $fixture -WorkflowPath (Join-Path $script:RepositoryRoot '.github/workflows/validate.yml')
            $result.InvocationFailed | Should -BeFalse
            $result.ProviderChunks.Count | Should -Be 0 -Because 'The provider JSON is never transported as raw numbered chunks.'
            $result.ProviderRecords.Count | Should -Be 2
            $providerOutput = $result.ProviderRecords | ConvertTo-Json -Compress -Depth 20
            $providerOutput | Should -Not -Match 'SYP171_PRIVATE_SENTINEL_59b62|::add-mask::|diagnostic_probe|workflow_command|unknown_path|skill\.source'
            $privacy = Get-CanonicalValidationObserverPrivacyAssessment -Transcript $result.Transcript
            $privatePattern = 'SYP171_PRIVATE_SENTINEL_59b62|SYP171_PRIVATE_KEY_SENTINEL|SYP171_PRIVATE_SKILL_KEY|SYP171_PRIVATE_COMPLETENESS_KEY|SYP171_PRIVATE_DEEP_PROPERTY|SYP171_PRIVATE_NESTED_SENTINEL|::add-mask::'
            ($privacy.ObserverDiagnosticLines -join "`n") | Should -Not -Match $privatePattern
            $privacy.ExistingStreamPrivateLines.Count | Should -BeGreaterThan 0 -Because 'This task keeps the existing captured stderr stream unchanged and does not certify it as private.'
            ($privacy.ExistingStreamPrivateLines -join "`n") | Should -Match 'SYP171_PRIVATE_SENTINEL_59b62|::add-mask::'
            $privacy.UnclassifiedPrivateLines | Should -BeNullOrEmpty -Because 'Only the existing numbered stderr chunk may carry these synthetic fixture sentinels.'
            $result.ProviderRecords[1].comparison.state | Should -Be 'equal'
            $result.ProviderRecords[1].originalProviderRetained | Should -BeFalse
            $result.ProviderRecords[1].diagnosticOnly | Should -BeTrue
            $result.ProviderRecords[1].providerUnknownProperties.count | Should -Be 5
            $result.ProviderRecords[1].providerUnknownProperties.nameHashesSha256 | Should -Match '^[0-9a-f]{64}$'
            $result.ProviderRecords[1].skillUnknownProperties.count | Should -Be 1
            $result.ProviderRecords[1].projection.provider.unknownProperties.count | Should -Be 1
            $result.ProviderRecords[1].comparison.unknownPropertiesDiffer | Should -BeFalse
            ($result.DiagnosticTransportBytes -lt 131073) | Should -BeTrue
            $result.GitHubEnvContent | Should -Be 'ENV-FILE-MUST-STAY-UNCHANGED'
            $result.GitHubOutputContent | Should -Be 'OUTPUT-FILE-MUST-STAY-UNCHANGED'
        }
        finally { Remove-CanonicalValidationObserverFixture -Fixture $fixture }
    }

    # Scenario: Verified provider completeness canonicalizes, then verified stderr completeness serialization fails.
    # Purpose: Identify the failing side and preserve an explicit not-run comparison without exposing the exception text.
    It 'InterT83_ReportsStderrCanonicalizationFailureWithoutRawProvider' {
        $fixture = New-CanonicalValidationObserverFixture -RepositoryRoot $script:RepositoryRoot
        try {
            $result = Invoke-CanonicalValidationObserverFixture -Fixture $fixture -WorkflowPath (Join-Path $script:RepositoryRoot '.github/workflows/validate.yml') -FailCanonicalCall 2
            $result.InvocationFailed | Should -BeFalse
            $result.ProviderRecords.Count | Should -Be 2
            $terminal = $result.ProviderRecords[1]
            $terminal.phase | Should -Be 'stderr-canonicalization'
            $terminal.phaseState.providerCanonicalization.started | Should -BeTrue
            $terminal.phaseState.providerCanonicalization.completed | Should -BeTrue
            $terminal.phaseState.stderrCanonicalization.started | Should -BeTrue
            $terminal.phaseState.stderrCanonicalization.completed | Should -BeFalse
            $terminal.phaseState.comparison.started | Should -BeFalse
            $terminal.comparison.state | Should -Be 'not-run'
            $terminal.errorClass | Should -Be 'runtime'
            $terminal.originalProviderRetained | Should -BeFalse
            $privacy = Get-CanonicalValidationObserverPrivacyAssessment -Transcript $result.Transcript -ExpectedInjectedRuntimeError 'SYP171_PRIVATE_SERIALIZER_SENTINEL'
            ($privacy.ObserverDiagnosticLines -join "`n") | Should -Not -Match 'SYP171_PRIVATE_SERIALIZER_SENTINEL'
            $privacy.UnclassifiedPrivateLines | Should -BeNullOrEmpty
        }
        finally { Remove-CanonicalValidationObserverFixture -Fixture $fixture }
    }

    # Scenario: The final terminal line fails once after the pre-record was written.
    # Purpose: Emit an incomplete fallback and make the observer's inability to complete transport explicit.
    It 'InterT84_FailedTerminalTransportEmitsIncompleteFallback' {
        $fixture = New-CanonicalValidationObserverFixture -RepositoryRoot $script:RepositoryRoot
        try {
            $result = Invoke-CanonicalValidationObserverFixture -Fixture $fixture -WorkflowPath (Join-Path $script:RepositoryRoot '.github/workflows/validate.yml') -FailDiagnosticTransport
            $result.InvocationFailed | Should -BeFalse
            $result.ProviderRecords.Count | Should -Be 2
            $terminal = $result.ProviderRecords[1]
            $terminal.phase | Should -Be 'derived-output'
            $terminal.phaseState.derivedOutput.started | Should -BeTrue
            $terminal.phaseState.derivedOutput.completed | Should -BeFalse
            $terminal.projection.state | Should -Be 'limited'
            $terminal.projection.limit | Should -Be 'output-incomplete'
            $terminal.outputStatus | Should -Be 'output-incomplete'
            $result.CaptureReasonLines -join "`n" | Should -Match 'provider-output-incomplete'
            $result.Transcript | Should -Not -Match 'SYP171_PRIVATE_TRANSPORT_SENTINEL'
            ($result.ObserverDiagnosticLines -join "`n") | Should -Not -Match 'SYP171_PRIVATE_TRANSPORT_SENTINEL'
            $result.DiagnosticTransportBytes -le 131072 | Should -BeTrue
        }
        finally { Remove-CanonicalValidationObserverFixture -Fixture $fixture }
    }

    # Scenario: Known fields have wrong types, an unknown enum, an untrusted path, and an invalid line span.
    # Purpose: Preserve null/type information while redacting unverified values and retaining only candidate-bound spans.
    It 'InterT85_RedactsWrongTypedUnknownAndInvalidSpanValues' {
        $fixture = New-CanonicalValidationObserverFixture -RepositoryRoot $script:RepositoryRoot -TaintedFields
        try {
            $result = Invoke-CanonicalValidationObserverFixture -Fixture $fixture -WorkflowPath (Join-Path $script:RepositoryRoot '.github/workflows/validate.yml')
            $result.ProviderRecords.Count | Should -Be 2
            $terminal = $result.ProviderRecords[1]
            $terminal.comparison.state | Should -Be 'equal'
            $fields = $terminal.projection.provider.fields
            $fields.coverage_percent.type | Should -Be 'string'
            $fields.coverage_percent.valueState | Should -Be 'redacted'
            $null -eq $fields.coverage_percent.value | Should -BeTrue
            $fields.scanned_components.type | Should -Be 'null'
            $fields.scanned_components.valueState | Should -Be 'null'
            $fields.scanned_components.value | Should -BeNullOrEmpty
            $fields.status.valueState | Should -Be 'redacted'
            $null -eq $fields.status.value | Should -BeTrue
            $ledgerRows = @($fields.ledger_exceptions.items)
            $ledgerRows.Count | Should -Be 2
            $ledgerRows[0].members.path.membership | Should -Be 'verified'
            $ledgerRows[0].members.start_line.limit | Should -Be 'invalid-span'
            $ledgerRows[0].members.end_line.limit | Should -Be 'invalid-span'
            $null -eq $ledgerRows[0].members.start_line.valueToken | Should -BeTrue
            $null -eq $ledgerRows[0].members.end_line.valueToken | Should -BeTrue
            $ledgerRows[1].members.path.type | Should -Be 'string'
            $ledgerRows[1].members.path.valueState | Should -Be 'redacted'
            $ledgerRows[1].members.path.membership | Should -Be 'unverified'
            $null -eq $ledgerRows[1].members.path.value | Should -BeTrue
            $reference = $fields.references.items[0].members
            $reference.line.valueState | Should -Be 'redacted'
            $reference.target_path.valueState | Should -Be 'redacted'
            $null -eq $reference.target_path.value | Should -BeTrue
            $privacy = Get-CanonicalValidationObserverPrivacyAssessment -Transcript $result.Transcript
            $taintedPattern = 'SYP171_PRIVATE_SENTINEL_59b62|SYP171_PRIVATE_ENUM_SENTINEL|SYP171_PRIVATE_TAINTED_LEDGER_MESSAGE'
            ($privacy.ObserverDiagnosticLines -join "`n") | Should -Not -Match $taintedPattern
            $privacy.ExistingStreamPrivateLines.Count | Should -BeGreaterThan 0 -Because 'The unchanged stderr chunk contains synthetic tainted input used by this projection test.'
            ($privacy.ExistingStreamPrivateLines -join "`n") | Should -Match 'SYP171_PRIVATE_SENTINEL_59b62|SYP171_PRIVATE_ENUM_SENTINEL'
            $privacy.UnclassifiedPrivateLines | Should -BeNullOrEmpty -Because 'No new provider diagnostic output may contain tainted fixture values.'
        }
        finally { Remove-CanonicalValidationObserverFixture -Fixture $fixture }
    }

    # Scenario: A valid provider report occupies exactly the existing 2 MiB snapshot limit.
    # Purpose: Keep inclusive size-bound behavior and the immutable raw-byte length visible in the safe pre-record.
    It 'InterT86_AcceptsProviderAtExactlyTwoMiB' {
        $fixture = New-CanonicalValidationObserverFixture -RepositoryRoot $script:RepositoryRoot -ProviderByteCount 2097152
        try {
            $result = Invoke-CanonicalValidationObserverFixture -Fixture $fixture -WorkflowPath (Join-Path $script:RepositoryRoot '.github/workflows/validate.yml')
            $result.InvocationFailed | Should -BeFalse
            $result.ProviderRecords.Count | Should -Be 2
            $result.ProviderRecords[0].recordKind | Should -Be 'pre'
            $result.ProviderRecords[0].providerSnapshot.utf8Bytes | Should -Be 2097152
            $result.ProviderRecords[1].providerSnapshot.utf8Bytes | Should -Be 2097152
            $result.ProviderRecords[1].comparison.state | Should -Be 'equal'
            $result.ProviderRecords[1].originalProviderRetained | Should -BeFalse
        }
        finally { Remove-CanonicalValidationObserverFixture -Fixture $fixture }
    }

    # Scenario: A provider report exceeds the immutable snapshot limit by one byte.
    # Purpose: Reject it before writing any provider-derived digest or projection.
    It 'InterT87_RejectsProviderOneByteOverTwoMiB' {
        $fixture = New-CanonicalValidationObserverFixture -RepositoryRoot $script:RepositoryRoot -ProviderByteCount 2097153
        try {
            $result = Invoke-CanonicalValidationObserverFixture -Fixture $fixture -WorkflowPath (Join-Path $script:RepositoryRoot '.github/workflows/validate.yml')
            $result.InvocationFailed | Should -BeFalse
            $result.ProviderRecords.Count | Should -Be 0
            $result.ProviderChunks.Count | Should -Be 0
            $result.CaptureReasonLines -join "`n" | Should -Match 'provider-file-invalid'
            $result.Transcript | Should -Not -Match 'providerSnapshot|providerSha256'
        }
        finally { Remove-CanonicalValidationObserverFixture -Fixture $fixture }
    }

    # Scenario: The provider snapshot contains invalid UTF-8 or an explicitly forbidden UTF-8 BOM.
    # Purpose: Fail closed before provider identity, digest, or projection output.
    It 'InterT88_RejectsInvalidUtf8AndBomProviderFiles' {
        foreach ($encoding in @('invalid', 'bom')) {
            $fixture = New-CanonicalValidationObserverFixture -RepositoryRoot $script:RepositoryRoot -ProviderEncoding $encoding
            try {
                $result = Invoke-CanonicalValidationObserverFixture -Fixture $fixture -WorkflowPath (Join-Path $script:RepositoryRoot '.github/workflows/validate.yml')
                $result.InvocationFailed | Should -BeFalse
                $result.ProviderRecords.Count | Should -Be 0
                $result.CaptureReasonLines -join "`n" | Should -Match 'provider-file-invalid'
                $result.Transcript | Should -Not -Match 'providerSnapshot|providerSha256'
            }
            finally { Remove-CanonicalValidationObserverFixture -Fixture $fixture }
        }
    }

    # Scenario: Two child-work keys contain the same event's provider report.
    # Purpose: Reject duplicate report locations without selecting or hashing either report.
    It 'InterT89_RejectsDuplicateProviderLocations' {
        $fixture = New-CanonicalValidationObserverFixture -RepositoryRoot $script:RepositoryRoot -DuplicateProvider
        try {
            $result = Invoke-CanonicalValidationObserverFixture -Fixture $fixture -WorkflowPath (Join-Path $script:RepositoryRoot '.github/workflows/validate.yml')
            $result.ProviderRecords.Count | Should -Be 0
            $result.CaptureReasonLines -join "`n" | Should -Match 'multiple-provider-reports-found'
            $result.Transcript | Should -Not -Match 'providerSnapshot|providerSha256'
        }
        finally { Remove-CanonicalValidationObserverFixture -Fixture $fixture }
    }

    # Scenario: The event-specific provider directory is a real junction on Windows or symbolic link on Unix.
    # Purpose: Verify the reparse/outside-root guard stops before opening the target report, and cleanup removes only the link.
    It 'InterT90_RejectsReparseAndOutsideRootProviderDirectory' {
        $fixture = New-CanonicalValidationObserverFixture -RepositoryRoot $script:RepositoryRoot -ReparseProvider
        try {
            $result = Invoke-CanonicalValidationObserverFixture -Fixture $fixture -WorkflowPath (Join-Path $script:RepositoryRoot '.github/workflows/validate.yml')
            $result.ProviderRecords.Count | Should -Be 0
            Test-Path -LiteralPath $fixture.OutsideProviderPath -PathType Leaf | Should -BeTrue
            $providerLink = Get-Item -LiteralPath $fixture.ProviderDirectoryPath -Force
            ($providerLink.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 | Should -BeTrue
            $providerLink.LinkType | Should -Be $fixture.ProviderDirectoryLinkType
            $resolvedTarget = [IO.DirectoryInfo]::new($fixture.ProviderDirectoryPath).ResolveLinkTarget($true)
            $resolvedTarget.FullName | Should -Be ([IO.Path]::GetFullPath($fixture.OutsideProviderDirectoryPath))
            $result.CaptureReasonLines -join "`n" | Should -Match 'child-work-path-invalid'
            $result.Transcript | Should -Not -Match 'SYP171_PRIVATE_SENTINEL_59b62|providerSnapshot|providerSha256'
        }
        finally { Remove-CanonicalValidationObserverFixture -Fixture $fixture }
    }

    # Scenario: The Stage 4 event envelope points to a path outside RUNNER_TEMP/runs.
    # Purpose: Exercise the separate normalized event-path containment guard without a link fixture.
    It 'InterT96_RejectsEventOutputOutsideRunsRoot' {
        $fixture = New-CanonicalValidationObserverFixture -RepositoryRoot $script:RepositoryRoot -EventOutputOutsideRunsRoot
        try {
            $result = Invoke-CanonicalValidationObserverFixture -Fixture $fixture -WorkflowPath (Join-Path $script:RepositoryRoot '.github/workflows/validate.yml')
            $result.ProviderRecords.Count | Should -Be 0
            $result.CaptureReasonLines -join "`n" | Should -Match 'event-not-verified'
            $result.Transcript | Should -Not -Match 'providerSnapshot|providerSha256'
        }
        finally { Remove-CanonicalValidationObserverFixture -Fixture $fixture }
    }

    # Scenario: Provider identity, candidate source, or execution status disagrees with validated evidence.
    # Purpose: Keep each acquisition validation boundary ahead of the provider-derived pre-record.
    It 'InterT91_RejectsInvalidIdentitySourceAndExecutionAgreement' {
        $cases = @(
            [pscustomobject]@{ Name = 'identity'; Parameters = @{ InvalidIdentity = $true }; Reason = 'provider-identity-invalid' },
            [pscustomobject]@{ Name = 'source'; Parameters = @{ SourceMismatch = $true }; Reason = 'provider-source-mismatch' },
            [pscustomobject]@{ Name = 'execution'; Parameters = @{ ExecutionMismatch = $true }; Reason = 'execution-success-mismatch' }
        )
        foreach ($case in $cases) {
            $fixtureParameters = $case.Parameters
            $fixtureParameters['RepositoryRoot'] = $script:RepositoryRoot
            $fixture = New-CanonicalValidationObserverFixture @fixtureParameters
            try {
                $result = Invoke-CanonicalValidationObserverFixture -Fixture $fixture -WorkflowPath (Join-Path $script:RepositoryRoot '.github/workflows/validate.yml')
                $result.ProviderRecords.Count | Should -Be 0 -Because "The $($case.Name) guard must run before provider diagnostics."
                $result.CaptureReasonLines -join "`n" | Should -Match $case.Reason
                $result.Transcript | Should -Not -Match 'providerSnapshot|providerSha256'
            }
            finally { Remove-CanonicalValidationObserverFixture -Fixture $fixture }
        }
    }

    # Scenario: The verified event says cleanup did not complete.
    # Purpose: Reject the event before any provider capture or projection is attempted.
    It 'InterT92_RejectsCleanupFalseEventBeforeProviderCapture' {
        $fixture = New-CanonicalValidationObserverFixture -RepositoryRoot $script:RepositoryRoot -CleanupFalse
        try {
            $result = Invoke-CanonicalValidationObserverFixture -Fixture $fixture -WorkflowPath (Join-Path $script:RepositoryRoot '.github/workflows/validate.yml')
            $result.ProviderRecords.Count | Should -Be 0
            $result.CaptureReasonLines -join "`n" | Should -Match 'event-not-verified'
            $result.Transcript | Should -Not -Match 'providerSnapshot|providerSha256'
        }
        finally { Remove-CanonicalValidationObserverFixture -Fixture $fixture }
    }

    # Scenario: Cleanup is verified, but no provider report remains in the matching child-work event folder.
    # Purpose: Emit only a fixed missing-file phase/reason and never claim that original provider bytes were retained.
    It 'InterT93_ReportsProviderMissingAfterCleanupWithoutInventingRetention' {
        $fixture = New-CanonicalValidationObserverFixture -RepositoryRoot $script:RepositoryRoot -MissingProvider
        try {
            $result = Invoke-CanonicalValidationObserverFixture -Fixture $fixture -WorkflowPath (Join-Path $script:RepositoryRoot '.github/workflows/validate.yml')
            $result.ProviderRecords.Count | Should -Be 1
            $terminal = $result.ProviderRecords[0]
            $terminal.recordKind | Should -Be 'terminal'
            $terminal.phase | Should -Be 'provider-acquisition'
            $terminal.phaseState.providerAcquisition.started | Should -BeTrue
            $terminal.phaseState.providerAcquisition.completed | Should -BeFalse
            $terminal.comparison.state | Should -Be 'not-run'
            $terminal.providerSnapshot.state | Should -Be 'missing'
            $null -eq $terminal.providerSnapshot.sha256 | Should -BeTrue
            $terminal.originalProviderRetained | Should -BeFalse
            $terminal.originalReason | Should -Be 'provider-report-not-found'
            $result.CaptureReasonLines -join "`n" | Should -Match 'provider-report-not-found'
            $result.Transcript | Should -Not -Match 'providerSha256|SYP171_PRIVATE_SENTINEL_59b62'
        }
        finally { Remove-CanonicalValidationObserverFixture -Fixture $fixture }
    }

    # Scenario: The diagnostic projection has enough nested records to hit node and serialized-output bounds.
    # Purpose: Enforce the node cap, report omitted work, keep the whole comparison, and fit the terminal envelope.
    It 'InterT94_LimitsLargeProjectionAndPreservesComparison' {
        $fixture = New-CanonicalValidationObserverFixture -RepositoryRoot $script:RepositoryRoot -LargeProjection
        try {
            $result = Invoke-CanonicalValidationObserverFixture -Fixture $fixture -WorkflowPath (Join-Path $script:RepositoryRoot '.github/workflows/validate.yml')
            $result.ProviderRecords.Count | Should -Be 2
            $terminal = $result.ProviderRecords[1]
            $terminal.projection.state | Should -Be 'limited'
            $terminal.projection.visitedNodes | Should -BeLessOrEqual 4096
            $terminal.projection.omittedNodes | Should -BeGreaterThan 0
            $terminal.phaseState.comparison.completed | Should -BeTrue
            $terminal.comparison.state | Should -Be 'equal'
            $terminal.outputStatus | Should -Be 'limited'
            $result.DiagnosticTransportBytes -le 131072 | Should -BeTrue
            $result.ProviderChunks.Count | Should -Be 0
        }
        finally { Remove-CanonicalValidationObserverFixture -Fixture $fixture }
    }

    # Scenario: A known array exceeds the per-array item bound but canonical provider/stderr comparison still completes.
    # Purpose: Preserve explicit omission counts and the total 128 KiB diagnostic transport cap.
    It 'InterT95_LimitsArraysAt1024AndBoundsOutput' {
        $fixture = New-CanonicalValidationObserverFixture -RepositoryRoot $script:RepositoryRoot -LargeArray
        try {
            $result = Invoke-CanonicalValidationObserverFixture -Fixture $fixture -WorkflowPath (Join-Path $script:RepositoryRoot '.github/workflows/validate.yml')
            $result.ProviderRecords.Count | Should -Be 2
            $terminal = $result.ProviderRecords[1]
            $terminal.projection.state | Should -Be 'limited'
            $terminal.projection.omittedNodes | Should -BeGreaterOrEqual 152
            $terminal.phaseState.comparison.completed | Should -BeTrue
            $terminal.comparison.state | Should -Be 'equal'
            $terminal.outputStatus | Should -Be 'limited'
            $result.DiagnosticTransportBytes -le 131072 | Should -BeTrue
        }
        finally { Remove-CanonicalValidationObserverFixture -Fixture $fixture }
    }

    It 'uses Unicode-aware case-insensitive inventory collision detection' {
        $repositoryValidator = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Test-Repository.ps1') -Raw
        $repositoryValidator | Should -Match 'StringComparer\]::OrdinalIgnoreCase'
        $repositoryValidator | Should -Match 'Unicode case-insensitive path collision'
        $repositoryValidator | Should -Not -Match 'ConvertTo-AsciiLowerInvariant'
    }

    # Scenario: The canonical GitHub Actions step runs the validator and then records its exit code.
    # Purpose: Preserve the native validator result while proving the saved exit and report remain unchanged.
    # Given: The workflow's actual run block and an isolated repository with a deterministic Validate.ps1 boundary stub.
    # When: The child PowerShell process receives validator exit code 0, 10, or 20.
    # Then: Its native exit, saved exit, report bytes, and diagnostic output agree with that code.
    It 'InterT97_PropagatesTheCanonicalNativeExitCode' -ForEach @(
        @{ ExitCode = 0 },
        @{ ExitCode = 10 },
        @{ ExitCode = 20 }
    ) {
        $workflowPath = Join-Path $script:RepositoryRoot '.github/workflows/validate.yml'
        $caseRoot = Join-Path $TestDrive ('canonical-exit-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $fixture = New-CanonicalExitPropagationFixture -Root $caseRoot -WorkflowPath $workflowPath
        $templateHash = (Get-FileHash -LiteralPath $fixture.ReportTemplatePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $environment = @{
            RUNNER_TEMP = $fixture.RunnerTemp
            GITHUB_SHA = $fixture.CandidateSha
            GITHUB_EVENT_NAME = 'push'
            PULL_REQUEST_BASE_SHA = ''
            PUSH_BEFORE_SHA = ''
            STANDARD_GO_RUNTIME_VERSION = 'go1.25.1'
            SYP171_CANONICAL_EXIT_CODE = [string]$ExitCode
            SYP171_CANONICAL_REPORT_TEMPLATE = $fixture.ReportTemplatePath
        }

        $result = Invoke-CanonicalWorkflowChild -ScriptPath $fixture.LaunchPath -Environment $environment
        $savedExitPath = Join-Path $fixture.RunnerTemp 'atlassian-central-exit.txt'
        $reportPath = Join-Path $fixture.RunnerTemp 'atlassian-source-conformance-report.json'
        [IO.File]::ReadAllText($savedExitPath).Trim() | Should -Be ([string]$ExitCode)
        (Get-FileHash -LiteralPath $reportPath -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $templateHash
        $result.Stdout | Should -Match "Canonical validator exited $ExitCode; source projection is checked separately\."
        $result.ExitCode | Should -Be $ExitCode -Because "the isolated child returned $($result.ExitCode); stdout='$($result.Stdout)' stderr='$($result.Stderr)'"
    }

    # Scenario: The source router consumes candidate-bound evidence after canonical validation has blocked.
    # Purpose: Keep source-stage success independent from a later canonical failure while rejecting broken evidence.
    # Given: The actual router run block and a source-pass report whose canonical result is BLOCKED with exit 10.
    # When: The router receives valid, failed, missing, malformed, or mismatched evidence in a child process.
    # Then: Only the valid source-pass-later-10 report routes as passed, with report bytes preserved.
    It 'InterT98_RoutesSourcePassAfterCanonicalBlockAndRejectsInvalidEvidence' -ForEach @(
        @{ RouterCase = 'valid'; ExpectedStatus = 'passed' },
        @{ RouterCase = 'failed-source'; ExpectedStatus = 'failed' },
        @{ RouterCase = 'missing-report'; ExpectedStatus = 'failed' },
        @{ RouterCase = 'malformed-report'; ExpectedStatus = 'failed' },
        @{ RouterCase = 'exit-mismatch'; ExpectedStatus = 'failed' }
    ) {
        $workflowPath = Join-Path $script:RepositoryRoot '.github/workflows/validate.yml'
        $routeScript = Get-CanonicalWorkflowRunScript -WorkflowPath $workflowPath -StepName 'Route source conformance from canonical evidence'
        $caseRoot = Join-Path $TestDrive ('source-route-' + [guid]::NewGuid().ToString('N'))
        $runnerTemp = Join-Path $caseRoot 'runner-temp'
        New-Item -ItemType Directory -Path $runnerTemp -Force | Out-Null
        $candidateSha = 'd' * 40
        $reportPath = Join-Path $runnerTemp 'atlassian-source-conformance-report.json'
        $reportBytesHash = $null
        if ($RouterCase -ne 'missing-report') {
            $evidence = New-CanonicalSourcePassLaterFailureReport -CandidateSha $candidateSha
            if ($RouterCase -eq 'failed-source') { $evidence.sourceConformance.status = 'failed' }
            $reportText = if ($RouterCase -eq 'malformed-report') { '{malformed-json' } else { ConvertTo-Json -InputObject $evidence -Depth 30 -Compress }
            [IO.File]::WriteAllText($reportPath, $reportText, [Text.UTF8Encoding]::new($false))
            $reportBytesHash = (Get-FileHash -LiteralPath $reportPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        $savedExit = if ($RouterCase -eq 'exit-mismatch') { '20' } else { '10' }
        $exitPath = Join-Path $runnerTemp 'atlassian-central-exit.txt'
        [IO.File]::WriteAllText($exitPath, $savedExit, [Text.UTF8Encoding]::new($false))
        $savedExitHash = (Get-FileHash -LiteralPath $exitPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $routePath = Join-Path $caseRoot 'route-source-conformance.ps1'
        [IO.File]::WriteAllText($routePath, $routeScript, [Text.UTF8Encoding]::new($false))
        $outputPath = Join-Path $caseRoot 'github-output.txt'

        $result = Invoke-CanonicalWorkflowChild -ScriptPath $routePath -Environment @{
            RUNNER_TEMP = $runnerTemp
            GITHUB_OUTPUT = $outputPath
            GITHUB_SHA = $candidateSha
        }

        $result.ExitCode | Should -Be 0 -Because "router stdout='$($result.Stdout)' stderr='$($result.Stderr)'"
        [IO.File]::ReadAllText($outputPath) | Should -Match "status=$ExpectedStatus"
        (Get-FileHash -LiteralPath $exitPath -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $savedExitHash
        if ($null -ne $reportBytesHash) {
            (Get-FileHash -LiteralPath $reportPath -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $reportBytesHash
        }
    }

    # Scenario: GitHub's downstream Require and mirror steps enforce the routed source-conformance result.
    # Purpose: Retain each native exit-1 gate while changing only canonical-step exit propagation.
    # Given: The workflow YAML consumed by the hosted jobs.
    # When: The accepted workflow is inspected.
    # Then: The Require step and all three mirrors still fail unless status is passed.
    It 'UnitT77_KeepsRequireAndMirrorExitGatesFailClosed' {
        $workflow = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/validate.yml') -Raw
        ([regex]::Matches($workflow, '(?m)^      - name: Mirror source conformance result\r?$')).Count | Should -Be 3
        ([regex]::Matches($workflow, 'if \[\[ "\$result" != ''passed'' \]\]; then[\s\S]{0,180}?exit 1')).Count | Should -Be 4
    }
}
