import Foundation
import OSCCore
import QuartzCore

/// Seconds since launch; the one clock shared by animations and the renderer.
enum AppClock {
    private static let start = CACurrentMediaTime()
    static var now: Float { Float(CACurrentMediaTime() - start) }
}

/// The app's side of the chat: owns the session and the set of joined rooms (one of them
/// active), runs commands from the input line, tracks unread and mentions for the rooms
/// in the background, and keeps a short list of notices for the HUD.
@MainActor
final class ChatController {
    struct Notice {
        enum Kind { case info, error, server, mention }
        var kind: Kind
        var text: String
        var at: Float
    }

    struct Activity {
        var unread = 0
        var mentioned = false
    }

    static let clientInfo = ClientInfo(name: "phosphor", version: "0.1.0")

    private(set) var session: ChatSession?
    /// Joined rooms in order; ⌘1 is the first.
    private(set) var rooms: [String] = []
    private(set) var activeRoom: String?
    private(set) var activity: [String: Activity] = [:]
    private(set) var notices: [Notice] = []
    private(set) var displayName = "anon"
    /// Message the user has selected with the arrow keys; commands act on it.
    var focus: Int?

    /// Every applied event, by room, so that room's scene can animate.
    var onEvent: ((String, Event) -> Void)?
    /// A room's state was replaced wholesale; its scene should drop its animations.
    var onRoomReloaded: ((String) -> Void)?
    /// The active room changed (old, new).
    var onActiveChanged: ((String?, String?) -> Void)?

    private(set) lazy var browser = RoomBrowser(controller: self)

    /// Every listed room from the public room browser, busiest first.
    private(set) var listed: [Room] = []
    private var listedAt: Date?
    /// Listed rooms you haven't joined.
    var unjoinedListed: [Room] { listed.filter { !rooms.contains($0.id) } }

    /// Offline scripted rooms (`--demo`); when present they replace the session entirely.
    private var demos: [String: DemoFeed] = [:]
    private var demoMe: String?

    func state(_ room: String) -> RoomState? { demos[room]?.state ?? session?.rooms[room] }
    var state: RoomState? { activeRoom.flatMap(state) }
    var me: String { demoMe ?? session?.me ?? "" }
    var origin: String { session?.client.origin ?? "" }
    var connection: EventSocket.Status { demoMe != nil ? .connected : session?.connection ?? .connecting }

    // MARK: persistence

    private struct SavedRoom: Codable {
        var name: String
        var id: String
    }

    /// Rooms to rejoin at launch, pinned to their fingerprints.
    private var savedRooms: [SavedRoom] {
        get { (UserDefaults.standard.data(forKey: "joinedRooms")).flatMap { try? JSONDecoder().decode([SavedRoom].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "joinedRooms") }
    }

    /// Fingerprints of rooms we've been in, by name, to spot a name taken over by a new room.
    private var knownRooms: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "knownRooms") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "knownRooms") }
    }

    private func persist() {
        guard demoMe == nil else { return }
        savedRooms = rooms.compactMap { id in state(id).map { SavedRoom(name: $0.room.name, id: id) } }
        UserDefaults.standard.set(activeRoom, forKey: "activeRoom")
    }

    // MARK: start

    /// Logs in, rejoins last session's rooms, and joins `room` too if one was asked for
    /// (or #lobby when there's nothing to rejoin).
    func start(room: String?, server: URL = OSCClient.defaultServer) {
        Task {
            do {
                let (identity, file) = try IdentityFile.loadOrCreate(at: IdentityFile.defaultURL)
                let client = OSCClient(baseURL: server, identity: identity, displayName: file.name, client: Self.clientInfo)
                let session = ChatSession(client: client)
                session.onUpdate = { [weak self] in self?.handle($0) }
                self.session = session
                note(.info, "connecting as \(identity.fingerprint.prefix(8))…")
                try await session.start()
                displayName = await client.displayName ?? "anon"

                let saved = savedRooms
                let lastActive = UserDefaults.standard.string(forKey: "activeRoom")
                for room in saved {
                    await join(room.name, activate: room.id == lastActive || activeRoom == nil, pinnedTo: room.id)
                }
                if let room { await join(room) } else if rooms.isEmpty { await join("lobby") }

                // Keep the room listing fresh. It's public and cacheable for 10 s; once a
                // minute is plenty outside the browser.
                while !Task.isCancelled {
                    await refreshListing()
                    try? await Task.sleep(for: .seconds(60))
                }
            } catch {
                note(.error, "login failed: \(error)")
            }
        }
    }

    func startDemo(speakers: Int) {
        let me = Identity.generate().fingerprint
        demoMe = me
        displayName = "you"
        let specs: [(String, String, Int, ClosedRange<Int>)] = [
            ("demo", "offline demo · nothing here is real", speakers, 1400...3200),
            ("dev", "a busy room", 6, 700...1800),
            ("art", "a slow room", 2, 5000...11000),
            ("music", "an even slower room", 1, 9000...20000),
        ]
        for (name, topic, speakers, pace) in specs {
            let feed = DemoFeed(name: name, topic: topic, me: me, speakers: speakers, pace: pace)
            feed.onEvent = { [weak self, id = feed.roomID] in self?.handle(.event(room: id, $0)) }
            demos[feed.roomID] = feed
            rooms.append(feed.roomID)
            feed.start()
        }
        activate(rooms[0])
        listed = DemoFeed.listing()
        note(.info, "offline demo rooms: nothing is sent anywhere")
    }

    // MARK: rooms

    func activate(_ room: String) {
        guard rooms.contains(room), room != activeRoom else { return }
        let old = activeRoom
        activeRoom = room
        activity[room] = Activity()
        focus = nil
        persist()
        onActiveChanged?(old, room)
    }

    /// ⌘1…⌘9 (zero-based here).
    func activate(index: Int) {
        if rooms.indices.contains(index) { activate(rooms[index]) }
    }

    /// ⌘← / ⌘→, wrapping around.
    func cycle(_ delta: Int) {
        guard !rooms.isEmpty else { return }
        let i = activeRoom.flatMap { rooms.firstIndex(of: $0) } ?? 0
        activate(rooms[(i + delta + rooms.count) % rooms.count])
    }

    // MARK: room browser

    /// Fetches the public listing (`GET /v1/rooms`, no login, no presence) unless it's
    /// fresher than `maxAge`. Up to `pages` pages; the browser asks for more than the
    /// background refresh does.
    func refreshListing(maxAge: TimeInterval = 10, pages: Int = 1) async {
        guard demoMe == nil, let client = session?.client else { return }
        if let listedAt, -listedAt.timeIntervalSinceNow < maxAge { return }
        do {
            var all: [Room] = []
            var cursor: String?
            for _ in 0..<pages {
                let page = try await client.rooms(cursor: cursor)
                all += page.rooms
                cursor = page.next
                if cursor == nil { break }
            }
            listed = all
            listedAt = Date()
        } catch {
            note(.error, "couldn't load the room list: \(error)")
        }
    }

    /// Joins a room picked in the browser, pinned to the fingerprint we saw listed so a
    /// name that changed hands in the meantime isn't joined by mistake.
    func join(listed room: Room, key: String? = nil, invite: String? = nil) {
        if demoMe != nil { return joinDemo(room, key: key, invite: invite) }
        Task { await join(room.name, key: key, invite: invite, pinnedTo: room.id) }
    }

    /// Joins (or creates) a room by name, e.g. an unlisted one.
    func join(named name: String) {
        if demoMe != nil {
            note(.info, "the demo only has its listed rooms")
            return
        }
        Task { await join(name) }
    }

    /// In the demo, a listed room becomes another scripted feed (any key or code works).
    private func joinDemo(_ room: Room, key: String?, invite: String?) {
        guard let me = demoMe else { return }
        if room.access == "key", (key ?? "").isEmpty { return note(.error, "#\(room.name) needs a room key") }
        if room.access == "invite", (invite ?? "").isEmpty { return note(.error, "#\(room.name) is invite-only") }
        let feed = DemoFeed(name: room.name, topic: room.topic ?? "", me: me, speakers: 2, pace: 3000...8000)
        feed.onEvent = { [weak self, id = feed.roomID] in self?.handle(.event(room: id, $0)) }
        demos[feed.roomID] = feed
        if !rooms.contains(feed.roomID) { rooms.append(feed.roomID) }
        feed.start()
        activate(feed.roomID)
        note(.info, "joined #\(room.name)")
    }

    // MARK: input

    /// The input line's Enter. Plain text goes to the active room; `/commands` act on the
    /// focused message.
    func submit(_ raw: String, labels: [String: String]) {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        if demoMe != nil {
            if let activeRoom { demos[activeRoom]?.input(MentionText.compose(line, labels: labels)) }
            return
        }
        let (head, rest) = split(line)
        Task {
            do {
                switch head {
                case "/help":
                    note(.info, "/sign text · /edit [id] text · /react [id] 👍 · /unreact · /join room [key] · /leave · /nick name · ⌘←→ ⌘1-9 rooms · ↑↓ select · ⌘R read · ⌘G ring/row")
                case "/sign":
                    try await send(rest, labels: labels, sign: true)
                case "/edit", "/sedit":
                    let (target, text) = targetMessage(rest, mine: true)
                    guard let target else { return note(.error, "no message of yours to edit") }
                    try await session?.edit(target, to: MentionText.compose(text, labels: labels), sign: head == "/sedit")
                case "/react", "/unreact":
                    let (target, reaction) = targetMessage(rest, mine: false)
                    guard let target, !reaction.isEmpty else { return note(.error, "usage: /react [id] 👍") }
                    if head == "/react" { try await session?.react(reaction, to: target) } else { try await session?.unreact(reaction, from: target) }
                case "/join":
                    let (name, key) = split(rest.trimmingCharacters(in: .whitespaces))
                    await join(name.trimmingCharacters(in: CharacterSet(charactersIn: "#")).lowercased(), key: key.isEmpty ? nil : key)
                case "/leave", "/part":
                    let name = rest.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
                    let target = name.isEmpty ? activeRoom : rooms.first { state($0)?.room.name == name }
                    guard let target else { return note(.error, "not in #\(name)") }
                    try await session?.leave(target)
                case "/nick":
                    try await session?.client.setName(rest)
                    displayName = rest
                default:
                    if head.hasPrefix("/") { note(.error, "unknown command \(head); /help") } else { try await send(line, labels: labels, sign: false) }
                }
            } catch let error as OSCError {
                note(.error, "\(error.code): \(error.message)")
            } catch {
                note(.error, "\(error)")
            }
        }
    }

    /// Moves the selection through messages: older (-1) or newer (+1); nil clears.
    func moveFocus(_ direction: Int?) {
        guard let direction, let ids = state?.orderedMessages.map(\.id), !ids.isEmpty else {
            focus = nil
            return
        }
        guard let focus, let i = ids.firstIndex(of: focus) else {
            self.focus = direction < 0 ? ids.last : nil
            return
        }
        let next = i + direction
        self.focus = next >= ids.count ? nil : ids[max(0, next)]
    }

    private var loadingOlder = false
    private var historyExhausted: Set<String> = []

    /// Fetches the page before the active room's oldest loaded message, once at a time.
    func loadOlder() {
        guard demoMe == nil, !loadingOlder, let session, let room = activeRoom, !historyExhausted.contains(room) else { return }
        loadingOlder = true
        Task {
            defer { loadingOlder = false }
            do {
                if try await !session.loadOlder(room) { historyExhausted.insert(room) }
            } catch {
                historyExhausted.insert(room)
                note(.error, "couldn't load older messages: \(error)")
            }
        }
    }

    // MARK: private

    private func send(_ text: String, labels: [String: String], sign: Bool) async throws {
        guard let activeRoom else { return note(.error, "not in a room") }
        try await session?.send(MentionText.compose(text, labels: labels), to: activeRoom, sign: sign)
    }

    /// `[id] rest`: an explicit message id if the first word is one, else the focused
    /// message, else the latest (of mine, for edits).
    private func targetMessage(_ args: String, mine: Bool) -> (Message?, String) {
        let (first, rest) = split(args)
        if let id = Int(first), let m = state?.messages[id] { return (m, rest) }
        if let focus, let m = state?.messages[focus], !mine || m.author.identity == me { return (m, args) }
        let candidates = state?.orderedMessages.filter { !mine || $0.author.identity == me } ?? []
        return (candidates.last, args)
    }

    /// Joins (or, if already joined, just activates). `pinnedTo` is a remembered
    /// fingerprint from a previous launch: if the name now belongs to a different room,
    /// we say so and don't join the stranger's room.
    private func join(_ name: String, key: String? = nil, invite: String? = nil, activate: Bool = true, pinnedTo: String? = nil) async {
        guard let session, !name.isEmpty else { return }
        if let existing = rooms.first(where: { state($0)?.room.name == name }) {
            if activate { self.activate(existing) }
            return
        }
        do {
            let state: RoomState
            do {
                state = try await session.join(name, expect: pinnedTo ?? knownRooms[name], key: key, invite: invite)
            } catch let error as OSCError where error.code == "room_changed" {
                if pinnedTo != nil {
                    note(.error, "#\(name) now belongs to a different room (yours expired). /join \(name) to join the new one.")
                    savedRooms.removeAll { $0.name == name }
                    return
                }
                note(.error, "#\(name) is a different room than the one you were in before (the old one expired). Joined the new one.")
                state = try await session.join(name, key: key, invite: invite)
            }
            knownRooms[name] = state.id
            if !rooms.contains(state.id) { rooms.append(state.id) }
            if activate || activeRoom == nil { self.activate(state.id) }
            persist()
            note(.info, "joined #\(state.room.name)")
        } catch let error as OSCError where error.code == "key_required" {
            note(.error, key == nil ? "#\(name) needs a room key: /join \(name) <key>"
                                    : "wrong key for #\(name) (too many wrong tries locks the room's key joins for a while)")
        } catch let error as OSCError where error.code == "invite_required" {
            note(.error, invite == nil ? "#\(name) is invite-only" : "that invite code didn't work for #\(name)")
        } catch let error as OSCError {
            note(.error, "join #\(name): \(error.code)")
        } catch {
            note(.error, "join #\(name): \(error)")
        }
    }

    private func removeRoom(_ room: String) {
        guard let i = rooms.firstIndex(of: room) else { return }
        rooms.remove(at: i)
        activity[room] = nil
        if activeRoom == room {
            let old = activeRoom
            activeRoom = rooms.isEmpty ? nil : rooms[min(i, rooms.count - 1)]
            focus = nil
            onActiveChanged?(old, activeRoom)
        }
        persist()
    }

    private func handle(_ update: ChatSession.Update) {
        switch update {
        case .event(let room, let event):
            if room != activeRoom, case .messageCreated(let m) = event.payload, m.author.identity != me {
                activity[room, default: Activity()].unread += 1
                if m.mentions?.contains(me) == true { activity[room, default: Activity()].mentioned = true }
            }
            onEvent?(room, event)
        case .reloaded(let room):
            onRoomReloaded?(room)
        case .left(let room, let reason):
            note(reason == "left" ? .info : .error, "left #\(state(room)?.room.name ?? "?"): \(reason)")
            removeRoom(room)
        case .mention(let item) where !rooms.contains(item.room.id):
            note(.mention, "\(item.message.author.name) mentioned you in #\(item.room.name)")
        case .notice(_, let notice):
            // Only these come from the server itself; everything else is user content.
            note(.server, "SERVER \(notice.code): \(notice.text)")
        case .connection(.disconnected(let reason)):
            note(.error, "disconnected (\(reason.prefix(60))); reconnecting")
        case .error(let message):
            note(.error, message)
        default:
            break
        }
    }

    func note(_ kind: Notice.Kind, _ text: String) {
        notices.append(Notice(kind: kind, text: SafeText.clean(text), at: AppClock.now))
        if notices.count > 6 { notices.removeFirst(notices.count - 6) }
    }

    private func split(_ s: String) -> (String, String) {
        guard let space = s.firstIndex(of: " ") else { return (s, "") }
        return (String(s[..<space]), String(s[s.index(after: space)...]))
    }
}
