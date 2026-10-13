import Foundation
import OSCCore

/// Whose Phosphor this is. Normally yours: your identity, settings, contacts and room keys.
/// `PHOSPHOR_IDENTITY=/path/to/file.identity` runs it as another identity (an agent's, say)
/// with its own settings, contacts and room keys, so neither disturbs the other: it won't
/// rejoin your rooms, see your contacts, or change your saved settings.
enum Profile {
    /// The identity file named by `PHOSPHOR_IDENTITY`, if any.
    static let identityOverride: URL? = ProcessInfo.processInfo.environment["PHOSPHOR_IDENTITY"]
        .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }

    /// "agent" for agent.identity; nil for your own profile.
    static let name: String? = identityOverride.map { $0.deletingPathExtension().lastPathComponent }

    /// Dev: `PHOSPHOR_SANDBOX` keeps settings apart too, so tests leave yours alone.
    static let isSandboxed = !(ProcessInfo.processInfo.environment["PHOSPHOR_SANDBOX"] ?? "").isEmpty

    static let defaults: UserDefaults = isSandboxed ? UserDefaults(suiteName: "Phosphor.sandbox")!
        : name.flatMap { UserDefaults(suiteName: "Phosphor.profile.\($0)") } ?? .standard

    static var contactsURL: URL {
        IdentityFile.defaultURL.deletingLastPathComponent().appendingPathComponent(name.map { "contacts-\($0).json" } ?? "contacts.json")
    }

    /// Per-identity settings (rooms you're in, room fingerprints, signing): the profile's
    /// own store for Phosphor's original identity (so nothing of it moves), a separate one
    /// for each other identity. Contacts and look-and-feel stay shared.
    nonisolated(unsafe) private(set) static var identityDefaults: UserDefaults = defaults
    /// Set for identities other than the original, to keep their room keys apart too.
    nonisolated(unsafe) private(set) static var identityTag: String?

    /// Set when on a custom server, so its rooms and keys stay apart from the real one's.
    nonisolated(unsafe) private(set) static var serverTag: String?

    /// Switches the per-identity store to the identity in `url`, on `server`. The original
    /// identity on the real server keeps the profile's own store, so nothing of it moves.
    static func use(identityAt url: URL, server: URL) {
        let fingerprint = (try? IdentityFile.read(from: url))?.identity
        let own = identityOverride != nil || url == IdentityFile.defaultURL || fingerprint == nil
        identityTag = own ? nil : fingerprint.map { String($0.prefix(16)) }
        let origin = OSCClient.origin(of: server)
        serverTag = origin == OSCClient.origin(of: OSCClient.defaultServer) ? nil
            : origin.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "://", with: "-").replacingOccurrences(of: ":", with: "-")
        guard identityTag != nil || serverTag != nil else {
            identityDefaults = defaults
            return
        }
        let prefix = isSandboxed ? "Phosphor.sandbox." : name.map { "Phosphor.profile.\($0)." } ?? "Phosphor."
        let suite = prefix + (serverTag.map { "server.\($0)." } ?? "") + (identityTag.map { "identity.\($0)" } ?? "original")
        identityDefaults = UserDefaults(suiteName: suite) ?? defaults
    }

    static var keychainService: String {
        let base = isSandboxed ? "Phosphor room key (sandbox)" : name.map { "Phosphor room key (\($0))" } ?? "Phosphor room key"
        return base + (identityTag.map { " [\($0)]" } ?? "") + (serverTag.map { " @\($0)" } ?? "")
    }
}
