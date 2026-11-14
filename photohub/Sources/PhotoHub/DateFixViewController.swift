import AppKit

/// Table row: a file with a mismatching date, a month folder destination, or both.
private struct DateFixRow: Sendable {
    /// Path as text – `URL` decomposes umlauts.
    let path: String
    let captureDate: Date?
    let current: FileDates
    let needsFix: Bool
    let move: MonthSorter.Move?
    var url: URL { URL(fileURLWithPath: path) }
}

/// Result of “Prüfen” (check): date mismatches, month folders and the resulting rows.
private struct DateFixCheck: Sendable {
    let plan: DateFixer.Plan
    let months: MonthSorter.Plan
    let rows: [DateFixRow]

    init(plan: DateFixer.Plan, months: MonthSorter.Plan) {
        self.plan = plan
        self.months = months
        var moves = Dictionary(months.moves.map { ($0.sourcePath, $0) }, uniquingKeysWith: { first, _ in first })
        var rows = plan.toFix.map { item in
            DateFixRow(path: item.path, captureDate: item.captureDate, current: item.current, needsFix: true,
                       move: moves.removeValue(forKey: item.path))
        }
        for move in months.moves where moves[move.sourcePath] != nil {
            rows.append(DateFixRow(path: move.sourcePath, captureDate: plan.captureDates[move.sourcePath] ?? nil,
                                   current: FileDates.read(URL(fileURLWithPath: move.sourcePath)), needsFix: false, move: move))
        }
        self.rows = rows.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

/// A change that can be undone.
private enum DateFixChange: Sendable {
    case dates(DateFixer.Outcome)
    case months(MonthSorter.Outcome)

    var summary: String {
        switch self {
        case .dates(let outcome): return "\(plural(outcome.changed.count, "Datei", "Dateien")) korrigiert"
        case .months(let outcome): return "\(plural(outcome.moved.count, "Datei", "Dateien")) \(outcome.copies ? "kopiert" : "einsortiert")"
        }
    }

    func undo() -> [String] {
        switch self {
        case .dates(let outcome): return DateFixer.undo(outcome)
        case .months(let outcome): return MonthSorter.undo(outcome)
        }
    }
}

/// Tab “Bilder-Datum korrigieren”: sets created, modified and added dates of photos and videos to the capture
/// time and optionally sorts them into month subfolders `01` … `12`.
final class DateFixViewController: NSViewController {
    private enum Phase {
        case idle
        case checking
        case ready
        case applying
        case done(DateFixChange)
        case failed(title: String, message: String)
    }

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let folder = "fixFolderPath"
        static let subfolders = "fixIncludeSubfolders"
        static let monthDestination = "fixMonthDestinationPath"
    }

    private var folder: URL?
    private var includeSubfolders = true
    /// Destination for the month folders – files are copied there. nil: move within the folder itself.
    private var monthDestination: URL?
    private var phase: Phase = .idle
    private var plan = DateFixer.Plan()
    private var monthPlan = MonthSorter.Plan()
    private var rows: [DateFixRow] = []
    /// Undone from the top: a later month sort first, then an earlier date fix, which knows the old paths.
    private var undoStack: [DateFixChange] = []
    private var task: Task<Void, Never>?
    private var runID = 0
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    // Header
    private lazy var folderButton = NSButton(title: "", target: self, action: #selector(revealFolder))
    private lazy var chooseButton = NSButton(title: "Wählen …", target: self, action: #selector(chooseFolder))
    private lazy var subfolderCheckbox = NSButton(checkboxWithTitle: "Unterordner einbeziehen", target: self, action: #selector(subfoldersChanged))
    private lazy var checkButton = NSButton(title: "Prüfen", target: self, action: #selector(check))
    private lazy var destinationButton = NSButton(title: "", target: self, action: #selector(revealDestination))
    private lazy var chooseDestinationButton = NSButton(title: "Wählen …", target: self, action: #selector(chooseDestination))
    private lazy var clearDestinationButton = NSButton(title: "Kein Ziel", target: self, action: #selector(clearDestination))

    // Content
    private let messageView = MessageView()
    private let progressView = ScanProgressView()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()

    // Footer
    private let bottomSeparator = NSBox()
    private let bottomBar = NSStackView()
    private let summaryLabel = NSTextField.label("")
    private let undoLabel = NSTextField.label("")
    private lazy var undoButton = NSButton(title: "Rückgängig", target: self, action: #selector(undo))
    private lazy var sortButton = NSButton(title: "In Monatsordner sortieren …", target: self, action: #selector(confirmSort))
    private lazy var applyButton = NSButton(title: "Datum korrigieren …", target: self, action: #selector(confirmApply))

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "Bilder-Datum korrigieren"
        if let path = defaults.string(forKey: Keys.folder) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                folder = URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        includeSubfolders = defaults.object(forKey: Keys.subfolders) as? Bool ?? true
        if let path = defaults.string(forKey: Keys.monthDestination) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                monthDestination = URL(fileURLWithPath: path, isDirectory: true)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht unterstützt") }

    // MARK: - Layout

    override func loadView() {
        let root = DropView(frame: NSRect(x: 0, y: 0, width: 1120, height: 760))
        root.onDropFolder = { [weak self] url in self?.setFolder(url) }
        view = root

        let topSeparator = NSBox()
        topSeparator.boxType = .separator
        bottomSeparator.boxType = .separator

        let center = NSView()
        center.setContentHuggingPriority(.init(1), for: .vertical)
        center.setContentCompressionResistancePriority(.init(1), for: .vertical)
        for subview in [messageView, progressView, scrollView] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            center.addSubview(subview)
            NSLayoutConstraint.activate([
                subview.topAnchor.constraint(equalTo: center.topAnchor),
                subview.bottomAnchor.constraint(equalTo: center.bottomAnchor),
                subview.leadingAnchor.constraint(equalTo: center.leadingAnchor),
                subview.trailingAnchor.constraint(equalTo: center.trailingAnchor),
            ])
        }

        let layout = NSStackView(views: [makeTopBar(), topSeparator, center, bottomSeparator, makeBottomBar()])
        layout.orientation = .vertical
        layout.spacing = 0
        layout.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.topAnchor.constraint(equalTo: root.topAnchor),
            layout.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            layout.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            layout.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        for subview in layout.arrangedSubviews {
            subview.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true
        }

        setUpTable()
        progressView.cancelButton.target = self
        progressView.cancelButton.action = #selector(cancel)
    }

    private func makeTopBar() -> NSView {
        for button in [folderButton, destinationButton] {
            button.isBordered = false
            button.imagePosition = .imageLeading
            button.alignment = .left
            button.lineBreakMode = .byTruncatingMiddle
            button.setContentHuggingPriority(.init(1), for: .horizontal)
            button.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        }
        subfolderCheckbox.toolTip = "Auch alle Unterordner durchsuchen – und jedem seine eigenen Monatsordner geben. "
            + "Fotos-Mediatheken und versteckte Dateien werden nie verändert."
        checkButton.toolTip = "Aufnahmezeit aller Fotos und Videos lesen, mit dem Dateidatum vergleichen und die Monatsordner planen"
        chooseDestinationButton.toolTip = "Zielordner für die Monatsordner wählen – dann wird kopiert, das Original bleibt unverändert"
        clearDestinationButton.toolTip = "Ohne Zielordner: die Monatsordner entstehen im Ordner selbst, die Dateien werden verschoben"

        func label(_ text: String) -> NSTextField {
            let field = NSTextField.label(text)
            field.textColor = Darcula.muted
            return field
        }
        let grid = NSGridView(views: [
            [label("Ordner:"), folderButton, chooseButton, subfolderCheckbox, checkButton],
            [label("Kopien nach:"), destinationButton, chooseDestinationButton, clearDestinationButton, NSGridCell.emptyContentView],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 4).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.columnSpacing = 10
        grid.rowSpacing = 8
        grid.column(at: 3).leadingPadding = 8

        let bar = NSStackView(views: [grid])
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        grid.widthAnchor.constraint(equalTo: bar.widthAnchor, constant: -28).isActive = true
        return bar
    }

    private func makeBottomBar() -> NSView {
        summaryLabel.textColor = Darcula.muted
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setContentCompressionResistancePriority(.init(10), for: .horizontal)
        undoLabel.lineBreakMode = .byTruncatingTail
        undoLabel.setContentCompressionResistancePriority(.init(20), for: .horizontal)
        applyButton.image = NSImage(systemSymbolName: "calendar.badge.clock", accessibilityDescription: nil)
        applyButton.imagePosition = .imageLeading
        applyButton.keyEquivalent = "\r"
        applyButton.bezelColor = StudioApp.photo.color
        sortButton.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
        sortButton.imagePosition = .imageLeading
        sortButton.toolTip = "Fotos und Videos nach Aufnahmemonat in Unterordner 01 bis 12 verschieben – "
            + "mit „Unterordner einbeziehen“ in jedem Ordner, in dem sie liegen"
        undoButton.toolTip = "Die letzte Änderung zurücknehmen"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        bottomBar.setViews([summaryLabel, undoLabel, undoButton, spacer, sortButton, applyButton], in: .leading)
        bottomBar.orientation = .horizontal
        bottomBar.spacing = 10
        bottomBar.setCustomSpacing(16, after: summaryLabel)
        bottomBar.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        return bottomBar
    }

    private func setUpTable() {
        let columns: [(id: String, title: String, width: CGFloat)] = [
            ("file", "Datei", 250),
            ("capture", "Aufnahmezeit", 148),
            ("created", "Erstellt", 148),
            ("modified", "Geändert", 148),
            ("added", "Hinzugefügt", 148),
            ("month", "Monatsordner", 150),
        ]
        for spec in columns {
            let column = NSTableColumn(identifier: .init(spec.id))
            column.title = spec.title
            column.width = spec.width
            column.minWidth = 80
            tableView.addTableColumn(column)
        }
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.useDarculaStyle()
        tableView.style = .inset
        tableView.rowHeight = 22
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(revealRow)
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        render()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.subtitle = folder?.lastPathComponent ?? ""
    }

    // MARK: - Display

    private var isBusy: Bool {
        switch phase {
        case .checking, .applying: return true
        default: return false
        }
    }

    private func render() {
        let busy = isBusy
        if let folder {
            folderButton.title = folder.path
            folderButton.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
            folderButton.contentTintColor = Darcula.text
            folderButton.toolTip = "Im Finder zeigen"
        } else {
            folderButton.title = "Kein Ordner gewählt"
            folderButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            folderButton.contentTintColor = Darcula.muted
            folderButton.toolTip = nil
        }
        if let monthDestination {
            destinationButton.title = monthDestination.path
            destinationButton.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
            destinationButton.contentTintColor = Darcula.text
            destinationButton.toolTip = "Im Finder zeigen"
        } else {
            destinationButton.title = "Kein Ziel – Monatsordner entstehen im Ordner selbst (verschieben)"
            destinationButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            destinationButton.contentTintColor = Darcula.muted
            destinationButton.toolTip = nil
        }
        chooseDestinationButton.isEnabled = !busy
        clearDestinationButton.isEnabled = !busy
        clearDestinationButton.isHidden = monthDestination == nil
        subfolderCheckbox.state = includeSubfolders ? .on : .off
        chooseButton.isEnabled = !busy
        subfolderCheckbox.isEnabled = !busy
        checkButton.isEnabled = !busy && folder != nil
        if case .idle = phase { checkButton.title = "Prüfen" } else { checkButton.title = "Neu prüfen" }

        messageView.isHidden = true
        progressView.isHidden = true
        scrollView.isHidden = true
        switch phase {
        case .idle where folder == nil:
            messageView.isHidden = false
            messageView.show(symbol: "calendar.badge.clock", title: "Dateidatum korrigieren",
                             text: "PhotoHub liest die Aufnahmezeit aller Fotos und Videos aus ihren Metadaten und setzt „Erstellt“, "
                                 + "„Geändert“ und „Hinzugefügt“ im Finder darauf – wie der Tab „Apple Fotos Export“. Auf Wunsch "
                                 + "sortiert es die Fotos und Videos nach Monat in Unterordner 01 bis 12, in jedem Ordner. "
                                 + "Die Bilder selbst bleiben unverändert. Du kannst den Ordner auch in dieses Fenster ziehen.",
                             buttonTitle: "Ordner wählen …") { [weak self] in self?.chooseFolder() }
        case .idle:
            messageView.isHidden = false
            messageView.show(symbol: "magnifyingglass", title: "Bereit zum Prüfen",
                             text: "Vor jeder Änderung siehst du, welche Dateien betroffen sind, welches Datum sie bekommen und in "
                                 + "welchen Monatsordner sie kämen.",
                             buttonTitle: "Jetzt prüfen") { [weak self] in self?.check() }
        case .checking, .applying:
            progressView.isHidden = false
        case .ready where rows.isEmpty:
            messageView.isHidden = false
            var text = "Bei \(plural(plan.correctCount, "Datei", "Dateien")) stimmen Erstellt, Geändert und Hinzugefügt schon mit der Aufnahmezeit überein."
            if !plan.withoutDate.isEmpty { text += " \(plural(plan.withoutDate.count, "Datei", "Dateien")) ohne Aufnahmezeit bleiben, wie sie sind." }
            messageView.show(symbol: "checkmark.seal", title: plan.checkedCount == 0 ? "Keine Fotos gefunden" : "Alles stimmt",
                             text: plan.checkedCount == 0 ? "In diesem Ordner liegen keine Fotos oder Videos." : text)
        case .ready:
            scrollView.isHidden = false
        case .done(.months(let outcome)):
            messageView.isHidden = false
            var text: String
            if outcome.copies {
                text = "\(plural(outcome.moved.count, "Datei", "Dateien")) nach „\(monthPlan.destination?.lastPathComponent ?? "")“ kopiert, "
                    + "in \(monthFolderText(withArticle: true))."
            } else {
                text = "\(plural(outcome.moved.count, "Datei", "Dateien")) in \(monthFolderText(withArticle: true)) verschoben."
            }
            if !outcome.failures.isEmpty {
                text += (outcome.copies ? " Nicht kopiert: " : " Nicht verschoben: ")
                    + outcome.failures.prefix(5).joined(separator: "; ") + (outcome.failures.count > 5 ? " …" : "")
            }
            text += outcome.copies ? " Das Original ist unverändert. „Rückgängig“ legt die Kopien in den Papierkorb."
                : " Andere Dateien sind unverändert. „Rückgängig“ verschiebt alles zurück."
            let done = outcome.copies ? "In Monatsordner kopiert" : "In Monatsordner sortiert"
            messageView.show(symbol: outcome.failures.isEmpty ? "checkmark.circle" : "exclamationmark.triangle",
                             title: outcome.wasCancelled ? "Abgebrochen" : done, text: text,
                             buttonTitle: "Neu prüfen") { [weak self] in self?.check() }
        case .done(.dates(let outcome)):
            messageView.isHidden = false
            var text = "Bei \(plural(outcome.changed.count, "Datei", "Dateien")) zeigen Erstellt, Geändert und Hinzugefügt jetzt die Aufnahmezeit."
            if !outcome.failures.isEmpty {
                text += " Nicht geändert: " + outcome.failures.prefix(5).joined(separator: "; ") + (outcome.failures.count > 5 ? " …" : "")
            }
            text += " „Rückgängig“ stellt die alten Daten wieder her."
            messageView.show(symbol: outcome.failures.isEmpty ? "checkmark.circle" : "exclamationmark.triangle",
                             title: outcome.wasCancelled ? "Abgebrochen" : "Datum korrigiert", text: text,
                             buttonTitle: "Neu prüfen") { [weak self] in self?.check() }
        case .failed(let title, let message):
            messageView.isHidden = false
            messageView.show(symbol: "exclamationmark.triangle", title: title, text: message,
                             buttonTitle: "Erneut versuchen") { [weak self] in self?.check() }
        }
        tableView.reloadData()
        updateBottomBar(busy: busy)
    }

    private func updateBottomBar(busy: Bool) {
        let ready: Bool
        if case .ready = phase { ready = true } else { ready = false }
        let visible = ready || !undoStack.isEmpty
        bottomBar.isHidden = !visible
        bottomSeparator.isHidden = !visible
        guard visible else { return }

        summaryLabel.isHidden = !ready
        var parts = ["\(plural(plan.checkedCount, "Datei", "Dateien")) geprüft", "\(plan.toFix.count.formatted()) zu korrigieren"]
        if plan.correctCount > 0 { parts.append("\(plan.correctCount.formatted()) stimmen schon") }
        if !plan.withoutDate.isEmpty { parts.append("\(plan.withoutDate.count.formatted()) ohne Aufnahmezeit") }
        if plan.notDownloadedCount > 0 { parts.append("\(plan.notDownloadedCount.formatted()) nur in iCloud") }
        if !monthPlan.moves.isEmpty {
            parts.append("\(monthPlan.moves.count.formatted()) für \(monthFolderText(withArticle: false))")
        }
        if monthPlan.alreadyCopiedCount > 0 { parts.append("\(monthPlan.alreadyCopiedCount.formatted()) schon im Ziel") }
        summaryLabel.stringValue = parts.joined(separator: " · ")
        summaryLabel.toolTip = plan.withoutDate.isEmpty ? nil
            : "Ohne Aufnahmezeit:\n" + plan.withoutDate.prefix(20).map(relativePath).joined(separator: "\n") + (plan.withoutDate.count > 20 ? "\n…" : "")

        if let change = undoStack.last {
            undoLabel.stringValue = change.summary
            undoLabel.isHidden = false
            undoButton.isHidden = false
            undoButton.isEnabled = !busy
        } else {
            undoLabel.isHidden = true
            undoButton.isHidden = true
        }
        applyButton.isHidden = !ready
        applyButton.isEnabled = ready && !plan.toFix.isEmpty
        sortButton.isHidden = !ready
        sortButton.isEnabled = ready && !monthPlan.moves.isEmpty
        sortButton.title = monthPlan.copies ? "In Monatsordner kopieren …" : "In Monatsordner sortieren …"
    }

    /// Where files go: “(die) Monatsordner 01 bis 10”, “(den) Monatsordner 03 in „Urlaub““ or, across several
    /// folders, “14 Monatsordner in 2 Ordnern”. Paths relative to the folder or the copy destination.
    private func monthFolderText(withArticle: Bool) -> String {
        let bases = monthPlan.targetBases
        guard let base = bases.first else { return "Monatsordner" }
        if bases.count > 1 {
            return "\(monthPlan.monthFolderCount.formatted()) Monatsordner in \(bases.count.formatted()) Ordnern"
        }
        let names = monthPlan.folderNames
        var text = names.count == 1 ? "Monatsordner \(names[0])"
            : "Monatsordner \(names[0]) \(names.count == 2 ? "und" : "bis") \(names[names.count - 1])"
        if withArticle { text = (names.count == 1 ? "den " : "die ") + text }
        let root = monthPlan.destination?.path ?? folder?.path
        if base != root { text += " in „\(relativePath(base, to: root))“" }
        return text
    }

    private func relativePath(_ url: URL) -> String { relativePath(url.path) }

    private func relativePath(_ path: String) -> String { relativePath(path, to: folder?.path) }

    private func relativePath(_ path: String, to root: String?) -> String {
        guard let root, path.hasPrefix(root + "/") else { return (path as NSString).lastPathComponent }
        return String(path.dropFirst(root.count + 1))
    }

    // MARK: - Workflow

    @objc private func check() { runCheck(reusing: nil) }

    /// Checks the folder. With `existing` (destination changed), only the month folders are replanned –
    /// capture times have already been read.
    private func runCheck(reusing existing: DateFixer.Plan?) {
        guard let folder, !isBusy else { return }
        runID += 1
        let id = runID
        let recursive = includeSubfolders
        let destination = monthDestination
        phase = .checking
        progressView.update(ScanProgress(message: existing == nil ? "Suche Fotos und Videos …" : "Plane Monatsordner …"))
        render()
        let report: PhotoScanner.ProgressHandler = { [weak self] progress in
            Task { @MainActor in
                guard let self, id == self.runID else { return }
                self.progressView.update(progress)
            }
        }
        // Separate task so “Abbrechen” reaches the work (nested tasks don't inherit cancellation).
        let job = Task.detached(priority: .userInitiated) { () -> Result<DateFixCheck, Error> in
            do {
                let plan: DateFixer.Plan
                if let existing {
                    plan = existing
                } else {
                    plan = try await DateFixer.plan(folder: folder, recursive: recursive, progress: report)
                }
                let months = try await MonthSorter.plan(folder: folder, destination: destination, recursive: recursive,
                                                        knownDates: plan.captureDates, progress: report)
                return .success(DateFixCheck(plan: plan, months: months))
            } catch {
                return .failure(error)
            }
        }
        task = Task { [weak self] in
            let outcome = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            guard let self, id == self.runID else { return }
            switch outcome {
            case .success(let result):
                self.plan = result.plan
                self.monthPlan = result.months
                self.rows = result.rows
                self.phase = .ready
            case .failure(let error) where error is CancellationError:
                self.phase = .idle
            case .failure(let error):
                self.phase = .failed(title: "Prüfen nicht möglich", message: error.localizedDescription)
            }
            self.render()
        }
    }

    @objc private func confirmApply() {
        guard case .ready = phase, !plan.toFix.isEmpty, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Bei \(plural(plan.toFix.count, "Datei", "Dateien")) das Datum korrigieren?"
        var text = ["„Erstellt“, „Geändert“ und „Hinzugefügt“ werden auf die Aufnahmezeit aus den Metadaten gesetzt. Die Bilddaten bleiben unverändert."]
        if !plan.withoutDate.isEmpty { text.append("\(plural(plan.withoutDate.count, "Datei", "Dateien")) ohne Aufnahmezeit bleiben, wie sie sind.") }
        text.append("„Rückgängig“ stellt die alten Daten wieder her, solange PhotoHub geöffnet ist.")
        alert.informativeText = text.joined(separator: "\n")
        alert.addButton(withTitle: "Korrigieren")
        alert.addButton(withTitle: "Abbrechen")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.apply() }
        }
    }

    private func apply() {
        runID += 1
        let id = runID
        let plan = plan
        phase = .applying
        progressView.update(ScanProgress(message: "Korrigiere Datum …", done: 0, total: plan.toFix.count))
        render()
        let report: PhotoScanner.ProgressHandler = { [weak self] progress in
            Task { @MainActor in
                guard let self, id == self.runID else { return }
                self.progressView.update(progress)
            }
        }
        let job = Task.detached(priority: .userInitiated) { DateFixer.apply(plan, progress: report) }
        task = FileOperations.start { [weak self] in
            let outcome = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            guard let self else { return }
            if !outcome.changed.isEmpty { self.undoStack.append(.dates(outcome)) }
            self.phase = .done(.dates(outcome))
            self.render()
        }
    }

    @objc private func confirmSort() {
        guard case .ready = phase, !monthPlan.moves.isEmpty, let folder, let window = view.window else { return }
        let count = monthPlan.moves.count
        let alert = NSAlert()
        var text: [String]
        if let destination = monthPlan.destination {
            alert.messageText = "\(plural(count, "Datei", "Dateien")) in Monatsordner kopieren?"
            text = ["Die Fotos und Videos werden nach Aufnahmemonat nach „\(destination.lastPathComponent)“ kopiert, "
                    + "in \(monthFolderText(withArticle: true)) – mit denselben Unterordnern wie in „\(folder.lastPathComponent)“. "
                    + "Das Original bleibt unverändert."]
        } else {
            alert.messageText = "\(plural(count, "Datei", "Dateien")) in Monatsordner sortieren?"
            text = [monthPlan.targetBases == [folder.path]
                ? "Die Fotos und Videos direkt in „\(folder.lastPathComponent)“ kommen nach Aufnahmemonat in \(monthFolderText(withArticle: true))."
                : "Die Fotos und Videos kommen nach Aufnahmemonat in \(monthFolderText(withArticle: true)) – jeweils in dem Ordner, in dem sie liegen."]
        }
        if monthPlan.usesYearFolders {
            text[0] += " Wo sonst Jahre gemischt würden, steht das Jahr davor (2025/12)."
        }
        if monthPlan.alreadyCopiedCount > 0 {
            text.append("Schon im Ziel, werden übersprungen: \(plural(monthPlan.alreadyCopiedCount, "Datei", "Dateien")).")
        }
        let fileDates = monthPlan.fileDateCount
        if fileDates > 0 { text.append("Ohne Aufnahmezeit, nach Änderungsdatum: \(plural(fileDates, "Datei", "Dateien")).") }
        let renamed = monthPlan.renameCount
        if renamed > 0 { text.append("Mit Zusatz „_1“, weil der Name schon vergeben ist: \(plural(renamed, "Datei", "Dateien")).") }
        if monthPlan.copies {
            text.append((includeSubfolders ? "Was schon in Ordnern 01 bis 12 liegt, wird nicht kopiert. " : "")
                        + "Die Dateidaten bleiben erhalten. „Rückgängig“ legt die Kopien in den Papierkorb, solange PhotoHub geöffnet ist.")
        } else {
            text.append((includeSubfolders ? "Was schon in Ordnern 01 bis 12 liegt, bleibt dort, andere Dateien ebenso. "
                         : "Unterordner und andere Dateien bleiben, wo sie sind. ") + "Die Dateidaten bleiben erhalten. "
                        + "„Rückgängig“ verschiebt alles zurück, solange PhotoHub geöffnet ist.")
        }
        alert.informativeText = text.joined(separator: "\n")
        alert.addButton(withTitle: monthPlan.copies ? "Kopieren" : "Sortieren")
        alert.addButton(withTitle: "Abbrechen")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.sort() }
        }
    }

    private func sort() {
        runID += 1
        let id = runID
        let plan = monthPlan
        phase = .applying
        progressView.update(ScanProgress(message: plan.copies ? "Kopiere in Monatsordner …" : "Sortiere in Monatsordner …",
                                         done: 0, total: plan.moves.count))
        render()
        let report: PhotoScanner.ProgressHandler = { [weak self] progress in
            Task { @MainActor in
                guard let self, id == self.runID else { return }
                self.progressView.update(progress)
            }
        }
        let job = Task.detached(priority: .userInitiated) { Result { try MonthSorter.apply(plan, progress: report) } }
        task = FileOperations.start { [weak self] in
            let result = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            guard let self else { return }
            switch result {
            case .success(let outcome):
                if !outcome.moved.isEmpty { self.undoStack.append(.months(outcome)) }
                self.phase = .done(.months(outcome))
            case .failure(let error):
                self.phase = .failed(title: plan.copies ? "Kopieren nicht möglich" : "Sortieren nicht möglich",
                                     message: error.localizedDescription)
            }
            self.render()
        }
    }

    @objc private func cancel() {
        guard isBusy else { return }
        task?.cancel()
    }

    @objc private func undo() {
        guard !isBusy, let change = undoStack.popLast() else { return }
        // Busy until done, so nothing else starts on the half-restored folder.
        phase = .applying
        progressView.update(ScanProgress(message: "Mache rückgängig …"))
        // Undo always runs to the end.
        progressView.cancelButton.isHidden = true
        render()
        task = FileOperations.start { [weak self] in
            let failures = await Task.detached(priority: .userInitiated) { change.undo() }.value
            guard let self else { return }
            self.progressView.cancelButton.isHidden = false
            self.phase = .idle
            self.render()
            self.check()
            if !failures.isEmpty, let window = self.view.window {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Hinweis"
                let problem: String
                switch change {
                case .months(let outcome): problem = outcome.copies ? "ließ sich die Kopie nicht in den Papierkorb legen" : "ließ sich nicht zurückverschieben"
                case .dates: problem = "ließ sich das alte Datum nicht wiederherstellen"
                }
                alert.informativeText = "Bei \(plural(failures.count, "Datei", "Dateien")) \(problem):\n\n" + failures.prefix(8).joined(separator: "\n")
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }

    // MARK: - Folder

    private func setFolder(_ url: URL) {
        guard !isBusy else { return }
        folder = url.standardizedFileURL
        defaults.set(folder?.path, forKey: Keys.folder)
        view.window?.subtitle = url.lastPathComponent
        undoStack = []
        check()
    }

    @objc private func chooseFolder() {
        guard let window = view.window, !isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Auswählen"
        panel.message = "Wähle den Ordner, dessen Fotos und Videos das Datum der Aufnahme bekommen sollen"
        panel.directoryURL = folder ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.setFolder(url)
        }
    }

    @objc private func subfoldersChanged() {
        includeSubfolders = subfolderCheckbox.state == .on
        defaults.set(includeSubfolders, forKey: Keys.subfolders)
        if folder != nil { check() }
    }

    @objc private func revealFolder() {
        if let folder { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
    }

    // MARK: - Copy destination

    private func setDestination(_ url: URL?) {
        guard !isBusy else { return }
        monthDestination = url?.standardizedFileURL
        defaults.set(monthDestination?.path, forKey: Keys.monthDestination)
        // Capture times are already known – only replan the month folders.
        if case .ready = phase { runCheck(reusing: plan) } else { render() }
    }

    @objc private func chooseDestination() {
        guard let window = view.window, !isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Auswählen"
        panel.message = "Wähle den Ordner, in den die Monatsordner kopiert werden – das Original bleibt unverändert"
        panel.directoryURL = monthDestination ?? folder?.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.setDestination(url)
        }
    }

    @objc private func clearDestination() {
        setDestination(nil)
    }

    @objc private func revealDestination() {
        if let monthDestination { NSWorkspace.shared.activateFileViewerSelecting([monthDestination]) }
    }

    @objc private func revealRow() {
        guard rows.indices.contains(tableView.clickedRow) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([rows[tableView.clickedRow].url])
    }
}

// MARK: - Table

extension DateFixViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        if case .ready = phase { return rows.count }
        return 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier else { return nil }
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeCell(id)
        let field = cell.textField!
        let item = rows[row]
        // Mismatching dates in orange, matching ones in grey.
        func show(_ date: Date?) {
            field.stringValue = date.map(dateFormatter.string) ?? "–"
            let matches = date.flatMap { date in item.captureDate.map { abs(date.timeIntervalSince($0)) < 1 } } ?? true
            field.textColor = matches ? Darcula.muted : Darcula.warn
        }
        switch id.rawValue {
        case "file":
            field.stringValue = relativePath(item.path)
            field.textColor = Darcula.text
            field.toolTip = item.path
        case "capture":
            field.stringValue = item.captureDate.map(dateFormatter.string) ?? "–"
            field.textColor = item.captureDate == nil ? Darcula.muted : Darcula.text
        case "month":
            if let move = item.move {
                field.stringValue = (move.isRenamed ? move.relativeTarget : move.folderName) + (move.usesFileDate ? " · Dateidatum" : "")
                field.textColor = Darcula.text
                let target = relativePath(move.targetPath, to: monthPlan.destination?.path ?? folder?.path)
                var tip = [monthPlan.destination.map { "Kopie nach: „\($0.lastPathComponent)“/\(target)" } ?? "Ziel: \(target)"]
                if move.usesFileDate { tip.append("Ohne Aufnahmezeit – einsortiert nach dem Änderungsdatum") }
                if move.isRenamed { tip.append("Der Name ist im Monatsordner schon vergeben") }
                field.toolTip = tip.joined(separator: "\n")
            } else {
                field.stringValue = "–"
                field.textColor = Darcula.muted
                let inMonthFolder = relativePath(item.path).split(separator: "/").dropLast()
                    .contains { $0.count == 2 && Int($0).map { (1...12).contains($0) } == true }
                field.toolTip = inMonthFolder ? "Liegt schon in einem Monatsordner" : nil
            }
        case "created": show(item.current.created)
        case "modified": show(item.current.modified)
        case "added": show(item.current.added)
        default: field.stringValue = ""
        }
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = DarculaTableCell()
        cell.identifier = id
        let field = TableLabel(labelWithString: "")
        field.textColor = Darcula.text
        field.lineBreakMode = id.rawValue == "file" ? .byTruncatingHead : .byTruncatingTail
        field.font = id.rawValue == "file" ? .systemFont(ofSize: NSFont.systemFontSize) : .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
        ])
        return cell
    }
}
