import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

@Suite("media intake and recent recovery")
@MainActor
struct MediaIntakeTests {
    @Test func removingARecentEntryKeepsTheProjectOnDisk() throws {
        let preferences = IsolatedDefaults()
        defer { preferences.remove() }
        let folder = temporaryTestDirectory("remove-recent")
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = try StudioProject.create(at: folder)
        let session = makeTestSession(preferences: preferences.defaults)
        session.rememberRecent(folder)
        #expect(session.recentPaths == [folder.path])
        session.forgetRecent(folder.path)
        #expect(session.recentPaths.isEmpty)
        #expect(session.recents.entries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: project.jobURL.path))
    }

    @Test(arguments: [0, 1, 1_048_577, 3_145_729])
    func fileHashesMatchAcrossChunkBoundaries(count: Int) async throws {
        let folder = temporaryTestDirectory("stream-hash")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("clip.mp4")
        let data = Data((0 ..< count).map { UInt8(truncatingIfNeeded: $0) })
        try data.write(to: file)
        #expect(try await VisionInspector.contentHash(fileURL: file) == VisionInspector.contentHash(data))
        let cancelled = Task { try await VisionInspector.contentHash(fileURL: file) }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }

    @Test func photosVideoImportKeepsExactBytesAndRemovesItsTransferCopy() async throws {
        let folder = temporaryTestDirectory("photos-video-intake")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("Holiday.MP4")
        try await MediaFixtures.video(at: original, times: (0 ..< 9).map { Double($0) / 24 })
        let sourceHash = try await VisionInspector.contentHash(fileURL: original)
        let session = makeTestSession()
        session.project = try StudioProject.create(at: folder.appendingPathComponent("project"))

        func importAndReleaseTransfer() async throws -> URL {
            let picked = try PickedPhoto.copyVideo(from: original)
            guard case let .video(copy) = picked.content else {
                Issue.record("Photos clip was loaded as image data")
                throw StudioError.message("Expected a file-backed video transfer")
            }
            #expect(copy != original)
            #expect(FileManager.default.fileExists(atPath: copy.path))
            #expect(try await session.importPickedPhoto(picked))
            #expect(try await !session.importPickedPhoto(picked))
            return copy
        }

        let temporaryCopy = try await importAndReleaseTransfer()
        let imported = try #require(session.project?.images.first)
        #expect(imported.id == "Holiday-\(sourceHash.prefix(8)).mp4")
        #expect(try await VisionInspector.contentHash(fileURL: imported.url) == sourceHash)
        #expect(try await MediaEditor.videoTimeline(url: imported.url).times.count == 9)
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(!FileManager.default.fileExists(atPath: temporaryCopy.path))
    }
}
