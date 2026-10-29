[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$expectedBuildPrefix = [IO.Path]::GetFullPath((Join-Path $projectRoot '.build')).TrimEnd('\') + '\'
$buildRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot '.build\watermark-core'))
$expectedBuildRoot = $expectedBuildPrefix + 'watermark-core'
if (-not $buildRoot.StartsWith($expectedBuildPrefix, [StringComparison]::OrdinalIgnoreCase) -or
    -not $buildRoot.Equals($expectedBuildRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "拒绝清理意外构建路径：$buildRoot"
}
foreach ($path in @($expectedBuildPrefix.TrimEnd('\'), $buildRoot)) {
    if ((Test-Path -LiteralPath $path) -and
        ((Get-Item -LiteralPath $path -Force).LinkType -in @('Junction', 'SymbolicLink'))) {
        throw "拒绝清理包含目录链接的构建路径：$path"
    }
}
if (Test-Path -LiteralPath $buildRoot) {
    Remove-Item -LiteralPath $buildRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null

$venvRoot = Join-Path $buildRoot 'venv'
$python = Join-Path $venvRoot 'Scripts\python.exe'
Write-Host '正在创建独立 Python 3.10 构建环境……'
try {
    & py -3.10 -m venv $venvRoot | Out-Host
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $python -PathType Leaf)) {
        throw 'Python 3.10 虚拟环境创建未成功。'
    }
}
catch {
    throw "无法创建构建环境，请确认已安装 Python 3.10 和 py 启动器：$($_.Exception.Message)"
}

$requirements = Join-Path $PSScriptRoot 'requirements-watermark-build.txt'
Write-Host '正在安装固定版本的构建依赖……'
& $python -m pip install --disable-pip-version-check --requirement $requirements | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw '构建依赖安装失败，请检查网络、证书和 pip 输出。'
}

$distRoot = Join-Path $buildRoot 'dist'
$workRoot = Join-Path $buildRoot 'work'
$specRoot = Join-Path $buildRoot 'spec'
$entryPoint = Join-Path $projectRoot 'src\watermark_core\watermark_core.py'
Write-Host '正在构建独立水印核心 EXE……'
& $python -m PyInstaller --noconfirm --clean --onefile --console --name watermark_core `
    --distpath $distRoot --workpath $workRoot --specpath $specRoot $entryPoint | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw '水印核心 EXE 构建失败，请检查 PyInstaller 输出。'
}

$exe = [IO.Path]::GetFullPath((Join-Path $distRoot 'watermark_core.exe'))
if (-not (Test-Path -LiteralPath $exe -PathType Leaf) -or (Get-Item -LiteralPath $exe).Length -le 0) {
    throw "构建结果缺失或为空：$exe"
}
$versionOutput = @(& $exe --version)
if ($LASTEXITCODE -ne 0 -or $versionOutput.Count -ne 1 -or $versionOutput[0] -cne '0.2.0') {
    throw '水印核心 EXE 无法启动，或版本输出并非精确的 0.2.0。'
}
Write-Host "水印核心已构建并验证：$exe" -ForegroundColor Green
Write-Output $exe
