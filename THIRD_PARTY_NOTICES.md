<!--
SPDX-FileCopyrightText: 2026 SyuanTsai
SPDX-License-Identifier: Apache-2.0
-->

# Third-party dependency inventory

The repository does not vendor the source or binaries listed below; these dependencies are not vendored into the licensed work. They are referenced as runtimes, CI actions, or install-at-run-time validation tools and remain governed by their upstream licenses and notices.

| Dependency | Use | Upstream license | Upstream source |
| --- | --- | --- | --- |
| `actions/checkout@v7` | GitHub Actions repository checkout | MIT | https://github.com/actions/checkout |
| `actions/setup-go@v7` | GitHub Actions Go runtime setup | MIT | https://github.com/actions/setup-go |
| `actions/setup-node@v7` | GitHub Actions Node.js runtime setup | MIT | https://github.com/actions/setup-node |
| `agent-ecosystem/skill-validator@latest` | CI-only Agent Skill validator installed with `go install` | MIT | https://github.com/agent-ecosystem/skill-validator |
| `skill-tools@latest` | CI-only Agent Skill quality and routing CLI installed with npm | Apache-2.0 | https://github.com/skill-tools/skill-tools |
| PowerShell / Windows PowerShell | Executes repository scripts and tests | PowerShell 7 is MIT; Windows PowerShell is supplied under Microsoft terms | https://github.com/PowerShell/PowerShell |
| GitHub CLI | Checks Copilot-compatible Skill publishing in CI | MIT | https://github.com/cli/cli/blob/trunk/LICENSE |
| Go toolchain | Installs and runs `skill-validator` in CI | BSD-style Go license | https://go.dev/LICENSE |
| Node.js | Runs `skill-tools` in CI | MIT plus licenses for included third-party libraries | https://github.com/nodejs/node/blob/main/LICENSE |
| npm CLI | Installs `skill-tools` in CI | Artistic-2.0 plus dependency-specific licenses | https://github.com/npm/cli/blob/latest/LICENSE |

The workflow currently resolves the validator CLIs from mutable `@latest` selectors. Before a release or redistribution that includes downloaded artifacts, record the resolved versions and re-check their upstream license and bundled notices. This inventory does not replace the license files shipped by those upstream distributions.

Atlassian and Bitbucket REST documentation is linked from the Skills but is not copied into this repository. Jira, Confluence, Atlassian, and Bitbucket names and trademarks remain the property of their respective owners.
