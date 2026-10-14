import Cocoa
import SwiftUI
import Combine
import AVKit
import UniformTypeIdentifiers

// MARK: - CueLevel 2.0 window
// Three columns, one job each: the show's cues (left), the cue itself (centre), and what CueLevel will do to it (right).
// Prepare is for operators; Edit opens the clip gain editor. Settings that are set once per show live in Show settings.

struct ContentView: View {
    @EnvironmentObject var model: Workspace
    @EnvironmentObject var updater: Updater
    @State private var hovering = false
    @State private var showSettings = false
    @State private var filter = ListFilter.all
    @AppStorage("CueLevelShowDetails") private var showDetails = false
    enum ListFilter: Hashable { case all, attention, done }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            HStack(spacing: 0) {
                cueList.frame(width: 292)
                Rectangle().fill(Theme.line).frame(width: 1)
                stage.frame(minWidth: 560, maxWidth: .infinity)
                if !model.clipEditing || model.selected == nil {
                    Rectangle().fill(Theme.line).frame(width: 1)
                    AssistantPanel(openSettings: { showSettings = true }, setEditing: setEditing).frame(width: 348)
                }
            }
            statusBar
        }
        .frame(minWidth: 1180, minHeight: 720)
        .background(Theme.base)
        .ignoresSafeArea(.container, edges: .top)
        .background(WindowChrome())
        .onAppear { DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) } }
        .foregroundStyle(Theme.bone)
        .tint(Theme.good)
        .preferredColorScheme(.dark)
        .onDrop(of: [UTType.fileURL], isTargeted: $hovering) { providers in
            // 2.0.1: gather every dropped file first, then add them in one go (one add per file left all but the first waiting).
            let group = DispatchGroup(), lock = NSLock(); var urls: [(Int, URL)] = []
            for (index, provider) in providers.enumerated() {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { lock.lock(); urls.append((index, url)); lock.unlock() }
                    group.leave()
                }
            }
            group.notify(queue: .main) { model.add(urls.sorted { $0.0 < $1.0 }.map(\.1)) }
            return !providers.isEmpty
        }
        .overlay { if hovering { dropOverlay } }
        .alert("CueLevel", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .sheet(isPresented: $showSettings) { ShowSettingsSheet { showSettings = false }.environmentObject(model) }
        .sheet(isPresented: $model.showSavePreset) { presetSheet }
        .sheet(isPresented: $model.showAbout) { aboutSheet }
        .sheet(isPresented: $updater.showSheet) { updateSheet }
        .sheet(isPresented: $model.showShortcuts) { ShortcutSheet { model.showShortcuts = false } }
        .sheet(isPresented: Binding(get: { model.referenceDraft != nil }, set: { if !$0 { model.referenceDraft = nil } })) { referenceSheet }
        .background { Button("") { setEditing(!model.clipEditing) }.keyboardShortcut("e").opacity(0).disabled(!model.clipEditing && (model.selected?.analysis == nil || model.busy)) }
    }

    /// Prepare ↔ Edit. Leaving Edit levels the cue again when the edits changed what it would sound like.
    func setEditing(_ on: Bool) {
        guard on != model.clipEditing else { return }
        if on {
            guard model.selected?.analysis != nil else { return }
            model.clipEditing = true; model.switchPreview(false)
        } else {
            model.clipEditing = false; model.selectedRegion = nil
            if let job = model.selected, model.outputIsStale || (job.output == nil && !ClipGain.active(job.clipGain).isEmpty) {
                model.settings.format == .lossless ? model.quickLevelSelected() : model.processSelected()
            }
        }
    }

    var dropOverlay: some View {
        ZStack {
            Theme.base.opacity(0.86)
            RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.good, style: StrokeStyle(lineWidth: 2, dash: [8, 6])).padding(18)
            VStack(spacing: 12) {
                LogoMark(tile: true).frame(width: 84, height: 84)
                Text(model.quickLevel ? "Drop to level" : "Drop to add cues").font(.system(size: 24, weight: .semibold))
                Text(model.quickLevel ? "Levelled copies go to \(model.outputFolderDisplay)" : "Each file is measured as it arrives. Originals are never changed.").hint()
            }
        }.allowsHitTesting(false)
    }

    // MARK: Toolbar
    var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) { LogoMark().frame(width: 22, height: 22); Text("CueLevel").font(.system(size: 14.5, weight: .semibold)) }
                .onTapGesture(count: 2) { model.showAbout = true }.help("About CueLevel")
            Segments(options: [(false, "Prepare"), (true, "Edit")], selection: Binding(get: { model.clipEditing }, set: { setEditing($0) }))
                .frame(width: 168).disabled(!model.clipEditing && (model.selected?.analysis == nil || model.busy))   // leaving Edit is always allowed
                .help("Prepare levels cues. Edit opens the clip gain editor for the selected cue (⌘E).")
                .padding(.leading, 14)
            if let feed = updater.offered, updater.available != nil || updater.isWorking {
                Button { updater.showSheet = true } label: {
                    Label("CueLevel \(feed.version) is ready", systemImage: "arrow.down.circle.fill").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Theme.good.opacity(0.14))).foregroundStyle(Theme.good)
                }.buttonStyle(.plain).help("See what's new and install the update")
            }
            Spacer(minLength: 12)
            Toggle(isOn: Binding(get: { model.quickLevel }, set: { model.setQuickLevel($0) })) {
                Text("Level on drop").font(.system(size: 12.5)).foregroundStyle(model.quickLevel ? Theme.bone : Theme.muted)
            }.toggleStyle(CLSwitch()).disabled(model.busy)
                .help("When on, every file you drop is levelled straight into \(model.outputFolderDisplay)")
            Button { model.addFiles() } label: { Label("Add cues", systemImage: "plus") }.buttonStyle(CLButton(kind: .ghost))
            if model.busy && model.canCancel {
                Button { model.cancel() } label: { Label("Stop", systemImage: "stop.fill") }.buttonStyle(CLButton(kind: .danger)).keyboardShortcut(".")
            } else {
                let todo = model.jobs.filter { !CueStage($0).isDone || $0.output == nil }.count
                Button(model.jobs.isEmpty ? "Level all" : todo == 0 ? "All levelled" : "Level all \(todo)") { model.quickLevelAll() }.buttonStyle(CLButton())
                    .disabled(model.busy || todo == 0)
            }
            Menu {
                Button("Open the Levelled folder") { model.revealOutputFolder() }
                Button("Save a copy of every levelled cue…") { model.exportAll() }.disabled(model.completedCount == 0)
                Button("Save show report…") { model.exportShowReport() }.disabled(model.jobs.allSatisfy { $0.analysis == nil })
            } label: { Text("Deliver").foregroundStyle(Theme.bone) }.menuStyle(.borderlessButton).fixedSize().disabled(model.busy).tint(Theme.bone)
                .padding(.horizontal, 10).padding(.vertical, 5).background(RoundedRectangle(cornerRadius: 7).fill(Theme.raised)).overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line2))
        }
        .padding(.leading, 86).padding(.trailing, 16).frame(height: 52)
        .background(Theme.panel).overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    var statusBar: some View {
        HStack(spacing: 10) {
            Circle().fill(model.busy ? Theme.changed : Theme.good).frame(width: 7, height: 7)
            Text(model.status).lineLimit(1).foregroundStyle(Theme.text)
            if model.watching, let folder = model.watchFolder { Label("Watching \(folder.lastPathComponent)", systemImage: "eye").foregroundStyle(Theme.muted) }
            Spacer()
            Text("Space plays · ⌘L levels · ⌘/ shortcuts").foregroundStyle(Theme.dim)
            Text("Processing stays on this Mac").foregroundStyle(Theme.muted).padding(.leading, 10)
        }.font(.system(size: 11.5)).padding(.horizontal, 16).frame(height: 28)
        .background(Theme.panel).overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    // MARK: Cue list
    var visibleJobs: [CueJob] {
        model.jobs.filter { job in
            switch filter {
            case .all: return true
            case .attention: return CueStage(job).wantsAttention
            case .done: return CueStage(job).isDone
            }
        }
    }
    var cueList: some View {
        let attention = model.jobs.filter { CueStage($0).wantsAttention }.count
        let done = model.jobs.filter { CueStage($0).isDone }.count
        return VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Cues").sectionTitle()
                Text(model.jobs.isEmpty ? "None yet" : "\(model.jobs.count) cue\(model.jobs.count == 1 ? "" : "s"), \(done) done").font(.system(size: 12)).foregroundStyle(Theme.muted).monospacedDigit()
                Spacer()
                if !model.jobs.isEmpty {
                    Button { model.removeSelected() } label: { Image(systemName: "minus") }.buttonStyle(CLButton(kind: .ghost))
                        .help("Remove the selected cue from the list (the file stays where it is)").disabled(model.busy || model.selection == nil)
                }
            }.padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 10)
            if !model.jobs.isEmpty {
                HStack(spacing: 6) {
                    Chip(title: "All", selected: filter == .all) { filter = .all }
                    Chip(title: "Needs a look \(attention)", selected: filter == .attention) { filter = .attention }
                    Chip(title: "Done \(done)", selected: filter == .done) { filter = .done }
                    Spacer()
                }.padding(.horizontal, 16).padding(.bottom, 8)
            }
            ScrollView {
                LazyVStack(spacing: 0) { ForEach(visibleJobs) { job in cueRow(job, number: (model.jobs.firstIndex { $0.id == job.id } ?? 0) + 1) } }
            }
            dropHint.padding(14)
        }.background(Theme.panel)
        .onDeleteCommand { model.removeSelected() }
    }
    func cueRow(_ job: CueJob, number: Int) -> some View {
        let selected = model.selection == job.id
        let target = job.output?.settings.target ?? model.settings.target
        return HStack(alignment: .center, spacing: 10) {
            Text(String(format: "%02d", number)).font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.dim).frame(width: 20, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if job.analysis?.info.isVideo == true { Image(systemName: "film").font(.system(size: 10)).foregroundStyle(Theme.dim) }
                    Text(job.source.deletingPathExtension().lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                }
                if let analysis = job.analysis {
                    HStack(spacing: 8) {
                        Text(clockText(analysis.info.duration))
                        Text(lufs(job.output?.levels.integrated ?? analysis.levels.integrated) + " LUFS")
                    }.font(.system(size: 11.5)).foregroundStyle(Theme.muted).monospacedDigit()
                    MiniRuler(source: analysis.levels.integrated, output: job.output?.levels.integrated, target: target).frame(height: 8).padding(.top, 2)
                } else if CueStage(job) == .failed || CueStage(job) == .stopped {
                    Text(job.message).font(.system(size: 11.5)).foregroundStyle(CueStage(job) == .failed ? Theme.hot : Theme.muted).lineLimit(2)
                }
                if job.status == .working { ProgressView(value: job.progress).progressViewStyle(.linear).tint(Theme.bone).controlSize(.small) }
            }
            Spacer(minLength: 4)
            StageLabel(job: job)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(selected ? Theme.raised : Color.clear)
        .overlay(alignment: .leading) { if selected { Rectangle().fill(Theme.bone).frame(width: 3) } }
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
            Text("Drop audio or video").font(.system(size: 13, weight: .medium))
            Text(model.quickLevel ? "Levelled straight into \(model.outputFolderDisplay)" : "Each file is measured as it arrives. Originals are never changed.").hint().multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(14)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line2, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
        .onTapGesture { model.addFiles() }
    }

    // MARK: Stage
    var stage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let job = model.selected { cueStage(job) } else { emptyState }
            }.padding(.horizontal, 26).padding(.vertical, 22).frame(maxWidth: model.clipEditing ? .infinity : 1060, alignment: .leading).frame(maxWidth: .infinity)
        }.background(Theme.base)
    }
    @ViewBuilder func cueStage(_ job: CueJob) -> some View {
        header(job)
        if let analysis = job.analysis {
            if model.clipEditing {
                VStack(spacing: 12) {
                    ClipGainEditor(job: job, analysis: analysis)
                    transport(job)
                }.card(padding: 16)
            } else {
                LevelReadout(job: job, analysis: analysis, target: job.output?.settings.target ?? model.settings.target,
                             ceiling: model.settings.peak, peakLimit: model.settings.peakLimit, good: model.goodBand(target: job.output?.settings.target ?? model.settings.target))
                waveCard(job)
                checks(analysis)
                if model.outputIsStale, job.output != nil {
                    notice("Settings or edits have changed since this cue was levelled. Level it again to apply them.", tone: .changed)
                }
                details(job, analysis)
            }
        } else if job.status == .working {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text(job.message).font(.system(size: 13)).foregroundStyle(Theme.text); Spacer(); Text("\(Int(job.progress * 100))%").monospacedDigit().foregroundStyle(Theme.muted) }
                ProgressView(value: job.progress).tint(Theme.good)
            }.card()
        } else if job.status == .failed {
            notice(job.message, tone: job.message.localizedCaseInsensitiveContains("silent") ? .neutral : .hot)
        } else {
            notice(model.busy ? "Waiting to be measured. CueLevel will get to it when the current job finishes." : "Not measured yet. Select Measure now on the right.", tone: .neutral)
        }
    }
    func header(_ job: CueJob) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 14) {
            Text(job.source.deletingPathExtension().lastPathComponent).font(.system(size: 24, weight: .semibold)).tracking(-0.4).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            if let info = job.analysis?.info {
                Menu {
                    ForEach(ContentMode.allCases) { mode in
                        Button((mode == model.mode(for: job) ? "✓ " : "") + mode.label + (mode == model.settings.mode ? " (show setting)" : "")) { model.setCueMode(mode) }
                    }
                } label: {
                    HStack(spacing: 4) { Text(model.mode(for: job).label); Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)) }
                        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.bone)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tint(Theme.bone)
                .padding(.horizontal, 7).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 5).fill(job.mode == nil ? Theme.raised : Theme.changed.opacity(0.18)))
                .disabled(model.busy)
                .help("What kind of cue this is. Change it for a music bed in a voice show: music is never evened out.")
                HStack(spacing: 12) { ForEach(fileFacts(job.source, info), id: \.self) { Text($0) } }.font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
    func fileFacts(_ source: URL, _ info: MediaInfo) -> [String] {
        var parts = [clockText(info.duration), source.pathExtension.uppercased() + (info.sampleRate.map { String(format: " %g kHz", Double($0) / 1000) } ?? ""),
                     info.channels == 1 ? "mono" : info.channels == 2 ? "stereo" : "\(info.channels) channels"]
        if let tracks = info.audioStreams, tracks > 1 { parts.append("\(tracks) audio tracks") }
        if info.isVideo { parts.append(info.videoCodec.map { "video \($0.uppercased())" } ?? "video") }
        parts.append(ByteCountFormatter.string(fromByteCount: info.byteCount, countStyle: .file))
        return parts
    }

    func waveCard(_ job: CueJob) -> some View {
        let target = job.output?.settings.target ?? model.settings.target
        return VStack(spacing: 12) {
            HStack(spacing: 12) {
                Segments(options: [(false, "Original"), (true, "Levelled")], selection: Binding(get: { model.processedPreview }, set: { model.switchPreview($0) }))
                    .frame(width: 200).disabled(job.output == nil)
                    .help(job.output == nil ? "Level the cue to hear the result" : "Switch between the original and the levelled cue")
                Spacer()
                if !model.currentCurve.isEmpty {
                    HStack(spacing: 14) {
                        HStack(spacing: 6) { Capsule().fill(Theme.changed).frame(width: 14, height: 2); Text("Loudness over time") }
                        if model.goodBand(target: target) != nil {
                            HStack(spacing: 6) { RoundedRectangle(cornerRadius: 2).fill(Theme.good.opacity(0.25)).overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.good.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))).frame(width: 14, height: 8)
                                Text("Good range for \(model.mode(for: job).label)") }
                                .help("Where your good \(model.mode(for: job).label) cues sit over time. Loudness inside the band sounds like good material.")
                        }
                    }.font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
            Waveform(peaks: model.currentWaveform, curve: model.currentCurve, target: target, good: model.goodBand(target: target),
                     edits: model.processedPreview ? [] : ClipGain.active(job.clipGain), position: model.playhead, duration: model.duration, seek: model.seek)
            transport(job)
            if job.analysis?.info.isVideo == true {
                DisclosureGroup("Picture") { VideoPlayer(player: model.player).frame(height: 240).clipShape(RoundedRectangle(cornerRadius: 8)).padding(.top, 8) }
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text)
            }
        }.card(padding: 16)
    }
    func transport(_ job: CueJob) -> some View {
        HStack(spacing: 14) {
            Button { model.playPause() } label: {
                Image(systemName: model.playing ? "pause.fill" : "play.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.base)
                    .frame(width: 34, height: 34).background(Circle().fill(Theme.bone))
            }.buttonStyle(.plain).keyboardShortcut(.space, modifiers: []).accessibilityLabel(model.playing ? "Pause" : "Play")
            Text(clockText(model.playhead)).monospacedDigit()
            Slider(value: Binding(get: { min(model.duration, model.playhead) }, set: { model.seek($0) }), in: 0 ... max(0.01, model.duration)).controlSize(.small).accessibilityLabel("Playback position").disabled(model.duration == 0)
            Text(clockText(model.duration)).monospacedDigit()
            LoudnessMeterBar(reading: model.meterReading(at: model.playhead), target: job.output?.settings.target ?? model.settings.target, ready: !model.meterCurve.isEmpty)
                .frame(minWidth: 300, maxWidth: 380)
            Toggle("Match", isOn: $model.matchPreview).toggleStyle(.checkbox).onChange(of: model.matchPreview) { _ in model.applyVolume() }.disabled(job.output == nil)
                .help("Plays the original and levelled versions at equal loudness, so you compare sound, not volume")
        }.font(.system(size: 12)).foregroundStyle(Theme.muted)
    }

    /// Source checks as short pills; the full sentence is in the tooltip.
    func checks(_ analysis: Analysis) -> some View {
        let findings = analysis.sourceFindings
        func short(_ f: String) -> String {
            if f.contains("clipping") { return "Probable clipping" }
            if f.contains("DC offset") { return "DC offset" }
            if f.contains("out of phase") { return "Left and right out of phase" }
            if f.contains("identical") { return "Mono in a stereo file" }
            if f.contains("at the start") { return f.components(separatedBy: " of silence").first.map { "\($0) silence at the start" } ?? "Silence at the start" }
            if f.contains("at the end") { return f.components(separatedBy: " of silence").first.map { "\($0) silence at the end" } ?? "Silence at the end" }
            if f.contains("Surround") { return "Surround, will be downmixed" }
            if f.contains("audio tracks") { return f.components(separatedBy: ".").first ?? "Several audio tracks" }
            return f
        }
        var good: [String] = []
        if analysis.stereo != nil {
            if !findings.contains(where: { $0.contains("clipping") }) { good.append("No clipping") }
            if !findings.contains(where: { $0.contains("DC offset") }) { good.append("No DC offset") }
            if analysis.info.channels >= 2, !findings.contains(where: { $0.contains("out of phase") }) { good.append("Phase OK") }
        }
        let flow = FlowRow(spacing: 8)
        return flow {
            ForEach(findings, id: \.self) { pill(short($0), tone: .changed).help($0) }
            ForEach(good, id: \.self) { pill($0, tone: .good) }
            if analysis.stereo == nil { pill("Measure again for source checks", tone: .neutral) }
        }
    }
    func pill(_ text: String, tone: LevelTone) -> some View {
        HStack(spacing: 7) { Circle().fill(Theme.tone(tone)).frame(width: 7, height: 7); Text(text) }
            .font(.system(size: 12)).foregroundStyle(Theme.text)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
    }
    func notice(_ text: String, tone: LevelTone) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Circle().fill(Theme.tone(tone)).frame(width: 7, height: 7).padding(.top, 5)
            Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.tone(tone).opacity(0.07))).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.tone(tone).opacity(0.25)))
    }

    /// Measurements and the reference comparison, for anyone who wants the numbers.
    func details(_ job: CueJob, _ analysis: Analysis) -> some View {
        DisclosureGroup(isExpanded: $showDetails) {
            VStack(alignment: .leading, spacing: 14) {
                statsStrip(job, analysis)
                if let check = model.referenceCheck(for: job) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Against your references").font(.system(size: 13, weight: .semibold))
                        ForEach(check.findings, id: \.self) { f in
                            HStack(alignment: .top, spacing: 8) { Circle().fill(f.needsAttention ? Theme.changed : Theme.good).frame(width: 6, height: 6).padding(.top, 5); Text(f.text).hint() }
                        }
                    }
                } else if model.references.isEmpty {
                    Text("Import your good reference cues in Show settings to compare every cue with finished material.").hint()
                }
                HStack(spacing: 8) {
                    Button("Measure again") { model.analyze() }.buttonStyle(CLButton(kind: .ghost)).disabled(model.busy)
                    Button("Mark as good…") { model.beginAddingReference() }.buttonStyle(CLButton(kind: .ghost)).disabled(model.busy)
                    if job.output != nil { Button("Save cue report…") { model.saveReport() }.buttonStyle(CLButton(kind: .ghost)).disabled(model.busy) }
                }
            }.padding(.top, 10)
        } label: { Text("Measurements").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text) }
    }
    func statsStrip(_ job: CueJob, _ analysis: Analysis) -> some View {
        let output = job.output
        let ceiling = output?.settings.peak ?? model.settings.peak
        return HStack(spacing: 0) {
            stat("Integrated", value: output?.levels.integrated ?? analysis.levels.integrated, unit: "LUFS", was: output.map { _ in analysis.levels.integrated }, first: true)
            stat("True peak", value: output?.levels.truePeak ?? analysis.levels.truePeak, unit: "dBTP", was: output.map { _ in analysis.levels.truePeak })
            stat("Loudness range", value: output?.levels.loudnessRange ?? analysis.levels.loudnessRange, unit: "LU", was: output.map { _ in analysis.levels.loudnessRange })
            stat("Peak to average", value: output?.levels.crestFactor ?? analysis.levels.crestFactor, unit: "dB", was: output == nil ? nil : analysis.levels.crestFactor)
            stat("Headroom", value: ceiling - (output?.levels.truePeak ?? analysis.levels.truePeak), unit: "dB", note: "to the \(lufs(ceiling)) ceiling")
        }.card(padding: 0)
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
        .padding(.horizontal, 14).padding(.vertical, 12)
        .overlay(alignment: .leading) { if !first { Rectangle().fill(Theme.line).frame(width: 1) } }
    }

    // MARK: Empty state (first run)
    var emptyState: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 60)
            LogoMark(tile: true).frame(width: 104, height: 104)
            VStack(spacing: 8) {
                Text("Level your show's cues").font(.system(size: 28, weight: .semibold)).tracking(-0.5)
                Text("Every cue comes out at the same loudness on the PA, with nothing else about it changed.").font(.system(size: 14)).foregroundStyle(Theme.muted)
            }
            HStack(alignment: .top, spacing: 14) {
                step(1, "Add your cues", "Drop audio or video anywhere in this window. Each file is measured as it arrives.")
                step(2, "Check the plan", "CueLevel shows what it would change and why, compared with cues you've marked as good.")
                step(3, "Level and deliver", "Levelled copies land in \(model.outputFolderDisplay), ready for playback.")
            }.frame(maxWidth: 820)
            HStack(spacing: 10) {
                Button { model.addFiles() } label: { Label("Add cues…", systemImage: "plus") }.buttonStyle(CLButton(kind: .primary))
                Button("Show settings…") { showSettings = true }.buttonStyle(CLButton())
            }
            Text("WAV, AIFF, MP3, M4A, FLAC, MP4, MOV and most other audio and video files. Originals are never changed.").hint()
            Spacer(minLength: 40)
        }.frame(maxWidth: .infinity)
    }
    func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(n)").font(.readout(15)).foregroundStyle(Theme.onGood).frame(width: 26, height: 26).background(Circle().fill(Theme.good))
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(detail).hint()
        }.card(padding: 16).frame(maxWidth: .infinity, alignment: .topLeading)
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
                LogoMark(tile: true).frame(width: 60, height: 60)
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
                    Text("What's new").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.bone)
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
            Text("Mark as a good cue").font(.system(size: 18, weight: .semibold))
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
            Segments(options: ContentMode.allCases.map { ($0, $0.label) }, selection: $model.referenceDraftCategory)
            TextField("Note (optional), e.g. \"walk-in music, sounded right at desk gain\"", text: $model.referenceDraftNote).textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { model.referenceDraft = nil }.buttonStyle(CLButton(kind: .ghost))
                Spacer()
                Button("Add to references") { model.addReference() }.buttonStyle(CLButton(kind: .primary)).keyboardShortcut(.defaultAction).disabled(model.busy || job?.analysis == nil)
            }
        }.padding(24).frame(width: 480).background(Theme.panel).preferredColorScheme(.dark)
    }
    var aboutSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) { LogoMark(tile: true).frame(width: 60, height: 60); VStack(alignment: .leading, spacing: 3) { Text("CueLevel \(appShortVersion)").font(.system(size: 20, weight: .semibold)); Text("Lossless loudness levelling for event playback").hint() } }
            Text("All processing happens on this Mac. CueLevel never uploads your files and collects no data. Originals are never modified.").font(.system(size: 13)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: $updater.autoCheck) { Text("Check for updates automatically").font(.system(size: 12.5)).foregroundStyle(Theme.text).frame(maxWidth: .infinity, alignment: .leading) }.toggleStyle(CLSwitch())
            Text("When on, CueLevel reads one small public version file on GitHub at launch and twice a day. Nothing about you or your files is sent.").hint()
            Text("Includes FFmpeg and the RNNoise speech model. Their licences, source locations and build details are in the Third-party notices that ship with CueLevel.").hint()
            HStack { Link("FFmpeg licensing", destination: URL(string: "https://ffmpeg.org/legal.html")!).font(.system(size: 12.5)); Spacer(); Button("Done") { model.showAbout = false }.buttonStyle(CLButton(kind: .primary)).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 480).background(Theme.panel).preferredColorScheme(.dark)
    }
}

// MARK: - Components

/// The signature readout: where the cue is now, where it lands, and the target, on one −40…0 LUFS ruler.
struct LevelReadout: View {
    let job: CueJob
    let analysis: Analysis
    let target: Double
    let ceiling: Double
    let peakLimit: Double?
    let good: ClosedRange<Double>?
    var body: some View {
        let source = analysis.levels.integrated
        let plan = LosslessPlan(levels: analysis.levels, target: target, ceiling: ceiling, maxLimiting: peakLimit ?? 0)
        let landed = job.output?.levels.integrated
        let after = landed ?? (source + plan.gain)
        let sourceTone = levelTone(source, target: target)
        let afterTone: LevelTone = levelTone(after, target: target) == .good ? .good : .changed
        HStack(alignment: .center, spacing: 30) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(lufs(source)).font(.readout(28, weight: .medium)).foregroundStyle(Theme.tone(sourceTone)).monospacedDigit()
                    Text("Now").font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Image(systemName: "arrow.right").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.dim)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(lufs(after)).font(.readout(44)).foregroundStyle(Theme.tone(afterTone).opacity(landed == nil ? 0.75 : 1)).monospacedDigit()
                        Text("LUFS").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted)
                    }
                    Text(caption(plan: plan, landed: landed)).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }.fixedSize()
            LevelRuler(source: source, after: after, landed: landed != nil, target: target, good: good).frame(height: 62)
        }.card(padding: 20)
        .accessibilityElement().accessibilityLabel("Loudness now \(lufs(source)) LUFS, \(landed == nil ? "after levelling" : "levelled") \(lufs(after)) LUFS, target \(lufs(target))")
    }
    func caption(plan: LosslessPlan, landed: Double?) -> String {
        if job.alreadyGood != nil { return "Already good, left as it is" }
        if let output = job.output, let landed {
            let gain = output.gainApplied ?? (landed - analysis.levels.integrated)
            return "Levelled, \(signed(gain)) dB"
        }
        if plan.shortfall > 0.05 { return "After levelling, \(signed(plan.gain)) dB (peaks keep it \(String(format: "%.1f", plan.shortfall)) dB under)" }
        return abs(plan.gain) < 0.05 ? "Already on target" : "After levelling, \(signed(plan.gain)) dB"
    }
}

struct LevelRuler: View {
    let source: Double
    let after: Double
    let landed: Bool
    let target: Double
    let good: ClosedRange<Double>?
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x: (Double) -> CGFloat = { CGFloat(Theme.position($0)) * w }
            ZStack(alignment: .topLeading) {
                Capsule().fill(Theme.meter).opacity(0.22).frame(width: w, height: 8).offset(y: 24)
                if let good {
                    RoundedRectangle(cornerRadius: 5).fill(Theme.good.opacity(0.10))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.good.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                        .frame(width: max(6, x(good.upperBound) - x(good.lowerBound)), height: 18).offset(x: x(good.lowerBound), y: 19)
                        .help("Where your good references sit")
                }
                Capsule().fill(LinearGradient(colors: [Theme.tone(levelTone(source, target: target)), Theme.good], startPoint: source < after ? .leading : .trailing, endPoint: source < after ? .trailing : .leading))
                    .frame(width: max(4, abs(x(after) - x(source))), height: 4).offset(x: min(x(source), x(after)), y: 26)
                Rectangle().fill(Theme.bone).frame(width: 2, height: 38).offset(x: x(target) - 1, y: 9)
                Text("Target \(lufs(target))").font(.system(size: 11, weight: .semibold)).fixedSize().position(x: x(target), y: 0)
                dot(Theme.tone(levelTone(source, target: target)), filled: true).offset(x: x(source) - 9, y: 19)
                dot(Theme.good, filled: landed).offset(x: x(after) - 9, y: 19)
                ForEach([-40, -30, -20, -10, 0], id: \.self) { v in
                    Text(lufs(Double(v)).replacingOccurrences(of: ".0", with: "")).font(.system(size: 10.5)).foregroundStyle(Theme.dim).monospacedDigit().fixedSize()
                        .position(x: min(w - 8, max(8, x(Double(v)))), y: 54)
                }
            }
        }
    }
    func dot(_ color: Color, filled: Bool) -> some View {
        Circle().fill(filled ? color : Theme.base).frame(width: 18, height: 18)
            .overlay(Circle().stroke(filled ? Theme.base : color, lineWidth: filled ? 3 : 2.5))
    }
}

/// A cue's loudness in the list: a dot on a thin track, with the target as a tick.
struct MiniRuler: View {
    let source: Double
    let output: Double?
    let target: Double
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x: (Double) -> CGFloat = { CGFloat(Theme.position($0)) * w }
            let value = output ?? source
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line).frame(height: 3)
                if let output { Capsule().fill(Theme.good.opacity(0.35)).frame(width: max(2, abs(x(output) - x(source))), height: 3).offset(x: min(x(source), x(output))) }
                Rectangle().fill(Theme.bone.opacity(0.55)).frame(width: 1.5, height: 9).offset(x: x(target))
                Circle().fill(output != nil ? Theme.good : Theme.tone(levelTone(value, target: target))).frame(width: 8, height: 8).offset(x: x(value) - 4)
            }
        }
    }
}

/// Wraps its children onto new lines (for the source-check pills).
struct FlowRow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 800
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing; line = max(line, size.height)
        }
        return CGSize(width: width, height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; line = max(line, size.height)
        }
    }
}

/// Waveform with loudness over time, the good range band and (in Original) the edited sections.
struct Waveform: View {
    let peaks: [Float]
    var curve: [Float] = []
    var target: Double? = nil
    var good: ClosedRange<Double>? = nil
    var edits: [GainRegion] = []
    let position: Double
    let duration: Double
    let seek: (Double) -> Void
    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let middle = size.height / 2
                func y(_ value: Double) -> Double { size.height * (1 - (max(-60, min(0, value)) + 60) / 60) }
                if let good, curve.count > 1 {
                    let band = CGRect(x: 0, y: y(good.upperBound), width: size.width, height: max(2, y(good.lowerBound) - y(good.upperBound)))
                    context.fill(Path(band), with: .color(Theme.good.opacity(0.08)))
                    var edges = Path()
                    edges.move(to: CGPoint(x: 0, y: band.minY)); edges.addLine(to: CGPoint(x: size.width, y: band.minY))
                    edges.move(to: CGPoint(x: 0, y: band.maxY)); edges.addLine(to: CGPoint(x: size.width, y: band.maxY))
                    context.stroke(edges, with: .color(Theme.good.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
                }
                if duration > 0 {
                    for r in edits {
                        let rect = CGRect(x: r.start / duration * size.width, y: 0, width: max(2, r.length / duration * size.width), height: size.height)
                        context.fill(Path(rect), with: .color(Theme.changed.opacity(0.07)))
                        var e = Path(); e.move(to: CGPoint(x: rect.minX, y: 0)); e.addLine(to: CGPoint(x: rect.minX, y: size.height)); e.move(to: CGPoint(x: rect.maxX, y: 0)); e.addLine(to: CGPoint(x: rect.maxX, y: size.height))
                        context.stroke(e, with: .color(Theme.changed.opacity(0.45)), lineWidth: 1)
                        if rect.width > 60 {
                            context.draw(Text(r.muted == true ? "Muted" : signed(r.gain) + " dB").font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.changed), at: CGPoint(x: rect.minX + 6, y: 12), anchor: .leading)
                        }
                    }
                }
                if !peaks.isEmpty {
                    // 2.0.1: one bar per pixel column at most, drawn as a filled envelope (thin bars on a fractional grid made moiré stripes).
                    let columns = max(1, min(peaks.count, Int(size.width)))
                    let width = size.width / Double(columns)
                    var top: [CGPoint] = [], baseTop: [CGPoint] = []
                    var anyEdit = false
                    for c in 0..<columns {
                        let lo = c * peaks.count / columns, hi = max(lo + 1, (c + 1) * peaks.count / columns)
                        let peak = Double(peaks[lo..<min(hi, peaks.count)].max() ?? 0)
                        let t = (Double(c) + 0.5) / Double(columns) * duration
                        let m = edits.isEmpty ? 1 : ClipGain.multiplier(at: t, regions: edits)
                        if m != 1 { anyEdit = true }
                        let x = (Double(c) + 0.5) * width
                        top.append(CGPoint(x: x, y: middle - max(0.75, min(1, pow(peak * m, 0.6)) * (middle - 8))))
                        baseTop.append(CGPoint(x: x, y: middle - max(0.75, min(1, pow(peak, 0.6)) * (middle - 8))))
                    }
                    func envelope(_ points: [CGPoint]) -> Path {
                        var p = Path(); guard let first = points.first else { return p }
                        p.move(to: CGPoint(x: 0, y: first.y)); points.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: size.width, y: points.last!.y))
                        p.addLine(to: CGPoint(x: size.width, y: 2 * middle - points.last!.y))
                        points.reversed().forEach { p.addLine(to: CGPoint(x: $0.x, y: 2 * middle - $0.y)) }
                        p.addLine(to: CGPoint(x: 0, y: 2 * middle - first.y)); p.closeSubpath(); return p
                    }
                    if anyEdit { context.fill(envelope(baseTop), with: .color(Theme.muted.opacity(0.22))) }
                    context.fill(envelope(top), with: .color(Theme.bone.opacity(0.82)))
                }
                if curve.count > 1 {
                    if let target {
                        var line = Path(); line.move(to: CGPoint(x: 0, y: y(target))); line.addLine(to: CGPoint(x: size.width, y: y(target)))
                        context.stroke(line, with: .color(Theme.bone.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                    // The first ~3 s have no short-term reading yet (shown as the -70 floor); start the line at the first real value.
                    let first = curve.firstIndex { $0 > -69.9 } ?? 0
                    var trace = Path()
                    for index in first..<curve.count {
                        let point = CGPoint(x: Double(index) / Double(curve.count - 1) * size.width, y: y(Double(curve[index])))
                        if index == first { trace.move(to: point) } else { trace.addLine(to: point) }
                    }
                    context.stroke(trace, with: .color(Theme.changed), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                }
                let x = duration > 0 ? min(1, max(0, position / duration)) * size.width : 0
                var cursor = Path(); cursor.move(to: CGPoint(x: x, y: 0)); cursor.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(cursor, with: .color(Theme.bone), lineWidth: 1.5)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in if duration > 0 { seek(min(1, max(0, value.location.x / geometry.size.width)) * duration) } })
            .overlay { if peaks.isEmpty { Text("Measure the cue to draw its waveform").hint() } }
        }.frame(height: 230)
        .accessibilityLabel("Waveform with loudness over time. Use the playback position slider to seek.")
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

/// Files opened from Finder ("Open With", or dropped on the Dock icon) are handed to the window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var pending: [URL] = []
    static let opened = Notification.Name("CueLevelOpenedFiles")
    func application(_ application: NSApplication, open urls: [URL]) {
        AppDelegate.pending += urls
        NotificationCenter.default.post(name: AppDelegate.opened, object: nil)
    }
}

@main struct CueLevelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
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
                .onReceive(NotificationCenter.default.publisher(for: AppDelegate.opened).receive(on: RunLoop.main).prepend(Notification(name: AppDelegate.opened))) { _ in
                    let urls = AppDelegate.pending; AppDelegate.pending = []
                    if !urls.isEmpty { model.add(urls) }
                }
        }.defaultSize(width: 1440, height: 900).windowStyle(.hiddenTitleBar)
            .commands {
                CommandGroup(replacing: .appInfo) {
                    Button("About CueLevel") { model.showAbout = true }
                    Button("Check for Updates…") { Task { await updater.check(userInitiated: true) } }.disabled(!updater.canCheck)
                }
                CommandGroup(after: .newItem) { Button("Add Cues…") { model.addFiles() }.keyboardShortcut("o") }
                CommandGroup(replacing: .help) { Button("Keyboard Shortcuts") { model.showShortcuts = true }.keyboardShortcut("/", modifiers: .command) }
                CommandGroup(replacing: .undoRedo) {
                    Button("Undo") { if model.clipEditing { model.undoRegions() } else { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) } }.keyboardShortcut("z")
                    Button("Redo") { if model.clipEditing { model.redoRegions() } else { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) } }.keyboardShortcut("z", modifiers: [.command, .shift])
                }
            }
    }
}



/// Keyboard shortcuts, laid out like a cheat sheet for training.
struct ShortcutSheet: View {
    let close: () -> Void
    let groups: [(String, [(String, String)])] = [
        ("Playback", [("Space", "Play / pause"), ("⌘L", "Level the selected cue"), ("⌘E", "Switch between Prepare and Edit"), ("P", "Play section or in–out range with pre/post-roll"), ("L", "Loop on / off")]),
        ("Clip gain editor", [("Drag across", "Mark a section"), ("Drag up / down", "Change a section's level"), ("↑ / ↓", "Nudge 0.5 dB"), ("⇧↑ / ⇧↓", "Nudge 3 dB"), ("M", "Mute the selected section"), ("Return", "Add a marker at the playhead")]),
        ("Cue edges", [("I", "Set in point at the playhead"), ("O", "Set out point at the playhead"), ("Drag IN / OUT", "Move the in or out point on the ruler")]),
        ("View", [("T / R", "Zoom in / out"), ("⌥-scroll or pinch", "Zoom around the pointer"), ("Scroll", "Move along the cue when zoomed")]),
        ("Edit", [("⌘Z / ⇧⌘Z", "Undo / redo"), ("⌘O", "Add files"), ("⌘/", "This list")]),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Keyboard shortcuts").font(.system(size: 18, weight: .semibold)); Spacer(); Button("Done", action: close).buttonStyle(CLButton(kind: .primary)).keyboardShortcut(.defaultAction) }
            HStack(alignment: .top, spacing: 28) {
                ForEach(0..<2, id: \.self) { column in
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(groups.enumerated()).filter { $0.offset % 2 == column }.map(\.element), id: \.0) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(group.0).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.muted)
                                ForEach(group.1, id: \.0) { item in
                                    HStack(spacing: 10) {
                                        Text(item.0).font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundStyle(Theme.bone)
                                            .padding(.horizontal, 7).padding(.vertical, 3).background(RoundedRectangle(cornerRadius: 5).fill(Theme.raised)).overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line))
                                        Text(item.1).font(.system(size: 12.5)).foregroundStyle(Theme.text)
                                    }
                                }
                            }
                        }
                    }.frame(width: 300, alignment: .leading)
                }
            }
            Text("Single-key shortcuts work while the clip gain editor is open and you aren't typing in a field.").hint()
        }.padding(26).background(Theme.panel).preferredColorScheme(.dark)
    }
}
