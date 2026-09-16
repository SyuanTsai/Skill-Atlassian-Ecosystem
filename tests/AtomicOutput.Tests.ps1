# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Caller-specified canonical output atomicity' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:RepositoryValidator = Join-Path $script:RepositoryRoot 'scripts/Test-Repository.ps1'
        $script:GitPath = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path
    }

    It 'UnitT10_preserves_existing_output_bytes_and_fails_closed' {
        # Scenario: The requested output path already contains a canary.
        # Purpose: FileMode.CreateNew must reject the path before any byte is changed.
        Test-Path -LiteralPath $script:RepositoryValidator -PathType Leaf | Should -BeTrue
        $root = Join-Path $TestDrive 'existing-output-fixture'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'catalog') -Destination (Join-Path $root 'catalog') -Recurse
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'config') -Destination (Join-Path $root 'config') -Recurse
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'skills') -Destination (Join-Path $root 'skills') -Recurse
        & $script:GitPath -C $root init --quiet
        & $script:GitPath -C $root add -- catalog config skills
        $output = Join-Path $TestDrive 'existing-output.json'
        $canary = [Text.UTF8Encoding]::new($false).GetBytes('{"untouched":true}')
        [IO.File]::WriteAllBytes($output, $canary)
        { & $script:RepositoryValidator -RepositoryRoot $root -OutputPath $output } | Should -Throw
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($output)) |
            Should -Be ([Convert]::ToBase64String($canary))
    }

    It 'UnitT20_writes_complete_utf8_json_for_a_new_output_path' {
        # Scenario: A valid candidate requests a new report path.
        # Purpose: Successful output must be UTF-8 without BOM and parse as one complete JSON document.
        $root = Join-Path $TestDrive 'new-output-fixture'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'catalog') -Destination (Join-Path $root 'catalog') -Recurse
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'config') -Destination (Join-Path $root 'config') -Recurse
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'skills') -Destination (Join-Path $root 'skills') -Recurse
        & $script:GitPath -C $root init --quiet
        & $script:GitPath -C $root add -- catalog config skills
        $output = Join-Path $TestDrive 'complete-output.json'
        { & $script:RepositoryValidator -RepositoryRoot $root -OutputPath $output } | Should -Not -Throw
        $bytes = [IO.File]::ReadAllBytes($output)
        $bytes.Length | Should -BeGreaterThan 2
        @($bytes[0..2]) | Should -Not -Be @(0xEF, 0xBB, 0xBF)
        { Get-Content -LiteralPath $output -Raw | ConvertFrom-Json -Depth 30 } | Should -Not -Throw
    }

    It 'InterT30_allows_exactly_one_of_two_processes_to_create_the_same_output' {
        # Scenario: Two independent PowerShell processes validate the same read-only fixture and path.
        # Purpose: Prove CreateNew ownership, not a timing delay, determines the single winner.
        Test-Path -LiteralPath $script:RepositoryValidator -PathType Leaf | Should -BeTrue
        $root = Join-Path $TestDrive 'concurrent-output-fixture'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'catalog') -Destination (Join-Path $root 'catalog') -Recurse
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'config') -Destination (Join-Path $root 'config') -Recurse
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'skills') -Destination (Join-Path $root 'skills') -Recurse
        & $script:GitPath -C $root init --quiet
        & $script:GitPath -C $root add -- catalog config skills
        $output = Join-Path $TestDrive 'concurrent-output.json'
        $pwsh = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        $arguments = @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:RepositoryValidator,
            '-RepositoryRoot', $root, '-OutputPath', $output
        )
        $processes = @()
        foreach ($unused in 1..2) {
            $info = [Diagnostics.ProcessStartInfo]::new()
            $info.FileName = $pwsh
            $info.UseShellExecute = $false
            $info.RedirectStandardOutput = $false
            $info.RedirectStandardError = $false
            foreach ($argument in $arguments) { [void]$info.ArgumentList.Add($argument) }
            $process = [Diagnostics.Process]::new()
            $process.StartInfo = $info
            [void]$process.Start()
            $processes += $process
        }
        foreach ($process in $processes) {
            $process.WaitForExit()
        }
        $successCount = @($processes | Where-Object ExitCode -eq 0).Count
        $successCount | Should -Be 1
        { Get-Content -LiteralPath $output -Raw | ConvertFrom-Json -Depth 30 } | Should -Not -Throw
    }
}
