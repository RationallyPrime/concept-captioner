import AppKit
import ConceptCore
import CryptoKit
import ImageIO
import Synchronization
import Vision

struct ImageAnalysis: Codable, Equatable {
    var faces: [CGRect] = []
    var warnings: [String] = []
    var width = 0
    var height = 0
    var duplicateOf: String?
}

/// What the Mac learned about one file's content, cached in the project by content hash
/// (`<project>/.conceptstudio/vision-cache.json`, app-only, never published). Warnings that compare
/// photos with each other (duplicates, near-duplicates) are recomputed from the cached feature prints
/// on every pass, because they depend on the whole set.
struct CachedImageAnalysis: Codable, Equatable {
    /// Bump when the per-file checks change so older entries are recomputed.
    static let version = 1
    var version = Self.version
    var analysis: ImageAnalysis
    /// The archived `VNFeaturePrintObservation`, nil when Vision produced none.
    var featurePrint: Data?
}

struct VisionCache: Codable, Equatable {
    static let fileName = "vision-cache.json"
    var entries: [String: CachedImageAnalysis] = [:]

    static func url(in projectDirectory: URL) -> URL {
        ProjectAppState.folder(in: projectDirectory).appendingPathComponent(fileName)
    }

    static func load(from projectDirectory: URL) -> VisionCache {
        guard let data = try? Data(contentsOf: url(in: projectDirectory)),
              let cache = try? JSONDecoder().decode(VisionCache.self, from: data) else { return VisionCache() }
        return cache
    }

    func save(to projectDirectory: URL) throws {
        try FileManager.default.createDirectory(
            at: ProjectAppState.folder(in: projectDirectory), withIntermediateDirectories: true
        )
        try AtomicFile.write(JSONEncoder().encode(self), to: Self.url(in: projectDirectory))
    }
}

actor VisionInspector {
    /// Vision's synchronous requests can wait for their own workers. Keep them off Swift's
    /// cooperative executor and serialize them across the app's separate inspector instances.
    private static let visionQueue = DispatchQueue(label: "ConceptStudio.Vision", qos: .userInitiated)
    // Conservative revision-2 proposal gates, not a calibrated identity-recognition model.
    static let similarPhotoDistance: Float = 0.08
    static let faceProposalDistance: Float = 0.10
    static let faceAmbiguityMargin: Float = 0.04

    static func faceCandidate(_ matches: [(String, Float)]) -> String? {
        let ordered = matches.filter(\.1.isFinite).sorted { $0.1 < $1.1 }
        guard let best = ordered.first, best.1 <= faceProposalDistance else { return nil }
        if ordered.count > 1, ordered[1].1 - best.1 < faceAmbiguityMargin { return nil }
        return best.0
    }

    static func contentHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Hash files in bounded chunks on the nonisolated async executor, including large clips.
    static func contentHash(fileURL: URL) async throws -> String {
        let file = try FileHandle(forReadingFrom: fileURL)
        defer { try? file.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            guard let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty else { break }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func analyze(_ urls: [URL]) async throws -> [String: ImageAnalysis] {
        try await analyze(urls, cacheIn: nil)
    }

    /// Analyse `urls` in order, reusing and updating the cache stored in `cacheDirectory` (a project
    /// folder; nil keeps nothing). `progress` receives each photo's final result as soon as it is known.
    func analyze(
        _ urls: [URL],
        cacheIn cacheDirectory: URL?,
        progress: (@Sendable (String, ImageAnalysis) async -> Void)? = nil
    ) async throws -> [String: ImageAnalysis] {
        var cache = cacheDirectory.map(VisionCache.load(from:)) ?? VisionCache()
        var results: [String: ImageAnalysis] = [:]
        var hashes: [String: String] = [:]
        var prints: [(String, VNFeaturePrintObservation)] = []
        var used: Set<String> = []
        for url in urls {
            try Task.checkCancellation()
            let name = url.lastPathComponent
            let hash = try await Self.contentHash(fileURL: url)
            used.insert(hash)
            let entry: CachedImageAnalysis
            if Sources.isVideo(Sources.suffix(of: name)) {
                let info = try await MediaEditor.videoInfo(url: url)
                entry = CachedImageAnalysis(
                    analysis: ImageAnalysis(width: info.width, height: info.height), featurePrint: nil
                )
            } else {
                if let cached = cache.entries[hash], cached.version == CachedImageAnalysis.version {
                    entry = cached
                } else {
                    let data = try Data(contentsOf: url)
                    entry = try await Self.performVision { _ in try Self.inspect(data) }
                }
            }
            cache.entries[hash] = entry
            let observation = entry.featurePrint.flatMap(Self.unarchive)
            let analysis = try Self.compare(
                entry.analysis, name: name, hash: hash, observation: observation, hashes: hashes, prints: prints
            )
            if hashes[hash] == nil, let observation { prints.append((name, observation)) }
            hashes[hash] = hashes[hash] ?? name
            results[name] = analysis
            await progress?(name, analysis)
        }
        if let cacheDirectory {
            cache.entries = cache.entries.filter { used.contains($0.key) }
            try? cache.save(to: cacheDirectory)
        }
        return results
    }

    private static func performVision<Value: Sendable>(
        _ operation: @escaping @Sendable (_ checkCancellation: @Sendable () throws -> Void) throws -> Value
    ) async throws -> Value {
        let cancelled = Mutex(false)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result: Value = try await withCheckedThrowingContinuation { continuation in
                visionQueue.async {
                    let checkCancellation: @Sendable () throws -> Void = {
                        if cancelled.withLock({ $0 }) { throw CancellationError() }
                    }
                    do {
                        try checkCancellation()
                        try continuation.resume(returning: operation(checkCancellation))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    /// The checks that depend only on this file's content.
    private static func inspect(_ data: Data) throws -> CachedImageAnalysis {
        var analysis = ImageAnalysis()
        guard let image = image(data) else {
            analysis.warnings = ["This photo cannot be decoded. Import another copy."]
            return CachedImageAnalysis(analysis: analysis, featurePrint: nil)
        }
        analysis.width = image.width
        analysis.height = image.height
        if min(image.width, image.height) < 512 {
            analysis.warnings.append("Small image: details may not survive training. Prefer a larger original.")
        }
        let faces = VNDetectFaceCaptureQualityRequest()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .fast
        let feature = featureRequest()
        try VNImageRequestHandler(cgImage: image).perform([faces, text, feature])
        analysis.faces = faces.results?.map(\.boundingBox).sorted { $0.midX < $1.midX } ?? []
        if faces.results?.contains(where: { ($0.faceCaptureQuality ?? 1) < 0.3 }) == true {
            analysis.warnings.append("A face is hard to see. Check focus, angle and lighting before using it.")
        }
        if !(text.results ?? []).isEmpty {
            analysis.warnings
                .append(
                    "Possible text detected. Captions should describe signs and logos without copying the words."
                )
        }
        let print = try feature.results?.first.map {
            try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
        }
        return CachedImageAnalysis(analysis: analysis, featurePrint: print)
    }

    /// Add the warnings that compare this photo with the ones before it.
    private static func compare(
        _ base: ImageAnalysis,
        name: String,
        hash: String,
        observation: VNFeaturePrintObservation?,
        hashes: [String: String],
        prints: [(String, VNFeaturePrintObservation)]
    ) throws -> ImageAnalysis {
        var analysis = base
        if let original = hashes[hash] {
            analysis.duplicateOf = original
            analysis.warnings.append("Exact duplicate of \(original). Repeated samples can overemphasize one scene.")
        } else if let observation {
            for (other, print) in prints {
                var distance: Float = 0
                try observation.computeDistance(&distance, to: print)
                if distance <= similarPhotoDistance {
                    analysis.duplicateOf = other
                    analysis.warnings
                        .append("Visually similar to \(other). Inspect these candidates and exclude unwanted copies.")
                    break
                }
            }
        }
        return analysis
    }

    private static func unarchive(_ data: Data) -> VNFeaturePrintObservation? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
    }

    func proposals(images: [URL], references: [String: URL]) async throws -> [String: Job.Mapping] {
        try await Self.performVision { checkCancellation in
            try Self.faceProposals(images: images, references: references, checkCancellation: checkCancellation)
        }
    }

    private static func faceProposals(
        images: [URL], references: [String: URL], checkCancellation: @Sendable () throws -> Void
    ) throws -> [String: Job.Mapping] {
        var referencePrints: [String: VNFeaturePrintObservation] = [:]
        for (trigger, url) in references {
            try checkCancellation()
            if let image = try Self.image(Data(contentsOf: url)), let face = try Self.faceImages(image).first {
                referencePrints[trigger] = try Self.feature(face)
            }
        }
        var result: [String: Job.Mapping] = [:]
        for url in images {
            try checkCancellation()
            guard let image = try Self.image(Data(contentsOf: url)) else { continue }
            var mapping = Job.Mapping()
            for (index, face) in try Self.faceImages(image).enumerated() {
                try checkCancellation()
                guard let feature = try Self.feature(face) else { continue }
                var matches: [(String, Float)] = []
                for (trigger, reference) in referencePrints {
                    var distance: Float = 0
                    try feature.computeDistance(&distance, to: reference)
                    matches.append((trigger, distance))
                }
                if let trigger = Self.faceCandidate(matches), mapping[trigger] == nil {
                    mapping[trigger] = "face \(index + 1), counted from left to right"
                }
            }
            if !mapping.isEmpty { result[url.lastPathComponent] = mapping }
        }
        return result
    }

    private static func image(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
        ] as CFDictionary)
    }

    private static func feature(_ image: CGImage) throws -> VNFeaturePrintObservation? {
        let request = featureRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        return request.results?.first
    }

    private static func featureRequest() -> VNGenerateImageFeaturePrintRequest {
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        return request
    }

    private static func faceImages(_ image: CGImage) throws -> [CGImage] {
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).sorted { $0.boundingBox.midX < $1.boundingBox.midX }.compactMap { face in
            let box = face.boundingBox
            let rectangle = CGRect(
                x: box.minX * Double(image.width),
                y: (1 - box.maxY) * Double(image.height),
                width: box.width * Double(image.width),
                height: box.height * Double(image.height)
            )
            return image.cropping(to: rectangle.integral)
        }
    }
}

@MainActor
extension StudioSession {
    /// Check the project's photos on this Mac in the background. Results for unchanged files come
    /// from the project's cache; the project stays usable while the rest are analysed.
    func startImageAnalysis() {
        stopImageAnalysis()
        guard let project else { return }
        analysisGeneration += 1
        let generation = analysisGeneration
        let urls = project.allMedia.map(\.url)
        let current = Set(urls.map(\.lastPathComponent))
        analyses = analyses.filter { current.contains($0.key) }
        analyzing = true
        let cacheDirectory = demoMode ? nil : project.directory
        analysisTask = Task { [weak self, inspector] in
            let result = try? await inspector.analyze(urls, cacheIn: cacheDirectory) { [weak self] name, analysis in
                await self?.receiveAnalysis(name, analysis, generation: generation)
            }
            guard let self, generation == analysisGeneration else { return }
            if let result { analyses = result }
            analyzing = false
        }
    }

    func stopImageAnalysis() {
        analysisGeneration += 1
        analysisTask?.cancel()
        analysisTask = nil
        analyzing = false
    }

    private func receiveAnalysis(_ name: String, _ analysis: ImageAnalysis, generation: Int) {
        guard generation == analysisGeneration else { return }
        analyses[name] = analysis
    }
}
