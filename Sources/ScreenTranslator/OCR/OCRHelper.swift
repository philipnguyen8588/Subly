import Foundation
import AppKit
import CoreVideo
import Vision

/// OCR phụ đề chạy trong một tiến trình phụ (chính file chạy của app, cờ `--ocr-helper`).
/// Vision thỉnh thoảng treo hẳn bên trong (chờ Neural Engine mãi, không bao giờ trả về). Treo trong tiến trình chính thì chỉ
/// thoát app mới hết; treo trong tiến trình phụ thì app tắt nó, mở lại và dịch tiếp sau vài giây.
///
/// Giao thức qua stdin/stdout: mỗi yêu cầu = 4 byte độ dài (little-endian) + JSON `Request` + `bytesPerRow × height` byte BGRA;
/// mỗi trả lời = một dòng JSON `Response`.
enum OCRHelper {
    struct Request: Codable {
        var width, height, bytesPerRow: Int
        var accurate: Bool
        var minTextHeight: Float
        var centerOnly: Bool
        var minRowHeight: Double
    }
    struct Response: Codable {
        var ok: Bool
        var text = "", lines: [String] = [], confidence: Float = 0, accurate = true, ms = 0.0
        var observations = 0, rows = 0, maxPerRow = 0, heightRatio = 1.0, lineHeights: [Double] = []

        init(_ r: VisionOCR.Result) {
            ok = true; text = r.text; lines = r.lines; confidence = r.confidence; accurate = r.level == .accurate; ms = r.ms
            observations = r.observations; rows = r.rows; maxPerRow = r.maxPerRow; heightRatio = r.heightRatio; lineHeights = r.lineHeights
        }
        init(failed: Void) { ok = false }

        var result: VisionOCR.Result {
            var r = VisionOCR.Result(text: text, lines: lines, confidence: confidence, level: accurate ? .accurate : .fast, ms: ms)
            r.observations = observations; r.rows = rows; r.maxPerRow = maxPerRow; r.heightRatio = heightRatio; r.lineHeights = lineHeights
            return r
        }
    }

    static var isHelper: Bool { CommandLine.arguments.contains("--ocr-helper") }

    /// Vòng lặp của tiến trình phụ: đọc yêu cầu, OCR, trả lời. Kết thúc khi stdin đóng (app chính thoát).
    static func runHelper() -> Never {
        NSApplication.shared.setActivationPolicy(.prohibited)      // không hiện icon Dock
        let input = FileHandle.standardInput, output = FileHandle.standardOutput
        let ocr = VisionOCR()
        func read(_ n: Int) -> Data? {
            var d = Data()
            while d.count < n {
                let chunk = input.readData(ofLength: n - d.count)
                if chunk.isEmpty { return nil }
                d.append(chunk)
            }
            return d
        }
        while let lenData = read(4) {
            let len = Int(lenData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
            guard let reqData = read(len), let req = try? JSONDecoder().decode(Request.self, from: reqData),
                  let pixels = read(req.bytesPerRow * req.height) else { break }
            var reply = Response(failed: ())
            if let pb = makeBuffer(req, pixels) {
                ocr.level = req.accurate ? .accurate : .fast
                ocr.minTextHeight = req.minTextHeight
                ocr.centerOnly = req.centerOnly
                ocr.minRowHeight = CGFloat(req.minRowHeight)
                if let r = autoreleasepool(invoking: { ocr.recognize(pb) }) { reply = Response(r) }
            }
            var line = (try? JSONEncoder().encode(reply)) ?? Data("{\"ok\":false}".utf8)
            line.append(0x0A)
            output.write(line)
        }
        exit(0)
    }

    private static func makeBuffer(_ req: Request, _ pixels: Data) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, req.width, req.height, kCVPixelFormatType_32BGRA, nil, &pb) == kCVReturnSuccess, let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let dst = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let dstRow = CVPixelBufferGetBytesPerRow(pb), rowBytes = min(dstRow, req.bytesPerRow)
        pixels.withUnsafeBytes { src in
            for y in 0..<req.height {
                memcpy(dst + y * dstRow, src.baseAddress! + y * req.bytesPerRow, rowBytes)
            }
        }
        return pb
    }
}

/// Phía app chính: gửi khung hình cho tiến trình phụ, chờ có giới hạn; quá hạn thì tắt và mở lại tiến trình phụ.
/// Mỗi vùng phụ đề một client, gọi tuần tự từ hàng đợi OCR của vùng đó.
final class OCRClient {
    private var process: Process?
    private var stdin: FileHandle?
    private var replies: [Data] = []
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var buffer = Data()
    /// Quá thời gian này không có trả lời → coi là Vision đã treo (bình thường dưới 0,2 s).
    var timeout: TimeInterval = 5
    /// Báo cho app biết đã phải khởi động lại bộ nhận dạng chữ (để ghi log / hiện thông báo).
    var onRestart: ((Int) -> Void)?
    private var restarts = 0
    let name: String
    /// Gửi khung hình ở luồng riêng: tiến trình phụ treo thì nó ngừng đọc, ghi vào ống dẫn đầy sẽ kẹt mãi;
    /// có luồng riêng thì bước chờ có hạn bên dưới vẫn bao được cả việc gửi lẫn việc nhận.
    private let writer = DispatchQueue(label: "ocr.helper.write")
    /// Tắt tiến trình phụ khi đang ghi dở sẽ sinh SIGPIPE (mặc định làm chết cả app) → bỏ qua, để lệnh ghi chỉ báo lỗi.
    private static let ignoreSigpipe: Void = { _ = Darwin.signal(SIGPIPE, SIG_IGN) }()

    init(name: String) { self.name = name; _ = Self.ignoreSigpipe }
    deinit { stop() }

    func stop() {
        stdin?.closeFile(); stdin = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil
    }

    private func start() -> Bool {
        guard let exe = Bundle.main.executableURL else { return false }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--ocr-helper"]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self, !d.isEmpty else { return }
            self.lock.lock()
            self.buffer.append(d)
            while let nl = self.buffer.firstIndex(of: 0x0A) {
                self.replies.append(self.buffer[self.buffer.startIndex..<nl])
                self.buffer.removeSubrange(self.buffer.startIndex...nl)
                self.signal.signal()
            }
            self.lock.unlock()
        }
        do { try p.run() } catch {
            Log.error("OCR[\(name)]: không mở được tiến trình nhận dạng chữ: \(error.localizedDescription)")
            return false
        }
        process = p
        stdin = inPipe.fileHandleForWriting
        return true
    }

    /// Kill ngay (tiến trình phụ đang treo trong Vision nên không tự thoát được), bỏ mọi trả lời cũ.
    private func kill() {
        if let p = process { Darwin.kill(p.processIdentifier, SIGKILL) }
        try? stdin?.close()
        stdin = nil; process = nil
        lock.lock(); replies.removeAll(); buffer.removeAll(); lock.unlock()
        while signal.wait(timeout: .now()) == .success {}
    }

    func recognize(_ pb: CVPixelBuffer, accurate: Bool, minTextHeight: Float, centerOnly: Bool, minRowHeight: CGFloat) -> VisionOCR.Result? {
        if process?.isRunning != true { kill(); guard start() else { return nil } }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { CVPixelBufferUnlockBaseAddress(pb, .readOnly); return nil }
        let pixels = Data(bytes: base, count: bpr * h)
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        let req = OCRHelper.Request(width: w, height: h, bytesPerRow: bpr, accurate: accurate, minTextHeight: minTextHeight,
                                    centerOnly: centerOnly, minRowHeight: Double(minRowHeight))
        guard let json = try? JSONEncoder().encode(req) else { return nil }
        var msg = Data()
        var len = UInt32(json.count).littleEndian
        msg.append(Data(bytes: &len, count: 4)); msg.append(json); msg.append(pixels)
        guard let handle = stdin else { return nil }
        writer.async { try? handle.write(contentsOf: msg) }

        guard signal.wait(timeout: .now() + timeout) == .success else {
            restarts += 1
            Log.error("OCR[\(name)]: nhận dạng chữ của macOS treo quá \(Int(timeout)) s → khởi động lại (lần \(restarts))")
            kill()
            onRestart?(restarts)
            return nil
        }
        lock.lock(); let data = replies.isEmpty ? nil : replies.removeFirst(); lock.unlock()
        guard let data, let reply = try? JSONDecoder().decode(OCRHelper.Response.self, from: data), reply.ok else { return nil }
        return reply.result
    }
}
