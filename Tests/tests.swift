import Foundation
import CryptoKit

// CueLevel tests (engine, references, lossless path, catalogue, updates). Run with Scripts/run-tests.sh.
func check(_ condition: Bool, _ message: String) { if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) } }
func near(_ a: Double, _ b: Double, _ tolerance: Double = 0.001) -> Bool { abs(a - b) <= tolerance }
final class Bytes: @unchecked Sendable { var data = Data() }
/// MD5 of the first video stream's compressed packets, via the bundled FFmpeg (identical value = picture untouched).
func videoDigest(_ url: URL) throws -> String {
    let box = Bytes()
    try AudioEngine.run(["-i", url.path, "-map", "0:v:0", "-c", "copy", "-f", "md5", "pipe:1"], token: Cancellation(), output: { box.data.append($0) })
    return String(decoding: box.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
func sha(_ url: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() }
func cue(_ lufs: Double, tp: Double, lra: Double, crest: Double?) -> Measurement {
    var m = Measurement(integrated: lufs, truePeak: tp, loudnessRange: lra, threshold: lufs - 10, offset: 0)
    if let crest { m.samplePeak = tp; m.rms = tp - crest }
    return m
}

@main struct Tests {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let libraryFolder = root.appendingPathComponent("outputs/CueLevel/Reference Library")
        let area = root.appendingPathComponent("work/v07-tests/session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: area, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: area) }

        // 1. Library loads with confirmed labels and keeps categories separate.
        let libraryHash = try sha(libraryFolder.appendingPathComponent("library.json"))
        let annotationsHash = try sha(libraryFolder.appendingPathComponent("annotations.json"))
        let library = try ReferenceLibrary.load(from: libraryFolder)
        check(library.records.count == 6, "six references")
        check(library.references(for: .music).count == 2 && library.references(for: .voice).count == 4 && library.references(for: .mixed).isEmpty, "2 music, 4 voice, 0 mixed")
        let voice = library.span(for: .voice)!, music = library.span(for: .music)!
        check(near(voice.loudness.lowerBound, -30.27) && near(voice.loudness.upperBound, -21.77), "voice loudness spread kept, not averaged")
        check(near(voice.loudnessRange.lowerBound, 6.1) && near(voice.loudnessRange.upperBound, 7.0), "voice LRA spread")
        check(near(voice.crest!.lowerBound, 20.646) && near(voice.crest!.upperBound, 23.951), "voice crest spread")
        check(near(music.loudnessRange.lowerBound, 2.9) && near(music.loudnessRange.upperBound, 4.0), "music LRA spread")
        check(library.span(for: .mixed) == nil, "no Audio + voice span")
        print("PASS: library loads 6 confirmed references as separate category ranges")

        // 2. Annotations (keyed by SHA-256) override library categories.
        let edited = area.appendingPathComponent("edited-library")
        try FileManager.default.createDirectory(at: edited, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: libraryFolder.appendingPathComponent("library.json"), to: edited.appendingPathComponent("library.json"))
        var notes = try JSONSerialization.jsonObject(with: Data(contentsOf: libraryFolder.appendingPathComponent("annotations.json"))) as! [String: Any]
        var bySource = notes["by_source_sha256"] as! [String: Any]
        let arti = "bb0a00a3ead39b51763e4a62f4963b72a4836b6448622d98c5b94fa7b6d37285"
        var artiNote = bySource[arti] as! [String: Any]; artiNote["category"] = "Voice"; bySource[arti] = artiNote; notes["by_source_sha256"] = bySource
        try JSONSerialization.data(withJSONObject: notes).write(to: edited.appendingPathComponent("annotations.json"))
        check(try ReferenceLibrary.load(from: edited).references(for: .voice).count == 5, "annotation category wins")
        print("PASS: confirmed annotations override library labels")

        // 3. Import copies only measurement files and leaves the source library unchanged; invalid folders are refused.
        let workspace = Workspace(dataDirectory: area.appendingPathComponent("app"))
        check(workspace.references.isEmpty, "fresh workspace has no library")
        workspace.references = try ReferenceLibrary.install(from: libraryFolder, into: workspace.referenceFolder)
        let installed = try FileManager.default.contentsOfDirectory(atPath: workspace.referenceFolder.path).sorted()
        check(installed == ["annotations.json", "library.json"], "only measurement files installed: \(installed)")
        check(try sha(libraryFolder.appendingPathComponent("library.json")) == libraryHash && sha(libraryFolder.appendingPathComponent("annotations.json")) == annotationsHash, "source library unchanged")
        check(Workspace(dataDirectory: area.appendingPathComponent("app")).references.records.count == 6, "library restored on relaunch")
        do { _ = try ReferenceLibrary.install(from: area, into: area.appendingPathComponent("bad")); check(false, "empty folder accepted") } catch {}
        print("PASS: import installs measurements only, restores on relaunch, refuses invalid folders")

        // 4. Preservation: every approved reference, checked against its own category, is left with fixed gain only.
        var base = ProcessingSettings(); base.setMode(.voice)
        base.deess = true; base.cleanupOptions.hum = .hz50; base.highpass = true; base.format = .videoAndWav
        for record in library.records {
            var settings = base; settings.mode = record.mode!
            let levels = record.cuelevelStereo
            let check4 = ReferenceCheck(cue: cue(levels.integratedLufs, tp: levels.truePeakDbtp, lra: levels.loudnessRangeLu, crest: record.crestFactorDb), mode: record.mode!, library: library, settings: settings)
            check(check4.approach == .preserve, "\(record.name) should be preserved")
            let plan = check4.recommendedSettings(from: settings)!
            check(!plan.levelerOptions.enabled && !plan.compression && plan.range == 20 && plan.workingLevel == -18, "\(record.name): dynamics off")
            check(plan.target == settings.target && plan.peak == settings.peak && plan.format == settings.format && plan.mode == settings.mode, "\(record.name): target/ceiling/format/mode untouched")
            check(plan.deess && plan.highpass && plan.cleanupOptions.hum == .hz50 && !plan.denoise && plan.enhancementOptions == settings.enhancementOptions, "\(record.name): cleanup/tone untouched")
            check(plan.peak <= -1, "ceiling never taken from a reference")
            try plan.validate()
        }
        print("PASS: all six references are recommended for preservation (fixed gain only)")

        // 5. Inconsistent speech (measured synthetic fixture: Kishore with a 12 dB step) gets leveling, not compression.
        var speech = ProcessingSettings(); speech.setMode(.voice)
        let uneven = ReferenceCheck(cue: cue(-29.34, tp: -11.17, lra: 16.9, crest: 23.19), mode: .voice, library: library, settings: speech)
        check(uneven.approach == .gentle && uneven.levelerStyle == .balanced && !uneven.controlPeaks, "uneven speech -> balanced leveler")
        let unevenPlan = uneven.recommendedSettings(from: speech)!
        check(unevenPlan.levelerOptions.enabled && unevenPlan.levelerOptions.maximumLift == 6 && !unevenPlan.compression && unevenPlan.workingLevel == -18, "uneven plan settings")
        let slightly = ReferenceCheck(cue: cue(-28, tp: -9, lra: 9.5, crest: 21), mode: .voice, library: library, settings: speech)
        check(slightly.levelerStyle == .gentle, "small excess -> gentle")
        // 6. Spiky speech (Balak with 4 ms clicks) gets peak control, never a stronger leveler.
        let spiky = ReferenceCheck(cue: cue(-26.67, tp: -2.98, lra: 7.0, crest: 28.23), mode: .voice, library: library, settings: speech)
        check(spiky.approach == .gentle && spiky.controlPeaks && spiky.levelerStyle == nil, "spiky -> peak control")
        let spikyPlan = spiky.recommendedSettings(from: speech)!
        check(spikyPlan.compression && spikyPlan.ratio <= 2.0 && !spikyPlan.levelerOptions.enabled, "spiky plan settings")
        // 7. Wide music is flagged but not leveled automatically.
        var song = ProcessingSettings(); song.setMode(.music)
        let wideMusic = ReferenceCheck(cue: cue(-20, tp: -3, lra: 12, crest: 12), mode: .music, library: library, settings: song)
        check(wideMusic.approach == .preserve && wideMusic.findings.contains { $0.needsAttention }, "music dynamics preserved and flagged")
        // 8. Headroom: a fixed gain change that would exceed the ceiling is reported.
        var hot = speech; hot.target = -16
        let act1 = ReferenceCheck(cue: cue(-21.77, tp: -1.71, lra: 6.5, crest: 23.95), mode: .voice, library: library, settings: hot)
        check(near(act1.fixedGainPeak, 4.06, 0.01) && near(act1.headroomShortfall, 6.06, 0.01) && act1.findings.contains { $0.text.contains("dynamic loudness control") }, "headroom shortfall reported")
        // 9. No references in a category -> no recommendation.
        let mixed = ReferenceCheck(cue: cue(-24, tp: -4, lra: 8, crest: 15), mode: .mixed, library: library, settings: ProcessingSettings())
        check(mixed.approach == nil && mixed.recommendedSettings(from: ProcessingSettings()) == nil, "mixed has no recommendation")
        // 10. Without crest data the decision uses loudness range only and says so.
        let legacy = ReferenceCheck(cue: cue(-28, tp: -9, lra: 6.5, crest: nil), mode: .voice, library: library, settings: speech)
        check(legacy.approach == .preserve && legacy.findings.contains { $0.text.contains("Analyse this cue again") }, "legacy analysis handled")
        check(!ReferenceCheck.describeChanges(from: speech, to: unevenPlan).isEmpty && ReferenceCheck.describeChanges(from: unevenPlan, to: unevenPlan).isEmpty, "change descriptions")
        print("PASS: recommendation policy (leveling, peaks, music, headroom, missing references, legacy analyses)")

        // 11. Compatibility: 0.6 settings and measurements decode; 0.6 filter chains are unchanged.
        var legacySettings = try JSONSerialization.jsonObject(with: JSONEncoder().encode(speech)) as! [String: Any]
        legacySettings.removeValue(forKey: "workingLevel")
        let decoded = try JSONDecoder().decode(ProcessingSettings.self, from: JSONSerialization.data(withJSONObject: legacySettings))
        check(decoded.workingLevel == nil && decoded.filterChain(sampleCount: nil, inputLoudness: -30) == decoded.filterChain(sampleCount: nil) && !decoded.filters.contains("volume="), "0.6 chain unchanged")
        let oldMeasurement = #"{"integrated":-23,"truePeak":-2,"loudnessRange":7,"threshold":-33,"offset":0}"#
        check(try JSONDecoder().decode(Measurement.self, from: Data(oldMeasurement.utf8)).crestFactor == nil, "0.6 measurement decodes")
        var levelled = speech; levelled.workingLevel = -18
        check(levelled.filterChain(sampleCount: nil, inputLoudness: -29.34).hasPrefix("volume=11.34dB,"), "working gain inserted first")
        levelled.enhancementOptions.repairClipping = true
        check(levelled.filterChain(sampleCount: nil, inputLoudness: -29.34).hasPrefix("adeclip=w=20:o=50:a=2:t=10:m=save,volume=11.34dB,"), "declip stays first")
        var fixedOnly = levelled; fixedOnly.levelerOptions.enabled = false; fixedOnly.compression = false; fixedOnly.enhancementOptions = EnhancementSettings()
        check(!fixedOnly.filterChain(sampleCount: nil, inputLoudness: -29.34).contains("volume="), "no working gain without level-dependent stages")
        levelled.workingLevel = -40
        do { try levelled.validate(); check(false, "invalid working level accepted") } catch {}
        print("PASS: 0.6 sessions/settings compatible; working gain only when level-dependent stages run")

        // 12. Log parsing for crest and final-stage mode.
        let log = "[Parsed_loudnorm_2 @ 0x1] \n{\n\t\"input_i\" : \"-22.75\",\n\t\"input_tp\" : \"-21.99\",\n\t\"input_lra\" : \"0.00\",\n\t\"input_thresh\" : \"-32.75\",\n\t\"normalization_type\" : \"dynamic\",\n\t\"target_offset\" : \"19.75\"\n}\n[Parsed_astats_1 @ 0x2] Overall\n[Parsed_astats_1 @ 0x2] Peak level dB: -21.989245\n[Parsed_astats_1 @ 0x2] RMS level dB: -24.999272\n"
        let parsed = try Measurement.parse(log)
        check(near(parsed.crestFactor!, 3.010027, 0.0001) && Measurement.normalizationType(in: log) == "dynamic", "parse astats and normalization type")
        check(Measurement.overallStat("Peak level dB", in: "[x] Overall\n[x] Peak level dB: -inf\n") == nil, "silence -> nil")
        print("PASS: crest and final-stage parsing")

        // 13. Engine end to end with the bundled FFmpeg: crest is measured, final-stage mode is recorded, sources are untouched.
        let fixtures = area.appendingPathComponent("fixtures"); try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        let steady = fixtures.appendingPathComponent("steady.wav"), clicks = fixtures.appendingPathComponent("clicks.wav")
        try AudioEngine.run(["-f","lavfi","-i","sine=frequency=440:sample_rate=48000:duration=10","-af","volume=-12dB","-ac","2","-c:a","pcm_s24le",steady.path], token: Cancellation())
        try AudioEngine.run(["-f","lavfi","-i","aevalsrc=0.03*sin(2*PI*440*t)+0.9*sin(2*PI*2000*t)*lt(mod(t\\,2)\\,0.005):s=48000:d=10","-ac","2","-c:a","pcm_s24le",clicks.path], token: Cancellation())
        let hashes = try [sha(steady), sha(clicks)]
        let steadyAnalysis = try AudioEngine.analyze(steady, token: Cancellation()) { _, _ in }
        check(steadyAnalysis.levels.crestFactor != nil && near(steadyAnalysis.levels.crestFactor!, 3.01, 0.2), "sine crest ≈ 3 dB")
        let preserve = ReferenceCheck(cue: steadyAnalysis.levels, mode: .voice, library: library, settings: speech).recommendedSettings(from: speech)!
        let steadyOut = try AudioEngine.process(steady, analysis: steadyAnalysis, settings: preserve, directory: area.appendingPathComponent("render1"), token: Cancellation()) { _, _ in }
        // Regression: a steady tone measures 0 LU, which 0.6 passed to loudnorm as "unmeasured", forcing dynamic mode.
        check(steadyOut.finalGainMode == "linear" && abs(steadyOut.levels.integrated - preserve.target) < 0.5, "preserve -> fixed gain at target (0 LU input)")
        check(!steadyOut.warnings.contains { $0.contains("dynamic loudness control") }, "no dynamic warning for fixed gain")
        let clickAnalysis = try AudioEngine.analyze(clicks, token: Cancellation()) { _, _ in }
        let clickCheck = ReferenceCheck(cue: clickAnalysis.levels, mode: .voice, library: library, settings: preserve)
        check(clickCheck.headroomShortfall > 0, "click fixture predicted to exceed ceiling")
        let clickOut = try AudioEngine.process(clicks, analysis: clickAnalysis, settings: preserve, directory: area.appendingPathComponent("render2"), token: Cancellation()) { _, _ in }
        check(clickOut.finalGainMode == "dynamic" && clickOut.warnings.contains { $0.contains("dynamic loudness control") }, "dynamic fallback detected and reported")
        var paired = preserve; paired.format = .videoAndWav
        let video = root.appendingPathComponent("work/test.mp4")
        let videoHash = try sha(video)
        let videoAnalysis = try AudioEngine.analyze(video, token: Cancellation()) { _, _ in }
        let pairedOut = try AudioEngine.process(video, analysis: videoAnalysis, settings: paired, directory: area.appendingPathComponent("render3"), token: Cancellation()) { _, _ in }
        check(try sha(video) == videoHash, "video source unchanged")
        check(pairedOut.finalGainMode != nil && pairedOut.companionGainMode != nil && pairedOut.levels.crestFactor != nil, "paired output records both final-stage modes")
        var levelledRun = speech; levelledRun.workingLevel = -18
        let levelledOut = try AudioEngine.process(steady, analysis: steadyAnalysis, settings: levelledRun, directory: area.appendingPathComponent("render4"), token: Cancellation()) { _, _ in }
        check(abs(levelledOut.levels.integrated - levelledRun.target) < 1, "working level path reaches target")
        check(try [sha(steady), sha(clicks)] == hashes, "sources unchanged")
        print("PASS: engine records crest and final-stage mode; fixed-gain and fallback cases verified; sources unchanged")

        // 14. Lossless gain-only path (Quick Level): picture untouched, uncompressed audio at the source rate, exact gain, no limiting.
        let plan = LosslessPlan(levels: cue(-27.39, tp: -3.64, lra: 2.4, crest: 27.7), target: -18, ceiling: -1)
        check(near(plan.gain, 2.64, 0.001) && near(plan.shortfall, 6.75, 0.001), "plan stays quieter instead of limiting")
        let roomy = LosslessPlan(levels: cue(-30, tp: -14, lra: 6, crest: 20), target: -18, ceiling: -1)   // +12 dB needed, 13 dB of headroom
        check(roomy.shortfall == 0 && near(roomy.gain, 12) && roomy.limiting == 0, "plan reaches target with headroom")
        check(AudioEngine.losslessExtension(for: URL(fileURLWithPath: "a.MP4"), isVideo: true) == "mov" && AudioEngine.losslessExtension(for: URL(fileURLWithPath: "a.mkv"), isVideo: true) == "mkv" && AudioEngine.losslessExtension(for: URL(fileURLWithPath: "a.mp3"), isVideo: false) == "wav", "container rule")
        var lossless = ProcessingSettings(); lossless.format = .lossless; lossless.target = -18; lossless.peak = -1
        lossless.levelerOptions.enabled = true; lossless.denoise = true; lossless.deess = true   // must all be bypassed
        let clip = fixtures.appendingPathComponent("clip.mp4")
        try AudioEngine.run(["-f","lavfi","-i","testsrc2=s=320x240:r=25:d=4","-f","lavfi","-i","sine=frequency=440:sample_rate=44100:duration=4","-c:v","mpeg4","-q:v","4","-c:a","aac","-b:a","192k","-timecode","01:00:00:00",clip.path], token: Cancellation())
        let clipHash = try sha(clip), clipVideo = try videoDigest(clip)
        let clipAnalysis = try AudioEngine.analyze(clip, token: Cancellation()) { _, _ in }
        check(clipAnalysis.info.videoCodec == "mpeg4", "video codec detected: \(clipAnalysis.info.videoCodec ?? "nil")")
        let clipOut = try AudioEngine.process(clip, analysis: clipAnalysis, settings: lossless, directory: area.appendingPathComponent("render5"), token: Cancellation()) { _, _ in }
        let clipInfo = try AudioEngine.inspect(clipOut.url, token: Cancellation())
        check(clipOut.url.pathExtension == "mov" && clipInfo.isVideo, "MP4 source -> MOV")
        check(try videoDigest(clipOut.url) == clipVideo, "picture packets identical")
        check(clipInfo.audioDescription.hasPrefix("pcm_s24le") && clipInfo.audioDescription.contains("44100 Hz"), "uncompressed audio at source rate: \(clipInfo.audioDescription)")
        check(clipOut.finalGainMode == "fixed" && abs(clipOut.levels.integrated - (-18)) < 0.5 && clipOut.levels.truePeak <= -0.8, "level -18 LUFS, peaks under ceiling: \(clipOut.levels.integrated) / \(clipOut.levels.truePeak)")
        let timecodeLog = try AudioEngine.run(["-i", clipOut.url.path, "-f", "null", "-t", "0", "-"], token: Cancellation())
        check(timecodeLog.contains("01:00:00:00"), "timecode kept")
        check(try sha(clip) == clipHash, "video source unchanged")
        // Peaky cue: stays quieter rather than being limited.
        var quiet = lossless; quiet.levelerOptions.enabled = false
        let clickLossless = try AudioEngine.process(clicks, analysis: clickAnalysis, settings: quiet, directory: area.appendingPathComponent("render6"), token: Cancellation()) { _, _ in }
        let clickPlan = LosslessPlan(levels: clickAnalysis.levels, target: -18, ceiling: -1)
        check(clickPlan.shortfall > 1 && abs(clickLossless.levels.integrated - (-18 - clickPlan.shortfall)) < 0.5 && clickLossless.levels.truePeak <= -0.8, "peaky cue kept quieter, peaks intact")
        check(clickLossless.warnings.contains { $0.contains("below the -18.0 LUFS target") } && clickLossless.url.pathExtension == "wav", "shortfall reported; audio stays WAV")
        check(try AudioEngine.inspect(clickLossless.url, token: Cancellation()).audioDescription.contains("48000 Hz"), "48 kHz source stays 48 kHz")
        // Non-QuickTime video stays MKV, with a note.
        let mkv = fixtures.appendingPathComponent("clip.mkv")
        try AudioEngine.run(["-i", clip.path, "-map", "0:v", "-map", "0:a", "-c", "copy", mkv.path], token: Cancellation())
        let mkvAnalysis = try AudioEngine.analyze(mkv, token: Cancellation()) { _, _ in }
        let mkvOut = try AudioEngine.process(mkv, analysis: mkvAnalysis, settings: lossless, directory: area.appendingPathComponent("render7"), token: Cancellation()) { _, _ in }
        let mkvVideo = try videoDigest(mkvOut.url)
        check(mkvOut.url.pathExtension == "mkv" && mkvOut.warnings.contains { $0.contains("MKV") } && mkvVideo == clipVideo, "MKV kept, picture identical")
        print("PASS: lossless path — picture identical, PCM at source rate, exact gain to -18 LUFS, timecode kept, no limiting")

        // 15. Quick Level settings persist; numbered destinations never overwrite.
        let quickArea = area.appendingPathComponent("quick")
        let quickApp = Workspace(dataDirectory: quickArea)
        quickApp.quickFolder = fixtures; quickApp.quickLevel = true; quickApp.persist()
        let reopened = Workspace(dataDirectory: quickArea)
        check(reopened.quickLevel && reopened.quickFolder == fixtures, "Quick Level restored")
        check(Workspace.uniqueDestination(in: fixtures, name: "clip.mp4").lastPathComponent == "clip 2.mp4" && Workspace.uniqueDestination(in: fixtures, name: "new.mov").lastPathComponent == "new.mov", "numbered destinations")
        print("PASS: Quick Level persistence and non-overwriting destinations")

        // 16. 1.0: surround and multi-track inputs are accepted and described.
        func make(_ name: String, _ args: [String]) throws -> URL { let url = fixtures.appendingPathComponent(name); try AudioEngine.run(args + [url.path], token: Cancellation()); return url }
        let surround = try make("s51.wav", ["-f","lavfi","-i","sine=frequency=440:duration=4","-af","pan=5.1|FL=c0|FR=c0|FC=c0|LFE=c0|BL=c0|BR=c0","-c:a","pcm_s24le"])
        let surroundInfo = try AudioEngine.inspect(surround, token: Cancellation())
        check(surroundInfo.channels == 6 && surroundInfo.sampleRate == 44100 && surroundInfo.audioStreams == 1, "5.1 accepted: \(surroundInfo.channels) ch")
        check(AudioEngine.channelCount("Audio: aac (LC), 48000 Hz, 5.1(side), fltp") == 6 && AudioEngine.channelCount("Audio: pcm_s24le, 48000 Hz, 3 channels, s32") == 3 && AudioEngine.channelCount("Audio: aac, 48000 Hz, stereo, fltp") == 2, "layout parsing")
        let multi = try make("multi.mp4", ["-f","lavfi","-i","testsrc2=s=320x240:r=25:d=3","-f","lavfi","-i","sine=frequency=440:duration=3","-f","lavfi","-i","sine=frequency=880:duration=3","-f","lavfi","-i","sine=frequency=660:duration=3","-map","0","-map","1","-map","2","-map","3","-c:v","mpeg4","-c:a","aac"])
        let multiAnalysis = try AudioEngine.analyze(multi, token: Cancellation()) { _, _ in }
        check(multiAnalysis.info.audioStreams == 3 && multiAnalysis.sourceFindings.contains { $0.contains("3 audio tracks") }, "multi-track described")
        let multiOut = try AudioEngine.process(multi, analysis: multiAnalysis, settings: lossless, directory: area.appendingPathComponent("render8"), token: Cancellation()) { _, _ in }
        func trackDigest(_ url: URL, _ index: Int) throws -> String {
            let box = Bytes(); try AudioEngine.run(["-i", url.path, "-map", "0:a:\(index)", "-c", "copy", "-f", "md5", "pipe:1"], token: Cancellation(), output: { box.data.append($0) }); return String(decoding: box.data, as: UTF8.self)
        }
        let multiOutInfo = try AudioEngine.inspect(multiOut.url, token: Cancellation())
        check(multiOutInfo.audioStreams == 3 && multiOutInfo.audioDescription.hasPrefix("pcm_s24le"), "three tracks out, first levelled")
        check(try trackDigest(multi, 1) == trackDigest(multiOut.url, 1) && trackDigest(multi, 2) == trackDigest(multiOut.url, 2), "extra tracks bit-identical")
        check(try videoDigest(multiOut.url) == videoDigest(multi), "picture identical with extra tracks")
        let videoFirst = try AudioEngine.run(["-i", multiOut.url.path, "-t", "0", "-f", "null", "-"], token: Cancellation())
        check(videoFirst.range(of: "Stream #0:0")!.lowerBound < videoFirst.range(of: "Video:")!.lowerBound && videoFirst.range(of: "Video:")!.lowerBound < videoFirst.range(of: "Stream #0:1")!.lowerBound, "video is the first stream")
        print("PASS: surround and multi-track input; extra tracks copied untouched; video first")

        // 17. Optional peak limiter: reaches more of the target, peaks held at the ceiling, length unchanged.
        var limited = lossless; limited.levelerOptions.enabled = false; limited.denoise = false; limited.deess = false; limited.peakLimit = 3
        try limited.validate()
        let limPlan = LosslessPlan(levels: clickAnalysis.levels, target: -18, ceiling: -1, maxLimiting: 3)
        check(near(limPlan.limiting, 3, 0.001) && near(limPlan.shortfall, clickPlan.shortfall - 3, 0.001), "limiter plan capped at 3 dB")
        let limOut = try AudioEngine.process(clicks, analysis: clickAnalysis, settings: limited, directory: area.appendingPathComponent("render9"), token: Cancellation()) { _, _ in }
        let limAnalysis = try AudioEngine.analyze(limOut.url, token: Cancellation()) { _, _ in }
        check(limOut.finalGainMode == "limited" && limOut.levels.truePeak <= -0.8 && limOut.warnings.contains { $0.contains("Peak limiter") }, "limited output under the ceiling: \(limOut.levels.truePeak)")
        check(limAnalysis.sampleCount == clickAnalysis.sampleCount && limAnalysis.info.sampleRate == 48000, "length and rate unchanged by limiter")
        var badLimit = limited; badLimit.peakLimit = 9
        do { try badLimit.validate(); check(false, "limit above 6 dB accepted") } catch {}
        print("PASS: optional peak limiter")

        // 18. Loudness-over-time and source checks.
        check((clickAnalysis.loudnessCurve?.count ?? 0) >= 50 && (clickAnalysis.loudnessCurve ?? []).allSatisfy { $0 >= -70 && $0 <= 0 }, "loudness curve present")
        check((clipOut.loudnessCurve?.isEmpty ?? true) == false, "output loudness curve present")
        let dc = try make("dc.wav", ["-f","lavfi","-i","aevalsrc=0.1*sin(2*PI*440*t)+0.01:s=48000:d=4","-c:a","pcm_s24le"])
        let phase = try make("phase.wav", ["-f","lavfi","-i","aevalsrc=0.2*sin(2*PI*440*t)|-0.2*sin(2*PI*440*t):s=48000:d=4","-c:a","pcm_s24le"])
        let head = try make("head.wav", ["-f","lavfi","-i","aevalsrc=0.2*sin(2*PI*440*t)*gte(t\\,3):s=48000:d=6","-ac","2","-c:a","pcm_s24le"])
        let clipped = try make("clipped.wav", ["-f","lavfi","-i","aevalsrc=0.9*sin(2*PI*440*t):s=48000:d=3","-af","volume=12dB","-ac","2","-c:a","pcm_s16le"])
        func findings(_ url: URL) throws -> [String] { try AudioEngine.analyze(url, token: Cancellation()) { _, _ in }.sourceFindings }
        check(try findings(dc).contains { $0.contains("DC offset") }, "DC offset found")
        check(try findings(phase).contains { $0.contains("out of phase") }, "phase problem found")
        let headFindings = try findings(head)
        check(headFindings.contains { $0.contains("silence at the start") } && headFindings.contains { $0.contains("effectively a mono file") }, "head silence and dual-mono found: \(headFindings)")
        check(try findings(clipped).contains { $0.contains("Probable clipping") }, "clipping found")
        check(try findings(steady).allSatisfy { !$0.contains("clipping") && !$0.contains("DC offset") }, "no false clipping/DC on a clean tone")
        print("PASS: loudness-over-time and source checks")

        // 19. Show report: one row per analysed cue, CSV quoting, HTML escaping.
        var reportJob = CueJob(source: URL(fileURLWithPath: "/show/Cue 1, \"Intro\" <final>.mp4")); reportJob.analysis = clipAnalysis; reportJob.output = clipOut; reportJob.status = .ready
        reportJob.exportURL = URL(fileURLWithPath: "/out/Cue 1.mov")
        let unanalysed = CueJob(source: URL(fileURLWithPath: "/show/never.wav"))
        let rows = Workspace.showReportRows([reportJob, unanalysed])
        check(rows.count == 2 && rows[0][0] == "Cue" && rows[1][1] == "Cue 1.mov" && rows[1][9] == String(format: "%.1f", clipOut.levels.integrated), "report rows")
        let csv = Workspace.showReportCSV([reportJob])
        check(csv.contains("\"Cue 1, \"\"Intro\"\" <final>.mp4\"") && csv.hasSuffix("\n"), "CSV quoting")
        let html = Workspace.showReportHTML([reportJob], title: "Show <test>")
        check(html.contains("&lt;final&gt;") && html.contains("Show &lt;test&gt;") && html.contains("<table>"), "HTML escaping")
        print("PASS: show report")

        // 20. Per-cue recommendations, loudness standards, watch folder.
        let unevenAnalysis = Analysis(info: clickAnalysis.info, levels: cue(-29.34, tp: -11.17, lra: 16.9, crest: 23.19), waveform: [])
        check(Workspace.settingsForCue(speech, analysis: unevenAnalysis, library: library, recommend: true).levelerOptions.style == .balanced, "per-cue recommendation applied")
        check(Workspace.settingsForCue(speech, analysis: unevenAnalysis, library: library, recommend: false) == speech, "off leaves settings")
        check(Workspace.settingsForCue(lossless, analysis: unevenAnalysis, library: library, recommend: true) == lossless, "lossless never changed")
        for preset in LoudnessPreset.all { var p = ProcessingSettings(); p.target = preset.target; p.peak = preset.peak; try p.validate() }
        let watchDir = area.appendingPathComponent("watch"); try FileManager.default.createDirectory(at: watchDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: steady, to: watchDir.appendingPathComponent("already-here.wav"))
        let watcher = Workspace(dataDirectory: area.appendingPathComponent("watch-app"))
        watcher.watchFolder = watchDir; watcher.startWatching()
        try FileManager.default.copyItem(at: clicks, to: watchDir.appendingPathComponent("new cue.wav"))
        try Data("not media".utf8).write(to: watchDir.appendingPathComponent("notes.txt"))
        watcher.scanWatchFolder()
        check(watcher.jobs.isEmpty, "waits until the file size is stable")
        watcher.scanWatchFolder()
        check(watcher.jobs.map(\.source.lastPathComponent) == ["new cue.wav"], "only the new media file is added: \(watcher.jobs.map(\.source.lastPathComponent))")
        watcher.setWatching(false)
        check(Workspace(dataDirectory: area.appendingPathComponent("watch-app")).watchFolder == watchDir, "watch folder remembered")
        print("PASS: per-cue recommendations, loudness standards, watch folder")

        // 21. Growing the reference catalogue: add, re-add (replace), category via annotations, remove. Originals untouched.
        let catalogue = area.appendingPathComponent("catalogue")
        _ = try ReferenceLibrary.install(from: libraryFolder, into: catalogue)
        let steadySha = try Updater.sha256(of: steady)
        check(try steadySha == sha(steady), "streaming SHA-256 matches")
        let newRecord = ReferenceLibrary.record(for: steadyAnalysis, name: "steady.wav", sha256: steadySha, category: .mixed, note: "walk-in", version: "test")
        var grown = try ReferenceLibrary.add(newRecord, into: catalogue)
        check(grown.records.count == 7 && grown.references(for: .mixed).count == 1 && grown.span(for: .mixed) != nil, "added reference creates an Audio + voice span")
        check(grown.records.first { $0.sha256 == steadySha }?.contentDescription == "walk-in", "note kept")
        grown = try ReferenceLibrary.add(ReferenceLibrary.record(for: steadyAnalysis, name: "steady.wav", sha256: steadySha, category: .voice, note: "", version: "test"), into: catalogue)
        check(grown.records.count == 7 && grown.references(for: .voice).count == 5 && grown.references(for: .mixed).isEmpty, "re-adding replaces, not duplicates")
        let annotated = library.records.first!
        var relabel = ReferenceLibrary.record(for: steadyAnalysis, name: annotated.name, sha256: annotated.sha256, category: .mixed, note: "", version: "test")
        relabel["id"] = annotated.id
        grown = try ReferenceLibrary.add(relabel, into: catalogue)
        check(grown.records.first { $0.sha256 == annotated.sha256 }?.mode == .mixed, "category change survives annotations")
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogue.appendingPathComponent("library.json"))) as! [String: Any]
        check(raw["purpose"] != nil && raw["created_utc"] != nil, "library header fields kept")
        grown = try ReferenceLibrary.remove(id: String(steadySha.prefix(16)), from: catalogue)
        check(grown.records.count == 6 && !grown.records.contains { $0.sha256 == steadySha }, "reference removed")
        let fresh = try ReferenceLibrary.add(newRecord, into: area.appendingPathComponent("empty-catalogue"))
        check(fresh.records.count == 1, "first reference creates a library")
        check(try [sha(libraryFolder.appendingPathComponent("library.json")), sha(libraryFolder.appendingPathComponent("annotations.json"))] == [libraryHash, annotationsHash], "source library untouched")
        print("PASS: reference catalogue grows, replaces, relabels and removes")

        // 22. Update feed: parsing, version rules, refusing incomplete feeds, install destination.
        let feedJSON = #"{"schema":1,"version":"1.1.0","build":105,"minimumSystemVersion":"13.0","url":"https://github.com/chugs024/cuelevel-updates/releases/download/v1.1.0/CueLevel-1.1.0.dmg","sha256":"\#(String(repeating: "ab", count: 32))","size":1,"teamID":"327ABFB3W2","notes":"- Faster\n\n• Safer"}"#
        let feed = try Appcast.decode(Data(feedJSON.utf8))
        check(feed.isNewer(thanBuild: 9) && !feed.isNewer(thanBuild: 105) && !feed.isNewer(thanBuild: 200), "build comparison")
        check(feed.noteLines == ["Faster", "Safer"], "notes cleaned: \(feed.noteLines)")
        var future = feed; future.minimumSystemVersion = "99.0"
        check(!future.isNewer(thanBuild: 9), "too-new macOS requirement ignored")
        check((try? Appcast.decode(Data(feedJSON.replacingOccurrences(of: "https://", with: "http://").utf8))) == nil, "plain HTTP refused")
        check((try? Appcast.decode(Data(#"{"version":"1","build":2,"url":"https://x.y/z.dmg","sha256":"short"}"#.utf8))) == nil, "bad checksum refused")
        check(Updater.installDestination(bundle: URL(fileURLWithPath: "/Volumes/CueLevel 1.1/CueLevel.app")).path == "/Applications/CueLevel.app", "never installs onto the DMG")
        check(Updater.shellQuote("it's") == "'it'\\''s'", "shell quoting")
        print("PASS: update feed rules")
        print("ALL 1.1 TESTS PASSED")
    }
}
