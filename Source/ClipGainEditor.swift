import SwiftUI
import AppKit

/// Pro Tools-style clip gain on the waveform: drag across empty space to make a section, drag its line up or down to change
/// its volume, drag the square handles at the top to set fade lengths, drag the lower part of an edge to resize.
/// A click without dragging moves the playhead (and selects the section under it).
struct ClipGainWaveform: View {
    let peaks: [Float]
    let duration: Double
    let position: Double
    let regions: [GainRegion]
    let selected: UUID?
    let onSeek: (Double) -> Void
    let onCreate: (Double, Double) -> Void
    let onChange: (GainRegion) -> Void
    let onSelect: (UUID?) -> Void

    enum Handle { case gain, fadeIn, fadeOut, left, right, body, empty }
    @State private var handle: Handle?
    @State private var original: GainRegion?
    @State private var draft: GainRegion?
    @State private var newRange: (Double, Double)?

    static let height: CGFloat = 176
    private var shown: [GainRegion] { regions.map { $0.id == draft?.id ? draft! : $0 } }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            Canvas { context, canvasSize in draw(&context, canvasSize) }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in dragChanged(value, size) }
                    .onEnded { value in dragEnded(value, size) })
                .overlay { if peaks.isEmpty { Text("Measure the cue to draw its waveform").hint() } }
                .accessibilityLabel("Clip gain editor. \(regions.count) section\(regions.count == 1 ? "" : "s").")
                .onHover { inside in if !inside { NSCursor.arrow.set() } }
                .onContinuousHover { phase in
                    if case .active(let point) = phase { cursor(for: hit(point, size)).set() }
                }
        }.frame(height: Self.height)
    }

    // MARK: Geometry
    private func x(_ t: Double, _ w: CGFloat) -> CGFloat { duration > 0 ? CGFloat(t / duration) * w : 0 }
    private func t(_ x: CGFloat, _ w: CGFloat) -> Double { duration > 0 ? min(duration, max(0, Double(x / max(1, w)) * duration)) : 0 }
    private func lineY(_ gain: Double, _ h: CGFloat) -> CGFloat { h / 2 - CGFloat(gain / 24) * (h / 2 - 16) }

    private func hit(_ p: CGPoint, _ size: CGSize) -> (Handle, GainRegion?) {
        let ordered = shown.filter { $0.id == selected } + shown.filter { $0.id != selected }
        for r in ordered {
            let x0 = x(r.start, size.width), x1 = x(r.end, size.width)
            if abs(p.x - x(r.start + r.fadeIn, size.width)) < 8, p.y < 20 { return (.fadeIn, r) }
            if abs(p.x - x(r.end - r.fadeOut, size.width)) < 8, p.y < 20 { return (.fadeOut, r) }
            if p.x >= x0 - 4, p.x <= x1 + 4 {
                if p.y > size.height * 0.6 && abs(p.x - x0) < 6 { return (.left, r) }
                if p.y > size.height * 0.6 && abs(p.x - x1) < 6 { return (.right, r) }
                if p.x >= x0, p.x <= x1, abs(p.y - lineY(r.gain, size.height)) < 7 { return (.gain, r) }
                if p.x >= x0, p.x <= x1 { return (.body, r) }
            }
        }
        return (.empty, nil)
    }
    private func cursor(for result: (Handle, GainRegion?)) -> NSCursor {
        switch result.0 {
        case .gain: return .resizeUpDown
        case .fadeIn, .fadeOut, .left, .right: return .resizeLeftRight
        case .body: return .pointingHand
        case .empty: return .iBeam
        }
    }

    // MARK: Dragging
    private func dragChanged(_ value: DragGesture.Value, _ size: CGSize) {
        if handle == nil {
            let (h, r) = hit(value.startLocation, size)
            handle = h; original = r; draft = r
            if let r { onSelect(r.id) }
        }
        let moved = hypot(value.translation.width, value.translation.height) > 3
        guard moved, let h = handle else { return }
        let now = t(value.location.x, size.width)
        switch h {
        case .empty: newRange = (t(value.startLocation.x, size.width), now)
        case .body: break
        case .gain:
            guard var r = original else { return }
            r.gain = r.gain - Double(value.translation.height) / Double(size.height / 2 - 16) * 24
            draft = r.normalized(duration: duration)
        case .fadeIn:
            guard var r = original else { return }
            r.fadeIn = now - r.start; draft = r.normalized(duration: duration)
        case .fadeOut:
            guard var r = original else { return }
            r.fadeOut = r.end - now; draft = r.normalized(duration: duration)
        case .left:
            guard var r = original else { return }
            r.start = min(now, r.end - GainRegion.minimumLength); draft = r.normalized(duration: duration)
        case .right:
            guard var r = original else { return }
            r.end = max(now, r.start + GainRegion.minimumLength); draft = r.normalized(duration: duration)
        }
    }
    private func dragEnded(_ value: DragGesture.Value, _ size: CGSize) {
        defer { handle = nil; original = nil; draft = nil; newRange = nil }
        let moved = hypot(value.translation.width, value.translation.height) > 3
        switch handle {
        case .empty?:
            if moved, let range = newRange, abs(range.1 - range.0) >= GainRegion.minimumLength { onCreate(range.0, range.1) }
            else { onSelect(nil); onSeek(t(value.location.x, size.width)) }
        case .body?: onSeek(t(value.location.x, size.width))
        default:
            if moved, let draft, draft != original { onChange(draft) }
            else if !moved { onSeek(t(value.location.x, size.width)) }
        }
    }

    // MARK: Drawing
    private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        let w = size.width, h = size.height, middle = h / 2
        var grid = Path()
        for row in 1...3 { let y = h * Double(row) / 4; grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: w, y: y)) }
        context.stroke(grid, with: .color(.white.opacity(0.05)), lineWidth: 1)
        let list = shown
        let active = ClipGain.active(list)

        // Sections behind the waveform.
        for r in list {
            let rect = CGRect(x: x(r.start, w), y: 0, width: max(2, x(r.end, w) - x(r.start, w)), height: h)
            let isSelected = r.id == selected
            let tint = r.isReference ? Theme.lime : Theme.teal
            context.fill(Path(rect), with: .color(tint.opacity(isSelected ? 0.11 : 0.05)))
            var edges = Path(); edges.move(to: CGPoint(x: rect.minX, y: 0)); edges.addLine(to: CGPoint(x: rect.minX, y: h))
            edges.move(to: CGPoint(x: rect.maxX, y: 0)); edges.addLine(to: CGPoint(x: rect.maxX, y: h))
            context.stroke(edges, with: .color(tint.opacity(isSelected ? 0.7 : 0.3)), lineWidth: 1)
        }
        if let range = newRange {
            let a = x(min(range.0, range.1), w), b = x(max(range.0, range.1), w)
            context.fill(Path(CGRect(x: a, y: 0, width: b - a, height: h)), with: .color(Theme.teal.opacity(0.16)))
        }

        // Waveform: the original faintly, the edited result on top.
        if !peaks.isEmpty {
            let step = w / Double(peaks.count)
            var before = Path(), after = Path()
            for (index, peak) in peaks.enumerated() {
                let time = (Double(index) + 0.5) / Double(peaks.count) * duration
                let m = active.isEmpty ? 1 : ClipGain.multiplier(at: time, regions: active)
                let base = max(1, min(1, pow(Double(peak), 0.6)) * (middle - 6))
                let edited = max(1, min(1, pow(Double(peak) * m, 0.6)) * (middle - 6))
                let x0 = Double(index) * step, bar = max(1, step * 0.62)
                if m != 1 { before.addRect(CGRect(x: x0, y: middle - base, width: bar, height: base * 2)) }
                after.addRoundedRect(in: CGRect(x: x0, y: middle - edited, width: bar, height: edited * 2), cornerSize: CGSize(width: 0.8, height: 0.8))
            }
            context.fill(before, with: .color(Theme.muted.opacity(0.22)))
            context.fill(after, with: .linearGradient(Gradient(colors: [Theme.teal.opacity(0.9), Theme.teal.opacity(0.5), Theme.teal.opacity(0.9)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
        }

        // Gain lines with fades, handles and labels.
        var zero = Path(); zero.move(to: CGPoint(x: 0, y: middle)); zero.addLine(to: CGPoint(x: w, y: middle))
        context.stroke(zero, with: .color(Theme.bone.opacity(0.12)), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
        for r in list {
            let isSelected = r.id == selected
            let a = x(r.start, w), b = x(r.end, w), fi = x(r.start + r.fadeIn, w), fo = x(r.end - r.fadeOut, w), y = lineY(r.gain, h)
            var line = Path()
            line.move(to: CGPoint(x: a, y: middle)); line.addLine(to: CGPoint(x: fi, y: y)); line.addLine(to: CGPoint(x: fo, y: y)); line.addLine(to: CGPoint(x: b, y: middle))
            context.stroke(line, with: .color(isSelected ? Theme.bone : Theme.bone.opacity(0.65)), style: StrokeStyle(lineWidth: isSelected ? 2 : 1.4, lineJoin: .round))
            for hx in [fi, fo] {
                let square = CGRect(x: hx - 4.5, y: 4, width: 9, height: 9)
                context.fill(Path(roundedRect: square, cornerRadius: 2), with: .color(isSelected ? Theme.amber : Theme.amber.opacity(0.55)))
                var guide = Path(); guide.move(to: CGPoint(x: hx, y: 13)); guide.addLine(to: CGPoint(x: hx, y: y))
                context.stroke(guide, with: .color(Theme.amber.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            let label = r.isReference ? "★ Sounds right" + (abs(r.gain) >= 0.05 ? " · " + signed(r.gain) + " dB" : "") : signed(r.gain) + " dB"
            if b - a > 44 {
                context.draw(Text(label).font(.system(size: 10.5, weight: .semibold)).monospacedDigit().foregroundColor(r.isReference ? Theme.lime : Theme.bone),
                             at: CGPoint(x: (fi + fo) / 2, y: max(24, y - 11)))
            }
        }

        let px = duration > 0 ? min(1, max(0, position / duration)) * w : 0
        var cursor = Path(); cursor.move(to: CGPoint(x: px, y: 0)); cursor.addLine(to: CGPoint(x: px, y: h))
        context.stroke(cursor, with: .color(Theme.bone), lineWidth: 1)
    }
}

/// Controls under the clip gain editor for the selected section.
struct ClipGainBar: View {
    @EnvironmentObject var model: Workspace
    var body: some View {
        let regions = model.selectedRegions
        let region = regions.first { $0.id == model.selectedRegion }
        VStack(alignment: .leading, spacing: 8) {
            if let region {
                HStack(spacing: 8) {
                    Text("\(clockText(region.start)) – \(clockText(region.end))").monospacedDigit().foregroundStyle(Theme.text)
                    Divider().frame(height: 14)
                    Button { model.nudgeSelectedRegion(by: -1) } label: { Image(systemName: "minus") }.buttonStyle(CLButton(kind: .ghost)).help("Lower by 1 dB")
                    TextField("Gain", value: Binding(get: { region.gain }, set: { var r = region; r.gain = $0; model.updateRegion(r) }), format: .number.precision(.fractionLength(1)))
                        .textFieldStyle(.plain).multilineTextAlignment(.trailing).frame(width: 44).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 3).background(RoundedRectangle(cornerRadius: 6).fill(Theme.field)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
                    Text("dB").foregroundStyle(Theme.muted)
                    Button { model.nudgeSelectedRegion(by: 1) } label: { Image(systemName: "plus") }.buttonStyle(CLButton(kind: .ghost)).help("Raise by 1 dB")
                    Divider().frame(height: 14)
                    Button { model.markSelectedAsReference() } label: { Label(region.isReference ? "Sounds right ✓" : "Sounds right", systemImage: "star") }
                        .buttonStyle(CLButton(kind: .ghost)).help("Mark this section as the level other sections should match")
                    Button { model.matchSelectedToReference() } label: { Label(model.measuringSection ? "Measuring…" : "Match", systemImage: "equal.circle") }
                        .buttonStyle(CLButton(kind: .ghost)).disabled(model.referenceRegion == nil || region.isReference || model.measuringSection || model.busy)
                        .help(model.referenceRegion == nil ? "Mark a section as Sounds right first" : "Set this section's gain so it is as loud as the Sounds right section")
                    Spacer()
                    Button { model.deleteSelectedRegion() } label: { Image(systemName: "trash") }.buttonStyle(CLButton(kind: .ghost)).help("Remove this section")
                }
                HStack(spacing: 14) {
                    Text("Fade in \(Int(region.fadeIn * 1000)) ms").monospacedDigit()
                    Text("Fade out \(Int(region.fadeOut * 1000)) ms").monospacedDigit()
                    Spacer()
                    if !regions.isEmpty { Button("Clear all") { model.clearRegions() }.buttonStyle(.plain).foregroundStyle(Theme.muted) }
                }.font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            } else {
                HStack {
                    Text(regions.isEmpty
                         ? "Drag across the waveform to select a section, then drag its line up or down. Drag the orange squares to set fades."
                         : "Click a section to edit it, or drag across empty space for a new one. Mark one as Sounds right, then Match the others to it.").hint()
                    Spacer()
                    if !regions.isEmpty { Button("Clear all") { model.clearRegions() }.buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(Theme.muted) }
                }
            }
            if model.outputIsStale, model.selected?.output != nil {
                Text("Edits apply when you level the cue again.").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.amber)
            }
        }.font(.system(size: 12))
    }
}
