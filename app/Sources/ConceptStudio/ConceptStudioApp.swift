import SwiftUI

@main
struct ConceptStudioApp: App {
    @State private var session = StudioSession()
    @FocusedValue(\.captionSaveAction) private var captionSaveAction
    @NSApplicationDelegateAdaptor(StudioAppDelegate.self) private var delegate

    var body: some Scene {
        Window("ConceptStudio", id: "studio") {
            StudioRootView(session: session).onAppear {
                delegate.session = session
                session.restoreStartupComputer()
            }
        }
        .defaultSize(width: 1240, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New project…") { session.createProject() }.keyboardShortcut("n")
                Button("Open project…") { session.openProject() }.keyboardShortcut("o")
                Button(captionSaveAction == nil ? "Save project" : "Save caption") {
                    if let captionSaveAction { captionSaveAction.save() } else { session.saveProject() }
                }.keyboardShortcut("s")
                    .disabled(captionSaveAction?.disabled ?? (session.project == nil || session.busy))
                Button("Close project") { session.requestClose() }.disabled(session.project == nil)
            }
        }
        Settings { StudioSettingsView(session: session) }
    }
}
