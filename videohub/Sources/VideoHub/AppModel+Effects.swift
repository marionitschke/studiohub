import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Transitions, titles and the logo.
extension AppModel {
    // MARK: Transitions

    /// A length in whole frames, at least one.
    func transitionTicks(_ seconds: Double) -> Int64 {
        guard let document else { return 0 }
        return Int64(max(1, (seconds * document.frameRate).rounded())) * document.frameTicks
    }

    /// Sets or removes the transition at a boundary: 0 is the start, `parts.count` the end.
    func setTransition(_ kind: Transition.Kind?, at boundary: Int) {
        guard document != nil, (0...edit.parts.count).contains(boundary) else { return }
        var new = edit
        let duration = edit.transition(at: boundary)?.duration ?? transitionTicks(transitionSeconds)
        new.setTransition(kind.map { Transition(kind: $0, duration: duration) }, at: boundary)
        guard new != edit else { return }
        let fade = boundary == 0 ? "Einblenden" : boundary == edit.parts.count ? "Ausblenden" : nil
        let action = kind == nil
            ? fade.map { "\($0) entfernen" } ?? "Übergang entfernen"
            : fade ?? (kind == .dissolve ? "Überblendung" : "Abblende über Schwarz")
        commit(new, previous: edit, action: action)
    }

    func setTransitionLength(_ seconds: Double, at boundary: Int) {
        transitionSeconds = seconds
        guard var transition = edit.transition(at: boundary) else { return }
        transition.duration = transitionTicks(seconds)
        var new = edit
        new.setTransition(transition, at: boundary)
        guard new != edit else { return }
        commit(new, previous: edit, action: "Übergangslänge ändern")
    }

    /// The cut (boundary between two parts) closest to the playhead.
    var nearestInnerBoundary: Int? {
        edit.parts.indices.dropFirst().min {
            abs(edit.sequenceStart(of: $0) - playhead) < abs(edit.sequenceStart(of: $1) - playhead)
        }
    }

    func setTransitionAtNearestCut(_ kind: Transition.Kind?) {
        guard let boundary = nearestInnerBoundary else {
            NSSound.beep()
            statusMessage = "Ein Übergang braucht mindestens zwei Teile – erst schneiden."
            return
        }
        setTransition(kind, at: boundary)
    }

    func toggleFadeIn() {
        setTransition(edit.transition(at: 0) == nil ? .black : nil, at: 0)
    }

    func toggleFadeOut() {
        setTransition(edit.fadeOut == nil ? .black : nil, at: edit.parts.count)
    }

    // MARK: Titles

    var selectedTitleID: UUID? {
        if case .title(let id) = selection { id } else { nil }
    }

    var selectedTitle: Title? { selectedTitleID.flatMap { edit.title($0) } }

    /// Titles are at least half a second long.
    var minimumTitle: Int64 {
        guard let document else { return 1 }
        return max(document.frameTicks, document.ticks(seconds: 0.5))
    }

    /// Where a title is fully visible (after its fade in).
    private func visiblePosition(of placed: PlacedTitle) -> Int64 {
        guard let document else { return placed.start }
        return placed.start + min(document.ticks(seconds: 0.3), (placed.end - placed.start) / 4)
    }

    /// A new title of 3 s at the playhead, in the look of the selected one.
    func addTitle() {
        addTitle(at: snapped(playhead))
    }

    func addTitle(at position: Int64) {
        guard let document, !edit.parts.isEmpty, !isExporting else { return }
        let length = min(document.ticks(seconds: 3), sequenceLength)
        let start = min(max(0, position), max(0, sequenceLength - length))
        var title = selectedTitle ?? Title(text: "", anchor: 0, length: length)
        title.id = UUID()
        title.text = "Titel"
        title.length = length
        var new = edit
        guard new.addTitle(title, at: start), let placed = new.placedTitle(title.id) else { return }
        if isPlaying { pause() }
        playhead = min(max(playhead, visiblePosition(of: placed)), placed.end - 1)
        selection = .title(title.id)
        focusTitleText = true
        commit(new, previous: edit, action: "Titel hinzufügen")
    }

    /// Selects a title and shows it in the preview.
    func selectTitle(_ id: UUID) {
        finishLiveChange()
        selection = .title(id)
        if let placed = edit.placedTitle(id), !placed.range.contains(playhead) {
            if isPlaying { pause() }
            seek(to: visiblePosition(of: placed))
        }
    }

    func deleteTitle(_ id: UUID) {
        var new = edit
        new.removeTitle(id)
        commit(new, previous: edit, action: "Titel löschen")
    }

    /// ⌫: the selected title or logo, otherwise the part at the playhead.
    func deleteSelectionOrPart() {
        if let id = selectedTitleID {
            deleteTitle(id)
        } else if selection == .logo {
            removeLogo()
        } else {
            deleteCurrentPart()
        }
    }

    /// Dragging a title in the title lane.
    func moveTitle(_ id: UUID, to position: Int64, phase: DragPhase) {
        if phase == .began {
            beginDrag()
            selection = .title(id)
        }
        edit.moveTitle(id, to: snapped(position))
        if phase == .ended { endDrag(action: "Titel verschieben") } else { showEffects() }
    }

    /// Dragging the start or end of a title.
    func trimTitle(_ id: UUID, _ edge: PartEdge, to position: Int64, phase: DragPhase) {
        if phase == .began {
            beginDrag()
            selection = .title(id)
        }
        edit.trimTitle(id, edge, to: snapped(position), minimumLength: minimumTitle)
        guard phase == .ended else {
            showEffects()
            return
        }
        func length(_ edit: EditList?) -> Int64 { edit?.placedTitle(id).map { $0.end - $0.start } ?? 0 }
        endDrag(action: length(edit) > length(editBeforeDrag) ? "Titel verlängern" : "Titel kürzen")
    }

    /// Text, look or place of a title, shown at once; one undo step once the change is finished.
    func changeTitle(_ id: UUID, _ action: String, _ change: (inout Title) -> Void) {
        changeLive(action) { $0.updateTitle(id, change) }
    }

    // MARK: Logo

    /// Adds the remembered logo (or asks for an image), or selects the logo the edit has.
    func addOrSelectLogo() {
        guard document != nil, !edit.parts.isEmpty, !isExporting else { return }
        if edit.logo != nil {
            finishLiveChange()
            selection = .logo
            return
        }
        guard let logo = LogoStore.remembered() else {
            chooseLogo()
            return
        }
        var new = edit
        new.logo = logo
        selection = .logo
        commit(new, previous: edit, action: "Logo hinzufügen")
    }

    func chooseLogo() {
        guard document != nil, !isExporting else { return }
        finishLiveChange()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Bild für das Logo wählen – am besten ein PNG mit durchsichtigem Hintergrund"
        panel.prompt = "Wählen"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let file = try LogoStore.importImage(url)
            var logo = edit.logo ?? LogoStore.placement(for: file)
            logo.file = file
            var new = edit
            new.logo = logo
            selection = .logo
            commit(new, previous: edit, action: edit.logo == nil ? "Logo hinzufügen" : "Logo ändern")
            LogoStore.remember(logo)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeLogo() {
        guard edit.logo != nil else { return }
        var new = edit
        new.logo = nil
        commit(new, previous: edit, action: "Logo entfernen")
    }

    func changeLogo(_ action: String, _ change: (inout Logo) -> Void) {
        changeLive(action) { edit in
            guard var logo = edit.logo else { return }
            change(&logo)
            edit.logo = logo
        }
    }

    func selectLogo() {
        finishLiveChange()
        selection = .logo
    }

    func clearSelection() {
        finishLiveChange()
        selection = nil
    }

    // MARK: Preview

    func selectOverlay(_ target: OverlayItem.Target) {
        switch target {
        case .title(let id): selectTitle(id)
        case .logo: selectLogo()
        }
    }

    /// Dragging a title or the logo in the preview: its centre, 0…1 of the picture.
    func moveOverlay(_ target: OverlayItem.Target, to center: CGPoint, phase: DragPhase) {
        if phase == .began, isPlaying { pause() }
        switch target {
        case .title(let id):
            changeTitle(id, "Titel verschieben") {
                $0.x = center.x
                $0.y = center.y
            }
        case .logo:
            changeLogo("Logo verschieben") {
                $0.x = center.x
                $0.y = center.y
            }
        }
        if phase == .ended { finishLiveChange() }
    }

    // MARK: Live changes

    /// Applies a change at once and shows it; the undo step comes with `finishLiveChange()`.
    func changeLive(_ action: String, _ change: (inout EditList) -> Void) {
        guard document != nil else { return }
        if editBeforeLive != nil, liveAction != action { finishLiveChange() }
        if editBeforeLive == nil {
            editBeforeLive = edit
            liveAction = action
        }
        change(&edit)
        showEffects()
    }

    /// Ends a live change (slider released, text field left, title dropped): one undo step.
    func finishLiveChange() {
        guard let before = editBeforeLive else { return }
        editBeforeLive = nil
        if let logo = edit.logo, logo != before.logo { LogoStore.remember(logo) }
        guard edit != before else { return }
        commit(edit, previous: before, action: liveAction)
    }
}

enum LogoError: LocalizedError {
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): "„\(name)“ lässt sich nicht als Bild lesen."
        }
    }
}

/// The logo images VideoHub keeps (as PNG copies in Application Support, so the edit does not
/// depend on the original file) and the place of the last logo, for the next video.
enum LogoStore {
    private static let fileKey = "logoFile", xKey = "logoX", yKey = "logoY", widthKey = "logoWidth", opacityKey = "logoOpacity"

    static var folder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("VideoHub/Logos", isDirectory: true)
    }

    /// Copies an image as PNG (upright, at most 2000 pixels wide) and returns the copy.
    static func importImage(_ url: URL) throws -> URL {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2000,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw LogoError.unreadable(url.lastPathComponent)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent("\(UUID().uuidString).png")
        guard let destination = CGImageDestinationCreateWithURL(copy as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw LogoError.unreadable(url.lastPathComponent)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw LogoError.unreadable(url.lastPathComponent) }
        return copy
    }

    static func remember(_ logo: Logo) {
        let defaults = UserDefaults.standard
        defaults.set(logo.file.path, forKey: fileKey)
        defaults.set(logo.x, forKey: xKey)
        defaults.set(logo.y, forKey: yKey)
        defaults.set(logo.width, forKey: widthKey)
        defaults.set(logo.opacity, forKey: opacityKey)
    }

    /// The last logo where it was, if its image is still there.
    static func remembered() -> Logo? {
        guard let path = UserDefaults.standard.string(forKey: fileKey), FileManager.default.fileExists(atPath: path) else { return nil }
        return placement(for: URL(fileURLWithPath: path))
    }

    /// A logo with this image at the remembered place (or the default one).
    static func placement(for file: URL) -> Logo {
        let defaults = UserDefaults.standard
        var logo = Logo(file: file)
        guard defaults.object(forKey: xKey) != nil else { return logo }
        logo.x = min(max(0, defaults.double(forKey: xKey)), 1)
        logo.y = min(max(0, defaults.double(forKey: yKey)), 1)
        logo.width = min(max(Logo.minimumWidth, defaults.double(forKey: widthKey)), Logo.maximumWidth)
        logo.opacity = min(max(0.1, defaults.double(forKey: opacityKey)), 1)
        return logo
    }

    /// Deletes the copies of earlier logos (at launch, when no undo step can need them any more).
    static func cleanUp() {
        let kept = UserDefaults.standard.string(forKey: fileKey)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.path != kept {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
