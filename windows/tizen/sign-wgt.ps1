# Đóng gói + ký app Tizen (.wgt) không cần Tizen Studio: tạo author-signature.xml và signature1.xml theo chuẩn
# W3C XML Digital Signatures for Widgets, giống hệt định dạng `tizen package` tạo ra (RSA-SHA512, SHA-512 từng file).
# Cách dựng dạng chuẩn hoá đã đối chiếu bằng cách xác minh lại chữ ký do tizen CLI tạo.
#
#   .\sign-wgt.ps1 -Src .\SubtitleTV -Out .\SubtitleTV.wgt -Author author.p12 -Distributor distributor.p12 -Password <pass>
param(
    [Parameter(Mandatory = $true)][string]$Src,
    [Parameter(Mandatory = $true)][string]$Out,
    [Parameter(Mandatory = $true)][string]$Author,
    [Parameter(Mandatory = $true)][string]$Distributor,
    [Parameter(Mandatory = $true)][string]$Password,
    [string]$DistributorPassword
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
if (-not $DistributorPassword) { $DistributorPassword = $Password }
$NS = 'http://www.w3.org/2000/09/xmldsig#'
$utf8 = New-Object Text.UTF8Encoding($false)

function B64([byte[]]$b) { ([Convert]::ToBase64String($b) -replace '(.{76})(?=.)', "`$1`n") }
function Sha512([byte[]]$b) { [Security.Cryptography.SHA512]::Create().ComputeHash($b) }

# Chứng chỉ + khoá từ .p12: [khoá, chuỗi chứng chỉ (lá trước, CA sau)].
function Load-P12([string]$path, [string]$pw) {
    $col = New-Object Security.Cryptography.X509Certificates.X509Certificate2Collection
    $col.Import((Resolve-Path $path).Path, $pw, [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
    $leaf = $col | Where-Object { $_.HasPrivateKey } | Select-Object -First 1
    if (-not $leaf) { throw "Không có khoá bí mật trong $path" }
    $key = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($leaf)
    # Khoá nạp vào CSP cũ không ký được SHA-512 → chép sang RSACng.
    if ($key -is [Security.Cryptography.RSACryptoServiceProvider]) {
        $cng = New-Object Security.Cryptography.RSACng
        $cng.ImportParameters($key.ExportParameters($true))
        $key = $cng
    }
    , @($key, (@($leaf) + @($col | Where-Object { -not $_.HasPrivateKey })))
}

function Signature-Xml([string]$id, [string]$role, [string[]]$refs, [string]$root, $key, $chain) {
    $refXml = ''
    foreach ($r in $refs) {
        $uri = ($r -split '/' | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
        $digest = B64 (Sha512 ([IO.File]::ReadAllBytes((Join-Path $root $r))))
        $refXml += "<Reference URI=`"$uri`">`n<DigestMethod Algorithm=`"http://www.w3.org/2001/04/xmlenc#sha512`"></DigestMethod>`n<DigestValue>$digest</DigestValue>`n</Reference>`n"
    }
    $obj = "<Object Id=`"prop`"><SignatureProperties xmlns:dsp=`"http://www.w3.org/2009/xmldsig-properties`">" +
        "<SignatureProperty Id=`"profile`" Target=`"#$id`"><dsp:Profile URI=`"http://www.w3.org/ns/widgets-digsig#profile`"></dsp:Profile></SignatureProperty>" +
        "<SignatureProperty Id=`"role`" Target=`"#$id`"><dsp:Role URI=`"http://www.w3.org/ns/widgets-digsig#role-$role`"></dsp:Role></SignatureProperty>" +
        "<SignatureProperty Id=`"identifier`" Target=`"#$id`"><dsp:Identifier></dsp:Identifier></SignatureProperty></SignatureProperties></Object>"
    # Dạng chuẩn hoá của #prop: Object kế thừa xmlns mặc định của <Signature>.
    $propDigest = B64 (Sha512 ($utf8.GetBytes($obj.Replace('<Object Id="prop">', "<Object xmlns=`"$NS`" Id=`"prop`">"))))
    $signedInfo = "<SignedInfo>`n<CanonicalizationMethod Algorithm=`"http://www.w3.org/2001/10/xml-exc-c14n#`"></CanonicalizationMethod>`n" +
        "<SignatureMethod Algorithm=`"http://www.w3.org/2001/04/xmldsig-more#rsa-sha512`"></SignatureMethod>`n" + $refXml +
        "<Reference URI=`"#prop`">`n<Transforms>`n<Transform Algorithm=`"http://www.w3.org/2006/12/xml-c14n11`"></Transform>`n</Transforms>`n" +
        "<DigestMethod Algorithm=`"http://www.w3.org/2001/04/xmlenc#sha512`"></DigestMethod>`n<DigestValue>$propDigest</DigestValue>`n</Reference>`n</SignedInfo>"
    # SignedInfo chuẩn hoá (exc-c14n): thêm xmlns mặc định lên chính nó.
    $c14n = $utf8.GetBytes($signedInfo.Replace('<SignedInfo>', "<SignedInfo xmlns=`"$NS`">"))
    $sig = B64 ($key.SignData($c14n, [Security.Cryptography.HashAlgorithmName]::SHA512, [Security.Cryptography.RSASignaturePadding]::Pkcs1))
    $certs = ($chain | ForEach-Object { "<X509Certificate>`n$(B64 $_.RawData)`n</X509Certificate>`n" }) -join ''
    "<Signature xmlns=`"$NS`" Id=`"$id`">`n$signedInfo`n<SignatureValue>$sig</SignatureValue>`n<KeyInfo>`n<X509Data>`n$certs</X509Data>`n</KeyInfo>`n$obj`n</Signature>"
}

# Chép mã nguồn sang thư mục tạm (bỏ chữ ký cũ, file rác của tizen CLI).
$stage = Join-Path ([IO.Path]::GetTempPath()) ("wgt-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $stage | Out-Null
try {
    $srcFull = (Resolve-Path $Src).Path.TrimEnd('\')
    $files = Get-ChildItem $srcFull -Recurse -File | ForEach-Object { $_.FullName.Substring($srcFull.Length + 1).Replace('\', '/') } |
        Where-Object { $_ -notmatch '^(author-signature|signature\d*)\.xml$' -and $_ -notmatch '(^|/)\.(manifest\.tmp|delta\.lst|project|tproject|settings)' -and $_ -notmatch '\.wgt$' }
    $files = [string[]]($files | Sort-Object { $_ } -CaseSensitive)
    if (-not ($files -contains 'config.xml')) { throw "Không thấy config.xml trong $Src" }
    foreach ($f in $files) {
        $dst = Join-Path $stage $f
        New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
        Copy-Item (Join-Path $srcFull $f) $dst
    }

    $a = Load-P12 $Author $Password
    $d = Load-P12 $Distributor $DistributorPassword
    [IO.File]::WriteAllText((Join-Path $stage 'author-signature.xml'), (Signature-Xml 'AuthorSignature' 'author' $files $stage $a[0] $a[1]), $utf8)
    [IO.File]::WriteAllText((Join-Path $stage 'signature1.xml'), (Signature-Xml 'DistributorSignature' 'distributor' (@('author-signature.xml') + $files) $stage $d[0] $d[1]), $utf8)

    if (Test-Path $Out) { Remove-Item $Out -Force }
    $zip = [IO.Compression.ZipFile]::Open($Out, 'Create')
    try {
        foreach ($f in @('author-signature.xml', 'signature1.xml') + $files) {
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $stage $f), $f, 'Optimal')
        }
    } finally { $zip.Dispose() }
    Write-Host "Đã ký: $Out ($($files.Count) file)"
} finally { Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue }
