import AppKit
import ConceptCore
import Foundation
import UniformTypeIdentifiers

/// Open panels for the view layer. Session methods never present UI: a view runs the panel and
/// hands the chosen URL to the session (`createProject(at:)`, `openProject(url:)`, ...).
@MainActor
enum ProjectAccess {
    static func chooseFolder(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseImages(multiple: Bool = true) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = multiple
        return panel.runModal() == .OK ? panel.urls : []
    }
}

/// Recently opened projects: most recent first, at most `limit`, each with the security-scoped
/// bookmark that reopens it under the sandbox. Stored in the session's injected preferences.
struct RecentProjects {
    static let key = "recentProjects"
    static let limit = 10
    /// Before recency was tracked: an unordered `[path: bookmark]` dictionary.
    static let legacyKey = "projectBookmarks"
    /// Before custom skills were copied into projects: `[path: bookmark]` for skill folders.
    static let legacySkillKey = "skillBookmarks"

    struct Entry: Codable, Equatable {
        var path: String
        var bookmark: Data
    }

    let preferences: UserDefaults

    var entries: [Entry] {
        if let data = preferences.data(forKey: Self.key),
           let entries = try? JSONDecoder().decode([Entry].self, from: data) {
            return entries
        }
        let legacy = preferences.dictionary(forKey: Self.legacyKey) as? [String: Data] ?? [:]
        return legacy.keys.sorted().prefix(Self.limit).compactMap { path in
            legacy[path].map { Entry(path: path, bookmark: $0) }
        }
    }

    var paths: [String] {
        entries.map(\.path)
    }

    /// Put `url` first, dropping its older entry and anything past the limit.
    func remember(_ url: URL) throws {
        let bookmark = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let rest = entries.filter { $0.path != url.path }
        write([Entry(path: url.path, bookmark: bookmark)] + rest)
    }

    func forget(_ path: String) {
        write(entries.filter { $0.path != path })
    }

    /// Resolve a recent project's bookmark. An entry that no longer resolves is removed, and the
    /// error says what to do instead.
    func restore(_ path: String) throws -> URL {
        guard let entry = entries.first(where: { $0.path == path }) else {
            throw StudioError.message("Choose Open project and select this folder again.")
        }
        do {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: entry.bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard FileManager.default.fileExists(atPath: url.appendingPathComponent("job.yaml").path) else {
                throw StudioError.message("missing job")
            }
            if stale || url.path != path {
                // The folder moved or was renamed: keep its place in the list under the new path.
                forget(path)
                try remember(url)
            }
            return url
        } catch {
            forget(path)
            throw StudioError.message(
                "\(URL(fileURLWithPath: path).lastPathComponent) could not be found any more, so it was removed "
                    + "from recent projects. If you moved it, choose Open project and select its new location."
            )
        }
    }

    /// A skill folder chosen before skills were copied into projects, if its bookmark still resolves.
    func legacySkill(_ path: String) -> URL? {
        guard let data = (preferences.dictionary(forKey: Self.legacySkillKey) as? [String: Data])?[path] else {
            return nil
        }
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale)
    }

    private func write(_ entries: [Entry]) {
        if let data = try? JSONEncoder().encode(Array(entries.prefix(Self.limit))) {
            preferences.set(data, forKey: Self.key)
            preferences.removeObject(forKey: Self.legacyKey)
        }
    }
}

/// Recent projects and the project's skill folder.
@MainActor
extension StudioSession {
    func openRecent(_ path: String) {
        do {
            try openProject(url: recents.restore(path))
        } catch {
            recentPaths = recents.paths
            errorMessage = Self.describe(error)
        }
    }

    func rememberRecent(_ url: URL) {
        do { try recents.remember(url) } catch {
            message = "Project opened, but it could not be added to recent projects."
        }
        recentPaths = recents.paths
    }

    /// Use a skill folder the user chose: it is copied into the project and job.yaml refers to the copy.
    func chooseSkill(_ url: URL) {
        guard var project else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let skill = try project.adoptSkill(from: url)
            self.project = project
            message = "Copied the “\(skill.name)” skill into this project. Edit it there; "
                + "the original folder is no longer used."
        } catch { errorMessage = Self.describe(error) }
    }

    /// Back to the bundled skill; job.yaml gets no `skill` key.
    func useBundledSkill() {
        do {
            try project?.useBundledSkill()
            message = "Using the bundled caption instructions."
        } catch { errorMessage = Self.describe(error) }
    }

    /// A project whose job.yaml points at a skill outside the project (an earlier app version, or a
    /// job written by hand) gets that skill copied in when it can still be read.
    func migrateOutsideSkill() {
        guard var project, project.skillIsOutsideProject, let path = project.job.skill,
              let url = recents.legacySkill(path) ?? project.skillURL else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard (try? project.adoptSkill(from: url)) != nil else { return }
        self.project = project
        message += " Its skill folder was copied into the project."
    }

    func selectedSkill() throws -> Skill {
        guard let project, project.job.skill != nil else { return try Skills.load() }
        guard !project.skillIsOutsideProject, let url = project.skillURL else {
            throw StudioError.message(
                "This project's skill folder is outside the project. Choose the skill folder again on Captioning "
                    + "and it will be copied into the project."
            )
        }
        return try Skills.load(url)
    }
}

/// Transitional entry points for views that still call the panel-presenting forms. Each one runs
/// the panel here and forwards to the URL-taking method; views should run the panel themselves.
@MainActor
extension StudioSession {
    @available(*, deprecated, message: "Run ProjectAccess.chooseFolder in the view, then call createProject(at:)")
    func createProject() {
        guard let url = ProjectAccess.chooseFolder(prompt: "Create project here") else { return }
        createProject(at: url)
    }

    @available(*, deprecated, message: "Run ProjectAccess.chooseFolder in the view, then call openProject(url:)")
    func openProject() {
        guard let url = ProjectAccess.chooseFolder(prompt: "Open project") else { return }
        openProject(url: url)
    }

    @available(*, deprecated, message: "Run ProjectAccess.chooseFolder in the view, then call importFolder(_:)")
    func importFolder() {
        guard let url = ProjectAccess.chooseFolder(prompt: "Import photos") else { return }
        importFolder(url)
    }

    @available(*, deprecated, message: "Run ProjectAccess.chooseFolder in the view, then call chooseSkill(_:)")
    func chooseSkill() {
        guard let url = ProjectAccess.chooseFolder(prompt: "Choose skill") else { return }
        chooseSkill(url)
    }

    @available(
        *,
        deprecated,
        message: "Run ProjectAccess.chooseImages in the view, then call chooseReference(trigger:from:)"
    )
    func chooseReference(trigger: String) {
        guard let url = ProjectAccess.chooseImages(multiple: false).first else { return }
        chooseReference(trigger: trigger, from: url)
    }
}
