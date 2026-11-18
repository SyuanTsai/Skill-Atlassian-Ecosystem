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
| `CONFLUENCE_API_BASE_URL` | Scoped REST base | Exactly scheme `https`, host `api.atlassian.com`, and base path `/ex/confluence/{cloudId}` after trimming a trailing slash |

Load [the shared API access workflow](shared-workflow.md) for Process or User scope, environment inheritance, host reload, HTTP classification, and completion reporting.

## Fast Path usage

The normal Process-scope invocation is:

```powershell
pwsh -NoProfile -File ./scripts/Configure-ConfluenceApiAccess.ps1 `
  -BaseUrl 'https://<site>.atlassian.net' `
  -Email '<account-email>' `
  -TargetScope Process `
  -TestConnection
```

The script calls `${CONFLUENCE_BASE_URL}/_edge/tenant_info` without credentials, validates the returned Cloud ID, and derives `CONFLUENCE_API_BASE_URL` automatically. The helper calculates both values, so no manual derivation is needed.

After the shared workflow authorizes User persistence, add the explicit token-persistence switch only when separately authorized:

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

Read-only success proves only the tested read scopes; it does not prove `write:page:confluence` or destination-page permission.

For Confluence-specific remediation, a `400` requires validating both API-base construction and request shape without exposing inputs, and a `404` requires verifying Cloud ID, API path, or target resource identity without guessing.

## Least-privilege probe

A documented read-only endpoint outside the intended token scopes may be passed as `-OutOfScopeReadPath`. A `401`/`403` after the allowed reads succeed records the expected denial; a `200` indicates broader access than intended. Never use a mutating endpoint for this test.

## Completion supplement

In addition to the shared completion report, record the least-privilege probe result as exactly one of: `expected denial`, `broader access`, `not run`, or `inconclusive`. Do not infer a successful least-privilege probe from the allowed space and page reads.
