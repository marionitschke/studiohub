import Foundation

/// One part of the file between two cuts. Positions are sample frames of the source file.
struct Segment: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var start: Int64
    var end: Int64
    /// Track (1…3) the part is exported with.
    var track = 1
    /// Deleted parts are on no track: not exported and skipped in playback. They keep their track,
    /// so that they can be restored where they were.
    var deleted = false
    var name = ""
    /// Fade-in and fade-out length in frames (together never longer than the part).
    var fadeIn: Int64 = 0
    var fadeOut: Int64 = 0

    var length: Int64 { end - start }
    func contains(_ frame: Int64) -> Bool { frame >= start && frame < end }

    /// Volume of the part's own fades at `frame` (1 outside them).
    func fadeGain(at frame: Int64) -> Float {
        Fade.gain(at: frame, range: start..<end, fadeIn: fadeIn, fadeOut: fadeOut)
    }

    /// Shortens the fades if the part got too short for them.
    mutating func clampFades() {
        fadeIn = min(max(0, fadeIn), length)
        fadeOut = min(max(0, fadeOut), length - fadeIn)
    }
}

extension Segment {
    private enum CodingKeys: String, CodingKey {
        case id, start, end, track, deleted, name, fadeIn, fadeOut
    }

    /// Missing fields (from older stored edits) get their defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        start = try container.decode(Int64.self, forKey: .start)
        end = try container.decode(Int64.self, forKey: .end)
        track = try container.decodeIfPresent(Int.self, forKey: .track) ?? 1
        deleted = try container.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        fadeIn = try container.decodeIfPresent(Int64.self, forKey: .fadeIn) ?? 0
        fadeOut = try container.decodeIfPresent(Int64.self, forKey: .fadeOut) ?? 0
    }
}

enum FadeEdge: Sendable {
    case fadeIn, fadeOut
}

enum Fade {
    /// S-curve from 0 to 1: starts and ends softly.
    static func curve(_ t: Double) -> Float {
        Float(0.5 - 0.5 * cos(Double.pi * min(max(t, 0), 1)))
    }

    /// Volume at `frame` for fades at the start and end of `range`.
    static func gain(at frame: Int64, range: Range<Int64>, fadeIn: Int64, fadeOut: Int64) -> Float {
        var gain: Float = 1
        if fadeIn > 0, frame < range.lowerBound + fadeIn {
            gain *= curve(Double(frame - range.lowerBound) / Double(fadeIn))
        }
        if fadeOut > 0, frame >= range.upperBound - fadeOut {
            gain *= curve(Double(range.upperBound - frame - 1) / Double(fadeOut))
        }
        return gain
    }
}

/// The edit of one file: segments that cover it from 0 to `length` without gaps or overlaps, each
/// on one of three tracks or deleted. Every track can be exported on its own.
struct EditList: Equatable, Codable, Sendable {
    static let tracks = 1...3

    private(set) var segments: [Segment]
    let length: Int64

    init(length: Int64) {
        self.length = length
        segments = [Segment(start: 0, end: length)]
    }

    /// Restores stored segments, or starts over if they do not cover exactly `length`.
    init(length: Int64, segments stored: [Segment]) {
        self.init(length: length)
        guard let first = stored.first, first.start == 0, stored.last?.end == length else { return }
        for (a, b) in zip(stored, stored.dropFirst()) where a.end != b.start { return }
        guard stored.allSatisfy({
            $0.length > 0 && EditList.tracks.contains($0.track) && $0.fadeIn >= 0 && $0.fadeOut >= 0
                && $0.fadeIn <= $0.length - $0.fadeOut
        }) else { return }
        segments = stored
    }

    /// Positions of the cuts (the start of every segment but the first).
    var cuts: [Int64] { segments.dropFirst().map(\.start) }

    var hasEdits: Bool {
        segments.count > 1 || segments.contains { $0.track != 1 || $0.deleted || !$0.name.isEmpty || $0.fadeIn > 0 || $0.fadeOut > 0 }
    }

    /// Index of the segment containing `frame`; the end of the file belongs to the last one.
    func index(at frame: Int64) -> Int {
        var low = 0, high = segments.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if segments[mid].start <= frame { low = mid } else { high = mid - 1 }
        }
        return low
    }

    func segment(at frame: Int64) -> Segment { segments[index(at: frame)] }

    /// Splits the segment at `frame`. Both halves stay on the same track (or deleted); the name and the fade-in
    /// stay on the left, the fade-out goes with the right half.
    /// Fails if either half would be shorter than `minimumLength`.
    @discardableResult
    mutating func cut(at frame: Int64, minimumLength: Int64) -> Bool {
        let i = index(at: frame)
        let old = segments[i]
        guard frame - old.start >= minimumLength, old.end - frame >= minimumLength else { return false }
        segments[i].end = frame
        segments[i].fadeOut = 0
        segments[i].clampFades()
        var right = Segment(start: frame, end: old.end, track: old.track, deleted: old.deleted, fadeOut: old.fadeOut)
        right.clampFades()
        segments.insert(right, at: i + 1)
        return true
    }

    /// Removes cut number `cutIndex` (between segment `cutIndex` and `cutIndex + 1`) and joins both.
    /// The joined part stays on the left track and keeps the outer fades; the left name wins unless
    /// it is empty. If only the left part is deleted, the right one wins, so that joining never
    /// deletes audio that was kept.
    mutating func removeCut(_ cutIndex: Int) {
        guard cutIndex >= 0, cutIndex + 1 < segments.count else { return }
        let left = segments[cutIndex]
        let right = segments.remove(at: cutIndex + 1)
        let (winner, other) = left.deleted && !right.deleted ? (right, left) : (left, right)
        segments[cutIndex].end = right.end
        segments[cutIndex].fadeOut = right.fadeOut
        segments[cutIndex].track = winner.track
        segments[cutIndex].deleted = winner.deleted
        segments[cutIndex].name = winner.name.isEmpty ? other.name : winner.name
    }

    /// Moves cut number `cutIndex`, clamped so that both neighbours stay at least `minimumLength` long.
    mutating func moveCut(_ cutIndex: Int, to frame: Int64, minimumLength: Int64) {
        guard cutIndex >= 0, cutIndex + 1 < segments.count else { return }
        let low = segments[cutIndex].start + minimumLength
        let high = segments[cutIndex + 1].end - minimumLength
        guard low <= high else { return }
        let position = min(max(frame, low), high)
        segments[cutIndex].end = position
        segments[cutIndex + 1].start = position
        segments[cutIndex].clampFades()
        segments[cutIndex + 1].clampFades()
    }

    /// Sets a fade of a part, limited so that fade-in and fade-out together fit into it.
    mutating func setFade(_ edge: FadeEdge, of index: Int, to frames: Int64) {
        guard segments.indices.contains(index) else { return }
        let segment = segments[index]
        switch edge {
        case .fadeIn: segments[index].fadeIn = min(max(0, frames), segment.length - segment.fadeOut)
        case .fadeOut: segments[index].fadeOut = min(max(0, frames), segment.length - segment.fadeIn)
        }
    }

    /// Cuts at every frame that leaves both halves at least `minimumLength` long; returns how many.
    @discardableResult
    mutating func cut(at frames: [Int64], minimumLength: Int64) -> Int {
        frames.sorted().reduce(0) { count, frame in count + (cut(at: frame, minimumLength: minimumLength) ? 1 : 0) }
    }

    /// Index of the cut closest to `frame`.
    func cutIndex(nearest frame: Int64) -> Int? {
        cuts.indices.min { abs(cuts[$0] - frame) < abs(cuts[$1] - frame) }
    }

    /// The same edit for a longer recording (files appended): the last part grows to the new end.
    func extended(to newLength: Int64) -> EditList {
        guard newLength > length else { return self }
        var stored = segments
        stored[stored.count - 1].end = newLength
        return EditList(length: newLength, segments: stored)
    }

    /// Puts a part on a track; a deleted part is restored there.
    mutating func setTrack(_ track: Int, for id: Segment.ID) {
        guard EditList.tracks.contains(track), let i = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[i].track = track
        segments[i].deleted = false
    }

    /// Deletes a part or restores it on its track.
    mutating func setDeleted(_ deleted: Bool, for id: Segment.ID) {
        if let i = segments.firstIndex(where: { $0.id == id }) { segments[i].deleted = deleted }
    }

    var deletedCount: Int { segments.filter(\.deleted).count }

    mutating func rename(_ id: Segment.ID, to name: String) {
        if let i = segments.firstIndex(where: { $0.id == id }) { segments[i].name = name }
    }

    func segments(onTrack track: Int) -> [Segment] { segments.filter { $0.track == track && !$0.deleted } }

    /// Audio of a track as continuous ranges: neighbouring parts on the same track are joined,
    /// because nothing lies between them.
    func ranges(onTrack track: Int) -> [Range<Int64>] {
        ranges { $0.track == track }
    }

    /// Everything that is not deleted, on whichever track: what playback of all tracks plays.
    var keptRanges: [Range<Int64>] { ranges { _ in true } }

    private func ranges(where include: (Segment) -> Bool) -> [Range<Int64>] {
        var ranges: [Range<Int64>] = []
        for segment in segments where !segment.deleted && include(segment) {
            if let last = ranges.last, last.upperBound == segment.start {
                ranges[ranges.count - 1] = last.lowerBound..<segment.end
            } else {
                ranges.append(segment.start..<segment.end)
            }
        }
        return ranges
    }

    func length(onTrack track: Int) -> Int64 { segments(onTrack: track).reduce(0) { $0 + $1.length } }
}

/// Export tags the user changed in „Tags“. nil takes the value from the source file, an empty
/// text leaves it out.
struct CustomTags: Codable, Equatable, Sendable {
    enum Cover: Codable, Equatable, Sendable {
        case source
        case none
        /// Path of an image file.
        case file(String)
    }

    var artist: String?
    var album: String?
    var cover: Cover = .source

    var isEmpty: Bool { artist == nil && album == nil && cover == .source }

    /// The source tags with these changes; `artwork` is the image of a `.file` cover.
    func applied(to source: SourceTags, artwork: Data?) -> SourceTags {
        var result = source
        if let artist { result.artist = artist.isEmpty ? nil : artist }
        if let album { result.album = album.isEmpty ? nil : album }
        switch cover {
        case .source: break
        case .none: result.artwork = nil
        case .file: result.artwork = artwork
        }
        return result
    }
}

/// Thread-safe cancellation flag for background work.
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    init() {}

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// Thread-safe counter for progress reported from several threads.
final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0

    init() {}

    /// Adds `amount` and returns the new total.
    func add(_ amount: Int64) -> Int64 { lock.withLock { value += amount; return value } }
    var total: Int64 { lock.withLock { value } }
}

enum TimeFormat {
    /// "1:02:03.45" (with hours) or "2:03.45"; `decimals` digits after the seconds.
    static func string(_ seconds: Double, decimals: Int = 2, forceHours: Bool = false) -> String {
        var scale = 1
        for _ in 0..<decimals { scale *= 10 }
        // Whole ticks (e.g. hundredths) first, so that 1.15 s does not turn into 1.14 s.
        let ticks = Int((max(0, seconds) * Double(scale) + 1e-6).rounded(.down))
        let whole = ticks / scale
        let hours = whole / 3600
        let minutes = whole / 60 % 60
        let wholeSeconds = whole % 60
        var result = hours > 0 || forceHours
            ? String(format: "%d:%02d:%02d", hours, minutes, wholeSeconds)
            : String(format: "%d:%02d", minutes, wholeSeconds)
        if decimals > 0 {
            result += "." + String(format: "%0\(decimals)d", ticks % scale)
        }
        return result
    }
}

enum FileNames {
    /// Makes a user-supplied name safe as a file name: no path separators, no leading dot, not too long.
    static func sanitize(_ name: String) -> String {
        var cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.count > 120 { cleaned = String(cleaned.prefix(120)).trimmingCharacters(in: .whitespaces) }
        // A file name may have 255 bytes (decomposed, as the volume may store it); room is left for the
        // number, the extension and the temporary name of the export.
        if cleaned.decomposedStringWithCanonicalMapping.utf8.count > 200 {
            while cleaned.decomposedStringWithCanonicalMapping.utf8.count > 200 { cleaned.removeLast() }
            cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        }
        return cleaned
    }
}
