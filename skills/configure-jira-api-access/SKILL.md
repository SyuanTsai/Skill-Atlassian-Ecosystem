---
name: configure-jira-api-access
description: Check and fix Jira Cloud API authentication without exposing credentials. Use when required environment settings are missing; a token, Cloud ID, or API URL is invalid; connectivity fails; or REST calls return authentication, authorization, or endpoint errors. Also use for GitHub Copilot IDE Jira environment setup and a read-only JQL readiness preflight.
license: Apache-2.0
---

# Configure Jira API Access

Guide the user from environment inventory to a verified read-only Jira Cloud connection. Keep credential values out of prompts, logs, repositories, command arguments, and responses. This Skill owns the shared Jira access and configuration behavior; host-specific Codex or GitHub Copilot discovery and reload behavior must not fork this shared core.

Before any Jira access, load [references/environment-separation.md](references/environment-separation.md) and resolve the environment. If the environment cannot be determined or signals conflict, stop and ask. If the resolved environment's required connection method fails, stop and report it without falling back to another method.

Read [references/configuration.md](references/configuration.md) before changing local configuration or diagnosing an HTTP failure. When the host is IDE GitHub Copilot, also read [references/copilot-ide.md](references/copilot-ide.md) to map the shared `HostReloadContract` to Copilot Skill discovery and host recreation. Use [scripts/Configure-JiraApiAccess.ps1](scripts/Configure-JiraApiAccess.ps1) as the canonical Fast Path for environment setup, Cloud ID discovery, API-base derivation, and hidden token input. Use [scripts/Test-JiraApiAccess.ps1](scripts/Test-JiraApiAccess.ps1) for deterministic redacted validation. Resolve the host-provided installed Skill root before invoking either helper; never let a consumer repository's `scripts/` directory supply the executable. Do not regenerate equivalent `Read-Host`, `SetEnvironmentVariable`, tenant lookup, Basic-auth, or validation PowerShell during the normal flow when these scripts are available. Load [references/shared-workflow.md](references/shared-workflow.md) before choosing Process or User scope, handling `HostReloadContract`, classifying an HTTP result, or preparing the completion report.

## Workflow

1. Establish the intended Jira operation and selected access path. The environment-separation reference determines whether REST API or an approved connector is allowed and prohibits silent fallback.
2. For REST API access, run `Test-JiraApiAccess.ps1` without `-TestConnection` to inspect whether `JIRA_BASE_URL`, `JIRA_EMAIL`, `JIRA_API_TOKEN`, `JIRA_CLOUD_ID`, and `JIRA_API_BASE_URL` are present and where they are defined. Never print the values.
3. Apply the shared workflow to report the redacted inventory, choose Process or User scope, and handle host reload.
4. If configuration must be created or repaired, invoke `Configure-JiraApiAccess.ps1` rather than constructing environment-setting commands ad hoc. Supply only the Jira site root, email, and requested `Process` or `User` scope. The script discovers Cloud ID from `/_edge/tenant_info`, derives the scoped base with scheme `https`, host api.atlassian.com, and base path `/ex/jira/{cloudId}`, reads the API token with hidden input, always configures its current Process for immediate validation, and invokes the validator.
5. Before token creation or rotation, show the minimum read-only scope checklist for the intended Jira operation. For the validator's identity plus issue and JQL reads, prefer classic `read:jira-user` and `read:jira-work`. If granular scopes are required, combine the documented identity scopes with the exact scopes for each selected GET endpoint; do not reuse POST-search scopes or assume the enhanced-JQL set covers a different endpoint. Do not request write scopes for read-only validation.
6. After the user approves read-only network access, use the Configure Fast Path with `-TestConnection` or invoke `Test-JiraApiAccess.ps1 -TestConnection`. Tenant identity must match before Basic authentication is sent to the scoped Jira API base.
7. To preflight the requested read endpoint, run the validator with a confirmed `-IssueKey`, a confirmed `-Jql`, or both. Keep `-MaxResults` at or below 100. These modes perform GET requests only and suppress response bodies. This readiness check does not replace the user-visible read through `work-with-jira`.
8. Apply the shared workflow as the single failure-classification and host-state rule.
9. In IDE GitHub Copilot, apply `references/copilot-ide.md` after any `reload-required` or `process-user-mismatch` result. Recreate the IDE or Copilot host as instructed, then rerun this same shared validator. Do not introduce a Copilot-only credential or REST validation implementation.
10. Before preparing the completion report, load the **Completion supplement** in [references/configuration.md](references/configuration.md). When validation succeeds, hand the requested Jira work to `work-with-jira`. Remain read-only unless the user separately and explicitly authorizes a write.

Before a Fast Path, load [references/host-resolved-fast-path.md](references/host-resolved-fast-path.md) and perform its installed-root, prefix, reparse-point, helper-existence, and no-token-in-arguments checks.

For diagnosis without changing configuration:

```powershell
pwsh -NoProfile -File $testScript
pwsh -NoProfile -File $testScript -TestConnection
pwsh -NoProfile -File $testScript -IssueKey 'DEMO-42'
pwsh -NoProfile -File $testScript -Jql 'project = DEMO ORDER BY created DESC' -MaxResults 20
```

## Stop Conditions

Stop and explain the next safe action when a credential would need to be displayed, logged, committed, or placed in a command argument; tenant identity is ambiguous; persistence lacks authorization; write scope is requested for a read-only task; or the Copilot host does not support Agent Skills. The shared workflow handles repeated authentication failures, and the environment-separation reference governs any connection-method change.
