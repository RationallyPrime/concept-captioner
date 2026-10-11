// Server-sent events (text/event-stream) parsed from raw body bytes.
//
// Framing follows the WHATWG event-stream rules: lines end in CRLF, LF or CR; a blank line
// dispatches the event; `data` lines join with "\n"; `:` lines are comments; one leading space
// after the colon is dropped. Two lenient additions keep a sloppy server from merging events:
// an `event:` or `id:` field that arrives while data is already buffered closes the buffered
// event first, and an event still buffered when the body ends is dispatched.

import Foundation

public struct ServerSentEvent: Sendable, Equatable {
    /// The `event:` field; nil when the event named none (the spec's default "message").
    public let event: String?
    public let data: String
    /// The last `id:` seen on the stream, as the spec's last-event-ID.
    public let id: String?

    public init(event: String? = nil, data: String, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

/// Incremental parser: feed body bytes in chunks of any size, then `finish()` at end of body.
public struct ServerSentEventParser: Sendable {
    private var line: [UInt8] = []
    private var afterCR = false
    private var firstLine = true
    private var data: [String] = []
    private var event: String?
    private var lastID: String?

    public init() {}

    /// The events completed by `bytes`, in order.
    public mutating func feed(_ bytes: some Sequence<UInt8>) -> [ServerSentEvent] {
        var events: [ServerSentEvent] = []
        for byte in bytes {
            if afterCR {
                afterCR = false
                if byte == 0x0A { continue } // the LF of a CRLF pair split anywhere
            }
            switch byte {
            case 0x0A:
                endLine(into: &events)
            case 0x0D:
                endLine(into: &events)
                afterCR = true
            default:
                line.append(byte)
            }
        }
        return events
    }

    /// The events still pending at end of body: a final unterminated line, then any buffered data.
    public mutating func finish() -> [ServerSentEvent] {
        var events: [ServerSentEvent] = []
        if !line.isEmpty { endLine(into: &events) }
        dispatch(into: &events)
        return events
    }

    private mutating func endLine(into events: inout [ServerSentEvent]) {
        // Lossy on purpose: the spec decodes the stream as UTF-8 with replacement characters.
        // swiftlint:disable:next optional_data_string_conversion
        var text = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)
        if firstLine {
            firstLine = false
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        }
        if text.isEmpty {
            dispatch(into: &events)
            return
        }
        if text.hasPrefix(":") { return }
        var value: Substring = ""
        let field: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            value = text[text.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = text[...]
        }
        switch field {
        case "data":
            data.append(String(value))
        case "event":
            if !data.isEmpty { dispatch(into: &events) }
            event = String(value)
        case "id":
            if !data.isEmpty { dispatch(into: &events) }
            if !value.contains("\0") { lastID = String(value) }
        default:
            break // `retry` and unknown fields carry nothing a captioner needs
        }
    }

    private mutating func dispatch(into events: inout [ServerSentEvent]) {
        defer {
            data = []
            event = nil
        }
        guard !data.isEmpty else { return }
        events.append(ServerSentEvent(event: event, data: data.joined(separator: "\n"), id: lastID))
    }
}

/// The events of a streamed body, in arrival order. Single pass, like the body it reads.
public struct ServerSentEventStream: AsyncSequence, Sendable {
    public typealias Element = ServerSentEvent

    let body: AsyncThrowingStream<Data, any Error>

    public init(body: AsyncThrowingStream<Data, any Error>) {
        self.body = body
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(body: body.makeAsyncIterator())
    }

    public struct Iterator: AsyncIteratorProtocol {
        var body: AsyncThrowingStream<Data, any Error>.Iterator
        var parser = ServerSentEventParser()
        var pending: [ServerSentEvent] = []
        var ended = false

        public mutating func next() async throws -> ServerSentEvent? {
            while pending.isEmpty {
                if ended { return nil }
                if let chunk = try await body.next() {
                    pending = parser.feed(chunk)
                } else {
                    ended = true
                    pending = parser.finish()
                }
            }
            return pending.removeFirst()
        }
    }
}
