import SwiftUI

/// Mỗi nhân vật một màu cố định (theo thứ tự trong danh sách tên đã học của game), dùng để tô tên ở overlay, dải phụ đề và nhật ký.
@MainActor
enum SpeakerColors {
    /// 12 màu dễ phân biệt, đủ đậm để đọc trên nền trắng.
    private static let palette: [(Double, Double, Double)] = [
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
    ]

    static func index(for name: String) -> Int {
        let speakers = AppSettings.shared.speakers
        let canon = SpeakerNames.canonical(name, speakers: speakers) ?? name
        if let i = speakers.firstIndex(where: { $0.lowercased() == canon.lowercased() }) { return i % palette.count }
        // Tên chưa học: màu theo chữ, ổn định giữa các lần chạy.
        let h = canon.lowercased().unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }
        return abs(h) % palette.count
    }

    /// `onDark`: dùng trên nền tối (overlay) → pha sáng lên cho dễ đọc.
    static func color(for name: String, onDark: Bool = false) -> Color {
        let (r, g, b) = palette[index(for: name)]
        if onDark { return Color(red: r + (1 - r) * 0.45, green: g + (1 - g) * 0.45, blue: b + (1 - b) * 0.45) }
        return Color(red: r, green: g, blue: b)
    }

    /// Tô màu + in đậm phần "Tên:" ở đầu mỗi dòng. Game không hiện tên người nói thì trả về chữ thường.
    static func styled(_ text: String, size: CGFloat, weight: Font.Weight = .regular, onDark: Bool = false) -> AttributedString {
        var out = AttributedString()
        let colorize = AppSettings.shared.showsSpeakerNames
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            if i > 0 { out += AttributedString("\n") }
            var a = AttributedString(line)
            a.font = .system(size: size, weight: weight)
            if colorize, let r = line.range(of: #"^[^:：]{1,30}[:：]"#, options: .regularExpression),
               line[r].split(separator: " ").count <= 6, let ar = Range(NSRange(r, in: line), in: a) {
                let name = String(line[r].dropLast()).trimmingCharacters(in: .whitespaces)
                a[ar].font = .system(size: size, weight: .bold)
                a[ar].foregroundColor = color(for: name, onDark: onDark)
            }
            out += a
        }
        return out
    }
}
