import Foundation

final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    func check() throws { lock.lock(); let c = cancelled; lock.unlock(); if c { throw CancellationError() } }
    func launch(_ p: Process) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try p.run(); process = p
    }
    func clear(_ p: Process) { lock.lock(); if process === p { process = nil }; lock.unlock() }
    func cancel() {
        lock.lock(); cancelled = true; let p = process; lock.unlock()
        if let p, p.isRunning {
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        }
    }
}
/// Consumes 48 kHz stereo float frames: waveform peaks plus whole-file correlation and leading/trailing silence.
final class WaveCollector: @unchecked Sendable {
    static let audible: Float = 0.001   // -60 dBFS
    var peaks: [Float]
    let binCount: Int
    var carry = Data()
    /// Frames consumed (one per 48 kHz sample period).
    var sampleIndex = 0
    let samplesPerBin: Double
    var sumL2 = 0.0, sumR2 = 0.0, sumLR = 0.0
    var firstAudible: Int?
    var lastAudible: Int?
    init(duration: Double, bins: Int = 1000) {
        binCount = max(1, bins); peaks = [Float](repeating: 0, count: max(1, bins))
        samplesPerBin = max(1, duration * 48000 / Double(max(1, bins)))
    }
    func consume(_ chunk: Data) {
        carry.append(chunk)
        let count = carry.count / 8
        carry.withUnsafeBytes { bytes in
            for i in 0..<count {
                let l = bytes.loadUnaligned(fromByteOffset: i * 8, as: Float.self)
                let r = bytes.loadUnaligned(fromByteOffset: i * 8 + 4, as: Float.self)
                if l.isFinite && r.isFinite {
                    let v = max(abs(l), abs(r))
                    let bin = min(binCount - 1, Int(Double(sampleIndex) / samplesPerBin))
                    peaks[bin] = max(peaks[bin], v)
                    sumL2 += Double(l * l); sumR2 += Double(r * r); sumLR += Double(l * r)
                    if v > Self.audible { if firstAudible == nil { firstAudible = sampleIndex }; lastAudible = sampleIndex }
                }
                sampleIndex += 1
            }
        }
        carry.removeFirst(count * 8)
    }
    var stats: StereoStats {
        let denominator = (sumL2 * sumR2).squareRoot()
        let head = Double(firstAudible ?? sampleIndex) / 48000
        let tail = Double(lastAudible.map { sampleIndex - 1 - $0 } ?? 0) / 48000
        return StereoStats(correlation: denominator > 0 ? sumLR / denominator : nil, headSilence: head, tailSilence: tail)
    }
}
/// Collects short-term loudness values printed by ebur128/ametadata on stdout.
final class CurveCollector: @unchecked Sendable {
    var pending = ""
    var values: [Float] = []
    let key: String
    init(key: String = "lavfi.r128.S") { self.key = key + "=" }
    func consume(_ chunk: Data) {
        pending += String(decoding: chunk, as: UTF8.self)
        while let newline = pending.firstIndex(of: "\n") {
            let line = pending[..<newline]
            if line.hasPrefix(key), let value = Float(line.dropFirst(key.count)), value.isFinite { values.append(max(-70, min(0, value))) }
            pending.removeSubrange(...newline)
        }
    }
    /// At most maxPoints values, keeping the loudest reading in each span so short loud moments stay visible.
    func reduced(maxPoints: Int = 600) -> [Float] {
        guard values.count > maxPoints else { return values }
        let step = Double(values.count) / Double(maxPoints)
        return (0..<maxPoints).map { i in
            let start = Int(Double(i) * step), end = max(start + 1, min(values.count, Int(Double(i + 1) * step)))
            return values[start..<end].max() ?? -70
        }
    }
}
enum AudioEngine {
    static var binary: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["CUELEVEL_FFMPEG"] ?? Bundle.main.resourceURL!.appendingPathComponent("ffmpeg").path) }
    @discardableResult static func run(_ arguments: [String], token: Cancellation, duration: Double = 0,
                                      progress: @escaping @Sendable (Double) -> Void = { _ in },
                                      output: (@Sendable (Data) -> Void)? = nil) throws -> String {
        try token.check()
        let process = Process(); process.executableURL = binary
        process.currentDirectoryURL = binary.deletingLastPathComponent()
        process.arguments = ["-hide_banner", "-nostdin", "-nostats", "-progress", "pipe:2"] + arguments
        let errorPipe = Pipe(); process.standardError = errorPipe
        let outputPipe = output == nil ? nil : Pipe()
        process.standardOutput = outputPipe ?? FileHandle.nullDevice as Any
        try token.launch(process)
        let group = DispatchGroup()
        if let outputPipe, let output {
            group.enter(); DispatchQueue.global(qos: .utility).async {
                while true { let data = outputPipe.fileHandleForReading.availableData; if data.isEmpty { break }; output(data) }
                group.leave()
            }
        }
        var tail = Data(); var lines = ""
        while true {
            let data = errorPipe.fileHandleForReading.availableData
            if data.isEmpty { break }
            tail.append(data); if tail.count > 262144 { tail.removeFirst(tail.count - 262144) }
            lines += String(decoding: data, as: UTF8.self)
            while let split = lines.firstIndex(of: "\n") {
                let line = String(lines[..<split]); lines.removeSubrange(...split)
                if line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)), duration > 0 { progress(min(1, max(0, us / 1_000_000 / duration))) }
            }
            if lines.count > 32768 { lines = String(lines.suffix(32768)) }
        }
        process.waitUntilExit(); group.wait(); token.clear(process); try token.check()
        let text = String(decoding: tail, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let useful = text.split(separator: "\n").filter { !$0.hasPrefix("out_") && !$0.hasPrefix("progress=") }.suffix(12).joined(separator: "\n")
            throw cueError("The media engine could not complete this step.\n\n\(useful)")
        }
        return text
    }
    static func inspect(_ input: URL, token: Cancellation) throws -> MediaInfo {
        guard FileManager.default.isReadableFile(atPath: input.path) else { throw cueError("Source file unavailable. Reconnect the drive or add the file again.") }
        if let bytes = (try? FileManager.default.attributesOfItem(atPath: input.path)[.size] as? NSNumber)?.int64Value, bytes == 0 {
            throw cueError("This file is empty (0 bytes). It may not have finished copying.")
        }
        let log: String
        do { log = try run(["-i", input.path, "-map", "0:a:0", "-t", "0", "-f", "null", "-"], token: token) }
        catch is CancellationError { throw CancellationError() }
        catch {
            // 2.0.1: plain-language reasons instead of the engine's log.
            let text = error.localizedDescription
            if text.contains("matches no streams") { throw cueError("This file has no audio track, so there's nothing to level.") }
            if ["Invalid data found", "could not find codec", "moov atom not found", "End of file", "Invalid argument", "unspecified size"].contains(where: text.contains) {
                throw cueError("CueLevel can't read this file. It may be damaged, incomplete, or not audio or video.")
            }
            throw error
        }
        let source = String(log.components(separatedBy: "Stream mapping:").first ?? log)
        let streams = source.components(separatedBy: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Stream #0:") }
        let audio = streams.filter { $0.contains("Audio:") }
        guard !audio.isEmpty else { throw cueError("This file has no audio track to level.") }
        let channels = channelCount(audio[0])
        guard channels > 0 else { throw cueError("The audio channel layout cannot be read. Export a mono, stereo or standard surround mix first.") }
        let rate = audio[0].range(of: #"(\d+) Hz"#, options: .regularExpression).flatMap { Int(audio[0][$0].dropLast(3)) }
        let pattern = try NSRegularExpression(pattern: "Duration: ([0-9]+):([0-9]+):([0-9.]+)")
        guard let m = pattern.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) else { throw cueError("The duration cannot be read. Use a complete, seekable audio or video file.") }
        let ns = source as NSString
        let hours = Double(ns.substring(with: m.range(at: 1))) ?? 0
        let minutes = Double(ns.substring(with: m.range(at: 2))) ?? 0
        let seconds = Double(ns.substring(with: m.range(at: 3))) ?? 0
        let duration = hours * 3600 + minutes * 60 + seconds
        guard duration > 0 else { throw cueError("The file has no playable duration.") }
        let size = (try? FileManager.default.attributesOfItem(atPath: input.path)[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (try? FileManager.default.attributesOfItem(atPath: input.path)[.modificationDate] as? Date) ?? .distantPast
        let pictures = streams.filter { $0.contains("Video:") && !$0.contains("attached pic") }
        let videoCodec = pictures.first.flatMap { $0.components(separatedBy: "Video: ").last?.split(whereSeparator: { $0 == " " || $0 == "," }).first.map(String.init) }
        return MediaInfo(duration: duration, isVideo: !pictures.isEmpty, audioDescription: audio[0].components(separatedBy: "Audio:").last?.trimmingCharacters(in: .whitespaces) ?? "Audio", channels: channels, byteCount: size, modified: modified, hasOtherStreams: streams.contains { $0.contains("Subtitle:") || $0.contains("Data:") || $0.contains("Attachment:") }, videoCodec: videoCodec, audioStreams: audio.count, sampleRate: rate)
    }
    /// FFmpeg's channel layout name from a stream description ("pcm_s24le, 48000 Hz, 5.1(side), s32" → "5.1(side)").
    static func layoutName(_ description: String) -> String? {
        let parts = description.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3, let i = parts.firstIndex(where: { $0.hasSuffix(" Hz") }), parts.indices.contains(i + 1) else { return nil }
        let name = parts[i + 1]
        return name.contains("channels") || name.isEmpty ? nil : name
    }
    /// Channel count from an FFmpeg stream line: mono, stereo, standard surround layouts, or "N channels".
    static func channelCount(_ line: String) -> Int {
        let layouts: [(String, Int)] = [("mono", 1), ("stereo", 2), ("2.1", 3), ("3.0", 3), ("quad", 4), ("4.0", 4), ("4.1", 5), ("5.0", 5), ("5.1", 6), ("6.0", 6), ("6.1", 7), ("7.0", 7), ("7.1", 8), ("hexagonal", 6), ("octagonal", 8)]
        for (name, count) in layouts where line.contains(", \(name),") || line.contains(", \(name)(") { return count }
        if let range = line.range(of: #"(\d+) channels"#, options: .regularExpression), let n = Int(line[range].split(separator: " ")[0]) { return n }
        return 0
    }
    /// Loudness and peaks. `keepChannels` (2.1) measures the file's own channels as BS.1770 defines (surround weighted,
    /// LFE left out); otherwise the audio is measured as stereo, as processed output is.
    static func measure(_ input: URL, token: Cancellation, duration: Double, filters: String = "anull", normalizer: String = "loudnorm=I=-23", keepChannels: Bool = false, progress: @escaping @Sendable (Double) -> Void = { _ in }) throws -> Measurement {
        let layout = keepChannels ? [] : ["-ac", "2"]
        let chain = (keepChannels ? "" : "aformat=channel_layouts=stereo,") + "\(filters),\(Measurement.statsFilter),\(normalizer):print_format=json"
        let log = try run(["-i", input.path, "-map", "0:a:0", "-vn"] + layout + ["-af", chain, "-f", "null", "-"], token: token, duration: duration, progress: progress)
        return try Measurement.parse(log)
    }
    static func waveform(_ input: URL, duration: Double, token: Cancellation) throws -> [Float] {
        try waveformData(input, duration: duration, token: token).peaks
    }
    /// Fine waveform for zooming in the clip gain editor: 200 peaks per second (5 ms), at most 720 000 points.
    static func detailWaveform(_ input: URL, duration: Double, token: Cancellation) throws -> [Float] {
        try waveformData(input, duration: duration, token: token, bins: Int(min(720_000, max(1000, duration * 200)))).peaks
    }
    static func waveformData(_ input: URL, duration: Double, token: Cancellation, bins: Int = 1000) throws -> WaveCollector {
        let collector = WaveCollector(duration: duration, bins: bins)
        try run(["-i",input.path,"-map","0:a:0","-vn","-ac","2","-ar","48000","-f","f32le","pipe:1"], token: token, output: { collector.consume($0) })
        return collector
    }
    /// Short-term (3 s) loudness across the file, for the loudness-over-time graph.
    static func loudnessCurve(_ input: URL, duration: Double, token: Cancellation, progress: @escaping @Sendable (Double) -> Void = { _ in }) throws -> [Float] {
        let collector = CurveCollector()
        try run(["-i", input.path, "-map", "0:a:0", "-vn", "-af", "aformat=channel_layouts=stereo,ebur128=metadata=1:framelog=verbose,ametadata=mode=print:key=lavfi.r128.S:file=-", "-f", "null", "-"], token: token, duration: duration, progress: progress, output: { collector.consume($0) })
        return collector.reduced()
    }
    /// Momentary (400 ms) loudness every 100 ms across the whole file, for Even out.
    static func momentaryLoudness(_ input: URL, duration: Double, token: Cancellation) throws -> [Float] {
        let collector = CurveCollector(key: "lavfi.r128.M")
        try run(["-i", input.path, "-map", "0:a:0", "-vn", "-af", "aformat=channel_layouts=stereo,ebur128=metadata=1,ametadata=mode=print:key=lavfi.r128.M:file=-", "-f", "null", "-"], token: token, duration: duration, output: { collector.consume($0) })
        return collector.values
    }
    /// Even out: clip gain sections that bring clearly loud or quiet stretches back to the cue's typical level.
    static func evenOutRegions(_ input: URL, info: MediaInfo, tolerance: Double = ClipGain.evenOutTolerance, keeping existing: [GainRegion], token: Cancellation) throws -> [GainRegion] {
        try evenOutPlan(input, info: info, tolerance: tolerance, keeping: existing, skipMusic: false, token: token).regions
    }
    /// Even out for Quick Level (2.0.1): skips cues that play continuously like music, since a song's dynamics are intentional.
    static func evenOutPlan(_ input: URL, info: MediaInfo, tolerance: Double = ClipGain.evenOutTolerance, keeping existing: [GainRegion], skipMusic: Bool,
                            token: Cancellation) throws -> (regions: [GainRegion], soundsLikeMusic: Bool) {
        let curve = try momentaryLoudness(input, duration: info.duration, token: token).map(Double.init)
        if skipMusic, ClipGain.soundsLikeMusic(momentary: curve) { return ([], true) }
        let peaks = try detailWaveform(input, duration: info.duration, token: token)
        return (ClipGain.evenOut(momentary: curve, duration: info.duration, tolerance: tolerance, avoiding: existing, peaks: peaks), false)
    }
    /// Short-term (3 s) loudness every 100 ms across the whole file (not thinned), for reference shapes.
    static func shortTermLoudness(_ input: URL, duration: Double, token: Cancellation) throws -> [Float] {
        let collector = CurveCollector(key: "lavfi.r128.S")
        try run(["-i", input.path, "-map", "0:a:0", "-vn", "-af", "aformat=channel_layouts=stereo,ebur128=metadata=1,ametadata=mode=print:key=lavfi.r128.S:file=-", "-f", "null", "-"], token: token, duration: duration, output: { collector.consume($0) })
        return collector.values
    }
    static func loudnessProfile(_ input: URL, duration: Double, token: Cancellation) throws -> LoudnessProfile? {
        LoudnessProfile(shortTerm: try shortTermLoudness(input, duration: duration, token: token).map(Double.init))
    }
    static func gapRegions(_ input: URL, info: MediaInfo, depth: Double, token: Cancellation) throws -> [GainRegion] {
        let curve = try momentaryLoudness(input, duration: info.duration, token: token)
        return ClipGain.gapRegions(momentary: curve.map(Double.init), duration: info.duration, depth: depth)
    }
    static func analyze(_ input: URL, foldSurround: Bool = false, token: Cancellation, progress: @escaping @Sendable (Double, String) -> Void) throws -> Analysis {
        progress(0, "Inspecting file")
        let info = try inspect(input, token: token)
        progress(0.02, "Measuring loudness")
        let fold = foldSurround && info.channels > 2
        let levels = try measure(input, token: token, duration: info.duration, keepChannels: !fold) { progress(0.02 + $0 * 0.6, "Measuring loudness") }
        progress(0.62, "Building waveform")
        let wave = try waveformData(input, duration: info.duration, token: token)
        progress(0.78, "Tracing loudness over time")
        let curve = try loudnessCurve(input, duration: info.duration, token: token) { progress(0.78 + $0 * 0.22, "Tracing loudness over time") }
        progress(1, "Analysis complete")
        return Analysis(info: info, levels: levels, waveform: wave.peaks, sampleCount: wave.sampleIndex, stereo: wave.stats, loudnessCurve: curve,
                        foldedToStereo: fold ? true : nil, channelsMeasured: fold ? 2 : info.channels)
    }
    static func process(_ input: URL, analysis: Analysis, settings: ProcessingSettings, directory: URL, token: Cancellation,
                        progress: @escaping @Sendable (Double, String) -> Void) throws -> ProcessedAudio {
        if settings.format == .lossless { return try processLossless(input, analysis: analysis, settings: settings, directory: directory, token: token, progress: progress) }
        try settings.validate(); try token.check()
        if settings.denoise && settings.cleanupOptions.method == .speech {
            guard FileManager.default.isReadableFile(atPath: binary.deletingLastPathComponent().appendingPathComponent("speech.rnnn").path) else {
                throw cueError("The speech denoising model is missing. Reinstall CueLevel to restore it.")
            }
        }
        let video = analysis.info.isVideo && (settings.format == .automatic || settings.format == .videoAndWav)
        let ext: String
        switch settings.format {
        case .wav: ext = "wav"
        case .flac: ext = "flac"
        case .m4a: ext = "m4a"
        case .automatic, .videoAndWav, .lossless: ext = video ? (["mov","mp4","mkv"].contains(input.pathExtension.lowercased()) ? input.pathExtension.lowercased() : "mkv") : "wav"
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let free = (try? FileManager.default.attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? Int64.max
        let estimate = Int64(analysis.info.duration * 48000 * (settings.format == .videoAndWav ? 12 : 6)) + (video ? analysis.info.byteCount : 0) + 200_000_000
        guard free > estimate else { throw cueError("Not enough free space for processing. Free up approximately \(ByteCountFormatter.string(fromByteCount: estimate, countStyle: .file)) on the Mac's internal drive.") }
        let output = directory.appendingPathComponent(input.deletingPathExtension().lastPathComponent + "_CueLevel." + ext)
        let companion = video && settings.format == .videoAndWav ? directory.appendingPathComponent(input.deletingPathExtension().lastPathComponent + "_CueLevel_Audio.wav") : nil
        let sampleCount: Int?
        if settings.denoise && settings.cleanupOptions.method == .speech {
            sampleCount = try analysis.sampleCount ?? waveformData(input, duration: analysis.info.duration, token: token).sampleIndex
        } else { sampleCount = analysis.sampleCount }
        let edits = settings.editFilters(duration: analysis.info.duration, sampleRate: analysis.info.sampleRate ?? 48000, canCut: !video)
        let processingFilters = [edits, settings.filterChain(sampleCount: sampleCount, inputLoudness: analysis.levels.integrated)].compactMap { $0 }.joined(separator: ",")
        let measuring = try measure(input, token: token, duration: analysis.info.duration, filters: processingFilters, normalizer: settings.normalizer) { progress($0 * 0.3, "Analysing processing") }
        // loudnorm treats measured_LRA=0 as "not supplied" and silently falls back to dynamic mode. Steady material
        // longer than 3 s (tones, very constant loops) can measure exactly 0 LU, so pass a negligible positive value.
        let measuredRange = max(measuring.loudnessRange, 0.01)
        let norm = "\(settings.normalizer):measured_I=\(measuring.integrated):measured_TP=\(measuring.truePeak):measured_LRA=\(measuredRange):measured_thresh=\(measuring.threshold):offset=\(measuring.offset):linear=true:print_format=json"
        var args = ["-i",input.path,"-map","0:a:0"]
        if video { args += ["-map","0:v?","-c:v","copy","-map","0:s?","-c:s","copy"] }
        args += ["-map_metadata","0","-map_chapters","0","-af","aformat=channel_layouts=stereo,\(processingFilters),\(norm)","-ac","2","-ar","48000"]
        if video || settings.format == .m4a { args += ["-c:a","aac","-b:a","320k"] }
        else if settings.format == .flac { args += ["-c:a","flac","-sample_fmt","s32"] }
        else { args += ["-c:a","pcm_s24le"] }
        args += ["-n",output.path]
        do {
            let renderLog = try run(args, token: token, duration: analysis.info.duration) { progress(0.3 + $0 * 0.4, "Rendering output") }
            let gainMode = Measurement.normalizationType(in: renderLog)
            let levels = try measure(output, token: token, duration: analysis.info.duration) { progress(0.7 + $0 * (companion == nil ? 0.25 : 0.12), "Verifying output") }
            var audioLevels: Measurement?
            var companionMode: String?
            if let companion {
                let companionLog = try run(["-i",input.path,"-map","0:a:0","-vn","-af","aformat=channel_layouts=stereo,\(processingFilters),\(norm)","-c:a","pcm_s24le","-ar","48000","-ac","2","-n",companion.path],token: token,duration: analysis.info.duration) { progress(0.82 + $0 * 0.06,"Creating WAV copy") }
                companionMode = Measurement.normalizationType(in: companionLog)
                audioLevels = try measure(companion, token: token, duration: analysis.info.duration) { progress(0.88 + $0 * 0.07,"Verifying WAV copy") }
            }
            progress(0.96, "Building output waveform")
            let wave = try waveform(output, duration: analysis.info.duration, token: token)
            var warnings: [String] = []
            if gainMode == "dynamic" || companionMode == "dynamic" {
                warnings.append("The final loudness stage could not reach the target with one fixed gain change, so it applied dynamic loudness control. This can reduce natural dynamics. Check Reference check for the cause; lowering the target or reducing peaks keeps it fixed.")
            }
            if let audioLevels, abs(audioLevels.integrated - settings.target) > 1 || audioLevels.truePeak > settings.peak + 0.2 {
                warnings.append("The WAV copy is outside the requested loudness or peak tolerance. Review its measurements before export.")
            }
            if abs(levels.integrated - settings.target) > 1 { warnings.append("Measured loudness is more than 1 LU from the target. Review before export.") }
            if levels.truePeak > settings.peak + 0.2 { warnings.append("Encoded output exceeds the requested peak ceiling. Lower the ceiling and process again.") }
            if settings.levelerOptions.enabled { warnings.append("Automatic leveling changes gain within the cue. Review fades, pauses and intentional dynamics; the quiet threshold is level-based, not speech detection.") }
            if settings.enhancementOptions.repairClipping { warnings.append("Clipping repair estimates damaged peaks; it cannot recover the original recording. Compare for new artifacts.") }
            if settings.enhancementOptions.voiceEQ { warnings.append("Dynamic voice EQ applies limited, time-varying cuts in three bands. It does not identify speakers or learn a target voice.") }
            if settings.enhancementOptions.brightness { warnings.append("Brightness boosts existing high frequencies, including hiss. It does not reconstruct missing bandwidth.") }
            if analysis.levels.truePeak >= 0 { warnings.append("Source reaches full scale. Existing distortion may remain.") }
            if analysis.info.channels == 1 { warnings.append("Mono source exported as dual-mono stereo.") }
            if analysis.info.channels > 2 { warnings.append("Surround source downmixed to stereo.") }
            if let n = analysis.info.audioStreams, n > 1 { warnings.append("Only the first of \(n) audio tracks is kept in this mode. Use Lossless · gain only to keep the others untouched.") }
            if video && analysis.info.hasOtherStreams { warnings.append("Subtitle streams were copied. Data streams and attachments are not retained.") }
            if settings.denoise {
                warnings.append(settings.cleanupOptions.method == .speech ? "Speech denoising can reduce music, effects and unvoiced speech. Compare the original before export." : "Steady-noise reduction can alter quiet music and ambience. Compare the original before export.")
            }
            if settings.cleanupOptions.hum != .off { warnings.append("Hum notches also reduce wanted content at the selected frequency and its first four harmonics.") }
            progress(0.98, "Tracing loudness over time")
            let curve = try loudnessCurve(output, duration: analysis.info.duration, token: token)
            progress(1, "Ready to review")
            return ProcessedAudio(url: output, levels: levels, waveform: wave, settings: settings, warnings: warnings, created: Date(), audioCompanion: companion, companionLevels: audioLevels, finalGainMode: gainMode, companionGainMode: companionMode, loudnessCurve: curve)
        } catch { try? FileManager.default.removeItem(at: output); if let companion { try? FileManager.default.removeItem(at: companion) }; throw error }
    }
    /// "Already good" (1.8): an exact, bit-for-bit copy of the source, described like a levelled result with no change.
    static func unchangedCopy(_ input: URL, analysis: Analysis, settings: ProcessingSettings, directory: URL) throws -> ProcessedAudio {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent(input.deletingPathExtension().lastPathComponent + "_CueLevel." + input.pathExtension)
        try FileManager.default.copyItem(at: input, to: output)
        return ProcessedAudio(url: output, levels: analysis.levels, waveform: analysis.waveform, settings: settings, warnings: [], created: Date(),
                              finalGainMode: "unchanged", loudnessCurve: analysis.loudnessCurve, gainApplied: 0, shortfall: 0, limiting: 0)
    }
    /// QuickTime-family sources become MOV (MP4 cannot carry uncompressed audio); others become MKV so every stream can be copied.
    static func losslessExtension(for input: URL, isVideo: Bool) -> String {
        guard isVideo else { return "wav" }
        return ["mov", "mp4", "m4v", "qt"].contains(input.pathExtension.lowercased()) ? "mov" : "mkv"
    }
    /// Lossless levelling: the picture, subtitles, chapters, metadata and timecode are copied untouched; the audio receives one
    /// exact gain change (no resampling, no loudness filter, no compression) and is stored uncompressed at its original sample rate.
    /// If the target would push the true peak over the ceiling, the cue stays quieter instead of being limited.
    static func processLossless(_ input: URL, analysis: Analysis, settings: ProcessingSettings, directory: URL, token: Cancellation,
                                progress: @escaping @Sendable (Double, String) -> Void) throws -> ProcessedAudio {
        try token.check()
        guard (-30.0 ... -12.0).contains(settings.target), (-6.0 ... -1.0).contains(settings.peak) else { throw cueError("The loudness target or peak ceiling is outside its supported range.") }
        let info = analysis.info
        let ext = losslessExtension(for: input, isVideo: info.isVideo)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let free = (try? FileManager.default.attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? Int64.max
        let estimate = Int64(info.duration * 96000 * 8) + (info.isVideo ? info.byteCount : 0) + 200_000_000
        guard free > estimate else { throw cueError("Not enough free space for processing. Free up approximately \(ByteCountFormatter.string(fromByteCount: estimate, countStyle: .file)) on the Mac's internal drive.") }
        // 2.1: the source's channels are kept (mono stays mono, 5.1 stays 5.1) unless Fold surround to stereo is on.
        let fold = settings.foldsSurround && info.channels > 2
        let layoutFilter = fold ? "aformat=channel_layouts=stereo," : ""
        // Clip gain changes the cue's loudness and peaks, so measure the edited signal before planning the gain.
        let clipFilter = settings.editFilters(duration: info.duration, sampleRate: info.sampleRate ?? 48000, canCut: !info.isVideo, channels: fold ? 2 : info.channels,
                                               layout: fold ? "stereo" : Self.layoutName(info.audioDescription))
        // 2.0.1: clip gain is rendered once to a float intermediate, which is then measured and levelled. The per-sample
        // gain expression is the slow part, and it used to run twice (measure, then render).
        var clipped: URL? = nil
        let sourceLevels: Measurement
        if let filter = clipFilter {
            let temp = directory.appendingPathComponent("clip-gain-\(UUID().uuidString).wav")
            try run(["-i", input.path, "-map", "0:a:0", "-vn", "-af", "\(layoutFilter)\(filter)", "-c:a", "pcm_f32le", "-rf64", "auto", "-n", temp.path],
                    token: token, duration: info.duration) { progress($0 * 0.15, "Applying clip gain") }
            clipped = temp
            sourceLevels = try measure(temp, token: token, duration: info.duration, keepChannels: true) { progress(0.15 + $0 * 0.05, "Measuring clip gain edits") }
        } else { sourceLevels = analysis.levels }
        defer { if let clipped { try? FileManager.default.removeItem(at: clipped) } }
        let plan = settings.manualGain.map { LosslessPlan(fixedGain: $0) } ?? LosslessPlan(levels: sourceLevels, target: settings.target, ceiling: settings.peak, maxLimiting: settings.peakLimit ?? 0)
        guard plan.gain.isFinite, abs(plan.gain) < 60 else { throw cueError("The soundtrack is silent or too quiet to level reliably.") }
        let output = directory.appendingPathComponent(input.deletingPathExtension().lastPathComponent + "_CueLevel." + ext)
        let sampleFormat = info.audioDescription.hasPrefix("pcm_f") ? "pcm_f32le" : "pcm_s24le"
        var chain = (clipped == nil ? layoutFilter : "") + "volume=" + String(format: "%.4f", plan.gain) + "dB:precision=double"
        if plan.limiting > 0.05 {
            // Only when the user allowed limiting: 4x oversampled look-ahead limiter (approximates true peak), then back to the source rate.
            let limit = pow(10, (settings.peak - 0.3) / 20)
            chain += ",aresample=192000,alimiter=limit=" + String(format: "%.6f", limit) + ":attack=1:release=50:level=0:latency=1,aresample=\(info.sampleRate ?? 48000)"
        }
        let extraTracks = info.isVideo && (info.audioStreams ?? 1) > 1
        var args = ["-i", input.path] + (clipped.map { ["-i", $0.path] } ?? []) + ["-filter_complex", "[\(clipped == nil ? 0 : 1):a:0]\(chain)[levelled]"]
        if info.isVideo { args += ["-map", "0:v?"] }   // video first, as in typical source files
        args += ["-map", "[levelled]"]
        if extraTracks { args += ["-map", "0:a?", "-map", "-0:a:0"] }
        if info.isVideo { args += ["-map", "0:s?"] }
        if info.isVideo {
            args += ["-c:v", "copy", "-c:s", "copy"]
            if ext == "mov", info.videoCodec == "hevc" { args += ["-tag:v", "hvc1"] }
        }
        if extraTracks { args += ["-c:a", "copy"] }
        args += ["-c:a:0", sampleFormat, "-map_metadata", "0", "-map_chapters", "0", "-n", output.path]
        do {
            let base = clipFilter == nil ? 0.0 : 0.2
            try run(args, token: token, duration: info.duration) { progress(base + $0 * (0.6 - base), "Writing lossless copy") }
            let levels = try measure(output, token: token, duration: info.duration, keepChannels: true) { progress(0.6 + $0 * 0.3, "Verifying output") }
            progress(0.92, "Building output waveform")
            let wave = try waveform(output, duration: info.duration, token: token)
            func f(_ v: Double) -> String { String(format: "%.1f", v) }
            var warnings: [String] = []
            // Even out's own sections are listed in the result; only hand-drawn sections are a note to listen to.
            let edits = ClipGain.active(settings.clipGain).filter { $0.isAuto != true }.count
            if edits > 0 { warnings.append("Clip gain changed the volume of \(edits) section\(edits == 1 ? "" : "s") you drew before levelling. Listen through the fades.") }
            if plan.shortfall > 0.05 {
                warnings.append("Kept \(f(plan.shortfall)) dB below the \(f(settings.target)) LUFS target so the loudest peak stays under \(f(settings.peak)) dBTP without limiting. Output: \(f(levels.integrated)) LUFS.")
            }
            if plan.limiting > 0.05 {
                warnings.append("Peak limiter reduced the loudest peaks by up to \(f(plan.limiting)) dB to reach the target. Those peaks are altered; everything else is a clean gain change.")
            }
            if abs(levels.integrated - (settings.target - plan.shortfall)) > (plan.limiting > 0.05 ? 1.0 : 0.5) { warnings.append("Measured output is \(f(levels.integrated)) LUFS, which differs from the planned \(f(settings.target - plan.shortfall)) LUFS. Review before use.") }
            if levels.truePeak > settings.peak + 0.2 { warnings.append("Output true peak \(f(levels.truePeak)) dBTP is above the \(f(settings.peak)) dBTP ceiling. Review before use.") }
            if analysis.levels.truePeak >= 0 { warnings.append("Source reaches full scale. Existing distortion may remain.") }
            if clipFilter != nil, sourceLevels.truePeak > 0 { warnings.append("Clip gain pushed peaks over full scale (\(f(sourceLevels.truePeak)) dBTP) before levelling. The levelling gain brings them back down; lower the boosted sections if the output still sounds harsh.") }
            if fold { warnings.append("Folded \(info.channels)-channel surround down to stereo, as set in Settings. Folding mixes the channels together, so it isn't lossless.") }
            if let n = info.audioStreams, n > 1 { warnings.append(info.isVideo ? (n == 2 ? "2 audio tracks: the first is levelled, the second is copied untouched." : "\(n) audio tracks: the first is levelled, the other \(n - 1) are copied untouched.") : "Only the first of \(n) audio tracks is kept: WAV holds one track.") }
            if ext == "mkv" { warnings.append("Saved as MKV so every stream could be copied untouched. Resolume may not open MKV; supply MOV or MP4 sources for playback files.") }
            progress(0.96, "Tracing loudness over time")
            let curve = try loudnessCurve(output, duration: info.duration, token: token)
            progress(1, "Ready to review")
            return ProcessedAudio(url: output, levels: levels, waveform: wave, settings: settings, warnings: warnings, created: Date(), finalGainMode: plan.limiting > 0.05 ? "limited" : "fixed", loudnessCurve: curve, gainApplied: plan.gain, shortfall: plan.shortfall, limiting: plan.limiting)
        } catch { try? FileManager.default.removeItem(at: output); throw error }
    }
}

extension AudioEngine {
    /// Integrated loudness of one section, after the given clip-gain regions (sections shorter than 0.4 s cannot be gated).
    static func sectionLoudness(_ input: URL, info: MediaInfo, start: Double, end: Double, regions: [GainRegion], token: Cancellation) throws -> Double {
        guard end - start >= 0.4 else { throw cueError("Select at least half a second to measure a section.") }
        var filters: [String] = []
        if let clip = ClipGain.filter(regions) { filters.append(clip) }
        filters.append(ClipGain.trim(start: start, end: end, sampleRate: info.sampleRate ?? 48000))
        return try measure(input, token: token, duration: end - start, filters: filters.joined(separator: ","), keepChannels: true).integrated
    }
}
