# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Atlassian pre-push exact candidate guard' {
    BeforeAll {
        $script:SourceRoot = Split-Path -Parent $PSScriptRoot
        $script:HookSource = Join-Path $script:SourceRoot '.githooks/Invoke-PrePushValidation.ps1'
        $script:TempParent = [IO.Path]::GetFullPath($TestDrive).TrimEnd([char[]]@('\','/'))

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
        [void][IO.Directory]::CreateDirectory((Join-Path $repo 'config'))
        Copy-Item -LiteralPath $script:HookSource -Destination (Join-Path $repo '.githooks/Invoke-PrePushValidation.ps1')
        Copy-Item -LiteralPath (Join-Path $script:SourceRoot '.githooks/pre-push') -Destination (Join-Path $repo '.githooks/pre-push')
        if (-not $IsWindows) {
            & chmod +x (Join-Path $repo '.githooks/pre-push')
            if ($LASTEXITCODE -ne 0) { throw 'Could not mark disposable shell hook executable.' }
        }
        $marker = Join-Path $root 'canonical-invoked.txt'
        $stub = @'
param([switch]$SourceConformance, [string]$RepositoryRoot, [string]$ArtifactsRoot, [string]$BaseCommit, [string]$ExpectedGoRuntimeVersion, [string]$OutputPath)
$repo = if ($RepositoryRoot) { $RepositoryRoot } else { (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path }
$head = ([string](& git -C $repo rev-parse HEAD)).Trim()
[IO.File]::WriteAllText($env:AT_PREPUSH_MARKER, "$head|$BaseCommit|$ExpectedGoRuntimeVersion|$env:GITHUB_EVENT_NAME")
[IO.File]::WriteAllText(($env:AT_PREPUSH_MARKER + '.artifacts'), $ArtifactsRoot)
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
        [IO.File]::WriteAllText((Join-Path $repo 'scripts/Invoke-SourceConformance.ps1'), 'throw "Fixture adapter must not execute."', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $repo 'config/standard-v1.json'), '{}', [Text.UTF8Encoding]::new($false))
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
            foreach ($name in @('python','node','npm')) { [IO.File]::WriteAllText((Join-Path $bin "$name.cmd"), "@echo off`r`nexit /b 0`r`n", [Text.ASCIIEncoding]::new()) }
        }
        else {
            $go = Join-Path $bin 'go'
            [IO.File]::WriteAllText($go, "#!/bin/sh`necho go version go1.25.1 linux/amd64`n", [Text.UTF8Encoding]::new($false))
            & chmod +x $go
            if ($LASTEXITCODE -ne 0) { throw 'Could not mark disposable Go stub executable.' }
            foreach ($name in @('python','node','npm')) {
                $path = Join-Path $bin $name
                [IO.File]::WriteAllText($path, "#!/bin/sh`nexit 0`n", [Text.UTF8Encoding]::new($false))
                & chmod +x $path
            }
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

    function Invoke-PrePushFixtureHook {
        param($Fixture, [string[]]$Records, [string]$RemoteUrl, [string]$InheritedEvent)
        $savedPath = $env:PATH
        $savedMarker = $env:AT_PREPUSH_MARKER
        $savedEvent = $env:GITHUB_EVENT_NAME
        try {
            $env:PATH = "$($Fixture.bin)$([IO.Path]::PathSeparator)$savedPath"
            $env:AT_PREPUSH_MARKER = $Fixture.marker
            if ($PSBoundParameters.ContainsKey('InheritedEvent')) { $env:GITHUB_EVENT_NAME = $InheritedEvent }
            if (-not $PSBoundParameters.ContainsKey('RemoteUrl')) { $RemoteUrl = $Fixture.remote }
            $output = $Records | & pwsh -NoProfile -NonInteractive -File (Join-Path $Fixture.repo '.githooks/Invoke-PrePushValidation.ps1') -RemoteName origin -RemoteUrl $RemoteUrl 2>&1
            return [pscustomobject]@{ exitCode = $LASTEXITCODE; output = ($output -join "`n") }
        }
        finally {
            $env:PATH = $savedPath
            $env:AT_PREPUSH_MARKER = $savedMarker
            $env:GITHUB_EVENT_NAME = $savedEvent
        }
    }

    function Remove-FixturePrePushArtifact {
        param([string]$Path)
        if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
        $full = [IO.Path]::GetFullPath($Path)
        [IO.Path]::GetDirectoryName($full) | Should -Be ([IO.Path]::GetTempPath().TrimEnd([char[]]@('\','/')))
        [IO.Path]::GetFileName($full) | Should -Match '^atlassian-prepush-[0-9a-f]{32}$'
        @((Get-Item -LiteralPath $full -Force), (Get-ChildItem -LiteralPath $full -Force)) |
            Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 } | Should -BeNullOrEmpty
        Remove-Item -LiteralPath $full -Recurse -Force
    }

    function Set-FixtureTrustedHook {
        param($Fixture, [string]$Mode = 'Enable')
        $savedPath = $env:PATH
        try {
            $env:PATH = "$($Fixture.bin)$([IO.Path]::PathSeparator)$savedPath"
            $output = & pwsh -NoProfile -NonInteractive -File (Join-Path $script:SourceRoot 'scripts/Set-PrePushHook.ps1') -RepositoryRoot $Fixture.repo -Mode $Mode 2>&1
            return [pscustomobject]@{ exitCode=$LASTEXITCODE; output=($output -join "`n") }
        }
        finally { $env:PATH = $savedPath }
    }

    function Invoke-ReviewedRevisionFixture {
        param([ValidateSet('script', 'test', 'documentation', 'reviewed', 'no-op', 'main-identical')][string]$Change)
        $fixture = New-PrePushFixture
        $savedPath = $env:PATH
        $savedMarker = $env:AT_PREPUSH_MARKER
        try {
            [void][IO.Directory]::CreateDirectory((Join-Path $fixture.repo 'tests'))
            foreach ($relative in @('scripts/Test-Repository.ps1', 'tests/FixtureCandidate.Tests.ps1')) {
                [IO.File]::WriteAllText((Join-Path $fixture.repo $relative), '# Reviewed benign fixture code.', [Text.UTF8Encoding]::new($false))
            }
            $canonicalPath = Join-Path $fixture.repo 'scripts/Validate.ps1'
            $canonical = [IO.File]::ReadAllText($canonicalPath)
            # These counters represent a confined canonical/acquisition stub, never real tool acquisition.
            $instrumentation = @'
[IO.File]::AppendAllText(($env:AT_PREPUSH_MARKER + '.calls'), "canonical`n")
[IO.File]::AppendAllText(($env:AT_PREPUSH_MARKER + '.acquisition'), "fixture-acquisition`n")
& (Join-Path $repo 'scripts/Test-Repository.ps1')
& (Join-Path $repo 'tests/FixtureCandidate.Tests.ps1')
'@
            $canonical = $canonical.Replace('$head =', $instrumentation + "`n" + '$head =')
            [IO.File]::WriteAllText($canonicalPath, $canonical, [Text.UTF8Encoding]::new($false))
            & git -C $fixture.repo add scripts/Validate.ps1 scripts/Test-Repository.ps1 tests/FixtureCandidate.Tests.ps1
            & git -C $fixture.repo commit -m 'review complete candidate fixture' | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Could not commit reviewed fixture.' }
            $fixture.head = ([string](& git -C $fixture.repo rev-parse HEAD)).Trim()
            $installed = Set-FixtureTrustedHook -Fixture $fixture
            if ($installed.exitCode -ne 0) { throw $installed.output }
            $hookPath = ([string](& git -C $fixture.repo config --local --get core.hooksPath)).Trim()
            $manifestPath = Join-Path $hookPath 'manifest.json'
            $manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            if ($Change -ne 'reviewed') {
                $changedPath = switch ($Change) {
                    script { 'scripts/Test-Repository.ps1' }
                    test { 'tests/FixtureCandidate.Tests.ps1' }
                    documentation { 'README.md' }
                    no-op { 'README.md' }
                    main-identical { 'README.md' }
                }
                $payload = if ($Change -in @('documentation', 'no-op', 'main-identical')) { 'Different clean documentation revision.' } else {
                    '[IO.File]::WriteAllText(($env:AT_PREPUSH_MARKER + ".attack"), "unreviewed candidate executed")'
                }
                [IO.File]::WriteAllText((Join-Path $fixture.repo $changedPath), $payload, [Text.UTF8Encoding]::new($false))
                & git -C $fixture.repo add -- $changedPath
                & git -C $fixture.repo commit -m 'unreviewed candidate revision' | Out-Null
                if ($LASTEXITCODE -ne 0) { throw 'Could not commit changed fixture.' }
            }
            $candidate = ([string](& git -C $fixture.repo rev-parse HEAD)).Trim()
            $pushRef = 'main'
            if ($Change -eq 'no-op') { $pushRef = "$($fixture.first):refs/heads/main" }
            if ($Change -eq 'main-identical') {
                # Seed the disposable remote's authenticated main without invoking the candidate's push hook.
                & git --git-dir=$($fixture.remote) fetch --no-write-fetch-head $fixture.repo main 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { throw 'Could not copy candidate objects into disposable remote.' }
                & git --git-dir=$($fixture.remote) update-ref refs/heads/main $candidate
                & git -C $fixture.repo switch -c feature/main-identical 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { throw 'Could not create disposable identical branch.' }
                $pushRef = 'feature/main-identical'
            }
            $clean = @(& git -C $fixture.repo status --porcelain=v1 --untracked-files=all).Count -eq 0
            $unchangedEntries = @($manifest.files | Where-Object {
                (Get-FileHash -LiteralPath (Join-Path $fixture.repo $_.path) -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $_.sha256
            }).Count
            $env:PATH = "$($fixture.bin)$([IO.Path]::PathSeparator)$savedPath"
            $env:AT_PREPUSH_MARKER = $fixture.marker
            $output = & git -C $fixture.repo push origin $pushRef 2>&1
            $pushExit = $LASTEXITCODE
            $calls = if (Test-Path -LiteralPath ($fixture.marker + '.calls')) { @(Get-Content -LiteralPath ($fixture.marker + '.calls')).Count } else { 0 }
            $acquisitionCalls = if (Test-Path -LiteralPath ($fixture.marker + '.acquisition')) { @(Get-Content -LiteralPath ($fixture.marker + '.acquisition')).Count } else { 0 }
            $artifactRemoved = if (Test-Path -LiteralPath ($fixture.marker + '.artifacts')) {
                -not (Test-Path -LiteralPath (Get-Content -LiteralPath ($fixture.marker + '.artifacts') -Raw))
            } else { $true }
            $binding = if (Test-Path -LiteralPath $fixture.marker) { Get-Content -LiteralPath $fixture.marker -Raw } else { '' }
            $evidence = [pscustomobject]@{
                scenario=$Change; reviewedRevision=$manifest.sourceRevision; candidateRevision=$candidate
                clean=$clean; unchangedEntryCount=$unchangedEntries; exitCode=$pushExit
                manifestUnchanged=((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -ceq $manifestHash)
                canonicalCalls=$calls; fixtureAcquisitionCalls=$acquisitionCalls
                attackMarkerPresent=(Test-Path -LiteralPath ($fixture.marker + '.attack'))
                artifactRemoved=$artifactRemoved; canonicalBinding=$binding
                expectedBinding="$($fixture.head)|$($fixture.first)|1.25.1|pre-push"; output=($output -join "`n")
            }
            Write-Host ('C290_BOUNDARY_EVIDENCE ' + ($evidence | ConvertTo-Json -Compress))
            return $evidence
        }
        finally {
            $env:PATH = $savedPath
            $env:AT_PREPUSH_MARKER = $savedMarker
            Remove-PrePushFixture $fixture
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

    It 'UnitT07_RejectsSecretBearingRemoteWithoutEchoingTheIdentifier' {
        # Scenario: Git passes a direct repository URL containing a fake credential as both hook arguments.
        # Purpose: Reject unsupported remotes before validation without disclosing the caller-supplied identifier.
        $fixture = New-PrePushFixture
        try {
            $secretRemote = 'https://fixture-user:TOP_SECRET_PREPUSH_MARKER@example.invalid/repo.git'
            $line = "refs/heads/main $($fixture.head) refs/heads/main $($fixture.first)"
            $output = $line | & pwsh -NoProfile -NonInteractive -File (Join-Path $fixture.repo '.githooks/Invoke-PrePushValidation.ps1') -RemoteName $secretRemote -RemoteUrl $secretRemote 2>&1
            $LASTEXITCODE | Should -Not -Be 0
            ($output -join "`n") | Should -Match 'Unsupported remote'
            ($output -join "`n") | Should -Not -Match 'TOP_SECRET_PREPUSH_MARKER|fixture-user|example\.invalid'
            (Test-Path -LiteralPath $fixture.marker) | Should -BeFalse
        }
        finally { Remove-PrePushFixture $fixture }
    }

    It 'UnitT08_AcceptsNoPendingUpdatesWithoutCanonicalValidation' {
        # Scenario: Git invokes the hook for an up-to-date origin push with no ref records.
        # Purpose: Preserve successful no-op pushes without acquiring tools or running validation.
        $fixture = New-PrePushFixture
        try {
            $result = Invoke-PrePushFixtureHook -Fixture $fixture -Records @()
            $result.exitCode | Should -Be 0 -Because $result.output
            (Test-Path -LiteralPath $fixture.marker) | Should -BeFalse
        }
        finally { Remove-PrePushFixture $fixture }
    }

    It 'UnitT09_AuthenticatesTheConfiguredPushUrlRatherThanFetchUrl' {
        # Scenario: Origin has distinct fetch and push URLs and Git supplies the configured push URL.
        # Purpose: Accept the actual authenticated destination while retaining exact candidate validation.
        $fixture = New-PrePushFixture
        try {
            $pushUrl = Join-Path $fixture.root 'push.git'
            & git init --bare $pushUrl | Out-Null
            & git -C $fixture.repo remote set-url --push origin $pushUrl
            $line = "refs/heads/main $($fixture.head) refs/heads/main $($fixture.first)"
            $result = Invoke-PrePushFixtureHook -Fixture $fixture -Records @($line) -RemoteUrl $pushUrl
            $result.exitCode | Should -Be 0 -Because $result.output
            (Test-Path -LiteralPath $fixture.marker) | Should -BeTrue
        }
        finally { Remove-PrePushFixture $fixture }
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

    It 'UnitT28_AcceptsSymbolicHeadForTheCurrentBranch' {
        # Scenario: A single origin HEAD refspec names the current symbolic main branch.
        # Purpose: Resolve symbolic branch identity while validating the exact committed candidate.
        $fixture = New-PrePushFixture
        try {
            $line = "HEAD $($fixture.head) refs/heads/main $($fixture.first)"
            $result = Invoke-PrePushFixtureHook -Fixture $fixture -Records @($line)
            $result.exitCode | Should -Be 0 -Because $result.output
            (Test-Path -LiteralPath $fixture.marker) | Should -BeTrue
        }
        finally { Remove-PrePushFixture $fixture }
    }

    It 'UnitT29_RejectsDetachedHeadBeforeCanonicalValidation' {
        # Scenario: A HEAD refspec is supplied while the checkout is detached at the candidate.
        # Purpose: Reject a non-branch source even when its commit matches the checkout.
        $fixture = New-PrePushFixture
        try {
            & git -C $fixture.repo switch --detach $fixture.head | Out-Null
            $line = "HEAD $($fixture.head) refs/heads/main $($fixture.first)"
            $result = Invoke-PrePushFixtureHook -Fixture $fixture -Records @($line)
            $result.exitCode | Should -Not -Be 0
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

    It 'UnitT32_BindsTheCanonicalChildToPrePushDespiteAnInheritedEvent' {
        # Scenario: The parent process has an unrelated GitHub event identity.
        # Purpose: Ensure acquisition evidence and execution identity describe the actual pre-push operation.
        $fixture = New-PrePushFixture
        try {
            $line = "refs/heads/main $($fixture.head) refs/heads/main $($fixture.first)"
            $result = Invoke-PrePushFixtureHook -Fixture $fixture -Records @($line) -InheritedEvent pull_request
            $result.exitCode | Should -Be 0 -Because $result.output
            (Get-Content -LiteralPath $fixture.marker -Raw) | Should -Match '\|pre-push$'
        }
        finally { Remove-PrePushFixture $fixture }
    }

    It 'UnitT33_CleansTheCallerOwnedArtifactsAfterSourceSuccess' {
        # Scenario: The canonical child returns a passed source projection with blocked Stage 6.
        # Purpose: Remove the full per-push acquisition tree instead of accumulating it on the host.
        $fixture = New-PrePushFixture
        $artifactRoot = $null
        try {
            $line = "refs/heads/main $($fixture.head) refs/heads/main $($fixture.first)"
            $result = Invoke-PrePushFixtureHook -Fixture $fixture -Records @($line)
            $result.exitCode | Should -Be 0 -Because $result.output
            $artifactRoot = Get-Content -LiteralPath ($fixture.marker + '.artifacts') -Raw
            (Test-Path -LiteralPath $artifactRoot) | Should -BeFalse
        }
        finally { Remove-FixturePrePushArtifact -Path $artifactRoot; Remove-PrePushFixture $fixture }
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

    It 'UnitT36_CleansFailedArtifactsAndRetainsOnlyABoundedReport' {
        # Scenario: The canonical child writes an invalid source revision and the push is rejected.
        # Purpose: Preserve a bounded local failure report while reclaiming the run's full acquisition tree.
        $fixture = New-PrePushFixture
        $savedInvalid = $env:AT_PREPUSH_INVALID_REPORT
        $retained = $null
        $artifactRoot = $null
        try {
            $env:AT_PREPUSH_INVALID_REPORT = '1'
            $line = "refs/heads/main $($fixture.head) refs/heads/main $($fixture.first)"
            $result = Invoke-PrePushFixtureHook -Fixture $fixture -Records @($line)
            $result.exitCode | Should -Not -Be 0
            $artifactRoot = Get-Content -LiteralPath ($fixture.marker + '.artifacts') -Raw
            (Test-Path -LiteralPath $artifactRoot) | Should -BeFalse
            $leaf = [IO.Path]::GetFileName($artifactRoot)
            $leaf | Should -Match '^atlassian-prepush-[0-9a-f]{32}$'
            $retained = Join-Path ([IO.Path]::GetTempPath()) ($leaf.Replace('atlassian-prepush-', 'atlassian-prepush-report-') + '.json')
            (Test-Path -LiteralPath $retained -PathType Leaf) | Should -BeTrue
            (Get-Item -LiteralPath $retained).Length | Should -BeLessOrEqual 1048576
        }
        finally {
            $env:AT_PREPUSH_INVALID_REPORT = $savedInvalid
            Remove-FixturePrePushArtifact -Path $artifactRoot
            if ($retained -and (Test-Path -LiteralPath $retained)) {
                [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($retained)) | Should -Be ([IO.Path]::GetTempPath().TrimEnd([char[]]@('\','/')))
                [IO.Path]::GetFileName($retained) | Should -Match '^atlassian-prepush-report-[0-9a-f]{32}\.json$'
                Remove-Item -LiteralPath $retained -Force
            }
            Remove-PrePushFixture $fixture
        }
    }

    It 'InterT40_RoutesActualLocalPushThroughCanonicalEntry' {
        # Scenario: A disposable candidate repo enables the trusted snapshot and pushes to a disposable bare remote.
        # Purpose: Verify Git invokes the immutable wrapper and propagates exact candidate source success to the push.
        $fixture = New-PrePushFixture
        $oldPath = $env:PATH
        try {
            $env:PATH = "$($fixture.bin)$([IO.Path]::PathSeparator)$oldPath"
            $env:AT_PREPUSH_MARKER = $fixture.marker
            $installed = Set-FixtureTrustedHook -Fixture $fixture
            $installed.exitCode | Should -Be 0 -Because $installed.output
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
            $installed = Set-FixtureTrustedHook -Fixture $fixture
            $installed.exitCode | Should -Be 0 -Because $installed.output
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

    It 'UnitT46_UsesTheServerMainTipRatherThanAStaleTrackingRef' {
        # Scenario: Origin/main locally points at HEAD but the server main remains an earlier ancestor.
        # Purpose: Include the full source delta from the authenticated destination baseline.
        $fixture = New-PrePushFixture
        try {
            & git -C $fixture.repo switch -c feature/stale-main | Out-Null
            & git -C $fixture.repo update-ref refs/remotes/origin/main $fixture.head
            $line = "refs/heads/feature/stale-main $($fixture.head) refs/heads/feature/stale-main $('0' * 40)"
            $result = Invoke-PrePushFixtureHook -Fixture $fixture -Records @($line)
            $result.exitCode | Should -Be 0 -Because $result.output
            (Get-Content -LiteralPath $fixture.marker -Raw) | Should -Match ([regex]::Escape("$($fixture.head)|$($fixture.first)|"))
        }
        finally { Remove-PrePushFixture $fixture }
    }

    It 'UnitT47_RejectsMultipleBestMergeBasesBeforeCanonicalValidation' {
        # Scenario: Candidate and server main have two best ancestors in a criss-cross graph.
        # Purpose: Reject ambiguous comparisons rather than omitting source paths from an arbitrary base.
        $fixture = New-PrePushFixture
        try {
            $tree = ([string](& git -C $fixture.repo rev-parse 'HEAD^{tree}')).Trim()
            $left = ([string](& git -C $fixture.repo commit-tree $tree -p $fixture.first -m left)).Trim()
            $right = ([string](& git -C $fixture.repo commit-tree $tree -p $fixture.first -m right)).Trim()
            $candidate = ([string](& git -C $fixture.repo commit-tree $tree -p $left -p $right -m candidate)).Trim()
            $remoteTip = ([string](& git -C $fixture.repo commit-tree $tree -p $right -p $left -m remote)).Trim()
            & git -C $fixture.repo push origin "${remoteTip}:refs/heads/main" | Out-Null
            & git -C $fixture.repo switch -c feature/criss-cross $candidate | Out-Null
            $line = "refs/heads/feature/criss-cross $candidate refs/heads/feature/criss-cross $('0' * 40)"
            $result = Invoke-PrePushFixtureHook -Fixture $fixture -Records @($line)
            $result.exitCode | Should -Not -Be 0
            $result.output | Should -Match 'unique.*merge base'
            (Test-Path -LiteralPath $fixture.marker) | Should -BeFalse
        }
        finally { Remove-PrePushFixture $fixture }
    }

    It 'UnitT48_AllowsNewBranchAtTheAuthenticatedServerMainCommit' {
        # Scenario: A new branch publishes the exact source commit already present at server main.
        # Purpose: Permit a ref-only publication without inventing a distinct source comparison or acquiring tools.
        $fixture = New-PrePushFixture
        try {
            & git -C $fixture.repo push origin main | Out-Null
            & git -C $fixture.repo switch -c feature/main-identical | Out-Null
            $line = "refs/heads/feature/main-identical $($fixture.head) refs/heads/feature/main-identical $('0' * 40)"
            $result = Invoke-PrePushFixtureHook -Fixture $fixture -Records @($line)
            $result.exitCode | Should -Be 0 -Because $result.output
            (Test-Path -LiteralPath $fixture.marker) | Should -BeFalse
        }
        finally { Remove-PrePushFixture $fixture }
    }

    It 'InterT50_TrustedSnapshotBlocksAContributorChangedTrackedHook' {
        # Scenario: After enable, a committed contributor branch replaces the tracked shell hook with a marker command.
        # Purpose: Ensure branch checkout cannot replace the executable pre-push trust boundary.
        $fixture = New-PrePushFixture
        try {
            $installed = Set-FixtureTrustedHook -Fixture $fixture
            $installed.exitCode | Should -Be 0 -Because $installed.output
            $hooksPath = ([string](& git -C $fixture.repo config --local --get core.hooksPath)).Trim()
            $hooksPath | Should -Not -Be '.githooks'
            [IO.Path]::IsPathFullyQualified($hooksPath) | Should -BeTrue
            [IO.File]::WriteAllText((Join-Path $fixture.repo '.githooks/pre-push'), "#!/bin/sh`necho untrusted > attack-marker.txt`nexit 0`n", [Text.UTF8Encoding]::new($false))
            & git -C $fixture.repo add .githooks/pre-push
            & git -C $fixture.repo commit -m 'untrusted hook branch' | Out-Null
            & git -C $fixture.repo push origin main 2>&1 | Out-Null
            $LASTEXITCODE | Should -Not -Be 0
            (Test-Path -LiteralPath (Join-Path $fixture.repo 'attack-marker.txt')) | Should -BeFalse
            (Test-Path -LiteralPath $fixture.marker) | Should -BeFalse
        }
        finally { Remove-PrePushFixture $fixture }
    }

    It 'InterT51_TrustedSnapshotBlocksAChangedCanonicalEntryBeforeExecution' {
        # Scenario: An enabled checkout commits a canonical entry that writes an attacker marker.
        # Purpose: Verify the trusted wrapper checks the full executable entry chain before candidate code runs.
        $fixture = New-PrePushFixture
        try {
            $installed = Set-FixtureTrustedHook -Fixture $fixture
            $installed.exitCode | Should -Be 0 -Because $installed.output
            [IO.File]::WriteAllText((Join-Path $fixture.repo 'scripts/Validate.ps1'), '[IO.File]::WriteAllText((Join-Path $PSScriptRoot "../attack-marker.txt"), "untrusted")', [Text.UTF8Encoding]::new($false))
            & git -C $fixture.repo add scripts/Validate.ps1
            & git -C $fixture.repo commit -m 'untrusted entry branch' | Out-Null
            & git -C $fixture.repo push origin main 2>&1 | Out-Null
            $LASTEXITCODE | Should -Not -Be 0
            (Test-Path -LiteralPath (Join-Path $fixture.repo 'attack-marker.txt')) | Should -BeFalse
        }
        finally { Remove-PrePushFixture $fixture }
    }

    It 'InterT52_TrustedSnapshotRunsOneCanonicalSourceCallForAValidPush' {
        # Scenario: The trusted setup snapshots a clean candidate whose entry chain is unchanged.
        # Purpose: Retain the canonical source projection for a real push through the untracked hook wrapper.
        $fixture = New-PrePushFixture
        $savedPath = $env:PATH
        $savedMarker = $env:AT_PREPUSH_MARKER
        try {
            $installed = Set-FixtureTrustedHook -Fixture $fixture
            $installed.exitCode | Should -Be 0 -Because $installed.output
            $env:PATH = "$($fixture.bin)$([IO.Path]::PathSeparator)$savedPath"
            $env:AT_PREPUSH_MARKER = $fixture.marker
            $output = & git -C $fixture.repo push origin main 2>&1
            $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
            (Get-Content -LiteralPath $fixture.marker -Raw) | Should -Match ([regex]::Escape("$($fixture.head)|$($fixture.first)|1.25.1|pre-push"))
        }
        finally {
            $env:PATH = $savedPath
            $env:AT_PREPUSH_MARKER = $savedMarker
            Remove-PrePushFixture $fixture
        }
    }

    It 'InterT53_PushUsesPlatformPathIdentityForSnapshotOwnership_<Change>' -ForEach @(
        @{ Change='case-only' }, @{ Change='different-directory' }
    ) {
        # Scenario: A trusted snapshot records alternate casing or a different Git metadata directory.
        # Purpose: Permit equivalent Windows paths while rejecting different directories before candidate execution.
        $fixture = New-PrePushFixture
        $savedPath = $env:PATH
        $savedMarker = $env:AT_PREPUSH_MARKER
        try {
            $installed = Set-FixtureTrustedHook -Fixture $fixture
            $installed.exitCode | Should -Be 0 -Because $installed.output
            $hooksPath = ([string](& git -C $fixture.repo config --local --get core.hooksPath)).Trim()
            $manifestPath = Join-Path $hooksPath 'manifest.json'
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            $originalCommon = [string]$manifest.commonGitDirectory
            $manifest.commonGitDirectory = if ($Change -eq 'case-only') { $originalCommon.ToUpperInvariant() } else { $originalCommon + '.other' }
            $manifest.commonGitDirectory | Should -Not -BeExactly $originalCommon
            (Get-Item -LiteralPath $manifestPath).IsReadOnly = $false
            [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
            $env:PATH = "$($fixture.bin)$([IO.Path]::PathSeparator)$savedPath"
            $env:AT_PREPUSH_MARKER = $fixture.marker
            $output = & git -C $fixture.repo push origin main 2>&1
            $pushExit = $LASTEXITCODE
            if ($IsWindows -and $Change -eq 'case-only') {
                $pushExit | Should -Be 0 -Because ($output -join "`n")
                (Get-Content -LiteralPath $fixture.marker -Raw) | Should -BeExactly "$($fixture.head)|$($fixture.first)|1.25.1|pre-push"
            }
            else {
                $pushExit | Should -Not -Be 0
                (Test-Path -LiteralPath $fixture.marker) | Should -BeFalse
                ($output -join "`n") | Should -Match 'Trusted pre-push entry is changed or unavailable'
            }
        }
        finally {
            $env:PATH = $savedPath
            $env:AT_PREPUSH_MARKER = $savedMarker
            Remove-PrePushFixture $fixture
        }
    }

    It 'InterT54_DisableUsesPlatformPathIdentityForSnapshotOwnership_<Change>' -ForEach @(
        @{ Change='case-only' }, @{ Change='different-directory' }
    ) {
        # Scenario: Disable encounters a snapshot manifest with case-only or different-directory ownership.
        # Purpose: Restore equivalent Windows snapshots while preserving an unowned hooksPath and its files.
        $fixture = New-PrePushFixture
        try {
            $installed = Set-FixtureTrustedHook -Fixture $fixture
            $installed.exitCode | Should -Be 0 -Because $installed.output
            $hooksPath = ([string](& git -C $fixture.repo config --local --get core.hooksPath)).Trim()
            $manifestPath = Join-Path $hooksPath 'manifest.json'
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            $originalCommon = [string]$manifest.commonGitDirectory
            $manifest.commonGitDirectory = if ($Change -eq 'case-only') { $originalCommon.ToUpperInvariant() } else { $originalCommon + '.other' }
            $manifest.commonGitDirectory | Should -Not -BeExactly $originalCommon
            (Get-Item -LiteralPath $manifestPath).IsReadOnly = $false
            [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
            $disabled = Set-FixtureTrustedHook -Fixture $fixture -Mode Disable
            if ($IsWindows -and $Change -eq 'case-only') {
                $disabled.exitCode | Should -Be 0 -Because $disabled.output
                & git -C $fixture.repo config --local --get core.hooksPath 2>$null
                $LASTEXITCODE | Should -Be 1
                (Test-Path -LiteralPath $hooksPath) | Should -BeFalse
            }
            else {
                $disabled.exitCode | Should -Not -Be 0
                $disabled.output | Should -Match 'Hook snapshot ownership does not match'
                ([string](& git -C $fixture.repo config --local --get core.hooksPath)).Trim() | Should -BeExactly $hooksPath
                (Test-Path -LiteralPath $hooksPath) | Should -BeTrue
            }
        }
        finally { Remove-PrePushFixture $fixture }
    }

    It 'InterT55_RejectsAnUnreviewedTestRepositoryBeforeCandidateExecution' {
        # Scenario: Only the existing candidate repository test script changes after the trusted snapshot is enabled.
        # Purpose: Reject its new commit before canonical or acquisition stubs can execute the attacker marker.
        $result = Invoke-ReviewedRevisionFixture -Change script
        $result.clean | Should -BeTrue
        $result.unchangedEntryCount | Should -Be 5
        $result.candidateRevision | Should -Not -Be $result.reviewedRevision
        $result.exitCode | Should -Not -Be 0
        $result.canonicalCalls | Should -Be 0
        $result.fixtureAcquisitionCalls | Should -Be 0
        $result.attackMarkerPresent | Should -BeFalse
        $result.manifestUnchanged | Should -BeTrue
    }

    It 'InterT56_RejectsAnUnreviewedExistingPesterTestBeforeCandidateExecution' {
        # Scenario: Only an existing candidate tests/*.Tests.ps1 file changes while all five snapshot entries match.
        # Purpose: Cover the executable Pester surface outside the entry inventory before any candidate code runs.
        $result = Invoke-ReviewedRevisionFixture -Change test
        $result.clean | Should -BeTrue
        $result.unchangedEntryCount | Should -Be 5
        $result.candidateRevision | Should -Not -Be $result.reviewedRevision
        $result.exitCode | Should -Not -Be 0
        $result.canonicalCalls | Should -Be 0
        $result.fixtureAcquisitionCalls | Should -Be 0
        $result.attackMarkerPresent | Should -BeFalse
        $result.manifestUnchanged | Should -BeTrue
    }

    It 'InterT57_RejectsAnyDifferentCleanRevisionWithoutRefreshingTrust' {
        # Scenario: A documentation-only fixture commit changes HEAD without changing the trusted five entry hashes.
        # Purpose: Make the full revision restriction explicit and prevent automatic manifest trust refresh.
        $result = Invoke-ReviewedRevisionFixture -Change documentation
        $result.clean | Should -BeTrue
        $result.unchangedEntryCount | Should -Be 5
        $result.candidateRevision | Should -Not -Be $result.reviewedRevision
        $result.exitCode | Should -Not -Be 0
        $result.canonicalCalls | Should -Be 0
        $result.fixtureAcquisitionCalls | Should -Be 0
        $result.attackMarkerPresent | Should -BeFalse
        $result.manifestUnchanged | Should -BeTrue
    }

    It 'InterT58_RunsExactlyOneCanonicalCallForTheCompleteReviewedCommit' {
        # Scenario: The clean candidate is the complete revision intentionally used to enable the snapshot.
        # Purpose: Preserve one canonical invocation, destination/base/report binding and owned artifact cleanup.
        $result = Invoke-ReviewedRevisionFixture -Change reviewed
        $result.clean | Should -BeTrue
        $result.unchangedEntryCount | Should -Be 5
        $result.candidateRevision | Should -Be $result.reviewedRevision
        $result.exitCode | Should -Be 0 -Because $result.output
        $result.canonicalCalls | Should -Be 1
        $result.fixtureAcquisitionCalls | Should -Be 1
        $result.attackMarkerPresent | Should -BeFalse
        $result.manifestUnchanged | Should -BeTrue
        $result.artifactRemoved | Should -BeTrue
        $result.canonicalBinding | Should -BeExactly $result.expectedBinding
    }

    It 'InterT59_PreservesZeroRefNoOpWithADifferentCleanHead' {
        # Scenario: HEAD differs from the trusted manifest, but an actual push has no pending ref update.
        # Purpose: Retain the trusted no-op early return without running or trusting candidate code.
        $result = Invoke-ReviewedRevisionFixture -Change no-op
        $result.candidateRevision | Should -Not -Be $result.reviewedRevision
        $result.unchangedEntryCount | Should -Be 5
        $result.clean | Should -BeTrue
        $result.exitCode | Should -Be 0 -Because $result.output
        $result.canonicalCalls | Should -Be 0
        $result.fixtureAcquisitionCalls | Should -Be 0
        $result.manifestUnchanged | Should -BeTrue
        $result.attackMarkerPresent | Should -BeFalse
        $result.output | Should -Match 'no pending ref updates'
    }

    It 'InterT60_PreservesNewBranchAtRemoteMainWithoutTrustingDifferentHead' {
        # Scenario: A new branch at verified remote main has a clean HEAD different from the manifest revision.
        # Purpose: Preserve ref-only publication before candidate execution without refreshing the manifest.
        $result = Invoke-ReviewedRevisionFixture -Change main-identical
        $result.candidateRevision | Should -Not -Be $result.reviewedRevision
        $result.unchangedEntryCount | Should -Be 5
        $result.clean | Should -BeTrue
        $result.exitCode | Should -Be 0 -Because $result.output
        $result.canonicalCalls | Should -Be 0
        $result.fixtureAcquisitionCalls | Should -Be 0
        $result.manifestUnchanged | Should -BeTrue
        $result.attackMarkerPresent | Should -BeFalse
        $result.output | Should -Match 'no new source content'
    }

    It 'UnitT53_RefusesToReplaceAnExistingHooksPath' {
        # Scenario: A repository already has an organization hook directory configured.
        # Purpose: Preserve existing hook behavior rather than silently replacing it during opt-in.
        $fixture = New-PrePushFixture
        try {
            & git -C $fixture.repo config --local core.hooksPath existing-hooks
            $installed = Set-FixtureTrustedHook -Fixture $fixture
            $installed.exitCode | Should -Not -Be 0
            ([string](& git -C $fixture.repo config --local --get core.hooksPath)).Trim() | Should -Be 'existing-hooks'
        }
        finally { Remove-PrePushFixture $fixture }
    }

    It 'UnitT54_DisablesOnlyItsOwnSnapshotAndRestoresAbsentLocalSetting' {
        # Scenario: A previously unconfigured checkout enables and disables the managed snapshot.
        # Purpose: Restore the prior absent setting and clean only the installer-owned Git metadata directory.
        $fixture = New-PrePushFixture
        try {
            $installed = Set-FixtureTrustedHook -Fixture $fixture
            $installed.exitCode | Should -Be 0 -Because $installed.output
            $hooksPath = ([string](& git -C $fixture.repo config --local --get core.hooksPath)).Trim()
            $disabled = Set-FixtureTrustedHook -Fixture $fixture -Mode Disable
            $disabled.exitCode | Should -Be 0 -Because $disabled.output
            & git -C $fixture.repo config --local --get core.hooksPath 2>$null
            $LASTEXITCODE | Should -Be 1
            (Test-Path -LiteralPath $hooksPath) | Should -BeFalse
        }
        finally { Remove-PrePushFixture $fixture }
    }
}
