# Bitbucket API access configuration

## Required settings

| Variable | Meaning | Safe validation |
| --- | --- | --- |
| `BITBUCKET_API_BASE_URL` | Bitbucket Cloud REST API base | Absolute HTTPS URL; normally `https://api.bitbucket.org/2.0` |
| `BITBUCKET_EMAIL` | Atlassian/Bitbucket account email used for Basic API-token authentication | Non-empty email-shaped value |
| `BITBUCKET_API_TOKEN` | Single-purpose Bitbucket Cloud API token | Presence only; never validate by token length, prefix, hash, or partial characters |
| `BITBUCKET_WORKSPACE` | Target Bitbucket workspace slug | Non-empty slug with no URL delimiters or credentials |

Process-scoped values can make the current session work but do not prove User- or Machine-level persistence.

## Least-privilege permissions

For `review-bitbucket-pull-request` read-only review, request exactly:

- Repositories Read — `read:repository:bitbucket`
- Pull requests Read — `read:pullrequest:bitbucket`

These are independent API-token scopes. Repository Read does not grant PR access, and Pull requests Read does not grant repository API access. Atlassian currently documents that Pull requests Read also permits commenting; the consuming review skill must therefore maintain its own explicit-authorization guard before publishing comments.

Add permissions only for a separately requested operation. Examples:

- repository modification: add `write:repository:bitbucket` while retaining explicit read if the endpoint requires it;
- PR create/update/approve/decline/merge: add `write:pullrequest:bitbucket` only when that operation is actually required and supported by the consuming workflow.

Never grant Repository Admin, Delete, workspace admin, or unrelated product permissions as a convenience baseline.

## Token creation, expiration, rotation, and revocation

Create a Bitbucket Cloud API token in Atlassian account settings with a descriptive single-purpose name, the minimum permissions above, and a finite expiration date appropriate to the use case. Record only the expiration date and purpose in a non-secret operational note; never record the token value.

Do not accept the token in chat. Have the user inject it privately into the current process or an approved secret store. Persisting it to User/Machine environment variables is an explicit security tradeoff and requires user authorization. Never place it in a repository, `.env` file committed to Git, shell history, profile script, transcript, CI log, Jira issue, or Confluence page.

Rotate before expiry or when purpose/permissions change. Revoke immediately when compromised, no longer needed, or when the owning account/workspace relationship changes.

## Redacted validation helper

Run an offline inventory first from the repository root:

```powershell
pwsh -NoProfile -File ./.agents/skills/configure-bitbucket-api-access/scripts/Test-BitbucketApiAccess.ps1
```

The helper reports presence, source scope, and non-secret shape only. It never reports the email, token, encoded credential, Authorization header, response body, or raw exception message.

After the user approves a read-only connection check, verify both permission paths for the confirmed target:

```powershell
pwsh -NoProfile -File ./.agents/skills/configure-bitbucket-api-access/scripts/Test-BitbucketApiAccess.ps1 -TestConnection -RepositorySlug <confirmed-repository-slug> -PullRequestId <confirmed-pr-id>
```

Do not put the token or email on the command line. The helper reads them from the approved environment path and constructs authentication only in memory.

## Read-only validation paths

Use a request equivalent to:

```text
GET ${BITBUCKET_API_BASE_URL}/repositories/${BITBUCKET_WORKSPACE}?pagelen=1
Accept: application/json
Authorization: Basic <in-memory base64 of BITBUCKET_EMAIL:BITBUCKET_API_TOKEN>
```

Construct the Authorization value only in memory. Do not echo the header, encoded credential, response body, repository names, or private workspace metadata. Clear temporary credential variables where possible.

Interpret conservatively:

| Result | Meaning and safe next action |
| --- | --- |
| `200` | That specific path is accessible; PR-review readiness requires `200` from both the repository-list and exact PR paths |
| `400` | Check request/API-base/workspace syntax |
| `401` | Check email, token type, expiration/revocation, and Basic-auth construction |
| `403` | Check token permission and workspace/repository access |
| `404` | Check workspace/resource identity without guessing |
| `429` | Respect `Retry-After` |
| Network/TLS failure | Diagnose proxy/network/TLS separately from credentials |

The exact PR check uses `GET ${BITBUCKET_API_BASE_URL}/repositories/${BITBUCKET_WORKSPACE}/{repo_slug}/pullrequests/{pull_request_id}`. A failed exact-target check may indicate Pull requests Read, product access, or target identity; do not infer which one from a response body because the helper intentionally suppresses it.

## Safe inspection

On Windows, query environment presence at Process/User/Machine scope independently with `System.Environment.GetEnvironmentVariable`. On Unix-like systems, inspect only the current process and approved secret-store integration. Never scan shell history or unrelated home-directory files. If the source cannot be established safely, report it as unknown.

For URLs and workspace slugs, validate normalized structure in memory and report only category-level results. Never include credentials in URLs.
