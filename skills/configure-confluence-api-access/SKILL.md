---
name: configure-confluence-api-access
description: Check and fix Confluence Cloud scoped API-token access without exposing credentials. Use when CONFLUENCE_* settings are missing or invalid before publishing, authentication returns 401/403, or the Cloud ID, scoped API base, and least-privilege reads need verification.
---

# Configure Confluence API Access

Guide the user from configuration inventory to a verified least-privilege Confluence Cloud connection. Keep credential values out of prompts, logs, repositories, command arguments, generated documents, and responses.

Read [references/configuration.md](references/configuration.md) before changing configuration, creating or rotating a token, or diagnosing an HTTP failure. Use [scripts/Configure-ConfluenceApiAccess.ps1](scripts/Configure-ConfluenceApiAccess.ps1) as the canonical Fast Path for environment setup, Cloud ID discovery, API-base derivation, and hidden token input; use [scripts/Test-ConfluenceApiAccess.ps1](scripts/Test-ConfluenceApiAccess.ps1) for redacted inventory and read-only checks. Do not regenerate equivalent `Read-Host`, `SetEnvironmentVariable`, tenant lookup, Basic-auth, or validation PowerShell during the normal flow when these scripts are available.

## Workflow

1. Establish the exact intended Confluence operation. For `publish-requirements-to-confluence`, build the minimum scope list from the actual API operations: read spaces, read pages, and create/update pages only when publishing is requested.
2. Run `Test-ConfluenceApiAccess.ps1` without `-TestConnection` to inspect only whether `CONFLUENCE_BASE_URL`, `CONFLUENCE_EMAIL`, `CONFLUENCE_API_TOKEN`, `CONFLUENCE_CLOUD_ID`, and `CONFLUENCE_API_BASE_URL` are present and where they are defined. Validate non-secret shapes in memory; never print token values, lengths, hashes, prefixes, encoded forms, or Authorization headers.
3. Report a redacted inventory with purpose, presence, source scope, and validation result. Distinguish Process, User, Machine, secret-store injection, and unknown sources.
4. If the REST API path is selected and configuration must be created or repaired, use `Configure-ConfluenceApiAccess.ps1` rather than constructing PowerShell setup commands ad hoc. Supply only the site base URL, email, and desired `Process` or `User` scope. The script performs unauthenticated `/_edge/tenant_info` discovery, validates the Cloud ID, derives `https://api.atlassian.com/ex/confluence/{cloudId}`, reads the token with hidden input, always configures its current Process for immediate validation, and invokes the validator.
5. Use `Process` scope by default. Use `User` scope only after explaining persistence and obtaining authorization; this adds User persistence to the current Process setup. Persisting the token to User scope additionally requires the script's explicit `-PersistTokenToUser` switch; otherwise the token remains Process-scoped even when non-secret settings are persisted.
6. Before token creation or rotation, show one complete minimum scope checklist for the intended operation. Prefer a single-purpose scoped token with an explicit expiration date. Do not ask the user to paste the token into chat.
7. After the user approves a read-only connection check, use either the Configure Fast Path with `-TestConnection` or `Test-ConfluenceApiAccess.ps1 -TestConnection`. Tenant identity must match before credentials are sent. The validator then independently requests the spaces and pages endpoints and suppresses response bodies.
8. To evaluate least privilege, choose a documented, read-only Confluence endpoint that requires a scope intentionally omitted from this token, then pass only its relative `/wiki/api/...` path with `-OutOfScopeReadPath`. A `401` or `403` after both allowed requests succeed records the expected denial, but cannot by itself distinguish token scope from product permission; a `200` shows broader access than intended. Never use a mutating endpoint for this check.
9. Successful space and page reads validate authentication plus `read:space:confluence` and `read:page:confluence`. Do not claim `write:page:confluence` from read-only evidence; the publishing workflow must still verify destination permissions and use its explicit-write boundary.
10. Treat Process scope as the only effective environment for connection validation. If required settings exist only in User/Machine scope, report `HostEnvironmentState = reload-required`, list `PersistedButNotInheritedSettings`, and do not make a request. If Process and User values differ, validate the current Process values but report `process-user-mismatch`. Follow `HostReloadContract.RequiredAction = recreate-host-process`; when `SecretInjectionRequired` is true, recreate it through the approved secret source named by the contract. Never try to repair the parent Agent by setting `$env:*` in a child shell.
11. When read validation succeeds, return control to `publish-requirements-to-confluence`. If the user selected connector access instead, do not force API-token setup or silently change access paths.

Canonical Fast Path examples use placeholders only; never place a real token in an argument:

```powershell
pwsh -NoProfile -File ./.agents/skills/configure-confluence-api-access/scripts/Configure-ConfluenceApiAccess.ps1 -BaseUrl 'https://<site>.atlassian.net' -Email '<account-email>' -TargetScope Process -TestConnection
pwsh -NoProfile -File ./.agents/skills/configure-confluence-api-access/scripts/Configure-ConfluenceApiAccess.ps1 -BaseUrl 'https://<site>.atlassian.net' -Email '<account-email>' -TargetScope User -PersistTokenToUser -TestConnection
```

For diagnosis without changing settings:

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
1. Run the canonical validator and report only whether the five required environment variables are present and their source scopes.
2. Verify the site, Cloud ID, scoped API base, and minimum Space/Page scopes.
3. If setup is missing and REST API is the selected path, invoke the canonical Configure Fast Path instead of generating tenant-discovery/environment PowerShell.
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

Stop and explain the next safe action when a credential would need to be displayed, logged, committed, or placed in a command argument; the site, Cloud ID, or intended operation is ambiguous; organization policy does not approve API-token use; stronger scopes are required but not justified; persistence/token rotation lacks authorization; the selected access path would need to change without user authorization; or repeated authentication failures remain after safe endpoint and configuration checks.

## Completion Report

Report in the user's language:

- each required variable's presence, source scope, and validation state;
- whether the site, discovered Cloud ID, and scoped API base identify the same tenant;
- each read-only endpoint category tested and its HTTP status;
- whether an expected outside-scope denial was observed, broader access was observed, the check was not run, or the result was inconclusive;
- minimum scopes required for the intended operation;
- whether API access is ready for read-only or publishing work;
- the host environment state, persisted-but-not-inherited or conflicting setting names, and the host-agnostic reload action;
- token-expiration/rotation actions still needing tracking.

Never include real credential values, Authorization headers, private account identifiers, tenant-specific content, or unrelated page data.
