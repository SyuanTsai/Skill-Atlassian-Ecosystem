# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluenceTransport.psm1'
$site = 'https://example.atlassian.net'
$cloudId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
$apiBase = "https://api.atlassian.com/ex/confluence/$cloudId"

function New-VerifiedSessionAccessReport {
    return [pscustomobject]@{
        ConfigurationState = 'valid'
        HostEnvironmentState = 'process-user-mismatch'
        HostReloadRequired = $true
        MissingProcessSettings = @()
        ScopeConflictSettings = @('CONFLUENCE_BASE_URL')
        TenantIdentityState = 'match'
        SpaceReadCheck = [pscustomobject]@{ Category = 'success' }
        PageReadCheck = [pscustomobject]@{ Category = 'success' }
        ReadyForRead = $true
    }
}

function Start-LoopbackHttpResponder {
    param([byte[]] $Body)
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $runspace = [PowerShell]::Create()
    $null = $runspace.AddScript({
        param($Listener, [byte[]] $Body)
        $client = $Listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $received = [IO.MemoryStream]::new()
            $chunk = [byte[]]::new(1024)
            while (-not ([Text.Encoding]::ASCII.GetString($received.ToArray()).Contains("`r`n`r`n"))) {
                $read = $stream.Read($chunk, 0, $chunk.Length)
                if ($read -eq 0) { break }
                $received.Write($chunk, 0, $read)
            }
            $head = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/octet-stream`r`nContent-Length: $($Body.Length)`r`nConnection: close`r`n`r`n")
            $stream.Write($head, 0, $head.Length)
            $stream.Write($Body, 0, $Body.Length)
            $stream.Flush()
        }
        catch { }
        finally { $client.Dispose() }
    }).AddArgument($listener).AddArgument($Body)
    $handle = $runspace.BeginInvoke()
    return [pscustomobject]@{
        Uri = "http://127.0.0.1:$(([Net.IPEndPoint] $listener.LocalEndpoint).Port)/wiki/api/v2/spaces"
        Listener = $listener; Runspace = $runspace; Handle = $handle
    }
}

function Stop-LoopbackHttpResponder {
    param([object] $Responder)
    if ($null -eq $Responder) { return }
    $Responder.Listener.Stop()
    if (-not $Responder.Handle.AsyncWaitHandle.WaitOne(5000)) { $Responder.Runspace.Stop() }
    $Responder.Runspace.Dispose()
}

function Invoke-ModuleWireRead {
    param([object] $Request)
    $module = Get-Module -Name ConfluenceTransport
    return & $module { param($InnerRequest) Invoke-ConfluenceWireRead -Request $InnerRequest } $Request
}

}

Describe 'SYP-478 real wire read loop' {
    # Scenario: SYP478-SCN-001; a real HTTP response is larger than the 8 KiB read buffer.
    # Purpose: The production read loop runs on pwsh (no .NET extension methods) and returns every byte.
    It 'UnitT10_wire_read_returns_full_multi_buffer_body' {
        Import-Module -Name $modulePath -Force
        $body = [byte[]]::new(20000)
        for ($i = 0; $i -lt $body.Length; $i++) { $body[$i] = [byte] ($i % 251) }
        $responder = Start-LoopbackHttpResponder -Body $body
        try {
            $result = Invoke-ModuleWireRead ([pscustomobject]@{ Method = 'GET'; Uri = $responder.Uri; Headers = @{ Accept = 'application/json' }; TimeoutSec = 10; ResponseLimitBytes = 4MB; AuthAllowed = $false; Authorization = $null })
            $result.StatusCode | Should -Be 200
            $result.BodyBytes.Length | Should -Be $body.Length
            [Convert]::ToBase64String($result.BodyBytes) | Should -BeExactly ([Convert]::ToBase64String($body))
        }
        finally { Stop-LoopbackHttpResponder $responder }
    }

    # Scenario: SYP478-SCN-002; a real HTTP response exceeds ResponseLimitBytes.
    # Purpose: The bounded read loop still stops with ResponseLimitExceeded instead of buffering the whole body.
    It 'UnitT20_wire_read_enforces_response_limit' {
        Import-Module -Name $modulePath -Force
        $responder = Start-LoopbackHttpResponder -Body ([byte[]]::new(20000))
        try {
            { Invoke-ModuleWireRead ([pscustomobject]@{ Method = 'GET'; Uri = $responder.Uri; Headers = @{}; TimeoutSec = 10; ResponseLimitBytes = 10000; AuthAllowed = $false; Authorization = $null }) } |
                Should -Throw -ExpectedMessage 'ResponseLimitExceeded'
        }
        finally { Stop-LoopbackHttpResponder $responder }
    }
}

Describe 'SYP-171 bounded live read transport' {
    BeforeEach { $script:wire = [System.Collections.Generic.List[object]]::new() }

    # Scenario: SYP171-SCN-001; the selected tenant is exact and a JSON read is bounded.
    # Purpose: Credentials go only to that tenant API origin; the envelope stays byte-accurate.
    It 'UnitT10_sends_auth_only_to_selected_api_and_returns_bytes' {
        Import-Module -Name $modulePath -Force
        $fake = {
            param($Request)
            $script:wire.Add($Request)
            return [pscustomobject]@{ StatusCode = 200; Headers = @{}; BodyBytes = [Text.Encoding]::UTF8.GetBytes('{"results":[]}') }
        }
        $invoker = New-ConfluenceReadInvoker -ExpectedSiteOrigin $site -ConfiguredSiteOrigin $site -ApiBase $apiBase -CloudId $cloudId -Email 'synthetic@example.invalid' -Token 'synthetic-token' -WireInvoker $fake
        $result = & $invoker ([pscustomobject]@{ Method = 'GET'; Uri = "$apiBase/wiki/api/v2/spaces"; Headers = @{ Accept = 'application/json' }; AuthAllowed = $true; TimeoutSec = 30; ResponseLimitBytes = 4MB })
        $result.StatusCode | Should -Be 200
        [Text.Encoding]::UTF8.GetString($result.BodyBytes) | Should -Be '{"results":[]}'
        $script:wire.Count | Should -Be 1
        $script:wire[0].AuthAllowed | Should -Be $true
        $script:wire[0].Authorization | Should -Match '^Basic '
    }

    # Scenario: SYP171-SCN-001; a read request points at another host.
    # Purpose: Reject it before a credential or any HTTP request is sent.
    It 'UnitT20_rejects_cross_host_request_before_wire' {
        Import-Module -Name $modulePath -Force
        $fake = { param($Request) $script:wire.Add($Request); throw 'Wire must not run.' }
        $invoker = New-ConfluenceReadInvoker -ExpectedSiteOrigin $site -ConfiguredSiteOrigin $site -ApiBase $apiBase -CloudId $cloudId -Email 'synthetic@example.invalid' -Token 'synthetic-token' -WireInvoker $fake
        { & $invoker ([pscustomobject]@{ Method = 'GET'; Uri = 'https://other.atlassian.net/wiki/api/v2/pages'; Headers = @{}; AuthAllowed = $true; TimeoutSec = 30; ResponseLimitBytes = 4MB }) } | Should -Throw
        $script:wire.Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-002; the attachment endpoint redirects to a signed binary URL.
    # Purpose: The signed URL receives no Authorization and is never printed in the result.
    It 'UnitT30_follows_one_https_attachment_redirect_without_auth' {
        Import-Module -Name $modulePath -Force
        $fake = {
            param($Request)
            $script:wire.Add($Request)
            if ($script:wire.Count -eq 1) { return [pscustomobject]@{ StatusCode = 302; Headers = @{ Location = 'https://signed.example.invalid/opaque?secret=abc' }; BodyBytes = [byte[]]@() } }
            return [pscustomobject]@{ StatusCode = 200; Headers = @{}; BodyBytes = [byte[]]@(1,2,3) }
        }
        $invoker = New-ConfluenceReadInvoker -ExpectedSiteOrigin $site -ConfiguredSiteOrigin $site -ApiBase $apiBase -CloudId $cloudId -Email 'synthetic@example.invalid' -Token 'synthetic-token' -WireInvoker $fake
        $result = & $invoker ([pscustomobject]@{ Method = 'GET'; Uri = "$apiBase/wiki/rest/api/content/101/child/attachment/501/download?version=1"; Headers = @{}; AuthAllowed = $true; TimeoutSec = 30; ResponseLimitBytes = 20MB })
        $result.StatusCode | Should -Be 200
        $result.BodyBytes.Length | Should -Be 3
        $script:wire.Count | Should -Be 2
        $script:wire[1].AuthAllowed | Should -Be $false
        $script:wire[1].Authorization | Should -BeNullOrEmpty
        ($result | ConvertTo-Json -Depth 4) | Should -Not -Match 'signed.example.invalid'
    }

    # Scenario: SYP171-SCN-002; the redirect target is not HTTPS.
    # Purpose: Unsafe download locations never receive a second request.
    It 'UnitT40_rejects_unsafe_attachment_redirect' {
        Import-Module -Name $modulePath -Force
        $fake = { param($Request) $script:wire.Add($Request); return [pscustomobject]@{ StatusCode = 302; Headers = @{ Location = 'http://127.0.0.1/private' }; BodyBytes = [byte[]]@() } }
        $invoker = New-ConfluenceReadInvoker -ExpectedSiteOrigin $site -ConfiguredSiteOrigin $site -ApiBase $apiBase -CloudId $cloudId -Email 'synthetic@example.invalid' -Token 'synthetic-token' -WireInvoker $fake
        { & $invoker ([pscustomobject]@{ Method = 'GET'; Uri = "$apiBase/wiki/rest/api/content/101/child/attachment/501/download"; Headers = @{}; AuthAllowed = $true; TimeoutSec = 30; ResponseLimitBytes = 20MB }) } | Should -Throw
        $script:wire.Count | Should -Be 1
    }

    # Scenario: SYP171-SCN-001; an explicit Process credential differs from older User settings after successful tenant and read checks.
    # Purpose: A verified session-only credential can capture the selected tenant without replacing persisted settings.
    It 'UnitT50_accepts_verified_process_only_session' {
        Import-Module -Name $modulePath -Force
        Test-ConfluenceSelectedSessionAccess -Access (New-VerifiedSessionAccessReport) | Should -BeTrue
    }

    # Scenario: SYP171-SCN-001; the helper reports a User-only value that has not been inherited by the current Process.
    # Purpose: An unbound host reload remains blocked rather than being mistaken for an intentional session override.
    It 'UnitT60_rejects_reload_required_without_process_override' {
        Import-Module -Name $modulePath -Force
        $access = New-VerifiedSessionAccessReport
        $access.HostEnvironmentState = 'reload-required'
        Test-ConfluenceSelectedSessionAccess -Access $access | Should -BeFalse
    }

    # Scenario: SYP171-SCN-001; the process override is incomplete or lacks an actual scope conflict.
    # Purpose: The exception requires all Process settings and an identified mismatch, not a bare success flag.
    It 'UnitT70_rejects_incomplete_process_override' {
        Import-Module -Name $modulePath -Force
        $access = New-VerifiedSessionAccessReport
        $access.MissingProcessSettings = @('CONFLUENCE_API_TOKEN')
        Test-ConfluenceSelectedSessionAccess -Access $access | Should -BeFalse
        $access.MissingProcessSettings = @()
        $access.ScopeConflictSettings = @()
        Test-ConfluenceSelectedSessionAccess -Access $access | Should -BeFalse
    }

    # Scenario: SYP171-SCN-001; the tenant or either required read was not verified.
    # Purpose: A Process/User mismatch never bypasses tenant binding or scoped read authorization.
    It 'UnitT80_rejects_unverified_tenant_or_read_access' {
        Import-Module -Name $modulePath -Force
        $access = New-VerifiedSessionAccessReport
        $access.TenantIdentityState = 'mismatch'
        Test-ConfluenceSelectedSessionAccess -Access $access | Should -BeFalse
        $access.TenantIdentityState = 'match'
        $access.PageReadCheck.Category = 'denied'
        Test-ConfluenceSelectedSessionAccess -Access $access | Should -BeFalse
        $access.PageReadCheck.Category = 'success'
        $access.ReadyForRead = $false
        Test-ConfluenceSelectedSessionAccess -Access $access | Should -BeFalse
    }

    # Scenario: SYP171-SCN-001; the Process and persisted settings already agree and the connection is verified.
    # Purpose: Existing successful access stays available after the caller adopts the shared predicate.
    It 'UnitT90_preserves_existing_process_ready_access' {
        Import-Module -Name $modulePath -Force
        $access = New-VerifiedSessionAccessReport
        $access.HostEnvironmentState = 'process-ready'
        $access.HostReloadRequired = $false
        $access.ScopeConflictSettings = @()
        Test-ConfluenceSelectedSessionAccess -Access $access | Should -BeTrue
        $access.HostReloadRequired = $true
        Test-ConfluenceSelectedSessionAccess -Access $access | Should -BeFalse
    }
}
