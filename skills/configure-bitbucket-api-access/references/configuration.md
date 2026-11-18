<!--
SPDX-FileCopyrightText: 2026 SyuanTsai
SPDX-License-Identifier: Apache-2.0
-->

# Bitbucket API access configuration

## Canonical Fast Path

Use `scripts/Configure-BitbucketApiAccess.ps1` for normal setup or repair. It is the stable entry point for non-secret environment values, hidden API-token input, Process/User scope selection, and optional read-only connection validation. Do not rebuild equivalent `Read-Host`, `SetEnvironmentVariable`, Basic-auth, or validator invocation snippets during ordinary Agent execution.

Use `scripts/Test-BitbucketApiAccess.ps1` when only inventory/diagnosis is needed and no configuration should be changed.

## Required settings

| Variable | Meaning | Safe validation |
| --- | --- | --- |
| `BITBUCKET_API_BASE_URL` | Bitbucket Cloud REST base | Exactly scheme `https`, host `api.bitbucket.org`, and base path `/2.0` after trimming a trailing slash |
| `BITBUCKET_EMAIL` | Atlassian/Bitbucket account email associated with the token | Non-empty email-shaped value |
| `BITBUCKET_API_TOKEN` | Bitbucket Cloud API token | Presence only; never inspect length, prefix, hash, or encoded form |
| `BITBUCKET_WORKSPACE` | Target workspace slug | Alphanumeric start, then alphanumeric/underscore/hyphen |

Load [the shared API access workflow](shared-workflow.md) for Process or User scope, environment inheritance, host reload, HTTP classification, and completion reporting.

## Fast Path usage

The normal Process-scope invocation is:

```powershell
pwsh -NoProfile -File ./scripts/Configure-BitbucketApiAccess.ps1 `
  -Email '<account-email>' `
  -Workspace '<workspace>' `
  -TargetScope Process `
  -TestConnection
```

After the shared workflow authorizes User persistence, add the explicit token-persistence switch only when separately authorized:

```powershell
pwsh -NoProfile -File ./scripts/Configure-BitbucketApiAccess.ps1 `
  -Email '<account-email>' `
  -Workspace '<workspace>' `
  -TargetScope User `
  -PersistTokenToUser `
  -TestConnection
```

The token is always collected with hidden `Read-Host -AsSecureString`; never put a real token in a command argument, prompt, repository, transcript, Jira comment, or response.

For an exact pull-request readiness check, supply both target values together:

```powershell
pwsh -NoProfile -File ./scripts/Configure-BitbucketApiAccess.ps1 `
  -Email '<account-email>' `
  -Workspace '<workspace>' `
  -TargetScope Process `
  -TestConnection `
  -RepositorySlug '<repository-slug>' `
  -PullRequestId 42
```

## Minimum permissions

For `review-bitbucket-pull-request` read-only analysis:

- `read:repository:bitbucket`
- `read:pullrequest:bitbucket`

Do not request Repository Write/Admin or Pull requests Write for ordinary review. Stronger scopes require a separate operation and explicit authorization.

## Validation behavior

`Test-BitbucketApiAccess.ps1` checks configuration without exposing values. With `-TestConnection`, it performs a minimal repository-list read; when repository slug and PR ID are also supplied, it performs the exact PR read. Response bodies are suppressed.

A repository-list `200` alone does not prove Pull requests Read or visibility of a specific PR.

For Bitbucket-specific remediation, a `400` requires validating both URL construction and workspace shape without exposing inputs, and a `404` requires verifying workspace or resource identity without guessing.
