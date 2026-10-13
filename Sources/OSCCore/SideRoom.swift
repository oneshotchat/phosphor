@preconcurrency import CryptoKit
import Foundation

/// Side rooms (protocol §6): a room for exactly two people, whose name both can work out
/// from their fingerprints, so neither has to send it. The server hides it from everyone
/// else and nobody runs it. The server operator can still read it, like every room.
public enum SideRoom {
    /// `side-` plus the first 16 bytes of SHA-256 of the side room string, in lowercase
    /// unpadded base32. `server` is our configured origin, never one the server reports.
    public static func name(_ a: String, _ b: String, server: String) -> String {
        let (low, high) = a < b ? (a, b) : (b, a)
        let string = "oneshotchat/v1/side-room\nserver:\(server)\nmembers:\(low),\(high)"
        return "side-" + Base32.encode(SHA256.hash(data: Data(string.utf8)).prefix(16))
    }

    /// Whether `room` is a proper side room for `me` and `other`: its members are exactly
    /// the two of you, and its name is the one the two of you work out.
    public static func isProper(_ room: Room, me: String, other: String, server: String) -> Bool {
        guard let members = room.side?.members, Set(members) == Set([me, other]), members.count == 2 else { return false }
        return room.name == name(me, other, server: server)
    }

    /// The other member of a side room you're in.
    public static func other(in room: Room, me: String) -> String? {
        room.side?.members.first { $0 != me }
    }
}
