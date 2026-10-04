import Foundation
import AppKit
import UniformTypeIdentifiers

enum Exporter {
    enum Format: String, CaseIterable, Identifiable {
        case txt, srt, json
        var id: String { rawValue }
        var label: String {
            switch self { case .txt: return "TXT song ngữ"; case .srt: return "SRT phụ đề"; case .json: return "JSON (kèm phân tích)" }
        }
        var type: UTType { self == .json ? .json : .plainText }
    }

    @MainActor
    static func export(_ format: Format, entries: [TranslationEntry], analyses: [ScreenAnalysis]) {
        let data: Data
        switch format {
        case .txt: data = Data(txt(entries).utf8)
        case .srt: data = Data(srt(entries).utf8)
        case .json: data = json(entries, analyses) ?? Data()
        }
        let p = NSSavePanel()
        p.nameFieldStringValue = "screen-translator-\(dateStamp()).\(format.rawValue)"
        p.allowedContentTypes = [format.type]
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let url = p.url {
            do { try data.write(to: url) } catch { Log.error("Export failed: \(error.localizedDescription)") }
        }
    }

    static func txt(_ entries: [TranslationEntry]) -> String {
        let asc = entries.sorted { $0.timestamp < $1.timestamp }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return asc.map { e in
            "[\(f.string(from: e.timestamp))] \(e.regionName) · \(e.backend)\n\(e.source)\n\(e.translated)\n"
        }.joined(separator: "\n")
    }

    static func srt(_ entries: [TranslationEntry]) -> String {
        let asc = entries.filter { $0.kind == .subtitle }.sorted { $0.timestamp < $1.timestamp }
        guard let first = asc.first else { return "" }
        var out = ""
        for (i, e) in asc.enumerated() {
            let start = e.timestamp.timeIntervalSince(first.timestamp)
            let nextStart = i + 1 < asc.count ? asc[i + 1].timestamp.timeIntervalSince(first.timestamp) : start + 4
            let end = min(nextStart - 0.05, start + 8)
            out += "\(i + 1)\n\(srtTime(start)) --> \(srtTime(max(end, start + 0.5)))\n\(e.translated)\n\(e.source)\n\n"
        }
        return out
    }

    private static func srtTime(_ t: TimeInterval) -> String {
        let ms = Int((t - floor(t)) * 1000)
        let s = Int(t)
        return String(format: "%02d:%02d:%02d,%03d", s / 3600, (s / 60) % 60, s % 60, ms)
    }

    static func json(_ entries: [TranslationEntry], _ analyses: [ScreenAnalysis]) -> Data? {
        let iso = ISO8601DateFormatter()
        let rows: [[String: Any]] = entries.sorted { $0.timestamp < $1.timestamp }.map {
            ["timestamp": iso.string(from: $0.timestamp), "region": $0.regionName, "kind": $0.kind.rawValue,
             "source": $0.source, "translated": $0.translated, "backend": $0.backend,
             "latencyMs": $0.latencyMs, "target": $0.targetLang]
        }
        let an: [[String: Any]] = analyses.sorted { $0.timestamp < $1.timestamp }.map {
            ["timestamp": iso.string(from: $0.timestamp), "region": $0.regionName, "summary": $0.summary,
             "backend": $0.backend, "latencyMs": $0.latencyMs,
             "lines": $0.lines.map { ["source": $0.source, "target": $0.target] }]
        }
        return try? JSONSerialization.data(withJSONObject: ["history": rows, "analyses": an], options: [.prettyPrinted])
    }

    private static func dateStamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmm"; return f.string(from: Date())
    }
}
