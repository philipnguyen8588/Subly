using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Documents;
using System.Windows.Media;

namespace ScreenTranslator;

/// Mỗi nhân vật một màu cố định (theo thứ tự trong danh sách tên đã học của game), dùng để tô tên ở overlay, dải phụ đề và nhật ký.
public static class SpeakerColors
{
    /// 12 màu dễ phân biệt, đủ đậm để đọc trên nền trắng.
    static readonly (double r, double g, double b)[] palette =
    {
        (0.20, 0.47, 0.95),   // xanh dương
        (0.93, 0.47, 0.10),   // cam
        (0.13, 0.64, 0.36),   // xanh lá
        (0.86, 0.24, 0.52),   // hồng
        (0.53, 0.35, 0.90),   // tím
        (0.05, 0.62, 0.68),   // xanh ngọc
        (0.87, 0.25, 0.22),   // đỏ
        (0.72, 0.56, 0.05),   // vàng đậm
        (0.33, 0.36, 0.80),   // chàm
        (0.60, 0.40, 0.22),   // nâu
        (0.42, 0.62, 0.12),   // xanh ô liu
        (0.75, 0.30, 0.78),   // tím hồng
    };

    static readonly Regex NamePrefix = new(@"^[^:：]{1,30}[:：]", RegexOptions.Compiled);

    public static int Index(string name, IList<string>? speakers = null)
    {
        speakers ??= AppSettings.shared.speakers;
        var canon = SpeakerNames.Canonical(name, speakers) ?? name;
        for (int i = 0; i < speakers.Count; i++)
            if (speakers[i].ToLowerInvariant() == canon.ToLowerInvariant()) return i % palette.Length;
        // Tên chưa học: màu theo chữ, ổn định giữa các lần chạy (djb2 giống bản macOS).
        long h = 5381;
        foreach (var c in canon.ToLowerInvariant()) h = unchecked((h * 33) + c);
        return (int)(Math.Abs(h) % palette.Length);
    }

    /// `onDark`: dùng trên nền tối (overlay) → pha sáng lên cho dễ đọc.
    public static Color ColorFor(string name, bool onDark = false, IList<string>? speakers = null)
    {
        var (r, g, b) = palette[Index(name, speakers)];
        if (onDark) { r += (1 - r) * 0.45; g += (1 - g) * 0.45; b += (1 - b) * 0.45; }
        return Color.FromRgb((byte)(r * 255), (byte)(g * 255), (byte)(b * 255));
    }

    public static Color PaletteColor(int i)
    {
        var (r, g, b) = palette[((i % palette.Length) + palette.Length) % palette.Length];
        return Color.FromRgb((byte)(r * 255), (byte)(g * 255), (byte)(b * 255));
    }

    /// Tô màu + in đậm phần "Tên:" ở đầu mỗi dòng. Game không hiện tên người nói thì trả về chữ thường.
    public static List<Inline> Styled(string text, bool onDark = false, FontWeight? weight = null)
    {
        var outp = new List<Inline>();
        bool colorize = AppSettings.shared.showsSpeakerNames;
        var speakers = AppSettings.shared.speakers;
        var lines = text.Split('\n');
        for (int i = 0; i < lines.Length; i++)
        {
            var line = lines[i];
            if (i > 0) outp.Add(new LineBreak());
            var m = colorize ? NamePrefix.Match(line) : Match.Empty;
            if (m.Success && m.Value.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length <= 3)
            {
                var name = m.Value[..^1].Trim();
                outp.Add(new Run(m.Value) { FontWeight = FontWeights.Bold, Foreground = new SolidColorBrush(ColorFor(name, onDark, speakers)) });
                outp.Add(new Run(line[m.Length..]) { FontWeight = weight ?? FontWeights.Normal });
            }
            else outp.Add(new Run(line) { FontWeight = weight ?? FontWeights.Normal });
        }
        return outp;
    }
}
