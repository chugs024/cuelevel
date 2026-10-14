import Foundation
import AVFoundation

// Reads the first audio track of any file AVFoundation can open (WAV, AIFF, CAF, MP3, AAC/M4A, ALAC, FLAC, MOV, MP4, M4V)
// as 32-bit float at its own sample rate, one array per channel. The channels stay as they are in the source: mono stays
// mono and surround stays surround. Only when `foldSurround` is on is a surround source folded down to stereo.

struct OpenedMedia {
    var asset: AVURLAsset
    var audioTrack: AVAssetTrack
    var info: MediaInfo
    /// Channels in the source track.
    var sourceChannels: Int
    var sampleRate: Double
    /// True when the source's PCM is floating point (the lossless output then stays float).
    var isFloat: Bool
    /// The channels CueLevel decodes, measures and writes (the source's, or stereo when folded).
    var map: ChannelMap
    /// The source track's own channel layout, passed to the decoder so the channel order is known.
    var sourceLayout: Data?
    /// True when a surround source is folded down to stereo.
    var folded: Bool
    /// The source's layout in a word ("5.1", "stereo").
    var sourceName: String
    var channels: Int { map.count }
}

enum MediaReader {
    static func open(_ url: URL, foldSurround: Bool = false) async throws -> OpenedMedia {
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
        let layout = ChannelMap.of(format, channels: channels).name
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
        let fold = foldSurround && channels > 2
        let map = fold ? ChannelMap.stereo : ChannelMap.of(format, channels: channels)
        return OpenedMedia(asset: asset, audioTrack: track, info: info, sourceChannels: channels, sampleRate: asbd.mSampleRate, isFloat: isFloat,
                           map: map, sourceLayout: sourceLayout(format, channels: channels), folded: fold, sourceName: layout)
    }

    /// The layout to decode with: the file's own, or the codec's standard one when the file names none (so the
    /// decoder's channel order is the one CueLevel assumes).
    static func sourceLayout(_ format: CMAudioFormatDescription, channels n: Int) -> Data? {
        guard n > 2 else { return ChannelMap.layoutData(format) }
        if ChannelMap.labelled(format, channels: n) != nil { return ChannelMap.layoutData(format) }
        if let tag = ChannelMap.codecDefault(format, channels: n) { return ChannelMap.tagData(tag) }
        return nil
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

    /// Output settings that decode the track to interleaved 32-bit float, keeping the source's channels and their order
    /// (or folding surround to stereo when asked).
    static func decodeSettings(_ media: OpenedMedia) -> [String: Any] {
        var s: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        if media.folded {
            s[AVNumberOfChannelsKey] = 2
            var layout = AudioChannelLayout(); layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            s[AVChannelLayoutKey] = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        } else if media.sourceChannels > 2, let layout = media.sourceLayout {
            s[AVNumberOfChannelsKey] = media.sourceChannels
            s[AVChannelLayoutKey] = layout
        }
        return s
    }

    /// Splits one decoded, interleaved sample buffer into one array per channel.
    static func planar(from buffer: CMSampleBuffer) -> [[Float]]? {
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              let block = CMSampleBufferGetDataBuffer(buffer) else { return nil }
        let frames = CMSampleBufferGetNumSamples(buffer)
        let channels = Int(asbd.mChannelsPerFrame)
        guard frames > 0, channels > 0 else { return Array(repeating: [], count: max(1, channels)) }
        var length = 0; var pointer: UnsafeMutablePointer<CChar>?
        var contiguous = block
        if !CMBlockBufferIsRangeContiguous(block, atOffset: 0, length: 0) {
            var copy: CMBlockBuffer?
            CMBlockBufferCreateContiguous(allocator: nil, sourceBuffer: block, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: 0, flags: 0, blockBufferOut: &copy)
            if let copy { contiguous = copy }
        }
        guard CMBlockBufferGetDataPointer(contiguous, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr, let pointer else { return nil }
        let available = min(frames, length / (4 * channels))
        var out = [[Float]](repeating: [Float](repeating: 0, count: available), count: channels)
        pointer.withMemoryRebound(to: Float.self, capacity: available * channels) { p in
            for c in 0..<channels {
                out[c].withUnsafeMutableBufferPointer { dst in
                    for i in 0..<available { dst[i] = p[i * channels + c] }
                }
            }
        }
        return out
    }

    /// Decodes the whole first audio track, calling `body` with each chunk (one array per channel, presentation time).
    /// `range` (2.1) reads only part of the file, e.g. the part of the waveform on screen.
    static func decode(_ media: OpenedMedia, range: CMTimeRange? = nil, isCancelled: () -> Bool = { false },
                       body: ([[Float]], CMTime) throws -> Void) throws {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: media.asset) } catch { throw cueError("CueLevel can't read this file. It may be damaged, incomplete, or not audio or video.") }
        if let range { reader.timeRange = range }
        let output = AVAssetReaderTrackOutput(track: media.audioTrack, outputSettings: decodeSettings(media))
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw cueError("CueLevel can't decode this file's audio.") }
        reader.add(output)
        guard reader.startReading() else { throw cueError("CueLevel can't read this file. It may be damaged, incomplete, or not audio or video.") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        while let buffer = output.copyNextSampleBuffer() {
            if isCancelled() { throw CancellationError() }
            guard let chunk = planar(from: buffer), let first = chunk.first, !first.isEmpty else { continue }
            guard chunk.count == media.channels else { throw cueError("CueLevel couldn't keep this file's \(media.map.name) channels apart. Turn on Fold surround to stereo in Settings, or export the mix again.") }
            try body(chunk, CMSampleBufferGetPresentationTimeStamp(buffer))
        }
        if reader.status == .failed { throw cueError("The audio could not be decoded completely. The file may be damaged.") }
    }
}
