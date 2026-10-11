import SwiftUI
import AppKit

// Clip gain editor (1.3), laid out like a DAW clip-gain lane:
//   toolbar (undo, zoom) · time ruler · zoomable waveform with sections · fader for the selected section · overview strip
//   · section controls (gain, fades in ms, loudness, play, match).
// Mouse: drag across empty space to make a section; drag inside a section up/down to change its level; orange squares set
// fades; the lower part of an edge resizes. Option-scroll or pinch zooms, scroll pans. Keys: ↑/↓ ±0.5 dB (⇧ ±3 dB),
// T/R zoom in/out, ⌘Z/⇧⌘Z undo/redo.

private let rulerHeight: CGFloat = 20
private let dbRange = 24.0

struct ClipGainEditor: View {
    @EnvironmentObject var model: Workspace
    let job: CueJob
    let analysis: Analysis
    @State private var faderDraft: Double?

    var body: some View {
        let regions = job.clipGain ?? []
        let region = regions.first { $0.id == model.selectedRegion }
        let view = model.timeView.resolved(duration: analysis.info.duration)
        VStack(alignment: .leading, spacing: 8) {
            toolbar(view: view, region: region)
            HStack(alignment: .top, spacing: 10) {
                ClipGainLane(peaks: model.detailWaveform.isEmpty ? analysis.waveform : model.detailWaveform,
                             duration: analysis.info.duration, viewStart: view.start, viewLength: view.length,
                             position: model.playhead, regions: regions, selected: model.selectedRegion,
                             faderOverride: region.flatMap { r in faderDraft.map { var c = r; c.gain = $0; return c } },
                             onSeek: model.seek, onCreate: { model.addRegion(start: $0, end: $1) },
                             onChange: { model.updateRegion($0) }, onSelect: { model.selectedRegion = $0 },
                             onZoom: { factor, anchor in model.zoom(by: factor, around: anchor) }, onPan: { model.pan(by: $0) })
                GainFader(value: region?.gain, draft: $faderDraft) { value in
                    if var r = region { r.gain = value; model.updateRegion(r) }
                }
            }
            OverviewStrip(peaks: analysis.waveform, duration: analysis.info.duration, viewStart: view.start, viewLength: view.length,
                          regions: regions, position: model.playhead) { center in
                model.timeView = TimeView(start: center - view.length / 2, length: model.timeView.length).panned(by: 0, duration: analysis.info.duration)
            }
            sectionBar(region: region, regions: regions)
        }
        .background(shortcuts)
    }

    // MARK: Toolbar
    func toolbar(view: (start: Double, length: Double), region: GainRegion?) -> some View {
        HStack(spacing: 6) {
            Button { model.undoRegions() } label: { Image(systemName: "arrow.uturn.backward") }.buttonStyle(CLButton(kind: .ghost)).disabled(!model.history.canUndo).help("Undo (⌘Z)")
            Button { model.redoRegions() } label: { Image(systemName: "arrow.uturn.forward") }.buttonStyle(CLButton(kind: .ghost)).disabled(!model.history.canRedo).help("Redo (⇧⌘Z)")
            Divider().frame(height: 14)
            Button { model.zoom(by: 0.5) } label: { Image(systemName: "minus.magnifyingglass") }.buttonStyle(CLButton(kind: .ghost)).help("Zoom out (R)")
            Button { model.zoom(by: 2) } label: { Image(systemName: "plus.magnifyingglass") }.buttonStyle(CLButton(kind: .ghost)).help("Zoom in (T)")
            Button("Fit") { model.zoomToFit() }.buttonStyle(CLButton(kind: .ghost)).help("Show the whole cue")
            Button("Section") { model.zoomToSelectedRegion() }.buttonStyle(CLButton(kind: .ghost)).disabled(region == nil).help("Zoom to the selected section")
            Divider().frame(height: 14)
            Button { model.evenOutSelected() } label: { Label("Even out", systemImage: "wand.and.rays") }.buttonStyle(CLButton(kind: .ghost)).disabled(model.measuringSection)
                .help("Find stretches more than 2 dB louder or quieter than the rest and turn them back. Hand-drawn sections are kept.")
            Spacer()
            Text("\(preciseClock(view.start)) – \(preciseClock(view.start + view.length))").monospacedDigit().foregroundStyle(Theme.muted)
            if model.detailWaveform.isEmpty { ProgressView().controlSize(.small).help("Loading the detailed waveform for zooming") }
        }.font(.system(size: 11.5))
    }

    // MARK: Section controls
    @ViewBuilder func sectionBar(region: GainRegion?, regions: [GainRegion]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let region {
                HStack(spacing: 8) {
                    Text("\(preciseClock(region.start)) – \(preciseClock(region.end))").monospacedDigit().foregroundStyle(Theme.text)
                    Text(String(format: "%.2f s", region.length)).monospacedDigit().foregroundStyle(Theme.muted)
                    Divider().frame(height: 14)
                    numberField("Gain", value: region.gain, unit: "dB", width: 46) { var r = region; r.gain = $0; model.updateRegion(r) }
                    numberField("Fade in", value: region.fadeIn * 1000, unit: "ms in", width: 46, decimals: 0) { var r = region; r.fadeIn = $0 / 1000; model.updateRegion(r) }
                    numberField("Fade out", value: region.fadeOut * 1000, unit: "ms out", width: 46, decimals: 0) { var r = region; r.fadeOut = $0 / 1000; model.updateRegion(r) }
                    Spacer()
                    Button { model.deleteSelectedRegion() } label: { Image(systemName: "trash") }.buttonStyle(CLButton(kind: .ghost)).help("Remove this section")
                }
                HStack(spacing: 8) {
                    Button { model.playSelectedSection() } label: { Label("Play section", systemImage: "play.fill") }.buttonStyle(CLButton(kind: .ghost))
                        .help("Plays from just before the section to just after it, with your edits")
                    Button { model.measureSelectedSection() } label: {
                        if let lufs = model.sectionLoudness[region.id] { Text("Section \(String(format: "%.1f", lufs)) LUFS").monospacedDigit() }
                        else { Label(model.measuringSection ? "Measuring…" : "Measure", systemImage: "gauge.with.dots.needle.33percent") }
                    }.buttonStyle(CLButton(kind: .ghost)).disabled(model.measuringSection).help("Integrated loudness of this section with your edits")
                    Divider().frame(height: 14)
                    Button { model.markSelectedAsReference() } label: { Label(region.isReference ? "Sounds right ✓" : "Sounds right", systemImage: "star") }
                        .buttonStyle(CLButton(kind: .ghost)).help("Mark this section as the level other sections should match")
                    Button { model.matchSelectedToReference() } label: { Label("Match", systemImage: "equal.circle") }
                        .buttonStyle(CLButton(kind: .ghost)).disabled(model.referenceRegion == nil || region.isReference || model.measuringSection || model.busy)
                        .help(model.referenceRegion == nil ? "Mark a section as Sounds right first" : "Set this section's gain so it is as loud as the Sounds right section")
                    Spacer()
                    Button("Clear all") { model.clearRegions() }.buttonStyle(.plain).foregroundStyle(Theme.muted)
                }
            } else {
                HStack {
                    Text(regions.isEmpty
                         ? "Drag across the waveform to mark a section, then drag inside it up or down, or use the fader. Option-scroll or pinch to zoom."
                         : "Click a section to select it, or drag across empty space for a new one. ↑/↓ nudge 0.5 dB, ⇧↑/⇧↓ 3 dB, T/R zoom.").hint()
                    Spacer()
                    if !regions.isEmpty { Button("Clear all") { model.clearRegions() }.buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(Theme.muted) }
                }
            }
            HStack(spacing: 6) {
                if model.previewAttenuation > 0.05 {
                    Text("Playback includes your edits, \(String(format: "%.1f", model.previewAttenuation)) dB quieter overall so boosts fit.").hint()
                } else if !ClipGain.active(regions).isEmpty {
                    Text("Playback includes your edits.").hint()
                }
                Spacer()
                if model.outputIsStale, model.selected?.output != nil {
                    Text("Done editing re-levels the cue with these edits.").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.amber)
                }
            }
        }.font(.system(size: 12))
    }
    func numberField(_ title: String, value: Double, unit: String, width: CGFloat, decimals: Int = 1, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 4) {
            TextField(title, value: Binding(get: { value }, set: set), format: .number.precision(.fractionLength(decimals)))
                .textFieldStyle(.plain).multilineTextAlignment(.trailing).frame(width: width).monospacedDigit()
                .padding(.horizontal, 6).padding(.vertical, 3).background(RoundedRectangle(cornerRadius: 6).fill(Theme.field)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
            Text(unit).foregroundStyle(Theme.muted)
        }.help(title)
    }

    // MARK: Keyboard
    var shortcuts: some View {
        Group {
            Button("") { model.nudgeSelectedRegion(by: 0.5) }.keyboardShortcut(.upArrow, modifiers: [])
            Button("") { model.nudgeSelectedRegion(by: -0.5) }.keyboardShortcut(.downArrow, modifiers: [])
            Button("") { model.nudgeSelectedRegion(by: 3) }.keyboardShortcut(.upArrow, modifiers: .shift)
            Button("") { model.nudgeSelectedRegion(by: -3) }.keyboardShortcut(.downArrow, modifiers: .shift)
            Button("") { model.zoom(by: 2) }.keyboardShortcut("t", modifiers: [])
            Button("") { model.zoom(by: 0.5) }.keyboardShortcut("r", modifiers: [])
        }.opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }
}

/// Time with tenths, e.g. 01:23.4 (or 1:02:03.4).
func preciseClock(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "00:00.0" }
    let tenths = Int((seconds * 10).rounded(.down)), s = tenths / 10
    return (s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)) + ".\(tenths % 10)"
}

// MARK: - Lane

struct ClipGainLane: View {
    let peaks: [Float]
    let duration: Double
    let viewStart: Double
    let viewLength: Double
    let position: Double
    let regions: [GainRegion]
    let selected: UUID?
    let faderOverride: GainRegion?
    let onSeek: (Double) -> Void
    let onCreate: (Double, Double) -> Void
    let onChange: (GainRegion) -> Void
    let onSelect: (UUID?) -> Void
    let onZoom: (Double, Double) -> Void
    let onPan: (Double) -> Void

    enum Handle { case gain, fadeIn, fadeOut, left, right, empty }
    @State private var handle: Handle?
    @State private var original: GainRegion?
    @State private var draft: GainRegion?
    @State private var newRange: (Double, Double)?

    static let height: CGFloat = 214
    private var shown: [GainRegion] {
        regions.map { r in
            if let draft, draft.id == r.id { return draft }
            if let faderOverride, faderOverride.id == r.id { return faderOverride }
            return r
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            Canvas { context, canvasSize in draw(&context, canvasSize) }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in dragChanged(value, size) }
                    .onEnded { value in dragEnded(value, size) })
                .overlay { if peaks.isEmpty { Text("Measure the cue to draw its waveform").hint() } }
                .background(ScrollZoomCatcher(onScroll: { dx, dy, flags, fx in scrolled(dx: dx, dy: dy, flags: flags, fx: fx, width: size.width) },
                                              onMagnify: { m, fx in onZoom(1 + Double(m), time(atFraction: fx)) }))
                .onHover { inside in if !inside { NSCursor.arrow.set() } }
                .onContinuousHover { phase in if case .active(let p) = phase { cursor(for: hit(p, size).0).set() } }
                .accessibilityLabel("Clip gain editor with \(regions.count) section\(regions.count == 1 ? "" : "s")")
        }
        .frame(height: Self.height)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Geometry
    private var length: Double { max(1e-6, viewLength) }
    private func x(_ t: Double, _ w: CGFloat) -> CGFloat { CGFloat((t - viewStart) / length) * w }
    private func t(_ x: CGFloat, _ w: CGFloat) -> Double { min(duration, max(0, viewStart + Double(x / max(1, w)) * length)) }
    private func time(atFraction f: CGFloat) -> Double { viewStart + Double(f) * length }
    private func laneTop() -> CGFloat { rulerHeight }
    private func lineY(_ gain: Double, _ h: CGFloat) -> CGFloat {
        let top = rulerHeight, mid = top + (h - top) / 2
        return mid - CGFloat(gain / dbRange) * ((h - top) / 2 - 14)
    }

    private func scrolled(dx: CGFloat, dy: CGFloat, flags: NSEvent.ModifierFlags, fx: CGFloat, width: CGFloat) -> Bool {
        if flags.contains(.option) || flags.contains(.command) {
            guard dy != 0 else { return true }
            onZoom(exp(Double(dy) * 0.012), time(atFraction: fx)); return true
        }
        let zoomed = viewLength < duration - 1e-6
        guard zoomed else { return false }   // let the page scroll when showing the whole cue
        let delta = abs(dx) > abs(dy) ? dx : dy
        onPan(-Double(delta) / Double(max(1, width)) * viewLength); return true
    }

    private func hit(_ p: CGPoint, _ size: CGSize) -> (Handle, GainRegion?) {
        guard p.y > rulerHeight else { return (.empty, nil) }
        let ordered = shown.filter { $0.id == selected } + shown.filter { $0.id != selected }
        for r in ordered {
            let x0 = x(r.start, size.width), x1 = x(r.end, size.width)
            if abs(p.x - x(r.start + r.fadeIn, size.width)) < 8, p.y < rulerHeight + 20 { return (.fadeIn, r) }
            if abs(p.x - x(r.end - r.fadeOut, size.width)) < 8, p.y < rulerHeight + 20 { return (.fadeOut, r) }
            if p.x >= x0 - 4, p.x <= x1 + 4 {
                if p.y > size.height * 0.75 && abs(p.x - x0) < 5 { return (.left, r) }
                if p.y > size.height * 0.75 && abs(p.x - x1) < 5 { return (.right, r) }
                if p.x >= x0, p.x <= x1 { return (.gain, r) }
            }
        }
        return (.empty, nil)
    }
    private func cursor(for handle: Handle) -> NSCursor {
        switch handle {
        case .gain: return .resizeUpDown
        case .fadeIn, .fadeOut, .left, .right: return .resizeLeftRight
        case .empty: return .iBeam
        }
    }

    // MARK: Dragging
    private func dragChanged(_ value: DragGesture.Value, _ size: CGSize) {
        if value.startLocation.y <= rulerHeight { onSeek(t(value.location.x, size.width)); return }   // scrub on the ruler
        if handle == nil {
            let (h, r) = hit(value.startLocation, size)
            handle = h; original = r; draft = r
            if let r { onSelect(r.id) }
        }
        let moved = hypot(value.translation.width, value.translation.height) > 3
        guard moved, let h = handle else { return }
        let now = t(value.location.x, size.width)
        guard var r = original else { if h == .empty { newRange = (t(value.startLocation.x, size.width), now) }; return }
        switch h {
        case .empty: return
        case .gain:
            // Up is louder. 0.25 dB per point; hold Shift for fine 0.05 dB steps.
            let step = NSEvent.modifierFlags.contains(.shift) ? 0.05 : 0.25
            r.gain = r.gain - Double(value.translation.height) * step
        case .fadeIn: r.fadeIn = now - r.start
        case .fadeOut: r.fadeOut = r.end - now
        case .left: r.start = min(now, r.end - GainRegion.minimumLength)
        case .right: r.end = max(now, r.start + GainRegion.minimumLength)
        }
        draft = r.normalized(duration: duration)
    }
    private func dragEnded(_ value: DragGesture.Value, _ size: CGSize) {
        defer { handle = nil; original = nil; draft = nil; newRange = nil }
        if value.startLocation.y <= rulerHeight { return }
        let moved = hypot(value.translation.width, value.translation.height) > 3
        switch handle {
        case .empty?:
            if moved, let range = newRange, abs(range.1 - range.0) >= GainRegion.minimumLength { onCreate(range.0, range.1) }
            else { onSelect(nil); onSeek(t(value.location.x, size.width)) }
        default:
            if moved, let draft, draft != original { onChange(draft) }
            else if !moved { onSeek(t(value.location.x, size.width)) }
        }
    }

    // MARK: Drawing
    private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        let w = size.width, h = size.height, top = rulerHeight, middle = top + (h - top) / 2
        let list = shown, active = ClipGain.active(list)

        // dB grid with labels (matches the fader scale).
        for db in [12.0, 6.0, 0.0, -6.0, -12.0] {
            let y = lineY(db, h)
            var line = Path(); line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: w, y: y))
            context.stroke(line, with: .color(.white.opacity(db == 0 ? 0.10 : 0.04)), style: StrokeStyle(lineWidth: 1, dash: db == 0 ? [] : [2, 4]))
            context.draw(Text(db == 0 ? "0" : (db > 0 ? "+\(Int(db))" : "−\(Int(-db))")).font(.system(size: 9, weight: .medium)).monospacedDigit().foregroundColor(Theme.muted.opacity(0.8)),
                         at: CGPoint(x: 4, y: y - 6), anchor: .leading)
        }

        // Sections behind the waveform.
        for r in list where r.end > viewStart && r.start < viewStart + length {
            let rect = CGRect(x: x(r.start, w), y: top, width: max(2, x(r.end, w) - x(r.start, w)), height: h - top)
            let isSelected = r.id == selected, tint = r.isReference ? Theme.lime : Theme.teal
            context.fill(Path(rect), with: .color(tint.opacity(isSelected ? 0.12 : 0.05)))
            var edges = Path(); edges.move(to: CGPoint(x: rect.minX, y: top)); edges.addLine(to: CGPoint(x: rect.minX, y: h))
            edges.move(to: CGPoint(x: rect.maxX, y: top)); edges.addLine(to: CGPoint(x: rect.maxX, y: h))
            context.stroke(edges, with: .color(tint.opacity(isSelected ? 0.75 : 0.3)), lineWidth: 1)
        }
        if let range = newRange {
            let a = x(min(range.0, range.1), w), b = x(max(range.0, range.1), w)
            context.fill(Path(CGRect(x: a, y: top, width: b - a, height: h - top)), with: .color(Theme.teal.opacity(0.16)))
            context.draw(Text(String(format: "%.2f s", abs(range.1 - range.0))).font(.system(size: 10.5, weight: .semibold)).monospacedDigit().foregroundColor(Theme.teal),
                         at: CGPoint(x: (a + b) / 2, y: top + 10))
        }

        // Waveform, one column per point: the original faintly where edited, the edited result on top.
        if !peaks.isEmpty, duration > 0 {
            let n = Double(peaks.count), columns = max(1, Int(w)), half = (h - top) / 2 - 4
            var before = Path(), after = Path()
            for c in 0..<columns {
                let t0 = viewStart + Double(c) / Double(columns) * length, t1 = viewStart + Double(c + 1) / Double(columns) * length
                let i0 = max(0, min(peaks.count - 1, Int(t0 / duration * n))), i1 = max(i0 + 1, min(peaks.count, Int((t1 / duration * n).rounded(.up))))
                var peak: Float = 0
                for i in i0..<i1 where peaks[i] > peak { peak = peaks[i] }
                let m = active.isEmpty ? 1 : ClipGain.multiplier(at: (t0 + t1) / 2, regions: active)
                let base = max(0.5, min(1, pow(Double(peak), 0.6)) * half)
                let edited = max(0.5, min(1, pow(Double(peak) * m, 0.6)) * half)
                if m != 1 { before.addRect(CGRect(x: Double(c), y: middle - base, width: 1, height: base * 2)) }
                after.addRect(CGRect(x: Double(c), y: middle - edited, width: 0.8, height: edited * 2))
            }
            context.fill(before, with: .color(Theme.muted.opacity(0.25)))
            context.fill(after, with: .linearGradient(Gradient(colors: [Theme.teal.opacity(0.95), Theme.teal.opacity(0.55), Theme.teal.opacity(0.95)]),
                                                      startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: h)))
        }

        // Level lines with fades, grips, handles and values (always shown).
        for r in list where r.end > viewStart && r.start < viewStart + length {
            let isSelected = r.id == selected
            let a = x(r.start, w), b = x(r.end, w), fi = x(r.start + r.fadeIn, w), fo = x(r.end - r.fadeOut, w), y = lineY(r.gain, h), zero = lineY(0, h)
            var line = Path()
            line.move(to: CGPoint(x: a, y: zero)); line.addLine(to: CGPoint(x: fi, y: y)); line.addLine(to: CGPoint(x: fo, y: y)); line.addLine(to: CGPoint(x: b, y: zero))
            context.stroke(line, with: .color(isSelected ? Theme.bone : Theme.bone.opacity(0.65)), style: StrokeStyle(lineWidth: isSelected ? 2.5 : 1.5, lineJoin: .round))
            for hx in [fi, fo] {
                context.fill(Path(roundedRect: CGRect(x: hx - 4.5, y: top + 4, width: 9, height: 9), cornerRadius: 2), with: .color(isSelected ? Theme.amber : Theme.amber.opacity(0.55)))
                var guide = Path(); guide.move(to: CGPoint(x: hx, y: top + 13)); guide.addLine(to: CGPoint(x: hx, y: y))
                context.stroke(guide, with: .color(Theme.amber.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            let centre = max(a + 30, min(b - 30, (max(fi, 0) + min(fo, w)) / 2))
            let value = (r.isReference ? "★ " : (r.isAuto == true ? "auto " : "")) + signed(r.gain) + " dB"
            let pill = CGRect(x: centre - (r.isAuto == true ? 42 : 32), y: y - 9, width: r.isAuto == true ? 84 : 64, height: 18)
            context.fill(Path(roundedRect: pill, cornerRadius: 5), with: .color(isSelected ? Theme.bone : Theme.raised))
            context.stroke(Path(roundedRect: pill, cornerRadius: 5), with: .color(r.isReference ? Theme.lime : Theme.bone.opacity(0.5)), lineWidth: 1)
            context.draw(Text(value).font(.system(size: 10.5, weight: .bold)).monospacedDigit().foregroundColor(isSelected ? Theme.base : Theme.bone), at: CGPoint(x: centre, y: y))
        }

        // Big readout while dragging a level.
        if handle == .gain, let d = draft {
            let cx = min(w - 60, max(60, (x(d.start, w) + x(d.end, w)) / 2))
            let bubble = CGRect(x: cx - 56, y: top + 22, width: 112, height: 34)
            context.fill(Path(roundedRect: bubble, cornerRadius: 10), with: .color(d.gain >= 0 ? Theme.teal : Theme.amber))
            context.draw(Text(signed(d.gain) + " dB").font(.system(size: 19, weight: .bold)).monospacedDigit().foregroundColor(Theme.base), at: CGPoint(x: cx, y: bubble.midY))
        }

        // Ruler.
        context.fill(Path(CGRect(x: 0, y: 0, width: w, height: top)), with: .color(Theme.panel))
        let step = Self.tickStep(for: length, width: w)
        var tick = (viewStart / step).rounded(.down) * step
        while tick <= viewStart + length {
            let tx = x(tick, w)
            var mark = Path(); mark.move(to: CGPoint(x: tx, y: top - 6)); mark.addLine(to: CGPoint(x: tx, y: top))
            context.stroke(mark, with: .color(Theme.muted.opacity(0.7)), lineWidth: 1)
            context.draw(Text(Self.tickLabel(tick, step: step)).font(.system(size: 9.5)).monospacedDigit().foregroundColor(Theme.muted), at: CGPoint(x: tx + 3, y: 8), anchor: .leading)
            tick += step
        }
        var rule = Path(); rule.move(to: CGPoint(x: 0, y: top)); rule.addLine(to: CGPoint(x: w, y: top))
        context.stroke(rule, with: .color(Theme.line), lineWidth: 1)

        let px = x(position, w)
        if px >= 0 && px <= w {
            var cursor = Path(); cursor.move(to: CGPoint(x: px, y: 0)); cursor.addLine(to: CGPoint(x: px, y: h))
            context.stroke(cursor, with: .color(Theme.bone), lineWidth: 1)
        }
    }

    static func tickStep(for length: Double, width: CGFloat) -> Double {
        let target = length / Double(max(1, width / 90))
        for s in [0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600] where s >= target { return s }
        return 1200
    }
    static func tickLabel(_ t: Double, step: Double) -> String {
        let total = max(0, t), m = Int(total) / 60, s = total - Double(m * 60)
        if step >= 1 { return String(format: "%d:%02d", m, Int(s.rounded())) }
        return String(format: step >= 0.1 ? "%d:%04.1f" : "%d:%05.2f", m, s)
    }
}

// MARK: - Fader

/// A console-style fader for the selected section: drag the cap, double-click it to return to 0 dB.
struct GainFader: View {
    let value: Double?
    @Binding var draft: Double?
    let commit: (Double) -> Void
    @State private var startValue: Double?

    var body: some View {
        VStack(spacing: 6) {
            Text(value.map { signed(draft ?? $0) } ?? "—").font(.system(size: 13, weight: .bold)).monospacedDigit()
                .foregroundStyle(value == nil ? Theme.muted : Theme.bone).frame(width: 62).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
            GeometryReader { geometry in
                let h = geometry.size.height
                let current = draft ?? value ?? 0
                let y = CGFloat((dbRange - current) / (dbRange * 2)) * h
                ZStack(alignment: .topLeading) {
                    // Scale
                    ForEach([24.0, 12.0, 6.0, 0.0, -6.0, -12.0, -24.0], id: \.self) { db in
                        let ty = CGFloat((dbRange - db) / (dbRange * 2)) * h
                        HStack(spacing: 2) {
                            Text(db == 0 ? "0" : (db > 0 ? "+\(Int(db))" : "−\(Int(-db))")).font(.system(size: 8.5)).monospacedDigit().foregroundStyle(Theme.muted).frame(width: 20, alignment: .trailing)
                            Rectangle().fill(Theme.muted.opacity(db == 0 ? 0.8 : 0.4)).frame(width: db == 0 ? 10 : 6, height: 1)
                            Spacer(minLength: 0)
                        }.offset(y: ty - 5)
                    }
                    // Track
                    RoundedRectangle(cornerRadius: 2).fill(Theme.base).frame(width: 4, height: h).offset(x: 36)
                    // Cap
                    RoundedRectangle(cornerRadius: 4)
                        .fill(LinearGradient(colors: [Theme.bone, Theme.bone.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                        .overlay(Rectangle().fill(Theme.base).frame(height: 2))
                        .frame(width: 26, height: 16).offset(x: 25, y: y - 8)
                        .opacity(value == nil ? 0.3 : 1)
                }
                .frame(width: 62, height: h)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard let value else { return }
                        if startValue == nil { startValue = value }
                        let step = NSEvent.modifierFlags.contains(.shift) ? 0.2 : 1.0
                        let raw = startValue! - Double(g.translation.height / h) * dbRange * 2 * step
                        draft = (min(dbRange, max(-dbRange, raw)) * 10).rounded() / 10
                    }
                    .onEnded { _ in
                        if let draft { commit(draft) }
                        draft = nil; startValue = nil
                    })
                .simultaneousGesture(TapGesture(count: 2).onEnded { if value != nil { commit(0) } })
                .onHover { inside in (inside && value != nil ? NSCursor.resizeUpDown : NSCursor.arrow).set() }
            }
            .frame(height: ClipGainLane.height - 36)
        }
        .frame(width: 62)
        .help(value == nil ? "Select a section to use the fader" : "Drag to set the section's level (Shift for fine). Double-click for 0 dB.")
    }
}

// MARK: - Overview

/// The whole cue with the visible part outlined; click or drag to move the view.
struct OverviewStrip: View {
    let peaks: [Float]
    let duration: Double
    let viewStart: Double
    let viewLength: Double
    let regions: [GainRegion]
    let position: Double
    let moveTo: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            Canvas { context, size in
                let h = size.height, mid = h / 2
                guard duration > 0 else { return }
                for r in regions {
                    let rect = CGRect(x: r.start / duration * w, y: 0, width: max(1, r.length / duration * w), height: h)
                    context.fill(Path(rect), with: .color((r.isReference ? Theme.lime : Theme.teal).opacity(0.25)))
                }
                if !peaks.isEmpty {
                    var wave = Path(); let step = w / Double(peaks.count)
                    for (i, p) in peaks.enumerated() {
                        let ph = max(0.5, min(1, pow(Double(p), 0.6)) * (mid - 1))
                        wave.addRect(CGRect(x: Double(i) * step, y: mid - ph, width: max(0.5, step), height: ph * 2))
                    }
                    context.fill(wave, with: .color(Theme.muted.opacity(0.55)))
                }
                let window = CGRect(x: viewStart / duration * w, y: 0.5, width: max(3, viewLength / duration * w), height: h - 1)
                context.fill(Path(roundedRect: window, cornerRadius: 3), with: .color(Theme.bone.opacity(0.08)))
                context.stroke(Path(roundedRect: window, cornerRadius: 3), with: .color(Theme.bone.opacity(0.7)), lineWidth: 1)
                var cursor = Path(); cursor.move(to: CGPoint(x: position / duration * w, y: 0)); cursor.addLine(to: CGPoint(x: position / duration * w, y: h))
                context.stroke(cursor, with: .color(Theme.bone.opacity(0.8)), lineWidth: 1)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in moveTo(Double(g.location.x / max(1, w)) * duration) })
        }
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.field))
        .help("Whole cue. Click or drag to move the zoomed view.")
    }
}

// MARK: - Trackpad and mouse wheel

/// Receives scroll and pinch over the editor without taking clicks: Option/⌘-scroll or pinch zooms, scroll pans when zoomed.
struct ScrollZoomCatcher: NSViewRepresentable {
    var onScroll: (CGFloat, CGFloat, NSEvent.ModifierFlags, CGFloat) -> Bool
    var onMagnify: (CGFloat, CGFloat) -> Void
    func makeNSView(context: Context) -> CatcherView { let v = CatcherView(); v.onScroll = onScroll; v.onMagnify = onMagnify; return v }
    func updateNSView(_ view: CatcherView, context: Context) { view.onScroll = onScroll; view.onMagnify = onMagnify }

    final class CatcherView: NSView {
        var onScroll: ((CGFloat, CGFloat, NSEvent.ModifierFlags, CGFloat) -> Bool)?
        var onMagnify: ((CGFloat, CGFloat) -> Void)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let p = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return event }
                let fx = self.bounds.width > 0 ? p.x / self.bounds.width : 0.5
                if event.type == .magnify { self.onMagnify?(event.magnification, fx); return nil }
                let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
                return self.onScroll?(event.scrollingDeltaX * scale, event.scrollingDeltaY * scale, event.modifierFlags, fx) == true ? nil : event
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
