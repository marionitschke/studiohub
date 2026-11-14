import Accelerate
import AVFoundation
import Foundation

/// The opened recording: one file, or several files of the same format played one after another.
/// Positions are sample frames of the whole recording.
struct AudioDocument: Sendable {
    struct File: Sendable, Equatable {
        let url: URL
        /// Position of the file's first frame in the recording.
        let start: Int64
        let length: Int64
        let size: Int64

        var range: Range<Int64> { start..<(start + length) }
    }

    let files: [File]
    let sampleRate: Double
    let channels: Int
    /// Length in sample frames.
    let length: Int64

    init(files: [File], sampleRate: Double, channels: Int) {
        self.files = files
        self.sampleRate = sampleRate
        self.channels = channels
        length = files.last.map { $0.start + $0.length } ?? 0
    }

    init(url: URL, length: Int64, sampleRate: Double, channels: Int, fileSize: Int64) {
        self.init(files: [File(url: url, start: 0, length: length, size: fileSize)], sampleRate: sampleRate, channels: channels)
    }

    /// The first file: it names the recording and gives the folder and the tags.
    var url: URL { files[0].url }
    var urls: [URL] { files.map(\.url) }
    var fileSize: Int64 { files.reduce(0) { $0 + $1.size } }
    var duration: Double { Double(length) / sampleRate }
    var name: String { url.deletingPathExtension().lastPathComponent }
    /// "Aufnahme.mp3" or "Teil 1.wav + 2 weitere"
    var displayName: String {
        files.count == 1 ? url.lastPathComponent : "\(url.lastPathComponent) + \(files.count - 1) weitere"
    }
    /// Where the second and every later file begins.
    var fileStarts: [Int64] { files.dropFirst().map(\.start) }

    /// "44,1 kHz · Stereo"
    var summary: String {
        let kHz = (sampleRate / 1000).formatted(.number.precision(.fractionLength(0...1)))
        let layout = switch channels {
        case 1: "Mono"
        case 2: "Stereo"
        default: "\(channels) Kanäle"
        }
        return "\(kHz) kHz · \(layout)"
    }

    func seconds(_ frame: Int64) -> Double { Double(frame) / sampleRate }
    func frame(_ seconds: Double) -> Int64 { Int64((seconds * sampleRate).rounded()) }

    /// `range` split at the file borders: each file it touches with the frames inside that file.
    func parts(of range: Range<Int64>) -> [(file: File, local: Range<Int64>)] {
        files.compactMap { file in
            let lower = max(range.lowerBound, file.start), upper = min(range.upperBound, file.start + file.length)
            return lower < upper ? (file, (lower - file.start)..<(upper - file.start)) : nil
        }
    }

    /// True if `url` is one of the files (exports must never overwrite them). Besides the path, the
    /// file itself is compared: on a case-insensitive volume "live.mp3" is "Live.MP3", and hard links
    /// share one file.
    func contains(_ url: URL) -> Bool {
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        if files.contains(where: { $0.url.standardizedFileURL.resolvingSymlinksInPath() == target }) { return true }
        guard let identity = AudioDocument.identity(of: url) else { return false }
        return files.contains { AudioDocument.identity(of: $0.url) == identity }
    }

    /// Volume and file number (symbolic links followed); nil if there is no such file.
    private static func identity(of url: URL) -> [Int64]? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return [Int64(info.st_dev), Int64(bitPattern: info.st_ino)]
    }
}

/// Tags of the source file, carried over into the exported MP3s.
struct SourceTags: Sendable, Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var artwork: Data?
}

/// Peak levels for drawing: minimum and maximum per block of frames (all channels together), in
/// several resolutions so that a zoomed-out view never has to scan millions of values.
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
    /// Highest absolute value in the file; the view scales the waveform to it.
    let peak: Float
    /// RMS of every block of the finest level (all channels together): how loud it sounds, for the
    /// pause finder. Without it, the peaks stand in.
    let rms: [Float]

    init(length: Int64, minimum: [Float], maximum: [Float], rms: [Float]? = nil) {
        self.length = length
        self.rms = rms ?? zip(minimum, maximum).map { max(-$0, $1) }
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

enum AudioError: LocalizedError {
    case unreadable(String)
    case empty(String)
    case mismatch(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): "„\(name)“ kann nicht gelesen werden. macOS unterstützt dieses Format nicht."
        case .empty(let name): "„\(name)“ enthält keinen Ton."
        case .mismatch(let name): "„\(name)“ passt nicht zu den anderen Dateien: andere Abtastrate oder Kanalzahl. Aneinanderhängen lassen sich nur Dateien im selben Format."
        }
    }
}

enum AudioLoader {
    /// Opens one file, or several files that are joined in the given order.
    static func open(_ urls: [URL]) throws -> AudioDocument {
        var files: [AudioDocument.File] = []
        var format: (rate: Double, channels: Int)?
        for url in urls {
            let file: AVAudioFile
            do {
                file = try AVAudioFile(forReading: url)
            } catch {
                throw AudioError.unreadable(url.lastPathComponent)
            }
            guard file.length > 0 else { throw AudioError.empty(url.lastPathComponent) }
            let rate = file.processingFormat.sampleRate, channels = Int(file.processingFormat.channelCount)
            if let format, format.rate != rate || format.channels != channels { throw AudioError.mismatch(url.lastPathComponent) }
            format = (rate, channels)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            files.append(AudioDocument.File(url: url, start: files.last.map { $0.start + $0.length } ?? 0, length: file.length, size: size))
        }
        guard let format else { throw AudioError.empty("") }
        return AudioDocument(files: files, sampleRate: format.rate, channels: format.channels)
    }

    static func open(_ url: URL) throws -> AudioDocument { try open([url]) }

    /// Decodes the whole recording and collects its peaks. Long recordings are decoded in parallel
    /// chunks, each with its own `AVAudioFile`. `progress` receives values from 0 to 1 from any thread.
    static func peaks(for document: AudioDocument, token: CancelToken,
                      progress: @escaping @Sendable (Double) -> Void) throws -> Peaks {
        let block = Int64(Peaks.baseBlock)
        let blocks = Int((document.length + block - 1) / block)
        var minimum = [Float](repeating: 0, count: blocks)
        var maximum = [Float](repeating: 0, count: blocks)
        var squares = [Float](repeating: 0, count: blocks)

        // Chunks of whole blocks, so that every block is filled by exactly one chunk.
        let parallel = document.duration > 60 ? min(8, max(1, ProcessInfo.processInfo.activeProcessorCount)) : 1
        let blocksPerChunk = (blocks + parallel - 1) / parallel
        let decoded = ProgressCounter()
        let errors = ErrorBox()

        minimum.withUnsafeMutableBufferPointer { minPointer in
            maximum.withUnsafeMutableBufferPointer { maxPointer in
              squares.withUnsafeMutableBufferPointer { squarePointer in
                let minBase = minPointer, maxBase = maxPointer, squareBase = squarePointer
                DispatchQueue.concurrentPerform(iterations: parallel) { chunk in
                    let firstBlock = chunk * blocksPerChunk
                    guard firstBlock < blocks else { return }
                    let start = Int64(firstBlock) * block
                    let end = min(document.length, Int64(min(blocks, firstBlock + blocksPerChunk)) * block)
                    do {
                        try decode(document, from: start, to: end, token: token) { buffer, position in
                            let samples = buffer.floatChannelData!
                            let channels = Int(buffer.format.channelCount)
                            let count = Int(buffer.frameLength)
                            // One run per block (a chunk may start or end in the middle of one).
                            var frame = 0
                            while frame < count {
                                let absolute = position + Int64(frame)
                                let index = Int(absolute / block)
                                let run = min(count - frame, Int(Int64(index + 1) * block - absolute))
                                var low: Float = 0, high: Float = 0, square: Float = 0
                                for channel in 0..<channels {
                                    var value: Float = 0
                                    vDSP_minv(samples[channel] + frame, 1, &value, vDSP_Length(run))
                                    low = min(low, value)
                                    vDSP_maxv(samples[channel] + frame, 1, &value, vDSP_Length(run))
                                    high = max(high, value)
                                    vDSP_svesq(samples[channel] + frame, 1, &value, vDSP_Length(run))
                                    square += value
                                }
                                if index < blocks {
                                    minBase[index] = min(minBase[index], low)
                                    maxBase[index] = max(maxBase[index], high)
                                    squareBase[index] += square
                                }
                                frame += run
                            }
                            let total = decoded.add(Int64(count))
                            progress(min(1, Double(total) / Double(document.length)))
                        }
                    } catch {
                        errors.set(error)
                        token.cancel()
                    }
                }
              }
            }
        }
        if let error = errors.error { throw error }
        if token.isCancelled { throw CancellationError() }
        let rms = squares.enumerated().map { index, sum in
            let frames = min(block, document.length - Int64(index) * block)
            return (sum / Float(max(1, frames * Int64(document.channels)))).squareRoot()
        }
        return Peaks(length: document.length, minimum: minimum, maximum: maximum, rms: rms)
    }

    /// Reads frames `start..<end` of the recording across its files; positions are those of the
    /// recording. See the single-file version.
    static func decode(_ document: AudioDocument, from start: Int64, to end: Int64, token: CancelToken,
                       chunkSize: AVAudioFrameCount = 65_536,
                       _ body: (AVAudioPCMBuffer, Int64) throws -> Void) throws {
        guard start < end else { return }
        for part in document.parts(of: start..<end) {
            try decode(part.file.url, from: part.local.lowerBound, to: part.local.upperBound, token: token,
                       chunkSize: chunkSize) { buffer, position in
                try body(buffer, part.file.start + position)
            }
        }
    }

    /// Reads frames `start..<end` as float samples (one array per channel) in chunks and hands each
    /// chunk to `body` together with the file position of its first frame. The buffer is reused, so
    /// `body` may change the samples in place.
    static func decode(_ url: URL, from start: Int64, to end: Int64, token: CancelToken,
                       chunkSize: AVAudioFrameCount = 65_536,
                       _ body: (AVAudioPCMBuffer, Int64) throws -> Void) throws {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkSize),
              buffer.floatChannelData != nil else { throw AudioError.unreadable(url.lastPathComponent) }
        file.framePosition = start
        var position = start
        while position < end {
            if token.isCancelled { throw CancellationError() }
            let wanted = AVAudioFrameCount(min(Int64(chunkSize), end - position))
            try file.read(into: buffer, frameCount: wanted)
            let count = Int64(buffer.frameLength)
            if count == 0 { break }
            try body(buffer, position)
            position += count
        }
    }

    /// Title, artist, album and cover of the source file (any of them may be missing).
    static func tags(for url: URL) async -> SourceTags {
        var tags = SourceTags()
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return tags }
        for item in items {
            switch item.commonKey {
            case .commonKeyTitle: tags.title = try? await item.load(.stringValue)
            case .commonKeyArtist: tags.artist = try? await item.load(.stringValue)
            case .commonKeyAlbumName: tags.album = try? await item.load(.stringValue)
            case .commonKeyArtwork: tags.artwork = try? await item.load(.dataValue)
            default: break
            }
        }
        return tags
    }
}

/// First error from parallel work.
final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?

    func set(_ error: Error) { lock.withLock { if stored == nil { stored = error } } }
    var error: Error? { lock.withLock { stored } }
}
