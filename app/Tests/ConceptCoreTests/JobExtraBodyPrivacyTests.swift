// A job file may have been downloaded. Its extra_body is merged over the request body last, so
// it must not be able to switch provider-side retention back on. Python: models.py `_settings`.

import ConceptCore
import Foundation
import Testing

@Suite("modelclient extra_body privacy keys")
struct JobExtraBodyPrivacyTests {
    @Test(arguments: ["store", "Store", "metadata", "user", "safety_identifier"])
    func jobCannotControlProviderRetention(key: String) throws {
        #expect(throws: ConfigurationError.self) {
            try Endpoints.resolve(
                EndpointSpec(
                    kind: "vllm",
                    model: "m",
                    baseURL: "http://localhost/v1",
                    settings: ["extra_body": .object(JSONObject([(key, .bool(true))]))]
                ),
                keys: StaticKeyStore([:])
            )
        }
    }

    @Test func harmlessExtraBodyKeysStillPass() throws {
        let resolved = try Endpoints.resolve(
            EndpointSpec(
                kind: "vllm",
                model: "m",
                baseURL: "http://localhost/v1",
                settings: ["extra_body": .object(["top_k": .int(5)])]
            ),
            keys: StaticKeyStore([:])
        )
        #expect(resolved.settings.extraBody["top_k"] == .int(5))
    }
}
