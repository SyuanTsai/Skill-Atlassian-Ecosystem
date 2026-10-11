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
            $version = if ($script:mode -eq 'attachment-drift' -and $script:attachmentReads -gt 1) { 2 } else { 1 }
            $attachment = @{ id = '501'; title = 'diagram.png'; version = @{ number = $version }; fileSize = 3; mediaType = 'image/png'; downloadLink = '/wiki/rest/api/content/101/child/attachment/501/download' }
            return [pscustomobject]@{ StatusCode = 200; Headers = @{}; Body = @{ results = @($attachment); _links = @{} } }
        }
        if ($path -match '/content/101/child/attachment/501/download$') {
            return [pscustomobject]@{ StatusCode = 200; Headers = @{}; BodyBytes = [byte[]] @(1, 2, 3) }
        }
        if ($path -match '/pages/(101|102)$') {
            $pageId = $Matches[1]
            if ($script:mode -eq 'page-denied' -and $pageId -eq '102') { return [pscustomobject]@{ StatusCode = 403; Headers = @{}; Body = @{} } }
            $storage = if ($pageId -eq '101') {
                if ($script:mode -eq 'macro') { '<p>before</p><ac:structured-macro ac:name="toc" />' }
                else { '<h2>合成需求</h2><p>原文與來源</p><ac:image><ri:attachment ri:filename="diagram.png" /></ac:image>' }
            } else { '<p>第二頁</p>' }
            $page = @{ id = $pageId; title = "Synthetic $pageId"; status = 'current'; spaceId = '55'; parentId = '99'; version = @{ number = 3 }; body = @{ storage = @{ value = $storage } } }
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

}

Describe 'SYP-171 private Confluence capture' {
    BeforeEach {
        $script:fixtureRoot = New-CaptureFixture
        $script:requests = [System.Collections.Generic.List[object]]::new()
        $script:attachmentReads = 0
        $script:mode = 'normal'
    }
    AfterEach { Remove-CaptureFixture -Root $script:fixtureRoot }

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
}
