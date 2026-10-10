import SwiftUI
import AVFoundation
import CoreMedia

/// Điều phối giữa phiên PS5 nhúng và pipeline dịch: profile riêng, vùng mặc định, tự bắt đầu/dừng dịch.
@MainActor
enum PS5Coordinator {
    /// Tạo vùng PS5 mặc định (phụ đề ở dải dưới + toàn màn hình) trong game đang chọn nếu chưa có.
    static func prepareProfile() {
        let settings = AppSettings.shared
        var regions = settings.regions
        if !regions.contains(where: { $0.embedded && $0.kind == .subtitle }) {
            var r = Region(name: "Phụ đề PS5", displayID: 0, x: 0.10, y: 0.72, width: 0.80, height: 0.24)
            r.embedded = true
            regions.append(r)
        }
        if !regions.contains(where: { $0.embedded && $0.kind == .manual }) {
            var r = Region(name: "Màn hình PS5", displayID: 0, x: 0, y: 0, width: 1, height: 1, kind: .manual)
            r.embedded = true
            regions.append(r)
        }
        if regions != settings.regions { settings.regions = regions }
    }

    static func connect() {
        let settings = AppSettings.shared
        prepareProfile()
        PS5Stream.shared.connect(resolution: settings.ps5Resolution, fps: settings.ps5FPS)
    }

    static func stateChanged(_ s: PS5Stream.State) {
        let settings = AppSettings.shared
        guard settings.source == .ps5 else { return }
        switch s {
        case .streaming:
            if settings.ps5AutoTranslate, !Pipeline.shared.isRunning { Task { await Pipeline.shared.start() } }
        case .idle, .failed:
            if Pipeline.shared.isRunning { Pipeline.shared.stop() }
        default: break
        }
    }

    /// Dời / đổi cỡ một khung đã có (khung phụ đề chính hoặc khu vực dịch thêm) theo id.
    static func updateSubtitleRect(id: UUID, rect r: CGRect) {
        let settings = AppSettings.shared
        guard let i = settings.regions.firstIndex(where: { $0.id == id }) else { return }
        settings.regions[i].rect = r
        Log.info("PS5: khung '\(settings.regions[i].name)' = \(String(format: "x %.2f y %.2f w %.2f h %.2f", r.minX, r.minY, r.width, r.height))")
        Pipeline.shared.restartIfRunning()
    }

    /// Thêm một khu vực dịch mới trên hình PS5: chỉ dịch chữ trong khung, không lấy tên, không đọc thành tiếng,
    /// bản dịch hiện ngay tại khung. Nếu chưa có khung phụ đề chính nào thì khung đầu tiên làm khung chính.
    @discardableResult
    static func addSubtitleRegion(_ r: CGRect) -> UUID {
        let settings = AppSettings.shared
        var regions = settings.regions
        let hasPrimary = regions.contains { $0.embedded && $0.kind == .subtitle && !$0.extra }
        var n = Region(name: hasPrimary ? "Khu vực \(regions.filter { $0.embedded && $0.kind == .subtitle }.count + 1)" : "Phụ đề PS5",
                       displayID: 0, x: r.minX, y: r.minY, width: r.width, height: r.height)
        n.embedded = true
        n.extra = hasPrimary
        regions.append(n)
        settings.regions = regions
        Log.info("PS5: thêm \(n.extra ? "khu vực dịch" : "khung phụ đề chính") '\(n.name)' = \(String(format: "x %.2f y %.2f w %.2f h %.2f", r.minX, r.minY, r.width, r.height))")
        Pipeline.shared.restartIfRunning()
        return n.id
    }

    /// Xoá một khu vực dịch thêm (không cho xoá khung phụ đề chính).
    static func removeSubtitleRegion(id: UUID) {
        let settings = AppSettings.shared
        guard let r = settings.regions.first(where: { $0.id == id }), r.extra else { return }
        settings.regions.removeAll { $0.id == id }
        Pipeline.shared.clearRegionCaption(id)
        Log.info("PS5: xoá khu vực dịch '\(r.name)'")
        Pipeline.shared.restartIfRunning()
    }
}

/// Chưa có máy: nhập từ chiaki-ng hoặc đăng ký mới bằng mã PIN.
struct PS5SetupView: View {
    @ObservedObject var stream = PS5Stream.shared
    @State private var ip = ""
    @State private var account = ""
    @State private var pin = ""
    @State private var found: [PS5Stream.Found] = []
    @State private var searching = false
    @State private var message = ""
    @State private var pastedURL = ""
    @State private var fetchingID = false
    @State private var psnMessage = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "playstation.logo").font(.system(size: 28)).foregroundStyle(Theme.accentGradient)
                    VStack(alignment: .leading) {
                        Text("Lấy hình PS5 ngay trong app").font(.title3.weight(.semibold))
                        Text("App kết nối Remote Play để nhận hình và dịch phụ đề. Không gửi điều khiển, không phát tiếng: bạn vẫn chơi bằng tay cầm nối thẳng với PS5.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                GroupBox("Cách 1 – Dùng lại máy đã đăng ký trong chiaki-ng") {
                    HStack {
                        Text("Nếu bạn đã đăng ký PS5 trong chiaki-ng trên máy này, app lấy lại khoá đăng ký đó, không cần mã PIN.")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Nhập từ chiaki-ng") {
                            message = stream.importFromChiaki() ? "" : "Không thấy máy nào đã đăng ký trong chiaki-ng."
                        }
                        .buttonStyle(GradientButtonStyle(compact: true))
                    }
                    .padding(6)
                }
                GroupBox("Cách 2 – Đăng ký mới") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("Địa chỉ IP của PS5 (ví dụ 192.168.1.20)", text: $ip)
                            Button(searching ? "Đang tìm…" : "Tìm trong mạng") { search() }.disabled(searching)
                        }
                        ForEach(found) { f in
                            Button { ip = f.addr } label: {
                                Label("\(f.name) – \(f.addr) (\(f.stateLabel))", systemImage: "dot.radiowaves.left.and.right")
                            }.buttonStyle(.link)
                        }
                        TextField("PSN Account ID (dạng base64, 12 ký tự, ví dụ AbCdEfGhIjk=)", text: $account)
                        GroupBox {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Chưa có PSN Account ID? Lấy bằng cách đăng nhập PSN:").font(.callout.weight(.medium))
                                HStack(alignment: .firstTextBaseline) {
                                    Text("1.")
                                    Button("Mở trang đăng nhập PSN") { NSWorkspace.shared.open(PSNAccount.loginURL) }
                                    Text("rồi đăng nhập tài khoản của bạn trên trang của Sony.").foregroundStyle(.secondary)
                                }
                                HStack(alignment: .firstTextBaseline) {
                                    Text("2.")
                                    Text("Khi trang chuyển sang địa chỉ có chữ “redirect” (trang trắng hoặc báo lỗi cũng được), copy toàn bộ địa chỉ trên thanh URL và dán vào đây:")
                                        .foregroundStyle(.secondary)
                                }
                                HStack {
                                    TextField("https://remoteplay.dl.playstation.net/remoteplay/redirect?code=…", text: $pastedURL)
                                    Button("Dán") { pastedURL = NSPasteboard.general.string(forType: .string) ?? pastedURL }
                                    Button(fetchingID ? "Đang lấy…" : "Lấy Account ID") { fetchAccountID() }
                                        .disabled(fetchingID || pastedURL.isEmpty)
                                }
                                if !psnMessage.isEmpty {
                                    Text(psnMessage).font(.caption).foregroundStyle(psnMessage.hasPrefix("Đã") ? Color.green : Theme.danger)
                                        .textSelection(.enabled)
                                }
                                Text("App chỉ gửi mã trong URL tới máy chủ của Sony để đổi lấy số tài khoản. Mật khẩu của bạn chỉ nhập trên trang của Sony, app không thấy và không lưu token.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .font(.callout)
                            .padding(4)
                        }
                        TextField("Mã PIN 8 số trên PS5", text: $pin)
                        Text("Trên PS5: Settings → System → Remote Play → bật Enable Remote Play → Link Device để lấy mã PIN. PSN Account ID không phải tên đăng nhập; chiaki-ng có nút lấy mã này bằng cách đăng nhập PSN.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(stream.registering ? "Đang đăng ký…" : "Đăng ký") { register() }
                                .disabled(stream.registering || ip.isEmpty || pin.isEmpty || account.isEmpty)
                            if !stream.registMessage.isEmpty { Text(stream.registMessage).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .padding(6)
                }
                if !message.isEmpty { Text(message).foregroundStyle(Theme.danger) }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func search() {
        searching = true
        DispatchQueue.global().async {
            let r = PS5Stream.discover(PS5Stream.broadcastAddresses())
            DispatchQueue.main.async {
                found = r; searching = false
                if r.isEmpty { message = "Không thấy PS5 nào trả lời. Kiểm tra PS5 đã bật và cùng mạng." } else { message = "" }
                if ip.isEmpty, let f = r.first { ip = f.addr }
            }
        }
    }

    private func fetchAccountID() {
        fetchingID = true
        psnMessage = ""
        let pasted = pastedURL
        Task {
            do {
                let id = try await PSNAccount.accountID(fromPasted: pasted)
                account = id
                psnMessage = "Đã lấy được Account ID và điền vào ô phía trên."
                pastedURL = ""
                Log.info("PSN: đã lấy Account ID")
            } catch {
                psnMessage = error.localizedDescription
                Log.warn("PSN: lấy Account ID lỗi: \(error.localizedDescription)")
            }
            fetchingID = false
        }
    }

    private func register() {
        guard let acc = PS5Store.accountID(fromBase64: account) else { message = "PSN Account ID không đúng dạng (cần base64 của 8 byte)."; return }
        guard let p = UInt32(pin.filter(\.isNumber)), pin.filter(\.isNumber).count == 8 else { message = "Mã PIN phải gồm 8 chữ số."; return }
        message = ""
        stream.register(hostAddr: ip.trimmingCharacters(in: .whitespaces), accountID: acc, pin: p)
    }
}
