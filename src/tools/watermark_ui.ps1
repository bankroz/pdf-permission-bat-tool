[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$InputFiles,
    [switch]$LibraryMode,
    [switch]$NoPrompt,
    [string]$CorePath,
    [string]$QpdfPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function New-WatermarkResult {
    param(
        [Parameter(Mandatory)][ValidateSet('Valid', 'Success', 'Warning', 'Failed', 'Skipped')][string]$Status,
        [Parameter(Mandatory)][string]$InputPath,
        [string]$OutputPath = '',
        [Parameter(Mandatory)][string]$Message,
        [string]$Details = '',
        [long]$Pages = 0,
        [long]$RemovedBlocks = 0
    )
    [pscustomobject]@{
        IsValid = $Status -eq 'Valid'
        Status = $Status
        InputPath = $InputPath
        OutputPath = $OutputPath
        Message = $Message
        Details = $Details
        Pages = $Pages
        RemovedBlocks = $RemovedBlocks
    }
}

function Test-WatermarkInputPath {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return New-WatermarkResult -Status 'Skipped' -InputPath $Path -Message '文件不存在或不是普通文件。'
    }
    if ([IO.Path]::GetExtension($Path) -ine '.pdf') {
        return New-WatermarkResult -Status 'Skipped' -InputPath $Path -Message '不是 PDF 文件。'
    }
    return New-WatermarkResult -Status 'Valid' -InputPath (Get-Item -LiteralPath $Path).FullName -Message '输入有效。'
}

function Get-WatermarkOutputPath {
    param([Parameter(Mandatory)][string]$InputPath)
    $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InputPath)
    $directory = [IO.Path]::GetDirectoryName($fullPath)
    $stem = [IO.Path]::GetFileNameWithoutExtension($fullPath)
    $candidate = Join-Path $directory "${stem}_去水印.pdf"
    $index = 2
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $directory "${stem}_去水印_${index}.pdf"
        $index++
    }
    return $candidate
}

function Select-WatermarkPdfFiles {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    try {
        $dialog.Title = '选择要去水印的 PDF 文件'
        $dialog.Filter = 'PDF 文件 (*.pdf)|*.pdf'
        $dialog.Multiselect = $true
        $dialog.RestoreDirectory = $true
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return @($dialog.FileNames) }
        return @()
    }
    finally { $dialog.Dispose() }
}

function Confirm-WatermarkProcessing {
    param([switch]$NoPrompt)
    if ($NoPrompt) { return $true }
    Add-Type -AssemblyName System.Windows.Forms
    $text = "本工具仅处理你有权修改的文件。`r`n`r`n原文件不会被覆盖。去水印后的副本可能使数字签名失效。`r`n`r`n是否继续？"
    $answer = [System.Windows.Forms.MessageBox]::Show(
        $text, 'PDF 去水印工具',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    return $answer -eq [System.Windows.Forms.DialogResult]::Yes
}

function Resolve-WatermarkDependencies {
    param([string]$CorePath, [string]$QpdfPath)
    try {
        $toolRoot = Split-Path -Parent $PSScriptRoot
        if (-not $CorePath) { $CorePath = Join-Path $toolRoot 'watermark\watermark_core.exe' }
        if (-not $QpdfPath) { $QpdfPath = Join-Path $toolRoot 'qpdf\bin\qpdf.exe' }
        if (-not (Test-Path -LiteralPath $CorePath -PathType Leaf)) { throw '未找到 watermark_core.exe。' }
        if (-not (Test-Path -LiteralPath $QpdfPath -PathType Leaf)) { throw '未找到 qpdf.exe。' }
        return [pscustomobject]@{
            IsValid = $true
            CorePath = (Get-Item -LiteralPath $CorePath).FullName
            QpdfPath = (Get-Item -LiteralPath $QpdfPath).FullName
            Details = ''
        }
    }
    catch { return [pscustomobject]@{ IsValid = $false; CorePath = ''; QpdfPath = ''; Details = $_.Exception.Message } }
}

function ConvertTo-WatermarkProcessArgument {
    param([AllowEmptyString()][string]$Argument)
    # Windows CreateProcess quoting: double backslashes before quotes and at the end.
    $escaped = [regex]::Replace($Argument, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Invoke-WatermarkProcess {
    param([Parameter(Mandatory)][string]$Path, [string[]]$Arguments)
    $process = New-Object System.Diagnostics.Process
    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $Path
        $startInfo.Arguments = (@($Arguments | ForEach-Object { ConvertTo-WatermarkProcessArgument -Argument $_ }) -join ' ')
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $startInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
        $process.StartInfo = $startInfo
        [void]$process.Start()
        # Read both pipes concurrently so a verbose dependency cannot deadlock.
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return [pscustomobject]@{ Started = $true; ExitCode = $process.ExitCode; StdOut = $stdout.Result; StdErr = $stderr.Result }
    }
    catch { return [pscustomobject]@{ Started = $false; ExitCode = -1; StdOut = ''; StdErr = $_.Exception.Message } }
    finally { $process.Dispose() }
}

function Test-WatermarkDependencies {
    param([Parameter(Mandatory)][string]$CorePath, [Parameter(Mandatory)][string]$QpdfPath)
    $core = Invoke-WatermarkProcess -Path $CorePath -Arguments @('--version')
    if (-not $core.Started -or $core.ExitCode -ne 0 -or $core.StdOut.Trim() -cne '0.2.0') {
        return [pscustomobject]@{ IsValid = $false; Details = "核心无法启动或版本不是 0.2.0。$($core.StdOut)$($core.StdErr)" }
    }
    $qpdf = Invoke-WatermarkProcess -Path $QpdfPath -Arguments @('--version')
    $qpdfVersionMatches = $qpdf.StdOut -match '(?m)^qpdf version 12\.4\.2(?:\s|$)'
    if (-not $qpdf.Started -or $qpdf.ExitCode -ne 0 -or -not $qpdfVersionMatches) {
        return [pscustomobject]@{ IsValid = $false; Details = "qpdf 无法启动或版本不是 12.4.2。$($qpdf.StdOut)$($qpdf.StdErr)" }
    }
    return [pscustomobject]@{ IsValid = $true; Details = '' }
}

function Invoke-WatermarkCore {
    param(
        [Parameter(Mandatory)][string]$CorePath,
        [Parameter(Mandatory)][string]$InputPath,
        [Parameter(Mandatory)][string]$OutputPath
    )
    $run = Invoke-WatermarkProcess -Path $CorePath -Arguments @($InputPath, $OutputPath)
    $details = ($run.StdErr + [Environment]::NewLine + $run.StdOut).Trim()
    try {
        if (-not $run.Started) { throw '去水印核心无法启动。' }
        $payload = ConvertFrom-Json -InputObject $run.StdOut -ErrorAction Stop
        if ($null -eq $payload -or $payload -is [array]) { throw '核心返回的 JSON 不是单个结果对象。' }
        $names = @($payload.PSObject.Properties.Name)
        foreach ($name in @('status', 'message', 'pages', 'removed_blocks')) {
            if ($names -notcontains $name) { throw "核心返回的 JSON 缺少字段：$name" }
        }
        $states = @('success', 'unsupported', 'encrypted', 'invalid', 'failed')
        $codes = @{ success = 0; unsupported = 10; encrypted = 11; invalid = 12; failed = 13 }
        if ($states -cnotcontains $payload.status) { throw '核心返回未知状态。' }
        if ($run.ExitCode -ne $codes[$payload.status]) { throw '核心状态与退出码不一致。' }
        $pages = 0L
        $removed = 0L
        if (-not [long]::TryParse([string]$payload.pages, [ref]$pages) -or $pages -lt 0 -or
            -not [long]::TryParse([string]$payload.removed_blocks, [ref]$removed) -or $removed -lt 0 -or
            $payload.message -isnot [string]) { throw '核心返回的计数或消息字段无效。' }
        return [pscustomobject]@{
            ExitCode = $run.ExitCode
            Status = $payload.status
            Message = $payload.message
            Pages = $pages
            RemovedBlocks = $removed
            Details = $details
        }
    }
    catch {
        return [pscustomobject]@{
            ExitCode = $run.ExitCode
            Status = 'failed'
            Message = '去水印核心返回无效结果或无法运行。'
            Pages = 0L
            RemovedBlocks = 0L
            Details = ($_.Exception.Message + [Environment]::NewLine + $details).Trim()
        }
    }
}

function Test-WatermarkOutput {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$QpdfPath,
        [Parameter(Mandatory)][long]$Pages
    )
    $details = ''
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-Item -LiteralPath $Path).Length -le 0) { throw '核心未生成非空的 PDF 文件。' }
        $check = Invoke-WatermarkProcess -Path $QpdfPath -Arguments @('--check', $Path)
        $details = ($check.StdOut + [Environment]::NewLine + $check.StdErr).Trim()
        if (-not $check.Started -or $check.ExitCode -notin @(0, 3)) { throw 'qpdf 文件结构检查失败。' }
        $count = Invoke-WatermarkProcess -Path $QpdfPath -Arguments @('--show-npages', $Path)
        $details = ($details + [Environment]::NewLine + $count.StdOut + [Environment]::NewLine + $count.StdErr).Trim()
        $actualPages = 0L
        if (-not $count.Started -or $count.ExitCode -ne 0 -or
            $count.StdOut.Trim() -notmatch '^[0-9]+$' -or
            -not [long]::TryParse($count.StdOut.Trim(), [ref]$actualPages) -or $actualPages -ne $Pages) {
            throw 'qpdf 页数检查失败或与去水印核心不一致。'
        }
        return [pscustomobject]@{ IsValid = $true; IsWarning = $check.ExitCode -eq 3; Details = $details }
    }
    catch {
        return [pscustomobject]@{ IsValid = $false; IsWarning = $false; Details = ($_.Exception.Message + [Environment]::NewLine + $details).Trim() }
    }
}

function Invoke-WatermarkFile {
    param(
        [Parameter(Mandatory)][string]$InputPath,
        [Parameter(Mandatory)][string]$CorePath,
        [Parameter(Mandatory)][string]$QpdfPath
    )
    $fullInput = $InputPath
    $tempPath = $null
    try {
        $validation = Test-WatermarkInputPath -Path $InputPath
        if (-not $validation.IsValid) { return $validation }
        $fullInput = $validation.InputPath
        $finalPath = Get-WatermarkOutputPath -InputPath $fullInput
        $directory = [IO.Path]::GetDirectoryName($fullInput)
        $stem = [IO.Path]::GetFileNameWithoutExtension($fullInput)
        $tempPath = Join-Path $directory ('.{0}.{1}.watermark.tmp.pdf' -f $stem, [guid]::NewGuid().ToString('N'))
        $core = Invoke-WatermarkCore -CorePath $CorePath -InputPath $fullInput -OutputPath $tempPath
        if ($core.Status -eq 'unsupported') {
            return New-WatermarkResult -Status 'Skipped' -InputPath $fullInput -Message $core.Message `
                -Details $core.Details -Pages $core.Pages -RemovedBlocks $core.RemovedBlocks
        }
        if ($core.Status -ne 'success') {
            return New-WatermarkResult -Status 'Failed' -InputPath $fullInput -Message $core.Message `
                -Details $core.Details -Pages $core.Pages -RemovedBlocks $core.RemovedBlocks
        }
        $outputCheck = Test-WatermarkOutput -Path $tempPath -QpdfPath $QpdfPath -Pages $core.Pages
        $details = ($core.Details + [Environment]::NewLine + $outputCheck.Details).Trim()
        if (-not $outputCheck.IsValid) {
            return New-WatermarkResult -Status 'Failed' -InputPath $fullInput -Message '输出校验失败，未发布副本。' -Details $details
        }
        # The two-argument Move never overwrites an output created concurrently.
        [IO.File]::Move($tempPath, $finalPath)
        $status = 'Success'
        $message = '已生成去水印副本。'
        if ($outputCheck.IsWarning) { $status = 'Warning'; $message = '已生成去水印副本，但 qpdf 报告文件结构警告。' }
        return New-WatermarkResult -Status $status -InputPath $fullInput -OutputPath $finalPath `
            -Message $message -Details $details -Pages $core.Pages -RemovedBlocks $core.RemovedBlocks
    }
    catch {
        return New-WatermarkResult -Status 'Failed' -InputPath $fullInput `
            -Message '处理过程中发生错误，未修改原文件。' -Details $_.Exception.Message
    }
    finally {
        if ($tempPath -and [IO.File]::Exists($tempPath)) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
    }
}

function Show-WatermarkResult {
    param([Parameter(Mandatory)]$Result, [Parameter(Mandatory)][int]$Index, [Parameter(Mandatory)][int]$Total)
    try { $name = [IO.Path]::GetFileName($Result.InputPath) }
    catch { $name = '（无法解析的输入路径）' }
    switch ($Result.Status) {
        'Success' { Write-Host "[$Index/$Total] 成功：$name，页数 $($Result.Pages)，删除块数 $($Result.RemovedBlocks) -> $($Result.OutputPath)" -ForegroundColor Green }
        'Warning' {
            Write-Host "[$Index/$Total] 警告成功：$name，页数 $($Result.Pages)，删除块数 $($Result.RemovedBlocks) -> $($Result.OutputPath)" -ForegroundColor Yellow
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
        default { throw "未知处理状态：$($Result.Status)" }
    }
}

function Show-WatermarkSummary {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Results, [switch]$NoPrompt)
    $success = @($Results | Where-Object { $_.Status -eq 'Success' }).Count
    $warning = @($Results | Where-Object { $_.Status -eq 'Warning' }).Count
    $failed = @($Results | Where-Object { $_.Status -eq 'Failed' }).Count
    $skipped = @($Results | Where-Object { $_.Status -eq 'Skipped' }).Count
    Write-Host ''
    Write-Host "处理完成：成功 $success，警告成功 $warning，失败 $failed，跳过 $skipped。" -ForegroundColor Cyan
    $directories = @($Results | Where-Object { $_.OutputPath } |
        ForEach-Object { [IO.Path]::GetDirectoryName($_.OutputPath) } | Sort-Object -Unique)
    if (-not $NoPrompt -and $directories.Count -eq 1) {
        Add-Type -AssemblyName System.Windows.Forms
        $answer = [System.Windows.Forms.MessageBox]::Show(
            '是否打开输出文件夹？', '处理完成',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) { Start-Process -FilePath $directories[0] }
    }
    elseif ($directories.Count -gt 1) {
        Write-Host '输出目录：'
        $directories | ForEach-Object { Write-Host "  $_" }
    }
}

function Invoke-WatermarkMain {
    param([string[]]$InputFiles, [switch]$NoPrompt, [string]$CorePath, [string]$QpdfPath)
    $dependencies = Resolve-WatermarkDependencies -CorePath $CorePath -QpdfPath $QpdfPath
    if (-not $dependencies.IsValid) {
        Write-Host "工具文件不完整：$($dependencies.Details) 请重新解压完整目录。" -ForegroundColor Red
        return 2
    }
    $health = Test-WatermarkDependencies -CorePath $dependencies.CorePath -QpdfPath $dependencies.QpdfPath
    if (-not $health.IsValid) {
        Write-Host "工具无法运行：$($health.Details) 请重新解压完整目录。" -ForegroundColor Red
        return 2
    }
    $paths = @($InputFiles | Where-Object { $_ })
    if ($paths.Count -eq 0) { $paths = @(Select-WatermarkPdfFiles) }
    if ($paths.Count -eq 0) { Write-Host '未选择文件。'; return 0 }
    if (-not (Confirm-WatermarkProcessing -NoPrompt:$NoPrompt)) { Write-Host '已取消。'; return 0 }
    $results = New-Object System.Collections.Generic.List[object]
    for ($index = 0; $index -lt $paths.Count; $index++) {
        try { $result = Invoke-WatermarkFile -InputPath $paths[$index] -CorePath $dependencies.CorePath -QpdfPath $dependencies.QpdfPath }
        catch {
            $result = New-WatermarkResult -Status 'Failed' -InputPath $paths[$index] `
                -Message '处理过程中发生错误，未修改原文件。' -Details $_.Exception.Message
        }
        $results.Add($result)
        try { Show-WatermarkResult -Result $result -Index ($index + 1) -Total $paths.Count }
        catch { Write-Host "[$($index + 1)/$($paths.Count)] 无法显示结果。" -ForegroundColor Red }
    }
    Show-WatermarkSummary -Results $results.ToArray() -NoPrompt:$NoPrompt
    if (@($results | Where-Object { $_.Status -eq 'Failed' }).Count -gt 0) { return 1 }
    return 0
}

if (-not $LibraryMode) {
    $mainExitCode = Invoke-WatermarkMain -InputFiles $InputFiles -NoPrompt:$NoPrompt -CorePath $CorePath -QpdfPath $QpdfPath
    exit $mainExitCode
}
