import SwiftUI
import AVFoundation

// CueLevel Pro's editor: the cue's waveform with its sections (clip gain), trims and fades, and a fader for the cue's
// level. Pinch to zoom, drag the waveform to move along it. Tap a section to select it, then drag its line up or down
// for its gain and its edges to resize it. Everything plays live; Level saves the edits and makes the levelled copy.

struct CueEditorView: View {
    @EnvironmentObject var store: CueStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @StateObject private var model: EditorModel
    @StateObject private var player = EditorPlayer()
    @State private var confirmCancel = false
    @State private var loop = false
    private let automatic: EditDraft
    private let source: URL

    init(store: CueStore, cue: MobileCue) {
        let analysis = cue.analysis!
        automatic = store.automaticDraft(cue)
        source = store.originalURL(cue)
        _model = StateObject(wrappedValue: EditorModel(cueID: cue.id, analysis: analysis, data: store.evenOutData(cue.id),
                                                       target: store.settings.target, ceiling: store.settings.peak, draft: store.currentDraft(cue)))
    }

    var body: some View {
        NavigationStack {
            Group {
                if sizeClass == .regular {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(spacing: 12) { editingColumn }
                        FaderPanel(model: model, vertical: true).frame(width: 220)
                    }
                    .padding(16)
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            editingColumn
                            FaderPanel(model: model, vertical: false)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                    }
                }
            }
            .background(Theme.base.ignoresSafeArea())
            .navigationTitle("Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { if model.changed { confirmCancel = true } else { close() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { player.stop(); store.saveEdits(model.cueID, model.draft); dismiss() } label: { Text("Level").fontWeight(.semibold) }
                }
            }
            .confirmationDialog("Discard your changes?", isPresented: $confirmCancel, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { close() }
            }
            .task {
                await player.load(source, duration: model.duration)
                pushToPlayer()
            }
            .onChange(of: model.draft) { pushToPlayer() }
            .onChange(of: model.prediction) { pushToPlayer() }
            .onChange(of: loop) { player.loopRange = loop ? model.window : nil }
            .onChange(of: model.window) { if loop { player.loopRange = model.window } }
            .onDisappear { player.stop() }
        }
        .tint(Theme.good)
        .preferredColorScheme(.dark)
    }

    private func close() { player.stop(); dismiss() }

    private func pushToPlayer() {
        let regions = ClipGain.active(model.draft.regions), edit = model.draft.edit, duration = model.duration
        var points: [Double] = [edit.inPoint, edit.end(duration: duration), edit.inPoint + edit.fadeIn, edit.end(duration: duration) - edit.fadeOut]
        for r in regions { points += [r.start, r.start + r.fadeIn, r.end - r.fadeOut, r.end] }
        player.update(envelope: { ClipGain.envelope(at: $0, regions: regions, edit: edit, duration: duration) }, breakpoints: points, gain: model.gain)
    }

    @ViewBuilder var editingColumn: some View {
        transport
        TimelineTrack(model: model, player: player)
            .frame(height: sizeClass == .regular ? 300 : 230)
        OverviewStrip(model: model, player: player).frame(height: 40)
        tools
        if let r = model.selected { SectionInspector(model: model, region: r) }
    }

    var transport: some View {
        HStack(spacing: 12) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.base).frame(width: 42, height: 42).background(Circle().fill(Theme.bone))
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            .keyboardShortcut(.space, modifiers: [])
            VStack(alignment: .leading, spacing: 1) {
                Text("\(clockTenths(player.time)) / \(clock(model.duration))").font(.system(size: 14).monospacedDigit()).foregroundStyle(Theme.text)
                Text(player.bypass ? "Original, untouched" : (player.headroom > 0.05 ? "With your edits · preview \(dbText(-player.headroom)) dB" : "With your edits"))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            Toggle(isOn: $loop) { Image(systemName: "repeat") }.toggleStyle(.button).accessibilityLabel("Loop what's on screen")
            Toggle(isOn: $player.bypass) { Text("Bypass").font(.system(size: 14, weight: .medium)) }.toggleStyle(.button)
                .accessibilityHint("Plays the original without your edits")
        }
    }

    var tools: some View {
        HStack(spacing: 8) {
            Button { model.addSection(at: player.time > 0 ? player.time : (model.window.lowerBound + model.window.upperBound) / 2) } label: {
                Label("Section", systemImage: "plus")
            }.buttonStyle(CLButton(kind: .secondary))
            Spacer(minLength: 0)
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.buttonStyle(CLButton(kind: .ghost))
                .disabled(model.undoStack.isEmpty).accessibilityLabel("Undo").keyboardShortcut("z", modifiers: .command)
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }.buttonStyle(CLButton(kind: .ghost))
                .disabled(model.redoStack.isEmpty).accessibilityLabel("Redo").keyboardShortcut("z", modifiers: [.command, .shift])
            Button { model.showAll() } label: { Image(systemName: "arrow.left.and.right.square") }.buttonStyle(CLButton(kind: .ghost))
                .accessibilityLabel("Show the whole cue")
            Menu {
                Button("Back to CueLevel's automatic plan") { model.resetToAutomatic(automatic) }
                Button("Remove every section", role: .destructive) { model.checkpoint(); model.draft.regions = []; model.selection = nil }
                    .disabled(model.draft.regions.isEmpty)
            } label: { Image(systemName: "ellipsis.circle").font(.system(size: 18)) }
                .accessibilityLabel("More")
        }
    }
}

func clockTenths(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "00:00.0" }
    let s = max(0, seconds); let m = Int(s / 60)
    return String(format: "%02d:%04.1f", m, s - Double(m) * 60)
}

// MARK: Timeline

/// The cue's waveform with sections, trims and fades, and the handles to change them.
struct TimelineTrack: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var player: EditorPlayer
    @State private var panStart: Double?
    @State private var zoomStart: ClosedRange<Double>?
    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            ZStack(alignment: .topLeading) {
                canvas(W, H)
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { v in tap(at: v.location.x, W) })
                    .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { v in
                        let span = model.window.upperBound - model.window.lowerBound
                        if panStart == nil { panStart = model.window.lowerBound }
                        model.scroll(to: panStart! - Double(v.translation.width / W) * span)
                    }.onEnded { _ in panStart = nil })
                    .simultaneousGesture(MagnifyGesture().onChanged { v in
                        if zoomStart == nil { zoomStart = model.window }
                        guard let z = zoomStart else { return }
                        let centre = z.lowerBound + Double(v.startLocation.x / W) * (z.upperBound - z.lowerBound)
                        model.window = z
                        model.zoom(by: v.magnification, around: centre)
                    }.onEnded { _ in zoomStart = nil })
                handles(W, H)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Waveform")
    }

    // Coordinates
    func x(_ t: Double, _ W: CGFloat) -> CGFloat {
        let span = model.window.upperBound - model.window.lowerBound
        return CGFloat((t - model.window.lowerBound) / max(0.001, span)) * W
    }
    func t(_ x: CGFloat, _ W: CGFloat) -> Double {
        model.window.lowerBound + Double(x / max(1, W)) * (model.window.upperBound - model.window.lowerBound)
    }
    static let gainSpan = 24.0
    func y(_ gain: Double, _ H: CGFloat) -> CGFloat { H / 2 - CGFloat(gain / Self.gainSpan) * (H / 2 - 16) }

    func tap(at px: CGFloat, _ W: CGFloat) {
        let time = t(px, W)
        if let hit = model.draft.regions.filter({ $0.start <= time && time <= $0.end }).min(by: { $0.length < $1.length }) {
            model.selection = model.selection == hit.id ? nil : hit.id
        } else {
            model.selection = nil
            player.seek(time)
        }
    }

    func canvas(_ W: CGFloat, _ H: CGFloat) -> some View {
        let draft = model.draft, window = model.window, duration = model.duration
        let peaks = model.data?.peaks ?? model.analysis.waveform
        let selection = model.selection, playhead = player.time
        let regions = ClipGain.active(draft.regions)
        return Canvas { g, size in
            let mid = H / 2
            let span = window.upperBound - window.lowerBound
            func px(_ t: Double) -> CGFloat { CGFloat((t - window.lowerBound) / max(0.001, span)) * W }
            // Time ruler.
            let step = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600].first { Double(W) / (span / $0) >= 70 } ?? 600
            var tick = (window.lowerBound / step).rounded(.up) * step
            while tick <= window.upperBound {
                let xx = px(tick)
                g.fill(Path(CGRect(x: xx, y: 0, width: 1, height: 6)), with: .color(Theme.line2))
                let label = step < 1 ? clockTenths(tick) : clock(tick)
                g.draw(Text(label).font(.system(size: 9.5).monospacedDigit()).foregroundColor(Theme.dim), at: CGPoint(x: xx + 3, y: 4), anchor: .topLeading)
                tick += step
            }
            // 0 dB line for the section gain scale.
            g.fill(Path(CGRect(x: 0, y: mid - 0.25, width: W, height: 0.5)), with: .color(Theme.line))
            // Sections behind the wave.
            for r in draft.regions {
                let x0 = px(r.start), x1 = px(r.end)
                guard x1 >= 0, x0 <= W else { continue }
                let selected = r.id == selection
                g.fill(Path(CGRect(x: x0, y: 0, width: max(1, x1 - x0), height: H)), with: .color(Theme.changed.opacity(selected ? 0.18 : 0.08)))
                for edge in [x0, x1] { g.fill(Path(CGRect(x: edge - 0.5, y: 0, width: 1, height: H)), with: .color(Theme.changed.opacity(selected ? 0.9 : 0.45))) }
            }
            // Waveform: the original faintly, and the edited sound on top.
            if !peaks.isEmpty, duration > 0 {
                let rate = Double(peaks.count) / duration
                let columns = Int(W)
                var original = Path(), edited = Path()
                for c in stride(from: 0, to: columns, by: 1) {
                    let t0 = window.lowerBound + Double(c) / Double(W) * span, t1 = window.lowerBound + Double(c + 1) / Double(W) * span
                    let i0 = max(0, Int(t0 * rate)), i1 = min(peaks.count, max(i0 + 1, Int(t1 * rate)))
                    guard i0 < peaks.count else { break }
                    var p: Float = 0
                    for i in i0 ..< i1 where peaks[i] > p { p = peaks[i] }
                    let a = CGFloat(min(1, p)) * (mid - 4)
                    let env = CGFloat(ClipGain.envelope(at: (t0 + t1) / 2, regions: regions, edit: draft.edit, duration: duration))
                    let e = min(mid - 2, a * env)
                    original.addRect(CGRect(x: CGFloat(c), y: mid - a, width: 1, height: max(0.5, 2 * a)))
                    edited.addRect(CGRect(x: CGFloat(c), y: mid - e, width: 1, height: max(0.5, 2 * e)))
                }
                g.fill(original, with: .color(Theme.bone.opacity(0.16)))
                g.fill(edited, with: .color(Theme.bone.opacity(0.82)))
            }
            // Trimmed-off ends.
            let inX = px(draft.edit.inPoint), outX = px(draft.edit.end(duration: duration))
            if inX > 0 { g.fill(Path(CGRect(x: 0, y: 0, width: inX, height: H)), with: .color(Color.black.opacity(0.55))) }
            if outX < W { g.fill(Path(CGRect(x: outX, y: 0, width: W - outX, height: H)), with: .color(Color.black.opacity(0.55))) }
            // Edge fades.
            if draft.edit.fadeIn > 0 {
                var p = Path(); p.move(to: CGPoint(x: inX, y: H)); p.addLine(to: CGPoint(x: px(draft.edit.inPoint + draft.edit.fadeIn), y: 8))
                g.stroke(p, with: .color(Theme.quiet), lineWidth: 1.5)
            }
            if draft.edit.fadeOut > 0 {
                var p = Path(); p.move(to: CGPoint(x: px(draft.edit.end(duration: duration) - draft.edit.fadeOut), y: 8)); p.addLine(to: CGPoint(x: outX, y: H))
                g.stroke(p, with: .color(Theme.quiet), lineWidth: 1.5)
            }
            // Section gain lines, with their fades.
            for r in draft.regions {
                let x0 = px(r.start), x1 = px(r.end)
                guard x1 >= 0, x0 <= W else { continue }
                let yy = r.muted == true ? H - 6 : y(r.gain, H)
                var line = Path()
                line.move(to: CGPoint(x: x0, y: mid)); line.addLine(to: CGPoint(x: px(r.start + r.fadeIn), y: yy))
                line.addLine(to: CGPoint(x: px(r.end - r.fadeOut), y: yy)); line.addLine(to: CGPoint(x: x1, y: mid))
                g.stroke(line, with: .color(Theme.changed), style: StrokeStyle(lineWidth: r.id == selection ? 2.2 : 1.4, lineJoin: .round))
                if x1 - x0 > 46 {
                    let label = r.muted == true ? "Muted" : dbText(r.gain) + " dB"
                    g.draw(Text(label).font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundColor(Theme.changed),
                           at: CGPoint(x: max(x0, 0) + 5, y: r.gain >= 0 ? yy + 5 : yy - 5), anchor: r.gain >= 0 ? .topLeading : .bottomLeading)
                }
            }
            // Playhead.
            let ph = px(playhead)
            if ph >= 0 && ph <= W { g.fill(Path(CGRect(x: ph - 0.75, y: 0, width: 1.5, height: H)), with: .color(Theme.bone)) }
        }
    }

    // MARK: Handles
    @ViewBuilder func handles(_ W: CGFloat, _ H: CGFloat) -> some View {
        let duration = model.duration
        // In and out points.
        trimHandle(x: x(model.draft.edit.inPoint, W), H: H, label: "In point") { dx in
            let start = dragStart ?? model.draft.edit.inPoint
            if dragStart == nil { dragStart = start; model.checkpoint() }
            let end = model.draft.edit.end(duration: duration)
            model.draft.edit.inPoint = max(0, min(end - 0.2, start + Double(dx / W) * span))
            model.draft.edit.fadeIn = min(model.draft.edit.fadeIn, end - model.draft.edit.inPoint)
        }
        trimHandle(x: x(model.draft.edit.end(duration: duration), W), H: H, label: "Out point") { dx in
            let start = dragStart ?? model.draft.edit.end(duration: duration)
            if dragStart == nil { dragStart = start; model.checkpoint() }
            let v = max(model.draft.edit.inPoint + 0.2, min(duration, start + Double(dx / W) * span))
            model.draft.edit.outPoint = v >= duration - 0.0005 ? nil : v
            model.draft.edit.fadeOut = min(model.draft.edit.fadeOut, v - model.draft.edit.inPoint)
        }
        // Fade lengths.
        fadeKnob(x: x(model.draft.edit.inPoint + model.draft.edit.fadeIn, W), label: "Fade in") { dx in
            let start = dragStart ?? model.draft.edit.fadeIn
            if dragStart == nil { dragStart = start; model.checkpoint() }
            let room = model.draft.edit.end(duration: duration) - model.draft.edit.inPoint - model.draft.edit.fadeOut
            model.draft.edit.fadeIn = max(0, min(room, start + Double(dx / W) * span))
        }
        fadeKnob(x: x(model.draft.edit.end(duration: duration) - model.draft.edit.fadeOut, W), label: "Fade out") { dx in
            let start = dragStart ?? model.draft.edit.fadeOut
            if dragStart == nil { dragStart = start; model.checkpoint() }
            let room = model.draft.edit.end(duration: duration) - model.draft.edit.inPoint - model.draft.edit.fadeIn
            model.draft.edit.fadeOut = max(0, min(room, start - Double(dx / W) * span))
        }
        // The selected section: its gain and its edges.
        if let r = model.selected {
            let x0 = x(r.start, W), x1 = x(r.end, W)
            edgeHandle(x: x0, H: H, label: "Section start") { dx in
                let start = dragStart ?? r.start
                if dragStart == nil { dragStart = start; model.checkpoint() }
                model.update(r.id) { $0.start = max(0, min($0.end - GainRegion.minimumLength, start + Double(dx / W) * span)) }
            }
            edgeHandle(x: x1, H: H, label: "Section end") { dx in
                let start = dragStart ?? r.end
                if dragStart == nil { dragStart = start; model.checkpoint() }
                model.update(r.id) { $0.end = min(duration, max($0.start + GainRegion.minimumLength, start + Double(dx / W) * span)) }
            }
            gainKnob(x: min(max(16, (max(0, x0) + min(W, x1)) / 2), W - 16), y: r.muted == true ? H - 6 : y(r.gain, H), region: r, H: H)
        }
    }
    private var span: Double { model.window.upperBound - model.window.lowerBound }

    func trimHandle(x: CGFloat, H: CGFloat, label: String, onDrag: @escaping (CGFloat) -> Void) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(Theme.quiet).frame(width: 4, height: H)
            .overlay(RoundedRectangle(cornerRadius: 3).fill(Theme.quiet).frame(width: 14, height: 30))
            .frame(width: 34, height: H).contentShape(Rectangle())
            .position(x: x, y: H / 2)
            .highPriorityGesture(DragGesture(minimumDistance: 0).onChanged { onDrag($0.translation.width) }.onEnded { _ in dragStart = nil })
            .accessibilityLabel(label)
    }
    func fadeKnob(x: CGFloat, label: String, onDrag: @escaping (CGFloat) -> Void) -> some View {
        Rectangle().fill(Theme.quiet).frame(width: 11, height: 11).rotationEffect(.degrees(45))
            .frame(width: 32, height: 32).contentShape(Rectangle())
            .position(x: x, y: 16)
            .highPriorityGesture(DragGesture(minimumDistance: 0).onChanged { onDrag($0.translation.width) }.onEnded { _ in dragStart = nil })
            .accessibilityLabel(label)
    }
    func edgeHandle(x: CGFloat, H: CGFloat, label: String, onDrag: @escaping (CGFloat) -> Void) -> some View {
        Capsule().fill(Theme.changed).frame(width: 6, height: 44)
            .frame(width: 30, height: H).contentShape(Rectangle())
            .position(x: x, y: H / 2)
            .highPriorityGesture(DragGesture(minimumDistance: 0).onChanged { onDrag($0.translation.width) }.onEnded { _ in dragStart = nil })
            .accessibilityLabel(label)
    }
    func gainKnob(x: CGFloat, y: CGFloat, region r: GainRegion, H: CGFloat) -> some View {
        Circle().fill(Theme.changed).frame(width: 18, height: 18).overlay(Circle().stroke(Theme.base, lineWidth: 2))
            .frame(width: 44, height: 44).contentShape(Rectangle())
            .position(x: x, y: y)
            .highPriorityGesture(DragGesture(minimumDistance: 0).onChanged { v in
                let start = dragStart ?? r.gain
                if dragStart == nil { dragStart = start; model.checkpoint() }
                let raw = start - Double(v.translation.height / (H / 2 - 16)) * Self.gainSpan
                let snapped = (raw * 2).rounded() / 2
                model.update(r.id) { $0.muted = nil; $0.gain = min(GainRegion.gainRange.upperBound, max(GainRegion.gainRange.lowerBound, abs(snapped) < 0.25 ? 0 : snapped)) }
            }.onEnded { _ in dragStart = nil })
            .accessibilityElement()
            .accessibilityLabel("Section gain").accessibilityValue("\(dbText(r.gain)) dB")
            .accessibilityAdjustableAction { dir in
                model.checkpoint()
                model.update(r.id) { $0.gain = min(24, max(-24, $0.gain + (dir == .increment ? 0.5 : -0.5))) }
            }
    }
}

/// The whole cue in a strip, with the part shown above outlined. Drag to move along the cue.
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
                    for c in 0 ..< Int(W) {
                        let i = min(peaks.count - 1, Int(Double(c) / Double(W) * Double(peaks.count)))
                        let a = CGFloat(min(1, peaks[i])) * (H / 2 - 2)
                        p.addRect(CGRect(x: CGFloat(c), y: H / 2 - a, width: 1, height: max(0.5, 2 * a)))
                    }
                    g.fill(p, with: .color(Theme.muted.opacity(0.6)))
                }
                for r in model.draft.regions {
                    g.fill(Path(CGRect(x: CGFloat(r.start / d) * W, y: H - 4, width: max(2, CGFloat(r.length / d) * W), height: 4)), with: .color(Theme.changed))
                }
                let x0 = CGFloat(model.window.lowerBound / d) * W, x1 = CGFloat(model.window.upperBound / d) * W
                g.stroke(Path(roundedRect: CGRect(x: x0 + 0.5, y: 0.5, width: max(4, x1 - x0) - 1, height: H - 1), cornerRadius: 4), with: .color(Theme.bone), lineWidth: 1.2)
                let ph = CGFloat(player.time / d) * W
                g.fill(Path(CGRect(x: ph - 0.5, y: 0, width: 1, height: H)), with: .color(Theme.bone.opacity(0.7)))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let span = model.window.upperBound - model.window.lowerBound
                model.scroll(to: Double(v.location.x / W) * d - span / 2)
            })
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Whole cue")
    }
}

/// The selected section's settings.
struct SectionInspector: View {
    @ObservedObject var model: EditorModel
    let region: GainRegion
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Section").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.bone)
                Text("\(clockTenths(region.start))–\(clockTenths(region.end))").font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 4)
            Button { step(-0.5) } label: { Image(systemName: "minus") }.buttonStyle(CLButton(kind: .secondary)).accessibilityLabel("Down half a dB")
            Text(region.muted == true ? "Muted" : dbText(region.gain) + " dB").font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.changed).frame(minWidth: 70)
            Button { step(0.5) } label: { Image(systemName: "plus") }.buttonStyle(CLButton(kind: .secondary)).accessibilityLabel("Up half a dB")
            Menu {
                Button(region.muted == true ? "Unmute" : "Mute") { model.checkpoint(); model.update(region.id) { $0.muted = $0.muted == true ? nil : true } }
                Button("Delete section", role: .destructive) { model.deleteSelected() }
            } label: { Image(systemName: "ellipsis").frame(width: 32, height: 32) }
                .accessibilityLabel("Section options")
        }
        .padding(10).background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
    }
    func step(_ d: Double) {
        model.checkpoint()
        model.update(region.id) { $0.muted = nil; $0.gain = min(24, max(-24, $0.gain + d)) }
    }
}

// MARK: Fader

/// The cue's level: a fader marked in output loudness, with the target, the automatic setting, and the loudest peak.
struct FaderPanel: View {
    @ObservedObject var model: EditorModel
    let vertical: Bool
    static let range = -40.0 ... -6.0

    var body: some View {
        let out = model.outputLoudness, peak = model.outputPeak
        let peakColour = peak > 0 ? Theme.hot : peak > model.ceiling + 0.05 ? Theme.changed : Theme.bone
        let readouts = VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text(lufsText(out)).font(.readout(34)).foregroundStyle(Theme.tone(levelTone(out, target: model.target))).monospacedDigit()
                Text("LUFS after levelling").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            VStack(alignment: .leading, spacing: 4) {
                line("Loudest peak", "≈ \(lufsText(peak)) dBTP", peakColour)
                line("Gain", "\(dbText(model.gain)) dB", Theme.bone)
                line("Target", "\(lufsText(model.target)) LUFS", Theme.muted)
            }
            if peak > 0 {
                Text("Peaks go over full scale and will clip. Pull the fader down.").font(.system(size: 12.5)).foregroundStyle(Theme.hot).fixedSize(horizontal: false, vertical: true)
            } else if peak > model.ceiling + 0.05 {
                Text("The loudest peak passes your \(lufsText(model.ceiling)) dBTP ceiling.").font(.system(size: 12.5)).foregroundStyle(Theme.changed).fixedSize(horizontal: false, vertical: true)
            }
            Button {
                model.checkpoint(); model.draft.gain = nil
            } label: {
                Label(model.draft.gain == nil ? "Automatic" : "Back to automatic", systemImage: model.draft.gain == nil ? "checkmark" : "arrow.uturn.backward")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(CLButton(kind: model.draft.gain == nil ? .ghost : .secondary)).disabled(model.draft.gain == nil)
        }
        return Group {
            if vertical {
                VStack(alignment: .leading, spacing: 16) {
                    readouts
                    Fader(model: model).frame(maxHeight: .infinity)
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    readouts.frame(maxWidth: .infinity, alignment: .leading)
                    Fader(model: model).frame(width: 96, height: 250)
                }
            }
        }
        .padding(14).background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line, lineWidth: 1))
    }
    func line(_ k: String, _ v: String, _ c: Color) -> some View {
        HStack { Text(k).foregroundStyle(Theme.muted); Spacer(); Text(v).foregroundStyle(c).monospacedDigit() }.font(.system(size: 13.5, weight: .medium))
    }
}

/// A console-style fader. Its scale is the cue's loudness after levelling, so moving it to −18 puts the cue at −18 LUFS.
struct Fader: View {
    @ObservedObject var model: EditorModel
    @State private var start: Double?
    var body: some View {
        GeometryReader { geo in
            let H = geo.size.height, W = geo.size.width
            let range = FaderPanel.range
            let top: CGFloat = 14, bottom = H - 14
            let yFor = { (l: Double) -> CGFloat in bottom - CGFloat((min(range.upperBound, max(range.lowerBound, l)) - range.lowerBound) / (range.upperBound - range.lowerBound)) * (bottom - top) }
            let slotX = W * 0.62
            let auto = model.prediction.loudness + model.prediction.autoGain
            ZStack(alignment: .topLeading) {
                // Scale.
                ForEach([-6.0, -12, -18, -24, -30, -40], id: \.self) { mark in
                    let yy = yFor(mark)
                    Text(lufsText(mark)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(abs(mark - model.target) < 0.01 ? Theme.good : Theme.dim)
                        .position(x: slotX - 30, y: yy)
                    Rectangle().fill(Theme.line2).frame(width: 10, height: 1).position(x: slotX - 12, y: yy)
                }
                // Slot, target and automatic marks.
                RoundedRectangle(cornerRadius: 3).fill(Theme.field).frame(width: 6, height: bottom - top).position(x: slotX, y: (top + bottom) / 2)
                Rectangle().fill(Theme.good).frame(width: 22, height: 2).position(x: slotX, y: yFor(model.target))
                    .accessibilityHidden(true)
                Image(systemName: "a.circle.fill").font(.system(size: 13)).foregroundStyle(Theme.good)
                    .position(x: slotX + 22, y: yFor(auto)).accessibilityHidden(true)
                // Cap.
                RoundedRectangle(cornerRadius: 5).fill(LinearGradient(colors: [Theme.line2, Theme.raised], startPoint: .top, endPoint: .bottom))
                    .overlay(Rectangle().fill(Theme.bone).frame(height: 2))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.base, lineWidth: 1))
                    .frame(width: 40, height: 26)
                    .position(x: slotX, y: yFor(model.outputLoudness))
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 2)
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
}
