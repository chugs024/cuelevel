import Foundation
import CryptoKit
import AVFoundation

// CueLevel for iPhone and iPad: the on-device engine (Mobile/Engine) checked against the Mac's FFmpeg engine.
// Run by Scripts/run-tests.sh on the Mac CI runner, where both engines are available.

var failures = 0
/// Records a failure and carries on, so one run shows every difference (the CI log isn't readable from here, annotations are).
func check(_ condition: Bool, _ message: String) { if !condition { failures += 1; print("::error::FAIL: \(message)"); fputs("FAIL: \(message)\n", stderr) } }
var notes: [String] = []
/// Collected and printed as one annotation (GitHub keeps only a few per step).
func note(_ text: String) { notes.append(text); print(text) }
func flushNotes() { print("::notice title=Device engine vs FFmpeg::" + notes.joined(separator: "%0A")) }
func near(_ a: Double, _ b: Double, _ tolerance: Double) -> Bool { abs(a - b) <= tolerance }
func f(_ v: Double) -> String { String(format: "%7.2f", v) }
final class Bytes: @unchecked Sendable { var data = Data() }
func ffmpeg(_ args: [String]) throws { try AudioEngine.run(["-loglevel", "error", "-y"] + args, token: Cancellation()) }
func videoDigest(_ url: URL) throws -> String {
    let box = Bytes()
    try AudioEngine.run(["-i", url.path, "-map", "0:v:0", "-c", "copy", "-f", "md5", "pipe:1"], token: Cancellation(), output: { box.data.append($0) })
    return String(decoding: box.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
func sha(_ url: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() }

/// Compares the on-device analysis with FFmpeg's measurement of the same file.
func compare(_ name: String, _ url: URL, integrated: Double = 0.15, truePeak: Double = 0.3, range: Double = 1.2) async throws -> (Analysis, EvenOutData) {
    let token = Cancellation()
    let info = try AudioEngine.inspect(url, token: token)
    let reference = try AudioEngine.measure(url, token: token, duration: info.duration)
    let (mobile, data) = try await MobileEngine.analyze(url)
    let m = mobile.levels
    note("\(name): I \(f(m.integrated)) vs \(f(reference.integrated))   TP \(f(m.truePeak)) vs \(f(reference.truePeak))   LRA \(f(m.loudnessRange)) vs \(f(reference.loudnessRange))   peak \(f(m.samplePeak ?? 0)) vs \(f(reference.samplePeak ?? 0))")
    check(near(m.integrated, reference.integrated, integrated), "\(name): integrated loudness matches FFmpeg")
    check(near(m.truePeak, reference.truePeak, truePeak), "\(name): true peak matches FFmpeg")
    check(near(m.loudnessRange, reference.loudnessRange, range), "\(name): loudness range matches FFmpeg")
    // FFmpeg measures astats after its graph resamples for loudnorm (192 kHz), so its "sample peak" is close to the true peak.
    // The device reports the real sample peak: never above FFmpeg's, and within the gap to the true peak.
    if let a = m.samplePeak, let b = reference.samplePeak { check(a <= b + 0.05 && a >= b - 1.0, "\(name): sample peak consistent with FFmpeg (\(a) vs \(b))") }
    if let a = m.dcOffset, let b = reference.dcOffset { check(near(a, b, 0.0005), "\(name): DC offset matches FFmpeg") }
    check(near(mobile.info.duration, info.duration, 0.1), "\(name): duration matches FFmpeg")
    // Momentary loudness every 100 ms, as Even out reads it.
    let ff = try AudioEngine.momentaryLoudness(url, duration: info.duration, token: token).map(Double.init)
    let ours = data.momentary.map(Double.init)
    let n = min(ff.count, ours.count)
    check(abs(ff.count - ours.count) <= 3, "\(name): momentary readings every 100 ms (\(ours.count) vs \(ff.count))")
    let audible = (4..<n).filter { ff[$0] > -60 && ours[$0] > -60 }
    let meanError = audible.map { abs(ff[$0] - ours[$0]) }.reduce(0, +) / Double(max(1, audible.count))
    note("\(name) momentary: \(ours.count) readings, mean difference \(String(format: "%.3f", meanError)) LU")
    check(meanError < 0.3, "\(name): momentary loudness follows FFmpeg's ebur128")
    return (mobile, data)
}

@main struct MobileEngineTests {
    static func main() async throws {
        let area = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("mobile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: area, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: area) }
        func file(_ name: String) -> URL { area.appendingPathComponent(name) }
        let token = Cancellation()

        // Test material, made with FFmpeg.
        try ffmpeg(["-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000:duration=12", "-af", "volume=-12dB", "-ac", "2", "-c:a", "pcm_s24le", file("sine.wav").path])
        // Speech-like: pink noise in 2 s phrases with 1 s pauses, and a stretch 9 dB down from 12 s to 21 s (mono, 44.1 kHz).
        try ffmpeg(["-f", "lavfi", "-i", "anoisesrc=color=pink:sample_rate=44100:duration=36:seed=7", "-af",
                    "volume='if(lt(mod(t,3),2),0.5,0.01)':eval=frame,volume=-9dB:enable='between(t,12,21)'", "-ac", "1", "-c:a", "pcm_s16le", file("speech.wav").path])
        // Music-like at 96 kHz: steady tones with slow swells.
        try ffmpeg(["-f", "lavfi", "-i", "aevalsrc='0.2*sin(2*PI*220*t)*(0.6+0.4*sin(2*PI*0.1*t))+0.1*sin(2*PI*1760*t)|0.2*sin(2*PI*330*t)*(0.6+0.4*cos(2*PI*0.1*t))+0.1*sin(2*PI*2640*t)':s=96000:d=25",
                    "-c:a", "pcm_f32le", file("music96.wav").path])
        // Inter-sample peaks: a sine at a quarter of the sample rate, sampled 45° off its crest.
        try ffmpeg(["-f", "lavfi", "-i", "aevalsrc='0.9*sin(2*PI*11025*t+PI/4)':s=44100:d=6", "-ac", "2", "-c:a", "pcm_s24le", file("intersample.wav").path])
        // Compressed formats AVFoundation decodes on the phone.
        try ffmpeg(["-i", file("speech.wav").path, "-c:a", "aac", "-b:a", "192k", file("speech.m4a").path])
        try ffmpeg(["-i", file("speech.wav").path, "-c:a", "flac", file("speech.flac").path])
        // Video with two audio tracks (the second must be copied untouched).
        try ffmpeg(["-f", "lavfi", "-i", "testsrc2=s=640x360:r=25:d=8", "-f", "lavfi", "-i", "sine=frequency=330:sample_rate=48000:duration=8",
                    "-f", "lavfi", "-i", "sine=frequency=550:sample_rate=48000:duration=8",
                    "-map", "0:v", "-map", "1:a", "-map", "2:a", "-af", "volume=-26dB", "-c:v", "mpeg4", "-q:v", "5", "-c:a", "aac", "-b:a", "192k", "-shortest", file("show.mov").path])

        print("== Measurement: on-device engine vs FFmpeg")
        _ = try await compare("1 kHz sine, 48 kHz", file("sine.wav"), integrated: 0.1)
        let (speech, speechData) = try await compare("speech-like, mono 44.1 kHz", file("speech.wav"))
        _ = try await compare("music-like, 96 kHz float", file("music96.wav"))
        // A sine at a quarter of the sample rate, 45° off its crest: every sample is 3 dB under the true peak.
        // Its true peak is known exactly (0.9 × 0.7071 after the −3 dB stereo conversion = −3.93 dBTP); FFmpeg's resampler
        // overshoots it by about 0.6 dB, so this one is checked against the theory instead.
        let (inter, _) = try await compare("inter-sample peaks", file("intersample.wav"), truePeak: 1.0)
        check(near(inter.levels.truePeak, 20 * log10(0.9 * 0.70710678), 0.15), "true peak of a quarter-rate sine is exact (\(inter.levels.truePeak))")
        check(inter.levels.truePeak > (inter.levels.samplePeak ?? 0) + 2, "true peak sees the peaks between samples")
        _ = try await compare("AAC (M4A)", file("speech.m4a"), integrated: 0.2)
        _ = try await compare("FLAC", file("speech.flac"))
        _ = try await compare("video's first audio track", file("show.mov"), integrated: 0.2)
        check(speech.stereo?.correlation.map { $0 > 0.999 } == true, "mono reads as identical channels")
        check(speech.info.channels == 1 && speech.info.sampleRate == 44100 && !speech.info.isVideo, "speech file info")

        print("== Even out: same sections from either engine")
        let ffMomentary = try AudioEngine.momentaryLoudness(file("speech.wav"), duration: speech.info.duration, token: token).map(Double.init)
        let ffPeaks = try AudioEngine.detailWaveform(file("speech.wav"), duration: speech.info.duration, token: token)
        let ffRegions = ClipGain.evenOut(momentary: ffMomentary, duration: speech.info.duration, peaks: ffPeaks)
        let ourRegions = MobileEngine.evenOutPlan(speechData, duration: speech.info.duration, tolerance: ClipGain.evenOutTolerance, keeping: [], skipMusic: false).regions
        note("Even out FFmpeg: " + ffRegions.map { String(format: "%.1f–%.1f s %+.1f dB", $0.start, $0.end, $0.gain) }.joined(separator: ", "))
        note("Even out device: " + ourRegions.map { String(format: "%.1f–%.1f s %+.1f dB", $0.start, $0.end, $0.gain) }.joined(separator: ", "))
        check(ourRegions.count == ffRegions.count, "Even out finds the same number of stretches")
        for (a, b) in zip(ourRegions, ffRegions) {
            check(near(a.gain, b.gain, 1.0) && near(a.start, b.start, 0.35) && near(a.end, b.end, 0.35), "Even out stretch matches FFmpeg's (\(a.start)–\(a.end) \(a.gain) dB)")
        }
        check(ourRegions.contains { $0.gain > 6 && $0.start > 11 && $0.end < 22 }, "the quiet stretch is lifted")

        print("== Lossless levelling on the device")
        var settings = ProcessingSettings(); settings.target = -18; settings.peak = -1; settings.format = .lossless
        let out = area.appendingPathComponent("Levelled")
        // Audio: one gain change, measured by FFmpeg.
        let levelled = try await MobileEngine.level(file("speech.wav"), analysis: speech, settings: settings, directory: out)
        let levelledInfo = try AudioEngine.inspect(levelled.url, token: token)
        let levelledFF = try AudioEngine.measure(levelled.url, token: token, duration: levelledInfo.duration)
        note("speech → \(levelled.url.lastPathComponent): \(f(levelledFF.integrated)) LUFS, \(f(levelledFF.truePeak)) dBTP (gain \(String(format: "%+.2f", levelled.gainApplied ?? 0)), shortfall \(String(format: "%.2f", levelled.shortfall ?? 0)))")
        check(levelled.url.lastPathComponent == "speech_LVL-18.wav", "output named with the target")
        check(near(levelledFF.integrated, settings.target - (levelled.shortfall ?? 0), 0.2), "levelled audio reaches the target (FFmpeg)")
        check(levelledFF.truePeak <= settings.peak + 0.2, "levelled audio stays under the ceiling (FFmpeg)")
        check(levelledInfo.sampleRate == 44100 && levelledInfo.audioDescription.hasPrefix("pcm_s24le"), "WAV at the source rate, 24-bit")
        check(near(levelledInfo.duration, speech.info.duration, 0.01), "no samples added or lost")
        check(near(levelled.levels.integrated, levelledFF.integrated, 0.15), "the device's own verification agrees with FFmpeg")
        // A gain change only: the output divided by the gain is the input, sample for sample (within 24-bit rounding).
        let gain = pow(10, (levelled.gainApplied ?? 0) / 20)
        let source = try AVAudioFile(forReading: file("speech.wav")), result = try AVAudioFile(forReading: levelled.url)
        let a = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 44100)!, b = AVAudioPCMBuffer(pcmFormat: result.processingFormat, frameCapacity: 44100)!
        try source.read(into: a, frameCount: 44100); try result.read(into: b, frameCount: 44100)
        var worst: Float = 0
        for i in 0..<Int(a.frameLength) { worst = max(worst, abs(b.floatChannelData![0][i] / Float(gain) - a.floatChannelData![0][i] * 0.70710677)) }
        note("largest sample difference after removing the gain: \(worst)")
        check(worst < 2e-6, "levelling is one exact gain change")

        // Float sources stay float; 96 kHz stays 96 kHz.
        let (music, _) = try await MobileEngine.analyze(file("music96.wav"))
        let musicOut = try await MobileEngine.level(file("music96.wav"), analysis: music, settings: settings, directory: out)
        let musicInfo = try AudioEngine.inspect(musicOut.url, token: token)
        check(musicInfo.sampleRate == 96000 && musicInfo.audioDescription.hasPrefix("pcm_f32le"), "float 96 kHz source stays float at 96 kHz")

        // Hand edits: a +6 dB section and in/out points.
        var edited = settings
        edited.clipGain = [GainRegion(start: 4, end: 10, gain: 6, fadeIn: 0.05, fadeOut: 0.05)]
        var edit = CueEdit(); edit.inPoint = 1.0; edit.outPoint = 25.0; edit.fadeOut = 0.5
        edited.edit = edit
        let editedOut = try await MobileEngine.level(file("speech.wav"), analysis: speech, settings: edited, directory: out)
        let editedInfo = try AudioEngine.inspect(editedOut.url, token: token)
        let editedFF = try AudioEngine.measure(editedOut.url, token: token, duration: editedInfo.duration)
        note("edited → \(f(editedInfo.duration)) s, \(f(editedFF.integrated)) LUFS, \(f(editedFF.truePeak)) dBTP")
        check(near(editedInfo.duration, 24.0, 0.01), "in and out points cut the audio file")
        check(near(editedFF.integrated, settings.target - (editedOut.shortfall ?? 0), 0.25), "edited cue is measured after the edits, then levelled")
        check(editedOut.warnings.contains { $0.contains("1 section") }, "hand-drawn sections are noted")

        // Video: picture copied bit for bit, levelled PCM first track, second track kept.
        let (show, _) = try await MobileEngine.analyze(file("show.mov"))
        check(show.info.isVideo && show.info.audioStreams == 2 && show.info.videoCodec == "mpeg4", "video info")
        let video = try await MobileEngine.level(file("show.mov"), analysis: show, settings: settings, directory: out)
        let videoInfo = try AudioEngine.inspect(video.url, token: token)
        let videoFF = try AudioEngine.measure(video.url, token: token, duration: videoInfo.duration)
        note("video → \(video.url.lastPathComponent): \(f(videoFF.integrated)) LUFS, \(f(videoFF.truePeak)) dBTP, \(videoInfo.audioStreams ?? 0) audio tracks, \(videoInfo.audioDescription)")
        check(video.url.pathExtension == "mov", "video saved as MOV")
        check(try videoDigest(video.url) == videoDigest(file("show.mov")), "picture copied bit for bit")
        check(videoInfo.audioStreams == 2, "second audio track kept")
        check(videoInfo.audioDescription.hasPrefix("pcm_"), "levelled track is uncompressed PCM")
        check(near(videoFF.integrated, settings.target - (video.shortfall ?? 0), 0.25), "video's audio reaches the target (FFmpeg)")
        check(near(videoInfo.duration, show.info.duration, 0.1), "video keeps its length")

        // Already good: an exact copy.
        let copy = try MobileEngine.unchangedCopy(file("speech.flac"), analysis: speech, settings: settings, directory: out)
        check(try sha(copy.url) == sha(file("speech.flac")), "already-good cue is copied bit for bit")
        check(copy.url.lastPathComponent == "speech_LVL-18.flac", "copy keeps its type")
        let again = try MobileEngine.unchangedCopy(file("speech.flac"), analysis: speech, settings: settings, directory: out)
        check(again.url.lastPathComponent == "speech_LVL-18 2.flac", "a second copy doesn't overwrite the first")

        // Unreadable files give plain reasons.
        FileManager.default.createFile(atPath: file("empty.wav").path, contents: Data())
        do { _ = try await MobileEngine.analyze(file("empty.wav")); check(false, "empty file rejected") } catch { check(error.localizedDescription.contains("empty"), "empty file reason: \(error.localizedDescription)") }
        try Data("not audio at all".utf8).write(to: file("fake.wav"))
        do { _ = try await MobileEngine.analyze(file("fake.wav")); check(false, "fake file rejected") } catch { check(error.localizedDescription.contains("can't read"), "fake file reason: \(error.localizedDescription)") }
        try ffmpeg(["-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo", "-t", "5", "-c:a", "pcm_s16le", file("silent.wav").path])
        do { _ = try await MobileEngine.analyze(file("silent.wav")); check(false, "silent file rejected") } catch { check(error.localizedDescription.contains("silent"), "silent file reason: \(error.localizedDescription)") }

        flushNotes()
        if failures > 0 { fputs("\(failures) mobile engine checks failed\n", stderr); exit(1) }
        print("MOBILE ENGINE CHECKS PASSED")
    }
}
