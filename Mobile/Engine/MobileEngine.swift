import Foundation
import AVFoundation

// CueLevel's engine on iPhone and iPad. Same results and the same rules as the Mac's lossless mode:
// one exact gain change per cue (plus any clip gain sections), never past the peak ceiling, no compression,
// no limiting, no resampling, and the source's own channels (mono stays mono, 5.1 stays 5.1) unless the person turns on
// Fold surround to stereo. Audio becomes WAV at its own sample rate (24-bit, or 32-bit float for float sources);
// video becomes MOV with the picture, other audio tracks and timecode copied untouched.

/// Fine-grained readings Even out needs: momentary loudness every 100 ms and 200 peaks per second.
struct EvenOutData: Codable, Sendable {
    var momentary: [Float]
    var peaks: [Float]
}

/// Applies a cue's hand edits (repairs, clip gain sections, in/out fades) and the levelling gain, sample by sample.
final class CueProcessor {
    let rate: Double
    let gain: Float
    let regions: [GainRegion]
    let edit: CueEdit?
    let duration: Double
    private var frame = 0
    private var dcPrev: [(x: Float, y: Float)] = []
    private let dcA: Float
    private let edgeActive: Bool
    private let e: CueEdit

    init(rate: Double, gainDB: Double, settings: ProcessingSettings, duration: Double) {
        self.rate = rate
        gain = Float(pow(10, gainDB / 20))
        regions = ClipGain.active(settings.clipGain)
        edit = settings.edit
        self.duration = duration
        e = (settings.edit ?? CueEdit()).normalized(duration: duration)
        edgeActive = e.isTrimmed(duration: duration) || e.hasFades
        let rc = 1 / (2 * Double.pi * 5), dt = 1 / rate
        dcA = Float(rc / (rc + dt))
    }
    var changesShape: Bool { !regions.isEmpty || edgeActive || (edit?.hasRepairs ?? false) }

    /// Fade-shaped gain of the in/out points at time t (0 outside the kept part).
    func edgeGain(_ t: Double) -> Double {
        guard edgeActive else { return 1 }
        let start = e.inPoint, end = e.end(duration: duration)
        guard t >= start, t <= end else { return 0 }
        let fi = max(e.fadeIn, start > 0.0005 ? CueEdit.clickGuard : 0), fo = max(e.fadeOut, end < duration - 0.0005 ? CueEdit.clickGuard : 0)
        func shape(_ x: Double) -> Double {
            let x = max(0, min(1, x))
            switch e.fadeShape {
            case .linear: return x
            case .smooth: return sin(x * Double.pi / 2)
            case .sCurve: let c = 2 * x - 1; return 1 - cos(Double.pi / 4 * (c * c * c + 1))
            }
        }
        var g = 1.0
        if fi > 0, t < start + fi { g *= shape((t - start) / fi) }
        if fo > 0, t > end - fo { g *= shape((end - t) / fo) }
        return g
    }

    /// Processes one chunk in place (an array per channel); `frame` keeps counting from the first sample of the cue.
    /// The same gain goes on every channel. Polarity fixes act on the first (left) and second (right) channel.
    func process(_ channels: inout [[Float]]) {
        guard let n = channels.first?.count else { return }
        if let edit, edit.removeDC {
            if dcPrev.count != channels.count { dcPrev = Array(repeating: (0, 0), count: channels.count) }
            for c in channels.indices {
                var prev = dcPrev[c]
                for i in 0..<n { let y = dcA * (prev.y + channels[c][i] - prev.x); prev = (channels[c][i], y); channels[c][i] = y }
                dcPrev[c] = prev
            }
        }
        if let edit, edit.polarity != .none {
            var flip: [Int] = []
            if edit.polarity == .left || edit.polarity == .both { flip.append(0) }
            if (edit.polarity == .right || edit.polarity == .both), channels.count > 1 { flip.append(1) }
            for c in flip { for i in 0..<n { channels[c][i] = -channels[c][i] } }
        }
        if regions.isEmpty && !edgeActive {
            if gain != 1 { for c in channels.indices { for i in 0..<n { channels[c][i] *= gain } } }
        } else {
            var m = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = Double(frame + i) / rate
                m[i] = Float(ClipGain.multiplier(at: t, regions: regions) * edgeGain(t)) * gain
            }
            for c in channels.indices { for i in 0..<n { channels[c][i] *= m[i] } }
        }
        frame += n
    }
}

enum MobileEngine {
    // MARK: Analysis
    static func analyze(_ url: URL, foldSurround: Bool = false, isCancelled: @escaping () -> Bool = { false },
                        progress: @escaping (Double) -> Void = { _ in }) async throws -> (Analysis, EvenOutData) {
        let media = try await MediaReader.open(url, foldSurround: foldSurround)
        return try analyzeOpened(media, isCancelled: isCancelled, progress: progress)
    }
    /// One decoding pass gives everything: loudness, true peak, range, waveform, silence, phase, the loudness curve,
    /// and Even out's readings. Synchronous, so the Mac app can run it on its own worker thread.
    static func analyzeOpened(_ media: OpenedMedia, isCancelled: @escaping () -> Bool = { false },
                              progress: @escaping (Double) -> Void = { _ in }) throws -> (Analysis, EvenOutData) {
        let meter = LoudnessMeter(sampleRate: media.sampleRate, weights: media.map.weights)
        let wave = WaveformBuilder(duration: media.info.duration, sampleRate: media.sampleRate)
        let total = max(1, media.info.duration * media.sampleRate)
        var done = 0, lastReport = 0
        try MediaReader.decode(media, isCancelled: isCancelled) { chunk, _ in
            meter.add(chunk)
            wave.add(chunk)
            let frames = chunk[0].count
            done += frames
            if done - lastReport > Int(media.sampleRate) { lastReport = done; progress(min(1, Double(done) / total)) }
        }
        let levels = try meter.finish()
        let analysis = Analysis(info: media.info, levels: levels, waveform: wave.peaks, sampleCount: nil,
                                stereo: wave.stats, loudnessCurve: reducedCurve(meter.shortTerm), foldedToStereo: media.folded ? true : nil, channelsMeasured: media.channels)
        progress(1)
        return (analysis, EvenOutData(momentary: meter.momentary, peaks: wave.detail))
    }

    /// Even out for a cue (as AudioEngine.evenOutPlan on the Mac): skips cues that play continuously like music when asked.
    static func evenOutPlan(_ data: EvenOutData, duration: Double, tolerance: Double, keeping existing: [GainRegion], skipMusic: Bool) -> (regions: [GainRegion], soundsLikeMusic: Bool) {
        let curve = data.momentary.map(Double.init)
        if skipMusic, ClipGain.soundsLikeMusic(momentary: curve) { return ([], true) }
        return (ClipGain.evenOut(momentary: curve, duration: duration, tolerance: tolerance, avoiding: existing, peaks: data.peaks), false)
    }

    // MARK: Output names
    static func outputName(for input: URL, target: Double, ext: String) -> String {
        input.deletingPathExtension().lastPathComponent + "_LVL" + String(format: "%g", target.rounded()) + "." + ext
    }
    static func uniqueURL(_ url: URL) -> URL {
        var candidate = url, n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + " \(n)").appendingPathExtension(url.pathExtension)
            n += 1
        }
        return candidate
    }

    /// "Already good": an exact copy of the source, described like a levelled result with no change.
    static func unchangedCopy(_ input: URL, analysis: Analysis, settings: ProcessingSettings, directory: URL) throws -> ProcessedAudio {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = uniqueURL(directory.appendingPathComponent(outputName(for: input, target: settings.target, ext: input.pathExtension.lowercased())))
        try FileManager.default.copyItem(at: input, to: output)
        return ProcessedAudio(url: output, levels: analysis.levels, waveform: analysis.waveform, settings: settings, warnings: [], created: Date(),
                              finalGainMode: "unchanged", loudnessCurve: analysis.loudnessCurve, gainApplied: 0, shortfall: 0, limiting: 0)
    }

    // MARK: Lossless levelling
    static func level(_ input: URL, analysis: Analysis, settings: ProcessingSettings, directory: URL,
                      isCancelled: @escaping () -> Bool = { false }, progress: @escaping (Double, String) -> Void = { _, _ in }) async throws -> ProcessedAudio {
        guard (-30.0 ... -12.0).contains(settings.target), (-6.0 ... -1.0).contains(settings.peak) else { throw cueError("The loudness target or peak ceiling is outside its supported range.") }
        let media = try await MediaReader.open(input, foldSurround: settings.foldsSurround)
        let info = media.info
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let free = (try? FileManager.default.attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? Int64.max
        let estimate = Int64(info.duration * media.sampleRate * 4 * Double(media.channels)) + (info.isVideo ? info.byteCount : 0) + 50_000_000
        guard free > estimate else { throw cueError("Not enough free space. Free up about \(ByteCountFormatter.string(fromByteCount: estimate, countStyle: .file)) on this device.") }
        let total = max(1, info.duration * media.sampleRate)

        // Hand edits change the cue's loudness and peaks, so measure the edited signal before planning the gain.
        let probe = CueProcessor(rate: media.sampleRate, gainDB: 0, settings: settings, duration: info.duration)
        var sourceLevels = analysis.levels
        if probe.changesShape {
            progress(0, "Measuring your edits")
            let meter = LoudnessMeter(sampleRate: media.sampleRate, weights: media.map.weights)
            var done = 0
            try MediaReader.decode(media, isCancelled: isCancelled) { chunk, _ in
                var edited = chunk
                probe.process(&edited)
                meter.add(edited)
                done += chunk[0].count; progress(0.3 * Double(done) / total, "Measuring your edits")
            }
            sourceLevels = try meter.finish()
        }
        let plan = LosslessPlan(levels: sourceLevels, target: settings.target, ceiling: settings.peak, maxLimiting: 0)
        guard plan.gain.isFinite, abs(plan.gain) < 60 else { throw cueError("The soundtrack is silent or too quiet to level reliably.") }

        let processor = CueProcessor(rate: media.sampleRate, gainDB: plan.gain, settings: settings, duration: info.duration)
        let meter = LoudnessMeter(sampleRate: media.sampleRate, weights: media.map.weights)
        let wave = WaveformBuilder(duration: info.duration, sampleRate: media.sampleRate)
        let base = probe.changesShape ? 0.3 : 0.0
        let ext = info.isVideo ? "mov" : "wav"
        let output = uniqueURL(directory.appendingPathComponent(outputName(for: input, target: settings.target, ext: ext)))
        do {
            if info.isVideo {
                try await writeVideo(media, to: output, processor: processor, meter: meter, wave: wave, isCancelled: isCancelled) { f in
                    progress(base + (0.95 - base) * min(1, Double(f) / total), "Writing lossless copy")
                }
            } else {
                try writeAudio(media, to: output, processor: processor, meter: meter, wave: wave, settings: settings, isCancelled: isCancelled) { f in
                    progress(base + (0.95 - base) * min(1, Double(f) / total), "Writing lossless copy")
                }
            }
        } catch { try? FileManager.default.removeItem(at: output); throw error }
        let levels = try meter.finish()
        progress(1, "Ready to review")
        func f(_ v: Double) -> String { String(format: "%.1f", v).replacingOccurrences(of: "-", with: "−") }
        var warnings: [String] = []
        let edits = ClipGain.active(settings.clipGain).filter { $0.isAuto != true }.count
        if edits > 0 { warnings.append("Clip gain changed the volume of \(edits) section\(edits == 1 ? "" : "s") you drew before levelling. Listen through the fades.") }
        if plan.shortfall > 0.05 {
            warnings.append("Kept \(f(plan.shortfall)) dB below the \(f(settings.target)) LUFS target so the loudest peak stays under \(f(settings.peak)) dBTP without limiting. Output: \(f(levels.integrated)) LUFS.")
        }
        if abs(levels.integrated - (settings.target - plan.shortfall)) > 0.5 { warnings.append("Measured output is \(f(levels.integrated)) LUFS, which differs from the planned \(f(settings.target - plan.shortfall)) LUFS. Review before use.") }
        if levels.truePeak > settings.peak + 0.2 { warnings.append("Output true peak \(f(levels.truePeak)) dBTP is above the \(f(settings.peak)) dBTP ceiling. Review before use.") }
        if analysis.levels.truePeak >= 0 { warnings.append("Source reaches full scale. Existing distortion may remain.") }
        if media.folded { warnings.append("Folded \(media.sourceName) surround down to stereo, as set in Settings. Folding mixes the channels together, so it isn't lossless.") }
        if let n = info.audioStreams, n > 1 { warnings.append(info.isVideo ? (n == 2 ? "2 audio tracks: the first is levelled, the second is copied untouched." : "\(n) audio tracks: the first is levelled, the other \(n - 1) are copied untouched.") : "Only the first of \(n) audio tracks is kept: WAV holds one track.") }
        if info.isVideo && info.hasOtherStreams { warnings.append("Subtitle tracks were not copied.") }
        return ProcessedAudio(url: output, levels: levels, waveform: wave.peaks, settings: settings, warnings: warnings, created: Date(),
                              finalGainMode: "fixed", loudnessCurve: reducedCurve(meter.shortTerm), gainApplied: plan.gain, shortfall: plan.shortfall, limiting: 0)
    }

    // MARK: Audio files → WAV
    /// Writes the levelled audio with the source's channels. Surround is stored in WAV's standard channel order with a
    /// channel mask, so DAWs, QLab and media servers know which channel is which.
    static func writeAudio(_ media: OpenedMedia, to output: URL, processor: CueProcessor, meter: LoudnessMeter, wave: WaveformBuilder,
                           settings: ProcessingSettings, isCancelled: @escaping () -> Bool, progress: (Int) -> Void) throws {
        let rate = media.sampleRate, n = media.channels
        var fileSettings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: n,
                                           AVLinearPCMBitDepthKey: media.isFloat ? 32 : 24, AVLinearPCMIsFloatKey: media.isFloat,
                                           AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        let wav = media.map.wavOrder()
        let order = wav?.order ?? Array(0..<n)
        if n > 2 {
            if let wav { fileSettings[AVChannelLayoutKey] = wav.layout }
            else {
                var layout = AudioChannelLayout(); layout.mChannelLayoutTag = kAudioChannelLayoutTag_DiscreteInOrder | UInt32(n)
                fileSettings[AVChannelLayoutKey] = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
            }
        }
        let file = try AVAudioFile(forWriting: output, settings: fileSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard Int(format.channelCount) == n else { throw cueError("CueLevel couldn't create a \(media.map.name) output file.") }
        // In and out points cut the audio file (video keeps its length and is silenced instead).
        let e = (settings.edit ?? CueEdit()).normalized(duration: media.info.duration)
        let trimmed = e.isTrimmed(duration: media.info.duration)
        let first = trimmed ? Int((e.inPoint * rate).rounded()) : 0
        let last = trimmed ? Int((e.end(duration: media.info.duration) * rate).rounded()) : Int.max
        var position = 0
        try MediaReader.decode(media, isCancelled: isCancelled) { chunk, _ in
            var data = chunk
            processor.process(&data)
            let frames = data[0].count
            let lo = max(0, first - position), hi = min(frames, last - position)
            position += frames
            progress(position)
            guard hi > lo else { return }
            var kept = (lo == 0 && hi == frames) ? data : data.map { Array($0[lo..<hi]) }
            if !media.isFloat { clampForInteger(&kept) }
            meter.add(kept)
            wave.add(kept)
            let count = hi - lo
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
            buffer.frameLength = AVAudioFrameCount(count)
            for k in 0..<n { kept[order[k]].withUnsafeBufferPointer { p in buffer.floatChannelData![k].update(from: p.baseAddress!, count: count) } }
            try file.write(from: buffer)
        }
    }
    /// 24-bit files can't hold values at or over full scale.
    private static func clampForInteger(_ channels: inout [[Float]]) {
        let maxValue: Float = 8_388_607.0 / 8_388_608.0
        for c in channels.indices { for i in channels[c].indices { channels[c][i] = max(-1, min(maxValue, channels[c][i])) } }
    }
    /// The channel layout written into MOV files: the source's own (MOV stores any layout), or mono/stereo.
    static func movLayout(_ media: OpenedMedia) -> Data {
        var layout = AudioChannelLayout()
        switch media.channels {
        case 1: layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
        case 2: layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        default: return media.sourceLayout ?? media.map.descriptionLayout()
        }
        return Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
    }

    // MARK: Video → MOV (picture and other tracks copied)
    final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

    static func writeVideo(_ media: OpenedMedia, to output: URL, processor: CueProcessor, meter: LoudnessMeter, wave: WaveformBuilder,
                           isCancelled: @escaping () -> Bool, progress: @escaping (Int) -> Void) async throws {
        let asset = media.asset
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        writer.metadata = (try? await asset.load(.metadata)) ?? []
        var pairs: [(AVAssetReaderOutput, AVAssetWriterInput, Bool)] = []   // (output, input, isLevelledAudio)

        for track in try await asset.loadTracks(withMediaType: .video) {
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil); out.alwaysCopiesSampleData = false
            let hint = try await track.load(.formatDescriptions).first
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
            input.transform = try await track.load(.preferredTransform)
            input.expectsMediaDataInRealTime = false
            if reader.canAdd(out), writer.canAdd(input) { reader.add(out); writer.add(input); pairs.append((out, input, false)) }
        }
        // The levelled first audio track: uncompressed PCM at the source rate.
        let decoded = AVAssetReaderTrackOutput(track: media.audioTrack, outputSettings: MediaReader.decodeSettings(media))
        decoded.alwaysCopiesSampleData = false
        let layout = movLayout(media)
        let audioSettings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: media.sampleRate, AVNumberOfChannelsKey: media.channels,
                                            AVLinearPCMBitDepthKey: media.isFloat ? 32 : 24, AVLinearPCMIsFloatKey: media.isFloat,
                                            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
                                            AVChannelLayoutKey: layout]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = false
        guard reader.canAdd(decoded), writer.canAdd(audioInput) else { throw cueError("CueLevel can't write this video's audio.") }
        reader.add(decoded); writer.add(audioInput); pairs.append((decoded, audioInput, true))
        // Any further audio tracks and timecode are copied as they are.
        for track in try await asset.loadTracks(withMediaType: .audio).dropFirst() {
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil); out.alwaysCopiesSampleData = false
            let hint = try await track.load(.formatDescriptions).first
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
            if reader.canAdd(out), writer.canAdd(input) { reader.add(out); writer.add(input); pairs.append((out, input, false)) }
        }
        for track in (try? await asset.loadTracks(withMediaType: .timecode)) ?? [] {
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            let hint = try await track.load(.formatDescriptions).first
            let input = AVAssetWriterInput(mediaType: .timecode, outputSettings: nil, sourceFormatHint: hint)
            if reader.canAdd(out), writer.canAdd(input) {
                reader.add(out); writer.add(input); pairs.append((out, input, false))
                if let video = pairs.first(where: { $0.1.mediaType == .video })?.1, video.canAddTrackAssociation(withTrackOf: input, type: AVAssetTrack.AssociationType.timecode.rawValue) {
                    video.addTrackAssociation(withTrackOf: input, type: AVAssetTrack.AssociationType.timecode.rawValue)
                }
            }
        }
        guard writer.startWriting() else { throw writer.error ?? cueError("CueLevel couldn't start writing the video.") }
        guard reader.startReading() else { writer.cancelWriting(); throw reader.error ?? cueError("CueLevel can't read this video.") }
        writer.startSession(atSourceTime: .zero)

        let failure = Box<Error?>(nil)
        let frames = Box(0)
        await withTaskGroup(of: Void.self) { group in
            for (index, pair) in pairs.enumerated() {
                group.addTask {
                    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                        let queue = DispatchQueue(label: "cuelevel.writer.\(index)")
                        let finished = Box(false)
                        pair.1.requestMediaDataWhenReady(on: queue) {
                            guard !finished.value else { return }
                            while pair.1.isReadyForMoreMediaData {
                                if isCancelled() || failure.value != nil { finished.value = true; pair.1.markAsFinished(); done.resume(); return }
                                guard let buffer = pair.0.copyNextSampleBuffer() else { finished.value = true; pair.1.markAsFinished(); done.resume(); return }
                                var toAppend = buffer
                                if pair.2 {
                                    guard var data = MediaReader.planar(from: buffer), let count = data.first?.count, count > 0 else { continue }
                                    guard data.count == media.channels else { failure.value = cueError("CueLevel couldn't keep this video's \(media.map.name) channels apart."); continue }
                                    processor.process(&data)
                                    if !media.isFloat { clampForInteger(&data) }
                                    meter.add(data)
                                    wave.add(data)
                                    frames.value += count; progress(frames.value)
                                    guard let made = makeBuffer(data, rate: media.sampleRate, layout: layout, time: CMSampleBufferGetPresentationTimeStamp(buffer)) else {
                                        failure.value = cueError("CueLevel couldn't write the levelled audio."); continue
                                    }
                                    toAppend = made
                                }
                                if !pair.1.append(toAppend) { failure.value = writer.error ?? cueError("The video could not be written."); }
                            }
                        }
                    }
                }
            }
        }
        if isCancelled() { reader.cancelReading(); writer.cancelWriting(); throw CancellationError() }
        if let error = failure.value { reader.cancelReading(); writer.cancelWriting(); throw error }
        if reader.status == .failed { writer.cancelWriting(); throw cueError("The video could not be read completely. The file may be damaged.") }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? cueError("The video could not be written.") }
    }

    /// An interleaved float sample buffer of `channels` with the given layout.
    static func makeBuffer(_ channels: [[Float]], rate: Double, layout: Data, time: CMTime) -> CMSampleBuffer? {
        let n = channels.count, frames = channels.first?.count ?? 0
        guard n > 0, frames > 0 else { return nil }
        let bytesPerFrame = UInt32(4 * n)
        var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame, mChannelsPerFrame: UInt32(n), mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        let made = layout.withUnsafeBytes { raw in
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: raw.count, layout: raw.baseAddress!.assumingMemoryBound(to: AudioChannelLayout.self),
                                           magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        }
        guard made == noErr, let format else { return nil }
        var interleaved = [Float](repeating: 0, count: frames * n)
        for c in 0..<n { channels[c].withUnsafeBufferPointer { src in for i in 0..<frames { interleaved[i * n + c] = src[i] } } }
        let bytes = frames * n * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = interleaved.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames,
                                                                   presentationTimeStamp: time, packetDescriptions: nil, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
}
