// Local folder in. Python counterpart: sources/local.py::LocalFolderSource.

import Foundation

public struct LocalFolderSource: ImageSource {
    public let name = "folder"
    public let directory: URL
    /// Image files only, sorted by file name (byte order).
    public let files: [URL]

    /// Lists the folder once. Hidden entries are considered like any other (Python's `iterdir`
    /// does not skip them); only regular files whose suffix is in `Sources.imageSuffixes`
    /// (case-insensitively) are kept. Symlinks to files count as files, like `Path.is_file()`.
    public init(directory: URL) throws {
        let directory = directory.standardizedFileURL
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ConfigurationError("input directory does not exist: \(directory.path)")
        }
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch {
            throw ConfigurationError("input directory could not be listed: \(directory.path) (\(error))")
        }
        let files = entries.filter { entry in
            guard Sources.imageSuffixes.contains(Sources.suffix(of: entry.lastPathComponent).lowercased()) else {
                return false
            }
            var entryIsDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: entry.path, isDirectory: &entryIsDirectory)
                && !entryIsDirectory.boolValue
        }.sorted { $0.lastPathComponent.utf8.lexicographicallyPrecedes($1.lastPathComponent.utf8) }
        let stems = Set(files.map { Sources.stem(of: $0.lastPathComponent) })
        guard stems.count == files.count else {
            throw ConfigurationError("image stems collide; sidecar captions would be ambiguous")
        }
        self.directory = directory
        self.files = files
    }

    public func sampleIDs() async throws -> [String] {
        files.map(\.lastPathComponent)
    }

    public func count() async throws -> Int {
        files.count
    }

    /// Reads each file when the consumer asks for it (a pull stream, like the Python async
    /// generator), so a folder is never loaded into memory at once. A file that cannot be read
    /// ends the stream with that error.
    public func samples() -> AsyncThrowingStream<Sample, any Error> {
        samples(only: nil)
    }

    /// `samples()` over the listed files whose name is in `ids`; the others are never read.
    public func samples(only ids: Set<String>?) -> AsyncThrowingStream<Sample, any Error> {
        let wanted = ids.map { ids in files.filter { ids.contains($0.lastPathComponent) } } ?? files
        let cursor = Cursor(wanted)
        return AsyncThrowingStream(unfolding: { try await cursor.next() })
    }

    /// Walks the file list; an actor so the pull closure stays `Sendable` without a lock.
    private actor Cursor {
        private var remaining: ArraySlice<URL>

        init(_ files: [URL]) {
            remaining = files[...]
        }

        func next() throws -> Sample? {
            guard let file = remaining.popFirst() else { return nil }
            let data = try Data(contentsOf: file)
            let name = file.lastPathComponent
            return Sample(sampleID: name, data: data, suffix: Sources.suffix(of: name))
        }
    }
}
