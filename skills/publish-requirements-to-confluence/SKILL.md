---
name: publish-requirements-to-confluence
description: Create or safely update a traceable Confluence Cloud page from analyzed requirements. Use when the user asks to organize or publish completed requirement analysis or a specification to Confluence, with preview, destination, draft, version-history, and authorization checks.
license: Apache-2.0
---

# Publish Requirements to Confluence

Transform completed requirement analysis into a clear, traceable Confluence page, show the user what will be published, and protect existing content and version history during the write.

Before any Confluence access, load [references/environment-separation.md](references/environment-separation.md) and resolve the environment. If the environment cannot be determined or signals conflict, stop and ask. If the resolved environment's required connection method fails, stop and report it without falling back to another method.

Read [references/confluence-cloud-api.md](references/confluence-cloud-api.md) before accessing Confluence or preparing an API request. Read [references/requirements-structure.md](references/requirements-structure.md) when organizing the document.

## Access Boundary

Use only the connection method required by the resolved environment. If REST access is required but missing, invalid, or unverified, route setup and read-only diagnostics through `configure-confluence-api-access`. Never print, log, persist, or place credentials in prompts, repositories, URLs, command arguments, generated documents, or responses.

Treat space and page discovery as read-only. Treat creating a page, updating content or title, adding labels, moving a page, changing restrictions, or uploading attachments as external writes. Publish only when the user has explicitly requested the exact create or update operation and the target is unambiguous.

## Preparation Flow

1. Identify the analyzed source material, intended audience, document language, and expected outcome. Preserve source links, identifiers, decisions, and ownership when provided.
2. Separate confirmed requirements, assumptions, decisions, dependencies, constraints, risks, and open questions. Do not invent missing requirements, acceptance criteria, owners, dates, or decisions; mark missing information explicitly.
3. Organize the content with the requirement structure reference. Keep stable requirement IDs when present. When IDs are absent and traceability matters, propose neutral IDs without implying that they came from the source.
4. Preserve technical details needed for implementation while consolidating duplicates and separating business intent from proposed implementation. Record material conflicts instead of silently choosing one interpretation.
5. Produce a user-visible preview or structured summary before publishing. Include the planned page title, document sections, omitted or unresolved content, and whether the action will create or update a page. Also show the resolved environment and site.

## Destination and Conflict Flow

1. Resolve the exact Confluence Cloud site, numeric space ID, parent page ID when applicable, page title, and create-versus-update intent. Convert a space key to its numeric ID through a read-only lookup.
2. Search the target space for an existing current page with the same title. Collect each candidate's page ID, parent, title, and status without selecting a target from title alone.
3. For an update, read both the latest published page and the `get-draft=true` storage view, including parent, title, status, version, and body. This is the single conflict rule: if same-title candidates or their parents leave the target ambiguous, stop and ask the user to select the exact target; if a draft diverges or either view changes after preview or authorization, stop, summarize the divergence safely, preserve both states, and obtain explicit reconciliation instructions and renewed authorization before rebuilding. Never overwrite or reconcile automatically.
4. Confirm that the authenticated account has the required space and page permissions. A valid token does not prove permission to the selected destination.
5. Obtain explicit authorization for the final target and previewed content when it has not already been provided. Reconfirm if the target, replacement boundary, or material content changed after the preview. Reconfirm again after any conflict-resolution decision.

## Publish and Verify

1. Convert the approved document to safe Confluence storage-format markup. Escape source text, preserve links, and use supported headings, lists, tables, and code blocks. Do not inject untrusted raw HTML or unsupported macros.
2. Create with `POST /wiki/api/v2/pages`. For an update, repeat the conflict reads from the Destination and Conflict Flow, then use `PUT /wiki/api/v2/pages/{id}` with the latest version plus one. Include a concise version message.
3. Read the resulting page back and verify its title, space, parent, status, version, and essential sections. Return the page ID and user-facing link without exposing unrelated private site data.
4. Report exactly what was created or updated, the source material represented, unresolved questions, and any formatting or attachment limitations.

Example destination check:

```text
Site: confirmed
Space ID: 123456
Parent page: Architecture Decisions (987654)
Title: Payment Retry Requirements
Action: create
```

Example conflict fields from the same preview:

```text
Same-title page: none
Unpublished draft conflict: none
```

## Stop Conditions

Stop before publishing if unresolved source contradictions materially change the page, sensitive information lacks an approved destination, permission or scope is insufficient, or preserving existing content cannot be guaranteed.

If storage-format conversion would inject unsupported markup or untrusted HTML, sanitize or omit the unsafe element and report the limitation. If permission is insufficient or the resulting page cannot be read back and verified, report the failed operation without retrying a write blindly.

Do not delete pages, purge drafts, change restrictions, or upload attachments under this workflow unless the user separately requests and authorizes that action.

## Error Handling

For destination or version conflicts, use step 3 of **Destination and Conflict Flow** as the sole handling location.
