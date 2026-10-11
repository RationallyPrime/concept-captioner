import ConceptCore
import Foundation

protocol FileUploading: Sendable {
    func upload(_ request: URLRequest, from file: URL) async throws -> HTTPResponse
}

struct URLSessionUploader: FileUploading {
    func upload(_ request: URLRequest, from file: URL) async throws -> HTTPResponse {
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: file, delegate: NoRedirects())
        return HTTPResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _: URLSession, task _: URLSessionTask,
            willPerformHTTPRedirection _: HTTPURLResponse, newRequest _: URLRequest
        ) async -> URLRequest? {
            nil
        }
    }
}

extension PodAgentClient {
    func upload(name: String, fileName: String, from file: URL, size: Int64) async throws {
        guard RunArtifacts.validRunID(name), !fileName.isEmpty, fileName != ".", fileName != "..",
              !fileName.contains("/"), !fileName.contains("\\"), !fileName.hasPrefix("."),
              !fileName.unicodeScalars.contains(where: { $0.value < 32 }),
              size > 0, size <= LocalTrainingDataset.maximumFileBytes else {
            throw StudioError.message("Invalid training upload name or file size.")
        }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, Int64(values.fileSize ?? -1) == size else {
            throw StudioError.message("The prepared training file changed before uploading.")
        }
        var request = URLRequest(
            url: baseURL.appendingPathComponent("uploads").appendingPathComponent(name)
                .appendingPathComponent(fileName),
            timeoutInterval: 600
        )
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(size), forHTTPHeaderField: "Content-Length")
        let response = try await uploader.upload(request, from: file)
        guard (200 ..< 300).contains(response.status),
              let receipt = try JSONValue(parsing: response.body).objectValue,
              receipt["name"]?.stringValue == name, receipt["file_name"]?.stringValue == fileName,
              receipt["size"]?.intValue == Int(size) else {
            throw StudioError.message("The computer did not confirm the complete training upload (\(response.status)).")
        }
    }
}
