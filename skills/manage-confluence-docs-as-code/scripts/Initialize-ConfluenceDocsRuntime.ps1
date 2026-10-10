# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

#Requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RuntimeRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not $IsWindows){throw 'RuntimeSetupRequiresWindows'}
$full=[IO.Path]::GetFullPath($RuntimeRoot)
$receiptPath="$full.receipt.json"
if(Test-Path -LiteralPath $full){
    $item=Get-Item -LiteralPath $full -Force
    if(-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        @(Get-ChildItem -LiteralPath $full -Force).Count -gt 0){throw 'RuntimeRootNotEmpty'}
}
if(Test-Path -LiteralPath $receiptPath){throw 'RuntimeReceiptAlreadyExists'}
$parent=[IO.Path]::GetDirectoryName($full)
if(-not(Test-Path -LiteralPath $parent -PathType Container)){throw 'RuntimeParentUnavailable'}
$ancestor=$parent
while(-not [string]::IsNullOrWhiteSpace($ancestor)){
    if(((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'RuntimeReparsePoint'}
    $ancestor=[IO.Path]::GetDirectoryName($ancestor.TrimEnd('\','/'))
}

Import-Module (Join-Path $PSScriptRoot 'ConfluenceRuntime.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'StrictJson.psm1') -Force
$sourceRoot=$PSScriptRoot
$lock=Read-Syp171StrictJsonFile -Path (Join-Path $sourceRoot 'package-lock.json') -Depth 30
if($lock.lockfileVersion -ne 3){throw 'RuntimeLockUnsupported'}
foreach($key in $lock.packages.Keys){
    if($key -ceq ''){continue}
    $package=$lock.packages[$key]
    if([string]$package.resolved -cnotmatch '^https://registry\.npmjs\.org/[^?#]+$' -or
        [string]$package.integrity -cnotmatch '^sha512-[A-Za-z0-9+/]+={0,2}$'){throw 'RuntimeLockSourceUnsupported'}
}
$nodeSource=(Get-Command node -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source
$npmCommand=Get-Command npm -ErrorAction Stop|Select-Object -First 1
$npmSource=Join-Path (Split-Path -Parent $npmCommand.Source) 'node_modules/npm'
if(-not(Test-Path -LiteralPath (Join-Path $npmSource 'bin/npm-cli.js') -PathType Leaf)){throw 'RuntimeNpmUnavailable'}
$nodeSourceHash=(Get-FileHash -LiteralPath $nodeSource -Algorithm SHA256).Hash.ToLowerInvariant()
$setupRoot=Join-Path $parent "$([IO.Path]::GetFileName($full)).setup-$([Guid]::NewGuid().ToString('N'))"
$null=New-Item -ItemType Directory -Path (Join-Path $full 'node') -Force
$null=New-Item -ItemType Directory -Path $setupRoot
Copy-Item -LiteralPath $nodeSource -Destination (Join-Path $full 'node/node.exe')
Copy-Item -LiteralPath $npmSource -Destination (Join-Path $full 'node/npm') -Recurse
foreach($name in @('package.json','package-lock.json')){Copy-Item -LiteralPath (Join-Path $sourceRoot $name) -Destination (Join-Path $full $name)}
$nodePath=Join-Path $full 'node/node.exe'
if((Get-FileHash -LiteralPath $nodePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $nodeSourceHash){throw 'RuntimeNodeCopyChanged'}
$npmCli=Join-Path $full 'node/npm/bin/npm-cli.js'
$userConfig=Join-Path $setupRoot 'user.npmrc'
$globalConfig=Join-Path $setupRoot 'global.npmrc'
foreach($path in @($userConfig,$globalConfig)){[IO.File]::WriteAllText($path,'',[Text.UTF8Encoding]::new($false))}

function Invoke-IsolatedRuntimeTool {
    param([string[]]$Arguments,[int]$TimeoutSeconds=300)
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$nodePath
    foreach($argument in $Arguments){$start.ArgumentList.Add($argument)}
    $start.WorkingDirectory=$full
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $start.Environment.Clear()
    foreach($name in @('PATH','Path','SystemRoot','WINDIR','COMSPEC','TEMP','TMP','PATHEXT')){
        $value=[Environment]::GetEnvironmentVariable($name,'Process')
        if(-not [string]::IsNullOrWhiteSpace($value)){$start.Environment[$name]=$value}
    }
    $start.Environment['CI']='1'
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start
    try{
        if(-not $process.Start()){throw 'RuntimeSetupProcessFailed'}
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit($TimeoutSeconds*1000)){$process.Kill($true);throw 'RuntimeSetupTimeout'}
        $output=$stdout.GetAwaiter().GetResult();$errors=$stderr.GetAwaiter().GetResult()
        if($output.Length -gt 4MB -or $errors.Length -gt 4MB){throw 'RuntimeSetupOutputTooLarge'}
        if($process.ExitCode -ne 0){
            [IO.File]::WriteAllText((Join-Path $setupRoot 'failure.txt'),$errors,[Text.UTF8Encoding]::new($false))
            throw ('RuntimeSetupProcessFailed:' + [string]$process.ExitCode)
        }
        return $output.Trim()
    }finally{$process.Dispose()}
}

$nodeVersion=Invoke-IsolatedRuntimeTool -Arguments @('--version')
$npmVersion=Invoke-IsolatedRuntimeTool -Arguments @($npmCli,'--version')
if($nodeVersion -cnotmatch '^v24\.[0-9]+\.[0-9]+$' -or $npmVersion -cnotmatch '^11\.[0-9]+\.[0-9]+$'){throw 'RuntimeVersionMismatch'}
$installOutput=Invoke-IsolatedRuntimeTool -Arguments @($npmCli,'ci','--ignore-scripts','--no-bin-links','--no-audit','--no-fund',
    '--registry=https://registry.npmjs.org/',"--userconfig=$userConfig","--globalconfig=$globalConfig","--cache=$(Join-Path $setupRoot 'cache')")
[IO.File]::WriteAllText((Join-Path $setupRoot 'npm-ci.txt'),$installOutput+"`n",[Text.UTF8Encoding]::new($false))
$receipt=New-ConfluenceDocsRuntimeReceipt -RuntimeRoot $full -RuntimeSourceRoot $sourceRoot -NodeVersion $nodeVersion -NpmVersion $npmVersion
[IO.File]::WriteAllText($receiptPath,($receipt|ConvertTo-Json -Depth 12)+"`n",[Text.UTF8Encoding]::new($false))
$receiptSha256=(Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
$verified=Test-ConfluenceDocsRuntimeReceipt -ReceiptPath $receiptPath -ReceiptSha256 $receiptSha256 -RuntimeSourceRoot $sourceRoot
if($verified.status -cne 'valid'){throw ($verified.reasonCodes -join ',')}
[ordered]@{status='ready';runtimeRoot=$full;receiptPath=$receiptPath;receiptSha256=$receiptSha256;nodeVersion=$nodeVersion;
    npmVersion=$npmVersion;fileCount=$verified.fileCount;setupEvidenceRoot=$setupRoot}|ConvertTo-Json
