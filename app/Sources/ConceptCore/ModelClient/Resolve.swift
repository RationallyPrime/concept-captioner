// Spec string or EndpointSpec -> a ModelClient plus settings. Python counterpart: models.py.
// Keys come from an injected KeyStore, never from the environment inside the library.
//
// A job file is data that may have been downloaded (`hf fetch-job`), so a `base_url` in it is
// untrusted. Two rules keep a stored key from being sent to a host the file chose:
//
// - `kind: openai` always talks to api.openai.com; a `base_url` on it is an error. Any other
//   OpenAI-compatible server is `kind: vllm`, whose key the user set for custom endpoints and
//   nothing else.
// - A custom `base_url` must be https, or http to a loopback / private-network host.
// - The vLLM key goes only to the origin (scheme, host, port) configured by the user, never to
//   an arbitrary job host or another port on the configured one.

import Foundation

public enum Provider: String, Sendable, CaseIterable {
    case google, anthropic, openai, openrouter, vercel, gateway, vllm
}

public protocol KeyStore: Sendable {
    /// nil when no key is stored. `.vllm` may run without one; everyone else needs one.
    func apiKey(for provider: Provider) throws -> String?
    /// The endpoint the user configured in Settings, never a value taken from a job file.
    var vllmBaseURL: String? { get }
}

public struct StaticKeyStore: KeyStore {
    public let keys: [Provider: String]
    public let vllmBaseURL: String?

    public init(_ keys: [Provider: String], vllmBaseURL: String? = nil) {
        self.keys = keys
        self.vllmBaseURL = vllmBaseURL
    }

    public func apiKey(for provider: Provider) throws -> String? {
        keys[provider]
    }
}

public struct ResolvedEndpoint: Sendable {
    public let client: any ModelClient
    public let settings: RequestSettings
    public let outputMode: OutputMode
    /// The model name as requested, for the response record.
    public let requested: String
    public let concurrency: Int

    public init(
        client: any ModelClient,
        settings: RequestSettings = RequestSettings(),
        outputMode: OutputMode = .native,
        requested: String? = nil,
        concurrency: Int = 4
    ) {
        self.client = client
        self.settings = settings
        self.outputMode = outputMode
        self.requested = requested ?? client.requestedModel
        self.concurrency = concurrency
    }
}

public extension Endpoints {
    /// The fixed Pydantic AI Gateway proxy origin encoded by a supported gateway key.
    static func gatewayProxyBaseURL(for apiKey: String) throws -> URL {
        guard apiKey.range(of: #"^pylf_v[0-9]+_(us|eu)_[a-zA-Z0-9_-]+\z"#, options: .regularExpression) != nil else {
            throw ConfigurationError("Pydantic AI Gateway key must encode the supported us or eu region")
        }
        let region = apiKey.split(separator: "_")[2]
        return URL(string: "https://gateway-\(region).pydantic.dev/proxy")!
    }

    /// "provider:model" -> EndpointSpec (both sides trimmed, like `str.partition` + `strip`).
    static func parseSpec(_ spec: String) throws -> EndpointSpec {
        guard let colon = spec.firstIndex(of: ":") else {
            throw malformedSpec(spec)
        }
        let kind = spec[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
        let model = spec[spec.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kind.isEmpty, !model.isEmpty else {
            throw malformedSpec(spec)
        }
        return try EndpointSpec(kind: kind, model: model)
    }

    private static func malformedSpec(_ spec: String) -> ConfigurationError {
        ConfigurationError("endpoint spec must look like provider:model, got '\(spec)'")
    }

    static func resolve(
        _ spec: String,
        thinking: ThinkingLevel = .none,
        keys: any KeyStore,
        transport: any HTTPTransport = URLSessionTransport()
    ) throws -> ResolvedEndpoint {
        try resolve(parseSpec(spec), thinking: thinking, keys: keys, transport: transport)
    }

    /// Direct providers and the three gateways. Configuration mistakes are `ConfigurationError`; a provider that
    /// needs a key the store does not have is `ModelError.missingKey`.
    static func resolve(
        _ spec: EndpointSpec,
        thinking: ThinkingLevel = .none,
        keys: any KeyStore,
        transport: any HTTPTransport = URLSessionTransport()
    ) throws -> ResolvedEndpoint {
        let provider = try provider(for: spec)
        let settings = try RequestSettings(settings: spec.settings, thinking: thinking)
        var apiKey = try keys.apiKey(for: provider)
        if provider == .vllm {
            guard let target = try baseURL(spec) else {
                throw ConfigurationError("kind vllm needs base_url")
            }
            let credentialMatches = try vllmCredentialMatchesTarget(
                targetURL: target.absoluteString,
                configuredBaseURL: keys.vllmBaseURL
            )
            if !credentialMatches {
                apiKey = nil
            }
        }
        if apiKey == nil, provider != .vllm {
            throw ModelError.missingKey(provider)
        }
        let client = try makeClient(provider: provider, spec: spec, apiKey: apiKey, transport: transport)
        return ResolvedEndpoint(
            client: client,
            settings: settings,
            outputMode: spec.outputMode,
            requested: spec.model,
            concurrency: spec.concurrency
        )
    }

    private static func makeClient(
        provider: Provider,
        spec: EndpointSpec,
        apiKey: String?,
        transport: any HTTPTransport
    ) throws -> any ModelClient {
        switch provider {
        case .openai:
            let base = OpenAIResponsesClient.openAIBaseURL
            return OpenAIResponsesClient(baseURL: base, apiKey: apiKey ?? "", model: spec.model, transport: transport)
        case .openrouter:
            return OpenAICompatibleClient(
                baseURL: OpenAICompatibleClient.openRouterBaseURL, apiKey: apiKey, model: spec.model,
                transport: transport, reasoningDialect: .openRouter, acceptsVideo: true
            )
        case .vercel:
            return OpenAICompatibleClient(
                baseURL: OpenAICompatibleClient.vercelBaseURL, apiKey: apiKey, model: spec.model, transport: transport
            )
        case .gateway:
            return try gatewayClient(spec: spec, apiKey: apiKey ?? "", transport: transport)
        case .vllm:
            guard let base = try baseURL(spec) else {
                throw ConfigurationError("kind vllm needs base_url")
            }
            return OpenAICompatibleClient(
                baseURL: base, apiKey: apiKey, model: spec.model, transport: transport, acceptsVideo: true
            )
        case .anthropic:
            return AnthropicClient(apiKey: apiKey ?? "", model: spec.model, transport: transport)
        case .google:
            return GeminiClient(apiKey: apiKey ?? "", model: spec.model, transport: transport)
        }
    }

    private static func provider(for spec: EndpointSpec) throws -> Provider {
        if spec.kind == "gemini" {
            throw ConfigurationError("unknown endpoint kind 'gemini' (Gemini is kind: google)")
        }
        let provider: Provider
        if spec.kind.hasPrefix("gateway/") {
            guard gatewayUpstreams.contains(String(spec.kind.dropFirst("gateway/".count))) else {
                throw ConfigurationError(
                    "unsupported Pydantic AI Gateway provider '\(spec.kind)'; expected gateway/"
                        + gatewayUpstreams.joined(separator: ", gateway/")
                )
            }
            provider = .gateway
        } else if let direct = Provider(rawValue: spec.kind), direct != .gateway {
            provider = direct
        } else {
            let known = (Provider.allCases.filter { $0 != .gateway }.map(\.rawValue)
                + gatewayUpstreams.map { "gateway/\($0)" }).joined(separator: ", ")
            throw ConfigurationError("unknown endpoint kind '\(spec.kind)'; expected one of \(known)")
        }
        if spec.baseURL != nil, provider == .openai {
            throw ConfigurationError(
                "kind: openai always talks to api.openai.com and takes no base_url; for another "
                    + "OpenAI-compatible server use kind: vllm with base_url (its key is VLLM_API_KEY)"
            )
        }
        if spec.baseURL != nil, provider != .vllm {
            throw ConfigurationError("base_url is only meaningful for kind vllm, not '\(spec.kind)'")
        }
        return provider
    }

    private static var gatewayUpstreams: [String] {
        // `chat` and `responses` are pydantic-ai's aliases of `openai-chat` and `openai-responses`.
        ["google", "google-cloud", "anthropic", "openai", "openai-responses", "openai-chat", "chat", "responses"]
    }

    private static func gatewayClient(
        spec: EndpointSpec,
        apiKey: String,
        transport: any HTTPTransport
    ) throws -> any ModelClient {
        // The key selects only one of the documented production US/EU proxy hosts.
        let base = try gatewayProxyBaseURL(for: apiKey)
        switch String(spec.kind.dropFirst("gateway/".count)) {
        case "google", "google-cloud":
            return GeminiClient(
                apiKey: apiKey, model: spec.model,
                baseURL: base.appendingPathComponent("google-vertex/v1beta1/publishers/google"),
                transport: transport, bearerAuth: true, api: .vertex
            )
        case "anthropic":
            return AnthropicClient(
                apiKey: apiKey, model: spec.model, baseURL: base.appendingPathComponent("anthropic"),
                transport: transport, bearerAuth: true
            )
        case "openai-chat", "chat":
            return OpenAICompatibleClient(
                baseURL: base.appendingPathComponent("openai"), apiKey: apiKey, model: spec.model, transport: transport
            )
        default:
            return OpenAIResponsesClient(
                baseURL: base.appendingPathComponent("openai"), apiKey: apiKey, model: spec.model, transport: transport
            )
        }
    }

    /// The spec's base_url as a checked URL, nil when absent.
    private static func baseURL(_ spec: EndpointSpec) throws -> URL? {
        guard let text = spec.baseURL else { return nil }
        return try checkBaseURL(text)
    }

    /// Whether the configured vLLM credential is allowed for the requested target origin.
    static func vllmCredentialMatchesTarget(targetURL: String, configuredBaseURL: String?) throws -> Bool {
        let target = try checkBaseURL(targetURL)
        let configured = try configuredBaseURL.map(checkBaseURL)
        return configured.map(Origin.init) == Origin(target)
    }

    /// Accept https anywhere, or plain http only to a loopback / private host (Python `check_base_url`).
    /// Images and the endpoint key must never travel in clear text to a public host.
    static func checkBaseURL(_ text: String) throws -> URL {
        guard let url = URL(string: text), let host = url.host(percentEncoded: false), !host.isEmpty else {
            throw ConfigurationError("base_url '\(text)' has no host")
        }
        guard !text.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0)
                || CharacterSet.controlCharacters.contains($0) || $0 == "\\"
        }) else {
            throw ConfigurationError("base_url must not contain whitespace, controls or backslashes")
        }
        guard url.user == nil, url.password == nil, !((url.host() ?? "").contains("%")),
              url.port.map({ (0 ... 65535).contains($0) }) ?? true
        else {
            throw ConfigurationError("base_url must not contain userinfo, an escaped host or an invalid port")
        }
        let scheme = url.scheme?.lowercased()
        if scheme == "https" {
            return url
        }
        if scheme == "http", isPrivateHost(host) {
            return url
        }
        throw ConfigurationError(
            "base_url '\(text)' must be https, or http to a loopback/private address; images and the "
                + "endpoint key would otherwise travel in clear text to a public host"
        )
    }

    /// Python `_private_host`: a single-label name, localhost.localdomain, a .local/.internal name,
    /// or an IP literal that is loopback, private or link-local.
    static func isPrivateHost(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased()
        var bare = Substring(host)
        if bare.hasPrefix("["), bare.hasSuffix("]") {
            bare = bare.dropFirst().dropLast()
        }
        // single-label names (docker service names, LAN hosts) never resolve through public DNS
        if !bare.contains("."), !bare.contains(":") {
            return true
        }
        if host == "localhost.localdomain" || host.hasSuffix(".local") || host.hasSuffix(".internal") {
            return true
        }
        guard let address = IPAddress(String(bare)) else {
            return false
        }
        return address.isLoopback || address.isPrivate || address.isLinkLocal
    }
}

/// Scheme, lowercased host and port with the scheme's default filled in: what the vLLM key is
/// bound to.
struct Origin: Equatable {
    let scheme: String?
    let host: String?
    let port: Int?

    init(_ url: URL) {
        scheme = url.scheme?.lowercased()
        host = url.host(percentEncoded: false)?.lowercased()
        port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : nil)
    }
}

/// A parsed IPv4 or IPv6 literal with the classification Python's `ipaddress` module gives it.
enum IPAddress {
    case v4(UInt32)
    case v6([UInt8])

    init?(_ text: String) {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            self = .v4(UInt32(bigEndian: v4.s_addr))
            return
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 {
            self = .v6(withUnsafeBytes(of: v6) { Array($0) })
            return
        }
        return nil
    }

    /// An IPv4-mapped IPv6 address (`::ffff:a.b.c.d`) classifies as its embedded IPv4 address.
    private var mappedV4: IPAddress? {
        guard case let .v6(bytes) = self, bytes[0 ..< 10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF,
              bytes[11] == 0xFF
        else {
            return nil
        }
        let value = bytes[12...].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return .v4(value)
    }

    var isLoopback: Bool {
        switch self {
        case let .v4(value):
            return inV4(value, "127.0.0.0", 8)
        case let .v6(bytes):
            if let mappedV4 { return mappedV4.isLoopback }
            return bytes[0 ..< 15].allSatisfy { $0 == 0 } && bytes[15] == 1
        }
    }

    var isLinkLocal: Bool {
        switch self {
        case let .v4(value):
            return inV4(value, "169.254.0.0", 16)
        case let .v6(bytes):
            if let mappedV4 { return mappedV4.isLinkLocal }
            return bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80
        }
    }

    /// Not globally reachable per the IANA special-purpose registries, as Python's `is_private`.
    var isPrivate: Bool {
        switch self {
        case let .v4(value):
            let blocks: [(String, Int)] = [
                ("0.0.0.0", 8), ("10.0.0.0", 8), ("127.0.0.0", 8), ("169.254.0.0", 16), ("172.16.0.0", 12),
                ("192.0.0.0", 24), ("192.0.2.0", 24), ("192.168.0.0", 16), ("198.18.0.0", 15),
                ("198.51.100.0", 24), ("203.0.113.0", 24), ("240.0.0.0", 4), ("255.255.255.255", 32),
            ]
            return blocks.contains { inV4(value, $0.0, $0.1) }
        case let .v6(bytes):
            if let mappedV4 { return mappedV4.isPrivate }
            if bytes.allSatisfy({ $0 == 0 }) || isLoopback || isLinkLocal { return true }
            if bytes[0] & 0xFE == 0xFC { return true } // fc00::/7 unique local
            if bytes[0] == 0x01, bytes[1 ..< 8].allSatisfy({ $0 == 0 }) { return true } // 100::/64 discard
            if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0D, bytes[3] == 0xB8 { return true } // 2001:db8::/32
            return false
        }
    }

    private func inV4(_ value: UInt32, _ network: String, _ prefix: Int) -> Bool {
        guard case let .v4(base)? = IPAddress(network) else { return false }
        let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << UInt32(32 - prefix)
        return value & mask == base & mask
    }
}
