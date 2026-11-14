import AppKit
import AVFoundation
import SwiftUI

/// The preview: two players whose layers lie on top of each other. A new edit (or the source while
/// an edge is dragged) is loaded into the hidden one and only swapped in once its frame is ready,
/// so the picture never flashes black after an edit.
@MainActor
final class VideoPlayer {
    let layers: [AVPlayerLayer]
    private let players = [AVPlayer(), AVPlayer()]
    private var active = 0
    /// The player that is being prepared, if any.
    private var pending: Int?
    private var generation = 0
    private var timeObservers: [Any] = []
    private var endObserver: NSObjectProtocol?
    private var readyObservation: NSKeyValueObservation?
    private var seekTarget: CMTime?
    private var isSeeking = false
    private(set) var wantsPlaying = false
    /// True while the plain source is shown (dragging an edge), not the edit.
    private(set) var showsSource = false

    /// The time of the edit while it plays.
    var onTime: ((CMTime) -> Void)?
    /// The edit played to its end.
    var onEnd: (() -> Void)?

    init() {
        layers = players.map { player in
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspect
            return layer
        }
        layers[1].opacity = 0
        for (index, player) in players.enumerated() {
            player.actionAtItemEnd = .pause
            let observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self, index == self.active, self.pending == nil, !self.showsSource, !self.isSeeking,
                          self.wantsPlaying else { return }
                    self.onTime?(time)
                }
            }
            timeObservers.append(observer)
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil,
                                                             queue: .main) { [weak self] notification in
            let item = notification.object as? AVPlayerItem
            MainActor.assumeIsolated {
                guard let self, let item, item === self.players[self.active].currentItem, !self.showsSource else { return }
                self.wantsPlaying = false
                self.onEnd?()
            }
        }
    }

    var currentTime: CMTime { players[active].currentTime() }

    /// Loads `item` at `time` into the hidden player and swaps it in when its frame is ready.
    /// `source`: the item is the plain source, shown while an edge is dragged.
    func show(_ item: AVPlayerItem, at time: CMTime, source: Bool = false) {
        generation += 1
        showsSource = source
        let generation = generation
        let next = 1 - active
        readyObservation = nil
        pending = next
        seekTarget = nil
        let player = players[next]
        player.pause()
        player.replaceCurrentItem(with: item)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.prepared(next, generation: generation) }
            }
        }
    }

    func clear() {
        generation += 1
        pause()
        pending = nil
        showsSource = false
        readyObservation = nil
        for player in players { player.replaceCurrentItem(with: nil) }
    }

    private func prepared(_ index: Int, generation: Int) {
        guard generation == self.generation else { return }
        if layers[index].isReadyForDisplay {
            swap(to: index)
            return
        }
        readyObservation = layers[index].observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
            let ready = layer.isReadyForDisplay
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, ready, generation == self.generation, self.pending == index else { return }
                    self.swap(to: index)
                }
            }
        }
        // A file that never reports a frame (e.g. no picture at that time) is swapped in anyway.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.generation, self.pending == index else { return }
                self.swap(to: index)
            }
        }
    }

    private func swap(to index: Int) {
        readyObservation = nil
        let old = active
        active = index
        pending = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layers[index].opacity = 1
        layers[old].opacity = 0
        CATransaction.commit()
        players[old].pause()
        players[old].replaceCurrentItem(with: nil)
        if wantsPlaying && !showsSource { players[index].play() }
    }

    func play() {
        wantsPlaying = true
        if pending == nil, !showsSource { players[active].play() }
    }

    func pause() {
        wantsPlaying = false
        for player in players { player.pause() }
    }

    /// Draws the shown frame anew after its effects changed: a copy of the video composition makes
    /// the player compose the frame again (a seek to the same time would show the cached one).
    func refresh() {
        guard pending == nil, !showsSource, let item = players[active].currentItem,
              let composition = item.videoComposition?.mutableCopy() as? AVMutableVideoComposition else { return }
        item.videoComposition = composition
    }

    /// Exact seek. While dragging, seeks queue up: only the newest waits for the running one.
    func seek(to time: CMTime) {
        seekTarget = time
        if !isSeeking { nextSeek() }
    }

    private func nextSeek() {
        guard let target = seekTarget else {
            isSeeking = false
            return
        }
        seekTarget = nil
        isSeeking = true
        players[pending ?? active].seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.nextSeek() }
            }
        }
    }
}

/// Something in the preview that can be selected and dragged: a title at the playhead or the logo.
struct OverlayItem: Equatable {
    enum Target: Equatable {
        case title(UUID)
        case logo
    }

    var target: Target
    /// In the picture: 0…1, y from the top.
    var frame: CGRect
    var selected: Bool
}

/// Hosts the player's layers (they belong to the player, so a new view simply takes them over) and
/// the frames of titles and logo: a click selects one, dragging moves it, a click elsewhere ends
/// the selection. The effects themselves are drawn into the video.
final class PlayerNSView: NSView {
    /// The picture as shown (rotation applied); the player fits it into the view.
    var pictureSize: CGSize = .zero
    /// Titles first, the logo last (it lies on top).
    var items: [OverlayItem] = [] {
        didSet {
            guard items != oldValue else { return }
            updateOutline()
            window?.invalidateCursorRects(for: self)
        }
    }
    var hasSelection = false
    var onSelect: ((OverlayItem.Target) -> Void)?
    var onMove: ((OverlayItem.Target, CGPoint, DragPhase) -> Void)?
    var onClearSelection: (() -> Void)?

    private let shade = CAShapeLayer()
    private let outline = CAShapeLayer()
    private var drag: (target: OverlayItem.Target, origin: CGPoint, start: NSPoint, moved: Bool)?

    init(player: VideoPlayer) {
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        for playerLayer in player.layers {
            playerLayer.removeFromSuperlayer()
            playerLayer.frame = bounds
            layer?.addSublayer(playerLayer)
        }
        for (shape, color, width) in [(shade, NSColor.black.withAlphaComponent(0.6), 3.0), (outline, NSColor.white, 1.5)] {
            shape.fillColor = nil
            shape.strokeColor = color.cgColor
            shape.lineWidth = width
            layer?.addSublayer(shape)
        }
        outline.lineDashPattern = [5, 3]
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in layer?.sublayers ?? [] { sublayer.frame = bounds }
        CATransaction.commit()
        updateOutline()
        window?.invalidateCursorRects(for: self)
    }

    /// The picture inside the view (aspect fit, like the player layer).
    private var pictureRect: CGRect {
        guard pictureSize.width > 0, pictureSize.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / pictureSize.width, bounds.height / pictureSize.height)
        let size = CGSize(width: pictureSize.width * scale, height: pictureSize.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// A frame of the picture in view coordinates (origin bottom left).
    private func viewRect(_ frame: CGRect) -> CGRect {
        let picture = pictureRect
        return CGRect(x: picture.minX + frame.minX * picture.width, y: picture.maxY - frame.maxY * picture.height,
                      width: frame.width * picture.width, height: frame.height * picture.height)
    }

    private func updateOutline() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = items.first(where: \.selected).map { CGPath(rect: viewRect($0.frame).insetBy(dx: -2, dy: -2), transform: nil) }
        shade.path = path
        outline.path = path
        CATransaction.commit()
    }

    private func item(at point: NSPoint) -> OverlayItem? {
        items.reversed().first { viewRect($0.frame).insetBy(dx: -4, dy: -4).contains(point) }
    }

    override func resetCursorRects() {
        for item in items { addCursorRect(viewRect(item.frame).intersection(bounds), cursor: .openHand) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let item = item(at: point) else {
            drag = nil
            if hasSelection { onClearSelection?() }
            return
        }
        onSelect?(item.target)
        drag = (item.target, CGPoint(x: item.frame.midX, y: item.frame.midY), point, false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let current = drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        let picture = pictureRect
        guard picture.width > 0, current.moved || hypot(point.x - current.start.x, point.y - current.start.y) >= 3 else { return }
        if !current.moved { NSCursor.closedHand.set() }
        var x = current.origin.x + (point.x - current.start.x) / picture.width
        let y = current.origin.y - (point.y - current.start.y) / picture.height
        // Snaps to the middle.
        if abs(x - 0.5) * picture.width < 6 { x = 0.5 }
        onMove?(current.target, CGPoint(x: min(max(0, x), 1), y: min(max(0, y), 1)), current.moved ? .changed : .began)
        drag?.moved = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let current = drag else { return }
        drag = nil
        guard current.moved else { return }
        let point = convert(event.locationInWindow, from: nil)
        let picture = pictureRect
        var x = current.origin.x + (point.x - current.start.x) / max(1, picture.width)
        let y = current.origin.y - (point.y - current.start.y) / max(1, picture.height)
        if abs(x - 0.5) * picture.width < 6 { x = 0.5 }
        onMove?(current.target, CGPoint(x: min(max(0, x), 1), y: min(max(0, y), 1)), .ended)
        window?.invalidateCursorRects(for: self)
    }
}

struct PlayerView: NSViewRepresentable {
    let player: VideoPlayer
    var pictureSize: CGSize = .zero
    var items: [OverlayItem] = []
    var hasSelection = false
    weak var model: AppModel?

    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView(player: player)
        view.onSelect = { [weak model] target in model?.selectOverlay(target) }
        view.onMove = { [weak model] target, center, phase in model?.moveOverlay(target, to: center, phase: phase) }
        view.onClearSelection = { [weak model] in model?.clearSelection() }
        return view
    }

    func updateNSView(_ view: PlayerNSView, context: Context) {
        view.pictureSize = pictureSize
        view.hasSelection = hasSelection
        view.items = items
    }
}
