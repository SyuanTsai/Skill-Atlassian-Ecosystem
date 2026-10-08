<!--
SPDX-FileCopyrightText: 2026 SyuanTsai
SPDX-License-Identifier: Apache-2.0
-->

# Source simplification and delivery contract

This public document records portable engineering requirements. Task-specific Jira state, private source material, local paths, execution logs and historical machine probes are maintained in private work records.

## Scope and invariants

Preserve the generic Pull/Push, Draft, attachment, mapping, drift, journal, readback, no-op and recovery behavior and all 11 native Requirement/17 Scenario identities and expectations. Consolidate duplicate JSON parsing and only helpers whose type, null, case, byte/text/file and error semantics are equivalent. Keep the four command interfaces, schemas and domain reason codes compatible. File count is an outcome, not an acceptance threshold.

Storage/readback and source projection may be combined only if the change removes actual duplication without expanding dependencies or responsibilities. The native subprocess wrapper may be combined with orchestration only if isolated native consumers remain isolated. The documented [simplification decisions](simplification-decisions.md) retain both boundaries.

## Acceptance

- AC171-01: Remove proven duplicate parsing/helpers; preserve four command interfaces, input/output/exit semantics and existing schema versions. Record both module-merger decisions.
- AC171-02: Keep native 11 REQ/17 SCN IDs and expectations. Bind applicable assertions and Agent semantic review to the exact candidate/input identity. Identify source, isolated installed and live evidence separately; unexecuted receiving work is not PASS.
- AC171-03: Complete the normal applicable source canonical validation and required source CI. Preserve original findings, completeness and the formal result. An unsatisfied required source gate remains incomplete.
- AC171-04: Complete source review and normal merge; verify the final full commit, archive hash, per-Skill content hashes and matching reports. Do not prefill identities or approvals.
- AC171-05: Supply a cross-computer receiving index, runtime build instructions, command examples, replacement/alias behavior, receiving live scenarios and recovery limits.
- AC171-06: Record truthful final acceptance and the delivery index in the authorized work tracker while preserving history. Source completion and central release/deployment/live completion remain distinct.

## Verification and workflow

Protect Mapping's duplicate-key, malformed UTF-8/JSON, unknown-field, path and size boundaries; preserve the digest of the exact accepted bytes. Verify direct helper callers and publication refusal/reconciliation assertions. Review synthetic mixed source, missing expected results and embedded instructions without inventing answers.

Run affected suites during refactoring, then the applicable complete domain regression and repository/standalone checks for the fixed candidate. Runtime/package/lock changes require a matching receipt and verification. Run the declared normal sourceConformance entry and hosted required checks on the actual candidate. A developer suite, reused scan on identical input or local reproduction is not a fresh canonical report. Tool defects use minimal neutral reproductions and the normal reviewed authority/upstream process; completeness, required checks and findings remain intact.

After normal review/merge, build and verify a source archive that excludes private work records and machine paths. Publish a fixed commit/archive URL, hashes and an evidence index that a receiving computer can obtain. Preserve raw private evidence; any public derived summary must identify its derivation and original evidence identity rather than impersonating a raw report. Use a fresh receiver-built runtime receipt.

## Receiving boundary and recovery

Central source/profile/lock integration, formal release/activation, host deployment, actual previous-Skill retirement and installed/live acceptance are receiving work. Source required checks must still pass. Preserve the replacement/alias contract, customized/unmanaged protections, previous immutable pin and recovery materials. See the [implementation contract](implementation-plan.md) and package references for operational limitations. Never mark unexecuted deployment/live tasks complete.
