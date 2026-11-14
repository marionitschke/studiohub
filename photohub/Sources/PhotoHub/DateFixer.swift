import Foundation
import UniformTypeIdentifiers

/// Sets created, modified and added dates of photos and videos to the capture time from their metadata – the
/// same logic as the “Apple Fotos Export” tab, but for files in place. Image data is never changed; `undo`
/// restores the previous dates.
enum DateFixer {
    struct Item: Sendable {
        let url: URL
        /// Path as text – `URL` decomposes umlauts; writes must be byte-exact.
        let path: String
        let captureDate: Date
        let current: FileDates
    }

    struct Plan: Sendable {
        var toFix: [Item] = []
        var correctCount = 0
        /// Photos and videos without a capture time – left unchanged.
        var withoutDate: [URL] = []
        /// Only in iCloud, not on this Mac – reading would download them.
        var notDownloadedCount = 0
        /// Capture time of each file read, by path (nil = none) – needed again for month folders.
        var captureDates: [String: Date?] = [:]

        var checkedCount: Int { toFix.count + correctCount + withoutDate.count }
    }

    struct Outcome: Sendable {
        struct Change: Sendable {
            let path: String
            let previous: FileDates
        }
        var changed: [Change] = []
        var failures: [String] = []
        var wasCancelled = false
    }

    // MARK: - Check

    static func plan(folder: URL, recursive: Bool, progress: @escaping PhotoScanner.ProgressHandler) async throws -> Plan {
        var plan = Plan()
        let files = try mediaFiles(in: folder, recursive: recursive, notDownloaded: &plan.notDownloadedCount, progress: progress)
        for (url, date) in try await readCaptureDates(files, progress: progress) {
            plan.captureDates.updateValue(date, forKey: url.path)
            guard let date else {
                plan.withoutDate.append(url)
                continue
            }
            let current = FileDates.read(url)
            if current.matches(date) {
                plan.correctCount += 1
            } else {
                plan.toFix.append(Item(url: url, path: url.path, captureDate: date, current: current))
            }
        }
        plan.toFix.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return plan
    }

    /// Capture time of each file (nil = none). Photos in parallel on GCD threads (ImageIO blocks), videos one by
    /// one via the async AVFoundation API.
    static func readCaptureDates(_ files: [URL], progress: @escaping PhotoScanner.ProgressHandler) async throws -> [(url: URL, date: Date?)] {
        guard !files.isEmpty else { return [] }
        let images = files.filter { !CaptureDate.isMovie($0) }
        let movies = files.filter(CaptureDate.isMovie)
        var dates = try await PhotoScanner.parallelMap(images, message: "Lese Aufnahmezeit der Fotos …", progress: progress) { url in
            autoreleasepool { CaptureDate.image(url) }
        }
        if !movies.isEmpty { progress(ScanProgress(message: "Lese Aufnahmezeit der Videos …", done: 0, total: movies.count)) }
        for (index, url) in movies.enumerated() {
            try Task.checkCancellation()
            dates.append(await CaptureDate.movie(url))
            progress(ScanProgress(message: "Lese Aufnahmezeit der Videos …", done: index + 1, total: movies.count))
        }
        return zip(images + movies, dates).map { (url: $0, date: $1) }
    }

    /// Photos and videos in the folder. Like the duplicate search, skips hidden files, packages (the Photos library
    /// is never modified) and NAS thumbnail folders.
    private static func mediaFiles(in folder: URL, recursive: Bool, notDownloaded: inout Int,
                                   progress: PhotoScanner.ProgressHandler) throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .contentTypeKey, .ubiquitousItemDownloadingStatusKey]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: options,
                                                              errorHandler: { _, _ in true }) else {
            throw ScanError.folderNotReadable(folder)
        }
        var files: [URL] = []
        progress(ScanProgress(message: "Suche Fotos und Videos …"))
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true {
                if PhotoScanner.ignoredFolders.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, let type = values.contentType,
                  type.conforms(to: .image) || type.conforms(to: .audiovisualContent) else { continue }
            if let status = values.ubiquitousItemDownloadingStatus, status != .current {
                notDownloaded += 1
                continue
            }
            files.append(url)
            if files.count % 250 == 0 { progress(ScanProgress(message: "Suche Fotos und Videos …", done: files.count)) }
        }
        return files
    }

    // MARK: - Fixing

    static func apply(_ plan: Plan, progress: @escaping PhotoScanner.ProgressHandler) -> Outcome {
        var outcome = Outcome()
        let total = plan.toFix.count
        progress(ScanProgress(message: "Korrigiere Datum …", done: 0, total: total))
        for (index, item) in plan.toFix.enumerated() {
            if Task.isCancelled {
                outcome.wasCancelled = true
                break
            }
            guard FileManager.default.fileExists(atPath: item.path) else {
                outcome.failures.append("\(item.url.lastPathComponent): nicht mehr vorhanden")
                continue
            }
            let previous = FileDates.read(item.url)
            if FileDates.write(.all(item.captureDate), toPath: item.path) {
                outcome.changed.append(.init(path: item.path, previous: previous))
            } else {
                // Partially written? Restore the previous dates.
                FileDates.write(previous, toPath: item.path)
                outcome.failures.append("\(item.url.lastPathComponent): Datum ließ sich nicht setzen")
            }
            if (index + 1) % 50 == 0 || index + 1 == total { progress(ScanProgress(message: "Korrigiere Datum …", done: index + 1, total: total)) }
        }
        return outcome
    }

    /// Restores the previous dates. Returns the files where that failed.
    static func undo(_ outcome: Outcome) -> [String] {
        outcome.changed.reversed().compactMap { change in
            FileDates.write(change.previous, toPath: change.path) ? nil : (change.path as NSString).lastPathComponent
        }
    }
}
