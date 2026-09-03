<!--
SPDX-FileCopyrightText: 2026 SyuanTsai
SPDX-License-Identifier: Apache-2.0
-->

# Jira API access configuration

## Required settings

| Variable | Meaning | Safe validation |
| --- | --- | --- |
| `JIRA_BASE_URL` | Browser-facing Jira Cloud site URL | Absolute HTTPS URL; normally an `*.atlassian.net` host |
| `JIRA_EMAIL` | Atlassian account email associated with the token | Non-empty email-shaped value |
| `JIRA_API_TOKEN` | Jira API token | Presence only; token length is variable and must not be used for validation |
| `JIRA_CLOUD_ID` | Jira Cloud tenant identifier | UUID returned by `/_edge/tenant_info` |
| `JIRA_API_BASE_URL` | REST base for a scoped Jira token | Exactly `https://api.atlassian.com/ex/jira/{JIRA_CLOUD_ID}` after trimming a trailing slash |

Treat the values as configuration only after confirming their source scope. Process-scoped values can make the current tool work but do not prove User- or Machine-level persistence.

## Canonical Fast Path

Use `scripts/Configure-JiraApiAccess.ps1` for normal setup or repair. It validates the site root and email, discovers Cloud ID without credentials, derives the scoped API base, reads the token with hidden input, and invokes the deterministic validator. Do not regenerate equivalent environment-setting, tenant-discovery, Basic-auth, or validation snippets while this script is available.

The Fast Path always writes every required setting to its current Process so validation can run immediately. `-TargetScope User` additionally persists non-secret values on Windows; the token is persisted only when the user separately authorizes `-PersistTokenToUser`. User persistence never updates an already-running parent Agent process.

## Safe inspection

Inspect presence without expanding values. On Windows, query Process, User, and Machine scopes independently with `System.Environment.GetEnvironmentVariable`. On Unix-like systems, inspect the current process environment and any approved secret-store integration; do not search shell history or broadly scan home directories.

Search a known configuration file only when necessary and return the file path plus matched variable names, never matching lines. Do not inspect unrelated files to infer where a token came from. If the source cannot be established safely, report it as unknown.

Validate URLs with a URI parser and compare normalized scheme, host, and path components. Do not use token length, prefixes, hashes, partial characters, or Base64 output as diagnostics.

## Token creation and injection

Before token creation, prepare one complete permission checklist. Include the minimum scopes for the intended Jira operations plus the scope required by this skill's identity check:

- classic scope: `read:jira-user`; or
- granular scopes: `read:application-role:jira`, `read:group:jira`, `read:user:jira`, and `read:avatar:jira`.

For the validator's enhanced JQL `GET /rest/api/3/search/jql` request, also include either classic `read:jira-work` or all of these granular query scopes: `read:issue-details:jira`, `read:audit-log:jira`, `read:avatar:jira`, `read:field-configuration:jira`, and `read:issue-meta:jira`. These are endpoint-specific: the enhanced-search POST operation has a different granular set, and issue-by-key scopes can depend on the requested fields. Verify every selected GET operation against Atlassian's current REST reference instead of reusing another endpoint's list.

Have the user create or rotate a scoped API token in [Atlassian account security settings](https://id.atlassian.com/manage-profile/security/api-tokens) and select every scope on that checklist. Do not create a token without the identity-check scope and then diagnose `/myself` as a credential failure. Save the token in an approved password or secret manager; it cannot be recovered later. Use Atlassian's [API token guidance](https://support.atlassian.com/atlassian-account/docs/manage-api-tokens-for-your-atlassian-account/) when the UI or token behavior has changed.

Do not accept the token in chat. If interactive session injection is appropriate, read it without terminal echo and place it only in the current process environment. Clear temporary variables after assignment. Do not persist it to User or Machine environment storage unless the user explicitly authorizes that security tradeoff.

Changing a token, its scopes, or its expiration is an external account mutation. Explain the action and wait for explicit user authorization before performing any supported mutation; otherwise guide the user through Atlassian's UI.

## Cloud ID discovery

When `JIRA_BASE_URL` is known but the Cloud ID is missing, request:

```text
GET ${JIRA_BASE_URL}/_edge/tenant_info
Accept: application/json
```

Read only the `cloudId` field, validate it as a UUID, and construct:

```text
https://api.atlassian.com/ex/jira/{cloudId}
```

For scoped API tokens, use that base for Jira `/rest/api/3/...` and `/rest/agile/1.0/...` requests. Do not send those scoped-token requests to the site-specific base URL.

## Read-only connection test

Test the smallest useful authenticated request:

```text
GET ${JIRA_API_BASE_URL}/rest/api/3/myself
Accept: application/json
Authorization: Basic <in-memory base64 of JIRA_EMAIL:JIRA_API_TOKEN>
```

Construct the header in memory from environment or secret-store values. Never echo the input, header, encoded credential, or response body. Clear temporary credential buffers and variables when the tool permits it.

Interpret results conservatively:

| Result | Meaning and next action |
| --- | --- |
| `200` | Authentication and this endpoint are valid; separately verify scopes needed by the intended operation |
| `400` | Check URL construction and request format without exposing inputs |
| `401` | Check token type, account email, expiration or revocation, and use of the scoped-token base URL |
| `403` | Authentication may work; verify that the token was created with `read:jira-user` or all four documented granular `/myself` scopes, then check product access and account permissions |
| `404` | Check Cloud ID, API base path, and resource path |
| `429` | Respect `Retry-After`; do not loop aggressively |
| Network/TLS failure | Separate local network or proxy failure from Jira credential failure |

Return only the HTTP status, failure category, and redacted remediation. Do not return the Jira response body unless the user needs a specific non-sensitive field and its disclosure is justified.

## Environment inheritance and host reload

The validator inventories Process, User, and Machine scopes but uses only Process values for tenant and authenticated requests:

- `process-ready`: every required Process value is present and agrees with persisted values.
- `reload-required`: every missing Process value exists in User or Machine scope. No request is sent.
- `process-user-mismatch`: Process is complete, but at least one persisted value differs. The current Process can be tested, while a future host may inherit different values.
- `incomplete`: at least one required Process value is absent and has no persisted candidate.

`HostReloadContract` version 1 is shared across Agent hosts. When `Required` is true, `RequiredAction` is `recreate-host-process`, `ParentProcessMutationSupported` is false, and the adapter reruns the validator after reload. If the token was not persisted, `SecretInjectionRequired` is true and `SecretSourceRequired` is `approved-secret-store-or-hidden-input`; do not assume a restart alone will supply it. For Codex, fully exit and relaunch Codex with the required secret injection from an environment that can see the intended User values. GitHub Copilot IDE support consumes the same contract through its own host adapter; it must not fork credential, tenant, classification, or inheritance logic.
