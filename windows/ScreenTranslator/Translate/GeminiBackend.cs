using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace ScreenTranslator;

public class GeminiException : Exception
{
    public enum Kind { noKey, rateLimited, http, empty, badJSON, timeout }
    public readonly Kind kind;
    public readonly int code;
    public readonly double? retryAfter;
    public GeminiException(Kind kind, string msg, int code = 0, double? retryAfter = null) : base(msg)
    { this.kind = kind; this.code = code; this.retryAfter = retryAfter; }

    public static GeminiException NoKey() => new(Kind.noKey, "Chưa có Gemini API key");
    public static GeminiException RateLimited(double? r) => new(Kind.rateLimited, $"Gemini 429 rate limited (retry {(int)(r ?? 60)}s)", 429, r);
    public static GeminiException Http(int c, string m) => new(Kind.http, $"Gemini HTTP {c}: {m}", c);
    public static GeminiException Empty() => new(Kind.empty, "Gemini trả về rỗng");
    public static GeminiException BadJSON() => new(Kind.badJSON, "Gemini trả về JSON không hợp lệ");
    public static GeminiException Timeout() => new(Kind.timeout, "Gemini quá thời gian chờ");
}

public sealed class GeminiBackend : ITranslationBackend, ICloudChatBackend
{
    public BackendKind kind => BackendKind.gemini;

    /// Từ 10/2026 Google không cho tài khoản mới dùng model 2.x và endpoint generateContent cũ trả 404 → gọi qua Interactions API.
    public static readonly string[] models =
    {
        "gemini-3.5-flash-lite",
        "gemini-flash-lite-latest",
        "gemini-3.1-flash-lite",
        "gemini-3.5-flash",
        "gemini-3.8-flash",
    };
    /// Thứ tự thử khi model đã chọn bị 503/404/timeout.
    public static readonly string[] fallbackModels = { "gemini-3.5-flash-lite", "gemini-flash-lite-latest", "gemini-3.1-flash-lite", "gemini-3.5-flash" };
    /// Model dự phòng của bản này (AI share chỉ được thử các model đã share).
    public string[] fallbacks = fallbackModels;

    /// Nhiều key miễn phí dùng xoay vòng: mỗi request lấy key kế tiếp để chia đều quota; key bị 429 thì nghỉ đến hết
    /// thời gian Google báo, các key còn lại chạy tiếp.
    public List<string> apiKeys = new();
    public string apiKey
    {
        get => apiKeys.FirstOrDefault() ?? "";
        set => apiKeys = string.IsNullOrEmpty(value) ? new List<string>() : new List<string> { value };
    }
    int keyIndex;
    readonly Dictionary<string, DateTime> keyCooldown = new();
    readonly object keyLock = new();
    public string model;
    public double timeout;
    public string baseURL = "https://generativelanguage.googleapis.com/v1beta";
    public string targetName = "Vietnamese";
    public List<GlossaryEntry> glossary = new();
    public List<string> speakers = new();
    /// Chữ đang dịch (câu + ngữ cảnh). Có giá trị thì chỉ đưa vào prompt những thuật ngữ xuất hiện trong đó,
    /// để danh sách thuật ngữ dài không làm prompt phình to.
    public string glossaryFocus = "";
    /// Tên game đang chơi (tên profile) để model dùng hiểu biết về thế giới của game đó.
    public string gameName = "";
    public TranslationStyle translationStyle = TranslationStyle.modern;
    /// Ghi chú riêng của người chơi cho game này (thêm nguyên văn vào lời dặn).
    public string translationNote = "";
    /// Bối cảnh cốt truyện: tóm tắt "Dịch màn hình" gần nhất có nội dung (Journal, tiểu sử nhân vật…).
    public string storyContext = "";
    /// Model đang thực sự dùng (có thể là model dự phòng) + hạn "dính" 5 phút.
    public string? activeModel { get; private set; }
    DateTime activeUntil = DateTime.MinValue;
    public string? lastError { get; private set; }
    /// Model người dùng chọn trả 404 (không tồn tại với key này) → Router sẽ đổi cài đặt sang model dự phòng.
    public bool chosenModelMissing { get; set; }

    static readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(90) };

    public GeminiBackend(string apiKey, string model, double timeout)
    {
        this.apiKey = apiKey; this.model = model; this.timeout = timeout;
    }

    public GeminiBackend(List<string> apiKeys, string model, double timeout)
    {
        this.apiKeys = apiKeys; this.model = model; this.timeout = timeout;
    }

    // AI share dùng Gemini qua proxy của server: router gọi nó như các nhà cung cấp kiểu chat khác.
    public bool isReady => !string.IsNullOrEmpty(apiKey) && model.Length > 0;
    public string modelName => model;
    Task<string> ICloudChatBackend.Translate(string text, IList<TranslationPair> context, CancellationToken ct, string? modelOverride) =>
        TranslateWith(text, context, modelOverride, ct);
    Task<string> ICloudChatBackend.Complete(string system, string user, bool json, int maxTokens, double timeout, CancellationToken ct, string? modelOverride) =>
        Generate(system, user, timeout, ct, maxTokens, modelOverride);

    /// Danh sách model để thử theo thứ tự cho một request.
    List<string> CandidateModels(int maxAttempts)
    {
        var list = new List<string>();
        if (activeModel != null && DateTime.UtcNow < activeUntil) list.Add(activeModel);
        list.Add(model);
        list.AddRange(fallbacks);
        return list.Distinct().Take(maxAttempts).ToList();
    }

    static bool IsRetryable(Exception e) => e is GeminiException g &&
        (g.kind == GeminiException.Kind.timeout || (g.kind == GeminiException.Kind.http && (g.code == 503 || g.code == 404 || g.code == 500 || g.code == 502)));

    // MARK: prompts

    string speakersBlock => speakers.Count == 0 ? "" :
        "\nCharacter names (keep exactly as written, never translate; a line that starts with one of them followed by a colon keeps it at the start): " + string.Join(", ", speakers) + "\n";

    string glossaryBlock => GlossaryBlock(glossaryFocus);

    /// `focus` truyền riêng để việc chạy nền (cốt truyện) không ghi đè `glossaryFocus` của câu phụ đề đang dịch.
    string GlossaryBlock(string rawFocus)
    {
        var focus = rawFocus.ToLowerInvariant();
        var items = glossary.Where(g =>
        {
            var t = g.term.Trim();
            // So khớp theo nguyên từ (không phải chuỗi con): "Uma" không khớp "human", "Quen" không khớp "frequent";
            // cho phép đuôi số nhiều -s/-es/'s ("drowner" khớp "drowners").
            if (t.Length == 0) return false;
            if (focus.Length == 0) return true;
            var pattern = @"(?<![\p{L}\p{N}])" + Regex.Escape(t.ToLowerInvariant()) + @"(?:'?s|es)?(?![\p{L}\p{N}])";
            return Regex.IsMatch(focus, pattern);
        }).ToList();
        if (items.Count == 0) return speakersBlock;
        var rows = items.Select(g => g.keepAsIs || g.translation.Trim().Length == 0
            ? $"- \"{g.term}\" → keep exactly as \"{g.term}\""
            : $"- \"{g.term}\" → \"{g.translation}\"");
        return "\nGlossary (always apply, case-insensitive match):\n" + string.Join("\n", rows) + "\n" + speakersBlock;
    }

    public string subtitleSystemPrompt
    {
        get
        {
            var source = gameName.Length == 0 ? "movies and video games" : $"the video game \"{gameName}\"";
            var story = storyContext.Length == 0 ? "" : $"\nStory so far (background only, never translate it): {storyContext}\n";
            var trimmedNote = translationNote.Trim();
            var note = trimmedNote.Length == 0 ? "" : $"Notes from the player for this game (follow them): {trimmedNote}\n";
            return $"You write {targetName} subtitles for {source}. Translate the meaning and the feeling, never word by word, " +
                   $"like a professional film subtitler. Turn slang, idioms and swearing into natural spoken {targetName} of the same strength; " +
                   "never translate them literally. Keep lines short and spoken, like real people talking. " +
                   "Keep character names and game terms as written unless the glossary says otherwise. " +
                   $"Output ONLY the {targetName} line, with no quotes, notes or explanations. If the input starts with a speaker's name and a colon " +
                   "(for example \"Jackie: \"), start the output with that same name and colon; if it does not, do not add any name.\n" +
                   (targetName == "Vietnamese" ? VietnameseStyle(translationStyle) : "") + note + story + glossaryBlock;
        }
    }

    /// Hướng dẫn riêng cho tiếng Việt, theo phong cách của game: xưng hô là chỗ dịch máy hay sai nhất.
    public static string VietnameseStyle(TranslationStyle style)
    {
        // Xưng hô theo quan hệ trong gia đình: model hay bỏ qua nếu không nhắc (chú Byron gọi cháu Clive là "ngươi").
        const string family =
            "Family members always use family terms: uncle/aunt and nephew/niece → \"chú/bác/cô/dì\" and \"cháu\"; parent and child → " +
            "\"cha/bố/mẹ\" and \"con\"; siblings → \"anh/chị\" and \"em\"; grandparents → \"ông/bà\" and \"cháu\". \"Uncle X\" = \"chú X\". " +
            "Decide the relationship from the conversation and the story context.\n";
        const string common = family +
            "Greetings, goodbyes, thanks and stock phrases must use what a Vietnamese person would actually say in that moment, " +
            "not a literal rendering. Keep the same pronouns as the previous lines between the same people. " +
            "If the input is a cut-off fragment, translate only what is there and add nothing.\n";
        return style switch
        {
            TranslationStyle.fantasy =>
                "Setting: a medieval fantasy world of knights, lords and kingdoms. Write in a dignified, slightly old-fashioned Vietnamese, " +
                "like a Vietnamese dub of a fantasy film. " +
                "Pronouns: a soldier or servant speaking to his lord or commander says \"tôi\" and calls him \"ngài\"; comrades-in-arms say \"tôi\" and \"anh\"; " +
                "lords, enemies and anyone speaking down say \"ta\" and \"ngươi\"; groups say \"chúng tôi\" (not including the listener) or " +
                "\"chúng ta\" (including the listener). Titles: \"Sir X\" = \"ngài X\", \"Lady X\" = \"tiểu thư X\", \"my lord\" = \"thưa ngài\", " +
                "\"Your Highness\" = \"điện hạ\". Never use \"tớ\", \"tụi\", \"bạn\" or modern slang. " +
                common + "Examples of the style:\n" +
                "Soldier: As you command. → Soldier: Tuân lệnh.\n" +
                "Clive: Thank you, Sir Wade. → Clive: Cảm ơn ngài Wade.\n" +
                "Clive: And so we shall. → Clive: Và chúng ta sẽ làm vậy.\n" +
                "Knight: We are outnumbered, my lord. → Knight: Thưa ngài, quân ta yếu thế hơn.\n" +
                "Clive: I have a favor to ask, Uncle Byron. → Clive: Cháu có việc muốn nhờ chú, chú Byron.\n",
            TranslationStyle.myth =>
                "Setting: an epic of gods, giants and ancient myth. Write in a strong, terse, slightly archaic Vietnamese. " +
                "Pronouns: gods, giants and enemies speaking to each other or to mortals say \"ta\" and \"ngươi\"; a father speaking to his son " +
                "says \"ta\" and \"con\", the son says \"con\" and \"cha\"; companions say \"tôi\" and \"anh\"/\"ông\". Never use \"tớ\", \"tụi\", \"bạn\" or " +
                "modern slang. " +
                common + "Examples of the style:\n" +
                "Kratos: Boy. → Kratos: Con.\n" +
                "Kratos: We go. Now. → Kratos: Đi. Ngay.\n" +
                "Thor: You'll pay for that. → Thor: Ngươi sẽ phải trả giá.\n",
            _ =>
                "Pronouns: by default the speaker says \"tôi\" and calls teammates and friends \"cậu\" or \"anh\"/\"cô\", strangers and officials " +
                "\"anh\"/\"cô\"/\"ông\". Use \"tao/mày\" only when the speaker is openly hostile or insulting. Never use \"ngươi\". " +
                "\"jack in\" = \"kết nối vào\". Short Spanish or other foreign phrases are translated by meaning into the same natural Vietnamese, " +
                "except names and single words like \"hermano\", \"choom\" that work as nicknames. " +
                common + "Examples of the style:\n" +
                "V: About to find out. → V: Sắp biết ngay đây.\n" +
                "Jackie: Locked an' ready, hermano. Do your thing. → Jackie: Sẵn sàng rồi, hermano. Làm đi.\n" +
                "Jackie: I will. Ahí luego. → Jackie: Chắc chắn rồi. Gặp sau nhé.\n" +
                "V: Tell Misty I said \"Hi.\" → V: Gửi lời chào Misty giúp tôi nhé.\n" +
                "Sheriff (hostile): Ain't buyin' it. → Sheriff: Đừng hòng tao tin.\n",
        };
    }

    /// Cách viết phần tóm tắt của "Dịch màn hình".
    public const string summaryGuide =
        "How long the summary is depends on the screen. " +
        "If the screen only has menus, buttons, settings or stats, write one short sentence saying what the screen is. " +
        "If it contains story, quest, journal, codex or character text, retell ALL of that text's content in your own words, " +
        "not just the gist: keep every person, relationship, trait, past event, motive, goal, place, faction, item and number it mentions, " +
        "in the original order, in as many sentences as needed (usually 4–10). Do not add facts that are not on screen. " +
        "Write natural flowing prose. Never list categories, never comment on what the text contains, and never give advice; " +
        "mention the player's next step only when the screen states an objective.";

    public string analysisSystemPrompt =>
        "You are helping a player understand a video game screen. The user gives you numbered lines of English text " +
        "extracted by OCR from one screenshot (UI labels, dialog, quest text, stats). OCR may contain small errors; infer the intent.\n" +
        "Return JSON with:\n" +
        $"- \"summary\": in {targetName}. {summaryGuide}\n" +
        $"- \"lines\": an array of {{\"i\": line number, \"t\": {targetName} translation}}. Translate every line; keep names, numbers, keys and game terms as-is unless the glossary says otherwise.\n" +
        glossaryBlock;

    /// Tóm tắt một đoạn phụ đề người dùng chọn trong nhật ký (dùng chung cho mọi engine).
    public string storySummaryPrompt
    {
        get
        {
            var source = gameName.Length == 0 ? "a video game or movie" : $"the video game \"{gameName}\"";
            var trimmedNote = translationNote.Trim();
            var note = trimmedNote.Length == 0 ? "" : $"Notes from the player about this game (relationships, names): {trimmedNote}\n";
            return $"You help a player follow the story of {source}. The user sends subtitle lines in the order they appeared; " +
                   "a line may start with the speaker's name and a colon. OCR may contain small errors; infer the intent.\n" +
                   $"Write in {targetName}:\n" +
                   "- \"title\": a short title for this part of the story (3–8 words).\n" +
                   "- \"summary\": retell what happens in this part as a clear story: who is involved, what they say, want or decide, " +
                   "what is revealed, relationships and motives, and how it ends. Mention characters by name. Length depends on the input: " +
                   "2–4 sentences for a short exchange, up to 3 short paragraphs for a long scene. Stay faithful: only what the lines say or " +
                   "clearly imply; never invent actions, gestures or feelings (hugs, tears…), and when it is unclear who did something, " +
                   "keep it vague instead of guessing. Never list the lines one by one; never give advice.\n" +
                   "Keep character names and game terms as written unless the glossary says otherwise.\n" +
                   note + glossaryBlock;
        }
    }

    /// Trả lời câu hỏi của người chơi về cốt truyện, chỉ dựa trên dữ liệu `StoryQA` gửi kèm (dùng chung cho mọi engine).
    public string StoryQAPrompt(string focus)
    {
        var source = gameName.Length == 0 ? "a video game" : $"the video game \"{gameName}\"";
        var trimmedNote = translationNote.Trim();
        var note = trimmedNote.Length == 0 ? "" : $"Notes from the player about this game (relationships, names): {trimmedNote}\n";
        return $"You answer a player's questions about the story of {source}, using ONLY the story record in the user message. " +
               "The app built that record from the subtitles and journal screens the player has seen so far. The user message may contain: " +
               "STORY SO FAR, STORY PARTS, CHARACTERS (full details of the characters related to the question), ALL OTHER CHARACTERS " +
               "(name and role), LORE (places, factions, concepts), OTHER LORE ENTRIES (names only), SUBTITLE EXCERPTS (original lines " +
               "that mention the question's keywords, oldest first; a line may start with the speaker's name and a colon), PREVIOUS Q&A " +
               "(earlier turns of this conversation, for follow-up questions) and finally QUESTION.\n" +
               "Rules:\n" +
               $"- Answer in {targetName}, directly. For \"who / what / which\" questions, put each item on its own line starting with \"- \", " +
               "the name first, then a short note on how the record links it to the question (role, relation, what they did).\n" +
               "- Be complete: look through every block, including ALL OTHER CHARACTERS, LORE and SUBTITLE EXCERPTS. When asked who is in, " +
               "belongs to or is connected with a place or faction, list everyone and every group the record ties to it: rulers, " +
               "members, people who live there, come from there, serve or served it, fight for or against it, and its people or army.\n" +
               "- Use only the record. Never add facts, plot, backstory or future events from your own knowledge of the game (no spoilers). " +
               "When the record only hints at something, say that it is not certain.\n" +
               "- If the record has nothing relevant, say in one sentence that the record has no information about it yet, and mention the " +
               "closest related thing it does contain, if any.\n" +
               "- Keep character names and game terms as written in the record unless the glossary says otherwise.\n" +
               "- Plain text only: no headings, bold, tables or code fences.\n" +
               note + GlossaryBlock(focus);
    }

    /// Cập nhật cốt truyện game: một lần gọi trả về đoạn diễn biến mới, bài viết liền mạch và các nhân vật có thay đổi.
    public string StoryUpdatePrompt(string focus)
    {
        var source = gameName.Length == 0 ? "a video game" : $"the video game \"{gameName}\"";
        var trimmedNote = translationNote.Trim();
        var note = trimmedNote.Length == 0 ? "" : $"Notes from the player about this game (relationships, names): {trimmedNote}\n";
        return $"You keep a running story record for a player of {source}. The user sends four blocks: STORY SO FAR (the record you wrote " +
               "earlier; may be empty), KNOWN CHARACTERS (may be empty), KNOWN LORE (names of codex entries already recorded; may be empty) " +
               "and NEW LINES: subtitle lines in the order they appeared since the last update. A line may start with the speaker's name " +
               "and a colon. Lines starting with \"[Screen]\" are summaries of journal, quest or codex screens the player opened. " +
               "\"[…later…]\" marks a break in play time. OCR may contain small errors; infer the intent.\n" +
               "A \"[Screen]\" line is reference material, not an event. When it describes who a character is, or explains a place, a " +
               "faction, army or organisation, or a concept of the game world, it must go ONLY into \"characters\" (field \"journal\") or " +
               "\"lore\" below: never retell it in \"part\" or \"narrative\", and never write that the player opened or read a screen. Only a " +
               "\"[Screen]\" line that states something that happened in the story or the current objective may inform \"part\" and \"narrative\".\n" +
               $"Write in {targetName} and return JSON with:\n" +
               "- \"part\": {\"title\", \"summary\"} covering only what happens in NEW LINES. \"title\": 3–8 words. \"summary\": retell it as a clear " +
               "story: who is involved, what they say, want or decide, what is revealed, and how it ends; 2–4 sentences for a short exchange, " +
               "up to 3 short paragraphs for a long scene. If NEW LINES contain nothing of the story (menus, combat shouts, small talk, " +
               "or only reference screens), use null.\n" +
               "- \"narrative\": the whole story so far as one continuous text: STORY SO FAR extended with the new events and rewritten so it " +
               "reads as one retelling, in chronological order, in short paragraphs separated by a blank line. Keep every important earlier " +
               "event, name, reveal and decision; never drop the beginning. At most about 450 words: when it would be longer, tell older " +
               "events more briefly and recent ones in more detail. If nothing changes, return \"\".\n" +
               "- \"characters\": every named character who speaks or takes part in NEW LINES and is not yet listed in KNOWN CHARACTERS, " +
               "plus every known character about whom NEW LINES reveal something new or whose situation changes; [] if none. A character " +
               "counts as new whenever the name is missing from KNOWN CHARACTERS, even if the story treats them as familiar: always " +
               "include the protagonist and the companions travelling with them. Each is " +
               "{\"name\", \"role\", \"personality\", \"background\", \"relations\", \"status\", \"journal\"}, every field except \"journal\" at most " +
               "two short sentences. \"journal\" holds what a \"[Screen]\" line says about this character (their profile in the game's " +
               "journal or codex): keep all of its facts, in up to 4 sentences; \"\" when no screen describes them. A character described " +
               "only by a \"[Screen]\" line still belongs in \"characters\". " +
               "\"status\" is the character's current situation at the end of NEW LINES: where they are, their condition (alive, dead, " +
               "wounded, captured, missing, rescued…) and what they are doing or about to do; rewrite it whenever it changes. For a known " +
               "character, write the full updated text of each field you change and \"\" for fields that do not change. Use \"\" when " +
               "something is not known; never guess. Use names exactly as in KNOWN CHARACTERS and the glossary; if a new name is clearly " +
               "the same person as a known character, use the known name. Do not add unnamed speakers (Soldier, Guard) unless they " +
               "matter to the story.\n" +
               "- \"lore\": codex entries explained by \"[Screen]\" lines in NEW LINES: places, factions (armies, orders, nations, " +
               "organisations) and concepts (magic, creatures, items, historical events); [] if none. Each is {\"name\", \"kind\", " +
               "\"description\"}: \"name\" as written in the game (use the exact name from KNOWN LORE when it is the same entry); \"kind\" is " +
               "\"place\", \"faction\", \"concept\" or \"other\"; \"description\" keeps every fact the screen gives, in up to 5 sentences. " +
               "People go in \"characters\", not in \"lore\".\n" +
               "Stay faithful: use only STORY SO FAR and NEW LINES. Never add plot, backstory or future events from your own knowledge of " +
               "the game (no spoilers); never invent actions, gestures or feelings; when it is unclear who did something, keep it vague. " +
               "Never list the lines one by one; never give advice.\n" +
               "Keep character names and game terms as written unless the glossary says otherwise.\n" +
               note + GlossaryBlock(focus) + "\n" +
               "Reply with JSON only, no code fences and no other text, exactly in this shape (inside a string write a paragraph " +
               "break as \\n\\n, never a real line break, and use single quotes ‘…’ instead of double quotes):\n" +
               "{\"part\": {\"title\": \"…\", \"summary\": \"…\"}, \"narrative\": \"…\", \"characters\": [{\"name\": \"…\", \"role\": \"…\", \"personality\": \"…\", \"background\": \"…\", \"relations\": \"…\", \"status\": \"…\", \"journal\": \"…\"}], \"lore\": [{\"name\": \"…\", \"kind\": \"…\", \"description\": \"…\"}]}";
    }

    /// Gọi model với lời dặn và nội dung tuỳ ý (có thử model dự phòng như dịch màn hình).
    public Task<string> Generate(string system, string input, double timeout, CancellationToken ct = default, int maxOutputTokens = 4096, string? modelOverride = null)
    {
        if (string.IsNullOrEmpty(apiKey)) throw GeminiException.NoKey();
        var gen = new JsonObject { ["temperature"] = 0.4, ["max_output_tokens"] = maxOutputTokens };
        return SendWithFallback(system, input, gen, timeout, 3, ct, modelOverride);
    }

    // MARK: subtitle translate

    public Task<string> Translate(string text, IList<TranslationPair> context, CancellationToken ct = default) =>
        TranslateWith(text, context, null, ct);

    /// `modelOverride`: model riêng cho việc dịch phụ đề (Cài đặt → Dịch); null = model mặc định.
    public async Task<string> TranslateWith(string text, IList<TranslationPair> context, string? modelOverride, CancellationToken ct = default)
    {
        if (string.IsNullOrEmpty(apiKey)) throw GeminiException.NoKey();
        // Interactions API nhận một đoạn input: gộp các câu trước làm ngữ cảnh.
        var input = "";
        if (context.Count > 0)
        {
            input += "Previous lines of this conversation (context only, do not repeat them):\n";
            foreach (var p in context) input += $"EN: {p.source}\nTranslated: {p.target}\n";
            input += "\n";
        }
        input += "Translate this new line:\n" + text;
        var gen = new JsonObject { ["temperature"] = 0.2, ["max_output_tokens"] = 256 };
        var raw = await SendWithFallback(subtitleSystemPrompt, input, gen, timeout, 2, ct, modelOverride);
        var cleaned = Clean(raw);
        if (cleaned.Length == 0) throw GeminiException.Empty();
        return cleaned;
    }

    // MARK: screen analysis (JSON mode)

    public record AnalysisResult(string summary, Dictionary<int, string> translations);

    public async Task<AnalysisResult> Analyze(IList<string> lines, double timeout, CancellationToken ct = default, string? modelOverride = null)
    {
        if (string.IsNullOrEmpty(apiKey)) throw GeminiException.NoKey();
        var numbered = string.Join("\n", lines.Select((l, i) => $"{i + 1}. {l}"));
        var gen = new JsonObject { ["temperature"] = 0.3, ["max_output_tokens"] = 4096 };
        var system = analysisSystemPrompt + "\nReply with JSON only, no code fences and no other text, exactly in this shape:\n" +
                     "{\"summary\": \"…\", \"lines\": [{\"i\": 1, \"t\": \"…\"}, {\"i\": 2, \"t\": \"…\"}]}";
        var raw = await SendWithFallback(system, numbered, gen, timeout, 3, ct, modelOverride);
        // Lấy phần {...} (model đôi khi bọc trong ```json … ```).
        var obj = ParseObject(raw) ?? throw GeminiException.BadJSON();
        var summary = obj["summary"]?.GetValue<string>() ?? "";
        var map = new Dictionary<int, string>();
        if (obj["lines"] is JsonArray arr)
            foreach (var l in arr)
            {
                try
                {
                    var i = l?["i"]?.GetValue<int>(); var t = l?["t"]?.GetValue<string>();
                    if (i != null && t != null) map[i.Value] = t;
                }
                catch { }
            }
        return new AnalysisResult(TextUtils.Normalize(summary), map);
    }

    /// Phần {...} đầu tiên tới dấu } cuối cùng của câu trả lời, đọc thành JSON (null nếu không đọc được).
    public static JsonObject? ParseObject(string raw)
    {
        int a = raw.IndexOf('{'), b = raw.LastIndexOf('}');
        if (a < 0 || b <= a) return null;
        try { return JsonNode.Parse(raw[a..(b + 1)]) as JsonObject; } catch { return null; }
    }

    // MARK: transport

    /// Thử lần lượt các model; 503/404/timeout → model tiếp theo. Model thành công được "dính" 5 phút.
    /// `preferred`: model riêng của một việc (khác model mặc định) → thử nó trước rồi tới các model dự phòng, và không
    /// đụng tới trạng thái "dính" / "model không tồn tại" của model mặc định.
    async Task<string> SendWithFallback(string system, string input, JsonObject generation, double timeout, int maxAttempts, CancellationToken ct, string? preferred = null)
    {
        Exception lastErr = GeminiException.Empty();
        if (!string.IsNullOrEmpty(preferred) && preferred != model)
        {
            foreach (var pm in new[] { preferred }.Concat(fallbacks).Distinct().Take(maxAttempts))
            {
                try
                {
                    var res = await Send(pm, system, input, generation, timeout, ct);
                    if (pm != preferred) Log.Warn($"Gemini chuyển sang model dự phòng {pm} (model đã chọn: {preferred})");
                    return res;
                }
                catch (Exception ex) when (IsRetryable(ex))
                {
                    lastErr = ex;
                    Log.Warn($"Gemini {pm} lỗi ({Trunc(ex.Message, 60)}) → thử model khác");
                }
            }
            throw lastErr;
        }
        foreach (var m in CandidateModels(maxAttempts))
        {
            try
            {
                var outp = await Send(m, system, input, generation, timeout, ct);
                if (m != model && m != activeModel) Log.Warn($"Gemini chuyển sang model dự phòng {m} (model đã chọn: {model})");
                activeModel = m;
                activeUntil = DateTime.UtcNow.AddSeconds(300);
                lastError = null;
                return outp;
            }
            catch (Exception e) when (e is not OperationCanceledException || !ct.IsCancellationRequested)
            {
                lastErr = e;
                lastError = $"{m}: {e.Message}";
                if (m == model && e is GeminiException { kind: GeminiException.Kind.http, code: 404 }) chosenModelMissing = true;
                if (IsRetryable(e))
                {
                    Log.Warn($"Gemini {m} lỗi ({Trunc(e.Message, 60)}) → thử model khác");
                    if (m == activeModel) activeModel = null;
                    continue;
                }
                throw;
            }
        }
        throw lastErr;
    }

    static string Trunc(string s, int n) => s.Length > n ? s[..n] : s;

    async Task<string> Send(string model, string system, string input, JsonObject generation, double timeout, CancellationToken ct)
    {
        try { return await Request(model, system, input, generation, timeout, true, ct); }
        catch (GeminiException e) when (e.kind == GeminiException.Kind.http && e.code == 400 && e.Message.ToLowerInvariant().Contains("thinking"))
        {
            return await Request(model, system, input, generation, timeout, false, ct);
        }
    }

    /// Các key cho request này, bắt đầu từ key kế tiếp trong vòng; key đang nghỉ vì 429 bị bỏ qua (trừ khi mọi key đều nghỉ).
    List<string> KeysForRequest()
    {
        lock (keyLock)
        {
            var keys = apiKeys;
            if (keys.Count == 0) return new List<string>();
            int start = keyIndex % keys.Count;
            keyIndex = (start + 1) % keys.Count;
            var ordered = keys.Skip(start).Concat(keys.Take(start)).ToList();
            var now = DateTime.UtcNow;
            var ready = ordered.Where(k => !keyCooldown.TryGetValue(k, out var until) || until <= now).ToList();
            return ready.Count == 0 ? new List<string> { ordered[0] } : ready;
        }
    }

    /// Gửi bằng key kế tiếp; key nào bị 429 thì cho nghỉ và thử ngay key khác. Chỉ báo hết quota khi mọi key đều hết.
    async Task<string> Request(string model, string system, string input, JsonObject generation, double timeout, bool thinking, CancellationToken ct)
    {
        GeminiException limited = GeminiException.NoKey();
        foreach (var key in KeysForRequest())
        {
            try { return await Request(key, model, system, input, generation, timeout, thinking, ct); }
            catch (GeminiException e) when (e.kind == GeminiException.Kind.rateLimited)
            {
                lock (keyLock) keyCooldown[key] = DateTime.UtcNow.AddSeconds(e.retryAfter ?? 60);
                if (apiKeys.Count > 1) Log.Warn($"Gemini key …{(key.Length > 4 ? key[^4..] : key)} hết quota (429) → thử key khác");
                limited = e;
            }
        }
        throw limited;
    }

    /// POST /interactions (Gemini Interactions API): lời dặn ở `system_instruction`, nội dung ở `input`,
    /// kết quả là các bước `model_output` trong `steps` (bỏ qua bước `thought`).
    async Task<string> Request(string key, string model, string system, string input, JsonObject generation, double timeout, bool thinking, CancellationToken ct)
    {
        var gen = (JsonObject)generation.DeepClone();
        if (thinking) gen["thinking_level"] = "low";
        var body = new JsonObject
        {
            ["model"] = model, ["system_instruction"] = system, ["input"] = input, ["generation_config"] = gen,
        };
        using var req = new HttpRequestMessage(HttpMethod.Post, $"{baseURL}/interactions");
        req.Headers.Add("x-goog-api-key", key);
        req.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");

        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(TimeSpan.FromSeconds(timeout));
        HttpResponseMessage resp;
        string data;
        try
        {
            resp = await http.SendAsync(req, cts.Token);
            data = await resp.Content.ReadAsStringAsync(cts.Token);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested) { throw GeminiException.Timeout(); }
        int code = (int)resp.StatusCode;
        JsonObject? json = null;
        try { json = JsonNode.Parse(data) as JsonObject; } catch { }

        if (code == 429) throw GeminiException.RateLimited(RetryDelay(json));
        if (code < 200 || code >= 300)
        {
            var msg = json?["error"]?["message"]?.GetValue<string>() ?? data;
            throw GeminiException.Http(code, msg);
        }
        var sb = new StringBuilder();
        if (json?["steps"] is JsonArray steps)
            foreach (var st in steps)
            {
                if (Str(st?["type"]) != "model_output" || st?["content"] is not JsonArray content) continue;
                foreach (var c in content)
                    if (Str(c?["type"]) == "text" && Str(c?["text"]) is string s) sb.Append(s);
            }
        if (sb.Length == 0) throw GeminiException.Empty();
        return sb.ToString();
    }

    static string? Str(JsonNode? n) => n is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;

    static double? RetryDelay(JsonObject? json)
    {
        if (json?["error"]?["details"] is not JsonArray details) return null;
        foreach (var d in details)
        {
            var t = d?["@type"]?.GetValue<string>();
            var s = d?["retryDelay"]?.GetValue<string>();
            if (t != null && t.EndsWith("RetryInfo") && s != null &&
                double.TryParse(s.Trim('s'), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var v)) return v;
        }
        return null;
    }

    static string Clean(string s)
    {
        var t = TextUtils.Normalize(s);
        const string q = "\"“”'";
        if (t.Length >= 2 && q.Contains(t[0]) && q.Contains(t[^1])) t = t[1..^1];
        return t;
    }

    /// GET /models: các model hỗ trợ generateContent, ưu tiên flash/lite.
    public static async Task<List<string>> ListModels(string apiKey, string baseURL)
    {
        using var req = new HttpRequestMessage(HttpMethod.Get, $"{baseURL}/models?pageSize=200");
        req.Headers.Add("x-goog-api-key", apiKey);
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        var resp = await http.SendAsync(req, cts.Token);
        var data = await resp.Content.ReadAsStringAsync();
        JsonObject? json = null;
        try { json = JsonNode.Parse(data) as JsonObject; } catch { }
        int code = (int)resp.StatusCode;
        if (code < 200 || code >= 300) throw GeminiException.Http(code, json?["error"]?["message"]?.GetValue<string>() ?? "");
        var names = new List<string>();
        if (json?["models"] is JsonArray ms)
            foreach (var m in ms)
            {
                var n = m?["name"]?.GetValue<string>();
                if (n == null || m?["supportedGenerationMethods"] is not JsonArray methods) continue;
                if (!methods.Any(x => x?.GetValue<string>() == "generateContent")) continue;
                var id = n.Split('/').Last();
                if (id.Contains("tts") || id.Contains("image") || id.Contains("embedding") || id.Contains("live") || id.Contains("omni")) continue;
                names.Add(id);
            }
        names.Sort((a, b) =>
        {
            bool la = a.Contains("lite"), lb = b.Contains("lite");
            if (la != lb) return la ? -1 : 1;
            return string.CompareOrdinal(b, a);
        });
        return names;
    }

    /// Nút "Test key" trong Cài đặt.
    public static async Task<(bool ok, string message)> Test(string apiKey, string model)
    {
        var b = new GeminiBackend(apiKey, model, 10)
        {
            baseURL = AppSettings.shared.geminiBaseURL,
            targetName = AppSettings.shared.target.englishName,
        };
        try
        {
            var t0 = DateTime.UtcNow;
            var r = await b.Translate("Hello, how are you?", Array.Empty<TranslationPair>());
            return (true, $"{r}  ({(int)(DateTime.UtcNow - t0).TotalMilliseconds} ms)");
        }
        catch (Exception e) { return (false, e.Message); }
    }
}
