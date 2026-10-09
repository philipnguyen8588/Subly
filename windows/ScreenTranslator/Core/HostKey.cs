using System;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;

namespace ScreenTranslator;

/// Cặp khoá Ed25519 riêng của máy, tạo lần đầu và lưu bằng SecretStore (mã hoá DPAPI). Dùng để ký yêu cầu gửi server:
/// server ghi nhận public key ở lần đầu (TOFU) nên không máy nào mạo nhận được mã phần cứng của máy khác.
/// Tương đương HostKey.swift của bản macOS.
public static class HostKey
{
    const string Name = "device-key";

    static readonly Ed25519PrivateKeyParameters Key = Load();

    static Ed25519PrivateKeyParameters Load()
    {
        var raw = SecretStore.Get(Name);
        if (!string.IsNullOrEmpty(raw) && Base64Url.Decode(raw) is byte[] data && data.Length == Ed25519PrivateKeyParameters.KeySize)
        {
            try { return new Ed25519PrivateKeyParameters(data, 0); } catch { /* tạo khoá mới */ }
        }
        var k = new Ed25519PrivateKeyParameters(new Org.BouncyCastle.Security.SecureRandom());
        SecretStore.Set(Base64Url.Encode(k.GetEncoded()), Name);
        return k;
    }

    public static string PublicKeyB64 => Base64Url.Encode(Key.GeneratePublicKey().GetEncoded());

    public static string Sign(string message)
    {
        try
        {
            var signer = new Ed25519Signer();
            signer.Init(true, Key);
            var bytes = System.Text.Encoding.UTF8.GetBytes(message);
            signer.BlockUpdate(bytes, 0, bytes.Length);
            return Base64Url.Encode(signer.GenerateSignature());
        }
        catch { return ""; }
    }
}
