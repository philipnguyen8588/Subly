import Foundation
import VideoToolbox
import CoreMedia

/// Giải mã luồng H.264 dạng Annex-B (mỗi lần `decode` nhận một access unit) bằng bộ giải mã phần cứng, trả về khung BGRA.
final class H264Decoder {
    var onFrame: ((CVPixelBuffer) -> Void)?
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var sps: [UInt8] = [], pps: [UInt8] = []
    private(set) var decoded = 0, failed = 0

    /// Tách các NAL unit khỏi luồng Annex-B (start code 00 00 01 hoặc 00 00 00 01).
    static func nalUnits(_ p: UnsafeBufferPointer<UInt8>) -> [Range<Int>] {
        var out: [Range<Int>] = []
        let n = p.count
        var i = 0, start = -1
        while i + 2 < n {
            if p[i] == 0, p[i + 1] == 0, p[i + 2] == 1 {
                if start >= 0 {
                    var end = i
                    if end > start, p[end - 1] == 0 { end -= 1 }   // start code 4 byte
                    if end > start { out.append(start..<end) }
                }
                start = i + 3
                i += 3
            } else { i += 1 }
        }
        if start >= 0, start < n { out.append(start..<n) }
        return out
    }

    /// Trả về false nếu access unit không giải mã được (để bên gọi xin keyframe mới).
    @discardableResult
    func decode(_ buf: UnsafePointer<UInt8>, count: Int) -> Bool {
        let p = UnsafeBufferPointer(start: buf, count: count)
        var avcc = [UInt8]()
        avcc.reserveCapacity(count + 16)
        var newSPS: [UInt8]?, newPPS: [UInt8]?
        for r in Self.nalUnits(p) {
            let type = p[r.lowerBound] & 0x1F
            switch type {
            case 7: newSPS = Array(p[r])
            case 8: newPPS = Array(p[r])
            case 9, 6: continue                       // AUD, SEI: bỏ
            default:
                var len = UInt32(r.count).bigEndian
                withUnsafeBytes(of: &len) { avcc.append(contentsOf: $0) }
                avcc.append(contentsOf: p[r])
            }
        }
        if let s = newSPS, let q = newPPS, s != sps || q != pps || session == nil {
            sps = s; pps = q
            guard makeSession() else { failed += 1; return false }
        }
        guard let session, let format, !avcc.isEmpty else { return session != nil }

        var block: CMBlockBuffer?
        let size = avcc.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: size,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: size, flags: 0, blockBufferOut: &block) == noErr, let block else { return false }
        avcc.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: size) }
        var sample: CMSampleBuffer?
        var sizes = [size]
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &sizes, sampleBufferOut: &sample) == noErr,
              let sample else { return false }
        var ok = true
        let st = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { [weak self] status, _, image, _, _ in
            guard let self else { return }
            if status == noErr, let image { self.decoded += 1; self.onFrame?(image) }
            else { self.failed += 1; ok = false }
        }
        if st != noErr { failed += 1; return false }
        return ok
    }

    private func makeSession() -> Bool {
        invalidate()
        var fmt: CMVideoFormatDescription?
        let st: OSStatus = sps.withUnsafeBufferPointer { s in
            pps.withUnsafeBufferPointer { q in
                let ptrs = [s.baseAddress!, q.baseAddress!]
                let sizes = [s.count, q.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2,
                                                                           parameterSetPointers: ptrs, parameterSetSizes: sizes,
                                                                           nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
            }
        }
        guard st == noErr, let fmt else { Log.error("H264: không tạo được format (\(st))"); return false }
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var s: VTDecompressionSession?
        let r = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: fmt, decoderSpecification: nil,
                                             imageBufferAttributes: attrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &s)
        guard r == noErr, let s else { Log.error("H264: không tạo được bộ giải mã (\(r))"); return false }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = s
        format = fmt
        let d = CMVideoFormatDescriptionGetDimensions(fmt)
        Log.info("H264: bộ giải mã \(d.width)×\(d.height)")
        return true
    }

    func invalidate() {
        if let s = session { VTDecompressionSessionInvalidate(s) }
        session = nil
        format = nil
    }

    deinit { invalidate() }
}
