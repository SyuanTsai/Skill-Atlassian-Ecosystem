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

```text
.agents/skills/
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

The `Configure-*` commands are the Fast Path for setup/repair. They use hidden token input and default to Process scope. User-scope persistence is explicit, and token persistence requires the separate `-PersistTokenToUser` switch. Jira and Confluence automatically discover the tenant Cloud ID and derive the scoped API base. `Test-*` commands are read-only diagnostic/validation entry points and suppress credential/response-body output.

When a Configure command writes User-scope values, the returned result marks `HostReloadRequired`. Existing Codex, Visual Studio, VS Code, or other Agent host processes do not automatically inherit environment values written after they started; restart/reload the host instead of trying to mutate the parent process from a child PowerShell.

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

The repository contract validates exactly the expected six Atlassian ecosystem Skills, required metadata/references, all canonical Configure/Test scripts, product-specific safety and permission boundaries, deterministic API failure classifications, and secret redaction under PowerShell 7 and Windows PowerShell 5.1 in CI.

## Source metadata

`catalog/source.json` identifies this repository as stable source `atlassian-ecosystem`. Consumers should pin an immutable tag/commit/content hash according to the parent Catalog/Lock contract rather than tracking mutable latest content directly.
