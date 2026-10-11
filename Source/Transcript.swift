import Foundation
import Speech

// Transcript (1.6): on-device speech recognition with Apple's Speech framework. Nothing leaves the Mac: recognition is
// required to run on the device, and CueLevel refuses to transcribe if the Mac can only do it on Apple's servers.
// The first audio track is converted to 16 kHz mono WAV and recognised in 50-second pieces; word times are joined back.

enum Transcriber {
    static let chunkSeconds = 50.0

    /// Asks for speech recognition permission (macOS shows its own prompt once).
    static func authorize() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }

    static func transcribe(_ input: URL, duration: Double, locale: Locale = .current,
                           progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [TranscriptWord] {
        guard await authorize() else {
            throw cueError("Speech recognition is turned off for CueLevel. Turn it on in System Settings › Privacy & Security › Speech Recognition.")
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
            throw cueError("Speech recognition isn't available for this language.")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw cueError("On-device speech recognition isn't installed for \(recognizer.locale.identifier). Turn on Dictation in System Settings › Keyboard, let it download, then try again. CueLevel never sends audio to a server.")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CueLevel-transcript-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try AudioEngine.run(["-i", input.path, "-map", "0:a:0", "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le",
                             "-f", "segment", "-segment_time", String(Int(chunkSeconds)), "-reset_timestamps", "1",
                             folder.appendingPathComponent("part%04d.wav").path], token: Cancellation(), duration: duration)
        let parts = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var words: [TranscriptWord] = []
        for (index, part) in parts.enumerated() {
            let offset = Double(index) * chunkSeconds
            let request = SFSpeechURLRecognitionRequest(url: part)
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = false
            if #available(macOS 13, *) { request.addsPunctuation = true }
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            let segments: [SFTranscriptionSegment] = try await withCheckedThrowingContinuation { continuation in
                recognizer.recognitionTask(with: request) { result, error in
                    guard !once.done else { return }
                    if let result, result.isFinal { once.done = true; continuation.resume(returning: result.bestTranscription.segments); return }
                    if let error {
                        once.done = true
                        // "No speech detected" ends a silent piece; that is not a failure.
                        let nsError = error as NSError
                        if nsError.code == 1110 || nsError.code == 203 { continuation.resume(returning: []) } else { continuation.resume(throwing: error) }
                    }
                }
            }
            words += segments.map { TranscriptWord(text: $0.substring, start: offset + $0.timestamp, duration: $0.duration) }
            progress(Double(index + 1) / Double(max(1, parts.count)))
        }
        return words
    }
}
