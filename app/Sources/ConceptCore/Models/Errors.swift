// Errors shared across ConceptCore. Python counterpart: types.ConfigurationError plus the
// provider/transport failures pydantic-ai raised.

import Foundation

/// Anything the user got wrong: a bad job file, skill, profile, or endpoint spec.
public struct ConfigurationError: Error, Equatable, LocalizedError, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}

/// A provider or transport failure while talking to a model.
public enum ModelError: Error, LocalizedError, Sendable {
    case http(status: Int, body: String)
    case transport(String)
    case malformedReply(String)
    case missingKey(Provider)

    public var errorDescription: String? {
        switch self {
        case let .http(status, body): "HTTP \(status): \(body)"
        case let .transport(message): "transport: \(message)"
        case let .malformedReply(message): "malformed reply: \(message)"
        case let .missingKey(provider): "no API key for \(provider.rawValue)"
        }
    }
}

/// A Hugging Face Hub HTTP failure or an unsupported dataset layout.
public enum HubError: Error, LocalizedError, Sendable {
    case http(status: Int, body: String)
    case transport(String)
    case malformed(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case let .http(status, body): "HTTP \(status): \(body)"
        case let .transport(message): "transport: \(message)"
        case let .malformed(message): "malformed: \(message)"
        case let .unsupported(message): "unsupported: \(message)"
        }
    }
}
