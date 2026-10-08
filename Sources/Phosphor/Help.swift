/// Every command and key, in one place: the `/` suggestions, the usage line while typing a
/// command, and the help panel (⌘/ or `/help`) are all drawn from these lists.
enum Help {
    enum Topic: String, CaseIterable {
        case chat, rooms, mod, keys

        var title: String {
            switch self {
            case .chat: "CHAT"
            case .rooms: "ROOMS"
            case .mod: "OPERATORS"
            case .keys: "KEYS"
            }
        }
    }

    struct Command {
        let name: String
        let args: String
        let summary: String
        let topic: Topic
        var usage: String { args.isEmpty ? name : "\(name) \(args)" }
    }

    /// In the order they're suggested and listed. A name can appear more than once for
    /// different forms (`/join` with a key or an invite code).
    static let commands: [Command] = [
        Command(name: "/join", args: "room [key]", summary: "join a room, or create it", topic: .rooms),
        Command(name: "/join", args: "room invite code", summary: "join with an invite code", topic: .rooms),
        Command(name: "/leave", args: "[room]", summary: "leave this room, or the one named", topic: .rooms),
        Command(name: "/room", args: "", summary: "this room's settings and people (⌘I)", topic: .rooms),
        Command(name: "/help", args: "[topic]", summary: "this help (⌘/) · topics: chat, rooms, mod, keys", topic: .rooms),

        Command(name: "/nick", args: "name", summary: "change your display name", topic: .chat),
        Command(name: "/react", args: "[id] 👍", summary: "react to the selected or latest message", topic: .chat),
        Command(name: "/unreact", args: "[id] 👍", summary: "take your reaction back", topic: .chat),
        Command(name: "/edit", args: "[id] text", summary: "edit your selected or latest message", topic: .chat),
        Command(name: "/sedit", args: "[id] text", summary: "edit it, signed", topic: .chat),
        Command(name: "/sign", args: "text", summary: "send one message signed", topic: .chat),
        Command(name: "/unsigned", args: "text", summary: "send one message unsigned", topic: .chat),

        Command(name: "/topic", args: "[text]", summary: "set the topic (nothing clears it)", topic: .mod),
        Command(name: "/room", args: "settings…", summary: "listed | unlisted · open | key k | invite", topic: .mod),
        Command(name: "/room", args: "settings…", summary: "moderated | unmoderated · retention 24h | 7d | forever", topic: .mod),
        Command(name: "/invite", args: "[uses]", summary: "make an invite code, good for 24 h", topic: .mod),
        Command(name: "/op", args: "@who", summary: "make them an operator", topic: .mod),
        Command(name: "/deop", args: "@who", summary: "take operator away", topic: .mod),
        Command(name: "/voice", args: "@who", summary: "let them speak in a moderated room", topic: .mod),
        Command(name: "/devoice", args: "@who", summary: "take their voice away", topic: .mod),
        Command(name: "/mute", args: "@who", summary: "stop them speaking here", topic: .mod),
        Command(name: "/unmute", args: "@who", summary: "let them speak again", topic: .mod),
        Command(name: "/allow", args: "@who", summary: "let them into an invite-only room", topic: .mod),
        Command(name: "/kick", args: "@who [reason]", summary: "remove them (they can come back)", topic: .mod),
        Command(name: "/ban", args: "@who", summary: "remove them and keep them out", topic: .mod),
        Command(name: "/unban", args: "@who", summary: "let them back in", topic: .mod),
    ]

    static let keys: [(keys: String, action: String)] = [
        ("⏎  ·  ⇧⏎", "send  ·  new line"),
        ("tab", "take the suggestion"),
        ("↑ ↓  ·  esc", "select a message  ·  clear"),
        ("⌘L", "room browser"),
        ("⌘← ⌘→  ·  ⌘1–9", "switch rooms"),
        ("⌘I  ·  ⌘W", "room info  ·  leave room"),
        ("⌘C", "copy a fingerprint, on room info"),
        ("⌘G", "ring or row layout"),
        ("⌘R", "reading mode"),
        ("⌘↓  ·  ⌘0", "latest  ·  reset view"),
        ("⌘T  ·  ⌘E", "colour theme  ·  CRT effects"),
        ("⌃⌘F", "full screen"),
        ("scroll  ·  ⌥ scroll", "fly up and down  ·  closer"),
        ("drag", "look around"),
        ("⌘/", "this help"),
    ]

    /// Command names to suggest, once each, in list order. Operator commands only for
    /// operators, since nobody else can use them.
    static func names(forOperator isOperator: Bool) -> [String] {
        var seen = Set<String>()
        return commands.filter { isOperator || $0.topic != .mod }.compactMap { seen.insert($0.name).inserted ? $0.name : nil }
    }

    /// Every form of the command `name`, for the usage line.
    static func forms(of name: String, forOperator isOperator: Bool) -> [Command] {
        let all = commands.filter { $0.name == name }
        let allowed = all.filter { isOperator || $0.topic != .mod }
        return allowed.isEmpty ? all : allowed
    }
}
