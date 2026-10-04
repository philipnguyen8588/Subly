using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace ScreenTranslator;

/// Dịch qua endpoint miễn phí của Google Translate (translate.googleapis.com, client=gtx), không cần key.
/// Thay cho Apple Translation của bản macOS: nhanh (~150–400 ms), dịch từng câu rời, không ngữ cảnh.
public sealed class GoogleFreeBackend : ITranslationBackend
{
    public BackendKind kind => BackendKind.google;
    public string targetCode = "vi";
    public double timeout = 5;

    static readonly HttpClient http = CreateClient();
    static HttpClient CreateClient()
    {
        var c = new HttpClient { Timeout = TimeSpan.FromSeconds(60) };
        c.DefaultRequestHeaders.UserAgent.ParseAdd("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36");
        return c;
    }

    public async Task<string> Translate(string text, IList<TranslationPair> context, CancellationToken ct = default)
    {
        var url = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=en&tl=" + Uri.EscapeDataString(targetCode) +
                  "&dt=t&q=" + Uri.EscapeDataString(text);
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(TimeSpan.FromSeconds(timeout));
        string body;
        try
        {
            using var resp = await http.GetAsync(url, cts.Token);
            body = await resp.Content.ReadAsStringAsync(cts.Token);
            if (!resp.IsSuccessStatusCode) throw new Exception($"Google HTTP {(int)resp.StatusCode}");
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested) { throw new TimeoutException("Google Translate quá thời gian chờ"); }
        using var doc = JsonDocument.Parse(body);
        var sb = new StringBuilder();
        var root = doc.RootElement;
        if (root.ValueKind == JsonValueKind.Array && root.GetArrayLength() > 0 && root[0].ValueKind == JsonValueKind.Array)
            foreach (var seg in root[0].EnumerateArray())
                if (seg.ValueKind == JsonValueKind.Array && seg.GetArrayLength() > 0 && seg[0].ValueKind == JsonValueKind.String)
                    sb.Append(seg[0].GetString());
        var outp = TextUtils.Normalize(sb.ToString());
        if (outp.Length == 0) throw new Exception("Google Translate trả về rỗng");
        return outp;
    }

    /// Dịch nhiều dòng (dịch màn hình): song song tối đa 4 request.
    public async Task<List<string>> TranslateBatch(IList<string> texts, CancellationToken ct = default)
    {
        var sem = new SemaphoreSlim(4);
        var tasks = texts.Select(async t =>
        {
            await sem.WaitAsync(ct);
            try { return await Translate(t, Array.Empty<TranslationPair>(), ct); }
            catch (Exception e) { Log.Warn($"Google dịch dòng lỗi: {e.Message}"); return ""; }
            finally { sem.Release(); }
        });
        return (await Task.WhenAll(tasks)).ToList();
    }
}
