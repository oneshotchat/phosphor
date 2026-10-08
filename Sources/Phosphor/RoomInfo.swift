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
    }

    var name: String
    var topic: String?
    var lifetime: String
    var settings: [Row]
    var here: Int
    var operators: [Person]
    var you: Person
    var youAre: String
    var signing: Bool
    var isOperator: Bool

    init(state: RoomState, me: String, myName: String, signing: Bool, isOperator: Bool) {
        let room = state.room
        name = "#" + SafeText.clean(room.name)
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
        here = state.occupants.count
        operators = state.occupants.values
            .filter { $0.role == .operator }
            .map { Person(identity: $0.identity, label: SafeText.clean(labels[$0.identity] ?? $0.name)) }
            .sorted { $0.label < $1.label }
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

    /// "7 days", "24 hours", "90 minutes".
    static func duration(_ seconds: Int) -> String {
        func plural(_ n: Int, _ unit: String) -> String { "\(n) \(unit)\(n == 1 ? "" : "s")" }
        if seconds % 86400 == 0 { return plural(seconds / 86400, "day") }
        if seconds % 3600 == 0 { return plural(seconds / 3600, "hour") }
        if seconds % 60 == 0 { return plural(seconds / 60, "minute") }
        return plural(seconds, "second")
    }
}
