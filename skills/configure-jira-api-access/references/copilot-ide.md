<!--
SPDX-FileCopyrightText: 2026 SyuanTsai
SPDX-License-Identifier: Apache-2.0
-->

# GitHub Copilot IDE host adapter

This reference is host-specific. It consumes the shared Jira access behavior and `HostReloadContract` from `configure-jira-api-access`; it must not duplicate credential handling, Cloud ID discovery, API-base derivation, HTTP classification, or environment inheritance logic.

## Supported Skill locations

GitHub Copilot Agent Skills use the open Agent Skills format.

Project scope may load skills from:

- `.github/skills/<skill-name>/SKILL.md`
- `.agents/skills/<skill-name>/SKILL.md`
- `.claude/skills/<skill-name>/SKILL.md`

Personal scope may load skills from:

- `~/.copilot/skills/<skill-name>/SKILL.md`
- `~/.agents/skills/<skill-name>/SKILL.md`

Use a current GitHub Copilot host that supports Agent Skills. VS Code supports Agent Skills. For Visual Studio, verify the installed release against GitHub's current Copilot feature matrix before diagnosing Jira configuration; an IDE release without Agent Skills support is a host capability problem, not a Jira credential problem.

## Preferred installation

`gh skill` is currently a public-preview GitHub CLI feature and requires GitHub CLI 2.90.0 or later. Preview and install the same immutable reviewed revision. Use a trusted release tag or full commit SHA; for pre-merge acceptance, use the exact reviewed PR head SHA. An unpinned command can resolve a release or the default branch instead of the revision under review.

```powershell
$reviewedSkillRef = '<trusted-release-tag-or-full-commit-sha>'
gh --version
gh skill preview SyuanTsai/Skill-Atlassian-Ecosystem "configure-jira-api-access@$reviewedSkillRef"
gh skill preview SyuanTsai/Skill-Atlassian-Ecosystem "work-with-jira@$reviewedSkillRef"
```

Install that same revision at project scope from the target repository when the Jira workflow should be limited to that repository:

```powershell
gh skill install SyuanTsai/Skill-Atlassian-Ecosystem configure-jira-api-access --pin $reviewedSkillRef --agent github-copilot --scope project
gh skill install SyuanTsai/Skill-Atlassian-Ecosystem work-with-jira --pin $reviewedSkillRef --agent github-copilot --scope project
```

Verify that both installed `SKILL.md` files' injected source-tracking metadata identifies this repository and the same reviewed revision before starting E2E acceptance. Use `--scope user` when the same trusted Skills should be available across repositories, retaining the same `--pin`. Do not manually fork or copy only part of either Skill; keep `SKILL.md`, references, and scripts together.

## Discovery and reload

After installation or update, start a new Copilot Agent session. If the host was already running while Skills or User-scope environment settings changed, recreate or reload the host/session before changing Jira credentials again.

When the shared validator returns:

- `HostEnvironmentState = process-ready`: continue with Jira read validation.
- `HostEnvironmentState = reload-required`: User/Machine values exist but were not inherited by the current IDE/Copilot process. Recreate the IDE host process, then rerun the same validator.
- `HostEnvironmentState = process-user-mismatch`: the current process is using values that differ from persisted values. Treat the current Process as authoritative for the current session, recreate the host before expecting persisted values to take effect, and rerun the validator.

Always follow `HostReloadContract.RequiredAction`. `recreate-host-process` means the IDE/Copilot parent process must be recreated. A PowerShell process launched by Copilot is a child process and cannot repair the already-running parent by setting `$env:*`.

If `HostReloadContract.SecretInjectionRequired = true`, recreate the host through the approved secret-store/launcher path or repeat hidden token injection. Never place the token in a prompt, command argument, repository file, profile, or log.

## End-to-end proof

Use the installed `configure-jira-api-access` Skill to locate its own `scripts/Test-JiraApiAccess.ps1`; do not hardcode a repository checkout path. Run the shared validator from the Copilot-controlled environment:

```powershell
& $resolvedJiraValidator -TestConnection
& $resolvedJiraValidator -IssueKey 'DEMO-42'
& $resolvedJiraValidator -Jql 'project = DEMO ORDER BY created DESC' -MaxResults 20
```

The validator is a preflight: it proves tenant identity, authentication, endpoint availability, and redaction while intentionally suppressing response bodies. It does not replace the user-visible Jira workflow. After preflight succeeds, submit both of these user-confirmed requests in the same Copilot Agent session, replacing the placeholders only with authorized test data:

Issue read prompt:

```text
Use the installed `work-with-jira` Skill and the verified Jira REST path to read DEMO-42 from the authoritative configured Jira site. Return only its key, summary, status, and assignee. Perform no writes.
```

JQL read prompt:

```text
Use the installed `work-with-jira` Skill and the same verified Jira REST tenant to run `project = DEMO ORDER BY created DESC` with at most 20 results. Return only each issue's key, summary, and status. Perform no writes.
```

For the required reload lifecycle, use an already authorized User-scope configuration or obtain explicit authorization before persisting one; token entry must remain hidden. Start the IDE/Copilot host before those User-scope values are created or changed. From that still-running Copilot host, rerun the installed validator in a new child shell and observe `HostEnvironmentState = reload-required` with no network request. Follow `HostReloadContract`, fully recreate the IDE/Copilot host, start a new Agent session, and rerun the same validator until the Process values are inherited and the requested read succeeds. A mocked environment reader, a unit-test double, or restarting only the child shell does not satisfy this final acceptance step. If the real lifecycle cannot be performed safely, record the IDE E2E as incomplete.

The acceptance proof requires all of the following from the IDE Copilot host:

1. Both installed Skills' source-tracking metadata matches the repository and immutable revision that was reviewed and previewed.
2. Each Skill is discoverable and the Jira setup Skill's bundled script can be resolved relative to its installed Skill directory.
3. Tenant identity and `/rest/api/3/myself` succeed.
4. The issue prompt runs through the installed `work-with-jira` Skill, targets the authoritative tenant, and the returned issue fields contain only the requested key, summary, status, and assignee.
5. The JQL prompt runs through the installed `work-with-jira` Skill against the same tenant, remains bounded to 20 results, and the returned JQL result fields contain only the requested key, summary, and status.
6. Both workflow requests remain read-only. The validator output remains redacted and suppresses response bodies; the workflow exposes only the requested fields rather than a complete response body.
7. A persisted-but-not-inherited environment scenario is observed in the actual IDE/Copilot host, classified as `reload-required` without a network request, and succeeds only after that host is recreated. Automated tests remain prerequisite evidence but cannot replace this lifecycle proof.

## Access-path rule

If the user selected Jira REST API for the Copilot session, stay on that path. Do not fall back to Rovo, MCP, or another connector because the IDE environment needs a reload. If the user selected a connector, do not force environment-token setup.
