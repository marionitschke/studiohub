import Foundation

/// An image on disk with the information needed for comparison and display.
struct PhotoFile: Hashable, Sendable {
    let url: URL
    let size: Int64
    let created: Date?
    /// Modification date – together with the size the key for the scan cache.
    var modified: Date?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var captureDate: Date?
    /// Files belonging to this photo that move to the Trash with it:
    /// Live Photo video, .AAE edits, .XMP metadata, and the JPEG of a RAW+JPEG pair.
    var companions: [URL] = []
    var companionBytes: Int64 = 0

    var name: String { url.lastPathComponent }
    /// Size including sidecars – the space freed when deleting.
    var totalSize: Int64 { size + companionBytes }
    /// “+ JPG, MOV” for display.
    var companionSummary: String? {
        companions.isEmpty ? nil : "+ " + companions.map { $0.pathExtension.uppercased() }.joined(separator: ", ")
    }
    var pixelCount: Int { (pixelWidth ?? 0) * (pixelHeight ?? 0) }

    var dimensionsText: String? {
        guard let w = pixelWidth, let h = pixelHeight else { return nil }
        return "\(w) × \(h)"
    }

    /// File names like “IMG_1234 Kopie.jpg”, “IMG_1234 copy 2.jpg” or “IMG_1234 (1).jpg”.
    var looksLikeCopy: Bool {
        let base = url.deletingPathExtension().lastPathComponent.lowercased()
        return base.range(of: #"([ _-](kopie|copy)( ?\d+)?|\s?\(\d+\))$"#, options: .regularExpression) != nil
    }

    /// “Keep first” order: highest resolution, largest file, no copy name, oldest creation date, shortest path.
    static func keepOrder(_ a: PhotoFile, _ b: PhotoFile) -> Bool {
        if a.pixelCount != b.pixelCount { return a.pixelCount > b.pixelCount }
        if a.size != b.size { return a.size > b.size }
        if a.looksLikeCopy != b.looksLikeCopy { return !a.looksLikeCopy }
        let dateA = a.created ?? .distantFuture
        let dateB = b.created ?? .distantFuture
        if dateA != dateB { return dateA < dateB }
        if a.url.path.count != b.url.path.count { return a.url.path.count < b.url.path.count }
        return a.url.path < b.url.path
    }
}

/// What to search for.
struct FindOptions: Equatable, Sendable {
    var identical = true
    var compressed = true
    var motif = true
    var minimumMotifSize = 3
    var tolerance = DuplicateFinder.defaultTolerance

    /// Compressed copies and same motifs require analysing the images themselves.
    var needsImageAnalysis: Bool { compressed || motif }
    var isEmpty: Bool { !identical && !compressed && !motif }
}

/// Role of a file within its group.
enum PhotoRole: Sendable {
    /// Best version of a picture that has copies.
    case best
    /// Byte-identical copy.
    case identicalCopy
    /// The same picture in lower quality (downscaled or more heavily compressed).
    case compressed
    /// Another shot with the same composition and quality (e.g. a burst shot with the same pose).
    case sameMotif
}

/// Files shown together. The first file is the best.
struct DuplicateGroup: Sendable {
    enum Kind: Sendable {
        case copies
        case motif
    }

    var kind: Kind
    var files: [PhotoFile]
    var roles: [URL: PhotoRole]
    /// Suggested for deletion: copies, depending on the selected options.
    var suggestedMarks: Set<URL>
    /// Photos where someone has their eyes closed (only checked in motif groups).
    var closedEyes: Set<URL> = []
    /// Shots clearly blurrier than the sharpest in their motif group.
    var blurry: Set<URL> = []

    var suggestedBytes: Int64 { files.filter { suggestedMarks.contains($0.url) }.reduce(0) { $0 + $1.totalSize } }
    var duplicateCount: Int { files.count - 1 }

    var title: String {
        if kind == .motif { return "Gleiches Motiv" }
        let present = Set(roles.values)
        switch (present.contains(.identicalCopy), present.contains(.compressed)) {
        case (true, true): return "Bytegleiche & komprimierte Kopien"
        case (true, false): return "Bytegleiche Kopien"
        case (false, true): return "Komprimierte Kopien"
        case (false, false): return "Ähnliche Bilder"
        }
    }
}

extension Int64 {
    var formattedBytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

/// “1 Datei” / “3 Dateien” – with thousands separators.
func plural(_ count: Int, _ one: String, _ many: String) -> String {
    "\(count.formatted()) \(count == 1 ? one : many)"
}
