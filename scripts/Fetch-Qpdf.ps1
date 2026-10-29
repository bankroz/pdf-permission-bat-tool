[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$version = '12.4.2'
$archiveName = "qpdf-$version-msvc64.zip"
$downloadUrl = "https://github.com/qpdf/qpdf/releases/download/v$version/$archiveName"
$expectedSha256 = 'DB87077E683630C1217E0E8F9A20A9749D952AB676E881C3689187763A5DE25D'

$projectRoot = Split-Path -Parent $PSScriptRoot
$vendorDir = Join-Path $projectRoot 'vendor'
$archivePath = Join-Path $vendorDir $archiveName
$downloadPath = "$archivePath.download"
$extractDir = Join-Path $vendorDir "qpdf-$version-msvc64"

function Test-ArchiveHash {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash -eq $expectedSha256
}

New-Item -ItemType Directory -Force -Path $vendorDir | Out-Null

if (-not (Test-ArchiveHash -Path $archivePath)) {
    if (Test-Path -LiteralPath $archivePath) {
        Remove-Item -LiteralPath $archivePath -Force
    }
    if (Test-Path -LiteralPath $downloadPath) {
        Remove-Item -LiteralPath $downloadPath -Force
    }

    Write-Host "正在从 qpdf 官方 GitHub Release 下载 $archiveName ..."
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $downloadUrl -OutFile $downloadPath
        if (-not (Test-ArchiveHash -Path $downloadPath)) {
            $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $downloadPath).Hash
            throw "qpdf 下载文件校验失败。期望 $expectedSha256，实际 $actualHash。"
        }
        Move-Item -LiteralPath $downloadPath -Destination $archivePath
    }
    finally {
        if (Test-Path -LiteralPath $downloadPath) {
            Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
        }
    }
}

$needsExtraction = -not (Test-Path -LiteralPath $extractDir -PathType Container)
if (-not $needsExtraction) {
    $existingQpdf = Get-ChildItem -LiteralPath $extractDir -Filter qpdf.exe -Recurse -File |
        Select-Object -First 1
    $needsExtraction = -not [bool]$existingQpdf
}

if ($needsExtraction) {
    if (Test-Path -LiteralPath $extractDir) {
        Remove-Item -LiteralPath $extractDir -Recurse -Force
    }
    Write-Host '正在解压 qpdf ...'
    Expand-Archive -LiteralPath $archivePath -DestinationPath $vendorDir -Force
}

$qpdfExe = Get-ChildItem -LiteralPath $extractDir -Filter qpdf.exe -Recurse -File |
    Select-Object -First 1
if (-not $qpdfExe) {
    throw 'qpdf 压缩包中未找到 qpdf.exe。'
}

$versionOutput = & $qpdfExe.FullName --version
if ($LASTEXITCODE -ne 0) {
    throw 'qpdf.exe 无法启动。'
}

Write-Host $versionOutput
Write-Host "qpdf 已就绪：$($qpdfExe.FullName)"
