import Foundation
import OSCCore

/// An offline room with scripted chatter, for working on visuals without posting to the
/// real server. Events are built as protocol JSON and go through the real `RoomState`
/// and event path, so the scene can't tell the difference.
///
///     swift run Phosphor --demo               (PHOSPHOR_DEMO_SPEAKERS=6 for the two-column layout)
///
/// The demo runs several of these, one per room, at different paces.
@MainActor
final class DemoFeed {
    private(set) var state: RoomState
    let me: String
    var onEvent: ((Event) -> Void)?

    let roomID: String
    private let pace: ClosedRange<Int>
    private var seq = 100
    private var people: [(fp: String, name: String)] = []
    private var present: Set<String> = []
    private let speakers: Int
    private var messages: [Int: [String: Any]] = [:]
    private var task: Task<Void, Never>?

    private static let lines = [
        "anyone else here from #conformance?",
        "just passed !test 🎉",
        "lobby keeps messages for seven days, this one only an hour",
        "has anyone tried the WebSocket reconnect after a laptop sleep? catch-up worked for me",
        "日本語もok → CoreText font fallback",
        "nothing lasts forever ✦",
        "a slightly longer message to see how wrapping behaves when someone has a lot to say about tripcodes and petnames and why fingerprints are the only real identity here",
        "line one\nline two\nline three",
        "+1",
        "brb",
        "signatures can't be denied later, worth remembering",
        "the bot says set client.url",
        "who's the other sam?",
        "rooms expire after 7 days with nobody in them",
    ]

    init(name: String, topic: String, me: String, speakers: Int, pace: ClosedRange<Int>) {
        self.speakers = max(1, speakers)
        self.me = me
        self.pace = pace
        roomID = Self.roomID(name)
        let names = ["sam", "sam", "ada", "kit", "noor", "lev", "ines", "tomo", "rue", "bo", "cy", "dee"]
        people = [(me, "you")] + names.map { (Identity.generate().fingerprint, $0) }
        present = Set(people.prefix(9).map(\.fp))

        let occupants = people.prefix(9).map { ["identity": $0.fp, "name": $0.name, "role": NSNull()] as [String: Any] }
        let room: [String: Any] = [
            "id": roomID, "name": name, "topic": topic,
            "visibility": "listed", "access": "open", "speaking": "open", "retention_seconds": 3600,
            "latest_seq": seq, "occupant_count": occupants.count, "occupants": occupants,
        ]
        state = RoomState(room: Self.decode(Room.self, room)!, role: nil)

        // Some history, already written.
        var history: [Message] = []
        for i in 0..<8 {
            seq += 1
            let author = speakerPool[i % speakerPool.count]
            let dict = message(id: seq, author: author, text: Self.lines[i % Self.lines.count])
            messages[seq] = dict
            history.append(Self.decode(Message.self, dict)!)
        }
        state = RoomState(room: Self.decode(Room.self, room.merging(["latest_seq": seq]) { $1 })!, role: nil)
        state.load(history)
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func start() {
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(Int.random(in: self?.pace ?? 2000...3000)))
                self?.step()
            }
        }
    }

    /// Typing in the demo room: plain text, `/react [id] x`, `/edit text`.
    /// Your own message, sent the way the real server answers: stored and returned at once
    /// (call `onSent`), with the live event echoing back a moment later.
    var onSent: ((Message) -> Void)?

    func input(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        if parts.first == "/react", parts.count >= 2 {
            let id = Int(parts[1]).flatMap { messages[$0] != nil ? $0 : nil } ?? messages.keys.max()!
            react(id, parts.count == 3 ? parts[2] : parts[1], by: me)
        } else if parts.first == "/edit", let id = messages.filter({ ($0.value["author"] as? [String: Any])?["identity"] as? String == me }).keys.max() {
            edit(id, text: String(line.dropFirst(6)))
        } else if !line.hasPrefix("/") {
            post(from: me, text: line, asReply: true)
        }
    }

    // MARK: script

    private var speakerPool: [(fp: String, name: String)] { Array(people.dropFirst().prefix(speakers)) }

    private func step() {
        let roll = Int.random(in: 0..<100)
        let recent = messages.keys.sorted().suffix(6)
        switch roll {
        case 0..<62:
            let author = speakerPool.randomElement()!
            post(from: author.fp, text: Self.lines.randomElement()!)
        case 62..<72:
            if let id = recent.randomElement() { react(id, ["👍", "🔥", "lol", "+1"].randomElement()!, by: speakerPool.randomElement()!.fp) }
        case 72..<78:
            if let id = recent.last, let author = (messages[id]?["author"] as? [String: Any])?["identity"] as? String, author != me {
                edit(id, text: (messages[id]?["text"] as? String ?? "") + " (fixed typo)")
            }
        case 78..<86:
            let author = speakerPool.randomElement()!
            post(from: author.fp, text: "<@\(me)> what do you think?", mentions: [me])
        case 86..<93:
            // A lurker leaves (in one of several ways) or someone new arrives.
            let lurkers = people.dropFirst(speakers + 1)
            if let leaving = lurkers.filter({ present.contains($0.fp) }).randomElement(), present.count > 6 {
                present.remove(leaving.fp)
                emit("member.left", ["identity": leaving.fp, "name": leaving.name,
                                     "reason": ["left", "timeout", "kicked", "banned"].randomElement()!, "by": NSNull(), "message": NSNull()])
            } else if let joining = lurkers.filter({ !present.contains($0.fp) }).randomElement() {
                present.insert(joining.fp)
                emit("member.joined", ["identity": joining.fp, "name": joining.name, "role": NSNull()])
            }
        default:
            break
        }
    }

    private func post(from fp: String, text: String, mentions: [String] = [], asReply: Bool = false) {
        seq += 1
        var mentioned = mentions
        for case .mention(let target) in MentionText.segments(text) where !mentioned.contains(target) { mentioned.append(target) }
        let dict = message(id: seq, author: people.first { $0.fp == fp }!, text: text, mentions: mentioned)
        messages[seq] = dict
        guard asReply, let sent = Self.decode(Message.self, dict) else {
            emit("message.created", ["message": dict], seq: seq)
            return
        }
        state.load([sent])
        onSent?(sent)
        let id = seq
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            self?.emit("message.created", ["message": dict], seq: id)
        }
    }

    private func react(_ id: Int, _ reaction: String, by fp: String) {
        emit("reaction.added", ["message_id": id, "reaction": reaction, "identity": fp])
    }

    private func edit(_ id: Int, text: String) {
        guard var dict = messages[id] else { return }
        dict["text"] = text
        dict["version"] = (dict["version"] as? Int ?? 1) + 1
        dict["edited_at"] = Self.timestamp(Date())
        messages[id] = dict
        emit("message.edited", ["message": dict])
    }

    private func emit(_ type: String, _ data: [String: Any], seq explicit: Int? = nil) {
        let eventSeq: Int
        if let explicit { eventSeq = explicit } else { seq += 1; eventSeq = seq }
        let dict: [String: Any] = ["seq": eventSeq, "room": roomID, "type": type, "at": Self.timestamp(Date()), "data": data]
        guard let event = Self.decode(Event.self, dict) else { return }
        state.apply(event)
        onEvent?(event)
    }

    private func message(id: Int, author: (fp: String, name: String), text: String, mentions: [String] = []) -> [String: Any] {
        [
            "id": id, "room": roomID, "author": ["identity": author.fp, "name": author.name],
            "client": ["name": "demo"], "text": text, "mentions": mentions, "nonce": "demo\(id)nonce",
            "signature": NSNull(), "version": 1, "created_at": Self.timestamp(Date()), "edited_at": NSNull(),
            "reactions": [] as [Any], "expires_at": Self.timestamp(Date().addingTimeInterval(3600)),
        ]
    }

    /// Room id for a demo room name, the same way `init` makes it, so a listed room and the
    /// feed that serves it once joined share an id.
    static func roomID(_ name: String) -> String {
        String((name + String(repeating: "0", count: 26)).prefix(26)).lowercased()
    }

    /// Made-up display names. A few repeat on purpose, so tripcodes show up.
    private static let handles = [
        "mira", "jonas_k", "pixelwitch", "tomás", "nyx", "deadbeef", "ollie", "kaito", "sasha.v",
        "brightside", "quill", "ash", "zuri", "grumpycat", "lena", "theo", "ayo", "marguerite",
        "0xfeed", "bjørn", "ren", "late_again", "wren", "sam", "ines", "noor", "kit", "mira",
    ]

    /// A made-up public room listing for the browser: busiest first, some needing a key or
    /// an invite.
    static func listing() -> [Room] {
        let rooms: [(String, String, Int, Int, String)] = [
            ("lobby", "say hi", 14, 9, "open"), ("ai", "talk about models", 9, 6, "open"),
            ("games", "members only", 6, 4, "key"), ("help", "ask anything", 5, 2, "open"),
            ("news", "links and headlines", 4, 1, "open"), ("late-night", "by invitation", 3, 3, "invite"),
            ("quiet", "", 2, 0, "open"), ("retro", "old machines", 1, 0, "open"),
        ]
        return rooms.enumerated().compactMap { index, spec in
            let (name, topic, people, recent, access) = spec
            let offset = index * 11
            let occupants = (0..<people).map { i in
                ["identity": Identity.generate().fingerprint, "name": handles[(i * 5 + offset) % handles.count],      // 5 is coprime with 28: no repeats
                 "role": NSNull()] as [String: Any]
            }
            return decode(Room.self, [
                "id": roomID(name), "name": name, "topic": topic, "visibility": "listed", "access": access,
                "speaking": "open", "retention_seconds": 3600, "latest_seq": 100, "occupant_count": people,
                "occupants": occupants, "activity": ["messages_last_10m": recent],
            ])
        }
    }

    private static func timestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ object: [String: Any]) -> T? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            return try Date(s, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        do { return try decoder.decode(T.self, from: data) } catch {
            print("DemoFeed: \(error)")
            return nil
        }
    }
}
