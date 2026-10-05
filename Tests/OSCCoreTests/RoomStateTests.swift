import Foundation
import Testing
@testable import OSCCore

private let roomID = "ibaueq2eivdeoscjjjfuytkoj4"
private let sam = String(repeating: "a", count: 52)
private let ada = String(repeating: "b", count: 52)

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSON.decoder.decode(T.self, from: Data(json.utf8))
}

private func messageJSON(id: Int, text: String = "hello", version: Int = 1, author: String = sam, reactions: String = "[]") -> String {
    """
    {"id":\(id),"room":"\(roomID)","author":{"identity":"\(author)","name":"sam"},
     "client":{"name":"toaster-chat","version":"0.3.1"},"text":"\(text)","mentions":[],
     "nonce":"01hzx7k2m9","signature":null,"version":\(version),
     "created_at":"2026-10-03T04:05:06.789Z","edited_at":null,"reactions":\(reactions),
     "expires_at":"2026-10-10T04:05:06.789Z","some_future_field":true}
    """
}

private func event(_ seq: Int, _ type: String, _ data: String) throws -> Event {
    try decode(Event.self, #"{"seq":\#(seq),"room":"\#(roomID)","type":"\#(type)","at":"2026-10-03T04:05:06Z","data":\#(data)}"#)
}

private func freshRoom(latestSeq: Int = 100) throws -> RoomState {
    let room = try decode(Room.self, """
    {"id":"\(roomID)","name":"lobby","topic":"be nice","visibility":"listed","access":"open","speaking":"open",
     "retention_seconds":604800,"permanent":true,"created_at":"2026-10-01T00:00:00.000Z","latest_seq":\(latestSeq),
     "activity":{"messages_last_10m":3,"last_message_at":"2026-10-03T04:01:00.000Z"},
     "occupant_count":1,"occupants":[{"identity":"\(sam)","name":"sam","role":"operator"}]}
    """)
    return RoomState(room: room, role: .operator)
}

@Test func decodesRoomIncludingSnakeCaseActivity() throws {
    let state = try freshRoom()
    #expect(state.room.retentionSeconds == 604800)
    #expect(state.room.activity?.messagesLast10m == 3)
    #expect(state.room.activity?.lastMessageAt != nil)
    #expect(state.occupants[sam]?.role == .operator)
    #expect(state.lastSeq == 100)
}

@Test func unknownEventTypesAndRolesDecodeHarmlessly() throws {
    #expect(try { if case .unknown = try event(101, "room.exploded", "{}").payload { true } else { false } }())
    // A known type with broken data is also skipped, not fatal.
    #expect(try { if case .unknown = try event(102, "member.joined", #"{"nope":1}"#).payload { true } else { false } }())
    let joined = try event(103, "member.joined", #"{"identity":"\#(ada)","name":"ada","role":"wizard"}"#)
    guard case .memberJoined(let j) = joined.payload else { Issue.record("expected member.joined"); return }
    #expect(j.role == .unknown("wizard"))
}

@Test func appliesMessageLifecycle() throws {
    var state = try freshRoom()
    do { let applied = state.apply(try event(101, "message.created", #"{"message":\#(messageJSON(id: 101))}"#)); #expect(applied) }
    do { let applied = state.apply(try event(102, "reaction.added", #"{"message_id":101,"reaction":"👍","identity":"\#(ada)"}"#)); #expect(applied) }
    do { let applied = state.apply(try event(103, "reaction.added", #"{"message_id":101,"reaction":"👍","identity":"\#(sam)"}"#)); #expect(applied) }
    #expect(state.messages[101]?.reactions == [ReactionSummary(reaction: "👍", count: 2, identities: [ada, sam])])
    do { let applied = state.apply(try event(104, "reaction.removed", #"{"message_id":101,"reaction":"👍","identity":"\#(ada)"}"#)); #expect(applied) }
    #expect(state.messages[101]?.reactions?.first?.count == 1)
    do { let applied = state.apply(try event(105, "message.edited", #"{"message":\#(messageJSON(id: 101, text: "hello again", version: 2))}"#)); #expect(applied) }
    #expect(state.messages[101]?.text == "hello again")
    #expect(state.lastSeq == 105)
}

@Test func skipsDuplicatesAndSnapshotEvents() throws {
    var state = try freshRoom(latestSeq: 100)
    #expect(!state.apply(try event(100, "message.created", #"{"message":\#(messageJSON(id: 100))}"#)))  // in the snapshot
    let e = try event(101, "member.joined", #"{"identity":"\#(ada)","name":"ada","role":null}"#)
    do { let applied = state.apply(e); #expect(applied) }
    do { let applied = state.apply(e); #expect(!applied) }
    #expect(state.occupants.count == 2)
}

@Test func lateOutOfOrderEventStillApplies() throws {
    var state = try freshRoom()
    do { let applied = state.apply(try event(103, "message.created", #"{"message":\#(messageJSON(id: 103))}"#)); #expect(applied) }
    do { let applied = state.apply(try event(102, "message.created", #"{"message":\#(messageJSON(id: 102))}"#)); #expect(applied) }
    #expect(state.orderedMessages.map(\.id) == [102, 103])
    #expect(state.lastSeq == 103)
}

@Test func olderVersionNeverOverwritesNewer() throws {
    var state = try freshRoom()
    state.load([try decode(Message.self, messageJSON(id: 50, text: "v3", version: 3))])
    state.load([try decode(Message.self, messageJSON(id: 50, text: "v2", version: 2))])
    #expect(state.messages[50]?.text == "v3")
}

@Test func membersLeaveRenameAndChangeRole() throws {
    var state = try freshRoom()
    state.apply(try event(101, "member.joined", #"{"identity":"\#(ada)","name":"ada","role":null}"#))
    state.apply(try event(102, "member.renamed", #"{"identity":"\#(ada)","old_name":"ada","new_name":"ada2"}"#))
    state.apply(try event(103, "member.role_changed", #"{"identity":"\#(ada)","role":"voice","by":"\#(sam)"}"#))
    #expect(state.occupants[ada]?.name == "ada2")
    #expect(state.occupants[ada]?.role == .voice)
    state.apply(try event(104, "member.left", #"{"identity":"\#(ada)","name":"ada2","reason":"timeout","by":null,"message":null}"#))
    #expect(state.occupants[ada] == nil)
}

@Test func labelsIncludeAuthorsWhoLeft() throws {
    var state = try freshRoom()
    state.load([try decode(Message.self, messageJSON(id: 90, author: "a" + String(repeating: "c", count: 51)))])
    #expect(state.labels[sam] == "sam#aa")
    #expect(state.labels["a" + String(repeating: "c", count: 51)] == "sam#ac")
}

@Test func signatureStatusVerifiesLocally() throws {
    let id = try Identity(seed: "aaaqeayeaudaocajbifqydiob4ibceqtcqkrmfyydenbwha5dypq")
    var message = try decode(Message.self, messageJSON(id: 1, author: id.fingerprint))
    #expect(message.signatureStatus(server: "https://api.oneshotchat.com") == .unsigned)
    message.signature = try id.sign(SignedString.message(server: "https://api.oneshotchat.com", room: roomID,
                                                         author: id.fingerprint, nonce: "01hzx7k2m9", version: 1, text: "hello"))
    #expect(message.signatureStatus(server: "https://api.oneshotchat.com") == .valid)
    #expect(message.signatureStatus(server: "https://evil.example") == .invalid)
    message.text = "tampered"
    #expect(message.signatureStatus(server: "https://api.oneshotchat.com") == .invalid)
}

@Test func decodesWebSocketFrames() throws {
    guard case .event(let e) = SocketFrame.decode(Data(#"{"seq":5,"room":"\#(roomID)","type":"notice","data":{"code":"motd","text":"hi"}}"#.utf8)),
          case .notice(let n) = e.payload else { Issue.record("expected notice event"); return }
    #expect(n.text == "hi")
    guard case .sessionNotice(let s) = SocketFrame.decode(Data(#"{"type":"session.notice","data":{"code":"too_fast","text":"slow"}}"#.utf8))
    else { Issue.record("expected session notice"); return }
    #expect(s.code == "too_fast")
    #expect({ if case .pong = SocketFrame.decode(Data(#"{"type":"pong"}"#.utf8)) { true } else { false } }())
    #expect({ if case .unknown = SocketFrame.decode(Data("not json".utf8)) { true } else { false } }())
}
