import Foundation

// Clip gain (1.2): Pro Tools-style volume changes on sections of a cue.
// Each region raises or lowers one stretch of the first audio track by a fixed number of dB, with fade-in and fade-out
// lengths the user drags. It is volume only: no compression, no EQ. The levelled output is rendered with the edits applied
// and then levelled as usual, so it replaces the normal output.

struct GainRegion: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id = UUID()
    /// Seconds from the first audio sample.
    var start: Double
    var end: Double
    /// Gain in dB applied between the fades.
    var gain: Double = 0
    /// Fade lengths in seconds, inside the region.
    var fadeIn: Double = 0.05
    var fadeOut: Double = 0.05
    /// Marked by the user as a stretch that already sounds right; Match brings other regions to its loudness.
    var isReference = false
    /// Made by Even out (replaced when Even out runs again); nil or false for sections drawn by hand.
    var isAuto: Bool? = nil
    /// Silenced section (1.5): a mute with short fades, like muting a clip in Pro Tools.
    var muted: Bool? = nil

    static let gainRange = -24.0 ... 24.0
    static let minimumLength = 0.1
    static let minimumFade = 0.005

    var length: Double { end - start }
    var linearGain: Double { muted == true ? 0 : pow(10, gain / 20) }

    /// Keeps the region inside the cue, at least `minimumLength` long, with fades that fit and gain in range.
    func normalized(duration: Double) -> GainRegion {
        var r = self
        if r.end < r.start { swap(&r.start, &r.end) }
        r.start = max(0, min(r.start, max(0, duration - Self.minimumLength)))
        r.end = min(max(duration, r.start + Self.minimumLength), max(r.end, r.start + Self.minimumLength))
        r.gain = (min(Self.gainRange.upperBound, max(Self.gainRange.lowerBound, r.gain.isFinite ? r.gain : 0)) * 10).rounded() / 10
        let half = r.length / 2
        r.fadeIn = min(half, max(Self.minimumFade, r.fadeIn.isFinite ? r.fadeIn : Self.minimumFade))
        r.fadeOut = min(half, max(Self.minimumFade, r.fadeOut.isFinite ? r.fadeOut : Self.minimumFade))
        return r
    }

    /// 0 outside the region, 1 between the fades, a linear ramp across each fade.
    func weight(at t: Double) -> Double {
        guard t > start, t < end else { return 0 }
        return min(1, (t - start) / fadeIn) * min(1, (end - t) / fadeOut)
    }
}

enum ClipGain {
    /// Regions that change the sound (non-zero gain), sorted, with overlaps resolved in favour of the later-starting region.
    static func active(_ regions: [GainRegion]?) -> [GainRegion] {
        (regions ?? []).filter { (abs($0.gain) >= 0.05 || $0.muted == true) && $0.length > 0 }.sorted { $0.start < $1.start }
    }

    /// Linear multiplier at time t: each region's change, weighted by its fades, multiplied together (so overlapping
    /// sections combine like stacked gain stages).
    static func multiplier(at t: Double, regions: [GainRegion]) -> Double {
        var m = 1.0
        for r in regions { let w = r.weight(at: t); if w > 0 { m *= 1 + (r.linearGain - 1) * w } }
        return max(0, m)
    }

    /// FFmpeg filter applying the regions sample-accurately (time from the sample index, so container start offsets don't matter).
    /// nil when nothing changes the sound.
    static func filter(_ regions: [GainRegion]?) -> String? {
        let list = active(regions)
        guard !list.isEmpty else { return nil }
        func n(_ v: Double) -> String { String(format: "%.6f", v) }
        let terms = list.map { r in
            "(1+(\(n(r.linearGain - 1)))*clip((T-\(n(r.start)))/\(n(r.fadeIn)),0,1)*clip((\(n(r.end))-T)/\(n(r.fadeOut)),0,1))"
        }
        let expression = "val(ch)*max(0," + terms.joined(separator: "*") + ")"
        // aeval has no named time-from-sample constant; substitute n/s for T.
        return "aeval=exprs='" + expression.replacingOccurrences(of: "T", with: "(n/s)") + "':c=same"
    }

    /// Gain (dB) that brings a section measured at `loudness` to the reference section's loudness, within the allowed range.
    static func matchGain(reference: Double, section: Double) -> Double? {
        guard reference.isFinite, section.isFinite else { return nil }
        return (min(GainRegion.gainRange.upperBound, max(GainRegion.gainRange.lowerBound, reference - section)) * 10).rounded() / 10
    }

    /// Filter that keeps only [start, end) of a stream at `sampleRate`, for measuring one section.
    static func trim(start: Double, end: Double, sampleRate: Int) -> String {
        "atrim=start_sample=\(Int((start * Double(sampleRate)).rounded())):end_sample=\(Int((end * Double(sampleRate)).rounded())),asetpts=PTS-STARTPTS"
    }
}

extension ClipGain {
    /// Real-time preview through AVAudioMix, whose volume cannot exceed 1: everything is scaled down by the largest boost
    /// so the balance between sections is exact while boosted sections still fit. Returns that overall scale (0–1].
    static func previewScale(_ regions: [GainRegion]?, edit: CueEdit? = nil, duration: Double = 0) -> Double {
        let peak = breakpoints(regions, edit: edit, duration: duration).map { multiplier(at: $0, regions: active(regions)) }.max() ?? 1
        return 1 / max(1, peak)
    }
    /// Volume breakpoints for the preview: (time, volume) pairs; volume changes linearly between consecutive points.
    static func previewPoints(_ regions: [GainRegion]?, edit: CueEdit? = nil, duration: Double = 0) -> [(time: Double, volume: Double)] {
        let scale = previewScale(regions, edit: edit, duration: duration)
        return breakpoints(regions, edit: edit, duration: duration).map { t in
            (t, envelope(at: t, regions: regions, edit: edit, duration: duration) * scale)
        }
    }
    static func breakpoints(_ regions: [GainRegion]?, edit: CueEdit?, duration: Double) -> [Double] {
        var times: Set<Double> = [0]
        for r in active(regions) { times.formUnion([r.start, r.start + r.fadeIn, r.end - r.fadeOut, r.end]) }
        if let edit, duration > 0, edit.changesAudio(duration: duration) {
            let e = edit.normalized(duration: duration), s = e.inPoint, end = e.end(duration: duration)
            let fi = max(e.fadeIn, s > 0.0005 ? CueEdit.clickGuard : 0), fo = max(e.fadeOut, end < duration - 0.0005 ? CueEdit.clickGuard : 0)
            times.formUnion([max(0, s - 0.0001), s, s + fi, end - fo, end, min(duration, end + 0.0001)])
            // Curved fades are previewed as a few straight segments.
            for k in 1..<4 { times.insert(s + fi * Double(k) / 4); times.insert(end - fo * Double(k) / 4) }
        }
        return times.filter { $0 >= 0 }.sorted()
    }
}

/// Undo history for clip gain edits (one step per finished drag or button press).
struct EditHistory<State: Equatable> {
    private(set) var undoStack: [State] = []
    private(set) var redoStack: [State] = []
    let limit = 200
    mutating func record(_ previous: State) {
        if undoStack.last != previous { undoStack.append(previous); if undoStack.count > limit { undoStack.removeFirst() } }
        redoStack.removeAll()
    }
    mutating func undo(current: State) -> State? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current); return previous
    }
    mutating func redo(current: State) -> State? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current); return next
    }
    mutating func reset() { undoStack.removeAll(); redoStack.removeAll() }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
}

/// Visible time window of the zoomable editor.
struct TimeView: Equatable, Sendable {
    var start = 0.0
    var length = 0.0        // 0 = whole cue
    static let minimumLength = 0.05
    func resolved(duration: Double) -> (start: Double, length: Double) {
        guard duration > 0 else { return (0, 1) }
        let l = length <= 0 ? duration : min(duration, max(Self.minimumLength, length))
        return (min(max(0, start), duration - l), l)
    }
    /// Zooms by `factor` (>1 zooms in) keeping `anchor` (seconds) under the same point.
    func zoomed(by factor: Double, around anchor: Double, duration: Double) -> TimeView {
        let (s, l) = resolved(duration: duration)
        let newLength = min(duration, max(Self.minimumLength, l / max(0.01, factor)))
        let ratio = l > 0 ? (anchor - s) / l : 0.5
        var v = TimeView(start: anchor - ratio * newLength, length: newLength >= duration - 1e-9 ? 0 : newLength)
        let r = v.resolved(duration: duration); v.start = r.start
        return v
    }
    func panned(by seconds: Double, duration: Double) -> TimeView {
        var v = self; let r = resolved(duration: duration); v.start = r.start + seconds
        v.start = v.resolved(duration: duration).start; return v
    }
}

extension AudioEngine {
    /// Integrated loudness of one section, after the given clip-gain regions (sections shorter than 0.4 s cannot be gated).
    static func sectionLoudness(_ input: URL, info: MediaInfo, start: Double, end: Double, regions: [GainRegion], token: Cancellation) throws -> Double {
        guard end - start >= 0.4 else { throw cueError("Select at least half a second to measure a section.") }
        var filters: [String] = []
        if let clip = ClipGain.filter(regions) { filters.append(clip) }
        filters.append(ClipGain.trim(start: start, end: end, sampleRate: info.sampleRate ?? 48000))
        return try measure(input, token: token, duration: end - start, filters: filters.joined(separator: ",")).integrated
    }
}
