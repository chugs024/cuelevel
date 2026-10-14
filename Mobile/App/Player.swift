import SwiftUI
import AVFoundation
import AVKit

// Playback for one cue: the original or the levelled copy, switching at the same moment for a fair before/after.
// "Match" plays the louder of the two quieter by the levelling gain, so you compare the sound, not the volume.

@MainActor
final class CuePlayer: ObservableObject {
    @Published var isPlaying = false
    @Published var time = 0.0
    @Published var duration = 0.0
    @Published var showingLevelled = false
    @Published var match = true
    let player = AVPlayer()
    private var observer: Any?
    private var endObserver: NSObjectProtocol?
    private(set) var original: URL?
    private(set) var levelled: URL?
    private var gain = 0.0

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            Task { @MainActor in self?.time = CMTimeGetSeconds(t) }
        }
    }

    func load(original: URL, levelled: URL?, gain: Double, duration: Double) {
        guard original != self.original || levelled != self.levelled else { return }
        pause()
        self.original = original; self.levelled = levelled; self.gain = gain; self.duration = duration
        showingLevelled = levelled != nil
        swap(to: showingLevelled, at: 0)
    }

    private func swap(to levelledCopy: Bool, at seconds: Double) {
        guard let url = levelledCopy ? (levelled ?? original) : original else { return }
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.isPlaying = false; self?.player.seek(to: .zero); self?.time = 0 }
        }
        applyVolume(levelledCopy)
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 48000), toleranceBefore: .zero, toleranceAfter: .zero)
        time = seconds
    }

    private func applyVolume(_ levelledCopy: Bool) {
        guard match, levelled != nil else { player.volume = 1; return }
        // Turn down whichever version is louder by the gain between them.
        if gain > 0 { player.volume = levelledCopy ? Float(pow(10, -gain / 20)) : 1 }
        else { player.volume = levelledCopy ? 1 : Float(pow(10, gain / 20)) }
    }

    func toggle() { isPlaying ? pause() : play() }
    func play() {
        try? AVAudioSession.sharedInstance().setActive(true)
        if duration > 0, time >= duration - 0.05 { seek(0) }
        player.play(); isPlaying = true
    }
    func pause() { player.pause(); isPlaying = false }
    func seek(_ seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 48000), toleranceBefore: .zero, toleranceAfter: .zero); time = seconds
    }
    func showLevelled(_ on: Bool) {
        guard on != showingLevelled, levelled != nil else { return }
        let was = isPlaying, at = time
        showingLevelled = on
        swap(to: on, at: at)
        if was { player.play() }
    }
    func setMatch(_ on: Bool) { match = on; applyVolume(showingLevelled) }
    func stop() { pause(); player.replaceCurrentItem(with: nil); original = nil; levelled = nil }
}

/// The video picture for video cues (shown under a disclosure, like the Mac).
struct PictureView: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let c = AVPlayerViewController(); c.player = player; c.showsPlaybackControls = false; c.videoGravity = .resizeAspect; return c
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) { controller.player = player }
}
