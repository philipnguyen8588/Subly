import Foundation

/// Một bản sao lưu trên server (mỗi máy một bản).
struct BackupInfo: Identifiable, Decodable, Equatable {
    let machine: String
    let name: String
    let platform: String
    let appVersion: String
    let ip: String
    let size: Int64
    let sha256: String
    let created: Double
    var id: String { machine }
    var date: Date { Date(timeIntervalSince1970: created) }
    var platformLabel: String { platform == "win" ? "Windows" : platform == "mac" ? "Mac" : "?" }
}

/// Gọi API tài khoản / sao lưu của server (server/backup.go). Token đăng nhập giữ trong SecretStore "account-token".
enum BackupClient {
    struct Failure: LocalizedError {
        let message: String
        let unauthorized: Bool
        var errorDescription: String? { message }
    }

    static let tokenName = "account-token"
    static var token: String { SecretStore.get(tokenName) ?? "" }
    static var available: Bool { RuntimeConfig.server != nil }

    /// Mã máy: HostIdentity.hash. `--machine-id <64 hex>` thay mã khi test (giả làm máy khác).
    static var machineID: String {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--machine-id"), i + 1 < args.count, args[i + 1].count == 64 { return args[i + 1].lowercased() }
        return HostIdentity.hash
    }

    private static func request(_ path: String, method: String = "GET", timeout: TimeInterval = 20) throws -> URLRequest {
        guard let server = RuntimeConfig.server, let url = URL(string: server + path) else {
            throw Failure(message: "Bản app này không có server sao lưu", unauthorized: false)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return req
    }

    private static func check(_ data: Data, _ resp: URLResponse?) throws {
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard !(200..<300).contains(code) else { return }
        let msg = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
        throw Failure(message: msg ?? (code == 0 ? "Không kết nối được server" : "Lỗi server (HTTP \(code))"), unauthorized: code == 401)
    }

    /// Đăng nhập; trả về tên đăng nhập (đã chuẩn hoá) và lưu token.
    static func login(username: String, password: String) async throws -> String {
        var req = try request("/v1/account/login", method: "POST")
        req.setValue(nil, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["username": username, "password": password, "device": HostIdentity.name])
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(data, resp)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let tok = obj["token"] as? String else {
            throw Failure(message: "Server trả về dữ liệu không hợp lệ", unauthorized: false)
        }
        SecretStore.set(tok, name: tokenName)
        return obj["username"] as? String ?? username
    }

    static func logout() async {
        if let req = try? request("/v1/account/logout", method: "POST", timeout: 8) { _ = try? await URLSession.shared.data(for: req) }
        SecretStore.set("", name: tokenName)
    }

    static func list() async throws -> [BackupInfo] {
        let (data, resp) = try await URLSession.shared.data(for: try request("/v1/backups"))
        try check(data, resp)
        struct Reply: Decodable { let backups: [BackupInfo] }
        return try JSONDecoder().decode(Reply.self, from: data).backups
    }

    static func delete(machine: String) async throws {
        let (data, resp) = try await URLSession.shared.data(for: try request("/v1/backups/\(machine)", method: "DELETE"))
        try check(data, resp)
    }

    /// Tải file zip lên làm bản sao lưu của máy này (ghi đè bản cũ).
    static func upload(_ file: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> BackupInfo {
        var q = URLComponents()
        q.queryItems = [.init(name: "name", value: HostIdentity.name), .init(name: "platform", value: "mac"), .init(name: "v", value: AppInfo.version)]
        var req = try request("/v1/backups/\(machineID)?\(q.percentEncodedQuery ?? "")", method: "PUT", timeout: 120)
        req.setValue("application/zip", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await Transfer(progress: progress).upload(req, file: file)
        try check(data, resp)
        return try JSONDecoder().decode(BackupInfo.self, from: data)
    }

    /// Tải bản sao lưu của một máy về file `dest`.
    static func download(machine: String, to dest: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let req = try request("/v1/backups/\(machine)", timeout: 120)
        let (data, resp) = try await Transfer(progress: progress).download(req, to: dest)
        try check(data, resp)
    }
}

/// Tải lên / tải về có báo tiến độ (URLSession với delegate riêng cho từng lần).
private final class Transfer: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void
    private var cont: CheckedContinuation<(Data, URLResponse?), Error>?
    private var body = Data()
    private var dest: URL?
    private var moveError: Error?

    init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

    private func session() -> URLSession {
        URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    }

    func upload(_ req: URLRequest, file: URL) async throws -> (Data, URLResponse?) {
        let s = session()
        defer { s.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { c in
            cont = c
            s.uploadTask(with: req, fromFile: file).resume()
        }
    }

    func download(_ req: URLRequest, to dest: URL) async throws -> (Data, URLResponse?) {
        self.dest = dest
        let s = session()
        defer { s.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { c in
            cont = c
            s.downloadTask(with: req).resume()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData _: Int64, totalBytesSent sent: Int64, totalBytesExpectedToSend total: Int64) {
        if total > 0 { progress(Double(sent) / Double(total)) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { body.append(data) }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten written: Int64, totalBytesExpectedToWrite total: Int64) {
        if total > 0 { progress(Double(written) / Double(total)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            body = (try? Data(contentsOf: location)) ?? Data()   // lỗi dạng {"error": …}
            return
        }
        guard let dest else { return }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
        } catch { moveError = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let e = error ?? moveError { cont?.resume(throwing: e) } else { cont?.resume(returning: (body, task.response)) }
        cont = nil
    }
}
