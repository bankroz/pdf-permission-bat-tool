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
[IO.File]::WriteAllBytes($second, [byte[]](1))
$third = Get-UniqueOutputPath -InputPath $input
Assert-Equal -Expected (Join-Path $scratch '中文 & 文件!_可注释_3.pdf') -Actual $third -Name 'third output name'

$valid = Test-PdfInputPath -Path $input
Assert-True -Value $valid.IsValid -Name 'valid PDF path accepted'

$wrong = Join-Path $scratch 'not-pdf.txt'
Set-Content -LiteralPath $wrong -Value 'x'
$invalid = Test-PdfInputPath -Path $wrong
Assert-Equal -Expected 'Skipped' -Actual $invalid.Status -Name 'non-PDF skipped'

$missing = Test-PdfInputPath -Path (Join-Path $scratch 'missing.pdf')
Assert-Equal -Expected 'Skipped' -Actual $missing.Status -Name 'missing file skipped'

$invalidStatusRejected = $false
try {
    New-ProcessResult -Status 'Typo' -InputPath $input -Message 'invalid status' | Out-Null
}
catch {
    $invalidStatusRejected = $true
}
Assert-True -Value $invalidStatusRejected -Name 'unknown result status rejected'

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

$warningQpdf = Join-Path $integration 'warning-qpdf.cmd'
$warningQpdfLines = @(
    '@echo off',
    'copy /b "%~2" "%~3" >nul',
    'exit /b 3'
)
[IO.File]::WriteAllText($warningQpdf, ($warningQpdfLines -join "`r`n"), [Text.Encoding]::ASCII)
$warningResult = Invoke-PdfCopy -InputPath $plain -QpdfPath $warningQpdf
Assert-Equal -Expected 'Warning' -Actual $warningResult.Status -Name 'qpdf exit code 3 preserved as warning success'
Assert-True -Value (Test-Path -LiteralPath $warningResult.OutputPath -PathType Leaf) -Name 'warning output preserved'

$permissionQpdf = Join-Path $integration 'permission-qpdf.cmd'
$permissionQpdfLines = @(
    '@echo off',
    'echo Permission denied 1>&2',
    'exit /b 2'
)
[IO.File]::WriteAllText($permissionQpdf, ($permissionQpdfLines -join "`r`n"), [Text.Encoding]::ASCII)
$permissionResult = Invoke-PdfCopy -InputPath $plain -QpdfPath $permissionQpdf
Assert-Equal -Expected 'Failed' -Actual $permissionResult.Status -Name 'write permission failure rejected'
Assert-True -Value ($permissionResult.Message -match '写入权限') -Name 'write permission failure translated'

$beforeBatchOutputs = @(Get-ChildItem -LiteralPath $integration -Filter '普通 文件_可注释*.pdf').Count
$batchExitCode = Invoke-Main -InputFiles @($plain, $locked, $broken) -NoPrompt -QpdfPath $qpdf.FullName
Assert-Equal -Expected 1 -Actual $batchExitCode -Name 'mixed batch reports partial failure'
$afterBatchOutputs = @(Get-ChildItem -LiteralPath $integration -Filter '普通 文件_可注释*.pdf').Count
Assert-True -Value ($afterBatchOutputs -gt $beforeBatchOutputs) -Name 'mixed batch continues after failure'

$missingQpdfExitCode = Invoke-Main -InputFiles @($plain) -NoPrompt -QpdfPath (Join-Path $integration 'missing-qpdf.exe')
Assert-Equal -Expected 2 -Actual $missingQpdfExitCode -Name 'missing qpdf stops batch'

$brokenQpdf = Join-Path $integration 'broken-qpdf.exe'
[IO.File]::WriteAllBytes($brokenQpdf, [byte[]](0, 1, 2, 3))
$brokenQpdfExitCode = Invoke-Main -InputFiles @($plain) -NoPrompt -QpdfPath $brokenQpdf
Assert-Equal -Expected 2 -Actual $brokenQpdfExitCode -Name 'unstartable qpdf stops batch'

$wrongVersionQpdf = Join-Path $integration 'wrong-version-qpdf.cmd'
$wrongVersionQpdfLines = @(
    '@echo off',
    'echo qpdf version 1.0.0',
    'exit /b 0'
)
[IO.File]::WriteAllText($wrongVersionQpdf, ($wrongVersionQpdfLines -join "`r`n"), [Text.Encoding]::ASCII)
$wrongVersionExitCode = Invoke-Main -InputFiles @($plain) -NoPrompt -QpdfPath $wrongVersionQpdf
Assert-Equal -Expected 2 -Actual $wrongVersionExitCode -Name 'wrong qpdf version stops batch'

$beforeExceptionalBatch = @(Get-ChildItem -LiteralPath $integration -Filter '普通 文件_可注释*.pdf').Count
$exceptionEscaped = $false
$exceptionalBatchExitCode = $null
try {
    $invalidPath = 'illegal' + [char]0 + '.pdf'
    $exceptionalBatchExitCode = Invoke-Main -InputFiles @($invalidPath, $plain) -NoPrompt -QpdfPath $qpdf.FullName
}
catch {
    $exceptionEscaped = $true
}
Assert-Equal -Expected $false -Actual $exceptionEscaped -Name 'path preparation exception stays inside file boundary'
Assert-Equal -Expected 1 -Actual $exceptionalBatchExitCode -Name 'path preparation failure marks partial batch failure'
$afterExceptionalBatch = @(Get-ChildItem -LiteralPath $integration -Filter '普通 文件_可注释*.pdf').Count
Assert-True -Value ($afterExceptionalBatch -gt $beforeExceptionalBatch) -Name 'batch continues after path preparation exception'

Assert-True -Value (Confirm-Processing -NoPrompt) -Name 'non-interactive confirmation bypass'

$tempFiles = @(Get-ChildItem -LiteralPath $integration -Filter '*.tmp.pdf' -Force)
Assert-Equal -Expected 0 -Actual $tempFiles.Count -Name 'temporary files cleaned'

if ($DeliverySmokeTest) {
    $delivery = Join-Path $projectRoot 'dist\PDF权限处理工具_BAT版'
    $deliveryZip = Join-Path $projectRoot 'dist\PDF权限处理工具_BAT版.zip'
    $deliveryExists = Test-Path -LiteralPath $delivery -PathType Container
    Assert-True -Value $deliveryExists -Name 'delivery directory exists'
    Assert-True -Value ((Test-Path -LiteralPath $deliveryZip -PathType Leaf) -and ((Get-Item -LiteralPath $deliveryZip).Length -gt 0)) -Name 'delivery ZIP exists'

    if ($deliveryExists) {
        $deliveryBat = Join-Path $delivery 'PDF权限处理工具.bat'
        $deliveryScript = Join-Path $delivery 'tools\pdf_tool.ps1'
        $deliveryReadme = Join-Path $delivery '使用说明.txt'
        $deliveryQpdf = Join-Path $delivery 'qpdf\bin\qpdf.exe'
        $deliveryManifest = Join-Path $delivery 'SHA256SUMS.txt'

        Assert-True -Value (Test-Path -LiteralPath $deliveryBat -PathType Leaf) -Name 'delivery contains BAT launcher'
        Assert-True -Value (Test-Path -LiteralPath $deliveryScript -PathType Leaf) -Name 'delivery contains PowerShell logic'
        Assert-True -Value (Test-Path -LiteralPath $deliveryReadme -PathType Leaf) -Name 'delivery contains usage guide'
        Assert-True -Value (Test-Path -LiteralPath $deliveryQpdf -PathType Leaf) -Name 'delivery contains qpdf executable'
        Assert-True -Value (Test-Path -LiteralPath $deliveryManifest -PathType Leaf) -Name 'delivery contains SHA-256 manifest'

        $licenseFiles = @(Get-ChildItem -LiteralPath (Join-Path $delivery 'licenses') -File -ErrorAction SilentlyContinue)
        Assert-True -Value ($licenseFiles.Count -ge 3) -Name 'delivery contains qpdf license notices'

        if (Test-Path -LiteralPath $deliveryManifest -PathType Leaf) {
            $manifestValid = $true
            $manifestPaths = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
            foreach ($line in (Get-Content -LiteralPath $deliveryManifest)) {
                if ($line -notmatch '^([A-F0-9]{64})  (.+)$') {
                    $manifestValid = $false
                    break
                }
                $expectedHash = $Matches[1]
                $relativePath = $Matches[2]
                $manifestFile = [IO.Path]::GetFullPath((Join-Path $delivery $relativePath))
                $deliveryPrefix = $delivery.TrimEnd('\') + '\'
                if ((-not $manifestFile.StartsWith($deliveryPrefix, [StringComparison]::OrdinalIgnoreCase)) -or
                    (-not $manifestPaths.Add($relativePath)) -or
                    (-not (Test-Path -LiteralPath $manifestFile -PathType Leaf)) -or
                    ((Get-FileHash -Algorithm SHA256 -LiteralPath $manifestFile).Hash -ne $expectedHash)) {
                    $manifestValid = $false
                    break
                }
            }
            $deliveryPaths = @(Get-ChildItem -LiteralPath $delivery -Recurse -File |
                Where-Object { $_.FullName -ne $deliveryManifest } |
                ForEach-Object { $_.FullName.Substring($delivery.Length + 1) } |
                Sort-Object)
            $manifestPathList = @($manifestPaths | Sort-Object)
            if (($deliveryPaths -join "`n") -ne ($manifestPathList -join "`n")) {
                $manifestValid = $false
            }
            Assert-True -Value $manifestValid -Name 'delivery manifest validates every file'
        }

        if (Test-Path -LiteralPath $deliveryQpdf -PathType Leaf) {
            $deliveryVersion = & $deliveryQpdf --version
            Assert-Equal -Expected 0 -Actual $LASTEXITCODE -Name 'bundled qpdf starts'
            Assert-True -Value (($deliveryVersion -join ' ') -match '12\.4\.2') -Name 'bundled qpdf version pinned'
        }

        if (Test-Path -LiteralPath $deliveryZip -PathType Leaf) {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zipArchive = [IO.Compression.ZipFile]::OpenRead($deliveryZip)
            try {
                $zipFileEntries = @($zipArchive.Entries | Where-Object { $_.Name } | ForEach-Object { $_.FullName.Replace('\', '/') } | Sort-Object)
            }
            finally {
                $zipArchive.Dispose()
            }
            $expectedZipEntries = @(Get-ChildItem -LiteralPath $delivery -Recurse -File | ForEach-Object {
                'PDF权限处理工具_BAT版/' + $_.FullName.Substring($delivery.Length + 1).Replace('\', '/')
            } | Sort-Object)
            Assert-Equal -Expected ($expectedZipEntries -join "`n") -Actual ($zipFileEntries -join "`n") -Name 'ZIP contains exact delivery file set'

            $testsTmpRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot 'tests\tmp'))
            $zipTestRoot = [IO.Path]::GetFullPath((Join-Path $testsTmpRoot ('zip acceptance ' + [guid]::NewGuid().ToString('N'))))
            $testsTmpPrefix = $testsTmpRoot.TrimEnd('\') + '\'
            if (-not $zipTestRoot.StartsWith($testsTmpPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing unsafe ZIP test path: $zipTestRoot"
            }
            try {
                Expand-Archive -LiteralPath $deliveryZip -DestinationPath $zipTestRoot
                $zipToolRoot = Join-Path $zipTestRoot 'PDF权限处理工具_BAT版'
                $zipQpdf = Join-Path $zipToolRoot 'qpdf\bin\qpdf.exe'
                $zipBat = Join-Path $zipToolRoot 'PDF权限处理工具.bat'
                $zipManifest = Join-Path $zipToolRoot 'SHA256SUMS.txt'

                $zipManifestValid = Test-Path -LiteralPath $zipManifest -PathType Leaf
                $zipManifestPaths = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
                if ($zipManifestValid) {
                    foreach ($line in (Get-Content -LiteralPath $zipManifest)) {
                        if ($line -notmatch '^([A-F0-9]{64})  (.+)$') {
                            $zipManifestValid = $false
                            break
                        }
                        $expectedHash = $Matches[1]
                        $relativePath = $Matches[2]
                        $zipManifestFile = [IO.Path]::GetFullPath((Join-Path $zipToolRoot $relativePath))
                        $zipToolPrefix = $zipToolRoot.TrimEnd('\') + '\'
                        if ((-not $zipManifestFile.StartsWith($zipToolPrefix, [StringComparison]::OrdinalIgnoreCase)) -or
                            (-not $zipManifestPaths.Add($relativePath)) -or
                            (-not (Test-Path -LiteralPath $zipManifestFile -PathType Leaf)) -or
                            ((Get-FileHash -Algorithm SHA256 -LiteralPath $zipManifestFile).Hash -ne $expectedHash)) {
                            $zipManifestValid = $false
                            break
                        }
                    }
                    $zipActualPaths = @(Get-ChildItem -LiteralPath $zipToolRoot -Recurse -File |
                        Where-Object { $_.FullName -ne $zipManifest } |
                        ForEach-Object { $_.FullName.Substring($zipToolRoot.Length + 1) } |
                        Sort-Object)
                    $zipManifestPathList = @($zipManifestPaths | Sort-Object)
                    if (($zipActualPaths -join "`n") -ne ($zipManifestPathList -join "`n")) {
                        $zipManifestValid = $false
                    }
                }
                Assert-True -Value $zipManifestValid -Name 'extracted ZIP manifest validates exact file set and bytes'

                $zipInputDir = Join-Path $zipTestRoot 'input (中文 &!)'
                New-Item -ItemType Directory -Force -Path $zipInputDir | Out-Null
                $zipInput = Join-Path $zipInputDir 'ZIP BAT 验收 (1) &!.pdf'
                & $zipQpdf '--empty' $zipInput
                $zipFixtureExitCode = $LASTEXITCODE
                '' | & $zipBat '-NoPrompt' $zipInput
                $zipBatExitCode = $LASTEXITCODE
                $zipOutput = @(Get-ChildItem -LiteralPath $zipInputDir -Filter '*_可注释.pdf' -File)
                Assert-Equal -Expected 0 -Actual $zipFixtureExitCode -Name 'ZIP qpdf creates acceptance fixture'
                Assert-Equal -Expected 0 -Actual $zipBatExitCode -Name 'BAT runs from extracted ZIP'
                Assert-Equal -Expected 1 -Actual $zipOutput.Count -Name 'BAT from ZIP creates output for special path'
            }
            finally {
                if (Test-Path -LiteralPath $zipTestRoot) {
                    Remove-Item -LiteralPath $zipTestRoot -Recurse -Force
                }
            }
        }
    }
}

if ($script:failed -gt 0) {
    throw "$script:failed tests failed"
}

Write-Host "$script:passed tests passed" -ForegroundColor Cyan
