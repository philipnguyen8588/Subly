# Sinh ScreenTranslator\Core\RuntimeConfigValues.cs từ subly.local.env ở thư mục gốc repo (không commit).
# Bản Windows của Scripts/gen_runtime_config.py (bản macOS).
#
# subly.local.env (thư mục gốc repo, dùng chung cho cả Mac và Windows):
#     SUBLY_SERVER=https://sub.example.com
#     SUBLY_PUBKEY=<public key do `subly-server keygen` in ra, base64url 32 byte>
#
# Giá trị được XOR với khoá ngẫu nhiên mỗi lần build để không nằm nguyên văn trong file chạy.
# Không có file env (hoặc thiếu giá trị) → sinh cấu hình rỗng: bản build đó không kiểm tra máy (bản dùng riêng).
$ErrorActionPreference = "Stop"

$windowsRoot = Split-Path $PSScriptRoot                 # ...\windows
$repoRoot = Split-Path $windowsRoot                     # gốc repo
$envPath = Join-Path $repoRoot "subly.local.env"
$outPath = Join-Path $windowsRoot "ScreenTranslator\Core\RuntimeConfigValues.cs"

$values = @{}
if (Test-Path $envPath) {
    foreach ($line in Get-Content $envPath) {
        $t = $line.Trim()
        if ($t -and -not $t.StartsWith("#") -and $t.Contains("=")) {
            $i = $t.IndexOf("=")
            $values[$t.Substring(0, $i).Trim()] = $t.Substring($i + 1).Trim()
        }
    }
}

$server = ""
if ($values.ContainsKey("SUBLY_SERVER")) { $server = $values["SUBLY_SERVER"].TrimEnd("/") }
$pubkey = ""
if ($values.ContainsKey("SUBLY_PUBKEY")) { $pubkey = $values["SUBLY_PUBKEY"] }

function Decode-B64Url([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return [byte[]]@() }
    $t = $s.Replace("-", "+").Replace("_", "/")
    switch ($t.Length % 4) { 2 { $t += "==" } 3 { $t += "=" } }
    return [Convert]::FromBase64String($t)
}

if ($server -or $pubkey) {
    if (-not $server.StartsWith("https://")) { throw "gen-runtime-config: SUBLY_SERVER phải bắt đầu bằng https://" }
    try { $raw = Decode-B64Url $pubkey } catch { $raw = [byte[]]@() }
    if ($raw.Length -ne 32) { throw "gen-runtime-config: SUBLY_PUBKEY không phải public key Ed25519 (base64url, 32 byte)" }
} else {
    $raw = [byte[]]@()
}

$key = New-Object byte[] 48
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$rng.GetBytes($key)
$rng.Dispose()

function Enc([byte[]]$data) {
    if ($data.Length -eq 0) { return "" }
    $parts = for ($i = 0; $i -lt $data.Length; $i++) { $data[$i] -bxor $key[$i % $key.Length] }
    return ($parts -join ", ")
}

$serverBytes = [System.Text.Encoding]::UTF8.GetBytes($server)
$src = @"
// Sinh tự động bởi Scripts/gen-runtime-config.ps1, không sửa tay, không commit.
namespace ScreenTranslator;

static class RuntimeConfigValues
{
    public static readonly byte[] k = { $(($key -join ", ")) };
    public static readonly byte[] a = { $(Enc $serverBytes) };
    public static readonly byte[] b = { $(Enc $raw) };
}
"@

New-Item -ItemType Directory -Force (Split-Path $outPath) | Out-Null
$old = if (Test-Path $outPath) { Get-Content -Raw $outPath } else { $null }
# Không có cấu hình và file đã rỗng → giữ nguyên để khỏi biên dịch lại. Có cấu hình → luôn ghi lại.
if ($server -or ($null -eq $old) -or ($old -notmatch "a = \{  \}")) {
    Set-Content -Path $outPath -Value $src -Encoding UTF8
}
if ($server) { Write-Host "gen-runtime-config: kiểm tra máy BẬT ($server)" } else { Write-Host "gen-runtime-config: kiểm tra máy TẮT (không có subly.local.env)" }
