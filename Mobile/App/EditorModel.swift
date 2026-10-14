import SwiftUI
import AVFoundation

// Pro editor: the state being edited (sections, trims and fades, the fader), undo and redo, and a live prediction of the
// result. The prediction uses the readings CueLevel kept when it measured the cue (momentary loudness every 100 ms, which
// are exactly BS.1770's gating blocks, and 200 peaks per second), so the readouts move with the fader without
// decoding the file again. The levelled file is measured for real when it's made.

struct EditDraft: Equatable {
    var regions: [GainRegion]
    var edit: CueEdit
    /// The cue's gain in dB set on the fader; nil = automatic (CueLevel works it out from the target).
    var gain: Double?
}

struct EditPrediction: Equatable {
    /// Loudness and sample peak of the edited cue before the fader (LUFS, dBFS).
    var loudness: Double
    var peak: Double
    /// The gain CueLevel would choose: to the target, or less if the loudest peak would pass the ceiling.
    var autoGain: Double
}

@MainActor
final class EditorModel: ObservableObject {
    let cueID: UUID
    let analysis: Analysis
    let data: EvenOutData?
    let target: Double
    let ceiling: Double
    let original: EditDraft
    /// Peaks grouped to at most 20 per second, so predictions stay quick while dragging on a long cue.
    private let coarsePeaks: [Float]

    @Published var draft: EditDraft { didSet { if draft != oldValue { predict() } } }
    @Published var selection: UUID?
    /// Visible part of the cue, in seconds.
    @Published var window: ClosedRange<Double>
    @Published private(set) var prediction: EditPrediction
    @Published private(set) var undoStack: [EditDraft] = []
    @Published private(set) var redoStack: [EditDraft] = []

    var duration: Double { analysis.info.duration }
    var changed: Bool { draft != original }
    /// The gain that will be used: the fader's, or the automatic one.
    var gain: Double { draft.gain ?? prediction.autoGain }
    var outputLoudness: Double { prediction.loudness + gain }
    /// True peak estimate: the sample peak of the readings plus the source's own gap between sample and true peak.
    var outputPeak: Double { prediction.peak + gain + truePeakMargin }
    private var truePeakMargin: Double { max(0, analysis.levels.truePeak - (analysis.levels.samplePeak ?? analysis.levels.truePeak)) }

    init(cueID: UUID, analysis: Analysis, data: EvenOutData?, target: Double, ceiling: Double, draft: EditDraft) {
        self.cueID = cueID; self.analysis = analysis; self.data = data; self.target = target; self.ceiling = ceiling
        self.original = draft
        self.draft = draft
        let fine = data?.peaks ?? []
        let group = max(1, Int((Double(fine.count) / max(0.001, analysis.info.duration) / 20).rounded(.up)))
        coarsePeaks = stride(from: 0, to: fine.count, by: group).map { fine[$0 ..< min(fine.count, $0 + group)].max() ?? 0 }
        window = 0 ... max(0.5, analysis.info.duration)
        prediction = EditPrediction(loudness: analysis.levels.integrated, peak: analysis.levels.samplePeak ?? analysis.levels.truePeak, autoGain: 0)
        predict()
    }

    // MARK: Undo
    /// Call once when a change starts (a tap, or the start of a drag); the change itself can then be applied many times.
    func checkpoint() {
        undoStack.append(draft); if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }
    func undo() { guard let last = undoStack.popLast() else { return }; redoStack.append(draft); draft = last; keepSelectionValid() }
    func redo() { guard let next = redoStack.popLast() else { return }; undoStack.append(draft); draft = next; keepSelectionValid() }
    private func keepSelectionValid() { if let s = selection, !draft.regions.contains(where: { $0.id == s }) { selection = nil } }

    // MARK: Sections
    var selected: GainRegion? { draft.regions.first { $0.id == selection } }
    func update(_ id: UUID, _ change: (inout GainRegion) -> Void) {
        guard let i = draft.regions.firstIndex(where: { $0.id == id }) else { return }
        var r = draft.regions[i]; change(&r)
        r.isAuto = nil   // edited by hand now
        draft.regions[i] = r.normalized(duration: duration)
    }
    /// A new section at `time`, two seconds long (or the tenth of the visible part, if shorter), not overlapping others.
    func addSection(at time: Double) {
        checkpoint()
        let span = min(2.0, max(0.5, (window.upperBound - window.lowerBound) / 5))
        var start = max(0, min(duration - span, time - span / 2))
        if let hit = draft.regions.first(where: { $0.start <= start && start < $0.end }) { start = min(duration - span, hit.end) }
        var r = GainRegion(start: start, end: min(duration, start + span), gain: 3, fadeIn: 0.05, fadeOut: 0.05)
        r = r.normalized(duration: duration)
        draft.regions.append(r); draft.regions.sort { $0.start < $1.start }
        selection = r.id
    }
    func deleteSelected() {
        guard let id = selection else { return }
        checkpoint(); draft.regions.removeAll { $0.id == id }; selection = nil
    }
    /// Back to what CueLevel does on its own: Even out's sections, no fader, the automatic trim.
    func resetToAutomatic(_ automatic: EditDraft) { checkpoint(); draft = automatic; selection = nil }

    // MARK: Zoom
    func zoom(by factor: Double, around t: Double) {
        let span = window.upperBound - window.lowerBound
        let newSpan = min(duration, max(min(0.002, duration), span / factor))   // down to about 100 samples across the screen
        let frac = span > 0 ? (t - window.lowerBound) / span : 0.5
        var lo = t - newSpan * frac
        lo = max(0, min(duration - newSpan, lo))
        window = lo ... lo + newSpan
    }
    func scroll(to lower: Double) {
        let span = window.upperBound - window.lowerBound
        let lo = max(0, min(duration - span, lower))
        window = lo ... lo + span
    }
    func showAll() { window = 0 ... max(0.5, duration) }

    // MARK: Prediction
    /// Linear gain of the sections, trims and fades at time t.
    func envelope(_ t: Double) -> Double {
        ClipGain.envelope(at: t, regions: ClipGain.active(draft.regions), edit: draft.edit, duration: duration)
    }
    private func predict() {
        guard let data, !data.momentary.isEmpty else {
            prediction = EditPrediction(loudness: analysis.levels.integrated, peak: analysis.levels.samplePeak ?? analysis.levels.truePeak,
                                        autoGain: LosslessPlan(levels: analysis.levels, target: target, ceiling: ceiling).gain)
            return
        }
        // Gating blocks: each momentary reading is the 400 ms ending at (i + 1) × 100 ms.
        var blocks: [Double] = []
        blocks.reserveCapacity(data.momentary.count)
        for (i, m) in data.momentary.enumerated() {
            let centre = Double(i + 1) * 0.1 - 0.2
            guard centre >= 0, centre <= duration else { continue }
            let env = envelope(centre)
            guard env > 0, m > -70 else { continue }
            blocks.append(pow(10, (Double(m) + 0.691) / 10) * env * env)
        }
        let absolute = blocks.filter { $0 > pow(10, (-70 + 0.691) / 10) }
        var loudness = analysis.levels.integrated
        if !absolute.isEmpty {
            let gate = -0.691 + 10 * log10(absolute.reduce(0, +) / Double(absolute.count)) - 10
            let kept = absolute.filter { -0.691 + 10 * log10($0) > gate }
            if !kept.isEmpty { loudness = -0.691 + 10 * log10(kept.reduce(0, +) / Double(kept.count)) }
        }
        var peak = 0.0
        let rate = Double(coarsePeaks.count) / max(0.001, duration)
        let regions = ClipGain.active(draft.regions)
        for (j, p) in coarsePeaks.enumerated() where p > 0 {
            let t = (Double(j) + 0.5) / rate
            let v = Double(p) * ClipGain.envelope(at: t, regions: regions, edit: draft.edit, duration: duration)
            if v > peak { peak = v }
        }
        let peakDB = peak > 0 ? 20 * log10(peak) : -100
        let wanted = target - loudness
        let allowed = ceiling - (peakDB + truePeakMargin)
        prediction = EditPrediction(loudness: loudness, peak: peakDB, autoGain: min(wanted, allowed))
    }
}
