import AVFoundation
import Foundation

enum VideoError: LocalizedError {
    case cannotOpen(String)
    case noVideo(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let name):
            "„\(name)“ kann macOS nicht öffnen. VideoHub bearbeitet MOV- und MP4-Videos, zum Beispiel vom iPhone."
        case .noVideo(let name):
            "„\(name)“ enthält kein Bild. Für reine Tondateien gibt es MusicHub."
        }
    }
}

/// An opened video: the asset, its video track and its main sound track, and what the editor needs
/// to know about them. Positions are ticks of the video track's time scale.
/// Unchecked: everything is a constant, and the tracks of a loaded file asset never change
/// (AVFoundation does not mark `AVAssetTrack` as Sendable).
final class VideoDocument: @unchecked Sendable {
    let url: URL
    let asset: AVURLAsset
    let videoTrack: AVAssetTrack
    /// The sound that plays with the picture. Newer iPhones add a second track for spatial audio;
    /// the enabled stereo track is the one players use.
    let audioTrack: AVAssetTrack?
    let timescale: CMTimeScale
    /// The source range with video.
    let bounds: Range<Int64>
    /// One frame at the nominal frame rate.
    let frameTicks: Int64
    let frameRate: Double
    /// Size as shown (rotation applied).
    let displaySize: CGSize
    let transform: CGAffineTransform
    let fileSize: Int64
    /// "HEVC · 1920 × 1080 · 30 fps · HDR (Dolby Vision)"
    let summary: String
    /// The codec of the picture (media subtype of its format).
    let codec: FourCharCode
    let audioSampleRate: Double
    let audioChannels: Int
    let audioIsAAC: Bool
    /// Where the main sound track lies in the asset.
    let audioTimeRange: CMTimeRange?

    var name: String { url.deletingPathExtension().lastPathComponent }
    var fileType: AVFileType { VideoDocument.fileType(for: url) }
    /// ProRes only fits in a MOV; H.264, HEVC and AV1 can be copied into an MP4 as well.
    var copiesIntoMP4: Bool { !VideoDocument.proRes.contains(codec) }
    var aspectRatio: CGFloat { displaySize.height > 0 ? displaySize.width / displaySize.height : 16.0 / 9 }
    var length: Int64 { bounds.upperBound - bounds.lowerBound }

    func time(_ ticks: Int64) -> CMTime { CMTime(value: ticks, timescale: timescale) }
    func ticks(_ time: CMTime) -> Int64 {
        guard time.isNumeric else { return 0 }
        return CMTimeConvertScale(time, timescale: timescale, method: .roundHalfAwayFromZero).value
    }
    func seconds(_ ticks: Int64) -> Double { Double(ticks) / Double(timescale) }
    func ticks(seconds: Double) -> Int64 { Int64((seconds * Double(timescale)).rounded()) }
    /// Audio frame (of the main sound track) at a source position.
    func audioFrame(_ ticks: Int64) -> Int64 { Int64((Double(ticks) * audioSampleRate / Double(timescale)).rounded()) }

    /// The nearest frame start (on the nominal frame grid of the video track).
    func snapped(_ ticks: Int64) -> Int64 {
        let offset = ticks - bounds.lowerBound
        let frames = (Double(offset) / Double(frameTicks)).rounded()
        return min(max(bounds.lowerBound + Int64(frames) * frameTicks, bounds.lowerBound), bounds.upperBound)
    }

    static func fileType(for url: URL) -> AVFileType {
        switch url.pathExtension.lowercased() {
        case "mp4": .mp4
        case "m4v": .m4v
        default: .mov
        }
    }

    private init(url: URL, asset: AVURLAsset, videoTrack: AVAssetTrack, audioTrack: AVAssetTrack?, timescale: CMTimeScale,
                 bounds: Range<Int64>, frameTicks: Int64, frameRate: Double, displaySize: CGSize, transform: CGAffineTransform,
                 fileSize: Int64, summary: String, codec: FourCharCode, audioSampleRate: Double, audioChannels: Int,
                 audioIsAAC: Bool, audioTimeRange: CMTimeRange?) {
        self.url = url
        self.asset = asset
        self.videoTrack = videoTrack
        self.audioTrack = audioTrack
        self.timescale = timescale
        self.bounds = bounds
        self.frameTicks = frameTicks
        self.frameRate = frameRate
        self.displaySize = displaySize
        self.transform = transform
        self.fileSize = fileSize
        self.summary = summary
        self.codec = codec
        self.audioSampleRate = audioSampleRate
        self.audioChannels = audioChannels
        self.audioIsAAC = audioIsAAC
        self.audioTimeRange = audioTimeRange
    }

    static func open(_ url: URL) async throws -> VideoDocument {
        let name = url.lastPathComponent
        // Precise timing: cuts and seeks land on the exact frame.
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let playable: Bool
        do {
            playable = try await asset.load(.isPlayable)
        } catch {
            throw VideoError.cannotOpen(name)
        }
        guard playable else { throw VideoError.cannotOpen(name) }
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw VideoError.noVideo(name) }

        let (naturalTimescale, timeRange, size, transform, nominalRate, minDuration, formats) = try await video.load(
            .naturalTimeScale, .timeRange, .naturalSize, .preferredTransform, .nominalFrameRate, .minFrameDuration, .formatDescriptions)
        let timescale = naturalTimescale > 0 ? naturalTimescale : 600
        func ticks(_ time: CMTime) -> Int64 {
            time.isNumeric ? CMTimeConvertScale(time, timescale: timescale, method: .roundHalfAwayFromZero).value : 0
        }
        // A broken file can report an empty, endless or backwards range.
        let start = ticks(timeRange.start), end = ticks(timeRange.end)
        guard end > start else { throw VideoError.noVideo(name) }
        let bounds = start..<end
        // Absurd rates from broken files would overflow the frame arithmetic below.
        let frameRate = Double(nominalRate.isFinite && nominalRate >= 1.0 / 3600 && nominalRate <= 10_000 ? nominalRate : 30)
        var frameTicks = max(1, Int64((Double(timescale) / frameRate).rounded()))
        if minDuration.isNumeric, minDuration.value > 0 {
            let fromMinimum = ticks(minDuration)
            // Variable frame rate (phones): the nominal rate is the average, the minimum duration the
            // fastest frame. Only an exact constant rate makes both agree.
            if abs(fromMinimum - frameTicks) <= 1, fromMinimum > 0 { frameTicks = fromMinimum }
        }
        let shown = CGRect(origin: .zero, size: size).applying(transform)
        let displaySize = CGSize(width: abs(shown.width).rounded(), height: abs(shown.height).rounded())

        let audio = try await mainAudioTrack(of: asset)
        var sampleRate = 48_000.0, channels = 2, isAAC = false
        if let audio, let format = try await audio.load(.formatDescriptions).first,
           let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
            sampleRate = (1...768_000).contains(description.mSampleRate) ? description.mSampleRate : sampleRate
            channels = Int(max(1, description.mChannelsPerFrame))
            isAAC = description.mFormatID == kAudioFormatMPEG4AAC
        }
        var audioTimeRange: CMTimeRange?
        if let audio { audioTimeRange = try await audio.load(.timeRange) }

        let size64 = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
        let summary = describe(formats.first, size: displaySize, frameRate: frameRate)
        return VideoDocument(url: url, asset: asset, videoTrack: video, audioTrack: audio, timescale: timescale, bounds: bounds,
                             frameTicks: frameTicks, frameRate: frameRate, displaySize: displaySize, transform: transform,
                             fileSize: size64, summary: summary, codec: formats.first.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0,
                             audioSampleRate: sampleRate, audioChannels: channels, audioIsAAC: isAAC, audioTimeRange: audioTimeRange)
    }

    /// The first enabled sound track that is not spatial audio (APAC), else the first one.
    private static func mainAudioTrack(of asset: AVURLAsset) async throws -> AVAssetTrack? {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        var fallback: AVAssetTrack?
        for track in tracks {
            let (enabled, formats) = try await track.load(.isEnabled, .formatDescriptions)
            let subtype = formats.first.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
            if fallback == nil { fallback = track }
            if enabled, subtype != fourCC("apac") { return track }
        }
        return fallback
    }

    private static let proRes: Set<FourCharCode> = [
        kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ, kCMVideoCodecType_AppleProRes422LT,
        kCMVideoCodecType_AppleProRes422Proxy, kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes4444XQ,
        fourCC("aprn"), fourCC("aprh"),
    ]

    private static func fourCC(_ string: String) -> FourCharCode {
        string.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }

    private static func describe(_ format: CMFormatDescription?, size: CGSize, frameRate: Double) -> String {
        var parts: [String] = []
        if let format {
            let codec = CMFormatDescriptionGetMediaSubType(format)
            switch codec {
            case kCMVideoCodecType_HEVC, fourCC("dvh1"), fourCC("hev1"): parts.append("HEVC")
            case kCMVideoCodecType_H264, fourCC("avc3"): parts.append("H.264")
            case fourCC("av01"): parts.append("AV1")
            case _ where proRes.contains(codec): parts.append("ProRes")
            default: break
            }
        }
        parts.append("\(Int(size.width)) × \(Int(size.height))")
        parts.append(frameRate.rounded() == frameRate ? "\(Int(frameRate)) fps" : String(format: "%.2f fps", frameRate))
        if let format, let hdr = hdrName(format) { parts.append(hdr) }
        return parts.joined(separator: " · ")
    }

    private static func hdrName(_ format: CMFormatDescription) -> String? {
        let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any] ?? [:]
        if atoms.keys.contains(where: { ["dvcC", "dvvC", "dvwC"].contains($0) })
            || CMFormatDescriptionGetMediaSubType(format) == fourCC("dvh1") {
            return "HDR (Dolby Vision)"
        }
        let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String
        if transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) { return "HDR (HLG)" }
        if transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) { return "HDR (PQ)" }
        return nil
    }
}

/// Builds the edit as a composition: the parts of the source one after another. Nothing is copied
/// or decoded; preview and export read straight from the original file.
enum Composer {
    /// The edit as a composition: the pictures of `ranges` one after another, and the sound as
    /// `sound` says (by default it follows the pictures). Gaps in the sound stay silent.
    static func composition(_ document: VideoDocument, ranges: [Range<Int64>], sound: [SoundSegment]? = nil,
                            video: Bool = true, audio: Bool = true) throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        if video, let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            var at = CMTime.zero
            for range in ranges where !range.isEmpty {
                let timeRange = CMTimeRange(start: document.time(range.lowerBound), duration: document.time(Int64(range.count)))
                try videoTrack.insertTimeRange(timeRange, of: document.videoTrack, at: at)
                at = at + timeRange.duration
            }
            videoTrack.preferredTransform = document.transform
        }
        if audio { try addSound(to: composition, document, sound ?? SoundSegment.following(ranges)) }
        return composition
    }

    /// The sound track of an edit: the segments one after another, silence in the gaps.
    @discardableResult
    static func addSound(to composition: AVMutableComposition, _ document: VideoDocument, _ segments: [SoundSegment]) throws
        -> AVMutableCompositionTrack? {
        guard let source = document.audioTrack, let audioRange = document.audioTimeRange,
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }
        var end = CMTime.zero
        for segment in segments.sorted(by: { $0.position < $1.position }) {
            let timeRange = CMTimeRange(start: document.time(segment.source.lowerBound), duration: document.time(Int64(segment.source.count)))
            // The sound can be a little shorter or longer than the picture; it is placed by time.
            let overlap = timeRange.intersection(audioRange)
            guard overlap.duration > .zero else { continue }
            let at = document.time(segment.position) + (overlap.start - timeRange.start)
            if at > end { audioTrack.insertEmptyTimeRange(CMTimeRange(start: end, end: at)) }
            try audioTrack.insertTimeRange(overlap, of: source, at: at)
            end = at + overlap.duration
        }
        // Nothing to hear (everything muted): an empty sound track makes the encoding export fail (−11838).
        guard end > .zero else {
            composition.removeTrack(audioTrack)
            return nil
        }
        return audioTrack
    }
}

// MARK: - Waveform

/// Waveform overview of the sound: minimum and maximum per block of audio frames, in several
/// resolutions (the timeline picks the one that fits its zoom).
struct Peaks: Sendable {
    static let baseBlock = 256
    static let levelFactor = 4

    struct Level: Sendable {
        let block: Int
        var minimum: [Float]
        var maximum: [Float]
    }

    let levels: [Level]
    let length: Int64
    /// Highest absolute value; the view scales the waveform to it.
    let peak: Float

    init(length: Int64, minimum: [Float], maximum: [Float]) {
        self.length = length
        var levels = [Level(block: Peaks.baseBlock, minimum: minimum, maximum: maximum)]
        while let last = levels.last, last.minimum.count > 2_000 {
            let count = (last.minimum.count + Peaks.levelFactor - 1) / Peaks.levelFactor
            var lower = [Float](repeating: 0, count: count)
            var upper = [Float](repeating: 0, count: count)
            for i in 0..<count {
                let from = i * Peaks.levelFactor, to = min(from + Peaks.levelFactor, last.minimum.count)
                lower[i] = last.minimum[from..<to].min() ?? 0
                upper[i] = last.maximum[from..<to].max() ?? 0
            }
            levels.append(Level(block: last.block * Peaks.levelFactor, minimum: lower, maximum: upper))
        }
        self.levels = levels
        let top = levels.last!
        peak = max(abs(top.minimum.min() ?? 0), abs(top.maximum.max() ?? 0))
    }

    /// The coarsest level whose blocks are not wider than `framesPerPoint`.
    func level(forFramesPerPoint framesPerPoint: Double) -> Int {
        var result = 0
        for (i, level) in levels.enumerated() where Double(level.block) <= framesPerPoint { result = i }
        return result
    }

    /// Minimum and maximum between two frames on the given level (at least one block).
    func range(from start: Int64, to end: Int64, level index: Int) -> (Float, Float)? {
        let level = levels[index]
        let count = level.minimum.count
        let first = Int(max(0, start) / Int64(level.block))
        guard first < count else { return nil }
        let last = min(count, max(first + 1, Int((end + Int64(level.block) - 1) / Int64(level.block))))
        var lower: Float = 0, upper: Float = 0
        for i in first..<last {
            lower = min(lower, level.minimum[i])
            upper = max(upper, level.maximum[i])
        }
        return (lower, upper)
    }
}

enum AudioReader {
    /// Waveform of the main sound track, all channels together. Positions are audio frames from the
    /// asset's time 0; nil without sound or when cancelled.
    static func peaks(for document: VideoDocument, token: CancelToken, progress: (Double) -> Void) throws -> Peaks? {
        guard let track = document.audioTrack else { return nil }
        let reader = try AVAssetReader(asset: document.asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? VideoError.cannotOpen(document.url.lastPathComponent) }

        let rate = document.audioSampleRate
        let total = Double(document.audioFrame(document.bounds.upperBound))
        let block = Peaks.baseBlock
        var minimum: [Float] = [], maximum: [Float] = []
        var blockMin: Float = 0, blockMax: Float = 0, inBlock = 0
        var frames: Int64 = 0
        var samples: [Float] = []
        let gate = PercentGate()

        func addSilence(_ count: Int64) {
            for _ in 0..<count {
                inBlock += 1
                if inBlock == block {
                    minimum.append(blockMin); maximum.append(blockMax)
                    blockMin = 0; blockMax = 0; inBlock = 0
                }
            }
            frames += count
        }

        while let buffer = output.copyNextSampleBuffer() {
            if token.isCancelled {
                reader.cancelReading()
                return nil
            }
            let count = CMSampleBufferGetNumSamples(buffer)
            guard count > 0, let data = CMSampleBufferGetDataBuffer(buffer),
                  let format = CMSampleBufferGetFormatDescription(buffer),
                  let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { continue }
            let length = CMBlockBufferGetDataLength(data)
            guard length >= 4 else { continue }
            // Gaps in the track (or a late start) are silence, so that positions stay in time.
            let start = (CMSampleBufferGetPresentationTimeStamp(buffer).seconds * rate).rounded()
            if start.isFinite, start > Double(frames) { addSilence(Int64(min(start - Double(frames), rate * 3600))) }
            let channels = Int(max(1, description.mChannelsPerFrame))
            if samples.count < length / 4 { samples = [Float](repeating: 0, count: length / 4) }
            samples.withUnsafeMutableBytes {
                _ = CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: min(length, $0.count), destination: $0.baseAddress!)
            }
            let usable = min(count, length / 4 / channels)
            for frame in 0..<usable {
                var low: Float = 0, high: Float = 0
                for channel in 0..<channels {
                    let value = samples[frame * channels + channel]
                    low = min(low, value)
                    high = max(high, value)
                }
                blockMin = min(blockMin, low)
                blockMax = max(blockMax, high)
                inBlock += 1
                if inBlock == block {
                    minimum.append(blockMin); maximum.append(blockMax)
                    blockMin = 0; blockMax = 0; inBlock = 0
                }
            }
            frames += Int64(usable)
            if total > 0 {
                let value = min(1, Double(frames) / total)
                if gate.pass(value) { progress(value) }
            }
        }
        if reader.status == .failed { throw reader.error ?? VideoError.cannotOpen(document.url.lastPathComponent) }
        if inBlock > 0 { minimum.append(blockMin); maximum.append(blockMax) }
        return Peaks(length: frames, minimum: minimum, maximum: maximum)
    }
}
