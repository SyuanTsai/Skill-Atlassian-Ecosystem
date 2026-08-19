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

    if (-not $Condition) {
        throw $Message
    }
}

Assert-True (Test-Path -LiteralPath $sourcePath -PathType Leaf) 'catalog/source.json is required.'
$source = Get-Content -Raw -Encoding UTF8 -LiteralPath $sourcePath | ConvertFrom-Json

Assert-True ($source.schemaVersion -eq 1) 'catalog/source.json schemaVersion must be 1.'
Assert-True ($source.sourceId -ceq 'atlassian-ecosystem') 'Stable sourceId must be atlassian-ecosystem.'
Assert-True ($source.repository -ceq 'https://github.com/SyuanTsai/Skill-Atlassian-Ecosystem.git') 'Repository URL is incorrect.'
Assert-True ($source.skillsRoot -ceq '.agents/skills') 'skillsRoot must be .agents/skills.'

$expectedSkills = @(
    'configure-jira-api-access',
    'publish-requirements-to-confluence',
    'review-bitbucket-pull-request',
    'work-with-jira'
)

$declaredSkills = @($source.skills | Sort-Object)
Assert-True (($declaredSkills -join "`n") -ceq (($expectedSkills | Sort-Object) -join "`n")) 'catalog/source.json must declare exactly the four Atlassian ecosystem Skills.'

$actualSkills = @(Get-ChildItem -LiteralPath $skillsRoot -Directory | Select-Object -ExpandProperty Name | Sort-Object)
Assert-True (($actualSkills -join "`n") -ceq (($expectedSkills | Sort-Object) -join "`n")) '.agents/skills must contain exactly the declared Atlassian skills.'

$requiredReferences = @{
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

$jiraSkill = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillsRoot 'work-with-jira/SKILL.md')
Assert-True ($jiraSkill -cmatch 'configure-jira-api-access') 'work-with-jira must retain the configure-jira-api-access fallback.'
Assert-True ($jiraSkill -cmatch 'connector') 'work-with-jira must retain connector-based Jira routing.'
Assert-True ($jiraSkill -cmatch 'If Jira API access is missing, invalid, or not yet verified') 'work-with-jira must keep API setup conditional rather than mandatory.'

$bitbucketSkill = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillsRoot 'review-bitbucket-pull-request/SKILL.md')
Assert-True ($bitbucketSkill -cmatch 'local Git') 'review-bitbucket-pull-request must use a verified local Git diff.'
Assert-True ($bitbucketSkill -cmatch 'explicitly instructs') 'review-bitbucket-pull-request must keep comment publication explicitly authorized.'
Assert-True ($bitbucketSkill -cmatch 'Do not edit or resolve comments, approve, request changes, decline, merge') 'review-bitbucket-pull-request must retain its remote-write exclusions.'

Write-Host 'Atlassian Ecosystem repository validation passed.'
Write-Host "Stable source: $($source.sourceId)"
Write-Host "Skills: $($expectedSkills -join ', ')"
