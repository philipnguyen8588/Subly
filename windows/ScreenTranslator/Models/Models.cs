using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json.Serialization;

namespace ScreenTranslator;

/// Vùng gắn app: khi app không ở phía trước thì làm gì.
[JsonConverter(typeof(JsonStringEnumConverter))]
public enum RegionAppMode { followWindow, pauseWhenInactive }

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum RegionKind { subtitle, manual }

/// Nguồn hình của một profile: app/cửa sổ trên máy này, hoặc PS5 nhúng trong app.
[JsonConverter(typeof(JsonStringEnumConverter))]
public enum ProfileSource { external, ps5 }

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum QueueMode { latestWins, fifo }

/// Windows: Gemini → Google Translate (thay Apple Translation); chỉ Google Translate; hoặc OpenAI (trả phí) → Google Translate.
[JsonConverter(typeof(JsonStringEnumConverter))]
public enum TranslationEngine { auto, google, openAI }

/// Engine cho "Dịch màn hình" (chọn riêng với phụ đề: phụ đề cần nhanh, dịch màn hình cần hiểu kỹ).
[JsonConverter(typeof(JsonStringEnumConverter))]
public enum ScreenEngine { gemini, openAI, google }

/// Giọng văn và cách xưng hô khi dịch phụ đề, chọn theo bối cảnh của game.
[JsonConverter(typeof(JsonStringEnumConverter))]
public enum TranslationStyle { auto, modern, fantasy, myth }

public static class TranslationStyles
{
    /// Đoán phong cách từ tên game; không nhận ra thì dùng hiện đại.
    public static TranslationStyle Guess(string gameName)
    {
        var n = gameName.ToLowerInvariant();
        if (new[] { "god of war", "ragnar", "assassin's creed odyssey", "hades" }.Any(n.Contains)) return TranslationStyle.myth;
        if (new[] { "final fantasy", "ff16", "ffxvi", "witcher", "elden", "dragon", "skyrim", "baldur", "dark souls", "zelda", "kingdom come", "lord of the rings" }.Any(n.Contains))
            return TranslationStyle.fantasy;
        return TranslationStyle.modern;
    }
}

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum OverlayPosition { belowRegion, aboveRegion, screenBottom }

/// Engine giọng đọc: Windows (OneCore/SAPI), giọng AI offline (sherpa-onnx), Microsoft Edge neural.
[JsonConverter(typeof(JsonStringEnumConverter))]
public enum VoiceEngine { windows, local, edge }

public static class Labels
{
    public static string Of(RegionAppMode m) => m == RegionAppMode.followWindow ? "Vẫn dịch (bám cửa sổ)" : "Tạm dừng";
    public static string Of(RegionKind k) => k == RegionKind.subtitle ? "Phụ đề" : "Thủ công";
    public static string Of(ProfileSource s) => s == ProfileSource.external ? "App trên máy này" : "PS5";
    public static string Of(QueueMode q) => q == QueueMode.latestWins ? "Phụ đề (chỉ giữ câu mới nhất)" : "Hội thoại (đọc lần lượt)";
    public static string Of(TranslationEngine e) => e switch
    {
        TranslationEngine.auto => "Tự động: Gemini → Google Translate",
        TranslationEngine.openAI => "OpenAI (cần mạng, trả phí, ~0,9 s/câu) → dự phòng Google Translate",
        _ => "Google Translate (miễn phí, nhanh, dịch từng câu rời)",
    };
    public static string Of(ScreenEngine e) => e switch
    {
        ScreenEngine.gemini => "Gemini (cần mạng, miễn phí, ~4–8 s) → dự phòng Google Translate",
        ScreenEngine.openAI => "OpenAI (cần mạng, trả phí, ~3,5 s) → dự phòng Google Translate",
        _ => "Google Translate (nhanh, không có tóm tắt)",
    };
    public static string Of(TranslationStyle s) => s switch
    {
        TranslationStyle.auto => "Tự động theo tên game",
        TranslationStyle.modern => "Hiện đại / đường phố",
        TranslationStyle.fantasy => "Kỳ ảo trung cổ (hiệp sĩ, lãnh chúa)",
        _ => "Thần thoại sử thi",
    };
    public static string Of(OverlayPosition p) => p switch
    {
        OverlayPosition.belowRegion => "Ngay dưới vùng",
        OverlayPosition.aboveRegion => "Ngay trên vùng",
        _ => "Đáy màn hình",
    };
    public static string Of(VoiceEngine e) => e switch
    {
        VoiceEngine.windows => "Windows (offline, tức thì)",
        VoiceEngine.local => "Giọng AI offline (Piper, tiếng Việt)",
        _ => "Microsoft Edge (đám mây, 3–5 s)",
    };
}

public struct RectD : IEquatable<RectD>
{
    public double X, Y, Width, Height;
    public RectD(double x, double y, double w, double h) { X = x; Y = y; Width = w; Height = h; }
    public double MinX => X; public double MinY => Y;
    public double MaxX => X + Width; public double MaxY => Y + Height;
    public double MidX => X + Width / 2; public double MidY => Y + Height / 2;
    public bool IsEmpty => Width <= 0 || Height <= 0;
    public bool Contains(double px, double py) => px >= X && px < MaxX && py >= Y && py < MaxY;
    public RectD Intersect(RectD o)
    {
        double x1 = Math.Max(X, o.X), y1 = Math.Max(Y, o.Y), x2 = Math.Min(MaxX, o.MaxX), y2 = Math.Min(MaxY, o.MaxY);
        return x2 > x1 && y2 > y1 ? new RectD(x1, y1, x2 - x1, y2 - y1) : new RectD(0, 0, 0, 0);
    }
    public bool Equals(RectD o) => X == o.X && Y == o.Y && Width == o.Width && Height == o.Height;
    public override bool Equals(object? obj) => obj is RectD r && Equals(r);
    public override int GetHashCode() => HashCode.Combine(X, Y, Width, Height);
    public override string ToString() => $"({X:0.##},{Y:0.##} {Width:0.##}×{Height:0.##})";
}

/// Vùng màn hình. Toạ độ pixel vật lý toàn cục của Windows (gốc trên-trái màn hình chính).
/// Vùng `embedded` (PS5) thì x/y/width/height là tỉ lệ 0...1 của khung hình.
public class Region
{
    public Guid id { get; set; } = Guid.NewGuid();
    public string name { get; set; } = "";
    public uint displayID { get; set; }
    public double x { get; set; }
    public double y { get; set; }
    public double width { get; set; }
    public double height { get; set; }
    public bool enabled { get; set; } = true;
    public RegionKind kind { get; set; } = RegionKind.subtitle;
    /// Gắn với app: tên process (vd "msedge") — tương đương bundle ID trên macOS.
    public string? appBundleID { get; set; }
    public string? appName { get; set; }
    /// HWND lúc vẽ (có thể đổi sau khi app khởi động lại).
    public long? windowID { get; set; }
    public double? winOffsetX { get; set; }
    public double? winOffsetY { get; set; }
    public double? winWidth { get; set; }
    public double? winHeight { get; set; }
    public RegionAppMode appMode { get; set; } = RegionAppMode.followWindow;
    public bool embedded { get; set; }
    /// Khu vực dịch thêm (ngoài khung phụ đề chính): không lấy tên nhân vật, không đọc thành tiếng,
    /// bản dịch hiện ngay tại khung thay vì ở dải phụ đề chung.
    public bool extra { get; set; }

    [JsonIgnore]
    public RectD rect
    {
        get => new(x, y, width, height);
        set { x = value.X; y = value.Y; width = value.Width; height = value.Height; }
    }

    /// Vùng tính theo góc trên-trái cửa sổ, co giãn theo tỉ lệ nếu cửa sổ đã đổi kích thước so với lúc vẽ.
    public RectD? LocalRect(double winW, double winH)
    {
        if (winOffsetX is not double ox || winOffsetY is not double oy) return null;
        double sx = 1, sy = 1;
        if (winWidth is double w0 && winHeight is double h0 && w0 > 1 && h0 > 1 && winW > 1 && winH > 1)
        { sx = winW / w0; sy = winH / h0; }
        return new RectD(ox * sx, oy * sy, width * sx, height * sy);
    }

    /// Có đủ thông tin để chụp thẳng cửa sổ app (bám cửa sổ) không.
    [JsonIgnore]
    public bool followsWindow => !embedded && appMode == RegionAppMode.followWindow && appBundleID != null && winOffsetX != null && winOffsetY != null;

    public Region Clone() => (Region)MemberwiseClone();
}

public class GlossaryEntry
{
    public Guid id { get; set; } = Guid.NewGuid();
    public string term { get; set; } = "";
    public string translation { get; set; } = "";
    public bool keepAsIs { get; set; }
    public GlossaryEntry Clone() => (GlossaryEntry)MemberwiseClone();
}

public class Profile
{
    public Guid id { get; set; } = Guid.NewGuid();
    public string name { get; set; } = "";
    public ProfileSource source { get; set; } = ProfileSource.external;
    public List<Region> regions { get; set; } = new();
    public List<GlossaryEntry> glossary { get; set; } = new();
    /// Game có hiện "Tên: câu thoại" không.
    public bool showsSpeakerNames { get; set; } = true;
    /// Tên nhân vật đã học.
    public List<string> speakers { get; set; } = new();
    /// Tên hiện ở dòng riêng phía trên câu thoại (không có dấu hai chấm).
    public bool speakerAbove { get; set; }
    public TranslationStyle translationStyle { get; set; } = TranslationStyle.auto;
    /// Ghi chú tự do cho người dịch (xưng hô riêng giữa các nhân vật…).
    public string translationNote { get; set; } = "";

    public Profile Clone() => new()
    {
        id = id, name = name, source = source,
        regions = regions.Select(r => r.Clone()).ToList(),
        glossary = glossary.Select(g => g.Clone()).ToList(),
        showsSpeakerNames = showsSpeakerNames, speakers = speakers.ToList(),
        speakerAbove = speakerAbove, translationStyle = translationStyle, translationNote = translationNote,
    };
}

/// Tổ hợp phím toàn cục: mã phím ảo Windows (VK) + MOD_* của RegisterHotKey.
public class KeyCombo
{
    public uint keyCode { get; set; }
    public uint modifiers { get; set; }

    public const uint Alt = 0x1, Control = 0x2, Shift = 0x4, Win = 0x8;

    public KeyCombo() { }
    public KeyCombo(uint key, uint mods) { keyCode = key; modifiers = mods; }

    [JsonIgnore]
    public string display
    {
        get
        {
            var parts = new List<string>();
            if ((modifiers & Control) != 0) parts.Add("Ctrl");
            if ((modifiers & Alt) != 0) parts.Add("Alt");
            if ((modifiers & Shift) != 0) parts.Add("Shift");
            if ((modifiers & Win) != 0) parts.Add("Win");
            parts.Add(KeyName(keyCode));
            return string.Join("+", parts);
        }
    }

    public static string KeyName(uint vk)
    {
        if (vk >= 0x41 && vk <= 0x5A) return ((char)vk).ToString();
        if (vk >= 0x30 && vk <= 0x39) return ((char)vk).ToString();
        if (vk >= 0x70 && vk <= 0x87) return "F" + (vk - 0x6F);
        if (vk >= 0x60 && vk <= 0x69) return "Num" + (vk - 0x60);
        return vk switch
        {
            0x20 => "Space", 0x0D => "Enter", 0x09 => "Tab", 0x08 => "Backspace", 0x1B => "Esc",
            0x25 => "←", 0x26 => "↑", 0x27 => "→", 0x28 => "↓",
            0x2D => "Insert", 0x2E => "Delete", 0x24 => "Home", 0x23 => "End", 0x21 => "PgUp", 0x22 => "PgDn",
            0xBA => ";", 0xBB => "=", 0xBC => ",", 0xBD => "-", 0xBE => ".", 0xBF => "/", 0xC0 => "`",
            0xDB => "[", 0xDC => "\\", 0xDD => "]", 0xDE => "'",
            _ => $"key{vk}",
        };
    }

    public override bool Equals(object? obj) => obj is KeyCombo k && k.keyCode == keyCode && k.modifiers == modifiers;
    public override int GetHashCode() => HashCode.Combine(keyCode, modifiers);
}

public record TargetLanguage(string code, string name, string englishName)
{
    /// Mã ngôn ngữ cho Google Translate.
    public string googleCode => code switch { "zh-Hans" => "zh-CN", "zh-Hant" => "zh-TW", _ => code };
    /// Mã BCP-47 cho giọng Windows.
    public string bcp47 => code switch
    {
        "vi" => "vi-VN", "en" => "en-US", "ja" => "ja-JP", "ko" => "ko-KR", "zh-Hans" => "zh-CN", "zh-Hant" => "zh-TW",
        "fr" => "fr-FR", "de" => "de-DE", "es" => "es-ES", "th" => "th-TH", "id" => "id-ID", _ => code,
    };

    public static readonly TargetLanguage[] all =
    {
        new("vi", "Tiếng Việt", "Vietnamese"),
        new("en", "English", "English"),
        new("ja", "日本語", "Japanese"),
        new("ko", "한국어", "Korean"),
        new("zh-Hans", "中文 (简体)", "Simplified Chinese"),
        new("zh-Hant", "中文 (繁體)", "Traditional Chinese"),
        new("fr", "Français", "French"),
        new("de", "Deutsch", "German"),
        new("es", "Español", "Spanish"),
        new("th", "ไทย", "Thai"),
        new("id", "Bahasa Indonesia", "Indonesian"),
    };
    public static TargetLanguage Find(string code) => all.FirstOrDefault(l => l.code == code) ?? all[0];
}
