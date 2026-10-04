# Tải thư viện sherpa-onnx dựng sẵn cho Windows x64 (giọng AI offline) vào windows/Vendor/sherpa-onnx/lib.
# Cùng phiên bản với bản macOS (Scripts/fetch-sherpa.sh) để struct C khớp với LocalTTS.cs.
# Cần Microsoft Visual C++ Redistributable 2015-2022 (x64) trên máy chạy app (thường đã có sẵn).
param([string]$Version = $(if ($env:SHERPA_VERSION) { $env:SHERPA_VERSION } else { "v1.13.8" }))
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$vendor = Join-Path $root "Vendor"
$dest = Join-Path $vendor "sherpa-onnx\lib"
if (Test-Path (Join-Path $dest "sherpa-onnx-c-api.dll")) {
    Write-Host "sherpa-onnx already present: $dest"
    exit 0
}
New-Item -ItemType Directory -Force $vendor | Out-Null
$name = "sherpa-onnx-$Version-win-x64-shared-MD-Release-lib"
$url = "https://github.com/k2-fsa/sherpa-onnx/releases/download/$Version/$name.tar.bz2"
$archive = Join-Path $vendor "$name.tar.bz2"
Write-Host "Downloading $url"
Invoke-WebRequest -Uri $url -OutFile $archive -UseBasicParsing
$tmp = Join-Path $vendor "sherpa-tmp"
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
New-Item -ItemType Directory -Force $tmp | Out-Null
# tar.exe (bsdtar) có sẵn trên Windows 10/11, giải nén được .tar.bz2
& "$env:SystemRoot\System32\tar.exe" -xjf $archive -C $tmp
if ($LASTEXITCODE -ne 0) { throw "tar failed ($LASTEXITCODE)" }
New-Item -ItemType Directory -Force $dest | Out-Null
$dlls = Get-ChildItem -Recurse -Path $tmp -Filter *.dll
if (-not ($dlls | Where-Object { $_.Name -eq "sherpa-onnx-c-api.dll" })) { throw "sherpa-onnx-c-api.dll not found in $name" }
$dlls | ForEach-Object { Copy-Item $_.FullName -Destination $dest -Force }
Remove-Item -Recurse -Force $tmp
Remove-Item -Force $archive
Write-Host "sherpa-onnx $Version -> $dest"
Get-ChildItem $dest | ForEach-Object { Write-Host "  $($_.Name)" }
