import AppKit
import SwiftUI

enum Style {
    /// VideoHub's main color (the icon's green): the sound.
    static let main = StudioApp.video.color
    /// Waveforms and text on the dark background.
    static let ink = StudioApp.video.ink
    /// The current part, the selected title, where a moved part would go.
    static let selection = Darcula.text
    /// Titles in the timeline.
    static let title = NSColor.systemOrange
    /// Dissolves in the timeline.
    static let transition = NSColor.systemPurple
}

/// Everything the timeline draws. Positions are sequence ticks (see `EditList`).
struct TimelineState {
    var parts: [Part]
    var playhead: Int64
    var visibleStart: Double
    var visibleLength: Double
    var timescale: Double
    var frameTicks: Int64
    var aspectRatio: CGFloat
    var hasAudio: Bool
    var peaks: Peaks?
    var audioRate: Double
    var titles: [PlacedTitle] = []
    var selectedTitle: UUID?
    /// The transition at every boundary: 0 the start, `parts.count` the end.
    var transitions: [Transition?] = []
    var regions: [EffectLayout.Region] = []

    var sequenceLength: Int64 { parts.reduce(0) { $0 + $1.length } }

    var starts: [Int64] {
        var result: [Int64] = []
        var position: Int64 = 0
        for part in parts {
            result.append(position)
            position += part.length
        }
        return result
    }

    func isCut(_ boundary: Int) -> Bool {
        boundary >= 0 && boundary + 1 < parts.count && parts[boundary].end == parts[boundary + 1].start
    }

    /// The part at the playhead; the end of the edit belongs to the last part.
    var currentIndex: Int? {
        var start: Int64 = 0
        for (index, part) in parts.enumerated() {
            if playhead < start + part.length { return playhead >= start ? index : nil }
            start += part.length
        }
        return parts.isEmpty || playhead != start ? nil : parts.count - 1
    }

    /// The detached sounds, the top layer last (it is drawn last and hit first).
    var detachedSounds: [(index: Int, sound: Sound)] {
        parts.indices.compactMap { index -> (index: Int, sound: Sound)? in
            if case .detached(let sound) = parts[index].sound { (index, sound) } else { nil }
        }.sorted { $0.sound.layer < $1.sound.layer }
    }
}

/// The timeline: time ruler, the title lane, the picture lane with thumbnails and the sound lane
/// with the waveform, one box per part in playback order, and a scroll bar. Click or drag to move
/// the playhead, drag the edge of a part to shorten or lengthen it, drag a cut to move it (× in the
/// ruler removes it), drag a picture to move the part elsewhere, scroll to pan, pinch or ⌥-scroll to
/// zoom. Detached sounds lie on top of the sound lane: drag them to shift them, drag their edges to
/// trim them. Titles work the same way in their lane; a double click there adds one. A button on
/// every boundary of the picture lane (and at the start and end) opens the transition menu.
final class TimelineNSView: NSView, NSViewToolTipOwner {
    static let rulerHeight: CGFloat = 24
    static let titleHeight: CGFloat = 26
    static let videoHeight: CGFloat = 78
    static let audioHeight: CGFloat = 56
    static let scrollerHeight: CGFloat = 12
    static let totalHeight = rulerHeight + titleHeight + videoHeight + audioHeight + scrollerHeight
    static let badgeSize: CGFloat = 20
    static let flagSize: CGFloat = 16
    static let edgeGrab: CGFloat = 6

    var state: TimelineState? {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    weak var thumbnails: ThumbnailCache?
    var onSeek: ((Int64, Bool) -> Void)?
    var onMoveCut: ((Int, Int64, DragPhase) -> Void)?
    var onTrim: ((Int, PartEdge, Int64, DragPhase) -> Void)?
    var onRemoveCut: ((Int) -> Void)?
    var onMovePart: ((Int, Int) -> Void)?
    var onMoveSound: ((Int, Int64, DragPhase) -> Void)?
    var onTrimSound: ((Int, PartEdge, Int64, DragPhase) -> Void)?
    var onSelectTitle: ((UUID) -> Void)?
    var onAddTitle: ((Int64) -> Void)?
    var onMoveTitle: ((UUID, Int64, DragPhase) -> Void)?
    var onTrimTitle: ((UUID, PartEdge, Int64, DragPhase) -> Void)?
    var onSetTransition: ((Int, Transition.Kind?) -> Void)?
    var onSetTransitionLength: ((Int, Double) -> Void)?
    var onScroll: ((Double) -> Void)?
    var onZoom: ((Double, Double) -> Void)?
    var onResize: ((Double) -> Void)?

    private enum EdgeHit {
        case cut(Int)
        case trim(Int, PartEdge)
    }

    private enum SoundHit {
        case body(Int)
        case edge(Int, PartEdge)
    }

    private enum Drag {
        case seek
        case scroller(grab: CGFloat)
        /// Source position of the cut when the drag began, and the zoom then.
        case cut(boundary: Int, onFlag: Bool, moved: Bool, startX: CGFloat, origin: Int64, ticksPerPoint: Double)
        case trim(index: Int, edge: PartEdge, moved: Bool, startX: CGFloat, origin: Int64, ticksPerPoint: Double)
        /// Pressed on a picture: a click seeks, dragging sideways moves the part.
        case part(index: Int, start: NSPoint, moving: Bool, x: CGFloat, grab: CGFloat)
        /// Pressed on a detached sound: a click seeks, dragging shifts it (`origin`: its shift then).
        case sound(index: Int, moved: Bool, startX: CGFloat, origin: Int64, ticksPerPoint: Double)
        case soundEdge(index: Int, edge: PartEdge, moved: Bool, startX: CGFloat, origin: Int64, ticksPerPoint: Double)
        /// Pressed on a title: a click selects it, dragging moves it (`origin`: its start then).
        case title(id: UUID, moved: Bool, startX: CGFloat, origin: Int64, ticksPerPoint: Double)
        case titleEdge(id: UUID, edge: PartEdge, moved: Bool, startX: CGFloat, origin: Int64, ticksPerPoint: Double)
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

    private func x(_ position: Double, _ state: TimelineState) -> CGFloat {
        CGFloat((position - state.visibleStart) / state.visibleLength) * bounds.width
    }

    private func position(atX x: CGFloat, _ state: TimelineState) -> Double {
        state.visibleStart + Double(x / max(1, bounds.width)) * state.visibleLength
    }

    private func ticksPerPoint(_ state: TimelineState) -> Double { state.visibleLength / Double(max(1, bounds.width)) }

    private var titleLane: NSRect { NSRect(x: 0, y: Self.rulerHeight, width: bounds.width, height: Self.titleHeight) }
    private var videoLane: NSRect { NSRect(x: 0, y: titleLane.maxY, width: bounds.width, height: Self.videoHeight) }
    private var audioLane: NSRect { NSRect(x: 0, y: videoLane.maxY, width: bounds.width, height: Self.audioHeight) }
    private var lanes: NSRect { NSRect(x: 0, y: videoLane.minY, width: bounds.width, height: Self.videoHeight + Self.audioHeight) }
    private var scrollerRect: NSRect {
        NSRect(x: 0, y: bounds.height - Self.scrollerHeight, width: bounds.width, height: Self.scrollerHeight)
    }

    /// The box of part `index` in a lane.
    private func box(_ index: Int, in lane: NSRect, _ state: TimelineState, starts: [Int64]) -> NSRect {
        let left = x(Double(starts[index]), state)
        let right = x(Double(starts[index] + state.parts[index].length), state)
        return NSRect(x: left + 1, y: lane.minY + 3, width: max(1, right - left - 2), height: lane.height - 6)
    }

    /// The box of a detached sound, wherever it plays.
    private func soundBox(_ index: Int, _ sound: Sound, _ state: TimelineState, starts: [Int64]) -> NSRect {
        let position = starts[index] + sound.start - state.parts[index].start + sound.shift
        let left = x(Double(position), state), right = x(Double(position + sound.length), state)
        return NSRect(x: left + 1, y: audioLane.minY + 3, width: max(1, right - left - 2), height: audioLane.height - 6)
    }

    /// The detached sound at `point` (the top one where they overlap): its body or an edge.
    private func soundHit(at point: NSPoint) -> SoundHit? {
        guard let state, audioLane.contains(point) else { return nil }
        let starts = state.starts
        for (index, sound) in state.detachedSounds.reversed() {
            let frame = soundBox(index, sound, state, starts: starts)
            guard point.x >= frame.minX - Self.edgeGrab, point.x <= frame.maxX + Self.edgeGrab else { continue }
            if abs(point.x - frame.minX) <= Self.edgeGrab { return .edge(index, .start) }
            if abs(point.x - frame.maxX) <= Self.edgeGrab { return .edge(index, .end) }
            return .body(index)
        }
        return nil
    }

    private func titleBox(_ placed: PlacedTitle, _ state: TimelineState) -> NSRect {
        let left = x(Double(placed.start), state), right = x(Double(placed.end), state)
        return NSRect(x: left + 1, y: titleLane.minY + 3, width: max(2, right - left - 2), height: titleLane.height - 6)
    }

    private enum TitleHit {
        case body(UUID)
        case edge(UUID, PartEdge)
    }

    /// The title at `point` (the later one where they overlap): its body or an edge.
    private func titleHit(at point: NSPoint) -> TitleHit? {
        guard let state, titleLane.contains(point) else { return nil }
        for placed in state.titles.reversed() {
            let frame = titleBox(placed, state)
            guard point.x >= frame.minX - Self.edgeGrab, point.x <= frame.maxX + Self.edgeGrab else { continue }
            if frame.width > Self.edgeGrab * 2 {
                if abs(point.x - frame.minX) <= Self.edgeGrab { return .edge(placed.title.id, .start) }
                if abs(point.x - frame.maxX) <= Self.edgeGrab { return .edge(placed.title.id, .end) }
            }
            return .body(placed.title.id)
        }
        return nil
    }

    /// The transition button of a boundary: on a cut, or just inside the start and the end.
    private func badgeRect(_ boundary: Int, _ state: TimelineState, starts: [Int64]) -> NSRect {
        let count = state.parts.count
        var center = x(Double(boundary < count ? starts[boundary] : state.sequenceLength), state)
        if boundary == 0 { center += Self.badgeSize / 2 + 6 }
        if boundary == count { center -= Self.badgeSize / 2 + 6 }
        return NSRect(x: round(center - Self.badgeSize / 2), y: round(videoLane.midY - Self.badgeSize / 2),
                      width: Self.badgeSize, height: Self.badgeSize)
    }

    private func badge(at point: NSPoint) -> Int? {
        guard let state, videoLane.contains(point), !state.parts.isEmpty else { return nil }
        let starts = state.starts
        return (0...state.parts.count).reversed().first { badgeRect($0, state, starts: starts).insetBy(dx: -2, dy: -2).contains(point) }
    }

    private func thumbRect(_ state: TimelineState) -> NSRect {
        let length = Double(max(1, state.sequenceLength))
        let width = max(24, CGFloat(state.visibleLength / length) * bounds.width)
        let left = CGFloat(state.visibleStart / length) * (bounds.width - width) / max(0.0001, CGFloat(1 - state.visibleLength / length))
        return NSRect(x: min(left, bounds.width - width), y: scrollerRect.minY + 3, width: width, height: Self.scrollerHeight - 6)
    }

    private func flagRect(_ cutX: CGFloat) -> NSRect {
        NSRect(x: round(cutX) - Self.flagSize / 2, y: (Self.rulerHeight - Self.flagSize) / 2, width: Self.flagSize, height: Self.flagSize)
    }

    private func flag(at point: NSPoint) -> Int? {
        guard let state, point.y < Self.rulerHeight else { return nil }
        let starts = state.starts
        return state.parts.indices.dropLast().first {
            state.isCut($0) && flagRect(x(Double(starts[$0 + 1]), state)).insetBy(dx: -2, dy: -2).contains(point)
        }
    }

    /// The edge of a part near `point`: at a cut both parts change, elsewhere only the part itself.
    private func edge(at point: NSPoint) -> EdgeHit? {
        guard let state, lanes.contains(point) else { return nil }
        let starts = state.starts
        var best: (distance: CGFloat, hit: EdgeHit)?
        for (index, part) in state.parts.enumerated() {
            let left = x(Double(starts[index]), state), right = x(Double(starts[index] + part.length), state)
            guard right >= -Self.edgeGrab, left <= bounds.width + Self.edgeGrab else { continue }
            for (edgeX, edge) in [(left, PartEdge.start), (right, PartEdge.end)] {
                let distance = abs(point.x - edgeX)
                guard distance <= Self.edgeGrab, best == nil || distance < best!.distance else { continue }
                var hit = EdgeHit.trim(index, edge)
                if edge == .end, state.isCut(index) { hit = .cut(index) }
                if edge == .start, state.isCut(index - 1) { hit = .cut(index - 1) }
                best = (distance, hit)
            }
        }
        return best?.hit
    }

    private func partIndex(atX x: CGFloat, _ state: TimelineState) -> Int? {
        let position = position(atX: x, state)
        guard position >= 0, position < Double(state.sequenceLength) else { return nil }
        var start: Int64 = 0
        for (index, part) in state.parts.enumerated() {
            if position < Double(start + part.length) { return index }
            start += part.length
        }
        return nil
    }

    /// Where a dragged part would go: in front of the first other part whose middle is right of `x`.
    private func destination(forX x: CGFloat, moving index: Int, _ state: TimelineState) -> Int {
        let position = position(atX: x, state)
        let starts = state.starts
        for (other, part) in state.parts.enumerated() where other != index {
            if position < Double(starts[other]) + Double(part.length) / 2 { return other }
        }
        return state.parts.count
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        Darcula.background.setFill()
        bounds.fill()
        guard let state, state.visibleLength > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        let width = bounds.width
        let starts = state.starts
        let visibleEnd = state.visibleStart + state.visibleLength

        for lane in [titleLane, videoLane, audioLane] {
            Darcula.text.withAlphaComponent(0.03).setFill()
            lane.fill()
            Darcula.border.setFill()
            NSRect(x: 0, y: lane.maxY - 1, width: width, height: 1).fill()
        }

        var movingIndex: Int?
        if case .part(let index, _, true, _, _) = drag { movingIndex = index }
        var wanted: [ThumbnailKey] = []
        let currentIndex = state.currentIndex
        for (index, part) in state.parts.enumerated() {
            let start = starts[index]
            guard Double(start + part.length) > state.visibleStart, Double(start) < visibleEnd else { continue }
            let current = index == currentIndex
            drawPicture(index, state, starts: starts, current: current, context: context, wanted: &wanted)
            drawSound(index, state, starts: starts, current: current, context: context)
            if index == movingIndex {
                Darcula.background.withAlphaComponent(0.6).setFill()
                box(index, in: videoLane, state, starts: starts).fill(using: .sourceOver)
                box(index, in: audioLane, state, starts: starts).fill(using: .sourceOver)
            }
        }
        thumbnails?.want(wanted)

        drawRuler(state, visibleEnd: visibleEnd)

        // Cuts across both lanes, with a button with × in the ruler that removes them.
        for boundary in state.parts.indices.dropLast() where state.isCut(boundary) {
            let position = Double(starts[boundary + 1])
            guard position >= state.visibleStart, position <= visibleEnd else { continue }
            let cutX = round(x(position, state)) + 0.5
            Darcula.text.withAlphaComponent(0.7).setFill()
            NSRect(x: cutX - 0.5, y: lanes.minY, width: 1, height: lanes.height).fill()
            let flag = flagRect(cutX)
            Darcula.text.setFill()
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

        drawDetachedSounds(state, starts: starts, context: context)
        drawRegions(state, starts: starts)
        drawTitles(state)
        drawBadges(state, starts: starts)

        // A part being moved: where it would go, and the part under the mouse.
        if case .part(let index, _, true, let mouseX, let grab) = drag, state.parts.indices.contains(index) {
            let target = destination(forX: mouseX, moving: index, state)
            let targetX = round(x(Double(target < state.parts.count ? starts[target] : state.sequenceLength), state))
            Style.selection.setFill()
            NSRect(x: targetX - 1.5, y: lanes.minY, width: 3, height: lanes.height).fill()
            let original = box(index, in: videoLane, state, starts: starts)
            let ghost = NSRect(x: mouseX - grab, y: original.minY - 2, width: original.width, height: original.height + 4)
            let path = NSBezierPath(roundedRect: ghost, xRadius: 5, yRadius: 5)
            Style.selection.withAlphaComponent(0.22).setFill()
            path.fill()
            Style.selection.setStroke()
            path.lineWidth = 2
            path.stroke()
            drawLabel("\(index + 1)", in: ghost)
        }

        // Playhead with a small triangle in the ruler.
        if Double(state.playhead) >= state.visibleStart && Double(state.playhead) <= visibleEnd {
            let playX = round(x(Double(state.playhead), state)) + 0.5
            NSColor.systemRed.setFill()
            NSRect(x: playX - 0.75, y: Self.rulerHeight - 6, width: 1.5, height: lanes.maxY - Self.rulerHeight + 6).fill()
            let triangle = NSBezierPath()
            triangle.move(to: NSPoint(x: playX - 6, y: Self.rulerHeight - 10))
            triangle.line(to: NSPoint(x: playX + 6, y: Self.rulerHeight - 10))
            triangle.line(to: NSPoint(x: playX, y: Self.rulerHeight - 2))
            triangle.close()
            triangle.fill()
        }

        drawScroller(state)
    }

    /// Where transitions run, over the pictures: darkening towards black, or a cross for a dissolve.
    private func drawRegions(_ state: TimelineState, starts: [Int64]) {
        let count = state.parts.count
        for region in state.regions {
            let left = x(Double(region.range.lowerBound), state), right = x(Double(region.range.upperBound), state)
            guard right >= 0, left <= bounds.width, right - left >= 1 else { continue }
            let rect = NSRect(x: left, y: videoLane.minY + 3, width: right - left, height: videoLane.height - 6)
            switch region.kind {
            case .black:
                let clear = NSColor.black.withAlphaComponent(0), dark = NSColor.black.withAlphaComponent(0.85)
                if region.boundary == 0 {
                    NSGradient(starting: dark, ending: clear)?.draw(in: rect, angle: 0)
                } else if region.boundary == count {
                    NSGradient(starting: clear, ending: dark)?.draw(in: rect, angle: 0)
                } else {
                    let cut = x(Double(starts[region.boundary]), state)
                    NSGradient(starting: clear, ending: dark)?.draw(in: NSRect(x: left, y: rect.minY, width: cut - left, height: rect.height), angle: 0)
                    NSGradient(starting: dark, ending: clear)?.draw(in: NSRect(x: cut, y: rect.minY, width: right - cut, height: rect.height), angle: 0)
                }
            case .dissolve:
                Style.transition.withAlphaComponent(0.3).setFill()
                rect.fill(using: .sourceOver)
                let cross = NSBezierPath()
                cross.move(to: NSPoint(x: rect.minX, y: rect.maxY))
                cross.line(to: NSPoint(x: rect.maxX, y: rect.minY))
                cross.move(to: NSPoint(x: rect.minX, y: rect.minY))
                cross.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
                cross.lineWidth = 1.5
                Style.transition.setStroke()
                cross.stroke()
            }
        }
    }

    /// The titles in their lane, with the first line of their text.
    private func drawTitles(_ state: TimelineState) {
        for placed in state.titles {
            let frame = titleBox(placed, state)
            guard frame.maxX >= 0, frame.minX <= bounds.width else { continue }
            let selected = placed.title.id == state.selectedTitle
            let path = NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4)
            Darcula.background.setFill()
            path.fill()
            Style.title.withAlphaComponent(selected ? 0.45 : 0.25).setFill()
            path.fill()
            (selected ? Style.selection : Style.title).setStroke()
            path.lineWidth = selected ? 2 : 1
            path.stroke()
            let line = placed.title.text.split(separator: "\n").first.map(String.init) ?? ""
            let visible = NSRect(x: max(frame.minX, 0) + 6, y: frame.minY, width: min(frame.maxX, bounds.width) - max(frame.minX, 0) - 10,
                                 height: frame.height)
            guard visible.width > 12, !line.isEmpty else { continue }
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                             .foregroundColor: Darcula.text]
            let text = NSAttributedString(string: line, attributes: attributes)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: visible).addClip()
            text.draw(at: NSPoint(x: visible.minX, y: visible.midY - text.size().height / 2))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// A button on every boundary: + without a transition, a filled circle with one.
    private func drawBadges(_ state: TimelineState, starts: [Int64]) {
        guard !state.parts.isEmpty else { return }
        for boundary in 0...state.parts.count {
            let rect = badgeRect(boundary, state, starts: starts)
            guard rect.maxX >= 0, rect.minX <= bounds.width else { continue }
            let transition = boundary < state.transitions.count ? state.transitions[boundary] : nil
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            let symbol: String
            let color: NSColor
            switch transition?.kind {
            case nil:
                Darcula.surface.withAlphaComponent(0.9).setFill()
                circle.fill()
                Darcula.border.setStroke()
                circle.lineWidth = 1
                circle.stroke()
                symbol = "plus"
                color = Darcula.muted
            case .dissolve where boundary > 0 && boundary < state.parts.count:
                Style.transition.setFill()
                circle.fill()
                symbol = "square.on.square"
                color = .white
            default:
                NSColor.black.setFill()
                circle.fill()
                NSColor.white.withAlphaComponent(0.8).setStroke()
                circle.lineWidth = 1.5
                circle.stroke()
                symbol = boundary == 0 ? "sunrise.fill" : boundary == state.parts.count ? "sunset.fill" : "moon.fill"
                color = .white
            }
            let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
            else { continue }
            let target = NSRect(x: rect.midX - image.size.width / 2, y: rect.midY - image.size.height / 2,
                                width: image.size.width, height: image.size.height)
            image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    // MARK: Transition menu

    private final class MenuAction: NSMenuItem {
        private let handler: () -> Void

        init(_ title: String, on: Bool = false, enabled: Bool = true, handler: @escaping () -> Void) {
            self.handler = handler
            super.init(title: title, action: #selector(run), keyEquivalent: "")
            target = self
            state = on ? .on : .off
            isEnabled = enabled
        }

        required init(coder: NSCoder) { fatalError("not used") }

        @objc private func run() { handler() }
    }

    static let transitionLengths: [Double] = [0.25, 0.5, 1, 2]

    static func seconds(_ value: Double) -> String {
        (value.rounded() == value ? String(format: "%.0f s", value) : String(format: "%g s", value))
            .replacingOccurrences(of: ".", with: ",")
    }

    private func showTransitionMenu(_ boundary: Int, _ state: TimelineState, starts: [Int64]) {
        let count = state.parts.count
        let current = boundary < state.transitions.count ? state.transitions[boundary] : nil
        let menu = NSMenu()
        menu.autoenablesItems = false
        let set = { [weak self] (kind: Transition.Kind?) in self?.onSetTransition?(boundary, kind) }
        if boundary == 0 {
            menu.addItem(MenuAction("Nicht einblenden", on: current == nil) { set(nil) })
            menu.addItem(MenuAction("Aus Schwarz einblenden", on: current != nil) { set(.black) })
        } else if boundary == count {
            menu.addItem(MenuAction("Nicht ausblenden", on: current == nil) { set(nil) })
            menu.addItem(MenuAction("In Schwarz ausblenden", on: current != nil) { set(.black) })
        } else {
            menu.addItem(MenuAction("Kein Übergang", on: current == nil) { set(nil) })
            menu.addItem(MenuAction("Überblendung", on: current?.kind == .dissolve) { set(.dissolve) })
            menu.addItem(MenuAction("Abblende über Schwarz", on: current?.kind == .black) { set(.black) })
        }
        menu.addItem(.separator())
        let heading = NSMenuItem(title: current == nil ? "Länge neuer Übergänge" : "Länge", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        let wished = current.map { Double($0.duration) / state.timescale }
        for length in Self.transitionLengths {
            let on = wished.map { abs($0 - length) < 0.02 } ?? false
            menu.addItem(MenuAction(Self.seconds(length), on: on) { [weak self] in self?.onSetTransitionLength?(boundary, length) })
        }
        if let region = state.regions.first(where: { $0.boundary == boundary }), region.shortened {
            menu.addItem(.separator())
            let actual = Double(region.range.count) / state.timescale
            let reason = region.kind == .dissolve && boundary > 0 && boundary < count
                ? "zu wenig Material hinter dem Schnitt" : "der Teil ist zu kurz"
            let note = NSMenuItem(title: "Nur \(String(format: "%.2f", actual).replacingOccurrences(of: ".", with: ",")) s – \(reason)",
                                  action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        } else if current?.kind == .dissolve, boundary > 0, boundary < count,
                  !state.regions.contains(where: { $0.boundary == boundary }) {
            menu.addItem(.separator())
            let note = NSMenuItem(title: "Keine Überblendung möglich – kein Material hinter dem Schnitt", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
        let rect = badgeRect(boundary, state, starts: starts)
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY + 4), in: self)
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let state, let boundary = badge(at: point) else { return "" }
        let count = state.parts.count
        let current = boundary < state.transitions.count ? state.transitions[boundary] : nil
        guard let current else {
            return boundary == 0 ? "Einblenden aus Schwarz …" : boundary == count ? "Ausblenden in Schwarz …" : "Übergang wählen …"
        }
        let length = Self.seconds((Double(current.duration) / state.timescale * 100).rounded() / 100)
        let name = boundary == 0 ? "Einblenden" : boundary == count ? "Ausblenden"
            : current.kind == .dissolve ? "Überblendung" : "Abblende über Schwarz"
        return "\(name), \(length) – klicken zum Ändern"
    }

    /// The pictures of a part: thumbnails on a grid of the source (shared by all zoom levels with
    /// the same tile width); the first tile of a part shows its first frame.
    private func drawPicture(_ index: Int, _ state: TimelineState, starts: [Int64], current: Bool, context: CGContext,
                             wanted: inout [ThumbnailKey]) {
        let part = state.parts[index]
        let start = starts[index]
        let frame = box(index, in: videoLane, state, starts: starts)
        let path = NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        Darcula.surface.setFill()
        frame.fill()

        let perPoint = ticksPerPoint(state)
        let tileWidth = max(18, frame.height * state.aspectRatio)
        var step = max(1, state.frameTicks)
        while Double(step) < Double(tileWidth) * perPoint { step *= 2 }
        let left = max(frame.minX, 0), right = min(frame.maxX, bounds.width)
        let firstSource = part.start + Int64(max(0, position(atX: left, state) - Double(start)))
        var tile = firstSource / step
        while tile * step < part.end {
            let tileStart = tile * step
            tile += 1
            let tileX = max(x(Double(start + tileStart - part.start), state), frame.minX)
            guard tileX <= right else { break }
            let nextX = x(Double(start + tileStart + step - part.start), state)
            let rect = NSRect(x: tileX, y: frame.minY, width: max(1, nextX - tileX), height: frame.height)
            let key = ThumbnailKey(step: step, time: max(tileStart, part.start))
            guard let image = thumbnails?.image(key) else {
                wanted.append(key)
                continue
            }
            // Fill the tile (cropping the sides); the context is flipped, the image is not.
            let imageAspect = CGFloat(image.width) / CGFloat(max(1, image.height))
            var target = rect
            if imageAspect > rect.width / rect.height {
                target.size.width = rect.height * imageAspect
            } else {
                target.size.height = rect.width / imageAspect
                target.origin.y = rect.midY - target.height / 2
            }
            context.saveGState()
            context.clip(to: rect)
            context.translateBy(x: 0, y: target.minY + target.maxY)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .medium
            context.draw(image, in: target)
            context.restoreGState()
            NSColor.black.withAlphaComponent(0.35).setFill()
            NSRect(x: rect.maxX - 0.5, y: rect.minY, width: 0.5, height: rect.height).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        (current ? Style.selection : Darcula.text.withAlphaComponent(0.25)).setStroke()
        let border = NSBezierPath(roundedRect: frame.insetBy(dx: current ? 1 : 0.5, dy: current ? 1 : 0.5), xRadius: 4, yRadius: 4)
        border.lineWidth = current ? 2 : 1
        border.stroke()
        if frame.width > 26 { drawLabel("\(index + 1)", in: frame) }
    }

    private func drawLabel(_ text: String, in frame: NSRect, color: NSColor = NSColor.black.withAlphaComponent(0.55)) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let pill = NSRect(x: frame.minX + 4, y: frame.minY + 4, width: size.width + 10, height: size.height + 2)
        color.setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        (text as NSString).draw(at: NSPoint(x: pill.minX + 5, y: pill.minY + 1), withAttributes: attributes)
    }

    /// The sound of a part under its picture: a tinted box with the waveform of its source range,
    /// or an empty dashed box when the part is muted. Detached sounds are drawn on top later.
    private func drawSound(_ index: Int, _ state: TimelineState, starts: [Int64], current: Bool, context: CGContext) {
        let part = state.parts[index]
        let frame = box(index, in: audioLane, state, starts: starts)
        switch part.sound {
        case .detached:
            return
        case .muted:
            let path = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            path.setLineDash([4, 3], count: 2, phase: 0)
            path.lineWidth = current ? 1.5 : 1
            (current ? Style.selection : Darcula.muted.withAlphaComponent(0.6)).setStroke()
            path.stroke()
            if frame.width > 30 { drawSymbol("speaker.slash", in: frame) }
            return
        case .linked:
            break
        }
        let path = NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4)
        Style.main.withAlphaComponent(current ? 0.2 : 0.1).setFill()
        path.fill()
        Style.main.withAlphaComponent(current ? 0.9 : 0.4).setStroke()
        path.lineWidth = current ? 1.5 : 1
        path.stroke()

        guard state.hasAudio else {
            if frame.width > 70 {
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Darcula.faint]
                ("Kein Ton" as NSString).draw(at: NSPoint(x: max(frame.minX, 0) + 8, y: frame.midY - 7), withAttributes: attributes)
            }
            return
        }
        drawWaveform(in: frame, playing: part.start, at: starts[index], state, context: context)
    }

    /// Detached sounds over the sound lane, opaque, so that the sound they replace is hidden; a
    /// badge says whose sound it is and how far it is shifted.
    private func drawDetachedSounds(_ state: TimelineState, starts: [Int64], context: CGContext) {
        let current = state.currentIndex
        for (index, sound) in state.detachedSounds {
            let frame = soundBox(index, sound, state, starts: starts)
            guard frame.maxX >= 0, frame.minX <= bounds.width else { continue }
            let path = NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4)
            Darcula.background.setFill()
            path.fill()
            Style.main.withAlphaComponent(0.22).setFill()
            path.fill()
            drawWaveform(in: frame, playing: sound.start, at: starts[index] + sound.start - state.parts[index].start + sound.shift,
                         state, context: context)
            let isCurrent = index == current
            (isCurrent ? Style.selection : Style.main).setStroke()
            path.lineWidth = isCurrent ? 2 : 1.5
            path.stroke()
            guard frame.width > 26 else { continue }
            let seconds = Double(sound.shift) / state.timescale
            let shift = sound.shift == 0 ? "gelöst"
                : String(format: "%+.2f s", seconds).replacingOccurrences(of: ".", with: ",").replacingOccurrences(of: "-", with: "−")
            let visible = NSRect(x: max(frame.minX, 0), y: frame.minY, width: min(frame.maxX, bounds.width) - max(frame.minX, 0),
                                 height: frame.height)
            drawLabel(frame.width > 90 ? "\(index + 1) · \(shift)" : "\(index + 1)", in: visible, color: Style.main)
        }
    }

    /// The waveform of the source sound from `source` on, played from sequence position `position`.
    private func drawWaveform(in frame: NSRect, playing source: Int64, at position: Int64, _ state: TimelineState, context: CGContext) {
        guard let peaks = state.peaks, peaks.length > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2
        let step = 1 / scale
        let ratio = state.audioRate / state.timescale
        let framesPerColumn = ticksPerPoint(state) * Double(step) * ratio
        let level = peaks.level(forFramesPerPoint: framesPerColumn)
        let amplitude = (frame.height / 2 - 4) / CGFloat(max(peaks.peak, 0.05))
        let middle = frame.midY
        var columns: [CGRect] = []
        var column = max(frame.minX, 0)
        let end = min(frame.maxX, bounds.width)
        while column < end {
            let from = Double(source) + self.position(atX: column, state) - Double(position)
            let to = Double(source) + self.position(atX: column + step, state) - Double(position)
            if let (low, high) = peaks.range(from: Int64(from * ratio), to: Int64(to * ratio), level: level) {
                columns.append(CGRect(x: column, y: middle - CGFloat(high) * amplitude, width: step,
                                      height: max(step, CGFloat(high - low) * amplitude)))
            }
            column += step
        }
        context.setFillColor(Style.ink.cgColor)
        context.fill(columns)
    }

    private func drawSymbol(_ name: String, in frame: NSRect) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [Darcula.muted]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
        let middle = (max(frame.minX, 0) + min(frame.maxX, bounds.width)) / 2
        let rect = NSRect(x: middle - image.size.width / 2, y: frame.midY - image.size.height / 2,
                          width: image.size.width, height: image.size.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private func drawRuler(_ state: TimelineState, visibleEnd: Double) {
        Darcula.surface.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: Self.rulerHeight).fill()
        Darcula.border.setFill()
        NSRect(x: 0, y: Self.rulerHeight - 1, width: bounds.width, height: 1).fill()

        let secondsPerPoint = state.visibleLength / state.timescale / Double(max(1, bounds.width))
        let intervals: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200]
        let interval = intervals.first { $0 / secondsPerPoint >= 90 } ?? 7200
        let decimals = interval < 1 ? 1 : 0
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: Darcula.muted,
        ]
        let first = (state.visibleStart / state.timescale / interval).rounded(.down)
        var tick = 0.0
        while true {
            let seconds = (first + tick) * interval
            tick += 1
            let position = seconds * state.timescale
            if position > visibleEnd { break }
            let tickX = round(x(position, state)) + 0.5
            Darcula.faint.setFill()
            NSRect(x: tickX - 0.5, y: Self.rulerHeight - 7, width: 1, height: 6).fill()
            (TimeFormat.string(seconds, decimals: decimals) as NSString).draw(at: NSPoint(x: tickX + 3, y: 4), withAttributes: attributes)
        }
    }

    private func drawScroller(_ state: TimelineState) {
        Darcula.surface.setFill()
        scrollerRect.fill()
        guard state.visibleLength < Double(state.sequenceLength) * 0.999 else { return }
        let thumb = thumbRect(state)
        Darcula.muted.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: thumb, xRadius: thumb.height / 2, yRadius: thumb.height / 2).fill()
    }

    override func resetCursorRects() {
        removeAllToolTips()
        guard let state else { return }
        let starts = state.starts
        for placed in state.titles {
            let frame = titleBox(placed, state)
            if frame.width > Self.edgeGrab * 3 {
                addCursorRect(frame.insetBy(dx: Self.edgeGrab, dy: 0).intersection(bounds), cursor: .openHand)
                for edgeX in [frame.minX, frame.maxX] where edgeX >= -Self.edgeGrab && edgeX <= bounds.width + Self.edgeGrab {
                    addCursorRect(NSRect(x: edgeX - Self.edgeGrab / 2, y: frame.minY, width: Self.edgeGrab, height: frame.height),
                                  cursor: .resizeLeftRight)
                }
            }
        }
        for index in state.parts.indices {
            let picture = box(index, in: videoLane, state, starts: starts)
            if picture.width > Self.edgeGrab * 3 {
                addCursorRect(picture.insetBy(dx: Self.edgeGrab, dy: 0).intersection(bounds), cursor: .openHand)
            }
            for edgeX in [picture.minX - 1, picture.maxX + 1] where edgeX >= -Self.edgeGrab && edgeX <= bounds.width + Self.edgeGrab {
                addCursorRect(NSRect(x: edgeX - Self.edgeGrab / 2, y: lanes.minY, width: Self.edgeGrab, height: lanes.height),
                              cursor: .resizeLeftRight)
            }
        }
        for boundary in state.parts.indices.dropLast() where state.isCut(boundary) {
            addCursorRect(flagRect(x(Double(starts[boundary + 1]), state)), cursor: .pointingHand)
        }
        if !state.parts.isEmpty {
            for boundary in 0...state.parts.count {
                let rect = badgeRect(boundary, state, starts: starts)
                guard rect.maxX >= 0, rect.minX <= bounds.width else { continue }
                addCursorRect(rect, cursor: .pointingHand)
                addToolTip(rect, owner: self, userData: nil)
            }
        }
        for (index, sound) in state.detachedSounds {
            let frame = soundBox(index, sound, state, starts: starts)
            if frame.width > Self.edgeGrab * 3 {
                addCursorRect(frame.insetBy(dx: Self.edgeGrab, dy: 0).intersection(bounds), cursor: .openHand)
            }
            for edgeX in [frame.minX - 1, frame.maxX + 1] where edgeX >= -Self.edgeGrab && edgeX <= bounds.width + Self.edgeGrab {
                addCursorRect(NSRect(x: edgeX - Self.edgeGrab / 2, y: frame.minY, width: Self.edgeGrab, height: frame.height),
                              cursor: .resizeLeftRight)
            }
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let state else { return }
        let point = convert(event.locationInWindow, from: nil)
        let perPoint = ticksPerPoint(state)
        if scrollerRect.contains(point) {
            let thumb = thumbRect(state)
            let grab = thumb.contains(point) ? point.x - thumb.minX : thumb.width / 2
            drag = .scroller(grab: grab)
            scroll(to: point.x - grab, state)
        } else if let boundary = flag(at: point) {
            drag = .cut(boundary: boundary, onFlag: true, moved: false, startX: point.x, origin: state.parts[boundary].end,
                        ticksPerPoint: perPoint)
        } else if let boundary = badge(at: point) {
            drag = nil
            showTransitionMenu(boundary, state, starts: state.starts)
        } else if titleLane.contains(point) {
            switch titleHit(at: point) {
            case .body(let id):
                let start = state.titles.first { $0.title.id == id }?.start ?? 0
                drag = .title(id: id, moved: false, startX: point.x, origin: start, ticksPerPoint: perPoint)
            case .edge(let id, let edge):
                let placed = state.titles.first { $0.title.id == id }
                drag = .titleEdge(id: id, edge: edge, moved: false, startX: point.x,
                                  origin: (edge == .start ? placed?.start : placed?.end) ?? 0, ticksPerPoint: perPoint)
            case nil:
                let position = Int64(position(atX: point.x, state))
                if event.clickCount == 2 {
                    drag = nil
                    onAddTitle?(position)
                } else {
                    drag = .seek
                    onSeek?(position, false)
                }
            }
        } else if let hit = soundHit(at: point) {
            switch hit {
            case .body(let index):
                guard case .detached(let sound) = state.parts[index].sound else { return }
                drag = .sound(index: index, moved: false, startX: point.x, origin: sound.shift, ticksPerPoint: perPoint)
            case .edge(let index, let edge):
                guard case .detached(let sound) = state.parts[index].sound else { return }
                drag = .soundEdge(index: index, edge: edge, moved: false, startX: point.x,
                                  origin: edge == .start ? sound.start : sound.end, ticksPerPoint: perPoint)
            }
        } else if let hit = edge(at: point) {
            switch hit {
            case .cut(let boundary):
                drag = .cut(boundary: boundary, onFlag: false, moved: false, startX: point.x, origin: state.parts[boundary].end,
                            ticksPerPoint: perPoint)
            case .trim(let index, let edge):
                let part = state.parts[index]
                drag = .trim(index: index, edge: edge, moved: false, startX: point.x, origin: edge == .start ? part.start : part.end,
                             ticksPerPoint: perPoint)
            }
        } else if videoLane.contains(point), let index = partIndex(atX: point.x, state) {
            let picture = box(index, in: videoLane, state, starts: state.starts)
            drag = .part(index: index, start: point, moving: false, x: point.x, grab: point.x - picture.minX)
        } else {
            drag = .seek
            onSeek?(Int64(position(atX: point.x, state)), false)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let state, let drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        switch drag {
        case .seek:
            onSeek?(Int64(position(atX: min(max(0, point.x), bounds.width), state)), false)
        case .scroller(let grab):
            scroll(to: point.x - grab, state)
        case .cut(let boundary, let onFlag, let moved, let startX, let origin, let perPoint):
            guard moved || abs(point.x - startX) >= 3 else { return }
            onMoveCut?(boundary, origin + Int64(Double(point.x - startX) * perPoint), moved ? .changed : .began)
            self.drag = .cut(boundary: boundary, onFlag: onFlag, moved: true, startX: startX, origin: origin, ticksPerPoint: perPoint)
        case .trim(let index, let edge, let moved, let startX, let origin, let perPoint):
            guard moved || abs(point.x - startX) >= 2 else { return }
            onTrim?(index, edge, origin + Int64(Double(point.x - startX) * perPoint), moved ? .changed : .began)
            self.drag = .trim(index: index, edge: edge, moved: true, startX: startX, origin: origin, ticksPerPoint: perPoint)
        case .part(let index, let start, let moving, _, let grab):
            guard moving || abs(point.x - start.x) >= 4 else { return }
            if !moving { NSCursor.closedHand.set() }
            self.drag = .part(index: index, start: start, moving: true, x: point.x, grab: grab)
            needsDisplay = true
        case .sound(let index, let moved, let startX, let origin, let perPoint):
            guard moved || abs(point.x - startX) >= 3 else { return }
            if !moved { NSCursor.closedHand.set() }
            onMoveSound?(index, origin + Int64(Double(point.x - startX) * perPoint), moved ? .changed : .began)
            self.drag = .sound(index: index, moved: true, startX: startX, origin: origin, ticksPerPoint: perPoint)
        case .soundEdge(let index, let edge, let moved, let startX, let origin, let perPoint):
            guard moved || abs(point.x - startX) >= 2 else { return }
            onTrimSound?(index, edge, origin + Int64(Double(point.x - startX) * perPoint), moved ? .changed : .began)
            self.drag = .soundEdge(index: index, edge: edge, moved: true, startX: startX, origin: origin, ticksPerPoint: perPoint)
        case .title(let id, let moved, let startX, let origin, let perPoint):
            guard moved || abs(point.x - startX) >= 3 else { return }
            if !moved { NSCursor.closedHand.set() }
            onMoveTitle?(id, origin + Int64(Double(point.x - startX) * perPoint), moved ? .changed : .began)
            self.drag = .title(id: id, moved: true, startX: startX, origin: origin, ticksPerPoint: perPoint)
        case .titleEdge(let id, let edge, let moved, let startX, let origin, let perPoint):
            guard moved || abs(point.x - startX) >= 2 else { return }
            onTrimTitle?(id, edge, origin + Int64(Double(point.x - startX) * perPoint), moved ? .changed : .began)
            self.drag = .titleEdge(id: id, edge: edge, moved: true, startX: startX, origin: origin, ticksPerPoint: perPoint)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            drag = nil
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
        guard let state, let drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        switch drag {
        case .seek:
            onSeek?(Int64(position(atX: min(max(0, point.x), bounds.width), state)), true)
        case .scroller:
            break
        case .cut(let boundary, let onFlag, let moved, let startX, let origin, let perPoint):
            if moved {
                onMoveCut?(boundary, origin + Int64(Double(point.x - startX) * perPoint), .ended)
            } else if onFlag {
                onRemoveCut?(boundary)
            } else {
                onSeek?(Int64(position(atX: startX, state)), true)
            }
        case .trim(let index, let edge, let moved, let startX, let origin, let perPoint):
            if moved {
                onTrim?(index, edge, origin + Int64(Double(point.x - startX) * perPoint), .ended)
            } else {
                onSeek?(Int64(position(atX: startX, state)), true)
            }
        case .part(let index, let start, let moving, let mouseX, _):
            if moving {
                onMovePart?(index, destination(forX: mouseX, moving: index, state))
            } else {
                onSeek?(Int64(position(atX: start.x, state)), true)
            }
        case .sound(let index, let moved, let startX, let origin, let perPoint):
            if moved {
                onMoveSound?(index, origin + Int64(Double(point.x - startX) * perPoint), .ended)
            } else {
                onSeek?(Int64(position(atX: startX, state)), true)
            }
        case .soundEdge(let index, let edge, let moved, let startX, let origin, let perPoint):
            if moved {
                onTrimSound?(index, edge, origin + Int64(Double(point.x - startX) * perPoint), .ended)
            } else {
                onSeek?(Int64(position(atX: startX, state)), true)
            }
        case .title(let id, let moved, let startX, let origin, let perPoint):
            if moved {
                onMoveTitle?(id, origin + Int64(Double(point.x - startX) * perPoint), .ended)
            } else {
                onSelectTitle?(id)
            }
        case .titleEdge(let id, let edge, let moved, let startX, let origin, let perPoint):
            if moved {
                onTrimTitle?(id, edge, origin + Int64(Double(point.x - startX) * perPoint), .ended)
            } else {
                onSelectTitle?(id)
            }
        }
    }

    private func scroll(to thumbLeft: CGFloat, _ state: TimelineState) {
        let length = Double(state.sequenceLength)
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
            let anchor = position(atX: convert(event.locationInWindow, from: nil).x, state)
            onZoom?(pow(1.01, delta), anchor)
            return
        }
        let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        let delta = Double(horizontal ? event.scrollingDeltaX : event.scrollingDeltaY) * (precise ? 1 : 12)
        onScroll?(state.visibleStart - delta * state.visibleLength / Double(max(1, bounds.width)))
    }

    override func magnify(with event: NSEvent) {
        guard let state else { return }
        let anchor = position(atX: convert(event.locationInWindow, from: nil).x, state)
        onZoom?(1 + Double(event.magnification), anchor)
    }
}

struct TimelineView: NSViewRepresentable {
    let state: TimelineState
    let model: AppModel

    func makeNSView(context: Context) -> TimelineNSView {
        let view = TimelineNSView()
        // Since macOS 14 views draw past their bounds by default; a part being moved would cover the lane names.
        view.clipsToBounds = true
        view.thumbnails = model.thumbnails
        model.thumbnails.onUpdate = { [weak view] in view?.needsDisplay = true }
        view.onSeek = { [weak model] position, final in model?.seek(to: position, final: final) }
        view.onMoveCut = { [weak model] boundary, source, phase in model?.moveCut(boundary, to: source, phase: phase) }
        view.onTrim = { [weak model] index, edge, source, phase in model?.trim(index, edge, to: source, phase: phase) }
        view.onRemoveCut = { [weak model] boundary in model?.removeCut(boundary) }
        view.onMovePart = { [weak model] index, destination in model?.movePart(index, before: destination) }
        view.onMoveSound = { [weak model] index, shift, phase in model?.moveSound(index, to: shift, phase: phase) }
        view.onTrimSound = { [weak model] index, edge, source, phase in model?.trimSound(index, edge, to: source, phase: phase) }
        view.onSelectTitle = { [weak model] id in model?.selectTitle(id) }
        view.onAddTitle = { [weak model] position in model?.addTitle(at: position) }
        view.onMoveTitle = { [weak model] id, position, phase in model?.moveTitle(id, to: position, phase: phase) }
        view.onTrimTitle = { [weak model] id, edge, position, phase in model?.trimTitle(id, edge, to: position, phase: phase) }
        view.onSetTransition = { [weak model] boundary, kind in model?.setTransition(kind, at: boundary) }
        view.onSetTransitionLength = { [weak model] boundary, seconds in model?.setTransitionLength(seconds, at: boundary) }
        view.onScroll = { [weak model] start in model?.scroll(to: start) }
        view.onZoom = { [weak model] factor, anchor in model?.zoom(by: factor, around: anchor) }
        view.onResize = { [weak model] width in model?.setViewWidth(width) }
        return view
    }

    func updateNSView(_ view: TimelineNSView, context: Context) {
        view.state = state
    }
}
