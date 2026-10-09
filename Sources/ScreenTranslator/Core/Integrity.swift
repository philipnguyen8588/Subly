import Foundation
import Security

/// Vài lớp làm khó việc can thiệp lúc chạy. Chỉ bật ở bản phát hành (có cấu hình server);
/// bản dev (không có subly.local.env) bỏ qua để còn gỡ lỗi được. Không phải chống phá tuyệt đối —
/// khoá thật nằm ở server duyệt máy.
enum Integrity {
    /// Gọi sớm lúc khởi động bản phát hành.
    static func arm() {
        guard RuntimeConfig.enabled else { return }
        denyDebugger()
        if !signatureIntact() {
            // File chạy đã bị sửa sau khi ký (vá nhị phân) → dừng, không nêu lý do.
            exit(0)
        }
    }

    /// Chặn gắn debugger (lldb/attach). Người thạo vẫn vượt được, chỉ cản kiểu phổ thông.
    private static func denyDebugger() {
        _ = _pt(PT_DENY_ATTACH, 0, nil, 0)
    }

    /// Chữ ký của tiến trình đang chạy còn nguyên vẹn? Vá thẳng file chạy làm chữ ký hỏng → false.
    private static func signatureIntact() -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, [], nil) == errSecSuccess
    }
}

// PT_DENY_ATTACH = 31; ptrace không được phơi bày trực tiếp trong Swift nên gọi qua tên hàm C.
private let PT_DENY_ATTACH: Int32 = 31
@_silgen_name("ptrace")
private func _pt(_ request: Int32, _ pid: pid_t, _ addr: UnsafeMutableRawPointer?, _ data: Int32) -> Int32
