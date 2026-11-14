import Foundation
import UniformTypeIdentifiers

/// Adds the photos and videos from folder A that are missing in folder B by moving them into the same subfolder
/// in B. “Missing” means no file with the same content exists anywhere in B – name and subfolder don't matter, so
/// whatever remains in A afterwards also exists in B.
/// - Compares the SHA-256 of the whole file (using the scan cache), not just start and end like the export sorter:
///   a false match would leave a photo in A that is not actually in B.
/// - Taken names in B are numbered like in the export sorter (`IMG_1_1.HEIC`); files sharing a name (Live Photo,
///   RAW+JPEG, .AAE) together.
/// - Created, modified and added dates stay as in A. `undo` moves everything back.
enum FolderSync {
    struct Move: Sendable {
        /// Paths as text – `URL` decomposes umlauts; names must stay byte-identical.
        let sourcePath: String
        let targetPath: String
        /// Path below A or B, for display.
        let relativeSource: String
        let relativeTarget: String
        let size: Int64

        var source: URL { URL(fileURLWithPath: sourcePath) }
        var isRenamed: Bool { (relativeSource as NSString).lastPathComponent != (relativeTarget as NSString).lastPathComponent }
    }

    struct Plan: Sendable {
        var moves: [Move] = []
        /// Same content already in B – stay in A.
        var presentCount = 0
        /// Same content as another file from A that moves to B – stays in A.
        var duplicateCount = 0
        /// Only in iCloud, not on this Mac: left in A and not compared in B, since reading would download them.
        var notDownloadedInSource = 0
        var notDownloadedInDestination = 0
        /// Other files in A (not photos or videos) – left in place.
        var otherFileCount = 0
        /// A and B are on different volumes: moving means copying and deleting in A.
        var acrossVolumes = false

        var checkedCount: Int { moves.count + presentCount + duplicateCount }
        var moveBytes: Int64 { moves.reduce(0) { $0 + $1.size } }
        var renameCount: Int { moves.filter(\.isRenamed).count }
    }

    /// What moving did – enough to undo it.
    typealias Outcome = FileMove.Batch

    enum SyncError: LocalizedError {
        case overlapping
        case notEnoughSpace(needed: Int64, available: Int64)

        var errorDescription: String? {
            switch self {
            case .overlapping:
                return "A und B müssen zwei getrennte Ordner sein – keiner darf im anderen liegen."
            case .notEnoughSpace(let needed, let available):
                return "In B ist nicht genug Platz: Die Dateien brauchen \(needed.formattedBytes), frei sind \(available.formattedBytes)."
            }
        }
    }

    /// Sidecar files without an image type: Photos edits (.AAE) and Lightroom & co. metadata (.XMP).
    private static let sidecarExtensions: Set<String> = ["aae", "xmp"]

    // MARK: - Comparing

    /// Plans the move without changing anything.
    static func plan(source: URL, destination: URL, cache: ScanCache, progress: @escaping PhotoScanner.ProgressHandler) async throws -> Plan {
        func normalized(_ url: URL) -> String {
            url.standardizedFileURL.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping.lowercased()
        }
        func contains(_ outer: String, _ inner: String) -> Bool { (inner + "/").hasPrefix(outer + "/") }
        let sourceKey = normalized(source)
        let destinationKey = normalized(destination)
        if contains(sourceKey, destinationKey) || contains(destinationKey, sourceKey) { throw SyncError.overlapping }

        var plan = Plan()
        plan.acrossVolumes = !sameVolume(source, destination)
        let sourceFiles = try mediaFiles(in: source, name: "A", notDownloaded: &plan.notDownloadedInSource,
                                         others: &plan.otherFileCount, progress: progress)
        var otherFilesInDestination = 0
        let destinationFiles = try mediaFiles(in: destination, name: "B", notDownloaded: &plan.notDownloadedInDestination,
                                              others: &otherFilesInDestination, progress: progress)

        // Only files of equal size can match – from B, only those whose size occurs in A are read.
        let sourceSizes = Set(sourceFiles.map(\.size))
        let candidates = sourceFiles + destinationFiles.filter { sourceSizes.contains($0.size) }
        let identicalSets = try await PhotoScanner.exactDuplicates(in: candidates, cache: cache, progress: progress)

        let sourcePaths = Set(sourceFiles.map(\.url.path))
        var present = Set<String>()
        var duplicates = Set<String>()
        func nameKey(_ path: String) -> String { (path as NSString).lastPathComponent.precomposedStringWithCanonicalMapping.lowercased() }
        for set in identicalSets {
            let fromSource = set.map(\.url.path).filter(sourcePaths.contains)
            if set.contains(where: { sidecarExtensions.contains($0.url.pathExtension.lowercased()) }) {
                // A sidecar belongs to the photo with its name, and the same edit applied to two photos gives identical
                // .AAE files. So it only counts as present under its own name in B, and never as a duplicate in A.
                let namesInB = Set(set.map(\.url.path).filter { !sourcePaths.contains($0) }.map(nameKey))
                present.formUnion(fromSource.filter { namesInB.contains(nameKey($0)) })
            } else if fromSource.count < set.count {
                present.formUnion(fromSource)
            } else {
                // Only in A, but several times: the first file moves to B, then the others exist there too.
                duplicates.formUnion(fromSource.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.dropFirst())
            }
        }
        plan.presentCount = present.count
        plan.duplicateCount = duplicates.count

        let missing = sourceFiles.filter { !present.contains($0.url.path) && !duplicates.contains($0.url.path) }
        plan.moves = targets(for: missing, source: source, destination: destination)
        return plan
    }

    /// Photos, videos and their sidecars in the folder and all subfolders. Like the duplicate search, skips hidden
    /// files, packages (the Photos library is never modified) and NAS thumbnail folders.
    private static func mediaFiles(in folder: URL, name: String, notDownloaded: inout Int, others: inout Int,
                                   progress: PhotoScanner.ProgressHandler) throws -> [PhotoFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .creationDateKey,
                                      .contentModificationDateKey, .contentTypeKey, .ubiquitousItemDownloadingStatusKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                              errorHandler: { _, _ in true }) else {
            throw ScanError.folderNotReadable(folder)
        }
        let keySet = Set(keys)
        let message = "Suche Fotos und Videos in \(name) …"
        var files: [PhotoFile] = []
        progress(ScanProgress(message: message))
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            guard let values = try? url.resourceValues(forKeys: keySet) else { continue }
            if values.isDirectory == true {
                if PhotoScanner.ignoredFolders.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let isMedia = values.contentType.map { $0.conforms(to: .image) || $0.conforms(to: .audiovisualContent) } ?? false
            guard isMedia || sidecarExtensions.contains(url.pathExtension.lowercased()) else {
                others += 1
                continue
            }
            if let status = values.ubiquitousItemDownloadingStatus, status != .current {
                notDownloaded += 1
                continue
            }
            guard let size = values.fileSize, size > 0 else { continue }
            files.append(PhotoFile(url: url, size: Int64(size), created: values.creationDate, modified: values.contentModificationDate))
            if files.count % 250 == 0 { progress(ScanProgress(message: message, done: files.count)) }
        }
        return files
    }

    /// Destination of each missing file: the same subfolder in B. Files sharing a name in one folder (Live Photo,
    /// RAW+JPEG, .AAE) get the same first suffix – “IMG_1”, “IMG_1_1”, … – that is still free in B.
    private static func targets(for files: [PhotoFile], source: URL, destination: URL) -> [Move] {
        let fileManager = FileManager.default
        // Destinations already claimed in this run (case-insensitive, like APFS).
        var claimed = Set<String>()
        func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }
        func isFree(_ path: String) -> Bool { !claimed.contains(key(path)) && !fileManager.fileExists(atPath: path) }

        let withRelative = files.map { (file: $0, relative: relativePath($0.url.path, root: source.path)) }
        let groups = Dictionary(grouping: withRelative) { key(($0.relative as NSString).deletingPathExtension) }
        var moves: [Move] = []
        for stem in groups.keys.sorted() {
            let members = groups[stem]!.sorted { $0.relative < $1.relative }
            func target(_ relative: String, _ suffix: Int) -> String {
                let directory = (relative as NSString).deletingLastPathComponent
                let name = ExportSorter.renamed((relative as NSString).lastPathComponent, suffix)
                return directory.isEmpty ? name : directory + "/" + name
            }
            var suffix = 0
            while !members.allSatisfy({ isFree(destination.path + "/" + target($0.relative, suffix)) }) { suffix += 1 }
            for member in members {
                let relativeTarget = target(member.relative, suffix)
                let targetPath = destination.path + "/" + relativeTarget
                claimed.insert(key(targetPath))
                moves.append(Move(sourcePath: member.file.url.path, targetPath: targetPath, relativeSource: member.relative,
                                  relativeTarget: relativeTarget, size: member.file.size))
            }
        }
        return moves.sorted { $0.relativeSource.localizedStandardCompare($1.relativeSource) == .orderedAscending }
    }

    /// “/A/2020/Urlaub/IMG_1.jpg” under “/A” → “2020/Urlaub/IMG_1.jpg”, character for character as on disk.
    private static func relativePath(_ path: String, root: String) -> String {
        if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        let components = (path as NSString).pathComponents.dropFirst((root as NSString).pathComponents.count)
        return components.joined(separator: "/")
    }

    // MARK: - Moving

    /// Moves as planned. On cancellation the files moved so far stay moved; `undo` reverts them as well.
    static func apply(_ plan: Plan, source: URL, destination: URL, progress: @escaping PhotoScanner.ProgressHandler) throws -> Outcome {
        if plan.acrossVolumes { try checkSpace(for: plan, destination: destination) }
        let moves = plan.moves.map { FileMove.Planned(sourcePath: $0.sourcePath, targetPath: $0.targetPath, label: $0.relativeSource) }
        return FileMove.perform(moves, message: "Verschiebe nach B …", sourceMissing: "nicht mehr in A",
                                folderFailed: "Ordner in B ließ sich nicht anlegen", progress: progress)
    }

    /// Moves everything back to A, removes newly created folders in B that are empty again and restores folder
    /// modification dates. Returns the files where that failed.
    static func undo(_ outcome: Outcome) -> [String] { FileMove.undo(outcome) }

    private static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let volumeA = (try? a.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        let volumeB = (try? b.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
        return volumeA != nil && volumeA?.isEqual(volumeB) == true
    }

    /// Moving to another volume copies – that must fit into the free space.
    private static func checkSpace(for plan: Plan, destination: URL) throws {
        let values = try? destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        // External drives sometimes report no “important usage” capacity – then use the plain free space.
        let available = max(values?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(values?.volumeAvailableCapacity ?? 0))
        guard available > 0 else { return }
        if plan.moveBytes > available { throw SyncError.notEnoughSpace(needed: plan.moveBytes, available: available) }
    }
}
