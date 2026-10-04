import Foundation
import Combine

/// Danh sách giọng AI offline tải được (model Piper tiếng Việt của NGHI-TTS, bản cho sherpa-onnx).
struct LocalVoice: Identifiable, Equatable {
    let id: String          // tên file model (không đuôi)
    let name: String
    let note: String
    var sizeMB: Int { 61 }
}

@MainActor
final class VoiceCatalog: ObservableObject {
    static let shared = VoiceCatalog()

    /// Ghi chú dựa trên đo cao độ (F0) của 10 câu thoại: giọng dao động nhiều giữa các câu nghe như nhiều người khác nhau.
    static let voices: [LocalVoice] = [
        LocalVoice(id: "minhquang", name: "Minh Quang", note: "nam · ổn định nhất trong các giọng nam"),
        LocalVoice(id: "manhdung", name: "Mạnh Dũng", note: "nam · ổn định"),
        LocalVoice(id: "chieuthanh", name: "Chiếu Thành", note: "nam trầm · cao độ đổi khá nhiều giữa các câu"),
        LocalVoice(id: "thientam", name: "Thiện Tâm", note: "nam rất trầm · cao độ đổi nhiều giữa các câu"),
        LocalVoice(id: "deepman3909", name: "Deep Man", note: "nam giọng cao · cao độ đổi nhiều giữa các câu"),
        LocalVoice(id: "lacphi", name: "Lạc Phi", note: "nữ · ổn định nhất trong các giọng nữ"),
        LocalVoice(id: "banmai", name: "Ban Mai", note: "nữ · ổn định"),
        LocalVoice(id: "calmwoman3688", name: "Calm Woman", note: "nữ trầm"),
        LocalVoice(id: "maiphuong", name: "Mai Phương", note: "nữ"),
        LocalVoice(id: "phuongtrang", name: "Phương Trang", note: "nữ"),
        LocalVoice(id: "minhthu", name: "Minh Thu", note: "nữ giọng cao"),
    ]
    nonisolated static let defaultVoiceID = "minhquang"

    nonisolated static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ScreenTranslator/voices", isDirectory: true)
    }
    nonisolated static func modelURL(_ id: String) -> URL { dir.appendingPathComponent("\(id).onnx") }
    nonisolated static var tokensURL: URL { dir.appendingPathComponent("tokens.txt") }
    nonisolated static var espeakURL: URL { dir.appendingPathComponent("espeak-ng-data", isDirectory: true) }
    nonisolated static func isInstalled(_ id: String) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: modelURL(id).path) && fm.fileExists(atPath: tokensURL.path)
            && fm.fileExists(atPath: espeakURL.appendingPathComponent("phontab").path)
    }

    private static let modelBase = "https://huggingface.co/doof-ferb/nghitts-copy/resolve/main/sherpa-onnx/"
    private static let espeakArchive = "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/espeak-ng-data.tar.bz2"

    @Published private(set) var installed: Set<String> = []
    @Published private(set) var downloading: [String: Double] = [:]   // id → tiến độ 0...1
    @Published private(set) var errors: [String: String] = [:]

    private init() { refresh() }

    func refresh() { installed = Set(Self.voices.map(\.id).filter(Self.isInstalled)) }

    func download(_ id: String) {
        guard downloading[id] == nil else { return }
        downloading[id] = 0
        errors[id] = nil
        Task {
            do {
                try FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
                try await ensureCommonFiles()
                try await fetch(URL(string: Self.modelBase + "\(id).onnx")!, to: Self.modelURL(id)) { [weak self] p in
                    Task { @MainActor in self?.downloading[id] = p }
                }
                Log.info("VoiceCatalog: đã tải giọng \(id)")
            } catch {
                errors[id] = error.localizedDescription
                Log.error("VoiceCatalog: tải giọng \(id) lỗi: \(error.localizedDescription)")
            }
            downloading[id] = nil
            refresh()
        }
    }

    func delete(_ id: String) {
        try? FileManager.default.removeItem(at: Self.modelURL(id))
        refresh()
    }

    /// tokens.txt + espeak-ng-data (bảng phiên âm, 18 MB) dùng chung cho mọi giọng.
    private func ensureCommonFiles() async throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: Self.tokensURL.path) {
            try await fetch(URL(string: Self.modelBase + "tokens.txt")!, to: Self.tokensURL) { _ in }
        }
        if !fm.fileExists(atPath: Self.espeakURL.appendingPathComponent("phontab").path) {
            let archive = Self.dir.appendingPathComponent("espeak-ng-data.tar.bz2")
            try await fetch(URL(string: Self.espeakArchive)!, to: archive) { _ in }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            p.arguments = ["xjf", archive.path, "-C", Self.dir.path]
            try p.run()
            p.waitUntilExit()
            try? fm.removeItem(at: archive)
            guard p.terminationStatus == 0 else { throw URLError(.cannotDecodeContentData) }
        }
    }

    private func fetch(_ url: URL, to dest: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let delegate = ProgressDelegate(progress)
        let (tmp, resp) = try await URLSession.shared.download(from: url, delegate: delegate)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let onProgress: @Sendable (Double) -> Void
        init(_ p: @escaping @Sendable (Double) -> Void) { onProgress = p }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if totalBytesExpectedToWrite > 0 { onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }
}
