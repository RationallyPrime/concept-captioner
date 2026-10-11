import AVFoundation
import ConceptCore
@testable import ConceptStudio
import CoreVideo
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

enum MediaFixtures {
    static func image(width: Int = 80, height: Int = 60) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    static func encoded(_ image: CGImage, type: UTType) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// A local two-second movie with changing pixels; no external media or services.
    static func video(at url: URL, times: [Double]? = nil, width: Int = 64, height: Int = 64) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input)
        #expect(writer.canAdd(input))
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let sampleTimes = times ?? (0 ..< 20).map { Double($0) / 10 }
        for (frame, seconds) in sampleTimes.enumerated() {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !input.isReadyForMoreMediaData {
                guard ContinuousClock.now < deadline else { throw StudioError.message("Synthetic encoder timed out") }
                try await Task.sleep(for: .milliseconds(10))
            }
            var buffer: CVPixelBuffer?
            #expect(CVPixelBufferCreate(
                kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB,
                [
                    kCVPixelBufferCGImageCompatibilityKey: true,
                    kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                ] as CFDictionary,
                &buffer
            ) == kCVReturnSuccess)
            let pixel = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            let bytes = try #require(CVPixelBufferGetBaseAddress(pixel)).assumingMemoryBound(to: UInt8.self)
            for y in 0 ..< height {
                for x in 0 ..< width {
                    let offset = y * CVPixelBufferGetBytesPerRow(pixel) + x * 4
                    bytes[offset] = 255
                    bytes[offset + 1] = frame < 10 ? 240 : 10
                    bytes[offset + 2] = 20
                    bytes[offset + 3] = frame < 10 ? 10 : 240
                    if x < width / 8 {
                        bytes[offset + 1] = 10; bytes[offset + 2] = 240; bytes[offset + 3] = 10
                    } else if x >= width * 7 / 8 {
                        bytes[offset + 1] = 240; bytes[offset + 2] = 240; bytes[offset + 3] = 240
                    }
                    let center = width / 4 + frame * (width / 2) / max(1, sampleTimes.count - 1)
                    let dx = x - center, dy = y - height / 2, radius = min(width, height) / 12
                    if dx * dx + dy * dy < radius * radius {
                        bytes[offset + 1] = 10; bytes[offset + 2] = 20; bytes[offset + 3] = 240
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            #expect(adaptor.append(pixel, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 600)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }
}

private actor SelectedClipTransport: HTTPTransport {
    let expectedBytes: Data
    private(set) var count = 0

    init(expectedBytes: Data) {
        self.expectedBytes = expectedBytes
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let system = try #require(body["systemInstruction"] as? [String: Any])
        let instructions = try #require((system["parts"] as? [[String: Any]])?.first?["text"] as? String)
        #expect(instructions.contains("attached_target_video"))
        #expect(!instructions.contains("attached_target_image"))
        #expect(instructions.contains("uninspected"))
        let contents = try #require(body["contents"] as? [[String: Any]])
        let blobs = contents.flatMap { $0["parts"] as? [[String: Any]] ?? [] }
            .compactMap { $0["inlineData"] as? [String: String] }
        #expect(blobs.count == 1)
        #expect(blobs.first?["mimeType"] == "video/mp4")
        #expect(blobs.first?["data"] == expectedBytes.base64EncodedString())
        let text = count == 0 ? "{\"caption\":\"NORA7 changes from red to blue over the selected segment.\"}" :
            "{\"approved\":true,\"notes\":[]}"
        count += 1
        let response: [String: Any] = ["candidates": [["content": ["parts": [["text": text]]]]]]
        return try HTTPResponse(status: 200, body: JSONSerialization.data(withJSONObject: response))
    }
}

@Suite("curation and exact media targets")
struct MediaWorkflowTests {
    @Test(arguments: [UTType.tiff, UTType.heic])
    func normalizedFormatsBecomeUsablePngTargets(type: UTType) throws {
        let directory = temporaryTestDirectory("format-import")
        defer { try? FileManager.default.removeItem(at: directory) }
        var project = try StudioProject.create(at: directory)
        let data = try MediaFixtures.encoded(MediaFixtures.image(), type: type)
        let id = try project.importData(data, name: "portrait." + type.preferredFilenameExtension!)
        #expect(id == "portrait.png")
        let source = try LocalFolderSource(directory: project.imagesDirectory)
        #expect(source.files.map(\.lastPathComponent) == [id])
        let decoded = try MediaEditor.orientedImage(Data(contentsOf: source.files[0]))
        #expect(decoded.width == 80 && decoded.height == 60)
        _ = try Images.providerImage(Data(contentsOf: source.files[0]), suffix: ".png")
    }

    @Test func exclusionReopenPublishAndUndoPreserveFinalCaptionAndMapping() async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let id = "garden.png"
        let mapping = project.job.mapping(for: id)
        try await project.saveCaption(id: id, text: "NORA7 protected caption.", final: true)
        try project.setIncluded(id, false)
        #expect(!project.images.contains { $0.id == id })
        #expect(project.excludedImages.first { $0.id == id }?.isFinal == true)
        #expect(try LocalFolderSource(directory: project.imagesDirectory).files.count == 2)
        let operations = try await ProjectPublisher.operations(for: project)
        #expect(!operations.contains { [id, "garden.txt", "garden.json"].contains($0.path) })
        let reopened = try await StudioProject.open(at: project.directory)
        #expect(reopened.excludedImages.first { $0.id == id }?.caption == "NORA7 protected caption.")
        #expect(reopened.excludedImages.first { $0.id == id }?.isFinal == true)
        try project.undoCuration()
        #expect(project.images.first { $0.id == id }?.isFinal == true)
        #expect(project.job.mapping(for: id) == mapping)
        #expect(try await SidecarSink(directory: project.imagesDirectory).record(id)?.isHumanFinal == true)
    }

    @Test func approvedCropChangesActualPixelsResetsOldCaptionAndUndoRestoresExactBytes() async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let id = "garden.png"
        let original = try Data(contentsOf: #require(project.images.first { $0.id == id }).url)
        let before = try MediaEditor.orientedImage(original)
        let mapping = project.job.mapping(for: id)
        try await project.saveCaption(id: id, text: "NORA7 original final.", final: true)
        let rectangle = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        try project.approveTarget(
            id: id, data: MediaEditor.cropped(original, rectangle: rectangle), name: id,
            selection: MediaSelection(originalName: id, crop: rectangle)
        )
        let cropped = try MediaEditor
            .orientedImage(Data(contentsOf: #require(project.images.first { $0.id == id }).url))
        #expect(cropped.width == before.width / 2 && cropped.height == before.height / 2)
        #expect(project.job.mapping(for: id) == nil)
        #expect(try await SidecarSink(directory: project.imagesDirectory).record(id) == nil)
        #expect(project.images.first { $0.id == id }?.caption.isEmpty == true)
        try project.undoCuration()
        #expect(try Data(contentsOf: #require(project.images.first { $0.id == id }).url) == original)
        #expect(project.job.mapping(for: id) == mapping)
        #expect(try await SidecarSink(directory: project.imagesDirectory).record(id)?.isHumanFinal == true)
    }

    @Test func nameCollisionCannotDeleteAnotherTargetOrItsCaption() async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let existing = try #require(project.images.first { $0.id == "window.png" })
        let bytes = try Data(contentsOf: existing.url)
        #expect(throws: StudioError.self) {
            try project.approveTarget(
                id: "garden.png", data: bytes, name: existing.id,
                selection: MediaSelection(originalName: "garden.png", crop: CGRect(x: 0, y: 0, width: 1, height: 1))
            )
        }
        #expect(try Data(contentsOf: existing.url) == bytes)
        #expect(project.images.count == 3)
    }

    @Test func selectedVideoRangeIsRealExportWithRebasedFramesAndExactPublishedBytes() async throws {
        let directory = temporaryTestDirectory("video-import")
        defer { try? FileManager.default.removeItem(at: directory) }
        var project = try StudioProject.create(at: directory)
        let original = directory.appendingPathComponent("original.mp4")
        try await MediaFixtures.video(at: original)
        try project.importFiles([original])
        let id = try #require(project.images.first?.id)
        let output = directory.appendingPathComponent("trimmed.mp4")
        let selected = try await MediaEditor.trim(
            url: project.images[0].url, startFrame: 2, frameCount: 17, longEdge: 512, output: output
        )
        let bytes = try Data(contentsOf: output)
        try project.approveTarget(
            id: id, data: bytes, name: id,
            selection: MediaSelection(
                originalName: id, startSeconds: selected.range.start.seconds, endSeconds: selected.range.end.seconds,
                frameCount: 17, videoWidth: selected.info.width, videoHeight: selected.info.height
            )
        )
        let info = try await MediaEditor.videoInfo(url: project.images[0].url)
        #expect(abs(info.duration - 1.7) < 0.12)
        #expect(try await MediaEditor.videoTimeline(url: project.images[0].url).times.count == 17)
        #expect(!info.hasAudio)
        let frames = try await MediaEditor.frames(url: project.images[0].url, count: 3)
        #expect(frames.count == 3)
        #expect(frames[0].seconds == 0)
        #expect(frames.allSatisfy { $0.seconds < info.duration })
        let operations = try await ProjectPublisher.operations(for: project)
        let media = try #require(operations.first { $0.path == id })
        guard case let .addFile(_, url) = media else { Issue.record("Expected exact selected media file"); return }
        #expect(try Data(contentsOf: url) == bytes)
        let reopened = try await StudioProject.open(at: directory)
        #expect(reopened.mediaState.selections[id]?.startSeconds == 0.2)
        #expect(reopened.mediaState.selections[id]?.endSeconds == 1.9)
        #expect(reopened.mediaState.selections[id]?.frameCount == 17)
        #expect(reopened.mediaState.selections[id]?.videoWidth == info.width)
        #expect(reopened.mediaState.selections[id]?.videoHeight == info.height)
        #expect(try LocalFolderSource(directory: project.imagesDirectory).files.count == 1)
        project.job.profile = "ltx-video"
        try project.job.setMapping(["NORA7": "the changing colored surface"], for: id)
        let transport = SelectedClipTransport(expectedBytes: bytes)
        let endpoint = ResolvedEndpoint(client: GeminiClient(
            apiKey: "fixture", model: "gemini-3.8-flash", transport: transport
        ))
        let runner = try Runner(job: project.job, captioner: endpoint, critic: endpoint)
        let summary = try await runner.run(
            source: LocalFolderSource(directory: project.imagesDirectory),
            sink: SidecarSink(directory: project.imagesDirectory)
        )
        #expect(summary.outcomes.first?.status == .written)
        #expect(await transport.count == 2)
        #expect(try String(
            contentsOf: project.imagesDirectory.appendingPathComponent("original.txt"), encoding: .utf8
        ) == "NORA7 changes from red to blue over the selected segment.")
    }

    @Test func reopenSingleStyleAssignsIncludedTargetsAndPersistsOnlyChangedJob() async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        project.job.concepts = try [Concept(trigger: "NORA7", classNoun: "style", targetConcept: .style)]
        project.job.samples = ["garden.png": nil]
        try project.setIncluded("studio.png", false)
        let opened = try await StudioProject.open(at: project.directory)
        let expected = try #require(opened.job.mappingIncludingWholeTargets(nil))
        #expect(opened.images.allSatisfy { opened.job.mapping(for: $0.id) == expected })
        #expect(opened.job.mapping(for: "studio.png") == nil)
        let stored = try Job.load(contentsOf: opened.jobURL)
        #expect(opened.images.allSatisfy { stored.mapping(for: $0.id) == expected })
        let before = try opened.jobURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        _ = try await StudioProject.open(at: project.directory)
        #expect(try opened.jobURL.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate == before)
    }

    @Test func variableRateSelectionRefusesWithoutRetimingButConstantPortionCanBeApproved() async throws {
        let directory = temporaryTestDirectory("variable-rate-video")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.mp4")
        let times = (0 ..< 10).map { Double($0) / 10 } + [
            1.4,
            1.5,
            1.7,
            1.9,
            2.2,
            2.4,
            2.41,
            2.7,
            3.0,
            3.4,
        ]
        try await MediaFixtures.video(at: original, times: times)
        let source = try await MediaEditor.videoTimeline(url: original)
        #expect(source.times.count == 20)
        for invalidCount in [0, 10, Int.max, Int.min] {
            #expect(source.range(startFrame: 0, frameCount: invalidCount) == nil)
        }
        let output = directory.appendingPathComponent("selected.mp4")
        #expect(!source.supportsTiming(startFrame: 3, frameCount: 9))
        await #expect(throws: StudioError.self) {
            try await MediaEditor.trim(url: original, startFrame: 3, frameCount: 9, longEdge: 512, output: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(source.supportsTiming(startFrame: 0, frameCount: 9))
        let selected = try await MediaEditor.trim(
            url: original, startFrame: 0, frameCount: 9, longEdge: 512, output: output
        )
        let target = try await MediaEditor.videoTimeline(url: output)
        #expect(target.times.count == 9)
        for (index, time) in target.times.enumerated() {
            #expect(abs(time.seconds - (source.times[index] - selected.range.start).seconds) < 0.002)
        }
        let invalid = directory.appendingPathComponent("invalid.mp4")
        await #expect(throws: StudioError.self) {
            try await MediaEditor.trim(url: original, startFrame: 0, frameCount: 10, longEdge: 512, output: invalid)
        }
        #expect(!FileManager.default.fileExists(atPath: invalid.path))
        await #expect(throws: StudioError.self) {
            try await MediaEditor.trim(url: original, startFrame: 15, frameCount: 9, longEdge: 512, output: invalid)
        }
        #expect(!FileManager.default.fileExists(atPath: invalid.path))
    }

    @Test func longSourceCannotApproveUnsupported265FrameSegment() async throws {
        let directory = temporaryTestDirectory("long-video-bound")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.mp4")
        try await MediaFixtures.video(at: original, times: (0 ..< 273).map { Double($0) / 30 })
        let timeline = try await MediaEditor.videoTimeline(url: original)
        #expect(timeline.times.count == 273)
        #expect(timeline.maximumTrainingFrames() == 257)
        #expect(timeline.range(startFrame: 0, frameCount: 257) != nil)
        let output = directory.appendingPathComponent("unsupported.mp4")
        await #expect(throws: StudioError.self) {
            try await MediaEditor.trim(url: original, startFrame: 0, frameCount: 265, longEdge: 512, output: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test(arguments: [
        (CGSize(width: 1280, height: 720), CGSize(width: 512, height: 288)),
        (CGSize(width: 720, height: 1280), CGSize(width: 288, height: 512)),
        (CGSize(width: 1024, height: 768), CGSize(width: 512, height: 384)),
    ])
    func approvedVideoPreservesAspectAndBothOuterEdges(dimensions: (source: CGSize, target: CGSize)) async throws {
        let directory = temporaryTestDirectory("video-aspect")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.mp4")
        try await MediaFixtures.video(
            at: original, times: (0 ..< 9).map { Double($0) / 30 },
            width: Int(dimensions.source.width), height: Int(dimensions.source.height)
        )
        let output = directory.appendingPathComponent("selected.mp4")
        let selected = try await MediaEditor.trim(
            url: original, startFrame: 0, frameCount: 9, longEdge: 512, output: output
        )
        #expect(CGSize(width: selected.info.width, height: selected.info.height) == dimensions.target)
        let frame = try await MediaEditor.frame(url: output, seconds: 0)
        let context = try #require(CGContext(
            data: nil, width: frame.image.width, height: frame.image.height, bitsPerComponent: 8,
            bytesPerRow: frame.image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(frame.image, in: CGRect(x: 0, y: 0, width: frame.image.width, height: frame.image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let left = (frame.image.height / 2 * frame.image.width + frame.image.width / 16) * 4
        let right = (frame.image.height / 2 * frame.image.width + frame.image.width * 15 / 16) * 4
        #expect(bytes[left + 1] > 150 && bytes[left] < 80)
        #expect(bytes[right] > 150 && bytes[right + 1] > 150 && bytes[right + 2] > 150)
        if dimensions.target == CGSize(width: 512, height: 288),
           let path = ProcessInfo.processInfo.environment["CONCEPTSTUDIO_APPROVED_VIDEO_PROOF"] {
            let proof = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: proof, withIntermediateDirectories: true)
            let originalData = try Data(contentsOf: original)
            let selectedData = try Data(contentsOf: output)
            let sourceName = "synthetic-source.mp4"
            let targetName = "approved-9frames-512x288.mp4"
            try originalData.write(to: proof.appendingPathComponent(sourceName))
            try selectedData.write(to: proof.appendingPathComponent(targetName))
            let caption = "NORA7, a blue circle moves from left to right across a red field, "
                + "with a green vertical stripe on the left and a white vertical stripe on the right."
            try caption.write(
                to: proof.appendingPathComponent("approved-9frames-512x288.txt"), atomically: true, encoding: .utf8
            )
            let receipt: [String: Any] = try await [
                "proof": "offline synthetic native AV export; no external model, Hub or resource calls",
                "source": sourceName, "target": targetName,
                "source_sha256": SHA256.hash(data: originalData).map { String(format: "%02x", $0) }.joined(),
                "target_sha256": SHA256.hash(data: selectedData).map { String(format: "%02x", $0) }.joined(),
                "decoded_frame_count": MediaEditor.videoTimeline(url: output).times.count,
                "width": selected.info.width, "height": selected.info.height, "fps": selected.info.fps,
                "source_fps": MediaEditor.videoInfo(url: original).fps,
                "start_seconds": selected.range.start.seconds, "end_seconds": selected.range.end.seconds,
                "both_outer_edge_landmarks_verified": true,
                "caption": caption,
            ]
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                .write(to: proof.appendingPathComponent("receipt.json"))
        }
    }

    @Test func includingPreviouslyUnmappedSampleAfterStyleChangeIsCaptionReady() async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let id = "garden.png"
        try project.job.setMapping(nil, for: id)
        try project.setIncluded(id, false)
        project.job.concepts = try [Concept(trigger: "NORA7", classNoun: "style", targetConcept: .style)]
        try project.setIncluded(id, true)
        #expect(project.job.unmapped([id]).isEmpty)
        #expect(project.job.mapping(for: id) == project.job.mappingIncludingWholeTargets(nil))
        #expect(try Job.load(contentsOf: project.jobURL).mapping(for: id) == project.job
            .mappingIncludingWholeTargets(nil))
    }

    @Test(arguments: [TargetConcept.style, .object])
    func undoAfterConceptChangeDoesNotRestoreStalePersonMapping(category: TargetConcept) async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let id = "garden.png"
        let image = try #require(project.images.first { $0.id == id })
        try project.approveTarget(
            id: id, data: Data(contentsOf: image.url), name: id, selection: MediaSelection(originalName: id)
        )
        project.job.concepts = try [Concept(trigger: "OBJECT8", classNoun: "object", targetConcept: category)]
        try project.undoCuration()
        #expect(project.job.mapping(for: id) == project.job.mappingIncludingWholeTargets(nil))
        if category == .object { #expect(project.job.unmapped([id]) == [id]) }
        #expect(project.images.contains { $0.id == id })
    }

    @Test func failedApprovalRestoresOriginalMediaCaptionAndJobOnDisk() async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let id = "garden.png"
        let original = try #require(project.images.first { $0.id == id })
        let bytes = try Data(contentsOf: original.url)
        let mapping = project.job.mapping(for: id)
        try await project.saveCaption(id: id, text: "NORA7 original final.", final: true)
        let stateURL = ProjectMediaState.url(in: project.directory)
        if FileManager.default.fileExists(atPath: stateURL.path) { try FileManager.default.removeItem(at: stateURL) }
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            try project.approveTarget(
                id: id, data: MediaEditor.cropped(bytes, rectangle: CGRect(x: 0, y: 0, width: 0.5, height: 0.5)),
                name: id, selection: MediaSelection(originalName: id)
            )
        }
        #expect(try Data(contentsOf: original.url) == bytes)
        #expect(project.curationUndo.isEmpty)
        let reopened = try await StudioProject.open(at: project.directory)
        #expect(reopened.job.mapping(for: id) == mapping)
        #expect(reopened.images.first { $0.id == id }?.caption == "NORA7 original final.")
        #expect(reopened.images.first { $0.id == id }?.isFinal == true)
    }

    @Test @MainActor func undoEditedTargetClearsOnlyItsStaleDraftAndRestoresSavedCaption() async throws {
        let session = makeTestSession()
        session.demoMode = true
        session.project = try await makeDemoProject()
        let project = try #require(session.project)
        defer { session.stopImageAnalysis(); try? FileManager.default.removeItem(at: project.directory) }
        let first = try #require(project.images.first { $0.id == "garden.png" })
        let other = try #require(project.images.first { $0.id == "window.png" })
        try session.project?.approveTarget(
            id: first.id, data: MediaEditor.png(MediaFixtures.image()), name: first.id,
            selection: MediaSelection(originalName: first.id)
        )
        session.setCaptionDraft(CaptionDraft(text: "NORA7 edited target draft.", isFinal: false), for: first.id)
        session.setCaptionDraft(CaptionDraft(text: "NORA7 other target draft.", isFinal: false), for: other.id)
        session.undoMediaCuration()
        #expect(session.captionDrafts[first.id] == nil)
        #expect(session.captionDrafts[other.id]?.text == "NORA7 other target draft.")
        #expect(session.project?.images.first { $0.id == first.id }?.caption == first.caption)
    }

    @Test @MainActor func exclusionKeepsDraftVisibleToCloseConfirmationAndUndo() async throws {
        let session = makeTestSession()
        session.demoMode = true
        session.project = try await makeDemoProject()
        let project = try #require(session.project)
        defer { session.stopImageAnalysis(); try? FileManager.default.removeItem(at: project.directory) }
        let image = try #require(project.images.first)
        let draft = CaptionDraft(text: "NORA7 unsaved caption.", isFinal: true)
        session.setCaptionDraft(draft, for: image.id)
        session.includeMedia(image.id, included: false)
        #expect(session.unsavedCaptionCount == 1)
        #expect(session.needsCloseConfirmation)
        session.undoMediaCuration()
        #expect(session.project?.isIncluded(image.id) == true)
        #expect(session.captionDraft(for: image) == draft)
    }

    @Test @MainActor func repeatedCropRecipeRemainsRelativeToOriginalAndUndoStepsBack() async throws {
        let session = makeTestSession()
        session.demoMode = true
        session.project = try await makeDemoProject()
        let project = try #require(session.project)
        defer { session.stopImageAnalysis(); try? FileManager.default.removeItem(at: project.directory) }
        let image = try #require(project.images.first)
        let bytes = try Data(contentsOf: image.url)
        session.approveCrop(id: image.id, rectangle: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        await session.task?.value
        #expect(session.errorMessage == nil)
        session.approveCrop(id: image.id, rectangle: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        await session.task?.value
        #expect(session.errorMessage == nil)
        #expect(session.project?.mediaState.selections[image.id]?.crop ==
            CGRect(x: 0.125, y: 0.125, width: 0.25, height: 0.25))
        session.undoMediaCuration()
        #expect(session.project?.mediaState.selections[image.id]?.crop == CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        session.undoMediaCuration()
        #expect(try Data(contentsOf: image.url) == bytes)
    }

    @Test func exactDuplicateGroupsRetainStableIdentifiers() async throws {
        let directory = temporaryTestDirectory("duplicate-groups")
        defer { try? FileManager.default.removeItem(at: directory) }
        var project = try StudioProject.create(at: directory)
        let data = try MediaEditor.png(MediaFixtures.image(width: 640, height: 512))
        _ = try project.importData(data, name: "first.png")
        _ = try project.importData(data, name: "second.png")
        let results = try await VisionInspector().analyze(project.images.map(\.url))
        #expect(results["second.png"]?.duplicateOf == "first.png")
    }
}

@Suite("video segment control values")
@MainActor
struct MediaEditorControlTests {
    @Test func timeControlsSnapToDecodedTimestampsAndPreserveExactDurationOptions() {
        let irregular = [0.0, 0.04, 0.11, 0.16, 0.25].map { CMTime(seconds: $0, preferredTimescale: 600) }
        #expect(MediaEditorView.nearestFrame(to: 0.13, in: irregular, maximumIndex: 4) == 2)
        #expect(MediaEditorView.nearestFrame(to: 0.15, in: irregular, maximumIndex: 4) == 3)
        #expect(MediaEditorView.nearestFrame(to: -1, in: irregular, maximumIndex: 4) == 0)
        #expect(MediaEditorView.nearestFrame(to: 20, in: irregular, maximumIndex: 2) == 2)
        #expect(MediaEditorView.nearestFrame(to: .nan, in: irregular, maximumIndex: 4) == 0)
        let times = (0 ..< 129).map { CMTime(value: Int64($0), timescale: 24) }
        let timeline = VideoTimeline(times: times, end: CMTime(value: 129, timescale: 24))
        #expect(MediaEditorView.durationChoices(in: timeline, startFrame: 0, currentCount: 65)
            == [9, 17, 33, 49, 65, 97, 129])
        #expect(timeline.range(startFrame: 0, frameCount: 9)?.duration == CMTime(value: 9, timescale: 24))
        #expect(MediaEditorView.durationChoices(in: timeline, startFrame: 112, currentCount: 17) == [9, 17])
        #expect(MediaEditorView.durationChoices(in: timeline, startFrame: 0, currentCount: 10)
            == [9, 17, 33, 49, 97, 129])
    }
}
