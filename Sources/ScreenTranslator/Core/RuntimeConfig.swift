import Foundation

/// Cấu hình nhúng lúc build (Scripts/gen_runtime_config.py), lưu dạng đã làm rối.
/// Bản build không có cấu hình thì `enabled == false`: app không kiểm tra máy (bản dùng riêng).
enum RuntimeConfig {
    static var enabled: Bool { !RuntimeConfigValues.a.isEmpty && RuntimeConfigValues.b.count == 32 }

    static var endpoint: String { String(decoding: decode(RuntimeConfigValues.a), as: UTF8.self) + "/v1/session" }
    static var verifier: Data { Data(decode(RuntimeConfigValues.b)) }

    private static func decode(_ v: [UInt8]) -> [UInt8] {
        let k = RuntimeConfigValues.k
        return v.enumerated().map { $0.element ^ k[$0.offset % k.count] }
    }
}
