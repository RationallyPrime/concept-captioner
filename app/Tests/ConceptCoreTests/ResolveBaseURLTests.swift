// base_url safety in resolve: Python models.py `_model`, `_private_host` and `check_base_url`.
// A job file may have been downloaded, so its base_url is untrusted. See docs/CORE-SPEC.md, module
// `modelclient`, "resolve rules".

import ConceptCore
import Foundation
import Testing

@Suite("modelclient resolve base_url")
struct ResolveBaseURLTests {
    static let keys = StaticKeyStore([.google: "g-key", .anthropic: "a-key", .openai: "o-key", .openrouter: "r-key"])

    @Test(arguments: [
        ("https://trusted.example/v1", "https://trusted.example/v1", true),
        ("https://TRUSTED.example/v1", "https://trusted.example/other", true),
        ("https://evil.example/v1", "https://trusted.example/v1", false),
        ("http://localhost:8000/v1", "http://LOCALHOST:8000/other", true),
        ("https://trusted.example:443/v1", "https://trusted.example/v1", true),
        // Another port or scheme on the configured host is another service: no key.
        ("http://localhost:9000/v1", "http://localhost:8000/v1", false),
        ("http://localhost/v1", "http://localhost:8000/v1", false),
        ("http://trusted.example.local/v1", "https://trusted.example.local/v1", false),
        ("https://evil.example/v1", nil, false),
    ] as [(String, String?, Bool)])
    func vllmKeyOnlyReachesConfiguredOrigin(target: String, configured: String?, authenticated: Bool) async throws {
        let reply = try StubTransport.json([
            "model": "m",
            "choices": [["message": ["content": "{}"]]],
        ])
        let transport = StubTransport { _ in reply }
        let result = try Endpoints.resolve(
            EndpointSpec(kind: "vllm", model: "m", baseURL: target),
            keys: StaticKeyStore([.vllm: "stored-vllm-key"], vllmBaseURL: configured),
            transport: transport
        )
        _ = try await result.client.request(
            instructions: "test", messages: [.user("test")],
            output: OutputRequest(name: Caption.schemaName, schema: Caption.jsonSchema, mode: .native),
            settings: result.settings
        )
        let request = try #require(await transport.requests.first)
        #expect(request.url?.host()?.lowercased() == URL(string: target)?.host()?.lowercased())
        #expect(request.value(forHTTPHeaderField: "Authorization") ==
            (authenticated ? "Bearer stored-vllm-key" : nil))
    }

    @Test(arguments: [
        "Authorization", "aUtHoRiZaTiOn", "Proxy-Authorization", "x-api-key", "x-goog-api-key",
        "api_key", "X-Auth-Token", "Cookie", "Host",
    ])
    func jobCannotSupplyAuthenticationHeaders(header: String) throws {
        #expect(throws: ConfigurationError.self) {
            try Endpoints.resolve(
                EndpointSpec(
                    kind: "vllm",
                    model: "m",
                    baseURL: "http://localhost/v1",
                    settings: ["extra_headers": .object(JSONObject([(header, .string("bad"))]))]
                ),
                keys: StaticKeyStore([:])
            )
        }
    }

    @Test(arguments: [
        "http://localhost@evil.example/v1", "https://localhost@evil.example/v1",
        "http://local%68ost/v1", "http://localhost\\@evil.example/v1",
        "http://local\thost/v1", "http://localhost/\npath", "http://localhost:99999/v1",
    ])
    func ambiguousURLsAreRejected(url: String) throws {
        #expect(throws: ConfigurationError.self) {
            try Endpoints.resolve(EndpointSpec(kind: "vllm", model: "m", baseURL: url), keys: StaticKeyStore([:]))
        }
    }

    @Test("a downloaded job file's base_url can never pair with the stored OpenAI key")
    func baseURLCannotRedirectAStoredKey() throws {
        for bad in ["https://evil.example/v1", "http://localhost:8000/v1"] {
            let redirect = #expect(throws: ConfigurationError.self) {
                try Endpoints.resolve(EndpointSpec(kind: "openai", model: "gpt-5.2", baseURL: bad), keys: Self.keys)
            }
            #expect(redirect?.message.contains("takes no base_url") == true)
            #expect(redirect?.message.contains("kind: vllm with base_url") == true)
        }
        let google = #expect(throws: ConfigurationError.self) {
            try Endpoints.resolve(EndpointSpec(kind: "google", model: "x", baseURL: "http://nope"), keys: Self.keys)
        }
        #expect(google?.message == "base_url is only meaningful for kind vllm, not 'google'")
    }

    @Test(
        "custom endpoints: https anywhere, plain http only to loopback/private hosts",
        arguments: [
            "https://pod-1234.proxy.runpod.net/v1",
            "http://localhost:8000/v1",
            "http://pod:8000/v1",
            "http://10.0.0.5:8000/v1",
            "http://192.168.1.20:8000/v1",
            "http://172.31.255.1/v1",
            "http://127.0.0.1:8000/v1",
            "http://169.254.10.10/v1",
            "http://[::1]:8000/v1",
            "http://[fd00::5]:8000/v1",
            "http://localhost.localdomain:8000/v1",
            "http://gpu-box.local:8000/v1",
            "http://vllm.corp.internal/v1",
        ]
    )
    func acceptsSafeBaseURLs(url: String) throws {
        let resolved = try Endpoints.resolve(
            EndpointSpec(kind: "vllm", model: "m", baseURL: url),
            keys: StaticKeyStore([:])
        )
        #expect((resolved.client as? OpenAICompatibleClient)?.baseURL.absoluteString == url)
    }

    @Test(
        "plain http to a public host is refused: images and the key would travel in clear text",
        arguments: [
            "http://evil.example.com/v1",
            "http://8.8.8.8:8000/v1",
            "http://proxy.runpod.net/v1",
            "http://[2606:4700::1111]/v1",
            "http://[::ffff:8.8.8.8]/v1",
            "ftp://localhost/v1",
        ]
    )
    func rejectsClearTextToPublicHosts(url: String) throws {
        let error = #expect(throws: ConfigurationError.self) {
            try Endpoints.resolve(EndpointSpec(kind: "vllm", model: "m", baseURL: url), keys: StaticKeyStore([:]))
        }
        #expect(error?.message.contains("must be https") == true)
        #expect(error?.message.contains("clear text to a public host") == true)
    }

    @Test func rejectsBaseURLWithoutHost() throws {
        let error = #expect(throws: ConfigurationError.self) {
            try Endpoints.resolve(
                EndpointSpec(kind: "vllm", model: "m", baseURL: "not a url"),
                keys: StaticKeyStore([:])
            )
        }
        #expect(error?.message.contains("has no host") == true)
    }
}
