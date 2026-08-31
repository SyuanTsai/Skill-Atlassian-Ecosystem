---
name: configure-confluence-api-access
description: Check, configure, and safely validate Confluence Cloud scoped API-token access without exposing credentials. Use when Confluence API settings are missing or invalid, authentication fails, Cloud ID or scoped API base must be resolved, or publish-requirements-to-confluence needs API access.
---

# Configure Confluence API Access

Guide the user from configuration inventory to a verified least-privilege Confluence Cloud connection. Keep credential values out of prompts, logs, repositories, command arguments, generated documents, and responses.

Read [references/configuration.md](references/configuration.md) before proposing commands, changing configuration, creating or rotating a token, or diagnosing an HTTP failure.

## Workflow

1. Establish the exact intended Confluence operation. For `publish-requirements-to-confluence`, build the minimum scope list from the actual API operations: read spaces, read pages, and create/update pages only when publishing is requested.
2. Inspect only whether `CONFLUENCE_BASE_URL`, `CONFLUENCE_EMAIL`, `CONFLUENCE_API_TOKEN`, `CONFLUENCE_CLOUD_ID`, and `CONFLUENCE_API_BASE_URL` are present and where they are defined. Validate non-secret shapes in memory; never print token values, lengths, hashes, prefixes, encoded forms, or Authorization headers.
3. Report a redacted inventory with purpose, presence, source scope, and validation result. Distinguish Process, User, Machine, secret-store injection, and unknown sources.
4. Resolve missing or invalid settings in dependency order: site base URL, account email, Cloud ID, scoped API base URL, then token.
5. If `CONFLUENCE_CLOUD_ID` is absent, use `${CONFLUENCE_BASE_URL}/_edge/tenant_info` as a read-only tenant lookup, extract only `cloudId`, validate it as a UUID, and derive `CONFLUENCE_API_BASE_URL` as `https://api.atlassian.com/ex/confluence/{cloudId}`. Never guess either value.
6. Before token creation or rotation, show one complete minimum scope checklist for the intended operation. Prefer a single-purpose scoped token with an explicit expiration date. Do not ask the user to paste the token into chat.
7. Before persisting or replacing a setting, explain the target storage scope and obtain explicit authorization. Prefer session-only injection or an approved secret manager; never write credentials to a repository, shell history, transcript, profile, generated document, Jira, or Confluence.
8. Offer the smallest useful authenticated read-only validation using `${CONFLUENCE_API_BASE_URL}/wiki/api/v2/spaces?limit=1`. Construct Basic authentication from `CONFLUENCE_EMAIL:CONFLUENCE_API_TOKEN` only in memory. Do not return the response body.
9. A `200` validates authentication and the read-space path only. Before page work, verify `read:page:confluence`; before create/update, verify `write:page:confluence` and the destination's Confluence permissions.
10. When validation succeeds, return control to `publish-requirements-to-confluence`. That skill retains its preview, destination, draft-conflict, version, and explicit-write authorization requirements.

## Minimum scopes for requirements publishing

Use granular scoped-token permissions aligned to the Confluence v2 endpoints actually used:

- space discovery: `read:space:confluence`
- page discovery/read: `read:page:confluence`
- page create/update: `write:page:confluence`

Do not request space-write/admin, attachment, restriction, delete, or unrelated scopes unless a separately authorized workflow actually needs them. Product-level space/page permissions still apply even when token scopes are present.

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
- whether the scoped API base matches the validated Cloud ID;
- the read-only endpoint category tested and HTTP status;
- minimum scopes required for the intended operation;
- whether API access is ready for read-only or publishing work;
- token-expiration/rotation actions still needing tracking.

Never include real credential values, Authorization headers, private account identifiers, tenant-specific content, or unrelated page data.