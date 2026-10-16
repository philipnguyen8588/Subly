import SwiftUI

enum Theme {
    static let accentStart = Color(red: 0.38, green: 0.44, blue: 0.98)
    static let accentEnd = Color(red: 0.16, green: 0.76, blue: 0.70)
    static let gemini = Color(red: 0.16, green: 0.72, blue: 0.66)
    static let apple = Color.orange
    static let danger = Color(red: 0.93, green: 0.33, blue: 0.31)
    static let cardRadius: CGFloat = 12

    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accentStart, accentEnd], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static func backendColor(_ backend: String) -> Color {
        switch backend {
        case "gemini": return gemini
        case "appleAI": return Color.purple
        case "openAI": return Color(red: 0.06, green: 0.64, blue: 0.5)
        case "anthropic": return Color(red: 0.85, green: 0.47, blue: 0.34)
        case "custom": return Color(red: 0.45, green: 0.5, blue: 0.85)
        default: return apple
        }
    }
    static var windowBackground: Color { Color(nsColor: .windowBackgroundColor) }
    static var cardFill: Color { Color.primary.opacity(0.045) }
    static var cardStroke: Color { Color.primary.opacity(0.08) }
    static var controlFill: Color { Color.primary.opacity(0.06) }
    static var controlStroke: Color { Color.primary.opacity(0.12) }
}

struct CardStyle: ViewModifier {
    var padding: CGFloat = 12
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).stroke(Theme.cardStroke, lineWidth: 1))
    }
}
extension View {
    func card(padding: CGFloat = 12) -> some View { modifier(CardStyle(padding: padding)) }
}

struct SectionHeader<Trailing: View>: View {
    let title: String
    var icon: String? = nil
    @ViewBuilder var trailing: Trailing

    init(_ title: String, icon: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.icon = icon; self.trailing = trailing()
    }
    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.caption).foregroundStyle(.secondary) }
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(1)
                .foregroundStyle(.secondary)
            Spacer()
            trailing
        }
    }
}
extension SectionHeader where Trailing == EmptyView {
    init(_ title: String, icon: String? = nil) { self.init(title, icon: icon) { EmptyView() } }
}

struct StatusPill: View {
    let color: Color
    let text: String
    var detail: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.7), radius: 3)
            Text(text).font(.callout.weight(.medium))
            if let detail {
                Text(detail).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(Theme.cardFill))
        .overlay(Capsule().stroke(Theme.cardStroke, lineWidth: 1))
    }
}

/// Hệ nút dùng chung cho cả app: mọi nút có chữ cùng chiều cao, cùng bo góc, cùng cỡ chữ.
/// `.regular` (36 pt) cho thanh công cụ và hộp thoại, `.large` (44 pt) cho nút hành động chính của một màn hình.
enum AppButtonKind { case primary, tinted, secondary, danger, ghost }
enum AppButtonSize {
    case regular, large
    var height: CGFloat { self == .large ? 44 : 36 }
    var font: Font { self == .large ? .system(size: 15, weight: .semibold) : .system(size: 13, weight: .semibold) }
    var padding: CGFloat { self == .large ? 20 : 14 }
}

struct AppButtonStyle: ButtonStyle {
    var kind: AppButtonKind = .primary
    var size: AppButtonSize = .regular
    /// Nút chỉ có biểu tượng: vuông, cạnh bằng chiều cao.
    var iconOnly = false
    /// Giãn hết chiều ngang được cấp.
    var fill = false
    var minWidth: CGFloat? = nil

    func makeBody(configuration: Configuration) -> some View {
        AppButtonBody(configuration: configuration, style: self)
    }

    static let radius: CGFloat = 10
}

private struct AppButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let style: AppButtonStyle
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AppButtonStyle.radius, style: .continuous)
        configuration.label
            .font(style.size.font)
            .labelStyle(AppButtonLabelStyle())
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, style.iconOnly ? 0 : style.size.padding)
            .frame(width: style.iconOnly ? style.size.height : nil, height: style.size.height)
            .frame(minWidth: style.iconOnly ? nil : style.minWidth, maxWidth: style.fill ? .infinity : nil)
            .background(background, in: shape)
            .overlay(shape.strokeBorder(border, lineWidth: 1))
            .overlay(shape.fill(Color.primary.opacity(hovering && isEnabled && style.kind != .primary && style.kind != .danger ? 0.05 : 0)))
            .brightness(hovering && isEnabled && (style.kind == .primary || style.kind == .danger) ? 0.04 : 0)
            .contentShape(shape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .onHover { hovering = $0 }
    }

    private var foreground: Color {
        switch style.kind {
        case .primary, .danger: return .white
        case .tinted: return Theme.accentStart
        case .secondary: return .primary
        case .ghost: return .secondary
        }
    }
    private var background: AnyShapeStyle {
        switch style.kind {
        case .primary: return AnyShapeStyle(Theme.accentGradient)
        case .danger: return AnyShapeStyle(Theme.danger)
        case .tinted: return AnyShapeStyle(Theme.accentStart.opacity(0.12))
        case .secondary: return AnyShapeStyle(Theme.controlFill)
        case .ghost: return AnyShapeStyle(Color.clear)
        }
    }
    private var border: Color {
        switch style.kind {
        case .primary, .danger, .ghost: return .clear
        case .tinted: return Theme.accentStart.opacity(0.45)
        case .secondary: return Theme.controlStroke
        }
    }
}

/// Biểu tượng + chữ trong nút: khoảng cách đều, biểu tượng nhỏ hơn chữ một chút.
struct AppButtonLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            configuration.icon.imageScale(.medium)
            configuration.title
        }
    }
}

extension View {
    /// Áp kiểu nút chung của app.
    func appButton(_ kind: AppButtonKind = .secondary, size: AppButtonSize = .regular, fill: Bool = false, minWidth: CGFloat? = nil) -> some View {
        buttonStyle(AppButtonStyle(kind: kind, size: size, fill: fill, minWidth: minWidth))
    }
    /// Nút chỉ có biểu tượng (vuông 36 pt).
    func appIconButton(_ kind: AppButtonKind = .secondary, size: AppButtonSize = .regular) -> some View {
        buttonStyle(AppButtonStyle(kind: kind, size: size, iconOnly: true))
    }
}

/// Toggle dạng nút có chữ (ví dụ "Vẽ khung phụ đề"): bật = viền màu nhấn, tắt = nút thường. Cùng kích thước với AppButtonStyle.
struct AppToggleButtonStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: { configuration.label }
            .buttonStyle(AppButtonStyle(kind: configuration.isOn ? .tinted : .secondary))
    }
}

/// Toggle chỉ có biểu tượng trên thanh đầu cửa sổ (voice, overlay, cốt truyện): 36×36 như mọi nút biểu tượng khác.
struct IconToggleStyle: ToggleStyle {
    let icon: String
    let help: String
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Image(systemName: icon).font(.system(size: 15, weight: .medium))
        }
        .buttonStyle(AppButtonStyle(kind: configuration.isOn ? .primary : .secondary, iconOnly: true))
        .help(help)
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var steps: [String] = []
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.accentGradient)
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if !steps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(i + 1)").font(.caption.weight(.bold)).foregroundStyle(.white)
                                .frame(width: 18, height: 18).background(Circle().fill(Theme.accentGradient))
                            Text(s).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: 360)
        .padding(24)
    }
}

extension Date {
    var hm: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: self)
    }
    var hms: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: self)
    }
}
