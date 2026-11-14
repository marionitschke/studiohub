import Foundation

/// Everything a scan found out about the images. Groups are computed from it – and recomputed without reading
/// the images again when options change.
struct ScanCatalog: Sendable {
    var scannedCount: Int
    /// Sets of byte-identical files (at least two each).
    var identicalSets: [[PhotoFile]]
    /// Image fingerprints; nil if the scan only looked for byte-identical copies.
    var fingerprints: [Fingerprint]?
    /// Sharpness and faces of analysed photos: motif groups and files where sharpness decides the best version.
    var shots: [URL: ShotInfo] = [:]

    func removing(_ urls: Set<URL>) -> ScanCatalog {
        var copy = self
        copy.identicalSets = identicalSets.map { $0.filter { !urls.contains($0.url) } }.filter { $0.count > 1 }
        copy.fingerprints = fingerprints?.filter { !urls.contains($0.file.url) }
        urls.forEach { copy.shots[$0] = nil }
        return copy
    }
}

/// Builds the displayed groups from the catalog.
///
/// Two levels:
/// 1. “Same picture”: byte-identical, nearly identical fingerprint or – for smooth, low-contrast images whose
///    fingerprint already flips through compression – a nearly identical brightness grid. Each file is either a
///    byte-identical copy, a worse (compressed) version or, at equal quality, a separate shot of the same motif
///    (e.g. a burst shot without movement). At equal resolution, sharpness decides before file size.
/// 2. “Same motif”: shots with the same composition (distance up to the tolerance); only separate shots count,
///    not copies. The fingerprint is position-dependent – head left and head right are different motifs.
enum DuplicateFinder {
    static let defaultTolerance = 10
    static let maxTolerance = 24
    /// Up to this distance (of 128 bits) two files show the same picture.
    static let samePictureDistance = 6
    /// On smooth areas (sky, fog) neighbouring grid cells are almost equally bright and compression flips single
    /// bits. Up to this distance the brightness grid itself decides.
    static let relaxedPictureDistance = 20
    /// Largest mean deviation of the normalised brightness grids for the same picture.
    /// Measured: copies and exports up to 0.06, different photos from 0.34.
    static let maxGridDifference = 0.10
    /// Same resolution but at most 85 % of the file size → more heavily compressed.
    private static let compressedSizeRatio = 0.85

    /// Which files show the same picture and which pictures the same motif – the basis of the groups.
    struct Similarity: Sendable {
        fileprivate let files: [PhotoFile]
        fileprivate let identicalSetOf: [Int]
        /// Per motif its pictures, per picture the indices of its files in `files`.
        /// Without motif search, every picture is its own motif.
        fileprivate let motifs: [[[Int]]]
    }

    /// nil if the catalog has no fingerprints or only byte-identical copies are searched.
    static func similarity(in catalog: ScanCatalog, options: FindOptions) throws -> Similarity? {
        guard options.needsImageAnalysis, let prints = catalog.fingerprints else { return nil }

        // All analysed images plus byte-identical files that could not be analysed.
        var files = prints.map(\.file)
        var horizontal = prints.map(\.horizontal)
        var vertical = prints.map(\.vertical)
        var grids = prints.map(\.grid)
        var hasHash = [Bool](repeating: true, count: files.count)
        var index: [URL: Int] = [:]
        for (i, file) in files.enumerated() { index[file.url] = i }
        for set in catalog.identicalSets {
            for file in set where index[file.url] == nil {
                index[file.url] = files.count
                files.append(file)
                horizontal.append(0)
                vertical.append(0)
                grids.append([])
                hasHash.append(false)
            }
        }

        let count = files.count
        var identicalSetOf = [Int](repeating: -1, count: count)
        var samePicture = UnionFind(count)
        var sameMotif = UnionFind(count)
        for (setNumber, set) in catalog.identicalSets.enumerated() {
            let first = index[set[0].url]!
            for file in set {
                let i = index[file.url]!
                identicalSetOf[i] = setNumber
                samePicture.union(first, i)
                sameMotif.union(first, i)
            }
        }

        let ratios = files.map(aspectRatio)
        let normalizedGrids = grids.map(normalized)
        let motifLimit = options.motif ? options.tolerance : -1
        let searchLimit = max(relaxedPictureDistance, motifLimit)
        for i in 0..<count where hasHash[i] {
            if i % 256 == 0, Task.isCancelled { throw CancellationError() }
            for j in (i + 1)..<count where hasHash[j] {
                let distance = (horizontal[i] ^ horizontal[j]).nonzeroBitCount + (vertical[i] ^ vertical[j]).nonzeroBitCount
                guard distance <= searchLimit, aspectRatiosMatch(ratios[i], ratios[j]) else { continue }
                let isSamePicture = distance <= samePictureDistance
                    || (distance <= relaxedPictureDistance
                        && meanDifference(normalizedGrids[i], normalizedGrids[j]) <= maxGridDifference)
                if isSamePicture {
                    samePicture.union(i, j)
                    sameMotif.union(i, j)
                } else if distance <= motifLimit {
                    sameMotif.union(i, j)
                }
            }
        }

        var pictures: [Int: [Int]] = [:]
        for i in 0..<count { pictures[samePicture.find(i), default: []].append(i) }
        var motifs: [Int: [[Int]]] = [:]
        for members in pictures.values {
            motifs[options.motif ? sameMotif.find(members[0]) : members[0], default: []].append(members)
        }
        return Similarity(files: files, identicalSetOf: identicalSetOf, motifs: Array(motifs.values))
    }

    /// Files whose sharpness decides which version of a picture is best: several distinct files (not
    /// byte-identical) at the picture's highest resolution.
    static func filesComparedBySharpness(in similarity: Similarity) -> [PhotoFile] {
        similarity.motifs.joined().flatMap { members -> [PhotoFile] in
            let top = members.map { similarity.files[$0].pixelCount }.max()
            let candidates = members.filter { similarity.files[$0].pixelCount == top }
            // Byte-identical files count as one content.
            let contents = Set(candidates.map { similarity.identicalSetOf[$0] >= 0 ? -1 - similarity.identicalSetOf[$0] : $0 })
            return contents.count > 1 ? candidates.map { similarity.files[$0] } : []
        }
    }

    static func groups(from similarity: Similarity, options: FindOptions, shots: [URL: ShotInfo]) -> [DuplicateGroup] {
        var result: [DuplicateGroup] = []
        for pictures in similarity.motifs {
            let analyzed = pictures.map {
                PictureCluster(members: $0, files: similarity.files, identicalSetOf: similarity.identicalSetOf,
                               options: options, shots: shots)
            }
            let shotCount = analyzed.reduce(0) { $0 + $1.shotCount }
            if options.motif, shotCount >= max(2, options.minimumMotifSize) {
                result.append(motifGroup(analyzed))
            } else {
                result += analyzed.filter(\.hasCopies).map(\.group)
            }
        }
        return result
    }

    private static func identicalGroup(_ set: [PhotoFile]) -> DuplicateGroup {
        let sorted = set.sorted(by: PhotoFile.keepOrder)
        var roles: [URL: PhotoRole] = [sorted[0].url: .best]
        for file in sorted.dropFirst() { roles[file.url] = .identicalCopy }
        return DuplicateGroup(kind: .copies, files: sorted, roles: roles, suggestedMarks: Set(sorted.dropFirst().map(\.url)))
    }

    /// Several shots of the same motif: the best stays, all others are suggested.
    private static func motifGroup(_ clusters: [PictureCluster]) -> DuplicateGroup {
        let ordered = clusters.sorted { PhotoFile.keepOrder($0.files[0], $1.files[0]) }
        let files = ordered.flatMap(\.files)
        var roles: [URL: PhotoRole] = [:]
        for cluster in ordered {
            roles.merge(cluster.roles) { _, new in new }
            roles[cluster.files[0].url] = .sameMotif
        }
        roles[files[0].url] = .best
        return DuplicateGroup(kind: .motif, files: files, roles: roles, suggestedMarks: Set(files.dropFirst().map(\.url)))
    }

    /// Grid without influence of overall brightness and contrast (mean 0, deviation 1).
    /// For nearly uniform images the deviation is clamped so noise does not dominate.
    private static func normalized(_ grid: [UInt8]) -> [Double] {
        guard !grid.isEmpty else { return [] }
        let values = grid.map(Double.init)
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        let spread = max(variance.squareRoot(), 3)
        return values.map { ($0 - mean) / spread }
    }

    private static func meanDifference(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        return zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(a.count)
    }

    private static func aspectRatio(_ file: PhotoFile) -> Double {
        guard let w = file.pixelWidth, let h = file.pixelHeight, w > 0, h > 0 else { return 0 }
        return Double(w) / Double(h)
    }

    /// A crop is not a duplicate – the aspect ratio must be (almost) equal.
    private static func aspectRatiosMatch(_ a: Double, _ b: Double) -> Bool {
        guard a > 0, b > 0 else { return true }
        return abs(a - b) / max(a, b) < 0.03
    }

    /// Files showing the same picture, with each file's role.
    private struct PictureCluster {
        let files: [PhotoFile]
        var roles: [URL: PhotoRole] = [:]
        var suggested: Set<URL> = []
        /// Contains copies that should be shown according to the options.
        var hasCopies = false
        /// Separate shots (best file plus same-motif files), without copies.
        var shotCount = 1

        init(members: [Int], files allFiles: [PhotoFile], identicalSetOf: [Int], options: FindOptions, shots: [URL: ShotInfo]) {
            var sorted = members.sorted { PhotoFile.keepOrder(allFiles[$0], allFiles[$1]) }
            // At equal resolution sharpness comes first: a shaky burst shot with noise is often the largest file but not
            // the best.
            func sharpness(_ member: Int) -> Float { shots[allFiles[member].url]?.sharpness ?? 0 }
            let topPixels = allFiles[sorted[0]].pixelCount
            let top = sorted.indices.filter { allFiles[sorted[$0]].pixelCount == topPixels }
            let sharpest = top.map { sharpness(sorted[$0]) }.max() ?? 0
            if sharpest > sharpness(sorted[0]) * DuplicateFinder.clearlySharperFactor,
               let position = top.first(where: { sharpness(sorted[$0]) >= sharpest * DuplicateFinder.equallySharpFactor }) {
                sorted.insert(sorted.remove(at: position), at: 0)
            }
            files = sorted.map { allFiles[$0] }
            guard sorted.count > 1 else {
                roles[files[0].url] = .sameMotif
                return
            }

            let best = files[0]
            roles[best.url] = .best
            var seenSets: Set<Int> = [identicalSetOf[sorted[0]]]
            for (position, member) in sorted.enumerated().dropFirst() {
                let file = files[position]
                let set = identicalSetOf[member]
                if set >= 0, seenSets.contains(set) {
                    roles[file.url] = .identicalCopy
                    if options.identical { suggested.insert(file.url); hasCopies = true }
                } else if DuplicateFinder.isLowerQuality(file, than: best) {
                    roles[file.url] = .compressed
                    if options.compressed { suggested.insert(file.url); hasCopies = true }
                } else {
                    roles[file.url] = .sameMotif
                    shotCount += 1
                }
                seenSets.insert(set)
            }
        }

        var group: DuplicateGroup {
            DuplicateGroup(kind: .copies, files: files, roles: roles, suggestedMarks: suggested)
        }
    }

    fileprivate static func isLowerQuality(_ file: PhotoFile, than best: PhotoFile) -> Bool {
        if file.pixelCount > 0, best.pixelCount > 0, file.pixelCount != best.pixelCount {
            return file.pixelCount < best.pixelCount
        }
        return Double(file.size) <= Double(best.size) * compressedSizeRatio
    }
}

/// Groups indices connected directly or through intermediate steps.
private struct UnionFind {
    private var parent: [Int]

    init(_ count: Int) {
        parent = Array(0..<count)
    }

    mutating func find(_ index: Int) -> Int {
        var i = index
        while parent[i] != i {
            parent[i] = parent[parent[i]]
            i = parent[i]
        }
        return i
    }

    mutating func union(_ a: Int, _ b: Int) {
        let rootA = find(a), rootB = find(b)
        if rootA != rootB { parent[rootB] = rootA }
    }
}

// MARK: - Sharpness and faces

extension DuplicateFinder {
    /// A shot only counts as sharper than the current best from this factor on. Measured: sharp shots of the same
    /// motif differ by up to 8 %, slightly blurry ones reach at most 0.81.
    static let clearlySharperFactor: Float = 1.2
    /// From this share of the sharpest shot's sharpness, shots count as equally sharp – then resolution, file size
    /// and name decide as usual.
    static let equallySharpFactor: Float = 0.9
    /// Shots below this share of the sharpest shot in their group count as blurry.
    static let blurryFactor: Float = 0.7

    /// Builds the groups. Analyses sharpness where it decides the best version of a picture, and faces in motif
    /// groups. Photos already analysed (from `catalog.shots` or the cache) are not checked again; new results are
    /// returned as well.
    static func groupsAnalyzingShots(in catalog: ScanCatalog, options: FindOptions, cache: ScanCache,
                                     progress: @escaping PhotoScanner.ProgressHandler) async throws -> (groups: [DuplicateGroup], shots: [URL: ShotInfo]) {
        guard let similarity = try similarity(in: catalog, options: options) else {
            return (options.identical ? catalog.identicalSets.map(identicalGroup) : [], catalog.shots)
        }
        var shots = catalog.shots
        func analyze(_ files: [PhotoFile]) async throws {
            let unchecked = files.filter { shots[$0.url] == nil }
            guard !unchecked.isEmpty else { return }
            shots.merge(try await ShotAnalyzer.analyze(unchecked, cache: cache, progress: progress)) { _, new in new }
        }
        try await analyze(filesComparedBySharpness(in: similarity))
        let groups = groups(from: similarity, options: options, shots: shots)
        try await analyze(groups.filter { $0.kind == .motif }.flatMap(\.files))
        return (groups.map { rankedByShots($0, shots: shots) }, shots)
    }

    /// Picks the best shot in a motif group.
    /// - With people: nobody has their eyes closed, not blurry, most faces, highest face quality.
    /// - Without people: the sharpest shot if it is clearly sharper than the best by resolution and file size;
    ///   otherwise that one stays.
    static func rankedByShots(_ group: DuplicateGroup, shots: [URL: ShotInfo]) -> DuplicateGroup {
        guard group.kind == .motif else { return group }
        var group = group
        // Only separate shots compete, not copies.
        let candidates = group.files.indices.filter { [.best, .sameMotif].contains(group.roles[group.files[$0].url]) }
        func shot(_ index: Int) -> ShotInfo { shots[group.files[index].url] ?? ShotInfo() }
        func sharpness(_ index: Int) -> Float { shot(index).sharpness ?? 0 }

        let sharpest = candidates.map(sharpness).max() ?? 0
        let blurry = Set(candidates.filter { shot($0).sharpness.map { $0 < sharpest * blurryFactor } ?? false })
        group.blurry = Set(blurry.map { group.files[$0].url })
        group.closedEyes = Set(group.files.map(\.url).filter { shots[$0]?.hasClosedEyes == true })

        let bestIndex: Int?
        if candidates.contains(where: { shot($0).faceCount > 0 }) {
            func rank(_ index: Int) -> (Int, Int, Int, Float, Float, Int) {
                let info = shot(index)
                return (info.closedEyesCount, blurry.contains(index) ? 1 : 0, -info.faceCount,
                        -(info.quality ?? -1), -sharpness(index), index)
            }
            bestIndex = candidates.min { rank($0) < rank($1) }
        } else if sharpest > sharpness(0) * clearlySharperFactor {
            bestIndex = candidates.first { sharpness($0) >= sharpest * equallySharpFactor }
        } else {
            bestIndex = nil
        }
        guard let bestIndex, bestIndex != 0 else { return group }

        let previousBest = group.files[0]
        let newBest = group.files.remove(at: bestIndex)
        group.files.insert(newBest, at: 0)
        group.roles[previousBest.url] = .sameMotif
        group.roles[newBest.url] = .best
        group.suggestedMarks = Set(group.files.dropFirst().map(\.url))
        return group
    }
}
