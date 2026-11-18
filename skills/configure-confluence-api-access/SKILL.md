---
name: configure-confluence-api-access
description: Check and fix Confluence Cloud scoped API-token access without exposing credentials. Use when CONFLUENCE_* settings are missing or invalid before publishing, authentication returns 401 or 403, or the Cloud ID, scoped API base, and least-privilege reads need verification.
license: Apache-2.0
---

# Configure Confluence API Access

Guide the user from configuration inventory to a verified least-privilege Confluence Cloud connection. Keep credential values out of prompts, logs, repositories, command arguments, generated documents, and responses.

Before any Confluence access, load [references/environment-separation.md](references/environment-separation.md) and resolve the environment. If the environment cannot be determined or signals conflict, stop and ask. If the resolved environment's required connection method fails, stop and report it without falling back to another method.

Read [references/configuration.md](references/configuration.md) before changing configuration, creating or rotating a token, or diagnosing an HTTP failure. Use [scripts/Configure-ConfluenceApiAccess.ps1](scripts/Configure-ConfluenceApiAccess.ps1) as the canonical Fast Path for environment setup, Cloud ID discovery, API-base derivation, and hidden token input; use [scripts/Test-ConfluenceApiAccess.ps1](scripts/Test-ConfluenceApiAccess.ps1) for redacted inventory and read-only checks. Resolve the host-provided installed Skill root before invoking either helper; never let a consumer repository's `scripts/` directory supply the executable. Do not regenerate equivalent `Read-Host`, `SetEnvironmentVariable`, tenant lookup, Basic-auth, or validation PowerShell during the normal flow when these scripts are available. Load [references/shared-workflow.md](references/shared-workflow.md) before choosing Process or User scope, handling `HostReloadContract`, classifying an HTTP result, or preparing the completion report.

## Workflow

1. Establish the exact intended Confluence operation. For `publish-requirements-to-confluence`, build the minimum scope list from the actual API operations: read spaces, read pages, and create or update pages only when publishing is requested.
   For `manage-confluence-docs-as-code`, capture/preview requires page and space reads; attachment metadata requires `read:attachment:confluence`. Request `write:page:confluence` only for approved page execution. The official v1 binary attachment upload requires `read:content-details:confluence` and `write:attachment:confluence`; require those only when an approved plan contains upload. Keep the site, Cloud ID and API base identical across v1 and v2 paths.
2. Run `Test-ConfluenceApiAccess.ps1` without `-TestConnection` to inspect only whether `CONFLUENCE_BASE_URL`, `CONFLUENCE_EMAIL`, `CONFLUENCE_API_TOKEN`, `CONFLUENCE_CLOUD_ID`, and `CONFLUENCE_API_BASE_URL` are present and where they are defined. Validate non-secret shapes in memory; never print token values, lengths, hashes, prefixes, encoded forms, or Authorization headers.
3. Apply the shared workflow to report the redacted inventory, choose Process or User scope, and handle host reload.
4. If the REST API path is selected and configuration must be created or repaired, use `Configure-ConfluenceApiAccess.ps1` rather than constructing PowerShell setup commands ad hoc. Supply only the site base URL, email, and desired `Process` or `User` scope. The script performs unauthenticated `/_edge/tenant_info` discovery, validates the Cloud ID, derives the scoped base with scheme `https`, host api.atlassian.com, and base path `/ex/confluence/{cloudId}`, reads the token with hidden input, always configures its current Process for immediate validation, and invokes the validator.
5. Before token creation or rotation, show one complete minimum scope checklist for the intended operation. Prefer a single-purpose scoped token with an explicit expiration date. Never request credential material in chat; the helper must read the token through hidden input.
6. After the user approves a read-only connection check, use either the Configure Fast Path with `-TestConnection` or `Test-ConfluenceApiAccess.ps1 -TestConnection`. Tenant identity must match before credentials are sent. The validator then independently requests the spaces and pages endpoints and suppresses response bodies.
7. To evaluate least privilege, choose a documented, read-only Confluence endpoint that requires a scope intentionally omitted from this token, then pass only its relative `/wiki/api/...` path with `-OutOfScopeReadPath`. A `401` or `403` after both allowed requests succeed records the expected denial, but cannot by itself distinguish token scope from product permission; a `200` shows broader access than intended. Never use a mutating endpoint for this check.
8. Successful space and page reads validate authentication plus `read:space:confluence` and `read:page:confluence`. Do not claim `write:page:confluence` from read-only evidence; the publishing workflow must still verify destination permissions and use its explicit-write boundary.
9. Apply the shared workflow to interpret host state and failures. Before preparing the completion report, load the **Completion supplement** in [references/configuration.md](references/configuration.md). When read validation succeeds, return control to the selected `publish-requirements-to-confluence` or `manage-confluence-docs-as-code` workflow. The environment-separation reference remains authoritative for the selected connection method.

Resolve the installed Skill root supplied by the host, then bind each helper to that root before running a Fast Path. Read [references/host-resolved-fast-path.md](references/host-resolved-fast-path.md) for the required prefix, reparse-point, and helper-existence checks; the consumer repository must not supply these paths. Never place a real token in an argument.

For diagnosis without changing settings:

```powershell
pwsh -NoProfile -File $testScript
```

Connection and least-privilege check:

```powershell
pwsh -NoProfile -File $testScript -TestConnection -OutOfScopeReadPath <documented-read-only-relative-path>
```

## Minimum scopes for requirements publishing

Use granular scoped-token permissions aligned to the Confluence v2 endpoints actually used:

- space discovery: `read:space:confluence`
- page discovery and read: `read:page:confluence`
- page create or update: `write:page:confluence`

Do not request space-write or admin, attachment, restriction, delete, or unrelated scopes unless a separately authorized workflow actually needs them. Product-level space or page permissions still apply even when token scopes are present.

## Stop Conditions

Stop and explain the next safe action when a credential would need to be displayed, logged, committed, or placed in a command argument; the site, Cloud ID, or intended operation is ambiguous; organization policy does not approve API-token use; stronger scopes are required but not justified; or persistence or token rotation lacks authorization. The shared workflow handles repeated authentication failures, and the environment-separation reference governs any connection-method change.

## Error Handling

For HTTP errors, use the **Safe HTTP classification** section in [references/shared-workflow.md](references/shared-workflow.md) as the sole handling location.
