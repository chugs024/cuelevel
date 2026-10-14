import SwiftUI
import UIKit
import UniformTypeIdentifiers
import AVFoundation

// The show on this device: cues, their measurements and results, and the work queue.
// Originals are copied into the app (the files you picked are never changed). Levelled copies go to
// Files › On My iPhone › CueLevel › Levelled, where any app can pick them up.

enum MobileState: String, Codable, Sendable { case queued, measuring, measured, levelling, levelled, alreadyGood, needsLook, failed }

struct MobileCue: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    /// File name inside the Originals folder.
    var fileName: String
    var added = Date()
    var mode: ContentMode? = nil
    var state = MobileState.queued
    var message = ""
    var analysis: Analysis? = nil
    var output: ProcessedAudio? = nil
    /// Levelled file name inside the Levelled folder (paths change between app updates, names don't).
    var outputName: String? = nil
    var alreadyGood: String? = nil
    var evenOutSkipped: Bool? = nil
    var autoRegions: [GainRegion]? = nil
    var edit = CueEdit()
    /// Plan switches for this cue (nil = the show default).
    var trim: Bool? = nil
    var evenOut: Bool? = nil

    static func == (a: MobileCue, b: MobileCue) -> Bool {
        a.id == b.id && a.state == b.state && a.message == b.message && a.mode == b.mode && a.outputName == b.outputName
            && a.trim == b.trim && a.evenOut == b.evenOut && a.edit == b.edit && a.analysis?.levels.integrated == b.analysis?.levels.integrated
    }

    var stage: CueStage {
        switch state {
        case .queued: return .waiting
        case .measuring, .levelling: return .working
        case .measured: return .measured
        case .levelled: return .levelled
        case .alreadyGood: return .alreadyGood
        case .needsLook: return .needsLook
        case .failed: return .failed
        }
    }
    var isVideo: Bool { analysis?.info.isVideo ?? ["mov", "mp4", "m4v"].contains((fileName as NSString).pathExtension.lowercased()) }
}

struct MobileSettings: Codable, Equatable, Sendable {
    var target = -18.0
    var peak = -1.0
    var defaultMode = ContentMode.voice
    var evenOut = true
    var trimSilence = true
    var levelOnAdd = false
}

/// Stop flag the engine checks from its own threads.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock(); private var flag = false
    var value: Bool { get { lock.lock(); defer { lock.unlock() }; return flag } set { lock.lock(); flag = newValue; lock.unlock() } }
}

private struct Session: Codable { var version = 1; var cues: [MobileCue]; var settings: MobileSettings }

@MainActor
final class CueStore: ObservableObject {
    @Published var cues: [MobileCue] = []
    @Published var settings = MobileSettings() { didSet { if settings != oldValue { save() } } }
    @Published var selection: UUID?
    @Published var progress: [UUID: Double] = [:]
    @Published var progressLabel: [UUID: String] = [:]
    @Published var error: String?
    @Published var status = ""
    let library: ReferenceLibrary
    private var worker: Task<Void, Never>?
    private var levelQueue: [UUID] = []
    private let cancel = CancelFlag()
    private var cancelled: Bool { get { cancel.value } set { cancel.value = newValue } }

    static let support: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }()
    static let originals: URL = { let u = support.appendingPathComponent("Originals", isDirectory: true); try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u }()
    static let details: URL = { let u = support.appendingPathComponent("Even out", isDirectory: true); try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u }()
    static let levelled: URL = {
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Levelled", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u
    }()
    static var sessionURL: URL { support.appendingPathComponent("session.json") }

    init() {
        if let folder = Bundle.main.url(forResource: "Reference Library", withExtension: nil), let lib = try? ReferenceLibrary.load(from: folder) { library = lib }
        else { library = ReferenceLibrary() }
        load()
    }

    // MARK: Persistence
    private func load() {
        guard let data = try? Data(contentsOf: Self.sessionURL), let s = try? JSONDecoder().decode(Session.self, from: data) else { return }
        settings = s.settings
        cues = s.cues.map { c in
            var c = c
            // Work interrupted by the app closing starts again.
            if c.state == .measuring { c.state = .queued }
            if c.state == .levelling { c.state = c.analysis == nil ? .queued : .measured }
            if let name = c.outputName, c.output != nil { c.output?.url = Self.levelled.appendingPathComponent(name) }
            if let name = c.outputName, !FileManager.default.fileExists(atPath: Self.levelled.appendingPathComponent(name).path) {
                c.output = nil; c.outputName = nil; if c.stage.isDone || c.state == .needsLook { c.state = .measured }
            }
            return c
        }
        if cues.contains(where: { $0.state == .queued }) { startWorker() }
    }
    func save() {
        let snapshot = Session(cues: cues, settings: settings), url = Self.sessionURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }

    // MARK: Queries
    func cue(_ id: UUID?) -> MobileCue? { cues.first { $0.id == id } }
    func originalURL(_ cue: MobileCue) -> URL { Self.originals.appendingPathComponent(cue.fileName) }
    func outputURL(_ cue: MobileCue) -> URL? { cue.outputName.map { Self.levelled.appendingPathComponent($0) } }
    func mode(for cue: MobileCue) -> ContentMode { cue.mode ?? settings.defaultMode }
    var busy: Bool { worker != nil }
    var levelledURLs: [URL] { cues.compactMap { outputURL($0) }.filter { FileManager.default.fileExists(atPath: $0.path) } }
    var levelAllIDs: [UUID] { cues.filter { $0.output == nil && $0.state != .failed && $0.state != .levelling }.map(\.id) }

    func processing(for cue: MobileCue) -> ProcessingSettings {
        var s = ProcessingSettings()
        s.setMode(mode(for: cue))
        s.target = settings.target; s.peak = settings.peak; s.format = .lossless
        return s
    }
    func plan(for cue: MobileCue) -> CuePlan? {
        guard let analysis = cue.analysis else { return nil }
        return CuePlan.make(analysis: analysis, settings: processing(for: cue), evenOut: cue.evenOut ?? settings.evenOut,
                            autoTrim: cue.trim ?? settings.trimSilence, edit: cue.edit, handEdits: false, library: library)
    }

    // MARK: Adding cues
    static let mediaExtensions: Set<String> = ["wav", "wave", "aif", "aiff", "aifc", "caf", "mp3", "m4a", "aac", "flac", "alac", "mov", "mp4", "m4v", "3gp"]

    func add(_ urls: [URL]) {
        var files: [URL] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
                let items = (FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
                for item in items.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
                where Self.mediaExtensions.contains(item.pathExtension.lowercased()) {
                    if let copy = copyIn(item) { files.append(copy) }
                }
            } else if let copy = copyIn(url) { files.append(copy) }
        }
        guard !files.isEmpty else { error = "No audio or video files were found there."; return }
        for file in files {
            // Originals sit in their own folder each (Originals/<tag>/<name>), so file names stay exactly as picked.
            let folder = file.deletingLastPathComponent().lastPathComponent
            cues.append(MobileCue(name: file.deletingPathExtension().lastPathComponent, fileName: folder + "/" + file.lastPathComponent))
        }
        status = "Added \(files.count) cue\(files.count == 1 ? "" : "s"). Measuring…"
        save(); startWorker()
    }
    /// Copies a picked file into the app so the original is never touched.
    private func copyIn(_ url: URL) -> URL? {
        let tag = String(UUID().uuidString.prefix(8))
        let folder = Self.originals.appendingPathComponent(tag, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(url.lastPathComponent)
        do {
            var copyError: Error?
            var coordinatorError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinatorError) { readURL in
                do { try FileManager.default.copyItem(at: readURL, to: destination) } catch { copyError = error }
            }
            if let e = copyError ?? coordinatorError { throw e }
            return destination
        } catch {
            self.error = "\(url.lastPathComponent) couldn't be added: \(error.localizedDescription)"
            return nil
        }
    }

    func remove(_ ids: Set<UUID>) {
        for c in cues where ids.contains(c.id) {
            try? FileManager.default.removeItem(at: originalURL(c))
            let folder = originalURL(c).deletingLastPathComponent()
            if folder != Self.originals { try? FileManager.default.removeItem(at: folder) }
            try? FileManager.default.removeItem(at: Self.details.appendingPathComponent(c.id.uuidString + ".json"))
        }
        cues.removeAll { ids.contains($0.id) }
        levelQueue.removeAll { ids.contains($0) }
        if let s = selection, ids.contains(s) { selection = cues.first?.id }
        if cues.isEmpty { status = "" }
        save()
    }
    func removeAll() { remove(Set(cues.map(\.id))) }

    // MARK: Editing the plan
    func update(_ id: UUID, _ change: (inout MobileCue) -> Void) {
        guard let i = cues.firstIndex(where: { $0.id == id }) else { return }
        change(&cues[i]); save()
    }
    func setMode(_ id: UUID, _ mode: ContentMode?) { update(id) { $0.mode = mode; $0.evenOutSkipped = nil } }
    func toggle(_ control: PlanSwitch, for id: UUID) {
        update(id) { c in
            switch control {
            case .trim: c.trim = !(c.trim ?? settings.trimSilence)
            case .evenOut: c.evenOut = !(c.evenOut ?? settings.evenOut)
            case .removeDC: c.edit.removeDC.toggle()
            case .flipPolarity: c.edit.polarity = c.edit.polarity == .none ? .right : .none
            }
        }
    }

    // MARK: Work queue
    func level(_ ids: [UUID]) {
        for id in ids where !levelQueue.contains(id) { levelQueue.append(id) }
        status = ids.count == 1 ? "Levelling…" : "Levelling \(ids.count) cues…"
        startWorker()
    }
    func levelAll() { level(levelAllIDs) }
    func stop() { cancelled = true; status = "Stopping…" }

    private func startWorker() {
        guard worker == nil else { return }
        cancelled = false
        worker = Task { [weak self] in
            await self?.runQueue()
            self?.worker = nil
            self?.objectWillChange.send()
        }
        objectWillChange.send()
    }

    private func runQueue() async {
        let background = UIApplication.shared.beginBackgroundTask(withName: "CueLevel") {}
        defer { UIApplication.shared.endBackgroundTask(background) }
        while !cancelled {
            if let next = cues.first(where: { $0.state == .queued }) {
                await measure(next.id)
                if settings.levelOnAdd, let c = cue(next.id), c.state == .measured { levelQueue.append(c.id) }
                continue
            }
            if let id = levelQueue.first {
                levelQueue.removeFirst()
                if let c = cue(id), c.analysis != nil, c.state != .levelling { await levelOne(id) }
                continue
            }
            break
        }
        if cancelled {
            for i in cues.indices where cues[i].state == .measuring || cues[i].state == .levelling { cues[i].state = cues[i].analysis == nil ? .queued : .measured }
            levelQueue.removeAll(); status = "Stopped."; save(); return
        }
        let done = cues.filter { $0.stage.isDone }.count, look = cues.filter { $0.stage.wantsAttention }.count
        status = cues.isEmpty ? "" : "\(done) of \(cues.count) cues done" + (look > 0 ? ", \(look) need a look." : ".")
        save()
    }

    private func measure(_ id: UUID) async {
        guard let c = cue(id) else { return }
        update(id) { $0.state = .measuring; $0.message = "" }
        progress[id] = 0; progressLabel[id] = "Measuring"
        let url = originalURL(c)
        let flag = cancel
        let check: @Sendable () -> Bool = { flag.value }
        do {
            let (analysis, detail) = try await Task.detached(priority: .userInitiated) {
                try await MobileEngine.analyze(url, isCancelled: { check() }, progress: { p in Task { @MainActor [weak self] in self?.progress[id] = p } })
            }.value
            if let data = try? JSONEncoder().encode(detail) { try? data.write(to: Self.details.appendingPathComponent(id.uuidString + ".json")) }
            update(id) { $0.analysis = analysis; $0.state = .measured; $0.message = "" }
        } catch is CancellationError {
            update(id) { $0.state = .queued }
        } catch {
            update(id) { $0.state = .failed; $0.message = error.localizedDescription }
        }
        progress[id] = nil; progressLabel[id] = nil
    }

    private func evenOutData(_ id: UUID) -> EvenOutData? {
        guard let data = try? Data(contentsOf: Self.details.appendingPathComponent(id.uuidString + ".json")) else { return nil }
        return try? JSONDecoder().decode(EvenOutData.self, from: data)
    }

    private func levelOne(_ id: UUID) async {
        guard let c = cue(id), let analysis = c.analysis else { return }
        update(id) { $0.state = .levelling; $0.message = "" }
        progress[id] = 0; progressLabel[id] = "Planning"
        var s = processing(for: c)
        let duration = analysis.info.duration
        let mode = mode(for: c)
        // Trim silence (video keeps its length; the head and tail are silenced instead).
        var edit = c.edit
        if c.trim ?? settings.trimSilence, let stats = analysis.stereo {
            let head = max(0, stats.headSilence - 0.1), tail = max(0, stats.tailSilence - 0.1)
            if head >= 0.3 || tail >= 0.3 { edit = CueEdit.trimmedToSound(stats, duration: duration, keeping: edit) }
        }
        // Even out, never for music.
        var regions: [GainRegion] = []
        var skipped = false
        if (c.evenOut ?? settings.evenOut) && mode != .music {
            var data = evenOutData(id)
            if data == nil { let source = originalURL(c); data = try? await Task.detached { try await MobileEngine.analyze(source).1 }.value }
            if let data {
                let plan = MobileEngine.evenOutPlan(data, duration: duration, tolerance: library.evenOutTolerance(for: mode), keeping: [], skipMusic: c.mode == nil)
                regions = plan.regions; skipped = plan.soundsLikeMusic
            }
        }
        s.clipGain = regions.isEmpty ? nil : regions
        s.edit = edit
        let good = cueAlreadyGoodReason(analysis: analysis, target: s.target, peak: s.peak, autoSections: regions.count,
                                        hasEdits: edit.changesAudio(duration: duration), library: library, mode: mode)
        let input = originalURL(c)
        let directory = Self.levelled
        if let old = outputURL(c) { try? FileManager.default.removeItem(at: old) }
        let flag = cancel
        let check: @Sendable () -> Bool = { flag.value }
        do {
            let result: ProcessedAudio
            if let good {
                result = try MobileEngine.unchangedCopy(input, analysis: analysis, settings: s, directory: directory)
                update(id) { $0.alreadyGood = good }
            } else {
                let settingsCopy = s
                result = try await Task.detached(priority: .userInitiated) {
                    try await MobileEngine.level(input, analysis: analysis, settings: settingsCopy, directory: directory, isCancelled: { check() },
                                                 progress: { p, label in Task { @MainActor [weak self] in self?.progress[id] = p; self?.progressLabel[id] = label } })
                }.value
                update(id) { $0.alreadyGood = nil }
            }
            // A result kept under the target only because of its peaks counts as levelled; any other note needs a look.
            let notes = result.warnings.filter { !$0.hasPrefix("Kept ") }
            update(id) {
                $0.output = result; $0.outputName = result.url.lastPathComponent
                $0.autoRegions = regions; $0.evenOutSkipped = skipped ? true : nil
                $0.state = good != nil ? .alreadyGood : (notes.isEmpty ? .levelled : .needsLook)
            }
        } catch is CancellationError {
            update(id) { $0.state = .measured }
        } catch {
            update(id) { $0.state = .failed; $0.message = error.localizedDescription }
        }
        progress[id] = nil; progressLabel[id] = nil
    }

    func clearLevelled() {
        for i in cues.indices {
            if let url = outputURL(cues[i]) { try? FileManager.default.removeItem(at: url) }
            cues[i].output = nil; cues[i].outputName = nil; cues[i].alreadyGood = nil
            if cues[i].analysis != nil && cues[i].state != .failed { cues[i].state = .measured }
        }
        save()
    }
}

extension MobileCue {
    /// The list's short label: what happened, in the words an operator uses.
    func stageText(target: Double) -> String {
        if state == .needsLook, let s = output?.shortfall, s > 0.05, (output?.warnings.filter { !$0.hasPrefix("Kept ") } ?? []).isEmpty { return "\(dbText(s, signed: false)) dB under" }
        if state == .levelled, let s = output?.shortfall, s > 0.05 { return "\(dbText(s, signed: false)) dB under" }
        if state == .failed, message.contains("silent") { return "Silent" }
        return stage.title
    }
    func stageTone(target: Double) -> LevelTone {
        switch stage {
        case .levelled: return (output?.shortfall ?? 0) > 0.05 ? .changed : .good
        case .alreadyGood: return .good
        case .needsLook: return .changed
        case .failed: return message.contains("silent") ? .neutral : .hot
        default: return .neutral
        }
    }
    /// Loudness shown in the list: after levelling when there is a result.
    var shownLoudness: Double? { output?.levels.integrated ?? analysis?.levels.integrated }
}
