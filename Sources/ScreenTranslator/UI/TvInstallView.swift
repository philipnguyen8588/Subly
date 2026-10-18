import AppKit
import SwiftUI

/// Cửa sổ "Cài app lên TV Samsung" (nút trên header màn Bắt đầu / màn dịch): hướng dẫn bật Developer Mode,
/// nhập IP TV, bấm Cài; TvInstaller lo kết nối, chứng chỉ (đăng nhập Samsung nếu TV mới), ký và cài.
struct TvInstallView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var ip = AppSettings.shared.tvInstallIp
    @State private var log = ""
    @State private var result: (text: String, error: Bool)?
    @State private var task: Task<Void, Never>?
    private let pcIps = WebServer.lanAddresses()
    private let missing = TvInstaller.missingFiles()

    private var running: Bool { task != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "tv").font(.system(size: 24)).foregroundStyle(Theme.accentStart)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cài app Subtitle TV lên TV Samsung").font(.headline)
                    Text("TV mới lần đầu: trình duyệt mở trang đăng nhập Samsung Account để xin chứng chỉ cho TV đó.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("1. Trên TV: mở Apps, bấm 1 2 3 4 5 trên remote, bật Developer mode.")
                Text("2. Ô Host PC IP trên TV: nhập IP máy tính này")
                HStack(spacing: 8) {
                    Text(pcIps.first ?? "(không thấy IP mạng nội bộ)")
                        .font(.system(size: 14, design: .monospaced)).textSelection(.enabled)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 6))
                    Button("Chép") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(pcIps.first ?? "", forType: .string)
                    }.appButton().disabled(pcIps.isEmpty)
                }.padding(.leading, 18)
                Text("3. Tắt TV rồi mở lại. Xem IP của TV: Cài đặt → Chung → Mạng → Trạng thái mạng.")
                Text(pcIps.count > 1 ? "Máy có nhiều IP: " + pcIps.joined(separator: ", ") + " — chọn IP cùng mạng với TV." : "TV và máy tính phải cùng mạng.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .font(.system(size: 13))
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()

            HStack(spacing: 8) {
                Text("IP của TV").font(.system(size: 13))
                TextField("192.168.1.20", text: $ip)
                    .textFieldStyle(.roundedBorder).frame(width: 180)
                    .disabled(running)
                    .onSubmit { if !running && missing == nil { start() } }
                Spacer()
                if running {
                    Button("Huỷ") { task?.cancel() }.appButton()
                }
                Button { start() } label: { Label("Cài lên TV", systemImage: "square.and.arrow.down") }
                    .appButton(.primary, minWidth: 140)
                    .disabled(running || missing != nil)
                    .keyboardShortcut(.defaultAction)
            }

            if let missing { Text(missing).font(.system(size: 13)).foregroundStyle(Theme.danger) }
            if running { ProgressView().progressViewStyle(.linear) }

            ScrollViewReader { proxy in
                ScrollView {
                    Text(log.isEmpty ? " " : log)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .id("log")
                }
                .frame(height: 170)
                .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 8))
                .onChange(of: log) { proxy.scrollTo("log", anchor: .bottom) }
            }

            if let result {
                Text(result.text).font(.system(size: 13))
                    .foregroundStyle(result.error ? Theme.danger : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 20)
        .frame(width: 600)
        .onDisappear { task?.cancel() }
    }

    private func start() {
        let ip = ip.trimmingCharacters(in: .whitespaces)
        var addr = in_addr()
        guard inet_pton(AF_INET, ip, &addr) == 1 else {
            result = ("Nhập IP của TV dạng 192.168.1.20.", true); return
        }
        settings.tvInstallIp = ip
        log = ""; result = nil
        task = Task { @MainActor in
            do {
                try await TvInstaller.install(ip: ip, log: { line in
                    DispatchQueue.main.async { log += line + "\n" }
                }, confirmUninstall: {
                    let a = NSAlert()
                    a.messageText = "Cài app lên TV"
                    a.informativeText = "TV đã có Subtitle TV cài bằng chứng chỉ khác nên không cài đè được.\n\n" +
                        "Gỡ app cũ rồi cài lại? Cài đặt đã lưu trong app trên TV (máy tính đã chọn, cỡ chữ…) sẽ mất."
                    a.addButton(withTitle: "Gỡ và cài lại")
                    a.addButton(withTitle: "Không")
                    return a.runModal() == .alertFirstButtonReturn
                })
                result = ("✅ Đã cài và mở app trên TV. Trên TV: Back → Máy tính → \"Dò máy trong mạng\" để kết nối máy này.", false)
            } catch where error is CancellationError || Task.isCancelled {
                result = ("Đã huỷ.", false)
            } catch {
                log += "Lỗi: \(error.localizedDescription)\n"
                Log.warn("TV: cài app lỗi: \(error.localizedDescription)")
                result = ("Không cài được: " + (error.localizedDescription.components(separatedBy: "\n").first ?? ""), true)
            }
            task = nil
        }
    }
}
