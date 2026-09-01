---
name: configure-confluence-api-access
description: Check and fix Confluence Cloud scoped API-token access without exposing credentials. Use when CONFLUENCE_* settings are missing or invalid before publishing, authentication returns 401/403, or the Cloud ID, scoped API base, and least-privilege reads need verification.
---

# Configure Confluence API Access

Guide the user from configuration inventory to a verified least-privilege Confluence Cloud connection. Keep credential values out of prompts, logs, repositories, command arguments, generated documents, and responses.

Read [references/configuration.md](references/configuration.md) before proposing commands, changing configuration, creating or rotating a token, or diagnosing an HTTP failure. Use [scripts/Test-ConfluenceApiAccess.ps1](scripts/Test-ConfluenceApiAccess.ps1) for redacted inventory and read-only checks instead of rebuilding credential-handling commands ad hoc.

## Workflow

1. Establish the exact intended Confluence operation. For `publish-requirements-to-confluence`, build the minimum scope list from the actual API operations: read spaces, read pages, and create/update pages only when publishing is requested.
2. Run the validation script without `-TestConnection` to inspect only whether `CONFLUENCE_BASE_URL`, `CONFLUENCE_EMAIL`, `CONFLUENCE_API_TOKEN`, `CONFLUENCE_CLOUD_ID`, and `CONFLUENCE_API_BASE_URL` are present and where they are defined. Validate non-secret shapes in memory; never print token values, lengths, hashes, prefixes, encoded forms, or Authorization headers.
3. Report a redacted inventory with purpose, presence, source scope, and validation result. Distinguish Process, User, Machine, secret-store injection, and unknown sources.
4. Resolve missing or invalid settings in dependency order: site base URL, account email, Cloud ID, scoped API base URL, then token.
5. If `CONFLUENCE_CLOUD_ID` is absent, use `${CONFLUENCE_BASE_URL}/_edge/tenant_info` as a read-only tenant lookup, extract only `cloudId`, validate it as a UUID, and derive `CONFLUENCE_API_BASE_URL` as `https://api.atlassian.com/ex/confluence/{cloudId}`. Never guess either value.
6. Before token creation or rotation, show one complete minimum scope checklist for the intended operation. Prefer a single-purpose scoped token with an explicit expiration date. Do not ask the user to paste the token into chat.
7. Before persisting or replacing a setting, explain the target storage scope and obtain explicit authorization. Prefer session-only injection or an approved secret manager; never write credentials to a repository, shell history, transcript, profile, generated document, Jira, or Confluence.
8. After the user approves a read-only connection check, run the script with `-TestConnection`. It first requests `${CONFLUENCE_BASE_URL}/_edge/tenant_info` without credentials and requires the returned Cloud ID to match both `CONFLUENCE_CLOUD_ID` and `CONFLUENCE_API_BASE_URL`. Do not send the token until this tenant binding succeeds.
9. After tenant identity matches, the script independently requests `${CONFLUENCE_API_BASE_URL}/wiki/api/v2/spaces?limit=1` and `${CONFLUENCE_API_BASE_URL}/wiki/api/v2/pages?limit=1`. It constructs Basic authentication only in memory and returns no response bodies. Read readiness requires `200` from both paths.
10. To evaluate least privilege, choose a documented, read-only Confluence endpoint that requires a scope intentionally omitted from this token, then pass only its relative `/wiki/api/...` path with `-OutOfScopeReadPath`. A `401` or `403` after both allowed requests succeed records the expected denial, but cannot by itself distinguish token scope from product permission; a `200` shows broader access than intended. Never use a mutating endpoint for this check.
11. Successful space and page reads validate authentication plus `read:space:confluence` and `read:page:confluence`. Do not claim `write:page:confluence` from read-only evidence; the publishing workflow must still verify destination permissions and use its explicit-write boundary.
12. When both read validations succeed, return control to `publish-requirements-to-confluence`. If a connector already provides the required operations, do not force API-token setup. That skill retains its preview, destination, draft-conflict, version, and explicit-write authorization requirements.

Run the supplied helper from the repository root; never add the email or token as arguments:

```powershell
pwsh -NoProfile -File ./.agents/skills/configure-confluence-api-access/scripts/Test-ConfluenceApiAccess.ps1
pwsh -NoProfile -File ./.agents/skills/configure-confluence-api-access/scripts/Test-ConfluenceApiAccess.ps1 -TestConnection -OutOfScopeReadPath <documented-read-only-relative-path>
```

## Minimum scopes for requirements publishing

Use granular scoped-token permissions aligned to the Confluence v2 endpoints actually used:

- space discovery: `read:space:confluence`
- page discovery/read: `read:page:confluence`
- page create/update: `write:page:confluence`

Do not request space-write/admin, attachment, restriction, delete, or unrelated scopes unless a separately authorized workflow actually needs them. Product-level space/page permissions still apply even when token scopes are present.

## Example

```text
User request:
"My Confluence publishing setup returns 403. Check the API access without showing any secret values."

Expected workflow:
1. Report only whether the five required environment variables are present and their source scopes.
2. Verify the site, Cloud ID, scoped API base, and minimum Space/Page scopes.
3. Offer the redacting validation script's tenant-binding check, allowed space/page requests, and a documented outside-scope read request.
4. Return only HTTP statuses, safe categories, least-privilege state, and next actions. Do not overstate whether a `403` is token scope or product permission when the evidence cannot distinguish them.
```

## Error Handling

- `400`: validate API-base construction and request shape without exposing inputs.
- `401`: verify token type, account email, expiration/revocation, and use of the scoped `api.atlassian.com/ex/confluence/{cloudId}` base.
- `403`: authentication may be valid; report missing token scope or product permission category.
- `404`: verify Cloud ID, API path, or target resource identity without guessing.
- `429`: respect `Retry-After`; do not loop aggressively.
- Network/TLS failure: separate transport failure from authentication failure.

## Stop Conditions

Stop and explain the next safe action when a credential would need to be displayed, logged, committed, or placed in a command argument; the site, Cloud ID, or intended operation is ambiguous; organization policy does not approve API-token use; stronger scopes are required but not justified; persistence/token rotation lacks authorization; or repeated authentication failures remain after safe endpoint and configuration checks.

## Completion Report

Report in the user's language:

- each required variable's presence, source scope, and validation state;
- whether the site, validated Cloud ID, and scoped API base identify the same tenant;
- each read-only endpoint category tested and its HTTP status;
- whether an expected outside-scope denial was observed, broader access was observed, the check was not run, or the result was inconclusive;
- minimum scopes required for the intended operation;
- whether API access is ready for read-only or publishing work;
- token-expiration/rotation actions still needing tracking.

Never include real credential values, Authorization headers, private account identifiers, tenant-specific content, or unrelated page data.
