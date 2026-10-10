# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'StrictJson.psm1') -Force -Scope Local

function Get-RuntimeHash {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-RuntimeNoReparse {
    param([string]$Path)
    $current=[IO.Path]::GetFullPath($Path)
    while(-not [string]::IsNullOrWhiteSpace($current)){
        if(Test-Path -LiteralPath $current){
            $item=Get-Item -LiteralPath $current -Force
            if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'RuntimeReparsePoint'}
        }
        $parent=[IO.Path]::GetDirectoryName($current.TrimEnd('\','/'))
        if($parent -ceq $current){break}
        $current=$parent
    }
}

function Get-RuntimeInventory {
    param([string]$Root)
    $full=[IO.Path]::GetFullPath($Root)
    if(-not(Test-Path -LiteralPath $full -PathType Container)){throw 'RuntimeUnavailable'}
    Assert-RuntimeNoReparse $full
    $pending=[System.Collections.Generic.Queue[string]]::new()
    $pending.Enqueue($full)
    $files=[System.Collections.Generic.List[object]]::new()
    while($pending.Count -gt 0){
        foreach($item in @(Get-ChildItem -LiteralPath $pending.Dequeue() -Force)){
            if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'RuntimeReparsePoint'}
            if($item.PSIsContainer){$pending.Enqueue($item.FullName);continue}
            $relative=[IO.Path]::GetRelativePath($full,$item.FullName).Replace('\','/')
            if($relative.StartsWith('../',[StringComparison]::Ordinal) -or [IO.Path]::IsPathRooted($relative)){throw 'RuntimePathInvalid'}
            $files.Add([ordered]@{path=$relative;byteLength=[long]$item.Length;sha256=Get-RuntimeHash $item.FullName})
            if($files.Count -gt 20000){throw 'RuntimeInventoryTooLarge'}
        }
    }
    $files.Sort([System.Comparison[object]]{
        param($left,$right)
        return [StringComparer]::Ordinal.Compare([string]$left['path'],[string]$right['path'])
    })
    return @($files.ToArray())
}

function Get-RuntimeVersions {
    param([string]$Root)
    $versions=[ordered]@{}
    foreach($package in @(@{name='openspec';path='@fission-ai/openspec';version='1.13.0'},@{name='markdownIt';path='markdown-it';version='14.3.1'})){
        $metadata=Read-Syp171StrictJsonFile -Path (Join-Path $Root ('node_modules/' + $package.path + '/package.json')) -Depth 20
        if([string]$metadata.version -cne $package.version){throw 'RuntimeVersionMismatch'}
        $versions[$package.name]=$package.version
    }
    if(-not(Test-Path -LiteralPath (Join-Path $Root 'node_modules/@fission-ai/openspec/bin/openspec.js') -PathType Leaf)){throw 'RuntimeValidatorUnavailable'}
    return $versions
}

function New-ConfluenceDocsRuntimeReceipt {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RuntimeRoot,[Parameter(Mandatory)][string]$RuntimeSourceRoot,
        [Parameter(Mandatory)][ValidatePattern('^v24\.[0-9]+\.[0-9]+$')][string]$NodeVersion,
        [Parameter(Mandatory)][ValidatePattern('^11\.[0-9]+\.[0-9]+$')][string]$NpmVersion)
    $full=[IO.Path]::GetFullPath($RuntimeRoot)
    $files=@(Get-RuntimeInventory $full)
    $versions=Get-RuntimeVersions $full
    foreach($name in @('package.json','package-lock.json')){
        if((Get-RuntimeHash (Join-Path $full $name)) -cne (Get-RuntimeHash (Join-Path $RuntimeSourceRoot $name))){throw 'RuntimeSourceChanged'}
    }
    $node=Join-Path $full 'node/node.exe'
    if(-not(Test-Path -LiteralPath $node -PathType Leaf)){throw 'RuntimeNodeUnavailable'}
    return [ordered]@{schemaVersion=1;artifactType='confluence-docs-runtime-receipt-v1';createdAtUtc=[DateTime]::UtcNow.ToString('o');
        runtimeRoot=$full;nodeVersion=$NodeVersion;npmVersion=$NpmVersion;sourcePackageSha256=Get-RuntimeHash (Join-Path $full 'package.json');
        sourceLockSha256=Get-RuntimeHash (Join-Path $full 'package-lock.json');nodePath='node/node.exe';nodeSha256=Get-RuntimeHash $node;
        versions=$versions;files=$files}
}

function New-RuntimeResult {
    param([string]$Code)
    return [pscustomobject]@{status='invalid';reasonCodes=@($Code);runtimeRoot='';nodePath='';fileCount=0}
}

function Test-ConfluenceDocsRuntimeReceipt {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ReceiptPath,[Parameter(Mandatory)][string]$ReceiptSha256,
        [Parameter(Mandatory)][string]$RuntimeSourceRoot)
    if(-not(Test-Path -LiteralPath $ReceiptPath -PathType Leaf)){return New-RuntimeResult 'RuntimeReceiptUnavailable'}
    try{
        Assert-RuntimeNoReparse $ReceiptPath
        if($ReceiptSha256 -cnotmatch '^[a-f0-9]{64}$' -or (Get-RuntimeHash $ReceiptPath) -cne $ReceiptSha256){return New-RuntimeResult 'RuntimeReceiptChanged'}
        if((Get-Item -LiteralPath $ReceiptPath).Length -gt 4MB){return New-RuntimeResult 'RuntimeReceiptInvalid'}
        $receipt=Read-Syp171StrictJsonFile -Path $ReceiptPath -Depth 12
        if(-not(Test-Syp171JsonKeys $receipt @('schemaVersion','artifactType','createdAtUtc','runtimeRoot','nodeVersion','npmVersion','sourcePackageSha256','sourceLockSha256','nodePath','nodeSha256','versions','files')) -or
            $receipt.schemaVersion -isnot [long] -and $receipt.schemaVersion -isnot [int] -or $receipt.schemaVersion -ne 1 -or
            $receipt.artifactType -cne 'confluence-docs-runtime-receipt-v1' -or [string]$receipt.nodeVersion -cnotmatch '^v24\.[0-9]+\.[0-9]+$' -or
            [string]$receipt.npmVersion -cnotmatch '^11\.[0-9]+\.[0-9]+$' -or [string]$receipt.nodePath -cne 'node/node.exe' -or
            -not [IO.Path]::IsPathFullyQualified([string]$receipt.runtimeRoot) -or
            -not(Test-Syp171JsonKeys $receipt.versions @('openspec','markdownIt')) -or
            $receipt.versions.openspec -cne '1.13.0' -or $receipt.versions.markdownIt -cne '14.3.1' -or
            $receipt.files -isnot [array] -or @($receipt.files).Count -eq 0 -or @($receipt.files).Count -gt 20000){return New-RuntimeResult 'RuntimeReceiptInvalid'}
        foreach($field in @('sourcePackageSha256','sourceLockSha256','nodeSha256')){
            if([string]$receipt[$field] -cnotmatch '^[a-f0-9]{64}$'){return New-RuntimeResult 'RuntimeReceiptInvalid'}
        }
        $seen=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($file in @($receipt.files)){
            if(-not(Test-Syp171JsonKeys $file @('path','byteLength','sha256')) -or
                [string]$file.path -cnotmatch '^(?!/)(?![A-Za-z]:)(?!.*(?:^|/)\.\.?(/|$))[^\\\r\n:]+$' -or
                -not $seen.Add([string]$file.path) -or
                ($file.byteLength -isnot [long] -and $file.byteLength -isnot [int]) -or [long]$file.byteLength -lt 0 -or
                [string]$file.sha256 -cnotmatch '^[a-f0-9]{64}$'){return New-RuntimeResult 'RuntimeReceiptInvalid'}
        }
        if((Get-RuntimeHash (Join-Path $RuntimeSourceRoot 'package.json')) -cne $receipt.sourcePackageSha256 -or
            (Get-RuntimeHash (Join-Path $RuntimeSourceRoot 'package-lock.json')) -cne $receipt.sourceLockSha256){return New-RuntimeResult 'RuntimeSourceChanged'}
        $actual=@(Get-RuntimeInventory $receipt.runtimeRoot)
        if($actual.Count -ne @($receipt.files).Count){return New-RuntimeResult 'RuntimeClosureChanged'}
        for($i=0;$i -lt $actual.Count;$i++){
            $record=$receipt.files[$i];$file=$actual[$i]
            if($record.path -cne $file.path -or $record.sha256 -cne $file.sha256 -or [long]$record.byteLength -ne $file.byteLength){return New-RuntimeResult 'RuntimeClosureChanged'}
        }
        if((Get-RuntimeHash (Join-Path $receipt.runtimeRoot 'package.json')) -cne $receipt.sourcePackageSha256 -or
            (Get-RuntimeHash (Join-Path $receipt.runtimeRoot 'package-lock.json')) -cne $receipt.sourceLockSha256 -or
            (Get-RuntimeHash (Join-Path $receipt.runtimeRoot 'node/node.exe')) -cne $receipt.nodeSha256){return New-RuntimeResult 'RuntimeClosureChanged'}
        $null=Get-RuntimeVersions $receipt.runtimeRoot
        return [pscustomobject]@{status='valid';reasonCodes=@();runtimeRoot=[string]$receipt.runtimeRoot;
            nodePath=(Join-Path $receipt.runtimeRoot 'node/node.exe');fileCount=$actual.Count;nodeVersion=$receipt.nodeVersion;npmVersion=$receipt.npmVersion}
    }catch{
        $code=if($_.Exception.Message -ceq 'RuntimeReparsePoint'){'RuntimeReparsePoint'}elseif($_.Exception.Message -ceq 'RuntimeVersionMismatch'){'RuntimeVersionMismatch'}else{'RuntimeReceiptInvalid'}
        return New-RuntimeResult $code
    }
}

Export-ModuleMember -Function New-ConfluenceDocsRuntimeReceipt,Test-ConfluenceDocsRuntimeReceipt
