import SwiftUI
import AppKit
import ImageIO

/// Ảnh "dịch màn hình" đang mở trong modal của cửa sổ chính (nil = đóng).
@MainActor
final class ShotViewer: ObservableObject {
    static let shared = ShotViewer()
    @Published private(set) var currentID: Int64?

    func show(_ id: Int64) { currentID = id }
    func close() { currentID = nil }
}

/// Đọc ảnh chụp đã lưu (file JPEG trong Application Support) và giữ tạm trong bộ nhớ.
enum ShotImages {
    private static let cache: NSCache<NSString, CGImage> = {
        let c = NSCache<NSString, CGImage>()
        c.countLimit = 40
        return c
    }()

    /// `maxPixel` = nil: ảnh đầy đủ; có giá trị: ảnh thu nhỏ cho danh sách.
    static func load(_ id: Int64, maxPixel: Int? = nil) -> CGImage? {
        let key = "\(id)-\(maxPixel ?? 0)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let src = CGImageSourceCreateWithURL(HistoryStore.shotURL(id) as CFURL, nil) else { return nil }
        let img: CGImage?
        if let maxPixel {
            img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ] as CFDictionary)
        } else {
            img = CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        if let img { cache.setObject(img, forKey: key) }
        return img
    }

    static func thumbnailJPEG(_ id: Int64, maxPixel: Int) -> Data? {
        guard let img = load(id, maxPixel: maxPixel) else { return nil }
        return NSBitmapImageRep(cgImage: img).representation(using: .jpeg, properties: [.compressionFactor: 0.6])
    }
}

/// Ảnh chụp đứng yên + bản dịch đè lên đúng vị trí từng khối chữ.
struct TranslatedShotView: View {
    let image: CGImage
    let items: [ShotItem]
    let showSource: Bool

    var body: some View {
        GeometryReader { geo in
            let iw = CGFloat(image.width), ih = CGFloat(image.height)
            let scale = min(geo.size.width / iw, geo.size.height / ih)
            let fit = CGSize(width: iw * scale, height: ih * scale)
            let origin = CGPoint(x: (geo.size.width - fit.width) / 2, y: (geo.size.height - fit.height) / 2)
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1).resizable().interpolation(.high)
                    .frame(width: fit.width, height: fit.height).offset(x: origin.x, y: origin.y)
                if !showSource {
                    ForEach(items) { it in ShotBox(item: it, fit: fit, origin: origin) }
                }
            }
        }
    }
}

/// Một khối bản dịch đặt đè lên chữ gốc.
private struct ShotBox: View {
    let item: ShotItem
    let fit: CGSize
    let origin: CGPoint

    var body: some View {
        let w = item.w * fit.width, h = item.h * fit.height
        // Tiếng Việt thường dài hơn tiếng Anh: cho hộp rộng thêm, chữ tự co cho vừa.
        let boxW = min(max(w * 1.15, w + 12), fit.width - item.x * fit.width)
        let size = max(9, h / CGFloat(item.lines) * 0.74)
        Text(item.target)
            .font(.system(size: size, weight: .medium))
            .minimumScaleFactor(0.45)
            .lineLimit(item.lines + (item.lines > 1 ? 1 : 0))
            .foregroundStyle(.white)
            .padding(.horizontal, 3)
            .frame(width: boxW, height: h + 2, alignment: .leading)
            .background(Color.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 3))
            .offset(x: origin.x + item.x * fit.width - 3, y: origin.y + item.y * fit.height - 1)
            .help(item.source)
    }
}

/// Modal phủ cửa sổ chính: ảnh đã dịch, lùi/tới giữa các ảnh đã chụp (←/→), Esc để đóng.
struct ShotModal: View {
    let id: Int64
    @ObservedObject var store = HistoryStore.shared
    @ObservedObject var viewer = ShotViewer.shared
    @State private var showSource = false

    /// Các mục còn ảnh, cũ → mới.
    private var shots: [ScreenAnalysis] { store.analyses.filter(\.hasImage).reversed() }

    var body: some View {
        let shots = shots
        let index = shots.firstIndex { $0.id == id }
        ZStack {
            Color.black.onTapGesture { viewer.close() }
            if let index, let image = ShotImages.load(id) {
                let shot = shots[index]
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Text("\(index + 1)/\(shots.count)").monospacedDigit().foregroundStyle(.white.opacity(0.6))
                        Text("\(shot.timestamp.hms) · \(shot.items.count) khối chữ").foregroundStyle(.white.opacity(0.6)).monospacedDigit()
                        Spacer()
                        Toggle(isOn: $showSource) { Label("Xem bản gốc", systemImage: "eye") }.toggleStyle(.button)
                        Button { step(-1, in: shots, from: index) } label: { Image(systemName: "chevron.left") }
                            .keyboardShortcut(.leftArrow, modifiers: []).disabled(index == 0).help("Ảnh chụp trước (←)")
                        Button { step(1, in: shots, from: index) } label: { Image(systemName: "chevron.right") }
                            .keyboardShortcut(.rightArrow, modifiers: []).disabled(index == shots.count - 1).help("Ảnh chụp sau (→)")
                        Button { viewer.close() } label: { Label("Đóng", systemImage: "xmark") }
                            .keyboardShortcut(.cancelAction)
                    }
                    .font(.callout).padding(.horizontal, 14).padding(.vertical, 8)
                    TranslatedShotView(image: image, items: shot.items, showSource: showSource)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if !shot.summary.isEmpty {
                        Text(shot.summary).font(.callout).foregroundStyle(.white.opacity(0.85)).lineLimit(3)
                            .multilineTextAlignment(.center).textSelection(.enabled)
                            .padding(.horizontal, 24).padding(.vertical, 10)
                    }
                }
            } else {
                VStack(spacing: 10) {
                    Text("Ảnh này không còn được lưu.").foregroundStyle(.white.opacity(0.7))
                    Button("Đóng") { viewer.close() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private func step(_ d: Int, in shots: [ScreenAnalysis], from index: Int) {
        let i = index + d
        if shots.indices.contains(i) { viewer.show(shots[i].id) }
    }
}

/// Ảnh thu nhỏ của một lần chụp, nạp ngoài luồng chính.
struct ShotThumb: View {
    let id: Int64
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color.black
            if let image { Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit) }
        }
        .task(id: id) {
            image = await Task.detached(priority: .utility) { ShotImages.load(id, maxPixel: 640) }.value
        }
    }
}
