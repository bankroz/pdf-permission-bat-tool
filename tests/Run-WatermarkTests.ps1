[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $projectRoot 'src\tools\watermark_ui.ps1'
$batPath = Join-Path $projectRoot 'src\PDF去水印工具.bat'
$script:passed = 0
$script:failed = 0

function Assert-Equal {
    param([object]$Expected, [object]$Actual, [string]$Name)
    if ($Expected -eq $Actual) {
        $script:passed++
        Write-Host "PASS $Name" -ForegroundColor Green
    }
    else {
        $script:failed++
        Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red
    }
}

function Assert-True {
    param([bool]$Value, [string]$Name)
    Assert-Equal -Expected $true -Actual $Value -Name $Name
}

Assert-True -Value (Test-Path -LiteralPath $scriptPath -PathType Leaf) -Name 'watermark UI script exists'
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw 'Watermark UI feature is missing.'
}
. $scriptPath -LibraryMode

# Cleanup is restricted to this exact test-owned directory.
$scratch = [IO.Path]::GetFullPath((Join-Path $projectRoot 'tests\tmp\watermark-ui'))
$expectedScratch = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'tmp\watermark-ui'))
if ($scratch -ne $expectedScratch -or (Split-Path -Leaf $scratch) -ne 'watermark-ui') {
    throw "Refusing unsafe test cleanup: $scratch"
}
if (Test-Path -LiteralPath $scratch) {
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
$inputDir = Join-Path $scratch '输入 (中文 &!)'
New-Item -ItemType Directory -Path $inputDir -Force | Out-Null

# Real child processes implement the external protocols deterministically.
$fakeSource = @"
using System;
using System.IO;
using System.Text;
public static class WatermarkDependencyFixture {
    public static int Main(string[] args) {
        Console.OutputEncoding = new UTF8Encoding(false);
        string exe = Path.GetFileNameWithoutExtension(Environment.GetCommandLineArgs()[0]);
        bool qpdf = exe.StartsWith("qpdf", StringComparison.Ordinal);
        if (args.Length == 1 && args[0] == "--version") {
            Console.WriteLine(qpdf ? (exe.Contains("wrong") ? "qpdf version 12.4.20" : "qpdf version 12.4.2") : (exe.Contains("wrong") ? "0.2.00" : "0.2.0"));
            return 0;
        }
        if (qpdf) {
            string mode = File.ReadAllText(args[1]).Trim();
            if (args[0] == "--check") {
                Console.Error.WriteLine("检查中文输出");
                return mode == "qpdffail" ? 2 : (mode == "warning" ? 3 : 0);
            }
            if (args[0] == "--show-npages") {
                Console.WriteLine(mode == "pagewrong" ? "4" : (mode == "badpages" ? "not-an-integer" : "3"));
                return mode == "pagecommandfail" ? 2 : 0;
            }
            return 2;
        }
        string state = File.ReadAllText(args[0]).Trim();
        if (state == "badjson") { File.WriteAllText(args[1], "partial"); Console.WriteLine("{invalid JSON"); return 0; }
        if (state == "badshape") { Console.WriteLine("{\"status\":\"success\",\"message\":\"missing counts\"}"); return 0; }
        if (state == "unknown") { Console.WriteLine("{\"status\":\"mystery\",\"message\":\"unknown\",\"pages\":3,\"removed_blocks\":4}"); return 0; }
        string status = state == "unsupported" || state == "encrypted" || state == "invalid" || state == "failed" ? state : "success";
        if (state != "missingoutput") File.Copy(args[0], args[1]);
        if (state == "emptyoutput") File.WriteAllBytes(args[1], new byte[0]);
        Console.Error.WriteLine("诊断中文信息");
        Console.WriteLine("{\"status\":\"" + status + "\",\"message\":\"已删除中文水印\",\"pages\":3,\"removed_blocks\":" + (status == "success" ? "4" : "0") + "}");
        if (state == "mismatch") return 10;
        return status == "unsupported" ? 10 : status == "encrypted" ? 11 : status == "invalid" ? 12 : status == "failed" ? 13 : 0;
    }
}
"@
$fakeExe = Join-Path $scratch 'core.exe'
Add-Type -TypeDefinition $fakeSource -Language CSharp -OutputAssembly $fakeExe -OutputType ConsoleApplication
$coreWrong = Join-Path $scratch 'core-wrong.exe'
$qpdfExe = Join-Path $scratch 'qpdf.exe'
$qpdfWrong = Join-Path $scratch 'qpdf-wrong.exe'
foreach ($copyPath in @($coreWrong, $qpdfExe, $qpdfWrong)) {
    Copy-Item -LiteralPath $fakeExe -Destination $copyPath
}
$notExecutable = Join-Path $scratch 'broken.exe'
[IO.File]::WriteAllText($notExecutable, 'not an executable')

function New-TestInput {
    param([string]$Name, [string]$Mode = 'success')
    $path = Join-Path $inputDir ($Name + '.pdf')
    [IO.File]::WriteAllText($path, $Mode, (New-Object Text.UTF8Encoding($false)))
    return $path
}

$plain = New-TestInput -Name '普通 文件 (1) &!'
$firstOutput = Join-Path $inputDir '普通 文件 (1) &!_去水印.pdf'
Assert-Equal -Expected $firstOutput -Actual (Get-WatermarkOutputPath -InputPath $plain) -Name 'first output uses watermark suffix'
[IO.File]::WriteAllText($firstOutput, 'existing output')
Assert-Equal -Expected (Join-Path $inputDir '普通 文件 (1) &!_去水印_2.pdf') -Actual (Get-WatermarkOutputPath -InputPath $plain) -Name 'output collision increments from two'
[IO.File]::WriteAllText((Join-Path $inputDir '普通 文件 (1) &!_去水印_2.pdf'), 'existing output two')
Assert-Equal -Expected (Join-Path $inputDir '普通 文件 (1) &!_去水印_3.pdf') -Actual (Get-WatermarkOutputPath -InputPath $plain) -Name 'multiple output collisions increment'
$valid = Test-WatermarkInputPath -Path $plain
Assert-True -Value $valid.IsValid -Name 'existing PDF input is valid'
Assert-Equal -Expected 'Valid' -Actual $valid.Status -Name 'valid input status'
Assert-Equal -Expected ([IO.Path]::GetFullPath($plain)) -Actual $valid.InputPath -Name 'valid input is absolute'
Push-Location -LiteralPath $inputDir
try {
    Assert-Equal -Expected $plain -Actual (Test-WatermarkInputPath -Path ([IO.Path]::GetFileName($plain))).InputPath -Name 'relative input resolves from PowerShell location'
    Assert-Equal -Expected (Join-Path $inputDir '普通 文件 (1) &!_去水印_3.pdf') -Actual (Get-WatermarkOutputPath -InputPath ([IO.Path]::GetFileName($plain))) -Name 'relative output resolves from PowerShell location'
}
finally { Pop-Location }
$textFile = Join-Path $inputDir 'other.txt'
[IO.File]::WriteAllText($textFile, 'text')
Assert-Equal -Expected 'Skipped' -Actual (Test-WatermarkInputPath -Path $textFile).Status -Name 'non PDF input skipped'
Assert-Equal -Expected 'Skipped' -Actual (Test-WatermarkInputPath -Path (Join-Path $inputDir 'missing.pdf')).Status -Name 'missing input skipped'
Assert-Equal -Expected 'Skipped' -Actual (Test-WatermarkInputPath -Path $inputDir).Status -Name 'directory input skipped'
$rejected = $false
try { New-WatermarkResult -Status 'Other' -InputPath $plain -Message 'bad' | Out-Null } catch { $rejected = $true }
Assert-True -Value $rejected -Name 'unknown public result status rejected'
$fields = (New-WatermarkResult -Status 'Success' -InputPath $plain -Message 'ok').PSObject.Properties.Name
foreach ($field in @('IsValid', 'Status', 'InputPath', 'OutputPath', 'Message', 'Details', 'Pages', 'RemovedBlocks')) {
    Assert-True -Value ($fields -contains $field) -Name "result includes $field"
}
Assert-True -Value (Confirm-WatermarkProcessing -NoPrompt) -Name 'confirmation NoPrompt bypass'
$bytes = [IO.File]::ReadAllBytes($scriptPath)
Assert-True -Value ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) -Name 'PowerShell source is UTF-8 BOM'
Assert-True -Value (Test-Path -LiteralPath $batPath -PathType Leaf) -Name 'BAT launcher exists'
if (Test-Path -LiteralPath $batPath -PathType Leaf) {
    $batBytes = [IO.File]::ReadAllBytes($batPath)
    $bat = [Text.Encoding]::ASCII.GetString($batBytes)
    Assert-Equal -Expected 0 -Actual @($batBytes | Where-Object { $_ -gt 127 }).Count -Name 'BAT is pure ASCII without BOM'
    Assert-True -Value ($bat -notmatch '(?i)chcp') -Name 'BAT does not change code page'
    Assert-True -Value ($bat -notmatch '(?i)EnableDelayedExpansion') -Name 'BAT does not enable delayed expansion'
    Assert-True -Value ($bat -match '(?m)^setlocal DisableDelayedExpansion\r?$') -Name 'BAT disables delayed expansion'
    Assert-True -Value ($bat -notmatch '(?<!\r)\n') -Name 'BAT uses CRLF'
    Assert-True -Value ($bat -match 'powershell\.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%TOOL_ROOT%tools\\watermark_ui\.ps1" %\*') -Name 'BAT forwards arguments to independent UI'
    Assert-True -Value ($bat -match 'set "TOOL_EXIT=%ERRORLEVEL%"[\s\S]*pause[\s\S]*exit /b %TOOL_EXIT%') -Name 'BAT preserves exit code across pause'
}

$deps = Resolve-WatermarkDependencies -CorePath $fakeExe -QpdfPath $qpdfExe
Assert-True -Value $deps.IsValid -Name 'explicit dependencies resolved'
Assert-Equal -Expected $fakeExe -Actual $deps.CorePath -Name 'explicit core takes precedence'
Assert-Equal -Expected $qpdfExe -Actual $deps.QpdfPath -Name 'explicit qpdf takes precedence'
Push-Location -LiteralPath $scratch
try {
    $relativeDependencies = Resolve-WatermarkDependencies -CorePath '.\core.exe' -QpdfPath '.\qpdf.exe'
    Assert-Equal -Expected $fakeExe -Actual $relativeDependencies.CorePath -Name 'relative core uses PowerShell location'
    Assert-Equal -Expected $qpdfExe -Actual $relativeDependencies.QpdfPath -Name 'relative qpdf uses PowerShell location'
}
finally { Pop-Location }
Assert-True -Value (Test-WatermarkDependencies -CorePath $fakeExe -QpdfPath $qpdfExe).IsValid -Name 'correct dependency versions healthy'
Assert-Equal -Expected $false -Actual (Test-WatermarkDependencies -CorePath $notExecutable -QpdfPath $qpdfExe).IsValid -Name 'unstartable core invalid without exception'
Assert-Equal -Expected $false -Actual (Test-WatermarkDependencies -CorePath $coreWrong -QpdfPath $qpdfExe).IsValid -Name 'core version must match exactly'
Assert-Equal -Expected $false -Actual (Test-WatermarkDependencies -CorePath $fakeExe -QpdfPath $qpdfWrong).IsValid -Name 'qpdf version must match pinned version'

$coreTemp = Join-Path $inputDir 'core-direct.tmp.pdf'
$coreResult = Invoke-WatermarkCore -CorePath $fakeExe -InputPath $plain -OutputPath $coreTemp
Assert-Equal -Expected 0 -Actual $coreResult.ExitCode -Name 'core exit code captured'
Assert-Equal -Expected 'success' -Actual $coreResult.Status -Name 'core JSON status mapped'
Assert-Equal -Expected '已删除中文水印' -Actual $coreResult.Message -Name 'core UTF-8 JSON preserves Chinese under Windows PowerShell'
Assert-Equal -Expected 3 -Actual $coreResult.Pages -Name 'core page count mapped'
Assert-Equal -Expected 4 -Actual $coreResult.RemovedBlocks -Name 'core removed blocks mapped'
Assert-True -Value ($coreResult.Details -match '诊断中文信息') -Name 'stderr captured as UTF-8 details'
Remove-Item -LiteralPath $coreTemp

$beforeHash = (Get-FileHash -LiteralPath $plain -Algorithm SHA256).Hash
$beforeTime = (Get-Item -LiteralPath $plain).LastWriteTimeUtc.Ticks
$success = Invoke-WatermarkFile -InputPath $plain -CorePath $fakeExe -QpdfPath $qpdfExe
Assert-Equal -Expected 'Success' -Actual $success.Status -Name 'success publishes validated output'
Assert-True -Value (Test-Path -LiteralPath $success.OutputPath -PathType Leaf) -Name 'published output exists'
Assert-Equal -Expected (Join-Path $inputDir '普通 文件 (1) &!_去水印_3.pdf') -Actual $success.OutputPath -Name 'success preserves existing outputs'
Assert-Equal -Expected 'existing output' -Actual ([IO.File]::ReadAllText($firstOutput)) -Name 'existing output bytes preserved'
Assert-Equal -Expected 3 -Actual $success.Pages -Name 'published result includes pages'
Assert-Equal -Expected 4 -Actual $success.RemovedBlocks -Name 'published result includes removed blocks'
Assert-Equal -Expected $beforeHash -Actual (Get-FileHash -LiteralPath $plain -Algorithm SHA256).Hash -Name 'input SHA256 unchanged'
Assert-Equal -Expected $beforeTime -Actual (Get-Item -LiteralPath $plain).LastWriteTimeUtc.Ticks -Name 'input timestamp unchanged'

$warningInput = New-TestInput -Name 'warning' -Mode 'warning'
$warning = Invoke-WatermarkFile -InputPath $warningInput -CorePath $fakeExe -QpdfPath $qpdfExe
Assert-Equal -Expected 'Warning' -Actual $warning.Status -Name 'qpdf check exit three publishes warning'
Assert-True -Value (Test-Path -LiteralPath $warning.OutputPath -PathType Leaf) -Name 'warning output exists'

foreach ($mode in @('unsupported', 'encrypted', 'invalid', 'failed', 'badjson', 'badshape', 'unknown', 'mismatch', 'qpdffail', 'pagewrong', 'badpages', 'pagecommandfail', 'missingoutput', 'emptyoutput')) {
    $inputPath = New-TestInput -Name $mode -Mode $mode
    $result = Invoke-WatermarkFile -InputPath $inputPath -CorePath $fakeExe -QpdfPath $qpdfExe
    $expectedStatus = if ($mode -eq 'unsupported') { 'Skipped' } else { 'Failed' }
    Assert-Equal -Expected $expectedStatus -Actual $result.Status -Name "$mode gets safe result"
    Assert-Equal -Expected '' -Actual $result.OutputPath -Name "$mode has no published path"
    Assert-Equal -Expected $false -Actual (Test-Path -LiteralPath (Join-Path $inputDir ($mode + '_去水印.pdf'))) -Name "$mode never publishes output"
}
Assert-Equal -Expected 0 -Actual @(Get-ChildItem -LiteralPath $inputDir -Filter '*.tmp.pdf' -Force).Count -Name 'all per-file temporary files cleaned'
$invalidPath = 'illegal' + [char]0 + '.pdf'
$pathResult = Invoke-WatermarkFile -InputPath $invalidPath -CorePath $fakeExe -QpdfPath $qpdfExe
Assert-Equal -Expected 'Failed' -Actual $pathResult.Status -Name 'illegal path preparation exception converted to Failed'

$shown = (Show-WatermarkResult -Result $success -Index 1 -Total 2 6>&1 | Out-String)
Assert-True -Value ($shown -match '\[1/2\].*成功') -Name 'result shows index and Chinese status'
Assert-True -Value ($shown -match '3.*4') -Name 'successful display includes pages and removed blocks'
$summary = (Show-WatermarkSummary -Results @($success, $warning, $pathResult, (New-WatermarkResult -Status 'Skipped' -InputPath $plain -Message 'skip')) -NoPrompt 6>&1 | Out-String)
Assert-True -Value ($summary -match '成功 1.*警告成功 1.*失败 1.*跳过 1') -Name 'summary counts all statuses'

$unsupportedInput = Join-Path $inputDir 'unsupported.pdf'
$failedInput = Join-Path $inputDir 'failed.pdf'
$batchSuccessInput = New-TestInput -Name 'batch success (中文 &!)'
$batchExit = Invoke-WatermarkMain -InputFiles @($failedInput, $unsupportedInput, $batchSuccessInput) -NoPrompt -CorePath $fakeExe -QpdfPath $qpdfExe
Assert-Equal -Expected 1 -Actual $batchExit -Name 'mixed batch failure exits one'
Assert-True -Value (Test-Path -LiteralPath (Join-Path $inputDir 'batch success (中文 &!)_去水印.pdf')) -Name 'batch continues after failure'
Assert-Equal -Expected 0 -Actual (Invoke-WatermarkMain -InputFiles @($unsupportedInput) -NoPrompt -CorePath $fakeExe -QpdfPath $qpdfExe) -Name 'unsupported-only batch exits zero'
Assert-Equal -Expected 0 -Actual (Invoke-WatermarkMain -InputFiles @($warningInput, $plain) -NoPrompt -CorePath $fakeExe -QpdfPath $qpdfExe) -Name 'warning and success batch exits zero'
$exceptionEscaped = $false
try { $badPathBatchExit = Invoke-WatermarkMain -InputFiles @($invalidPath, $batchSuccessInput) -NoPrompt -CorePath $fakeExe -QpdfPath $qpdfExe } catch { $exceptionEscaped = $true }
Assert-Equal -Expected $false -Actual $exceptionEscaped -Name 'illegal path does not escape batch'
Assert-Equal -Expected 1 -Actual $badPathBatchExit -Name 'illegal path marks batch failure'
Assert-True -Value (Test-Path -LiteralPath (Join-Path $inputDir 'batch success (中文 &!)_去水印_2.pdf')) -Name 'batch continues after illegal path'
$launcherInput = New-TestInput -Name 'BAT launch 中文 (2) &!'
'' | & $batPath '-NoPrompt' '-CorePath' $fakeExe '-QpdfPath' $qpdfExe $launcherInput
Assert-Equal -Expected 0 -Actual $LASTEXITCODE -Name 'BAT runs independent PowerShell entry point'
Assert-True -Value (Test-Path -LiteralPath (Join-Path $inputDir 'BAT launch 中文 (2) &!_去水印.pdf')) -Name 'BAT safely forwards special input path'
'' | & $batPath '-NoPrompt' '-CorePath' $fakeExe '-QpdfPath' $qpdfExe $failedInput $launcherInput
Assert-Equal -Expected 1 -Actual $LASTEXITCODE -Name 'BAT preserves mixed batch exit one after pause'
Assert-True -Value (Test-Path -LiteralPath (Join-Path $inputDir 'BAT launch 中文 (2) &!_去水印_2.pdf')) -Name 'BAT forwards multiple files and continues after failure'
$missing = Join-Path $scratch 'missing.exe'
foreach ($case in @(
    @{ Name = 'missing core'; Core = $missing; Qpdf = $qpdfExe },
    @{ Name = 'unstartable core'; Core = $notExecutable; Qpdf = $qpdfExe },
    @{ Name = 'wrong core version'; Core = $coreWrong; Qpdf = $qpdfExe },
    @{ Name = 'missing qpdf'; Core = $fakeExe; Qpdf = $missing },
    @{ Name = 'unstartable qpdf'; Core = $fakeExe; Qpdf = $notExecutable },
    @{ Name = 'wrong qpdf version'; Core = $fakeExe; Qpdf = $qpdfWrong }
)) {
    Assert-Equal -Expected 2 -Actual (Invoke-WatermarkMain -InputFiles @($plain) -NoPrompt -CorePath $case.Core -QpdfPath $case.Qpdf) -Name "$($case.Name) batch exits two"
}
# Replace only the UI boundary to exercise cancellation without opening modal dialogs.
$originalSelect = (Get-Command Select-WatermarkPdfFiles).ScriptBlock
$originalConfirm = (Get-Command Confirm-WatermarkProcessing).ScriptBlock
try {
    Set-Item -Path Function:\Select-WatermarkPdfFiles -Value { return @() }
    Assert-Equal -Expected 0 -Actual (Invoke-WatermarkMain -NoPrompt -CorePath $fakeExe -QpdfPath $qpdfExe) -Name 'file selection cancellation exits zero'
    Set-Item -Path Function:\Confirm-WatermarkProcessing -Value { param([switch]$NoPrompt) return $false }
    Assert-Equal -Expected 0 -Actual (Invoke-WatermarkMain -InputFiles @($plain) -CorePath $fakeExe -QpdfPath $qpdfExe) -Name 'confirmation cancellation exits zero'
}
finally {
    Set-Item -Path Function:\Select-WatermarkPdfFiles -Value $originalSelect
    Set-Item -Path Function:\Confirm-WatermarkProcessing -Value $originalConfirm
}
Assert-Equal -Expected 0 -Actual @(Get-ChildItem -LiteralPath $inputDir -Filter '*.tmp.pdf' -Force).Count -Name 'batch leaves no temporary files'
if ($script:failed -gt 0) { throw "$script:failed tests failed" }
Write-Host "$script:passed tests passed" -ForegroundColor Cyan
