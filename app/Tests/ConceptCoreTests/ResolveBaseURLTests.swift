// base_url safety in resolve: Python models.py `_model`, `_private_host` and `check_base_url`.
// A job file may have been downloaded, so its base_url is untrusted. See docs/CORE-SPEC.md, module
// `modelclient`, "resolve rules".

import ConceptCore
import Foundation
import Testing

@Suite("modelclient resolve base_url")
struct ResolveBaseURLTests {
    static let keys = StaticKeyStore([.google: "g-key", .anthropic: "a-key", .openai: "o-key", .openrouter: "r-key"])

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
