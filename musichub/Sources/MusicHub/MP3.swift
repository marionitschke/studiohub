import AppKit
import Foundation

enum ExportError: LocalizedError {
    case encoder
    case notWritable(String)
    case overwritesSource

    var errorDescription: String? {
        switch self {
        case .encoder: "Der MP3-Encoder konnte nicht gestartet werden."
        case .notWritable(let folder): "In „\(folder)“ kann nicht geschrieben werden."
        case .overwritesSource: "Die Originaldatei kann nicht überschrieben werden. Bitte wähle einen anderen Namen oder Ordner."
        }
    }
}

/// ID3v2.3 tag with UTF-16 text (umlauts and every other character survive), an optional cover and
/// optional chapters (CHAP/CTOC, read by podcast players).
struct ID3Tag: Sendable, Equatable {
    struct Chapter: Sendable, Equatable {
        var title: String
        /// Milliseconds from the start of the audio.
        var start: UInt32
        var end: UInt32
    }

    /// More do not fit into the table of contents (one byte counts the entries).
    static let maximumChapters = 255

    var title: String?
    var artist: String?
    var album: String?
    var track: Int?
    var trackCount: Int?
    var artwork: Data?
    var chapters: [Chapter] = []

    func data() -> Data {
        var frames = Data()
        frames.append(ID3Tag.text("TIT2", title))
        frames.append(ID3Tag.text("TPE1", artist))
        frames.append(ID3Tag.text("TALB", album))
        if let track { frames.append(ID3Tag.text("TRCK", trackCount.map { "\(track)/\($0)" } ?? "\(track)")) }
        if let artwork, let mime = ID3Tag.imageType(artwork) {
            var body = Data([0x00])          // Latin-1 for the MIME type and description
            body.append(mime.data(using: .ascii)!)
            body.append(contentsOf: [0x00, 0x03, 0x00]) // end of MIME type, front cover, empty description
            body.append(artwork)
            frames.append(ID3Tag.frame("APIC", body))
        }
        let chapters = self.chapters.prefix(ID3Tag.maximumChapters)
        if !chapters.isEmpty {
            var toc = Data("toc".utf8) + [0x00]
            toc.append(contentsOf: [0x03, UInt8(chapters.count)]) // top level, ordered; number of entries
            for index in chapters.indices { toc.append(Data("ch\(index)".utf8) + [0x00]) }
            frames.append(ID3Tag.frame("CTOC", toc))
            for (index, chapter) in chapters.enumerated() {
                var body = Data("ch\(index)".utf8) + [0x00]
                for value in [chapter.start, chapter.end, UInt32.max, UInt32.max] { body.append(ID3Tag.bigEndian(value)) }
                body.append(ID3Tag.text("TIT2", chapter.title))
                frames.append(ID3Tag.frame("CHAP", body))
            }
        }
        var tag = Data("ID3".utf8)
        tag.append(contentsOf: [0x03, 0x00, 0x00])
        tag.append(ID3Tag.syncsafe(frames.count))
        tag.append(frames)
        return tag
    }

    /// A text frame (empty data for a missing value).
    private static func text(_ id: String, _ value: String?) -> Data {
        guard let value, !value.isEmpty else { return Data() }
        var body = Data([0x01, 0xFF, 0xFE]) // UTF-16 with byte order mark (little endian)
        body.append(value.data(using: .utf16LittleEndian) ?? Data())
        return frame(id, body)
    }

    private static func frame(_ id: String, _ body: Data) -> Data {
        var frame = Data(id.utf8)
        frame.append(bigEndian(UInt32(body.count)))
        frame.append(contentsOf: [0x00, 0x00])
        frame.append(body)
        return frame
    }

    private static func bigEndian(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    /// Tag sizes use 7 bits per byte.
    static func syncsafe(_ value: Int) -> Data {
        Data([UInt8(value >> 21 & 0x7F), UInt8(value >> 14 & 0x7F), UInt8(value >> 7 & 0x7F), UInt8(value & 0x7F)])
    }

    static func imageType(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        return nil
    }

    /// Chapters for parts joined one after another: each starts where the previous one ended.
    static func chapters(titles: [String], lengths: [Int64], sampleRate: Double) -> [Chapter] {
        var position: Int64 = 0
        return zip(titles, lengths).map { title, length in
            defer { position += length }
            let ms = { (frame: Int64) in UInt32(min(Double(UInt32.max - 1), (Double(frame) / sampleRate * 1000).rounded())) }
            return Chapter(title: title, start: ms(position), end: ms(position + length))
        }
    }
}

/// Cover images for ID3: JPEG and PNG up to 1400 pixels go in as they are, anything else is
/// converted to a JPEG of at most 1400 pixels.
enum Artwork {
    static let maximumSide = 1400

    static func prepare(_ data: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        let side = max(rep.pixelsWide, rep.pixelsHigh)
        if ID3Tag.imageType(data) != nil, side <= maximumSide { return data }
        let scale = min(1, Double(maximumSide) / Double(max(1, side)))
        let width = max(1, Int(Double(rep.pixelsWide) * scale)), height = max(1, Int(Double(rep.pixelsHigh) * scale))
        guard let target = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: target)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        rep.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.current?.flushGraphics()
        return target.representation(using: .jpeg, properties: [.compressionFactor: 0.88])
    }
}
