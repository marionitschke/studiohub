import AppKit
import AVFoundation
import CoreImage
import Observation
import UniformTypeIdentifiers

/// One video of the batch and how far it is.
struct BatchItem: Identifiable, Equatable {
    enum Status: Equatable {
        case waiting
        /// macOS cannot open it (e.g. MKV or AVI) or it has no picture.
        case unreadable(String)
        /// The result is already in the destination folder; it is skipped.
        case exists
        case running(BatchProcessor.Phase, Double)
        case done(SoundNormalizer.Result?)
        case failed(String)
        case cancelled
    }

    let source: URL
    var destination: URL
    let title: String
    var duration: Double?
    var summary: String?
    var status = Status.waiting
    /// A logo of its own already in the bottom left corner (nil: not checked yet).
    var hasLogo: Bool?
    /// Chosen by hand in the list; wins over the check.
    var watermarkChoice: Bool?

    var id: URL { source }

    /// Whether the video gets the watermark: not where it has a logo already. nil while unknown.
    var getsWatermark: Bool? { watermarkChoice ?? hasLogo.map { !$0 } }
}

/// The batch tab: source and destination folder, the settings for all videos, the list of videos
/// with their state, a preview of the settings and the run itself. Folders and settings are
/// remembered; the run is not (a second run skips what is already in the destination).
@MainActor
@Observable
final class BatchModel {
    private(set) var source: URL?
    private(set) var destination: URL?
    private(set) var settings = BatchSettings.load()
    private(set) var items: [BatchItem] = []
    var selection: URL? {
        didSet { if selection != oldValue { loadPreview() } }
    }
    /// Reading lengths and formats.
    private(set) var isScanning = false
    private(set) var isCheckingLogos = false
    private(set) var isRunning = false
    private(set) var preview: NSImage?
    private(set) var previewTime: Double?
    private(set) var previewProblem: String?
    var errorMessage: String?
    private(set) var finishedMessage: String?
    /// While running: media seconds per second of work, for the time still needed.
    private(set) var startedAt: Date?
    private(set) var secondsDone = 0.0

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var logoTask: Task<Void, Never>?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var previewSource: (id: URL, document: VideoDocument, title: String, frame: CIImage, renderer: EffectRenderer)?
    /// Called once when a run has ended (quitting waits for it).
    @ObservationIgnored var onRunEnded: (() -> Void)?

    private static let sourceKey = "batchSource", destinationKey = "batchDestination"

    init() {
        let defaults = UserDefaults.standard
        source = defaults.string(forKey: Self.sourceKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
        destination = defaults.string(forKey: Self.destinationKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let watermark = settings.watermark, !FileManager.default.fileExists(atPath: watermark.path) { settings.watermark = nil }
    }

    // MARK: Folders

    /// Lists the source folder the first time the tab is shown.
    func appear() {
        if items.isEmpty, !isScanning, source != nil { scan() }
    }

    func chooseSource() {
        guard let url = chooseFolder("Ordner mit den Videos wählen – VideoHub bearbeitet die Videos direkt darin (ohne Unterordner)",
                                     start: source) else { return }
        setSource(url)
    }

    func chooseDestination() {
        guard let url = chooseFolder("Ordner für die fertigen Videos wählen", start: destination ?? source) else { return }
        setDestination(url)
    }

    func setSource(_ url: URL) {
        guard !isRunning else { return }
        source = url
        UserDefaults.standard.set(url.path, forKey: Self.sourceKey)
        finishedMessage = nil
        scan()
    }

    func setDestination(_ url: URL) {
        guard !isRunning else { return }
        destination = url
        UserDefaults.standard.set(url.path, forKey: Self.destinationKey)
        finishedMessage = nil
        refreshDestinations()
    }

    private func chooseFolder(_ message: String, start: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = message
        panel.prompt = "Wählen"
        panel.directoryURL = start
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Lists the videos of the source folder and reads their length and format in the background.
    func scan() {
        guard let source, !isRunning else { return }
        scanTask?.cancel()
        stopCheckingLogos()
        let urls: [URL]
        do {
            urls = try BatchRecipe.videos(in: source)
        } catch {
            items = []
            errorMessage = "„\(source.lastPathComponent)“ lässt sich nicht lesen: \(error.localizedDescription)"
            return
        }
        let folder = destination ?? source
        let targets = BatchRecipe.destinations(for: urls, in: folder, format: settings.format)
        items = zip(urls, targets).map { BatchItem(source: $0, destination: $1, title: BatchRecipe.title(forFile: $0)) }
        refreshDestinations()
        if selection == nil || !items.contains(where: { $0.id == selection }) { selection = items.first?.id }
        isScanning = true
        scanTask = Task {
            for url in urls {
                guard !Task.isCancelled else { return }
                let info: (Double, String)?
                var problem: String?
                do {
                    let document = try await VideoDocument.open(url)
                    info = (document.seconds(document.length), document.summary)
                } catch {
                    info = nil
                    problem = error.localizedDescription
                }
                guard !Task.isCancelled, let index = items.firstIndex(where: { $0.id == url }) else { continue }
                if let info {
                    items[index].duration = info.0
                    items[index].summary = info.1
                } else if let problem {
                    items[index].status = .unreadable(problem)
                }
            }
            guard !Task.isCancelled else { return }
            isScanning = false
            checkLogos()
        }
    }

    /// Checks the corners of the videos not checked yet, so that the list shows early which videos
    /// get the watermark. Not while a run exports: decoding for the check at the same time made the
    /// spare frames of the export pile up (thousands of IOSurfaces) and may let it stand still. The
    /// run checks each video just before it instead.
    private func checkLogos() {
        stopCheckingLogos()
        guard !isRunning else { return }
        let urls = items.filter { item in
            if case .unreadable = item.status { return false }
            return item.hasLogo == nil
        }.map(\.id)
        guard !urls.isEmpty else { return }
        isCheckingLogos = true
        logoTask = Task {
            for url in urls {
                guard !Task.isCancelled else { return }
                guard items.first(where: { $0.id == url })?.hasLogo == nil else { continue }
                let found = await BurnedInLogo.hasLogo(url)
                guard !Task.isCancelled else { return }
                store(found, for: url)
            }
            isCheckingLogos = false
        }
    }

    /// The stopped check may still be reading a frame; `start()` waits for it.
    @discardableResult
    private func stopCheckingLogos() -> Task<Void, Never>? {
        let task = logoTask
        task?.cancel()
        logoTask = nil
        isCheckingLogos = false
        return task
    }

    private func store(_ hasLogo: Bool?, for id: URL) {
        guard let hasLogo, let index = items.firstIndex(where: { $0.id == id }), items[index].hasLogo != hasLogo else { return }
        items[index].hasLogo = hasLogo
        if id == selection { renderPreview() }
    }

    var selectedItem: BatchItem? { items.first { $0.id == selection } }

    /// nil: as the check found.
    func setWatermark(_ choice: Bool?, for id: URL) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        switch items[index].status {
        case .running, .done: return
        default: break
        }
        items[index].watermarkChoice = choice
        if id == selection { renderPreview() }
    }

    /// Destination names follow the format; videos already done there are marked to be skipped.
    private func refreshDestinations() {
        guard let folder = destination ?? source else { return }
        let targets = BatchRecipe.destinations(for: items.map(\.source), in: folder, format: settings.format)
        for index in items.indices {
            items[index].destination = targets[index]
            switch items[index].status {
            case .waiting, .exists, .cancelled:
                let exists = destination != nil && FileManager.default.fileExists(atPath: targets[index].path)
                items[index].status = exists ? .exists : .waiting
            default:
                break
            }
        }
    }

    // MARK: Settings

    func chooseWatermark() {
        guard !isRunning else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Bild für das Wasserzeichen wählen – am besten ein PNG mit durchsichtigem Hintergrund"
        panel.prompt = "Wählen"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let copy = try LogoStore.importImage(url, trimmed: true)
            let old = settings.watermark
            change { $0.watermark = copy }
            // Copies the editor might still use are left to `LogoStore.cleanUp()` at the next launch.
            if let old, old.path != LogoStore.remembered()?.file.path { try? FileManager.default.removeItem(at: old) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeWatermark() {
        change { $0.watermark = nil }
    }

    func change(_ update: (inout BatchSettings) -> Void) {
        guard !isRunning else { return }
        let format = settings.format
        update(&settings)
        settings.save()
        if settings.format != format { refreshDestinations() }
        renderPreview()
    }

    // MARK: Preview

    /// Reads a frame of the selected video (in the middle of its title) for the preview.
    private func loadPreview() {
        previewTask?.cancel()
        guard let item = items.first(where: { $0.id == selection }) else {
            previewSource = nil
            preview = nil
            previewProblem = nil
            return
        }
        if case .unreadable(let problem) = item.status {
            previewSource = nil
            preview = nil
            previewProblem = problem
            return
        }
        previewTask = Task {
            do {
                let document = try await VideoDocument.open(item.source)
                let frame = try await BatchRecipe.previewFrame(document)
                guard !Task.isCancelled else { return }
                if item.hasLogo == nil, !isRunning, let score = try? await BurnedInLogo.detect(document) {
                    guard !Task.isCancelled else { return }
                    store(score.hasLogo, for: item.id)
                }
                let edit = BatchRecipe.edit(for: document, title: item.title, settings: settings)
                let renderer = EffectRenderer(document: document, content: EffectContent(edit: edit, layout: edit.effectLayout(frame: document.frameTicks)))
                previewSource = (item.id, document, item.title, frame, renderer)
                previewTime = document.seconds(BatchRecipe.previewPosition(document))
                previewProblem = nil
                renderPreview()
            } catch {
                guard !Task.isCancelled else { return }
                previewSource = nil
                preview = nil
                previewProblem = error.localizedDescription
            }
        }
    }

    /// The preview frame with title and watermark as the export draws them.
    private func renderPreview() {
        guard let source = previewSource else { return }
        let document = source.document
        let watermark = items.first { $0.id == source.id }?.getsWatermark ?? true
        let edit = BatchRecipe.edit(for: document, title: source.title, settings: settings, watermark: watermark)
        source.renderer.update(EffectContent(edit: edit, layout: edit.effectLayout(frame: document.frameTicks)))
        guard let picture = BatchRecipe.preview(source.frame, document: document, renderer: source.renderer) else { return }
        preview = NSImage(cgImage: picture, size: source.renderer.renderSize)
    }

    // MARK: Run

    /// Waiting, and the videos a new start tries again.
    var waitingItems: [BatchItem] {
        items.filter {
            switch $0.status {
            case .waiting, .cancelled, .failed: true
            default: false
            }
        }
    }

    /// Why the batch cannot start yet; nil when it can.
    var startProblem: String? {
        guard let source else { return "Wähle den Ordner mit den Videos." }
        guard let destination else { return "Wähle den Ordner für die fertigen Videos." }
        if BatchRecipe.sameFolder(source, destination) { return "Das Ziel muss ein anderer Ordner sein als die Quelle." }
        if settings.watermark == nil, waitingItems.contains(where: { $0.getsWatermark != false }) {
            return "Wähle ein Bild für das Wasserzeichen."
        }
        if isScanning && items.isEmpty { return "Die Videos werden gelesen …" }
        if waitingItems.isEmpty { return items.isEmpty ? "Im Quellordner liegen keine Videos." : "Alle Videos sind schon im Zielordner." }
        return nil
    }

    func start() {
        guard !isRunning, startProblem == nil else { return }
        refreshDestinations()
        for index in items.indices {
            switch items[index].status {
            case .cancelled, .failed: items[index].status = .waiting
            default: break
            }
        }
        isRunning = true
        finishedMessage = nil
        startedAt = Date()
        secondsDone = 0
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                         reason: "VideoHub bearbeitet Videos im Stapel")
        let settings = self.settings
        let check = stopCheckingLogos()
        runTask = Task {
            await check?.value
            var done = 0, failed = 0
            for index in items.indices {
                guard !Task.isCancelled else { break }
                guard items[index].status == .waiting else { continue }
                let item = items[index]
                if FileManager.default.fileExists(atPath: item.destination.path) {
                    items[index].status = .exists
                    continue
                }
                if let problem = spaceProblem(for: item) {
                    items[index].status = .failed(problem)
                    failed += 1
                    errorMessage = problem
                    break
                }
                try? FileManager.default.createDirectory(at: item.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                items[index].status = .running(.sound, 0)
                let id = item.id
                if item.getsWatermark == nil {
                    let found = await BurnedInLogo.hasLogo(item.source)
                    store(found, for: id)
                }
                let watermark = items[index].getsWatermark ?? true
                do {
                    let result = try await BatchProcessor.process(item.source, title: item.title, watermark: watermark, to: item.destination,
                                                                  settings: settings) { phase, value in
                        Task { @MainActor [weak self] in self?.progress(id, phase, value) }
                    }
                    items[index].status = .done(result)
                    done += 1
                } catch {
                    if Task.isCancelled || error is CancellationError {
                        items[index].status = .cancelled
                        break
                    }
                    items[index].status = .failed(error.localizedDescription)
                    failed += 1
                }
                secondsDone += item.duration ?? 0
            }
            finish(done: done, failed: failed, cancelled: Task.isCancelled)
        }
    }

    func cancel() {
        runTask?.cancel()
    }

    private func progress(_ id: URL, _ phase: BatchProcessor.Phase, _ value: Double) {
        guard let index = items.firstIndex(where: { $0.id == id }), case .running = items[index].status else { return }
        items[index].status = .running(phase, value)
    }

    private func finish(done: Int, failed: Int, cancelled: Bool) {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        isRunning = false
        runTask = nil
        startedAt = nil
        var parts = [done == 1 ? "1 Video bearbeitet" : "\(done) Videos bearbeitet"]
        if failed > 0 { parts.append(failed == 1 ? "1 Fehler" : "\(failed) Fehler") }
        finishedMessage = (cancelled ? "Abgebrochen: " : "Fertig: ") + parts.joined(separator: ", ") + "."
        onRunEnded?()
        onRunEnded = nil
        checkLogos()
    }

    /// Stops before a video that would not fit: the result needs about the size of the source.
    private func spaceProblem(for item: BatchItem) -> String? {
        let folder = item.destination.deletingLastPathComponent()
        guard let free = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
              let size = try? item.source.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        let needed = Int64(Double(size) * 1.5) + 1_000_000_000
        guard free < needed else { return nil }
        return "Im Zielordner ist nicht genug Platz für „\(item.source.lastPathComponent)“ (frei: \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)))."
    }

    /// The media time still to do ÷ the speed so far; nil until there is enough to go by.
    var remainingSeconds: Double? {
        guard isRunning, let startedAt else { return nil }
        let elapsed = Date().timeIntervalSince(startedAt)
        var doneNow = secondsDone, left = 0.0
        for item in items {
            switch item.status {
            case .running(_, let value):
                doneNow += (item.duration ?? 0) * value
                left += (item.duration ?? 0) * (1 - value)
            case .waiting:
                left += item.duration ?? 0
            default:
                break
            }
        }
        guard elapsed > 20, doneNow > 0 else { return nil }
        return left / (doneNow / elapsed)
    }

    func showResults() {
        let done = items.filter { if case .done = $0.status { true } else { false } }.map(\.destination)
        if !done.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(done)
        } else if let destination {
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
    }
}
