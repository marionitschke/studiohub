import AppKit
import SwiftUI

enum DragPhase {
    case began, changed, ended
}

enum TrackStyle {
    /// Blue, orange and green as in DiaryHub, light enough for waveforms on the dark background.
    static func color(_ track: Int) -> NSColor {
        switch track {
        case 1: Darcula.color(0x6DB6F0)
        case 2: Darcula.color(0xFF9A52)
        default: Darcula.color(0x3FBF63)
        }
    }
}

/// Everything the timeline draws.
struct TimelineState {
    var peaks: Peaks
    var sampleRate: Double
    var segments: [Segment]
    var playhead: Int64
    var visibleStart: Double
    var visibleLength: Double
    var soloTrack: Int?
    /// Cuts the pause finder proposes (dashed until they are set).
    var proposedCuts: [Int64] = []
    /// Where each later file of a joined recording begins, with its name.
    var fileStarts: [(frame: Int64, name: String)] = []
}

/// The timeline: time ruler, three tracks with the parts at their time positions, cuts with a
/// remove button, fade handles at the top corners of every part, playhead and a scroll bar. Click
/// or drag to move the playhead, drag a cut to move it, drag a fade handle inwards to fade, drag a
/// part up or down to put it on another track, scroll to pan, pinch or ⌥-scroll to zoom. Deleted
/// parts stay in their lane as a grey, dashed outline; dragging one onto a lane restores it there.
final class TimelineNSView: NSView {
    static let rulerHeight: CGFloat = 24
    static let scrollerHeight: CGFloat = 12
    static let flagSize: CGFloat = 16
    static let handleRadius: CGFloat = 5
    static let trackCount = EditList.tracks.count

    var state: TimelineState? {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var onSeek: ((Int64, Bool) -> Void)?
    var onMoveCut: ((Int, Int64, DragPhase) -> Void)?
    var onRemoveCut: ((Int) -> Void)?
    var onMoveToTrack: ((Segment.ID, Int) -> Void)?
    var onFade: ((Int, FadeEdge, Int64, DragPhase) -> Void)?
    var onScroll: ((Double) -> Void)?
    var onZoom: ((Double, Double) -> Void)?
    var onResize: ((Double) -> Void)?

    private enum Drag {
        case seek
        case cut(index: Int, onFlag: Bool, moved: Bool, startX: CGFloat)
        /// Pressed on a part: becomes a track move (vertical) or a seek (horizontal).
        case part(index: Int, start: NSPoint, movingToTrack: Int?)
        case fade(index: Int, edge: FadeEdge, grab: CGFloat)
        case scroller(grab: CGFloat)
    }
    private var drag: Drag?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let width = Double(newSize.width)
        DispatchQueue.main.async { [weak self] in self?.onResize?(width) }
    }

    // MARK: Geometry

    private func x(_ frame: Double, _ state: TimelineState) -> CGFloat {
        CGFloat((frame - state.visibleStart) / state.visibleLength) * bounds.width
    }

    private func frame(atX x: CGFloat, _ state: TimelineState) -> Double {
        state.visibleStart + Double(x / max(1, bounds.width)) * state.visibleLength
    }

    private var laneHeight: CGFloat {
        max(1, (bounds.height - Self.rulerHeight - Self.scrollerHeight) / CGFloat(Self.trackCount))
    }

    private func laneRect(_ track: Int) -> NSRect {
        NSRect(x: 0, y: Self.rulerHeight + CGFloat(track - 1) * laneHeight, width: bounds.width, height: laneHeight)
    }

    /// Track under a y position (clamped to the tracks).
    private func track(atY y: CGFloat) -> Int {
        min(Self.trackCount, max(1, Int((y - Self.rulerHeight) / laneHeight) + 1))
    }

    private var scrollerRect: NSRect {
        NSRect(x: 0, y: bounds.height - Self.scrollerHeight, width: bounds.width, height: Self.scrollerHeight)
    }

    private func thumbRect(_ state: TimelineState) -> NSRect {
        let length = Double(max(1, state.peaks.length))
        let width = max(24, CGFloat(state.visibleLength / length) * bounds.width)
        let left = CGFloat(state.visibleStart / length) * (bounds.width - width) / max(0.0001, CGFloat(1 - state.visibleLength / length))
        return NSRect(x: min(left, bounds.width - width), y: scrollerRect.minY + 3, width: width, height: Self.scrollerHeight - 6)
    }

    private var cuts: [Int64] { state?.segments.dropFirst().map(\.start) ?? [] }

    private func flagRect(_ cutX: CGFloat) -> NSRect {
        NSRect(x: round(cutX) - Self.flagSize / 2, y: (Self.rulerHeight - Self.flagSize) / 2,
               width: Self.flagSize, height: Self.flagSize)
    }

    private func flag(at point: NSPoint) -> Int? {
        guard let state, point.y < Self.rulerHeight else { return nil }
        return cuts.indices.first { flagRect(x(Double(cuts[$0]), state)).insetBy(dx: -2, dy: -2).contains(point) }
    }

    private func cutLine(near point: NSPoint) -> Int? {
        guard let state, point.y > Self.rulerHeight, point.y < scrollerRect.minY else { return nil }
        let candidates = cuts.indices.map { ($0, abs(x(Double(cuts[$0]), state) - point.x)) }.filter { $0.1 <= 4 }
        return candidates.min { $0.1 < $1.1 }?.0
    }

    /// The box a part is drawn in, in its track's lane.
    private func partBox(_ segment: Segment, _ state: TimelineState) -> NSRect {
        let left = max(-2, x(Double(segment.start), state))
        let right = min(bounds.width + 2, x(Double(segment.end), state))
        return NSRect(x: left + 1, y: laneRect(segment.track).minY + 3, width: max(1, right - left - 2), height: laneHeight - 7)
    }

    private func points(_ frames: Int64, _ state: TimelineState) -> CGFloat {
        CGFloat(Double(frames) / state.visibleLength) * bounds.width
    }

    /// Fade handles of a part on its top edge: at the corners, or where the fade ends. Only parts
    /// wide enough to grab them get handles.
    private func fadeHandles(_ segment: Segment, _ state: TimelineState) -> (fadeIn: NSPoint, fadeOut: NSPoint)? {
        let box = partBox(segment, state)
        guard !segment.deleted, box.width >= 36, box.maxX > 0, box.minX < bounds.width else { return nil }
        let inset: CGFloat = 7
        let inX = box.minX + min(box.width - inset, max(inset, points(segment.fadeIn, state)))
        let outX = box.maxX - min(box.width - inset, max(inset, points(segment.fadeOut, state)))
        return (NSPoint(x: inX, y: box.minY + 1), NSPoint(x: outX, y: box.minY + 1))
    }

    private func fadeHandle(at point: NSPoint) -> (index: Int, edge: FadeEdge, handle: NSPoint)? {
        guard let state else { return nil }
        for (index, segment) in state.segments.enumerated() {
            guard let handles = fadeHandles(segment, state) else { continue }
            for (edge, handle) in [(FadeEdge.fadeIn, handles.fadeIn), (.fadeOut, handles.fadeOut)]
            where hypot(point.x - handle.x, point.y - handle.y) <= Self.handleRadius + 4 {
                return (index, edge, handle)
            }
        }
        return nil
    }

    private func segmentIndex(at frame: Double, _ state: TimelineState) -> Int? {
        guard frame >= 0, frame < Double(state.peaks.length) else { return nil }
        return state.segments.firstIndex { Double($0.start) <= frame && frame < Double($0.end) }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        Darcula.background.setFill()
        bounds.fill()
        guard let state, state.visibleLength > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        let width = bounds.width
        let visibleEnd = state.visibleStart + state.visibleLength

        // Lanes with separators.
        for track in EditList.tracks {
            let lane = laneRect(track)
            TrackStyle.color(track).withAlphaComponent(0.035).setFill()
            lane.fill()
            Darcula.border.setFill()
            NSRect(x: 0, y: lane.maxY - 1, width: width, height: 1).fill()
        }

        // Parts: a tinted box in their lane, the current one stronger.
        var movingIndex: Int?, movingTarget: Int?
        if case .part(let index, _, let target?) = drag { movingIndex = index; movingTarget = target }
        for (index, segment) in state.segments.enumerated()
        where Double(segment.end) > state.visibleStart && Double(segment.start) < visibleEnd {
            let current = segment.contains(state.playhead)
            let box = partBox(segment, state)
            let path = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
            if segment.deleted {
                Darcula.text.withAlphaComponent(current ? 0.06 : 0.03).setFill()
                path.fill()
                path.setLineDash([4, 3], count: 2, phase: 0)
                Darcula.muted.withAlphaComponent(current ? 0.8 : 0.4).setStroke()
            } else {
                let color = TrackStyle.color(segment.track)
                color.withAlphaComponent(current ? 0.22 : 0.12).setFill()
                path.fill()
                color.withAlphaComponent(current ? 0.9 : 0.45).setStroke()
            }
            path.lineWidth = current ? 1.5 : 1
            path.stroke()
            if index == movingIndex, let movingTarget, movingTarget != segment.track || segment.deleted {
                let ghost = NSBezierPath(roundedRect: NSRect(x: box.minX, y: laneRect(movingTarget).minY + 3, width: box.width, height: box.height),
                                         xRadius: 5, yRadius: 5)
                TrackStyle.color(movingTarget).withAlphaComponent(0.18).setFill()
                ghost.fill()
                ghost.setLineDash([5, 3], count: 2, phase: 0)
                TrackStyle.color(movingTarget).setStroke()
                ghost.lineWidth = 1.5
                ghost.stroke()
            }
            if box.width > 28 {
                var label = "\(index + 1)"
                if !segment.name.isEmpty { label += "  " + segment.name }
                if segment.deleted { label += "  (gelöscht)" }
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: segment.deleted ? Darcula.faint : Darcula.muted,
                ]
                (label as NSString).draw(with: NSRect(x: box.minX + 15, y: box.minY + 3, width: box.width - 30, height: 15),
                                         options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
            }
        }

        // Waveform, one column per device pixel, in the lane of the part it belongs to.
        let scale = window?.backingScaleFactor ?? 2
        let step = 1 / scale
        let framesPerColumn = state.visibleLength / Double(width) * Double(step)
        let level = state.peaks.level(forFramesPerPoint: framesPerColumn)
        let amplitude = (laneHeight / 2 - 12) / CGFloat(max(state.peaks.peak, 0.05))
        // Index 0 collects the columns of deleted parts (drawn grey).
        var columns = [[CGRect]](repeating: [], count: Self.trackCount + 1)
        var segmentIndex = 0
        var column: CGFloat = 0
        while column < width {
            let from = frame(atX: column, state), to = frame(atX: column + step, state)
            defer { column += step }
            if to <= 0 { continue }
            guard from < Double(state.peaks.length),
                  let (low, high) = state.peaks.range(from: Int64(max(0, from)), to: Int64(to), level: level) else { break }
            while segmentIndex < state.segments.count - 1, Double(state.segments[segmentIndex].end) <= from { segmentIndex += 1 }
            let segment = state.segments[segmentIndex]
            let middle = laneRect(segment.track).midY + 6
            // The waveform shrinks inside fades, as it will sound.
            let gain = CGFloat(segment.fadeGain(at: Int64(max(0, from))))
            columns[segment.deleted ? 0 : segment.track].append(CGRect(x: column, y: middle - CGFloat(high) * amplitude * gain, width: step,
                                                 height: max(step, CGFloat(high - low) * amplitude * gain)))
        }
        for track in EditList.tracks {
            context.setFillColor(TrackStyle.color(track).cgColor)
            context.fill(columns[track])
        }
        context.setFillColor(Darcula.faint.cgColor)
        context.fill(columns[0])

        drawFades(state, visibleEnd: visibleEnd)
        drawFileStarts(state, visibleEnd: visibleEnd)

        // Solo: the other tracks fade out.
        if let solo = state.soloTrack {
            for track in EditList.tracks where track != solo {
                Darcula.background.withAlphaComponent(0.6).setFill()
                laneRect(track).fill(using: .sourceOver)
            }
        }

        drawRuler(state, visibleEnd: visibleEnd)

        // Cuts across all tracks, with a button with × in the ruler. The cut under the playhead (the
        // one , and . move) is drawn brighter and wider.
        let lanesBottom = scrollerRect.minY
        for cut in cuts where Double(cut) >= state.visibleStart && Double(cut) <= visibleEnd {
            let cutX = round(x(Double(cut), state)) + 0.5
            let active = cut == state.playhead
            (active ? Darcula.text : Darcula.text.withAlphaComponent(0.7)).setFill()
            NSRect(x: cutX - (active ? 1 : 0.5), y: Self.rulerHeight, width: active ? 2 : 1, height: lanesBottom - Self.rulerHeight).fill()
            let flag = flagRect(cutX)
            (active ? NSColor.white : Darcula.text).setFill()
            NSBezierPath(roundedRect: flag, xRadius: 4, yRadius: 4).fill()
            let cross = NSBezierPath()
            let inset = flag.insetBy(dx: 5, dy: 5)
            cross.move(to: NSPoint(x: inset.minX, y: inset.minY))
            cross.line(to: NSPoint(x: inset.maxX, y: inset.maxY))
            cross.move(to: NSPoint(x: inset.maxX, y: inset.minY))
            cross.line(to: NSPoint(x: inset.minX, y: inset.maxY))
            cross.lineWidth = 1.6
            cross.lineCapStyle = .round
            Darcula.background.setStroke()
            cross.stroke()
        }

        // Proposed cuts: dashed, with a small marker in the ruler.
        for cut in state.proposedCuts where Double(cut) >= state.visibleStart && Double(cut) <= visibleEnd {
            let cutX = round(x(Double(cut), state)) + 0.5
            let line = NSBezierPath()
            line.move(to: NSPoint(x: cutX, y: Self.rulerHeight))
            line.line(to: NSPoint(x: cutX, y: lanesBottom))
            line.setLineDash([4, 3], count: 2, phase: 0)
            line.lineWidth = 1.5
            StudioApp.music.ink.setStroke()
            line.stroke()
            StudioApp.music.ink.setFill()
            NSBezierPath(ovalIn: NSRect(x: cutX - 4, y: Self.rulerHeight / 2 - 4, width: 8, height: 8)).fill()
        }

        // Playhead with a small triangle in the ruler.
        if Double(state.playhead) >= state.visibleStart && Double(state.playhead) <= visibleEnd {
            let playX = round(x(Double(state.playhead), state)) + 0.5
            NSColor.systemRed.setFill()
            NSRect(x: playX - 0.75, y: Self.rulerHeight - 6, width: 1.5, height: lanesBottom - Self.rulerHeight + 6).fill()
            let triangle = NSBezierPath()
            triangle.move(to: NSPoint(x: playX - 6, y: Self.rulerHeight - 10))
            triangle.line(to: NSPoint(x: playX + 6, y: Self.rulerHeight - 10))
            triangle.line(to: NSPoint(x: playX, y: Self.rulerHeight - 2))
            triangle.close()
            triangle.fill()
        }

        drawScroller(state)
    }

    /// Fade curves (the faded area shaded above them) and the handles.
    private func drawFades(_ state: TimelineState, visibleEnd: Double) {
        var dragged: (index: Int, edge: FadeEdge)?
        if case .fade(let index, let edge, _) = drag { dragged = (index, edge) }
        for (index, segment) in state.segments.enumerated()
        where !segment.deleted && Double(segment.end) > state.visibleStart && Double(segment.start) < visibleEnd {
            let box = partBox(segment, state)
            let color = TrackStyle.color(segment.track)
            for edge in [FadeEdge.fadeIn, .fadeOut] {
                let frames = edge == .fadeIn ? segment.fadeIn : segment.fadeOut
                let width = min(box.width, points(frames, state))
                guard width >= 1 else { continue }
                let curve = NSBezierPath()
                let shade = NSBezierPath()
                let steps = 24
                for i in 0...steps {
                    let t = CGFloat(i) / CGFloat(steps)
                    let level = CGFloat(Fade.curve(Double(t)))
                    let point = edge == .fadeIn
                        ? NSPoint(x: box.minX + t * width, y: box.maxY - level * box.height)
                        : NSPoint(x: box.maxX - t * width, y: box.maxY - level * box.height)
                    if i == 0 { curve.move(to: point) } else { curve.line(to: point) }
                }
                shade.append(curve)
                shade.line(to: NSPoint(x: edge == .fadeIn ? box.minX : box.maxX, y: box.minY))
                shade.close()
                Darcula.background.withAlphaComponent(0.45).setFill()
                shade.fill()
                color.withAlphaComponent(0.9).setStroke()
                curve.lineWidth = 1.5
                curve.stroke()
            }
            guard let handles = fadeHandles(segment, state) else { continue }
            for (edge, handle) in [(FadeEdge.fadeIn, handles.fadeIn), (.fadeOut, handles.fadeOut)] {
                let circle = NSBezierPath(ovalIn: NSRect(x: handle.x - Self.handleRadius, y: handle.y - Self.handleRadius,
                                                         width: Self.handleRadius * 2, height: Self.handleRadius * 2))
                NSColor.white.setFill()
                circle.fill()
                color.setStroke()
                circle.lineWidth = 1.5
                circle.stroke()
                if let dragged, dragged.index == index, dragged.edge == edge {
                    let frames = edge == .fadeIn ? segment.fadeIn : segment.fadeOut
                    let seconds = Double(frames) / state.sampleRate
                    let text = (edge == .fadeIn ? "Einblenden " : "Ausblenden ")
                        + (frames == 0 ? "aus" : seconds.formatted(.number.precision(.fractionLength(1))) + " s")
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                        .foregroundColor: Darcula.text,
                        .backgroundColor: Darcula.background.withAlphaComponent(0.85),
                    ]
                    let size = (text as NSString).size(withAttributes: attributes)
                    let originX = edge == .fadeIn ? handle.x + 9 : handle.x - 9 - size.width
                    (text as NSString).draw(at: NSPoint(x: originX, y: handle.y + 6), withAttributes: attributes)
                }
            }
        }
    }

    /// Borders between the files of a joined recording: a dotted line and the name of the file that
    /// begins there, at the bottom of the lanes.
    private func drawFileStarts(_ state: TimelineState, visibleEnd: Double) {
        let bottom = scrollerRect.minY
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: Darcula.muted,
            .backgroundColor: Darcula.background.withAlphaComponent(0.8),
        ]
        for start in state.fileStarts where Double(start.frame) >= state.visibleStart && Double(start.frame) <= visibleEnd {
            let lineX = round(x(Double(start.frame), state)) + 0.5
            let line = NSBezierPath()
            line.move(to: NSPoint(x: lineX, y: Self.rulerHeight))
            line.line(to: NSPoint(x: lineX, y: bottom))
            line.setLineDash([1, 3], count: 2, phase: 0)
            line.lineWidth = 1
            Darcula.muted.setStroke()
            line.stroke()
            let text = " " + start.name + " " as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: lineX + 3, y: bottom - size.height - 3), withAttributes: attributes)
        }
    }

    private func drawRuler(_ state: TimelineState, visibleEnd: Double) {
        Darcula.surface.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: Self.rulerHeight).fill()
        Darcula.border.setFill()
        NSRect(x: 0, y: Self.rulerHeight - 1, width: bounds.width, height: 1).fill()

        let secondsPerPoint = state.visibleLength / state.sampleRate / Double(max(1, bounds.width))
        let intervals: [Double] = [0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200]
        let interval = intervals.first { $0 / secondsPerPoint >= 90 } ?? 7200
        let decimals = interval < 0.1 ? 2 : (interval < 1 ? 1 : 0)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: Darcula.muted,
        ]
        let first = (state.visibleStart / state.sampleRate / interval).rounded(.down)
        var tick = 0.0
        while true {
            let seconds = (first + tick) * interval
            tick += 1
            let frame = seconds * state.sampleRate
            if frame > visibleEnd { break }
            let tickX = round(x(frame, state)) + 0.5
            Darcula.faint.setFill()
            NSRect(x: tickX - 0.5, y: Self.rulerHeight - 7, width: 1, height: 6).fill()
            (TimeFormat.string(seconds, decimals: decimals) as NSString).draw(at: NSPoint(x: tickX + 3, y: 4), withAttributes: attributes)
        }
    }

    private func drawScroller(_ state: TimelineState) {
        Darcula.surface.setFill()
        scrollerRect.fill()
        guard state.visibleLength < Double(state.peaks.length) * 0.999 else { return }
        let thumb = thumbRect(state)
        Darcula.muted.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: thumb, xRadius: thumb.height / 2, yRadius: thumb.height / 2).fill()
    }

    override func resetCursorRects() {
        guard let state else { return }
        for cut in cuts {
            let cutX = x(Double(cut), state)
            guard cutX >= -8, cutX <= bounds.width + 8 else { continue }
            addCursorRect(NSRect(x: cutX - 4, y: Self.rulerHeight, width: 8, height: scrollerRect.minY - Self.rulerHeight),
                          cursor: .resizeLeftRight)
            addCursorRect(flagRect(cutX), cursor: .pointingHand)
        }
        for segment in state.segments {
            guard let handles = fadeHandles(segment, state) else { continue }
            for handle in [handles.fadeIn, handles.fadeOut] {
                let size = Self.handleRadius * 2 + 6
                addCursorRect(NSRect(x: handle.x - size / 2, y: handle.y - size / 2, width: size, height: size), cursor: .resizeLeftRight)
            }
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let state else { return }
        let point = convert(event.locationInWindow, from: nil)
        if scrollerRect.contains(point) {
            let thumb = thumbRect(state)
            let grab = thumb.contains(point) ? point.x - thumb.minX : thumb.width / 2
            drag = .scroller(grab: grab)
            scroll(to: point.x - grab, state)
        } else if let index = flag(at: point) {
            drag = .cut(index: index, onFlag: true, moved: false, startX: point.x)
        } else if let hit = fadeHandle(at: point) {
            drag = .fade(index: hit.index, edge: hit.edge, grab: point.x - hit.handle.x)
            let segment = state.segments[hit.index]
            onFade?(hit.index, hit.edge, hit.edge == .fadeIn ? segment.fadeIn : segment.fadeOut, .began)
        } else if let index = cutLine(near: point) {
            drag = .cut(index: index, onFlag: false, moved: false, startX: point.x)
        } else if point.y > Self.rulerHeight, let index = segmentIndex(at: frame(atX: point.x, state), state),
                  state.segments[index].track == track(atY: point.y) {
            drag = .part(index: index, start: point, movingToTrack: nil)
        } else {
            drag = .seek
            onSeek?(Int64(frame(atX: point.x, state)), false)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let state, let drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        let target = Int64(frame(atX: min(max(0, point.x), bounds.width), state))
        switch drag {
        case .seek:
            onSeek?(target, false)
        case .cut(let index, let onFlag, let moved, let startX):
            if !moved {
                guard abs(point.x - startX) >= 3 else { return }
                onMoveCut?(index, target, .began)
                self.drag = .cut(index: index, onFlag: onFlag, moved: true, startX: startX)
            }
            onMoveCut?(index, target, .changed)
        case .part(let index, let start, let moving):
            if moving == nil {
                let dx = abs(point.x - start.x), dy = abs(point.y - start.y)
                if dy >= 6 && dy > dx {
                    self.drag = .part(index: index, start: start, movingToTrack: track(atY: point.y))
                    needsDisplay = true
                } else if dx >= 3 {
                    self.drag = .seek
                    onSeek?(target, false)
                }
            } else {
                self.drag = .part(index: index, start: start, movingToTrack: track(atY: point.y))
                needsDisplay = true
            }
        case .fade(let index, let edge, let grab):
            onFade?(index, edge, fadeFrames(index, edge, handleX: point.x - grab, state), .changed)
        case .scroller(let grab):
            scroll(to: point.x - grab, state)
        }
    }

    /// Fade length for a handle dragged to `handleX`; within a few points of the corner it is off.
    private func fadeFrames(_ index: Int, _ edge: FadeEdge, handleX: CGFloat, _ state: TimelineState) -> Int64 {
        guard state.segments.indices.contains(index) else { return 0 }
        let box = partBox(state.segments[index], state)
        let distance = edge == .fadeIn ? handleX - box.minX : box.maxX - handleX
        guard distance > 8 else { return 0 }
        return Int64(Double(distance / max(1, bounds.width)) * state.visibleLength)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            drag = nil
            needsDisplay = true
        }
        guard let state, let drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        let target = Int64(frame(atX: min(max(0, point.x), bounds.width), state))
        switch drag {
        case .seek:
            onSeek?(target, true)
        case .cut(let index, let onFlag, let moved, _):
            if moved {
                onMoveCut?(index, target, .ended)
            } else if onFlag {
                onRemoveCut?(index)
            }
        case .part(let index, let start, let moving):
            if let moving {
                guard state.segments.indices.contains(index) else { return }
                let segment = state.segments[index]
                if moving != segment.track || segment.deleted { onMoveToTrack?(segment.id, moving) }
            } else {
                onSeek?(Int64(frame(atX: start.x, state)), true)
            }
        case .fade(let index, let edge, let grab):
            onFade?(index, edge, fadeFrames(index, edge, handleX: point.x - grab, state), .ended)
        case .scroller:
            break
        }
    }

    private func scroll(to thumbLeft: CGFloat, _ state: TimelineState) {
        let length = Double(state.peaks.length)
        let thumbWidth = thumbRect(state).width
        let fraction = Double(thumbLeft / max(1, bounds.width - thumbWidth))
        onScroll?(fraction * (length - state.visibleLength))
    }

    // MARK: Scrolling and zoom

    override func scrollWheel(with event: NSEvent) {
        guard let state else { return }
        let precise = event.hasPreciseScrollingDeltas
        if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) {
            let delta = Double(event.scrollingDeltaY) * (precise ? 1 : 8)
            let anchor = frame(atX: convert(event.locationInWindow, from: nil).x, state)
            onZoom?(pow(1.01, delta), anchor)
            return
        }
        let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        let delta = Double(horizontal ? event.scrollingDeltaX : event.scrollingDeltaY) * (precise ? 1 : 12)
        onScroll?(state.visibleStart - delta * state.visibleLength / Double(max(1, bounds.width)))
    }

    override func magnify(with event: NSEvent) {
        guard let state else { return }
        let anchor = frame(atX: convert(event.locationInWindow, from: nil).x, state)
        onZoom?(1 + Double(event.magnification), anchor)
    }
}

struct TimelineView: NSViewRepresentable {
    let state: TimelineState
    let model: AppModel

    func makeNSView(context: Context) -> TimelineNSView {
        let view = TimelineNSView()
        view.onSeek = { [weak model] frame, final in model?.seek(to: frame, final: final) }
        view.onMoveCut = { [weak model] index, frame, phase in model?.moveCut(index, to: frame, phase: phase) }
        view.onRemoveCut = { [weak model] index in model?.removeCut(index) }
        view.onMoveToTrack = { [weak model] id, track in model?.setTrack(track, for: id) }
        view.onFade = { [weak model] index, edge, frames, phase in model?.setFade(edge, of: index, to: frames, phase: phase) }
        view.onScroll = { [weak model] start in model?.scroll(to: start) }
        view.onZoom = { [weak model] factor, anchor in model?.zoom(by: factor, around: anchor) }
        view.onResize = { [weak model] width in model?.setViewWidth(width) }
        return view
    }

    func updateNSView(_ view: TimelineNSView, context: Context) {
        view.state = state
    }
}
