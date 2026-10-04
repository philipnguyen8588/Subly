import Foundation
import os

enum Log {
    private static let logger = Logger(subsystem: "com.lipnguyen.ScreenTranslator", category: "app")
    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    static func info(_ msg: @autoclosure () -> String) { emit("INFO", msg()) }
    static func warn(_ msg: @autoclosure () -> String) { emit("WARN", msg()) }
    static func error(_ msg: @autoclosure () -> String) { emit("ERR ", msg()) }

    /// File log: ~/Library/Application Support/ScreenTranslator/app.log (cắt bớt khi > 2 MB).
    static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenTranslator", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("app.log")
    }()
    private static let fileQueue = DispatchQueue(label: "log.file")
    private static var handle: FileHandle? = {
        if let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int, size > 2_000_000 {
            try? FileManager.default.removeItem(at: fileURL)
        }
        if !FileManager.default.fileExists(atPath: fileURL.path) { FileManager.default.createFile(atPath: fileURL.path, contents: nil) }
        let h = try? FileHandle(forWritingTo: fileURL)
        h?.seekToEndOfFile()
        return h
    }()

    private static func emit(_ level: String, _ msg: String) {
        logger.log("\(level, privacy: .public) \(msg, privacy: .public)")
        let line = "\(fmt.string(from: Date())) \(level) \(msg)\n"
        let data = line.data(using: .utf8)!
        FileHandle.standardError.write(data)
        fileQueue.async { handle?.write(data) }
    }
}
