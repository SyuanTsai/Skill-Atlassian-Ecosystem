# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Atlassian pre-push exact candidate guard' {
    BeforeAll {
        $script:SourceRoot = Split-Path -Parent $PSScriptRoot
        $script:HookSource = Join-Path $script:SourceRoot '.githooks/Invoke-PrePushValidation.ps1'
        $script:TempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]@('\','/'))

    function New-PrePushFixture {
        $root = Join-Path $script:TempParent ('atlassian-prepush-test-' + [guid]::NewGuid().ToString('N'))
        $repo = Join-Path $root 'repo'
        $remote = Join-Path $root 'remote.git'
        [void][IO.Directory]::CreateDirectory($root)
        & git init --bare $remote | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not initialize local bare remote.' }
        & git init -b main $repo | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not initialize local candidate repo.' }
        & git -C $repo config user.email 'prepush-test@example.invalid'
        & git -C $repo config user.name 'PrePush Test'
        & git -C $repo remote add origin $remote
        [void][IO.Directory]::CreateDirectory((Join-Path $repo '.githooks'))
        [void][IO.Directory]::CreateDirectory((Join-Path $repo 'scripts'))
        Copy-Item -LiteralPath $script:HookSource -Destination (Join-Path $repo '.githooks/Invoke-PrePushValidation.ps1')
        Copy-Item -LiteralPath (Join-Path $script:SourceRoot '.githooks/pre-push') -Destination (Join-Path $repo '.githooks/pre-push')
        if (-not $IsWindows) {
            & chmod +x (Join-Path $repo '.githooks/pre-push')
            if ($LASTEXITCODE -ne 0) { throw 'Could not mark disposable shell hook executable.' }
        }
        $marker = Join-Path $root 'canonical-invoked.txt'
        $stub = @'
param([switch]$SourceConformance, [string]$ArtifactsRoot, [string]$BaseCommit, [string]$ExpectedGoRuntimeVersion, [string]$OutputPath)
$repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$head = ([string](& git -C $repo rev-parse HEAD)).Trim()
[IO.File]::WriteAllText($env:AT_PREPUSH_MARKER, "$head|$BaseCommit|$ExpectedGoRuntimeVersion")
$sourceSha = if ($env:AT_PREPUSH_INVALID_REPORT -eq '1') { '0000000000000000000000000000000000000000' } else { $head }
$stages = @(1..10 | ForEach-Object { [pscustomobject]@{ status=($(if ($_ -le 5) { 'passed' } elseif ($_ -eq 6) { 'blocked' } else { 'skipped' })); events=@() } })
$report = [pscustomobject]@{
    schemaVersion=1; evidence='standard-validation-evidence-v1'; contract='standard-validation-contract-v1'
    candidate=[pscustomobject]@{ sourceRevision=$head; candidateId='fixture'; contentSha256='fixture-hash' }
    releaseEligible=$false; exitCode=10; state='blocked'; stages=$stages
    sourceConformance=[pscustomobject]@{
        schemaVersion=1; contract='standard-source-conformance-v1'; scope='source-stages-1-5'; status='passed'
        sourceRevision=$sourceSha; candidateId='fixture'; contentSha256='fixture-hash'; releaseEligible=$false
        failureReasons=@(); checkedStages=@(1..5)
        pester=[pscustomobject]@{ eventCount=1; testInventoryCount=1; total=1; passed=1; failed=0 }
        canonicalValidation=[pscustomobject]@{ state='blocked'; exitCode=10; releaseEligible=$false; stage6Status='blocked' }
    }
}
[IO.File]::WriteAllText($OutputPath, ($report | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
exit 10
'@
        [IO.File]::WriteAllText((Join-Path $repo 'scripts/Validate.ps1'), $stub, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $repo 'README.md'), 'fixture', [Text.UTF8Encoding]::new($false))
        & git -C $repo add .
        & git -C $repo update-index --chmod=+x .githooks/pre-push
        & git -C $repo commit -m 'fixture one' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not commit fixture.' }
        $first = ([string](& git -C $repo rev-parse HEAD)).Trim()
        & git -C $repo push origin main | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not seed local remote.' }
        [IO.File]::WriteAllText((Join-Path $repo 'README.md'), 'fixture two', [Text.UTF8Encoding]::new($false))
        & git -C $repo add README.md
        & git -C $repo commit -m 'fixture two' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not advance fixture.' }
        $head = ([string](& git -C $repo rev-parse HEAD)).Trim()
        $bin = Join-Path $root 'bin'
        [void][IO.Directory]::CreateDirectory($bin)
        if ($IsWindows) {
            [IO.File]::WriteAllText((Join-Path $bin 'go.cmd'), "@echo off`r`necho go version go1.25.1 windows/amd64`r`n", [Text.ASCIIEncoding]::new())
        }
        else {
            $go = Join-Path $bin 'go'
            [IO.File]::WriteAllText($go, "#!/bin/sh`necho go version go1.25.1 linux/amd64`n", [Text.UTF8Encoding]::new($false))
            & chmod +x $go
            if ($LASTEXITCODE -ne 0) { throw 'Could not mark disposable Go stub executable.' }
        }
        return [pscustomobject]@{ root=$root; repo=$repo; remote=$remote; first=$first; head=$head; marker=$marker; bin=$bin }
    }

    function Remove-PrePushFixture($fixture) {
        $root = [IO.Path]::GetFullPath([string]$fixture.root)
        if ([IO.Path]::GetDirectoryName($root) -cne $script:TempParent -or
            [IO.Path]::GetFileName($root) -cnotmatch '^atlassian-prepush-test-[0-9a-f]{32}$') {
            throw 'Refusing unsafe pre-push fixture cleanup.'
        }
        if (Test-Path -LiteralPath $root) {
            $item = Get-Item -Force -LiteralPath $root
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Fixture root is a reparse point.' }
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }
    }

    It 'UnitT05_RoutesOneCanonicalCallAndChecksTheSameSourceFieldsAsCi' {
        # Scenario: CI and the repository-local hook consume the canonical source report.
        # Purpose: Bind the hook to one canonical call and the same source-only fields as CI.
        $workflow = Get-Content -LiteralPath (Join-Path $script:SourceRoot '.github/workflows/validate.yml') -Raw
        $hook = Get-Content -LiteralPath $script:HookSource -Raw
        @([regex]::Matches($hook, '& ./scripts/Validate\.ps1 -SourceConformance')).Count | Should -Be 1
        @([regex]::Matches($workflow, '& ./scripts/Validate\.ps1 -SourceConformance')).Count | Should -Be 1
        foreach ($field in @('candidate.sourceRevision', 'source.sourceRevision', 'source.contentSha256', 'source.failureReasons', 'source.pester.failed', 'canonical.stage6Status')) {
            $hook | Should -Match ([regex]::Escape($field))
            $workflow | Should -Match ([regex]::Escape($field))
        }
        $pattern = '(?s)if \(\$report\.schemaVersion -eq 1 -and.*?\) \{\s*\$status = ''passed'''
        $ciProjection = [regex]::Match($workflow, $pattern)
        $hookProjection = [regex]::Match($hook, $pattern)
        $ciProjection.Success | Should -BeTrue
        $hookProjection.Success | Should -BeTrue
        $normalizedCi = ($ciProjection.Value.Replace('$env:GITHUB_SHA', '$candidate').Replace('$actualExitCode', '$canonicalExit') -creplace '\s+', '')
        $normalizedHook = ($hookProjection.Value -creplace '\s+', '')
        $normalizedHook | Should -BeExactly $normalizedCi
    }

    It 'UnitT10_RejectsNonHeadCandidateBeforeCanonicalCall' {
        # Scenario: Git proposes an earlier commit although the checkout points at a newer HEAD.
        # Purpose: Prevent validation of a different candidate from the one being pushed.
        $fixture = New-PrePushFixture
        try {
            $line = "refs/heads/main $($fixture.first) refs/heads/main $($fixture.first)"
            $output = $line | & pwsh -NoProfile -NonInteractive -File (Join-Path $fixture.repo '.githooks/Invoke-PrePushValidation.ps1') -RemoteName origin -RemoteUrl $fixture.remote 2>&1
            $LASTEXITCODE | Should -Not -Be 0
            ($output -join "`n") | Should -Match 'does not match HEAD'
            (Test-Path -LiteralPath $fixture.marker) | Should -BeFalse
        }
        finally { Remove-PrePushFixture $fixture }
    }

    It 'UnitT20_RejectsDirtyCandidateBeforeCanonicalCall' {
        # Scenario: The push points at HEAD, but an untracked local file makes the checkout ambiguous.
        # Purpose: Stop a working-tree candidate from being mistaken for the committed push candidate.
        $fixture = New-PrePushFixture
        try {
            [IO.File]::WriteAllText((Join-Path $fixture.repo 'private-local.txt'), 'dirty', [Text.UTF8Encoding]::new($false))
            $line = "refs/heads/main $($fixture.head) refs/heads/main $($fixture.first)"
            $output = $line | & pwsh -NoProfile -NonInteractive -File (Join-Path $fixture.repo '.githooks/Invoke-PrePushValidation.ps1') -RemoteName origin -RemoteUrl $fixture.remote 2>&1
            $LASTEXITCODE | Should -Not -Be 0
            ($output -join "`n") | Should -Match 'dirty'
            (Test-Path -LiteralPath $fixture.marker) | Should -BeFalse
        }
        finally { Remove-PrePushFixture $fixture }
    }

    It 'UnitT25_RejectsTagPushBeforeCanonicalCall' {
        # Scenario: The local and remote refs name a tag rather than the same branch.
        # Purpose: Prevent source-only validation from authorizing a release-affecting tag push.
        $fixture = New-PrePushFixture
        try {
            $line = "refs/tags/v1.0 $($fixture.head) refs/tags/v1.0 $('0' * 40)"
            $output = $line | & pwsh -NoProfile -NonInteractive -File (Join-Path $fixture.repo '.githooks/Invoke-PrePushValidation.ps1') -RemoteName origin -RemoteUrl $fixture.remote 2>&1
            $LASTEXITCODE | Should -Not -Be 0
            ($output -join "`n") | Should -Match 'matching branch refs'
            (Test-Path -LiteralPath $fixture.marker) | Should -BeFalse
        }
        finally { Remove-PrePushFixture $fixture }
    }

    It 'UnitT27_RejectsMultipleRefUpdatesBeforeCanonicalCall' {
        # Scenario: One push carries two branch updates with different candidate bindings.
        # Purpose: Avoid treating a single successful source report as approval for both refs.
        $fixture = New-PrePushFixture
        try {
            $line = "refs/heads/main $($fixture.head) refs/heads/main $($fixture.first)"
            $output = @($line, $line) | & pwsh -NoProfile -NonInteractive -File (Join-Path $fixture.repo '.githooks/Invoke-PrePushValidation.ps1') -RemoteName origin -RemoteUrl $fixture.remote 2>&1
            $LASTEXITCODE | Should -Not -Be 0
            ($output -join "`n") | Should -Match 'exactly one pre-push ref update'
            (Test-Path -LiteralPath $fixture.marker) | Should -BeFalse
        }
        finally { Remove-PrePushFixture $fixture }
    }

    It 'UnitT30_AcceptsSourceProjectionForExactHeadWithBlockedStageSix' {
        # Scenario: One clean HEAD update has a matching canonical source report and Stage 6 remains blocked.
        # Purpose: Mirror CI source-only pass/block without promoting a formal release.
        $fixture = New-PrePushFixture
        $oldPath = $env:PATH
        try {
            $env:PATH = "$($fixture.bin)$([IO.Path]::PathSeparator)$oldPath"
            $env:AT_PREPUSH_MARKER = $fixture.marker
            $line = "refs/heads/main $($fixture.head) refs/heads/main $($fixture.first)"
            $output = $line | & pwsh -NoProfile -NonInteractive -File (Join-Path $fixture.repo '.githooks/Invoke-PrePushValidation.ps1') -RemoteName origin -RemoteUrl $fixture.remote 2>&1
            $LASTEXITCODE | Should -Be 0
            ($output -join "`n") | Should -Match 'source conformance passed'
            (Get-Content -LiteralPath $fixture.marker -Raw) | Should -Match ([regex]::Escape("$($fixture.head)|$($fixture.first)|1.25.1"))
        }
        finally {
            $env:PATH = $oldPath
            Remove-Item Env:AT_PREPUSH_MARKER -ErrorAction SilentlyContinue
            Remove-PrePushFixture $fixture
        }
    }

    It 'UnitT35_RejectsMismatchedCanonicalSourceRevision' {
        # Scenario: The canonical report claims source success for a revision other than pushed HEAD.
        # Purpose: Fail closed on a candidate-binding mismatch even when the source projection says passed.
        $fixture = New-PrePushFixture
        $oldPath = $env:PATH
        try {
            $env:PATH = "$($fixture.bin)$([IO.Path]::PathSeparator)$oldPath"
            $env:AT_PREPUSH_MARKER = $fixture.marker
            $env:AT_PREPUSH_INVALID_REPORT = '1'
            $line = "refs/heads/main $($fixture.head) refs/heads/main $($fixture.first)"
            $output = $line | & pwsh -NoProfile -NonInteractive -File (Join-Path $fixture.repo '.githooks/Invoke-PrePushValidation.ps1') -RemoteName origin -RemoteUrl $fixture.remote 2>&1
            $LASTEXITCODE | Should -Not -Be 0
            ($output -join "`n") | Should -Match 'did not pass'
            (Test-Path -LiteralPath $fixture.marker) | Should -BeTrue
        }
        finally {
            $env:PATH = $oldPath
            Remove-Item Env:AT_PREPUSH_MARKER -ErrorAction SilentlyContinue
            Remove-Item Env:AT_PREPUSH_INVALID_REPORT -ErrorAction SilentlyContinue
            Remove-PrePushFixture $fixture
        }
    }

    It 'InterT40_RoutesActualLocalPushThroughCanonicalEntry' {
        # Scenario: A disposable candidate repo enables its own hook and pushes to a disposable bare remote.
        # Purpose: Verify Git invokes the shell hook and propagates exact candidate source success to the push.
        $fixture = New-PrePushFixture
        $oldPath = $env:PATH
        try {
            $env:PATH = "$($fixture.bin)$([IO.Path]::PathSeparator)$oldPath"
            $env:AT_PREPUSH_MARKER = $fixture.marker
            & git -C $fixture.repo config --local core.hooksPath .githooks
            & git -C $fixture.repo push origin main 2>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0
            (Test-Path -LiteralPath $fixture.marker) | Should -BeTrue
            $remoteHead = ([string](& git --git-dir=$($fixture.remote) rev-parse refs/heads/main)).Trim()
            $remoteHead | Should -Be $fixture.head
        }
        finally {
            $env:PATH = $oldPath
            Remove-Item Env:AT_PREPUSH_MARKER -ErrorAction SilentlyContinue
            Remove-PrePushFixture $fixture
        }
    }

    It 'InterT45_UsesOriginMainBaseForAnActualNewBranchPush' {
        # Scenario: A disposable feature branch is pushed to a new ref on a disposable bare remote.
        # Purpose: Bind the new-branch candidate to origin/main and invoke canonical validation once.
        $fixture = New-PrePushFixture
        $oldPath = $env:PATH
        try {
            $env:PATH = "$($fixture.bin)$([IO.Path]::PathSeparator)$oldPath"
            $env:AT_PREPUSH_MARKER = $fixture.marker
            & git -C $fixture.repo switch -c feature/prepush | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Could not create disposable feature branch.' }
            & git -C $fixture.repo config --local core.hooksPath .githooks
            & git -C $fixture.repo push origin feature/prepush 2>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0
            (Get-Content -LiteralPath $fixture.marker -Raw) | Should -Match ([regex]::Escape("$($fixture.head)|$($fixture.first)|1.25.1"))
            $remoteHead = ([string](& git --git-dir=$($fixture.remote) rev-parse refs/heads/feature/prepush)).Trim()
            $remoteHead | Should -Be $fixture.head
        }
        finally {
            $env:PATH = $oldPath
            Remove-Item Env:AT_PREPUSH_MARKER -ErrorAction SilentlyContinue
            Remove-PrePushFixture $fixture
        }
    }
}
