import Foundation
import OSCCore
import QuartzCore

/// Seconds since launch; the one clock shared by animations and the renderer.
enum AppClock {
    private static let start = CACurrentMediaTime()
    static var now: Float { Float(CACurrentMediaTime() - start) }
}

/// The app's side of the chat: owns the session, runs commands from the input line,
/// and keeps a short list of notices for the HUD. Rendering reads from it each frame.
@MainActor
final class ChatController {
    struct Notice {
        enum Kind { case info, error, server, mention }
        var kind: Kind
        var text: String
        var at: Float
    }

    static let clientInfo = ClientInfo(name: "phosphor", version: "0.1.0")

    private(set) var session: ChatSession?
    private(set) var roomID: String?
    private(set) var notices: [Notice] = []
    private(set) var displayName = "anon"
    /// Message the user has selected with the arrow keys; commands act on it.
    var focus: Int?
    /// Called for every applied event, so the scene can start animations.
    var onEvent: ((Event) -> Void)?
    /// Called when the current room's state is replaced or switched.
    var onRoomChanged: (() -> Void)?

    /// Offline scripted room (`--demo`); when set, it replaces the session entirely.
    private(set) var demo: DemoFeed?

    var state: RoomState? { demo?.state ?? roomID.flatMap { session?.rooms[$0] } }
    var me: String { demo?.me ?? session?.me ?? "" }
    var origin: String { session?.client.origin ?? "" }
    var connection: EventSocket.Status { demo != nil ? .connected : session?.connection ?? .connecting }

    func startDemo(speakers: Int) {
        let feed = DemoFeed(speakers: speakers)
        feed.onEvent = { [weak self] in self?.onEvent?($0) }
        demo = feed
        displayName = "you"
        onRoomChanged?()
        note(.info, "offline demo room: nothing is sent anywhere")
        feed.start()
    }

    /// Fingerprints of rooms we've been in, by name, to spot a name taken over by a new room.
    private var knownRooms: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "knownRooms") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "knownRooms") }
    }

    func start(room: String, server: URL = OSCClient.defaultServer) {
        Task {
            do {
                let (identity, file) = try IdentityFile.loadOrCreate(at: IdentityFile.defaultURL)
                let client = OSCClient(baseURL: server, identity: identity, displayName: file.name, client: Self.clientInfo)
                let session = ChatSession(client: client)
                session.onUpdate = { [weak self] in self?.handle($0) }
                self.session = session
                note(.info, "connecting as \(identity.fingerprint.prefix(8))… (identity: \(IdentityFile.defaultURL.path))")
                try await session.start()
                displayName = await client.displayName ?? "anon"
                await join(room)
            } catch {
                note(.error, "login failed: \(error)")
            }
        }
    }

    // MARK: input

    /// The input line's Enter. Plain text is sent; `/commands` act on the focused message.
    func submit(_ raw: String, labels: [String: String]) {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        if let demo { return demo.input(MentionText.compose(line, labels: labels)) }
        let (head, rest) = split(line)
        Task {
            do {
                switch head {
                case "/help":
                    note(.info, "/sign text · /edit [id] text · /react [id] 👍 · /unreact [id] 👍 · /join room [key] · /nick name · ⌥↑↓ select · ⌘R read · ⌘T theme · ⌘E crt")
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
                    await join(name.trimmingCharacters(in: CharacterSet(charactersIn: "#")).lowercased(),
                               key: key.isEmpty ? nil : key)
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

    // MARK: private

    private func send(_ text: String, labels: [String: String], sign: Bool) async throws {
        guard let roomID else { return note(.error, "not in a room") }
        try await session?.send(MentionText.compose(text, labels: labels), to: roomID, sign: sign)
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

    private func join(_ name: String, key: String? = nil) async {
        guard let session, !name.isEmpty else { return }
        do {
            let state: RoomState
            do {
                state = try await session.join(name, expect: knownRooms[name], key: key)
            } catch let error as OSCError where error.code == "room_changed" {
                note(.error, "#\(name) is now a different room than the one you were in before (the old one expired). Joined the new one.")
                state = try await session.join(name, key: key)
            }
            if let old = roomID, old != state.id { try? await session.leave(old) }
            knownRooms[name] = state.id
            roomID = state.id
            focus = nil
            onRoomChanged?()
            note(.info, "joined #\(state.room.name)")
        } catch let error as OSCError where error.code == "key_required" {
            note(.error, key == nil ? "#\(name) needs a room key: /join \(name) <key>"
                                    : "wrong key for #\(name) (too many wrong tries locks the room's key joins for a while)")
        } catch let error as OSCError where error.code == "invite_required" {
            note(.error, "#\(name) is invite-only")
        } catch let error as OSCError {
            note(.error, "join #\(name): \(error.code)")
        } catch {
            note(.error, "join #\(name): \(error)")
        }
    }

    private func handle(_ update: ChatSession.Update) {
        switch update {
        case .event(let room, let event) where room == roomID:
            onEvent?(event)
        case .reloaded(let room) where room == roomID:
            onRoomChanged?()
        case .left(let room, let reason) where room == roomID:
            note(.error, "you left the room: \(reason)")
            roomID = nil
            onRoomChanged?()
        case .mention(let item) where item.room.id != roomID:
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
