import Foundation

struct TrashMove: Sendable {
    let original: URL
    let trashed: URL
}

/// Moves files to the Trash – PhotoHub never deletes permanently.
enum FileTrash {
    struct Outcome: Sendable {
        var moved: [TrashMove] = []
        var failed: [String] = []
    }

    static func moveToTrash(_ urls: [URL]) -> Outcome {
        var outcome = Outcome()
        for url in urls {
            do {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                outcome.moved.append(TrashMove(original: url, trashed: (resulting as URL?) ?? url))
            } catch {
                outcome.failed.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return outcome
    }
}
