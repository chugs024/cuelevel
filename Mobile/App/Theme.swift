import SwiftUI

// CueLevel for iPhone and iPad: the same graphite design as the Mac app. Colour only ever means level:
// quiet (blue) · good (green) · changed / attention (amber) · hot (red). Everything else is neutral.

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

enum Theme {
    static let base = Color(hex: 0x16181B)
    static let panel = Color(hex: 0x1D2024)
    static let raised = Color(hex: 0x262A2F)
    static let field = Color(hex: 0x131518)
    static let line = Color(hex: 0x30343A)
    static let line2 = Color(hex: 0x41464E)
    static let bone = Color(hex: 0xEEE9E0)
    static let text = Color(hex: 0xCFCBC4)
    static let muted = Color(hex: 0x9CA1A8)
    static let dim = Color(hex: 0x7A7F86)
    static let quiet = Color(hex: 0x6CB6FF)
    static let good = Color(hex: 0x4FD18B)
    static let changed = Color(hex: 0xF2B544)
    static let hot = Color(hex: 0xFF5D4E)
    static let onGood = Color(hex: 0x0F2A1B)

    static func tone(_ tone: LevelTone) -> Color {
        switch tone {
        case .neutral: return muted
        case .quiet: return quiet
        case .good: return good
        case .changed: return changed
        case .hot: return hot
        }
    }
    /// Loudness scale used by every ruler: −40 to 0 LUFS.
    static func position(_ lufs: Double) -> Double { min(1, max(0, (lufs + 40) / 40)) }
    static let meter = LinearGradient(colors: [quiet.opacity(0.55), good.opacity(0.55), changed.opacity(0.55), hot.opacity(0.55)], startPoint: .leading, endPoint: .trailing)
}

extension Font {
    /// The one large readout per screen: expanded width, like a console display.
    static func readout(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font { .system(size: size, weight: weight).width(.expanded) }
}

func lufsText(_ v: Double) -> String { String(format: "%.1f", v).replacingOccurrences(of: "-", with: "−") }
func dbText(_ v: Double, signed: Bool = true) -> String {
    let s = String(format: "%.1f", abs(v))
    return (v < 0 ? "−" : (signed ? "+" : "")) + s
}
func clock(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "00:00" }
    let s = Int(seconds.rounded(.down)); return String(format: "%02d:%02d", s / 60, s % 60)
}

// MARK: Controls
struct CLButton: ButtonStyle {
    enum Kind { case primary, secondary, ghost, hero }
    var kind = Kind.secondary
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let filled = kind == .primary || kind == .hero
        return configuration.label
            .font(.system(size: kind == .hero ? 17 : 15, weight: filled ? .semibold : .medium))
            .foregroundStyle(filled ? Theme.onGood : kind == .ghost ? Theme.text : Theme.bone)
            .padding(.horizontal, kind == .hero ? 18 : 14).padding(.vertical, kind == .hero ? 15 : 10)
            .frame(maxWidth: kind == .hero ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: kind == .hero ? 14 : 10).fill(filled ? Theme.good : kind == .ghost ? Color.clear : Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: kind == .hero ? 14 : 10).stroke(kind == .secondary ? Theme.line2 : Color.clear, lineWidth: 1))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.38)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line, lineWidth: 1))
    }
}

/// The CueLevel mark: three bars of varying height (as they arrive) and three level ones (as they leave).
struct LogoMark: View {
    var body: some View {
        Canvas { g, size in
            let w = size.width / 28
            let bars: [(CGFloat, CGFloat, CGFloat, Color)] = [(3, 10, 8, Theme.bone), (7.4, 4, 20, Theme.bone), (11.8, 8, 12, Theme.bone),
                                                              (16.2, 9, 10, Theme.good), (20.6, 9, 10, Theme.good), (25, 9, 10, Theme.good)]
            for (x, y, h, c) in bars {
                g.fill(Path(roundedRect: CGRect(x: x * w - 1.2 * w, y: y * w, width: 2.4 * w, height: h * w), cornerRadius: 1.2 * w), with: .color(c))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
