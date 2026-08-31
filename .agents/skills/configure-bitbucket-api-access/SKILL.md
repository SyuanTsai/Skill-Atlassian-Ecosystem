---
name: configure-bitbucket-api-access
description: Check, configure, and safely validate Bitbucket Cloud API-token access without exposing credentials. Use when Bitbucket API environment settings are missing or invalid, authentication fails, workspace access must be verified, or review-bitbucket-pull-request needs API access.
---

# Configure Bitbucket API Access

Guide the user from configuration inventory to a verified least-privilege Bitbucket Cloud connection. Keep credential values out of prompts, logs, repositories, command arguments, and responses.

Read [references/configuration.md](references/configuration.md) before proposing commands, changing configuration, creating or rotating a token, or diagnosing an HTTP failure.

## Workflow

1. Establish the exact intended Bitbucket operation. Default `review-bitbucket-pull-request` to read-only review access and request only Repository Read (`read:repository:bitbucket`) plus Pull requests Read (`read:pullrequest:bitbucket`). Add stronger permissions only when a separately authorized operation requires them.
2. Inspect only whether `BITBUCKET_API_BASE_URL`, `BITBUCKET_EMAIL`, `BITBUCKET_API_TOKEN`, and `BITBUCKET_WORKSPACE` are present and where they are defined. Validate non-secret shapes in memory; never print token values, lengths, hashes, prefixes, encoded forms, or Authorization headers.
3. Report a redacted inventory with purpose, presence, source scope, and validation result. Distinguish Process, User, Machine, secret-store injection, and unknown sources. Do not claim persistence for process-only settings.
4. Resolve missing or invalid settings in dependency order: API base URL, account email, workspace, then token.
5. Before token creation or rotation, show one complete minimum permission checklist for the intended operation. Prefer a single-purpose token with an explicit expiration date. Do not ask the user to paste the token into chat.
6. Before persisting or replacing a setting, explain the target storage scope and obtain explicit authorization. Prefer session-only injection or an approved secret manager; never write credentials to a repository, shell history, transcript, profile, generated document, Jira, or Confluence.
7. Validate `BITBUCKET_API_BASE_URL` as an HTTPS Bitbucket Cloud REST base, normally `https://api.bitbucket.org/2.0`, with no embedded credentials.
8. Offer a minimal read-only authenticated request to `${BITBUCKET_API_BASE_URL}/repositories/${BITBUCKET_WORKSPACE}?pagelen=1`. Construct Basic authentication from `BITBUCKET_EMAIL:BITBUCKET_API_TOKEN` only in memory. Do not return the response body; use only the HTTP status and safe classification.
9. A successful read proves authentication and repository visibility for the selected workspace, not every permission needed by every future action. For PR review, separately verify the token has Pull requests Read before handing work to `review-bitbucket-pull-request`.
10. When validation succeeds, return control to the requested Bitbucket workflow. Keep remote writes behind that workflow's explicit authorization boundary.

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
3. Offer one read-only repository-list request for the configured workspace.
4. Return only the HTTP status, safe diagnosis, and next action; never return the token or Authorization header.
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
- the read-only endpoint category tested and HTTP status;
- the minimum permissions required for the intended operation;
- whether Bitbucket API access is ready for that operation;
- token-expiration/rotation actions the user still needs to track.

Never include real credential values, Authorization headers, private account identifiers, or unrelated repository data.
