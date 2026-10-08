import Foundation

public struct OSCError: Error, Sendable, CustomStringConvertible {
    public var status: Int
    /// Branch on this, not `message` (Appendix B).
    public var code: String
    public var message: String
    public var retryAfter: TimeInterval?

    public var description: String { "\(status) \(code): \(message)" }
}

/// Every HTTP call in the protocol. Writes go here; live events come from `EventSocket`.
///
/// - Honors `Retry-After` on 429 (up to a cap), then surfaces the error.
/// - Logs in again once if the session expired, then retries.
/// - Signs with the origin of the *configured* base URL, never one the server reports.
public actor OSCClient {
    public static let defaultServer = URL(string: "https://api.oneshotchat.com")!

    public nonisolated let baseURL: URL
    /// `scheme://host[:port]`, lowercase, default port dropped. Goes into every signed string.
    public nonisolated let origin: String
    public nonisolated let identity: Identity
    public nonisolated let clientInfo: ClientInfo
    public private(set) var displayName: String?
    public private(set) var session: LoginResult?

    private let urlSession: URLSession
    private let incognito: Bool
    private let maxRetryWait: TimeInterval

    public init(baseURL: URL = OSCClient.defaultServer, identity: Identity, displayName: String?,
                client: ClientInfo, incognito: Bool = false, urlSession: URLSession = .shared,
                maxRetryWait: TimeInterval = 60) {
        self.baseURL = baseURL
        origin = Self.origin(of: baseURL)
        self.identity = identity
        self.displayName = displayName
        clientInfo = client
        self.incognito = incognito
        self.urlSession = urlSession
        self.maxRetryWait = maxRetryWait
    }

    public static func origin(of url: URL) -> String {
        let scheme = (url.scheme ?? "https").lowercased()
        let host = (url.host ?? "").lowercased()
        let defaultPort = scheme == "https" ? 443 : scheme == "http" ? 80 : nil
        if let port = url.port, port != defaultPort { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }

    // MARK: discovery and auth

    public func discover() async throws -> Discovery {
        try await call("GET", "/v1", auth: false)
    }

    @discardableResult
    public func login() async throws -> LoginResult {
        struct ChallengeBody: Encodable { var identity: String }
        struct Challenge: Decodable { var challenge: String }
        struct SessionBody: Encodable {
            var identity, challenge, signature: String
            var name: String?
            var incognito: Bool
            var client: ClientInfo
        }

        let fingerprint = identity.fingerprint
        let challenge: Challenge = try await call("POST", "/v1/auth/challenge", auth: false, body: ChallengeBody(identity: fingerprint))
        let signature = try identity.sign(SignedString.login(server: origin, identity: fingerprint, challenge: challenge.challenge))
        let result: LoginResult = try await call("POST", "/v1/auth/session", auth: false, body: SessionBody(
            identity: fingerprint, challenge: challenge.challenge, signature: signature,
            name: displayName, incognito: incognito, client: clientInfo))
        session = result
        if let name = result.identity.name { displayName = name }
        return result
    }

    public func logout() async throws {
        let _: Empty = try await call("DELETE", "/v1/auth/session")
        session = nil
    }

    public func setName(_ name: String) async throws {
        struct Body: Encodable { var name: String }
        let _: Empty = try await call("PATCH", "/v1/me", body: Body(name: name))
        displayName = name
    }

    /// Renews presence in every room this session is in. Any authed request or a
    /// WebSocket ping does the same.
    public func heartbeat() async throws {
        let _: Empty = try await call("POST", "/v1/session/heartbeat")
    }

    // MARK: rooms

    public func rooms(cursor: String? = nil) async throws -> RoomList {
        try await call("GET", "/v1/rooms", query: cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [], auth: false)
    }

    public func room(named name: String) async throws -> Room {
        try await call("GET", "/v1/rooms/by-name/\(segment(name))", authOptional: true)
    }

    public func room(id: String) async throws -> Room {
        try await call("GET", "/v1/rooms/\(segment(id))", authOptional: true)
    }

    /// `expect` pins the room fingerprint you remember: a different room behind the same
    /// name fails with `409 room_changed` instead of silently joining a stranger's room.
    public func join(_ name: String, expect: String? = nil, key: String? = nil, invite: String? = nil,
                     create: RoomCreateOptions? = nil) async throws -> JoinResult {
        struct Body: Encodable {
            var name: String
            var expect, key, invite: String?
            var create: RoomCreateOptions?
        }
        return try await call("POST", "/v1/rooms/join", body: Body(name: name, expect: expect, key: key, invite: invite, create: create))
    }

    public func leave(room: String) async throws {
        let _: Empty = try await call("POST", "/v1/rooms/\(segment(room))/leave")
    }

    // MARK: operator actions (operators and server admins; others get 403 not_operator)

    /// Emits `room.updated` to everyone in the room.
    public func updateRoom(_ room: String, _ update: RoomUpdate) async throws {
        let _: Empty = try await call("PATCH", "/v1/rooms/\(segment(room))", body: update)
    }

    /// `role`: operator, voice, invited, muted or banned. Banning also removes them.
    public func setRole(room: String, identity: String, role: String) async throws {
        struct Body: Encodable { var role: String }
        let _: Empty = try await call("PUT", "/v1/rooms/\(segment(room))/roles/\(segment(identity))", body: Body(role: role))
    }

    /// Everyone with a role in the room, present or not. Anyone in the room may ask.
    public func roles(room: String) async throws -> [RoleEntry] {
        let list: RoleList = try await call("GET", "/v1/rooms/\(segment(room))/roles")
        return list.roles
    }

    public func clearRole(room: String, identity: String) async throws {
        let _: Empty = try await call("DELETE", "/v1/rooms/\(segment(room))/roles/\(segment(identity))")
    }

    /// Removes someone now; they can rejoin unless banned.
    public func kick(room: String, identity: String, reason: String?) async throws {
        struct Body: Encodable { var identity: String; var reason: String? }
        let _: Empty = try await call("POST", "/v1/rooms/\(segment(room))/kick", body: Body(identity: identity, reason: reason))
    }

    /// An invite code for an invite-only room. Defaults: 1 use, 24 hours.
    public func createInvite(room: String, uses: Int = 1, expiresIn: Int = 86400) async throws -> Invite {
        struct Body: Encodable { var uses: Int; var expiresIn: Int }
        return try await call("POST", "/v1/rooms/\(segment(room))/invites", body: Body(uses: uses, expiresIn: expiresIn))
    }

    // MARK: messages

    public func messages(room: String, before: Int? = nil, after: Int? = nil, limit: Int = 50) async throws -> MessagePage {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { query.append(URLQueryItem(name: "before", value: String(before))) }
        if let after { query.append(URLQueryItem(name: "after", value: String(after))) }
        return try await call("GET", "/v1/rooms/\(segment(room))/messages", query: query)
    }

    /// `room` is the room fingerprint (it's part of what gets signed).
    public func send(room: String, text: String, sign: Bool = false, nonce: String = OSCClient.makeNonce()) async throws -> Message {
        struct Body: Encodable { var text: String; var nonce: String; var signature: String? }
        let signature = sign
            ? try identity.sign(SignedString.message(server: origin, room: room, author: identity.fingerprint,
                                                     nonce: nonce, version: 1, text: text))
            : nil
        return try await call("POST", "/v1/rooms/\(segment(room))/messages", body: Body(text: text, nonce: nonce, signature: signature))
    }

    /// Edits `message` (your latest copy of it) to `text`, as version + 1. A signed edit
    /// reuses the original nonce. `409 version_conflict` means another device edited first.
    public func edit(_ message: Message, text: String, sign: Bool = false) async throws -> Message {
        struct Body: Encodable { var text: String; var version: Int; var signature: String? }
        let version = message.version + 1
        var signature: String?
        if sign {
            guard let nonce = message.nonce else {
                throw OSCError(status: 0, code: "missing_nonce", message: "Can't sign an edit of a message without a nonce")
            }
            signature = try identity.sign(SignedString.message(server: origin, room: message.room, author: identity.fingerprint,
                                                               nonce: nonce, version: version, text: text))
        }
        return try await call("PATCH", "/v1/rooms/\(segment(message.room))/messages/\(message.id)",
                              body: Body(text: text, version: version, signature: signature))
    }

    public func react(room: String, message: Int, reaction: String) async throws {
        let _: Empty = try await call("PUT", "/v1/rooms/\(segment(room))/messages/\(message)/reactions/\(segment(reaction))")
    }

    public func unreact(room: String, message: Int, reaction: String) async throws {
        let _: Empty = try await call("DELETE", "/v1/rooms/\(segment(room))/messages/\(message)/reactions/\(segment(reaction))")
    }

    // MARK: events

    public func events(room: String, after: Int, limit: Int = 100) async throws -> EventPage {
        try await call("GET", "/v1/rooms/\(segment(room))/events",
                       query: [URLQueryItem(name: "after", value: String(after)), URLQueryItem(name: "limit", value: String(limit))])
    }

    public func mentions(after cursor: String? = nil, limit: Int = 50) async throws -> MentionPage {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { query.append(URLQueryItem(name: "after", value: cursor)) }
        return try await call("GET", "/v1/me/mentions", query: query)
    }

    /// Single-use, valid for 30 s. `503 unavailable` means no WebSocket here: poll instead.
    public func webSocketTicket() async throws -> WebSocketTicket {
        try await call("POST", "/v1/ws-ticket")
    }

    // MARK: plumbing

    public static func makeNonce() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private struct Empty: Decodable {}

    /// Percent-encodes one path segment (room names, reactions like 👍 → %F0%9F%91%8D).
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private nonisolated func segment(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? s
    }

    private struct NoBody: Encodable {}

    private func call<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [],
                                    auth: Bool = true, authOptional: Bool = false) async throws -> T {
        try await call(method, path, query: query, auth: auth, authOptional: authOptional, body: nil as NoBody?)
    }

    private func call<T: Decodable, B: Encodable>(_ method: String, _ path: String, query: [URLQueryItem] = [],
                                                  auth: Bool = true, authOptional: Bool = false, body: B?) async throws -> T {
        var relogged = false
        var attempts = 0
        while true {
            attempts += 1
            if auth, session == nil { try await login() }
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
            components.percentEncodedPath = path
            components.queryItems = query.isEmpty ? nil : query
            var request = URLRequest(url: components.url!)
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSON.encoder.encode(body)
            }
            if (auth || authOptional), let token = session?.token {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }

            let (data, response) = try await urlSession.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) {
                return try JSON.decoder.decode(T.self, from: data.isEmpty ? Data("{}".utf8) : data)
            }

            let error = Self.error(status: status, data: data, response: response)
            if status == 429, attempts < 4, let wait = error.retryAfter, wait <= maxRetryWait {
                try await Task.sleep(for: .seconds(wait))
                continue
            }
            if status == 401, auth, !relogged, ["session_expired", "unauthorized"].contains(error.code) {
                relogged = true
                session = nil
                continue
            }
            throw error
        }
    }

    private static func error(status: Int, data: Data, response: URLResponse) -> OSCError {
        struct Body: Decodable { struct E: Decodable { var code: String; var message: String? }; var error: E }
        let body = try? JSONDecoder().decode(Body.self, from: data)
        let retry = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        return OSCError(status: status, code: body?.error.code ?? "http_\(status)",
                        message: body?.error.message ?? HTTPURLResponse.localizedString(forStatusCode: status),
                        retryAfter: retry)
    }
}
