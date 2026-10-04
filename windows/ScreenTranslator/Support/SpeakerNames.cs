using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;

namespace ScreenTranslator;

/// Học và nhận diện tên người nói ở đầu câu phụ đề ("Atreus: ...").
public static class SpeakerNames
{
    static readonly Regex LearnPattern = new(@"^([A-Z][A-Za-z'\-]{0,20}(?: [A-Z][A-Za-z'\-]{1,20}){0,2}):\s+\S", RegexOptions.Compiled);
    static readonly Regex StdPrefix = new(@"^[^:：]{1,40}[:：]\s+", RegexOptions.Compiled);
    static readonly Regex TrailingColon = new(@"[:：]\s*$", RegexOptions.Compiled);
    static readonly Regex LeadingPunct = new(@"^[,.;:\-–— ]+", RegexOptions.Compiled);
    static readonly HashSet<string> Blacklist = new() { "Note", "Warning", "Tip", "Hint", "Objective", "Quest", "Mission", "Chapter", "Press", "Error", "Info" };

    /// Trả về tên nếu câu có dạng "Tên: nội dung" (tên 1–3 từ, viết hoa chữ đầu; tên một chữ cái như "V" cũng nhận).
    public static string? Learn(string source)
    {
        var m = LearnPattern.Match(source);
        if (!m.Success) return null;
        var name = m.Groups[1].Value.Trim();
        // Loại vài từ hay đứng trước dấu hai chấm mà không phải tên
        return Blacklist.Contains(name) ? null : name;
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
        for (int n = Math.Min(3, tokens.Length); n >= 1; n--)
        {
            var head = string.Join(" ", tokens.Take(n)).Trim(",.;:-–—!?".ToCharArray());
            var known = Canonical(head, speakers);
            if (known == null) continue;
            var rest = LeadingPunct.Replace(string.Join(" ", tokens.Skip(n)), "").Trim(' ');
            if (rest.Length == 0) continue;
            return new Match(known, rest);
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
