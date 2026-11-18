# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$sourcePath = Join-Path $repositoryRoot 'catalog/source.json'
$skillsRoot = Join-Path $repositoryRoot 'skills'
$licensePath = Join-Path $repositoryRoot 'LICENSE'
$spdxLicensePath = Join-Path $repositoryRoot 'LICENSES/Apache-2.0.txt'
$noticePath = Join-Path $repositoryRoot 'NOTICE'
$provenancePath = Join-Path $repositoryRoot 'PROVENANCE.md'
$thirdPartyNoticesPath = Join-Path $repositoryRoot 'THIRD_PARTY_NOTICES.md'
$reusePath = Join-Path $repositoryRoot 'REUSE.toml'

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool] $Condition,
        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    if (-not $Condition) { throw $Message }
}

function Assert-PowerShellParses {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref] $tokens, [ref] $parseErrors)
    Assert-True (@($parseErrors).Count -eq 0) "PowerShell parse failed for $Path`: $(@($parseErrors | ForEach-Object Message) -join '; ')"
}

Assert-True (Test-Path -LiteralPath $sourcePath -PathType Leaf) 'catalog/source.json is required.'
$source = Get-Content -Raw -Encoding UTF8 -LiteralPath $sourcePath | ConvertFrom-Json
Assert-True ($source.schemaVersion -eq 2) 'catalog/source.json schemaVersion must be 2.'
Assert-True ($source.sourceId -ceq 'atlassian-ecosystem') 'Stable sourceId must be atlassian-ecosystem.'
Assert-True ($source.repository -ceq 'https://github.com/SyuanTsai/Skill-Atlassian-Ecosystem.git') 'Repository URL is incorrect.'
Assert-True ($source.skillsRoot -ceq 'skills') 'skillsRoot must be skills.'


foreach ($requiredLicensingPath in @($licensePath, $spdxLicensePath, $noticePath, $provenancePath, $thirdPartyNoticesPath, $reusePath)) {
    Assert-True (Test-Path -LiteralPath $requiredLicensingPath -PathType Leaf) "Missing required licensing file: $requiredLicensingPath"
}

$license = (Get-Content -Raw -Encoding UTF8 -LiteralPath $licensePath) -replace "`r`n", "`n"
$spdxLicense = (Get-Content -Raw -Encoding UTF8 -LiteralPath $spdxLicensePath) -replace "`r`n", "`n"
Assert-True ($license -ceq $spdxLicense) 'LICENSE and LICENSES/Apache-2.0.txt must contain the same canonical text.'
Assert-True ($license -cmatch '(?s)^\s*Apache License\s+Version 2\.0, January 2004.*END OF TERMS AND CONDITIONS') 'Apache-2.0 license text is incomplete.'

$notice = Get-Content -Raw -Encoding UTF8 -LiteralPath $noticePath
Assert-True ($notice -cmatch 'Copyright 2026 SyuanTsai') 'NOTICE must identify the copyright holder.'

$thirdPartyNotices = Get-Content -Raw -Encoding UTF8 -LiteralPath $thirdPartyNoticesPath
foreach ($dependency in @('actions/checkout', 'actions/setup-go', 'actions/upload-artifact', 'agent-ecosystem/skill-validator', 'NVIDIA/SkillSpector', 'Pester', 'skill-tools')) {
    Assert-True ($thirdPartyNotices -cmatch [regex]::Escape($dependency)) "THIRD_PARTY_NOTICES.md is missing $dependency."
}
Assert-True ($thirdPartyNotices -cmatch 'not vendored') 'THIRD_PARTY_NOTICES.md must state the non-vendored dependency boundary.'

# Git checkouts may use LF or CRLF; normalize before exact multiline metadata checks.
$reuse = (Get-Content -Raw -Encoding UTF8 -LiteralPath $reusePath) -replace "`r`n", "`n"
Assert-True ($reuse -cmatch '(?m)^version = 1$') 'REUSE.toml must use schema version 1.'
Assert-True ($reuse -cmatch '(?m)^path = "catalog/source\.json"$') 'REUSE.toml must associate licensing information with catalog/source.json.'
Assert-True ($reuse -cmatch '(?m)^SPDX-License-Identifier = "Apache-2\.0"$') 'REUSE.toml must declare Apache-2.0 for uncommentable files.'

# Validate each maintained annotation, not just values occurring somewhere in the document.
$reuseAnnotations = @([regex]::Split($reuse, '(?m)^\[\[annotations\]\][ \t]*\n') | Select-Object -Skip 1)
foreach ($annotatedPath in @('catalog/source.json', 'config/standard-v1.json', 'NOTICE')) {
    $pathPattern = '(?m)^path = "' + [regex]::Escape($annotatedPath) + '"$'
    $matchingAnnotations = @($reuseAnnotations | Where-Object { $_ -cmatch $pathPattern })
    Assert-True ($matchingAnnotations.Count -eq 1) "REUSE.toml must contain exactly one annotation for $annotatedPath."
    $annotation = $matchingAnnotations[0]
    Assert-True ($annotation -cmatch '(?m)^SPDX-License-Identifier = "Apache-2\.0"$') "REUSE.toml must declare Apache-2.0 for $annotatedPath."
    Assert-True ($annotation -cmatch '(?m)^SPDX-FileCopyrightText = "2026 SyuanTsai"$') "REUSE.toml must declare copyright information for $annotatedPath."
}
$skillAnnotationPattern = '(?m)^path = "skills/\*/SKILL\.md"$'
$skillAnnotations = @($reuseAnnotations | Where-Object { $_ -cmatch $skillAnnotationPattern })
Assert-True ($skillAnnotations.Count -eq 1) 'REUSE.toml must contain exactly one annotation for skills/*/SKILL.md.'
Assert-True ($skillAnnotations[0] -cmatch '(?m)^precedence = "aggregate"$') 'The SKILL.md REUSE annotation must use aggregate precedence.'
Assert-True ($skillAnnotations[0] -cmatch '(?m)^SPDX-License-Identifier = "Apache-2\.0"$') 'The SKILL.md REUSE annotation must declare Apache-2.0.'
Assert-True ($skillAnnotations[0] -cmatch '(?m)^SPDX-FileCopyrightText = "2026 SyuanTsai"$') 'The SKILL.md REUSE annotation must declare copyright information.'

$expectedSkills = @(
    'configure-bitbucket-api-access',
    'configure-confluence-api-access',
    'configure-jira-api-access',
    'manage-confluence-docs-as-code',
    'publish-requirements-to-confluence',
    'review-bitbucket-pull-request',
    'work-with-jira'
)

$declaredSkills = @($source.skills | Sort-Object)
Assert-True (($declaredSkills -join "`n") -ceq (($expectedSkills | Sort-Object) -join "`n")) 'catalog/source.json must declare exactly the seven Atlassian ecosystem Skills.'
$gitCommand = Get-Command -Name git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$gitExecutable = if ($null -ne $gitCommand) { [string] $gitCommand.Source } else { $null }
$canInspectIgnoredPaths = -not [string]::IsNullOrWhiteSpace($gitExecutable) `
    -and (Test-Path -LiteralPath (Join-Path $repositoryRoot '.git'))
$actualSkills = @(
    Get-ChildItem -LiteralPath $skillsRoot -Directory | ForEach-Object {
        $relativeSkillPath = "skills/$($_.Name)/SKILL.md"
        $isIgnored = $false
        if ($canInspectIgnoredPaths) {
            $ignoreExitCode = & {
                if ($null -ne (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue)) {
                    $PSNativeCommandUseErrorActionPreference = $false
                }
                & $gitExecutable -C $repositoryRoot check-ignore --quiet -- $relativeSkillPath
                $LASTEXITCODE
            }
            $isIgnored = $ignoreExitCode -eq 0
        }
        if (-not $isIgnored) { $_.Name }
    } | Sort-Object
)
$global:LASTEXITCODE = 0
Assert-True (($actualSkills -join "`n") -ceq (($expectedSkills | Sort-Object) -join "`n")) 'skills must contain exactly the declared Atlassian skills.'

if ($canInspectIgnoredPaths) {
    $trackedRuntimeArtifacts = @(& $gitExecutable -C $repositoryRoot ls-files -- '.agents/**' '.codex/**' 'AGENTS.md' '.github/AI-Rules/**' '.github/copilot-instructions.md')
    Assert-True ($LASTEXITCODE -eq 0) 'Git failed while checking reserved runtime artifacts.'
    Assert-True ($trackedRuntimeArtifacts.Count -eq 0) 'Reserved Agent runtime artifacts must remain local and untracked.'
}
$global:LASTEXITCODE = 0

$requiredReferences = @{
    'configure-bitbucket-api-access' = @('references/configuration.md', 'references/environment-separation.md', 'references/shared-workflow.md')
    'configure-confluence-api-access' = @('references/configuration.md', 'references/environment-separation.md', 'references/shared-workflow.md')
    'configure-jira-api-access' = @('references/configuration.md', 'references/copilot-ide.md', 'references/environment-separation.md', 'references/host-resolved-fast-path.md', 'references/shared-workflow.md')
    'manage-confluence-docs-as-code' = @(
        'references/import-review.md',
        'references/confluence-mapping.schema.json',
        'references/capture.schema.json',
        'references/import-review.schema.json',
        'references/publish-plan.schema.json',
        'references/sync-state.schema.json',
        'references/operation-journal.schema.json',
        'references/authorization.schema.json'
        'references/environment-separation.md'
    )
    'publish-requirements-to-confluence' = @('references/confluence-cloud-api.md', 'references/environment-separation.md', 'references/requirements-structure.md')
    'review-bitbucket-pull-request' = @('references/bitbucket-cloud-api.md', 'references/review-actions.md')
    'work-with-jira' = @('references/environment-separation.md')
}

$requiredScripts = @{
    'configure-bitbucket-api-access' = @('scripts/Configure-BitbucketApiAccess.ps1', 'scripts/Test-BitbucketApiAccess.ps1')
    'configure-confluence-api-access' = @('scripts/Configure-ConfluenceApiAccess.ps1', 'scripts/Test-ConfluenceApiAccess.ps1')
    'configure-jira-api-access' = @('scripts/Configure-JiraApiAccess.ps1', 'scripts/Test-JiraApiAccess.ps1')
    'manage-confluence-docs-as-code' = @('scripts/Pull-ConfluenceDocs.ps1', 'scripts/Test-ConfluenceDocs.ps1', 'scripts/Push-ConfluenceDocs.ps1')
    'publish-requirements-to-confluence' = @()
    'review-bitbucket-pull-request' = @('scripts/Invoke-BitbucketReviewActions.ps1')
    'work-with-jira' = @()
}

foreach ($skillId in $expectedSkills) {
    $skillRoot = Join-Path $skillsRoot $skillId
    $skillFile = Join-Path $skillRoot 'SKILL.md'
    $openAiFile = Join-Path $skillRoot 'agents/openai.yaml'
    Assert-True (Test-Path -LiteralPath $skillFile -PathType Leaf) "$skillId is missing SKILL.md."
    Assert-True (Test-Path -LiteralPath $openAiFile -PathType Leaf) "$skillId is missing agents/openai.yaml."
    $skillContent = Get-Content -Raw -Encoding UTF8 -LiteralPath $skillFile
    Assert-True ($skillContent -cmatch "(?m)^name:\s*$([regex]::Escape($skillId))\s*$") "$skillId SKILL.md front matter must declare name: $skillId."
    Assert-True ($skillContent -cmatch '(?m)^license:\s*Apache-2\.0\s*$') "$skillId SKILL.md front matter must declare Apache-2.0."
    $openAiContent = Get-Content -Raw -Encoding UTF8 -LiteralPath $openAiFile
    Assert-True ($openAiContent -cmatch [regex]::Escape("`$$skillId")) "$skillId agents/openai.yaml default prompt must reference `$$skillId."
    foreach ($relativeReference in $requiredReferences[$skillId]) {
        Assert-True (Test-Path -LiteralPath (Join-Path $skillRoot $relativeReference) -PathType Leaf) "$skillId is missing $relativeReference."
    }
    foreach ($relativeScript in $requiredScripts[$skillId]) {
        $scriptPath = Join-Path $skillRoot $relativeScript
        Assert-True (Test-Path -LiteralPath $scriptPath -PathType Leaf) "$skillId is missing $relativeScript."
        Assert-PowerShellParses -Path $scriptPath
    }
}

$docsAsCodeRoot = Join-Path $skillsRoot 'manage-confluence-docs-as-code'
$operationalSchemas = @($requiredReferences['manage-confluence-docs-as-code'] | Where-Object { $_ -like '*.schema.json' })
$expectedOperationalSchemas = @(
    'references/authorization.schema.json',
    'references/capture.schema.json',
    'references/confluence-mapping.schema.json',
    'references/import-review.schema.json',
    'references/operation-journal.schema.json',
    'references/publish-plan.schema.json',
    'references/sync-state.schema.json'
)
Assert-True (($operationalSchemas | Sort-Object) -join "`n" -ceq (($expectedOperationalSchemas | Sort-Object) -join "`n")) 'manage-confluence-docs-as-code must ship exactly the seven required operational JSON Schemas.'
$schemaIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($relativeSchema in $operationalSchemas) {
    $schemaPath = Join-Path $docsAsCodeRoot $relativeSchema
    $schemaText = Get-Content -Raw -Encoding UTF8 -LiteralPath $schemaPath
    try { $schema = $schemaText | ConvertFrom-Json -AsHashtable -Depth 50 -ErrorAction Stop }
    catch { throw "$relativeSchema must be valid JSON: $($_.Exception.Message)" }
    Assert-True ($schema['$schema'] -ceq 'http://json-schema.org/draft-07/schema#') "$relativeSchema must pin JSON Schema Draft 7."
    Assert-True ($schema.type -ceq 'object' -and $schema.additionalProperties -eq $false) "$relativeSchema must reject unknown root properties."
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$schema['$id']) -and $schemaIds.Add([string]$schema['$id'])) "$relativeSchema must have a unique non-empty schema ID."
    Assert-True ($schemaText -cnotmatch '"(?:SHALL|THEN)"\s*:') "$relativeSchema must not contain an editable requirement or expected-result field."
}

$bitbucketSetup = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillsRoot 'configure-bitbucket-api-access/SKILL.md')
$sharedAccessWorkflow = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $repositoryRoot 'docs/shared-references/configure-api-access/shared-workflow.md')
Assert-True ($bitbucketSetup -cmatch 'BITBUCKET_API_TOKEN') 'Bitbucket setup must require BITBUCKET_API_TOKEN.'
Assert-True ($bitbucketSetup -cmatch 'read:repository:bitbucket') 'Bitbucket setup must require Repository Read for review baseline.'
Assert-True ($bitbucketSetup -cmatch 'read:pullrequest:bitbucket') 'Bitbucket setup must require Pull requests Read for review baseline.'
Assert-True ($bitbucketSetup -cmatch 'Configure-BitbucketApiAccess\.ps1') 'Bitbucket setup must route configuration through its canonical Fast Path.'
Assert-True ($bitbucketSetup -cmatch 'Do not regenerate equivalent') 'Bitbucket setup must prohibit ad-hoc replacement PowerShell when canonical scripts exist.'
Assert-True ($sharedAccessWorkflow -cmatch 'Never include real credential values') 'The shared API access workflow must retain the secret-redaction completion contract.'
Assert-True ($sharedAccessWorkflow -cmatch [regex]::Escape('Use Process scope by default.')) 'The shared API access workflow must use Process scope by default.'
Assert-True ($sharedAccessWorkflow -cmatch [regex]::Escape('Use User scope only after explaining persistence and obtaining authorization')) 'The shared API access workflow must require authorization before User-scope persistence.'
Assert-True ($sharedAccessWorkflow -cmatch [regex]::Escape('Treat Process scope as the only effective environment for connection validation.')) 'The shared API access workflow must validate connections only from Process scope.'
Assert-True ($sharedAccessWorkflow -cmatch [regex]::Escape('Without `-PersistTokenToUser`, the token remains Process-scoped even when non-secret settings are persisted.')) 'The shared API access workflow must keep a non-persisted token in Process scope.'
Assert-True ($sharedAccessWorkflow -cmatch [regex]::Escape('Process values apply only to the current process and future children; do not report Process-only settings as persisted.')) 'The shared API access workflow must retain Process-scope lifetime and reporting boundaries.'
Assert-True ($sharedAccessWorkflow -cmatch [regex]::Escape('Let `M` be the set of required Process values that are missing.')) 'The shared API access workflow must define M as the missing required Process values.'
Assert-True ($sharedAccessWorkflow -cmatch [regex]::Escape('1. `incomplete`: `M` is non-empty, and at least one value in `M` has no persisted candidate; do not send a request.')) 'The shared API access workflow must classify incomplete only for non-empty M with an unpersisted missing value.'
Assert-True ($sharedAccessWorkflow -cmatch [regex]::Escape('2. `reload-required`: `M` is non-empty, and every value in `M` has a persisted candidate in User or Machine scope; do not send a request.')) 'The shared API access workflow must classify reload-required only for non-empty M with persisted candidates for every missing value.'
Assert-True ($sharedAccessWorkflow -cmatch [regex]::Escape('3. `process-user-mismatch`: `M` is empty, and at least one persisted value differs from its Process value; the current Process may be tested, but report the mismatch and warn that a future host may inherit different values.')) 'The shared API access workflow must classify process-user-mismatch only for empty M with a persisted mismatch and retain its warning.'
Assert-True ($sharedAccessWorkflow -cmatch [regex]::Escape('4. `process-ready`: `M` is empty, and no persisted value differs from its Process value.')) 'The shared API access workflow must classify process-ready only for empty M without a persisted mismatch.'
Assert-True ($sharedAccessWorkflow -cmatch [regex]::Escape('For any input, exactly one state applies.')) 'The shared API access workflow must state that exactly one host environment state applies.'
Assert-True ($sharedAccessWorkflow -cmatch '(?s)1\. `incomplete`:.+?2\. `reload-required`:.+?3\. `process-user-mismatch`:.+?4\. `process-ready`:') 'The shared API access workflow must evaluate host environment states in incomplete, reload-required, process-user-mismatch, process-ready order.'
Assert-True ($sharedAccessWorkflow -cmatch [regex]::Escape('`PersistedButNotInheritedSettings` lists every persisted candidate whose required Process value is missing.')) 'The shared API access workflow must retain the exact persisted-but-not-inherited field.'
Assert-True ($sharedAccessWorkflow -cmatch [regex]::Escape('`ParentProcessMutationSupported = false`')) 'The shared API access workflow must prohibit parent-process mutation.'
Assert-True ($sharedAccessWorkflow -cmatch [regex]::Escape('`SecretSourceRequired = approved-secret-store-or-hidden-input`')) 'The shared API access workflow must retain the exact approved secret-source enumeration.'
Assert-True ($sharedAccessWorkflow -cmatch [regex]::Escape('respect `Retry-After` when present; do not retry aggressively')) 'The shared API access workflow must honor Retry-After without aggressive retries.'
Assert-True ($sharedAccessWorkflow -cmatch [regex]::Escape('separately verify the scopes or permissions required for the intended operation')) 'The shared API access workflow must separately verify the intended operation scopes or permissions after a successful probe.'
Assert-True ($sharedAccessWorkflow -cmatch [regex]::Escape('failure category')) 'The shared API access workflow must report the failure category.'
Assert-True ($sharedAccessWorkflow -cmatch [regex]::Escape('the user needs a specific non-sensitive field')) 'The shared API access workflow must limit the response-body exception to a user-needed specific non-sensitive field.'
Assert-True ($sharedAccessWorkflow -cmatch [regex]::Escape('its disclosure is justified')) 'The shared API access workflow must require justification for disclosing the specific non-sensitive field.'
Assert-True ($sharedAccessWorkflow -cmatch [regex]::Escape('return only that field, never the complete response body')) 'The shared API access workflow must return only the justified field and never the complete response body.'
Assert-True ($sharedAccessWorkflow -cmatch [regex]::Escape("each required setting's purpose, presence, source scope, and validation state")) 'The shared API access workflow must report each required setting purpose with its redacted inventory state.'
Assert-True ($sharedAccessWorkflow -cmatch [regex]::Escape('- `3xx`: reject the redirect without following it and fail closed as `redirect-rejected`.')) 'The shared API access workflow must reject redirects without following them.'
Assert-True ($sharedAccessWorkflow -cmatch [regex]::Escape('- `400`: request or configuration error; validate construction without exposing inputs.')) 'The shared API access workflow must classify 400 as a request or configuration error without exposing inputs.'
Assert-True ($sharedAccessWorkflow -cmatch [regex]::Escape('- `401`: authentication error; verify token type, account identity, expiration or revocation, and endpoint selection.')) 'The shared API access workflow must verify every listed 401 authentication diagnostic.'
Assert-True ($sharedAccessWorkflow -cmatch [regex]::Escape('- `403`: authorization, product permission, scope, or resource-access restriction; do not claim which one without evidence.')) 'The shared API access workflow must classify 403 without claiming an unsupported cause.'
Assert-True ($sharedAccessWorkflow -cmatch [regex]::Escape('- `404`: tenant, endpoint, path, or resource mismatch; verify identity without guessing.')) 'The shared API access workflow must verify 404 identity without guessing.'
Assert-True ($sharedAccessWorkflow -cmatch [regex]::Escape('- `5xx`: service unavailability, separate from credential failure.')) 'The shared API access workflow must separate 5xx service unavailability from credential failure.'
Assert-True ($sharedAccessWorkflow -cmatch [regex]::Escape('- Transport, network, proxy, DNS, certificate, or TLS failure: report separately from authentication.')) 'The shared API access workflow must report transport-layer failures separately from authentication.'
Assert-True ($sharedAccessWorkflow -cmatch [regex]::Escape('Repeated authentication failures after safe configuration and endpoint checks stop the workflow.')) 'The shared API access workflow must stop after repeated authentication failures.'
Assert-True ($sharedAccessWorkflow -cmatch [regex]::Escape('- the redacted tenant or API-base consistency result;')) 'The shared API access workflow completion report must include the redacted tenant or API-base consistency result.'
Assert-True ($sharedAccessWorkflow -cmatch [regex]::Escape('- each read-only endpoint category tested and its HTTP status;')) 'The shared API access workflow completion report must include each tested read-only endpoint category and status.'
Assert-True ($sharedAccessWorkflow -cmatch [regex]::Escape('- the minimum permissions or scopes required for the intended operation;')) 'The shared API access workflow completion report must include minimum permissions or scopes for the intended operation.'
Assert-True ($sharedAccessWorkflow -cmatch [regex]::Escape('- whether access is ready for that operation;')) 'The shared API access workflow completion report must state whether access is ready for the intended operation.'
Assert-True ($sharedAccessWorkflow -cmatch [regex]::Escape('- `HostEnvironmentState`, `PersistedButNotInheritedSettings`, conflicting setting names, and the required `HostReloadContract` action;')) 'The shared API access workflow completion report must include host state, conflicts, and the required reload action.'
Assert-True ($sharedAccessWorkflow -cmatch [regex]::Escape('- remaining token expiration, rotation, scope, or policy actions.')) 'The shared API access workflow completion report must include remaining token and policy actions.'

$environmentSeparation = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $repositoryRoot 'docs/shared-references/environment-separation/environment-separation.md')
$environmentResolutionOrderPattern = [regex]::Escape('Load this reference before every external-system access and resolve whether the target is the private environment or the work environment in this order:') + '\r?\n\r?\n' +
    [regex]::Escape('1. URL or site domain.') + '\r?\n' +
    [regex]::Escape('2. Issue-key prefix.') + '\r?\n' +
    [regex]::Escape('3. Repository mapping configuration.') + '\r?\n' +
    [regex]::Escape("4. The user's explicit designation.") + '\r?\n' +
    [regex]::Escape('5. If the environment is still unknown, stop and ask the user.')
Assert-True ($environmentSeparation -cmatch $environmentResolutionOrderPattern) 'The environment-separation source must preserve the ordered environment-resolution signals and unknown-environment stop.'
Assert-True ($environmentSeparation -cmatch [regex]::Escape('An issue-key prefix must have an explicit environment mapping. Store mappings such as the entries for `<PRIVATE-PREFIX>` and `<WORK-PREFIX>` only in the user''s local configuration outside managed Skill directories. Never write a prefix-to-environment mapping into a repository. If a required mapping is unavailable, stop and ask instead of guessing.')) 'The environment-separation source must stop when an external prefix mapping is unavailable.'
Assert-True ($environmentSeparation -cmatch [regex]::Escape('Before access, verify that the site or equivalent tenant identity and the project both belong to the resolved environment. Stop on a mismatch.')) 'The environment-separation source must verify site and project consistency before access.'
Assert-True ($environmentSeparation -cmatch [regex]::Escape('Before a write, show the resolved environment and site in the preview. Do not move data between environments unless the user explicitly requests and authorizes that cross-environment operation.')) 'The environment-separation source must preview write identity and require authorization for cross-environment movement.'

$bitbucketConfiguration = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillsRoot 'configure-bitbucket-api-access/references/configuration.md')
Assert-True ($bitbucketConfiguration -cmatch [regex]::Escape('validating both URL construction and workspace shape')) 'Bitbucket 400 remediation must validate URL construction and workspace shape.'

$confluenceSetup = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillsRoot 'configure-confluence-api-access/SKILL.md')
$confluenceConfiguration = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillsRoot 'configure-confluence-api-access/references/configuration.md')
Assert-True ($confluenceSetup -cmatch 'CONFLUENCE_API_TOKEN') 'Confluence setup must require CONFLUENCE_API_TOKEN.'
Assert-True ($confluenceSetup -cmatch 'scheme `https`') 'Confluence setup must pin the scoped-token API scheme.'
Assert-True ($confluenceSetup -cmatch 'host api\.atlassian\.com') 'Confluence setup must pin the scoped-token API host.'
Assert-True ($confluenceSetup -cmatch 'base path `/ex/confluence/\{cloudId\}`') 'Confluence setup must pin the scoped-token API base path.'
Assert-True ($confluenceSetup -cmatch 'read:space:confluence') 'Confluence setup must include space-read scope.'
Assert-True ($confluenceSetup -cmatch 'read:page:confluence') 'Confluence setup must include page-read scope.'
Assert-True ($confluenceSetup -cmatch 'write:page:confluence') 'Confluence setup must include page-write scope for publishing.'
Assert-True ($confluenceSetup -cmatch 'Configure-ConfluenceApiAccess\.ps1') 'Confluence setup must route configuration through its canonical Fast Path.'
Assert-True ($confluenceSetup -cmatch 'Do not regenerate equivalent') 'Confluence setup must prohibit ad-hoc replacement PowerShell when canonical scripts exist.'
Assert-True ($confluenceSetup -cmatch 'references/shared-workflow\.md') 'Confluence setup must load the shared completion and error-handling workflow.'
Assert-True ($confluenceSetup -cmatch 'attachment metadata requires `read:attachment:confluence`') 'Confluence setup must require read:attachment:confluence for attachment metadata.'
Assert-True ($confluenceSetup -cmatch 'official v1 binary attachment upload requires `read:content-details:confluence` and `write:attachment:confluence`') 'Confluence setup must restrict the minimum binary-upload attachment scopes to official v1.'
Assert-True ($confluenceSetup -cmatch [regex]::Escape('capture/preview requires page and space reads')) 'Confluence docs-as-code capture and preview must retain page and space read scopes.'
Assert-True ($confluenceSetup -cmatch [regex]::Escape('Request `write:page:confluence` only for approved page execution.')) 'Confluence docs-as-code page-write scope must remain limited to approved execution.'
Assert-True ($confluenceSetup -cmatch 'Keep the site, Cloud ID and API base identical across v1 and v2 paths') 'Confluence attachment and page paths must remain bound to the same tenant.'
Assert-True ($confluenceConfiguration -cmatch [regex]::Escape('validating both API-base construction and request shape')) 'Confluence 400 remediation must validate API-base construction and request shape.'
Assert-True ($confluenceConfiguration -cmatch '`expected denial`, `broader access`, `not run`, or `inconclusive`') 'Confluence completion evidence must retain all four least-privilege probe result states.'
Assert-True ($confluenceSetup -cmatch 'Before preparing the completion report, load the \*\*Completion supplement\*\*') 'Confluence setup must load its service-specific completion supplement before reporting.'

$jiraSetup = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillsRoot 'configure-jira-api-access/SKILL.md')
$jiraConfiguration = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillsRoot 'configure-jira-api-access/references/configuration.md')
Assert-True ($jiraSetup -cmatch 'JIRA_API_TOKEN') 'Jira setup must require JIRA_API_TOKEN.'
Assert-True (Test-Path -LiteralPath (Join-Path $skillsRoot 'configure-jira-api-access/scripts/Configure-JiraApiAccess.ps1') -PathType Leaf) 'Jira setup must retain the canonical Configure Fast Path.'
Assert-True (Test-Path -LiteralPath (Join-Path $skillsRoot 'configure-jira-api-access/scripts/Test-JiraApiAccess.ps1') -PathType Leaf) 'Jira setup must retain the deterministic validator.'
Assert-True ($jiraSetup -cmatch 'references/copilot-ide\.md') 'Jira setup must retain the GitHub Copilot IDE host-adapter reference.'
Assert-True ($jiraSetup -cmatch 'HostReloadContract') 'Jira setup must consume the shared host reload contract.'
Assert-True ($jiraSetup -cmatch 'Do not introduce a Copilot-only') 'Jira setup must prohibit a duplicated Copilot access implementation.'
Assert-True ($jiraConfiguration -cmatch 'Copilot Skill discovery and any required host recreation were completed before the successful validator rerun') 'Jira completion evidence must record Copilot discovery and host recreation before a successful rerun.'
Assert-True ($jiraSetup -cmatch 'Before preparing the completion report, load the \*\*Completion supplement\*\*') 'Jira setup must load its service-specific completion supplement before reporting.'
Assert-True ($jiraConfiguration -cmatch [regex]::Escape('`-TargetScope User` persists non-secret values on Windows only')) 'Jira scope selection must state that User persistence is supported only on Windows.'
Assert-True ($jiraConfiguration -cmatch [regex]::Escape('issue key, and resource visibility without guessing')) 'Jira not-found remediation must verify issue key and resource visibility.'
Assert-True ($jiraSetup -cmatch [regex]::Escape('8. Apply the shared workflow as the single failure-classification and host-state rule.')) 'Jira setup must retain one shared failure-classification and host-state rule.'
Assert-True ([regex]::Matches($jiraSetup, [regex]::Escape('8. Apply the shared workflow as the single failure-classification and host-state rule.')).Count -eq 1) 'Jira setup must contain the shared failure-classification and host-state rule exactly once.'
Assert-True ($jiraConfiguration -cmatch '(?s)first verify the identity and endpoint scopes.*?then check product access and account permissions') 'Jira 403 remediation must verify scopes before product access and account permissions.'

# Scenario: The setup Skill validates endpoint readiness before handing off the user-visible Jira request.
# Purpose: A response-body-suppressing validator must not be described as proof of the final work-with-jira result.
Assert-True ($jiraSetup -cmatch 'preflight the requested read endpoint') 'Jira setup must describe Issue/JQL validator calls as endpoint preflight.'
Assert-True ($jiraSetup -cmatch 'does not replace the user-visible read through `work-with-jira`') 'Jira setup must distinguish validator readiness from the final Jira workflow.'

$copilotReference = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillsRoot 'configure-jira-api-access/references/copilot-ide.md')
Assert-True ($copilotReference -cmatch '\.github/skills') 'Copilot reference must document project Skill discovery.'
Assert-True ($copilotReference -cmatch '~/.copilot/skills') 'Copilot reference must document personal Skill discovery.'
Assert-True ($copilotReference -cmatch '\$reviewedSkillRef') 'Copilot reference must define one reviewed immutable Skill revision.'
Assert-True ($copilotReference -cmatch 'gh skill preview SyuanTsai/Skill-Atlassian-Ecosystem "configure-jira-api-access@\$reviewedSkillRef"') 'Copilot reference must preview the reviewed Jira setup Skill revision.'
Assert-True ($copilotReference -cmatch 'gh skill preview SyuanTsai/Skill-Atlassian-Ecosystem "work-with-jira@\$reviewedSkillRef"') 'Copilot reference must preview the reviewed Jira workflow Skill revision.'
Assert-True ($copilotReference -cmatch 'gh skill install SyuanTsai/Skill-Atlassian-Ecosystem configure-jira-api-access --pin \$reviewedSkillRef --agent github-copilot --scope project') 'Copilot reference must install the reviewed Jira setup Skill revision.'
Assert-True ($copilotReference -cmatch 'gh skill install SyuanTsai/Skill-Atlassian-Ecosystem work-with-jira --pin \$reviewedSkillRef --agent github-copilot --scope project') 'Copilot reference must install the reviewed Jira workflow Skill revision.'
Assert-True ($copilotReference -cmatch 'recreate-host-process') 'Copilot reference must map the shared reload contract to host recreation.'
Assert-True ($copilotReference -cmatch 'reload-required') 'Copilot reference must document persisted-but-not-inherited handling.'
Assert-True ($copilotReference -cmatch 'IssueKey') 'Copilot reference must retain one-issue E2E validation.'
Assert-True ($copilotReference -cmatch 'Jql') 'Copilot reference must retain JQL E2E validation.'

# Scenario: The Copilot reference provides separate, user-visible Issue and JQL workflow prompts after validation.
# Purpose: HTTP-only validator checks must not pass as proof that the installed work-with-jira Skill returns requested fields.
$normalizedCopilotReference = $copilotReference.Replace("`r`n", "`n")
$copilotWorkflowPrompts = @(
    [regex]::Matches($normalizedCopilotReference, '(?ms)^```text\n(?<Prompt>.*?)\n```[ \t]*$') |
        ForEach-Object { $_.Groups['Prompt'].Value } |
        Where-Object { $_ -cmatch 'Use the installed `work-with-jira` Skill' }
)
$copilotIssuePrompts = @($copilotWorkflowPrompts | Where-Object { $_ -cmatch 'DEMO-42' -and $_ -cmatch 'Perform no writes' })
$copilotJqlPrompts = @($copilotWorkflowPrompts | Where-Object { $_ -cmatch 'project = DEMO ORDER BY created DESC' -and $_ -cmatch 'at most 20 results' -and $_ -cmatch 'Perform no writes' })
Assert-True ($copilotReference -cmatch 'validator is a preflight') 'Copilot E2E must identify the shared validator as preflight rather than the user-visible workflow.'
Assert-True ($copilotIssuePrompts.Count -ge 1) 'Copilot E2E must include a read-only issue prompt routed through the installed work-with-jira Skill.'
Assert-True ($copilotJqlPrompts.Count -ge 1) 'Copilot E2E must include a bounded read-only JQL prompt routed through the installed work-with-jira Skill.'
Assert-True ($copilotReference -cmatch 'returned issue fields') 'Copilot E2E must verify user-visible issue fields rather than only an HTTP status.'
Assert-True ($copilotReference -cmatch 'returned JQL result fields') 'Copilot E2E must verify user-visible JQL fields rather than only an HTTP status.'

# Scenario: User-scope values change after the real IDE/Copilot host starts, then the host is recreated.
# Purpose: Unit-test environment readers or child-shell restarts must not substitute for the required host lifecycle proof.
Assert-True ($copilotReference -cnotmatch '(?i)observed or simulated') 'Copilot E2E must not accept a test double in place of the actual host lifecycle.'
Assert-True ($copilotReference -cmatch 'actual IDE/Copilot host') 'Copilot E2E must observe persisted-but-not-inherited recovery in the actual host.'

$jiraSkill = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillsRoot 'work-with-jira/SKILL.md')
Assert-True ($jiraSkill -cmatch 'configure-jira-api-access') 'work-with-jira must retain the configure-jira-api-access fallback.'
Assert-True ($jiraSkill -cmatch 'connector') 'work-with-jira must retain connector-based Jira routing.'
Assert-True ($jiraSkill -cmatch 'If Jira API access is missing, invalid, or not yet verified') 'work-with-jira must keep API setup conditional rather than mandatory.'
Assert-True ($jiraSkill -cmatch 'IDE GitHub Copilot') 'work-with-jira must retain the IDE GitHub Copilot REST route.'
Assert-True ($jiraSkill -cmatch [regex]::Escape('Delegate the Copilot reload and shared `HostReloadContract` details')) 'work-with-jira must delegate Copilot reload and host contract behavior to configure-jira-api-access.'
Assert-True ($jiraSkill -cmatch [regex]::Escape('do not hardcode repository, `.agents`, `.github`, or home-directory paths')) 'work-with-jira must prohibit hardcoded repository and home helper paths.'
Assert-True ($jiraSkill -cmatch [regex]::Escape('Do not diagnose an environment inheritance mismatch as a bad token')) 'work-with-jira must not misdiagnose host inheritance as token failure.'
Assert-True ($jiraSkill -cmatch 'search/jql') 'work-with-jira must retain bounded JQL REST guidance.'
Assert-True ($jiraSkill -cmatch 'nextPageToken') 'work-with-jira must retain JQL pagination guidance.'
Assert-True ($jiraSkill -cmatch 'Create permission') 'work-with-jira must require connector Create-permission preflight.'
Assert-True ($jiraSkill -cmatch 'issue types') 'work-with-jira must resolve issue types before connector creation.'
Assert-True ($jiraSkill -cmatch 'required fields') 'work-with-jira must resolve required fields before connector creation.'

$bitbucketSkill = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillsRoot 'review-bitbucket-pull-request/SKILL.md')
Assert-True ($bitbucketSkill -cmatch 'local Git') 'review-bitbucket-pull-request must use a verified local Git diff.'
Assert-True ($bitbucketSkill -cmatch 'explicitly instructs') 'review-bitbucket-pull-request must keep comment publication explicitly authorized.'
# Scenario: SYP-275 permits scoped Create/Reply/Resolve with other exclusions retained.
# Purpose: Package contract must agree with the supported execution flow.
Assert-True ($bitbucketSkill -cmatch 'Do not edit or delete comments, reopen threads, approve, request changes, decline, merge') 'Bitbucket review must retain exclusions outside scoped feedback actions.'
Assert-True ($bitbucketSkill -cmatch 'Invoke-BitbucketReviewActions\.ps1') 'Bitbucket REST actions must use the shared package helper.'
Assert-True ($bitbucketSkill -cmatch 'configure-bitbucket-api-access') 'review-bitbucket-pull-request must route missing or invalid REST access to configure-bitbucket-api-access.'

$confluenceSkill = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillsRoot 'publish-requirements-to-confluence/SKILL.md')
Assert-True ($confluenceSkill -cmatch 'configure-confluence-api-access') 'publish-requirements-to-confluence must route missing or invalid REST access to configure-confluence-api-access.'
Assert-True ($confluenceSkill -cmatch [regex]::Escape('technical details needed for implementation')) 'publish-requirements-to-confluence must preserve technical details needed for implementation.'
Assert-True ($confluenceSkill -cmatch [regex]::Escape('mark missing information explicitly')) 'publish-requirements-to-confluence must explicitly mark every missing-information category.'
Assert-True ($confluenceSkill -cmatch [regex]::Escape('separating business intent from proposed implementation')) 'publish-requirements-to-confluence must unconditionally separate business intent from proposed implementation.'
Assert-True ($confluenceSkill -cmatch 'preserve links, and use supported headings, lists, tables, and code blocks') 'publish-requirements-to-confluence must preserve supported source structure.'
Assert-True ($confluenceSkill -cmatch 'Return the page ID and user-facing link without exposing unrelated private site data') 'publish-requirements-to-confluence must return safe page identity without unrelated private site data.'
Assert-True ($confluenceSkill -cmatch [regex]::Escape('3. For an update, read both the latest published page and the `get-draft=true` storage view, including parent, title, status, version, and body. This is the single conflict rule: if same-title candidates or their parents leave the target ambiguous, stop and ask the user to select the exact target; if a draft diverges or either view changes after preview or authorization, stop, summarize the divergence safely, preserve both states, and obtain explicit reconciliation instructions and renewed authorization before rebuilding. Never overwrite or reconcile automatically.')) 'publish-requirements-to-confluence must retain the complete ambiguity, divergence, reauthorization, and no-overwrite conflict rule.'
Assert-True ([regex]::Matches($confluenceSkill, [regex]::Escape('3. For an update, read both the latest published page and the `get-draft=true` storage view, including parent, title, status, version, and body. This is the single conflict rule: if same-title candidates or their parents leave the target ambiguous, stop and ask the user to select the exact target; if a draft diverges or either view changes after preview or authorization, stop, summarize the divergence safely, preserve both states, and obtain explicit reconciliation instructions and renewed authorization before rebuilding. Never overwrite or reconcile automatically.')).Count -eq 1) 'publish-requirements-to-confluence must contain the complete conflict rule exactly once.'

$bitbucketReference = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillsRoot 'review-bitbucket-pull-request/references/bitbucket-cloud-api.md')
Assert-True ($bitbucketReference -cmatch 'inline\.to.+source/head side.+added or context') 'Bitbucket inline.to must map to the new PR source/head side.'
Assert-True ($bitbucketReference -cmatch 'inline\.from.+destination/base side.+removed') 'Bitbucket inline.from must map to the old PR destination/base side.'

$readme = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $repositoryRoot 'README.md')
Assert-True ($readme -cmatch 'configure-bitbucket-api-access') 'README must list configure-bitbucket-api-access.'
Assert-True ($readme -cmatch 'configure-confluence-api-access') 'README must list configure-confluence-api-access.'
Assert-True ($readme -cmatch 'exactly the expected seven Atlassian ecosystem Skills') 'README validation summary must describe seven Skills.'
Assert-True ($readme -cmatch 'manage-confluence-docs-as-code') 'README must list the Docs-as-Code Skill.'
Assert-True ($readme -cmatch 'IDE GitHub Copilot: Jira read-only access') 'README must document the IDE GitHub Copilot Jira route.'
Assert-True ($readme -cmatch '\$reviewedSkillRef') 'README must define one reviewed immutable Skill revision.'
Assert-True ($readme -cmatch 'gh skill preview SyuanTsai/Skill-Atlassian-Ecosystem "configure-jira-api-access@\$reviewedSkillRef"') 'README must preview the reviewed Jira setup Skill revision.'
Assert-True ($readme -cmatch 'gh skill preview SyuanTsai/Skill-Atlassian-Ecosystem "work-with-jira@\$reviewedSkillRef"') 'README must preview the reviewed Jira workflow Skill revision.'
Assert-True ($readme -cmatch 'gh skill install SyuanTsai/Skill-Atlassian-Ecosystem configure-jira-api-access --pin \$reviewedSkillRef --agent github-copilot --scope project') 'README must install the reviewed Jira setup Skill revision.'
Assert-True ($readme -cmatch 'gh skill install SyuanTsai/Skill-Atlassian-Ecosystem work-with-jira --pin \$reviewedSkillRef --agent github-copilot --scope project') 'README must install the reviewed Jira workflow Skill revision.'
Assert-True ($readme -cmatch 'HostReloadContract') 'README must document the shared host reload contract for Copilot.'
Assert-True ($readme -cmatch 'installed `work-with-jira` Skill returns the requested fields') 'README must require a user-visible Jira workflow rather than validator-only E2E.'
Assert-True ($readme -cmatch 'actual IDE/Copilot host lifecycle') 'README must require the real Copilot reload lifecycle.'

Assert-True ($readme -cmatch 'Apache-2\.0') 'README must identify the repository license.'
Assert-True ($readme -cmatch 'PROVENANCE\.md') 'README must link the provenance record.'
Assert-True ($readme -cmatch 'THIRD_PARTY_NOTICES\.md') 'README must link the third-party inventory.'

$spdxFiles = @(
    Get-Item -LiteralPath (Join-Path $repositoryRoot 'README.md'), $provenancePath, $thirdPartyNoticesPath
    if (Test-Path -LiteralPath (Join-Path $repositoryRoot '.github') -PathType Container) {
        Get-ChildItem -LiteralPath (Join-Path $repositoryRoot '.github') -Recurse -File | Where-Object Extension -in @('.yml', '.yaml')
    }
    Get-ChildItem -LiteralPath $skillsRoot -Recurse -File | Where-Object {
        $repositoryRelativePath = $_.FullName.Substring($repositoryRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar).Replace('\', '/')
        $_.Extension -in @('.md', '.ps1', '.yml', '.yaml') -and $repositoryRelativePath -cnotmatch '^skills/[^/]+/SKILL\.md$'
    }
    Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'tests') -Recurse -File | Where-Object Extension -eq '.ps1'
)
foreach ($spdxFile in $spdxFiles) {
    $spdxContent = Get-Content -Raw -Encoding UTF8 -LiteralPath $spdxFile.FullName
    Assert-True ($spdxContent -cmatch '(?m)SPDX-FileCopyrightText:\s*2026 SyuanTsai\s*$') "$($spdxFile.FullName) is missing SPDX copyright information."
    Assert-True ($spdxContent -cmatch ('(?m)SPDX-License' + '-Identifier:\s*Apache-2\.0\s*$')) "$($spdxFile.FullName) is missing the Apache-2.0 SPDX identifier."
}

# Standard v1 section 4.5.1 moves SKILL.md licensing to REUSE.toml and forbids SPDX lines in the body.
$slimmedSkillIds = @(
    'configure-bitbucket-api-access'
    'configure-confluence-api-access'
    'configure-jira-api-access'
    'manage-confluence-docs-as-code'
    'publish-requirements-to-confluence'
    'work-with-jira'
)
foreach ($skillId in $slimmedSkillIds) {
    $skillContent = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillsRoot "$skillId/SKILL.md")
    Assert-True ($skillContent -cnotmatch '(?m)^\s*SPDX-(?:FileCopyrightText|License-Identifier):') "$skillId SKILL.md must not contain SPDX body lines under section 4.5.1."
}
# 後續單 SYP-493，因中央 contentSha256 釘住：review-bitbucket-pull-request/SKILL.md 暫時豁免反向檢查。

Write-Host 'Atlassian Ecosystem repository validation passed.'
Write-Host "Stable source: $($source.sourceId)"
Write-Host "Skills: $($expectedSkills -join ', ')"
