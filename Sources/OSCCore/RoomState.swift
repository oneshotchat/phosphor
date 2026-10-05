import Foundation

/// Everything we know about one joined room, kept current by applying events in `seq` order.
public struct RoomState: Sendable {
    public internal(set) var room: Room
    public internal(set) var role: Role?
    /// Present people, by fingerprint.
    public internal(set) var occupants: [String: Occupant] = [:]
    /// Latest version of each message we've seen, by id (= the creating event's seq).
    public internal(set) var messages: [Int: Message] = [:]
    /// Highest seq applied. The cursor for `GET …/events?after=`.
    public internal(set) var lastSeq: Int
    private var applied: Set<Int> = []

    public init(room: Room, role: Role?) {
        self.room = room
        self.role = role
        lastSeq = room.latestSeq ?? 0
        floorSeq = lastSeq
        for occupant in room.occupants ?? [] { occupants[occupant.identity] = occupant }
    }

    public var id: String { room.id }

    public var orderedMessages: [Message] { messages.values.sorted { $0.id < $1.id } }

    /// Tripcode labels (fingerprint → label) for everyone in view: occupants plus the
    /// authors of loaded messages, which is the set the protocol says to disambiguate.
    public var labels: [String: String] {
        var people = occupants.values.map { (name: $0.name, fingerprint: $0.identity) }
        for message in messages.values where occupants[message.author.identity] == nil {
            people.append((message.author.name, message.author.identity))
        }
        return Tripcode.labels(for: people)
    }

    /// Merges a history page. Safe to repeat: messages are replaced by id.
    public mutating func load(_ page: [Message]) {
        for message in page { upsert(message) }
    }

    /// Applies an event at most once. Events at or below the join snapshot's seq are
    /// already reflected in it, so they're skipped. Returns whether the event was new.
    @discardableResult
    public mutating func apply(_ event: Event) -> Bool {
        // Out-of-order WebSocket delivery is fine: a late event above the floor still applies.
        guard event.room == room.id, event.seq > floorSeq, !applied.contains(event.seq) else { return false }
        applied.insert(event.seq)
        lastSeq = max(lastSeq, event.seq)
        if applied.count > 2000 {
            floorSeq = lastSeq - 1000
            applied = applied.filter { $0 > floorSeq }
        }

        switch event.payload {
        case .messageCreated(let m), .messageEdited(let m):
            upsert(m)
        case .reactionAdded(let r):
            messages[r.messageId]?.applyReaction(r.reaction, by: r.identity, added: true)
        case .reactionRemoved(let r):
            messages[r.messageId]?.applyReaction(r.reaction, by: r.identity, added: false)
        case .memberJoined(let j):
            occupants[j.identity] = Occupant(identity: j.identity, name: j.name, role: j.role, admin: occupants[j.identity]?.admin)
        case .memberLeft(let l):
            occupants[l.identity] = nil
        case .memberRenamed(let r):
            occupants[r.identity]?.name = r.newName
        case .memberRoleChanged(let r):
            occupants[r.identity]?.role = r.role
        case .roomUpdated(let updated):
            let occupantsBefore = occupants
            room = updated
            if let list = updated.occupants {
                occupants = [:]
                for o in list { occupants[o.identity] = o }
            } else {
                occupants = occupantsBefore
            }
        case .notice, .unknown:
            break
        }
        return true
    }

    /// Restart from a fresh snapshot after `truncated` (events we missed have expired).
    public mutating func reset(messages page: [Message], latestSeq: Int) {
        messages = [:]
        applied = []
        load(page)
        lastSeq = latestSeq
        floorSeq = latestSeq
    }

    /// Drop messages past their room's retention.
    public mutating func pruneExpired(now: Date = Date()) {
        messages = messages.filter { $0.value.expiresAt.map { $0 > now } ?? true }
    }

    mutating func updateRole(_ role: Role?) { self.role = role }

    /// Events at or below this were covered by a snapshot; never apply them.
    private var floorSeq: Int = 0

    private mutating func upsert(_ message: Message) {
        if let existing = messages[message.id], existing.version > message.version { return }
        messages[message.id] = message
    }
}
