import AppKit
import ConceptCore
@testable import ConceptStudio
import SwiftUI
import Testing

@Suite("view logic")
@MainActor
struct ViewLogicTests {
    @Test func journeyOrderComesFromAllCases() {
        let preferences = IsolatedDefaults()
        defer { preferences.remove() }
        let session = StudioSession(preferences: preferences.defaults, secrets: MemorySecretStore())
        #expect(session.previousStep == nil)
        session.step = .monitor
        #expect(session.nextStep == nil)
        for (earlier, later) in zip(StudioStep.allCases, StudioStep.allCases.dropFirst()) {
            session.step = earlier
            #expect(session.nextStep == later)
            session.step = later
            #expect(session.previousStep == earlier)
        }
    }

    @Test func switchingProviderKeepsATypedModel() {
        let typed = ProviderChoices.model(afterSwitchingFrom: "openrouter", to: "google", current: "my/custom-model")
        #expect(typed == "my/custom-model")
        let untouched = ProviderChoices.model(
            afterSwitchingFrom: "openrouter", to: "google", current: ProviderChoices.defaultModel(for: "openrouter")
        )
        #expect(untouched == ProviderChoices.defaultModel(for: "google"))
        #expect(ProviderChoices.model(afterSwitchingFrom: "google", to: "anthropic", current: "")
            == ProviderChoices.defaultModel(for: "anthropic"))
    }

    @Test func aPromptResumesOnceWithTheAnswer() async {
        let suite = "ConceptStudio.viewlogic." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite) ?? .standard
        defer { preferences.removePersistentDomain(forName: suite) }
        let session = StudioSession(preferences: preferences)
        async let choice = session.ask(.discardCaptionDrafts(warning: "2 unsaved caption edits"))
        await waitForPrompt(session)
        let prompt = session.pendingPrompt
        #expect(prompt?.confirmTitle == "Discard edits")
        #expect(prompt?.alternateTitle == nil)
        if let prompt {
            session.answer(prompt, .confirm)
            session.answer(prompt, .cancel) // a second answer is ignored
        }
        #expect(await choice == .confirm)
        #expect(session.pendingPrompt == nil)
    }

    @Test func aNewerPromptCancelsTheOlderOne() async {
        let suite = "ConceptStudio.viewlogic." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite) ?? .standard
        defer { preferences.removePersistentDomain(forName: suite) }
        let session = StudioSession(preferences: preferences)
        async let first = session.ask(.discardCaptionDrafts(warning: "first"))
        await waitForPrompt(session)
        let older = session.pendingPrompt?.id
        async let second = session.ask(.stopWithPendingResult)
        await waitForPrompt(session, other: older)
        #expect(await first == .cancel)
        if let prompt = session.pendingPrompt { session.answer(prompt, .alternate) }
        #expect(await second == .alternate)
    }

    private func waitForPrompt(_ session: StudioSession, other: UUID? = nil) async {
        _ = await eventually { session.pendingPrompt != nil && session.pendingPrompt?.id != other }
    }

    @Test func cancellingTheWaitAnswersCancelAndWithdrawsThePrompt() async {
        let suite = "ConceptStudio.viewlogic." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite) ?? .standard
        defer { preferences.removePersistentDomain(forName: suite) }
        let session = StudioSession(preferences: preferences)
        let waiting = Task { await session.ask(.stopWithPendingResult) }
        await waitForPrompt(session)
        #expect(session.pendingPrompt != nil)
        waiting.cancel()
        #expect(await waiting.value == .cancel)
        #expect(await eventually { session.pendingPrompt == nil })
        // Already cancelled before asking: answers at once and shows nothing.
        let early = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await session.ask(.stopWithPendingResult)
        }
        #expect(await early.value == .cancel)
        #expect(session.pendingPrompt == nil)
    }

    @Test func returnNeverDiscardsEditsOrSpendsMore() {
        func prompt(_ kind: StudioPrompt.Kind) -> StudioPrompt {
            StudioPrompt(kind: kind, reply: StudioPromptReply())
        }
        #expect(!prompt(.discardCaptionDrafts(warning: "1 edit")).confirmIsDefault)
        #expect(!prompt(.raiseBudget(from: 5, to: 10, hourlyRate: 1)).confirmIsDefault)
        #expect(prompt(.stopWithPendingResult).confirmIsDefault)
        let work = StudioPrompt.RunningWork(
            hasRunningPod: true, hourlyRate: 1, spent: 0, offerKeepRunning: true, purpose: .quit
        )
        #expect(prompt(.stopWork(work)).confirmIsDefault)
    }

    @Test func keepRunningIsOfferedOnlyWhenQuittingWithARunningComputer() {
        let quitting = StudioPrompt(
            kind: .stopWork(.init(
                hasRunningPod: true, hourlyRate: 1.5, spent: 0.75, offerKeepRunning: true, purpose: .quit
            )),
            reply: StudioPromptReply()
        )
        #expect(quitting.confirmTitle == "Stop and quit")
        #expect(quitting.alternateTitle == "Keep the computer running")
        #expect(quitting.message.contains(StudioMoney.format(1.5)))
        #expect(quitting.message.contains("Reopen ConceptStudio to stop it"))
        let closing = StudioPrompt(
            kind: .stopWork(.init(
                hasRunningPod: true, hourlyRate: nil, spent: 0, offerKeepRunning: false, purpose: .closeProject
            )),
            reply: StudioPromptReply()
        )
        #expect(closing.alternateTitle == nil)
    }

    @Test func thumbnailsAreDownsampledAndCached() async throws {
        let url = try #require(Bundle.module.url(forResource: "Demo", withExtension: nil)?
            .appendingPathComponent("images/garden.png"))
        let key = PhotoThumbnails.Key(url: url, pixels: 128)
        let image = try #require(await PhotoThumbnails.load(key))
        #expect(max(image.size.width, image.size.height) <= 128)
        // Render tests in parallel suites switch projects, which flushes the shared cache; a flush between
        // these two lines is not a failure, but a different cached image would be.
        if let cached = PhotoThumbnails.cached(key) { #expect(cached === image) }
        #expect(PhotoThumbnails.bucket(for: 100) == 128)
        #expect(PhotoThumbnails.bucket(for: 129) == 256)
        #expect(PhotoThumbnails.bucket(for: 9000) == 2048)
        let missing = PhotoThumbnails.Key(url: URL(fileURLWithPath: "/nonexistent/photo.png"), pixels: 128)
        #expect(await PhotoThumbnails.load(missing) == nil)
    }
}

/// Polls `condition` until it holds or `seconds` of real time pass. A fixed number of yields is not enough
/// when the parallel run keeps the main actor busy.
@MainActor
func eventually(within seconds: Double = 30, _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

/// The draft-discard and close decisions, driven through the window prompts with the offline demo.
/// Serialized: every test opens the demo, and opening it runs `VisionInspector.analyze`, which blocks a
/// cooperative thread on synchronous Vision text recognition. Five of these in parallel with the other
/// suites exhausted the cooperative pool and the whole run hung inside Vision (sampled 2026-10-11).
@Suite("close and switch decisions", .serialized)
@MainActor
struct CloseDecisionTests {
    /// An open demo project with one unsaved caption edit; `rent` also starts the demo computer.
    private func demoSession(rent: Bool) async throws -> StudioSession {
        let suite = "ConceptStudio.close." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        let session = StudioSession(preferences: preferences)
        session.useDemo()
        await session.task?.value
        let image = try #require(session.project?.images.first)
        session.setCaptionDraft(CaptionDraft(text: "NORA7 edited by hand.", isFinal: false), for: image.id)
        if rent {
            await session.gpu.refreshOffers()
            await session.gpu.rent()
            #expect(session.gpu.hasRunningPod)
        }
        return session
    }

    private func cleanUp(_ session: StudioSession) async {
        let directory = session.project?.directory
        await session.gpu.stopEverything()
        await session.closeProject()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// Waits for a prompt other than `previous` and returns it.
    private func nextPrompt(_ session: StudioSession, after previous: UUID? = nil) async -> StudioPrompt? {
        guard await eventually({ session.pendingPrompt.map { $0.id != previous } ?? false }) else { return nil }
        return session.pendingPrompt
    }

    @Test func aRefusedProjectSwitchKeepsTheDrafts() async throws {
        let session = try await demoSession(rent: true)
        session.useDemo()
        // The switch refuses before asking because the computer is running; the edits remain.
        #expect(session.errorMessage?.contains("Stop the rented computer") == true)
        #expect(session.pendingPrompt == nil)
        #expect(session.unsavedCaptionCount == 1)
        await cleanUp(session)
    }

    @Test func aConfirmedSwitchClearsTheDraftsOnlyWhenTheProjectChanges() async throws {
        let session = try await demoSession(rent: false)
        session.useDemo()
        let prompt = try #require(await nextPrompt(session))
        #expect(session.unsavedCaptionCount == 1)
        session.answer(prompt, .confirm)
        // The demo reopens in its one location, so wait for the switch itself rather than a new folder.
        #expect(await eventually { session.unsavedCaptionCount == 0 && !session.busy })
        await session.task?.value
        #expect(session.project != nil, "\(session.errorMessage ?? session.message)")
        await cleanUp(session)
    }

    @Test func closeProjectNeverOffersKeepRunningAndCancelKeepsEverything() async throws {
        let session = try await demoSession(rent: true)
        async let decision = session.decideClose(.closeProject)
        let discard = try #require(await nextPrompt(session))
        session.answer(discard, .confirm)
        let stop = try #require(await nextPrompt(session, after: discard.id))
        guard case let .stopWork(work) = stop.kind else { Issue.record("expected the stop prompt"); return }
        #expect(!work.offerKeepRunning)
        #expect(stop.alternateTitle == nil)
        session.answer(stop, .cancel)
        #expect(await decision == nil)
        #expect(session.project != nil)
        #expect(session.gpu.hasRunningPod)
        #expect(session.unsavedCaptionCount == 1)
        await cleanUp(session)
    }

    @Test func quittingCanKeepTheComputerRunning() async throws {
        let session = try await demoSession(rent: true)
        async let decision = session.decideClose(.quit)
        let discard = try #require(await nextPrompt(session))
        session.answer(discard, .confirm)
        let stop = try #require(await nextPrompt(session, after: discard.id))
        #expect(stop.alternateTitle == "Keep the computer running")
        session.answer(stop, .alternate)
        #expect(await decision == .keepRunning)
        // Keep running skips the pending-result question.
        #expect(session.pendingPrompt == nil)
        #expect(await session.carryOut(.keepRunning))
        #expect(session.gpu.hasRunningPod)
        #expect(session.gpu.pod != nil)
        await cleanUp(session)
    }

    @Test func aConfirmedCloseStopsAndClearsTheDrafts() async throws {
        let session = try await demoSession(rent: true)
        let directory = session.project?.directory
        async let decision = session.decideClose(.closeProject)
        let discard = try #require(await nextPrompt(session))
        session.answer(discard, .confirm)
        let stop = try #require(await nextPrompt(session, after: discard.id))
        session.answer(stop, .confirm)
        let result = await decision
        #expect(result == .stop(discardingPendingResult: false))
        // Deciding alone discards nothing; carrying it out does, once the computer is confirmed stopped.
        #expect(session.unsavedCaptionCount == 1)
        if let result { #expect(await session.carryOut(result)) }
        #expect(!session.gpu.hasRunningPod)
        #expect(session.project == nil)
        #expect(session.captionDrafts.isEmpty)
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }
}
