import AVFoundation
import Foundation

/// Plays ranges of the recording one after another (a track plays as it will be exported). A
/// recording of several files is scheduled file by file.
@MainActor
final class Player {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var document: AudioDocument?
    private var files: [AVAudioFile] = []
    /// What was scheduled at the last start, in order (positions of the recording).
    private var schedule: [Range<Int64>] = []
    private var generation = 0
    private var configurationObserver: NSObjectProtocol?

    /// Called with the final position when the last scheduled part has played to the end, or when
    /// playback stopped because the output device changed.
    var onStop: ((Int64?) -> Void)?
    private(set) var isPlaying = false
    /// Volume for the fades (0…1).
    var gain: Float = 1 {
        didSet { node.volume = gain }
    }

    init() {
        engine.attach(node)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            // Headphones plugged in or out: the engine has stopped by itself.
            MainActor.assumeIsolated { self?.handleConfigurationChange() }
        }
    }

    func load(_ document: AudioDocument) throws {
        stop()
        let files = try document.urls.map { try AVAudioFile(forReading: $0) }
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: engine.mainMixerNode, format: files[0].processingFormat)
        self.files = files
        self.document = document
    }

    /// Starts at `frame` and plays every range from there on. A position between two ranges starts
    /// at the next one. Returns false if nothing is left to play.
    @discardableResult
    func play(from frame: Int64, ranges: [Range<Int64>]) -> Bool {
        stop()
        guard let document, !files.isEmpty else { return false }
        // Split at the file borders: every piece is played from its own file.
        var parts: [(range: Range<Int64>, file: Int, local: Range<Int64>)] = []
        for range in ranges where range.upperBound > frame {
            let from = max(range.lowerBound, frame)
            for (index, file) in document.files.enumerated() {
                let lower = max(from, file.start), upper = min(range.upperBound, file.start + file.length)
                if lower < upper { parts.append((lower..<upper, index, (lower - file.start)..<(upper - file.start))) }
            }
        }
        guard !parts.isEmpty else { return false }

        if !engine.isRunning {
            do { try engine.start() } catch { return false }
        }
        generation += 1
        let current = generation
        for (i, part) in parts.enumerated() {
            let pieces = Player.pieces(of: part.local)
            for (j, piece) in pieces.enumerated() {
                let isLast = i == parts.count - 1 && j == pieces.count - 1
                node.scheduleSegment(files[part.file], startingFrame: piece.lowerBound, frameCount: AVAudioFrameCount(piece.count),
                                     at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    guard isLast else { return }
                    Task { @MainActor in self?.finished(current) }
                }
            }
        }
        schedule = parts.map(\.range)
        node.play()
        isPlaying = true
        return true
    }

    /// `range` in pieces a segment can be scheduled with: its frame count has 32 bits, which a long
    /// recording passes (27 hours at 44.1 kHz, 6 hours at 192 kHz).
    nonisolated static func pieces(of range: Range<Int64>, maximum: Int64 = Int64(AVAudioFrameCount.max)) -> [Range<Int64>] {
        stride(from: range.lowerBound, to: range.upperBound, by: Int(maximum)).map { $0..<min($0 + maximum, range.upperBound) }
    }

    /// Stops and returns the position where playback was.
    @discardableResult
    func stop() -> Int64? {
        let position = self.position
        generation += 1
        if isPlaying || node.isPlaying { node.stop() }
        isPlaying = false
        gain = 1
        schedule = []
        return position
    }

    /// Current position in the recording, mapped through the schedule (the player only counts the
    /// frames it has played since the start).
    var position: Int64? {
        guard isPlaying, let nodeTime = node.lastRenderTime, let playerTime = node.playerTime(forNodeTime: nodeTime) else {
            return nil
        }
        var played = max(0, playerTime.sampleTime)
        for part in schedule {
            if played < Int64(part.count) { return part.lowerBound + played }
            played -= Int64(part.count)
        }
        return schedule.last?.upperBound
    }

    private func finished(_ current: Int) {
        guard current == generation, isPlaying else { return }
        let end = schedule.last?.upperBound
        isPlaying = false
        schedule = []
        onStop?(end)
    }

    private func handleConfigurationChange() {
        guard isPlaying else { return }
        onStop?(stop())
    }
}
