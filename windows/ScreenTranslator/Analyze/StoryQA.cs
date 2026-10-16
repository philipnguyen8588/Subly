using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;

namespace ScreenTranslator;

/// Hỏi đáp về cốt truyện: chỉ chọn phần dữ liệu liên quan tới câu hỏi (nhân vật, bách khoa, đoạn diễn biến, câu phụ đề
/// có từ khoá) để gửi model, thay vì gửi cả kho cốt truyện mỗi lần hỏi cho đỡ tốn token. Giống hệt bản macOS.
public static class StoryQA
{
    public record Turn(string question, string answer);

    /// Giới hạn ngữ cảnh (ký tự) gửi model.
    public const int cloudBudget = 24_000;
    public const int maxQuestion = 500;

    /// Từ để hỏi / từ nối, đã bỏ dấu: không dùng để tìm.
    static readonly HashSet<string> stopWords = new((
        "co nhung nguoi nao la ai gi cua va voi trong ve nay do bao nhieu sao tai vi khi thi mot cac duoc đuoc da đa dang đang se " +
        "hay cho toi minh ban ke biet hoi the nhu o ra len xuong di đi den đen tu bi lam con khong chua roi vay ha nhe oi nua lai " +
        "ma nen neu hon nhat rat qua cung deu đeu tung moi tat ca gom nhan vat chuyen truyen cot game tom hien luc bay gio " +
        "who what which where when why how is are was were a an of in on to and or does did about tell me there from with " +
        "people person character characters story has have chinh quan he").Split(' ', StringSplitOptions.RemoveEmptyEntries));

    /// Phần dữ liệu đã chọn cho một câu hỏi; `Render` cắt theo giới hạn.
    public sealed class Material
    {
        public string question = "", narrative = "";
        public List<string> parts = new(), characters = new(), otherCharacters = new(), lore = new(), otherLore = new(),
                            excerpts = new(), history = new();
        /// Câu hỏi + tên được nhắc tới: chỉ đưa thuật ngữ liên quan vào lời dặn.
        public string focus = "";
    }

    // MARK: chọn dữ liệu

    public static string Fold(string s) => StoryUpdate.NameKey(s);

    static readonly Regex nonWord = new(@"[^\p{L}\p{N}]+");
    static string[] Words(string s) => nonWord.Split(s).Where(w => w.Length > 0).ToArray();

    record Term(string folded, string raw, int words);

    /// Cụm 1–3 từ của câu hỏi, không bắt đầu / kết thúc bằng từ để hỏi; từ đơn phải từ 3 ký tự.
    static List<Term> Terms(string question)
    {
        var raw = Words(question.ToLowerInvariant());
        var folded = raw.Select(Fold).ToArray();
        var outp = new List<Term>();
        var seen = new HashSet<string>();
        for (int n = 3; n >= 1; n--)
        {
            if (raw.Length < n) continue;
            for (int i = 0; i <= raw.Length - n; i++)
            {
                var f = folded[i..(i + n)];
                if (stopWords.Contains(f[0]) || stopWords.Contains(f[^1])) continue;
                if (n == 1 && f[0].Length < 3) continue;
                var key = string.Join(" ", f);
                if (!seen.Add(key)) continue;
                outp.Add(new Term(key, string.Join(" ", raw[i..(i + n)]), n));
            }
        }
        return outp;
    }

    /// `term` có trong `hay` như một cụm từ trọn vẹn (không phải một phần của từ khác).
    public static bool ContainsWord(string hay, string term)
    {
        if (term.Length == 0) return false;
        int from = 0, i;
        while ((i = hay.IndexOf(term, from, StringComparison.Ordinal)) >= 0)
        {
            int end = i + term.Length;
            bool before = i > 0 && char.IsLetterOrDigit(hay[i - 1]);
            bool after = end < hay.Length && char.IsLetterOrDigit(hay[end]);
            if (!before && !after) return true;
            from = end;
        }
        return false;
    }

    static readonly int[] termWeight = { 0, 3, 15, 30 };

    /// Điểm liên quan của một mục: tên có trong câu hỏi, cụm từ của câu hỏi có trong nội dung,
    /// hoặc nội dung nhắc tới một tên mà câu hỏi hỏi tới (vd. hỏi "Iron Kingdom" → người có tiểu sử nhắc Iron Kingdom).
    static int Score(string name, string text, string qKey, List<Term> terms, List<string> mentioned)
    {
        var nk = Fold(name);
        int s = 0;
        if (nk.Length > 0 && ContainsWord(qKey, nk)) s += 100;
        else if (Words(nk).Any(w => w.Length >= 4 && !stopWords.Contains(w) && ContainsWord(qKey, w))) s += 40;
        var hay = Fold(text);
        foreach (var t in terms) if (ContainsWord(hay, t.folded)) s += termWeight[t.words];
        foreach (var m in mentioned) if (m != nk && ContainsWord(hay, m)) s += 40;
        return s;
    }

    static string Cut(string s, int n) => s.Length > n ? s[..n] + "…" : s;

    public static Material Gather(string question, GameStory? story, IReadOnlyList<StoryPart> parts, IReadOnlyList<Turn> history,
                                  Func<List<string>, List<TranslationEntry>> search)
    {
        var qKey = Fold(question);
        var characters = story?.characters ?? new List<StoryCharacter>();
        var lore = story?.lore ?? new List<StoryLore>();
        // Tên nhân vật / mục bách khoa được hỏi thẳng.
        var mentioned = characters.Select(c => c.name).Concat(lore.Select(l => l.name)).Select(Fold)
            .Where(k => k.Length >= 2 && ContainsWord(qKey, k)).ToList();
        // Bỏ các từ lẻ nằm trong một tên được hỏi ("iron", "kingdom" của "Iron Kingdom"): chúng kéo về câu không liên quan.
        var terms = Terms(question).Where(t => !mentioned.Any(m => m != t.folded && ContainsWord(m, t.folded))).ToList();

        var scoredLore = lore.Select(l => (l, s: Score(l.name, l.description, qKey, terms, mentioned)))
            .Where(x => x.s > 0).OrderByDescending(x => x.s).Take(8).Select(x => x.l).ToList();
        var detailedLore = scoredLore.Select(l => l.name).ToHashSet();
        var loreLines = scoredLore.Select(l => $"- {l.name} [{l.kind}]: {l.description}").ToList();
        var otherLore = lore.Where(l => !detailedLore.Contains(l.name)).Select(l => l.name).ToList();

        // Đoạn diễn biến (mới nhất trước trong `parts`): những đoạn khớp nhất, không có thì 3 đoạn gần nhất; xếp lại cũ trước.
        var pickedParts = parts.Select(p => (p, s: Score("", p.title + " " + p.summary, qKey, terms, mentioned)))
            .Where(x => x.s > 0).OrderByDescending(x => x.s).Take(4).Select(x => x.p).ToList();
        if (pickedParts.Count == 0) pickedParts = parts.Take(3).ToList();
        var partLines = pickedParts.OrderBy(p => p.id).Select(p => $"- {p.title}: {TextUtils.Normalize(p.summary)}").ToList();

        // Câu phụ đề: tìm theo tên được hỏi (viết như trong game) và các cụm từ của câu hỏi, lấy 40 câu khớp nhất.
        var namesAsWritten = characters.Select(c => c.name).Concat(lore.Select(l => l.name)).Where(n => mentioned.Contains(Fold(n))).ToList();
        var seenTerm = new HashSet<string>();
        var searchTerms = namesAsWritten.Concat(terms.Where(t => t.words >= 2 || t.raw.Length >= 4).Select(t => t.raw))
            .Where(t => seenTerm.Add(Fold(t))).ToList();
        var found = searchTerms.Count == 0 ? new List<TranslationEntry>() : search(searchTerms);
        var excerpts = found.Select(e => (e, s: Score("", e.source + " " + e.translated, qKey, terms, mentioned)))
            .Where(x => x.s > 0).OrderByDescending(x => x.s).ThenByDescending(x => x.e.id).Take(40)
            .Select(x => x.e).OrderBy(e => e.id).Select(e => TextUtils.Normalize(e.source)).ToList();

        // Nhân vật: ngoài điểm theo câu hỏi, cộng thêm cho người nói / được nhắc trong các câu phụ đề vừa tìm được và trong
        // mục bách khoa được hỏi tới. Hồ sơ nhân vật viết bằng ngôn ngữ đích (vd. "Vương quốc Sắt") nên tên tiếng Anh trong
        // câu hỏi ("Iron Kingdom") thường không khớp thẳng: phụ đề gốc là cầu nối.
        var speakers = excerpts.Select(l => l.IndexOf(':')).Zip(excerpts)
            .Where(x => x.First > 0 && x.First <= 30).Select(x => Fold(x.Second[..x.First])).ToHashSet();
        var askedLore = scoredLore.Where(l => mentioned.Contains(Fold(l.name))).ToList();
        var linked = Fold(string.Join("\n", askedLore.Select(l => l.description).Concat(excerpts)));
        // Cụm 2 từ trong mô tả của mục bách khoa được hỏi (vd. "thượng phụ"): nhân vật có vai trò chứa cụm đó cũng liên quan.
        var loreBigrams = askedLore.SelectMany(l =>
        {
            var w = Words(Fold(l.description));
            return Enumerable.Range(0, Math.Max(0, w.Length - 1))
                .Where(i => !stopWords.Contains(w[i]) && !stopWords.Contains(w[i + 1])).Select(i => w[i] + " " + w[i + 1]);
        }).ToHashSet();
        int LinkBonus(StoryCharacter c)
        {
            var full = Fold(c.name);
            var first = full.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? full;
            if (speakers.Contains(full) || speakers.Contains(first)) return 25;
            if (ContainsWord(linked, full) || (first.Length >= 4 && ContainsWord(linked, first))) return 20;
            var role = Fold(c.role + " " + c.journal);
            return loreBigrams.Any(b => ContainsWord(role, b)) ? 15 : 0;
        }
        static string CharText(StoryCharacter c) => string.Join(" ", c.role, c.personality, c.background, c.relations, c.status, c.journal);
        var scoredChars = characters.Select(c => (c, s: Score(c.name, CharText(c), qKey, terms, mentioned) + LinkBonus(c)))
            .Where(x => x.s > 0).OrderByDescending(x => x.s).Take(12).Select(x => x.c).ToList();
        // Câu hỏi chung chung (không khớp ai): đưa những người vừa xuất hiện gần đây.
        if (scoredChars.Count == 0) scoredChars = characters.Where(c => c.seen > 0).OrderByDescending(c => c.seen).Take(6).ToList();
        var detailedNames = scoredChars.Select(c => c.name).ToHashSet();
        var charLines = scoredChars.Select(c =>
        {
            var fields = string.Join("; ", new[] { ("role", c.role), ("personality", c.personality), ("background", c.background),
                                                   ("relations", c.relations), ("status", c.status), ("journal", c.journal) }
                .Where(f => f.Item2.Length > 0).Select(f => $"{f.Item1}: {f.Item2}"));
            return $"- {c.name}: {(fields.Length == 0 ? "(nothing known yet)" : fields)}";
        }).ToList();
        var otherChars = characters.Where(c => !detailedNames.Contains(c.name)).Select(c =>
        {
            var role = TextUtils.Normalize(c.role);
            return role.Length == 0 ? c.name : $"{c.name} ({Cut(role, 70)})";
        }).ToList();

        var historyLines = history.TakeLast(3).Select(t => $"Q: {t.question}\nA: {Cut(t.answer, 500)}").ToList();
        var focus = string.Join("\n", new[] { question }.Concat(namesAsWritten).Concat(scoredChars.Select(c => c.name)).Concat(scoredLore.Select(l => l.name)));
        return new Material
        {
            question = question, narrative = story?.narrative ?? "", parts = partLines, characters = charLines,
            otherCharacters = otherChars, lore = loreLines, otherLore = otherLore, excerpts = excerpts, history = historyLines, focus = focus,
        };
    }

    // MARK: dựng nội dung gửi model

    /// Lấy các mục theo thứ tự cho tới khi đủ `cap` ký tự (mục đầu quá dài thì cắt bớt).
    static string Fill(List<string> items, int cap, string separator = "\n")
    {
        var outp = "";
        foreach (var item in items)
        {
            var add = (outp.Length == 0 ? "" : separator) + item;
            if (outp.Length + add.Length > cap)
            {
                if (outp.Length == 0) outp = item[..Math.Max(0, cap - 1)] + "…";
                break;
            }
            outp += add;
        }
        return outp;
    }

    public static string Render(Material m, int budget)
    {
        int Cap(double share) => (int)(budget * share);
        var blocks = new List<(string, string)>
        {
            ("STORY SO FAR", Cut(m.narrative, Cap(0.2))),
            ("STORY PARTS (oldest first)", Fill(m.parts, Cap(0.14))),
            ("CHARACTERS", Fill(m.characters, Cap(0.26))),
            ("ALL OTHER CHARACTERS", Fill(m.otherCharacters, Cap(0.09), "; ")),
            ("LORE", Fill(m.lore, Cap(0.1))),
            ("OTHER LORE ENTRIES", Fill(m.otherLore, Cap(0.03), ", ")),
            ("SUBTITLE EXCERPTS (oldest first)", Fill(m.excerpts, Cap(0.12))),
            ("PREVIOUS Q&A", Fill(m.history, Cap(0.06), "\n\n")),
        };
        var outp = string.Join("\n\n", blocks.Where(b => b.Item2.Length > 0).Select(b => $"{b.Item1}:\n{b.Item2}"));
        return outp + (outp.Length == 0 ? "" : "\n\n") + "QUESTION:\n" + m.question;
    }
}
