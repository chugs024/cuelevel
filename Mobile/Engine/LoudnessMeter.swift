import Foundation
import Accelerate

// CueLevel for iPhone and iPad: a streaming loudness meter (ITU-R BS.1770-4 / EBU R 128) in Swift and Accelerate.
// It replaces FFmpeg's ebur128, loudnorm and astats, which can't run on iOS. The Mac test suite checks its results
// against FFmpeg on every build (Tests/mobile-engine-tests.swift).
//
// Feed it stereo float audio at the source sample rate (Mono and surround are downmixed by MediaReader the same way
// FFmpeg's aformat=channel_layouts=stereo does). It produces, per 100 ms step, the momentary (400 ms) and short-term
// (3 s) loudness, and at the end integrated loudness, loudness range, true peak, sample peak, RMS, peak count and DC.

final class LoudnessMeter {
    let sampleRate: Double
    // K-weighting: a high-shelf and the RLB high-pass, as two biquad sections per channel.
    private var setup: vDSP_biquad_Setup
    private var delayL: [Float]
    private var delayR: [Float]
    // 100 ms segments: energy of K-weighted L+R, and sample count (segments can be 1 sample longer at odd rates).
    private var segmentEnergy: [Double] = []
    private var segmentLength: [Int] = []
    private var currentEnergy = 0.0
    private var currentLength = 0
    private var samplesSeen = 0
    private var nextBoundary: Int
    private var segmentIndex = 0
    // True peak: polyphase interpolation filter.
    private let upsample: Int
    private let phases: [[Float]]          // each phase's taps, reversed for vDSP_conv
    private let taps: Int
    private var historyL: [Float]
    private var historyR: [Float]
    private(set) var truePeakLinear: Float = 0
    // Sample statistics (astats "Overall" equivalents).
    private(set) var samplePeakLinear: Float = 0
    private var peakCount = 0
    private var sumSquares = 0.0
    private var sum = 0.0
    private var valueCount = 0
    /// Momentary and short-term loudness every 100 ms (LUFS, clamped to −70…0 like CueLevel's FFmpeg readings).
    private(set) var momentary: [Float] = []
    private(set) var shortTerm: [Float] = []
    /// Unclamped short-term values of complete 3 s windows, for the loudness range.
    private var shortTermFull: [Double] = []

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        let fs = sampleRate
        // Pre-filter (high shelf) and RLB high-pass, coefficients for any rate (libebur128's derivation of BS.1770).
        var f0 = 1681.974450955533, Q = 0.7071752369554196
        let G = 3.999843853973347
        var K = tan(Double.pi * f0 / fs)
        let Vh = pow(10, G / 20), Vb = pow(Vh, 0.4996667741545416)
        var a0 = 1 + K / Q + K * K
        let pb = [(Vh + Vb * K / Q + K * K) / a0, 2 * (K * K - Vh) / a0, (Vh - Vb * K / Q + K * K) / a0]
        let pa = [2 * (K * K - 1) / a0, (1 - K / Q + K * K) / a0]
        f0 = 38.13547087602444; Q = 0.5003270373238773; K = tan(Double.pi * f0 / fs)
        a0 = 1 + K / Q + K * K
        let ra = [2 * (K * K - 1) / a0, (1 - K / Q + K * K) / a0]
        // vDSP order per section: b0, b1, b2, a1, a2.
        let coefficients: [Double] = [pb[0], pb[1], pb[2], pa[0], pa[1], 1, -2, 1, ra[0], ra[1]]
        setup = vDSP_biquad_CreateSetup(coefficients, 2)!
        delayL = [Float](repeating: 0, count: 2 * 2 + 2)
        delayR = [Float](repeating: 0, count: 2 * 2 + 2)
        nextBoundary = Int((fs / 10).rounded())
        // True peak at ≥ 192 kHz like FFmpeg's loudnorm: 4× at 44.1/48 kHz, 2× at 88.2/96 kHz.
        upsample = fs < 96000 ? 4 : (fs < 192000 ? 2 : 1)
        taps = 24
        phases = LoudnessMeter.interpolationPhases(factor: upsample, tapsPerPhase: taps)
        historyL = [Float](repeating: 0, count: taps - 1)
        historyR = [Float](repeating: 0, count: taps - 1)
    }
    deinit { vDSP_biquad_DestroySetup(setup) }

    /// Windowed-sinc interpolator split into its phases, each normalised to unity gain at DC.
    static func interpolationPhases(factor L: Int, tapsPerPhase T: Int) -> [[Float]] {
        guard L > 1 else { return [[Float](repeating: 0, count: T - 1) + [1]] }
        let N = L * T
        let centre = Double(N - 1) / 2
        let cutoff = 0.5 / Double(L) * 0.98         // just below the original Nyquist
        var h = [Double](repeating: 0, count: N)
        for n in 0..<N {
            let x = Double(n) - centre
            let sinc = x == 0 ? 2 * cutoff : sin(2 * Double.pi * cutoff * x) / (Double.pi * x)
            // Blackman–Harris window
            let w = 0.35875 - 0.48829 * cos(2 * Double.pi * Double(n) / Double(N - 1)) + 0.14128 * cos(4 * Double.pi * Double(n) / Double(N - 1)) - 0.01168 * cos(6 * Double.pi * Double(n) / Double(N - 1))
            h[n] = sinc * w
        }
        return (0..<L).map { p in
            var phase = (0..<T).map { k in h[k * L + p] }
            let gain = phase.reduce(0, +)
            if gain != 0 { phase = phase.map { $0 / gain } }
            return phase.reversed().map(Float.init)   // vDSP_conv correlates; reversed taps make it a convolution
        }
    }

    /// Adds `frames` stereo frames (separate left and right arrays).
    func add(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        // Sample statistics on the unweighted signal.
        var maxL: Float = 0, maxR: Float = 0
        vDSP_maxmgv(left, 1, &maxL, vDSP_Length(frames)); vDSP_maxmgv(right, 1, &maxR, vDSP_Length(frames))
        let chunkPeak = max(maxL, maxR)
        if chunkPeak > samplePeakLinear { samplePeakLinear = chunkPeak; peakCount = 0 }
        if chunkPeak >= samplePeakLinear * 0.999_999 && samplePeakLinear > 0 {
            let limit = samplePeakLinear * 0.999_999
            for i in 0..<frames { if abs(left[i]) >= limit { peakCount += 1 }; if abs(right[i]) >= limit { peakCount += 1 } }
        }
        var sqL: Float = 0, sqR: Float = 0, sL: Float = 0, sR: Float = 0
        vDSP_svesq(left, 1, &sqL, vDSP_Length(frames)); vDSP_svesq(right, 1, &sqR, vDSP_Length(frames))
        vDSP_sve(left, 1, &sL, vDSP_Length(frames)); vDSP_sve(right, 1, &sR, vDSP_Length(frames))
        sumSquares += Double(sqL) + Double(sqR); sum += Double(sL) + Double(sR); valueCount += 2 * frames

        truePeak(left, frames: frames, history: &historyL)
        truePeak(right, frames: frames, history: &historyR)

        // K-weighting, then 100 ms segment energies.
        var kl = [Float](repeating: 0, count: frames), kr = [Float](repeating: 0, count: frames)
        vDSP_biquad(setup, &delayL, left, 1, &kl, 1, vDSP_Length(frames))
        vDSP_biquad(setup, &delayR, right, 1, &kr, 1, vDSP_Length(frames))
        var offset = 0
        while offset < frames {
            let take = min(frames - offset, nextBoundary - samplesSeen)
            var e1: Float = 0, e2: Float = 0
            kl.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + offset, 1, &e1, vDSP_Length(take)) }
            kr.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + offset, 1, &e2, vDSP_Length(take)) }
            currentEnergy += Double(e1) + Double(e2); currentLength += take
            samplesSeen += take; offset += take
            if samplesSeen == nextBoundary { closeSegment() }
        }
    }

    private func truePeak(_ x: UnsafePointer<Float>, frames: Int, history: inout [Float]) {
        let T = taps
        var padded = history; padded.append(contentsOf: UnsafeBufferPointer(start: x, count: frames))
        var out = [Float](repeating: 0, count: frames)
        var best: Float = 0
        for phase in phases {
            padded.withUnsafeBufferPointer { p in
                phase.withUnsafeBufferPointer { h in
                    vDSP_conv(p.baseAddress!, 1, h.baseAddress!, 1, &out, 1, vDSP_Length(frames), vDSP_Length(T))
                }
            }
            var m: Float = 0; vDSP_maxmgv(out, 1, &m, vDSP_Length(frames)); best = max(best, m)
        }
        truePeakLinear = max(truePeakLinear, best)
        history = Array(padded.suffix(T - 1))
    }

    private func closeSegment() {
        segmentEnergy.append(currentEnergy); segmentLength.append(currentLength)
        currentEnergy = 0; currentLength = 0
        segmentIndex += 1
        nextBoundary = Int((Double(segmentIndex + 1) * sampleRate / 10).rounded())
        let n = segmentEnergy.count
        let m = window(last: 4, of: n), s = window(last: 30, of: n)
        momentary.append(Float(max(-70, min(0, Self.lufs(m)))))
        shortTerm.append(Float(max(-70, min(0, Self.lufs(s)))))
        if n >= 30 { shortTermFull.append(Self.lufs(s)) }
    }

    /// Mean square of the last `count` segments, zero-padded at the start (as FFmpeg's ebur128 ring buffer is).
    private func window(last count: Int, of n: Int) -> Double {
        let lo = max(0, n - count)
        var e = 0.0
        for i in lo..<n { e += segmentEnergy[i] }
        let nominal = Double(count) * sampleRate / 10
        return e / nominal
    }

    static func lufs(_ meanSquare: Double) -> Double { meanSquare > 0 ? -0.691 + 10 * log10(meanSquare) : -.infinity }

    /// Finishes the measurement. Throws when the audio is silent or too quiet to gate.
    func finish() throws -> Measurement {
        if currentLength > 0 { segmentEnergy.append(currentEnergy); segmentLength.append(currentLength); currentEnergy = 0; currentLength = 0 }
        // Gating blocks: 400 ms with 75 % overlap, i.e. every 4 consecutive segments.
        var blocks: [Double] = []
        if segmentEnergy.count >= 4 {
            for k in 3..<segmentEnergy.count {
                let e = segmentEnergy[k - 3] + segmentEnergy[k - 2] + segmentEnergy[k - 1] + segmentEnergy[k]
                let n = segmentLength[k - 3] + segmentLength[k - 2] + segmentLength[k - 1] + segmentLength[k]
                if n > 0 { blocks.append(e / Double(n)) }
            }
        } else if !segmentEnergy.isEmpty {
            // Shorter than 400 ms: one block over everything.
            let n = segmentLength.reduce(0, +); if n > 0 { blocks.append(segmentEnergy.reduce(0, +) / Double(n)) }
        }
        let absolute = blocks.filter { Self.lufs($0) > -70 }
        guard !absolute.isEmpty else { throw cueError("The soundtrack is silent or too quiet to measure reliably.") }
        let relativeGate = Self.lufs(absolute.reduce(0, +) / Double(absolute.count)) - 10
        let gated = absolute.filter { Self.lufs($0) > relativeGate }
        let integrated = Self.lufs(gated.reduce(0, +) / Double(max(1, gated.count)))
        // Loudness range (EBU Tech 3342): short-term values, −70 absolute and −20 LU relative gate, P95 − P10.
        var range = 0.0
        let stAbsolute = shortTermFull.filter { $0 > -70 }
        if stAbsolute.count >= 2 {
            let stGate = Self.lufs(stAbsolute.map { pow(10, ($0 + 0.691) / 10) }.reduce(0, +) / Double(stAbsolute.count)) - 20
            let kept = stAbsolute.filter { $0 > stGate }.sorted()
            if kept.count >= 2 {
                func pct(_ q: Double) -> Double { kept[Int((Double(kept.count - 1) * q).rounded())] }
                range = max(0, pct(0.95) - pct(0.10))
            }
        }
        let peak = max(truePeakLinear, samplePeakLinear)
        var m = Measurement(integrated: integrated, truePeak: peak > 0 ? 20 * log10(Double(peak)) : -.infinity,
                            loudnessRange: range, threshold: relativeGate, offset: 0)
        m.samplePeak = samplePeakLinear > 0 ? 20 * log10(Double(samplePeakLinear)) : nil
        m.rms = valueCount > 0 && sumSquares > 0 ? 10 * log10(sumSquares / Double(valueCount)) : nil
        m.peakCount = Double(peakCount)
        m.dcOffset = valueCount > 0 ? sum / Double(valueCount) : nil
        guard m.truePeak.isFinite else { throw cueError("The soundtrack is silent or too quiet to measure reliably.") }
        return m
    }
}

/// Waveform peaks, stereo correlation and leading/trailing silence, as the Mac's WaveCollector, at the source rate.
final class WaveformBuilder {
    static let audible: Float = 0.001   // −60 dBFS
    private(set) var peaks: [Float]
    private(set) var detail: [Float]
    private let perBin: Double
    private let perDetail: Double
    private(set) var frame = 0
    private var sumL2 = 0.0, sumR2 = 0.0, sumLR = 0.0
    private var firstAudible: Int?
    private var lastAudible: Int?
    let sampleRate: Double

    init(duration: Double, sampleRate: Double, bins: Int = 1000) {
        self.sampleRate = sampleRate
        let total = max(1, duration * sampleRate)
        peaks = [Float](repeating: 0, count: bins)
        perBin = max(1, total / Double(bins))
        // Fine waveform for Even out: 200 peaks per second (5 ms), at most 720 000 points (as on the Mac).
        let detailBins = Int(min(720_000, max(1000, duration * 200)))
        detail = [Float](repeating: 0, count: detailBins)
        perDetail = max(1, total / Double(detailBins))
    }

    func add(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        for i in 0..<frames {
            let l = left[i], r = right[i]
            guard l.isFinite, r.isFinite else { frame += 1; continue }
            let v = max(abs(l), abs(r))
            let b = min(peaks.count - 1, Int(Double(frame) / perBin))
            if v > peaks[b] { peaks[b] = v }
            let d = min(detail.count - 1, Int(Double(frame) / perDetail))
            if v > detail[d] { detail[d] = v }
            sumL2 += Double(l * l); sumR2 += Double(r * r); sumLR += Double(l * r)
            if v > Self.audible { if firstAudible == nil { firstAudible = frame }; lastAudible = frame }
            frame += 1
        }
    }

    var stats: StereoStats {
        let d = (sumL2 * sumR2).squareRoot()
        return StereoStats(correlation: d > 0 ? sumLR / d : nil,
                           headSilence: Double(firstAudible ?? frame) / sampleRate,
                           tailSilence: Double(lastAudible.map { frame - 1 - $0 } ?? 0) / sampleRate)
    }
}

/// At most `maxPoints` values, keeping the loudest reading in each span (as the Mac's CurveCollector.reduced).
func reducedCurve(_ values: [Float], maxPoints: Int = 600) -> [Float] {
    guard values.count > maxPoints else { return values }
    let step = Double(values.count) / Double(maxPoints)
    return (0..<maxPoints).map { i in
        let start = Int(Double(i) * step), end = max(start + 1, min(values.count, Int(Double(i + 1) * step)))
        return values[start..<end].max() ?? -70
    }
}
