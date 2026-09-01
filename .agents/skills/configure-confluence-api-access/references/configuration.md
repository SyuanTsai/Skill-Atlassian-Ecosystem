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

Process values apply only to the current process and future children. User-scope changes on Windows are persistent for newly launched processes, but already-running Codex/IDE processes do not inherit them automatically.

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

When the Fast Path reports `HostReloadRequired = true`, User-scope values have been written but the current Agent host may still be using its original environment snapshot. Restart/reload the host from an environment that can see the new User values. A child PowerShell process cannot update the environment of its existing parent Agent process.

## Access-path boundary

If the user selected Confluence REST API, remain on REST API for this flow. If the user selected an approved connector, do not force API-token setup. Never silently fall back from one access path to the other after a failure.
