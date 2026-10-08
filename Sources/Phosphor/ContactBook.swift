import Foundation
import OSCCore

/// People you've saved, by full fingerprint, with an optional petname: the protocol's way
/// to recognise someone over time, since names aren't unique and a tripcode is easy to
/// forge. Kept on this Mac only (Application Support/Phosphor/contacts.json); the server
/// never knows. In demo mode the book lives in memory, so made-up people never land in it.
@MainActor
final class ContactBook {
    static let shared = ContactBook()

    struct Contact: Codable, Equatable {
        var fingerprint: String
        /// What you call them; nil to use their own name.
        var petname: String?
        /// Their own name when last seen, for when they're nowhere to be seen now.
        var name: String?
        var added: Date
        var lastSeen: Date?
        var lastSeenRoom: String?
    }

    private(set) var contacts: [String: Contact] = [:]
    /// Bumped on every change, so cached text that shows names can be redrawn.
    private(set) var revision = 0
    private var inMemory = false

    static var fileURL: URL {
        IdentityFile.defaultURL.deletingLastPathComponent().appendingPathComponent("contacts.json")
    }

    private init() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let list = try? JSONDecoder.iso.decode([Contact].self, from: data) else { return }
        contacts = Dictionary(list.map { ($0.fingerprint, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Demo mode: start empty and never write to disk.
    func useInMemory(seed: [Contact] = []) {
        inMemory = true
        contacts = Dictionary(seed.map { ($0.fingerprint, $0) }, uniquingKeysWith: { a, _ in a })
        revision += 1
    }

    func contact(_ fingerprint: String) -> Contact? { contacts[fingerprint] }
    func isContact(_ fingerprint: String) -> Bool { contacts[fingerprint] != nil }

    /// How a person's name shows anywhere: their label (with its tripcode), then your
    /// petname in brackets if it's different, then the contact mark. "neo (Jared) ★".
    func display(_ fingerprint: String, label: String, name: String? = nil) -> String {
        guard let contact = contacts[fingerprint] else { return label }
        let own = name ?? String(label.split(separator: "#").first ?? Substring(label))     // without its tripcode
        if let pet = contact.petname, !pet.isEmpty, pet != own, pet != label { return "\(label) (\(pet)) ★" }
        return "\(label) ★"
    }

    /// Every label in a room's label map, decorated.
    func display(_ labels: [String: String]) -> [String: String] {
        guard !contacts.isEmpty else { return labels }
        var out = labels
        for (fp, label) in labels where contacts[fp] != nil { out[fp] = display(fp, label: label) }
        return out
    }

    /// Saves someone, or renames them if they're saved already (an empty petname clears it).
    func save(_ fingerprint: String, petname: String?, name: String?, seenIn room: String? = nil) {
        var contact = contacts[fingerprint] ?? Contact(fingerprint: fingerprint, added: Date())
        if let petname { contact.petname = petname.isEmpty ? nil : petname }
        if let name { contact.name = name }
        if let room {
            contact.lastSeen = Date()
            contact.lastSeenRoom = room
        }
        contacts[fingerprint] = contact
        changed()
    }

    func remove(_ fingerprint: String) {
        guard contacts.removeValue(forKey: fingerprint) != nil else { return }
        changed()
    }

    /// A contact was seen (present in a room, or speaking): when, where, and their name then.
    func saw(_ fingerprint: String, in room: String, name: String?) {
        guard var contact = contacts[fingerprint] else { return }
        let renamed = name != nil && name != contact.name
        // Rewrite the file at most once a minute for sightings alone.
        let stale = contact.lastSeen.map { -$0.timeIntervalSinceNow > 60 } ?? true
        guard renamed || stale || contact.lastSeenRoom != room else { return }
        contact.lastSeen = Date()
        contact.lastSeenRoom = room
        if let name { contact.name = name }
        contacts[fingerprint] = contact
        changed(redraw: renamed)
    }

    private func changed(redraw: Bool = true) {
        if redraw { revision += 1 }
        guard !inMemory else { return }
        let list = contacts.values.sorted { $0.added < $1.added }
        guard let data = try? JSONEncoder.iso.encode(list) else { return }
        try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

private extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
