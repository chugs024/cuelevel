import SwiftUI
import AppKit

/// Show settings (2.0): everything set once per show, out of the operator's way.
/// Loudness standard and ceiling, what Quick Level does, where files go, references, and the optional processing chain.
struct ShowSettingsSheet: View {
    @EnvironmentObject var model: Workspace
    let close: () -> Void
    enum Tab: String, CaseIterable { case loudness = "Loudness", files = "Files", references = "References", processing = "Processing" }
    @State private var tab = Tab.loudness
    @State private var showProcessing = true
    @State private var showAdvanced = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Show settings").font(.system(size: 18, weight: .semibold))
                Spacer()
                Segments(options: Tab.allCases.map { ($0, $0.rawValue) }, selection: $tab).frame(width: 400)
                Spacer()
                Button("Done", action: close).buttonStyle(CLButton(kind: .primary)).keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 22).padding(.vertical, 16)
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch tab {
                    case .loudness: loudnessTab
                    case .files: filesTab
                    case .references: referencesSection
                    case .processing: processingSection
                    }
                }
            }
        }
        .frame(width: 720, height: 600).background(Theme.panel).foregroundStyle(Theme.bone).tint(Theme.good).preferredColorScheme(.dark)
        .disabled(model.busy)
    }

    @ViewBuilder var loudnessTab: some View {
        section {
            HStack { Text("Level to").sectionTitle(); Spacer(); standardsMenu }
            valueRow("Target", value: $model.settings.target, range: -30 ... -12, unit: "LUFS")
            valueRow("Peak ceiling", value: $model.settings.peak, range: -6 ... -1, unit: "dBTP")
            Text("−18 LUFS with peaks under −1 dBTP suits most live venues. It's a starting point, not a calibration: check it on your PA at your normal desk gain.").hint()
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
            Text("What levelling does").sectionTitle()
            Toggle(isOn: $model.evenOut) { switchLabel("Even out loud and quiet stretches", "Stretches that move more than your good references are turned back in the nearest pause, without fades. Music is left as it is: cues set to Music, and cues that play continuously like a song.") }.toggleStyle(CLSwitch())
            Toggle(isOn: $model.autoTrim) { switchLabel("Trim silence at the start and end", "Audio is cut; video keeps its length and the silence is muted instead.") }.toggleStyle(CLSwitch())
        }
        section {
            HStack { Text("Content").sectionTitle(); Spacer(); presetsMenu }
            Segments(options: [(ContentMode.music, "Music"), (ContentMode.mixed, "Music + voice"), (ContentMode.voice, "Voice")], selection: Binding(get: { model.settings.mode }, set: { model.changeMode($0) }))
            Text(model.settings.mode.detail + " Cues are compared with your good references of this type.").hint()
        }
    }
    @ViewBuilder var filesTab: some View {
        section {
            Text("Where levelled files go").sectionTitle()
            folderRow(model.quickFolder, empty: "Desktop › CueLevel › Levelled") { model.chooseQuickFolder() }
            if model.quickFolder != nil { Button("Use Desktop › CueLevel") { model.useDefaultOutputFolder() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.good) }
            Text("Files are named “<original>_LVL\(String(format: "%.0f", model.settings.target)).wav” (or .mov). Nothing is ever overwritten; a second copy becomes “… 2.wav”. Reports go to a Reports folder next to them.").hint()
        }
        section {
            Text("File type").sectionTitle()
            HStack {
                Text("Save as").font(.system(size: 12.5)).foregroundStyle(Theme.text)
                Spacer()
                Picker("Save as", selection: $model.settings.format) { ForEach(OutputFormat.allCases) { Text($0.rawValue).tag($0) } }
                    .labelsHidden().fixedSize()
            }
            Text(formatHint).hint()
        }
        section {
            Toggle(isOn: Binding(get: { model.settings.foldsSurround }, set: { model.setFoldSurround($0) })) { Text("Fold surround to stereo").sectionTitle().frame(maxWidth: .infinity, alignment: .leading) }.toggleStyle(CLSwitch())
            Text(model.settings.foldsSurround
                 ? "Surround files (5.1, 7.1) are folded down to stereo for a stereo PA. Folding mixes the channels together, so those copies aren't lossless. Mono and stereo files are unchanged."
                 : "Every levelled copy has the same channels as its source: mono stays mono, 5.1 stays 5.1. Turn this on only if your PA plays stereo and you want surround files folded down.").hint()
        }
        section {
            Toggle(isOn: Binding(get: { model.watching }, set: { model.setWatching($0) })) { Text("Watch a folder").sectionTitle().frame(maxWidth: .infinity, alignment: .leading) }.toggleStyle(CLSwitch())
            if model.watchFolder != nil || model.watching { folderRow(model.watchFolder, empty: "Choose folder") { model.chooseWatchFolder() } }
            Text("New files are added the moment they finish copying in\(model.quickLevel ? ", and levelled straight away" : ""). Files already there are left alone.").hint()
        }
    }
    func switchLabel(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) { Text(title).font(.system(size: 13, weight: .medium)); Text(detail).hint() }.frame(maxWidth: .infinity, alignment: .leading)
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
            .menuStyle(.borderlessButton).font(.system(size: 12)).foregroundStyle(Theme.good).fixedSize()
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
                if let span = model.references.span(for: model.settings.mode), let spread = span.spread {
                    Text("Good \(model.settings.mode.label) moves \(String(format: "%.1f–%.1f", spread.lowerBound, spread.upperBound)) LU between quieter and louder stretches (\(span.shapeCount) reference\(span.shapeCount == 1 ? "" : "s")). Even out keeps cues within ±\(String(format: "%g", model.references.evenOutTolerance(for: model.settings.mode))) dB.").hint()
                }
                if model.referencesMissingShapes > 0 {
                    Button("Measure reference shapes… (\(model.referencesMissingShapes) missing)") { model.measureReferenceShapes() }.buttonStyle(CLButton(kind: .ghost)).disabled(model.busy)
                        .help("Read your reference recordings once to learn how good material moves over time. Nothing is copied.")
                }
                Toggle(isOn: $model.autoRecommend) { Text("Apply each cue's recommendation").font(.system(size: 12.5)).foregroundStyle(Theme.text).frame(maxWidth: .infinity, alignment: .leading) }.toggleStyle(CLSwitch())
                Text("When processing (not in lossless mode), each cue gets Preserve or Gentle correction based on your approved references.").hint()
            }
        }
    }
    func section<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11) { content() }
            .padding(.horizontal, 22).padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading)
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
            Button(folder == nil ? "Choose" : "Change", action: choose).buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.good)
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
}
