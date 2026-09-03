<!--
SPDX-FileCopyrightText: 2026 SyuanTsai
SPDX-License-Identifier: Apache-2.0
-->

# Source and licensing boundary

## Public source

This repository maintains reusable Agent Skills, PowerShell access helpers, documentation, and deterministic tests for Jira, Confluence, and Bitbucket. The Skills were extracted from the maintainer's reusable instruction collection and are maintained here as a standalone project.

The maintainer states that development used a personally funded AI subscription. This is a maintainer attestation, not independent verification or a legal ownership determination.

## Licensed scope

The repository-authored generic core is licensed under Apache-2.0:

- Skill instructions, agent metadata, and bundled references under `skills/`;
- generic configuration and read-only validation helpers under `skills/*/scripts/`;
- synthetic fixtures and repository checks under `tests/`;
- workflow configuration, catalog metadata, and repository documentation.

SPDX headers and `REUSE.toml` identify the applicable files. Attribution appears in `NOTICE`; the complete license text appears in `LICENSE` and `LICENSES/Apache-2.0.txt`.

## Exclusions and evidence boundary

The grant does not cover external dependencies or documentation, trademarks, credentials, tenant data, user-provided content, or outputs produced when applying the Skills. External tools remain governed by their own licenses; see `THIRD_PARTY_NOTICES.md`.

This public summary intentionally omits private account, employment, subscription, and audit records. It does not publish an organization-specific identity inventory or change historical Git metadata. Git identity alone is not a determination of content origin or ownership.

No organization-specific adapter or proprietary tenant configuration is distributed as part of this generic core. Future adapters or contributions with uncertain origin require their own source and licensing review before inclusion.

## Maintenance

Review provenance when introducing external code, vendored dependencies, new contributors, or tenant-specific material. Retain required third-party attribution and obtain any necessary rights before publishing changes. This document does not replace applicable agreements or legal advice.
