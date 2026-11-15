import AVFoundation
import CoreGraphics
import Foundation

/// Finds a logo that is already burned into the bottom left corner of a video, where the batch
/// would put its watermark. Such a logo stays put while the picture underneath changes: in the
/// average of frames from the whole video its edges stay sharp, everything else blurs. The same
/// test on the bottom right corner tells a logo from a still scene (a camera on a tripod), whose
/// sharp edges are not confined to one corner.
enum BurnedInLogo {
    struct Score: Equatable, Sendable {
        /// Share of the bottom left corner covered by edges that stay (0…1).
        var left: Double
        /// The same for the bottom right corner.
        var right: Double

        var hasLogo: Bool { left >= 0.04 && left >= 3 * right }
    }

    static let frames = 20
    /// The corners looked at, as fractions of width and height.
    static let cornerWidth = 0.3, cornerHeight = 0.22
    private static let analysisWidth = 256

    static func detect(_ document: VideoDocument) async throws -> Score {
        try await score(document.asset, from: document.time(document.bounds.lowerBound), length: document.time(document.length))
    }

    /// nil when the video cannot be read.
    static func hasLogo(_ url: URL) async -> Bool? {
        guard let document = try? await VideoDocument.open(url), let score = try? await detect(document) else { return nil }
        return score.hasLogo
    }

    /// Frames from 10 % to 90 % of the video, so that fades at the start and end do not count.
    static func score(_ asset: AVAsset, from start: CMTime, length: CMTime) async throws -> Score {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: analysisWidth * 2, height: analysisWidth * 2)
        let tolerance = CMTime(seconds: min(2, length.seconds / Double(frames * 4)), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let times = (0..<frames).map { index in
            start + CMTimeMultiplyByFloat64(length, multiplier: 0.1 + 0.8 * Double(index) / Double(frames - 1))
        }
        var left: Corner?, right: Corner?
        for await result in generator.images(for: times) {
            try Task.checkCancellation()
            guard let image = try? result.image, let gray = Gray(image, width: analysisWidth) else { continue }
            if left == nil {
                let width = Int(Double(gray.width) * cornerWidth), height = Int(Double(gray.height) * cornerHeight)
                left = Corner(x: 0, y: gray.height - height, width: width, height: height)
                right = Corner(x: gray.width - width, y: gray.height - height, width: width, height: height)
            }
            left?.add(gray)
            right?.add(gray)
        }
        guard let left, let right, left.count >= frames / 2 else { return Score(left: 0, right: 0) }
        return Score(left: left.staticEdges, right: right.staticEdges)
    }

    /// A frame as 8-bit grey, `width` pixels wide, rows from the top.
    private struct Gray {
        let width: Int, height: Int
        let values: [UInt8]

        init?(_ image: CGImage, width: Int) {
            guard image.width > 0, image.height > 0 else { return nil }
            let height = max(8, Int((Double(width) * Double(image.height) / Double(image.width)).rounded()))
            var values = [UInt8](repeating: 0, count: width * height)
            let drawn = values.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                context.interpolationQuality = .medium
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            self.width = width
            self.height = height
            self.values = values
        }
    }

    /// Sums over the frames for one corner: the brightness, and the strength of the edges.
    private struct Corner {
        let x: Int, y: Int, width: Int, height: Int
        var brightness: [Float]
        var edges: [Float]
        var count = 0

        init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            brightness = Array(repeating: 0, count: width * height)
            edges = Array(repeating: 0, count: width * height)
        }

        mutating func add(_ gray: Gray) {
            guard x + width <= gray.width, y + height <= gray.height else { return }
            func value(_ column: Int, _ row: Int) -> Float {
                Float(gray.values[(y + min(max(row, 0), height - 1)) * gray.width + x + min(max(column, 0), width - 1)])
            }
            for row in 0..<height {
                for column in 0..<width {
                    brightness[row * width + column] += value(column, row)
                    let dx = value(column + 1, row) - value(column - 1, row), dy = value(column, row + 1) - value(column, row - 1)
                    edges[row * width + column] += (dx * dx + dy * dy).squareRoot()
                }
            }
            count += 1
        }

        /// Share of the pixels where the average picture has a clear edge that is nearly as strong as
        /// the edges in the single frames: an edge that is there in all of them.
        var staticEdges: Double {
            guard count > 0, width > 2, height > 2 else { return 0 }
            let scale = 1 / Float(count)
            var found = 0
            for row in 1..<(height - 1) {
                for column in 1..<(width - 1) {
                    let index = row * width + column
                    let dx = brightness[index + 1] - brightness[index - 1], dy = brightness[index + width] - brightness[index - width]
                    let averaged = (dx * dx + dy * dy).squareRoot() * scale
                    if averaged > 24, averaged > 0.7 * edges[index] * scale { found += 1 }
                }
            }
            return Double(found) / Double((width - 2) * (height - 2))
        }
    }
}
