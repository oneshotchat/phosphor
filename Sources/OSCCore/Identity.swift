@preconcurrency import CryptoKit
import Foundation

/// An Ed25519 keypair. The fingerprint (base32 public key) is the permanent ID.
public struct Identity: Sendable {
    public let privateKey: Curve25519.Signing.PrivateKey

    public init(privateKey: Curve25519.Signing.PrivateKey) {
        self.privateKey = privateKey
    }

    /// `seed` is the 32-byte Ed25519 seed, base32 as stored in the identity file.
    public init(seed: String) throws {
        guard let raw = Base32.decode(seed), raw.count == 32 else {
            throw IdentityError.badSeed
        }
        privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    }

    public static func generate() -> Identity {
        Identity(privateKey: Curve25519.Signing.PrivateKey())
    }

    public var seed: String { Base32.encode(privateKey.rawRepresentation) }

    public var fingerprint: String { Base32.encode(privateKey.publicKey.rawRepresentation) }

    /// Base32 Ed25519 signature over the UTF-8 bytes of `string`.
    ///
    /// CryptoKit's Ed25519 is hedged (randomized), so this won't match the protocol's
    /// deterministic test-vector signatures byte for byte. Signatures still verify
    /// against the public key, which is all the server checks.
    public func sign(_ string: String) throws -> String {
        Base32.encode(try privateKey.signature(for: Data(string.utf8)))
    }

    public static func verify(signature: String, of string: String, fingerprint: String) -> Bool {
        guard let sig = Base32.decode(signature),
              let pub = Base32.decode(fingerprint),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pub)
        else { return false }
        return key.isValidSignature(sig, for: Data(string.utf8))
    }

    public static func isFingerprint(_ string: String) -> Bool {
        string.count == 52 && string.utf8.allSatisfy { (0x61...0x7a).contains($0) || (0x32...0x37).contains($0) }
    }
}

public enum IdentityError: Error, Equatable {
    case badSeed
    case badFile
    case fingerprintMismatch
}

/// The exact strings the protocol signs (§4). Lines joined by LF, no trailing newline.
/// `server` is always our configured origin, never one the server tells us.
public enum SignedString {
    public static func login(server: String, identity: String, challenge: String) -> String {
        "oneshotchat/v1/login\nserver:\(server)\nidentity:\(identity)\nchallenge:\(challenge)"
    }

    public static func message(server: String, room: String, author: String, nonce: String, version: Int, text: String) -> String {
        "oneshotchat/v1/message\nserver:\(server)\nroom:\(room)\nauthor:\(author)\nnonce:\(nonce)\nversion:\(version)\n\(text)"
    }

    public static func retire(server: String, identity: String) -> String {
        "oneshotchat/v1/retire\nserver:\(server)\nidentity:\(identity)"
    }
}

/// The portable identity file (§3). Anyone holding it *is* that identity.
public struct IdentityFile: Codable, Sendable {
    public var format = "oneshotchat-identity"
    public var version = 1
    public var seed: String
    public var identity: String
    public var name: String?

    public init(identity: Identity, name: String?) {
        seed = identity.seed
        self.identity = identity.fingerprint
        self.name = name
    }

    /// Checks the format and that the seed really derives the stated fingerprint.
    public func load() throws -> Identity {
        guard format == "oneshotchat-identity", version == 1 else { throw IdentityError.badFile }
        let id = try Identity(seed: seed)
        guard id.fingerprint == identity else { throw IdentityError.fingerprintMismatch }
        return id
    }

    public static func read(from url: URL) throws -> IdentityFile {
        try JSONDecoder().decode(IdentityFile.self, from: Data(contentsOf: url))
    }

    /// Writes atomically with owner-only (0600) permissions.
    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }

    /// `~/Library/Application Support/Phosphor/default.identity`, shared by the app and `osc`.
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Phosphor", isDirectory: true)
            .appendingPathComponent("default.identity")
    }

    /// Loads the identity at `url`, or creates and saves a new one there.
    public static func loadOrCreate(at url: URL, name: String? = nil) throws -> (Identity, IdentityFile) {
        if FileManager.default.fileExists(atPath: url.path) {
            let file = try read(from: url)
            return (try file.load(), file)
        }
        let identity = Identity.generate()
        let file = IdentityFile(identity: identity, name: name)
        try file.write(to: url)
        return (identity, file)
    }
}
