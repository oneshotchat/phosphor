import Foundation

/// A logged-in session's view of its rooms, kept live: WebSocket when the server offers
/// one, polling when it doesn't, and HTTP catch-up after every (re)connect.
///
/// Lives on the main actor so UI code can read `rooms` directly; observe changes via `onUpdate`.
@MainActor
public final class ChatSession {
    public enum Update: Sendable {
        case connection(EventSocket.Status)
        case joined(room: String)
        /// A new event was applied to `rooms[room]`.
        case event(room: String, Event)
        /// The room's state was replaced wholesale (history truncated, or rejoined).
        case reloaded(room: String)
        /// Older messages were merged in for scrollback.
        case historyLoaded(room: String, hasMore: Bool)
        /// We're no longer in the room (kicked or banned, or a rejoin failed).
        case left(room: String, reason: String)
        /// Someone mentioned us, in any room.
        case mention(MentionItem)
        /// From the server: a room `notice` event, or a per-session notice (`room` nil).
        case notice(room: String?, Notice)
        case error(String)
    }

    public let client: OSCClient
    public private(set) var discovery: Discovery?
    public private(set) var rooms: [String: RoomState] = [:]
    public private(set) var connection: EventSocket.Status = .connecting
    public var onUpdate: ((Update) -> Void)?

    public var me: String { client.identity.fingerprint }

    /// Room keys used to join, so an automatic rejoin works. Memory only, never persisted.
    private var roomKeys: [String: String] = [:]
    private var socketTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private let pollInterval: Duration

    public init(client: OSCClient, pollInterval: Duration = .seconds(3)) {
        self.client = client
        self.pollInterval = pollInterval
    }

    /// Discovers the server, logs in, and starts listening for live events.
    public func start() async throws {
        discovery = try await client.discover()
        try await client.login()
        listen()
    }

    public func stop() {
        socketTask?.cancel()
        pollTask?.cancel()
        socketTask = nil
        pollTask = nil
    }

    // MARK: rooms

    /// Joins (creating if free), loads recent history, then catches up from the join point.
    /// Pass `expect` with a remembered fingerprint to refuse a different room reusing the name.
    @discardableResult
    public func join(_ name: String, expect: String? = nil, key: String? = nil, invite: String? = nil) async throws -> RoomState {
        let result = try await client.join(name, expect: expect, key: key, invite: invite)
        let id = result.room.id
        roomKeys[id] = key
        var state = RoomState(room: result.room, role: result.role)
        state.load(try await client.messages(room: id).messages)
        rooms[id] = state
        emit(.joined(room: id))
        await catchUp(id)
        return rooms[id] ?? state
    }

    /// Changes room settings. A key you set is kept for automatic rejoins, like one you
    /// joined with.
    public func updateRoom(_ room: String, _ update: RoomUpdate) async throws {
        try await client.updateRoom(room, update)
        if let key = update.key { roomKeys[room] = key }
        if update.access == "open" { roomKeys[room] = nil }
    }

    public func leave(_ room: String) async throws {
        try await client.leave(room: room)
        rooms[room] = nil
        roomKeys[room] = nil
        emit(.left(room: room, reason: "left"))
    }

    /// Older messages for scrollback, merged into the room's state.
    public func loadOlder(_ room: String) async throws -> Bool {
        guard let oldest = rooms[room]?.messages.keys.min() else { return false }
        let page = try await client.messages(room: room, before: oldest)
        rooms[room]?.load(page.messages)
        emit(.historyLoaded(room: room, hasMore: page.hasMore))
        return page.hasMore
    }

    // MARK: actions (thin wrappers that also apply the result locally)

    @discardableResult
    public func send(_ text: String, to room: String, sign: Bool = false) async throws -> Message {
        let message = try await client.send(room: room, text: text, sign: sign)
        rooms[room]?.load([message])
        return message
    }

    @discardableResult
    public func edit(_ message: Message, to text: String, sign: Bool = false) async throws -> Message {
        let latest = rooms[message.room]?.messages[message.id] ?? message
        let edited = try await client.edit(latest, text: text, sign: sign)
        rooms[message.room]?.load([edited])
        return edited
    }

    public func react(_ reaction: String, to message: Message) async throws {
        try await client.react(room: message.room, message: message.id, reaction: reaction)
    }

    public func unreact(_ reaction: String, from message: Message) async throws {
        try await client.unreact(room: message.room, message: message.id, reaction: reaction)
    }

    // MARK: live events

    private func listen() {
        socketTask?.cancel()
        let stream = EventSocket.stream(client: client)
        socketTask = Task { [weak self] in
            for await output in stream {
                guard let self else { return }
                switch output {
                case .status(let status):
                    connection = status
                    emit(.connection(status))
                    switch status {
                    case .connected: await catchUpAll()
                    case .unavailable: startPolling()
                    case .connecting, .disconnected: break
                    }
                case .frame(let frame):
                    await handle(frame)
                }
            }
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await catchUpAll()
                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    private func handle(_ frame: SocketFrame) async {
        switch frame {
        case .event(let event):
            await apply(event)
        case .mention(let mention):
            emit(.mention(mention))
        case .sessionNotice(let notice):
            emit(.notice(room: nil, notice))
        case .pong, .unknown:
            break
        }
    }

    private func apply(_ event: Event) async {
        guard rooms[event.room]?.apply(event) == true else { return }
        if case .memberRoleChanged(let change) = event.payload, change.identity == me {
            rooms[event.room]?.updateRole(change.role)
        }
        emit(.event(room: event.room, event))
        if case .notice(let notice) = event.payload { emit(.notice(room: event.room, notice)) }

        if case .memberLeft(let left) = event.payload, left.identity == me {
            if left.reason == "timeout" {
                // Presence lapsed (laptop slept, say). Roles are kept; just come back.
                await rejoin(event.room)
            } else {
                rooms[event.room] = nil
                emit(.left(room: event.room, reason: left.reason ?? "left"))
            }
        }
    }

    private func catchUpAll() async {
        for id in rooms.keys { await catchUp(id) }
    }

    /// Pages through `…/events?after=` until current. Handles expiry and lapsed presence.
    private func catchUp(_ id: String) async {
        do {
            while let after = rooms[id]?.lastSeq {
                let page = try await client.events(room: id, after: after)
                if page.truncated == true {
                    let recent = try await client.messages(room: id)
                    rooms[id]?.reset(messages: recent.messages, latestSeq: page.latestSeq ?? after)
                    emit(.reloaded(room: id))
                    return
                }
                for event in page.events { await apply(event) }
                if !page.hasMore || page.events.isEmpty { return }
            }
        } catch let error as OSCError where error.code == "not_in_room" {
            await rejoin(id)
        } catch {
            emit(.error("catch-up \(id): \(error)"))
        }
    }

    /// Rejoins a room we dropped out of, pinned to its fingerprint, keeping our state.
    private func rejoin(_ id: String) async {
        guard let name = rooms[id]?.room.name else { return }
        do {
            let result = try await client.join(name, expect: id, key: roomKeys[id])
            rooms[id]?.updateRole(result.role)
            emit(.reloaded(room: id))
            await catchUp(id)
        } catch {
            rooms[id] = nil
            emit(.left(room: id, reason: "rejoin failed: \(error)"))
        }
    }

    private func emit(_ update: Update) { onUpdate?(update) }
}
