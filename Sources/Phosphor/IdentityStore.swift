import Foundation
import OSCCore

/// Your identities on this Mac: Phosphor's original (`Phosphor/default.identity`), the ones
/// made or imported here (`Phosphor/identities/*.identity`), and files you linked where
/// they are. Every file is the identity itself, so Phosphor only ever reads one to check
/// it or log in, writes them readable only by you, and never shows the private key.
///
/// Run as another identity (`PHOSPHOR_IDENTITY`, e.g. an agent's), Phosphor sees only that
/// one and changes nothing here.
@MainActor
enum IdentityStore {
    struct Entry: Equatable {
        var url: URL
        var fingerprint: String
        /// The name hint in the file (the server holds the real one).
        var name: String?
        /// Phosphor's original identity file.
        var isOriginal: Bool
        /// A file used where it is (linked), rather than kept in Phosphor's folder.
        var isLinked: Bool
        var isIncognito: Bool
        var lastUsed: Date?
    }

    static var folder: URL { IdentityFile.defaultURL.deletingLastPathComponent().appendingPathComponent("identities", isDirectory: true) }

    /// True when this run is pinned to one identity by `PHOSPHOR_IDENTITY`.
    static var isPinned: Bool { Profile.identityOverride != nil }

    private static let defaults = Profile.defaults

    static var linkedPaths: [String] {
        get { defaults.stringArray(forKey: "linkedIdentities") ?? [] }
        set { defaults.set(newValue, forKey: "linkedIdentities") }
    }
    private static var lastUsedTimes: [String: Date] {
        get { defaults.dictionary(forKey: "identityLastUsed") as? [String: Date] ?? [:] }
        set { defaults.set(newValue, forKey: "identityLastUsed") }
    }
    private static var incognito: Set<String> {
        get { Set(defaults.stringArray(forKey: "incognitoIdentities") ?? []) }
        set { defaults.set(Array(newValue), forKey: "incognitoIdentities") }
    }

    /// The identity to start with when there's a choice, if you've chosen one.
    static var defaultPath: String? {
        get { defaults.string(forKey: "defaultIdentity") }
        set { defaults.set(newValue, forKey: "defaultIdentity") }
    }

    /// Every usable identity, the original first, then by name.
    static func all() -> [Entry] {
        if let pinned = Profile.identityOverride { return [entry(pinned, linked: true)].compactMap { $0 } }
        var urls: [(URL, Bool)] = []
        if FileManager.default.fileExists(atPath: IdentityFile.defaultURL.path) { urls.append((IdentityFile.defaultURL, false)) }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        urls += files.filter { $0.pathExtension == "identity" }.sorted { $0.path < $1.path }.map { ($0, false) }
        // Linked files, and a file chosen before identities were managed here.
        var linked = linkedPaths
        if let old = defaults.string(forKey: "identityPath"), !old.hasPrefix(IdentityFile.defaultURL.deletingLastPathComponent().path),
           !linked.contains(old) { linked.append(old) }
        urls += linked.map { (URL(fileURLWithPath: $0), true) }
        var seen = Set<String>()
        return urls.compactMap { entry($0.0, linked: $0.1) }.filter { seen.insert($0.fingerprint).inserted }
            .sorted { a, b in
                if a.isOriginal != b.isOriginal { return a.isOriginal }
                return (a.name ?? "").lowercased() < (b.name ?? "").lowercased()
            }
    }

    private static func entry(_ url: URL, linked: Bool) -> Entry? {
        guard let file = try? IdentityFile.read(from: url), (try? file.load()) != nil else { return nil }
        return Entry(url: url, fingerprint: file.identity, name: file.name, isOriginal: url == IdentityFile.defaultURL,
                     isLinked: linked, isIncognito: incognito.contains(file.identity), lastUsed: lastUsedTimes[file.identity])
    }

    static func markUsed(_ fingerprint: String) { lastUsedTimes[fingerprint] = Date() }

    static func isIncognito(_ fingerprint: String) -> Bool { incognito.contains(fingerprint) }

    /// A new identity, kept in Phosphor's folder. Incognito ones are throwaway: the server
    /// forgets them after 24 hours unused.
    static func create(name: String, incognito wanted: Bool) throws -> Entry {
        let identity = Identity.generate()
        let url = folder.appendingPathComponent("\(identity.fingerprint.prefix(16)).identity")
        try IdentityFile(identity: identity, name: name).write(to: url)
        if wanted { incognito.insert(identity.fingerprint) }
        return entry(url, linked: false)!
    }

    enum ImportError: Error, CustomStringConvertible {
        case notAnIdentity, alreadyHere(String)
        var description: String {
            switch self {
            case .notAnIdentity: "that isn't a usable identity file (its key doesn't match its fingerprint, or it isn't one)"
            case .alreadyHere(let name): "that identity is already here (\(name))"
            }
        }
    }

    /// Checks a file (its private key must derive its fingerprint) and copies it into
    /// Phosphor's folder. The original is left where it is.
    static func importFile(_ source: URL) throws -> Entry {
        guard let file = try? IdentityFile.read(from: source), (try? file.load()) != nil else { throw ImportError.notAnIdentity }
        if let existing = all().first(where: { $0.fingerprint == file.identity }) {
            throw ImportError.alreadyHere(existing.name ?? String(file.identity.prefix(8)))
        }
        let url = folder.appendingPathComponent("\(file.identity.prefix(16)).identity")
        try file.write(to: url)
        return entry(url, linked: false)!
    }

    /// Writes a copy, readable only by you.
    static func export(_ entry: Entry, to url: URL) throws {
        try IdentityFile.read(from: entry.url).write(to: url)
    }

    /// Updates the name hint in the file (not in a linked file, which isn't Phosphor's).
    static func rename(_ entry: Entry, to name: String) {
        guard !entry.isLinked, var file = try? IdentityFile.read(from: entry.url), (try? file.load()) != nil else { return }
        file.name = name
        try? file.write(to: entry.url)
    }

    /// Removes it from this Mac: deletes a file in Phosphor's folder, forgets a linked one.
    static func remove(_ entry: Entry) throws {
        if entry.isLinked {
            linkedPaths.removeAll { $0 == entry.url.path }
            if defaults.string(forKey: "identityPath") == entry.url.path { defaults.removeObject(forKey: "identityPath") }
        } else {
            try FileManager.default.removeItem(at: entry.url)
        }
        incognito.remove(entry.fingerprint)
        if defaultPath == entry.url.path { defaultPath = nil }
    }

    static func link(_ url: URL) {
        if !linkedPaths.contains(url.path) { linkedPaths.append(url.path) }
    }
}
