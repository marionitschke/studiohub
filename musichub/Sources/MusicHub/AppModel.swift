import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
    // MARK: Document

    var document: AudioDocument?
    var peaks: Peaks?
    /// Tags of the (first) source file.
    var tags = SourceTags()
    /// What the user changed for the export in „Tags“.
    private(set) var customTags = CustomTags()
    /// The image of a cover chosen from a file, ready for ID3.
    private(set) var customArtwork: Data?
    var edit = EditList(length: 0)

    var isLoading = false
    var loadingName = ""
    var loadProgress = 0.0
    /// Recordings opened before, newest first: the paths of their files.
    private(set) var recent: [[String]]
    /// A cue sheet next to the opened file, offered in the footer.
    var suggestedCue: URL?

    // MARK: Playback and view

    var playhead: Int64 = 0 {
        didSet { updateCurrentSegment() }
    }
    /// The part under the playhead (stored, so that views only update when it really changes).
    private(set) var currentSegmentID: Segment.ID?
    var isPlaying = false
    /// Track that playback is limited to (as it will be exported); nil plays all tracks.
    var soloTrack: Int? {
        didSet { restartPlayback() }
    }
    /// Visible part of the waveform, in frames.
    var visibleStart: Double = 0
    var visibleLength: Double = 1
    var viewWidth: Double = 800

    // MARK: Finding pauses

    var isFindingPauses = false {
        didSet { updateProposedCuts() }
    }
    /// Quieter than this (dBFS) counts as a pause …
    var pauseThreshold: Double {
        didSet {
            defaults.set(pauseThreshold, forKey: Keys.pauseThreshold)
            updateProposedCuts()
        }
    }
    /// … if it lasts at least this many seconds.
    var pauseMinimum: Double {
        didSet {
            defaults.set(pauseMinimum, forKey: Keys.pauseMinimum)
            updateProposedCuts()
        }
    }
    /// Cuts the pause finder would set, shown in the timeline while it is open.
    private(set) var proposedCuts: [Int64] = []

    // MARK: Export

    var isExporting = false
    var exportProgress = 0.0
    var exportLabel = ""
    var exportedFiles: [URL] = []
    /// Exports are brought to the same loudness (−14 LUFS).
    var normalizeLoudness: Bool {
        didSet { defaults.set(normalizeLoudness, forKey: Keys.normalize) }
    }
    var statusMessage: String?
    var errorMessage: String?
    /// Quit was requested while exporting; the app quits once the export has stopped.
    var quitAfterExport = false

    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored private let player = Player()
    @ObservationIgnored private let store: EditStore
    @ObservationIgnored private let defaults: UserDefaults
    /// While a transition is previewed: the cut the playhead returns to afterwards.
    @ObservationIgnored private var previewReturn: Int64?
    @ObservationIgnored private var loadToken: CancelToken?
    @ObservationIgnored private var exportToken: CancelToken?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var editBeforeDrag: EditList?

    private enum Keys {
        static let normalize = "normalizeLoudness"
        static let pauseThreshold = "pauseThreshold"
        static let pauseMinimum = "pauseMinimum"
    }

    init(store: EditStore = .standard, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        recent = RecentFiles.load(defaults)
        normalizeLoudness = defaults.bool(forKey: Keys.normalize)
        pauseThreshold = defaults.object(forKey: Keys.pauseThreshold) as? Double ?? -40
        pauseMinimum = defaults.object(forKey: Keys.pauseMinimum) as? Double ?? 2
        player.onStop = { [weak self] end in self?.playbackEnded(at: end) }
    }

    // MARK: Derived values

    var currentSegment: Segment? { edit.segments.first { $0.id == currentSegmentID } }
    /// The source tags with the user's changes: what goes into the exported files.
    var exportTags: SourceTags { customTags.applied(to: tags, artwork: customArtwork) }
    func canExport(track: Int) -> Bool {
        document != nil && !isExporting && !isLoading && !edit.segments(onTrack: track).isEmpty
    }

    /// What playback plays: all parts that are not deleted, or only the solo track's parts.
    private var playbackRanges: [Range<Int64>] {
        guard document != nil else { return [] }
        return soloTrack.map { edit.ranges(onTrack: $0) } ?? edit.keptRanges
    }
    /// Parts shorter than this cannot be created.
    private var minimumSegment: Int64 { document.map { $0.frame(0.1) } ?? 1 }
    private var length: Double { Double(document?.length ?? 0) }

    private func updateCurrentSegment() {
        let id = edit.segments.isEmpty ? nil : edit.segment(at: playhead).id
        if id != currentSegmentID { currentSegmentID = id }
    }

    // MARK: Opening

    static let cueType = UTType(filenameExtension: "cue")

    func showOpenPanel() {
        guard !isExporting else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie] + [AppModel.cueType].compactMap { $0 }
        panel.allowsMultipleSelection = true
        panel.prompt = "Öffnen"
        panel.message = "Mehrere Dateien werden in der Reihenfolge ihrer Namen aneinandergehängt."
        if let document { panel.directoryURL = document.url.deletingLastPathComponent() }
        if panel.runModal() == .OK { open(panel.urls) }
    }

    func showAppendPanel() {
        guard let document, !isExporting, !isLoading else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = true
        panel.prompt = "Anhängen"
        panel.message = "Die Dateien kommen hinten an „\(document.displayName)“. Sie brauchen dieselbe Abtastrate und Kanalzahl."
        panel.directoryURL = document.files[document.files.count - 1].url.deletingLastPathComponent()
        if panel.runModal() == .OK { append(panel.urls) }
    }

    /// Opens audio files – several are joined in the order of their names – or a cue sheet.
    func open(_ urls: [URL]) {
        // Links dropped from a browser are not files (and would be downloaded on the main thread).
        let urls = urls.filter(\.isFileURL)
        guard !isExporting, !urls.isEmpty else { return }
        if let cue = urls.first(where: { $0.pathExtension.lowercased() == "cue" }) {
            openCue(cue)
        } else {
            load(AppModel.sortedByName(urls))
        }
    }

    func open(_ url: URL) { open([url]) }

    /// Adds files at the end of the recording; the last part grows over them.
    func append(_ urls: [URL]) {
        guard let document, !isExporting else { return }
        let added = AppModel.sortedByName(urls).filter { !document.contains($0) }
        guard !added.isEmpty else { return }
        load(document.urls + added, keeping: edit)
    }

    func openRecent(_ paths: [String]) {
        guard !isExporting else { return }
        load(paths.map { URL(fileURLWithPath: $0) })
    }

    /// Recent recordings whose files all still exist.
    var recentRecordings: [[String]] {
        recent.filter { $0.allSatisfy { FileManager.default.fileExists(atPath: $0) } }
    }

    func clearRecent() {
        recent = []
        RecentFiles.save(recent, defaults)
    }

    nonisolated static func sortedByName(_ urls: [URL]) -> [URL] {
        urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Reads the files in the background. `kept` is the edit of a recording that files were
    /// appended to; `cue` is applied once the files are open (offered, if they have stored cuts).
    private func load(_ urls: [URL], keeping kept: EditList? = nil, cue: (sheet: CueSheet, url: URL)? = nil) {
        stopPlayback()
        loadToken?.cancel()
        let token = CancelToken()
        loadToken = token
        isLoading = true
        loadProgress = 0
        loadingName = RecentFiles.name(urls.map(\.path))
        statusMessage = nil
        exportedFiles = []

        let gate = PercentGate()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () throws -> (AudioDocument, Peaks) in
                let document = try AudioLoader.open(urls)
                let peaks = try AudioLoader.peaks(for: document, token: token) { value in
                    guard gate.pass(value) else { return }
                    Task { @MainActor in
                        if token === self.loadToken { self.loadProgress = value }
                    }
                }
                return (document, peaks)
            }
            Task { @MainActor in self.finishLoading(result, token: token, kept: kept, cue: cue) }
        }
    }

    func cancelLoading() {
        loadToken?.cancel()
        loadToken = nil
        isLoading = false
    }

    private func finishLoading(_ result: Result<(AudioDocument, Peaks), Error>, token: CancelToken,
                               kept: EditList?, cue: (sheet: CueSheet, url: URL)?) {
        guard token === loadToken else { return }
        loadToken = nil
        isLoading = false
        switch result {
        case .success(let (document, peaks)):
            do {
                try player.load(document)
            } catch {
                errorMessage = AudioError.unreadable(document.url.lastPathComponent).localizedDescription
                return
            }
            undoManager?.removeAllActions()
            soloTrack = nil
            isFindingPauses = false
            suggestedCue = nil
            self.document = document
            self.peaks = peaks
            tags = SourceTags()
            let restored = store.load(for: document)
            // Appended files keep the export tags along with the edit.
            if kept == nil { customTags = restored.tags }
            loadCustomArtwork()
            // The kept edit only fits if the first files did not change on disk in the meantime; one of
            // another length would make every later change fail silently.
            let carried = kept.map { $0.extended(to: document.length) }.flatMap { $0.length == document.length ? $0 : nil }
            edit = carried ?? restored.edit ?? EditList(length: document.length)
            playhead = 0
            updateCurrentSegment()
            visibleStart = 0
            visibleLength = Double(document.length)
            recent = RecentFiles.adding(document.urls.map(\.path), to: recent)
            RecentFiles.save(recent, defaults)
            if kept != nil {
                save()
                statusMessage = "Angehängt – die Aufnahme besteht jetzt aus \(document.files.count) Dateien."
            } else if let cue, restored.edit == nil {
                apply(cue.sheet, name: cue.url.lastPathComponent, undoable: false)
            } else if restored.edit != nil {
                statusMessage = "Die Schnitte vom letzten Mal sind wiederhergestellt."
                // Applied here, the sheet would replace the stored cuts without undo; it is offered instead.
                suggestedCue = cue?.url
            } else if let sibling = AppModel.cueSheet(nextTo: document.url) {
                suggestedCue = sibling
                statusMessage = "Neben der Datei liegt „\(sibling.lastPathComponent)“."
            }
            Task {
                let tags = await AudioLoader.tags(for: document.url)
                if self.document?.url == document.url { self.tags = tags }
            }
        case .failure(let error):
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
    }

    // MARK: Cue sheets

    nonisolated static func cueSheet(nextTo url: URL) -> URL? {
        let cue = url.deletingPathExtension().appendingPathExtension("cue")
        return FileManager.default.fileExists(atPath: cue.path) ? cue : nil
    }

    func showCuePanel() {
        guard let document, !isExporting, let type = AppModel.cueType else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [type]
        panel.prompt = "Übernehmen"
        panel.message = "Die Titel der Cue-Datei werden zu Schnitten mit Namen."
        panel.directoryURL = document.url.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { openCue(url) }
    }

    /// With a recording open, the sheet's tracks become its cuts. Otherwise the audio files the
    /// sheet names are opened from its folder and the tracks applied to them.
    func openCue(_ url: URL) {
        guard !isExporting else { return }
        let sheet: CueSheet
        do {
            sheet = try CueSheet.read(url)
        } catch {
            errorMessage = "„\(url.lastPathComponent)“ kann nicht gelesen werden."
            return
        }
        if document != nil {
            apply(sheet, name: url.lastPathComponent)
            return
        }
        let folder = url.deletingLastPathComponent()
        let files = sheet.files.map {
            folder.appendingPathComponent(($0.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent)
        }
        guard !files.isEmpty else {
            errorMessage = "In „\(url.lastPathComponent)“ steht keine Audiodatei."
            return
        }
        if let missing = files.first(where: { !FileManager.default.fileExists(atPath: $0.path) }) {
            errorMessage = "„\(missing.lastPathComponent)“ aus der Cue-Datei liegt nicht neben ihr. Öffne die Audiodatei und lade die Cue-Datei dann über Ablage → Cue-Datei laden …"
            return
        }
        load(files, cue: (sheet, url))
    }

    func acceptSuggestedCue() {
        guard let url = suggestedCue else { return }
        suggestedCue = nil
        openCue(url)
    }

    /// `undoable` is false right after loading: the change does not come from an event, so its undo
    /// group would stay open and swallow the user's next action.
    private func apply(_ sheet: CueSheet, name: String, undoable: Bool = true) {
        guard let document, let new = sheet.edit(for: document, minimumLength: minimumSegment) else {
            errorMessage = "In „\(name)“ stehen keine Titel, die zu dieser Aufnahme passen."
            return
        }
        suggestedCue = nil
        // The sheet's performer and title fill the export tags where nothing is set yet.
        var tags = customTags
        if exportTags.artist == nil, let performer = sheet.performer, !performer.isEmpty { tags.artist = performer }
        if exportTags.album == nil, let title = sheet.title, !title.isEmpty { tags.album = title }
        if undoable {
            commit(new, previous: edit, action: "Cue-Datei übernehmen")
            replaceTags(tags)
        } else {
            customTags = tags
            edit = new
            updateCurrentSegment()
            save()
        }
        statusMessage = "\(new.segments.count) Teile aus „\(name)“ übernommen."
    }

    // MARK: Playback

    func togglePlay() {
        guard document != nil else { return }
        isPlaying ? stopPlayback() : startPlayback()
    }

    private func startPlayback() {
        let ranges = playbackRanges
        guard let last = ranges.last else {
            NSSound.beep()
            return
        }
        // At the end (or behind the last part to play): start over.
        let from = playhead >= last.upperBound - minimumSegment / 10 ? ranges[0].lowerBound : playhead
        guard player.play(from: from, ranges: ranges) else { return }
        isPlaying = true
        updatePlaybackGain(at: from)
        startTimer()
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopPlayback() {
        let position = player.stop()
        if let previewReturn { playhead = previewReturn } else if let position { playhead = position }
        previewReturn = nil
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    /// Plays on from the current position with the current edit (after seeking or editing).
    private func restartPlayback() {
        guard isPlaying else { return }
        previewReturn = nil
        if !player.play(from: playhead, ranges: playbackRanges) { stopPlayback() }
        updatePlaybackGain(at: playhead)
    }

    static let previewSeconds = 2.0

    /// Plays 2 s before to 2 s after the cut closest to the playhead – of the solo track if one is
    /// chosen, so that the join sounds as it will be exported. The playhead then returns to the cut.
    func previewCut() {
        guard let document, !isExporting, let index = edit.cutIndex(nearest: playhead) else {
            NSSound.beep()
            return
        }
        let cut = edit.cuts[index]
        if isPlaying { stopPlayback() }
        let ranges = AppModel.previewRanges(around: cut, in: playbackRanges, span: document.frame(AppModel.previewSeconds))
        guard let first = ranges.first, player.play(from: first.lowerBound, ranges: ranges) else {
            NSSound.beep()
            return
        }
        playhead = first.lowerBound
        previewReturn = cut
        isPlaying = true
        updatePlaybackGain(at: first.lowerBound)
        startTimer()
        ensureVisible(Double(cut))
    }

    /// Up to `span` frames of `ranges` before `cut` and up to `span` frames after it.
    nonisolated static func previewRanges(around cut: Int64, in ranges: [Range<Int64>], span: Int64) -> [Range<Int64>] {
        var before: [Range<Int64>] = []
        var left = span
        for range in ranges.reversed() where range.lowerBound < cut && left > 0 {
            let upper = min(range.upperBound, cut)
            let lower = max(range.lowerBound, upper - left)
            before.insert(lower..<upper, at: 0)
            left -= upper - lower
        }
        var after: [Range<Int64>] = []
        left = span
        for range in ranges where range.upperBound > cut && left > 0 {
            let lower = max(range.lowerBound, cut)
            let upper = min(range.upperBound, lower + left)
            after.append(lower..<upper)
            left -= upper - lower
        }
        if let last = before.last, let first = after.first, last.upperBound == first.lowerBound {
            before[before.count - 1] = last.lowerBound..<first.upperBound
            after.removeFirst()
        }
        return before + after
    }

    /// The fades are heard while playing: the player's volume follows the part under the playhead.
    private func updatePlaybackGain(at frame: Int64) {
        guard !edit.segments.isEmpty else { return }
        player.gain = edit.segment(at: frame).fadeGain(at: frame)
    }

    private func playbackEnded(at end: Int64?) {
        if let previewReturn { playhead = previewReturn } else if let end { playhead = end }
        previewReturn = nil
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let position = player.position else { return }
        playhead = position
        updatePlaybackGain(at: position)
        // Turn the page when the playhead leaves the visible area.
        let frame = Double(position)
        if frame < visibleStart || frame > visibleStart + visibleLength {
            scroll(to: frame - visibleLength * 0.05)
        }
    }

    /// Moves the playhead. While dragging, `final` is false and playback is only restarted at the end.
    func seek(to frame: Int64, final: Bool = true) {
        guard let document else { return }
        let target = min(max(0, frame), document.length)
        playhead = target
        guard final else {
            // Silent while scrubbing; the timer finds no position and leaves the playhead alone.
            if isPlaying { player.stop() }
            return
        }
        if isPlaying {
            previewReturn = nil
            if player.play(from: target, ranges: playbackRanges) { updatePlaybackGain(at: target) } else { stopPlayback() }
        }
        ensureVisible(Double(target))
    }

    func step(seconds: Double) {
        guard let document else { return }
        seek(to: playhead + document.frame(seconds))
    }

    func goToStart() { seek(to: 0) }
    func goToEnd() { seek(to: document?.length ?? 0) }

    /// Jumps to the next or previous cut (or the start/end of the file).
    func jumpToCut(forward: Bool) {
        guard let document else { return }
        let marks = [0] + edit.cuts + [document.length]
        // While playing, a little slack lets repeated presses go further back.
        let slack = isPlaying ? document.frame(0.5) : 0
        let target = forward ? marks.first { $0 > playhead } : marks.last { $0 < playhead - slack }
        seek(to: target ?? (forward ? document.length : 0))
    }

    /// Makes a table row the current part: the playhead goes to its start.
    func select(_ id: Segment.ID) {
        guard id != currentSegmentID, let segment = edit.segments.first(where: { $0.id == id }) else { return }
        seek(to: segment.start)
        if Double(segment.end) > visibleStart + visibleLength || Double(segment.start) < visibleStart {
            scroll(to: Double(segment.start) - visibleLength * 0.05)
        }
    }

    // MARK: Editing

    func cutAtPlayhead() {
        guard document != nil else { return }
        var new = edit
        guard new.cut(at: playhead, minimumLength: minimumSegment) else {
            NSSound.beep()
            return
        }
        commit(new, previous: edit, action: "Schnitt setzen")
    }

    /// Puts the part under the playhead on another track.
    func moveCurrentPart(toTrack track: Int) {
        guard let segment = currentSegment else { return }
        setTrack(track, for: segment.id)
    }

    func setTrack(_ track: Int, for id: Segment.ID) {
        var new = edit
        new.setTrack(track, for: id)
        commit(new, previous: edit, action: "Teil auf Spur \(track)")
    }

    /// Deletes a part (it is no longer exported or played) or restores it on its track.
    func setDeleted(_ deleted: Bool, for id: Segment.ID) {
        var new = edit
        new.setDeleted(deleted, for: id)
        commit(new, previous: edit, action: deleted ? "Teil löschen" : "Teil wiederherstellen")
    }

    /// Deletes the part under the playhead, or restores it if it is deleted.
    func toggleDeletedCurrentPart() {
        guard let segment = currentSegment else { return }
        setDeleted(!segment.deleted, for: segment.id)
    }

    /// Moves the cut closest to the playhead by `seconds`; the playhead goes with it.
    func nudgeCut(by seconds: Double) {
        guard let document, let index = edit.cutIndex(nearest: playhead) else {
            NSSound.beep()
            return
        }
        var new = edit
        new.moveCut(index, to: edit.cuts[index] + document.frame(seconds), minimumLength: minimumSegment)
        guard new != edit else {
            NSSound.beep()
            return
        }
        playhead = new.cuts[index]
        commit(new, previous: edit, action: "Schnitt verschieben")
        ensureVisible(Double(playhead))
    }

    private func updateProposedCuts() {
        guard isFindingPauses, let peaks, let document else {
            if !proposedCuts.isEmpty { proposedCuts = [] }
            return
        }
        let pauses = PauseFinder.pauses(in: peaks, thresholdDB: pauseThreshold, minimumFrames: document.frame(pauseMinimum),
                                        bridgeFrames: document.frame(0.3))
        proposedCuts = PauseFinder.cuts(for: pauses, existing: edit.cuts)
    }

    /// Sets the cuts the pause finder proposes (one undo step).
    func applyProposedCuts() {
        var new = edit
        let count = new.cut(at: proposedCuts, minimumLength: minimumSegment)
        isFindingPauses = false
        guard count > 0 else { return }
        commit(new, previous: edit, action: "Schnitte in Pausen")
        statusMessage = count == 1 ? "1 Schnitt in eine Pause gesetzt." : "\(count) Schnitte in Pausen gesetzt."
    }

    func toggleSolo(_ track: Int) {
        soloTrack = soloTrack == track ? nil : track
    }

    func removeCut(_ index: Int) {
        var new = edit
        new.removeCut(index)
        commit(new, previous: edit, action: "Schnitt entfernen")
    }

    /// Dragging a cut: the edit changes live, undo and saving happen once at the end.
    func moveCut(_ index: Int, to frame: Int64, phase: DragPhase) {
        switch phase {
        case .began:
            editBeforeDrag = edit
        case .changed:
            edit.moveCut(index, to: frame, minimumLength: minimumSegment)
            updateCurrentSegment()
        case .ended:
            edit.moveCut(index, to: frame, minimumLength: minimumSegment)
            if let before = editBeforeDrag { commit(edit, previous: before, action: "Schnitt verschieben") }
            editBeforeDrag = nil
        }
    }

    /// Dragging a fade handle: like moving a cut, undo and saving happen once at the end.
    func setFade(_ edge: FadeEdge, of index: Int, to frames: Int64, phase: DragPhase) {
        switch phase {
        case .began:
            editBeforeDrag = edit
            edit.setFade(edge, of: index, to: frames)
        case .changed:
            edit.setFade(edge, of: index, to: frames)
        case .ended:
            edit.setFade(edge, of: index, to: frames)
            if let before = editBeforeDrag { commit(edit, previous: before, action: edge == .fadeIn ? "Einblenden" : "Ausblenden") }
            editBeforeDrag = nil
        }
    }

    /// Names are not undoable (the text field has its own undo while typing).
    func rename(_ id: Segment.ID, to name: String) {
        edit.rename(id, to: name)
        save()
    }

    private func save() {
        if let document { store.save(edit, tags: customTags, for: document) }
    }

    func resetEdits() {
        commit(EditList(length: edit.length), previous: edit, action: "Alle Schnitte entfernen")
    }

    private func commit(_ new: EditList, previous: EditList, action: String) {
        guard let document, new.length == document.length, new != previous || editBeforeDrag != nil else { return }
        edit = new
        updateCurrentSegment()
        save()
        updateProposedCuts()
        restartPlayback()
        guard new != previous else { return }
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.statusMessage = nil
                model.commit(previous, previous: new, action: action)
            }
        }
        undoManager?.setActionName(action)
    }

    /// Tags that change together with an edit (from a cue sheet) are undone with it: both undo
    /// registrations fall into the same group.
    private func replaceTags(_ tags: CustomTags) {
        let previous = customTags
        guard tags != previous else { return }
        setCustomTags(tags)
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.replaceTags(previous) }
        }
    }

    // MARK: Export tags

    func setCustomTags(_ new: CustomTags) {
        guard new != customTags else { return }
        let coverChanged = new.cover != customTags.cover
        customTags = new
        if coverChanged { loadCustomArtwork() }
        save()
    }

    func chooseCover() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = "Wählen"
        panel.message = "Bild für das Cover der exportierten MP3s"
        if let document { panel.directoryURL = document.url.deletingLastPathComponent() }
        if panel.runModal() == .OK, let url = panel.url { setCover(url) }
    }

    /// Takes an image file as cover (it is read again for every export session).
    func setCover(_ url: URL) {
        guard url.isFileURL, let data = try? Data(contentsOf: url), Artwork.prepare(data) != nil else {
            errorMessage = "„\(url.lastPathComponent)“ ist kein Bild, das MusicHub lesen kann."
            return
        }
        var new = customTags
        new.cover = .file(url.path)
        setCustomTags(new)
    }

    private func loadCustomArtwork() {
        if case .file(let path) = customTags.cover, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            customArtwork = Artwork.prepare(data)
        } else {
            customArtwork = nil
        }
    }

    // MARK: Zoom and scrolling

    /// The closest zoom shows 128 frames per point.
    private var minimumVisibleLength: Double { min(length, max(1, viewWidth) * 128) }

    func zoom(by factor: Double, around anchor: Double? = nil) {
        guard document != nil, visibleLength > 0 else { return }
        let playheadFrame = Double(playhead)
        let center = anchor ?? (playheadFrame >= visibleStart && playheadFrame <= visibleStart + visibleLength
            ? playheadFrame : visibleStart + visibleLength / 2)
        let ratio = (center - visibleStart) / visibleLength
        visibleLength = min(length, max(minimumVisibleLength, visibleLength / factor))
        scroll(to: center - ratio * visibleLength)
    }

    func zoomToFit() {
        visibleLength = max(1, length)
        visibleStart = 0
    }

    /// Zoom as 0 (whole file) … 1 (closest), on a logarithmic scale for the slider.
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

    private func ensureVisible(_ frame: Double) {
        if frame < visibleStart || frame > visibleStart + visibleLength {
            scroll(to: frame - visibleLength / 2)
        }
    }

    func setViewWidth(_ width: Double) {
        guard width > 0, width != viewWidth else { return }
        viewWidth = width
    }

    // MARK: Export

    /// Exports the parts of a track joined into one MP3, with a chapter per part. `withCue` also
    /// writes a cue sheet next to it.
    func exportTrack(_ track: Int, withCue: Bool = false) {
        guard let document, canExport(track: track) else { return }
        let parts = edit.segments(onTrack: track)
        let wholeFile = edit.ranges(onTrack: track) == [0..<document.length]
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mp3]
        panel.directoryURL = document.url.deletingLastPathComponent()
        panel.nameFieldStringValue = !wholeFile ? "\(document.name) – Spur \(track).mp3"
            : (document.files.count == 1 && document.url.pathExtension.lowercased() == "mp3" ? "\(document.name) (Kopie).mp3" : "\(document.name).mp3")
        panel.message = withCue ? "Spur \(track) als eine MP3 exportieren, mit Cue-Datei daneben" : "Spur \(track) als eine MP3 exportieren"
        panel.prompt = "Exportieren"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let tags = exportTags
        // The whole file keeps its title; a selection is named like the file it is saved as.
        let title = wholeFile ? (tags.title ?? document.name) : url.deletingPathExtension().lastPathComponent
        let titles = AppModel.partTitles(parts)
        var tag = ID3Tag(title: title, artist: tags.artist, album: tags.album ?? (wholeFile ? nil : tags.title), artwork: tags.artwork)
        if parts.count > 1 {
            tag.chapters = ID3Tag.chapters(titles: titles, lengths: parts.map(\.length), sampleRate: document.sampleRate)
        }
        var job = ExportJob(pieces: Exporter.pieces(for: parts, sourceLength: document.length, sampleRate: document.sampleRate),
                            destination: url, tag: tag, normalize: normalizeLoudness)
        if withCue {
            var start = 0.0
            let tracks = zip(titles, parts).map { title, part in
                defer { start += document.seconds(part.length) }
                return (title: title, start: start)
            }
            job.cueSheet = CueSheet.text(file: url.lastPathComponent, title: tag.album ?? title, performer: tags.artist, tracks: tracks)
            // The save panel only asked about the MP3. The cue sheet next to it – often the one the
            // recording came with – is not replaced unasked.
            if FileManager.default.fileExists(atPath: job.cueDestination.path) {
                let alert = NSAlert()
                alert.messageText = "„\(job.cueDestination.lastPathComponent)“ gibt es dort schon."
                alert.informativeText = "Die vorhandene Cue-Datei kommt in den Papierkorb."
                alert.addButton(withTitle: "Ersetzen")
                alert.addButton(withTitle: "Abbrechen")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
        }
        run([job], label: "„\(url.lastPathComponent)“")
    }

    /// Chapter and cue titles: the part names, or "Teil n" counted within the track.
    nonisolated static func partTitles(_ parts: [Segment]) -> [String] {
        parts.enumerated().map { index, part in
            let name = part.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "Teil \(index + 1)" : name
        }
    }

    /// Exports every part of a track as its own MP3.
    func exportTrackParts(_ track: Int) {
        guard let document, canExport(track: track) else { return }
        let parts = edit.segments(onTrack: track)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = document.url.deletingLastPathComponent()
        panel.prompt = "Hier exportieren"
        panel.message = parts.count == 1 ? "Ordner für den Teil von Spur \(track) wählen"
            : "Ordner für die \(parts.count) Teile von Spur \(track) wählen"
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        let jobs = AppModel.partJobs(parts, document: document, tags: exportTags, folder: folder, normalize: normalizeLoudness)
        if jobs.contains(where: { document.contains($0.destination) }) {
            errorMessage = ExportError.overwritesSource.localizedDescription
            return
        }
        let existing = jobs.filter { FileManager.default.fileExists(atPath: $0.destination.path) }
        if !existing.isEmpty {
            let alert = NSAlert()
            alert.messageText = existing.count == 1
                ? "„\(existing[0].destination.lastPathComponent)“ gibt es dort schon."
                : "\(existing.count) der Dateien gibt es dort schon."
            alert.informativeText = "Die vorhandenen Dateien kommen in den Papierkorb."
            alert.addButton(withTitle: "Ersetzen")
            alert.addButton(withTitle: "Abbrechen")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        run(jobs, label: jobs.count == 1 ? "1 Teil" : "\(jobs.count) Teile")
    }

    /// Exports one part as its own MP3, wherever it lies.
    func exportPart(_ id: Segment.ID) {
        guard let document, !isExporting, !isLoading, let index = edit.segments.firstIndex(where: { $0.id == id }),
              !edit.segments[index].deleted else { return }
        let segment = edit.segments[index]
        let name = segment.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = name.isEmpty ? "\(document.name) – Teil \(String(format: "%02d", index + 1))" : name
        let fileName = FileNames.sanitize(title)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mp3]
        panel.directoryURL = document.url.deletingLastPathComponent()
        panel.nameFieldStringValue = (fileName.isEmpty ? "Teil \(index + 1)" : fileName) + ".mp3"
        panel.message = "Teil \(index + 1) als MP3 exportieren"
        panel.prompt = "Exportieren"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let tags = exportTags
        let tag = ID3Tag(title: title, artist: tags.artist, album: tags.album ?? tags.title ?? document.name, artwork: tags.artwork)
        let job = ExportJob(pieces: Exporter.pieces(for: [segment], sourceLength: document.length, sampleRate: document.sampleRate),
                            destination: url, tag: tag, normalize: normalizeLoudness)
        run([job], label: "„\(url.lastPathComponent)“")
    }

    /// One job per part. Named parts become "01 Name.mp3", unnamed ones "<Datei> – Teil 01.mp3".
    nonisolated static func partJobs(_ parts: [Segment], document: AudioDocument, tags: SourceTags, folder: URL,
                                     normalize: Bool = false) -> [ExportJob] {
        var used: Set<String> = []
        return parts.enumerated().map { index, segment in
            let number = String(format: "%02d", index + 1)
            let name = segment.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = name.isEmpty ? "\(document.name) – Teil \(number)" : name
            var base = FileNames.sanitize(name.isEmpty ? title : "\(number) \(name)")
            if base.isEmpty { base = "Teil \(number)" }
            var fileName = base
            var counter = 2
            while used.contains(fileName.lowercased()) {
                fileName = "\(base) (\(counter))"
                counter += 1
            }
            used.insert(fileName.lowercased())
            let tag = ID3Tag(title: title, artist: tags.artist, album: tags.album ?? tags.title ?? document.name,
                             track: index + 1, trackCount: parts.count, artwork: tags.artwork)
            let pieces = Exporter.pieces(for: [segment], sourceLength: document.length, sampleRate: document.sampleRate)
            return ExportJob(pieces: pieces, destination: folder.appendingPathComponent(fileName).appendingPathExtension("mp3"),
                             tag: tag, normalize: normalize)
        }
    }

    /// Runs the jobs in the background; several parts are encoded at the same time.
    private func run(_ jobs: [ExportJob], label: String) {
        guard let document, !jobs.isEmpty else { return }
        stopPlayback()
        let token = CancelToken()
        exportToken = token
        isExporting = true
        exportProgress = 0
        exportLabel = label
        statusMessage = nil
        exportedFiles = []

        let source = document
        let total = max(1, jobs.reduce(0) { $0 + $1.work })
        let encoded = ProgressCounter()
        let nextJob = ProgressCounter()
        let finished = FinishedJobs()
        let errors = ErrorBox()
        let gate = PercentGate()
        let workers = min(jobs.count, max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2)))

        DispatchQueue.global(qos: .userInitiated).async {
            DispatchQueue.concurrentPerform(iterations: workers) { _ in
                while !token.isCancelled {
                    let index = Int(nextJob.add(1) - 1)
                    guard index < jobs.count else { return }
                    do {
                        try Exporter.export(jobs[index], source: source, token: token) { frames in
                            let value = Double(encoded.add(frames)) / Double(total)
                            guard gate.pass(value) else { return }
                            Task { @MainActor in
                                if token === self.exportToken { self.exportProgress = value }
                            }
                        }
                        finished.add(index)
                    } catch {
                        if !(error is CancellationError) { errors.set(error) }
                        token.cancel()
                    }
                }
            }
            let done = finished.indices.sorted().map { jobs[$0].destination }
            Task { @MainActor in
                self.finishExport(done: done, of: jobs.count, error: errors.error, folder: jobs[0].destination.deletingLastPathComponent())
            }
        }
    }

    func cancelExport() {
        exportToken?.cancel()
    }

    private func finishExport(done: [URL], of count: Int, error: Error?, folder: URL) {
        exportToken = nil
        isExporting = false
        exportedFiles = done
        if let error {
            var message = error.localizedDescription
            if !done.isEmpty { message += "\n\n\(done.count) von \(count) Dateien sind fertig geworden." }
            errorMessage = message
        } else if done.count < count {
            statusMessage = done.isEmpty ? "Export abgebrochen." : "Export abgebrochen – \(done.count) von \(count) Dateien sind fertig."
        } else {
            statusMessage = count == 1
                ? "Exportiert: \(done[0].lastPathComponent)"
                : "\(count) Dateien exportiert nach „\(folder.lastPathComponent)“."
        }
        if quitAfterExport {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }

    func showExportedFiles() {
        guard !exportedFiles.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(exportedFiles)
    }

    // MARK: Keyboard

    /// Single keys for the editor (handled before buttons and the table see them; text fields are
    /// left alone by the caller). Returns true if the key was used.
    func handleKey(_ event: NSEvent) -> Bool {
        guard document != nil, !isExporting, !isLoading else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !flags.contains(.command), !flags.contains(.control) else { return false }
        switch event.keyCode {
        case 49: togglePlay()                                            // space
        case 123: flags.contains(.option) ? jumpToCut(forward: false)    // ←
            : step(seconds: flags.contains(.shift) ? -10 : -1)
        case 124: flags.contains(.option) ? jumpToCut(forward: true)     // →
            : step(seconds: flags.contains(.shift) ? 10 : 1)
        case 115: goToStart()                                            // home
        case 119: goToEnd()                                              // end
        case 43 where !flags.contains(.option):                          // , (by position)
            nudgeCut(by: flags.contains(.shift) ? -0.1 : -0.01)
        case 47 where !flags.contains(.option):                          // .
            nudgeCut(by: flags.contains(.shift) ? 0.1 : 0.01)
        case 51 where flags.isEmpty, 117 where flags.isEmpty:            // ⌫, ⌦
            guard let segment = currentSegment else { return false }
            if segment.deleted { NSSound.beep() } else { setDeleted(true, for: segment.id) }
        default:
            guard flags.isEmpty, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
            if key == "s" {
                cutAtPlayhead()
            } else if key == "v" {
                previewCut()
            } else if let track = Int(key), EditList.tracks.contains(track) {
                moveCurrentPart(toTrack: track)
            } else {
                return false
            }
        }
        return true
    }
}

/// Recordings opened before, as the paths of their files (newest first).
enum RecentFiles {
    static let key = "recentRecordings"
    static let limit = 10

    static func adding(_ paths: [String], to list: [[String]]) -> [[String]] {
        Array(([paths] + list.filter { $0 != paths }).prefix(limit))
    }

    static func load(_ defaults: UserDefaults) -> [[String]] {
        defaults.array(forKey: key) as? [[String]] ?? []
    }

    static func save(_ list: [[String]], _ defaults: UserDefaults) {
        defaults.set(list, forKey: key)
    }

    /// "Aufnahme.mp3" or "Teil 1.wav + 2 weitere"
    static func name(_ paths: [String]) -> String {
        let first = paths.first.map { ($0 as NSString).lastPathComponent } ?? ""
        return paths.count > 1 ? "\(first) + \(paths.count - 1) weitere" : first
    }
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

/// Indices of finished export jobs, collected from several threads.
final class FinishedJobs: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int] = []

    func add(_ index: Int) { lock.withLock { stored.append(index) } }
    var indices: [Int] { lock.withLock { stored } }
}
