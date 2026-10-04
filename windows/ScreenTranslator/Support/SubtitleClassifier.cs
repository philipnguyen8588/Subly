using System;
using System.Collections.Generic;
using System.Linq;

namespace ScreenTranslator;

/// Phân biệt phụ đề với chữ giao diện (menu, cài đặt, danh sách) bằng heuristic trên văn bản + bố cục OCR.
/// Chữ giao diện: nhiều từ Hoa Đầu Chữ, nhiều mảnh cùng hàng (cột), nhiều hàng, cỡ chữ lẫn, nhiều số/nhãn, cụm lặp.
/// Phụ đề: câu đầy đủ chữ thường, 1–3 dòng, cỡ chữ đều, có dấu câu.
public static class SubtitleClassifier
{
    public const int threshold = 3;

    public record Verdict(int score, List<string> reasons)
    {
        public bool isUI => score >= threshold;
    }

    public static Verdict Classify(OcrResult r) => Classify(r.text, r.rows, r.maxPerRow, r.heightRatio);

    static bool IsPunctOrSymbol(char c) => char.IsPunctuation(c) || char.IsSymbol(c);
    static string TrimPunct(string s)
    {
        int st = 0, en = s.Length;
        while (st < en && IsPunctOrSymbol(s[st])) st++;
        while (en > st && IsPunctOrSymbol(s[en - 1])) en--;
        return s[st..en];
    }

    public static Verdict Classify(string text, int rows = 1, int maxPerRow = 1, double heightRatio = 1)
    {
        int score = 0;
        var reasons = new List<string>();
        var tokens = text.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (tokens.Length == 0) return new Verdict(0, new());

        // Hoa Đầu Chữ (bỏ từ đầu câu, bỏ qua nếu toàn chữ hoa).
        var letters = text.Where(char.IsLetter).ToList();
        int upper = letters.Count(char.IsUpper);
        bool allCaps = letters.Count > 0 && (double)upper / letters.Count >= 0.9;
        if (!allCaps)
        {
            int considered = 0, capitalized = 0;
            bool sentenceStart = true;
            foreach (var tok in tokens)
            {
                var word = TrimPunct(tok);
                var wl = word.Where(char.IsLetter).ToList();
                bool skip = wl.Count < 2 || sentenceStart;
                if (!skip)
                {
                    considered++;
                    if (char.IsUpper(wl[0])) capitalized++;
                }
                char last = tok.Length > 0 ? tok[^1] : ' ';
                sentenceStart = ".!?…:".IndexOf(last) >= 0 || tok.EndsWith("...");
            }
            if (considered >= 3)
            {
                double ratio = (double)capitalized / considered;
                if (ratio >= 0.5) { score += 2; reasons.Add($"hoa đầu chữ {(int)(ratio * 100)}%"); }
                else if (ratio >= 0.35) { score += 1; reasons.Add($"hoa đầu chữ {(int)(ratio * 100)}%"); }
            }
        }

        // Không có dấu câu nào.
        if (text.IndexOfAny(".,!?…;'\"".ToCharArray()) < 0) { score += 1; reasons.Add("không dấu câu"); }

        // Bố cục.
        if (maxPerRow >= 3) { score += 2; reasons.Add($"cột ({maxPerRow} mảnh/hàng)"); }
        if (rows >= 4) { score += 1; reasons.Add($"{rows} hàng"); }
        if (heightRatio >= 1.6) { score += 1; reasons.Add($"cỡ chữ lẫn ×{heightRatio:0.0}"); }

        // Số / đơn vị / nhãn.
        int numeric = tokens.Count(IsNumericToken);
        if (tokens.Length >= 4 && (double)numeric / tokens.Length >= 0.25) { score += 1; reasons.Add($"nhiều số ({numeric}/{tokens.Length})"); }
        int colons = text.Count(c => c == ':' || c == '：');
        if (colons >= 2) { score += 1; reasons.Add($"{colons} dấu hai chấm"); }

        // Cụm 3 từ lặp ≥ 3 lần.
        var words = new List<string>();
        var cur = new System.Text.StringBuilder();
        foreach (var c in text.ToLowerInvariant())
        {
            if (char.IsLetterOrDigit(c)) cur.Append(c);
            else if (cur.Length > 0) { words.Add(cur.ToString()); cur.Clear(); }
        }
        if (cur.Length > 0) words.Add(cur.ToString());
        if (words.Count >= 9)
        {
            var counts = new Dictionary<string, int>();
            for (int i = 0; i < words.Count - 2; i++)
            {
                var key = words[i] + " " + words[i + 1] + " " + words[i + 2];
                counts[key] = counts.GetValueOrDefault(key) + 1;
            }
            var top = counts.OrderByDescending(kv => kv.Value).First();
            if (top.Value >= 3) { score += 1; reasons.Add($"lặp “{top.Key}” ×{top.Value}"); }
        }

        if (tokens.Length > 45) { score += 1; reasons.Add($"{tokens.Length} từ"); }
        return new Verdict(score, reasons);
    }

    /// 0.3, 20K, 1.2K, MB, GB, 50%, +, -, 10:30, v1.2
    static bool IsNumericToken(string raw)
    {
        var t = TrimPunct(raw);
        if (t.Length == 0) return true;
        int digits = t.Count(char.IsDigit);
        if (digits > 0 && digits >= t.Length - 2) return true;
        return new[] { "MB", "GB", "KB", "TB", "K", "M", "FPS", "MS", "HZ", "DB" }.Contains(t.ToUpperInvariant());
    }
}
