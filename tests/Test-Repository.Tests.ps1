# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Atlassian Ecosystem Standard v1 repository contract' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:ValidatorPath = Join-Path $script:RepositoryRoot 'scripts/Test-Repository.ps1'
        $script:GitPath = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path
    }

    BeforeEach {
        $script:FixtureRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:FixtureRoot | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'catalog') -Destination $script:FixtureRoot -Recurse
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'config') -Destination $script:FixtureRoot -Recurse
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'skills') -Destination $script:FixtureRoot -Recurse
        & $script:GitPath -C $script:FixtureRoot init --quiet
        & $script:GitPath -C $script:FixtureRoot add -- catalog/source.json config skills
        if ($LASTEXITCODE -ne 0) { throw 'Could not prepare the repository contract fixture.' }
        $script:SkillId = 'configure-jira-api-access'
        $script:SkillRoot = Join-Path $script:FixtureRoot "skills/$($script:SkillId)"
    }

    It 'accepts the current schema v2 inventory and all canonical Skill packages' {
        # Scenario: The fixture contains exactly the six catalogued Atlassian Skills.
        # Purpose: Protect the source inventory and package identity contract.
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot } | Should -Not -Throw
    }

    It 'produces deterministic per-Skill content hashes' {
        # Scenario: The same clean fixture is validated twice.
        # Purpose: Make source content evidence reproducible for catalog and release records.
        $first = (& $script:ValidatorPath -RepositoryRoot $script:FixtureRoot | Select-Object -Last 1) | ConvertFrom-Json
        $second = (& $script:ValidatorPath -RepositoryRoot $script:FixtureRoot | Select-Object -Last 1) | ConvertFrom-Json
        @($first.skills).Count | Should -Be 6
        $first.skills.contentSha256 | Should -Be $second.skills.contentSha256
        @($first.skills.contentSha256 | Where-Object { $_ -notmatch '^[0-9a-f]{64}$' }).Count | Should -Be 0
    }

    It 'binds Git file modes into the per-Skill content identity' {
        # Scenario: A tracked Skill file changes only from 100644 to 100755.
        # Purpose: Ensure executable-bit changes cannot reuse the old package hash.
        $before = ((& $script:ValidatorPath -RepositoryRoot $script:FixtureRoot | Select-Object -Last 1) | ConvertFrom-Json)
        & $script:GitPath -C $script:FixtureRoot update-index --chmod=+x -- "skills/$($script:SkillId)/SKILL.md"
        if ($LASTEXITCODE -ne 0) { throw 'Could not change the fixture Git mode.' }
        $after = ((& $script:ValidatorPath -RepositoryRoot $script:FixtureRoot | Select-Object -Last 1) | ConvertFrom-Json)
        $beforeFile = @($before.skills | Where-Object skillId -CEq $script:SkillId)[0].files | Where-Object path -CEq 'SKILL.md'
        $afterFile = @($after.skills | Where-Object skillId -CEq $script:SkillId)[0].files | Where-Object path -CEq 'SKILL.md'
        $beforeFile.mode | Should -Be '100644'
        $afterFile.mode | Should -Be '100755'
        $beforeSkill = @($before.skills | Where-Object skillId -CEq $script:SkillId)[0]
        $afterSkill = @($after.skills | Where-Object skillId -CEq $script:SkillId)[0]
        $beforeSkill.contentSha256 | Should -Not -Be $afterSkill.contentSha256
    }

    It 'reads non-ASCII Git paths from the NUL-delimited index output' {
        # Scenario: A valid package file has a non-ASCII relative path.
        # Purpose: Prevent Git C-quoting from changing the candidate-bound inventory identity.
        $unicodePath = Join-Path $script:SkillRoot 'references/使用.md'
        Set-Content -LiteralPath $unicodePath -Value '# Unicode reference' -Encoding utf8NoBOM -NoNewline
        & $script:GitPath -C $script:FixtureRoot add -- "skills/$($script:SkillId)/references/使用.md"
        if ($LASTEXITCODE -ne 0) { throw 'Could not stage the Unicode fixture path.' }
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot } | Should -Not -Throw
    }

    It 'rejects an unlisted Skill directory' {
        # Scenario: A new package is placed under the canonical source root without catalog entry.
        # Purpose: Prevent unmanaged Skill content from entering a release.
        New-Item -ItemType Directory -Path (Join-Path $script:FixtureRoot 'skills/unlisted-skill') | Out-Null
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot } | Should -Throw '*inventory does not exactly match*'
    }

    It 'rejects publisher-discoverable Skills outside the catalog' {
        foreach ($relativePath in @('rogue/SKILL.md', 'plugins/scope/skills/rogue/SKILL.md')) {
            $roguePath = Join-Path $script:FixtureRoot ($relativePath.Replace('/', [IO.Path]::DirectorySeparatorChar))
            New-Item -ItemType Directory -Path (Split-Path -Parent $roguePath) -Force | Out-Null
            Set-Content -LiteralPath $roguePath -Value '# unlisted publisher package' -Encoding utf8NoBOM -NoNewline
            { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot } | Should -Throw '*Publisher-discoverable Skill inventory*'
        }
    }

    It 'rejects publisher-discoverable Skills outside the catalog' {
        foreach ($relativePath in @('rogue/SKILL.md', 'plugins/scope/skills/rogue/SKILL.md')) {
            $roguePath = Join-Path $script:FixtureRoot ($relativePath.Replace('/', [IO.Path]::DirectorySeparatorChar))
            New-Item -ItemType Directory -Path (Split-Path -Parent $roguePath) -Force | Out-Null
            Set-Content -LiteralPath $roguePath -Value '# unlisted publisher package' -Encoding utf8NoBOM -NoNewline
            { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot } | Should -Throw '*Publisher-discoverable Skill inventory*'
        }
    }

    It 'rejects non-package content at the canonical source root' {
        # Scenario: A file is placed beside the six Skill directories.
        # Purpose: Prevent ambiguous source-root content from bypassing package validation.
        Set-Content -LiteralPath (Join-Path $script:FixtureRoot 'skills/ignored.ps1') -Value 'Write-Output unsafe'
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot } | Should -Throw '*non-package or reparse entry*'
    }

    It 'rejects schema v1 or unknown source metadata fields' {
        # Scenario: The source inventory is downgraded or receives an unrecognized property.
        # Purpose: Keep the catalog contract exact and fail closed on legacy metadata.
        $sourcePath = Join-Path $script:FixtureRoot 'catalog/source.json'
        $source = Get-Content -LiteralPath $sourcePath -Raw | ConvertFrom-Json
        $source.schemaVersion = 1
        $source | Add-Member -NotePropertyName profiles -NotePropertyValue @()
        $source | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $sourcePath -Encoding utf8NoBOM
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot } | Should -Throw '*invalid property set*'
    }

    It 'rejects duplicate JSON properties before object materialization' {
        # Scenario: source.json contains two decoded sourceId keys.
        # Purpose: Prevent permissive JSON materialization from hiding conflicting identity.
        $sourcePath = Join-Path $script:FixtureRoot 'catalog/source.json'
        $text = Get-Content -LiteralPath $sourcePath -Raw
        $text = $text -replace '"sourceId": "atlassian-ecosystem",', '"sourceId": "atlassian-ecosystem", "sourceId": "other",'
        Set-Content -LiteralPath $sourcePath -Value $text -Encoding utf8NoBOM -NoNewline
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot } | Should -Throw '*duplicate JSON property*'
    }

    It 'rejects a repository-local security policy fork' {
        # Scenario: An adapter attempts to add a local security object beside central authority binding.
        # Purpose: Ensure security decisions remain in the normative repository.
        $adapterPath = Join-Path $script:FixtureRoot 'config/standard-v1.json'
        $adapter = Get-Content -LiteralPath $adapterPath -Raw | ConvertFrom-Json
        $adapter | Add-Member -NotePropertyName security -NotePropertyValue ([pscustomobject]@{ blockSeverities = @('critical', 'high') })
        $adapter | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $adapterPath -Encoding utf8NoBOM
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot } | Should -Throw '*invalid property set*'
    }

    It 'rejects an unsorted source inventory' {
        # Scenario: Two catalog entries are inverted while all IDs remain present.
        # Purpose: Preserve deterministic ordinal catalog identity.
        $sourcePath = Join-Path $script:FixtureRoot 'catalog/source.json'
        $source = Get-Content -LiteralPath $sourcePath -Raw | ConvertFrom-Json
        [array]::Reverse($source.skills)
        $source | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $sourcePath -Encoding utf8NoBOM
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot } | Should -Throw '*ordinal ascending order*'
    }

    It 'rejects untracked package content from the integrity inventory' {
        # Scenario: A file exists in a Skill package but is absent from the Git index.
        # Purpose: Bind content hashes to reviewed Git bytes rather than arbitrary filesystem bytes.
        Set-Content -LiteralPath (Join-Path $script:SkillRoot 'untracked.txt') -Value 'not indexed'
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot } | Should -Throw '*filesystem inventory does not match the Git index*'
    }

    It 'rejects unstaged package bytes that are not bound to the Git index' {
        # Scenario: A tracked Skill file changes after it was staged.
        # Purpose: Stop validation from accepting bytes different from the reviewed index.
        Add-Content -LiteralPath (Join-Path $script:SkillRoot 'SKILL.md') -Value ([Environment]::NewLine + 'Additional valid body text.')
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot } | Should -Throw '*working-tree content is not bound*'
    }

    It 'rejects malformed OpenAI metadata lexical style' {
        # Scenario: A YAML mapping key is quoted even though the repository contract forbids it.
        # Purpose: Keep metadata parsing deterministic across supported PowerShell versions.
        $metadataPath = Join-Path $script:SkillRoot 'agents/openai.yaml'
        $metadata = Get-Content -LiteralPath $metadataPath -Raw
        $metadata = $metadata -replace 'display_name: "Configure Jira API Access"', '"display_name": "Configure Jira API Access"'
        Set-Content -LiteralPath $metadataPath -Value $metadata -Encoding utf8NoBOM -NoNewline
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot } | Should -Throw '*quoted mapping key*'
    }

    It 'rejects malformed optional OpenAI interface fields' {
        # Scenario: A package declares an invalid brand color or an escaping icon path.
        # Purpose: Apply the central OpenAI metadata semantic baseline before package identity is emitted.
        $metadataPath = Join-Path $script:SkillRoot 'agents/openai.yaml'
        $metadata = Get-Content -LiteralPath $metadataPath -Raw
        $metadata = $metadata -replace '  default_prompt:', ('  brand_color: "not-a-color"' + [Environment]::NewLine + '  default_prompt:')
        Set-Content -LiteralPath $metadataPath -Value $metadata -Encoding utf8NoBOM -NoNewline
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot } | Should -Throw '*brand_color*hexadecimal*'

        $metadata = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'skills/configure-jira-api-access/agents/openai.yaml') -Raw
        $metadata = $metadata -replace '  default_prompt:', ('  icon_small: "./assets/../../outside.svg"' + [Environment]::NewLine + '  default_prompt:')
        Set-Content -LiteralPath $metadataPath -Value $metadata -Encoding utf8NoBOM -NoNewline
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot } | Should -Throw '*unsafe asset path*'
    }

    It 'rejects comments outside the SPDX license header' {
        # Scenario: A non-header YAML comment is appended to Skill metadata.
        # Purpose: Prevent ignored syntax from creating cross-parser metadata drift.
        Add-Content -LiteralPath (Join-Path $script:SkillRoot 'agents/openai.yaml') -Value '# unsupported comment'
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot } | Should -Throw '*unsupported or malformed syntax*'
    }
}
