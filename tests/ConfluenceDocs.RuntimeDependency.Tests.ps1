# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $script:repositoryRoot=Split-Path -Parent $PSScriptRoot
    $script:runtimeScripts=Join-Path $script:repositoryRoot 'skills/manage-confluence-docs-as-code/scripts'
    $script:fixturePath=Join-Path $PSScriptRoot 'fixtures/confluence-runtime-depth-guard.mjs'
    if([string]::IsNullOrWhiteSpace($env:SYP171_RUNTIME_ROOT)){
        throw 'A prepared SYP171_RUNTIME_ROOT is required for runtime dependency tests.'
    }
    $script:runtimeRoot=[IO.Path]::GetFullPath($env:SYP171_RUNTIME_ROOT)
    $script:nodePath=Join-Path $script:runtimeRoot 'node/node.exe'
    $script:receiptPath="$($script:runtimeRoot).receipt.json"
    if(-not(Test-Path -LiteralPath $script:nodePath -PathType Leaf)){
        throw 'The exact prepared runtime node/node.exe is unavailable.'
    }
    if(-not(Test-Path -LiteralPath $script:fixturePath -PathType Leaf)){
        throw 'The bounded runtime dependency fixture is unavailable.'
    }
    Import-Module (Join-Path $script:runtimeScripts 'ConfluenceRuntime.psm1') -Force
    $script:runtimeReceiptDigest=(Get-FileHash -LiteralPath $script:receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $script:runtimeReceiptCheck=Test-ConfluenceDocsRuntimeReceipt -ReceiptPath $script:receiptPath `
        -ReceiptSha256 $script:runtimeReceiptDigest -RuntimeSourceRoot $script:runtimeScripts
    if($script:runtimeReceiptCheck.status -cne 'valid' -or
        [IO.Path]::GetFullPath($script:runtimeReceiptCheck.runtimeRoot) -cne $script:runtimeRoot -or
        [IO.Path]::GetFullPath($script:runtimeReceiptCheck.nodePath) -cne [IO.Path]::GetFullPath($script:nodePath)){
        throw "Prepared source-bound runtime receipt is invalid: $(@($script:runtimeReceiptCheck.reasonCodes) -join ',')"
    }

    function Invoke-ConfluenceRuntimeDepthFixture {
        param([Parameter(Mandatory)][ValidateSet('identity','patterns','ast','options','compatibility')][string]$Mode)
        $start=[Diagnostics.ProcessStartInfo]::new()
        $start.FileName=$script:nodePath
        foreach($argument in @($script:fixturePath,$Mode,$script:runtimeScripts,$script:runtimeRoot)){
            $start.ArgumentList.Add([string]$argument)
        }
        $start.WorkingDirectory=$script:repositoryRoot
        $start.UseShellExecute=$false
        $start.CreateNoWindow=$true
        $start.RedirectStandardOutput=$true
        $start.RedirectStandardError=$true
        $process=[Diagnostics.Process]::new()
        $process.StartInfo=$start
        try{
            if(-not $process.Start()) { throw 'Runtime depth fixture did not start.' }
            $stdout=$process.StandardOutput.ReadToEndAsync()
            $stderr=$process.StandardError.ReadToEndAsync()
            if(-not $process.WaitForExit(30000)){
                $process.Kill($true)
                $null=$process.WaitForExit(5000)
                throw "Runtime depth fixture timed out in mode '$Mode'."
            }
            $output=$stdout.GetAwaiter().GetResult()
            $errors=$stderr.GetAwaiter().GetResult()
            if($output.Length -gt 16384 -or $errors.Length -gt 4096){
                throw "Runtime depth fixture exceeded its bounded output in mode '$Mode'."
            }
            if($process.ExitCode -ne 0){
                throw "Runtime depth fixture failed in mode '$Mode': $($errors.Trim())"
            }
            $result=$output|ConvertFrom-Json -Depth 20
            if($result.mode -cne $Mode){ throw 'Runtime depth fixture returned a different mode.' }
            return $result
        }finally{
            $process.Dispose()
        }
    }
}

Describe 'SYP171 transitive braces runtime depth guard' {
    # Scenario: SYP171-SCN-008; the actual prepared runtime supplies OpenSpec's fast-glob -> micromatch -> braces require route.
    # Purpose: Separate source/lock/installed-byte identity from the behavioral depth assertions below.
    It 'InterT00_binds_the_actual_transitive_route_to_the_exact_prepared_fork_bytes' {
        $receipt=$script:runtimeReceiptCheck
        $receipt.status|Should -Be 'valid' -Because ($receipt.reasonCodes -join ',')
        [IO.Path]::GetFullPath($receipt.runtimeRoot)|Should -Be $script:runtimeRoot
        [IO.Path]::GetFullPath($receipt.nodePath)|Should -Be $script:nodePath

        $result=Invoke-ConfluenceRuntimeDepthFixture -Mode identity
        $result.nodeVersion|Should -Match '^v24\.'
        $result.manifestOverride|Should -BeExactly 'npm:@dieub/braces-depth-guard@3.0.3-pn.3'
        $result.lockfileVersion|Should -Be 3
        $result.packages.openspec.version|Should -BeExactly '1.13.0'
        $result.packages.openspec.lockVersion|Should -BeExactly '1.13.0'
        $result.packages.fastGlob.version|Should -BeExactly '3.3.3'
        $result.packages.fastGlob.lockVersion|Should -BeExactly '3.3.3'
        $result.packages.micromatch.version|Should -BeExactly '4.0.8'
        $result.packages.micromatch.lockVersion|Should -BeExactly '4.0.8'
        $result.packages.braces.name|Should -BeExactly '@dieub/braces-depth-guard'
        $result.packages.braces.version|Should -BeExactly '3.0.3-pn.3'
        $result.packages.braces.license|Should -BeExactly 'MIT'
        $result.packages.braces.lockVersion|Should -BeExactly '3.0.3-pn.3'
        $result.packages.braces.resolved|Should -BeExactly 'https://registry.npmjs.org/@dieub/braces-depth-guard/-/braces-depth-guard-3.0.3-pn.3.tgz'
        $result.packages.braces.integrity|Should -BeExactly 'sha512-QY+Uq4s42STyIMPoRkBuUZfYyvz0uZuwuUburLwMx5N+lWqnHHaBxcKPtgKVKjTyFnS1q4ivKu9Wxi4VG7FE9Q=='
        [IO.Path]::GetFullPath((Join-Path $script:runtimeRoot 'node_modules/braces'))|Should -Be ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($result.resolved.braces)))

        $expectedFiles=@{
            'LICENSE'='35bdd8a44339719441900fb50fbefc5e2dca1ca662cbaed7a687de842c8b70f2'
            'README.md'='f06ecffb78d40201813ecf840cd06b280a5a56ee85a7f9a6224df3bc1453c53d'
            'index.js'='332ea07c7b006361aad12aa994ca75dc1db8e8382b884909e2f38f10b85c88a4'
            'lib/compile.js'='20ea98b7f04c8969ca478db458e3e08e0f3b47cc9f810a75336370bfedbf9436'
            'lib/constants.js'='f9fb688959232eee3e6ad7906a5b0e3234815db49ee857ef86983d65b917dc7c'
            'lib/expand.js'='3fb6a53995e05263b594485975c2ac9312e0c3b6b8bf37bd3b4ec6e5deb43a9e'
            'lib/parse.js'='43d983a546dce1ed446dbe8535438a717de9e85040ab701edae3a5a50acdc1d4'
            'lib/stringify.js'='dd47ae5c9ac1f1a0e65de7160e25500a9dd724279a65fe96011c7f1b7b7ed36c'
            'lib/utils.js'='34b39e1b7d634c5460c30b1fe271dd337cfc383709b3659c31e5d84b12e92e61'
            'package.json'='6a966416d58086ffe4cb6d5f6af14c380953bba178d2865c536a9ecb4dab4e74'
        }
        (@($result.publishedFileNames|Sort-Object) -join "`n")|Should -Be (@($expectedFiles.Keys|Sort-Object) -join "`n")
        foreach($relative in $expectedFiles.Keys){
            $result.publishedFileHashes.PSObject.Properties[$relative].Value|Should -BeExactly $expectedFiles[$relative] -Because "installed published file '$relative' matches the retained immutable archive receipt"
        }
        $license=Get-Content -LiteralPath (Join-Path $script:runtimeRoot 'node_modules/braces/LICENSE') -Raw
        $license|Should -Match 'Permission is hereby granted'
    }

    # Scenario: SYP171-SCN-008; bounded brace, parenthesis, and mixed nesting is at the supported cap.
    # Purpose: Every public string processor preserves legal input at depth 100 through the native transitive route.
    It 'InterT10_accepts_depth_100_for_brace_paren_and_mixed_inputs' {
        $result=Invoke-ConfluenceRuntimeDepthFixture -Mode patterns
        $rows=@($result.rows|Where-Object depth -EQ 100)
        $rows.Count|Should -Be 12
        foreach($row in $rows){
            $row.accepted|Should -BeTrue -Because "$($row.method) must accept $($row.kind) depth $($row.depth); error=$($row.errorName): $($row.errorMessage)"
        }
    }

    # Scenario: SYP171-SCN-008; the next brace, parenthesis, or mixed container exceeds the enforced cap.
    # Purpose: Confirm an explicit parser depth error instead of acceptance, generic stack overflow, or test-name-only identity drift.
    It 'InterT20_rejects_depth_101_for_brace_paren_and_mixed_inputs_with_a_typed_depth_error' {
        $result=Invoke-ConfluenceRuntimeDepthFixture -Mode patterns
        $rows=@($result.rows|Where-Object depth -EQ 101)
        $rows.Count|Should -Be 12
        foreach($row in $rows){
            $row.accepted|Should -BeFalse -Because "$($row.method) accepted $($row.kind) depth $($row.depth)"
            $row.errorName|Should -BeExactly 'SyntaxError'
            $row.errorMessage|Should -Match 'exceeds max depth \(100\)'
        }
    }

    # Scenario: SYP171-SCN-008; an independently constructed parser-shaped AST bypasses string parsing.
    # Purpose: AST walkers enforce the same 100/101 boundary for compile, expand, and stringify.
    It 'InterT30_bounds_direct_parser_shaped_ast_walkers_at_depth_100_and_101' {
        $result=Invoke-ConfluenceRuntimeDepthFixture -Mode ast
        $accepted=@($result.rows|Where-Object depth -EQ 100)
        $rejected=@($result.rows|Where-Object depth -EQ 101)
        $accepted.Count|Should -Be 3
        $rejected.Count|Should -Be 3
        foreach($row in $accepted){
            $row.accepted|Should -BeTrue -Because "$($row.method) should accept parser-shaped AST depth 100"
        }
        foreach($row in $rejected){
            $row.accepted|Should -BeFalse -Because "$($row.method) accepted parser-shaped AST depth 101"
            $row.errorName|Should -BeExactly 'RangeError'
            $row.errorMessage|Should -Match 'AST depth \(101\), exceeds max depth \(100\)'
        }
    }

    # Scenario: SYP171-SCN-008; non-finite and overlarge options cannot disable the hard cap.
    # Purpose: Validate option clamping, zero and negative edges across string processors and direct AST walkers.
    It 'InterT40_caps_nonfinite_and_large_depth_options_and_handles_numeric_edges' {
        $result=Invoke-ConfluenceRuntimeDepthFixture -Mode options
        $optionRows=@($result.rows|Where-Object { $_.option -in @('infinity','nan','large-cap') })
        $optionRows.Count|Should -Be 24
        foreach($row in @($optionRows|Where-Object depth -EQ 100)){
            $row.accepted|Should -BeTrue -Because "$($row.method) should accept depth 100 with option $($row.option)"
        }
        foreach($row in @($optionRows|Where-Object depth -EQ 101)){
            $row.accepted|Should -BeFalse -Because "$($row.method) bypassed the hard cap with option $($row.option)"
            $row.errorName|Should -BeExactly 'SyntaxError'
            $row.errorMessage|Should -Match 'exceeds max depth \(100\)'
        }
        $astOptionRows=@($result.rows|Where-Object { $_.option -match '^ast-' })
        $astOptionRows.Count|Should -Be 9
        foreach($row in $astOptionRows){
            $row.accepted|Should -BeFalse -Because "$($row.method) AST walker bypassed the hard cap with option $($row.option)"
            $row.errorName|Should -BeExactly 'RangeError'
            $row.errorMessage|Should -Match 'AST depth \(101\), exceeds max depth \(100\)'
        }
        $zeroFlat=@($result.rows|Where-Object option -EQ 'zero-flat')
        $zeroNested=@($result.rows|Where-Object option -EQ 'zero-nested')
        $negative=@($result.rows|Where-Object option -EQ 'negative')
        $zeroFlat.Count|Should -Be 4
        $zeroNested.Count|Should -Be 4
        $negative.Count|Should -Be 4
        foreach($row in $zeroFlat){$row.accepted|Should -BeTrue}
        foreach($row in $zeroNested){$row.accepted|Should -BeFalse;$row.errorName|Should -BeExactly 'SyntaxError'}
        foreach($row in $negative){$row.accepted|Should -BeFalse;$row.errorName|Should -BeExactly 'RangeError'}
    }

    # Scenario: SYP171-SCN-008; guard-enabled braces remains compatible with ordinary glob/range/escape behavior.
    # Purpose: Verify the transitive fast-glob and micromatch consumers retain expected brace matching and expansion output.
    It 'InterT50_preserves_ordinary_brace_glob_range_and_escape_outputs' {
        $result=Invoke-ConfluenceRuntimeDepthFixture -Mode compatibility
        (@($result.listExpansion) -join "`n")|Should -BeExactly "a/b/d`na/c/d"
        (@($result.rangeExpansion) -join "`n")|Should -BeExactly "1`n2`n3"
        (@($result.escapedBraceLiteral) -join "`n")|Should -BeExactly 'a/{b,c}'
        (@($result.micromatchExpansion) -join ',')|Should -BeExactly 'True,False'
        (@($result.fastGlobFiles) -join "`n")|Should -BeExactly 'tests/fixtures/confluence-runtime-depth-guard.mjs'
    }
}
