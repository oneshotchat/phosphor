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

    static let defaults: UserDefaults = name.flatMap { UserDefaults(suiteName: "Phosphor.profile.\($0)") } ?? .standard

    static var contactsURL: URL {
        IdentityFile.defaultURL.deletingLastPathComponent().appendingPathComponent(name.map { "contacts-\($0).json" } ?? "contacts.json")
    }

    static var keychainService: String { name.map { "Phosphor room key (\($0))" } ?? "Phosphor room key" }
}
