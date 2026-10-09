import SwiftUI
import AppKit

/// Màn hình hiện khi app chưa sẵn sàng chạy. Cố ý chung chung, không nêu lý do (chờ duyệt / thu hồi / mất mạng…).
struct StartupErrorView: View {
    @ObservedObject var check = SessionCheck.shared
    @State private var retrying = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 42)).foregroundStyle(.secondary)
            Text("ScreenTranslator không khởi động được")
                .font(.title3.weight(.semibold))
            Text("Không thể tiếp tục lúc này. Vui lòng kiểm tra kết nối mạng rồi thử lại sau.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
            Text("Mã: 0x2A1")
                .font(.caption.monospaced()).foregroundStyle(.tertiary)
            HStack(spacing: 10) {
                Button("Đóng") { WindowManager.shared.dismissStartupError() }
                Button {
                    retrying = true
                    Task {
                        await check.refresh()
                        retrying = false
                        if check.valid() { WindowManager.shared.dismissStartupError() }
                    }
                } label: {
                    if retrying { ProgressView().controlSize(.small) } else { Text("Thử lại") }
                }
                .buttonStyle(.borderedProminent).disabled(retrying)
            }
            .padding(.top, 4)
        }
        .padding(40)
        .frame(width: 460, height: 320)
    }
}
