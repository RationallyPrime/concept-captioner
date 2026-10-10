// Progress reporting for Hub commits, and the source of an added file's bytes: in memory, or a
// file on disk that is sampled, hashed and uploaded by reading through it when its turn comes.

import CryptoKit
import Foundation

/// One step of a commit as it happens, for a progress UI. `completed` of `total` files in
/// `phase` are already done and `path` (of `bytes` bytes) is the one being handled now; the
/// `.committing` report carries no path. `.downloading` is only reported by HubFolderSink,
/// `.hashing` and `.uploading` only for files the Hub stores as LFS objects.
public struct HubProgress: Sendable, Equatable {
    public enum Phase: String, Sendable {
        case preparing
        case downloading
        case hashing
        case uploading
        case committing
    }

    public let phase: Phase
    public let path: String?
    public let completed: Int
    public let total: Int
    public let bytes: Int

    public init(phase: Phase, path: String? = nil, completed: Int = 0, total: Int = 0, bytes: Int = 0) {
        self.phase = phase
        self.path = path
        self.completed = completed
        self.total = total
        self.bytes = bytes
    }
}

/// Called synchronously from the commit's own task, so a handler hops to the main actor itself.
public typealias HubProgressHandler = @Sendable (HubProgress) -> Void

/// Where an added file's bytes come from. `size` is known up front; the sample, the hash and the
/// full bytes are produced on request, reading a file from disk each time, so a commit of many
/// files never holds more than the one being handled.
struct CommitSource {
    enum Storage {
        case memory(Data)
        case file(URL)
    }

    /// Read size while hashing a file on disk.
    static let hashChunkBytes = 1 << 20

    let path: String
    let storage: Storage
    let size: Int

    /// nil for a delete; `HubError.transport` for a file that cannot be read.
    init?(_ operation: CommitOperation) throws {
        switch operation {
        case let .add(path, data):
            self.path = path
            storage = .memory(data)
            size = data.count
        case let .addFile(path, url):
            self.path = path
            storage = .file(url)
            size = try CommitSource.fileSize(url)
        case .delete:
            return nil
        }
    }

    /// The leading bytes the preupload call samples.
    func sample() throws -> Data {
        switch storage {
        case let .memory(data): data.prefix(HubClient.preuploadSampleBytes)
        case let .file(url): try CommitSource
            .read(url) { try $0.read(upToCount: HubClient.preuploadSampleBytes) ?? Data() }
        }
    }

    func sha256Hex() throws -> String {
        switch storage {
        case let .memory(data): HubClient.sha256Hex(data)
        case let .file(url): try CommitSource.sha256Hex(fileAt: url)
        }
    }

    /// Every byte, read fresh from disk for a file.
    func bytes() throws -> Data {
        switch storage {
        case let .memory(data): data
        case let .file(url): try CommitSource.read(url) { try $0.readToEnd() ?? Data() }
        }
    }

    // MARK: - Files on disk

    /// The sha256 of a file, read in `hashChunkBytes` pieces.
    static func sha256Hex(fileAt url: URL) throws -> String {
        try read(url) { handle in
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: hashChunkBytes), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Size in bytes of a file on disk; a missing or unreadable file is `HubError.transport`.
    static func fileSize(_ url: URL) throws -> Int {
        do {
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                throw HubError.transport("'\(url.path)' is not a regular file")
            }
            return size
        } catch let error as HubError {
            throw error
        } catch {
            throw HubError.transport("could not read '\(url.path)': \(HubClient.describe(error))")
        }
    }

    /// Opens the file for reading, hands the handle to `body` and closes it; errors become `HubError.transport`.
    static func read<T>(_ url: URL, _ body: (FileHandle) throws -> T) throws -> T {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return try body(handle)
        } catch let error as HubError {
            throw error
        } catch {
            throw HubError.transport("could not read '\(url.path)': \(HubClient.describe(error))")
        }
    }
}
