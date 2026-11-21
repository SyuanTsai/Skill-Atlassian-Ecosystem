# Code-evidence documentation workflow

Use this workflow when a document describes behavior implemented in code. Keep evidence bound to an exact version, distinguish verified behavior from gaps, and reuse the authorization and readback controls of this Skill.

## 1. Fix scope and versions

Identify the documentation repository and code repository, and pin each to a commit or revision before drafting. Represent relevant uncommitted code as a baseline commit plus an explicitly identified worktree diff. Record the paths in scope and the target page identity, including its environment, site, space, page ID or explicit parent, and current or Draft boundary as applicable.

## 2. Gather evidence

Search for symbols first, then read only the necessary methods and surrounding context. Keep concise notes that bind each claim to its version, repository-relative file, and symbol. Return relevant excerpts, diffs, and summaries by default; do not emit complete files, documents, or storage XML without a reason.

Re-read when new evidence, a failure, or state drift makes it necessary. Do not impose a read-once or sync-once limit, and do not treat fewer tool calls as the sole success criterion.

## 3. Reconcile the evidence table

For work involving multiple sources or mappings, build a concise table before writing long-form text. Include at least `source`, `target`, `condition`, `status`, `commit`, `file`, and `symbol`. Track create, update, delete, and exception paths separately when they apply; do not invent an inapplicable path.

Use these statuses:

- `confirmed in code`: the cited version and symbol directly establish the claim.
- `confirmed not mapped`: the cited code establishes that this flow has no mapping or handling path.
- `unconfirmed`: the available evidence cannot establish the claim, including behavior that requires live service observation.

Do not promote an inference, a failed search, a DTO declaration, or recently updated documentation to confirmed behavior. Resolve contradictions in the table or retain the weaker status before drafting.

## 4. Write and verify locally

Draft in one focused pass after the evidence is stable. Bind citations to a commit or revision, repository-relative file, and symbol. Obtain line numbers from the pinned source and recheck them together before finalizing; do not prefill approximate line numbers.

Review the content and diff, run the local checks required by the repository, and inspect rendering when layout matters. Continue to use this Skill's `Test-ConfluenceDocs.ps1` and Push preview controls; evidence review does not replace them.

## 5. Sync and read back

Use the existing preview → explicit authorization → execute → readback workflow. After a write, compare text, tables, links, and evidence completely. Ignore only service normalization already proven harmless by an explicit equivalence rule, such as a server-added macro ID covered by the existing readback rules; an unknown difference blocks completion or requires investigation.

If a result is uncertain, establish the remote state and reconcile the original operation before resending. Do not retry blindly, weaken comparison rules to hide drift, or claim success without verified readback.

## Lean and full workflows

A single-point, small documentation change may use a lean workflow without a mandatory evidence table or review ceremony. It still requires source verification, coverage of necessary branches, a concurrent-edit conflict check, and post-write readback. Use the full workflow for multiple sources, multiple branches, or any document that describes program behavior.

## Project-specific inputs

Page IDs, data-model names, a specific Draft version, and one-time direct-edit exceptions are project inputs. Put them in project configuration, mappings, adapters, or case documentation rather than turning them into general rules.

## Delegating

When delegating implementation or investigation to another AI, make the prompt self-contained: include the scope, evidence classifications, required paths, concise-output expectations, and completion report. The Code-Collaboration `write-implementation-prompt` Skill may help prepare that prompt, but the prompt must carry its own repository context rather than link relatively into another repository.

This workflow does not relax permissions, authorization, or current-versus-Draft publication boundaries. Never fabricate a plan, validation result, synchronization result, or successful readback.
