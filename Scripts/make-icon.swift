// Sinh AppIcon.iconset từ SF Symbol trên nền gradient. Dùng: swift Scripts/make-icon.swift <iconset-dir>
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let size = NSSize(width: px, height: px)
    let img = NSImage(size: size)
    img.lockFocus()
    let s = CGFloat(px)
    let inset = s * 0.05
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.21, yRadius: s * 0.21)
    let grad = NSGradient(colors: [NSColor(red: 0.38, green: 0.44, blue: 0.98, alpha: 1),
                                   NSColor(red: 0.16, green: 0.76, blue: 0.70, alpha: 1)])!
    grad.draw(in: path, angle: -55)
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.50, weight: .semibold)
    if let sym = NSImage(systemSymbolName: "captions.bubble.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let tinted = NSImage(size: sym.size)
        tinted.lockFocus()
        sym.draw(at: .zero, from: NSRect(origin: .zero, size: sym.size), operation: .sourceOver, fraction: 1)
        NSColor.white.set()
        NSRect(origin: .zero, size: sym.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        let dst = NSRect(x: (s - sym.size.width) / 2, y: (s - sym.size.height) / 2 + s * 0.02, width: sym.size.width, height: sym.size.height)
        NSGraphicsContext.current?.cgContext.setShadow(offset: CGSize(width: 0, height: -s * 0.015), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        tinted.draw(in: dst)
    }
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    rep.size = size
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(outDir)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(outDir)/icon_\(base)x\(base)@2x.png"))
}
print("iconset written to \(outDir)")
