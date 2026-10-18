# Ký (chứng chỉ Samsung) và cài app Subtitle TV lên TV Samsung Tizen đang bật Developer Mode. KHÔNG cần Tizen Studio:
# ký bằng sign-wgt.ps1, kết nối TV bằng sdb.exe riêng (windows\Vendor\tizen\sdb.exe, build.ps1 / bộ cài mang theo).
#   .\deploy.ps1 -Tv 192.168.8.31            ký + cài + mở app
#   .\deploy.ps1 -Tv 192.168.8.31 -Debug     mở app ở chế độ debug (in cổng DevTools để soi lỗi)
#   .\deploy.ps1 -Kit                        chỉ đóng gói thành 1 file zip cài được từ máy khác (wgt đã ký + sdb + .bat)
#   .\deploy.ps1 -Kit -Profile OIOI -KitName SubtitleTV-OIOI   zip đặt tên riêng (không ghi đè zip mặc định)
#   .\deploy.ps1 -IdKit                      gói nhỏ "lấy mã TV": gửi cho người dùng TV mới để họ lấy DUID gửi lại
#   .\deploy.ps1 -App HdmiTest -Tv <IP> -Profile HVM-TV   cài app khác trong thư mục này (vd. app test HDMI tối giản)
# -Profile = tên thư mục chứng chỉ trong %USERPROFILE%\SamsungCertificate (hoặc %APPDATA%\ScreenTranslator\tv-certs);
# mật khẩu lấy từ password.txt hoặc *.pwd của Certificate Manager (DPAPI tài khoản Windows này).
param(
    [string]$Tv = "192.168.8.31",
    [string]$Profile = "LipNguyen-TV",
    [string]$App = "SubtitleTV",
    [switch]$Debug,
    [switch]$Kit,
    [string]$KitName = "SubtitleTV-Samsung",
    [switch]$IdKit
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Security
$sdb = @((Join-Path $PSScriptRoot "sdb.exe"), (Join-Path $PSScriptRoot "..\Vendor\tizen\sdb.exe")) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $sdb) { throw "Không thấy sdb.exe (windows\Vendor\tizen\sdb.exe — chạy windows\build.ps1 một lần, hoặc lấy từ bộ cài)" }
$src = Join-Path $PSScriptRoot $App
# id app / gói lấy từ config.xml của app được chọn.
$cfgXml = [xml](Get-Content (Join-Path $src "config.xml") -Raw)
$appId = $cfgXml.widget.application.id
$pkgId = $cfgXml.widget.application.package
$serial = "${Tv}:26101"
$out = Join-Path $PSScriptRoot "build"
$wgtName = "$App.wgt"

if ($IdKit) {
    # Gói "lấy mã TV" = sdb.exe + LAY-ID-TV.bat + hướng dẫn. Gửi cho người dùng TV mới: họ chạy lấy DUID rồi gửi lại.
    New-Item -ItemType Directory -Force $out | Out-Null
    $idDir = Join-Path $out "LayID-TV-Samsung"
    Remove-Item -Recurse -Force $idDir -ErrorAction SilentlyContinue
    New-Item -ItemType Directory $idDir | Out-Null
    Copy-Item $sdb, (Join-Path $PSScriptRoot "LAY-ID-TV.bat"), (Join-Path $PSScriptRoot "HUONG-DAN-CAI-TV.txt") $idDir
    $dist = Join-Path $PSScriptRoot "..\dist"
    New-Item -ItemType Directory -Force $dist | Out-Null
    $zip = Join-Path (Resolve-Path $dist) "LayID-TV-Samsung.zip"
    Compress-Archive -Path $idDir -DestinationPath $zip -Force
    Write-Host "Gói lấy mã TV: $zip"
    return
}

# ---------- Chứng chỉ ----------
$certDir = @((Join-Path "$env:USERPROFILE\SamsungCertificate" $Profile), (Join-Path "$env:APPDATA\ScreenTranslator\tv-certs" $Profile)) |
    Where-Object { Test-Path (Join-Path $_ "author.p12") } | Select-Object -First 1
if (-not $certDir) { throw "Không thấy chứng chỉ '$Profile' trong %USERPROFILE%\SamsungCertificate hoặc %APPDATA%\ScreenTranslator\tv-certs" }
function Get-Password([string]$which) {
    foreach ($f in "$which.password.txt", "password.txt") { if (Test-Path (Join-Path $certDir $f)) { return (Get-Content (Join-Path $certDir $f) -Raw).Trim() } }
    $b = [IO.File]::ReadAllBytes((Join-Path $certDir "$which.pwd"))   # DPAPI, 4 byte đầu là độ dài
    [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect($b[4..($b.Length - 1)], $null, 'CurrentUser'))
}

Remove-Item -Recurse -Force $out -ErrorAction SilentlyContinue
New-Item -ItemType Directory $out | Out-Null
$wgt = Join-Path $out $wgtName
& (Join-Path $PSScriptRoot "sign-wgt.ps1") -Src $src -Out $wgt -Author (Join-Path $certDir "author.p12") -Distributor (Join-Path $certDir "distributor.p12") `
    -Password (Get-Password "author") -DistributorPassword (Get-Password "distributor") | Out-Null

if ($Kit) {
    # Bộ cài = file .wgt đã ký + sdb.exe (chạy độc lập) + CAI-LEN-TV.bat + LAY-ID-TV.bat + hướng dẫn, nén thành 1 file zip.
    $kitDir = Join-Path $out $KitName
    New-Item -ItemType Directory $kitDir | Out-Null
    Copy-Item $wgt, $sdb, (Join-Path $PSScriptRoot "LAY-ID-TV.bat"), (Join-Path $PSScriptRoot "HUONG-DAN-CAI-TV.txt") $kitDir
    # CAI-LEN-TV.bat viết cho SubtitleTV → thay tên file / id app cho app được chọn (giữ ASCII + CRLF cho cmd).
    $bat = (Get-Content (Join-Path $PSScriptRoot "CAI-LEN-TV.bat") -Raw).Replace("StSubTV001.SubtitleTV", $appId).Replace("StSubTV001", $pkgId).Replace("SubtitleTV.wgt", $wgtName)
    [IO.File]::WriteAllText((Join-Path $kitDir "CAI-LEN-TV.bat"), $bat, [Text.Encoding]::ASCII)
    $dist = Join-Path $PSScriptRoot "..\dist"
    New-Item -ItemType Directory -Force $dist | Out-Null
    $zip = Join-Path (Resolve-Path $dist) "$KitName.zip"
    Compress-Archive -Path $kitDir -DestinationPath $zip -Force
    Write-Host "Bộ cài: $zip"
    return
}

& $sdb connect $Tv | Out-Null
$remote = "/home/owner/share/tmp/sdk_tools/tmp/$wgtName"
& $sdb -s $serial push $wgt $remote | Out-Null
$res = & $sdb -s $serial shell 0 vd_appinstall $pkgId $remote
$res | Where-Object { $_ -match 'install (failed|completed)|spend time' } | Select-Object -Last 2
if (-not ($res -match "install completed")) { throw "Cài lên TV thất bại" }
& $sdb -s $serial shell 0 was_kill $appId | Out-Null
if ($Debug) {
    $r = & $sdb -s $serial shell 0 debug $appId
    $r
    $port = ([regex]::Match(($r -join " "), "port: *(\d+)")).Groups[1].Value
    if ($port) {
        & $sdb -s $serial forward --remove-all 2>$null
        & $sdb -s $serial forward tcp:9555 "tcp:$port" | Out-Null
        Write-Host "DevTools: http://127.0.0.1:9555/json"
    }
} else {
    & $sdb -s $serial shell 0 execute $appId
}
