import Foundation
import AVFoundation

// Reads the first audio track of any file AVFoundation can open (WAV, AIFF, CAF, MP3, AAC/M4A, ALAC, FLAC, MOV, MP4, M4V)
// as stereo 32-bit float at its own sample rate. Mono becomes dual mono at −3 dB and surround is downmixed to stereo,
// matching what CueLevel's FFmpeg engine measures on the Mac (aformat=channel_layouts=stereo).

struct OpenedMedia {
    var asset: AVURLAsset
    var audioTrack: AVAssetTrack
    var info: MediaInfo
    /// Channels in the decoded stream before the stereo conversion.
    var sourceChannels: Int
    var sampleRate: Double
    /// True when the source's PCM is floating point (the lossless output then stays float).
    var isFloat: Bool
}

enum MediaReader {
    static func open(_ url: URL) async throws -> OpenedMedia {
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw cueError("Source file unavailable. Add the file again.") }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        if bytes == 0 { throw cueError("This file is empty (0 bytes). It may not have finished copying.") }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let audio: [AVAssetTrack], video: [AVAssetTrack], text: [AVAssetTrack]
        let duration: CMTime
        do {
            audio = try await asset.loadTracks(withMediaType: .audio)
            video = try await asset.loadTracks(withMediaType: .video)
            text = (try? await asset.loadTracks(withMediaType: .text)) ?? []
            duration = try await asset.load(.duration)
        } catch {
            throw cueError("CueLevel can't read this file. It may be damaged, incomplete, or not audio or video.")
        }
        guard let track = audio.first else {
            if video.isEmpty { throw cueError("CueLevel can't read this file. It may be damaged, incomplete, or not audio or video.") }
            throw cueError("This file has no audio track, so there's nothing to level.")
        }
        guard let format = try await track.load(.formatDescriptions).first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else {
            throw cueError("The audio channel layout cannot be read. Export a mono, stereo or standard surround mix first.")
        }
        let channels = Int(asbd.mChannelsPerFrame)
        guard channels > 0, asbd.mSampleRate > 0 else { throw cueError("The audio channel layout cannot be read. Export a mono, stereo or standard surround mix first.") }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { throw cueError("The file has no playable duration.") }
        let codec = codecName(asbd)
        let layout = channels == 1 ? "mono" : channels == 2 ? "stereo" : "\(channels) channels"
        var videoCodec: String? = nil
        if let v = video.first, let f = try await v.load(.formatDescriptions).first {
            let fourCC = CMFormatDescriptionGetMediaSubType(f)
            videoCodec = videoCodecName(fourCC)
        }
        let info = MediaInfo(duration: seconds, isVideo: !video.isEmpty,
                             audioDescription: "\(codec), \(Int(asbd.mSampleRate)) Hz, \(layout)", channels: channels, byteCount: bytes,
                             modified: (attributes?[.modificationDate] as? Date) ?? .distantPast, hasOtherStreams: !text.isEmpty,
                             videoCodec: videoCodec, audioStreams: audio.count, sampleRate: Int(asbd.mSampleRate))
        let isFloat = asbd.mFormatID == kAudioFormatLinearPCM && (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        return OpenedMedia(asset: asset, audioTrack: track, info: info, sourceChannels: channels, sampleRate: asbd.mSampleRate, isFloat: isFloat)
    }

    static func codecName(_ d: AudioStreamBasicDescription) -> String {
        switch d.mFormatID {
        case kAudioFormatLinearPCM:
            let float = (d.mFormatFlags & kAudioFormatFlagIsFloat) != 0, big = (d.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0
            return float ? "pcm_f\(d.mBitsPerChannel)\(big ? "be" : "le")" : "pcm_s\(d.mBitsPerChannel)\(big ? "be" : "le")"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD: return "aac"
        case kAudioFormatMPEGLayer3: return "mp3"
        case kAudioFormatAppleLossless: return "alac"
        case kAudioFormatFLAC: return "flac"
        case kAudioFormatAC3: return "ac3"
        case kAudioFormatEnhancedAC3: return "eac3"
        case kAudioFormatOpus: return "opus"
        default: return fourCC(d.mFormatID)
        }
    }
    static func videoCodecName(_ code: FourCharCode) -> String {
        switch fourCC(code) {
        case "avc1", "avc3": return "h264"
        case "hvc1", "hev1": return "hevc"
        case "apcn", "apch", "apcs", "apco", "ap4h", "ap4x": return "prores"
        case "mp4v": return "mpeg4"
        case "jpeg", "mjpa": return "mjpeg"
        default: return fourCC(code)
        }
    }
    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF), UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "audio"
    }

    /// Output settings that decode the track to interleaved 32-bit float. Surround is folded to stereo by AVFoundation;
    /// mono and stereo stay as they are (mono is converted below at −3 dB per side).
    static func decodeSettings(sourceChannels: Int) -> [String: Any] {
        var s: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        if sourceChannels > 2 {
            s[AVNumberOfChannelsKey] = 2
            var layout = AudioChannelLayout(); layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            s[AVChannelLayoutKey] = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        }
        return s
    }

    /// Splits one decoded sample buffer into stereo left/right arrays.
    static func stereo(from buffer: CMSampleBuffer) -> (left: [Float], right: [Float])? {
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              let block = CMSampleBufferGetDataBuffer(buffer) else { return nil }
        let frames = CMSampleBufferGetNumSamples(buffer)
        let channels = Int(asbd.mChannelsPerFrame)
        guard frames > 0, channels > 0 else { return ([], []) }
        var length = 0; var pointer: UnsafeMutablePointer<CChar>?
        var contiguous = block
        if !CMBlockBufferIsRangeContiguous(block, atOffset: 0, length: 0) {
            var copy: CMBlockBuffer?
            CMBlockBufferCreateContiguous(allocator: nil, sourceBuffer: block, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: 0, flags: 0, blockBufferOut: &copy)
            if let copy { contiguous = copy }
        }
        guard CMBlockBufferGetDataPointer(contiguous, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr, let pointer else { return nil }
        let available = min(frames, length / (4 * channels))
        var left = [Float](repeating: 0, count: available), right = [Float](repeating: 0, count: available)
        pointer.withMemoryRebound(to: Float.self, capacity: available * channels) { p in
            if channels == 1 {
                let k: Float = 0.70710677
                for i in 0..<available { let v = p[i] * k; left[i] = v; right[i] = v }
            } else {
                for i in 0..<available { left[i] = p[i * channels]; right[i] = p[i * channels + 1] }
            }
        }
        return (left, right)
    }

    /// Decodes the whole first audio track, calling `body` with each chunk (left, right, frames, presentation time).
    static func decode(_ media: OpenedMedia, isCancelled: () -> Bool = { false },
                       body: (UnsafePointer<Float>, UnsafePointer<Float>, Int, CMTime) throws -> Void) throws {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: media.asset) } catch { throw cueError("CueLevel can't read this file. It may be damaged, incomplete, or not audio or video.") }
        let output = AVAssetReaderTrackOutput(track: media.audioTrack, outputSettings: decodeSettings(sourceChannels: media.sourceChannels))
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw cueError("CueLevel can't decode this file's audio.") }
        reader.add(output)
        guard reader.startReading() else { throw cueError("CueLevel can't read this file. It may be damaged, incomplete, or not audio or video.") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        while let buffer = output.copyNextSampleBuffer() {
            if isCancelled() { throw CancellationError() }
            guard let pair = stereo(from: buffer), !pair.left.isEmpty else { continue }
            let l = pair.left, r = pair.right
            let time = CMSampleBufferGetPresentationTimeStamp(buffer)
            try l.withUnsafeBufferPointer { lp in try r.withUnsafeBufferPointer { rp in try body(lp.baseAddress!, rp.baseAddress!, l.count, time) } }
        }
        if reader.status == .failed { throw cueError("The audio could not be decoded completely. The file may be damaged.") }
    }
}
