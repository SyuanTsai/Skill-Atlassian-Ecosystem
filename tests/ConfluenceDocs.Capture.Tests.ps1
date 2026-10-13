# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluenceDocs.psm1'
$cloudId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
$apiBase = "https://api.atlassian.com/ex/confluence/$cloudId"
$site = 'https://example.atlassian.net'

function New-CaptureFixture {
    $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
    $root = Join-Path $tempParent "syp171-capture-tests-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path (Join-Path $root 'adapter') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $root 'canonical.md'), 'accepted Git content', (New-Object System.Text.UTF8Encoding($false)))
    $scope = [ordered]@{ schemaVersion = 1; siteOrigin = $site; cloudId = $cloudId; apiBase = $apiBase; scope = @{ kind = 'space'; spaceId = '55' } } | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText((Join-Path $root 'scope.json'), $scope, (New-Object System.Text.UTF8Encoding($false)))
    return $root
}

function Remove-CaptureFixture {
    param([Parameter(Mandatory)][string] $Root)
    if (-not (Test-Path -LiteralPath $Root)) { return }
    $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path)
    $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
    if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\', '/') -cne $tempParent) { throw 'Capture fixture escaped temporary root.' }
    if ([IO.Path]::GetFileName($resolved) -cnotmatch '^syp171-capture-tests-[a-f0-9]{32}$') { throw 'Unexpected capture fixture name.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

function New-FakeCaptureHttp {
    return {
        param($Request)
        $script:requests.Add([pscustomobject]@{ Method = $Request.Method; Uri = [string] $Request.Uri; AuthAllowed = $Request.AuthAllowed })
        $uri = [Uri] $Request.Uri
        $path = $uri.AbsolutePath
        if ($path -match '/spaces/55/pages$') {
            return [pscustomobject]@{ StatusCode = 200; Headers = @{}; Body = @{ results = @(@{ id = '101' }, @{ id = '102' }); _links = @{} } }
        }
        if ($path -match '/pages/(101|102)/attachments$') {
            if ($Matches[1] -eq '102') { return [pscustomobject]@{ StatusCode = 200; Headers = @{}; Body = @{ results = @(); _links = @{} } } }
            $script:attachmentReads++
            if ($script:mode -eq 'many-attachments') {
                $rows = @(501..526 | ForEach-Object { @{ id = [string]$_; title = "diagram-$_.png"; version = @{ number = 1 }; fileSize = 3; mediaType = 'image/png'; downloadLink = "/wiki/rest/api/content/101/child/attachment/$_/download" } })
                return [pscustomobject]@{ StatusCode = 200; Headers = @{}; Body = @{ results = $rows; _links = @{} } }
            }
            $version = if ($script:mode -eq 'attachment-drift' -and $script:attachmentReads -gt 1) { 2 } else { 1 }
            $attachment = @{ id = '501'; title = 'diagram.png'; version = @{ number = $version }; fileSize = 3; mediaType = 'image/png'; downloadLink = '/wiki/rest/api/content/101/child/attachment/501/download' }
            if ($script:mode -eq 'attachment-media-null') { $attachment.mediaType = $null }
            elseif ($script:mode -eq 'attachment-media-blank') { $attachment.mediaType = ' ' }
            elseif ($script:mode -eq 'attachment-media-missing') { $attachment.Remove('mediaType') }
            return [pscustomobject]@{ StatusCode = 200; Headers = @{}; Body = @{ results = @($attachment); _links = @{} } }
        }
        if ($path -match '/content/101/child/attachment/(\d+)/download$') {
            [byte[]]$bytes = @(1, 2, 3)
            if ($script:mode -eq 'many-attachments') { $bytes = [byte[]] @(([int]$Matches[1] % 251), 2, 3) }
            return [pscustomobject]@{ StatusCode = 200; Headers = @{}; BodyBytes = $bytes }
        }
        if ($path -match '/pages/(101|102)$') {
            $pageId = $Matches[1]
            if ($script:mode -eq 'page-denied' -and $pageId -eq '102') { return [pscustomobject]@{ StatusCode = 403; Headers = @{}; Body = @{} } }
            $storage = if ($pageId -eq '101') {
                if ($script:mode -eq 'macro') { '<p>before</p><ac:structured-macro ac:name="toc" />' }
                else { '<h2>合成需求</h2><p>原文與來源</p><ac:image><ri:attachment ri:filename="diagram.png" /></ac:image>' }
            } else { '<p>第二頁</p>' }
            $page = @{ id = $pageId; title = "Synthetic $pageId"; status = 'current'; spaceId = '55'; parentId = '99'; version = @{ number = 3 }; body = @{ storage = @{ value = $storage } } }
            if ($uri.Query.Contains('get-draft=true') -and $pageId -eq '101') {
                switch ($script:mode) {
                    'draft-id-invalid' { $page.id = '999' }
                    'draft-status-invalid' { $page.status = 'draft' }
                    'draft-storage-invalid' { $page.body.storage.Remove('value') }
                    'draft-version-invalid' { $page.version.number = 0 }
                    'draft-diverged' { $page.version.number = 4; $page.body.storage.value = '<p>Draft differs</p>' }
                }
            }
            return [pscustomobject]@{ StatusCode = 200; Headers = @{}; Body = $page }
        }
        throw "Unexpected read path: $path"
    }
}

function Invoke-CaptureFixture {
    param([string] $TargetPath)
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) { throw 'ConfluenceDocs production module is missing.' }
    Import-Module -Name $modulePath -Force
    $target = if ([string]::IsNullOrWhiteSpace($TargetPath)) { Join-Path $script:fixtureRoot 'adapter' } else { $TargetPath }
    return Invoke-ConfluenceCapture -Root $script:fixtureRoot -TargetPath $target -ScopePath (Join-Path $script:fixtureRoot 'scope.json') -ExpectedSiteOrigin $site -HttpInvoker (New-FakeCaptureHttp)
}

function New-PullCliFixture {
    $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
    $root = Join-Path $tempParent "syp171-pull-cli-$([Guid]::NewGuid().ToString('N'))"
    $created = $false
    try {
        $installRoot = Join-Path $root 'installed'
        $skillInstall = Join-Path $installRoot 'manage-confluence-docs-as-code'
        $accessInstall = Join-Path $installRoot 'configure-confluence-api-access'
        $repo = Join-Path $root 'selected-repo'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $created = $true
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code') -Destination $skillInstall -Recurse
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'skills/configure-confluence-api-access') -Destination $accessInstall -Recurse

        $transportPath = Join-Path $skillInstall 'scripts/ConfluenceTransport.psm1'
        $transport = [IO.File]::ReadAllText($transportPath)
        $startMarker = 'function Invoke-ConfluenceWireRead {'
        $endMarker = 'function Test-SignedDownloadUri {'
        $start = $transport.IndexOf($startMarker, [StringComparison]::Ordinal)
        $end = $transport.IndexOf($endMarker, $start, [StringComparison]::Ordinal)
        if ($start -lt 0 -or $end -le $start) { throw 'Could not isolate copied Pull transport wire boundary.' }
        $wireStub = @'
function Invoke-ConfluenceWireRead {
    param([object]$Request)
    $statePath = $env:SYP171_PULL_MOCK_STATE
    $state = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($statePath)) -AsHashtable -Depth 20 -ErrorAction Stop
    $uri = [Uri]$Request.Uri
    $event = [ordered]@{ method = [string]$Request.Method; path = $uri.AbsolutePath; query = $uri.Query }
    $state.requests += @($event)
    [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    if ([string]$Request.Method -cne 'GET') { throw 'PullReadOnlyMethodExpected' }
    $body = $null
    if ($uri.AbsolutePath -match '/spaces/55/pages$') {
        $body = @{ results = @(@{ id = '101' }); _links = @{} }
    } elseif ($uri.AbsolutePath -match '/pages/101/attachments$') {
        $body = @{ results = @(); _links = @{} }
    } elseif ($uri.AbsolutePath -match '/pages/101$') {
        $body = @{ id = '101'; title = 'Synthetic 101'; status = 'current'; spaceId = '55'; parentId = '99'; version = @{ number = 3 }; body = @{ storage = @{ value = '<p>Pull fixture</p>' } } }
    } else { throw "PullMockUnexpectedReadPath: $($uri.AbsolutePath)" }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 20 -Compress))
    return [pscustomobject]@{ StatusCode = 200; Headers = @{}; BodyBytes = $bytes }
}
'@
        $patched = $transport.Substring(0, $start) + $wireStub + $transport.Substring($end)
        [IO.File]::WriteAllText($transportPath, $patched, [Text.UTF8Encoding]::new($false))
        if ($patched.Substring(0, $start) -cne $transport.Substring(0, $start) -or
            $patched.Substring($start + $wireStub.Length) -cne $transport.Substring($end)) {
            throw 'Temporary Pull transport copy changed outside the fake wire boundary.'
        }

        $accessPath = Join-Path $accessInstall 'scripts/Test-ConfluenceApiAccess.ps1'
        $accessStub = @'
param([switch]$TestConnection)
if (-not $TestConnection) { throw 'ConnectionCheckRequired' }
if (-not [string]::IsNullOrWhiteSpace([string]$env:SYP171_PULL_ACCESS_CALLS)) { [IO.File]::AppendAllText($env:SYP171_PULL_ACCESS_CALLS, "called`n") }
[pscustomobject]@{
    ReadyForRead = $true; HostReloadRequired = $false; ConfigurationState = 'valid'; TenantIdentityState = 'match'
    SpaceReadCheck = [pscustomobject]@{ Category = 'success' }; PageReadCheck = [pscustomobject]@{ Category = 'success' }
    HostEnvironmentState = 'process-ready'; MissingProcessSettings = @(); ScopeConflictSettings = @()
}
'@
        [IO.File]::WriteAllText($accessPath, $accessStub, [Text.UTF8Encoding]::new($false))

        New-Item -ItemType Directory -Path (Join-Path $repo '.confluence') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $repo 'docs') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $repo 'docs/canonical.md'), 'keep accepted bytes', [Text.UTF8Encoding]::new($false))
        $scope = [ordered]@{ schemaVersion = 1; siteOrigin = $site; cloudId = $cloudId; apiBase = $apiBase; scope = @{ kind = 'space'; spaceId = '55' } }
        $scopePath = Join-Path $repo '.confluence/scope.json'
        [IO.File]::WriteAllText($scopePath, ($scope | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        $statePath = Join-Path $root 'wire-state.json'
        $state = [ordered]@{ requests = @() }
        [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        $pwsh = [string][Environment]::ProcessPath
        if ([string]::IsNullOrWhiteSpace($pwsh)) { $pwsh = Join-Path $PSHOME 'pwsh.exe' }
        return [pscustomobject]@{
            root = $root; tempParent = $tempParent; repo = $repo; scopePath = $scopePath
            targetPath = Join-Path $repo 'candidate-capture'; statePath = $statePath
            accessCallsPath = Join-Path $root 'access-calls.txt'; pwsh = $pwsh
            pullPath = Join-Path $skillInstall 'scripts/Pull-ConfluenceDocs.ps1'
        }
    } catch {
        if ($created -and (Test-Path -LiteralPath $root)) { Remove-PullCliFixture -Root $root -Parent $tempParent }
        throw
    }
}

function Invoke-PullCli {
    param([Parameter(Mandatory)]$Fixture)
    $args = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $Fixture.pullPath,
        '-TargetPath', $Fixture.targetPath, '-Root', $Fixture.repo, '-ScopePath', $Fixture.scopePath)
    $output = @(& $Fixture.pwsh @args 2>&1)
    $exitCode = $LASTEXITCODE
    $outputText = ($output | ForEach-Object { [string]$_ }) -join "`n"
    $jsonStart = $outputText.IndexOf('{', [StringComparison]::Ordinal)
    if ($jsonStart -lt 0) { throw "Pull CLI returned no JSON. Exit=$exitCode Output=$outputText" }
    $resultJson = $outputText.Substring($jsonStart).Trim()
    return [pscustomobject]@{ exitCode = $exitCode; result = ($resultJson | ConvertFrom-Json -ErrorAction Stop); output = $output }
}

function Read-PullCliState {
    param([Parameter(Mandatory)]$Fixture)
    return ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Fixture.statePath)) -AsHashtable -Depth 20
}

function Remove-PullCliFixture {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Parent)
    if (-not (Test-Path -LiteralPath $Root)) { return }
    $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path)
    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd('\', '/')
    if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\', '/') -cne $parentFull -or
        [IO.Path]::GetFileName($resolved) -cnotmatch '^syp171-pull-cli-[a-f0-9]{32}$') {
        throw 'Unsafe Pull fixture cleanup target.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

}

Describe 'SYP-171 private Confluence capture' {
    BeforeAll {
        $script:oldPullEnvironment = @{}
        foreach ($name in @('CONFLUENCE_BASE_URL', 'CONFLUENCE_API_BASE_URL', 'CONFLUENCE_CLOUD_ID', 'CONFLUENCE_EMAIL', 'CONFLUENCE_API_TOKEN', 'SYP171_PULL_MOCK_STATE', 'SYP171_PULL_ACCESS_CALLS')) {
            $script:oldPullEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        }
    }
    BeforeEach {
        $script:fixtureRoot = New-CaptureFixture
        $script:requests = [System.Collections.Generic.List[object]]::new()
        $script:attachmentReads = 0
        $script:mode = 'normal'
    }
    AfterEach { Remove-CaptureFixture -Root $script:fixtureRoot }
    AfterAll { foreach ($name in $script:oldPullEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $script:oldPullEnvironment[$name], 'Process') } }

    # Scenario: SYP171-SCN-001; two pages and one attachment have stable readback versions.
    # Purpose: Full candidates and identities are persisted privately while accepted Git bytes stay unchanged.
    It 'InterT10_captures_two_pages_and_attachment_without_touching_canonical' {
        $result = Invoke-CaptureFixture
        ($result.reasonCodes -join ',') | Should -Be ''
        $result.status | Should -Be 'complete'
        (Get-Content -LiteralPath (Join-Path $script:fixtureRoot 'canonical.md') -Raw) | Should -Be 'accepted Git content'
        $manifest = Get-Content -LiteralPath (Join-Path $result.capturePath 'capture.json') -Raw | ConvertFrom-Json
        @($manifest.pages).Count | Should -Be 2
        $manifest.pages[0].pageId | Should -Be '101'
        @($manifest.pages[0].attachments).Count | Should -Be 1
        (Test-Path -LiteralPath (Join-Path $result.capturePath $manifest.pages[0].snapshotPath)) | Should -Be $true
        (Test-Path -LiteralPath (Join-Path $result.capturePath $manifest.pages[0].attachments[0].assetPath)) | Should -Be $true
        [IO.File]::ReadAllText((Join-Path $result.capturePath $manifest.pages[0].snapshotPath),[Text.UTF8Encoding]::new($false,$true)) | Should -BeExactly '<h2>合成需求</h2><p>原文與來源</p><ac:image><ri:attachment ri:filename="diagram.png" /></ac:image>'
        [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $result.capturePath $manifest.pages[0].attachments[0].assetPath))) | Should -BeExactly '010203'
        @($script:requests | Where-Object Method -ne 'GET').Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-002; the second page returns 403 after the first was read.
    # Purpose: A partial capture still preserves the first source and never reports space completeness.
    It 'InterT20_keeps_first_candidate_when_second_page_is_denied' {
        $script:mode = 'page-denied'
        $result = Invoke-CaptureFixture
        $result.status | Should -Be 'partial'
        @($result.reasonCodes) | Should -Contain 'RemoteReadDenied'
        $manifest = Get-Content -LiteralPath (Join-Path $result.capturePath 'capture.json') -Raw | ConvertFrom-Json
        @($manifest.pages).Count | Should -Be 1
        @($manifest.incompletePageIds) | Should -Contain '102'
        (Get-Content -LiteralPath (Join-Path $script:fixtureRoot 'canonical.md') -Raw) | Should -Be 'accepted Git content'
    }

    # Scenario: SYP171-SCN-002; attachment metadata changes after binary download.
    # Purpose: Asset bytes remain a candidate, while unstable remote versions block a full result.
    It 'InterT30_marks_attachment_version_drift_as_partial' {
        $script:mode = 'attachment-drift'
        $result = Invoke-CaptureFixture
        $result.status | Should -Be 'partial'
        @($result.reasonCodes) | Should -Contain 'AttachmentUnstable'
        $manifest = Get-Content -LiteralPath (Join-Path $result.capturePath 'capture.json') -Raw | ConvertFrom-Json
        @($manifest.pages).Count | Should -BeGreaterThan 0
        $manifest.pages[0].pageId | Should -Be '101'
    }

    # Scenario: SYP171-SCN-009; a page contains a macro unsupported by the V1 projection.
    # Purpose: Raw storage survives in the candidate but the capture cannot be called publishable.
    It 'InterT40_preserves_macro_snapshot_and_reports_unsupported_content' {
        $script:mode = 'macro'
        $result = Invoke-CaptureFixture
        $result.status | Should -Be 'partial'
        @($result.reasonCodes) | Should -Contain 'UnsupportedContent'
        $manifest = Get-Content -LiteralPath (Join-Path $result.capturePath 'capture.json') -Raw | ConvertFrom-Json
        $raw = Get-Content -LiteralPath (Join-Path $result.capturePath $manifest.pages[0].snapshotPath) -Raw
        $raw | Should -Match 'ac:structured-macro'
        (Get-Content -LiteralPath (Join-Path $script:fixtureRoot 'canonical.md') -Raw) | Should -Be 'accepted Git content'
    }

    # Scenario: A successful draft endpoint returns an invalid page identity, version, status, or storage shape.
    # Purpose: HTTP 200 alone cannot make a capture complete when the draft snapshot cannot be validated.
    # Given: The published page is valid and one draft field is malformed.
    # When: Pull captures the selected space.
    # Then: The page is marked incomplete with DraftReadIncomplete instead of being treated as ordinary divergence.
    It 'UnitT45_marks_invalid_draft_identity_fields_incomplete' {
        foreach ($mode in @('draft-id-invalid','draft-status-invalid','draft-storage-invalid','draft-version-invalid')) {
            $script:mode = $mode
            $result = Invoke-CaptureFixture
            $result.status | Should -Be 'partial' -Because $mode
            @($result.reasonCodes) | Should -Contain 'DraftReadIncomplete' -Because $mode
            $manifest = Get-Content -LiteralPath (Join-Path $result.capturePath 'capture.json') -Raw | ConvertFrom-Json
            @($manifest.incompletePageIds) | Should -Contain '101' -Because $mode
        }
    }

    # Scenario: A valid draft identity has a real version and storage difference from the published page.
    # Purpose: Genuine divergence remains visible as a draft observation rather than becoming an invalid-read error.
    # Given: The published and draft snapshots each have valid identity fields.
    # When: Their version and body differ.
    # Then: Capture remains complete and the manifest records diverged.
    It 'InterT45_keeps_valid_draft_difference_as_diverged' {
        $script:mode = 'draft-diverged'
        $result = Invoke-CaptureFixture
        $result.status | Should -Be 'complete'
        @($result.reasonCodes) | Should -Not -Contain 'DraftReadIncomplete'
        $manifest = Get-Content -LiteralPath (Join-Path $result.capturePath 'capture.json') -Raw | ConvertFrom-Json
        ($manifest.pages | Where-Object pageId -eq '101').draftObservation | Should -Be 'diverged'
    }

    # Scenario: A page has more than the publication mapping's per-page attachment limit.
    # Purpose: Pull preserves all raw source attachments even when a later publication mapping will reject the count.
    # Given: The private capture reads twenty-six distinct, valid image attachments.
    # When: Pull writes the raw attachment snapshot and manifest.
    # Then: Every attachment entry and byte file remains present and digest-verifiable.
    It 'InterT47_preserves_all_raw_attachments_above_the_publication_mapping_limit' {
        $script:mode = 'many-attachments'
        $result = Invoke-CaptureFixture
        $result.status | Should -Be 'complete'
        $manifest = Get-Content -LiteralPath (Join-Path $result.capturePath 'capture.json') -Raw | ConvertFrom-Json
        $attachments = @($manifest.pages | Where-Object pageId -eq '101' | Select-Object -ExpandProperty attachments)
        $attachments.Count | Should -Be 26
        foreach ($attachment in $attachments) {
            $assetPath = Join-Path $result.capturePath $attachment.assetPath
            (Test-Path -LiteralPath $assetPath -PathType Leaf) | Should -BeTrue
            $bytes = [IO.File]::ReadAllBytes($assetPath)
            $bytes.Length | Should -Be $attachment.byteLength
            [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant() | Should -BeExactly $attachment.sha256
        }
    }

    # Scenario: An attachment is missing a usable media type despite an otherwise valid HTTP 200 response.
    # Purpose: Missing and blank MIME metadata makes the attachment identity incomplete, never a complete capture.
    # Given: Attachment ID, version, filename, and download path are otherwise valid.
    # When: The API omits, nulls, or blanks mediaType.
    # Then: Capture is partial and preserves an explicit AttachmentIdentityInvalid reason.
    It 'UnitT46_marks_missing_or_blank_attachment_media_type_incomplete' {
        foreach ($mode in @('attachment-media-missing','attachment-media-null','attachment-media-blank')) {
            $script:mode = $mode
            $result = Invoke-CaptureFixture
            $result.status | Should -Be 'partial' -Because $mode
            @($result.reasonCodes) | Should -Contain 'AttachmentIdentityInvalid' -Because $mode
        }
    }

    # Scenario: SYP171-SCN-001; a target path resolves outside the selected adopter root.
    # Purpose: Pull must stop before any read or file write rather than capturing into an arbitrary location.
    It 'UnitT50_rejects_target_path_outside_root_before_HTTP' {
        $target = Join-Path (Split-Path -Parent $script:fixtureRoot) 'outside-adapter'
        $result = Invoke-CaptureFixture -TargetPath $target
        $result.status | Should -Be 'invalid'
        @($result.reasonCodes) | Should -Contain 'TargetOutsideRoot'
        $script:requests.Count | Should -Be 0
        (Test-Path -LiteralPath $target) | Should -Be $false
    }

    # Scenario: The captured scope records the same API base with a trailing slash.
    # Purpose: The URI-aware transport contract trims only this permitted representation difference.
    # Given: The scope's tenant and Cloud ID remain valid.
    # When: The capture uses the trailing-slash API base.
    # Then: The existing collection, page, draft, and attachment reads complete.
    It 'UnitT60_accepts_scope_api_base_trailing_slash_for_capture_reads' {
        $scopePath = Join-Path $script:fixtureRoot 'scope.json'
        $scope = Get-Content -LiteralPath $scopePath -Raw | ConvertFrom-Json -AsHashtable
        $scope.apiBase = "$apiBase/"
        [IO.File]::WriteAllText($scopePath,($scope|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
        $result = Invoke-CaptureFixture
        $result.status | Should -Be 'complete'
        $script:requests.Count | Should -BeGreaterThan 0
    }

    # Scenario: Public Pull receives the captured site and scoped API base with permitted trailing slashes.
    # Purpose: The entry point accepts canonical URI representation differences and completes through authenticated reads.
    It 'InterT70_public_pull_accepts_site_and_api_trailing_slashes' {
        $pull = New-PullCliFixture
        try {
            $env:CONFLUENCE_BASE_URL = $site + '/'
            $env:CONFLUENCE_API_BASE_URL = $apiBase + '/'
            $env:CONFLUENCE_CLOUD_ID = $cloudId
            $env:CONFLUENCE_EMAIL = 'fixture@example.invalid'
            $env:CONFLUENCE_API_TOKEN = 'fixture-token-only'
            $env:SYP171_PULL_MOCK_STATE = $pull.statePath
            $env:SYP171_PULL_ACCESS_CALLS = $pull.accessCallsPath
            $result = Invoke-PullCli -Fixture $pull
            $result.exitCode | Should -Be 0 -Because (ConvertTo-Json -InputObject $result.result -Compress -Depth 8)
            $result.result.status | Should -Be 'complete'
            (Test-Path -LiteralPath $pull.accessCallsPath -PathType Leaf) | Should -BeTrue
            @((Read-PullCliState -Fixture $pull).requests).Count | Should -BeGreaterThan 0
            (Get-Content -LiteralPath (Join-Path $pull.repo 'docs/canonical.md') -Raw) | Should -BeExactly 'keep accepted bytes'
        } finally {
            Remove-PullCliFixture -Root $pull.root -Parent $pull.tempParent
        }
    }

    # Scenario: Pull configuration has an invalid tenant origin, scoped API route, or Cloud ID.
    # Purpose: The CLI returns a structured refusal before the access validator or any remote request runs.
    It 'UnitT80_public_pull_blocks_invalid_tenant_settings_before_access_or_HTTP' {
        $cases = @(
            @{ setting = 'site'; value = 'https://user:password@example.atlassian.net'; reason = 'TenantMismatch' },
            @{ setting = 'site'; value = $site + '/wiki'; reason = 'TenantMismatch' },
            @{ setting = 'site'; value = $site + '?tenant=other'; reason = 'TenantMismatch' },
            @{ setting = 'site'; value = $site + '#tenant'; reason = 'TenantMismatch' },
            @{ setting = 'site'; value = 'https://other.atlassian.net'; reason = 'TenantMismatch' },
            @{ setting = 'api'; value = $apiBase + '?tenant=other'; reason = 'ApiBaseMismatch' },
            @{ setting = 'api'; value = ''; reason = 'ApiBaseMismatch' },
            @{ setting = 'cloud'; value = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'; reason = 'ApiBaseMismatch' },
            @{ setting = 'cloud'; value = ''; reason = 'ApiBaseMismatch' }
        )
        $pull = New-PullCliFixture
        try {
            foreach ($case in $cases) {
                if (Test-Path -LiteralPath $pull.accessCallsPath) { Remove-Item -LiteralPath $pull.accessCallsPath -Force }
                $env:CONFLUENCE_BASE_URL = $site
                $env:CONFLUENCE_API_BASE_URL = $apiBase
                $env:CONFLUENCE_CLOUD_ID = $cloudId
                $env:CONFLUENCE_EMAIL = 'fixture@example.invalid'
                $env:CONFLUENCE_API_TOKEN = 'fixture-token-only'
                $env:SYP171_PULL_MOCK_STATE = $pull.statePath
                $env:SYP171_PULL_ACCESS_CALLS = $pull.accessCallsPath
                switch ($case.setting) {
                    'site' { $env:CONFLUENCE_BASE_URL = $case.value }
                    'api' { $env:CONFLUENCE_API_BASE_URL = $case.value }
                    'cloud' { $env:CONFLUENCE_CLOUD_ID = $case.value }
                }
                [IO.File]::WriteAllText($pull.statePath, '{"requests":[]}', [Text.UTF8Encoding]::new($false))
                $result = Invoke-PullCli -Fixture $pull
                $result.exitCode | Should -Be 10 -Because ("setting=$($case.setting); result=" + (ConvertTo-Json -InputObject $result.result -Compress -Depth 8))
                $result.result.status | Should -Be 'blocked'
                @($result.result.reasonCodes) | Should -Contain $case.reason
                @((Read-PullCliState -Fixture $pull).requests).Count | Should -Be 0
                (Test-Path -LiteralPath $pull.accessCallsPath) | Should -BeFalse
            }
        } finally {
            Remove-PullCliFixture -Root $pull.root -Parent $pull.tempParent
        }
    }
}
