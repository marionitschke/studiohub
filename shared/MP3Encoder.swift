import CLame
import Foundation

enum MP3EncoderError: LocalizedError {
    case unavailable

    var errorDescription: String? { "Der MP3-Encoder konnte nicht gestartet werden." }
}

/// LAME, set to constant 320 kbit/s. The first frame of the output is a placeholder for the LAME tag
/// (encoder delay and padding, for gapless playback), which `lameTag()` returns once all audio is in.
final class MP3Encoder {
    static let bitrate: Int32 = 320

    private let lame: OpaquePointer
    private let outputRatio: Double
    private var buffer: [UInt8] = []

    init(sampleRate: Int, channels: Int) throws {
        guard let lame = lame_init() else { throw MP3EncoderError.unavailable }
        let outputRate = MP3Encoder.outputRate(for: sampleRate)
        lame_set_in_samplerate(lame, Int32(sampleRate))
        lame_set_out_samplerate(lame, Int32(outputRate))
        lame_set_num_channels(lame, channels == 1 ? 1 : 2)
        lame_set_mode(lame, channels == 1 ? MONO : JOINT_STEREO)
        lame_set_VBR(lame, vbr_off)
        lame_set_brate(lame, MP3Encoder.bitrate)
        lame_set_quality(lame, 3) // LAME's default; at 320 kbit/s as good as 2, but more than twice as fast
        lame_set_write_id3tag_automatic(lame, 0)
        lame_set_bWriteVbrTag(lame, 1)
        guard lame_init_params(lame) >= 0 else {
            lame_close(lame)
            throw MP3EncoderError.unavailable
        }
        self.lame = lame
        outputRatio = Double(outputRate) / Double(sampleRate)
    }

    deinit { lame_close(lame) }

    /// 320 kbit/s needs MPEG-1 (32, 44.1 or 48 kHz); other rates are resampled by LAME.
    static func outputRate(for sampleRate: Int) -> Int {
        if [32_000, 44_100, 48_000].contains(sampleRate) { return sampleRate }
        if sampleRate > 48_000 { return sampleRate % 44_100 == 0 ? 44_100 : 48_000 }
        return 44_100
    }

    /// Encodes `count` frames of float samples (-1…1). For mono, `right` is ignored.
    func encode(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) throws -> Data {
        // LAME's worst case is 1.25 bytes per output sample plus 7200 bytes.
        let capacity = Int(Double(count) * max(1, outputRatio) * 1.25) + 7200
        if buffer.count < capacity { buffer = [UInt8](repeating: 0, count: capacity) }
        let written = buffer.withUnsafeMutableBufferPointer {
            lame_encode_buffer_ieee_float(lame, left, right, Int32(count), $0.baseAddress, Int32(capacity))
        }
        guard written >= 0 else { throw MP3EncoderError.unavailable }
        return Data(buffer[0..<Int(written)])
    }

    /// Encodes what is still buffered and pads the last frame.
    func flush() throws -> Data {
        if buffer.count < 7200 { buffer = [UInt8](repeating: 0, count: 7200) }
        let size = Int32(buffer.count)
        let written = buffer.withUnsafeMutableBufferPointer { lame_encode_flush(lame, $0.baseAddress, size) }
        guard written >= 0 else { throw MP3EncoderError.unavailable }
        return Data(buffer[0..<Int(written)])
    }

    /// The finished LAME tag; it replaces the placeholder frame at the start of the MP3 data.
    func lameTag() -> Data {
        var frame = [UInt8](repeating: 0, count: 4096)
        let size = frame.withUnsafeMutableBufferPointer { lame_get_lametag_frame(lame, $0.baseAddress, 4096) }
        return size > 0 && size <= 4096 ? Data(frame[0..<size]) : Data()
    }
}
