<!--
SPDX-FileCopyrightText: 2026 SyuanTsai
SPDX-License-Identifier: Apache-2.0
-->

# Skill-Atlassian-Ecosystem

Canonical source for the Atlassian ecosystem Agent Skills used across Jira, Confluence, and Bitbucket workflows.

Stable source ID: `atlassian-ecosystem`

## License and provenance

The repository-authored Skills, scripts, tests, documentation, catalog metadata, and workflow configuration are licensed under [Apache-2.0](LICENSE). See [NOTICE](NOTICE) for attribution, [PROVENANCE.md](PROVENANCE.md) for the public source and licensing boundary, and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for external dependencies.

External services, trademarks, credentials, tenant data, and user content are not included in this license grant. SPDX headers and [REUSE.toml](REUSE.toml) identify the licensing information for distributed files.

## Skills

- `configure-bitbucket-api-access`
- `configure-confluence-api-access`
- `configure-jira-api-access`
- `publish-requirements-to-confluence`
- `review-bitbucket-pull-request`
- `work-with-jira`

## Stable PowerShell access commands

The three API-access Skills ship canonical PowerShell entry points. Agents should invoke these scripts instead of regenerating equivalent environment, token-input, Cloud-ID discovery, authentication, or validation snippets on every run.

Canonical source lives under `skills/`. The bootstrap/catalog layer installs managed runtime copies under the consumer repository's ignored `.agents/skills/` path.

```text
skills/
  configure-bitbucket-api-access/scripts/
    Configure-BitbucketApiAccess.ps1
    Test-BitbucketApiAccess.ps1
  configure-confluence-api-access/scripts/
    Configure-ConfluenceApiAccess.ps1
    Test-ConfluenceApiAccess.ps1
  configure-jira-api-access/scripts/
    Configure-JiraApiAccess.ps1
    Test-JiraApiAccess.ps1
```

The `Configure-*` commands are the Fast Path for setup/repair. They use hidden token input and default to Process scope. Every run configures its current Process; User-scope persistence is additive and explicit, and token persistence requires the separate `-PersistTokenToUser` switch. Jira and Confluence automatically discover the tenant Cloud ID and derive the scoped API base. `Test-*` commands are read-only diagnostic/validation entry points and suppress credential/response-body output.

Connection validation uses only the effective Process environment. User/Machine-only values produce `HostEnvironmentState = reload-required` without a network request; differing Process/User values produce `process-user-mismatch` while the current Process is validated. `HostReloadContract` version 1 returns the host-neutral `recreate-host-process` action and records that child-to-parent environment mutation is unsupported. Codex and IDE adapters map that action to their own restart/reload behavior, then rerun the same validator.

## IDE GitHub Copilot: Jira read-only access

The Jira Skills remain one canonical Agent Skills source for Codex and IDE GitHub Copilot. There is no Copilot-only fork of the access scripts or credential logic.

GitHub Copilot project Skills may be installed under `.github/skills`, `.agents/skills`, or `.claude/skills`; personal Skills may be installed under `~/.copilot/skills` or `~/.agents/skills`. `gh skill` can install from this repository and automatically select the host directory. It is currently a public-preview GitHub CLI feature and requires GitHub CLI 2.90.0 or later.

Preview and install the same immutable reviewed revision. Set the value to a trusted release tag or full commit SHA; for pre-merge acceptance, use the exact reviewed PR head SHA. Unpinned commands can resolve a release or the default branch instead of the revision under review.

```powershell
$reviewedSkillRef = '<trusted-release-tag-or-full-commit-sha>'
gh --version
gh skill preview SyuanTsai/Skill-Atlassian-Ecosystem "configure-jira-api-access@$reviewedSkillRef"
gh skill preview SyuanTsai/Skill-Atlassian-Ecosystem "work-with-jira@$reviewedSkillRef"
```

Project scope, pinned to that same revision:

```powershell
gh skill install SyuanTsai/Skill-Atlassian-Ecosystem configure-jira-api-access --pin $reviewedSkillRef --agent github-copilot --scope project
gh skill install SyuanTsai/Skill-Atlassian-Ecosystem work-with-jira --pin $reviewedSkillRef --agent github-copilot --scope project
```

Before E2E acceptance, verify that both installed `SKILL.md` files' injected source-tracking metadata identifies this repository and the same reviewed revision. Use `--scope user` for personal installation across trusted repositories while retaining the same `--pin`. Use a current Copilot host with Agent Skills support: VS Code supports Agent Skills; for Visual Studio, verify the installed release against GitHub's current Copilot feature matrix before debugging Jira access.

After Skill installation or User-scope environment changes, start a new Copilot Agent session. If `Test-JiraApiAccess.ps1` returns `reload-required` or `process-user-mismatch`, follow its `HostReloadContract`: recreate the IDE/Copilot host, restore the token through the approved secret source when required, then rerun the same shared validator. Do not regenerate a second Copilot-specific Fast Path.

The host-specific acceptance path is documented in `skills/configure-jira-api-access/references/copilot-ide.md`. Final IDE validation must prove that the installed `work-with-jira` Skill returns the requested fields for one Jira issue and one bounded JQL read, and that a persisted-but-not-inherited configuration recovers through the actual IDE/Copilot host lifecycle without exposing credentials.

## Access-path boundary

Connector and REST API paths are separate. Once the user selects one path for the current operation, Skills must not silently fall back to the other after a failure. Connector availability does not invalidate a user-selected REST path, and environment-token presence does not force REST when the user selected a connector.

## Credential boundary

Jira, Confluence, and Bitbucket credentials are separately scoped. Tokens must be read only from approved environment variables, hidden interactive input, or an approved secret store. Never print, log, commit, embed in command arguments, or copy credentials into Jira/Confluence content.

## Repository validation

Run:

```powershell
pwsh -NoProfile -File ./tests/validate-repository.ps1
pwsh -NoProfile -File ./tests/validate-api-access.ps1
```

The repository contract validates exactly the expected six Atlassian ecosystem Skills, required metadata/references, all canonical Configure/Test scripts, product-specific safety and permission boundaries, deterministic API failure classifications, secret redaction under PowerShell 7 and Windows PowerShell 5.1, and the GitHub Copilot Jira host-adapter documentation contract.

Licensing checks also verify the required documents, catalog and Skill license declarations, and SPDX/REUSE coverage, including the Copilot host-adapter reference.

## Source metadata

`catalog/source.json` identifies this repository as stable source `atlassian-ecosystem`. Consumers should pin an immutable tag/commit/content hash according to the parent Catalog/Lock contract rather than tracking mutable latest content directly.
