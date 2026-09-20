# 由 assets/app_icon.svg 生成各平台图标
#   - windows/runner/resources/app_icon.ico  (Windows 应用图标 / 任务栏 / 安装包)
#   - assets/app_icon.png                    (应用内使用)
#
# 流程：SVG -> 512px PNG（无头 Edge 渲染）-> 缩放 -> ICO / PNG
# 用法：powershell -ExecutionPolicy Bypass -File packaging\windows\make_icon.ps1

$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$svg = Join-Path $root 'assets\app_icon.svg'
$icoOut = Join-Path $root 'windows\runner\resources\app_icon.ico'
$pngOut = Join-Path $root 'assets\app_icon.png'

if (-not (Test-Path $svg)) { throw "SVG not found: $svg" }

# 1) SVG -> 512px PNG
$tmp = Join-Path $env:TEMP 'app_icon_build'
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$html = Join-Path $tmp 'render.html'
$png512 = Join-Path $tmp 'icon_512.png'

$svgUri = ('file:///' + ($svg -replace '\\', '/'))
$htmlText = @"
<html><head><style>html,body{margin:0;padding:0;background:transparent;overflow:hidden}</style></head>
<body><img src="$svgUri" width="512" height="512"></body></html>
"@
[IO.File]::WriteAllText($html, $htmlText, (New-Object Text.UTF8Encoding $false))

$edge = @(
  'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
  'C:\Program Files\Microsoft\Edge\Application\msedge.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { throw 'Microsoft Edge not found (needed to rasterize the SVG).' }

if (Test-Path $png512) { Remove-Item $png512 -Force }
# Edge 会向 stderr 输出无害诊断信息，临时放宽以免被 ErrorActionPreference 中断
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& $edge --headless=new --disable-gpu --screenshot=$png512 --window-size=512,512 --default-background-color=00000000 "file:///$($html -replace '\\','/')" 2>$null | Out-Null
$ErrorActionPreference = $prevEap
if (-not (Test-Path $png512)) { throw "Failed to render PNG: $png512" }
Write-Host "Rendered 512px PNG: $png512"

# 2) 缩放并输出 ICO / PNG
$py = Join-Path $tmp 'make_icons.py'
$pyText = @'
from PIL import Image

src_path, ico_path, png_path = r"__SRC__", r"__ICO__", r"__PNG__"

img = Image.open(src_path).convert("RGBA")
img = img.crop(img.getbbox()) if False else img

sizes = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
img.save(ico_path, format="ICO", sizes=sizes)
img.resize((256, 256), Image.LANCZOS).save(png_path, format="PNG")
print("ICO ->", ico_path)
print("PNG ->", png_path)
'@
$pyText = $pyText.Replace('__SRC__', $png512).Replace('__ICO__', $icoOut).Replace('__PNG__', $pngOut)
[IO.File]::WriteAllText($py, $pyText, (New-Object Text.UTF8Encoding $false))

python $py
if ($LASTEXITCODE -ne 0) { throw "Icon generation failed (exit=$LASTEXITCODE)" }

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host 'Icon files:' -ForegroundColor Green
foreach ($f in @($icoOut, $pngOut)) {
    if (Test-Path $f) {
        Write-Host ('  {0}  ({1:N1} KB)' -f $f, ((Get-Item $f).Length / 1KB)) -ForegroundColor Green
    }
}
