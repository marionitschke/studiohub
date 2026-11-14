import Foundation

/// Remembers per file what a scan computed expensively – checksums, fingerprint with image info, sharpness and
/// faces – so a rescan only reads new or changed photos. A file counts as unchanged while path, size and
/// modification date stay the same.
///
/// Stored at ~/Library/Caches/<bundle ID>/ScanCache.plist. Without a file the cache works in memory only.
final class ScanCache: @unchecked Sendable {
    /// Increase when fingerprint, sharpness measurement or face check change – everything is then recomputed.
    private static let version = 1

    struct Entry: Codable {
        var size: Int64
        var modified: Date
        var quickHash: String?
        var fullHash: String?
        var picture: StoredPicture?
        var shot: ShotInfo?
    }

    /// Fingerprint plus resolution and capture date.
    struct StoredPicture: Codable {
        var horizontal: Int64
        var vertical: Int64
        var grid: Data
        var pixelWidth: Int?
        var pixelHeight: Int?
        var captureDate: Date?

        init(_ print: Fingerprint) {
            horizontal = Int64(bitPattern: print.horizontal)
            vertical = Int64(bitPattern: print.vertical)
            grid = Data(print.grid)
            pixelWidth = print.file.pixelWidth
            pixelHeight = print.file.pixelHeight
            captureDate = print.file.captureDate
        }

        func withMetadata(_ file: PhotoFile) -> PhotoFile {
            var file = file
            file.pixelWidth = pixelWidth
            file.pixelHeight = pixelHeight
            file.captureDate = captureDate
            return file
        }

        func fingerprint(of file: PhotoFile) -> Fingerprint {
            Fingerprint(file: withMetadata(file), horizontal: UInt64(bitPattern: horizontal),
                        vertical: UInt64(bitPattern: vertical), grid: [UInt8](grid))
        }
    }

    private struct Archive: Codable {
        var version: Int
        var entries: [String: Entry]
    }

    static let shared = ScanCache(fileURL: defaultFileURL)

    static var defaultFileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "PhotoHub", isDirectory: true)
            .appendingPathComponent("ScanCache.plist")
    }

    let fileURL: URL?
    private let lock = NSLock()
    /// Keeps two saves, or a save and a clear, from overtaking each other.
    private let fileLock = NSLock()
    /// Read from disk on first access.
    private var loadedEntries: [String: Entry]?
    private var isDirty = false

    init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    /// Size of the cache file, nil if there is none.
    var fileSize: Int64? {
        guard let path = fileURL?.path,
              let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    // MARK: - Reading and writing

    /// The entry for this file – only if it hasn't changed since.
    func entry(for file: PhotoFile) -> Entry? {
        guard let modified = file.modified else { return nil }
        return withEntries { entries in
            guard let entry = entries[file.url.path], entry.size == file.size, entry.modified == modified else { return nil }
            return entry
        }
    }

    /// Adds to the file's entry, discarding an outdated entry.
    func update(_ file: PhotoFile, _ change: (inout Entry) -> Void) {
        guard let modified = file.modified else { return }
        withEntries { entries in
            var entry = entries[file.url.path].flatMap { $0.size == file.size && $0.modified == modified ? $0 : nil }
                ?? Entry(size: file.size, modified: modified)
            change(&entry)
            entries[file.url.path] = entry
            isDirty = true
        }
    }

    /// Forgets files in the scanned folder that the scan no longer found (deleted, moved).
    /// Entries of other folders stay – e.g. from a drive that is currently disconnected.
    func removeEntries(in folder: URL, recursive: Bool, except present: Set<String>) {
        let root = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        withEntries { entries in
            let gone = entries.keys.filter { path in
                guard path.hasPrefix(root), !present.contains(path) else { return false }
                return recursive || !path.dropFirst(root.count).contains("/")
            }
            gone.forEach { entries[$0] = nil }
            if !gone.isEmpty { isDirty = true }
        }
    }

    /// Writes the cache if something changed.
    func save() {
        guard let fileURL else { return }
        fileLock.lock()
        defer { fileLock.unlock() }
        let snapshot: [String: Entry]? = withEntries { entries in
            guard isDirty else { return nil }
            isDirty = false
            return entries
        }
        guard let snapshot else { return }
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(Archive(version: Self.version, entries: snapshot))
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // A missing cache is fine – the next scan just recomputes.
        }
    }

    func clear() {
        fileLock.lock()
        defer { fileLock.unlock() }
        lock.lock()
        loadedEntries = [:]
        isDirty = false
        lock.unlock()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    private func withEntries<T>(_ body: (inout [String: Entry]) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        if loadedEntries == nil { loadedEntries = Self.load(from: fileURL) }
        return body(&loadedEntries!)
    }

    private static func load(from url: URL?) -> [String: Entry] {
        guard let url, let data = try? Data(contentsOf: url),
              let archive = try? PropertyListDecoder().decode(Archive.self, from: data),
              archive.version == version else { return [:] }
        return archive.entries
    }
}
