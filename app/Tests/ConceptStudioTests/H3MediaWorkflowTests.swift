import AVFoundation
import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

@Suite("H3 exact media approval")
struct H3MediaWorkflowTests {
    @Test @MainActor func eachModelKeepsItsOwnFrameGridAndTiming() {
        let timeline = VideoTimeline(
            times: (0 ..< 300).map { CMTime(value: Int64($0), timescale: 24) },
            end: CMTime(value: 300, timescale: 24)
        )
        #expect(timeline.maximumTrainingFrames() == 257)
        #expect(timeline.maximumTrainingFrames(format: .h3) == 243)
        #expect(timeline.range(startFrame: 3, frameCount: 22, format: .h3) != nil)
        #expect(timeline.range(startFrame: 3, frameCount: 39, format: .h3) != nil)
        #expect(timeline.range(startFrame: 0, frameCount: 33, format: .h3) == nil)
        #expect(timeline.range(startFrame: 0, frameCount: 22) == nil)
        #expect(timeline.range(startFrame: 0, frameCount: 4, format: .h3) == nil)
        #expect(timeline.range(startFrame: 0, frameCount: 260, format: .h3) == nil)
        let otherRate = VideoTimeline(
            times: (0 ..< 40).map { CMTime(value: Int64($0), timescale: 30) },
            end: CMTime(value: 40, timescale: 30)
        )
        #expect(otherRate.supportsTiming(startFrame: 0, frameCount: 33))
        #expect(!otherRate.supportsTiming(startFrame: 0, frameCount: 22, format: .h3))
        let fractionalRate = VideoTimeline(
            times: (0 ..< 40).map { CMTime(value: Int64($0) * 1001, timescale: 24000) },
            end: CMTime(value: 40040, timescale: 24000)
        )
        #expect(!fractionalRate.supportsTiming(startFrame: 0, frameCount: 22, format: .h3))
        #expect(timeline.supportsTiming(startFrame: 0, frameCount: 22, format: .h3))
        let choices = MediaEditorView.durationChoices(in: timeline, startFrame: 0, currentCount: 39, format: .h3)
        #expect(choices.first == 5 && choices.last == 243)
        #expect(choices.allSatisfy { $0 % 17 == 5 })
        #expect(VideoTrainingFormat(profile: "h3-still") == .h3)
        #expect(VideoTrainingFormat(profile: "ltx-video") == .ltx)
        #expect(VideoTrainingFormat.h3.initialSelectionFrames(available: 124) == 124)
        #expect(VideoTrainingFormat.ltx.initialSelectionFrames(available: 49) == 33)
    }

    @Test(arguments: [22, 39])
    func realH3ExportRetainsEverySelectedFrameAudioAndCaptionPayload(frameCount: Int) async throws {
        let directory = temporaryTestDirectory("h3-media")
        defer { try? FileManager.default.removeItem(at: directory) }
        var project = try StudioProject.create(at: directory)
        project.job = try Job(profile: "ltx-video", concepts: [Concept(trigger: "MOVE8", targetConcept: .motion)])
        let original = directory.appendingPathComponent("clip.mp4")
        try await H3MediaFixtures.audiovisualClip(at: original)
        try await project.importFiles([original])
        let id = try #require(project.images.first?.id)
        let source = try #require(project.images.first?.url)
        let output = directory.appendingPathComponent("approved.mp4")
        let selected = try await MediaEditor.trim(
            url: source, startFrame: 3, frameCount: frameCount, longEdge: 512, output: output, format: .h3
        )
        let bytes = try Data(contentsOf: output)
        let timeline = try await MediaEditor.videoTimeline(url: output)
        #expect(timeline.times.count == frameCount)
        #expect(timeline.supportsTiming(startFrame: 0, frameCount: frameCount, format: .h3))
        #expect(selected.info.hasAudio)
        #expect(selected.info.width % 32 == 0 && selected.info.height % 32 == 0)
        #expect(abs(selected.range.start.seconds - 3 / 24.0) < 0.002)
        for (index, time) in timeline.times.enumerated() {
            #expect(abs(time.seconds - Double(index) / 24) < 0.002)
        }
        try project.approveTarget(
            id: id, sourceFile: output, name: id,
            selection: MediaSelection(
                originalName: id, startSeconds: selected.range.start.seconds, endSeconds: selected.range.end.seconds,
                frameCount: frameCount, videoWidth: selected.info.width, videoHeight: selected.info.height
            ), profile: VideoTrainingFormat.h3.rawValue
        )
        let reopened = try await StudioProject.open(at: directory)
        #expect(reopened.job.profile == "h3-video")
        #expect(reopened.mediaState.selections[id]?.frameCount == frameCount)
        #expect(reopened.mediaState.selections[id]?.startSeconds == selected.range.start.seconds)
        #expect(reopened.job.mapping(for: id) == reopened.job.wholeTargetMapping)
        let endpoint = ResolvedEndpoint(client: GeminiClient(
            apiKey: "fixture", model: "gemini-3.8-flash", transport: H3ClipTransport(expectedBytes: bytes)
        ))
        let summary = try await Runner(job: reopened.job, captioner: endpoint, critic: endpoint).run(
            source: LocalFolderSource(directory: reopened.imagesDirectory),
            sink: SidecarSink(directory: reopened.imagesDirectory)
        )
        #expect(summary.outcomes.first?.status == .written)
        #expect(try String(
            contentsOf: reopened.imagesDirectory.appendingPathComponent("clip.txt"), encoding: .utf8
        ) == H3ClipTransport.caption)
        let operations = try await ProjectPublisher.operations(for: reopened)
        guard case let .addFile(_, published) = try #require(operations.first { $0.path == id }) else {
            Issue.record("Expected the approved video file"); return
        }
        #expect(try Data(contentsOf: published) == bytes)
        try project.undoCuration()
        #expect(project.job.profile == "ltx-video")
        #expect(try Data(contentsOf: source) == Data(contentsOf: original))
        #expect(try Job.load(contentsOf: project.jobURL).profile == "ltx-video")
    }

    @Test func incompatibleCadenceAndFrameCountNeverReplaceTheTarget() async throws {
        let directory = temporaryTestDirectory("h3-refusal")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("source.mp4")
        try await MediaFixtures.video(at: source, times: (0 ..< 40).map { Double($0) / 30 })
        let before = try Data(contentsOf: source)
        let output = directory.appendingPathComponent("refused.mp4")
        await #expect(throws: StudioError.self) {
            try await MediaEditor.trim(
                url: source, startFrame: 0, frameCount: 22, longEdge: 512, output: output, format: .h3
            )
        }
        await #expect(throws: StudioError.self) {
            try await MediaEditor.trim(
                url: source, startFrame: 0, frameCount: 33, longEdge: 512, output: output, format: .h3
            )
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try Data(contentsOf: source) == before)
    }

    @Test @MainActor func approvalKeepsOtherCaptionsAndUndoPreservesALaterExplicitFormat() async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let original = project.directory.appendingPathComponent("clip.mp4")
        try await MediaFixtures.video(at: original, times: (0 ..< 50).map { Double($0) / 24 })
        try await project.importFiles([original])
        project.job.profile = "ltx-video"
        try project.save()
        let other = try #require(project.images.first { $0.id == "garden.jpg" })
        try await project.saveCaption(id: other.id, text: "NORA7 saved caption.", final: true)
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let session = makeTestSession(preferences: defaults.defaults)
        session.demoMode = true
        session.project = project
        defer { session.stopImageAnalysis() }
        session.approveVideoSegment(id: "clip.mp4", startFrame: 2, frameCount: 22, longEdge: 512, format: .h3)
        await session.task?.value
        #expect(session.errorMessage == nil)
        #expect(session.project?.job.profile == "h3-video")
        #expect(session.project?.images.first { $0.id == other.id }?.caption == "NORA7 saved caption.")
        #expect(session.project?.images.first { $0.id == other.id }?.isFinal == true)
        #expect(session.message.contains("other saved captions keep their text"))
        session.project?.job.profile = "plain"
        try session.project?.save()
        session.undoMediaCuration()
        #expect(session.project?.job.profile == "plain")
        #expect(try Job.load(contentsOf: project.jobURL).profile == "plain")
        #expect(try Data(contentsOf: project.imagesDirectory.appendingPathComponent("clip.mp4")) ==
            Data(contentsOf: original))
    }

    @Test @MainActor func changedProjectFormatCannotBeOverwrittenByPendingApproval() async throws {
        let directory = temporaryTestDirectory("h3-profile-handoff")
        defer { try? FileManager.default.removeItem(at: directory) }
        var project = try StudioProject.create(at: directory)
        let source = directory.appendingPathComponent("clip.mp4")
        try await MediaFixtures.video(at: source, times: (0 ..< 50).map { Double($0) / 24 })
        try await project.importFiles([source])
        let before = try Data(contentsOf: project.imagesDirectory.appendingPathComponent("clip.mp4"))
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let session = makeTestSession(preferences: defaults.defaults)
        session.demoMode = true
        session.project = project
        session.approveVideoSegment(id: "clip.mp4", startFrame: 2, frameCount: 22, longEdge: 512, format: .h3)
        session.project?.job.profile = "plain"
        await session.task?.value
        #expect(session.errorMessage?.contains("caption format changed") == true)
        #expect(session.project?.job.profile == "plain")
        #expect(session.project?.mediaState.selections["clip.mp4"] == nil)
        #expect(try Data(contentsOf: project.imagesDirectory.appendingPathComponent("clip.mp4")) == before)
    }

    @Test @MainActor func customSkillWithoutTheSelectedVideoProfileKeepsItsCurrentJobAndTarget() async throws {
        let directory = temporaryTestDirectory("h3-custom-skill")
        defer { try? FileManager.default.removeItem(at: directory) }
        var project = try StudioProject.create(at: directory)
        let source = directory.appendingPathComponent("clip.mp4")
        try await MediaFixtures.video(at: source, times: (0 ..< 30).map { Double($0) / 24 })
        try await project.importFiles([source])
        project.job.skill = try makeSkill(named: "custom-captions", in: directory, profile: "custom").path
        project.job.profile = "custom"
        try project.save()
        let before = try Data(contentsOf: project.imagesDirectory.appendingPathComponent("clip.mp4"))
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let session = makeTestSession(preferences: defaults.defaults)
        session.demoMode = true
        session.project = project
        session.approveVideoSegment(id: "clip.mp4", startFrame: 0, frameCount: 22, longEdge: 512, format: .h3)
        await session.task?.value
        #expect(session.errorMessage?.contains("unknown profile 'h3-video'") == true)
        #expect(session.project?.job.profile == "custom")
        #expect(try Job.load(contentsOf: project.jobURL).profile == "custom")
        #expect(try Data(contentsOf: project.imagesDirectory.appendingPathComponent("clip.mp4")) == before)
        #expect(session.project?.curationUndo.isEmpty == true)
    }
}

private enum H3MediaFixtures {
    static func audiovisualClip(at output: URL) async throws {
        let directory = output.deletingLastPathComponent()
        let video = directory.appendingPathComponent("pixels.mp4")
        try await MediaFixtures.video(at: video, times: (0 ..< 80).map { Double($0) / 24 }, width: 96, height: 64)
        let audio = directory.appendingPathComponent("tone.wav")
        try writeTone(to: audio)
        let videoAsset = AVURLAsset(url: video), audioAsset = AVURLAsset(url: audio)
        let videoTrack = try #require(try await videoAsset.loadTracks(withMediaType: .video).first)
        let audioTrack = try #require(try await audioAsset.loadTracks(withMediaType: .audio).first)
        let duration = try await videoTrack.load(.timeRange).duration
        let composition = AVMutableComposition()
        let picture = try #require(composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ))
        let sound = try #require(composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ))
        try picture.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: videoTrack, at: .zero)
        try sound.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: audioTrack, at: .zero)
        let export = try #require(AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ))
        try await export.export(to: output, as: .mp4)
    }

    private static func writeTone(to audio: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192_000))
        buffer.frameLength = buffer.frameCapacity
        let channel = try #require(buffer.floatChannelData?.pointee)
        for index in 0 ..< Int(buffer.frameLength) {
            channel[index] = Float(sin(Double(index) * 2 * .pi * 440 / 48000) * 0.05)
        }
        let file = try AVAudioFile(forWriting: audio, settings: format.settings)
        try file.write(from: buffer)
    }
}

private actor H3ClipTransport: HTTPTransport {
    static let caption = "integrated_multimodal_description: [Shot 1] MOVE8, a movement, appears on a colored surface "
        + "with a blue dot and green and white edge stripes.\n\noverall_soundscape: A steady tone is audible."
        + "\n\nnon_diegetic_music: N/A"
    let expectedBytes: Data

    init(expectedBytes: Data) {
        self.expectedBytes = expectedBytes
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let body = try JSONValue(parsing: #require(request.httpBody))
        let instructions = try #require(body.objectValue?["systemInstruction"]?.objectValue?["parts"]?.arrayValue?
            .first?.objectValue?["text"]?.stringValue)
        #expect(instructions.contains("Profile: MiniMax H3 training-caption format (video)"))
        #expect(instructions.contains("attached_target_video"))
        let parts = body.objectValue?["contents"]?.arrayValue?
            .flatMap { $0.objectValue?["parts"]?.arrayValue ?? [] } ?? []
        let video = try #require(parts.first { $0.objectValue?["inlineData"] != nil })
        #expect(video.objectValue?["inlineData"]?.objectValue?["data"]?.stringValue == expectedBytes
            .base64EncodedString())
        #expect(video.objectValue?["videoMetadata"]?.objectValue?["fps"] == .int(24))
        let text: String = if instructions.contains("REVIEW TASK") {
            Critique(approved: true).jsonValue.pythonDumps()
        } else {
            Caption(caption: Self.caption).jsonValue.pythonDumps()
        }
        let response: JSONValue = .object(["candidates": .array([
            .object(["content": .object(["parts": .array([.object(["text": .string(text)])])])]),
        ])])
        return HTTPResponse(status: 200, body: response.pythonDumpsData())
    }
}
