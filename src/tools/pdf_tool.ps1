[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$InputFiles,
    [switch]$LibraryMode,
    [switch]$NoPrompt,
    [string]$QpdfPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function New-ProcessResult {
    param(
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][string]$InputPath,
        [string]$OutputPath = '',
        [Parameter(Mandatory)][string]$Message,
        [string]$Details = ''
    )

    [pscustomobject]@{
        IsValid   = $Status -eq 'Valid'
        Status    = $Status
        InputPath = $InputPath
        OutputPath = $OutputPath
        Message   = $Message
        Details   = $Details
    }
}

function Test-PdfInputPath {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return New-ProcessResult -Status 'Skipped' -InputPath $Path -Message '文件不存在或已被移动。'
    }

    if ([IO.Path]::GetExtension($Path) -ine '.pdf') {
        return New-ProcessResult -Status 'Skipped' -InputPath $Path -Message '不是 PDF 文件。'
    }

    $fullPath = [IO.Path]::GetFullPath($Path)
    return New-ProcessResult -Status 'Valid' -InputPath $fullPath -Message '输入有效。'
}

function Get-UniqueOutputPath {
    param([Parameter(Mandatory)][string]$InputPath)

    $fullPath = [IO.Path]::GetFullPath($InputPath)
    $directory = [IO.Path]::GetDirectoryName($fullPath)
    $stem = [IO.Path]::GetFileNameWithoutExtension($fullPath)
    $candidate = Join-Path $directory "${stem}_可注释.pdf"
    $index = 2

    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $directory "${stem}_可注释_${index}.pdf"
        $index++
    }

    return $candidate
}
