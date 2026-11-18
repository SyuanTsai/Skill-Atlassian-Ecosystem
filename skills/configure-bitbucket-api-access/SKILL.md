---
name: configure-bitbucket-api-access
description: Configure and validate Bitbucket Cloud API-token access before Bitbucket pull request review. Use when BITBUCKET_* environment settings are missing or invalid, a Bitbucket API token returns status 401 or 403, or Bitbucket Repository Read and Pull requests Read permissions must be verified.
license: Apache-2.0
---

# Configure Bitbucket API Access

Guide the user from configuration inventory to a verified least-privilege Bitbucket Cloud connection. Keep credential values out of prompts, logs, repositories, command arguments, and responses.

Before any Bitbucket access, load [references/environment-separation.md](references/environment-separation.md) and resolve the environment. If the environment cannot be determined or signals conflict, stop and ask. If the resolved environment's required connection method fails, stop and report it without falling back to another method.

Read [references/configuration.md](references/configuration.md) before changing configuration, creating or rotating a token, or diagnosing an HTTP failure. Use [scripts/Configure-BitbucketApiAccess.ps1](scripts/Configure-BitbucketApiAccess.ps1) as the canonical Fast Path for environment setup and hidden token input, and [scripts/Test-BitbucketApiAccess.ps1](scripts/Test-BitbucketApiAccess.ps1) for redacted inventory and connection checks. Resolve the host-provided installed Skill root before invoking either helper; never let a consumer repository's `scripts/` directory supply the executable. Do not regenerate equivalent `Read-Host`, `SetEnvironmentVariable`, Basic-auth, or validation PowerShell during the normal flow when these scripts are available. Load [references/shared-workflow.md](references/shared-workflow.md) before choosing Process or User scope, handling `HostReloadContract`, classifying an HTTP result, or preparing the completion report.

## Workflow

1. Establish the exact intended Bitbucket operation. Default `review-bitbucket-pull-request` to read-only review access and request only Repository Read (`read:repository:bitbucket`) plus Pull requests Read (`read:pullrequest:bitbucket`). Add stronger permissions only when a separately authorized operation requires them.
2. Run `Test-BitbucketApiAccess.ps1` without `-TestConnection` to inspect only whether `BITBUCKET_API_BASE_URL`, `BITBUCKET_EMAIL`, `BITBUCKET_API_TOKEN`, and `BITBUCKET_WORKSPACE` are present and where they are defined. Validate non-secret shapes in memory; never print token values, lengths, hashes, prefixes, encoded forms, or Authorization headers.
3. Apply the shared workflow to report the redacted inventory, choose Process or User scope, and handle host reload.
4. If the REST API path is selected and configuration must be created or repaired, use `Configure-BitbucketApiAccess.ps1` instead of constructing environment-setting commands ad hoc. Supply only non-secret inputs such as email, workspace, and the desired `Process` or `User` scope. The script reads the API token with hidden input, sets the canonical API base, always configures its current Process for immediate validation, and invokes the validator.
5. Before token creation or rotation, show one complete minimum permission checklist for the intended operation. Prefer a single-purpose token with an explicit expiration date. Never request credential material in chat; the helper must read the token through hidden input.
6. Validate `BITBUCKET_API_BASE_URL` as exactly the Bitbucket Cloud REST base with scheme `https`, host api.bitbucket.org, and base path /2.0 after trimming a trailing slash, with no embedded credentials.
7. After the user approves a read-only connection check, use either the Configure Fast Path with `-TestConnection` or the Test helper directly with `-TestConnection`. It requests `${BITBUCKET_API_BASE_URL}/repositories/${BITBUCKET_WORKSPACE}?pagelen=1`. For PR-review readiness, also pass the confirmed repository slug and PR ID so it tests the exact PR metadata path. The validator constructs Basic authentication only in memory and returns no response body.
8. Treat the two checks independently: the workspace repository-list path must return `200` for Repository Read, and the exact PR path must return `200` for Pull requests Read and target visibility. A repository-list success alone is not PR-review readiness. Apply the shared workflow for safe HTTP classification.
9. When both checks succeed, return control to `review-bitbucket-pull-request`. The environment-separation reference remains authoritative for the selected connection method.

Resolve the installed Skill root supplied by the host, then bind each helper to that root before running a Fast Path. Read [references/host-resolved-fast-path.md](references/host-resolved-fast-path.md) for the required prefix, reparse-point, and helper-existence checks; the consumer repository must not supply these paths. Never place a real token in an argument.

For diagnosis without changing settings:

```powershell
pwsh -NoProfile -File $testScript
pwsh -NoProfile -File $testScript -TestConnection -RepositorySlug <confirmed-repository-slug> -PullRequestId <confirmed-pr-id>
```

## Required permission baseline

For `review-bitbucket-pull-request` read-only analysis:

- Repositories: Read (`read:repository:bitbucket`)
- Pull requests: Read (`read:pullrequest:bitbucket`)

Do not request Repository Write, Repository Admin, or Pull requests Write for ordinary review. Note that Bitbucket's current API-token Pull requests Read scope can also permit PR comments; the review skill must still enforce explicit user authorization before using that write capability.

## Stop Conditions

Stop and explain the next safe action when a credential would need to be displayed, logged, committed, or placed in a command argument; the workspace or intended operation is ambiguous; organization policy does not approve API-token use; a stronger permission is required but not explicitly justified; or persistence or token rotation lacks authorization. The shared workflow handles repeated authentication failures, and the environment-separation reference governs any connection-method change.
