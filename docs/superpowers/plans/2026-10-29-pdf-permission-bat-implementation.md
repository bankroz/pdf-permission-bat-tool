# Windows 10 PDF Permission BAT Tool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and verify a portable Windows 10 x64 folder that batch-generates non-overwriting, decrypted PDF copies through a BAT launcher and bundled qpdf.

**Architecture:** A tiny BAT file launches a focused Windows PowerShell 5.1 script. The script owns file selection, confirmation, safe output naming, per-file qpdf execution, temporary-file cleanup, Chinese status mapping, and result summary. Separate acquisition and build scripts pin and verify the official qpdf archive, then assemble the end-user folder under `dist/`.

**Tech Stack:** Windows Batch, Windows PowerShell 5.1, .NET Framework WinForms, qpdf 12.4.2 msvc64, Git.

---

## File map

- `.gitignore`: excludes downloaded vendor payloads, generated distributions, and test scratch files.
- `scripts/Fetch-Qpdf.ps1`: downloads the pinned official qpdf ZIP, verifies SHA-256, and extracts it reproducibly.
- `scripts/Build-Portable.ps1`: assembles the final portable directory and writes a SHA-256 manifest.
- `src/PDF权限处理工具.bat`: double-click and drag/drop launcher.
- `src/tools/pdf_tool.ps1`: all user interaction and PDF-processing logic; saved as UTF-8 with BOM for Windows PowerShell 5.1.
- `src/使用说明.txt`: end-user instructions, limitations, privacy statement, and troubleshooting.
- `tests/Run-Tests.ps1`: dependency-free unit and integration test runner.
- `dist/PDF权限处理工具_BAT版/`: generated, runnable delivery directory.

### Task 1: Pin and acquire qpdf

**Files:**
- Create: `.gitignore`
- Create: `scripts/Fetch-Qpdf.ps1`

- [ ] **Step 1: Write the acquisition contract check**

Run this before the script exists:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Fetch-Qpdf.ps1 -WhatIf
```

Expected: FAIL because `scripts/Fetch-Qpdf.ps1` does not exist.

- [ ] **Step 2: Implement the pinned downloader**

Create a script with these immutable values and checks:

```powershell
[CmdletBinding(SupportsShouldProcess = $true)]
param()

$ErrorActionPreference = 'Stop'
$version = '12.4.2'
$archiveName = "qpdf-$version-msvc64.zip"
$downloadUrl = "https://github.com/qpdf/qpdf/releases/download/v$version/$archiveName"
$expectedSha256 = 'DB87077E683630C1217E0E8F9A20A9749D952AB676E881C3689187763A5DE25D'
$projectRoot = Split-Path -Parent $PSScriptRoot
$vendorDir = Join-Path $projectRoot 'vendor'
$archivePath = Join-Path $vendorDir $archiveName
$extractDir = Join-Path $vendorDir "qpdf-$version-msvc64"

New-Item -ItemType Directory -Force -Path $vendorDir | Out-Null
if (-not (Test-Path -LiteralPath $archivePath)) {
    Invoke-WebRequest -UseBasicParsing -Uri $downloadUrl -OutFile $archivePath
}
$actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath).Hash
if ($actual -ne $expectedSha256) {
    throw "qpdf 下载文件校验失败。期望 $expectedSha256，实际 $actual。"
}
if (-not (Test-Path -LiteralPath $extractDir)) {
    Expand-Archive -LiteralPath $archivePath -DestinationPath $vendorDir
}
$qpdfExe = Get-ChildItem -LiteralPath $extractDir -Filter qpdf.exe -Recurse -File |
    Select-Object -First 1
if (-not $qpdfExe) { throw 'qpdf 压缩包中未找到 qpdf.exe。' }
& $qpdfExe.FullName --version
if ($LASTEXITCODE -ne 0) { throw 'qpdf.exe 无法启动。' }
Write-Host "qpdf 已就绪：$($qpdfExe.FullName)"
```

Create `.gitignore`:

```gitignore
.superpowers/
vendor/
dist/
tests/tmp/
*.tmp.pdf
```

- [ ] **Step 3: Run and verify acquisition**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Fetch-Qpdf.ps1
```

Expected: the archive hash matches, extraction succeeds, and `qpdf version 12.4.2` is printed.

- [ ] **Step 4: Commit acquisition source**

```powershell
git add .gitignore scripts/Fetch-Qpdf.ps1
git commit -m "build: pin portable qpdf dependency"
```

### Task 2: Build tested naming and result primitives

**Files:**
- Create: `tests/Run-Tests.ps1`
- Create: `src/tools/pdf_tool.ps1`

- [ ] **Step 1: Write failing unit tests**

Create a dependency-free runner that dot-sources the production script in library mode and verifies exact behavior:

```powershell
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $projectRoot 'src\tools\pdf_tool.ps1'
. $scriptPath -LibraryMode

$script:passed = 0
$script:failed = 0
function Assert-Equal([object]$Expected, [object]$Actual, [string]$Name) {
    if ($Expected -eq $Actual) { $script:passed++; Write-Host "PASS $Name"; return }
    $script:failed++; Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual"
}
function Assert-True([bool]$Value, [string]$Name) {
    Assert-Equal $true $Value $Name
}

$scratch = Join-Path $projectRoot 'tests\tmp\unit'
if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
$input = Join-Path $scratch '中文 & 文件!.pdf'
[IO.File]::WriteAllBytes($input, [byte[]](1, 2, 3))

$first = Get-UniqueOutputPath -InputPath $input
Assert-Equal (Join-Path $scratch '中文 & 文件!_可注释.pdf') $first 'first output name'
[IO.File]::WriteAllBytes($first, [byte[]](1))
$second = Get-UniqueOutputPath -InputPath $input
Assert-Equal (Join-Path $scratch '中文 & 文件!_可注释_2.pdf') $second 'numbered output name'

$valid = Test-PdfInputPath -Path $input
Assert-True $valid.IsValid 'valid PDF path accepted'
$wrong = Join-Path $scratch 'not-pdf.txt'
Set-Content -LiteralPath $wrong -Value 'x'
$invalid = Test-PdfInputPath -Path $wrong
Assert-Equal 'Skipped' $invalid.Status 'non-PDF skipped'

if ($script:failed -gt 0) { throw "$script:failed tests failed" }
Write-Host "$script:passed tests passed"
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
```

Expected: FAIL because production functions do not exist.

- [ ] **Step 3: Implement the primitives and typed result shape**

Create `src/tools/pdf_tool.ps1` with:

```powershell
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
    param([string]$Status, [string]$InputPath, [string]$OutputPath, [string]$Message, [string]$Details = '')
    [pscustomobject]@{ Status = $Status; InputPath = $InputPath; OutputPath = $OutputPath; Message = $Message; Details = $Details }
}

function Test-PdfInputPath {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return New-ProcessResult 'Skipped' $Path '' '文件不存在或已被移动。'
    }
    if ([IO.Path]::GetExtension($Path) -ine '.pdf') {
        return New-ProcessResult 'Skipped' $Path '' '不是 PDF 文件。'
    }
    return New-ProcessResult 'Valid' ([IO.Path]::GetFullPath($Path)) '' '输入有效。'
}

function Get-UniqueOutputPath {
    param([Parameter(Mandatory)][string]$InputPath)
    $directory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($InputPath))
    $stem = [IO.Path]::GetFileNameWithoutExtension($InputPath)
    $candidate = Join-Path $directory "${stem}_可注释.pdf"
    $index = 2
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $directory "${stem}_可注释_${index}.pdf"
        $index++
    }
    return $candidate
}
```

At this stage the file contains the parameter block and the three primitive functions only. The guarded command entry point is added together with `Invoke-Main` in Task 3, so every referenced function exists whenever the script is executed directly.

- [ ] **Step 4: Run tests to verify pass**

Run the test command again.

Expected: all naming and validation tests print `PASS`, with zero failures.

- [ ] **Step 5: Commit primitives**

```powershell
git add tests/Run-Tests.ps1 src/tools/pdf_tool.ps1
git commit -m "feat: add safe PDF path primitives"
```

### Task 3: Implement batch processing and launcher

**Files:**
- Modify: `tests/Run-Tests.ps1`
- Modify: `src/tools/pdf_tool.ps1`
- Create: `src/PDF权限处理工具.bat`

- [ ] **Step 1: Add failing integration assertions**

Extend `tests/Run-Tests.ps1` after locating the downloaded `qpdf.exe`. Generate a normal PDF, a restriction-only PDF, a password-required PDF, and a corrupt file. Assert:

```powershell
$qpdf = Get-ChildItem (Join-Path $projectRoot 'vendor') -Filter qpdf.exe -Recurse -File | Select-Object -First 1
if (-not $qpdf) { throw 'Run scripts/Fetch-Qpdf.ps1 first.' }
$integration = Join-Path $projectRoot 'tests\tmp\integration 中文 &!'
New-Item -ItemType Directory -Force -Path $integration | Out-Null
$plain = Join-Path $integration '普通 文件.pdf'
& $qpdf.FullName --empty $plain
Assert-Equal 0 $LASTEXITCODE 'create plain fixture'

$plainResult = Invoke-PdfCopy -InputPath $plain -QpdfPath $qpdf.FullName
Assert-Equal 'Success' $plainResult.Status 'plain PDF processed'
Assert-True (Test-Path -LiteralPath $plainResult.OutputPath) 'plain output exists'

$restricted = Join-Path $integration '限制注释.pdf'
& $qpdf.FullName $plain $restricted --encrypt '' 'owner-secret' 256 --modify=none --annotate=n --
Assert-Equal 0 $LASTEXITCODE 'create restricted fixture'
$restrictedResult = Invoke-PdfCopy -InputPath $restricted -QpdfPath $qpdf.FullName
Assert-True ($restrictedResult.Status -in @('Success', 'Warning')) 'restricted PDF processed'

$locked = Join-Path $integration '需要密码.pdf'
& $qpdf.FullName $plain $locked --encrypt 'known-open-password' 'owner-secret' 256 --
Assert-Equal 0 $LASTEXITCODE 'create locked fixture'
$lockedResult = Invoke-PdfCopy -InputPath $locked -QpdfPath $qpdf.FullName
Assert-Equal 'Failed' $lockedResult.Status 'open-password PDF rejected'
Assert-True ($lockedResult.Message -match '密码') 'password failure translated'

$broken = Join-Path $integration '损坏.pdf'
Set-Content -LiteralPath $broken -Value 'not a PDF'
$brokenResult = Invoke-PdfCopy -InputPath $broken -QpdfPath $qpdf.FullName
Assert-Equal 'Failed' $brokenResult.Status 'corrupt PDF rejected'

$tempFiles = Get-ChildItem -LiteralPath $integration -Filter '*.tmp.pdf' -Force
Assert-Equal 0 @($tempFiles).Count 'temporary files cleaned'
```

- [ ] **Step 2: Run tests to verify failure**

Expected: FAIL because `Invoke-PdfCopy` is undefined.

- [ ] **Step 3: Implement qpdf invocation and batch flow**

Add focused functions to `pdf_tool.ps1`:

```powershell
function Get-FriendlyQpdfError {
    param([string]$Details)
    if ($Details -match '(?i)password|invalid password') { return '文件需要已知的打开密码，未处理。' }
    if ($Details -match '(?i)not a pdf|damaged|unable to find|xref') { return '文件损坏、格式无效或 qpdf 无法解析。' }
    if ($Details -match '(?i)permission denied|access.*denied') { return '原文件目录没有写入权限，请复制到可写目录后重试。' }
    return 'qpdf 未能处理该文件；文件可能损坏或带有不支持的限制。'
}

function Invoke-PdfCopy {
    param([Parameter(Mandatory)][string]$InputPath, [Parameter(Mandatory)][string]$QpdfPath)
    $validation = Test-PdfInputPath -Path $InputPath
    if ($validation.Status -ne 'Valid') { return $validation }
    $fullInput = $validation.InputPath
    $finalPath = Get-UniqueOutputPath -InputPath $fullInput
    $directory = [IO.Path]::GetDirectoryName($fullInput)
    $stem = [IO.Path]::GetFileNameWithoutExtension($fullInput)
    $tempPath = Join-Path $directory ('.{0}.{1}.tmp.pdf' -f $stem, [guid]::NewGuid().ToString('N'))
    try {
        $lines = @(& $QpdfPath '--decrypt' $fullInput $tempPath 2>&1 | ForEach-Object { $_.ToString() })
        $exitCode = $LASTEXITCODE
        $details = $lines -join [Environment]::NewLine
        $validOutput = (Test-Path -LiteralPath $tempPath -PathType Leaf) -and ((Get-Item -LiteralPath $tempPath).Length -gt 0)
        if (($exitCode -in @(0, 3)) -and $validOutput) {
            [IO.File]::Move($tempPath, $finalPath)
            if ($exitCode -eq 3) { return New-ProcessResult 'Warning' $fullInput $finalPath '已生成副本，但 qpdf 报告文件结构警告。' $details }
            return New-ProcessResult 'Success' $fullInput $finalPath '已生成处理后的副本。' $details
        }
        return New-ProcessResult 'Failed' $fullInput '' (Get-FriendlyQpdfError -Details $details) $details
    } catch [UnauthorizedAccessException] {
        return New-ProcessResult 'Failed' $fullInput '' '原文件目录没有写入权限，请复制到可写目录后重试。' $_.Exception.Message
    } catch {
        return New-ProcessResult 'Failed' $fullInput '' '处理过程中发生错误，未修改原文件。' $_.Exception.Message
    } finally {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
    }
}
```

Add the user-interaction and batch functions:

```powershell
function Select-PdfFiles {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = '选择要处理的 PDF 文件'
    $dialog.Filter = 'PDF 文件 (*.pdf)|*.pdf|所有文件 (*.*)|*.*'
    $dialog.Multiselect = $true
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return @($dialog.FileNames)
    }
    return @()
}

function Confirm-Processing {
    param([switch]$NoPrompt)
    if ($NoPrompt) { return $true }
    Add-Type -AssemblyName System.Windows.Forms
    $text = "本工具仅处理你有权修改的文件。`n`n原文件不会被覆盖。处理后的副本可能使数字签名失效。`n`n是否继续？"
    $answer = [System.Windows.Forms.MessageBox]::Show(
        $text,
        'PDF 权限处理工具',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    return $answer -eq [System.Windows.Forms.DialogResult]::Yes
}

function Resolve-BundledQpdf {
    param([string]$ExplicitPath)
    if ($ExplicitPath) {
        if (Test-Path -LiteralPath $ExplicitPath -PathType Leaf) { return [IO.Path]::GetFullPath($ExplicitPath) }
        return $null
    }
    $toolRoot = Split-Path -Parent $PSScriptRoot
    $qpdfRoot = Join-Path $toolRoot 'qpdf'
    if (-not (Test-Path -LiteralPath $qpdfRoot -PathType Container)) { return $null }
    $exe = Get-ChildItem -LiteralPath $qpdfRoot -Filter qpdf.exe -Recurse -File | Select-Object -First 1
    if ($exe) { return $exe.FullName }
    return $null
}

function Show-Result {
    param([Parameter(Mandatory)]$Result, [int]$Index, [int]$Total)
    $name = [IO.Path]::GetFileName($Result.InputPath)
    switch ($Result.Status) {
        'Success' { Write-Host "[$Index/$Total] 成功：$name -> $($Result.OutputPath)" -ForegroundColor Green }
        'Warning' { Write-Host "[$Index/$Total] 警告成功：$name -> $($Result.OutputPath)`n  $($Result.Message)" -ForegroundColor Yellow }
        'Failed'  { Write-Host "[$Index/$Total] 失败：$name`n  $($Result.Message)" -ForegroundColor Red }
        default   { Write-Host "[$Index/$Total] 跳过：$name`n  $($Result.Message)" -ForegroundColor DarkYellow }
    }
}

function Show-Summary {
    param([object[]]$Results, [switch]$NoPrompt)
    $success = @($Results | Where-Object Status -eq 'Success').Count
    $warning = @($Results | Where-Object Status -eq 'Warning').Count
    $failed = @($Results | Where-Object Status -eq 'Failed').Count
    $skipped = @($Results | Where-Object Status -eq 'Skipped').Count
    Write-Host ''
    Write-Host "处理完成：成功 $success，警告成功 $warning，失败 $failed，跳过 $skipped。"
    Write-Host '请用福昕打开新文件，再试一次“打字机”。如果仍不能输入，原因可能不是普通 PDF 权限限制。'
    $directories = @($Results | Where-Object { $_.OutputPath } | ForEach-Object { [IO.Path]::GetDirectoryName($_.OutputPath) } | Sort-Object -Unique)
    if ((-not $NoPrompt) -and $directories.Count -eq 1) {
        Add-Type -AssemblyName System.Windows.Forms
        $answer = [System.Windows.Forms.MessageBox]::Show('是否打开输出文件夹？', '处理完成', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Information)
        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) { Start-Process -FilePath 'explorer.exe' -ArgumentList @($directories[0]) }
    } elseif ($directories.Count -gt 1) {
        Write-Host '输出目录：'
        $directories | ForEach-Object { Write-Host "  $_" }
    }
}

function Invoke-Main {
    param([string[]]$InputFiles, [switch]$NoPrompt, [string]$QpdfPath)
    $resolvedQpdf = Resolve-BundledQpdf -ExplicitPath $QpdfPath
    if (-not $resolvedQpdf) {
        Write-Host '工具文件不完整：未找到随程序附带的 qpdf.exe。请重新解压完整目录。' -ForegroundColor Red
        return 2
    }
    $paths = @($InputFiles | Where-Object { $_ })
    if ($paths.Count -eq 0) { $paths = @(Select-PdfFiles) }
    if ($paths.Count -eq 0) { Write-Host '未选择文件。'; return 0 }
    if (-not (Confirm-Processing -NoPrompt:$NoPrompt)) { Write-Host '已取消。'; return 0 }
    $results = New-Object System.Collections.Generic.List[object]
    for ($index = 0; $index -lt $paths.Count; $index++) {
        $result = Invoke-PdfCopy -InputPath $paths[$index] -QpdfPath $resolvedQpdf
        $results.Add($result)
        Show-Result -Result $result -Index ($index + 1) -Total $paths.Count
    }
    Show-Summary -Results $results.ToArray() -NoPrompt:$NoPrompt
    if (@($results | Where-Object Status -eq 'Failed').Count -gt 0) { return 1 }
    return 0
}

if (-not $LibraryMode) {
    $mainExitCode = Invoke-Main -InputFiles $InputFiles -NoPrompt:$NoPrompt -QpdfPath $QpdfPath
    exit $mainExitCode
}
```

`Invoke-Main` stops the whole batch only when qpdf is missing. Every selected file otherwise crosses an independent `Invoke-PdfCopy` exception boundary.

- [ ] **Step 4: Add BAT launcher**

Create:

```bat
@echo off
setlocal DisableDelayedExpansion
set "TOOL_ROOT=%~dp0"
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%TOOL_ROOT%tools\pdf_tool.ps1" %*
set "TOOL_EXIT=%ERRORLEVEL%"
echo(
pause
exit /b %TOOL_EXIT%
```

The BAT file must contain ASCII bytes only, have no BOM, and contain neither `chcp` nor `enabledelayedexpansion`. Add test assertions for those rules. All `.ps1` files that contain Chinese text must start with the UTF-8 BOM bytes `EF BB BF` so Windows PowerShell 5.1 does not decode them as CP936.

- [ ] **Step 5: Run unit and integration tests**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
```

Expected: all assertions pass, password-required and damaged PDFs fail safely, all valid outputs exist, no temporary PDF remains, and input hashes are unchanged.

- [ ] **Step 6: Commit processing implementation**

```powershell
git add src/PDF权限处理工具.bat src/tools/pdf_tool.ps1 tests/Run-Tests.ps1
git commit -m "feat: add portable batch PDF processing"
```

### Task 4: Assemble and verify the portable delivery

**Files:**
- Create: `src/使用说明.txt`
- Create: `scripts/Build-Portable.ps1`
- Modify: `tests/Run-Tests.ps1`

- [ ] **Step 1: Write end-user documentation**

Document exactly: Windows 10 x64 support; double-click multi-select; multi-file drag/drop; outputs beside originals; non-overwriting suffix rule; no unknown-password cracking; signature warning; local-only processing; troubleshooting for missing qpdf, invalid PDF, password, and unwritable directories; qpdf version, source URL, and license location.

- [ ] **Step 2: Implement the build script**

`Build-Portable.ps1` must:

```powershell
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'Fetch-Qpdf.ps1')
$delivery = Join-Path $projectRoot 'dist\PDF权限处理工具_BAT版'
if (Test-Path -LiteralPath $delivery) { Remove-Item -LiteralPath $delivery -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $delivery 'tools'), (Join-Path $delivery 'licenses') | Out-Null
Copy-Item -LiteralPath (Join-Path $projectRoot 'src\PDF权限处理工具.bat') -Destination $delivery
Copy-Item -LiteralPath (Join-Path $projectRoot 'src\tools\pdf_tool.ps1') -Destination (Join-Path $delivery 'tools')
Copy-Item -LiteralPath (Join-Path $projectRoot 'src\使用说明.txt') -Destination $delivery
$vendorRoot = Join-Path $projectRoot 'vendor\qpdf-12.4.2-msvc64'
Copy-Item -LiteralPath $vendorRoot -Destination (Join-Path $delivery 'qpdf') -Recurse
$licenseCandidates = Get-ChildItem -LiteralPath $vendorRoot -Recurse -File | Where-Object { $_.Name -match '(?i)license|copying|copyright|artistic' }
foreach ($file in $licenseCandidates) { Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $delivery 'licenses') -Force }
$manifest = Get-ChildItem -LiteralPath $delivery -Recurse -File | Sort-Object FullName | Get-FileHash -Algorithm SHA256
$manifest | ForEach-Object { '{0}  {1}' -f $_.Hash, $_.Path.Substring($delivery.Length + 1) } |
    Set-Content -LiteralPath (Join-Path $delivery 'SHA256SUMS.txt') -Encoding UTF8
Write-Host "便携版已生成：$delivery"
```

- [ ] **Step 3: Extend tests with delivery smoke checks**

Assert the built folder contains the BAT, PowerShell script, README, qpdf executable, at least one license file, and manifest. Invoke bundled qpdf `--version` and require exit code `0`.

- [ ] **Step 4: Build and run the complete verification suite**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-Portable.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1 -DeliverySmokeTest
git status --short
```

Expected: build succeeds, all tests pass, qpdf reports version 12.4.2, and only intended source/documentation changes appear in Git.

- [ ] **Step 5: Commit build and documentation source**

```powershell
git add src/使用说明.txt scripts/Build-Portable.ps1 tests/Run-Tests.ps1
git commit -m "build: assemble verified portable delivery"
```

### Task 5: Final manual acceptance

**Files:**
- Verify: `dist/PDF权限处理工具_BAT版/`

- [ ] **Step 1: Launch the BAT without arguments**

Expected: multi-select dialog opens; cancel exits normally after the console pause.

- [ ] **Step 2: Drag multiple fixtures onto the BAT**

Use one ordinary PDF, one restriction-only PDF, one password-required PDF, and one damaged PDF.

Expected: ordinary and restriction-only copies are generated; password-required and damaged files receive clear Chinese failures; batch continues.

- [ ] **Step 3: Verify immutability and collision handling**

Compare SHA-256 hashes and timestamps of all inputs before and after. Run the same successful inputs twice.

Expected: originals are unchanged; the second run creates `_可注释_2.pdf` rather than overwriting the first output.

- [ ] **Step 4: Inspect final delivery contents**

Expected: no source tests, Git metadata, downloaded ZIP, temporary PDF, or user test document is present inside `dist/PDF权限处理工具_BAT版/`.
