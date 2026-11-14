import AppKit
import AVFoundation
import Observation
import UniformTypeIdentifiers

/// Everything the window shows: the open video, the edit, playback and export. Edits live only in
/// this session; nothing is stored.
@MainActor
@Observable
final class AppModel {
    var document: VideoDocument?
    var edit = EditList(bounds: 0..<0)
    var peaks: Peaks?
    /// While the waveform is read: 0…1.
    var peaksProgress: Double?
    /// Position in the edit (sequence ticks).
    var playhead: Int64 = 0
    var isPlaying = false
    var isOpening = false

    var visibleStart: Double = 0
    var visibleLength: Double = 1
    var viewWidth: Double = 800

    var isExporting = false
    var exportProgress = 0.0
    var exportLabel = ""
    var exportedFiles: [URL] = []
    var statusMessage: String?
    var errorMessage: String?
    var quitAfterExport = false
    /// The edit as last exported (nothing is lost if it is still the same).
    private(set) var exportedEdit: EditList?

    /// What the inspector next to the preview shows.
    enum Selection: Equatable {
        case title(UUID)
        case logo
    }
    var selection: Selection?
    /// Asks the inspector to put the cursor into the text of the selected title.
    var focusTitleText = false
    /// The length for new transitions.
    var transitionSeconds = 0.5

    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored let player = VideoPlayer()
    @ObservationIgnored let thumbnails = ThumbnailCache()
    @ObservationIgnored var editBeforeDrag: EditList?
    /// The edit before a change that is shown live (typing, a slider) and committed once.
    @ObservationIgnored var editBeforeLive: EditList?
    @ObservationIgnored var liveAction = ""
    /// Draws the effects of the preview; swapped content shows a moved title without a new composition.
    @ObservationIgnored private var previewRenderer: EffectRenderer?
    @ObservationIgnored private var peaksToken: CancelToken?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var resumeAfterScrub = false

    static let videoTypes: [UTType] = [.quickTimeMovie, .mpeg4Movie, UTType("com.apple.m4v-video") ?? .movie]

    init() {
        player.onTime = { [weak self] time in self?.playerMoved(time) }
        player.onEnd = { [weak self] in self?.playbackEnded() }
        LogoStore.cleanUp()
    }

    var hasUnexportedChanges: Bool { document != nil && edit.hasEdits && edit != exportedEdit }
    var sequenceLength: Int64 { edit.sequenceLength }
    var currentIndex: Int? { edit.index(at: playhead) }
    var canExport: Bool { document != nil && !edit.parts.isEmpty && !isExporting }
    var canExportAudio: Bool { canExport && document?.audioTrack != nil }

    /// Parts are at least 0.1 s long (in whole frames).
    var minimumPart: Int64 {
        guard let document else { return 1 }
        let frames = (document.ticks(seconds: 0.1) + document.frameTicks - 1) / document.frameTicks
        return max(1, frames) * document.frameTicks
    }

    func seconds(_ ticks: Int64) -> Double { document?.seconds(ticks) ?? 0 }

    // MARK: Opening

    func showOpenPanel() {
        guard !isExporting else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = AppModel.videoTypes
        panel.message = "Video zum Schneiden wählen"
        panel.prompt = "Öffnen"
        if let document { panel.directoryURL = document.url.deletingLastPathComponent() }
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ urls: [URL]) {
        if let url = urls.first { open(url) }
    }

    func open(_ url: URL) {
        guard !isExporting, !isOpening, confirmDiscard(beforeOpening: true) else { return }
        isOpening = true
        statusMessage = nil
        Task {
            do {
                install(try await VideoDocument.open(url))
            } catch {
                errorMessage = error.localizedDescription
            }
            isOpening = false
        }
    }

    /// Asks before unexported changes are dropped; true if it may go on.
    func confirmDiscard(beforeOpening: Bool) -> Bool {
        guard hasUnexportedChanges, let document else { return true }
        let alert = NSAlert()
        alert.messageText = "Die Schnitte in „\(document.url.lastPathComponent)“ sind nicht exportiert."
        alert.informativeText = "VideoHub speichert keine Schnitte. Wenn du weitermachst, gehen sie verloren."
        alert.addButton(withTitle: beforeOpening ? "Verwerfen und öffnen" : "Verwerfen und beenden")
        alert.addButton(withTitle: "Abbrechen")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func install(_ document: VideoDocument) {
        peaksToken?.cancel()
        player.clear()
        isPlaying = false
        self.document = document
        edit = EditList(bounds: document.bounds)
        selection = nil
        editBeforeLive = nil
        exportedEdit = nil
        exportedFiles = []
        undoManager?.removeAllActions()
        playhead = 0
        peaks = nil
        thumbnails.load(document)
        zoomToFit()
        showEdit()
        loadPeaks(document)
    }

    private func loadPeaks(_ document: VideoDocument) {
        guard document.audioTrack != nil else {
            peaksProgress = nil
            return
        }
        let token = CancelToken()
        peaksToken = token
        peaksProgress = 0
        // The model lives as long as the app; a newer video cancels the token.
        let model = self
        Task.detached(priority: .userInitiated) {
            let peaks = (try? AudioReader.peaks(for: document, token: token) { value in
                Task { @MainActor in
                    if !token.isCancelled { model.peaksProgress = value }
                }
            }) ?? nil
            await MainActor.run {
                guard !token.isCancelled else { return }
                model.peaksProgress = nil
                model.peaks = peaks
            }
        }
    }

    // MARK: Playback

    /// Puts the current edit into the preview at the playhead. With effects the preview renders
    /// them like the export (SDR).
    func showEdit() {
        guard let document else { return }
        do {
            let item: AVPlayerItem
            if edit.hasEffects {
                let effects = try Composer.effects(document, edit: edit)
                item = AVPlayerItem(asset: effects.composition)
                item.videoComposition = effects.videoComposition
                item.audioMix = effects.audioMix
                previewRenderer = effects.renderer
            } else {
                item = AVPlayerItem(asset: try Composer.composition(document, ranges: edit.ranges, sound: edit.soundSegments))
                previewRenderer = nil
            }
            player.show(item, at: document.time(playhead))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Shows changed titles or a changed logo at once: the preview keeps its composition and only
    /// draws the frame anew. Anything else needs `showEdit()`.
    func showEffects() {
        guard let document else { return }
        guard let renderer = previewRenderer, edit.hasEffects, !player.showsSource else {
            showEdit()
            return
        }
        renderer.update(EffectContent(edit: edit, layout: edit.effectLayout(frame: document.frameTicks)))
        player.refresh()
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let document, !edit.parts.isEmpty else { return }
        if playhead >= sequenceLength - document.frameTicks { seek(to: 0) }
        if player.showsSource { showEdit() }
        isPlaying = true
        player.play()
    }

    func pause() {
        player.pause()
        isPlaying = false
        if let document, !player.showsSource {
            playhead = min(sequenceLength, max(0, document.ticks(player.currentTime)))
        }
    }

    private func playerMoved(_ time: CMTime) {
        guard isPlaying, let document else { return }
        playhead = min(sequenceLength, max(0, document.ticks(time)))
        // Turn the page when the playhead leaves the visible area.
        let position = Double(playhead)
        if position < visibleStart || position > visibleStart + visibleLength {
            scroll(to: position - visibleLength * 0.05)
        }
    }

    private func playbackEnded() {
        isPlaying = false
        playhead = sequenceLength
    }

    /// Moves the playhead. While dragging, `final` is false; playback pauses until the mouse is released.
    func seek(to position: Int64, final: Bool = true) {
        guard let document else { return }
        let target = min(max(0, position), sequenceLength)
        if !final, isPlaying {
            player.pause()
            isPlaying = false
            resumeAfterScrub = true
        }
        playhead = target
        if player.showsSource {
            showEdit()
        } else {
            player.seek(to: document.time(target))
        }
        if final {
            ensureVisible(Double(target))
            if resumeAfterScrub {
                resumeAfterScrub = false
                play()
            }
        }
    }

    /// The start of the frame at a sequence position.
    func snapped(_ position: Int64) -> Int64 {
        guard let document, let index = edit.index(at: position), let source = edit.sourcePosition(at: position) else { return position }
        let part = edit.parts[index]
        let frame = min(max(document.snapped(source), part.start), part.end)
        return edit.sequencePosition(ofSource: frame, inPart: index)
    }

    func step(frames: Int) {
        guard let document else { return }
        if isPlaying { pause() }
        seek(to: snapped(playhead + Int64(frames) * document.frameTicks))
    }

    func step(seconds: Double) {
        guard let document else { return }
        seek(to: playhead + document.ticks(seconds: seconds))
    }

    func goToStart() { seek(to: 0) }
    func goToEnd() { seek(to: sequenceLength) }

    /// Jumps to the start of the next or previous part (or the end of the edit).
    func jumpToPart(forward: Bool) {
        guard let document else { return }
        let marks = edit.starts + [sequenceLength]
        // While playing, a little slack lets repeated presses go further back.
        let slack = isPlaying ? document.ticks(seconds: 0.5) : 0
        let target = forward ? marks.first { $0 > playhead } : marks.last { $0 < playhead - slack }
        seek(to: target ?? (forward ? sequenceLength : 0))
    }

    // MARK: Editing

    func cutAtPlayhead() {
        guard document != nil, !edit.parts.isEmpty else { return }
        let position = snapped(playhead)
        var new = edit
        guard new.cut(at: position, minimumLength: minimumPart) else {
            NSSound.beep()
            statusMessage = "Hier geht kein Schnitt: Jeder Teil muss mindestens 0,1 s lang sein."
            return
        }
        playhead = position
        commit(new, previous: edit, action: "Schneiden")
    }

    func deleteCurrentPart() {
        guard let index = currentIndex else { return }
        deletePart(index)
    }

    func deletePart(_ index: Int) {
        guard edit.parts.indices.contains(index) else { return }
        var new = edit
        let start = edit.sequenceStart(of: index)
        new.delete(index)
        playhead = min(start, new.sequenceLength)
        commit(new, previous: edit, action: "Teil löschen")
    }

    func movePart(_ index: Int, before destination: Int) {
        guard edit.parts.indices.contains(index) else { return }
        let id = edit.parts[index].id
        var new = edit
        new.move(index, before: destination)
        guard new != edit else { return }
        if let moved = new.parts.firstIndex(where: { $0.id == id }) { playhead = new.sequenceStart(of: moved) }
        commit(new, previous: edit, action: "Teil verschieben")
    }

    func removeCut(_ boundary: Int) {
        guard edit.isCut(boundary) else { return }
        var new = edit
        new.join(boundary)
        commit(new, previous: edit, action: "Schnitt entfernen")
    }

    func resetEdits() {
        guard let document else { return }
        playhead = 0
        commit(EditList(bounds: document.bounds), previous: edit, action: "Alle Schnitte entfernen")
    }

    /// Moves the nearest cut by whole frames (keys , and .).
    func nudgeCut(frames: Int) {
        guard let document else { return }
        let cuts = edit.parts.indices.dropLast().filter { edit.isCut($0) }
        guard let boundary = cuts.min(by: {
            abs(edit.sequenceStart(of: $0 + 1) - playhead) < abs(edit.sequenceStart(of: $1 + 1) - playhead)
        }) else {
            NSSound.beep()
            return
        }
        var new = edit
        new.moveCut(boundary, to: edit.parts[boundary + 1].start + Int64(frames) * document.frameTicks, minimumLength: minimumPart)
        playhead = new.sequenceStart(of: boundary + 1)
        commit(new, previous: edit, action: "Schnitt verschieben")
    }

    /// Dragging a cut: the edit changes live and the preview shows the first frame after the cut;
    /// undo and the new preview come once at the end.
    func moveCut(_ boundary: Int, to source: Int64, phase: DragPhase) {
        guard let document else { return }
        if phase == .began { beginDrag() }
        edit.moveCut(boundary, to: document.snapped(source), minimumLength: minimumPart)
        guard edit.parts.indices.contains(boundary + 1) else { return }
        if phase == .ended {
            playhead = edit.sequenceStart(of: boundary + 1)
            endDrag(action: "Schnitt verschieben")
        } else {
            showSource(edit.parts[boundary + 1].start)
        }
    }

    /// Dragging the start or end of a part: the preview shows its first or last frame.
    func trim(_ index: Int, _ edge: PartEdge, to source: Int64, phase: DragPhase) {
        guard let document, edit.parts.indices.contains(index) else { return }
        if phase == .began { beginDrag() }
        edit.trim(index, edge, to: document.snapped(source), minimumLength: minimumPart)
        let part = edit.parts[index]
        let lastFrame = max(part.start, part.end - document.frameTicks)
        if phase == .ended {
            let start = edit.sequenceStart(of: index)
            playhead = edge == .start ? start : start + (lastFrame - part.start)
            let before = editBeforeDrag.flatMap { $0.parts.indices.contains(index) ? $0.parts[index].length : nil }
            endDrag(action: (before ?? part.length) < part.length ? "Teil verlängern" : "Teil kürzen")
        } else {
            showSource(edge == .start ? part.start : lastFrame)
        }
    }

    // MARK: Sound

    /// The sound of the part at the playhead.
    var currentSound: PartSound? { currentIndex.map { edit.parts[$0].sound } }
    var canEditSound: Bool { document?.audioTrack != nil && currentIndex != nil }

    /// Detaches the sound of the part at the playhead from its picture, or puts it back.
    func toggleDetachedSound() {
        guard canEditSound, let index = currentIndex else { return }
        var new = edit
        if case .detached = edit.parts[index].sound {
            new.attachSound(index)
            commit(new, previous: edit, action: "Ton anlegen")
        } else {
            new.detachSound(index)
            commit(new, previous: edit, action: "Ton lösen")
        }
    }

    func toggleMute() {
        guard canEditSound, let index = currentIndex else { return }
        let muted = edit.parts[index].sound == .muted
        var new = edit
        new.setMuted(index, !muted)
        commit(new, previous: edit, action: muted ? "Ton einschalten" : "Ton stummschalten")
    }

    /// Shifts the sound of the part at the playhead by whole frames (⌥, and ⌥.), detaching it first.
    func nudgeSound(frames: Int) {
        guard let document, canEditSound, let index = currentIndex else { return }
        var new = edit
        new.detachSound(index)
        guard let sound = new.parts[index].soundAsDetached else { return }
        new.shiftSound(index, to: sound.shift + Int64(frames) * document.frameTicks, minimumLength: minimumPart)
        commit(new, previous: edit, action: "Ton verschieben")
    }

    /// Dragging a detached sound sideways; the new sound is heard once the mouse is released.
    func moveSound(_ index: Int, to shift: Int64, phase: DragPhase) {
        guard let document, edit.parts.indices.contains(index) else { return }
        if phase == .began { beginDrag() }
        let frame = Double(document.frameTicks)
        edit.shiftSound(index, to: Int64((Double(shift) / frame).rounded()) * document.frameTicks, minimumLength: minimumPart)
        if phase == .ended { endDrag(action: "Ton verschieben") }
    }

    /// Dragging the start or end of a detached sound.
    func trimSound(_ index: Int, _ edge: PartEdge, to source: Int64, phase: DragPhase) {
        guard let document, edit.parts.indices.contains(index) else { return }
        if phase == .began { beginDrag() }
        edit.trimSound(index, edge, to: document.snapped(source), minimumLength: minimumPart)
        if phase == .ended {
            let before = editBeforeDrag.flatMap { $0.parts.indices.contains(index) ? $0.parts[index].soundAsDetached?.length : nil }
            let after = edit.parts[index].soundAsDetached?.length ?? 0
            endDrag(action: (before ?? after) < after ? "Ton verlängern" : "Ton kürzen")
        }
    }

    func beginDrag() {
        finishLiveChange()
        editBeforeDrag = edit
        if isPlaying { pause() }
    }

    func endDrag(action: String) {
        let before = editBeforeDrag ?? edit
        editBeforeDrag = nil
        commit(edit, previous: before, action: action)
    }

    private func showSource(_ source: Int64) {
        guard let document else { return }
        let time = document.time(min(max(source, document.bounds.lowerBound), max(document.bounds.lowerBound, document.bounds.upperBound - 1)))
        if player.showsSource {
            player.seek(to: time)
        } else {
            player.show(AVPlayerItem(asset: document.asset), at: time, source: true)
        }
    }

    func commit(_ new: EditList, previous: EditList, action: String) {
        guard document != nil else { return }
        // A change shown live gets its own undo step first.
        if editBeforeLive != nil { finishLiveChange() }
        if case .title(let id) = selection, new.title(id) == nil { selection = nil }
        if selection == .logo, new.logo == nil { selection = nil }
        let wasFit = visibleLength >= Double(previous.sequenceLength) * 0.999
        edit = new
        playhead = min(max(0, playhead), new.sequenceLength)
        if wasFit { zoomToFit() } else { clampView() }
        showEdit()
        guard new != previous else { return }
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.statusMessage = nil
                model.commit(previous, previous: new, action: action)
            }
        }
        undoManager?.setActionName(action)
    }

    // MARK: Zoom and scrolling (sequence ticks)

    private var length: Double { Double(max(1, sequenceLength)) }

    /// The closest zoom shows a frame 12 points wide.
    private var minimumVisibleLength: Double {
        guard let document else { return 1 }
        return min(length, max(1, viewWidth) / 12 * Double(document.frameTicks))
    }

    func zoom(by factor: Double, around anchor: Double? = nil) {
        guard document != nil, visibleLength > 0 else { return }
        let position = Double(playhead)
        let center = anchor ?? (position >= visibleStart && position <= visibleStart + visibleLength
            ? position : visibleStart + visibleLength / 2)
        let ratio = (center - visibleStart) / visibleLength
        visibleLength = min(length, max(minimumVisibleLength, visibleLength / factor))
        scroll(to: center - ratio * visibleLength)
    }

    func zoomToFit() {
        visibleLength = length
        visibleStart = 0
    }

    /// Zoom as 0 (whole edit) … 1 (closest), on a logarithmic scale for the slider.
    var zoomFraction: Double {
        get {
            let low = minimumVisibleLength, high = length
            guard high > low, visibleLength > 0 else { return 0 }
            return log(high / visibleLength) / log(high / low)
        }
        set {
            let low = minimumVisibleLength, high = length
            guard high > low else { return }
            let target = high * pow(low / high, min(max(0, newValue), 1))
            zoom(by: visibleLength / target)
        }
    }

    func scroll(to start: Double) {
        visibleStart = min(max(0, start), max(0, length - visibleLength))
    }

    private func clampView() {
        visibleLength = min(length, max(minimumVisibleLength, visibleLength))
        scroll(to: visibleStart)
    }

    private func ensureVisible(_ position: Double) {
        if position < visibleStart || position > visibleStart + visibleLength {
            scroll(to: position - visibleLength / 2)
        }
    }

    func setViewWidth(_ width: Double) {
        guard width > 0, width != viewWidth else { return }
        viewWidth = width
    }

    // MARK: Export

    /// Whether the export encodes anew, for the interface.
    var exportReencodes: Bool { edit.hasEffects }

    func exportVideo() {
        guard let document, canExport else { return }
        finishLiveChange()
        let effects = edit.hasEffects
        let defaults = UserDefaults.standard
        let mp4Possible = effects || document.copiesIntoMP4
        let format = VideoFormat.preferred(remembered: defaults.string(forKey: VideoFormat.defaultsKey),
                                           source: document.url, mp4Possible: mp4Possible)
        let codec = effects ? VideoCodec(rawValue: defaults.string(forKey: VideoCodec.defaultsKey) ?? "") ?? .h264 : nil
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(document.name) \(edit.hasEdits ? "(gekürzt)" : "(Kopie)").\(format.fileExtension)"
        panel.directoryURL = document.url.deletingLastPathComponent()
        if effects {
            let size = document.displaySize
            let rate = document.frameRate.rounded() == document.frameRate ? "\(Int(document.frameRate))" : String(format: "%.2f", document.frameRate)
            panel.message = "Mit Übergängen, Titeln oder Logo wird das Video neu kodiert – \(Int(size.width)) × \(Int(size.height)), \(rate) fps, SDR."
        } else {
            panel.message = "Das Video wird ohne Neukodierung gespeichert – in Originalqualität."
        }
        panel.prompt = "Exportieren"
        panel.canCreateDirectories = true
        let accessory = FormatAccessory(panel: panel, format: format, mp4Possible: mp4Possible, codec: codec)
        let answer = withExtendedLifetime(accessory) { panel.runModal() }
        guard answer == .OK, let url = panel.url else { return }
        defaults.set(VideoFormat(of: url).rawValue, forKey: VideoFormat.defaultsKey)
        let snapshot = edit
        if effects {
            let chosen = accessory.codec ?? .h264
            defaults.set(chosen.rawValue, forKey: VideoCodec.defaultsKey)
            run(destination: url, snapshot: snapshot) { progress in
                try await Exporter.exportEffects(document, edit: snapshot, codec: chosen, to: url, progress: progress)
            }
        } else {
            let ranges = edit.ranges, sound = edit.soundSegments
            run(destination: url, snapshot: snapshot) { progress in
                try await Exporter.exportVideo(document, ranges: ranges, sound: sound, to: url, progress: progress)
            }
        }
    }

    func exportAudio(_ format: AudioFormat) {
        guard let document, canExportAudio else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(document.name)\(edit.hasEdits ? " (gekürzt)" : "").\(format.fileExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .audio]
        panel.directoryURL = document.url.deletingLastPathComponent()
        panel.message = "Der Ton des Schnitts als \(format.title)"
        panel.prompt = "Exportieren"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let ranges = edit.ranges, sound = edit.soundSegments, ramps = edit.effectLayout(frame: document.frameTicks).ramps
        // Only the video counts as exported: the sound alone does not keep the cuts.
        run(destination: url, snapshot: nil) { progress in
            try await Exporter.exportAudio(document, ranges: ranges, sound: sound, ramps: ramps, format: format, to: url,
                                           progress: progress)
        }
    }

    private func run(destination: URL, snapshot: EditList?,
                     work: @escaping (@escaping @Sendable (Double) -> Void) async throws -> Void) {
        if isPlaying { pause() }
        isExporting = true
        exportProgress = 0
        exportLabel = "„\(destination.lastPathComponent)“"
        statusMessage = nil
        exportedFiles = []
        let gate = PercentGate()
        exportTask = Task {
            do {
                try await work { value in
                    guard gate.pass(value) else { return }
                    Task { @MainActor [weak self] in self?.exportProgress = value }
                }
                if let snapshot { exportedEdit = snapshot }
                exportedFiles = [destination]
                statusMessage = "Exportiert: \(destination.lastPathComponent)"
            } catch {
                if Task.isCancelled || error is CancellationError {
                    statusMessage = "Export abgebrochen."
                } else {
                    errorMessage = error.localizedDescription
                }
            }
            isExporting = false
            exportTask = nil
            if quitAfterExport {
                quitAfterExport = false
                // Cancelling the export does not mean giving up the cuts.
                NSApp.reply(toApplicationShouldTerminate: confirmDiscard(beforeOpening: false))
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    func showExportedFiles() {
        guard !exportedFiles.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(exportedFiles)
    }

    // MARK: Keyboard

    /// Single keys for the editor (text fields are left alone by the caller). Returns true if used.
    func handleKey(_ event: NSEvent) -> Bool {
        guard document != nil, !isExporting, !isOpening else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !flags.contains(.command), !flags.contains(.control) else { return false }
        switch event.keyCode {
        case 49: togglePlay()                                              // space
        case 123: flags.contains(.option) ? jumpToPart(forward: false)     // ←
            : flags.contains(.shift) ? step(seconds: -1) : step(frames: -1)
        case 124: flags.contains(.option) ? jumpToPart(forward: true)      // →
            : flags.contains(.shift) ? step(seconds: 1) : step(frames: 1)
        case 115: goToStart()                                              // home
        case 119: goToEnd()                                                // end
        case 43 where !flags.contains(.option):                            // , (by position)
            nudgeCut(frames: flags.contains(.shift) ? -10 : -1)
        case 47 where !flags.contains(.option):                            // .
            nudgeCut(frames: flags.contains(.shift) ? 10 : 1)
        case 43: nudgeSound(frames: flags.contains(.shift) ? -10 : -1)     // ⌥,
        case 47: nudgeSound(frames: flags.contains(.shift) ? 10 : 1)       // ⌥.
        case 51 where flags.isEmpty, 117 where flags.isEmpty:              // ⌫, ⌦
            deleteSelectionOrPart()
        case 53 where selection != nil: clearSelection()                   // esc
        default:
            guard flags.isEmpty else { return false }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "s": cutAtPlayhead()
            case "l": toggleDetachedSound()
            case "m": toggleMute()
            case "t": addTitle()
            default: return false
            }
        }
        return true
    }
}
