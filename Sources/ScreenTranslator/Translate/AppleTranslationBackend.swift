import Foundation
import SwiftUI
import Translation

/// Dịch on-device qua Translation framework. TranslationSession chỉ tồn tại trong closure của
/// `.translationTask`, nên backend đẩy job vào AsyncStream và `serve(session:)` xử lý bên trong closure đó.
final class AppleTranslationBackend: TranslationBackend, ObservableObject {
    let kind: BackendKind = .apple

    /// Continuation chỉ được resume một lần: bên nào tới trước (kết quả dịch hoặc hết giờ) thì thắng, bên sau bị bỏ qua.
    final class Reply<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        init(_ c: CheckedContinuation<T, Error>) { continuation = c }
        func resume(with result: Result<T, Error>) {
            lock.lock(); let c = continuation; continuation = nil; lock.unlock()
            c?.resume(with: result)
        }
    }

    enum Job {
        case single(String, Reply<String>)
        case batch([String], Reply<[String]>)
    }

    enum AppleError: LocalizedError {
        case notReady, timeout, notInstalled
        var errorDescription: String? {
            switch self {
            case .notReady: return "Apple Translation chưa sẵn sàng"
            case .timeout: return "Apple Translation quá thời gian"
            case .notInstalled: return "Chưa tải gói ngôn ngữ"
            }
        }
    }

    @Published private(set) var ready = false
    @Published private(set) var installed: Bool? = nil
    @Published private(set) var targetCode: String

    /// Hàng đợi job của session đang phục vụ. Mỗi lần `serve` tạo hàng đợi mới, vì AsyncStream kết thúc hẳn
    /// khi task đang đọc nó bị huỷ (đổi ngôn ngữ đích) và không dùng lại được.
    private var jobs: AsyncStream<Job>.Continuation?
    private var serveGeneration = 0
    private let jobsLock = NSLock()

    let source = Locale.Language(identifier: "en")
    var target: Locale.Language { Locale.Language(identifier: targetCode) }

    init(targetCode: String) {
        self.targetCode = targetCode
        Task { await refreshAvailability() }
    }

    /// Đưa job vào hàng đợi của session hiện tại; false nếu chưa có session nào đang phục vụ.
    private func enqueue(_ job: Job) -> Bool {
        jobsLock.lock(); defer { jobsLock.unlock() }
        guard let jobs else { return false }
        if case .terminated = jobs.yield(job) { return false }
        return true
    }

    /// Gửi job rồi chờ kết quả, tối đa `seconds`. Hết giờ thì trả lỗi ngay, không đợi session.
    private func request<T>(timeout seconds: Double, _ make: @escaping (Reply<T>) -> Job) async throws -> T {
        try await withCheckedThrowingContinuation { c in
            let reply = Reply(c)
            guard enqueue(make(reply)) else { reply.resume(with: .failure(AppleError.notReady)); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                reply.resume(with: .failure(AppleError.timeout))
            }
        }
    }

    @MainActor
    func setTarget(_ code: String) {
        guard code != targetCode else { return }
        targetCode = code
        installed = nil
        ready = false
        Task { await refreshAvailability() }
    }

    @MainActor
    func refreshAvailability() async {
        let status = await LanguageAvailability().status(from: source, to: target)
        installed = (status == .installed)
        Log.info("Apple Translation en→\(targetCode) status: \(status)")
    }

    func translate(_ text: String, context: [TranslationPair]) async throws -> String {
        guard ready else { throw AppleError.notReady }
        return try await request(timeout: 5) { .single(text, $0) }
    }

    func translateBatch(_ texts: [String]) async throws -> [String] {
        guard ready else { throw AppleError.notReady }
        guard !texts.isEmpty else { return [] }
        return try await request(timeout: 30) { .batch(texts, $0) }
    }

    /// Gọi từ closure của `.translationTask`. Chạy đến khi task bị huỷ (đổi ngôn ngữ đích).
    func serve(session: TranslationSession) async {
        let (stream, continuation) = AsyncStream.makeStream(of: Job.self, bufferingPolicy: .unbounded)
        let (gen, old) = jobsLock.withLock { () -> (Int, AsyncStream<Job>.Continuation?) in
            serveGeneration += 1
            let old = jobs
            jobs = continuation
            return (serveGeneration, old)
        }
        old?.finish()
        await MainActor.run { ready = true }
        Log.info("Apple Translation session ready (en→\(targetCode))")
        for await job in stream {
            if Task.isCancelled {
                switch job {
                case .single(_, let c): c.resume(with: .failure(CancellationError()))
                case .batch(_, let c): c.resume(with: .failure(CancellationError()))
                }
                break
            }
            switch job {
            case .single(let text, let c):
                do {
                    let t0 = Date()
                    let r = try await session.translate(text)
                    Log.info("Apple translate \(Int(Date().timeIntervalSince(t0) * 1000))ms")
                    c.resume(with: .success(r.targetText))
                } catch { c.resume(with: .failure(error)) }
            case .batch(let texts, let c):
                do {
                    let reqs = texts.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: "\($0.offset)") }
                    let responses = try await session.translations(from: reqs)
                    var out = texts
                    for r in responses {
                        if let id = r.clientIdentifier, let i = Int(id), i < out.count { out[i] = r.targetText }
                    }
                    c.resume(with: .success(out))
                } catch { c.resume(with: .failure(error)) }
            }
        }
        // Session mới có thể đã lên thay trước khi vòng lặp này kết thúc → chỉ báo "chưa sẵn sàng" nếu vẫn là session hiện tại.
        let current = jobsLock.withLock { () -> Bool in
            let current = gen == serveGeneration
            if current { jobs = nil }
            return current
        }
        continuation.finish()
        if current { await MainActor.run { ready = false } }
    }
}

/// View ẩn giữ TranslationSession sống suốt phiên; đổi ngôn ngữ đích → session mới.
struct TranslationHostView: View {
    @ObservedObject var backend: AppleTranslationBackend
    @ObservedObject var settings = AppSettings.shared
    @State private var config: TranslationSession.Configuration

    init(backend: AppleTranslationBackend) {
        self.backend = backend
        _config = State(initialValue: TranslationSession.Configuration(source: backend.source, target: backend.target))
    }

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(config) { session in
                await backend.serve(session: session)
            }
            .onChange(of: settings.targetLanguage) { _, code in
                backend.setTarget(code)
                config = TranslationSession.Configuration(source: backend.source, target: Locale.Language(identifier: code))
            }
    }
}

/// Nút tải gói ngôn ngữ, đặt trong Settings (cần cửa sổ hiển thị để hệ thống hiện sheet tải).
struct LanguageDownloadButton: View {
    @ObservedObject var backend: AppleTranslationBackend
    @State private var config: TranslationSession.Configuration?
    @State private var message = ""

    var body: some View {
        HStack {
            Button("Tải gói ngôn ngữ Anh → \(TargetLanguage.find(backend.targetCode).name)") {
                config = TranslationSession.Configuration(source: backend.source, target: backend.target)
            }
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
        .translationTask(config) { session in
            do {
                try await session.prepareTranslation()
                message = "Đã sẵn sàng"
                await backend.refreshAvailability()
            } catch {
                message = error.localizedDescription
            }
            config = nil
        }
    }
}
