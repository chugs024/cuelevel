import Foundation
import CryptoKit
import AppKit

// Software updates (1.1).
// CueLevel reads one small public file (appcast.json in the public cuelevel-updates repository). Nothing about the
// user's files or usage is sent. An update is installed only when the download matches the published SHA-256, is
// signed with CueLevel's Developer ID (team 327ABFB3W2) and passes Gatekeeper's notarisation check.

struct Appcast: Codable, Equatable, Sendable {
    var schema: Int?
    var version: String
    var build: Int
    var minimumSystemVersion: String?
    var published: String?
    var url: URL
    var sha256: String
    var size: Int64?
    var teamID: String?
    var notes: String?

    /// Lines of the release notes, without empty lines or list markers.
    var noteLines: [String] {
        (notes ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.hasPrefix("- ") || $0.hasPrefix("• ") || $0.hasPrefix("* ") ? String($0.dropFirst(2)) : $0 }
            .filter { !$0.isEmpty }
    }
    /// True when this release is newer than the running build and can run on this Mac.
    func isNewer(thanBuild current: Int) -> Bool {
        guard build > current else { return false }
        guard let minimum = minimumSystemVersion else { return true }
        let parts = minimum.split(separator: ".").compactMap { Int($0) }
        let required = OperatingSystemVersion(majorVersion: parts.first ?? 0, minorVersion: parts.count > 1 ? parts[1] : 0, patchVersion: parts.count > 2 ? parts[2] : 0)
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(required)
    }
    static func decode(_ data: Data) throws -> Appcast {
        let feed = try JSONDecoder().decode(Appcast.self, from: data)
        guard feed.url.scheme == "https", feed.sha256.count == 64, feed.build > 0 else { throw cueError("The update information is incomplete.") }
        return feed
    }
}

enum UpdateState: Equatable {
    case idle, checking, upToDate, available(Appcast), downloading(Double), installing, failed(String)
    /// Shown once on the first launch after an update: what changed in the version now running.
    case justUpdated(Appcast)
}

@MainActor final class Updater: ObservableObject {
    static let teamID = "327ABFB3W2"
    static let releaseBundleID = "local.halllevel.app"
    static let autoCheckKey = "CueLevelCheckForUpdates"
    static let lastCheckKey = "CueLevelLastUpdateCheck"
    static let skippedKey = "CueLevelSkippedBuild"
    static let lastRunBuildKey = "CueLevelLastRunBuild"

    @Published var state = UpdateState.idle {
        didSet {
            if case .available(let feed) = state { offered = feed }
            if case .justUpdated(let feed) = state { offered = feed }
        }
    }
    /// The release last offered, kept while it downloads and installs.
    @Published private(set) var offered: Appcast?
    @Published var showSheet = false
    @Published var autoCheck: Bool { didSet { UserDefaults.standard.set(autoCheck, forKey: Self.autoCheckKey) } }

    let feedURL: URL?
    let currentBuild: Int
    let currentVersion: String
    private var timer: Timer?
    private var download: URLSessionDownloadTask?
    private var progressObservation: NSKeyValueObservation?

    init(bundle: Bundle = .main) {
        feedURL = (bundle.object(forInfoDictionaryKey: "CueLevelUpdateFeed") as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        currentBuild = Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
        currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        UserDefaults.standard.register(defaults: [Self.autoCheckKey: true])
        autoCheck = UserDefaults.standard.bool(forKey: Self.autoCheckKey)
    }

    var available: Appcast? { if case .available(let feed) = state { return feed }; return nil }
    var isWorking: Bool { switch state { case .checking, .downloading, .installing: return true; default: return false } }
    var canCheck: Bool { feedURL != nil && !isWorking }

    /// On the first launch after an update, shows what's new; otherwise checks at every launch and every 4 hours
    /// while CueLevel stays open, and pops up "New version available" when there is one.
    func start() {
        guard feedURL != nil else { return }
        let lastRun = UserDefaults.standard.integer(forKey: Self.lastRunBuildKey)
        UserDefaults.standard.set(currentBuild, forKey: Self.lastRunBuildKey)
        if lastRun > 0 && lastRun < currentBuild { Task { await showWhatsNew() } }
        else if autoCheck { Task { await check(userInitiated: false) } }
        timer = Timer.scheduledTimer(withTimeInterval: 4 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in if let self, self.autoCheck { await self.check(userInitiated: false) } }
        }
    }

    func check(userInitiated: Bool) async {
        guard let feedURL, !isWorking else { return }
        if userInitiated { showSheet = true }
        state = .checking
        do {
            var request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue("CueLevel/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            if let http = response as? HTTPURLResponse, http.statusCode == 404 { state = .upToDate; return }   // nothing published yet
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw cueError("The update server did not respond. Try again later.") }
            let feed = try Appcast.decode(data)
            let skipped = UserDefaults.standard.integer(forKey: Self.skippedKey)
            if feed.isNewer(thanBuild: currentBuild) && (userInitiated || feed.build != skipped) {
                state = .available(feed); showSheet = true
            } else { state = .upToDate }
        } catch {
            state = userInitiated ? .failed(Self.describe(error)) : .idle
        }
    }

    /// Reads the feed and, when it describes the version now running, shows its notes once.
    func showWhatsNew() async {
        guard let feedURL, let (data, _) = try? await URLSession.shared.data(from: feedURL), let feed = try? Appcast.decode(data) else { return }
        if feed.build == currentBuild { state = .justUpdated(feed); showSheet = true }
        else if feed.isNewer(thanBuild: currentBuild) && autoCheck { state = .available(feed); showSheet = true }
    }

    func skip() {
        if let feed = offered { UserDefaults.standard.set(feed.build, forKey: Self.skippedKey) }
        state = .idle; showSheet = false
    }
    func later() { showSheet = false }
    func cancel() { download?.cancel(); download = nil; progressObservation = nil; state = .idle }

    /// Downloads, verifies and installs the update, then relaunches. `canQuit` is false while CueLevel is processing.
    func install(canQuit: Bool) {
        guard let feed = offered, !isWorking else { return }
        guard canQuit else { state = .failed("Finish or stop the current job, then install the update."); return }
        state = .downloading(0)
        let task = URLSession.shared.downloadTask(with: feed.url) { [weak self] location, response, error in
            // The temporary file is removed when this handler returns, so move it first.
            var kept: URL?
            if let location {
                let target = FileManager.default.temporaryDirectory.appendingPathComponent("CueLevel-\(feed.version)-\(UUID().uuidString).dmg")
                if (try? FileManager.default.moveItem(at: location, to: target)) != nil { kept = target }
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            Task { @MainActor in
                guard let self else { return }
                self.progressObservation = nil; self.download = nil
                if let error = error as? URLError, error.code == .cancelled { return }
                guard let dmg = kept, status == 200, error == nil else { self.state = .failed(error.map(Self.describe) ?? "The download failed (HTTP \(status))."); return }
                self.state = .installing
                do {
                    let destination = Self.installDestination()
                    let staged = try await Task.detached { try Self.verifyAndStage(dmg: dmg, feed: feed, destination: destination) }.value
                    try Self.relaunch(replacing: destination, with: staged, oldVersion: self.currentVersion)
                } catch {
                    try? FileManager.default.removeItem(at: dmg)
                    self.state = .failed(Self.describe(error))
                }
            }
        }
        progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in if case .downloading = self?.state { self?.state = .downloading(fraction) } }
        }
        download = task
        task.resume()
    }

    // MARK: Verification and installation

    /// Where the update goes: in place of this copy when it is the release app in a writable folder; otherwise
    /// /Applications/CueLevel.app. A development build ("CueLevel Dev") is left alone beside the release app.
    nonisolated static func installDestination(bundle: URL = Bundle.main.bundleURL) -> URL {
        let path = bundle.path
        let translocated = path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/")
        let isRelease = Bundle(url: bundle)?.bundleIdentifier == releaseBundleID
        if isRelease && !translocated && FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path) {
            return bundle.deletingLastPathComponent().appendingPathComponent("CueLevel.app")
        }
        return URL(fileURLWithPath: "/Applications/CueLevel.app")
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    nonisolated static func tool(_ path: String, _ arguments: [String], timeout: TimeInterval = 300) throws -> String {
        // Output goes to a temporary file, not a pipe: `hdiutil attach` leaves a helper process holding the pipe open,
        // so reading a pipe to its end would wait forever (the 1.1.0–1.2.0 "Checking the signature and installing" hang).
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("cuelevel-tool-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        process.standardOutput = handle; process.standardError = handle; process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw cueError("\(URL(fileURLWithPath: path).lastPathComponent) did not finish. Try the update again, or download it from the release page.")
        }
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        guard process.terminationStatus == 0 else { throw cueError("\(URL(fileURLWithPath: path).lastPathComponent) failed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))") }
        return text
    }

    /// Verifies the DMG and the app inside it, then copies the app next to its destination (same volume, so the swap is a rename).
    nonisolated static func verifyAndStage(dmg: URL, feed: Appcast, destination: URL) throws -> URL {
        defer { try? FileManager.default.removeItem(at: dmg) }
        guard try sha256(of: dmg) == feed.sha256.lowercased() else { throw cueError("The downloaded update does not match the published checksum, so it was not installed.") }
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("CueLevel-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try tool("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path])
        defer { _ = try? tool("/usr/bin/hdiutil", ["detach", "-force", mount.path]); try? FileManager.default.removeItem(at: mount) }
        let app = mount.appendingPathComponent("CueLevel.app")
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == releaseBundleID else { throw cueError("The update does not contain CueLevel.") }
        guard Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") == feed.build else { throw cueError("The update's version does not match the published information.") }
        let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
        do { try tool("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=\(requirement)", app.path]) }
        catch { throw cueError("The update is not signed by CueLevel's developer, so it was not installed.") }
        do { try tool("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path]) }
        catch { throw cueError("macOS Gatekeeper did not approve the update, so it was not installed.") }
        let folder = destination.deletingLastPathComponent()
        let staged = folder.appendingPathComponent(".CueLevel-update-\(UUID().uuidString).app")
        do { try tool("/usr/bin/ditto", [app.path, staged.path]) }
        catch { throw cueError("CueLevel could not write to \(folder.path). Download the update from the release page and drag it into Applications.") }
        return staged
    }

    /// Hands over to a small script that waits for CueLevel to quit, swaps the app (the old copy goes to the Trash) and reopens it.
    static func relaunch(replacing destination: URL, with staged: URL, oldVersion: String) throws {
        let trash = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first?.path ?? (NSHomeDirectory() + "/.Trash")
        let script = """
        #!/bin/zsh
        pid=\(ProcessInfo.processInfo.processIdentifier)
        while kill -0 $pid 2>/dev/null; do sleep 0.3; done
        dest=\(shellQuote(destination.path)); staged=\(shellQuote(staged.path))
        if [[ -e "$dest" ]]; then
          old=\(shellQuote(trash))/"CueLevel \(oldVersion) $(date +%H%M%S).app"
          mv "$dest" "$old" || { rm -rf "$staged"; open "$dest"; exit 1; }
        fi
        mv "$staged" "$dest" && xattr -dr com.apple.quarantine "$dest" 2>/dev/null
        open "$dest"
        rm -f "$0"
        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cuelevel-update-\(UUID().uuidString).sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "nohup /bin/zsh \(shellQuote(file.path)) >/dev/null 2>&1 &"]
        try process.run(); process.waitUntilExit()
        NSApp.terminate(nil)
    }

    nonisolated static func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    nonisolated static func describe(_ error: Error) -> String {
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost: return "This Mac is offline. Connect to the internet and try again."
            case .timedOut: return "The update server took too long to respond. Try again later."
            default: return "The update could not be downloaded (\(url.code.rawValue))."
            }
        }
        return error.localizedDescription
    }
}
