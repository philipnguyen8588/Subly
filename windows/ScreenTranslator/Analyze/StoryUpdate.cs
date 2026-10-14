using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Text.Json.Nodes;

namespace ScreenTranslator;

/// Kết quả một lần model cập nhật cốt truyện game: đoạn diễn biến mới, bài viết liền mạch, các nhân vật có thay đổi
/// và các mục bách khoa (địa danh, thế lực, khái niệm) lấy từ màn hình nhật ký.
/// Việc đọc và gộp là hàm thuần, để một phản hồi hỏng hoặc bị cắt cụt không bao giờ xoá mất phần đã lưu.
public sealed class StoryUpdate
{
    public string partTitle = "";
    public string partSummary = "";
    public string narrative = "";
    public List<StoryCharacter> characters = new();
    public List<StoryLore> lore = new();

    /// Đọc {"part": {"title", "summary"} | null, "narrative", "characters": [...], "lore": [...]} (model đôi khi bọc trong ```json … ```).
    public static StoryUpdate Parse(string raw)
    {
        var obj = GeminiBackend.ParseObject(raw) ?? GeminiBackend.ParseObject(EscapeControls(raw));
        if (obj == null || !(obj.ContainsKey("part") || obj.ContainsKey("narrative") || obj.ContainsKey("characters") || obj.ContainsKey("summary") || obj.ContainsKey("lore")))
            throw new TranslationRouter.StoryException("Model trả về dữ liệu không đọc được");
        static string Str(JsonNode? n) { try { return TextUtils.Normalize(n?.GetValue<string>() ?? ""); } catch { return ""; } }
        static string Paragraphs(JsonNode? n) { try { return TranslationRouter.CleanParagraphs(n?.GetValue<string>() ?? ""); } catch { return ""; } }
        var u = new StoryUpdate();
        // Chấp nhận cả dạng phẳng {"title", "summary"} khi model bỏ lớp "part".
        var part = obj["part"] as JsonObject ?? obj;
        u.partTitle = Str(part["title"]);
        u.partSummary = Paragraphs(part["summary"]);
        u.narrative = Paragraphs(obj["narrative"]);
        if (obj["characters"] is JsonArray arr)
            foreach (var item in arr)
            {
                if (item is not JsonObject c) continue;
                var name = Str(c["name"]);
                if (name.Length == 0) continue;
                u.characters.Add(new StoryCharacter
                {
                    name = name, role = Str(c["role"]), personality = Str(c["personality"]),
                    background = Str(c["background"]), relations = Str(c["relations"]), status = Str(c["status"]),
                    journal = Paragraphs(c["journal"]),
                });
            }
        if (obj["lore"] is JsonArray lore)
            foreach (var item in lore)
            {
                if (item is not JsonObject l) continue;
                var name = Str(l["name"]); var text = Paragraphs(l["description"]);
                if (name.Length == 0 || text.Length == 0) continue;
                var kind = Str(l["kind"]).ToLowerInvariant();
                u.lore.Add(new StoryLore { name = name, kind = StoryLore.kinds.Any(k => k.id == kind) ? kind : "other", description = text });
            }
        return u;
    }

    /// Model hay xuống dòng thật giữa bài viết nhiều đoạn, trong khi JSON đòi viết thành \n → đổi các ký tự điều khiển
    /// nằm trong chuỗi thành dạng thoát để vẫn đọc được.
    public static string EscapeControls(string json)
    {
        var sb = new StringBuilder(json.Length + 16);
        bool inString = false, escaped = false;
        foreach (var ch in json)
        {
            if (!inString) { if (ch == '"') inString = true; sb.Append(ch); }
            else if (escaped) { escaped = false; sb.Append(ch); }
            else if (ch == '\\') { escaped = true; sb.Append(ch); }
            else if (ch == '"') { inString = false; sb.Append(ch); }
            else if (ch == '\n') sb.Append("\\n");
            else if (ch == '\r') continue;
            else if (ch == '\t') sb.Append("\\t");
            else sb.Append(ch);
        }
        return sb.ToString();
    }

    /// Khoá so tên nhân vật: không phân biệt hoa thường và dấu.
    public static string NameKey(string s)
    {
        var sb = new StringBuilder();
        foreach (var ch in s.Trim().Normalize(NormalizationForm.FormD))
            if (CharUnicodeInfo.GetUnicodeCategory(ch) != UnicodeCategory.NonSpacingMark) sb.Append(ch);
        return sb.ToString().Normalize(NormalizationForm.FormC).ToLowerInvariant();
    }

    /// Bài viết mới thay bài cũ, trừ khi nó rỗng hoặc ngắn bất thường (bị cắt cụt): khi đó giữ bài cũ và nối đoạn mới vào.
    public static string MergeNarrative(string old, StoryUpdate u)
    {
        bool truncated = old.Length >= 600 && u.narrative.Length < old.Length / 2;
        if (u.narrative.Length > 0 && !truncated) return u.narrative;
        if (u.partSummary.Length == 0) return old;
        return old.Length == 0 ? u.partSummary : old + "\n\n" + u.partSummary;
    }

    /// Trường có nội dung thay trường cũ, trường rỗng giữ nguyên; tên chưa có thì thêm vào cuối. Model không xoá được nhân vật.
    /// Giới hạn chỉ để chặn dữ liệu hỏng: game nhập vai dài có cả trăm nhân vật có tên (giới hạn cũ 40 làm mất nhân vật mới).
    public static List<StoryCharacter> MergeCharacters(List<StoryCharacter> old, List<StoryCharacter> add, int limit = 300)
    {
        var outp = old.Select(c => new StoryCharacter
        {
            name = c.name, role = c.role, personality = c.personality, background = c.background, relations = c.relations,
            status = c.status, journal = c.journal, seen = c.seen,
        }).ToList();
        foreach (var c in add)
        {
            var hit = outp.FirstOrDefault(o => NameKey(o.name) == NameKey(c.name));
            if (hit != null)
            {
                if (c.role.Length > 0) hit.role = c.role;
                if (c.personality.Length > 0) hit.personality = c.personality;
                if (c.background.Length > 0) hit.background = c.background;
                if (c.relations.Length > 0) hit.relations = c.relations;
                if (c.status.Length > 0) hit.status = c.status;
                if (c.journal.Length > 0) hit.journal = c.journal;
            }
            else if (outp.Count < limit) outp.Add(c);
        }
        return outp;
    }

    /// Ghi thời điểm xuất hiện gần nhất cho những nhân vật có tên trong các câu mới (`text`) hoặc được model nhắc tới,
    /// để danh sách nhân vật xếp được theo "mới xuất hiện gần đây".
    public static void MarkSeen(List<StoryCharacter> characters, string text, List<StoryCharacter> mentioned, double unixTime)
    {
        var haystack = NameKey(text);
        var named = mentioned.Select(c => NameKey(c.name)).ToHashSet();
        foreach (var c in characters)
        {
            var key = NameKey(c.name);
            if (named.Contains(key) || haystack.Contains(key)) c.seen = Math.Max(c.seen, unixTime);
        }
    }

    /// Mục bách khoa: mô tả mới thay mô tả cũ của mục cùng tên, tên chưa có thì thêm vào cuối.
    public static List<StoryLore> MergeLore(List<StoryLore> old, List<StoryLore> add, int limit = 500)
    {
        var outp = old.Select(l => new StoryLore { name = l.name, kind = l.kind, description = l.description }).ToList();
        foreach (var l in add)
        {
            var hit = outp.FirstOrDefault(o => NameKey(o.name) == NameKey(l.name));
            if (hit != null)
            {
                hit.description = l.description;
                if (l.kind != "other") hit.kind = l.kind;
            }
            else if (outp.Count < limit) outp.Add(l);
        }
        return outp;
    }
}
