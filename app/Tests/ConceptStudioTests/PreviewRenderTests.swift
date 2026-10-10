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
            "chatgpt-sign-in", view: Form { ChatGPTSettingsSection(session: session) }.formStyle(.grouped),
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
                +
                "Concept editor is standalone sheet content. "
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
