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
        default: return apple
        }
    }
    static var windowBackground: Color { Color(nsColor: .windowBackgroundColor) }
    static var cardFill: Color { Color.primary.opacity(0.045) }
    static var cardStroke: Color { Color.primary.opacity(0.08) }
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

struct GradientButtonStyle: ButtonStyle {
    var tint: LinearGradient = Theme.accentGradient
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? .callout.weight(.semibold) : .body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 12 : 16).padding(.vertical, compact ? 6 : 8)
            .background(tint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .shadow(color: Theme.accentStart.opacity(0.25), radius: 6, y: 2)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct IconToggleStyle: ToggleStyle {
    let icon: String
    let help: String
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 26)
                .foregroundStyle(configuration.isOn ? Color.white : Color.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(configuration.isOn ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.cardFill))
                )
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Theme.cardStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
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
