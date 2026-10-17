import Foundation

/// AI share: dùng API key do chủ server chia sẻ mà không bao giờ thấy key. App chỉ giữ một token; mọi request AI đi
/// qua proxy `/v1/ai/<nhà cung cấp>` của server, server kiểm tra model rồi tự gắn key thật (xem server/share.go).
@MainActor
enum AIShareClient {
    enum ShareError: LocalizedError {
        case unavailable
        case badToken
        case http(Int, String)
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Bản app này không có server AI share"
            case .badToken: return "Token không đúng dạng (bắt đầu bằng sts_)"
            case .http(let c, let m): return m.isEmpty ? "AI share: HTTP \(c)" : m
            }
        }
    }

    /// Bản build có server (hoặc đang test với --server).
    static var available: Bool { serverURL != nil }

    private static var serverURL: String? { RuntimeConfig.server }

    /// Địa chỉ gốc mà backend của nhà cung cấp gọi tới (thay cho api.openai.com…).
    static func proxyBase(_ provider: String) -> String { (serverURL ?? "") + "/v1/ai/" + provider }

    static func providerName(_ p: String) -> String {
        switch p {
        case "openai": return "OpenAI"
        case "anthropic": return "Anthropic Claude"
        case "gemini": return "Gemini"
        case "custom": return "API tuỳ chỉnh"
        default: return p
        }
    }

    /// Hỏi server token này dùng nhà cung cấp nào, những model nào.
    static func info(token: String) async throws -> AppSettings.AIShareInfo {
        guard let server = serverURL, let url = URL(string: server + "/v1/share/info") else { throw ShareError.unavailable }
        guard token.hasPrefix("sts_"), token.count < 100 else { throw ShareError.badToken }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(code) else {
            throw ShareError.http(code, ((obj?["error"] as? [String: Any])?["message"] as? String) ?? "")
        }
        guard let provider = obj?["provider"] as? String, let models = obj?["models"] as? [String], !models.isEmpty else {
            throw ShareError.http(code, "Server trả về dữ liệu không hợp lệ")
        }
        return .init(label: (obj?["label"] as? String) ?? "", provider: provider, models: models)
    }

    /// Lưu token mới sau khi server xác nhận.
    static func importToken(_ raw: String) async throws -> AppSettings.AIShareInfo {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let info = try await info(token: token)
        let s = AppSettings.shared
        s.aiShareToken = token
        s.aiShare = info
        Log.info("AI share: đã nhập \"\(info.label)\" (\(providerName(info.provider)), \(info.models.count) model)")
        return info
    }

    static func remove() {
        let s = AppSettings.shared
        s.aiShareToken = ""
        s.aiShare = nil
    }

    /// Cập nhật danh sách model từ server (admin sửa model / thu hồi). Lỗi mạng thì giữ nguyên thông tin cũ.
    @discardableResult
    static func refresh() async -> Error? {
        let s = AppSettings.shared
        let token = s.aiShareToken
        guard !token.isEmpty, s.aiShare != nil, available else { return nil }
        do {
            let fresh = try await info(token: token)
            if fresh != s.aiShare { s.aiShare = fresh }
            return nil
        } catch ShareError.http(let code, let msg) where code == 403 {
            if s.aiShare?.revoked == false { Log.warn("AI share: \(msg)") }
            s.aiShare?.revoked = true
            return ShareError.http(code, msg)
        } catch {
            return error
        }
    }

    /// Backend gọi qua proxy cho nhà cung cấp của share (router và nút Kiểm tra dùng chung).
    static func makeBackend(_ info: AppSettings.AIShareInfo, token: String) -> CloudChatBackend {
        let base = proxyBase(info.provider)
        switch info.provider {
        case "anthropic":
            let b = AnthropicBackend()
            b.apiKey = token; b.baseURL = base
            b.model = info.models.first ?? ""
            return b
        case "gemini":
            let b = GeminiBackend(apiKeys: [token], model: info.models.first ?? "", timeout: 6)
            b.baseURL = base
            b.fallbackModels = info.models
            return b
        default:
            let b = OpenAIBackend()
            b.apiKey = token; b.baseURL = base
            b.official = info.provider == "openai"
            b.model = info.models.first ?? ""
            return b
        }
    }

    /// Nút "Kiểm tra": dịch thử một câu bằng model này qua proxy.
    static func test(model: String) async -> Result<String, Error> {
        let s = AppSettings.shared
        await refresh()
        guard let info = s.aiShare, !s.aiShareToken.isEmpty else { return .failure(ShareError.http(0, "Chưa nhập AI share")) }
        if info.revoked { return .failure(ShareError.http(403, "AI share đã bị thu hồi hoặc token không còn hợp lệ")) }
        guard info.models.contains(model) else { return .failure(ShareError.http(0, "Model \(model) không nằm trong AI share")) }
        let b = makeBackend(info, token: s.aiShareToken)
        let prompt = "Translate the English subtitle into natural \(s.target.englishName). Output only the translation."
        if let o = b as? OpenAIBackend { o.timeout = 15; o.subtitlePrompt = { prompt } }
        if let a = b as? AnthropicBackend { a.timeout = 15; a.subtitlePrompt = { prompt } }
        if let g = b as? GeminiBackend { g.timeout = 15; g.targetName = s.target.englishName }
        do {
            let t0 = Date()
            let r = try await b.translate("Hello, how are you?", context: [], model: model)
            return .success("\(r)  (\(Int(Date().timeIntervalSince(t0) * 1000)) ms)")
        } catch {
            return .failure(error)
        }
    }
}
