# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
Import-Module -Name (Join-Path $PSScriptRoot 'ConfluenceTransport.psm1') -Scope Local
Import-Module -Name (Join-Path $PSScriptRoot 'StorageProjection.psm1') -Scope Local
Import-Module -Name (Join-Path $PSScriptRoot 'StrictJson.psm1') -Scope Local

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
    return $relative -ceq '.' -or ($relative -cne '..' -and -not $relative.StartsWith(('..' + [IO.Path]::DirectorySeparatorChar), [StringComparison]::Ordinal) -and -not [IO.Path]::IsPathRooted($relative))
}

function Test-ExistingReparsePoint {
    param([string] $Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
        $itemLinkTarget = $item.PSObject.Properties['LinkTarget']
        if ($null -ne $itemLinkTarget -and -not [string]::IsNullOrEmpty([string] $itemLinkTarget.Value)) { return $true }
        return $false
    } catch {
        $lookupError = $_
        foreach ($metadata in @([IO.FileInfo]::new($Path), [IO.DirectoryInfo]::new($Path))) {
            try {
                if (-not [string]::IsNullOrEmpty([string] $metadata.LinkTarget)) { return $true }
            } catch { }
        }
        if ($lookupError.CategoryInfo.Category -eq [Management.Automation.ErrorCategory]::ObjectNotFound -or
            $lookupError.Exception -is [IO.FileNotFoundException] -or $lookupError.Exception -is [IO.DirectoryNotFoundException]) { return $false }
        throw $lookupError
    }
}

function Test-ReparseAncestor {
    param([string] $Root, [string] $Path)
    $current = [IO.Path]::GetFullPath($Path)
    $boundary = [IO.Path]::GetFullPath($Root)
    if (-not (Test-PathInside -Root $boundary -Path $current)) { return $true }
    $volumeRoot = [IO.Path]::GetPathRoot($current)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        try {
            if (Test-ExistingReparsePoint -Path $current) { return $true }
        } catch { return $true }
        if ($current.Equals($volumeRoot, $comparison)) { break }
        $parent = [IO.Path]::GetDirectoryName($current)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $current) { break }
        $current = $parent
    }
    return $false
}

function Assert-CapturePathNoReparse {
    param([Parameter(Mandatory)][string] $Root, [Parameter(Mandatory)][string] $Path)
    $fullRoot = [IO.Path]::GetFullPath($Root)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-PathInside -Root $fullRoot -Path $fullPath) -or (Test-ReparseAncestor -Root $fullRoot -Path $fullPath)) {
        throw [Security.SecurityException]::new('ReparsePointRejected')
    }
}

function Test-ConfluenceCapturePrivatePermissions {
    if ($IsWindows) {
        try {
            $aclAssembly = [Reflection.Assembly]::Load('System.IO.FileSystem.AccessControl')
            $aclExtensions = $aclAssembly.GetType('System.IO.FileSystemAclExtensions', $true)
            $directorySecurity = [Type]::GetType('System.Security.AccessControl.DirectorySecurity, System.IO.FileSystem.AccessControl', $false)
            $fileSecurity = [Type]::GetType('System.Security.AccessControl.FileSecurity, System.IO.FileSystem.AccessControl', $false)
            $rights = [Type]::GetType('System.Security.AccessControl.FileSystemRights, System.IO.FileSystem.AccessControl', $false)
            $fileStreamType = [IO.FileStream]
            $directoryCreate = $aclExtensions.GetMethod('Create', [Type[]] @([IO.DirectoryInfo], $directorySecurity))
            $fileCreate = $aclExtensions.GetMethod('Create', [Type[]] @([IO.FileInfo], [IO.FileMode], $rights, [IO.FileShare], [int], [IO.FileOptions], $fileSecurity))
            $directoryRead = $aclExtensions.GetMethod('GetAccessControl', [Type[]] @([IO.DirectoryInfo]))
            $fileRead = $aclExtensions.GetMethod('GetAccessControl', [Type[]] @([IO.FileInfo]))
            $streamRead = $aclExtensions.GetMethod('GetAccessControl', [Type[]] @($fileStreamType))
            $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
            return ($null -ne $directorySecurity -and $null -ne $fileSecurity -and $null -ne $rights -and
                $null -ne $directoryCreate -and $null -ne $fileCreate -and $null -ne $directoryRead -and
                $null -ne $fileRead -and $null -ne $streamRead -and $null -ne $userSid)
        } catch { return $false }
    }

    try {
        $unixMode = [Type]::GetType('System.IO.UnixFileMode', $false)
        $streamOptions = [Type]::GetType('System.IO.FileStreamOptions', $false)
        if ($null -eq $unixMode -or $null -eq $streamOptions) { return $false }
        $createDirectory = [IO.Directory].GetMethod('CreateDirectory', [Type[]] @([string], $unixMode))
        $directoryMode = [IO.File].GetMethod('GetUnixFileMode', [Type[]] @([string]))
        $fileMode = [IO.File].GetMethod('GetUnixFileMode', [Type[]] @([string]))
        $createMode = $streamOptions.GetProperty('UnixCreateMode')
        $fileStreamConstructor = [IO.FileStream].GetConstructor([Type[]] @([string], $streamOptions))
        return ($null -ne $createDirectory -and $null -ne $directoryMode -and $null -ne $fileMode -and
            $null -ne $createMode -and $createMode.CanWrite -and $null -ne $fileStreamConstructor)
    } catch { return $false }
}

function New-CaptureDirectorySecurity {
    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $rights = [Security.AccessControl.FileSystemRights]::FullControl
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $allow = [Security.AccessControl.AccessControlType]::Allow
    [void] $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($userSid, $rights, $inheritance, [Security.AccessControl.PropagationFlags]::None, $allow))
    [void] $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($systemSid, $rights, $inheritance, [Security.AccessControl.PropagationFlags]::None, $allow))
    return $security
}

function New-CaptureFileSecurity {
    $security = [Security.AccessControl.FileSecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $rights = [Security.AccessControl.FileSystemRights]::FullControl
    $allow = [Security.AccessControl.AccessControlType]::Allow
    [void] $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($userSid, $rights, $allow))
    [void] $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($systemSid, $rights, $allow))
    return $security
}

function Test-CapturePrivatePathPermissions {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][bool] $IsDirectory,
        [IO.FileStream] $Stream
    )
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.PSIsContainer -ne $IsDirectory -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        if (-not $IsWindows) {
            $unixMode = [Type]::GetType('System.IO.UnixFileMode', $false)
            if ($null -eq $unixMode) { return $false }
            $method = [IO.File].GetMethod('GetUnixFileMode', [Type[]] @([string]))
            if ($null -eq $method) { return $false }
            $actual = $method.Invoke($null, @($Path))
            $expectedName = if ($IsDirectory) { 'UserRead, UserWrite, UserExecute' } else { 'UserRead, UserWrite' }
            $expected = [Enum]::Parse($unixMode, $expectedName)
            return ([int64] $actual -eq [int64] $expected)
        }

        $aclAssembly = [Reflection.Assembly]::Load('System.IO.FileSystem.AccessControl')
        $aclExtensions = $aclAssembly.GetType('System.IO.FileSystemAclExtensions', $true)
        if ($IsDirectory) { $security = $aclExtensions.GetMethod('GetAccessControl', [Type[]] @([IO.DirectoryInfo])).Invoke($null, @([IO.DirectoryInfo]::new($Path))) }
        elseif ($null -ne $Stream) { $security = $aclExtensions.GetMethod('GetAccessControl', [Type[]] @([IO.FileStream])).Invoke($null, @($Stream)) }
        else { $security = $aclExtensions.GetMethod('GetAccessControl', [Type[]] @([IO.FileInfo])).Invoke($null, @([IO.FileInfo]::new($Path))) }
        if (-not $security.AreAccessRulesProtected) { return $false }
        $rules = @($security.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        if ($rules.Count -ne 2) { return $false }
        $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $expectedSids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        [void] $expectedSids.Add($userSid)
        [void] $expectedSids.Add('S-1-5-18')
        $seenSids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($rule in $rules) {
            $sid = [string] $rule.IdentityReference.Value
            if (-not $expectedSids.Contains($sid) -or -not $seenSids.Add($sid) -or $rule.IsInherited -or
                $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
                ($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -ne [Security.AccessControl.FileSystemRights]::FullControl) { return $false }
            if ($IsDirectory) {
                $expectedInheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
                if ($rule.InheritanceFlags -ne $expectedInheritance -or $rule.PropagationFlags -ne [Security.AccessControl.PropagationFlags]::None) { return $false }
            } elseif ($rule.InheritanceFlags -ne [Security.AccessControl.InheritanceFlags]::None -or $rule.PropagationFlags -ne [Security.AccessControl.PropagationFlags]::None) { return $false }
        }
        return ($seenSids.Count -eq 2)
    } catch { return $false }
}

function New-CapturePrivateDirectory {
    param([Parameter(Mandatory)][string] $Root, [Parameter(Mandatory)][string] $Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    Assert-CapturePathNoReparse -Root $Root -Path $fullPath
    if (Test-Path -LiteralPath $fullPath) { throw [IO.IOException]::new('CapturePrivatePathCollision') }
    Assert-CapturePathNoReparse -Root $Root -Path $fullPath
    if ($IsWindows) {
        $aclAssembly = [Reflection.Assembly]::Load('System.IO.FileSystem.AccessControl')
        $aclExtensions = $aclAssembly.GetType('System.IO.FileSystemAclExtensions', $true)
        $method = $aclExtensions.GetMethod('Create', [Type[]] @([IO.DirectoryInfo], [Security.AccessControl.DirectorySecurity]))
        [void] $method.Invoke($null, @([IO.DirectoryInfo]::new($fullPath), (New-CaptureDirectorySecurity)))
    } else {
        $unixMode = [Type]::GetType('System.IO.UnixFileMode', $true)
        $method = [IO.Directory].GetMethod('CreateDirectory', [Type[]] @([string], $unixMode))
        $mode = [Enum]::Parse($unixMode, 'UserRead, UserWrite, UserExecute')
        [void] $method.Invoke($null, @($fullPath, $mode))
    }
    Assert-CapturePathNoReparse -Root $Root -Path $fullPath
    if (-not (Test-CapturePrivatePathPermissions -Path $fullPath -IsDirectory $true)) { throw [Security.SecurityException]::new('CapturePrivatePermissionsUnavailable') }
}

function Ensure-CapturePrivateDirectory {
    param([Parameter(Mandatory)][string] $Root, [Parameter(Mandatory)][string] $Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    Assert-CapturePathNoReparse -Root $Root -Path $fullPath
    if (Test-Path -LiteralPath $fullPath) {
        Assert-CapturePathNoReparse -Root $Root -Path $fullPath
        if (-not (Test-CapturePrivatePathPermissions -Path $fullPath -IsDirectory $true)) { throw [Security.SecurityException]::new('CapturePrivatePermissionsUnavailable') }
        return
    }
    New-CapturePrivateDirectory -Root $Root -Path $fullPath
}

function Write-CapturePrivateBytes {
    param([Parameter(Mandatory)][string] $Root, [Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][AllowEmptyCollection()][byte[]] $Bytes)
    $fullPath = [IO.Path]::GetFullPath($Path)
    Assert-CapturePathNoReparse -Root $Root -Path $fullPath
    if (Test-Path -LiteralPath $fullPath) { throw [IO.IOException]::new('CapturePrivatePathCollision') }
    $stream = $null
    try {
        Assert-CapturePathNoReparse -Root $Root -Path $fullPath
        if ($IsWindows) {
            $aclAssembly = [Reflection.Assembly]::Load('System.IO.FileSystem.AccessControl')
            $aclExtensions = $aclAssembly.GetType('System.IO.FileSystemAclExtensions', $true)
            $method = $aclExtensions.GetMethod('Create', [Type[]] @([IO.FileInfo], [IO.FileMode], [Security.AccessControl.FileSystemRights], [IO.FileShare], [int], [IO.FileOptions], [Security.AccessControl.FileSecurity]))
            $stream = $method.Invoke($null, @([IO.FileInfo]::new($fullPath), [IO.FileMode]::CreateNew, [Security.AccessControl.FileSystemRights]::FullControl, [IO.FileShare]::None, [int] 4096, [IO.FileOptions]::None, (New-CaptureFileSecurity)))
        } else {
            $unixMode = [Type]::GetType('System.IO.UnixFileMode', $true)
            $streamOptions = [Type]::GetType('System.IO.FileStreamOptions', $true)
            $options = [Activator]::CreateInstance($streamOptions)
            $options.Mode = [IO.FileMode]::CreateNew
            $options.Access = [IO.FileAccess]::Write
            $options.Share = [IO.FileShare]::None
            $options.UnixCreateMode = [Enum]::Parse($unixMode, 'UserRead, UserWrite')
            $constructor = [IO.FileStream].GetConstructor([Type[]] @([string], $streamOptions))
            $stream = $constructor.Invoke(@($fullPath, $options))
        }
        Assert-CapturePathNoReparse -Root $Root -Path $fullPath
        if (-not (Test-CapturePrivatePathPermissions -Path $fullPath -IsDirectory $false -Stream $stream)) { throw [Security.SecurityException]::new('CapturePrivatePermissionsUnavailable') }
        Assert-CapturePathNoReparse -Root $Root -Path $fullPath
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush()
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Test-ScopeContract {
    param([System.Collections.IDictionary] $Scope)
    if (($Scope.Keys | Sort-Object) -join ',' -cne 'apiBase,cloudId,schemaVersion,scope,siteOrigin') { return 'ScopeSchemaInvalid' }
    if ($Scope.schemaVersion -ne 1 -or $Scope.siteOrigin -isnot [string] -or $Scope.cloudId -isnot [string] -or $Scope.apiBase -isnot [string]) { return 'ScopeSchemaInvalid' }
    $format = '\A[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}\z'
    if ($Scope.cloudId.Length -ne 36 -or $Scope.cloudId -cnotmatch $format) { return 'ScopeSchemaInvalid' }
    $cloudGuid = [Guid]::Empty
    if (-not [Guid]::TryParseExact($Scope.cloudId, 'D', [ref] $cloudGuid)) { return 'ScopeSchemaInvalid' }
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
        Method = 'GET'; Uri = ($ApiBase.TrimEnd('/') + $RelativePath); Headers = @{ Accept = 'application/json' }
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
    if ($id -cne $RequestedPageId -or $status -cne 'current' -or [string]::IsNullOrWhiteSpace([string]$storage) -or
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
    $mediaTypeValue = Get-CaptureValue -Object $Attachment -Name 'mediaType'
    if ($id -cnotmatch '^[0-9]+$' -or [string]::IsNullOrWhiteSpace($title) -or $title -match '[\\/]' -or
        $null -eq $version -or [int] $version -lt 1 -or $null -eq $size -or [int64] $size -lt 0 -or [int64] $size -gt 20MB) { return $null }
    if ([string]::IsNullOrWhiteSpace([string]$mediaTypeValue)) { return $null }
    $download = [string] (Get-CaptureValue -Object $Attachment -Name 'downloadLink')
    $expected = "/wiki/rest/api/content/$PageId/child/attachment/$id/download"
    if ($download -cne $expected) { return $null }
    return [pscustomobject]@{
        id = $id; filename = $title; version = [int] $version; byteLength = [int64] $size
        mediaType = [string] (Get-CaptureValue -Object $Attachment -Name 'mediaType'); downloadPath = $download
    }
}

function Invoke-AttachmentDownload {
    param([string] $ApiBase, [object] $Attachment, [scriptblock] $HttpInvoker, [long] $ResponseLimitBytes = 20MB)
    $request = [pscustomobject]@{
        Method = 'GET'; Uri = ([string]($($ApiBase.TrimEnd('/'))) + [string]($($Attachment.downloadPath)) + '?version=' + [string]($($Attachment.version))); Headers = @{ Accept = '*/*' }
        Body = $null; TimeoutSec = 30; ResponseLimitBytes = $ResponseLimitBytes; AuthAllowed = $true
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

function Test-ConfluenceCaptureBudgetLimits {
    param(
        [long] $MaxAttachmentDownloadBytes = 1GB,
        [int] $MaxAttachmentAttempts = 1000,
        [long] $MaxCaptureBytes = 1GB
    )
    if ($MaxAttachmentDownloadBytes -lt 1 -or $MaxAttachmentDownloadBytes -gt 1GB -or
        $MaxAttachmentAttempts -lt 1 -or $MaxAttachmentAttempts -gt 1000 -or
        $MaxCaptureBytes -lt (16MB + 1) -or $MaxCaptureBytes -gt 1GB) { return 'CaptureBudgetInvalid' }
    return $null
}

function New-CaptureManifestRecord {
    param(
        [string] $CaptureId,
        [string] $CapturedAtUtc,
        [System.Collections.IDictionary] $Scope,
        [string] $Status,
        [string[]] $ReasonCodes,
        [string[]] $IncompletePageIds,
        [object[]] $Pages
    )
    return [ordered]@{
        schemaVersion = 1; captureId = $CaptureId; capturedAtUtc = $CapturedAtUtc
        siteOrigin = $Scope.siteOrigin; cloudId = $Scope.cloudId; scope = $Scope.scope
        status = $Status; reasonCodes = @($ReasonCodes); incompletePageIds = @($IncompletePageIds)
        pages = @($Pages)
    }
}

function New-CaptureAuditFileRecord {
    param([string] $RelativePath, [long] $Length, [string] $Sha256)
    return [ordered]@{ relativePath = $RelativePath; length = $Length; sha256 = $Sha256 }
}

function Get-CaptureTerminalPlan {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Manifest,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $UnindexedFiles,
        [Parameter(Mandatory)][long] $DataBytes,
        [Parameter(Mandatory)][long] $MaxCaptureBytes
    )
    $utf8 = [Text.UTF8Encoding]::new($false)
    $manifestText = ConvertTo-Json -InputObject $Manifest -Depth 15
    $manifestBytes = $utf8.GetBytes($manifestText)
    if ($manifestBytes.LongLength -gt 4MB) {
        return [pscustomobject]@{ accepted = $false; reason = 'CaptureMetadataBudgetExceeded'; manifest = $Manifest; manifestText = $manifestText; manifestBytes = $manifestBytes; auditText = $null; auditBytes = [byte[]]@(); auditIncomplete = $false }
    }

    $auditText = $null
    $auditBytes = [byte[]]@()
    $auditIncomplete = $false
    if (@($UnindexedFiles).Count -gt 0) {
        $audit = [ordered]@{ schemaVersion = 1; captureId = [string] $Manifest.captureId; status = 'complete'; files = @($UnindexedFiles) }
        $auditText = ConvertTo-Json -InputObject $audit -Depth 10
        $auditBytes = $utf8.GetBytes($auditText)
        if (($manifestBytes.LongLength + $auditBytes.LongLength) -gt 16MB) {
            $reasonCodes = @($Manifest.reasonCodes) + @('CaptureAuditIncomplete') | Select-Object -Unique
            $updated = [ordered]@{}
            foreach ($key in $Manifest.Keys) {
                if ([string] $key -ceq 'reasonCodes') { $updated[$key] = @($reasonCodes) }
                else { $updated[$key] = $Manifest[$key] }
            }
            $Manifest = $updated
            $manifestText = ConvertTo-Json -InputObject $Manifest -Depth 15
            $manifestBytes = $utf8.GetBytes($manifestText)
            $audit = [ordered]@{ schemaVersion = 1; captureId = [string] $Manifest.captureId; status = 'incomplete'; omittedFileCount = [int] @($UnindexedFiles).Count; files = @() }
            $auditText = ConvertTo-Json -InputObject $audit -Depth 10
            $auditBytes = $utf8.GetBytes($auditText)
            $auditIncomplete = $true
        }
    }

    if ($manifestBytes.LongLength -gt 4MB -or ($manifestBytes.LongLength + $auditBytes.LongLength) -gt 16MB -or
        ($DataBytes + $manifestBytes.LongLength + $auditBytes.LongLength) -gt $MaxCaptureBytes) {
        return [pscustomobject]@{ accepted = $false; reason = 'CaptureMetadataBudgetExceeded'; manifest = $Manifest; manifestText = $manifestText; manifestBytes = $manifestBytes; auditText = $auditText; auditBytes = $auditBytes; auditIncomplete = $auditIncomplete }
    }
    return [pscustomobject]@{ accepted = $true; reason = $null; manifest = $Manifest; manifestText = $manifestText; manifestBytes = $manifestBytes; auditText = $auditText; auditBytes = $auditBytes; auditIncomplete = $auditIncomplete }
}

function New-CaptureBudgetTerminalPlan {
    param(
        [string] $CaptureId,
        [string] $CapturedAtUtc,
        [System.Collections.IDictionary] $Scope,
        [string] $Status,
        [string[]] $ReasonCodes,
        [string[]] $IncompletePageIds,
        [object[]] $Pages,
        [object[]] $UnindexedFiles,
        [long] $DataBytes,
        [long] $MaxCaptureBytes
    )
    $manifest = New-CaptureManifestRecord -CaptureId $CaptureId -CapturedAtUtc $CapturedAtUtc -Scope $Scope -Status $Status -ReasonCodes $ReasonCodes -IncompletePageIds $IncompletePageIds -Pages $Pages
    return Get-CaptureTerminalPlan -Manifest $manifest -UnindexedFiles $UnindexedFiles -DataBytes $DataBytes -MaxCaptureBytes $MaxCaptureBytes
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
        [Parameter(Mandatory)][scriptblock] $HttpInvoker,
        [long] $MaxAttachmentDownloadBytes = 1GB,
        [int] $MaxAttachmentAttempts = 1000,
        [long] $MaxCaptureBytes = 1GB
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
    $budgetError = Test-ConfluenceCaptureBudgetLimits -MaxAttachmentDownloadBytes $MaxAttachmentDownloadBytes -MaxAttachmentAttempts $MaxAttachmentAttempts -MaxCaptureBytes $MaxCaptureBytes
    if ($null -ne $budgetError) { return New-CaptureResult -Status 'invalid' -ReasonCodes @($budgetError) -CapturePath '' }
    if (-not (Test-ConfluenceCapturePrivatePermissions)) {
        return New-CaptureResult -Status 'failed' -ReasonCodes @('CapturePrivatePermissionsUnavailable') -CapturePath ''
    }

    $captureId = [Guid]::NewGuid().ToString('N')
    $capturedAtUtc = (Get-Date -AsUTC).ToString('o')
    $possibleReasons = @(
        'RemoteReadFailed', 'RemoteAuthenticationFailed', 'RemoteReadDenied', 'RemoteReadUnavailable', 'RemoteRateLimited',
        'ResponseTooLarge', 'ResponseInvalid', 'UnsafeReadPath', 'DraftReadIncomplete', 'PageIdentityInvalid',
        'AttachmentReadIncomplete', 'AttachmentIdentityInvalid', 'AttachmentDownloadFailed', 'AttachmentBytesMismatch',
        'AttachmentUnstable', 'ProjectedImageAttachmentUnresolved', 'PageUnstable', 'UnsupportedContent', 'CaptureAttachmentBudgetExceeded',
        'CaptureFileBudgetExceeded', 'CaptureMetadataBudgetExceeded', 'CaptureAuditIncomplete',
        'PaginationLimit', 'PaginationLoop', 'RemoteIdMissing', 'DuplicateRemoteId',
        'PaginationInconsistent', 'UnsafePaginationTarget', 'UnsafeInitialPath'
    )
    $initialIncompleteIds = if ($scope.scope.kind -ceq 'page') { @($scope.scope.pageIds | ForEach-Object { [string] $_ }) } else { @() }
    $initialPlan = New-CaptureBudgetTerminalPlan -CaptureId $captureId -CapturedAtUtc $capturedAtUtc -Scope $scope `
        -Status 'partial' -ReasonCodes $possibleReasons -IncompletePageIds $initialIncompleteIds -Pages @() `
        -UnindexedFiles @() -DataBytes 0 -MaxCaptureBytes $MaxCaptureBytes
    if (-not $initialPlan.accepted) { return New-CaptureResult -Status 'invalid' -ReasonCodes @('CaptureMetadataBudgetExceeded') -CapturePath '' }

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
    if ((Test-Path -LiteralPath $stage) -or (Test-Path -LiteralPath $final)) {
        return New-CaptureResult -Status 'failed' -ReasonCodes @('CaptureStagingConflict') -CapturePath ''
    }
    try {
        Assert-CapturePathNoReparse -Root $resolvedRoot -Path $privateRoot
        New-Item -ItemType Directory -Path $privateRoot -Force | Out-Null
        Assert-CapturePathNoReparse -Root $resolvedRoot -Path $privateRoot
        $ignorePath = Join-Path $privateRoot '.gitignore'
        Assert-CapturePathNoReparse -Root $resolvedRoot -Path $ignorePath
        if (-not (Test-Path -LiteralPath $ignorePath)) {
            Assert-CapturePathNoReparse -Root $resolvedRoot -Path $ignorePath
            [IO.File]::WriteAllText($ignorePath, ('*' + ([string][char]10) + ''), [Text.UTF8Encoding]::new($false))
            Assert-CapturePathNoReparse -Root $resolvedRoot -Path $ignorePath
        }
        Assert-CapturePathNoReparse -Root $resolvedRoot -Path $captureRoot
        New-Item -ItemType Directory -Path $captureRoot -Force | Out-Null
        Assert-CapturePathNoReparse -Root $resolvedRoot -Path $captureRoot
        New-CapturePrivateDirectory -Root $resolvedRoot -Path $stage
        New-CapturePrivateDirectory -Root $resolvedRoot -Path (Join-Path $stage 'pages')
    } catch {
        return New-CaptureResult -Status 'failed' -ReasonCodes @('CapturePrivatePermissionsUnavailable') -CapturePath $stage
    }
    $pages = [System.Collections.Generic.List[object]]::new()
    $incompleteIds = [System.Collections.Generic.List[string]]::new()
    $reasons = [System.Collections.Generic.List[string]]::new()
    $pageIds = [System.Collections.Generic.List[string]]::new()
    $unindexedFiles = [System.Collections.Generic.List[object]]::new()
    $attemptCount = 0
    [long] $attemptBytesReserved = 0
    [long] $dataBytesUsed = 0
    [long] $dataBytesLimit = $MaxCaptureBytes - 16MB
    $stopForBudget = $false
    $spaceId = ''
    try {
        if ($scope.scope.kind -ceq 'space') {
            $spaceId = [string] $scope.scope.spaceId
            $listing = Get-ConfluenceCollection -ExpectedSiteOrigin $ExpectedSiteOrigin -ConfiguredSiteOrigin $scope.siteOrigin -ApiBase $scope.apiBase -CloudId $scope.cloudId -RelativePath ('/wiki/api/v2/spaces/' + [string]($spaceId) + '/pages?limit=50') -HttpInvoker $HttpInvoker
            $seenPageIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($item in @($listing.items)) {
                $listedPageId = [string] (Get-CaptureValue -Object $item -Name 'id')
                if ($listedPageId -cmatch '^[0-9]+$') {
                    if ($seenPageIds.Add($listedPageId)) { $pageIds.Add($listedPageId) }
                } else { $reasons.Add('PageIdentityInvalid') }
            }
            if ($listing.status -cne 'complete') { foreach ($code in @($listing.reasonCodes)) { $reasons.Add([string] $code) } }
        } else { foreach ($id in @($scope.scope.pageIds)) { $pageIds.Add([string] $id) } }

        if ($scope.scope.kind -ceq 'space') {
            $listedFallback = New-CaptureBudgetTerminalPlan -CaptureId $captureId -CapturedAtUtc $capturedAtUtc -Scope $scope `
                -Status 'partial' -ReasonCodes (@($reasons.ToArray()) + @($possibleReasons) | Select-Object -Unique) `
                -IncompletePageIds @($pageIds.ToArray()) -Pages @() -UnindexedFiles @() -DataBytes 0 -MaxCaptureBytes $MaxCaptureBytes
            if (-not $listedFallback.accepted) {
                $reasons.Add('CaptureMetadataBudgetExceeded')
                $pageIds.Clear()
                $stopForBudget = $true
            }
        }

        for ($pageIndex = 0; $pageIndex -lt $pageIds.Count; $pageIndex++) {
            $pageId = [string] $pageIds[$pageIndex]
            $remainingPageIds = @($pageIds.ToArray() | Select-Object -Skip $pageIndex)
            $pagePath = "/wiki/api/v2/pages/${pageId}?body-format=storage"
            $read = Invoke-CaptureRead -ApiBase $scope.apiBase -RelativePath $pagePath -HttpInvoker $HttpInvoker
            if ($null -ne $read.reason) { $reasons.Add($read.reason); $incompleteIds.Add($pageId); continue }
            $identity = Get-PageIdentity -Page $read.body -RequestedPageId $pageId -ExpectedSpaceId $spaceId
            if ($null -eq $identity) { $reasons.Add('PageIdentityInvalid'); $incompleteIds.Add($pageId); continue }
            $draft = Invoke-CaptureRead -ApiBase $scope.apiBase -RelativePath "$pagePath&get-draft=true" -HttpInvoker $HttpInvoker
            if ($null -ne $draft.reason) { $reasons.Add('DraftReadIncomplete'); $incompleteIds.Add($pageId); continue }
            $draftIdentity = Get-PageIdentity -Page $draft.body -RequestedPageId $pageId -ExpectedSpaceId $spaceId
            if ($null -eq $draftIdentity) { $reasons.Add('DraftReadIncomplete'); $incompleteIds.Add($pageId); continue }
            $draftObservation = if ($null -eq $draftIdentity -or $draftIdentity.version -ne $identity.version -or $draftIdentity.storage -cne $identity.storage) { 'diverged' } else { 'same-as-published' }
            $relativeSnapshot = "pages/$pageId/storage.xml"
            $relativeCandidate = "pages/$pageId/candidate.md"
            $pageDirectory = Join-Path $stage "pages/$pageId"
            $storageBytes = [Text.UTF8Encoding]::new($false).GetBytes([string] $identity.storage)
            $rawAudit = New-CaptureAuditFileRecord -RelativePath $relativeSnapshot -Length $storageBytes.LongLength -Sha256 (Get-ByteHash -Bytes $storageBytes)
            $pendingPageAudit = [System.Collections.Generic.List[object]]::new()
            $pendingPageAudit.Add($rawAudit)
            $rawBudgetIncomplete = @(@($incompleteIds.ToArray()) + @($remainingPageIds) | Select-Object -Unique)
            $rawFallbackReasons = @(@($reasons.ToArray()) + @($possibleReasons) | Select-Object -Unique)
            $rawDataBytes = $dataBytesUsed + $storageBytes.LongLength
            $rawOnlyTerminal = New-CaptureBudgetTerminalPlan -CaptureId $captureId -CapturedAtUtc $capturedAtUtc -Scope $scope `
                -Status 'partial' -ReasonCodes $rawFallbackReasons -IncompletePageIds $rawBudgetIncomplete -Pages @($pages.ToArray()) `
                -UnindexedFiles (@($unindexedFiles.ToArray()) + @($pendingPageAudit.ToArray())) -DataBytes $rawDataBytes -MaxCaptureBytes $MaxCaptureBytes
            if (-not $rawOnlyTerminal.accepted -or $rawDataBytes -gt $dataBytesLimit) {
                if (-not $rawOnlyTerminal.accepted) { $reasons.Add('CaptureMetadataBudgetExceeded') }
                if ($rawDataBytes -gt $dataBytesLimit) { $reasons.Add('CaptureFileBudgetExceeded') }
                foreach ($id in $rawBudgetIncomplete) { if (-not $incompleteIds.Contains([string] $id)) { $incompleteIds.Add([string] $id) } }
                $minimalTerminal = New-CaptureBudgetTerminalPlan -CaptureId $captureId -CapturedAtUtc $capturedAtUtc -Scope $scope `
                    -Status 'partial' -ReasonCodes @($reasons.ToArray() | Select-Object -Unique) -IncompletePageIds @($incompleteIds.ToArray()) `
                    -Pages @($pages.ToArray()) -UnindexedFiles @($unindexedFiles.ToArray()) -DataBytes $dataBytesUsed -MaxCaptureBytes $MaxCaptureBytes
                if (-not $minimalTerminal.accepted) { return New-CaptureResult -Status 'failed' -ReasonCodes @('CaptureMetadataBudgetExceeded') -CapturePath $stage }
                $stopForBudget = $true
                break
            }
            New-CapturePrivateDirectory -Root $resolvedRoot -Path $pageDirectory
            Write-CapturePrivateBytes -Root $resolvedRoot -Path (Join-Path $pageDirectory 'storage.xml') -Bytes $storageBytes
            $dataBytesUsed += $storageBytes.LongLength

            $projection = ConvertFrom-ConfluenceStorage -Storage $identity.storage -PageId $pageId -PageVersion $identity.version
            $attachmentPath = "/wiki/api/v2/pages/$pageId/attachments?limit=50"
            $before = Get-ConfluenceCollection -ExpectedSiteOrigin $ExpectedSiteOrigin -ConfiguredSiteOrigin $scope.siteOrigin -ApiBase $scope.apiBase -CloudId $scope.cloudId -RelativePath $attachmentPath -HttpInvoker $HttpInvoker
            $attachmentIdentities = [System.Collections.Generic.List[object]]::new()
            $plannedAssets = [System.Collections.Generic.List[object]]::new()
            $savedAssets = [System.Collections.Generic.List[object]]::new()
            $pageReasons = [System.Collections.Generic.List[string]]::new()
            if ($before.status -cne 'complete') { $pageReasons.Add('AttachmentReadIncomplete') }
            foreach ($attachment in @($before.items)) {
                $asset = Get-AttachmentIdentity -Attachment $attachment -PageId $pageId
                if ($null -eq $asset) { $pageReasons.Add('AttachmentIdentityInvalid'); continue }
                $attachmentIdentities.Add($asset)
                $plannedAssets.Add([ordered]@{
                    attachmentId = $asset.id; version = $asset.version; filename = $asset.filename
                    mediaType = $asset.mediaType; byteLength = $asset.byteLength; sha256 = ('0' * 64); assetPath = ('assets/' + ('0' * 64))
                })
            }

            $relativeAssetRecords = [System.Collections.Generic.List[object]]::new()
            foreach ($assetRecord in $plannedAssets) { $relativeAssetRecords.Add($assetRecord) }
            $candidatePage = [ordered]@{
                pageId = $pageId; spaceId = $identity.spaceId; parentId = $identity.parentId
                title = $identity.title; version = $identity.version; bodySha256 = $projection.bodySha256
                draftObservation = $draftObservation; snapshotPath = $relativeSnapshot; candidatePath = $relativeCandidate
                projectionStatus = $projection.status; sourceBlocks = @($projection.sourceBlocks)
                unsupported = @($projection.unsupported | ForEach-Object { [ordered]@{ code = $_.code; location = $_.location; sourceSha256 = $_.sourceSha256 } })
                attachments = @($relativeAssetRecords.ToArray())
            }
            if ($projection.status -cne 'supported') { $pageReasons.Add('UnsupportedContent') }

            $candidateBytes = [Text.UTF8Encoding]::new($false).GetBytes([string] $projection.markdown)
            $candidateAudit = New-CaptureAuditFileRecord -RelativePath $relativeCandidate -Length $candidateBytes.LongLength -Sha256 (Get-ByteHash -Bytes $candidateBytes)

            $futureIds = @($pageIds.ToArray() | Select-Object -Skip ($pageIndex + 1))
            $candidateStatus = if ($pageReasons.Count -gt 0 -or $reasons.Count -gt 0 -or $incompleteIds.Count -gt 0 -or $futureIds.Count -gt 0) { 'partial' } else { 'complete' }
            $candidateReasons = @()
            if ($candidateStatus -cne 'complete') {
                $candidateReasons = @(@($reasons.ToArray()) + @($pageReasons.ToArray()) + @($possibleReasons) | Select-Object -Unique)
            }
            $candidateIncomplete = @(@($incompleteIds.ToArray()) + @($futureIds) | Select-Object -Unique)
            $candidatePages = @($pages.ToArray()) + @($candidatePage)
            $candidateTerminal = New-CaptureBudgetTerminalPlan -CaptureId $captureId -CapturedAtUtc $capturedAtUtc -Scope $scope `
                -Status $candidateStatus -ReasonCodes $candidateReasons -IncompletePageIds $candidateIncomplete -Pages $candidatePages `
                -UnindexedFiles @($unindexedFiles.ToArray()) -DataBytes ($dataBytesUsed + $candidateBytes.LongLength) -MaxCaptureBytes $MaxCaptureBytes

            $budgetIncomplete = @($incompleteIds.ToArray()) + $remainingPageIds | Select-Object -Unique
            $fallbackReasons = @($reasons.ToArray()) + @($pageReasons.ToArray()) + @($possibleReasons) + @('CaptureMetadataBudgetExceeded') | Select-Object -Unique
            $fallbackFiles = @($unindexedFiles.ToArray()) + @($pendingPageAudit.ToArray()) + @($candidateAudit)
            $fallbackTerminal = New-CaptureBudgetTerminalPlan -CaptureId $captureId -CapturedAtUtc $capturedAtUtc -Scope $scope `
                -Status 'partial' -ReasonCodes $fallbackReasons -IncompletePageIds $budgetIncomplete -Pages @($pages.ToArray()) `
                -UnindexedFiles $fallbackFiles -DataBytes ($dataBytesUsed + $candidateBytes.LongLength) -MaxCaptureBytes $MaxCaptureBytes

            if (-not $candidateTerminal.accepted -or -not $fallbackTerminal.accepted) {
                $reason = if (-not $candidateTerminal.accepted) { 'CaptureMetadataBudgetExceeded' } else { 'CaptureMetadataBudgetExceeded' }
                $reasons.Add($reason)
                foreach ($id in $budgetIncomplete) { if (-not $incompleteIds.Contains([string] $id)) { $incompleteIds.Add([string] $id) } }
                foreach ($file in $pendingPageAudit) { $unindexedFiles.Add($file) }
                $stopForBudget = $true
                break
            }

            if (($dataBytesUsed + $candidateBytes.LongLength) -gt $dataBytesLimit) {
                $reasons.Add('CaptureFileBudgetExceeded')
                foreach ($id in $budgetIncomplete) { if (-not $incompleteIds.Contains([string] $id)) { $incompleteIds.Add([string] $id) } }
                foreach ($file in $pendingPageAudit) { $unindexedFiles.Add($file) }
                $stopForBudget = $true
                break
            }

            $partialBeforeCandidate = New-CaptureBudgetTerminalPlan -CaptureId $captureId -CapturedAtUtc $capturedAtUtc -Scope $scope `
                -Status 'partial' -ReasonCodes $fallbackReasons -IncompletePageIds $budgetIncomplete -Pages @($pages.ToArray()) `
                -UnindexedFiles (@($unindexedFiles.ToArray()) + @($pendingPageAudit.ToArray()) + @($candidateAudit)) -DataBytes ($dataBytesUsed + $candidateBytes.LongLength) -MaxCaptureBytes $MaxCaptureBytes
            if (-not $partialBeforeCandidate.accepted) {
                $reasons.Add('CaptureMetadataBudgetExceeded')
                foreach ($id in $budgetIncomplete) { if (-not $incompleteIds.Contains([string] $id)) { $incompleteIds.Add([string] $id) } }
                foreach ($file in $pendingPageAudit) { $unindexedFiles.Add($file) }
                $stopForBudget = $true
                break
            }
            Write-CapturePrivateBytes -Root $resolvedRoot -Path (Join-Path $pageDirectory 'candidate.md') -Bytes $candidateBytes
            $dataBytesUsed += $candidateBytes.LongLength
            $pendingPageAudit.Add($candidateAudit)

            if ($before.status -cne 'complete') { $reasons.Add('AttachmentReadIncomplete') }
            $pageBudgetStop = $false
            foreach ($asset in $attachmentIdentities) {
                $reservedBytes = [Math]::Max([long] $asset.byteLength, [long] 1)
                $attemptBytesRemaining = $MaxAttachmentDownloadBytes - $attemptBytesReserved
                if ($attemptCount -ge $MaxAttachmentAttempts -or $reservedBytes -gt $attemptBytesRemaining) {
                    $reasons.Add('CaptureAttachmentBudgetExceeded')
                    $pageBudgetStop = $true
                    break
                }
                $potentialFallback = New-CaptureBudgetTerminalPlan -CaptureId $captureId -CapturedAtUtc $capturedAtUtc -Scope $scope `
                    -Status 'partial' -ReasonCodes (@($reasons.ToArray()) + @($possibleReasons) + @('CaptureAttachmentBudgetExceeded') | Select-Object -Unique) `
                    -IncompletePageIds $budgetIncomplete -Pages @($pages.ToArray()) -UnindexedFiles (@($unindexedFiles.ToArray()) + @($pendingPageAudit.ToArray())) `
                    -DataBytes $dataBytesUsed -MaxCaptureBytes $MaxCaptureBytes
                if (-not $potentialFallback.accepted) {
                    $reasons.Add('CaptureMetadataBudgetExceeded')
                    $pageBudgetStop = $true
                    break
                }

                $attemptCap = [long] 20MB
                $declaredByteCap = [Math]::Max([long] $asset.byteLength, [long] 1)
                if ($declaredByteCap -lt $attemptCap) { $attemptCap = $declaredByteCap }
                if ($attemptBytesRemaining -lt $attemptCap) { $attemptCap = $attemptBytesRemaining }
                $attemptCount++
                $attemptBytesReserved += $reservedBytes
                $download = Invoke-AttachmentDownload -ApiBase $scope.apiBase -Attachment $asset -HttpInvoker $HttpInvoker -ResponseLimitBytes $attemptCap
                if ($null -ne $download.reason) { $reasons.Add($download.reason); continue }
                $sha = Get-ByteHash -Bytes $download.bytes
                $relativeAsset = "assets/$sha"
                $assetDirectory = Join-Path $stage 'assets'
                Ensure-CapturePrivateDirectory -Root $resolvedRoot -Path $assetDirectory
                $assetFile = Join-Path $assetDirectory $sha
                Assert-CapturePathNoReparse -Root $resolvedRoot -Path $assetFile
                $assetAlreadyExists = Test-Path -LiteralPath $assetFile -PathType Leaf
                $assetBytesToAdd = if ($assetAlreadyExists) { [long] 0 } else { [long] $download.bytes.LongLength }
                if (($dataBytesUsed + $assetBytesToAdd) -gt $dataBytesLimit) {
                    $reasons.Add('CaptureFileBudgetExceeded')
                    $pageBudgetStop = $true
                    break
                }
                $assetAudit = New-CaptureAuditFileRecord -RelativePath $relativeAsset -Length $download.bytes.LongLength -Sha256 $sha
                $prospectivePageAudit = @($unindexedFiles.ToArray()) + @($pendingPageAudit.ToArray())
                if (-not $assetAlreadyExists) { $prospectivePageAudit += $assetAudit }
                $preAssetWrite = New-CaptureBudgetTerminalPlan -CaptureId $captureId -CapturedAtUtc $capturedAtUtc -Scope $scope `
                    -Status 'partial' -ReasonCodes (@($reasons.ToArray()) + @($possibleReasons) + @('CaptureMetadataBudgetExceeded') | Select-Object -Unique) `
                    -IncompletePageIds $budgetIncomplete -Pages @($pages.ToArray()) -UnindexedFiles $prospectivePageAudit `
                    -DataBytes ($dataBytesUsed + $assetBytesToAdd) -MaxCaptureBytes $MaxCaptureBytes
                if (-not $preAssetWrite.accepted -or ($dataBytesUsed + $assetBytesToAdd) -gt $dataBytesLimit) {
                    $reasons.Add('CaptureFileBudgetExceeded')
                    $pageBudgetStop = $true
                    break
                }
                if (Test-Path -LiteralPath $assetFile -PathType Leaf) {
                    Assert-CapturePathNoReparse -Root $resolvedRoot -Path $assetFile
                    if (-not (Test-CapturePrivatePathPermissions -Path $assetFile -IsDirectory $false) -or (Get-ByteHash -Bytes ([IO.File]::ReadAllBytes($assetFile))) -cne $sha) {
                        throw [Security.SecurityException]::new('CapturePrivatePermissionsUnavailable')
                    }
                } else {
                    Write-CapturePrivateBytes -Root $resolvedRoot -Path $assetFile -Bytes $download.bytes
                    $dataBytesUsed += $download.bytes.LongLength
                    $pendingPageAudit.Add($assetAudit)
                }
                $savedAssets.Add([ordered]@{
                    attachmentId = $asset.id; version = $asset.version; filename = $asset.filename
                    mediaType = $asset.mediaType; byteLength = $asset.byteLength; sha256 = $sha; assetPath = $relativeAsset
                })
            }

            if ($pageBudgetStop) {
                foreach ($id in $budgetIncomplete) { if (-not $incompleteIds.Contains([string] $id)) { $incompleteIds.Add([string] $id) } }
                foreach ($file in $pendingPageAudit) { $unindexedFiles.Add($file) }
                $stopForBudget = $true
                break
            }

            $after = Get-ConfluenceCollection -ExpectedSiteOrigin $ExpectedSiteOrigin -ConfiguredSiteOrigin $scope.siteOrigin -ApiBase $scope.apiBase -CloudId $scope.cloudId -RelativePath $attachmentPath -HttpInvoker $HttpInvoker
            if ($after.status -cne 'complete') { $reasons.Add('AttachmentReadIncomplete') }
            $afterIdentities = [System.Collections.Generic.List[object]]::new()
            foreach ($attachment in @($after.items)) {
                $asset = Get-AttachmentIdentity -Attachment $attachment -PageId $pageId
                if ($null -eq $asset) { $reasons.Add('AttachmentIdentityInvalid') } else { $afterIdentities.Add($asset) }
            }
            $attachmentsStable = Test-AttachmentStable -Before $attachmentIdentities.ToArray() -After $afterIdentities.ToArray()
            if (-not $attachmentsStable) { $reasons.Add('AttachmentUnstable') }
            elseif ($after.status -ceq 'complete') {
                foreach ($projectedAsset in @($projection.assets)) {
                    $projectedFilename = [string] $projectedAsset.filename
                    $savedIdentityCount = 0
                    foreach ($savedAsset in $savedAssets) {
                        if ([StringComparer]::Ordinal.Equals([string] $savedAsset.filename, $projectedFilename)) {
                            $savedIdentityCount++
                            if ($savedIdentityCount -gt 1) { break }
                        }
                    }
                    if ($savedIdentityCount -ne 1) {
                        $reasons.Add('ProjectedImageAttachmentUnresolved')
                        break
                    }
                }
            }
            $reread = Invoke-CaptureRead -ApiBase $scope.apiBase -RelativePath $pagePath -HttpInvoker $HttpInvoker
            $stablePage = if ($null -eq $reread.reason) { Get-PageIdentity -Page $reread.body -RequestedPageId $pageId -ExpectedSpaceId $spaceId } else { $null }
            if ($null -eq $stablePage -or $stablePage.version -ne $identity.version -or $stablePage.storage -cne $identity.storage -or $stablePage.title -cne $identity.title) { $reasons.Add('PageUnstable') }
            foreach ($code in $pageReasons) { $reasons.Add($code) }
            $pageRecord = [ordered]@{
                pageId = $pageId; spaceId = $identity.spaceId; parentId = $identity.parentId
                title = $identity.title; version = $identity.version; bodySha256 = $projection.bodySha256
                draftObservation = $draftObservation; snapshotPath = $relativeSnapshot; candidatePath = $relativeCandidate
                projectionStatus = $projection.status; sourceBlocks = @($projection.sourceBlocks)
                unsupported = @($projection.unsupported | ForEach-Object { [ordered]@{ code = $_.code; location = $_.location; sourceSha256 = $_.sourceSha256 } })
                attachments = @($savedAssets.ToArray())
            }
            $pageResultReasons = @($reasons.ToArray() | Select-Object -Unique)
            $pageResultStatus = if ($pageResultReasons.Count -eq 0 -and $incompleteIds.Count -eq 0 -and $futureIds.Count -eq 0) { 'complete' } else { 'partial' }
            $pageResultIncomplete = @(@($incompleteIds.ToArray()) + @($futureIds) | Select-Object -Unique)
            $pageResultPages = @($pages.ToArray()) + @($pageRecord)
            $pageResultTerminal = New-CaptureBudgetTerminalPlan -CaptureId $captureId -CapturedAtUtc $capturedAtUtc -Scope $scope `
                -Status $pageResultStatus -ReasonCodes $pageResultReasons -IncompletePageIds $pageResultIncomplete -Pages $pageResultPages `
                -UnindexedFiles @($unindexedFiles.ToArray()) -DataBytes $dataBytesUsed -MaxCaptureBytes $MaxCaptureBytes
            if (-not $pageResultTerminal.accepted) {
                $reasons.Add('CaptureMetadataBudgetExceeded')
                foreach ($id in $budgetIncomplete) { if (-not $incompleteIds.Contains([string] $id)) { $incompleteIds.Add([string] $id) } }
                foreach ($file in $pendingPageAudit) { $unindexedFiles.Add($file) }
                $stopForBudget = $true
                break
            }
            $pages.Add($pageRecord)
        }

        $uniqueReasons = @($reasons.ToArray() | Select-Object -Unique)
        $status = if ($uniqueReasons.Count -eq 0 -and $incompleteIds.Count -eq 0) { 'complete' } else { 'partial' }
        $terminalPlan = New-CaptureBudgetTerminalPlan -CaptureId $captureId -CapturedAtUtc $capturedAtUtc -Scope $scope `
            -Status $status -ReasonCodes $uniqueReasons -IncompletePageIds @($incompleteIds.ToArray()) -Pages @($pages.ToArray()) `
            -UnindexedFiles @($unindexedFiles.ToArray()) -DataBytes $dataBytesUsed -MaxCaptureBytes $MaxCaptureBytes
        if (-not $terminalPlan.accepted) { return New-CaptureResult -Status 'failed' -ReasonCodes @('CaptureMetadataBudgetExceeded') -CapturePath $stage }
        if (-not [string]::IsNullOrEmpty([string] $terminalPlan.auditText)) {
            Write-CapturePrivateBytes -Root $resolvedRoot -Path (Join-Path $stage 'capture-unindexed-files.json') -Bytes $terminalPlan.auditBytes
        }
        Write-CapturePrivateBytes -Root $resolvedRoot -Path (Join-Path $stage 'capture.json') -Bytes $terminalPlan.manifestBytes
        $uniqueReasons = @($terminalPlan.manifest.reasonCodes)
        $status = [string] $terminalPlan.manifest.status
        if (Test-Path -LiteralPath $final) {
            return New-CaptureResult -Status 'failed' -ReasonCodes @('CaptureStagingConflict') -CapturePath $stage
        }
        if (-not (Test-PathInside -Root $captureRoot -Path $stage) -or -not (Test-PathInside -Root $captureRoot -Path $final)) {
            return New-CaptureResult -Status 'failed' -ReasonCodes @('CaptureStagingConflict') -CapturePath $stage
        }
        Assert-CapturePathNoReparse -Root $resolvedRoot -Path $stage
        Assert-CapturePathNoReparse -Root $resolvedRoot -Path $final
        Move-Item -LiteralPath $stage -Destination $final
        Assert-CapturePathNoReparse -Root $resolvedRoot -Path $final
        foreach ($item in @((Get-Item -LiteralPath $final -Force)) + @(Get-ChildItem -LiteralPath $final -Force -Recurse)) {
            if (-not (Test-CapturePrivatePathPermissions -Path $item.FullName -IsDirectory $item.PSIsContainer)) {
                return New-CaptureResult -Status 'failed' -ReasonCodes @('CapturePrivatePermissionsUnavailable') -CapturePath $final
            }
        }
        return New-CaptureResult -Status $status -ReasonCodes $uniqueReasons -CapturePath $final
    }
    catch {
        $reason = if ($_.Exception.Message -ceq 'ReparsePointRejected') { 'ReparsePointRejected' }
            elseif ($_.Exception -is [Security.SecurityException] -or $_.Exception.Message -ceq 'CapturePrivatePermissionsUnavailable') { 'CapturePrivatePermissionsUnavailable' }
            else { 'CaptureFailure' }
        return New-CaptureResult -Status 'failed' -ReasonCodes @($reason) -CapturePath $stage
    }
}

Export-ModuleMember -Function Invoke-ConfluenceCapture, Test-ConfluenceCapturePrivatePermissions, Test-ConfluenceCaptureBudgetLimits
