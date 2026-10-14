import Cocoa
import SwiftUI
import AVKit
import UniformTypeIdentifiers

/// Version shown in the interface and reports, read from the app bundle (1.0.0 when run outside a bundle, e.g. tests).
let appShortVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.1.0"
func clockText(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "00:00" }
    let s = Int(seconds); return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
}
enum JobStatus: String, Codable { case queued = "Queued", analyzed = "Analysed", working = "Working", ready = "Ready", review = "Review", failed = "Failed", cancelled = "Cancelled" }
struct CueJob: Identifiable, Codable {
    var id = UUID()
    var source: URL
    var status = JobStatus.queued
    var analysis: Analysis?
    var output: ProcessedAudio?
    var message = "Ready for analysis"
    var progress = 0.0
    var audioExportURL: URL? = nil
    var exportURL: URL?
    /// Clip gain sections drawn on this cue (1.2). Applied when the cue is levelled; the output replaces the normal one.
    var clipGain: [GainRegion]? = nil
    /// In/out points, edge fades and markers (1.5).
    var edit: CueEdit? = nil
    /// Saved alternative edits (1.6) and the on-device transcript.
    var versions: [CueVersion]? = nil
    var transcript: [TranscriptWord]? = nil
    /// Set when Quick Level found nothing to change (1.8): why the cue is already good.
    var alreadyGood: String? = nil
    /// This cue's content type when it differs from the show's (2.0.1), e.g. a music bed in a voice show.
    var mode: ContentMode? = nil
    /// Quick Level left Even out off because the cue plays continuously, like music (2.0.1).
    var evenOutSkipped: Bool? = nil
}
struct SavedPreset: Codable, Identifiable { var id = UUID(); var name: String; var settings: ProcessingSettings }
struct Session: Codable {
    var jobs: [CueJob]; var settings: ProcessingSettings; var presets: [SavedPreset]
    var quickLevel: Bool? = nil; var quickFolder: URL? = nil
    var watchFolder: URL? = nil; var watching: Bool? = nil; var autoRecommend: Bool? = nil
    var settingsRevision: Int? = nil
    var evenOut: Bool? = nil
    var autoTrim: Bool? = nil
}
/// Common loudness specifications. Targets and ceilings only; nothing else changes.
struct LoudnessPreset: Identifiable, Hashable {
    var name: String; var target: Double; var peak: Double
    var id: String { name }
    static let all = [LoudnessPreset(name: "Live venue · −18 LUFS", target: -18, peak: -1),
                      LoudnessPreset(name: "EBU R128 broadcast · −23 LUFS", target: -23, peak: -1),
                      LoudnessPreset(name: "ATSC A/85 (US TV) · −24 LUFS", target: -24, peak: -2),
                      LoudnessPreset(name: "Online video · −16 LUFS", target: -16, peak: -1),
                      LoudnessPreset(name: "Music streaming · −14 LUFS", target: -14, peak: -1)]
}
/// File types the watch folder picks up.
/// Runs blocking work (FFmpeg runs, file copies) on a GCD thread. Task.detached would park it on Swift's small cooperative
/// pool, where a few long FFmpeg runs could starve everything else (2.0.1: adding 25 files froze levelling at "Starting").
func offPool<T>(_ work: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try work() }) }
    }
}
let mediaExtensions: Set<String> = ["wav", "wave", "aif", "aiff", "aifc", "caf", "mp3", "m4a", "aac", "flac", "ogg", "opus", "wma", "mp4", "m4v", "mov", "qt", "mkv", "mka", "webm", "avi", "mxf", "mts", "m2ts", "ts"]
struct ExportReport: Codable {
    var application = "CueLevel \(appShortVersion)"
    var source: String
    var output: String
    var before: Measurement
    var after: Measurement
    var settings: ProcessingSettings
    var notes: [String]
    var date: Date
    var audioCompanion: String? = nil
    var companionLevels: Measurement? = nil
    var finalGainMode: String? = nil
    var referenceCheck: [String]? = nil
}
@MainActor final class Workspace: ObservableObject {
    @Published var jobs: [CueJob] = []
    @Published var selection: UUID? { didSet { selectedRegion = nil; loadPlayer() } }
    @Published var settings = Workspace.venueDefaults { didSet { persist() } }
    /// New sessions start at the live-venue standard: −18 LUFS, −1 dBTP.
    static var venueDefaults: ProcessingSettings { var s = ProcessingSettings(); s.target = -18; s.peak = -1; s.format = .lossless; return s }
    /// Bumped when a default changes; older sessions are migrated once on load.
    static let settingsRevision = 3
    @Published var presets: [SavedPreset] = []
    @Published var busy = false
    @Published var workingID: UUID?
    @Published var status = "Add files to begin"
    @Published var error: String?
    @Published var advanced = false
    @Published var player = AVPlayer()
    @Published var processedPreview = false
    @Published var matchPreview = true
    @Published var playhead = 0.0
    @Published var playing = false
    @Published var referenceDescription = "Measure a mastered cue to set the loudness target."
    @Published var showSavePreset = false
    @Published var presetName = ""
    @Published var showAbout = false
    @Published var references = ReferenceLibrary()
    /// "Add as reference" sheet: the cue being added, its category and an optional note.
    @Published var referenceDraft: UUID?
    @Published var referenceDraftCategory = ContentMode.voice
    @Published var referenceDraftNote = ""
    /// Quick Level: dropped files are analysed, levelled losslessly and saved to quickFolder without any dialogs.
    @Published var quickLevel = false
    @Published var quickFolder: URL?
    static let quickTarget = -18.0
    static let quickCeiling = -1.0
    /// Watch folder: new files saved into it are added automatically (and levelled when Quick Level is on).
    @Published var watchFolder: URL?
    @Published var watching = false
    /// Apply each cue's reference recommendation automatically when processing a batch (non-lossless modes).
    @Published var autoRecommend = false { didSet { persist() } }
    /// Quick Level: even out clearly loud or quiet stretches with clip gain before levelling (1.4). On by default.
    @Published var evenOut = true { didSet { persist() } }
    /// Quick Level: trim silence at the start and end of audio files (video keeps its length; the head is silenced instead).
    @Published var autoTrim = false { didSet { persist() } }
    private var watchTimer: Timer?
    /// Files seen in the watch folder, with their last observed size, so only new, fully written files are added.
    private var watchSeen: [String: Int64] = [:]
    private var watchPending: [String: Int64] = [:]
    private var token: Cancellation?
    private var observation: Any?
    private var playerError: NSKeyValueObservation?
    let directory: URL
    var selected: CueJob? { jobs.first { $0.id == selection } }
    /// A cue's content type: its own choice, else the show's.
    func mode(for job: CueJob?) -> ContentMode { job?.mode ?? settings.mode }
    /// The show settings as they apply to one cue (its own content type).
    func cueSettings(_ job: CueJob?) -> ProcessingSettings { Self.applying(job?.mode, to: settings) }
    static func applying(_ mode: ContentMode?, to base: ProcessingSettings) -> ProcessingSettings {
        guard let mode, mode != base.mode else { return base }
        var s = base
        if s.format == .lossless { s.mode = mode } else { s.setMode(mode) }
        return s
    }
    /// Sets the selected cue's content type (nil = follow the show).
    func setCueMode(_ mode: ContentMode?) {
        guard let id = selection else { return }
        update(id) { $0.mode = mode }; persist()
    }
    var completedCount: Int { jobs.filter { $0.output != nil }.count }
    var remainingCount: Int { jobs.filter { $0.output == nil }.count }
    var currentWaveform: [Float] { processedPreview ? (selected?.output?.waveform ?? []) : (selected?.analysis?.waveform ?? []) }
    var currentCurve: [Float] { processedPreview ? (selected?.output?.loudnessCurve ?? []) : (selected?.analysis?.loudnessCurve ?? []) }
    var duration: Double { selected?.analysis?.info.duration ?? 0 }
    var outputIsStale: Bool {
        guard let job = selected, var used = job.output?.settings else { return false }
        if ClipGain.active(used.clipGain) != ClipGain.active(job.clipGain) { return true }
        let duration = job.analysis?.info.duration ?? 0
        func audible(_ e: CueEdit?) -> CueEdit? {
            guard let e else { return nil }
            var n = e.normalized(duration: duration); n.markers = []
            return n.changesAudio(duration: duration) ? n : nil
        }
        if audible(used.edit) != audible(job.edit) { return true }
        used.clipGain = nil; used.edit = nil
        // Per-cue recommendations and Quick Level legitimately change some settings per cue; compare what the user controls.
        if autoRecommend || used.format == .lossless {
            return used.target != settings.target || used.peak != settings.peak || used.mode != mode(for: job) || (used.format == .lossless) != (settings.format == .lossless || quickLevel) || (used.format == .lossless && used.peakLimit != settings.peakLimit)
        }
        return used != settings
    }
    var canCancel: Bool { token != nil }
    var referenceFolder: URL { directory.appendingPathComponent(ReferenceLibrary.folderName, isDirectory: true) }
    init(dataDirectory: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        // Development builds set CueLevelDataFolder so they never read or rewrite the installed app's session.
        let folder = (Bundle.main.object(forInfoDictionaryKey: "CueLevelDataFolder") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "CueLevel"
        directory = dataDirectory ?? base.appendingPathComponent(folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        references = (try? ReferenceLibrary.load(from: directory.appendingPathComponent(ReferenceLibrary.folderName, isDirectory: true))) ?? ReferenceLibrary()
        if let data = try? Data(contentsOf: directory.appendingPathComponent("session.json")), let saved = try? JSONDecoder().decode(Session.self, from: data) {
            jobs = saved.jobs; settings = saved.settings; presets = saved.presets
            quickFolder = saved.quickFolder; quickLevel = saved.quickLevel ?? false
            watchFolder = saved.watchFolder; autoRecommend = saved.autoRecommend ?? false; evenOut = saved.evenOut ?? true; autoTrim = saved.autoTrim ?? false
            if saved.watching == true, saved.watchFolder != nil { startWatching() }
            settings.cut = max(2, settings.cut)
            // 1.1.1: the standard is now −18 LUFS. A session still on the old −23 default moves to −18 / −1 dBTP once;
            // any other target the user chose is kept.
            if (saved.settingsRevision ?? 1) < 2, settings.target == -23 {
                settings.target = -18; if settings.peak == -2 { settings.peak = -1 }
            }
            // 2.0: levelling is lossless by default (one exact gain change). Sessions on the old automatic file type move once.
            if (saved.settingsRevision ?? 1) < 3, settings.format == .automatic { settings.format = .lossless }
            for i in presets.indices { presets[i].settings.cut = max(2, presets[i].settings.cut) }
            for i in jobs.indices {
                if jobs[i].status == .working { jobs[i].status = .queued; jobs[i].message = "Interrupted — ready to retry"; jobs[i].progress = 0 }
                if let copy = jobs[i].output?.audioCompanion, !FileManager.default.fileExists(atPath: copy.path) {
                    jobs[i].output?.audioCompanion = nil; jobs[i].output?.companionLevels = nil
                    jobs[i].output?.warnings.append("WAV copy missing from cache. Process again to recreate the pair.")
                    jobs[i].status = .review
                }
                if let output = jobs[i].output, !FileManager.default.fileExists(atPath: output.url.path) { jobs[i].output = nil; jobs[i].status = .queued; jobs[i].message = "Cached output unavailable — reprocess" }
            }
        }
        observation = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.playhead = time.seconds.isFinite ? time.seconds : 0
                self.playing = self.player.rate > 0
            }
        }
        selection = jobs.first?.id
        loadPlayer()
        status = jobs.isEmpty ? "Add files to begin" : "Previous session restored"
    }
    func persist() {
        let snapshot = Session(jobs: jobs, settings: settings, presets: presets, quickLevel: quickLevel, quickFolder: quickFolder, watchFolder: watchFolder, watching: watching, autoRecommend: autoRecommend, settingsRevision: Self.settingsRevision, evenOut: evenOut, autoTrim: autoTrim)
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: directory.appendingPathComponent("session.json"), options: .atomic) }
    }
    func changeMode(_ mode: ContentMode) { settings.setMode(mode) }
    func addFiles() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.message = "Add audio or video cues, or a folder of them. Files stay on your Mac."
        if panel.runModal() == .OK { add(panel.urls) }
    }
    /// Files as given, with any folder replaced by the audio and video files inside it (2.0.1: folders can be dropped).
    static func expandFolders(_ urls: [URL]) -> [URL] {
        urls.flatMap { url -> [URL] in
            var isDirectory: ObjCBool = false
            guard url.isFileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  !url.pathExtension.lowercased().hasSuffix("app") else { return [url] }
            let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
            var found: [URL] = []
            while let item = walker?.nextObject() as? URL {
                if mediaExtensions.contains(item.pathExtension.lowercased()), (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { found.append(item) }
            }
            return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
    }
    func add(_ urls: [URL]) {
        var added: [UUID] = []
        for url in Self.expandFolders(urls) where url.isFileURL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
            if jobs.contains(where: { $0.source.standardizedFileURL.resolvingSymlinksInPath() == normalized }) { continue }
            let job = CueJob(source: url); jobs.append(job); added.append(job.id)
        }
        guard let first = added.first else { return }
        selection = first; status = "Added \(added.count) file\(added.count == 1 ? "" : "s")"; persist()
        if quickLevel {
            // Files dropped while a batch is running are picked up when it finishes.
            if !busy { run(ids: added, render: true) } else { status = "Added \(added.count) to Quick Level — waiting for the current batch" }
        } else if !busy { run(ids: added, render: false) }   // measure everything that was added, not only the selection
        else { status = "Added \(added.count) file\(added.count == 1 ? "" : "s"). They'll be measured when the current job finishes." }
    }
    func update(_ id: UUID, _ edit: (inout CueJob) -> Void) { if let i = jobs.firstIndex(where: { $0.id == id }) { edit(&jobs[i]) } }
    func progress(_ id: UUID, _ value: Double, _ message: String) {
        guard busy, workingID == id else { return }
        update(id) { $0.progress = value; $0.message = message }; status = message
    }
    func analyze() { guard let id = selection else { return }; run(ids: [id], render: false) }
    func processSelected() { guard let id = selection else { return }; run(ids: [id], render: true) }
    func processQueue() { run(ids: jobs.filter { $0.output == nil }.map(\.id), render: true) }
    /// Quick Level one cue from the inspector: lossless gain (plus Even out when on), then show the Levelled version.
    /// Saved into the Quick Level folder when one is chosen; otherwise use Export.
    func quickLevelSelected() { guard let id = selection else { return }; run(ids: [id], render: true, quickOverride: true) }
    /// Levels every cue that isn't done yet (2.0: "Level all" skips cues already levelled or already good).
    func quickLevelAll() { run(ids: levelAllIDs, render: true, quickOverride: true) }
    /// Cues "Level all" will level: not levelled yet and readable (2.0.1: files that can't be read aren't retried every time).
    var levelAllIDs: [UUID] { jobs.filter { $0.output == nil && $0.status != .failed }.map(\.id) }
    private func run(ids: [UUID], render: Bool, quickOverride: Bool = false) {
        guard !busy, !ids.isEmpty else { return }
        busy = true; player.pause(); playing = false
        let cancellation = Cancellation(); token = cancellation
        // Quick Level always renders the lossless gain-only path, whatever output type a preset selected.
        let quick = render && (quickOverride || quickLevel)
        let options: ProcessingSettings = { var o = settings; if quick { o.format = .lossless }; return o }()
        Task {
            for id in ids {
                do { try cancellation.check() } catch { break }
                guard let current = jobs.first(where: { $0.id == id }) else { continue }
                let perCue = Self.applying(current.mode, to: options)   // 2.0.1: the cue's own content type
                workingID = id
                update(id) { $0.status = .working; $0.progress = 0; $0.message = "Starting"; $0.evenOutSkipped = nil }; persist()
                do {
                    let analysis: Analysis
                    let attributes = try? FileManager.default.attributesOfItem(atPath: current.source.path)
                    let size = (attributes?[.size] as? NSNumber)?.int64Value
                    let modified = attributes?[.modificationDate] as? Date
                    if render, let existing = current.analysis, size == existing.info.byteCount, modified == existing.info.modified { analysis = existing }
                    else {
                        analysis = try await offPool {
                            try AudioEngine.analyze(current.source, token: cancellation) { value, message in
                                Task { @MainActor in self.progress(id, render ? value * 0.3 : value, message) }
                            }
                        }
                    }
                    update(id) { $0.analysis = analysis }
                    var evened = 0
                    // Even out is for speech; a song's loud and quiet parts are part of the music.
                    if render && quick && evenOut && perCue.mode != .music {
                        update(id) { $0.message = "Evening out loud and quiet stretches" }
                        let all = jobs.first(where: { $0.id == id })?.clipGain ?? []
                        let manual = all.filter { $0.isAuto != true }, keep = all.filter { $0.isAuto != true || $0.isGap == true }
                        let source = current.source, info = analysis.info
                        let tolerance = references.evenOutTolerance(for: perCue.mode)
                        let skipMusic = current.mode == nil   // a cue the user marked Voice is always evened
                        let plan = try await offPool { try AudioEngine.evenOutPlan(source, info: info, tolerance: tolerance, keeping: manual, skipMusic: skipMusic, token: cancellation) }
                        let auto = plan.regions
                        update(id) { $0.clipGain = keep + auto; $0.evenOutSkipped = plan.soundsLikeMusic ? true : nil }
                        evened = auto.count
                    }
                    var cueOptions = Self.settingsForCue(perCue, analysis: analysis, library: references, recommend: autoRecommend && !quick)
                    if render && quick && autoTrim, let stats = analysis.stereo {
                        let duration = analysis.info.duration
                        update(id) { $0.edit = CueEdit.trimmedToSound(stats, duration: duration, keeping: $0.edit ?? CueEdit()) }
                    }
                    cueOptions.clipGain = jobs.first(where: { $0.id == id })?.clipGain
                    cueOptions.edit = jobs.first(where: { $0.id == id })?.edit
                    if render {
                        let renderDirectory = directory.appendingPathComponent("Cache/\(id.uuidString)/\(UUID().uuidString)", isDirectory: true)
                        // Quick Level first asks whether the cue needs anything at all.
                        let latest = jobs.first(where: { $0.id == id })
                        let goodReason: String? = quick ? Self.alreadyGoodReason(analysis: analysis, target: cueOptions.target, peak: cueOptions.peak,
                            autoSections: evened, hasEdits: Self.hasHandEdits(latest, duration: analysis.info.duration), library: references, mode: cueOptions.mode) : nil
                        let cueSettings = cueOptions, source = current.source
                        let result = try await offPool { () -> ProcessedAudio in
                            if goodReason != nil { return try AudioEngine.unchangedCopy(source, analysis: analysis, settings: cueSettings, directory: renderDirectory) }
                            return try AudioEngine.process(source, analysis: analysis, settings: cueSettings, directory: renderDirectory, token: cancellation) { value, message in
                                Task { @MainActor in self.progress(id, 0.3 + value * 0.7, message) }
                            }
                        }
                        update(id) { $0.alreadyGood = goodReason }
                        if let previous = current.output { try? FileManager.default.removeItem(at: previous.url.deletingLastPathComponent()) }
                        update(id) { $0.output = result; $0.exportURL = nil; $0.audioExportURL = nil; $0.progress = 1; $0.status = result.warnings.isEmpty ? .ready : .review; $0.message = result.warnings.isEmpty ? "Ready to export" : "Review notes before export" }
                        if quick {
                            let folder = outputFolder
                            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                            let destination = Self.uniqueDestination(in: folder, name: Self.levelledName(for: current.source, target: result.settings.target, ext: result.url.pathExtension))
                            let sources = jobs.map(\.source)
                            do {
                                try await offPool { try Self.atomicCopy(from: result.url, to: destination, sources: sources, allowReplace: false) }
                                update(id) { $0.exportURL = destination; $0.message = goodReason != nil ? "✓ Already good, no change needed → " + destination.lastPathComponent : (evened > 0 ? "Evened out \(evened) stretch\(evened == 1 ? "" : "es"), levelled → " : (result.warnings.isEmpty ? "Levelled → " : "Levelled with notes → ")) + destination.lastPathComponent }
                            } catch {
                                update(id) { $0.status = .review; $0.message = "Levelled, but saving to the Quick Level folder failed: \(error.localizedDescription)" }
                            }
                        }
                    } else { update(id) { $0.progress = 1; $0.status = $0.output == nil ? .analyzed : ($0.output!.warnings.isEmpty ? .ready : .review); $0.message = "Analysis complete" } }
                    if selection == id { processedPreview = render; loadPlayer() }
                } catch is CancellationError {
                    update(id) { $0.status = .cancelled; $0.progress = 0; $0.message = "Cancelled — source unchanged" }; persist(); break
                } catch {
                    update(id) { $0.status = .failed; $0.message = error.localizedDescription; $0.progress = 0 }
                }
                persist()
            }
            workingID = nil; busy = false; token = nil
            let stopped = jobs.contains { $0.status == .cancelled }
            let thisRunStopped = (try? cancellation.check()) == nil
            status = stopped ? "Stopped. Remaining files stay in the queue." : quick ? "Quick Level finished. Levelled files are in \(outputFolderDisplay)." : "Finished. Review your results before export."
            persist()
            if quick { writeShowReport(into: reportsFolder, dated: quickFolder == nil) }
            if quickLevel, !thisRunStopped {
                let waiting = jobs.filter { $0.output == nil && $0.status == .queued }.map(\.id)
                if !waiting.isEmpty { run(ids: waiting, render: true) }
            }
            // 2.0.1: files added while CueLevel was busy are measured as soon as it's free.
            if !thisRunStopped {
                let unmeasured = jobs.filter { $0.analysis == nil && $0.status == .queued }.map(\.id)
                if !unmeasured.isEmpty { run(ids: unmeasured, render: false) }
            }
        }
    }
    func cancel() { token?.cancel(); status = "Stopping…" }
    func removeSelected() {
        guard !busy, let id = selection else { return }
        player.pause(); player.replaceCurrentItem(with: nil)
        jobs.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("Cache/\(id.uuidString)"))
        selection = jobs.first?.id; persist()
    }
    func loadPlayer() {
        player.pause(); playing = false; playhead = 0
        if let sectionStop { player.removeTimeObserver(sectionStop); self.sectionStop = nil }
        if clipEditing && detailFor != selection { history.reset(); timeView = TimeView(); loadDetailWaveform() }
        guard let job = selected else { player.replaceCurrentItem(with: nil); return }
        if processedPreview && job.output == nil { processedPreview = false }
        let url = processedPreview ? job.output!.url : job.source
        let item = AVPlayerItem(url: url); player.replaceCurrentItem(with: item); applyVolume(); applyPreviewMix()
        loadMeterCurve(for: url, duration: job.analysis?.info.duration ?? 0)
        playerError = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            if item.status == .failed { Task { @MainActor in self?.status = "Native preview is unavailable for this format. Processing may still be supported; export to WAV for audio preview." } }
        }
    }
    func switchPreview(_ processed: Bool) {
        guard !processed || selected?.output != nil else { return }
        let position = player.currentTime(); let wasPlaying = player.rate > 0
        processedPreview = processed; loadPlayer()
        player.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in if wasPlaying { Task { @MainActor in self?.player.play() } } }
    }
    func applyVolume() {
        guard matchPreview, let before = selected?.analysis?.levels, let after = selected?.output?.levels else { player.volume = 1; return }
        let common = min(before.integrated, after.integrated)
        player.volume = Float(pow(10, (common - (processedPreview ? after.integrated : before.integrated)) / 20))
    }
    func playPause() { if player.rate > 0 { player.pause() } else { player.play() }; playing = player.rate > 0 }
    func seek(_ seconds: Double) { player.seek(to: CMTime(seconds: max(0, min(duration, seconds)), preferredTimescale: 600)); playhead = seconds }
    func chooseReference() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        if panel.runModal() != .OK { return }; guard let url = panel.url else { return }
        busy = true; let cancellation = Cancellation(); token = cancellation; status = "Measuring reference"
        Task {
            do {
                let reference = try await offPool {
                    let info = try AudioEngine.inspect(url, token: cancellation)
                    return try AudioEngine.measure(url, token: cancellation, duration: info.duration)
                }
                settings.target = min(-12, max(-30, reference.integrated))
                referenceDescription = "\(url.lastPathComponent) · \(String(format: "%.1f", reference.integrated)) LUFS. Target set to \(String(format: "%.1f", settings.target)) LUFS."
                status = "Reference measured. Saved presets can retain this target."
            } catch is CancellationError { status = "Reference measurement cancelled" }
            catch { self.error = error.localizedDescription; status = "Reference could not be measured" }
            busy = false; token = nil; persist()
        }
    }
    /// Compares the cue with the approved references for the currently selected content type.
    func referenceCheck(for job: CueJob, settings options: ProcessingSettings? = nil) -> ReferenceCheck? {
        guard let analysis = job.analysis, !references.isEmpty else { return nil }
        let basis = options ?? cueSettings(job)
        return ReferenceCheck(cue: analysis.levels, mode: basis.mode, library: references, settings: basis)
    }
    /// Applies the recommendation to the processing settings. Nothing is processed until the user chooses Process.
    func applyReferencePlan() {
        guard !busy, let job = selected, let check = referenceCheck(for: job), let next = check.recommendedSettings(from: settings) else { return }
        settings = next
        status = "\(check.approach?.rawValue ?? "Recommendation") applied to settings. Process the cue, then compare at matched loudness."
    }
    func importReferenceLibrary() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "Choose a CueLevel Reference Library folder (containing library.json). Only measurement files are copied; recordings stay where they are."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            references = try ReferenceLibrary.install(from: folder, into: referenceFolder)
            status = "Reference library imported: \(references.summary)"
        } catch { self.error = error.localizedDescription }
    }
    // MARK: Clip gain (1.2)
    @Published var clipEditing = false { didSet { if clipEditing != oldValue { editingChanged() } } }
    @Published var selectedRegion: UUID?
    @Published var measuringSection = false
    /// Zoom window of the clip gain editor, the fine waveform used when zoomed in, and measured section loudness.
    @Published var timeView = TimeView()
    @Published var detailWaveform: [Float] = []
    @Published var sectionLoudness: [UUID: Double] = [:]
    @Published private(set) var history = EditHistory<CueEditState>()
    /// Loop playback of the selected section (or the in–out range), with pre/post-roll in seconds.
    @Published var looping = false
    @Published var preRoll = 1.0
    /// Momentary loudness (100 ms steps) of whatever is loaded in the player, for the live meter.
    @Published var meterCurve: [Float] = []
    private var meterToken: Cancellation?
    private var meterCache: [URL: [Float]] = [:]
    @Published var showShortcuts = false
    var selectedEdit: CueEdit { selected?.edit ?? CueEdit() }
    private var detailFor: UUID?
    private var sectionStop: Any?
    var selectedRegions: [GainRegion] { selected?.clipGain ?? [] }
    var previewAttenuation: Double { -20 * log10(ClipGain.previewScale(selected?.clipGain, edit: selected?.edit, duration: duration)) }

    /// Replaces the selected cue's regions (each normalised to the cue's length) and saves the session.
    func setRegions(_ regions: [GainRegion], recordUndo: Bool = true) {
        guard let id = selection, let duration = selected?.analysis?.info.duration, duration > 0 else { return }
        let before = selectedRegions
        let after = regions.map { $0.normalized(duration: duration) }.sorted { $0.start < $1.start }
        guard after != before else { return }
        if recordUndo { history.record(CueEditState(regions: before, edit: selectedEdit)) }
        update(id) { $0.clipGain = after }
        // Loudness readings are only valid for the edits they were measured with.
        sectionLoudness = [:]
        applyPreviewMix(); persist()
    }
    /// Even out for the selected cue: replaces earlier Even out sections, keeps hand-drawn ones. Undoable.
    func evenOutSelected() {
        guard !measuringSection, let job = selected, let info = job.analysis?.info else { return }
        measuringSection = true; status = "Finding loud and quiet stretches"
        let manual = selectedRegions.filter { $0.isAuto != true }, keep = selectedRegions.filter { $0.isAuto != true || $0.isGap == true }, source = job.source
        Task {
            defer { measuringSection = false }
            do {
                let tolerance = references.evenOutTolerance(for: mode(for: job))
                let auto = try await offPool { try AudioEngine.evenOutRegions(source, info: info, tolerance: tolerance, keeping: manual, token: Cancellation()) }
                setRegions(keep + auto)
                status = auto.isEmpty ? "Already even: nothing is more than \(Int(ClipGain.evenOutTolerance)) dB from the typical level" : "Even out made \(auto.count) section\(auto.count == 1 ? "" : "s"). Adjust any of them, then click Done editing."
            } catch { self.error = error.localizedDescription }
        }
    }
    func undoRegions() { if let previous = history.undo(current: CueEditState(regions: selectedRegions, edit: selectedEdit)) { restore(previous) } }
    func redoRegions() { if let next = history.redo(current: CueEditState(regions: selectedRegions, edit: selectedEdit)) { restore(next) } }
    private func restore(_ state: CueEditState) { setRegions(state.regions, recordUndo: false); setEdit(state.edit, recordUndo: false) }

    // MARK: In/out points, fades, markers, mute, loop (1.5)
    func setEdit(_ edit: CueEdit, recordUndo: Bool = true) {
        guard let id = selection, let duration = selected?.analysis?.info.duration, duration > 0 else { return }
        var edit = edit
        if recordUndo, edit.inPoint != selectedEdit.inPoint, edit.inPoint > 0 { edit.inPoint = snapped(edit.inPoint) }
        if recordUndo, edit.outPoint != selectedEdit.outPoint, let out = edit.outPoint { edit.outPoint = snapped(out) }
        let next = edit.normalized(duration: duration)
        guard next != selectedEdit else { return }
        if recordUndo { history.record(CueEditState(regions: selectedRegions, edit: selectedEdit)) }
        update(id) { $0.edit = next }
        applyPreviewMix(); persist()
    }
    func setInPoint(_ t: Double? = nil) { var e = selectedEdit; e.inPoint = t ?? playhead; setEdit(e) }
    func setOutPoint(_ t: Double? = nil) { var e = selectedEdit; e.outPoint = t ?? playhead; setEdit(e) }
    func clearTrim() { var e = selectedEdit; e.inPoint = 0; e.outPoint = nil; setEdit(e) }
    func trimToSound() {
        guard let analysis = selected?.analysis else { return }
        guard let stats = analysis.stereo else { error = "Measure the cue again to find its silence."; return }
        setEdit(CueEdit.trimmedToSound(stats, duration: analysis.info.duration, keeping: selectedEdit))
        status = "Trimmed to the sound: \(String(format: "%.2f", selectedEdit.inPoint)) s in, out at \(String(format: "%.2f", selectedEdit.end(duration: analysis.info.duration))) s"
    }
    /// Copies this cue's edge fades (lengths and shape) to every cue.
    func applyFadesToAllCues() {
        let source = selectedEdit
        for i in jobs.indices {
            var e = jobs[i].edit ?? CueEdit(); e.fadeIn = source.fadeIn; e.fadeOut = source.fadeOut; e.fadeShape = source.fadeShape
            if let d = jobs[i].analysis?.info.duration { e = e.normalized(duration: d) }
            jobs[i].edit = e
        }
        persist(); status = "Fades applied to all \(jobs.count) cues"
    }
    func addMarker(at t: Double? = nil) {
        var e = selectedEdit
        let time = t ?? playhead
        e.markers.append(CueMarker(time: time, name: "Marker \(e.markers.count + 1)"))
        setEdit(e)
    }
    func renameMarker(_ id: UUID, to name: String) {
        var e = selectedEdit
        guard let i = e.markers.firstIndex(where: { $0.id == id }) else { return }
        e.markers[i].name = name; setEdit(e, recordUndo: false)
    }
    func deleteMarker(_ id: UUID) { var e = selectedEdit; e.markers.removeAll { $0.id == id }; setEdit(e) }
    func toggleMuteSelected() {
        guard var r = selectedRegions.first(where: { $0.id == selectedRegion }) else { status = "Select a section to mute it"; return }
        r.muted = r.muted == true ? nil : true; updateRegion(r)
    }
    /// Plays the selected section (or the in–out range) with pre/post-roll; loops when Loop is on.
    func playRange() {
        let duration = self.duration
        let range: (Double, Double)
        if let r = selectedRegions.first(where: { $0.id == selectedRegion }) { range = (r.start, r.end) }
        else { let e = selectedEdit.normalized(duration: duration); range = (e.inPoint, e.end(duration: duration)) }
        if let sectionStop { player.removeTimeObserver(sectionStop); self.sectionStop = nil }
        let start = max(0, range.0 - preRoll), stop = min(duration, range.1 + preRoll)
        seek(start)
        sectionStop = player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: max(start + 0.05, stop - 0.02), preferredTimescale: 600))], queue: .main) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.looping { self.seek(start); self.player.play(); return }
                self.player.pause(); self.playing = false
                if let s = self.sectionStop { self.player.removeTimeObserver(s); self.sectionStop = nil }
            }
        }
        player.play(); playing = true
    }

    // MARK: 1.6 — snap, lower gaps, versions, transcript, repairs
    /// Section edges and in/out points land on the quietest moment within ±60 ms, so edits never cut through a word.
    @Published var snapToQuiet = true
    @Published var transcribing = false
    func snapped(_ t: Double) -> Double {
        guard snapToQuiet, !detailWaveform.isEmpty, duration > 0 else { return t }
        return ClipGain.snapToQuiet(t, peaks: detailWaveform, duration: duration)
    }
    /// Turns down the pauses between phrases by `depth` dB (replacing earlier gap sections). Undoable.
    func lowerGaps(by depth: Double) {
        guard !measuringSection, let job = selected, let info = job.analysis?.info else { return }
        let keep = selectedRegions.filter { $0.isGap != true }
        guard depth > 0 else { setRegions(keep); status = "Gap sections removed"; return }
        measuringSection = true; status = "Finding the pauses between phrases"
        let source = job.source
        Task {
            defer { measuringSection = false }
            do {
                let gaps = try await offPool { try AudioEngine.gapRegions(source, info: info, depth: depth, token: Cancellation()) }
                setRegions(keep + gaps)
                status = gaps.isEmpty ? "No pauses long enough to lower" : "Lowered \(gaps.count) pause\(gaps.count == 1 ? "" : "s") by \(Int(depth)) dB"
            } catch { self.error = error.localizedDescription }
        }
    }
    var versions: [CueVersion] { selected?.versions ?? [] }
    func saveVersion(named name: String? = nil) {
        guard let id = selection else { return }
        let version = CueVersion(name: name ?? "Version \(versions.count + 1)", regions: selectedRegions, edit: selectedEdit)
        update(id) { $0.versions = ($0.versions ?? []) + [version] }
        persist(); status = "Saved \(version.name)"
    }
    func loadVersion(_ version: CueVersion) {
        history.record(CueEditState(regions: selectedRegions, edit: selectedEdit))
        setRegions(version.regions, recordUndo: false); setEdit(version.edit, recordUndo: false)
        status = "Loaded \(version.name). ⌘Z goes back."
    }
    func deleteVersion(_ version: CueVersion) {
        guard let id = selection else { return }
        update(id) { $0.versions?.removeAll { $0.id == version.id } }; persist()
    }
    func transcribeSelected() {
        guard !transcribing, let job = selected, let info = job.analysis?.info else { return }
        transcribing = true; status = "Transcribing on this Mac…"
        let source = job.source, id = job.id
        Task {
            defer { transcribing = false }
            do {
                let words = try await Transcriber.transcribe(source, duration: info.duration) { fraction in
                    Task { @MainActor in self.status = "Transcribing on this Mac… \(Int(fraction * 100))%" }
                }
                update(id) { $0.transcript = words }; persist()
                status = words.isEmpty ? "No speech found" : "Transcript ready: \(words.count) words"
            } catch { self.error = error.localizedDescription; status = "Transcript not made" }
        }
    }
    func fixDCOffset() { var e = selectedEdit; e.removeDC = true; setEdit(e); status = "DC offset will be removed when the cue is levelled" }
    func fixPolarity(_ fix: PolarityFix) { var e = selectedEdit; e.polarity = fix; setEdit(e); status = fix == .none ? "Polarity normal" : "\(fix.rawValue) when the cue is levelled" }

    // MARK: Already good (1.8)
    /// Hand-made changes (sections drawn by hand, trims, fades, repairs) always mean the cue is processed.
    nonisolated static func hasHandEdits(_ job: CueJob?, duration: Double) -> Bool {
        guard let job else { return false }
        if ClipGain.active(job.clipGain).contains(where: { $0.isAuto != true }) || (job.clipGain ?? []).contains(where: { $0.hasEffects }) { return true }
        return job.edit?.changesAudio(duration: duration) ?? false
    }
    /// Why a cue needs no change, or nil when it does: loudness within 1 LU of the target, peaks under the ceiling,
    /// nothing for Even out to fix, no hand edits, and no clipping, DC offset or phase problem.
    nonisolated static func alreadyGoodReason(analysis: Analysis, target: Double, peak: Double, autoSections: Int, hasEdits: Bool,
                                              library: ReferenceLibrary, mode: ContentMode) -> String? {
        let levels = analysis.levels
        guard abs(levels.integrated - target) <= 1.0, levels.truePeak <= peak, autoSections == 0, !hasEdits else { return nil }
        let problems = analysis.sourceFindings.filter { $0.contains("clipping") || $0.contains("DC offset") || $0.contains("out of phase") }
        guard problems.isEmpty else { return nil }
        func f(_ v: Double) -> String { String(format: "%.1f", v).replacingOccurrences(of: "-", with: "−") }
        var parts = ["\(f(levels.integrated)) LUFS, within 1 LU of \(f(target))", "peaks \(f(levels.truePeak)) dBTP"]
        if let spread = analysis.loudnessCurve.flatMap({ LoudnessProfile(shortTerm: $0.map(Double.init)) })?.spread {
            let good = library.span(for: mode)?.spread
            parts.append(good.map { "moves \(f(spread)) LU (good \(mode.label): \(f($0.lowerBound))–\(f($0.upperBound)))" } ?? "moves \(f(spread)) LU, nothing to even out")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Reference shapes — what good sounds like over time (1.7)
    /// The band where good references of this content type sit, relative to the target (short-term LUFS).
    func goodBand(target: Double) -> ClosedRange<Double>? {
        guard let shape = references.span(for: mode(for: selected))?.shape else { return nil }
        return (target + shape.lowerBound) ... (target + shape.upperBound)
    }
    /// This cue's short-term spread (P90 − P10) from its loudness curve.
    func cueSpread(_ analysis: Analysis) -> Double? { analysis.loudnessCurve.flatMap { LoudnessProfile(shortTerm: $0.map(Double.init)) }?.spread }
    var referencesMissingShapes: Int { references.records.filter { $0.loudnessProfile == nil }.count }
    /// Measures the loudness shape of reference recordings in a folder, matched to the library by fingerprint.
    /// Recordings are only read; nothing is copied.
    func measureReferenceShapes() {
        guard !busy else { return }
        guard !references.isEmpty else { error = "Import your reference library first (References › Import library…)."; return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "Choose the folder with your reference recordings. CueLevel matches them to the library by fingerprint and only reads them."
        let handoff = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/CueLevel-Handoff-2026-10-10/Reference Audio", isDirectory: true)
        if FileManager.default.fileExists(atPath: handoff.path) { panel.directoryURL = handoff }
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let wanted = Set(references.records.map { $0.sha256.lowercased() }), libraryFolder = referenceFolder
        busy = true; status = "Measuring reference shapes…"
        let token = Cancellation(); self.token = token
        Task {
            defer { busy = false; self.token = nil }
            do {
                let result = try await offPool { () -> (ReferenceLibrary, Int) in
                    let files = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? [])
                        .filter { mediaExtensions.contains($0.pathExtension.lowercased()) }
                    var profiles: [String: LoudnessProfile] = [:]
                    for file in files {
                        try token.check()
                        let sha = try Updater.sha256(of: file)
                        guard wanted.contains(sha) else { continue }
                        let info = try AudioEngine.inspect(file, token: token)
                        if let p = try AudioEngine.loudnessProfile(file, duration: info.duration, token: token) { profiles[sha] = p }
                    }
                    return (try ReferenceLibrary.setProfiles(profiles, in: libraryFolder), profiles.count)
                }
                references = result.0
                status = result.1 == 0 ? "No recordings in that folder match your references" : "Measured the shape of \(result.1) reference\(result.1 == 1 ? "" : "s")"
            } catch is CancellationError { status = "Stopped" }
            catch { self.error = error.localizedDescription }
        }
    }

    // MARK: Live meter (1.5)
    func loadMeterCurve(for url: URL, duration: Double) {
        meterToken?.cancel(); meterToken = nil
        if let cached = meterCache[url] { meterCurve = cached; return }
        meterCurve = []
        // 2.0.1: only for measured cues, and the previous cue's meter pass is stopped (clicking down a long list used to queue one FFmpeg run per cue).
        guard duration > 0 else { return }
        let token = Cancellation(); meterToken = token
        Task {
            guard let curve = try? await offPool({ try AudioEngine.momentaryLoudness(url, duration: duration, token: token) }) else { return }
            meterCache[url] = curve
            if player.currentItem.flatMap({ ($0.asset as? AVURLAsset)?.url }) == url { meterCurve = curve }
        }
    }
    /// Momentary and short-term loudness (LUFS) and sample peak (dBFS) at time t of what is playing, including live edits.
    func meterReading(at t: Double) -> (momentary: Double?, shortTerm: Double?, peak: Double?) {
        let editGain: Double = {
            guard clipEditing, !processedPreview else { return 0 }
            let g = ClipGain.envelope(at: t, regions: selected?.clipGain, edit: selected?.edit, duration: duration)
            return g > 0 ? 20 * log10(g) : -120
        }()
        var momentary: Double?, shortTerm: Double?
        let i = Int(t * 10)
        if !meterCurve.isEmpty, i >= 0, i < meterCurve.count {
            let m = Double(meterCurve[i]); momentary = m > -69.9 ? m + editGain : nil
            let window = meterCurve[max(0, i - 29)...i].map { pow(10, Double($0) / 10) }
            let s = 10 * log10(window.reduce(0, +) / Double(window.count))
            shortTerm = s > -69.9 ? s + editGain : nil
        }
        let wave = (clipEditing && !processedPreview && !detailWaveform.isEmpty) ? detailWaveform : currentWaveform
        var peak: Double?
        if !wave.isEmpty, duration > 0 {
            let centre = Int(t / duration * Double(wave.count)), span = max(1, Int(0.15 / duration * Double(wave.count)))
            let lo = max(0, centre - span), hi = min(wave.count - 1, centre + span)
            if lo <= hi, let p = wave[lo...hi].max(), p > 0 { peak = 20 * log10(Double(p)) + editGain }
        }
        return (momentary, shortTerm, peak)
    }

    private func editingChanged() {
        history.reset(); sectionLoudness = [:]; timeView = TimeView()
        if !clipEditing, let s = sectionStop { player.removeTimeObserver(s); sectionStop = nil }
        if clipEditing { loadDetailWaveform() }
        applyPreviewMix()
    }
    /// Loads the 5 ms waveform for zooming, once per cue.
    func loadDetailWaveform() {
        guard let job = selected, let info = job.analysis?.info, detailFor != job.id else { return }
        detailFor = job.id; detailWaveform = []
        let source = job.source, id = job.id
        Task {
            let peaks = try? await offPool { try AudioEngine.detailWaveform(source, duration: info.duration, token: Cancellation()) }
            if selection == id, let peaks { detailWaveform = peaks }
        }
    }
    // Zoom and scroll.
    func zoom(by factor: Double, around anchor: Double? = nil) {
        let resolved = timeView.resolved(duration: duration)
        timeView = timeView.zoomed(by: factor, around: anchor ?? (playhead >= resolved.start && playhead <= resolved.start + resolved.length ? playhead : resolved.start + resolved.length / 2), duration: duration)
    }
    func pan(by seconds: Double) { timeView = timeView.panned(by: seconds, duration: duration) }
    func zoomToFit() { timeView = TimeView() }
    func zoomToSelectedRegion() {
        guard let r = selectedRegions.first(where: { $0.id == selectedRegion }) else { return }
        let pad = max(0.2, r.length * 0.15)
        timeView = TimeView(start: r.start - pad, length: r.length + pad * 2)
        timeView.start = timeView.resolved(duration: duration).start
    }
    /// Plays just the selected section (or from the playhead if none), stopping at its end.
    func playSelectedSection() { playRange() }
    /// Plays the original with the clip gain edits applied in real time (scaled so boosts fit; see previewAttenuation).
    func applyPreviewMix() {
        guard let item = player.currentItem else { return }
        let duration = self.duration
        guard clipEditing, !processedPreview, !ClipGain.active(selected?.clipGain).isEmpty || (selected?.edit?.changesAudio(duration: duration) ?? false) else { item.audioMix = nil; return }
        let points = ClipGain.previewPoints(selected?.clipGain, edit: selected?.edit, duration: duration)
        Task {
            guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first else { return }
            let parameters = AVMutableAudioMixInputParameters(track: track)
            for (index, point) in points.enumerated() {
                let time = CMTime(seconds: point.time, preferredTimescale: 48000)
                if index + 1 < points.count, points[index + 1].time > point.time {
                    let next = points[index + 1]
                    parameters.setVolumeRamp(fromStartVolume: Float(point.volume), toEndVolume: Float(next.volume),
                                             timeRange: CMTimeRange(start: time, end: CMTime(seconds: next.time, preferredTimescale: 48000)))
                } else { parameters.setVolume(Float(point.volume), at: time) }
            }
            let mix = AVMutableAudioMix(); mix.inputParameters = [parameters]
            if player.currentItem === item { item.audioMix = mix }
        }
    }
    /// Measures the selected section's integrated loudness with all current edits applied.
    func measureSelectedSection() {
        guard !measuringSection, let job = selected, let info = job.analysis?.info, let r = selectedRegions.first(where: { $0.id == selectedRegion }) else { return }
        measuringSection = true
        let source = job.source, regions = selectedRegions
        Task {
            defer { measuringSection = false }
            do {
                let value = try await offPool { try AudioEngine.sectionLoudness(source, info: info, start: r.start, end: r.end, regions: regions, token: Cancellation()) }
                if selectedRegions == regions { sectionLoudness[r.id] = value }
            } catch { self.error = error.localizedDescription }
        }
    }
    func addRegion(start: Double, end: Double) {
        guard let duration = selected?.analysis?.info.duration else { return }
        let region = GainRegion(start: snapped(min(start, end)), end: snapped(max(start, end))).normalized(duration: duration)
        // A new section replaces any overlapping ones, like drawing a new clip-gain range in Pro Tools.
        let kept = selectedRegions.filter { $0.end <= region.start || $0.start >= region.end }
        setRegions(kept + [region]); selectedRegion = region.id
    }
    func updateRegion(_ region: GainRegion) {
        var region = region
        if let old = selectedRegions.first(where: { $0.id == region.id }) {
            if old.start != region.start { region.start = snapped(region.start) }
            if old.end != region.end { region.end = snapped(region.end) }
        }
        setRegions(selectedRegions.map { $0.id == region.id ? region : $0 })
    }
    func nudgeSelectedRegion(by delta: Double) {
        guard var region = selectedRegions.first(where: { $0.id == selectedRegion }) else { return }
        region.gain += delta; updateRegion(region)
    }
    func deleteSelectedRegion() {
        guard let id = selectedRegion else { return }
        setRegions(selectedRegions.filter { $0.id != id }); selectedRegion = nil
    }
    func clearRegions() { setRegions([]); selectedRegion = nil }
    /// Marks the selected section as the one that sounds right. Only one reference per cue; its own gain is kept.
    func markSelectedAsReference() {
        guard let id = selectedRegion else { return }
        setRegions(selectedRegions.map { var r = $0; r.isReference = r.id == id ? !r.isReference : false; return r })
    }
    var referenceRegion: GainRegion? { selectedRegions.first { $0.isReference } }
    /// Sets the selected section's gain so its loudness matches the reference section, measured with FFmpeg on the source.
    func matchSelectedToReference() {
        guard !busy, !measuringSection, let job = selected, let info = job.analysis?.info,
              let reference = referenceRegion, let target = selectedRegions.first(where: { $0.id == selectedRegion }), target.id != reference.id else { return }
        measuringSection = true; status = "Measuring the two sections"
        let others = selectedRegions.filter { $0.id != target.id }
        let source = job.source, token = Cancellation()
        Task {
            defer { measuringSection = false }
            do {
                let (good, section) = try await offPool {
                    (try AudioEngine.sectionLoudness(source, info: info, start: reference.start, end: reference.end, regions: others, token: token),
                     try AudioEngine.sectionLoudness(source, info: info, start: target.start, end: target.end, regions: others, token: token))
                }
                guard let gain = ClipGain.matchGain(reference: good, section: section) else { throw cueError("One of the sections is silent, so it cannot be matched.") }
                var matched = target; matched.gain = gain; updateRegion(matched)
                status = "Matched: section was \(String(format: "%.1f", section)) LUFS, reference \(String(format: "%.1f", good)) LUFS → \(gain >= 0 ? "+" : "")\(String(format: "%.1f", gain)) dB"
            } catch { self.error = error.localizedDescription; status = "Sections not matched" }
        }
    }

    /// Opens the "Add as reference" sheet for the selected, measured cue.
    func beginAddingReference() {
        guard !busy, let job = selected, job.analysis != nil else { return }
        referenceDraftCategory = mode(for: selected); referenceDraftNote = ""; referenceDraft = job.id
    }
    /// Records the cue's source measurements in the installed library. The recording is hashed, never copied.
    func addReference() {
        guard !busy, let id = referenceDraft, let job = jobs.first(where: { $0.id == id }), let analysis = job.analysis else { return }
        let source = job.source, category = referenceDraftCategory, note = referenceDraftNote, folder = referenceFolder
        referenceDraft = nil; busy = true; status = "Adding \(source.lastPathComponent) to your references"
        Task {
            defer { busy = false }
            do {
                guard FileManager.default.isReadableFile(atPath: source.path) else { throw cueError("The original file is no longer at \(source.path). Add it again, then add it as a reference.") }
                let library = try await offPool {
                    let sha = try Updater.sha256(of: source)
                    let profile = try AudioEngine.loudnessProfile(source, duration: analysis.info.duration, token: Cancellation())
                    let record = ReferenceLibrary.record(for: analysis, name: source.lastPathComponent, sha256: sha, category: category, note: note, version: appShortVersion, profile: profile)
                    return try ReferenceLibrary.add(record, into: folder)
                }
                references = library
                status = "Added to \(category.rawValue) references · \(library.summary)"
            } catch { self.error = error.localizedDescription; status = "Reference not added" }
        }
    }
    func removeReference(_ record: ReferenceRecord) {
        guard !busy else { return }
        do { references = try ReferenceLibrary.remove(id: record.id, from: referenceFolder); status = "Removed \(record.name) from your references" }
        catch { self.error = error.localizedDescription }
    }
    func savePreset() {
        let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do { try settings.validate() } catch { self.error = error.localizedDescription; return }
        presets.append(SavedPreset(name: name, settings: settings)); presetName = ""; showSavePreset = false; persist()
    }
    func reveal() { if let url = selected?.exportURL ?? selected?.audioExportURL { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    func exportSelected(audioCopy: Bool = false) {
        guard !busy, let job = selected, let result = job.output else { return }
        guard let exportSource = audioCopy ? result.audioCompanion : result.url else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.levelledName(for: job.source, target: result.settings.target, ext: exportSource.pathExtension)
        try? FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        panel.directoryURL = outputFolder
        panel.allowedContentTypes = [UTType(filenameExtension: exportSource.pathExtension) ?? .data]
        guard panel.runModal() == .OK, let target = panel.url else { return }
        busy = true; status = "Exporting \(target.lastPathComponent)…"
        let sources = jobs.map(\.source)
        Task {
            do {
                try await offPool { try Self.atomicCopy(from: exportSource, to: target, sources: sources) }
                update(job.id) { if audioCopy { $0.audioExportURL = target } else { $0.exportURL = target } }; status = "Exported \(target.lastPathComponent)"; persist()
                NSWorkspace.shared.activateFileViewerSelecting([target])
            } catch { self.error = error.localizedDescription; status = "Export failed; cached output is available to retry" }
            busy = false
        }
    }
    /// A destination in folder that never overwrites an existing file: "Name.mov", then "Name 2.mov", "Name 3.mov"…
    // MARK: Output folder and naming (1.5)
    /// Everything CueLevel saves goes to Desktop › CueLevel unless another folder is chosen:
    ///   Levelled/  <original name>_LVL-18.<ext>   (a second copy becomes "…_LVL-18 2.wav"; nothing is overwritten)
    ///   Reports/   CueLevel Report <date>.csv and .html
    nonisolated static var defaultRoot: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/CueLevel", isDirectory: true) }
    nonisolated static var defaultLevelledFolder: URL { defaultRoot.appendingPathComponent("Levelled", isDirectory: true) }
    nonisolated static var defaultReportsFolder: URL { defaultRoot.appendingPathComponent("Reports", isDirectory: true) }
    var outputFolder: URL { quickFolder ?? Self.defaultLevelledFolder }
    var reportsFolder: URL { quickFolder ?? Self.defaultReportsFolder }
    var outputFolderDisplay: String { quickFolder.map(\.lastPathComponent) ?? "Desktop › CueLevel › Levelled" }
    nonisolated static func levelledName(for source: URL, target: Double, ext: String) -> String {
        let t = target == target.rounded() ? String(format: "%.0f", target) : String(format: "%.1f", target)
        return source.deletingPathExtension().lastPathComponent + "_LVL" + t + (ext.isEmpty ? "" : "." + ext)
    }
    func useDefaultOutputFolder() { quickFolder = nil; persist(); status = "Saving to \(outputFolderDisplay)" }
    func revealOutputFolder() {
        try? FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([outputFolder])
    }
    nonisolated static func uniqueDestination(in folder: URL, name: String) -> URL {
        var destination = folder.appendingPathComponent(name); var n = 2
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        while FileManager.default.fileExists(atPath: destination.path) { destination = folder.appendingPathComponent("\(stem) \(n)" + (ext.isEmpty ? "" : ".\(ext)")); n += 1 }
        return destination
    }
    /// Turns Quick Level on (choosing an output folder if needed) with lossless gain-only settings at -18 LUFS / -1 dBTP.
    func setQuickLevel(_ on: Bool) {
        guard on else { quickLevel = false; status = "Quick Level off"; persist(); return }
        settings.format = .lossless; settings.target = Self.quickTarget; settings.peak = Self.quickCeiling
        quickLevel = true; persist()
        status = "Level on drop is on. Dropped files are levelled losslessly into \(outputFolderDisplay)."
    }
    func chooseQuickFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "Choose where Quick Level saves levelled copies. Originals are never changed."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        quickFolder = folder; persist()
    }
    /// The settings one cue is processed with: the batch settings, or the cue's reference recommendation when enabled.
    nonisolated static func settingsForCue(_ base: ProcessingSettings, analysis: Analysis, library: ReferenceLibrary, recommend: Bool) -> ProcessingSettings {
        guard recommend, base.format != .lossless, !library.isEmpty else { return base }
        return ReferenceCheck(cue: analysis.levels, mode: base.mode, library: library, settings: base).recommendedSettings(from: base) ?? base
    }
    func applyLoudnessPreset(_ preset: LoudnessPreset) { settings.target = preset.target; settings.peak = preset.peak; status = "Loudness set to \(preset.name)" }

    // MARK: Watch folder
    func chooseWatchFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to watch. New audio and video files saved into it are added to CueLevel automatically."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        if Self.sameFolder(folder, outputFolder) { error = "The watch folder must be different from the Quick Level output folder, or levelled files would be picked up again."; return }
        watchFolder = folder; if watching { startWatching() } else { persist() }
    }
    func setWatching(_ on: Bool) {
        if on { if watchFolder == nil { chooseWatchFolder() }; guard watchFolder != nil else { return }; startWatching() }
        else { watchTimer?.invalidate(); watchTimer = nil; watching = false; status = "Watch folder off"; persist() }
    }
    /// Files already in the folder when watching starts are left alone; only files that appear afterwards are added.
    func startWatching() {
        guard let watchFolder else { return }
        watchTimer?.invalidate()
        watchSeen = Dictionary(uniqueKeysWithValues: Self.mediaFiles(in: watchFolder).map { ($0.path, Self.fileSize($0)) })
        watchPending = [:]
        watching = true; persist()
        status = "Watching \(watchFolder.lastPathComponent) for new files"
        watchTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.scanWatchFolder() } }
    }
    /// Adds files that are new and whose size has stopped changing (finished copying or exporting).
    func scanWatchFolder() {
        guard watching, let watchFolder else { return }
        var ready: [URL] = []
        for file in Self.mediaFiles(in: watchFolder) where watchSeen[file.path] == nil {
            let size = Self.fileSize(file)
            if size > 0, watchPending[file.path] == size { ready.append(file); watchSeen[file.path] = size; watchPending[file.path] = nil }
            else { watchPending[file.path] = size }
        }
        if !ready.isEmpty { add(ready.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) }
    }
    nonisolated static func mediaFiles(in folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter { mediaExtensions.contains($0.pathExtension.lowercased()) && ((try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false) }
    }
    nonisolated static func fileSize(_ url: URL) -> Int64 { ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0 }
    nonisolated static func sameFolder(_ a: URL, _ b: URL) -> Bool { a.standardizedFileURL.resolvingSymlinksInPath() == b.standardizedFileURL.resolvingSymlinksInPath() }

    // MARK: Show report
    /// One row per processed cue, for the show file: levels before/after, gain, shortfall, limiting and every note.
    nonisolated static func showReportRows(_ jobs: [CueJob]) -> [[String]] {
        func f(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "" }
        var rows = [["Cue", "Saved as", "Duration", "Type", "Mode", "Output", "Source LUFS", "Source dBTP", "Source LRA", "Output LUFS", "Output dBTP", "Gain dB", "Below target dB", "Limited dB", "Status", "Notes", "Edits", "Markers"]]
        for job in jobs {
            guard let analysis = job.analysis else { continue }
            let out = job.output
            let gain = out?.gainApplied ?? out.map { $0.levels.integrated - analysis.levels.integrated }
            var notes = analysis.sourceFindings + (out?.warnings ?? [])
            var seen = Set<String>(); notes = notes.filter { seen.insert($0).inserted }
            rows.append([job.source.lastPathComponent, job.exportURL?.lastPathComponent ?? "", clockText(analysis.info.duration),
                         analysis.info.isVideo ? "Video" : "Audio", out?.settings.mode.rawValue ?? "", out?.settings.format.rawValue ?? "",
                         f(analysis.levels.integrated), f(analysis.levels.truePeak), f(analysis.levels.loudnessRange),
                         f(out?.levels.integrated), f(out?.levels.truePeak), f(gain), f(out?.shortfall), f(out?.limiting),
                         job.alreadyGood != nil ? "No change needed" : job.status.rawValue, notes.joined(separator: " | "), editSummary(job, duration: analysis.info.duration),
                         (job.edit?.markers ?? []).map { "\($0.name) @ \(clockText($0.time))" }.joined(separator: " | ")])
        }
        return rows
    }
    nonisolated static func editSummary(_ job: CueJob, duration: Double) -> String {
        var parts: [String] = []
        if let e = job.edit?.normalized(duration: duration) {
            if e.isTrimmed(duration: duration) { parts.append("trimmed \(clockText(e.inPoint))–\(clockText(e.end(duration: duration)))") }
            if e.hasFades { parts.append("fades \(Int(e.fadeIn * 1000))/\(Int(e.fadeOut * 1000)) ms \(e.fadeShape.rawValue.lowercased())") }
        }
        let sections = ClipGain.active(job.clipGain)
        let muted = sections.filter { $0.muted == true }.count, auto = sections.filter { $0.isAuto == true && $0.muted != true }.count
        let manual = sections.count - muted - auto
        if auto > 0 { parts.append("\(auto) evened") }
        if manual > 0 { parts.append("\(manual) clip gain") }
        if muted > 0 { parts.append("\(muted) muted") }
        return parts.joined(separator: ", ")
    }
    nonisolated static func showReportCSV(_ jobs: [CueJob]) -> String {
        showReportRows(jobs).map { row in row.map { cell in
            cell.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) ? "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : cell
        }.joined(separator: ",") }.joined(separator: "\n") + "\n"
    }
    nonisolated static func showReportHTML(_ jobs: [CueJob], title: String, date: Date = Date()) -> String {
        func esc(_ t: String) -> String { t.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
        let rows = showReportRows(jobs)
        let header = rows.first.map { "<tr>" + $0.map { "<th>\(esc($0))</th>" }.joined() + "</tr>" } ?? ""
        let body = rows.dropFirst().map { "<tr>" + $0.map { "<td>\(esc($0))</td>" }.joined() + "</tr>" }.joined(separator: "\n")
        let stamp = DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(esc(title))</title><style>
        body{font:13px -apple-system,Helvetica,sans-serif;margin:32px;color:#1b1f24}h1{font-size:20px;margin:0 0 4px}p{color:#5b6470;margin:0 0 18px}
        table{border-collapse:collapse;width:100%}th,td{border-bottom:1px solid #dde1e6;padding:6px 8px;text-align:left;vertical-align:top}
        th{font-size:11px;text-transform:uppercase;letter-spacing:.04em;color:#5b6470}td:nth-child(n+7):nth-child(-n+14){font-variant-numeric:tabular-nums;text-align:right}
        @media print{body{margin:12mm}}</style></head><body><h1>\(esc(title))</h1>
        <p>CueLevel \(esc(appShortVersion)) · \(esc(stamp)) · \(rows.count - 1) cue\(rows.count == 2 ? "" : "s")</p>
        <table>\(header)
        \(body)</table></body></html>
        """
    }
    /// Quick Level writes/refreshes "CueLevel Report.csv" and ".html" in its output folder after each batch.
    func writeShowReport(into folder: URL, dated: Bool = false) {
        let processed = jobs.filter { $0.output != nil }
        guard !processed.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
            let stem = dated ? "CueLevel Report \(formatter.string(from: Date()))" : "CueLevel Report"
            try Data(Self.showReportCSV(processed).utf8).write(to: folder.appendingPathComponent(stem + ".csv"), options: .atomic)
            try Data(Self.showReportHTML(processed, title: "CueLevel show report").utf8).write(to: folder.appendingPathComponent(stem + ".html"), options: .atomic)
        } catch { status = "Levelled files saved; the show report could not be written: \(error.localizedDescription)" }
    }
    func exportShowReport() {
        let processed = jobs.filter { $0.analysis != nil }
        guard !processed.isEmpty else { error = "Analyse or process some cues first."; return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "CueLevel Report.csv"; panel.allowedContentTypes = [.commaSeparatedText]
        panel.message = "A printable HTML copy is saved alongside the CSV."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(Self.showReportCSV(processed).utf8).write(to: url, options: .atomic)
            let html = url.deletingPathExtension().appendingPathExtension("html")
            try Data(Self.showReportHTML(processed, title: "CueLevel show report").utf8).write(to: html, options: .atomic)
            status = "Show report saved"; NSWorkspace.shared.activateFileViewerSelecting([url, html])
        } catch { self.error = error.localizedDescription }
    }
    nonisolated static func atomicCopy(from source: URL, to target: URL, sources: [URL], allowReplace: Bool = true) throws {
        let resolved = target.standardizedFileURL.resolvingSymlinksInPath()
        guard !sources.contains(where: { $0.standardizedFileURL.resolvingSymlinksInPath() == resolved }) else { throw cueError("This destination is a source file in the queue. Choose another filename to preserve it.") }
        let temp = target.deletingLastPathComponent().appendingPathComponent(".CueLevel-\(UUID().uuidString).\(target.pathExtension)")
        do {
            try FileManager.default.copyItem(at: source, to: temp)
            if FileManager.default.fileExists(atPath: target.path) {
                guard allowReplace else { throw cueError("A file appeared at the export destination. Choose another folder or retry.") }
                _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
            }
            else { try FileManager.default.moveItem(at: temp, to: target) }
        } catch { try? FileManager.default.removeItem(at: temp); throw error }
    }
    func exportAll() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.message = "Export processed cues. Existing filenames will be kept; numbered copies will be created."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let snapshot = jobs; let sources = jobs.map(\.source)
        busy = true
        Task {
        var successes = 0; var errors: [String] = []
        for job in snapshot {
            guard let result = job.output else { continue }
            for file in [result.url] + (result.audioCompanion.map { [$0] } ?? []) {
                var destination = folder.appendingPathComponent(file.lastPathComponent); var n = 2
                while FileManager.default.fileExists(atPath: destination.path) { destination = folder.appendingPathComponent(file.deletingPathExtension().lastPathComponent + " \(n)." + file.pathExtension); n += 1 }
                status = "Exporting \(destination.lastPathComponent)…"
                let target = destination
                do {
                    try await offPool { try Self.atomicCopy(from: file, to: target, sources: sources, allowReplace: false) }
                    update(job.id) { if file == result.url { $0.exportURL = target } else { $0.audioExportURL = target } }; successes += 1
                } catch { errors.append("\(file.lastPathComponent): \(error.localizedDescription)") }
            }
        }
        status = "Exported \(successes) file\(successes == 1 ? "" : "s")"; persist()
        if !errors.isEmpty { error = errors.joined(separator: "\n") }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
        busy = false
        }
    }
    func saveReport() {
        guard let job = selected, let analysis = job.analysis, let output = job.output else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = job.source.deletingPathExtension().lastPathComponent + "_CueLevel-report.json"; panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let report = ExportReport(source: job.source.lastPathComponent, output: job.exportURL?.lastPathComponent ?? output.url.lastPathComponent, before: analysis.levels, after: output.levels, settings: output.settings, notes: output.warnings, date: output.created, audioCompanion: job.audioExportURL?.lastPathComponent ?? output.audioCompanion?.lastPathComponent, companionLevels: output.companionLevels, finalGainMode: output.finalGainMode, referenceCheck: referenceCheck(for: job, settings: output.settings)?.summaryLines)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(report).write(to: url, options: .atomic)
                status = "Measurement report saved"
            } catch { self.error = error.localizedDescription }
        }
    }
    func shutdown() { token?.cancel(); player.pause(); persist() }
}
