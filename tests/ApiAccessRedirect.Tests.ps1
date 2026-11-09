# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Atlassian API access redirect rejection' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:BitbucketValidator = Join-Path $script:RepositoryRoot 'skills/configure-bitbucket-api-access/scripts/Test-BitbucketApiAccess.ps1'
        $script:ConfluenceValidator = Join-Path $script:RepositoryRoot 'skills/configure-confluence-api-access/scripts/Test-ConfluenceApiAccess.ps1'
        $script:JiraValidator = Join-Path $script:RepositoryRoot 'skills/configure-jira-api-access/scripts/Test-JiraApiAccess.ps1'
        $script:CloudId = '11111111-2222-3333-4444-555555555555'
        $script:RedirectLocation = 'https://redirect.invalid/private?canary=LOCATION_CANARY'

        function New-EnvironmentReader {
            param([hashtable] $Values)

            return {
                param([string] $Name, [string] $Scope)
                if ($Scope -cne 'Process') { return $null }
                return $Values[$Name]
            }.GetNewClosure()
        }

        function Assert-RedirectResultIsRedacted {
            param($Result, [string] $Email, [string] $Token)

            $serialized = $Result | ConvertTo-Json -Depth 20
            $serialized | Should -Not -Match ([regex]::Escape($Email))
            $serialized | Should -Not -Match ([regex]::Escape($Token))
            $serialized | Should -Not -Match ([regex]::Escape($script:RedirectLocation))
            $serialized | Should -Match 'redirects are not followed and the check failed closed'
        }

        function New-BitbucketValues {
            param([string] $Email, [string] $Token)
            return @{
                BITBUCKET_API_BASE_URL = 'https://api.bitbucket.org/2.0'
                BITBUCKET_EMAIL = $Email
                BITBUCKET_API_TOKEN = $Token
                BITBUCKET_WORKSPACE = 'test-workspace'
            }
        }

        function New-ConfluenceValues {
            param([string] $Email, [string] $Token)
            return @{
                CONFLUENCE_BASE_URL = 'https://example.atlassian.net'
                CONFLUENCE_EMAIL = $Email
                CONFLUENCE_API_TOKEN = $Token
                CONFLUENCE_CLOUD_ID = $script:CloudId
                CONFLUENCE_API_BASE_URL = "https://api.atlassian.com/ex/confluence/$($script:CloudId)"
            }
        }

        function New-JiraValues {
            param([string] $Email, [string] $Token)
            return @{
                JIRA_BASE_URL = 'https://example.atlassian.net'
                JIRA_EMAIL = $Email
                JIRA_API_TOKEN = $Token
                JIRA_CLOUD_ID = $script:CloudId
                JIRA_API_BASE_URL = "https://api.atlassian.com/ex/jira/$($script:CloudId)"
            }
        }
    }

    It 'stops after a Bitbucket repository redirect and rejects a later PR redirect' {
        $email = 'bitbucket-user@example.invalid'
        $token = 'BITBUCKET_REDIRECT_TOKEN_CANARY'
        $firstState = @{ Call = 0 }
        $repositoryRedirectInvoker = {
            param([Uri] $Uri, [hashtable] $Headers)
            $firstState.Call++
            return [pscustomobject]@{
                StatusCode = 302
                Content = ''
                Headers = @{ Location = $script:RedirectLocation }
            }
        }.GetNewClosure()

        $repositoryRedirectResult = & $script:BitbucketValidator `
            -TestConnection `
            -RepositorySlug 'repository' `
            -PullRequestId 42 `
            -EnvironmentReader (New-EnvironmentReader (New-BitbucketValues $email $token)) `
            -HttpInvoker $repositoryRedirectInvoker

        $repositoryRedirectResult.RepositoryReadCheck.StatusCode | Should -Be 302
        $repositoryRedirectResult.RepositoryReadCheck.Category | Should -Be 'redirect-rejected'
        $repositoryRedirectResult.PullRequestReadCheck.Category | Should -Be 'not-run'
        $firstState.Call | Should -Be 1
        $repositoryRedirectResult.ReadyForReview | Should -BeFalse
        Assert-RedirectResultIsRedacted $repositoryRedirectResult $email $token

        $secondState = @{ Call = 0 }
        $pullRequestRedirectInvoker = {
            param([Uri] $Uri, [hashtable] $Headers)
            $secondState.Call++
            $status = if ($Uri.AbsolutePath -like '*/pullrequests/42') { 307 } else { 200 }
            return [pscustomobject]@{
                StatusCode = $status
                Content = ''
                Headers = @{ Location = $script:RedirectLocation }
            }
        }.GetNewClosure()

        $pullRequestRedirectResult = & $script:BitbucketValidator `
            -TestConnection `
            -RepositorySlug 'repository' `
            -PullRequestId 42 `
            -EnvironmentReader (New-EnvironmentReader (New-BitbucketValues $email $token)) `
            -HttpInvoker $pullRequestRedirectInvoker

        $pullRequestRedirectResult.RepositoryReadCheck.Category | Should -Be 'success'
        $pullRequestRedirectResult.PullRequestReadCheck.StatusCode | Should -Be 307
        $pullRequestRedirectResult.PullRequestReadCheck.Category | Should -Be 'redirect-rejected'
        $secondState.Call | Should -Be 2
        $pullRequestRedirectResult.ReadyForReview | Should -BeFalse
        Assert-RedirectResultIsRedacted $pullRequestRedirectResult $email $token
    }

    It 'normalizes the Bitbucket default invoker 302 response and disables redirects' {
        $email = 'bitbucket-default@example.invalid'
        $token = 'BITBUCKET_DEFAULT_TOKEN_CANARY'
        Mock Invoke-WebRequest {
            return [pscustomobject]@{ StatusCode = 302; Content = ''; Headers = @{ Location = $script:RedirectLocation } }
        }

        $result = . $script:BitbucketValidator `
            -TestConnection `
            -EnvironmentReader (New-EnvironmentReader (New-BitbucketValues $email $token))

        $result.RepositoryReadCheck.StatusCode | Should -Be 302
        $result.RepositoryReadCheck.Category | Should -Be 'redirect-rejected'
        $result.ReadyForReview | Should -BeFalse
        Should -Invoke Invoke-WebRequest -Times 1 -ParameterFilter { $MaximumRedirection -eq 0 -and $SkipHttpErrorCheck }
        Assert-RedirectResultIsRedacted $result $email $token
    }

    It 'rejects a Confluence tenant redirect before constructing authorization' {
        $email = 'confluence-tenant@example.invalid'
        $token = 'CONFLUENCE_TENANT_TOKEN_CANARY'
        $state = @{ AuthorizationObserved = $false }
        $invoker = {
            param([Uri] $Uri, [hashtable] $Headers)
            if ($Headers.ContainsKey('Authorization')) { $state.AuthorizationObserved = $true }
            return [pscustomobject]@{ StatusCode = 302; Content = ''; Headers = @{ Location = $script:RedirectLocation } }
        }.GetNewClosure()

        $result = & $script:ConfluenceValidator `
            -TestConnection `
            -EnvironmentReader (New-EnvironmentReader (New-ConfluenceValues $email $token)) `
            -HttpInvoker $invoker

        $result.TenantIdentityCheck.StatusCode | Should -Be 302
        $result.TenantIdentityCheck.Category | Should -Be 'redirect-rejected'
        $result.ReadyForRead | Should -BeFalse
        $state.AuthorizationObserved | Should -BeFalse
        Assert-RedirectResultIsRedacted $result $email $token
    }

    It 'stops after a Confluence space redirect and rejects a later page redirect' {
        $email = 'confluence-user@example.invalid'
        $token = 'CONFLUENCE_REDIRECT_TOKEN_CANARY'
        $firstState = @{ AuthenticatedCalls = 0; CloudId = $script:CloudId }
        $spaceRedirectInvoker = {
            param([Uri] $Uri, [hashtable] $Headers)
            $isTenantRequest = $Uri.AbsolutePath -like '*/_edge/tenant_info'
            if (-not $isTenantRequest) { $firstState.AuthenticatedCalls++ }
            $status = if ($isTenantRequest) { 200 } else { 302 }
            $content = if ($status -eq 200) { @{ cloudId = $firstState.CloudId } | ConvertTo-Json -Compress } else { '' }
            return [pscustomobject]@{
                StatusCode = $status
                Content = $content
                Headers = @{ Location = $script:RedirectLocation }
            }
        }.GetNewClosure()

        $spaceRedirectResult = & $script:ConfluenceValidator `
            -TestConnection `
            -OutOfScopeReadPath '/wiki/api/v2/attachments?limit=1' `
            -EnvironmentReader (New-EnvironmentReader (New-ConfluenceValues $email $token)) `
            -HttpInvoker $spaceRedirectInvoker

        $spaceRedirectResult.SpaceReadCheck.Category | Should -Be 'redirect-rejected'
        $spaceRedirectResult.SpaceReadCheck.StatusCode | Should -Be 302
        $spaceRedirectResult.PageReadCheck.Category | Should -Be 'not-run'
        $spaceRedirectResult.LeastPrivilegeState | Should -Be 'inconclusive'
        $spaceRedirectResult.LeastPrivilegeCheck.Attempted | Should -BeFalse
        $firstState.AuthenticatedCalls | Should -Be 1
        $spaceRedirectResult.ReadyForRead | Should -BeFalse
        Assert-RedirectResultIsRedacted $spaceRedirectResult $email $token

        $secondState = @{ AuthenticatedCalls = 0; CloudId = $script:CloudId }
        $pageRedirectInvoker = {
            param([Uri] $Uri, [hashtable] $Headers)
            $isTenantRequest = $Uri.AbsolutePath -like '*/_edge/tenant_info'
            if (-not $isTenantRequest) { $secondState.AuthenticatedCalls++ }
            $status = if ($isTenantRequest -or $Uri.AbsolutePath -like '*/spaces') { 200 } else { 307 }
            $content = if ($isTenantRequest) { @{ cloudId = $secondState.CloudId } | ConvertTo-Json -Compress } else { '' }
            return [pscustomobject]@{
                StatusCode = $status
                Content = $content
                Headers = @{ Location = $script:RedirectLocation }
            }
        }.GetNewClosure()

        $pageRedirectResult = & $script:ConfluenceValidator `
            -TestConnection `
            -OutOfScopeReadPath '/wiki/api/v2/attachments?limit=1' `
            -EnvironmentReader (New-EnvironmentReader (New-ConfluenceValues $email $token)) `
            -HttpInvoker $pageRedirectInvoker

        $pageRedirectResult.SpaceReadCheck.Category | Should -Be 'success'
        $pageRedirectResult.PageReadCheck.Category | Should -Be 'redirect-rejected'
        $pageRedirectResult.PageReadCheck.StatusCode | Should -Be 307
        $pageRedirectResult.LeastPrivilegeState | Should -Be 'inconclusive'
        $pageRedirectResult.LeastPrivilegeCheck.Attempted | Should -BeFalse
        $secondState.AuthenticatedCalls | Should -Be 2
        $pageRedirectResult.ReadyForRead | Should -BeFalse
        Assert-RedirectResultIsRedacted $pageRedirectResult $email $token
    }

    It 'normalizes the Confluence default invoker 302 response and disables redirects' {
        $email = 'confluence-default@example.invalid'
        $token = 'CONFLUENCE_DEFAULT_TOKEN_CANARY'
        Mock Invoke-WebRequest {
            if ([string]$Uri -like '*_edge/tenant_info') {
                return [pscustomobject]@{ StatusCode = 200; Content = (@{ cloudId = $script:CloudId } | ConvertTo-Json -Compress) }
            }
            return [pscustomobject]@{ StatusCode = 302; Content = ''; Headers = @{ Location = $script:RedirectLocation } }
        }

        $result = . $script:ConfluenceValidator `
            -TestConnection `
            -EnvironmentReader (New-EnvironmentReader (New-ConfluenceValues $email $token))

        $result.SpaceReadCheck.Category | Should -Be 'redirect-rejected'
        $result.PageReadCheck.Category | Should -Be 'not-run'
        $result.ReadyForRead | Should -BeFalse
        Should -Invoke Invoke-WebRequest -Times 2 -ParameterFilter { $MaximumRedirection -eq 0 -and $SkipHttpErrorCheck }
        Assert-RedirectResultIsRedacted $result $email $token
    }

    It 'rejects a Jira tenant redirect before constructing authorization' {
        $email = 'jira-tenant@example.invalid'
        $token = 'JIRA_TENANT_TOKEN_CANARY'
        $state = @{ AuthorizationObserved = $false }
        $invoker = {
            param([string] $Uri, [hashtable] $Headers)
            if ($Headers.ContainsKey('Authorization')) { $state.AuthorizationObserved = $true }
            return [pscustomobject]@{ StatusCode = 302; Content = ''; Headers = @{ Location = $script:RedirectLocation } }
        }.GetNewClosure()

        $result = & $script:JiraValidator `
            -TestConnection `
            -EnvironmentReader (New-EnvironmentReader (New-JiraValues $email $token)) `
            -HttpInvoker $invoker

        $result.TenantIdentityCheck.StatusCode | Should -Be 302
        $result.TenantIdentityCheck.Category | Should -Be 'redirect-rejected'
        $result.ReadyForRead | Should -BeFalse
        $state.AuthorizationObserved | Should -BeFalse
        Assert-RedirectResultIsRedacted $result $email $token
    }

    It 'rejects Jira <StatusCode> identity redirects without running requested queries' -ForEach @(
        @{ StatusCode = 302 }
        @{ StatusCode = 307 }
    ) {
        param($StatusCode)
        $email = 'jira-user@example.invalid'
        $token = 'JIRA_REDIRECT_TOKEN_CANARY'
        $testState = @{ RedirectStatus = [int] $StatusCode; QueryObserved = $false; CloudId = $script:CloudId }
        $invoker = {
            param([string] $Uri, [hashtable] $Headers)
            if ($Uri -like '*/_edge/tenant_info') {
                return [pscustomobject]@{ StatusCode = 200; Content = (@{ cloudId = $testState.CloudId } | ConvertTo-Json -Compress) }
            }
            if ($Uri -notlike '*/rest/api/3/myself') { $testState.QueryObserved = $true }
            return [pscustomobject]@{ StatusCode = $testState.RedirectStatus; Content = ''; Headers = @{ Location = $script:RedirectLocation } }
        }.GetNewClosure()

        $result = & $script:JiraValidator `
            -Jql 'project = DEMO' `
            -EnvironmentReader (New-EnvironmentReader (New-JiraValues $email $token)) `
            -HttpInvoker $invoker

        $result.IdentityReadCheck.StatusCode | Should -Be $StatusCode
        $result.IdentityReadCheck.Category | Should -Be 'redirect-rejected'
        $result.JqlReadCheck.Category | Should -Be 'not-run'
        $testState.QueryObserved | Should -BeFalse
        $result.ReadyForRead | Should -BeFalse
        $result.ReadyForRequestedQuery | Should -BeFalse
        Assert-RedirectResultIsRedacted $result $email $token
    }

    It 'normalizes the Jira default invoker 302 response and disables redirects' {
        $email = 'jira-default@example.invalid'
        $token = 'JIRA_DEFAULT_TOKEN_CANARY'
        Mock Invoke-WebRequest {
            if ([string]$Uri -like '*_edge/tenant_info') {
                return [pscustomobject]@{ StatusCode = 200; Content = (@{ cloudId = $script:CloudId } | ConvertTo-Json -Compress) }
            }
            return [pscustomobject]@{ StatusCode = 302; Content = ''; Headers = @{ Location = $script:RedirectLocation } }
        }

        $result = . $script:JiraValidator `
            -TestConnection `
            -EnvironmentReader (New-EnvironmentReader (New-JiraValues $email $token))

        $result.IdentityReadCheck.StatusCode | Should -Be 302
        $result.IdentityReadCheck.Category | Should -Be 'redirect-rejected'
        $result.ReadyForRead | Should -BeFalse
        Should -Invoke Invoke-WebRequest -Times 2 -ParameterFilter { $MaximumRedirection -eq 0 -and $SkipHttpErrorCheck }
        Assert-RedirectResultIsRedacted $result $email $token
    }

    It 'uses the shared maximum-redirection setting before the PS7-only option' {
        foreach ($validator in @($script:BitbucketValidator, $script:ConfluenceValidator, $script:JiraValidator)) {
            $source = Get-Content -LiteralPath $validator -Raw
            $source | Should -Match 'MaximumRedirection\s*=\s*0'
            $source | Should -Match 'if \(\$PSVersionTable\.PSVersion\.Major -ge 7\)'
            $source | Should -Match 'Invoke-WebRequest\s+@invokeParams'
        }
    }
}
