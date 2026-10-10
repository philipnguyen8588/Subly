# Đóng gói (ký chứng chỉ Samsung) và cài app Subtitle TV lên TV Samsung Tizen đang bật Developer Mode.
#   .\deploy.ps1 -Tv 192.168.8.31            đóng gói + cài + mở app
#   .\deploy.ps1 -Tv 192.168.8.31 -Debug     mở app ở chế độ debug (in cổng DevTools để soi lỗi)
#   .\deploy.ps1 -Kit                        chỉ đóng gói thành 1 file zip cài được từ máy không có Tizen Studio
#   .\deploy.ps1 -Kit -Profile OIOI -KitName SubtitleTV-OIOI   zip đặt tên riêng (không ghi đè zip mặc định)
#   .\deploy.ps1 -IdKit                      gói nhỏ "lấy mã TV": gửi cho người dùng TV mới để họ lấy DUID gửi lại
#   .\deploy.ps1 -App HdmiTest -Tv <IP> -Profile HVM-TV   cài app khác trong thư mục này (vd. app test HDMI tối giản)
param(
    [string]$Tv = "192.168.8.31",
    [string]$Profile = "LipNguyen-TV",
    [string]$Tizen = "C:\tizen-studio",
    [string]$App = "SubtitleTV",
    [switch]$Debug,
    [switch]$Kit,
    [string]$KitName = "SubtitleTV-Samsung",
    [switch]$IdKit
)
$ErrorActionPreference = "Stop"
$sdb = Join-Path $Tizen "tools\sdb.exe"
$cli = Join-Path $Tizen "tools\ide\bin\tizen.bat"
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

Remove-Item -Recurse -Force $out -ErrorAction SilentlyContinue
New-Item -ItemType Directory $out | Out-Null
Copy-Item "$src\*" $out
& $cli package -t wgt -s $Profile -- $out | Out-Null
# Tên gói có dấu cách làm trình cài trên TV báo lỗi → đổi tên.
$wgt = Get-ChildItem $out -Filter *.wgt | Select-Object -First 1
if (-not $wgt) { throw "Đóng gói thất bại (kiểm tra profile chứng chỉ '$Profile')" }
Move-Item $wgt.FullName (Join-Path $out $wgtName) -Force

if ($Kit) {
    # Bộ cài = file .wgt đã ký + sdb.exe (chạy độc lập) + CAI-LEN-TV.bat + LAY-ID-TV.bat + hướng dẫn, nén thành 1 file zip.
    $kitDir = Join-Path $out $KitName
    New-Item -ItemType Directory $kitDir | Out-Null
    Copy-Item (Join-Path $out $wgtName), $sdb, (Join-Path $PSScriptRoot "LAY-ID-TV.bat"), (Join-Path $PSScriptRoot "HUONG-DAN-CAI-TV.txt") $kitDir
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
& $sdb -s $serial push (Join-Path $out $wgtName) $remote | Out-Null
$res = & $sdb -s $serial shell 0 vd_appinstall $pkgId $remote
$res | Select-Object -Last 2
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
