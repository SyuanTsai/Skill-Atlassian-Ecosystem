---
name: configure-jira-api-access
description: Check, fix, test, and update authentication for Atlassian Cloud issue operations without exposing credentials. Use when the user needs to inspect missing settings, find a Cloud ID, rotate a token safely, or validate connectivity before working with Jira.
---

# Configure Jira API Access

Guide the user one safe step at a time from configuration inventory to a verified read-only Jira Cloud connection. Keep credential values out of prompts, logs, repositories, command arguments, and responses.

Read [references/configuration.md](references/configuration.md) before proposing commands, changing local configuration, or diagnosing an HTTP failure.

## Workflow

1. Establish the intended Jira operation and whether the token is scoped. Before the user creates or rotates a token, build the minimum scope list for that operation and include the identity-validation scope required by `/rest/api/3/myself`: classic `read:jira-user`, or all granular scopes `read:application-role:jira`, `read:group:jira`, `read:user:jira`, and `read:avatar:jira`.
2. Inspect only whether the five required environment variables are present and where they are defined. Validate their shapes in memory; never print their values, lengths, hashes, encoded forms, or complete URLs containing private tenant details.
3. Report a redacted inventory with one row per variable: purpose, presence, source scope, and validation result. Distinguish Process, User, Machine, secret-store injection, and unknown sources. Do not claim persistence when a value exists only in the current process.
4. Resolve missing or invalid settings in dependency order:
   - `JIRA_BASE_URL`
   - `JIRA_EMAIL`
   - `JIRA_API_TOKEN`
   - `JIRA_CLOUD_ID`
   - `JIRA_API_BASE_URL`
5. Ask for at most one missing user decision or user-supplied setting at a time. Before directing the user to create the token, show the complete required scope checklist, including the `/myself` scope above, and have the user select those permissions in Atlassian's account UI. Never ask the user to paste a token into chat; let the user inject it privately into the environment or an approved secret store.
6. Before persisting or replacing any setting, explain the target scope and obtain explicit authorization. Prefer session-only injection or an approved secret manager. Never write credentials to a repository, shell history, profile, transcript, or ordinary config file.
7. If `JIRA_CLOUD_ID` is absent, make the unauthenticated read-only request `${JIRA_BASE_URL}/_edge/tenant_info`, extract only `cloudId`, verify it is a UUID, and construct `JIRA_API_BASE_URL` as `https://api.atlassian.com/ex/jira/{cloudId}`. Do not guess either value.
8. Check that all values are coherent, then offer a read-only authenticated request to `${JIRA_API_BASE_URL}/rest/api/3/myself`. Build Basic authentication from `JIRA_EMAIL:JIRA_API_TOKEN` only in memory and discard temporary credential data afterward.
9. Report only success or a safely redacted failure category. A `200` verifies authentication and access to that endpoint, but not every scope required by future Jira operations.
10. When validation succeeds, hand the requested Jira work to `work-with-jira`. Default that work to read-only unless the user explicitly authorizes a write.

## Example

```text
User request:
"My Jira API calls return 401. Check my setup without showing any secret values."

Expected workflow:
1. Report only whether each required environment variable is present and where it is defined.
2. Verify the site, Cloud ID, API base URL, and minimum token scopes.
3. Offer a read-only /rest/api/3/myself check after explicit approval.
4. Return a redacted diagnosis and the next safe action.
```

Example redacted inventory:

```text
JIRA_BASE_URL     present  User     valid site URL
JIRA_EMAIL        present  Process  valid shape
JIRA_API_TOKEN    present  Secret   not displayed
JIRA_CLOUD_ID     missing  —        discover with tenant_info
JIRA_API_BASE_URL missing  —        derive after Cloud ID validation
```

## Error Handling

- If authentication returns `401`, verify endpoint selection, credential presence, and token shape without displaying secret material; do not assume the token itself is invalid until those checks pass.
- If access returns `403`, distinguish authentication success from missing permission or scope and report only the required permission category.
- If `tenant_info` fails or returns an invalid Cloud ID, stop instead of guessing the API base URL.
- If persistence would write a secret to an unsafe location, keep the value session-only or require an approved secret store.
- If repeated `401` or `403` responses persist after safe endpoint and scope checks, stop and require a token or policy review rather than cycling credentials blindly.

## Stop Conditions

Stop and explain the next safe action when:

- a credential would need to be displayed, logged, committed, or passed in a command argument;
- the Jira site, account, Cloud ID, or target operation is ambiguous;
- organization policy does not approve API-token use or the selected secret store;
- resolving the problem would require changing token scopes, replacing a token, or persisting settings without user authorization;
- repeated requests return `401` or `403` after endpoint and credential-shape checks.

## Completion Report

Report in the user's language:

- each required variable's presence, source scope, and validation state;
- whether the API base matches the Cloud ID;
- the read-only endpoint tested and its HTTP status;
- whether access is ready for the intended operation;
- missing permissions, persistence limitations, or actions the user still needs to complete.

Never include real credential values, private account identifiers, or tenant-specific URLs in the report.
