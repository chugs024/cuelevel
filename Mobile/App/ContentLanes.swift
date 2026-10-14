import Foundation
import AVFoundation
import SoundAnalysis

// Where a cue has speech and where it has music, from Apple's built-in sound classifier (SoundAnalysis), shown as a
// lane under the waveform. It only reads the audio: nothing is separated or changed. Results are kept per cue.

struct ContentSegment: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    /// Confidence 0–1.
    var speech: Float
    var music: Float
}

private final class ContentObserver: NSObject, SNResultsObserving, @unchecked Sendable {
    var segments: [ContentSegment] = []
    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let r = result as? SNClassificationResult else { return }
        func c(_ id: String) -> Float { Float(r.classification(forIdentifier: id)?.confidence ?? 0) }
        let speech = max(c("speech"), c("shout"), c("whispering"), c("speech_synthesizer"))
        let music = max(c("music"), c("singing"), c("choir"), c("musical_instrument"))
        let start = CMTimeGetSeconds(r.timeRange.start), end = CMTimeGetSeconds(CMTimeRangeGetEnd(r.timeRange))
        segments.append(ContentSegment(start: start, end: end, speech: speech, music: music))
    }
}

enum ContentLanes {
    /// Classifies the cue in windows of about one second. Runs on the calling thread; call it off the main thread.
    static func analyze(_ url: URL) async -> [ContentSegment]? {
        guard let media = try? await MediaReader.open(url, foldSurround: false) else { return nil }
        return await Task.detached(priority: .utility) { () -> [ContentSegment]? in
            guard let format = AVAudioFormat(standardFormatWithSampleRate: media.sampleRate, channels: 1),
                  let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else { return nil }
            request.overlapFactor = 0.5
            let observer = ContentObserver()
            let analyzer = SNAudioStreamAnalyzer(format: format)
            guard (try? analyzer.add(request, withObserver: observer)) != nil else { return nil }
            let weights = media.map.weights.map { Float($0 > 0 ? 1 : 0) }
            let used = max(1, weights.reduce(0, +))
            var position: AVAudioFramePosition = 0
            do {
                try MediaReader.decode(media) { chunk, _ in
                    let n = chunk[0].count
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { return }
                    buffer.frameLength = AVAudioFrameCount(n)
                    let out = buffer.floatChannelData![0]
                    for i in 0 ..< n { var s: Float = 0; for c in chunk.indices where c < weights.count { s += chunk[c][i] * weights[c] }; out[i] = s / used }
                    analyzer.analyze(buffer, atAudioFramePosition: position)
                    position += AVAudioFramePosition(n)
                }
            } catch { return nil }
            analyzer.completeAnalysis()
            return observer.segments.sorted { $0.start < $1.start }
        }.value
    }

    /// Stretches where speech or music is likely (confidence over 0.5 on average), merged across small gaps.
    static func stretches(_ segments: [ContentSegment], music: Bool) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        for s in segments where (music ? s.music : s.speech) >= 0.5 {
            let a = s.start + (s.end - s.start) * 0.25, b = s.end - (s.end - s.start) * 0.25   // the middle of each overlapping window
            if let last = out.last, a <= last.upperBound + 0.3 { out[out.count - 1] = last.lowerBound ... max(last.upperBound, b) }
            else { out.append(a ... b) }
        }
        return out
    }
}
