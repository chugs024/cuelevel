import SwiftUI
import AVFoundation

// Plays the original with the edits applied live, as volume ramps on the audio track: sections, trims, fades and the
// fader. Volume can't go above 1, so when the edits boost past the original the whole preview is turned down by the
// same amount; the changes between stretches are what you hear exactly. Bypass plays the untouched original.

@MainActor
final class EditorPlayer: ObservableObject {
    @Published var isPlaying = false
    @Published var time = 0.0
    @Published var bypass = false { didSet { applyMix() } }
    /// dB the preview is turned down by so boosts fit (0 when nothing is boosted past the original).
    @Published private(set) var headroom = 0.0
    let player = AVPlayer()
    private var item: AVPlayerItem?
    private var track: AVAssetTrack?
    private var observer: Any?
    private var endObserver: NSObjectProtocol?
    private var pending: Task<Void, Never>?
    private var envelope: ((Double) -> Double)?
    private var outputGain = 0.0
    private var breakpoints: [Double] = []
    private var duration = 0.0
    /// Loop the visible part of the cue.
    var loopRange: ClosedRange<Double>?

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            Task { @MainActor in
                guard let self else { return }
                self.time = CMTimeGetSeconds(t)
                if let loop = self.loopRange, self.isPlaying, self.time >= loop.upperBound { self.seek(loop.lowerBound) }
            }
        }
    }

    func load(_ url: URL, duration: Double) async {
        self.duration = duration
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        self.item = item
        track = try? await asset.loadTracks(withMediaType: .audio).first
        player.replaceCurrentItem(with: item)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.isPlaying = false; self?.seek(0) }
        }
        applyMix()
    }

    /// New edits: the envelope (linear gain at a time), where it changes, and the gain in dB on top.
    func update(envelope: @escaping (Double) -> Double, breakpoints: [Double], gain: Double) {
        self.envelope = envelope; self.breakpoints = breakpoints; outputGain = gain
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled else { return }
            self?.applyMix()
        }
    }

    private func applyMix() {
        guard let item, let track else { return }
        guard !bypass, let envelope, duration > 0 else { item.audioMix = nil; headroom = 0; return }
        // Sample the envelope at every point where it changes, and every 50 ms through fades.
        var times = Set(breakpoints.map { max(0, min(duration, $0)) })
        times.insert(0); times.insert(duration)
        let sorted = times.sorted()
        var points: [Double] = []
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            points.append(a)
            if b - a <= 3 { var t = a + 0.05; while t < b { points.append(t); t += 0.05 } }
        }
        points.append(duration)
        let linear = pow(10, outputGain / 20)
        let values = points.map { envelope($0) * linear }
        let loudest = values.max() ?? 1
        let scale = loudest > 1 ? 1 / loudest : 1
        headroom = loudest > 1 ? 20 * log10(loudest) : 0
        let params = AVMutableAudioMixInputParameters(track: track)
        for i in 0 ..< points.count - 1 {
            let range = CMTimeRange(start: CMTime(seconds: points[i], preferredTimescale: 48000), end: CMTime(seconds: points[i + 1], preferredTimescale: 48000))
            params.setVolumeRamp(fromStartVolume: Float(values[i] * scale), toEndVolume: Float(values[i + 1] * scale), timeRange: range)
        }
        let mix = AVMutableAudioMix(); mix.inputParameters = [params]
        item.audioMix = mix
    }

    func toggle() { isPlaying ? pause() : play() }
    func play() {
        try? AVAudioSession.sharedInstance().setActive(true)
        if let loop = loopRange, time < loop.lowerBound || time >= loop.upperBound { seek(loop.lowerBound) }
        else if duration > 0, time >= duration - 0.05 { seek(0) }
        player.play(); isPlaying = true
    }
    func pause() { player.pause(); isPlaying = false }
    func seek(_ seconds: Double) {
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 48000), toleranceBefore: .zero, toleranceAfter: .zero); time = seconds
    }
    func stop() { pause(); player.replaceCurrentItem(with: nil) }
}
