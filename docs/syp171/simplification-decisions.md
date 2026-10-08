<!--
SPDX-FileCopyrightText: 2026 SyuanTsai
SPDX-License-Identifier: Apache-2.0
-->

# Source simplification decisions

## Shared parsing and equivalent helpers

- Mapping uses ConvertFrom-Syp171StrictJson for strict JSON and recursive duplicate-key rejection. The inclusive 4 MiB byte bound, empty-input refusal, strict UTF-8, depth 30, MappingSchemaInvalid and domain checks remain. Validation and digest use the same accepted buffer.
- Mapping, CodeBinding, Validation, ImportReview, Plan, Publish and Runtime share the existing StrictJson exact-key guard with unchanged IDictionary, Sort-Object and case-sensitive comparison semantics.
- Plan/Publish share the int/long minimum-value guard. Their byte-array hash uses the already imported Assets helper. UTF-8 text hashing, file hashing and JSON canonicalization keep their separate semantics.
- The Skill instructions consolidate selection of the four command entries while retaining unknown-result handling, source-instruction rejection, tenant/scope authorization, immutable plans and recovery limits.

## Module boundaries retained

ConfluenceStorage handles storage/readback equivalence, namespace/attribute/text/macro rules and attachment references. StorageProjection handles capture blocks and native-source projection and depends on Assets. Combining them would expand the dependency loaded by readback consumers without removing a second implementation. Their DTD/resolver protections remain separate.

OpenSpecSource is the isolated Node subprocess boundary used by native-only consumers and Push. ConfluenceValidation orchestrates Mapping, CodeBinding, ImportReview and coverage. Combining them would load orchestration into isolated native consumers without removing a duplicate wrapper. UTF-8, timeout, cleared child environment, fixed CLI/parser and error categories remain.

The package retains 32 files, including 14 modules and eight versioned schemas. There is no file-count gate or permanent shim added to reduce that count.

## Workflow and evidence

Checkout names its pinned action literally. Jobs, permissions, canonical/source routing, failure conditions, raw canonical outcome and runtime receipt checks remain unchanged. Workflow syntax must stay visible to the approved inventory classifier; aliases or token rewriting must not conceal execution surfaces.

The [delivery contract](source-simplification-and-goal-plan.md) requires exact-candidate tests and real normal source gates. Developer, canonical and installed/live evidence have separate scope. Preserve old failed attempts and source identities privately; public summaries and CI artifacts identify their actual evidence provenance.

## Recovery

Revert the functional refactor to restore the previous helpers with the same operational formats. Pair runtime/code rollback when dependencies change. Preserve existing adopter mapping, plan, journal, sync and source revisions. Source restoration does not authorize remote resends or overwrites.
