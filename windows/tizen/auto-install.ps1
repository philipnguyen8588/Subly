# Cài Subtitle TV lên một TV Samsung bất kỳ, KHÔNG cần Tizen Studio:
#   1. Kết nối TV bằng sdb.exe (Developer Mode bật, Host PC IP = máy này), lấy DUID.
#   2. Tìm bộ chứng chỉ có DUID này (thư mục certs\ cạnh script, hoặc %USERPROFILE%\SamsungCertificate).
#      Chưa có → mở trang đăng nhập Samsung (người dùng tự đăng nhập), samsung-cert.ps1 xin Samsung ký chứng chỉ mới
#      vào certs\Subly-Auto (cộng dồn DUID qua các lần).
#   3. Ký app bằng sign-wgt.ps1 rồi cài + mở trên TV.
#
#   .\auto-install.ps1 -Tv 192.168.8.40
#   .\auto-install.ps1 -Tv 192.168.8.40 -NewCert     bỏ qua chứng chỉ có sẵn, luôn xin chứng chỉ mới
#   .\auto-install.ps1 -Tv 192.168.8.40 -Reinstall   gỡ app cũ trước (TV đã cài app bằng chứng chỉ khác thì cài đè
#                                                     có thể bị từ chối; gỡ thì mất cài đặt đã lưu trong app trên TV)
param(
    [string]$Tv,
    [string]$CertDir,
    [switch]$NewCert,
    [switch]$Reinstall
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Security
$here = $PSScriptRoot
$sdb = Join-Path $here "sdb.exe"
if (-not (Test-Path $sdb)) { $sdb = "C:\tizen-studio\tools\sdb.exe" }
if (-not (Test-Path $sdb)) { throw "Không thấy sdb.exe (để cạnh script này)." }
$app = Join-Path $here "SubtitleTV"
if (-not $CertDir) {
    $CertDir = Join-Path $here "certs"
    if (-not (Test-Path $CertDir) -and (Test-Path "$env:USERPROFILE\SamsungCertificate")) { $CertDir = "$env:USERPROFILE\SamsungCertificate" }
}
$cfg = [xml](Get-Content (Join-Path $app "config.xml") -Raw)
$appId = $cfg.widget.application.id
$pkgId = $cfg.widget.application.package

# Mật khẩu .p12: password.txt (bộ cài / samsung-cert.ps1) hoặc *.pwd của Certificate Manager (DPAPI, chỉ đọc được
# trên đúng máy + tài khoản Windows đã tạo; 4 byte đầu là độ dài).
function Get-Password([string]$dir, [string]$which) {
    foreach ($f in "$which.password.txt", "password.txt") { if (Test-Path (Join-Path $dir $f)) { return (Get-Content (Join-Path $dir $f) -Raw).Trim() } }
    $pwd = Join-Path $dir "$which.pwd"
    if (Test-Path $pwd) {
        try {
            $b = [IO.File]::ReadAllBytes($pwd)
            return [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect($b[4..($b.Length - 1)], $null, 'CurrentUser'))
        } catch { }
    }
    return $null
}
function Get-Duids([string]$dir) {
    $list = @()
    if (Test-Path (Join-Path $dir "duids.txt")) { $list += Get-Content (Join-Path $dir "duids.txt") | ForEach-Object { $_.Trim() } | Where-Object { $_ } }
    if (Test-Path (Join-Path $dir "device-profile.xml")) {
        $list += [regex]::Matches((Get-Content (Join-Path $dir "device-profile.xml") -Raw), '<TestDevice>([^<]+)</TestDevice>') | ForEach-Object { $_.Groups[1].Value }
    }
    return $list
}

if (-not $Tv) { $Tv = Read-Host "IP của TV (Cài đặt > Chung > Mạng > Trạng thái mạng)" }
$serial = "${Tv}:26101"

# ---------- 1. DUID ----------
Write-Host "== Kết nối TV $Tv" -ForegroundColor Cyan
$c = & $sdb connect $Tv 2>&1 | Out-String
if ($c -notmatch "connected") {
    throw "Không kết nối được TV $Tv.`n$c`nKiểm tra: TV bật Developer Mode (Apps → bấm 1 2 3 4 5), Host PC IP = IP máy này, đã tắt/mở lại TV, cùng mạng."
}
$duid = ((& $sdb -s $serial shell 0 getduid) -join "").Trim()
if ($duid -notmatch '^[A-Z0-9]{8,}$') { throw "Không đọc được DUID của TV (nhận được: '$duid')" }
Write-Host "DUID: $duid"

# ---------- 2. Chứng chỉ ----------
$use = $null
if (-not $NewCert -and (Test-Path $CertDir)) {
    foreach ($d in Get-ChildItem $CertDir -Directory) {
        if ((Test-Path (Join-Path $d.FullName "author.p12")) -and (Test-Path (Join-Path $d.FullName "distributor.p12")) -and
            ((Get-Duids $d.FullName) -contains $duid) -and (Get-Password $d.FullName "author")) { $use = $d.FullName; break }
    }
}
if ($use) {
    Write-Host "TV đã có trong chứng chỉ '$(Split-Path $use -Leaf)' → không cần đăng nhập Samsung."
} else {
    Write-Host "== Xin chứng chỉ Samsung cho TV này (đăng nhập Samsung Account trên trình duyệt)" -ForegroundColor Cyan
    $use = Join-Path $CertDir "Subly-Auto"
    & (Join-Path $here "samsung-cert.ps1") -Out $use -Duid $duid
}

# ---------- 3. Ký + cài ----------
Write-Host "== Ký app bằng chứng chỉ '$(Split-Path $use -Leaf)'" -ForegroundColor Cyan
$wgt = Join-Path ([IO.Path]::GetTempPath()) "SubtitleTV.wgt"
& (Join-Path $here "sign-wgt.ps1") -Src $app -Out $wgt -Author (Join-Path $use "author.p12") -Distributor (Join-Path $use "distributor.p12") `
    -Password (Get-Password $use "author") -DistributorPassword (Get-Password $use "distributor")

if ($Reinstall) {
    Write-Host "== Gỡ app cũ ($pkgId)" -ForegroundColor Cyan
    & $sdb -s $serial shell 0 vd_appuninstall $pkgId | Select-Object -Last 1
}
Write-Host "== Cài lên TV" -ForegroundColor Cyan
$remote = "/home/owner/share/tmp/sdk_tools/tmp/SubtitleTV.wgt"
& $sdb -s $serial push $wgt $remote | Out-Null
$res = & $sdb -s $serial shell 0 vd_appinstall $pkgId $remote
$res | Select-Object -Last 2
if (-not ($res -match "install completed")) {
    if (-not $Reinstall) { Write-Host "Nếu TV đã có app cài bằng chứng chỉ khác, chạy lại kèm -Reinstall (gỡ app cũ rồi cài)." -ForegroundColor Yellow }
    throw "Cài lên TV thất bại"
}
& $sdb -s $serial shell 0 was_kill $appId | Out-Null
& $sdb -s $serial shell 0 execute $appId | Out-Null
Write-Host "Xong: Subtitle TV đã cài và mở trên TV $Tv." -ForegroundColor Green
