import Foundation
import UniformTypeIdentifiers

/// Distributes photos and videos into month subfolders `01` … `12` by capture month (tab “Bilder-Datum
/// korrigieren”): the files directly in the folder and, optionally, those of each subfolder, each into month
/// folders in their own folder. Without a destination, files move within the folder; with one, they are copied
/// into the same subfolders there and the original stays unchanged.
/// If the images span several years, the year comes first (`2025/03`) – two years never end up in the same month
/// folder, not even in a later run (see `plan`).
/// - Month: capture time as in the export sorter (`CaptureDate`), otherwise the file's modification date.
/// - Files sharing a name (Live Photo, RAW+JPEG, .AAE/.XMP) move together, by the photo's date.
/// - Folders `01` … `12` count as sorted and stay as they are, as do other files. Taken names in a month folder
///   are numbered like in the export sorter (`IMG_1_1.HEIC`), never overwritten. When copying, a file with the
///   same name and content counts as already copied.
/// - Created, modified and added dates are kept. `undo` moves everything back or moves the copies to the Trash.
enum MonthSorter {
    struct Move: Sendable {
        /// Paths as text – `URL` decomposes umlauts; names must stay byte-identical.
        let sourcePath: String
        let targetPath: String
        /// Folder containing the file.
        let directory: String
        /// Folder that gets the month folders: `directory` itself or its counterpart in the destination.
        let targetBase: String
        /// Month folder below `targetBase`: “03” or “2025/03”.
        let folderName: String
        /// No capture time: sorted by modification date.
        let usesFileDate: Bool
        let size: Int64

        var name: String { (sourcePath as NSString).lastPathComponent }
        var targetName: String { (targetPath as NSString).lastPathComponent }
        /// Destination below `targetBase`: “03/IMG_1.jpg”.
        var relativeTarget: String { folderName + "/" + targetName }
        var isRenamed: Bool { name != targetName }
    }

    struct Plan: Sendable {
        var moves: [Move] = []
        var source: URL?
        /// Destination for copies – nil means move within the folder itself.
        var destination: URL?
        /// Copying only: already in the destination with the same name (possibly `_1` …) and content.
        var alreadyCopiedCount = 0
        /// Year/month instead of month in at least one folder: several years, or month folders of another year or year
        /// folders with month folders already exist there.
        var usesYearFolders = false
        /// Only in iCloud, not on this Mac – left in place.
        var notDownloadedCount = 0

        var copies: Bool { destination != nil }
        var copyBytes: Int64 { moves.reduce(0) { $0 + $1.size } }
        /// Month folders below their folder, sorted: “01”, “02”, … or “2025/12”, “2026/01”, …
        var folderNames: [String] { Set(moves.map(\.folderName)).sorted() }
        /// Folders that get month folders (in the folder itself or in the destination).
        var targetBases: [String] { Set(moves.map(\.targetBase)).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
        var monthFolderCount: Int { Set(moves.map { $0.targetBase + "/" + $0.folderName }).count }
        var fileDateCount: Int { moves.filter(\.usesFileDate).count }
        var renameCount: Int { moves.filter(\.isRenamed).count }
    }

    typealias Outcome = FileMove.Batch

    enum SortError: LocalizedError {
        case overlapping
        case notEnoughSpace(needed: Int64, available: Int64)

        var errorDescription: String? {
            switch self {
            case .overlapping:
                return "Der Zielordner für die Kopien muss außerhalb des Ordners liegen – und der Ordner nicht im Zielordner."
            case .notEnoughSpace(let needed, let available):
                return "Im Zielordner ist nicht genug Platz: Die Kopien brauchen \(needed.formattedBytes), frei sind \(available.formattedBytes)."
            }
        }
    }

    /// Sidecar files without an image type – they follow the photo with the same name.
    private static let sidecarExtensions: Set<String> = ["aae", "xmp"]
    /// This many files per existing month folder are enough to tell its year.
    private static let sampleSize = 20

    private struct Entry: Sendable {
        let path: String
        let isMedia: Bool
        let isMovie: Bool
        /// Modification date, else creation date – for files without a capture time.
        let fileDate: Date?
        let size: Int64
        var name: String { (path as NSString).lastPathComponent }
        var stem: String { (name as NSString).deletingPathExtension.precomposedStringWithCanonicalMapping.lowercased() }
    }

    // MARK: - Preview

    /// Plans the sort without changing anything: the folder itself and, with `recursive`, every subfolder that is
    /// not a month folder. With `destination` the month folders go there, in the same subfolder as in the folder.
    /// `knownDates` are capture times already read by “Prüfen” (path → date, nil = none); missing ones are read.
    static func plan(folder: URL, destination: URL? = nil, recursive: Bool = true, knownDates: [String: Date?] = [:],
                     progress: @escaping PhotoScanner.ProgressHandler) async throws -> Plan {
        if let destination {
            func normalized(_ url: URL) -> String {
                url.standardizedFileURL.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping.lowercased()
            }
            func contains(_ outer: String, _ inner: String) -> Bool { (inner + "/").hasPrefix(outer + "/") }
            let source = normalized(folder), target = normalized(destination)
            if contains(source, target) || contains(target, source) { throw SortError.overlapping }
        }
        var plan = Plan()
        plan.source = folder
        plan.destination = destination
        progress(ScanProgress(message: "Plane Monatsordner …"))
        let directories = [folder.path] + (recursive ? try subdirectories(of: folder) : [])
        var contents: [(directory: String, files: [Entry])] = []
        for directory in directories {
            try Task.checkCancellation()
            contents.append((directory, try entries(in: directory, notDownloaded: &plan.notDownloadedCount)))
        }
        var dates = knownDates
        let unknown = contents.flatMap(\.files).filter { $0.isMedia && dates.index(forKey: $0.path) == nil }.map { URL(fileURLWithPath: $0.path) }
        for (url, date) in try await DateFixer.readCaptureDates(unknown, progress: progress) { dates.updateValue(date, forKey: url.path) }

        // Destinations already claimed in this run (case-insensitive, like APFS) – across all folders, because
        // `2026/03` in the folder and loose files in a subfolder `2026` end up in the same month folder.
        var claimed = Set<String>()
        for (directory, files) in contents {
            var base = directory
            if let destination {
                let relative = relativePath(directory, root: folder.path)
                base = relative.isEmpty ? destination.path : destination.path + "/" + relative
            }
            try await planDirectory(directory, base: base, files: files, dates: dates, claimed: &claimed, plan: &plan, progress: progress)
        }
        plan.moves.sort {
            if $0.directory != $1.directory { return $0.directory.localizedStandardCompare($1.directory) == .orderedAscending }
            if $0.folderName != $1.folderName { return $0.folderName < $1.folderName }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return plan
    }

    /// Month folders in `base` for the files directly in `directory`.
    private static func planDirectory(_ directory: String, base: String, files: [Entry], dates: [String: Date?],
                                      claimed: inout Set<String>, plan: inout Plan,
                                      progress: @escaping PhotoScanner.ProgressHandler) async throws {
        // Name groups get the photo's date, else the video's, else the oldest file date.
        // A sidecar without a photo or video stays in place.
        struct Group {
            let members: [Entry]
            let year: Int
            let month: Int
            let usesFileDate: Bool
        }
        let calendar = Calendar.current
        var groups: [Group] = []
        for (_, members) in Dictionary(grouping: files, by: \.stem).sorted(by: { $0.key < $1.key }) {
            let media = members.filter(\.isMedia).sorted { ($0.isMovie ? 1 : 0, $0.name) < ($1.isMovie ? 1 : 0, $1.name) }
            let capture = media.lazy.compactMap { dates[$0.path] ?? nil }.first
            guard let date = capture ?? media.compactMap(\.fileDate).min() else { continue }
            let parts = calendar.dateComponents([.year, .month], from: date)
            guard let year = parts.year, let month = parts.month else { continue }
            groups.append(Group(members: members.sorted { $0.name < $1.name }, year: year, month: month, usesFileDate: capture == nil))
        }
        guard !groups.isEmpty else { return }

        // Month only, as long as no month folder ends up with two years – including folders from an earlier run.
        let years = Set(groups.map(\.year))
        let subfolders = subfolderNames(of: base)
        let monthFolders = subfolders.filter(isMonthName).map { base + "/" + $0 }
        let existingYears = try await yearsInMonthFolders(monthFolders, dates: dates, progress: progress)
        let hasYearFolders = subfolders.contains { name in isYearName(name) && subfolderNames(of: base + "/" + name).contains(where: isMonthName) }
        let usesYearFolders = years.count > 1 || !existingYears.isSubset(of: years) || (monthFolders.isEmpty && hasYearFolders)
        if usesYearFolders { plan.usesYearFolders = true }

        // First suffix (“”, “_1”, …) where no file of the group hits another one. When copying, a file with the same
        // content counts as already copied, so a second run copies nothing twice.
        enum Slot { case free, same, taken }
        let fileManager = FileManager.default
        let copies = plan.copies
        func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }
        func slot(_ member: Entry, _ path: String) -> Slot {
            if claimed.contains(key(path)) { return .taken }
            guard fileManager.fileExists(atPath: path) else { return .free }
            return copies && ExportSorter.sameContent(URL(fileURLWithPath: member.path), URL(fileURLWithPath: path)) ? .same : .taken
        }
        for group in groups {
            let folderName = usesYearFolders ? String(format: "%04d/%02d", group.year, group.month) : String(format: "%02d", group.month)
            let target = base + "/" + folderName
            func path(_ member: Entry, _ suffix: Int) -> String { target + "/" + ExportSorter.renamed(member.name, suffix) }
            var suffix = 0
            var slots: [Slot] = []
            while true {
                slots = group.members.map { slot($0, path($0, suffix)) }
                if !slots.contains(.taken) { break }
                suffix += 1
            }
            for (member, slot) in zip(group.members, slots) {
                if slot == .same {
                    plan.alreadyCopiedCount += 1
                    continue
                }
                let targetPath = path(member, suffix)
                claimed.insert(key(targetPath))
                plan.moves.append(Move(sourcePath: member.path, targetPath: targetPath, directory: directory, targetBase: base,
                                       folderName: folderName, usesFileDate: group.usesFileDate, size: member.size))
            }
        }
    }

    /// All subfolders that can get month folders. Skipped along with their contents: month folders (already
    /// sorted), hidden folders, packages (Photos library) and NAS thumbnail folders.
    private static func subdirectories(of folder: URL) throws -> [String] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                              errorHandler: { _, _ in true }) else {
            throw ScanError.folderNotReadable(folder)
        }
        var result: [String] = []
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isDirectory == true else { continue }
            let name = (url.path as NSString).lastPathComponent
            if isMonthName(name) || PhotoScanner.ignoredFolders.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            if values.isPackage != true { result.append(url.path) }
        }
        return result
    }

    /// Names of visible subfolders (no packages); empty if the folder doesn't exist.
    private static func subfolderNames(of path: String) -> [String] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path, isDirectory: true),
                                                                 includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isDirectory == true, values.isPackage != true else { return nil }
            return (url.path as NSString).lastPathComponent
        }
    }

    /// “/A/2020/Urlaub” under “/A” → “2020/Urlaub”, character for character as on disk; the folder itself → “”.
    private static func relativePath(_ path: String, root: String) -> String {
        if path == root { return "" }
        if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        let components = (path as NSString).pathComponents.dropFirst((root as NSString).pathComponents.count)
        return components.joined(separator: "/")
    }

    /// “01” … “12”
    private static func isMonthName(_ name: String) -> Bool {
        name.count == 2 && name.allSatisfy(\.isASCII) && Int(name).map { (1...12).contains($0) } == true
    }

    /// “1900” … “2999”
    private static func isYearName(_ name: String) -> Bool {
        name.count == 4 && name.allSatisfy(\.isASCII) && Int(name).map { (1900...2999).contains($0) } == true
    }

    /// Files directly in the folder that can be sorted: photos, videos, sidecars. Hidden files and iCloud files
    /// that are not downloaded are left out.
    private static func entries(in folder: String, notDownloaded: inout Int) throws -> [Entry] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentTypeKey, .fileSizeKey,
                                      .contentModificationDateKey, .creationDateKey, .ubiquitousItemDownloadingStatusKey]
        let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder, isDirectory: true),
                                                               includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        var files: [Entry] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let type = values.contentType
            let isMovie = type?.conforms(to: .audiovisualContent) == true
            let isMedia = isMovie || type?.conforms(to: .image) == true
            guard isMedia || sidecarExtensions.contains(url.pathExtension.lowercased()) else { continue }
            if let status = values.ubiquitousItemDownloadingStatus, status != .current {
                notDownloaded += 1
                continue
            }
            files.append(Entry(path: url.path, isMedia: isMedia, isMovie: isMovie,
                               fileDate: values.contentModificationDate ?? values.creationDate, size: Int64(values.fileSize ?? 0)))
        }
        return files
    }

    /// Years of the photos and videos already in the month folders – a sample per folder.
    private static func yearsInMonthFolders(_ monthFolders: [String], dates: [String: Date?],
                                            progress: @escaping PhotoScanner.ProgressHandler) async throws -> Set<Int> {
        var unused = 0
        var sample: [Entry] = []
        for directory in monthFolders {
            sample += try entries(in: directory, notDownloaded: &unused).filter(\.isMedia).prefix(sampleSize)
        }
        var known = dates
        let unknown = sample.filter { known.index(forKey: $0.path) == nil }.map { URL(fileURLWithPath: $0.path) }
        for (url, date) in try await DateFixer.readCaptureDates(unknown, progress: progress) { known.updateValue(date, forKey: url.path) }
        return Set(sample.compactMap { entry in
            ((known[entry.path] ?? nil) ?? entry.fileDate).map { Calendar.current.component(.year, from: $0) }
        })
    }

    // MARK: - Sorting

    /// Moves or copies as planned. On cancellation the work done so far stays; `undo` reverts it as well.
    static func apply(_ plan: Plan, progress: @escaping PhotoScanner.ProgressHandler) throws -> Outcome {
        if plan.copies { try checkSpace(for: plan) }
        let moves = plan.moves.map { FileMove.Planned(sourcePath: $0.sourcePath, targetPath: $0.targetPath, label: $0.name) }
        return FileMove.perform(moves, copy: plan.copies, message: plan.copies ? "Kopiere in Monatsordner …" : "Sortiere in Monatsordner …",
                                sourceMissing: "nicht mehr vorhanden", folderFailed: "Monatsordner ließ sich nicht anlegen", progress: progress)
    }

    /// Moves everything back or moves the copies to the Trash, removes newly created month folders that are empty
    /// again and restores folder modification dates. Returns the files where that failed.
    static func undo(_ outcome: Outcome) -> [String] { FileMove.undo(outcome) }

    /// Copies to another volume (or without clone support) must fit into the free space.
    private static func checkSpace(for plan: Plan) throws {
        guard let source = plan.source, let destination = plan.destination else { return }
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey, .volumeSupportsFileCloningKey,
                                         .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let target = try? destination.resourceValues(forKeys: keys) else { return }
        let sourceVolume = (try? source.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        if sourceVolume?.isEqual(target.volumeIdentifier) == true && target.volumeSupportsFileCloning == true { return }
        // External drives sometimes report no “important usage” capacity – then use the plain free space.
        let available = max(target.volumeAvailableCapacityForImportantUsage ?? 0, Int64(target.volumeAvailableCapacity ?? 0))
        guard available > 0 else { return }
        if plan.copyBytes > available { throw SortError.notEnoughSpace(needed: plan.copyBytes, available: available) }
    }
}
