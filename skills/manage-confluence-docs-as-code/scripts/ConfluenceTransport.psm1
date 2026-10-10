# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest

function New-CollectionResult {
    param([string] $Status, [string[]] $ReasonCodes, [object[]] $Items, [int] $Responses)
    return [pscustomobject]@{
        status = $Status
        reasonCodes = @($ReasonCodes)
        items = @($Items)
        responses = $Responses
    }
}

function Get-EnvelopeValue {
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

function Test-ConfluenceTenant {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ExpectedSiteOrigin,
        [Parameter(Mandatory)][string] $ConfiguredSiteOrigin,
        [Parameter(Mandatory)][string] $ApiBase,
        [Parameter(Mandatory)][string] $CloudId
    )
    $expected = $null
    $configured = $null
    $base = $null
    if (-not [Uri]::TryCreate($ExpectedSiteOrigin, [UriKind]::Absolute, [ref] $expected) -or
        -not [Uri]::TryCreate($ConfiguredSiteOrigin, [UriKind]::Absolute, [ref] $configured) -or
        -not [Uri]::TryCreate($ApiBase, [UriKind]::Absolute, [ref] $base)) {
        return 'TenantMismatch'
    }
    if ($expected.Scheme -cne 'https' -or $configured.Scheme -cne 'https' -or
        $expected.GetLeftPart([UriPartial]::Authority) -cne $ExpectedSiteOrigin.TrimEnd('/') -or
        $configured.GetLeftPart([UriPartial]::Authority) -cne $ConfiguredSiteOrigin.TrimEnd('/') -or
        $expected.GetLeftPart([UriPartial]::Authority) -cne $configured.GetLeftPart([UriPartial]::Authority)) {
        return 'TenantMismatch'
    }
    $parsedCloudId = [Guid]::Empty
    if (-not [Guid]::TryParse($CloudId, [ref] $parsedCloudId) -or
        $base.AbsoluteUri.TrimEnd('/') -cne "https://api.atlassian.com/ex/confluence/$CloudId") {
        return 'ApiBaseMismatch'
    }
    return $null
}

function Test-ConfluenceSelectedSessionAccess {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object] $Access)

    $ready = Get-EnvelopeValue -Object $Access -Name 'ReadyForRead'
    $reload = Get-EnvelopeValue -Object $Access -Name 'HostReloadRequired'
    if ($ready -isnot [bool] -or -not $ready -or $reload -isnot [bool] -or
        [string](Get-EnvelopeValue -Object $Access -Name 'ConfigurationState') -cne 'valid' -or
        [string](Get-EnvelopeValue -Object $Access -Name 'TenantIdentityState') -cne 'match' -or
        [string](Get-EnvelopeValue -Object (Get-EnvelopeValue -Object $Access -Name 'SpaceReadCheck') -Name 'Category') -cne 'success' -or
        [string](Get-EnvelopeValue -Object (Get-EnvelopeValue -Object $Access -Name 'PageReadCheck') -Name 'Category') -cne 'success') {
        return $false
    }
    $hostState = [string](Get-EnvelopeValue -Object $Access -Name 'HostEnvironmentState')
    if ($hostState -ceq 'process-ready') { return -not $reload }
    if ($hostState -cne 'process-user-mismatch' -or -not $reload) { return $false }
    $missing = Get-EnvelopeValue -Object $Access -Name 'MissingProcessSettings'
    $conflicts = Get-EnvelopeValue -Object $Access -Name 'ScopeConflictSettings'
    return $missing -is [array] -and $missing.Count -eq 0 -and
        $conflicts -is [array] -and $conflicts.Count -gt 0
}

function Resolve-ConfluenceNextUri {
    param([string] $Next, [string] $ApiBase, [Uri] $CurrentUri)
    if ([string]::IsNullOrWhiteSpace($Next)) { return $null }
    $target = $null
    if ($Next.StartsWith('/wiki/api/v2/', [StringComparison]::Ordinal)) {
        $target = [Uri]::new(($ApiBase.TrimEnd('/') + $Next))
    } elseif ($Next.StartsWith('?', [StringComparison]::Ordinal)) {
        $target = [Uri]::new(($CurrentUri.GetLeftPart([UriPartial]::Path) + $Next))
    } elseif (-not [Uri]::TryCreate($Next, [UriKind]::Absolute, [ref] $target)) {
        return $null
    }
    $expectedPrefix = $ApiBase.TrimEnd('/') + '/wiki/api/v2/'
    if ($target.Scheme -cne 'https' -or $target.UserInfo -or $target.Fragment -or
        -not $target.AbsoluteUri.StartsWith($expectedPrefix, [StringComparison]::Ordinal)) {
        return $null
    }
    return $target
}

function Get-NextFromLinkHeader {
    param([object] $Headers)
    $link = [string] (Get-EnvelopeValue -Object $Headers -Name 'Link')
    if ([string]::IsNullOrWhiteSpace($link)) { return $null }
    foreach ($part in ($link -split ',')) {
        if ($part -match '<(?<url>[^>]+)>\s*;\s*rel="?next"?') { return $Matches['url'] }
    }
    return $null
}

function Get-ConfluenceCollection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ExpectedSiteOrigin,
        [Parameter(Mandatory)][string] $ConfiguredSiteOrigin,
        [Parameter(Mandatory)][string] $ApiBase,
        [Parameter(Mandatory)][string] $CloudId,
        [Parameter(Mandatory)][string] $RelativePath,
        [Parameter(Mandatory)][scriptblock] $HttpInvoker,
        [ValidateRange(1, 1000)][int] $MaxResponses = 1000
    )
    $tenantError = Test-ConfluenceTenant -ExpectedSiteOrigin $ExpectedSiteOrigin -ConfiguredSiteOrigin $ConfiguredSiteOrigin -ApiBase $ApiBase -CloudId $CloudId
    if ($null -ne $tenantError) { return New-CollectionResult -Status 'blocked' -ReasonCodes @($tenantError) -Items @() -Responses 0 }
    if (-not $RelativePath.StartsWith('/wiki/api/v2/', [StringComparison]::Ordinal)) {
        return New-CollectionResult -Status 'blocked' -ReasonCodes @('UnsafeInitialPath') -Items @() -Responses 0
    }
    $current = Resolve-ConfluenceNextUri -Next $RelativePath -ApiBase $ApiBase -CurrentUri $null
    if ($null -eq $current) { return New-CollectionResult -Status 'blocked' -ReasonCodes @('UnsafeInitialPath') -Items @() -Responses 0 }

    $visited = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $seenIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $items = [System.Collections.Generic.List[object]]::new()
    $responses = 0
    while ($null -ne $current) {
        if ($responses -ge $MaxResponses) { return New-CollectionResult -Status 'partial' -ReasonCodes @('PaginationLimit') -Items $items.ToArray() -Responses $responses }
        if (-not $visited.Add($current.AbsoluteUri)) { return New-CollectionResult -Status 'partial' -ReasonCodes @('PaginationLoop') -Items $items.ToArray() -Responses $responses }
        $request = [pscustomobject]@{
            Method = 'GET'; Uri = $current.AbsoluteUri; Headers = @{ Accept = 'application/json' }
            Body = $null; TimeoutSec = 30; ResponseLimitBytes = 4MB; AuthAllowed = $true
        }
        try { $response = & $HttpInvoker $request }
        catch { return New-CollectionResult -Status 'partial' -ReasonCodes @('RemoteReadFailed') -Items $items.ToArray() -Responses $responses }
        $responses++
        $code = [int] (Get-EnvelopeValue -Object $response -Name 'StatusCode')
        if ($code -ne 200) {
            $reason = switch ($code) {
                401 { 'RemoteAuthenticationFailed' }
                403 { 'RemoteReadDenied' }
                404 { 'RemoteReadUnavailable' }
                429 { 'RemoteRateLimited' }
                default { 'RemoteReadFailed' }
            }
            return New-CollectionResult -Status 'partial' -ReasonCodes @($reason) -Items $items.ToArray() -Responses $responses
        }
        $body = Get-EnvelopeValue -Object $response -Name 'Body'
        if ($body -is [byte[]]) {
            if ($body.Length -gt 4MB) { return New-CollectionResult -Status 'partial' -ReasonCodes @('ResponseTooLarge') -Items $items.ToArray() -Responses $responses }
            try { $body = [Text.Encoding]::UTF8.GetString($body) | ConvertFrom-Json -AsHashtable -Depth 30 }
            catch { return New-CollectionResult -Status 'partial' -ReasonCodes @('ResponseInvalid') -Items $items.ToArray() -Responses $responses }
        }
        $results = Get-EnvelopeValue -Object $body -Name 'results'
        if ($null -eq $results) { return New-CollectionResult -Status 'partial' -ReasonCodes @('ResponseInvalid') -Items $items.ToArray() -Responses $responses }
        foreach ($item in @($results)) {
            $id = [string] (Get-EnvelopeValue -Object $item -Name 'id')
            if ([string]::IsNullOrWhiteSpace($id)) { return New-CollectionResult -Status 'partial' -ReasonCodes @('RemoteIdMissing') -Items $items.ToArray() -Responses $responses }
            if (-not $seenIds.Add($id)) { return New-CollectionResult -Status 'partial' -ReasonCodes @('DuplicateRemoteId') -Items $items.ToArray() -Responses $responses }
            $items.Add($item)
        }
        $links = Get-EnvelopeValue -Object $body -Name '_links'
        $bodyNext = [string] (Get-EnvelopeValue -Object $links -Name 'next')
        $headerNext = Get-NextFromLinkHeader -Headers (Get-EnvelopeValue -Object $response -Name 'Headers')
        if (-not [string]::IsNullOrWhiteSpace($bodyNext) -and -not [string]::IsNullOrWhiteSpace($headerNext)) {
            $bodyUri = Resolve-ConfluenceNextUri -Next $bodyNext -ApiBase $ApiBase -CurrentUri $current
            $headerUri = Resolve-ConfluenceNextUri -Next $headerNext -ApiBase $ApiBase -CurrentUri $current
            if ($null -eq $bodyUri -or $null -eq $headerUri -or $bodyUri.AbsoluteUri -cne $headerUri.AbsoluteUri) {
                return New-CollectionResult -Status 'partial' -ReasonCodes @('PaginationInconsistent') -Items $items.ToArray() -Responses $responses
            }
        }
        $next = if (-not [string]::IsNullOrWhiteSpace($headerNext)) { $headerNext } else { $bodyNext }
        if ([string]::IsNullOrWhiteSpace($next)) { $current = $null; continue }
        $current = Resolve-ConfluenceNextUri -Next $next -ApiBase $ApiBase -CurrentUri $current
        if ($null -eq $current) { return New-CollectionResult -Status 'partial' -ReasonCodes @('UnsafePaginationTarget') -Items $items.ToArray() -Responses $responses }
    }
    return New-CollectionResult -Status 'complete' -ReasonCodes @() -Items $items.ToArray() -Responses $responses
}

function Invoke-ConfluenceWireRead {
    param([object] $Request)
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $method = [string] $Request.Method
    if ($method -notin @('GET','PUT','POST')) { throw 'WireMethodUnsupported' }
    $message = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($method), [Uri] $Request.Uri)
    $timeout = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds([int] $Request.TimeoutSec))
    $response = $null
    $stream = $null
    $memory = [IO.MemoryStream]::new()
    $bodyBytes = $null
    try {
        if (-not [string]::IsNullOrEmpty([string] $Request.Authorization)) {
            $message.Headers.TryAddWithoutValidation('Authorization', [string] $Request.Authorization) | Out-Null
        }
        $accept = [string] $Request.Headers.Accept
        if (-not [string]::IsNullOrWhiteSpace($accept)) { $message.Headers.TryAddWithoutValidation('Accept', $accept) | Out-Null }
        $atlassianToken = [string] $Request.Headers['X-Atlassian-Token']
        if (-not [string]::IsNullOrWhiteSpace($atlassianToken)) {
            $message.Headers.TryAddWithoutValidation('X-Atlassian-Token', $atlassianToken) | Out-Null
        }
        if ($method -ne 'GET') {
            $bodyBytes = if($null -ne $Request.PSObject.Properties['BodyBytes'] -and $Request.BodyBytes -is [byte[]]){[byte[]]$Request.BodyBytes.Clone()}else{
                [Text.Encoding]::UTF8.GetBytes([string] $Request.Body)
            }
            $message.Content = [Net.Http.ByteArrayContent]::new($bodyBytes)
            $contentType = [string] $Request.Headers['Content-Type']
            if (-not [string]::IsNullOrWhiteSpace($contentType)) {
                $message.Content.Headers.TryAddWithoutValidation('Content-Type', $contentType) | Out-Null
            }
        }
        $response = $client.SendAsync($message, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $timeout.Token).GetAwaiter().GetResult()
        $headers = @{}
        foreach ($header in $response.Headers) { $headers[$header.Key] = ($header.Value -join ',') }
        $stream = $response.Content.ReadAsStreamAsync($timeout.Token).GetAwaiter().GetResult()
        $buffer = [byte[]]::new(8192)
        while ($true) {
            $count = $stream.ReadAsync($buffer.AsMemory(), $timeout.Token).GetAwaiter().GetResult()
            if ($count -eq 0) { break }
            if ($memory.Length + $count -gt [int64] $Request.ResponseLimitBytes) { throw 'ResponseLimitExceeded' }
            $memory.Write($buffer, 0, $count)
        }
        return [pscustomobject]@{ StatusCode = [int] $response.StatusCode; Headers = $headers; BodyBytes = $memory.ToArray() }
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        $memory.Dispose(); if ($null -ne $response) { $response.Dispose() }
        $timeout.Dispose(); $message.Dispose(); $client.Dispose(); $handler.Dispose()
        if ($null -ne $bodyBytes) { [Array]::Clear($bodyBytes) }
    }
}

function Test-SignedDownloadUri {
    param([string] $Location)
    $uri = $null
    if (-not [Uri]::TryCreate($Location, [UriKind]::Absolute, [ref] $uri)) { return $false }
    $parsedIp = $null
    $host = $uri.DnsSafeHost.ToLowerInvariant()
    return $uri.Scheme -ceq 'https' -and [string]::IsNullOrEmpty($uri.UserInfo) -and
        [string]::IsNullOrEmpty($uri.Fragment) -and -not [Net.IPAddress]::TryParse($host, [ref] $parsedIp) -and
        $host -cne 'localhost' -and -not $host.EndsWith('.local', [StringComparison]::Ordinal) -and
        -not $host.EndsWith('.internal', [StringComparison]::Ordinal)
}

function New-ConfluenceReadInvoker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ExpectedSiteOrigin,
        [Parameter(Mandatory)][string] $ConfiguredSiteOrigin,
        [Parameter(Mandatory)][string] $ApiBase,
        [Parameter(Mandatory)][string] $CloudId,
        [Parameter(Mandatory)][string] $Email,
        [Parameter(Mandatory)][string] $Token,
        [scriptblock] $WireInvoker
    )
    $tenantError = Test-ConfluenceTenant -ExpectedSiteOrigin $ExpectedSiteOrigin -ConfiguredSiteOrigin $ConfiguredSiteOrigin -ApiBase $ApiBase -CloudId $CloudId
    if ($null -ne $tenantError) { throw $tenantError }
    if ([string]::IsNullOrWhiteSpace($Email) -or [string]::IsNullOrWhiteSpace($Token)) { throw 'CredentialUnavailable' }
    if ($null -eq $WireInvoker) { $WireInvoker = ${function:Invoke-ConfluenceWireRead} }
    $getValue = ${function:Get-EnvelopeValue}
    $testSignedUri = ${function:Test-SignedDownloadUri}
    $apiPrefix = $ApiBase.TrimEnd('/') + '/wiki/'
    $credentialBytes = [Text.Encoding]::UTF8.GetBytes("${Email}:${Token}")
    $authorization = 'Basic ' + [Convert]::ToBase64String($credentialBytes)
    [Array]::Clear($credentialBytes)
    return {
        param($Request)
        $method = [string] (& $getValue -Object $Request -Name 'Method')
        $uriText = [string] (& $getValue -Object $Request -Name 'Uri')
        $uri = $null
        if ($method -cne 'GET' -or -not [Uri]::TryCreate($uriText, [UriKind]::Absolute, [ref] $uri) -or
            $uri.Scheme -cne 'https' -or $uri.UserInfo -or $uri.Fragment -or
            -not $uri.AbsoluteUri.StartsWith($apiPrefix, [StringComparison]::Ordinal)) { throw 'UnsafeReadRequest' }
        $limit = [int64] (& $getValue -Object $Request -Name 'ResponseLimitBytes')
        $timeout = [int] (& $getValue -Object $Request -Name 'TimeoutSec')
        if ($limit -lt 1 -or $limit -gt 20MB -or $timeout -lt 1 -or $timeout -gt 30) { throw 'UnsafeReadLimits' }
        $first = [pscustomobject]@{
            Method = 'GET'; Uri = $uri.AbsoluteUri; Headers = (& $getValue -Object $Request -Name 'Headers')
            TimeoutSec = $timeout; ResponseLimitBytes = $limit; AuthAllowed = $true; Authorization = $authorization
        }
        $response = & $WireInvoker $first
        $status = [int] (& $getValue -Object $response -Name 'StatusCode')
        if ($status -eq 302) {
            if ($uri.AbsolutePath -cnotmatch '/wiki/rest/api/content/[0-9]+/child/attachment/[0-9]+/download$') { throw 'UnexpectedRedirect' }
            $location = [string] (& $getValue -Object (& $getValue -Object $response -Name 'Headers') -Name 'Location')
            if (-not (& $testSignedUri -Location $location)) { throw 'UnsafeAttachmentRedirect' }
            $second = [pscustomobject]@{
                Method = 'GET'; Uri = $location; Headers = @{ Accept = '*/*' }
                TimeoutSec = $timeout; ResponseLimitBytes = $limit; AuthAllowed = $false; Authorization = $null
            }
            $response = & $WireInvoker $second
            if ([int] (& $getValue -Object $response -Name 'StatusCode') -eq 302) { throw 'NestedAttachmentRedirect' }
        }
        $bytes = & $getValue -Object $response -Name 'BodyBytes'
        if ($bytes -is [byte[]] -and $bytes.Length -gt $limit) { throw 'ResponseLimitExceeded' }
        return [pscustomobject]@{
            StatusCode = [int] (& $getValue -Object $response -Name 'StatusCode')
            Headers = (& $getValue -Object $response -Name 'Headers')
            BodyBytes = $bytes; Body = $bytes
        }
    }.GetNewClosure()
}

function New-ConfluenceOperationInvoker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ExpectedSiteOrigin,
        [Parameter(Mandatory)][string] $ConfiguredSiteOrigin,
        [Parameter(Mandatory)][string] $ApiBase,
        [Parameter(Mandatory)][string] $CloudId,
        [Parameter(Mandatory)][string] $Email,
        [Parameter(Mandatory)][string] $Token,
        [scriptblock] $WireInvoker
    )
    $tenantError = Test-ConfluenceTenant -ExpectedSiteOrigin $ExpectedSiteOrigin -ConfiguredSiteOrigin $ConfiguredSiteOrigin -ApiBase $ApiBase -CloudId $CloudId
    if ($null -ne $tenantError) { throw $tenantError }
    if ([string]::IsNullOrWhiteSpace($Email) -or [string]::IsNullOrWhiteSpace($Token)) { throw 'CredentialUnavailable' }
    if ($null -eq $WireInvoker) { $WireInvoker = ${function:Invoke-ConfluenceWireRead} }
    $readInvoker = New-ConfluenceReadInvoker -ExpectedSiteOrigin $ExpectedSiteOrigin -ConfiguredSiteOrigin $ConfiguredSiteOrigin          -ApiBase $ApiBase -CloudId $CloudId -Email $Email -Token $Token -WireInvoker $WireInvoker
    $getValue = ${function:Get-EnvelopeValue}
    $credentialBytes = [Text.Encoding]::UTF8.GetBytes("${Email}:${Token}")
    $authorization = 'Basic ' + [Convert]::ToBase64String($credentialBytes)
    [Array]::Clear($credentialBytes)
    $apiPrefix = "$($ApiBase.TrimEnd('/'))/wiki/api/v2/pages"
    $attachmentPrefix = "$($ApiBase.TrimEnd('/'))/wiki/rest/api/content"
    return {
        param($Request)
        $method = [string] (& $getValue -Object $Request -Name 'Method')
        if ($method -ceq 'GET') { return & $readInvoker $Request }
        $uri = $null
        $uriText = [string] (& $getValue -Object $Request -Name 'Uri')
        if ($method -notin @('PUT','POST') -or -not [Uri]::TryCreate($uriText, [UriKind]::Absolute, [ref] $uri) -or
            $uri.Scheme -cne 'https' -or $uri.UserInfo -or $uri.Fragment -or $uri.Query -or
            (($method -ceq 'PUT' -and $uri.AbsoluteUri -cnotmatch "^$([regex]::Escape($apiPrefix))/[0-9]+$") -or
             ($method -ceq 'POST' -and $uri.AbsoluteUri -cne $apiPrefix -and
              $uri.AbsoluteUri -cnotmatch "^$([regex]::Escape($attachmentPrefix))/[0-9]+/child/attachment$"))) { throw 'UnsafeWriteRequest' }
        $attachmentPost=$method -ceq 'POST' -and $uri.AbsoluteUri -cne $apiPrefix
        $headers=& $getValue -Object $Request -Name 'Headers'
        $raw=& $getValue -Object $Request -Name 'BodyBytes'
        if($attachmentPost){
            if($raw -isnot [byte[]] -or $raw.Length -lt 1 -or $raw.Length -gt 20MB+64KB -or
                [string](& $getValue -Object $headers -Name 'X-Atlassian-Token') -cne 'nocheck' -or
                [string](& $getValue -Object $headers -Name 'Content-Type') -cnotmatch '^multipart/form-data; boundary=(?:[A-Za-z0-9-]{1,70}|"[A-Za-z0-9-]{1,70}")$' -or
                $null -ne (& $getValue -Object $Request -Name 'Body')) {throw 'UnsafeAttachmentWrite'}
        }elseif($raw -is [byte[]]){throw 'UnexpectedBinaryWrite'}
        $body = [string] (& $getValue -Object $Request -Name 'Body')
        $limit = [int64] (& $getValue -Object $Request -Name 'ResponseLimitBytes')
        $timeout = [int] (& $getValue -Object $Request -Name 'TimeoutSec')
        if ((-not $attachmentPost -and [Text.Encoding]::UTF8.GetByteCount($body) -gt 4MB) -or $limit -lt 1 -or $limit -gt 4MB -or
            $timeout -lt 1 -or $timeout -gt 30 -or -not [bool] (& $getValue -Object $Request -Name 'AuthAllowed')) { throw 'UnsafeWriteLimits' }
        $wireRequest = [pscustomobject]@{
            Method = $method; Uri = $uri.AbsoluteUri; Headers = $headers
            Body = $(if($attachmentPost){$null}else{$body});BodyBytes=$null
            TimeoutSec = $timeout; ResponseLimitBytes = $limit
            AuthAllowed = $true; Authorization = $authorization
        }
        if($attachmentPost){$wireRequest.BodyBytes=[byte[]]$raw}
        $response = & $WireInvoker $wireRequest
        $status = [int] (& $getValue -Object $response -Name 'StatusCode')
        if ($status -eq 302 -or $status -eq 301 -or $status -eq 307 -or $status -eq 308) { throw 'WriteRedirected' }
        $bytes = & $getValue -Object $response -Name 'BodyBytes'
        if ($bytes -is [byte[]] -and $bytes.Length -gt $limit) { throw 'ResponseLimitExceeded' }
        return [pscustomobject]@{
            StatusCode = $status; Headers = (& $getValue -Object $response -Name 'Headers')
            BodyBytes = $bytes; Body = $bytes
        }
    }.GetNewClosure()
}

Export-ModuleMember -Function Test-ConfluenceTenant, Test-ConfluenceSelectedSessionAccess, Get-ConfluenceCollection, New-ConfluenceReadInvoker, New-ConfluenceOperationInvoker
