import AppKit
import CoreGraphics

enum WindowFinder {
    struct AppInfo { let bundleID: String; let name: String }
    struct WindowInfo { let app: AppInfo; let windowID: UInt32; let bounds: CGRect }

    /// App sở hữu cửa sổ trên cùng chứa điểm `cgPoint` (toạ độ CG toàn cục), bỏ qua chính app này.
    static func app(under cgPoint: CGPoint) -> AppInfo? { window(under: cgPoint)?.app }

    static func window(under cgPoint: CGPoint) -> WindowInfo? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let me = getpid()
        for w in list {   // đã sắp xếp trước → sau
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32, pid != me,
                  (w[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let wd = b["Width"], let ht = b["Height"],
                  let wid = w[kCGWindowNumber as String] as? UInt32 else { continue }
            let bounds = CGRect(x: x, y: y, width: wd, height: ht)
            guard bounds.contains(cgPoint) else { continue }
            guard let app = NSRunningApplication(processIdentifier: pid), let bid = app.bundleIdentifier else { continue }
            return WindowInfo(app: AppInfo(bundleID: bid, name: app.localizedName ?? bid), windowID: wid, bounds: bounds)
        }
        return nil
    }

    /// Các app thường (có Dock icon) đang chạy, để gắn thủ công.
    static func runningApps() -> [AppInfo] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .compactMap { a in a.bundleIdentifier.map { AppInfo(bundleID: $0, name: a.localizedName ?? $0) } }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    static var frontmostBundleID: String? { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }

    /// Khung hiện tại (CG, gốc trên-trái) của một cửa sổ theo ID, nil nếu cửa sổ không còn.
    static func bounds(of windowID: UInt32) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowID)) as? [[String: Any]],
              let b = list.first?[kCGWindowBounds as String] as? [String: CGFloat],
              let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"] else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Vị trí vùng trên màn hình lúc này: vùng bám cửa sổ thì đi theo cửa sổ, còn lại dùng toạ độ đã lưu.
    static func currentRect(of region: Region) -> CGRect {
        if region.followsWindow, let wid = region.windowID, let b = bounds(of: wid),
           let l = region.localRect(inWindowOfSize: b.size) {
            return CGRect(x: b.minX + l.minX, y: b.minY + l.minY, width: l.width, height: l.height)
        }
        return region.rect
    }
}
