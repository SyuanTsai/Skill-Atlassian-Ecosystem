# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
Import-Module -Name (Join-Path $PSScriptRoot 'ConfluenceTransport.psm1') -Force -Scope Local
Import-Module -Name (Join-Path $PSScriptRoot 'StorageProjection.psm1') -Force -Scope Local
Import-Module -Name (Join-Path $PSScriptRoot 'StrictJson.psm1') -Force -Scope Local

function New-CaptureResult {
    param([string] $Status, [string[]] $ReasonCodes, [string] $CapturePath)
    return [pscustomobject]@{ status = $Status; reasonCodes = @($ReasonCodes); capturePath = $CapturePath }
}

function Get-CaptureValue {
    param([object] $Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { $value = $Object[$Name] }
    else {
        $property = $Object.PSObject.Properties[$Name]
        if ($null -eq $property) { return $null }
        $value = $property.Value
    }
    if ($value -is [array]) { Write-Output -NoEnumerate $value }
    else { return $value }
}

function Test-PathInside {
    param([string] $Root, [string] $Path)
    $relative = [IO.Path]::GetRelativePath([IO.Path]::GetFullPath($Root), [IO.Path]::GetFullPath($Path))
    return $relative -ceq '.' -or ($relative -cne '..' -and -not $relative.StartsWith("..$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::Ordinal) -and -not [IO.Path]::IsPathRooted($relative))
}

function Test-ExistingReparsePoint {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    return (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Test-ReparseAncestor {
    param([string] $Root, [string] $Path)
    $current = [IO.Path]::GetFullPath($Path)
    $boundary = [IO.Path]::GetFullPath($Root)
    while (Test-PathInside -Root $boundary -Path $current) {
        if (Test-ExistingReparsePoint -Path $current) { return $true }
        if ($current -ceq $boundary) { break }
        $parent = [IO.Path]::GetDirectoryName($current)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $current) { break }
        $current = $parent
    }
    return $false
}

function Test-ScopeContract {
    param([System.Collections.IDictionary] $Scope)
    if (($Scope.Keys | Sort-Object) -join ',' -cne 'apiBase,cloudId,schemaVersion,scope,siteOrigin') { return 'ScopeSchemaInvalid' }
    if ($Scope.schemaVersion -ne 1 -or $Scope.siteOrigin -isnot [string] -or $Scope.cloudId -isnot [string] -or $Scope.apiBase -isnot [string]) { return 'ScopeSchemaInvalid' }
    $selection = $Scope.scope
    if ($selection -isnot [System.Collections.IDictionary]) { return 'ScopeSchemaInvalid' }
    if ($selection.kind -ceq 'space') {
        if (($selection.Keys | Sort-Object) -join ',' -cne 'kind,spaceId' -or [string] $selection.spaceId -cnotmatch '^[0-9]+$') { return 'ScopeSchemaInvalid' }
    } elseif ($selection.kind -ceq 'page') {
        if (($selection.Keys | Sort-Object) -join ',' -cne 'kind,pageIds' -or @($selection.pageIds).Count -eq 0) { return 'ScopeSchemaInvalid' }
        $ids = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($id in @($selection.pageIds)) {
            if ([string] $id -cnotmatch '^[0-9]+$' -or -not $ids.Add([string] $id)) { return 'ScopeSchemaInvalid' }
        }
    } else { return 'ScopeSchemaInvalid' }
    return $null
}

function Invoke-CaptureRead {
    param([string] $ApiBase, [string] $RelativePath, [scriptblock] $HttpInvoker)
    if (-not $RelativePath.StartsWith('/wiki/api/v2/', [StringComparison]::Ordinal)) {
        return [pscustomobject]@{ reason = 'UnsafeReadPath'; body = $null }
    }
    $request = [pscustomobject]@{
        Method = 'GET'; Uri = "$($ApiBase.TrimEnd('/'))$RelativePath"; Headers = @{ Accept = 'application/json' }
        Body = $null; TimeoutSec = 30; ResponseLimitBytes = 4MB; AuthAllowed = $true
    }
    try { $response = & $HttpInvoker $request }
    catch { return [pscustomobject]@{ reason = 'RemoteReadFailed'; body = $null } }
    $status = [int] (Get-CaptureValue -Object $response -Name 'StatusCode')
    if ($status -ne 200) {
        $reason = switch ($status) {
            401 { 'RemoteAuthenticationFailed' }
            403 { 'RemoteReadDenied' }
            404 { 'RemoteReadUnavailable' }
            429 { 'RemoteRateLimited' }
            default { 'RemoteReadFailed' }
        }
        return [pscustomobject]@{ reason = $reason; body = $null }
    }
    $body = Get-CaptureValue -Object $response -Name 'Body'
    if ($body -is [byte[]]) {
        if ($body.Length -gt 4MB) { return [pscustomobject]@{ reason = 'ResponseTooLarge'; body = $null } }
        try { $body = [Text.Encoding]::UTF8.GetString($body) | ConvertFrom-Json -AsHashtable -Depth 30 }
        catch { return [pscustomobject]@{ reason = 'ResponseInvalid'; body = $null } }
    }
    if ($null -eq $body) { return [pscustomobject]@{ reason = 'ResponseInvalid'; body = $null } }
    return [pscustomobject]@{ reason = $null; body = $body }
}

function Get-PageIdentity {
    param([object] $Page, [string] $RequestedPageId, [string] $ExpectedSpaceId)
    $id = [string] (Get-CaptureValue -Object $Page -Name 'id')
    $spaceId = [string] (Get-CaptureValue -Object $Page -Name 'spaceId')
    $status = [string] (Get-CaptureValue -Object $Page -Name 'status')
    $version = Get-CaptureValue -Object (Get-CaptureValue -Object $Page -Name 'version') -Name 'number'
    $storage = Get-CaptureValue -Object (Get-CaptureValue -Object (Get-CaptureValue -Object $Page -Name 'body') -Name 'storage') -Name 'value'
    if ($id -cne $RequestedPageId -or $status -cne 'current' -or $null -eq $storage -or
        $null -eq $version -or [int] $version -lt 1 -or
        (-not [string]::IsNullOrWhiteSpace($ExpectedSpaceId) -and $spaceId -cne $ExpectedSpaceId)) { return $null }
    return [pscustomobject]@{
        pageId = $id; spaceId = $spaceId; version = [int] $version
        title = [string] (Get-CaptureValue -Object $Page -Name 'title')
        parentId = [string] (Get-CaptureValue -Object $Page -Name 'parentId')
        storage = [string] $storage
    }
}

function Get-AttachmentIdentity {
    param([object] $Attachment, [string] $PageId)
    $id = [string] (Get-CaptureValue -Object $Attachment -Name 'id')
    $title = [string] (Get-CaptureValue -Object $Attachment -Name 'title')
    $version = Get-CaptureValue -Object (Get-CaptureValue -Object $Attachment -Name 'version') -Name 'number'
    $size = Get-CaptureValue -Object $Attachment -Name 'fileSize'
    if ($id -cnotmatch '^[0-9]+$' -or [string]::IsNullOrWhiteSpace($title) -or $title -match '[\\/]' -or
        $null -eq $version -or [int] $version -lt 1 -or $null -eq $size -or [int64] $size -lt 0 -or [int64] $size -gt 20MB) { return $null }
    $download = [string] (Get-CaptureValue -Object $Attachment -Name 'downloadLink')
    $expected = "/wiki/rest/api/content/$PageId/child/attachment/$id/download"
    if ($download -cne $expected) { return $null }
    return [pscustomobject]@{
        id = $id; filename = $title; version = [int] $version; byteLength = [int64] $size
        mediaType = [string] (Get-CaptureValue -Object $Attachment -Name 'mediaType'); downloadPath = $download
    }
}

function Invoke-AttachmentDownload {
    param([string] $ApiBase, [object] $Attachment, [scriptblock] $HttpInvoker)
    $request = [pscustomobject]@{
        Method = 'GET'; Uri = "$($ApiBase.TrimEnd('/'))$($Attachment.downloadPath)?version=$($Attachment.version)"; Headers = @{ Accept = '*/*' }
        Body = $null; TimeoutSec = 30; ResponseLimitBytes = 20MB; AuthAllowed = $true
    }
    try { $response = & $HttpInvoker $request }
    catch { return [pscustomobject]@{ reason = 'AttachmentDownloadFailed'; bytes = $null } }
    if ([int] (Get-CaptureValue -Object $response -Name 'StatusCode') -ne 200) {
        return [pscustomobject]@{ reason = 'AttachmentDownloadFailed'; bytes = $null }
    }
    $bytes = Get-CaptureValue -Object $response -Name 'BodyBytes'
    if ($bytes -isnot [byte[]]) { $bytes = Get-CaptureValue -Object $response -Name 'Body' }
    if ($bytes -isnot [byte[]] -or $bytes.Length -ne $Attachment.byteLength) {
        return [pscustomobject]@{ reason = 'AttachmentBytesMismatch'; bytes = $null }
    }
    return [pscustomobject]@{ reason = $null; bytes = $bytes }
}

function Get-ByteHash {
    param([byte[]] $Bytes)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Test-AttachmentStable {
    param([object[]] $Before, [object[]] $After)
    if (@($Before).Count -ne @($After).Count) { return $false }
    $afterById = @{}
    foreach ($item in $After) { $afterById[[string] $item.id] = $item }
    foreach ($item in $Before) {
        $other = $afterById[[string] $item.id]
        if ($null -eq $other -or $item.version -ne $other.version -or $item.filename -cne $other.filename -or $item.byteLength -ne $other.byteLength) { return $false }
    }
    return $true
}

function Invoke-ConfluenceCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $TargetPath,
        [Parameter(Mandatory)][string] $ScopePath,
        [Parameter(Mandatory)][string] $ExpectedSiteOrigin,
        [Parameter(Mandatory)][scriptblock] $HttpInvoker
    )
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return New-CaptureResult -Status 'invalid' -ReasonCodes @('RootUnavailable') -CapturePath '' }
    $resolvedRoot = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path)
    $target = [IO.Path]::GetFullPath($TargetPath)
    $scopeFile = [IO.Path]::GetFullPath($ScopePath)
    if (-not (Test-PathInside -Root $resolvedRoot -Path $target)) { return New-CaptureResult -Status 'invalid' -ReasonCodes @('TargetOutsideRoot') -CapturePath '' }
    if (-not (Test-PathInside -Root $resolvedRoot -Path $scopeFile) -or -not (Test-Path -LiteralPath $scopeFile -PathType Leaf)) {
        return New-CaptureResult -Status 'invalid' -ReasonCodes @('ScopeOutsideRoot') -CapturePath ''
    }
    if ((Test-ReparseAncestor -Root $resolvedRoot -Path $target) -or (Test-ReparseAncestor -Root $resolvedRoot -Path $scopeFile)) {
        return New-CaptureResult -Status 'invalid' -ReasonCodes @('ReparsePointRejected') -CapturePath ''
    }
    try { $scope = Read-Syp171StrictJsonFile -Path $scopeFile -Depth 10 }
    catch { return New-CaptureResult -Status 'invalid' -ReasonCodes @('ScopeSchemaInvalid') -CapturePath '' }
    $schemaError = Test-ScopeContract -Scope $scope
    if ($null -ne $schemaError) { return New-CaptureResult -Status 'invalid' -ReasonCodes @($schemaError) -CapturePath '' }
    $tenantError = Test-ConfluenceTenant -ExpectedSiteOrigin $ExpectedSiteOrigin -ConfiguredSiteOrigin $scope.siteOrigin -ApiBase $scope.apiBase -CloudId $scope.cloudId
    if ($null -ne $tenantError) { return New-CaptureResult -Status 'blocked' -ReasonCodes @($tenantError) -CapturePath '' }

    $captureId = [Guid]::NewGuid().ToString('N')
    $captureRoot = Join-Path $target '.local/captures'
    $stage = Join-Path $captureRoot "capture-$captureId.staging"
    $final = Join-Path $captureRoot "capture-$captureId"
    if (-not (Test-PathInside -Root $target -Path $captureRoot) -or -not (Test-PathInside -Root $captureRoot -Path $stage) -or -not (Test-PathInside -Root $captureRoot -Path $final)) {
        return New-CaptureResult -Status 'invalid' -ReasonCodes @('TargetOutsideRoot') -CapturePath ''
    }
    if (Test-ReparseAncestor -Root $resolvedRoot -Path $captureRoot) {
        return New-CaptureResult -Status 'invalid' -ReasonCodes @('ReparsePointRejected') -CapturePath ''
    }
    $privateRoot = Join-Path $target '.local'
    New-Item -ItemType Directory -Path $privateRoot -Force | Out-Null
    $ignorePath = Join-Path $privateRoot '.gitignore'
    if (-not (Test-Path -LiteralPath $ignorePath)) {
        [IO.File]::WriteAllText($ignorePath, "*`n", [Text.UTF8Encoding]::new($false))
    }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    $pages = [System.Collections.Generic.List[object]]::new()
    $incompleteIds = [System.Collections.Generic.List[string]]::new()
    $reasons = [System.Collections.Generic.List[string]]::new()
    $pageIds = [System.Collections.Generic.List[string]]::new()
    $spaceId = ''
    try {
        if ($scope.scope.kind -ceq 'space') {
            $spaceId = [string] $scope.scope.spaceId
            $listing = Get-ConfluenceCollection -ExpectedSiteOrigin $ExpectedSiteOrigin -ConfiguredSiteOrigin $scope.siteOrigin -ApiBase $scope.apiBase -CloudId $scope.cloudId -RelativePath "/wiki/api/v2/spaces/$spaceId/pages?limit=50" -HttpInvoker $HttpInvoker
            foreach ($item in @($listing.items)) { $pageIds.Add([string] (Get-CaptureValue -Object $item -Name 'id')) }
            if ($listing.status -cne 'complete') { foreach ($code in @($listing.reasonCodes)) { $reasons.Add([string] $code) } }
        } else { foreach ($id in @($scope.scope.pageIds)) { $pageIds.Add([string] $id) } }

        foreach ($pageId in $pageIds) {
            $pagePath = "/wiki/api/v2/pages/${pageId}?body-format=storage"
            $read = Invoke-CaptureRead -ApiBase $scope.apiBase -RelativePath $pagePath -HttpInvoker $HttpInvoker
            if ($null -ne $read.reason) { $reasons.Add($read.reason); $incompleteIds.Add($pageId); continue }
            $identity = Get-PageIdentity -Page $read.body -RequestedPageId $pageId -ExpectedSpaceId $spaceId
            if ($null -eq $identity) { $reasons.Add('PageIdentityInvalid'); $incompleteIds.Add($pageId); continue }
            $draft = Invoke-CaptureRead -ApiBase $scope.apiBase -RelativePath "$pagePath&get-draft=true" -HttpInvoker $HttpInvoker
            if ($null -ne $draft.reason) { $reasons.Add('DraftReadIncomplete'); $incompleteIds.Add($pageId); continue }
            $draftIdentity = Get-PageIdentity -Page $draft.body -RequestedPageId $pageId -ExpectedSpaceId $spaceId
            $draftObservation = if ($null -eq $draftIdentity -or $draftIdentity.version -ne $identity.version -or $draftIdentity.storage -cne $identity.storage) { 'diverged' } else { 'same-as-published' }
            $projection = ConvertFrom-ConfluenceStorage -Storage $identity.storage -PageId $pageId -PageVersion $identity.version
            $relativeSnapshot = "pages/$pageId/storage.xml"
            $relativeCandidate = "pages/$pageId/candidate.md"
            $pageDirectory = Join-Path $stage "pages/$pageId"
            New-Item -ItemType Directory -Path $pageDirectory -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $pageDirectory 'storage.xml'), $identity.storage, (New-Object System.Text.UTF8Encoding($false)))
            [IO.File]::WriteAllText((Join-Path $pageDirectory 'candidate.md'), $projection.markdown, (New-Object System.Text.UTF8Encoding($false)))
            if ($projection.status -cne 'supported') { $reasons.Add('UnsupportedContent') }

            $attachmentPath = "/wiki/api/v2/pages/$pageId/attachments?limit=50"
            $before = Get-ConfluenceCollection -ExpectedSiteOrigin $ExpectedSiteOrigin -ConfiguredSiteOrigin $scope.siteOrigin -ApiBase $scope.apiBase -CloudId $scope.cloudId -RelativePath $attachmentPath -HttpInvoker $HttpInvoker
            $attachmentIdentities = [System.Collections.Generic.List[object]]::new()
            $savedAssets = [System.Collections.Generic.List[object]]::new()
            if ($before.status -cne 'complete') { $reasons.Add('AttachmentReadIncomplete') }
            foreach ($attachment in @($before.items)) {
                $asset = Get-AttachmentIdentity -Attachment $attachment -PageId $pageId
                if ($null -eq $asset) { $reasons.Add('AttachmentIdentityInvalid'); continue }
                $attachmentIdentities.Add($asset)
                $download = Invoke-AttachmentDownload -ApiBase $scope.apiBase -Attachment $asset -HttpInvoker $HttpInvoker
                if ($null -ne $download.reason) { $reasons.Add($download.reason); continue }
                $sha = Get-ByteHash -Bytes $download.bytes
                $relativeAsset = "assets/$sha"
                $assetDirectory = Join-Path $stage 'assets'
                New-Item -ItemType Directory -Path $assetDirectory -Force | Out-Null
                $assetFile = Join-Path $assetDirectory $sha
                if (-not (Test-Path -LiteralPath $assetFile)) { [IO.File]::WriteAllBytes($assetFile, $download.bytes) }
                $savedAssets.Add([ordered]@{
                    attachmentId = $asset.id; version = $asset.version; filename = $asset.filename
                    mediaType = $asset.mediaType; byteLength = $asset.byteLength; sha256 = $sha; assetPath = $relativeAsset
                })
            }
            $after = Get-ConfluenceCollection -ExpectedSiteOrigin $ExpectedSiteOrigin -ConfiguredSiteOrigin $scope.siteOrigin -ApiBase $scope.apiBase -CloudId $scope.cloudId -RelativePath $attachmentPath -HttpInvoker $HttpInvoker
            if ($after.status -cne 'complete') { $reasons.Add('AttachmentReadIncomplete') }
            $afterIdentities = [System.Collections.Generic.List[object]]::new()
            foreach ($attachment in @($after.items)) {
                $asset = Get-AttachmentIdentity -Attachment $attachment -PageId $pageId
                if ($null -eq $asset) { $reasons.Add('AttachmentIdentityInvalid') } else { $afterIdentities.Add($asset) }
            }
            if (-not (Test-AttachmentStable -Before $attachmentIdentities.ToArray() -After $afterIdentities.ToArray())) { $reasons.Add('AttachmentUnstable') }
            $reread = Invoke-CaptureRead -ApiBase $scope.apiBase -RelativePath $pagePath -HttpInvoker $HttpInvoker
            $stablePage = if ($null -eq $reread.reason) { Get-PageIdentity -Page $reread.body -RequestedPageId $pageId -ExpectedSpaceId $spaceId } else { $null }
            if ($null -eq $stablePage -or $stablePage.version -ne $identity.version -or $stablePage.storage -cne $identity.storage -or $stablePage.title -cne $identity.title) { $reasons.Add('PageUnstable') }
            $pages.Add([ordered]@{
                pageId = $pageId; spaceId = $identity.spaceId; parentId = $identity.parentId
                title = $identity.title; version = $identity.version; bodySha256 = $projection.bodySha256
                draftObservation = $draftObservation; snapshotPath = $relativeSnapshot; candidatePath = $relativeCandidate
                projectionStatus = $projection.status; sourceBlocks = @($projection.sourceBlocks)
                unsupported = @($projection.unsupported | ForEach-Object { [ordered]@{ code = $_.code; location = $_.location; sourceSha256 = $_.sourceSha256 } })
                attachments = @($savedAssets.ToArray())
            })
        }
        $uniqueReasons = @($reasons | Select-Object -Unique)
        $status = if ($uniqueReasons.Count -eq 0) { 'complete' } else { 'partial' }
        $manifest = [ordered]@{
            schemaVersion = 1; captureId = $captureId; capturedAtUtc = (Get-Date -AsUTC).ToString('o')
            siteOrigin = $scope.siteOrigin; cloudId = $scope.cloudId; scope = $scope.scope
            status = $status; reasonCodes = $uniqueReasons; incompletePageIds = @($incompleteIds.ToArray())
            pages = @($pages.ToArray())
        }
        [IO.File]::WriteAllText((Join-Path $stage 'capture.json'), ($manifest | ConvertTo-Json -Depth 15), (New-Object System.Text.UTF8Encoding($false)))
        if ((Test-Path -LiteralPath $final) -or -not (Test-PathInside -Root $captureRoot -Path $stage) -or -not (Test-PathInside -Root $captureRoot -Path $final) -or
            (Test-ReparseAncestor -Root $resolvedRoot -Path $stage) -or (Test-ReparseAncestor -Root $resolvedRoot -Path $final)) {
            return New-CaptureResult -Status 'failed' -ReasonCodes @('CaptureStagingConflict') -CapturePath $stage
        }
        Move-Item -LiteralPath $stage -Destination $final
        return New-CaptureResult -Status $status -ReasonCodes $uniqueReasons -CapturePath $final
    }
    catch {
        return New-CaptureResult -Status 'failed' -ReasonCodes @('CaptureFailure') -CapturePath $stage
    }
}

Export-ModuleMember -Function Invoke-ConfluenceCapture
