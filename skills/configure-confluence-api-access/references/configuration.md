<!--
SPDX-FileCopyrightText: 2026 SyuanTsai
SPDX-License-Identifier: Apache-2.0
-->

# Confluence API access configuration

## Canonical Fast Path

Use `scripts/Configure-ConfluenceApiAccess.ps1` for normal setup or repair. It is the stable entry point for site/email configuration, Cloud ID discovery, scoped API-base derivation, hidden API-token input, Process/User scope selection, and optional read-only validation. Do not rebuild equivalent `Read-Host`, `SetEnvironmentVariable`, tenant lookup, Basic-auth, or validator invocation snippets during ordinary Agent execution.

Use `scripts/Test-ConfluenceApiAccess.ps1` when only inventory/diagnosis is needed and no configuration should be changed.

## Required settings

| Variable | Meaning | Safe validation |
| --- | --- | --- |
| `CONFLUENCE_BASE_URL` | Browser-facing Confluence Cloud site | Canonical `https://<site>.atlassian.net` root |
| `CONFLUENCE_EMAIL` | Atlassian account email associated with the token | Non-empty email-shaped value |
| `CONFLUENCE_API_TOKEN` | Scoped Confluence API token | Presence only; never inspect length, prefix, hash, or encoded form |
| `CONFLUENCE_CLOUD_ID` | Tenant identity | Non-empty UUID returned by `/_edge/tenant_info` |
| `CONFLUENCE_API_BASE_URL` | Scoped REST base | Exactly `https://api.atlassian.com/ex/confluence/{cloudId}` |

Process values apply only to the current process and future children. The Configure Fast Path always writes every required value to its current Process. With `-TargetScope User`, it additionally persists non-secret settings; the token is persisted only with `-PersistTokenToUser`. Already-running Agent hosts do not inherit later User-scope changes automatically.

## Fast Path usage

Process scope is the default normal route:

```powershell
pwsh -NoProfile -File ./scripts/Configure-ConfluenceApiAccess.ps1 `
  -BaseUrl 'https://<site>.atlassian.net' `
  -Email '<account-email>' `
  -TargetScope Process `
  -TestConnection
```

The script calls `${CONFLUENCE_BASE_URL}/_edge/tenant_info` without credentials, validates the returned Cloud ID, and derives `CONFLUENCE_API_BASE_URL` automatically. Do not ask the user to manually calculate either value.

Use User scope only after the persistence tradeoff is explicitly accepted. Persisting the token itself requires the additional `-PersistTokenToUser` switch:

```powershell
pwsh -NoProfile -File ./scripts/Configure-ConfluenceApiAccess.ps1 `
  -BaseUrl 'https://<site>.atlassian.net' `
  -Email '<account-email>' `
  -TargetScope User `
  -PersistTokenToUser `
  -TestConnection
```

The token is always collected with hidden `Read-Host -AsSecureString`; never put a real token in a command argument, prompt, repository, transcript, Jira comment, Confluence page, or response.

## Minimum scopes

For read validation:

- `read:space:confluence`
- `read:page:confluence`

For `publish-requirements-to-confluence`, page creation/update additionally requires:

- `write:page:confluence`

Do not request space admin/write, delete, attachment, restriction, or unrelated scopes unless a separately authorized operation requires them.

## Validation behavior

`Test-ConfluenceApiAccess.ps1` first validates tenant identity without credentials. Only after the site and Cloud ID match does it construct Basic authentication in memory and perform minimal reads against spaces and pages. Response bodies are suppressed.

Safe classifications:

- `200`: success for the tested endpoint
- `400`: request/configuration
- `401`: authentication
- `403`: token scope or product permission
- `404`: tenant/path/resource
- `429`: rate-limited
- transport/TLS failure: separate from authentication

Read-only success proves only the tested read scopes; it does not prove `write:page:confluence` or destination-page permission.

## Least-privilege probe

A documented read-only endpoint outside the intended token scopes may be passed as `-OutOfScopeReadPath`. A `401`/`403` after the allowed reads succeed records the expected denial; a `200` indicates broader access than intended. Never use a mutating endpoint for this test.

## Environment inheritance

The validator inventories Process, User, and Machine scopes but uses only Process values for tenant-authenticated requests:

- `process-ready`: every required Process value is present and agrees with persisted values.
- `reload-required`: every missing Process value exists in User or Machine scope. No request is sent.
- `process-user-mismatch`: Process is complete, but at least one persisted value differs. The current Process can be tested, while a future host may inherit different values.
- `incomplete`: at least one required Process value is absent and has no persisted candidate.

`HostReloadContract` version 1 is host-agnostic. When `Required` is true, `RequiredAction` is `recreate-host-process`, `ParentProcessMutationSupported` is false, and the adapter must rerun the validator after reload. If the token was not persisted, `SecretInjectionRequired` is true and `SecretSourceRequired` is `approved-secret-store-or-hidden-input`; do not assume a restart alone will supply it. The Codex adapter fulfills the action by fully exiting and relaunching Codex with the required secret injection from an environment that can see the intended User values. Other hosts map the same action in their own adapter; a child PowerShell process must never claim to update its existing parent.

## Access-path boundary

If the user selected Confluence REST API, remain on REST API for this flow. If the user selected an approved connector, do not force API-token setup. Never silently fall back from one access path to the other after a failure.
