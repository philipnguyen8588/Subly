# Đóng gói và cài app Subtitle TV lên TV LG webOS đang bật Developer Mode (cần ares-cli: npm i -g @webos-tools/cli).
#   .\deploy.ps1 -Tv 192.168.1.40            đóng gói + cài + mở app
#   .\deploy.ps1 -Tv 192.168.1.40 -Debug     mở thêm DevTools (Web Inspector) để soi lỗi
# Lần đầu với một TV: script hỏi Passphrase (hiện trong app Developer Mode trên TV) để lấy khoá SSH.
param(
    [Parameter(Mandatory = $true)][string]$Tv,
    [string]$Device = "lgtv",
    [switch]$Debug
)
$ErrorActionPreference = "Stop"
$appId = "com.lipnguyen.subtitletv"
$src = Join-Path $PSScriptRoot "SubtitleTV"
$out = Join-Path $PSScriptRoot "build"
if (-not (Get-Command ares-package -ErrorAction SilentlyContinue)) { throw "Chưa có ares-cli. Cài Node.js rồi chạy: npm i -g @webos-tools/cli" }

# Thêm TV vào danh sách thiết bị của ares (hoặc cập nhật IP nếu TV đã có nhưng đổi IP).
$devices = (& ares-setup-device -F 2>$null) -join "`n"
if ($devices -notmatch "`"name`":\s*`"$Device`"") {
    & ares-setup-device -a $Device -i "host=$Tv" -i "port=9922" -i "username=prisoner" | Out-Null
} else {
    & ares-setup-device -m $Device -i "host=$Tv" | Out-Null
}
# Khoá SSH của TV: lấy một lần (nhập Passphrase hiện trong app Developer Mode).
$key = Join-Path $env:USERPROFILE ".ssh\${Device}_webos"
if (-not (Test-Path $key)) {
    Write-Host "Lần đầu: nhập Passphrase hiện trong app Developer Mode trên TV" -ForegroundColor Cyan
    & ares-novacom --device $Device --getkey
    if ($LASTEXITCODE -ne 0) { throw "Không lấy được khoá. Kiểm tra Developer Mode + Key Server đang bật trên TV." }
}

Remove-Item -Recurse -Force $out -ErrorAction SilentlyContinue
& ares-package $src -o $out | Out-Null
$ipk = Get-ChildItem $out -Filter *.ipk | Select-Object -First 1
if (-not $ipk) { throw "Đóng gói thất bại" }
& ares-install -d $Device $ipk.FullName
if ($LASTEXITCODE -ne 0) { throw "Cài lên TV thất bại (TV tắt Developer Mode / hết hạn phiên?)" }
& ares-launch -d $Device $appId | Out-Null
Write-Host "Đã cài và mở Subtitle TV trên $Tv" -ForegroundColor Green
if ($Debug) { & ares-inspect -d $Device --app $appId --open }
