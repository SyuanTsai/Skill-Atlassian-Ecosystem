# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
Set-StrictMode -Version Latest
function Test-SkillSpectorExceptionCandidateChange {
    param(
        [Parameter(Mandatory = $true)][string] $GitPath,
        [Parameter(Mandatory = $true)][string] $RepositoryRoot,
        [Parameter(Mandatory = $true)][string] $BaseRevision,
        [Parameter(Mandatory = $true)][string] $CandidateRevision
    )

    $baselineChanges = @(& $GitPath -C $RepositoryRoot diff --find-renames=100% --name-only "$BaseRevision...$CandidateRevision" -- config/skillspector-exceptions/ 2>$null)
    if ($LASTEXITCODE -ne 0) { throw 'Could not compare SkillSpector exception baselines.' }
    if ($baselineChanges.Count -gt 0) { return $true }

    $registryPath = 'config/skillspector-exceptions.json'
    $registries = @()
    foreach ($revision in @($BaseRevision, $CandidateRevision)) {
        $content = @(& $GitPath -C $RepositoryRoot show "${revision}:$registryPath" 2>$null)
        if ($LASTEXITCODE -ne 0) {
            # A failed show is absence only when the commit tree can be read and has no registry.
            $treeEntry = @(& $GitPath -C $RepositoryRoot ls-tree --name-only $revision -- $registryPath 2>$null)
            if ($LASTEXITCODE -ne 0 -or $treeEntry.Count -gt 0) {
                throw "Could not read SkillSpector exception registry at '$revision'."
            }
            $registries += [pscustomobject]@{ exists = $false; content = $null }
        }
        else {
            $registries += [pscustomobject]@{ exists = $true; content = ($content -join "`n") }
        }
    }
    if ($registries[0].exists -ne $registries[1].exists) { return $true }
    if (-not $registries[0].exists) { return $false }

    $normalized = foreach ($registry in $registries) {
        $value = ConvertFrom-Json -InputObject $registry.content -ErrorAction Stop
        $value.PSObject.Properties.Remove('gateEffect')
        ConvertTo-Json -InputObject $value -Depth 100 -Compress -ErrorAction Stop
    }
    return $normalized[0] -cne $normalized[1]
}

Export-ModuleMember -Function Test-SkillSpectorExceptionCandidateChange
