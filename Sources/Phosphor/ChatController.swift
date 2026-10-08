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
    /// Sign messages and edits by default (Phosphor → Sign Messages). A signature proves a
    /// message is yours and untouched, but it also can't be denied later.
    var signByDefault: Bool = UserDefaults.standard.object(forKey: "signMessages") as? Bool ?? true {
        didSet { UserDefaults.standard.set(signByDefault, forKey: "signMessages") }
    }
    /// Message the user has selected with the arrow keys; commands act on it.
    var focus: Int?

    /// Every applied event, by room, so that room's scene can animate.
    var onEvent: ((String, Event) -> Void)?
    /// A room's state was replaced wholesale; its scene should drop its animations.
    var onRoomReloaded: ((String) -> Void)?
    /// Your own message was sent or edited; the reply arrives before (or after) its live
    /// event, and either way the room animates it once.
    var onOwnMessage: ((String, Message, _ edited: Bool) -> Void)?
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
    private var demoName = "you"

    func state(_ room: String) -> RoomState? { demos[room]?.state ?? session?.rooms[room] }
    var state: RoomState? { activeRoom.flatMap(state) }

    /// Operator here (or a server admin), so operator commands are worth suggesting.
    var isOperator: Bool { state?.role == .operator || state?.occupants[me]?.admin == true }

    /// What the help panel shows: everything (⌘/, `/help`) or one topic; nil when closed.
    enum HelpView: Equatable { case all, topic(Help.Topic) }
    var help: HelpView? {
        didSet { if help != nil { showingRoomInfo = false } }
    }

    /// The room info walls (/room, ⌘I): the room's settings, and beside it its people.
    /// Only one wall view at a time: it replaces help.
    var showingRoomInfo = false {
        didSet {
            guard showingRoomInfo else { return }
            help = nil
            if !oldValue { infoPage = 0; selectedPerson = nil }
            if let activeRoom { refreshRoles(activeRoom) }
        }
    }
    /// 0: the room, 1: its people.
    var infoPage = 0

    /// ←→ on the info walls.
    func pageInfo(_ delta: Int) { infoPage = max(0, min(1, infoPage + delta)) }

    /// The person picked with ↑↓ on the people wall: their full fingerprint shows, and
    /// ⌘C copies it.
    var selectedPerson: String?

    func movePersonSelection(_ delta: Int) {
        guard let people = roomInfo?.everyone, !people.isEmpty else { return }
        let i = people.firstIndex { $0.identity == selectedPerson }.map { $0 + delta } ?? (delta > 0 ? 0 : people.count - 1)
        selectedPerson = people.indices.contains(i) ? people[i].identity : nil
        if let selectedPerson { lookUp([selectedPerson]) }        // for their status
    }

    /// The fingerprint ⌘C copies with the info walls up: the selected person's, else the room's.
    var fingerprintToCopy: String? {
        guard showingRoomInfo, let info = roomInfo else { return nil }
        if infoPage == 1, let selectedPerson { return selectedPerson }
        return info.roomID
    }

    /// Names and statuses looked up by fingerprint (GET /v1/identities), kept for the session.
    private var identities: [String: IdentityInfo] = [:]
    private var lookingUp: Set<String> = []

    private func lookUp(_ fingerprints: [String]) {
        guard demoMe == nil, let client = session?.client else { return }
        for fp in fingerprints where identities[fp] == nil && !lookingUp.contains(fp) {
            lookingUp.insert(fp)
            Task {
                if let info = try? await client.identity(fp) { identities[fp] = info }
                lookingUp.remove(fp)
            }
        }
    }

    /// Each room's role listing, fetched when its info wall opens and when a role changes.
    private var roomRoles: [String: [RoleEntry]] = [:]

    private func refreshRoles(_ room: String) {
        guard demoMe == nil, let client = session?.client else { return }
        Task {
            guard let roles = try? await client.roles(room: room) else { return }
            roomRoles[room] = roles
            // People with a role who aren't here may have no name we know: ask.
            let known = Set(state(room)?.occupants.keys.map { $0 } ?? []).union(state(room)?.orderedMessages.map(\.author.identity) ?? [])
            lookUp(roles.filter { $0.name == nil && !known.contains($0.identity) }.map(\.identity))
        }
    }

    /// What the info walls show for the active room.
    var roomInfo: RoomInfo? {
        guard let state, let activeRoom else { return nil }
        return RoomInfo(state: state, me: me, myName: displayName, signing: signByDefault, isOperator: isOperator,
                        roles: roomRoles[activeRoom] ?? demos[activeRoom]?.roles, identities: identities)
    }

    /// ←→ in help: the next or previous topic, stopping at the ends.
    func pageHelp(_ delta: Int) {
        let topics = Help.Topic.allCases
        let current: Int = if case .topic(let t) = help { topics.firstIndex(of: t) ?? 0 } else { 0 }
        help = .topic(topics[max(0, min(topics.count - 1, current + delta))])
    }
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

    /// Logs in, rejoins last session's rooms, and joins `room` too if one was asked for.
    /// With nothing to rejoin and no room asked for, nothing is joined: the overview opens
    /// so you can pick (being in a listed room is public, so that's your call).
    func start(room: String?, server: URL = OSCClient.defaultServer) {
        self.server = server
        if room == nil, savedRooms.isEmpty {
            browser.open()
            note(.info, "pick a room to join, or type a name · esc to close")
        }
        startTask?.cancel()
        startTask = Task {
            do {
                let url = identityURL
                // Phosphor's own identity is created on first use; one you chose must exist.
                let (identity, file) = url == IdentityFile.defaultURL
                    ? try IdentityFile.loadOrCreate(at: url)
                    : try Self.loadChosenIdentity(url)
                let client = OSCClient(baseURL: server, identity: identity, displayName: file.name, client: Self.clientInfo)
                let session = ChatSession(client: client)
                session.onUpdate = { [weak self] in self?.handle($0) }
                self.session = session
                displayName = file.name ?? "anon"
                note(.info, "connecting as \(identity.fingerprint.prefix(8))…")
                // Keep trying if the server can't be reached (offline at launch, say).
                var wait: Double = 2
                while true {
                    do {
                        try await session.start()
                        break
                    } catch let error as OSCError {
                        throw error                     // the server answered and said no
                    } catch {
                        note(.error, "can't reach \(server.host ?? "the server") (\(Self.brief(error))); retrying in \(Int(wait))s")
                        try await Task.sleep(for: .seconds(wait))
                        wait = min(wait * 2, 30)
                    }
                }
                displayName = await client.displayName ?? displayName
                await chooseNameIfUnset(fingerprint: identity.fingerprint)
                try Task.checkCancellation()

                let saved = savedRooms
                let lastActive = UserDefaults.standard.string(forKey: "activeRoom")
                for room in saved {
                    // Keyed rooms rejoin with the key from the keychain; if there's none, or it
                    // no longer works, the overview asks for it instead of failing.
                    let key = RoomKeychain.key(for: room.id)
                    let target = RoomBrowser.Target(name: room.name, id: room.id)
                    switch await join(room.name, key: key, activate: room.id == lastActive || activeRoom == nil,
                                      pinnedTo: room.id, askForKey: true) {
                    case .needsKey:
                        if key != nil { RoomKeychain.remove(for: room.id) }
                        browser.ask(.key(target, wrong: key != nil))
                    case .needsInvite:
                        browser.ask(.invite(target, wrong: false))
                    case .joined, .failed:
                        break
                    }
                }
                if let room { await join(room) }
                if browser.isOpen { await refreshListing(maxAge: 0, pages: 3) }

                // Keep the room listing fresh. It's public and cacheable for 10 s; once a
                // minute is plenty outside the browser.
                while !Task.isCancelled {
                    await refreshListing()
                    try? await Task.sleep(for: .seconds(60))
                }
            } catch is CancellationError {
            } catch {
                note(.error, "login failed: \(error)")
            }
        }
    }

    // MARK: identity

    private var startTask: Task<Void, Never>?
    private var server = OSCClient.defaultServer

    /// An identity file for this launch only (`--identity path`).
    var launchIdentity: URL?

    /// The identity in use: this launch's, else the one chosen in the menu (remembered),
    /// else Phosphor's own. Chosen files are used in place, never copied.
    var identityURL: URL {
        launchIdentity
            ?? UserDefaults.standard.string(forKey: "identityPath").map { URL(fileURLWithPath: $0) }
            ?? IdentityFile.defaultURL
    }

    private static func loadChosenIdentity(_ url: URL) throws -> (Identity, IdentityFile) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ChooseIdentityError(message: "no identity file at \(url.path)")
        }
        let file = try IdentityFile.read(from: url)
        return (try file.load(), file)
    }

    private struct ChooseIdentityError: Error, CustomStringConvertible {
        var message: String
        var description: String { message }
    }

    // MARK: display name

    private var nameWaiter: CheckedContinuation<String?, Never>?

    /// Identities that chose to stay anon (Esc at the name prompt), so they aren't asked again.
    private static let staysAnonKey = "staysAnon"

    /// The server calls you `anon` until you pick a name, so a new identity is asked for one
    /// before it joins anything.
    private func chooseNameIfUnset(fingerprint: String) async {
        guard displayName.isEmpty || displayName == DisplayName.unset,
              !(UserDefaults.standard.stringArray(forKey: Self.staysAnonKey) ?? []).contains(fingerprint) else { return }
        note(.info, "pick a name: it's shown with your messages, and you can change it later with /nick")
        var problem: String?
        while !Task.isCancelled {
            let answer = await withCheckedContinuation { waiter in
                nameWaiter = waiter
                browser.ask(.name(problem: problem))
            }
            guard !Task.isCancelled else { return }
            guard let name = answer else {
                UserDefaults.standard.set((UserDefaults.standard.stringArray(forKey: Self.staysAnonKey) ?? []) + [fingerprint],
                                          forKey: Self.staysAnonKey)
                return note(.info, "staying anon · /nick name to pick one later")
            }
            do {
                try await session?.client.setName(name)
                displayName = name
                rememberName(name)
                return note(.info, "you're \(SafeText.clean(name))")
            } catch let error as OSCError {
                problem = error.message                 // refused: ask again, saying why
            } catch {
                return note(.error, "couldn't set your name (\(Self.brief(error))) · try /nick name")
            }
        }
    }

    /// The browser's answer to the name prompt (nil: Esc, stay anon).
    func answerName(_ name: String?) {
        nameWaiter?.resume(returning: name)
        nameWaiter = nil
    }

    /// Keeps the name as the hint in Phosphor's own identity file, so an exported copy
    /// carries it. Identity files you chose are never written to.
    private func rememberName(_ name: String) {
        guard identityURL == IdentityFile.defaultURL, var file = try? IdentityFile.read(from: identityURL),
              (try? file.load()) != nil else { return }
        file.name = name
        try? file.write(to: identityURL)
    }

    /// Switches to another identity file (nil: Phosphor's own). The file is checked first;
    /// then the current identity logs out (leaving its rooms) and the new one logs in and
    /// rejoins the saved rooms.
    func useIdentity(at url: URL?) {
        if let url {
            do {
                let identity = try Self.loadChosenIdentity(url).0
                note(.info, "switching to \(identity.fingerprint.prefix(8))…")
            } catch {
                return note(.error, "that isn't a usable identity file: \(error)")
            }
            UserDefaults.standard.set(url.path, forKey: "identityPath")
        } else {
            UserDefaults.standard.removeObject(forKey: "identityPath")
        }
        launchIdentity = nil
        guard demoMe == nil else { return note(.info, "the identity is used when not in demo mode") }

        let old = session
        old?.onUpdate = nil
        old?.stop()
        startTask?.cancel()
        answerName(nil)                                 // a name prompt for the old identity
        // Clear the rooms without touching the saved list, which the new identity rejoins.
        let previous = activeRoom
        rooms = []
        activity = [:]
        activeRoom = nil
        focus = nil
        session = nil
        listedAt = nil
        onActiveChanged?(previous, nil)
        Task {
            try? await old?.client.logout()
            start(room: nil, server: server)
        }
    }

    /// A short reason for a network error, not the whole NSError dump.
    private static func brief(_ error: Error) -> String {
        if let url = error as? URLError { return url.localizedDescription.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() }
        return String(String(describing: error).prefix(60))
    }

    /// `paceScale` below 1 makes every room chattier.
    func startDemo(speakers: Int, name: String, paceScale: Double = 1) {
        let me = Identity.generate().fingerprint
        demoMe = me
        demoName = name
        displayName = name
        // #dev is the busy room with a long past (the tours end by flying up through it).
        let specs: [(String, String, Int, ClosedRange<Int>, Int)] = [
            ("lobby", "say hi · messages last 7 days", speakers, 1600...3600, 20),
            ("dev", "building OneShotChat clients", 6, 900...2200, 50),
            ("clients", "show and tell: new clients", 3, 4000...9000, 8),
            ("offtopic", "everything else", 1, 9000...20000, 8),
        ]
        for (name, topic, speakers, pace, history) in specs {
            let scaled = Int(Double(pace.lowerBound) * paceScale)...Int(Double(pace.upperBound) * paceScale)
            let feed = DemoFeed(name: name, topic: topic, me: me, myName: self.demoName, speakers: speakers, pace: scaled,
                                history: history)
            feed.onEvent = { [weak self, id = feed.roomID] in self?.handle(.event(room: id, $0)) }
            feed.onSent = { [weak self, id = feed.roomID] in self?.onOwnMessage?(id, $0, false) }
            demos[feed.roomID] = feed
            rooms.append(feed.roomID)
            feed.start()
        }
        activate(rooms[0])
        listed = DemoFeed.listing()
        note(.info, "demo mode · offline")
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

    /// Leaves a room (⌘W or /leave): the server is told, the room drops out of the layout
    /// and the next one along becomes active. Leaving is per room; your roles are kept.
    func leave(_ room: String) {
        guard rooms.contains(room) else { return }
        let name = state(room)?.room.name ?? "?"
        if let demo = demos[room] {
            demo.stop()
            demos[room] = nil
            removeRoom(room)
            note(.info, "left #\(name)")
            return
        }
        Task {
            do {
                try await session?.leave(room)      // reports .left, which removes the room
            } catch {
                note(.error, "couldn't leave #\(name): \(error)")
            }
        }
    }

    func leaveActive() {
        if let activeRoom { leave(activeRoom) }
    }

    /// ⌘1…⌘9 (zero-based here).
    /// Demo: the room at `index` mentions you / someone reacts to your latest there.
    func demoMention(roomIndex: Int) {
        if rooms.indices.contains(roomIndex) { demos[rooms[roomIndex]]?.mentionYou() }
    }

    func demoReactToMine(_ reaction: String = "🔥") {
        if let activeRoom { demos[activeRoom]?.reactToYours(reaction) }
    }

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
    enum JoinOutcome {
        case joined, needsKey, needsInvite, failed
    }

    /// A join started in the browser: the outcome tells it whether to close or ask for a
    /// key or invite code (which it does itself, so those aren't reported as errors).
    func joinFromBrowser(_ target: RoomBrowser.Target, key: String?, invite: String?) async -> JoinOutcome {
        if demoMe != nil {
            guard let room = listed.first(where: { $0.name == target.name }) else {
                note(.info, "the demo only has its listed rooms")
                return .failed
            }
            if room.access == "key", (key ?? "").isEmpty { return .needsKey }
            if room.access == "invite", (invite ?? "").isEmpty { return .needsInvite }
            joinDemo(room)
            return .joined
        }
        return await join(target.name, key: key, invite: invite, pinnedTo: target.id, askForKey: true)
    }

    /// In the demo, a listed room becomes another scripted feed (any key or code works).
    private func joinDemo(_ room: Room) {
        guard let me = demoMe else { return }
        let feed = DemoFeed(name: room.name, topic: room.topic ?? "", me: me, myName: demoName, speakers: 2, pace: 3000...8000)
        feed.onEvent = { [weak self, id = feed.roomID] in self?.handle(.event(room: id, $0)) }
        feed.onSent = { [weak self, id = feed.roomID] in self?.onOwnMessage?(id, $0, false) }
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
        let (head, rest) = split(line)
        if head == "/help" {
            let word = rest.trimmingCharacters(in: .whitespaces).lowercased()
            if word.isEmpty { return help = .all }
            guard let topic = Help.Topic(rawValue: word) ?? (word == "operators" ? .mod : nil) else {
                return note(.error, "no help on \(word) · try /help chat, rooms, mod or keys")
            }
            return help = .topic(topic)
        }
        if head == "/room", rest.trimmingCharacters(in: .whitespaces).isEmpty {
            guard state != nil else { return note(.error, "not in a room") }
            return showingRoomInfo = true
        }
        if head == "/leave" || head == "/part" {
            let name = rest.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
            let target = name.isEmpty ? activeRoom : rooms.first { state($0)?.room.name == name }
            guard let target else { return note(.error, "not in #\(name)") }
            return leave(target)
        }
        if demoMe != nil {
            switch head {
            case "/nick":
                if let problem = DisplayName.problem(rest) { return note(.error, problem) }
                displayName = rest
                return note(.info, "you're \(rest) (in the demo)")
            case "/sign", "/unsigned":
                if let activeRoom, !rest.isEmpty { demos[activeRoom]?.input(MentionText.compose(rest, labels: labels)) }
                return
            case "/react", "/edit":
                break
            default:
                if head.hasPrefix("/") {
                    let known = Help.commands.contains { $0.name == head }
                    return note(.error, known ? "\(head) needs the server: not in demo mode" : "unknown command \(head); /help")
                }
            }
            if let activeRoom { demos[activeRoom]?.input(MentionText.compose(line, labels: labels)) }
            return
        }
        Task {
            do {
                switch head {
                case "/unsigned":
                    try await send(rest, labels: labels, sign: false)
                case "/sign":
                    try await send(rest, labels: labels, sign: true)
                case "/edit", "/sedit":
                    let (target, text) = targetMessage(rest, mine: true)
                    guard let target else { return note(.error, "no message of yours to edit") }
                    if let edited = try await session?.edit(target, to: MentionText.compose(text, labels: labels), sign: head == "/sedit" || signByDefault) {
                        onOwnMessage?(edited.room, edited, true)
                    }
                case "/react", "/unreact":
                    let (target, reaction) = targetMessage(rest, mine: false)
                    guard let target, !reaction.isEmpty else { return note(.error, "usage: /react [id] 👍") }
                    if head == "/react" { try await session?.react(reaction, to: target) } else { try await session?.unreact(reaction, from: target) }
                case "/join":
                    // /join room [key]  or  /join room invite <code>
                    let (name, more) = split(rest.trimmingCharacters(in: .whitespaces))
                    let room = name.trimmingCharacters(in: CharacterSet(charactersIn: "#")).lowercased()
                    let (word, code) = split(more)
                    if word == "invite", !code.isEmpty {
                        await join(room, invite: code)
                    } else {
                        await join(room, key: more.isEmpty ? nil : more)
                    }
                case "/room":
                    try await roomCommand(rest)
                case "/topic":
                    try await updateActiveRoom(RoomUpdate(topic: rest), done: rest.isEmpty ? "topic cleared" : "topic set")
                case "/invite":
                    guard let activeRoom else { return note(.error, "not in a room") }
                    let invite = try await session?.client.createInvite(room: activeRoom, uses: Int(rest) ?? 1)
                    if let invite {
                        note(.info, "invite code: \(invite.code)  (\(invite.usesLeft ?? 1) use\(invite.usesLeft == 1 ? "" : "s"), 24 h) · they join with /join \(state?.room.name ?? "room") invite \(invite.code)")
                    }
                case "/op", "/deop", "/voice", "/devoice", "/mute", "/unmute", "/ban", "/unban", "/allow", "/kick":
                    try await memberCommand(head, rest, labels: labels)
                case "/nick":
                    if let problem = DisplayName.problem(rest) { return note(.error, problem) }
                    try await session?.client.setName(rest)
                    displayName = rest
                    rememberName(rest)
                default:
                    if head.hasPrefix("/") { note(.error, "unknown command \(head); /help") } else { try await send(line, labels: labels, sign: signByDefault) }
                }
            } catch let error as OSCError {
                note(.error, "\(error.code): \(error.message)")
            } catch {
                note(.error, "\(error)")
            }
        }
    }

    // MARK: operator commands

    /// `/room` shows the active room's settings; `/room <setting>…` changes them, e.g.
    /// `/room unlisted`, `/room key hunter2`, `/room invite`, `/room moderated`,
    /// `/room retention 24h` (or `forever`). Several can go in one command.
    private func roomCommand(_ args: String) async throws {
        guard state != nil else { return note(.error, "not in a room") }
        let words = args.split(separator: " ").map(String.init)
        if words.isEmpty { return showingRoomInfo = true }
        var update = RoomUpdate()
        var i = 0
        while i < words.count {
            switch words[i] {
            case "listed", "unlisted": update.visibility = words[i]
            case "open": update.access = "open"
            case "invite": update.access = "invite"
            case "key":
                guard i + 1 < words.count else { return note(.error, "usage: /room key <key>") }
                update.access = "key"
                update.key = words[i + 1]
                i += 1
            case "moderated": update.speaking = "moderated"
            case "unmoderated": update.speaking = "open"
            case "retention":
                guard i + 1 < words.count else { return note(.error, "usage: /room retention 24h|7d|forever") }
                if words[i + 1] == "forever" { update.retention = .forever } else {
                    guard let seconds = Self.parseDuration(words[i + 1]) else { return note(.error, "retention like 1h, 24h, 7d or forever") }
                    update.retention = .seconds(seconds)
                }
                i += 1
            default:
                return note(.error, "unknown room setting '\(words[i])'; /room for the list")
            }
            i += 1
        }
        try await updateActiveRoom(update, done: "room updated")
        showingRoomInfo = true                          // the wall shows the result, and glows what changed
    }

    private func updateActiveRoom(_ update: RoomUpdate, done: String) async throws {
        guard let activeRoom, let session else { return note(.error, "not in a room") }
        try await session.updateRoom(activeRoom, update)
        if let key = update.key { RoomKeychain.save(key, for: activeRoom) }
        if update.access == "open" { RoomKeychain.remove(for: activeRoom) }
        note(.info, done)
    }

    /// Roles and kicks for someone in view: `/op @sam#a7`, `/kick @sam spamming`.
    private func memberCommand(_ head: String, _ args: String, labels: [String: String]) async throws {
        guard let activeRoom, let client = session?.client else { return note(.error, "not in a room") }
        let (who, reason) = split(args.trimmingCharacters(in: .whitespaces))
        let label = who.hasPrefix("@") ? String(who.dropFirst()) : who
        guard let fp = labels[label] ?? (Identity.isFingerprint(label) ? label : nil) else {
            return note(.error, "no one called @\(label) here (type @ to pick someone)")
        }
        switch head {
        case "/op": try await client.setRole(room: activeRoom, identity: fp, role: "operator")
        case "/voice": try await client.setRole(room: activeRoom, identity: fp, role: "voice")
        case "/mute": try await client.setRole(room: activeRoom, identity: fp, role: "muted")
        case "/ban": try await client.setRole(room: activeRoom, identity: fp, role: "banned")
        case "/allow": try await client.setRole(room: activeRoom, identity: fp, role: "invited")
        case "/kick": try await client.kick(room: activeRoom, identity: fp, reason: reason.isEmpty ? nil : reason)
        default: try await client.clearRole(room: activeRoom, identity: fp)     // deop, devoice, unmute, unban
        }
        note(.info, "\(head.dropFirst()) @\(label): done")
    }

    static func parseDuration(_ s: String) -> Int? {
        guard let unit = s.last, let n = Int(s.dropLast()) else { return Int(s) }
        switch unit {
        case "h": return n * 3600
        case "d": return n * 86400
        case "w": return n * 604800
        default: return nil
        }
    }

    static func duration(_ seconds: Int) -> String {
        seconds % 86400 == 0 ? "\(seconds / 86400)d" : seconds % 3600 == 0 ? "\(seconds / 3600)h" : "\(seconds)s"
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
        if let sent = try await session?.send(MentionText.compose(text, labels: labels), to: activeRoom, sign: sign) {
            onOwnMessage?(activeRoom, sent, false)
        }
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
    /// `askForKey`: the caller will ask for a missing or wrong key / invite code itself.
    @discardableResult
    private func join(_ name: String, key: String? = nil, invite: String? = nil, activate: Bool = true, pinnedTo: String? = nil,
                      askForKey: Bool = false) async -> JoinOutcome {
        guard let session, !name.isEmpty else { return .failed }
        if let existing = rooms.first(where: { state($0)?.room.name == name }) {
            if activate { self.activate(existing) }
            return .joined
        }
        do {
            let state: RoomState
            do {
                state = try await session.join(name, expect: pinnedTo ?? knownRooms[name], key: key, invite: invite)
            } catch let error as OSCError where error.code == "room_changed" {
                if pinnedTo != nil {
                    note(.error, "#\(name) now belongs to a different room (yours expired). /join \(name) to join the new one.")
                    savedRooms.removeAll { $0.name == name }
                    return .failed
                }
                note(.error, "#\(name) is a different room than the one you were in before (the old one expired). Joined the new one.")
                state = try await session.join(name, key: key, invite: invite)
            }
            knownRooms[name] = state.id
            if let key { RoomKeychain.save(key, for: state.id) }
            if !rooms.contains(state.id) { rooms.append(state.id) }
            if activate || activeRoom == nil { self.activate(state.id) }
            persist()
            note(.info, "joined #\(state.room.name)")
            return .joined
        } catch let error as OSCError where error.code == "key_required" {
            if key != nil { note(.error, "wrong key for #\(name) (too many wrong tries locks the room's key joins for a while)") }
            else if !askForKey { note(.error, "#\(name) needs a room key: /join \(name) <key>") }
            return .needsKey
        } catch let error as OSCError where error.code == "invite_required" {
            if invite != nil { note(.error, "that invite code didn't work for #\(name)") }
            else if !askForKey { note(.error, "#\(name) is invite-only: /join \(name) invite <code>") }
            return .needsInvite
        } catch let error as OSCError {
            note(.error, "join #\(name): \(error.code)")
            return .failed
        } catch {
            note(.error, "join #\(name): \(error)")
            return .failed
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
            if case .memberRoleChanged = event.payload, roomRoles[room] != nil { refreshRoles(room) }
            onEvent?(room, event)
        case .reloaded(let room):
            onRoomReloaded?(room)
        case .left(let room, let name, let reason, let detail):
            // A room you left or were banned from won't be rejoined: forget its key.
            if reason == "left" || reason == "banned" { RoomKeychain.remove(for: room) }
            let detail = detail.map { ": \($0)" } ?? ""
            switch reason {
            case "left": note(.info, "left #\(name)")
            case "kicked": note(.error, "you were kicked from #\(name)\(detail)")
            case "banned": note(.error, "you were banned from #\(name)\(detail)")
            case "rejoin_failed": note(.error, "lost #\(name), couldn't rejoin\(detail)")
            default: note(.error, "left #\(name) (\(reason))\(detail)")
            }
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
