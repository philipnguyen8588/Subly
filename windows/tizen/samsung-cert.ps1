# Xin chứng chỉ Samsung (author + distributor có DUID của TV) mà không cần mở Certificate Manager.
# Chỉ dùng PowerShell + .NET Framework có sẵn trong Windows (không cần Python).
#
# Làm đúng như Certificate Manager / Tizen extension (theo tool mã nguồn mở Apps2Samsung, MIT):
#   1. Mở trang đăng nhập Samsung Account trên trình duyệt; người dùng tự đăng nhập.
#   2. Samsung POST token về http://localhost:4794/signin/callback (máy này nghe cổng đó).
#   3. Tạo khoá RSA + CSR, gửi lên svdca.samsungqbe.com để Samsung ký; CSR distributor ghi DUID của các TV.
#   4. Ghép thành author.p12 / distributor.p12 (kèm CA trung gian) để `tizen package` ký app.
# Profile cộng dồn DUID (tối đa 10). Lần sau thêm TV chỉ xin lại distributor, author giữ nguyên khoá → app đã cài
# trên TV cũ vẫn cập nhật được.
#
#   .\samsung-cert.ps1 -Out C:\Users\<user>\SamsungCertificate\Subly-Auto -Duid BDCGOF7Z2EPXG
param(
    [Parameter(Mandatory = $true)][string]$Out,
    [Parameter(Mandatory = $true)][string[]]$Duid,
    [string]$Api = "https://svdca.samsungqbe.com/apis",   # đổi được để thử với máy chủ giả
    [switch]$NoBrowser,                                     # thử nghiệm: không mở trình duyệt
    [int]$TimeoutSec = 600
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Net.Http
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$SignIn = "https://account.samsung.com/accounts/be1dce529476c1a6d407c4c7578c31bd/signInGate"
$ClientId = "v285zxnl3h"          # client id của Tizen Studio
$State = "accountcheckdogeneratedstatetext"
$Port = 4794                      # Samsung chỉ chấp nhận redirect về đúng cổng này
$CaDir = Join-Path $PSScriptRoot "ca"
$MaxDuids = 10
New-Item -ItemType Directory -Force $Out | Out-Null
function P([string]$name) { Join-Path $Out $name }

# ---------- 1–2. Đăng nhập Samsung Account ----------
function Get-SamsungAuth {
    $listener = New-Object Net.HttpListener
    $listener.Prefixes.Add("http://localhost:$Port/")
    try { $listener.Start() } catch { throw "Không nghe được cổng $Port (Certificate Manager / Tizen Studio đang mở?). Đóng nó rồi chạy lại. $($_.Exception.Message)" }
    try {
        $redirect = [Uri]::EscapeDataString("http://localhost:$Port/signin/callback")
        $url = "${SignIn}?locale=&clientId=$ClientId&redirect_uri=$redirect&state=$State&tokenType=TOKEN"
        Write-Host "Đang mở trang đăng nhập Samsung Account trên trình duyệt…"
        Write-Host "  Nếu trình duyệt không tự mở, copy link này: $url"
        if (-not $NoBrowser) { Start-Process $url }
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while ($true) {
            $wait = [int][Math]::Max(0, ($deadline - (Get-Date)).TotalMilliseconds)
            $task = $listener.GetContextAsync()
            if (-not $task.Wait($wait)) { throw "Hết thời gian chờ đăng nhập Samsung." }
            $ctx = $task.Result
            $auth = $null; $msg = "Phản hồi đăng nhập không hợp lệ."
            if ($ctx.Request.HttpMethod -eq "POST" -and $ctx.Request.Url.AbsolutePath -eq "/signin/callback") {
                $raw = (New-Object IO.StreamReader($ctx.Request.InputStream, [Text.Encoding]::UTF8)).ReadToEnd()
                $form = @{}
                foreach ($kv in $raw -split '&') {
                    $i = $kv.IndexOf('=')
                    if ($i -gt 0) { $form[[Uri]::UnescapeDataString($kv.Substring(0, $i))] = [Uri]::UnescapeDataString($kv.Substring($i + 1).Replace('+', ' ')) }
                }
                if ($form['state'] -eq $State -and $form['code']) {
                    try { $auth = $form['code'] | ConvertFrom-Json } catch { }
                    if ($auth -and $auth.access_token) { $msg = "✅ Đã đăng nhập Samsung. Đóng trang này và quay lại cửa sổ cài đặt." } else { $auth = $null }
                }
            }
            $html = [Text.Encoding]::UTF8.GetBytes("<html><meta charset=`"utf-8`"><body style=`"font:20px sans-serif;padding:40px`">$msg</body></html>")
            $ctx.Response.StatusCode = $(if ($auth) { 200 } else { 400 })
            $ctx.Response.ContentType = "text/html; charset=utf-8"
            $ctx.Response.OutputStream.Write($html, 0, $html.Length)
            $ctx.Response.Close()
            if ($auth) { break }
        }
    } finally { $listener.Stop(); $listener.Close() }
    if (-not $auth.inputEmailID) { throw "Tài khoản Samsung không trả về email; chứng chỉ distributor cần email." }
    Write-Host "Đã đăng nhập: $($auth.inputEmailID)"
    return $auth
}

# ---------- 3. CSR + gửi Samsung ký ----------
function DerLength([int]$n) {
    if ($n -lt 0x80) { return , [byte]$n }
    if ($n -lt 0x100) { return [byte[]](0x81, $n) }
    return [byte[]](0x82, ($n -shr 8), ($n -band 0xFF))
}
function DerTlv([byte]$tag, [byte[]]$content) { [byte[]](@($tag) + (DerLength $content.Length) + $content) }

# SAN tự mã hoá DER (mỗi DUID là một URI "URN:tizen:deviceid=…"): Uri của .NET sẽ đổi "URN:" thành chữ thường.
function New-SanExtension([string[]]$uris) {
    $items = @()
    foreach ($u in $uris) { $items += DerTlv 0x86 ([Text.Encoding]::ASCII.GetBytes($u)) }
    New-Object Security.Cryptography.X509Certificates.X509Extension("2.5.29.17", (DerTlv 0x30 ([byte[]]$items)), $false)
}

function New-CsrPem($key, [string]$subject, [string[]]$sanUris) {
    $req = New-Object Security.Cryptography.X509Certificates.CertificateRequest($subject, $key,
        [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    if ($sanUris) { $req.CertificateExtensions.Add((New-SanExtension $sanUris)) }
    $b64 = [Convert]::ToBase64String($req.CreateSigningRequest(), [Base64FormattingOptions]::InsertLineBreaks)
    [Text.Encoding]::ASCII.GetBytes("-----BEGIN CERTIFICATE REQUEST-----`n$($b64 -replace "`r", '')`n-----END CERTIFICATE REQUEST-----`n")
}

function Send-Csr([string]$path, $auth, [byte[]]$csr, [string]$fileName, [hashtable]$extra) {
    $http = New-Object Net.Http.HttpClient
    $http.Timeout = [TimeSpan]::FromSeconds(60)
    $form = New-Object Net.Http.MultipartFormDataContent
    $fields = [ordered]@{ access_token = $auth.access_token; user_id = $auth.userId }
    if ($extra) { foreach ($k in $extra.Keys) { $fields[$k] = $extra[$k] } }
    $fields['platform'] = 'VD'
    foreach ($k in $fields.Keys) { $form.Add((New-Object Net.Http.StringContent([string]$fields[$k])), $k) }
    $form.Add((New-Object Net.Http.ByteArrayContent(, $csr)), "csr", $fileName)
    $res = $http.PostAsync("$Api/$path", $form).Result
    $body = $res.Content.ReadAsByteArrayAsync().Result
    if (-not $res.IsSuccessStatusCode) {
        throw "Samsung từ chối ($path): HTTP $([int]$res.StatusCode) $([Text.Encoding]::UTF8.GetString($body))"
    }
    return , $body
}

function Read-Cert([byte[]]$data) {
    $text = [Text.Encoding]::ASCII.GetString($data)
    if ($text -match '-----BEGIN CERTIFICATE-----([\s\S]+?)-----END CERTIFICATE-----') { $data = [Convert]::FromBase64String(($Matches[1] -replace '\s', '')) }
    New-Object Security.Cryptography.X509Certificates.X509Certificate2(, $data)
}

function Write-P12([string]$path, $key, [byte[]]$signed, [string]$caFile, [string]$password) {
    $leaf = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::CopyWithPrivateKey((Read-Cert $signed), $key)
    $ca = Read-Cert ([IO.File]::ReadAllBytes((Join-Path $CaDir $caFile)))
    $col = New-Object Security.Cryptography.X509Certificates.X509Certificate2Collection
    [void]$col.Add($leaf); [void]$col.Add($ca)
    # Windows xuất PFX dạng 3DES/SHA1 → Java 8 trong Tizen Studio đọc được.
    [IO.File]::WriteAllBytes($path, $col.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12, $password))
}

# ---------- chạy ----------
# DUID cũ của profile + DUID mới (một chứng chỉ distributor chứa được tối đa 10 TV).
$duids = New-Object Collections.Generic.List[string]
if (Test-Path (P "duids.txt")) { Get-Content (P "duids.txt") | Where-Object { $_.Trim() } | ForEach-Object { $duids.Add($_.Trim()) } }
foreach ($d in $Duid) { if (-not $duids.Contains($d)) { $duids.Add($d) } }
if ($duids.Count -gt $MaxDuids) {
    Write-Host "Profile đã có $($duids.Count - $Duid.Count) TV; giữ $MaxDuids TV mới nhất."
    $duids = [Collections.Generic.List[string]]($duids | Select-Object -Last $MaxDuids)
}

$auth = Get-SamsungAuth

if ((Test-Path (P "author.p12")) -and (Test-Path (P "password.txt"))) {
    $password = (Get-Content (P "password.txt") -Raw).Trim()
    $flags = [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable
    $authorCert = New-Object Security.Cryptography.X509Certificates.X509Certificate2((P "author.p12"), $password, $flags)
    # Dùng thẳng khoá của author (Exportable → xuất lại được vào distributor.p12).
    $key = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($authorCert)
    Write-Host "Dùng lại chứng chỉ author có sẵn, chỉ xin lại distributor."
} else {
    $password = -join ((1..24) | ForEach-Object { [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789' | Get-Random })
    $key = New-Object Security.Cryptography.RSACng(2048)
    Write-Host "Xin chứng chỉ author…"
    $author = Send-Csr "v3/authors" $auth (New-CsrPem $key "CN=Subly" $null) "author.csr"
    [IO.File]::WriteAllBytes((P "signed_author.cer"), $author)
    Write-P12 (P "author.p12") $key $author "vd_tizen_dev_author_ca.cer" $password
    Set-Content (P "password.txt") $password -NoNewline -Encoding ASCII
}

Write-Host "Xin chứng chỉ distributor cho TV: $($duids -join ', ')"
$san = @("URN:tizen:packageid=") + ($duids | ForEach-Object { "URN:tizen:deviceid=$_" })
$csr = New-CsrPem $key "E=$($auth.inputEmailID), CN=TizenSDK" $san
$extra = [ordered]@{ privilege_level = "public"; developer_type = "Individual" }
[IO.File]::WriteAllBytes((P "device-profile.xml"), (Send-Csr "v1/distributors" $auth $csr "distributor.csr" $extra))
$dist = Send-Csr "v3/distributors" $auth $csr "distributor.csr" $extra
[IO.File]::WriteAllBytes((P "signed_distributor.cer"), $dist)
Write-P12 (P "distributor.p12") $key $dist "vd_tizen_dev_public2.crt" $password
Set-Content (P "duids.txt") ($duids -join "`r`n") -Encoding ASCII
Write-Host "Xong chứng chỉ: $Out"
