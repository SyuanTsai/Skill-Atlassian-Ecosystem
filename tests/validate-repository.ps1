Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $repositoryRoot 'catalog/source.json'
$skillsRoot = Join-Path $repositoryRoot '.agents/skills'

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool] $Condition,
        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    if (-not $Condition) { throw $Message }
}

Assert-True (Test-Path -LiteralPath $sourcePath -PathType Leaf) 'catalog/source.json is required.'
$source = Get-Content -Raw -Encoding UTF8 -LiteralPath $sourcePath | ConvertFrom-Json
Assert-True ($source.schemaVersion -eq 1) 'catalog/source.json schemaVersion must be 1.'
Assert-True ($source.sourceId -ceq 'atlassian-ecosystem') 'Stable sourceId must be atlassian-ecosystem.'
Assert-True ($source.repository -ceq 'https://github.com/SyuanTsai/Skill-Atlassian-Ecosystem.git') 'Repository URL is incorrect.'
Assert-True ($source.skillsRoot -ceq '.agents/skills') 'skillsRoot must be .agents/skills.'

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
$actualSkills = @(Get-ChildItem -LiteralPath $skillsRoot -Directory | Select-Object -ExpandProperty Name | Sort-Object)
Assert-True (($actualSkills -join "`n") -ceq (($expectedSkills | Sort-Object) -join "`n")) '.agents/skills must contain exactly the declared Atlassian skills.'

$requiredReferences = @{
    'configure-bitbucket-api-access' = @('references/configuration.md')
    'configure-confluence-api-access' = @('references/configuration.md')
    'configure-jira-api-access' = @('references/configuration.md')
    'publish-requirements-to-confluence' = @('references/confluence-cloud-api.md', 'references/requirements-structure.md')
    'review-bitbucket-pull-request' = @('references/bitbucket-cloud-api.md')
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
}

$bitbucketSetup = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillsRoot 'configure-bitbucket-api-access/SKILL.md')
Assert-True ($bitbucketSetup -cmatch 'BITBUCKET_API_TOKEN') 'Bitbucket setup must require BITBUCKET_API_TOKEN.'
Assert-True ($bitbucketSetup -cmatch 'read:repository:bitbucket') 'Bitbucket setup must require Repository Read for review baseline.'
Assert-True ($bitbucketSetup -cmatch 'read:pullrequest:bitbucket') 'Bitbucket setup must require Pull requests Read for review baseline.'
Assert-True ($bitbucketSetup -cmatch 'Never include real credential values') 'Bitbucket setup must retain secret-redaction completion contract.'

$confluenceSetup = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillsRoot 'configure-confluence-api-access/SKILL.md')
Assert-True ($confluenceSetup -cmatch 'CONFLUENCE_API_TOKEN') 'Confluence setup must require CONFLUENCE_API_TOKEN.'
Assert-True ($confluenceSetup -cmatch 'https://api\.atlassian\.com/ex/confluence/\{cloudId\}') 'Confluence setup must use scoped-token cloud API base.'
Assert-True ($confluenceSetup -cmatch 'read:space:confluence') 'Confluence setup must include space-read scope.'
Assert-True ($confluenceSetup -cmatch 'read:page:confluence') 'Confluence setup must include page-read scope.'
Assert-True ($confluenceSetup -cmatch 'write:page:confluence') 'Confluence setup must include page-write scope for publishing.'
Assert-True ($confluenceSetup -cmatch 'Never include real credential values') 'Confluence setup must retain secret-redaction completion contract.'

$jiraSkill = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillsRoot 'work-with-jira/SKILL.md')
Assert-True ($jiraSkill -cmatch 'configure-jira-api-access') 'work-with-jira must retain the configure-jira-api-access fallback.'
Assert-True ($jiraSkill -cmatch 'If Jira API access is missing, invalid, or not yet verified') 'work-with-jira must keep API setup conditional rather than mandatory.'

$bitbucketSkill = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillsRoot 'review-bitbucket-pull-request/SKILL.md')
Assert-True ($bitbucketSkill -cmatch 'local Git') 'review-bitbucket-pull-request must use a verified local Git diff.'
Assert-True ($bitbucketSkill -cmatch 'explicitly instructs') 'review-bitbucket-pull-request must keep comment publication explicitly authorized.'
Assert-True ($bitbucketSkill -cmatch 'Do not edit or resolve comments, approve, request changes, decline, merge') 'review-bitbucket-pull-request must retain its remote-write exclusions.'

$bitbucketReference = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillsRoot 'review-bitbucket-pull-request/references/bitbucket-cloud-api.md')
Assert-True ($bitbucketReference -cmatch 'inline\.to.+source/head side.+added or context') 'Bitbucket inline.to must map to the new PR source/head side.'
Assert-True ($bitbucketReference -cmatch 'inline\.from.+destination/base side.+removed') 'Bitbucket inline.from must map to the old PR destination/base side.'

Write-Host 'Atlassian Ecosystem repository validation passed.'
Write-Host "Stable source: $($source.sourceId)"
Write-Host "Skills: $($expectedSkills -join ', ')"
