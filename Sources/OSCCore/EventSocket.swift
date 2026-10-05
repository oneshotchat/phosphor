import Foundation

/// The receive-only WebSocket (§9) as an async stream. It takes care of tickets, pings,
/// and reconnecting with backoff (1 s, 2 s, 4 s … 60 s). Disconnects are normal: the
/// server closes every connection within 2 hours. After each `.connected`, the consumer
/// must catch up every room over HTTP, since events may have been missed in the gap.
public enum EventSocket {
    public enum Status: Sendable, Equatable {
        case connecting
        case connected
        case disconnected(reason: String)
        /// The server offers no WebSocket (`503`). Poll the events endpoint instead.
        case unavailable
    }

    public enum Output: Sendable {
        case status(Status)
        case frame(SocketFrame)
    }

    public static func stream(client: OSCClient, pingInterval: Duration = .seconds(60),
                              urlSession: URLSession = .shared) -> AsyncStream<Output> {
        AsyncStream { continuation in
            let task = Task {
                var backoff: Double = 1
                while !Task.isCancelled {
                    continuation.yield(.status(.connecting))
                    do {
                        let ticket = try await client.webSocketTicket()
                        let socket = urlSession.webSocketTask(with: ticket.url)
                        socket.resume()
                        defer { socket.cancel(with: .goingAway, reason: nil) }

                        // The first ping completes once the handshake has, and renews presence.
                        try await socket.send(.string(#"{"action":"ping"}"#))
                        continuation.yield(.status(.connected))

                        // Ping at least every 2 min and at most every 10 s, or the server hangs up.
                        let pinger = Task {
                            while !Task.isCancelled {
                                try await Task.sleep(for: pingInterval)
                                try await socket.send(.string(#"{"action":"ping"}"#))
                            }
                        }
                        defer { pinger.cancel() }

                        while !Task.isCancelled {
                            let message = try await withTaskCancellationHandler {
                                try await socket.receive()
                            } onCancel: {
                                socket.cancel(with: .goingAway, reason: nil)
                            }
                            backoff = 1
                            switch message {
                            case .string(let text): continuation.yield(.frame(SocketFrame.decode(Data(text.utf8))))
                            case .data(let data): continuation.yield(.frame(SocketFrame.decode(data)))
                            @unknown default: break
                            }
                        }
                    } catch let error as OSCError where error.status == 503 {
                        continuation.yield(.status(.unavailable))
                        break
                    } catch {
                        if Task.isCancelled { break }
                        continuation.yield(.status(.disconnected(reason: String(describing: error))))
                    }
                    try? await Task.sleep(for: .seconds(backoff))
                    backoff = min(backoff * 2, 60)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
