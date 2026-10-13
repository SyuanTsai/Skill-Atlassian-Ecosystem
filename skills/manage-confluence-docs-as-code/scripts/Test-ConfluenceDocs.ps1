# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$MappingPath,
    [Parameter(Mandatory)][string]$DocsCommit,
    [string]$CodeBindingPath,
    [string]$ReviewPath,
    [string]$CodeReviewPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'ConfluenceValidation.psm1') -Force
try{$result=Invoke-ConfluenceValidation -Root $Root -MappingPath $MappingPath -DocsCommit $DocsCommit -CodeBindingPath $CodeBindingPath -ReviewPath $ReviewPath -CodeReviewPath $CodeReviewPath}
catch{$result=[pscustomobject]@{status='failed';reasonCodes=@('ValidationFailure')}}
$result|ConvertTo-Json -Depth 12
exit $(switch($result.status){'valid'{0}'blocked'{10}'invalid'{30}default{20}})
