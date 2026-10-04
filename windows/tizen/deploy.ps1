# Đóng gói (ký chứng chỉ Samsung) và cài app Subtitle TV lên TV Samsung Tizen đang bật Developer Mode.
#   .\deploy.ps1 -Tv 192.168.8.31            đóng gói + cài + mở app
#   .\deploy.ps1 -Tv 192.168.8.31 -Debug     mở app ở chế độ debug (in cổng DevTools để soi lỗi)
param(
    [string]$Tv = "192.168.8.31",
    [string]$Profile = "LipNguyen-TV",
    [string]$Tizen = "C:\tizen-studio",
    [switch]$Debug
)
$ErrorActionPreference = "Stop"
$sdb = Join-Path $Tizen "tools\sdb.exe"
$cli = Join-Path $Tizen "tools\ide\bin\tizen.bat"
$appId = "StSubTV001.SubtitleTV"
$pkgId = "StSubTV001"
$serial = "${Tv}:26101"
$src = Join-Path $PSScriptRoot "SubtitleTV"
$out = Join-Path $PSScriptRoot "build"

& $sdb connect $Tv | Out-Null
Remove-Item -Recurse -Force $out -ErrorAction SilentlyContinue
New-Item -ItemType Directory $out | Out-Null
Copy-Item "$src\*" $out
& $cli package -t wgt -s $Profile -- $out | Out-Null
# Tên gói có dấu cách làm trình cài trên TV báo lỗi → đổi tên.
$wgt = Get-ChildItem $out -Filter *.wgt | Select-Object -First 1
if (-not $wgt) { throw "Đóng gói thất bại (kiểm tra profile chứng chỉ '$Profile')" }
Move-Item $wgt.FullName (Join-Path $out "SubtitleTV.wgt") -Force
$remote = "/home/owner/share/tmp/sdk_tools/tmp/SubtitleTV.wgt"
& $sdb -s $serial push (Join-Path $out "SubtitleTV.wgt") $remote | Out-Null
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
