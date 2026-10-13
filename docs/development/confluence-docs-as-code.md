# Confluence documentation workflow

This repository's Confluence documentation workflow manages ordinary Markdown in Git. It captures authorized source pages, asks for review before import, binds mappings and plans to exact source revisions, previews remote changes, and publishes only with matching human authorization. OpenSpec can be used optionally to organize documents outside this workflow; it is not a runtime, format, or validation requirement. When using it, check the upstream latest stable release and record the exact version in the relevant documentation. The [official v1.14.1 release](https://github.com/Fission-AI/OpenSpec/releases/tag/v1.14.1) was the latest stable version on 2026-10-13; this dated reference does not create a workflow dependency.

Historical requirements and scenario IDs below come from the [original SYP-171 source spec at commit `5c4938c3ff9cd42fe8862e77a8adfe52f055aa64`](https://github.com/SyuanTsai/Skill-Atlassian-Ecosystem/blob/5c4938c3ff9cd42fe8862e77a8adfe52f055aa64/openspec/changes/manage-confluence-docs-as-code/specs/confluence-docs/spec.md). That Git revision remains the immutable source for their earlier wording.

## Source and review

Capture only the page or space scope the user authorized. Keep the source origin, page identity, version, hierarchy, attachments, raw storage, candidate Markdown, and each source block's location and digest. A partial read, changed page version, missing pagination, or unsupported node remains visible as incomplete. Capture never overwrites adopted Git files.

Review every captured source block against its source identity and bytes. An accepted block names the exact repository-relative Markdown document and whole-document section (`document`), and records the SHA-256 of the exact committed destination blob. Unknown, retained, and excluded blocks have no publish destination and remain non-ready; exclusions need a reason and retained evidence. The selected commit must contain the same mapping, Markdown, capture, review, raw snapshots, candidates, and attachment bytes being validated. Preserve those captured bytes in Git with a `-text` attributes rule for the capture directory and attachment files; do not allow checkout or autocrlf conversion to rewrite evidence.

Ordinary documentation does not need a code, test, build, or environment revision. When a page makes a claim about current program behavior, bind it to a code revision and a current review of the relevant code paths. If code changed and the claim was not refreshed or reviewed against that revision, block it as stale. A missing product outcome stays unknown; current implementation or a preview cannot approve it.

## Versioned inputs and recovery

The workflow requires PowerShell 7.2 or later. `Initialize-ConfluenceDocsRuntime.ps1` is retired. Mapping schema versions 1–3 and publication plan versions 1–4 are rejected; use the current mapping and plan contracts. New current-mode plans use authorization schema v1; new Draft-mode plans use v4. Historical authorization schemas v2 and v3 cannot authorize a new v5 plan and are not upgraded automatically. Obtain explicit authorization for the exact new plan digest and actions. An earlier authorization does not carry over to a different plan.

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

Preview reads the selected tenant and target baselines without writing. It freezes rendered page bodies, attachment bytes and metadata, link resolution, current/draft versions, parent state, intermediate writes, source digests, and the publication mode in a versioned plan. A source, mapping, attachment, target, or baseline change invalidates that plan and its authorization. Draft and published state are separate conflict surfaces. Resolve `docsRoot` as the Markdown repository and resolve `skillScripts` as the installed or source Skill's `scripts` directory; the script path and documentation root are independent inputs.

Execution revalidates the exact committed inputs, tenant, mapping, capture review, code-current evidence where applicable, plan payloads, and remote baselines before any write. It uses a durable operation journal, refuses blind retries after uncertain writes, and reconciles by the original operation identity. It updates confirmed sync state only after page identity, content, version, and attachment readback agree. Repeating an unchanged operation is a no-op.

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
