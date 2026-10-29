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

function Test-FileHash {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedHash
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash -eq $ExpectedHash
}

New-Item -ItemType Directory -Force -Path $vendorDir | Out-Null

if (-not (Test-FileHash -Path $archivePath -ExpectedHash $expectedSha256)) {
    if (Test-Path -LiteralPath $archivePath) {
        Remove-Item -LiteralPath $archivePath -Force
    }
    if (Test-Path -LiteralPath $downloadPath) {
        Remove-Item -LiteralPath $downloadPath -Force
    }

    Write-Host "正在从 qpdf 官方 GitHub Release 下载 $archiveName ..."
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $downloadUrl -OutFile $downloadPath
        if (-not (Test-FileHash -Path $downloadPath -ExpectedHash $expectedSha256)) {
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

$metadataDir = Join-Path $vendorDir 'qpdf-metadata'
New-Item -ItemType Directory -Force -Path $metadataDir | Out-Null
$metadataFiles = @(
    @{
        Name = 'LICENSE.txt'
        Url = 'https://raw.githubusercontent.com/qpdf/qpdf/v12.4.2/LICENSE.txt'
        Sha256 = 'CFC7749B96F63BD31C3C42B5C471BF756814053E847C10F3EB003417BC523D30'
    },
    @{
        Name = 'NOTICE.md'
        Url = 'https://raw.githubusercontent.com/qpdf/qpdf/v12.4.2/NOTICE.md'
        Sha256 = 'B207F65A9E5491195DED63B2941199B19A4D30148871F2742C88EAE7BFC513A6'
    }
)

foreach ($metadata in $metadataFiles) {
    $targetPath = Join-Path $metadataDir $metadata.Name
    if (-not (Test-FileHash -Path $targetPath -ExpectedHash $metadata.Sha256)) {
        $temporaryPath = "$targetPath.download"
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $metadata.Url -OutFile $temporaryPath
            if (-not (Test-FileHash -Path $temporaryPath -ExpectedHash $metadata.Sha256)) {
                throw "qpdf 元数据校验失败：$($metadata.Name)"
            }
            Move-Item -LiteralPath $temporaryPath -Destination $targetPath -Force
        }
        finally {
            if (Test-Path -LiteralPath $temporaryPath) {
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Write-Host $versionOutput
Write-Host "qpdf 已就绪：$($qpdfExe.FullName)"
