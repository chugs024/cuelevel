import Foundation

// Per-cue edits (1.5): in/out points (trim), fades at the cue's edges with a curve shape, and markers.
// Rendered sample-accurately with FFmpeg after the clip gain sections. Video keeps its full length: instead of cutting,
// the audio before the in point and after the out point is silenced, so picture and sound stay in sync.

enum FadeShape: String, Codable, CaseIterable, Sendable {
    case linear = "Linear", smooth = "Smooth", sCurve = "S-curve"
    /// FFmpeg afade curve names.
    var ffmpeg: String { switch self { case .linear: return "tri"; case .smooth: return "qsin"; case .sCurve: return "esin" } }
}

struct CueMarker: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var time: Double
    var name: String
}

struct CueEdit: Codable, Equatable, Sendable {
    /// In point (seconds from the start of the source) and out point (nil = the end).
    var inPoint = 0.0
    var outPoint: Double? = nil
    /// Fades at the in and out points, in seconds.
    var fadeIn = 0.0
    var fadeOut = 0.0
    var fadeShape = FadeShape.smooth
    var markers: [CueMarker] = []

    /// Shortest fade used at a cut so it never clicks.
    static let clickGuard = 0.005

    init() {}
    // Every field is optional when decoding, so sessions from older and newer versions always load.
    enum CodingKeys: String, CodingKey { case inPoint, outPoint, fadeIn, fadeOut, fadeShape, markers }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inPoint = try c.decodeIfPresent(Double.self, forKey: .inPoint) ?? 0
        outPoint = try c.decodeIfPresent(Double.self, forKey: .outPoint)
        fadeIn = try c.decodeIfPresent(Double.self, forKey: .fadeIn) ?? 0
        fadeOut = try c.decodeIfPresent(Double.self, forKey: .fadeOut) ?? 0
        fadeShape = (try? c.decodeIfPresent(FadeShape.self, forKey: .fadeShape)) ?? .smooth
        markers = try c.decodeIfPresent([CueMarker].self, forKey: .markers) ?? []
    }

    func end(duration: Double) -> Double { min(duration, max(inPoint + 0.1, outPoint ?? duration)) }
    func isTrimmed(duration: Double) -> Bool { inPoint > 0.0005 || end(duration: duration) < duration - 0.0005 }
    var hasFades: Bool { fadeIn > 0.0005 || fadeOut > 0.0005 }
    func changesAudio(duration: Double) -> Bool { isTrimmed(duration: duration) || hasFades }

    /// Keeps points inside the cue and fades inside the kept part.
    func normalized(duration: Double) -> CueEdit {
        var e = self
        e.inPoint = min(max(0, inPoint.isFinite ? inPoint : 0), max(0, duration - 0.1))
        let out = end(duration: duration)
        e.outPoint = out >= duration - 0.0005 ? nil : out
        let length = out - e.inPoint
        e.fadeIn = min(length / 2, max(0, fadeIn.isFinite ? fadeIn : 0))
        e.fadeOut = min(length / 2, max(0, fadeOut.isFinite ? fadeOut : 0))
        e.markers = markers.filter { $0.time.isFinite && $0.time >= 0 && $0.time <= duration }.sorted { $0.time < $1.time }
        return e
    }

    /// FFmpeg filters for the in/out points and edge fades, at the source sample rate. `canCut` is false for video
    /// outputs, where the head and tail are silenced instead of removed.
    func filters(duration: Double, sampleRate: Int, canCut: Bool) -> [String] {
        let e = normalized(duration: duration)
        guard e.changesAudio(duration: duration) else { return [] }
        let rate = Double(sampleRate)
        func samples(_ t: Double) -> Int { Int((t * rate).rounded()) }
        let start = e.inPoint, end = e.end(duration: duration)
        var list: [String] = []
        let trimmed = e.isTrimmed(duration: duration)
        // A cut gets at least a click-guard fade; the head of a cue that already starts at 0 needs none.
        let fadeIn = max(e.fadeIn, start > 0.0005 ? Self.clickGuard : 0)
        let fadeOut = max(e.fadeOut, end < duration - 0.0005 ? Self.clickGuard : 0)
        if canCut {
            if trimmed { list.append("atrim=start_sample=\(samples(start)):end_sample=\(samples(end)),asetpts=PTS-STARTPTS") }
            let length = end - start
            if fadeIn > 0 { list.append("afade=t=in:ss=0:ns=\(max(1, samples(fadeIn))):curve=\(e.fadeShape.ffmpeg)") }
            if fadeOut > 0 { list.append("afade=t=out:ss=\(samples(length - fadeOut)):ns=\(max(1, samples(fadeOut))):curve=\(e.fadeShape.ffmpeg)") }
        } else {
            // Silence before the in point and after the out point; the fades sit inside the kept part.
            if fadeIn > 0 { list.append("afade=t=in:ss=\(samples(start)):ns=\(max(1, samples(fadeIn))):curve=\(e.fadeShape.ffmpeg)") }
            if fadeOut > 0 { list.append("afade=t=out:ss=\(samples(end - fadeOut)):ns=\(max(1, samples(fadeOut))):curve=\(e.fadeShape.ffmpeg)") }
        }
        return list
    }

    /// Head and tail silence to trim: in just before the first sound, out just after the last, leaving `handle` seconds.
    static func trimmedToSound(_ stats: StereoStats, duration: Double, handle: Double = 0.1, keeping edit: CueEdit) -> CueEdit {
        var e = edit
        e.inPoint = max(0, stats.headSilence - handle)
        let out = duration - max(0, stats.tailSilence - handle)
        e.outPoint = out >= duration - 0.0005 ? nil : out
        if e.fadeIn < 0.01 { e.fadeIn = 0.01 }
        if e.fadeOut < 0.05 { e.fadeOut = 0.05 }
        return e.normalized(duration: duration)
    }
}

extension ProcessingSettings {
    /// Everything edited by hand on this cue, applied before any processing: clip gain, then in/out points and edge fades.
    func editFilters(duration: Double, sampleRate: Int, canCut: Bool) -> String? {
        var list: [String] = []
        if let clip = ClipGain.filter(clipGain) { list.append(clip) }
        if let edit { list += edit.filters(duration: duration, sampleRate: sampleRate, canCut: canCut) }
        return list.isEmpty ? nil : list.joined(separator: ",")
    }
}

/// Everything undoable in the editor for one cue.
struct CueEditState: Equatable, Sendable {
    var regions: [GainRegion]
    var edit: CueEdit
}

extension ClipGain {
    /// Gain of the in/out points and edge fades at time t (0 outside the kept part, ramps across the fades).
    static func edgeGain(at t: Double, edit: CueEdit?, duration: Double) -> Double {
        guard let edit, edit.changesAudio(duration: duration) else { return 1 }
        let e = edit.normalized(duration: duration), start = e.inPoint, end = e.end(duration: duration)
        guard t >= start, t <= end else { return 0 }
        var g = 1.0
        let fi = max(e.fadeIn, start > 0.0005 ? CueEdit.clickGuard : 0), fo = max(e.fadeOut, end < duration - 0.0005 ? CueEdit.clickGuard : 0)
        if fi > 0, t < start + fi { g *= (t - start) / fi }
        if fo > 0, t > end - fo { g *= (end - t) / fo }
        return max(0, min(1, g))
    }
    /// Whole edit envelope (clip gain × edges) at time t.
    static func envelope(at t: Double, regions: [GainRegion]?, edit: CueEdit?, duration: Double) -> Double {
        multiplier(at: t, regions: active(regions)) * edgeGain(at: t, edit: edit, duration: duration)
    }
}
