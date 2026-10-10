// Sidecar <stem>.txt captions and <stem>.json response records out.
// Python counterpart: sources/local.py::SidecarSink, atomic_write_text/json.

import Foundation

public enum AtomicFile {
    /// Write to a temp file in the same directory, then rename over the target (creates parents).
    ///
    /// The temp file is `.<name>.<uuid>.tmp` beside the target, created exclusively, and removed
    /// again if anything fails before the rename. The target is created with mode 0644 (less the
    /// umask); Python's `mkstemp` leaves its sidecars at 0600, which is an accident of the tool,
    /// not part of the contract.
    public static func write(_ data: Data, to url: URL) throws {
        let target = url.standardizedFileURL
        let directory = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw posixError("could not create \(temp.path)") }
        defer {
            if FileManager.default.fileExists(atPath: temp.path) {
                try? FileManager.default.removeItem(at: temp)
            }
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
        guard rename(temp.path, target.path) == 0 else {
            throw posixError("could not move \(temp.path) over \(target.path)")
        }
    }

    public static func write(text: String, to url: URL) throws {
        try write(Data(text.utf8), to: url)
    }

    private static func posixError(_ what: String) -> NSError {
        let code = errno
        let reason = String(cString: strerror(code))
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(what): \(reason)"]
        )
    }
}

public struct SidecarSink: CaptionSink {
    public let name = "sidecar"
    public let directory: URL

    /// Creates the directory (and its parents) when missing.
    public init(directory: URL) throws {
        let directory = directory.standardizedFileURL
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ConfigurationError("output directory could not be created: \(directory.path) (\(error))")
        }
        self.directory = directory
    }

    public func captionURL(for sampleID: String) -> URL {
        sidecarURL(for: sampleID, extension: "txt")
    }

    public func recordURL(for sampleID: String) -> URL {
        sidecarURL(for: sampleID, extension: "json")
    }

    /// `<directory>/<stem>.<extension>`; the stem is taken from the id's last path component,
    /// as `Path(sample_id).stem` does.
    private func sidecarURL(for sampleID: String, extension: String) -> URL {
        let lastComponent = sampleID.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init)
        let stem = Sources.stem(of: lastComponent ?? sampleID)
        return directory.appendingPathComponent("\(stem).\(`extension`)")
    }

    public func exists(_ sampleID: String) async throws -> Bool {
        isFile(captionURL(for: sampleID))
    }

    /// nil when there is no record file, or when its contents are not valid JSON or not a JSON
    /// object (the sample is then treated as never captioned, as Python does for undecodable
    /// JSON). Any object loads, however sparse or hand-edited; a missing `sample_id` is taken
    /// from the id asked for, so a human-final record is never mistaken for no record.
    public func record(_ sampleID: String) async throws -> ResponseRecord? {
        let url = recordURL(for: sampleID)
        guard isFile(url), let data = try? Data(contentsOf: url) else { return nil }
        guard let json = try? JSONValue(parsing: data) else { return nil }
        return try? ResponseRecord(json: json, sampleID: sampleID)
    }

    /// The record first, as `json.dumps(record, ensure_ascii=False, indent=1)`, then the caption
    /// when there is one; each write is atomic.
    public func write(_ sampleID: String, caption: String?, record: ResponseRecord) async throws {
        try AtomicFile.write(record.jsonValue.pythonDumpsData(indent: 1), to: recordURL(for: sampleID))
        if let caption {
            try AtomicFile.write(text: caption, to: captionURL(for: sampleID))
        }
    }

    public func finalize() async throws -> JSONObject {
        ["directory": .string(directory.path)]
    }

    private func isFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }
}
