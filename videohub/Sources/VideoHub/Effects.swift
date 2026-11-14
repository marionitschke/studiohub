import Foundation

/// The effects of an edit as they really run: which source material goes into which of the two
/// video tracks (a dissolve needs both), where one track blends into the other and how bright the
/// picture is. Positions are sequence ticks. Transitions keep the timing of the edit: a dissolve
/// is centred on its cut and uses material beyond it, a dip to black takes the end of one part and
/// the start of the next. No transition takes more than half of a part.
struct EffectLayout: Equatable, Sendable {
    /// A piece of the source on a video track, with material beyond its part for dissolves.
    struct Clip: Equatable, Sendable {
        var position: Int64
        var source: Range<Int64>
        var track: Int

        var end: Int64 { position + Int64(source.count) }
    }

    /// Where the picture of one track blends into the other.
    struct Blend: Equatable, Sendable {
        var range: Range<Int64>
        var from: Int
        var to: Int
    }

    /// A ramp of brightness and volume: 1 is the normal picture, 0 black and silent.
    struct Ramp: Equatable, Sendable {
        var range: Range<Int64>
        var from: Double
        var to: Double
    }

    /// A transition where it really runs, for the timeline.
    struct Region: Equatable, Sendable {
        /// As in `EditList.transition(at:)`: 0 the start, `parts.count` the end.
        var boundary: Int
        var kind: Transition.Kind
        var range: Range<Int64>
        /// Shorter than wished: the parts or the material beyond the cut are too short.
        var shortened: Bool
    }

    var clips: [Clip] = []
    var blends: [Blend] = []
    var ramps: [Ramp] = []
    var regions: [Region] = []
    var length: Int64 = 0

    var trackCount: Int { clips.contains { $0.track == 1 } ? 2 : 1 }

    /// The brightness at a sequence position (the start of a frame).
    func level(at position: Int64, frame: Int64) -> Double {
        for ramp in ramps where ramp.range.contains(position) {
            return ramp.from + (ramp.to - ramp.from) * Self.progress(position, in: ramp.range, frame: frame)
        }
        return 1
    }

    /// 0 on the first frame of a range, 1 on its last.
    static func progress(_ position: Int64, in range: Range<Int64>, frame: Int64) -> Double {
        let span = Double(range.upperBound - range.lowerBound - frame)
        guard span > 0 else { return 1 }
        return min(1, max(0, Double(position - range.lowerBound) / span))
    }
}

extension EditList {
    /// The effects as they run; `frame` is one frame in ticks (lengths are whole frames).
    func effectLayout(frame: Int64) -> EffectLayout {
        var layout = EffectLayout()
        layout.length = sequenceLength
        let count = parts.count
        guard count > 0 else { return layout }
        let frame = max(1, frame)
        let starts = starts
        func frames(_ ticks: Int64) -> Int64 { max(0, ticks) / frame * frame }
        func half(_ index: Int) -> Int64 { frames(parts[index].length / 2) }

        // Material before (lead) and after (tail) each part that a dissolve shows.
        var lead = [Int64](repeating: 0, count: count)
        var tail = [Int64](repeating: 0, count: count)
        for boundary in 0...count {
            guard let transition = transition(at: boundary) else { continue }
            let wished = frames(transition.duration)
            guard wished > 0 else { continue }
            if boundary == 0 || boundary == count {
                let length = min(wished, half(boundary == 0 ? 0 : count - 1))
                guard length > 0 else { continue }
                let range = boundary == 0 ? 0..<length : layout.length - length..<layout.length
                layout.ramps.append(EffectLayout.Ramp(range: range, from: boundary == 0 ? 0 : 1, to: boundary == 0 ? 1 : 0))
                layout.regions.append(EffectLayout.Region(boundary: boundary, kind: .black, range: range, shortened: length < wished))
                continue
            }
            let before = boundary - 1, after = boundary
            let cut = starts[boundary]
            let first = frames(wished / 2)
            var x: Int64, y: Int64
            switch transition.kind {
            case .black:
                x = min(first, half(before))
                y = min(wished - first, half(after))
                if x > 0 { layout.ramps.append(EffectLayout.Ramp(range: cut - x..<cut, from: 1, to: 0)) }
                if y > 0 { layout.ramps.append(EffectLayout.Ramp(range: cut..<cut + y, from: 0, to: 1)) }
            case .dissolve:
                let room = min(half(before), parts[after].start - bounds.lowerBound)
                let roomAfter = min(half(after), bounds.upperBound - parts[before].end)
                x = min(first, room)
                y = min(wished - x, roomAfter)
                x = min(wished - y, room)
                lead[after] = x
                tail[before] = y
            }
            guard x + y > 0 else { continue }
            layout.regions.append(EffectLayout.Region(boundary: boundary, kind: transition.kind, range: cut - x..<cut + y,
                                                      shortened: x + y < wished))
        }

        // A dissolve switches to the other track; everything else stays on the track before.
        var track = [Int](repeating: 0, count: count)
        for index in 1..<max(1, count) {
            let dissolves = lead[index] > 0 || tail[index - 1] > 0
            track[index] = dissolves ? 1 - track[index - 1] : track[index - 1]
            if dissolves {
                let cut = starts[index]
                layout.blends.append(EffectLayout.Blend(range: cut - lead[index]..<cut + tail[index - 1],
                                                        from: track[index - 1], to: track[index]))
            }
        }
        layout.clips = parts.indices.map { index in
            EffectLayout.Clip(position: starts[index] - lead[index],
                              source: parts[index].start - lead[index]..<parts[index].end + tail[index], track: track[index])
        }
        return layout
    }
}
