using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.RegularExpressions;

namespace ScreenTranslator;

/// Đóng gói + ký app Tizen (.wgt) không cần Tizen Studio: author-signature.xml và signature1.xml theo chuẩn
/// W3C XML Digital Signatures for Widgets, giống hệt `tizen package` (RSA-SHA512, SHA-512 từng file).
/// Port từ windows\tizen\sign-wgt.ps1 — dạng chuẩn hoá (c14n) đã đối chiếu bằng cách xác minh lại chữ ký do tizen CLI
/// tạo, và gói ký ra đã được TV Samsung thật chấp nhận.
public static class WgtSigner
{
    const string NS = "http://www.w3.org/2000/09/xmldsig#";
    static readonly UTF8Encoding Utf8 = new(false);

    /// Ký thư mục mã nguồn app `src` thành file `outWgt`.
    public static void Sign(string src, string outWgt, string authorP12, string authorPassword, string distributorP12, string distributorPassword)
    {
        src = Path.GetFullPath(src).TrimEnd('\\');
        var files = Directory.GetFiles(src, "*", SearchOption.AllDirectories)
            .Select(f => f[(src.Length + 1)..].Replace('\\', '/'))
            .Where(f => !Regex.IsMatch(f, @"^(author-signature|signature\d*)\.xml$") && !Regex.IsMatch(f, @"(^|/)\.") && !f.EndsWith(".wgt"))
            .OrderBy(f => f, StringComparer.Ordinal).ToList();
        if (!files.Contains("config.xml")) throw new InvalidOperationException("Không thấy config.xml của app TV");

        var (aKey, aChain) = LoadP12(authorP12, authorPassword);
        var (dKey, dChain) = LoadP12(distributorP12, distributorPassword);
        byte[] Read(string f) => File.ReadAllBytes(Path.Combine(src, f.Replace('/', '\\')));
        var author = Utf8.GetBytes(SignatureXml("AuthorSignature", "author", files.Select(f => (f, Read(f))), aKey, aChain));
        var dist = Utf8.GetBytes(SignatureXml("DistributorSignature", "distributor",
            new[] { ("author-signature.xml", author) }.Concat(files.Select(f => (f, Read(f)))), dKey, dChain));

        if (File.Exists(outWgt)) File.Delete(outWgt);
        using var zip = ZipFile.Open(outWgt, ZipArchiveMode.Create);
        void Add(string name, byte[] data) { using var s = zip.CreateEntry(name, CompressionLevel.Optimal).Open(); s.Write(data); }
        Add("author-signature.xml", author);
        Add("signature1.xml", dist);
        foreach (var f in files) Add(f, Read(f));
    }

    /// Khoá + chuỗi chứng chỉ (lá trước, CA sau) từ .p12.
    static (RSA key, List<X509Certificate2> chain) LoadP12(string path, string password)
    {
        var col = new X509Certificate2Collection();
        col.Import(path, password, X509KeyStorageFlags.Exportable | X509KeyStorageFlags.EphemeralKeySet);
        var leaf = col.FirstOrDefault(c => c.HasPrivateKey) ?? throw new InvalidOperationException($"Không có khoá bí mật trong {Path.GetFileName(path)}");
        var key = leaf.GetRSAPrivateKey() ?? throw new InvalidOperationException("Chứng chỉ không phải RSA");
        return (key, new[] { leaf }.Concat(col.Where(c => !c.HasPrivateKey)).ToList());
    }

    static string B64(byte[] b) => Regex.Replace(Convert.ToBase64String(b), "(.{76})(?=.)", "$1\n");

    static string SignatureXml(string id, string role, IEnumerable<(string uri, byte[] data)> refs, RSA key, List<X509Certificate2> chain)
    {
        var sb = new StringBuilder();
        foreach (var (uri, data) in refs)
        {
            var escaped = string.Join("/", uri.Split('/').Select(Uri.EscapeDataString));
            sb.Append($"<Reference URI=\"{escaped}\">\n<DigestMethod Algorithm=\"http://www.w3.org/2001/04/xmlenc#sha512\"></DigestMethod>\n<DigestValue>{B64(SHA512.HashData(data))}</DigestValue>\n</Reference>\n");
        }
        var obj = "<Object Id=\"prop\"><SignatureProperties xmlns:dsp=\"http://www.w3.org/2009/xmldsig-properties\">" +
            $"<SignatureProperty Id=\"profile\" Target=\"#{id}\"><dsp:Profile URI=\"http://www.w3.org/ns/widgets-digsig#profile\"></dsp:Profile></SignatureProperty>" +
            $"<SignatureProperty Id=\"role\" Target=\"#{id}\"><dsp:Role URI=\"http://www.w3.org/ns/widgets-digsig#role-{role}\"></dsp:Role></SignatureProperty>" +
            $"<SignatureProperty Id=\"identifier\" Target=\"#{id}\"><dsp:Identifier></dsp:Identifier></SignatureProperty></SignatureProperties></Object>";
        // Dạng chuẩn hoá của #prop: Object kế thừa xmlns mặc định của <Signature>.
        var propDigest = B64(SHA512.HashData(Utf8.GetBytes(obj.Replace("<Object Id=\"prop\">", $"<Object xmlns=\"{NS}\" Id=\"prop\">"))));
        var signedInfo = "<SignedInfo>\n<CanonicalizationMethod Algorithm=\"http://www.w3.org/2001/10/xml-exc-c14n#\"></CanonicalizationMethod>\n" +
            "<SignatureMethod Algorithm=\"http://www.w3.org/2001/04/xmldsig-more#rsa-sha512\"></SignatureMethod>\n" + sb +
            "<Reference URI=\"#prop\">\n<Transforms>\n<Transform Algorithm=\"http://www.w3.org/2006/12/xml-c14n11\"></Transform>\n</Transforms>\n" +
            $"<DigestMethod Algorithm=\"http://www.w3.org/2001/04/xmlenc#sha512\"></DigestMethod>\n<DigestValue>{propDigest}</DigestValue>\n</Reference>\n</SignedInfo>";
        // SignedInfo chuẩn hoá (exc-c14n): thêm xmlns mặc định lên chính nó.
        var c14n = Utf8.GetBytes(signedInfo.Replace("<SignedInfo>", $"<SignedInfo xmlns=\"{NS}\">"));
        var sig = B64(key.SignData(c14n, HashAlgorithmName.SHA512, RSASignaturePadding.Pkcs1));
        var certs = string.Concat(chain.Select(c => $"<X509Certificate>\n{B64(c.RawData)}\n</X509Certificate>\n"));
        return $"<Signature xmlns=\"{NS}\" Id=\"{id}\">\n{signedInfo}\n<SignatureValue>{sig}</SignatureValue>\n<KeyInfo>\n<X509Data>\n{certs}</X509Data>\n</KeyInfo>\n{obj}\n</Signature>";
    }
}
