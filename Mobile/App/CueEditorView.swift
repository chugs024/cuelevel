import SwiftUI
import AVFoundation
import UIKit

// CueLevel Pro's editor, laid out like a pro audio app: a transport bar, the cue's waveform drawn sharp at every zoom
// (each channel in its own lane), a lane showing where there's speech and where there's music, and a fader with a
// meter. One finger edits: drag a stretch up or down to change its level, drag its edges, or drag sideways on an empty
// part to mark a new stretch. Two fingers scroll, pinch zooms. Everything plays live; Save & level makes the copy.

struct CueEditorView: View {
    @EnvironmentObject var store: CueStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: EditorModel
    @StateObject private var player = EditorPlayer()
    @StateObject private var waves = WaveformStore()
    @State private var content: [ContentSegment]?
    @State private var contentFailed = false
    @State private var splitChannels = true
    /// Waveform height (×1 to ×16), for quiet cues; it changes only the drawing.
    @State private var heightZoom: CGFloat = 1
    @State private var confirmCancel = false
    @State private var loop = false
    private let automatic: EditDraft
    private let source: URL
    private let title: String
    private let detailLine: String
    private let fold: Bool

    init(store: CueStore, cue: MobileCue) {
        let analysis = cue.analysis!
        automatic = store.automaticDraft(cue)
        source = store.originalURL(cue)
        title = cue.name
        fold = store.settings.foldsSurround
        let ch = analysis.info.channels
        detailLine = [clock(analysis.info.duration), ch == 1 ? "mono" : ch == 2 ? "stereo" : "\(ch) channels",
                      analysis.info.sampleRate.map { String(format: "%g kHz", Double($0) / 1000) } ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        _model = StateObject(wrappedValue: EditorModel(cueID: cue.id, analysis: analysis, data: store.evenOutData(cue.id),
                                                       target: store.settings.target, ceiling: store.settings.peak, draft: store.currentDraft(cue)))
        _content = State(initialValue: store.contentSegments(cue.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().overlay(Theme.line)
            HStack(spacing: 0) {
                VStack(spacing: 8) {
                    TimelineTrack(model: model, player: player, waves: waves, content: content, contentFailed: contentFailed, split: splitChannels, heightZoom: heightZoom)
                    OverviewStrip(model: model, player: player).frame(height: 30)
                    toolStrip
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                Divider().overlay(Theme.line)
                FaderColumn(model: model, player: player)
                    .frame(width: 200)
            }
        }
        .background(Theme.base.ignoresSafeArea())
        .tint(Theme.good)
        .preferredColorScheme(.dark)
        .confirmationDialog("Discard your changes?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { close() }
        }
        .onAppear { Orientation.landscape(true) }
        .onDisappear { player.stop(); Orientation.landscape(false) }
        .task {
            await player.load(source, duration: model.duration)
            pushToPlayer()
        }
        .task {
            await waves.load(source, foldSurround: fold, duration: model.duration)
            #if targetEnvironment(simulator)
            // Build-server screenshots: a deep zoom (a few milliseconds) to check the sample-level drawing.
            if ProcessInfo.processInfo.arguments.contains("-editZoom"), let peaks = model.data?.peaks, let i = peaks.indices.max(by: { peaks[$0] < peaks[$1] }) {
                let t = Double(i) / Double(peaks.count) * model.duration
                model.window = max(0, t - 0.002) ... t + 0.002
            }
            #endif
        }
        .task {
            guard content == nil else { return }
            if let found = await ContentLanes.analyze(source) { content = found; store.saveContentSegments(model.cueID, found) } else { contentFailed = true }
        }
        .onChange(of: model.draft) { pushToPlayer() }
        .onChange(of: model.prediction) { pushToPlayer() }
        .onChange(of: loop) { player.loopRange = loop ? model.window : nil }
        .onChange(of: model.window) { if loop { player.loopRange = model.window } }
    }

    private func close() { player.stop(); dismiss() }

    private func pushToPlayer() {
        let regions = ClipGain.active(model.draft.regions), edit = model.draft.edit, duration = model.duration
        var points: [Double] = [edit.inPoint, edit.end(duration: duration), edit.inPoint + edit.fadeIn, edit.end(duration: duration) - edit.fadeOut]
        for r in regions { points += [r.start, r.start + r.fadeIn, r.end - r.fadeOut, r.end] }
        player.update(envelope: { ClipGain.envelope(at: $0, regions: regions, edit: edit, duration: duration) }, breakpoints: points, gain: model.gain)
    }

    // MARK: Top bar
    var topBar: some View {
        HStack(spacing: 14) {
            Button("Cancel") { if model.changed { confirmCancel = true } else { close() } }
                .font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.bone).lineLimit(1)
                Text(detailLine).font(.system(size: 11.5)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            .frame(minWidth: 70, maxWidth: 220, alignment: .leading).layoutPriority(-1)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                iconButton("backward.end.fill", "Go to start") { player.seek(model.draft.edit.inPoint) }
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.base).frame(width: 38, height: 38).background(Circle().fill(Theme.bone))
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play").keyboardShortcut(.space, modifiers: [])
                Text(clockTenths(player.time)).font(.system(size: 17, weight: .medium).monospacedDigit()).foregroundStyle(Theme.bone)
                    .frame(width: 84, alignment: .leading).padding(.leading, 6)
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                toggleButton("repeat", "Loop what's on screen", on: loop) { loop.toggle() }
                Button { player.bypass.toggle() } label: {
                    Text("Bypass").font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize()
                        .foregroundStyle(player.bypass ? Theme.base : Theme.text)
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 7).fill(player.bypass ? Theme.changed : Theme.raised))
                }
                .accessibilityHint("Plays the original without your edits")
                iconButton("arrow.uturn.backward", "Undo") { model.undo() }.disabled(model.undoStack.isEmpty).keyboardShortcut("z", modifiers: .command)
                iconButton("arrow.uturn.forward", "Redo") { model.redo() }.disabled(model.redoStack.isEmpty).keyboardShortcut("z", modifiers: [.command, .shift])
                Menu {
                    Button("Back to CueLevel's automatic plan") { model.resetToAutomatic(automatic) }
                    Button("Remove every section", role: .destructive) { model.checkpoint(); model.draft.regions = []; model.selection = nil }
                        .disabled(model.draft.regions.isEmpty)
                } label: { Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text).frame(width: 34, height: 30) }
                    .accessibilityLabel("More")
            }
            Button { player.stop(); store.saveEdits(model.cueID, model.draft); dismiss() } label: {
                Text("Save & level").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.onGood)
                    .padding(.horizontal, 14).frame(height: 32).background(RoundedRectangle(cornerRadius: 8).fill(Theme.good))
            }
        }
        .padding(.horizontal, 14).frame(height: 54)
        .background(Theme.panel.ignoresSafeArea(edges: .top))
    }
    func iconButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).frame(width: 34, height: 30) }
            .foregroundStyle(Theme.text).accessibilityLabel(label)
    }
    func toggleButton(_ symbol: String, _ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(on ? Theme.base : Theme.text)
                .frame(width: 34, height: 30).background(RoundedRectangle(cornerRadius: 7).fill(on ? Theme.good : Theme.raised))
        }
        .accessibilityLabel(label).accessibilityValue(on ? "On" : "Off")
    }

    // MARK: Tools
    var toolStrip: some View {
        HStack(spacing: 10) {
            if let r = model.selected {
                Text("\(clockTenths(r.start))–\(clockTenths(r.end))").font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.muted)
                stepper(r)
                Button { model.checkpoint(); model.update(r.id) { $0.muted = $0.muted == true ? nil : true } } label: {
                    Text(r.muted == true ? "Unmute" : "Mute").font(.system(size: 13, weight: .medium))
                }.buttonStyle(ToolButton())
                Button(role: .destructive) { model.deleteSelected() } label: { Image(systemName: "trash").font(.system(size: 13, weight: .medium)) }
                    .buttonStyle(ToolButton()).accessibilityLabel("Delete section")
            } else {
                Button { model.addSection(at: player.time > 0 ? player.time : (model.window.lowerBound + model.window.upperBound) / 2) } label: {
                    Label("Section at playhead", systemImage: "plus").font(.system(size: 13, weight: .medium))
                }.buttonStyle(ToolButton())
                Text("Drag sideways to mark a stretch, then drag it up or down")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.dim).lineLimit(1).minimumScaleFactor(0.75)
            }
            Spacer(minLength: 6)
            HStack(spacing: 0) {
                Button { heightZoom = max(1, heightZoom / 2) } label: { Image(systemName: "minus").frame(width: 28, height: 30) }.disabled(heightZoom <= 1)
                    .accessibilityLabel("Lower waveform height")
                Image(systemName: "arrow.up.and.down").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.muted)
                    .overlay(alignment: .bottomTrailing) { if heightZoom > 1 { Text("×\(Int(heightZoom))").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.changed).offset(x: 10, y: 6) } }
                Button { heightZoom = min(16, heightZoom * 2) } label: { Image(systemName: "plus").frame(width: 28, height: 30) }.disabled(heightZoom >= 16)
                    .accessibilityLabel("Raise waveform height")
            }
            .font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.text)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.raised))
            if model.analysis.info.channels > 1 {
                Button { splitChannels.toggle() } label: {
                    Label(splitChannels ? "Channels" : "Combined", systemImage: splitChannels ? "rectangle.split.1x2" : "rectangle").font(.system(size: 13, weight: .medium))
                }.buttonStyle(ToolButton()).accessibilityHint("Shows each channel in its own lane, or one combined waveform")
            }
            Button { model.showAll() } label: { Image(systemName: "arrow.left.and.right").font(.system(size: 13, weight: .semibold)) }
                .buttonStyle(ToolButton()).accessibilityLabel("Show the whole cue")
        }
        .frame(height: 32)
    }
    func stepper(_ r: GainRegion) -> some View {
        HStack(spacing: 0) {
            Button { step(r, -0.5) } label: { Image(systemName: "minus").frame(width: 30, height: 30) }.accessibilityLabel("Down half a dB")
            Text(r.muted == true ? "Muted" : dbText(r.gain) + " dB").font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.changed).frame(width: 74)
            Button { step(r, 0.5) } label: { Image(systemName: "plus").frame(width: 30, height: 30) }.accessibilityLabel("Up half a dB")
        }
        .font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.text)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.raised))
    }
    func step(_ r: GainRegion, _ d: Double) {
        model.checkpoint(); model.update(r.id) { $0.muted = nil; $0.gain = min(24, max(-24, $0.gain + d)) }
    }
}

struct ToolButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(Theme.text)
            .padding(.horizontal, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.raised.opacity(configuration.isPressed ? 0.6 : 1)))
            .opacity(enabled ? 1 : 0.4)
    }
}

func clockTenths(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "00:00.0" }
    let s = max(0, seconds); let m = Int(s / 60)
    return String(format: "%02d:%04.1f", m, s - Double(m) * 60)
}

// MARK: Timeline

/// The waveform lanes with the sections, trims and fades drawn over them, the ruler, the speech/music lane, and the
/// touch handling for all of it.
struct TimelineTrack: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var player: EditorPlayer
    @ObservedObject var waves: WaveformStore
    let content: [ContentSegment]?
    let contentFailed: Bool
    let split: Bool
    var heightZoom: CGFloat = 1
    @Environment(\.displayScale) private var displayScale

    enum Target { case inPoint, outPoint, fadeIn, fadeOut, start(UUID), end(UUID), gain(UUID), create(UUID) }
    @State private var target: Target?
    @State private var startValue = 0.0
    @State private var anchor = 0.0
    @State private var readout: (String, CGPoint)?
    @State private var zoomStart: ClosedRange<Double>?
    @State private var hoverX: CGFloat?
    private let haptic = UISelectionFeedbackGenerator()

    static let ruler: CGFloat = 20
    static let contentLane: CGFloat = 26
    static let gainSpan = 24.0

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            let lanesTop = Self.ruler, lanesH = H - Self.ruler - Self.contentLane
            ZStack(alignment: .topLeading) {
                canvas(W, H, lanesTop, lanesH)
                TimelineGestures(
                    onTap: { tap($0, W, lanesTop, lanesH) },
                    onEdit: { state, start, moved in edit(state, start, moved, W, lanesTop, lanesH) },
                    onScroll: { dx, _ in model.scroll(to: model.window.lowerBound - Double(dx / W) * span) },
                    onZoom: { scale, at, state in
                        if state == .began { zoomStart = model.window }
                        guard let z = zoomStart else { return }
                        let centre = z.lowerBound + Double(at.x / W) * (z.upperBound - z.lowerBound)
                        model.window = z
                        model.zoom(by: scale, around: centre)
                        if state == .ended || state == .cancelled { zoomStart = nil }
                    },
                    onHover: { hoverX = $0?.x })
                if let shown = readout {
                    let text = shown.0, at = shown.1
                    Text(text).font(.system(size: 13, weight: .bold).monospacedDigit()).foregroundStyle(Theme.base)
                        .padding(.horizontal, 9).padding(.vertical, 5).background(Capsule().fill(Theme.changed))
                        .position(x: min(max(44, at.x), W - 44), y: max(16, at.y - 34))
                        .allowsHitTesting(false)
                }
            }
            .onAppear { requestDetail(W) }
            .onChange(of: model.window) { requestDetail(W) }
            .onChange(of: waves.ready) { requestDetail(W) }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Waveform")
        .accessibilityValue(model.selected.map { "Section selected, \(dbText($0.gain)) dB" } ?? "\(model.draft.regions.count) sections")
    }

    private var span: Double { model.window.upperBound - model.window.lowerBound }
    func x(_ t: Double, _ W: CGFloat) -> CGFloat { CGFloat((t - model.window.lowerBound) / max(0.0001, span)) * W }
    func t(_ x: CGFloat, _ W: CGFloat) -> Double { model.window.lowerBound + Double(x / max(1, W)) * span }
    func y(_ gain: Double, _ top: CGFloat, _ h: CGFloat) -> CGFloat { top + h / 2 - CGFloat(gain / Self.gainSpan) * (h / 2 - 12) }
    private func requestDetail(_ W: CGFloat) { waves.need(window: model.window, pixels: Int(W * min(displayScale, 2))) }

    // MARK: Touch
    func tap(_ p: CGPoint, _ W: CGFloat, _ top: CGFloat, _ h: CGFloat) {
        let time = t(p.x, W)
        if p.y > top, let hit = model.draft.regions.filter({ $0.start <= time && time <= $0.end }).min(by: { $0.length < $1.length }) {
            model.selection = model.selection == hit.id ? nil : hit.id
        } else {
            model.selection = nil
            player.seek(max(0, min(model.duration, time)))
        }
    }

    func hitTest(_ p: CGPoint, _ W: CGFloat, _ top: CGFloat) -> Target {
        let e = model.draft.edit, d = model.duration
        let inX = x(e.inPoint, W), outX = x(e.end(duration: d), W)
        if p.y < top + 26 {
            if abs(p.x - x(e.inPoint + e.fadeIn, W)) < 18 { return .fadeIn }
            if abs(p.x - x(e.end(duration: d) - e.fadeOut, W)) < 18 { return .fadeOut }
        }
        if abs(p.x - inX) < 14 { return .inPoint }
        if abs(p.x - outX) < 14 { return .outPoint }
        let sections = model.draft.regions.sorted { a, _ in a.id == model.selection }
        for r in sections {
            if abs(p.x - x(r.start, W)) < 12 { return .start(r.id) }
            if abs(p.x - x(r.end, W)) < 12 { return .end(r.id) }
        }
        let time = t(p.x, W)
        if let hit = model.draft.regions.filter({ $0.start <= time && time <= $0.end }).min(by: { $0.length < $1.length }) { return .gain(hit.id) }
        return .create(UUID())
    }

    func edit(_ state: UIGestureRecognizer.State, _ start: CGPoint, _ moved: CGSize, _ W: CGFloat, _ top: CGFloat, _ h: CGFloat) {
        let secondsPerPoint = span / Double(max(1, W))
        let dbPerPoint = Self.gainSpan / Double(max(1, h / 2 - 12))
        let d = model.duration
        switch state {
        case .began:
            let hit = hitTest(start, W, top)
            target = hit
            model.checkpoint()
            haptic.prepare()
            switch hit {
            case .inPoint: startValue = model.draft.edit.inPoint
            case .outPoint: startValue = model.draft.edit.end(duration: d)
            case .fadeIn: startValue = model.draft.edit.fadeIn
            case .fadeOut: startValue = model.draft.edit.fadeOut
            case .start(let id): startValue = model.draft.regions.first { $0.id == id }?.start ?? 0; model.selection = id
            case .end(let id): startValue = model.draft.regions.first { $0.id == id }?.end ?? 0; model.selection = id
            case .gain(let id):
                let r = model.draft.regions.first { $0.id == id }
                startValue = r?.muted == true ? -24 : (r?.gain ?? 0); model.selection = id
            case .create(let id):
                anchor = max(0, min(d, t(start.x, W)))
                var r = GainRegion(start: anchor, end: min(d, anchor + 0.1), gain: 0, fadeIn: 0.03, fadeOut: 0.03)
                r.id = id
                model.draft.regions.append(r); model.selection = id
            }
            fallthrough
        case .changed:
            guard let target else { return }
            let here = CGPoint(x: start.x + moved.width, y: start.y + moved.height)
            switch target {
            case .inPoint:
                let end = model.draft.edit.end(duration: d)
                model.draft.edit.inPoint = max(0, min(end - 0.2, startValue + Double(moved.width) * secondsPerPoint))
                model.draft.edit.fadeIn = min(model.draft.edit.fadeIn, end - model.draft.edit.inPoint)
                readout = ("In " + clockTenths(model.draft.edit.inPoint), here)
            case .outPoint:
                let v = max(model.draft.edit.inPoint + 0.2, min(d, startValue + Double(moved.width) * secondsPerPoint))
                model.draft.edit.outPoint = v >= d - 0.0005 ? nil : v
                model.draft.edit.fadeOut = min(model.draft.edit.fadeOut, v - model.draft.edit.inPoint)
                readout = ("Out " + clockTenths(v), here)
            case .fadeIn:
                let room = model.draft.edit.end(duration: d) - model.draft.edit.inPoint - model.draft.edit.fadeOut
                model.draft.edit.fadeIn = max(0, min(room, startValue + Double(moved.width) * secondsPerPoint))
                readout = (String(format: "Fade in %.2f s", model.draft.edit.fadeIn), here)
            case .fadeOut:
                let room = model.draft.edit.end(duration: d) - model.draft.edit.inPoint - model.draft.edit.fadeIn
                model.draft.edit.fadeOut = max(0, min(room, startValue - Double(moved.width) * secondsPerPoint))
                readout = (String(format: "Fade out %.2f s", model.draft.edit.fadeOut), here)
            case .start(let id):
                model.update(id) { $0.start = max(0, min($0.end - GainRegion.minimumLength, startValue + Double(moved.width) * secondsPerPoint)) }
                readout = (clockTenths(model.draft.regions.first { $0.id == id }?.start ?? 0), here)
            case .end(let id):
                model.update(id) { $0.end = min(d, max($0.start + GainRegion.minimumLength, startValue + Double(moved.width) * secondsPerPoint)) }
                readout = (clockTenths(model.draft.regions.first { $0.id == id }?.end ?? 0), here)
            case .gain(let id):
                let raw = startValue - Double(moved.height) * dbPerPoint
                var g = (raw * 2).rounded() / 2
                g = min(GainRegion.gainRange.upperBound, max(GainRegion.gainRange.lowerBound, g))
                let old = model.draft.regions.first { $0.id == id }?.gain ?? 0
                if (old < 0) != (g < 0) || (old == 0) != (g == 0) { haptic.selectionChanged() }
                model.update(id) { $0.muted = nil; $0.gain = g }
                readout = (dbText(g) + " dB", here)
            case .create(let id):
                let b = max(0, min(d, t(here.x, W)))
                model.update(id) { $0.start = min(anchor, b); $0.end = max(anchor, b, min(anchor, b) + 0.1) }
                readout = (String(format: "%.1f s", abs(b - anchor)), here)
            }
        case .ended:
            if case .create(let id) = target, let r = model.draft.regions.first(where: { $0.id == id }), r.length < 0.25 {
                model.undo(); model.selection = nil   // too short to be a stretch: it was a tap
            }
            target = nil; readout = nil
        default:
            if target != nil { model.undo() }   // a second finger took over: put things back
            target = nil; readout = nil
        }
    }

    // MARK: Drawing
    func canvas(_ W: CGFloat, _ H: CGFloat, _ lanesTop: CGFloat, _ lanesH: CGFloat) -> some View {
        let draft = model.draft, window = model.window, duration = model.duration
        let selection = model.selection, playhead = player.time
        let regions = ClipGain.active(draft.regions)
        let lanes = waves.lanes, ready = waves.ready, rate = waves.rate
        let scale = min(displayScale, 2)
        let hover = hoverX
        let speech = content.map { ContentLanes.stretches($0, music: false) } ?? []
        let music = content.map { ContentLanes.stretches($0, music: true) } ?? []
        let contentReady = content != nil, failed = contentFailed
        let hz = heightZoom
        return Canvas { g, size in
            let span = window.upperBound - window.lowerBound
            func px(_ t: Double) -> CGFloat { CGFloat((t - window.lowerBound) / max(0.0001, span)) * W }
            // Ruler.
            g.fill(Path(CGRect(x: 0, y: 0, width: W, height: Self.ruler)), with: .color(Theme.panel))
            let step = [0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600].first { Double(W) / (span / $0) >= 76 } ?? 600
            var tick = (window.lowerBound / step).rounded(.up) * step
            while tick <= window.upperBound + 0.0001 {
                let xx = px(tick)
                g.fill(Path(CGRect(x: xx, y: Self.ruler - 6, width: 1, height: 6)), with: .color(Theme.line2))
                g.fill(Path(CGRect(x: xx, y: lanesTop, width: 0.5, height: lanesH)), with: .color(Theme.line.opacity(0.55)))
                let label = step < 0.01 ? String(format: "%.4f", tick) : step < 0.1 ? String(format: "%.2f", tick) : (step < 1 ? clockTenths(tick) : clock(tick))
                g.draw(Text(label).font(.system(size: 10).monospacedDigit()).foregroundColor(Theme.dim), at: CGPoint(x: xx + 3, y: 3), anchor: .topLeading)
                tick += step
            }
            // Sections behind the waveform.
            for r in draft.regions {
                let x0 = px(r.start), x1 = px(r.end)
                guard x1 >= 0, x0 <= W else { continue }
                let selected = r.id == selection
                g.fill(Path(CGRect(x: x0, y: lanesTop, width: max(1, x1 - x0), height: lanesH)), with: .color(Theme.changed.opacity(selected ? 0.16 : 0.07)))
            }
            // Waveform lanes.
            let laneCount = split ? max(1, lanes.count) : 1
            let laneH = lanesH / CGFloat(laneCount)
            if !ready || lanes.isEmpty {
                g.draw(Text("Reading the waveform…").font(.system(size: 13)).foregroundColor(Theme.muted), at: CGPoint(x: W / 2, y: lanesTop + lanesH / 2))
            } else {
                let columns = Int(W * scale)
                let colW = 1 / scale
                // Gain of the edits per column (shared by every lane).
                var env = [CGFloat](repeating: 1, count: columns)
                var edited = false
                for c in 0 ..< columns {
                    let tm = window.lowerBound + (Double(c) + 0.5) / Double(columns) * span
                    let v = CGFloat(ClipGain.envelope(at: tm, regions: regions, edit: draft.edit, duration: duration))
                    env[c] = v; if abs(v - 1) > 0.001 { edited = true }
                }
                for lane in 0 ..< laneCount {
                    let top = lanesTop + CGFloat(lane) * laneH, mid = top + laneH / 2, half = laneH / 2 - 3
                    g.fill(Path(CGRect(x: 0, y: mid - 0.25, width: W, height: 0.5)), with: .color(Theme.line))
                    let channels = split ? [lane] : Array(lanes.indices)
                    let samplesPerColumn = span * rate / Double(columns)
                    if samplesPerColumn < 1.2 {
                        // Deep zoom: the samples themselves, as a line with a dot on each sample.
                        let a = max(0, Int(window.lowerBound * rate) - 1), b = Int(window.upperBound * rate) + 2
                        for ch in channels {
                            guard let s = waves.samples(ch, from: a, to: min(b, waves.frames)) else { continue }
                            var line = Path(), dots = Path()
                            for (k, v) in s.enumerated() {
                                let tm = Double(a + k) / rate
                                let xx = px(tm), gain = CGFloat(ClipGain.envelope(at: tm, regions: regions, edit: draft.edit, duration: duration))
                                let yy = mid - max(-1, min(1, CGFloat(v) * gain * hz)) * half
                                if k == 0 { line.move(to: CGPoint(x: xx, y: yy)) } else { line.addLine(to: CGPoint(x: xx, y: yy)) }
                                if samplesPerColumn < 0.12 { dots.addEllipse(in: CGRect(x: xx - 1.6, y: yy - 1.6, width: 3.2, height: 3.2)) }
                            }
                            g.stroke(line, with: .color(Theme.bone), lineWidth: 1.2)
                            g.fill(dots, with: .color(Theme.bone))
                        }
                    } else {
                        var peak = Path(), body = Path(), ghost = Path()
                        for c in 0 ..< columns {
                            let t0 = window.lowerBound + Double(c) / Double(columns) * span, t1 = window.lowerBound + Double(c + 1) / Double(columns) * span
                            let a = Int(t0 * rate), b = max(Int(t1 * rate), a + 1)
                            guard a < waves.frames else { break }
                            var lo: Float = 0, hi: Float = 0, rms: Float = 0
                            var any = false
                            for ch in channels {
                                guard let col = waves.column(ch, from: a, to: min(b, waves.frames)) else { continue }
                                if !any { lo = col.lo; hi = col.hi; rms = col.rms; any = true } else { lo = min(lo, col.lo); hi = max(hi, col.hi); rms = max(rms, col.rms) }
                            }
                            guard any else { continue }
                            let xx = CGFloat(c) * colW, e = env[c]
                            let k = e * hz
                            let yHi = mid - min(1, CGFloat(hi) * k) * half, yLo = mid - max(-1, CGFloat(lo) * k) * half
                            peak.addRect(CGRect(x: xx, y: yHi, width: colW, height: max(colW, yLo - yHi)))
                            let r = min(1, CGFloat(rms) * k) * half
                            body.addRect(CGRect(x: xx, y: mid - r, width: colW, height: max(colW, 2 * r)))
                            if edited, abs(e - 1) > 0.001 {
                                ghost.addRect(CGRect(x: xx, y: mid - min(1, CGFloat(hi) * hz) * half, width: colW, height: colW))
                                ghost.addRect(CGRect(x: xx, y: mid - max(-1, CGFloat(lo) * hz) * half, width: colW, height: colW))
                            }
                        }
                        g.fill(peak, with: .color(Theme.bone.opacity(0.62)))
                        g.fill(body, with: .color(Theme.bone.opacity(0.95)))
                        g.fill(ghost, with: .color(Theme.muted.opacity(0.75)))
                    }
                    if split && lanes.indices.contains(lane) {
                        g.draw(Text(lanes[lane].name).font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.muted), at: CGPoint(x: 6, y: top + 4), anchor: .topLeading)
                    }
                    if lane > 0 { g.fill(Path(CGRect(x: 0, y: top, width: W, height: 1)), with: .color(Theme.line)) }
                }
            }
            // Trimmed-off ends.
            let inX = px(draft.edit.inPoint), outX = px(draft.edit.end(duration: duration))
            if inX > 0 { g.fill(Path(CGRect(x: 0, y: lanesTop, width: inX, height: lanesH)), with: .color(Color.black.opacity(0.6))) }
            if outX < W { g.fill(Path(CGRect(x: outX, y: lanesTop, width: W - outX, height: lanesH)), with: .color(Color.black.opacity(0.6))) }
            for (xx, label) in [(inX, "In"), (outX, "Out")] where xx >= -2 && xx <= W + 2 {
                g.fill(Path(CGRect(x: xx - 1, y: lanesTop, width: 2, height: lanesH)), with: .color(Theme.quiet))
                g.fill(Path(roundedRect: CGRect(x: label == "In" ? xx : xx - 26, y: lanesTop, width: 26, height: 15), cornerRadius: 3), with: .color(Theme.quiet))
                g.draw(Text(label).font(.system(size: 9.5, weight: .bold)).foregroundColor(Theme.base), at: CGPoint(x: label == "In" ? xx + 13 : xx - 13, y: lanesTop + 7.5))
            }
            // Edge fades: the fade curve and a handle at its end.
            let fiX = px(draft.edit.inPoint + draft.edit.fadeIn), foX = px(draft.edit.end(duration: duration) - draft.edit.fadeOut)
            if draft.edit.fadeIn > 0.001 {
                var p = Path(); p.move(to: CGPoint(x: inX, y: lanesTop + lanesH)); p.addQuadCurve(to: CGPoint(x: fiX, y: lanesTop + 18), control: CGPoint(x: inX, y: lanesTop + 18))
                g.stroke(p, with: .color(Theme.quiet), lineWidth: 1.5)
            }
            if draft.edit.fadeOut > 0.001 {
                var p = Path(); p.move(to: CGPoint(x: foX, y: lanesTop + 18)); p.addQuadCurve(to: CGPoint(x: outX, y: lanesTop + lanesH), control: CGPoint(x: outX, y: lanesTop + 18))
                g.stroke(p, with: .color(Theme.quiet), lineWidth: 1.5)
            }
            for xx in [fiX, foX] where xx >= -6 && xx <= W + 6 {
                let cy = lanesTop + 18
                var d = Path()
                d.move(to: CGPoint(x: xx, y: cy - 6)); d.addLine(to: CGPoint(x: xx + 6, y: cy)); d.addLine(to: CGPoint(x: xx, y: cy + 6)); d.addLine(to: CGPoint(x: xx - 6, y: cy)); d.closeSubpath()
                g.fill(d, with: .color(Theme.quiet))
            }
            // Section gain lines over every lane, with their fades, and a label.
            for r in draft.regions {
                let x0 = px(r.start), x1 = px(r.end)
                guard x1 >= 0, x0 <= W else { continue }
                let selected = r.id == selection
                let zero = y(0, lanesTop, lanesH), yy = r.muted == true ? lanesTop + lanesH - 4 : y(r.gain, lanesTop, lanesH)
                // The 0 dB guide across the section, the ramps (its fades) faintly, and the level line itself.
                var guide = Path(); guide.move(to: CGPoint(x: x0, y: zero)); guide.addLine(to: CGPoint(x: x1, y: zero))
                g.stroke(guide, with: .color(Theme.changed.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                let fx0 = px(r.start + r.fadeIn), fx1 = px(r.end - r.fadeOut)
                var ramps = Path()
                ramps.move(to: CGPoint(x: x0, y: zero)); ramps.addLine(to: CGPoint(x: fx0, y: yy))
                ramps.move(to: CGPoint(x: fx1, y: yy)); ramps.addLine(to: CGPoint(x: x1, y: zero))
                g.stroke(ramps, with: .color(Theme.changed.opacity(0.4)), lineWidth: 1)
                var line = Path(); line.move(to: CGPoint(x: fx0, y: yy)); line.addLine(to: CGPoint(x: fx1, y: yy))
                g.stroke(line, with: .color(Theme.changed), style: StrokeStyle(lineWidth: selected ? 2.6 : 1.8, lineCap: .round))
                if selected {
                    for edge in [x0, x1] { g.fill(Path(roundedRect: CGRect(x: edge - 2.5, y: lanesTop + lanesH / 2 - 18, width: 5, height: 36), cornerRadius: 2.5), with: .color(Theme.changed)) }
                    let cx = min(max(x0, 0), W) + (min(x1, W) - min(max(x0, 0), W)) / 2
                    g.fill(Path(ellipseIn: CGRect(x: cx - 7, y: yy - 7, width: 14, height: 14)), with: .color(Theme.changed))
                    g.stroke(Path(ellipseIn: CGRect(x: cx - 7, y: yy - 7, width: 14, height: 14)), with: .color(Theme.base), lineWidth: 2)
                }
                if x1 - x0 > 52 {
                    let text = r.muted == true ? "Muted" : dbText(r.gain) + " dB"
                    let lx = max(x0, 0) + 6
                    g.fill(Path(roundedRect: CGRect(x: lx - 4, y: lanesTop + 3, width: 58, height: 17), cornerRadius: 4), with: .color(Theme.base.opacity(0.75)))
                    g.draw(Text(text).font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundColor(Theme.changed), at: CGPoint(x: lx, y: lanesTop + 4.5), anchor: .topLeading)
                }
            }
            // Speech and music lane.
            let cTop = lanesTop + lanesH
            g.fill(Path(CGRect(x: 0, y: cTop, width: W, height: Self.contentLane)), with: .color(Theme.panel))
            g.fill(Path(CGRect(x: 0, y: cTop, width: W, height: 1)), with: .color(Theme.line))
            if contentReady && speech.isEmpty && music.isEmpty {
                g.draw(Text("No speech or music recognised in this cue").font(.system(size: 10.5)).foregroundColor(Theme.dim), at: CGPoint(x: 8, y: cTop + Self.contentLane / 2), anchor: .leading)
            } else if contentReady {
                for (row, list, label) in [(0, speech, "Speech"), (1, music, "Music")] {
                    let yy = cTop + 4 + CGFloat(row) * 11
                    for s in list {
                        let a = px(s.lowerBound), b = px(s.upperBound)
                        guard b >= 0, a <= W else { continue }
                        g.fill(Path(roundedRect: CGRect(x: max(a, 46), y: yy + 1, width: max(2, b - max(a, 46)), height: 7), cornerRadius: 3.5),
                               with: .color(row == 0 ? Theme.bone.opacity(0.85) : Theme.muted.opacity(0.7)))
                    }
                    g.draw(Text(label).font(.system(size: 9.5, weight: .semibold)).foregroundColor(Theme.dim), at: CGPoint(x: 6, y: yy + 4.5), anchor: .leading)
                }
            } else {
                g.draw(Text(failed ? "Speech and music can't be found in this file" : "Finding speech and music…").font(.system(size: 10.5)).foregroundColor(Theme.dim),
                       at: CGPoint(x: 8, y: cTop + Self.contentLane / 2), anchor: .leading)
            }
            // Hover position (pointer on iPad and Mac) and the playhead.
            if let hover { g.fill(Path(CGRect(x: hover - 0.5, y: 0, width: 1, height: H)), with: .color(Theme.bone.opacity(0.25))) }
            let ph = px(playhead)
            if ph >= -1 && ph <= W + 1 {
                g.fill(Path(CGRect(x: ph - 0.75, y: 0, width: 1.5, height: H)), with: .color(Theme.bone))
                var cap = Path(); cap.move(to: CGPoint(x: ph - 6, y: 0)); cap.addLine(to: CGPoint(x: ph + 6, y: 0)); cap.addLine(to: CGPoint(x: ph, y: 8)); cap.closeSubpath()
                g.fill(cap, with: .color(Theme.bone))
            }
        }
    }
}

// MARK: Overview

/// The whole cue in a strip, with the part shown above outlined and the sections marked. Drag to move along the cue.
struct OverviewStrip: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var player: EditorPlayer
    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            let d = max(0.001, model.duration)
            Canvas { g, _ in
                let peaks = model.analysis.waveform
                if !peaks.isEmpty {
                    var p = Path()
                    for c in stride(from: 0, to: Int(W), by: 1) {
                        let i0 = Int(Double(c) / Double(W) * Double(peaks.count)), i1 = max(i0 + 1, Int(Double(c + 1) / Double(W) * Double(peaks.count)))
                        let v = peaks[min(peaks.count - 1, i0) ..< min(peaks.count, i1)].max() ?? 0
                        let a = CGFloat(min(1, v)) * (H / 2 - 3)
                        p.addRect(CGRect(x: CGFloat(c), y: H / 2 - a, width: 1, height: max(0.5, 2 * a)))
                    }
                    g.fill(p, with: .color(Theme.muted.opacity(0.55)))
                }
                for r in model.draft.regions {
                    g.fill(Path(CGRect(x: CGFloat(r.start / d) * W, y: H - 3, width: max(2, CGFloat(r.length / d) * W), height: 3)), with: .color(Theme.changed))
                }
                let x0 = CGFloat(model.window.lowerBound / d) * W, x1 = CGFloat(model.window.upperBound / d) * W
                let rect = CGRect(x: x0, y: 0.5, width: max(6, x1 - x0), height: H - 1)
                g.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(Theme.bone.opacity(0.08)))
                g.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0), cornerRadius: 4), with: .color(Theme.bone.opacity(0.8)), lineWidth: 1)
                let ph = CGFloat(player.time / d) * W
                g.fill(Path(CGRect(x: ph - 0.5, y: 0, width: 1, height: H)), with: .color(Theme.bone))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let span = model.window.upperBound - model.window.lowerBound
                model.scroll(to: Double(v.location.x / W) * d - span / 2)
            })
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Whole cue")
    }
}

// MARK: Fader column

/// The cue's level: the result in big type, a meter, a fader marked in output loudness (with the target and the
/// automatic setting), and the loudest peak.
struct FaderColumn: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var player: EditorPlayer
    static let range = -40.0 ... -6.0

    var body: some View {
        let out = model.outputLoudness, peak = model.outputPeak
        let peakColour = peak > 0 ? Theme.hot : peak > model.ceiling + 0.05 ? Theme.changed : Theme.bone
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text(lufsText(out)).font(.readout(30)).foregroundStyle(Theme.tone(levelTone(out, target: model.target))).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text("LUFS after levelling").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            HStack(alignment: .top, spacing: 0) {
                Fader(model: model, player: player)
            }
            .frame(maxHeight: .infinity)
            VStack(spacing: 3) {
                line("Peak", "≈ \(lufsText(peak)) dBTP", peakColour)
                line("Gain", "\(dbText(model.gain)) dB", Theme.bone)
            }
            if peak > 0 {
                Text("Peaks will clip. Pull the fader down.").font(.system(size: 11.5)).foregroundStyle(Theme.hot).fixedSize(horizontal: false, vertical: true)
            } else if peak > model.ceiling + 0.05 {
                Text("Over your \(lufsText(model.ceiling)) dBTP ceiling.").font(.system(size: 11.5)).foregroundStyle(Theme.changed).fixedSize(horizontal: false, vertical: true)
            }
            Button {
                model.checkpoint(); model.draft.gain = nil
            } label: {
                Text(model.draft.gain == nil ? "Automatic level" : "Back to automatic").font(.system(size: 12.5, weight: .semibold)).frame(maxWidth: .infinity)
            }
            .buttonStyle(ToolButton()).disabled(model.draft.gain == nil)
        }
        .padding(12)
        .background(Theme.panel)
    }
    func line(_ k: String, _ v: String, _ c: Color) -> some View {
        HStack { Text(k).foregroundStyle(Theme.muted); Spacer(); Text(v).foregroundStyle(c).monospacedDigit() }.font(.system(size: 12, weight: .medium))
    }
}

/// A console-style fader whose scale is the cue's loudness after levelling, with a meter beside it that follows the
/// playhead (the cue's momentary loudness with your edits and the fader).
struct Fader: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var player: EditorPlayer
    @State private var start: Double?
    var body: some View {
        GeometryReader { geo in
            let H = geo.size.height
            let range = FaderColumn.range
            let top: CGFloat = 10, bottom = H - 10
            let yFor = { (l: Double) -> CGFloat in bottom - CGFloat((min(range.upperBound, max(range.lowerBound, l)) - range.lowerBound) / (range.upperBound - range.lowerBound)) * (bottom - top) }
            let labelsX: CGFloat = 16, slotX: CGFloat = 78, meterX: CGFloat = 132
            let auto = model.prediction.loudness + model.prediction.autoGain
            let meter = meterValue
            ZStack(alignment: .topLeading) {
                ForEach([-6.0, -12, -18, -24, -30, -40], id: \.self) { mark in
                    let yy = yFor(mark)
                    Text(String(format: "%.0f", mark).replacingOccurrences(of: "-", with: "−")).font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(abs(mark - model.target) < 0.01 ? Theme.good : Theme.dim)
                        .position(x: labelsX, y: yy)
                    Rectangle().fill(abs(mark - model.target) < 0.01 ? Theme.good : Theme.line2).frame(width: 12, height: 1).position(x: slotX - 22, y: yy)
                }
                RoundedRectangle(cornerRadius: 3).fill(Theme.field).frame(width: 6, height: bottom - top).position(x: slotX, y: (top + bottom) / 2)
                Text("A").font(.system(size: 9, weight: .heavy)).foregroundStyle(Theme.onGood).frame(width: 15, height: 15)
                    .background(Circle().fill(Theme.good)).position(x: slotX + 30, y: yFor(auto)).accessibilityHidden(true)
                // Meter.
                RoundedRectangle(cornerRadius: 2).fill(Theme.field).frame(width: 8, height: bottom - top).position(x: meterX, y: (top + bottom) / 2)
                if let meter {
                    let yy = yFor(meter)
                    RoundedRectangle(cornerRadius: 2).fill(Theme.tone(levelTone(meter, target: model.target)))
                        .frame(width: 8, height: max(2, bottom - yy)).position(x: meterX, y: yy + (bottom - yy) / 2)
                }
                // Cap.
                RoundedRectangle(cornerRadius: 5).fill(LinearGradient(colors: [Color(hex: 0x5A6069), Color(hex: 0x30353B)], startPoint: .top, endPoint: .bottom))
                    .overlay(Rectangle().fill(Theme.bone).frame(height: 2))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.black.opacity(0.6), lineWidth: 1))
                    .frame(width: 44, height: 26)
                    .position(x: slotX, y: yFor(model.outputLoudness))
                    .shadow(color: .black.opacity(0.45), radius: 3, y: 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                if start == nil { start = model.outputLoudness; model.checkpoint() }
                let perPoint = (range.upperBound - range.lowerBound) / Double(bottom - top)
                var wanted = (start ?? model.outputLoudness) - Double(v.translation.height) * perPoint
                wanted = min(range.upperBound, max(range.lowerBound, (wanted * 10).rounded() / 10))
                if abs(wanted - auto) < 0.25 { model.draft.gain = nil } else { model.draft.gain = wanted - model.prediction.loudness }
            }.onEnded { _ in start = nil })
        }
        .accessibilityElement()
        .accessibilityLabel("Fader")
        .accessibilityValue("\(lufsText(model.outputLoudness)) LUFS")
        .accessibilityAdjustableAction { dir in
            model.checkpoint()
            model.draft.gain = model.gain + (dir == .increment ? 0.5 : -0.5)
        }
    }
    /// Momentary loudness at the playhead, after the edits and the fader (from the readings taken when measuring).
    var meterValue: Double? {
        guard player.isPlaying, let m = model.data?.momentary, !m.isEmpty else { return nil }
        let i = min(m.count - 1, max(0, Int(player.time * 10)))
        let env = ClipGain.envelope(at: player.time, regions: ClipGain.active(model.draft.regions), edit: model.draft.edit, duration: model.duration)
        guard env > 0, m[i] > -69 else { return -40 }
        return Double(m[i]) + 20 * log10(env) + model.gain
    }
}
