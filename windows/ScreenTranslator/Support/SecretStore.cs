using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace ScreenTranslator;

/// Lưu bí mật (API key, khoá PS5) trong file `<name>.secret` ở %APPDATA%\ScreenTranslator,
/// mã hoá bằng DPAPI (chỉ tài khoản Windows hiện tại giải mã được).
public static class SecretStore
{
    static string PathOf(string name) => AppPaths.File($"{name}.secret");

    public static string? Get(string name)
    {
        try
        {
            var p = PathOf(name);
            if (!File.Exists(p)) return null;
            var data = File.ReadAllBytes(p);
            byte[] plain;
            try { plain = ProtectedData.Unprotect(data, null, DataProtectionScope.CurrentUser); }
            catch (CryptographicException) { plain = data; } // file chép tay ở dạng chữ thường
            return Encoding.UTF8.GetString(plain).Trim();
        }
        catch (Exception e)
        {
            Log.Error($"SecretStore read failed: {e.Message}");
            return null;
        }
    }

    public static bool Set(string value, string name)
    {
        var p = PathOf(name);
        try
        {
            if (string.IsNullOrEmpty(value))
            {
                if (File.Exists(p)) File.Delete(p);
                return true;
            }
            var enc = ProtectedData.Protect(Encoding.UTF8.GetBytes(value), null, DataProtectionScope.CurrentUser);
            var tmp = p + ".tmp";
            File.WriteAllBytes(tmp, enc);
            File.Move(tmp, p, true);
            return true;
        }
        catch (Exception e)
        {
            Log.Error($"SecretStore write failed: {e.Message}");
            return false;
        }
    }
}
