import AVFoundation
import Foundation

enum ExportError: LocalizedError {
    case encoder
    case overwritesSource
    case notMP4
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .encoder: "Der MP3-Encoder konnte nicht gestartet werden."
        case .overwritesSource: "Die Originaldatei kann nicht überschrieben werden. Bitte wähle einen anderen Namen oder Ordner."
        case .notMP4: "Dieses Video passt ohne Neukodierung nicht in eine MP4-Datei. Bitte wähle beim Exportieren das Format MOV."
        case .failed(let reason): reason
        }
    }
}

enum AudioFormat: String, CaseIterable, Sendable {
    case m4a, wav, mp3

    var fileExtension: String { rawValue }

    var title: String {
        switch self {
        case .m4a: "M4A (AAC, 256 kbit/s)"
        case .wav: "WAV"
        case .mp3: "MP3 (320 kbit/s)"
        }
    }
}

/// The codec when an edit with effects is encoded anew.
enum VideoCodec: String, CaseIterable, Sendable {
    case h264, hevc

    var title: String {
        switch self {
        case .h264: "H.264 – läuft überall"
        case .hevc: "HEVC – kleinere Datei"
        }
    }

    var preset: String {
        switch self {
        case .h264: AVAssetExportPresetHighestQuality
        case .hevc: AVAssetExportPresetHEVCHighestQuality
        }
    }

    static let defaultsKey = "videoCodec"
}

enum Exporter {
    /// Writes the edit as a new video without re-encoding: the frames and the sound are copied from
    /// the original (original quality, HDR stays), the cuts are stored as an edit list. Takes
    /// seconds even for long videos. The container follows the extension of `destination`: from a
    /// MOV into an MP4, recording date and place stay (as ISO user data), make and model are lost.
    static func exportVideo(_ document: VideoDocument, ranges: [Range<Int64>], sound: [SoundSegment]? = nil, to destination: URL,
                            progress: @escaping @Sendable (Double) -> Void) async throws {
        try check(destination, against: document)
        let fileType = VideoDocument.fileType(for: destination)
        if fileType != .mov, !document.copiesIntoMP4 { throw ExportError.notMP4 }
        let composition = try Composer.composition(document, ranges: ranges, sound: sound)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw ExportError.failed("Das Video lässt sich nicht ohne Neukodierung exportieren.")
        }
        // Recording date, place and camera stay with the video.
        session.metadata = (try? await document.asset.load(.metadata)) ?? []
        try await run(session, as: fileType, to: destination, source: document.url, progress: progress)
    }

    /// Writes an edit with transitions, titles or a logo: the picture is rendered and encoded anew
    /// as H.264 or HEVC, in SDR (HDR is tone-mapped), in the size and frame rate of the source; the
    /// sound is encoded as AAC. MP4 and MOV both work, also for ProRes sources.
    static func exportEffects(_ document: VideoDocument, edit: EditList, codec: VideoCodec, to destination: URL,
                              progress: @escaping @Sendable (Double) -> Void) async throws {
        try check(destination, against: document)
        let effects = try Composer.effects(document, edit: edit)
        guard let session = AVAssetExportSession(asset: effects.composition, presetName: codec.preset) else {
            throw ExportError.failed("Das Video lässt sich nicht als \(codec == .hevc ? "HEVC" : "H.264") kodieren.")
        }
        session.videoComposition = effects.videoComposition
        session.audioMix = effects.audioMix
        session.metadata = (try? await document.asset.load(.metadata)) ?? []
        try await run(session, as: VideoDocument.fileType(for: destination), to: destination, source: document.url, progress: progress)
    }

    /// Writes the sound of the edit, decoded and encoded anew: AAC 256 kbit/s, WAV 16 bit or MP3
    /// 320 kbit/s. Copying the AAC as it is would leave the cuts as an edit list, which many audio
    /// programs ignore (they play bits of what was cut away), and AVFoundation's copy of a whole
    /// track loses its last few hundredths of a second.
    /// `ramps`: fades to and from black, which the sound follows.
    static func exportAudio(_ document: VideoDocument, ranges: [Range<Int64>], sound: [SoundSegment]? = nil,
                            ramps: [EffectLayout.Ramp] = [], format: AudioFormat, to destination: URL,
                            progress: @escaping @Sendable (Double) -> Void) async throws {
        try check(destination, against: document)
        let composition = try Composer.composition(document, ranges: ranges, sound: sound, video: false)
        // Everything muted: the composition has no sound track.
        guard let track = composition.tracks(withMediaType: .audio).first else {
            throw ExportError.failed("Im Schnitt ist kein Ton zu hören.")
        }
        let mix = Composer.audioMix(for: track, ramps: ramps, document: document)
        guard let asset = composition.copy() as? AVComposition else { throw ExportError.failed("Der Ton lässt sich nicht lesen.") }
        let temp = temporaryURL(for: destination)
        let token = CancelToken()
        let sampleRate = document.audioSampleRate, channels = min(2, document.audioChannels)
        do {
            try await withTaskCancellationHandler {
                try await Task.detached {
                    try await encode(asset, mix: mix, sampleRate: sampleRate, channels: channels, format: format, to: temp,
                                     token: token, progress: progress)
                }.value
            } onCancel: {
                token.cancel()
            }
            try moveIntoPlace(temp, destination)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    private static func check(_ destination: URL, against document: VideoDocument) throws {
        let target = destination.standardizedFileURL.resolvingSymlinksInPath()
        let source = document.url.standardizedFileURL.resolvingSymlinksInPath()
        if target == source { throw ExportError.overwritesSource }
        // The same file under another spelling: a hard link, or other letter case where the path is not canonicalised.
        let key = URLResourceKey.fileResourceIdentifierKey
        if let existing = try? target.resourceValues(forKeys: [key]).fileResourceIdentifier,
           let original = try? source.resourceValues(forKeys: [key]).fileResourceIdentifier,
           existing.isEqual(original) {
            throw ExportError.overwritesSource
        }
    }

    private static func run(_ session: AVAssetExportSession, as fileType: AVFileType, to destination: URL, source: URL,
                            progress: @escaping @Sendable (Double) -> Void) async throws {
        let temp = temporaryURL(for: destination)
        let monitor = Task {
            for await state in session.states(updateInterval: 0.1) {
                if case .exporting(let value) = state { progress(value.fractionCompleted) }
            }
        }
        defer { monitor.cancel() }
        do {
            try await session.export(to: temp, as: fileType)
            if let created = try? MovieHeader.creationTime(of: source), created > 0 {
                try? MovieHeader.setCreationTime(created, of: temp)
            }
            try moveIntoPlace(temp, destination)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// Decodes the sound (mixed to at most two channels) and writes it as AAC, WAV (16 bit) or MP3.
    private static func encode(_ asset: AVComposition, mix: AVAudioMix?, sampleRate: Double, channels: Int, format: AudioFormat,
                               to url: URL, token: CancelToken, progress: (Double) -> Void) async throws {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw ExportError.failed("Das Video hat keinen Ton.") }
        let duration = try await asset.load(.duration)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.audioMix = mix
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ExportError.failed("Der Ton lässt sich nicht lesen.") }
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                      channels: AVAudioChannelCount(channels), interleaved: false) else { throw ExportError.encoder }

        var file: AVAudioFile?
        var mp3: MP3Encoder?
        var handle: FileHandle?
        switch format {
        case .m4a:
            file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: channels == 1 ? 128_000 : 256_000,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
        case .wav:
            file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
        default:
            mp3 = try MP3Encoder(sampleRate: Int(sampleRate), channels: channels)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw ExportError.failed("In „\(url.deletingLastPathComponent().lastPathComponent)“ kann nicht geschrieben werden.")
            }
            handle = try FileHandle(forWritingTo: url)
        }
        defer {
            file?.close()
            try? handle?.close()
        }

        let total = max(1, duration.seconds * sampleRate)
        var done = 0.0
        let gate = PercentGate()
        while let sample = output.copyNextSampleBuffer() {
            if token.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(frames)) else { continue }
            buffer.frameLength = AVAudioFrameCount(frames)
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames),
                                                                      into: buffer.mutableAudioBufferList)
            guard status == noErr else { throw ExportError.failed("Der Ton lässt sich nicht lesen (Fehler \(status)).") }
            if let file { try file.write(from: buffer) }
            if let mp3, let handle, let data = buffer.floatChannelData {
                try handle.write(contentsOf: mp3.encode(left: data[0], right: data[channels > 1 ? 1 : 0], count: frames))
            }
            done += Double(frames)
            let value = min(1, done / total)
            if gate.pass(value) { progress(value) }
        }
        if reader.status == .failed { throw reader.error ?? ExportError.failed("Der Ton lässt sich nicht lesen.") }
        if let mp3, let handle {
            try handle.write(contentsOf: mp3.flush())
            let tag = mp3.lameTag()
            if !tag.isEmpty {
                try handle.seek(toOffset: 0)
                try handle.write(contentsOf: tag)
            }
        }
    }

    /// A hidden file next to the destination, with the same extension (the writers pick the format by it).
    static func temporaryURL(for destination: URL) -> URL {
        let name = ".\(destination.deletingPathExtension().lastPathComponent)-\(UUID().uuidString.prefix(8)).videohub"
        return destination.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension(destination.pathExtension)
    }

    /// Replaces an existing file by moving it to the Trash first (volumes without a Trash: replaced).
    static func moveIntoPlace(_ temp: URL, _ destination: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            if (try? manager.trashItem(at: destination, resultingItemURL: nil)) == nil {
                _ = try manager.replaceItemAt(destination, withItemAt: temp)
                return
            }
        }
        try manager.moveItem(at: temp, to: destination)
    }
}

/// The creation time in the movie header ('mvhd' in 'moov'), in seconds since 1904. AVFoundation
/// writes the time of the export there; Photos and other media apps take the recording date from
/// it when a file has no QuickTime metadata (most MP4s). The field has a fixed size, so it can be
/// overwritten in place.
enum MovieHeader {
    static func creationTime(of url: URL) throws -> UInt64? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let field = try creationField(in: handle) else { return nil }
        try handle.seek(toOffset: field.offset)
        guard let data = try handle.read(upToCount: field.width), data.count == field.width else { return nil }
        return data.reduce(0) { $0 << 8 | UInt64($1) }
    }

    static func setCreationTime(_ value: UInt64, of url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        guard let field = try creationField(in: handle), field.width == 8 || value <= UInt64(UInt32.max) else { return }
        let bytes = (0..<field.width).reversed().map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
        try handle.seek(toOffset: field.offset)
        try handle.write(contentsOf: Data(bytes))
    }

    /// Position and width of the field: 4 bytes in a version 0 header, 8 in version 1.
    private static func creationField(in handle: FileHandle) throws -> (offset: UInt64, width: Int)? {
        let end = try handle.seekToEnd()
        guard let moov = try box("moov", in: handle, from: 0, to: end),
              let mvhd = try box("mvhd", in: handle, from: moov.content, to: moov.end) else { return nil }
        try handle.seek(toOffset: mvhd.content)
        guard let version = try handle.read(upToCount: 1)?.first, version <= 1 else { return nil }
        let width = version == 1 ? 8 : 4
        guard mvhd.content + 4 + UInt64(width) <= mvhd.end else { return nil }
        return (mvhd.content + 4, width)
    }

    /// The first box of a type between two offsets: where its content starts and where it ends.
    private static func box(_ type: String, in handle: FileHandle, from start: UInt64, to end: UInt64) throws
        -> (content: UInt64, end: UInt64)? {
        var offset = start
        while offset + 8 <= end {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 16), header.count >= 8 else { return nil }
            let bytes = [UInt8](header)
            var size = bytes[0..<4].reduce(0) { $0 << 8 | UInt64($1) }
            var headerSize: UInt64 = 8
            if size == 1 {
                guard bytes.count == 16 else { return nil }
                size = bytes[8..<16].reduce(0) { $0 << 8 | UInt64($1) }
                headerSize = 16
            } else if size == 0 {
                size = end - offset
            }
            guard size >= headerSize, size <= end - offset else { return nil }
            if String(decoding: bytes[4..<8], as: UTF8.self) == type { return (offset + headerSize, offset + size) }
            offset += size
        }
        return nil
    }
}
