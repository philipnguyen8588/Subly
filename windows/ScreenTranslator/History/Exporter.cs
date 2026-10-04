using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;

namespace ScreenTranslator;

public static class Exporter
{
    public enum Format { txt, srt, json }

    public static string Label(Format f) => f switch
    {
        Format.txt => "TXT song ngữ",
        Format.srt => "SRT phụ đề",
        _ => "JSON (kèm phân tích)",
    };

    public static void Export(Format format, List<TranslationEntry> entries, List<ScreenAnalysis> analyses)
    {
        var text = format switch
        {
            Format.txt => Txt(entries),
            Format.srt => Srt(entries),
            _ => Json(entries, analyses),
        };
        var dlg = new Microsoft.Win32.SaveFileDialog
        {
            FileName = $"screen-translator-{DateTime.Now:yyyyMMdd-HHmm}.{format}",
            Filter = format == Format.json ? "JSON (*.json)|*.json" : format == Format.srt ? "SubRip (*.srt)|*.srt" : "Text (*.txt)|*.txt",
        };
        if (dlg.ShowDialog() == true)
        {
            try { File.WriteAllText(dlg.FileName, text, new UTF8Encoding(false)); }
            catch (Exception e) { Log.Error($"Export failed: {e.Message}"); }
        }
    }

    public static string Txt(List<TranslationEntry> entries) =>
        string.Join("\n", entries.OrderBy(e => e.timestamp).Select(e =>
            $"[{e.timestamp:yyyy-MM-dd HH:mm:ss}] {e.regionName} · {e.backend}\n{e.source}\n{e.translated}\n"));

    public static string Srt(List<TranslationEntry> entries)
    {
        var asc = entries.Where(e => e.kind == RegionKind.subtitle).OrderBy(e => e.timestamp).ToList();
        if (asc.Count == 0) return "";
        var first = asc[0].timestamp;
        var sb = new StringBuilder();
        for (int i = 0; i < asc.Count; i++)
        {
            var e = asc[i];
            double start = (e.timestamp - first).TotalSeconds;
            double nextStart = i + 1 < asc.Count ? (asc[i + 1].timestamp - first).TotalSeconds : start + 4;
            double end = Math.Min(nextStart - 0.05, start + 8);
            sb.Append($"{i + 1}\n{SrtTime(start)} --> {SrtTime(Math.Max(end, start + 0.5))}\n{e.translated}\n{e.source}\n\n");
        }
        return sb.ToString();
    }

    static string SrtTime(double t)
    {
        int ms = (int)((t - Math.Floor(t)) * 1000);
        int s = (int)t;
        return $"{s / 3600:00}:{(s / 60) % 60:00}:{s % 60:00},{ms:000}";
    }

    public static string Json(List<TranslationEntry> entries, List<ScreenAnalysis> analyses)
    {
        var rows = entries.OrderBy(e => e.timestamp).Select(e => new Dictionary<string, object>
        {
            ["timestamp"] = e.timestamp.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"), ["region"] = e.regionName, ["kind"] = e.kind.ToString(),
            ["source"] = e.source, ["translated"] = e.translated, ["backend"] = e.backend,
            ["latencyMs"] = e.latencyMs, ["target"] = e.targetLang,
        });
        var an = analyses.OrderBy(a => a.timestamp).Select(a => new Dictionary<string, object>
        {
            ["timestamp"] = a.timestamp.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"), ["region"] = a.regionName, ["summary"] = a.summary,
            ["backend"] = a.backend, ["latencyMs"] = a.latencyMs,
            ["lines"] = a.lines.Select(l => new Dictionary<string, string> { ["source"] = l.source, ["target"] = l.target }).ToList(),
        });
        return JsonSerializer.Serialize(new Dictionary<string, object> { ["history"] = rows.ToList(), ["analyses"] = an.ToList() },
            new JsonSerializerOptions { WriteIndented = true, Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping });
    }
}
