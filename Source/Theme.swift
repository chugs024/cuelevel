import SwiftUI
import AppKit

// MARK: - CueLevel 2.0 design system
// Graphite surfaces that stay easy on the eyes in a dark booth. Colour is only ever used for level:
//   quiet (blue) · good (green) · changed / attention (amber) · hot (red).
// Everything else is neutral, so a glance at any screen tells you which cues are where.

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

enum Theme {
    // Surfaces
    static let base = Color(hex: 0x16181B)      // window
    static let panel = Color(hex: 0x1D2024)     // side panels, cards
    static let raised = Color(hex: 0x262A2F)    // controls, selected rows
    static let field = Color(hex: 0x131518)     // inputs, wells
    static let line = Color(hex: 0x30343A)
    static let line2 = Color(hex: 0x41464E)
    // Text
    static let bone = Color(hex: 0xEEE9E0)      // primary text ("paper")
    static let text = Color(hex: 0xCFCBC4)
    static let muted = Color(hex: 0x9CA1A8)
    static let dim = Color(hex: 0x6C7178)
    // Level colours
    static let quiet = Color(hex: 0x6CB6FF)
    static let good = Color(hex: 0x4FD18B)
    static let changed = Color(hex: 0xF2B544)
    static let hot = Color(hex: 0xFF5D4E)
    static let onGood = Color(hex: 0x0F2A1B)    // text on a green button
    // Names used throughout the app (kept so every screen picks up the new palette).
    static let teal = good
    static let lime = Color(hex: 0xA6E4C0)       // references ("sounds right")
    static let amber = changed
    static let coral = hot

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
    static let meter = LinearGradient(colors: [quiet, good, changed, hot], startPoint: .leading, endPoint: .trailing)
}

// MARK: Type
extension Font {
    /// The one large readout per screen: expanded width, like a console display.
    static func readout(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font { .system(size: size, weight: weight).width(.expanded) }
}

// MARK: Controls
struct CLButton: ButtonStyle {
    enum Kind { case primary, secondary, ghost, danger, hero }
    var kind = Kind.secondary
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let hero = kind == .hero
        return configuration.label
            .font(.system(size: hero ? 14 : 12.5, weight: kind == .primary || hero ? .semibold : .medium))
            .foregroundStyle(kind == .primary || hero ? Theme.onGood : kind == .danger ? Theme.hot : kind == .ghost ? Theme.text : Theme.bone)
            .padding(.horizontal, hero ? 16 : 11).padding(.vertical, hero ? 11 : 6)
            .frame(maxWidth: hero ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: hero ? 10 : 7).fill(kind == .primary || hero ? Theme.good : kind == .ghost ? Color.clear : Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(kind == .secondary || kind == .danger ? Theme.line2 : Color.clear, lineWidth: 1))
            .opacity(enabled ? (configuration.isPressed ? 0.78 : 1) : 0.38)
            .contentShape(Rectangle())
    }
}

struct CLSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                configuration.label
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? Theme.good : Theme.line2).frame(width: 30, height: 18)
                    Circle().fill(configuration.isOn ? Theme.onGood : Color(hex: 0xC9C6C0)).frame(width: 14, height: 14).padding(2)
                }.animation(.easeOut(duration: 0.15), value: configuration.isOn)
            }
        }.buttonStyle(.plain).accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

/// A square tickbox for plan steps.
struct CLCheck: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 5).fill(configuration.isOn ? Theme.good : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(configuration.isOn ? Color.clear : Theme.line2, lineWidth: 1.5))
                    .overlay { if configuration.isOn { Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(Theme.onGood) } }
                    .frame(width: 18, height: 18).padding(.top, 1)
                configuration.label
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

/// A segmented control in the app's own style.
struct Segments<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                Button { selection = option.0 } label: {
                    Text(option.1).font(.system(size: 12.5, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 4).padding(.horizontal, 10)
                        .foregroundStyle(selection == option.0 ? Theme.bone : Theme.muted)
                        .background(RoundedRectangle(cornerRadius: 6).fill(selection == option.0 ? Theme.raised : Color.clear))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(selection == option.0 ? .isSelected : [])
            }
        }.padding(2).background(RoundedRectangle(cornerRadius: 8).fill(Theme.field)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
    }
}

/// A small rounded filter chip.
struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(selected ? Theme.bone : Theme.muted)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Capsule().fill(selected ? Theme.raised : Color.clear)).overlay(Capsule().stroke(Theme.line))
        }.buttonStyle(.plain)
    }
}

extension View {
    func card(padding: CGFloat = 18) -> some View {
        self.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
    }
    func sectionTitle() -> some View { font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.bone) }
    func hint() -> some View { font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
}

func lufs(_ value: Double?) -> String { value.map { String(format: "%.1f", $0).replacingOccurrences(of: "-", with: "−") } ?? "—" }
func signed(_ value: Double) -> String { (value >= 0 ? "+" : "−") + String(format: "%.1f", abs(value)) }

// MARK: - Mark
/// The CueLevel mark: uneven bars that become even, in the good green. `tile` draws the app-icon background.
struct LogoMark: View {
    var tile = false
    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height) / 1024
            if tile {
                let rect = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
                context.fill(Path(roundedRect: rect, cornerRadius: 185 * s), with: .linearGradient(Gradient(colors: [Color(hex: 0x2B2E33), Color(hex: 0x17191C)]), startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: rect.maxY)))
            }
            let heights: [Double] = [0.30, 0.78, 0.46, 0.92, 0.55, 0.55, 0.55]
            // Without the tile the mark is drawn larger so it reads at toolbar size.
            let scale = tile ? 1.0 : 1.55, origin = tile ? 0.0 : -(1024 * (scale - 1) / 2)
            for (i, h) in heights.enumerated() {
                let x = (262 + Double(i) * 83) * scale + origin, w = 46 * scale, hh = h * 440 * scale, cy = 512.0
                let rect = CGRect(x: (x - w / 2) * s, y: (cy - hh / 2) * s, width: w * s, height: hh * s)
                context.fill(Path(roundedRect: rect, cornerRadius: w / 2 * s), with: .color(i >= 4 ? Theme.good : Theme.bone))
            }
        }.accessibilityHidden(true)
    }
}

/// A cue's stage in a few words, in the colour that means the same thing everywhere.
struct StageLabel: View {
    let job: CueJob
    var body: some View {
        let stage = CueStage(job)
        let color: Color = {
            switch stage {
            case .levelled, .alreadyGood: return Theme.good
            case .needsLook: return Theme.changed
            case .failed: return job.message.localizedCaseInsensitiveContains("silent") ? Theme.muted : Theme.hot
            case .working: return Theme.bone
            default: return Theme.muted
            }
        }()
        let text: String = {
            if stage == .working { return "\(Int(job.progress * 100))%" }
            if stage == .failed, job.message.localizedCaseInsensitiveContains("silent") { return "Silent" }
            if stage == .needsLook, let short = job.output?.shortfall, short > 0.05 { return String(format: "%.1f dB under", short) }
            return stage.title
        }()
        HStack(spacing: 4) {
            if stage == .alreadyGood { Image(systemName: "checkmark.seal.fill").font(.system(size: 10)) }
            Text(text)
        }.font(.system(size: 11.5, weight: .semibold)).monospacedDigit().foregroundStyle(color)
    }
}

/// Live loudness while playing: momentary (bar) and short-term (tick) LUFS against the target, plus sample peak.
struct LoudnessMeterBar: View {
    let reading: (momentary: Double?, shortTerm: Double?, peak: Double?)
    let target: Double
    let ready: Bool
    var body: some View {
        HStack(spacing: 12) {
            GeometryReader { geometry in
                let w = geometry.size.width
                let x: (Double) -> CGFloat = { v in CGFloat((min(0, max(-40, v)) + 40) / 40) * w }
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Theme.field)
                    if let m = reading.momentary {
                        RoundedRectangle(cornerRadius: 3).fill(Theme.tone(levelTone(m, target: target))).frame(width: max(2, x(m)))
                    }
                    if let s = reading.shortTerm { Rectangle().fill(Theme.bone).frame(width: 2, height: 12).offset(x: x(s) - 1) }
                    Rectangle().fill(Theme.bone.opacity(0.6)).frame(width: 1.5, height: 14).offset(x: x(target))
                }
            }.frame(height: 8)
            meterValue("Now", reading.momentary, "LUFS")
            meterValue("3 s", reading.shortTerm, "LUFS")
            meterValue("Peak", reading.peak, "dB", warn: (reading.peak ?? -100) > -1)
        }
        .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
        .opacity(ready ? 1 : 0.4)
        .help("Live loudness of what's playing. Now = the last 0.4 s, 3 s = the last three seconds. The white mark is the target.")
    }
    func meterValue(_ label: String, _ value: Double?, _ unit: String, warn: Bool = false) -> some View {
        HStack(spacing: 3) {
            Text(label)
            Text(value.map { lufs($0) } ?? "—").font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(warn ? Theme.hot : Theme.bone).frame(minWidth: 38, alignment: .trailing)
            Text(unit)
        }
    }
}
