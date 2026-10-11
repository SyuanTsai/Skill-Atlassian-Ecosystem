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
| `actions/upload-artifact@v7` | Uploads run-owned validation evidence from CI | MIT | https://github.com/actions/upload-artifact |
| `agent-ecosystem/skill-validator@latest` | CI-only Agent Skill validator installed with `go install` | MIT | https://github.com/agent-ecosystem/skill-validator |
| `NVIDIA/SkillSpector@latest` | CI-only Agent Skill security scanner installed in the run-owned Python wheelhouse | Apache-2.0 | https://github.com/NVIDIA/SkillSpector |
| `Pester@latest` | CI-only PowerShell regression test runner installed with `Save-Module` | Apache-2.0 | https://github.com/pester/Pester |
| `skill-tools@latest` | CI-only Agent Skill quality and routing CLI installed with npm | Apache-2.0 | https://github.com/skill-tools/skill-tools |
| PowerShell / Windows PowerShell | Executes repository scripts and tests | PowerShell 7 is MIT; Windows PowerShell is supplied under Microsoft terms | https://github.com/PowerShell/PowerShell |
| GitHub CLI | Checks Copilot-compatible Skill publishing in CI | MIT | https://github.com/cli/cli/blob/trunk/LICENSE |
| Go toolchain | Installs and runs `skill-validator` in CI | BSD-style Go license | https://go.dev/LICENSE |
| Node.js | Runs `skill-tools` in CI | MIT plus licenses for included third-party libraries | https://github.com/nodejs/node/blob/main/LICENSE |
| npm CLI | Installs `skill-tools` in CI | Artistic-2.0 plus dependency-specific licenses | https://github.com/npm/cli/blob/latest/LICENSE |
| `@fission-ai/openspec@1.13.0` | Fixed native SDD validator installed from the runtime lock at run time | MIT | https://github.com/Fission-AI/OpenSpec/tree/9d4e5974e5c0d9a09b9c6c1e1eb0975e80ec4461 |
| `markdown-it@14.3.1` | Fixed Markdown token parser installed from the runtime lock at run time | MIT | https://github.com/markdown-it/markdown-it/tree/14.3.1 |

The workflow resolves validation tools through the central latest-stable-per-run policy and records their resolved identities in run-owned evidence. Before a release or redistribution that includes downloaded artifacts, re-check their upstream license and bundled notices. This inventory does not replace the license files shipped by those upstream distributions.

Atlassian and Bitbucket REST documentation is linked from the Skills but is not copied into this repository. Jira, Confluence, Atlassian, and Bitbucket names and trademarks remain the property of their respective owners.
