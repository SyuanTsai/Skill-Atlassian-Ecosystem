Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $repositoryRoot 'catalog/source.json'
$skillsRoot = Join-Path $repositoryRoot 'skills'

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
Assert-True ($source.schemaVersion -eq 1) 'catalog/source.json schemaVersion must be 1.'
Assert-True ($source.sourceId -ceq 'atlassian-ecosystem') 'Stable sourceId must be atlassian-ecosystem.'
Assert-True ($source.repository -ceq 'https://github.com/SyuanTsai/Skill-Atlassian-Ecosystem.git') 'Repository URL is incorrect.'
Assert-True ($source.skillsRoot -ceq 'skills') 'skillsRoot must be skills.'

$expectedSkills = @(
    'configure-bitbucket-api-access',
    'configure-confluence-api-access',
    'configure-jira-api-access',
    'publish-requirements-to-confluence',
    'review-bitbucket-pull-request',
    'work-with-jira'
)

$declaredSkills = @($source.skills | Sort-Object)
Assert-True (($declaredSkills -join "`n") -ceq (($expectedSkills | Sort-Object) -join "`n")) 'catalog/source.json must declare exactly the six Atlassian ecosystem Skills.'
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
    'configure-bitbucket-api-access' = @('references/configuration.md')
    'configure-confluence-api-access' = @('references/configuration.md')
    'configure-jira-api-access' = @('references/configuration.md', 'references/copilot-ide.md')
    'publish-requirements-to-confluence' = @('references/confluence-cloud-api.md', 'references/requirements-structure.md')
    'review-bitbucket-pull-request' = @('references/bitbucket-cloud-api.md')
    'work-with-jira' = @()
}

$requiredScripts = @{
    'configure-bitbucket-api-access' = @('scripts/Configure-BitbucketApiAccess.ps1', 'scripts/Test-BitbucketApiAccess.ps1')
    'configure-confluence-api-access' = @('scripts/Configure-ConfluenceApiAccess.ps1', 'scripts/Test-ConfluenceApiAccess.ps1')
    'configure-jira-api-access' = @('scripts/Configure-JiraApiAccess.ps1', 'scripts/Test-JiraApiAccess.ps1')
    'publish-requirements-to-confluence' = @()
    'review-bitbucket-pull-request' = @()
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

$bitbucketSetup = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillsRoot 'configure-bitbucket-api-access/SKILL.md')
Assert-True ($bitbucketSetup -cmatch 'BITBUCKET_API_TOKEN') 'Bitbucket setup must require BITBUCKET_API_TOKEN.'
Assert-True ($bitbucketSetup -cmatch 'read:repository:bitbucket') 'Bitbucket setup must require Repository Read for review baseline.'
Assert-True ($bitbucketSetup -cmatch 'read:pullrequest:bitbucket') 'Bitbucket setup must require Pull requests Read for review baseline.'
Assert-True ($bitbucketSetup -cmatch 'Configure-BitbucketApiAccess\.ps1') 'Bitbucket setup must route configuration through its canonical Fast Path.'
Assert-True ($bitbucketSetup -cmatch 'Do not regenerate equivalent') 'Bitbucket setup must prohibit ad-hoc replacement PowerShell when canonical scripts exist.'
Assert-True ($bitbucketSetup -cmatch 'Never include real credential values') 'Bitbucket setup must retain secret-redaction completion contract.'

$confluenceSetup = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillsRoot 'configure-confluence-api-access/SKILL.md')
Assert-True ($confluenceSetup -cmatch 'CONFLUENCE_API_TOKEN') 'Confluence setup must require CONFLUENCE_API_TOKEN.'
Assert-True ($confluenceSetup -cmatch 'https://api\.atlassian\.com/ex/confluence/\{cloudId\}') 'Confluence setup must use scoped-token cloud API base.'
Assert-True ($confluenceSetup -cmatch 'read:space:confluence') 'Confluence setup must include space-read scope.'
Assert-True ($confluenceSetup -cmatch 'read:page:confluence') 'Confluence setup must include page-read scope.'
Assert-True ($confluenceSetup -cmatch 'write:page:confluence') 'Confluence setup must include page-write scope for publishing.'
Assert-True ($confluenceSetup -cmatch 'Configure-ConfluenceApiAccess\.ps1') 'Confluence setup must route configuration through its canonical Fast Path.'
Assert-True ($confluenceSetup -cmatch 'Do not regenerate equivalent') 'Confluence setup must prohibit ad-hoc replacement PowerShell when canonical scripts exist.'
Assert-True ($confluenceSetup -cmatch 'Never include real credential values') 'Confluence setup must retain secret-redaction completion contract.'

$jiraSetup = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillsRoot 'configure-jira-api-access/SKILL.md')
Assert-True ($jiraSetup -cmatch 'JIRA_API_TOKEN') 'Jira setup must require JIRA_API_TOKEN.'
Assert-True (Test-Path -LiteralPath (Join-Path $skillsRoot 'configure-jira-api-access/scripts/Configure-JiraApiAccess.ps1') -PathType Leaf) 'Jira setup must retain the canonical Configure Fast Path.'
Assert-True (Test-Path -LiteralPath (Join-Path $skillsRoot 'configure-jira-api-access/scripts/Test-JiraApiAccess.ps1') -PathType Leaf) 'Jira setup must retain the deterministic validator.'
Assert-True ($jiraSetup -cmatch 'references/copilot-ide\.md') 'Jira setup must retain the GitHub Copilot IDE host-adapter reference.'
Assert-True ($jiraSetup -cmatch 'HostReloadContract') 'Jira setup must consume the shared host reload contract.'
Assert-True ($jiraSetup -cmatch 'Do not introduce a Copilot-only') 'Jira setup must prohibit a duplicated Copilot access implementation.'

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

$jiraSkill = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillsRoot 'work-with-jira/SKILL.md')
Assert-True ($jiraSkill -cmatch 'configure-jira-api-access') 'work-with-jira must retain the configure-jira-api-access fallback.'
Assert-True ($jiraSkill -cmatch 'connector') 'work-with-jira must retain connector-based Jira routing.'
Assert-True ($jiraSkill -cmatch 'If Jira API access is missing, invalid, or not yet verified') 'work-with-jira must keep API setup conditional rather than mandatory.'
Assert-True ($jiraSkill -cmatch 'IDE GitHub Copilot') 'work-with-jira must retain the IDE GitHub Copilot REST route.'
Assert-True ($jiraSkill -cmatch 'HostReloadContract') 'work-with-jira must consume the shared host reload contract instead of duplicating environment logic.'
Assert-True ($jiraSkill -cmatch 'search/jql') 'work-with-jira must retain bounded JQL REST guidance.'
Assert-True ($jiraSkill -cmatch 'nextPageToken') 'work-with-jira must retain JQL pagination guidance.'
Assert-True ($jiraSkill -cmatch 'Create permission') 'work-with-jira must require connector Create-permission preflight.'
Assert-True ($jiraSkill -cmatch 'issue types') 'work-with-jira must resolve issue types before connector creation.'
Assert-True ($jiraSkill -cmatch 'required fields') 'work-with-jira must resolve required fields before connector creation.'

$bitbucketSkill = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillsRoot 'review-bitbucket-pull-request/SKILL.md')
Assert-True ($bitbucketSkill -cmatch 'local Git') 'review-bitbucket-pull-request must use a verified local Git diff.'
Assert-True ($bitbucketSkill -cmatch 'explicitly instructs') 'review-bitbucket-pull-request must keep comment publication explicitly authorized.'
Assert-True ($bitbucketSkill -cmatch 'Do not edit or resolve comments, approve, request changes, decline, merge') 'review-bitbucket-pull-request must retain its remote-write exclusions.'
Assert-True ($bitbucketSkill -cmatch 'configure-bitbucket-api-access') 'review-bitbucket-pull-request must route missing or invalid REST access to configure-bitbucket-api-access.'

$confluenceSkill = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillsRoot 'publish-requirements-to-confluence/SKILL.md')
Assert-True ($confluenceSkill -cmatch 'configure-confluence-api-access') 'publish-requirements-to-confluence must route missing or invalid REST access to configure-confluence-api-access.'

$bitbucketReference = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillsRoot 'review-bitbucket-pull-request/references/bitbucket-cloud-api.md')
Assert-True ($bitbucketReference -cmatch 'inline\.to.+source/head side.+added or context') 'Bitbucket inline.to must map to the new PR source/head side.'
Assert-True ($bitbucketReference -cmatch 'inline\.from.+destination/base side.+removed') 'Bitbucket inline.from must map to the old PR destination/base side.'

$readme = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $repositoryRoot 'README.md')
Assert-True ($readme -cmatch 'configure-bitbucket-api-access') 'README must list configure-bitbucket-api-access.'
Assert-True ($readme -cmatch 'configure-confluence-api-access') 'README must list configure-confluence-api-access.'
Assert-True ($readme -cmatch 'exactly the expected six Atlassian ecosystem Skills') 'README validation summary must describe six Skills.'
Assert-True ($readme -cmatch 'IDE GitHub Copilot: Jira read-only access') 'README must document the IDE GitHub Copilot Jira route.'
Assert-True ($readme -cmatch '\$reviewedSkillRef') 'README must define one reviewed immutable Skill revision.'
Assert-True ($readme -cmatch 'gh skill preview SyuanTsai/Skill-Atlassian-Ecosystem "configure-jira-api-access@\$reviewedSkillRef"') 'README must preview the reviewed Jira setup Skill revision.'
Assert-True ($readme -cmatch 'gh skill preview SyuanTsai/Skill-Atlassian-Ecosystem "work-with-jira@\$reviewedSkillRef"') 'README must preview the reviewed Jira workflow Skill revision.'
Assert-True ($readme -cmatch 'gh skill install SyuanTsai/Skill-Atlassian-Ecosystem configure-jira-api-access --pin \$reviewedSkillRef --agent github-copilot --scope project') 'README must install the reviewed Jira setup Skill revision.'
Assert-True ($readme -cmatch 'gh skill install SyuanTsai/Skill-Atlassian-Ecosystem work-with-jira --pin \$reviewedSkillRef --agent github-copilot --scope project') 'README must install the reviewed Jira workflow Skill revision.'
Assert-True ($readme -cmatch 'HostReloadContract') 'README must document the shared host reload contract for Copilot.'

Write-Host 'Atlassian Ecosystem repository validation passed.'
Write-Host "Stable source: $($source.sourceId)"
Write-Host "Skills: $($expectedSkills -join ', ')"
