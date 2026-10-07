<!--
SPDX-FileCopyrightText: 2026 SyuanTsai
SPDX-License-Identifier: Apache-2.0
-->

# Bitbucket Cloud PR API reference

Official [pull-request REST reference](https://developer.atlassian.com/cloud/bitbucket/rest/api-group-pullrequests/), checked 2026-10-07. Recheck current endpoints/scopes before provisioning. Scopes do not grant user authorization.

## Access

Use an approved connector when sufficient. REST requires exactly `https://api.bitbucket.org/2.0`; construct Basic authentication in memory from `BITBUCKET_EMAIL` and `BITBUCKET_API_TOKEN`. Read those plus `BITBUCKET_API_BASE_URL` from the running process environment or an approved secret-store adapter. No credential arguments. Optional `BITBUCKET_WORKSPACE` defaults must match the exact PR.

- `read:repository:bitbucket`: repository visibility/setup baseline.
- `read:pullrequest:bitbucket`: metadata/discussion/statuses and Create/Reply/Resolve. The official reference currently assigns this scope (OAuth `pullrequest`) to creation and resolution.
- `write:pullrequest:bitbucket` is not needed for these operations. Do not add PR-state capabilities.

Git uses separate approved credential helpers/SSH agents. API scopes do not replace Git source inspection.

## Context and complete Git diff

Prefix: `/repositories/{workspace}/{repo_slug}/pullrequests/{pull_request_id}`.

| Read | Suffix |
| --- | --- |
| Metadata, participants, state, both commits | none |
| All comments/replies | `/comments` |
| One comment / verification | `/comments/{comment_id}` |
| Activity, tasks, statuses | `/activity`, `/tasks`, `/statuses` |

Follow every `next`. The shared script rejects redirects, pagination cycles, and URLs outside HTTPS `api.bitbucket.org:443` and the exact requested collection path before sending headers. Errors contain codes, never response bodies.

Fetch/validate both objects and inspect the same pair:

```text
git diff <destination-commit>...<source-commit>
git diff --name-status <destination-commit>...<source-commit>
git diff --stat <destination-commit>...<source-commit>
git diff --numstat <destination-commit>...<source-commit>
```

Incomplete Git/diff/validation keeps feedback local. Resolved comments and summaries cannot establish correctness.

## Feedback endpoints

| Action | Endpoint / minimal payload | Response |
| --- | --- | --- |
| Create global | `POST /comments`, `{"content":{"raw":"Markdown"}}` | 201 comment |
| Create inline | Same endpoint plus `inline` | 201 comment |
| Reply | Same endpoint plus `{"parent":{"id":ROOT_ID}}` | 201 comment |
| Resolve root | `POST /comments/{root_comment_id}/resolve`, no body | 200 resolution |

`inline.to` maps to the source/head side for added or context lines; `inline.from` maps to the destination/base side for removed lines. Use one side with `path`; ranges use corresponding `start_to`/`to` or `start_from`/`from`. Verify local diff positions or use global feedback. Reply targets the traced root without new inline location. Verify Resolve by the root comment's non-null `resolution`.

The helper adds a credential-free HTML correlation marker to Create/Reply for timeout reconciliation. Check both commits immediately before writes and re-read afterwards. A changed pair stops the batch; acknowledge the remaining check/write race.

401/403 need access repair; 404 needs target/thread verification; 409 remains failure; POST 429 is not automatically retried. GET 429 allows three attempts with delays bounded to five seconds. Pending/uncertain writes reconcile all pages and never blindly resend. See [review-actions.md](review-actions.md) for inputs, receipts, and recovery. No edits/deletions/reopening, approval, request changes, merge/decline, metadata/task mutations, or Git push.
