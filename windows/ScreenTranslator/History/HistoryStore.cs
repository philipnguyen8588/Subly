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

/// Lịch sử dịch + phân tích màn hình, SQLite (cùng schema với bản macOS). Mỗi dòng gắn với một game (profile);
/// `entries` / `analyses` chỉ chứa dữ liệu của game đang chọn và tự nạp lại khi đổi game. Dùng trên UI thread.
public sealed class HistoryStore
{
    public static readonly HistoryStore shared = new();

    /// mới nhất trước
    public List<TranslationEntry> entries { get; private set; } = new();
    public List<ScreenAnalysis> analyses { get; private set; } = new();
    /// Game (UUID của profile) mà `entries` / `analyses` đang chứa.
    public string scope { get; private set; } = "";
    /// Số dòng có từ trước khi nhật ký được tách theo game (không gắn với game nào).
    public int legacyCount { get; private set; }

    public event Action? Changed;
    public event Action<TranslationEntry>? EntryAdded;
    public event Action? EntriesCleared;
    public event Action<ScreenAnalysis>? AnalysisAdded;

    readonly SqliteConnection db;
    const int maxInMemory = 2000, maxAnalyses = 300;
    /// Số ảnh chụp "dịch màn hình" được giữ trên đĩa cho mỗi game.
    public const int maxShots = 50;
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
        PRAGMA journal_mode=WAL;
        """);
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
            while (r.Read())
            {
                var id = r.GetInt64(0);
                List<AnalysisLine> lines; List<ShotItem> items;
                try { lines = JsonSerializer.Deserialize<List<AnalysisLine>>(r.GetString(4)) ?? new(); } catch { lines = new(); }
                try { items = JsonSerializer.Deserialize<List<ShotItem>>(r.GetString(8)) ?? new(); } catch { items = new(); }
                outp.Add(new ScreenAnalysis
                {
                    id = id, timestamp = FromUnix(r.GetDouble(1)), regionName = r.GetString(2), summary = r.GetString(3), lines = lines,
                    backend = r.GetString(5), latencyMs = r.GetInt32(6), profile = r.GetString(7), items = items,
                    imageWidth = r.GetInt32(9), imageHeight = r.GetInt32(10), hasImage = File.Exists(ShotPath(id)),
                });
            }
        }
        return outp;
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

    public ScreenAnalysis? FindAnalysis(long id) => analyses.FirstOrDefault(a => a.id == id) ?? LoadAnalyses(scope).FirstOrDefault(a => a.id == id);
}
