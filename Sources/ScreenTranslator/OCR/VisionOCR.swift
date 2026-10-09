import Foundation
import Vision
import CoreVideo
import CoreGraphics

final class VisionOCR {
    struct Result {
        let text: String
        let lines: [String]
        let confidence: Float
        let level: VNRequestTextRecognitionLevel
        var ms: Double
        /// Bố cục, dùng để phân biệt phụ đề với chữ giao diện (menu/cài đặt).
        var observations = 0          // số mảnh chữ Vision trả về
        var rows = 0                  // số hàng sau khi gom
        var maxPerRow = 0             // nhiều mảnh trên một hàng = cột menu
        var heightRatio = 1.0         // chiều cao mảnh lớn nhất / nhỏ nhất = cỡ chữ lẫn lộn
        var lineHeights: [Double] = []   // chiều cao chữ của từng hàng trong `lines` (tỉ lệ theo chiều cao ảnh)
    }

    var languages: [String] = ["en-US"]
    var minTextHeight: Float = 0
    /// .accurate đọc đúng chữ mảnh trên nền video (~60 ms); .fast (~20 ms) hay đọc sai và luôn báo confidence 0.5.
    var level: VNRequestTextRecognitionLevel = .accurate
    /// Chỉ áp dụng ở .accurate (fast luôn báo 0.5): bỏ mảnh chữ mà Vision không chắc (thường là nền video).
    var minConfidence: Float = 0.45
    /// Chỉ nhận chữ nằm ở giữa khung theo chiều ngang (phụ đề luôn canh giữa); chữ ở mép như nút "Quick Save", "Back",
    /// biển hiệu trong cảnh game bị bỏ. Chỉ áp dụng cho `recognize` (vùng phụ đề).
    var centerOnly = false
    /// Dải giữa khung (tỉ lệ bề ngang): một cụm chữ phải chạm dải này mới được nhận.
    static let centerBand: ClosedRange<CGFloat> = 0.40...0.60
    /// Bỏ hàng có chữ thấp hơn mức này (tỉ lệ theo chiều cao ảnh). RegionWorker đặt theo cỡ chữ phụ đề đã học
    /// để loại chữ nhỏ trong cảnh game (đồng hồ "mph" trên bảng điều khiển xe…). Chỉ áp dụng cho `recognize`.
    var minRowHeight: CGFloat = 0

    /// Mọi lượt nhận dạng chữ trong app chạy lần lượt, không song song: đã gặp Vision treo hẳn (chờ Neural Engine mãi)
    /// khi OCR phụ đề và "Dịch màn hình" chạy cùng lúc.
    private static let visionLock = NSLock()
    private static func perform(_ handler: VNImageRequestHandler, _ req: VNRequest) throws {
        visionLock.lock(); defer { visionLock.unlock() }
        try handler.perform([req])
    }

    /// Cho phụ đề (frame từ SCStream).
    func recognize(_ pb: CVPixelBuffer) -> Result? {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let r = run(VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:]), level: level, centerOnly: centerOnly, minRowHeight: minRowHeight) else { return nil }
        var out = r
        out.ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        return out
    }

    /// Cho phân tích màn hình: accurate, trả về từng dòng.
    func recognizeLines(_ cg: CGImage) -> Result? {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let r = run(VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:]), level: .accurate) else { return nil }
        var out = r
        out.ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        return out
    }

    /// Một khối chữ kèm vị trí (chuẩn hoá 0...1, gốc trên-trái) để vẽ bản dịch đè lên đúng chỗ.
    struct Block {
        var text: String
        var box: CGRect
        var lines: Int
        /// Chiều cao chữ trung bình của các dòng (không tính khoảng trống giữa dòng), để so cỡ chữ khi gộp đoạn.
        var textH: CGFloat = 0
    }

    /// Cho "dịch đè lên màn hình": trả về từng khối chữ. Các dòng liền nhau của cùng một đoạn văn được gộp lại để dịch trọn ý.
    func recognizeBlocks(_ cg: CGImage) -> [Block] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = languages
        req.usesLanguageCorrection = true
        do { try Self.perform(VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:]), req) } catch {
            Log.error("OCR failed: \(error.localizedDescription)")
            return []
        }
        var items: [Block] = (req.results ?? []).compactMap { o in
            guard let c = o.topCandidates(1).first, c.confidence >= minConfidence else { return nil }
            let text = TextUtils.normalize(TextUtils.stripJunkTokens(c.string))
            guard TextUtils.letterCount(text) >= 2 else { return nil }
            let b = o.boundingBox
            return Block(text: text, box: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height), lines: 1, textH: b.height)
        }
        items.sort { abs($0.box.minY - $1.box.minY) > 0.01 ? $0.box.minY < $1.box.minY : $0.box.minX < $1.box.minX }
        // Gộp đoạn văn: dòng dưới nằm sát dòng trên, cùng lề trái, cỡ chữ tương đương.
        var out: [Block] = []
        for it in items {
            if let i = out.lastIndex(where: { prev in
                let lineH = prev.textH
                let gap = it.box.minY - prev.box.maxY
                // Cùng lề trái, hoặc cùng tâm (đoạn chữ canh giữa như hướng dẫn, thông báo).
                let sameLeft = abs(it.box.minX - prev.box.minX) < 0.012 || abs(it.box.midX - prev.box.midX) < 0.012
                // Dòng không có chữ cao/thấp (dòng cuối ngắn "no amount of money can buy.") có khung thấp hơn ~30 %.
                let sameSize = max(lineH, it.box.height) / max(0.0001, min(lineH, it.box.height)) < 1.5
                // Mục menu xếp dọc cũng cùng lề nhưng cách nhau xa hơn và thường chỉ 1–2 từ → không gộp.
                let wordy = prev.text.split(separator: " ").count >= 3
                // Khoảng cách dòng của đoạn văn trong game thường bằng 0,5–0,8 lần chiều cao chữ (ngưỡng cũ 0,45 tách nhầm
                // dòng đầu của đoạn ra riêng); dưới 1 lần chiều cao chữ coi là cùng đoạn.
                return sameLeft && sameSize && wordy && gap > -lineH * 0.3 && gap < lineH * 1.0 && prev.lines < 12
            }) {
                out[i].text += " " + it.text
                out[i].box = out[i].box.union(it.box)
                out[i].textH = (out[i].textH * CGFloat(out[i].lines) + it.box.height) / CGFloat(out[i].lines + 1)
                out[i].lines += 1
            } else {
                out.append(it)
            }
        }
        return out
    }

    /// Trong một hàng, các mảnh chữ cách nhau xa là những cụm riêng (phụ đề ở giữa, nút bấm ở mép): chỉ giữ cụm chạm dải giữa khung.
    private static func centered(_ row: [(String, Float, CGRect)]) -> [(String, Float, CGRect)] {
        var clusters: [[(String, Float, CGRect)]] = []
        for o in row.sorted(by: { $0.2.minX < $1.2.minX }) {
            if let last = clusters.last?.last, o.2.minX - last.2.maxX < 0.05 { clusters[clusters.count - 1].append(o) }
            else { clusters.append([o]) }
        }
        return clusters.filter { c in
            let minX = c.map(\.2.minX).min() ?? 0, maxX = c.map(\.2.maxX).max() ?? 0
            return minX <= centerBand.upperBound && maxX >= centerBand.lowerBound
        }.flatMap { $0 }
    }

    /// Như `centered` cho cả khung: giữ cụm chạm dải giữa, cộng thêm dòng tiếp nối của phụ đề bị xuống dòng
    /// ("…Are you here" / "alone?"): cụm nằm sát ngay trên/dưới một cụm đã giữ và gọn trong bề ngang của cụm đó.
    /// Nút bấm ở mép không nằm trong bề ngang của phụ đề nên vẫn bị bỏ.
    private static func centeredRows(_ groups: [[(String, Float, CGRect)]]) -> [[(String, Float, CGRect)]] {
        typealias Obs = (String, Float, CGRect)
        let rows: [[[Obs]]] = groups.map { row in
            var clusters: [[Obs]] = []
            for o in row.sorted(by: { $0.2.minX < $1.2.minX }) {
                if let last = clusters.last?.last, o.2.minX - last.2.maxX < 0.05 { clusters[clusters.count - 1].append(o) }
                else { clusters.append([o]) }
            }
            return clusters
        }
        func box(_ c: [Obs]) -> CGRect { c.map(\.2).reduce(c[0].2) { $0.union($1) } }
        var keep = rows.map { $0.map { c in let b = box(c); return b.minX <= centerBand.upperBound && b.maxX >= centerBand.lowerBound } }
        var changed = true
        while changed {
            changed = false
            for i in rows.indices {
                for j in rows[i].indices where !keep[i][j] {
                    let b = box(rows[i][j])
                    for n in [i - 1, i + 1] where rows.indices.contains(n) {
                        for k in rows[n].indices where keep[n][k] {
                            let kb = box(rows[n][k])
                            let gap = max(kb.minY - b.maxY, b.minY - kb.maxY)
                            let inside = b.minX >= kb.minX - 0.02 && b.maxX <= kb.maxX + 0.02
                            if inside, gap < max(kb.height, b.height) * 1.2 { keep[i][j] = true; changed = true }
                        }
                    }
                }
            }
        }
        return rows.indices.map { i in rows[i].indices.filter { keep[i][$0] }.flatMap { rows[i][$0] } }.filter { !$0.isEmpty }
    }

    private func run(_ handler: VNImageRequestHandler, level: VNRequestTextRecognitionLevel, centerOnly: Bool = false, minRowHeight: CGFloat = 0) -> Result? {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = level
        req.recognitionLanguages = languages
        req.usesLanguageCorrection = (level == .accurate)
        req.minimumTextHeight = minTextHeight
        do { try Self.perform(handler, req) } catch {
            Log.error("OCR failed: \(error.localizedDescription)")
            return nil
        }
        let all = (req.results ?? []).compactMap { o -> (String, Float, CGRect)? in
            guard let c = o.topCandidates(1).first else { return nil }
            if level == .accurate, c.confidence < minConfidence { return nil }
            let cleaned = TextUtils.stripJunkTokens(c.string)
            guard !cleaned.isEmpty else { return nil }
            return (cleaned, c.confidence, o.boundingBox)
        }
        guard !all.isEmpty else { return Result(text: "", lines: [], confidence: 0, level: level, ms: 0) }

        // Gom theo dòng: Vision dùng gốc dưới-trái → midY lớn = dòng trên.
        let sorted = all.sorted { $0.2.midY > $1.2.midY }
        var groups: [[(String, Float, CGRect)]] = []
        for o in sorted {
            if let last = groups.last, let ref = last.first,
               abs(ref.2.midY - o.2.midY) < max(ref.2.height, o.2.height) * 0.6 {
                groups[groups.count - 1].append(o)
            } else {
                groups.append([o])
            }
        }
        if centerOnly { groups = Self.centeredRows(groups) }
        if minRowHeight > 0 { groups = groups.filter { g in (g.map(\.2.height).max() ?? 0) >= minRowHeight } }
        guard !groups.isEmpty else { return Result(text: "", lines: [], confidence: 0, level: level, ms: 0) }
        let obs = groups.flatMap { $0 }
        let rowsText = groups.map { g in
            (TextUtils.normalize(g.sorted { $0.2.minX < $1.2.minX }.map { $0.0 }.joined(separator: "  ")), Double(g.map(\.2.height).max() ?? 0))
        }.filter { !$0.0.isEmpty }
        let lines = rowsText.map(\.0)
        let conf = obs.map { $0.1 }.reduce(0, +) / Float(obs.count)
        let heights = obs.map { $0.2.height }.filter { $0 > 0 }
        var r = Result(text: lines.joined(separator: " "), lines: lines, confidence: conf, level: level, ms: 0)
        r.lineHeights = rowsText.map(\.1)
        r.observations = obs.count
        r.rows = groups.count
        r.maxPerRow = groups.map(\.count).max() ?? 0
        if let lo = heights.min(), let hi = heights.max(), lo > 0 { r.heightRatio = Double(hi / lo) }
        return r
    }
}
