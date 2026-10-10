import Foundation
import Network

protocol ChatGPTCallback: Sendable {
    func start() async throws -> URL
    func wait() async throws -> URL
    func cancel() async
}

/// A temporary HTTP listener bound only to IPv4 loopback. It never serves app content.
actor ChatGPTLoopbackCallback: ChatGPTCallback {
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var ready: CheckedContinuation<URL, any Error>?
    private var waiting: CheckedContinuation<URL, any Error>?
    private var result: Result<URL, any Error>?
    private var redirectURI: URL?
    private var timeout: Task<Void, Never>?

    func start() async throws -> URL {
        try Task.checkCancellation()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        listener.stateUpdateHandler = { state in Task { await self.changed(state) } }
        listener.newConnectionHandler = { connection in Task { await self.accept(connection) } }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                listener.start(queue: .global(qos: .userInitiated))
                timeout = Task {
                    do { try await Task.sleep(for: .seconds(600)) } catch { return }
                    finish(.failure(ChatGPTAuthError("ChatGPT sign-in timed out. Start a new sign-in.")))
                }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func wait() async throws -> URL {
        try await withTaskCancellationHandler {
            if let result { return try result.get() }
            return try await withCheckedThrowingContinuation { waiting = $0 }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    private func changed(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard result == nil, let port = listener?.port else { return }
            let url = URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback")!
            redirectURI = url
            ready?.resume(returning: url)
            ready = nil
        case let .failed(error): finish(.failure(error))
        default: break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard result == nil else { connection.cancel(); return }
        connections.append(connection)
        connection.start(queue: .global(qos: .userInitiated))
        receive(connection, data: Data())
    }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { chunk, _, complete, error in
            Task { await self.received(connection, data: data + (chunk ?? Data()), complete: complete, error: error) }
        }
    }

    private func received(_ connection: NWConnection, data: Data, complete: Bool, error: NWError?) {
        guard result == nil else { connection.cancel(); return }
        guard error == nil, data.count <= 16384 else { connection.cancel(); return }
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            if complete { connection.cancel() } else { receive(connection, data: data) }
            return
        }
        guard let header = String(bytes: data[..<headerEnd.lowerBound], encoding: .utf8) else {
            connection.cancel()
            return
        }
        guard let redirectURI, let target = Self.callbackTarget(header, redirectURI: redirectURI) else {
            reply(connection, status: "404 Not Found", text: "This address is only for ChatGPT sign-in.")
            return
        }
        reply(connection, status: "200 OK", text: "You can return to ConceptStudio to finish signing in.")
        // Keep this response connection alive until its send completes; stop all other traffic now.
        connections.removeAll { $0 === connection }
        finish(.success(target))
    }

    static func callbackTarget(_ header: String, redirectURI: URL) -> URL? {
        let line = header.components(separatedBy: "\r\n").first ?? ""
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0] == "GET", parts[2].hasPrefix("HTTP/1."),
              parts[1].hasPrefix("/"), !parts[1].hasPrefix("//"),
              let url = URL(string: String(parts[1]), relativeTo: redirectURI)?.absoluteURL,
              url.path() == "/auth/callback", url.host() == "127.0.0.1",
              url.port == redirectURI.port else { return nil }
        return url
    }

    private func reply(_ connection: NWConnection, status: String, text: String) {
        let body = Data(text.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func finish(_ outcome: Result<URL, any Error>) {
        guard result == nil else { return }
        result = outcome
        timeout?.cancel()
        listener?.cancel()
        listener = nil
        for connection in connections {
            connection.cancel()
        }
        connections = []
        if let ready { ready.resume(with: outcome); self.ready = nil }
        if let waiting { waiting.resume(with: outcome); self.waiting = nil }
    }
}
