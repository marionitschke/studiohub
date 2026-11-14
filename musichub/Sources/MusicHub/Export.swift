import Accelerate
import AVFoundation
import Foundation

/// A range of the source with fades at its start and end (in frames).
struct ExportPiece: Sendable, Equatable {
    var range: Range<Int64>
    var fadeIn: Int64 = 0
    var fadeOut: Int64 = 0
}

/// One MP3 to write: the pieces of the source, joined in order.
struct ExportJob: Sendable {
    let pieces: [ExportPiece]
    let destination: URL
    let tag: ID3Tag
    /// Brings the file to `LoudnessMeter.target`: a first pass measures, the second encodes.
    var normalize = false
    /// Written next to the MP3 (same name, .cue) once the MP3 is in place.
    var cueSheet: String?

    var frames: Int64 { pieces.reduce(0) { $0 + Int64($1.range.count) } }
    /// Frames to go through, counting the measuring pass.
    var work: Int64 { frames * (normalize ? 2 : 1) }
    var cueDestination: URL { destination.deletingPathExtension().appendingPathExtension("cue") }
}

enum Exporter {
    /// Short fade wherever the audio jumps (a gap before or after a piece), so that no click is heard.
    static let clickFadeSeconds = 0.006

    /// Pieces for exporting `segments` (in time order) joined into one file: each keeps its own fades,
    /// and where the audio jumps – not at the start or end of the file – a short fade is added.
    static func pieces(for segments: [Segment], sourceLength: Int64, sampleRate: Double) -> [ExportPiece] {
        let clickFade = Int64(sampleRate * clickFadeSeconds)
        return segments.enumerated().map { index, segment in
            var piece = ExportPiece(range: segment.start..<segment.end, fadeIn: segment.fadeIn, fadeOut: segment.fadeOut)
            let continuesBefore = index > 0 && segments[index - 1].end == segment.start
            let continuesAfter = index + 1 < segments.count && segments[index + 1].start == segment.end
            if !continuesBefore && segment.start > 0 { piece.fadeIn = max(piece.fadeIn, min(clickFade, segment.length / 2)) }
            if !continuesAfter && segment.end < sourceLength { piece.fadeOut = max(piece.fadeOut, min(clickFade, segment.length / 2)) }
            return piece
        }
    }

    static func export(_ job: ExportJob, source url: URL, token: CancelToken, progress: (Int64) -> Void) throws {
        try export(job, source: AudioLoader.open(url), token: token, progress: progress)
    }

    /// Writes `job` as an MP3. The file is built under a hidden temporary name next to the
    /// destination and only moved into place when complete; an existing file goes to the Trash.
    /// `progress` receives the number of frames processed since the last call (see `ExportJob.work`).
    static func export(_ job: ExportJob, source: AudioDocument, token: CancelToken,
                       progress: (Int64) -> Void) throws {
        if source.contains(job.destination) || (job.cueSheet != nil && source.contains(job.cueDestination)) {
            throw ExportError.overwritesSource
        }
        let channels = source.channels == 1 ? 1 : 2
        let encoder = try MP3Encoder(sampleRate: Int(source.sampleRate), channels: channels)

        var gain: Float = 1
        if job.normalize {
            let meter = LoudnessMeter(sampleRate: source.sampleRate, channels: channels)
            try render(job, source: source, token: token) { samples, count in
                meter.add(samples, count: count)
                progress(Int64(count))
            }
            gain = meter.gain()
        }

        let folder = job.destination.deletingLastPathComponent()
        let temp = temporaryURL(for: job.destination)
        guard FileManager.default.createFile(atPath: temp.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: temp) else {
            throw ExportError.notWritable(folder.lastPathComponent)
        }
        var finished = false
        defer {
            try? handle.close()
            if !finished { try? FileManager.default.removeItem(at: temp) }
        }

        let id3 = job.tag.data()
        try handle.write(contentsOf: id3)
        try render(job, source: source, token: token) { samples, count in
            if gain != 1 {
                for channel in 0..<channels { vDSP_vsmul(samples[channel], 1, &gain, samples[channel], 1, vDSP_Length(count)) }
            }
            let right = channels > 1 ? samples[1] : samples[0]
            try handle.write(contentsOf: try encoder.encode(left: samples[0], right: right, count: count))
            progress(Int64(count))
        }
        try handle.write(contentsOf: try encoder.flush())
        let tag = encoder.lameTag()
        if !tag.isEmpty {
            try handle.seek(toOffset: UInt64(id3.count))
            try handle.write(contentsOf: tag)
        }
        try handle.close()

        try moveIntoPlace(temp, job.destination)
        finished = true

        if let cueSheet = job.cueSheet {
            let cueTemp = temporaryURL(for: job.cueDestination)
            do {
                try Data(cueSheet.utf8).write(to: cueTemp)
                try moveIntoPlace(cueTemp, job.cueDestination)
            } catch {
                try? FileManager.default.removeItem(at: cueTemp)
                throw ExportError.notWritable(folder.lastPathComponent)
            }
        }
    }

    /// Decodes the pieces in order, mixes more than two channels down to stereo and applies the
    /// fades. `body` gets one or two channels of float samples per chunk and may change them.
    private static func render(_ job: ExportJob, source: AudioDocument, token: CancelToken,
                               _ body: (UnsafePointer<UnsafeMutablePointer<Float>>, Int) throws -> Void) throws {
        // More than two channels (e.g. 5.1) are mixed down to stereo by Core Audio, which knows the
        // channel layouts.
        var downmix: (converter: AVAudioConverter, buffer: AVAudioPCMBuffer)?

        // Pieces that follow each other in the source are decoded in one go.
        var runs: [[ExportPiece]] = []
        for piece in job.pieces {
            if let last = runs.last?.last, last.range.upperBound == piece.range.lowerBound {
                runs[runs.count - 1].append(piece)
            } else {
                runs.append([piece])
            }
        }

        for run in runs {
            let start = run[0].range.lowerBound, end = run[run.count - 1].range.upperBound
            try AudioLoader.decode(source, from: start, to: end, token: token) { input, position in
                var buffer = input
                if source.channels > 2 {
                    if downmix?.converter.inputFormat != input.format {
                        guard let stereo = AVAudioFormat(standardFormatWithSampleRate: source.sampleRate, channels: 2),
                              let converter = AVAudioConverter(from: input.format, to: stereo),
                              let output = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: input.frameCapacity) else {
                            throw ExportError.encoder
                        }
                        converter.downmix = true
                        downmix = (converter, output)
                    }
                    try downmix!.converter.convert(to: downmix!.buffer, from: input)
                    buffer = downmix!.buffer
                }
                let count = Int(buffer.frameLength)
                let samples = buffer.floatChannelData!
                let outputChannels = Int(buffer.format.channelCount)

                // Only the frames inside a fade are touched.
                let chunk = position..<(position + Int64(count))
                for piece in run where piece.range.overlaps(chunk) {
                    var windows = [piece.range.lowerBound..<(piece.range.lowerBound + piece.fadeIn),
                                   (piece.range.upperBound - piece.fadeOut)..<piece.range.upperBound]
                    if windows[0].upperBound > windows[1].lowerBound {
                        // Fades that meet: one window, so that no frame is faded twice.
                        windows = [windows[0].lowerBound..<windows[1].upperBound]
                    }
                    for window in windows where !window.isEmpty && window.overlaps(chunk) {
                        for absolute in max(window.lowerBound, chunk.lowerBound)..<min(window.upperBound, chunk.upperBound) {
                            let gain = Fade.gain(at: absolute, range: piece.range, fadeIn: piece.fadeIn, fadeOut: piece.fadeOut)
                            let frame = Int(absolute - position)
                            for channel in 0..<outputChannels { samples[channel][frame] *= gain }
                        }
                    }
                }
                try body(samples, count)
            }
        }
    }

    private static func temporaryURL(for destination: URL) -> URL {
        // The name only makes the file recognisable; shortened, so that a long destination name does
        // not push the temporary one over the 255 bytes a file name may have.
        var name = destination.deletingPathExtension().lastPathComponent
        while name.decomposedStringWithCanonicalMapping.utf8.count > 100 { name.removeLast() }
        return destination.deletingLastPathComponent().appendingPathComponent(".\(name)-\(UUID().uuidString.prefix(8)).musichub")
    }

    /// Replaces an existing file by moving it to the Trash first (volumes without a Trash: replaced).
    private static func moveIntoPlace(_ temp: URL, _ destination: URL) throws {
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
