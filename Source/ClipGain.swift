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

    static let gainRange = -24.0 ... 24.0
    static let minimumLength = 0.1
    static let minimumFade = 0.005

    var length: Double { end - start }
    var linearGain: Double { pow(10, gain / 20) }

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
        (regions ?? []).filter { abs($0.gain) >= 0.05 && $0.length > 0 }.sorted { $0.start < $1.start }
    }

    /// Linear multiplier at time t: 1 plus each region's change weighted by its fades.
    static func multiplier(at t: Double, regions: [GainRegion]) -> Double {
        var m = 1.0
        for r in regions { let w = r.weight(at: t); if w > 0 { m += (r.linearGain - 1) * w } }
        return max(0, m)
    }

    /// FFmpeg filter applying the regions sample-accurately (time from the sample index, so container start offsets don't matter).
    /// nil when nothing changes the sound.
    static func filter(_ regions: [GainRegion]?) -> String? {
        let list = active(regions)
        guard !list.isEmpty else { return nil }
        func n(_ v: Double) -> String { String(format: "%.6f", v) }
        let terms = list.map { r in
            "(\(n(r.linearGain - 1)))*clip((T-\(n(r.start)))/\(n(r.fadeIn)),0,1)*clip((\(n(r.end))-T)/\(n(r.fadeOut)),0,1)"
        }
        let expression = "val(ch)*max(0,1+" + terms.joined(separator: "+") + ")"
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
