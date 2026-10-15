# Confluence documentation workflow

This repository's Confluence documentation workflow manages ordinary Markdown in Git. It captures authorized source pages, asks for review before import, binds mappings and plans to exact source revisions, previews remote changes, and publishes only with matching human authorization. OpenSpec can be used optionally to organize documents outside this workflow; it is not a runtime, format, or validation requirement. When using it, check the upstream latest stable release and record the exact version in the relevant documentation. The [official v1.14.1 release](https://github.com/Fission-AI/OpenSpec/releases/tag/v1.14.1) was the latest stable version on 2026-10-13; this dated reference does not create a workflow dependency.

Historical requirements and scenario IDs below come from the [original SYP-171 source spec at commit `5c4938c3ff9cd42fe8862e77a8adfe52f055aa64`](https://github.com/SyuanTsai/Skill-Atlassian-Ecosystem/blob/5c4938c3ff9cd42fe8862e77a8adfe52f055aa64/openspec/changes/manage-confluence-docs-as-code/specs/confluence-docs/spec.md). That Git revision remains the immutable source for their earlier wording.

## Source and review

Capture only the page or space scope the user authorized. Keep the source origin, page identity, version, hierarchy, attachments, raw storage, candidate Markdown, and each source block's location and digest. A partial read, changed page version, missing pagination, or unsupported node remains visible as incomplete. Capture never overwrites adopted Git files.

Review every captured source block against its source identity and bytes. An accepted block names the exact repository-relative Markdown document and whole-document section (`document`), and records the SHA-256 of the exact committed destination blob. Unknown, retained, and excluded blocks have no publish destination and remain non-ready; exclusions need a reason and retained evidence. The selected commit must contain the same mapping, Markdown, capture, review, raw snapshots, candidates, and attachment bytes being validated. Preserve those captured bytes in Git with a `-text` attributes rule for the capture directory and attachment files; do not allow checkout or autocrlf conversion to rewrite evidence.

Ordinary documentation does not need a code, test, build, or environment revision. When a page makes a claim about current program behavior, bind it to a code revision and a current review of the relevant code paths. If code changed and the claim was not refreshed or reviewed against that revision, block it as stale. A missing product outcome stays unknown; current implementation or a preview cannot approve it.

## Capture path, permission, and budget contract

Each selected capture scope must provide a Cloud ID in dashed GUID D format: exactly 36 characters arranged in hexadecimal 8-4-4-4-12 groups. Capture checks this selected identity before tenant checks, permission preflight, access validation, HTTP reads, or capture output. A non-D, malformed, or whitespace-padded value returns invalid with ScopeSchemaInvalid and an empty capturePath. Valid D letter case and the original scope file bytes are preserved. This rule applies only to the selected Capture scope; generic tenant matching keeps its existing matching-N compatibility. Re-capture legacy data with a valid D scope and review it again instead of rewriting old evidence.

`Pull-ConfluenceDocs.ps1` requires `-Root`, `-TargetPath`, and `-ScopePath`; the target and scope file must remain inside the selected root. Choose an absolute physical root whose existing path from the capture target through the filesystem or volume root contains no symbolic link, junction, or other reparse point. The capture engine does not follow linked ancestors and returns the fixed `ReparsePointRejected` reason for them, including platform aliases such as macOS `/tmp` when they resolve through a link. It rechecks the path before and after private directory/file creation and immediately before sensitive writes. These checks do not make a parent directory safe against a concurrent rename or replacement by another process that can write there; shared parent-directory permissions are not changed.

Captured files are private. Windows capture directories and files use protected ACLs granting full control to the current user and `SYSTEM` only. Unix directories use `0700` and files use `0600`, and the resulting mode is read back before capture proceeds. Permission failures have three distinct boundaries. The runtime capability preflight runs before public access validation and any capture-content `HttpInvoker` calls; if the host cannot set or verify the required permissions, capture stops with `CapturePrivatePermissionsUnavailable` before public access validation and before any capture-content call. After that preflight passes, failure to create or verify the initial owned stage stops before the first capture-content `HttpInvoker` call, although public access validation may already have run. A later permission check for an owned child file stops before that file's first sensitive byte is written. By then, earlier authorized reads or downloads and retained raw page evidence may already exist. That failure returns `failed` with its retained stage/evidence when available, not a valid `partial` manifest. The Unix implementation requires the .NET `UnixFileMode`, `FileStreamOptions.UnixCreateMode`, and mode-setting APIs (PowerShell 7.3/.NET 7 or later). This implementation has only been exercised on the Windows host; Linux and macOS behavior still requires platform verification. A filesystem write failure after staging starts returns `failed` with a retained stage path when available; it must not be represented as a valid `partial` manifest.

The three `Pull-ConfluenceDocs.ps1` budget parameters are bounded and can only reduce the defaults:

| Parameter | Default and maximum | Accepted range |
| --- | --- | --- |
| `-MaxAttachmentDownloadBytes` | 1 GiB | 1 byte–1 GiB |
| `-MaxAttachmentAttempts` | 1,000 attempts | 1–1,000 attempts |
| `-MaxCaptureBytes` | 1 GiB | 16 MiB + 1 byte–1 GiB |

An individual attachment declaration is limited to 20 MiB. Each download request is capped at the smallest of 20 MiB, the declared length (with a 1-byte minimum for a declared zero-length attachment), and the remaining aggregate download budget. A zero-length declaration accepts only an empty response; failed attempts still consume their reserved byte/attempt budget. The attempt budget is per attachment identity, even when downloaded bytes deduplicate to one asset file.

Storage API responses and storage fragments are bounded to 4 MiB. `capture.json` is admitted by its actual serialized UTF-8 byte length and may use at most 4,194,304 bytes. The manifest plus the private `capture-unindexed-files.json` audit have a combined ceiling of 16,777,216 bytes; the audit uses only the remaining space under that shared ceiling. Accounted capture bytes include raw page snapshots, Markdown candidates, unique attachment asset files, and the actual manifest and audit serialization. Before a sensitive write, the prospective files and a legal terminal state must fit both the metadata ceilings and `-MaxCaptureBytes`.

Initial page-scope metadata that cannot fit is `invalid` with `CaptureMetadataBudgetExceeded` before source reads. If a space capture can preserve its scope but cannot fit every discovered page ID, it can return a minimal `partial` capture that explicitly does not list all IDs. During a page, the engine stops further data reads/downloads when a budget is exhausted and preserves files that were already safely written; the current page can be omitted from `pages` and marked incomplete. If the audit itself cannot list every retained file, the valid partial capture is marked `CaptureAuditIncomplete` and its bounded audit reports omitted entries. A real file I/O failure remains `failed` (for example, `CaptureFailure`) with retained-stage evidence when available; it is not converted to a budget partial.

Collection and budget outcomes use fixed reason codes, including `PaginationLimit`, `PaginationLoop`, `RemoteIdMissing`, `DuplicateRemoteId`, `PaginationInconsistent`, `UnsafePaginationTarget`, `UnsafeInitialPath`, `CaptureAttachmentBudgetExceeded`, `CaptureFileBudgetExceeded`, `CaptureMetadataBudgetExceeded`, and `CaptureAuditIncomplete`. After tenant admission, collection requests use the parsed canonical API base consistently for both the initial URI and pagination targets, including equivalent scheme/host case and the default HTTPS port; write authorization continues to bind the configured raw-trimmed API identity. A well-formed storage fragment within the 4 MiB limit is also scanned to end-of-document before parsing; content elements are counted from depth 1, without counting the synthetic wrapper. Any content element deeper than 128 makes the whole fragment unsupported as `StorageDepthExceeded`: the capture records the original raw bytes and digest, stores an empty candidate, marks the capture `partial` with `UnsupportedContent`, and may continue to later pages. At the projection layer, malformed trailing XML, forbidden DTDs, and size violations keep their existing `StorageXmlInvalid`, `DtdForbidden`, and `StorageTooLarge` precedence instead of being relabelled as a depth result.

Import review always reprojects the captured raw bytes. A legacy complete capture whose prior projection considered deep content supported therefore fails current source validation with `CaptureSourceChanged`; its old capture and candidate are preserved unchanged. Recapture and repeat review, preview, and authorization under the current depth policy. Do not rewrite old evidence to imitate a current projection or reuse a prior approval.

## Versioned inputs and recovery

The workflow requires PowerShell 7.3 or later. Each public entry-point script enforces that minimum before validation, preview, capture, or execution so the private-file permission APIs required by Draft snapshots and captures are available on every supported platform. `Initialize-ConfluenceDocsRuntime.ps1` is retired. Mapping schema versions 1–3 and publication plan versions 1–4 are rejected; use the current mapping and plan contracts. New current-mode plans use authorization schema v1; new Draft-mode plans use v4. Historical authorization schemas v2 and v3 cannot authorize a new v5 plan and are not upgraded automatically. Obtain explicit authorization for the exact new plan digest and actions. An earlier authorization does not carry over to a different plan.

A capture dossier is a small JSON file that points to the committed capture and import review, for example:

```json
{
  "schemaVersion": 2,
  "capturePath": ".confluence/captures/2026-10-13/capture.json",
  "importReviewPath": ".confluence/captures/2026-10-13/import-review.json"
}
```

For a `code-current` mapping, the binding JSON records the docs and code repositories, exact commits, and path sets. Its `docs.sourcePaths` must cover every validated Markdown input, mapping, and any capture review inputs. Its `code.relevantPaths` names the code files supporting the claims:

```json
{
  "schemaVersion": 2,
  "targetKind": "current",
  "docs": {"repositoryPath": ".", "commit": "<exact docs commit>", "sourcePaths": ["docs/example.md", "confluence-mapping.json"]},
  "code": {"repositoryPath": ".", "commit": "<exact code commit>", "relevantPaths": ["src/example.ps1"]}
}
```

The accompanying code review JSON is bound to both commits and to the exact binding file bytes. Every `relevantPaths` entry must appear in `evidencePaths`:

```json
{
  "schemaVersion": 1,
  "outcome": "still-correct",
  "docsCommit": "<exact docs commit>",
  "codeCommit": "<exact code commit>",
  "bindingSha256": "<lowercase SHA-256 of the binding JSON bytes>",
  "evidencePaths": ["src/example.ps1"]
}
```

Resolve a repository revision with `git -C $docsRoot rev-parse HEAD`. A reviewed destination's `contentSha256` is the lowercase SHA-256 of the exact bytes in the selected commit's Git blob (`git rev-parse <commit>:<path>` returns a Git object ID, which is a different value). Hash the blob bytes with SHA-256; do not decode/re-encode the Markdown before hashing. The validator requires the selected commit and working source to agree under Git's effective clean filters. Markdown rendering and `contentSha256` use committed blob bytes; preserve raw capture evidence and attachments with `-text` rules. The review's `bindingSha256` likewise hashes the exact binding JSON bytes.

Restoring a Git file does not restore remote Confluence state, and uploading the same attachment bytes again can create a new remote attachment version. A recovery or compensating write needs a new preview and exact authorization. Retain the old plan, journal, and sync record; for an uncertain result, investigate with the original operation ID and do not blindly retry.

## Mapping, preview, and publication

Mappings identify each Markdown source, Confluence page or explicit parent, content kind, assets, and link bindings. The supported Markdown subset is explicit in the skill; unsupported constructs stop projection rather than disappearing. Resolve links by page identity. Do not select or create a page by title, and do not automatically create pages for unresolved or draft targets.

A native storage `<a>` with a non-empty, unprefixed `title` attribute is unsupported. Capture retains the original raw page body and reports `partial` with `UnsupportedContent`; review the unsupported block before import. A titleless or empty-title link keeps its existing behavior. A supported storage `<br/>` is captured as the existing renderer's Markdown hard break so a storage-to-Markdown-to-storage round trip retains the break. Import review can reject an older complete capture containing a non-empty link title with `CaptureSourceChanged`, because current projection no longer matches its recorded supported content. Retain the old evidence, recapture, and complete human review again.

Preview reads the selected tenant and target baselines without writing. It freezes rendered page bodies, attachment bytes and metadata, link resolution, current/draft versions, parent state, intermediate writes, source digests, and the publication mode in a versioned plan. Draft preview records the observed Draft digest and a deterministic recovery path only for a real update; it creates no second copy of the Draft body, and no-op pages have no recovery path. A source, mapping, attachment, target, or baseline change invalidates that plan and its authorization. Draft and published state are separate conflict surfaces. Resolve `docsRoot` as the Markdown repository and resolve `skillScripts` as the installed or source Skill's `scripts` directory; the script path and documentation root are independent inputs.

Execution revalidates the exact committed inputs, tenant, mapping, capture review, code-current evidence where applicable, plan payloads, and remote baselines before any write. For Draft updates, it completes the full fresh batch drift check, then creates or verifies one private exact prewrite snapshot at the authorized recovery path before any attachment or page mutation. A collision, permission failure, or digest mismatch returns `DraftSnapshotUnavailable` with zero remote mutation. Older v5 Draft plans without `draftSnapshotTiming: prewrite` return `PlanRequiresRepreview` and need a fresh preview and authorization. It uses a durable operation journal, refuses blind retries after uncertain writes, and reconciles by the original operation identity. It updates confirmed sync state only after page identity, content, version, and attachment readback agree. Repeating an unchanged operation is a no-op.

Publication does not change the reviewed source, infer acceptance, claim tests passed, or apply/archive a proposal. Old mapping, plan, and authorization versions are not silently upgraded: review and create a new preview and authorization. Retain prior revisions, plans, journals, and sync state needed to recover or investigate an earlier operation.

## SYP-171 requirement and scenario disposition

The following crosswalk preserves the meaning of the 11 original requirements and 17 scenarios while recording changes made when the workflow returned to general Markdown. These IDs are historical references, not runtime scenario gates.

| Requirement | Scenario | Disposition |
| --- | --- | --- |
| REQ-001 | SCN-001, SCN-002 | Retained: capture exact authorized page/space identity, version, hierarchy, links, and attachments; partial or failed reads remain incomplete and adopted Git documents stay untouched. |
| REQ-002 | SCN-003, SCN-004 | Revised: organize evidence-backed content into ordinary Markdown and references; preserve source correspondence and unknown outcomes; native OpenSpec `spec`/`design`/`tasks` files are optional external organization. |
| REQ-003 | SCN-005, SCN-006 | Revised: bind exact docs commit and authorized paths while preserving unrelated Git work. Only current-program-behavior claims require a relevant code revision and correctness review; general documents do not. |
| REQ-004 | SCN-007 | Retained and renamed: preview exact mapped pages, parents, assets, and links, then require authorization for the immutable plan; page identity is not inferred from a title. |
| REQ-005 | SCN-008, SCN-009 | Revised: use the declared Markdown renderer and explicit supported-content checks. Reject unsupported content without silent loss and retain the original source and location; no fixed native validator is required. |
| REQ-006 | SCN-010, SCN-011 | Retained: detect published and draft drift; journal operations; do not blindly retry uncertain page creation or overwrite an unexpected target. |
| REQ-007 | SCN-012 | Retained: update sync baseline only after identity, version, body, and attachments read back successfully; an unchanged rerun is a no-op. |
| REQ-008 | SCN-013, SCN-014 | Removed as a general-document gate: do not fabricate test results or completion. Code-current claims use applicable evidence; repository development still uses its normal regression checks. General docs need no scenario, build, or environment receipt. |
| REQ-009 | SCN-015 | Retained: keep proposal, current behavior, implementation, test, and publication state distinct; publishing does not modify source or apply/archive a proposal. |
| REQ-010 | SCN-016 | Revised: the primary workflow completes with Git, PowerShell, Markdown, and configured Confluence access without SYP-5 or an OpenSpec runtime; no replacement native validator is added. |
| REQ-011 | SCN-017 | Split: source review, repository gates, normal review/merge, and recoverable source artifacts are in this work. Installed replacement, live end-to-end adoption, and retirement of customized prior installs belong to SYP-259. |
