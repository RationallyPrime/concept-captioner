import AppKit
import ConceptCore
@testable import ConceptStudio
import SwiftUI
import Testing

private struct ChatGPTPreviewWire: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        guard request.url?.absoluteString == "https://api.openai.com/v1/models" else {
            throw StudioError.message("Only the synthetic model catalog is available in previews.")
        }
        return HTTPResponse(status: 200, body: Data("""
        {"models":[
          {"slug":"example-vision","display_name":"Example vision model","visibility":"list"},
          {"slug":"example-fast","display_name":"Example fast model","visibility":"list"}
        ]}
        """.utf8))
    }
}

@Suite(
    "offscreen app previews",
    .enabled(if: ProcessInfo.processInfo.environment["CONCEPTSTUDIO_RENDER_PREVIEWS"] == "1")
)
@MainActor
struct PreviewRenderTests {
    private let sizes: [(String, CGSize)] = [
        ("minimum", CGSize(width: 980, height: 680)),
        ("default", CGSize(width: 1240, height: 820)),
    ]

    @Test func renderActualScreens() async throws {
        let output = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["CONCEPTSTUDIO_PREVIEW_OUTPUT"]
                ?? "/tmp/conceptstudio-offscreen-previews",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let filter = Set((ProcessInfo.processInfo.environment["CONCEPTSTUDIO_PREVIEW_SCREENS"] ?? "")
            .split(separator: ",").map(String.init))
        let suite = "ConceptStudio.previews." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let session = StudioSession(preferences: preferences)
        session.recentPaths = []
        session.demoMode = true
        session.gpu = GPUWorkspace(demoMode: true, preferences: preferences)
        NSApplication.shared.setActivationPolicy(.prohibited)
        let originalAppearance = NSApplication.shared.appearance
        defer { NSApplication.shared.appearance = originalAppearance }
        var captures: [[String: String]] = []
        if let garden = Bundle.module.url(forResource: "Demo", withExtension: nil)?
            .appendingPathComponent("images/garden.png") {
            await prewarmThumbnails([garden])
        }
        try await capture(
            "welcome",
            view: StudioRootView(session: session),
            output: output,
            filter: filter,
            captures: &captures
        )
        session.useDemo()
        await session.task?.value
        #expect(session.errorMessage == nil)
        #expect(session.demoMode)
        let projectDirectory = try #require(session.project?.directory)
        defer { try? FileManager.default.removeItem(at: projectDirectory) }
        session.gpu = GPUWorkspace(demoMode: true, preferences: preferences)
        await prewarmThumbnails(session.project?.images.map(\.url) ?? [])
        for step in StudioStep.allCases {
            if step == .review {
                session.caption()
                await session.task?.value
            }
            if step == .pods { await session.gpu.refreshOffers() }
            if step == .training {
                session.gpu.gpuCount = 2
                await session.gpu.rent()
                await session.gpu.refresh()
            }
            if step == .monitor {
                await session.gpu.train(datasetRepo: session.repoID)
                for _ in 0 ..< 4 {
                    await session.gpu.refresh()
                }
            }
            session.step = step
            let name = step == .pods ? "gpu" : String(describing: step)
            try await capture(
                name,
                view: StudioRootView(session: session),
                output: output,
                filter: filter,
                captures: &captures
            )
            try await captureStates(of: step, session: session, output: output, filter: filter, captures: &captures)
        }
        try await captureAuxiliaryScreens(session: session, output: output, filter: filter, captures: &captures)
        await session.gpu.stopEverything()
        #expect(!session.gpu.hasRunningPod)
        try await captureChatGPT(
            project: session.project,
            preferences: preferences,
            output: output,
            filter: filter,
            captures: &captures
        )
        try writeManifest(captures, to: output)
        print("OFFSCREEN PREVIEWS: \(output.path) (\(captures.count) PNGs)")
    }

    /// Extra states of a journey screen: a prefilled suggestion, a multi-selection, a running computer, tabs.
    private func captureStates(
        of step: StudioStep, session: StudioSession, output: URL, filter: Set<String>,
        captures: inout [[String: String]]
    ) async throws {
        let root = StudioRootView(session: session)
        switch step {
        case .mapping:
            let image = try #require(session.project?.images.last)
            let trigger = try #require(session.project?.job.concepts.first?.trigger)
            let confirmed = session.project?.job.mapping(for: image.id)
            try session.project?.job.setMapping(nil, for: image.id)
            session.mappingProposals[image.id] = [trigger: "the person on the left in a green jacket"]
            session.selectedImageID = image.id
            try await capture("mapping-suggested", view: root, output: output, filter: filter, captures: &captures)
            try session.project?.job.setMapping(confirmed, for: image.id)
            session.mappingProposals = [:]
        case .review:
            let ids = session.project?.images.map(\.id) ?? []
            session.reviewSelection = Set(ids.prefix(2))
            try await capture("review-several", view: root, output: output, filter: filter, captures: &captures)
            session.reviewSelection = Set(ids.prefix(1))
        case .training:
            session.step = .pods
            try await capture("gpu-running", view: root, output: output, filter: filter, captures: &captures)
        case .monitor:
            for tab in [MonitorTab.tensorBoard, .log] {
                session.monitorTab = tab
                let name = tab == .log ? "monitor-log" : "monitor-tensorboard"
                try await capture(name, view: root, output: output, filter: filter, captures: &captures)
            }
            session.monitorTab = .progress
        default:
            return
        }
    }

    private func captureAuxiliaryScreens(
        session: StudioSession, output: URL, filter: Set<String>, captures: inout [[String: String]]
    ) async throws {
        try await capture(
            "concept-editor", view: ConceptEditor(session: session, existing: session.project?.job.concepts.first),
            output: output, filter: filter, captures: &captures,
            renderSizes: [("sheet", CGSize(width: 660, height: 650))]
        )
        try await capture(
            "settings",
            view: StudioSettingsView(session: session),
            output: output,
            filter: filter,
            captures: &captures
        )
        let results: [(String, TrainingResult.State?)] = [
            ("result-pending", .pending),
            ("result-pushed", .pushed(repo: "your-name/nora7-lora")),
            ("result-saved", .saved(folder: "/Users/you/NORA7 project/results/concept-0123456789ab")),
        ]
        for (name, state) in results {
            try await capture(
                name,
                view: TrainingResultSection(state: state, busy: false) {}.padding(24)
                    .frame(maxHeight: .infinity, alignment: .top),
                output: output, filter: filter, captures: &captures,
                renderSizes: [("section", CGSize(width: 760, height: 240))]
            )
        }
    }

    private func prewarmThumbnails(_ urls: [URL]) async {
        for url in urls {
            for pixels in PhotoThumbnails.buckets {
                _ = await PhotoThumbnails.load(PhotoThumbnails.Key(url: url, pixels: pixels))
            }
        }
    }

    private func captureChatGPT(
        project: StudioProject?, preferences: UserDefaults, output: URL, filter: Set<String>,
        captures: inout [[String: String]]
    ) async throws {
        guard filter.isEmpty || filter.contains(where: { $0.hasPrefix("chatgpt-") }) else { return }
        let state = ChatGPTSavedState(hostID: "urn:uuid:preview-only", registrations: [
            ChatGPTRegistration(
                clientID: "oaiapp_preview_account", subject: "preview-only", email: "preview@example.invalid",
                tokens: ChatGPTTokens(
                    accessToken: "synthetic-preview-access", refreshToken: "synthetic-preview-refresh",
                    idToken: "synthetic-preview-identity", scopes: [ChatGPTAuth.directScope],
                    expiresAt: Date.distantFuture, nonce: "preview-only"
                )
            ),
        ])
        let data = try JSONEncoder().encode(state)
        let accounts = ChatGPTAccounts(
            preferences: preferences, transport: ChatGPTPreviewWire(),
            loadCredentials: { data }, saveCredentials: { _ in },
            openBrowser: { _ in throw StudioError.message("Browser sign-in is disabled in previews.") }
        )
        let session = StudioSession(preferences: preferences, chatGPT: accounts)
        session.gpu = GPUWorkspace(demoMode: true, preferences: preferences)
        session.project = project
        session.step = .captioning
        session.endpointKind = "openai"
        session.modelName = "example-vision"
        session.openAIUsesChatGPT = true
        // Render the actual account section without Settings' unrelated API-key status reads.
        try await capture(
            "chatgpt-sign-in", view: ChatGPTSettingsSection(session: session).padding(24)
                .frame(maxHeight: .infinity, alignment: .top),
            output: output, filter: filter, captures: &captures,
            renderSizes: [("section", CGSize(width: 700, height: 300))]
        )
        await accounts.load()
        await accounts.refreshModels()
        #expect(accounts.availableModels.count == 2)
        try await capture(
            "chatgpt-captioning",
            view: StudioRootView(session: session),
            output: output,
            filter: filter,
            captures: &captures
        )
        await accounts.cancelAndWait()
    }

    private func writeManifest(_ captures: [[String: String]], to output: URL) throws {
        let metadata: [String: Any] = [
            "method": "NSHostingView in a never-shown NSWindow; offscreen cacheDisplay, no desktop screenshot",
            "fixtures": "Actual DemoProject, demo model actions and DemoGPUProvider; isolated UserDefaults. "
                + "ChatGPT captures use a synthetic account/model catalog and injected credentials/HTTP/browser seams.",
            "appearance": "Light/dark scheme with simulated controlActiveState.key; no key window or activation",
            "limits": "Content only; native sidebar vibrancy may differ from a visible window. "
                + "Concept editor and trained-model result sections are standalone content. "
                + "Window alerts (close, quit, discard, budget prompts) are not drawn offscreen. "
                + "No titlebar, input, focus, VoiceOver or live-service proof.",
            "pixel_scale": 1, "captures": captures,
        ]
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("render-manifest.json"))
    }

    private func capture(
        _ name: String, view: some View, output: URL, filter: Set<String>, captures: inout [[String: String]],
        renderSizes: [(String, CGSize)]? = nil
    ) async throws {
        guard filter.isEmpty || filter.contains(name) else { return }
        for (theme, scheme, appearanceName) in [
            ("light", ColorScheme.light, NSAppearance.Name.aqua),
            ("dark", ColorScheme.dark, NSAppearance.Name.darkAqua),
        ] {
            for (sizeName, size) in renderSizes ?? sizes {
                let content = view
                    .environment(\.colorScheme, scheme)
                    .environment(\.controlActiveState, .key)
                    .environment(\.locale, Locale(identifier: "en_US"))
                    .frame(width: size.width, height: size.height)
                    .background(Color(nsColor: .windowBackgroundColor))
                let appearance = try #require(NSAppearance(named: appearanceName))
                NSApplication.shared.appearance = appearance
                let host = NSHostingView(rootView: content)
                host.appearance = appearance
                host.frame = CGRect(origin: .zero, size: size)
                let window = NSWindow(
                    contentRect: CGRect(origin: .zero, size: size),
                    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
                )
                window.isReleasedWhenClosed = false
                window.appearance = appearance
                window.contentView = host
                defer {
                    window.contentView = nil
                    window.delegate = nil
                    window.close()
                }
                host.layoutSubtreeIfNeeded()
                await Task.yield()
                try await Task.sleep(for: .milliseconds(40))
                var bitmap: NSBitmapImageRep?
                appearance.performAsCurrentDrawingAppearance {
                    host.layoutSubtreeIfNeeded()
                    bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)
                    if let bitmap { host.cacheDisplay(in: host.bounds, to: bitmap) }
                }
                let image = try #require(bitmap)
                #expect(!window.isVisible)
                #expect(image.pixelsWide == Int(size.width))
                #expect(image.pixelsHigh == Int(size.height))
                let png = try #require(image.representation(using: .png, properties: [:]))
                let filename = "\(name)-\(theme)-\(sizeName).png"
                try png.write(to: output.appendingPathComponent(filename))
                captures.append([
                    "screen": name, "theme": theme, "size": sizeName, "file": filename,
                    "width": String(image.pixelsWide), "height": String(image.pixelsHigh),
                ])
            }
        }
    }
}

/// View-layer logic behind the screens; runs in every test pass, no network.
@Suite("view logic")
@MainActor
struct ViewLogicTests {
    @Test func journeyOrderComesFromAllCases() {
        #expect(StudioStep.allCases.first?.stepBefore == nil)
        #expect(StudioStep.allCases.last?.stepAfter == nil)
        for (earlier, later) in zip(StudioStep.allCases, StudioStep.allCases.dropFirst()) {
            #expect(earlier.stepAfter == later)
            #expect(later.stepBefore == earlier)
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
        for _ in 0 ..< 100 where session.pendingPrompt == nil || session.pendingPrompt?.id == other {
            await Task.yield()
        }
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
        #expect(PhotoThumbnails.cached(key) === image)
        #expect(PhotoThumbnails.bucket(for: 100) == 128)
        #expect(PhotoThumbnails.bucket(for: 129) == 256)
        #expect(PhotoThumbnails.bucket(for: 9000) == 2048)
        let missing = PhotoThumbnails.Key(url: URL(fileURLWithPath: "/nonexistent/photo.png"), pixels: 128)
        #expect(await PhotoThumbnails.load(missing) == nil)
    }
}
