import Foundation
import OSCCore

// osc: a plain-terminal OneShotChat client on OSCCore.
//
//   osc discover            server info (no login)
//   osc rooms               the public room browser (no login)
//   osc whoami              your fingerprint (creates an identity on first use)
//   osc chat <room>         join and chat; type /help inside (--key <room key> for keyed rooms)
//
// Options: --server <url>  --name <display name>  --identity <path>

let version = "0.1.0"
setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered even when piped, so live events show promptly
var args = Array(CommandLine.arguments.dropFirst())

func option(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

let server = option("--server").flatMap(URL.init(string:)) ?? OSCClient.defaultServer
let nameOption = option("--name")
let roomKey = option("--key")
let identityURL = option("--identity").map { URL(fileURLWithPath: $0) } ?? IdentityFile.defaultURL

/// Chat text is untrusted: strip terminal control sequences before printing.
func safe(_ text: String) -> String { SafeText.clean(text) }

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("osc: \(message)\n".utf8))
    exit(1)
}

func makeClient() throws -> OSCClient {
    let (identity, file) = try IdentityFile.loadOrCreate(at: identityURL, name: nameOption)
    return OSCClient(baseURL: server, identity: identity, displayName: nameOption ?? file.name,
                     client: ClientInfo(name: "phosphor-cli", version: version))
}

switch args.first {
case "discover":
    let d = try await OSCClient(baseURL: server, identity: .generate(), displayName: nil,
                                client: ClientInfo(name: "phosphor-cli")).discover()
    print("\(safe(d.name)) protocol \(d.protocol)")
    print("websocket: \(d.websocketUrl?.absoluteString ?? "none")")
    print("conformance bot: \(d.conformanceBot ?? "none")")
    if let motd = d.motd { print("motd: \(safe(motd))") }

case "rooms":
    let list = try await OSCClient(baseURL: server, identity: .generate(), displayName: nil,
                                   client: ClientInfo(name: "phosphor-cli")).rooms()
    for room in list.rooms {
        let people = room.occupantCount.map { "\($0) here" } ?? "?"
        let recent = room.activity?.messagesLast10m.map { "\($0) msgs/10m" } ?? ""
        print("#\(safe(room.name))  \(people)  \(recent)  \(safe(room.topic ?? ""))")
    }

case "whoami":
    let (identity, file) = try IdentityFile.loadOrCreate(at: identityURL, name: nameOption)
    print("\(safe(file.name ?? "anon"))  \(identity.fingerprint)")
    print("identity file: \(identityURL.path) (this file IS your identity; keep it secret)")

case "chat":
    guard args.count >= 2 else { fail("usage: osc chat <room>") }
    try await Chat(roomName: args[1].trimmingCharacters(in: CharacterSet(charactersIn: "#")).lowercased()).run()

default:
    print("usage: osc discover | rooms | whoami | chat <room> [--key key]  [--server url] [--name name] [--identity path]")
}

@MainActor
final class Chat {
    let roomName: String
    var session: ChatSession!
    var roomID = ""

    init(roomName: String) { self.roomName = roomName }

    var state: RoomState? { session.rooms[roomID] }

    func label(_ fingerprint: String) -> String {
        state?.labels[fingerprint] ?? String(fingerprint.prefix(8))
    }

    func render(_ m: Message) -> String {
        let signature = switch m.signatureStatus(server: session.client.origin) {
        case .unsigned: ""
        case .valid: " [signed]"
        case .invalid: " [BAD SIGNATURE]"
        }
        let edited = m.editedAt != nil ? " (edited)" : ""
        let reactions = (m.reactions ?? []).map { "\(safe($0.reaction))×\($0.count)" }.joined(separator: " ")
        let text = MentionText.display(m.text, label: label)
        return "[\(m.id)] \(safe(label(m.author.identity))): \(safe(text))\(edited)\(signature)\(reactions.isEmpty ? "" : "  " + reactions)"
    }

    func run() async throws {
        session = ChatSession(client: try makeClient())
        session.onUpdate = { [unowned self] update in self.show(update) }
        try await session.start()
        let name = await session.client.displayName
        print("you are \(safe(name ?? "anon")) (\(session.me))")
        let state = try await session.join(roomName, key: roomKey)
        roomID = state.id
        print("joined #\(safe(state.room.name)) \(state.id)  topic: \(safe(state.room.topic ?? ""))")
        for m in state.orderedMessages.suffix(20) { print(render(m)) }
        print("(/help for commands)")

        for try await line in FileHandle.standardInput.bytes.lines {
            if await !command(line) { break }
        }
        try? await session.leave(roomID)
        session.stop()
    }

    func show(_ update: ChatSession.Update) {
        switch update {
        case .connection(let status): print("· connection: \(status)")
        case .event(let room, let event) where room == roomID:
            switch event.payload {
            case .messageCreated(let m): print(render(m))
            case .messageEdited(let m): print("edited → " + render(m))
            case .reactionAdded(let r): print("· \(safe(label(r.identity))) reacted \(safe(r.reaction)) to [\(r.messageId)]")
            case .reactionRemoved(let r): print("· \(safe(label(r.identity))) removed \(safe(r.reaction)) from [\(r.messageId)]")
            case .memberJoined(let j): print("· \(safe(label(j.identity))) joined")
            case .memberLeft(let l): print("· \(safe(l.name ?? label(l.identity))) left (\(l.reason ?? "left"))")
            case .memberRenamed(let r): print("· \(safe(r.oldName ?? "?")) is now \(safe(r.newName))")
            case .memberRoleChanged(let r): print("· \(safe(label(r.identity))) role: \(r.role?.rawValue ?? "none")")
            case .roomUpdated(let room): print("· room updated, topic: \(safe(room.topic ?? ""))")
            case .notice, .unknown: break
            }
        case .notice(_, let notice): print("!! SERVER NOTICE (\(safe(notice.code))): \(safe(notice.text))")
        case .mention(let item) where item.room.id != roomID:
            print("· mentioned in #\(safe(item.room.name)): \(render(item.message))")
        case .left(let room, let reason) where room == roomID: print("· you left the room: \(safe(reason))")
        case .error(let message): print("· error: \(safe(message))")
        default: break
        }
    }

    /// Returns false to quit.
    func command(_ line: String) async -> Bool {
        do {
            let (head, rest) = split(line)
            switch head {
            case "/quit": return false
            case "/help":
                print("""
                text            send (type @label to mention someone; see /who)
                /sign text      send a signed message
                /edit id text   edit your message     /sedit id text   signed edit
                /react id 👍    react                 /unreact id 👍   remove reaction
                /who            people here, with mention labels
                /quit
                """)
            case "/who":
                for o in (state?.occupants.values.sorted { $0.name < $1.name } ?? []) {
                    print("  @\(safe(label(o.identity)))  \(o.role?.rawValue ?? "")  \(o.identity)")
                }
            case "/sign": try await send(rest, sign: true)
            case "/edit", "/sedit":
                let (id, text) = split(rest)
                guard let id = Int(id), let message = state?.messages[id] else { print("· no message \(id)"); break }
                try await session.edit(message, to: compose(text), sign: head == "/sedit")
            case "/react", "/unreact":
                let (id, reaction) = split(rest)
                guard let id = Int(id), let message = state?.messages[id] else { print("· no message \(id)"); break }
                if head == "/react" { try await session.react(reaction, to: message) } else { try await session.unreact(reaction, from: message) }
            default:
                if line.hasPrefix("/") { print("· unknown command; /help") } else if !line.isEmpty { try await send(line, sign: false) }
            }
        } catch {
            print("· error: \(error)")
        }
        return true
    }

    func send(_ text: String, sign: Bool) async throws {
        try await session.send(compose(text), to: roomID, sign: sign)
    }

    /// `@label` → `<@fingerprint>` for everyone in view.
    func compose(_ text: String) -> String {
        var byLabel: [String: String] = [:]
        for (fingerprint, label) in state?.labels ?? [:] { byLabel[label] = fingerprint }
        return MentionText.compose(text, labels: byLabel)
    }

    func split(_ s: String) -> (String, String) {
        guard let space = s.firstIndex(of: " ") else { return (s, "") }
        return (String(s[..<space]), String(s[s.index(after: space)...]))
    }
}
