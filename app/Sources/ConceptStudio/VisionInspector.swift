import AppKit
import ConceptCore
import CryptoKit
import ImageIO
import Vision

struct ImageAnalysis {
    var faces: [CGRect] = []
    var warnings: [String] = []
    var width = 0
    var height = 0
}

actor VisionInspector {
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

    func analyze(_ urls: [URL]) throws -> [String: ImageAnalysis] {
        var results: [String: ImageAnalysis] = [:]
        var hashes: [String: String] = [:]
        var prints: [(String, VNFeaturePrintObservation)] = []
        for url in urls {
            try Task.checkCancellation()
            let data = try Data(contentsOf: url)
            let hash = SHA256.hash(data: data).description
            var analysis = ImageAnalysis()
            guard let image = Self.image(data) else {
                analysis.warnings = ["This photo cannot be decoded. Import another copy."]
                results[url.lastPathComponent] = analysis
                continue
            }
            analysis.width = image.width
            analysis.height = image.height
            if min(image.width, image.height) < 512 {
                analysis.warnings.append("Small image: details may not survive training. Prefer a larger original.")
            }
            let faces = VNDetectFaceCaptureQualityRequest()
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .fast
            let feature = Self.featureRequest()
            try VNImageRequestHandler(cgImage: image).perform([faces, text, feature])
            analysis.faces = faces.results?.map(\.boundingBox).sorted { $0.midX < $1.midX } ?? []
            if faces.results?.contains(where: { ($0.faceCaptureQuality ?? 1) < 0.3 }) == true {
                analysis.warnings.append("A face is hard to see. Check focus, angle and lighting before using it.")
            }
            if !(text.results ?? []).isEmpty {
                analysis.warnings
                    .append(
                        "Readable text detected. Captions should describe signs and logos without copying the words."
                    )
            }
            if let original = hashes[hash] {
                analysis.warnings.append("Exact duplicate of \(original). Repeated photos can overemphasize one scene.")
            } else if let observation = feature.results?.first {
                for (name, other) in prints {
                    var distance: Float = 0
                    try observation.computeDistance(&distance, to: other)
                    if distance <= Self.similarPhotoDistance {
                        analysis.warnings
                            .append("Visually similar to \(name). Keep enough variety in scenes and clothing.")
                        break
                    }
                }
                prints.append((url.lastPathComponent, observation))
            }
            hashes[hash] = url.lastPathComponent
            results[url.lastPathComponent] = analysis
        }
        return results
    }

    func proposals(images: [URL], references: [String: URL]) throws -> [String: Job.Mapping] {
        var referencePrints: [String: VNFeaturePrintObservation] = [:]
        for (trigger, url) in references {
            try Task.checkCancellation()
            if let image = try Self.image(Data(contentsOf: url)), let face = try Self.faceImages(image).first {
                referencePrints[trigger] = try Self.feature(face)
            }
        }
        var result: [String: Job.Mapping] = [:]
        for url in images {
            try Task.checkCancellation()
            guard let image = try Self.image(Data(contentsOf: url)) else { continue }
            var mapping = Job.Mapping()
            for (index, face) in try Self.faceImages(image).enumerated() {
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
