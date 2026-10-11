# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
Import-Module -Name (Join-Path $PSScriptRoot 'ConfluenceTransport.psm1') -Force -Scope Local

function Get-AssetField {
    param([object]$Object,[string]$Name)
    if($null -eq $Object){return $null}
    if($Object -is [System.Collections.IDictionary]){$value=$Object[$Name]}
    else{
    $property=$Object.PSObject.Properties[$Name]
    if($null -eq $property){return $null}
    $value=$property.Value
    }
    if($value -is [array]){Write-Output -NoEnumerate $value}else{return $value}
}
function Get-AssetHash {
    param([byte[]]$Bytes)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}
function New-AssetResult {
    param([string]$Status,[string]$Reason,[object]$Fields)
    $result=[ordered]@{status=$Status;reasonCodes=$(if($Reason){@($Reason)}else{@()})}
    if($null -ne $Fields){foreach($key in $Fields.Keys){$result[$key]=$Fields[$key]}}
    return [pscustomobject]$result
}
function Test-AssetRelativePath {
    param([string]$Root,[string]$RelativePath)
    if([string]::IsNullOrWhiteSpace($RelativePath) -or $RelativePath -match '[\\\r\n]' -or
        $RelativePath.StartsWith('/',[StringComparison]::Ordinal) -or $RelativePath -match '^[A-Za-z]:' -or
        @($RelativePath -split '/'|Where-Object {$_ -in @('', '.', '..')}).Count -gt 0){return $false}
    $rootFull=[IO.Path]::GetFullPath($Root)
    $full=[IO.Path]::GetFullPath((Join-Path $rootFull $RelativePath))
    $back=[IO.Path]::GetRelativePath($rootFull,$full)
    if($back -eq '..' -or $back.StartsWith(('..' + [IO.Path]::DirectorySeparatorChar),[StringComparison]::Ordinal) -or
        [IO.Path]::IsPathRooted($back)){return $false}
    $current=$full
    while($current -ne $rootFull){
        if(Test-Path -LiteralPath $current){
            $item=Get-Item -LiteralPath $current -Force
            if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){return $false}
        }
        $current=[IO.Path]::GetDirectoryName($current)
        if([string]::IsNullOrWhiteSpace($current)){return $false}
    }
    return $true
}
function Resolve-LocalManagedAsset {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$ProjectionId,[Parameter(Mandatory)][object]$Asset)
    if($ProjectionId -cnotmatch '^[a-z][a-z0-9-]{0,49}$' -or $null -eq $Asset){
        return New-AssetResult -Status 'invalid' -Reason 'AssetSchemaInvalid' -Fields $null
    }
    $keys=if($Asset -is [System.Collections.IDictionary]){@($Asset.Keys)}else{@($Asset.PSObject.Properties.Name)}
    if(($keys|Sort-Object)-join ',' -cne 'displayFilename,localPath,mediaType,sha256'){
        return New-AssetResult -Status 'invalid' -Reason 'AssetSchemaInvalid' -Fields $null
    }
    $local=[string](Get-AssetField -Object $Asset -Name 'localPath')
    $display=[string](Get-AssetField -Object $Asset -Name 'displayFilename')
    $media=[string](Get-AssetField -Object $Asset -Name 'mediaType')
    $expected=[string](Get-AssetField -Object $Asset -Name 'sha256')
    $extensions=@{'image/png'='.png';'image/jpeg'='.jpg';'image/gif'='.gif';'application/pdf'='.pdf';'text/plain'='.txt';'application/octet-stream'='.bin'}
    if(-not(Test-Path -LiteralPath $Root -PathType Container) -or -not(Test-AssetRelativePath -Root $Root -RelativePath $local) -or
        $display.Length -lt 1 -or $display.Length -gt 180 -or $display -match '[\\/\x00-\x1f\x7f]' -or
        -not $extensions.ContainsKey($media) -or $expected -cnotmatch '^[a-f0-9]{64}$'){
        return New-AssetResult -Status 'invalid' -Reason 'AssetInputInvalid' -Fields $null
    }
    $full=[IO.Path]::GetFullPath((Join-Path $Root $local))
    if(-not(Test-Path -LiteralPath $full -PathType Leaf)){
        return New-AssetResult -Status 'invalid' -Reason 'AssetSourceUnavailable' -Fields $null
    }
    $length=(Get-Item -LiteralPath $full -Force).Length
    if($length -gt 20MB){return New-AssetResult -Status 'invalid' -Reason 'AssetTooLarge' -Fields $null}
    try{$bytes=[IO.File]::ReadAllBytes($full)}catch{return New-AssetResult -Status 'invalid' -Reason 'AssetSourceUnavailable' -Fields $null}
    $actual=Get-AssetHash -Bytes $bytes
    if($actual -cne $expected){return New-AssetResult -Status 'invalid' -Reason 'AssetSourceChanged' -Fields $null}
    $remote='syp171-' + $ProjectionId + '-' + $actual + [string]$extensions[$media]
    return New-AssetResult -Status 'valid' -Reason '' -Fields ([ordered]@{
        localPath=$local;displayFilename=$display;mediaType=$media;sha256=$actual
        byteLength=$bytes.Length;remoteFilename=$remote;bytes=$bytes
    })
}
function Get-ManagedAttachmentList {
    param([string]$SiteOrigin,[string]$ApiBase,[string]$CloudId,[string]$PageId,[scriptblock]$HttpInvoker)
    return Get-ConfluenceCollection -ExpectedSiteOrigin $SiteOrigin -ConfiguredSiteOrigin $SiteOrigin -ApiBase $ApiBase -CloudId $CloudId -RelativePath ('/wiki/api/v2/pages/' + $PageId + '/attachments?limit=50') -HttpInvoker $HttpInvoker
}
function Get-ManagedAttachmentObservation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SiteOrigin,[Parameter(Mandatory)][string]$ApiBase,
        [Parameter(Mandatory)][string]$CloudId,[Parameter(Mandatory)][string]$PageId,
        [Parameter(Mandatory)][string]$RemoteFilename,[Parameter(Mandatory)][string]$MediaType,
        [Parameter(Mandatory)][string]$Sha256,[Parameter(Mandatory)][int64]$ByteLength,
        [Parameter(Mandatory)][scriptblock]$HttpInvoker,[string]$ExpectedComment='')
    if($PageId -cnotmatch '^[0-9]+$' -or $Sha256 -cnotmatch '^[a-f0-9]{64}$' -or $ByteLength -lt 0 -or $ByteLength -gt 20MB){
        return New-AssetResult -Status 'blocked' -Reason 'AssetObservationInvalid' -Fields $null
    }
    $first=Get-ManagedAttachmentList -SiteOrigin $SiteOrigin -ApiBase $ApiBase -CloudId $CloudId -PageId $PageId -HttpInvoker $HttpInvoker
    if($first.status -cne 'complete'){return New-AssetResult -Status 'blocked' -Reason 'AttachmentReadIncomplete' -Fields $null}
    $matches=@($first.items|Where-Object {[string](Get-AssetField -Object $_ -Name 'title') -ceq $RemoteFilename})
    if($matches.Count -gt 1){return New-AssetResult -Status 'blocked' -Reason 'DuplicateManagedAttachment' -Fields $null}
    $id='';$version=0
    if($matches.Count -eq 1){
        $item=$matches[0]
        $id=[string](Get-AssetField -Object $item -Name 'id')
        $versionRaw=Get-AssetField -Object (Get-AssetField -Object $item -Name 'version') -Name 'number'
        $download=[string](Get-AssetField -Object $item -Name 'downloadLink')
        $expectedDownload="/wiki/rest/api/content/$PageId/child/attachment/$id/download"
        if($id -cnotmatch '^[0-9]+$' -or [string](Get-AssetField -Object $item -Name 'pageId') -cne $PageId -or
            [string](Get-AssetField -Object $item -Name 'status') -cne 'current' -or
            [string](Get-AssetField -Object $item -Name 'mediaType') -cne $MediaType -or
            [int64](Get-AssetField -Object $item -Name 'fileSize') -ne $ByteLength -or
            $null -eq $versionRaw -or [int]$versionRaw -lt 1 -or $download -cne $expectedDownload){
            return New-AssetResult -Status 'blocked' -Reason 'ManagedAttachmentConflict' -Fields $null
        }
        if($ExpectedComment -and [string](Get-AssetField -Object $item -Name 'comment') -cne $ExpectedComment){
            return New-AssetResult -Status 'blocked' -Reason 'AttachmentOperationUnproven' -Fields $null
        }
        $version=[int]$versionRaw
        $request=[pscustomobject]@{Method='GET';Uri="$($ApiBase.TrimEnd('/'))${download}?version=$version";Headers=@{Accept='*/*'};Body=$null;TimeoutSec=30;ResponseLimitBytes=20MB;AuthAllowed=$true}
        try{$response=& $HttpInvoker $request}catch{return New-AssetResult -Status 'blocked' -Reason 'AttachmentDownloadFailed' -Fields $null}
        $bytes=Get-AssetField -Object $response -Name 'BodyBytes'
        if($bytes -isnot [byte[]]){$bytes=Get-AssetField -Object $response -Name 'Body'}
        if([int](Get-AssetField -Object $response -Name 'StatusCode') -ne 200 -or $bytes -isnot [byte[]] -or
            $bytes.Length -ne $ByteLength -or (Get-AssetHash -Bytes $bytes) -cne $Sha256){
            return New-AssetResult -Status 'blocked' -Reason 'ManagedAttachmentConflict' -Fields $null
        }
    }
    $second=Get-ManagedAttachmentList -SiteOrigin $SiteOrigin -ApiBase $ApiBase -CloudId $CloudId -PageId $PageId -HttpInvoker $HttpInvoker
    if($second.status -cne 'complete'){return New-AssetResult -Status 'blocked' -Reason 'AttachmentReadIncomplete' -Fields $null}
    $after=@($second.items|Where-Object {[string](Get-AssetField -Object $_ -Name 'title') -ceq $RemoteFilename})
    if($after.Count -ne $matches.Count -or ($after.Count -eq 1 -and
        ([string](Get-AssetField -Object $after[0] -Name 'id') -cne $id -or
         [int](Get-AssetField -Object (Get-AssetField -Object $after[0] -Name 'version') -Name 'number') -ne $version -or
         ($ExpectedComment -and [string](Get-AssetField -Object $after[0] -Name 'comment') -cne $ExpectedComment)))){
        return New-AssetResult -Status 'blocked' -Reason 'RemoteAttachmentDrift' -Fields $null
    }
    return New-AssetResult -Status 'ready' -Reason '' -Fields ([ordered]@{
        action=$(if($matches.Count -eq 0){'upload'}else{'reuse'});remoteAttachmentId=$id;remoteVersion=$version
    })
}

function New-ManagedAttachmentUploadRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ApiBase,[Parameter(Mandatory)][string]$PageId,
        [Parameter(Mandatory)][object]$Asset,[Parameter(Mandatory)][string]$ProjectionId,[Parameter(Mandatory)][string]$OperationId,
        [Parameter(Mandatory)][byte[]]$Bytes)
    if($PageId -cnotmatch '^[0-9]+$' -or $ProjectionId -cnotmatch '^[a-z][a-z0-9-]{0,49}$' -or $OperationId -cnotmatch '^[a-f0-9]{32}$' -or
        $Bytes.Length -gt 20MB -or $Bytes.Length -ne [int64]$Asset.byteLength -or
        (Get-AssetHash -Bytes $Bytes) -cne [string]$Asset.sha256 -or
        [string]$Asset.remoteFilename -cnotmatch '^syp171-[a-z][a-z0-9-]{0,49}-[a-f0-9]{64}\.(png|jpg|gif|pdf|txt|bin)$'){
        throw 'UnsafeAttachmentUploadInput'
    }
    $comment=('SYP171:' + [string](${OperationId}) + ':' + [string](${ProjectionId}) + ':' + [string]($($Asset.sha256)))
    $multipart=[Net.Http.MultipartFormDataContent]::new()
    try{
        $file=[Net.Http.ByteArrayContent]::new($Bytes)
        $file.Headers.ContentType=[Net.Http.Headers.MediaTypeHeaderValue]::Parse([string]$Asset.mediaType)
        $multipart.Add($file,'file',[string]$Asset.remoteFilename)
        $multipart.Add([Net.Http.StringContent]::new($comment,[Text.Encoding]::UTF8),'comment')
        $multipart.Add([Net.Http.StringContent]::new('true',[Text.Encoding]::UTF8),'minorEdit')
        $contentType=$multipart.Headers.ContentType.ToString()
        $body=$multipart.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        if($body.Length -gt 20MB+64KB){throw 'AttachmentMultipartTooLarge'}
        return [pscustomobject]@{
            Method='POST';Uri="$($ApiBase.TrimEnd('/'))/wiki/rest/api/content/$PageId/child/attachment"
            Headers=@{Accept='application/json';'Content-Type'=$contentType;'X-Atlassian-Token'='nocheck'}
            BodyBytes=$body;Body=$null;TimeoutSec=30;ResponseLimitBytes=4MB;AuthAllowed=$true;Comment=$comment
        }
    }finally{$multipart.Dispose()}
}

Export-ModuleMember -Function Resolve-LocalManagedAsset,Get-ManagedAttachmentObservation,Get-AssetHash,New-ManagedAttachmentUploadRequest
