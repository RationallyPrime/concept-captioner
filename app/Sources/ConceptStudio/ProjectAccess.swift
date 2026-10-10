import AppKit
import Foundation
import UniformTypeIdentifiers

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

    static func remember(_ url: URL, collection: String = "projectBookmarks") throws {
        let bookmark = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        var bookmarks = UserDefaults.standard.dictionary(forKey: collection) as? [String: Data] ?? [:]
        bookmarks[url.path] = bookmark
        UserDefaults.standard.set(bookmarks, forKey: collection)
    }

    static var recentPaths: [String] {
        (UserDefaults.standard.dictionary(forKey: "projectBookmarks") ?? [:]).keys.sorted()
    }

    static func restore(_ path: String, collection: String = "projectBookmarks") throws -> URL {
        guard let data = UserDefaults.standard.dictionary(forKey: collection)?[path] as? Data else {
            throw StudioError.message("Choose Open project and select this folder again.")
        }
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        if stale { try remember(url, collection: collection) }
        return url
    }
}
