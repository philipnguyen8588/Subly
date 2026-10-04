using System;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using System.Web;

namespace ScreenTranslator;

/// Lấy PSN Account ID bằng cách đăng nhập trang chính thức của Sony (cùng luồng với script psn-account-id.py của chiaki-ng):
/// mở trang đăng nhập → người dùng dán URL "redirect" → đổi mã lấy token → đọc user_id → 8 byte little-endian → base64.
public static class PSNAccount
{
    // Client ID/secret công khai của ứng dụng Remote Play, lấy từ mã nguồn chiaki-ng.
    const string clientID = "ba495a24-818c-472b-b12d-ff231c1b5745";
    const string clientSecret = "mvaiZkRsAsI1IBkY";
    const string redirect = "https://remoteplay.dl.playstation.net/remoteplay/redirect";
    const string tokenURL = "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/token";
    static readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(20) };

    public static string LoginURL =>
        $"https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/authorize?service_entity=urn:service-entity:psn&response_type=code&client_id={clientID}&redirect_uri={redirect}&scope=psn:clientapp&request_locale=en_US&ui=pr&service_logo=ps&layout_type=popup&smcid=remoteplay&prompt=always&PlatformPrivacyWs1=minimal&";

    /// Tách mã uỷ quyền từ URL redirect (hoặc nhận thẳng chuỗi mã).
    public static string? Code(string pasted)
    {
        var t = pasted.Trim();
        if (Uri.TryCreate(t, UriKind.Absolute, out var u))
        {
            var c = HttpUtility.ParseQueryString(u.Query)["code"];
            if (!string.IsNullOrEmpty(c)) return c;
        }
        if (t.Length > 0 && !t.Contains('/') && !t.Contains(' ') && !t.Contains('=')) return t;   // người dùng dán riêng mã
        return null;
    }

    /// user_id (số thập phân) → 8 byte little-endian → base64, đúng định dạng chiaki dùng.
    public static string Encode(ulong userID) => Convert.ToBase64String(BitConverter.GetBytes(userID));

    public static async Task<string> AccountID(string pasted)
    {
        var code = Code(pasted) ?? throw new Exception("URL không có tham số code. Hãy copy đúng địa chỉ của trang có chữ “redirect” sau khi đăng nhập.");
        var basic = new AuthenticationHeaderValue("Basic", Convert.ToBase64String(Encoding.UTF8.GetBytes($"{clientID}:{clientSecret}")));

        using var req = new HttpRequestMessage(HttpMethod.Post, tokenURL);
        req.Headers.Authorization = basic;
        req.Content = new StringContent($"grant_type=authorization_code&code={code}&redirect_uri={redirect}&", Encoding.UTF8, "application/x-www-form-urlencoded");
        using var r1 = await http.SendAsync(req);
        var d1 = await r1.Content.ReadAsStringAsync();
        if ((int)r1.StatusCode != 200) throw Http((int)r1.StatusCode, d1);
        using var j1 = JsonDocument.Parse(d1);
        if (!j1.RootElement.TryGetProperty("access_token", out var tok) || tok.GetString() is not string token)
            throw new Exception("Phản hồi thiếu trường access_token.");

        using var info = new HttpRequestMessage(HttpMethod.Get, tokenURL + "/" + Uri.EscapeDataString(token));
        info.Headers.Authorization = basic;
        using var r2 = await http.SendAsync(info);
        var d2 = await r2.Content.ReadAsStringAsync();
        if ((int)r2.StatusCode != 200) throw Http((int)r2.StatusCode, d2);
        using var j2 = JsonDocument.Parse(d2);
        if (!j2.RootElement.TryGetProperty("user_id", out var uid)) throw new Exception("Phản hồi thiếu trường user_id.");
        var raw = uid.ValueKind == JsonValueKind.Number ? uid.GetRawText() : uid.GetString() ?? "";
        if (!ulong.TryParse(raw, out var id)) throw new Exception("Phản hồi thiếu trường user_id.");
        return Encode(id);
    }

    static Exception Http(int c, string s) =>
        new($"Sony trả về lỗi {c}. Mã trong URL chỉ dùng được một lần và hết hạn nhanh: đăng nhập lại rồi dán URL mới. {(s.Length > 120 ? s[..120] : s)}");
}
