---
name: publish-requirements-to-confluence
description: Create or safely update a traceable Confluence Cloud page from analyzed requirements. Use when the user asks to organize or publish completed requirement analysis or a specification to Confluence, with preview, destination, draft, version-history, and authorization checks.
license: Apache-2.0
---

<!--
SPDX-FileCopyrightText: 2026 SyuanTsai
SPDX-License-Identifier: Apache-2.0
-->

# Publish Requirements to Confluence

Transform completed requirement analysis into a clear, traceable Confluence page, show the user what will be published, and protect existing content and version history during the write.

Read [references/confluence-cloud-api.md](references/confluence-cloud-api.md) before accessing Confluence or preparing an API request. Read [references/requirements-structure.md](references/requirements-structure.md) when organizing the document.

## Access Boundary

Prefer an approved Confluence connector when it can resolve and update the exact target safely. Otherwise use Confluence Cloud REST API v2 with credentials from environment variables or an approved secret store. Never print, log, persist, or place credentials in prompts, repositories, URLs, command arguments, generated documents, or responses.

If the approved connector cannot perform the requested operation and Confluence REST access is missing, invalid, or not yet verified, route setup and read-only diagnostics through `configure-confluence-api-access` before continuing. Keep this fallback conditional: do not require an API token when the connector already satisfies the publishing request.

Treat space and page discovery as read-only. Treat creating a page, updating content or title, adding labels, moving a page, changing restrictions, or uploading attachments as external writes. Publish only when the user has explicitly requested the exact create or update operation and the target is unambiguous.

## Preparation Flow

1. Identify the analyzed source material, intended audience, document language, and expected outcome. Preserve source links, identifiers, decisions, and ownership when provided.
2. Separate confirmed requirements, assumptions, decisions, dependencies, constraints, risks, and open questions. Do not invent missing requirements, acceptance criteria, owners, dates, or decisions; mark missing information explicitly.
3. Organize the content with the requirement structure reference. Keep stable requirement IDs when present. When IDs are absent and traceability matters, propose neutral IDs without implying that they came from the source.
4. Preserve technical details needed for implementation while consolidating duplicates and separating business intent from proposed implementation. Record material conflicts instead of silently choosing one interpretation.
5. Produce a user-visible preview or structured summary before publishing. Include the planned page title, document sections, omitted or unresolved content, and whether the action will create or update a page.

## Destination Flow

1. Resolve the exact Confluence Cloud site, numeric space ID, parent page ID when applicable, page title, and create-versus-update intent. Convert a space key to its numeric ID through a read-only lookup.
2. Search the target space for an existing current page with the same title. If more than one candidate exists or the parent differs, stop and ask the user to choose. Never infer an update target from title alone when ambiguous.
3. For an update, fetch both the latest published page and the `get-draft=true` view in storage format, including parent, title, status, version, and body. Compare them before preparing the update. If an unpublished draft exists or diverges from the published page, stop, show a safe summary of the differences, and obtain an explicit decision about how to preserve or merge it; never overwrite or reconcile it automatically.
4. Confirm that the authenticated account has the required space and page permissions. A valid token does not prove permission to the selected destination.
5. Obtain explicit authorization for the final target and previewed content when it has not already been provided. Reconfirm if the target, replacement boundary, or material content changed after the preview.

## Publish and Verify

1. Convert the approved document to safe Confluence storage-format markup. Escape source text, preserve links, and use supported headings, lists, tables, and code blocks. Do not inject untrusted raw HTML or unsupported macros.
2. Create with `POST /wiki/api/v2/pages`. For an update, immediately re-read both the published and `get-draft=true` views; proceed with `PUT /wiki/api/v2/pages/{id}` using the latest version number plus one only when no new or diverged draft appeared after authorization. Include a concise version message.
3. On a conflict or version mismatch, stop, re-read the current page, show the divergence, and obtain renewed authorization before rebuilding the update. Do not overwrite blindly.
4. Read the resulting page back and verify its title, space, parent, status, version, and essential sections. Return the page ID and user-facing link without exposing unrelated private site data.
5. Report exactly what was created or updated, the source material represented, unresolved questions, and any formatting or attachment limitations.

## Example

```text
User request:
"Publish this approved requirements analysis under the Payments space as a child of Architecture Decisions."

Expected workflow:
1. Structure the requirements and show a preview.
2. Resolve the exact site, numeric space ID, parent page, and create/update intent.
3. Check for same-title pages and unpublished drafts.
4. Publish only after the target and content are explicitly authorized, then read the page back.
```

Example destination check:

```text
Site: confirmed
Space ID: 123456
Parent page: Architecture Decisions (987654)
Title: Payment Retry Requirements
Action: create
Same-title page: none
Unpublished draft conflict: none
```

## Error Handling

- If multiple pages match the intended title or parent, stop and require the user to select the exact destination.
- If an unpublished draft differs from the published page, preserve both states and obtain explicit reconciliation instructions before updating.
- If the current version changes after authorization, re-read the page and require renewed approval before rebuilding the update.
- If storage-format conversion would inject unsupported markup or untrusted HTML, sanitize or omit the unsafe element and report the limitation.
- If permission is insufficient or the resulting page cannot be read back and verified, report the failed operation without retrying a write blindly.

## Stop Conditions

Stop before publishing when the destination or create/update intent is ambiguous, the source contains unresolved contradictions that materially change the page, permission or scope is insufficient, an unpublished draft has not been explicitly reconciled, sensitive information lacks an approved destination, or preserving existing page content cannot be guaranteed.

Do not delete pages, purge drafts, change restrictions, or upload attachments under this workflow unless the user separately requests and authorizes that action.
