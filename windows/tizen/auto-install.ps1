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
if (-not (Test-Path $sdb)) { $sdb = Join-Path $here "..\Vendor\tizen\sdb.exe" }   # chạy trong repo
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
# Mọi bộ chứng chỉ có DUID này (một TV có thể nằm trong nhiều bộ). Thử lần lượt: app đã cài trên TV bằng chứng chỉ
# tác giả nào thì chỉ bộ cùng tác giả mới cài đè được (TV báo "Author certificate not match" với bộ khác).
$candidates = @()
if (-not $NewCert -and (Test-Path $CertDir)) {
    foreach ($d in Get-ChildItem $CertDir -Directory) {
        if ((Test-Path (Join-Path $d.FullName "author.p12")) -and (Test-Path (Join-Path $d.FullName "distributor.p12")) -and
            ((Get-Duids $d.FullName) -contains $duid) -and (Get-Password $d.FullName "author")) { $candidates += $d.FullName }
    }
}
if ($candidates.Count) {
    Write-Host "TV đã có trong chứng chỉ: $(($candidates | ForEach-Object { Split-Path $_ -Leaf }) -join ', ') → không cần đăng nhập Samsung."
} else {
    Write-Host "== Xin chứng chỉ Samsung cho TV này (đăng nhập Samsung Account trên trình duyệt)" -ForegroundColor Cyan
    $auto = Join-Path $CertDir "Subly-Auto"
    & (Join-Path $here "samsung-cert.ps1") -Out $auto -Duid $duid
    $candidates = @($auto)
}

# ---------- 3. Ký + cài ----------
$remote = "/home/owner/share/tmp/sdk_tools/tmp/SubtitleTV.wgt"
function Install-With([string]$certSet) {
    Write-Host "== Ký app bằng chứng chỉ '$(Split-Path $certSet -Leaf)' và cài lên TV" -ForegroundColor Cyan
    $wgt = Join-Path ([IO.Path]::GetTempPath()) "SubtitleTV.wgt"
    & (Join-Path $here "sign-wgt.ps1") -Src $app -Out $wgt -Author (Join-Path $certSet "author.p12") -Distributor (Join-Path $certSet "distributor.p12") `
        -Password (Get-Password $certSet "author") -DistributorPassword (Get-Password $certSet "distributor")
    & $sdb -s $serial push $wgt $remote | Out-Null
    $res = (& $sdb -s $serial shell 0 vd_appinstall $pkgId $remote) -join "`n"
    Write-Host (($res -split "`n" | Where-Object { $_ -match 'install (failed|completed)' }) -join "`n")
    return $res
}
function Uninstall-Old {
    Write-Host "== Gỡ app cũ ($pkgId)" -ForegroundColor Cyan
    & $sdb -s $serial shell 0 vd_appuninstall $pkgId | Select-Object -Last 1
}

if ($Reinstall) { Uninstall-Old }
$done = $false; $authorMismatch = $false
foreach ($cs in $candidates) {
    $res = Install-With $cs
    if ($res -match "install completed") { $done = $true; break }
    if ($res -match "Author certificate not match") { $authorMismatch = $true; continue }   # thử bộ tiếp theo
    break                                                                                     # lỗi khác: dừng
}
if (-not $done -and $authorMismatch -and -not $Reinstall) {
    Write-Host ""
    Write-Host "TV đã có Subtitle TV cài bằng chứng chỉ tác giả khác, nên không cài đè được." -ForegroundColor Yellow
    Write-Host "Gỡ app cũ rồi cài lại thì được, nhưng mất cài đặt đã lưu trong app trên TV (máy tính đã chọn, cỡ chữ…)." -ForegroundColor Yellow
    $ans = Read-Host "Gỡ app cũ rồi cài lại? (Y/N)"
    if ($ans -match '^[YyCc]') {
        Uninstall-Old
        $done = (Install-With $candidates[0]) -match "install completed"
    }
}
if (-not $done) { throw "Cài lên TV thất bại (xem dòng 'install failed' phía trên)" }
& $sdb -s $serial shell 0 was_kill $appId | Out-Null
& $sdb -s $serial shell 0 execute $appId | Out-Null
Write-Host "Xong: Subtitle TV đã cài và mở trên TV $Tv." -ForegroundColor Green
