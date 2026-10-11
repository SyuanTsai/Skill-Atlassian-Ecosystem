# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $repositoryRoot=Split-Path -Parent $PSScriptRoot
    $runtimeScripts=Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts'
    Import-Module (Join-Path $runtimeScripts 'ConfluenceRuntime.psm1') -Force
    $tokens=$null;$parseErrors=$null
    $adapterAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repositoryRoot 'scripts/Invoke-SourceConformance.ps1'),[ref]$tokens,[ref]$parseErrors)
    if($parseErrors.Count -ne 0){throw 'Source adapter parse failed'}
    $assignment=$adapterAst.Find({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$childRunnerText'},$true)
    $childText=$assignment.Right.Find({param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst]},$true).Value
    $childAst=[Management.Automation.Language.Parser]::ParseInput($childText,[ref]$tokens,[ref]$parseErrors)
    if($parseErrors.Count -ne 0){throw 'Source child parse failed'}
    $mappingHelpers=@('Get-Property','Get-TextSha256','New-Finding') | ForEach-Object {
        $helperName=$_
        $definition=$childAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $helperName},$true)
        if($null -eq $definition){throw "Finding helper missing: $helperName"}
        $definition.Extent.Text
    }
    $script:findingMapper=New-Module -ScriptBlock ([scriptblock]::Create(($mappingHelpers -join "`n")+"`nExport-ModuleMember -Function New-Finding"))
    $pesterModule=(Get-Module Pester|Select-Object -First 1)
    $pesterManifest=Join-Path $pesterModule.ModuleBase 'Pester.psd1'
    $pwshPath=(Get-Command pwsh -CommandType Application|Select-Object -First 1).Source

    function Invoke-RuntimeAdapterFixture {
        $toolchainPath=Join-Path $script:caseRoot 'toolchain.json'
        [IO.File]::WriteAllText($toolchainPath,($script:toolchain|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
        $start=[Diagnostics.ProcessStartInfo]::new()
        $start.FileName=$pwshPath
        foreach($argument in @('-NoProfile','-NonInteractive','-File',$script:childPath,'-Mode','repository-pester','-ToolchainPath',$toolchainPath,
            '-ToolchainSha256',(Get-FileHash -LiteralPath $toolchainPath -Algorithm SHA256).Hash.ToLowerInvariant())){$start.ArgumentList.Add($argument)}
        $start.UseShellExecute=$false;$start.CreateNoWindow=$true
        $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        $start.WorkingDirectory=$script:caseRoot
        $start.Environment.Clear()
        foreach($name in @('PATH','SystemRoot','WINDIR','COMSPEC','TEMP','TMP','PATHEXT')){
            $value=[Environment]::GetEnvironmentVariable($name,'Process')
            if(-not [string]::IsNullOrWhiteSpace($value)){$start.Environment[$name]=$value}
        }
        $start.Environment['STANDARD_VALIDATION_CANDIDATE_ROOT']=$script:candidateRoot
        $start.Environment['STANDARD_VALIDATION_ACTIVE_SKILLS']='manage-confluence-docs-as-code'
        $start.Environment['STANDARD_VALIDATION_CANDIDATE_ID']='synthetic-runtime-adapter'
        $start.Environment['SYP171_RUNTIME_ROOT']='untrusted-caller-runtime'
        $process=[Diagnostics.Process]::new();$process.StartInfo=$start
        try{
            if(-not $process.Start()){throw 'Adapter child failed to start'}
            $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
            if(-not $process.WaitForExit(45000)){$process.Kill($true);throw 'Adapter fixture timeout'}
            return [pscustomobject]@{exitCode=$process.ExitCode;stdout=$stdout.GetAwaiter().GetResult();stderr=$stderr.GetAwaiter().GetResult()}
        }finally{$process.Dispose()}
    }
}

Describe 'Source conformance provider finding identity' {
    # Scenario: A SkillSpector issue reports its rule, explanation and file in its native schema.
    # Purpose: Canonical evidence keeps the provider identity and location without changing its severity or fingerprint.
    It 'UnitT10_preserves_native_provider_rule_location_and_explanation' {
        $issue=[pscustomobject]@{id='E1';severity='MEDIUM';explanation='Exact endpoint identity comparison';location=[pscustomobject]@{file='scripts/ConfluencePlan.psm1';start_line=335}}
        $result=& $script:findingMapper {param($value) New-Finding -Issue $value -SkillId 'manage-confluence-docs-as-code' -Stage 'skillspector-static'} $issue
        $result.ruleId|Should -BeExactly 'E1'
        $result.path|Should -BeExactly 'scripts/ConfluencePlan.psm1'
        $result.message|Should -BeExactly $issue.explanation
        $result.severity|Should -BeExactly 'medium'
        $result.skillId|Should -BeExactly 'manage-confluence-docs-as-code'
        $bytes=[Text.Encoding]::UTF8.GetBytes(($issue|ConvertTo-Json -Depth 30 -Compress))
        $expectedHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        $result.fingerprint|Should -BeExactly $expectedHash
    }

    # Scenario: An existing adapter provider supplies flat fields as well as conflicting native aliases.
    # Purpose: Native-schema support does not change the established flat-field precedence.
    It 'UnitT20_keeps_existing_flat_field_precedence' {
        $issue=[pscustomobject]@{rule_id='legacy-rule';ruleId='other-rule';id='E1';file='legacy.ps1';path='other.ps1';location=[pscustomobject]@{file='native.ps1'};message='legacy message';explanation='native explanation';severity='INFO'}
        $result=& $script:findingMapper {param($value) New-Finding -Issue $value -SkillId 'test-skill' -Stage 'test-stage'} $issue
        $result.ruleId|Should -BeExactly 'legacy-rule'
        $result.path|Should -BeExactly 'legacy.ps1'
        $result.message|Should -BeExactly 'legacy message'
        $result.severity|Should -BeExactly 'informational'
    }

    # Scenario: Multiple provider occurrences share the same rule identifier and have separate locations.
    # Purpose: Mapping does not collapse occurrences or weaken their individual severity.
    It 'UnitT30_keeps_each_occurrence_and_handles_absent_optional_location' {
        $issues=@(
            [pscustomobject]@{id='E1';severity='MEDIUM';location=[pscustomobject]@{file='first.psm1'}},
            [pscustomobject]@{id='E1';severity='MEDIUM';location=[pscustomobject]@{file='second.psm1'}},
            [pscustomobject]@{id='LP3';severity='MEDIUM';location=$null},
            [pscustomobject]@{id='SC4';severity='HIGH'}
        )
        $results=@($issues|ForEach-Object {& $script:findingMapper {param($value) New-Finding -Issue $value -SkillId 'test-skill' -Stage 'skillspector-static'} $_})
        $results.Count|Should -Be 4
        $results[0].path|Should -BeExactly 'first.psm1'
        $results[1].path|Should -BeExactly 'second.psm1'
        $results[2].path|Should -BeExactly ''
        $results[3].path|Should -BeExactly ''
        $results[3].severity|Should -BeExactly 'high'
        $results[0].fingerprint|Should -Not -Be $results[1].fingerprint
    }

    # Scenario: A provider returns a severity outside the canonical contract.
    # Purpose: Improved evidence mapping must continue to reject unknown severities.
    It 'UnitT40_rejects_an_unknown_severity' {
        $issue=[pscustomobject]@{id='E1';severity='unrecognized';location=[pscustomobject]@{file='probe.ps1'}}
        {& $script:findingMapper {param($value) New-Finding -Issue $value -SkillId 'test-skill' -Stage 'skillspector-static'} $issue}|Should -Throw '*unsupported severity*'
    }
}

Describe 'Source conformance exact runtime child binding' {
    BeforeEach {
        $script:caseRoot=Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        $script:candidateRoot=Join-Path $script:caseRoot 'candidate'
        $candidateScripts=Join-Path $script:candidateRoot 'skills/manage-confluence-docs-as-code/scripts'
        $candidateRuntime=$candidateScripts
        $script:preparedRoot=Join-Path $script:caseRoot 'prepared-runtime'
        foreach($directory in @($candidateRuntime,(Join-Path $script:candidateRoot 'tests'),(Join-Path $script:preparedRoot 'node'),
            (Join-Path $script:preparedRoot 'node_modules/@fission-ai/openspec/bin'),(Join-Path $script:preparedRoot 'node_modules/markdown-it'))){
            $null=New-Item -ItemType Directory -Path $directory -Force
        }
        foreach($name in @('ConfluenceRuntime.psm1','StrictJson.psm1')){Copy-Item -LiteralPath (Join-Path $runtimeScripts $name) -Destination (Join-Path $candidateScripts $name)}
        foreach($name in @('package.json','package-lock.json')){
            Copy-Item -LiteralPath (Join-Path $runtimeScripts "$name") -Destination (Join-Path $candidateRuntime $name)
            Copy-Item -LiteralPath (Join-Path $candidateRuntime $name) -Destination (Join-Path $script:preparedRoot $name)
        }
        [IO.File]::WriteAllText((Join-Path $script:preparedRoot 'node/node.exe'),'Synthetic identity; never executed')
        [IO.File]::WriteAllText((Join-Path $script:preparedRoot 'node_modules/@fission-ai/openspec/bin/openspec.js'),'// synthetic parser')
        [IO.File]::WriteAllText((Join-Path $script:preparedRoot 'node_modules/@fission-ai/openspec/package.json'),'{"version":"1.13.0"}')
        [IO.File]::WriteAllText((Join-Path $script:preparedRoot 'node_modules/markdown-it/package.json'),'{"version":"14.3.1"}')
        $script:receiptPath=Join-Path $script:caseRoot 'receipt.json'
        $receipt=New-ConfluenceDocsRuntimeReceipt -RuntimeRoot $script:preparedRoot -RuntimeSourceRoot $candidateRuntime -NodeVersion 'v24.19.0' -NpmVersion '11.17.0'
        [IO.File]::WriteAllText($script:receiptPath,($receipt|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
        $script:toolchain=[ordered]@{pesterModulePath=$pesterManifest;pesterModuleSha256=(Get-FileHash -LiteralPath $pesterManifest -Algorithm SHA256).Hash.ToLowerInvariant();
            pesterVersion=$pesterModule.Version.ToString();confluenceDocsRuntime=[ordered]@{receiptPath=$script:receiptPath;
                receiptSha256=(Get-FileHash -LiteralPath $script:receiptPath -Algorithm SHA256).Hash.ToLowerInvariant();
                helperSha256=(Get-FileHash -LiteralPath (Join-Path $candidateScripts 'ConfluenceRuntime.psm1') -Algorithm SHA256).Hash.ToLowerInvariant()}}
        $script:childPath=Join-Path $script:caseRoot 'source-child.ps1'
        [IO.File]::WriteAllText($script:childPath,$childText,[Text.UTF8Encoding]::new($false))
        $probe=@'
Describe 'Runtime adapter probe' {
    It 'UnitT10_uses_the_receipt_root_and_node_instead_of_caller_environment' {
        $env:SYP171_RUNTIME_ROOT | Should -Not -Be 'untrusted-caller-runtime'
        Test-Path -LiteralPath (Join-Path $env:SYP171_RUNTIME_ROOT 'node_modules/@fission-ai/openspec/bin/openspec.js') | Should -BeTrue
        (Get-Command node -CommandType Application | Select-Object -First 1).Source | Should -Be (Join-Path $env:SYP171_RUNTIME_ROOT 'node/node.exe')
    }
}
'@
        [IO.File]::WriteAllText((Join-Path $script:candidateRoot 'tests/Probe.Tests.ps1'),$probe,[Text.UTF8Encoding]::new($false))
    }

    # Scenario: SYP171-SCN-017; the central child has only explicit Standard bindings and an untrusted caller runtime.
    # Purpose: The actual generated adapter propagates the verified receipt and executable to its separate Pester child.
    It 'InterT10_binds_the_verified_runtime_to_the_pester_child' {
        $result=Invoke-RuntimeAdapterFixture
        $result.exitCode|Should -Be 0 -Because $result.stderr
        $envelope=$result.stdout|ConvertFrom-Json
        $envelope.testResult.passed|Should -Be 1
        $envelope.candidateIdentity|Should -Be 'synthetic-runtime-adapter'
        $envelope.activeSkills|Should -Contain 'manage-confluence-docs-as-code'
    }

    # Scenario: SYP171-SCN-008/017; the run-owned toolchain lacks the declared runtime binding.
    # Purpose: Candidate tests cannot fall back to inherited developer environment when explicit setup evidence is missing.
    It 'InterT20_rejects_a_missing_runtime_binding' {
        $script:toolchain.Remove('confluenceDocsRuntime')
        $result=Invoke-RuntimeAdapterFixture
        $result.exitCode|Should -Be 1
        $result.stdout|Should -BeNullOrEmpty
    }

    # Scenario: SYP171-SCN-008/017; receipt bytes change after the toolchain freezes their hash.
    # Purpose: The generated adapter rejects drift before starting its Pester process.
    It 'InterT30_rejects_a_changed_receipt_before_pester' {
        [IO.File]::AppendAllText($script:receiptPath,' ')
        $result=Invoke-RuntimeAdapterFixture
        $result.exitCode|Should -Be 1
        $result.stderr|Should -Match 'RuntimeReceiptChanged'
        $result.stdout|Should -BeNullOrEmpty
    }

    # Scenario: SYP171-SCN-017; one suite passes but another fails during discovery.
    # Purpose: A positive test count cannot mask a failed container and falsely qualify source conformance.
    It 'InterT40_rejects_failed_pester_containers_even_with_a_passing_test' {
        [IO.File]::WriteAllText((Join-Path $script:candidateRoot 'tests/Broken.Tests.ps1'),"throw 'Synthetic discovery failure'")
        $result=Invoke-RuntimeAdapterFixture
        $result.exitCode|Should -Be 1
        $result.stderr|Should -Match 'Pester repository regression did not complete successfully'
        $result.stdout|Should -BeNullOrEmpty
    }
}
