import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What the batch does with every video; chosen once before it starts and the same for all.
struct BatchSettings: Equatable, Sendable {
    /// The watermark image (a PNG copy, see `LogoStore`).
    var watermark: URL?
    /// Width of the watermark as a fraction of the picture's shorter side, so that it looks the same
    /// on 4:3 and 16:9 videos.
    var watermarkSize = 0.22
    var watermarkOpacity = 0.7
    var format = VideoFormat.mp4
    var codec = VideoCodec.h264

    static let sizeRange = 0.05...0.6
    static let opacityRange = 0.1...1.0

    private static let watermarkKey = "batchWatermark", sizeKey = "batchWatermarkSize", opacityKey = "batchWatermarkOpacity",
                       formatKey = "batchFormat", codecKey = "batchCodec"

    static func load() -> BatchSettings {
        let defaults = UserDefaults.standard
        var settings = BatchSettings()
        if let path = defaults.string(forKey: watermarkKey), FileManager.default.fileExists(atPath: path) {
            settings.watermark = URL(fileURLWithPath: path)
        }
        if defaults.object(forKey: sizeKey) != nil {
            settings.watermarkSize = min(max(sizeRange.lowerBound, defaults.double(forKey: sizeKey)), sizeRange.upperBound)
        }
        if defaults.object(forKey: opacityKey) != nil {
            settings.watermarkOpacity = min(max(opacityRange.lowerBound, defaults.double(forKey: opacityKey)), opacityRange.upperBound)
        }
        settings.format = defaults.string(forKey: formatKey).flatMap(VideoFormat.init(rawValue:)) ?? .mp4
        settings.codec = defaults.string(forKey: codecKey).flatMap(VideoCodec.init(rawValue:)) ?? .h264
        return settings
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(watermark?.path, forKey: Self.watermarkKey)
        defaults.set(watermarkSize, forKey: Self.sizeKey)
        defaults.set(watermarkOpacity, forKey: Self.opacityKey)
        defaults.set(format.rawValue, forKey: Self.formatKey)
        defaults.set(codec.rawValue, forKey: Self.codecKey)
    }

    /// The watermark file to keep when old logo copies are cleaned up.
    static var rememberedWatermark: String? { UserDefaults.standard.string(forKey: watermarkKey) }
}

/// The fixed part of the batch: every video fades in from black and out to black (picture and
/// sound), shows its title in the first ten seconds and gets the watermark at the bottom left.
enum BatchRecipe {
    static let fadeSeconds = 1.5
    /// The title fades in from 1 s, out until 9 s.
    static let titleStart = 1.0, titleEnd = 9.0, titleFade = 1.0
    /// The band in this size (of the shorter side), date and place below at 60 %.
    static let titleSize = 0.08, secondLineScale = 0.6
    /// Space between the watermark and the left and bottom edge, as a fraction of the shorter side.
    static let margin = 0.04

    /// The title from a file name: without extension, tags such as "+tokka video+" or "[HD]",
    /// underscores and doubled spaces; in capitals (German rules: ß → SS). A date (or a year) starts
    /// the second line, so that the band stands above date and place.
    static func title(forFile url: URL) -> String {
        let raw = url.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping
        var name = raw.replacingOccurrences(of: #"\+[^+]*\+|\[[^\]]*\]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-–,·")))
        if name.isEmpty { name = raw.trimmingCharacters(in: .whitespaces) }
        var title = name.uppercased(with: Locale(identifier: "de_DE"))
        let date = #"(?<=\S) (?=(?:AM )?(?:\d{1,2}\.\d{1,2}\.\d{2,4}|(?:19|20)\d{2})(?:\s|$))"#
        if let range = title.range(of: date, options: .regularExpression) {
            title.replaceSubrange(range, with: "\n")
        }
        return title
    }

    /// Where the title runs (sequence ticks, whole frames); in short videos within the first and last tenth.
    static func titleRange(_ document: VideoDocument) -> Range<Int64> {
        let length = Double(document.length) / Double(document.timescale)
        func frames(_ seconds: Double) -> Int64 { document.ticks(seconds: seconds) / document.frameTicks * document.frameTicks }
        let start = frames(min(titleStart, length * 0.1))
        let end = max(start + document.frameTicks, frames(min(titleEnd, length * 0.9)))
        return start..<min(end, document.length)
    }

    /// The moment the preview shows: the middle of the title, after the fade in.
    static func previewPosition(_ document: VideoDocument) -> Int64 {
        let range = titleRange(document)
        return (range.lowerBound + range.upperBound) / 2 / document.frameTicks * document.frameTicks
    }

    /// The source frame the preview decorates: at `previewPosition`, upright, in the render size.
    static func previewFrame(_ document: VideoDocument) async throws -> CIImage {
        let generator = AVAssetImageGenerator(asset: document.asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = document.time(document.frameTicks * 10)
        generator.requestedTimeToleranceAfter = document.time(document.frameTicks * 10)
        let image = try await generator.image(at: document.time(document.bounds.lowerBound + previewPosition(document))).image
        let size = EffectRenderer.renderSize(of: document), frame = CIImage(cgImage: image)
        return frame.transformed(by: CGAffineTransform(scaleX: size.width / frame.extent.width, y: size.height / frame.extent.height))
    }

    /// The preview frame with title and watermark as the export draws them, in sRGB.
    static func preview(_ frame: CIImage, document: VideoDocument, renderer: EffectRenderer) -> CGImage? {
        let canvas = CGRect(origin: .zero, size: renderer.renderSize)
        let image = renderer.decorate(frame, at: previewPosition(document)).composited(over: CIImage(color: .black).cropped(to: canvas))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return EffectRenderer.context.createCGImage(image, from: canvas, format: .RGBA8, colorSpace: space)
    }

    /// `watermark`: false for a video that already has a logo of its own.
    static func edit(for document: VideoDocument, title: String, settings: BatchSettings, watermark: Bool = true) -> EditList {
        var edit = EditList(bounds: document.bounds)
        let fade = document.ticks(seconds: fadeSeconds) / document.frameTicks * document.frameTicks
        edit.setTransition(Transition(kind: .black, duration: fade), at: 0)
        edit.fadeOut = fade
        let range = titleRange(document)
        edit.addTitle(Title(text: title, anchor: 0, length: Int64(range.count), x: 0.5, y: 0.5, size: titleSize,
                            fadeSeconds: titleFade, secondLineScale: secondLineScale), at: range.lowerBound)
        edit.logo = watermark ? Self.watermark(settings, canvas: EffectRenderer.renderSize(of: document)) : nil
        return edit
    }

    /// The watermark as a logo at the bottom left of a picture of this size.
    static func watermark(_ settings: BatchSettings, canvas: CGSize) -> Logo? {
        guard let file = settings.watermark, let aspect = imageAspect(file), canvas.width > 0, canvas.height > 0 else { return nil }
        let shorter = min(canvas.width, canvas.height)
        let width = settings.watermarkSize * shorter, height = width / aspect, margin = Self.margin * shorter
        return Logo(file: file, x: (margin + width / 2) / canvas.width, y: 1 - (margin + height / 2) / canvas.height,
                    width: width / canvas.width, opacity: settings.watermarkOpacity)
    }

    /// Width ÷ height of an image.
    static func imageAspect(_ url: URL) -> CGFloat? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat, let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
              width > 0, height > 0 else { return nil }
        return width / height
    }

    /// The videos directly in a folder (no subfolders, no hidden files), sorted like the Finder.
    static func videos(in folder: URL) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentTypeKey]
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys),
                                                               options: [.skipsHiddenFiles, .skipsPackageDescendants])
        return urls.filter { url in
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return false }
            return values.contentType?.conforms(to: .movie) == true
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// The file name of each result in the destination folder: the name of the source with the
    /// extension of the format; " 2", " 3" … where two sources would end up under one name.
    static func destinations(for sources: [URL], in folder: URL, format: VideoFormat) -> [URL] {
        var taken: Set<String> = []
        return sources.map { source in
            let base = source.deletingPathExtension().lastPathComponent
            var name = "\(base).\(format.fileExtension)"
            var number = 2
            while taken.contains(name.precomposedStringWithCanonicalMapping.lowercased()) {
                name = "\(base) \(number).\(format.fileExtension)"
                number += 1
            }
            taken.insert(name.precomposedStringWithCanonicalMapping.lowercased())
            return folder.appendingPathComponent(name)
        }
    }

    static func sameFolder(_ first: URL, _ second: URL) -> Bool {
        let a = first.standardizedFileURL.resolvingSymlinksInPath().path, b = second.standardizedFileURL.resolvingSymlinksInPath().path
        return a == b
    }
}

/// Works through one video: normalises its sound into a hidden file next to the result, then
/// renders and encodes the video with the recipe's effects and that sound.
enum BatchProcessor {
    enum Phase: Equatable, Sendable {
        case sound, video
    }

    /// The share of the progress the two sound passes take (the encoding takes far longer).
    static let soundShare = 0.1
    /// A video whose progress stands still this long is given up (see `watched`).
    static let stallLimit: Duration = .seconds(120)

    static func process(_ source: URL, title: String, watermark: Bool = true, to destination: URL, settings: BatchSettings,
                        progress: @escaping @Sendable (Phase, Double) -> Void) async throws -> SoundNormalizer.Result? {
        try await watched(limit: stallLimit) { moved in
            try await run(source, title: title, watermark: watermark, to: destination, settings: settings) { phase, value in
                moved(value)
                progress(phase, value)
            }
        }
    }

    /// Runs `operation` and cancels it when the progress it reports through `moved` has not changed
    /// for `limit`. Twice in a batch of 224 videos an export stood still for good (the cause is
    /// not known); this way it costs one video and not the rest of the night.
    static func watched<T: Sendable>(limit: Duration,
                                     _ operation: @escaping @Sendable (_ moved: @escaping @Sendable (Double) -> Void) async throws -> T)
        async throws -> T {
        let heartbeat = Heartbeat()
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation { heartbeat.beat($0) } }
            group.addTask {
                while true {
                    try await Task.sleep(for: min(.seconds(1), limit / 4))
                    if heartbeat.idle > limit { throw ExportError.stalled(limit) }
                }
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    /// When the progress last changed.
    private final class Heartbeat: @unchecked Sendable {
        private let lock = NSLock()
        private var value = -1.0
        private var changed = ContinuousClock.now

        func beat(_ value: Double) {
            lock.withLock {
                guard value != self.value else { return }
                self.value = value
                changed = .now
            }
        }

        var idle: Duration { lock.withLock { ContinuousClock.now - changed } }
    }

    private static func run(_ source: URL, title: String, watermark: Bool, to destination: URL, settings: BatchSettings,
                            progress: @escaping @Sendable (Phase, Double) -> Void) async throws -> SoundNormalizer.Result? {
        let document = try await VideoDocument.open(source)
        let edit = BatchRecipe.edit(for: document, title: title, settings: settings, watermark: watermark)
        let soundFile = Exporter.temporaryURL(for: destination.deletingPathExtension().appendingPathExtension("m4a"))
        defer { try? FileManager.default.removeItem(at: soundFile) }
        let token = CancelToken()
        let sound = try await withTaskCancellationHandler {
            try await SoundNormalizer.normalize(document, to: soundFile, token: token) { progress(.sound, $0 * soundShare) }
        } onCancel: {
            token.cancel()
        }
        try Task.checkCancellation()
        try await Exporter.exportEffects(document, edit: edit, codec: settings.codec, sound: sound == nil ? nil : soundFile,
                                         to: destination) { progress(.video, soundShare + $0 * (1 - soundShare)) }
        return sound
    }
}
