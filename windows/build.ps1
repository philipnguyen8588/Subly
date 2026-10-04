# Build ScreenTranslator cho Windows.
#   .\build.ps1                 tải thư viện phụ (sherpa-onnx, danh sách từ), dựng PS5 (nếu có MSYS2) rồi build Release
#   .\build.ps1 -SkipPS5        bỏ qua phần PS5 (st_chiaki.dll)
#   .\build.ps1 -Publish        xuất bản thư mục chạy được: windows\dist\ScreenTranslator
#   .\build.ps1 -Run            build rồi mở app
param(
    [switch]$SkipPS5,
    [switch]$Publish,
    [switch]$Run,
    [string]$Configuration = "Release",
    [string]$Msys = "C:\msys64"
)
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
Push-Location $root
try {
    Write-Host "== Thư viện giọng AI offline (sherpa-onnx)" -ForegroundColor Cyan
    & (Join-Path $root "Scripts\fetch-sherpa.ps1")
    Write-Host "== Danh sách từ tiếng Anh" -ForegroundColor Cyan
    & (Join-Path $root "Scripts\fetch-words.ps1")
    if (Test-Path (Join-Path $root "ScreenTranslator\Resources\AppIcon.ico")) { } else { & (Join-Path $root "Scripts\make-icon.ps1") }

    if (-not $SkipPS5) {
        $bash = Join-Path $Msys "usr\bin\bash.exe"
        if (Test-Path $bash) {
            Write-Host "== PS5 Remote Play (st_chiaki.dll qua MSYS2 MINGW64)" -ForegroundColor Cyan
            $full = (Join-Path $root "Scripts\build-chiaki.sh") -replace '\\', '/'
            $script = "/" + $full.Substring(0, 1).ToLower() + $full.Substring(2)
            $env:MSYSTEM = "MINGW64"
            & $bash -lc "$script"
            if ($LASTEXITCODE -ne 0) { throw "build-chiaki.sh lỗi ($LASTEXITCODE)" }
        } else {
            Write-Warning "Không thấy MSYS2 ở $Msys → bỏ qua PS5 (app vẫn chạy, tab PS5 báo thiếu st_chiaki.dll). Cài MSYS2 từ https://www.msys2.org/"
        }
    }

    Write-Host "== dotnet build ($Configuration)" -ForegroundColor Cyan
    dotnet build (Join-Path $root "ScreenTranslator.sln") -c $Configuration
    if ($LASTEXITCODE -ne 0) { throw "dotnet build lỗi" }

    $exe = Join-Path $root "ScreenTranslator\bin\$Configuration\net8.0-windows10.0.19041.0\win-x64\ScreenTranslator.exe"
    if ($Publish) {
        Write-Host "== dotnet publish → dist\ScreenTranslator" -ForegroundColor Cyan
        $dist = Join-Path $root "dist\ScreenTranslator"
        dotnet publish (Join-Path $root "ScreenTranslator\ScreenTranslator.csproj") -c $Configuration -o $dist
        if ($LASTEXITCODE -ne 0) { throw "dotnet publish lỗi" }
        $exe = Join-Path $dist "ScreenTranslator.exe"
    }
    Write-Host "Xong: $exe" -ForegroundColor Green
    if ($Run) { Start-Process $exe }
}
finally { Pop-Location }
