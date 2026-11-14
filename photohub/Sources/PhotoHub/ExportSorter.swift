import Foundation

/// Copies day folders exported from Apple Photos (“1. August 2026”) into a year/month structure
/// (`destination/2026/08`). Modelled on the `organize_photos.py` script, which moves files; here the export stays
/// unchanged by default so everything can be redone. Optionally moves like the script, removing emptied day folders.
/// - Files already copied are recognised (same name and content), also under `Name_1`.
/// - Files sharing a name (Live Photo: HEIC + MOV) get the same `_1` suffix on conflicts.
/// - Capture time is read without exiftool (`CaptureDate`: ImageIO or AVFoundation, with time zone).
/// - Undo moves the copies to the Trash or moves everything back into the export.
enum ExportSorter {
    struct Plan: Sendable {
        var folders: [FolderPlan] = []
        /// Subfolders whose name is not a date – left untouched.
        var unrecognized: [URL] = []

        var fileCount: Int { folders.reduce(0) { $0 + $1.copies.count + $1.alreadyCopied.count } }
        var copyCount: Int { folders.reduce(0) { $0 + $1.copies.count } }
        var copyBytes: Int64 { folders.reduce(0) { $0 + $1.copies.reduce(0) { $0 + $1.size } } }
        var renameCount: Int { folders.reduce(0) { $0 + $1.renamedCount } }
        var alreadyCopiedCount: Int { folders.reduce(0) { $0 + $1.alreadyCopied.count } }
        var isEmpty: Bool { folders.isEmpty && unrecognized.isEmpty }
    }

    struct FolderPlan: Sendable {
        let source: URL
        let year: Int
        let month: Int
        let day: Int
        let target: URL
        var copies: [Copy] = []
        /// Already in the destination with the same name (possibly `_1` …) and content – skipped.
        var alreadyCopied: [URL] = []

        var targetName: String { String(format: "%04d/%02d", year, month) }
        var renamedCount: Int { copies.filter(\.isRenamed).count }
    }

    struct Copy: Sendable {
        let source: URL
        /// Text instead of URL: `URL` stores umlauts decomposed (NFD), but the name must stay byte-identical.
        let targetPath: String
        let size: Int64
        var target: URL { URL(fileURLWithPath: targetPath) }
        var isRenamed: Bool { exactName(source) != (targetPath as NSString).lastPathComponent }
    }

    /// What copying or moving created – enough to undo it.
    struct Outcome: Sendable {
        struct Move: Sendable {
            let sourcePath: String
            let targetPath: String
            /// Dates in the export beforehand – restored by `undo`.
            let dates: FileDates
        }
        var movesFiles = false
        /// The new files in the destination.
        var transferred: [URL] = []
        /// Only when moving: where each file came from.
        var moved: [Move] = []
        struct RemovedFolder: Sendable {
            let path: String
            let dates: FileDates
        }
        /// Day folders emptied and removed by moving, with their dates for `undo`.
        var removedFolders: [RemovedFolder] = []
        var createdDirectories: [URL] = []
        /// Modification dates of the touched folders beforehand – adding and removing files changes them.
        var folderDates: [URL: Date] = [:]
        var renamedCount = 0
        var alreadyCopiedCount = 0
        var datesSet = 0
        var datesMissing = 0
        var failures: [String] = []
        var wasCancelled = false
    }

    enum SortError: LocalizedError {
        case destinationInsideExport(String)
        case notEnoughSpace(needed: Int64, available: Int64)

        var errorDescription: String? {
            switch self {
            case .destinationInsideExport(let folder):
                return "Der Zielordner liegt im Tagesordner „\(folder)“ des Exports. Wähle einen Zielordner außerhalb davon."
            case .notEnoughSpace(let needed, let available):
                return "Im Ziel ist nicht genug Platz: Die Kopien brauchen \(needed.formattedBytes), frei sind \(available.formattedBytes)."
            }
        }
    }

    // MARK: - Folder names

    private static let months = [
        "januar": 1, "februar": 2, "märz": 3, "maerz": 3, "april": 4, "mai": 5, "juni": 6,
        "juli": 7, "august": 8, "september": 9, "oktober": 10, "november": 11, "dezember": 12,
    ]
    private static let folderPattern = try! NSRegularExpression(pattern: #"^\s*(\d{1,2})\.\s+([A-Za-zÄÖÜäöüß]+)\s+(\d{4})\s*$"#)
    private static let ignoredFiles: Set<String> = [".DS_Store"]

    /// “1. August 2026” → 2026, 8, 1. German month names only, like the script.
    static func parseDateFolder(_ name: String) -> (year: Int, month: Int, day: Int)? {
        // Umlauts may be stored decomposed (“a” + diaeresis) – compose before comparing.
        let name = name.precomposedStringWithCanonicalMapping
        let range = NSRange(name.startIndex..., in: name)
        guard let match = folderPattern.firstMatch(in: name, range: range),
              let day = Range(match.range(at: 1), in: name).flatMap({ Int(name[$0]) }),
              let monthName = Range(match.range(at: 2), in: name).map({ name[$0].lowercased() }),
              let month = months[monthName],
              let year = Range(match.range(at: 3), in: name).flatMap({ Int(name[$0]) }) else { return nil }
        return (year, month, day)
    }

    // MARK: - Preview

    /// Plans the copy without changing anything.
    static func plan(source: URL, destination: URL) throws -> Plan {
        let fileManager = FileManager.default
        let entries = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        var plan = Plan()
        var dated: [(url: URL, date: (year: Int, month: Int, day: Int))] = []
        for url in entries where (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            if let date = parseDateFolder(url.lastPathComponent) {
                dated.append((url, date))
            } else {
                plan.unrecognized.append(url)
            }
        }
        let destinationPath = destination.standardizedFileURL.path + "/"
        if let folder = dated.first(where: { destinationPath.hasPrefix($0.url.standardizedFileURL.path + "/") }) {
            throw SortError.destinationInsideExport(folder.url.lastPathComponent)
        }
        dated.sort { ($0.date.year, $0.date.month, $0.date.day, $0.url.lastPathComponent) < ($1.date.year, $1.date.month, $1.date.day, $1.url.lastPathComponent) }
        plan.unrecognized.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        // Destinations already claimed in this run (case-insensitive, like APFS) → source file.
        var claimed: [String: URL] = [:]
        func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }
        enum Slot { case free, same, taken }
        func slot(for file: URL, at path: String) -> Slot {
            if let other = claimed[key(path)] { return sameContent(file, other) ? .same : .taken }
            guard fileManager.fileExists(atPath: path) else { return .free }
            return sameContent(file, URL(fileURLWithPath: path)) ? .same : .taken
        }

        for (folder, date) in dated {
            if Task.isCancelled { throw CancellationError() }
            let target = destination.appendingPathComponent(String(format: "%04d", date.year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", date.month), isDirectory: true)
            var folderPlan = FolderPlan(source: folder, year: date.year, month: date.month, day: date.day, target: target)
            let files = try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
                .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true && !ignoredFiles.contains($0.lastPathComponent) }
            // Files sharing a name with different extensions (Live Photo, RAW+JPEG, .AAE) end up under one name: the
            // first of “IMG_1”, “IMG_1_1”, … where no file with different content exists. Files with identical content
            // there come from an earlier run and are skipped.
            let groups = Dictionary(grouping: files) { $0.deletingPathExtension().lastPathComponent.lowercased() }
            for stem in groups.keys.sorted() {
                let members = groups[stem]!.sorted { $0.lastPathComponent < $1.lastPathComponent }
                func path(_ file: URL, _ suffix: Int) -> String { target.path + "/" + renamed(exactName(file), suffix) }
                var suffix = 0
                var slots: [Slot] = []
                while true {
                    slots = members.map { slot(for: $0, at: path($0, suffix)) }
                    if !slots.contains(.taken) { break }
                    suffix += 1
                }
                for (file, slot) in zip(members, slots) {
                    if slot == .same {
                        folderPlan.alreadyCopied.append(file)
                        continue
                    }
                    let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                    let copy = Copy(source: file, targetPath: path(file, suffix), size: size)
                    claimed[key(copy.targetPath)] = file
                    folderPlan.copies.append(copy)
                }
            }
            folderPlan.copies.sort { $0.source.lastPathComponent.localizedStandardCompare($1.source.lastPathComponent) == .orderedAscending }
            if !folderPlan.copies.isEmpty || !folderPlan.alreadyCopied.isEmpty { plan.folders.append(folderPlan) }
        }
        return plan
    }

    /// File name as stored on disk (`URL.lastPathComponent` may decompose umlauts).
    fileprivate static func exactName(_ url: URL) -> String { (url.path as NSString).lastPathComponent }

    /// “IMG_1.HEIC” → “IMG_1_2.HEIC” (like the script); 0 = unchanged.
    static func renamed(_ name: String, _ suffix: Int) -> String {
        guard suffix > 0 else { return name }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        return ext.isEmpty ? "\(stem)_\(suffix)" : "\(stem)_\(suffix).\(ext)"
    }

    /// Same size and same first and last 64 KB. Reads at most 128 KB per file because the preview runs on every
    /// tab switch, including large videos. Different shots already differ in their leading metadata; a false match
    /// only means a file is not copied – the export remains.
    static func sameContent(_ a: URL, _ b: URL) -> Bool {
        let sizeA = (try? a.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        let sizeB = (try? b.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        guard let sizeA, sizeA == sizeB, let edgesA = edges(of: a, size: sizeA), let edgesB = edges(of: b, size: sizeA) else { return false }
        return edgesA == edgesB
    }

    private static func edges(of url: URL, size: Int) -> Data? {
        let chunk = 64 * 1024
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard size > 2 * chunk else { return try? handle.readToEnd() ?? Data() }
        guard var data = try? handle.read(upToCount: chunk), (try? handle.seek(toOffset: UInt64(size - chunk))) != nil,
              let tail = try? handle.read(upToCount: chunk) else { return nil }
        data.append(tail)
        return data
    }

    // MARK: - Copying

    /// Replans (in case something changed since the preview), then copies or moves. On cancellation the work done
    /// so far stays and can be undone as well.
    static func apply(source: URL, destination: URL, setCaptureDates: Bool, moveFiles: Bool,
                      progress: @escaping PhotoScanner.ProgressHandler) async throws -> Outcome {
        let fileManager = FileManager.default
        let plan = try plan(source: source, destination: destination)
        try checkSpace(for: plan, source: source, destination: destination, moveFiles: moveFiles)
        var outcome = Outcome()
        outcome.movesFiles = moveFiles
        outcome.alreadyCopiedCount = plan.alreadyCopiedCount
        let total = plan.copyCount
        let message = moveFiles ? "Verschiebe …" : "Kopiere …"
        var done = 0
        progress(ScanProgress(message: message, done: 0, total: total))

        func remember(_ folder: URL) {
            guard outcome.folderDates[folder] == nil,
                  let date = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return }
            outcome.folderDates[folder] = date
        }
        remember(destination)
        if moveFiles { remember(source) }

        folders: for folder in plan.folders where !folder.copies.isEmpty {
            for directory in [folder.target.deletingLastPathComponent(), folder.target] { remember(directory) }
            if moveFiles { remember(folder.source) }
            for directory in [folder.target.deletingLastPathComponent(), folder.target] where !fileManager.fileExists(atPath: directory.path) {
                do {
                    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                    outcome.createdDirectories.append(directory)
                } catch {
                    outcome.failures.append("\(directory.path): \(error.localizedDescription)")
                    continue folders
                }
            }
            for copy in folder.copies {
                if Task.isCancelled {
                    outcome.wasCancelled = true
                    break folders
                }
                // If the destination has been taken meanwhile, number it like a conflict.
                let directory = (copy.targetPath as NSString).deletingLastPathComponent
                let name = (copy.targetPath as NSString).lastPathComponent
                var targetPath = copy.targetPath
                var suffix = 0
                while fileManager.fileExists(atPath: targetPath) {
                    suffix += 1
                    targetPath = directory + "/" + renamed(name, suffix)
                }
                let previous = moveFiles ? FileDates.read(copy.source) : nil
                do {
                    if moveFiles {
                        try FileMove.move(atPath: copy.source.path, toPath: targetPath)
                    } else {
                        try copyItem(copy.source, toPath: targetPath)
                    }
                } catch {
                    outcome.failures.append("\(copy.source.lastPathComponent): \(error.localizedDescription)")
                    continue
                }
                if let previous {
                    // In the new folder “date added” would otherwise be now – restore the export's dates; capture time may follow.
                    FileDates.write(previous, toPath: targetPath)
                    outcome.moved.append(.init(sourcePath: copy.source.path, targetPath: targetPath, dates: previous))
                }
                let target = URL(fileURLWithPath: targetPath)
                outcome.transferred.append(target)
                if (targetPath as NSString).lastPathComponent != exactName(copy.source) { outcome.renamedCount += 1 }
                if setCaptureDates {
                    if let date = await CaptureDate.read(target) {
                        FileDates.write(.all(date), toPath: targetPath)
                        outcome.datesSet += 1
                    } else {
                        // Without a capture time keep the original's date, so “date added” follows instead of showing now.
                        if let modified = FileDates.read(target).modified { FileDates.write(FileDates(added: modified), toPath: targetPath) }
                        outcome.datesMissing += 1
                    }
                }
                done += 1
                if done % 20 == 0 || done == total { progress(ScanProgress(message: message, done: done, total: total)) }
            }
            // Like the script: remove an emptied day folder (`rmdir` fails while anything is left).
            if moveFiles {
                let dates = FileDates.read(folder.source)
                if rmdir(folder.source.path) == 0 { outcome.removedFolders.append(.init(path: folder.source.path, dates: dates)) }
            }
        }
        return outcome
    }

    /// Undoes a copy (copies to the Trash) or a move (everything back into the export, removed day folders
    /// recreated). Then removes newly created folders that are empty again and restores folder modification dates.
    /// Returns what failed.
    static func undo(_ outcome: Outcome) -> [String] {
        let fileManager = FileManager.default
        var failures: [String] = []
        if outcome.movesFiles {
            for folder in outcome.removedFolders { mkdir(folder.path, 0o777) }
            for move in outcome.moved.reversed() {
                do {
                    try FileMove.move(atPath: move.targetPath, toPath: move.sourcePath)
                    FileDates.write(move.dates, toPath: move.sourcePath)
                } catch {
                    failures.append("\((move.sourcePath as NSString).lastPathComponent): \(error.localizedDescription)")
                }
            }
            // Created and added dates of the recreated folders; modification dates follow below from `folderDates`.
            for folder in outcome.removedFolders { FileDates.write(folder.dates, toPath: folder.path) }
        } else {
            failures = FileTrash.moveToTrash(outcome.transferred.filter { fileManager.fileExists(atPath: $0.path) }).failed
        }
        for directory in outcome.createdDirectories.reversed() where (try? fileManager.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
            try? fileManager.removeItem(at: directory)
        }
        for (folder, date) in outcome.folderDates {
            try? fileManager.setAttributes([.modificationDate: date], ofItemAtPath: folder.path)
        }
        return failures
    }

    /// Copies like `cp -c`: a clone on APFS (instant, no extra space until one side changes), otherwise a full
    /// copy, with timestamps and metadata. The destination path is text so the name stays byte-identical.
    /// Never overwrites.
    private static func copyItem(_ source: URL, toPath target: String) throws {
        guard copyfile(source.path, target, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_CLONE)) == 0 else {
            let code = errno
            // Remove the partial copy – it is ours for sure (COPYFILE_EXCL).
            if code != EEXIST { try? FileManager.default.removeItem(atPath: target) }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// Files must fit into the free space on another volume (or, when copying, without clone support).
    /// Moving on the same volume is just a rename.
    private static func checkSpace(for plan: Plan, source: URL, destination: URL, moveFiles: Bool) throws {
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey, .volumeSupportsFileCloningKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let target = try? destination.resourceValues(forKeys: keys),
              let available = target.volumeAvailableCapacityForImportantUsage else { return }
        let sourceVolume = (try? source.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
        let sameVolume = sourceVolume != nil && (sourceVolume as? NSObject)?.isEqual(target.volumeIdentifier) == true
        guard !(sameVolume && (moveFiles || target.volumeSupportsFileCloning == true)) else { return }
        let needed = plan.copyBytes
        if needed > available { throw SortError.notEnoughSpace(needed: needed, available: available) }
    }
}
