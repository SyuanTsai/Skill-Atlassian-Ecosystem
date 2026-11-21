# Code-evidence case: page and managed-attachment actions

This representative case documents how `manage-confluence-docs-as-code` decides managed-attachment upload or reuse and page create, update, or no-op. It is evidence for the pinned source version, not a claim about every possible live Confluence response.

## Fixed scope and version

- Repository revision: `e85f8863dff89c4b143b63db0ef763dffa638e9e`.
- Paths: `skills/manage-confluence-docs-as-code/scripts/ConfluenceAssets.psm1`, `skills/manage-confluence-docs-as-code/scripts/ConfluencePlan.psm1`, and `skills/manage-confluence-docs-as-code/scripts/ConfluencePublish.psm1`.
- Subject: current-mode page planning and execution for managed attachments, including new and existing pages.

## Evidence table

<!-- evidence-table:start -->
| Source | Target | Condition | Status | Commit | File | Symbol |
| --- | --- | --- | --- | --- | --- | --- |
| Validated payload for a page without a page ID | New page and its managed attachments | The create title and parent are verified; every managed asset is planned as `upload` and the page action is `create` | confirmed in code | e85f8863dff89c4b143b63db0ef763dffa638e9e | `skills/manage-confluence-docs-as-code/scripts/ConfluencePlan.psm1` | `New-ConfluencePreviewPlan` |
| Authorized create plan | Created page identity and final page body | Execution establishes the created identity, uploads planned assets, resolves links, and verifies final readback | confirmed in code | e85f8863dff89c4b143b63db0ef763dffa638e9e | `skills/manage-confluence-docs-as-code/scripts/ConfluencePublish.psm1` | `Invoke-PublishLinkedPages` |
| Managed local asset and remote attachment list | Existing attachment | One exact filename match has valid metadata and downloaded bytes with the expected digest; the action is `reuse` | confirmed in code | e85f8863dff89c4b143b63db0ef763dffa638e9e | `skills/manage-confluence-docs-as-code/scripts/ConfluenceAssets.psm1` | `Get-ManagedAttachmentObservation` |
| Existing page payload and stable remote observations | Existing page | Equivalent body, equal title, and no required upload produce `no-op`; otherwise the action is `update` | confirmed in code | e85f8863dff89c4b143b63db0ef763dffa638e9e | `skills/manage-confluence-docs-as-code/scripts/ConfluencePlan.psm1` | `New-ConfluencePreviewPlan` |
| Existing managed filename with conflicting metadata or bytes | Attachment update-in-place path | The observation blocks with a conflict; it does not map the mismatch to overwrite or attachment-version update | confirmed not mapped | e85f8863dff89c4b143b63db0ef763dffa638e9e | `skills/manage-confluence-docs-as-code/scripts/ConfluenceAssets.psm1` | `Get-ManagedAttachmentObservation` |
| Upload or page write request | Live Confluence persistence and subsequent visibility | The client sends the request and requires readback, but actual server-side persistence cannot be established from repository code alone | unconfirmed | e85f8863dff89c4b143b63db0ef763dffa638e9e | `skills/manage-confluence-docs-as-code/scripts/ConfluencePublish.psm1` | `Invoke-PublishLinkedPages` |
<!-- evidence-table:end -->

## Concise output document

For a new page, the preview requires an empty page ID, verifies the target parent and title availability, assigns `create`, and plans each managed attachment as `upload`. Execution first establishes and reads back the page identity, then uploads attachments and writes the final resolved body.

For an existing page, each managed attachment is observed twice around a byte-level check. An absent managed filename becomes `upload`; one stable exact match becomes `reuse`. Duplicate names, changed observations, or mismatched metadata or bytes block the operation. There is no evidence in this flow of an attachment update-in-place mapping for a conflicting same-name attachment.

After attachment decisions, an existing page becomes `no-op` only when storage is equivalent, the title is unchanged, and no upload is needed. Otherwise it becomes `update`. Execution still validates baselines and readback; the repository proves those client-side gates, while successful persistence remains a live-service fact that must be confirmed by an actual operation readback.

## Verification results

The pinned revision was resolved with `git rev-parse e85f886`, which returned `e85f8863dff89c4b143b63db0ef763dffa638e9e`. Each evidence row was then checked with `git show <commit>:<path>` and a symbol search in the returned blob:

- `New-ConfluencePreviewPlan` exists in `ConfluencePlan.psm1`; its create branch assigns upload to new-page assets, and its existing-page branch selects no-op only for an equivalent body, equal title, and no upload, otherwise update.
- `Invoke-PublishLinkedPages` exists in `ConfluencePublish.psm1`; it handles linked create identities, upload or reuse confirmation, final writes, and readback gates.
- `Get-ManagedAttachmentObservation` exists in `ConfluenceAssets.psm1`; it returns upload for no matching filename, reuse for one stable byte-verified match, and blocking results for conflicts or drift.

Local contract checking is provided by `tests/ConfluenceDocs.EvidenceWorkflow.Tests.ps1`. It parses every evidence row, reads the pinned Git blob, and confirms that the cited symbol is declared in that file; the repository's normal Markdown and Skill review checks remain applicable.

## Usage

Repeated-read counts, tool-output volume, and actual usage/credits data are unavailable because comparable data were not retained. No cost reduction is claimed.
