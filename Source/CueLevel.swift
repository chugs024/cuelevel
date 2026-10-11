import Cocoa
import SwiftUI
import AVKit
import UniformTypeIdentifiers

// MARK: - Design system
// Colours come from the CueLevel icon: a graphite tile, bone-white marks and the teal → lime → amber meter arc.
// The meter gradient is used functionally (as a loudness scale), never as decoration.
extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}
enum Theme {
    static let base = Color(hex: 0x14181E)
    static let panel = Color(hex: 0x1A1F27)
    static let raised = Color(hex: 0x232A34)
    static let field = Color(hex: 0x12161B)
    static let line = Color(hex: 0x2B333E)
    static let line2 = Color(hex: 0x39424F)
    static let bone = Color(hex: 0xF3EFE7)
    static let text = Color(hex: 0xC7CCD4)
    static let muted = Color(hex: 0x8B94A3)
    static let dim = Color(hex: 0x5E6774)
    static let teal = Color(hex: 0x3FE0B5)
    static let lime = Color(hex: 0xC9E86A)
    static let amber = Color(hex: 0xFF9F43)
    static let coral = Color(hex: 0xFF6A3D)
    static let meterStops: [Gradient.Stop] = [.init(color: Color(hex: 0x2BB894), location: 0), .init(color: teal, location: 0.35),
                                              .init(color: lime, location: 0.68), .init(color: amber, location: 0.88), .init(color: coral, location: 1)]
    static let meter = LinearGradient(stops: meterStops, startPoint: .leading, endPoint: .trailing)
    /// Loudness scale used by every ribbon: −40 to 0 LUFS.
    static func position(_ lufs: Double) -> Double { min(1, max(0, (lufs + 40) / 40)) }
}
private let accent = Theme.teal
private let panelColor = Theme.panel

struct CLButton: ButtonStyle {
    enum Kind { case primary, secondary, ghost, danger }
    var kind = Kind.secondary
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: kind == .primary ? .semibold : .medium))
            .foregroundStyle(kind == .primary ? Theme.base : kind == .danger ? Theme.coral : Theme.bone)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(kind == .primary ? Theme.bone : kind == .ghost ? Color.clear : Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(kind == .secondary || kind == .danger ? Theme.line2 : Color.clear, lineWidth: 1))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.38)
            .contentShape(Rectangle())
    }
}
struct CLSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                configuration.label
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? Theme.teal : Theme.line2).frame(width: 30, height: 18)
                    Circle().fill(configuration.isOn ? Color(hex: 0x0F1A17) : Color(hex: 0xAAB2BF)).frame(width: 14, height: 14).padding(2)
                }.animation(.easeOut(duration: 0.15), value: configuration.isOn)
            }
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
                    Text(option.1).font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 5)
                        .foregroundStyle(selection == option.0 ? Theme.bone : Theme.muted)
                        .background(RoundedRectangle(cornerRadius: 6).fill(selection == option.0 ? Color(hex: 0x2C3440) : Color.clear))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(selection == option.0 ? .isSelected : [])
            }
        }.padding(2).background(RoundedRectangle(cornerRadius: 8).fill(Theme.field)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
    }
}
extension View {
    func card() -> some View { padding(.horizontal, 20).padding(.vertical, 16).background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line)) }
    func sectionTitle() -> some View { font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.bone) }
    func hint() -> some View { font(.system(size: 11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
}
func lufs(_ value: Double?) -> String { value.map { String(format: "%.1f", $0).replacingOccurrences(of: "-", with: "−") } ?? "—" }
func signed(_ value: Double) -> String { (value >= 0 ? "+" : "−") + String(format: "%.1f", abs(value)) }

// MARK: - Loudness ribbon (the signature element)
/// Where a cue started, where it landed and the target, on the icon's meter scale.
struct LoudnessRibbon: View {
    let source: Double
    let output: Double?
    let target: Double
    var compact = false
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let lo = Theme.position(min(source, output ?? source)) * w
            let hi = Theme.position(max(source, output ?? source)) * w
            let height: CGFloat = compact ? 6 : 14
            let trackY: CGFloat = compact ? 0 : 30
            ZStack(alignment: .topLeading) {
                Capsule().fill(Theme.meter).opacity(compact ? 0 : 0.22).frame(width: w, height: height).offset(y: trackY)
                Capsule().fill(compact ? AnyShapeStyle(Color(hex: 0x2A313C)) : AnyShapeStyle(Color.clear)).frame(width: w, height: height).offset(y: trackY)
                Theme.meter.frame(width: w, height: height).mask(Capsule().frame(width: max(height, hi - lo), height: height).offset(x: lo).frame(width: w, alignment: .leading)).offset(y: trackY)
                Rectangle().fill(Theme.bone.opacity(compact ? 0.55 : 1)).frame(width: compact ? 1.5 : 2, height: compact ? 12 : 38).offset(x: Theme.position(target) * w - 1, y: compact ? -3 : 18)
                if !compact {
                    Text("Target \(lufs(target))").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.bone).fixedSize()
                        .position(x: Theme.position(target) * w, y: 8)
                    marker(at: Theme.position(source) * w, filled: false, label: "Source \(lufs(source))")
                    if let output { marker(at: Theme.position(output) * w, filled: true, label: "Levelled \(lufs(output))") }
                }
            }
        }.frame(height: compact ? 6 : 74)
        .accessibilityElement().accessibilityLabel("Loudness: source \(lufs(source)) LUFS, levelled \(lufs(output)) LUFS, target \(lufs(target)) LUFS")
    }
    func marker(at x: CGFloat, filled: Bool, label: String) -> some View {
        ZStack {
            if filled { Circle().fill(Theme.bone).frame(width: 26, height: 26).shadow(color: Theme.bone.opacity(0.18), radius: 0, x: 0, y: 0).overlay(Circle().stroke(Theme.bone.opacity(0.14), lineWidth: 8)) }
            else { Circle().fill(Theme.base).frame(width: 26, height: 26).overlay(Circle().stroke(Color(hex: 0xAAB2BF), lineWidth: 2.5)) }
            Text(label).font(.system(size: 11.5, weight: filled ? .medium : .regular)).foregroundStyle(filled ? Theme.bone : Theme.muted).fixedSize().offset(y: 30)
        }.position(x: x, y: 37)
    }
}

// MARK: - Waveform with loudness-over-time
struct Waveform: View {
    let peaks: [Float]
    var curve: [Float] = []
    var target: Double? = nil
    let position: Double
    let duration: Double
    let seek: (Double) -> Void
    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                var grid = Path()
                for row in 1...3 { let y = size.height * Double(row) / 4; grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y)) }
                context.stroke(grid, with: .color(.white.opacity(0.05)), lineWidth: 1)
                let middle = size.height / 2
                if !peaks.isEmpty {
                    var wave = Path()
                    let step = size.width / Double(peaks.count)
                    for (index, peak) in peaks.enumerated() {
                        let height = max(1, min(1, pow(Double(peak), 0.6)) * (middle - 6))
                        wave.addRoundedRect(in: CGRect(x: Double(index) * step, y: middle - height, width: max(1, step * 0.62), height: height * 2), cornerSize: CGSize(width: 0.8, height: 0.8))
                    }
                    context.fill(wave, with: .linearGradient(Gradient(colors: [Theme.teal.opacity(0.9), Theme.teal.opacity(0.5), Theme.teal.opacity(0.9)]), startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)))
                }
                func y(_ value: Double) -> Double { size.height * (1 - (max(-60, min(0, value)) + 60) / 60) }
                if curve.count > 1 {
                    if let target {
                        var line = Path(); line.move(to: CGPoint(x: 0, y: y(target))); line.addLine(to: CGPoint(x: size.width, y: y(target)))
                        context.stroke(line, with: .color(Theme.bone.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                    // The first ~3 s have no short-term reading yet (shown as the -70 floor); start the line at the first real value.
                    let first = curve.firstIndex { $0 > -69.9 } ?? 0
                    var trace = Path()
                    for index in first..<curve.count {
                        let point = CGPoint(x: Double(index) / Double(curve.count - 1) * size.width, y: y(Double(curve[index])))
                        if index == first { trace.move(to: point) } else { trace.addLine(to: point) }
                    }
                    context.stroke(trace, with: .color(Theme.amber), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                }
                let x = duration > 0 ? min(1, max(0, position / duration)) * size.width : 0
                var cursor = Path(); cursor.move(to: CGPoint(x: x, y: 0)); cursor.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(cursor, with: .color(Theme.bone), lineWidth: 1)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in if duration > 0 { seek(min(1, max(0, value.location.x / geometry.size.width)) * duration) } })
            .overlay { if peaks.isEmpty { Text("Measure the cue to draw its waveform").hint() } }
        }.frame(height: 150)
        .accessibilityLabel("Waveform with short-term loudness. Use the playback position slider to seek.")
    }
}

// MARK: - Window
struct ContentView: View {
    @EnvironmentObject var model: Workspace
    @EnvironmentObject var updater: Updater
    @State private var hovering = false
    @State private var showProcessing = false
    @State private var showAdvanced = false
    var body: some View {
        VStack(spacing: 0) {
            topBar
            HStack(spacing: 0) {
                queue.frame(width: 320)
                Rectangle().fill(Theme.line).frame(width: 1)
                center.frame(minWidth: 560, maxWidth: .infinity)
                Rectangle().fill(Theme.line).frame(width: 1)
                inspector.frame(width: 316)
            }
            statusBar
        }
        .frame(minWidth: 1180, minHeight: 720)
        .background(Theme.base)
        .ignoresSafeArea(.container, edges: .top)
        .background(WindowChrome())
        .onAppear { DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) } }
        .foregroundStyle(Theme.bone)
        .tint(Theme.teal)
        .preferredColorScheme(.dark)
        .onDrop(of: [UTType.fileURL], isTargeted: $hovering) { providers in
            for provider in providers { _ = provider.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in model.add([url]) } } } }
            return !providers.isEmpty
        }
        .overlay { if hovering { dropOverlay } }
        .alert("CueLevel", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .sheet(isPresented: $model.showSavePreset) { presetSheet }
        .sheet(isPresented: $model.showAbout) { aboutSheet }
        .sheet(isPresented: $updater.showSheet) { updateSheet }
        .sheet(isPresented: Binding(get: { model.referenceDraft != nil }, set: { if !$0 { model.referenceDraft = nil } })) { referenceSheet }
    }
    var dropOverlay: some View {
        ZStack {
            Theme.base.opacity(0.82)
            RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.teal, style: StrokeStyle(lineWidth: 2, dash: [8, 6])).padding(18)
            VStack(spacing: 10) {
                LogoMark().frame(width: 64, height: 64)
                Text(model.quickLevel ? "Drop to level" : "Drop to add to the queue").font(.system(size: 22, weight: .semibold))
                Text(model.quickLevel ? "Levelled copies go to \(model.quickFolder?.lastPathComponent ?? "your output folder")" : "Each file is measured as soon as it arrives").hint()
            }
        }.allowsHitTesting(false)
    }

    // MARK: Top bar
    var topBar: some View {
        HStack(spacing: 10) {
            leadingBar
            Spacer(minLength: 12)
            trailingBar
        }
        .padding(.leading, 86).padding(.trailing, 16).frame(height: 52)
        .background(Theme.panel).overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
    var leadingBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 9) { LogoMark().frame(width: 22, height: 22); Text("CueLevel").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.bone) }
                .onTapGesture(count: 2) { model.showAbout = true }
            quickLevelPill.padding(.leading, 14)
            if let feed = updater.offered, updater.available != nil || updater.isWorking {
                Button { updater.showSheet = true } label: {
                    Label("CueLevel \(feed.version) is ready", systemImage: "arrow.down.circle.fill").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Theme.teal.opacity(0.14))).overlay(Capsule().stroke(Theme.teal.opacity(0.35)))
                        .foregroundStyle(Theme.teal)
                }.buttonStyle(.plain).help("See what's new and install the update")
            }
        }
    }
    var trailingBar: some View {
        HStack(spacing: 10) {
            Button { model.addFiles() } label: { Label("Add files", systemImage: "plus") }.buttonStyle(CLButton(kind: .ghost)).keyboardShortcut("o")
            Button { model.exportShowReport() } label: { Label("Show report", systemImage: "doc.text") }.buttonStyle(CLButton(kind: .ghost))
                .disabled(model.busy || model.jobs.allSatisfy { $0.analysis == nil })
            Button("Export all…") { model.exportAll() }.buttonStyle(CLButton()).disabled(model.busy || model.completedCount == 0)
            if model.busy && model.canCancel {
                Button { model.cancel() } label: { Label("Stop", systemImage: "stop.fill") }.buttonStyle(CLButton(kind: .danger)).keyboardShortcut(".")
            } else {
                Button { model.processQueue() } label: { Label(model.quickLevel ? "Level queue" : "Process queue", systemImage: "play.fill") }
                    .buttonStyle(CLButton(kind: .primary)).disabled(model.busy || model.remainingCount == 0)
            }
        }
    }
    var quickLevelPill: some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { model.quickLevel }, set: { model.setQuickLevel($0) })) { EmptyView() }.toggleStyle(CLSwitch()).disabled(model.busy)
            Text("Quick Level").font(.system(size: 13, weight: .semibold))
            Button { model.chooseQuickFolder() } label: {
                if let folder = model.quickFolder {
                    (Text("saving to ").foregroundColor(Theme.muted) + Text(folder.lastPathComponent).foregroundColor(Theme.bone.opacity(0.88))).font(.system(size: 12.5))
                } else { Text("Choose output folder").font(.system(size: 12.5)).foregroundStyle(Theme.teal) }
            }.buttonStyle(.plain).help(model.quickFolder?.path ?? "Choose where levelled copies are saved")
        }
        .padding(.leading, 6).padding(.trailing, 12).padding(.vertical, 5)
        .background(Capsule().fill(model.quickLevel ? Theme.teal.opacity(0.10) : Theme.raised))
        .overlay(Capsule().stroke(model.quickLevel ? Theme.teal.opacity(0.3) : Theme.line2))
    }
    var statusBar: some View {
        HStack(spacing: 10) {
            Circle().fill(model.busy ? Theme.amber : Theme.teal).frame(width: 7, height: 7)
            Text(model.status).lineLimit(1).foregroundStyle(Theme.text)
            if model.watching, let folder = model.watchFolder { Label("Watching \(folder.lastPathComponent)", systemImage: "eye").foregroundStyle(Theme.muted) }
            Spacer()
            Text("Processing stays on this Mac").foregroundStyle(Theme.muted)
        }.font(.system(size: 11.5)).padding(.horizontal, 16).frame(height: 28)
        .background(Theme.panel).overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    // MARK: Queue
    var queue: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Cues").sectionTitle()
                Spacer()
                Text(model.jobs.isEmpty ? "Empty" : "\(model.completedCount) of \(model.jobs.count) done").font(.system(size: 12)).foregroundStyle(Theme.muted).monospacedDigit()
                Button { model.removeSelected() } label: { Image(systemName: "minus") }.buttonStyle(CLButton(kind: .ghost)).help("Remove the selected cue from the list (the file stays where it is)")
                    .disabled(model.busy || model.selection == nil)
            }.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
            ScrollView {
                LazyVStack(spacing: 0) { ForEach(model.jobs) { job in queueRow(job) } }
            }
            dropHint.padding(14)
        }.background(Theme.panel)
        .onDeleteCommand { model.removeSelected() }
    }
    func queueRow(_ job: CueJob) -> some View {
        let selected = model.selection == job.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: job.analysis?.info.isVideo == true ? "film" : "waveform").font(.system(size: 11)).foregroundStyle(Theme.dim).frame(width: 16)
                Text(job.source.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                StateBadge(job: job, target: job.output?.settings.target ?? model.settings.target)
            }
            if let analysis = job.analysis {
                HStack(spacing: 10) {
                    LoudnessRibbon(source: analysis.levels.integrated, output: job.output?.levels.integrated, target: job.output?.settings.target ?? model.settings.target, compact: true)
                    (Text(lufs(analysis.levels.integrated)) + Text("  →  ").foregroundColor(Theme.muted) + Text(lufs(job.output?.levels.integrated)))
                        .font(.system(size: 11.5)).monospacedDigit().frame(width: 96, alignment: .trailing)
                }
            } else if job.status == .failed || job.status == .cancelled {
                Text(job.message).font(.system(size: 11.5)).foregroundStyle(job.status == .failed ? Theme.coral : Theme.muted).lineLimit(2)
            }
            if job.status == .working { ProgressView(value: job.progress).progressViewStyle(.linear).tint(Theme.bone) }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(selected ? Theme.raised : Color.clear)
        .overlay(alignment: .leading) { if selected { Rectangle().fill(Theme.teal).frame(width: 3) } }
        .overlay(alignment: .top) { Rectangle().fill(Color(hex: 0x222831)).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture { model.selection = job.id }
        .contextMenu {
            Button("Show original in Finder") { NSWorkspace.shared.activateFileViewerSelecting([job.source]) }
            if let saved = job.exportURL { Button("Show levelled copy in Finder") { NSWorkspace.shared.activateFileViewerSelecting([saved]) } }
            Divider()
            Button("Remove from list") { model.selection = job.id; model.removeSelected() }.disabled(model.busy)
        }
        .accessibilityElement(children: .combine).accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
    var dropHint: some View {
        VStack(spacing: 3) {
            Text("Drop audio or video").font(.system(size: 12.5, weight: .medium))
            Text(model.quickLevel ? "Levelled copies go straight to your output folder" : "Files are measured as they arrive").hint().multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(14)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line2, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
    }

    // MARK: Centre
    var center: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let job = model.selected { cueDetail(job) } else { emptyState }
            }.padding(.horizontal, 28).padding(.vertical, 22).frame(maxWidth: 980, alignment: .leading).frame(maxWidth: .infinity)
        }.background(Theme.base)
    }
    @ViewBuilder func cueDetail(_ job: CueJob) -> some View {
        header(job)
        if job.status == .failed { attention([job.message], color: Theme.coral) }
        if job.status == .working {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text(job.message).font(.system(size: 12.5)).foregroundStyle(Theme.text); Spacer(); Text("\(Int(job.progress * 100))%").monospacedDigit().foregroundStyle(Theme.muted) }
                ProgressView(value: job.progress).tint(Theme.teal)
            }.card()
        }
        if let analysis = job.analysis {
            ribbonCard(job, analysis)
            playbackCard(job)
            statsStrip(job, analysis)
            if let output = job.output {
                if model.outputIsStale { attention(["Settings have changed since this cue was levelled. Level it again to apply them."], color: Theme.amber) }
                if !output.warnings.isEmpty { attention(output.warnings, color: Theme.amber) }
            }
            HStack(alignment: .top, spacing: 28) {
                checksColumn(analysis)
                referenceColumn(job)
            }
            actions(job)
        } else if job.status != .working {
            VStack(alignment: .leading, spacing: 10) {
                Text("This cue hasn't been measured yet.").font(.system(size: 13)).foregroundStyle(Theme.text)
                Button("Measure") { model.analyze() }.buttonStyle(CLButton(kind: .primary)).disabled(model.busy)
            }.card()
        }
    }
    func header(_ job: CueJob) -> some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(job.source.deletingPathExtension().lastPathComponent).font(.system(size: 26, weight: .semibold)).tracking(-0.4).lineLimit(2).textSelection(.enabled)
                if let info = job.analysis?.info {
                    HStack(spacing: 16) { ForEach(fileFacts(job.source, info), id: \.self) { Text($0) } }.font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                }
            }
            Spacer()
            if let saved = job.exportURL {
                VStack(alignment: .trailing, spacing: 3) {
                    (Text("Saved as ").foregroundColor(Theme.muted) + Text(saved.lastPathComponent).foregroundColor(Theme.bone)).font(.system(size: 12.5)).lineLimit(1)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Theme.teal)
                }
            }
        }
    }
    func fileFacts(_ source: URL, _ info: MediaInfo) -> [String] {
        var parts = [source.pathExtension.uppercased(), clockText(info.duration), info.channels == 1 ? "Mono" : info.channels == 2 ? "Stereo" : "\(info.channels)-channel surround"]
        if let rate = info.sampleRate { parts.append(String(format: "%g kHz", Double(rate) / 1000)) }
        if let tracks = info.audioStreams, tracks > 1 { parts.append("\(tracks) audio tracks") }
        if info.isVideo { parts.append(info.videoCodec.map { "Video \($0.uppercased())" } ?? "Video") }
        parts.append(ByteCountFormatter.string(fromByteCount: info.byteCount, countStyle: .file))
        return parts
    }
    func ribbonCard(_ job: CueJob, _ analysis: Analysis) -> some View {
        let target = job.output?.settings.target ?? model.settings.target
        return VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline) {
                Text("Loudness").sectionTitle()
                Spacer()
                if let output = job.output {
                    let gain = output.gainApplied ?? (output.levels.integrated - analysis.levels.integrated)
                    Text(signed(gain) + " dB").font(.system(size: 22, weight: .semibold)).tracking(-0.4).monospacedDigit()
                    Text(gainDescription(output)).font(.system(size: 13)).foregroundStyle(Theme.muted)
                } else {
                    let plan = LosslessPlan(levels: analysis.levels, target: target, ceiling: model.settings.peak, maxLimiting: model.settings.peakLimit ?? 0)
                    Text("Needs " + signed(target - analysis.levels.integrated) + " dB").font(.system(size: 15, weight: .semibold)).monospacedDigit()
                    if plan.shortfall > 0.05 { Text("peaks allow \(signed(plan.gain)) dB").font(.system(size: 13)).foregroundStyle(Theme.amber) }
                }
            }
            VStack(spacing: 10) {
                LoudnessRibbon(source: analysis.levels.integrated, output: job.output?.levels.integrated, target: target)
                HStack { ForEach([-40, -35, -30, -25, -20, -15, -10, -5], id: \.self) { Text("−\(abs($0))"); Spacer() }; Text("0 LUFS") }
                    .font(.system(size: 10.5)).foregroundStyle(Theme.dim).monospacedDigit()
            }
        }.card()
    }
    func gainDescription(_ output: ProcessedAudio) -> String {
        switch output.finalGainMode {
        case "fixed": return "one exact gain change"
        case "limited": return "gain with \(String(format: "%.1f", output.limiting ?? 0)) dB of peak limiting"
        case "dynamic": return "dynamic loudness control"
        default: return output.settings.format == .lossless ? "gain change" : "processed"
        }
    }
    func playbackCard(_ job: CueJob) -> some View {
        VStack(spacing: 10) {
            HStack {
                Segments(options: [(false, "Original"), (true, "Levelled")], selection: Binding(get: { model.processedPreview }, set: { model.switchPreview($0) }))
                    .frame(width: 190).disabled(job.output == nil || model.clipEditing)
                Button {
                    model.clipEditing.toggle()
                    if model.clipEditing { model.switchPreview(false) }
                    else {
                        model.selectedRegion = nil
                        // Render straight away so the edits can be heard in Levelled.
                        if model.outputIsStale || (job.output == nil && !ClipGain.active(job.clipGain).isEmpty) { model.processSelected() }
                    }
                } label: {
                    Label(model.clipEditing ? "Done editing" : "Clip gain" + (ClipGain.active(job.clipGain).isEmpty ? "" : " · \(ClipGain.active(job.clipGain).count)"), systemImage: "slider.vertical.3")
                }.buttonStyle(CLButton(kind: model.clipEditing ? .primary : .ghost)).disabled(job.analysis == nil || model.busy)
                .help("Raise or lower sections of this cue, like clip gain in Pro Tools")
                Spacer()
                if !model.currentCurve.isEmpty {
                    HStack(spacing: 14) {
                        HStack(spacing: 6) { Capsule().fill(Theme.amber).frame(width: 14, height: 2); Text("Short-term loudness") }
                        HStack(spacing: 6) { Capsule().fill(Theme.bone.opacity(0.55)).frame(width: 14, height: 1); Text("Target \(lufs(model.settings.target))") }
                    }.font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                }
            }
            if model.clipEditing, let analysis = job.analysis {
                ClipGainEditor(job: job, analysis: analysis)
            } else {
                Waveform(peaks: model.currentWaveform, curve: model.currentCurve, target: job.output?.settings.target ?? model.settings.target, position: model.playhead, duration: model.duration, seek: model.seek)
            }
            HStack(spacing: 12) {
                Button { model.playPause() } label: {
                    Image(systemName: model.playing ? "pause.fill" : "play.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.base)
                        .frame(width: 30, height: 30).background(Circle().fill(Theme.bone))
                }.buttonStyle(.plain).keyboardShortcut(.space, modifiers: []).accessibilityLabel(model.playing ? "Pause" : "Play")
                Text(clockText(model.playhead)).monospacedDigit()
                Slider(value: Binding(get: { min(model.duration, model.playhead) }, set: { model.seek($0) }), in: 0 ... max(0.01, model.duration)).controlSize(.small).accessibilityLabel("Playback position").disabled(model.duration == 0)
                Text(clockText(model.duration)).monospacedDigit()
                Toggle("Match loudness", isOn: $model.matchPreview).toggleStyle(.checkbox).onChange(of: model.matchPreview) { _ in model.applyVolume() }.disabled(job.output == nil)
                    .help("Plays original and levelled versions at equal loudness so you compare sound, not volume")
            }.font(.system(size: 12)).foregroundStyle(Theme.muted)
            if job.analysis?.info.isVideo == true {
                DisclosureGroup("Picture") { VideoPlayer(player: model.player).frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 8)).padding(.top, 8) }
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
            }
        }.padding(.horizontal, 16).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
    }
    func statsStrip(_ job: CueJob, _ analysis: Analysis) -> some View {
        let output = job.output
        let ceiling = output?.settings.peak ?? model.settings.peak
        return HStack(spacing: 0) {
            stat("Integrated", value: output?.levels.integrated ?? analysis.levels.integrated, unit: "LUFS", was: output.map { _ in analysis.levels.integrated }, first: true)
            stat("True peak", value: output?.levels.truePeak ?? analysis.levels.truePeak, unit: "dBTP", was: output.map { _ in analysis.levels.truePeak })
            stat("Loudness range", value: output?.levels.loudnessRange ?? analysis.levels.loudnessRange, unit: "LU", was: output.map { _ in analysis.levels.loudnessRange })
            stat("Peak to average", value: output?.levels.crestFactor ?? analysis.levels.crestFactor, unit: "dB", was: output == nil ? nil : analysis.levels.crestFactor)
            stat("Headroom left", value: ceiling - (output?.levels.truePeak ?? analysis.levels.truePeak), unit: "dB", note: "to \(lufs(ceiling)) ceiling")
        }
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
    func stat(_ title: String, value: Double?, unit: String, was: Double? = nil, note: String? = nil, first: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(lufs(value)).font(.system(size: 17, weight: .semibold)).monospacedDigit()
                Text(unit).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.muted)
            }
            Group {
                if let note { Text(note) }
                else if let was, let value { Text(abs(was - value) < 0.05 ? "unchanged" : "was \(lufs(was))") }
                else { Text(" ") }
            }.font(.system(size: 11.5)).foregroundStyle(Theme.dim).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, first ? 0 : 14).padding(.vertical, 12)
        .overlay(alignment: .leading) { if !first { Rectangle().fill(Theme.line).frame(width: 1) } }
    }
    func attention(_ notes: [String], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(notes, id: \.self) { note in
                HStack(alignment: .top, spacing: 9) { Circle().fill(color).frame(width: 7, height: 7).padding(.top, 5); Text(note).font(.system(size: 12.5)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.07))).overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.22)))
    }
    func note(_ text: String, good: Bool) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Circle().fill(good ? Theme.teal : Theme.amber).frame(width: 7, height: 7).padding(.top, 5)
            Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }
    func checksColumn(_ analysis: Analysis) -> some View {
        let findings = analysis.sourceFindings
        return VStack(alignment: .leading, spacing: 7) {
            Text("Source checks").sectionTitle().padding(.bottom, 2)
            if findings.isEmpty { note(analysis.stereo == nil ? "Measure again to check clipping, phase and silence." : "No clipping, DC offset, phase or silence problems.", good: analysis.stereo != nil) }
            ForEach(findings, id: \.self) { note($0, good: false) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder func referenceColumn(_ job: CueJob) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Against your references").sectionTitle().padding(.bottom, 2)
            if model.references.isEmpty {
                Text("Import your approved reference library to compare each cue with finished material.").hint()
                Button("Import library…") { model.importReferenceLibrary() }.buttonStyle(CLButton()).disabled(model.busy)
            } else if let check = model.referenceCheck(for: job) {
                ForEach(check.findings, id: \.self) { note($0.text, good: !$0.needsAttention) }
                if let approach = check.approach, let proposed = check.recommendedSettings(from: model.settings), model.settings.format != .lossless {
                    let changes = ReferenceCheck.describeChanges(from: model.settings, to: proposed)
                    HStack {
                        Text("Recommended: \(approach.rawValue)").font(.system(size: 12.5, weight: .semibold))
                        Spacer()
                        Button("Apply") { model.applyReferencePlan() }.buttonStyle(CLButton()).disabled(model.busy || changes.isEmpty)
                    }.padding(.top, 4)
                    ForEach(changes, id: \.self) { Text($0).hint() }
                }
            }
            if job.analysis != nil {
                Button { model.beginAddingReference() } label: { Label("Add as an approved reference…", systemImage: "star") }
                    .buttonStyle(CLButton(kind: .ghost)).disabled(model.busy).padding(.top, 4)
                    .help("This cue sounds right on the PA: keep its measurements as an example of good")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    func actions(_ job: CueJob) -> some View {
        HStack(spacing: 8) {
            Button(job.output == nil ? (model.quickLevel ? "Level this cue" : "Process this cue") : "Level again") { model.processSelected() }.buttonStyle(CLButton(kind: .primary)).disabled(model.busy)
            Button("Measure again") { model.analyze() }.buttonStyle(CLButton()).disabled(model.busy)
            Spacer()
            if job.output != nil {
                Button("Export…") { model.exportSelected() }.buttonStyle(CLButton()).disabled(model.busy)
                if job.output?.audioCompanion != nil { Button("Export WAV…") { model.exportSelected(audioCopy: true) }.buttonStyle(CLButton()).disabled(model.busy) }
                Button("Save report…") { model.saveReport() }.buttonStyle(CLButton(kind: .ghost)).disabled(model.busy)
            }
        }.padding(.top, 4)
    }
    var emptyState: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 70)
            LogoMark().frame(width: 88, height: 88)
            Text(model.quickLevel ? "Drop cues to level them" : "Drop cues to get started").font(.system(size: 26, weight: .semibold)).tracking(-0.4)
            Text(model.quickLevel
                 ? "Each file is brought to \(lufs(model.settings.target)) LUFS with one exact gain change and saved to \(model.quickFolder?.lastPathComponent ?? "your output folder"). Picture and audio quality are untouched."
                 : "Turn on Quick Level to level dropped files automatically, or add files to measure and process them one by one.")
                .font(.system(size: 13.5)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).frame(maxWidth: 460)
            HStack(spacing: 10) {
                Button { model.addFiles() } label: { Label("Add files", systemImage: "plus") }.buttonStyle(CLButton(kind: .primary))
                if !model.quickLevel { Button("Turn on Quick Level") { model.setQuickLevel(true) }.buttonStyle(CLButton()) }
            }
            Text("WAV, AIFF, MP3, M4A, FLAC, MP4, MOV and most other audio and video files").hint().padding(.top, 10)
            Spacer(minLength: 40)
        }.frame(maxWidth: .infinity)
    }

    // MARK: Inspector
    var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                section {
                    HStack { Text("Level to").sectionTitle(); Spacer(); standardsMenu }
                    valueRow("Target", value: $model.settings.target, range: -30 ... -12, unit: "LUFS")
                    valueRow("Peak ceiling", value: $model.settings.peak, range: -6 ... -1, unit: "dBTP")
                    Toggle(isOn: $model.evenOut) { Text("Even out loud and quiet stretches").font(.system(size: 12.5)).foregroundStyle(Theme.text).frame(maxWidth: .infinity, alignment: .leading) }.toggleStyle(CLSwitch())
                    Text(model.evenOut ? "Quick Level turns stretches more than 2 dB louder or quieter than the rest back toward it, with short fades. Volume only; edit them under Clip gain. Turn off for music." : "Quick Level applies one gain change to the whole file.").hint()
                }
                section {
                    Text("When peaks won't fit").sectionTitle()
                    Segments(options: [(false, "Stay quieter"), (true, "Limit peaks")], selection: Binding(get: { model.settings.peakLimit != nil }, set: { model.settings.peakLimit = $0 ? (model.settings.peakLimit ?? 3) : nil }))
                    if model.settings.peakLimit != nil {
                        valueRow("Most limiting allowed", value: Binding(get: { model.settings.peakLimit ?? 3 }, set: { model.settings.peakLimit = $0 }), range: 1 ... 6, unit: "dB")
                        Text("Only the peaks that would pass the ceiling are touched, with 4× oversampling. Cues needing more stay partly quieter.").hint()
                    } else {
                        Text("Cues are never touched apart from gain. The report shows how far below target each one lands.").hint()
                    }
                }
                section {
                    Text("Output").sectionTitle()
                    folderRow(model.quickFolder, empty: "Choose output folder") { model.chooseQuickFolder() }
                    Menu {
                        ForEach(OutputFormat.allCases) { format in Button(format.rawValue) { model.settings.format = format } }
                    } label: { HStack { Text("File type").foregroundStyle(Theme.text); Spacer(); Text(model.settings.format.rawValue).foregroundStyle(Theme.bone) } }
                        .menuStyle(.borderlessButton).font(.system(size: 12.5)).disabled(model.quickLevel)
                    Text(formatHint).hint()
                }
                section {
                    Toggle(isOn: Binding(get: { model.watching }, set: { model.setWatching($0) })) { Text("Watch a folder").sectionTitle().frame(maxWidth: .infinity, alignment: .leading) }.toggleStyle(CLSwitch())
                    if model.watchFolder != nil || model.watching { folderRow(model.watchFolder, empty: "Choose folder") { model.chooseWatchFolder() } }
                    Text("New files are added the moment they finish copying in\(model.quickLevel ? ", and levelled straight away" : ""). Files already there are left alone.").hint()
                }
                section {
                    HStack { Text("Content").sectionTitle(); Spacer(); presetsMenu }
                    Segments(options: [(ContentMode.music, "Music"), (ContentMode.mixed, "Mixed"), (ContentMode.voice, "Voice")], selection: Binding(get: { model.settings.mode }, set: { model.changeMode($0) }))
                    Text(model.settings.mode.detail).hint()
                }
                processingSection
                referencesSection
            }
        }.background(Theme.panel).disabled(model.busy)
    }
    var formatHint: String {
        switch model.settings.format {
        case .lossless: return "Picture copied untouched into MOV (MKV for other containers). Audio uncompressed at its own sample rate, with one exact gain change."
        case .automatic: return "Audio becomes 24-bit WAV. Video keeps its picture with AAC stereo audio."
        case .videoAndWav: return "Video with AAC audio, plus a 24-bit WAV rendered from the source."
        default: return "Audio only, 48 kHz stereo. Video is not included."
        }
    }
    var standardsMenu: some View {
        Menu("Standards") { ForEach(LoudnessPreset.all) { preset in Button(preset.name) { model.applyLoudnessPreset(preset) } } }
            .menuStyle(.borderlessButton).font(.system(size: 12)).foregroundStyle(Theme.teal).fixedSize()
    }
    var presetsMenu: some View {
        Menu("Presets") {
            Button("Music defaults") { model.settings = ProcessingSettings(); model.changeMode(.music) }
            Button("Mixed defaults") { model.settings = ProcessingSettings() }
            Button("Voice defaults") { model.settings = ProcessingSettings(); model.changeMode(.voice) }
            if !model.presets.isEmpty { Divider(); ForEach(model.presets) { preset in Button(preset.name) { model.settings = preset.settings } } }
            Divider(); Button("Save current settings…") { model.showSavePreset = true }
        }.menuStyle(.borderlessButton).font(.system(size: 12)).fixedSize()
    }
    var processingSection: some View {
        section {
            Button { withAnimation(.easeOut(duration: 0.15)) { showProcessing.toggle() } } label: {
                HStack { Text("Processing").sectionTitle(); Spacer(); Text(model.settings.format == .lossless ? "Off in lossless mode" : showProcessing ? "Hide" : "Show").font(.system(size: 12)).foregroundStyle(Theme.muted); Image(systemName: showProcessing ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted) }
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
            Text("Leveler, compression, noise and tone tools for cues that need more than gain. They change the sound, so they are bypassed in lossless mode.").hint()
            if showProcessing {
                Group {
                    module("Automatic leveler", "Evens out quiet and loud passages", isOn: $model.settings.levelerOptions.enabled)
                    if model.settings.levelerOptions.enabled {
                        Segments(options: LevelerStyle.allCases.map { ($0, $0.rawValue) }, selection: Binding(get: { model.settings.levelerOptions.style }, set: { model.settings.levelerOptions.apply($0) }))
                    }
                    module("Peak compression", "Restrains sudden loud passages", isOn: $model.settings.compression)
                    module("Rumble filter", "Removes low handling noise", isOn: $model.settings.highpass)
                    module("De-esser", "Softens sharp S sounds", isOn: $model.settings.deess)
                    module("Harshness control", "Tames excess upper-mid energy", isOn: $model.settings.soften)
                    module("Noise reduction", "Cleans background before levelling", isOn: $model.settings.denoise)
                    if model.settings.denoise {
                        Segments(options: model.settings.mode == .voice ? [(NoiseMethod.steady, "Steady noise"), (NoiseMethod.speech, "Speech denoiser")] : [(NoiseMethod.steady, "Steady noise")], selection: $model.settings.cleanupOptions.method)
                        if model.settings.cleanupOptions.method == .speech { valueRow("Strength", value: $model.settings.cleanupOptions.speechStrength, range: 0 ... 100, unit: "%") }
                        else { valueRow("Reduction", value: $model.settings.noiseReduction, range: 1 ... 12, unit: "dB") }
                    }
                    HStack { Text("Mains hum").font(.system(size: 12.5)).foregroundStyle(Theme.text); Spacer(); Picker("Mains hum", selection: $model.settings.cleanupOptions.hum) { ForEach(HumMode.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().fixedSize() }
                    if model.settings.cleanupOptions.hum != .off { valueRow("Hum reduction", value: $model.settings.cleanupOptions.humReduction, range: 1 ... 18, unit: "dB") }
                }
                Group {
                    if model.settings.mode == .voice {
                        module("Dynamic voice EQ", "Small cuts for boom, boxiness and edge", isOn: $model.settings.enhancementOptions.voiceEQ)
                        module("Plosive reduction", "Restrains P and B bursts", isOn: $model.settings.enhancementOptions.plosives)
                    }
                    module("Repair clipping", "Rebuilds flattened peaks; may add artifacts", isOn: $model.settings.enhancementOptions.repairClipping)
                    module("Brightness", "Lifts existing highs, including hiss", isOn: $model.settings.enhancementOptions.brightness)
                    if model.settings.enhancementOptions.brightness { valueRow("High-shelf gain", value: $model.settings.enhancementOptions.brightnessGain, range: 0 ... 3, unit: "dB") }
                    Button { showAdvanced.toggle() } label: { HStack { Text("Fine controls").font(.system(size: 12.5, weight: .medium)); Spacer(); Image(systemName: showAdvanced ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold)) }.foregroundStyle(Theme.text).contentShape(Rectangle()) }.buttonStyle(.plain).padding(.top, 4)
                    if showAdvanced { advancedControls }
                }
            }
        }
    }
    @ViewBuilder var advancedControls: some View {
        if model.settings.levelerOptions.enabled {
            valueRow("Maximum lift", value: $model.settings.levelerOptions.maximumLift, range: 0 ... 12, unit: "dB")
            valueRow("Smoothing", value: $model.settings.levelerOptions.response, range: 1 ... 10, unit: "s")
            valueRow("Quiet threshold", value: $model.settings.levelerOptions.noiseThreshold, range: -70 ... -25, unit: "dBFS")
        }
        Toggle(isOn: Binding(get: { model.settings.workingLevel != nil }, set: { model.settings.workingLevel = $0 ? ReferenceCheck.workingLevel : nil })) {
            Text("Level-independent dynamics").font(.system(size: 12.5)).foregroundStyle(Theme.text).frame(maxWidth: .infinity, alignment: .leading)
        }.toggleStyle(CLSwitch())
        if model.settings.workingLevel != nil { valueRow("Working level", value: Binding(get: { model.settings.workingLevel ?? ReferenceCheck.workingLevel }, set: { model.settings.workingLevel = $0 }), range: -24 ... -14, unit: "LUFS") }
        if model.settings.enhancementOptions.voiceEQ { valueRow("EQ cut per band", value: $model.settings.enhancementOptions.eqLimit, range: 2 ... 3, unit: "dB") }
        if model.settings.enhancementOptions.plosives {
            valueRow("Plosive cut", value: $model.settings.enhancementOptions.plosiveLimit, range: 2 ... 6, unit: "dB")
            valueRow("Plosive threshold", value: $model.settings.enhancementOptions.plosiveThreshold, range: -40 ... -12, unit: "dBFS")
        }
        valueRow("Range target", value: $model.settings.range, range: 5 ... 20, unit: "LU")
        valueRow("Compression ratio", value: $model.settings.ratio, range: 1 ... 4, unit: ":1")
        valueRow("Rumble cutoff", value: $model.settings.cutoff, range: 30 ... 150, unit: "Hz")
        valueRow("De-ess amount", value: $model.settings.deessAmount, range: 0 ... 0.6, unit: "")
        if model.settings.denoise && model.settings.cleanupOptions.method == .steady {
            valueRow("Noise floor", value: $model.settings.cleanupOptions.noiseFloor, range: -80 ... -20, unit: "dB")
            Toggle(isOn: $model.settings.cleanupOptions.trackNoise) { Text("Follow changing noise").font(.system(size: 12.5)).foregroundStyle(Theme.text).frame(maxWidth: .infinity, alignment: .leading) }.toggleStyle(CLSwitch())
        }
        valueRow("Harshness band", value: $model.settings.frequency, range: 2000 ... 6000, unit: "Hz")
        valueRow("Harshness cut", value: $model.settings.cut, range: 2 ... 3, unit: "dB")
    }
    var referencesSection: some View {
        section {
            Text("References").sectionTitle()
            Text(model.references.summary).hint()
            HStack(spacing: 8) {
                Button(model.references.isEmpty ? "Import library…" : "Replace library…") { model.importReferenceLibrary() }.buttonStyle(CLButton())
                Button("Match a reference…") { model.chooseReference() }.buttonStyle(CLButton(kind: .ghost)).help("Measure a finished cue and use its loudness as the target")
            }
            if !model.references.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.references.records) { record in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(record.name).font(.system(size: 12)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                                    Text("\(record.category ?? "") · \(lufs(record.cuelevelStereo.integratedLufs)) LUFS · LRA \(String(format: "%.1f", record.cuelevelStereo.loudnessRangeLu))").hint()
                                }
                                Spacer(minLength: 4)
                                Button { model.removeReference(record) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(Theme.muted)
                                    .help("Remove from the catalogue (the recording is not touched)").disabled(model.busy)
                            }
                        }
                    }.padding(.top, 4)
                } label: { Text("Catalogue (\(model.references.records.count))").font(.system(size: 12.5)).foregroundStyle(Theme.text) }
                Toggle(isOn: $model.autoRecommend) { Text("Apply each cue's recommendation").font(.system(size: 12.5)).foregroundStyle(Theme.text).frame(maxWidth: .infinity, alignment: .leading) }.toggleStyle(CLSwitch())
                Text("When processing (not in lossless mode), each cue gets Preserve or Gentle correction based on your approved references.").hint()
            }
        }
    }
    func section<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11) { content() }
            .padding(.horizontal, 18).padding(.vertical, 15).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
    func module(_ title: String, _ subtitle: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) { Text(title).font(.system(size: 12.5, weight: .medium)); Text(subtitle).hint() }.frame(maxWidth: .infinity, alignment: .leading)
        }.toggleStyle(CLSwitch())
    }
    func folderRow(_ folder: URL?, empty: String, choose: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(Theme.muted)
            Text(folder.map { $0.deletingLastPathComponent().lastPathComponent + " › " + $0.lastPathComponent } ?? empty).font(.system(size: 12)).foregroundStyle(folder == nil ? Theme.muted : Theme.bone).lineLimit(1).truncationMode(.head)
            Spacer()
            Button(folder == nil ? "Choose" : "Change", action: choose).buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.teal)
        }.padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
        .help(folder?.path ?? empty)
    }
    func valueRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.system(size: 12.5)).foregroundStyle(Theme.text)
                Spacer()
                HStack(spacing: 4) {
                    TextField(title, value: value, format: .number.precision(.fractionLength(1))).textFieldStyle(.plain).multilineTextAlignment(.trailing).frame(width: 48).monospacedDigit()
                    if !unit.isEmpty { Text(unit).foregroundStyle(Theme.muted) }
                }.font(.system(size: 12.5)).padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
            }
            Slider(value: value, in: range).controlSize(.small).accessibilityLabel(title)
        }
    }

    // MARK: Sheets
    var presetSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save settings as a preset").font(.system(size: 18, weight: .semibold))
            Text("Keeps the content type, loudness, processing and file type.").hint()
            TextField("Preset name", text: $model.presetName).textFieldStyle(.roundedBorder).onSubmit { model.savePreset() }
            HStack { Button("Cancel") { model.showSavePreset = false }.buttonStyle(CLButton(kind: .ghost)); Spacer(); Button("Save preset") { model.savePreset() }.buttonStyle(CLButton(kind: .primary)).disabled(model.presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width: 420).background(Theme.panel).preferredColorScheme(.dark)
    }
    var updateSheet: some View {
        let feed = updater.offered
        let justUpdated: Bool = { if case .justUpdated = updater.state { return true }; return false }()
        let headline: String = {
            switch updater.state {
            case .justUpdated: return "CueLevel has been updated"
            case .available, .downloading, .installing: return "New version available"
            case .checking: return "Checking for updates"
            case .upToDate: return "You're up to date"
            case .failed: return feed == nil ? "Couldn't check for updates" : "Update not installed"
            case .idle: return "Software update"
            }
        }()
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                LogoMark().frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline).font(.system(size: 19, weight: .semibold)).tracking(-0.2)
                    if let feed, justUpdated {
                        Text("You're now on CueLevel \(feed.version).").hint()
                    } else if let feed, updater.state != .upToDate {
                        HStack(spacing: 6) {
                            Text("CueLevel \(feed.version)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.teal)
                                .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(Theme.teal.opacity(0.14)))
                            Text("You have \(updater.currentVersion)").hint()
                        }
                    } else {
                        Text("CueLevel \(updater.currentVersion) (build \(updater.currentBuild))").hint()
                    }
                }
            }
            switch updater.state {
            case .checking: HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking for updates…").hint() }
            case .upToDate: Text("You have the newest version of CueLevel.").font(.system(size: 13)).foregroundStyle(Theme.text)
            case .failed(let message): Text(message).font(.system(size: 13)).foregroundStyle(Theme.coral).fixedSize(horizontal: false, vertical: true)
            case .downloading(let fraction): VStack(alignment: .leading, spacing: 6) { ProgressView(value: fraction).tint(Theme.teal); Text("Downloading… \(Int(fraction * 100))%").hint() }
            case .installing: HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking the signature and installing. CueLevel will reopen by itself.").hint() }
            case .idle, .available, .justUpdated: EmptyView()
            }
            if let feed, !feed.noteLines.isEmpty, updater.state != .upToDate {
                VStack(alignment: .leading, spacing: 9) {
                    Text("WHAT'S NEW").font(.system(size: 10.5, weight: .semibold)).tracking(0.8).foregroundStyle(Theme.muted)
                    ForEach(feed.noteLines, id: \.self) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                            Image(systemName: "sparkle").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.teal)
                            Text(line).font(.system(size: 13)).foregroundStyle(Theme.bone.opacity(0.92)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.field)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
            }
            if model.busy, updater.available != nil { Text("CueLevel is working. You can install once the current job finishes or you stop it.").hint() }
            HStack(spacing: 8) {
                if updater.available != nil { Button("Skip this version") { updater.skip() }.buttonStyle(CLButton(kind: .ghost)) }
                Spacer()
                switch updater.state {
                case .available:
                    Button("Later") { updater.later() }.buttonStyle(CLButton(kind: .ghost))
                    Button("Install and reopen") { updater.install(canQuit: !model.busy) }.buttonStyle(CLButton(kind: .primary)).keyboardShortcut(.defaultAction).disabled(model.busy)
                case .downloading: Button("Cancel") { updater.cancel() }.buttonStyle(CLButton(kind: .ghost))
                case .installing: EmptyView()
                case .justUpdated: Button("Got it") { updater.showSheet = false; updater.state = .idle }.buttonStyle(CLButton(kind: .primary)).keyboardShortcut(.defaultAction)
                default: Button("Done") { updater.showSheet = false }.buttonStyle(CLButton(kind: .primary)).keyboardShortcut(.defaultAction)
                }
            }
        }.padding(26).frame(width: 500).background(Theme.panel).preferredColorScheme(.dark)
    }
    var referenceSheet: some View {
        let job = model.jobs.first { $0.id == model.referenceDraft }
        return VStack(alignment: .leading, spacing: 14) {
            Text("Add to your reference catalogue").font(.system(size: 18, weight: .semibold))
            Text("Add only finished cues you have heard on the PA and approved. CueLevel keeps their measurements as an example of what good sounds like; the recording itself is not copied.").hint()
            if let job, let analysis = job.analysis {
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.source.lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text("\(lufs(analysis.levels.integrated)) LUFS · \(lufs(analysis.levels.truePeak)) dBTP · LRA \(String(format: "%.1f", analysis.levels.loudnessRange)) LU\(analysis.levels.crestFactor.map { " · peak-to-average \(String(format: "%.1f", $0)) dB" } ?? "")").hint()
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                if !analysis.sourceFindings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Source checks found:").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.amber)
                        ForEach(analysis.sourceFindings, id: \.self) { Text($0).hint() }
                    }
                }
            }
            Text("Content").sectionTitle()
            Segments(options: ContentMode.allCases.map { ($0, $0.rawValue) }, selection: $model.referenceDraftCategory)
            TextField("Note (optional), e.g. \"walk-in music, sounded right at desk gain\"", text: $model.referenceDraftNote).textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { model.referenceDraft = nil }.buttonStyle(CLButton(kind: .ghost))
                Spacer()
                Button("Add reference") { model.addReference() }.buttonStyle(CLButton(kind: .primary)).keyboardShortcut(.defaultAction).disabled(model.busy || job?.analysis == nil)
            }
        }.padding(24).frame(width: 480).background(Theme.panel).preferredColorScheme(.dark)
    }
    var aboutSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) { LogoMark().frame(width: 52, height: 52); VStack(alignment: .leading, spacing: 3) { Text("CueLevel \(appShortVersion)").font(.system(size: 20, weight: .semibold)); Text("Lossless loudness levelling for event playback").hint() } }
            Text("All processing happens on this Mac. CueLevel never uploads your files and collects no data. Originals are never modified.").font(.system(size: 13)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: $updater.autoCheck) { Text("Check for updates automatically").font(.system(size: 12.5)).foregroundStyle(Theme.text).frame(maxWidth: .infinity, alignment: .leading) }.toggleStyle(CLSwitch())
            Text("When on, CueLevel reads one small public version file on GitHub at launch and twice a day. Nothing about you or your files is sent.").hint()
            Text("Includes FFmpeg and the RNNoise speech model. Their licences, source locations and build details are in the Third-party notices that ship with CueLevel.").hint()
            HStack { Link("FFmpeg licensing", destination: URL(string: "https://ffmpeg.org/legal.html")!).font(.system(size: 12.5)); Spacer(); Button("Done") { model.showAbout = false }.buttonStyle(CLButton(kind: .primary)).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 480).background(Theme.panel).preferredColorScheme(.dark)
    }
}

/// Centres the close/minimise/zoom buttons vertically in CueLevel's 52-pt top bar (the window uses a hidden title bar,
/// so the bar is drawn by SwiftUI). Re-applied whenever the window resizes, changes key state or leaves full screen.
struct WindowChrome: NSViewRepresentable {
    static let barHeight: CGFloat = 52
    final class Coordinator { var observers: [NSObjectProtocol] = []; deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } } }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            Self.place(window)
            let names: [Notification.Name] = [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didExitFullScreenNotification, NSWindow.didEndLiveResizeNotification]
            context.coordinator.observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in Self.place(window) }
            }
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { if let window = view.window { Self.place(window) } }
    static func place(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen), let close = window.standardWindowButton(.closeButton), let titlebar = close.superview, let container = titlebar.superview else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        container.frame = NSRect(x: container.frame.minX, y: window.frame.height - barHeight, width: container.frame.width, height: barHeight)
        titlebar.frame = NSRect(x: 0, y: 0, width: container.frame.width, height: barHeight)
        for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = window.standardWindowButton(type) else { continue }
            button.setFrameOrigin(NSPoint(x: 18 + CGFloat(index) * 20, y: (barHeight - button.frame.height) / 2))
        }
    }
}

/// Queue status in a few words; a cue left below target shows by how much.
struct StateBadge: View {
    let job: CueJob
    let target: Double
    var body: some View {
        let (text, color): (String, Color) = {
            switch job.status {
            case .working: return ("\(Int(job.progress * 100))%", Theme.bone)
            case .ready: return ("Ready", Theme.teal)
            case .review:
                if let short = job.output?.shortfall, short > 0.05 { return (String(format: "%.1f under", short), Theme.amber) }
                return ("Check notes", Theme.amber)
            case .failed: return ("Failed", Theme.coral)
            case .cancelled: return ("Stopped", Theme.muted)
            case .analyzed: return ("Measured", Theme.muted)
            case .queued: return ("Waiting", Theme.muted)
            }
        }()
        Text(text).font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.12)))
    }
}

/// The CueLevel mark drawn natively: meter arc, three levelled bars, cue dot.
struct LogoMark: View {
    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height) / 64
            let center = CGPoint(x: 32 * s, y: 32 * s)
            var arc = Path()
            arc.addArc(center: center, radius: 21 * s, startAngle: .degrees(-38), endAngle: .degrees(38), clockwise: true)
            context.stroke(arc, with: .linearGradient(Gradient(colors: [Theme.amber, Theme.lime, Theme.teal]), startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)),
                           style: StrokeStyle(lineWidth: 9 * s, lineCap: .round))
            context.fill(Path(ellipseIn: CGRect(x: 49 * s, y: 28 * s, width: 8 * s, height: 8 * s)), with: .color(Theme.bone))
            for x in [24.0, 30.0, 36.0] { context.fill(Path(roundedRect: CGRect(x: x * s, y: 25 * s, width: 3.6 * s, height: 14 * s), cornerRadius: 1.8 * s), with: .color(Theme.bone)) }
        }.accessibilityHidden(true)
    }
}

@main struct CueLevelApp: App {
    @StateObject private var model = Workspace()
    @StateObject private var updater = Updater()
    init() {
        if CommandLine.arguments.contains("--self-test"), CommandLine.arguments.count >= 4 {
            do {
                let args = CommandLine.arguments
                let input = URL(fileURLWithPath: args[2]); var settings = ProcessingSettings()
                if args.contains("--voice") { settings.setMode(.voice) }
                if args.contains("--music") { settings.setMode(.music) }
                if args.contains("--filters") { settings.highpass = true; settings.denoise = true; settings.deess = true; settings.soften = true }
                if args.contains("--speech-denoise") { settings.setMode(.voice); settings.denoise = true; settings.cleanupOptions.method = .speech }
                if args.contains("--enhance") { settings.setMode(.voice); settings.enhancementOptions.voiceEQ = true; settings.enhancementOptions.plosives = true; settings.enhancementOptions.repairClipping = true; settings.enhancementOptions.brightness = true }
                if args.contains("--leveler") { settings.levelerOptions = LevelerSettings() }
                if args.contains("--video-wav") { settings.format = .videoAndWav }
                if args.contains("--flac") { settings.format = .flac }
                if args.contains("--m4a") { settings.format = .m4a }
                if args.contains("--lossless") { settings.format = .lossless; settings.target = -18; settings.peak = -1 }
                let token = Cancellation()
                if args.contains("--cancel") { DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { token.cancel() } }
                let analysis = try AudioEngine.analyze(input, token: token) { _, _ in }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CueLevel-test-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: directory) }
                let result = try AudioEngine.process(input, analysis: analysis, settings: settings, directory: directory, token: token) { _, _ in }
                try FileManager.default.copyItem(at: result.url, to: URL(fileURLWithPath: args[3]))
                if let copy = result.audioCompanion { try FileManager.default.copyItem(at: copy, to: URL(fileURLWithPath: args[3]).deletingPathExtension().appendingPathExtension("wav")) }
                print("BEFORE \(analysis.levels.integrated) LUFS; AFTER \(result.levels.integrated) LUFS; PEAK \(result.levels.truePeak) dBTP; WAVEBINS \(analysis.waveform.count)/\(result.waveform.count)")
                print(result.warnings.joined(separator: "\n")); exit(0)
            } catch is CancellationError { print("CANCELLED"); exit(2) }
            catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        }
    }
    var body: some Scene {
        Window("CueLevel", id: "workspace") {
            ContentView().environmentObject(model).environmentObject(updater)
                .onAppear { updater.start() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.shutdown() }
        }.defaultSize(width: 1440, height: 900).windowStyle(.hiddenTitleBar)
            .commands {
                CommandGroup(replacing: .appInfo) {
                    Button("About CueLevel") { model.showAbout = true }
                    Button("Check for Updates…") { Task { await updater.check(userInitiated: true) } }.disabled(!updater.canCheck)
                }
                CommandGroup(after: .newItem) { Button("Add Files…") { model.addFiles() }.keyboardShortcut("o") }
                CommandGroup(replacing: .undoRedo) {
                    Button("Undo") { if model.clipEditing { model.undoRegions() } else { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) } }.keyboardShortcut("z")
                    Button("Redo") { if model.clipEditing { model.redoRegions() } else { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) } }.keyboardShortcut("z", modifiers: [.command, .shift])
                }
            }
    }
}
