using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading.Tasks;

namespace ScreenTranslator;

/// Game mẫu: game kèm sẵn thuật ngữ, phong cách dịch, ghi chú cho AI và cài đặt tên người nói, để tạo nhanh một game.
/// Danh sách lấy từ server (GET /v1/games, sửa ở trang quản trị nên thêm game không cần build lại app), lưu cache ở
/// %APPDATA%\ScreenTranslator\games.json; chưa tải được lần nào thì dùng bản đóng kèm (thư mục glossaries/ cạnh exe).
/// Port từ GameCatalog.swift của bản macOS.
public static class GameCatalog
{
    public sealed class Term
    {
        public string term { get; set; } = "";
        public string? translation { get; set; }
    }

    public sealed class Group
    {
        public string group { get; set; } = "";
        public List<Term> entries { get; set; } = new();
    }

    public sealed class Game
    {
        public string id { get; set; } = "";
        public string name { get; set; } = "";
        public List<string> aliases { get; set; } = new();
        public string style { get; set; } = "auto";
        public string description { get; set; } = "";
        public string note { get; set; } = "";
        public bool showsSpeakerNames { get; set; } = true;
        public bool speakerAbove { get; set; }
        public List<string> speakers { get; set; } = new();
        public List<Group> glossary { get; set; } = new();

        [JsonIgnore]
        public TranslationStyle translationStyle => Enum.TryParse<TranslationStyle>(style, out var s) ? s : TranslationStyle.auto;

        /// Thuật ngữ dạng danh sách phẳng (bỏ trùng, không phân biệt hoa thường).
        [JsonIgnore]
        public List<GlossaryEntry> entries
        {
            get
            {
                var seen = new HashSet<string>();
                var outp = new List<GlossaryEntry>();
                foreach (var t in glossary.SelectMany(g => g.entries))
                {
                    var term = t.term.Trim();
                    if (term.Length == 0 || !seen.Add(term.ToLowerInvariant())) continue;
                    var tr = (t.translation ?? "").Trim();
                    outp.Add(new GlossaryEntry { term = term, translation = tr, keepAsIs = tr.Length == 0 });
                }
                return outp;
            }
        }

        /// Game mới tạo từ game mẫu: lấy luôn thuật ngữ, phong cách dịch, ghi chú cho AI và cài đặt tên người nói.
        public Profile MakeProfile(ProfileSource source = ProfileSource.external) => new()
        {
            name = name, source = source, glossary = entries, showsSpeakerNames = showsSpeakerNames, speakerAbove = speakerAbove,
            speakers = speakers.ToList(), translationStyle = translationStyle, translationNote = note,
        };
    }

    sealed class Cache
    {
        public string? etag { get; set; }
        public List<Game> games { get; set; } = new();
    }

    static readonly JsonSerializerOptions json = new() { PropertyNameCaseInsensitive = true };
    static readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(15) };
    static readonly object lk = new();
    static List<Game>? games;
    static string? etag;
    static string CachePath => AppPaths.File("games.json");
    /// Thư mục glossaries cạnh exe (bản single-file: thư mục giải nén tạm = AppContext.BaseDirectory).
    static string BundledDir => Path.Combine(AppContext.BaseDirectory, "glossaries");

    /// Danh sách game mẫu hiện có (cache của server, không có thì bản đóng kèm), xếp theo tên.
    public static List<Game> Games
    {
        get
        {
            lock (lk)
            {
                if (games == null)
                {
                    try
                    {
                        if (File.Exists(CachePath) && JsonSerializer.Deserialize<Cache>(File.ReadAllText(CachePath), json) is Cache c && c.games.Count > 0)
                        { games = Sorted(c.games); etag = c.etag; }
                    }
                    catch (Exception e) { Log.Warn($"Cache game mẫu lỗi: {e.Message}"); }
                    games ??= Sorted(Bundled());
                }
                return games;
            }
        }
    }

    static List<Game> Sorted(IEnumerable<Game> g) => g.OrderBy(x => x.name, StringComparer.CurrentCultureIgnoreCase).ToList();

    /// Bản đóng kèm app.
    public static List<Game> Bundled()
    {
        var outp = new List<Game>();
        try
        {
            if (!Directory.Exists(BundledDir)) return outp;
            foreach (var f in Directory.GetFiles(BundledDir, "*.json"))
            {
                try { if (JsonSerializer.Deserialize<Game>(File.ReadAllText(f), json) is Game g && g.name.Length > 0) outp.Add(g); }
                catch (Exception e) { Log.Warn($"Game mẫu {Path.GetFileName(f)} lỗi: {e.Message}"); }
            }
        }
        catch (Exception e) { Log.Warn($"Đọc glossaries lỗi: {e.Message}"); }
        return outp;
    }

    /// Game mẫu ứng với tên một game của người dùng (trùng tên hoặc tên gọi khác, không phân biệt hoa thường / dấu).
    public static Game? Named(string name)
    {
        var n = name.Trim();
        if (n.Length == 0) return null;
        bool Same(string a) => string.Compare(a, n, System.Globalization.CultureInfo.InvariantCulture,
            System.Globalization.CompareOptions.IgnoreCase | System.Globalization.CompareOptions.IgnoreNonSpace) == 0;
        var list = Games;
        return list.FirstOrDefault(g => Same(g.name)) ?? list.FirstOrDefault(g => g.aliases.Any(Same));
    }

    /// Tải danh sách mới từ server (gửi ETag nên không đổi thì không tải lại). Lỗi mạng thì giữ danh sách đang có.
    public static async Task Refresh()
    {
        if (RuntimeConfig.Server is not string server) return;
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, server + "/v1/games");
            string? tag;
            lock (lk) tag = etag;
            if (tag != null) req.Headers.TryAddWithoutValidation("If-None-Match", tag);
            using var resp = await http.SendAsync(req);
            if (resp.StatusCode == HttpStatusCode.NotModified) return;
            if (!resp.IsSuccessStatusCode) { Log.Warn($"Game mẫu: server trả HTTP {(int)resp.StatusCode}"); return; }
            var body = await resp.Content.ReadAsStringAsync();
            var fresh = JsonSerializer.Deserialize<Cache>(body, json)?.games ?? new();
            // Server chưa có game nào (chưa nạp danh sách) → giữ bản đang có.
            if (fresh.Count == 0) return;
            var newTag = resp.Headers.ETag?.ToString();
            File.WriteAllText(CachePath, JsonSerializer.Serialize(new Cache { etag = newTag, games = fresh }));
            lock (lk) { games = Sorted(fresh); etag = newTag; }
            Log.Info($"Game mẫu: đã cập nhật {fresh.Count} game từ server");
        }
        catch (Exception e) { Log.Warn($"Game mẫu: không tải được danh sách từ server: {e.Message}"); }
    }
}
