# Skill-Atlassian-Ecosystem

Canonical source for the Atlassian ecosystem Agent Skills used across Jira, Confluence, and Bitbucket workflows.

Stable source ID: `atlassian-ecosystem`

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

Preview before installation:

```powershell
gh --version
gh skill preview SyuanTsai/Skill-Atlassian-Ecosystem configure-jira-api-access
gh skill preview SyuanTsai/Skill-Atlassian-Ecosystem work-with-jira
```

Project scope:

```powershell
gh skill install SyuanTsai/Skill-Atlassian-Ecosystem configure-jira-api-access --agent github-copilot --scope project
gh skill install SyuanTsai/Skill-Atlassian-Ecosystem work-with-jira --agent github-copilot --scope project
```

Use `--scope user` for personal installation across trusted repositories. Use a current Copilot host with Agent Skills support: VS Code supports Agent Skills; for Visual Studio, verify the installed release against GitHub's current Copilot feature matrix before debugging Jira access.

After Skill installation or User-scope environment changes, start a new Copilot Agent session. If `Test-JiraApiAccess.ps1` returns `reload-required` or `process-user-mismatch`, follow its `HostReloadContract`: recreate the IDE/Copilot host, restore the token through the approved secret source when required, then rerun the same shared validator. Do not regenerate a second Copilot-specific Fast Path.

The host-specific acceptance path is documented in `skills/configure-jira-api-access/references/copilot-ide.md`. Final IDE validation must prove tenant identity, one Jira issue read, one bounded JQL read, and one persisted-but-not-inherited → host recreation → successful rerun scenario without exposing credentials.

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

## Source metadata

`catalog/source.json` identifies this repository as stable source `atlassian-ecosystem`. Consumers should pin an immutable tag/commit/content hash according to the parent Catalog/Lock contract rather than tracking mutable latest content directly.
