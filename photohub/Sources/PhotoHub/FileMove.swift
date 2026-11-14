import Foundation

/// Moving and copying for “Apple Fotos Export” (option), “Bilder-Datum korrigieren” (month folders, also as
/// copies) and “Bilder-Ordner abgleichen”.
enum FileMove {
    /// Moves without overwriting: a rename on the same volume (instant), otherwise a copy with metadata followed by
    /// deleting the original. Paths as text so names stay byte-identical.
    static func move(atPath source: String, toPath target: String) throws {
        func failure(_ code: Int32) -> POSIXError { POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        if renamex_np(source, target, UInt32(RENAME_EXCL)) == 0 { return }
        var code = errno
        // exFAT, FAT and some network volumes don't support RENAME_EXCL: check for an existing file (case-insensitive
        // there), then rename.
        if code == ENOTSUP {
            var info = stat()
            if lstat(target, &info) == 0 { throw failure(EEXIST) }
            guard errno == ENOENT else { throw failure(errno) }
            if rename(source, target) == 0 { return }
            code = errno
        }
        guard code == EXDEV else { throw failure(code) }
        guard copyfile(source, target, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_EXCL)) == 0 else {
            let code = errno
            // Remove the partial copy – it is ours for sure (COPYFILE_EXCL).
            if code != EEXIST { unlink(target) }
            throw failure(code)
        }
        // Delete only once the copy is complete and written to the volume – not just cached, so unplugging a drive
        // or a network error can't lose the only copy. fsync also reports write errors deferred by network volumes.
        let synced: Bool = {
            let descriptor = open(target, O_RDONLY)
            guard descriptor >= 0 else { return false }
            defer { close(descriptor) }
            return fsync(descriptor) == 0 || errno == ENOTSUP || errno == EINVAL
        }()
        var sourceInfo = stat()
        var targetInfo = stat()
        guard synced, stat(source, &sourceInfo) == 0, stat(target, &targetInfo) == 0, sourceInfo.st_size == targetInfo.st_size else {
            unlink(target)
            throw failure(EIO)
        }
        guard removeOriginal(source, sameAs: sourceInfo) else {
            let code = errno
            unlink(target)
            throw failure(code)
        }
    }

    /// `unlink`, also where an exFAT volume lists a name in another Unicode normalization than it was created with
    /// (umlauts): lookups match either form there, but removing needs the original one. A variant is only removed if
    /// it is the very same file (device and inode).
    private static func removeOriginal(_ path: String, sameAs info: stat) -> Bool {
        if unlink(path) == 0 { return true }
        let code = errno
        if code == ENOENT {
            let directory = (path as NSString).deletingLastPathComponent
            let name = (path as NSString).lastPathComponent
            for variant in [name.precomposedStringWithCanonicalMapping, name.decomposedStringWithCanonicalMapping]
            where !variant.utf8.elementsEqual(name.utf8) {
                let candidate = directory + "/" + variant
                var other = stat()
                if lstat(candidate, &other) == 0, other.st_dev == info.st_dev, other.st_ino == info.st_ino,
                   unlink(candidate) == 0 { return true }
            }
        }
        errno = code
        return false
    }

    /// Copies like `cp -c`: a clone on APFS (instant, no extra space), otherwise a full copy, with metadata.
    /// Paths as text so names stay byte-identical. Never overwrites.
    static func copy(atPath source: String, toPath target: String) throws {
        guard copyfile(source, target, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_CLONE)) == 0 else {
            let code = errno
            // Remove the partial copy – it is ours for sure (COPYFILE_EXCL).
            if code != EEXIST { unlink(target) }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    // MARK: - Batch

    /// A planned move. Paths as text (byte-exact names); `label` appears in error messages.
    struct Planned: Sendable {
        let sourcePath: String
        let targetPath: String
        let label: String
    }

    /// What a batch of moves or copies changed – enough to undo it.
    struct Batch: Sendable {
        /// Copied instead of moved: sources are unchanged, `undo` moves the copies to the Trash.
        var copies = false
        struct Moved: Sendable {
            let sourcePath: String
            let targetPath: String
            /// Dates beforehand – written again in the new folder, restored at the old location by `undo`.
            let dates: FileDates
        }
        var moved: [Moved] = []
        var createdDirectories: [String] = []
        /// Modification dates of the touched folders beforehand – moving changes them.
        var folderDates: [String: Date] = [:]
        var failures: [String] = []
        var wasCancelled = false
    }

    /// Moves (or with `copy`, copies) as planned and creates missing folders. A destination taken meanwhile is
    /// numbered (`Name_1`). Created, modified and added dates stay as before. On cancellation the work done so far
    /// stays and `undo` reverts it as well.
    /// - Parameters:
    ///   - sourceMissing: Error text when the file is gone, e.g. “nicht mehr in A”.
    ///   - folderFailed: Error text when the destination folder can't be created.
    static func perform(_ moves: [Planned], copy: Bool = false, message: String, sourceMissing: String, folderFailed: String,
                        progress: PhotoScanner.ProgressHandler) -> Batch {
        let fileManager = FileManager.default
        var batch = Batch()
        batch.copies = copy
        func remember(_ directory: String) {
            guard batch.folderDates[directory] == nil,
                  let date = (try? fileManager.attributesOfItem(atPath: directory))?[.modificationDate] as? Date else { return }
            batch.folderDates[directory] = date
        }
        /// Creates missing folders one by one (for `undo`) via `mkdir`, because `FileManager` decomposes umlauts.
        func createDirectory(_ path: String) throws {
            var missing: [String] = []
            var existing = path
            while !fileManager.fileExists(atPath: existing) {
                missing.append(existing)
                existing = (existing as NSString).deletingLastPathComponent
            }
            guard !missing.isEmpty else { return }
            remember(existing)
            for directory in missing.reversed() {
                if mkdir(directory, 0o777) == 0 {
                    batch.createdDirectories.append(directory)
                } else if errno != EEXIST {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }

        let total = moves.count
        progress(ScanProgress(message: message, done: 0, total: total))
        for (index, move) in moves.enumerated() {
            if Task.isCancelled {
                batch.wasCancelled = true
                break
            }
            defer {
                if (index + 1) % 20 == 0 || index + 1 == total { progress(ScanProgress(message: message, done: index + 1, total: total)) }
            }
            guard fileManager.fileExists(atPath: move.sourcePath) else {
                batch.failures.append("\(move.label): \(sourceMissing)")
                continue
            }
            let directory = (move.targetPath as NSString).deletingLastPathComponent
            let name = (move.targetPath as NSString).lastPathComponent
            do {
                try createDirectory(directory)
            } catch {
                batch.failures.append("\(move.label): \(folderFailed) (\(error.localizedDescription))")
                continue
            }
            var targetPath = move.targetPath
            var suffix = 0
            while fileManager.fileExists(atPath: targetPath) {
                suffix += 1
                targetPath = directory + "/" + ExportSorter.renamed(name, suffix)
            }
            if !copy { remember((move.sourcePath as NSString).deletingLastPathComponent) }
            remember(directory)
            let dates = FileDates.read(URL(fileURLWithPath: move.sourcePath))
            do {
                if copy {
                    try FileMove.copy(atPath: move.sourcePath, toPath: targetPath)
                } else {
                    try FileMove.move(atPath: move.sourcePath, toPath: targetPath)
                }
            } catch {
                batch.failures.append("\(move.label): \(error.localizedDescription)")
                continue
            }
            // In the new folder “date added” (on another volume also “created”) would otherwise be now – keep the old dates.
            FileDates.write(dates, toPath: targetPath)
            batch.moved.append(.init(sourcePath: move.sourcePath, targetPath: targetPath, dates: dates))
        }
        // Nothing moved (all failed, or cancelled right away): there is nothing to undo, so don't leave the newly
        // created, empty folders behind.
        if batch.moved.isEmpty {
            _ = undo(batch)
            batch.createdDirectories = []
            batch.folderDates = [:]
        }
        return batch
    }

    /// Moves everything back (copies to the Trash), removes newly created folders that are empty again and restores
    /// folder modification dates. Returns the files where that failed.
    static func undo(_ batch: Batch) -> [String] {
        var failures: [String] = []
        if batch.copies {
            let copies = batch.moved.map(\.targetPath).filter { FileManager.default.fileExists(atPath: $0) }
            failures = FileTrash.moveToTrash(copies.map { URL(fileURLWithPath: $0) }).failed
        } else {
            for moved in batch.moved.reversed() {
                do {
                    try move(atPath: moved.targetPath, toPath: moved.sourcePath)
                    FileDates.write(moved.dates, toPath: moved.sourcePath)
                } catch {
                    failures.append("\((moved.sourcePath as NSString).lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        for directory in batch.createdDirectories.reversed() { rmdir(directory) }
        for (folder, date) in batch.folderDates {
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: folder)
        }
        return failures
    }
}
