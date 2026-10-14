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
        $script:requests.Add([pscustomobject]@{ Method = $Request.Method; Uri = [string] $Request.Uri; AuthAllowed = $Request.AuthAllowed; ResponseLimitBytes = $Request.ResponseLimitBytes })
        $uri = [Uri] $Request.Uri
        $path = $uri.AbsolutePath
        if ($path -match '/spaces/55/pages$') {
            if ($script:mode -eq 'collection-pagination-loop') {
                return [pscustomobject]@{ StatusCode = 200; Headers = @{}; Body = @{ results = @(@{ id = '101' }); _links = @{ next = [string] $Request.Uri } } }
            }
            if ($script:mode -eq 'large-space-id-list') {
                return [pscustomobject]@{ StatusCode = 200; Headers = @{}; Body = @{ results = @(@{ id = $script:largePageId }); _links = @{} } }
            }
            return [pscustomobject]@{ StatusCode = 200; Headers = @{}; Body = @{ results = @(@{ id = '101' }, @{ id = '102' }); _links = @{} } }
        }
        if ($path -match '/pages/(101|102)/attachments$') {
            if ($Matches[1] -eq '102') { return [pscustomobject]@{ StatusCode = 200; Headers = @{}; Body = @{ results = @(); _links = @{} } } }
            if ($script:mode -in @('manifest-title-no-attachments', 'projected-image-missing', 'native-titled-link-unsupported')) { return [pscustomobject]@{ StatusCode = 200; Headers = @{}; Body = @{ results = @(); _links = @{} } } }
            $script:attachmentReads++
            if ($script:mode -eq 'projected-image-duplicate') {
                $rows = @(@(501, 502) | ForEach-Object { @{ id = [string]$_; title = 'diagram.png'; version = @{ number = 1 }; fileSize = 3; mediaType = 'image/png'; downloadLink = "/wiki/rest/api/content/101/child/attachment/$_/download" } })
                return [pscustomobject]@{ StatusCode = 200; Headers = @{}; Body = @{ results = $rows; _links = @{} } }
            }
            if ($script:mode -in @('many-attachments', 'many-attachments-duplicate', 'many-attachments-failed-first')) {
                $rows = @(501..526 | ForEach-Object { @{ id = [string]$_; title = "diagram-$_.png"; version = @{ number = 1 }; fileSize = 3; mediaType = 'image/png'; downloadLink = "/wiki/rest/api/content/101/child/attachment/$_/download" } })
                return [pscustomobject]@{ StatusCode = 200; Headers = @{}; Body = @{ results = $rows; _links = @{} } }
            }
            if ($script:mode -in @('many-attachments-1000', 'many-attachments-1001')) {
                $lastId = if ($script:mode -eq 'many-attachments-1000') { 1500 } else { 1501 }
                $rows = @(501..$lastId | ForEach-Object { @{ id = [string]$_; title = "zero-$_.bin"; version = @{ number = 1 }; fileSize = 0; mediaType = 'application/octet-stream'; downloadLink = "/wiki/rest/api/content/101/child/attachment/$_/download" } })
                return [pscustomobject]@{ StatusCode = 200; Headers = @{}; Body = @{ results = $rows; _links = @{} } }
            }
            $version = if ($script:mode -eq 'attachment-drift' -and $script:attachmentReads -gt 1) { 2 } else { 1 }
            $fileSize = if ($script:mode -in @('zero-size-attachment-empty', 'zero-size-attachment-nonempty')) { 0 } else { 3 }
            $attachmentTitle = if ($script:mode -eq 'projected-image-case-mismatch') { 'Diagram.png' } else { 'diagram.png' }
            $attachment = @{ id = '501'; title = $attachmentTitle; version = @{ number = $version }; fileSize = $fileSize; mediaType = 'image/png'; downloadLink = '/wiki/rest/api/content/101/child/attachment/501/download' }
            if ($script:mode -eq 'attachment-media-null') { $attachment.mediaType = $null }
            elseif ($script:mode -eq 'attachment-media-blank') { $attachment.mediaType = ' ' }
            elseif ($script:mode -eq 'attachment-media-missing') { $attachment.Remove('mediaType') }
            return [pscustomobject]@{ StatusCode = 200; Headers = @{}; Body = @{ results = @($attachment); _links = @{} } }
        }
        if ($path -match '/content/101/child/attachment/(\d+)/download$') {
            [byte[]]$bytes = @(1, 2, 3)
            if ($script:mode -in @('many-attachments', 'many-attachments-failed-first')) { $bytes = [byte[]] @(([int]$Matches[1] % 251), 2, 3) }
            if ($script:mode -in @('many-attachments-1000', 'many-attachments-1001')) { $bytes = [byte[]]::new(0) }
            if ($script:mode -eq 'many-attachments-failed-first' -and $Matches[1] -eq '501') { return [pscustomobject]@{ StatusCode = 503; Headers = @{}; BodyBytes = [byte[]]::new(0) } }
            if ($script:mode -eq 'zero-size-attachment-empty') { $bytes = [byte[]]::new(0) }
            if ($script:mode -eq 'zero-size-attachment-nonempty') { $bytes = [byte[]] @(1) }
            return [pscustomobject]@{ StatusCode = 200; Headers = @{}; BodyBytes = $bytes }
        }
        if ($path -match '/pages/(101|102)$') {
            $pageId = $Matches[1]
            if ($script:mode -eq 'capture-page-directory-junction' -and $pageId -eq '101' -and [string]::IsNullOrEmpty($script:reparseLink)) {
                $script:reparseTarget = Join-Path $script:fixtureRoot 'page-directory-junction-target'
                $script:reparseLink = Join-Path $script:fixtureRoot 'adapter/.local/captures/capture-eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee.staging/pages/101'
                New-Item -ItemType Directory -Path $script:reparseTarget -Force | Out-Null
                New-Item -ItemType Junction -Path $script:reparseLink -Target $script:reparseTarget -ErrorAction Stop | Out-Null
            }
            if ($script:mode -eq 'page-denied' -and $pageId -eq '102') { return [pscustomobject]@{ StatusCode = 403; Headers = @{}; Body = @{} } }
            $storage = if ($pageId -eq '101') {
                if ($script:mode -eq 'manifest-title-no-attachments') { '<h2>Boundary page</h2><p>Stable content for metadata cap fixture.</p>' }
                elseif ($script:mode -eq 'deep-first-page') { ('<strong>' * 129) + 'deep capture source' + ('</strong>' * 129) }
                elseif ($script:mode -eq 'root-inline-unsupported') { '<strong>Writer fragment root</strong><p>Following supported paragraph.</p>' }
                elseif ($script:mode -eq 'native-titled-link-unsupported') { [string]$script:nativeTitledLinkStorage }
                elseif ($script:mode -eq 'macro') { '<p>before</p><ac:structured-macro ac:name="toc" />' }
                elseif ($script:mode -in @('many-attachments', 'many-attachments-duplicate', 'many-attachments-failed-first', 'many-attachments-1000', 'many-attachments-1001')) { '<h2>Attachment payload page</h2><p>No projected images.</p>' }
                elseif ($script:mode -eq 'projected-image-repeat') { '<h2>Repeated image reference</h2><p><ac:image><ri:attachment ri:filename="diagram.png" /></ac:image><ac:image><ri:attachment ri:filename="diagram.png" /></ac:image></p>' }
                else { '<h2>合成需求</h2><p>原文與來源</p><ac:image><ri:attachment ri:filename="diagram.png" /></ac:image>' }
            } else { '<p>第二頁</p>' }
            $title = if ($script:mode -in @('manifest-title', 'manifest-title-no-attachments')) { [string] $script:manifestTitle } else { "Synthetic $pageId" }
            $page = @{ id = $pageId; title = $title; status = 'current'; spaceId = '55'; parentId = '99'; version = @{ number = 3 }; body = @{ storage = @{ value = $storage } } }
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
    param(
        [string] $TargetPath,
        [switch] $ObservePrivateWrites,
        [switch] $ObserveRawProjectionOrder,
        [switch] $InjectPageDirectoryJunction,
        [switch] $PrivatePermissionsUnavailable,
        [switch] $FailAssetPermissionBeforeWrite,
        [switch] $FailCandidateWrite,
        [ValidateSet('', 'stage', 'final')][string] $CaptureCollision = '',
        [long] $MaxAttachmentDownloadBytes = 1GB,
        [int] $MaxAttachmentAttempts = 1000,
        [long] $MaxCaptureBytes = 1GB
    )
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) { throw 'ConfluenceDocs production module is missing.' }
    $selectedModulePath = $modulePath
    if ($ObservePrivateWrites -or $ObserveRawProjectionOrder -or $InjectPageDirectoryJunction -or $PrivatePermissionsUnavailable -or $FailAssetPermissionBeforeWrite -or $FailCandidateWrite -or -not [string]::IsNullOrEmpty($CaptureCollision)) {
        $testModuleDirectory = Join-Path $script:fixtureRoot 'private-write-observer-modules'
        New-Item -ItemType Directory -Path $testModuleDirectory -Force | Out-Null
        Get-ChildItem -LiteralPath (Split-Path -Parent $modulePath) -File | Copy-Item -Destination $testModuleDirectory
        $selectedModulePath = Join-Path $testModuleDirectory 'ConfluenceDocs.psm1'
        $moduleText = [IO.File]::ReadAllText($selectedModulePath)
        if ($PrivatePermissionsUnavailable) {
            $capabilityStart = $moduleText.IndexOf('function Test-ConfluenceCapturePrivatePermissions {', [StringComparison]::Ordinal)
            $capabilityEnd = $moduleText.IndexOf('function New-CaptureDirectorySecurity {', $capabilityStart, [StringComparison]::Ordinal)
            if ($capabilityStart -lt 0 -or $capabilityEnd -le $capabilityStart) { throw 'Could not isolate private permission capability helper in the copied module.' }
            $capabilityStub = "function Test-ConfluenceCapturePrivatePermissions { return `$false }`r`n`r`n"
            $moduleText = $moduleText.Substring(0, $capabilityStart) + $capabilityStub + $moduleText.Substring($capabilityEnd)
        }
        if ($FailAssetPermissionBeforeWrite) {
            $permissionAnchor = "        if (-not (Test-CapturePrivatePathPermissions -Path `$fullPath -IsDirectory `$false -Stream `$stream)) { throw [Security.SecurityException]::new('CapturePrivatePermissionsUnavailable') }"
            if ($moduleText.IndexOf($permissionAnchor, [StringComparison]::Ordinal) -lt 0 -or
                $moduleText.IndexOf($permissionAnchor, [StringComparison]::Ordinal) -ne $moduleText.LastIndexOf($permissionAnchor, [StringComparison]::Ordinal)) {
                throw 'Could not instrument the exact private file permission check in the copied module.'
            }
            $permissionReplacement = @'
        $testPermissionCheck = Test-CapturePrivatePathPermissions -Path $fullPath -IsDirectory $false -Stream $stream
        if ($env:SYP171_CAPTURE_TEST_FAIL_ASSET_PERMISSION -eq '1' -and $fullPath -match '[\\/]assets[\\/]') { $testPermissionCheck = $false }
        if (-not $testPermissionCheck) { throw [Security.SecurityException]::new('CapturePrivatePermissionsUnavailable') }
'@
            $moduleText = $moduleText.Replace($permissionAnchor, $permissionReplacement.TrimEnd())
        }
        if ($FailCandidateWrite -or $InjectPageDirectoryJunction -or -not [string]::IsNullOrEmpty($CaptureCollision)) {
            $captureIdAnchor = '$captureId = [Guid]::NewGuid().ToString(''N'')'
            if ($moduleText.IndexOf($captureIdAnchor, [StringComparison]::Ordinal) -lt 0 -or
                $moduleText.IndexOf($captureIdAnchor, [StringComparison]::Ordinal) -ne $moduleText.LastIndexOf($captureIdAnchor, [StringComparison]::Ordinal)) {
                throw 'Could not instrument the exact capture identity boundary in the copied module.'
            }
            $moduleText = $moduleText.Replace($captureIdAnchor, "`$captureId = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'")
        }
        if ($FailCandidateWrite) {
            $writeAnchor = '        $stream.Write($Bytes, 0, $Bytes.Length)'
            if ($moduleText.IndexOf($writeAnchor, [StringComparison]::Ordinal) -lt 0 -or
                $moduleText.IndexOf($writeAnchor, [StringComparison]::Ordinal) -ne $moduleText.LastIndexOf($writeAnchor, [StringComparison]::Ordinal)) {
                throw 'Could not instrument the exact private byte write boundary in the copied module.'
            }
            $writeFailure = @'
        if ($env:SYP171_CAPTURE_TEST_FAIL_CANDIDATE_WRITE -eq '1' -and [IO.Path]::GetFileName($Path) -ceq 'candidate.md') {
            throw [IO.IOException]::new('CaptureInjectedWriteFailure')
        }
'@
            $moduleText = $moduleText.Replace($writeAnchor, $writeFailure + $writeAnchor)
        }
        if ($ObserveRawProjectionOrder) {
            $writeAnchor = '        $stream.Write($Bytes, 0, $Bytes.Length)'
            if ($moduleText.IndexOf($writeAnchor, [StringComparison]::Ordinal) -lt 0 -or
                $moduleText.IndexOf($writeAnchor, [StringComparison]::Ordinal) -ne $moduleText.LastIndexOf($writeAnchor, [StringComparison]::Ordinal)) {
                throw 'Could not instrument the exact private file-write order boundary in the copied module.'
            }
            $writeObserver = @'
        if ([IO.Path]::GetFileName($Path) -ceq 'storage.xml' -and -not [string]::IsNullOrWhiteSpace($env:SYP171_CAPTURE_TEST_RAW_PROJECTION_ORDER)) {
            [IO.File]::AppendAllText($env:SYP171_CAPTURE_TEST_RAW_PROJECTION_ORDER, 'raw-write' + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        }
'@
            $moduleText = $moduleText.Replace($writeAnchor, $writeObserver + $writeAnchor)
            $projectionPath = Join-Path $testModuleDirectory 'StorageProjection.psm1'
            $projectionText = [IO.File]::ReadAllText($projectionPath)
            $projectionAnchor = '    $bodyHash = Get-ProjectionHash -Text $Storage'
            $projectionIndex = $projectionText.IndexOf($projectionAnchor, [StringComparison]::Ordinal)
            if ($projectionIndex -lt 0 -or $projectionIndex -ne $projectionText.LastIndexOf($projectionAnchor, [StringComparison]::Ordinal)) {
                throw 'Could not instrument the exact projection entry point in the copied module.'
            }
            $projectionObserver = @'
    if (-not [string]::IsNullOrWhiteSpace($env:SYP171_CAPTURE_TEST_RAW_PROJECTION_ORDER)) {
        [IO.File]::AppendAllText($env:SYP171_CAPTURE_TEST_RAW_PROJECTION_ORDER, 'projection' + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    }
'@
            $projectionText = $projectionText.Insert($projectionIndex, $projectionObserver)
            [IO.File]::WriteAllText($projectionPath, $projectionText, [Text.UTF8Encoding]::new($false))
        }
        if ($ObservePrivateWrites) {
        $writeAnchor = '        $stream.Write($Bytes, 0, $Bytes.Length)'
        if ($moduleText.IndexOf($writeAnchor, [StringComparison]::Ordinal) -lt 0 -or
            $moduleText.IndexOf($writeAnchor, [StringComparison]::Ordinal) -ne $moduleText.LastIndexOf($writeAnchor, [StringComparison]::Ordinal)) {
            throw 'Could not instrument the exact private file-write boundary in the copied module.'
        }
        $observer = @'
        if (-not [string]::IsNullOrWhiteSpace($env:SYP171_CAPTURE_TEST_PERMISSION_LOG)) {
            $testAclAssembly = [Reflection.Assembly]::Load('System.IO.FileSystem.AccessControl')
            $testAclExtensions = $testAclAssembly.GetType('System.IO.FileSystemAclExtensions', $true)
            $testParent = [IO.DirectoryInfo]::new((Split-Path -Parent $Path))
            $testPagesRoot = $testParent.Parent
            $testStageRoot = $testPagesRoot.Parent
            if ($IsWindows) {
                $testFileSecurity = $testAclExtensions.GetMethod('GetAccessControl', [Type[]] @([IO.FileStream])).Invoke($null, @($stream))
                $testParentSecurity = $testAclExtensions.GetMethod('GetAccessControl', [Type[]] @([IO.DirectoryInfo])).Invoke($null, @($testParent))
                $testPagesSecurity = $testAclExtensions.GetMethod('GetAccessControl', [Type[]] @([IO.DirectoryInfo])).Invoke($null, @($testPagesRoot))
                $testStageSecurity = $testAclExtensions.GetMethod('GetAccessControl', [Type[]] @([IO.DirectoryInfo])).Invoke($null, @($testStageRoot))
                $testSidType = [Security.Principal.SecurityIdentifier]
                $testFileSids = @($testFileSecurity.GetAccessRules($true, $true, $testSidType) | ForEach-Object { $_.IdentityReference.Value } | Sort-Object)
                $testParentSids = @($testParentSecurity.GetAccessRules($true, $true, $testSidType) | ForEach-Object { $_.IdentityReference.Value } | Sort-Object)
                $testPagesSids = @($testPagesSecurity.GetAccessRules($true, $true, $testSidType) | ForEach-Object { $_.IdentityReference.Value } | Sort-Object)
                $testStageSids = @($testStageSecurity.GetAccessRules($true, $true, $testSidType) | ForEach-Object { $_.IdentityReference.Value } | Sort-Object)
                $testObservation = [ordered]@{ fileName = [IO.Path]::GetFileName($Path); fileProtected = $testFileSecurity.AreAccessRulesProtected; fileSids = $testFileSids; parentProtected = $testParentSecurity.AreAccessRulesProtected; parentSids = $testParentSids; pagesProtected = $testPagesSecurity.AreAccessRulesProtected; pagesSids = $testPagesSids; stageProtected = $testStageSecurity.AreAccessRulesProtected; stageSids = $testStageSids }
            } else {
                $testFileMode = [IO.File].GetMethod('GetUnixFileMode', [Type[]] @([string])).Invoke($null, @($Path))
                $testParentMode = [IO.Directory].GetMethod('GetUnixFileMode', [Type[]] @([string])).Invoke($null, @($testParent.FullName))
                $testPagesMode = [IO.Directory].GetMethod('GetUnixFileMode', [Type[]] @([string])).Invoke($null, @($testPagesRoot.FullName))
                $testStageMode = [IO.Directory].GetMethod('GetUnixFileMode', [Type[]] @([string])).Invoke($null, @($testStageRoot.FullName))
                $testObservation = [ordered]@{ fileName = [IO.Path]::GetFileName($Path); fileMode = [string]$testFileMode; parentMode = [string]$testParentMode; pagesMode = [string]$testPagesMode; stageMode = [string]$testStageMode }
            }
            $testJson = ConvertTo-Json -InputObject $testObservation -Compress -Depth 5
            [IO.File]::AppendAllText($env:SYP171_CAPTURE_TEST_PERMISSION_LOG, $testJson + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        }
'@
        $moduleText = $moduleText.Replace($writeAnchor, $observer + $writeAnchor)
        }
        [IO.File]::WriteAllText($selectedModulePath, $moduleText, [Text.UTF8Encoding]::new($false))
    }
    Import-Module -Name $selectedModulePath -Force
    $target = if ([string]::IsNullOrWhiteSpace($TargetPath)) { Join-Path $script:fixtureRoot 'adapter' } else { $TargetPath }
    if (-not [string]::IsNullOrEmpty($CaptureCollision)) {
        $collisionRoot = Join-Path $target '.local/captures'
        New-Item -ItemType Directory -Path $collisionRoot -Force | Out-Null
        $collisionName = if ($CaptureCollision -eq 'stage') { 'capture-eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee.staging' } else { 'capture-eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' }
        $collisionPath = Join-Path $collisionRoot $collisionName
        New-Item -ItemType Directory -Path $collisionPath -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $collisionPath 'collision-marker.txt'), 'preserve', [Text.UTF8Encoding]::new($false))
    }
    return Invoke-ConfluenceCapture -Root $script:fixtureRoot -TargetPath $target -ScopePath (Join-Path $script:fixtureRoot 'scope.json') -ExpectedSiteOrigin $site -HttpInvoker (New-FakeCaptureHttp) `
        -MaxAttachmentDownloadBytes $MaxAttachmentDownloadBytes -MaxAttachmentAttempts $MaxAttachmentAttempts -MaxCaptureBytes $MaxCaptureBytes
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
    param(
        [Parameter(Mandatory)]$Fixture,
        [long] $MaxAttachmentDownloadBytes = 1GB,
        [int] $MaxAttachmentAttempts = 1000,
        [long] $MaxCaptureBytes = 1GB
    )
    $args = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $Fixture.pullPath,
        '-TargetPath', $Fixture.targetPath, '-Root', $Fixture.repo, '-ScopePath', $Fixture.scopePath,
        '-MaxAttachmentDownloadBytes', [string] $MaxAttachmentDownloadBytes,
        '-MaxAttachmentAttempts', [string] $MaxAttachmentAttempts,
        '-MaxCaptureBytes', [string] $MaxCaptureBytes)
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
        $script:reparseLink = ''
        $script:reparseTarget = ''
        $script:manifestTitle = 'x'
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

    # Scenario: A native titled HTTPS link is captured with an ordinary sibling block and a following page.
    # Purpose: Retain full raw storage, refuse the titled block, and keep incomplete captures blocked from accepted destinations and preview writes.
    It 'InterT42_refuses_native_titled_links_through_capture_and_blocks_consumers' {
        $markdownModulePath = Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/MarkdownProjection.psm1'
        Import-Module -Name $markdownModulePath -Force
        $nativeMarkdown = '[Titled HTTPS](https://docs.example.invalid/spec "Specification title")' + "`n`n" + 'Ordinary sibling content.'
        $nativeHtml = ConvertFrom-Markdown -InputObject $nativeMarkdown
        $nativeHtmlDocument = [Xml.XmlDocument]::new()
        $nativeHtmlDocument.LoadXml('<root>' + [string]$nativeHtml.Html + '</root>')
        $nativeHtmlAnchor = $nativeHtmlDocument.SelectSingleNode('/root/p[1]/a')
        $nativeHtmlAnchor.GetAttribute('href') | Should -BeExactly 'https://docs.example.invalid/spec'
        $nativeHtmlAnchor.GetAttribute('title') | Should -BeExactly 'Specification title'
        $forward = ConvertTo-ConfluenceMarkdownStorage -Markdown $nativeMarkdown -Root $repositoryRoot `
            -SourcePath 'docs/unrelated.md' -ProjectionId 'native-link-title'
        $forward.status | Should -BeExactly 'supported'
        $forwardDocument = [Xml.XmlDocument]::new()
        $forwardDocument.PreserveWhitespace = $true
        $forwardDocument.LoadXml('<root>' + [string]$forward.storage + '</root>')
        $sourceAnchor = $forwardDocument.SelectSingleNode('/root/p[1]/a')
        $sourceAnchor.GetAttribute('href') | Should -BeExactly 'https://docs.example.invalid/spec'
        $sourceAnchor.GetAttribute('title') | Should -BeExactly 'Specification title'
        $script:nativeTitledLinkStorage = [string]$forward.storage
        $script:mode = 'native-titled-link-unsupported'

        $consumerRoot = Join-Path $script:fixtureRoot 'consumer-repository'
        New-Item -ItemType Directory -Path (Join-Path $consumerRoot 'docs') -Force | Out-Null
        [IO.File]::Copy((Join-Path $repositoryRoot '.gitattributes'), (Join-Path $consumerRoot '.gitattributes'), $true)
        [IO.File]::WriteAllText((Join-Path $consumerRoot 'docs/general.md'), '# Captured page' + "`n", [Text.UTF8Encoding]::new($false))
        $mapping = [ordered]@{
            schemaVersion = 4; adapter = @{ id = 'powershell-markdown'; version = '1' }
            siteOrigin = $site; cloudId = $cloudId; sourceMode = 'capture-markdown'
            entries = @(@{ projectionId = 'captured-page'; sourceArtifact = 'docs/general.md'; sourceSectionId = 'document'; pageId = '101'; spaceId = '55'; parentId = '99'; parentProjectionId = ''; title = 'Captured page'; assets = @(); linkBindings = @(); contentKind = 'general' })
        }
        $mappingPath = Join-Path $consumerRoot 'mapping.json'
        [IO.File]::WriteAllText($mappingPath, ($mapping | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        & git -C $consumerRoot init --quiet | Out-Null
        & git -C $consumerRoot config user.name 'SYP-171 capture consumer fixture' | Out-Null
        & git -C $consumerRoot config user.email 'fixture@example.invalid' | Out-Null
        & git -C $consumerRoot config core.autocrlf false | Out-Null
        & git -C $consumerRoot add -- .gitattributes docs/general.md mapping.json | Out-Null
        & git -C $consumerRoot commit --quiet -m 'Fixture native titled link consumer'
        if ($LASTEXITCODE -ne 0) { throw 'Unable to commit the native titled link consumer baseline.' }

        $scope = [ordered]@{ schemaVersion = 1; siteOrigin = $site; cloudId = $cloudId; apiBase = $apiBase; scope = @{ kind = 'page'; pageIds = @('101', '102') } } | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText((Join-Path $script:fixtureRoot 'scope.json'), $scope, [Text.UTF8Encoding]::new($false))
        $captureResult = Invoke-CaptureFixture -TargetPath $consumerRoot
        $producerGets = @($script:requests | Where-Object Method -CEQ 'GET').Count
        $producerOtherMethods = @($script:requests | Where-Object Method -cne 'GET').Count
        $producerGets | Should -BeGreaterThan 0
        $producerOtherMethods | Should -Be 0
        $capturePath = Join-Path $captureResult.capturePath 'capture.json'
        $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json -AsHashtable -Depth 20
        $page = @($capture.pages | Where-Object pageId -CEQ '101')[0]
        $rawStoragePath = Join-Path $captureResult.capturePath ([string]$page.snapshotPath)
        $rawBytes = [IO.File]::ReadAllBytes($rawStoragePath)
        $expectedRawBytes = [Text.UTF8Encoding]::new($false).GetBytes([string]$forward.storage)
        [Convert]::ToBase64String($rawBytes) | Should -BeExactly ([Convert]::ToBase64String($expectedRawBytes))
        $rawSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($rawBytes)).ToLowerInvariant()
        $expectedBodySha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($expectedRawBytes)).ToLowerInvariant()
        $page.bodySha256 | Should -BeExactly $expectedBodySha
        $rawSha | Should -BeExactly $expectedBodySha
        $rawDocument = [Xml.XmlDocument]::new()
        $rawDocument.PreserveWhitespace = $true
        $rawDocument.LoadXml('<root>' + [Text.UTF8Encoding]::new($false, $true).GetString($rawBytes) + '</root>')
        $rawAnchor = $rawDocument.SelectSingleNode('/root/p[1]/a')
        $rawAnchor.GetAttribute('href') | Should -BeExactly 'https://docs.example.invalid/spec'
        $rawAnchor.GetAttribute('title') | Should -BeExactly 'Specification title'
        $anchorSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($rawAnchor.OuterXml))).ToLowerInvariant()
        $parentSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($rawAnchor.ParentNode.OuterXml))).ToLowerInvariant()
        @($page.sourceBlocks | Where-Object { $_.sourceSha256 -CEQ $parentSha }).Count | Should -Be 1
        @($page.unsupported | Where-Object { $_.code -CEQ 'UnsupportedLinkTitle' -and $_.sourceSha256 -CEQ $anchorSha }).Count | Should -Be 1

        # This product assertion is the expected baseline Red: the valid producer currently calls the titled page complete.
        $capture.status | Should -BeExactly 'partial'
        @($capture.reasonCodes) | Should -Contain 'UnsupportedContent'
        $page.projectionStatus | Should -BeExactly 'unsupported'
        @($page.sourceBlocks | Where-Object { -not $_.supported -and $_.sourceSha256 -CEQ $parentSha }).Count | Should -Be 1
        $candidatePath = Join-Path $captureResult.capturePath ([string]$page.candidatePath)
        $candidate = [IO.File]::ReadAllText($candidatePath, [Text.UTF8Encoding]::new($false, $true))
        $candidate | Should -Not -Match 'Titled HTTPS'
        $candidate | Should -Match 'Ordinary sibling content\.'
        @($capture.pages | Where-Object { $_.pageId -CEQ '102' -and $_.projectionStatus -CEQ 'supported' }).Count | Should -Be 1

        Import-Module (Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ImportReview.psm1') -Force
        Import-Module (Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluenceValidation.psm1') -Force
        Import-Module (Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluenceMarkdownWorkflow.psm1') -Force
        $dispositions = [System.Collections.Generic.List[object]]::new()
        foreach ($capturedPage in @($capture.pages)) {
            foreach ($block in @($capturedPage.sourceBlocks)) {
                $dispositionStatus = if ($block.supported) { 'excluded' } else { 'unknown' }
                $dispositions.Add(@{ blockId = [string]$block.id; sourceSha256 = [string]$block.sourceSha256; location = [string]$block.location; status = $dispositionStatus; ready = $false; destinations = @(); reason = 'Capture requires manual review' })
            }
        }
        $review = [ordered]@{ schemaVersion = 2; captureId = [string]$capture.captureId; siteOrigin = $site; dispositions = @($dispositions.ToArray()); attachments = @() }
        $reviewPath = Join-Path $captureResult.capturePath 'import-review.json'
        [IO.File]::WriteAllText($reviewPath, ($review | ConvertTo-Json -Depth 16), [Text.UTF8Encoding]::new($false))
        $dossierPath = Join-Path $consumerRoot '.confluence/review-dossier.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $dossierPath) -Force | Out-Null
        $captureRelative = [IO.Path]::GetRelativePath($consumerRoot, $capturePath).Replace('\', '/')
        $reviewRelative = [IO.Path]::GetRelativePath($consumerRoot, $reviewPath).Replace('\', '/')
        [IO.File]::WriteAllText($dossierPath, (@{ schemaVersion = 2; capturePath = $captureRelative; importReviewPath = $reviewRelative } | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))

        $import = Test-ConfluenceImportReview -CapturePath $capturePath -ReviewPath $reviewPath
        $import.status | Should -BeExactly 'blocked'
        @($import.reasonCodes) | Should -Contain 'CaptureIncomplete'
        $import.unknownCount | Should -BeGreaterThan 0
        @($import.acceptedDestinations).Count | Should -Be 0

        & git -C $consumerRoot add -f -- .local/captures .confluence/review-dossier.json | Out-Null
        & git -C $consumerRoot commit --quiet -m 'Fixture partial native titled link capture and review'
        if ($LASTEXITCODE -ne 0) { throw 'Unable to commit the native titled link capture and review fixture.' }
        $commit = (& git -C $consumerRoot rev-parse HEAD).Trim()
        $validation = Invoke-ConfluenceValidation -Root $consumerRoot -MappingPath $mappingPath -DocsCommit $commit -ReviewPath $dossierPath
        $validation.status | Should -BeExactly 'blocked'
        @($validation.reasonCodes) | Should -Contain 'CaptureIncomplete'

        $script:previewHttpCalls = 0
        $planPath = Join-Path $consumerRoot 'preview.json'
        $preview = New-ConfluenceMarkdownPreviewPlan -Root $consumerRoot -MappingPath $mappingPath -DocsCommit $commit -ReviewPath $dossierPath `
            -PlanPath $planPath -ExpectedSiteOrigin $site -ApiBase $apiBase -HttpInvoker { param($Request) $script:previewHttpCalls++; throw 'PreviewMustNotIssueHttp' }
        $preview.status | Should -BeExactly 'blocked'
        @($preview.reasonCodes) | Should -Contain 'CaptureIncomplete'
        $script:previewHttpCalls | Should -Be 0
        (Test-Path -LiteralPath $planPath) | Should -BeFalse
        Write-Host ('F10-INTERT42-EVIDENCE=' + (ConvertTo-Json -InputObject ([ordered]@{
            producerGetCount = $producerGets; producerOtherMethodCount = $producerOtherMethods
            rawBytes = $rawBytes.Length; rawSha256 = $rawSha; anchorSha256 = $anchorSha; sourceBlockSha256 = $parentSha
            captureStatus = $capture.status; captureReasonCodes = @($capture.reasonCodes)
            importReviewStatus = $import.status; acceptedDestinationCount = @($import.acceptedDestinations).Count
            validationStatus = $validation.status; previewStatus = $preview.status; previewHttpCount = $script:previewHttpCalls
            planExists = (Test-Path -LiteralPath $planPath)
        }) -Compress -Depth 8))
    }

    # Scenario: SYP171-SCN-025; a projected image has no attachment with the same source filename.
    # Purpose: Capture must preserve evidence while refusing to call an unresolved projected image complete.
    It 'InterT157_marks_a_missing_projected_image_identity_as_partial_and_preserves_candidates' {
        $script:mode = 'projected-image-missing'
        $result = Invoke-CaptureFixture
        $manifest = Get-Content -LiteralPath (Join-Path $result.capturePath 'capture.json') -Raw | ConvertFrom-Json
        $page = @($manifest.pages | Where-Object { $_.pageId -ceq '101' })[0]
        $rawPath = Join-Path $result.capturePath $page.snapshotPath
        $candidatePath = Join-Path $result.capturePath $page.candidatePath
        (Test-Path -LiteralPath $rawPath -PathType Leaf) | Should -BeTrue
        (Test-Path -LiteralPath $candidatePath -PathType Leaf) | Should -BeTrue
        [IO.File]::ReadAllText($rawPath) | Should -Match 'ri:filename="diagram.png"'
        [IO.File]::ReadAllText($candidatePath) | Should -Match 'assets/diagram.png'
        @($page.attachments).Count | Should -Be 0
        @($script:requests | Where-Object { $_.Uri -match '/pages/101/attachments(?:\?|$)' }).Count | Should -Be 2
        @($script:requests | Where-Object { $_.Uri -match '/download\?version=' }).Count | Should -Be 0
        $result.status | Should -BeExactly 'partial'
        @($result.reasonCodes) | Should -Contain 'ProjectedImageAttachmentUnresolved'
    }

    # Scenario: SYP171-SCN-026; the saved attachment filename differs only by case from the projected filename.
    # Purpose: Filename identity uses ordinal case-sensitive equality, while captured evidence remains available.
    It 'InterT158_marks_a_case_mismatched_projected_image_identity_as_partial' {
        $script:mode = 'projected-image-case-mismatch'
        $result = Invoke-CaptureFixture
        $manifest = Get-Content -LiteralPath (Join-Path $result.capturePath 'capture.json') -Raw | ConvertFrom-Json
        $page = @($manifest.pages | Where-Object { $_.pageId -ceq '101' })[0]
        $rawPath = Join-Path $result.capturePath $page.snapshotPath
        $candidatePath = Join-Path $result.capturePath $page.candidatePath
        [IO.File]::ReadAllText($rawPath) | Should -Match 'ri:filename="diagram.png"'
        [IO.File]::ReadAllText($candidatePath) | Should -Match 'assets/diagram.png'
        @($page.attachments).Count | Should -Be 1
        $page.attachments[0].attachmentId | Should -BeExactly '501'
        $page.attachments[0].filename | Should -BeExactly 'Diagram.png'
        $assetPath = Join-Path $result.capturePath $page.attachments[0].assetPath
        [Convert]::ToHexString([IO.File]::ReadAllBytes($assetPath)) | Should -BeExactly '010203'
        @($script:requests | Where-Object { $_.Uri -match '/pages/101/attachments(?:\?|$)' }).Count | Should -Be 2
        @($script:requests | Where-Object { $_.Uri -match '/download\?version=' }).Count | Should -Be 1
        $result.status | Should -BeExactly 'partial'
        @($result.reasonCodes) | Should -Contain 'ProjectedImageAttachmentUnresolved'
    }

    # Scenario: SYP171-SCN-027; two stable attachment IDs share the projected image filename.
    # Purpose: Deduplicated bytes do not collapse distinct remote attachment identities into a unique match.
    It 'InterT159_marks_duplicate_projected_image_filename_identities_as_partial' {
        $script:mode = 'projected-image-duplicate'
        $result = Invoke-CaptureFixture
        $manifest = Get-Content -LiteralPath (Join-Path $result.capturePath 'capture.json') -Raw | ConvertFrom-Json
        $page = @($manifest.pages | Where-Object { $_.pageId -ceq '101' })[0]
        [IO.File]::ReadAllText((Join-Path $result.capturePath $page.snapshotPath)) | Should -Match 'ri:filename="diagram.png"'
        [IO.File]::ReadAllText((Join-Path $result.capturePath $page.candidatePath)) | Should -Match 'assets/diagram.png'
        @($page.attachments).Count | Should -Be 2
        @($page.attachments | Select-Object -ExpandProperty attachmentId -Unique).Count | Should -Be 2
        @($page.attachments | Select-Object -ExpandProperty filename -Unique).Count | Should -Be 1
        @($page.attachments | Select-Object -ExpandProperty assetPath -Unique).Count | Should -Be 1
        $assetPath = Join-Path $result.capturePath $page.attachments[0].assetPath
        [Convert]::ToHexString([IO.File]::ReadAllBytes($assetPath)) | Should -BeExactly '010203'
        @($script:requests | Where-Object { $_.Uri -match '/pages/101/attachments(?:\?|$)' }).Count | Should -Be 2
        @($script:requests | Where-Object { $_.Uri -match '/download\?version=' }).Count | Should -Be 2
        $result.status | Should -BeExactly 'partial'
        @($result.reasonCodes) | Should -Contain 'ProjectedImageAttachmentUnresolved'
    }

    # Scenario: SYP171-SCN-028; two projected references resolve to one stable exact filename identity.
    # Purpose: Repeated references remain complete when each maps to the same unique saved attachment identity.
    It 'InterT160_allows_repeated_projected_references_to_one_unique_attachment_identity' {
        $script:mode = 'projected-image-repeat'
        $result = Invoke-CaptureFixture
        $result.status | Should -BeExactly 'complete'
        $manifest = Get-Content -LiteralPath (Join-Path $result.capturePath 'capture.json') -Raw | ConvertFrom-Json
        $page = @($manifest.pages | Where-Object { $_.pageId -ceq '101' })[0]
        $candidatePath = Join-Path $result.capturePath $page.candidatePath
        $candidate = [IO.File]::ReadAllText($candidatePath)
        ([regex]::Matches($candidate, 'assets/diagram\.png')).Count | Should -Be 2
        @($page.attachments).Count | Should -Be 1
        $page.attachments[0].attachmentId | Should -BeExactly '501'
        $page.attachments[0].filename | Should -BeExactly 'diagram.png'
        [IO.File]::ReadAllText((Join-Path $result.capturePath $page.snapshotPath)) | Should -Match 'ri:filename="diagram.png"'
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

    # Scenario: A valid page title can make the actual serialized manifest exceed the committed-source 4 MiB gate.
    # Purpose: Producer admission uses exact UTF-8 serializer bytes and never writes an oversized capture artifact.
    It 'InterT130_rejects_a_prospective_manifest_one_byte_over_the_4MiB_committed_cap' {
        $scope = [ordered]@{ schemaVersion = 1; siteOrigin = $site; cloudId = $cloudId; apiBase = $apiBase; scope = @{ kind = 'page'; pageIds = @('101') } } | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText((Join-Path $script:fixtureRoot 'scope.json'), $scope, [Text.UTF8Encoding]::new($false))
        $script:mode = 'manifest-title-no-attachments'
        $script:manifestTitle = 'x'
        $baseline = Invoke-CaptureFixture
        $baseline.status | Should -Be 'complete'
        $baselineLength = [IO.File]::ReadAllBytes((Join-Path $baseline.capturePath 'capture.json')).Length
        $oversizedTitleLength = (4MB + 1) - $baselineLength + 1
        ($baselineLength + $oversizedTitleLength - 1) | Should -Be (4MB + 1)
        $script:manifestTitle = 'x' * $oversizedTitleLength
        $result = Invoke-CaptureFixture
        $result.status | Should -Be 'partial'
        @($result.reasonCodes) | Should -Contain 'CaptureMetadataBudgetExceeded'
        $manifestPath = Join-Path $result.capturePath 'capture.json'
        $manifestBytes = [IO.File]::ReadAllBytes($manifestPath)
        ($manifestBytes.Length -le 4MB) | Should -BeTrue
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        @($manifest.incompletePageIds) | Should -Contain '101'
        @($manifest.pages).Count | Should -Be 0
        (Test-Path -LiteralPath (Join-Path $result.capturePath 'pages/101/storage.xml')) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $result.capturePath 'pages/101/candidate.md')) | Should -BeFalse
        $audit = Get-Content -LiteralPath (Join-Path $result.capturePath 'capture-unindexed-files.json') -Raw | ConvertFrom-Json
        @($audit.files).Count | Should -Be 1
        $rawFile = Join-Path $result.capturePath $audit.files[0].relativePath
        [IO.File]::ReadAllBytes($rawFile).Length | Should -Be $audit.files[0].length
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($rawFile))).ToLowerInvariant() | Should -BeExactly $audit.files[0].sha256
    }

    It 'InterT131_accepts_a_manifest_at_exactly_the_4MiB_committed_cap' {
        $scope = [ordered]@{ schemaVersion = 1; siteOrigin = $site; cloudId = $cloudId; apiBase = $apiBase; scope = @{ kind = 'page'; pageIds = @('101') } } | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText((Join-Path $script:fixtureRoot 'scope.json'), $scope, [Text.UTF8Encoding]::new($false))
        $script:mode = 'manifest-title-no-attachments'
        $script:manifestTitle = 'x'
        $baseline = Invoke-CaptureFixture
        $baseline.status | Should -Be 'complete'
        $baselineLength = [IO.File]::ReadAllBytes((Join-Path $baseline.capturePath 'capture.json')).Length
        $script:manifestTitle = 'x' * (4MB - $baselineLength + 1)
        $result = Invoke-CaptureFixture
        $result.status | Should -Be 'complete'
        [IO.File]::ReadAllBytes((Join-Path $result.capturePath 'capture.json')).Length | Should -Be 4MB
    }

    It 'UnitT132_rejects_out_of_range_capture_limits_before_source_reads_or_owned_output' {
        $result = Invoke-CaptureFixture -MaxAttachmentAttempts 0
        $result.status | Should -Be 'invalid'
        @($result.reasonCodes) | Should -Contain 'CaptureBudgetInvalid'
        @($script:requests).Count | Should -Be 0
        (Test-Path -LiteralPath (Join-Path $script:fixtureRoot 'adapter/.local')) | Should -BeFalse
    }

    It 'InterT133_stops_at_attachment_attempt_limit_and_audits_the_unfinished_page' {
        $script:mode = 'many-attachments'
        $result = Invoke-CaptureFixture -MaxAttachmentAttempts 1
        $result.status | Should -Be 'partial'
        @($result.reasonCodes) | Should -Contain 'CaptureAttachmentBudgetExceeded'
        @($script:requests | Where-Object Uri -Match '/download\?version=').Count | Should -Be 1
        $manifest = Get-Content -LiteralPath (Join-Path $result.capturePath 'capture.json') -Raw | ConvertFrom-Json
        @($manifest.pages).Count | Should -Be 0
        @($manifest.incompletePageIds) | Should -Contain '101'
        @($manifest.incompletePageIds) | Should -Contain '102'
        $audit = Get-Content -LiteralPath (Join-Path $result.capturePath 'capture-unindexed-files.json') -Raw | ConvertFrom-Json
        @($audit.files).Count | Should -Be 3
        foreach ($file in $audit.files) {
            $path = Join-Path $result.capturePath $file.relativePath
            [IO.File]::ReadAllBytes($path).Length | Should -Be $file.length
            [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($path))).ToLowerInvariant() | Should -BeExactly $file.sha256
        }
        (Test-Path -LiteralPath (Join-Path $result.capturePath 'pages/101/storage.xml')) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $result.capturePath 'pages/101/candidate.md')) | Should -BeTrue
    }

    It 'InterT134_blocks_attachment_download_when_attempt_byte_reservation_will_not_fit' {
        $result = Invoke-CaptureFixture -MaxAttachmentDownloadBytes 2
        $result.status | Should -Be 'partial'
        @($result.reasonCodes) | Should -Contain 'CaptureAttachmentBudgetExceeded'
        @($script:requests | Where-Object Uri -Match '/download\?version=').Count | Should -Be 0
        $manifest = Get-Content -LiteralPath (Join-Path $result.capturePath 'capture.json') -Raw | ConvertFrom-Json
        @($manifest.pages).Count | Should -Be 0
        $audit = Get-Content -LiteralPath (Join-Path $result.capturePath 'capture-unindexed-files.json') -Raw | ConvertFrom-Json
        @($audit.files | Where-Object relativePath -Like 'pages/101/*').Count | Should -Be 2
    }

    It 'InterT135_keeps_duplicate_asset_attempts_but_counts_the_shared_file_once' {
        $script:mode = 'many-attachments-duplicate'
        $baseline = Invoke-CaptureFixture
        $baseline.status | Should -Be 'complete'
        $baselineFiles = @(Get-ChildItem -LiteralPath $baseline.capturePath -File -Recurse | Where-Object Name -ne 'capture.json')
        $logicalDataBytes = [long](($baselineFiles | Measure-Object -Property Length -Sum).Sum)
        $script:attachmentReads = 0
        $script:requests = [System.Collections.Generic.List[object]]::new()
        $bounded = Invoke-CaptureFixture -MaxAttachmentDownloadBytes 78 -MaxAttachmentAttempts 26 -MaxCaptureBytes (16MB + $logicalDataBytes)
        $bounded.status | Should -Be 'complete'
        @($script:requests | Where-Object Uri -Match '/download\?version=').Count | Should -Be 26
        $manifest = Get-Content -LiteralPath (Join-Path $bounded.capturePath 'capture.json') -Raw | ConvertFrom-Json
        @($manifest.pages[0].attachments).Count | Should -Be 26
        @(Get-ChildItem -LiteralPath (Join-Path $bounded.capturePath 'assets') -File).Count | Should -Be 1
        $boundedFiles = @(Get-ChildItem -LiteralPath $bounded.capturePath -File -Recurse | Where-Object Name -ne 'capture.json')
        [long](($boundedFiles | Measure-Object -Property Length -Sum).Sum) | Should -Be $logicalDataBytes
    }

    It 'InterT136_returns_a_valid_file_budget_partial_before_writing_the_current_page' {
        $result = Invoke-CaptureFixture -MaxCaptureBytes (16MB + 1)
        $result.status | Should -Be 'partial'
        @($result.reasonCodes) | Should -Contain 'CaptureFileBudgetExceeded'
        $manifest = Get-Content -LiteralPath (Join-Path $result.capturePath 'capture.json') -Raw | ConvertFrom-Json
        @($manifest.pages).Count | Should -Be 0
        @($manifest.incompletePageIds) | Should -Contain '101'
        (Test-Path -LiteralPath (Join-Path $result.capturePath 'pages/101/storage.xml')) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $result.capturePath 'pages/101/candidate.md')) | Should -BeFalse
        @($script:requests | Where-Object { $_.Uri -match '/pages/101\?body-format=storage(?:&get-draft=true)?$' }).Count | Should -Be 2
        @($script:requests | Where-Object Uri -Match '/pages/101/attachments').Count | Should -Be 0
    }

    It 'InterT137_public_pull_rejects_invalid_capture_limits_before_access_or_HTTP' {
        $pull = New-PullCliFixture
        try {
            [IO.File]::WriteAllText($pull.statePath, '{"requests":[]}', [Text.UTF8Encoding]::new($false))
            $env:CONFLUENCE_BASE_URL = $site
            $env:CONFLUENCE_API_BASE_URL = $apiBase
            $env:CONFLUENCE_CLOUD_ID = $cloudId
            $env:CONFLUENCE_EMAIL = 'fixture@example.invalid'
            $env:CONFLUENCE_API_TOKEN = 'fixture-token-only'
            $env:SYP171_PULL_MOCK_STATE = $pull.statePath
            $env:SYP171_PULL_ACCESS_CALLS = $pull.accessCallsPath
            $result = Invoke-PullCli -Fixture $pull -MaxCaptureBytes (16MB)
            $result.exitCode | Should -Be 30
            $result.result.status | Should -Be 'invalid'
            @($result.result.reasonCodes) | Should -Contain 'CaptureBudgetInvalid'
            (Test-Path -LiteralPath $pull.accessCallsPath) | Should -BeFalse
            @((Read-PullCliState -Fixture $pull).requests).Count | Should -Be 0
            (Test-Path -LiteralPath $pull.targetPath) | Should -BeFalse
        } finally {
            Remove-PullCliFixture -Root $pull.root -Parent $pull.tempParent
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

    # Scenario: A selected capture scope supplies matching compact N, braced B, malformed dashed, or whitespace-padded Cloud ID input.
    # Purpose: Enforce exact dashed-D syntax at the selected-scope boundary without changing generic matching-N tenant behavior.
    # Given: A generic tenant helper accepts matching N and each selected scope has a matching API route.
    # When: Invoke-ConfluenceCapture receives those raw scope inputs.
    # Then: Invalid identities return ScopeSchemaInvalid before reads, private output, or any scope-byte rewrite.
    It 'UnitT55_requires_dashed_D_cloud_id_before_capture_reads_or_output' {
        $transportPath = Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluenceTransport.psm1'
        Import-Module -Name $transportPath -Force
        $compactCloudId = $cloudId.Replace('-', '')
        $compactApiBase = "https://api.atlassian.com/ex/confluence/$compactCloudId"
        Test-ConfluenceTenantConfiguration -ExpectedSiteOrigin $site -ConfiguredSiteOrigin $site -ApiBase $compactApiBase -CloudId $compactCloudId -ExpectedApiBase $compactApiBase -ExpectedCloudId $compactCloudId | Should -BeNullOrEmpty

        $badDashCloudId = 'aaaaaaaa-aaaaaaaa-aaaa-aaaa-aaaaaaaa'
        $badDashCloudId.Length | Should -Be 36
        $cases = @(
            @{ label = 'matching N'; cloudId = $compactCloudId; apiBase = $compactApiBase },
            @{ label = 'braced B'; cloudId = ('{' + $cloudId + '}'); apiBase = ('https://api.atlassian.com/ex/confluence/{' + $cloudId + '}') },
            @{ label = 'malformed D layout'; cloudId = $badDashCloudId; apiBase = ('https://api.atlassian.com/ex/confluence/' + $badDashCloudId) },
            @{ label = 'surrounding whitespace'; cloudId = (' ' + $cloudId); apiBase = ('https://api.atlassian.com/ex/confluence/ ' + $cloudId) }
        )
        foreach ($case in $cases) {
            $scopePath = Join-Path $script:fixtureRoot 'scope.json'
            $scope = Get-Content -LiteralPath $scopePath -Raw | ConvertFrom-Json -AsHashtable -Depth 8
            $scope.cloudId = $case.cloudId
            $scope.apiBase = $case.apiBase
            [IO.File]::WriteAllText($scopePath, ($scope | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
            $scopeBytesBefore = [IO.File]::ReadAllBytes($scopePath)
            $scopeShaBefore = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($scopeBytesBefore)).ToLowerInvariant()

            $result = Invoke-CaptureFixture
            $scopeBytesAfter = [IO.File]::ReadAllBytes($scopePath)
            $scopeShaAfter = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($scopeBytesAfter)).ToLowerInvariant()
            $localPath = Join-Path $script:fixtureRoot 'adapter/.local'
            $observation = [ordered]@{
                input = $case.label; cloudId = $case.cloudId; status = $result.status; reasonCodes = @($result.reasonCodes)
                capturePath = $result.capturePath; httpCount = $script:requests.Count
                localOutputExists = Test-Path -LiteralPath $localPath
                scopeBytesUnchanged = ($scopeShaAfter -ceq $scopeShaBefore)
            }
            $observationJson = ConvertTo-Json -InputObject $observation -Compress -Depth 8
            $result.status | Should -BeExactly 'invalid' -Because $observationJson
            @($result.reasonCodes) | Should -Contain 'ScopeSchemaInvalid' -Because $observationJson
            $result.capturePath | Should -BeExactly '' -Because $observationJson
            $script:requests.Count | Should -Be 0 -Because $observationJson
            (Test-Path -LiteralPath $localPath) | Should -BeFalse -Because $observationJson
            $scopeShaAfter | Should -BeExactly $scopeShaBefore -Because $observationJson
        }
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

    # Scenario: A selected capture scope uses lowercase or uppercase dashed D spelling for the same Cloud ID.
    # Purpose: Keep valid D inputs complete, preserve the selected case in the emitted manifest, and never rewrite the input scope.
    # Given: The scope Cloud ID and its API route use one valid D spelling.
    # When: Invoke-ConfluenceCapture reads and writes the ordinary fixture capture.
    # Then: The capture completes, GETs occur, manifest case matches exactly, and original scope bytes stay unchanged.
    It 'UnitT61_preserves_lowercase_and_uppercase_dashed_D_in_capture_manifest' {
        $upperCloudId = $cloudId.ToUpperInvariant()
        $cases = @(
            @{ label = 'lowercase D'; cloudId = $cloudId },
            @{ label = 'uppercase D'; cloudId = $upperCloudId }
        )
        foreach ($case in $cases) {
            $scopePath = Join-Path $script:fixtureRoot 'scope.json'
            $scope = Get-Content -LiteralPath $scopePath -Raw | ConvertFrom-Json -AsHashtable -Depth 8
            $scope.cloudId = $case.cloudId
            $scope.apiBase = "https://api.atlassian.com/ex/confluence/$($case.cloudId)"
            [IO.File]::WriteAllText($scopePath, ($scope | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
            $scopeBytesBefore = [IO.File]::ReadAllBytes($scopePath)
            $scopeShaBefore = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($scopeBytesBefore)).ToLowerInvariant()

            $result = Invoke-CaptureFixture
            $result.status | Should -BeExactly 'complete' -Because $case.label
            $result.capturePath | Should -Not -BeNullOrEmpty -Because $case.label
            $manifest = Get-Content -LiteralPath (Join-Path $result.capturePath 'capture.json') -Raw | ConvertFrom-Json -Depth 8
            $manifest.cloudId | Should -BeExactly $case.cloudId -Because $case.label
            $script:requests.Count | Should -BeGreaterThan 0 -Because $case.label

            $scopeBytesAfter = [IO.File]::ReadAllBytes($scopePath)
            $scopeShaAfter = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($scopeBytesAfter)).ToLowerInvariant()
            $scopeShaAfter | Should -BeExactly $scopeShaBefore -Because $case.label
        }
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

    # Scenario: The capture scope selects Cloud ID A while process configuration contains a self-consistent API/Cloud ID pair B.
    # Purpose: Pull must bind the configured tenant to the selected scope before calling access validation or the wire.
    It 'InterT90_public_pull_blocks_api_identity_switch_before_access_or_HTTP' {
        $matching = New-PullCliFixture
        try {
            $otherCloudId='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
            $env:CONFLUENCE_BASE_URL = $site
            $env:CONFLUENCE_API_BASE_URL = $apiBase
            $env:CONFLUENCE_CLOUD_ID = $cloudId
            $env:CONFLUENCE_EMAIL = 'fixture@example.invalid'
            $env:CONFLUENCE_API_TOKEN = 'fixture-token-only'
            $env:SYP171_PULL_MOCK_STATE = $matching.statePath
            $env:SYP171_PULL_ACCESS_CALLS = $matching.accessCallsPath
            [IO.File]::WriteAllText($matching.statePath, '{"requests":[]}', [Text.UTF8Encoding]::new($false))

            $matched = Invoke-PullCli -Fixture $matching
            $matched.exitCode | Should -Be 0 -Because (ConvertTo-Json -InputObject $matched.result -Compress -Depth 8)
            $matched.result.status | Should -Be 'complete'
            (Test-Path -LiteralPath $matching.accessCallsPath -PathType Leaf) | Should -BeTrue
            @((Read-PullCliState -Fixture $matching).requests).Count | Should -BeGreaterThan 0
        } finally {
            Remove-PullCliFixture -Root $matching.root -Parent $matching.tempParent
        }

        $pull = New-PullCliFixture
        try {
            $env:CONFLUENCE_API_BASE_URL = "https://api.atlassian.com/ex/confluence/$otherCloudId"
            $env:CONFLUENCE_CLOUD_ID = $otherCloudId
            $env:CONFLUENCE_EMAIL = 'fixture@example.invalid'
            $env:CONFLUENCE_API_TOKEN = 'fixture-token-only'
            $env:SYP171_PULL_MOCK_STATE = $pull.statePath
            $env:SYP171_PULL_ACCESS_CALLS = $pull.accessCallsPath
            [IO.File]::WriteAllText($pull.statePath, '{"requests":[]}', [Text.UTF8Encoding]::new($false))

            $result = Invoke-PullCli -Fixture $pull

            # Check the preflight boundary first so a later capture fixture failure cannot mask an early access call.
            (Test-Path -LiteralPath $pull.accessCallsPath) | Should -BeFalse
            @((Read-PullCliState -Fixture $pull).requests).Count | Should -Be 0
            $result.exitCode | Should -Be 10 -Because (ConvertTo-Json -InputObject $result.result -Compress -Depth 8)
            $result.result.status | Should -Be 'blocked'
            @($result.result.reasonCodes) | Should -Contain 'ApiBaseMismatch'
        } finally {
            Remove-PullCliFixture -Root $pull.root -Parent $pull.tempParent
        }
    }

    # Scenario: The selected Pull scope and process configuration use opposite casing for the same GUID in their own valid API routes.
    # Purpose: The public Pull entry point accepts either spelling only after binding both identities, then reaches mocked access and reads.
    # Given: Selected scope and process configuration use valid D spellings that can differ only by case.
    # When: The public Pull entry point runs against its mocked access and HTTP boundaries.
    # Then: The exact selected D case reaches the capture manifest and scope bytes remain unchanged.
    It 'InterT100_public_pull_accepts_cross_case_selected_tenant_before_access_and_HTTP' {
        $upperCloudId=$cloudId.ToUpperInvariant()
        $upperApiBase="https://api.atlassian.com/ex/confluence/$upperCloudId"
        $cases=@(
            @{configuredCloud=$cloudId;configuredApi=$apiBase;selectedCloud=$upperCloudId;selectedApi=$upperApiBase},
            @{configuredCloud=$upperCloudId;configuredApi=$upperApiBase;selectedCloud=$cloudId;selectedApi=$apiBase}
        )
        foreach($case in $cases){
            $pull=New-PullCliFixture
            try {
                $scope=Get-Content -LiteralPath $pull.scopePath -Raw | ConvertFrom-Json -AsHashtable -Depth 8
                $scope.cloudId=$case.selectedCloud
                $scope.apiBase=$case.selectedApi
                [IO.File]::WriteAllText($pull.scopePath,($scope|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
                $scopeBytesBefore = [IO.File]::ReadAllBytes($pull.scopePath)
                $scopeShaBefore = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($scopeBytesBefore)).ToLowerInvariant()
                [IO.File]::WriteAllText($pull.statePath,'{"requests":[]}',[Text.UTF8Encoding]::new($false))
                $env:CONFLUENCE_BASE_URL=$site
                $env:CONFLUENCE_API_BASE_URL=$case.configuredApi
                $env:CONFLUENCE_CLOUD_ID=$case.configuredCloud
                $env:CONFLUENCE_EMAIL='fixture@example.invalid'
                $env:CONFLUENCE_API_TOKEN='fixture-token-only'
                $env:SYP171_PULL_MOCK_STATE=$pull.statePath
                $env:SYP171_PULL_ACCESS_CALLS=$pull.accessCallsPath

                $result=Invoke-PullCli -Fixture $pull

                $result.exitCode | Should -Be 0 -Because (ConvertTo-Json -InputObject $result.result -Compress -Depth 8)
                $result.result.status | Should -Be 'complete'
                (Test-Path -LiteralPath $pull.accessCallsPath -PathType Leaf) | Should -BeTrue
                @((Read-PullCliState -Fixture $pull).requests).Count | Should -BeGreaterThan 0
                (Test-Path -LiteralPath $pull.targetPath -PathType Container) | Should -BeTrue
                $result.result.capturePath | Should -Not -BeNullOrEmpty
                $manifest = Get-Content -LiteralPath (Join-Path $result.result.capturePath 'capture.json') -Raw | ConvertFrom-Json -Depth 8
                $manifest.cloudId | Should -BeExactly $case.selectedCloud
                $scopeBytesAfter = [IO.File]::ReadAllBytes($pull.scopePath)
                $scopeShaAfter = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($scopeBytesAfter)).ToLowerInvariant()
                $scopeShaAfter | Should -BeExactly $scopeShaBefore
            } finally {
                Remove-PullCliFixture -Root $pull.root -Parent $pull.tempParent
            }
        }
    }

    # Scenario: A selected scope uses an array, number, object, null, or missing property for one of its required identity strings.
    # Purpose: The public Pull entry point rejects malformed identity types before the access validator, remote reads, or capture output.
    It 'InterT95_public_pull_rejects_nonstring_scope_identity_before_access_or_HTTP' {
        $matching = New-PullCliFixture
        try {
            $env:CONFLUENCE_BASE_URL = $site
            $env:CONFLUENCE_API_BASE_URL = $apiBase
            $env:CONFLUENCE_CLOUD_ID = $cloudId
            $env:CONFLUENCE_EMAIL = 'fixture@example.invalid'
            $env:CONFLUENCE_API_TOKEN = 'fixture-token-only'
            $env:SYP171_PULL_MOCK_STATE = $matching.statePath
            $env:SYP171_PULL_ACCESS_CALLS = $matching.accessCallsPath

            $matched = Invoke-PullCli -Fixture $matching
            $matched.exitCode | Should -Be 0 -Because (ConvertTo-Json -InputObject $matched.result -Compress -Depth 8)
            $matched.result.status | Should -Be 'complete'
            (Test-Path -LiteralPath $matching.accessCallsPath -PathType Leaf) | Should -BeTrue
            @((Read-PullCliState -Fixture $matching).requests).Count | Should -BeGreaterThan 0
            (Test-Path -LiteralPath $matching.targetPath -PathType Container) | Should -BeTrue
        } finally {
            Remove-PullCliFixture -Root $matching.root -Parent $matching.tempParent
        }

        $pull = New-PullCliFixture
        try {
            $cases = foreach ($field in @('siteOrigin', 'cloudId', 'apiBase')) {
                foreach ($kind in @('singleton-array', 'number', 'object', 'null', 'missing')) {
                    [pscustomobject]@{ field = $field; kind = $kind }
                }
            }
            $observations = [System.Collections.Generic.List[object]]::new()
            foreach ($case in $cases) {
                $scope = [ordered]@{
                    schemaVersion = 1
                    siteOrigin = $site
                    cloudId = $cloudId
                    apiBase = $apiBase
                    scope = @{ kind = 'space'; spaceId = '55' }
                }
                if ($case.kind -ceq 'missing') {
                    [void] $scope.Remove($case.field)
                } else {
                    $validValue = $scope[$case.field]
                    switch ($case.kind) {
                        'singleton-array' { $scope[$case.field] = @($validValue) }
                        'number' { $scope[$case.field] = 42 }
                        'object' { $scope[$case.field] = @{ invalid = 'not-a-string' } }
                        'null' { $scope[$case.field] = $null }
                    }
                }
                [IO.File]::WriteAllText($pull.scopePath, ($scope | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
                [IO.File]::WriteAllText($pull.statePath, '{"requests":[]}', [Text.UTF8Encoding]::new($false))
                if (Test-Path -LiteralPath $pull.accessCallsPath) { Remove-Item -LiteralPath $pull.accessCallsPath -Force }
                $env:CONFLUENCE_BASE_URL = $site
                $env:CONFLUENCE_API_BASE_URL = $apiBase
                $env:CONFLUENCE_CLOUD_ID = $cloudId
                $env:CONFLUENCE_EMAIL = 'fixture@example.invalid'
                $env:CONFLUENCE_API_TOKEN = 'fixture-token-only'
                $env:SYP171_PULL_MOCK_STATE = $pull.statePath
                $env:SYP171_PULL_ACCESS_CALLS = $pull.accessCallsPath

                $exitCode = -1
                $status = 'no-structured-result'
                $reasonCodes = @()
                $cliError = $null
                try {
                    $result = Invoke-PullCli -Fixture $pull
                    $exitCode = $result.exitCode
                    $status = [string] $result.result.status
                    $reasonCodes = @($result.result.reasonCodes)
                } catch {
                    $cliError = $_.Exception.Message
                }
                $observations.Add([pscustomobject]@{
                    field = $case.field; kind = $case.kind; exitCode = $exitCode
                    status = $status; reasonCodes = $reasonCodes; error = $cliError
                    accessCalled = Test-Path -LiteralPath $pull.accessCallsPath -PathType Leaf
                    wireCount = @((Read-PullCliState -Fixture $pull).requests).Count
                    captureOutputExists = Test-Path -LiteralPath $pull.targetPath -PathType Container
                })
            }

            $observedJson = ConvertTo-Json -InputObject @($observations.ToArray()) -Compress -Depth 8
            @($observations | Where-Object accessCalled).Count | Should -Be 0 -Because $observedJson
            @($observations | Where-Object { $_.wireCount -ne 0 }).Count | Should -Be 0 -Because $observedJson
            @($observations | Where-Object captureOutputExists).Count | Should -Be 0 -Because $observedJson
            @($observations | Where-Object {
                $_.exitCode -ne 30 -or $_.status -cne 'invalid' -or
                @($_.reasonCodes) -cnotcontains 'ScopeSchemaInvalid' -or $null -ne $_.error
            }).Count | Should -Be 0 -Because $observedJson
        } finally {
            Remove-PullCliFixture -Root $pull.root -Parent $pull.tempParent
        }
    }

    # Scenario: The public Pull CLI receives matching-N, B, malformed-D, or whitespace-padded selected scope identity.
    # Purpose: Reject non-D selected scope before the access validator, HTTP wire, or capture output while generic matching-N remains compatible.
    # Given: The selected scope and process configuration use the same exact identity spelling and a valid fixture route.
    # When: Run the real Pull CLI entry point with its access and HTTP boundaries instrumented.
    # Then: Invalid selected identities return exit 30/ScopeSchemaInvalid with no access, HTTP, capture path, or scope-byte rewrite.
    It 'InterT105_rejects_selected_non_D_cloud_id_before_access_HTTP_or_output' {
        Import-Module -Name (Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluenceTransport.psm1') -Force
        $compactCloudId = $cloudId.Replace('-', '')
        $compactApiBase = "https://api.atlassian.com/ex/confluence/$compactCloudId"
        Test-ConfluenceTenantConfiguration -ExpectedSiteOrigin $site -ConfiguredSiteOrigin $site -ApiBase $compactApiBase -CloudId $compactCloudId -ExpectedApiBase $compactApiBase -ExpectedCloudId $compactCloudId | Should -BeNullOrEmpty

        $badDashCloudId = 'aaaaaaaa-aaaaaaaa-aaaa-aaaa-aaaaaaaa'
        $cases = @(
            @{ label = 'matching N'; cloudId = $compactCloudId; apiBase = $compactApiBase },
            @{ label = 'braced B'; cloudId = ('{' + $cloudId + '}'); apiBase = ('https://api.atlassian.com/ex/confluence/{' + $cloudId + '}') },
            @{ label = 'malformed D layout'; cloudId = $badDashCloudId; apiBase = ('https://api.atlassian.com/ex/confluence/' + $badDashCloudId) },
            @{ label = 'surrounding whitespace'; cloudId = (' ' + $cloudId); apiBase = ('https://api.atlassian.com/ex/confluence/ ' + $cloudId) }
        )
        foreach ($case in $cases) {
            $pull = New-PullCliFixture
            try {
                $scope = Get-Content -LiteralPath $pull.scopePath -Raw | ConvertFrom-Json -AsHashtable -Depth 8
                $scope.cloudId = $case.cloudId
                $scope.apiBase = $case.apiBase
                [IO.File]::WriteAllText($pull.scopePath, ($scope | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
                $scopeBytesBefore = [IO.File]::ReadAllBytes($pull.scopePath)
                $scopeShaBefore = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($scopeBytesBefore)).ToLowerInvariant()
                [IO.File]::WriteAllText($pull.statePath, '{"requests":[]}', [Text.UTF8Encoding]::new($false))
                $env:CONFLUENCE_BASE_URL = $site
                $env:CONFLUENCE_API_BASE_URL = $case.apiBase
                $env:CONFLUENCE_CLOUD_ID = $case.cloudId
                $env:CONFLUENCE_EMAIL = 'fixture@example.invalid'
                $env:CONFLUENCE_API_TOKEN = 'fixture-token-only'
                $env:SYP171_PULL_MOCK_STATE = $pull.statePath
                $env:SYP171_PULL_ACCESS_CALLS = $pull.accessCallsPath

                $result = Invoke-PullCli -Fixture $pull
                $wireCount = @((Read-PullCliState -Fixture $pull).requests).Count
                $accessCalled = Test-Path -LiteralPath $pull.accessCallsPath -PathType Leaf
                $captureOutputExists = Test-Path -LiteralPath $pull.targetPath -PathType Container
                $scopeBytesAfter = [IO.File]::ReadAllBytes($pull.scopePath)
                $scopeShaAfter = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($scopeBytesAfter)).ToLowerInvariant()
                $observationJson = ConvertTo-Json -InputObject ([ordered]@{
                    input = $case.label; cloudId = $case.cloudId; exitCode = $result.exitCode
                    status = $result.result.status; reasonCodes = @($result.result.reasonCodes)
                    accessCalled = $accessCalled; wireCount = $wireCount
                    capturePath = $result.result.capturePath; captureOutputExists = $captureOutputExists
                    scopeBytesUnchanged = ($scopeShaAfter -ceq $scopeShaBefore)
                }) -Compress -Depth 8

                $result.exitCode | Should -Be 30 -Because $observationJson
                $result.result.status | Should -BeExactly 'invalid' -Because $observationJson
                @($result.result.reasonCodes) | Should -Contain 'ScopeSchemaInvalid' -Because $observationJson
                $result.result.capturePath | Should -BeExactly '' -Because $observationJson
                $accessCalled | Should -BeFalse -Because $observationJson
                $wireCount | Should -Be 0 -Because $observationJson
                $captureOutputExists | Should -BeFalse -Because $observationJson
                $scopeShaAfter | Should -BeExactly $scopeShaBefore -Because $observationJson
            } finally {
                Remove-PullCliFixture -Root $pull.root -Parent $pull.tempParent
            }
        }
    }

    # Scenario: Process configuration uses compact N while the selected Pull scope stores the same tenant as dashed D.
    # Purpose: Stop a mixed-representation identity at preflight before invoking access validation or the HTTP wire.
    It 'InterT110_public_pull_blocks_mixed_D_N_identity_before_access_and_HTTP' {
        $compactCloudId=$cloudId.Replace('-', '')
        $compactApiBase="https://api.atlassian.com/ex/confluence/$compactCloudId"
        $pull=New-PullCliFixture
        try {
            [IO.File]::WriteAllText($pull.statePath,'{"requests":[]}',[Text.UTF8Encoding]::new($false))
            $env:CONFLUENCE_BASE_URL=$site
            $env:CONFLUENCE_API_BASE_URL=$compactApiBase
            $env:CONFLUENCE_CLOUD_ID=$compactCloudId
            $env:CONFLUENCE_EMAIL='fixture@example.invalid'
            $env:CONFLUENCE_API_TOKEN='fixture-token-only'
            $env:SYP171_PULL_MOCK_STATE=$pull.statePath
            $env:SYP171_PULL_ACCESS_CALLS=$pull.accessCallsPath

            $result=Invoke-PullCli -Fixture $pull
            $observation=[pscustomobject]@{
                accessCalled=(Test-Path -LiteralPath $pull.accessCallsPath -PathType Leaf)
                wireCount=@((Read-PullCliState -Fixture $pull).requests).Count
                exitCode=$result.exitCode
                status=$result.result.status
                reasonCodes=@($result.result.reasonCodes)
            }
            $observationJson=ConvertTo-Json -InputObject $observation -Compress -Depth 8
            $observation.accessCalled | Should -BeFalse -Because $observationJson
            $observation.wireCount | Should -Be 0 -Because $observationJson
            $observation.exitCode | Should -Be 10 -Because $observationJson
            $observation.status | Should -Be 'blocked' -Because $observationJson
            $observation.reasonCodes | Should -Contain 'ApiBaseMismatch' -Because $observationJson
        } finally {
            Remove-PullCliFixture -Root $pull.root -Parent $pull.tempParent
        }
    }

    # Scenario: A successful synthetic capture creates a complete candidate tree.
    # Purpose: Every capture-owned directory and file starts with restrictive permissions and keeps them after finalization.
    It 'InterT120_protects_capture_owned_tree_at_creation' {
        if (-not $IsWindows) {
            $unixModeType = [Type]::GetType('System.IO.UnixFileMode')
            $optionsType = [Type]::GetType('System.IO.FileStreamOptions')
            $directoryMethod = $null
            $unixCreateMode = $null
            if ($null -ne $unixModeType) {
                $directoryMethod = [IO.Directory].GetMethod('CreateDirectory', [Type[]] @([string], $unixModeType))
            }
            if ($null -ne $optionsType) { $unixCreateMode = $optionsType.GetProperty('UnixCreateMode') }
            if ($null -eq $directoryMethod -or $null -eq $unixCreateMode) {
                $script:requests.Clear()
                $unavailable = Invoke-CaptureFixture
                $script:requests.Count | Should -Be 0
                $unavailable.status | Should -BeExactly 'failed'
                @($unavailable.reasonCodes) | Should -Contain 'CapturePrivatePermissionsUnavailable'
                return
            }
        }

        $permissionLog = Join-Path $script:fixtureRoot 'private-write-observations.jsonl'
        $oldPermissionLog = [Environment]::GetEnvironmentVariable('SYP171_CAPTURE_TEST_PERMISSION_LOG', 'Process')
        [Environment]::SetEnvironmentVariable('SYP171_CAPTURE_TEST_PERMISSION_LOG', $permissionLog, 'Process')
        try { $result = Invoke-CaptureFixture -ObservePrivateWrites }
        finally { [Environment]::SetEnvironmentVariable('SYP171_CAPTURE_TEST_PERMISSION_LOG', $oldPermissionLog, 'Process') }
        $result.status | Should -BeExactly 'complete' -Because ('reasonCodes=' + (@($result.reasonCodes) -join ',') + '; requests=' + $script:requests.Count)
        $writeObservations = @(Get-Content -LiteralPath $permissionLog | ForEach-Object { ConvertFrom-Json -InputObject $_ -AsHashtable })
        $writeObservations.Count | Should -BeGreaterThan 0
        $firstWrite = $writeObservations[0]
        $firstWrite.fileName | Should -BeExactly 'storage.xml'
        if ($IsWindows) {
            $expectedSids = [string[]] @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18')
            [Array]::Sort($expectedSids, [StringComparer]::Ordinal)
            $firstWrite.fileProtected | Should -BeTrue -Because 'File ACL is inspected from its open handle immediately before the first content write.'
            @($firstWrite.fileSids).Count | Should -Be 2
            @($firstWrite.fileSids | Where-Object { $_ -notin $expectedSids }).Count | Should -Be 0
            @($expectedSids | Where-Object { $_ -notin @($firstWrite.fileSids) }).Count | Should -Be 0
            $firstWrite.parentProtected | Should -BeTrue
            $firstWrite.pagesProtected | Should -BeTrue
            $firstWrite.stageProtected | Should -BeTrue
            @($firstWrite.parentSids).Count | Should -Be 2
            @($firstWrite.pagesSids).Count | Should -Be 2
            @($firstWrite.stageSids).Count | Should -Be 2
            @($firstWrite.parentSids | Where-Object { $_ -notin $expectedSids }).Count | Should -Be 0
            @($firstWrite.pagesSids | Where-Object { $_ -notin $expectedSids }).Count | Should -Be 0
            @($firstWrite.stageSids | Where-Object { $_ -notin $expectedSids }).Count | Should -Be 0
        } else {
            $firstWrite.fileMode | Should -BeExactly 'UserRead, UserWrite'
            $firstWrite.parentMode | Should -BeExactly 'UserRead, UserWrite, UserExecute'
            $firstWrite.pagesMode | Should -BeExactly 'UserRead, UserWrite, UserExecute'
            $firstWrite.stageMode | Should -BeExactly 'UserRead, UserWrite, UserExecute'
        }
        if ($IsWindows) { Add-Type -AssemblyName System.IO.FileSystem.AccessControl }
        $paths = @($result.capturePath) + @(Get-ChildItem -LiteralPath $result.capturePath -Force -Recurse | ForEach-Object FullName)
        foreach ($path in $paths) {
            $item = Get-Item -LiteralPath $path -Force
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) | Should -Be ([IO.FileAttributes]::Normal -band [IO.FileAttributes]::ReparsePoint)
            if ($IsWindows) {
                $security = if ($item.PSIsContainer) {
                    [IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new($path))
                } else {
                    [IO.FileSystemAclExtensions]::GetAccessControl([IO.FileInfo]::new($path))
                }
                $security.AreAccessRulesProtected | Should -BeTrue -Because $path
                $rules = @($security.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
                $rules.Count | Should -Be 2 -Because $path
                $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
                $systemSid = 'S-1-5-18'
                @($rules | Where-Object { $_.IdentityReference.Value -ceq $userSid }).Count | Should -Be 1 -Because $path
                @($rules | Where-Object { $_.IdentityReference.Value -ceq $systemSid }).Count | Should -Be 1 -Because $path
                @($rules | Where-Object {
                    $_.AccessControlType -cne [Security.AccessControl.AccessControlType]::Allow -or
                    ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -ne [Security.AccessControl.FileSystemRights]::FullControl
                }).Count | Should -Be 0 -Because $path
            } else {
                $mode = if ($item.PSIsContainer) { [IO.Directory]::GetUnixFileMode($path) } else { [IO.File]::GetUnixFileMode($path) }
                $modeText = [string]$mode
                $expected = if ($item.PSIsContainer) {
                    [Enum]::Parse($unixModeType, 'UserRead, UserWrite, UserExecute')
                } else {
                    [Enum]::Parse($unixModeType, 'UserRead, UserWrite')
                }
                $mode | Should -Be $expected -Because "$path mode=$modeText"
            }
        }
    }

    # Scenario: The direct capture runtime cannot create and inspect protected private files.
    # Purpose: Capability failure is reported before any captured-content request or output tree creation.
    It 'InterT125_direct_capture_blocks_before_source_reads_when_private_permissions_unavailable' {
        $script:requests.Clear()
        $result = Invoke-CaptureFixture -PrivatePermissionsUnavailable
        $result.status | Should -BeExactly 'failed'
        @($result.reasonCodes) | Should -Contain 'CapturePrivatePermissionsUnavailable'
        $script:requests.Count | Should -Be 0
        (Test-Path -LiteralPath (Join-Path $script:fixtureRoot 'adapter/.local')) | Should -BeFalse
    }

    # Scenario: Public Pull has a valid tenant but lacks the runtime capability for protected private capture.
    # Purpose: The CLI rejects the capture before its access validator, HTTP wire, or target output creation.
    It 'InterT126_public_pull_blocks_before_access_when_private_permissions_unavailable' {
        $pull = New-PullCliFixture
        try {
            $captureModule = Join-Path (Split-Path -Parent $pull.pullPath) 'ConfluenceDocs.psm1'
            $moduleText = [IO.File]::ReadAllText($captureModule)
            $capabilityStart = $moduleText.IndexOf('function Test-ConfluenceCapturePrivatePermissions {', [StringComparison]::Ordinal)
            $capabilityEnd = $moduleText.IndexOf('function New-CaptureDirectorySecurity {', $capabilityStart, [StringComparison]::Ordinal)
            if ($capabilityStart -lt 0 -or $capabilityEnd -le $capabilityStart) { throw 'Could not isolate capability helper in copied Pull installation.' }
            $capabilityStub = "function Test-ConfluenceCapturePrivatePermissions { return `$false }`r`n`r`n"
            $moduleText = $moduleText.Substring(0, $capabilityStart) + $capabilityStub + $moduleText.Substring($capabilityEnd)
            [IO.File]::WriteAllText($captureModule, $moduleText, [Text.UTF8Encoding]::new($false))

            $env:CONFLUENCE_BASE_URL = $site
            $env:CONFLUENCE_API_BASE_URL = $apiBase
            $env:CONFLUENCE_CLOUD_ID = $cloudId
            $env:CONFLUENCE_EMAIL = 'fixture@example.invalid'
            $env:CONFLUENCE_API_TOKEN = 'fixture-token-only'
            $env:SYP171_PULL_MOCK_STATE = $pull.statePath
            $env:SYP171_PULL_ACCESS_CALLS = $pull.accessCallsPath
            [IO.File]::WriteAllText($pull.statePath, '{"requests":[]}', [Text.UTF8Encoding]::new($false))

            $result = Invoke-PullCli -Fixture $pull
            $result.exitCode | Should -Be 10 -Because (ConvertTo-Json -InputObject $result.result -Compress -Depth 8)
            $result.result.status | Should -BeExactly 'blocked'
            @($result.result.reasonCodes) | Should -Contain 'CapturePrivatePermissionsUnavailable'
            (Test-Path -LiteralPath $pull.accessCallsPath) | Should -BeFalse
            @((Read-PullCliState -Fixture $pull).requests).Count | Should -Be 0
            (Test-Path -LiteralPath $pull.targetPath) | Should -BeFalse
        } finally {
            Remove-PullCliFixture -Root $pull.root -Parent $pull.tempParent
        }
    }

    # Scenario: A valid synthetic attachment has already been downloaded when its newly created asset cannot be permission-verified.
    # Purpose: The failed later file write is blocked at that file's first content byte while prior reads remain truthfully acknowledged.
    It 'InterT127_late_asset_permission_failure_blocks_its_first_content_write' {
        $oldFailAsset = [Environment]::GetEnvironmentVariable('SYP171_CAPTURE_TEST_FAIL_ASSET_PERMISSION', 'Process')
        [Environment]::SetEnvironmentVariable('SYP171_CAPTURE_TEST_FAIL_ASSET_PERMISSION', '1', 'Process')
        try { $result = Invoke-CaptureFixture -FailAssetPermissionBeforeWrite }
        finally { [Environment]::SetEnvironmentVariable('SYP171_CAPTURE_TEST_FAIL_ASSET_PERMISSION', $oldFailAsset, 'Process') }

        $result.status | Should -BeExactly 'failed'
        @($result.reasonCodes) | Should -Contain 'CapturePrivatePermissionsUnavailable'
        (Test-Path -LiteralPath $result.capturePath -PathType Container) | Should -BeTrue
        $script:requests.Count | Should -BeGreaterThan 0
        @($script:requests | Where-Object { $_.Uri -match '/child/attachment/501/download\?version=1$' }).Count | Should -Be 1
        $rawPage = Join-Path $result.capturePath 'pages/101/storage.xml'
        (Test-Path -LiteralPath $rawPage -PathType Leaf) | Should -BeTrue
        (Get-Item -LiteralPath $rawPage).Length | Should -BeGreaterThan 0
        $assetFiles = @(Get-ChildItem -LiteralPath (Join-Path $result.capturePath 'assets') -File)
        $assetFiles.Count | Should -Be 1
        $assetFiles[0].Length | Should -Be 0 -Because 'The private permission recheck occurs after CreateNew but before the first asset data write.'
        (Test-Path -LiteralPath (Join-Path $result.capturePath 'capture.json')) | Should -BeFalse
    }

    It 'InterT138_reserves_one_byte_for_zero_length_downloads_and_accepts_only_empty_payloads' {
        $scope = [ordered]@{ schemaVersion = 1; siteOrigin = $site; cloudId = $cloudId; apiBase = $apiBase; scope = @{ kind = 'page'; pageIds = @('101') } } | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText((Join-Path $script:fixtureRoot 'scope.json'), $scope, [Text.UTF8Encoding]::new($false))
        $script:mode = 'zero-size-attachment-empty'
        $empty = Invoke-CaptureFixture
        $emptyDownload = @($script:requests | Where-Object Uri -Match '/download\?version=')
        $emptyDownload.Count | Should -Be 1
        $emptyDownload[0].ResponseLimitBytes | Should -Be 1
        $empty.status | Should -Be 'complete'
        $emptyManifest = Get-Content -LiteralPath (Join-Path $empty.capturePath 'capture.json') -Raw | ConvertFrom-Json
        $emptyAsset = Join-Path $empty.capturePath $emptyManifest.pages[0].attachments[0].assetPath
        (Get-Item -LiteralPath $emptyAsset).Length | Should -Be 0

        $script:mode = 'zero-size-attachment-nonempty'
        $script:attachmentReads = 0
        $script:requests = [System.Collections.Generic.List[object]]::new()
        $nonempty = Invoke-CaptureFixture
        $nonempty.status | Should -Be 'partial'
        @($nonempty.reasonCodes) | Should -Contain 'AttachmentBytesMismatch'
        $nonemptyDownload = @($script:requests | Where-Object Uri -Match '/download\?version=')
        $nonemptyDownload.Count | Should -Be 1
        $nonemptyDownload[0].ResponseLimitBytes | Should -Be 1
        $nonemptyManifest = Get-Content -LiteralPath (Join-Path $nonempty.capturePath 'capture.json') -Raw | ConvertFrom-Json
        $nonemptyPage = @($nonemptyManifest.pages | Where-Object pageId -eq '101')
        $nonemptyPage.Count | Should -Be 1
        @($nonemptyPage[0].attachments).Count | Should -Be 0
        @(Get-ChildItem -LiteralPath (Join-Path $nonempty.capturePath 'assets') -File -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It 'InterT139_persists_the_published_raw_body_before_storage_projection' {
        $scope = [ordered]@{ schemaVersion = 1; siteOrigin = $site; cloudId = $cloudId; apiBase = $apiBase; scope = @{ kind = 'page'; pageIds = @('101') } } | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText((Join-Path $script:fixtureRoot 'scope.json'), $scope, [Text.UTF8Encoding]::new($false))
        $orderLog = Join-Path $script:fixtureRoot 'raw-projection-order.txt'
        $oldOrderLog = [Environment]::GetEnvironmentVariable('SYP171_CAPTURE_TEST_RAW_PROJECTION_ORDER', 'Process')
        [Environment]::SetEnvironmentVariable('SYP171_CAPTURE_TEST_RAW_PROJECTION_ORDER', $orderLog, 'Process')
        try { $result = Invoke-CaptureFixture -ObserveRawProjectionOrder }
        finally { [Environment]::SetEnvironmentVariable('SYP171_CAPTURE_TEST_RAW_PROJECTION_ORDER', $oldOrderLog, 'Process') }
        $result.status | Should -BeExactly 'complete'
        $events = @(Get-Content -LiteralPath $orderLog)
        ($events -join ',') | Should -BeExactly 'raw-write,projection'
        (Test-Path -LiteralPath (Join-Path $result.capturePath 'pages/101/storage.xml') -PathType Leaf) | Should -BeTrue
    }

    It 'InterT140_debits_the_pre_request_reservation_even_when_an_attachment_request_fails' {
        $script:mode = 'many-attachments-failed-first'
        $result = Invoke-CaptureFixture -MaxAttachmentDownloadBytes 3 -MaxAttachmentAttempts 26
        $result.status | Should -BeExactly 'partial'
        @($result.reasonCodes) | Should -Contain 'AttachmentDownloadFailed'
        @($result.reasonCodes) | Should -Contain 'CaptureAttachmentBudgetExceeded'
        $downloads = @($script:requests | Where-Object Uri -Match '/download\?version=')
        $downloads.Count | Should -Be 1
        $downloads[0].ResponseLimitBytes | Should -Be 3
        $manifest = Get-Content -LiteralPath (Join-Path $result.capturePath 'capture.json') -Raw | ConvertFrom-Json
        @($manifest.pages).Count | Should -Be 0
        @($manifest.incompletePageIds) | Should -Contain '101'
        $audit = Get-Content -LiteralPath (Join-Path $result.capturePath 'capture-unindexed-files.json') -Raw | ConvertFrom-Json
        @($audit.files | Where-Object relativePath -Like 'pages/101/*').Count | Should -Be 2
    }

    It 'InterT141_enforces_the_total_file_budget_across_pages' {
        $baseline = Invoke-CaptureFixture
        $baseline.status | Should -BeExactly 'complete'
        $baselineManifest = Get-Content -LiteralPath (Join-Path $baseline.capturePath 'capture.json') -Raw | ConvertFrom-Json
        $firstPage = @($baselineManifest.pages | Where-Object pageId -CEQ '101')[0]
        $firstPagePaths = @($firstPage.snapshotPath, $firstPage.candidatePath) + @($firstPage.attachments | ForEach-Object assetPath | Sort-Object -Unique)
        $firstPageBytes = [long]0
        foreach ($relativePath in $firstPagePaths) { $firstPageBytes += [IO.File]::ReadAllBytes((Join-Path $baseline.capturePath $relativePath)).LongLength }

        $script:requests = [System.Collections.Generic.List[object]]::new()
        $script:attachmentReads = 0
        $bounded = Invoke-CaptureFixture -MaxCaptureBytes (16MB + $firstPageBytes)
        $bounded.status | Should -BeExactly 'partial'
        @($bounded.reasonCodes) | Should -Contain 'CaptureFileBudgetExceeded'
        $manifest = Get-Content -LiteralPath (Join-Path $bounded.capturePath 'capture.json') -Raw | ConvertFrom-Json
        @($manifest.pages | Where-Object pageId -CEQ '101').Count | Should -Be 1
        @($manifest.pages | Where-Object pageId -CEQ '102').Count | Should -Be 0
        @($manifest.incompletePageIds) | Should -Contain '102'
        (Test-Path -LiteralPath (Join-Path $bounded.capturePath 'pages/102/storage.xml')) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $bounded.capturePath 'pages/102/candidate.md')) | Should -BeFalse
        @($script:requests | Where-Object { $_.Uri -match '/pages/102\?body-format=storage(?:&get-draft=true)?$' }).Count | Should -Be 2
        @($script:requests | Where-Object Uri -Match '/pages/102/attachments').Count | Should -Be 0
    }

    It 'InterT142_accepts_one_thousand_small_attachment_identities_at_the_default_attempt_boundary' {
        $script:mode = 'many-attachments-1000'
        $result = Invoke-CaptureFixture -MaxAttachmentDownloadBytes 1000 -MaxAttachmentAttempts 1000
        $result.status | Should -BeExactly 'complete'
        $downloads = @($script:requests | Where-Object Uri -Match '/download\?version=')
        $downloads.Count | Should -Be 1000
        @($downloads | Where-Object ResponseLimitBytes -NE 1).Count | Should -Be 0
        $manifest = Get-Content -LiteralPath (Join-Path $result.capturePath 'capture.json') -Raw | ConvertFrom-Json
        @($manifest.pages[0].attachments).Count | Should -Be 1000
        $assetFiles = @(Get-ChildItem -LiteralPath (Join-Path $result.capturePath 'assets') -File)
        $assetFiles.Count | Should -Be 1
        $assetFiles[0].Length | Should -Be 0
    }

    It 'InterT143_bounds_one_thousand_and_one_small_identities_without_false_completion' {
        $script:mode = 'many-attachments-1001'
        $result = Invoke-CaptureFixture -MaxAttachmentDownloadBytes 1000 -MaxAttachmentAttempts 1000
        $result.status | Should -BeExactly 'partial'
        @($result.reasonCodes) | Should -Contain 'CaptureAttachmentBudgetExceeded'
        @($script:requests | Where-Object Uri -Match '/download\?version=').Count | Should -Be 1000
        $manifest = Get-Content -LiteralPath (Join-Path $result.capturePath 'capture.json') -Raw | ConvertFrom-Json
        @($manifest.pages).Count | Should -Be 0
        @($manifest.incompletePageIds) | Should -Contain '101'
        @($manifest.incompletePageIds) | Should -Contain '102'
    }

    It 'UnitT144_rejects_page_scope_minimal_metadata_overflow_before_source_reads' {
        $largePageId = '9' * (4MB + 1)
        $scope = [ordered]@{ schemaVersion = 1; siteOrigin = $site; cloudId = $cloudId; apiBase = $apiBase; scope = @{ kind = 'page'; pageIds = @($largePageId) } } | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText((Join-Path $script:fixtureRoot 'scope.json'), $scope, [Text.UTF8Encoding]::new($false))
        $result = Invoke-CaptureFixture
        $result.status | Should -BeExactly 'invalid'
        @($result.reasonCodes) | Should -Contain 'CaptureMetadataBudgetExceeded'
        @($script:requests).Count | Should -Be 0
        (Test-Path -LiteralPath (Join-Path $script:fixtureRoot 'adapter/.local')) | Should -BeFalse
    }

    It 'InterT145_emits_a_minimal_partial_when_space_page_ids_exceed_metadata_capacity' {
        $script:mode = 'large-space-id-list'
        $script:largePageId = '8' * (4MB + 1)
        $result = Invoke-CaptureFixture
        $result.status | Should -BeExactly 'partial'
        @($result.reasonCodes) | Should -Contain 'CaptureMetadataBudgetExceeded'
        @($script:requests).Count | Should -Be 1
        $script:requests[0].Uri | Should -Match '/spaces/55/pages'
        $manifest = Get-Content -LiteralPath (Join-Path $result.capturePath 'capture.json') -Raw | ConvertFrom-Json
        @($manifest.pages).Count | Should -Be 0
        @($manifest.incompletePageIds).Count | Should -Be 0
        (Test-Path -LiteralPath (Join-Path $result.capturePath 'pages/101/storage.xml')) | Should -BeFalse
    }

    It 'UnitT146_bounds_audit_overflow_to_a_valid_header_with_an_omitted_file_count' {
        Import-Module -Name $modulePath -Force
        $module = @(Get-Module | Where-Object Path -CEQ $modulePath | Select-Object -Last 1)[0]
        $module | Should -Not -BeNullOrEmpty
        $manifest = [ordered]@{ schemaVersion = 1; captureId = 'test-capture'; capturedAtUtc = '2026-10-14T00:00:00Z'; status = 'partial'; reasonCodes = @('CaptureFileBudgetExceeded'); incompletePageIds = @('101'); pages = @() }
        $unindexed = [System.Collections.Generic.List[object]]::new()
        for ($index = 0; $index -lt 150000; $index++) {
            $suffix = $index.ToString('D6')
            $unindexed.Add([ordered]@{ relativePath = "assets/$suffix-$('a' * 64)"; length = 0; sha256 = ('b' * 64) })
        }
        $plan = & $module {
            param($TestManifest, $TestFiles)
            Get-CaptureTerminalPlan -Manifest $TestManifest -UnindexedFiles $TestFiles -DataBytes 0 -MaxCaptureBytes 1GB
        } $manifest $unindexed.ToArray()
        $plan.accepted | Should -BeTrue
        $plan.auditIncomplete | Should -BeTrue
        $plan.manifestBytes.LongLength | Should -BeLessOrEqual 4MB
        ($plan.manifestBytes.LongLength + $plan.auditBytes.LongLength) | Should -BeLessOrEqual 16MB
        @($plan.manifest.reasonCodes) | Should -Contain 'CaptureAuditIncomplete'
        $audit = $plan.auditText | ConvertFrom-Json
        $audit.status | Should -BeExactly 'incomplete'
        $audit.omittedFileCount | Should -Be 150000
        @($audit.files).Count | Should -Be 0
    }

    It 'InterT147_returns_failed_with_the_retained_stage_when_a_private_file_write_fails' {
        $oldFailWrite = [Environment]::GetEnvironmentVariable('SYP171_CAPTURE_TEST_FAIL_CANDIDATE_WRITE', 'Process')
        [Environment]::SetEnvironmentVariable('SYP171_CAPTURE_TEST_FAIL_CANDIDATE_WRITE', '1', 'Process')
        try { $result = Invoke-CaptureFixture -FailCandidateWrite }
        finally { [Environment]::SetEnvironmentVariable('SYP171_CAPTURE_TEST_FAIL_CANDIDATE_WRITE', $oldFailWrite, 'Process') }
        $result.status | Should -BeExactly 'failed'
        @($result.reasonCodes) | Should -Contain 'CaptureFailure'
        $result.capturePath | Should -Match '\.staging$'
        (Test-Path -LiteralPath (Join-Path $result.capturePath 'pages/101/storage.xml') -PathType Leaf) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $result.capturePath 'pages/101/candidate.md') -PathType Leaf) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $result.capturePath 'capture.json')) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $script:fixtureRoot 'adapter/.local/captures/capture-eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee')) | Should -BeFalse
    }

    It 'UnitT148_preserves_unexpected_stage_and_final_capture_collisions' {
        foreach ($collision in @('stage', 'final')) {
            $result = Invoke-CaptureFixture -CaptureCollision $collision
            $result.status | Should -BeExactly 'failed' -Because $collision
            @($result.reasonCodes) | Should -Contain 'CaptureStagingConflict' -Because $collision
            @($script:requests).Count | Should -Be 0 -Because $collision
            $collisionName = if ($collision -eq 'stage') { 'capture-eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee.staging' } else { 'capture-eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' }
            $marker = Join-Path (Join-Path $script:fixtureRoot "adapter/.local/captures/$collisionName") 'collision-marker.txt'
            (Get-Content -LiteralPath $marker -Raw) | Should -BeExactly 'preserve' -Because $collision
        }
    }

    It 'InterT149_rejects_an_existing_capture_target_junction_before_remote_io' {
        $targetDirectory = Join-Path $script:fixtureRoot 'capture-target-junction-target'
        $linkDirectory = Join-Path $script:fixtureRoot 'capture-target-junction'
        New-Item -ItemType Directory -Path (Join-Path $targetDirectory 'adapter') -Force | Out-Null
        $markerPath = Join-Path $targetDirectory 'adapter/keep.txt'
        [IO.File]::WriteAllText($markerPath, 'preserve capture target', [Text.UTF8Encoding]::new($false))
        try {
            New-Item -ItemType Junction -Path $linkDirectory -Target $targetDirectory -ErrorAction Stop | Out-Null
            $link = Get-Item -LiteralPath $linkDirectory -Force
            ($link.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 | Should -BeTrue
            $link.LinkTarget | Should -Not -BeNullOrEmpty
            $result = Invoke-CaptureFixture -TargetPath (Join-Path $linkDirectory 'adapter')
            $result.status | Should -BeExactly 'invalid'
            @($result.reasonCodes) | Should -Contain 'ReparsePointRejected'
            @($script:requests).Count | Should -Be 0
            (Get-Content -LiteralPath $markerPath -Raw) | Should -BeExactly 'preserve capture target'
            @((Get-ChildItem -LiteralPath (Join-Path $targetDirectory 'adapter') -Force)).Count | Should -Be 1
        } finally {
            $link = Get-Item -LiteralPath $linkDirectory -Force -ErrorAction SilentlyContinue
            if ($null -ne $link -and ($link.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Remove-Item -LiteralPath $linkDirectory -Force }
        }
    }

    It 'InterT150_rejects_a_dangling_capture_target_junction_before_remote_io' {
        $targetDirectory = Join-Path $script:fixtureRoot 'dangling-capture-target'
        $linkDirectory = Join-Path $script:fixtureRoot 'dangling-capture-link'
        New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
        New-Item -ItemType Junction -Path $linkDirectory -Target $targetDirectory -ErrorAction Stop | Out-Null
        Remove-Item -LiteralPath $targetDirectory -Force
        try {
            $link = Get-Item -LiteralPath $linkDirectory -Force
            ($link.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 | Should -BeTrue
            $link.LinkTarget | Should -Not -BeNullOrEmpty
            (Test-Path -LiteralPath $targetDirectory) | Should -BeFalse
            $result = Invoke-CaptureFixture -TargetPath (Join-Path $linkDirectory 'adapter')
            $result.status | Should -BeExactly 'invalid'
            @($result.reasonCodes) | Should -Contain 'ReparsePointRejected'
            @($script:requests).Count | Should -Be 0
        } finally {
            $link = Get-Item -LiteralPath $linkDirectory -Force -ErrorAction SilentlyContinue
            if ($null -ne $link -and ($link.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Remove-Item -LiteralPath $linkDirectory -Force }
            if (Test-Path -LiteralPath $targetDirectory) { Remove-Item -LiteralPath $targetDirectory -Force }
        }
    }

    It 'InterT151_rejects_a_page_directory_junction_before_creating_page_content' {
        $script:mode = 'capture-page-directory-junction'
        try { $result = Invoke-CaptureFixture -InjectPageDirectoryJunction }
        finally {
            $linkPath = [string] $script:reparseLink
            if (-not [string]::IsNullOrWhiteSpace($linkPath)) {
                $fixturePath = [IO.Path]::GetFullPath($script:fixtureRoot).TrimEnd('\', '/')
                $fullLinkPath = [IO.Path]::GetFullPath($linkPath)
                $relativeLinkPath = [IO.Path]::GetRelativePath($fixturePath, $fullLinkPath)
                if ([IO.Path]::IsPathRooted($relativeLinkPath) -or $relativeLinkPath -ceq '..' -or
                    $relativeLinkPath.StartsWith('..' + [IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal) -or
                    $relativeLinkPath.StartsWith('..' + [IO.Path]::AltDirectorySeparatorChar, [StringComparison]::Ordinal)) {
                    throw 'Capture junction cleanup path escaped its owned fixture root.'
                }
                $link = Get-Item -LiteralPath $fullLinkPath -Force -ErrorAction SilentlyContinue
                if ($null -ne $link -and ($link.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Remove-Item -LiteralPath $fullLinkPath -Force }
            }
        }
        $result.status | Should -BeExactly 'failed'
        @($result.reasonCodes) | Should -Contain 'ReparsePointRejected'
        @($script:requests | Where-Object { $_.Uri -match '/pages/101\?body-format=storage(?:&get-draft=true)?$' }).Count | Should -Be 2
        @($script:requests | Where-Object Uri -Match '/pages/101/attachments').Count | Should -Be 0
        @((Get-ChildItem -LiteralPath $script:reparseTarget -Force)).Count | Should -Be 0
    }

    It 'InterT152_rechecks_the_raw_file_ancestors_before_opening_and_writing' {
        $testModuleDirectory = Join-Path $script:fixtureRoot 'private-writer-test-module'
        New-Item -ItemType Directory -Path $testModuleDirectory -Force | Out-Null
        Get-ChildItem -LiteralPath (Split-Path -Parent $modulePath) -File | Copy-Item -Destination $testModuleDirectory
        $testModulePath = Join-Path $testModuleDirectory 'ConfluenceDocs.psm1'
        $moduleText = [IO.File]::ReadAllText($testModulePath)
        $writeAnchor = '        $stream.Write($Bytes, 0, $Bytes.Length)'
        if ($moduleText.IndexOf($writeAnchor, [StringComparison]::Ordinal) -lt 0 -or
            $moduleText.IndexOf($writeAnchor, [StringComparison]::Ordinal) -ne $moduleText.LastIndexOf($writeAnchor, [StringComparison]::Ordinal)) {
            throw 'Could not isolate the private writer byte-count observation point.'
        }
        $writeObserver = @'
        if (-not [string]::IsNullOrWhiteSpace($env:SYP171_CAPTURE_TEST_WRITE_LOG)) {
            [IO.File]::AppendAllText($env:SYP171_CAPTURE_TEST_WRITE_LOG, $Bytes.Length.ToString([Globalization.CultureInfo]::InvariantCulture) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        }
'@
        [IO.File]::WriteAllText($testModulePath, $moduleText.Replace($writeAnchor, $writeObserver + $writeAnchor), [Text.UTF8Encoding]::new($false))
        Import-Module -Name $testModulePath -Force
        $testModule = @(Get-Module | Where-Object Path -CEQ $testModulePath | Select-Object -Last 1)[0]
        $testModule | Should -Not -BeNullOrEmpty

        $targetDirectory = Join-Path $script:fixtureRoot 'raw-write-junction-target'
        $linkDirectory = Join-Path $script:fixtureRoot 'raw-write-junction'
        New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
        $writeLog = Join-Path $script:fixtureRoot 'private-write-count.txt'
        $oldLog = [Environment]::GetEnvironmentVariable('SYP171_CAPTURE_TEST_WRITE_LOG', 'Process')
        [Environment]::SetEnvironmentVariable('SYP171_CAPTURE_TEST_WRITE_LOG', $writeLog, 'Process')
        $hasRootParameter = & $testModule { (Get-Command Write-CapturePrivateBytes -ErrorAction Stop).Parameters.ContainsKey('Root') }
        $exceptionMessage = ''
        try {
            $ordinaryFile = Join-Path $script:fixtureRoot 'ordinary-private-writer-control.bin'
            & $testModule {
                param($RootPath, $FilePath, $HasRootParameter)
                [byte[]] $testBytes = @(90)
                if ($HasRootParameter) { Write-CapturePrivateBytes -Root $RootPath -Path $FilePath -Bytes $testBytes }
                else { Write-CapturePrivateBytes -Path $FilePath -Bytes $testBytes }
            } $script:fixtureRoot $ordinaryFile $hasRootParameter
            $positiveCount = @(Get-Content -LiteralPath $writeLog)
            @($positiveCount).Count | Should -Be 1
            $positiveCount[0] | Should -BeExactly '1'
            @([IO.File]::ReadAllBytes($ordinaryFile)).Count | Should -Be 1
            Remove-Item -LiteralPath $writeLog -Force

            $junctionPath = Join-Path $linkDirectory 'raw.bin'
            New-Item -ItemType Junction -Path $linkDirectory -Target $targetDirectory -ErrorAction Stop | Out-Null
            $link = Get-Item -LiteralPath $linkDirectory -Force
            ($link.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 | Should -BeTrue
            $link.LinkTarget | Should -Not -BeNullOrEmpty
            (Test-Path -LiteralPath $junctionPath) | Should -BeFalse
            try {
                & $testModule {
                    param($RootPath, $FilePath, $HasRootParameter)
                    [byte[]] $testBytes = @(65)
                    if ($HasRootParameter) { Write-CapturePrivateBytes -Root $RootPath -Path $FilePath -Bytes $testBytes }
                    else { Write-CapturePrivateBytes -Path $FilePath -Bytes $testBytes }
                } $script:fixtureRoot $junctionPath $hasRootParameter
            } catch { $exceptionMessage = $_.Exception.Message }
        }
        finally {
            [Environment]::SetEnvironmentVariable('SYP171_CAPTURE_TEST_WRITE_LOG', $oldLog, 'Process')
            $link = Get-Item -LiteralPath $linkDirectory -Force -ErrorAction SilentlyContinue
            if ($null -ne $link -and ($link.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Remove-Item -LiteralPath $linkDirectory -Force }
            if (Test-Path -LiteralPath $ordinaryFile) { Remove-Item -LiteralPath $ordinaryFile -Force }
        }
        $writes = if (Test-Path -LiteralPath $writeLog) { @(Get-Content -LiteralPath $writeLog) } else { @() }
        $exceptionMessage | Should -BeExactly 'ReparsePointRejected' -Because 'the new file was absent before the call and could only be reached through the verified directory junction'
        @($writes).Count | Should -Be 0 -Because 'the guard runs before the first content byte'
        (Test-Path -LiteralPath (Join-Path $targetDirectory 'raw.bin')) | Should -BeFalse
    }

    It 'InterT153_rejects_a_reparse_parent_above_the_capture_root_but_accepts_an_ordinary_parent' {
        Import-Module -Name $modulePath -Force
        $module = @(Get-Module | Where-Object Path -CEQ $modulePath | Select-Object -Last 1)[0]
        $physicalParent = Join-Path $script:fixtureRoot 'ancestor-target'
        $captureRoot = Join-Path $physicalParent 'scope-root'
        $junctionPath = Join-Path $script:fixtureRoot 'ancestor-junction'
        New-Item -ItemType Directory -Path $captureRoot -Force | Out-Null
        New-Item -ItemType Junction -Path $junctionPath -Target $physicalParent -ErrorAction Stop | Out-Null
        try {
            $aliasedRoot = Join-Path $junctionPath 'scope-root'
            $aliasedTarget = Join-Path $aliasedRoot 'adapter'
            $ordinaryTarget = Join-Path $captureRoot 'adapter'
            $linked = & $module {
                param($RootPath, $CandidatePath)
                Test-ReparseAncestor -Root $RootPath -Path $CandidatePath
            } $aliasedRoot $aliasedTarget
            $ordinary = & $module {
                param($RootPath, $CandidatePath)
                Test-ReparseAncestor -Root $RootPath -Path $CandidatePath
            } $captureRoot $ordinaryTarget
            $linked | Should -BeTrue
            $ordinary | Should -BeFalse
        } finally {
            $link = Get-Item -LiteralPath $junctionPath -Force -ErrorAction SilentlyContinue
            if ($null -ne $link -and ($link.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Remove-Item -LiteralPath $junctionPath -Force }
        }
    }

    It 'InterT154_uses_native_link_target_metadata_when_provider_lookup_misses_a_broken_link' {
        Import-Module -Name $modulePath -Force
        $module = @(Get-Module | Where-Object Path -CEQ $modulePath | Select-Object -Last 1)[0]
        $targetDirectory = Join-Path $script:fixtureRoot 'metadata-fallback-target'
        $linkDirectory = Join-Path $script:fixtureRoot 'metadata-fallback-link'
        New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
        New-Item -ItemType Junction -Path $linkDirectory -Target $targetDirectory -ErrorAction Stop | Out-Null
        Remove-Item -LiteralPath $targetDirectory -Force
        try {
            $link = Get-Item -LiteralPath $linkDirectory -Force
            ($link.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 | Should -BeTrue
            $nativeTarget = [IO.DirectoryInfo]::new($linkDirectory).LinkTarget
            $nativeTarget | Should -Not -BeNullOrEmpty
            $detected = & $module {
                param($LinkPath)
                function Get-Item {
                    [CmdletBinding()]
                    param([string] $LiteralPath, [switch] $Force)
                    if ($LiteralPath -ceq $LinkPath) { throw [IO.FileNotFoundException]::new('Synthetic provider metadata miss') }
                    Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
                }
                Test-ExistingReparsePoint -Path $LinkPath
            } $linkDirectory
            $detected | Should -BeTrue
        } finally {
            $link = Get-Item -LiteralPath $linkDirectory -Force -ErrorAction SilentlyContinue
            if ($null -ne $link -and ($link.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Remove-Item -LiteralPath $linkDirectory -Force }
            if (Test-Path -LiteralPath $targetDirectory) { Remove-Item -LiteralPath $targetDirectory -Force }
        }
    }

    It 'InterT155_keeps_the_raw_129_deep_page_and_continues_to_a_normal_next_page' {
        $script:mode = 'deep-first-page'
        $scope = [ordered]@{ schemaVersion = 1; siteOrigin = $site; cloudId = $cloudId; apiBase = $apiBase; scope = @{ kind = 'page'; pageIds = @('101', '102') } } | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText((Join-Path $script:fixtureRoot 'scope.json'), $scope, [Text.UTF8Encoding]::new($false))
        $deepStorage = ('<strong>' * 129) + 'deep capture source' + ('</strong>' * 129)
        $deepBytes = [Text.UTF8Encoding]::new($false).GetBytes($deepStorage)
        $expectedHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($deepBytes)).ToLowerInvariant()

        $result = Invoke-CaptureFixture
        $result.status | Should -BeExactly 'partial'
        @($result.reasonCodes) | Should -Contain 'UnsupportedContent'
        $manifest = Get-Content -LiteralPath (Join-Path $result.capturePath 'capture.json') -Raw | ConvertFrom-Json
        @($manifest.pages).Count | Should -Be 2
        $deepPage = @($manifest.pages | Where-Object pageId -CEQ '101')[0]
        $nextPage = @($manifest.pages | Where-Object pageId -CEQ '102')[0]
        $deepPage.projectionStatus | Should -BeExactly 'unsupported'
        @($deepPage.unsupported | Where-Object code -CEQ 'StorageDepthExceeded').Count | Should -Be 1
        $deepPage.bodySha256 | Should -BeExactly $expectedHash
        $deepPage.unsupported[0].sourceSha256 | Should -BeExactly $expectedHash
        $rawPath = Join-Path $result.capturePath $deepPage.snapshotPath
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($rawPath))).ToLowerInvariant() | Should -BeExactly $expectedHash
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($rawPath)) | Should -BeExactly ([Convert]::ToBase64String($deepBytes))
        [IO.File]::ReadAllBytes((Join-Path $result.capturePath $deepPage.candidatePath)).Length | Should -Be 0
        $nextPage.projectionStatus | Should -BeExactly 'supported'
        (Get-Content -LiteralPath (Join-Path $result.capturePath $nextPage.snapshotPath) -Raw) | Should -BeExactly '<p>第二頁</p>'
    }

    It 'InterT156_forwards_a_fixed_collection_pagination_reason_into_the_capture_terminal' {
        $script:mode = 'collection-pagination-loop'
        $result = Invoke-CaptureFixture
        $result.status | Should -BeExactly 'partial'
        @($result.reasonCodes) | Should -Contain 'PaginationLoop'
        @($script:requests | Where-Object Uri -Match '/spaces/55/pages').Count | Should -Be 1
        $manifest = Get-Content -LiteralPath (Join-Path $result.capturePath 'capture.json') -Raw | ConvertFrom-Json
        @($manifest.reasonCodes) | Should -Contain 'PaginationLoop'
        @($manifest.pages | Where-Object pageId -CEQ '101').Count | Should -Be 1
    }

    It 'InterT161_blocks_a_real_writer_fragment_root_capture_before_import_validation_or_preview_writes' {
        Import-Module (Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ImportReview.psm1') -Force
        Import-Module (Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluenceValidation.psm1') -Force
        Import-Module (Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluenceMarkdownWorkflow.psm1') -Force

        $script:mode = 'root-inline-unsupported'
        $consumerRoot = Join-Path $script:fixtureRoot 'consumer-repository'
        New-Item -ItemType Directory -Path (Join-Path $consumerRoot 'docs') -Force | Out-Null
        [IO.File]::Copy((Join-Path $repositoryRoot '.gitattributes'), (Join-Path $consumerRoot '.gitattributes'), $true)
        [IO.File]::WriteAllText((Join-Path $consumerRoot 'docs/general.md'), '# Captured page' + "`n", [Text.UTF8Encoding]::new($false))
        $mapping = [ordered]@{
            schemaVersion = 4; adapter = @{ id = 'powershell-markdown'; version = '1' }
            siteOrigin = $site; cloudId = $cloudId; sourceMode = 'capture-markdown'
            entries = @(@{ projectionId = 'captured-page'; sourceArtifact = 'docs/general.md'; sourceSectionId = 'document'; pageId = '101'; spaceId = '55'; parentId = '99'; parentProjectionId = ''; title = 'Captured page'; assets = @(); linkBindings = @(); contentKind = 'general' })
        }
        $mappingPath = Join-Path $consumerRoot 'mapping.json'
        [IO.File]::WriteAllText($mappingPath, ($mapping | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        & git -C $consumerRoot init --quiet | Out-Null
        & git -C $consumerRoot config user.name 'SYP-171 capture consumer fixture' | Out-Null
        & git -C $consumerRoot config user.email 'fixture@example.invalid' | Out-Null
        & git -C $consumerRoot config core.autocrlf false | Out-Null
        & git -C $consumerRoot add -- .gitattributes docs/general.md mapping.json | Out-Null
        & git -C $consumerRoot commit --quiet -m 'Fixture capture Markdown consumer'
        if ($LASTEXITCODE -ne 0) { throw 'Unable to commit the capture consumer baseline.' }

        $scope = [ordered]@{ schemaVersion = 1; siteOrigin = $site; cloudId = $cloudId; apiBase = $apiBase; scope = @{ kind = 'page'; pageIds = @('101', '102') } } | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText((Join-Path $script:fixtureRoot 'scope.json'), $scope, [Text.UTF8Encoding]::new($false))
        $captureResult = Invoke-CaptureFixture -TargetPath $consumerRoot
        $captureResult.status | Should -BeExactly 'partial'
        @($captureResult.reasonCodes) | Should -Contain 'UnsupportedContent'
        @($script:requests).Count | Should -BeGreaterThan 0
        @($script:requests | Where-Object Method -cne 'GET').Count | Should -Be 0
        $capturePath = Join-Path $captureResult.capturePath 'capture.json'
        $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json -AsHashtable -Depth 20
        $capture.schemaVersion | Should -Be 1
        $capture.status | Should -BeExactly 'partial'
        $deepPage = @($capture.pages | Where-Object pageId -CEQ '101')[0]
        $storageSource = '<strong>Writer fragment root</strong><p>Following supported paragraph.</p>'
        [byte[]]$storageBytes = [Text.UTF8Encoding]::new($false).GetBytes($storageSource)
        $storageHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($storageBytes)).ToLowerInvariant()
        [byte[]]$fragmentBytes = [Text.UTF8Encoding]::new($false).GetBytes('<strong>Writer fragment root</strong>')
        $fragmentHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($fragmentBytes)).ToLowerInvariant()
        $unsupportedNode = @($deepPage.unsupported | Where-Object code -CEQ 'UnsupportedNode')
        $unsupportedNode.Count | Should -Be 1
        $unsupportedNode[0].sourceSha256 | Should -BeExactly $fragmentHash
        $deepPage.bodySha256 | Should -BeExactly $storageHash
        $rawStoragePath = Join-Path $captureResult.capturePath ([string]$deepPage.snapshotPath)
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($rawStoragePath)) | Should -BeExactly ([Convert]::ToBase64String($storageBytes))
        @($deepPage.sourceBlocks | Where-Object { -not $_.supported -and $_.sourceSha256 -ceq $fragmentHash }).Count | Should -Be 1
        @($deepPage.sourceBlocks | Where-Object { $_.supported }).Count | Should -BeGreaterThan 0
        @($capture.pages | Where-Object pageId -CEQ '102').Count | Should -Be 1

        $dispositions = [System.Collections.Generic.List[object]]::new()
        $attachmentDispositions = [System.Collections.Generic.List[object]]::new()
        foreach ($page in @($capture.pages)) {
            foreach ($block in @($page.sourceBlocks)) {
                $dispositionStatus = if ($block.supported) { 'excluded' } else { 'unknown' }
                $dispositions.Add(@{ blockId = [string]$block.id; sourceSha256 = [string]$block.sourceSha256; location = [string]$block.location; status = $dispositionStatus; ready = $false; destinations = @(); reason = 'Capture requires manual review' })
            }
            foreach ($attachment in @($page.attachments)) {
                $attachmentDispositions.Add(@{ pageId = [string]$page.pageId; attachmentId = [string]$attachment.attachmentId; version = [long]$attachment.version; sha256 = [string]$attachment.sha256; status = 'not-converted'; ready = $false; destination = $null; reason = 'Attachment requires manual review' })
            }
        }
        $review = [ordered]@{ schemaVersion = 2; captureId = [string]$capture.captureId; siteOrigin = $site; dispositions = @($dispositions.ToArray()); attachments = @($attachmentDispositions.ToArray()) }
        $reviewPath = Join-Path $captureResult.capturePath 'import-review.json'
        [IO.File]::WriteAllText($reviewPath, ($review | ConvertTo-Json -Depth 16), [Text.UTF8Encoding]::new($false))
        $dossierPath = Join-Path $consumerRoot '.confluence/review-dossier.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $dossierPath) -Force | Out-Null
        $captureRelative = [IO.Path]::GetRelativePath($consumerRoot, $capturePath).Replace('\', '/')
        $reviewRelative = [IO.Path]::GetRelativePath($consumerRoot, $reviewPath).Replace('\', '/')
        [IO.File]::WriteAllText($dossierPath, (@{ schemaVersion = 2; capturePath = $captureRelative; importReviewPath = $reviewRelative } | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))

        $import = Test-ConfluenceImportReview -CapturePath $capturePath -ReviewPath $reviewPath
        $import.status | Should -BeExactly 'blocked'
        @($import.reasonCodes) | Should -Contain 'CaptureIncomplete'
        $import.unknownCount | Should -BeGreaterThan 0
        $import.nonReadyCount | Should -BeGreaterThan 0
        @($review.attachments | Where-Object { $_.status -ceq 'not-converted' -and -not $_.ready -and $null -eq $_.destination }).Count | Should -BeGreaterThan 0
        @($import.acceptedDestinations).Count | Should -Be 0

        & git -C $consumerRoot add -f -- .local/captures .confluence/review-dossier.json | Out-Null
        & git -C $consumerRoot commit --quiet -m 'Fixture partial writer capture and review dossier'
        if ($LASTEXITCODE -ne 0) { throw 'Unable to commit the writer capture and review dossier fixture.' }
        $commit = (& git -C $consumerRoot rev-parse HEAD).Trim()
        $validation = Invoke-ConfluenceValidation -Root $consumerRoot -MappingPath $mappingPath -DocsCommit $commit -ReviewPath $dossierPath
        $validation.status | Should -BeExactly 'blocked'
        @($validation.reasonCodes) | Should -Contain 'CaptureIncomplete'

        $script:previewHttpCalls = 0
        $planPath = Join-Path $consumerRoot 'preview.json'
        $preview = New-ConfluenceMarkdownPreviewPlan -Root $consumerRoot -MappingPath $mappingPath -DocsCommit $commit -ReviewPath $dossierPath `
            -PlanPath $planPath -ExpectedSiteOrigin $site -ApiBase $apiBase -HttpInvoker { param($Request) $script:previewHttpCalls++; throw 'PreviewMustNotIssueHttp' }
        $preview.status | Should -BeExactly 'blocked'
        @($preview.reasonCodes) | Should -Contain 'CaptureIncomplete'
        $script:previewHttpCalls | Should -Be 0
        (Test-Path -LiteralPath $planPath) | Should -BeFalse
    }
}
