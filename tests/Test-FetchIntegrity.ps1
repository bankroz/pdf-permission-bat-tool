[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$qpdfPath = Join-Path $projectRoot 'vendor\qpdf-12.4.2-msvc64\bin\qpdf.exe'
$fetchScript = Join-Path $projectRoot 'scripts\Fetch-Qpdf.ps1'

& $fetchScript
$expectedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $qpdfPath).Hash

try {
    [IO.File]::WriteAllBytes($qpdfPath, [byte[]](0, 1, 2, 3))
    & $fetchScript
    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $qpdfPath).Hash
    if ($actualHash -ne $expectedHash) {
        throw "Extracted qpdf was not restored. Expected $expectedHash, got $actualHash."
    }
    Write-Host 'PASS verified archive restores tampered extraction' -ForegroundColor Green
}
finally {
    & $fetchScript
}
