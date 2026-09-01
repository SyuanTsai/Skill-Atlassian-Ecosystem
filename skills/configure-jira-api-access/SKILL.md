---
name: configure-jira-api-access
description: Check and fix Jira Cloud API authentication without exposing credentials. Use when required environment settings are missing; a token, Cloud ID, or API URL is invalid; connectivity fails; or REST calls return authentication, authorization, or endpoint errors.
---

# Configure Jira API Access

Guide the user from environment inventory to a verified read-only Jira Cloud connection. Keep credential values out of prompts, logs, repositories, command arguments, and responses. This Skill owns the shared Jira access/configuration behavior; host-specific Codex or GitHub Copilot discovery/reload behavior must not fork this shared core.

Read [references/configuration.md](references/configuration.md) before changing local configuration or diagnosing an HTTP failure. When the host is IDE GitHub Copilot, also read [references/copilot-ide.md](references/copilot-ide.md) to map the shared `HostReloadContract` to Copilot Skill discovery and host recreation. Use [scripts/Configure-JiraApiAccess.ps1](scripts/Configure-JiraApiAccess.ps1) as the canonical Fast Path for environment setup, Cloud ID discovery, API-base derivation, and hidden token input. Use [scripts/Test-JiraApiAccess.ps1](scripts/Test-JiraApiAccess.ps1) for deterministic redacted validation. Do not regenerate equivalent `Read-Host`, `SetEnvironmentVariable`, tenant lookup, Basic-auth, or validation PowerShell during the normal flow when these scripts are available.

## Workflow

1. Establish the intended Jira operation and selected access path. If the user selects REST API, stay on REST API; if the user selects an approved connector, stay on the connector. Do not silently fall back between them.
2. For REST API access, run `Test-JiraApiAccess.ps1` without `-TestConnection` to inspect whether `JIRA_BASE_URL`, `JIRA_EMAIL`, `JIRA_API_TOKEN`, `JIRA_CLOUD_ID`, and `JIRA_API_BASE_URL` are present and where they are defined. Never print the values.
3. Report a redacted inventory with purpose, presence, source scope, and validation result. Distinguish Process, User, Machine, secret-store injection, and unknown sources.
4. If configuration must be created or repaired, invoke `Configure-JiraApiAccess.ps1` rather than constructing environment-setting commands ad hoc. Supply only the Jira site root, email, and requested `Process` or `User` scope. The script discovers Cloud ID from `/_edge/tenant_info`, derives `https://api.atlassian.com/ex/jira/{cloudId}`, reads the API token with hidden input, always configures its current Process for immediate validation, and invokes the validator.
5. Use `Process` scope by default. Use `User` scope only after explaining persistence and obtaining authorization; this adds User persistence to the current Process setup. Persisting the token to User scope additionally requires `-PersistTokenToUser`; otherwise the token remains Process-scoped.
6. Before token creation or rotation, show the minimum read-only scope checklist for the intended Jira operation. For the validator's identity plus issue/JQL reads, prefer classic `read:jira-user` and `read:jira-work`. If granular scopes are required, combine the documented identity scopes with the exact scopes for each selected GET endpoint; do not reuse POST-search scopes or assume the enhanced-JQL set covers a different endpoint. Do not request write scopes for read-only validation.
7. After the user approves read-only network access, use the Configure Fast Path with `-TestConnection` or invoke `Test-JiraApiAccess.ps1 -TestConnection`. Tenant identity must match before Basic authentication is sent to the scoped Jira API base.
8. To prove the requested read path, run the validator with a confirmed `-IssueKey`, a confirmed `-Jql`, or both. Keep `-MaxResults` at or below 100. These modes perform GET requests only and suppress response bodies.
9. Classify failures safely: `400` request/configuration, `401` authentication, `403` authorization/scope, `404` endpoint/resource, `429` rate-limit, `5xx` service unavailable, and transport/network/TLS separately.
10. Treat Process scope as the only effective environment for connection validation. If required settings exist only in User/Machine scope, report `HostEnvironmentState = reload-required`, list `PersistedButNotInheritedSettings`, and do not make a request. If Process and User values differ, validate the current Process values but report `process-user-mismatch`. Follow `HostReloadContract.RequiredAction = recreate-host-process`; when `SecretInjectionRequired` is true, recreate it through the approved secret source named by the contract. Never try to update the parent Agent by setting `$env:*` in a child shell.
11. In IDE GitHub Copilot, apply `references/copilot-ide.md` after any `reload-required` or `process-user-mismatch` result. Recreate the IDE/Copilot host as instructed, then rerun this same shared validator. Do not introduce a Copilot-only credential or REST validation implementation.
12. When validation succeeds, hand the requested Jira work to `work-with-jira`. Remain read-only unless the user separately and explicitly authorizes a write.

Canonical Fast Path examples use placeholders only; never place a real token in an argument:

```powershell
pwsh -NoProfile -File ./.agents/skills/configure-jira-api-access/scripts/Configure-JiraApiAccess.ps1 -BaseUrl 'https://<site>.atlassian.net' -Email '<account-email>' -TargetScope Process -TestConnection
pwsh -NoProfile -File ./.agents/skills/configure-jira-api-access/scripts/Configure-JiraApiAccess.ps1 -BaseUrl 'https://<site>.atlassian.net' -Email '<account-email>' -TargetScope User -PersistTokenToUser -TestConnection
```

For diagnosis without changing configuration:

```powershell
pwsh -NoProfile -File ./.agents/skills/configure-jira-api-access/scripts/Test-JiraApiAccess.ps1
pwsh -NoProfile -File ./.agents/skills/configure-jira-api-access/scripts/Test-JiraApiAccess.ps1 -TestConnection
pwsh -NoProfile -File ./.agents/skills/configure-jira-api-access/scripts/Test-JiraApiAccess.ps1 -IssueKey 'DEMO-42'
pwsh -NoProfile -File ./.agents/skills/configure-jira-api-access/scripts/Test-JiraApiAccess.ps1 -Jql 'project = DEMO ORDER BY created DESC' -MaxResults 20
```

## Error Handling

- `400`: validate request construction and configuration without exposing inputs.
- `401`: verify token type, account email, expiration/revocation, and scoped-token endpoint selection.
- `403`: authentication may work; verify token scope, Jira product access, and account permissions.
- `404`: verify Cloud ID, API path, issue key, or resource visibility without guessing.
- `429`: respect server backoff; do not loop aggressively.
- `5xx`: report service unavailability separately from credential failure.
- Network/TLS failure: separate proxy, DNS, certificate, or network policy failures from authentication failure.

## Stop Conditions

Stop and explain the next safe action when a credential would need to be displayed, logged, committed, or placed in a command argument; tenant identity is ambiguous; the selected access path would need to change without user authorization; persistence lacks authorization; write scope is requested for a read-only task; the Copilot host does not support Agent Skills; or repeated authentication failures remain after safe endpoint and configuration checks.

## Completion Report

Report in the user's language:

- each required variable's presence, source scope, and validation state;
- whether Jira site, Cloud ID, and scoped API base identify the same tenant;
- the identity/issue/JQL endpoint categories tested and HTTP status;
- whether the requested read path is ready;
- the host environment state, persisted-but-not-inherited or conflicting setting names, and the host-agnostic reload action;
- for IDE GitHub Copilot, whether Skill discovery and host recreation were completed before the successful rerun;
- any remaining token scope, expiration, or policy action.

Never include real credential values, Authorization headers, complete API response bodies, private account identifiers, or unrelated Jira data.
