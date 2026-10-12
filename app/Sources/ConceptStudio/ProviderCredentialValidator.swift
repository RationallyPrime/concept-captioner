import ConceptCore
import Foundation

enum ProviderCredentialValidator {
    static func checkHuggingFace(
        token: String,
        transport: any HTTPTransport = URLSessionTransport()
    ) async throws {
        var request = URLRequest(url: HubClient.defaultEndpoint.appendingPathComponent("api/whoami-v2"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        try await check(request, provider: "Hugging Face", transport: transport)
    }

    static func checkRunPod(
        key: String,
        transport: any HTTPTransport = URLSessionTransport()
    ) async throws {
        var components = URLComponents(string: "https://api.runpod.io/v2/pods")!
        components.queryItems = [URLQueryItem(name: "limit", value: "1")]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        try await check(request, provider: "RunPod", transport: transport)
    }

    private static func check(
        _ request: URLRequest,
        provider: String,
        transport: any HTTPTransport
    ) async throws {
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProviderModelCatalogError.unreachable(provider)
        }
        try Task.checkCancellation()
        guard (200 ..< 300).contains(response.status) else {
            if response.status == 401 || response.status == 403 {
                throw ProviderModelCatalogError.invalidKey(provider)
            }
            throw ProviderModelCatalogError.requestFailed(provider, response.status)
        }
    }
}
