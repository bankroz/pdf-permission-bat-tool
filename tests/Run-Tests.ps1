[CmdletBinding()]
param(
    [switch]$DeliverySmokeTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $projectRoot 'src\tools\pdf_tool.ps1'
. $scriptPath -LibraryMode

$script:passed = 0
$script:failed = 0

function Assert-Equal {
    param([object]$Expected, [object]$Actual, [string]$Name)

    if ($Expected -eq $Actual) {
        $script:passed++
        Write-Host "PASS $Name" -ForegroundColor Green
        return
    }

    $script:failed++
    Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red
}

function Assert-True {
    param([bool]$Value, [string]$Name)
    Assert-Equal -Expected $true -Actual $Value -Name $Name
}

$scratch = Join-Path $projectRoot 'tests\tmp\unit'
if (Test-Path -LiteralPath $scratch) {
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $scratch | Out-Null

$input = Join-Path $scratch '中文 & 文件!.pdf'
[IO.File]::WriteAllBytes($input, [byte[]](1, 2, 3))

$first = Get-UniqueOutputPath -InputPath $input
Assert-Equal -Expected (Join-Path $scratch '中文 & 文件!_可注释.pdf') -Actual $first -Name 'first output name'

[IO.File]::WriteAllBytes($first, [byte[]](1))
$second = Get-UniqueOutputPath -InputPath $input
Assert-Equal -Expected (Join-Path $scratch '中文 & 文件!_可注释_2.pdf') -Actual $second -Name 'numbered output name'

$valid = Test-PdfInputPath -Path $input
Assert-True -Value $valid.IsValid -Name 'valid PDF path accepted'

$wrong = Join-Path $scratch 'not-pdf.txt'
Set-Content -LiteralPath $wrong -Value 'x'
$invalid = Test-PdfInputPath -Path $wrong
Assert-Equal -Expected 'Skipped' -Actual $invalid.Status -Name 'non-PDF skipped'

$missing = Test-PdfInputPath -Path (Join-Path $scratch 'missing.pdf')
Assert-Equal -Expected 'Skipped' -Actual $missing.Status -Name 'missing file skipped'

if ($script:failed -gt 0) {
    throw "$script:failed tests failed"
}

Write-Host "$script:passed tests passed" -ForegroundColor Cyan
