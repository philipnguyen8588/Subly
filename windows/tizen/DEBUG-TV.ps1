# Mở app Subtitle TV trên TV Samsung ở chế độ DEBUG và bật DevTools (Chrome) để soi log.
#   .\DEBUG-TV.ps1                    mở debug TV mặc định rồi mở Chrome vào DevTools
#   .\DEBUG-TV.ps1 -Tv 192.168.2.245  chỉ định IP TV
#   .\DEBUG-TV.ps1 -Normal            mở chạy thường (không debug, không DevTools)
#   .\DEBUG-TV.ps1 -NoChrome          mở debug nhưng không tự mở Chrome (tự vào http://localhost:9222)
# TV phải bật Developer Mode + Host PC IP đúng; nếu TV ở xa thì bật Tailscale trước.
param(
    [string]$Tv = "192.168.2.245",
    [string]$Tizen = "C:\tizen-studio",
    [int]$Port = 9222,
    [switch]$Normal,
    [switch]$NoChrome
)
$ErrorActionPreference = "Stop"
$sdb = Join-Path $Tizen "tools\sdb.exe"
$appId = "StSubTV001.SubtitleTV"
$serial = "${Tv}:26101"

if (-not $Tv) { $Tv = Read-Host "Nhap IP cua TV" }

Write-Host "== Ket noi $Tv" -ForegroundColor Cyan
& $sdb connect $Tv | Out-Null
& $sdb -s $serial shell 0 was_kill $appId 2>$null | Out-Null
Start-Sleep -Milliseconds 500

if ($Normal) {
    Write-Host "== Mo app (chay thuong)" -ForegroundColor Cyan
    & $sdb -s $serial shell 0 execute $appId
    Write-Host "Da mo app tren TV (khong debug)." -ForegroundColor Green
    return
}

Write-Host "== Mo app (debug)" -ForegroundColor Cyan
$r = & $sdb -s $serial shell 0 debug $appId
$r
$m = [regex]::Match(($r -join ' '), 'port:\s*(\d+)')
if (-not $m.Success) { throw "Khong lay duoc cong debug (TV da bat Developer Mode chua?)" }
$tvPort = $m.Groups[1].Value
& $sdb -s $serial forward --remove-all 2>$null | Out-Null
& $sdb -s $serial forward "tcp:$Port" "tcp:$tvPort" | Out-Null

$url = "http://localhost:$Port"
Write-Host "DevTools: $url  -> bam trang 'Subtitle TV'" -ForegroundColor Green
if (-not $NoChrome) {
    $chrome = @(
        "C:\Program Files\Google\Chrome\Application\chrome.exe",
        "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($chrome) { & $chrome $url | Out-Null } else { Start-Process $url }
}
