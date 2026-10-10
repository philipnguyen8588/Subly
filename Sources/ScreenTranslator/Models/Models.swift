import Foundation
import CoreGraphics

/// Vùng gắn app: khi app không ở phía trước thì làm gì.
enum RegionAppMode: String, Codable, CaseIterable, Identifiable {
    case followWindow      // chụp thẳng cửa sổ app → vẫn dịch dù bị che / Tab qua app khác
    case pauseWhenInactive // chụp màn hình, tạm dừng khi app không ở phía trước
    var id: String { rawValue }
    var label: String { self == .followWindow ? "Vẫn dịch (bám cửa sổ)" : "Tạm dừng" }
}

enum RegionKind: String, Codable, CaseIterable {
    case subtitle, manual
    var label: String { self == .subtitle ? "Phụ đề" : "Thủ công" }
}

/// Vùng màn hình. `rect` theo toạ độ CoreGraphics toàn cục (gốc trên-trái, point).
struct Region: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var displayID: UInt32
    var x: Double, y: Double, width: Double, height: Double
    var enabled: Bool = true
    var kind: RegionKind = .subtitle
    var appBundleID: String? = nil     // gắn với app
    var appName: String? = nil
    var windowID: UInt32? = nil        // cửa sổ lúc vẽ (có thể đổi sau khi app khởi động lại)
    var winOffsetX: Double? = nil      // vị trí vùng tương đối với góc trên-trái cửa sổ
    var winOffsetY: Double? = nil
    var winWidth: Double? = nil        // kích thước cửa sổ lúc vẽ → cửa sổ đổi cỡ thì vùng co giãn theo tỉ lệ
    var winHeight: Double? = nil
    var appMode: RegionAppMode = .followWindow
    /// Vùng trên hình PS5 nhúng trong app: x/y/width/height là tỉ lệ 0...1 của khung hình, không phải toạ độ màn hình.
    var embedded: Bool = false
    /// Khu vực dịch thêm (ngoài khung phụ đề chính): không lấy tên nhân vật, không đọc thành tiếng,
    /// bản dịch hiện ngay tại khung thay vì ở dải phụ đề chung.
    var extra: Bool = false

    var rect: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set { x = newValue.minX; y = newValue.minY; width = newValue.width; height = newValue.height }
    }

    init(id: UUID = UUID(), name: String, displayID: UInt32, x: Double, y: Double, width: Double, height: Double,
         enabled: Bool = true, kind: RegionKind = .subtitle) {
        self.id = id; self.name = name; self.displayID = displayID
        self.x = x; self.y = y; self.width = width; self.height = height
        self.enabled = enabled; self.kind = kind
    }

    enum CodingKeys: String, CodingKey { case id, name, displayID, x, y, width, height, enabled, kind, appBundleID, appName, windowID, winOffsetX, winOffsetY, winWidth, winHeight, appMode, embedded, extra }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        displayID = try c.decode(UInt32.self, forKey: .displayID)
        x = try c.decode(Double.self, forKey: .x); y = try c.decode(Double.self, forKey: .y)
        width = try c.decode(Double.self, forKey: .width); height = try c.decode(Double.self, forKey: .height)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        kind = try c.decodeIfPresent(RegionKind.self, forKey: .kind) ?? .subtitle
        appBundleID = try c.decodeIfPresent(String.self, forKey: .appBundleID)
        appName = try c.decodeIfPresent(String.self, forKey: .appName)
        windowID = try c.decodeIfPresent(UInt32.self, forKey: .windowID)
        winOffsetX = try c.decodeIfPresent(Double.self, forKey: .winOffsetX)
        winOffsetY = try c.decodeIfPresent(Double.self, forKey: .winOffsetY)
        winWidth = try c.decodeIfPresent(Double.self, forKey: .winWidth)
        winHeight = try c.decodeIfPresent(Double.self, forKey: .winHeight)
        appMode = try c.decodeIfPresent(RegionAppMode.self, forKey: .appMode) ?? .followWindow
        embedded = try c.decodeIfPresent(Bool.self, forKey: .embedded) ?? false
        extra = try c.decodeIfPresent(Bool.self, forKey: .extra) ?? false
    }

    /// Vùng tính theo góc trên-trái cửa sổ, co giãn theo tỉ lệ nếu cửa sổ đã đổi kích thước so với lúc vẽ.
    func localRect(inWindowOfSize size: CGSize) -> CGRect? {
        guard let ox = winOffsetX, let oy = winOffsetY else { return nil }
        var sx = 1.0, sy = 1.0
        if let w0 = winWidth, let h0 = winHeight, w0 > 1, h0 > 1, size.width > 1, size.height > 1 {
            sx = Double(size.width) / w0; sy = Double(size.height) / h0
        }
        return CGRect(x: ox * sx, y: oy * sy, width: width * sx, height: height * sy)
    }

    /// Có đủ thông tin để chụp thẳng cửa sổ app (bám cửa sổ) không.
    var followsWindow: Bool { !embedded && appMode == .followWindow && appBundleID != nil && winOffsetX != nil && winOffsetY != nil }
}

struct GlossaryEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var term: String
    var translation: String = ""
    var keepAsIs: Bool = false
}

/// Giọng văn và cách xưng hô khi dịch phụ đề, chọn theo bối cảnh của game.
enum TranslationStyle: String, Codable, CaseIterable, Identifiable {
    case auto, modern, fantasy, myth
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Tự động theo tên game"
        case .modern: return "Hiện đại / đường phố"
        case .fantasy: return "Kỳ ảo trung cổ (hiệp sĩ, lãnh chúa)"
        case .myth: return "Thần thoại sử thi"
        }
    }
    /// Đoán phong cách từ tên game; không nhận ra thì dùng hiện đại.
    static func guess(_ gameName: String) -> TranslationStyle {
        let n = gameName.lowercased()
        if ["god of war", "ragnar", "assassin's creed odyssey", "hades"].contains(where: n.contains) { return .myth }
        if ["final fantasy", "ff16", "ffxvi", "witcher", "elden", "dragon", "skyrim", "baldur", "dark souls", "zelda", "kingdom come", "lord of the rings"].contains(where: n.contains) { return .fantasy }
        return .modern
    }
}

/// Nguồn hình của một profile: app/cửa sổ trên máy này, hoặc PS5 nhúng trong app.
enum ProfileSource: String, Codable, CaseIterable, Identifiable {
    case external, ps5
    var id: String { rawValue }
    var label: String { self == .external ? "App trên máy này" : "PS5" }
    var icon: String { self == .external ? "macwindow" : "playstation.logo" }
}

struct Profile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var source: ProfileSource = .external
    var regions: [Region] = []
    var glossary: [GlossaryEntry] = []
    var showsSpeakerNames: Bool = true     // game có hiện "Tên: câu thoại" không
    var speakers: [String] = []            // tên nhân vật đã học
    var speakerAbove = false               // tên hiện ở dòng riêng phía trên câu thoại (không có dấu hai chấm)
    var translationStyle: TranslationStyle = .auto
    var translationNote = ""               // ghi chú tự do cho người dịch (xưng hô riêng giữa các nhân vật…)

    init(id: UUID = UUID(), name: String, source: ProfileSource = .external, regions: [Region] = [], glossary: [GlossaryEntry] = [],
         showsSpeakerNames: Bool = true, speakers: [String] = []) {
        self.id = id; self.name = name; self.source = source; self.regions = regions; self.glossary = glossary
        self.showsSpeakerNames = showsSpeakerNames; self.speakers = speakers
    }

    enum CodingKeys: String, CodingKey { case id, name, source, regions, glossary, showsSpeakerNames, speakers, speakerAbove, translationStyle, translationNote }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        regions = try c.decodeIfPresent([Region].self, forKey: .regions) ?? []
        glossary = try c.decodeIfPresent([GlossaryEntry].self, forKey: .glossary) ?? []
        showsSpeakerNames = try c.decodeIfPresent(Bool.self, forKey: .showsSpeakerNames) ?? true
        speakers = try c.decodeIfPresent([String].self, forKey: .speakers) ?? []
        speakerAbove = try c.decodeIfPresent(Bool.self, forKey: .speakerAbove) ?? false
        translationStyle = try c.decodeIfPresent(TranslationStyle.self, forKey: .translationStyle) ?? .auto
        translationNote = try c.decodeIfPresent(String.self, forKey: .translationNote) ?? ""
        // Profile cũ chưa có nguồn: có vùng PS5 nhúng thì coi là PS5.
        source = try c.decodeIfPresent(ProfileSource.self, forKey: .source) ?? (regions.contains { $0.embedded } ? .ps5 : .external)
    }
}

enum QueueMode: String, Codable, CaseIterable, Identifiable {
    case latestWins, fifo
    var id: String { rawValue }
    var label: String { self == .latestWins ? "Phụ đề (chỉ giữ câu mới nhất)" : "Hội thoại (đọc lần lượt)" }
}

enum TranslationEngine: String, Codable, CaseIterable, Identifiable {
    case auto, appleIntelligence, appleTranslation, openAI
    var id: String { rawValue }
    var label: String {
        switch self {
        case .openAI: return "OpenAI (cần mạng, trả phí, ~0,9 s/câu) → dự phòng Apple Intelligence"
        case .auto: return "Tự động: Gemini → Apple Translation"
        case .appleIntelligence: return "Apple Intelligence (offline, có ngữ cảnh, ~0,8 s/câu)"
        case .appleTranslation: return "Apple Translation (offline, nhanh nhất ~30 ms)"
        }
    }
}

/// Engine cho "Dịch màn hình" (chọn riêng với phụ đề: phụ đề cần nhanh, dịch màn hình cần hiểu kỹ).
enum ScreenEngine: String, Codable, CaseIterable, Identifiable {
    case gemini, openAI, appleIntelligence, appleTranslation
    var id: String { rawValue }
    var label: String {
        switch self {
        case .gemini: return "Gemini (cần mạng, miễn phí, ~4–8 s) → dự phòng trên máy"
        case .openAI: return "OpenAI (cần mạng, trả phí, ~3,5 s) → dự phòng trên máy"
        case .appleIntelligence: return "Apple Intelligence (offline)"
        case .appleTranslation: return "Apple Translation (offline, nhanh, tóm tắt bằng Apple Intelligence)"
        }
    }
}

enum OverlayPosition: String, Codable, CaseIterable, Identifiable {
    case belowRegion, aboveRegion, screenBottom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .belowRegion: return "Ngay dưới vùng"
        case .aboveRegion: return "Ngay trên vùng"
        case .screenBottom: return "Đáy màn hình"
        }
    }
}

/// Tổ hợp phím toàn cục (mã Carbon).
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // cmdKey | optionKey | shiftKey | controlKey

    static let cmd: UInt32 = 256, shift: UInt32 = 512, option: UInt32 = 2048, control: UInt32 = 4096

    var display: String {
        var s = ""
        if modifiers & KeyCombo.control != 0 { s += "⌃" }
        if modifiers & KeyCombo.option != 0 { s += "⌥" }
        if modifiers & KeyCombo.shift != 0 { s += "⇧" }
        if modifiers & KeyCombo.cmd != 0 { s += "⌘" }
        return s + KeyCombo.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        let map: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W",
            14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
            26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J",
            39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 49: "Space", 50: "`",
            36: "↩", 48: "⇥", 51: "⌫", 53: "⎋", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
            103: "F11", 109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        return map[code] ?? "key\(code)"
    }
}

struct TargetLanguage: Identifiable, Equatable {
    let code: String        // BCP-47 dùng cho Apple Translation & voice
    let name: String        // hiển thị
    let englishName: String // đưa vào prompt Gemini
    var id: String { code }

    static let all: [TargetLanguage] = [
        .init(code: "vi", name: "Tiếng Việt", englishName: "Vietnamese"),
        .init(code: "en", name: "English", englishName: "English"),
        .init(code: "ja", name: "日本語", englishName: "Japanese"),
        .init(code: "ko", name: "한국어", englishName: "Korean"),
        .init(code: "zh-Hans", name: "中文 (简体)", englishName: "Simplified Chinese"),
        .init(code: "zh-Hant", name: "中文 (繁體)", englishName: "Traditional Chinese"),
        .init(code: "fr", name: "Français", englishName: "French"),
        .init(code: "de", name: "Deutsch", englishName: "German"),
        .init(code: "es", name: "Español", englishName: "Spanish"),
        .init(code: "th", name: "ไทย", englishName: "Thai"),
        .init(code: "id", name: "Bahasa Indonesia", englishName: "Indonesian"),
    ]
    static func find(_ code: String) -> TargetLanguage { all.first { $0.code == code } ?? all[0] }
}
