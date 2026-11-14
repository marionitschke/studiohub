import Foundation

/// Remembers the cuts and changed export tags per recording, so that reopening a long recording
/// brings them back. Stored as JSON in Application Support, keyed by the file path (the paths of
/// all files for a joined recording); size and length must still match.
final class EditStore {
    struct Entry: Codable {
        var size: Int64
        var length: Int64
        var segments: [Segment]
        var tags: CustomTags?
        var saved: Date
    }

    struct Restored {
        /// nil if the recording was never edited.
        var edit: EditList?
        var tags = CustomTags()
    }

    static let maximumEntries = 200

    let url: URL

    init(directory: URL) {
        url = directory.appendingPathComponent("edits.json")
    }

    static var standard: EditStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return EditStore(directory: support.appendingPathComponent("MusicHub", isDirectory: true))
    }

    static func key(for document: AudioDocument) -> String {
        document.urls.map(\.path).joined(separator: "\n")
    }

    func load(for document: AudioDocument) -> Restored {
        guard let entry = entries()?[EditStore.key(for: document)],
              entry.size == document.fileSize, entry.length == document.length else { return Restored() }
        let edit = EditList(length: document.length, segments: entry.segments)
        return Restored(edit: edit.hasEdits ? edit : nil, tags: entry.tags ?? CustomTags())
    }

    /// Saves the edit and the tags; a recording with neither is forgotten.
    func save(_ edit: EditList, tags: CustomTags = CustomTags(), for document: AudioDocument) {
        var all: [String: Entry]
        if let stored = entries() {
            all = stored
        } else {
            // Damaged, or written by a newer version: put aside instead of overwritten with this one entry.
            let aside = url.deletingLastPathComponent()
                .appendingPathComponent("edits-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            guard (try? FileManager.default.moveItem(at: url, to: aside)) != nil else { return }
            all = [:]
        }
        let key = EditStore.key(for: document)
        if edit.hasEdits || !tags.isEmpty {
            all[key] = Entry(size: document.fileSize, length: document.length, segments: edit.segments,
                             tags: tags.isEmpty ? nil : tags, saved: Date())
        } else {
            guard all.removeValue(forKey: key) != nil else { return }
        }
        if all.count > EditStore.maximumEntries {
            for (key, _) in all.sorted(by: { $0.value.saved < $1.value.saved }).prefix(all.count - EditStore.maximumEntries) {
                all.removeValue(forKey: key)
            }
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(all) { try? data.write(to: url, options: .atomic) }
    }

    /// All stored entries; entries that cannot be read are left out. nil if the file exists but cannot
    /// be read at all.
    private func entries() -> [String: Entry]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let entries = try? decoder.decode([String: Lenient<Entry>].self, from: data) else { return nil }
        return entries.compactMapValues(\.value)
    }
}

/// Decodes to nil instead of failing, so that one damaged entry does not take the others with it.
private struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}
