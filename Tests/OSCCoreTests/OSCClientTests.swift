import Foundation
import Testing
@testable import OSCCore

/// Serves canned responses in order and records every request it saw.
final class StubServer: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var json = "{}"
        var headers: [String: String] = [:]
    }

    struct Seen {
        var method: String
        var path: String      // percent-encoded, as sent
        var query: String?
        var authorization: String?
        var body: [String: Any]
    }

    nonisolated(unsafe) static var replies: [Reply] = []
    nonisolated(unsafe) static var seen: [Seen] = []
    static let lock = NSLock()

    static func reset(_ replies: [Reply]) {
        lock.withLock {
            self.replies = replies
            seen = []
        }
    }

    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubServer.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var bodyData = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                bodyData.append(buffer, count: n)
            }
            stream.close()
        }
        let body = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] ?? [:]
        let url = request.url!
        let reply: Reply = Self.lock.withLock {
            Self.seen.append(Seen(method: request.httpMethod ?? "GET",
                                  path: URLComponents(url: url, resolvingAgainstBaseURL: false)!.percentEncodedPath,
                                  query: url.query, authorization: request.value(forHTTPHeaderField: "Authorization"), body: body))
            return Self.replies.isEmpty ? Reply(status: 500, json: #"{"error":{"code":"internal","message":"no stub"}}"#)
                                        : Self.replies.removeFirst()
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: reply.headers.merging(["Content-Type": "application/json"]) { a, _ in a })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private let loginReplies: [StubServer.Reply] = [
    .init(json: #"{"challenge":"ucq2fi5euwtkpkfjvkv2zlnov6yldmvtws23nn5yxg5lxpf5x27q","expires_at":"2026-10-03T04:06:06.000Z"}"#),
    .init(json: #"{"token":"tok1","expires_at":"2026-10-04T04:05:06.789Z","identity":{"id":"x","name":"sam","status":"active","incognito":false}}"#),
]

private func makeClient() throws -> OSCClient {
    OSCClient(baseURL: URL(string: "https://api.oneshotchat.com")!,
              identity: try Identity(seed: "aaaqeayeaudaocajbifqydiob4ibceqtcqkrmfyydenbwha5dypq"),
              displayName: "sam", client: ClientInfo(name: "phosphor", version: "0.1"),
              urlSession: StubServer.session)
}

@Suite(.serialized) struct OSCClientTests {
    @Test func loginSignsChallengeForConfiguredOrigin() async throws {
        StubServer.reset(loginReplies)
        let client = try makeClient()
        let result = try await client.login()
        #expect(result.token == "tok1")

        let seen = StubServer.seen
        #expect(seen.map(\.path) == ["/v1/auth/challenge", "/v1/auth/session"])
        let body = seen[1].body
        let fingerprint = "aoqqpp7tzyil4hlq3umoos6atft6jvrqtosq2xy53sdgiesvgg4a"
        #expect(body["identity"] as? String == fingerprint)
        #expect((body["client"] as? [String: Any])?["name"] as? String == "phosphor")
        let signed = SignedString.login(server: "https://api.oneshotchat.com", identity: fingerprint,
                                        challenge: "ucq2fi5euwtkpkfjvkv2zlnov6yldmvtws23nn5yxg5lxpf5x27q")
        #expect(Identity.verify(signature: body["signature"] as? String ?? "", of: signed, fingerprint: fingerprint))
    }

    @Test func authedCallsLogInFirstAndSendBearer() async throws {
        StubServer.reset(loginReplies + [.init()])
        let client = try makeClient()
        try await client.react(room: "ibaueq2eivdeoscjjjfuytkoj4", message: 1044, reaction: "👍")
        let last = StubServer.seen.last!
        #expect(last.method == "PUT")
        #expect(last.path == "/v1/rooms/ibaueq2eivdeoscjjjfuytkoj4/messages/1044/reactions/%F0%9F%91%8D")
        #expect(last.authorization == "Bearer tok1")
    }

    @Test func signedSendUsesRoomFingerprintAndNonce() async throws {
        let room = "ibaueq2eivdeoscjjjfuytkoj4"
        let message = #"{"id":7,"room":"\#(room)","author":{"identity":"x","name":"sam"},"text":"hi","nonce":"n0nce123","version":1}"#
        StubServer.reset(loginReplies + [.init(status: 201, json: message)])
        let client = try makeClient()
        let sent = try await client.send(room: room, text: "hi\nthere", sign: true, nonce: "n0nce123")
        #expect(sent.id == 7)
        let body = StubServer.seen.last!.body
        #expect(body["nonce"] as? String == "n0nce123")
        let string = SignedString.message(server: "https://api.oneshotchat.com", room: room, author: client.identity.fingerprint,
                                          nonce: "n0nce123", version: 1, text: "hi\nthere")
        #expect(Identity.verify(signature: body["signature"] as? String ?? "", of: string, fingerprint: client.identity.fingerprint))
    }

    @Test func editSendsNextVersion() async throws {
        let json = #"{"id":7,"room":"r","author":{"identity":"x","name":"sam"},"text":"v2","nonce":"n0nce123","version":2}"#
        StubServer.reset(loginReplies + [.init(json: json)])
        let client = try makeClient()
        let original = try JSON.decoder.decode(Message.self, from: Data(#"{"id":7,"room":"r","author":{"identity":"x","name":"sam"},"text":"v1","nonce":"n0nce123","version":1}"#.utf8))
        _ = try await client.edit(original, text: "v2")
        let last = StubServer.seen.last!
        #expect(last.method == "PATCH")
        #expect(last.path == "/v1/rooms/r/messages/7")
        #expect(last.body["version"] as? Int == 2)
    }

    @Test func retriesAfterRateLimit() async throws {
        StubServer.reset(loginReplies + [
            .init(status: 429, json: #"{"error":{"code":"rate_limited","message":"slow down"}}"#, headers: ["Retry-After": "0"]),
            .init(),
        ])
        let client = try makeClient()
        try await client.heartbeat()
        #expect(StubServer.seen.filter { $0.path == "/v1/session/heartbeat" }.count == 2)
    }

    @Test func logsInAgainWhenSessionExpires() async throws {
        StubServer.reset(loginReplies + [
            .init(status: 401, json: #"{"error":{"code":"session_expired","message":"log in again"}}"#),
        ] + loginReplies + [.init()])
        let client = try makeClient()
        try await client.heartbeat()
        #expect(StubServer.seen.map(\.path) == ["/v1/auth/challenge", "/v1/auth/session", "/v1/session/heartbeat",
                                                "/v1/auth/challenge", "/v1/auth/session", "/v1/session/heartbeat"])
    }

    @Test func surfacesErrorCodes() async throws {
        StubServer.reset(loginReplies + [.init(status: 409, json: #"{"error":{"code":"room_changed","message":"different room"}}"#)])
        let client = try makeClient()
        do {
            _ = try await client.join("lobby", expect: "abc")
            Issue.record("expected an error")
        } catch let error as OSCError {
            #expect(error.status == 409)
            #expect(error.code == "room_changed")
        }
        #expect(StubServer.seen.last!.body["expect"] as? String == "abc")
    }

    @Test func joinSendsRoomKey() async throws {
        let room = #"{"room":{"id":"ibaueq2eivdeoscjjjfuytkoj4","name":"secret"},"role":null,"created":false}"#
        StubServer.reset(loginReplies + [.init(json: room)])
        let client = try makeClient()
        _ = try await client.join("secret", key: "hunter2")
        let body = StubServer.seen.last!.body
        #expect(body["name"] as? String == "secret")
        #expect(body["key"] as? String == "hunter2")
        #expect(body["expect"] == nil)
    }

    @Test func roomUpdateSendsOnlyChangedFields() async throws {
        StubServer.reset(loginReplies + [.init(), .init()])
        let client = try makeClient()
        try await client.updateRoom("r1", RoomUpdate(visibility: "unlisted"))
        var last = StubServer.seen.last!
        #expect(last.method == "PATCH")
        #expect(last.path == "/v1/rooms/r1")
        #expect(last.body.keys.sorted() == ["visibility"])
        #expect(last.body["visibility"] as? String == "unlisted")

        try await client.updateRoom("r1", RoomUpdate(access: "key", key: "hunter2", retention: .forever))
        last = StubServer.seen.last!
        #expect(last.body.keys.sorted() == ["access", "key", "retention_seconds"])
        #expect(last.body["retention_seconds"] is NSNull)     // null: keep forever
    }

    @Test func rolesKicksAndInvites() async throws {
        let invite = #"{"code":"k3v9","uses_left":2,"expires_at":"2026-10-07T00:00:00.000Z"}"#
        StubServer.reset(loginReplies + [.init(), .init(), .init(), .init(status: 201, json: invite)])
        let client = try makeClient()
        try await client.setRole(room: "r1", identity: "abc", role: "voice")
        #expect(StubServer.seen.last!.method == "PUT")
        #expect(StubServer.seen.last!.path == "/v1/rooms/r1/roles/abc")
        #expect(StubServer.seen.last!.body["role"] as? String == "voice")
        try await client.clearRole(room: "r1", identity: "abc")
        #expect(StubServer.seen.last!.method == "DELETE")
        try await client.kick(room: "r1", identity: "abc", reason: "spam")
        #expect(StubServer.seen.last!.path == "/v1/rooms/r1/kick")
        #expect(StubServer.seen.last!.body["reason"] as? String == "spam")
        let made = try await client.createInvite(room: "r1", uses: 2)
        #expect(made.code == "k3v9")
        #expect(made.usesLeft == 2)
        #expect(StubServer.seen.last!.body["expires_in"] as? Int == 86400)
    }

    @Test func publicCallsDontLogIn() async throws {
        StubServer.reset([.init(json: #"{"rooms":[],"next":null}"#)])
        let client = try makeClient()
        _ = try await client.rooms()
        #expect(StubServer.seen.map(\.path) == ["/v1/rooms"])
        #expect(StubServer.seen[0].authorization == nil)
    }
}
