import AVFoundation
import AppKit

/// A thumbnail of the timeline: the frame at `time` (source ticks) for tiles `step` ticks wide.
struct ThumbnailKey: Hashable, Sendable {
    let step: Int64
    let time: Int64
}

/// Thumbnails for the timeline, made in the background a few at a time. The timeline asks for what
/// it shows; wishes that have not started yet are replaced by newer ones (scrolling, zooming).
@MainActor
final class ThumbnailCache {
    static let limit = 3_000

    private var generator: AVAssetImageGenerator?
    private var timescale: CMTimeScale = 600
    private var images: [ThumbnailKey: CGImage] = [:]
    private var queue: [ThumbnailKey] = []
    private var running = false
    private var generation = 0
    /// Called when new thumbnails are there.
    var onUpdate: (() -> Void)?

    func load(_ document: VideoDocument?) {
        generation += 1
        images = [:]
        queue = []
        // A batch still running for the old video ends on its own when it sees the new generation.
        running = false
        generator = document.map { document in
            let generator = AVAssetImageGenerator(asset: document.asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 200)
            return generator
        }
        timescale = document?.timescale ?? 600
    }

    func image(_ key: ThumbnailKey) -> CGImage? { images[key] }

    /// The thumbnails the timeline shows now, in drawing order.
    func want(_ keys: [ThumbnailKey]) {
        queue = keys.filter { images[$0] == nil }
        if !running, !queue.isEmpty { run() }
    }

    private func run() {
        guard let generator else { return }
        running = true
        let generation = generation
        Task { @MainActor [weak self] in
            while let self, generation == self.generation, let first = self.queue.first {
                // One batch per tile width: the allowed deviation depends on it.
                let batch = Array(self.queue.prefix { $0.step == first.step }.prefix(6))
                self.queue.removeFirst(batch.count)
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = CMTime(value: max(1, first.step / 2), timescale: self.timescale)
                let times = batch.map { CMTime(value: $0.time, timescale: self.timescale) }
                for await result in generator.images(for: times) {
                    guard generation == self.generation else { break }
                    guard let image = try? result.image else { continue }
                    let requested = CMTimeConvertScale(result.requestedTime, timescale: self.timescale, method: .roundHalfAwayFromZero).value
                    if self.images.count >= ThumbnailCache.limit { self.images.removeAll() }
                    self.images[ThumbnailKey(step: first.step, time: requested)] = image
                }
                if generation == self.generation { self.onUpdate?() }
            }
            if let self, generation == self.generation { self.running = false }
        }
    }
}
