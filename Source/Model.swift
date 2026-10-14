import Foundation

// Shared by the Mac app and CueLevel for iPhone and iPad: settings, measurements and analysis results.
func cueError(_ message: String) -> NSError { NSError(domain: "CueLevel", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
enum ContentMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case music = "Audio only", mixed = "Audio + voice", voice = "Voice"
    var id: String { rawValue }
    var symbol: String { self == .music ? "music.note" : self == .voice ? "mic" : "waveform" }
    var detail: String {
        switch self {
        case .music: return "Preserve musical dynamics and transients."
        case .mixed: return "Gentle control for finished speech-and-music mixes."
        case .voice: return "Steadier speech with low-frequency rumble filtering."
        }
    }
}
enum OutputFormat: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic = "Match source type", lossless = "Lossless · gain only", videoAndWav = "Video + WAV copy", wav = "WAV · 24-bit", flac = "FLAC · lossless", m4a = "M4A · AAC"
    var id: String { rawValue }
}
/// Gain for lossless levelling: one exact volume change, never more than the peak ceiling allows.
struct LosslessPlan: Equatable, Sendable {
    /// dB applied to the whole cue.
    var gain: Double
    /// dB by which the cue stays below the target because a larger gain would exceed the ceiling (0 when it reaches the target).
    var shortfall: Double
    /// dB of peak limiting needed (0 unless the optional limiter is allowed and used).
    var limiting: Double
    init(levels: Measurement, target: Double, ceiling: Double, maxLimiting: Double = 0) {
        let wanted = target - levels.integrated
        let allowed = ceiling - levels.truePeak
        gain = min(wanted, allowed + max(0, maxLimiting))
        limiting = max(0, gain - allowed)
        shortfall = max(0, wanted - gain)
    }
}
enum NoiseMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case steady = "Steady background", speech = "Speech denoiser"
    var id: String { rawValue }
}
enum HumMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off = "Off", hz50 = "50 Hz", hz60 = "60 Hz"
    var id: String { rawValue }
    var frequency: Double { self == .hz50 ? 50 : 60 }
}
struct CleanupSettings: Codable, Equatable, Sendable {
    var method = NoiseMethod.steady
    var speechStrength = 75.0
    var noiseFloor = -50.0
    var trackNoise = true
    var hum = HumMode.off
    var humReduction = 6.0
}
struct EnhancementSettings: Codable, Equatable, Sendable {
    var voiceEQ = false
    var eqLimit = 2.0
    var plosives = false
    var plosiveLimit = 4.0
    var plosiveThreshold = -24.0
    var repairClipping = false
    var brightness = false
    var brightnessGain = 1.5
}
enum LevelerStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case gentle = "Gentle", balanced = "Balanced", strong = "Strong"
    var id: String { rawValue }
}
struct LevelerSettings: Codable, Equatable, Sendable {
    var enabled = true
    var style = LevelerStyle.balanced
    var maximumLift = 6.0
    var response = 3.0
    var noiseThreshold = -45.0
    mutating func apply(_ style: LevelerStyle) {
        self.style = style
        maximumLift = style == .gentle ? 3 : style == .balanced ? 6 : 9
        response = style == .gentle ? 6 : style == .balanced ? 3 : 2
    }
}
struct ProcessingSettings: Codable, Equatable, Sendable {
    var leveler: LevelerSettings? = LevelerSettings()
    var levelerOptions: LevelerSettings {
        get { if let leveler { return leveler }; var old = LevelerSettings(); old.enabled = false; return old }
        set { leveler = newValue }
    }
    var enhancement: EnhancementSettings? = nil
    var enhancementOptions: EnhancementSettings { get { enhancement ?? EnhancementSettings() } set { enhancement = newValue } }
    var mode = ContentMode.mixed
    var target = -23.0
    var peak = -2.0
    var range = 10.0
    var compression = true
    var ratio = 1.7
    var highpass = false
    var cutoff = 70.0
    var deess = false
    var deessAmount = 0.25
    var cleanup: CleanupSettings? = nil
    var cleanupOptions: CleanupSettings { get { cleanup ?? CleanupSettings() } set { cleanup = newValue } }
    var denoise = false
    var noiseReduction = 6.0
    var soften = false
    var frequency = 3500.0
    var cut = 2.0
    var format = OutputFormat.automatic
    /// Loudness (LUFS) at which level-dependent stages run. nil keeps the 0.6 behaviour, where thresholds act on the source's absolute level.
    var workingLevel: Double? = nil
    /// Lossless mode only: maximum dB of transparent true-peak limiting allowed to reach the target. nil = never limit (cue stays quieter).
    var peakLimit: Double? = nil
    /// Per-cue clip gain (1.2), applied before everything else. Set from the cue when it is processed; nil for batch settings.
    var clipGain: [GainRegion]? = nil
    /// Per-cue in/out points, edge fades and markers (1.5). Set from the cue when it is processed.
    var edit: CueEdit? = nil
    mutating func setMode(_ newMode: ContentMode) {
        mode = newMode
        var leveling = LevelerSettings(); leveling.apply(newMode == .music ? .gentle : newMode == .voice ? .strong : .balanced); leveling.enabled = newMode != .music; levelerOptions = leveling
        enhancementOptions = EnhancementSettings()
        var options = cleanupOptions; options.method = .steady; cleanupOptions = options
        range = newMode == .music ? 14 : newMode == .mixed ? 10 : 7
        ratio = newMode == .music ? 1.3 : newMode == .mixed ? 1.7 : 2.0
        highpass = newMode == .voice
        deess = false; denoise = false; soften = false
    }
    func validate() throws {
        let l = levelerOptions
        let e = enhancementOptions
        if mode != .voice && (e.voiceEQ || e.plosives) { throw cueError("Dynamic voice EQ and plosive reduction require Voice mode to protect musical content.") }
        let c = cleanupOptions
        if denoise && c.method == .speech && mode != .voice { throw cueError("Speech denoising is for Voice cues only. Choose steady background reduction to retain music and effects.") }
        for (value, bounds) in [(l.maximumLift, 0.0 ... 12.0),(l.response, 1.0 ... 10.0),(l.noiseThreshold, -70.0 ... -25.0),(e.eqLimit, 2.0 ... 3.0),(e.plosiveLimit, 2.0 ... 6.0),(e.plosiveThreshold, -40.0 ... -12.0),(e.brightnessGain, 0.0 ... 3.0),(c.speechStrength, 0.0 ... 100.0),(c.noiseFloor, -80.0 ... -20.0),(c.humReduction, 1.0 ... 18.0),(target, -30.0 ... -12.0),(peak, -6.0 ... -1.0),(range, 5.0 ... 20.0),(ratio, 1.0 ... 4.0),(cutoff, 30.0 ... 150.0),(deessAmount, 0.0 ... 0.6),(noiseReduction, 1.0 ... 12.0),(frequency, 2000.0 ... 6000.0),(cut, 2.0 ... 3.0)] {
            guard value.isFinite, bounds.contains(value) else { throw cueError("A processing setting is outside its supported range. Restore a preset and try again.") }
        }
        if let workingLevel, !(workingLevel.isFinite && (-30.0 ... -12.0).contains(workingLevel)) { throw cueError("A processing setting is outside its supported range. Restore a preset and try again.") }
        if let peakLimit, !(peakLimit.isFinite && (1.0 ... 6.0).contains(peakLimit)) { throw cueError("A processing setting is outside its supported range. Restore a preset and try again.") }
    }
    var filters: String { filterChain(sampleCount: nil) }
    /// True when any enabled stage responds to absolute signal level (thresholds, gain caps, noise floors).
    var usesLevelDependentStages: Bool {
        let e = enhancementOptions
        return levelerOptions.enabled || compression || deess || soften || denoise || e.voiceEQ || e.plosives
    }
    /// Static gain that places the cue at the working level before level-dependent stages. The final loudness pass removes it again.
    func workingGain(inputLoudness: Double?) -> Double? {
        guard let workingLevel, let inputLoudness, inputLoudness.isFinite, usesLevelDependentStages else { return nil }
        return min(30, max(-30, workingLevel - inputLoudness))
    }
    func filterChain(sampleCount: Int?, inputLoudness: Double? = nil) -> String {
        var list: [String] = []
        if enhancementOptions.repairClipping { list.append("adeclip=w=20:o=50:a=2:t=10:m=save") }
        if let gain = workingGain(inputLoudness: inputLoudness) { list.append("volume=" + String(format: "%.2f", gain) + "dB") }
        list += cleanupFilters(sampleCount: sampleCount)
        if highpass { list.append("highpass=f=\(cutoff)") }
        list += enhancementFilters()
        if deess { list.append("deesser=i=\(deessAmount):m=0.4:f=0.5") }
        if soften { list.append("adynamicequalizer=threshold=0.1:dfrequency=\(frequency):tfrequency=\(frequency):dqfactor=1:tqfactor=1:attack=15:release=200:ratio=1:range=\(cut / 2):mode=cutabove") }
        if let leveling = levelerFilter { list.append(leveling) }
        if compression { list.append("acompressor=threshold=0.25:ratio=\(ratio):attack=10:release=250:knee=4:makeup=1:link=maximum:detection=peak") }
        return list.isEmpty ? "anull" : list.joined(separator: ",")
    }
    var levelerFilter: String? {
        let l = levelerOptions
        guard l.enabled else { return nil }
        let gain = pow(10, l.maximumLift / 20)
        let threshold = pow(10, l.noiseThreshold / 20)
        let window = max(3, Int((l.response / 0.25).rounded()) | 1)
        return "dynaudnorm=f=250:g=\(window):p=0.85:m=\(gain):r=0.125:n=1:c=0:b=0:s=0:t=\(threshold):o=0"
    }
    func enhancementFilters() -> [String] {
        let e = enhancementOptions
        var list: [String] = []
        if e.plosives {
            let threshold = pow(10, e.plosiveThreshold / 20)
            list.append("adynamicequalizer=threshold=\(threshold):dfrequency=110:dqfactor=0.7:tfrequency=140:tqfactor=0.7:dftype=lowpass:tftype=lowshelf:attack=2:release=120:ratio=2:range=\(e.plosiveLimit / 2):mode=cutabove")
        }
        if e.voiceEQ {
            for frequency in [280, 800, 3200] {
                list.append("adynamicequalizer=threshold=0.05:dfrequency=\(frequency):tfrequency=\(frequency):dqfactor=0.8:tqfactor=0.8:attack=30:release=350:ratio=0.5:range=\(e.eqLimit / 2):mode=cutabove:auto=off")
            }
        }
        if e.brightness && e.brightnessGain > 0 { list.append("treble=g=\(e.brightnessGain):f=6000:t=q:w=0.7") }
        return list
    }
    func cleanupFilters(sampleCount: Int? = nil) -> [String] {
        let c = cleanupOptions
        var filters: [String] = []
        if c.hum != .off {
            for harmonic in 1...4 {
                filters.append("equalizer=f=\(c.hum.frequency * Double(harmonic)):t=q:w=30:g=-\(c.humReduction)")
            }
        }
        if denoise {
            if c.method == .speech && c.speechStrength > 0 {
                filters.append("aresample=48000")
                filters.append("apad=pad_len=480")
                filters.append("arnndn=m=speech.rnnn:mix=\(c.speechStrength / 100)")
                if let sampleCount { filters.append("atrim=start_sample=480:end_sample=\(sampleCount + 480),asetpts=PTS-480/SR/TB") }
                else { filters.append("atrim=start_sample=480,asetpts=PTS-480/SR/TB") }
            } else if c.method == .steady {
                filters.append("afftdn=nr=\(noiseReduction):nf=\(c.noiseFloor):tn=\(c.trackNoise ? 1 : 0):nl=min:gs=5")
            }
        }
        return filters
    }
    var normalizer: String { "loudnorm=I=\(target):TP=\(peak):LRA=\(range)" }
}
struct Measurement: Codable, Sendable {
    var integrated: Double
    var truePeak: Double
    var loudnessRange: Double
    var threshold: Double
    var offset: Double
    /// Highest sample (dBFS) and average RMS (dBFS) of the measured stereo signal. Absent in sessions from 0.6 and earlier.
    var samplePeak: Double? = nil
    var rms: Double? = nil
    /// Samples at the peak level, and mean DC offset (linear), from astats. Absent before 1.0.
    var peakCount: Double? = nil
    var dcOffset: Double? = nil
    /// Peak-to-average ratio in dB, measured the same way as the reference library's crest factor.
    var crestFactor: Double? {
        guard let samplePeak, let rms, samplePeak.isFinite, rms.isFinite else { return nil }
        return samplePeak - rms
    }
    static let statsFilter = "astats=measure_perchannel=none:measure_overall=Peak_level+RMS_level+Peak_count+DC_offset"
    /// Reads a value from the final astats "Overall" block; nil when absent or not finite (silence reports -inf).
    static func overallStat(_ name: String, in text: String) -> Double? {
        guard let block = text.range(of: "] Overall", options: .backwards) else { return nil }
        for line in text[block.upperBound...].split(separator: "\n") {
            guard let label = line.range(of: name + ": ") else { continue }
            guard let value = Double(line[label.upperBound...].trimmingCharacters(in: .whitespaces)), value.isFinite else { return nil }
            return value
        }
        return nil
    }
    /// "linear" when loudnorm applied one fixed gain change, "dynamic" when it fell back to time-varying loudness control.
    static func normalizationType(in text: String) -> String? {
        guard let key = text.range(of: "\"normalization_type\" : \"", options: .backwards) else { return nil }
        let rest = text[key.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }
    static func parse(_ text: String) throws -> Measurement {
        guard let start = text.range(of: "{", options: .backwards), let end = text.range(of: "}", options: .backwards), start.lowerBound < end.upperBound,
              let data = String(text[start.lowerBound..<end.upperBound]).data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: String] else { throw cueError("The audio could not be measured. Check that the file has an audible soundtrack.") }
        func number(_ key: String) throws -> Double {
            guard let s = dict[key], let n = Double(s), n.isFinite else { throw cueError("The soundtrack is silent or too quiet to measure reliably.") }; return n
        }
        var result = try Measurement(integrated: number("input_i"), truePeak: number("input_tp"), loudnessRange: number("input_lra"), threshold: number("input_thresh"), offset: number("target_offset"))
        result.samplePeak = overallStat("Peak level dB", in: text)
        result.rms = overallStat("RMS level dB", in: text)
        result.peakCount = overallStat("Peak count", in: text)
        result.dcOffset = overallStat("DC offset", in: text)
        return result
    }
}
struct MediaInfo: Codable, Sendable {
    var duration: Double
    var isVideo: Bool
    var audioDescription: String
    var channels: Int
    var byteCount: Int64
    var modified: Date
    var hasOtherStreams: Bool
    /// First video stream's codec name (e.g. "h264", "hevc", "prores"); nil for audio files and pre-0.7 sessions.
    var videoCodec: String? = nil
    /// Number of audio streams (the first is levelled) and the first stream's sample rate.
    var audioStreams: Int? = nil
    var sampleRate: Int? = nil
}
/// Whole-file stereo statistics from the waveform pass (48 kHz decode).
struct StereoStats: Codable, Sendable {
    var correlation: Double?
    var headSilence: Double
    var tailSilence: Double
}
struct Analysis: Codable, Sendable {
    var info: MediaInfo; var levels: Measurement; var waveform: [Float]; var sampleCount: Int? = nil
    var stereo: StereoStats? = nil
    /// Short-term loudness (LUFS) across the cue, evenly spaced, at most 600 points.
    var loudnessCurve: [Float]? = nil
    /// Plain-language source checks: clipping, DC offset, phase, silence, surround and extra tracks.
    var sourceFindings: [String] {
        var notes: [String] = []
        func f(_ v: Double) -> String { String(format: "%.1f", v) }
        let clipLevel = info.channels == 1 ? -3.11 : -0.1   // mono is measured after CueLevel's -3 dB dual-mono conversion
        if let peak = levels.samplePeak, peak >= clipLevel, let count = levels.peakCount, count >= 4 {
            notes.append("Probable clipping: \(Int(count)) samples sit at full scale. Levelling cannot remove existing distortion.")
        }
        if let dc = levels.dcOffset, abs(dc) >= 0.001 { notes.append("DC offset of \(String(format: "%.2f", dc * 100))% of full scale. It wastes headroom and can cause clicks at cue starts.") }
        if info.channels >= 2, let c = stereo?.correlation {
            if c < -0.1 { notes.append("Left and right are largely out of phase (correlation \(String(format: "%.2f", c))). Content can cancel on a mono-summed system.") }
            else if c > 0.999 && info.channels == 2 { notes.append("The stereo channels are identical: this is effectively a mono file.") }
        }
        if let s = stereo, s.headSilence >= 2 { notes.append("\(f(s.headSilence)) s of silence at the start. Check the cue's trigger timing.") }
        if let s = stereo, s.tailSilence >= 2 { notes.append("\(f(s.tailSilence)) s of silence at the end.") }
        if info.channels > 2 { notes.append("Surround source (\(info.channels) channels) is downmixed to stereo. Downmixing is not lossless.") }
        if let n = info.audioStreams, n > 1 { notes.append("\(n) audio tracks. The first is levelled; Lossless mode copies the others untouched, other modes drop them.") }
        return notes
    }
}
struct ProcessedAudio: Codable, Sendable {
    var url: URL
    var levels: Measurement
    var waveform: [Float]
    var settings: ProcessingSettings
    var warnings: [String]
    var created: Date
    var audioCompanion: URL? = nil
    var companionLevels: Measurement? = nil
    /// How the final loudness stage behaved: "linear" (fixed gain) or "dynamic". nil for results from 0.6 and earlier.
    var finalGainMode: String? = nil
    var companionGainMode: String? = nil
    var loudnessCurve: [Float]? = nil
    /// Lossless mode: applied gain, dB left below target, and dB of peak limiting.
    var gainApplied: Double? = nil
    var shortfall: Double? = nil
    var limiting: Double? = nil
}
