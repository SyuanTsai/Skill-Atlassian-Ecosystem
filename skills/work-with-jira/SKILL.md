---
name: work-with-jira
description: Read, search, create, comment on, assign, edit, or transition Jira Cloud issues through approved integrations. Use for Jira URLs, issue keys, JQL queries, project context, or explicitly requested issue changes while preserving exact site selection, credential scope, and write authorization.
---

# Work With Jira Cloud

## Target Selection

1. Treat the origin in a user-provided Jira URL as the authoritative site selector. Extract the site origin and issue key or resource identifier before choosing an access path.
2. Verify that every connector or REST request targets the same Jira site or resolved Cloud ID as the authoritative URL. A matching issue key on another site is a different resource and must never be substituted.
3. Use an Atlassian connector only when its accessible site matches the authoritative URL. If it is connected to a different site, do not search or retrieve content there as a fallback.
4. Use environment-based REST access only when `JIRA_BASE_URL` matches the authoritative URL's Jira site, then use the corresponding `JIRA_CLOUD_ID` and `JIRA_API_BASE_URL` for API calls. If no configured access path matches, stop and report the site mismatch without exposing private site details.
5. When the request contains only an issue key or JQL, use a single explicitly named or unambiguously configured site. If configured access paths disagree about the target site, ask the user to provide the Jira URL or choose the site; never default to the currently authenticated connector.
6. A Jira URL identifies the target but does not authorize a write. Continue to apply the write-authorization rules below.

## Access

If Jira API access is missing, invalid, or not yet verified, use `configure-jira-api-access` to guide setup and read-only validation before continuing.

1. In IDE GitHub Copilot, use this same Skill; do not require an Atlassian connector when the user selected the verified REST path. Before the first REST query, resolve the installed `configure-jira-api-access` Skill and the `Test-JiraApiAccess.ps1` validator bundled with that Skill. Resolve it from that Skill's installed directory; do not hardcode repository, `.agents`, `.github`, or home-directory paths.
2. If that validator reports `reload-required` or `process-user-mismatch`, apply the Copilot IDE host-adapter reference bundled with `configure-jira-api-access` and the shared `HostReloadContract`, recreate the IDE/Copilot host when required, then rerun the same validator. Do not diagnose an inheritance mismatch as a bad token and do not create a Copilot-only access implementation.
3. Read `JIRA_BASE_URL`, `JIRA_EMAIL`, `JIRA_API_TOKEN`, `JIRA_CLOUD_ID`, and `JIRA_API_BASE_URL` only from environment variables or an approved secret store.
4. Base every `/rest/api/3/...` and `/rest/agile/1.0/...` request on `JIRA_API_BASE_URL`; never call those REST endpoints through `JIRA_BASE_URL`.
5. If `JIRA_CLOUD_ID` or `JIRA_API_BASE_URL` is missing, route back to `configure-jira-api-access`; do not rebuild Cloud ID discovery or API-base derivation here.
6. After resolving the target site, use only the access path selected by the user. Use Atlassian MCP or Rovo only when the user selected that connector path and its accessible site matches the resolved target; a token's presence alone is not authorization and a connector's presence is not permission to abandon REST.
7. Never print, log, persist, or place credential values in prompts, repositories, command arguments, or responses. Do not reveal them through diagnostic commands.

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

## Example

```text
User request:
"In Copilot, read SYP-123 and then search the same project for open issues."

Expected workflow:
1. Resolve the authoritative Jira site and selected REST path.
2. Run the shared Jira validator from the installed configure Skill; repair only host reload/inheritance when its contract requires it.
3. Read SYP-123 with only the requested fields.
4. Execute a bounded JQL search against the same tenant and return only the requested fields.
5. Perform no remote writes.
```

Example read-only result:

```text
Issue: SYP-123
Site: authoritative configured Jira Cloud site
Status: In Progress
Assignee: resolved from requested fields
Remote writes: none
```

## Error Handling

- If the Jira site cannot be resolved unambiguously, stop before searching or writing and request the authoritative URL or explicit site choice.
- If a connector and environment configuration point to different sites, do not substitute one for the other; report the mismatch safely.
- If IDE GitHub Copilot can see persisted User settings but the current process did not inherit them, treat the shared validator's reload contract as authoritative and recreate the host before retrying credentials.
- If authentication or permission fails, report the HTTP status and operation type without exposing credentials or complete response bodies.
- If a write target, transition, user, or project remains ambiguous after read-only resolution, do not perform the write.
- If a write returns an uncertain or partial result, re-read the target before retrying and report what actually changed.
