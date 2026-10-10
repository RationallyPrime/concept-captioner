// StructuredStage retries and the retry user turn (pydantic-ai RetryPromptPart.model_response).
// See docs/CORE-SPEC.md, module `modelclient`.

import ConceptCore
import CoreGraphics
import Foundation
import Testing

private enum Support {
    static let png = Fixtures.syntheticPNG(seed: 1, size: CGSize(width: 24, height: 24))
    static let turn: [ChatMessage] = [.user([.text("Inspect this image."), .image(data: png, mediaType: "image/png")])]
}

@Suite("modelclient stage")
struct StructuredStageTests {
    static let problem = "the mapped trigger NORA7 must appear exactly in the caption"

    func stage(_ fake: FakeModelClient, mode: OutputMode = .native) -> StructuredStage<Caption> {
        StructuredStage(
            name: "cap",
            endpoint: Fixtures.endpoint(fake, outputMode: mode),
            schemaName: "Caption",
            schema: Caption.jsonSchema
        )
    }

    /// The captioner run with the trigger validator and its retry text.
    func validated(_ fake: FakeModelClient, mode: OutputMode = .native) async throws -> StageRun<Caption> {
        try await stage(fake, mode: mode).run(
            instructions: "I",
            messages: Support.turn,
            validate: validate,
            retryMessage: retryMessage
        )
    }

    @Sendable func validate(_ caption: Caption) -> [String] {
        caption.caption.contains("NORA7") ? [] : [Self.problem]
    }

    @Sendable func retryMessage(_ problems: [String]) -> String {
        "Fix the caption: " + problems.joined(separator: "; ") + "."
    }

    @Test func retriesOnceOnValidatorProblems() async throws {
        let first = try FakeModelClient.Reply(encoding: Caption(caption: "no trigger"))
        let fake = FakeModelClient(model: "cap-1") { request in
            request.messages.count == 1 ? first : try FakeModelClient.Reply(encoding: Caption(caption: "NORA7 here"))
        }
        let run = try await validated(fake)
        #expect(run.output.caption == "NORA7 here")
        #expect(run.requests == 2)
        #expect(run.servedModel == "cap-1")
        #expect(run.messages.count == 4)

        let requests = await fake.requests
        #expect(requests.count == 2)
        #expect(requests[1].instructions == "I")
        #expect(requests[1].messages.count == 3)
        #expect(requests[1].messages[1] == .assistant(first.text))
        #expect(requests[1].messages[2].role == .user)
        // pydantic-ai 2.55 RetryPromptPart.model_response for an output-validator ModelRetry
        // with no tool name (native / prompted output).
        #expect(requests[1].lastText
            == "Validation feedback:\nFix the caption: \(Self.problem).\n\nFix the errors and try again.")

        let clean = FakeModelClient.caption(Caption(caption: "NORA7 at once"))
        let single = try await validated(clean)
        #expect(single.requests == 1)
        #expect(single.messages.count == 2)
    }

    /// Only tool output carries a tool name in pydantic-ai, and only then is the validator's
    /// message sent bare; prompted output gets the same prefix as native.
    @Test func validatorRetryTextPerOutputMode() async throws {
        func retryText(_ mode: OutputMode) async throws -> String {
            let fake = FakeModelClient { request in
                request.messages.count == 1
                    ? try FakeModelClient.Reply(encoding: Caption(caption: "no trigger"))
                    : try FakeModelClient.Reply(encoding: Caption(caption: "NORA7 here"))
            }
            _ = try await validated(fake, mode: mode)
            return await fake.requests[1].lastText
        }
        let feedback = "Fix the caption: \(Self.problem)."
        #expect(try await retryText(.tool) == feedback + "\n\nFix the errors and try again.")
        let prefixed = "Validation feedback:\n" + feedback + "\n\nFix the errors and try again."
        #expect(try await retryText(.prompted) == prefixed)
        #expect(try await retryText(.native) == prefixed)
    }

    @Test func twoRejectionsFail() async throws {
        let fake = FakeModelClient.caption(Caption(caption: "never"), model: "cap-2")
        let error = await #expect(throws: StageFailure.self) { try await validated(fake) }
        guard case let .rejected(problems, lastReply, requests, served) = try #require(error) else {
            Issue.record("expected .rejected, got \(String(describing: error))")
            return
        }
        #expect(problems == [Self.problem])
        #expect(requests == 2)
        #expect(served == "cap-2")
        #expect(lastReply.text.contains("never"))
        #expect(await fake.requests.count == 2)
    }

    @Test func undecodableThenGoodSucceeds() async throws {
        let fake = FakeModelClient { request in
            if request.messages.count == 1 { return FakeModelClient.Reply(text: "not json at all") }
            return try FakeModelClient.Reply(encoding: Caption(caption: "NORA7 ok"))
        }
        let run = try await stage(fake).run(instructions: "I", messages: Support.turn, validate: validate)
        #expect(run.output.caption == "NORA7 ok")
        #expect(run.requests == 2)
        // pydantic's json_invalid record; the parser's own message differs between the two
        // implementations, so only the frame is pinned here.
        let retry = await fake.requests[1].lastText
        let frame = "1 validation error:\n```json\n[\n  {\n    \"type\": \"json_invalid\",\n    \"loc\": [],\n"
        #expect(retry.hasPrefix(frame + "    \"msg\": \"Invalid JSON: "))
        #expect(retry.hasSuffix("\"\n  }\n]\n```\n\nFix the errors and try again."))
    }

    /// A reply missing a required field retries with exactly the text pydantic-ai 2.55 sends
    /// for `Caption.model_validate_json('{"usable": true}')` in native mode.
    @Test func missingKeyRetryMatchesPydantic() async throws {
        let fake = FakeModelClient { request in
            if request.messages.count == 1 { return FakeModelClient.Reply(text: #"{"usable": true}"#) }
            return try FakeModelClient.Reply(encoding: Caption(caption: "NORA7 ok"))
        }
        let run = try await stage(fake).run(instructions: "I", messages: Support.turn)
        #expect(run.requests == 2)
        let expected = """
        1 validation error:
        ```json
        [
          {
            "type": "missing",
            "loc": [
              "caption"
            ],
            "msg": "Field required"
          }
        ]
        ```

        Fix the errors and try again.
        """
        #expect(await fake.requests[1].lastText == expected)
    }

    /// The finding's scenario: a prompted-mode model adds a `confidence` field twice. Python's
    /// `extra="forbid"` fails both attempts and the sample ends failed; Swift must agree instead
    /// of writing the first reply.
    @Test func extraKeyRepliesFailLikePydantic() async throws {
        let reply = #"{"caption": "A photo of NORA7.", "usable": true, "note": null, "confidence": 0.9}"#
        let fake = FakeModelClient { _ in FakeModelClient.Reply(text: reply) }
        let error = await #expect(throws: StageFailure.self) {
            try await stage(fake, mode: .prompted).run(instructions: "I", messages: Support.turn, validate: validate)
        }
        guard case let .undecodable(reason, _, requests, _) = try #require(error) else {
            Issue.record("expected .undecodable, got \(String(describing: error))")
            return
        }
        #expect(reason.contains("confidence"))
        #expect(requests == 2)

        let failure = try #require(StructuredStage<Caption>.decode(reply).failureValue)
        #expect(failure.loc == [.string("confidence")])
        #expect(failure.msg == "Value error, Extra inputs are not permitted")
        let retry = await fake.requests[1].lastText
        #expect(retry.contains("\"confidence\""))
        #expect(retry.contains("Extra inputs are not permitted"))
        #expect(retry.hasSuffix(RetryPrompt.suffix))
    }

    @Test func twoUndecodableRepliesFail() async throws {
        let fake = FakeModelClient { _ in FakeModelClient.Reply(text: #"{"usable": true}"#) }
        let error = await #expect(throws: StageFailure.self) {
            try await stage(fake).run(instructions: "I", messages: Support.turn)
        }
        guard case let .undecodable(reason, _, requests, _) = try #require(error) else {
            Issue.record("expected .undecodable, got \(String(describing: error))")
            return
        }
        #expect(reason.contains("caption"))
        #expect(requests == 2)
    }
}

@Suite("modelclient retry prompt")
struct RetryPromptTests {
    struct Item: Decodable {
        let name: String
        let count: Int
    }

    struct Nested: Decodable {
        let items: [Item]
        let flags: [String: Bool]
    }

    func failure(_ text: String) throws -> DecodeFailure {
        guard case let .failure(failure) = StructuredStage<Nested>.decode(text) else {
            throw ConfigurationError("expected a decode failure for \(text)")
        }
        return failure
    }

    @Test func validatorPrefixesOnlyWithoutToolName() {
        let prefixed = "Validation feedback:\nFix it.\n\nFix the errors and try again."
        #expect(RetryPrompt.validator("Fix it.", mode: .native) == prefixed)
        #expect(RetryPrompt.validator("Fix it.", mode: .prompted) == prefixed)
        #expect(RetryPrompt.validator("Fix it.", mode: .tool) == "Fix it.\n\nFix the errors and try again.")
        #expect(StructuredStage<Caption>.retrySuffix == RetryPrompt.suffix)
    }

    @Test func decodeFailuresMapOntoPydanticErrorTypes() throws {
        let missing = try failure(#"{"items": [{"name": "a"}], "flags": {}}"#)
        #expect(missing.type == "missing")
        #expect(missing.loc == [.string("items"), .int(0), .string("count")])
        #expect(missing.msg == "Field required")
        #expect(missing.message == "missing key 'count' at items.Index 0")

        let wrongType = try failure(#"{"items": [{"name": 1, "count": 2}], "flags": {}}"#)
        #expect(wrongType.type == "string_type")
        #expect(wrongType.loc == [.string("items"), .int(0), .string("name")])
        #expect(wrongType.msg == "Input should be a valid string")

        let wrongInt = try failure(#"{"items": [{"name": "a", "count": "2"}], "flags": {}}"#)
        #expect(wrongInt.type == "int_type")
        #expect(wrongInt.msg == "Input should be a valid integer")

        let null = try failure(#"{"items": [], "flags": {"x": null}}"#)
        #expect(null.type == "bool_type")
        #expect(null.loc == [.string("flags"), .string("x")])
        #expect(null.msg == "Input should be a valid boolean")

        let notList = try failure(#"{"items": {}, "flags": {}}"#)
        #expect(notList.type == "list_type")
        #expect(notList.msg == "Input should be a valid list")

        let notDict = try failure(#"{"items": [], "flags": []}"#)
        #expect(notDict.type == "dict_type")
        #expect(notDict.msg == "Input should be a valid dictionary")

        let garbage = try failure("nope")
        #expect(garbage.type == "json_invalid")
        #expect(garbage.loc.isEmpty)
        #expect(garbage.msg.hasPrefix("Invalid JSON: "))
    }

    @Test func undecodableRendersOneRecordWithIntegerIndices() throws {
        let text = try RetryPrompt.undecodable(failure(#"{"items": [{"name": "a"}], "flags": {}}"#))
        let expected = """
        1 validation error:
        ```json
        [
          {
            "type": "missing",
            "loc": [
              "items",
              0,
              "count"
            ],
            "msg": "Field required"
          }
        ]
        ```

        Fix the errors and try again.
        """
        #expect(text == expected)
    }
}

private extension Result {
    var failureValue: Failure? {
        if case let .failure(failure) = self { failure } else { nil }
    }
}
