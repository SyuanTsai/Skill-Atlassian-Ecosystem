# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AtlassianSourceCommon.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'SkillSpectorExceptionCandidates.psm1') -ErrorAction Stop
$script:SourceRepository = 'https://github.com/SyuanTsai/Skill-Atlassian-Ecosystem.git'

$script:PreparedSourceAuthorityCommit = '3c55daaa2a3b22eca9fb3e1749ed16589a260b1e'
$script:PreparedSourceAuthorityArchiveSha256 = 'eaebca9d034aa8d3447e82f0e499766da5f4b01a75230d4880bea8f8a46ba230'
$script:SourceAuthorityRepository = 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'
$script:PreparedSourceAuthorityFiles = [ordered]@{
    'docs/standards/README.md' = '8aef64a9e69848c82d0ceba43f14c2876e3816cbc4761bac26a35e6f62aaf884'
    'docs/standards/internal-source-continuation.json' = '793019c1e3d6ebee607a017b4b8ca813a84a1b8c5371302e19c8431870d02066'
    'docs/standards/managed-skill-lifecycle.md' = '4e3f8595072d663f51d18aa28f42293fda5456362b49c0ea3f0157ae3dcf56dd'
    'docs/standards/schemas/internal-source-continuation-v1.schema.json' = '559aaa9f7ec44f347ad9c431f57caaed017824bc7949a480658aa1f3af07f01c'
    'docs/standards/schemas/internal-source-review-assessment-v1.schema.json' = 'c25f810e1c6b7b8848c6deda87e8ad2c6b5df8f1073da9bfb9d078a2966fbd60'
    'docs/standards/schemas/managed-skill-lifecycle-v1.schema.json' = '9a7f4c02588d2b88194e953a41766a72a9426fa89d4c3781c5750dcc22d35863'
    'docs/standards/schemas/openai-agent-metadata.schema.json' = '23c1aaee28a54fea1946a61d6122a2097906ffa5bdd66c8014fc6b1625c9062a'
    'docs/standards/schemas/source-inventory-v2.schema.json' = '084550944b4141ab5535f58fb6e99730a5c34b56103f6b59fd5a352679caa98e'
    'docs/standards/schemas/standard-semantic-consent-evidence-v2.schema.json' = '109091979d0a47e2035d3d8b20963fcdb85680e5da737bf1f27121608115d430'
    'docs/standards/schemas/standard-validation-adapter-v1.schema.json' = '11aa88fc25716d748bd4f514f1a44f02390ad1745dd5a5c5beee07f642fd5639'
    'docs/standards/schemas/standard-validation-evidence-v1.schema.json' = 'e177a6832d055b51a440615fec65d01941b1b0c32bf468b962c8eb79750db924'
    'docs/standards/schemas/skillspector-approved-sources-v1.schema.json' = '20fa8516c9dcb7c9ae15f4682092dc583411db3149fac2641fef7b5182c3d12b'
    'docs/standards/schemas/static-native-profile-execution-v1.schema.json' = 'efca31987080d8ae213d32f51195de482802ccb3ca1b720991c75ce474dc264a'
    'docs/standards/schemas/static-parser-host-ownership-v1.schema.json' = 'f3184acc41597286be9440a41cbadb46f89a37ee84a0224c27c1adcef78e7591'
    'docs/standards/schemas/static-parser-profile-execution-v1.schema.json' = '7774f346293e6e7ff64ffffed527b7f6ef4012a1cfcb2f9ae0d4ad760c540077'
    'docs/standards/schemas/upstream-adapter-v1.schema.json' = '3cff6246463188a91cc54c6a46315a949314767a759c6214e5b28e4db95ac8d7'
    'docs/standards/schemas/validation-security-gate-v1.schema.json' = 'b924b28a791f4d6eedcc0aa1c01fb62687ec863c0c17048093bfdd99aaa55b74'
    'docs/standards/skill-repository-review-matrix.md' = 'db0f898b2e59e0600abe3ec93684e561db339c82547d9035b18285f0285672ab'
    'docs/standards/skill-repository-standard.md' = 'a831a4151f8ea31e90709487af7823256ca4b119784823216a89ee8fcc85da35'
    'docs/standards/skillspector-approved-sources.json' = 'baaaf2a66e98f2c28a48fddd04051f09cf5498ef6c7978cbf45f5d415b69a330'
    'docs/standards/standard-validation-contract-v1.json' = '2fa394ee48f940cdc2272c64199b90d95dea3665e1496df49cd0bd695cbdbe15'
    'docs/standards/static-parser-host-ownership.json' = '994acd989327d094d22ce2c68ca20eceec609f4e494f4e5d252cfcdef742de2c'
    'docs/standards/trust-anchors/human-approval-public-key.xml' = '1e46153b72d02f3ce2fb26becd449df4f1590d8e5cb441b1954006a5602bbd9b'
    'docs/standards/trust-anchors/trusted-supervisor-public-key.xml' = '4d550851f43405920156f40c9fc648d99a69dd73efc200f6968d8a837e7fbf27'
    'docs/standards/upstream-adapter.json' = 'c4f5133b24841bb9c66182dc3d5a027596f864ec28e410d47249a67b3b97ad31'
    'docs/standards/upstream-interoperability.md' = '8e48cc4831d151ffa4665433d79ad88e8871cb1d694861908dd0206406dcefe5'
    'docs/standards/validation-security-gate.json' = '1ab4c1208885a3aeb74654d8133426367134446e2b7519f06e63de3a53b16067'
    'docs/standards/validation-toolchain.json' = '001054854960563201d969a826db990f01ab93a2e87120ccc5ee42be8f8417d7'
    'scripts/Get-StandardPowerShellSyntaxProof.ps1' = '29104bd061d5e43540a0586c29830b28fd6f16367f3a7ffbf960980576d559cd'
    'scripts/Invoke-StandardAuthorityGate.ps1' = 'b4972681e79f788485e3925b737a7b0faac38a63c617450472758f2cc33798ef'
    'scripts/Invoke-StandardStaticScan.ps1' = '62686b6e8cab6bda6e6fa7164b03b76fd97aeb508c3f6fdc7643f4190ee9517f'
    'scripts/Invoke-StandardValidation.ps1' = '242b9e856d11dffffc512d03b60a7bd1f8ebad101d99cd97556488201b504350'
    'scripts/Resolve-PythonWheelClosure.py' = '4d6325bc7d425e6fe2ef474d7f78fe8966b44ec5e1acee86f2417dc740d1fcea'
    'scripts/Resolve-StandardValidationTool.ps1' = 'c0d68b227fc04e19d710a89c4559fe45e0cc979eead846006261dc2dc5bfa14f'
    'scripts/StandardSemanticBridge.psm1' = '92595bdbb98ae77bdb2cc4dd7605ecc29f54e0a6746c9ee7d7636655f65665ef'
    'scripts/Validate-UpstreamAdapter.ps1' = '3b6e6474690b1ae9f9486544b68f50ca29b96f5dbe6aa8d6c6cd8570afad500b'
    'scripts/WindowsDacl.psm1' = 'ffa1f85d94bb6bce9bf8353f8c7733bdbe59880a3d0d075191938cc28aebb5f6'
    'scripts/installer-safe-mutation.psm1' = 'dc031edcc2f48968df83cd68ad52eacb7f7b05d3ca6a0cc622658cf6151c8293'
    'scripts/platform-runtime.psd1' = '7f112390d2995a105b9e9a916876df1779485dec6df21d7516243e2dcd1c4dca'
    'scripts/platform-runtime.psm1' = 'ad051b2794ce4dc10108404201735d02f7b032ed0e633c5f22f73c884fb10370'
    'scripts/platform/Linux.psm1' = '52c261d577ee7b3946771d1112030996896fdd119e06ac3849e430a3d56fb38c'
    'scripts/platform/MacOS.psm1' = '8f25edfbee5ab36b5e1c42eb55c6dbab44db0bc29896c180612b1248920c7c47'
    'scripts/platform/OwnedProcess.cs' = '097061ad5902f896ff74b3f60b0ecaf63f3d58f357aed8fdbf80a8586564de58'
    'scripts/platform/PlatformNative.cs' = 'f9da23bf3e6e3c8960b26d534e14873f6b4fc98b3d13f5b6cdfdd5f7716a4514'
    'scripts/platform/RuntimePreparation.psm1' = 'dc254c04e7e2caf280726e66f67434776bc7df12a210a38c80596e41344fd077'
    'scripts/platform/Unix.psm1' = 'ec3b3bb0b39e1ce84d4c8f60a78c44fb40cb9d58c13ed88a6b9d9db978fcc147'
    'scripts/platform/UnixNative.cs' = '996a8e4cc1c795f4732a9d7368e597b838c801d0710e32629cafcbba89f8c004'
    'scripts/platform/UnixProcess.cs' = '125d2b3eecdad6a6c201d5f5d61a6efd0ad55ba93822c7b83a679a5397005db1'
    'scripts/platform/Windows.psm1' = '9b7442178083a9b165ed3bf53367d5c3ce1b1f09d56f0f6efe964b524e17be0b'
    'scripts/platform/WindowsInstallerMutation.cs' = 'b88b4b09c7bb5c3e71b762ddc6ebe72007ed0cca99977ab7a7272529c3ff9218'
    'scripts/platform/WindowsNative.cs' = '6eea8ca2701b6a6de88ee4a3348f053d07a0543d607832e667335c838bb7d433'
    'scripts/platform/WindowsProcess.cs' = '7b8a0cddd3b9809b861801fe1d6a618684e2ca6fa13f9334825c5c9da5b2d8d6'
    'scripts/standard_static_powershell.py' = '53d807123ef21d7f89e46947d8e7eb5b6bafe39f55fdfa0c36c99bf7c6a74dca'
}

function Get-PreparedSourceAuthorityPin {
    param([string] $AuthorityRevision = $script:PreparedSourceAuthorityCommit)
    if ($AuthorityRevision -cne $script:PreparedSourceAuthorityCommit) { throw 'Source authority revision is not the exact reviewed pin.' }
    return [pscustomobject]@{
        repository = $script:SourceAuthorityRepository
        commit = $script:PreparedSourceAuthorityCommit
        archiveUrl = "https://codeload.github.com/SyuanTsai/SyuanTsai-AI-Instructions/zip/$($script:PreparedSourceAuthorityCommit)"
        archiveSha256 = $script:PreparedSourceAuthorityArchiveSha256
        files = $script:PreparedSourceAuthorityFiles
    }
}

function Assert-AtlassianSourceAuthorityConfig {
    param([Parameter(Mandatory = $true)] $Config)

    $expectedProperties = @('schemaVersion', 'standardVersion', 'authority', 'deviations', 'centralRunner')
    $actualProperties = @($Config.PSObject.Properties | ForEach-Object { [string]$_.Name })
    if ($actualProperties.Count -ne $expectedProperties.Count -or
        @($expectedProperties | Where-Object { $actualProperties -cnotcontains $_ }).Count -gt 0 -or
        @($actualProperties | Where-Object { $expectedProperties -cnotcontains $_ }).Count -gt 0) {
        throw 'config/standard-v1.json has an invalid property set.'
    }
    if ($null -eq $Config.schemaVersion -or $Config.schemaVersion.GetType().Name -notin @('Byte', 'Int16', 'Int32', 'Int64', 'UInt16', 'UInt32', 'UInt64') -or
        $Config.schemaVersion -ne 1 -or $Config.standardVersion -isnot [string] -or $Config.standardVersion -cne 'v1') {
        throw 'config/standard-v1.json has an unsupported schema or Standard version.'
    }

    $authority = $Config.authority
    $expectedAuthorityProperties = @('repository', 'commit', 'archiveUrl', 'archiveSha256', 'files')
    $actualAuthorityProperties = @($authority.PSObject.Properties | ForEach-Object { [string]$_.Name })
    if ($actualAuthorityProperties.Count -ne $expectedAuthorityProperties.Count -or
        @($expectedAuthorityProperties | Where-Object { $actualAuthorityProperties -cnotcontains $_ }).Count -gt 0 -or
        @($actualAuthorityProperties | Where-Object { $expectedAuthorityProperties -cnotcontains $_ }).Count -gt 0) {
        throw 'config/standard-v1.json authority has an invalid property set.'
    }

    $pin = Get-PreparedSourceAuthorityPin
    foreach ($field in @('repository', 'commit', 'archiveUrl', 'archiveSha256')) {
        if ($authority.PSObject.Properties[$field].Value -isnot [string] -or [string]$authority.$field -cne [string]$pin.$field) {
            throw "config/standard-v1.json authority '$field' does not match the exact prepared source tuple."
        }
    }
    if ($authority.files -isnot [array] -or @($authority.files).Count -ne $script:PreparedSourceAuthorityFiles.Count) {
        throw 'config/standard-v1.json authority file closure must contain the exact approved records.'
    }

    $expectedPaths = @($script:PreparedSourceAuthorityFiles.Keys)
    for ($index = 0; $index -lt $expectedPaths.Count; $index++) {
        $file = @($authority.files)[$index]
        $fileProperties = @($file.PSObject.Properties | ForEach-Object { [string]$_.Name })
        if ($fileProperties.Count -ne 2 -or $fileProperties -cnotcontains 'path' -or $fileProperties -cnotcontains 'sha256' -or
            $file.path -isnot [string] -or $file.sha256 -isnot [string] -or
            [string]$file.path -cne [string]$expectedPaths[$index] -or
            [string]$file.sha256 -cne [string]$script:PreparedSourceAuthorityFiles[$expectedPaths[$index]]) {
            throw "config/standard-v1.json authority file identity mismatch at index $index."
        }
    }
    return $pin
}

function Assert-AtlassianSourceRunRequest {
    [CmdletBinding()]
    param(
        [string] $ExecutionMode = 'Run',
        [switch] $PrepareSourceTools,
        [switch] $SourceValidation,
        [string] $SourceToolsPath,
        [int] $AdapterVersion = 1,
        [string] $AuthorityCommit,
        [string] $RunId,
        [switch] $CompleteLifecycle,
        [switch] $DevelopmentHarness
    )

    $setup = [bool]$PrepareSourceTools
    $source = [bool]$SourceValidation
    $hasPath = $PSBoundParameters.ContainsKey('SourceToolsPath')
    if ($setup -and $source) { throw 'PrepareSourceTools and SourceValidation are separate setup and execution requests.' }
    if (($setup -or $source) -and ($ExecutionMode -cne 'Run' -or [string]::IsNullOrWhiteSpace($SourceToolsPath))) {
        throw 'Explicit source setup or validation requires Run and SourceToolsPath.'
    }
    if (-not ($setup -or $source) -and $hasPath) { throw 'Ordinary Core does not accept SourceToolsPath.' }
    if (-not ($setup -or $source)) { return 'Core' }
    if ($AdapterVersion -ne 2 -or $CompleteLifecycle -or $DevelopmentHarness) {
        throw 'SourceValidation requires Core adapter v2 and cannot be combined with a legacy lifecycle or development harness.'
    }
    if ($AuthorityCommit -cne $script:PreparedSourceAuthorityCommit) {
        throw 'Source setup and validation require the exact approved 3c55daa authority tuple.'
    }
    if ($source -and $RunId -cnotmatch '^[0-9a-f]{32}$') {
        throw 'SourceValidation requires the fresh setup RunId as exactly 32 lowercase hexadecimal characters.'
    }
    if ($setup -and -not [string]::IsNullOrWhiteSpace($RunId)) {
        throw 'PrepareSourceTools creates the fresh setup RunId and does not accept a caller-provided identity.'
    }
    if ($setup) { return 'PrepareSourceTools' }
    return 'SourceValidation'
}

function New-AtlassianSourceFrozenFileInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $RuntimeFiles,
        [Parameter(Mandatory = $true)][AllowNull()][object] $SourceFiles,
        [Parameter(Mandatory = $true)][AllowNull()][object] $PesterFiles,
        [Parameter(Mandatory = $true)][AllowNull()][object] $ReceiptFiles
    )

    $comparison = if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
    $byPath = [Collections.Generic.Dictionary[string, string]]::new($comparison)
    foreach ($group in @($RuntimeFiles, $SourceFiles, $PesterFiles, $ReceiptFiles)) {
        if ($null -eq $group) { continue }
        if ($group -is [string]) { $groupItems = @($group) }
        elseif ($group -is [Collections.IEnumerable]) { $groupItems = @($group) }
        else { throw 'Frozen source file groups must contain string paths or string arrays.' }
        foreach ($pathValue in $groupItems) {
            if ($pathValue -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$pathValue)) {
                throw 'Frozen source file inventory contains a non-string or empty path.'
            }
            $fullPath = [IO.Path]::GetFullPath([string]$pathValue)
            $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
            if ($item.PSIsContainer -or $item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Frozen source input must be a regular file: $fullPath"
            }
            $sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
            if (-not $byPath.TryAdd($fullPath, $sha256) -and $byPath[$fullPath] -cne $sha256) {
                throw "Frozen source file changed while its input groups were composed: $fullPath"
            }
        }
    }
    if ($byPath.Count -eq 0) { throw 'Frozen source file inventory must not be empty.' }
    $sortedPaths = [string[]]@($byPath.Keys)
    [Array]::Sort($sortedPaths, [StringComparer]::Ordinal)
    $records = @($sortedPaths | ForEach-Object { [pscustomobject][ordered]@{ path = $_; sha256 = $byPath[$_] } })
    return [pscustomobject]@{ files = [object[]]$records; count = $records.Count }
}

function Assert-AtlassianSourceProtectedDispatchFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $ProtectedBaseRoot,
        [Parameter(Mandatory = $true)][string] $CandidateRoot,
        [Parameter(Mandatory = $true)][object[]] $ManifestEntries
    )

    $protectedRoot = [IO.Path]::GetFullPath($ProtectedBaseRoot)
    $candidateRootFull = [IO.Path]::GetFullPath($CandidateRoot)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $protectedPaths = @(
        'scripts/Invoke-CorePester.ps1',
        'scripts/CorePesterIntegrity.psm1',
        'scripts/StandardSourceDriver.psm1',
        'scripts/AtlassianSourceCommon.psm1',
        'scripts/SkillSpectorExceptionCandidates.psm1',
        'scripts/Test-Repository.ps1'
    )
    $entries = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($entry in $ManifestEntries) {
        $relative = [string]$entry.path
        $segments = $relative.Split('/')
        if ([string]::IsNullOrWhiteSpace($relative) -or $relative.Contains('\') -or [IO.Path]::IsPathRooted($relative) -or
            $segments -contains '' -or $segments -contains '.' -or $segments -contains '..' -or
            [string]$entry.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
            [string]$entry.mode -cnotin @('100644', '100755') -or $entries.ContainsKey($relative)) {
            throw 'Candidate Git entry mode manifest contains an invalid or duplicate protected dispatch entry.'
        }
        $entries.Add($relative, $entry)
    }

    $result = [Collections.Generic.List[object]]::new()
    foreach ($relative in $protectedPaths) {
        if (-not $entries.ContainsKey($relative)) { throw "Candidate revision is missing the protected dispatch file: $relative" }
        $basePath = Join-Path $protectedRoot ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        $candidatePath = Join-Path $candidateRootFull ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        foreach ($path in @($basePath, $candidatePath)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Protected dispatch file is missing: $path" }
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Protected dispatch file is a reparse point: $path" }
        }
        $baseHash = (Get-FileHash -LiteralPath $basePath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        $candidateHash = (Get-FileHash -LiteralPath $candidatePath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if ($baseHash -cne $candidateHash -or [string]$entries[$relative].sha256 -cne $baseHash -or [string]$entries[$relative].mode -cne '100644') {
            throw "Candidate protected dispatch file differs from the trusted driver bytes: $relative"
        }
        $result.Add([pscustomobject]@{ path = $relative; sha256 = $baseHash; protectedPath = [IO.Path]::GetFullPath($basePath) })
    }
    return $result.ToArray()
}

function Assert-AtlassianSourceProtectedRuntimeCopies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $ProtectedBaseRoot,
        [Parameter(Mandatory = $true)][string] $CandidateRoot,
        [Parameter(Mandatory = $true)][string] $OwnedRoot,
        [Parameter(Mandatory = $true)][object[]] $ManifestEntries,
        [Parameter(Mandatory = $true)][object[]] $FrozenFiles
    )

    $dispatchFiles = @(Assert-AtlassianSourceProtectedDispatchFiles -ProtectedBaseRoot $ProtectedBaseRoot `
        -CandidateRoot $CandidateRoot -ManifestEntries $ManifestEntries)
    $runtimeRoot = [IO.Path]::GetFullPath((Join-Path $OwnedRoot 'runtime/ProtectedSourceChecks'))
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $frozen = [Collections.Generic.Dictionary[string, string]]::new($(if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }))
    foreach ($record in $FrozenFiles) {
        $path = [IO.Path]::GetFullPath([string]$record.path)
        if ([string]$record.sha256 -cnotmatch '^[0-9a-f]{64}$' -or -not $frozen.TryAdd($path, [string]$record.sha256)) {
            throw 'Prepared frozen file inventory contains an invalid or duplicate protected-copy record.'
        }
    }
    foreach ($binding in $dispatchFiles) {
        $relative = ([string]$binding.path).Replace('/', [IO.Path]::DirectorySeparatorChar)
        $copyPath = [IO.Path]::GetFullPath((Join-Path $runtimeRoot $relative))
        if (-not $copyPath.StartsWith($runtimeRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar, $comparison) -or
            -not $frozen.ContainsKey($copyPath)) {
            throw "Run-owned protected dispatch copy is missing from the frozen closure: $($binding.path)"
        }
        foreach ($path in @([string]$binding.protectedPath, $copyPath)) {
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if ($item.PSIsContainer -or $item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Run-owned protected dispatch copy is not a regular file: $path" }
            if ((Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() -cne [string]$binding.sha256) {
                throw "Run-owned protected dispatch copy differs from the trusted protected-base bytes: $($binding.path)"
            }
        }
        if ($frozen[$copyPath] -cne [string]$binding.sha256) { throw "Run-owned protected dispatch copy has a self-consistent but untrusted frozen hash: $($binding.path)" }
    }
    return $dispatchFiles
}

function Assert-AtlassianSourceSha256 {
    param([Parameter(Mandatory = $true)][string] $Value, [Parameter(Mandatory = $true)][string] $Context)
    if ($Value -cnotmatch '^[0-9a-f]{64}$') { throw "$Context must be a lowercase SHA-256 value." }
}

function Assert-AtlassianSourceNoDuplicateJsonProperties {
    param([Parameter(Mandatory = $true)][System.Text.Json.JsonElement] $Element, [Parameter(Mandatory = $true)][string] $Context)
    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $names.Add($property.Name)) { throw "$Context contains duplicate JSON property '$($property.Name)'." }
            Assert-AtlassianSourceNoDuplicateJsonProperties -Element $property.Value -Context "$Context.$($property.Name)"
        }
    }
    elseif ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
        foreach ($item in $Element.EnumerateArray()) { Assert-AtlassianSourceNoDuplicateJsonProperties -Element $item -Context $Context }
    }
}

function Assert-AtlassianSourceRuntimeInventory {
    param(
        [Parameter(Mandatory = $true)] $PesterRuntime,
        [Parameter(Mandatory = $true)][string] $OwnedRoot,
        [Parameter(Mandatory = $true)] $FrozenFiles
    )

    $runtimeRoot = [IO.Path]::GetFullPath([string]$PesterRuntime.runtimeRoot)
    $expectedRoot = [IO.Path]::GetFullPath((Join-Path $OwnedRoot 'runtime'))
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not $runtimeRoot.Equals($expectedRoot, $comparison) -or -not (Test-Path -LiteralPath $runtimeRoot -PathType Container)) {
        throw 'Prepared PowerShell runtime root does not match the exact run-owned copy.'
    }
    $runtimeExecutable = [IO.Path]::GetFullPath([string]$PesterRuntime.runtimeExecutablePath)
    $runtimeExecutableName = if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' }
    $expectedExecutable = [IO.Path]::GetFullPath((Join-Path $runtimeRoot $runtimeExecutableName))
    if (-not $runtimeExecutable.Equals($expectedExecutable, $comparison) -or
        -not (Test-Path -LiteralPath $runtimeExecutable -PathType Leaf) -or
        [string]$PesterRuntime.runtimeExecutableSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        (Get-FileHash -LiteralPath $runtimeExecutable -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$PesterRuntime.runtimeExecutableSha256) {
        throw 'Prepared PowerShell executable path or hash differs from the run-owned runtime.'
    }

    $inventoryPath = [IO.Path]::GetFullPath([string]$PesterRuntime.runtimeInventoryPath)
    $expectedInventoryPath = [IO.Path]::GetFullPath((Join-Path $OwnedRoot 'powershell-runtime-inventory.json'))
    if (-not $inventoryPath.Equals($expectedInventoryPath, $comparison) -or
        [string]$PesterRuntime.runtimeInventorySha256 -cnotmatch '^[0-9a-f]{64}$' -or
        -not (Test-Path -LiteralPath $inventoryPath -PathType Leaf) -or
        (Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$PesterRuntime.runtimeInventorySha256 -or
        -not $FrozenFiles.ContainsKey($inventoryPath) -or $FrozenFiles[$inventoryPath] -cne [string]$PesterRuntime.runtimeInventorySha256) {
        throw 'Prepared PowerShell runtime inventory is missing, changed or not frozen.'
    }
    $runtimeFields = @('schemaVersion', 'root', 'executablePath', 'executableSha256', 'files')
    $document = $null
    try {
        $runtimeJson = [IO.File]::ReadAllText($inventoryPath, [Text.UTF8Encoding]::new($false, $true))
        $document = [System.Text.Json.JsonDocument]::Parse($runtimeJson)
        $propertyNames = @($document.RootElement.EnumerateObject() | ForEach-Object { [string]$_.Name })
        if ($document.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object -or
            $propertyNames.Count -ne $runtimeFields.Count -or
            @($runtimeFields | Where-Object { $propertyNames -cnotcontains $_ }).Count -gt 0) {
            throw 'Prepared PowerShell runtime inventory has an invalid property set.'
        }
        Assert-AtlassianSourceNoDuplicateJsonProperties -Element $document.RootElement -Context 'Prepared PowerShell runtime inventory'
        $runtimeInventory = ConvertFrom-Json -InputObject $runtimeJson -Depth 20 -ErrorAction Stop
    }
    finally { if ($null -ne $document) { $document.Dispose() } }
    if ([int]$runtimeInventory.schemaVersion -ne 1 -or
        -not [IO.Path]::GetFullPath([string]$runtimeInventory.root).Equals($runtimeRoot, $comparison) -or
        -not [IO.Path]::GetFullPath([string]$runtimeInventory.executablePath).Equals($runtimeExecutable, $comparison) -or
        [string]$runtimeInventory.executableSha256 -cne [string]$PesterRuntime.runtimeExecutableSha256 -or
        $runtimeInventory.files -isnot [array] -or $runtimeInventory.files.Count -eq 0) {
        throw 'Prepared PowerShell runtime inventory does not bind the exact run-owned runtime.'
    }

    $expectedFiles = [Collections.Generic.Dictionary[string, string]]::new($(if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }))
    foreach ($file in @($runtimeInventory.files)) {
        $properties = @($file.PSObject.Properties | ForEach-Object { [string]$_.Name })
        if ($properties.Count -ne 2 -or $properties -cnotcontains 'path' -or $properties -cnotcontains 'sha256' -or
            [string]$file.path -cnotmatch '^(?:[A-Za-z]:\\|/)' -or [string]$file.sha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw 'Prepared PowerShell runtime file inventory contains a malformed entry.'
        }
        $path = [IO.Path]::GetFullPath([string]$file.path)
        $prefix = $runtimeRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if (-not $path.StartsWith($prefix, $comparison) -or
            -not $expectedFiles.TryAdd($path, [string]$file.sha256)) {
            throw 'Prepared PowerShell runtime inventory contains an unsafe or duplicate path.'
        }
    }
    if (-not $expectedFiles.ContainsKey($runtimeExecutable) -or $expectedFiles[$runtimeExecutable] -cne [string]$PesterRuntime.runtimeExecutableSha256) {
        throw 'Prepared PowerShell runtime inventory does not include the exact child executable hash.'
    }
    foreach ($path in $expectedFiles.Keys) {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or $item.Attributes -band [IO.FileAttributes]::ReparsePoint -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expectedFiles[$path] -or
            -not $FrozenFiles.ContainsKey($path) -or $FrozenFiles[$path] -cne $expectedFiles[$path]) {
            throw "Prepared PowerShell runtime file is missing, changed, unsafe or not frozen: $path"
        }
    }
    $actualFiles = @()
    foreach ($item in @(Get-ChildItem -LiteralPath $runtimeRoot -Force -Recurse -ErrorAction Stop)) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Prepared PowerShell runtime contains a reparse point: $($item.FullName)" }
        if (-not $item.PSIsContainer) { $actualFiles += [IO.Path]::GetFullPath($item.FullName) }
    }
    if ($actualFiles.Count -ne $expectedFiles.Count -or
        @($actualFiles | Where-Object { -not $expectedFiles.ContainsKey($_) }).Count -gt 0) {
        throw 'Prepared PowerShell runtime has an incomplete or extra file outside its frozen inventory.'
    }
    return $runtimeInventory
}

function Assert-AtlassianSourcePreparedBindings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $Prepared,
        [Parameter(Mandatory = $true)][string] $PreparedPath,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{40}$')][string] $CandidateRevision,
        [Parameter(Mandatory = $true)][string] $PowerShellPath,
        [Parameter(Mandatory = $true)][string] $SourceRepository
    )

    $topFields = @('schemaVersion', 'preparation', 'runId', 'sourceRevision', 'authorityRevision', 'ownedRoot', 'candidateArchivePath', 'candidateArchiveSha256', 'sourceValidation', 'pesterRuntime')
    $topProperties = @($Prepared.PSObject.Properties | ForEach-Object { [string]$_.Name })
    if ($topProperties.Count -ne $topFields.Count -or
        @($topFields | Where-Object { $topProperties -cnotcontains $_ }).Count -gt 0 -or
        @($topProperties | Where-Object { $topFields -cnotcontains $_ }).Count -gt 0 -or
        [int]$Prepared.schemaVersion -ne 1 -or $Prepared.preparation -cne 'atlassian-source-tools' -or
        [string]$Prepared.runId -cnotmatch '^[0-9a-f]{32}$' -or [string]$Prepared.sourceRevision -cne $CandidateRevision -or
        [string]$Prepared.authorityRevision -cne $script:PreparedSourceAuthorityCommit -or
        [string]$Prepared.candidateArchivePath -cnotmatch '^(?:[A-Za-z]:\\|/)' -or
        [string]$Prepared.candidateArchiveSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Prepared source tools do not bind the exact source, authority and setup run.'
    }
    $preparedFullPath = [IO.Path]::GetFullPath($PreparedPath)
    $expectedOwnedRoot = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $preparedFullPath) "source-tools-$($Prepared.runId)"))
    if (-not [IO.Path]::GetFullPath([string]$Prepared.ownedRoot).Equals($expectedOwnedRoot, $(if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }))) {
        throw 'Prepared source tools owned root differs from its exact run identity.'
    }
    $archivePath = [IO.Path]::GetFullPath([string]$Prepared.candidateArchivePath)
    if (-not $archivePath.StartsWith([IO.Path]::GetFullPath([string]$Prepared.ownedRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar,
            $(if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal })) -or
        -not (Test-Path -LiteralPath $archivePath -PathType Leaf) -or
        (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$Prepared.candidateArchiveSha256) {
        throw 'Prepared candidate archive is missing, changed, or outside the exact source setup run.'
    }

    $sourceFields = @('packageAdapter', 'skillValidator', 'skillTools', 'staticAnalyzer', 'frozenFiles', 'toolReceipts')
    $sourceProperties = @($Prepared.sourceValidation.PSObject.Properties | ForEach-Object { [string]$_.Name })
    if ($sourceProperties.Count -ne $sourceFields.Count -or
        @($sourceFields | Where-Object { $sourceProperties -cnotcontains $_ }).Count -gt 0 -or
        @($sourceProperties | Where-Object { $sourceFields -cnotcontains $_ }).Count -gt 0 -or
        $Prepared.sourceValidation.toolReceipts -isnot [array] -or @($Prepared.sourceValidation.toolReceipts).Count -ne 3 -or
        $Prepared.sourceValidation.frozenFiles -isnot [array] -or @($Prepared.sourceValidation.frozenFiles).Count -eq 0) {
        throw 'Prepared source validation payload is partial or has an unexpected property set.'
    }
    $frozen = [Collections.Generic.Dictionary[string, string]]::new($(if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }))
    foreach ($file in @($Prepared.sourceValidation.frozenFiles)) {
        $properties = @($file.PSObject.Properties | ForEach-Object { [string]$_.Name })
        if ($properties.Count -ne 2 -or $properties -cnotcontains 'path' -or $properties -cnotcontains 'sha256' -or
            [string]$file.path -cnotmatch '^(?:[A-Za-z]:\\|/)' -or [string]$file.sha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw 'Prepared source frozen file entry is malformed.'
        }
        $path = [IO.Path]::GetFullPath([string]$file.path)
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or $item.Attributes -band [IO.FileAttributes]::ReparsePoint -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$file.sha256 -or
            -not $frozen.TryAdd($path, [string]$file.sha256)) {
            throw "Prepared source frozen file is missing, unsafe, changed or duplicated: $path"
        }
    }
    $manifestPath = [IO.Path]::GetFullPath((Join-Path ([string]$Prepared.ownedRoot) 'candidate-git-entry-modes.json'))
    $identityPath = [IO.Path]::GetFullPath((Join-Path ([string]$Prepared.ownedRoot) 'source-run-identity.json'))
    $manifestHash = if ($frozen.ContainsKey($manifestPath)) { [string]$frozen[$manifestPath] } else { '' }
    if (-not $frozen.ContainsKey($identityPath) -or [string]::IsNullOrWhiteSpace($manifestHash)) {
        throw 'Prepared source run identity or candidate manifest is missing from the frozen closure.'
    }
    $identity = Get-Content -LiteralPath $identityPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -Depth 30 -ErrorAction Stop
    if ([int]$identity.schemaVersion -ne 1 -or [string]$identity.runId -cne [string]$Prepared.runId -or
        [string]$identity.sourceRevision -cne [string]$Prepared.sourceRevision -or [string]$identity.authorityRevision -cne [string]$Prepared.authorityRevision -or
        -not [IO.Path]::GetFullPath([string]$identity.candidateManifestPath).Equals($manifestPath, $(if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal })) -or
        [string]$identity.candidateManifestSha256 -cne $manifestHash -or
        -not [IO.Path]::GetFullPath([string]$identity.candidateArchivePath).Equals($archivePath, $(if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal })) -or
        [string]$identity.candidateArchiveSha256 -cne [string]$Prepared.candidateArchiveSha256) {
        throw 'Prepared source identity receipt does not bind the exact source revision, authority, archive, manifest and RunId.'
    }
    $receiptNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($receiptBinding in @($Prepared.sourceValidation.toolReceipts)) {
        $properties = @($receiptBinding.PSObject.Properties | ForEach-Object { [string]$_.Name })
        if ($properties.Count -ne 2 -or $properties -cnotcontains 'path' -or $properties -cnotcontains 'sha256' -or
            -not $frozen.ContainsKey([IO.Path]::GetFullPath([string]$receiptBinding.path)) -or
            $frozen[[IO.Path]::GetFullPath([string]$receiptBinding.path)] -cne [string]$receiptBinding.sha256) {
            throw 'Prepared source tool receipt is not an exact frozen file.'
        }
        $receipt = Get-Content -LiteralPath ([string]$receiptBinding.path) -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -Depth 50 -ErrorAction Stop
        $name = [string]$receipt.toolName
        if ($name -cnotin @('skill-validator', 'skill-tools', 'skillspector') -or -not $receiptNames.Add($name) -or
            [string]$receipt.resolutionRunId -cne [string]$Prepared.runId -or $receipt.frozenForRun -isnot [bool] -or -not $receipt.frozenForRun) {
            throw 'Prepared source tool receipt belongs to another run or tool.'
        }
        foreach ($pair in @(@('executablePath', 'executableSha256'), @('entryPointPath', 'entryPointSha256'), @('nodePath', 'nodeSha256'), @('goRuntimePath', 'goRuntimeSha256'), @('resolverHelperPath', 'resolverHelperSha256'))) {
            $pathProperty = $receipt.PSObject.Properties[[string]$pair[0]]
            if ($null -eq $pathProperty -or [string]::IsNullOrWhiteSpace([string]$pathProperty.Value)) { continue }
            $hashProperty = $receipt.PSObject.Properties[[string]$pair[1]]
            $path = [IO.Path]::GetFullPath([string]$pathProperty.Value)
            if ($null -eq $hashProperty -or [string]$hashProperty.Value -cnotmatch '^[0-9a-f]{64}$' -or
                -not $frozen.ContainsKey($path) -or $frozen[$path] -cne [string]$hashProperty.Value) {
                throw "Prepared source receipt path/hash pair is missing from the frozen closure: $($pair[0])"
            }
        }
        foreach ($pair in @(@('shimPath', 'shimSha256'), @('payloadPath', 'payloadSha256'), @('runtimePath', 'runtimeSha256'))) {
            $pathProperty = $receipt.launcher.PSObject.Properties[[string]$pair[0]]
            if ($null -eq $pathProperty -or [string]::IsNullOrWhiteSpace([string]$pathProperty.Value)) { continue }
            $hashProperty = $receipt.launcher.PSObject.Properties[[string]$pair[1]]
            $path = [IO.Path]::GetFullPath([string]$pathProperty.Value)
            if ($null -eq $hashProperty -or [string]$hashProperty.Value -cnotmatch '^[0-9a-f]{64}$' -or
                -not $frozen.ContainsKey($path) -or $frozen[$path] -cne [string]$hashProperty.Value) {
                throw "Prepared source launcher path/hash pair is missing from the frozen closure: $($pair[0])"
            }
        }
        $installRoot = [IO.Path]::GetFullPath([string]$receipt.installRoot)
        if (-not (Test-Path -LiteralPath $installRoot -PathType Container)) { throw 'Prepared source receipt install root is missing.' }
        $installFiles = @(Get-ChildItem -LiteralPath $installRoot -Force -Recurse -ErrorAction Stop)
        foreach ($installFile in $installFiles) {
            if ($installFile.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Prepared source tool closure contains a reparse point: $($installFile.FullName)" }
            if ($installFile.PSIsContainer) { continue }
            $path = [IO.Path]::GetFullPath($installFile.FullName)
            if (-not $frozen.ContainsKey($path) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $frozen[$path]) {
                throw "Prepared source tool closure file is missing or changed in the frozen closure: $path"
            }
        }
    }
    foreach ($name in @('skill-validator', 'skill-tools', 'skillspector')) {
        if (-not $receiptNames.Contains($name)) { throw "Prepared source tool receipt is missing: $name" }
    }

    $pesterFields = @('moduleManifestPath', 'closureLockPath', 'closureLockSha256', 'setupReceiptPath', 'setupReceiptSha256',
        'runtimeRoot', 'runtimeExecutablePath', 'runtimeExecutableSha256', 'runtimeInventoryPath', 'runtimeInventorySha256', 'sourceTrustedToolRoot')
    $pesterProperties = @($Prepared.pesterRuntime.PSObject.Properties | ForEach-Object { [string]$_.Name })
    if ($pesterProperties.Count -ne $pesterFields.Count -or
        @($pesterFields | Where-Object { $pesterProperties -cnotcontains $_ }).Count -gt 0 -or
        @($pesterProperties | Where-Object { $pesterFields -cnotcontains $_ }).Count -gt 0) {
        throw 'Prepared Pester runtime binding has an invalid property set.'
    }
    foreach ($binding in @(
        [pscustomobject]@{ path = [string]$Prepared.pesterRuntime.closureLockPath; sha = [string]$Prepared.pesterRuntime.closureLockSha256; name = 'closure lock' },
        [pscustomobject]@{ path = [string]$Prepared.pesterRuntime.setupReceiptPath; sha = [string]$Prepared.pesterRuntime.setupReceiptSha256; name = 'setup receipt' }
    )) {
        $full = [IO.Path]::GetFullPath($binding.path)
        if (-not $frozen.ContainsKey($full) -or $frozen[$full] -cne $binding.sha -or
            (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant() -cne $binding.sha) {
            throw "Prepared Pester $($binding.name) is missing from the frozen closure or changed."
        }
    }
    $manifest = [IO.Path]::GetFullPath([string]$Prepared.pesterRuntime.moduleManifestPath)
    if (-not $frozen.ContainsKey($manifest)) { throw 'Prepared Pester manifest is missing from the frozen closure.' }
    $runtimeInventory = Assert-AtlassianSourceRuntimeInventory -PesterRuntime $Prepared.pesterRuntime -OwnedRoot ([string]$Prepared.ownedRoot) -FrozenFiles $frozen
    $receipt = Get-Content -LiteralPath ([string]$Prepared.pesterRuntime.setupReceiptPath) -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -Depth 50 -ErrorAction Stop
    if ([string]$receipt.runId -cne [string]$Prepared.runId -or [string]$receipt.lockSha256 -cne [string]$Prepared.pesterRuntime.closureLockSha256 -or
        [string]$receipt.terminalStatus -cne 'verified' -or
        -not [IO.Path]::GetFullPath([string]$receipt.runtimeExecutable).Equals([IO.Path]::GetFullPath($PowerShellPath), $(if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal })) -or
        -not [IO.Path]::GetFullPath([string]$receipt.runtimeModuleRoot).Equals([IO.Path]::GetFullPath((Split-Path -Parent $manifest)), $(if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal })) -or
        [string]$runtimeInventory.executableSha256 -cne [string]$Prepared.pesterRuntime.runtimeExecutableSha256) {
        throw 'Prepared Pester setup receipt does not bind the source run, lock and exact runtime.'
    }
    $dispatchRoot = [IO.Path]::GetFullPath([string]$Prepared.ownedRoot)
    $wrapperPath = [IO.Path]::GetFullPath((Join-Path $dispatchRoot 'Invoke-AtlassianValidationChild.ps1'))
    $toolchainPath = [IO.Path]::GetFullPath((Join-Path $dispatchRoot 'toolchain.json'))
    $manifestPath = [IO.Path]::GetFullPath((Join-Path $dispatchRoot 'candidate-git-entry-modes.json'))
    foreach ($path in @($wrapperPath, $toolchainPath, $manifestPath, $archivePath)) {
        if (-not $frozen.ContainsKey($path)) { throw "Prepared source dispatch input is not frozen: $path" }
    }
    $commonArguments = @(
        '-NoProfile', '-NonInteractive', '-File', $wrapperPath,
        '-ToolchainPath', $toolchainPath, '-ToolchainSha256', [string]$frozen[$toolchainPath],
        '-SourceRepository', $SourceRepository, '-SourceRevision', $CandidateRevision,
        '-ArchiveSha256', [string]$Prepared.candidateArchiveSha256,
        '-CoreSourceValidation'
    )
    $expectedModes = [ordered]@{
        packageAdapter = 'package-adapter'
        skillValidator = 'skill-validator'
        skillTools = 'skill-tools'
        staticAnalyzer = 'static'
    }
    foreach ($slot in @('packageAdapter', 'skillValidator', 'skillTools', 'staticAnalyzer')) {
        $dispatch = $Prepared.sourceValidation.$slot
        $properties = @($dispatch.PSObject.Properties | ForEach-Object { [string]$_.Name })
        if ($properties.Count -ne 2 -or $properties -cnotcontains 'command' -or $properties -cnotcontains 'arguments' -or
            [string]$dispatch.command -cne [IO.Path]::GetFullPath($PowerShellPath) -or $dispatch.arguments -isnot [array] -or
            @($dispatch.arguments).Count -ne ($commonArguments.Count + 2)) { throw "Prepared source dispatch '$slot' is incomplete or changed." }
        $expectedArguments = @($commonArguments + @('-Mode', [string]$expectedModes[$slot]))
        for ($index = 0; $index -lt $expectedArguments.Count; $index++) {
            if ([string]$dispatch.arguments[$index] -cne [string]$expectedArguments[$index]) {
                throw "Prepared source dispatch '$slot' does not select the exact protected wrapper, source inputs, and mode."
            }
        }
    }
    return $true
}

function Assert-AtlassianSourceAuthorityToolchain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $Toolchain,
        [Parameter(Mandatory = $true)][string] $AuthorityRoot,
        [Parameter(Mandatory = $true)] $AuthorityPin
    )

    $root = [IO.Path]::GetFullPath($AuthorityRoot)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    foreach ($binding in @(
        [pscustomobject]@{ pathProperty = 'centralRunnerPath'; hashProperty = 'centralRunnerSha256'; relative = 'scripts/Invoke-StandardValidation.ps1' },
        [pscustomobject]@{ pathProperty = 'upstreamAdapterValidatorPath'; hashProperty = 'upstreamAdapterValidatorSha256'; relative = 'scripts/Validate-UpstreamAdapter.ps1' },
        [pscustomobject]@{ pathProperty = 'upstreamPolicyPath'; hashProperty = 'upstreamPolicySha256'; relative = 'docs/standards/upstream-adapter.json' },
        [pscustomobject]@{ pathProperty = 'staticWrapperPath'; hashProperty = 'staticWrapperSha256'; relative = 'scripts/Invoke-StandardStaticScan.ps1' }
    )) {
        $expectedHash = [string]$AuthorityPin.files[[string]$binding.relative]
        $expectedPath = [IO.Path]::GetFullPath((Join-Path $root ([string]$binding.relative -replace '/', [IO.Path]::DirectorySeparatorChar)))
        $pathValue = $Toolchain.PSObject.Properties[[string]$binding.pathProperty]
        $hashValue = $Toolchain.PSObject.Properties[[string]$binding.hashProperty]
        if ([string]::IsNullOrWhiteSpace($expectedHash) -or $null -eq $pathValue -or $null -eq $hashValue -or
            -not [IO.Path]::GetFullPath([string]$pathValue.Value).Equals($expectedPath, $comparison) -or
            [string]$hashValue.Value -cne $expectedHash -or
            -not (Test-Path -LiteralPath $expectedPath -PathType Leaf) -or
            (Get-FileHash -LiteralPath $expectedPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() -cne $expectedHash) {
            throw "Prepared Standard Core helper does not match the actual exact authority checkout: $($binding.relative)"
        }
    }
    return $true
}

function Assert-AtlassianSourceReportBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $Report,
        [Parameter(Mandatory = $true)] $Prepared,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{40}$')][string] $CandidateRevision,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{40}$')][string] $BaseRevision,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{40}$')][string] $AuthorityRevision,
        [Parameter(Mandatory = $true)][string] $EventName,
        [Parameter(Mandatory = $true)][string] $ArtifactsRoot,
        [Parameter(Mandatory = $true)][string] $OutputPath,
        [Parameter(Mandatory = $true)][int] $ProcessExitCode,
        [Parameter(Mandatory = $true)][bool] $CleanupSucceeded,
        [bool] $CancellationRequested = $false
    )

    if ($CancellationRequested -or -not $CleanupSucceeded -or $ProcessExitCode -ne 0) {
        throw 'Source report cannot pass after cancellation, cleanup failure, or a non-zero central exit.'
    }
    if ([int]$Report.schemaVersion -ne 2 -or [string]$Report.evidence -cne 'standard-core-validation-evidence-v2' -or
        [string]$Report.state -cne 'PASS' -or [int]$Report.exitCode -ne 0 -or $Report.releaseEligible -isnot [bool] -or $Report.releaseEligible -or
        [string]$Report.contentMode -cne 'immutable-source' -or [string]$Report.runId -cne [string]$Prepared.runId -or
        [string]$Report.candidate.contentMode -cne 'immutable-source' -or [string]$Report.candidate.sourceRevision -cne $CandidateRevision -or
        [string]$Report.candidate.baseRevision -cne $BaseRevision -or [string]$Report.candidate.eventName -cne $EventName -or
        [string]$Report.authority.contentMode -cne 'source' -or [string]$Report.authority.revision -cne $AuthorityRevision -or
        [string]$Report.artifacts.root -cne [IO.Path]::GetFullPath($ArtifactsRoot) -or
        [string]$Report.artifacts.outputPath -cne [IO.Path]::GetFullPath($OutputPath) -or
        [string]$Report.artifacts.runId -cne [string]$Prepared.runId) {
        throw 'Source report has a partial, cross-run, wrong candidate/base/authority/event, or failing identity.'
    }
    $source = $Report.PSObject.Properties['sourceValidation']
    if ($null -eq $source -or $null -eq $source.Value -or [string]$source.Value.status -cne 'passed' -or
        [string]$source.Value.runId -cne [string]$Prepared.runId -or
        [string]$source.Value.sourceRevision -cne $CandidateRevision -or [string]$source.Value.authorityRevision -cne $AuthorityRevision) {
        throw 'Core-only or partial report cannot satisfy SourceValidation.'
    }
    foreach ($field in @('toolReceipts', 'frozenFiles')) {
        if ((ConvertTo-Json -InputObject @($source.Value.$field) -Depth 50 -Compress) -cne
            (ConvertTo-Json -InputObject @($Prepared.sourceValidation.$field) -Depth 50 -Compress)) {
            throw "Source report $field differ from the prepared run identity."
        }
    }
    if ($Report.checks -isnot [array] -or @($Report.checks).Count -ne 2 -or
        [string]$Report.checks[0].kind -cne 'general' -or [string]$Report.checks[1].kind -cne 'pester' -or
        @($Report.checks | Where-Object { [string]$_.status -cne 'passed' -or [int]$_.exitCode -ne 0 -or $_.cleanedUp -isnot [bool] -or -not $_.cleanedUp }).Count -ne 0) {
        throw 'Source report must contain exactly two clean passing Core checks.'
    }
    $caseBinding = $source.Value.pesterCaseInventory
    if ($null -eq $caseBinding -or [string]$caseBinding.path -notmatch 'standard-core.*case|pester.*case' -or
        [string]$caseBinding.sha256 -cnotmatch '^[0-9a-f]{64}$' -or -not (Test-Path -LiteralPath ([string]$caseBinding.path) -PathType Leaf) -or
        (Get-FileHash -LiteralPath ([string]$caseBinding.path) -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$caseBinding.sha256) {
        throw 'Source report Pester case sidecar is missing or changed.'
    }

    function Assert-AtlassianSourceReportEvidencePath {
        param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $RunRoot,
            [Parameter(Mandatory)][string] $Context)
        $full = [IO.Path]::GetFullPath($Path)
        $root = [IO.Path]::GetFullPath($RunRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        $prefix = $root + [IO.Path]::DirectorySeparatorChar
        if (-not $full.StartsWith($prefix, $comparison) -or -not (Test-Path -LiteralPath $full -PathType Leaf)) {
            throw "$Context is missing or outside the Core run root."
        }
        $cursor = $full
        while (-not $cursor.Equals($root, $comparison)) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "$Context contains a reparse path component." }
            $cursor = Split-Path -Parent $cursor
            if ([string]::IsNullOrWhiteSpace($cursor) -or $cursor.Equals([IO.Path]::GetPathRoot($cursor), $comparison)) {
                throw "$Context escaped the Core run root."
            }
        }
        return $full
    }

    function Assert-AtlassianSourceReportEvidenceFile {
        param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Sha256,
            [Parameter(Mandatory)][string] $RunRoot, [Parameter(Mandatory)][string] $Context)
        if ($Sha256 -cnotmatch '^[0-9a-f]{64}$') { throw "$Context is missing, malformed, or outside the Core run root." }
        $full = Assert-AtlassianSourceReportEvidencePath -Path $Path -RunRoot $RunRoot -Context $Context
        if ((Get-FileHash -LiteralPath $full -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() -cne $Sha256) {
            throw "$Context hash differs from its report binding."
        }
    }

    function Test-AtlassianSourceIntegerValue {
        param([AllowNull()][object] $Value)
        return ($Value -is [sbyte] -or $Value -is [byte] -or $Value -is [int16] -or $Value -is [uint16] -or
            $Value -is [int] -or $Value -is [uint32] -or $Value -is [long] -or $Value -is [uint64])
    }

    $runRoot = [IO.Path]::GetFullPath([string]$Report.artifacts.runRoot)
    $activeSkills = @($Report.candidate.activeSkills | ForEach-Object { [string]$_ })
    if ($activeSkills.Count -eq 0 -or @($activeSkills | Select-Object -Unique).Count -ne $activeSkills.Count) {
        throw 'Source report native evidence has no exact active Skill inventory.'
    }
    $nativeEventCounts = @{ 'skill-validator' = 0; 'skill-tools' = 0; 'static-analyzer' = 0 }
    foreach ($event in @($source.Value.events)) {
        $toolId = [string]$event.toolId
        $eventPath = Assert-AtlassianSourceReportEvidencePath -Path ([string]$event.outputPath) -RunRoot $runRoot -Context 'Source native event output'
        if ($event.outputSha256 -isnot [string] -or [string]$event.outputSha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw 'Source native event output hash is missing or malformed.'
        }
        $eventRecord = Get-Content -LiteralPath $eventPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -Depth 60 -ErrorAction Stop
        if ($null -eq $eventRecord -or $null -eq $eventRecord.process) {
            throw 'Source native event output does not bind a clean passing tool process.'
        }
        foreach ($identityField in @('eventId', 'stageId', 'toolId', 'skillId', 'candidateId')) {
            $reportIdentity = $event.PSObject.Properties[$identityField]
            $recordIdentity = $eventRecord.PSObject.Properties[$identityField]
            if ($null -eq $reportIdentity -or $null -eq $recordIdentity) {
                throw 'Source native event output does not bind report metadata.'
            }
            $reportValue = $reportIdentity.Value
            $recordValue = $recordIdentity.Value
            if ($identityField -ceq 'skillId') {
                if (($null -eq $reportValue) -ne ($null -eq $recordValue) -or
                    ($null -ne $reportValue -and ($reportValue -isnot [string] -or $recordValue -isnot [string] -or [string]$reportValue -cne [string]$recordValue))) {
                    throw 'Source native event output does not bind report metadata.'
                }
            }
            elseif ($reportValue -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$reportValue) -or
                $recordValue -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$recordValue) -or
                [string]$reportValue -cne [string]$recordValue) {
                throw 'Source native event output does not bind report metadata.'
            }
        }
        $reportExitCode = $event.PSObject.Properties['exitCode']
        $processExitCodeProperty = $eventRecord.process.PSObject.Properties['exitCode']
        $recordSchemaVersion = $eventRecord.PSObject.Properties['schemaVersion']
        $reportExitCodeValue = if ($null -eq $reportExitCode) { $null } else { $reportExitCode.Value }
        $processExitCodeValue = if ($null -eq $processExitCodeProperty) { $null } else { $processExitCodeProperty.Value }
        $schemaVersionValue = if ($null -eq $recordSchemaVersion) { $null } else { $recordSchemaVersion.Value }
        $reportExitCodeIsZero = $null -ne $reportExitCode -and (Test-AtlassianSourceIntegerValue -Value $reportExitCodeValue) -and $reportExitCodeValue -eq 0
        $processExitCodeIsZero = $null -ne $processExitCodeProperty -and (Test-AtlassianSourceIntegerValue -Value $processExitCodeValue) -and $processExitCodeValue -eq 0
        $schemaVersionIsOne = $null -ne $recordSchemaVersion -and (Test-AtlassianSourceIntegerValue -Value $schemaVersionValue) -and $schemaVersionValue -eq 1
        if (-not $reportExitCodeIsZero -or -not $processExitCodeIsZero -or
            [string]$event.status -cne 'passed' -or
            $event.cleanedUp -isnot [bool] -or -not $event.cleanedUp -or
            -not $schemaVersionIsOne -or
            [string]$eventRecord.process.status -cne 'passed' -or $eventRecord.process.cleanedUp -isnot [bool] -or
            -not $eventRecord.process.cleanedUp) {
            throw 'Source native event output does not bind a clean passing tool process.'
        }
        if ($eventRecord.stdout -isnot [string] -or $eventRecord.stderr -isnot [string]) {
            throw 'Source native event output does not contain raw stdout and stderr strings.'
        }
        $combinedOutput = [string]$eventRecord.stdout + "`n---stderr---`n" + [string]$eventRecord.stderr
        $outputBytes = [Text.UTF8Encoding]::new($false).GetBytes($combinedOutput)
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $outputSha256 = [Convert]::ToHexString($sha.ComputeHash($outputBytes)).ToLowerInvariant() }
        finally { $sha.Dispose() }
        if ($outputSha256 -cne [string]$event.outputSha256) {
            throw 'Source native event output hash differs from its report binding.'
        }
        if (-not $nativeEventCounts.ContainsKey($toolId)) { continue }
        $envelope = $null
        try { $envelope = ConvertFrom-Json -InputObject ([string]$eventRecord.stdout) -Depth 60 -ErrorAction Stop }
        catch { throw 'Source native event stdout does not contain a valid tool envelope.' }
        $nativeReports = @($envelope.nativeReports)
        if ($nativeReports.Count -eq 0) { throw 'Source native event omitted its native report inventory.' }
        foreach ($native in $nativeReports) {
            $nativeExitCode = $native.PSObject.Properties['exitCode']
            $nativeExitCodeValue = if ($null -eq $nativeExitCode) { $null } else { $nativeExitCode.Value }
            if ([string]$native.skillId -cnotin $activeSkills -or $null -eq $nativeExitCode -or
                -not (Test-AtlassianSourceIntegerValue -Value $nativeExitCodeValue) -or $nativeExitCodeValue -ne 0 -or
                $native.arguments -isnot [array] -or @($native.arguments).Count -eq 0) {
                throw 'Source native report does not bind the expected Skill, arguments, or successful exit.'
            }
            Assert-AtlassianSourceReportEvidenceFile -Path ([string]$native.path) -Sha256 ([string]$native.sha256) -RunRoot $runRoot -Context 'Source native JSON report'
        }
        $nativeEventCounts[$toolId] += $nativeReports.Count
    }
    foreach ($toolId in @('skill-validator', 'skill-tools', 'static-analyzer')) {
        if ([int]$nativeEventCounts[$toolId] -ne $activeSkills.Count) {
            throw "Source report native raw evidence is incomplete for $toolId."
        }
    }
    return $true
}

function New-AtlassianCoreAdapterV2 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $PowerShellPath,
        [Parameter(Mandatory = $true)][string] $TrustedToolRoot,
        [Parameter(Mandatory = $true)][string] $CandidateAuthorityAdapterRunId,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{40}$')][string] $CandidateRevision,
        [Parameter(Mandatory = $true)][string] $CandidateGitEntryModeManifestPath,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{64}$')][string] $CandidateGitEntryModeManifestSha256,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $ActiveSkillIds,
        [Parameter(Mandatory = $true)] $SourceValidation,
        [Parameter(Mandatory = $true)] $PesterRuntime
    )

    $fullPowerShellPath = [IO.Path]::GetFullPath($PowerShellPath)
    $fullTrustedToolRoot = [IO.Path]::GetFullPath($TrustedToolRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $pathComparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not (Test-Path -LiteralPath $fullPowerShellPath -PathType Leaf)) { throw 'Trusted PowerShell executable is missing.' }
    if (-not $fullPowerShellPath.Equals($fullTrustedToolRoot, $pathComparison) -and
        -not $fullPowerShellPath.StartsWith($fullTrustedToolRoot + [IO.Path]::DirectorySeparatorChar, $pathComparison)) {
        throw 'Trusted PowerShell executable must be within TrustedToolRoot.'
    }
    if ($CandidateAuthorityAdapterRunId -cnotmatch '^[0-9a-f]{32}$') { throw 'Core source adapter requires one canonical RunId.' }
    if ($ActiveSkillIds.Count -eq 0) { throw 'Core source adapter requires at least one active Skill.' }
    [string[]]$ids = @($ActiveSkillIds)
    $sorted = @($ids)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    if (($ids -join "`n") -cne ($sorted -join "`n") -or @($ids | Select-Object -Unique).Count -ne $ids.Count) {
        throw 'Core source adapter Skill inventory must be unique and ordinal sorted.'
    }
    foreach ($skillId in $ids) {
        if ($skillId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "Core source adapter contains an invalid Skill ID: '$skillId'." }
    }
    $sourceFields = @('packageAdapter', 'skillValidator', 'skillTools', 'staticAnalyzer', 'frozenFiles', 'toolReceipts')
    $sourceProperties = @($SourceValidation.PSObject.Properties | ForEach-Object { [string]$_.Name })
    if ($sourceProperties.Count -ne $sourceFields.Count -or
        @($sourceFields | Where-Object { $sourceProperties -cnotcontains $_ }).Count -gt 0 -or
        @($sourceProperties | Where-Object { $sourceFields -cnotcontains $_ }).Count -gt 0) {
        throw 'Prepared source validation payload has an invalid property set.'
    }
    foreach ($slot in @('packageAdapter', 'skillValidator', 'skillTools', 'staticAnalyzer')) {
        $dispatch = $SourceValidation.$slot
        $dispatchProperties = @($dispatch.PSObject.Properties | ForEach-Object { [string]$_.Name })
        if ($dispatchProperties.Count -ne 2 -or $dispatchProperties -cnotcontains 'command' -or $dispatchProperties -cnotcontains 'arguments' -or
            [string]$dispatch.command -cne $fullPowerShellPath -or $dispatch.arguments -isnot [array] -or @($dispatch.arguments).Count -lt 5) {
            throw "Prepared source validation dispatch '$slot' is incomplete or does not use the verified PowerShell executable."
        }
    }
    $pesterFields = @('moduleManifestPath', 'closureLockPath', 'closureLockSha256', 'setupReceiptPath', 'setupReceiptSha256',
        'runtimeRoot', 'runtimeExecutablePath', 'runtimeExecutableSha256', 'runtimeInventoryPath', 'runtimeInventorySha256', 'sourceTrustedToolRoot')
    $pesterProperties = @($PesterRuntime.PSObject.Properties | ForEach-Object { [string]$_.Name })
    if ($pesterProperties.Count -ne $pesterFields.Count -or
        @($pesterFields | Where-Object { $pesterProperties -cnotcontains $_ }).Count -gt 0 -or
        @($pesterProperties | Where-Object { $pesterFields -cnotcontains $_ }).Count -gt 0) {
        throw 'Prepared Pester runtime binding has an invalid property set.'
    }
    foreach ($field in @('moduleManifestPath', 'closureLockPath', 'setupReceiptPath', 'runtimeRoot', 'runtimeExecutablePath', 'runtimeInventoryPath', 'sourceTrustedToolRoot')) {
        if ([string]::IsNullOrWhiteSpace([string]$PesterRuntime.$field) -or -not [IO.Path]::IsPathRooted([string]$PesterRuntime.$field)) {
            throw "Prepared Pester runtime '$field' must be an absolute path."
        }
    }
    Assert-AtlassianSourceSha256 -Value ([string]$PesterRuntime.closureLockSha256) -Context 'Prepared Pester closure lock'
    Assert-AtlassianSourceSha256 -Value ([string]$PesterRuntime.setupReceiptSha256) -Context 'Prepared Pester setup receipt'
    Assert-AtlassianSourceSha256 -Value ([string]$PesterRuntime.runtimeExecutableSha256) -Context 'Prepared PowerShell executable'
    Assert-AtlassianSourceSha256 -Value ([string]$PesterRuntime.runtimeInventorySha256) -Context 'Prepared PowerShell runtime inventory'
    foreach ($field in @('moduleManifestPath', 'closureLockPath', 'setupReceiptPath')) {
        if (-not (Test-Path -LiteralPath ([string]$PesterRuntime.$field) -PathType Leaf)) {
            throw "Prepared Pester runtime '$field' is missing."
        }
    }
    foreach ($binding in @(
        [pscustomobject]@{ path = [string]$PesterRuntime.closureLockPath; hash = [string]$PesterRuntime.closureLockSha256; name = 'Pester closure lock' },
        [pscustomobject]@{ path = [string]$PesterRuntime.setupReceiptPath; hash = [string]$PesterRuntime.setupReceiptSha256; name = 'Pester setup receipt' },
        [pscustomobject]@{ path = [string]$PesterRuntime.runtimeInventoryPath; hash = [string]$PesterRuntime.runtimeInventorySha256; name = 'PowerShell runtime inventory' },
        [pscustomobject]@{ path = [string]$PesterRuntime.runtimeExecutablePath; hash = [string]$PesterRuntime.runtimeExecutableSha256; name = 'PowerShell executable' }
    )) {
        if ((Get-FileHash -LiteralPath $binding.path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $binding.hash) { throw "$($binding.name) changed after source setup." }
    }

    $powerShellSha256 = (Get-FileHash -LiteralPath $fullPowerShellPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $trustedRuntimeRoot = [IO.Path]::GetFullPath([string]$PesterRuntime.runtimeRoot)
    $trustedRuntimeExecutable = [IO.Path]::GetFullPath([string]$PesterRuntime.runtimeExecutablePath)
    if (-not $trustedRuntimeExecutable.Equals($fullPowerShellPath, $pathComparison) -or
        -not $trustedRuntimeExecutable.StartsWith($trustedRuntimeRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar, $pathComparison) -or
        $powerShellSha256 -cne [string]$PesterRuntime.runtimeExecutableSha256) {
        throw 'Core adapter executable does not match the exact prepared run-owned PowerShell runtime.'
    }
    $runtimeFrozenFiles = [Collections.Generic.Dictionary[string, string]]::new($(if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }))
    foreach ($file in @($SourceValidation.frozenFiles)) {
        if ($null -eq $file -or [string]$file.path -cnotmatch '^(?:[A-Za-z]:\\|/)' -or [string]$file.sha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw 'Core adapter source frozen file entry is malformed.'
        }
        $path = [IO.Path]::GetFullPath([string]$file.path)
        if (-not $runtimeFrozenFiles.TryAdd($path, [string]$file.sha256)) { throw 'Core adapter source frozen file inventory contains a duplicate path.' }
    }
    [void](Assert-AtlassianSourceRuntimeInventory -PesterRuntime $PesterRuntime -OwnedRoot (Split-Path -Parent $trustedRuntimeRoot) -FrozenFiles $runtimeFrozenFiles)
    $generalArguments = @('-NoProfile', '-NonInteractive', '-File', 'scripts/Test-Repository.ps1', '-ReadOnlySnapshot')
    $pesterArguments = @('-NoProfile', '-NonInteractive', '-File', 'scripts/Invoke-CorePester.ps1',
        '-CandidateAuthorityAdapterRunId', $CandidateAuthorityAdapterRunId, '-CandidateRevision', $CandidateRevision)
    return [ordered]@{
        schemaVersion = 2
        adapter = 'standard-core-adapter-v2'
        skillsRoot = 'skills'
        activeSkills = @($ids)
        sourceValidation = $SourceValidation
        checks = @(
            [ordered]@{ id = 'repository-general'; kind = 'general'; executable = $fullPowerShellPath; executableSha256 = $powerShellSha256; arguments = $generalArguments }
            [ordered]@{ id = 'repository-pester'; kind = 'pester'; executable = $fullPowerShellPath; executableSha256 = $powerShellSha256; arguments = $pesterArguments }
        )
    }
}


# Shared Atlassian child implementation; definitions only, with no acquisition or execution.
. (Join-Path $PSScriptRoot 'Invoke-SourceConformance.ps1') -DefineFunctionsOnly

function Get-GitBlobSha256 {
    param(
        [Parameter(Mandatory = $true)][string] $GitPath,
        [Parameter(Mandatory = $true)][string] $RepositoryRoot,
        [Parameter(Mandatory = $true)][string] $ObjectId
    )

    if ($ObjectId -cnotmatch '^[0-9a-f]{40}$') { throw "Invalid Git blob identity '$ObjectId'." }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $GitPath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @('-C', $RepositoryRoot, 'cat-file', 'blob', $ObjectId)) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        if (-not $process.Start()) { throw "Could not start Git blob reader for '$ObjectId'." }
        $hash = $hasher.ComputeHash($process.StandardOutput.BaseStream)
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "Git blob reader failed for '$ObjectId': $stderr" }
        return ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $hasher.Dispose()
        $process.Dispose()
    }
}

function Get-GitEntryModeManifest {
    param(
        [Parameter(Mandatory = $true)][string] $GitPath,
        [Parameter(Mandatory = $true)][string] $RepositoryRoot,
        [Parameter(Mandatory = $true)][string] $CandidateCommit
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $GitPath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @('-C', $RepositoryRoot, 'ls-tree', '-r', '-z', '--full-tree', '--format=%(objectmode)%x09%(objectname)%x09%(path)', $CandidateCommit)) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $output = [IO.MemoryStream]::new()
    try {
        if (-not $process.Start()) { throw 'Could not start Git tree inventory process.' }
        $process.StandardOutput.BaseStream.CopyTo($output)
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "Git tree inventory failed: $stderr" }
        $raw = [Text.UTF8Encoding]::new($false, $true).GetString($output.ToArray())
    }
    finally {
        $output.Dispose()
        $process.Dispose()
    }

    $entries = @()
    foreach ($record in $raw.Split([char]0, [StringSplitOptions]::RemoveEmptyEntries)) {
        $firstSeparator = $record.IndexOf([char]9)
        $secondSeparator = if ($firstSeparator -ge 0) { $record.IndexOf([char]9, $firstSeparator + 1) } else { -1 }
        if ($firstSeparator -le 0 -or $secondSeparator -le $firstSeparator + 1 -or $secondSeparator -ge $record.Length - 1) {
            throw 'Git tree inventory returned a malformed entry.'
        }
        $mode = $record.Substring(0, $firstSeparator)
        $objectId = $record.Substring($firstSeparator + 1, $secondSeparator - $firstSeparator - 1)
        $path = $record.Substring($secondSeparator + 1)
        $segments = $path.Split('/')
        if ([IO.Path]::IsPathRooted($path) -or $mode -cnotmatch '^[0-9]{6}$' -or $segments -contains '' -or
            $segments -contains '.' -or $segments -contains '..' -or $path.Contains('\') -or
            $path.Contains(':') -or $path -cmatch '[\x00-\x1f\x7f]' -or $objectId -cnotmatch '^[0-9a-f]{40}$') {
            throw "Git tree inventory returned an unsafe entry '$path' with mode '$mode'."
        }
        $entries += [ordered]@{ path = $path; mode = $mode; sha256 = Get-GitBlobSha256 -GitPath $GitPath -RepositoryRoot $RepositoryRoot -ObjectId $objectId }
    }
    if ($entries.Count -eq 0) { throw 'Git tree inventory did not contain any canonical Skill entries.' }
    return [ordered]@{ schemaVersion = 3; candidateCommit = $CandidateCommit; entries = $entries }
}


function Copy-AtlassianSourcePowerShellRuntime {
    param(
        [Parameter(Mandatory)][string] $PowerShellPath,
        [Parameter(Mandatory)][string] $TrustedToolRoot,
        [Parameter(Mandatory)][string] $OwnedRoot
    )

    $sourceExecutable = [IO.Path]::GetFullPath($PowerShellPath)
    $sourceRoot = [IO.Path]::GetFullPath((Split-Path -Parent $sourceExecutable))
    $runtimeExecutableName = if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' }
    if ([IO.Path]::GetFileName($sourceExecutable) -ine $runtimeExecutableName -or
        -not (Test-Path -LiteralPath $sourceExecutable -PathType Leaf) -or
        -not (Test-PathWithinOrEqual -Path $sourceExecutable -Root $TrustedToolRoot)) {
        throw "Source runtime copy requires the exact $runtimeExecutableName inside TrustedToolRoot."
    }
    Assert-NoReparseAncestors -Path $sourceExecutable -Context 'Trusted source PowerShell executable'
    $runtimeRoot = Assert-PathWithinRoot -Path (Join-Path $OwnedRoot 'runtime') -Root $OwnedRoot -Context 'Run-owned PowerShell runtime'
    if (Test-Path -LiteralPath $runtimeRoot) { throw 'Run-owned PowerShell runtime destination already exists.' }
    [void](New-Item -ItemType Directory -Path $runtimeRoot -ErrorAction Stop)

    $sourcePrefix = $sourceRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    foreach ($item in @(Get-ChildItem -LiteralPath $sourceRoot -Force -Recurse -ErrorAction Stop)) {
        $sourceItemPath = [IO.Path]::GetFullPath($item.FullName)
        if (-not $sourceItemPath.StartsWith($sourcePrefix, $(if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }))) {
            throw 'Trusted PowerShell runtime inventory escaped its installation root.'
        }
        $relative = [IO.Path]::GetRelativePath($sourceRoot, $sourceItemPath)
        $relativeSegments = @($relative -split '[\\/]')
        if ($relativeSegments.Count -ge 2 -and $relativeSegments[0] -ieq 'Modules' -and $relativeSegments[1] -ieq 'Pester') {
            continue
        }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Trusted PowerShell runtime contains an unexpected reparse point: $sourceItemPath"
        }
        $target = Join-Path $runtimeRoot $relative
        if ($item.PSIsContainer) {
            [void](New-Item -ItemType Directory -Path $target -Force -ErrorAction Stop)
            continue
        }
        $targetParent = Split-Path -Parent $target
        [void](New-Item -ItemType Directory -Path $targetParent -Force -ErrorAction Stop)
        [IO.File]::Copy($sourceItemPath, $target, $false)
    }
    $ownedExecutable = [IO.Path]::GetFullPath((Join-Path $runtimeRoot ([IO.Path]::GetFileName($sourceExecutable))))
    if (-not (Test-Path -LiteralPath $ownedExecutable -PathType Leaf)) { throw "Run-owned PowerShell runtime copy is missing $runtimeExecutableName." }
    Assert-NoReparseAncestors -Path $runtimeRoot -Context 'Run-owned PowerShell runtime'
    $ownedExecutableHash = Get-FileSha256 -Path $ownedExecutable
    $ownedFiles = @(Get-ChildItem -LiteralPath $runtimeRoot -Recurse -File -Force -ErrorAction Stop | ForEach-Object {
        if ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Run-owned PowerShell runtime contains a reparse point: $($_.FullName)" }
        [pscustomobject]@{ path = [IO.Path]::GetFullPath($_.FullName); sha256 = Get-FileSha256 -Path $_.FullName }
    })
    if ($ownedFiles.Count -eq 0 -or @($ownedFiles | Where-Object { Test-PathEqual -Left ([string]$_.path) -Right $ownedExecutable }).Count -ne 1) {
        throw 'Run-owned PowerShell runtime inventory is empty or does not contain its exact executable.'
    }
    return [pscustomobject]@{ root = $runtimeRoot; executablePath = $ownedExecutable; executableSha256 = $ownedExecutableHash; files = $ownedFiles }
}

function Get-AtlassianSourceReceiptFrozenPaths {
    param([Parameter(Mandatory = $true)] $Receipt, [Parameter(Mandatory = $true)][string] $OwnedRoot)

    $paths = [Collections.Generic.List[string]]::new()
    $installRoot = [IO.Path]::GetFullPath([string]$Receipt.installRoot)
    $installedRoot = [IO.Path]::GetFullPath((Join-Path $OwnedRoot 'installed'))
    [void](Assert-PathWithinRoot -Path $installRoot -Root $installedRoot -Context 'Resolved source tool install root')
    if (-not (Test-Path -LiteralPath $installRoot -PathType Container)) { throw 'Resolved source tool install root is missing.' }
    foreach ($item in @(Get-ChildItem -LiteralPath $installRoot -Force -Recurse -ErrorAction Stop)) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Resolved source tool closure contains a reparse point: $($item.FullName)" }
        if (-not $item.PSIsContainer) { $paths.Add([IO.Path]::GetFullPath($item.FullName)) }
    }
    if ($paths.Count -eq 0) { throw 'Resolved source tool installed closure is empty.' }

    $pathHashPairs = @(
        @('executablePath', 'executableSha256'),
        @('entryPointPath', 'entryPointSha256'),
        @('nodePath', 'nodeSha256'),
        @('goRuntimePath', 'goRuntimeSha256'),
        @('resolverHelperPath', 'resolverHelperSha256')
    )
    foreach ($pair in $pathHashPairs) {
        $pathProperty = $Receipt.PSObject.Properties[[string]$pair[0]]
        if ($null -eq $pathProperty -or [string]::IsNullOrWhiteSpace([string]$pathProperty.Value)) { continue }
        $hashProperty = $Receipt.PSObject.Properties[[string]$pair[1]]
        $filePath = [IO.Path]::GetFullPath([string]$pathProperty.Value)
        if ($null -eq $hashProperty -or [string]$hashProperty.Value -cnotmatch '^[0-9a-f]{64}$' -or
            -not (Test-Path -LiteralPath $filePath -PathType Leaf) -or
            (Get-FileSha256 -Path $filePath) -cne [string]$hashProperty.Value) {
            throw "Resolved source tool path/hash pair is incomplete or changed: $($pair[0])"
        }
        Assert-NoReparseAncestors -Path $filePath -Context "Resolved source tool $($pair[0])"
        $paths.Add($filePath)
    }
    $launcher = $Receipt.PSObject.Properties['launcher']
    if ($null -ne $launcher -and $null -ne $launcher.Value) {
        foreach ($pair in @(@('shimPath', 'shimSha256'), @('payloadPath', 'payloadSha256'), @('runtimePath', 'runtimeSha256'))) {
            $pathProperty = $launcher.Value.PSObject.Properties[[string]$pair[0]]
            if ($null -eq $pathProperty -or [string]::IsNullOrWhiteSpace([string]$pathProperty.Value)) { continue }
            $hashProperty = $launcher.Value.PSObject.Properties[[string]$pair[1]]
            $filePath = [IO.Path]::GetFullPath([string]$pathProperty.Value)
            if ($null -eq $hashProperty -or [string]$hashProperty.Value -cnotmatch '^[0-9a-f]{64}$' -or
                -not (Test-Path -LiteralPath $filePath -PathType Leaf) -or
                (Get-FileSha256 -Path $filePath) -cne [string]$hashProperty.Value) {
                throw "Resolved source tool launcher path/hash pair is incomplete or changed: $($pair[0])"
            }
            Assert-NoReparseAncestors -Path $filePath -Context "Resolved source tool launcher $($pair[0])"
            $paths.Add($filePath)
        }
    }
    return @($paths | Select-Object -Unique)
}

function Assert-AtlassianSourceAuthorityCheckout {
    param([Parameter(Mandatory)][string] $GitPath, [Parameter(Mandatory)][string] $AuthorityRoot, [Parameter(Mandatory)] $AuthorityPin)

    $root = [IO.Path]::GetFullPath($AuthorityRoot)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "Pinned source authority checkout is missing: $root" }
    Assert-NoReparseAncestors -Path $root -Context 'Pinned source authority checkout'
    $top = @(& $GitPath -C $root rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or $top.Count -ne 1 -or -not (Test-PathEqual -Left ([string]$top[0]) -Right $root)) {
        throw 'Pinned source authority path is not the root of a Git checkout.'
    }
    $head = Resolve-GitRevision -GitPath $GitPath -Root $root -Revision 'HEAD' -Context 'Pinned source authority HEAD'
    if ($head -cne [string]$AuthorityPin.commit) { throw 'Pinned source authority HEAD does not match the approved 3c55daa revision.' }
    $origins = @(& $GitPath -C $root config --local --get-all remote.origin.url 2>$null)
    if ($LASTEXITCODE -ne 0 -or $origins.Count -ne 1) { throw 'Pinned source authority checkout must have exactly one origin URL.' }
    $origin = ([string]$origins[0]).Trim().TrimEnd('/') -replace '\.git$', ''
    $expectedOrigin = ([string]$AuthorityPin.repository).Trim().TrimEnd('/') -replace '\.git$', ''
    if (-not $origin.Equals($expectedOrigin, [StringComparison]::OrdinalIgnoreCase)) { throw 'Pinned source authority origin differs from the approved repository.' }
    $dirty = @(& $GitPath -C $root status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0 -or $dirty.Count -ne 0) { throw 'Pinned source authority checkout must be clean and immutable.' }
    foreach ($entry in $AuthorityPin.files.GetEnumerator()) {
        $path = Assert-PathWithinRoot -Path (Join-Path $root ($entry.Key -replace '/', [IO.Path]::DirectorySeparatorChar)) -Root $root -Context 'Pinned source authority file'
        Assert-NoReparseAncestors -Path $path -Context 'Pinned source authority file'
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Pinned source authority file is missing: $($entry.Key)" }
        $blob = @(& $GitPath -C $root rev-parse --verify --end-of-options "$head`:$($entry.Key)" 2>$null)
        if ($LASTEXITCODE -ne 0 -or $blob.Count -ne 1 -or ([string]$blob[0]).Trim() -cnotmatch '^[0-9a-f]{40}$' -or
            (Get-GitBlobSha256 -GitPath $GitPath -RepositoryRoot $root -ObjectId ([string]$blob[0]).Trim()) -cne [string]$entry.Value -or
            (Get-FileSha256 -Path $path) -cne [string]$entry.Value) {
            throw "Pinned source authority Git blob or worktree bytes differ: $($entry.Key)"
        }
    }
    return [pscustomobject]@{ root = $root; runnerPath = (Join-Path $root 'scripts/Invoke-StandardValidation.ps1'); revision = $head }
}

function New-AtlassianSourceAuthoritySnapshot {
    param([Parameter(Mandatory)][string] $GitPath, [Parameter(Mandatory)][string] $SourceRoot,
        [Parameter(Mandatory)][string] $OwnedRoot, [Parameter(Mandatory)] $AuthorityPin)

    $snapshot = Assert-PathWithinRoot -Path (Join-Path $OwnedRoot 'authority') -Root $OwnedRoot -Context 'Source Core authority snapshot'
    if (Test-Path -LiteralPath $snapshot) { throw 'Source Core authority snapshot already exists.' }
    $hooksRoot = Join-Path $OwnedRoot '.empty-git-hooks'
    [void](New-Item -ItemType Directory -Path $hooksRoot -ErrorAction Stop)
    Assert-NoReparseAncestors -Path $hooksRoot -Context 'Source authority snapshot hooks'
    & $GitPath -c "core.hooksPath=$hooksRoot" -c core.autocrlf=false -c core.longpaths=true clone --quiet --local --no-hardlinks --no-checkout -- $SourceRoot $snapshot
    if ($LASTEXITCODE -ne 0) { throw 'Could not materialize protected source authority objects in the run-owned snapshot.' }
    foreach ($setting in @(@('core.autocrlf', 'false'), @('core.longpaths', 'true'))) {
        & $GitPath -C $snapshot config --local $setting[0] $setting[1]
        if ($LASTEXITCODE -ne 0) { throw "Could not set protected authority snapshot option $($setting[0])." }
    }
    $paths = @($AuthorityPin.files.Keys)
    & $GitPath -c "core.hooksPath=$hooksRoot" -C $snapshot sparse-checkout set --no-cone -- $paths
    if ($LASTEXITCODE -ne 0) { throw 'Could not select the exact approved 3c55daa authority closure.' }
    & $GitPath -C $snapshot config --local --replace-all remote.origin.url ([string]$AuthorityPin.repository)
    if ($LASTEXITCODE -ne 0) { throw 'Could not bind the source authority snapshot origin.' }
    & $GitPath -c "core.hooksPath=$hooksRoot" -c core.autocrlf=false -C $snapshot checkout --quiet --detach ([string]$AuthorityPin.commit)
    if ($LASTEXITCODE -ne 0) { throw 'Could not check out the exact 3c55daa source authority revision.' }
    return Assert-AtlassianSourceAuthorityCheckout -GitPath $GitPath -AuthorityRoot $snapshot -AuthorityPin $AuthorityPin
}

function Get-AtlassianSourceCoreRunPaths {
    param([Parameter(Mandatory)][string] $ArtifactsRoot, [Parameter(Mandatory)][bool] $ArtifactsRootWasExplicit,
        [Parameter(Mandatory)][string] $RunId, [string] $OutputPath)

    $requestedRoot = [IO.Path]::GetFullPath($ArtifactsRoot)
    if ($RunId -cnotmatch '^[0-9a-f]{32}$') { throw 'Prepared source RunId is invalid.' }
    $coreRoot = if ($ArtifactsRootWasExplicit) { $requestedRoot } else { Join-Path $requestedRoot "core-v2-$RunId" }
    $adapterParent = if ($ArtifactsRootWasExplicit) { Split-Path -Parent $coreRoot } else { $requestedRoot }
    if ([string]::IsNullOrWhiteSpace($adapterParent)) { throw 'Could not resolve a separate source adapter root.' }
    $adapterRoot = Join-Path $adapterParent ".core-v2-adapter-$RunId"
    if ((Test-PathWithinOrEqual -Path $adapterRoot -Root $coreRoot) -or (Test-PathWithinOrEqual -Path $coreRoot -Root $adapterRoot)) {
        throw 'Source Core adapter and artifacts root must be separate paths.'
    }
    $outputFull = if ([string]::IsNullOrWhiteSpace($OutputPath)) { Join-Path $coreRoot 'standard-core-validation-v2-report.json' }
        else { Assert-PathWithinRoot -Path $OutputPath -Root $coreRoot -Context 'Source OutputPath' }
    return [pscustomobject]@{ runId = $RunId; artifactsRoot = [IO.Path]::GetFullPath($coreRoot); adapterRoot = [IO.Path]::GetFullPath($adapterRoot); adapterPath = [IO.Path]::GetFullPath((Join-Path $adapterRoot 'standard-core-adapter-v2.json')); outputPath = [IO.Path]::GetFullPath($outputFull) }
}

function Invoke-AtlassianSourceToolSetup {
    param([Parameter(Mandatory)][string] $GitPath, [Parameter(Mandatory)][string] $PowerShellPath,
        [Parameter(Mandatory)][string] $RepositoryRoot, [Parameter(Mandatory)][string] $CandidateRevision,
        [Parameter(Mandatory)] $AuthorityConfig, [Parameter(Mandatory)][string] $SourceToolsPath,
        [Parameter(Mandatory)][string] $AuthorityRepositoryRoot, [string] $TrustedToolRoot,
        [string] $ExpectedGoRuntimeVersion, [Parameter(Mandatory)][int] $TimeoutSeconds)

    $setupStartedAtUtc = [DateTimeOffset]::UtcNow
    $setupTimer = [Diagnostics.Stopwatch]::StartNew()
    $setupStageSeconds = [ordered]@{}
    $resolverStageSeconds = [ordered]@{}
    $pin = Assert-AtlassianSourceAuthorityConfig -Config $AuthorityConfig
    $authority = Assert-AtlassianSourceAuthorityCheckout -GitPath $GitPath -AuthorityRoot $AuthorityRepositoryRoot -AuthorityPin $pin
    $sourcePowerShell = [IO.Path]::GetFullPath($PowerShellPath)
    $trustedRoot = if ([string]::IsNullOrWhiteSpace($TrustedToolRoot)) { Split-Path -Parent $sourcePowerShell } else { [IO.Path]::GetFullPath($TrustedToolRoot) }
    if (-not (Test-Path -LiteralPath $trustedRoot -PathType Container)) { throw 'Trusted PowerShell tool root is missing.' }
    Assert-NoReparseAncestors -Path $trustedRoot -Context 'Trusted PowerShell tool root'
    if (-not (Test-PathWithinOrEqual -Path $sourcePowerShell -Root $trustedRoot)) { throw 'PowerShell executable must remain inside TrustedToolRoot.' }
    Assert-OutsideRoot -Path $trustedRoot -Root $RepositoryRoot -Context 'TrustedToolRoot'
    Assert-OutsideRoot -Path $trustedRoot -Root $authority.root -Context 'TrustedToolRoot'

    $preparedPath = [IO.Path]::GetFullPath($SourceToolsPath)
    $setupRoot = [IO.Path]::GetFullPath((Split-Path -Parent $preparedPath))
    if (-not (Test-Path -LiteralPath $setupRoot -PathType Container)) { [void](New-Item -ItemType Directory -Path $setupRoot -Force -ErrorAction Stop) }
    if (-not (Test-PathEqual -Left (Split-Path -Parent $preparedPath) -Right $setupRoot)) { throw 'SourceToolsPath must resolve directly within its setup root.' }
    if (Test-Path -LiteralPath $preparedPath) { throw 'Prepared source toolset output already exists.' }
    Assert-OutsideRoot -Path $setupRoot -Root $RepositoryRoot -Context 'Source setup artifacts'
    Assert-OutsideRoot -Path $setupRoot -Root $authority.root -Context 'Source setup artifacts'
    Assert-OutsideRoot -Path $setupRoot -Root $trustedRoot -Context 'Source setup artifacts'
    Assert-NoReparseAncestors -Path $setupRoot -Context 'Source setup artifacts'

    $runId = [guid]::NewGuid().ToString('N')
    $ownedRoot = Assert-PathWithinRoot -Path (Join-Path $setupRoot "source-tools-$runId") -Root $setupRoot -Context 'Source setup owned root'
    if (Test-Path -LiteralPath $ownedRoot) { throw 'Source setup run-owned root unexpectedly exists.' }
    [void](New-Item -ItemType Directory -Path $ownedRoot -ErrorAction Stop)
    Assert-NoReparseAncestors -Path $ownedRoot -Context 'Source setup owned root'
    $stageTimer = [Diagnostics.Stopwatch]::StartNew()
    $runtimeCopy = Copy-AtlassianSourcePowerShellRuntime -PowerShellPath $sourcePowerShell -TrustedToolRoot $trustedRoot -OwnedRoot $ownedRoot
    $stageTimer.Stop()
    $setupStageSeconds.runtimeCopyAndInventorySeconds = [Math]::Round($stageTimer.Elapsed.TotalSeconds, 3)
    $powerShell = [string]$runtimeCopy.executablePath
    $runtimeRoot = [string]$runtimeCopy.root

    $runner = [IO.Path]::GetFullPath($authority.runnerPath)
    $resolver = Join-Path $authority.root 'scripts/Resolve-StandardValidationTool.ps1'
    $policy = Join-Path $authority.root 'docs/standards/validation-toolchain.json'
    foreach ($binding in @(@($runner, 'scripts/Invoke-StandardValidation.ps1'), @($resolver, 'scripts/Resolve-StandardValidationTool.ps1'), @($policy, 'docs/standards/validation-toolchain.json'))) {
        if ((Get-FileSha256 -Path $binding[0]) -cne [string]$pin.files[$binding[1]]) { throw "Verified authority file changed before setup: $($binding[1])" }
    }
    # Dot-sourcing binds the runner's parameters in this scope. Preserve the
    # setup identity and caller options instead of accepting its empty/defaults.
    . $runner -DefineFunctionsOnly -CandidateRoot $RepositoryRoot -AdapterPath $preparedPath -ArtifactsRoot $setupRoot `
        -SourceRepository $script:SourceRepository -SourceRevision $CandidateRevision -BaseRevision $CandidateRevision -AuthorityRevision $pin.commit `
        -RunId $runId -TimeoutSeconds $TimeoutSeconds -TrustedToolRoot $trustedRoot

    $stageTimer = [Diagnostics.Stopwatch]::StartNew()
    $manifestPath = Join-Path $ownedRoot 'candidate-git-entry-modes.json'
    $manifest = Get-GitEntryModeManifest -GitPath $GitPath -RepositoryRoot $RepositoryRoot -CandidateCommit $CandidateRevision
    $protectedSourceRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
    $protectedDispatchBindings = @(Assert-AtlassianSourceProtectedDispatchFiles -ProtectedBaseRoot $protectedSourceRoot `
        -CandidateRoot $RepositoryRoot -ManifestEntries @($manifest.entries))
    Write-Utf8NoBomCreateNew -Path $manifestPath -Text (($manifest | ConvertTo-Json -Depth 40) + [Environment]::NewLine)
    $manifestSha256 = Get-FileSha256 -Path $manifestPath
    $archivePath = Join-Path $ownedRoot 'candidate.zip'
    & $GitPath -C $RepositoryRoot archive --format=zip "--output=$archivePath" $CandidateRevision
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $archivePath -PathType Leaf)) { throw 'Source setup could not archive the exact immutable candidate.' }
    $archiveSha256 = Get-FileSha256 -Path $archivePath
    $stageTimer.Stop()
    $setupStageSeconds.candidateManifestAndArchiveSeconds = [Math]::Round($stageTimer.Elapsed.TotalSeconds, 3)
    $sourceIdentityPath = Join-Path $ownedRoot 'source-run-identity.json'
    $sourceIdentity = [ordered]@{
        schemaVersion = 1
        runId = $runId
        sourceRevision = $CandidateRevision
        authorityRevision = [string]$pin.commit
        candidateManifestPath = [IO.Path]::GetFullPath($manifestPath)
        candidateManifestSha256 = $manifestSha256
        candidateArchivePath = [IO.Path]::GetFullPath($archivePath)
        candidateArchiveSha256 = $archiveSha256
    }
    Write-Utf8NoBomCreateNew -Path $sourceIdentityPath -Text (($sourceIdentity | ConvertTo-Json -Depth 20) + [Environment]::NewLine)

    $receipts = [ordered]@{}
    $receiptBindings = @()
    $goVersion = Resolve-GoRuntimeVersion -Expected $ExpectedGoRuntimeVersion
    foreach ($toolName in @('skill-validator', 'skill-tools', 'skillspector')) {
        $resolverTimer = [Diagnostics.Stopwatch]::StartNew()
        $receiptPath = Join-Path $ownedRoot "receipt-$toolName.json"
        foreach ($inputName in @('powerShell', 'resolver', 'policy', 'toolName', 'ownedRoot', 'goVersion', 'runId', 'receiptPath')) {
            $inputValue = Get-Variable -Name $inputName -ValueOnly -Scope Local
            if ($inputValue -isnot [string] -or [string]::IsNullOrWhiteSpace($inputValue)) {
                throw "Source resolver setup requires a nonempty scalar string: `$$inputName."
            }
        }
        $processResult = & (Get-Command -Name 'Invoke-StandardValidationProcess' -CommandType Function -ErrorAction Stop) -Command $powerShell -Arguments @('-NoProfile', '-NonInteractive', '-File', $resolver,
            '-PolicyPath', $policy, '-ToolName', $toolName, '-Install', '-InstallRoot', (Join-Path $ownedRoot 'installed'),
            '-ExpectedGoRuntimeVersion', $goVersion, '-RunId', $runId, '-OutputPath', $receiptPath) `
            -WorkingDirectory $ownedRoot -Environment @{} -TimeoutSeconds $TimeoutSeconds -CoreLifecycleOnly
        Write-Utf8NoBomCreateNew -Path (Join-Path $ownedRoot "setup-$toolName-process.json") -Text (($processResult | ConvertTo-Json -Depth 40) + [Environment]::NewLine)
        if ([string]$processResult.status -cne 'passed' -or [int]$processResult.exitCode -ne 0 -or -not [bool]$processResult.cleanedUp) {
            throw "Source tool setup '$toolName' failed with status '$($processResult.status)', exit $($processResult.exitCode), cleanup=$($processResult.cleanedUp)."
        }
        $receipt = Read-JsonFile -Path $receiptPath -Context "$toolName source resolver receipt"
        if ([string]$receipt.toolName -cne $toolName -or [string]$receipt.resolutionRunId -cne $runId -or
            [string]$receipt.channel -cne $(if ($toolName -ceq 'skillspector') { 'approved-source-registry' } else { 'latest-stable' }) -or $receipt.frozenForRun -isnot [bool] -or -not $receipt.frozenForRun -or
            [string]::IsNullOrWhiteSpace([string]$receipt.resolvedVersion) -or [string]::IsNullOrWhiteSpace([string]$receipt.resolvedIdentity)) {
            throw "Source resolver receipt '$toolName' is not bound to this exact setup run."
        }
        $receipts[$toolName] = $receipt
        $receiptBindings += [pscustomobject]@{ path = [IO.Path]::GetFullPath($receiptPath); sha256 = Get-FileSha256 -Path $receiptPath }
        $resolverTimer.Stop()
        $resolverStageSeconds[$toolName] = [Math]::Round($resolverTimer.Elapsed.TotalSeconds, 3)
    }

    $toolchain = [ordered]@{
        centralRunnerPath = $runner; centralRunnerSha256 = Get-FileSha256 -Path $runner
        upstreamAdapterValidatorPath = Join-Path $authority.root 'scripts/Validate-UpstreamAdapter.ps1'; upstreamAdapterValidatorSha256 = Get-FileSha256 -Path (Join-Path $authority.root 'scripts/Validate-UpstreamAdapter.ps1')
        upstreamPolicyPath = Join-Path $authority.root 'docs/standards/upstream-adapter.json'; upstreamPolicySha256 = Get-FileSha256 -Path (Join-Path $authority.root 'docs/standards/upstream-adapter.json')
        skillValidatorPath = [string]$receipts.'skill-validator'.executablePath; skillValidatorSha256 = [string]$receipts.'skill-validator'.executableSha256
        skillToolsNodePath = [string]$receipts.'skill-tools'.nodePath; skillToolsNodeSha256 = [string]$receipts.'skill-tools'.nodeSha256
        skillToolsEntryPointPath = [string]$receipts.'skill-tools'.entryPointPath; skillToolsEntryPointSha256 = [string]$receipts.'skill-tools'.entryPointSha256
        skillSpectorPath = [string]$receipts.skillspector.executablePath; skillSpectorSha256 = [string]$receipts.skillspector.executableSha256
        skillSpectorReceiptPath = [string]$receiptBindings[2].path; skillSpectorReceiptSha256 = [string]$receiptBindings[2].sha256
    }
    $toolchain.staticWrapperPath = Join-Path $authority.root 'scripts/Invoke-StandardStaticScan.ps1'
    $toolchain.staticWrapperSha256 = [string]$pin.files['scripts/Invoke-StandardStaticScan.ps1']
    $toolchain.staticResolutionRunId = $runId
    $gitVersionOutput = @(& $GitPath --version)
    if ($LASTEXITCODE -ne 0 -or $gitVersionOutput.Count -ne 1 -or [string]$gitVersionOutput[0] -cnotmatch '^git version (?<version>[0-9]+\.[0-9]+(?:\.[0-9]+)?)') { throw 'Could not bind Git for internal Skill use.' }
    $internalUse = [ordered]@{}
    foreach ($entry in $script:InternalSkillUse.GetEnumerator()) { $internalUse[$entry.Key] = $entry.Value }
    $internalUse.runnerPath = $runner
    $internalUse.runnerSha256 = [string]$pin.files['scripts/Invoke-StandardValidation.ps1']
    $internalUse.authorityFiles = @($pin.files.GetEnumerator() | ForEach-Object { [ordered]@{ path = [string]$_.Key; sha256 = [string]$_.Value } })
    $internalUse.toolInventory = @(
        [ordered]@{ id = 'powershell'; version = "$($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor).$($PSVersionTable.PSVersion.Patch)"; path = $powerShell; sha256 = Get-FileSha256 -Path $powerShell }
        [ordered]@{ id = 'git'; version = [string]$Matches.version; path = $GitPath; sha256 = Get-FileSha256 -Path $GitPath }
    )
    $toolchain.internalSkillUse = $internalUse
    foreach ($toolPath in @(
        [pscustomobject]@{ path = $toolchain.skillValidatorPath; sha = $toolchain.skillValidatorSha256 },
        [pscustomobject]@{ path = $toolchain.skillToolsNodePath; sha = $toolchain.skillToolsNodeSha256 },
        [pscustomobject]@{ path = $toolchain.skillToolsEntryPointPath; sha = $toolchain.skillToolsEntryPointSha256 },
        [pscustomobject]@{ path = $toolchain.skillSpectorPath; sha = $toolchain.skillSpectorSha256 }
    )) {
        Assert-NoReparseAncestors -Path ([string]$toolPath.path) -Context 'Resolved source tool'
        if ((Get-FileSha256 -Path ([string]$toolPath.path)) -cne [string]$toolPath.sha) { throw 'Resolved source tool changed after receipt creation.' }
    }
    $toolchainPath = Join-Path $ownedRoot 'toolchain.json'
    Write-Utf8NoBomCreateNew -Path $toolchainPath -Text (($toolchain | ConvertTo-Json -Depth 30) + [Environment]::NewLine)
    $toolchainSha256 = Get-FileSha256 -Path $toolchainPath
    $wrapperPath = Join-Path $ownedRoot 'Invoke-AtlassianValidationChild.ps1'
    Write-Utf8NoBomCreateNew -Path $wrapperPath -Text $childRunnerText
    $commonArguments = @('-NoProfile', '-NonInteractive', '-File', $wrapperPath, '-ToolchainPath', $toolchainPath,
        '-ToolchainSha256', $toolchainSha256, '-SourceRepository', $script:SourceRepository, '-SourceRevision', $CandidateRevision,
        '-ArchiveSha256', $archiveSha256, '-CoreSourceValidation')
    $sourceDispatch = [ordered]@{
        packageAdapter = [ordered]@{ command = $powerShell; arguments = @($commonArguments + @('-Mode', 'package-adapter')) }
        skillValidator = [ordered]@{ command = $powerShell; arguments = @($commonArguments + @('-Mode', 'skill-validator')) }
        skillTools = [ordered]@{ command = $powerShell; arguments = @($commonArguments + @('-Mode', 'skill-tools')) }
        staticAnalyzer = [ordered]@{ command = $powerShell; arguments = @($commonArguments + @('-Mode', 'static')) }
        frozenFiles = @(); toolReceipts = @($receiptBindings)
    }

    $lockSource = Join-Path (Split-Path -Parent $PSScriptRoot) 'config/pester-6.2.0-closure.lock.json'
    $prepareScript = Join-Path $PSScriptRoot 'Prepare-PesterRuntime.ps1'
    $integrityModule = Join-Path $PSScriptRoot 'CorePesterIntegrity.psm1'
    foreach ($path in @($lockSource, $prepareScript, $integrityModule)) { if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Protected Pester setup input is missing: $path" } }
    $lockPath = Join-Path $ownedRoot 'pester-6.2.0-closure.lock.json'
    Copy-Item -LiteralPath $lockSource -Destination $lockPath -ErrorAction Stop
    $lockHash = Get-FileSha256 -Path $lockPath
    $moduleRoot = Join-Path $runtimeRoot 'Modules/Pester/6.2.0'
    $moduleManifestPath = Join-Path $moduleRoot 'Pester.psd1'
    $setupReceiptPath = Join-Path $ownedRoot 'pester-setup/setup-receipt.json'
    $setupEnvironment = @{ STANDARD_VALIDATION_RUN_OWNED_ROOT = $ownedRoot }
    $pesterSetupTimer = [Diagnostics.Stopwatch]::StartNew()
    foreach ($inputName in @('powerShell', 'prepareScript', 'ownedRoot', 'moduleRoot', 'lockPath', 'setupReceiptPath', 'runId')) {
        $inputValue = Get-Variable -Name $inputName -ValueOnly -Scope Local
        if ($inputValue -isnot [string] -or [string]::IsNullOrWhiteSpace($inputValue)) {
            throw "Pester source setup requires a nonempty scalar string: `$$inputName."
        }
    }
    $setupResult = & (Get-Command -Name 'Invoke-StandardValidationProcess' -CommandType Function -ErrorAction Stop) -Command $powerShell -Arguments @('-NoProfile', '-NonInteractive', '-File', $prepareScript,
        '-RuntimeExecutable', $powerShell, '-OwnedRoot', $ownedRoot, '-ModuleRoot', $moduleRoot, '-LockPath', $lockPath,
        '-SetupReceiptPath', $setupReceiptPath, '-RunId', $runId) -WorkingDirectory $ownedRoot -Environment $setupEnvironment `
        -TimeoutSeconds $TimeoutSeconds -CoreLifecycleOnly
    Write-Utf8NoBomCreateNew -Path (Join-Path $ownedRoot 'pester-setup-process.json') -Text (($setupResult | ConvertTo-Json -Depth 40) + [Environment]::NewLine)
    if ([string]$setupResult.status -cne 'passed' -or [int]$setupResult.exitCode -ne 0 -or -not [bool]$setupResult.cleanedUp) {
        throw "Run-owned Pester setup failed with status '$($setupResult.status)', exit $($setupResult.exitCode), cleanup=$($setupResult.cleanedUp)."
    }
    $pesterReceipt = Read-JsonFile -Path $setupReceiptPath -Context 'Pester setup receipt'
    if ([string]$pesterReceipt.runId -cne $runId -or [string]$pesterReceipt.lockSha256 -cne $lockHash -or
        [string]$pesterReceipt.terminalStatus -cne 'verified' -or [string]$pesterReceipt.runtimeExecutable -cne $powerShell -or
        -not (Test-Path -LiteralPath $moduleManifestPath -PathType Leaf)) { throw 'Run-owned Pester setup receipt is incomplete or belongs to a different setup.' }
    $moduleRootFull = [IO.Path]::GetFullPath($moduleRoot)
    $pesterClosureFiles = @(Get-ChildItem -LiteralPath $moduleRootFull -Recurse -File -Force -ErrorAction Stop | ForEach-Object { $_.FullName })
    if ($pesterClosureFiles.Count -eq 0) { throw 'Run-owned Pester module closure is empty.' }
    foreach ($path in @($pesterClosureFiles)) { Assert-NoReparseAncestors -Path $path -Context 'Run-owned Pester closure' }
    $pesterSetupTimer.Stop()
    $setupStageSeconds.pesterRuntimeSetupAndInventorySeconds = [Math]::Round($pesterSetupTimer.Elapsed.TotalSeconds, 3)

    $protectedDispatchCopyRoot = Join-Path $runtimeRoot 'ProtectedSourceChecks'
    foreach ($binding in $protectedDispatchBindings) {
        $destination = Join-Path $protectedDispatchCopyRoot ([string]$binding.path)
        $destinationParent = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $destinationParent -Force -ErrorAction Stop)
        }
        Copy-Item -LiteralPath ([string]$binding.protectedPath) -Destination $destination -ErrorAction Stop
        if ((Get-FileSha256 -Path $destination) -cne [string]$binding.sha256) {
            throw "Protected Core dispatch copy changed during source setup: $($binding.path)"
        }
    }

    $inventoryTimer = [Diagnostics.Stopwatch]::StartNew()
    $runtimeFiles = @(Get-ChildItem -LiteralPath $runtimeRoot -Recurse -File -Force -ErrorAction Stop | ForEach-Object {
        if ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Run-owned PowerShell runtime contains a reparse point: $($_.FullName)" }
        [pscustomobject]@{ path = [IO.Path]::GetFullPath($_.FullName); sha256 = Get-FileSha256 -Path $_.FullName }
    })
    $runtimeInventoryPath = Join-Path $ownedRoot 'powershell-runtime-inventory.json'
    $runtimeInventory = [ordered]@{
        schemaVersion = 1
        root = $runtimeRoot
        executablePath = $powerShell
        executableSha256 = Get-FileSha256 -Path $powerShell
        files = @($runtimeFiles | Sort-Object -Property path -CaseSensitive)
    }
    Write-Utf8NoBomCreateNew -Path $runtimeInventoryPath -Text (($runtimeInventory | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
    $runtimeInventorySha256 = Get-FileSha256 -Path $runtimeInventoryPath
    $runtimeCopyFiles = @($runtimeFiles | ForEach-Object { [string]$_.path })
    $receiptFrozenPaths = @()
    foreach ($receipt in @($receipts.Values)) {
        $receiptFrozenPaths += @(Get-AtlassianSourceReceiptFrozenPaths -Receipt $receipt -OwnedRoot $ownedRoot)
    }
    $sourceFrozenFiles = New-AtlassianSourceFrozenFileInventory -RuntimeFiles $runtimeCopyFiles `
        -SourceFiles @($runtimeInventoryPath, $powerShell, $runner, $resolver, $policy, $toolchain.staticWrapperPath, $toolchain.upstreamAdapterValidatorPath,
            $toolchain.upstreamPolicyPath, $toolchainPath, $wrapperPath, $manifestPath, $archivePath, $lockPath,
            $sourceIdentityPath, $prepareScript, $integrityModule) `
        -PesterFiles (@($moduleManifestPath, $setupReceiptPath) + @($pesterClosureFiles)) `
        -ReceiptFiles (@($receiptFrozenPaths) + @($receiptBindings | ForEach-Object { [string]$_.path }) + @(
            [string]$toolchain.skillValidatorPath, [string]$toolchain.skillToolsNodePath,
            [string]$toolchain.skillToolsEntryPointPath, [string]$toolchain.skillSpectorPath))
    $inventoryTimer.Stop()
    $setupStageSeconds.closureInventoryHashAndSortSeconds = [Math]::Round($inventoryTimer.Elapsed.TotalSeconds, 3)
    $stageTimingCapturedAtUtc = [DateTimeOffset]::UtcNow
    $setupTimingPath = Join-Path $ownedRoot 'setup-timing.json'
    $setupTiming = [ordered]@{
        schemaVersion = 1
        runId = $runId
        startedAtUtc = $setupStartedAtUtc.ToString('O')
        stageTimingCapturedAtUtc = $stageTimingCapturedAtUtc.ToString('O')
        stageSeconds = $setupStageSeconds
        resolverSeconds = $resolverStageSeconds
        stageTimingBoundary = 'runtime copy, candidate manifest/archive, resolver, Pester setup, and first frozen-file inventory/hash/sort intervals only; excludes final verification and prepared metadata write'
    }
    Write-Utf8NoBomCreateNew -Path $setupTimingPath -Text (($setupTiming | ConvertTo-Json -Depth 30) + [Environment]::NewLine)
    $setupTimingRecord = [pscustomobject]@{
        path = [IO.Path]::GetFullPath($setupTimingPath)
        sha256 = Get-FileSha256 -Path $setupTimingPath
    }
    $frozenRecords = @($sourceFrozenFiles.files) + @($setupTimingRecord)
    $sourceDispatch.frozenFiles = @($frozenRecords | Sort-Object -Property path -CaseSensitive)
    $frozenFiles = @($sourceDispatch.frozenFiles)
    # Re-importing binds the same caller variables as the initial import.
    . $runner -DefineFunctionsOnly -CandidateRoot $RepositoryRoot -AdapterPath $preparedPath -ArtifactsRoot $setupRoot `
        -SourceRepository $script:SourceRepository -SourceRevision $CandidateRevision -BaseRevision $CandidateRevision -AuthorityRevision $pin.commit `
        -RunId $runId -TimeoutSeconds $TimeoutSeconds -TrustedToolRoot $trustedRoot
    & (Get-Command -Name 'Assert-StandardCoreFrozenFiles' -CommandType Function -ErrorAction Stop) -Files @($sourceDispatch.frozenFiles)
    & (Get-Command -Name 'Assert-StandardCoreSourceToolReceipts' -CommandType Function -ErrorAction Stop) -Bindings @($sourceDispatch.toolReceipts) -FrozenFiles @($sourceDispatch.frozenFiles) -RunId $runId -CandidateRoot $RepositoryRoot -ArtifactsRoot $setupRoot

    $prepared = [ordered]@{
        schemaVersion = 1; preparation = 'atlassian-source-tools'; runId = $runId
        sourceRevision = $CandidateRevision; authorityRevision = [string]$pin.commit; ownedRoot = $ownedRoot
        candidateArchivePath = $archivePath; candidateArchiveSha256 = $archiveSha256
        sourceValidation = $sourceDispatch
        pesterRuntime = [ordered]@{
            moduleManifestPath = [IO.Path]::GetFullPath($moduleManifestPath)
            closureLockPath = [IO.Path]::GetFullPath($lockPath)
            closureLockSha256 = $lockHash
            setupReceiptPath = [IO.Path]::GetFullPath($setupReceiptPath)
            setupReceiptSha256 = Get-FileSha256 -Path $setupReceiptPath
            runtimeRoot = [IO.Path]::GetFullPath($runtimeRoot)
            runtimeExecutablePath = [IO.Path]::GetFullPath($powerShell)
            runtimeExecutableSha256 = Get-FileSha256 -Path $powerShell
            runtimeInventoryPath = [IO.Path]::GetFullPath($runtimeInventoryPath)
            runtimeInventorySha256 = $runtimeInventorySha256
            sourceTrustedToolRoot = [IO.Path]::GetFullPath($trustedRoot)
        }
    }
    Write-Utf8NoBomCreateNew -Path $preparedPath -Text (($prepared | ConvertTo-Json -Depth 80) + [Environment]::NewLine)
    $setupTimer.Stop()
    $setupCompletedAtUtc = [DateTimeOffset]::UtcNow
    $setupCompletedTimingPath = Join-Path $setupRoot "source-tools-setup-completed-$runId.json"
    $setupCompletedTiming = [ordered]@{
        schemaVersion = 1
        runId = $runId
        setupStartedAtUtc = $setupStartedAtUtc.ToString('O')
        setupCompletedAtUtc = $setupCompletedAtUtc.ToString('O')
        setupTotalSeconds = [Math]::Round($setupTimer.Elapsed.TotalSeconds, 3)
        stageSeconds = $setupStageSeconds
        resolverSeconds = $resolverStageSeconds
        stageTimingPath = [IO.Path]::GetFullPath($setupTimingPath)
        stageTimingSha256 = Get-FileSha256 -Path $setupTimingPath
        diagnosticTargetSeconds = 1200
        diagnosticTargetExceeded = ($setupTimer.Elapsed.TotalSeconds -gt 1200)
        totalBoundary = 'after complete frozen-file verification and prepared metadata creation'
    }
    Write-Utf8NoBomCreateNew -Path $setupCompletedTimingPath -Text (($setupCompletedTiming | ConvertTo-Json -Depth 30) + [Environment]::NewLine)
    [Console]::Out.WriteLine("Prepared source validation tools for RunId $runId at $preparedPath")
    [Console]::Out.WriteLine("Source setup timing evidence: $setupCompletedTimingPath")
}

function Read-AtlassianSourcePreparedTools {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $CandidateRevision,
        [Parameter(Mandatory)][string] $PowerShellPath, [Parameter(Mandatory)][string] $AuthorityRoot,
        [Parameter(Mandatory)] $AuthorityPin, [Parameter(Mandatory)][string] $CandidateRoot,
        [Parameter(Mandatory)][string] $ProtectedBaseRoot)

    $prepared = Read-JsonFile -Path $Path -Context 'Prepared Atlassian source tools'
    [void](Assert-AtlassianSourcePreparedBindings -Prepared $prepared -PreparedPath $Path -CandidateRevision $CandidateRevision -PowerShellPath $PowerShellPath -SourceRepository $script:SourceRepository)
    $ownedRoot = [IO.Path]::GetFullPath([string]$prepared.ownedRoot)
    $manifestPath = Join-Path $ownedRoot 'candidate-git-entry-modes.json'
    $manifestBindings = @($prepared.sourceValidation.frozenFiles | Where-Object { (Test-PathEqual -Left ([string]$_.path) -Right $manifestPath) })
    if ($manifestBindings.Count -ne 1 -or (Get-FileSha256 -Path $manifestPath) -cne [string]$manifestBindings[0].sha256) {
        throw 'Prepared candidate Git entry mode manifest is missing or changed.'
    }
    $candidateManifest = Read-JsonFile -Path $manifestPath -Context 'Prepared candidate Git entry mode manifest'
    $identityPath = Join-Path $ownedRoot 'source-run-identity.json'
    $identityBindings = @($prepared.sourceValidation.frozenFiles | Where-Object { (Test-PathEqual -Left ([string]$_.path) -Right $identityPath) })
    if ($identityBindings.Count -ne 1 -or (Get-FileSha256 -Path $identityPath) -cne [string]$identityBindings[0].sha256) {
        throw 'Prepared source run identity receipt is missing or changed.'
    }
    $sourceIdentity = Read-JsonFile -Path $identityPath -Context 'Prepared source run identity receipt'
    if ([int]$sourceIdentity.schemaVersion -ne 1 -or [string]$sourceIdentity.runId -cne [string]$prepared.runId -or
        [string]$sourceIdentity.sourceRevision -cne $CandidateRevision -or [string]$sourceIdentity.authorityRevision -cne [string]$AuthorityPin.commit -or
        -not (Test-PathEqual -Left ([string]$sourceIdentity.candidateManifestPath) -Right $manifestPath) -or
        [string]$sourceIdentity.candidateManifestSha256 -cne [string]$manifestBindings[0].sha256 -or
        -not (Test-PathEqual -Left ([string]$sourceIdentity.candidateArchivePath) -Right ([string]$prepared.candidateArchivePath)) -or
        [string]$sourceIdentity.candidateArchiveSha256 -cne [string]$prepared.candidateArchiveSha256) {
        throw 'Prepared source run identity does not bind the exact source, authority, manifest, archive and RunId.'
    }
    $protectedDispatchBindings = @(Assert-AtlassianSourceProtectedRuntimeCopies -ProtectedBaseRoot $ProtectedBaseRoot `
        -CandidateRoot $CandidateRoot -OwnedRoot $ownedRoot -ManifestEntries @($candidateManifest.entries) `
        -FrozenFiles @($prepared.sourceValidation.frozenFiles))
    $wrapperPath = Join-Path $ownedRoot 'Invoke-AtlassianValidationChild.ps1'
    $expectedWrapperHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($childRunnerText))).ToLowerInvariant()
    if ((Get-FileSha256 -Path $wrapperPath) -cne $expectedWrapperHash) { throw 'Prepared source child wrapper differs from the protected event-base driver.' }
    $toolchainPath = Join-Path $ownedRoot 'toolchain.json'
    if (-not (Test-Path -LiteralPath $toolchainPath -PathType Leaf)) { throw 'Prepared source toolchain is missing.' }
    $toolchainBindings = @($prepared.sourceValidation.frozenFiles | Where-Object { (Test-PathEqual -Left ([string]$_.path) -Right $toolchainPath) })
    if ($toolchainBindings.Count -ne 1 -or (Get-FileSha256 -Path $toolchainPath) -cne [string]$toolchainBindings[0].sha256) { throw 'Prepared source toolchain is not frozen.' }
    $toolchain = Read-JsonFile -Path $toolchainPath -Context 'Prepared source toolchain'
    [void](Assert-AtlassianSourceAuthorityToolchain -Toolchain $toolchain -AuthorityRoot $AuthorityRoot -AuthorityPin $AuthorityPin)
    if ([string]$toolchain.staticResolutionRunId -cne [string]$prepared.runId -or [string]$toolchain.internalSkillUse.runnerSha256 -cne [string]$AuthorityPin.files['scripts/Invoke-StandardValidation.ps1']) { throw 'Prepared correction/internal-use toolchain differs from its exact setup and authority.' }
    $staticWrapperBinding = @($prepared.sourceValidation.frozenFiles | Where-Object { [string]$_.path -ceq [string]$toolchain.staticWrapperPath -and [string]$_.sha256 -ceq [string]$toolchain.staticWrapperSha256 })
    if ($staticWrapperBinding.Count -ne 1) { throw 'Prepared correction wrapper is not frozen exactly once.' }
    foreach ($binding in @(
        [pscustomobject]@{ path = [string]$toolchain.centralRunnerPath; sha = [string]$toolchain.centralRunnerSha256; expected = 'scripts/Invoke-StandardValidation.ps1' },
        [pscustomobject]@{ path = [string]$toolchain.upstreamAdapterValidatorPath; sha = [string]$toolchain.upstreamAdapterValidatorSha256; expected = 'scripts/Validate-UpstreamAdapter.ps1' },
        [pscustomobject]@{ path = [string]$toolchain.upstreamPolicyPath; sha = [string]$toolchain.upstreamPolicySha256; expected = 'docs/standards/upstream-adapter.json' }
    )) {
        $frozen = @($prepared.sourceValidation.frozenFiles | Where-Object { (Test-PathEqual -Left ([string]$_.path) -Right $binding.path) -and [string]$_.sha256 -ceq $binding.sha })
        if ($frozen.Count -ne 1 -or (Get-FileSha256 -Path $binding.path) -cne $binding.sha) { throw "Prepared authority toolchain file is not frozen: $($binding.expected)" }
    }
    if ((Get-FileSha256 -Path ([string]$prepared.candidateArchivePath)) -cne [string]$prepared.candidateArchiveSha256) { throw 'Prepared candidate archive changed.' }
    return $prepared
}

function Invoke-AtlassianSourceValidation {
    param([Parameter(Mandatory)][string] $GitPath, [Parameter(Mandatory)][string] $PowerShellPath,
        [Parameter(Mandatory)][string] $RepositoryRoot, [Parameter(Mandatory)][string] $CandidateRevision,
        [Parameter(Mandatory)][string] $BaseRevision, [Parameter(Mandatory)] $AuthorityConfig,
        [Parameter(Mandatory)][string] $SourceToolsPath, [Parameter(Mandatory)][string] $AuthorityRepositoryRoot,
        [string] $TrustedToolRoot, [Parameter(Mandatory)][string] $ArtifactsRoot, [string] $OutputPath,
        [Parameter(Mandatory)][string] $EventName, [Parameter(Mandatory)][int] $TimeoutSeconds,
        [bool] $ArtifactsRootWasExplicit = $true, [string] $CancellationPath)

    $sourceValidationStartedAtUtc = [DateTimeOffset]::UtcNow
    $sourceValidationTimer = [Diagnostics.Stopwatch]::StartNew()
    $centralRunnerSeconds = 0.0
    $cleanupErrorMessage = $null
    $sourceReportAccepted = $false
    $pin = Assert-AtlassianSourceAuthorityConfig -Config $AuthorityConfig
    $authority = Assert-AtlassianSourceAuthorityCheckout -GitPath $GitPath -AuthorityRoot $AuthorityRepositoryRoot -AuthorityPin $pin
    $preparedPath = [IO.Path]::GetFullPath($SourceToolsPath)
    $preparedHint = Read-JsonFile -Path $preparedPath -Context 'Prepared Atlassian source tools'
    $powerShell = [IO.Path]::GetFullPath([string]$preparedHint.pesterRuntime.runtimeExecutablePath)
    $trustedRoot = [IO.Path]::GetFullPath([string]$preparedHint.pesterRuntime.runtimeRoot)
    if (-not [string]::IsNullOrWhiteSpace($TrustedToolRoot) -and
        -not [IO.Path]::GetFullPath($TrustedToolRoot).Equals([IO.Path]::GetFullPath([string]$preparedHint.pesterRuntime.sourceTrustedToolRoot), $(if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }))) {
        throw 'SourceValidation TrustedToolRoot differs from the exact root recorded during source setup.'
    }
    if (-not (Test-Path -LiteralPath $powerShell -PathType Leaf) -or
        (Get-FileSha256 -Path $powerShell) -cne [string]$preparedHint.pesterRuntime.runtimeExecutableSha256) {
        throw 'Prepared run-owned PowerShell executable is missing or changed.'
    }
    if (-not [IO.Path]::GetFullPath($PowerShellPath).Equals($powerShell, $(if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }))) {
        throw 'SourceValidation PowerShell path differs from the exact prepared run-owned executable.'
    }
    if (-not (Test-Path -LiteralPath $trustedRoot -PathType Container) -or -not (Test-PathWithinOrEqual -Path $powerShell -Root $trustedRoot)) {
        throw 'Source validation PowerShell must be within the verified TrustedToolRoot.'
    }
    Assert-NoReparseAncestors -Path $trustedRoot -Context 'Source validation TrustedToolRoot'
    Assert-OutsideRoot -Path $trustedRoot -Root $RepositoryRoot -Context 'TrustedToolRoot'
    Assert-OutsideRoot -Path $trustedRoot -Root $authority.root -Context 'TrustedToolRoot'
    $preparedRoot = [IO.Path]::GetFullPath((Split-Path -Parent $preparedPath))
    Assert-OutsideRoot -Path $preparedRoot -Root $RepositoryRoot -Context 'Prepared source root'
    Assert-OutsideRoot -Path $preparedRoot -Root $authority.root -Context 'Prepared source root'
    Assert-OutsideRoot -Path $preparedRoot -Root $trustedRoot -Context 'Prepared source root'
    $script:SourceInvalidInput = $true
    $prepared = Read-AtlassianSourcePreparedTools -Path $preparedPath -CandidateRevision $CandidateRevision -PowerShellPath $powerShell `
        -AuthorityRoot $authority.root -AuthorityPin $pin -CandidateRoot $RepositoryRoot `
        -ProtectedBaseRoot ([IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)))
    if ([string]$prepared.authorityRevision -cne [string]$pin.commit) { throw 'Prepared source tools do not bind the exact 3c55daa authority revision.' }
    $setupTimingPath = Join-Path ([string]$prepared.ownedRoot) 'setup-timing.json'
    $setupTimingBinding = @($prepared.sourceValidation.frozenFiles | Where-Object {
        (Test-PathEqual -Left ([string]$_.path) -Right $setupTimingPath)
    })
    if ($setupTimingBinding.Count -ne 1 -or (Get-FileSha256 -Path $setupTimingPath) -cne [string]$setupTimingBinding[0].sha256) {
        throw 'Prepared source setup timing evidence is missing or changed.'
    }
    $setupTiming = Read-JsonFile -Path $setupTimingPath -Context 'Prepared source setup timing evidence'
    if ([int]$setupTiming.schemaVersion -ne 1 -or [string]$setupTiming.runId -cne [string]$prepared.runId -or
        [string]$setupTiming.startedAtUtc -cnotmatch '^\d{4}-\d{2}-\d{2}T' -or
        [string]$setupTiming.stageTimingCapturedAtUtc -cnotmatch '^\d{4}-\d{2}-\d{2}T' -or
        $setupTiming.stageSeconds -isnot [pscustomobject] -or [string]::IsNullOrWhiteSpace([string]$setupTiming.stageTimingBoundary)) {
        throw 'Prepared source setup timing evidence is invalid or belongs to a different run.'
    }
    $setupCompletedTimingPath = Join-Path (Split-Path -Parent $preparedPath) "source-tools-setup-completed-$($prepared.runId).json"
    if (-not (Test-Path -LiteralPath $setupCompletedTimingPath -PathType Leaf)) { throw 'Completed source setup timing evidence is missing.' }
    $setupCompletedTimingSha256 = Get-FileSha256 -Path $setupCompletedTimingPath
    $setupCompletedTiming = Read-JsonFile -Path $setupCompletedTimingPath -Context 'Completed source setup timing evidence'
    if ([int]$setupCompletedTiming.schemaVersion -ne 1 -or [string]$setupCompletedTiming.runId -cne [string]$prepared.runId -or
        [string]$setupCompletedTiming.setupStartedAtUtc -cne [string]$setupTiming.startedAtUtc -or
        [double]$setupCompletedTiming.setupTotalSeconds -lt 0 -or [int]$setupCompletedTiming.diagnosticTargetSeconds -ne 1200 -or
        [string]$setupCompletedTiming.totalBoundary -cne 'after complete frozen-file verification and prepared metadata creation') {
        throw 'Completed source setup timing evidence is invalid or belongs to a different run.'
    }
    $script:SourceInvalidInput = $false

    $artifactsRootPath = [IO.Path]::GetFullPath($ArtifactsRoot)
    Assert-OutsideRoot -Path $artifactsRootPath -Root $RepositoryRoot -Context 'Source Core ArtifactsRoot'
    Assert-OutsideRoot -Path $artifactsRootPath -Root $authority.root -Context 'Source Core ArtifactsRoot'
    Assert-OutsideRoot -Path $artifactsRootPath -Root $trustedRoot -Context 'Source Core ArtifactsRoot'
    Assert-OutsideRoot -Path $artifactsRootPath -Root ([string]$prepared.ownedRoot) -Context 'Source Core ArtifactsRoot'
    $paths = Get-AtlassianSourceCoreRunPaths -ArtifactsRoot $artifactsRootPath -ArtifactsRootWasExplicit $ArtifactsRootWasExplicit `
        -RunId ([string]$prepared.runId) -OutputPath $OutputPath
    foreach ($root in @($paths.artifactsRoot, $paths.adapterRoot)) {
        Assert-OutsideRoot -Path $root -Root $RepositoryRoot -Context 'Source Core run-owned root'
        Assert-OutsideRoot -Path $root -Root $authority.root -Context 'Source Core run-owned root'
        Assert-OutsideRoot -Path $root -Root $trustedRoot -Context 'Source Core run-owned root'
        Assert-OutsideRoot -Path $root -Root ([string]$prepared.ownedRoot) -Context 'Source Core run-owned root'
    }
    Assert-OutsideRoot -Path $paths.adapterRoot -Root $paths.artifactsRoot -Context 'Source Core adapter root'
    if (-not (Test-Path -LiteralPath $paths.artifactsRoot -PathType Container)) { [void](New-Item -ItemType Directory -Path $paths.artifactsRoot -Force -ErrorAction Stop) }
    elseif (-not $ArtifactsRootWasExplicit) { throw 'Default Source Core ArtifactsRoot unexpectedly exists; run-owned paths are create-only.' }
    Assert-NoReparseAncestors -Path $paths.artifactsRoot -Context 'Source Core ArtifactsRoot'
    Assert-PathWithinRoot -Path $paths.outputPath -Root $paths.artifactsRoot -Context 'Source Core OutputPath' | Out-Null
    if (Test-Path -LiteralPath $paths.outputPath) { throw "Source Core output evidence already exists: $($paths.outputPath)" }
    if (Test-Path -LiteralPath $paths.adapterRoot) { throw 'Source Core adapter sibling path already exists.' }
    [void](New-Item -ItemType Directory -Path $paths.adapterRoot -ErrorAction Stop)
    $adapterRootCreated = $true
    $cleanupSucceeded = $false
    $processExitCode = 1
    $previousTestValidateSource = [Environment]::GetEnvironmentVariable('SYP482_TEST_VALIDATE_SOURCE', 'Process')
    try {
        Assert-NoReparseAncestors -Path $paths.adapterRoot -Context 'Source Core adapter root'
        $authoritySnapshot = New-AtlassianSourceAuthoritySnapshot -GitPath $GitPath -SourceRoot $authority.root -OwnedRoot $paths.adapterRoot -AuthorityPin $pin
        $manifestBinding = @($prepared.sourceValidation.frozenFiles | Where-Object {
            [IO.Path]::GetFullPath([string]$_.path).Equals([IO.Path]::GetFullPath((Join-Path ([string]$prepared.ownedRoot) 'candidate-git-entry-modes.json')), $(if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }))
        })
        if ($manifestBinding.Count -ne 1) { throw 'Prepared source Git entry manifest does not have one exact frozen binding.' }
        $adapter = New-AtlassianCoreAdapterV2 -PowerShellPath $powerShell -TrustedToolRoot $trustedRoot `
            -CandidateAuthorityAdapterRunId ([string]$prepared.runId) -CandidateRevision $CandidateRevision `
            -CandidateGitEntryModeManifestPath ([string]$manifestBinding[0].path) -CandidateGitEntryModeManifestSha256 ([string]$manifestBinding[0].sha256) `
            -ActiveSkillIds (Get-ActiveSkillIds -Root $RepositoryRoot) -SourceValidation $prepared.sourceValidation -PesterRuntime $prepared.pesterRuntime
        Write-Utf8NoBomCreateNew -Path $paths.adapterPath -Text (($adapter | ConvertTo-Json -Depth 80) + [Environment]::NewLine)
        $adapterSha = Get-FileSha256 -Path $paths.adapterPath
        $centralRunner = [IO.Path]::GetFullPath($authoritySnapshot.runnerPath)
        if ((Get-FileSha256 -Path $centralRunner) -cne [string]$pin.files['scripts/Invoke-StandardValidation.ps1']) { throw 'Run-owned protected Standard Core runner changed.' }
        $arguments = @('-CandidateRoot', $RepositoryRoot, '-AdapterPath', $paths.adapterPath, '-ArtifactsRoot', $paths.artifactsRoot,
            '-OutputPath', $paths.outputPath, '-SourceRepository', $script:SourceRepository, '-SourceRevision', $CandidateRevision,
            '-BaseRevision', $BaseRevision, '-EventName', $EventName, '-AuthorityRevision', [string]$pin.commit,
            '-TimeoutSeconds', [string]$TimeoutSeconds, '-TrustedToolRoot', $trustedRoot, '-SourceValidation', '-RunId', [string]$prepared.runId)
        if (-not [string]::IsNullOrWhiteSpace($CancellationPath)) { $arguments += @('-CancellationPath', [IO.Path]::GetFullPath($CancellationPath)) }
        # The canonical source child inherits this test-only variable. Clear any
        # developer override so CommonToolReportIntegration resolves Validate.ps1
        # from the immutable candidate snapshot under the protected Core run root.
        [Environment]::SetEnvironmentVariable('SYP482_TEST_VALIDATE_SOURCE', $null, 'Process')
        $centralRunnerTimer = [Diagnostics.Stopwatch]::StartNew()
        try {
            $runnerOutput = @(& $powerShell -NoProfile -NonInteractive -File $centralRunner @arguments 2>&1)
            $processExitCode = $LASTEXITCODE
        }
        finally {
            $centralRunnerTimer.Stop()
            $centralRunnerSeconds = [Math]::Round($centralRunnerTimer.Elapsed.TotalSeconds, 3)
        }
        $runnerOutput | Out-Host
        if ($processExitCode -eq 0) {
            . $centralRunner -DefineFunctionsOnly -CandidateRoot $RepositoryRoot -AdapterPath $paths.adapterPath -ArtifactsRoot $paths.artifactsRoot `
                -OutputPath $paths.outputPath -SourceRepository $script:SourceRepository -SourceRevision $CandidateRevision `
                -BaseRevision $BaseRevision -EventName $EventName -AuthorityRevision ([string]$pin.commit) -RunId ([string]$prepared.runId) `
                -SourceValidation -TrustedToolRoot $trustedRoot -TimeoutSeconds $TimeoutSeconds -CancellationPath $CancellationPath
            $report = Read-JsonFile -Path $paths.outputPath -Context 'Standard Core SourceValidation report'
            $securityPolicy = Read-JsonFile -Path (Join-Path $authoritySnapshot.root 'docs/standards/validation-security-gate.json') -Context 'source validation security policy'
            $platformPolicy = @($securityPolicy.stages | Where-Object { [string]$_.id -ceq 'skillspector-static' })[0].platformUnavailableException
            [void](& (Get-Command -Name 'Assert-StandardCoreSourceCheckReport' -CommandType Function -ErrorAction Stop) -ValidationSecurityPolicy $platformPolicy -Report $report -ExpectedSourceRevision $CandidateRevision -ExpectedBaseRevision $BaseRevision `
                -ExpectedAuthorityRevision ([string]$pin.commit) -ExpectedEventName $EventName -ArtifactsRoot $paths.artifactsRoot `
                -OutputPath $paths.outputPath -ProcessExitCode $processExitCode)
            [void](Assert-AtlassianSourceReportBinding -Report $report -Prepared $prepared -CandidateRevision $CandidateRevision `
                -BaseRevision $BaseRevision -AuthorityRevision ([string]$pin.commit) -EventName $EventName -ArtifactsRoot $paths.artifactsRoot `
                -OutputPath $paths.outputPath -ProcessExitCode $processExitCode -CleanupSucceeded $true `
                -CancellationRequested ([bool](-not [string]::IsNullOrWhiteSpace($CancellationPath) -and (Test-Path -LiteralPath $CancellationPath))))
            $sourceReportAccepted = $true
        }
    }
    finally {
        [Environment]::SetEnvironmentVariable('SYP482_TEST_VALIDATE_SOURCE', $previousTestValidateSource, 'Process')
        if ($adapterRootCreated -and (Test-Path -LiteralPath $paths.adapterRoot -PathType Container)) {
            try {
                $expectedAdapterRoot = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $paths.artifactsRoot) ".core-v2-adapter-$($prepared.runId)"))
                if (-not (Test-PathEqual -Left $paths.adapterRoot -Right $expectedAdapterRoot) -or
                    -not (Test-PathWithinOrEqual -Path $paths.adapterRoot -Root (Split-Path -Parent $paths.artifactsRoot)) -or
                    (Test-PathWithinOrEqual -Path $paths.adapterRoot -Root $paths.artifactsRoot)) { throw 'Source Core adapter cleanup escaped its unique sibling boundary.' }
                Assert-NoReparseAncestors -Path $paths.adapterRoot -Context 'Source Core adapter cleanup root'
                Remove-Item -LiteralPath $paths.adapterRoot -Recurse -Force -ErrorAction Stop
                if (Test-Path -LiteralPath $paths.adapterRoot) { throw 'Source Core adapter cleanup failed.' }
                $cleanupSucceeded = $true
            }
            catch {
                $script:SourceCleanupFailed = $true
                $cleanupErrorMessage = $_.Exception.Message
            }
        }
        $sourceValidationTimer.Stop()
        $sourceValidationCompletedAtUtc = [DateTimeOffset]::UtcNow
        $combinedWallSeconds = [Math]::Round(($sourceValidationCompletedAtUtc - [DateTimeOffset]::Parse([string]$setupTiming.startedAtUtc)).TotalSeconds, 3)
        $timingRoot = Split-Path -Parent $paths.artifactsRoot
        $sourceTimingPath = Join-Path $timingRoot "source-validation-timing-$($prepared.runId).json"
        $timingEvidence = [ordered]@{
            schemaVersion = 1
            runId = [string]$prepared.runId
            candidateRevision = $CandidateRevision
            baseRevision = $BaseRevision
            authorityRevision = [string]$pin.commit
            setupTimingPath = [IO.Path]::GetFullPath($setupTimingPath)
            setupTimingSha256 = [string]$setupTimingBinding[0].sha256
            setupCompletedTimingPath = [IO.Path]::GetFullPath($setupCompletedTimingPath)
            setupCompletedTimingSha256 = $setupCompletedTimingSha256
            setupTotalSeconds = [double]$setupCompletedTiming.setupTotalSeconds
            sourceValidationStartedAtUtc = $sourceValidationStartedAtUtc.ToString('O')
            sourceValidationCompletedAtUtc = $sourceValidationCompletedAtUtc.ToString('O')
            sourceValidationTotalSeconds = [Math]::Round($sourceValidationTimer.Elapsed.TotalSeconds, 3)
            centralRunnerSeconds = $centralRunnerSeconds
            combinedSetupToValidationSeconds = $combinedWallSeconds
            diagnosticTargetSeconds = 1200
            diagnosticTargetExceeded = ($combinedWallSeconds -gt 1200)
            processExitCode = $processExitCode
            reportAccepted = $sourceReportAccepted
            cleanupSucceeded = $cleanupSucceeded
        }
        try {
            Assert-OutsideRoot -Path $sourceTimingPath -Root $RepositoryRoot -Context 'Source timing evidence'
            Assert-OutsideRoot -Path $sourceTimingPath -Root $authority.root -Context 'Source timing evidence'
            Assert-NoReparseAncestors -Path $timingRoot -Context 'Source timing evidence root'
            Write-Utf8NoBomCreateNew -Path $sourceTimingPath -Text (($timingEvidence | ConvertTo-Json -Depth 30) + [Environment]::NewLine)
            [Console]::Out.WriteLine("Source timing evidence: $sourceTimingPath")
        }
        catch {
            if ($null -eq $cleanupErrorMessage) { $cleanupErrorMessage = "Could not retain source timing evidence: $($_.Exception.Message)" }
        }
        if ($null -ne $cleanupErrorMessage) { throw "SOURCE_CLEANUP| $cleanupErrorMessage" }
    }
    if ($processExitCode -eq 0 -and -not $cleanupSucceeded) { throw 'Source Core adapter cleanup status is not complete.' }
    if ($processExitCode -ne 0 -and (Test-Path -LiteralPath $paths.outputPath -PathType Leaf)) {
        [Console]::Error.WriteLine("Source Core report retained for failed process exit $($processExitCode): $($paths.outputPath)")
    }
    $script:ValidationExitCode = $processExitCode
    if ($processExitCode -ne 0) { exit $processExitCode }
    [Console]::Out.WriteLine("SourceValidation PASS: $($paths.outputPath) (RunId $($prepared.runId), adapter sha256 $adapterSha)")
}


function New-AtlassianSourceStandardValidationModule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $RunnerPath,
        [Parameter(Mandatory = $true)][string] $RunnerSha256,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary] $RunnerArguments,
        [switch] $SourceValidation
    )

    $runnerFullPath = [IO.Path]::GetFullPath($RunnerPath)
    if (-not [IO.Path]::IsPathRooted($RunnerPath) -or -not (Test-Path -LiteralPath $runnerFullPath -PathType Leaf)) {
        throw 'The protected Standard Core runner must be an existing absolute file.'
    }
    if ($RunnerSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'The protected Standard Core runner hash is invalid.' }
    if ((Get-FileHash -LiteralPath $runnerFullPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $RunnerSha256) {
        throw 'The protected Standard Core runner differs from its verified authority hash.'
    }

    $allowedNames = @(
        'CandidateRoot', 'AdapterPath', 'ArtifactsRoot', 'OutputPath', 'SourceRepository',
        'SourceRevision', 'BaseRevision', 'EventName', 'RunId', 'AuthorityRevision',
        'TimeoutSeconds', 'CancellationPath', 'TrustedToolRoot'
    )
    $requiredNames = @(
        'CandidateRoot', 'AdapterPath', 'ArtifactsRoot', 'OutputPath', 'SourceRepository',
        'SourceRevision', 'BaseRevision', 'EventName', 'RunId', 'AuthorityRevision',
        'TimeoutSeconds', 'CancellationPath', 'TrustedToolRoot'
    )
    $argumentNames = @($RunnerArguments.Keys | ForEach-Object { [string]$_ })
    foreach ($name in $argumentNames) {
        if ($name -cnotin $allowedNames) { throw "Unsupported protected Standard Core runner argument '$name'." }
    }
    foreach ($name in $requiredNames) {
        if (-not $RunnerArguments.Contains($name)) { throw "Protected Standard Core runner context is missing '$name'." }
    }
    foreach ($name in @('CandidateRoot', 'AdapterPath', 'ArtifactsRoot', 'TrustedToolRoot')) {
        $value = [string]$RunnerArguments[$name]
        if ([string]::IsNullOrWhiteSpace($value) -or -not [IO.Path]::IsPathRooted($value)) {
            throw "Protected Standard Core runner context '$name' must be an absolute path."
        }
    }
    foreach ($name in @('OutputPath', 'CancellationPath')) {
        $value = [string]$RunnerArguments[$name]
        if (-not [string]::IsNullOrWhiteSpace($value) -and -not [IO.Path]::IsPathRooted($value)) {
            throw "Protected Standard Core runner context '$name' must be empty or an absolute path."
        }
    }
    foreach ($name in @('SourceRepository', 'SourceRevision', 'BaseRevision', 'RunId', 'AuthorityRevision')) {
        if ([string]::IsNullOrWhiteSpace([string]$RunnerArguments[$name])) {
            throw "Protected Standard Core runner context '$name' must be nonempty."
        }
    }
    foreach ($name in @('SourceRevision', 'BaseRevision', 'AuthorityRevision')) {
        if ([string]$RunnerArguments[$name] -cnotmatch '^[0-9a-f]{40}$') {
            throw "Protected Standard Core runner context '$name' is not a canonical revision."
        }
    }
    if ([string]$RunnerArguments['RunId'] -cnotmatch '^[0-9a-f]{32}$') { throw 'Protected Standard Core runner RunId is invalid.' }
    if ([string]$RunnerArguments['EventName'] -cnotin @('local', 'pre-push', 'pull_request', 'push', 'workflow_dispatch')) {
        throw 'Protected Standard Core runner event is unsupported.'
    }
    if ([int]$RunnerArguments['TimeoutSeconds'] -le 0) { throw 'Protected Standard Core runner timeout must be positive.' }

    $importArguments = [ordered]@{}
    foreach ($name in $argumentNames) { $importArguments[$name] = $RunnerArguments[$name] }
    $importArguments['DefineFunctionsOnly'] = $true
    if ($SourceValidation) {
        $runnerTokens = $null
        $runnerErrors = $null
        $runnerAst = [Management.Automation.Language.Parser]::ParseFile($runnerFullPath, [ref]$runnerTokens, [ref]$runnerErrors)
        if ($runnerErrors.Count -ne 0 -or @($runnerAst.ParamBlock.Parameters | Where-Object {
            ([string]$_.Name.VariablePath.UserPath) -ceq 'SourceValidation'
        }).Count -ne 1) {
            throw 'The protected Standard Core runner does not expose the SourceValidation contract.'
        }
        $importArguments['SourceValidation'] = $true
    }

    $moduleName = 'AtlassianSourceStandardValidation_' + [guid]::NewGuid().ToString('N')
    $moduleArguments = @($runnerFullPath, $importArguments)
    $module = New-Module -Name $moduleName -ArgumentList $moduleArguments -ScriptBlock {
        param([string] $__runnerPath, [System.Collections.IDictionary] $__runnerArguments)
        . $__runnerPath @__runnerArguments
        Export-ModuleMember -Function @() -Cmdlet @() -Alias @() -Variable @()
    }
    if ($module -isnot [System.Management.Automation.PSModuleInfo] -or $module.Name -cne $moduleName) {
        throw 'Could not create an isolated Standard Core runner module.'
    }
    return $module
}

function Invoke-AtlassianSourceStandardValidationModule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.PSModuleInfo] $Module,
        [Parameter(Mandatory = $true)][string] $FunctionName,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary] $Arguments
    )

    $allowedFunctions = @(
        'Invoke-StandardValidationProcess', 'Assert-StandardCoreFrozenFiles',
        'Assert-StandardCoreSourceToolReceipts', 'Assert-StandardCoreSourceCheckReport',
        'Get-StandardCoreSourceToolGroups'
    )
    if ($FunctionName -cnotin $allowedFunctions) { throw "Protected Standard Core operation '$FunctionName' is not allowed." }
    $moduleInvoker = {
        param([string] $Name, [System.Collections.IDictionary] $BoundArguments)
        $command = Get-Command -Name $Name -CommandType Function -ErrorAction Stop
        $currentModule = [string]$ExecutionContext.SessionState.Module.Name
        if ([string]::IsNullOrWhiteSpace($currentModule) -or [string]$command.ModuleName -cne $currentModule) {
            throw 'Protected Standard Core operation is not owned by its isolated runner module.'
        }
        foreach ($argumentName in $BoundArguments.Keys) {
            if (-not $command.Parameters.ContainsKey([string]$argumentName)) {
                throw "Protected Standard Core operation '$Name' does not accept argument '$argumentName'."
            }
        }
        & $command @BoundArguments
    }
    return & $Module $moduleInvoker $FunctionName $Arguments
}

function Get-AtlassianSourceResidentRetainedApiContract {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Management.Automation.PSModuleInfo] $Module)

    $ownedCommand = & $Module {
        $ownerName = [string]$ExecutionContext.SessionState.Module.Name
        $command = Get-Command -Name 'Assert-StandardCoreSourceToolReceipts' -CommandType Function -ErrorAction SilentlyContinue |
            Select-Object -First 1
        $frozenCommand = Get-Command -Name 'Assert-StandardCoreFrozenFiles' -CommandType Function -ErrorAction SilentlyContinue |
            Select-Object -First 1
        [pscustomobject]@{
            moduleName = $ownerName
            commandModuleName = if ($null -eq $command) { $null } else { [string]$command.ModuleName }
            commandFound = ($null -ne $command)
            scriptFile = if ($null -eq $command -or $null -eq $command.ScriptBlock) { $null } else { [string]$command.ScriptBlock.File }
            parameterNames = if ($null -eq $command) { @() } else { @($command.Parameters.Keys | ForEach-Object { [string]$_ }) }
            frozenCommandModuleName = if ($null -eq $frozenCommand) { $null } else { [string]$frozenCommand.ModuleName }
            frozenCommandFound = ($null -ne $frozenCommand)
            runnerScriptFile = if ($null -eq $frozenCommand -or $null -eq $frozenCommand.ScriptBlock) { $null } else { [string]$frozenCommand.ScriptBlock.File }
        }
    }

    $requiredParameters = @('RetainedReceiptMap', 'ToolNames', 'AdditionalPaths', 'ReturnReceiptMap')
    $parameterNames = @($ownedCommand.parameterNames | ForEach-Object { [string]$_ })
    $missingParameters = @($requiredParameters | Where-Object { $parameterNames -cnotcontains $_ })
    $commandIsOwned = [bool]$ownedCommand.commandFound -and
        [string]$ownedCommand.commandModuleName -ceq [string]$ownedCommand.moduleName
    $frozenCommandIsOwned = [bool]$ownedCommand.frozenCommandFound -and
        [string]$ownedCommand.frozenCommandModuleName -ceq [string]$ownedCommand.moduleName
    return [pscustomobject]@{
        supported = ($commandIsOwned -and $frozenCommandIsOwned -and $missingParameters.Count -eq 0)
        missingParameters = $missingParameters
        parameterNames = $parameterNames
        moduleName = [string]$ownedCommand.moduleName
        commandModuleName = $ownedCommand.commandModuleName
        scriptFile = $ownedCommand.scriptFile
        frozenCommandModuleName = $ownedCommand.frozenCommandModuleName
        runnerScriptFile = $ownedCommand.runnerScriptFile
        timingStateProbed = $false
    }
}

function Assert-AtlassianSourceResidentRunRequest {
    [CmdletBinding()]
    param(
        [string] $ExecutionMode = 'Run',
        [switch] $PrepareSourceTools,
        [switch] $SourceValidation,
        [switch] $SourceResidentTiming,
        [string] $SourceToolsPath,
        [int] $AdapterVersion = 1,
        [string] $AuthorityRevision,
        [string] $RunId,
        [switch] $CompleteLifecycle,
        [switch] $DevelopmentHarness
    )

    if (-not $SourceResidentTiming) { throw 'The source resident timing guard requires its explicit SourceResidentTiming request.' }
    if ($PrepareSourceTools -or $SourceValidation) {
        throw 'SourceResidentTiming and source setup or canonical SourceValidation are separate requests.'
    }
    if ($ExecutionMode -cne 'Run' -or [string]::IsNullOrWhiteSpace($SourceToolsPath)) {
        throw 'SourceResidentTiming requires Run and the prepared SourceToolsPath.'
    }
    if ($AdapterVersion -ne 2 -or $CompleteLifecycle -or $DevelopmentHarness) {
        throw 'SourceResidentTiming requires Core adapter v2 and cannot be combined with a legacy lifecycle or development harness.'
    }
    if ([string]$RunId -cnotmatch '^[0-9a-f]{32}$') {
        throw 'SourceResidentTiming requires the prepared RunId as exactly 32 lowercase hexadecimal characters.'
    }
    [void](Get-PreparedSourceAuthorityPin -AuthorityRevision $AuthorityRevision)
    return 'SourceResidentTiming'
}

function Get-AtlassianSourceResidentCaseCountValues {
    param([Parameter(Mandatory = $true)] $CaseLedger)

    $countFields = @('Passed', 'Failed', 'Skipped', 'Inconclusive', 'NotRun')
    $integerTypes = @('System.Byte', 'System.SByte', 'System.Int16', 'System.UInt16', 'System.Int32', 'System.UInt32', 'System.Int64', 'System.UInt64', 'System.Single', 'System.Double', 'System.Decimal', 'System.Numerics.BigInteger')
    $convertCount = {
        param([object] $Value, [string] $FieldName)
        $invalidMessage = "Source resident Pester case ledger count '$FieldName' must be a finite non-negative integer within the supported safe 64-bit range."
        if ($null -eq $Value -or $Value -is [bool]) { throw $invalidMessage }
        $typeName = $Value.GetType().FullName
        if ($integerTypes -cnotcontains $typeName) { throw $invalidMessage }

        if ($typeName -ceq 'System.Single' -or $typeName -ceq 'System.Double') {
            $numericValue = [double]$Value
            $maximumExactInteger = if ($typeName -ceq 'System.Single') { 16777215.0 } else { 9007199254740991.0 }
            if ([double]::IsNaN($numericValue) -or [double]::IsInfinity($numericValue) -or
                $numericValue -lt 0.0 -or $numericValue -gt $maximumExactInteger -or
                [Math]::Truncate($numericValue) -ne $numericValue) {
                throw $invalidMessage
            }
            return [long]$numericValue
        }
        if ($typeName -ceq 'System.Numerics.BigInteger') {
            $maximumInteger = [System.Numerics.BigInteger]::Parse([long]::MaxValue.ToString([Globalization.CultureInfo]::InvariantCulture))
            $numericValue = [System.Numerics.BigInteger]$Value
            if ($numericValue -lt [System.Numerics.BigInteger]::Zero -or $numericValue -gt $maximumInteger) { throw $invalidMessage }
            return [long]$numericValue
        }

        try { $decimalValue = [decimal]$Value } catch { throw $invalidMessage }
        if ($decimalValue -lt [decimal]::Zero -or $decimalValue -gt [decimal][long]::MaxValue -or
            [decimal]::Truncate($decimalValue) -ne $decimalValue) {
            throw $invalidMessage
        }
        return [long]$decimalValue
    }

    $reportedCountsProperty = if ($null -eq $CaseLedger) { $null } else { $CaseLedger.PSObject.Properties['reportedCounts'] }
    $reportedCounts = if ($null -eq $reportedCountsProperty) { $null } else { $reportedCountsProperty.Value }
    $normalizedReportedCounts = [ordered]@{}
    $reportedTotal = [System.Numerics.BigInteger]::Zero
    foreach ($fieldName in $countFields) {
        $countProperty = if ($null -eq $reportedCounts) { $null } else { $reportedCounts.PSObject.Properties[$fieldName] }
        $countValue = if ($null -eq $countProperty) { $null } else { $countProperty.Value }
        $normalizedValue = & $convertCount $countValue $fieldName
        $normalizedReportedCounts[$fieldName] = $normalizedValue
        $reportedTotal += [System.Numerics.BigInteger]$normalizedValue
    }

    $discoveryProperty = if ($null -eq $CaseLedger) { $null } else { $CaseLedger.PSObject.Properties['caseDiscoveryCount'] }
    $executionProperty = if ($null -eq $CaseLedger) { $null } else { $CaseLedger.PSObject.Properties['caseExecutionCount'] }
    $discoveryCount = & $convertCount $(if ($null -eq $discoveryProperty) { $null } else { $discoveryProperty.Value }) 'caseDiscoveryCount'
    $executionCount = & $convertCount $(if ($null -eq $executionProperty) { $null } else { $executionProperty.Value }) 'caseExecutionCount'
    $maximumInteger = [System.Numerics.BigInteger]::Parse([long]::MaxValue.ToString([Globalization.CultureInfo]::InvariantCulture))
    if ($reportedTotal -gt $maximumInteger) {
        throw 'Source resident Pester case ledger reportedCounts total exceeds the supported safe 64-bit integer range.'
    }

    return [pscustomobject]@{
        reportedCounts = [pscustomobject]$normalizedReportedCounts
        caseDiscoveryCount = $discoveryCount
        caseExecutionCount = $executionCount
        reportedTotal = [long]$reportedTotal
    }
}

function Invoke-AtlassianSourceResidentSampleSeries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.PSModuleInfo] $Module,
        [Parameter(Mandatory = $true)] $Prepared,
        [Parameter(Mandatory = $true)] $Report,
        [Parameter(Mandatory = $true)] $TimingEvidence,
        [Parameter(Mandatory = $true)] $CaseLedger,
        [Parameter(Mandatory = $true)][string] $PreparedPath,
        [Parameter(Mandatory = $true)][string] $TimingEvidencePath,
        [Parameter(Mandatory = $true)][string] $CaseLedgerPath,
        [Parameter(Mandatory = $true)] $AuthorityPin,
        [Parameter(Mandatory = $true)][string] $RunnerPath,
        [Parameter(Mandatory = $true)][string] $RunnerSha256,
        [Parameter(Mandatory = $true)][string] $RepositoryRoot,
        [Parameter(Mandatory = $true)][string] $CandidateRoot,
        [Parameter(Mandatory = $true)][string] $BaseRevision,
        [Parameter(Mandatory = $true)][string] $ArtifactsRoot,
        [Parameter(Mandatory = $true)][string] $EvidenceRoot,
        [string] $CancellationPath
    )

    $tailTimer = [Diagnostics.Stopwatch]::StartNew()
    $status = 'incomplete'
    $reason = 'preflight-failed'
    $failureMessage = $null
    $rawPath = $null
    $summaryPath = $null
    $rawStream = $null
    $rawWriter = $null
    $originalConsoleError = $null
    $moduleState = $null
    $moduleStateCaptured = $false
    $consoleErrorCaptured = $false
    $metadataHashes = @{}
    $preparedSha256 = $null
    $reportSha256 = $null
    $sampleCount = 0
    $sampleCalls = [Collections.Generic.List[object]]::new()
    $sampleStopwatch = $null
    $selectedGroupSummary = @()
    $sampleRecords = @()
    $sampleDiagnosticErrors = [Collections.Generic.List[string]]::new()
    $postflightErrors = [Collections.Generic.List[string]]::new()
    $cleanupErrors = [Collections.Generic.List[string]]::new()
    $counters = $null
    $seriesWallSeconds = 0.0
    $timingStateRestored = $null
    $processIdentity = [pscustomobject]@{
        processId = $PID
        is64Bit = [Environment]::Is64BitProcess
        runtime = [Runtime.InteropServices.RuntimeInformation]::FrameworkDescription
        cacheCondition = 'same-process; canonical frozen-file preflight warmed closures before the ordered sample loop'
    }

    $writeTextCreateNew = {
        param([string] $Path, [string] $Text)
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
        $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() }
        finally { $stream.Dispose() }
    }
    $hashFile = {
        param([string] $Path)
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    }
    $fullPath = {
        param([string] $Path, [string] $Context)
        if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) { throw "INVALID|$Context must be an absolute path." }
        [IO.Path]::GetFullPath($Path)
    }
    $isWithin = {
        param([string] $Path, [string] $Root)
        $pathValue = [IO.Path]::GetFullPath($Path)
        $rootValue = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        $pathValue.Equals($rootValue, $comparison) -or $pathValue.StartsWith($rootValue + [IO.Path]::DirectorySeparatorChar, $comparison) -or
            $pathValue.StartsWith($rootValue + [IO.Path]::AltDirectorySeparatorChar, $comparison)
    }
    $sameBindings = {
        param([object[]] $Left, [object[]] $Right)
        if ($Left.Count -ne $Right.Count) { return $false }
        foreach ($leftBinding in $Left) {
            $leftPath = [IO.Path]::GetFullPath([string]$leftBinding.path)
            $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
            $matches = @($Right | Where-Object {
                [IO.Path]::GetFullPath([string]$_.path).Equals($leftPath, $comparison) -and
                [string]$_.sha256 -ceq [string]$leftBinding.sha256
            })
            if ($matches.Count -ne 1) { return $false }
        }
        return $true
    }
    $verifyNoReparse = {
        param([string] $Path, [switch] $AllowMissingLeaf)
        $cursor = [IO.Path]::GetFullPath($Path)
        while (-not [string]::IsNullOrWhiteSpace($cursor)) {
            if (Test-Path -LiteralPath $cursor) {
                $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "BLOCKED|Resident timing path contains a reparse point: $cursor" }
            }
            elseif (-not $AllowMissingLeaf) { throw "BLOCKED|Resident timing path is missing: $cursor" }
            $parent = Split-Path -Parent $cursor
            if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $cursor) { break }
            $cursor = $parent
            $AllowMissingLeaf = $true
        }
    }
    $newResult = {
        param([bool] $Complete)
        [pscustomobject]@{
            status = $status
            complete = $Complete
            reason = $reason
            message = $failureMessage
            runId = if ($null -ne $Prepared) { [string]$Prepared.runId } else { $null }
            sampleCount = $sampleCount
            selectedGroups = @($selectedGroupSummary)
            samples = @($sampleRecords)
            sampleDiagnosticCountersValid = ($sampleDiagnosticErrors.Count -eq 0)
            sampleDiagnosticErrors = @($sampleDiagnosticErrors.ToArray())
            counters = $counters
            seriesWallSeconds = [Math]::Round($seriesWallSeconds, 6)
            tailWallSeconds = [Math]::Round($tailTimer.Elapsed.TotalSeconds, 6)
            process = $processIdentity
            rawDiagnosticsPath = $rawPath
            rawDiagnosticsSha256 = if ($null -ne $rawPath -and (Test-Path -LiteralPath $rawPath -PathType Leaf)) { & $hashFile $rawPath } else { $null }
            summaryPath = $summaryPath
            preparedSha256 = $preparedSha256
            reportSha256 = $reportSha256
            metadataSha256 = $metadataHashes
            postflightErrors = @($postflightErrors.ToArray())
            cleanupErrors = @($cleanupErrors.ToArray())
            timingStateRestored = $timingStateRestored
        }
    }

    try {
        $contract = Get-AtlassianSourceResidentRetainedApiContract -Module $Module
        $expectedRunnerHash = [string]$AuthorityPin.files['scripts/Invoke-StandardValidation.ps1']
        $runnerFullPath = & $fullPath $RunnerPath 'selected protected runner'
        $moduleRunnerPath = if ([string]::IsNullOrWhiteSpace([string]$contract.runnerScriptFile)) { '' } else { & $fullPath ([string]$contract.runnerScriptFile) 'loaded protected runner' }
        $runnerScriptDirectory = Split-Path -Parent $runnerFullPath
        if ([IO.Path]::GetFileName($runnerScriptDirectory) -cne 'scripts' -or [IO.Path]::GetFileName($runnerFullPath) -cne 'Invoke-StandardValidation.ps1') {
            throw 'The selected protected runner path does not match the pinned scripts/Invoke-StandardValidation.ps1 location.'
        }
        $runnerAuthorityRoot = Split-Path -Parent $runnerScriptDirectory
        $repoFullPath = & $fullPath $RepositoryRoot 'protected repository'
        $candidateFullPath = & $fullPath $CandidateRoot 'candidate root'
        $artifactsFullPath = & $fullPath $ArtifactsRoot 'artifacts root'
        $evidenceFullPath = & $fullPath $EvidenceRoot 'resident evidence root'
        $evidenceParent = Split-Path -Parent $evidenceFullPath
        if (-not $contract.supported) {
            $reason = 'retained-receipt-api-unsupported'
            $status = 'unsupported'
        }
        elseif ([string]$Module.Name -cne [string]$contract.moduleName -or
            [string]$contract.frozenCommandModuleName -cne [string]$contract.moduleName -or
            [string]$RunnerSha256 -cne $expectedRunnerHash -or
            -not $runnerFullPath.Equals($moduleRunnerPath, $(if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal })) -or
            (& $hashFile $runnerFullPath) -cne $expectedRunnerHash) {
            $reason = 'selected-runner-identity-mismatch'
            $failureMessage = 'The resident sample module is not bound to the same selected authority runner identity.'
        }
        if (Test-Path -LiteralPath $evidenceFullPath) { throw 'Resident evidence root already exists; evidence is create-only.' }
        if ((& $isWithin $evidenceFullPath $repoFullPath) -or (& $isWithin $evidenceFullPath $candidateFullPath) -or
            (& $isWithin $evidenceFullPath $artifactsFullPath) -or (& $isWithin $evidenceFullPath $runnerAuthorityRoot)) {
            throw 'Resident evidence root must be outside the repository, candidate, canonical artifacts and selected authority roots.'
        }
        & $verifyNoReparse $evidenceParent -AllowMissingLeaf
        [void](New-Item -ItemType Directory -Path $evidenceFullPath -ErrorAction Stop)
        $rawPath = Join-Path $evidenceFullPath 'resident-timing-raw.stderr.log'
        $summaryPath = Join-Path $evidenceFullPath 'resident-timing-summary.json'
        $rawStream = [IO.File]::Open($rawPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $rawWriter = [IO.StreamWriter]::new($rawStream, [Text.UTF8Encoding]::new($false))
        $rawWriter.AutoFlush = $true

        if ($status -ceq 'unsupported' -or $reason -ceq 'selected-runner-identity-mismatch') {
            $rawWriter.Dispose(); $rawWriter = $null; $rawStream = $null
        }
        else {
            $preparedFullPath = & $fullPath $PreparedPath 'prepared source metadata'
            $timingFullPath = & $fullPath $TimingEvidencePath 'source timing evidence'
            $ledgerFullPath = & $fullPath $CaseLedgerPath 'Pester case ledger'
            $reportFullPath = & $fullPath ([string]$Report.artifacts.outputPath) 'canonical Core report'
            if (-not (& $isWithin $reportFullPath $artifactsFullPath)) { throw 'Canonical Core report is outside the accepted artifacts root.' }
            foreach ($pathValue in @($preparedFullPath, $timingFullPath, $ledgerFullPath, $reportFullPath)) {
                & $verifyNoReparse $pathValue
                $metadataHashes[$pathValue] = & $hashFile $pathValue
            }
            $preparedOnDisk = Get-Content -LiteralPath $preparedFullPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -Depth 80 -ErrorAction Stop
            $reportOnDisk = Get-Content -LiteralPath $reportFullPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -Depth 80 -ErrorAction Stop
            $timingOnDisk = Get-Content -LiteralPath $timingFullPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -Depth 40 -ErrorAction Stop
            $ledgerOnDisk = Get-Content -LiteralPath $ledgerFullPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -Depth 40 -ErrorAction Stop
            $preparedSha256 = [string]$metadataHashes[$preparedFullPath]
            $reportSha256 = [string]$metadataHashes[$reportFullPath]
            $runId = [string]$preparedOnDisk.runId
            $sourceRevision = [string]$preparedOnDisk.sourceRevision
            $authorityRevision = [string]$preparedOnDisk.authorityRevision
            $sourceValidation = $preparedOnDisk.sourceValidation
            $reportSourceValidation = $reportOnDisk.sourceValidation
            $expectedDispatchNames = @('packageAdapter', 'skillValidator', 'skillTools', 'staticAnalyzer', 'frozenFiles', 'toolReceipts')
            $preparedSourceNames = @($sourceValidation.PSObject.Properties.Name | Sort-Object -CaseSensitive)
            $expectedSourceNames = @($expectedDispatchNames | Sort-Object -CaseSensitive)
            $preparedReceiptBindings = @($sourceValidation.toolReceipts)
            $preparedFrozenBindings = @($sourceValidation.frozenFiles)
            $reportReceiptBindings = @($reportSourceValidation.toolReceipts)
            $reportFrozenBindings = @($reportSourceValidation.frozenFiles)
            $dispatchEntriesValid = $true
            foreach ($dispatchName in @('packageAdapter', 'skillValidator', 'skillTools', 'staticAnalyzer')) {
                $dispatch = $sourceValidation.PSObject.Properties[$dispatchName].Value
                if ($null -eq $dispatch -or -not [IO.Path]::IsPathRooted([string]$dispatch.command) -or $dispatch.arguments -isnot [array]) {
                    $dispatchEntriesValid = $false
                    continue
                }
                foreach ($dispatchPath in @([string]$dispatch.command) + @($dispatch.arguments | Where-Object { [IO.Path]::IsPathRooted([string]$_) })) {
                    $dispatchFullPath = [IO.Path]::GetFullPath([string]$dispatchPath)
                    $dispatchMatches = @($preparedFrozenBindings | Where-Object {
                        [IO.Path]::GetFullPath([string]$_.path).Equals($dispatchFullPath, $(if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }))
                    })
                    if ($dispatchMatches.Count -ne 1) { $dispatchEntriesValid = $false }
                }
            }
            $reportPathMatches = [IO.Path]::GetFullPath([string]$reportOnDisk.artifacts.outputPath).Equals($reportFullPath, $(if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }))
            $caseBindingPath = & $fullPath ([string]$reportSourceValidation.pesterCaseInventory.path) 'reported Pester case inventory'
            $coreRunRoot = & $fullPath ([string]$reportOnDisk.artifacts.runRoot) 'Core run root'
            $expectedCoreRunRoot = [IO.Path]::GetFullPath((Join-Path (Join-Path $artifactsFullPath 'runs') $runId))
            $snapshotRoot = & $fullPath ([string]$reportOnDisk.artifacts.snapshotRoot) 'Core candidate snapshot root'
            $caseRootPrefix = $coreRunRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
            $countNames = @('Failed', 'Skipped', 'Inconclusive', 'NotRun')
            $countValidationMessage = $null
            $diskCaseCountValues = $null
            $memoryCaseCountValues = $null
            try {
                $diskCaseCountValues = Get-AtlassianSourceResidentCaseCountValues -CaseLedger $ledgerOnDisk
                $memoryCaseCountValues = Get-AtlassianSourceResidentCaseCountValues -CaseLedger $CaseLedger
            }
            catch { $countValidationMessage = $_.Exception.Message }
            $caseCountsSemanticsValid = $false
            if ($null -eq $countValidationMessage) {
                $inMemoryCountsMatch = $true
                foreach ($countName in @('Passed') + $countNames) {
                    if ([long]$memoryCaseCountValues.reportedCounts.$countName -ne [long]$diskCaseCountValues.reportedCounts.$countName) {
                        $inMemoryCountsMatch = $false
                    }
                }
                if ([long]$memoryCaseCountValues.caseDiscoveryCount -ne [long]$diskCaseCountValues.caseDiscoveryCount -or
                    [long]$memoryCaseCountValues.caseExecutionCount -ne [long]$diskCaseCountValues.caseExecutionCount) {
                    $inMemoryCountsMatch = $false
                }
                $caseCountsSemanticsValid = $inMemoryCountsMatch -and
                    [long]$diskCaseCountValues.reportedCounts.Failed -eq 0 -and
                    [long]$diskCaseCountValues.reportedCounts.Skipped -eq 0 -and
                    [long]$diskCaseCountValues.reportedCounts.Inconclusive -eq 0 -and
                    [long]$diskCaseCountValues.reportedCounts.NotRun -eq 0 -and
                    [long]$diskCaseCountValues.reportedCounts.Passed -gt 0 -and
                    [long]$diskCaseCountValues.caseDiscoveryCount -gt 0 -and
                    [long]$diskCaseCountValues.caseDiscoveryCount -eq [long]$diskCaseCountValues.caseExecutionCount -and
                    [long]$diskCaseCountValues.reportedTotal -eq [long]$diskCaseCountValues.caseExecutionCount -and
                    [long]$diskCaseCountValues.reportedCounts.Passed -eq [long]$diskCaseCountValues.caseExecutionCount
            }
            if ($runId -cnotmatch '^[0-9a-f]{32}$' -or [string]$Prepared.runId -cne $runId -or
                [string]$Report.runId -cne $runId -or [string]$reportOnDisk.runId -cne $runId -or
                [string]$TimingEvidence.runId -cne $runId -or [string]$timingOnDisk.runId -cne $runId -or
                [string]$CaseLedger.coreRunId -cne $runId -or [string]$ledgerOnDisk.coreRunId -cne $runId -or
                [string]$authorityRevision -cne [string]$AuthorityPin.commit -or [string]$RunnerSha256 -cne $expectedRunnerHash -or
                [string]$reportOnDisk.authority.revision -cne $authorityRevision -or
                [string]$reportOnDisk.authority.runnerSha256 -cne $expectedRunnerHash -or
                [string]$sourceRevision -cne [string]$reportOnDisk.candidate.sourceRevision -or
                [string]$reportOnDisk.candidate.baseRevision -cne $BaseRevision -or
                [string]$reportOnDisk.artifacts.root -cne $artifactsFullPath -or -not $reportPathMatches -or
                [string]$reportOnDisk.artifacts.runId -cne $runId -or
                [string]$Report.artifacts.runId -cne $runId -or
                -not $coreRunRoot.Equals($expectedCoreRunRoot, $(if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal })) -or
                -not (& $isWithin $snapshotRoot $coreRunRoot) -or -not (Test-Path -LiteralPath $snapshotRoot -PathType Container) -or
                [string]$reportOnDisk.state -cne 'PASS' -or [int]$reportOnDisk.exitCode -ne 0 -or
                [string]$reportSourceValidation.status -cne 'passed' -or [string]$reportSourceValidation.runId -cne $runId -or
                [string]$reportSourceValidation.sourceRevision -cne $sourceRevision -or [string]$reportSourceValidation.authorityRevision -cne $authorityRevision -or
                [string]$Report.sourceValidation.status -cne [string]$reportSourceValidation.status -or
                [string]$Report.sourceValidation.runId -cne [string]$reportSourceValidation.runId -or
                [string]$Report.sourceValidation.sourceRevision -cne [string]$reportSourceValidation.sourceRevision -or
                [string]$Report.sourceValidation.authorityRevision -cne [string]$reportSourceValidation.authorityRevision -or
                $preparedSourceNames.Count -ne $expectedSourceNames.Count -or (($preparedSourceNames -join "`n") -cne ($expectedSourceNames -join "`n")) -or
                -not $dispatchEntriesValid -or
                $preparedReceiptBindings.Count -ne 3 -or $preparedFrozenBindings.Count -eq 0 -or
                $reportReceiptBindings.Count -ne 3 -or $reportFrozenBindings.Count -eq 0 -or
                -not (& $sameBindings $preparedReceiptBindings $reportReceiptBindings) -or
                -not (& $sameBindings $preparedFrozenBindings $reportFrozenBindings) -or
                -not $caseBindingPath.Equals($ledgerFullPath, $(if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal })) -or
                -not $ledgerFullPath.StartsWith($caseRootPrefix, $(if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal })) -or
                [string]$reportSourceValidation.pesterCaseInventory.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
                [string]$reportSourceValidation.pesterCaseInventory.sha256 -cne [string]$metadataHashes[$ledgerFullPath] -or
                [string]$ledgerOnDisk.report -cne 'standard-core-pester-case-inventory-v1' -or
                $ledgerOnDisk.schemaVersion -ne 1 -or $null -ne $countValidationMessage -or -not $caseCountsSemanticsValid -or
                -not [bool]$timingOnDisk.reportAccepted -or -not [bool]$timingOnDisk.cleanupSucceeded -or
                [string]$TimingEvidence.candidateRevision -cne $sourceRevision -or
                [string]$TimingEvidence.baseRevision -cne $BaseRevision -or
                [string]$TimingEvidence.authorityRevision -cne $authorityRevision -or
                [string]$timingOnDisk.candidateRevision -cne $sourceRevision -or
                [string]$timingOnDisk.baseRevision -cne $BaseRevision -or
                [string]$timingOnDisk.authorityRevision -cne $authorityRevision -or
                [int]$timingOnDisk.processExitCode -ne 0 -or
                [string]$ledgerOnDisk.terminalStatus -cne 'complete' -or $ledgerOnDisk.complete -isnot [bool] -or -not [bool]$ledgerOnDisk.complete) {
                $reason = 'metadata-mismatch'
                $failureMessage = if ($null -ne $countValidationMessage) { $countValidationMessage } else { 'Prepared metadata, accepted report, cleanup/timing evidence or complete case ledger do not bind the same run.' }
                $rawWriter.Dispose(); $rawWriter = $null; $rawStream = $null
            }
            else {
                $preparedSha256 = [string]$metadataHashes[$preparedFullPath]
                $reportSha256 = [string]$metadataHashes[$reportFullPath]
                $status = 'incomplete'
                $reason = 'preflight-failed'
                $moduleState = & $Module {
                    [pscustomobject]@{
                        timingEnabled = $script:StandardValidationTimingEnabled
                        timingStage = $script:StandardValidationTimingStage
                        closureTiming = $script:StandardValidationClosureTiming
                        readObserver = $script:StandardValidationReadObserver
                    }
                }
                $moduleStateCaptured = $true
                $originalConsoleError = [Console]::Error
                $consoleErrorCaptured = $true
                [Console]::SetError($rawWriter)
                & $Module {
                    param($Stage)
                    $script:StandardValidationTimingEnabled = $true
                    $script:StandardValidationTimingStage = $Stage
                    $script:StandardValidationClosureTiming = $null
                    $script:StandardValidationReadObserver = $null
                } 'source-resident-preflight'

                try {
                    Invoke-AtlassianSourceStandardValidationModule -Module $Module -FunctionName 'Assert-StandardCoreFrozenFiles' `
                        -Arguments ([ordered]@{ Files = [object[]]$sourceValidation.frozenFiles }) | Out-Null
                    $receiptMap = Invoke-AtlassianSourceStandardValidationModule -Module $Module -FunctionName 'Assert-StandardCoreSourceToolReceipts' `
                        -Arguments ([ordered]@{
                            Bindings = [object[]]$sourceValidation.toolReceipts; FrozenFiles = [object[]]$sourceValidation.frozenFiles
                            RunId = $runId; CandidateRoot = $candidateFullPath; ArtifactsRoot = $artifactsFullPath
                            ReturnReceiptMap = $true
                        })
                    if ($null -eq $receiptMap -or [int]$receiptMap.schemaVersion -ne 1 -or
                        [string]$receiptMap.runId -cne $runId -or $receiptMap.receipts -isnot [hashtable] -or
                        $receiptMap.bindings -isnot [hashtable] -or $null -eq $receiptMap.groups -or
                        $receiptMap.groups.byTool -isnot [hashtable] -or @($receiptMap.groups.groups).Count -lt 2) {
                        $reason = 'receipt-map-mismatch'
                        $failureMessage = 'The selected runner returned a retained receipt map with a different run or incomplete group inventory.'
                    }
                    else {
                        $groupsBySize = [Collections.Generic.List[object]]::new()
                        $seenGroupIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                        foreach ($group in @($receiptMap.groups.groups)) {
                            $groupId = [string]$group.id
                            $rootFiles = @($group.rootFiles)
                            if ([string]::IsNullOrWhiteSpace($groupId) -or -not $seenGroupIds.Add($groupId) -or $rootFiles.Count -eq 0) {
                                $reason = 'receipt-map-mismatch'
                                $failureMessage = 'The retained tool groups contain an empty or duplicate group identity.'
                                break
                            }
                            $rootBytes = [long]0
                            foreach ($file in $rootFiles) { $rootBytes += [long](Get-Item -LiteralPath ([string]$file.path) -Force -ErrorAction Stop).Length }
                            $groupsBySize.Add([pscustomobject]@{
                                id = $groupId; tools = @($group.tools); roots = @($group.roots)
                                rootFileCount = $rootFiles.Count; rootBytes = $rootBytes
                                rootFiles = $rootFiles; sharedFiles = @($group.sharedFiles); externalAssets = @($group.externalAssets)
                            })
                        }
                        if ($reason -ceq 'preflight-failed') {
                            $footprintCounts = @($groupsBySize | ForEach-Object { '{0}:{1}' -f [int]$_.rootFileCount, [long]$_.rootBytes } | Sort-Object -Unique)
                            if ($footprintCounts.Count -lt 2) {
                                $reason = 'insufficient-distinct-closure-footprints'
                                $failureMessage = 'The actual installed tool groups do not provide two distinct frozen root-file count and byte footprints.'
                            }
                            elseif (-not [string]::IsNullOrWhiteSpace($CancellationPath) -and (Test-Path -LiteralPath $CancellationPath -PathType Leaf)) {
                                $status = 'cancelled'
                                $reason = 'cancelled-before-samples'
                                $failureMessage = 'The resident sampling request was cancelled before the first sample.'
                            }
                            else {
                                $orderedGroups = @($groupsBySize | Sort-Object -Property @{ Expression = { [long]$_.rootBytes } }, @{ Expression = { [int]$_.rootFileCount } }, @{ Expression = { [string]$_.id } })
                                $selectedGroups = @($orderedGroups[0], $orderedGroups[-1])
                                $selectedGroupSummary = @($selectedGroups | ForEach-Object {
                                    [pscustomobject]@{
                                        groupId = [string]$_.id; tools = @($_.tools); rootFileCount = [int]$_.rootFileCount; rootBytes = [long]$_.rootBytes
                                        sharedFileCount = @($_.sharedFiles).Count; externalAssetCount = @($_.externalAssets).Count
                                    }
                                })
                                $reason = 'sampling-failed'
                                $sampleStopwatch = [Diagnostics.Stopwatch]::StartNew()
                                foreach ($group in $selectedGroups) {
                                    $additionalPathMap = [Collections.Generic.Dictionary[string,string]]::new($(if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }))
                                    foreach ($toolName in @($group.tools)) {
                                        $dispatchSlot = switch ([string]$toolName) {
                                            'skill-validator' { 'skillValidator' }
                                            'skill-tools' { 'skillTools' }
                                            'skillspector' { 'staticAnalyzer' }
                                            default { throw "The retained source group has an unsupported dispatch tool '$toolName'." }
                                        }
                                        $dispatch = $sourceValidation.PSObject.Properties[$dispatchSlot].Value
                                        $dispatchCommand = & $fullPath ([string]$dispatch.command) "prepared $dispatchSlot command"
                                        if (-not $additionalPathMap.ContainsKey($dispatchCommand)) { $additionalPathMap.Add($dispatchCommand, $dispatchCommand) }
                                        foreach ($argument in @($dispatch.arguments)) {
                                            if ([IO.Path]::IsPathRooted([string]$argument)) {
                                                $argumentPath = & $fullPath ([string]$argument) "prepared $dispatchSlot argument path"
                                                if (-not $additionalPathMap.ContainsKey($argumentPath)) { $additionalPathMap.Add($argumentPath, $argumentPath) }
                                            }
                                        }
                                    }
                                    $additionalPaths = [string[]]@($additionalPathMap.Values | Sort-Object -CaseSensitive)
                                    for ($sampleIndex = 1; $sampleIndex -le 3; $sampleIndex++) {
                                        if (-not [string]::IsNullOrWhiteSpace($CancellationPath) -and (Test-Path -LiteralPath $CancellationPath -PathType Leaf)) {
                                            $status = 'cancelled'
                                            $reason = 'cancelled-during-samples'
                                            $failureMessage = 'The resident sampling request was cancelled during the sample loop.'
                                            break
                                        }
                                        $sampleWatch = [Diagnostics.Stopwatch]::StartNew()
                                        $sampleCount++
                                        $sampleError = $null
                                        & $Module { param($Stage) $script:StandardValidationTimingStage = $Stage } 'source-resident-sample'
                                        try {
                                            [void](Invoke-AtlassianSourceStandardValidationModule -Module $Module -FunctionName 'Assert-StandardCoreSourceToolReceipts' `
                                                -Arguments ([ordered]@{
                                                    Bindings = [object[]]$sourceValidation.toolReceipts; FrozenFiles = [object[]]$sourceValidation.frozenFiles
                                                    RunId = $runId; CandidateRoot = $candidateFullPath; ArtifactsRoot = $artifactsFullPath
                                                    RetainedReceiptMap = $receiptMap; ToolNames = [string[]]$group.tools
                                                    AdditionalPaths = $additionalPaths
                                                }))
                                        }
                                        catch { $sampleError = $_.Exception.Message }
                                        finally {
                                            $sampleWatch.Stop()
                                            $sampleCalls.Add([pscustomobject]@{
                                                groupId = [string]$group.id; sampleIndex = $sampleIndex; tools = @($group.tools)
                                                rootFileCount = [int]$group.rootFileCount; rootBytes = [long]$group.rootBytes
                                                additionalPaths = $additionalPaths; wallSeconds = [Math]::Round($sampleWatch.Elapsed.TotalSeconds, 6)
                                                error = $sampleError
                                            })
                                        }
                                        if ($null -ne $sampleError) {
                                            $failureMessage = $sampleError
                                            $reason = 'sample-exception'
                                            break
                                        }
                                    }
                                    if ($reason -ceq 'sample-exception' -or $status -ceq 'cancelled') { break }
                                }
                                $sampleStopwatch.Stop()
                                $seriesWallSeconds = $sampleStopwatch.Elapsed.TotalSeconds
                            }
                        }
                    }
                }
                catch {
                    if ($reason -ceq 'sampling-failed') { $reason = 'sample-exception' }
                    elseif ($reason -ceq 'preflight-failed') { $reason = 'preflight-failed' }
                    $failureMessage = $_.Exception.Message
                }
                finally {
                    if ($null -ne $sampleStopwatch) {
                        $sampleStopwatch.Stop()
                        if ($sampleCount -gt 0 -and $seriesWallSeconds -eq 0.0) { $seriesWallSeconds = $sampleStopwatch.Elapsed.TotalSeconds }
                    }
                    if ($moduleStateCaptured) {
                        & $Module { param($Stage) $script:StandardValidationTimingStage = $Stage } 'source-resident-postflight'
                        try {
                            Invoke-AtlassianSourceStandardValidationModule -Module $Module -FunctionName 'Assert-StandardCoreFrozenFiles' `
                                -Arguments ([ordered]@{ Files = [object[]]$sourceValidation.frozenFiles }) | Out-Null
                        }
                        catch { $postflightErrors.Add(('frozen-file verification: ' + $_.Exception.Message)) }
                        try {
                            [void](Invoke-AtlassianSourceStandardValidationModule -Module $Module -FunctionName 'Assert-StandardCoreSourceToolReceipts' `
                                -Arguments ([ordered]@{
                                    Bindings = [object[]]$sourceValidation.toolReceipts; FrozenFiles = [object[]]$sourceValidation.frozenFiles
                                    RunId = $runId; CandidateRoot = $candidateFullPath; ArtifactsRoot = $artifactsFullPath
                                }))
                        }
                        catch { $postflightErrors.Add(('full receipt verification: ' + $_.Exception.Message)) }
                        if ($reason -ceq 'sampling-failed' -and $sampleCount -eq 6 -and $postflightErrors.Count -eq 0) {
                            $reason = 'complete'
                            $status = 'complete'
                        }
                        elseif ($reason -ceq 'sampling-failed' -and $postflightErrors.Count -gt 0) {
                            $reason = 'postflight-failed'
                            $failureMessage = $postflightErrors[0]
                        }
                    }
                    if ($consoleErrorCaptured) {
                        try { if ($null -ne $rawWriter) { $rawWriter.Flush() } }
                        catch {
                            $cleanupMessage = "raw timing writer Flush failed ($($_.Exception.GetType().FullName)): $($_.Exception.Message)"
                            $cleanupErrors.Add($cleanupMessage)
                            if ($null -eq $failureMessage) { $failureMessage = $cleanupMessage }
                            if ($status -ceq 'complete') { $status = 'incomplete'; if ($reason -ceq 'complete') { $reason = 'cleanup-failed' } }
                        }
                        finally {
                            try { [Console]::SetError($originalConsoleError); $consoleErrorCaptured = $false }
                            catch {
                                $cleanupMessage = "Console.Error restoration failed ($($_.Exception.GetType().FullName)): $($_.Exception.Message)"
                                $cleanupErrors.Add($cleanupMessage)
                                if ($null -eq $failureMessage) { $failureMessage = $cleanupMessage }
                                if ($status -ceq 'complete') { $status = 'incomplete'; if ($reason -ceq 'complete') { $reason = 'cleanup-failed' } }
                            }
                        }
                    }
                    if ($null -ne $rawWriter) {
                        try { $rawWriter.Dispose() }
                        catch {
                            $cleanupMessage = "raw timing writer Dispose failed ($($_.Exception.GetType().FullName)): $($_.Exception.Message)"
                            $cleanupErrors.Add($cleanupMessage)
                            if ($null -eq $failureMessage) { $failureMessage = $cleanupMessage }
                            if ($status -ceq 'complete') { $status = 'incomplete'; if ($reason -ceq 'complete') { $reason = 'cleanup-failed' } }
                            if ($null -ne $rawStream) {
                                try { $rawStream.Dispose() }
                                catch {
                                    $cleanupMessage = "raw timing backing stream fallback Dispose failed ($($_.Exception.GetType().FullName)): $($_.Exception.Message)"
                                    $cleanupErrors.Add($cleanupMessage)
                                    if ($null -eq $failureMessage) { $failureMessage = $cleanupMessage }
                                    if ($status -ceq 'complete') { $status = 'incomplete'; if ($reason -ceq 'complete') { $reason = 'cleanup-failed' } }
                                }
                            }
                        }
                        finally { $rawWriter = $null; $rawStream = $null }
                    }
                    if ($moduleStateCaptured) {
                        try {
                            & $Module {
                                param($Previous)
                                $script:StandardValidationTimingEnabled = $Previous.timingEnabled
                                $script:StandardValidationTimingStage = $Previous.timingStage
                                $script:StandardValidationClosureTiming = $Previous.closureTiming
                                $script:StandardValidationReadObserver = $Previous.readObserver
                            } $moduleState
                            $restoredState = & $Module {
                                [pscustomobject]@{
                                    timingEnabled = $script:StandardValidationTimingEnabled
                                    timingStage = $script:StandardValidationTimingStage
                                    closureTiming = $script:StandardValidationClosureTiming
                                    readObserver = $script:StandardValidationReadObserver
                                }
                            }
                            $timingStateRestored = [bool]$restoredState.timingEnabled -eq [bool]$moduleState.timingEnabled -and
                                [string]$restoredState.timingStage -ceq [string]$moduleState.timingStage -and
                                [object]::ReferenceEquals($restoredState.closureTiming, $moduleState.closureTiming) -and
                                [object]::ReferenceEquals($restoredState.readObserver, $moduleState.readObserver)
                            $moduleStateCaptured = $false
                            if (-not $timingStateRestored) {
                                $cleanupMessage = 'Module timing state restore readback did not match the four captured values and references.'
                                $cleanupErrors.Add($cleanupMessage)
                                if ($null -eq $failureMessage) { $failureMessage = $cleanupMessage }
                                if ($status -ceq 'complete') { $status = 'incomplete'; if ($reason -ceq 'complete') { $reason = 'cleanup-failed' } }
                            }
                        }
                        catch {
                            $timingStateRestored = $false
                            $cleanupMessage = "Module timing state restoration failed ($($_.Exception.GetType().FullName)): $($_.Exception.Message)"
                            $cleanupErrors.Add($cleanupMessage)
                            if ($null -eq $failureMessage) { $failureMessage = $cleanupMessage }
                            if ($status -ceq 'complete') { $status = 'incomplete'; if ($reason -ceq 'complete') { $reason = 'cleanup-failed' } }
                        }
                    }
                }

                $parsedRecords = [Collections.Generic.List[object]]::new()
                foreach ($line in @(Get-Content -LiteralPath $rawPath -ErrorAction Stop)) {
                    $prefix = '[StandardValidation timing] '
                    if (-not $line.StartsWith($prefix, [StringComparison]::Ordinal)) { continue }
                    try { $parsedRecords.Add(($line.Substring($prefix.Length) | ConvertFrom-Json -Depth 10 -ErrorAction Stop)) }
                    catch { }
                }
                $terminalStates = @('completed', 'failed', 'cancelled')
                $allSamplePhaseRecords = @($parsedRecords | Where-Object { [string]$_.stage -ceq 'source-resident-sample' })
                $counterFieldNames = @('calls', 'files', 'bytes', 'elapsedSeconds')
                for ($recordIndex = 0; $recordIndex -lt $allSamplePhaseRecords.Count; $recordIndex++) {
                    $rawRecord = $allSamplePhaseRecords[$recordIndex]
                    foreach ($fieldName in $counterFieldNames) {
                        $counterProperty = $rawRecord.PSObject.Properties[$fieldName]
                        if ($null -eq $counterProperty) {
                            $sampleDiagnosticErrors.Add("sample timing record $recordIndex is missing numeric '$fieldName'.")
                            continue
                        }
                        $counterValue = $counterProperty.Value
                        $numericType = $counterValue -is [byte] -or $counterValue -is [sbyte] -or
                            $counterValue -is [int16] -or $counterValue -is [uint16] -or
                            $counterValue -is [int32] -or $counterValue -is [uint32] -or
                            $counterValue -is [int64] -or $counterValue -is [uint64] -or
                            $counterValue -is [single] -or $counterValue -is [double] -or $counterValue -is [decimal]
                        if (-not $numericType) {
                            $sampleDiagnosticErrors.Add("sample timing record $recordIndex has non-numeric '$fieldName'.")
                            continue
                        }
                        $numericValue = [double]$counterValue
                        if ([double]::IsNaN($numericValue) -or [double]::IsInfinity($numericValue) -or $numericValue -lt 0) {
                            $sampleDiagnosticErrors.Add("sample timing record $recordIndex has non-finite or negative '$fieldName'.")
                        }
                    }
                }
                $samplePhaseRecords = @($allSamplePhaseRecords | Where-Object { [string]$_.state -cin $terminalStates })
                $sampleBlocks = [Collections.Generic.List[object]]::new()
                $currentSampleBlock = [Collections.Generic.List[object]]::new()
                foreach ($phaseRecord in $samplePhaseRecords) {
                    $currentSampleBlock.Add($phaseRecord)
                    if ([string]$phaseRecord.phase -ceq 'source-integrity') {
                        $sampleBlocks.Add([object[]]$currentSampleBlock.ToArray())
                        $currentSampleBlock.Clear()
                    }
                }
                if ($currentSampleBlock.Count -gt 0) { $sampleBlocks.Add([object[]]$currentSampleBlock.ToArray()) }
                $sampleRecordList = [Collections.Generic.List[object]]::new()
                for ($index = 0; $index -lt $sampleCalls.Count; $index++) {
                    $call = $sampleCalls[$index]
                    $phaseBlock = if ($index -lt $sampleBlocks.Count) { [object[]]$sampleBlocks[$index] } else { [object[]]@() }
                    $outerRecord = @($phaseBlock | Where-Object { [string]$_.phase -ceq 'source-integrity' } | Select-Object -Last 1)
                    $sourceIntegrityRecord = if ($outerRecord.Count -gt 0) { $outerRecord[0] } else { $null }
                    $nestedRecords = @($phaseBlock | Where-Object { [string]$_.phase -cne 'source-integrity' })
                    $sampleRecordList.Add([pscustomobject]@{
                        groupId = [string]$call.groupId; sampleIndex = [int]$call.sampleIndex; tools = @($call.tools)
                        rootFileCount = [int]$call.rootFileCount; rootBytes = [long]$call.rootBytes
                        additionalPaths = @($call.additionalPaths); wallSeconds = [double]$call.wallSeconds; error = $call.error
                        sourceIntegrity = $sourceIntegrityRecord; phaseRecords = $nestedRecords
                        state = if ($null -eq $sourceIntegrityRecord) { 'missing-diagnostics' } else { [string]$sourceIntegrityRecord.state }
                    })
                }
                $sampleRecords = @($sampleRecordList.ToArray())
                if ($status -ceq 'complete') {
                    $diagnosticsValid = $sampleDiagnosticErrors.Count -eq 0 -and $sampleCount -eq 6 -and $sampleRecords.Count -eq 6 -and @($sampleRecords | Where-Object {
                        $null -eq $_.sourceIntegrity -or [string]$_.sourceIntegrity.state -cne 'completed' -or
                            @($_.phaseRecords | Where-Object { [string]$_.phase -ceq 'source-receipt-bytes' -and [string]$_.state -ceq 'completed' }).Count -eq 0 -or
                            @($_.phaseRecords | Where-Object { [string]$_.phase -ceq 'frozen-file-hashes' -and [string]$_.state -ceq 'completed' }).Count -eq 0 -or
                            @($_.phaseRecords | Where-Object { [string]$_.phase -ceq 'closure-content-hash' -and [string]$_.state -ceq 'completed' }).Count -eq 0
                    }).Count -eq 0
                    if (-not $diagnosticsValid) {
                        $status = 'incomplete'
                        if ($sampleDiagnosticErrors.Count -gt 0) {
                            $reason = 'invalid-sample-diagnostic-counters'
                            $failureMessage = 'A sample-stage raw timing record has a missing, non-numeric, non-finite or negative counter.'
                        }
                        else {
                            $reason = 'missing-sample-terminal-diagnostics'
                            $failureMessage = 'Six sample calls with terminal outer records and retained-receipt, frozen-file-hash and closure-hash phase records were not captured.'
                        }
                    }
                    else {
                        $counters = [pscustomobject]@{
                            sampleTerminalCount = $sampleRecords.Count
                            phaseRecords = @($sampleRecords | ForEach-Object { @($_.phaseRecords) } | ForEach-Object { $_ })
                            phases = @($sampleRecords | ForEach-Object { @($_.phaseRecords | ForEach-Object { [string]$_.phase }) } | Sort-Object -Unique -CaseSensitive)
                        }
                        foreach ($groupSummary in $selectedGroupSummary) {
                            $groupSamples = @($sampleRecords | Where-Object { [string]$_.groupId -ceq [string]$groupSummary.groupId })
                            $groupWall = @($groupSamples | ForEach-Object { [double]$_.wallSeconds } | Sort-Object)
                            $groupSummary | Add-Member -NotePropertyName sampleCount -NotePropertyValue $groupSamples.Count -Force
                            $groupSummary | Add-Member -NotePropertyName minWallSeconds -NotePropertyValue $groupWall[0] -Force
                            $groupSummary | Add-Member -NotePropertyName meanWallSeconds -NotePropertyValue (($groupWall | Measure-Object -Average).Average) -Force
                            $groupSummary | Add-Member -NotePropertyName maxWallSeconds -NotePropertyValue $groupWall[-1] -Force
                        }
                    }
                }
                elseif ($sampleCount -gt 0 -and @($sampleRecords | Where-Object { $null -eq $_.sourceIntegrity }).Count -gt 0 -and $reason -ceq 'sampling-failed') {
                    $reason = 'missing-sample-terminal-diagnostics'
                    $failureMessage = 'Sample calls produced no terminal timing diagnostics; the result remains incomplete and counters are not synthesized.'
                }

                foreach ($metadataPath in @($metadataHashes.Keys)) {
                    if ((& $hashFile ([string]$metadataPath)) -cne [string]$metadataHashes[$metadataPath]) {
                        if ($status -ceq 'complete') { $status = 'incomplete'; $reason = 'metadata-changed-after-sampling' }
                        if ($null -eq $failureMessage) { $failureMessage = "Run metadata bytes changed during resident sampling: $metadataPath" }
                    }
                }
                $preparedSha256 = [string]$metadataHashes[$preparedFullPath]
                $reportSha256 = [string]$metadataHashes[$reportFullPath]
            }
        }
        if ($status -ceq 'complete' -and $reason -ceq 'complete' -and $null -eq $failureMessage) {
            $isComplete = $true
        }
        else { $isComplete = $false }
    }
    catch {
        if ($null -eq $failureMessage) { $failureMessage = $_.Exception.Message }
        if ($status -ceq 'complete') { $status = 'incomplete' }
        if ($reason -ceq 'preflight-failed') { $reason = 'evidence-or-preflight-error' }
        $isComplete = $false
    }
    finally {
        if ($null -ne $rawWriter) {
            try { $rawWriter.Flush() }
            catch {
                $cleanupMessage = "outer fallback raw timing writer Flush failed ($($_.Exception.GetType().FullName)): $($_.Exception.Message)"
                $cleanupErrors.Add($cleanupMessage)
                if ($null -eq $failureMessage) { $failureMessage = $cleanupMessage }
                if ($status -ceq 'complete') { $status = 'incomplete'; if ($reason -ceq 'complete') { $reason = 'cleanup-failed' } }
            }
        }
        if ($consoleErrorCaptured) {
            try { [Console]::SetError($originalConsoleError); $consoleErrorCaptured = $false }
            catch {
                $cleanupMessage = "outer fallback Console.Error restoration failed ($($_.Exception.GetType().FullName)): $($_.Exception.Message)"
                $cleanupErrors.Add($cleanupMessage)
                if ($null -eq $failureMessage) { $failureMessage = $cleanupMessage }
                if ($status -ceq 'complete') { $status = 'incomplete'; if ($reason -ceq 'complete') { $reason = 'cleanup-failed' } }
            }
        }
        if ($null -ne $rawWriter) {
            try { $rawWriter.Dispose() }
            catch {
                $cleanupMessage = "outer fallback raw timing writer Dispose failed ($($_.Exception.GetType().FullName)): $($_.Exception.Message)"
                $cleanupErrors.Add($cleanupMessage)
                if ($null -eq $failureMessage) { $failureMessage = $cleanupMessage }
                if ($status -ceq 'complete') { $status = 'incomplete'; if ($reason -ceq 'complete') { $reason = 'cleanup-failed' } }
                if ($null -ne $rawStream) {
                    try { $rawStream.Dispose() }
                    catch {
                        $cleanupMessage = "outer fallback raw timing backing stream Dispose failed ($($_.Exception.GetType().FullName)): $($_.Exception.Message)"
                        $cleanupErrors.Add($cleanupMessage)
                        if ($null -eq $failureMessage) { $failureMessage = $cleanupMessage }
                        if ($status -ceq 'complete') { $status = 'incomplete'; if ($reason -ceq 'complete') { $reason = 'cleanup-failed' } }
                    }
                }
            }
            finally { $rawWriter = $null; $rawStream = $null }
        }
        if ($moduleStateCaptured) {
            try {
                & $Module {
                    param($Previous)
                    $script:StandardValidationTimingEnabled = $Previous.timingEnabled
                    $script:StandardValidationTimingStage = $Previous.timingStage
                    $script:StandardValidationClosureTiming = $Previous.closureTiming
                    $script:StandardValidationReadObserver = $Previous.readObserver
                } $moduleState
                $restoredState = & $Module {
                    [pscustomobject]@{
                        timingEnabled = $script:StandardValidationTimingEnabled
                        timingStage = $script:StandardValidationTimingStage
                        closureTiming = $script:StandardValidationClosureTiming
                        readObserver = $script:StandardValidationReadObserver
                    }
                }
                $timingStateRestored = [bool]$restoredState.timingEnabled -eq [bool]$moduleState.timingEnabled -and
                    [string]$restoredState.timingStage -ceq [string]$moduleState.timingStage -and
                    [object]::ReferenceEquals($restoredState.closureTiming, $moduleState.closureTiming) -and
                    [object]::ReferenceEquals($restoredState.readObserver, $moduleState.readObserver)
                $moduleStateCaptured = $false
                if (-not $timingStateRestored) {
                    $cleanupMessage = 'Outer fallback module timing state restore readback did not match the four captured values and references.'
                    $cleanupErrors.Add($cleanupMessage)
                    if ($null -eq $failureMessage) { $failureMessage = $cleanupMessage }
                    if ($status -ceq 'complete') { $status = 'incomplete'; if ($reason -ceq 'complete') { $reason = 'cleanup-failed' } }
                }
            }
            catch {
                $timingStateRestored = $false
                $cleanupMessage = "outer fallback module timing state restoration failed ($($_.Exception.GetType().FullName)): $($_.Exception.Message)"
                $cleanupErrors.Add($cleanupMessage)
                if ($null -eq $failureMessage) { $failureMessage = $cleanupMessage }
                if ($status -ceq 'complete') { $status = 'incomplete'; if ($reason -ceq 'complete') { $reason = 'cleanup-failed' } }
            }
        }
        if ($cleanupErrors.Count -gt 0) {
            if ($status -ceq 'complete' -or $status -ceq 'unsupported') { $status = 'incomplete' }
            if ($reason -ceq 'complete') { $reason = 'cleanup-failed' }
            if ($null -eq $failureMessage) { $failureMessage = $cleanupErrors[0] }
            $isComplete = $false
        }
    }

    $tailTimer.Stop()
    if ($null -ne $summaryPath -and -not (Test-Path -LiteralPath $summaryPath -PathType Leaf)) {
        $result = & $newResult $isComplete
        $summary = [ordered]@{}
        foreach ($property in $result.PSObject.Properties) { $summary[$property.Name] = $property.Value }
        $summary['source'] = 'Resident retained receipt measurements from this selected runner/module; noncanonical evidence, distinct from hosted installed-payload proof.'
        & $writeTextCreateNew $summaryPath (($summary | ConvertTo-Json -Depth 30 -Compress) + [Environment]::NewLine)
        return $result
    }
    return (& $newResult $isComplete)
}

function Invoke-AtlassianSourceResidentTiming {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $GitPath,
        [Parameter(Mandatory = $true)][string] $PowerShellPath,
        [Parameter(Mandatory = $true)][string] $RepositoryRoot,
        [Parameter(Mandatory = $true)][string] $CandidateRevision,
        [Parameter(Mandatory = $true)][string] $BaseRevision,
        [Parameter(Mandatory = $true)] $AuthorityConfig,
        [Parameter(Mandatory = $true)][string] $AuthorityRepositoryRoot,
        [Parameter(Mandatory = $true)][string] $SourceToolsPath,
        [Parameter(Mandatory = $true)][string] $RunId,
        [Parameter(Mandatory = $true)][string] $EventName,
        [Parameter(Mandatory = $true)][string] $ArtifactsRoot,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $OutputPath,
        [Parameter(Mandatory = $true)][bool] $ArtifactsRootWasExplicit,
        [Parameter(Mandatory = $true)][string] $ResidentEvidenceRoot,
        [Parameter(Mandatory = $true)][string] $ProtectedBaseRoot,
        [Parameter(Mandatory = $true)][string] $TrustedToolRoot,
        [Parameter(Mandatory = $true)][int] $TimeoutSeconds,
        [string] $CancellationPath
    )

    if ([string]$RunId -cnotmatch '^[0-9a-f]{32}$' -or
        [string]$CandidateRevision -cnotmatch '^[0-9a-f]{40}$' -or
        [string]$BaseRevision -cnotmatch '^[0-9a-f]{40}$' -or
        [string]$EventName -cnotin @('local', 'pre-push', 'pull_request', 'push', 'workflow_dispatch') -or
        $TimeoutSeconds -le 0) {
        throw 'Source resident timing request has an invalid immutable run identity or execution boundary.'
    }
    if ([string]::IsNullOrWhiteSpace($ResidentEvidenceRoot)) {
        throw 'Source resident timing requires a separate create-only evidence root.'
    }

    $pin = Assert-AtlassianSourceAuthorityConfig -Config $AuthorityConfig
    $authority = Assert-AtlassianSourceAuthorityCheckout -GitPath $GitPath -AuthorityRoot $AuthorityRepositoryRoot -AuthorityPin $pin
    $candidateRoot = [IO.Path]::GetFullPath($RepositoryRoot)
    $protectedBaseRoot = [IO.Path]::GetFullPath($ProtectedBaseRoot)
    $preparedPath = [IO.Path]::GetFullPath($SourceToolsPath)
    $preparedHint = Read-JsonFile -Path $preparedPath -Context 'Prepared Atlassian source tools for resident timing'
    $powerShell = [IO.Path]::GetFullPath([string]$preparedHint.pesterRuntime.runtimeExecutablePath)
    $runtimeRoot = [IO.Path]::GetFullPath([string]$preparedHint.pesterRuntime.runtimeRoot)
    $trustedRoot = [IO.Path]::GetFullPath([string]$preparedHint.pesterRuntime.sourceTrustedToolRoot)
    $pathComparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if ([string]$preparedHint.runId -cne $RunId -or [string]$preparedHint.authorityRevision -cne [string]$pin.commit -or
        -not $powerShell.Equals([IO.Path]::GetFullPath($PowerShellPath), $pathComparison) -or
        -not $trustedRoot.Equals([IO.Path]::GetFullPath($TrustedToolRoot), $pathComparison) -or
        -not (Test-Path -LiteralPath $powerShell -PathType Leaf) -or
        (Get-FileSha256 -Path $powerShell) -cne [string]$preparedHint.pesterRuntime.runtimeExecutableSha256 -or
        -not $runtimeRoot.Equals([IO.Path]::GetFullPath((Join-Path ([string]$preparedHint.ownedRoot) 'runtime')), $pathComparison) -or
        -not (Test-PathWithinOrEqual -Path $powerShell -Root $runtimeRoot) -or
        -not (Test-Path -LiteralPath $trustedRoot -PathType Container) -or
        -not (Test-PathWithinOrEqual -Path $powerShell -Root $runtimeRoot)) {
        throw 'Prepared resident timing runtime does not match its exact owned executable, hash and trusted root.'
    }
    [void](Assert-AtlassianSourcePreparedBindings -Prepared $preparedHint -PreparedPath $preparedPath -CandidateRevision $CandidateRevision `
        -PowerShellPath $powerShell -SourceRepository $script:SourceRepository)
    if (-not (Test-Path -LiteralPath $candidateRoot -PathType Container)) { throw 'Source resident candidate root is missing.' }
    if (-not (Test-Path -LiteralPath $protectedBaseRoot -PathType Container)) { throw 'Source resident protected driver base root is missing.' }
    Assert-NoReparseAncestors -Path $candidateRoot -Context 'Source resident candidate root'
    Assert-NoReparseAncestors -Path $protectedBaseRoot -Context 'Source resident protected driver base root'
    Assert-NoReparseAncestors -Path $preparedPath -Context 'Source resident prepared metadata'
    Assert-NoReparseAncestors -Path $runtimeRoot -Context 'Source resident owned runtime'
    Assert-NoReparseAncestors -Path $trustedRoot -Context 'Source resident trusted tool root'

    $artifactsRootPath = [IO.Path]::GetFullPath($ArtifactsRoot)
    $paths = Get-AtlassianSourceCoreRunPaths -ArtifactsRoot $artifactsRootPath -ArtifactsRootWasExplicit $ArtifactsRootWasExplicit `
        -RunId $RunId -OutputPath $OutputPath
    $outputPath = [IO.Path]::GetFullPath($paths.outputPath)
    if ((-not [string]::IsNullOrWhiteSpace($OutputPath) -and -not $outputPath.Equals([IO.Path]::GetFullPath($OutputPath), $pathComparison)) -or
        -not (Test-Path -LiteralPath $paths.artifactsRoot -PathType Container) -or
        -not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
        throw 'Source resident timing canonical report paths are missing or differ from the prepared Core run.'
    }
    foreach ($root in @($candidateRoot, $authority.root, $runtimeRoot, $trustedRoot, [IO.Path]::GetFullPath([string]$preparedHint.ownedRoot))) {
        if ((Test-PathWithinOrEqual -Path $paths.artifactsRoot -Root $root) -or
            (Test-PathWithinOrEqual -Path $root -Root $paths.artifactsRoot)) {
            throw 'Source resident canonical artifacts overlap a protected source or authority root.'
        }
    }
    Assert-NoReparseAncestors -Path $paths.artifactsRoot -Context 'Source resident canonical artifacts root'
    Assert-NoReparseAncestors -Path $outputPath -Context 'Source resident canonical report'

    $report = Read-JsonFile -Path $outputPath -Context 'Accepted Standard Core source report for resident timing'
    $expectedCoreRunRoot = [IO.Path]::GetFullPath((Join-Path (Join-Path $paths.artifactsRoot 'runs') $RunId))
    $reportedCoreRunRoot = if ([string]::IsNullOrWhiteSpace([string]$report.artifacts.runRoot)) { '' } else { [IO.Path]::GetFullPath([string]$report.artifacts.runRoot) }
    if ([string]::IsNullOrWhiteSpace($reportedCoreRunRoot) -or -not $reportedCoreRunRoot.Equals($expectedCoreRunRoot, $pathComparison)) {
        throw 'Source resident timing report does not bind the exact prepared Core run namespace.'
    }
    $timingRoot = Split-Path -Parent $paths.artifactsRoot
    $timingPath = [IO.Path]::GetFullPath((Join-Path $timingRoot "source-validation-timing-$RunId.json"))
    if (-not (Test-Path -LiteralPath $timingPath -PathType Leaf)) { throw 'Source resident canonical timing receipt is missing.' }
    Assert-NoReparseAncestors -Path $timingPath -Context 'Source resident canonical timing receipt'
    $timingEvidence = Read-JsonFile -Path $timingPath -Context 'Source resident canonical timing receipt'
    [void](Assert-AtlassianSourceReportBinding -Report $report -Prepared $preparedHint -CandidateRevision $CandidateRevision `
        -BaseRevision $BaseRevision -AuthorityRevision ([string]$pin.commit) -EventName $EventName `
        -ArtifactsRoot $paths.artifactsRoot -OutputPath $outputPath -ProcessExitCode ([int]$timingEvidence.processExitCode) `
        -CleanupSucceeded ([bool]$timingEvidence.cleanupSucceeded) `
        -CancellationRequested ([bool](-not [string]::IsNullOrWhiteSpace($CancellationPath) -and (Test-Path -LiteralPath $CancellationPath))))
    if ([string]$report.state -cne 'PASS' -or [int]$report.exitCode -ne 0) {
        throw 'Source resident timing requires the canonical accepted report from the exact prepared run.'
    }
    if ([string]$timingEvidence.runId -cne $RunId -or
        [string]$timingEvidence.candidateRevision -cne $CandidateRevision -or
        [string]$timingEvidence.baseRevision -cne $BaseRevision -or
        [string]$timingEvidence.authorityRevision -cne [string]$pin.commit -or
        [int]$timingEvidence.processExitCode -ne 0 -or
        $timingEvidence.reportAccepted -isnot [bool] -or -not $timingEvidence.reportAccepted -or
        $timingEvidence.cleanupSucceeded -isnot [bool] -or -not $timingEvidence.cleanupSucceeded -or
        [double]$timingEvidence.sourceValidationTotalSeconds -lt 0) {
        throw 'Source resident timing receipt does not bind the accepted, cleaned-up prepared run.'
    }

    $caseBinding = $report.sourceValidation.pesterCaseInventory
    if ($null -eq $caseBinding -or [string]::IsNullOrWhiteSpace([string]$caseBinding.path) -or
        [string]$caseBinding.sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Source resident timing report has no exact Pester case ledger binding.'
    }
    $caseLedgerPath = [IO.Path]::GetFullPath([string]$caseBinding.path)
    $coreRunRoot = $reportedCoreRunRoot
    if (-not (Test-PathWithinOrEqual -Path $caseLedgerPath -Root $coreRunRoot) -or
        -not (Test-Path -LiteralPath $caseLedgerPath -PathType Leaf)) {
        throw 'Source resident Pester case ledger is outside the accepted Core run root.'
    }
    Assert-NoReparseAncestors -Path $caseLedgerPath -Context 'Source resident Pester case ledger'
    if ((Get-FileSha256 -Path $caseLedgerPath) -cne [string]$caseBinding.sha256) {
        throw 'Source resident Pester case ledger hash differs from its accepted report binding.'
    }
    $caseLedger = Read-JsonFile -Path $caseLedgerPath -Context 'Source resident Pester case ledger'
    if ([int]$caseLedger.schemaVersion -ne 1 -or [string]$caseLedger.report -cne 'standard-core-pester-case-inventory-v1' -or
        [string]$caseLedger.coreRunId -cne $RunId -or $caseLedger.complete -isnot [bool] -or -not $caseLedger.complete -or
        [string]$caseLedger.terminalStatus -cne 'complete' -or
        @($caseLedger.containerFileInventory).Count -le 0) {
        throw 'Source resident Pester case ledger is incomplete or belongs to a different Core run.'
    }
    $caseCountValues = Get-AtlassianSourceResidentCaseCountValues -CaseLedger $caseLedger
    $reportedCounts = $caseCountValues.reportedCounts
    if ([long]$caseCountValues.caseDiscoveryCount -le 0 -or
        [long]$caseCountValues.caseDiscoveryCount -ne [long]$caseCountValues.caseExecutionCount) {
        throw 'Source resident Pester case ledger is incomplete or belongs to a different Core run.'
    }
    if ([long]$caseCountValues.reportedTotal -ne [long]$caseCountValues.caseExecutionCount) {
        throw 'Source resident Pester case totals differ from the executed case inventory.'
    }
    if ([long]$reportedCounts.Failed -ne 0 -or [long]$reportedCounts.Skipped -ne 0 -or
        [long]$reportedCounts.Inconclusive -ne 0 -or [long]$reportedCounts.NotRun -ne 0 -or
        [long]$reportedCounts.Passed -ne [long]$caseCountValues.caseExecutionCount) {
        throw 'Source resident timing requires every discovered Pester case to pass without skips, inconclusive cases, failures, or not-run cases.'
    }

    $residentRoot = [IO.Path]::GetFullPath($ResidentEvidenceRoot)
    if (-not [IO.Path]::IsPathFullyQualified($ResidentEvidenceRoot)) { throw 'Source resident evidence root must be absolute.' }
    foreach ($root in @($candidateRoot, $protectedBaseRoot, $authority.root, $runtimeRoot, $trustedRoot, [IO.Path]::GetFullPath([string]$preparedHint.ownedRoot), $paths.artifactsRoot)) {
        if ((Test-PathWithinOrEqual -Path $residentRoot -Root $root) -or
            (Test-PathWithinOrEqual -Path $root -Root $residentRoot)) {
            throw 'Source resident timing evidence root overlaps a candidate, authority, owned runtime, or canonical evidence root.'
        }
    }
    if (Test-Path -LiteralPath $residentRoot) { throw 'Source resident timing evidence root already exists; evidence is create-only.' }

    $runnerArguments = [ordered]@{
        CandidateRoot = $candidateRoot
        AdapterPath = [IO.Path]::GetFullPath($paths.adapterPath)
        ArtifactsRoot = [IO.Path]::GetFullPath($paths.artifactsRoot)
        OutputPath = $outputPath
        SourceRepository = $script:SourceRepository
        SourceRevision = $CandidateRevision
        BaseRevision = $BaseRevision
        EventName = $EventName
        RunId = $RunId
        AuthorityRevision = [string]$pin.commit
        TimeoutSeconds = $TimeoutSeconds
        CancellationPath = if ([string]::IsNullOrWhiteSpace($CancellationPath)) { '' } else { [IO.Path]::GetFullPath($CancellationPath) }
        TrustedToolRoot = $trustedRoot
    }
    $runnerModule = $null
    try {
        $runnerModule = New-AtlassianSourceStandardValidationModule -RunnerPath $authority.runnerPath `
            -RunnerSha256 ([string]$pin.files['scripts/Invoke-StandardValidation.ps1']) -RunnerArguments $runnerArguments -SourceValidation
        return Invoke-AtlassianSourceResidentSampleSeries -Module $runnerModule -Prepared $preparedHint -Report $report `
            -TimingEvidence $timingEvidence -CaseLedger $caseLedger -PreparedPath $preparedPath `
            -TimingEvidencePath $timingPath -CaseLedgerPath $caseLedgerPath -AuthorityPin $pin `
            -RunnerPath $authority.runnerPath -RunnerSha256 ([string]$pin.files['scripts/Invoke-StandardValidation.ps1']) `
            -RepositoryRoot $protectedBaseRoot -CandidateRoot $candidateRoot -BaseRevision $BaseRevision `
            -ArtifactsRoot $paths.artifactsRoot -EvidenceRoot $residentRoot -CancellationPath $CancellationPath
    }
    finally {
        if ($null -ne $runnerModule) { Remove-Module -ModuleInfo $runnerModule -Force -ErrorAction Stop }
    }
}


function Convert-JsonElementToPowerShellObject {
    param([Parameter(Mandatory = $true)][System.Text.Json.JsonElement] $Element)

    switch ($Element.ValueKind) {
        ([System.Text.Json.JsonValueKind]::Object) {
            $value = [pscustomobject]@{}
            $propertyNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($property in $Element.EnumerateObject()) {
                if ([string]::IsNullOrEmpty($property.Name) -or -not $propertyNames.Add($property.Name)) {
                    throw "JSON object contains a property name that cannot be represented by a PowerShell object: '$($property.Name)'."
                }
                $propertyValue = Convert-JsonElementToPowerShellObject -Element $property.Value
                $value | Add-Member -MemberType NoteProperty -Name $property.Name -Value $propertyValue -ErrorAction Stop
            }
            return $value
        }
        ([System.Text.Json.JsonValueKind]::Array) {
            $items = [Collections.Generic.List[object]]::new()
            foreach ($item in $Element.EnumerateArray()) {
                $items.Add((Convert-JsonElementToPowerShellObject -Element $item))
            }
            return ,$items.ToArray()
        }
        ([System.Text.Json.JsonValueKind]::String) { return $Element.GetString() }
        ([System.Text.Json.JsonValueKind]::Number) {
            $numberText = $Element.GetRawText()
            return ConvertFrom-Json -InputObject $numberText -Depth 100 -ErrorAction Stop
        }
        ([System.Text.Json.JsonValueKind]::True) { return $true }
        ([System.Text.Json.JsonValueKind]::False) { return $false }
        ([System.Text.Json.JsonValueKind]::Null) { return $null }
        default { throw "Unsupported JSON value kind '$($Element.ValueKind)' for PowerShell conversion." }
    }
}

function Read-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Context is missing: $Path" }
    try {
        $text = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false, $true))
        $document = [System.Text.Json.JsonDocument]::Parse($text)
        try {
            Assert-NoDuplicateJsonProperties -Element $document.RootElement -Context $Context
            $convertFromJson = Get-Command -Name ConvertFrom-Json -CommandType Cmdlet -ErrorAction Stop
            if ($convertFromJson.Parameters.ContainsKey('DateKind')) {
                return $text | ConvertFrom-Json -Depth 100 -DateKind String -ErrorAction Stop
            }
            return Convert-JsonElementToPowerShellObject -Element $document.RootElement
        }
        finally { $document.Dispose() }
    }
    catch { throw "$Context is not valid unambiguous UTF-8 JSON: $($_.Exception.Message)" }
}


function Invoke-AtlassianSourceExceptionGate {
    [CmdletBinding()]
    param(
        [string] $GitPath, [string] $RepositoryRoot, [string] $BaseRevision, [string] $CandidateRevision,
        [string] $ArtifactsRoot, [string] $OutputPath
    )
    if (-not (Test-SkillSpectorExceptionCandidateChange -GitPath $GitPath -RepositoryRoot $RepositoryRoot -BaseRevision $BaseRevision -CandidateRevision $CandidateRevision)) { return $false }
    $root = [IO.Path]::GetFullPath($ArtifactsRoot)
    Assert-OutsideRoot -Path $root -Root $RepositoryRoot -Context 'Source exception evidence'
    [void][IO.Directory]::CreateDirectory($root)
    Assert-NoReparseAncestors -Path $root -Context 'Source exception evidence'
    $path = if ([string]::IsNullOrWhiteSpace($OutputPath)) { Join-Path $root "source-exception-blocked-$([guid]::NewGuid().ToString('N')).json" }
        else { Assert-PathWithinRoot -Path $OutputPath -Root $root -Context 'Source exception OutputPath' }
    $evidence = [ordered]@{
        schemaVersion = 1; report = 'atlassian-source-exception-gate-v1'
        state = 'BLOCKED'; exitCode = 10; releaseEligible = $false
        sourceRevision = $CandidateRevision; baseRevision = $BaseRevision
        message = 'SkillSpector exception candidates changed; human approval and semantic review are required before source validation can pass.'
    }
    Write-Utf8NoBomCreateNew -Path $path -Text (($evidence | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
    [Console]::Out.WriteLine(($evidence | ConvertTo-Json -Compress))
    [Console]::Error.WriteLine("BLOCKED evidence: $path")
    return $true
}

function Invoke-AtlassianSourceDriver {
    [CmdletBinding()]
    param(
        [string] $RepositoryRoot, [string] $ArtifactsRoot, [string] $OutputPath, [string] $BaseCommit,
        [int] $AdapterVersion = 1, [switch] $PrepareSourceTools, [switch] $SourceValidation,
        [switch] $SourceResidentTiming, [string] $SourceToolsPath, [string] $AuthorityRepositoryRoot,
        [string] $TrustedToolRoot, [string] $CancellationPath, [string] $ResidentEvidenceRoot,
        [string] $ExpectedGoRuntimeVersion, [int] $TimeoutSeconds = 900, [bool] $ArtifactsRootWasExplicit = $true
    )
    if (-not $IsWindows -or $PSVersionTable.PSVersion.Major -lt 7) { throw 'Core source validation requires Windows with PowerShell 7.' }
    if (@(@($PrepareSourceTools, $SourceValidation, $SourceResidentTiming) | Where-Object { [bool]$_ }).Count -ne 1 -or
        $AdapterVersion -ne 2 -or [string]::IsNullOrWhiteSpace($SourceToolsPath) -or
        [string]::IsNullOrWhiteSpace($AuthorityRepositoryRoot) -or $TimeoutSeconds -le 0) {
        throw 'Select exactly one source mode with AdapterVersion 2, SourceToolsPath, AuthorityRepositoryRoot and a positive timeout.'
    }
    if (-not $SourceResidentTiming -and -not [string]::IsNullOrWhiteSpace($ResidentEvidenceRoot)) { throw 'ResidentEvidenceRoot requires SourceResidentTiming.' }
    $repoRoot = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) { Split-Path -Parent $PSScriptRoot } else { [IO.Path]::GetFullPath($RepositoryRoot) }
    $git = Get-ResolvedGitPath
    $candidate = Resolve-GitRevision -GitPath $git -Root $repoRoot -Revision 'HEAD' -Context 'Candidate revision'
    $dirty = @(& $git -C $repoRoot status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0 -or $dirty.Count -ne 0) { throw 'Core source validation requires a clean immutable candidate commit.' }
    $config = Read-JsonFile -Path (Join-Path $repoRoot 'config/standard-v1.json') -Context 'config/standard-v1.json'
    $pin = Assert-AtlassianSourceAuthorityConfig -Config $config
    [void](Get-ActiveSkillIds -Root $repoRoot)
    $hint = $null
    if (-not $PrepareSourceTools) { $hint = Read-JsonFile -Path $SourceToolsPath -Context 'prepared Atlassian source tools' }
    if ($SourceResidentTiming) {
        [void](Assert-AtlassianSourceResidentRunRequest -SourceResidentTiming -SourceToolsPath $SourceToolsPath -AdapterVersion $AdapterVersion -AuthorityRevision $pin.commit -RunId ([string]$hint.runId))
    }
    else {
        [void](Assert-AtlassianSourceRunRequest -PrepareSourceTools:$PrepareSourceTools -SourceValidation:$SourceValidation -SourceToolsPath $SourceToolsPath -AdapterVersion $AdapterVersion -AuthorityCommit $pin.commit -RunId $(if ($null -eq $hint) { '' } else { [string]$hint.runId }))
    }
    if ($PrepareSourceTools) {
        Invoke-AtlassianSourceToolSetup -GitPath $git -PowerShellPath (Get-ResolvedPowerShellPath) -RepositoryRoot $repoRoot -CandidateRevision $candidate -AuthorityConfig $config -SourceToolsPath $SourceToolsPath -AuthorityRepositoryRoot $AuthorityRepositoryRoot -TrustedToolRoot $TrustedToolRoot -ExpectedGoRuntimeVersion $ExpectedGoRuntimeVersion -TimeoutSeconds $TimeoutSeconds | Out-Host
        return 0
    }
    $event = Get-EventName
    # Preserve v1's HEAD^ default and explicit pre-push base requirement.
    $baseInput = Resolve-SourceComparisonBaseInput -BaseCommit $BaseCommit -EventName $event
    $base = Resolve-GitRevision -GitPath $git -Root $repoRoot -Revision $baseInput -Context 'Base commit'
    & $git -C $repoRoot merge-base --is-ancestor $base $candidate
    if ($LASTEXITCODE -ne 0 -or $base -ceq $candidate) { throw 'Base commit must be a distinct ancestor of the immutable candidate.' }
    if (Invoke-AtlassianSourceExceptionGate -GitPath $git -RepositoryRoot $repoRoot -BaseRevision $base -CandidateRevision $candidate -ArtifactsRoot $ArtifactsRoot -OutputPath $OutputPath) { return 10 }
    $arguments = @{
        GitPath = $git; PowerShellPath = [string]$hint.pesterRuntime.runtimeExecutablePath
        RepositoryRoot = $repoRoot; CandidateRevision = $candidate; BaseRevision = $base; AuthorityConfig = $config
        SourceToolsPath = $SourceToolsPath; AuthorityRepositoryRoot = $AuthorityRepositoryRoot; TrustedToolRoot = $TrustedToolRoot
        ArtifactsRoot = $ArtifactsRoot; OutputPath = $OutputPath; EventName = $event; TimeoutSeconds = $TimeoutSeconds
        ArtifactsRootWasExplicit = $ArtifactsRootWasExplicit; CancellationPath = $CancellationPath
    }
    if ($SourceResidentTiming) {
        $arguments.RunId = [string]$hint.runId
        $arguments.ResidentEvidenceRoot = $ResidentEvidenceRoot
        $arguments.ProtectedBaseRoot = Split-Path -Parent $PSScriptRoot
        $result = Invoke-AtlassianSourceResidentTiming @arguments
        if ([string]$result.status -notin @('complete', 'unsupported')) { throw 'Source resident timing did not complete.' }
        $result | ConvertTo-Json -Depth 20 | Out-Host
    }
    else { Invoke-AtlassianSourceValidation @arguments | Out-Host }
    return 0
}

Export-ModuleMember -Function Get-PreparedSourceAuthorityPin, Assert-AtlassianSourceAuthorityConfig, Assert-AtlassianSourceRunRequest, New-AtlassianSourceFrozenFileInventory, Assert-AtlassianSourceProtectedDispatchFiles, Assert-AtlassianSourceProtectedRuntimeCopies, Assert-AtlassianSourcePreparedBindings, Assert-AtlassianSourceAuthorityToolchain, Assert-AtlassianSourceReportBinding, New-AtlassianCoreAdapterV2, Invoke-AtlassianSourceToolSetup, Invoke-AtlassianSourceValidation, Invoke-AtlassianSourceExceptionGate, Invoke-AtlassianSourceDriver
