using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;

namespace ScreenTranslator;

public static class TextUtils
{
    static readonly Regex Ws = new(@"\s+", RegexOptions.Compiled);
    static readonly Regex SingleLetterSpeaker = new(@"^[A-Z][:：]$", RegexOptions.Compiled);
    static readonly Regex SpeakerPrefix = new(@"^[^:：]{1,40}[:：]\s+", RegexOptions.Compiled);

    /// Gộp khoảng trắng, trim, bỏ ký tự điều khiển.
    public static string Normalize(string s) => Ws.Replace(s, " ").Trim();

    static HashSet<string> Words(string s)
    {
        var set = new HashSet<string>();
        var cur = new System.Text.StringBuilder();
        foreach (var ch in s.ToLowerInvariant())
        {
            if (char.IsLetter(ch) || char.IsDigit(ch) || ch == '\'') cur.Append(ch);
            else if (cur.Length > 0) { set.Add(cur.ToString()); cur.Clear(); }
        }
        if (cur.Length > 0) set.Add(cur.ToString());
        return set;
    }

    /// Độ giống theo từ (hệ số Dice trên tập từ, bỏ dấu câu, không phân biệt hoa thường). 0...1.
    public static double WordSimilarity(string a, string b)
    {
        var x = Words(a); var y = Words(b);
        if (x.Count == 0 && y.Count == 0) return 1;
        if (x.Count == 0 || y.Count == 0) return 0;
        int inter = x.Count(y.Contains);
        return 2.0 * inter / (x.Count + y.Count);
    }

    /// Hai kết quả OCR có phải cùng một câu không: lấy max(giống theo ký tự, giống theo từ).
    public static bool SameLine(string a, string b, double threshold)
    {
        if (a == b) return true;
        return Math.Max(Similarity(a, b), WordSimilarity(a, b)) >= threshold;
    }

    /// Bỏ token OCR vô nghĩa (trộn chữ/số kiểu "Ư0", "09000000V", "l|", ...). Giữ số thuần, giờ, %, mã ngắn như PS5/1st/4K.
    public static string StripJunkTokens(string s)
    {
        var tokens = s.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var kept = new List<string>();
        for (int i = 0; i < tokens.Length; i++)
        {
            var t = tokens[i];
            // "V:" ở đầu dòng là tên người nói một chữ cái (V trong Cyberpunk 2077), không phải rác.
            if (i == 0 && tokens.Length > 1 && SingleLetterSpeaker.IsMatch(t)) { kept.Add(t); continue; }
            if (!IsJunk(t)) kept.Add(t);
        }
        return string.Join(" ", kept);
    }

    static bool IsPunctOrSymbol(char c) => char.IsPunctuation(c) || char.IsSymbol(c);

    static bool IsJunk(string raw)
    {
        int st = 0, en = raw.Length;
        while (st < en && IsPunctOrSymbol(raw[st])) st++;
        while (en > st && IsPunctOrSymbol(raw[en - 1])) en--;
        var t = raw[st..en];
        if (t.Length == 0) return raw.Length > 2;               // chuỗi toàn ký hiệu dài → rác
        var letters = t.Where(char.IsLetter).ToList();
        int digits = t.Count(char.IsDigit);
        int others = t.Length - letters.Count - digits;
        if (letters.Count == 0)
        {
            // số thuần: 3, 2024, 10:30, 50%, 1,000 → giữ nếu không quá dài
            return digits > 6 || others > 2;
        }
        if (digits == 0)
        {
            // chữ thuần: bỏ nếu 1 ký tự lạ (trừ a/A/I) hoặc có nhiều ký tự không phải chữ xen giữa
            if (letters.Count == 1) return !(t == "a" || t == "A" || t == "I" || t == "i");
            return others > 1 && letters.Count <= 3;
        }
        // trộn chữ + số
        if (letters.Any(c => c > 127)) return true;             // "Ư0", "đ9"
        if (digits >= 3) return true;                           // "09000000V", "a1b2c3"
        if (letters.Count <= 2 && digits <= 2) return false;    // PS5, 4K, 1st, 2nd, F1, A4 → giữ
        return digits > letters.Count;
    }

    /// Bỏ "Tên người nói: " ở đầu câu (Young Woman:, Người phụ nữ trẻ:, KRATOS:).
    public static string StripSpeaker(string s)
    {
        var m = SpeakerPrefix.Match(s);
        if (!m.Success) return s;
        var rest = s[(m.Index + m.Length)..];
        return rest.Length == 0 ? s : rest;
    }

    public static int LetterCount(string s) => s.Count(char.IsLetter);

    /// 0...1, 1 = giống hệt. Levenshtein trên chuỗi lowercase.
    public static double Similarity(string a, string b)
    {
        var x = a.ToLowerInvariant(); var y = b.ToLowerInvariant();
        if (x.Length == 0 && y.Length == 0) return 1;
        if (x.Length == 0 || y.Length == 0) return 0;
        var prev = new int[y.Length + 1];
        var cur = new int[y.Length + 1];
        for (int j = 0; j <= y.Length; j++) prev[j] = j;
        for (int i = 1; i <= x.Length; i++)
        {
            cur[0] = i;
            for (int j = 1; j <= y.Length; j++)
            {
                int cost = x[i - 1] == y[j - 1] ? 0 : 1;
                cur[j] = Math.Min(Math.Min(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + cost);
            }
            (prev, cur) = (cur, prev);
        }
        int dist = prev[y.Length];
        return 1 - (double)dist / Math.Max(x.Length, y.Length);
    }

    public static int WordCount(string s) => s.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;
}
