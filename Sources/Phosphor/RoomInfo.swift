import Foundation
import OSCCore

/// What the room info wall (/room, ⌘I) says about the active room, in plain words.
struct RoomInfo: Equatable {
    struct Row: Equatable {
        var icon: Icon
        var label: String
        var value: String
        /// How an operator changes it, shown only to operators.
        var change: String?
    }

    struct Person: Equatable {
        var identity: String
        var label: String
        /// A role, or when they last spoke; empty for none.
        var note: String = ""
    }

    var name: String
    var roomID: String
    var topic: String?
    var lifetime: String
    var settings: [Row]
    var here: Int
    var operators: [Person]
    var you: Person
    var youAre: String
    var signing: Bool
    var isOperator: Bool

    /// The people wall: everyone here; people with a role who aren't; and who spoke in the
    /// loaded history but isn't here (the protocol keeps no other record of who came by).
    var present: [Person]
    var absentRoles: [Person]
    var recent: [Person]
    /// Everyone on the people wall, in order, for ↑↓.
    var everyone: [Person] { present + absentRoles + recent }
    /// Looked-up status (`active`, `retired`) by fingerprint, when known.
    var statuses: [String: String]

    /// `roles` is the room's role listing, when it's been fetched.
    /// `identities` are names and statuses looked up by fingerprint, for people the room
    /// itself doesn't name (role holders who aren't here).
    init(state: RoomState, me: String, myName: String, signing: Bool, isOperator: Bool, roles: [RoleEntry]?,
         identities: [String: IdentityInfo] = [:], now: Date = Date()) {
        let room = state.room
        name = "#" + SafeText.clean(room.name)
        roomID = room.id
        statuses = identities.compactMapValues(\.status)
        topic = room.topic.map(SafeText.clean).flatMap { $0.isEmpty ? nil : $0.replacingOccurrences(of: "\n", with: " ") }

        var life: [String] = []
        if let created = room.createdAt {
            let f = DateFormatter()
            f.setLocalizedDateFormatFromTemplate("d MMM yyyy")
            life.append("created \(f.string(from: created))")
        }
        life.append(room.permanent == true ? "permanent" : "closes after 7 days with nobody here")
        lifetime = life.joined(separator: " · ")

        let listed = room.visibility != "unlisted"
        let joining: Row = switch room.access {
        case "key": Row(icon: .key, label: "JOINING", value: "needs the room key", change: "/room open · /room invite")
        case "invite": Row(icon: .envelope, label: "JOINING", value: "invite only: /invite makes a code",
                           change: "/room open · /room key <key>")
        default: Row(icon: .padlockOpen, label: "JOINING", value: "anyone can join", change: "/room key <key> · /room invite")
        }
        let moderated = room.speaking == "moderated"
        let kept: Row = if let seconds = room.retentionSeconds {
            Row(icon: .hourglass, label: "MESSAGES", value: "kept for \(Self.duration(seconds))",
                change: "/room retention 24h · 7d · forever")
        } else {
            Row(icon: .infinity, label: "MESSAGES", value: "kept forever", change: "/room retention 24h · 7d")
        }
        settings = [
            Row(icon: listed ? .eye : .eyeHidden, label: "VISIBILITY",
                value: listed ? "listed in the room browser" : "unlisted: found only by name",
                change: listed ? "/room unlisted" : "/room listed"),
            joining,
            Row(icon: moderated ? .bubbleVoiced : .bubble, label: "SPEAKING",
                value: moderated ? "only operators and voiced people" : "anyone can speak",
                change: moderated ? "/room unmoderated" : "/room moderated"),
            kept,
        ]

        let labels = state.labels
        var authorNames: [String: String] = [:]
        for m in state.orderedMessages { authorNames[m.author.identity] = m.author.name }
        func label(_ identity: String, _ name: String?) -> String {
            SafeText.clean(labels[identity] ?? name ?? authorNames[identity] ?? identities[identity]?.name ?? String(identity.prefix(8)))
        }
        here = state.occupants.count

        // Roles: the listing if we have it (it includes people who aren't here), else
        // what the occupants say.
        var roleOf: [String: Role] = [:]
        for o in state.occupants.values { if let r = o.role { roleOf[o.identity] = r } }
        var roleNames: [String: String] = [:]
        for entry in roles ?? [] {
            roleOf[entry.identity] = entry.role
            if let n = entry.name { roleNames[entry.identity] = n }
        }
        func roleWord(_ identity: String, admin: Bool = false) -> String {
            switch roleOf[identity] {
            case .operator: "operator"
            case .voice: "voiced"
            case .invited: "invited"
            case .muted: "muted"
            case .banned: "banned"
            case .unknown(let raw): SafeText.clean(raw)
            case nil: admin ? "server admin" : ""
            }
        }
        operators = roleOf.filter { $0.value == .operator }.keys
            .map { Person(identity: $0, label: label($0, state.occupants[$0]?.name ?? roleNames[$0])) }
            .sorted { $0.label.lowercased() < $1.label.lowercased() }

        // Here now: operators first, then by name; you're marked.
        let rank: (String) -> Int = { roleOf[$0] == .operator ? 0 : roleOf[$0] == .voice ? 1 : 2 }
        present = state.occupants.values
            .map { o in
                var note = roleWord(o.identity, admin: o.admin == true)
                if o.identity == me { note = note.isEmpty ? "you" : "you · " + note }
                return Person(identity: o.identity, label: label(o.identity, o.name), note: note)
            }
            .sorted { (rank($0.identity), $0.label.lowercased()) < (rank($1.identity), $1.label.lowercased()) }
        let presentIDs = Set(state.occupants.keys)
        absentRoles = roleOf.keys.filter { !presentIDs.contains($0) }
            .map { Person(identity: $0, label: label($0, roleNames[$0]), note: roleWord($0)) }
            .sorted { $0.note == $1.note ? $0.label.lowercased() < $1.label.lowercased() : $0.note > $1.note }

        // Recently spoke: newest first, once each, not counting anyone listed above.
        var seen = presentIDs.union(roleOf.keys)
        var recent: [Person] = []
        for m in state.orderedMessages.reversed() where !seen.contains(m.author.identity) {
            seen.insert(m.author.identity)
            let ago = m.createdAt.map { Self.ago(now.timeIntervalSince($0)) } ?? ""
            recent.append(Person(identity: m.author.identity, label: label(m.author.identity, m.author.name), note: ago))
        }
        self.recent = recent
        you = Person(identity: me, label: SafeText.clean(labels[me] ?? myName))
        youAre = switch state.role {
        case .operator: "operator"
        case .voice: "voiced"
        case .muted: "muted"
        default: state.occupants[me]?.admin == true ? "server admin" : "member"
        }
        self.signing = signing
        self.isOperator = isOperator
    }

    /// "just now", "5m ago", "3h ago", "2d ago".
    static func ago(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }

    /// "7 days", "24 hours", "90 minutes".
    static func duration(_ seconds: Int) -> String {
        func plural(_ n: Int, _ unit: String) -> String { "\(n) \(unit)\(n == 1 ? "" : "s")" }
        if seconds % 86400 == 0 { return plural(seconds / 86400, "day") }
        if seconds % 3600 == 0 { return plural(seconds / 3600, "hour") }
        if seconds % 60 == 0 { return plural(seconds / 60, "minute") }
        return plural(seconds, "second")
    }
}
