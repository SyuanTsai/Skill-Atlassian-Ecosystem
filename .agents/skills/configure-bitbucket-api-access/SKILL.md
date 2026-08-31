---
name: configure-bitbucket-api-access
description: Check and fix Bitbucket Cloud API-token access without exposing credentials. Use when Bitbucket API environment settings are missing or invalid, authentication returns 401/403, or Repository Read and Pull requests Read permissions must be verified.
---

# Configure Bitbucket API Access

Guide the user from configuration inventory to a verified least-privilege Bitbucket Cloud connection. Keep credential values out of prompts, logs, repositories, command arguments, and responses.

Read [references/configuration.md](references/configuration.md) before proposing commands, changing configuration, creating or rotating a token, or diagnosing an HTTP failure. Use [scripts/Test-BitbucketApiAccess.ps1](scripts/Test-BitbucketApiAccess.ps1) for redacted inventory and connection checks instead of rebuilding credential-handling commands ad hoc.

## Workflow

1. Establish the exact intended Bitbucket operation. Default `review-bitbucket-pull-request` to read-only review access and request only Repository Read (`read:repository:bitbucket`) plus Pull requests Read (`read:pullrequest:bitbucket`). Add stronger permissions only when a separately authorized operation requires them.
2. Run the validation script without `-TestConnection` to inspect only whether `BITBUCKET_API_BASE_URL`, `BITBUCKET_EMAIL`, `BITBUCKET_API_TOKEN`, and `BITBUCKET_WORKSPACE` are present and where they are defined. Validate non-secret shapes in memory; never print token values, lengths, hashes, prefixes, encoded forms, or Authorization headers.
3. Report a redacted inventory with purpose, presence, source scope, and validation result. Distinguish Process, User, Machine, secret-store injection, and unknown sources. Do not claim persistence for process-only settings.
4. Resolve missing or invalid settings in dependency order: API base URL, account email, workspace, then token.
5. Before token creation or rotation, show one complete minimum permission checklist for the intended operation. Prefer a single-purpose token with an explicit expiration date. Do not ask the user to paste the token into chat.
6. Before persisting or replacing a setting, explain the target storage scope and obtain explicit authorization. Prefer session-only injection or an approved secret manager; never write credentials to a repository, shell history, transcript, profile, generated document, Jira, or Confluence.
7. Validate `BITBUCKET_API_BASE_URL` as an HTTPS Bitbucket Cloud REST base, normally `https://api.bitbucket.org/2.0`, with no embedded credentials.
8. After the user approves a read-only connection check, run the script with `-TestConnection`. It first requests `${BITBUCKET_API_BASE_URL}/repositories/${BITBUCKET_WORKSPACE}?pagelen=1`. For PR-review readiness, also pass the confirmed repository slug and PR ID so it tests the exact PR metadata path. The script constructs Basic authentication only in memory and returns no response body.
9. Treat the two checks independently: the workspace repository-list path must return `200` for Repository Read, and the exact PR path must return `200` for Pull requests Read and target visibility. A repository-list success alone is not PR-review readiness. Classify only safe status categories; never include response bodies or raw exception messages.
10. When both checks succeed, return control to `review-bitbucket-pull-request`. If a connector already provides the required reads, do not force API-token setup. Keep remote writes behind the review workflow's explicit authorization boundary.

Run the supplied helper from the repository root; never add the email or token as arguments:

```powershell
pwsh -NoProfile -File ./.agents/skills/configure-bitbucket-api-access/scripts/Test-BitbucketApiAccess.ps1
pwsh -NoProfile -File ./.agents/skills/configure-bitbucket-api-access/scripts/Test-BitbucketApiAccess.ps1 -TestConnection -RepositorySlug <confirmed-repository-slug> -PullRequestId <confirmed-pr-id>
```

## Required permission baseline

For `review-bitbucket-pull-request` read-only analysis:

- Repositories: Read (`read:repository:bitbucket`)
- Pull requests: Read (`read:pullrequest:bitbucket`)

Do not request Repository Write, Repository Admin, or Pull requests Write for ordinary review. Note that Bitbucket's current API-token Pull requests Read scope can also permit PR comments; the review skill must still enforce explicit user authorization before using that write capability.

## Example

```text
User request:
"My Bitbucket PR review setup returns 401. Check the API access without showing any secret values."

Expected workflow:
1. Report only whether the four required environment variables are present and their source scopes.
2. Verify the API base, workspace shape, Repository Read, and Pull requests Read requirements.
3. Offer the redacting validation script's repository-list check and, for PR readiness, its exact PR metadata check.
4. Return only HTTP statuses, safe diagnoses, and next actions; never return the token, Authorization header, response body, or exception message.
```

## Error Handling

- `400`: validate URL construction and workspace shape without exposing inputs.
- `401`: verify token type, account email, expiration/revocation, and endpoint selection; do not display credential material.
- `403`: authentication may be valid; report the missing permission category or workspace/repository access restriction.
- `404`: verify workspace/resource identity without guessing.
- `429`: respect `Retry-After`; do not loop aggressively.
- Network/TLS failure: separate transport failure from authentication failure.

## Stop Conditions

Stop and explain the next safe action when a credential would need to be displayed, logged, committed, or placed in a command argument; the workspace or intended operation is ambiguous; organization policy does not approve API-token use; a stronger permission is required but not explicitly justified; persistence or token rotation lacks authorization; or repeated authentication failures remain after safe endpoint and configuration checks.

## Completion Report

Report in the user's language:

- each required variable's presence, source scope, and validation state;
- the redacted API-base validation result;
- each read-only endpoint category tested and its HTTP status;
- the minimum permissions required for the intended operation;
- whether Bitbucket API access is ready for that operation;
- token-expiration/rotation actions the user still needs to track.

Never include real credential values, Authorization headers, private account identifiers, or unrelated repository data.
