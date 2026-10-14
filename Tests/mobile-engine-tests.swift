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
/// Integrated loudness from FFmpeg's ebur128 filter, the BS.1770 reference meter, on the file's own channels (surround
/// weighted, LFE left out). (loudnorm, which the Mac app measures with, reads fast-decaying material such as stings up to
/// about 0.4 LU lower; the device follows ebur128.)
func referenceLoudness(_ url: URL) throws -> Double {
    let log = try AudioEngine.run(["-i", url.path, "-map", "0:a:0", "-vn", "-af", "ebur128", "-f", "null", "-"], token: Cancellation())
    guard let block = log.range(of: "Integrated loudness:", options: .backwards),
          let i = log[block.upperBound...].range(of: #"I:\s+(-?[0-9.]+)"#, options: .regularExpression) else { return .nan }
    return Double(log[i].split(whereSeparator: { $0 == " " || $0 == ":" }).last.map(String.init) ?? "") ?? .nan
}
func sha(_ url: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() }

/// Compares the on-device analysis with FFmpeg's measurement of the same file.
func compare(_ name: String, _ url: URL, integrated: Double = 0.15, truePeak: Double = 0.3, range: Double = 1.2, momentary: Bool = true) async throws -> (Analysis, EvenOutData) {
    let token = Cancellation()
    let info = try AudioEngine.inspect(url, token: token)
    let reference = try AudioEngine.measure(url, token: token, duration: info.duration, keepChannels: true)
    let (mobile, data) = try await MobileEngine.analyze(url)
    let m = mobile.levels
    let ebur = try referenceLoudness(url)
    note("\(name): I \(f(m.integrated)) vs ebur128 \(f(ebur)) / loudnorm \(f(reference.integrated))   TP \(f(m.truePeak)) vs \(f(reference.truePeak))   LRA \(f(m.loudnessRange)) vs \(f(reference.loudnessRange))   peak \(f(m.samplePeak ?? 0)) vs \(f(reference.samplePeak ?? 0))")
    check(near(m.integrated, ebur, max(integrated, 0.06)), "\(name): integrated loudness matches FFmpeg's ebur128 (\(m.integrated) vs \(ebur))")
    check(near(m.integrated, reference.integrated, 0.6), "\(name): integrated loudness close to loudnorm (\(m.integrated) vs \(reference.integrated))")
    check(near(m.truePeak, reference.truePeak, truePeak), "\(name): true peak matches FFmpeg")
    check(near(m.loudnessRange, reference.loudnessRange, range), "\(name): loudness range matches FFmpeg")
    // FFmpeg measures astats after its graph resamples for loudnorm (192 kHz), so its "sample peak" is close to the true peak.
    // The device reports the real sample peak: never above FFmpeg's, and within the gap to the true peak.
    if let a = m.samplePeak, let b = reference.samplePeak { check(a <= b + 0.05 && a >= b - 1.0, "\(name): sample peak consistent with FFmpeg (\(a) vs \(b))") }
    if let a = m.dcOffset, let b = reference.dcOffset { check(near(a, b, 0.0005), "\(name): DC offset matches FFmpeg") }
    check(near(mobile.info.duration, info.duration, 0.1), "\(name): duration matches FFmpeg")
    check(mobile.channelsMeasured == info.channels, "\(name): every channel measured (\(mobile.channelsMeasured ?? 0) of \(info.channels))")
    // Momentary loudness every 100 ms, as Even out reads it (FFmpeg's Even out reading is stereo, so only mono/stereo).
    guard momentary, info.channels <= 2 else { return (mobile, data) }
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
        check(speech.channelsMeasured == 1 && speech.stereo?.correlation == nil, "mono is measured as mono (no stereo phase reading)")
        check(speech.info.channels == 1 && speech.info.sampleRate == 44100 && !speech.info.isVideo, "speech file info")

        // A sting: decaying tones every 2 s, 44.1 kHz 16-bit (the simulator run read 0.4 LU apart after Even out).
        try ffmpeg(["-f", "lavfi", "-i", "aevalsrc='0.9*sin(2*PI*440*t)*exp(-1.5*mod(t,2))|0.9*sin(2*PI*554*t)*exp(-1.5*mod(t,2))':s=44100:d=12", "-c:a", "pcm_s16le", file("sting.wav").path])
        let (sting, stingData) = try await compare("sting, 44.1 kHz 16-bit", file("sting.wav"))
        do {
            var st = ProcessingSettings(); st.target = -18; st.peak = -1; st.format = .lossless
            let regions = MobileEngine.evenOutPlan(stingData, duration: sting.info.duration, tolerance: ClipGain.evenOutTolerance, keeping: [], skipMusic: false).regions
            st.clipGain = regions
            st.edit = CueEdit.trimmedToSound(sting.stereo!, duration: sting.info.duration, keeping: CueEdit())
            let out = try await MobileEngine.level(file("sting.wav"), analysis: sting, settings: st, directory: area.appendingPathComponent("Sting"))
            let outInfo = try AudioEngine.inspect(out.url, token: token)
            let ff = try AudioEngine.measure(out.url, token: token, duration: outInfo.duration)
            let ebur = try referenceLoudness(out.url)
            note("sting levelled with \(regions.count) Even out sections: device \(f(out.levels.integrated)) vs ebur128 \(f(ebur)) / loudnorm \(f(ff.integrated)) LUFS, TP \(f(out.levels.truePeak)) vs \(f(ff.truePeak)), duration \(f(outInfo.duration))")
            check(near(out.levels.integrated, ebur, 0.1), "levelled sting: the device's verification agrees with ebur128")
            check(near(ebur, -18, 0.1), "levelled sting reaches the target (ebur128)")
        }

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

        print("== Songs are recognised, soft intro and fade-out included (2.1)")
        // A mastered song: a soft 4 s intro 12 dB under the song, the song itself without pauses, and a 6 s fade-out.
        // Before 2.1 the intro and fade counted as pauses, the song was taken for speech and Even out lifted the intro.
        try ffmpeg(["-f", "lavfi", "-i", "anoisesrc=color=pink:sample_rate=48000:duration=60:seed=3", "-af",
                    "volume='if(lt(t,4),0.25,1)*if(gt(t,54),max(0,(60-t)/6),1)':eval=frame,volume=-6dB", "-ac", "2", "-c:a", "pcm_s24le", file("song.wav").path])
        let (song, songData) = try await MobileEngine.analyze(file("song.wav"))
        check(ClipGain.soundsLikeMusic(momentary: songData.momentary.map(Double.init)), "a song with a soft intro and a fade-out is recognised as music")
        let songPlan = MobileEngine.evenOutPlan(songData, duration: song.info.duration, tolerance: ClipGain.evenOutTolerance, keeping: [], skipMusic: true)
        check(songPlan.soundsLikeMusic && songPlan.regions.isEmpty, "Even out leaves the song alone (\(songPlan.regions.count) sections)")
        check(!ClipGain.soundsLikeMusic(momentary: speechData.momentary.map(Double.init)), "speech with pauses is still treated as speech")

        print("== Speed: a long, high-bitrate video")
        // 8 minutes of 1080p at a high bitrate with a stereo soundtrack: FFmpeg's analysis reads the file three times,
        // the built-in engine reads only the audio, once.
        try ffmpeg(["-f", "lavfi", "-i", "testsrc2=s=1920x1080:r=30:d=480", "-f", "lavfi", "-i", "anoisesrc=color=pink:sample_rate=48000:duration=480:seed=9",
                    "-af", "volume=-12dB", "-c:v", "mpeg4", "-q:v", "1", "-c:a", "aac", "-b:a", "256k", "-shortest", file("long.mov").path])
        let bytes = (try? FileManager.default.attributesOfItem(atPath: file("long.mov").path)[.size] as? NSNumber)?.int64Value ?? 0
        var start = Date()
        let ffLong = try AudioEngine.analyze(file("long.mov"), token: token) { _, _ in }
        let ffTime = Date().timeIntervalSince(start)
        start = Date()
        let (ourLong, _) = try await MobileEngine.analyze(file("long.mov"))
        let ourTime = Date().timeIntervalSince(start)
        note("8-min video (\(bytes / 1_000_000) MB): FFmpeg analysis \(String(format: "%.1f", ffTime)) s, built-in \(String(format: "%.1f", ourTime)) s; \(f(ourLong.levels.integrated)) vs \(f(ffLong.levels.integrated)) LUFS")
        check(ourTime < ffTime, "the built-in engine measures a long video faster than FFmpeg's three passes")

        print("== Lossless levelling on the device")
        var settings = ProcessingSettings(); settings.target = -18; settings.peak = -1; settings.format = .lossless
        let out = area.appendingPathComponent("Levelled")
        // Audio: one gain change, measured by FFmpeg.
        let levelled = try await MobileEngine.level(file("speech.wav"), analysis: speech, settings: settings, directory: out)
        let levelledInfo = try AudioEngine.inspect(levelled.url, token: token)
        let levelledFF = try AudioEngine.measure(levelled.url, token: token, duration: levelledInfo.duration, keepChannels: true)
        note("speech → \(levelled.url.lastPathComponent): \(f(levelledFF.integrated)) LUFS, \(f(levelledFF.truePeak)) dBTP (gain \(String(format: "%+.2f", levelled.gainApplied ?? 0)), shortfall \(String(format: "%.2f", levelled.shortfall ?? 0)))")
        check(levelled.url.lastPathComponent == "speech_LVL-18.wav", "output named with the target")
        check(near(try referenceLoudness(levelled.url), settings.target - (levelled.shortfall ?? 0), 0.1), "levelled audio reaches the target (ebur128)")
        check(levelledFF.truePeak <= settings.peak + 0.2, "levelled audio stays under the ceiling (FFmpeg)")
        check(levelledInfo.sampleRate == 44100 && levelledInfo.audioDescription.hasPrefix("pcm_s24le"), "WAV at the source rate, 24-bit")
        check(levelledInfo.channels == 1, "mono stays mono (\(levelledInfo.channels) channels)")
        check(near(levelledInfo.duration, speech.info.duration, 0.01), "no samples added or lost")
        check(near(levelled.levels.integrated, try referenceLoudness(levelled.url), 0.1), "the device's own verification agrees with ebur128")
        // A gain change only: the output divided by the gain is the input, sample for sample (within 24-bit rounding).
        let gain = pow(10, (levelled.gainApplied ?? 0) / 20)
        let source = try AVAudioFile(forReading: file("speech.wav")), result = try AVAudioFile(forReading: levelled.url)
        let a = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 44100)!, b = AVAudioPCMBuffer(pcmFormat: result.processingFormat, frameCapacity: 44100)!
        try source.read(into: a, frameCount: 44100); try result.read(into: b, frameCount: 44100)
        var worst: Float = 0
        for i in 0..<Int(a.frameLength) { worst = max(worst, abs(b.floatChannelData![0][i] / Float(gain) - a.floatChannelData![0][i])) }
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
        let editedFF = try AudioEngine.measure(editedOut.url, token: token, duration: editedInfo.duration, keepChannels: true)
        note("edited → \(f(editedInfo.duration)) s, \(f(editedFF.integrated)) LUFS, \(f(editedFF.truePeak)) dBTP")
        check(near(editedInfo.duration, 24.0, 0.01), "in and out points cut the audio file")
        check(near(editedFF.integrated, settings.target - (editedOut.shortfall ?? 0), 0.25), "edited cue is measured after the edits, then levelled")
        check(editedOut.warnings.contains { $0.contains("1 section") }, "hand-drawn sections are noted")

        // Video: picture copied bit for bit, levelled PCM first track, second track kept.
        let (show, _) = try await MobileEngine.analyze(file("show.mov"))
        check(show.info.isVideo && show.info.audioStreams == 2 && show.info.videoCodec == "mpeg4", "video info")
        let video = try await MobileEngine.level(file("show.mov"), analysis: show, settings: settings, directory: out)
        let videoInfo = try AudioEngine.inspect(video.url, token: token)
        let videoFF = try AudioEngine.measure(video.url, token: token, duration: videoInfo.duration, keepChannels: true)
        note("video → \(video.url.lastPathComponent): \(f(videoFF.integrated)) LUFS, \(f(videoFF.truePeak)) dBTP, \(videoInfo.audioStreams ?? 0) audio tracks, \(videoInfo.audioDescription)")
        check(video.url.pathExtension == "mov", "video saved as MOV")
        check(try videoDigest(video.url) == videoDigest(file("show.mov")), "picture copied bit for bit")
        check(videoInfo.audioStreams == 2, "second audio track kept")
        check(videoInfo.audioDescription.hasPrefix("pcm_"), "levelled track is uncompressed PCM")
        check(near(videoFF.integrated, settings.target - (video.shortfall ?? 0), 0.25), "video's audio reaches the target (FFmpeg)")
        check(near(videoInfo.duration, show.info.duration, 0.1), "video keeps its length")

        print("== Surround keeps its channels (2.1)")
        // 5.1 with a different tone and level on every channel (FFmpeg writes WAV's standard order: L R C LFE Ls Rs), so a
        // channel swapped, dropped or mixed shows up. The LFE is loud, as BS.1770 leaves it out of the loudness.
        let tones = ["0.30*sin(2*PI*300*t)", "0.25*sin(2*PI*500*t)", "0.20*sin(2*PI*700*t)", "0.60*sin(2*PI*60*t)", "0.10*sin(2*PI*1100*t)", "0.15*sin(2*PI*1300*t)"]
        let swell = "*(0.7+0.3*sin(2*PI*0.25*t))"
        try ffmpeg(["-f", "lavfi", "-i", "aevalsrc='" + tones.map { $0 + swell }.joined(separator: "|") + "':s=48000:d=12:c=5.1", "-c:a", "pcm_s24le", file("five.wav").path])
        try ffmpeg(["-i", file("five.wav").path, "-c:a", "aac", "-b:a", "384k", file("five.m4a").path])
        try ffmpeg(["-f", "lavfi", "-i", "testsrc2=s=640x360:r=25:d=12", "-i", file("five.wav").path, "-map", "0:v", "-map", "1:a",
                    "-c:v", "mpeg4", "-q:v", "5", "-c:a", "aac", "-b:a", "384k", "-shortest", file("five.mov").path])
        let (five, _) = try await compare("5.1 WAV", file("five.wav"), integrated: 0.1)
        _ = try await compare("5.1 AAC (M4A)", file("five.m4a"), integrated: 0.25, truePeak: 0.5)
        check(five.info.channels == 6 && five.foldedToStereo == nil, "5.1 measured as 5.1")
        // The loud LFE tone would add several LU if it were counted; matching ebur128 above shows it is left out.
        let fiveOut = try await MobileEngine.level(file("five.wav"), analysis: five, settings: settings, directory: out)
        let fiveInfo = try AudioEngine.inspect(fiveOut.url, token: token)
        note("5.1 → \(fiveOut.url.lastPathComponent): \(fiveInfo.audioDescription), device \(f(fiveOut.levels.integrated)) vs ebur128 \(f(try referenceLoudness(fiveOut.url))) LUFS")
        check(fiveInfo.channels == 6 && fiveInfo.audioDescription.contains("5.1"), "5.1 WAV stays 5.1 with its layout (\(fiveInfo.audioDescription))")
        check(near(try referenceLoudness(fiveOut.url), settings.target - (fiveOut.shortfall ?? 0), 0.1), "levelled 5.1 reaches the target (ebur128)")
        check(!fiveOut.warnings.contains { $0.contains("Folded") }, "no fold note when every channel is kept")
        // Every channel is the same channel of the source times the one gain, in the same place.
        do {
            let src = try AVAudioFile(forReading: file("five.wav")), res = try AVAudioFile(forReading: fiveOut.url)
            check(src.processingFormat.channelCount == 6 && res.processingFormat.channelCount == 6, "both files read as 6 channels")
            let a = AVAudioPCMBuffer(pcmFormat: src.processingFormat, frameCapacity: 48000)!, b = AVAudioPCMBuffer(pcmFormat: res.processingFormat, frameCapacity: 48000)!
            try src.read(into: a, frameCount: 48000); try res.read(into: b, frameCount: 48000)
            let g = Float(pow(10, (fiveOut.gainApplied ?? 0) / 20))
            var worst: Float = 0
            for c in 0..<6 { for i in 0..<Int(a.frameLength) { worst = max(worst, abs(b.floatChannelData![c][i] / g - a.floatChannelData![c][i])) } }
            note("5.1: largest sample difference per channel after removing the gain: \(worst)")
            check(worst < 2e-6, "5.1 levelling is one exact gain on every channel, none swapped")
        }
        // AAC 5.1 decodes in AAC's own channel order (C L R Ls Rs LFE); the WAV must still come out in WAV order.
        let (fiveAAC, _) = try await MobileEngine.analyze(file("five.m4a"))
        let fiveAACOut = try await MobileEngine.level(file("five.m4a"), analysis: fiveAAC, settings: settings, directory: out)
        do {
            let ref = try AVAudioFile(forReading: file("five.wav")), res = try AVAudioFile(forReading: fiveAACOut.url)
            let a = AVAudioPCMBuffer(pcmFormat: ref.processingFormat, frameCapacity: 48000 * 4)!, b = AVAudioPCMBuffer(pcmFormat: res.processingFormat, frameCapacity: 48000 * 4)!
            try ref.read(into: a, frameCount: 48000 * 4); try res.read(into: b, frameCount: 48000 * 4)
            func rms(_ buf: AVAudioPCMBuffer, _ c: Int) -> Double { let n = Int(buf.frameLength); var s = 0.0; for i in 0..<n { let v = Double(buf.floatChannelData![c][i]); s += v * v }; return 10 * log10(s / Double(max(1, n))) }
            let gain = fiveAACOut.gainApplied ?? 0
            let diffs = (0..<6).map { rms(b, $0) - gain - rms(a, $0) }
            note("5.1 AAC → WAV channel levels vs source: " + diffs.map { String(format: "%+.2f", $0) }.joined(separator: " ") + " dB")
            check(res.processingFormat.channelCount == 6 && diffs.allSatisfy { abs($0) < 0.5 }, "5.1 AAC comes out in WAV channel order, each channel at its own level")
        }
        // Video with a 5.1 soundtrack: the levelled MOV track stays 5.1.
        let (fiveMov, _) = try await MobileEngine.analyze(file("five.mov"))
        let fiveMovOut = try await MobileEngine.level(file("five.mov"), analysis: fiveMov, settings: settings, directory: out)
        let fiveMovInfo = try AudioEngine.inspect(fiveMovOut.url, token: token)
        note("5.1 video → \(fiveMovInfo.audioDescription), \(f(try referenceLoudness(fiveMovOut.url))) LUFS")
        check(fiveMovInfo.channels == 6 && fiveMovInfo.audioDescription.hasPrefix("pcm_"), "5.1 video keeps a 5.1 PCM track")
        check(near(try referenceLoudness(fiveMovOut.url), settings.target - (fiveMovOut.shortfall ?? 0), 0.25), "5.1 video reaches the target (ebur128)")
        check(try videoDigest(fiveMovOut.url) == videoDigest(file("five.mov")), "5.1 video: picture copied bit for bit")
        // Fold surround to stereo, when asked.
        var fold = settings; fold.foldToStereo = true
        let (fiveFolded, _) = try await MobileEngine.analyze(file("five.wav"), foldSurround: true)
        check(fiveFolded.foldedToStereo == true && fiveFolded.channelsMeasured == 2, "folded measurement is marked")
        let foldedOut = try await MobileEngine.level(file("five.wav"), analysis: fiveFolded, settings: fold, directory: out)
        let foldedInfo = try AudioEngine.inspect(foldedOut.url, token: token)
        check(foldedInfo.channels == 2 && foldedOut.warnings.contains { $0.contains("Folded") }, "Fold surround to stereo folds, and says so")

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
