import Foundation

// CueLevel 2.0: the assistant's plan for one cue, and each cue's plain-language stage.
// Like iZotope's Repair/Master Assistant, CueLevel says what it will do before it does anything; each step can be skipped.

/// Where a cue is, in the words an operator uses.
enum CueStage: Equatable {
    case waiting, working, measured, levelled, alreadyGood, needsLook, failed, stopped

    init(_ job: CueJob) {
        switch job.status {
        case .queued: self = .waiting
        case .working: self = .working
        case .analyzed: self = .measured
        case .ready: self = job.alreadyGood != nil ? .alreadyGood : .levelled
        case .review: self = .needsLook
        case .failed: self = .failed
        case .cancelled: self = .stopped
        }
    }
    var title: String {
        switch self {
        case .waiting: return "Waiting"
        case .working: return "Working"
        case .measured: return "Ready to level"
        case .levelled: return "Levelled"
        case .alreadyGood: return "Already good"
        case .needsLook: return "Needs a look"
        case .failed: return "Couldn't open"
        case .stopped: return "Stopped"
        }
    }
    var isDone: Bool { self == .levelled || self == .alreadyGood }
    var wantsAttention: Bool { self == .needsLook || self == .failed }
}

/// What a colour means in CueLevel: colour is only ever used for level.
enum LevelTone: Equatable { case neutral, quiet, good, changed, hot }

/// Where a loudness sits against the target: within 1 LU is good, below is quiet, above is hot.
func levelTone(_ lufs: Double, target: Double) -> LevelTone {
    if abs(lufs - target) <= 1 { return .good }
    return lufs < target ? .quiet : .hot
}

enum PlanSwitch: Equatable { case trim, evenOut, removeDC, flipPolarity }

struct PlanStep: Identifiable, Equatable {
    var id: String
    var title: String
    var detail: String
    var value: String?
    var tone: LevelTone
    /// Whether the step will run, and which setting its tickbox controls (nil = always runs).
    var isOn: Bool
    var control: PlanSwitch?
}

struct CuePlan: Equatable {
    var steps: [PlanStep]
    var gain: Double
    var shortfall: Double
    var limiting: Double
    var predictedLoudness: Double
    var predictedPeak: Double
    /// This cue's short-term spread (P90 − P10) and the spread of good references of its content type.
    var spread: Double?
    var goodSpread: ClosedRange<Double>?
    /// Set when the cue already looks good: CueLevel will check for uneven stretches and otherwise leave it alone.
    var looksGood: String?

    static func make(analysis: Analysis, settings: ProcessingSettings, evenOut: Bool, autoTrim: Bool, edit: CueEdit,
                     handEdits: Bool, library: ReferenceLibrary) -> CuePlan {
        let levels = analysis.levels, info = analysis.info
        func f(_ v: Double) -> String { String(format: "%.1f", v).replacingOccurrences(of: "-", with: "−") }
        func sec(_ v: Double) -> String { String(format: "%.1f s", v) }
        var steps: [PlanStep] = []

        // Repairs first, only when the checks found something.
        if let dc = levels.dcOffset, abs(dc) >= 0.001 {
            steps.append(PlanStep(id: "dc", title: "Remove DC offset",
                                  detail: "The waveform sits \(String(format: "%.2f", abs(dc) * 100))% off centre. That wastes headroom and can click when the cue starts.",
                                  value: nil, tone: .changed, isOn: edit.removeDC, control: .removeDC))
        }
        if info.channels >= 2, let c = analysis.stereo?.correlation, c < -0.1 {
            steps.append(PlanStep(id: "polarity", title: "Flip the right channel",
                                  detail: "Left and right cancel each other out (correlation \(String(format: "%.2f", c))). On a mono-summed PA this cue would almost disappear.",
                                  value: nil, tone: .changed, isOn: edit.polarity != .none, control: .flipPolarity))
        }

        // Trim silence.
        let head = max(0, (analysis.stereo?.headSilence ?? 0) - 0.1), tail = max(0, (analysis.stereo?.tailSilence ?? 0) - 0.1)
        let worth = head >= 0.3 || tail >= 0.3
        let trimDetail: String = {
            guard analysis.stereo != nil else { return "Measure again to find the silence at each end." }
            guard worth else { return "Under 0.3 s at each end, so there's nothing worth cutting." }
            let parts = [head >= 0.3 ? "\(sec(head)) at the start" : nil, tail >= 0.3 ? "\(sec(tail)) at the end" : nil].compactMap { $0 }
            return (info.isVideo ? "Silences " : "Removes ") + parts.joined(separator: " and ") + (info.isVideo ? ". The video keeps its length." : ", so the cue plays the moment it's fired.")
        }()
        steps.append(PlanStep(id: "trim", title: "Trim silence", detail: trimDetail,
                              value: worth && autoTrim ? "−" + sec(head + tail) : nil, tone: worth && autoTrim ? .changed : .neutral,
                              isOn: autoTrim, control: .trim))

        // Even out.
        let tolerance = library.evenOutTolerance(for: settings.mode)
        let span = library.span(for: settings.mode)
        let spread = analysis.loudnessCurve.flatMap { LoudnessProfile(shortTerm: $0.map(Double.init)) }?.spread
        let evenDetail: String = {
            let rule = "Turns any stretch more than \(String(format: "%g", tolerance)) dB louder or quieter than the rest back into line. The change happens in a pause, with no fade."
            guard let spread, let good = span?.spread else { return rule }
            return spread <= good.upperBound + 1
                ? "This cue moves \(f(spread)) LU, like your good \(settings.mode.label) cues (\(f(good.lowerBound))–\(f(good.upperBound))), so there's probably nothing to change."
                : "This cue moves \(f(spread)) LU; good \(settings.mode.label) moves \(f(good.lowerBound))–\(f(good.upperBound)). " + rule
        }()
        let likelyUneven = spread.map { s in span?.spread.map { s > $0.upperBound + 1 } ?? false } ?? false
        steps.append(PlanStep(id: "even", title: "Even out loud and quiet stretches", detail: evenDetail,
                              value: evenOut && likelyUneven ? "likely" : nil, tone: evenOut && likelyUneven ? .changed : .neutral,
                              isOn: evenOut, control: .evenOut))

        // The gain change.
        let plan = LosslessPlan(levels: levels, target: settings.target, ceiling: settings.peak, maxLimiting: settings.peakLimit ?? 0)
        let gainDetail: String = {
            if plan.limiting > 0.05 { return "Limits only the loudest peaks, by up to \(f(plan.limiting)) dB, so the cue can reach the target." }
            if plan.shortfall > 0.05 { return "Stays \(f(plan.shortfall)) dB under the target so the loudest peak stays under \(f(settings.peak)) dBTP. Nothing is limited." }
            return "One exact gain change. No compression, no limiting."
        }()
        steps.append(PlanStep(id: "gain", title: abs(plan.gain) < 0.05 ? "Already at \(f(settings.target)) LUFS" : "Bring to \(f(settings.target - plan.shortfall)) LUFS",
                              detail: gainDetail, value: abs(plan.gain) < 0.05 ? nil : (plan.gain >= 0 ? "+" : "−") + String(format: "%.1f dB", abs(plan.gain)),
                              tone: plan.shortfall > 0.05 || plan.limiting > 0.05 ? .changed : .good, isOn: true, control: nil))

        let predictedPeak = min(levels.truePeak + plan.gain, plan.limiting > 0.05 ? settings.peak : .infinity)
        let looksGood = Workspace.alreadyGoodReason(analysis: analysis, target: settings.target, peak: settings.peak,
                                                    autoSections: likelyUneven && evenOut ? 1 : 0, hasEdits: handEdits || edit.hasRepairs, library: library, mode: settings.mode)
        return CuePlan(steps: steps, gain: plan.gain, shortfall: plan.shortfall, limiting: plan.limiting,
                       predictedLoudness: levels.integrated + plan.gain, predictedPeak: predictedPeak,
                       spread: spread, goodSpread: span?.spread, looksGood: looksGood)
    }
}

extension ContentMode {
    /// What the operator sees. The raw values stay as they are because sessions and the reference library store them.
    var label: String { switch self { case .music: return "Music"; case .mixed: return "Music + voice"; case .voice: return "Voice" } }
}
