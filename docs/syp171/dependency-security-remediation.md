<!--
SPDX-FileCopyrightText: 2026 SyuanTsai
SPDX-License-Identifier: Apache-2.0
-->

# Runtime dependencies and security verification

The package pins OpenSpec 1.13.0 and markdown-it 14.3.1 with a complete lock. Runtime initialization and verification bind these exact source package/lock bytes, versions and installed files in a new receipt. A receiving computer builds its own fresh empty runtime and receipt.

The markdown-it 14.x fixes are documented in [GHSA-253c-mchw-3w2r](https://github.com/advisories/GHSA-253c-mchw-3w2r), [GHSA-38c4-r59v-3vqw](https://github.com/advisories/GHSA-38c4-r59v-3vqw) and [GHSA-6v5v-wf23-fmfq](https://github.com/advisories/GHSA-6v5v-wf23-fmfq). The source reader retains the 14.x API with html/linkify/typographer disabled; this configuration does not substitute for a patched dependency.

The lock also contains OpenSpec -> fast-glob -> micromatch -> braces 3.0.3. [GHSA-vfj7-8cjw-p6xm](https://github.com/advisories/GHSA-vfj7-8cjw-p6xm) is an unresolved dependency finding. The fixed native invocation is validate with type change, strict, JSON and non-interactive mode. In the pinned CLI, the selected built-in tracked-tasks artifact resolves the fixed tasks.md path through the non-glob stat branch. This bounded reachability observation does not prove the entire dependency safe or waive a finding.

Dependency changes require a reviewed package/lock diff, fixed approved registry/integrity, regenerated runtime and relevant parser/renderer/receipt regressions. Official scanner findings and analysis completeness must be preserved. A partial scan or reachability note is not sourceConformance or release PASS. Keep original reports and environment-specific logs private; public evidence must be properly labelled and bind its real candidate and report identity.
