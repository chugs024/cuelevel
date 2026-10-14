import SwiftUI

// One cue: where it is now, what CueLevel will do (or did), and how it sounds before and after.

struct CueDetailView: View {
    @EnvironmentObject var store: CueStore
    @EnvironmentObject var pro: ProStore
    @StateObject private var player = CuePlayer()
    let id: UUID
    @State private var showPicture = false
    @State private var showMeasurements = false
    @State private var showEditor = false
    @State private var showPro = false

    var body: some View {
        if let cue = store.cue(id) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(cue)
                    if let a = cue.analysis {
                        readoutCard(cue, a)
                        waveCard(cue, a)
                        if cue.isVideo {
                            DisclosureGroup(isExpanded: $showPicture) {
                                PictureView(player: player.player).aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
                            } label: { Text("Picture").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.bone) }
                            .tint(Theme.muted)
                        }
                        FlowRow { ForEach(checkPills(a), id: \.0) { CheckPill(text: $0.0, ok: $0.1) } }
                        if cue.output != nil { ResultCard(cue: cue, player: player) } else { PlanCard(cue: cue) }
                        measurements(cue, a)
                    } else {
                        waiting(cue)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.base.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { load(cue) }
            .onChange(of: cue.outputName) { load(store.cue(id) ?? cue) }
            .onChange(of: id) { load(store.cue(id) ?? cue) }
            .onDisappear { player.pause() }
            .onChange(of: store.openEditorFor) { if store.openEditorFor == id { store.openEditorFor = nil; openEditor() } }
            .fullScreenCover(isPresented: $showEditor) {
                if let c = store.cue(id), c.analysis != nil { CueEditorView(store: store, cue: c).environmentObject(store) }
            }
            .sheet(isPresented: $showPro) { ProView(onUnlocked: { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { showEditor = true } }).environmentObject(pro) }
        }
    }
    /// Pro opens the editor; otherwise the Pro sheet explains what it adds.
    func openEditor() { player.pause(); if pro.isPro { showEditor = true } else { showPro = true } }

    private func load(_ cue: MobileCue) {
        player.load(original: store.originalURL(cue), levelled: store.outputURL(cue), gain: cue.output?.gainApplied ?? 0,
                    duration: cue.analysis?.info.duration ?? 0)
    }

    // MARK: Header
    func header(_ cue: MobileCue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(cue.name).font(.system(size: 24, weight: .semibold)).foregroundStyle(Theme.bone).lineLimit(2)
            HStack(spacing: 10) {
                Menu {
                    Picker("Content", selection: Binding(get: { store.mode(for: cue) }, set: { store.setMode(cue.id, $0) })) {
                        ForEach([ContentMode.voice, .mixed, .music], id: \.self) { Text($0.label).tag($0) }
                    }
                } label: {
                    HStack(spacing: 5) { Image(systemName: store.mode(for: cue).symbol); Text(store.mode(for: cue).label); Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)) }
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.bone)
                        .padding(.horizontal, 10).padding(.vertical, 6).background(Capsule().fill(Theme.raised))
                }
                .accessibilityLabel("Content type")
                if let a = cue.analysis {
                    Text(meta(a)).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
        }
    }
    func meta(_ a: Analysis) -> String {
        let kind = (a.info.audioDescription.components(separatedBy: ",").first ?? "").replacingOccurrences(of: "pcm_", with: "PCM ").uppercased()
        let rate = a.info.sampleRate.map { String(format: "%g kHz", Double($0) / 1000) } ?? ""
        let size = ByteCountFormatter.string(fromByteCount: a.info.byteCount, countStyle: .file)
        return [clock(a.info.duration), kind, rate, a.info.channels == 1 ? "mono" : a.info.channels == 2 ? "stereo" : "\(a.info.channels) ch", size].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: Readout
    func readoutCard(_ cue: MobileCue, _ a: Analysis) -> some View {
        let target = store.settings.target
        let plan = store.plan(for: cue)
        let after: Double? = cue.output?.levels.integrated ?? plan?.predictedLoudness
        let note: String = {
            if let out = cue.output {
                if cue.state == .alreadyGood { return "Already good, left as it is" }
                return "Levelled, " + dbText(out.gainApplied ?? 0) + " dB"
            }
            return "After levelling"
        }()
        return Card {
            VStack(alignment: .leading, spacing: 14) {
                LevelReadout(now: a.levels.integrated, after: after, target: target, note: note)
                LevelRuler(now: a.levels.integrated, after: after, target: target)
                HStack {
                    Text("Target \(lufsText(target))").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.bone)
                    Spacer()
                    Text("Peak \(lufsText(cue.output?.levels.truePeak ?? a.levels.truePeak)) dBTP").font(.system(size: 12.5).monospacedDigit()).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    // MARK: Waveform and playback
    func waveCard(_ cue: MobileCue, _ a: Analysis) -> some View {
        let levelled = player.showingLevelled && cue.output != nil
        let peaks = levelled ? (cue.output?.waveform ?? a.waveform) : a.waveform
        let curve = levelled ? (cue.output?.loudnessCurve ?? a.loudnessCurve) : a.loudnessCurve
        let band = store.library.span(for: store.mode(for: cue))?.shape.map { (store.settings.target + $0.lowerBound) ... (store.settings.target + $0.upperBound) }
        return Card(padding: 12) {
            VStack(alignment: .leading, spacing: 12) {
                if cue.output != nil {
                    Picker("Version", selection: Binding(get: { player.showingLevelled }, set: { player.showLevelled($0) })) {
                        Text("Original").tag(false); Text("Levelled").tag(true)
                    }.pickerStyle(.segmented)
                }
                WaveformView(peaks: peaks, curve: curve, band: band, sections: levelled ? [] : (cue.autoRegions ?? []),
                             duration: a.info.duration, playhead: player.time > 0 ? player.time : nil)
                    .frame(height: 150)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.field))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(GeometryReader { geo in
                        Color.clear.contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                                player.seek(max(0, min(1, v.location.x / geo.size.width)) * a.info.duration)
                            })
                    })
                HStack(spacing: 14) {
                    Button { player.toggle() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Theme.base).frame(width: 46, height: 46).background(Circle().fill(Theme.bone))
                    }
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(clock(player.time)) / \(clock(a.info.duration))").font(.system(size: 14).monospacedDigit()).foregroundStyle(Theme.text)
                        Text(levelled ? "Levelled copy" : "Original").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    if cue.output != nil {
                        Toggle(isOn: Binding(get: { player.match }, set: { player.setMatch($0) })) {
                            Text("Match").font(.system(size: 14)).foregroundStyle(Theme.text)
                        }
                        .toggleStyle(.switch).fixedSize()
                        .accessibilityHint("Plays both versions at the same loudness so you compare the sound, not the volume")
                    }
                }
                HStack(spacing: 14) {
                    legend(Theme.changed, "Loudness over time")
                    if band != nil { legend(Theme.good.opacity(0.5), "Good range for \(store.mode(for: cue).label)") }
                }
                Button { openEditor() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "slider.vertical.3")
                        Text(cue.handEdited ? "Edit your changes" : "Edit by hand")
                        Spacer()
                        if !pro.isPro {
                            Text("Pro").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.onGood)
                                .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(Theme.good))
                        }
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.dim)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(CLButton(kind: .secondary))
                .disabled(cue.state == .levelling || cue.state == .measuring)
                .accessibilityHint("Fader, clip gain sections, trims and fades")
            }
        }
    }
    func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 14, height: 4); Text(text).font(.system(size: 12)).foregroundStyle(Theme.muted) }
    }

    // MARK: Waiting, measuring, failed
    func waiting(_ cue: MobileCue) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                switch cue.state {
                case .failed:
                    Label("Can't level", systemImage: "exclamationmark.triangle.fill").font(.system(size: 17, weight: .semibold)).foregroundStyle(cue.message.contains("silent") ? Theme.muted : Theme.hot)
                    Text(cue.message).font(.system(size: 15)).foregroundStyle(Theme.text)
                    Button(role: .destructive) { store.remove([cue.id]) } label: { Text("Remove from the list") }.buttonStyle(CLButton(kind: .secondary))
                case .measuring:
                    Text("Measuring…").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.bone)
                    ProgressView(value: store.progress[cue.id] ?? 0).tint(Theme.good)
                    Text("Loudness, true peak, silence and phase. This takes a few seconds per minute of audio.").font(.system(size: 14)).foregroundStyle(Theme.muted)
                default:
                    Text("Waiting to be measured").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.bone)
                    Text("Cues are measured one at a time, in list order.").font(.system(size: 14)).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    // MARK: Measurements
    func measurements(_ cue: MobileCue, _ a: Analysis) -> some View {
        DisclosureGroup(isExpanded: $showMeasurements) {
            VStack(spacing: 8) {
                row("Integrated loudness", "\(lufsText(a.levels.integrated)) LUFS")
                row("True peak", "\(lufsText(a.levels.truePeak)) dBTP")
                row("Loudness range", String(format: "%.1f LU", a.levels.loudnessRange))
                if let p = a.levels.samplePeak { row("Sample peak", "\(lufsText(p)) dBFS") }
                if let c = a.levels.crestFactor { row("Crest factor", String(format: "%.1f dB", c)) }
                if let s = a.stereo?.correlation { row("Stereo correlation", String(format: "%.2f", s)) }
                if let out = cue.output {
                    Divider().overlay(Theme.line)
                    row("Levelled loudness", "\(lufsText(out.levels.integrated)) LUFS")
                    row("Levelled true peak", "\(lufsText(out.levels.truePeak)) dBTP")
                    row("Gain", "\(dbText(out.gainApplied ?? 0)) dB")
                }
            }.padding(.top, 8)
        } label: { Text("Measurements").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.bone) }
        .tint(Theme.muted)
    }
    func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(Theme.muted); Spacer(); Text(v).foregroundStyle(Theme.bone).monospacedDigit() }.font(.system(size: 14))
    }
}

/// What CueLevel will do to this cue, step by step, each with its reason. Steps with a switch can be skipped.
struct PlanCard: View {
    @EnvironmentObject var store: CueStore
    let cue: MobileCue
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Text("What CueLevel will do").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.bone)
                if let plan = store.plan(for: cue) {
                    if let good = plan.looksGood {
                        Text("Already good: \(good).").font(.system(size: 14)).foregroundStyle(Theme.good)
                    }
                    ForEach(plan.steps) { step in
                        HStack(alignment: .top, spacing: 12) {
                            Button { if let c = step.control { store.toggle(c, for: cue.id) } } label: {
                                Image(systemName: step.control == nil ? (step.isOn ? "arrow.up.arrow.down.circle.fill" : "minus.circle") : (step.isOn ? "checkmark.square.fill" : "square"))
                                    .font(.system(size: 20)).foregroundStyle(step.isOn ? Theme.good : Theme.dim)
                            }
                            .buttonStyle(.plain).disabled(step.control == nil)
                            .accessibilityLabel(step.title).accessibilityValue(step.isOn ? "On" : "Off")
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(step.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(step.isOn ? Theme.bone : Theme.muted)
                                    Spacer()
                                    if let v = step.value { Text(v).font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.tone(step.tone)) }
                                }
                                Text(step.detail).font(.system(size: 13.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    VStack(spacing: 6) {
                        line("Loudness", "\(lufsText(plan.predictedLoudness)) LUFS")
                        line("Loudest peak", "\(lufsText(plan.predictedPeak)) dBTP")
                        if let s = plan.spread {
                            line("Evenness", String(format: "%.1f LU", s) + (plan.goodSpread.map { String(format: " (good %.1f–%.1f)", $0.lowerBound, $0.upperBound) } ?? ""),
                                 tone: plan.goodSpread.map { s > $0.upperBound + 1 ? Theme.changed : Theme.bone } ?? Theme.bone)
                        }
                    }
                    .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Theme.field))
                    if cue.state == .levelling {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: store.progress[cue.id] ?? 0).tint(Theme.good)
                            Text(store.progressLabel[cue.id] ?? "Levelling…").font(.system(size: 13)).foregroundStyle(Theme.muted)
                        }
                    } else {
                        Button { store.level([cue.id]) } label: { Text("Level this cue") }.buttonStyle(CLButton(kind: .hero))
                            .disabled(store.busy && store.cues.contains { $0.state == .levelling })
                    }
                }
            }
        }
    }
    func line(_ k: String, _ v: String, tone: Color = Theme.bone) -> some View {
        HStack { Text(k).foregroundStyle(Theme.muted); Spacer(); Text(v).foregroundStyle(tone).monospacedDigit() }.font(.system(size: 14, weight: .medium))
    }
}

/// What CueLevel did, the saved file, and how to compare and share it.
struct ResultCard: View {
    @EnvironmentObject var store: CueStore
    let cue: MobileCue
    @ObservedObject var player: CuePlayer
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: cue.state == .needsLook ? "exclamationmark.circle.fill" : "checkmark.seal.fill")
                        .foregroundStyle(cue.state == .needsLook ? Theme.changed : Theme.good)
                    Text(cue.state == .needsLook ? "Levelled, with notes" : cue.stage.title).font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.bone)
                }
                .font(.system(size: 20))
                if let good = cue.alreadyGood {
                    Text(good).font(.system(size: 14)).foregroundStyle(Theme.muted)
                    Text("Nothing was changed. An exact copy was saved so the folder has every cue.").font(.system(size: 14)).foregroundStyle(Theme.muted)
                }
                if let out = cue.output, cue.alreadyGood == nil {
                    let regions = cue.autoRegions ?? []
                    if cue.handEdited {
                        let n = ClipGain.active(cue.manualRegions).count
                        done("Your edits", (n == 0 ? "No sections" : "\(n) section\(n == 1 ? "" : "s")") + (cue.fader != nil ? ", level set on the fader" : ", automatic level"), nil)
                    } else if !regions.isEmpty {
                        done("Evened out \(regions.count) stretch\(regions.count == 1 ? "" : "es")",
                             regions.prefix(3).map { "\(clock($0.start))–\(clock($0.end)) \(dbText($0.gain)) dB" }.joined(separator: ", ") + (regions.count > 3 ? "…" : ""), nil)
                    } else if cue.evenOutSkipped == true {
                        done("Not evened out", "This cue plays continuously like music, so its loud and quiet parts were kept.", nil, on: false)
                    }
                    done("Gain", cue.fader != nil ? "Set on the fader" : out.shortfall.map { $0 > 0.05 ? "Kept \(dbText($0, signed: false)) dB under the target so peaks stay under the ceiling" : "One exact change" } ?? "One exact change",
                         dbText(out.gainApplied ?? 0) + " dB")
                    ForEach(out.warnings.filter { !$0.hasPrefix("Kept ") }, id: \.self) { w in
                        Label { Text(w).font(.system(size: 13.5)).foregroundStyle(Theme.text) } icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.changed) }
                    }
                }
                if let out = cue.output {
                    VStack(spacing: 6) {
                        HStack { Text("Loudness").foregroundStyle(Theme.muted); Spacer(); Text("\(lufsText(out.levels.integrated)) LUFS").foregroundStyle(Theme.bone).monospacedDigit() }
                        HStack { Text("Loudest peak").foregroundStyle(Theme.muted); Spacer(); Text("\(lufsText(out.levels.truePeak)) dBTP").foregroundStyle(Theme.bone).monospacedDigit() }
                    }
                    .font(.system(size: 14, weight: .medium)).padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Theme.field))
                }
                if let url = store.outputURL(cue) {
                    HStack(spacing: 10) {
                        Image(systemName: "doc").foregroundStyle(Theme.muted)
                        Text(url.lastPathComponent).font(.system(size: 14)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up").font(.system(size: 14, weight: .semibold)) }.tint(Theme.good)
                    }
                    .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Theme.field))
                }
                HStack(spacing: 10) {
                    Button { player.showLevelled(!player.showingLevelled); if !player.isPlaying { player.play() } } label: {
                        Label("Before / after", systemImage: "arrow.left.arrow.right").frame(maxWidth: .infinity)
                    }.buttonStyle(CLButton(kind: .secondary))
                    Button { store.level([cue.id]) } label: { Label("Level again", systemImage: "arrow.clockwise").frame(maxWidth: .infinity) }
                        .buttonStyle(CLButton(kind: .secondary)).disabled(cue.state == .levelling)
                }
                if cue.state == .levelling {
                    ProgressView(value: store.progress[cue.id] ?? 0).tint(Theme.good)
                }
            }
        }
    }
    func done(_ title: String, _ detail: String, _ value: String?, on: Bool = true) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: on ? "checkmark" : "minus").font(.system(size: 13, weight: .bold)).foregroundStyle(on ? Theme.good : Theme.dim).frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.bone)
                    Spacer()
                    if let value { Text(value).font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.changed) }
                }
                Text(detail).font(.system(size: 13.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
