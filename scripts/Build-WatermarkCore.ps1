[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$expectedRuntime = 'CPython 3.10.11 x64'
$runtimeProbe = "import sys, struct; ok = sys.implementation.name == 'cpython' and sys.version_info == (3, 10, 11, 'final', 0) and struct.calcsize('P') == 8; print('CPython 3.10.11 x64' if ok else 'unsupported runtime'); sys.exit(0 if ok else 1)"
try {
    $runtimeOutput = @(& py -3.10 -c $runtimeProbe 2>&1)
    if ($LASTEXITCODE -ne 0 -or $runtimeOutput.Count -ne 1 -or $runtimeOutput[0] -cne $expectedRuntime) {
        throw '解释器版本、位数或检查输出不符合要求。'
    }
}
catch {
    throw "构建固定要求CPython 3.10.11 x64；解释器检查失败：$($_.Exception.Message)"
}

$directRequirements = Join-Path $PSScriptRoot 'requirements-watermark-build.txt'
$requirements = Join-Path $PSScriptRoot 'requirements-watermark-lock.txt'
$directLines = @(Get-Content -LiteralPath $directRequirements)
$lockLines = @(Get-Content -LiteralPath $requirements)
foreach ($name in @('pypdf', 'PyInstaller')) {
    $directPattern = '^' + [regex]::Escape($name) + '==([^\s]+)$'
    $directPin = @($directLines | Where-Object { $_ -match $directPattern })
    if ($directPin.Count -ne 1) {
        throw "直接依赖清单必须包含唯一的固定版本：$name"
    }
    $version = [regex]::Match($directPin[0], $directPattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase).Groups[1].Value
    $lockPattern = '^' + [regex]::Escape($name) + '==' + [regex]::Escape($version) + '\s+--hash=sha256:[0-9a-f]{64}$'
    if (@($lockLines | Where-Object { $_ -match $lockPattern }).Count -ne 1) {
        throw "依赖锁与直接清单版本不一致或缺少 SHA256：$name==$version"
    }
}

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

Write-Host '正在校验 SHA256 并安装完整锁定的构建依赖……'
& $python -m pip install --disable-pip-version-check --require-hashes --force-reinstall --requirement $requirements | Out-Host
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
