import CoreImage
import Foundation
import ImageIO
import Vision

/// Result of analysing a shot: how sharp it is, how many faces it shows, how many have their eyes closed and
/// how well they are captured.
struct ShotInfo: Sendable, Equatable, Codable {
    /// Edge strength of the sharpest regions relative to image contrast. Only meaningful between shots of the
    /// same motif.
    var sharpness: Float?
    var faceCount = 0
    var closedEyesCount = 0
    /// Mean face quality according to Vision (0 … 1): sharpness, lighting, expression, pose.
    var quality: Float?

    var hasClosedEyes: Bool { closedEyesCount > 0 }
}

/// Analyses shots with Apple's built-in frameworks – entirely on the Mac, without internet.
enum ShotAnalyzer {
    /// Smaller faces (share of image height) are ignored – eye detection is unreliable there.
    private static let minimumFaceHeight = 0.06
    private static let analysisSize = 2048
    /// Sharpness is always measured at this size so shots of different resolution are comparable.
    /// Any smaller and shakes of a few pixels would be lost.
    private static let sharpnessSize = 2048
    private static let sharpnessTile = 64

    static func analyze(_ files: [PhotoFile], cache: ScanCache,
                        progress: @escaping PhotoScanner.ProgressHandler) async throws -> [URL: ShotInfo] {
        let results = try await PhotoScanner.mapUsingCache(files, message: "Prüfe Schärfe, Gesichter und Augen …", progress: progress,
                                                           cached: { cache.entry(for: $0)?.shot }) { file in
            let info = autoreleasepool { analyze(file.url) }
            if let info { cache.update(file) { $0.shot = info } }
            return info
        }
        var shots: [URL: ShotInfo] = [:]
        for (file, info) in zip(files, results) { shots[file.url] = info ?? ShotInfo() }
        return shots
    }

    static func analyze(_ url: URL) -> ShotInfo? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: analysisSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        var info = ShotInfo()
        info.sharpness = sharpness(of: image)

        // Eyes: Core Image face detection with built-in blink detection.
        let detector = CIDetector(ofType: CIDetectorTypeFace, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let features = detector?.features(in: CIImage(cgImage: image), options: [CIDetectorEyeBlink: true]) ?? []
        let minimumHeight = Double(image.height) * minimumFaceHeight
        for case let face as CIFaceFeature in features where Double(face.bounds.height) >= minimumHeight {
            info.faceCount += 1
            if face.leftEyeClosed && face.rightEyeClosed { info.closedEyesCount += 1 }
        }

        // Face quality: Vision.
        let request = VNDetectFaceCaptureQualityRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let scores = (request.results ?? [])
            .filter { Double($0.boundingBox.height) >= minimumFaceHeight }
            .compactMap(\.faceCaptureQuality)
        if !scores.isEmpty {
            info.faceCount = max(info.faceCount, scores.count)
            info.quality = scores.reduce(0, +) / Float(scores.count)
        }
        return info
    }

    /// Sharpness as the product of two measures, both taken in the most detailed cells – usually the subject in
    /// focus, not a blurred background or sky:
    /// - Detail energy of the weaker direction (second derivative horizontally or vertically, divided by image
    ///   contrast). Shake only blurs edges across the motion, so this captures it fully.
    /// - Edge steepness: steepest brightness rise relative to a cell's brightness range. Reacts to any blur and
    ///   hardly to noise.
    /// The image is smoothed slightly first so noise doesn't count as detail. Exposure barely changes the value.
    /// Measured: shaky or blurry shots 0.45–0.8 of the sharp one; sharp shots of the same motif, including darker
    /// or recompressed ones, 0.96–1.08.
    static func sharpness(of image: CGImage) -> Float? {
        let scale = Double(sharpnessSize) / Double(max(image.width, image.height))
        let width = Int((Double(image.width) * scale).rounded())
        let height = Int((Double(image.height) * scale).rounded())
        guard width > 16, height > 16 else { return nil }
        var gray = [UInt8](repeating: 255, count: width * height) // white background for transparency
        let drawn = gray.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        // 3 × 3 mean, first by rows, then by columns.
        var rowSums = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = y * width
            for x in 1..<(width - 1) {
                rowSums[row + x] = Float(gray[row + x - 1]) + Float(gray[row + x]) + Float(gray[row + x + 1])
            }
        }
        var pixels = [Float](repeating: 0, count: width * height)
        for y in 1..<(height - 1) {
            let row = y * width
            for x in 1..<(width - 1) {
                pixels[row + x] = (rowSums[row - width + x] + rowSums[row + x] + rowSums[row + width + x]) / 9
            }
        }

        let tile = sharpnessTile
        let columns = (width + tile - 1) / tile
        let tileCount = columns * ((height + tile - 1) / tile)
        var energyX = [Double](repeating: 0, count: tileCount), energyY = energyX, counts = energyX
        var steepest = [Float](repeating: 0, count: tileCount)
        var darkest = [Float](repeating: .infinity, count: tileCount), brightest = steepest
        var sum = 0.0, squares = 0.0
        for y in 3..<(height - 3) {
            let row = y * width
            let tileRow = (y / tile) * columns
            for x in 3..<(width - 3) {
                let i = row + x
                let value = pixels[i]
                let curveX = 2 * value - pixels[i - 2] - pixels[i + 2]
                let curveY = 2 * value - pixels[i - 2 * width] - pixels[i + 2 * width]
                let slopeX = pixels[i + 1] - pixels[i - 1]
                let slopeY = pixels[i + width] - pixels[i - width]
                let t = tileRow + x / tile
                energyX[t] += Double(curveX * curveX)
                energyY[t] += Double(curveY * curveY)
                counts[t] += 1
                steepest[t] = max(steepest[t], (slopeX * slopeX + slopeY * slopeY).squareRoot())
                darkest[t] = min(darkest[t], value)
                brightest[t] = max(brightest[t], value)
                sum += Double(value)
                squares += Double(value * value)
            }
        }
        let total = counts.reduce(0, +)
        guard total > 0 else { return nil }
        let mean = sum / total
        let contrast = max((squares / total - mean * mean).squareRoot(), 4) // nearly uniform: don't overweight noise

        // Detail energy: the 10 % most energetic cells, weaker direction.
        let byEnergy = (0..<tileCount).filter { counts[$0] > 0 }.sorted { energyX[$0] + energyY[$0] > energyX[$1] + energyY[$1] }
        let detailed = byEnergy.prefix(max(1, byEnergy.count / 10))
        let pixelCount = detailed.reduce(0) { $0 + counts[$1] }
        let weakerEnergy = min(detailed.reduce(0) { $0 + energyX[$1] }, detailed.reduce(0) { $0 + energyY[$1] })
        let detail = (weakerEnergy / pixelCount).squareRoot() / contrast

        // Edge steepness: median over the 20 % highest-contrast cells.
        let ranges: [Float] = (0..<tileCount).map { counts[$0] > 0 ? brightest[$0] - darkest[$0] : 0 }
        let byRange = (0..<tileCount).filter { ranges[$0] > 8 }.sorted { ranges[$0] > ranges[$1] }
        guard !byRange.isEmpty else { return nil }
        let steepness = byRange.prefix(max(1, byRange.count / 5)).map { steepest[$0] / ranges[$0] }.sorted()
        return Float(detail) * steepness[steepness.count / 2]
    }
}
