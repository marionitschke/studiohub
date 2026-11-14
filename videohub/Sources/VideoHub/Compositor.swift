import AVFoundation
import CoreImage
import CoreText
import ImageIO

/// Everything drawn over and onto the pictures: brightness ramps, titles and the logo. The preview
/// can swap it while a title is dragged, without building a new composition.
struct EffectContent: Sendable {
    var ramps: [EffectLayout.Ramp] = []
    var titles: [PlacedTitle] = []
    var logo: Logo?

    init(edit: EditList, layout: EffectLayout) {
        ramps = layout.ramps
        titles = edit.placedTitles
        logo = edit.logo
    }
}

/// Renders the frames of an edit with effects: picks the source frame (or blends two), puts titles
/// and the logo on top and darkens the picture for fades. The output is SDR (Rec. 709) in the size
/// of the picture as it is shown, with the rotation of the source applied.
final class EffectRenderer: @unchecked Sendable {
    let renderSize: CGSize
    let frame: Int64
    let timescale: CMTimeScale
    private let orientation: CGImagePropertyOrientation
    private let lock = NSLock()
    private var content: EffectContent
    private var titleImages: [TitleArt.Key: CIImage] = [:]
    private var logoImage: (key: LogoKey, image: CIImage?)?

    private struct LogoKey: Equatable {
        var file: URL
        var width: Double
    }

    static let context = CIContext(options: [.cacheIntermediates: false])
    static let outputColorSpace = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()

    init(document: VideoDocument, content: EffectContent) {
        // Encoders want even sizes.
        renderSize = CGSize(width: max(2, (document.displaySize.width / 2).rounded() * 2),
                            height: max(2, (document.displaySize.height / 2).rounded() * 2))
        frame = document.frameTicks
        timescale = document.timescale
        orientation = Self.orientation(of: document.transform)
        self.content = content
    }

    func update(_ content: EffectContent) {
        lock.withLock { self.content = content }
    }

    /// The image orientation that turns the stored picture upright, from the track's transform.
    static func orientation(of transform: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (transform.a.rounded(), transform.b.rounded(), transform.c.rounded(), transform.d.rounded()) {
        case (0, 1, -1, 0): .right
        case (0, -1, 1, 0): .left
        case (-1, 0, 0, -1): .down
        case (-1, 0, 0, 1): .upMirrored
        case (1, 0, 0, -1): .downMirrored
        case (0, 1, 1, 0): .leftMirrored
        case (0, -1, -1, 0): .rightMirrored
        default: .up
        }
    }

    func render(_ request: AVAsynchronousVideoCompositionRequest, _ instruction: EffectInstruction) throws -> CVPixelBuffer {
        guard let output = request.renderContext.newPixelBuffer() else { throw ExportError.failed("Kein Bildpuffer frei.") }
        let time = request.compositionTime
        let position = CMTimeConvertScale(time, timescale: timescale, method: .roundHalfAwayFromZero).value
        let content = lock.withLock { self.content }
        let canvas = CGRect(origin: .zero, size: renderSize)
        let black = CIImage(color: .black).cropped(to: canvas)

        var image = picture(request, instruction.tracks.first) ?? black
        if instruction.tracks.count > 1, let blend = instruction.blend {
            let target = picture(request, instruction.tracks[1]) ?? black
            let progress = EffectLayout.progress(position, in: blend, frame: frame)
            image = image.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: target,
                kCIInputTimeKey: progress,
            ])
        }
        for placed in content.titles where placed.range.contains(position) {
            let opacity = titleOpacity(placed, at: position)
            guard opacity > 0, let art = titleImage(placed.title) else { continue }
            let size = art.extent.size
            let origin = CGPoint(x: (placed.title.x * renderSize.width - size.width / 2).rounded(),
                                 y: ((1 - placed.title.y) * renderSize.height - size.height / 2).rounded())
            image = Self.faded(art, opacity).transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y)).composited(over: image)
        }
        if let logo = content.logo, let art = logoImage(logo) {
            let size = art.extent.size
            let origin = CGPoint(x: (logo.x * renderSize.width - size.width / 2).rounded(),
                                 y: ((1 - logo.y) * renderSize.height - size.height / 2).rounded())
            image = Self.faded(art, logo.opacity).transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
                .composited(over: image)
        }
        let level = EffectLayout(ramps: content.ramps).level(at: position, frame: frame)
        if level < 1 {
            let value = CGFloat(max(0, level))
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: value, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: value, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: value, w: 0),
            ])
        }
        Self.context.render(image.composited(over: black).cropped(to: canvas), to: output, bounds: canvas,
                            colorSpace: Self.outputColorSpace)
        return output
    }

    /// A source frame, upright and filling the picture.
    private func picture(_ request: AVAsynchronousVideoCompositionRequest, _ track: CMPersistentTrackID?) -> CIImage? {
        guard let track, let buffer = request.sourceFrame(byTrackID: track) else { return nil }
        // AVFoundation hands the frames over in the composition's colour space (Rec. 709).
        var image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: Self.outputColorSpace]).oriented(orientation)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let size = image.extent.size
        if size.width > 0, size.height > 0, size != renderSize {
            image = image.transformed(by: CGAffineTransform(scaleX: renderSize.width / size.width, y: renderSize.height / size.height))
        }
        return image
    }

    /// Titles fade in and out over 0.3 s (a quarter of a short title).
    private func titleOpacity(_ placed: PlacedTitle, at position: Int64) -> Double {
        let fade = Double(min(Int64(0.3 * Double(timescale)), (placed.end - placed.start) / 4))
        guard fade > 0 else { return 1 }
        return min(1, Double(position - placed.start + frame) / fade, Double(placed.end - position) / fade)
    }

    private func titleImage(_ title: Title) -> CIImage? {
        let key = TitleArt.Key(title: title, canvas: renderSize)
        if let cached = lock.withLock({ titleImages[key] }) { return cached }
        guard let art = TitleArt.image(title, canvas: renderSize) else { return nil }
        let image = CIImage(cgImage: art)
        lock.withLock {
            if titleImages.count > 40 { titleImages.removeAll() }
            titleImages[key] = image
        }
        return image
    }

    private func logoImage(_ logo: Logo) -> CIImage? {
        let key = LogoKey(file: logo.file, width: logo.width)
        if let cached = lock.withLock({ logoImage }), cached.key == key { return cached.image }
        var image: CIImage?
        if let source = CGImageSourceCreateWithURL(logo.file as CFURL, nil),
           let art = CGImageSourceCreateImageAtIndex(source, 0, nil), art.width > 0 {
            let scale = logo.width * renderSize.width / CGFloat(art.width)
            image = CIImage(cgImage: art).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        lock.withLock { logoImage = (key, image) }
        return image
    }

    /// The image with its alpha (and so its colour) scaled.
    private static func faded(_ image: CIImage, _ opacity: Double) -> CIImage {
        guard opacity < 1 else { return image }
        return image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0, opacity)))])
    }
}

private extension EffectLayout {
    init(ramps: [Ramp]) {
        self.init()
        self.ramps = ramps
    }
}

/// Titles as images: SF Pro bold, centred lines, white with a soft shadow or black, optionally on
/// a half-transparent box. Sizes are in pixels of the picture.
enum TitleArt {
    struct Key: Hashable {
        var text: String
        var size: Double
        var dark: Bool
        var bar: Bool
        var canvas: CGSize

        init(title: Title, canvas: CGSize) {
            text = title.text
            size = title.size
            dark = title.dark
            bar = title.bar
            self.canvas = canvas
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(text)
            hasher.combine(size)
            hasher.combine(dark)
            hasher.combine(bar)
            hasher.combine(canvas.width)
            hasher.combine(canvas.height)
        }
    }

    private struct Layout {
        var framesetter: CTFramesetter
        var text: CGSize
        var padding: CGSize
        var fontSize: CGFloat

        var size: CGSize { CGSize(width: ceil(text.width + 2 * padding.width), height: ceil(text.height + 2 * padding.height)) }
    }

    private static func layout(_ title: Title, canvas: CGSize) -> Layout? {
        let text = title.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, canvas.width > 0, canvas.height > 0 else { return nil }
        let fontSize = max(6, CGFloat(title.size) * min(canvas.width, canvas.height))
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        var alignment = CTTextAlignment.center
        let paragraph = withUnsafeBytes(of: &alignment) { pointer in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size,
                                                  value: pointer.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let color = CGColor(gray: title.dark ? 0 : 1, alpha: 1)
        let string = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let padding = CGSize(width: (fontSize * 0.45).rounded(.up), height: (fontSize * 0.25).rounded(.up))
        let limit = CGSize(width: max(fontSize, canvas.width * 0.92 - 2 * padding.width), height: .greatestFiniteMagnitude)
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil, limit, nil)
        return Layout(framesetter: framesetter, text: CGSize(width: ceil(fitted.width), height: ceil(fitted.height)),
                      padding: padding, fontSize: fontSize)
    }

    /// The size of a title's image in the picture, for hit testing in the preview.
    static func size(_ title: Title, canvas: CGSize) -> CGSize? {
        layout(title, canvas: canvas)?.size
    }

    static func image(_ title: Title, canvas: CGSize) -> CGImage? {
        guard let layout = layout(title, canvas: canvas) else { return nil }
        let size = layout.size
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if title.bar {
            let radius = layout.fontSize * 0.22
            let box = CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: radius, cornerHeight: radius, transform: nil)
            context.setFillColor(CGColor(gray: title.dark ? 1 : 0, alpha: title.dark ? 0.6 : 0.45))
            context.addPath(box)
            context.fillPath()
        }
        if !title.dark {
            context.setShadow(offset: CGSize(width: 0, height: -layout.fontSize * 0.04), blur: layout.fontSize * 0.14,
                              color: CGColor(gray: 0, alpha: 0.65))
        }
        let rect = CGRect(origin: CGPoint(x: layout.padding.width, y: layout.padding.height), size: layout.text)
        let frame = CTFramesetterCreateFrame(layout.framesetter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, context)
        return context.makeImage()
    }
}

/// One stretch of the composition: one source track, or two that blend.
final class EffectInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let tracks: [CMPersistentTrackID]
    /// Where the blend runs (sequence ticks), when there are two tracks.
    let blend: Range<Int64>?
    let renderer: EffectRenderer

    init(timeRange: CMTimeRange, tracks: [CMPersistentTrackID], blend: Range<Int64>?, renderer: EffectRenderer) {
        self.timeRange = timeRange
        self.tracks = tracks
        self.blend = blend
        self.renderer = renderer
        requiredSourceTrackIDs = tracks.map { NSNumber(value: $0) }
    }
}

/// The custom compositor AVFoundation creates for compositions with effects. It renders on its own
/// queue; source frames arrive converted to SDR (it does not take HDR or wide colour frames).
final class EffectCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.videohub.compositor", qos: .userInitiated)
    private let lock = NSLock()
    private var generation = 0

    private static let pixelAttributes: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
    ]

    var sourcePixelBufferAttributes: [String: any Sendable]? { Self.pixelAttributes }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { Self.pixelAttributes }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let generation = lock.withLock { self.generation }
        queue.async { [self] in
            guard generation == lock.withLock({ self.generation }) else {
                request.finishCancelledRequest()
                return
            }
            guard let instruction = request.videoCompositionInstruction as? EffectInstruction else {
                request.finish(with: ExportError.failed("Unbekannte Anweisung für den Bildaufbau."))
                return
            }
            do {
                request.finish(withComposedVideoFrame: try instruction.renderer.render(request, instruction))
            } catch {
                request.finish(with: error)
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        lock.withLock { generation += 1 }
    }
}

extension Composer {
    struct Effects {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition
        let audioMix: AVAudioMix?
        let renderer: EffectRenderer
    }

    /// The edit with effects: the parts on one or two video tracks (dissolves need both), a custom
    /// compositor for the picture, volume ramps for the fades.
    static func effects(_ document: VideoDocument, edit: EditList) throws -> Effects {
        let layout = edit.effectLayout(frame: document.frameTicks)
        let composition = AVMutableComposition()
        var trackIDs: [CMPersistentTrackID] = []
        for index in 0..<layout.trackCount {
            guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw ExportError.failed("Die Bildspur lässt sich nicht anlegen.")
            }
            var end: Int64 = 0
            for clip in layout.clips where clip.track == index && !clip.source.isEmpty {
                if clip.position > end {
                    track.insertEmptyTimeRange(CMTimeRange(start: document.time(end), end: document.time(clip.position)))
                }
                let source = CMTimeRange(start: document.time(clip.source.lowerBound), duration: document.time(Int64(clip.source.count)))
                try track.insertTimeRange(source, of: document.videoTrack, at: document.time(clip.position))
                end = clip.end
            }
            trackIDs.append(track.trackID)
        }
        let audioTrack = try addSound(to: composition, document, edit.soundSegments)

        let renderer = EffectRenderer(document: document, content: EffectContent(edit: edit, layout: layout))
        var marks: Set<Int64> = [0, layout.length]
        for clip in layout.clips { marks.formUnion([clip.position, clip.end]) }
        for blend in layout.blends { marks.formUnion([blend.range.lowerBound, blend.range.upperBound]) }
        let sorted = marks.filter { $0 >= 0 && $0 <= layout.length }.sorted()
        var instructions: [EffectInstruction] = []
        for (from, to) in zip(sorted, sorted.dropFirst()) where from < to {
            var tracks: [CMPersistentTrackID] = []
            var blendRange: Range<Int64>?
            if let blend = layout.blends.first(where: { $0.range.lowerBound <= from && $0.range.upperBound >= to }) {
                tracks = [trackIDs[blend.from], trackIDs[blend.to]]
                blendRange = blend.range
            } else if let clip = layout.clips.first(where: { $0.position <= from && $0.end >= to }) {
                tracks = [trackIDs[clip.track]]
            }
            // Neighbours on the same single track become one instruction.
            if blendRange == nil, let last = instructions.last, last.blend == nil, last.tracks == tracks {
                instructions[instructions.count - 1] = EffectInstruction(
                    timeRange: CMTimeRange(start: last.timeRange.start, end: document.time(to)), tracks: tracks, blend: nil, renderer: renderer)
            } else {
                instructions.append(EffectInstruction(timeRange: CMTimeRange(start: document.time(from), end: document.time(to)),
                                                      tracks: tracks, blend: blendRange, renderer: renderer))
            }
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = EffectCompositor.self
        videoComposition.instructions = instructions
        videoComposition.renderSize = renderer.renderSize
        videoComposition.frameDuration = document.time(document.frameTicks)
        videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        let mix = audioTrack.flatMap { Composer.audioMix(for: $0, ramps: layout.ramps, document: document) }
        return Effects(composition: composition, videoComposition: videoComposition, audioMix: mix, renderer: renderer)
    }

    /// Volume ramps that follow the fades to and from black; nil without fades.
    static func audioMix(for track: AVAssetTrack, ramps: [EffectLayout.Ramp], document: VideoDocument) -> AVAudioMix? {
        guard !ramps.isEmpty else { return nil }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        let sorted = ramps.sorted { $0.range.lowerBound < $1.range.lowerBound }
        for (index, ramp) in sorted.enumerated() {
            let range = CMTimeRange(start: document.time(ramp.range.lowerBound), end: document.time(ramp.range.upperBound))
            parameters.setVolumeRamp(fromStartVolume: Float(ramp.from), toEndVolume: Float(ramp.to), timeRange: range)
            // A ramp's end volume holds until the next one: back to full volume after a dip without a way back.
            let next = index + 1 < sorted.count ? sorted[index + 1].range.lowerBound : nil
            if ramp.to < 1, next != ramp.range.upperBound {
                parameters.setVolume(1, at: document.time(ramp.range.upperBound))
            }
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }
}
