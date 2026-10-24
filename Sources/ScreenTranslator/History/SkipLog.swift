import Foundation

/// Nhật ký chữ OCR đọc được nhưng bị bỏ qua (menu, mẩu lạc, cảm thán, chữ mờ…), để xem lại trong tab "Bị bỏ qua"
/// và chỉnh bộ lọc nếu nó bỏ nhầm câu thoại. Lưu ở skipped.jsonl (mỗi dòng một mục), chỉ giữ `maxEntries` mục mới nhất.
@MainActor
final class SkipLog: ObservableObject {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case ui, stray, interjection, simple, junk, faint
        var id: String { rawValue }
        var title: String {
            switch self {
            case .ui: return "Menu"
            case .stray: return "Mẩu lạc"
            case .interjection: return "Cảm thán"
            case .simple: return "Đơn giản"
            case .junk: return "Vô nghĩa"
            case .faint: return "Chữ mờ"
            }
        }
        var help: String {
            switch self {
            case .ui: return "Chữ giao diện: menu, cài đặt, thanh nút bấm, danh sách"
            case .stray: return "Mẩu chữ 1–2 từ đứng một mình, không dấu câu (chữ trong cảnh game, nút bấm)"
            case .interjection: return "Câu chỉ có từ cảm thán (hmm, haha, huh…)"
            case .simple: return "Câu tối đa 5 từ, toàn từ cơ bản hoặc tên nhân vật, người chơi tự hiểu"
            case .junk: return "Câu ngắn không có từ tiếng Anh thật (OCR đọc nhầm)"
            case .faint: return "Chữ có độ tương phản thấp (đồng hồ tốc độ, chữ chìm trong cảnh)"
            }
        }
    }

    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        let time: Date
        let profile: String       // UUID của game lúc bỏ qua
        let region: String
        let kind: Kind
        let reason: String
        let text: String
    }

    static let shared = SkipLog()
    static let maxEntries = 3000

    @Published private(set) var entries: [Entry] = []
    private let url = AppPaths.file("skipped.jsonl")
    private let io = DispatchQueue(label: "skiplog", qos: .utility)

    private init() {
        guard let data = try? Data(contentsOf: url) else { return }
        let dec = Self.decoder
        entries = data.split(separator: UInt8(ascii: "\n")).compactMap { try? dec.decode(Entry.self, from: Data($0)) }
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries); rewrite() }
    }

    /// Gọi được từ luồng OCR.
    nonisolated static func add(_ kind: Kind, _ text: String, reason: String = "", region: String, profile: String) {
        let e = Entry(time: Date(), profile: profile, region: region, kind: kind, reason: reason, text: text)
        DispatchQueue.main.async { SkipLog.shared.append(e) }
    }

    private func append(_ e: Entry) {
        entries.append(e)
        // Ghi nối tiếp; vượt quá giới hạn một khoảng thì cắt bớt và ghi lại cả file.
        if entries.count > Self.maxEntries + 300 {
            entries.removeFirst(entries.count - Self.maxEntries)
            rewrite()
            return
        }
        guard var line = try? Self.encoder.encode(e) else { return }
        line.append(UInt8(ascii: "\n"))
        let url = url
        io.async {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(line); try? h.close()
            } else {
                try? line.write(to: url)
            }
        }
    }

    /// Xoá các mục của một game.
    func clear(profile: String) {
        entries.removeAll { $0.profile == profile }
        rewrite()
    }

    private func rewrite() {
        let enc = Self.encoder
        var data = Data()
        for e in entries {
            guard let line = try? enc.encode(e) else { continue }
            data.append(line); data.append(UInt8(ascii: "\n"))
        }
        let url = url
        io.async { try? data.write(to: url, options: .atomic) }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d
    }()
}
