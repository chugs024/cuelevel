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
    /// Section effects (1.6): a low-cut at this frequency (Hz) and/or a de-esser, cross-faded in with the section's fades.
    var lowCut: Double? = nil
    var deEss: Bool? = nil
    /// Made by "Lower gaps" (1.6): turns down the quiet between phrases.
    var isGap: Bool? = nil
    var hasEffects: Bool { (lowCut ?? 0) > 0 || deEss == true }

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

extension ClipGain {
    /// Even out keeps each stretch within this many dB of the cue's typical level.
    static let evenOutTolerance = 2.0
    static let evenOutMaxCut = 18.0
    static let evenOutMaxBoost = 9.0

    /// Finds stretches whose loudness sits clearly above or below the cue's typical level and returns sections that bring
    /// them back. `momentary` holds 400 ms loudness readings every 100 ms. Pauses are ignored when judging a stretch, and
    /// fades sit in the quiet around it. Sections never overlap `avoiding` (sections drawn by hand).
    /// Speech pauses often: in a speech cue a good share of 100 ms readings sit well below the typical level.
    /// Music (and most narration over a bed) plays continuously. Needs at least 20 s to judge.
    static func soundsLikeMusic(momentary m: [Double]) -> Bool {
        let audible = m.filter { $0 > -70 }
        guard audible.count >= 200 else { return false }
        let sorted = audible.sorted(), typical = sorted[sorted.count / 2]
        // Ignore silence before the first and after the last sound.
        guard let first = m.firstIndex(where: { $0 > typical - 20 }), let last = m.lastIndex(where: { $0 > typical - 20 }), last > first else { return false }
        let span = m[first...last]
        let dips = span.filter { $0 < typical - 12 }.count
        return Double(dips) / Double(span.count) < 0.04
    }
    static func evenOut(momentary m: [Double], duration: Double, tolerance: Double = evenOutTolerance, avoiding: [GainRegion] = [], peaks: [Float]? = nil) -> [GainRegion] {
        let step = 0.1
        guard m.count > 20 else { return [] }
        func energy(_ v: Double) -> Double { pow(10, v / 10) }
        func level(_ e: Double) -> Double { 10 * log10(max(e, 1e-12)) }
        func median(_ values: [Double]) -> Double? { let s = values.sorted(); return s.isEmpty ? nil : s[s.count / 2] }
        // Gate out silence, then pauses relative to the typical level.
        guard let rough = median(m.filter { $0 > -50 }) else { return [] }
        var active = m.map { $0 > -50 && $0 > rough - 15 }
        guard let reference = median(zip(m, active).filter { $0.1 }.map { $0.0 }) else { return [] }
        // 2.0.1: a long stretch 15–24 dB down is a quiet passage, not a pause (pauses are short or much quieter).
        var i = 0
        while i < m.count {
            guard !active[i], m[i] > -50, m[i] > rough - 24 else { i += 1; continue }
            var j = i; while j < m.count, !active[j], m[j] > -50, m[j] > rough - 24 { j += 1 }
            if Double(j - i) * step >= 3 { for k in i..<j { active[k] = true } }
            i = j
        }
        // Phrase loudness: energy mean of active readings within ±0.75 s.
        let radius = 7
        var phrase = [Double?](repeating: nil, count: m.count)
        for i in m.indices where active[i] {
            var sum = 0.0, n = 0
            for j in max(0, i - radius)...min(m.count - 1, i + radius) where active[j] { sum += energy(m[j]); n += 1 }
            phrase[i] = n > 0 ? level(sum / Double(n)) : nil
        }
        // Runs of the same direction beyond the tolerance; pauses shorter than 0.8 s don't end a run.
        struct Run { var sign: Int; var first: Int; var last: Int; var activeFrames: [Int] }
        var runs: [Run] = []
        var current: Run?
        var gap = 0
        func close() { if let r = current, Double(r.activeFrames.count) * step >= 1.0 { runs.append(r) }; current = nil; gap = 0 }
        for i in m.indices {
            guard active[i], let p = phrase[i] else {
                if current != nil { gap += 1; if Double(gap) * step > 0.8 { close() } }
                continue
            }
            let d = p - reference
            let sign = d > tolerance ? 1 : (d < -tolerance ? -1 : 0)
            if sign == 0 { close(); continue }
            if var r = current, r.sign == sign { r.last = i; r.activeFrames.append(i); current = r; gap = 0 }
            else { close(); current = Run(sign: sign, first: i, last: i, activeFrames: [i]) }
        }
        close()
        // One section per run: the gain that brings the run's loudness to the reference, with fades in the surrounding quiet.
        var result: [GainRegion] = []
        let firstActive = active.firstIndex(of: true) ?? 0, lastActive = active.lastIndex(of: true) ?? m.count - 1
        for r in runs {
            // 2.0.1: never lift a fade-in at the start or a fade-out at the end.
            if r.sign < 0, r.activeFrames.count >= 6 {
                let third = max(1, r.activeFrames.count / 3)
                let head = median(r.activeFrames.prefix(third).map { m[$0] }) ?? 0, tail = median(r.activeFrames.suffix(third).map { m[$0] }) ?? 0
                if lastActive - r.last <= 15, head - tail >= 4 { continue }
                if r.first - firstActive <= 15, tail - head >= 4 { continue }
            }
            // Trim to readings that themselves sit beyond the tolerance (the smoothing spreads a stretch's edges).
            let core = r.activeFrames.filter { Double(r.sign) * (m[$0] - reference) > tolerance }
            guard let first = core.first, let last = core.last, let loudness = median(core.map { m[$0] }) else { continue }
            var gain = ((reference - loudness) * 2).rounded() / 2
            gain = min(evenOutMaxBoost, max(-evenOutMaxCut, gain))
            guard abs(gain) >= tolerance * 0.75 else { continue }
            // Readings mark the end of a 400 ms window: the stretch starts about one reading before the first and ends
            // about 0.35 s before the last. No fades: the change is moved into the quietest moment nearby (the pause between
            // speakers) and uses only a 5 ms click guard, so the level simply is right from that point on.
            var start = max(0, Double(first) * step - 0.05), end = min(duration, Double(last + 1) * step - 0.3)
            if let peaks {
                start = quietest(near: start, from: start - 0.6, to: start + 0.1, peaks: peaks, duration: duration)
                end = quietest(near: end, from: end - 0.1, to: end + 0.6, peaks: peaks, duration: duration)
            }
            // 2.0.1: a lifted stretch never peaks above the cue's existing loudest peak, so Even out can't create new overs.
            if gain > 0, let peaks, !peaks.isEmpty, duration > 0, let loudest = peaks.max(), loudest > 0 {
                let perSecond = Double(peaks.count) / duration
                let lo = max(0, min(peaks.count - 1, Int(start * perSecond))), hi = max(lo, min(peaks.count - 1, Int(end * perSecond)))
                if let sectionPeak = peaks[lo...hi].max(), sectionPeak > 0 {
                    let room = 20 * log10(Double(loudest) / Double(sectionPeak))
                    gain = min(gain, (room * 2).rounded(.down) / 2)
                }
                guard gain >= tolerance * 0.75 else { continue }
            }
            var region = GainRegion(start: start, end: end, gain: gain, fadeIn: CueEdit.clickGuard, fadeOut: CueEdit.clickGuard)
            region.isAuto = true
            region = region.normalized(duration: duration)
            // Back-to-back stretches: start this one where the previous one ends.
            if let previous = result.last, previous.end > region.start { region.start = previous.end; region = region.normalized(duration: duration) }
            guard region.length >= 0.5 else { continue }
            if !avoiding.contains(where: { $0.start < region.end && region.start < $0.end }) { result.append(region) }
        }
        return result
    }
}

extension ClipGain {
    /// Weight expression (0–1) of the sections matching `include`, from the sample index, with their fades.
    static func weightExpression(_ regions: [GainRegion]) -> String {
        func n(_ v: Double) -> String { String(format: "%.6f", v) }
        let terms = regions.map { r in "clip((T-\(n(r.start)))/\(n(r.fadeIn)),0,1)*clip((\(n(r.end))-T)/\(n(r.fadeOut)),0,1)" }
        return "min(1," + terms.joined(separator: "+") + ")"
    }
    /// Section effects as a cross-fade between the dry signal and a filtered copy, so they switch in and out without clicks.
    static func effectsFilter(_ regions: [GainRegion]?) -> String? {
        let list = (regions ?? []).filter { $0.length > 0 }
        var stages: [String] = []
        func stage(_ tag: String, _ effect: String, _ group: [GainRegion]) -> String {
            let w = weightExpression(group).replacingOccurrences(of: "T", with: "(n/s)")
            return "asplit=2[\(tag)d][\(tag)w];[\(tag)w]\(effect)[\(tag)x];[\(tag)d][\(tag)x]amerge=inputs=2,aeval=exprs='val(0)*(1-\(w))+val(2)*\(w)|val(1)*(1-\(w))+val(3)*\(w)':c=stereo"
        }
        let lowCut = list.filter { ($0.lowCut ?? 0) > 0 }
        if let f = lowCut.compactMap(\.lowCut).max() { stages.append(stage("lc", "highpass=f=\(Int(f)):p=2", lowCut)) }
        let deEss = list.filter { $0.deEss == true }
        if !deEss.isEmpty { stages.append(stage("ds", "deesser=i=0.4:m=0.5:f=0.5", deEss)) }
        return stages.isEmpty ? nil : stages.joined(separator: ",")
    }

    /// "Lower gaps": sections over the pauses between phrases (quieter than 12 dB below the typical level for at least
    /// `minimumGap` seconds), turned down by `depth` dB with fades that stay inside the pause.
    static func gapRegions(momentary m: [Double], duration: Double, depth: Double = 6, minimumGap: Double = 0.4) -> [GainRegion] {
        let step = 0.1
        guard m.count > 10 else { return [] }
        func median(_ v: [Double]) -> Double? { let s = v.sorted(); return s.isEmpty ? nil : s[s.count / 2] }
        guard let rough = median(m.filter { $0 > -50 }), let reference = median(m.filter { $0 > -50 && $0 > rough - 15 }) else { return [] }
        let quiet = m.map { $0 < reference - 12 }
        var result: [GainRegion] = []
        var i = 0
        while i < m.count {
            guard quiet[i] else { i += 1; continue }
            var j = i
            while j + 1 < m.count, quiet[j + 1] { j += 1 }
            // A reading covers the 400 ms before its stamp, so the pause spans (i·0.1 − 0.3) … ((j+1)·0.1).
            let start = max(0, Double(i) * step - 0.3), end = min(duration, Double(j + 1) * step)
            if end - start >= minimumGap {
                let fade = min(0.08, (end - start) / 4)
                var r = GainRegion(start: start, end: end, gain: -abs(depth), fadeIn: fade, fadeOut: fade)
                r.isAuto = true; r.isGap = true
                result.append(r.normalized(duration: duration))
            }
            i = j + 1
        }
        return result
    }

    /// The quietest moment between `from` and `to` (within 1 dB of the lowest peak, the one nearest `t`).
    static func quietest(near t: Double, from: Double, to: Double, peaks: [Float], duration: Double) -> Double {
        guard !peaks.isEmpty, duration > 0 else { return t }
        let perSecond = Double(peaks.count) / duration
        let lo = max(0, Int(max(0, from) * perSecond)), hi = min(peaks.count - 1, Int(min(duration, to) * perSecond))
        guard lo <= hi, let floor = peaks[lo...hi].min() else { return t }
        let limit = max(floor * 1.122, floor + 1e-6)
        let centre = Int(t * perSecond)
        var best = -1
        for k in lo...hi where peaks[k] <= limit { if best < 0 || abs(k - centre) < abs(best - centre) { best = k } }
        return best < 0 ? t : (Double(best) + 0.5) / perSecond
    }
    /// Nearest quiet moment (lowest peak) to `t` within ±`window` seconds, from a fine waveform covering `duration`.
    static func snapToQuiet(_ t: Double, peaks: [Float], duration: Double, window: Double = 0.06) -> Double {
        guard !peaks.isEmpty, duration > 0 else { return t }
        let perSecond = Double(peaks.count) / duration
        let centre = Int(t * perSecond), span = max(1, Int(window * perSecond))
        let lo = max(0, centre - span), hi = min(peaks.count - 1, centre + span)
        guard lo <= hi else { return t }
        var best = lo
        for k in lo...hi where peaks[k] < peaks[best] || (peaks[k] == peaks[best] && abs(k - centre) < abs(best - centre)) { best = k }
        return (Double(best) + 0.5) / perSecond
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
