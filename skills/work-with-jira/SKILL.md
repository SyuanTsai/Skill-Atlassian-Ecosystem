---
name: work-with-jira
description: Read, search, create, comment on, assign, edit, or transition Jira Cloud issues through approved integrations. Use for Jira URLs, issue keys, JQL queries, project context, or explicitly requested issue changes while preserving exact site selection, credential scope, and write authorization. Use for reading Jira issues through verified REST access in GitHub Copilot IDE.
license: Apache-2.0
---

# Work With Jira Cloud

Before any Jira access, load [references/environment-separation.md](references/environment-separation.md) and resolve the environment. If the environment cannot be determined or signals conflict, stop and ask. If the resolved environment's required connection method fails, stop and report it; do not fall back to an API token, MCP, Rovo, or another method.

## Target Selection

The source-owned [Web capability contract](references/web-capability-contract.json) declares connector and local REST paths separately. A consumer projects this file with the verified Skill package and binds the authoritative site, user-selected path, and available host capabilities at runtime. The projection contains no credentials. An unavailable selected path or failed preflight blocks that operation; availability of the other path never changes the selection.

1. Treat the origin in a user-provided Jira URL as the authoritative site selector. Extract the site origin and issue key or resource identifier before choosing an access path.
2. Verify that every connector or REST request targets the same Jira site or resolved Cloud ID as the authoritative URL. A matching issue key on another site is a different resource and must never be substituted.
3. Use an Atlassian connector only when its accessible site matches the authoritative URL. If it is connected to a different site, do not search or retrieve content there as a fallback.
4. Use environment-based REST access only when `JIRA_BASE_URL` matches the authoritative URL's Jira site, then use the corresponding `JIRA_CLOUD_ID` and `JIRA_API_BASE_URL` for API calls. If no configured access path matches, stop and report the site mismatch without exposing private site details.
5. When the request contains only an issue key or JQL, use a single explicitly named or unambiguously configured site. If configured access paths disagree about the target site, ask the user to provide the Jira URL or choose the site; never default to the currently authenticated connector.
6. A Jira URL identifies the target but does not authorize a write. Continue to apply the write-authorization rules below.

## Access

If Jira API access is missing, invalid, or not yet verified, use `configure-jira-api-access` to guide setup and read-only validation before continuing. In IDE GitHub Copilot, use this same Skill; do not require an Atlassian connector when the user selected the verified REST path. Before the first REST query, resolve the installed `configure-jira-api-access` Skill and its bundled validator. Resolve both from that Skill's installed directory; do not hardcode repository, `.agents`, `.github`, or home-directory paths. Delegate the Copilot reload and shared `HostReloadContract` details to that Skill, and resume only after its validator reports the selected path ready. Do not diagnose an environment inheritance mismatch as a bad token, and do not create a Copilot-only access implementation.

Read `JIRA_BASE_URL`, `JIRA_EMAIL`, `JIRA_API_TOKEN`, `JIRA_CLOUD_ID`, and `JIRA_API_BASE_URL` only from environment variables or an approved secret store.

Base every `/rest/api/3/...` and `/rest/agile/1.0/...` request on `JIRA_API_BASE_URL`; never call those REST endpoints through `JIRA_BASE_URL`.

If `JIRA_CLOUD_ID` or `JIRA_API_BASE_URL` is missing, route back to `configure-jira-api-access`; do not rebuild Cloud ID discovery or API-base derivation here.

After resolving the target site, use only the access path required by the resolved environment. A token's presence does not authorize REST, and a connector's presence does not authorize abandoning REST.

Never print, log, persist, or place credential values in prompts, repositories, command arguments, or responses. Do not reveal them through diagnostic commands.

## Operations

1. Default to read-only queries. Perform external writes only when the user explicitly requests them.
2. Resolve ambiguous issue keys, JQL, projects, users, transitions, or other identifiers before acting; never guess a target.
3. For one confirmed issue over REST, use `GET /rest/api/3/issue/{issueKey}` and request only the fields needed for the task.
4. For JQL over REST, use `GET /rest/api/3/search/jql`, set `maxResults` to the smallest useful value and no more than 100, request only necessary fields, and follow `nextPageToken` only when additional results are required.
5. Normalize read results to the user's requested fields and avoid exposing unrelated personal data, internal links, sensitive content, or complete response bodies.
6. Before connector-based issue creation, list projects filtered by **Create permission**, select only a verified project, then retrieve its available **issue types** and the selected type's **required fields**. Resolve every required value before calling create. If no project is returned or metadata is incomplete, stop with the permission or metadata gap; do not try an unverified project and do not switch to REST as a fallback.
7. Before any other write, verify the target issue and intended change. Obtain confirmation before bulk, destructive, or difficult-to-reverse operations.
8. On failure, report the HTTP status, operation type, and a safely redacted error summary. Never return an Authorization header, token, or complete sensitive response body.
9. Report in the user's language what was read or changed, the target issue keys, and any unresolved permission or configuration problem without exposing secrets.

Example read-only result:

```text
Issue: <confirmed-issue-key>
Site: authoritative configured Jira Cloud site
Status: In Progress
Assignee: Account Name
Remote writes: none
```

## Error Handling

- If authentication or permission fails, report the HTTP status and operation type without exposing credentials or complete response bodies.
- If a write target, transition, user, or project remains ambiguous after read-only resolution, do not perform the write.
- If a write returns an uncertain or partial result, re-read the target before retrying and report what actually changed.
