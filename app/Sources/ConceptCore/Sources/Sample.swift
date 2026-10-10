// Where samples come from and where captions go. Python counterparts: types.Sample, sources/base.py.

import Foundation

/// One training target as the pipeline sees it: an id, bytes, and a suffix for encoding.
public struct Sample: Sendable, Equatable {
    public let sampleID: String
    public let data: Data
    public let suffix: String

    public init(sampleID: String, data: Data, suffix: String) {
        self.sampleID = sampleID
        self.data = data
        self.suffix = suffix
    }
}

public enum Sources {
    public static let imageSuffixes: Set<String> = [".png", ".jpg", ".jpeg", ".webp"]

    /// The last extension of a file name with its dot, as Python's `Path.suffix`: `"a.b.png"` is
    /// `".png"`, while `".hidden"`, `"trailing."` and `"none"` have no suffix (`""`). Case is kept.
    public static func suffix(of name: String) -> String {
        let scalars = Array(name.unicodeScalars)
        guard let dot = scalars.lastIndex(of: "."), dot > 0, dot < scalars.count - 1 else { return "" }
        return String(String.UnicodeScalarView(scalars[dot...]))
    }

    /// The file name without its last extension, as Python's `Path.stem`.
    public static func stem(of name: String) -> String {
        let suffix = suffix(of: name)
        guard !suffix.isEmpty else { return name }
        return String(name.unicodeScalars.dropLast(suffix.unicodeScalars.count))
    }
}

public protocol ImageSource: Sendable {
    var name: String { get }
    func samples() -> AsyncThrowingStream<Sample, any Error>
    /// `samples()` with a hint: the caller wants only these ids (nil: every sample). A source
    /// that can skip the others without reading or downloading them implements this and yields
    /// only wanted samples; the default is `samples()` unchanged, so a caller filters the result
    /// by id itself whichever way the source answered (the runner does).
    func samples(only ids: Set<String>?) -> AsyncThrowingStream<Sample, any Error>
    func count() async throws -> Int
    func sampleIDs() async throws -> [String]
}

public extension ImageSource {
    func samples(only ids: Set<String>?) -> AsyncThrowingStream<Sample, any Error> {
        samples()
    }
}

public protocol CaptionSink: Sendable {
    var name: String { get }
    /// True if this sample already has a caption.
    func exists(_ sampleID: String) async throws -> Bool
    /// The stored response record for this sample, if any.
    func record(_ sampleID: String) async throws -> ResponseRecord?
    /// Store the caption (when there is one) and the record.
    func write(_ sampleID: String, caption: String?, record: ResponseRecord) async throws
    /// Flush anything buffered (e.g. push a dataset) and return a summary.
    func finalize() async throws -> JSONObject
}
