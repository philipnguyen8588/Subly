using System;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32;

namespace ScreenTranslator;

/// Thông tin nhận dạng máy: mã phần cứng (băm) và vài thông tin để chủ app nhận ra máy trên trang quản trị.
/// Tương đương HostIdentity.swift của bản macOS (IOPlatformUUID + serial → đây dùng MachineGuid + UUID máy).
public static class HostIdentity
{
    /// SHA-256 (hex thường, 64 ký tự) của mã máy. Ổn định qua khởi động lại và cài lại app;
    /// đổi khi cài lại Windows (giống bản macOS: lúc đó máy hiện lại ở mục Chờ duyệt).
    public static readonly string Hash = ComputeHash();

    static string ComputeHash()
    {
        var raw = "subly-v1|win|" + MachineGuid() + "|" + SystemUuid();
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(raw));
        var sb = new StringBuilder(bytes.Length * 2);
        foreach (var b in bytes) sb.Append(b.ToString("x2"));
        return sb.ToString();
    }

    /// GUID gán khi cài Windows (HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid). Không đổi khi đổi tên máy.
    static string MachineGuid() => ReadRegistry(RegistryHive.LocalMachine,
        @"SOFTWARE\Microsoft\Cryptography", "MachineGuid");

    /// UUID phần cứng của máy (SMBIOS), đọc không cần quyền admin.
    static string SystemUuid() => ReadRegistry(RegistryHive.LocalMachine,
        @"SYSTEM\HardwareConfig", "LastConfig");

    static string ReadRegistry(RegistryHive hive, string path, string name)
    {
        try
        {
            using var baseKey = RegistryKey.OpenBaseKey(hive, RegistryView.Registry64);
            using var key = baseKey.OpenSubKey(path);
            return key?.GetValue(name) as string ?? "";
        }
        catch { return ""; }
    }

    /// Tên máy.
    public static string Name => Environment.MachineName;
    public static string User => Environment.UserName;

    /// Hãng + model máy, ví dụ "ASUS ROG Strix G16".
    public static string Model
    {
        get
        {
            var mfr = ReadRegistry(RegistryHive.LocalMachine, @"HARDWARE\DESCRIPTION\System\BIOS", "SystemManufacturer");
            var product = ReadRegistry(RegistryHive.LocalMachine, @"HARDWARE\DESCRIPTION\System\BIOS", "SystemProductName");
            return string.Join(" ", new[] { mfr, product }.Where(s => !string.IsNullOrWhiteSpace(s))).Trim();
        }
    }

    public static string OsVersion => RuntimeInformation.OSDescription;
}
