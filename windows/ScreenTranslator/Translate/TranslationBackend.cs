using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace ScreenTranslator;

public record TranslationPair(string source, string target);

public enum BackendKind { gemini, google, skipped, openAI }

public static class BackendLabels
{
    public static string Label(BackendKind k) => k switch
    {
        BackendKind.skipped => "Không dịch",
        BackendKind.gemini => "Gemini",
        BackendKind.openAI => "OpenAI",
        _ => "Google",
    };
    public static string Label(string raw) => Enum.TryParse<BackendKind>(raw, out var k) ? Label(k) : raw switch
    {
        "apple" => "Apple", "appleAI" => "Apple Intelligence", _ => raw,
    };
}

public interface ITranslationBackend
{
    BackendKind kind { get; }
    Task<string> Translate(string text, IList<TranslationPair> context, CancellationToken ct = default);
}

/// Token bucket theo phút (cửa sổ trượt) + bộ đếm theo ngày (reset 00:00 giờ Pacific, như quota Gemini).
public sealed class RateLimiter
{
    public int rpm, rpd;
    readonly List<DateTime> minuteStamps = new();
    string dayKey;
    int dayCount;
    DateTime? cooldownUntil;
    readonly object lk = new();

    static readonly TimeZoneInfo Pacific = FindPacific();
    static TimeZoneInfo FindPacific()
    {
        try { return TimeZoneInfo.FindSystemTimeZoneById("Pacific Standard Time"); }
        catch { try { return TimeZoneInfo.FindSystemTimeZoneById("America/Los_Angeles"); } catch { return TimeZoneInfo.Utc; } }
    }
    static string Today() => TimeZoneInfo.ConvertTimeFromUtc(DateTime.UtcNow, Pacific).ToString("yyyy-MM-dd");

    public RateLimiter(int rpm, int rpd)
    {
        this.rpm = rpm; this.rpd = rpd;
        dayKey = Today();
        dayCount = AppSettings.shared.Get($"rpd.{dayKey}", 0);
    }

    public void Configure(int rpm, int rpd) { lock (lk) { this.rpm = rpm; this.rpd = rpd; } }

    void RollDay()
    {
        var key = Today();
        if (key != dayKey) { dayKey = key; dayCount = AppSettings.shared.Get($"rpd.{key}", 0); }
    }

    public enum DenialKind { cooldown, minute, day }
    public record Denial(DenialKind kind, double seconds = 0);

    /// Trả về null nếu được phép (và đã trừ token), ngược lại lý do từ chối.
    public Denial? Acquire()
    {
        lock (lk)
        {
            RollDay();
            var now = DateTime.UtcNow;
            if (cooldownUntil is DateTime c)
            {
                if (now < c) return new Denial(DenialKind.cooldown, (c - now).TotalSeconds);
                cooldownUntil = null;
            }
            minuteStamps.RemoveAll(s => (now - s).TotalSeconds > 60);
            if (minuteStamps.Count >= rpm) return new Denial(DenialKind.minute);
            if (dayCount >= rpd) return new Denial(DenialKind.day);
            minuteStamps.Add(now);
            dayCount++;
            AppSettings.shared.Set($"rpd.{dayKey}", dayCount, "rpdUsed");
            return null;
        }
    }

    public void ReportRateLimited(double? retryAfter)
    {
        lock (lk) cooldownUntil = DateTime.UtcNow.AddSeconds(retryAfter ?? 60);
    }

    public int usedToday { get { lock (lk) { RollDay(); return dayCount; } } }
    public double? cooldownRemaining
    {
        get
        {
            lock (lk)
            {
                if (cooldownUntil is not DateTime c) return null;
                var r = (c - DateTime.UtcNow).TotalSeconds;
                return r > 0 ? r : null;
            }
        }
    }
}
