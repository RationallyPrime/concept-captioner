// Shared fixtures: synthetic PNGs drawn with CoreGraphics, the NORA7/IVAN9 job, caption helpers.
// Python counterpart: tests/conftest.py.

import ConceptCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum Fixtures {
    /// A flat background, an ellipse and a rectangle, like conftest.synthetic_png.
    public static func syntheticPNG(seed: Int, size: CGSize = CGSize(width: 256, height: 256)) -> Data {
        let width = Int(size.width)
        let height = Int(size.height)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fatalError("CGContext")
        }
        let red = CGFloat((40 + seed * 20) % 200) / 255
        context.setFillColor(CGColor(red: red, green: 90 / 255, blue: 160 / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 230 / 255, green: 200 / 255, blue: 180 / 255, alpha: 1))
        context.fillEllipse(in: CGRect(x: 64, y: 48, width: 128, height: 128))
        let blue = CGFloat((30 + seed * 7) % 200) / 255
        context.setFillColor(CGColor(red: blue, green: 60 / 255, blue: 120 / 255, alpha: 1))
        context.fill(CGRect(x: 80, y: 180, width: 96, height: 76))
        guard let image = context.makeImage() else { fatalError("makeImage") }
        return encodePNG(image)
    }

    public static func encodePNG(_ image: CGImage) -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            fatalError("CGImageDestination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    public static func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConceptCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// solo.png (seed 1), pair.png (seed 2), unmapped.png (seed 3) in a fresh temp folder.
    public static func imagesFolder() throws -> URL {
        let folder = try tempDirectory().appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, seed) in [("solo.png", 1), ("pair.png", 2), ("unmapped.png", 3)] {
            try syntheticPNG(seed: seed).write(to: folder.appendingPathComponent(name))
        }
        return folder
    }

    public static let soloMapping: Job.Mapping = ["NORA7": "The only person in the crop."]
    public static let pairMapping: Job.Mapping = ["NORA7": "The woman on the left.", "IVAN9": "The man on the right."]

    /// NORA7 woman / IVAN9 man; solo and pair mapped, unmapped held.
    public static func job() throws -> Job {
        try Job(
            concepts: [
                Concept(trigger: "NORA7", classNoun: "woman"),
                Concept(trigger: "IVAN9", classNoun: "man"),
            ],
            samples: ["solo.png": soloMapping, "pair.png": pairMapping, "unmapped.png": nil]
        )
    }

    public static func h3(_ body: String) -> String {
        "integrated_multimodal_description: [Shot 1] \(body)\n\noverall_soundscape: N/A\n\nnon_diegetic_music: N/A"
    }

    /// Read the mapped triggers back out of the ACTIVE JOB CONFIGURATION line in the instructions.
    public static func mappedTriggers(in instructions: String) throws -> Set<String> {
        guard let range = instructions.range(of: "ACTIVE JOB CONFIGURATION\n") else {
            throw ConfigurationError("no ACTIVE JOB CONFIGURATION in instructions")
        }
        let line = instructions[range.upperBound...].split(separator: "\n", maxSplits: 1).first ?? ""
        guard let view = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let inputs = view["inputs"] as? [String: Any],
              let mapping = inputs["subject_mapping"] as? [String: Any]
        else {
            throw ConfigurationError("job view has no inputs.subject_mapping")
        }
        return Set(mapping.keys)
    }

    public static func goodCaption(for instructions: String) throws -> String {
        let mapped = try mappedTriggers(in: instructions)
        if mapped == ["NORA7", "IVAN9"] {
            return h3("A photograph frames NORA7, a woman on the left, beside IVAN9, a man on the right.")
        }
        return h3("A photograph frames NORA7, a woman, seated by a window in a blue blouse.")
    }

    public static func captionerOK(model: String = "fake") -> FakeModelClient {
        FakeModelClient(model: model) { request in
            try FakeModelClient.Reply(encoding: Caption(caption: goodCaption(for: request.instructions)))
        }
    }

    public static func criticOK(model: String = "fake") -> FakeModelClient {
        FakeModelClient.critique(Critique(approved: true, notes: ["looks right"]), model: model)
    }

    public static func endpoint(
        _ client: FakeModelClient,
        requested: String? = nil,
        concurrency: Int = 4,
        outputMode: OutputMode = .native
    ) -> ResolvedEndpoint {
        ResolvedEndpoint(client: client, outputMode: outputMode, requested: requested, concurrency: concurrency)
    }

    /// Path to the repository's examples/job.example.yaml, relative to this package.
    public static var exampleJobURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Support
            .deletingLastPathComponent() // ConceptCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // app
            .deletingLastPathComponent() // repo
            .appendingPathComponent("examples/job.example.yaml")
    }
}
