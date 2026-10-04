using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using Microsoft.Win32;

namespace ScreenTranslator;

/// Thông tin máy PS5 đã đăng ký Remote Play. Lưu mã hoá DPAPI qua SecretStore (chứa khoá đăng ký).
public class PS5Host
{
    /// địa chỉ IP
    public string host { get; set; } = "";
    public string nickname { get; set; } = "";
    /// 6 byte
    public byte[] mac { get; set; } = new byte[6];
    /// 16 byte (ký tự hex, đệm \0)
    public byte[] registKey { get; set; } = new byte[16];
    /// 16 byte ("morning")
    public byte[] rpKey { get; set; } = new byte[16];
    /// 8 byte
    public byte[] accountID { get; set; } = new byte[8];
    public bool ps5 { get; set; } = true;

    public string macString => string.Join(":", mac.Select(b => b.ToString("x2")));
    public string hostID => string.Concat(mac.Select(b => b.ToString("X2")));
    public PS5Host Clone() => (PS5Host)MemberwiseClone();
}

public static class PS5Store
{
    const string name = "ps5host";

    public static PS5Host? Load()
    {
        var s = SecretStore.Get(name);
        if (string.IsNullOrEmpty(s)) return null;
        try { return JsonSerializer.Deserialize<PS5Host>(s); } catch { return null; }
    }

    public static void Save(PS5Host? h)
    {
        if (h == null) { SecretStore.Set("", name); return; }
        SecretStore.Set(JsonSerializer.Serialize(h), name);
    }

    /// PSN Account ID dạng base64 (8 byte) như chiaki-ng hiển thị.
    public static byte[]? AccountID(string b64)
    {
        try
        {
            var d = Convert.FromBase64String(b64.Trim());
            return d.Length == 8 ? d : null;
        }
        catch { return null; }
    }

    /// Đọc máy đã đăng ký trong chiaki-ng (QSettings trên Windows: registry HKCU\Software\Chiaki\Chiaki, hoặc file Chiaki.ini).
    public static PS5Host? ImportFromChiaki()
    {
        try { if (FromRegistry() is PS5Host h) return h; } catch (Exception e) { Log.Warn($"chiaki-ng registry: {e.Message}"); }
        try { if (FromIni() is PS5Host h) return h; } catch (Exception e) { Log.Warn($"chiaki-ng ini: {e.Message}"); }
        return null;
    }

    /// Giá trị QByteArray của QSettings: REG_BINARY, hoặc chuỗi "@ByteArray(...)" với các ký tự thoát \0 \xNN.
    static byte[]? Bytes(object? v)
    {
        if (v is byte[] b)
        {
            // Qt có thể lưu chuỗi UTF-16 trong REG_BINARY
            var s16 = Encoding.Unicode.GetString(b);
            if (s16.StartsWith("@ByteArray(")) return ParseByteArray(s16);
            return b;
        }
        if (v is string s) return ParseByteArray(s);
        return null;
    }

    static byte[]? ParseByteArray(string s)
    {
        s = s.Trim().Trim('"');
        if (!s.StartsWith("@ByteArray(")) return null;
        var inner = s["@ByteArray(".Length..];
        if (inner.EndsWith(")")) inner = inner[..^1];
        var outp = new System.Collections.Generic.List<byte>();
        for (int i = 0; i < inner.Length; i++)
        {
            char c = inner[i];
            if (c == '\\' && i + 1 < inner.Length)
            {
                char n = inner[i + 1];
                if (n == 'x')
                {
                    int j = i + 2; int val = 0; int digits = 0;
                    while (j < inner.Length && digits < 2 && Uri.IsHexDigit(inner[j])) { val = val * 16 + Convert.ToInt32(inner[j].ToString(), 16); j++; digits++; }
                    outp.Add((byte)val); i = j - 1; continue;
                }
                if (n == '0') { outp.Add(0); i++; continue; }
                if (n == '\\') { outp.Add((byte)'\\'); i++; continue; }
                if (n == '"') { outp.Add((byte)'"'); i++; continue; }
                if (n == 'n') { outp.Add(10); i++; continue; }
                if (n == 'r') { outp.Add(13); i++; continue; }
                if (n == 't') { outp.Add(9); i++; continue; }
            }
            outp.Add((byte)c);
        }
        return outp.ToArray();
    }

    static int Int(object? v, int def) => v switch
    {
        int i => i,
        string s when int.TryParse(s.Trim('"'), out var n) => n,
        _ => def,
    };

    static PS5Host? FromRegistry()
    {
        using var root = Registry.CurrentUser.OpenSubKey(@"Software\Chiaki\Chiaki");
        if (root == null) return null;
        using var hosts = root.OpenSubKey("registered_hosts");
        if (hosts == null) return null;
        int count = Int(hosts.GetValue("size"), 0);
        string accountB64 = "";
        using (var st = root.OpenSubKey("settings")) accountB64 = (st?.GetValue("psn_account_id") as string ?? "").Trim('"');
        for (int i = 1; i <= Math.Max(count, 1); i++)
        {
            using var k = hosts.OpenSubKey(i.ToString());
            if (k == null) continue;
            var h = Make(Bytes(k.GetValue("rp_regist_key")), Bytes(k.GetValue("rp_key")), Bytes(k.GetValue("server_mac")),
                         Int(k.GetValue("target"), 1_000_100), k.GetValue("server_nickname") as string, accountB64);
            if (h != null) return h;
        }
        return null;
    }

    static PS5Host? FromIni()
    {
        var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Chiaki");
        var file = new[] { "Chiaki.ini", "chiaki.ini" }.Select(f => Path.Combine(dir, f)).FirstOrDefault(File.Exists);
        if (file == null) return null;
        string section = "";
        var values = new System.Collections.Generic.Dictionary<string, string>();
        foreach (var raw in File.ReadAllLines(file))
        {
            var line = raw.Trim();
            if (line.StartsWith("[") && line.EndsWith("]")) { section = line[1..^1]; continue; }
            int eq = line.IndexOf('=');
            if (eq <= 0) continue;
            values[$"{section}/{line[..eq].Trim()}".Replace('\\', '/')] = line[(eq + 1)..].Trim();
        }
        string V(string k) => values.TryGetValue(k, out var v) ? v : "";
        int count = Int(V("registered_hosts/size"), 0);
        var accountB64 = V("settings/psn_account_id").Trim('"');
        for (int i = 1; i <= count; i++)
        {
            var p = $"registered_hosts/{i}/";
            var h = Make(ParseByteArray(V(p + "rp_regist_key")), ParseByteArray(V(p + "rp_key")), ParseByteArray(V(p + "server_mac")),
                         Int(V(p + "target"), 1_000_100), V(p + "server_nickname"), accountB64);
            if (h != null) return h;
        }
        return null;
    }

    static PS5Host? Make(byte[]? rk, byte[]? key, byte[]? mac, int target, string? nick, string accountB64)
    {
        if (rk == null || key == null || mac == null || rk.Length != 16 || key.Length != 16 || mac.Length != 6) return null;
        return new PS5Host
        {
            host = "", nickname = string.IsNullOrEmpty(nick) ? "PS5" : nick.Trim('"'), mac = mac, registKey = rk, rpKey = key,
            accountID = AccountID(accountB64) ?? new byte[8], ps5 = target >= 1_000_000,
        };
    }
}
