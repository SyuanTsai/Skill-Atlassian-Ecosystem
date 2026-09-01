# Bitbucket API access configuration

## Canonical Fast Path

Use `scripts/Configure-BitbucketApiAccess.ps1` for normal setup or repair. It is the stable entry point for non-secret environment values, hidden API-token input, Process/User scope selection, and optional read-only connection validation. Do not rebuild equivalent `Read-Host`, `SetEnvironmentVariable`, Basic-auth, or validator invocation snippets during ordinary Agent execution.

Use `scripts/Test-BitbucketApiAccess.ps1` when only inventory/diagnosis is needed and no configuration should be changed.

## Required settings

| Variable | Meaning | Safe validation |
| --- | --- | --- |
| `BITBUCKET_API_BASE_URL` | Bitbucket Cloud REST base | Exactly `https://api.bitbucket.org/2.0` |
| `BITBUCKET_EMAIL` | Atlassian/Bitbucket account email associated with the token | Non-empty email-shaped value |
| `BITBUCKET_API_TOKEN` | Bitbucket Cloud API token | Presence only; never inspect length, prefix, hash, or encoded form |
| `BITBUCKET_WORKSPACE` | Target workspace slug | Alphanumeric start, then alphanumeric/underscore/hyphen |

Process values apply only to the current process and future children. User-scope changes on Windows are persistent for newly launched processes, but already-running Codex/IDE processes do not inherit them automatically.

## Fast Path usage

Process scope is the default and safest normal route:

```powershell
pwsh -NoProfile -File ./scripts/Configure-BitbucketApiAccess.ps1 `
  -Email '<account-email>' `
  -Workspace '<workspace>' `
  -TargetScope Process `
  -TestConnection
```

Use User scope only after the persistence tradeoff is explicitly accepted. Persisting the token itself requires the additional `-PersistTokenToUser` switch:

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

Safe classifications:

- `200`: success for the tested endpoint
- `400`: request/configuration
- `401`: authentication
- `403`: permission/scope or workspace access
- `404`: target/path
- `429`: rate-limited
- transport/TLS failure: separate from authentication

A repository-list `200` alone does not prove Pull requests Read or visibility of a specific PR.

## Environment inheritance

When the Fast Path reports `HostReloadRequired = true`, User-scope values have been written but the current Agent host may still be using its original environment snapshot. Restart/reload the host from an environment that can see the new User values. A child PowerShell process cannot update the environment of its existing parent Agent process.

## Access-path boundary

If the user selected Bitbucket REST API, remain on REST API for this flow. If the user selected an approved connector, do not force API-token setup. Never silently fall back from one access path to the other after a failure.
