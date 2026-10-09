using System;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;

namespace ScreenTranslator;

/// Vé do server ký: "v1|hash|pub|iat|exp" + chữ ký Ed25519, dạng base64url(payload).base64url(sig).
/// App giữ vé để chạy được khi tạm mất mạng. Chống chỉnh đồng hồ lùi bằng mốc thời gian lớn nhất từng thấy.
/// Tương đương Ticket.swift của bản macOS.
public sealed class Ticket
{
    public string Raw { get; }
    public string Hash { get; }
    public string Pub { get; }
    public DateTimeOffset Iat { get; }
    public DateTimeOffset Exp { get; }

    const string Name = "session";
    const string ClockKey = "runtimeHighWater";

    Ticket(string raw, string hash, string pub, DateTimeOffset iat, DateTimeOffset exp)
    { Raw = raw; Hash = hash; Pub = pub; Iat = iat; Exp = exp; }

    public static Ticket? Current()
    {
        var raw = SecretStore.Get(Name);
        return string.IsNullOrEmpty(raw) ? null : Parse(raw);
    }

    public static void Save(string raw) => SecretStore.Set(raw, Name);
    public static void Clear() => SecretStore.Set("", Name);

    public static Ticket? Parse(string raw)
    {
        var parts = raw.Split('.', 2);
        if (parts.Length != 2) return null;
        var payload = Base64Url.Decode(parts[0]);
        var sig = Base64Url.Decode(parts[1]);
        if (payload == null || sig == null) return null;

        try
        {
            var verifier = new Ed25519Signer();
            verifier.Init(false, new Ed25519PublicKeyParameters(RuntimeConfig.Verifier, 0));
            verifier.BlockUpdate(payload, 0, payload.Length);
            if (!verifier.VerifySignature(sig)) return null;
        }
        catch { return null; }

        var f = System.Text.Encoding.UTF8.GetString(payload).Split('|');
        if (f.Length != 5 || f[0] != "v1"
            || !long.TryParse(f[3], out var iat) || !long.TryParse(f[4], out var exp)) return null;
        return new Ticket(raw, f[1], f[2],
            DateTimeOffset.FromUnixTimeSeconds(iat), DateTimeOffset.FromUnixTimeSeconds(exp));
    }

    /// Vé thật sự dùng được: chữ ký đúng (đã kiểm ở Parse), đúng máy này, đúng khoá máy này, còn hạn,
    /// và đồng hồ không bị vặn lùi so với mốc đã thấy.
    public bool LooksValid()
    {
        if (Hash != HostIdentity.Hash || Pub != HostKey.PublicKeyB64) return false;
        var now = DateTimeOffset.UtcNow;
        if (now >= Exp) return false;
        // Mốc thời gian lớn nhất từng thấy. now lùi quá 10 phút → nghi vặn đồng hồ, coi vé không hợp lệ.
        var hw = AppSettings.shared.Get<double>(ClockKey, 0);
        var secs = now.ToUnixTimeSeconds();
        if (hw > 0 && secs < hw - 600) return false;
        if (secs > hw) AppSettings.shared.Set(ClockKey, (double)secs, ClockKey);
        return true;
    }
}
