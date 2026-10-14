import SwiftUI
import AppKit

/// The right-hand panel (2.0): what CueLevel will do to the selected cue, step by step, before it does it.
/// After levelling it becomes the result: what changed, where the file went, and what to do next.
struct AssistantPanel: View {
    @EnvironmentObject var model: Workspace
    let openSettings: () -> Void
    let setEditing: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let job = model.selected { content(job) } else { idle }
                }.padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 16)
            }
            showSummary
        }.background(Theme.panel)
    }

    // MARK: Per cue
    @ViewBuilder func content(_ job: CueJob) -> some View {
        let stage = CueStage(job)
        if let analysis = job.analysis {
            if (stage.isDone || stage == .needsLook), let output = job.output, !model.outputIsStale {
                result(job, analysis, output)
            } else {
                plan(job, analysis)
            }
        } else if stage == .working {
            VStack(alignment: .leading, spacing: 10) {
                Text("Measuring").sectionTitle()
                Text(job.message).hint()
                ProgressView(value: job.progress).tint(Theme.good)
            }
        } else if stage == .waiting {
            VStack(alignment: .leading, spacing: 10) {
                Text("Waiting to be measured").sectionTitle()
                Text(model.busy ? "CueLevel will measure this cue when the current job finishes." : "This cue hasn't been measured yet.").hint()
                Button("Measure now") { model.analyze() }.buttonStyle(CLButton()).disabled(model.busy)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(stage == .failed ? (job.message.localizedCaseInsensitiveContains("silent") ? "This cue is silent" : "CueLevel can't level this file") : "Not measured yet").sectionTitle()
                if stage == .failed { Text(job.message).hint().textSelection(.enabled) }
                Button("Measure again") { model.analyze() }.buttonStyle(CLButton()).disabled(model.busy)
            }
        }
    }

    @ViewBuilder func plan(_ job: CueJob, _ analysis: Analysis) -> some View {
        let lossless = model.settings.format == .lossless
        let plan = CuePlan.make(analysis: analysis, settings: model.settings, evenOut: model.evenOut, autoTrim: model.autoTrim,
                                edit: job.edit ?? CueEdit(), handEdits: Workspace.hasHandEdits(job, duration: analysis.info.duration), library: model.references)
        VStack(alignment: .leading, spacing: 4) {
            Text(job.output != nil ? "Level again" : "What CueLevel will do").sectionTitle()
            Text(model.references.isEmpty ? "Untick anything you don't want. Nothing changes until you level the cue."
                 : "Checked against your good \(model.settings.mode.label) cues. Untick anything you don't want.").hint()
        }
        if let reason = plan.looksGood, lossless {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 18)).foregroundStyle(Theme.good)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Looks already good").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.good)
                    Text(reason).hint()
                    Text("If levelling finds nothing uneven, the cue is left exactly as it is.").hint()
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.good.opacity(0.08))).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.good.opacity(0.25)))
        }
        if lossless {
            VStack(alignment: .leading, spacing: 2) { ForEach(plan.steps) { step in stepRow(step) } }.padding(.horizontal, -8)
            VStack(alignment: .leading, spacing: 6) {
                predicted("Loudness", lufs(plan.predictedLoudness) + " LUFS", tone: plan.shortfall > 0.05 ? .changed : .good)
                predicted("Loudest peak", lufs(plan.predictedPeak) + " dBTP", tone: plan.predictedPeak <= model.settings.peak + 0.05 ? .good : .hot)
                if let spread = plan.spread {
                    predicted("Evenness", String(format: "%.1f LU", spread) + (plan.goodSpread.map { String(format: " (good %.1f–%.1f)", $0.lowerBound, $0.upperBound) } ?? ""),
                              tone: plan.goodSpread.map { spread <= $0.upperBound + 1 ? .good : .changed } ?? .neutral)
                }
            }.padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Theme.field)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
            .help("Before evening out. The exact result is measured after levelling.")
        } else {
            Text("File type is set to \(model.settings.format.rawValue), so the processing chain in Show settings runs as well. That changes the sound; choose Lossless for gain only.").hint()
        }
        VStack(spacing: 8) {
            Button { lossless ? model.quickLevelSelected() : model.processSelected() } label: {
                Text(job.output == nil ? (lossless ? "Level this cue" : "Process this cue") : "Level again")
            }.buttonStyle(CLButton(kind: .hero)).keyboardShortcut("l").disabled(model.busy)
            HStack(spacing: 8) {
                Button { model.playPause() } label: { Label(model.playing ? "Pause" : "Listen", systemImage: model.playing ? "pause.fill" : "play.fill").frame(maxWidth: .infinity) }.buttonStyle(CLButton())
                Button { setEditing(true) } label: { Text("Edit by hand").frame(maxWidth: .infinity) }.buttonStyle(CLButton()).disabled(model.busy)
            }
        }.padding(.top, 4)
    }

    func stepRow(_ step: PlanStep) -> some View {
        let label = HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(step.title).font(.system(size: 13, weight: .medium)).foregroundStyle(step.isOn ? Theme.bone : Theme.muted)
                Text(step.detail).hint()
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let value = step.value, step.isOn {
                Text(value).font(.system(size: 12.5, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.tone(step.tone))
            }
        }
        return Group {
            if let control = step.control {
                Toggle(isOn: Binding(get: { step.isOn }, set: { set(control, $0) })) { label }.toggleStyle(CLCheck())
            } else {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "arrow.up.and.down").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.onGood)
                        .frame(width: 18, height: 18).background(RoundedRectangle(cornerRadius: 5).fill(Theme.tone(step.tone))).padding(.top, 1)
                    label
                }
            }
        }.padding(.horizontal, 8).padding(.vertical, 9).background(RoundedRectangle(cornerRadius: 9).fill(Color.clear)).disabled(model.busy)
    }
    func set(_ control: PlanSwitch, _ on: Bool) {
        switch control {
        case .trim: model.autoTrim = on
        case .evenOut: model.evenOut = on
        case .removeDC: var e = model.selectedEdit; e.removeDC = on; model.setEdit(e)
        case .flipPolarity: model.fixPolarity(on ? .right : .none)
        }
    }
    func predicted(_ title: String, _ value: String, tone: LevelTone) -> some View {
        HStack {
            Text(title).foregroundStyle(Theme.muted)
            Spacer()
            Text(value).fontWeight(.semibold).monospacedDigit().foregroundStyle(tone == .good || tone == .neutral ? Theme.bone : Theme.tone(tone))
        }.font(.system(size: 12.5))
    }

    // MARK: After levelling
    @ViewBuilder func result(_ job: CueJob, _ analysis: Analysis, _ output: ProcessedAudio) -> some View {
        let stage = CueStage(job)
        let duration = analysis.info.duration
        let evened = (job.clipGain ?? []).filter { $0.isAuto == true && $0.isGap != true }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: stage == .needsLook ? "exclamationmark.circle.fill" : "checkmark.seal.fill").font(.system(size: 18))
                    .foregroundStyle(stage == .needsLook ? Theme.changed : Theme.good)
                Text(stage == .alreadyGood ? "Already good" : stage == .needsLook ? "Levelled, with notes" : "Levelled").font(.system(size: 17, weight: .semibold))
            }
            if let reason = job.alreadyGood {
                Text(reason).hint()
                Text("Nothing was changed. An exact copy was saved so the folder has every cue.").hint()
            }
        }
        if job.alreadyGood == nil {
            VStack(alignment: .leading, spacing: 2) {
                if let e = job.edit?.normalized(duration: duration), e.hasRepairs {
                    done("Repaired", [e.removeDC ? "DC offset removed" : nil, e.polarity != .none ? e.polarity.rawValue : nil].compactMap { $0 }.joined(separator: ", "), nil)
                }
                if let e = job.edit?.normalized(duration: duration), e.isTrimmed(duration: duration) {
                    done("Trimmed", "Plays \(clockText(e.inPoint)) to \(clockText(e.end(duration: duration)))", "−" + String(format: "%.1f s", duration - (e.end(duration: duration) - e.inPoint)))
                }
                if !evened.isEmpty {
                    done("Evened out \(evened.count) stretch\(evened.count == 1 ? "" : "es")", evened.prefix(3).map { "\(clockText($0.start))–\(clockText($0.end)) \(signed($0.gain)) dB" }.joined(separator: ", "), nil)
                }
                if let gain = output.gainApplied ?? Optional(output.levels.integrated - analysis.levels.integrated) {
                    done("Gain", output.finalGainMode == "limited" ? "With \(String(format: "%.1f", output.limiting ?? 0)) dB of peak limiting" : "One exact change", signed(gain) + " dB")
                }
            }.padding(.horizontal, -8)
        }
        VStack(alignment: .leading, spacing: 6) {
            predicted("Loudness", lufs(output.levels.integrated) + " LUFS", tone: levelTone(output.levels.integrated, target: output.settings.target) == .good ? .good : .changed)
            predicted("Loudest peak", lufs(output.levels.truePeak) + " dBTP", tone: output.levels.truePeak <= output.settings.peak + 0.2 ? .good : .hot)
        }.padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Theme.field)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
        if stage == .needsLook {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(output.warnings, id: \.self) { w in
                    HStack(alignment: .top, spacing: 8) { Circle().fill(Theme.changed).frame(width: 6, height: 6).padding(.top, 5); Text(w).hint() }
                }
            }
        }
        VStack(alignment: .leading, spacing: 8) {
            if let saved = job.exportURL {
                HStack(spacing: 6) {
                    Image(systemName: "doc").foregroundStyle(Theme.muted)
                    Text(saved.lastPathComponent).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }.buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.good)
                }.padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
            }
            HStack(spacing: 8) {
                Button { compare() } label: { Label("Before / after", systemImage: "arrow.left.arrow.right").frame(maxWidth: .infinity) }.buttonStyle(CLButton())
                    .help("Switches between the original and the levelled cue at matched loudness")
                Button { setEditing(true) } label: { Text("Edit by hand").frame(maxWidth: .infinity) }.buttonStyle(CLButton()).disabled(model.busy)
            }
            HStack(spacing: 8) {
                Button { model.exportSelected() } label: { Text("Save a copy…").frame(maxWidth: .infinity) }.buttonStyle(CLButton(kind: .ghost)).disabled(model.busy)
                Button { model.beginAddingReference() } label: { Text("Mark as good").frame(maxWidth: .infinity) }.buttonStyle(CLButton(kind: .ghost)).disabled(model.busy)
                    .help("This cue sounds right on the PA: add its measurements to your references")
            }
        }
    }
    func done(_ title: String, _ detail: String, _ value: String?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(Theme.good).frame(width: 18, height: 18).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                if !detail.isEmpty { Text(detail).hint() }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let value { Text(value).font(.system(size: 12.5, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.changed) }
        }.padding(.horizontal, 8).padding(.vertical, 7)
    }
    func compare() {
        model.matchPreview = true; model.applyVolume()
        model.switchPreview(!model.processedPreview)
        if !model.playing { model.playPause() }
    }

    // MARK: Nothing selected
    var idle: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What CueLevel will do").sectionTitle()
            Text("Select a cue to see what CueLevel would change, and why.").hint()
        }
    }

    // MARK: Show summary (pinned)
    var showSummary: some View {
        VStack(alignment: .leading, spacing: 9) {
            summaryRow("Content", nil) {
                Menu {
                    ForEach(ContentMode.allCases) { mode in Button(mode.label) { model.changeMode(mode) } }
                } label: { Text(model.settings.mode.label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.bone) }
                    .menuStyle(.borderlessButton).fixedSize().disabled(model.busy).tint(Theme.bone)
                    .help("What kind of cues these are. CueLevel compares them with your good references of the same kind.")
            }
            summaryRow("Target", "\(lufs(model.settings.target)) LUFS, peaks under \(lufs(model.settings.peak))") { EmptyView() }
            summaryRow("Saves to", model.outputFolderDisplay) { EmptyView() }
            summaryRow("References", model.references.isEmpty ? "None yet" : "\(model.references.records.count) good cues") { EmptyView() }
            Button("Show settings…", action: openSettings).buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.good).keyboardShortcut(",")
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
    func summaryRow<Accessory: View>(_ title: String, _ value: String?, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack {
            Text(title).foregroundStyle(Theme.muted)
            Spacer()
            if let value { Text(value).foregroundStyle(Theme.bone).lineLimit(1).truncationMode(.middle).monospacedDigit() }
            accessory()
        }.font(.system(size: 12))
    }
}
