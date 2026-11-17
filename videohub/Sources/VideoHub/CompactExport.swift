import AVFoundation
import Foundation

/// Re-encoding for sharing (WhatsApp, Instagram): size and frame rate stay, only the bit rate is
/// lower. AVAssetExportSession's presets choose the bit rate themselves (the highest quality takes
/// about as much as the camera did), so this encodes with AVAssetReader and AVAssetWriter.
enum CompactExport {
    /// Picture bit rate: 4.5 Mbit/s for H.264 at 1080p and 30 fps, HEVC two thirds of that. Smaller
    /// pictures get more bits per pixel (exponent 0.75), as encoders need relatively more for them;
    /// never more than the source has, so the copy does not grow.
    static func videoBitRate(size: CGSize, frameRate: Double, codec: VideoCodec, sourceBitRate: Double? = nil) -> Int {
        let pixels = max(1, Double(size.width * size.height)) / (1920 * 1080)
        let rate = min(max(frameRate, 1), 240) / 30
        var bits = 4_500_000 * pow(pixels, 0.75) * pow(rate, 0.5) * (codec == .hevc ? 0.65 : 1)
        if let sourceBitRate, sourceBitRate > 0 { bits = min(bits, sourceBitRate) }
        return Int(max(250_000, bits).rounded())
    }

    static func audioBitRate(channels: Int) -> Int { channels == 1 ? 64_000 : 128_000 }

    /// The rates AAC encodes: the source's, or the next higher one, at most 48 kHz.
    static func audioSampleRate(_ source: Double) -> Double {
        [8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000].first { $0 >= source.rounded() } ?? 48_000
    }

    /// The video and sound bit rates for a document, for the export and its estimate.
    static func bitRates(for document: VideoDocument, codec: VideoCodec) -> (video: Int, audio: Int) {
        let seconds = document.seconds(document.length)
        let source = seconds > 0 ? Double(document.fileSize) * 8 / seconds : nil
        let video = videoBitRate(size: EffectRenderer.renderSize(of: document), frameRate: document.frameRate, codec: codec,
                                 sourceBitRate: source)
        return (video, document.audioTrack == nil ? 0 : audioBitRate(channels: min(2, max(1, document.audioChannels))))
    }

    /// About how many bytes `seconds` of the document take, compressed.
    static func estimatedSize(of document: VideoDocument, seconds: Double, codec: VideoCodec) -> Int64 {
        let rates = bitRates(for: document, codec: codec)
        return Int64(Double(rates.video + rates.audio) * seconds / 8)
    }

    /// Encodes the edit with effects (or without: then it is just smaller) to `url`, which must not exist.
    static func write(_ effects: Composer.Effects, document: VideoDocument, codec: VideoCodec, metadata: [AVMetadataItem],
                      as fileType: AVFileType, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let composition = effects.composition
        let reader = try AVAssetReader(asset: composition)
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        // The index at the start: players and messengers can begin before the whole file is there.
        writer.shouldOptimizeForNetworkUse = true
        writer.metadata = metadata
        let rates = bitRates(for: document, codec: codec)

        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: composition.tracks(withMediaType: .video), videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        videoOutput.videoComposition = effects.videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw ExportError.failed("Das Bild lässt sich nicht lesen.") }
        reader.add(videoOutput)
        let size = effects.videoComposition.renderSize
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: rates.video,
            AVVideoExpectedSourceFrameRateKey: document.frameRate,
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
        ]
        if codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            compression[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: compression,
        ])
        videoInput.mediaTimeScale = document.timescale
        guard writer.canAdd(videoInput) else { throw ExportError.failed("Das Video lässt sich nicht als \(codec.name) kodieren.") }
        writer.add(videoInput)

        var pumps: [Pump] = []
        let duration = composition.duration.seconds
        let gate = PercentGate()
        pumps.append(Pump(output: videoOutput, input: videoInput, reader: reader, label: "video") { time in
            guard duration > 0, time.isNumeric else { return }
            let value = min(1, max(0, time.seconds / duration))
            if gate.pass(value) { progress(value) }
        })

        let audioTracks = composition.tracks(withMediaType: .audio)
        if !audioTracks.isEmpty {
            let channels = min(2, max(1, document.audioChannels))
            let sampleRate = audioSampleRate(document.audioSampleRate)
            let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            audioOutput.audioMix = effects.audioMix
            audioOutput.alwaysCopiesSampleData = false
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: audioBitRate(channels: channels),
            ])
            guard reader.canAdd(audioOutput), writer.canAdd(audioInput) else { throw ExportError.failed("Der Ton lässt sich nicht kodieren.") }
            reader.add(audioOutput)
            writer.add(audioInput)
            pumps.append(Pump(output: audioOutput, input: audioInput, reader: reader, label: "audio", sample: nil))
        }

        guard reader.startReading() else { throw reader.error ?? ExportError.failed("Das Video lässt sich nicht lesen.") }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw writer.error ?? ExportError.failed("Die Datei lässt sich nicht schreiben.")
        }
        writer.startSession(atSourceTime: .zero)

        let run = Run(reader: reader, pumps: pumps)
        let complete = await withTaskCancellationHandler {
            await withTaskGroup(of: Bool.self) { group in
                for pump in pumps { group.addTask { await pump.run() } }
                var complete = true
                for await done in group where !done {
                    complete = false
                    run.stop()
                }
                return complete
            }
        } onCancel: {
            run.stop()
        }
        // A block may still be on its way out of an append.
        for pump in pumps { await pump.drain() }

        defer { removeCopies(of: url) }
        if complete, !Task.isCancelled {
            await writer.finishWriting()
            if writer.status == .completed { return }
        } else if writer.status == .writing {
            writer.cancelWriting()
        }
        try Task.checkCancellation()
        throw writer.error ?? reader.error ?? ExportError.failed("Das Video ließ sich nicht kodieren.")
    }

    /// The writer moves the index to the front through a copy next to the file ("<name>.sb-…"), which
    /// it removes only a little later – not at all if the app quits first.
    private static func removeCopies(of url: URL) {
        let folder = url.deletingLastPathComponent(), prefix = url.lastPathComponent + ".sb-"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// What a cancellation or a failed track stops: the reading (which also frees a pump waiting for a
    /// frame) and every pump.
    private final class Run: @unchecked Sendable {
        private let reader: AVAssetReader
        private let pumps: [Pump]

        init(reader: AVAssetReader, pumps: [Pump]) {
            self.reader = reader
            self.pumps = pumps
        }

        func stop() {
            reader.cancelReading()
            for pump in pumps { pump.finish(false) }
        }
    }

    /// Moves the samples of one track from the reader to the writer, on a queue of its own: the writer
    /// interleaves the tracks and holds one back while it waits for the other.
    private final class Pump: @unchecked Sendable {
        private let output: AVAssetReaderOutput
        private let input: AVAssetWriterInput
        private let reader: AVAssetReader
        private let queue: DispatchQueue
        private let sample: (@Sendable (CMTime) -> Void)?
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        private var result: Bool?

        init(output: AVAssetReaderOutput, input: AVAssetWriterInput, reader: AVAssetReader, label: String,
             sample: (@Sendable (CMTime) -> Void)?) {
            self.output = output
            self.input = input
            self.reader = reader
            self.sample = sample
            queue = DispatchQueue(label: "VideoHub.CompactExport.\(label)")
        }

        /// True once every sample is in, false if the track stopped early.
        func run() async -> Bool {
            await withCheckedContinuation { continuation in
                let finished = lock.withLock { () -> Bool? in
                    if result == nil { self.continuation = continuation }
                    return result
                }
                if let finished {
                    continuation.resume(returning: finished)
                    return
                }
                input.requestMediaDataWhenReady(on: queue) { [self] in feed() }
            }
        }

        private func feed() {
            while input.isReadyForMoreMediaData {
                if lock.withLock({ result != nil }) { return }
                guard let buffer = output.copyNextSampleBuffer() else {
                    // Still reading when only the other track has samples left.
                    let read = reader.status == .completed || reader.status == .reading
                    if read { input.markAsFinished() }
                    finish(read)
                    return
                }
                sample?(CMSampleBufferGetPresentationTimeStamp(buffer))
                guard input.append(buffer) else {
                    finish(false)
                    return
                }
            }
        }

        func finish(_ success: Bool) {
            let waiting = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
                guard result == nil else { return nil }
                result = success
                defer { continuation = nil }
                return continuation
            }
            waiting?.resume(returning: success)
        }

        /// Waits until no block of this pump runs any more.
        func drain() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async { continuation.resume() }
            }
        }
    }
}
