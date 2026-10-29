[CmdletBinding()]
param(
    [switch]$DeliverySmokeTest
)

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
                return mode == "qpdffail" ? 2 : (mode == "warning" || mode == "bothwarning" ? 3 : 0);
            }
            if (args[0] == "--show-npages") {
                Console.WriteLine(mode == "pagewrong" || mode == "pagewarningwrong" ? "4" : (mode == "badpages" || mode == "pagewarninginvalid" ? "not-an-integer" : "3"));
                return mode == "pagecommandfail" ? 2 : (mode.StartsWith("pagewarning", StringComparison.Ordinal) || mode == "bothwarning" ? 3 : 0);
            }
            return 2;
        }
        string state = File.ReadAllText(args[0]).Trim();
        File.WriteAllText(args[0] + ".temp-path.txt", args[1]);
        if (Path.GetFileName(args[1]).StartsWith(".", StringComparison.Ordinal)) File.AppendAllLines(args[0] + ".temp-paths.txt", new string[] { args[1] });
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

function Remove-TestCoreTemporaryFile {
    param([string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetDirectoryName($fullPath) -ne $inputDir -or
        [IO.Path]::GetFileName($fullPath) -notmatch '^\.[a-f0-9]{32}\.wm\.tmp\.pdf$') {
        throw "Refusing unsafe test fixture cleanup: $fullPath"
    }
    if ([IO.File]::Exists($fullPath)) { Remove-Item -LiteralPath $fullPath -Force }
}

function Clear-TestCoreResidues {
    # Remove only unowned failure fixtures; owned leftovers must still fail cleanup assertions.
    foreach ($record in @(Get-ChildItem -LiteralPath $inputDir -Filter '*.temp-paths.txt' -File)) {
        $sourcePath = $record.FullName.Substring(0, $record.FullName.Length - '.temp-paths.txt'.Length)
        $mode = [IO.File]::ReadAllText($sourcePath).Trim()
        if ($mode -notin @('unsupported', 'encrypted', 'invalid', 'failed', 'badjson', 'mismatch', 'emptyoutput')) { continue }
        foreach ($path in [IO.File]::ReadAllLines($record.FullName)) { Remove-TestCoreTemporaryFile -Path $path }
    }
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

foreach ($mode in @('pagewarning', 'bothwarning')) {
    $warningPath = New-TestInput -Name $mode -Mode $mode
    $warningCheck = Test-WatermarkOutput -Path $warningPath -QpdfPath $qpdfExe -Pages 3
    Assert-True -Value $warningCheck.IsValid -Name "$mode page-count exit three validates"
    Assert-True -Value $warningCheck.IsWarning -Name "$mode page-count warning preserved"
    $warningResult = Invoke-WatermarkFile -InputPath $warningPath -CorePath $fakeExe -QpdfPath $qpdfExe
    Assert-Equal -Expected 'Warning' -Actual $warningResult.Status -Name "$mode publishes as Warning"
    Assert-True -Value ([IO.File]::Exists($warningResult.OutputPath)) -Name "$mode warning output published"
}

# Keep both public paths within MAX_PATH while the former stem-based temp exceeds it.
$longStem = 'n' * (215 - $inputDir.Length - 5)
$longInput = New-TestInput -Name $longStem -Mode 'longpath'
$longOutput = Get-WatermarkOutputPath -InputPath $longInput
$formerTemp = Join-Path $inputDir ('.{0}.{1}.watermark.tmp.pdf' -f $longStem, ('a' * 32))
Assert-Equal -Expected 215 -Actual $longInput.Length -Name 'long-path input remains usable on Windows'
Assert-Equal -Expected 219 -Actual $longOutput.Length -Name 'long-path final output remains usable on Windows'
Assert-True -Value ($formerTemp.Length -ge 260) -Name 'former temporary naming exceeds Windows path limit'
$unrelatedTemp = Join-Path $inputDir 'unrelated.watermark.tmp.pdf'
[IO.File]::WriteAllText($unrelatedTemp, 'unrelated file must survive')
$longResult = Invoke-WatermarkFile -InputPath $longInput -CorePath $fakeExe -QpdfPath $qpdfExe
$actualTemp = [IO.File]::ReadAllText($longInput + '.temp-path.txt')
Assert-Equal -Expected 'Success' -Actual $longResult.Status -Name 'long input publishes successfully using short temporary name'
Assert-True -Value ([IO.File]::Exists($longOutput)) -Name 'long-path final output exists'
Assert-True -Value ($actualTemp.Length -lt $longInput.Length) -Name 'temporary path is shorter than usable input path'
Assert-Equal -Expected $inputDir -Actual ([IO.Path]::GetDirectoryName($actualTemp)) -Name 'short temporary file stays beside input'
Assert-True -Value (([IO.Path]::GetFileName($actualTemp)).Length -le 48) -Name 'temporary name length is independent of input stem'
Assert-Equal -Expected $false -Actual ([IO.File]::Exists($actualTemp)) -Name 'short temporary file cleaned after publication'
Assert-Equal -Expected 'unrelated file must survive' -Actual ([IO.File]::ReadAllText($unrelatedTemp)) -Name 'cleanup preserves unrelated temporary files'
Remove-Item -LiteralPath $unrelatedTemp

# Use a synthetic damaged xref to verify the pinned real qpdf when available.
$realQpdf = Join-Path $projectRoot 'vendor\qpdf-12.4.2-msvc64\bin\qpdf.exe'
if (Test-Path -LiteralPath $realQpdf -PathType Leaf) {
    $repairFixture = Join-Path $inputDir 'repairable-xref.pdf'
    Assert-True -Value (Test-WatermarkDependencies -CorePath $fakeExe -QpdfPath $realQpdf).IsValid -Name 'real qpdf xref integration uses pinned version'
    $damagedPdf = @(
        '%PDF-1.4',
        '1 0 obj', '<< /Type /Catalog /Pages 2 0 R >>', 'endobj',
        '2 0 obj', '<< /Type /Pages /Count 1 /Kids [3 0 R] >>', 'endobj',
        '3 0 obj', '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << >> >>', 'endobj',
        'trailer', '<< /Root 1 0 R /Size 4 >>', 'startxref', '1', '%%EOF', ''
    ) -join [Environment]::NewLine
    [IO.File]::WriteAllText($repairFixture, $damagedPdf, [Text.Encoding]::ASCII)
    $realCheck = Invoke-WatermarkProcess -Path $realQpdf -Arguments @('--check', $repairFixture)
    $realCount = Invoke-WatermarkProcess -Path $realQpdf -Arguments @('--show-npages', $repairFixture)
    Assert-Equal -Expected 3 -Actual $realCheck.ExitCode -Name 'real qpdf check warns on recoverable xref damage'
    Assert-Equal -Expected 3 -Actual $realCount.ExitCode -Name 'real qpdf page count also warns on recoverable xref damage'
    Assert-Equal -Expected '1' -Actual $realCount.StdOut.Trim() -Name 'real qpdf warning still returns correct page count'
    $realValidation = Test-WatermarkOutput -Path $repairFixture -QpdfPath $realQpdf -Pages 1
    Assert-True -Value $realValidation.IsValid -Name 'real qpdf recoverable xref output accepted'
    Assert-True -Value $realValidation.IsWarning -Name 'real qpdf recoverable xref output marked Warning'
}
else { Write-Host 'SKIP real qpdf xref integration: vendor executable unavailable.' }

foreach ($mode in @('unsupported', 'encrypted', 'invalid', 'failed', 'badjson', 'badshape', 'unknown', 'mismatch', 'qpdffail', 'pagewrong', 'badpages', 'pagecommandfail', 'pagewarningwrong', 'pagewarninginvalid', 'missingoutput', 'emptyoutput')) {
    $inputPath = New-TestInput -Name $mode -Mode $mode
    $result = Invoke-WatermarkFile -InputPath $inputPath -CorePath $fakeExe -QpdfPath $qpdfExe
    $expectedStatus = if ($mode -eq 'unsupported') { 'Skipped' } else { 'Failed' }
    Assert-Equal -Expected $expectedStatus -Actual $result.Status -Name "$mode gets safe result"
    Assert-Equal -Expected '' -Actual $result.OutputPath -Name "$mode has no published path"
    Assert-Equal -Expected $false -Actual (Test-Path -LiteralPath (Join-Path $inputDir ($mode + '_去水印.pdf'))) -Name "$mode never publishes output"
    $recordedTemp = [IO.File]::ReadAllText($inputPath + '.temp-path.txt')
    if ($mode -in @('unsupported', 'encrypted', 'invalid', 'failed', 'badjson', 'mismatch', 'emptyoutput')) {
        Assert-True -Value ([IO.File]::Exists($recordedTemp)) -Name "$mode unconfirmed temporary file is preserved"
        if ([IO.File]::Exists($recordedTemp)) {
            $expectedContent = if ($mode -eq 'badjson') { 'partial' } elseif ($mode -eq 'emptyoutput') { '' } else { $mode }
            Assert-Equal -Expected $expectedContent -Actual ([IO.File]::ReadAllText($recordedTemp)) -Name "$mode unconfirmed temporary bytes unchanged"
        }
        # These artificial failure residues belong to the fixture, not the UI.
        Remove-TestCoreTemporaryFile -Path $recordedTemp
    }
    else {
        Assert-Equal -Expected $false -Actual ([IO.File]::Exists($recordedTemp)) -Name "$mode confirmed output failure leaves no owned temporary file"
    }
}
Assert-Equal -Expected 0 -Actual @(Get-ChildItem -LiteralPath $inputDir -Filter '*.tmp.pdf' -Force).Count -Name 'all per-file temporary files cleaned'

# Inject a real occupied candidate only at the filesystem existence boundary.
$collisionInput = New-TestInput -Name 'temp collision'
$script:collisionPath = ''
Set-Item -Path Function:\Test-Path -Value {
    param([string]$LiteralPath, [string]$PathType)
    if (-not $PathType -and [IO.Path]::GetFileName($LiteralPath) -match '^\.[a-f0-9]{32}\.wm\.tmp\.pdf$' -and -not $script:collisionPath) {
        $script:collisionPath = $LiteralPath
        [IO.File]::WriteAllText($LiteralPath, 'existing candidate belongs to someone else')
    }
    $parameters = @{ LiteralPath = $LiteralPath }
    if ($PathType) { $parameters.PathType = $PathType }
    return Microsoft.PowerShell.Management\Test-Path @parameters
}
try { $collisionResult = Invoke-WatermarkFile -InputPath $collisionInput -CorePath $fakeExe -QpdfPath $qpdfExe }
finally { Remove-Item -Path Function:\Test-Path }
Assert-True -Value ([bool]$script:collisionPath) -Name 'temporary candidate checked before core starts'
Assert-Equal -Expected 'Success' -Actual $collisionResult.Status -Name 'occupied temporary candidate is retried'
$usedTemp = [IO.File]::ReadAllText($collisionInput + '.temp-path.txt')
Assert-True -Value ($usedTemp -ne $script:collisionPath) -Name 'core never receives occupied temporary candidate'
if ($script:collisionPath) {
    Assert-Equal -Expected 'existing candidate belongs to someone else' -Actual ([IO.File]::ReadAllText($script:collisionPath)) -Name 'occupied candidate bytes preserved'
    Remove-TestCoreTemporaryFile -Path $script:collisionPath
}

$exhaustedInput = New-TestInput -Name 'temp retries exhausted'
$script:collisionAttempts = 0
Set-Item -Path Function:\Test-Path -Value {
    param([string]$LiteralPath, [string]$PathType)
    if (-not $PathType -and [IO.Path]::GetFileName($LiteralPath) -match '^\.[a-f0-9]{32}\.wm\.tmp\.pdf$') {
        $script:collisionAttempts++
        return $true
    }
    $parameters = @{ LiteralPath = $LiteralPath }
    if ($PathType) { $parameters.PathType = $PathType }
    return Microsoft.PowerShell.Management\Test-Path @parameters
}
try { $exhaustedResult = Invoke-WatermarkFile -InputPath $exhaustedInput -CorePath $fakeExe -QpdfPath $qpdfExe }
finally { Remove-Item -Path Function:\Test-Path }
Assert-Equal -Expected 'Failed' -Actual $exhaustedResult.Status -Name 'temporary collision exhaustion fails safely'
Assert-True -Value ($script:collisionAttempts -gt 1 -and $script:collisionAttempts -le 16) -Name 'temporary collision retries are bounded'
Assert-True -Value ($exhaustedResult.Message -match '临时') -Name 'temporary collision exhaustion explains failure'
Assert-Equal -Expected $false -Actual ([IO.File]::Exists($exhaustedInput + '.temp-path.txt')) -Name 'core is not started when all temporary candidates are occupied'

# A core-call exception after file creation still cannot establish UI ownership.
$exceptionInput = New-TestInput -Name 'unowned core exception'
$originalCore = (Get-Command Invoke-WatermarkCore).ScriptBlock
$script:exceptionTempPath = ''
$script:exceptionTempBytes = [guid]::NewGuid().ToByteArray()
Set-Item -Path Function:\Invoke-WatermarkCore -Value {
    param([string]$CorePath, [string]$InputPath, [string]$OutputPath)
    $script:exceptionTempPath = $OutputPath
    [IO.File]::WriteAllBytes($OutputPath, $script:exceptionTempBytes)
    throw 'Injected exception after unowned temporary file creation.'
}
try {
    $exceptionResult = Invoke-WatermarkFile -InputPath $exceptionInput -CorePath $fakeExe -QpdfPath $qpdfExe
    Assert-Equal -Expected 'Failed' -Actual $exceptionResult.Status -Name 'exception after temporary file creation returns Failed'
    Assert-Equal -Expected '' -Actual $exceptionResult.OutputPath -Name 'core-call exception publishes no output'
    Assert-True -Value ($exceptionResult.Details -match 'Injected exception after unowned temporary file creation') -Name 'core-call exception reaches per-file error boundary'
    Assert-True -Value ([bool]$script:exceptionTempPath) -Name 'core-call exception records exact temporary path'
    Assert-True -Value ([IO.File]::Exists($script:exceptionTempPath)) -Name 'unconfirmed temporary file survives core-call exception'
    if ([IO.File]::Exists($script:exceptionTempPath)) {
        Assert-Equal -Expected ([Convert]::ToBase64String($script:exceptionTempBytes)) -Actual ([Convert]::ToBase64String([IO.File]::ReadAllBytes($script:exceptionTempPath))) -Name 'core-call exception preserves unconfirmed temporary bytes'
    }
}
finally {
    Set-Item -Path Function:\Invoke-WatermarkCore -Value $originalCore
    if ($script:exceptionTempPath) {
        $cleanupPath = [IO.Path]::GetFullPath($script:exceptionTempPath)
        $testTmpPrefix = [IO.Path]::GetFullPath((Join-Path $projectRoot 'tests\tmp')).TrimEnd('\') + '\'
        if (-not $cleanupPath.StartsWith($testTmpPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing unsafe exception fixture cleanup: $cleanupPath"
        }
        Remove-TestCoreTemporaryFile -Path $cleanupPath
    }
}
Assert-Equal -Expected $originalCore.ToString() -Actual (Get-Command Invoke-WatermarkCore).ScriptBlock.ToString() -Name 'original core function restored after exception fixture'
Assert-Equal -Expected $false -Actual ([IO.File]::Exists($script:exceptionTempPath)) -Name 'test safely cleans its own exception fixture'

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
Clear-TestCoreResidues
Assert-Equal -Expected 0 -Actual @(Get-ChildItem -LiteralPath $inputDir -Filter '*.tmp.pdf' -Force).Count -Name 'batch leaves no temporary files'
if ($DeliverySmokeTest) {
    # Import the same exact manifest verifier used by the original tool's tests.
    . (Join-Path $PSScriptRoot 'Run-Tests.ps1') -LibraryMode
    $delivery = Join-Path $projectRoot 'dist\PDF权限处理工具_BAT版'
    $deliveryZip = Join-Path $projectRoot 'dist\PDF权限处理工具_BAT版.zip'
    $requiredFiles = @('PDF去水印工具.bat', 'tools\watermark_ui.ps1', 'watermark\watermark_core.exe', 'licenses\pypdf-LICENSE.txt', 'licenses\PyInstaller-COPYING.txt')
    Assert-True -Value (Test-Path -LiteralPath $delivery -PathType Container) -Name 'watermark delivery directory exists'
    foreach ($relativePath in $requiredFiles) {
        $deliveryFile = Join-Path $delivery $relativePath
        $exists = Test-Path -LiteralPath $deliveryFile -PathType Leaf
        Assert-True -Value ($exists -and (Get-Item -LiteralPath $deliveryFile).Length -gt 0) -Name "watermark delivery contains nonempty $relativePath"
    }
    $deliveryCore = Join-Path $delivery 'watermark\watermark_core.exe'
    if (Test-Path -LiteralPath $deliveryCore -PathType Leaf) {
        $version = Invoke-WatermarkProcess -Path $deliveryCore -Arguments @('--version')
        Assert-Equal -Expected 0 -Actual $version.ExitCode -Name 'delivery watermark core starts'
        Assert-Equal -Expected "0.2.0`r`n" -Actual $version.StdOut -Name 'delivery watermark core version is exactly 0.2.0'
    }
    foreach ($name in @('pypdf-LICENSE.txt', 'PyInstaller-COPYING.txt')) {
        $license = Join-Path $delivery ('licenses\' + $name)
        if (Test-Path -LiteralPath $license -PathType Leaf) {
            $sourceLicense = Join-Path $projectRoot ('third_party\' + $name)
            Assert-Equal -Expected (Get-FileHash -LiteralPath $sourceLicense -Algorithm SHA256).Hash -Actual (Get-FileHash -LiteralPath $license -Algorithm SHA256).Hash -Name "delivery $name matches tracked source bytes"
        }
    }
    Assert-True -Value (Test-DeliveryManifest -Root $delivery) -Name 'watermark delivery manifest covers exact file set and hashes'
    $zipExists = (Test-Path -LiteralPath $deliveryZip -PathType Leaf) -and (Get-Item -LiteralPath $deliveryZip).Length -gt 0
    Assert-True -Value $zipExists -Name 'watermark delivery ZIP exists and is nonempty'

    if ($zipExists) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($deliveryZip)
        try {
            $entries = @($archive.Entries | Where-Object { $_.Name } | ForEach-Object { $_.FullName.Replace('\', '/') } | Sort-Object)
        }
        finally { $archive.Dispose() }
        foreach ($relativePath in $requiredFiles) {
            Assert-True -Value ($entries -contains ('PDF权限处理工具_BAT版/' + $relativePath.Replace('\', '/'))) -Name "watermark ZIP contains $relativePath"
        }
        $expectedEntries = @(Get-ChildItem -LiteralPath $delivery -Recurse -File | ForEach-Object {
            'PDF权限处理工具_BAT版/' + $_.FullName.Substring($delivery.Length + 1).Replace('\', '/')
        } | Sort-Object)
        Assert-Equal -Expected ($expectedEntries -join "`n") -Actual ($entries -join "`n") -Name 'watermark ZIP contains exact delivery file set'

        # Generate a real one-page PDF without external data or a Python runtime.
        function New-MarkedWatermarkFixture {
            param([string]$Path)
            $body = "q 0 0 1 rg 10 10 40 40 re f Q`n"
            # Keep the marked path drawing at the stream tail, within the core's supported safety scope.
            $content = $body + "/Artifact << /Subtype /Watermark /Type /Pagination >> BDC`nq 1 0 0 rg 20 20 10 10 re f Q`nEMC`n"
            $objects = @(
                '<< /Type /Catalog /Pages 2 0 R >>',
                '<< /Type /Pages /Count 1 /Kids [3 0 R] >>',
                '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << >> /Contents 4 0 R >>',
                ("<< /Length $($content.Length) >>`nstream`n" + $content + 'endstream')
            )
            $pdf = "%PDF-1.4`n"
            $offsets = @()
            for ($i = 0; $i -lt $objects.Count; $i++) {
                $offsets += $pdf.Length
                $pdf += "$($i + 1) 0 obj`n$($objects[$i])`nendobj`n"
            }
            $xrefOffset = $pdf.Length
            $pdf += "xref`n0 5`n0000000000 65535 f `n"
            foreach ($offset in $offsets) { $pdf += ('{0:D10} 00000 n ' -f $offset) + "`n" }
            $pdf += "trailer`n<< /Root 1 0 R /Size 5 >>`nstartxref`n$xrefOffset`n%%EOF`n"
            [IO.File]::WriteAllBytes($Path, [Text.Encoding]::ASCII.GetBytes($pdf))
        }

        # Read only content streams actually referenced by the output page.
        function Read-WatermarkFixtureContent {
            param([string]$Path, [string]$QpdfPath)
            $pages = Invoke-WatermarkProcess -Path $QpdfPath -Arguments @('--json', '--json-key=pages', $Path)
            if ($pages.ExitCode -notin @(0, 3)) { throw "Cannot inspect PDF pages: $($pages.StdErr)" }
            $pageData = $pages.StdOut | ConvertFrom-Json
            if (@($pageData.pages).Count -ne 1 -or @($pageData.pages[0].contents).Count -ne 1) {
                throw 'Expected one generated page with one referenced content stream.'
            }
            $reference = $pageData.pages[0].contents[0]
            if ($reference -notmatch '^(\d+) (\d+) R$') { throw "Unexpected content reference: $reference" }
            $objectArgument = '--show-object={0},{1}' -f $Matches[1], $Matches[2]
            $stream = Invoke-WatermarkProcess -Path $QpdfPath -Arguments @($objectArgument, '--filtered-stream-data', $Path)
            if ($stream.ExitCode -notin @(0, 3)) { throw "Cannot inspect PDF content: $($stream.StdErr)" }
            return $stream.StdOut
        }

        $testsTmpRoot = (Resolve-Path -LiteralPath (Join-Path $projectRoot 'tests\tmp')).ProviderPath
        $testsTmpPrefix = $testsTmpRoot.TrimEnd('\') + '\'
        $zipTestRoot = [IO.Path]::GetFullPath((Join-Path $testsTmpRoot ('水印 ZIP (中文 &!) ' + [guid]::NewGuid().ToString('N'))))
        if (-not $zipTestRoot.StartsWith($testsTmpPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing unsafe watermark ZIP test path: $zipTestRoot"
        }
        try {
            Expand-Archive -LiteralPath $deliveryZip -DestinationPath $zipTestRoot
            $zipToolRoot = Join-Path $zipTestRoot 'PDF权限处理工具_BAT版'
            $zipBat = Join-Path $zipToolRoot 'PDF去水印工具.bat'
            $zipCore = Join-Path $zipToolRoot 'watermark\watermark_core.exe'
            $zipQpdf = Join-Path $zipToolRoot 'qpdf\bin\qpdf.exe'
            Assert-True -Value (Test-DeliveryManifest -Root $zipToolRoot) -Name 'watermark extracted ZIP manifest covers exact file set and hashes'
            $zipInputDir = Join-Path $zipTestRoot '输入 文件 (中文 &!)'
            New-Item -ItemType Directory -Path $zipInputDir -Force | Out-Null
            $zipInput = Join-Path $zipInputDir '标记水印 (1) &!.pdf'
            New-MarkedWatermarkFixture -Path $zipInput
            $fixtureContent = Read-WatermarkFixtureContent -Path $zipInput -QpdfPath $zipQpdf
            Assert-True -Value ($fixtureContent -match '/Artifact << /Subtype /Watermark /Type /Pagination >> BDC') -Name 'ZIP fixture has explicit target watermark block'
            Assert-True -Value ($fixtureContent -match '0 0 1 rg 10 10 40 40 re f') -Name 'ZIP fixture has separate blue body graphic'
            Assert-True -Value ($fixtureContent -match '(?s)\Aq 0 0 1 rg 10 10 40 40 re f Q\s+/Artifact << /Subtype /Watermark /Type /Pagination >> BDC\s+q 1 0 0 rg 20 20 10 10 re f Q\s+EMC\s*\z') -Name 'ZIP fixture keeps body before trailing marked watermark'
            $inputHash = (Get-FileHash -LiteralPath $zipInput -Algorithm SHA256).Hash
            $inputTime = (Get-Item -LiteralPath $zipInput).LastWriteTimeUtc.Ticks
            '' | & $zipBat '-NoPrompt' $zipInput
            $zipBatExitCode = $LASTEXITCODE
            Assert-Equal -Expected 0 -Actual $zipBatExitCode -Name 'watermark BAT from extracted ZIP exits zero'
            $outputs = @(Get-ChildItem -LiteralPath $zipInputDir -Filter '*_去水印.pdf' -File)
            Assert-Equal -Expected 1 -Actual $outputs.Count -Name 'watermark ZIP BAT creates exactly one output'
            if ($outputs.Count -eq 1) {
                $check = Invoke-WatermarkProcess -Path $zipQpdf -Arguments @('--check', $outputs[0].FullName)
                Assert-True -Value ($check.ExitCode -in @(0, 3)) -Name 'watermark ZIP BAT output passes extracted qpdf check'
                $pages = Invoke-WatermarkProcess -Path $zipQpdf -Arguments @('--show-npages', $outputs[0].FullName)
                Assert-True -Value ($pages.ExitCode -in @(0, 3)) -Name 'watermark ZIP BAT page count command succeeds'
                Assert-Equal -Expected '1' -Actual $pages.StdOut.Trim() -Name 'watermark ZIP BAT output has one page'
                $outputContent = Read-WatermarkFixtureContent -Path $outputs[0].FullName -QpdfPath $zipQpdf
                Assert-True -Value ($outputContent -notmatch '\bBDC\b') -Name 'watermark ZIP BAT output removes target BDC'
                Assert-Equal -Expected 'q 0 0 1 rg 10 10 40 40 re f Q' -Actual (($outputContent -replace '\s+', ' ').Trim()) -Name 'watermark ZIP BAT preserves all body drawing operations'
            }

            $isolatedOutput = Join-Path $zipInputDir '独立核心 输出 (2) &!.pdf'
            $oldPath = $env:PATH
            $oldPythonHome = [Environment]::GetEnvironmentVariable('PYTHONHOME', 'Process')
            $oldPythonPath = [Environment]::GetEnvironmentVariable('PYTHONPATH', 'Process')
            try {
                $env:PATH = Join-Path $env:SystemRoot 'System32'
                [Environment]::SetEnvironmentVariable('PYTHONHOME', $null, 'Process')
                [Environment]::SetEnvironmentVariable('PYTHONPATH', $null, 'Process')
                $isolatedVersion = Invoke-WatermarkProcess -Path $zipCore -Arguments @('--version')
                Assert-Equal -Expected 0 -Actual $isolatedVersion.ExitCode -Name 'ZIP core starts with System32-only PATH and no Python environment'
                Assert-Equal -Expected "0.2.0`r`n" -Actual $isolatedVersion.StdOut -Name 'isolated ZIP core version is exactly 0.2.0'
                $isolatedResult = Invoke-WatermarkProcess -Path $zipCore -Arguments @($zipInput, $isolatedOutput)
                Assert-Equal -Expected 0 -Actual $isolatedResult.ExitCode -Name 'isolated ZIP core processes real fixture without Python'
                $isolatedJson = $isolatedResult.StdOut | ConvertFrom-Json
                Assert-Equal -Expected 'success' -Actual $isolatedJson.status -Name 'isolated ZIP core reports success'
                Assert-Equal -Expected 1 -Actual $isolatedJson.pages -Name 'isolated ZIP core reports one page'
                Assert-Equal -Expected 1 -Actual $isolatedJson.removed_blocks -Name 'isolated ZIP core removes one marked block'
            }
            finally {
                $env:PATH = $oldPath
                [Environment]::SetEnvironmentVariable('PYTHONHOME', $oldPythonHome, 'Process')
                [Environment]::SetEnvironmentVariable('PYTHONPATH', $oldPythonPath, 'Process')
            }
            $isolatedContent = Read-WatermarkFixtureContent -Path $isolatedOutput -QpdfPath $zipQpdf
            Assert-True -Value ($isolatedContent -notmatch '\bBDC\b') -Name 'isolated ZIP core output has no target BDC'
            Assert-Equal -Expected 'q 0 0 1 rg 10 10 40 40 re f Q' -Actual (($isolatedContent -replace '\s+', ' ').Trim()) -Name 'isolated ZIP core preserves body drawing operations'
            Assert-Equal -Expected $inputHash -Actual (Get-FileHash -LiteralPath $zipInput -Algorithm SHA256).Hash -Name 'watermark ZIP processing leaves input SHA256 unchanged'
            Assert-Equal -Expected $inputTime -Actual (Get-Item -LiteralPath $zipInput).LastWriteTimeUtc.Ticks -Name 'watermark ZIP processing leaves input timestamp unchanged'
            Assert-Equal -Expected 0 -Actual @(Get-ChildItem -LiteralPath $zipInputDir -Filter '*.wm.tmp.pdf' -Force).Count -Name 'watermark ZIP processing leaves no wm temporary PDF'
        }
        finally {
            if (Test-Path -LiteralPath $zipTestRoot) {
                $resolvedCleanup = (Resolve-Path -LiteralPath $zipTestRoot).ProviderPath
                if (-not $resolvedCleanup.StartsWith($testsTmpPrefix, [StringComparison]::OrdinalIgnoreCase) -or
                    -not $resolvedCleanup.Equals($zipTestRoot, [StringComparison]::OrdinalIgnoreCase) -or
                    (Get-Item -LiteralPath $resolvedCleanup -Force).LinkType -in @('Junction', 'SymbolicLink')) {
                    throw "Refusing unsafe watermark ZIP test cleanup: $resolvedCleanup"
                }
                Remove-Item -LiteralPath $resolvedCleanup -Recurse -Force
            }
        }
    }
}
if ($script:failed -gt 0) { throw "$script:failed tests failed" }
Write-Host "$script:passed tests passed" -ForegroundColor Cyan
