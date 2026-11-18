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
| `JIRA_API_BASE_URL` | REST base for a scoped Jira token | Exactly scheme `https`, host `api.atlassian.com`, and base path `/ex/jira/{JIRA_CLOUD_ID}` after trimming a trailing slash |

Treat the values as configuration only after confirming their source scope. Load [the shared API access workflow](shared-workflow.md) for Process or User scope, environment inheritance, host reload, HTTP classification, and completion reporting.

Before choosing a persistence scope, load [manual persistence on Linux and macOS](manual-persistence-linux-macos.md). `-TargetScope User` persists non-secret values on Windows only; on Linux and macOS, the configure helper supports only the current Process.

## Completion supplement

For IDE GitHub Copilot, in addition to the shared completion report, record whether Copilot Skill discovery and any required host recreation were completed before the successful validator rerun. Do not report the Copilot path ready when the successful rerun did not follow those required steps.

## Canonical Fast Path

Use `scripts/Configure-JiraApiAccess.ps1` for normal setup or repair. It validates the site root and email, discovers Cloud ID without credentials, derives the scoped API base, reads the token with hidden input, and invokes the deterministic validator. Do not regenerate equivalent environment-setting, tenant-discovery, Basic-auth, or validation snippets while this script is available.

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

The scoped Jira REST base has scheme `https`, host `api.atlassian.com`, and base path `/ex/jira/{cloudId}`.

For scoped API tokens, use that base for Jira `/rest/api/3/...` and `/rest/agile/1.0/...` requests. Do not send those scoped-token requests to the site-specific base URL.

## Read-only connection test

Test the smallest useful authenticated request:

```text
GET ${JIRA_API_BASE_URL}/rest/api/3/myself
Accept: application/json
Authorization: Basic <in-memory base64 of JIRA_EMAIL:JIRA_API_TOKEN>
```

Construct the header in memory from environment or secret-store values. Never echo the input, header, encoded credential, or response body. Clear temporary credential buffers and variables when the tool permits it.

Apply the shared workflow's classifications. For Jira-specific remediation, verify scoped-token base selection on authentication failure, first verify the identity and endpoint scopes and then check product access and account permissions on authorization failure, and verify the Cloud ID, API path, issue key, and resource visibility without guessing on not-found results.
