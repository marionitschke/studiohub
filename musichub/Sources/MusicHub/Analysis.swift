import Accelerate
import Foundation

/// Finds quiet passages – the pauses between the pieces of a live recording – in the waveform data.
/// The level is the RMS over about 100 ms, so that room noise with single louder samples still
/// counts as quiet and a lone clap does not split a pause.
enum PauseFinder {
    /// Blocks on each side of a block that its level is averaged over (8 × 256 frames ≈ 46 ms).
    static let smoothing = 8

    /// Ranges where the level stays below `thresholdDB` (dBFS RMS) for at least `minimumFrames`.
    /// Quiet stretches separated by at most `bridgeFrames` of something louder (a clap, a cough)
    /// count as one. Silence at the very start or end of the recording is not a pause.
    static func pauses(in peaks: Peaks, thresholdDB: Double, minimumFrames: Int64, bridgeFrames: Int64 = 0) -> [Range<Int64>] {
        let block = Int64(peaks.levels[0].block)
        let count = peaks.rms.count
        // Running sums of the squares, for the average over a window around each block.
        var sums = [Double](repeating: 0, count: count + 1)
        for (i, value) in peaks.rms.enumerated() { sums[i + 1] = sums[i] + Double(value * value) }
        let limit = pow(10, thresholdDB / 10)
        var runs: [Range<Int>] = []
        var runStart: Int?
        for index in 0...count {
            var quiet = false
            if index < count {
                let from = max(0, index - smoothing), to = min(count, index + smoothing + 1)
                quiet = (sums[to] - sums[from]) / Double(to - from) < limit
            }
            if quiet {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                runStart = nil
                if let last = runs.last, Int64(start - last.upperBound) * block <= bridgeFrames {
                    runs[runs.count - 1] = last.lowerBound..<index
                } else {
                    runs.append(start..<index)
                }
            }
        }
        return runs.map { Int64($0.lowerBound) * block..<min(peaks.length, Int64($0.upperBound) * block) }
            .filter { $0.count >= minimumFrames && $0.lowerBound > 0 && $0.upperBound < peaks.length }
    }

    /// Where to cut: in the middle of every pause that does not already contain a cut.
    static func cuts(for pauses: [Range<Int64>], existing: [Int64]) -> [Int64] {
        pauses.filter { pause in !existing.contains { pause.contains($0) } }
            .map { $0.lowerBound + Int64($0.count) / 2 }
    }
}

/// Integrated loudness after ITU-R BS.1770-4 (the measure behind EBU R128 and the level the
/// streaming services play at): K-weighting, 400 ms blocks with 75 % overlap, absolute gate at
/// −70 LUFS and relative gate 10 LU below. Also keeps the sample peak. Not thread-safe; one meter
/// per export.
final class LoudnessMeter {
    /// What the export is brought to, as Spotify and YouTube play music.
    static let target = -14.0
    /// Highest sample peak a raised file may reach (dBFS), so that the MP3 does not clip.
    static let ceiling = -1.0

    private let channels: Int
    /// Frames per 100 ms; four of them form one measuring block.
    private let hop: Int
    private let setup: vDSP_biquad_Setup
    private var delays: [[Float]]
    private var filtered: [Float] = []
    /// Sum of the squared K-weighted samples of all channels per 100 ms.
    private var subBlocks: [Double] = []
    private var current = 0.0
    private var filled = 0
    private(set) var peak: Float = 0

    init(sampleRate: Double, channels: Int) {
        self.channels = channels
        hop = max(1, Int((sampleRate / 10).rounded()))
        setup = vDSP_biquad_CreateSetup(LoudnessMeter.coefficients(sampleRate: sampleRate), 2)!
        delays = Array(repeating: [Float](repeating: 0, count: 6), count: channels)
    }

    deinit { vDSP_biquad_DestroySetup(setup) }

    /// The two K-weighting stages (high shelf, then high pass) for any sample rate, as b0 b1 b2 a1 a2.
    static func coefficients(sampleRate: Double) -> [Double] {
        var f0 = 1681.974450955533, q = 0.7071752369554196
        var k = tan(Double.pi * f0 / sampleRate)
        let vh = pow(10, 3.999843853973347 / 20), vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        let shelf = [(vh + vb * k / q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0,
                     2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0]
        f0 = 38.13547087602444
        q = 0.5003270373238773
        k = tan(Double.pi * f0 / sampleRate)
        a0 = 1 + k / q + k * k
        let highPass = [1, -2, 1, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0]
        return shelf + highPass
    }

    /// Adds `count` frames (one array per channel).
    func add(_ samples: UnsafePointer<UnsafeMutablePointer<Float>>, count: Int) {
        guard count > 0 else { return }
        if filtered.count < count { filtered = [Float](repeating: 0, count: count) }
        // Pieces of this chunk per 100 ms sub-block: the first one completes the open sub-block.
        var bounds = [0]
        var position = min(count, hop - filled)
        while true {
            bounds.append(position)
            if position >= count { break }
            position = min(count, position + hop)
        }
        var sums = [Double](repeating: 0, count: bounds.count - 1)
        for channel in 0..<channels {
            var level: Float = 0
            vDSP_maxmgv(samples[channel], 1, &level, vDSP_Length(count))
            peak = max(peak, level)
            filtered.withUnsafeMutableBufferPointer { output in
                delays[channel].withUnsafeMutableBufferPointer { delay in
                    vDSP_biquad(setup, delay.baseAddress!, samples[channel], 1, output.baseAddress!, 1, vDSP_Length(count))
                }
                for i in sums.indices {
                    var sum: Float = 0
                    vDSP_svesq(output.baseAddress! + bounds[i], 1, &sum, vDSP_Length(bounds[i + 1] - bounds[i]))
                    sums[i] += Double(sum)
                }
            }
        }
        for (i, sum) in sums.enumerated() {
            current += sum
            filled += bounds[i + 1] - bounds[i]
            if filled == hop {
                subBlocks.append(current)
                current = 0
                filled = 0
            }
        }
    }

    /// Integrated loudness in LUFS; nil for silence.
    var integrated: Double? {
        var blocks: [Double] = []
        if subBlocks.count >= 4 {
            let frames = Double(4 * hop)
            for j in 0...(subBlocks.count - 4) {
                blocks.append((subBlocks[j] + subBlocks[j + 1] + subBlocks[j + 2] + subBlocks[j + 3]) / frames)
            }
        } else {
            // Shorter than one block: measured as a whole.
            let frames = subBlocks.count * hop + filled
            guard frames > 0 else { return nil }
            blocks = [(subBlocks.reduce(0, +) + current) / Double(frames)]
        }
        func lufs(_ z: Double) -> Double { -0.691 + 10 * log10(z) }
        let audible = blocks.filter { $0 > 0 && lufs($0) > -70 }
        guard !audible.isEmpty else { return nil }
        let relative = lufs(audible.reduce(0, +) / Double(audible.count)) - 10
        let gated = audible.filter { lufs($0) > relative }
        return lufs(gated.reduce(0, +) / Double(max(1, gated.count)))
    }

    /// Gain that brings the audio to `target`. Raising stops where the peak would pass `ceiling`;
    /// audio that is already louder is lowered.
    func gain(target: Double = LoudnessMeter.target, ceiling: Double = LoudnessMeter.ceiling) -> Float {
        guard let loudness = integrated, peak > 0 else { return 1 }
        let wanted = pow(10, (target - loudness) / 20)
        guard wanted > 1 else { return Float(wanted) }
        let limit = pow(10, ceiling / 20) / Double(peak)
        return Float(max(1, min(wanted, limit)))
    }
}
