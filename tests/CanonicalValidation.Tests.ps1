# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Safe fixed-phase report diagnostics' {
    BeforeAll {
        $entry = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Invoke-SourceConformance.ps1'
        $errors = $null; $tokens = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($entry, [ref]$tokens, [ref]$errors)
        if (@($errors).Count) { throw 'Source adapter parse failure.' }
        foreach ($name in @('Get-SafeCentralReportState','Invoke-CentralRunnerWithDiagnostics')) {
            $definitions = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq $name })
            if ($definitions.Count -ne 1) { throw "Required diagnostic function absent: $name" }
            . ([scriptblock]::Create($definitions[0].Extent.Text))
        }
        function New-DiagnosticReport {
            $ids = @('controlled-acquisition','integrity-verification','package-validation','skillspector-static','repository-tests','conditional-semantic-scan','ai-review','human-approval','publish-or-install','post-install-verification')
            $stages = @(for ($i = 0; $i -lt 10; $i++) {
                [pscustomobject]@{order=$i+1;id=$ids[$i];status=$(if ($i -lt 5) {'passed'} else {'not-applicable'});startedAt=$(if ($i -lt 5) {'2026-09-28T00:00:00Z'} else {$null})}
            })
            return [pscustomobject]@{schemaVersion=1;evidence='standard-validation-evidence-v1';contract='standard-validation-contract-v1';state='PASS';exitCode=0;releaseEligible=$false;candidate=[pscustomobject]@{sourceRevision=('1'*40);candidateId=('2'*64);contentSha256=('3'*64)};stages=$stages}
        }
        function Get-DiagnosticBytes($Report) { return ,[Text.Encoding]::UTF8.GetBytes(($Report | ConvertTo-Json -Depth 30 -Compress)) }
        function Get-DiagnosticResult($Report) { return Get-SafeCentralReportState -ReportBytes (Get-DiagnosticBytes $Report) -ReportExists $true -ActualExitCode $Report.exitCode }
        function Assert-NoDiagnosticContent($Result) {
            $json = $Result | ConvertTo-Json -Compress
            $json | Should -Not -Match 'SECRET_DIAGNOSTIC|private-path|example\.invalid|failure\.message|GITHUB_TOKEN|Invoke-InjectedCommand'
            @($Result.PSObject.Properties.Name | Sort-Object) -join ',' | Should -Be 'candidatePlaceholder,diagnosticOnly,errorClass,failurePhase,reportShape,startedStageCount'
            $Result.diagnosticOnly | Should -BeTrue
        }
    }

    # Scenario: No report file exists after child exit. Purpose: Preserve absence without interpreting stderr or inventing stage progress.
    It 'UnitT00_ClassifiesMissingReportWithFixedTokens' {
        $r = Get-SafeCentralReportState -ReportBytes $null -ReportExists $false -ActualExitCode 10
        $r.errorClass | Should -Be 'report-missing'; $r.failurePhase | Should -Be 'unknown'; $r.reportShape | Should -Be 'missing'
        $r.startedStageCount | Should -BeNullOrEmpty; Assert-NoDiagnosticContent $r
    }
    # Scenario: The output is a reservation or damaged JSON. Purpose: Emit no offending input or parser exception.
    It 'UnitT05_ClassifiesMalformedReportWithoutEchoingContent' {
        $r = Get-SafeCentralReportState -ReportBytes ([Text.Encoding]::UTF8.GetBytes('{SECRET_DIAGNOSTIC private-path')) -ReportExists $true -ActualExitCode 10
        $r.errorClass | Should -Be 'report-invalid'; $r.failurePhase | Should -Be 'unknown'; Assert-NoDiagnosticContent $r
    }
    # Scenario: A structurally recognized source PASS exists. Purpose: Mark diagnostic completion only, without producing authority evidence.
    It 'UnitT10_ClassifiesNormalReportAsDiagnosticOnly' {
        $r = Get-DiagnosticResult (New-DiagnosticReport)
        $r.failurePhase | Should -Be 'completed'; $r.errorClass | Should -Be 'none'; $r.startedStageCount | Should -Be 5
        $r.candidatePlaceholder | Should -BeFalse; Assert-NoDiagnosticContent $r
    }
    # Scenario: A valid report is placed inside a singleton or multiple-value array. Purpose: Preserve the original object envelope before parser enumeration.
    It 'UnitT11_RejectsNonObjectRootEnvelope' {
        $normal=[Text.Encoding]::UTF8.GetString((Get-DiagnosticBytes (New-DiagnosticReport)))
        foreach($text in @(('['+$normal+']'),('['+$normal+','+$normal+']'),'null','"SECRET_DIAGNOSTIC"')) {
            $r=Get-SafeCentralReportState -ReportBytes ([Text.Encoding]::UTF8.GetBytes($text)) -ReportExists $true -ActualExitCode 0
            $r.failurePhase | Should -Be 'unknown';$r.errorClass | Should -Be 'report-invalid';Assert-NoDiagnosticContent $r
        }
    }
    # Scenario: JSON contains trailing commas, missing punctuation or multiple roots. Purpose: Reject permissive parser extensions consistently across runtimes.
    It 'UnitT12_RejectsNonJsonPunctuation' {
        $normal=[Text.Encoding]::UTF8.GetString((Get-DiagnosticBytes (New-DiagnosticReport)))
        foreach($text in @(($normal.Substring(0,$normal.Length-1)+',}'),$normal.Replace('"stages":[','"stages":[,') ,$normal.Replace('"schemaVersion":1','"schemaVersion" 1'),($normal+$normal),'{"opaque":[0,]}')) {
            $r=Get-SafeCentralReportState -ReportBytes ([Text.Encoding]::UTF8.GetBytes($text)) -ReportExists $true -ActualExitCode 0
            $r.failurePhase | Should -Be 'unknown';$r.errorClass | Should -Be 'report-invalid';Assert-NoDiagnosticContent $r
        }
    }
    # Scenario: Number, whitespace and escape tokens violate JSON grammar. Purpose: Validate grammar before either runtime performs conversion.
    It 'UnitT13_RejectsNonJsonScalarTokens' {
        $normal=[Text.Encoding]::UTF8.GetString((Get-DiagnosticBytes (New-DiagnosticReport)))
        foreach($number in @('01','-01','+1','0x1','NaN','Infinity','1.','1e')) {
            $text=$normal.Replace('"schemaVersion":1',('"schemaVersion":'+$number))
            $r=Get-SafeCentralReportState -ReportBytes ([Text.Encoding]::UTF8.GetBytes($text)) -ReportExists $true -ActualExitCode 0
            $r.errorClass | Should -Be 'report-invalid';Assert-NoDiagnosticContent $r
        }
        foreach($text in @('{"opaque":"\q"}',('{'+[char]0x00a0+'"opaque":0}'))) {
            $r=Get-SafeCentralReportState -ReportBytes ([Text.Encoding]::UTF8.GetBytes($text)) -ReportExists $true -ActualExitCode 0
            $r.errorClass | Should -Be 'report-invalid';Assert-NoDiagnosticContent $r
        }
    }
    # Scenario: Valid nested opaque values include escaped strings and exponent numbers. Purpose: Preserve strict valid reports without interpreting opaque content.
    It 'UnitT14_AcceptsStrictNestedOpaqueJson' {
        $normal=[Text.Encoding]::UTF8.GetString((Get-DiagnosticBytes (New-DiagnosticReport)))
        $text=$normal.Substring(0,$normal.Length-1)+',"opaque":{"empty":{},"array":[null,true,false,-0,1.25e-2,"SECRET_DIAGNOSTIC\\private-path\u0020\n"]}}'
        $r=Get-SafeCentralReportState -ReportBytes ([Text.Encoding]::UTF8.GetBytes($text)) -ReportExists $true -ActualExitCode 0
        $r.failurePhase | Should -Be 'completed';$r.errorClass | Should -Be 'none';Assert-NoDiagnosticContent $r
    }
    # Scenario: An original pre-stage barrier produces a zero candidate and no started stages. Purpose: Separate the phase from the downstream revision failure code.
    It 'UnitT15_ClassifiesPreStageBlockedPlaceholder' {
        $report = New-DiagnosticReport; $report.state='BLOCKED'; $report.exitCode=10
        $report.candidate.sourceRevision='0'*40; $report.candidate.candidateId='0'*64; $report.candidate.contentSha256='0'*64
        foreach ($s in $report.stages) {$s.status='not-applicable';$s.startedAt=$null}
        $r = Get-DiagnosticResult $report
        $r.failurePhase | Should -Be 'pre-stage'; $r.errorClass | Should -Be 'pre-stage-blocked'; $r.startedStageCount | Should -Be 0
        $r.candidatePlaceholder | Should -BeTrue; Assert-NoDiagnosticContent $r
    }
    # Scenario: The second started stage actually fails. Purpose: Produce only a bounded stage enum from the first failed stage.
    It 'UnitT20_ClassifiesLaterStageFailure' {
        $report=New-DiagnosticReport; $report.state='FAILED';$report.exitCode=20;$report.stages[1].status='failed'
        foreach ($s in $report.stages[2..9]) {$s.status='not-run';$s.startedAt=$null}
        $r=Get-DiagnosticResult $report
        $r.failurePhase | Should -Be 'stage-2'; $r.errorClass | Should -Be 'stage-failed'; Assert-NoDiagnosticContent $r
    }
    # Scenario: An unstarted tail stage is terminal failed, blocked or cancelled under PASS. Purpose: Do not hide terminal failure behind a null timestamp.
    It 'UnitT21_RejectsTerminalStageWithoutStart' {
        foreach($status in @('failed','blocked','cancelled')) {
            $report=New-DiagnosticReport;$report.stages[5].status=$status
            $r=Get-DiagnosticResult $report
            $r.failurePhase | Should -Be 'unknown';$r.errorClass | Should -Be 'unknown';Assert-NoDiagnosticContent $r
        }
    }
    # Scenario: Required passed stages lack starts while not-run tail stages carry starts. Purpose: Count progress only after status/start consistency is established.
    It 'UnitT22_RejectsInconsistentPassedAndNotRunStarts' {
        $report=New-DiagnosticReport
        foreach($s in $report.stages[0..4]) {$s.startedAt=$null}
        foreach($s in $report.stages[5..9]) {$s.status='not-run';$s.startedAt='2026-09-28T00:00:00Z'}
        $r=Get-DiagnosticResult $report
        $r.failurePhase | Should -Be 'unknown';$r.startedStageCount | Should -BeNullOrEmpty;Assert-NoDiagnosticContent $r
        $report=New-DiagnosticReport;$report.stages[0].startedAt=$null
        $r=Get-DiagnosticResult $report
        $r.failurePhase | Should -Be 'unknown';Assert-NoDiagnosticContent $r
    }
    # Scenario: Root state, terminal stage, exit or release flag contradicts the terminal envelope. Purpose: Return unknown rather than rename a different failure class.
    It 'UnitT23_RejectsRootStageExitAndReleaseContradictions' {
        foreach($case in @(@{state='BLOCKED';exit=10;stage='failed'},@{state='FAILED';exit=20;stage='blocked'},@{state='CANCELLED';exit=40;stage='failed'},@{state='FAILED';exit=0;stage='failed'})) {
            $report=New-DiagnosticReport;$report.state=$case.state;$report.exitCode=$case.exit;$report.stages[1].status=$case.stage
            foreach($s in $report.stages[2..9]) {$s.status='not-run';$s.startedAt=$null}
            $r=Get-DiagnosticResult $report
            $r.failurePhase | Should -Be 'unknown';$r.errorClass | Should -Be 'unknown';Assert-NoDiagnosticContent $r
        }
        $report=New-DiagnosticReport;$report.state='BLOCKED';$report.exitCode=0
        $report.candidate.sourceRevision='0'*40;$report.candidate.candidateId='0'*64;$report.candidate.contentSha256='0'*64
        foreach($s in $report.stages) {$s.status='not-applicable';$s.startedAt=$null}
        $r=Get-DiagnosticResult $report
        $r.failurePhase | Should -Be 'unknown';Assert-NoDiagnosticContent $r
        $report=New-DiagnosticReport;$report.state='FAILED';$report.exitCode=20;$report.releaseEligible=$true;$report.stages[1].status='failed'
        foreach($s in $report.stages[2..9]) {$s.status='not-run';$s.startedAt=$null}
        $r=Get-DiagnosticResult $report
        $r.failurePhase | Should -Be 'unknown';Assert-NoDiagnosticContent $r
    }
    # Scenario: Later stages start after an earlier terminal failure. Purpose: Reject impossible sequential progress instead of advertising a known first phase.
    It 'UnitT24_RejectsStagesStartingAfterTerminalFailure' {
        $report=New-DiagnosticReport;$report.state='FAILED';$report.exitCode=20;$report.stages[1].status='failed'
        $r=Get-DiagnosticResult $report
        $r.failurePhase | Should -Be 'unknown';Assert-NoDiagnosticContent $r
    }
    # Scenario: A caller supplies a secret/path as a purported terminal state. Purpose: Unknown strings cannot become diagnostic enums.
    It 'UnitT25_RejectsUntrustedStateAndStringBoolean' {
        $report=New-DiagnosticReport;$report.state='SECRET_DIAGNOSTIC private-path';$report.releaseEligible='false'
        $r=Get-DiagnosticResult $report
        $r.failurePhase | Should -Be 'unknown';$r.errorClass | Should -Be 'unknown';Assert-NoDiagnosticContent $r
    }
    # Scenario: Blocked, invalid and cancelled envelopes have coherent starts and terminal statuses. Purpose: Preserve bounded diagnostics for known real terminal classes.
    It 'UnitT26_AcceptsCoherentTerminalStateMapping' {
        foreach($case in @(@{state='BLOCKED';exit=10;stage='blocked';class='stage-blocked'},@{state='INVALID';exit=30;stage='failed';class='stage-failed'},@{state='CANCELLED';exit=40;stage='cancelled';class='stage-failed'})) {
            $report=New-DiagnosticReport;$report.state=$case.state;$report.exitCode=$case.exit;$report.stages[1].status=$case.stage
            foreach($s in $report.stages[2..9]) {$s.status='not-run';$s.startedAt=$null}
            $r=Get-DiagnosticResult $report
            $r.failurePhase | Should -Be 'stage-2';$r.errorClass | Should -Be $case.class;Assert-NoDiagnosticContent $r
        }
    }
    # Scenario: A PASS report retains a pending conditional/lifecycle stage. Purpose: Do not report completed while canonical producer work remains not-run.
    It 'UnitT27_RejectsPendingStagesUnderPassEnvelope' {
        foreach($index in 5..9) {
            $report=New-DiagnosticReport;$report.stages[$index].status='not-run'
            $r=Get-DiagnosticResult $report
            $r.failurePhase | Should -Be 'unknown';$r.errorClass | Should -Be 'unknown';Assert-NoDiagnosticContent $r
        }
        $report=New-DiagnosticReport;foreach($s in $report.stages[5..9]) {$s.status='not-run'}
        $r=Get-DiagnosticResult $report
        $r.failurePhase | Should -Be 'unknown';Assert-NoDiagnosticContent $r
    }
    # Scenario: PASS mixes an executed lifecycle tail with explicit validation-only exclusions. Purpose: Respect the producer's single CompleteLifecycle choice.
    It 'UnitT28_RejectsMixedPassedAndExcludedLifecycleTail' {
        foreach($index in 6..9) {
            $report=New-DiagnosticReport;$report.stages[$index].status='passed';$report.stages[$index].startedAt='2026-09-28T00:00:00Z'
            $r=Get-DiagnosticResult $report
            $r.failurePhase | Should -Be 'unknown';Assert-NoDiagnosticContent $r
        }
    }
    # Scenario: releaseEligible asserts lifecycle completion, including conditional exclusion. Purpose: Check status shape without treating diagnostics as release authority.
    It 'UnitT29_ValidatesReleaseFlagAgainstTerminalLifecycleShape' {
        $report=New-DiagnosticReport;$report.releaseEligible=$true
        $r=Get-DiagnosticResult $report
        $r.failurePhase | Should -Be 'unknown';Assert-NoDiagnosticContent $r
        foreach($release in @($false,$true)) {
            $report=New-DiagnosticReport;$report.releaseEligible=$release
            foreach($s in $report.stages[6..9]) {$s.status='passed';$s.startedAt='2026-09-28T00:00:00Z'}
            $r=Get-DiagnosticResult $report
            $r.failurePhase | Should -Be 'completed';$r.startedStageCount | Should -Be 9;Assert-NoDiagnosticContent $r
            $report.stages[5].status='passed';$report.stages[5].startedAt='2026-09-28T00:00:00Z'
            $r=Get-DiagnosticResult $report
            $r.failurePhase | Should -Be 'completed';$r.startedStageCount | Should -Be 10;Assert-NoDiagnosticContent $r
        }
    }
    # Scenario: startedAt carries a command instead of a timestamp. Purpose: Do not infer progress from arbitrary non-null content.
    It 'UnitT30_RejectsInjectedStageProgress' {
        $report=New-DiagnosticReport;$report.stages[0].startedAt='Invoke-InjectedCommand SECRET_DIAGNOSTIC'
        $r=Get-DiagnosticResult $report
        $r.failurePhase | Should -Be 'unknown';$r.startedStageCount | Should -BeNullOrEmpty;Assert-NoDiagnosticContent $r
    }
    # Scenario: A later required stage fails after an earlier always stage was skipped. Purpose: Require the exact passed prefix before recognizing a failure phase.
    It 'UnitT31_RequiresPassedAlwaysPrefixBeforeLaterFailure' {
        foreach($failedIndex in 1..4) {
            foreach($skippedIndex in 0..($failedIndex-1)) {
                $report=New-DiagnosticReport;$report.state='FAILED';$report.exitCode=20;$report.stages[$failedIndex].status='failed'
                $report.stages[$skippedIndex].status='not-applicable';$report.stages[$skippedIndex].startedAt=$null
                foreach($s in $report.stages[($failedIndex+1)..9]) {$s.status='not-run';$s.startedAt=$null}
                $r=Get-DiagnosticResult $report
                $r.failurePhase | Should -Be 'unknown';Assert-NoDiagnosticContent $r
            }
        }
    }
    # Scenario: A lifecycle stage fails after the conditional stage is explicitly excluded. Purpose: Preserve valid late failures and the legitimate optional prefix.
    It 'UnitT32_AcceptsConditionalExclusionBeforeLateFailure' {
        foreach($failedIndex in 6..9) {
            $report=New-DiagnosticReport;$report.state='FAILED';$report.exitCode=20
            for($i=6;$i -le $failedIndex;$i++) {$report.stages[$i].status='passed';$report.stages[$i].startedAt='2026-09-28T00:00:00Z'}
            $report.stages[$failedIndex].status='failed'
            for($i=$failedIndex+1;$i -lt 10;$i++) {$report.stages[$i].status='not-run';$report.stages[$i].startedAt=$null}
            $r=Get-DiagnosticResult $report
            $r.failurePhase | Should -Be ('stage-'+($failedIndex+1));$r.errorClass | Should -Be 'stage-failed';Assert-NoDiagnosticContent $r
        }
    }
    # Scenario: Explicitly excluded stages carry execution starts. Purpose: Keep validation-only and conditional exclusion consistent with the pinned producer.
    It 'UnitT33_RejectsStartedExplicitExclusions' {
        foreach($index in 5..9) {
            $report=New-DiagnosticReport;$report.stages[$index].startedAt='2026-09-28T00:00:00Z'
            $r=Get-DiagnosticResult $report
            $r.failurePhase | Should -Be 'unknown';Assert-NoDiagnosticContent $r
        }
    }
    # Scenario: A later lifecycle failure follows a skipped lifecycle prerequisite. Purpose: Apply passed-prefix validation beyond the first five required stages.
    It 'UnitT34_RejectsSkippedLifecyclePrefixBeforeLaterFailure' {
        $report=New-DiagnosticReport;$report.state='FAILED';$report.exitCode=20
        $report.stages[7].status='passed';$report.stages[7].startedAt='2026-09-28T00:00:00Z'
        $report.stages[8].status='failed';$report.stages[8].startedAt='2026-09-28T00:00:00Z'
        $report.stages[9].status='not-run';$report.stages[9].startedAt=$null
        $r=Get-DiagnosticResult $report
        $r.failurePhase | Should -Be 'unknown';Assert-NoDiagnosticContent $r
    }
    # Scenario: The candidate has a malformed or inconsistent placeholder identity. Purpose: No candidate content crosses the diagnostic boundary.
    It 'UnitT35_RejectsUntrustedCandidateIdentity' {
        $report=New-DiagnosticReport;$report.candidate.sourceRevision='SECRET_DIAGNOSTIC'
        $r=Get-DiagnosticResult $report
        $r.failurePhase | Should -Be 'unknown';$r.candidatePlaceholder | Should -BeNullOrEmpty;Assert-NoDiagnosticContent $r
    }
    # Scenario: Root keys are duplicated or differ only in case. Purpose: PS5.1 and PS7 parsers must not silently choose different states.
    It 'UnitT40_RejectsDuplicateAndCaseConflictingJsonKeys' {
        foreach ($key in @('state','STATE')) {
            $text=([Text.Encoding]::UTF8.GetString((Get-DiagnosticBytes (New-DiagnosticReport)))).Replace('"state":"PASS"',('"state":"PASS","'+$key+'":"SECRET_DIAGNOSTIC"'))
            $r=Get-SafeCentralReportState -ReportBytes ([Text.Encoding]::UTF8.GetBytes($text)) -ReportExists $true -ActualExitCode 0
            $r.failurePhase | Should -Be 'unknown';$r.errorClass | Should -Be 'report-invalid';Assert-NoDiagnosticContent $r
        }
    }
    # Scenario: A report contains opaque errors, environment names and paths. Purpose: Ignore all content fields even in an otherwise recognized report.
    It 'UnitT45_DropsSecretPathCommandAndEnvironmentContent' {
        $report=New-DiagnosticReport
        $report | Add-Member -NotePropertyName failure -NotePropertyValue @{message='SECRET_DIAGNOSTIC C:\private-path Invoke-InjectedCommand GITHUB_TOKEN https://example.invalid'}
        $report | Add-Member -NotePropertyName failurePhase -NotePropertyValue 'SECRET_DIAGNOSTIC'
        $r=Get-DiagnosticResult $report
        $r.failurePhase | Should -Be 'completed';Assert-NoDiagnosticContent $r
    }
    # Scenario: Invalid UTF8 cannot be a report. Purpose: Emit fixed parse classification with no decoder output.
    It 'UnitT50_RejectsInvalidUtf8' {
        $r=Get-SafeCentralReportState -ReportBytes ([byte[]]@(255,254,1)) -ReportExists $true -ActualExitCode 10
        $r.errorClass | Should -Be 'report-invalid';Assert-NoDiagnosticContent $r
    }
    # Scenario: Oversized untrusted report data is supplied. Purpose: Bound decoder/parser memory before report interpretation.
    It 'UnitT55_BoundsReportBytes' {
        $r=Get-SafeCentralReportState -ReportBytes (New-Object byte[] 1048577) -ReportExists $true -ActualExitCode 10
        $r.errorClass | Should -Be 'report-invalid';Assert-NoDiagnosticContent $r
    }
    # Scenario: A real child writes an original report and exits. Purpose: Preserve original bytes/hash/exit while adding only fixed diagnostic metadata.
    It 'InterT60_PreservesOriginalBytesHashAndExitWithSafeMetadata' {
        $run=Join-Path $TestDrive 'phase-child';[void](New-Item -ItemType Directory $run)
        $output=Join-Path $run 'report.json';$child=Join-Path $run 'child.ps1'
        $text=[Text.Encoding]::UTF8.GetString((Get-DiagnosticBytes (New-DiagnosticReport)))
        $literal=$text.Replace("'","''");$outputLiteral=$output.Replace("'","''")
        [IO.File]::WriteAllText($child,"[IO.File]::WriteAllText('$outputLiteral','$literal',[Text.UTF8Encoding]::new(`$false)); exit 0")
        $result=Invoke-CentralRunnerWithDiagnostics -PowerShellPath (Get-Command pwsh -CommandType Application | Select-Object -First 1).Path -RunnerPath $child -Arguments @('-FixtureOnly') -RunRoot $run -OutputPath $output
        $m=Get-Content -LiteralPath $result.metadataPath -Raw | ConvertFrom-Json
        $result.exitCode | Should -Be 0
        $m.report.sha256 | Should -Be (Get-FileHash -LiteralPath $output).Hash.ToLowerInvariant()
        [IO.File]::ReadAllText($result.reportSnapshotPath) | Should -Be $text
        $m.safeReportState.failurePhase | Should -Be 'completed';Assert-NoDiagnosticContent $m.safeReportState
    }
}

Describe 'Canonical Standard v1 validation adapter' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:ValidatorPath = Join-Path $script:RepositoryRoot 'scripts/Validate.ps1'
        $script:Validator = Get-Content -LiteralPath $script:ValidatorPath -Raw
        $script:Adapter = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'config/standard-v1.json') -Raw |
            ConvertFrom-Json -Depth 20
        $script:GitPath = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path
        $diagnosticTokens = $null; $diagnosticErrors = $null
        $diagnosticAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepositoryRoot 'scripts/Invoke-SourceConformance.ps1'), [ref]$diagnosticTokens, [ref]$diagnosticErrors)
        if (@($diagnosticErrors).Count) { throw 'Diagnostic source parse failure.' }
        $classifier = @($diagnosticAst.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq 'Get-SafeCentralReportState' })
        if ($classifier.Count -ne 1) { throw 'Diagnostic classifier absent.' }
        . ([scriptblock]::Create($classifier[0].Extent.Text))
    }

    It 'UnitT00_PinsTheApproved8aAuthorityAndExactArchiveBoundary' {
        # Scenario: The validator obtains the normative Standard v1 snapshot.
        # Purpose: Reject mutable branches, broad archive URLs, or an unbound authority.
        $script:Adapter.authority.commit | Should -Be '8aabd22694a05771f98639f6d726cc9a620eb94b'
        $script:Adapter.authority.archiveUrl | Should -Match '/zip/[0-9a-f]{40}$'
        $script:Adapter.authority.archiveSha256 | Should -Be 'd92df1a8f0aa342970dc9c66a77b6211955b4708de12119cb7f9a360fd265311'
        $script:Adapter.authority.files.Count | Should -Be 26
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

    It 'uses Unicode-aware case-insensitive inventory collision detection' {
        $repositoryValidator = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Test-Repository.ps1') -Raw
        $repositoryValidator | Should -Match 'StringComparer\]::OrdinalIgnoreCase'
        $repositoryValidator | Should -Match 'Unicode case-insensitive path collision'
        $repositoryValidator | Should -Not -Match 'ConvertTo-AsciiLowerInvariant'
    }

    It 'UnitT80_PreservesFailedCentralChildDiagnosticsWithoutChangingReport' {
        # Scenario: The pinned central child writes both streams and leaves a reserved report after a nonzero exit.
        # Purpose: Preserve the exact failure evidence while keeping the report and exit result fail closed.
        $sourcePath = Join-Path $script:RepositoryRoot 'scripts/Invoke-SourceConformance.ps1'
        $tokens = $null
        $parseErrors = $null
        $sourceAst = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $definitions = @($sourceAst.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                        $node.Name -ceq 'Invoke-CentralRunnerWithDiagnostics'
                }, $false))
        $definitions.Count | Should -Be 1
        . ([scriptblock]::Create($definitions[0].Extent.Text))

        $fixtureRoot = Join-Path $TestDrive 'failed-central-child'
        [void](New-Item -ItemType Directory -Path $fixtureRoot)
        $childPath = Join-Path $fixtureRoot 'child.ps1'
        $reportPath = Join-Path $fixtureRoot 'report.json'
        $reserved = 'standard-validation-output-reservation-v1:fixture'
        $childScript = @'
param([string] $OutputPath)
[IO.File]::WriteAllText($OutputPath, 'standard-validation-output-reservation-v1:fixture', [Text.UTF8Encoding]::new($false))
[Console]::Out.WriteLine('fixture stdout')
[Console]::Error.WriteLine('fixture stderr')
exit 31
'@
        [IO.File]::WriteAllText($childPath, $childScript, [Text.UTF8Encoding]::new($false))
        $powerShellPath = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path

        $result = Invoke-CentralRunnerWithDiagnostics -PowerShellPath $powerShellPath -RunnerPath $childPath `
            -Arguments @('-OutputPath', $reportPath) -RunRoot $fixtureRoot -OutputPath $reportPath

        $result.exitCode | Should -Be 31
        [IO.File]::ReadAllText($reportPath) | Should -Be $reserved
        [IO.File]::ReadAllText($result.stdoutPath) | Should -Match 'fixture stdout'
        [IO.File]::ReadAllText($result.stderrPath) | Should -Match 'fixture stderr'
        [IO.File]::ReadAllBytes($result.reportSnapshotPath) | Should -Be ([IO.File]::ReadAllBytes($reportPath))
        $metadata = Get-Content -LiteralPath $result.metadataPath -Raw | ConvertFrom-Json -Depth 20
        $metadata.exitCode | Should -Be 31
        $metadata.report.prefixHex | Should -Be ([Convert]::ToHexString([Text.Encoding]::UTF8.GetBytes($reserved)).ToLowerInvariant())
        $metadata.report.reservationPrefix | Should -BeTrue
    }

    It 'UnitT90_PreservesSuccessfulCentralChildReportAndExit' {
        # Scenario: The pinned central child writes a valid report and exits successfully.
        # Purpose: Keep successful source validation unaffected by the diagnostic capture.
        $sourcePath = Join-Path $script:RepositoryRoot 'scripts/Invoke-SourceConformance.ps1'
        $tokens = $null
        $parseErrors = $null
        $sourceAst = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $definition = @($sourceAst.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                        $node.Name -ceq 'Invoke-CentralRunnerWithDiagnostics'
                }, $false))
        $definition.Count | Should -Be 1
        . ([scriptblock]::Create($definition[0].Extent.Text))

        $fixtureRoot = Join-Path $TestDrive 'successful-central-child'
        [void](New-Item -ItemType Directory -Path $fixtureRoot)
        $childPath = Join-Path $fixtureRoot 'child.ps1'
        $reportPath = Join-Path $fixtureRoot 'report.json'
        $childScript = @'
param([string] $OutputPath)
[IO.File]::WriteAllText($OutputPath, '{"status":"passed"}', [Text.UTF8Encoding]::new($false))
[Console]::Out.WriteLine('fixture success')
exit 0
'@
        [IO.File]::WriteAllText($childPath, $childScript, [Text.UTF8Encoding]::new($false))
        $powerShellPath = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path
        $result = Invoke-CentralRunnerWithDiagnostics -PowerShellPath $powerShellPath -RunnerPath $childPath `
            -Arguments @('-OutputPath', $reportPath) -RunRoot $fixtureRoot -OutputPath $reportPath

        $result.exitCode | Should -Be 0
        (Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json).status | Should -Be 'passed'
        [IO.File]::ReadAllText($result.stdoutPath) | Should -Match 'fixture success'
        $metadata = Get-Content -LiteralPath $result.metadataPath -Raw | ConvertFrom-Json -Depth 20
        $metadata.report.reservationPrefix | Should -BeFalse
        $metadata.report.sha256 | Should -Be (Get-FileHash -Algorithm SHA256 -LiteralPath $reportPath).Hash.ToLowerInvariant()
    }

    It 'UnitT100_RecordsLaunchFailureWhenNoCentralReportExists' {
        # Scenario: The trusted child executable cannot be launched and no report is created.
        # Purpose: Keep the original failure visible and never interpret missing evidence as success.
        $sourcePath = Join-Path $script:RepositoryRoot 'scripts/Invoke-SourceConformance.ps1'
        $tokens = $null
        $parseErrors = $null
        $sourceAst = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $definition = @($sourceAst.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                        $node.Name -ceq 'Invoke-CentralRunnerWithDiagnostics'
                }, $false))
        $definition.Count | Should -Be 1
        . ([scriptblock]::Create($definition[0].Extent.Text))

        $fixtureRoot = Join-Path $TestDrive 'unlaunched-central-child'
        [void](New-Item -ItemType Directory -Path $fixtureRoot)
        $missingExecutable = Join-Path $fixtureRoot 'missing-pwsh.exe'
        $runnerPath = Join-Path $fixtureRoot 'runner.ps1'
        [IO.File]::WriteAllText($runnerPath, 'exit 0', [Text.UTF8Encoding]::new($false))
        $reportPath = Join-Path $fixtureRoot 'missing-report.json'

        $result = Invoke-CentralRunnerWithDiagnostics -PowerShellPath $missingExecutable -RunnerPath $runnerPath `
            -Arguments @('-OutputPath', $reportPath) -RunRoot $fixtureRoot -OutputPath $reportPath

        $result.exitCode | Should -Not -Be 0
        Test-Path -LiteralPath $reportPath | Should -BeFalse
        Test-Path -LiteralPath $result.stdoutPath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $result.stderrPath -PathType Leaf | Should -BeTrue
        $metadata = Get-Content -LiteralPath $result.metadataPath -Raw | ConvertFrom-Json -Depth 20
        $metadata.launchError | Should -Not -BeNullOrEmpty
        $metadata.report.exists | Should -BeFalse
    }

    It 'UnitT110_ExposesOnlyBoundedKnownSourceFailureCodesForExitTen' {
        # Scenario: A blocked canonical report has source-binding failures plus an arbitrary fake-secret reason.
        # Purpose: Preserve actionable fixed failure codes for exit 10 without exposing child content.
        $path = Join-Path $script:RepositoryRoot 'scripts/Invoke-SourceConformance.ps1'
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
        $definitions = @($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Get-CentralSourceFailureSummary'
        }, $false))
        $definitions.Count | Should -Be 1
        . ([scriptblock]::Create($definitions[0].Extent.Text))
        $report = [pscustomobject]@{ exitCode=10; state='BLOCKED'; sourceConformance=[pscustomobject]@{
            status='failed'; failureReasons=@('candidate-revision-mismatch', 'pester-event-binding-invalid',
                'source-stage-3-not-passed', 'TOP_SECRET_FAILURE_MARKER', 'candidate-revision-mismatch')
        } }
        $summary = Get-CentralSourceFailureSummary -Report $report -MaximumCodes 2
        $summary.sourceStatus | Should -Be 'failed'
        @($summary.failureCodes).Count | Should -Be 2
        $summary.unknownReasonCount | Should -Be 1
        $summary.omittedKnownCodeCount | Should -Be 1
        ($summary | ConvertTo-Json -Depth 5) | Should -Not -Match 'TOP_SECRET_FAILURE_MARKER'
        $summary.failureCodes | Should -Contain 'candidate-revision-mismatch'
        $source = Get-Content -LiteralPath $path -Raw
        $source | Should -Not -Match 'Write-Warning.*\$diagnostic'
    }
}
