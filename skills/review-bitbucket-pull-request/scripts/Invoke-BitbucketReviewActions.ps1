# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $PlanPath,
    [string] $ReceiptPath,
    [switch] $Apply,
    [switch] $LocalOnly,
    [ValidateSet('None', 'Publish', 'Iterative')][string] $AuthorizationMode = 'None',
    [string] $AuthorizedTarget,
    [string[]] $AuthorizedActionIds = @(),
    [long[]] $IncludedRootCommentIds = @(),
    [string] $ContextPath,
    [switch] $ReadContext,
    [scriptblock] $EnvironmentReader,
    [scriptblock] $HttpInvoker,
    [scriptblock] $DelayInvoker,
    [switch] $AsObject
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Stop-Review {
    param([string] $Code)
    $exception = [InvalidOperationException]::new($Code)
    $exception.Data['ReviewError'] = $Code
    throw $exception
}

function Get-Field {
    param($Object, [string] $Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            if ($Object[$Name] -is [array]) { return ,$Object[$Name] }
            return $Object[$Name]
        }
    }
    elseif ($null -ne $Object.PSObject.Properties[$Name]) {
        if ($Object.$Name -is [array]) { return ,$Object.$Name }
        return $Object.$Name
    }
    return $Default
}

function Get-Digest {
    param([string] $Text)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))) -replace '-', '').ToLowerInvariant() }
    finally { $hasher.Dispose() }
}

function Read-ReviewJson {
    param([string] $Path)
    try {
        $text = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false, $true))
        $value = $text | ConvertFrom-Json
        # ConvertFrom-Json can silently replace duplicate properties on older hosts.
        # Tokenize strings atomically, decode property names, and check each object.
        $tokens = [regex]::Matches($text, '"(?:[^"\\]|\\.)*"|[{}\[\]:,]|[^\s{}\[\]:,]+')
        $objects = [Collections.Generic.Stack[Collections.Generic.HashSet[string]]]::new()
        for ($index = 0; $index -lt $tokens.Count; $index++) {
            $token = $tokens[$index].Value
            if ($token -ceq '{') { $objects.Push([Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)) }
            elseif ($token -ceq '}') { [void]$objects.Pop() }
            elseif ($token.StartsWith('"') -and $index + 1 -lt $tokens.Count -and $tokens[$index + 1].Value -ceq ':') {
                $name = [string]($token | ConvertFrom-Json)
                if (-not $objects.Peek().Add($name)) { Stop-Review 'duplicate-json-property' }
            }
        }
        return $value
    }
    catch { Stop-Review 'invalid-json' }
}

function Assert-Fields {
    param($Object, [string[]] $Required, [string[]] $Optional = @())
    if ($Object -isnot [pscustomobject]) { Stop-Review 'invalid-shape' }
    $names = @($Object.PSObject.Properties.Name)
    foreach ($name in $Required) { if ($names -cnotcontains $name) { Stop-Review 'missing-field' } }
    foreach ($name in $names) { if (@($Required + $Optional) -cnotcontains $name) { Stop-Review 'unknown-field' } }
}

function Assert-Id {
    param($Value)
    if ($Value -isnot [string] -or $Value -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,95}$') { Stop-Review 'invalid-id' }
}

function Assert-Commit {
    param($Value)
    if ($Value -isnot [string] -or $Value -cnotmatch '^[0-9a-f]{40}$') { Stop-Review 'invalid-commit' }
}

function Assert-PositiveInteger {
    param($Value)
    if ($Value -isnot [int] -and $Value -isnot [long]) { Stop-Review 'invalid-integer' }
    if ($Value -le 0) { Stop-Review 'invalid-integer' }
}

function Assert-Inline {
    param($Inline)
    if ($null -eq $Inline) { return }
    Assert-Fields $Inline @('path') @('from', 'to', 'start_from', 'start_to')
    if ($Inline.path -isnot [string] -or [string]::IsNullOrWhiteSpace($Inline.path) -or $Inline.path -match '(^/|\\|(^|/)\.\.(/|$)|[\r\n])') { Stop-Review 'invalid-inline' }
    $side = if ($Inline.PSObject.Properties['to']) { 'to' } else { 'from' }
    $other = if ($side -ceq 'to') { 'from' } else { 'to' }
    if (-not $Inline.PSObject.Properties[$side] -or $Inline.PSObject.Properties[$other] -or $Inline.PSObject.Properties["start_$other"]) { Stop-Review 'invalid-inline' }
    Assert-PositiveInteger $Inline.$side
    if ($Inline.PSObject.Properties["start_$side"]) {
        Assert-PositiveInteger $Inline."start_$side"
        if ($Inline."start_$side" -gt $Inline.$side) { Stop-Review 'invalid-inline' }
    }
}

function Assert-Plan {
    param($Value)
    Assert-Fields $Value @('schemaVersion', 'workspace', 'repository', 'pullRequestId', 'sourceCommit', 'destinationCommit', 'review', 'actions')
    if ($Value.schemaVersion -ne 1 -or $Value.actions -isnot [array]) { Stop-Review 'invalid-plan' }
    foreach ($slug in @($Value.workspace, $Value.repository)) {
        Assert-Id $slug
        if ($slug -in @('.', '..')) { Stop-Review 'invalid-target' }
    }
    Assert-PositiveInteger $Value.pullRequestId
    Assert-Commit $Value.sourceCommit; Assert-Commit $Value.destinationCommit
    Assert-Fields $Value.review @('completeLocalDiff', 'validationComplete', 'evidence')
    if ($Value.review.completeLocalDiff -isnot [bool] -or $Value.review.validationComplete -isnot [bool] -or $Value.review.evidence -isnot [string]) { Stop-Review 'invalid-review' }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($action in $Value.actions) {
        Assert-Fields $action @('id', 'findingId', 'type', 'assessment', 'evidence') @('content', 'commentId', 'inline', 'newEvidence', 'verifiedInPr')
        Assert-Id $action.id; Assert-Id $action.findingId
        if (-not $ids.Add($action.id)) { Stop-Review 'duplicate-action' }
        if ($action.type -cnotin @('Create', 'Reply', 'Resolve') -or $action.assessment -cnotin @('new', 'fixed', 'still-present', 'insufficient', 'local-only')) { Stop-Review 'invalid-action' }
        if ($action.evidence -isnot [string] -or [string]::IsNullOrWhiteSpace($action.evidence)) { Stop-Review 'missing-evidence' }
        if ($action.type -ceq 'Create') {
            if ($action.assessment -cne 'new' -or $action.PSObject.Properties['commentId']) { Stop-Review 'invalid-create' }
            Assert-Inline (Get-Field $action 'inline')
        }
        else {
            Assert-PositiveInteger (Get-Field $action 'commentId')
            if ($action.PSObject.Properties['inline']) { Stop-Review 'invalid-reply-inline' }
        }
        if ($action.type -cne 'Resolve') {
            if ((Get-Field $action 'content') -isnot [string] -or [string]::IsNullOrWhiteSpace($action.content)) { Stop-Review 'missing-content' }
        }
        foreach ($flag in @('newEvidence', 'verifiedInPr')) {
            if ($action.PSObject.Properties[$flag] -and $action.$flag -isnot [bool]) { Stop-Review 'invalid-flag' }
        }
    }
}

function Assert-LocalDataPath {
    param([string] $Path)
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $cursor = $full
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Stop-Review 'unsafe-data-path' }
        }
        $parent = Split-Path -Parent $cursor
        if ($parent -ceq $cursor) { break }; $cursor = $parent
    }
    $directory = Split-Path -Parent $full
    while (-not (Test-Path -LiteralPath $directory -PathType Container)) { $directory = Split-Path -Parent $directory }
    # Probing .git/admin or an external data directory can legitimately fail.
    # PS5 turns native stderr into a terminating error under Stop, even with 2>$null.
    $probe = & {
        $ErrorActionPreference = 'Continue'
        $PSNativeCommandUseErrorActionPreference = $false
        $output = @(& git -C $directory rev-parse --show-toplevel 2>$null)
        [pscustomobject]@{ output = $output; exitCode = $LASTEXITCODE }
    }
    if ($probe.exitCode -eq 0) {
        if ($probe.output.Count -ne 1) { Stop-Review 'invalid-git-root' }
        $root = [string]$probe.output[0]
        $relative = $full.Substring(([IO.Path]::GetFullPath([string]$root)).TrimEnd('\', '/').Length + 1).Replace('\', '/')
        $tracked = @(& git -C $root ls-files -- $relative 2>$null)
        if ($tracked.Count -gt 0) { Stop-Review 'tracked-data-path' }
        & git -C $root check-ignore --quiet -- $relative
        if ($LASTEXITCODE -ne 0) { Stop-Review 'data-path-must-be-ignored' }
    }
    return $full
}

function Save-Receipt {
    $json = $script:Receipt | ConvertTo-Json -Depth 15 -Compress
    $temporary = $script:ReceiptFile + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $script:ReceiptFile) { [IO.File]::Replace($temporary, $script:ReceiptFile, [System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temporary, $script:ReceiptFile) }
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

function Assert-Receipt {
    param($Value)
    Assert-Fields $Value @('schemaVersion', 'target', 'records')
    if ($Value.schemaVersion -ne 1 -or $Value.target -cne $script:Target -or $Value.records -isnot [array]) { Stop-Review 'invalid-receipt' }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($record in $Value.records) {
        Assert-Fields $record @('actionId', 'findingId', 'type', 'sourceCommit', 'destinationCommit', 'requestSha256', 'payloadSha256', 'commentId', 'rootCommentId', 'status')
        Assert-Id $record.actionId; Assert-Id $record.findingId
        if (-not $ids.Add($record.actionId)) { Stop-Review 'invalid-receipt' }
        Assert-Commit $record.sourceCommit; Assert-Commit $record.destinationCommit
        foreach ($digest in @($record.requestSha256, $record.payloadSha256)) { if ($digest -isnot [string] -or $digest -cnotmatch '^[0-9a-f]{64}$') { Stop-Review 'invalid-receipt' } }
        if ($record.type -cnotin @('Create', 'Reply', 'Resolve') -or $record.status -cnotin @('pending', 'succeeded', 'uncertain', 'failed')) { Stop-Review 'invalid-receipt' }
        foreach ($id in @($record.commentId, $record.rootCommentId)) { if ($null -ne $id) { Assert-PositiveInteger $id } }
        if ($record.status -ceq 'succeeded' -and ($null -eq $record.commentId -or $null -eq $record.rootCommentId)) { Stop-Review 'invalid-receipt' }
        if ($record.type -ceq 'Create' -and $null -ne $record.commentId -and $record.commentId -ne $record.rootCommentId) { Stop-Review 'invalid-receipt' }
    }
}

function Assert-ApiUri {
    param([string] $Url, [string] $Path)
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -cne 'api.bitbucket.org' -or $uri.Port -ne 443 -or $uri.UserInfo -or $uri.Fragment -or $uri.AbsolutePath -cne $Path) { Stop-Review 'unsafe-api-url' }
    return $uri
}

function Invoke-Api {
    param([string] $Method, [string] $Url, $Body = $null, [string] $ExpectedPath)
    $uri = Assert-ApiUri $Url $ExpectedPath
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        try { $response = & $HttpInvoker $Method $uri $script:Headers $Body }
        catch { Stop-Review 'transport-uncertain' }
        $status = [int](Get-Field $response 'StatusCode' 0)
        if ($status -eq 429 -and $Method -ceq 'GET' -and $attempt -lt 2) {
            $retry = Get-Field (Get-Field $response 'Headers') 'Retry-After' '1'
            $seconds = 1
            if ([int]::TryParse([string]$retry, [ref]$seconds)) { $seconds = [Math]::Min(5, [Math]::Max(0, $seconds)) } else { $seconds = 1 }
            & $DelayInvoker $seconds
            continue
        }
        if ($status -lt 200 -or $status -ge 300) { Stop-Review "http-$status" }
        $content = Get-Field $response 'Content'
        if ($content -is [string]) {
            try { return $content | ConvertFrom-Json } catch { Stop-Review 'invalid-api-json' }
        }
        return $content
    }
}

function Get-Pages {
    param([string] $Suffix)
    $path = $script:PrPath + $Suffix
    $url = 'https://api.bitbucket.org' + $path
    $visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $values = [Collections.ArrayList]::new()
    while ($url) {
        if (-not $visited.Add($url)) { Stop-Review 'pagination-cycle' }
        $page = Invoke-Api 'GET' $url $null $path
        $items = Get-Field $page 'values'
        if ($items -isnot [array]) { Stop-Review 'invalid-page' }
        foreach ($item in $items) { [void]$values.Add($item) }
        $url = [string](Get-Field $page 'next' '')
    }
    return ,@($values)
}

function Get-Root {
    param([long] $CommentId, [object[]] $Comments)
    $seen = [Collections.Generic.HashSet[long]]::new()
    while ($true) {
        if (-not $seen.Add($CommentId)) { Stop-Review 'comment-parent-cycle' }
        $matches = @($Comments | Where-Object { (Get-Field $_ 'id') -eq $CommentId })
        if ($matches.Count -ne 1 -or (Get-Field $matches[0] 'deleted' $false)) { Stop-Review 'comment-unavailable' }
        $parent = Get-Field $matches[0] 'parent'
        if ($null -eq $parent) { return $matches[0] }
        $CommentId = [long](Get-Field $parent 'id' 0)
        if ($CommentId -le 0) { Stop-Review 'comment-unavailable' }
    }
}

function Get-PayloadDigest {
    param($Comment)
    $inline = Get-Field $Comment 'inline'
    $normalizedInline = $null
    if ($null -ne $inline) {
        $normalizedInline = [ordered]@{ path = [string](Get-Field $inline 'path') }
        foreach ($field in @('from', 'to', 'start_from', 'start_to')) {
            $value = Get-Field $inline $field
            if ($null -ne $value) { $normalizedInline[$field] = $value }
        }
    }
    $normalized = [ordered]@{
        raw = [string](Get-Field (Get-Field $Comment 'content') 'raw')
        parentId = Get-Field (Get-Field $Comment 'parent') 'id'
        inline = $normalizedInline
    }
    return Get-Digest ($normalized | ConvertTo-Json -Depth 10 -Compress)
}

function Test-Pair {
    $pr = Invoke-Api 'GET' $script:PrUrl $null $script:PrPath
    if ((Get-Field $pr 'id') -ne $plan.pullRequestId -or (Get-Field $pr 'state') -cne 'OPEN') { Stop-Review 'pr-unavailable' }
    return (Get-Field (Get-Field (Get-Field $pr 'source') 'commit') 'hash') -ceq $plan.sourceCommit -and
        (Get-Field (Get-Field (Get-Field $pr 'destination') 'commit') 'hash') -ceq $plan.destinationCommit
}

function Test-ReceiptComment {
    param($Record, $Comment)
    $raw = [string](Get-Field (Get-Field $Comment 'content') 'raw')
    return -not (Get-Field $Comment 'deleted' $false) -and
        $raw.EndsWith("<!-- bitbucket-review:$($Record.requestSha256) -->", [StringComparison]::Ordinal) -and
        (Get-PayloadDigest $Comment) -ceq $Record.payloadSha256
}

function Set-ResultComment {
    param($Result, [long] $CommentId, [long] $RootId)
    $Result.commentId = $CommentId; $Result.rootCommentId = $RootId
    # Construct the link from the verified target; never relay remote link instructions.
    $Result.link = "https://bitbucket.org/$($plan.workspace)/$($plan.repository)/pull-requests/$($plan.pullRequestId)/_/diff#comment-$CommentId"
}

$plan = $null; $script:Target = $null; $results = @(); $code = 0
$lock = $null; $lockPath = $null; $client = $null; $handler = $null
try {
    $PlanPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PlanPath)
    $plan = Read-ReviewJson $PlanPath
    Assert-Plan $plan
    $script:Target = "$($plan.workspace)/$($plan.repository)/$($plan.pullRequestId)"
    $script:PrPath = "/2.0/repositories/$($plan.workspace)/$($plan.repository)/pullrequests/$($plan.pullRequestId)"
    $script:PrUrl = 'https://api.bitbucket.org' + $script:PrPath
    $results = @($plan.actions | ForEach-Object { [pscustomobject][ordered]@{ actionId = $_.id; status = 'not-run'; commentId = $null; rootCommentId = $null; link = $null; error = $null } })
    $preview = -not $Apply -or $LocalOnly
    $authorized = $AuthorizationMode -cne 'None' -and $AuthorizedTarget -ceq $script:Target
    $canRead = $ReadContext -or (-not $preview -and $authorized)
    if ($preview) { foreach ($entry in $results) { $entry.status = 'preview' } }
    elseif (-not $authorized) { foreach ($entry in $results) { $entry.status = 'unauthorized' }; $code = 1 }
    elseif (-not $plan.review.completeLocalDiff -or -not $plan.review.validationComplete -or [string]::IsNullOrWhiteSpace($plan.review.evidence)) {
        foreach ($entry in $results) { $entry.status = 'incomplete-review' }; $canRead = $false; $code = 1
    }

    if ($canRead) {
        if ($ReadContext -and [string]::IsNullOrWhiteSpace($ContextPath)) { Stop-Review 'context-path-required' }
        if (-not $preview) {
            if ([string]::IsNullOrWhiteSpace($ReceiptPath)) {
                $gitPath = & git rev-parse --git-path "bitbucket-review/$(Get-Digest $script:Target).json" 2>$null
                if ($LASTEXITCODE -ne 0) { Stop-Review 'receipt-path-required' }
                $ReceiptPath = [string]$gitPath
            }
            $script:ReceiptFile = Assert-LocalDataPath $ReceiptPath
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $script:ReceiptFile))
            $lockPath = $script:ReceiptFile + '.lock'
            try { $lock = [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None) }
            catch { Stop-Review 'receipt-locked' }
            $script:Receipt = [pscustomobject]@{ schemaVersion = 1; target = $script:Target; records = @() }
            if (Test-Path -LiteralPath $script:ReceiptFile) { $script:Receipt = Read-ReviewJson $script:ReceiptFile; Assert-Receipt $script:Receipt }
        }
        if ($null -eq $EnvironmentReader) { $EnvironmentReader = { param($Name); [Environment]::GetEnvironmentVariable($Name, [EnvironmentVariableTarget]::Process) } }
        $email = [string](& $EnvironmentReader 'BITBUCKET_EMAIL')
        $token = [string](& $EnvironmentReader 'BITBUCKET_API_TOKEN')
        $base = [string](& $EnvironmentReader 'BITBUCKET_API_BASE_URL')
        if ($base -cne 'https://api.bitbucket.org/2.0' -or [string]::IsNullOrWhiteSpace($email) -or [string]::IsNullOrWhiteSpace($token)) { Stop-Review 'access-not-configured' }
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${email}:${token}"))
        $script:Headers = @{ Authorization = "Basic $encoded"; Accept = 'application/json' }
        if ($null -eq $DelayInvoker) { $DelayInvoker = { param($Seconds); Start-Sleep -Seconds $Seconds } }
        if ($null -eq $HttpInvoker) {
            Add-Type -AssemblyName System.Net.Http
            $handler = [Net.Http.HttpClientHandler]::new(); $handler.AllowAutoRedirect = $false
            $client = [Net.Http.HttpClient]::new($handler); $client.Timeout = [TimeSpan]::FromSeconds(30)
            $HttpInvoker = {
                param($Method, $Uri, $Headers, $Body)
                $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), $Uri)
                $response = $null
                try {
                    foreach ($key in $Headers.Keys) { [void]$request.Headers.TryAddWithoutValidation($key, [string]$Headers[$key]) }
                    if ($null -ne $Body) { $request.Content = [Net.Http.StringContent]::new([string]$Body, [Text.Encoding]::UTF8, 'application/json') }
                    $response = $client.SendAsync($request).GetAwaiter().GetResult()
                    $retry = if ($null -ne $response.Headers.RetryAfter) { [string]$response.Headers.RetryAfter } else { '1' }
                    return @{ StatusCode = [int]$response.StatusCode; Content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult(); Headers = @{ 'Retry-After' = $retry } }
                }
                finally { if ($null -ne $response) { $response.Dispose() }; $request.Dispose() }
            }
        }

        if ($ContextPath) {
            $contextFile = Assert-LocalDataPath $ContextPath
            if ($contextFile -eq [IO.Path]::GetFullPath($PlanPath) -or (-not $preview -and $contextFile -eq $script:ReceiptFile)) { Stop-Review 'conflicting-data-paths' }
            $metadata = Invoke-Api 'GET' $script:PrUrl $null $script:PrPath
            $context = [ordered]@{ target = $script:Target; metadata = $metadata; reviewedSourceCommit = $plan.sourceCommit; reviewedDestinationCommit = $plan.destinationCommit }
            foreach ($suffix in @('comments', 'activity', 'tasks', 'statuses')) { $context[$suffix] = Get-Pages "/$suffix" }
            $contextJson = $context | ConvertTo-Json -Depth 60
            foreach ($secret in @($token, $email, $encoded)) {
                $quotedSecret = ConvertTo-Json -InputObject $secret -Compress
                $escapedSecret = $quotedSecret.Substring(1, $quotedSecret.Length - 2)
                $contextJson = $contextJson.Replace($escapedSecret, '[redacted]').Replace($secret, '[redacted]')
            }
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $contextFile))
            [IO.File]::WriteAllText($contextFile, $contextJson, [Text.UTF8Encoding]::new($false))
        }
        if (-not $preview) {
            $stopBatch = $false
            for ($index = 0; $index -lt $plan.actions.Count; $index++) {
                $action = $plan.actions[$index]; $entry = $results[$index]
                if ($stopBatch) { continue }
                if ($AuthorizationMode -ceq 'Publish' -and ($action.type -cne 'Create' -or $AuthorizedActionIds -cnotcontains $action.id)) { $entry.status = 'unauthorized'; $code = 1; continue }
                if (($action.type -ceq 'Resolve' -and ($action.assessment -cne 'fixed' -or (Get-Field $action 'verifiedInPr' $false) -ne $true)) -or
                    ($action.type -ceq 'Reply' -and ($action.assessment -cne 'still-present' -or (Get-Field $action 'newEvidence' $false) -ne $true))) {
                    $entry.status = 'retained'; continue
                }
                $record = $null
                $writeAttempted = $false; $postDefiniteFailure = $false
                try {
                    $comments = Get-Pages '/comments'
                    $root = $null; $rootId = $null
                    if ($action.type -cne 'Create') { $root = Get-Root $action.commentId $comments; $rootId = [long]$root.id }
                    if ($action.type -ceq 'Resolve') {
                        $owned = @($script:Receipt.records | Where-Object { $_.type -ceq 'Create' -and $_.findingId -ceq $action.findingId -and $_.rootCommentId -eq $rootId -and $_.status -ceq 'succeeded' -and (Test-ReceiptComment $_ $root) }).Count -eq 1
                        if (-not $owned -and $IncludedRootCommentIds -notcontains $rootId) { $entry.status = 'not-owned'; $code = 1; continue }
                    }
                    if (-not (Test-Pair)) { $entry.status = 'stale-review'; $code = 1; $stopBatch = $true; continue }
                    if ($null -ne $root -and $null -ne (Get-Field $root 'resolution')) { $entry.status = 'already-resolved'; Set-ResultComment $entry $rootId $rootId; continue }
                    $requestIdentity = [ordered]@{ target = $script:Target; sourceCommit = $plan.sourceCommit; destinationCommit = $plan.destinationCommit; action = $action }
                    $requestHash = Get-Digest ($requestIdentity | ConvertTo-Json -Depth 15 -Compress)
                    $payload = $null
                    if ($action.type -cne 'Resolve') {
                        foreach ($secret in @($token, $email, $encoded)) { if ($action.content.Contains($secret)) { Stop-Review 'credential-in-content' } }
                        $payload = [ordered]@{ content = @{ raw = $action.content + "`n`n<!-- bitbucket-review:$requestHash -->" } }
                        if ($action.type -ceq 'Reply') { $payload.parent = @{ id = $rootId } }
                        elseif ($action.PSObject.Properties['inline']) { $payload.inline = $action.inline }
                    }
                    $payloadHash = Get-PayloadDigest $payload
                    $prior = @($script:Receipt.records | Where-Object { $_.actionId -ceq $action.id })
                    if ($prior.Count -gt 0) {
                        $record = $prior[0]
                        if ($record.requestSha256 -cne $requestHash -or $record.payloadSha256 -cne $payloadHash) { Stop-Review 'action-identity-changed' }
                        # Always reconcile a prior intent, including HTTP failures.
                        # A proxy/server can report an error after committing a POST.
                        $matches = @($comments | Where-Object { -not (Get-Field $_ 'deleted' $false) -and (Get-PayloadDigest $_) -ceq $payloadHash })
                        if ($matches.Count -eq 1) {
                            $record.commentId = [long]$matches[0].id; $record.rootCommentId = [long](Get-Root $record.commentId $comments).id
                            $record.status = 'succeeded'; Save-Receipt
                            Set-ResultComment $entry $record.commentId $record.rootCommentId; $entry.status = 'already-completed'; continue
                        }
                        if ($record.status -cne 'failed' -or $matches.Count -gt 1) {
                            $entry.status = 'uncertain'; $code = 1; $stopBatch = $true; continue
                        }
                    }
                    if ($action.type -ceq 'Create') {
                        $existing = @($script:Receipt.records | Where-Object { $_.type -ceq 'Create' -and $_.findingId -ceq $action.findingId -and $_.status -cne 'failed' })
                        if ($existing.Count -gt 0) {
                            if ($existing.Count -ne 1 -or $existing[0].status -cne 'succeeded') { $entry.status = 'uncertain'; $code = 1; $stopBatch = $true; continue }
                            $existingRoot = Get-Root $existing[0].rootCommentId $comments
                            if (-not (Test-ReceiptComment $existing[0] $existingRoot)) { Stop-Review 'mapping-unverified' }
                            Set-ResultComment $entry $existingRoot.id $existingRoot.id; $entry.status = 'already-completed'; continue
                        }
                    }
                    if ($null -eq $record) {
                        $record = [pscustomobject][ordered]@{ actionId = $action.id; findingId = $action.findingId; type = $action.type; sourceCommit = $plan.sourceCommit; destinationCommit = $plan.destinationCommit; requestSha256 = $requestHash; payloadSha256 = $payloadHash; commentId = $null; rootCommentId = $rootId; status = 'pending' }
                        $script:Receipt.records = @($script:Receipt.records) + @($record)
                    }
                    $record.status = 'pending'; Save-Receipt
                    $path = if ($action.type -ceq 'Resolve') { "$($script:PrPath)/comments/$rootId/resolve" } else { "$($script:PrPath)/comments" }
                    $body = if ($null -ne $payload) { $payload | ConvertTo-Json -Depth 10 -Compress } else { $null }
                    $uncertainPost = $false
                    $writeAttempted = $true
                    try { $created = Invoke-Api 'POST' ('https://api.bitbucket.org' + $path) $body $path }
                    catch {
                        $postError = [string]$_.Exception.Data['ReviewError']
                        if ($postError -notin @('transport-uncertain', 'invalid-api-json') -and $postError -cnotmatch '^http-5\d\d$') { $postDefiniteFailure = $true; throw }
                        $uncertainPost = $true
                    }
                    if ($action.type -ceq 'Resolve') {
                        $verified = Invoke-Api 'GET' "$($script:PrUrl)/comments/$rootId" $null "$($script:PrPath)/comments/$rootId"
                        if ((Get-Field $verified 'id') -ne $rootId -or (Get-Field $verified 'deleted' $false) -or $null -ne (Get-Field $verified 'parent') -or $null -eq (Get-Field $verified 'resolution')) { Stop-Review 'write-unverified' }
                        $record.commentId = $rootId; $record.rootCommentId = $rootId
                    }
                    else {
                        if ($uncertainPost) {
                            $after = Get-Pages '/comments'
                            $matches = @($after | Where-Object { -not (Get-Field $_ 'deleted' $false) -and (Get-PayloadDigest $_) -ceq $payloadHash })
                            if ($matches.Count -ne 1) { Stop-Review 'write-unverified' }
                            $created = $matches[0]
                        }
                        $id = Get-Field $created 'id'; Assert-PositiveInteger $id
                        $verified = Invoke-Api 'GET' "$($script:PrUrl)/comments/$id" $null "$($script:PrPath)/comments/$id"
                        if ((Get-PayloadDigest $verified) -cne $payloadHash -or (Get-Field $verified 'deleted' $false) -or (Get-Field $verified 'id') -ne $id) { Stop-Review 'write-unverified' }
                        $record.commentId = $id; $record.rootCommentId = if ($null -ne $rootId) { $rootId } else { $id }
                    }
                    $record.status = 'succeeded'; Save-Receipt
                    Set-ResultComment $entry $record.commentId $record.rootCommentId; $entry.status = 'succeeded'
                    if (-not (Test-Pair)) { $entry.error = 'version-changed-after-write'; $code = 1; $stopBatch = $true }
                }
                catch {
                    $errorCode = [string]$_.Exception.Data['ReviewError']
                    if (-not $errorCode) { $errorCode = 'review-action-failed' }
                    $entry.error = $errorCode
                    $entry.status = if ($writeAttempted -and -not $postDefiniteFailure) {
                        if ($null -ne $record -and $record.status -ceq 'succeeded') { 'succeeded' } else { 'uncertain' }
                    } else { 'failed' }
                    if ($null -ne $record -and $writeAttempted) {
                        $record.status = $entry.status
                        Save-Receipt
                        if ($entry.status -ceq 'succeeded') { Set-ResultComment $entry $record.commentId $record.rootCommentId }
                    }
                    $code = 1; $stopBatch = $true
                }
            }
        }
    }
}
catch {
    $errorCode = [string]$_.Exception.Data['ReviewError']
    if (-not $errorCode) { $errorCode = 'review-input-failed' }
    if ($results.Count -eq 0) { $results = @([pscustomobject]@{ actionId = 'input'; status = 'failed'; commentId = $null; rootCommentId = $null; link = $null; error = $errorCode }) }
    foreach ($entry in $results) { if ($entry.status -in @('not-run', 'preview')) { $entry.status = 'failed'; $entry.error = $errorCode } }
    $code = 1
}
finally {
    if ($null -ne $client) { $client.Dispose() }
    if ($null -ne $handler) { $handler.Dispose() }
    if ($null -ne $lock) { $lock.Dispose(); Remove-Item -LiteralPath $lockPath -Force }
    $script:Headers = $null; $token = $null; $email = $null; $encoded = $null
}
$result = [pscustomobject][ordered]@{ target = $script:Target; results = @($results); exitCode = $code }
if ($AsObject) { $result } else { $result | ConvertTo-Json -Depth 12 -Compress }
exit $code
