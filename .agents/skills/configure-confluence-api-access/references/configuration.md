# Confluence API access configuration

## Required settings

| Variable | Meaning | Safe validation |
| --- | --- | --- |
| `CONFLUENCE_BASE_URL` | Browser-facing Confluence Cloud site URL | Root HTTPS URL on an `*.atlassian.net` host with no path, query, fragment, credentials, or non-default port |
| `CONFLUENCE_EMAIL` | Atlassian account email associated with the token | Non-empty email-shaped value |
| `CONFLUENCE_API_TOKEN` | Scoped Confluence API token | Presence only; never validate by token length, prefix, hash, or partial characters |
| `CONFLUENCE_CLOUD_ID` | Atlassian Cloud tenant identifier | UUID returned by `/_edge/tenant_info` |
| `CONFLUENCE_API_BASE_URL` | REST base for a scoped Confluence token | Exactly `https://api.atlassian.com/ex/confluence/{CONFLUENCE_CLOUD_ID}` after trimming a trailing slash |

Process-scoped values can make the current session work but do not prove User- or Machine-level persistence.

## Least-privilege scopes

For `publish-requirements-to-confluence`, scope the token to the exact endpoint set needed:

- `read:space:confluence` for space discovery and validation;
- `read:page:confluence` for page discovery, current-page reads, draft/version checks, and read-back verification;
- `write:page:confluence` only when the workflow will create or update a page.

Do not request space-write/admin, attachment, restriction, delete, label, or unrelated scopes unless a separately authorized workflow actually uses endpoints requiring them. Token scopes do not replace Confluence product permissions for the destination space/page.

## Token creation, expiration, rotation, and revocation

Create a scoped Atlassian API token with a descriptive single-purpose name, minimum scopes, and a finite expiration date. Record only the purpose and expiration date in non-secret operational tracking; never record the token value.

Do not accept the token in chat. Have the user inject it privately into the current process or an approved secret store. Persisting it to User/Machine environment variables is an explicit security tradeoff and requires user authorization. Never place it in a repository, `.env` file committed to Git, shell history, profile script, transcript, CI log, Jira issue, or Confluence page.

Rotate before expiry or when required scopes/purpose change. Revoke immediately when compromised or no longer required.

## Cloud ID discovery

Use `CONFLUENCE_BASE_URL` to make a read-only request equivalent to the following whenever resolving or validating tenant identity:

```text
GET ${CONFLUENCE_BASE_URL}/_edge/tenant_info
Accept: application/json
```

Read only `cloudId`, validate it as a non-empty UUID, and require it to match the configured Cloud ID before deriving or accepting:

```text
https://api.atlassian.com/ex/confluence/{cloudId}
```

For scoped API tokens, use that base before Confluence `/wiki/api/v2/...` paths. Do not guess Cloud ID or send scoped-token requests to an unverified site-specific API base.

## Redacted validation helper

Run an offline inventory first from the repository root:

```powershell
pwsh -NoProfile -File ./.agents/skills/configure-confluence-api-access/scripts/Test-ConfluenceApiAccess.ps1
```

The helper reports presence, source scope, and non-secret shape only. It never reports the email, token, encoded credential, Authorization header, response body, tenant content, or raw exception message.

After the user approves a read-only connection check, validate tenant binding, both required read paths, and a deliberately omitted read scope:

```powershell
pwsh -NoProfile -File ./.agents/skills/configure-confluence-api-access/scripts/Test-ConfluenceApiAccess.ps1 -TestConnection -OutOfScopeReadPath <documented-read-only-relative-path>
```

Select the outside-scope path from the current official Confluence API documentation. It must start with `/wiki/api/`, use `GET`, and require a scope intentionally excluded from the token. Never use page creation, update, deletion, restriction, or another mutating operation to test least privilege. Do not put the token or email on the command line.

## Read-only validation paths

First perform the unauthenticated tenant lookup above. Only after its Cloud ID matches, use requests equivalent to:

```text
GET ${CONFLUENCE_API_BASE_URL}/wiki/api/v2/spaces?limit=1
GET ${CONFLUENCE_API_BASE_URL}/wiki/api/v2/pages?limit=1
Accept: application/json
Authorization: Basic <in-memory base64 of CONFLUENCE_EMAIL:CONFLUENCE_API_TOKEN>
```

Construct the Authorization value only in memory. Do not echo the header, encoded credential, response body, space names, page titles, or tenant metadata.

Interpret conservatively:

| Result | Meaning and safe next action |
| --- | --- |
| `200` from both allowed paths | Authentication plus read-space and read-page access works; separately verify page-write requirements for publishing |
| `400` | Check scoped API-base construction and request syntax |
| `401` | Check email, token type, expiration/revocation, and use of the scoped API base |
| `403` | Check token scope and Confluence product permission |
| `404` | Check Cloud ID/API path/resource identity without guessing |
| `429` | Respect `Retry-After` |
| Network/TLS failure | Diagnose proxy/network/TLS separately from credentials |

The helper classifies least privilege only after tenant identity matches and both allowed read requests succeed:

| Outside-scope result | Safe conclusion |
| --- | --- |
| `401` or `403` | Expected denial observed; this supports the boundary but does not alone distinguish token scope from product permission |
| `200` | The token or account can read beyond the intended scope; review and reduce access |
| Not run | Least privilege was not tested |
| Other status or transport failure | Inconclusive; do not claim least privilege |

Read-only checks can establish authentication and selected read access. They cannot prove `write:page:confluence`; page publishing still requires the consuming skill's destination-permission checks and explicit write authorization.

## Safe inspection

On Windows, query environment presence at Process/User/Machine scope independently with `System.Environment.GetEnvironmentVariable`. On Unix-like systems, inspect only the current process and approved secret-store integration. Never scan shell history or unrelated home-directory files. If the source cannot be established safely, report it as unknown.

Validate URLs and UUIDs in memory and report only category-level results. Never include credentials in URLs.
