import AVFoundation
import Foundation

/// Integrated loudness after ITU-R BS.1770-4 / EBU R128: K-weighted mean square over 400 ms blocks
/// (75 % overlap), gated at −70 LUFS and 10 LU below the ungated mean. Fed with float PCM.
struct LoudnessMeter {
    /// One second-order section in transposed direct form II.
    private struct Biquad {
        var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
        var z1 = 0.0, z2 = 0.0

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    private var shelves: [Biquad]
    private var highPasses: [Biquad]
    /// A mono track plays on both speakers: it counts twice (dual mono), like the same sound in stereo.
    private let weight: Double
    /// 100 ms; a block is four of them.
    private let subBlock: Int
    private var inSubBlock = 0
    private var energy = 0.0
    private var subBlocks: [Double] = []
    /// Highest absolute sample value.
    private(set) var peak: Float = 0

    init(sampleRate: Double, channels: Int) {
        // The filters of BS.1770 for any sample rate (as derived in libebur128; exact at 48 kHz).
        var k = tan(Double.pi * 1681.974450955533 / sampleRate)
        var q = 0.7071752369554196
        let vh = pow(10, 3.999843853973347 / 20), vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        let shelf = Biquad(b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0, b2: (vh - vb * k / q + k * k) / a0,
                           a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        k = tan(Double.pi * 38.13547087602444 / sampleRate)
        q = 0.5003270373238773
        a0 = 1 + k / q + k * k
        let highPass = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        let count = max(1, channels)
        shelves = Array(repeating: shelf, count: count)
        highPasses = Array(repeating: highPass, count: count)
        weight = count == 1 ? 2 : 1
        subBlock = max(1, Int((sampleRate * 0.1).rounded()))
    }

    mutating func add(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let channels = min(Int(buffer.format.channelCount), shelves.count)
        for frame in 0..<Int(buffer.frameLength) {
            for channel in 0..<channels {
                let x = data[channel][frame]
                peak = max(peak, abs(x))
                let y = highPasses[channel].process(shelves[channel].process(Double(x)))
                energy += y * y
            }
            inSubBlock += 1
            if inSubBlock == subBlock {
                subBlocks.append(energy * weight)
                energy = 0
                inSubBlock = 0
            }
        }
    }

    /// LUFS; nil for silence or less than 400 ms of sound.
    var integrated: Double? {
        guard subBlocks.count >= 4 else { return nil }
        let frames = Double(4 * subBlock)
        var blocks: [Double] = []
        blocks.reserveCapacity(subBlocks.count - 3)
        var sum = subBlocks[0] + subBlocks[1] + subBlocks[2]
        for index in 3..<subBlocks.count {
            sum += subBlocks[index]
            blocks.append(sum / frames)
            sum -= subBlocks[index - 3]
        }
        func lufs(_ meanSquare: Double) -> Double { -0.691 + 10 * log10(meanSquare) }
        func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(values.count) }
        let audible = blocks.filter { $0 > 0 && lufs($0) > -70 }
        guard !audible.isEmpty else { return nil }
        let relativeGate = lufs(mean(audible)) - 10
        let gated = audible.filter { lufs($0) > relativeGate }
        return lufs(mean(gated.isEmpty ? audible : gated))
    }
}

/// Brings sound to a loudness: a fixed gain, a DC blocker (old tapes often have an offset) and a
/// look-ahead limiter that keeps every sample below the ceiling. The limiter reacts 5 ms early with
/// a linear ramp and recovers over 150 ms, so the gain never drops in a jump. The output lags the
/// input by the look-ahead; `flush()` returns the rest, so in the end every frame comes out once.
final class LoudnessNormalizer {
    let gain: Float
    let ceiling: Float
    private let channels: Int
    private let lookahead: Int
    private let release: Float
    private let dcPole: Float
    private let delay: UnsafeMutablePointer<Float>
    private let averages: UnsafeMutablePointer<Float>
    private let queueIndex: UnsafeMutablePointer<Int>
    private let queueValue: UnsafeMutablePointer<Float>
    private var queueHead = 0, queueCount = 0
    private var averageSum: Double
    private var envelope: Float = 1
    private var dcInput: [Float]
    private var dcOutput: [Float]
    private var position = 0
    /// Highest absolute value written, after limiting.
    private(set) var peak: Float = 0
    /// Lowest gain reduction of the limiter (1: never limited).
    private(set) var deepestReduction: Float = 1

    init(gain: Float, ceiling: Float, sampleRate: Double, channels: Int) {
        self.gain = gain
        self.ceiling = ceiling
        self.channels = max(1, channels)
        lookahead = max(1, Int((sampleRate * 0.005).rounded()))
        release = Float(exp(-1 / (0.15 * sampleRate)))
        dcPole = Float(1 - 2 * Double.pi * 5 / sampleRate)
        let window = lookahead + 1
        delay = .allocate(capacity: window * self.channels)
        delay.initialize(repeating: 0, count: window * self.channels)
        averages = .allocate(capacity: window)
        averages.initialize(repeating: 1, count: window)
        averageSum = Double(window)
        queueIndex = .allocate(capacity: window + 1)
        queueIndex.initialize(repeating: 0, count: window + 1)
        queueValue = .allocate(capacity: window + 1)
        queueValue.initialize(repeating: 1, count: window + 1)
        dcInput = Array(repeating: 0, count: self.channels)
        dcOutput = Array(repeating: 0, count: self.channels)
    }

    deinit {
        delay.deallocate()
        averages.deallocate()
        queueIndex.deallocate()
        queueValue.deallocate()
    }

    /// Processes `input` into `output` (same format, at least the same capacity); sets and returns the
    /// number of frames written – fewer than read at the very start.
    @discardableResult
    func process(_ input: AVAudioPCMBuffer, into output: AVAudioPCMBuffer) -> Int {
        guard let source = input.floatChannelData, let target = output.floatChannelData else {
            output.frameLength = 0
            return 0
        }
        var written = 0
        for frame in 0..<Int(input.frameLength) {
            if step({ source[min($0, Int(input.format.channelCount) - 1)][frame] }, target, written) { written += 1 }
        }
        output.frameLength = AVAudioFrameCount(written)
        return written
    }

    /// The frames still held back for the look-ahead; `output` needs room for `lookahead` frames.
    @discardableResult
    func flush(into output: AVAudioPCMBuffer) -> Int {
        guard let target = output.floatChannelData else { return 0 }
        var written = 0
        for _ in 0..<lookahead where step({ _ in 0 }, target, written) { written += 1 }
        output.frameLength = AVAudioFrameCount(written)
        return written
    }

    var flushCapacity: Int { lookahead }

    /// One frame in; true when one frame came out (at `slot` of `target`).
    private func step(_ sample: (Int) -> Float, _ target: UnsafePointer<UnsafeMutablePointer<Float>>, _ slot: Int) -> Bool {
        let window = lookahead + 1
        let writeSlot = position % window
        var loudest: Float = 0
        for channel in 0..<channels {
            let x = sample(channel) * gain
            let y = x - dcInput[channel] + dcPole * dcOutput[channel]
            dcInput[channel] = x
            dcOutput[channel] = y
            delay[channel * window + writeSlot] = y
            loudest = max(loudest, abs(y))
        }
        // The gain this frame may have at most, then the minimum over the look-ahead window
        // (a monotonic queue), then its moving average: a ramp that is down when the peak arrives.
        let allowed = loudest > ceiling ? ceiling / loudest : 1
        let capacity = window + 1
        while queueCount > 0, queueValue[(queueHead + queueCount - 1) % capacity] >= allowed { queueCount -= 1 }
        queueIndex[(queueHead + queueCount) % capacity] = position
        queueValue[(queueHead + queueCount) % capacity] = allowed
        queueCount += 1
        while queueIndex[queueHead] < position - lookahead {
            queueHead = (queueHead + 1) % capacity
            queueCount -= 1
        }
        let minimum = queueValue[queueHead]
        averageSum += Double(minimum) - Double(averages[writeSlot])
        averages[writeSlot] = minimum
        if position % 65_536 == 0 {
            averageSum = (0..<window).reduce(0) { $0 + Double(averages[$1]) }
        }
        let smooth = Float(averageSum / Double(window))
        envelope = smooth < envelope ? smooth : envelope + (smooth - envelope) * (1 - release)
        deepestReduction = min(deepestReduction, envelope)

        defer { position += 1 }
        guard position >= lookahead else { return false }
        let readSlot = (position - lookahead) % window
        for channel in 0..<channels {
            let value = delay[channel * window + readSlot] * envelope
            target[channel][slot] = value
            peak = max(peak, abs(value))
        }
        return true
    }
}

/// The batch's sound treatment: measures the loudness of the whole sound, then writes it at the
/// target loudness, limited below the ceiling, as Apple Lossless (the export encodes it as AAC).
enum SoundNormalizer {
    /// −16 LUFS: the level of Apple's media apps and podcasts; ceiling −1.5 dBFS leaves room for AAC.
    static let target = -16.0
    static let ceiling = -1.5
    /// Quiet recordings get at most this much louder (beyond that it is mostly noise).
    static let maximumBoost = 20.0

    struct Result: Equatable, Sendable {
        /// The loudness before, in LUFS (nil: silence).
        var measured: Double?
        /// The gain in dB.
        var gain: Double
        /// Peak after normalising, in dBFS.
        var peak: Double
        /// How far the limiter went down at most, in dB (0: not at all).
        var limited: Double
    }

    static func decibels(_ value: Float) -> Double { value > 0 ? 20 * log10(Double(value)) : -.infinity }

    /// nil when the video has no sound. `progress` runs 0…1 over both passes.
    static func normalize(_ document: VideoDocument, to url: URL, token: CancelToken,
                          progress: @escaping (Double) -> Void) async throws -> Result? {
        let composition = try Composer.composition(document, ranges: [document.bounds], video: false)
        guard !composition.tracks(withMediaType: .audio).isEmpty, let asset = composition.copy() as? AVComposition else { return nil }
        let rate = document.audioSampleRate, channels = min(2, document.audioChannels)

        var meter = LoudnessMeter(sampleRate: rate, channels: channels)
        try await Exporter.readPCM(asset, sampleRate: rate, channels: channels, token: token, progress: { progress($0 * 0.4) }) {
            meter.add($0)
        }
        let measured = meter.integrated
        let gain = measured.map { min(maximumBoost, target - $0) } ?? 0
        let normalizer = LoudnessNormalizer(gain: Float(pow(10, gain / 20)), ceiling: Float(pow(10, ceiling / 20)),
                                            sampleRate: rate, channels: channels)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                         channels: AVAudioChannelCount(channels), interleaved: false) else { throw ExportError.encoder }
        do {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatAppleLossless,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitDepthHintKey: 24,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            var output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)
            try await Exporter.readPCM(asset, sampleRate: rate, channels: channels, token: token,
                                       progress: { progress(0.4 + $0 * 0.6) }) { buffer in
                if output == nil || output!.frameCapacity < buffer.frameLength {
                    output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength)
                }
                guard let output else { throw ExportError.encoder }
                if normalizer.process(buffer, into: output) > 0 { try file.write(from: output) }
            }
            guard let tail = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(normalizer.flushCapacity)) else {
                throw ExportError.encoder
            }
            if normalizer.flush(into: tail) > 0 { try file.write(from: tail) }
            file.close()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return Result(measured: measured, gain: gain, peak: decibels(normalizer.peak), limited: -decibels(normalizer.deepestReduction))
    }
}
