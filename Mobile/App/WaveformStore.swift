import SwiftUI
import AVFoundation

// The editor's waveform: every channel of the cue summarised once (lowest, highest and RMS value of each small block of
// samples), and, when you zoom in past that, the exact samples of the part on screen read straight from the file. The
// waveform is drawn per screen pixel from these, so it stays sharp at every zoom, down to single samples.

@MainActor
final class WaveformStore: ObservableObject {
    struct Lane { var name: String; var mins: [Float]; var maxs: [Float]; var meanSquares: [Float] }
    struct Detail { var start: Int; var samples: [[Float]] }

    @Published private(set) var lanes: [Lane] = []
    @Published private(set) var ready = false
    @Published private(set) var detail: Detail?
    private(set) var rate: Double = 48000
    private(set) var block = 64
    private(set) var frames = 0
    private var media: OpenedMedia?
    private var detailTask: Task<Void, Never>?
    private var detailWanted: ClosedRange<Int>?

    func load(_ url: URL, foldSurround: Bool, duration: Double) async {
        guard let media = try? await MediaReader.open(url, foldSurround: foldSurround) else { return }
        self.media = media
        rate = media.sampleRate
        let total = max(1, Int(duration * media.sampleRate))
        // Blocks of at least 64 samples, at most 300 000 per channel (an hour at 48 kHz: 576-sample blocks).
        let block = max(64, Int((Double(total) / 300_000).rounded(.up)))
        self.block = block
        let names = media.map.shortNames
        let result = await Task.detached(priority: .userInitiated) { () -> ([Lane], Int) in
            let n = media.channels
            var mins = [[Float]](repeating: [], count: n), maxs = mins, sq = mins
            for c in 0 ..< n { mins[c].reserveCapacity(total / block + 2); maxs[c].reserveCapacity(total / block + 2); sq[c].reserveCapacity(total / block + 2) }
            var lo = [Float](repeating: .greatestFiniteMagnitude, count: n), hi = [Float](repeating: -.greatestFiniteMagnitude, count: n)
            var sum = [Double](repeating: 0, count: n)
            var filled = 0, frames = 0
            try? MediaReader.decode(media) { chunk, _ in
                let count = chunk[0].count
                var i = 0
                while i < count {
                    let take = min(count - i, block - filled)
                    for c in 0 ..< n {
                        chunk[c].withUnsafeBufferPointer { p in
                            var l = lo[c], h = hi[c], s = sum[c]
                            for k in i ..< i + take { let v = p[k]; if v < l { l = v }; if v > h { h = v }; s += Double(v * v) }
                            lo[c] = l; hi[c] = h; sum[c] = s
                        }
                    }
                    filled += take; i += take
                    if filled == block {
                        for c in 0 ..< n { mins[c].append(lo[c]); maxs[c].append(hi[c]); sq[c].append(Float(sum[c] / Double(block))); lo[c] = .greatestFiniteMagnitude; hi[c] = -.greatestFiniteMagnitude; sum[c] = 0 }
                        filled = 0
                    }
                }
                frames += count
            }
            if filled > 0 { for c in 0 ..< n { mins[c].append(lo[c]); maxs[c].append(hi[c]); sq[c].append(Float(sum[c] / Double(filled))) } }
            return ((0 ..< n).map { Lane(name: names.indices.contains($0) ? names[$0] : "\($0 + 1)", mins: mins[$0], maxs: maxs[$0], meanSquares: sq[$0]) }, frames)
        }.value
        lanes = result.0; frames = result.1
        ready = true
    }

    /// Asks for the exact samples of `window` when the screen shows fewer than one block per pixel there.
    func need(window: ClosedRange<Double>, pixels: Int) {
        guard ready, let media, pixels > 0 else { return }
        let first = Int(window.lowerBound * rate), last = Int(window.upperBound * rate)
        let perPixel = Double(last - first) / Double(pixels)
        guard perPixel < Double(block) * 1.5 else { return }
        if let d = detail, d.start <= first, d.start + (d.samples.first?.count ?? 0) >= last { return }
        if let w = detailWanted, w.lowerBound <= first, w.upperBound >= last { return }
        // Read the window and half a window either side, so small scrolls don't need a new read.
        let span = last - first
        let from = max(0, first - span / 2), to = min(frames, last + span / 2)
        guard to > from, to - from <= 8_000_000 else { return }
        detailWanted = from ... to
        detailTask?.cancel()
        let rate = self.rate
        detailTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard !Task.isCancelled else { return }
            let samples = await Task.detached(priority: .userInitiated) { () -> [[Float]]? in
                var out = [[Float]](repeating: [], count: media.channels)
                var position: Int?
                let range = CMTimeRange(start: CMTime(value: CMTimeValue(from), timescale: CMTimeScale(rate)),
                                        duration: CMTime(value: CMTimeValue(to - from), timescale: CMTimeScale(rate)))
                do {
                    try MediaReader.decode(media, range: range) { chunk, time in
                        if position == nil { position = Int((CMTimeGetSeconds(time) * rate).rounded()) }
                        for c in chunk.indices where c < out.count { out[c].append(contentsOf: chunk[c]) }
                    }
                } catch { return nil }
                // Align to the first sample asked for (decoders can start a little early).
                let skip = max(0, from - (position ?? from))
                return out.map { Array($0.dropFirst(skip)) }
            }.value
            guard let self, !Task.isCancelled, let samples else { return }
            self.detail = Detail(start: from, samples: samples)
            self.detailWanted = nil
        }
    }

    /// Lowest and highest sample and the RMS in one channel between two sample positions.
    func column(_ c: Int, from a: Int, to b: Int) -> (lo: Float, hi: Float, rms: Float)? {
        guard lanes.indices.contains(c), b > a else { return nil }
        if let d = detail, a >= d.start, b <= d.start + (d.samples[c].count), b - a < block * 2 {
            let s = d.samples[c]
            var lo: Float = .greatestFiniteMagnitude, hi: Float = -.greatestFiniteMagnitude, sum: Float = 0
            for k in (a - d.start) ..< (b - d.start) { let v = s[k]; if v < lo { lo = v }; if v > hi { hi = v }; sum += v * v }
            return (lo, hi, (sum / Float(b - a)).squareRoot())
        }
        let lane = lanes[c]
        let i0 = max(0, a / block), i1 = min(lane.mins.count, max(i0 + 1, (b + block - 1) / block))
        guard i0 < i1 else { return nil }
        var lo: Float = .greatestFiniteMagnitude, hi: Float = -.greatestFiniteMagnitude, sum: Float = 0
        for i in i0 ..< i1 { if lane.mins[i] < lo { lo = lane.mins[i] }; if lane.maxs[i] > hi { hi = lane.maxs[i] }; sum += lane.meanSquares[i] }
        return (lo, hi, (sum / Float(i1 - i0)).squareRoot())
    }

    /// The exact samples between two positions, when they're loaded (deep zoom, drawn as a line).
    func samples(_ c: Int, from a: Int, to b: Int) -> ArraySlice<Float>? {
        guard let d = detail, d.samples.indices.contains(c), a >= d.start, b <= d.start + d.samples[c].count, b > a else { return nil }
        return d.samples[c][(a - d.start) ..< (b - d.start)]
    }
}
