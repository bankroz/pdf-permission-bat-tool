[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$fetchScript = Join-Path $PSScriptRoot 'Fetch-Qpdf.ps1'
& $fetchScript

$coreBuildOutput = @(& (Join-Path $PSScriptRoot 'Build-WatermarkCore.ps1'))
if ($coreBuildOutput.Count -eq 0) {
    throw '水印核心构建未返回 EXE 路径。'
}
$watermarkCore = [string]$coreBuildOutput[-1]
if ([string]::IsNullOrWhiteSpace($watermarkCore) -or
    -not (Test-Path -LiteralPath $watermarkCore -PathType Leaf) -or
    (Get-Item -LiteralPath $watermarkCore).Length -le 0) {
    throw "水印核心构建结果缺失或为空：$watermarkCore"
}

$distRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot 'dist'))
$delivery = [IO.Path]::GetFullPath((Join-Path $distRoot 'PDF权限处理工具_BAT版'))
$expectedPrefix = $distRoot.TrimEnd('\') + '\'
if (-not $delivery.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "拒绝清理意外路径：$delivery"
}

if (Test-Path -LiteralPath $delivery) {
    Remove-Item -LiteralPath $delivery -Recurse -Force
}

$toolsDir = Join-Path $delivery 'tools'
$qpdfDir = Join-Path $delivery 'qpdf'
$licensesDir = Join-Path $delivery 'licenses'
$watermarkDir = Join-Path $delivery 'watermark'
New-Item -ItemType Directory -Force -Path $toolsDir, $qpdfDir, $licensesDir, $watermarkDir | Out-Null

Copy-Item -LiteralPath (Join-Path $projectRoot 'src\PDF权限处理工具.bat') -Destination $delivery
Copy-Item -LiteralPath (Join-Path $projectRoot 'src\tools\pdf_tool.ps1') -Destination $toolsDir
Copy-Item -LiteralPath (Join-Path $projectRoot 'src\PDF去水印工具.bat') -Destination $delivery
Copy-Item -LiteralPath (Join-Path $projectRoot 'src\tools\watermark_ui.ps1') -Destination $toolsDir
Copy-Item -LiteralPath $watermarkCore -Destination (Join-Path $watermarkDir 'watermark_core.exe')
Copy-Item -LiteralPath (Join-Path $projectRoot 'src\使用说明.txt') -Destination $delivery
Copy-Item -LiteralPath (Join-Path $projectRoot 'third_party\pypdf-LICENSE.txt') -Destination $licensesDir
Copy-Item -LiteralPath (Join-Path $projectRoot 'third_party\PyInstaller-COPYING.txt') -Destination $licensesDir

$vendorRoot = Join-Path $projectRoot 'vendor\qpdf-12.4.2-msvc64'
$vendorBin = Join-Path $vendorRoot 'bin'
if (-not (Test-Path -LiteralPath (Join-Path $vendorBin 'qpdf.exe') -PathType Leaf)) {
    throw 'qpdf 运行时目录不完整。'
}
Copy-Item -LiteralPath $vendorBin -Destination $qpdfDir -Recurse

$metadataRoot = Join-Path $projectRoot 'vendor\qpdf-metadata'
Copy-Item -LiteralPath (Join-Path $metadataRoot 'LICENSE.txt') -Destination (Join-Path $licensesDir 'qpdf-LICENSE.txt')
Copy-Item -LiteralPath (Join-Path $metadataRoot 'NOTICE.md') -Destination (Join-Path $licensesDir 'qpdf-NOTICE.md')

$manualLicense = Join-Path $vendorRoot 'share\doc\qpdf\manual-html\_sources\license.rst.txt'
Copy-Item -LiteralPath $manualLicense -Destination (Join-Path $licensesDir 'qpdf-manual-license.rst.txt')

$bundledQpdf = Join-Path $qpdfDir 'bin\qpdf.exe'
$copyrightOutput = & $bundledQpdf --copyright
if ($LASTEXITCODE -ne 0) {
    throw '无法读取 qpdf 版权信息。'
}
$copyrightOutput | Set-Content -LiteralPath (Join-Path $licensesDir 'qpdf-copyright.txt') -Encoding UTF8

$bundledCore = Join-Path $watermarkDir 'watermark_core.exe'
$coreVersionOutput = @(& $bundledCore --version)
if ($LASTEXITCODE -ne 0 -or $coreVersionOutput.Count -ne 1 -or $coreVersionOutput[0] -cne '0.2.0') {
    throw '便携目录中的 watermark_core.exe 无法启动，或版本输出并非精确的 0.2.0。'
}

$manifestPath = Join-Path $delivery 'SHA256SUMS.txt'
$manifestLines = Get-ChildItem -LiteralPath $delivery -Recurse -File |
    Where-Object { $_.FullName -ne $manifestPath } |
    Sort-Object FullName |
    ForEach-Object {
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash
        $relativePath = $_.FullName.Substring($delivery.Length + 1)
        '{0}  {1}' -f $hash, $relativePath
    }
$manifestLines | Set-Content -LiteralPath $manifestPath -Encoding UTF8

$versionOutput = & $bundledQpdf --version
if (($LASTEXITCODE -ne 0) -or (($versionOutput -join [Environment]::NewLine) -notmatch '(?m)^qpdf version 12\.4\.2\b')) {
    throw '便携目录中的 qpdf.exe 无法启动。'
}

$deliveryZip = [IO.Path]::GetFullPath((Join-Path $distRoot 'PDF权限处理工具_BAT版.zip'))
if (-not $deliveryZip.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "拒绝覆盖意外路径：$deliveryZip"
}
if (Test-Path -LiteralPath $deliveryZip) {
    Remove-Item -LiteralPath $deliveryZip -Force
}
Compress-Archive -LiteralPath $delivery -DestinationPath $deliveryZip -CompressionLevel Optimal

Write-Host $versionOutput
Write-Host "便携版已生成：$delivery" -ForegroundColor Green
Write-Host "Release 压缩包已生成：$deliveryZip" -ForegroundColor Green
