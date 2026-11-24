<!--
SPDX-FileCopyrightText: 2026 SyuanTsai
SPDX-License-Identifier: Apache-2.0
-->

# Skill-Atlassian-Ecosystem

## Overview

**What it is:** A collection of Agent Skills for Jira, Confluence, and Bitbucket Cloud workflows.

**Problem it solves:** The Skills guide API access checks, issue updates, page publishing, and pull request review. API access checks are read-only, external writes require explicit user authorization, and the Skills instruct agents to keep credentials out of output.

**Key Skills**

| Skill | What it does |
| --- | --- |
| [`configure-bitbucket-api-access`](skills/configure-bitbucket-api-access/SKILL.md) | Set up Bitbucket Cloud API-token access and verify repository and pull request read permissions before review. |
| [`configure-confluence-api-access`](skills/configure-confluence-api-access/SKILL.md) | Check and repair scoped Confluence Cloud API access, including the Cloud ID, API base URL, and least-privilege read access. |
| [`configure-jira-api-access`](skills/configure-jira-api-access/SKILL.md) | Check and repair Jira Cloud API authentication, including IDE GitHub Copilot setup and a read-only JQL readiness check. |
| [`manage-confluence-docs-as-code`](skills/manage-confluence-docs-as-code/SKILL.md) | Maintain recurring Confluence documentation as Markdown in Git. Pull and map pages, preview fixed plans, check attachments and conflicts, and verify published content by reading it back. |
| [`publish-requirements-to-confluence`](skills/publish-requirements-to-confluence/SKILL.md) | Create or update a Confluence Cloud page from analyzed requirements, with preview, destination, draft, version-history, and authorization checks. |
| [`review-bitbucket-pull-request`](skills/review-bitbucket-pull-request/SKILL.md) | Review Bitbucket Cloud pull requests from complete local Git diffs, draft or publish findings, and review fixes with authorized replies and thread resolution. |
| [`work-with-jira`](skills/work-with-jira/SKILL.md) | Read or search Jira Cloud issues and make explicitly requested updates through approved integrations. Read issues through verified REST access in IDE GitHub Copilot. |

**Hosts and requirements:** The Jira Skills document use in Codex and in IDE GitHub Copilot with Agent Skills support. The Confluence docs-as-code Skill requires PowerShell 7.3 or later, Git, repository access, and a configured Confluence connection.

**Quick start:**

1. Use [SyuanTsai-AI-Instructions](https://github.com/SyuanTsai/SyuanTsai-AI-Instructions) for managed installation and version pinning, or see [IDE GitHub Copilot: Jira read-only access](#ide-github-copilot-jira-read-only-access) for pinned installation of the Jira Skills in Copilot.
2. See [Stable PowerShell access commands](#stable-powershell-access-commands) to set up and check API access.
3. See [Repository validation](#repository-validation) for repository checks and local diagnostics.

**License and attribution:** [Apache-2.0](LICENSE) · [NOTICE](NOTICE) · [Provenance](PROVENANCE.md)

## 概覽

**這是什麼：** 一組用於 Jira、Confluence 和 Bitbucket Cloud 工作流程的 Agent Skills。

**解決什麼問題：** 這些 Skills 提供 API 存取檢查、議題更新、頁面發布與 Pull Request 審查的操作指引。API 存取檢查採唯讀方式，對外寫入須經使用者明確授權，且 Skills 要求 Agent 不在輸出中揭露憑證。

**主要 Skills**

| Skill | 功能 |
| --- | --- |
| [`configure-bitbucket-api-access`](skills/configure-bitbucket-api-access/SKILL.md) | 設定 Bitbucket Cloud API 權杖存取，並在審查前確認儲存庫與 Pull Request 的讀取權限。 |
| [`configure-confluence-api-access`](skills/configure-confluence-api-access/SKILL.md) | 檢查並修復限定範圍的 Confluence Cloud API 存取設定，包括 Cloud ID、API 基礎網址與最小讀取權限。 |
| [`configure-jira-api-access`](skills/configure-jira-api-access/SKILL.md) | 檢查並修復 Jira Cloud API 驗證設定，包括 IDE 版 GitHub Copilot 的設定與唯讀 JQL 就緒檢查。 |
| [`manage-confluence-docs-as-code`](skills/manage-confluence-docs-as-code/SKILL.md) | 將持續維護的 Confluence 文件以 Markdown 存在 Git。擷取並對應頁面、預覽固定的計畫、檢查附件與衝突，並重新讀取已發布的內容以確認結果。 |
| [`publish-requirements-to-confluence`](skills/publish-requirements-to-confluence/SKILL.md) | 根據已分析的需求建立或更新 Confluence Cloud 頁面，包含預覽、發布目標、草稿、版本紀錄與授權檢查。 |
| [`review-bitbucket-pull-request`](skills/review-bitbucket-pull-request/SKILL.md) | 根據完整的本機 Git 差異審查 Bitbucket Cloud Pull Request、起草或發布審查意見，並在授權範圍內回覆及結束討論串，以複查修正。 |
| [`work-with-jira`](skills/work-with-jira/SKILL.md) | 透過核准的整合方式讀取或搜尋 Jira Cloud 議題，並執行使用者明確要求的更新。在 IDE 版 GitHub Copilot 中，透過已驗證的 REST 存取讀取議題。 |

**執行環境與需求：** Jira Skills 的文件說明如何在 Codex 及支援 Agent Skills 的 IDE 版 GitHub Copilot 中使用。以 Git 管理 Confluence 文件的 Skill 需要 PowerShell 7.3 以上版本、Git、儲存庫存取權限，以及已設定的 Confluence 連線。

**快速開始：**

1. 透過 [SyuanTsai-AI-Instructions](https://github.com/SyuanTsai/SyuanTsai-AI-Instructions) 進行受管理的安裝並鎖定版本，或參閱 [IDE 版 GitHub Copilot 的 Jira 唯讀存取](#ide-github-copilot-jira-read-only-access)，在 Copilot 中安裝指定版本的 Jira Skills。
2. 參閱 [PowerShell 存取命令](#stable-powershell-access-commands)，設定並檢查 API 存取。
3. 參閱 [儲存庫驗證](#repository-validation)，查看儲存庫檢查與本機診斷方式。

**授權與著作權標示：** [Apache-2.0](LICENSE) · [NOTICE](NOTICE) · [來源與授權範圍](PROVENANCE.md)

---

Canonical source for the Atlassian ecosystem Agent Skills used across Jira, Confluence, and Bitbucket workflows.

Stable source ID: `atlassian-ecosystem`

For source maintenance and review, follow the [central Skill maintenance guidelines](https://github.com/SyuanTsai/SyuanTsai-AI-Instructions/blob/76cee33b5e9b91b8a21f362f2936078c74a68fb7/docs/skill-maintenance-guidelines.md) when deciding scope, supporting resources, dependencies, and replacement cleanup.

## Repository validation retirement

The legacy `Validate` and `Skill Quality Gate` workflows are retired and their checks are no longer development or merge prerequisites. This candidate supplies the replacement Standard v1 canonical validation architecture; remote `main` is not release-ready until the exact candidate head passes its required CI, review, and release gates.

## License and provenance

The repository-authored Skills, scripts, tests, documentation, catalog metadata, and workflow configuration are licensed under [Apache-2.0](LICENSE). See [NOTICE](NOTICE) for attribution, [PROVENANCE.md](PROVENANCE.md) for the public source and licensing boundary, and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for external dependencies.

External services, trademarks, credentials, tenant data, and user content are not included in this license grant. SPDX headers and [REUSE.toml](REUSE.toml) identify the licensing information for distributed files.

## Skills

- `configure-bitbucket-api-access`
- `configure-confluence-api-access`
- `configure-jira-api-access`
- `manage-confluence-docs-as-code`
- `publish-requirements-to-confluence`
- `review-bitbucket-pull-request`
- `work-with-jira`

## Stable PowerShell access commands

The three API-access Skills ship canonical PowerShell entry points. Agents should invoke these scripts instead of regenerating equivalent environment, token-input, Cloud-ID discovery, authentication, or validation snippets on every run.

Canonical source lives under `skills/`. The bootstrap/catalog layer installs managed runtime copies under the consumer repository's ignored `.agents/skills/` path.

`manage-confluence-docs-as-code` captures an authorized Confluence scope into private candidates, reviews each source-block disposition, maps committed Markdown to exact page identities, and publishes an approved immutable plan with readback. General documentation does not require code/test/build/environment evidence; current-program-behavior claims retain an applicable code review. OpenSpec is optional external document organization and is not a Skill runtime dependency. Use `publish-requirements-to-confluence` for a one-off requirements page.

The [workflow behavior and SYP-171 requirement crosswalk](docs/development/confluence-docs-as-code.md) records the revised general-Markdown contract and links to the original source revision.

```text
skills/
  configure-bitbucket-api-access/scripts/
    Configure-BitbucketApiAccess.ps1
    Test-BitbucketApiAccess.ps1
  configure-confluence-api-access/scripts/
    Configure-ConfluenceApiAccess.ps1
    Test-ConfluenceApiAccess.ps1
  configure-jira-api-access/scripts/
    Configure-JiraApiAccess.ps1
    Test-JiraApiAccess.ps1
```

The `Configure-*` commands are the Fast Path for setup/repair. They use hidden token input and default to Process scope. Every run configures its current Process; User-scope persistence is additive and explicit, and token persistence requires the separate `-PersistTokenToUser` switch. Jira and Confluence automatically discover the tenant Cloud ID and derive the scoped API base. `Test-*` commands are read-only diagnostic/validation entry points and suppress credential/response-body output.

Connection validation uses only the effective Process environment. User/Machine-only values produce `HostEnvironmentState = reload-required` without a network request; differing Process/User values produce `process-user-mismatch` while the current Process is validated. `HostReloadContract` version 1 returns the host-neutral `recreate-host-process` action and records that child-to-parent environment mutation is unsupported. Codex and IDE adapters map that action to their own restart/reload behavior, then rerun the same validator.

## IDE GitHub Copilot: Jira read-only access

The Jira Skills remain one canonical Agent Skills source for Codex and IDE GitHub Copilot. There is no Copilot-only fork of the access scripts or credential logic.

GitHub Copilot project Skills may be installed under `.github/skills`, `.agents/skills`, or `.claude/skills`; personal Skills may be installed under `~/.copilot/skills` or `~/.agents/skills`. `gh skill` can install from this repository and automatically select the host directory. It is currently a public-preview GitHub CLI feature and requires GitHub CLI 2.90.0 or later.

Preview and install the same immutable reviewed revision. Set the value to a trusted release tag or full commit SHA; for pre-merge acceptance, use the exact reviewed PR head SHA. Unpinned commands can resolve a release or the default branch instead of the revision under review.

```powershell
$reviewedSkillRef = '<trusted-release-tag-or-full-commit-sha>'
gh --version
gh skill preview SyuanTsai/Skill-Atlassian-Ecosystem "configure-jira-api-access@$reviewedSkillRef"
gh skill preview SyuanTsai/Skill-Atlassian-Ecosystem "work-with-jira@$reviewedSkillRef"
```

Project scope, pinned to that same revision:

```powershell
gh skill install SyuanTsai/Skill-Atlassian-Ecosystem configure-jira-api-access --pin $reviewedSkillRef --agent github-copilot --scope project
gh skill install SyuanTsai/Skill-Atlassian-Ecosystem work-with-jira --pin $reviewedSkillRef --agent github-copilot --scope project
```

Before E2E acceptance, verify that both installed `SKILL.md` files' injected source-tracking metadata identifies this repository and the same reviewed revision. Use `--scope user` for personal installation across trusted repositories while retaining the same `--pin`. Use a current Copilot host with Agent Skills support: VS Code supports Agent Skills; for Visual Studio, verify the installed release against GitHub's current Copilot feature matrix before debugging Jira access.

After Skill installation or User-scope environment changes, start a new Copilot Agent session. If `Test-JiraApiAccess.ps1` returns `reload-required` or `process-user-mismatch`, follow its `HostReloadContract`: recreate the IDE/Copilot host, restore the token through the approved secret source when required, then rerun the same shared validator. Do not regenerate a second Copilot-specific Fast Path.

The host-specific acceptance path is documented in `skills/configure-jira-api-access/references/copilot-ide.md`. Final IDE validation must prove that the installed `work-with-jira` Skill returns the requested fields for one Jira issue and one bounded JQL read, and that a persisted-but-not-inherited configuration recovers through the actual IDE/Copilot host lifecycle without exposing credentials.

## Access-path boundary

Connector and REST API paths are separate. Once the user selects one path for the current operation, Skills must not silently fall back to the other after a failure. Connector availability does not invalidate a user-selected REST path, and environment-token presence does not force REST when the user selected a connector.

## Credential boundary

Jira, Confluence, and Bitbucket credentials are separately scoped. Tokens must be read only from approved environment variables, hidden interactive input, or an approved secret store. Never print, log, commit, embed in command arguments, or copy credentials into Jira/Confluence content.

## Repository validation

The authority-published `consumer-gate` workflow validates the candidate on
Windows, Linux, and macOS from the immutable authority commit in
`config/authority-pin.json`. Repository-owned behavior is limited to:

- `scripts/Test-AtlassianRepository.ps1`, which checks the catalog, Skill
  packages, frontmatter, OpenAI metadata, portable paths, and deterministic
  content inventory from a read-only snapshot;
- `scripts/Test-AtlassianSharedReferences.ps1`, which checks the three shared
  reference mappings byte for byte; and
- the complete `tests/` tree, discovered and executed by the pinned authority.

Both repository checks accept `-RepositoryRoot` and `-ReadOnlySnapshot`, work
without `.git`, and do not write into the candidate. The transition workflow is
used only for the initial conversion; after cleanup, routine authority upgrades
change only the full commit in `config/authority-pin.json`.

SkillSpector exception data is shrink-only. The retained
`review-bitbucket-pull-request` baseline contains three findings pending SYP-493
re-approval; no new or modified exception is accepted.

### Component diagnostics

The repository suite executes these diagnostic helpers and verifies their exit
codes:

```powershell
pwsh -NoProfile -File ./tests/validate-repository.ps1
pwsh -NoProfile -File ./tests/validate-api-access.ps1
```

The repository contract validates exactly the expected seven Atlassian ecosystem Skills, required metadata/references, all canonical Configure/Test scripts, product-specific safety and permission boundaries, deterministic API failure classifications, secret redaction under PowerShell 7 and Windows PowerShell 5.1, and the GitHub Copilot Jira host-adapter documentation contract.

Licensing checks also verify the required documents, catalog identity, Skill license declarations, and SPDX/REUSE coverage, including the Copilot host-adapter reference.

## Source metadata

`catalog/source.json` identifies this repository as stable source `atlassian-ecosystem`. Consumers should pin an immutable tag/commit/content hash according to the parent Catalog/Lock contract rather than tracking mutable latest content directly.
