import Foundation

// Reference library integration (0.7).
// The library holds measurements of user-approved reference recordings, grouped by confirmed content category.
// It is used to compare a cue's dynamics with approved material and to recommend a conservative processing approach.
// It never averages references into one target, never takes a peak ceiling from a reference,
// and never switches on cleanup or tone processing. Recordings are not copied; only measurement files are.

struct ReferenceLevels: Codable, Sendable, Equatable {
    var integratedLufs: Double
    var truePeakDbtp: Double
    var loudnessRangeLu: Double
}
struct ReferenceBand: Codable, Sendable, Equatable {
    var lowHz: Double
    var highHz: Double
    var powerFraction: Double
}
/// The shape of a cue's loudness over time (1.7): short-term (3 s) loudness percentiles, ignoring pauses.
/// `spread` (P90 − P10, in LU) says how much the level moves between quieter and louder stretches.
struct LoudnessProfile: Codable, Sendable, Equatable {
    var p10: Double
    var p50: Double
    var p90: Double
    var spread: Double
    init?(shortTerm values: [Double]) {
        let audible = values.filter { $0 > -69.9 }
        guard audible.count >= 10 else { return nil }
        let peakish = audible.sorted()[Int(Double(audible.count - 1) * 0.95)]
        let gated = audible.filter { $0 > peakish - 20 }.sorted()   // ignore pauses and fades
        guard gated.count >= 10 else { return nil }
        func pct(_ q: Double) -> Double { gated[Int((Double(gated.count - 1) * q).rounded())] }
        p10 = pct(0.1); p50 = pct(0.5); p90 = pct(0.9); spread = p90 - p10
    }
}

struct ReferenceRecord: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var sha256: String
    var category: String?
    var categoryStatus: String?
    var contentDescription: String?
    var durationSeconds: Double?
    var native: ReferenceLevels
    /// Measured after the same mono/stereo conversion CueLevel applies, so it compares directly with a cue's analysis.
    var cuelevelStereo: ReferenceLevels
    var samplePeakDbfs: Double?
    var crestFactorDb: Double?
    var uncentredStereoCorrelation: Double?
    var spectrum: [ReferenceBand]?
    var loudnessProfile: LoudnessProfile?
    var mode: ContentMode? { category.flatMap { ContentMode(rawValue: $0) } }
}
struct ReferenceLibraryFile: Codable, Sendable {
    var schemaVersion: Int
    var records: [ReferenceRecord]
}
struct ReferenceAnnotation: Codable, Sendable {
    var category: String?
    var categoryStatus: String?
    var contentDescription: String?
}
struct ReferenceAnnotationsFile: Codable, Sendable {
    var schemaVersion: Int?
    var bySourceSha256: [String: ReferenceAnnotation]
}
/// Observed spread of the approved references in one category. Ranges, not averages.
struct ReferenceSpan: Sendable, Equatable {
    var count: Int
    var loudness: ClosedRange<Double>
    var loudnessRange: ClosedRange<Double>
    var crest: ClosedRange<Double>?
    /// Short-term spread (P90 − P10) of the references that have a measured shape, and their quiet/loud stretches
    /// relative to their median (for the Good range band). nil until shapes are measured.
    var spread: ClosedRange<Double>? = nil
    var shape: ClosedRange<Double>? = nil
    var shapeCount = 0
}

struct ReferenceLibrary: Sendable {
    static let folderName = "Reference Library"
    static let libraryFile = "library.json"
    static let annotationsFile = "annotations.json"
    var records: [ReferenceRecord] = []
    var isEmpty: Bool { records.isEmpty }

    func references(for mode: ContentMode) -> [ReferenceRecord] { records.filter { $0.mode == mode } }

    func span(for mode: ContentMode) -> ReferenceSpan? {
        let group = references(for: mode)
        guard !group.isEmpty else { return nil }
        func spread(_ values: [Double]) -> ClosedRange<Double> { values.min()! ... values.max()! }
        let crests = group.compactMap(\.crestFactorDb)
        let profiles = group.compactMap(\.loudnessProfile)
        return ReferenceSpan(count: group.count,
                             loudness: spread(group.map(\.cuelevelStereo.integratedLufs)),
                             loudnessRange: spread(group.map(\.cuelevelStereo.loudnessRangeLu)),
                             crest: crests.isEmpty ? nil : spread(crests),
                             spread: profiles.isEmpty ? nil : spread(profiles.map(\.spread)),
                             shape: profiles.isEmpty ? nil : (profiles.map { $0.p10 - $0.p50 }.min()! ... profiles.map { $0.p90 - $0.p50 }.max()!),
                             shapeCount: profiles.count)
    }

    /// How tightly Even out works for this content: half the widest P10–P90 spread of your good references
    /// (so a cue is evened only where it moves more than good material does), between 1.5 and 4 dB. 2 dB without shapes.
    func evenOutTolerance(for mode: ContentMode) -> Double {
        guard let widest = span(for: mode)?.spread?.upperBound else { return ClipGain.evenOutTolerance }
        return (min(4, max(1.5, widest / 2)) * 2).rounded() / 2
    }
    var summary: String {
        guard !isEmpty else { return "No reference library loaded." }
        let parts = ContentMode.allCases.map { mode -> String in "\(references(for: mode).count) \(mode.label)" }
        return "\(records.count) approved reference\(records.count == 1 ? "" : "s") · " + parts.joined(separator: " · ")
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase; return decoder
    }

    /// Loads library.json and, when present, annotations.json (user-confirmed labels keyed by source SHA-256, which take precedence).
    /// Records without a recognised CueLevel category are ignored.
    static func load(from folder: URL) throws -> ReferenceLibrary {
        let libraryURL = folder.appendingPathComponent(libraryFile)
        guard FileManager.default.isReadableFile(atPath: libraryURL.path) else { throw cueError("No library.json was found. Choose the CueLevel Reference Library folder.") }
        let file: ReferenceLibraryFile
        do { file = try decoder().decode(ReferenceLibraryFile.self, from: Data(contentsOf: libraryURL)) }
        catch { throw cueError("library.json could not be read as a CueLevel reference library.") }
        guard file.schemaVersion == 1 else { throw cueError("This reference library uses an unsupported format version (\(file.schemaVersion)).") }
        var annotations: [String: ReferenceAnnotation] = [:]
        let annotationsURL = folder.appendingPathComponent(annotationsFile)
        if FileManager.default.fileExists(atPath: annotationsURL.path) {
            do { annotations = try decoder().decode(ReferenceAnnotationsFile.self, from: Data(contentsOf: annotationsURL)).bySourceSha256 }
            catch { throw cueError("annotations.json could not be read. Restore it from the reference library folder.") }
        }
        var records: [ReferenceRecord] = []
        for var record in file.records {
            if let note = annotations[record.sha256.lowercased()] ?? annotations[record.sha256] {
                if let category = note.category { record.category = category }
                if let status = note.categoryStatus { record.categoryStatus = status }
                if let description = note.contentDescription { record.contentDescription = description }
            }
            let levels = [record.cuelevelStereo.integratedLufs, record.cuelevelStereo.truePeakDbtp, record.cuelevelStereo.loudnessRangeLu]
            guard record.mode != nil, levels.allSatisfy(\.isFinite) else { continue }
            if let crest = record.crestFactorDb, !crest.isFinite { record.crestFactorDb = nil }
            records.append(record)
        }
        return ReferenceLibrary(records: records)
    }

    /// Validates a chosen library folder, then copies only its measurement files into CueLevel's own data folder.
    static func install(from source: URL, into destination: URL) throws -> ReferenceLibrary {
        let validated = try load(from: source)
        guard !validated.isEmpty else { throw cueError("The library contains no references with a confirmed Music, Music + voice or Voice category.") }
        if source.standardizedFileURL.resolvingSymlinksInPath() == destination.standardizedFileURL.resolvingSymlinksInPath() { return validated }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data(contentsOf: source.appendingPathComponent(libraryFile)).write(to: destination.appendingPathComponent(libraryFile), options: .atomic)
        let annotations = source.appendingPathComponent(annotationsFile)
        let installedAnnotations = destination.appendingPathComponent(annotationsFile)
        if FileManager.default.fileExists(atPath: annotations.path) { try Data(contentsOf: annotations).write(to: installedAnnotations, options: .atomic) }
        else { try? FileManager.default.removeItem(at: installedAnnotations) }
        return try load(from: destination)
    }
}

// MARK: Growing the catalogue (1.1)
// "Add as reference" records a finished, approved cue's measurements in the installed library. The recording itself is
// never copied; only its SHA-256, name and measurements are stored, exactly like the imported references.
extension ReferenceLibrary {
    /// One new library record (snake_case keys, the same shape as the imported library.json).
    static func record(for analysis: Analysis, name: String, sha256: String, category: ContentMode, note: String, version: String, date: Date = Date(), profile: LoudnessProfile? = nil) -> [String: Any] {
        let levels: [String: Any] = ["integrated_lufs": analysis.levels.integrated, "true_peak_dbtp": analysis.levels.truePeak, "loudness_range_lu": analysis.levels.loudnessRange]
        var record: [String: Any] = [
            "id": String(sha256.prefix(16)), "name": name, "sha256": sha256, "bytes": analysis.info.byteCount,
            "category": category.rawValue, "category_status": "confirmed in CueLevel",
            "duration_seconds": analysis.info.duration,
            // CueLevel measures after its own stereo conversion; the same values serve both fields.
            "native": levels, "cuelevel_stereo": levels,
            "added_utc": ISO8601DateFormatter().string(from: date), "added_by": "CueLevel \(version)"
        ]
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { record["content_description"] = trimmed }
        if let peak = analysis.levels.samplePeak { record["sample_peak_dbfs"] = peak }
        if let crest = analysis.levels.crestFactor { record["crest_factor_db"] = crest }
        if let correlation = analysis.stereo?.correlation { record["uncentred_stereo_correlation"] = correlation }
        if let profile { record["loudness_profile"] = profileJSON(profile) }
        return record
    }

    private static func readJSON(_ url: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { throw cueError("\(url.lastPathComponent) could not be read.") }
        return object
    }
    private static func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    /// Adds (or replaces, when the same recording is added again) a record in the installed library, keeping every
    /// other record and field untouched. A matching entry in annotations.json is updated too, because annotations win on load.
    static func add(_ record: [String: Any], into folder: URL) throws -> ReferenceLibrary {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let libraryURL = folder.appendingPathComponent(libraryFile)
        var library = try readJSON(libraryURL) ?? [
            "schema_version": 1, "created_utc": ISO8601DateFormatter().string(from: Date()),
            "purpose": "Private CueLevel calibration reference measurements. Not a trained model; no automatic EQ matching or global default change.",
            "records": [[String: Any]]()]
        guard (library["schema_version"] as? Int) == 1 else { throw cueError("The installed reference library uses an unsupported format version.") }
        guard let sha = (record["sha256"] as? String)?.lowercased() else { throw cueError("The reference has no checksum.") }
        var records = library["records"] as? [[String: Any]] ?? []
        records.removeAll { ($0["sha256"] as? String)?.lowercased() == sha }
        records.append(record)
        library["records"] = records
        try writeJSON(library, to: libraryURL)
        let annotationsURL = folder.appendingPathComponent(annotationsFile)
        if var annotations = try readJSON(annotationsURL), var bySha = annotations["by_source_sha256"] as? [String: Any] {
            for key in bySha.keys where key.lowercased() == sha {
                var note = bySha[key] as? [String: Any] ?? [:]
                note["category"] = record["category"]; note["category_status"] = record["category_status"]
                if let description = record["content_description"] { note["content_description"] = description }
                bySha[key] = note
            }
            annotations["by_source_sha256"] = bySha
            try writeJSON(annotations, to: annotationsURL)
        }
        return try load(from: folder)
    }

    static func profileJSON(_ p: LoudnessProfile) -> [String: Any] { ["p10": p.p10, "p50": p.p50, "p90": p.p90, "spread": p.spread] }
    /// Stores measured shapes for records matched by SHA-256 (other records and fields untouched).
    static func setProfiles(_ profiles: [String: LoudnessProfile], in folder: URL) throws -> ReferenceLibrary {
        let libraryURL = folder.appendingPathComponent(libraryFile)
        guard var library = try readJSON(libraryURL) else { throw cueError("Import your reference library first.") }
        var records = library["records"] as? [[String: Any]] ?? []
        for i in records.indices {
            if let sha = (records[i]["sha256"] as? String)?.lowercased(), let p = profiles[sha] { records[i]["loudness_profile"] = profileJSON(p) }
        }
        library["records"] = records
        try writeJSON(library, to: libraryURL)
        return try load(from: folder)
    }
    /// Removes one reference (by its record id) from the installed library. The recording itself is not touched.
    static func remove(id: String, from folder: URL) throws -> ReferenceLibrary {
        let libraryURL = folder.appendingPathComponent(libraryFile)
        guard var library = try readJSON(libraryURL) else { return ReferenceLibrary() }
        var records = library["records"] as? [[String: Any]] ?? []
        records.removeAll { ($0["id"] as? String) == id }
        library["records"] = records
        try writeJSON(library, to: libraryURL)
        return try load(from: folder)
    }
}

enum MasteringApproach: String, Codable, Sendable {
    case preserve = "Preserve"
    case gentle = "Gentle correction"
    var explanation: String {
        switch self {
        case .preserve: return "Dynamics already sit within the approved references. Leveling and compression stay off, so the output differs from the source only by one fixed gain change."
        case .gentle: return "Corrects only what falls outside the references. Dynamics stages run at a fixed working level so quiet and loud sources are treated alike."
        }
    }
}
struct ReferenceFinding: Hashable, Sendable {
    var text: String
    var needsAttention: Bool
}

/// Compares one analysed cue with the approved references of the selected content category.
struct ReferenceCheck: Sendable {
    /// A cue may be this much wider (LU) than the widest reference before leveling is suggested.
    static let rangeAllowance = 1.0
    /// A cue's peak-to-average ratio may exceed the most dynamic reference by this much (dB) before peak control is suggested.
    static let crestAllowance = 3.0
    /// Working level for level-dependent stages, chosen to suit the leveler's -18 dBFS RMS design target.
    static let workingLevel = -18.0
    /// Range target that keeps the final loudness stage a fixed gain change for normal material.
    static let openRange = 20.0

    let mode: ContentMode
    let span: ReferenceSpan?
    let cue: Measurement
    let target: Double
    let ceiling: Double
    /// True peak after a fixed gain change from the source loudness to the target.
    let fixedGainPeak: Double
    /// dB by which that fixed gain change would exceed the peak ceiling (0 when it fits).
    let headroomShortfall: Double
    private(set) var approach: MasteringApproach?
    private(set) var levelerStyle: LevelerStyle?
    private(set) var controlPeaks = false
    private(set) var findings: [ReferenceFinding] = []

    init(cue: Measurement, mode: ContentMode, library: ReferenceLibrary, settings: ProcessingSettings) {
        self.cue = cue; self.mode = mode
        target = settings.target; ceiling = settings.peak
        fixedGainPeak = cue.truePeak + (settings.target - cue.integrated)
        headroomShortfall = max(0, fixedGainPeak - settings.peak)
        let found = library.span(for: mode)
        span = found
        func f(_ value: Double) -> String { String(format: "%.1f", value) }
        func r(_ range: ClosedRange<Double>) -> String { "\(f(range.lowerBound)) to \(f(range.upperBound))" }
        guard let span = found else {
            findings.append(ReferenceFinding(text: "No approved \(mode.label) references are in the library, so no recommendation is made. Add an approved \(mode.label) cue, or choose the content type that fits this cue.", needsAttention: true))
            return
        }
        let widest = span.loudnessRange.upperBound
        let rangeExcess = cue.loudnessRange - (widest + Self.rangeAllowance)
        if rangeExcess > 0 {
            if mode == .music {
                findings.append(ReferenceFinding(text: "Loudness range \(f(cue.loudnessRange)) LU is wider than the Music references (\(r(span.loudnessRange)) LU). This may be intentional musical dynamics, so leveling is not recommended automatically. Listen through quiet and loud passages.", needsAttention: true))
            } else {
                levelerStyle = rangeExcess > 3 ? .balanced : .gentle
                findings.append(ReferenceFinding(text: "Loudness range \(f(cue.loudnessRange)) LU is wider than the \(mode.label) references (\(r(span.loudnessRange)) LU). \(levelerStyle!.rawValue) automatic leveling is suggested.", needsAttention: true))
            }
        } else {
            findings.append(ReferenceFinding(text: "Loudness range \(f(cue.loudnessRange)) LU is consistent with the \(mode.label) references (\(r(span.loudnessRange)) LU).", needsAttention: false))
        }
        if let crest = cue.crestFactor, let crests = span.crest {
            if crest > crests.upperBound + Self.crestAllowance {
                controlPeaks = true
                findings.append(ReferenceFinding(text: "Peaks stand \(f(crest)) dB above the average level, more than the references (\(r(crests)) dB). Peak compression is suggested; very short spikes may still need a limiter.", needsAttention: true))
            } else if crest < crests.lowerBound - Self.crestAllowance {
                findings.append(ReferenceFinding(text: "Peak-to-average ratio \(f(crest)) dB is lower than the references (\(r(crests)) dB). The cue may already be limited; further compression is not recommended.", needsAttention: false))
            } else {
                findings.append(ReferenceFinding(text: "Peak-to-average ratio \(f(crest)) dB is within the reference spread (\(r(crests)) dB).", needsAttention: false))
            }
        } else if cue.crestFactor == nil {
            findings.append(ReferenceFinding(text: "Analyse this cue again to measure its peak-to-average ratio. The recommendation currently uses loudness range only.", needsAttention: false))
        }
        findings.append(ReferenceFinding(text: "Source loudness \(f(cue.integrated)) LUFS. The references span \(r(span.loudness)) LUFS and are not averaged; output level comes from your \(f(settings.target)) LUFS target.", needsAttention: false))
        if headroomShortfall > 0.05 {
            findings.append(ReferenceFinding(text: "A fixed gain change to \(f(settings.target)) LUFS would put the true peak at \(f(fixedGainPeak)) dBTP, \(f(headroomShortfall)) dB over the \(f(settings.peak)) dBTP ceiling. The final stage would switch to dynamic loudness control unless peaks are reduced or the target is lowered.", needsAttention: true))
        }
        if cue.truePeak >= 0 {
            findings.append(ReferenceFinding(text: "The source reaches full scale. Listen for existing distortion; leveling and loudness changes cannot remove it.", needsAttention: true))
        }
        approach = (levelerStyle == nil && !controlPeaks) ? .preserve : .gentle
    }

    /// Settings that follow the recommendation. Only dynamics stages change: target, ceiling, output format,
    /// content type, cleanup and tone controls are kept exactly as they are.
    func recommendedSettings(from current: ProcessingSettings) -> ProcessingSettings? {
        guard let approach else { return nil }
        var next = current
        var leveling = current.levelerOptions
        if approach == .gentle, let levelerStyle { leveling.apply(levelerStyle); leveling.enabled = true } else { leveling.enabled = false }
        next.levelerOptions = leveling
        next.compression = approach == .gentle && controlPeaks
        if next.compression {
            var defaults = ProcessingSettings(); defaults.setMode(mode)
            next.ratio = min(current.ratio, defaults.ratio)
        }
        next.range = Self.openRange
        next.workingLevel = Self.workingLevel
        return next
    }

    static func describeChanges(from old: ProcessingSettings, to new: ProcessingSettings) -> [String] {
        func onOff(_ value: Bool) -> String { value ? "On" : "Off" }
        func f(_ value: Double) -> String { String(format: "%.1f", value) }
        var changes: [String] = []
        let a = old.levelerOptions, b = new.levelerOptions
        if a.enabled != b.enabled || (b.enabled && (a.style != b.style || a.maximumLift != b.maximumLift || a.response != b.response)) {
            changes.append("Automatic leveler: \(a.enabled ? a.style.rawValue : "Off") → \(b.enabled ? "\(b.style.rawValue) (\(f(b.maximumLift)) dB max lift)" : "Off")")
        }
        if old.compression != new.compression { changes.append("Peak compression: \(onOff(old.compression)) → \(onOff(new.compression))") }
        else if new.compression && old.ratio != new.ratio { changes.append("Compression ratio: \(f(old.ratio)):1 → \(f(new.ratio)):1") }
        if old.range != new.range { changes.append("Range target: \(f(old.range)) → \(f(new.range)) LU, so the final stage stays a fixed gain change") }
        if old.workingLevel != new.workingLevel {
            changes.append("Dynamics working level: \(old.workingLevel.map { "\(f($0)) LUFS" } ?? "Off (source level)") → \(new.workingLevel.map { "\(f($0)) LUFS" } ?? "Off")")
        }
        return changes
    }

    /// Plain-text lines for reports.
    var summaryLines: [String] {
        var lines = ["Reference check · \(mode.label) · \(span?.count ?? 0) reference\(span?.count == 1 ? "" : "s") · \(approach?.rawValue ?? "No recommendation")"]
        lines += findings.map(\.text)
        return lines
    }
}
