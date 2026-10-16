# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest

function Test-Syp171JsonKeys {
    param([object]$Value,[string[]]$Expected)
    if($Value -isnot [System.Collections.IDictionary]){return $false}
    return (($Value.Keys|Sort-Object)-join ',') -ceq (($Expected|Sort-Object)-join ',')
}

function Test-Syp171JsonInteger {
    param([object]$Value,[long]$Minimum=0)
    return ($Value -is [int] -or $Value -is [long]) -and [long]$Value -ge $Minimum
}

function Test-Syp171DuplicateJsonProperty {
    param([System.Text.Json.JsonElement]$Element)
    if($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object){
        $seen=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach($property in $Element.EnumerateObject()){
            if(-not $seen.Add($property.Name) -or (Test-Syp171DuplicateJsonProperty -Element $property.Value)){return $true}
        }
    }elseif($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array){
        foreach($child in $Element.EnumerateArray()){
            if(Test-Syp171DuplicateJsonProperty -Element $child){return $true}
        }
    }
    return $false
}

function ConvertFrom-Syp171StrictJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Json,
        [ValidateRange(2,100)][int]$Depth=30
    )
    if([string]::IsNullOrWhiteSpace($Json)){throw 'JsonEmpty'}
    $options=[System.Text.Json.JsonDocumentOptions]::new()
    $options.AllowTrailingCommas=$false
    $options.CommentHandling=[System.Text.Json.JsonCommentHandling]::Disallow
    $options.MaxDepth=$Depth
    $document=[System.Text.Json.JsonDocument]::Parse($Json,$options)
    try{
        if(Test-Syp171DuplicateJsonProperty -Element $document.RootElement){throw 'DuplicateJsonKey'}
    }finally{$document.Dispose()}
    return $Json|ConvertFrom-Json -AsHashtable -Depth $Depth -ErrorAction Stop
}

function Read-Syp171StrictJsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateRange(1,67108864)][long]$MaximumBytes=33554432,
        [ValidateRange(2,100)][int]$Depth=30
    )
    $full=[IO.Path]::GetFullPath($Path)
    if(-not(Test-Path -LiteralPath $full -PathType Leaf)){throw 'JsonFileUnavailable'}
    $bytes=[IO.File]::ReadAllBytes($full)
    if($bytes.Length -gt $MaximumBytes){throw 'JsonFileTooLarge'}
    $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)
    return ConvertFrom-Syp171StrictJson -Json $text -Depth $Depth
}

Export-ModuleMember -Function ConvertFrom-Syp171StrictJson,Read-Syp171StrictJsonFile,Test-Syp171JsonKeys,Test-Syp171JsonInteger
