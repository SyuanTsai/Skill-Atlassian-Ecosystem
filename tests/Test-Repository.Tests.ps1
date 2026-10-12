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

    It 'UnitT10_discovers_omitted_tools_and_binds_regular_paths_before_hashing' {
        # Scenario: Trusted executable parameters are omitted or whitespace, and
        # a supplied non-leaf path is used as the Git executable.
        # Purpose: Discover omitted tools while rejecting explicit invalid paths
        # before repository bytes can be opened or hashed.
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot -TrustedGitPath ' ' -TrustedStatPath ' ' } | Should -Not -Throw

        $invalidGitPath = Join-Path $TestDrive 'not-a-trusted-git'
        New-Item -ItemType Directory -Path $invalidGitPath | Out-Null
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot -TrustedGitPath $invalidGitPath } |
            Should -Throw '*Trusted Git executable is not a regular non-reparse file*'

        if (-not $IsWindows) {
            $invalidStatPath = Join-Path $TestDrive 'not-a-trusted-stat'
            New-Item -ItemType Directory -Path $invalidStatPath | Out-Null
            { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot -TrustedStatPath $invalidStatPath } |
                Should -Throw '*Trusted stat executable is not a regular non-reparse file*'
        }

        $validatorText = Get-Content -LiteralPath $script:ValidatorPath -Raw
        $validatorText | Should -Match 'function Assert-NoReparseAncestors'
        $validatorText | Should -Match 'Assert-NoReparseAncestors -Path \$Path -Context "Raw file hash"'
        $validatorText | Should -Match 'Assert-RegularFileForHash -Item \$item -Context "Raw file hash"'
    }

    It 'UnitT15_AllowsOnlyIgnoredUntrackedPersonalSkillRuntime' {
        # Scenario: Bootstrap installs personal runtime Skills beside canonical source.
        # Purpose: Permit ignored local runtime while rejecting another public source root.
        $runtimeRoot = Join-Path $script:FixtureRoot '.agents/skills/personal-helper'
        New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $runtimeRoot 'SKILL.md') -Value '# Personal runtime fixture' -Encoding utf8NoBOM
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot } | Should -Throw '*Legacy .agents/skills source root*'
        $excludePath = Join-Path $script:FixtureRoot '.git/info/exclude'
        Add-Content -LiteralPath $excludePath -Value '/.agents/skills/'
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot } | Should -Not -Throw
        & $script:GitPath -C $script:FixtureRoot add -f -- '.agents/skills/personal-helper/SKILL.md'
        if ($LASTEXITCODE -ne 0) { throw 'Could not stage the runtime boundary fixture.' }
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot } | Should -Throw '*Legacy .agents/skills source root*'
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

    It 'ignores undocumented nested skills directories' {
        $ignoredPath = Join-Path $script:FixtureRoot 'docs/skills/ignored/SKILL.md'
        New-Item -ItemType Directory -Path (Split-Path -Parent $ignoredPath) -Force | Out-Null
        Set-Content -LiteralPath $ignoredPath -Value '# outside a documented publisher layout' -Encoding utf8NoBOM -NoNewline
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot } | Should -Not -Throw
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

    It 'UnitT25_Uses_commit_bound_read_only_snapshot_bytes_when_live_source_is_dirty' {
        # Scenario: A tracked-only snapshot is made from a commit, then the live checkout gains dirty, ignored, and extra files.
        # Purpose: Keep repository validation bound to the selected commit and prevent live checkout content from entering a source check.
        & $script:GitPath -C $script:FixtureRoot -c user.name=Test -c user.email=test@example.invalid commit --quiet -m 'snapshot fixture'
        if ($LASTEXITCODE -ne 0) { throw 'Could not commit the snapshot fixture.' }
        $expectedRevision = ([string](& $script:GitPath -C $script:FixtureRoot rev-parse HEAD)).Trim()
        if ($LASTEXITCODE -ne 0 -or $expectedRevision -notmatch '^[0-9a-f]{40}$') { throw 'Could not resolve the snapshot fixture revision.' }

        $snapshotRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $snapshotRoot | Out-Null
        $treeInfo = [Diagnostics.ProcessStartInfo]::new()
        $treeInfo.FileName = $script:GitPath
        $treeInfo.UseShellExecute = $false
        $treeInfo.RedirectStandardInput = $true
        $treeInfo.RedirectStandardOutput = $true
        $treeInfo.RedirectStandardError = $true
        $treeInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false, $true)
        foreach ($argument in @('-C', $script:FixtureRoot, 'ls-tree', '-r', '-z', '--full-tree', $expectedRevision, '--', 'catalog', 'config', 'skills')) {
            [void]$treeInfo.ArgumentList.Add($argument)
        }
        $treeProcess = [Diagnostics.Process]::new()
        $treeProcess.StartInfo = $treeInfo
        if (-not $treeProcess.Start()) { throw 'Could not enumerate the committed snapshot tree.' }
        $treeProcess.StandardInput.Close()
        $treeErrorTask = $treeProcess.StandardError.ReadToEndAsync()
        $treeOutput = $treeProcess.StandardOutput.ReadToEnd()
        $treeError = $treeErrorTask.GetAwaiter().GetResult()
        $treeProcess.WaitForExit()
        if ($treeProcess.ExitCode -ne 0) { throw "Could not enumerate the committed snapshot tree: $treeError" }
        $treeProcess.Dispose()
        foreach ($record in @($treeOutput.Split([char]0) | Where-Object { $_ -ne '' })) {
            if ([string]$record -cnotmatch '^(?<mode>100644|100755) blob (?<objectId>[0-9a-f]{40})\t(?<path>[^\x00\r\n]+)$') {
                throw "Could not parse committed snapshot tree entry '$record'."
            }
            $targetPath = Join-Path $snapshotRoot ([string]$Matches.path).Replace('/', [IO.Path]::DirectorySeparatorChar)
            New-Item -ItemType Directory -Path (Split-Path -Parent $targetPath) -Force | Out-Null
            $blobInfo = [Diagnostics.ProcessStartInfo]::new()
            $blobInfo.FileName = $script:GitPath
            $blobInfo.UseShellExecute = $false
            $blobInfo.RedirectStandardInput = $true
            $blobInfo.RedirectStandardOutput = $true
            $blobInfo.RedirectStandardError = $true
            foreach ($argument in @('-C', $script:FixtureRoot, 'cat-file', 'blob', [string]$Matches.objectId)) {
                [void]$blobInfo.ArgumentList.Add($argument)
            }
            $blobProcess = [Diagnostics.Process]::new()
            $blobProcess.StartInfo = $blobInfo
            if (-not $blobProcess.Start()) { throw "Could not read committed blob '$($Matches.objectId)'." }
            $blobProcess.StandardInput.Close()
            $blobErrorTask = $blobProcess.StandardError.ReadToEndAsync()
            $targetStream = [IO.File]::Open($targetPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $blobProcess.StandardOutput.BaseStream.CopyTo($targetStream) }
            finally { $targetStream.Dispose() }
            $blobError = $blobErrorTask.GetAwaiter().GetResult()
            $blobProcess.WaitForExit()
            if ($blobProcess.ExitCode -ne 0) { throw "Could not read committed blob: $blobError" }
            $blobProcess.Dispose()
        }
        Add-Content -LiteralPath (Join-Path $script:SkillRoot 'SKILL.md') -Value 'live tracked edit'
        $ignoredPath = Join-Path $script:SkillRoot 'ignored-live.txt'
        Set-Content -LiteralPath $ignoredPath -Value 'ignored live content' -Encoding utf8NoBOM
        Add-Content -LiteralPath (Join-Path $script:FixtureRoot '.git/info/exclude') -Value '/skills/*/ignored-live.txt'
        Set-Content -LiteralPath (Join-Path $script:SkillRoot 'untracked-live.txt') -Value 'extra live content' -Encoding utf8NoBOM

        $result = ((& $script:ValidatorPath -RepositoryRoot $snapshotRoot -ReadOnlySnapshot `
            -GitMetadataRoot $script:FixtureRoot -ExpectedRevision $expectedRevision | Select-Object -Last 1) | ConvertFrom-Json)
        @($result.skills).Count | Should -Be 6
        @($result.skills | Where-Object skillId -CEq $script:SkillId)[0].files.path | Should -Not -Contain 'ignored-live.txt'
        @($result.skills | Where-Object skillId -CEq $script:SkillId)[0].files.path | Should -Not -Contain 'untracked-live.txt'

        { & $script:ValidatorPath -RepositoryRoot $snapshotRoot -ReadOnlySnapshot `
            -GitMetadataRoot $script:FixtureRoot -ExpectedRevision ('0' * 40) } |
            Should -Throw '*HEAD does not match the expected commit revision*'

        $invalidGitRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $invalidGitRoot | Out-Null
        { & $script:ValidatorPath -RepositoryRoot $snapshotRoot -ReadOnlySnapshot `
            -GitMetadataRoot $invalidGitRoot -ExpectedRevision $expectedRevision } |
            Should -Throw "*Trusted Git snapshot command failed ('rev-parse --show-toplevel')*"

        $extraSnapshotPath = Join-Path $snapshotRoot 'extra-live-file.txt'
        Set-Content -LiteralPath $extraSnapshotPath -Value 'not committed' -Encoding utf8NoBOM
        { & $script:ValidatorPath -RepositoryRoot $snapshotRoot -ReadOnlySnapshot `
            -GitMetadataRoot $script:FixtureRoot -ExpectedRevision $expectedRevision } |
            Should -Throw '*Read-only candidate snapshot path inventory does not match the expected commit tree*'
        Remove-Item -LiteralPath $extraSnapshotPath -Force

        Add-Content -LiteralPath (Join-Path $snapshotRoot 'catalog/source.json') -Value ' '
        { & $script:ValidatorPath -RepositoryRoot $snapshotRoot -ReadOnlySnapshot `
            -GitMetadataRoot $script:FixtureRoot -ExpectedRevision $expectedRevision } |
            Should -Throw "*raw bytes are not bound to commit path 'catalog/source.json'*"

        Remove-Item -LiteralPath (Join-Path $snapshotRoot 'catalog/source.json') -Force
        { & $script:ValidatorPath -RepositoryRoot $snapshotRoot -ReadOnlySnapshot `
            -GitMetadataRoot $script:FixtureRoot -ExpectedRevision $expectedRevision } |
            Should -Throw '*path inventory does not match the expected commit tree*'
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

    It 'UnitT49_Review_skill_accepts_absence_and_rejects_malformed_or_unknown_frontmatter_fields' {
        # Scenario: The valid review Skill omits the optional allowed-tools field.
        # Purpose: Keep permission host-controlled while preserving strict syntax and unknown-field rejection.
        $skillPath = Join-Path $script:FixtureRoot 'skills/review-bitbucket-pull-request/SKILL.md'
        $skillText = Get-Content -LiteralPath $skillPath -Raw
        $skillText | Should -Not -Match '(?m)^allowed-tools:'
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot } | Should -Not -Throw

        foreach ($badDeclaration in @(
            "allowed-tools: Read, Glob`nallowed-tools: Write",
            'allowed-tools: Read,,Write',
            'allowed-tools: [Read, Write]',
            'allowed-tools: all',
            'allowed-tools: *',
            'allowed-tools: Read, Read',
            'allowed-tools: Read, Execute',
            ('allowed-tools: ' + ('R' * 257))
        )) {
            $invalidFrontmatter = $skillText -replace '(?m)^license: Apache-2\.0\r?$', ('license: Apache-2.0' + [Environment]::NewLine + $badDeclaration)
            Set-Content -LiteralPath $skillPath -Value $invalidFrontmatter -Encoding utf8NoBOM -NoNewline
            & $script:GitPath -C $script:FixtureRoot add -- 'skills/review-bitbucket-pull-request/SKILL.md'
            if ($LASTEXITCODE -ne 0) { throw 'Could not stage the invalid frontmatter fixture.' }
            { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot } | Should -Throw
        }

        $unsupportedFrontmatter = $skillText -replace '(?m)^license: Apache-2\.0\r?$', ('license: Apache-2.0' + [Environment]::NewLine + 'unreviewed-tools: Read')
        Set-Content -LiteralPath $skillPath -Value $unsupportedFrontmatter -Encoding utf8NoBOM -NoNewline
        & $script:GitPath -C $script:FixtureRoot add -- 'skills/review-bitbucket-pull-request/SKILL.md'
        if ($LASTEXITCODE -ne 0) { throw 'Could not stage the unsupported frontmatter fixture.' }
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot } | Should -Throw '*unsupported or duplicate frontmatter key*'
    }

    It 'UnitT50_Review_skill_must_not_preapprove_tools' {
        # Scenario: The review Skill declares all five canonical tools.
        # Purpose: Keep Bitbucket review permissions on the host permission flow instead of pre-approving tools.
        $skillPath = Join-Path $script:FixtureRoot 'skills/review-bitbucket-pull-request/SKILL.md'
        $skillTextWithoutPermissionField = Get-Content -LiteralPath $skillPath -Raw
        $skillText = $skillTextWithoutPermissionField -replace '(?m)^license: Apache-2\.0\r?$', ('license: Apache-2.0' + [Environment]::NewLine + 'allowed-tools: Read, Glob, Bash, WebFetch, Write')
        Set-Content -LiteralPath $skillPath -Value $skillText -Encoding utf8NoBOM -NoNewline
        & $script:GitPath -C $script:FixtureRoot add -- 'skills/review-bitbucket-pull-request/SKILL.md'
        if ($LASTEXITCODE -ne 0) { throw 'Could not stage the disallowed review-tool declaration fixture.' }

        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot } |
            Should -Throw '*review-bitbucket-pull-request*must not declare allowed-tools*'
    }

    It 'UnitT51_Review_skill_must_not_preapprove_read_and_glob' {
        # Scenario: The review Skill declares only Read and Glob.
        # Purpose: Keep host permission control even for a syntactically narrow declaration.
        $skillPath = Join-Path $script:FixtureRoot 'skills/review-bitbucket-pull-request/SKILL.md'
        $skillText = Get-Content -LiteralPath $skillPath -Raw
        $skillText = $skillText -replace '(?m)^license: Apache-2\.0\r?$', ('license: Apache-2.0' + [Environment]::NewLine + 'allowed-tools: Read, Glob')
        Set-Content -LiteralPath $skillPath -Value $skillText -Encoding utf8NoBOM -NoNewline
        & $script:GitPath -C $script:FixtureRoot add -- 'skills/review-bitbucket-pull-request/SKILL.md'
        if ($LASTEXITCODE -ne 0) { throw 'Could not stage the disallowed narrow review-tool declaration fixture.' }

        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot } |
            Should -Throw '*review-bitbucket-pull-request*must not declare allowed-tools*'
    }
}
