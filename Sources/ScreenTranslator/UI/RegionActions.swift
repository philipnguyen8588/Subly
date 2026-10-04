import AppKit
import SwiftUI

/// Thao tác vùng dùng chung cho cửa sổ chính và menu bar.
@MainActor
enum RegionActions {
    // MARK: App ngoài: đúng hai khung (màn hình game + phụ đề)

    /// Vẽ khung toàn bộ khu vực hiển thị game trên màn hình. Thay khung cũ; khung phụ đề đặt lại về dải dưới.
    static func pickGameArea() {
        let settings = AppSettings.shared
        RegionPicker.shared.begin { result in
            guard let (rect, display) = result else { return }
            var area = Region(name: "Màn hình game", displayID: display, x: rect.minX, y: rect.minY,
                              width: rect.width, height: rect.height, kind: .manual)
            attachWindow(&area)
            var regions = settings.regions.filter { $0.embedded }      // giữ vùng PS5 (nếu có), bỏ các khung app ngoài cũ
            regions.append(area)
            settings.regions = regions
            Log.info("Vùng game: \(Int(rect.width))×\(Int(rect.height)) \(area.appName.map { "gắn với \($0)" } ?? "(không gắn app)")")
            setExternalSubtitle(normalized: CGRect(x: 0.10, y: 0.74, width: 0.80, height: 0.22))
            NSApp.activate(ignoringOtherApps: true)
            WindowManager.shared.showMain()
        }
    }

    /// Đặt khung phụ đề theo tỉ lệ (0...1) bên trong khung màn hình game. Khung phụ đề bám cùng cửa sổ với khung game.
    static func setExternalSubtitle(normalized n: CGRect) {
        let settings = AppSettings.shared
        guard let area = settings.externalArea else { return }
        let a = WindowFinder.currentRect(of: area)
        let rect = CGRect(x: a.minX + n.minX * a.width, y: a.minY + n.minY * a.height,
                          width: n.width * a.width, height: n.height * a.height).integral
        var sub = settings.externalSubtitle ?? Region(name: "Phụ đề", displayID: area.displayID, x: 0, y: 0, width: 1, height: 1)
        sub.displayID = area.displayID
        sub.rect = rect
        sub.appBundleID = area.appBundleID; sub.appName = area.appName; sub.windowID = area.windowID; sub.appMode = area.appMode
        if area.followsWindow, let wid = area.windowID, let b = WindowFinder.bounds(of: wid) {
            sub.winOffsetX = rect.minX - b.minX; sub.winOffsetY = rect.minY - b.minY
            sub.winWidth = Double(b.width); sub.winHeight = Double(b.height)
        } else {
            sub.winOffsetX = nil; sub.winOffsetY = nil; sub.winWidth = nil; sub.winHeight = nil
        }
        var regions = settings.regions.filter { $0.embedded || $0.kind == .manual }   // chỉ một khung phụ đề app ngoài
        regions.append(sub)
        settings.regions = regions
        Log.info("Khung phụ đề app ngoài: \(String(format: "x %.2f y %.2f w %.2f h %.2f", n.minX, n.minY, n.width, n.height))")
        Pipeline.shared.restartIfRunning()
    }

    static func add(kind: RegionKind) {
        let settings = AppSettings.shared
        RegionPicker.shared.begin { result in
            guard let (rect, display) = result else { return }
            let def = kind == .subtitle ? "Phụ đề \(settings.subtitleRegions.count + 1)" : "Màn hình game"
            let name = askName(default: def)
            var r = Region(name: name, displayID: display, x: rect.minX, y: rect.minY,
                           width: rect.width, height: rect.height, kind: kind)
            if let w = WindowFinder.window(under: CGPoint(x: rect.midX, y: rect.midY)) {
                r.appBundleID = w.app.bundleID; r.appName = w.app.name
                r.windowID = w.windowID
                r.winOffsetX = rect.minX - w.bounds.minX; r.winOffsetY = rect.minY - w.bounds.minY; r.winWidth = Double(w.bounds.width); r.winHeight = Double(w.bounds.height)
                Log.info("Vùng '\(name)' gắn với \(w.app.name), offset (\(Int(r.winOffsetX!)), \(Int(r.winOffsetY!)))")
            }
            settings.regions.append(r)
            RegionPreviewProvider.shared.refreshNow()
            if kind == .subtitle { Pipeline.shared.restartIfRunning() }
            RegionEditor.shared.show(r)     // hiện khung ngay để thấy vùng vừa vẽ, tinh chỉnh nếu cần
        }
    }

    static func repick(_ r: Region) {
        guard !r.embedded else { return }   // vùng PS5 nhúng: vẽ lại trong tab PS5
        let settings = AppSettings.shared
        RegionPicker.shared.begin { result in
            guard let (rect, display) = result, let i = settings.regions.firstIndex(where: { $0.id == r.id }) else { return }
            settings.regions[i].displayID = display
            settings.regions[i].rect = rect
            if let w = WindowFinder.window(under: CGPoint(x: rect.midX, y: rect.midY)) {
                settings.regions[i].appBundleID = w.app.bundleID; settings.regions[i].appName = w.app.name
                settings.regions[i].windowID = w.windowID
                settings.regions[i].winOffsetX = rect.minX - w.bounds.minX; settings.regions[i].winOffsetY = rect.minY - w.bounds.minY; settings.regions[i].winWidth = Double(w.bounds.width); settings.regions[i].winHeight = Double(w.bounds.height)
            } else {
                settings.regions[i].appBundleID = nil; settings.regions[i].appName = nil
                settings.regions[i].windowID = nil; settings.regions[i].winOffsetX = nil; settings.regions[i].winOffsetY = nil; settings.regions[i].winWidth = nil; settings.regions[i].winHeight = nil
            }
            RegionPreviewProvider.shared.refreshNow()
            if r.kind == .subtitle { Pipeline.shared.restartIfRunning() }
        }
    }

    static func bind(_ r: Region, to app: WindowFinder.AppInfo?) {
        let settings = AppSettings.shared
        guard let i = settings.regions.firstIndex(where: { $0.id == r.id }) else { return }
        settings.regions[i].appBundleID = app?.bundleID
        settings.regions[i].appName = app?.name
        // Gắn thủ công: tính offset theo cửa sổ lớn nhất đang hiện của app chứa vùng (nếu có)
        settings.regions[i].windowID = nil
        settings.regions[i].winOffsetX = nil; settings.regions[i].winOffsetY = nil; settings.regions[i].winWidth = nil; settings.regions[i].winHeight = nil
        if let app, let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for w in list {
                guard let pid = w[kCGWindowOwnerPID as String] as? Int32,
                      NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == app.bundleID,
                      (w[kCGWindowLayer as String] as? Int ?? 0) == 0,
                      let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                      let x = b["X"], let y = b["Y"], let wd = b["Width"], let ht = b["Height"],
                      let wid = w[kCGWindowNumber as String] as? UInt32 else { continue }
                let bounds = CGRect(x: x, y: y, width: wd, height: ht)
                if bounds.contains(CGPoint(x: r.rect.midX, y: r.rect.midY)) {
                    settings.regions[i].windowID = wid
                    settings.regions[i].winOffsetX = r.rect.minX - bounds.minX
                    settings.regions[i].winOffsetY = r.rect.minY - bounds.minY; settings.regions[i].winWidth = Double(bounds.width); settings.regions[i].winHeight = Double(bounds.height)
                    break
                }
            }
        }
        if r.kind == .subtitle { Pipeline.shared.restartIfRunning() }
    }

    /// Gắn cửa sổ cho một Region mới tạo (dùng chung cho vẽ tay và --add-region).
    static func attachWindow(_ r: inout Region) {
        guard let w = WindowFinder.window(under: CGPoint(x: r.rect.midX, y: r.rect.midY)) else { return }
        r.appBundleID = w.app.bundleID; r.appName = w.app.name
        r.windowID = w.windowID
        r.winOffsetX = r.rect.minX - w.bounds.minX; r.winOffsetY = r.rect.minY - w.bounds.minY; r.winWidth = Double(w.bounds.width); r.winHeight = Double(w.bounds.height)
    }

    /// Vùng tạo từ bản cũ: có app nhưng chưa có offset → bổ sung nếu cửa sổ của đúng app đó đang nằm dưới vùng.
    static func fillMissingWindowOffsets() {
        let settings = AppSettings.shared
        var regions = settings.regions
        var changed = false
        for i in regions.indices where regions[i].appBundleID != nil && regions[i].winOffsetX == nil {
            if let w = WindowFinder.window(under: CGPoint(x: regions[i].rect.midX, y: regions[i].rect.midY)),
               w.app.bundleID == regions[i].appBundleID {
                regions[i].windowID = w.windowID
                regions[i].winOffsetX = regions[i].rect.minX - w.bounds.minX
                regions[i].winOffsetY = regions[i].rect.minY - w.bounds.minY; regions[i].winWidth = Double(w.bounds.width); regions[i].winHeight = Double(w.bounds.height)
                changed = true
                Log.info("Bổ sung offset cửa sổ cho vùng '\(regions[i].name)'")
            }
        }
        // Vùng tạo trước khi có tính năng co giãn: ghi nhận kích thước cửa sổ hiện tại làm mốc.
        for i in regions.indices where regions[i].winOffsetX != nil && regions[i].winWidth == nil {
            if let wid = regions[i].windowID, let b = WindowFinder.bounds(of: wid), b.width > 1 {
                regions[i].winWidth = Double(b.width); regions[i].winHeight = Double(b.height)
                changed = true
            }
        }
        if changed { settings.regions = regions }
    }

    static func setAppMode(_ r: Region, _ mode: RegionAppMode) {
        let settings = AppSettings.shared
        guard let i = settings.regions.firstIndex(where: { $0.id == r.id }) else { return }
        settings.regions[i].appMode = mode
        if r.kind == .subtitle { Pipeline.shared.restartIfRunning() }
    }

    static func toggle(_ r: Region) {
        let settings = AppSettings.shared
        guard let i = settings.regions.firstIndex(where: { $0.id == r.id }) else { return }
        settings.regions[i].enabled.toggle()
        if r.kind == .subtitle { Pipeline.shared.restartIfRunning() }
    }

    static func rename(_ r: Region) {
        let settings = AppSettings.shared
        guard let i = settings.regions.firstIndex(where: { $0.id == r.id }) else { return }
        settings.regions[i].name = askName(default: r.name)
    }

    static func remove(_ r: Region) {
        let settings = AppSettings.shared
        settings.regions.removeAll { $0.id == r.id }
        RegionPreviewProvider.shared.remove(r.id)
        if r.kind == .subtitle { Pipeline.shared.restartIfRunning() }
    }

    static func askName(default def: String) -> String {
        let a = NSAlert()
        a.messageText = "Tên vùng"
        a.informativeText = "Ví dụ: Phụ đề, Hội thoại, Màn hình game…"
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        tf.stringValue = def
        a.accessoryView = tf
        a.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        a.window.initialFirstResponder = tf
        a.runModal()
        let s = tf.stringValue.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? def : s
    }
}
