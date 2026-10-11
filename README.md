<!--
SPDX-FileCopyrightText: 2026 SyuanTsai
SPDX-License-Identifier: Apache-2.0
-->

# Skill-Atlassian-Ecosystem

Canonical source for the Atlassian ecosystem Agent Skills used across Jira, Confluence, and Bitbucket workflows.

Stable source ID: `atlassian-ecosystem`

## Repository validation retirement

The legacy `Validate` and `Skill Quality Gate` workflows are retired and their checks are no longer development or merge prerequisites. This candidate supplies the replacement Standard v1 canonical validation architecture; remote `main` is not release-ready until the exact candidate head passes its required CI, review, and release gates.

## License and provenance

The repository-authored Skills, scripts, tests, documentation, catalog metadata, and workflow configuration are licensed under [Apache-2.0](LICENSE). See [NOTICE](NOTICE) for attribution, [PROVENANCE.md](PROVENANCE.md) for the public source and licensing boundary, and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for external dependencies.

External services, trademarks, credentials, tenant data, and user content are not included in this license grant. SPDX headers and [REUSE.toml](REUSE.toml) identify the licensing information for distributed files.

## Skills

- `configure-bitbucket-api-access`
- `configure-confluence-api-access`
- `configure-jira-api-access`
- `publish-requirements-to-confluence`
- `review-bitbucket-pull-request`
- `work-with-jira`

## Stable PowerShell access commands

The three API-access Skills ship canonical PowerShell entry points. Agents should invoke these scripts instead of regenerating equivalent environment, token-input, Cloud-ID discovery, authentication, or validation snippets on every run.

Canonical source lives under `skills/`. The bootstrap/catalog layer installs managed runtime copies under the consumer repository's ignored `.agents/skills/` path.

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

Run the canonical Standard v1 source gate locally on a clean Git checkout:

```powershell
pwsh -NoProfile -File ./scripts/Validate.ps1
```

With no `-BaseCommit`, the adapter uses `HEAD^` as the source comparison base.
The local command and CI entry point invoke the same immutable PR54 central
runner. They resolve the approved toolchain, verify source and integrity
evidence, and execute the Skill and Atlassian repository regression suites.
The central report preserves its canonical exit code and `releaseEligible`
value; missing formal semantic evidence keeps the release gate blocked.
Legacy repository diagnostics remain covered by
`tests/RepositoryValidation.Tests.ps1`.

The read-only `pull_request` workflow runs `Validate.ps1 -SourceConformance`
against the event merge commit and its base. This source path invokes the
immutable PR54 central runner with a run-owned development-harness adapter,
checks all source stages and a nonzero Pester inventory, then routes only the
candidate-bound `sourceConformance` result to GitHub checks. Its canonical
Stage 6 and release eligibility remain unchanged. The Git-backed Atlassian
domain validator uses the clean checkout of that same commit because the
central runner's candidate archive intentionally has no `.git` directory.
The canonical job runs on Windows and executes the Windows PowerShell 5.1
repository contract inside its Stage 5 child validation.
The local command above uses the same central source route; source conformance
does not authorize a release or installation.

```powershell
pwsh -NoProfile -File ./tests/validate-repository.ps1
pwsh -NoProfile -File ./tests/validate-api-access.ps1
```

### Dormant Standard Core v2 source preparation

The protected Standard Core v2 preparation path remains dormant and requires an explicit `-PrepareSourceTools` or `-SourceValidation` selection. Its setup and execution are separate calls. Resolve one immutable base commit first, then pass the same full SHA, artifacts root, authority checkout, trusted run-owned root, and plan path to both steps. The Core v2 defaults are a 14,400-second aggregate operation deadline and a 3,600-second per-child limit; the legacy Standard v1 command above retains its 900-second timeout default. If `-ArtifactsRoot` is omitted for Core v2, the path is `%TEMP%/standard-core-artifacts`.

For PR19 preparation acceptance, run from a clean full Git checkout at the independently reviewed final preparation revision. At this stage the trusted driver revision and candidate source revision are intentionally the same commit; `BaseCommit` is a separate full SHA for the actual PR diff base and must be a distinct ancestor. Do not infer that base with `HEAD^` or make it equal to the driver revision. The existing preparation PR continues to use the protected Standard v1 CI route.

The public `Validate.ps1` Core v2 selector is a local convenience entry point for a checkout the caller has already selected and trusts. Do not use a candidate-owned public loader as the trust anchor for an untrusted pull-request event. For PR19 acceptance, invoke `Invoke-ProtectedSourceValidation.ps1` directly from the reviewed trusted checkout as shown below. After PR19 is normally merged, an adoption workflow must obtain its inline driver closure from the actual prep merge/event-base commit; the critical General/Pester launchers and their loader modules in the candidate must remain byte-identical to those event-base files. In that later adoption stage, the event-base driver, candidate source, and diff base can be different revisions.

```powershell
$repositoryRoot = '<clean checkout at the independently reviewed final preparation commit>'
$trustedDriverCheckout = $repositoryRoot
$baseCommit = '<full SHA of the actual PR base commit; distinct ancestor of source HEAD>'
$tempRoot = [IO.Path]::GetTempPath()
$runId = [guid]::NewGuid().ToString('N')
$artifactsRoot = Join-Path $tempRoot "syp304-pr19-artifacts-$runId"
$trustedToolRoot = Join-Path $tempRoot "syp304-pr19-trusted-tools-$runId"
$null = New-Item -ItemType Directory -Path $artifactsRoot,$trustedToolRoot
$runtimeArchivePath = '<official PowerShell 7 Windows x64 ZIP archive>'
$expectedRuntimeArchiveSha256 = '<SHA-256 from independently verified official release metadata>'
$actualRuntimeArchiveSha256 = (Get-FileHash -LiteralPath $runtimeArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualRuntimeArchiveSha256 -cne $expectedRuntimeArchiveSha256.ToLowerInvariant()) { throw 'PowerShell runtime archive hash mismatch.' }
Expand-Archive -LiteralPath $runtimeArchivePath -DestinationPath $trustedToolRoot
$pwsh = Join-Path $trustedToolRoot 'pwsh.exe'
if (-not (Test-Path -LiteralPath $pwsh -PathType Leaf)) { throw 'The verified run-owned PowerShell runtime is missing.' }
$env:RUN_OWNED_ROOT = $trustedToolRoot
$authorityRepositoryRoot = '<local checkout of the pinned ff85 authority revision>'
$sourceToolsPath = Join-Path $artifactsRoot 'source-tools-plan.json'
$protectedDriver = Join-Path $trustedDriverCheckout 'scripts/Invoke-ProtectedSourceValidation.ps1'

& $pwsh -NoProfile -NonInteractive -File $protectedDriver `
  -Mode PrepareSourceTools -RepositoryRoot $repositoryRoot -ArtifactsRoot $artifactsRoot `
  -AuthorityRepositoryRoot $authorityRepositoryRoot -TrustedToolRoot $trustedToolRoot `
  -BaseCommit $baseCommit -SourceToolsPath $sourceToolsPath `
  -OperationTimeoutSeconds 14400 -TimeoutSeconds 3600
if ($LASTEXITCODE -ne 0) { throw "Protected source preparation failed with exit code $LASTEXITCODE." }

& $pwsh -NoProfile -NonInteractive -File $protectedDriver `
  -Mode SourceValidation -RepositoryRoot $repositoryRoot -ArtifactsRoot $artifactsRoot `
  -AuthorityRepositoryRoot $authorityRepositoryRoot -TrustedToolRoot $trustedToolRoot `
  -BaseCommit $baseCommit -SourceToolsPath $sourceToolsPath `
  -OperationTimeoutSeconds 14400 -TimeoutSeconds 3600
if ($LASTEXITCODE -ne 0) { throw "Protected source validation failed with exit code $LASTEXITCODE." }
```

The repository contract validates exactly the expected six Atlassian ecosystem Skills, required metadata/references, all canonical Configure/Test scripts, product-specific safety and permission boundaries, deterministic API failure classifications, secret redaction under PowerShell 7 and Windows PowerShell 5.1, and the GitHub Copilot Jira host-adapter documentation contract.

Licensing checks also verify the required documents, catalog identity, Skill license declarations, and SPDX/REUSE coverage, including the Copilot host-adapter reference.

## Source metadata

`catalog/source.json` identifies this repository as stable source `atlassian-ecosystem`. Consumers should pin an immutable tag/commit/content hash according to the parent Catalog/Lock contract rather than tracking mutable latest content directly.
