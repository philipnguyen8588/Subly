# Tạo thư mục cài đặt standalone (máy mới KHÔNG cần Tizen Studio): windows\dist\SubtitleTV-Installer (+ .zip)
#   sdb.exe, app SubtitleTV, các script ký/xin chứng chỉ/cài, CA của Samsung, và các bộ chứng chỉ đã có
#   (author.p12 + distributor.p12 + mật khẩu dạng chữ) để TV đã đăng ký cài được ngay không cần đăng nhập.
#
#   .\make-installer.ps1             kèm chứng chỉ đang có trên máy này
#   .\make-installer.ps1 -NoCerts    không kèm chứng chỉ (máy nhận sẽ phải đăng nhập Samsung cho mọi TV)
#   .\make-installer.ps1 -Only HVM-TV -Name SubtitleTV-Installer-HVM   chỉ kèm chứng chỉ HVM-TV, đặt tên riêng
param(
    [switch]$NoCerts,
    [string[]]$Only,                        # chỉ kèm các bộ chứng chỉ này (tên thư mục trong SamsungCertificate)
    [string]$Name = "SubtitleTV-Installer",
    [string]$Tizen = "C:\tizen-studio"
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Security
$here = $PSScriptRoot
$dist = Join-Path $here "..\dist"
$out = Join-Path $dist $Name
Remove-Item -Recurse -Force $out -ErrorAction SilentlyContinue
New-Item -ItemType Directory $out | Out-Null

Copy-Item (Join-Path $Tizen "tools\sdb.exe") $out
Copy-Item (Join-Path $here "ca") $out -Recurse
foreach ($f in "auto-install.ps1", "samsung-cert.ps1", "sign-wgt.ps1", "TU-DONG-CAI-TV.bat") { Copy-Item (Join-Path $here $f) $out }
New-Item -ItemType Directory (Join-Path $out "SubtitleTV") | Out-Null
Get-ChildItem (Join-Path $here "SubtitleTV") -File | Where-Object { $_.Name -notmatch '^(author-signature|signature\d*)\.xml$|\.wgt$' } |
    ForEach-Object { Copy-Item $_.FullName (Join-Path $out "SubtitleTV") }

$certs = Join-Path $out "certs"
New-Item -ItemType Directory $certs | Out-Null
if (-not $NoCerts) {
    foreach ($d in Get-ChildItem "$env:USERPROFILE\SamsungCertificate" -Directory -ErrorAction SilentlyContinue) {
        $a = Join-Path $d.FullName "author.p12"; $s = Join-Path $d.FullName "distributor.p12"
        if (-not ((Test-Path $a) -and (Test-Path $s))) { continue }
        if ($Only -and ($Only -notcontains $d.Name)) { continue }
        $dst = Join-Path $certs $d.Name
        New-Item -ItemType Directory $dst | Out-Null
        Copy-Item $a, $s $dst
        foreach ($x in "device-profile.xml", "duids.txt") { if (Test-Path (Join-Path $d.FullName $x)) { Copy-Item (Join-Path $d.FullName $x) $dst } }
        # Mật khẩu: password.txt có sẵn, hoặc giải mã *.pwd (DPAPI của máy này) ra chữ để máy khác dùng được.
        foreach ($which in "author", "distributor") {
            $plain = $null
            if (Test-Path (Join-Path $d.FullName "password.txt")) { $plain = (Get-Content (Join-Path $d.FullName "password.txt") -Raw).Trim() }
            elseif (Test-Path (Join-Path $d.FullName "$which.pwd")) {
                $b = [IO.File]::ReadAllBytes((Join-Path $d.FullName "$which.pwd"))
                $plain = [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect($b[4..($b.Length - 1)], $null, 'CurrentUser'))
            }
            if ($plain) { Set-Content (Join-Path $dst "$which.password.txt") $plain -NoNewline -Encoding ASCII }
        }
        $duids = [regex]::Matches((Get-Content (Join-Path $dst "device-profile.xml") -Raw -ErrorAction SilentlyContinue), '<TestDevice>([^<]+)</TestDevice>') | ForEach-Object { $_.Groups[1].Value }
        Write-Host "  chứng chỉ $($d.Name): $($duids -join ', ')"
    }
}

@"
CÀI SUBTITLE TV LÊN TV SAMSUNG (không cần Tizen Studio)

1. Trên TV: mở Apps, bấm 1 2 3 4 5 trên remote, bật Developer mode, Host PC IP = IP máy tính này.
   Tắt TV rồi mở lại. Xem IP của TV: Cài đặt > Chung > Mạng > Trạng thái mạng.
2. Máy tính và TV cùng mạng. Bấm đúp TU-DONG-CAI-TV.bat, nhập IP của TV.
3. TV chưa từng đăng ký: trình duyệt mở trang đăng nhập Samsung Account -> đăng nhập.
   Script tự xin chứng chỉ cho TV này (lưu ở certs\Subly-Auto), ký app và cài.

Lỗi cài vì TV đã có app cài bằng chứng chỉ khác: mở PowerShell trong thư mục này, chạy
   powershell -ExecutionPolicy Bypass -File auto-install.ps1 -Tv <IP-TV> -Reinstall
(gỡ app cũ rồi cài; mất cài đặt đã lưu trong app trên TV).

Thư mục certs\ chứa khoá ký app và mật khẩu: chỉ đưa cho người tin tưởng.
"@ | Set-Content (Join-Path $out "HUONG-DAN.txt") -Encoding UTF8

$zip = Join-Path (Resolve-Path $dist) "$Name.zip"
Compress-Archive -Path $out -DestinationPath $zip -Force
Write-Host "Bộ cài standalone: $out"
Write-Host "Nén: $zip"
