import Foundation
import IOKit
import CryptoKit
import SystemConfiguration

/// Thông tin nhận dạng máy: mã phần cứng (băm) và vài thông tin để chủ app nhận ra máy trên trang quản trị.
enum HostIdentity {
    /// SHA-256 (hex) của UUID bo mạch + số serial. Không đổi khi cài lại macOS hay đổi tên máy.
    static let hash: String = {
        let raw = "subly-v1|" + platformProperty("IOPlatformUUID") + "|" + platformProperty("IOPlatformSerialNumber")
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }()

    private static func platformProperty(_ key: String) -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return "" }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String ?? ""
    }

    /// Tên máy trong Cài đặt → Chung → Giới thiệu (không tra DNS như Host.current()).
    static var name: String { (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? ProcessInfo.processInfo.hostName }
    static var user: String { NSUserName() }

    /// Ví dụ "Mac16,10".
    static var model: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}

extension Data {
    init?(base64URL s: String) {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        t += String(repeating: "=", count: (4 - t.count % 4) % 4)
        self.init(base64Encoded: t)
    }

    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
