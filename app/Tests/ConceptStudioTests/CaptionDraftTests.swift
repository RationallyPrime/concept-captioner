import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

@Suite("caption review drafts")
@MainActor
struct CaptionDraftTests {
    private func makeSession() async throws -> StudioSession {
        let session = makeTestSession()
        session.demoMode = true
        session.project = try await makeDemoProject()
        return session
    }

    @Test func draftsSurvivePhotoAndScreenNavigationWithoutWritingSidecars() async throws {
        let session = try await makeSession()
        let project = try #require(session.project)
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let first = try #require(project.images.first)
        let second = project.images[1]
        let sink = try SidecarSink(directory: project.imagesDirectory)
        let previous = try? Data(contentsOf: sink.captionURL(for: first.id))
        let draft = CaptionDraft(text: "NORA7 has a different caption.", isFinal: true)
        session.selectedImageID = first.id
        session.step = .review
        session.setCaptionDraft(draft, for: first.id)
        session.selectedImageID = second.id
        session.step = .publish
        session.saveProject()
        session.step = .review
        session.selectedImageID = first.id
        #expect(session.captionDraft(for: first) == draft)
        #expect(session.hasUnsavedCaption(for: first))
        #expect(session.unsavedCaptionCount == 1)
        #expect(session.project?.images.first?.caption == first.caption)
        #expect((try? Data(contentsOf: sink.captionURL(for: first.id))) == previous)
    }

    @Test func explicitSaveWritesCaptionAndFinalRecordWithoutClearingOtherDrafts() async throws {
        let session = try await makeSession()
        let project = try #require(session.project)
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let first = try #require(project.images.first)
        let second = project.images[1]
        let draft = CaptionDraft(text: "NORA7 is beside a window.", isFinal: true)
        session.setCaptionDraft(draft, for: first.id)
        session.setCaptionDraft(CaptionDraft(text: "NORA7 in the garden.", isFinal: false), for: second.id)
        session.saveCaption(id: first.id, text: draft.text, final: draft.isFinal)
        await session.editTask?.value
        let sink = try SidecarSink(directory: project.imagesDirectory)
        #expect(session.errorMessage == nil)
        #expect(try String(contentsOf: sink.captionURL(for: first.id), encoding: .utf8) == draft.text)
        #expect(try await sink.record(first.id)?.isHumanFinal == true)
        #expect(session.captionDrafts[first.id] == nil)
        #expect(session.captionDrafts[second.id] != nil)
        #expect(session.project?.images.first?.isFinal == true)
        #expect(session.unsavedCaptionCount == 1)
    }

    @Test func failedDiskSaveRetainsDraftForSuccessfulRetry() async throws {
        let session = try await makeSession()
        let project = try #require(session.project)
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let image = try #require(project.images.first)
        let draft = CaptionDraft(text: "NORA7 is in the studio.", isFinal: true)
        session.setCaptionDraft(draft, for: image.id)
        let held = project.directory.appendingPathComponent("held-images")
        try FileManager.default.moveItem(at: project.imagesDirectory, to: held)
        try Data("not a directory".utf8).write(to: project.imagesDirectory)
        session.saveCaption(id: image.id, text: draft.text, final: draft.isFinal)
        await session.editTask?.value
        #expect(session.errorMessage != nil)
        #expect(session.captionDraft(for: image) == draft)
        #expect(session.project?.images.first?.caption == image.caption)
        #expect(session.unsavedCaptionCount == 1)
        try FileManager.default.removeItem(at: project.imagesDirectory)
        try FileManager.default.moveItem(at: held, to: project.imagesDirectory)
        session.saveCaption(id: image.id, text: draft.text, final: draft.isFinal)
        await session.editTask?.value
        #expect(session.errorMessage == nil)
        #expect(session.captionDrafts[image.id] == nil)
        #expect(session.project?.images.first?.caption == draft.text)
    }

    @Test func completingEarlierSavePreservesLaterDraft() async throws {
        let session = try await makeSession()
        let project = try #require(session.project)
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let image = try #require(project.images.first)
        let saved = CaptionDraft(text: "NORA7 first saved caption.", isFinal: false)
        let later = CaptionDraft(text: "NORA7 later unsaved caption.", isFinal: true)
        session.setCaptionDraft(saved, for: image.id)
        session.saveCaption(id: image.id, text: saved.text, final: saved.isFinal)
        session.setCaptionDraft(later, for: image.id)
        await session.editTask?.value
        #expect(session.errorMessage == nil)
        #expect(session.project?.images.first?.caption == saved.text)
        #expect(session.captionDraft(for: image) == later)
        #expect(session.unsavedCaptionCount == 1)
    }

    @Test func discardRestoresSavedValuesWithoutWritingAndReleaseClearsDrafts() async throws {
        let session = try await makeSession()
        let project = try #require(session.project)
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let image = try #require(project.images.first)
        let sink = try SidecarSink(directory: project.imagesDirectory)
        let previous = try? Data(contentsOf: sink.captionURL(for: image.id))
        session.setCaptionDraft(CaptionDraft(text: "NORA7 unsaved.", isFinal: !image.isFinal), for: image.id)
        session.discardCaptionDraft(for: image)
        #expect(session.captionDraft(for: image) == CaptionDraft(text: image.caption, isFinal: image.isFinal))
        #expect(session.unsavedCaptionCount == 0)
        #expect((try? Data(contentsOf: sink.captionURL(for: image.id))) == previous)
        session.setCaptionDraft(CaptionDraft(text: "NORA7 another draft.", isFinal: true), for: image.id)
        await session.releaseProject()
        #expect(session.captionDrafts.isEmpty)
        #expect(session.project == nil)
    }

    @Test func invalidSaveKeepsDraftAndSavedCaption() async throws {
        let session = try await makeSession()
        let project = try #require(session.project)
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let image = try #require(project.images.first)
        let draft = CaptionDraft(text: " \n", isFinal: true)
        session.setCaptionDraft(draft, for: image.id)
        session.saveCaption(id: image.id, text: draft.text, final: draft.isFinal)
        await session.editTask?.value
        #expect(session.errorMessage?.contains("Write a caption") == true)
        #expect(session.captionDraft(for: image) == draft)
        #expect(session.project?.images.first?.caption == image.caption)
    }

    @Test(arguments: [true, false])
    func discardOrUndoCannotMaskAnActualRecaptionResult(discard: Bool) async throws {
        let session = try await makeSession()
        let project = try #require(session.project)
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let image = try #require(project.images.first)
        session.setCaptionDraft(CaptionDraft(text: "NORA7 temporary edit.", isFinal: true), for: image.id)
        if discard {
            session.discardCaptionDraft(for: image)
        } else {
            session.setCaptionDraft(CaptionDraft(text: image.caption, isFinal: image.isFinal), for: image.id)
        }
        #expect(session.captionDrafts[image.id] == nil)
        session.caption(only: [image.id], overwrite: true)
        await session.task?.value
        let updated = try #require(session.project?.images.first)
        #expect(session.errorMessage == nil)
        #expect(updated.caption != image.caption)
        #expect(session.captionDraft(for: updated) == CaptionDraft(text: updated.caption, isFinal: updated.isFinal))
        #expect(session.unsavedCaptionCount == 0)
    }

    @Test func closingWarningReflectsPendingDraftsWithoutDiscardingThem() async throws {
        let session = try await makeSession()
        let project = try #require(session.project)
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let image = try #require(project.images.first)
        #expect(session.captionDiscardWarning == nil)
        #expect(!session.needsCloseConfirmation)
        let draft = CaptionDraft(text: "NORA7 caption to keep.", isFinal: true)
        session.setCaptionDraft(draft, for: image.id)
        #expect(session.captionDiscardWarning?.contains("1 unsaved") == true)
        #expect(session.needsCloseConfirmation)
        #expect(!session.busy && !session.gpu.hasRunningPod && !session.gpu.isBusy)
        #expect(session.captionDraft(for: image) == draft)
        session.discardCaptionDraft(for: image)
        #expect(session.captionDiscardWarning == nil)
        #expect(!session.needsCloseConfirmation)
    }
}
