import ConceptCore
import SwiftUI

enum ModelChoices {
    static let providers = ["openrouter", "vercel", "gateway/anthropic", "google", "anthropic", "openai", "vllm"]
    static func title(_ kind: String) -> String {
        [
            "openrouter": "OpenRouter gateway",
            "vercel": "Vercel AI Gateway",
            "gateway/anthropic": "Pydantic AI Gateway",
            "google": "Google Gemini",
            "anthropic": "Anthropic Claude",
            "openai": "OpenAI",
            "vllm": "My pod / custom server",
        ][kind] ?? kind
    }
}

struct CaptioningView: View {
    @Bindable var session: StudioSession
    @State private var overwrite = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("Captioning choices") {
                    Form {
                        Picker("Account", selection: $session.endpointKind) {
                            ForEach(ModelChoices.providers, id: \.self) { Text(ModelChoices.title($0)).tag($0) }
                        }
                        TextField("Model", text: $session.modelName)
                            .help("Your gateway can use many models with one saved key.")
                        Picker(
                            "Caption format",
                            selection: Binding(get: { session.project?.job.profile ?? "flux-image" }, set: {
                                session.project?.job.profile = $0; session.saveProject()
                            })
                        ) {
                            ForEach(profiles, id: \.self) { Text($0).tag($0) }
                        }
                        HStack {
                            Text(session.project?.job.skill == nil ? "Bundled concept-boundary instructions" : session
                                .project?.job.skill ?? "")
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Choose skill folder…") { session.chooseSkill() }
                            if session.project?.job.skill != nil {
                                Button("Use bundled") { session.project?.job.skill = nil; session.saveProject() }
                            }
                        }
                        Toggle("Have a second model check the caption", isOn: $session.useCritic)
                        if session.useCritic {
                            Picker("Reviewer account", selection: $session.criticKind) {
                                ForEach(ModelChoices.providers, id: \.self) { Text(ModelChoices.title($0)).tag($0) }
                            }
                            TextField("Reviewer model", text: $session.criticModel)
                            if session.criticKind == "vllm" {
                                TextField(
                                    "Reviewer server URL (blank uses Settings)",
                                    text: $session.criticRequestBaseURL
                                )
                            }
                        }
                        DisclosureGroup("Advanced controls") {
                            Picker("Thinking effort", selection: $session.modelThinking) {
                                ForEach(ThinkingLevel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            if session.useCritic {
                                Picker("Reviewer thinking effort", selection: $session.criticThinking) {
                                    ForEach(ThinkingLevel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                                }
                            }
                            Picker("Structured response mode", selection: $session.outputMode) {
                                ForEach(OutputMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            Stepper("\(session.concurrency) photos at once", value: $session.concurrency, in: 1 ... 16)
                            if session.endpointKind == "vllm" { TextField(
                                "Server URL for this project (blank uses Settings)",
                                text: $session.requestBaseURL
                            ) }
                            Toggle("Re-caption existing model captions", isOn: $overwrite)
                            Text("Final captions are always protected. Turn this on to replace earlier model captions.")
                                .font(.caption)
                        }
                    }.padding(10)
                }.disabled(session.busy)
                GroupBox("Caption on a rented computer") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Hosted captioning needs no rented GPU. For a local model, rent a computer first, "
                            + "caption on GPU 0, then return to training after Review and Publish.")
                        HStack {
                            Button("Rent or choose a captioning computer") { session.step = .pods }
                            Button("Start caption server and use this computer") { session.usePodCaptionServer() }
                                .disabled(session.busy || !session.gpu.hasRunningPod)
                        }
                        if session.usingPodCaptioner {
                            Text("Using your authenticated computer's caption server.").font(.caption)
                            Button("Use my Settings server instead") {
                                session.usingPodCaptioner = false
                                session.requestBaseURL = ""
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                if session.demoMode {
                    Picker("Demo outcome to try", selection: $session.scenario) {
                        ForEach(DemoScenario.allCases) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    Text(
                        "Rejected demonstrates the optional critic; enable it for that outcome. "
                            + "Clear a mapping on the Mapping screen to try Needs mapping."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                if session.unmappedCount > 0 {
                    Label(
                        "\(session.unmappedCount) photos still need mapping. "
                            + "They will be skipped until you confirm them.",
                        systemImage: "person.crop.rectangle"
                    )
                    .foregroundStyle(.orange)
                }
                Text(session
                    .demoMode ? "Demo captioning costs $0 and stays offline." :
                    "Uses your provider account credits. No rented GPU is needed for hosted captioning.")
                    .foregroundStyle(.secondary)
                Button("Start captioning", systemImage: "play.fill") { session.caption(overwrite: overwrite) }
                    .buttonStyle(.borderedProminent).disabled(session.busy || session.project?.images.isEmpty != false)
                ForEach(session.project?.images ?? []) { image in
                    HStack {
                        Text(image.id).frame(width: 170, alignment: .leading)
                        Text(image.status?.rawValue.replacingOccurrences(of: "_", with: " ") ?? "Ready")
                            .font(.callout.bold())
                        Text(image.notes.joined(separator: "; ")).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
            }
        }
        .onChange(of: session.endpointKind) { _, kind in
            switch kind {
            case "google": session.modelName = "gemini-3.8-flash"
            case "anthropic", "gateway/anthropic": session.modelName = "claude-sonnet-4-6"
            case "openai": session.modelName = "gpt-5.2"
            case "vllm":
                session.modelName = session.usingPodCaptioner ? session.gpu.captionModel : "Qwen/Qwen3-VL-8B-Instruct"
            default: session.modelName = "google/gemini-3.8-flash"
            }
        }
    }

    private var profiles: [String] {
        (try? session.selectedSkill().profiles()) ?? [session.project?.job.profile ?? "flux-image"]
    }
}
