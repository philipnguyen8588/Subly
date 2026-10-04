using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;

namespace ScreenTranslator;

/// Tách kết quả OCR (nhiều hàng) thành từng câu thoại và bỏ những câu đã xử lý rồi.
/// Xử lý 3 tình huống: (1) game giữ câu cũ và hiện thêm câu mới bên dưới; (2) hai người nói hiện cùng lúc;
/// (3) câu mới đi kèm câu cũ bị coi là "trùng" nên bị bỏ mất.
public static class SubtitleSplitter
{
    static readonly Regex DashStart = new(@"^[-–—]\s*\S", RegexOptions.Compiled);
    static readonly Regex NameHead = new(@"^[^:：]{1,40}[:：]\s*\S", RegexOptions.Compiled);
    static readonly Regex ColonWs = new(@"[:：]\s*", RegexOptions.Compiled);
    static readonly Regex DashPrefix = new(@"^[-–—]\s*", RegexOptions.Compiled);
    static readonly Regex SoundDesc = new(@"\[[^\]]*\]|\([^)]*\)|\*[^*]*\*", RegexOptions.Compiled);

    /// Hàng bắt đầu một câu thoại mới: "Tên: …" (tên đã học hoặc tên hợp lệ) hoặc gạch đầu dòng "- …".
    public static bool StartsUtterance(string row, IList<string> speakers, bool useNames)
    {
        var t = row.Trim(' ');
        if (DashStart.IsMatch(t)) return true;
        if (!useNames) return false;
        var r = NameHead.Match(t);
        if (!r.Success) return false;
        var head = r.Value;
        int colon = head.IndexOfAny(new[] { ':', '：' });
        if (colon < 0) return false;
        var name = head[..colon].Trim(' ');
        if (SpeakerNames.Canonical(name, speakers) != null) return true;
        // Thay dấu hai chấm (trong phần đầu) bằng ": " rồi thử học tên.
        var fixedHead = ColonWs.Replace(head, ": ");
        return SpeakerNames.Learn(fixedHead + t[(r.Index + r.Length)..]) != null;
    }

    /// Gom các hàng thành câu thoại: hàng không mở đầu câu mới thì nối vào câu trước.
    public static List<string> Utterances(IList<string> rows, IList<string> speakers, bool useNames)
    {
        var outp = new List<string>();
        foreach (var row in rows)
        {
            if (row.Length == 0) continue;
            if (outp.Count == 0 || StartsUtterance(row, speakers, useNames)) outp.Add(DashPrefix.Replace(row, ""));
            else outp[^1] += " " + row;
        }
        return outp;
    }

    /// Độ giống cao nhất (0...1) của `text` so với các câu đã xử lý gần đây.
    public static double Score(string text, IList<string> recent)
    {
        double best = 0;
        foreach (var r in recent) best = Math.Max(best, Math.Max(TextUtils.Similarity(text, r), TextUtils.WordSimilarity(text, r)));
        return best;
    }

    /// Trả về các câu thoại CHƯA xử lý, theo thứ tự trên màn hình.
    public static List<string> Fresh(IList<string> rows, IList<string> speakers, bool useNames, IList<string> recent, double threshold)
    {
        bool Known(string s) => Score(s, recent) >= threshold;
        var parts = Utterances(rows, speakers, useNames);
        if (parts.Count == 1)
        {
            // Không tách được theo tên: hoặc là biến thể OCR của câu cũ, hoặc "câu cũ + câu mới" (game không hiện tên).
            var whole = parts[0];
            var wholeScore = Score(whole, recent);
            List<string>? split = null;
            if (rows.Count >= 2)
            {
                for (int k = rows.Count - 1; k >= 1; k--)
                {
                    var head = string.Join(" ", rows.Take(k));
                    var hs = Score(head, recent);
                    // Phần đầu khớp câu cũ TỐT HƠN cả đoạn → phần còn lại là câu mới.
                    if (hs >= threshold && hs > wholeScore + 0.02) { split = new() { head, string.Join(" ", rows.Skip(k)) }; break; }
                }
            }
            if (split != null) parts = split;
            else if (wholeScore >= threshold) return new();
        }
        var result = new List<string>();
        foreach (var part in parts)
        {
            if (TextUtils.LetterCount(part) < 2 || Known(part)) continue;
            // Câu mới MỞ ĐẦU bằng một câu đã đọc (game nối thêm chữ, hoặc OCR đọc lặp phần đuôi) → chỉ giữ phần thêm.
            var rest = RemainderAfterKnownPrefix(part, recent);
            if (rest != null)
            {
                if (rest.Length == 0 || Known(rest)) continue;
                result.Add(rest);
            }
            else result.Add(part);
        }
        return result;
    }

    // MARK: từ cảm thán

    static readonly HashSet<string> InterjectionWords = new()
    {
        "hm", "hmm", "hmph", "mhm", "mm", "mmhmm", "uh", "um", "er", "erm", "ah", "aha", "oh", "ooh", "eh", "huh", "ha", "heh",
        "ho", "hey", "wow", "whoa", "ugh", "argh", "agh", "gah", "grr", "tsk", "pfft", "phew", "oof", "ow", "ouch", "shh", "psst",
        "yikes", "whew", "meh", "bah", "eek", "ack", "urgh", "nngh", "hah", "ahem", "uhhuh", "uhuh", "ahh", "ohh", "oho", "ehh",
    };
    /// Dạng kéo dài / lặp: hmmmm, hahaha, uhhh, aaah, ooooh, grrrr, arrrgh…
    static readonly Regex InterjectionPattern = new(
        @"^(h+m+p?h?|m+h*m+|u+h+|u+m+|e+r+m*|a+h+a*|o+h+o*|e+h+|h+u+h+|(ha|he|ho|hi|hu){2,}h?|he+h+|ha+h*|ho+h*|a+r+g+h*|u+r*g+h+|a+g+h+|g+r+|w+h*o+a+h*|wo+w+|phe+w+|o+f+|o+w+|t+s+k+|p+f+t+|s+h+|z+|n+g+h+|y+a+h+)$",
        RegexOptions.Compiled);

    static List<string> SplitWords(string s, Func<char, bool> keep)
    {
        var list = new List<string>();
        var cur = new System.Text.StringBuilder();
        foreach (var c in s)
        {
            if (keep(c)) cur.Append(c);
            else if (cur.Length > 0) { list.Add(cur.ToString()); cur.Clear(); }
        }
        if (cur.Length > 0) list.Add(cur.ToString());
        return list;
    }

    /// Câu chỉ gồm từ cảm thán (hmm, haha, huh…) hoặc mô tả âm thanh trong ngoặc ([grunts], (sighs), *laughs*).
    /// Tên người nói ở đầu ("Kratos: Hmm.") được bỏ qua khi xét.
    public static bool IsInterjectionOnly(string text)
    {
        var t = TextUtils.StripSpeaker(text);
        // Mô tả âm thanh trong ngoặc không phải lời thoại.
        t = SoundDesc.Replace(t, " ");
        var words = SplitWords(t.ToLowerInvariant(), char.IsLetter);
        if (words.Count == 0) return TextUtils.LetterCount(text) > 0 && t.Trim().Length < text.Length;
        return words.All(w => InterjectionWords.Contains(w) || InterjectionPattern.IsMatch(w));
    }

    /// Từ tiếng Anh cơ bản mà người chơi tự hiểu được, không cần dịch.
    static readonly HashSet<string> BasicWords = new()
    {
        "yes", "yeah", "yep", "yup", "no", "nope", "nah", "ok", "okay", "alright", "all", "right", "sure", "fine", "good", "great",
        "nice", "cool", "well", "so", "and", "but", "or", "oh", "hey", "hi", "hello", "bye", "goodbye", "thanks", "thank", "you",
        "please", "sorry", "what", "why", "who", "where", "when", "how", "really", "maybe", "now", "here", "there", "this", "that",
        "it", "is", "it's", "that's", "what's", "i", "i'm", "me", "my", "we", "us", "he", "she", "they", "a", "an", "the", "to", "of",
        "go", "come", "on", "in", "out", "up", "down", "let's", "wait", "stop", "look", "run", "move", "help", "see", "know", "got",
        "get", "do", "did", "don't", "not", "can", "can't", "will", "too", "very", "again", "more", "one", "two", "three",
        "man", "boss", "sir", "ma'am", "damn", "shit", "fuck", "hell", "god", "wow", "huh", "hmm", "mm", "uh", "um", "ah",
    };

    /// Từ điển tiếng Anh (words.txt cạnh file exe, thay cho /usr/share/dict/words của macOS), nạp khi cần lần đầu,
    /// để phân biệt câu ngắn thật với chữ OCR vô nghĩa ("imph", "impr").
    static readonly Lazy<HashSet<string>?> Dictionary = new(() =>
    {
        try
        {
            var p = Path.Combine(AppPaths.AppDir, "words.txt");
            if (!File.Exists(p)) { Log.Warn("Không có words.txt → coi mọi câu ngắn đều có từ tiếng Anh"); return null; }
            return new HashSet<string>(File.ReadLines(p).Select(l => l.Trim().ToLowerInvariant()).Where(l => l.Length > 0));
        }
        catch { return null; }
    });

    /// Có ít nhất một từ tiếng Anh thật (từ 2 chữ cái, hoặc "I"/"a").
    public static bool HasEnglishWord(string text)
    {
        var dict = Dictionary.Value;
        var words = SplitWords(TextUtils.StripSpeaker(text).ToLowerInvariant().Replace('’', '\''), c => char.IsLetter(c) || c == '\'');
        foreach (var w in words)
        {
            if (w == "i" || w == "a") return true;
            if (w.Length < 2) continue;
            if (dict == null) return true;
            if (BasicWords.Contains(w) || dict.Contains(w)) return true;
            // Dạng biến đổi thường gặp: số nhiều, quá khứ, -ing, 's, n't.
            foreach (var suffix in new[] { "n't", "'s", "'re", "'ll", "'ve", "'d", "ing", "ed", "es", "s" })
                if (w.EndsWith(suffix) && w.Length > suffix.Length + 1 && dict.Contains(w[..^suffix.Length])) return true;
        }
        return false;
    }

    /// Câu quá đơn giản, không cần dịch hay đọc (mục tiêu là hiểu nội dung game, không phải đọc hết):
    /// sau khi bỏ tên người nói còn tối đa 2 từ ("V: No.", "Mechanic: What?", "Kill him."), hoặc tối đa 5 từ mà toàn từ cơ bản
    /// ("Okay, let's go.", "What? No, no, no.").
    public static bool IsSimple(string text)
    {
        var t = TextUtils.StripSpeaker(text.Trim(' '));
        var words = SplitWords(t.ToLowerInvariant().Replace('’', '\''), c => char.IsLetter(c) || char.IsDigit(c) || c == '\'');
        if (words.Count <= 2) return true;
        return words.Count <= 5 && words.All(BasicWords.Contains);
    }

    /// Mẩu chữ lạc đứng một mình, không phải lời thoại: tối đa 2 từ, không có tên người nói, không có dấu câu
    /// ("mph", "impr", "ON mph" của đồng hồ xe; "Quick", "BACK" của nút bấm). Lời thoại ngắn thật luôn có dấu câu
    /// ("No.", "What?") hoặc tên người nói ("V: Sure").
    public static bool IsStrayFragment(string text)
    {
        var t = text.Trim(' ');
        if (NameHead.IsMatch(t)) return false;
        if (t.IndexOfAny(".,!?…".ToCharArray()) >= 0) return false;
        return t.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length <= 2;
    }

    static string Norm(string w) => new(w.ToLowerInvariant().Where(char.IsLetterOrDigit).ToArray());
    static bool Alike(string a, string b) => a == b || (a.Length >= 3 && b.Length >= 3 && TextUtils.Similarity(a, b) >= 0.72);

    /// Nếu `text` bắt đầu bằng (gần đúng, theo từng từ) một câu trong `recent`: trả về phần còn lại sau câu đó.
    /// Phần còn lại là "" khi nó chỉ là tiếng vọng OCR của mấy từ cuối (ví dụ "... How youve grown! uve prown sa").
    /// Trả về null nếu không có câu nào là phần mở đầu.
    public static string? RemainderAfterKnownPrefix(string text, IList<string> recent)
    {
        var tokens = text.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var words = tokens.Select(Norm).ToArray();
        int bestN = 0; string[]? bestKnown = null;
        foreach (var r in recent)
        {
            var kw = r.Split(' ', StringSplitOptions.RemoveEmptyEntries).Select(Norm).Where(s => s.Length > 0).ToArray();
            int n = kw.Length;
            if (n < 3 || words.Length <= n) continue;
            // So từng từ, cho phép ~15 % sai do OCR.
            int hits = 0;
            for (int i = 0; i < n; i++) if (Alike(kw[i], words[i])) hits++;
            if ((double)hits / n >= 0.85 && n > bestN) { bestN = n; bestKnown = kw; }
        }
        if (bestKnown == null) return null;
        var restTokens = tokens.Skip(bestN).ToArray();
        var restWords = restTokens.Select(Norm).Where(w => w.Length >= 2).ToArray();
        if (restWords.Length == 0) return "";
        // Tiếng vọng OCR: mọi từ còn lại đều giống hoặc nằm trong một từ của câu đã đọc.
        bool echo = restWords.All(w => bestKnown.Any(k => k.Contains(w) || (w.Contains(k) && k.Length >= 3) || TextUtils.Similarity(k, w) >= 0.6));
        // Mảnh vụn: quá ngắn, toàn chữ thường, không có dấu câu → không phải câu thoại mới.
        var rest = string.Join(" ", restTokens);
        bool fragment = restWords.Length <= 3 && rest == rest.ToLowerInvariant() && rest.IndexOfAny(".!?…".ToCharArray()) < 0;
        return echo || fragment ? "" : rest;
    }
}
