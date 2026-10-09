using System;

namespace ScreenTranslator;

/// Cấu hình nhúng lúc build (Scripts/gen-runtime-config.ps1), lưu dạng đã làm rối.
/// Bản build không có cấu hình thì `Enabled == false`: app không kiểm tra máy (bản dùng riêng).
public static class RuntimeConfig
{
    public static bool Enabled => RuntimeConfigValues.a.Length > 0 && RuntimeConfigValues.b.Length == 32;

    public static string Endpoint => System.Text.Encoding.UTF8.GetString(Decode(RuntimeConfigValues.a)) + "/v1/session";
    public static byte[] Verifier => Decode(RuntimeConfigValues.b);

    static byte[] Decode(byte[] v)
    {
        var k = RuntimeConfigValues.k;
        var o = new byte[v.Length];
        for (int i = 0; i < v.Length; i++) o[i] = (byte)(v[i] ^ k[i % k.Length]);
        return o;
    }
}
