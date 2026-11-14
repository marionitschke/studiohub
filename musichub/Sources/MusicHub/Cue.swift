import Foundation

/// Cue sheets: the track list with start times that comes with many DJ sets and CD rips. MusicHub
/// reads them into cuts with names and writes one next to an exported MP3.
struct CueSheet: Equatable, Sendable {
    struct Track: Equatable, Sendable {
        var title = ""
        var performer: String?
        /// Start in seconds from the beginning of its file.
        var start: Double = 0
        /// The FILE the track belongs to, as written in the sheet.
        var file: String?
    }

    var title: String?
    var performer: String?
    var files: [String] = []
    var tracks: [Track] = []

    // MARK: Reading

    /// Real cue sheets have a few kilobytes; a much bigger file is not one and is not read into memory.
    static let maximumSize = 4 << 20

    static func read(_ url: URL) throws -> CueSheet {
        if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maximumSize {
            throw CocoaError(.fileReadTooLarge)
        }
        let data = try Data(contentsOf: url)
        // UTF-8 (with or without BOM) or UTF-16 with BOM (EAC's "Unicode"); older sheets are often Windows-1252.
        let utf16 = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
        let text = (utf16 ? String(data: data, encoding: .utf16) : nil) ?? String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
        return parse(text)
    }

    static func parse(_ text: String) -> CueSheet {
        var sheet = CueSheet()
        var track: Track?
        var file: String?
        func finishTrack() {
            if let track { sheet.tracks.append(track) }
            track = nil
        }
        for rawLine in text.replacingOccurrences(of: "\u{FEFF}", with: "").components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let space = line.firstIndex(of: " ") else { continue }
            let command = line[..<space].uppercased()
            let rest = String(line[line.index(after: space)...]).trimmingCharacters(in: .whitespaces)
            switch command {
            case "FILE":
                finishTrack()
                file = quoted(rest)
                if let file { sheet.files.append(file) }
            case "TRACK":
                finishTrack()
                track = Track(file: file)
            case "TITLE":
                if track != nil { track?.title = quoted(rest) ?? "" } else { sheet.title = quoted(rest) }
            case "PERFORMER":
                if track != nil { track?.performer = quoted(rest) } else { sheet.performer = quoted(rest) }
            case "INDEX":
                let parts = rest.split(separator: " ")
                if parts.count == 2, parts[0] == "01", let seconds = seconds(String(parts[1])) { track?.start = seconds }
            default:
                break
            }
        }
        finishTrack()
        return sheet
    }

    /// The text in quotes, or the first word if there are none (`FILE "a b.wav" WAVE` → `a b.wav`).
    private static func quoted(_ text: String) -> String? {
        if text.hasPrefix("\""), let end = text.dropFirst().lastIndex(of: "\"") {
            let value = String(text[text.index(after: text.startIndex)..<end])
            return value.isEmpty ? nil : value
        }
        let word = text.split(separator: " ").first.map(String.init)
        return word?.isEmpty == false ? word : nil
    }

    /// "mm:ss:ff" (75 frames per second; minutes may pass 99) in seconds. Negative values and minutes
    /// far beyond any recording are refused: they would overflow when turned into frames.
    static func seconds(_ timestamp: String) -> Double? {
        let parts = timestamp.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3, (0...1_000_000).contains(parts[0]), (0..<60).contains(parts[1]),
              (0..<75).contains(parts[2]) else { return nil }
        return Double(parts[0] * 60 + parts[1]) + Double(parts[2]) / 75
    }

    static func timestamp(_ seconds: Double) -> String {
        let frames = Int((max(0, seconds) * 75).rounded())
        return String(format: "%02d:%02d:%02d", frames / 75 / 60, frames / 75 % 60, frames % 75)
    }

    /// Name for the part of a track: "Performer – Title" when it has its own performer.
    func name(of track: Track) -> String {
        let title = track.title.trimmingCharacters(in: .whitespaces)
        guard let performer = track.performer?.trimmingCharacters(in: .whitespaces), !performer.isEmpty,
              performer != self.performer else { return title }
        return title.isEmpty ? performer : "\(performer) – \(title)"
    }

    /// The tracks as an edit of `document`: a cut at the start of every track, named after it.
    /// With several FILE entries, each is matched to the document's file of the same name.
    func edit(for document: AudioDocument, minimumLength: Int64) -> EditList? {
        var marks: [(frame: Int64, name: String)] = []
        for track in tracks {
            var offset: Int64 = 0
            if files.count > 1, let file = track.file {
                let wanted = CueSheet.baseName(file)
                guard let match = document.files.first(where: { CueSheet.baseName($0.url.lastPathComponent) == wanted }) else { continue }
                offset = match.start
            }
            let frame = offset + document.frame(track.start)
            if frame < document.length { marks.append((frame, name(of: track))) }
        }
        guard !marks.isEmpty else { return nil }
        var edit = EditList(length: document.length)
        edit.cut(at: marks.map(\.frame).filter { $0 > 0 }, minimumLength: minimumLength)
        for mark in marks {
            let segment = edit.segment(at: mark.frame)
            if segment.start == mark.frame, !mark.name.isEmpty { edit.rename(segment.id, to: mark.name) }
        }
        return edit
    }

    private static func baseName(_ file: String) -> String {
        ((file.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent as NSString)
            .deletingPathExtension.lowercased()
    }

    // MARK: Writing

    /// A sheet for one MP3 whose parts follow each other: `starts` in seconds from its beginning.
    static func text(file: String, title: String?, performer: String?, tracks: [(title: String, start: Double)]) -> String {
        func value(_ text: String) -> String {
            let line = text.replacingOccurrences(of: "\"", with: "'").components(separatedBy: .newlines).joined(separator: " ")
            return "\"" + line + "\""
        }
        var lines: [String] = []
        if let performer, !performer.isEmpty { lines.append("PERFORMER \(value(performer))") }
        if let title, !title.isEmpty { lines.append("TITLE \(value(title))") }
        lines.append("FILE \(value(file)) MP3")
        for (index, track) in tracks.enumerated() {
            lines.append(String(format: "  TRACK %02d AUDIO", index + 1))
            lines.append("    TITLE \(value(track.title))")
            if let performer, !performer.isEmpty { lines.append("    PERFORMER \(value(performer))") }
            lines.append("    INDEX 01 \(timestamp(track.start))")
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}
