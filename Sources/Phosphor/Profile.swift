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

    /// Switches the per-identity store to the identity in `url`.
    static func use(identityAt url: URL) {
        let fingerprint = (try? IdentityFile.read(from: url))?.identity
        guard identityOverride == nil, url != IdentityFile.defaultURL, let fingerprint else {
            identityDefaults = defaults
            identityTag = nil
            return
        }
        let tag = String(fingerprint.prefix(16))
        identityDefaults = UserDefaults(suiteName: (isSandboxed ? "Phosphor.sandbox.identity." : "Phosphor.identity.") + tag) ?? defaults
        identityTag = tag
    }

    static var keychainService: String {
        let base = isSandboxed ? "Phosphor room key (sandbox)" : name.map { "Phosphor room key (\($0))" } ?? "Phosphor room key"
        return identityTag.map { base + " [\($0)]" } ?? base
    }
}
