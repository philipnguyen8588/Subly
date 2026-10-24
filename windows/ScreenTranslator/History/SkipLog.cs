using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading.Tasks;

namespace ScreenTranslator;

/// Loại chữ bị bỏ qua (tên giữ giống bản Mac để file skipped.jsonl đọc chung được).
[JsonConverter(typeof(JsonStringEnumConverter))]
public enum SkipKind { ui, stray, interjection, simple, junk, faint }

public static class SkipKindInfo
{
    public static readonly SkipKind[] All = (SkipKind[])Enum.GetValues(typeof(SkipKind));

    public static string Title(this SkipKind k) => k switch
    {
        SkipKind.ui => "Menu",
        SkipKind.stray => "Mẩu lạc",
        SkipKind.interjection => "Cảm thán",
        SkipKind.simple => "Đơn giản",
        SkipKind.junk => "Vô nghĩa",
        _ => "Chữ mờ",
    };

    public static string Help(this SkipKind k) => k switch
    {
        SkipKind.ui => "Chữ giao diện: menu, cài đặt, thanh nút bấm, danh sách",
        SkipKind.stray => "Mẩu chữ 1–2 từ đứng một mình, không dấu câu (chữ trong cảnh game, nút bấm)",
        SkipKind.interjection => "Câu chỉ có từ cảm thán (hmm, haha, huh…)",
        SkipKind.simple => "Câu tối đa 5 từ, toàn từ cơ bản hoặc tên nhân vật, người chơi tự hiểu",
        SkipKind.junk => "Câu ngắn không có từ tiếng Anh thật (OCR đọc nhầm)",
        _ => "Chữ có độ tương phản thấp (đồng hồ tốc độ, chữ chìm trong cảnh)",
    };
}

public sealed class SkipEntry
{
    public string id { get; set; } = Guid.NewGuid().ToString().ToUpperInvariant();
    /// Giây kể từ 1970 (giống bản Mac).
    public double time { get; set; }
    public string profile { get; set; } = "";
    public string region { get; set; } = "";
    public SkipKind kind { get; set; }
    public string reason { get; set; } = "";
    public string text { get; set; } = "";

    [JsonIgnore] public DateTime Time => DateTimeOffset.FromUnixTimeMilliseconds((long)(time * 1000)).LocalDateTime;
}

/// Nhật ký chữ OCR đọc được nhưng bị bỏ qua (menu, mẩu lạc, cảm thán, chữ mờ…), để xem lại trong tab "Bị bỏ qua"
/// và chỉnh bộ lọc nếu nó bỏ nhầm câu thoại. Lưu ở skipped.jsonl (mỗi dòng một mục), chỉ giữ `MaxEntries` mục mới nhất.
/// `entries` và `Changed` chỉ dùng trên luồng UI.
public sealed class SkipLog
{
    public static readonly SkipLog shared = new();
    public const int MaxEntries = 3000;

    public List<SkipEntry> entries { get; } = new();
    public event Action? Changed;

    readonly string path = AppPaths.File("skipped.jsonl");
    readonly object io = new();
    static readonly JsonSerializerOptions Opts = new() { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    SkipLog()
    {
        try
        {
            if (!File.Exists(path)) return;
            foreach (var line in File.ReadLines(path))
            {
                if (line.Length == 0) continue;
                try { if (JsonSerializer.Deserialize<SkipEntry>(line, Opts) is { } e) entries.Add(e); } catch { }
            }
            if (entries.Count > MaxEntries) { entries.RemoveRange(0, entries.Count - MaxEntries); Rewrite(); }
        }
        catch (Exception e) { Log.Warn($"SkipLog: {e.Message}"); }
    }

    /// Gọi được từ luồng OCR.
    public static void Add(SkipKind kind, string text, string region, string profile, string reason = "")
    {
        var e = new SkipEntry { time = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0, profile = profile, region = region, kind = kind, reason = reason, text = text };
        App.RunOnUI(() => shared.Append(e));
    }

    void Append(SkipEntry e)
    {
        entries.Add(e);
        // Ghi nối tiếp; vượt quá giới hạn một khoảng thì cắt bớt và ghi lại cả file.
        if (entries.Count > MaxEntries + 300)
        {
            entries.RemoveRange(0, entries.Count - MaxEntries);
            Rewrite();
        }
        else
        {
            var line = JsonSerializer.Serialize(e, Opts) + "\n";
            Task.Run(() => { lock (io) { try { File.AppendAllText(path, line, new UTF8Encoding(false)); } catch { } } });
        }
        Changed?.Invoke();
    }

    /// Xoá các mục của một game.
    public void Clear(string profile)
    {
        entries.RemoveAll(e => e.profile == profile);
        Rewrite();
        Changed?.Invoke();
    }

    void Rewrite()
    {
        var data = string.Concat(entries.Select(e => JsonSerializer.Serialize(e, Opts) + "\n"));
        Task.Run(() =>
        {
            lock (io)
            {
                try
                {
                    var tmp = path + ".tmp";
                    File.WriteAllText(tmp, data, new UTF8Encoding(false));
                    File.Move(tmp, path, true);
                }
                catch { }
            }
        });
    }
}
