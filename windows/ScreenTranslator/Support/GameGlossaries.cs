using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace ScreenTranslator;

/// Thuật ngữ game đóng kèm app (thư mục `glossaries/` cạnh exe). Dùng để tạo sẵn profile cho các game
/// thông dụng ở lần chạy đầu. Mỗi CSV: dòng `#!game=Tên game` (tuỳ chọn), các dòng `thuật ngữ,bản dịch`
/// (bản dịch trống = giữ nguyên), dòng `#` là chú thích. Port từ GameGlossaries.swift của bản macOS.
public static class GameGlossaries
{
    public sealed class Game
    {
        public string name = "";
        public List<GlossaryEntry> entries = new();
    }

    /// Thư mục glossaries cạnh exe (bản single-file: thư mục giải nén tạm = AppContext.BaseDirectory).
    static string Dir => Path.Combine(AppContext.BaseDirectory, "glossaries");

    public static List<Game> Bundled()
    {
        try
        {
            if (!Directory.Exists(Dir)) return new();
            return Directory.GetFiles(Dir, "*.csv")
                .OrderBy(p => Path.GetFileName(p), StringComparer.OrdinalIgnoreCase)
                .Select(Parse)
                .Where(g => g != null)
                .Select(g => g!)
                .ToList();
        }
        catch (Exception e) { Log.Warn($"Đọc glossaries lỗi: {e.Message}"); return new(); }
    }

    static Game? Parse(string path)
    {
        string text;
        try { text = File.ReadAllText(path); } catch { return null; }
        var name = Path.GetFileNameWithoutExtension(path);
        var entries = new List<GlossaryEntry>();
        var seen = new HashSet<string>();
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0) continue;
            if (line.StartsWith("#!game="))
            {
                name = line.Substring("#!game=".Length).Trim();
                continue;
            }
            if (line.StartsWith("#")) continue;
            var idx = line.IndexOf(',');
            var term = (idx < 0 ? line : line.Substring(0, idx)).Trim();
            var tr = idx < 0 ? "" : line.Substring(idx + 1).Trim();
            if (term.Length == 0 || term.Equals("term", StringComparison.OrdinalIgnoreCase)) continue;
            if (!seen.Add(term.ToLowerInvariant())) continue;
            entries.Add(new GlossaryEntry { term = term, translation = tr, keepAsIs = tr.Length == 0 });
        }
        if (entries.Count == 0) return null;
        return new Game { name = name, entries = entries };
    }
}
