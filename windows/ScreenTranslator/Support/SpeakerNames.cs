using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;

namespace ScreenTranslator;

/// Học và nhận diện tên người nói ở đầu câu phụ đề ("Atreus: ...").
public static class SpeakerNames
{
    /// Tên 1–5 từ Viết Hoa; giữa tên được có từ nối viết thường ("Guardian of the Flame", "Dion Lesage", "Geralt of Rivia").
    static readonly Regex LearnPattern = new(@"^([A-Z][A-Za-z'\-]{0,20}(?: (?:(?:of|the|de|von|van|da|du|la|le|del|al|el) )*[A-Z][A-Za-z'\-]{1,20}){0,4}):\s+\S", RegexOptions.Compiled);
    static readonly Regex StdPrefix = new(@"^[^:：]{1,40}[:：]\s+", RegexOptions.Compiled);
    static readonly Regex TrailingColon = new(@"[:：]\s*$", RegexOptions.Compiled);
    static readonly Regex LeadingPunct = new(@"^[,.;:\-–— ]+", RegexOptions.Compiled);
    static readonly HashSet<string> Blacklist = new() { "Note", "Warning", "Tip", "Hint", "Objective", "Quest", "Mission", "Chapter", "Press", "Error", "Info" };

    /// Trả về tên nếu câu có dạng "Tên: nội dung" (tên 1–5 từ, viết hoa chữ đầu, cho phép từ nối "of/the"; tên một chữ cái như "V" cũng nhận).
    public static string? Learn(string source)
    {
        var m = LearnPattern.Match(source);
        if (!m.Success) return null;
        var name = m.Groups[1].Value.Trim();
        // Loại vài từ hay đứng trước dấu hai chấm mà không phải tên
        return Blacklist.Contains(name) ? null : name;
    }

    /// Game hiện tên ở dòng riêng phía trên câu thoại: nếu hàng đầu là một cụm ngắn trông như tên (tên đã học, hoặc 1–5 từ
    /// đều Viết Hoa, không dấu câu, không dấu hai chấm) và có câu bên dưới, ghép thành "Tên: câu…" để mọi xử lý tên dùng lại được.
    /// Trả về các hàng mới và cờ đã ghép hay chưa.
    public static (List<string> rows, bool joined) JoinNameAbove(IList<string> rows, IList<string> speakers)
    {
        if (rows.Count < 2) return (rows.ToList(), false);
        var first = rows[0].Trim(' ');
        if (Canonical(first, speakers) == null) first = CleanNameRow(first, speakers);
        if (first.Length == 0) return (rows.ToList(), false);
        var words = first.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        // Tên đã học (người dùng tự thêm) được phép dài và có dấu phẩy, ví dụ "Charles, Botanist".
        bool known = Canonical(first, speakers) != null;
        if (!known && !(words.Length >= 1 && words.Length <= 5 && !first.Contains(':') && !first.Contains('：') &&
                        first.IndexOfAny(".,!?…;\"".ToCharArray()) < 0)) return (rows.ToList(), false);
        bool nameLike = words.All(w => w.Length > 0 && (char.IsUpper(w[0]) || new[] { "of", "the", "de", "von", "van" }.Contains(w.ToLowerInvariant())));
        if (!known && !nameLike) return (rows.ToList(), false);
        var body = rows[1].Trim(' ');
        // Dòng dưới phải trông như câu thoại (từ 3 từ, hoặc có dấu câu), để hai nút xếp chồng ("Quick Save" / "Back")
        // không bị ghép thành "Quick Save: Back" rồi học nhầm thành tên nhân vật.
        bool sentence = body.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length >= 3 || body.IndexOfAny(".,!?…".ToCharArray()) >= 0;
        if (TextUtils.LetterCount(body) < 2 || !sentence) return (rows.ToList(), false);
        return (new[] { $"{first}: {body}" }.Concat(rows.Skip(2)).ToList(), true);
    }

    static string TrimNonAlnum(string s)
    {
        int a = 0, b = s.Length;
        while (a < b && !char.IsLetterOrDigit(s[a])) a++;
        while (b > a && !char.IsLetterOrDigit(s[b - 1])) b--;
        return s[a..b];
    }

    /// Mẩu rác OCR hay dính vào dòng tên: không có chữ cái ("*", "•", "_"), hoặc 1–2 chữ viết thường ("a", "ii").
    public static bool IsJunkToken(string w)
    {
        var s = TrimNonAlnum(w);
        int letters = TextUtils.LetterCount(s);
        return letters == 0 || (letters <= 2 && !char.IsUpper(s[0]));
    }

    /// Dòng tên OCR hay dính rác ở hai đầu ("a Clive", "• Sleipnir", "Harbard COO"): bỏ mẩu rác ở hai đầu và ký tự lạ
    /// bám vào tên; nếu dòng có chứa đúng một tên đã học, phần thừa chỉ là mẩu ngắn (≤ 3 chữ) thì lấy luôn tên đó.
    public static string CleanNameRow(string row, IList<string> speakers)
    {
        var words = row.Split(' ', StringSplitOptions.RemoveEmptyEntries).ToList();
        while (words.Count > 0 && IsJunkToken(words[0])) words.RemoveAt(0);
        while (words.Count > 0 && IsJunkToken(words[^1])) words.RemoveAt(words.Count - 1);
        var name = TrimNonAlnum(string.Join(" ", words));
        var known = Canonical(name, speakers);
        if (known != null) return known;
        var tokens = name.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        for (int n = Math.Min(6, tokens.Length - 1); n >= 1; n--)
            for (int start = 0; start + n <= tokens.Length; start++)
            {
                var head = string.Join(" ", tokens.Skip(start).Take(n));
                var k = speakers.FirstOrDefault(s => s.ToLowerInvariant() == head.ToLowerInvariant());
                if (k == null) continue;
                var rest = tokens.Take(start).Concat(tokens.Skip(start + n));
                if (rest.All(t => TextUtils.LetterCount(TrimNonAlnum(t)) <= 3)) return k;
            }
        return name;
    }

    public record Match(string speaker, string rest);

    /// Nếu câu bắt đầu bằng "Tên:" hoặc bằng một tên đã học (dấu hai chấm bị OCR đọc sai thành , . ; - hoặc mất),
    /// trả về tên chuẩn và phần còn lại.
    public static Match? MatchSpeaker(string text, IList<string> speakers)
    {
        var t = text.Trim(' ');
        // 1. Dạng chuẩn "X: ..."
        var r = StdPrefix.Match(t);
        if (r.Success)
        {
            var name = TrailingColon.Replace(r.Value, "").Trim(' ');
            var rest = t[(r.Index + r.Length)..];
            var known = Canonical(name, speakers);
            if (known != null) return new Match(known, rest);
            if (Learn(t) != null) return new Match(name, rest);   // tên mới hợp lệ (viết hoa, không nằm blacklist)
            return null;
        }
        if (speakers.Count == 0) return null;
        // 2. Tên đã học đứng đầu, sau đó là , . ; - – — hoặc khoảng trắng
        var tokens = t.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        int junk = 0;
        while (junk < tokens.Length - 1 && IsJunkToken(tokens[junk])) junk++;   // "* Harbard …", "a Clive …"
        tokens = tokens[junk..];
        // Tối đa 6 từ: tên dài người dùng tự thêm ("Guardian of the Flame", "Charles, Botanist").
        // Khớp chính xác trước, sau mới khớp gần đúng: "Guardian of the Flame We must…" không được nuốt chữ "We"
        // (cụm 5 từ đủ giống tên 4 từ).
        foreach (var exact in new[] { true, false })
        {
            for (int n = Math.Min(6, tokens.Length); n >= 1; n--)
            {
                var head = string.Join(" ", tokens.Take(n)).Trim(",.;:-–—!?".ToCharArray());
                var known = exact ? speakers.FirstOrDefault(s => s.ToLowerInvariant() == head.ToLowerInvariant()) : Canonical(head, speakers);
                if (known == null) continue;
                var rest = LeadingPunct.Replace(string.Join(" ", tokens.Skip(n)), "").Trim(' ');
                if (rest.Length == 0) continue;
                return new Match(known, rest);
            }
        }
        return null;
    }

    /// Khớp tên (không phân biệt hoa thường, cho phép OCR sai ~20 %) với danh sách đã học.
    public static string? Canonical(string name, IList<string> speakers)
    {
        var n = name.ToLowerInvariant();
        if (n.Length == 0) return null;
        var exact = speakers.FirstOrDefault(s => s.ToLowerInvariant() == n);
        if (exact != null) return exact;
        if (n.Length < 2) return null;      // tên một chữ cái chỉ khớp chính xác, không đoán gần đúng
        string? best = null; double bestSim = 0;
        foreach (var s in speakers)
        {
            var sim = TextUtils.Similarity(n, s.ToLowerInvariant());
            if (sim >= 0.8 && sim > bestSim) { best = s; bestSim = sim; }
        }
        return best;
    }

    /// Chuẩn hoá câu nguồn thành "Tên: nội dung" để dịch nhất quán.
    public static (string text, string? speaker) Normalize(string text, IList<string> speakers)
    {
        var m = MatchSpeaker(text, speakers);
        return m == null ? (text, null) : ($"{m.speaker}: {m.rest}", m.speaker);
    }

    /// Bỏ tên người nói khỏi câu dịch để đọc voice (Gemini có thể trả "Angrboda, ..." hoặc "Angrboda: ...").
    public static string StripForVoice(string translated, string? speaker, IList<string> speakers)
    {
        var all = speakers.ToList();
        if (speaker != null && !all.Contains(speaker)) all.Add(speaker);
        var m = MatchSpeaker(translated, all);
        return m != null ? m.rest : TextUtils.StripSpeaker(translated);
    }
}
