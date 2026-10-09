using System;

namespace ScreenTranslator;

/// base64url không đệm (khớp base64.RawURLEncoding của server và `base64URL` của bản macOS).
public static class Base64Url
{
    public static string Encode(byte[] data) =>
        Convert.ToBase64String(data).Replace('+', '-').Replace('/', '_').TrimEnd('=');

    public static byte[]? Decode(string s)
    {
        if (string.IsNullOrEmpty(s)) return null;
        var t = s.Replace('-', '+').Replace('_', '/');
        switch (t.Length % 4) { case 2: t += "=="; break; case 3: t += "="; break; }
        try { return Convert.FromBase64String(t); } catch { return null; }
    }
}
