using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Text.Json.Nodes;

namespace ScreenTranslator;

/// Kết quả một lần model cập nhật cốt truyện game: đoạn diễn biến mới, bài viết liền mạch, các nhân vật có thay đổi.
/// Việc đọc và gộp là hàm thuần, để một phản hồi hỏng hoặc bị cắt cụt không bao giờ xoá mất phần đã lưu.
public sealed class StoryUpdate
{
    public string partTitle = "";
    public string partSummary = "";
    public string narrative = "";
    public List<StoryCharacter> characters = new();

    /// Đọc {"part": {"title", "summary"} | null, "narrative", "characters": [...]} (model đôi khi bọc trong ```json … ```).
    public static StoryUpdate Parse(string raw)
    {
        var obj = GeminiBackend.ParseObject(raw) ?? GeminiBackend.ParseObject(EscapeControls(raw));
        if (obj == null || !(obj.ContainsKey("part") || obj.ContainsKey("narrative") || obj.ContainsKey("characters") || obj.ContainsKey("summary")))
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
                });
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
    public static List<StoryCharacter> MergeCharacters(List<StoryCharacter> old, List<StoryCharacter> add, int limit = 40)
    {
        var outp = old.Select(c => new StoryCharacter
        {
            name = c.name, role = c.role, personality = c.personality, background = c.background, relations = c.relations,
            status = c.status,
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
            }
            else if (outp.Count < limit) outp.Add(c);
        }
        return outp;
    }
}
