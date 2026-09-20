# Minecraft Command Console - Windows Release installer build script
#
# Steps:
#   1. flutter build windows --release
#   2. Copy VC++ runtime DLLs into the Release folder
#   3. Compile the Inno Setup script -> dist/*.exe
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File packaging\windows\build_installer.ps1

$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$releaseDir = Join-Path $root 'build\windows\x64\runner\Release'
$distDir = Join-Path $root 'dist'

Write-Host '==> [1/3] flutter build windows --release' -ForegroundColor Cyan
Push-Location $root
try {
    flutter build windows --release
    if ($LASTEXITCODE -ne 0) { throw "flutter build failed (exit=$LASTEXITCODE)" }
} finally {
    Pop-Location
}

if (-not (Test-Path (Join-Path $releaseDir 'minecraftcommand.exe'))) {
    throw "Build output not found: $releaseDir\minecraftcommand.exe"
}

Write-Host '==> [2/3] Copy VC++ runtime DLLs' -ForegroundColor Cyan
foreach ($dll in @('vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll')) {
    $src = Join-Path $env:SystemRoot "System32\$dll"
    $dst = Join-Path $releaseDir $dll
    if (Test-Path $src) {
        Copy-Item $src $dst -Force
        Write-Host "  + $dll"
    } else {
        Write-Warning "  $dll not found on this machine, skipped"
    }
}

Write-Host '==> [3/3] Compile installer (Inno Setup)' -ForegroundColor Cyan
$iscc = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
    'C:\Program Files (x86)\Inno Setup 6\ISCC.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $iscc) {
    throw "Inno Setup not found. Install it with: winget install --id JRSoftware.InnoSetup -e --scope user --accept-package-agreements --accept-source-agreements"
}

& $iscc (Join-Path $PSScriptRoot 'installer.iss')
if ($LASTEXITCODE -ne 0) { throw "ISCC failed (exit=$LASTEXITCODE)" }

Write-Host ''
Write-Host 'Done! Installer output:' -ForegroundColor Green
Get-ChildItem $distDir -Filter '*.exe' -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host ('  {0}  ({1:N1} MB)' -f $_.FullName, ($_.Length / 1MB)) -ForegroundColor Green
}
