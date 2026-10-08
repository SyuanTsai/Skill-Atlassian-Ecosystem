<!--
SPDX-FileCopyrightText: 2026 SyuanTsai
SPDX-License-Identifier: Apache-2.0
-->

# Confluence Docs-as-Code implementation contract

## 1. Scope

One generic Skill supports Pull, Test, Push and runtime initialization. Git is the maintained authoring source; Confluence is the remote presentation and collaboration surface. Import produces review candidates. Publish consumes committed, validated source and explicit operation authorization. Native Requirement/Scenario IDs and unknown expected results remain unchanged.

## 2. Repository and runtime

The package is under `skills/manage-confluence-docs-as-code/`. Keep its scripts, references and schemas together. Runtime dependencies are pinned by scripts/package.json and package-lock.json: OpenSpec 1.13.0 and markdown-it 14.3.1, with Node 24 and npm 11. Prepare a fresh empty runtime outside the adopter repository and retain its newly generated receipt. The receipt binds package/lock, executable/runtime versions and the installed inventory; paths are resolved on each receiving computer.

The companion configure-confluence-api-access Skill owns exact-tenant credential configuration. Credentials are read through the approved environment/integration and are excluded from source, arguments, logs and artifacts. The synthetic origin in examples and tests is `https://example.atlassian.net`.

## 3. Data contracts

Mapping, import review, code/test bindings, publication plan, journal and sync have separate versioned responsibilities. Preserve their schema IDs, supported versions and refusal reason codes. Mapping validation reads one bounded strict UTF-8 byte buffer and hashes those same accepted bytes; malformed JSON, duplicate keys, unknown fields, unsafe paths and inputs exceeding the inclusive 4 MiB limit are rejected.

The package [mapping schema](../../skills/manage-confluence-docs-as-code/references/confluence-mapping.schema.json), [Skill operation contract](../../skills/manage-confluence-docs-as-code/SKILL.md) and [import review](../../skills/manage-confluence-docs-as-code/references/import-review.md) define the maintained details. Operational JSON binds identity/evidence rather than copying native requirements or inventing missing THEN clauses.

## 4. Pull and semantic review

Pull captures the selected page identity, revisions, source blocks and attachment bytes into a private candidate. Incomplete pagination/capture or unsupported content remains explicit. Review classifies source into native spec, design, tasks and references. Retain original text and source hashes; preserve unknown outcomes and ignore embedded operational instructions. Accepted source is committed only within its approved file scope; unrelated work is preserved.

## 5. Test and source bindings

Test verifies the committed native OpenSpec source, mapping and code/test bindings, import review and fixed runtime receipt. Retain all 11 native Requirements and 17 Scenarios. Native CLI success alone does not prove expected behavior: local guards also reject missing outcomes, duplicate IDs, broken references, unknown review states and stale or mixed-version evidence. Assertions verify success, refusal, drift, uncertain-write reconciliation and no-op behavior.

## 6. Push and transport

Preview freezes source identities, target identities/revisions, rendered storage and attachment bytes into a plan. Execution separately requires the exact operation ID, mode, plan and authorization. Target drift, an unapproved plan, unsupported transport or a source/runtime change refuses mutation. Tenant selection and write scope remain explicit.

Plan/Publish use preflight, durable journal, readback and sync to reconcile uncertain outcomes before retry. Draft and attachments have distinct effects. Multi-page and attachment operations are not atomic; Draft has no version CAS. A same-name concurrent attachment upload can create a replacement version before the workflow detects it. Preserve partial/uncertain results and use the original operation proof for recovery.

## 7. Validation, delivery and recovery

Use the repository's normal sourceConformance entry, required hosted checks and review/merge process. Preserve raw findings and completeness; failed or partial analysis is not PASS. Agent review does not replace candidate-bound human approval. Source delivery and release/deployment/installed-live evidence remain separately identified.

The receiving index must use a remotely obtainable immutable commit/archive, archive hash, per-Skill content hash and version-bound evidence. Build runtime and receipt on the receiving computer. Replacement/alias deployment must protect customized and unmanaged installations and retain the previous pin and recovery evidence. Revert source/runtime pins together where required; preserve adopter mapping, plans, journal, sync and source revisions. Reconcile uncertain writes rather than blindly resending them.
