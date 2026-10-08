# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $repositoryRoot=Split-Path -Parent $PSScriptRoot
    $runtimeModule=Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluenceRuntime.psm1'
    $sourceRuntime=Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts'
    $initializeRuntime=Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/Initialize-ConfluenceDocsRuntime.ps1'
    if(Test-Path -LiteralPath $runtimeModule){Import-Module $runtimeModule -Force}
    function Write-RuntimeFixtureReceipt {
        $receipt=New-ConfluenceDocsRuntimeReceipt -RuntimeRoot $script:fixtureRuntime -RuntimeSourceRoot $sourceRuntime -NodeVersion 'v24.19.0' -NpmVersion '11.17.0'
        [IO.File]::WriteAllText($script:receiptPath,($receipt|ConvertTo-Json -Depth 12)+"`n",[Text.UTF8Encoding]::new($false))
        return (Get-FileHash -LiteralPath $script:receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    function Test-RuntimeFixtureReceipt {
        param([string]$Digest=$script:receiptDigest)
        return Test-ConfluenceDocsRuntimeReceipt -ReceiptPath $script:receiptPath -ReceiptSha256 $Digest -RuntimeSourceRoot $sourceRuntime
    }
}

Describe 'SYP-171 exact prepared runtime identity' {
    BeforeEach {
        $script:fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('syp171-runtime-tests-'+[Guid]::NewGuid().ToString('N'))
        $script:fixtureRuntime=Join-Path $script:fixtureRoot 'runtime'
        foreach($directory in @('node','node_modules/@fission-ai/openspec/bin','node_modules/markdown-it')){
            $null=New-Item -ItemType Directory -Path (Join-Path $script:fixtureRuntime $directory) -Force
        }
        foreach($filename in @('package.json','package-lock.json')){Copy-Item -LiteralPath (Join-Path $sourceRuntime $filename) -Destination (Join-Path $script:fixtureRuntime $filename)}
        [IO.File]::WriteAllText((Join-Path $script:fixtureRuntime 'node/node.exe'),'Synthetic executable identity; never run')
        [IO.File]::WriteAllText((Join-Path $script:fixtureRuntime 'node_modules/@fission-ai/openspec/package.json'),'{"version":"1.13.0"}')
        [IO.File]::WriteAllText((Join-Path $script:fixtureRuntime 'node_modules/@fission-ai/openspec/bin/openspec.js'),'// synthetic parser fixture')
        [IO.File]::WriteAllText((Join-Path $script:fixtureRuntime 'node_modules/markdown-it/package.json'),'{"version":"14.3.1"}')
        $script:receiptPath=Join-Path $script:fixtureRoot 'runtime.receipt.json'
        $script:receiptDigest=''
    }
    AfterEach {
        $resolved=[IO.Path]::GetFullPath($script:fixtureRoot)
        if([IO.Path]::GetDirectoryName($resolved).TrimEnd('\','/') -cne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/') -or [IO.Path]::GetFileName($resolved) -cnotmatch '^syp171-runtime-tests-[a-f0-9]{32}$'){throw 'Unexpected fixture path'}
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }

    # Scenario: SYP171-SCN-008/017; setup produced an exact source-bound runtime closure.
    # Purpose: Offline verification returns a frozen runtime/Node identity without installing anything.
    It 'UnitT10_accepts_only_an_exact_source_bound_file_inventory' {
        $script:receiptDigest=Write-RuntimeFixtureReceipt
        $result=Test-RuntimeFixtureReceipt
        $result.status|Should -Be 'valid'
        $result.runtimeRoot|Should -Be $script:fixtureRuntime
        $result.nodePath|Should -Be (Join-Path $script:fixtureRuntime 'node/node.exe')
        $result.fileCount|Should -Be 6
    }

    # Scenario: SYP171-SCN-008/017; identical installed files are enumerated in a filesystem-dependent order.
    # Purpose: Receipt identities use ordinal paths rather than incidental directory enumeration or current culture.
    It 'UnitT15_records_a_deterministic_ordinal_file_inventory' {
        $script:receiptDigest=Write-RuntimeFixtureReceipt
        $receipt=Get-Content -LiteralPath $script:receiptPath -Raw|ConvertFrom-Json
        $paths=[string[]]@($receipt.files.path)
        $expected=[string[]]$paths.Clone()
        [Array]::Sort($expected,[StringComparer]::Ordinal)
        $paths|Should -Be $expected
    }

    # Scenario: SYP171-SCN-008; receipt bytes differ from the run-owned hash binding.
    # Purpose: A replaced receipt cannot redefine the executable or dependency files.
    It 'UnitT20_rejects_a_missing_or_changed_receipt' {
        $script:receiptDigest=Write-RuntimeFixtureReceipt
        (Test-RuntimeFixtureReceipt -Digest ('0'*64)).reasonCodes|Should -Contain 'RuntimeReceiptChanged'
        Remove-Item -LiteralPath $script:receiptPath
        (Test-RuntimeFixtureReceipt).reasonCodes|Should -Contain 'RuntimeReceiptUnavailable'
    }

    # Scenario: SYP171-SCN-008; installed file bytes changed after receipt creation.
    # Purpose: An executable or parser cannot drift while retaining version metadata.
    It 'UnitT30_rejects_modified_and_deleted_dependency_files' {
        $script:receiptDigest=Write-RuntimeFixtureReceipt
        $path=Join-Path $script:fixtureRuntime 'node_modules/@fission-ai/openspec/bin/openspec.js'
        [IO.File]::WriteAllText($path,'// modified parser')
        (Test-RuntimeFixtureReceipt).reasonCodes|Should -Contain 'RuntimeClosureChanged'
        Remove-Item -LiteralPath $path
        (Test-RuntimeFixtureReceipt).reasonCodes|Should -Contain 'RuntimeClosureChanged'
    }

    # Scenario: SYP171-SCN-008; a new runtime file appears outside the frozen closure.
    # Purpose: Extra dependencies or configuration cannot become invisible execution inputs.
    It 'UnitT40_rejects_extra_files_in_the_runtime' {
        $script:receiptDigest=Write-RuntimeFixtureReceipt
        [IO.File]::WriteAllText((Join-Path $script:fixtureRuntime '.npmrc'),'synthetic configuration')
        (Test-RuntimeFixtureReceipt).reasonCodes|Should -Contain 'RuntimeClosureChanged'
    }

    # Scenario: SYP171-SCN-008; candidate package or lock no longer matches setup input.
    # Purpose: An older prepared runtime cannot qualify a changed source revision.
    It 'UnitT50_rejects_different_source_lock_bytes' {
        $script:receiptDigest=Write-RuntimeFixtureReceipt
        $otherSource=Join-Path $script:fixtureRoot 'other-source'
        $null=New-Item -ItemType Directory -Path $otherSource
        foreach($filename in @('package.json','package-lock.json')){Copy-Item -LiteralPath (Join-Path $sourceRuntime $filename) -Destination (Join-Path $otherSource $filename)}
        [IO.File]::AppendAllText((Join-Path $otherSource 'package-lock.json'),"`n")
        (Test-ConfluenceDocsRuntimeReceipt -ReceiptPath $script:receiptPath -ReceiptSha256 $script:receiptDigest -RuntimeSourceRoot $otherSource).reasonCodes|Should -Contain 'RuntimeSourceChanged'
    }

    # Scenario: SYP171-SCN-008; caller supplies a receipt path outside the runtime inventory.
    # Purpose: Traversal and duplicate aliases never authorize reading arbitrary files as dependencies.
    It 'UnitT60_rejects_unsafe_inventory_paths' {
        $script:receiptDigest=Write-RuntimeFixtureReceipt
        $receipt=Get-Content -LiteralPath $script:receiptPath -Raw|ConvertFrom-Json -AsHashtable
        $receipt.files[0].path='../outside.bin'
        [IO.File]::WriteAllText($script:receiptPath,($receipt|ConvertTo-Json -Depth 12))
        $script:receiptDigest=(Get-FileHash -LiteralPath $script:receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
        (Test-RuntimeFixtureReceipt).reasonCodes|Should -Contain 'RuntimeReceiptInvalid'
    }

    # Scenario: SYP171-SCN-008/017; a junction redirects part of the prepared runtime to another directory.
    # Purpose: Receipt checks reject reparse paths instead of trusting a file inventory outside the declared closure.
    It 'UnitT65_rejects_a_reparse_point_in_the_runtime' {
        $script:receiptDigest=Write-RuntimeFixtureReceipt
        $target=Join-Path $script:fixtureRoot 'redirect-target'
        $null=New-Item -ItemType Directory -Path $target
        $null=New-Item -ItemType Junction -Path (Join-Path $script:fixtureRuntime 'node_modules/redirect') -Target $target
        (Test-RuntimeFixtureReceipt).reasonCodes|Should -Contain 'RuntimeReparsePoint'
        {Write-RuntimeFixtureReceipt}|Should -Throw '*RuntimeReparsePoint*'
    }

    # Scenario: SYP171-SCN-008; setup discovers the wrong fixed parser version.
    # Purpose: An executable version mismatch cannot be upgraded into a valid receipt by guessing.
    It 'UnitT70_refuses_to_record_wrong_dependency_versions' {
        [IO.File]::WriteAllText((Join-Path $script:fixtureRuntime 'node_modules/markdown-it/package.json'),'{"version":"99.0.0"}')
        {Write-RuntimeFixtureReceipt}|Should -Throw '*RuntimeVersionMismatch*'
    }

    # Scenario: SYP171-SCN-017; explicit setup is given an existing runtime with content.
    # Purpose: Installation never overwrites existing or customized files and fails before npm is invoked.
    It 'UnitT80_refuses_to_install_into_a_nonempty_runtime' {
        $nodePath=Join-Path $script:fixtureRuntime 'node/node.exe'
        $before=(Get-FileHash -LiteralPath $nodePath -Algorithm SHA256).Hash
        {& $initializeRuntime -RuntimeRoot $script:fixtureRuntime}|Should -Throw '*RuntimeRootNotEmpty*'
        (Get-FileHash -LiteralPath $nodePath -Algorithm SHA256).Hash|Should -Be $before
        Test-Path -LiteralPath "$($script:fixtureRuntime).receipt.json"|Should -BeFalse
    }
}
