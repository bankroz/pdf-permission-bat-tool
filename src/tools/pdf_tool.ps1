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
        [Parameter(Mandatory)]
        [ValidateSet('Valid', 'Success', 'Warning', 'Failed', 'Skipped')]
        [string]$Status,
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

function Get-FriendlyQpdfError {
    param([string]$Details)

    if ($Details -match '(?i)password|invalid password') {
        return '文件需要已知的打开密码，未处理。'
    }

    if ($Details -match '(?i)not a pdf|damaged|unable to find|xref|pdf header') {
        return '文件损坏、格式无效或 qpdf 无法解析。'
    }

    if ($Details -match '(?i)permission denied|access.*denied|cannot open.*write') {
        return '原文件目录没有写入权限，请复制到可写目录后重试。'
    }

    return 'qpdf 未能处理该文件；文件可能损坏或带有不支持的限制。'
}

function Invoke-PdfCopy {
    param(
        [Parameter(Mandatory)][string]$InputPath,
        [Parameter(Mandatory)][string]$QpdfPath
    )

    $fullInput = $InputPath
    $tempPath = $null

    try {
        $validation = Test-PdfInputPath -Path $InputPath
        if (-not $validation.IsValid) {
            return $validation
        }

        $fullInput = $validation.InputPath
        $finalPath = Get-UniqueOutputPath -InputPath $fullInput
        $directory = [IO.Path]::GetDirectoryName($fullInput)
        $stem = [IO.Path]::GetFileNameWithoutExtension($fullInput)
        $tempName = '.{0}.{1}.tmp.pdf' -f $stem, [guid]::NewGuid().ToString('N')
        $tempPath = Join-Path $directory $tempName

        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $lines = @(& $QpdfPath '--decrypt' $fullInput $tempPath 2>&1 |
                ForEach-Object { $_.ToString() })
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        $details = $lines -join [Environment]::NewLine
        $validOutput = (Test-Path -LiteralPath $tempPath -PathType Leaf) -and
            ((Get-Item -LiteralPath $tempPath).Length -gt 0)

        if (($exitCode -in @(0, 3)) -and $validOutput) {
            [IO.File]::Move($tempPath, $finalPath)

            if ($exitCode -eq 3) {
                return New-ProcessResult -Status 'Warning' -InputPath $fullInput -OutputPath $finalPath `
                    -Message '已生成副本，但 qpdf 报告文件结构警告。' -Details $details
            }

            return New-ProcessResult -Status 'Success' -InputPath $fullInput -OutputPath $finalPath `
                -Message '已生成处理后的副本。' -Details $details
        }

        return New-ProcessResult -Status 'Failed' -InputPath $fullInput `
            -Message (Get-FriendlyQpdfError -Details $details) -Details $details
    }
    catch [UnauthorizedAccessException] {
        return New-ProcessResult -Status 'Failed' -InputPath $fullInput `
            -Message '原文件目录没有写入权限，请复制到可写目录后重试。' -Details $_.Exception.Message
    }
    catch {
        return New-ProcessResult -Status 'Failed' -InputPath $fullInput `
            -Message '处理过程中发生错误，未修改原文件。' -Details $_.Exception.Message
    }
    finally {
        if ($tempPath -and (Test-Path -LiteralPath $tempPath)) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Select-PdfFiles {
    Add-Type -AssemblyName System.Windows.Forms

    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = '选择要处理的 PDF 文件'
    $dialog.Filter = 'PDF 文件 (*.pdf)|*.pdf|所有文件 (*.*)|*.*'
    $dialog.Multiselect = $true
    $dialog.RestoreDirectory = $true

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return @($dialog.FileNames)
    }

    return @()
}

function Confirm-Processing {
    param([switch]$NoPrompt)

    if ($NoPrompt) {
        return $true
    }

    Add-Type -AssemblyName System.Windows.Forms
    $text = @'
本工具仅处理你有权修改的文件。

原文件不会被覆盖。处理后的副本可能使数字签名失效。

是否继续？
'@
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
        if (Test-Path -LiteralPath $ExplicitPath -PathType Leaf) {
            return [IO.Path]::GetFullPath($ExplicitPath)
        }
        return $null
    }

    $toolRoot = Split-Path -Parent $PSScriptRoot
    $qpdfExe = Join-Path $toolRoot 'qpdf\bin\qpdf.exe'
    if (Test-Path -LiteralPath $qpdfExe -PathType Leaf) {
        return [IO.Path]::GetFullPath($qpdfExe)
    }

    return $null
}

function Test-QpdfExecutable {
    param([Parameter(Mandatory)][string]$Path)

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $versionLines = @(& $Path '--version' 2>&1 | ForEach-Object { $_.ToString() })
        $exitCode = $LASTEXITCODE
    }
    catch {
        return [pscustomobject]@{ IsValid = $false; Details = $_.Exception.Message }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    $versionText = $versionLines -join [Environment]::NewLine
    $isExpectedVersion = $exitCode -eq 0 -and $versionText -match '(?m)^qpdf version 12\.4\.2\b'
    return [pscustomobject]@{ IsValid = $isExpectedVersion; Details = $versionText }
}

function Show-Result {
    param(
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][int]$Total
    )

    try {
        $name = [IO.Path]::GetFileName($Result.InputPath)
    }
    catch {
        $name = '（无法解析的输入路径）'
    }
    switch ($Result.Status) {
        'Success' {
            Write-Host "[$Index/$Total] 成功：$name -> $($Result.OutputPath)" -ForegroundColor Green
        }
        'Warning' {
            Write-Host "[$Index/$Total] 警告成功：$name -> $($Result.OutputPath)" -ForegroundColor Yellow
            Write-Host "  $($Result.Message)" -ForegroundColor Yellow
        }
        'Failed' {
            Write-Host "[$Index/$Total] 失败：$name" -ForegroundColor Red
            Write-Host "  $($Result.Message)" -ForegroundColor Red
        }
        'Skipped' {
            Write-Host "[$Index/$Total] 跳过：$name" -ForegroundColor DarkYellow
            Write-Host "  $($Result.Message)" -ForegroundColor DarkYellow
        }
        default {
            throw "未知处理状态：$($Result.Status)"
        }
    }
}

function Show-Summary {
    param(
        [Parameter(Mandatory)][object[]]$Results,
        [switch]$NoPrompt
    )

    $success = @($Results | Where-Object { $_.Status -eq 'Success' }).Count
    $warning = @($Results | Where-Object { $_.Status -eq 'Warning' }).Count
    $failed = @($Results | Where-Object { $_.Status -eq 'Failed' }).Count
    $skipped = @($Results | Where-Object { $_.Status -eq 'Skipped' }).Count

    Write-Host ''
    Write-Host "处理完成：成功 $success，警告成功 $warning，失败 $failed，跳过 $skipped。" -ForegroundColor Cyan
    Write-Host '请用福昕打开新文件，再试一次“打字机”。如果仍不能输入，原因可能不是普通的 PDF 权限限制，也可能与福昕的工具状态、文件签名或文件结构有关。'

    $directories = @($Results |
        Where-Object { $_.OutputPath } |
        ForEach-Object { [IO.Path]::GetDirectoryName($_.OutputPath) } |
        Sort-Object -Unique)

    if ((-not $NoPrompt) -and $directories.Count -eq 1) {
        Add-Type -AssemblyName System.Windows.Forms
        $answer = [System.Windows.Forms.MessageBox]::Show(
            '是否打开输出文件夹？',
            '处理完成',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
            Start-Process -FilePath $directories[0]
        }
    }
    elseif ($directories.Count -gt 1) {
        Write-Host '输出目录：'
        $directories | ForEach-Object { Write-Host "  $_" }
    }
}

function Invoke-Main {
    param(
        [string[]]$InputFiles,
        [switch]$NoPrompt,
        [string]$QpdfPath
    )

    $resolvedQpdf = Resolve-BundledQpdf -ExplicitPath $QpdfPath
    if (-not $resolvedQpdf) {
        Write-Host '工具文件不完整：未找到随程序附带的 qpdf.exe。请重新解压完整目录。' -ForegroundColor Red
        return 2
    }

    $qpdfHealth = Test-QpdfExecutable -Path $resolvedQpdf
    if (-not $qpdfHealth.IsValid) {
        Write-Host '工具文件不完整：qpdf.exe 无法启动或版本不正确。请重新解压完整目录。' -ForegroundColor Red
        return 2
    }

    $paths = @($InputFiles | Where-Object { $_ })
    if ($paths.Count -eq 0) {
        $paths = @(Select-PdfFiles)
    }
    if ($paths.Count -eq 0) {
        Write-Host '未选择文件。'
        return 0
    }

    if (-not (Confirm-Processing -NoPrompt:$NoPrompt)) {
        Write-Host '已取消。'
        return 0
    }

    $results = New-Object System.Collections.Generic.List[object]
    for ($index = 0; $index -lt $paths.Count; $index++) {
        try {
            $result = Invoke-PdfCopy -InputPath $paths[$index] -QpdfPath $resolvedQpdf
        }
        catch {
            $result = New-ProcessResult -Status 'Failed' -InputPath $paths[$index] `
                -Message '处理过程中发生错误，未修改原文件。' -Details $_.Exception.Message
        }
        $results.Add($result)
        try {
            Show-Result -Result $result -Index ($index + 1) -Total $paths.Count
        }
        catch {
            Write-Host "[$($index + 1)/$($paths.Count)] 失败：无法显示该输入路径。" -ForegroundColor Red
        }
    }

    Show-Summary -Results $results.ToArray() -NoPrompt:$NoPrompt
    if (@($results | Where-Object { $_.Status -eq 'Failed' }).Count -gt 0) {
        return 1
    }

    return 0
}

if (-not $LibraryMode) {
    $mainExitCode = Invoke-Main -InputFiles $InputFiles -NoPrompt:$NoPrompt -QpdfPath $QpdfPath
    exit $mainExitCode
}
