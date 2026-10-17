using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace ScreenTranslator;

public record TranslationEntry(long id, DateTime timestamp, string regionName, string source, string translated,
                               string backend, int latencyMs, RegionKind kind, string targetLang, string profile = "");

public class AnalysisLine
{
    public int id { get; set; }
    public string source { get; set; } = "";
    public string target { get; set; } = "";
}

/// Một khối chữ đã dịch trên ảnh chụp: toạ độ là tỉ lệ 0...1 của ảnh, gốc trên-trái.
public class ShotItem
{
    public int id { get; set; }
    public double x { get; set; }
    public double y { get; set; }
    public double w { get; set; }
    public double h { get; set; }
    public int lines { get; set; }
    public string source { get; set; } = "";
    public string target { get; set; } = "";
}

public class ScreenAnalysis
{
    public long id;
    public DateTime timestamp;
    public string regionName = "";
    public string summary = "";
    public List<AnalysisLine> lines = new();
    public string backend = "";
    public int latencyMs;
    public string profile = "";
    /// Vị trí từng khối chữ trên ảnh chụp (rỗng với mục cũ).
    public List<ShotItem> items = new();
    public int imageWidth, imageHeight;
    /// Còn file ảnh hay không: chỉ `HistoryStore.maxShots` ảnh mới nhất được giữ, mục cũ hơn chỉ còn chữ.
    public bool hasImage;
}

/// Một lần người dùng chọn nhiều câu phụ đề trong nhật ký và bấm "Tóm tắt". Giữ kèm các câu đã chọn để đọc lại được
/// cả khi nhật ký phụ đề đã bị xoá.
public class StorySummary
{
    public long id;
    public DateTime timestamp;
    public string profile = "";
    public string title = "";
    public string summary = "";
    public List<AnalysisLine> lines = new();
    /// Thời điểm câu đầu và câu cuối của đoạn được tóm tắt.
    public DateTime from, to;
    public string backend = "";
    public int latencyMs;
}

/// Một nhân vật trong mục "Cốt truyện": do model viết và bổ sung dần qua mỗi lần cập nhật.
/// Tên khoá JSON giống hệt bản macOS vì hai bản dùng chung file history.sqlite.
public class StoryCharacter
{
    public string name { get; set; } = "";
    public string role { get; set; } = "";
    public string personality { get; set; } = "";
    public string background { get; set; } = "";
    public string relations { get; set; } = "";
    /// Tình trạng hiện tại (đang ở đâu, còn sống / bị bắt / bị thương, đang làm gì): viết lại mỗi khi có thay đổi.
    public string status { get; set; } = "";
    /// Hồ sơ nhân vật chép từ màn hình nhật ký / bách khoa của game mà người chơi đã mở và dịch.
    public string journal { get; set; } = "";
    /// Thời điểm (giây Unix) của những câu phụ đề gần nhất có nhân vật này; 0 = chưa ghi nhận (dữ liệu cũ).
    public double seen { get; set; }
}

/// Một mục "Bách khoa" của cốt truyện: địa danh, thế lực / đội quân, khái niệm của thế giới game, lấy từ các màn hình
/// nhật ký / bách khoa người chơi đã dịch. Tên khoá JSON giống hệt bản macOS.
public class StoryLore
{
    public string name { get; set; } = "";
    /// "place" (địa danh), "faction" (thế lực, đội quân, tổ chức), "concept" (khái niệm, sự kiện, vật phẩm) hoặc "other".
    public string kind { get; set; } = "other";
    public string description { get; set; } = "";

    public static readonly (string id, string label)[] kinds = { ("place", "Địa danh"), ("faction", "Thế lực"), ("concept", "Khái niệm"), ("other", "Khác") };
    [System.Text.Json.Serialization.JsonIgnore] public string kindLabel => kinds.FirstOrDefault(k => k.id == kind).label ?? "Khác";
}

/// Cốt truyện của một game: bài viết liền mạch + danh sách nhân vật, kèm con trỏ tới dòng nhật ký cuối đã đưa vào.
public class GameStory
{
    public string profile = "";
    public string narrative = "";
    public List<StoryCharacter> characters = new();
    public List<StoryLore> lore = new();
    public long lastEntryID, lastAnalysisID;
    public DateTime updated;
    public string backend = "";
}

/// Một đoạn diễn biến trong dòng thời gian của cốt truyện (mỗi lần cập nhật thêm một đoạn).
public class StoryPart
{
    public long id;
    public DateTime timestamp;
    public string profile = "";
    public string title = "";
    public string summary = "";
    public DateTime from, to;
    public long entryFrom, entryTo;
    public int lineCount;
    public string backend = "";
    public int latencyMs;
}

/// Lịch sử dịch + phân tích màn hình, SQLite (cùng schema với bản macOS). Mỗi dòng gắn với một game (profile);
/// `entries` / `analyses` chỉ chứa dữ liệu của game đang chọn và tự nạp lại khi đổi game. Dùng trên UI thread.
public sealed class HistoryStore
{
    public static readonly HistoryStore shared = new();

    /// mới nhất trước
    public List<TranslationEntry> entries { get; private set; } = new();
    public List<ScreenAnalysis> analyses { get; private set; } = new();
    public List<StorySummary> summaries { get; private set; } = new();
    public GameStory? story { get; private set; }
    public List<StoryPart> storyParts { get; private set; } = new();
    /// Game (UUID của profile) mà `entries` / `analyses` đang chứa.
    public string scope { get; private set; } = "";
    /// Số dòng có từ trước khi nhật ký được tách theo game (không gắn với game nào).
    public int legacyCount { get; private set; }

    public event Action? Changed;
    public event Action<TranslationEntry>? EntryAdded;
    public event Action? EntriesCleared;
    public event Action<ScreenAnalysis>? AnalysisAdded;
    /// Cốt truyện của game đang chọn vừa đổi (cập nhật, xoá, đổi game).
    public event Action? StoryChanged;

    readonly SqliteConnection db;
    const int maxInMemory = 2000, maxAnalyses = 300;
    /// Số ảnh chụp "dịch màn hình" được giữ trên đĩa cho mỗi game.
    public const int maxShots = 200;
    public static string ShotPath(long id) => Path.Combine(AppPaths.Shots, $"{id}.jpg");
    readonly object lk = new();

    HistoryStore()
    {
        SQLitePCL.Batteries_V2.Init();
        db = new SqliteConnection($"Data Source={AppPaths.File("history.sqlite")}");
        try { db.Open(); }
        catch (Exception e)
        {
            Log.Error($"SQLite open failed: {e.Message}");
            db = new SqliteConnection("Data Source=:memory:");
            db.Open();
        }
        Exec("""
        CREATE TABLE IF NOT EXISTS history(
            id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, region TEXT NOT NULL,
            source TEXT NOT NULL, translated TEXT NOT NULL, backend TEXT NOT NULL, latency INTEGER NOT NULL);
        CREATE INDEX IF NOT EXISTS history_ts ON history(ts);
        CREATE TABLE IF NOT EXISTS analyses(
            id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, region TEXT NOT NULL,
            thumbnail BLOB, summary TEXT NOT NULL, lines TEXT NOT NULL, backend TEXT NOT NULL, latency INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS summaries(
            id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, profile TEXT NOT NULL, title TEXT NOT NULL,
            summary TEXT NOT NULL, lines TEXT NOT NULL, t_from REAL NOT NULL, t_to REAL NOT NULL,
            backend TEXT NOT NULL, latency INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS story(
            profile TEXT PRIMARY KEY, narrative TEXT NOT NULL DEFAULT '', characters TEXT NOT NULL DEFAULT '[]',
            last_entry_id INTEGER NOT NULL DEFAULT 0, last_analysis_id INTEGER NOT NULL DEFAULT 0,
            updated REAL NOT NULL DEFAULT 0, backend TEXT NOT NULL DEFAULT '');
        CREATE TABLE IF NOT EXISTS story_parts(
            id INTEGER PRIMARY KEY AUTOINCREMENT, profile TEXT NOT NULL, ts REAL NOT NULL, title TEXT NOT NULL,
            summary TEXT NOT NULL, t_from REAL NOT NULL, t_to REAL NOT NULL,
            entry_from INTEGER NOT NULL, entry_to INTEGER NOT NULL, line_count INTEGER NOT NULL,
            backend TEXT NOT NULL, latency INTEGER NOT NULL);
        CREATE INDEX IF NOT EXISTS story_parts_profile ON story_parts(profile, id);
        PRAGMA journal_mode=WAL;
        """);
        if (!Columns("story").Contains("lore")) Exec("ALTER TABLE story ADD COLUMN lore TEXT NOT NULL DEFAULT '[]'");
        if (!Columns("history").Contains("kind")) Exec("ALTER TABLE history ADD COLUMN kind TEXT NOT NULL DEFAULT 'subtitle'");
        if (!Columns("history").Contains("target")) Exec("ALTER TABLE history ADD COLUMN target TEXT NOT NULL DEFAULT 'vi'");
        if (!Columns("history").Contains("profile")) Exec("ALTER TABLE history ADD COLUMN profile TEXT NOT NULL DEFAULT ''");
        if (!Columns("analyses").Contains("profile"))
        {
            Exec("ALTER TABLE analyses ADD COLUMN profile TEXT NOT NULL DEFAULT ''");
            Exec("ALTER TABLE analyses ADD COLUMN items TEXT NOT NULL DEFAULT '[]'");
            Exec("ALTER TABLE analyses ADD COLUMN iw INTEGER NOT NULL DEFAULT 0");
            Exec("ALTER TABLE analyses ADD COLUMN ih INTEGER NOT NULL DEFAULT 0");
        }
        scope = ProfileKey(AppSettings.shared.activeProfile.id);
        entries = LoadEntries(scope);
        analyses = LoadAnalyses(scope);
        summaries = LoadSummaries(scope);
        story = LoadStory(scope);
        storyParts = LoadStoryParts(scope);
        legacyCount = Count("SELECT (SELECT COUNT(*) FROM history WHERE profile = '') + (SELECT COUNT(*) FROM analyses WHERE profile = '')");
        // Đổi game (ở bất kỳ đâu trong app) → nạp lại nhật ký của game mới.
        AppSettings.shared.Changed += key =>
        {
            if (key is "activeProfileID" or "profiles" or "activeProfile")
                App.RunOnUI(FollowActiveProfile);
        };
    }

    /// UUID dạng chữ HOA như Swift (`uuidString`), để file history.sqlite dùng chung được giữa hai bản.
    public static string ProfileKey(Guid id) => id.ToString().ToUpperInvariant();

    void FollowActiveProfile()
    {
        var active = ProfileKey(AppSettings.shared.activeProfile.id);
        if (active == scope) return;
        scope = active;
        entries = LoadEntries(active);
        analyses = LoadAnalyses(active);
        summaries = LoadSummaries(active);
        story = LoadStory(active);
        storyParts = LoadStoryParts(active);
        StoryChanged?.Invoke();
        Changed?.Invoke();
    }

    int Count(string sql)
    {
        lock (lk)
        {
            using var cmd = db.CreateCommand();
            cmd.CommandText = sql;
            try { return Convert.ToInt32(cmd.ExecuteScalar() ?? 0); } catch { return 0; }
        }
    }

    /// Dòng cũ không gắn với game nào (có từ trước khi nhật ký được tách theo game).
    public List<TranslationEntry> LegacyEntries() => LoadEntries("");
    public List<ScreenAnalysis> LegacyAnalyses() => LoadAnalyses("");
    public void ClearLegacy()
    {
        Exec("DELETE FROM history WHERE profile = ''; DELETE FROM analyses WHERE profile = '';");
        legacyCount = 0;
        Changed?.Invoke();
    }

    // MARK: helpers
    void Exec(string sql, params (string, object?)[] args)
    {
        lock (lk)
        {
            try
            {
                using var cmd = db.CreateCommand();
                cmd.CommandText = sql;
                foreach (var (k, v) in args) cmd.Parameters.AddWithValue(k, v ?? DBNull.Value);
                cmd.ExecuteNonQuery();
            }
            catch (Exception e) { Log.Error($"SQLite: {e.Message}"); }
        }
    }

    List<string> Columns(string table)
    {
        var outp = new List<string>();
        lock (lk)
        {
            using var cmd = db.CreateCommand();
            cmd.CommandText = $"PRAGMA table_info({table})";
            using var r = cmd.ExecuteReader();
            while (r.Read()) outp.Add(r.GetString(1));
        }
        return outp;
    }

    static DateTime FromUnix(double ts) => DateTimeOffset.FromUnixTimeMilliseconds((long)(ts * 1000)).LocalDateTime;
    static double ToUnix(DateTime t) => new DateTimeOffset(t).ToUnixTimeMilliseconds() / 1000.0;

    // MARK: history
    List<TranslationEntry> LoadEntries(string profile)
    {
        var outp = new List<TranslationEntry>();
        lock (lk)
        {
            using var cmd = db.CreateCommand();
            cmd.CommandText = "SELECT id, ts, region, source, translated, backend, latency, kind, target, profile FROM history WHERE profile = $p ORDER BY id DESC LIMIT $n";
            cmd.Parameters.AddWithValue("$p", profile);
            cmd.Parameters.AddWithValue("$n", maxInMemory);
            using var r = cmd.ExecuteReader();
            while (r.Read())
                outp.Add(new TranslationEntry(r.GetInt64(0), FromUnix(r.GetDouble(1)), r.GetString(2), r.GetString(3), r.GetString(4),
                    r.GetString(5), r.GetInt32(6), Enum.TryParse<RegionKind>(r.GetString(7), out var k) ? k : RegionKind.subtitle,
                    r.GetString(8), r.GetString(9)));
        }
        return outp;
    }

    public void Add(string region, string source, string translated, BackendKind backend, int ms,
                    RegionKind kind, string target, string profile)
    {
        var now = DateTime.Now;
        long id;
        lock (lk)
        {
            using var cmd = db.CreateCommand();
            cmd.CommandText = "INSERT INTO history(ts, region, source, translated, backend, latency, kind, target, profile) VALUES($ts,$r,$s,$t,$b,$l,$k,$g,$p); SELECT last_insert_rowid();";
            cmd.Parameters.AddWithValue("$ts", ToUnix(now));
            cmd.Parameters.AddWithValue("$r", region);
            cmd.Parameters.AddWithValue("$s", source);
            cmd.Parameters.AddWithValue("$t", translated);
            cmd.Parameters.AddWithValue("$b", backend.ToString());
            cmd.Parameters.AddWithValue("$l", ms);
            cmd.Parameters.AddWithValue("$k", kind.ToString());
            cmd.Parameters.AddWithValue("$g", target);
            cmd.Parameters.AddWithValue("$p", profile);
            try { id = Convert.ToInt64(cmd.ExecuteScalar()); }
            catch (Exception e) { Log.Error($"SQLite insert: {e.Message}"); return; }
        }
        if (profile != scope) return;
        var entry = new TranslationEntry(id, now, region, source, translated, backend.ToString(), ms, kind, target, profile);
        entries.Insert(0, entry);
        if (entries.Count > maxInMemory) entries.RemoveRange(maxInMemory, entries.Count - maxInMemory);
        EntryAdded?.Invoke(entry);
        Changed?.Invoke();
    }

    /// Xoá nhật ký phụ đề của game đang chọn.
    public void Clear()
    {
        Exec("DELETE FROM history WHERE profile = $p;", ("$p", scope));
        entries.Clear();
        EntriesCleared?.Invoke();
        Changed?.Invoke();
    }

    // MARK: analyses
    List<ScreenAnalysis> LoadAnalyses(string profile)
    {
        var outp = new List<ScreenAnalysis>();
        lock (lk)
        {
            using var cmd = db.CreateCommand();
            cmd.CommandText = "SELECT id, ts, region, summary, lines, backend, latency, profile, items, iw, ih FROM analyses WHERE profile = $p ORDER BY id DESC LIMIT $n";
            cmd.Parameters.AddWithValue("$p", profile);
            cmd.Parameters.AddWithValue("$n", maxAnalyses);
            using var r = cmd.ExecuteReader();
            while (r.Read()) outp.Add(AnalysisRow(r));
        }
        return outp;
    }

    /// Một dòng `SELECT id, ts, region, summary, lines, backend, latency, profile, items, iw, ih FROM analyses`.
    static ScreenAnalysis AnalysisRow(SqliteDataReader r)
    {
        var id = r.GetInt64(0);
        List<AnalysisLine> lines; List<ShotItem> items;
        try { lines = JsonSerializer.Deserialize<List<AnalysisLine>>(r.GetString(4)) ?? new(); } catch { lines = new(); }
        try { items = JsonSerializer.Deserialize<List<ShotItem>>(r.GetString(8)) ?? new(); } catch { items = new(); }
        return new ScreenAnalysis
        {
            id = id, timestamp = FromUnix(r.GetDouble(1)), regionName = r.GetString(2), summary = r.GetString(3), lines = lines,
            backend = r.GetString(5), latencyMs = r.GetInt32(6), profile = r.GetString(7), items = items,
            imageWidth = r.GetInt32(9), imageHeight = r.GetInt32(10), hasImage = File.Exists(ShotPath(id)),
        };
    }

    /// `image`: ảnh chụp màn hình game; được thu nhỏ + nén JPEG rồi lưu ra file, chỉ giữ `maxShots` ảnh mới nhất.
    public ScreenAnalysis AddAnalysis(string region, Frame? image, List<ShotItem> items, string summary, List<AnalysisLine> lines,
                                      BackendKind backend, int ms, string profile)
    {
        var now = DateTime.Now;
        var small = image?.Downscale(1600);
        long id;
        lock (lk)
        {
            using var cmd = db.CreateCommand();
            cmd.CommandText = "INSERT INTO analyses(ts, region, summary, lines, backend, latency, profile, items, iw, ih) VALUES($ts,$r,$s,$l,$b,$ms,$p,$i,$w,$h); SELECT last_insert_rowid();";
            cmd.Parameters.AddWithValue("$ts", ToUnix(now));
            cmd.Parameters.AddWithValue("$r", region);
            cmd.Parameters.AddWithValue("$s", summary);
            cmd.Parameters.AddWithValue("$l", JsonSerializer.Serialize(lines));
            cmd.Parameters.AddWithValue("$b", backend.ToString());
            cmd.Parameters.AddWithValue("$ms", ms);
            cmd.Parameters.AddWithValue("$p", profile);
            cmd.Parameters.AddWithValue("$i", JsonSerializer.Serialize(items));
            cmd.Parameters.AddWithValue("$w", small?.Width ?? 0);
            cmd.Parameters.AddWithValue("$h", small?.Height ?? 0);
            try { id = Convert.ToInt64(cmd.ExecuteScalar()); }
            catch (Exception e) { Log.Error($"SQLite insert analysis: {e.Message}"); id = 0; }
        }
        bool saved = false;
        if (small != null && id > 0)
        {
            try { File.WriteAllBytes(ShotPath(id), small.ToJpeg(60)); saved = true; }
            catch (Exception e) { Log.Error($"Lưu ảnh lỗi: {e.Message}"); }
        }
        var a = new ScreenAnalysis
        {
            id = id, timestamp = now, regionName = region, summary = summary, lines = lines, backend = backend.ToString(), latencyMs = ms,
            profile = profile, items = items, imageWidth = small?.Width ?? 0, imageHeight = small?.Height ?? 0, hasImage = saved,
        };
        if (profile == scope)
        {
            analyses.Insert(0, a);
            if (analyses.Count > maxAnalyses) analyses.RemoveRange(maxAnalyses, analyses.Count - maxAnalyses);
        }
        PruneShots(profile);
        AnalysisAdded?.Invoke(a);
        Changed?.Invoke();
        return a;
    }

    /// Mỗi game giữ `maxShots` ảnh mới nhất: xoá file ảnh của các mục cũ hơn, phần chữ vẫn còn trong nhật ký.
    void PruneShots(string profile)
    {
        var drop = new HashSet<long>();
        lock (lk)
        {
            using var cmd = db.CreateCommand();
            cmd.CommandText = "SELECT id FROM analyses WHERE profile = $p ORDER BY id DESC LIMIT -1 OFFSET $o";
            cmd.Parameters.AddWithValue("$p", profile);
            cmd.Parameters.AddWithValue("$o", maxShots);
            using var r = cmd.ExecuteReader();
            while (r.Read()) drop.Add(r.GetInt64(0));
        }
        foreach (var id in drop) { try { File.Delete(ShotPath(id)); } catch { } }
        foreach (var a in analyses) if (drop.Contains(a.id)) a.hasImage = false;
    }

    /// Xoá lịch sử dịch màn hình (kèm ảnh) của game đang chọn.
    public void ClearAnalyses()
    {
        foreach (var a in LoadAnalyses(scope)) { try { File.Delete(ShotPath(a.id)); } catch { } }
        Exec("DELETE FROM analyses WHERE profile = $p;", ("$p", scope));
        analyses.Clear();
        Changed?.Invoke();
    }

    // MARK: summaries
    List<StorySummary> LoadSummaries(string profile)
    {
        var outp = new List<StorySummary>();
        lock (lk)
        {
            using var cmd = db.CreateCommand();
            cmd.CommandText = "SELECT id, ts, profile, title, summary, lines, t_from, t_to, backend, latency FROM summaries WHERE profile = $p ORDER BY id DESC";
            cmd.Parameters.AddWithValue("$p", profile);
            using var r = cmd.ExecuteReader();
            while (r.Read())
            {
                List<AnalysisLine> lines;
                try { lines = JsonSerializer.Deserialize<List<AnalysisLine>>(r.GetString(5)) ?? new(); } catch { lines = new(); }
                outp.Add(new StorySummary
                {
                    id = r.GetInt64(0), timestamp = FromUnix(r.GetDouble(1)), profile = r.GetString(2), title = r.GetString(3),
                    summary = r.GetString(4), lines = lines, from = FromUnix(r.GetDouble(6)), to = FromUnix(r.GetDouble(7)),
                    backend = r.GetString(8), latencyMs = r.GetInt32(9),
                });
            }
        }
        return outp;
    }

    public StorySummary AddSummary(string title, string summary, List<AnalysisLine> lines, DateTime from, DateTime to,
                                   BackendKind backend, int ms, string profile)
    {
        var now = DateTime.Now;
        long id;
        lock (lk)
        {
            using var cmd = db.CreateCommand();
            cmd.CommandText = "INSERT INTO summaries(ts, profile, title, summary, lines, t_from, t_to, backend, latency) VALUES($ts,$p,$t,$s,$l,$f,$to,$b,$ms); SELECT last_insert_rowid();";
            cmd.Parameters.AddWithValue("$ts", ToUnix(now));
            cmd.Parameters.AddWithValue("$p", profile);
            cmd.Parameters.AddWithValue("$t", title);
            cmd.Parameters.AddWithValue("$s", summary);
            cmd.Parameters.AddWithValue("$l", JsonSerializer.Serialize(lines));
            cmd.Parameters.AddWithValue("$f", ToUnix(from));
            cmd.Parameters.AddWithValue("$to", ToUnix(to));
            cmd.Parameters.AddWithValue("$b", backend.ToString());
            cmd.Parameters.AddWithValue("$ms", ms);
            try { id = Convert.ToInt64(cmd.ExecuteScalar()); }
            catch (Exception e) { Log.Error($"SQLite insert summary: {e.Message}"); id = 0; }
        }
        var s = new StorySummary
        {
            id = id, timestamp = now, profile = profile, title = title, summary = summary, lines = lines,
            from = from, to = to, backend = backend.ToString(), latencyMs = ms,
        };
        if (profile == scope) summaries.Insert(0, s);
        Changed?.Invoke();
        return s;
    }

    public void DeleteSummary(long id)
    {
        Exec("DELETE FROM summaries WHERE id = $id;", ("$id", id));
        summaries.RemoveAll(s => s.id == id);
        Changed?.Invoke();
    }

    /// Xoá mọi bản tóm tắt của game đang chọn.
    public void ClearSummaries()
    {
        Exec("DELETE FROM summaries WHERE profile = $p;", ("$p", scope));
        summaries.Clear();
        Changed?.Invoke();
    }

    // MARK: story (cốt truyện game)
    static TranslationEntry Row(SqliteDataReader r) =>
        new(r.GetInt64(0), FromUnix(r.GetDouble(1)), r.GetString(2), r.GetString(3), r.GetString(4),
            r.GetString(5), r.GetInt32(6), Enum.TryParse<RegionKind>(r.GetString(7), out var k) ? k : RegionKind.subtitle,
            r.GetString(8), r.GetString(9));

    public GameStory? LoadStory(string profile)
    {
        lock (lk)
        {
            using var cmd = db.CreateCommand();
            cmd.CommandText = "SELECT narrative, characters, last_entry_id, last_analysis_id, updated, backend, lore FROM story WHERE profile = $p";
            cmd.Parameters.AddWithValue("$p", profile);
            using var r = cmd.ExecuteReader();
            if (!r.Read()) return null;
            List<StoryCharacter> chars;
            try { chars = JsonSerializer.Deserialize<List<StoryCharacter>>(r.GetString(1)) ?? new(); } catch { chars = new(); }
            chars.RemoveAll(c => string.IsNullOrEmpty(c.name));
            List<StoryLore> lore;
            try { lore = JsonSerializer.Deserialize<List<StoryLore>>(r.GetString(6)) ?? new(); } catch { lore = new(); }
            lore.RemoveAll(l => string.IsNullOrEmpty(l.name));
            return new GameStory
            {
                profile = profile, narrative = r.GetString(0), characters = chars, lore = lore, lastEntryID = r.GetInt64(2),
                lastAnalysisID = r.GetInt64(3), updated = FromUnix(r.GetDouble(4)), backend = r.GetString(5),
            };
        }
    }

    List<StoryPart> LoadStoryParts(string profile)
    {
        var outp = new List<StoryPart>();
        lock (lk)
        {
            using var cmd = db.CreateCommand();
            cmd.CommandText = "SELECT id, ts, profile, title, summary, t_from, t_to, entry_from, entry_to, line_count, backend, latency FROM story_parts WHERE profile = $p ORDER BY id DESC";
            cmd.Parameters.AddWithValue("$p", profile);
            using var r = cmd.ExecuteReader();
            while (r.Read())
                outp.Add(new StoryPart
                {
                    id = r.GetInt64(0), timestamp = FromUnix(r.GetDouble(1)), profile = r.GetString(2), title = r.GetString(3),
                    summary = r.GetString(4), from = FromUnix(r.GetDouble(5)), to = FromUnix(r.GetDouble(6)),
                    entryFrom = r.GetInt64(7), entryTo = r.GetInt64(8), lineCount = r.GetInt32(9), backend = r.GetString(10),
                    latencyMs = r.GetInt32(11),
                });
        }
        return outp;
    }

    /// Câu phụ đề của game có id lớn hơn con trỏ, cũ trước (kể cả câu bị bỏ qua không dịch, để giữ mạch hội thoại).
    public List<TranslationEntry> StoryEntries(string profile, long after, int limit)
    {
        var outp = new List<TranslationEntry>();
        lock (lk)
        {
            using var cmd = db.CreateCommand();
            cmd.CommandText = "SELECT id, ts, region, source, translated, backend, latency, kind, target, profile FROM history WHERE profile = $p AND id > $a AND kind = 'subtitle' ORDER BY id ASC LIMIT $n";
            cmd.Parameters.AddWithValue("$p", profile);
            cmd.Parameters.AddWithValue("$a", after);
            cmd.Parameters.AddWithValue("$n", limit);
            using var r = cmd.ExecuteReader();
            while (r.Read()) outp.Add(Row(r));
        }
        return outp;
    }

    /// Câu phụ đề của game có chứa một trong các cụm từ (không phân biệt hoa thường với chữ ASCII), mới nhất trước.
    /// Đọc thẳng từ DB nên tìm được cả những câu cũ không còn trong `entries`.
    public List<TranslationEntry> SearchEntries(string profile, IEnumerable<string> terms, int limit)
    {
        var list = terms.Where(t => t.Length > 0).Take(12).ToList();
        var outp = new List<TranslationEntry>();
        if (list.Count == 0) return outp;
        lock (lk)
        {
            using var cmd = db.CreateCommand();
            var cond = string.Join(" OR ", list.Select((_, i) => $"source LIKE $t{i} ESCAPE '\\' OR translated LIKE $t{i} ESCAPE '\\'"));
            cmd.CommandText = $"SELECT id, ts, region, source, translated, backend, latency, kind, target, profile FROM history WHERE profile = $p AND kind = 'subtitle' AND ({cond}) ORDER BY id DESC LIMIT $n";
            cmd.Parameters.AddWithValue("$p", profile);
            for (int i = 0; i < list.Count; i++)
                cmd.Parameters.AddWithValue($"$t{i}", "%" + list[i].Replace("\\", "\\\\").Replace("%", "\\%").Replace("_", "\\_") + "%");
            cmd.Parameters.AddWithValue("$n", limit);
            using var r = cmd.ExecuteReader();
            while (r.Read()) outp.Add(Row(r));
        }
        return outp;
    }

    /// Lần dịch màn hình của game có chứa một trong các cụm từ (trong tóm tắt hoặc các dòng chữ), mới nhất trước.
    /// Đọc thẳng từ DB nên tìm được cả những lần chụp cũ không còn trong `analyses`.
    public List<ScreenAnalysis> SearchAnalyses(string profile, IEnumerable<string> terms, int limit)
    {
        var list = terms.Where(t => t.Length > 0).Take(12).ToList();
        var outp = new List<ScreenAnalysis>();
        if (list.Count == 0) return outp;
        lock (lk)
        {
            using var cmd = db.CreateCommand();
            var cond = string.Join(" OR ", list.Select((_, i) => $"summary LIKE $t{i} ESCAPE '\\' OR lines LIKE $t{i} ESCAPE '\\'"));
            cmd.CommandText = $"SELECT id, ts, region, summary, lines, backend, latency, profile, items, iw, ih FROM analyses WHERE profile = $p AND ({cond}) ORDER BY id DESC LIMIT $n";
            cmd.Parameters.AddWithValue("$p", profile);
            for (int i = 0; i < list.Count; i++)
                cmd.Parameters.AddWithValue($"$t{i}", "%" + list[i].Replace("\\", "\\\\").Replace("%", "\\%").Replace("_", "\\_") + "%");
            cmd.Parameters.AddWithValue("$n", limit);
            using var r = cmd.ExecuteReader();
            while (r.Read()) outp.Add(AnalysisRow(r));
        }
        return outp;
    }

    /// Câu phụ đề `id` cùng `radius` câu trước và sau nó (cùng game), cũ trước.
    public List<TranslationEntry> EntriesAround(long id, string profile, int radius)
    {
        List<TranslationEntry> Fetch(string where, int n)
        {
            var outp = new List<TranslationEntry>();
            lock (lk)
            {
                using var cmd = db.CreateCommand();
                cmd.CommandText = $"SELECT id, ts, region, source, translated, backend, latency, kind, target, profile FROM history WHERE profile = $p AND kind = 'subtitle' AND {where} LIMIT $n";
                cmd.Parameters.AddWithValue("$p", profile);
                cmd.Parameters.AddWithValue("$id", id);
                cmd.Parameters.AddWithValue("$n", n);
                using var r = cmd.ExecuteReader();
                while (r.Read()) outp.Add(Row(r));
            }
            return outp;
        }
        var before = Fetch("id < $id ORDER BY id DESC", radius);
        before.Reverse();
        before.AddRange(Fetch("id >= $id ORDER BY id ASC", radius + 1));
        return before;
    }

    /// Tóm tắt của các lần "Dịch màn hình" có nội dung (bỏ tóm tắt menu) sau con trỏ, cũ trước.
    public List<(long id, DateTime timestamp, string summary)> StoryAnalyses(string profile, long after)
    {
        var outp = new List<(long, DateTime, string)>();
        lock (lk)
        {
            using var cmd = db.CreateCommand();
            cmd.CommandText = "SELECT id, ts, summary FROM analyses WHERE profile = $p AND id > $a AND length(summary) >= 80 AND summary NOT LIKE '(%' ORDER BY id ASC LIMIT 20";
            cmd.Parameters.AddWithValue("$p", profile);
            cmd.Parameters.AddWithValue("$a", after);
            using var r = cmd.ExecuteReader();
            while (r.Read()) outp.Add((r.GetInt64(0), FromUnix(r.GetDouble(1)), r.GetString(2)));
        }
        return outp;
    }

    /// Số câu đã dịch và số lần dịch màn hình chưa được đưa vào cốt truyện.
    public (int lines, int screens) StoryPending(string profile)
    {
        var s = LoadStory(profile);
        lock (lk)
        {
            using var cmd = db.CreateCommand();
            cmd.CommandText = """
                SELECT (SELECT COUNT(*) FROM history WHERE profile = $p AND id > $e AND kind = 'subtitle' AND backend != 'skipped'),
                       (SELECT COUNT(*) FROM analyses WHERE profile = $p AND id > $a AND length(summary) >= 80 AND summary NOT LIKE '(%')
                """;
            cmd.Parameters.AddWithValue("$p", profile);
            cmd.Parameters.AddWithValue("$e", s?.lastEntryID ?? 0);
            cmd.Parameters.AddWithValue("$a", s?.lastAnalysisID ?? 0);
            try
            {
                using var r = cmd.ExecuteReader();
                return r.Read() ? (r.GetInt32(0), r.GetInt32(1)) : (0, 0);
            }
            catch { return (0, 0); }
        }
    }

    /// Lưu kết quả một lần cập nhật cốt truyện. Trả về false (không lưu gì) nếu con trỏ đã đổi từ lúc bắt đầu,
    /// tức là người dùng vừa xoá / viết lại cốt truyện trong lúc model đang chạy.
    public bool SaveStoryUpdate(GameStory s, long expectedEntryCursor, StoryPart? part)
    {
        if ((LoadStory(s.profile)?.lastEntryID ?? 0) != expectedEntryCursor) return false;
        lock (lk)
        {
            using var tx = db.BeginTransaction();
            try
            {
                using (var cmd = db.CreateCommand())
                {
                    cmd.Transaction = tx;
                    cmd.CommandText = """
                        INSERT INTO story(profile, narrative, characters, last_entry_id, last_analysis_id, updated, backend, lore) VALUES($p,$n,$c,$e,$a,$u,$b,$l)
                        ON CONFLICT(profile) DO UPDATE SET narrative=excluded.narrative, characters=excluded.characters,
                            last_entry_id=excluded.last_entry_id, last_analysis_id=excluded.last_analysis_id,
                            updated=excluded.updated, backend=excluded.backend, lore=excluded.lore
                        """;
                    cmd.Parameters.AddWithValue("$p", s.profile);
                    cmd.Parameters.AddWithValue("$n", s.narrative);
                    cmd.Parameters.AddWithValue("$c", JsonSerializer.Serialize(s.characters));
                    cmd.Parameters.AddWithValue("$e", s.lastEntryID);
                    cmd.Parameters.AddWithValue("$a", s.lastAnalysisID);
                    cmd.Parameters.AddWithValue("$u", ToUnix(s.updated));
                    cmd.Parameters.AddWithValue("$b", s.backend);
                    cmd.Parameters.AddWithValue("$l", JsonSerializer.Serialize(s.lore));
                    cmd.ExecuteNonQuery();
                }
                if (part != null)
                {
                    using var cmd = db.CreateCommand();
                    cmd.Transaction = tx;
                    cmd.CommandText = "INSERT INTO story_parts(profile, ts, title, summary, t_from, t_to, entry_from, entry_to, line_count, backend, latency) VALUES($p,$ts,$t,$s,$f,$to,$ef,$et,$n,$b,$ms); SELECT last_insert_rowid();";
                    cmd.Parameters.AddWithValue("$p", s.profile);
                    cmd.Parameters.AddWithValue("$ts", ToUnix(part.timestamp));
                    cmd.Parameters.AddWithValue("$t", part.title);
                    cmd.Parameters.AddWithValue("$s", part.summary);
                    cmd.Parameters.AddWithValue("$f", ToUnix(part.from));
                    cmd.Parameters.AddWithValue("$to", ToUnix(part.to));
                    cmd.Parameters.AddWithValue("$ef", part.entryFrom);
                    cmd.Parameters.AddWithValue("$et", part.entryTo);
                    cmd.Parameters.AddWithValue("$n", part.lineCount);
                    cmd.Parameters.AddWithValue("$b", part.backend);
                    cmd.Parameters.AddWithValue("$ms", part.latencyMs);
                    part.id = Convert.ToInt64(cmd.ExecuteScalar());
                }
                tx.Commit();
            }
            catch (Exception e)
            {
                Log.Error($"SQLite save story: {e.Message}");
                try { tx.Rollback(); } catch { }
                return false;
            }
        }
        if (s.profile == scope)
        {
            story = s;
            if (part != null) storyParts.Insert(0, part);
            StoryChanged?.Invoke();
        }
        return true;
    }

    /// Xoá cốt truyện của game đang chọn. `fromNow`: bỏ qua nhật ký đã có, chỉ viết từ những câu sau thời điểm này;
    /// ngược lại lần cập nhật tới sẽ viết lại từ đầu nhật ký.
    public void ResetStory(bool fromNow)
    {
        Exec("DELETE FROM story WHERE profile = $p; DELETE FROM story_parts WHERE profile = $p;", ("$p", scope));
        storyParts.Clear();
        story = null;
        if (fromNow) StartStoryFromNow(scope);
        else StoryChanged?.Invoke();
    }

    /// Game chưa có cốt truyện → đặt con trỏ ở cuối nhật ký hiện có, để việc tự cập nhật chỉ viết từ những câu sau lúc này
    /// (nhật ký cũ chỉ được đưa vào khi người dùng bấm "Tóm tắt từ đầu nhật ký"). Không làm gì nếu game đã có con trỏ.
    public void StartStoryFromNow(string profile)
    {
        Exec("""
            INSERT OR IGNORE INTO story(profile, last_entry_id, last_analysis_id)
            VALUES($p, (SELECT COALESCE(MAX(id), 0) FROM history WHERE profile = $p),
                   (SELECT COALESCE(MAX(id), 0) FROM analyses WHERE profile = $p))
            """, ("$p", profile));
        if (profile != scope) return;
        story = LoadStory(profile);
        StoryChanged?.Invoke();
    }

    /// Số câu đã dịch trong nhật ký của game (để mời "Tóm tắt từ đầu nhật ký").
    public int StoryBacklog(string profile)
    {
        lock (lk)
        {
            using var cmd = db.CreateCommand();
            cmd.CommandText = "SELECT COUNT(*) FROM history WHERE profile = $p AND kind = 'subtitle' AND backend != 'skipped'";
            cmd.Parameters.AddWithValue("$p", profile);
            try { return Convert.ToInt32(cmd.ExecuteScalar() ?? 0); } catch { return 0; }
        }
    }

    public void DeleteStoryPart(long id)
    {
        Exec("DELETE FROM story_parts WHERE id = $id;", ("$id", id));
        storyParts.RemoveAll(p => p.id == id);
        StoryChanged?.Invoke();
    }

    public void DeleteStoryCharacter(string name)
    {
        var s = LoadStory(scope);
        if (s == null) return;
        s.characters.RemoveAll(c => c.name == name);
        Exec("UPDATE story SET characters = $c WHERE profile = $p;", ("$c", JsonSerializer.Serialize(s.characters)), ("$p", scope));
        story = s;
        StoryChanged?.Invoke();
    }

    /// Đưa con trỏ "màn hình đã đọc" của cốt truyện về đầu (giữ nguyên con trỏ câu phụ đề).
    public void RewindStoryScreens(string profile)
    {
        Exec("UPDATE story SET last_analysis_id = 0 WHERE profile = $p;", ("$p", profile));
        if (profile == scope) { story = LoadStory(profile); StoryChanged?.Invoke(); }
    }

    public void DeleteStoryLore(string name)
    {
        var s = LoadStory(scope);
        if (s == null) return;
        s.lore.RemoveAll(l => l.name == name);
        Exec("UPDATE story SET lore = $l WHERE profile = $p;", ("$l", JsonSerializer.Serialize(s.lore)), ("$p", scope));
        story = s;
        StoryChanged?.Invoke();
    }

    public ScreenAnalysis? FindAnalysis(long id) => analyses.FirstOrDefault(a => a.id == id) ?? LoadAnalyses(scope).FirstOrDefault(a => a.id == id);
}
