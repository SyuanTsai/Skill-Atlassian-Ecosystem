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
| `BITBUCKET_API_BASE_URL` | Bitbucket Cloud REST base | Exactly `https://api.bitbucket.org/2.0` |
| `BITBUCKET_EMAIL` | Atlassian/Bitbucket account email associated with the token | Non-empty email-shaped value |
| `BITBUCKET_API_TOKEN` | Bitbucket Cloud API token | Presence only; never inspect length, prefix, hash, or encoded form |
| `BITBUCKET_WORKSPACE` | Target workspace slug | Alphanumeric start, then alphanumeric/underscore/hyphen |

Process values apply only to the current process and future children. The Configure Fast Path always writes every required value to its current Process. With `-TargetScope User`, it additionally persists non-secret settings; the token is persisted only with `-PersistTokenToUser`. Already-running Agent hosts do not inherit later User-scope changes automatically.

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

The validator inventories Process, User, and Machine scopes but uses only Process values for actual authentication:

- `process-ready`: every required Process value is present and agrees with persisted values.
- `reload-required`: every missing Process value exists in User or Machine scope. No request is sent.
- `process-user-mismatch`: Process is complete, but at least one persisted value differs. The current Process can be tested, while a future host may inherit different values.
- `incomplete`: at least one required Process value is absent and has no persisted candidate.

`HostReloadContract` version 1 is host-agnostic. When `Required` is true, `RequiredAction` is `recreate-host-process`, `ParentProcessMutationSupported` is false, and the adapter must rerun the validator after reload. If the token was not persisted, `SecretInjectionRequired` is true and `SecretSourceRequired` is `approved-secret-store-or-hidden-input`; do not assume a restart alone will supply it. The Codex adapter fulfills the action by fully exiting and relaunching Codex with the required secret injection from an environment that can see the intended User values. Other hosts map the same action in their own adapter; a child PowerShell process must never claim to update its existing parent.

## Access-path boundary

If the user selected Bitbucket REST API, remain on REST API for this flow. If the user selected an approved connector, do not force API-token setup. Never silently fall back from one access path to the other after a failure.
