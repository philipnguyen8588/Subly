import SwiftUI
import AppKit

/// Trạng thái sao lưu / khôi phục dùng chung cho tab Cài đặt → Sao lưu và các cờ test.
@MainActor
final class BackupModel: ObservableObject {
    static let shared = BackupModel()

    @Published private(set) var backups: [BackupInfo] = []
    @Published private(set) var busy: String?          // đang làm gì (hiện cạnh vòng xoay)
    @Published private(set) var progress: Double?      // 0…1 khi đang tải lên / tải về
    @Published var message: String?
    @Published var isError = false
    @Published private(set) var loaded = false

    var loggedIn: Bool { !BackupClient.token.isEmpty && !AppSettings.shared.accountUser.isEmpty }
    var thisMachine: String { BackupClient.machineID }

    private func report(_ text: String, error: Bool) {
        message = text; isError = error
        if error { Log.warn("Sao lưu: \(text)") } else { Log.info("Sao lưu: \(text)") }
    }

    private func fail(_ e: Error) {
        if let f = e as? BackupClient.Failure, f.unauthorized {
            SecretStore.set("", name: BackupClient.tokenName)
            objectWillChange.send()
        }
        report(e.localizedDescription, error: true)
    }

    func login(username: String, password: String) async -> Bool {
        busy = "Đang đăng nhập…"; defer { busy = nil }
        do {
            AppSettings.shared.accountUser = try await BackupClient.login(username: username, password: password)
            report("Đã đăng nhập \(AppSettings.shared.accountUser)", error: false)
            await refresh()
            return true
        } catch { fail(error); return false }
    }

    func logout() async {
        await BackupClient.logout()
        AppSettings.shared.accountUser = ""
        backups = []; loaded = false; message = nil
    }

    func refresh() async {
        guard loggedIn else { return }
        do { backups = try await BackupClient.list(); loaded = true } catch { fail(error) }
    }

    /// Sao lưu dữ liệu máy này lên server (ghi đè bản cũ của máy này).
    @discardableResult
    func backupNow() async -> Bool {
        guard busy == nil else { return false }
        busy = "Đang đóng gói dữ liệu…"; progress = nil
        defer { busy = nil; progress = nil }
        do {
            let zip = try await BackupArchive.export()
            defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
            let size = (try? zip.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            busy = "Đang tải lên \(Self.size(Int64(size)))…"; progress = 0
            let info = try await BackupClient.upload(zip) { p in Task { @MainActor in BackupModel.shared.progress = p } }
            report("Đã sao lưu \(Self.size(info.size)) lúc \(info.date.formatted(date: .omitted, time: .shortened))", error: false)
            await refresh()
            return true
        } catch { fail(error); return false }
    }

    /// Tải bản của một máy về, giải nén chờ sẵn rồi khởi động lại app để thay dữ liệu.
    func restore(_ b: BackupInfo) async {
        guard busy == nil else { return }
        busy = "Đang tải bản sao lưu \(Self.size(b.size))…"; progress = 0
        defer { busy = nil; progress = nil }
        let zip = AppPaths.file("restore-download.zip")
        defer { try? FileManager.default.removeItem(at: zip) }
        do {
            try await BackupClient.download(machine: b.machine, to: zip) { p in Task { @MainActor in BackupModel.shared.progress = p } }
            busy = "Đang giải nén…"; progress = nil
            let m = try await Task.detached { try BackupArchive.stage(zip: zip) }.value
            Log.info("Sao lưu: đã chuẩn bị bản của \(m.machineName) (\(m.profiles) game, \(m.historyRows) dòng) → khởi động lại")
            try? FileManager.default.removeItem(at: zip)   // relaunch() thoát app nên defer không kịp chạy
            Pipeline.shared.stop()
            BackupArchive.relaunch()
        } catch { fail(error) }
    }

    func delete(_ b: BackupInfo) async {
        do { try await BackupClient.delete(machine: b.machine); await refresh() } catch { fail(error) }
    }

    static func size(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
}

/// Cài đặt → Sao lưu: đăng nhập tài khoản, sao lưu dữ liệu máy này, khôi phục từ bản của máy bất kỳ.
struct BackupSettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var model = BackupModel.shared
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        Form {
            if !BackupClient.available {
                Section { Text("Bản app này không có server sao lưu.").foregroundStyle(.secondary) }
            } else if !model.loggedIn {
                loginSection
            } else {
                accountSection
                backupsSection
            }
            if let msg = model.message {
                Section { Text(msg).foregroundStyle(model.isError ? .red : .green).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
        .task { if model.loggedIn && !model.loaded { await model.refresh() } }
    }

    private var loginSection: some View {
        Section {
            TextField("Tên đăng nhập", text: $username).textContentType(.username)
            SecureField("Mật khẩu", text: $password).textContentType(.password).onSubmit(login)
            HStack {
                Button("Đăng nhập", action: login)
                    .buttonStyle(.borderedProminent)
                    .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty || model.busy != nil)
                if let b = model.busy { ProgressView().controlSize(.small); Text(b).foregroundStyle(.secondary) }
            }
        } header: {
            Text("Tài khoản sao lưu")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sao lưu toàn bộ dữ liệu (cài đặt, game, thuật ngữ, nhân vật, phụ đề đã dịch, cốt truyện, ảnh dịch màn hình, API key, PS5) lên server để đổi máy không phải cài lại từ đầu. Tài khoản do admin cấp.")
                Text(.init(AppInfo.supportMarkdown))
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var accountSection: some View {
        Section {
            HStack {
                Label(settings.accountUser, systemImage: "person.crop.circle")
                Spacer()
                Button("Đăng xuất") { Task { await model.logout() } }.disabled(model.busy != nil)
            }
            HStack(spacing: 10) {
                Button {
                    Task { await model.backupNow() }
                } label: {
                    Label("Sao lưu máy này lên server", systemImage: "icloud.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy != nil)
                if let b = model.busy {
                    if let p = model.progress { ProgressView(value: p).frame(width: 120) } else { ProgressView().controlSize(.small) }
                    Text(b).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let mine = model.backups.first(where: { $0.machine == model.thisMachine }) {
                Text("Lần sao lưu cuối của máy này: \(mine.date.formatted(date: .abbreviated, time: .shortened)) · \(BackupModel.size(mine.size))")
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.loaded {
                Text("Máy này chưa sao lưu lần nào.").font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Tài khoản")
        } footer: {
            Text("Mỗi máy giữ một bản mới nhất trên server, sao lưu lại sẽ ghi đè. Giọng đọc AI đã tải không nằm trong bản sao lưu (tải lại ở Cài đặt → Voice).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var backupsSection: some View {
        Section {
            if model.backups.isEmpty {
                Text(model.loaded ? "Chưa có bản sao lưu nào." : "Đang tải danh sách…").foregroundStyle(.secondary)
            }
            ForEach(model.backups) { b in
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: b.platform == "win" ? "pc" : "desktopcomputer")
                        .font(.title2).foregroundStyle(.secondary).frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(b.name.isEmpty ? "(không tên)" : b.name).fontWeight(.semibold)
                            if b.machine == model.thisMachine {
                                Text("máy này").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.18), in: Capsule())
                            }
                        }
                        Text("\(b.platformLabel) · IP \(b.ip) · \(b.date.formatted(date: .abbreviated, time: .shortened)) · \(BackupModel.size(b.size))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Khôi phục") { confirmRestore(b) }.disabled(model.busy != nil)
                    Button { confirmDelete(b) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).disabled(model.busy != nil).help("Xoá bản sao lưu này trên server")
                }
            }
        } header: {
            HStack {
                Text("Bản sao lưu trên server")
                Spacer()
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Tải lại danh sách")
            }
        } footer: {
            Text("Khôi phục sẽ thay toàn bộ dữ liệu trên máy này bằng bản đã chọn (có thể là bản của máy khác, kể cả Windows) rồi khởi động lại app. Dữ liệu cũ được cất ở thư mục before-restore.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func login() {
        let u = username, p = password
        Task { if await model.login(username: u, password: p) { password = "" } }
    }

    private func confirmRestore(_ b: BackupInfo) {
        let alert = NSAlert()
        alert.messageText = "Khôi phục từ \(b.name)?"
        alert.informativeText = "Toàn bộ dữ liệu trên máy này sẽ bị thay bằng bản sao lưu của \(b.name) (\(b.platformLabel), \(b.date.formatted(date: .abbreviated, time: .shortened))). App sẽ khởi động lại."
            + (b.platform != "mac" ? "\n\nBản này từ Windows: phím tắt và giọng đọc của máy này được giữ nguyên, các khung chụp màn hình (ngoài PS5) cần vẽ lại." : "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Khôi phục")
        alert.addButton(withTitle: "Huỷ")
        if alert.runModal() == .alertFirstButtonReturn { Task { await model.restore(b) } }
    }

    private func confirmDelete(_ b: BackupInfo) {
        let alert = NSAlert()
        alert.messageText = "Xoá bản sao lưu của \(b.name)?"
        alert.informativeText = "Bản sao lưu này sẽ bị xoá khỏi server. Dữ liệu trên các máy không bị ảnh hưởng."
        alert.addButton(withTitle: "Xoá")
        alert.addButton(withTitle: "Huỷ")
        if alert.runModal() == .alertFirstButtonReturn { Task { await model.delete(b) } }
    }
}
