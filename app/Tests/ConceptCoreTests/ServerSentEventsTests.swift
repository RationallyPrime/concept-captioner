import ConceptCore
import Foundation
import Testing

private func parse(_ chunks: [String]) -> [ServerSentEvent] {
    var parser = ServerSentEventParser()
    return chunks.flatMap { parser.feed(Data($0.utf8)) } + parser.finish()
}

@Suite("server-sent events")
struct ServerSentEventsTests {
    @Test func blankLinesSeparateEvents() {
        let events = parse(["event: a\ndata: {\"n\":1}\n\nevent: b\ndata: {\"n\":2}\n\n"])
        #expect(events == [
            ServerSentEvent(event: "a", data: #"{"n":1}"#),
            ServerSentEvent(event: "b", data: #"{"n":2}"#),
        ])
    }

    @Test(arguments: ["\n", "\r\n", "\r"])
    func everyLineEndingWorksEvenSplitAcrossChunks(_ newline: String) {
        let text = "data: one\(newline)\(newline)data: two\(newline)\(newline)"
        let bytes = Array(text.utf8)
        // Every possible split point, including between the CR and LF of a CRLF pair.
        for cut in 0 ... bytes.count {
            var parser = ServerSentEventParser()
            let events = parser.feed(bytes[..<cut]) + parser.feed(bytes[cut...]) + parser.finish()
            #expect(events.map(\.data) == ["one", "two"], "cut at \(cut)")
        }
    }

    @Test func multiLineDataCommentsAndBOM() {
        let events = parse(["\u{FEFF}: heartbeat\n", "data:first\ndata: second\nretry: 10\n\n"])
        #expect(events == [ServerSentEvent(data: "first\nsecond")])
    }

    @Test func eventOrIDAfterBufferedDataClosesTheEvent() {
        let events = parse(["event: a\ndata: 1\nevent: b\ndata: 2\nid: 7\ndata: 3\n\n"])
        #expect(events == [
            ServerSentEvent(event: "a", data: "1"),
            ServerSentEvent(event: "b", data: "2"),
            ServerSentEvent(data: "3", id: "7"),
        ])
    }

    @Test func eventWithoutDataIsNotDispatchedAndUnterminatedEventIsFlushedAtEnd() {
        #expect(parse(["event: ping\n\n", "data: last"]) == [ServerSentEvent(data: "last")])
    }

    @Test func multiByteCharactersSplitAcrossChunksSurvive() {
        let bytes = Array("data: Þór ✓\n\n".utf8)
        var parser = ServerSentEventParser()
        let events = bytes.flatMap { parser.feed([$0]) } + parser.finish()
        #expect(events == [ServerSentEvent(data: "Þór ✓")])
    }

    @Test func eventsArriveBeforeTheBodyEnds() async throws {
        let (body, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let response = HTTPStreamResponse(status: 200, body: body)
        var events = response.events.makeAsyncIterator()
        continuation.yield(Data("data: first\n".utf8))
        continuation.yield(Data("\n".utf8))
        // The stream is still open: the first event must not wait for the body to finish.
        #expect(try await events.next() == ServerSentEvent(data: "first"))
        continuation.yield(Data("data: second\n\n".utf8))
        continuation.finish()
        #expect(try await events.next() == ServerSentEvent(data: "second"))
        #expect(try await events.next() == nil)
    }

    @Test func collectStopsAtTheLimit() async throws {
        let response = HTTPStreamResponse(status: 500, body: AsyncThrowingStream { continuation in
            continuation.yield(Data("abcdef".utf8))
            continuation.yield(Data("ghij".utf8))
            continuation.finish()
        })
        #expect(try await response.collect(limit: 8) == Data("abcdefgh".utf8))
    }
}
