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
}
struct SavedPreset: Codable, Identifiable { var id = UUID(); var name: String; var settings: ProcessingSettings }
struct Session: Codable {
    var jobs: [CueJob]; var settings: ProcessingSettings; var presets: [SavedPreset]
    var quickLevel: Bool? = nil; var quickFolder: URL? = nil
    var watchFolder: URL? = nil; var watching: Bool? = nil; var autoRecommend: Bool? = nil
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
    @Published var selection: UUID? { didSet { loadPlayer() } }
    @Published var settings = ProcessingSettings() { didSet { persist() } }
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
    private var watchTimer: Timer?
    /// Files seen in the watch folder, with their last observed size, so only new, fully written files are added.
    private var watchSeen: [String: Int64] = [:]
    private var watchPending: [String: Int64] = [:]
    private var token: Cancellation?
    private var observation: Any?
    private var playerError: NSKeyValueObservation?
    let directory: URL
    var selected: CueJob? { jobs.first { $0.id == selection } }
    var completedCount: Int { jobs.filter { $0.output != nil }.count }
    var remainingCount: Int { jobs.filter { $0.output == nil }.count }
    var currentWaveform: [Float] { processedPreview ? (selected?.output?.waveform ?? []) : (selected?.analysis?.waveform ?? []) }
    var currentCurve: [Float] { processedPreview ? (selected?.output?.loudnessCurve ?? []) : (selected?.analysis?.loudnessCurve ?? []) }
    var duration: Double { selected?.analysis?.info.duration ?? 0 }
    var outputIsStale: Bool {
        guard let used = selected?.output?.settings else { return false }
        // Per-cue recommendations and Quick Level legitimately change some settings per cue; compare what the user controls.
        if autoRecommend || used.format == .lossless {
            return used.target != settings.target || used.peak != settings.peak || used.mode != settings.mode || (used.format == .lossless) != (settings.format == .lossless || quickLevel) || (used.format == .lossless && used.peakLimit != settings.peakLimit)
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
            quickFolder = saved.quickFolder; quickLevel = (saved.quickLevel ?? false) && saved.quickFolder != nil
            watchFolder = saved.watchFolder; autoRecommend = saved.autoRecommend ?? false
            if saved.watching == true, saved.watchFolder != nil { startWatching() }
            settings.cut = max(2, settings.cut)
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
        let snapshot = Session(jobs: jobs, settings: settings, presets: presets, quickLevel: quickLevel, quickFolder: quickFolder, watchFolder: watchFolder, watching: watching, autoRecommend: autoRecommend)
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: directory.appendingPathComponent("session.json"), options: .atomic) }
    }
    func changeMode(_ mode: ContentMode) { settings.setMode(mode) }
    func addFiles() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.message = "Add audio or video cues. Files stay on your Mac."
        if panel.runModal() == .OK { add(panel.urls) }
    }
    func add(_ urls: [URL]) {
        var added: [UUID] = []
        for url in urls where url.isFileURL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
            if jobs.contains(where: { $0.source.standardizedFileURL.resolvingSymlinksInPath() == normalized }) { continue }
            let job = CueJob(source: url); jobs.append(job); added.append(job.id)
        }
        guard let first = added.first else { return }
        selection = first; status = "Added \(added.count) file\(added.count == 1 ? "" : "s")"; persist()
        if quickLevel && quickFolder != nil {
            // Files dropped while a batch is running are picked up when it finishes.
            if !busy { run(ids: added, render: true) } else { status = "Added \(added.count) to Quick Level — waiting for the current batch" }
        } else if !busy { run(ids: added, render: false) }   // measure everything that was added, not only the selection
    }
    func update(_ id: UUID, _ edit: (inout CueJob) -> Void) { if let i = jobs.firstIndex(where: { $0.id == id }) { edit(&jobs[i]) } }
    func progress(_ id: UUID, _ value: Double, _ message: String) {
        guard busy, workingID == id else { return }
        update(id) { $0.progress = value; $0.message = message }; status = message
    }
    func analyze() { guard let id = selection else { return }; run(ids: [id], render: false) }
    func processSelected() { guard let id = selection else { return }; run(ids: [id], render: true) }
    func processQueue() { run(ids: jobs.filter { $0.output == nil }.map(\.id), render: true) }
    private func run(ids: [UUID], render: Bool) {
        guard !busy, !ids.isEmpty else { return }
        busy = true; player.pause(); playing = false
        let cancellation = Cancellation(); token = cancellation
        // Quick Level always renders the lossless gain-only path, whatever output type a preset selected.
        let quick = render && quickLevel && quickFolder != nil
        let options: ProcessingSettings = { var o = settings; if quick { o.format = .lossless }; return o }()
        Task {
            for id in ids {
                do { try cancellation.check() } catch { break }
                guard let current = jobs.first(where: { $0.id == id }) else { continue }
                workingID = id
                update(id) { $0.status = .working; $0.progress = 0; $0.message = "Starting" }; persist()
                do {
                    let analysis: Analysis
                    let attributes = try? FileManager.default.attributesOfItem(atPath: current.source.path)
                    let size = (attributes?[.size] as? NSNumber)?.int64Value
                    let modified = attributes?[.modificationDate] as? Date
                    if render, let existing = current.analysis, size == existing.info.byteCount, modified == existing.info.modified { analysis = existing }
                    else {
                        analysis = try await Task.detached {
                            try AudioEngine.analyze(current.source, token: cancellation) { value, message in
                                Task { @MainActor in self.progress(id, render ? value * 0.3 : value, message) }
                            }
                        }.value
                    }
                    update(id) { $0.analysis = analysis }
                    let cueOptions = Self.settingsForCue(options, analysis: analysis, library: references, recommend: autoRecommend && !quick)
                    if render {
                        let renderDirectory = directory.appendingPathComponent("Cache/\(id.uuidString)/\(UUID().uuidString)", isDirectory: true)
                        let result = try await Task.detached {
                            try AudioEngine.process(current.source, analysis: analysis, settings: cueOptions, directory: renderDirectory, token: cancellation) { value, message in
                                Task { @MainActor in self.progress(id, 0.3 + value * 0.7, message) }
                            }
                        }.value
                        if let previous = current.output { try? FileManager.default.removeItem(at: previous.url.deletingLastPathComponent()) }
                        update(id) { $0.output = result; $0.exportURL = nil; $0.audioExportURL = nil; $0.progress = 1; $0.status = result.warnings.isEmpty ? .ready : .review; $0.message = result.warnings.isEmpty ? "Ready to export" : "Review notes before export" }
                        if quickLevel, options.format == .lossless, let folder = quickFolder {
                            let destination = Self.uniqueDestination(in: folder, name: current.source.deletingPathExtension().lastPathComponent + "." + result.url.pathExtension)
                            let sources = jobs.map(\.source)
                            do {
                                try await Task.detached { try Self.atomicCopy(from: result.url, to: destination, sources: sources, allowReplace: false) }.value
                                update(id) { $0.exportURL = destination; $0.message = (result.warnings.isEmpty ? "Levelled → " : "Levelled with notes → ") + destination.lastPathComponent }
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
            status = stopped ? "Stopped. Remaining files stay in the queue." : quickLevel ? "Quick Level finished. Levelled files are in \(quickFolder?.lastPathComponent ?? "the output folder")." : "Finished. Review your results before export."
            persist()
            if quick, let folder = quickFolder { writeShowReport(into: folder) }
            if quickLevel, quickFolder != nil, !thisRunStopped {
                let waiting = jobs.filter { $0.output == nil && $0.status == .queued }.map(\.id)
                if !waiting.isEmpty { run(ids: waiting, render: true) }
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
        guard let job = selected else { player.replaceCurrentItem(with: nil); return }
        if processedPreview && job.output == nil { processedPreview = false }
        let url = processedPreview ? job.output!.url : job.source
        let item = AVPlayerItem(url: url); player.replaceCurrentItem(with: item); applyVolume()
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
                let reference = try await Task.detached {
                    let info = try AudioEngine.inspect(url, token: cancellation)
                    return try AudioEngine.measure(url, token: cancellation, duration: info.duration)
                }.value
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
        let basis = options ?? settings
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
    /// Opens the "Add as reference" sheet for the selected, measured cue.
    func beginAddingReference() {
        guard !busy, let job = selected, job.analysis != nil else { return }
        referenceDraftCategory = settings.mode; referenceDraftNote = ""; referenceDraft = job.id
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
                let library = try await Task.detached {
                    let sha = try Updater.sha256(of: source)
                    let record = ReferenceLibrary.record(for: analysis, name: source.lastPathComponent, sha256: sha, category: category, note: note, version: appShortVersion)
                    return try ReferenceLibrary.add(record, into: folder)
                }.value
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
        let panel = NSSavePanel(); panel.nameFieldStringValue = exportSource.lastPathComponent
        panel.allowedContentTypes = [UTType(filenameExtension: exportSource.pathExtension) ?? .data]
        guard panel.runModal() == .OK, let target = panel.url else { return }
        busy = true; status = "Exporting \(target.lastPathComponent)…"
        let sources = jobs.map(\.source)
        Task {
            do {
                try await Task.detached { try Self.atomicCopy(from: exportSource, to: target, sources: sources) }.value
                update(job.id) { if audioCopy { $0.audioExportURL = target } else { $0.exportURL = target } }; status = "Exported \(target.lastPathComponent)"; persist()
                NSWorkspace.shared.activateFileViewerSelecting([target])
            } catch { self.error = error.localizedDescription; status = "Export failed; cached output is available to retry" }
            busy = false
        }
    }
    /// A destination in folder that never overwrites an existing file: "Name.mov", then "Name 2.mov", "Name 3.mov"…
    nonisolated static func uniqueDestination(in folder: URL, name: String) -> URL {
        var destination = folder.appendingPathComponent(name); var n = 2
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        while FileManager.default.fileExists(atPath: destination.path) { destination = folder.appendingPathComponent("\(stem) \(n)" + (ext.isEmpty ? "" : ".\(ext)")); n += 1 }
        return destination
    }
    /// Turns Quick Level on (choosing an output folder if needed) with lossless gain-only settings at -18 LUFS / -1 dBTP.
    func setQuickLevel(_ on: Bool) {
        guard on else { quickLevel = false; status = "Quick Level off"; persist(); return }
        if quickFolder == nil { chooseQuickFolder() }
        guard quickFolder != nil else { return }
        settings.format = .lossless; settings.target = Self.quickTarget; settings.peak = Self.quickCeiling
        quickLevel = true; persist()
        status = "Quick Level on. Drop files to level them losslessly into \(quickFolder!.lastPathComponent)."
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
        if let quickFolder, Self.sameFolder(folder, quickFolder) { error = "The watch folder must be different from the Quick Level output folder, or levelled files would be picked up again."; return }
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
        var rows = [["Cue", "Saved as", "Duration", "Type", "Mode", "Output", "Source LUFS", "Source dBTP", "Source LRA", "Output LUFS", "Output dBTP", "Gain dB", "Below target dB", "Limited dB", "Status", "Notes"]]
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
                         job.status.rawValue, notes.joined(separator: " | ")])
        }
        return rows
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
    func writeShowReport(into folder: URL) {
        let processed = jobs.filter { $0.output != nil }
        guard !processed.isEmpty else { return }
        do {
            try Data(Self.showReportCSV(processed).utf8).write(to: folder.appendingPathComponent("CueLevel Report.csv"), options: .atomic)
            try Data(Self.showReportHTML(processed, title: "CueLevel show report").utf8).write(to: folder.appendingPathComponent("CueLevel Report.html"), options: .atomic)
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
                    try await Task.detached { try Self.atomicCopy(from: file, to: target, sources: sources, allowReplace: false) }.value
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
