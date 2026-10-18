import SwiftUI

/// Tab "Thiết lập game": phong cách dịch, tên người nói đã học và thuật ngữ riêng của game đang chơi.
struct GameSetupView: View {
    enum Part: String, CaseIterable, Identifiable {
        case style, speakers, glossary
        var id: String { rawValue }
    }

    @ObservedObject var settings = AppSettings.shared
    @AppStorage("gameSetupPart") private var part: Part = .glossary

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $part) {
                    Text("Phong cách dịch").tag(Part.style)
                    Text(settings.showsSpeakerNames && !settings.speakers.isEmpty ? "Tên người nói  \(settings.speakers.count)" : "Tên người nói")
                        .tag(Part.speakers)
                    Text(settings.glossary.isEmpty ? "Thuật ngữ" : "Thuật ngữ  \(settings.glossary.count)").tag(Part.glossary)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.large)
                Spacer()
                SampleUpdateButton()
            }
            .padding(.horizontal, 14).frame(height: 52)
            Divider()
            switch part {
            case .style:
                ScrollView { TranslationStyleBox().padding(16) }
            case .speakers:
                SpeakersTab()
            case .glossary:
                GlossaryEditor(entries: $settings.glossary, fileName: "thuat-ngu-\(settings.activeProfile.name).csv",
                               note: "Thuật ngữ riêng của game “\(settings.activeProfile.name)”: tên riêng, địa danh, chiêu thức… Khi trùng với thuật ngữ chung (Cài đặt → Thuật ngữ chung) thì bảng này được ưu tiên. Để trống bản dịch = giữ nguyên.")
                    .padding(16)
            }
        }
    }
}
