# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$MappingPath,
    [Parameter(Mandatory)][string]$DocsCommit,
    [Parameter(Mandatory)][string]$CodeBindingPath,
    [Parameter(Mandatory)][string]$ReviewPath,
    [Parameter(Mandatory)][string]$RuntimeRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'ConfluenceValidation.psm1') -Force
try{$result=Invoke-ConfluenceValidation -Root $Root -MappingPath $MappingPath -DocsCommit $DocsCommit -CodeBindingPath $CodeBindingPath -ReviewPath $ReviewPath -RuntimeRoot $RuntimeRoot}
catch{$result=[pscustomobject]@{status='failed';reasonCodes=@('ValidationFailure');publishEligibility='blocked'}}
$result|ConvertTo-Json -Depth 12
exit $(switch($result.status){'valid'{0}'blocked'{10}'invalid'{30}default{20}})
