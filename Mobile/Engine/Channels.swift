import Foundation
import AVFoundation

// What each channel of a source is (left, right, centre, LFE, surround…), so CueLevel can keep a surround mix as
// surround: measure it the way ITU-R BS.1770 defines (surround channels weighted 1.41, LFE left out, as FFmpeg's
// ebur128 does) and write the levelled copy with the same channels in a layout WAV and MOV players understand.

struct ChannelMap: Sendable, Equatable {
    /// Core Audio labels of the decoded channels, in decoded order.
    var labels: [AudioChannelLabel]
    var count: Int { labels.count }

    static let mono = ChannelMap(labels: [kAudioChannelLabel_Mono])
    static let stereo = ChannelMap(labels: [kAudioChannelLabel_Left, kAudioChannelLabel_Right])

    /// BS.1770 channel weights.
    var weights: [Double] {
        labels.map { label in
            switch label {
            case kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LFE2:
                return 0
            case kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround, kAudioChannelLabel_CenterSurround,
                 kAudioChannelLabel_LeftSurroundDirect, kAudioChannelLabel_RightSurroundDirect,
                 kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight,
                 kAudioChannelLabel_TopBackLeft, kAudioChannelLabel_TopBackCenter, kAudioChannelLabel_TopBackRight:
                return 1.41
            default:
                return 1
            }
        }
    }

    /// Short names of the channels, for the editor's lanes ("L", "R", "C", "LFE", "Ls", "Rs").
    var shortNames: [String] {
        labels.enumerated().map { i, label in
            switch label {
            case kAudioChannelLabel_Mono: return "Mono"
            case kAudioChannelLabel_Left: return "L"
            case kAudioChannelLabel_Right: return "R"
            case kAudioChannelLabel_Center: return "C"
            case kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LFE2: return "LFE"
            case kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RearSurroundLeft: return "Ls"
            case kAudioChannelLabel_RightSurround, kAudioChannelLabel_RearSurroundRight: return "Rs"
            case kAudioChannelLabel_LeftSurroundDirect: return "Lss"
            case kAudioChannelLabel_RightSurroundDirect: return "Rss"
            case kAudioChannelLabel_CenterSurround: return "Cs"
            case kAudioChannelLabel_LeftCenter: return "Lc"
            case kAudioChannelLabel_RightCenter: return "Rc"
            default: return "\(i + 1)"
            }
        }
    }
    /// Short name for the layout ("5.1", "7.1", "6 channels").
    var name: String {
        let lfe = labels.contains(kAudioChannelLabel_LFEScreen) || labels.contains(kAudioChannelLabel_LFE2)
        switch count {
        case 1: return "mono"
        case 2: return "stereo"
        default:
            let main = count - (lfe ? 1 : 0)
            return lfe ? "\(main).1" : (main == 4 ? "quad" : "\(count) channels")
        }
    }

    /// The labels the usual WAV channel order gives a file with no layout information (FFmpeg's defaults).
    static func standard(_ n: Int) -> ChannelMap {
        let L = kAudioChannelLabel_Left, R = kAudioChannelLabel_Right, C = kAudioChannelLabel_Center, LFE = kAudioChannelLabel_LFEScreen
        let Ls = kAudioChannelLabel_LeftSurround, Rs = kAudioChannelLabel_RightSurround, Cs = kAudioChannelLabel_CenterSurround
        let Lsd = kAudioChannelLabel_LeftSurroundDirect, Rsd = kAudioChannelLabel_RightSurroundDirect
        switch n {
        case 1: return .mono
        case 2: return .stereo
        case 3: return ChannelMap(labels: [L, R, C])
        case 4: return ChannelMap(labels: [L, R, Ls, Rs])
        case 5: return ChannelMap(labels: [L, R, C, Lsd, Rsd])
        case 6: return ChannelMap(labels: [L, R, C, LFE, Ls, Rs])
        case 7: return ChannelMap(labels: [L, R, C, LFE, Cs, Lsd, Rsd])
        case 8: return ChannelMap(labels: [L, R, C, LFE, Ls, Rs, Lsd, Rsd])
        default: return ChannelMap(labels: (0..<n).map { kAudioChannelLabel_Discrete | AudioChannelLabel($0) })
        }
    }

    /// Reads the layout of a format description; falls back to the codec's own order (AAC keeps centre first) or the
    /// standard WAV order when it has none or it doesn't fit.
    static func of(_ format: CMAudioFormatDescription, channels n: Int) -> ChannelMap {
        if n == 1 { return .mono }
        if let labelled = labelled(format, channels: n) { return labelled }
        if let tag = codecDefault(format, channels: n), let labels = labels(tag: tag), labels.count == n { return ChannelMap(labels: labels) }
        return standard(n)
    }
    /// The labels the format description itself gives, when they name real speaker positions.
    static func labelled(_ format: CMAudioFormatDescription, channels n: Int) -> ChannelMap? {
        var size = 0
        guard let layout = CMAudioFormatDescriptionGetChannelLayout(format, sizeOut: &size), size >= MemoryLayout<AudioChannelLayout>.size,
              let labels = labels(of: layout), labels.count == n, labels.contains(where: { $0 >= 1 && $0 <= 18 }) else { return nil }
        return ChannelMap(labels: labels)
    }
    /// Compressed formats store surround in their own fixed order when the file has no layout of its own. AAC's is
    /// centre first (C L R Ls Rs LFE for 5.1).
    static func codecDefault(_ format: CMAudioFormatDescription, channels n: Int) -> AudioChannelLayoutTag? {
        guard n > 2, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return nil }
        switch asbd.mFormatID {
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD:
            switch n {
            case 3: return kAudioChannelLayoutTag_AAC_3_0
            case 4: return kAudioChannelLayoutTag_AAC_4_0
            case 5: return kAudioChannelLayoutTag_AAC_5_0
            case 6: return kAudioChannelLayoutTag_AAC_5_1
            case 7: return kAudioChannelLayoutTag_AAC_6_1
            case 8: return kAudioChannelLayoutTag_AAC_7_1
            default: return nil
            }
        default: return nil
        }
    }
    static func labels(tag: AudioChannelLayoutTag) -> [AudioChannelLabel]? {
        var layout = AudioChannelLayout(); layout.mChannelLayoutTag = tag
        return labels(of: &layout)
    }
    static func tagData(_ tag: AudioChannelLayoutTag) -> Data {
        var layout = AudioChannelLayout(); layout.mChannelLayoutTag = tag
        return Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
    }

    /// The raw layout of a format description, to pass on to the decoder and writer unchanged.
    static func layoutData(_ format: CMAudioFormatDescription) -> Data? {
        var size = 0
        guard let layout = CMAudioFormatDescriptionGetChannelLayout(format, sizeOut: &size), size >= MemoryLayout<AudioChannelLayout>.size else { return nil }
        return Data(bytes: layout, count: size)
    }

    /// Channel labels of any AudioChannelLayout (descriptions, a bitmap or a layout tag).
    static func labels(of layout: UnsafePointer<AudioChannelLayout>) -> [AudioChannelLabel]? {
        let tag = layout.pointee.mChannelLayoutTag
        if tag == kAudioChannelLayoutTag_UseChannelDescriptions { return descriptions(layout) }
        var property: AudioFormatPropertyID, specifier: UInt32
        if tag == kAudioChannelLayoutTag_UseChannelBitmap {
            property = kAudioFormatProperty_ChannelLayoutForBitmap; specifier = layout.pointee.mChannelBitmap.rawValue
        } else {
            property = kAudioFormatProperty_ChannelLayoutForTag; specifier = tag
        }
        var size: UInt32 = 0
        guard AudioFormatGetPropertyInfo(property, UInt32(MemoryLayout<UInt32>.size), &specifier, &size) == noErr, size > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioFormatGetProperty(property, UInt32(MemoryLayout<UInt32>.size), &specifier, &size, raw) == noErr else { return nil }
        return descriptions(raw.assumingMemoryBound(to: AudioChannelLayout.self))
    }
    private static func descriptions(_ layout: UnsafePointer<AudioChannelLayout>) -> [AudioChannelLabel] {
        let n = Int(layout.pointee.mNumberChannelDescriptions)
        guard n > 0, let offset = MemoryLayout<AudioChannelLayout>.offset(of: \AudioChannelLayout.mChannelDescriptions) else { return [] }
        let first = UnsafeRawPointer(layout).advanced(by: offset).assumingMemoryBound(to: AudioChannelDescription.self)
        return (0..<n).map { first[$0].mChannelLabel }
    }

    /// How to store these channels in a WAV file: WAV keeps its channels in a fixed order (front left, front right,
    /// centre, LFE, back left…), the same order as Core Audio's labels 1–18. Returns the order to write the decoded
    /// channels in and the layout to give the file; nil when the labels can't be expressed that way.
    func wavOrder() -> (order: [Int], layout: Data)? {
        guard count > 2 else { return nil }
        guard labels.allSatisfy({ $0 >= 1 && $0 <= 18 }), Set(labels).count == count else { return nil }
        let order = labels.indices.sorted { labels[$0] < labels[$1] }
        var bitmap: UInt32 = 0
        for label in labels { bitmap |= 1 << (label - 1) }
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelBitmap
        layout.mChannelBitmap = AudioChannelBitmap(rawValue: bitmap)
        return (order, Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size))
    }

    /// A layout listing these labels one by one (for MOV, which stores any layout as it is).
    func descriptionLayout() -> Data {
        let header = MemoryLayout<AudioChannelLayout>.offset(of: \AudioChannelLayout.mChannelDescriptions) ?? 12
        let size = header + MemoryLayout<AudioChannelDescription>.stride * max(1, count)
        var data = Data(count: size)
        data.withUnsafeMutableBytes { raw in
            let layout = raw.baseAddress!.assumingMemoryBound(to: AudioChannelLayout.self)
            layout.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
            layout.pointee.mChannelBitmap = AudioChannelBitmap(rawValue: 0)
            layout.pointee.mNumberChannelDescriptions = UInt32(count)
            let first = raw.baseAddress!.advanced(by: header).assumingMemoryBound(to: AudioChannelDescription.self)
            for (i, label) in labels.enumerated() {
                first[i] = AudioChannelDescription(mChannelLabel: label, mChannelFlags: AudioChannelFlags(rawValue: 0), mCoordinates: (0, 0, 0))
            }
        }
        return data
    }
}
