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

$powerShellBytes = [IO.File]::ReadAllBytes($scriptPath)
$hasUtf8Bom = ($powerShellBytes.Length -ge 3) -and
    ($powerShellBytes[0] -eq 0xEF) -and
    ($powerShellBytes[1] -eq 0xBB) -and
    ($powerShellBytes[2] -eq 0xBF)
Assert-True -Value $hasUtf8Bom -Name 'PowerShell source uses UTF-8 BOM'

$launcherPath = Join-Path $projectRoot 'src\PDF权限处理工具.bat'
$launcherExists = Test-Path -LiteralPath $launcherPath -PathType Leaf
Assert-True -Value $launcherExists -Name 'BAT launcher exists'
if ($launcherExists) {
    $launcherBytes = [IO.File]::ReadAllBytes($launcherPath)
    Assert-True -Value (-not ($launcherBytes | Where-Object { $_ -gt 0x7F })) -Name 'BAT launcher contains ASCII bytes only'
    $launcherHasUtf8Bom = ($launcherBytes.Length -ge 3) -and
        ($launcherBytes[0] -eq 0xEF) -and
        ($launcherBytes[1] -eq 0xBB) -and
        ($launcherBytes[2] -eq 0xBF)
    $launcherText = [Text.Encoding]::ASCII.GetString($launcherBytes)
    Assert-True -Value (-not $launcherHasUtf8Bom) -Name 'BAT launcher has no BOM'
    Assert-True -Value ($launcherText -notmatch '(?im)^\s*chcp\b') -Name 'BAT launcher does not switch code page'
    Assert-True -Value ($launcherText -notmatch '(?i)enabledelayedexpansion') -Name 'BAT launcher avoids delayed expansion'
}

$qpdf = Get-ChildItem -LiteralPath (Join-Path $projectRoot 'vendor') -Filter qpdf.exe -Recurse -File |
    Select-Object -First 1
if (-not $qpdf) {
    throw 'Run scripts/Fetch-Qpdf.ps1 first.'
}

$integration = Join-Path $projectRoot 'tests\tmp\integration 中文 &!'
if (Test-Path -LiteralPath $integration) {
    Remove-Item -LiteralPath $integration -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $integration | Out-Null

$plain = Join-Path $integration '普通 文件.pdf'
& $qpdf.FullName '--empty' $plain
Assert-Equal -Expected 0 -Actual $LASTEXITCODE -Name 'create plain fixture'
$plainHashBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $plain).Hash
$plainTimeBefore = (Get-Item -LiteralPath $plain).LastWriteTimeUtc

$plainResult = Invoke-PdfCopy -InputPath $plain -QpdfPath $qpdf.FullName
Assert-Equal -Expected 'Success' -Actual $plainResult.Status -Name 'plain PDF processed'
Assert-True -Value (Test-Path -LiteralPath $plainResult.OutputPath) -Name 'plain output exists'
Assert-Equal -Expected $plainHashBefore -Actual (Get-FileHash -Algorithm SHA256 -LiteralPath $plain).Hash -Name 'plain input hash unchanged'
Assert-Equal -Expected $plainTimeBefore -Actual (Get-Item -LiteralPath $plain).LastWriteTimeUtc -Name 'plain input timestamp unchanged'

$restricted = Join-Path $integration '限制注释.pdf'
& $qpdf.FullName '--encrypt' '--owner-password=owner-secret' '--bits=256' '--modify=none' '--annotate=n' '--' $plain $restricted
Assert-Equal -Expected 0 -Actual $LASTEXITCODE -Name 'create restricted fixture'
$restrictedResult = Invoke-PdfCopy -InputPath $restricted -QpdfPath $qpdf.FullName
Assert-True -Value ($restrictedResult.Status -in @('Success', 'Warning')) -Name 'restricted PDF processed'
Assert-True -Value (Test-Path -LiteralPath $restrictedResult.OutputPath) -Name 'restricted output exists'

$locked = Join-Path $integration '需要密码.pdf'
& $qpdf.FullName '--encrypt' '--user-password=known-open-password' '--owner-password=owner-secret' '--bits=256' '--' $plain $locked
Assert-Equal -Expected 0 -Actual $LASTEXITCODE -Name 'create locked fixture'
$lockedResult = Invoke-PdfCopy -InputPath $locked -QpdfPath $qpdf.FullName
Assert-Equal -Expected 'Failed' -Actual $lockedResult.Status -Name 'open-password PDF rejected'
Assert-True -Value ($lockedResult.Message -match '密码') -Name 'password failure translated'

$broken = Join-Path $integration '损坏.pdf'
Set-Content -LiteralPath $broken -Value 'not a PDF'
$brokenResult = Invoke-PdfCopy -InputPath $broken -QpdfPath $qpdf.FullName
Assert-Equal -Expected 'Failed' -Actual $brokenResult.Status -Name 'corrupt PDF rejected'

$beforeBatchOutputs = @(Get-ChildItem -LiteralPath $integration -Filter '普通 文件_可注释*.pdf').Count
$batchExitCode = Invoke-Main -InputFiles @($plain, $locked, $broken) -NoPrompt -QpdfPath $qpdf.FullName
Assert-Equal -Expected 1 -Actual $batchExitCode -Name 'mixed batch reports partial failure'
$afterBatchOutputs = @(Get-ChildItem -LiteralPath $integration -Filter '普通 文件_可注释*.pdf').Count
Assert-True -Value ($afterBatchOutputs -gt $beforeBatchOutputs) -Name 'mixed batch continues after failure'

$missingQpdfExitCode = Invoke-Main -InputFiles @($plain) -NoPrompt -QpdfPath (Join-Path $integration 'missing-qpdf.exe')
Assert-Equal -Expected 2 -Actual $missingQpdfExitCode -Name 'missing qpdf stops batch'

Assert-True -Value (Confirm-Processing -NoPrompt) -Name 'non-interactive confirmation bypass'

$tempFiles = @(Get-ChildItem -LiteralPath $integration -Filter '*.tmp.pdf' -Force)
Assert-Equal -Expected 0 -Actual $tempFiles.Count -Name 'temporary files cleaned'

if ($script:failed -gt 0) {
    throw "$script:failed tests failed"
}

Write-Host "$script:passed tests passed" -ForegroundColor Cyan
