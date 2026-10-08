import Foundation

// Wire types for protocol v1. All text in here (names, topics, messages, reactions,
// client metadata) is written by strangers: render it as plain text, never markup.
// Unknown fields are ignored by Codable; unknown enum values decode as `.unknown`.

public struct Discovery: Codable, Sendable {
    public var name: String
    public var `protocol`: String
    public var websocketUrl: URL?
    public var conformanceBot: String?
    public var admins: [String]?
    public var motd: String?
}

public struct ClientInfo: Codable, Sendable, Equatable {
    public var name: String
    public var version: String?
    public var url: String?

    public init(name: String, version: String? = nil, url: String? = nil) {
        self.name = name
        self.version = version
        self.url = url
    }
}

public struct Occupant: Codable, Sendable, Equatable {
    public var identity: String
    public var name: String
    public var role: Role?
    public var admin: Bool?
}

public enum Role: Codable, Sendable, Equatable {
    case `operator`, voice, invited, muted, banned
    case unknown(String)

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "operator": self = .operator
        case "voice": self = .voice
        case "invited": self = .invited
        case "muted": self = .muted
        case "banned": self = .banned
        default: self = .unknown(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public var rawValue: String {
        switch self {
        case .operator: "operator"
        case .voice: "voice"
        case .invited: "invited"
        case .muted: "muted"
        case .banned: "banned"
        case .unknown(let raw): raw
        }
    }
}

public struct RoomActivity: Codable, Sendable, Equatable {
    public var messagesLast10m: Int?
    public var lastMessageAt: Date?

    // Keys are matched after convertFromSnakeCase, which turns "messages_last_10m"
    // into "messagesLast10M" (it capitalizes "10m" as a word).
    enum CodingKeys: String, CodingKey {
        case messagesLast10m = "messagesLast10M"
        case lastMessageAt
    }
}

public struct Room: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var topic: String?
    public var visibility: String?
    public var access: String?
    public var speaking: String?
    public var retentionSeconds: Int?
    public var permanent: Bool?
    public var createdAt: Date?
    /// The following are null for an unlisted room you aren't in.
    public var latestSeq: Int?
    public var activity: RoomActivity?
    public var occupantCount: Int?
    public var occupants: [Occupant]?
}

public struct RoomList: Codable, Sendable {
    public var rooms: [Room]
    public var next: String?
}

public struct JoinResult: Codable, Sendable {
    public var room: Room
    public var role: Role?
    public var created: Bool?
}

/// Settings for a room that a join creates; ignored if the room already exists.
public struct RoomCreateOptions: Codable, Sendable {
    public var visibility: String?
    public var access: String?
    public var speaking: String?
    public var topic: String?
    public var retentionSeconds: Int?
    public var key: String?

    public init(visibility: String? = nil, access: String? = nil, speaking: String? = nil,
                topic: String? = nil, retentionSeconds: Int? = nil, key: String? = nil) {
        self.visibility = visibility
        self.access = access
        self.speaking = speaking
        self.topic = topic
        self.retentionSeconds = retentionSeconds
        self.key = key
    }
}

/// Room settings an operator can change (`PATCH /v1/rooms/{room}`). Only the fields that
/// are set are sent. The key is write-only: the server never returns it.
public struct RoomUpdate: Encodable, Sendable, Equatable {
    public enum Retention: Sendable, Equatable {
        case seconds(Int)
        case forever
    }

    public var topic: String?
    public var visibility: String?       // listed | unlisted
    public var access: String?           // open | key | invite
    public var speaking: String?         // open | moderated
    public var key: String?
    public var retention: Retention?

    public init(topic: String? = nil, visibility: String? = nil, access: String? = nil, speaking: String? = nil,
                key: String? = nil, retention: Retention? = nil) {
        self.topic = topic
        self.visibility = visibility
        self.access = access
        self.speaking = speaking
        self.key = key
        self.retention = retention
    }

    enum CodingKeys: String, CodingKey { case topic, visibility, access, speaking, key, retentionSeconds = "retention_seconds" }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(topic, forKey: .topic)
        try c.encodeIfPresent(visibility, forKey: .visibility)
        try c.encodeIfPresent(access, forKey: .access)
        try c.encodeIfPresent(speaking, forKey: .speaking)
        try c.encodeIfPresent(key, forKey: .key)
        switch retention {
        case .seconds(let s): try c.encode(s, forKey: .retentionSeconds)
        case .forever: try c.encodeNil(forKey: .retentionSeconds)       // null means keep forever
        case nil: break
        }
    }
}

public struct Invite: Decodable, Sendable {
    public var code: String
    public var usesLeft: Int?
    public var expiresAt: Date?
}

public struct Author: Codable, Sendable, Equatable {
    public var identity: String
    /// A snapshot of the name at send time.
    public var name: String
}

public struct ReactionSummary: Codable, Sendable, Equatable {
    public var reaction: String
    public var count: Int
    /// Missing (or empty) when you can see the message but aren't in its room.
    public var identities: [String]?
}

public struct Message: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var room: String
    public var author: Author
    public var client: ClientInfo?
    public var text: String
    public var mentions: [String]?
    public var nonce: String?
    public var signature: String?
    public var version: Int
    public var createdAt: Date?
    public var editedAt: Date?
    public var reactions: [ReactionSummary]?
    public var expiresAt: Date?

    public enum SignatureStatus: Sendable, Equatable {
        case unsigned, valid, invalid
    }

    /// Verify locally rather than trusting the server (protocol §4, "Verifying").
    /// `server` must be our configured origin, never one the server reports.
    public func signatureStatus(server: String) -> SignatureStatus {
        guard let signature else { return .unsigned }
        guard let nonce else { return .invalid }
        let string = SignedString.message(server: server, room: room, author: author.identity,
                                          nonce: nonce, version: version, text: text)
        return Identity.verify(signature: signature, of: string, fingerprint: author.identity) ? .valid : .invalid
    }

    mutating func applyReaction(_ reaction: String, by identity: String, added: Bool) {
        var list = reactions ?? []
        if let i = list.firstIndex(where: { $0.reaction == reaction }) {
            var ids = list[i].identities ?? []
            let had = ids.contains(identity)
            if added, !had {
                ids.append(identity)
                list[i].count += 1
            } else if !added, had {
                ids.removeAll { $0 == identity }
                list[i].count -= 1
            }
            list[i].identities = ids
            if list[i].count <= 0 { list.remove(at: i) }
        } else if added {
            list.append(ReactionSummary(reaction: reaction, count: 1, identities: [identity]))
        }
        reactions = list
    }
}

public struct MessagePage: Codable, Sendable {
    public var messages: [Message]
    public var hasMore: Bool
}

public struct Notice: Codable, Sendable, Equatable {
    public var code: String
    public var text: String
}

public struct Event: Decodable, Sendable {
    public var seq: Int
    public var room: String
    public var type: String
    public var at: Date?
    public var payload: Payload

    public enum Payload: Sendable {
        case messageCreated(Message)
        case messageEdited(Message)
        case reactionAdded(ReactionChange)
        case reactionRemoved(ReactionChange)
        case memberJoined(MemberJoined)
        case memberLeft(MemberLeft)
        case memberRenamed(MemberRenamed)
        case memberRoleChanged(MemberRoleChanged)
        case roomUpdated(Room)
        /// From the server, never a user. The only trustworthy "system" text.
        case notice(Notice)
        /// A type we don't know, or one whose data didn't parse. Skip it.
        case unknown
    }

    public struct ReactionChange: Codable, Sendable {
        public var messageId: Int
        public var reaction: String
        public var identity: String
    }

    public struct MemberJoined: Codable, Sendable {
        public var identity: String
        public var name: String
        public var role: Role?
    }

    public struct MemberLeft: Codable, Sendable {
        public var identity: String
        public var name: String?
        public var reason: String?   // left | timeout | kicked | banned
        public var by: String?
        public var message: String?
    }

    public struct MemberRenamed: Codable, Sendable {
        public var identity: String
        public var oldName: String?
        public var newName: String
    }

    public struct MemberRoleChanged: Codable, Sendable {
        public var identity: String
        public var role: Role?
        public var by: String?
    }

    private struct MessageData: Decodable { var message: Message }
    private struct RoomData: Decodable { var room: Room }

    enum CodingKeys: String, CodingKey { case seq, room, type, at, data }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decode(Int.self, forKey: .seq)
        room = try c.decode(String.self, forKey: .room)
        type = try c.decode(String.self, forKey: .type)
        at = try? c.decodeIfPresent(Date.self, forKey: .at)

        func data<T: Decodable>(_: T.Type) -> T? { try? c.decode(T.self, forKey: .data) }
        let parsed: Payload? = switch type {
        case "message.created": data(MessageData.self).map { .messageCreated($0.message) }
        case "message.edited": data(MessageData.self).map { .messageEdited($0.message) }
        case "reaction.added": data(ReactionChange.self).map { .reactionAdded($0) }
        case "reaction.removed": data(ReactionChange.self).map { .reactionRemoved($0) }
        case "member.joined": data(MemberJoined.self).map { .memberJoined($0) }
        case "member.left": data(MemberLeft.self).map { .memberLeft($0) }
        case "member.renamed": data(MemberRenamed.self).map { .memberRenamed($0) }
        case "member.role_changed": data(MemberRoleChanged.self).map { .memberRoleChanged($0) }
        case "room.updated": data(RoomData.self).map { .roomUpdated($0.room) }
        case "notice": data(Notice.self).map { .notice($0) }
        default: nil
        }
        payload = parsed ?? .unknown
    }
}

public struct EventPage: Decodable, Sendable {
    public var events: [Event]
    public var hasMore: Bool
    public var latestSeq: Int?
    /// Events after your cursor have expired: reload messages and continue from `latestSeq`.
    public var truncated: Bool?
}

public struct MentionItem: Decodable, Sendable {
    public struct RoomRef: Decodable, Sendable {
        public var id: String
        public var name: String
    }

    public var cursor: String?
    public var room: RoomRef
    public var message: Message
}

public struct MentionPage: Decodable, Sendable {
    public var mentions: [MentionItem]
    public var nextCursor: String?
}

public struct SessionIdentity: Codable, Sendable {
    public var id: String
    public var name: String?
    public var status: String?
    public var incognito: Bool?
}

public struct LoginResult: Codable, Sendable {
    public var token: String
    public var expiresAt: Date?
    public var identity: SessionIdentity
}

public struct WebSocketTicket: Codable, Sendable {
    public var ticket: String
    public var url: URL
    public var expiresAt: Date?
}

/// One frame from the receive-only WebSocket.
public enum SocketFrame: Sendable {
    case event(Event)
    case mention(MentionItem)
    case sessionNotice(Notice)
    case pong
    case unknown

    public static func decode(_ data: Data) -> SocketFrame {
        struct Probe: Decodable { var type: String?; var seq: Int? }
        struct MentionFrame: Decodable { var mention: MentionItem }
        struct NoticeFrame: Decodable { var data: Notice }
        let decoder = JSON.decoder
        guard let probe = try? decoder.decode(Probe.self, from: data) else { return .unknown }
        if probe.seq != nil { return (try? decoder.decode(Event.self, from: data)).map(SocketFrame.event) ?? .unknown }
        switch probe.type {
        case "mention": return (try? decoder.decode(MentionFrame.self, from: data)).map { .mention($0.mention) } ?? .unknown
        case "session.notice": return (try? decoder.decode(NoticeFrame.self, from: data)).map { .sessionNotice($0.data) } ?? .unknown
        case "pong": return .pong
        default: return .unknown
        }
    }
}

enum JSON {
    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            if let date = Timestamp.parse(string) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad timestamp \(string)"))
        }
        return d
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }
}

/// RFC 3339 UTC with milliseconds; tolerates a missing fraction.
enum Timestamp {
    static func parse(_ string: String) -> Date? {
        if let d = try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return d }
        return try? Date(string, strategy: Date.ISO8601FormatStyle())
    }
}

/// Someone's role in a room (`GET /v1/rooms/{room}/roles`). Roles outlast presence, so
/// this includes people who aren't there.
public struct RoleEntry: Codable, Sendable, Equatable {
    public var identity: String
    public var role: Role
    public var name: String?

    public init(identity: String, role: Role, name: String? = nil) {
        self.identity = identity
        self.role = role
        self.name = name
    }
}

/// The roles listing, as `{"roles": [...]}` or a bare array: the protocol doesn't spell
/// out the shape, so either is accepted.
struct RoleList: Decodable {
    var roles: [RoleEntry]

    private enum CodingKeys: String, CodingKey { case roles }

    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self), let roles = try? keyed.decode([RoleEntry].self, forKey: .roles) {
            self.roles = roles
        } else {
            roles = try decoder.singleValueContainer().decode([RoleEntry].self)
        }
    }
}

/// `GET /v1/identities/{fingerprint}`: someone's current name and status. It never says
/// which rooms they're in.
public struct IdentityInfo: Codable, Sendable, Equatable {
    public var id: String?
    public var name: String?
    /// `active` or `retired`.
    public var status: String?

    public init(id: String? = nil, name: String? = nil, status: String? = nil) {
        self.id = id
        self.name = name
        self.status = status
    }
}
