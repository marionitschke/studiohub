import Foundation

/// One part of the edit: a range of the source video. Positions are ticks of the video track's
/// time scale (`VideoDocument.timescale`), so every frame time is a whole number.
struct Part: Identifiable, Hashable, Sendable {
    var id = UUID()
    var start: Int64
    var end: Int64
    var sound = PartSound.linked
    /// How the part begins: from the part before (on the first part: from black).
    var transition: Transition?
    /// The titles that start in this part; they move and go with it.
    var titles: [Title] = []

    var length: Int64 { end - start }
    var range: Range<Int64> { start..<end }

    /// Where the part's sound plays, counted from the part's start in the sequence, and which
    /// source range it plays; nil when it is muted.
    var soundPlacement: (offset: Int64, source: Range<Int64>)? {
        switch sound {
        case .linked: (0, range)
        case .detached(let sound): (sound.start - start + sound.shift, sound.range)
        case .muted: nil
        }
    }

    /// The sound as a detached one (a linked sound is one without shift); nil when muted.
    var soundAsDetached: Sound? {
        switch sound {
        case .linked: Sound(start: start, end: end, shift: 0, layer: 0)
        case .detached(let sound): sound
        case .muted: nil
        }
    }
}

/// What a part sounds like.
enum PartSound: Hashable, Sendable {
    /// Its own sound, in sync with the picture.
    case linked
    /// Detached from the picture: shifted, shortened or lengthened.
    case detached(Sound)
    /// No sound of its own.
    case muted

    var isDetached: Bool {
        if case .detached = self { true } else { false }
    }
}

extension Optional<PartSound> {
    var isDetached: Bool { self?.isDetached ?? false }
}

/// A detached sound: a range of the source sound and its shift against the picture of its part
/// (0: in sync; positive: later). It belongs to the source material, not to a position in the
/// sequence, so it stays in sync when the picture is trimmed or the part is moved. Where it
/// overlaps the sound of another part it replaces it.
struct Sound: Hashable, Sendable {
    var start: Int64
    var end: Int64
    var shift: Int64
    /// Where detached sounds overlap, the higher layer is heard: the one changed last.
    var layer: Int

    var length: Int64 { end - start }
    var range: Range<Int64> { start..<end }
}

/// A piece of the sound as it is heard: the source range played from a sequence position on.
struct SoundSegment: Hashable, Sendable {
    var position: Int64
    var source: Range<Int64>

    var end: Int64 { position + Int64(source.count) }

    /// The sound that simply follows the pictures of the given parts.
    static func following(_ ranges: [Range<Int64>]) -> [SoundSegment] {
        EditList(bounds: 0..<0, parts: ranges.map { Part(start: $0.lowerBound, end: $0.upperBound) }).soundSegments
    }
}

/// How a part begins. On the first part every kind fades in from black.
struct Transition: Hashable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        /// The pictures blend into each other (needs material beyond the cut).
        case dissolve
        /// The picture fades to black and the next one fades in from black; the sound fades with it.
        case black
    }

    var kind: Kind
    /// The wished length in ticks (whole frames); shorter where the parts or the material are too short.
    var duration: Int64
}

/// A text over the picture. It starts at a source position (`anchor`) of the part it belongs to,
/// so it stays with its pictures when parts are trimmed or moved, and goes when its part is deleted.
struct Title: Identifiable, Hashable, Sendable {
    var id = UUID()
    var text: String
    var anchor: Int64
    var length: Int64
    /// The centre of the text, 0…1 of the picture (y from the top).
    var x = 0.5
    var y = 0.82
    /// Font size as a fraction of the shorter side of the picture.
    var size = 0.07
    /// Black instead of white.
    var dark = false
    /// A half-transparent box behind the text.
    var bar = false

    static let minimumSize = 0.03, maximumSize = 0.2
}

/// A title as it is seen: its part and where it runs in the sequence.
struct PlacedTitle: Hashable, Sendable {
    var part: Int
    var title: Title
    var start: Int64
    var end: Int64

    var range: Range<Int64> { start..<end }
}

/// An image over the whole video, e.g. a logo.
struct Logo: Hashable, Sendable {
    var file: URL
    /// The centre of the image, 0…1 of the picture (y from the top).
    var x = 0.88
    var y = 0.12
    /// Width as a fraction of the picture's width.
    var width = 0.16
    var opacity = 0.85

    static let minimumWidth = 0.04, maximumWidth = 0.6
}

enum PartEdge: Sendable {
    case start, end
}

enum DragPhase: Sendable {
    case began, changed, ended
}

/// The edit of one video: parts of the source in playback order. Parts never share source
/// material; whatever no part covers is cut away. A position in the edit (the "sequence") counts
/// ticks from the start of the first part.
struct EditList: Equatable, Sendable {
    /// The source range that has video.
    let bounds: Range<Int64>
    private(set) var parts: [Part]
    /// Fade to black at the end (wished length in ticks).
    var fadeOut: Int64?
    var logo: Logo?

    init(bounds: Range<Int64>) {
        self.bounds = bounds
        parts = bounds.isEmpty ? [] : [Part(start: bounds.lowerBound, end: bounds.upperBound)]
    }

    /// For checks: an edit from given parts (not validated).
    init(bounds: Range<Int64>, parts: [Part]) {
        self.bounds = bounds
        self.parts = parts
    }

    var sequenceLength: Int64 { parts.reduce(0) { $0 + $1.length } }

    var hasEdits: Bool {
        !(parts.count == 1 && parts[0].range == bounds && parts[0].sound == .linked) || hasEffects
    }

    /// Transitions, titles or a logo: the export has to encode the picture anew.
    var hasEffects: Bool {
        fadeOut != nil || logo != nil || parts.contains { $0.transition != nil || !$0.titles.isEmpty }
    }

    /// Source ranges in playback order.
    var ranges: [Range<Int64>] { parts.map(\.range) }

    /// Where every part starts in the sequence.
    var starts: [Int64] {
        var result: [Int64] = []
        var position: Int64 = 0
        for part in parts {
            result.append(position)
            position += part.length
        }
        return result
    }

    func sequenceStart(of index: Int) -> Int64 {
        parts[..<min(max(0, index), parts.count)].reduce(0) { $0 + $1.length }
    }

    /// Index of the part at a sequence position; the end of the sequence belongs to the last part.
    func index(at position: Int64) -> Int? {
        guard !parts.isEmpty else { return nil }
        var start: Int64 = 0
        for (index, part) in parts.enumerated() {
            if position < start + part.length { return index }
            start += part.length
        }
        return parts.count - 1
    }

    /// The source position shown at a sequence position.
    func sourcePosition(at position: Int64) -> Int64? {
        guard let index = index(at: position) else { return nil }
        let offset = min(max(0, position - sequenceStart(of: index)), parts[index].length)
        return parts[index].start + offset
    }

    /// The sequence position of a source position inside part `index`.
    func sequencePosition(ofSource source: Int64, inPart index: Int) -> Int64 {
        sequenceStart(of: index) + min(max(0, source - parts[index].start), parts[index].length)
    }

    /// The boundary after part `boundary` is a cut when the source simply continues there. A cut
    /// can be moved or removed; other boundaries are jumps (something was deleted or moved).
    func isCut(_ boundary: Int) -> Bool {
        boundary >= 0 && boundary + 1 < parts.count && parts[boundary].end == parts[boundary + 1].start
    }

    /// Splits the part at a sequence position. Fails if either half would be shorter than `minimumLength`.
    /// A detached sound is split where it is heard at that position, so nothing sounds different.
    @discardableResult
    mutating func cut(at position: Int64, minimumLength: Int64) -> Bool {
        guard let index = index(at: position) else { return false }
        let part = parts[index]
        let offset = position - sequenceStart(of: index)
        guard offset >= minimumLength, part.length - offset >= minimumLength else { return false }
        var second = Part(start: part.start + offset, end: part.end, sound: part.sound)
        parts[index].end = second.start
        second.titles = part.titles.filter { $0.anchor >= second.start }
        parts[index].titles = part.titles.filter { $0.anchor < second.start }
        if case .detached(let sound) = part.sound {
            // The source position of the sound heard at the cut.
            let split = second.start - sound.shift
            if split <= sound.start {
                parts[index].sound = .muted
            } else if split >= sound.end {
                second.sound = .muted
            } else {
                var head = sound, tail = sound
                head.end = split
                tail.start = split
                parts[index].sound = .detached(head)
                second.sound = .detached(tail)
            }
        }
        parts.insert(second, at: index + 1)
        return true
    }

    mutating func delete(_ index: Int) {
        guard parts.indices.contains(index) else { return }
        parts.remove(at: index)
    }

    /// Moves part `index` in front of the part that is now at `destination` (`parts.count`: to the end).
    mutating func move(_ index: Int, before destination: Int) {
        guard parts.indices.contains(index), (0...parts.count).contains(destination),
              destination != index, destination != index + 1 else { return }
        let part = parts.remove(at: index)
        parts.insert(part, at: destination > index ? destination - 1 : destination)
    }

    /// Removes a cut: both parts become one. Their sounds join if they fit together; otherwise
    /// the sound goes back to the picture.
    mutating func join(_ boundary: Int) {
        guard isCut(boundary) else { return }
        let first = parts[boundary], second = parts[boundary + 1]
        parts[boundary].end = second.end
        parts[boundary].titles += second.titles
        parts[boundary].sound = switch (first.sound, second.sound) {
        case (.linked, .linked): .linked
        case (.muted, .muted): .muted
        // One half had given all its sound to the other (see `cut`).
        case (.muted, .detached(let sound)), (.detached(let sound), .muted): .detached(sound)
        default:
            if let head = first.soundAsDetached, let tail = second.soundAsDetached,
               head.shift == tail.shift, head.end == tail.start {
                .detached(Sound(start: head.start, end: tail.end, shift: head.shift, layer: max(head.layer, tail.layer)))
            } else {
                .linked
            }
        }
        parts.remove(at: boundary + 1)
    }

    /// Moves a cut in the source; both parts keep at least `minimumLength`.
    mutating func moveCut(_ boundary: Int, to position: Int64, minimumLength: Int64) {
        guard isCut(boundary) else { return }
        let low = parts[boundary].start + minimumLength
        let high = parts[boundary + 1].end - minimumLength
        guard low <= high else { return }
        let value = min(max(position, low), high)
        parts[boundary].end = value
        parts[boundary + 1].start = value
        // The source continues across a cut: titles stay with their pictures.
        let titles = parts[boundary].titles + parts[boundary + 1].titles
        parts[boundary].titles = titles.filter { $0.anchor < value }
        parts[boundary + 1].titles = titles.filter { $0.anchor >= value }
    }

    /// The source range part `index` can grow into: up to the nearest other part in the source.
    func room(for index: Int) -> Range<Int64> {
        let part = parts[index]
        var low = bounds.lowerBound, high = bounds.upperBound
        for (other, candidate) in parts.enumerated() where other != index {
            if candidate.end <= part.start { low = max(low, candidate.end) }
            if candidate.start >= part.end { high = min(high, candidate.start) }
        }
        return low..<high
    }

    // MARK: Transitions

    /// The transition at a boundary: 0 is the start of the video (fade in), `parts.count` its end
    /// (fade out), the others lead into part `boundary`.
    func transition(at boundary: Int) -> Transition? {
        if boundary == parts.count { return fadeOut.map { Transition(kind: .black, duration: $0) } }
        return parts.indices.contains(boundary) ? parts[boundary].transition : nil
    }

    mutating func setTransition(_ transition: Transition?, at boundary: Int) {
        if boundary == parts.count {
            fadeOut = transition?.duration
        } else if parts.indices.contains(boundary) {
            parts[boundary].transition = transition
        }
    }

    // MARK: Titles

    /// All titles where they run, in order of their start.
    var placedTitles: [PlacedTitle] {
        let length = sequenceLength
        var result: [PlacedTitle] = []
        var position: Int64 = 0
        for (index, part) in parts.enumerated() {
            for title in part.titles {
                let start = position + min(max(0, title.anchor - part.start), max(0, part.length - 1))
                result.append(PlacedTitle(part: index, title: title, start: start, end: min(length, start + title.length)))
            }
            position += part.length
        }
        return result.sorted { ($0.start, $0.part) < ($1.start, $1.part) }
    }

    func title(_ id: UUID) -> Title? {
        parts.lazy.flatMap(\.titles).first { $0.id == id }
    }

    func placedTitle(_ id: UUID) -> PlacedTitle? {
        placedTitles.first { $0.title.id == id }
    }

    /// Adds a title that starts at a sequence position; false outside the edit.
    @discardableResult
    mutating func addTitle(_ title: Title, at position: Int64) -> Bool {
        guard let index = index(at: min(max(0, position), max(0, sequenceLength - 1))),
              let source = sourcePosition(at: min(max(0, position), max(0, sequenceLength - 1))) else { return false }
        var title = title
        title.anchor = source
        title.length = max(1, min(title.length, sequenceLength - sequencePosition(ofSource: source, inPart: index)))
        parts[index].titles.append(title)
        return true
    }

    mutating func removeTitle(_ id: UUID) {
        for index in parts.indices { parts[index].titles.removeAll { $0.id == id } }
    }

    /// Changes text, look or place of a title.
    mutating func updateTitle(_ id: UUID, _ change: (inout Title) -> Void) {
        for index in parts.indices {
            if let slot = parts[index].titles.firstIndex(where: { $0.id == id }) { change(&parts[index].titles[slot]) }
        }
    }

    /// Moves a title to another start; it then belongs to the part there. It stays inside the edit.
    mutating func moveTitle(_ id: UUID, to position: Int64) {
        guard let placed = placedTitle(id) else { return }
        let length = placed.end - placed.start
        let start = min(max(0, position), max(0, sequenceLength - length))
        removeTitle(id)
        var title = placed.title
        title.length = length
        addTitle(title, at: start)
    }

    /// Moves the start (the end stays) or the end of a title; it keeps at least `minimumLength`.
    mutating func trimTitle(_ id: UUID, _ edge: PartEdge, to position: Int64, minimumLength: Int64) {
        guard let placed = placedTitle(id) else { return }
        switch edge {
        case .start:
            let start = min(max(0, position), max(0, placed.end - minimumLength))
            removeTitle(id)
            var title = placed.title
            title.length = placed.end - start
            addTitle(title, at: start)
        case .end:
            let end = max(min(position, sequenceLength), min(sequenceLength, placed.start + minimumLength))
            updateTitle(id) { $0.length = max(1, end - placed.start) }
        }
    }

    // MARK: Sound

    /// Where the sound of part `index` plays in the sequence and which source range; nil when muted.
    func soundSpan(of index: Int) -> (position: Int64, source: Range<Int64>)? {
        guard parts.indices.contains(index), let placement = parts[index].soundPlacement else { return nil }
        return (sequenceStart(of: index) + placement.offset, placement.source)
    }

    /// The sound as it is heard, in playback order: detached sounds over the linked ones (the
    /// highest layer on top), cut off at the start and end of the sequence. Pieces that continue
    /// each other are joined.
    var soundSegments: [SoundSegment] {
        let length = sequenceLength
        var spans: [(segment: SoundSegment, priority: Int)] = []
        var position: Int64 = 0
        for part in parts {
            defer { position += part.length }
            guard let placement = part.soundPlacement else { continue }
            let start = position + placement.offset
            let from = max(start, 0), to = min(start + Int64(placement.source.count), length)
            guard from < to else { continue }
            let source = placement.source.lowerBound + (from - start)
            var priority = 0
            if case .detached(let sound) = part.sound { priority = sound.layer + 1 }
            spans.append((SoundSegment(position: from, source: source..<source + (to - from)), priority))
        }
        let marks = Set(spans.flatMap { [$0.segment.position, $0.segment.end] }).sorted()
        var result: [SoundSegment] = []
        for (from, to) in zip(marks, marks.dropFirst()) {
            let covering = spans.indices.filter { spans[$0].segment.position <= from && spans[$0].segment.end >= to }
            // A later part wins a tie (only detached sounds of the same layer can tie).
            guard let topIndex = covering.max(by: { (spans[$0].priority, $0) < (spans[$1].priority, $1) }) else { continue }
            let top = spans[topIndex]
            let source = top.segment.source.lowerBound + (from - top.segment.position)
            if let last = result.last, last.end == from, last.source.upperBound == source {
                result[result.count - 1].source = last.source.lowerBound..<source + (to - from)
            } else {
                result.append(SoundSegment(position: from, source: source..<source + (to - from)))
            }
        }
        return result
    }

    private func topLayer(except index: Int) -> Int {
        parts.indices.filter { $0 != index }.compactMap {
            if case .detached(let sound) = parts[$0].sound { sound.layer } else { nil }
        }.max() ?? 0
    }

    /// Detaches the sound of a part from its picture (a muted part gets its own sound back first).
    mutating func detachSound(_ index: Int) {
        guard parts.indices.contains(index) else { return }
        if case .detached = parts[index].sound { return }
        let part = parts[index]
        parts[index].sound = .detached(Sound(start: part.start, end: part.end, shift: 0, layer: topLayer(except: index) + 1))
    }

    /// Puts the part's own sound back under its picture.
    mutating func attachSound(_ index: Int) {
        guard parts.indices.contains(index) else { return }
        parts[index].sound = .linked
    }

    /// Mutes a part, or gives it its own sound back.
    mutating func setMuted(_ index: Int, _ muted: Bool) {
        guard parts.indices.contains(index) else { return }
        parts[index].sound = muted ? .muted : .linked
    }

    /// Shifts a detached sound against its picture; at least `minimumLength` of it stays in the sequence.
    mutating func shiftSound(_ index: Int, to shift: Int64, minimumLength: Int64) {
        guard parts.indices.contains(index), case .detached(var sound) = parts[index].sound else { return }
        let base = sequenceStart(of: index) + sound.start - parts[index].start
        let keep = min(minimumLength, sound.length)
        let low = keep - sound.length - base, high = sequenceLength - keep - base
        sound.shift = low <= high ? min(max(shift, low), high) : sound.shift
        sound.layer = topLayer(except: index) + 1
        parts[index].sound = .detached(sound)
    }

    /// Moves the start or end of a detached sound in the source; what is already there stays in place.
    mutating func trimSound(_ index: Int, _ edge: PartEdge, to position: Int64, minimumLength: Int64) {
        guard parts.indices.contains(index), case .detached(var sound) = parts[index].sound else { return }
        switch edge {
        case .start:
            let limit = max(sound.end - minimumLength, min(sound.start, sound.end - 1))
            sound.start = min(max(position, bounds.lowerBound), limit)
        case .end:
            let limit = min(sound.start + minimumLength, max(sound.end, sound.start + 1))
            sound.end = max(min(position, bounds.upperBound), limit)
        }
        sound.layer = topLayer(except: index) + 1
        parts[index].sound = .detached(sound)
    }

    /// Moves the start or end of a part in the source. It can take back material that was cut
    /// away, but never material of another part; the rest of the edit moves up or back.
    mutating func trim(_ index: Int, _ edge: PartEdge, to position: Int64, minimumLength: Int64) {
        guard parts.indices.contains(index) else { return }
        let part = parts[index]
        let room = room(for: index)
        switch edge {
        case .start:
            let limit = max(part.end - minimumLength, min(part.start, part.end - 1))
            parts[index].start = min(max(position, room.lowerBound), limit)
        case .end:
            let limit = min(part.start + minimumLength, max(part.end, part.start + 1))
            parts[index].end = max(min(position, room.upperBound), limit)
        }
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

/// Lets through at most one progress update per percent.
final class PercentGate: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1

    func pass(_ value: Double) -> Bool {
        let percent = Int(value * 100)
        return lock.withLock {
            guard percent > last else { return false }
            last = percent
            return true
        }
    }
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
        return cleaned
    }
}
