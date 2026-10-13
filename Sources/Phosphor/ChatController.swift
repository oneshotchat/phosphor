import Foundation
import OSCCore
import QuartzCore

/// Seconds since launch; the one clock shared by animations and the renderer.
enum AppClock {
    private static let start = CACurrentMediaTime()
    static var now: Float { Float(CACurrentMediaTime() - start) }
}

/// The app's side of the chat: owns the session and the set of joined rooms (one of them
/// active), runs commands from the input line, tracks unread and mentions for the rooms
/// in the background, and keeps a short list of notices for the HUD.
@MainActor
final class ChatController {
    struct Notice {
        enum Kind { case info, error, server, mention }
        var kind: Kind
        var text: String
        var at: Float
    }

    struct Activity {
        var unread = 0
        var mentioned = false
    }

    /// Sent with every message: the same for every user (the protocol asks that nothing
    /// user-specific goes in it); the URL is the public repo.
    static let clientInfo = ClientInfo(name: "phosphor", version: "0.2.0", url: "https://github.com/oneshotchat/phosphor")

    private(set) var session: ChatSession?
    /// Joined rooms in order; ⌘1 is the first.
    private(set) var rooms: [String] = []
    private(set) var activeRoom: String?
    private(set) var activity: [String: Activity] = [:]
    private(set) var notices: [Notice] = []
    private(set) var displayName = "anon"
    /// Sign messages and edits by default (Phosphor → Sign Messages). A signature proves a
    /// message is yours and untouched, but it also can't be denied later.
    var signByDefault: Bool = Profile.identityDefaults.object(forKey: "signMessages") as? Bool ?? true {
        didSet { Profile.identityDefaults.set(signByDefault, forKey: "signMessages") }
    }
    /// Message the user has selected with the arrow keys; commands act on it.
    var focus: Int?

    /// Every applied event, by room, so that room's scene can animate.
    var onEvent: ((String, Event) -> Void)?
    /// A room's state was replaced wholesale; its scene should drop its animations.
    var onRoomReloaded: ((String) -> Void)?
    /// Your own message was sent or edited; the reply arrives before (or after) its live
    /// event, and either way the room animates it once.
    var onOwnMessage: ((String, Message, _ edited: Bool) -> Void)?
    /// The active room changed (old, new).
    var onActiveChanged: ((String?, String?) -> Void)?

    private(set) lazy var browser = RoomBrowser(controller: self)

    /// Every listed room from the public room browser, busiest first.
    private(set) var listed: [Room] = []

    /// Server admins, by fingerprint: from the server's discovery list (refreshed now and
    /// then) plus anyone marked admin in a room. Never from a name: anyone can take one.
    private var discoveredAdmins: Set<String> = []
    private var demoAdmins: Set<String> = []
    var admins: Set<String> {
        var all = discoveredAdmins.union(demoAdmins)
        for room in rooms { for o in state(room)?.occupants.values ?? [:].values where o.admin == true { all.insert(o.identity) } }
        return all
    }
    func isAdmin(_ fingerprint: String) -> Bool { admins.contains(fingerprint) }
    private var listedAt: Date?
    /// Listed rooms you haven't joined.
    var unjoinedListed: [Room] { listed.filter { !rooms.contains($0.id) } }

    /// Offline scripted rooms (`--demo`); when present they replace the session entirely.
    private var demos: [String: DemoFeed] = [:]
    private var demoMe: String?
    private var demoName = "you"

    func state(_ room: String) -> RoomState? { demos[room]?.state ?? session?.rooms[room] }
    var state: RoomState? { activeRoom.flatMap(state) }

    /// Operator here (or a server admin), so operator commands are worth suggesting.
    var isOperator: Bool { state?.role == .operator || state?.occupants[me]?.admin == true }

    /// What the help panel shows: everything (⌘/, `/help`) or one topic; nil when closed.
    enum HelpView: Equatable { case all, topic(Help.Topic) }
    var help: HelpView? {
        didSet { if help != nil { showingRoomInfo = false; showingContacts = false; showingIdentities = false } }
    }

    /// The room info walls (/room, ⌘I): the room's settings, and beside it its people.
    /// Only one wall view at a time: it replaces help.
    var showingRoomInfo = false {
        didSet {
            if !showingRoomInfo { contactPrompt = nil }
            guard showingRoomInfo else { return }
            help = nil
            showingContacts = false
            showingIdentities = false
            if !oldValue { infoPage = 0; selectedPerson = nil }
            if let activeRoom { refreshRoles(activeRoom) }
        }
    }
    /// 0: the room, 1: its people.
    var infoPage = 0

    // MARK: contacts

    /// The contacts wall (⌘K, /contacts): yours, not the room's, so it stands alone.
    var showingContacts = false {
        didSet {
            if !showingContacts { contactPrompt = nil }
            guard showingContacts else { return }
            help = nil
            showingRoomInfo = false
            showingIdentities = false
            if !oldValue { selectedContact = nil; contactsPage = 0; selectedPlace = nil }
            noteSightings()
            lookUp(ContactBook.shared.contacts.values.filter { $0.name == nil }.map(\.fingerprint))
        }
    }
    var selectedContact: String? {
        didSet {
            guard selectedContact != oldValue else { return }
            contactPrompt = nil
            selectedPlace = nil
            if selectedContact == nil { contactsPage = 0 }      // their wall needs someone
        }
    }

    /// One row of the contacts wall.
    struct ContactRow: Equatable {
        var identity: String
        var label: String
        var petname: String?
        /// Where they are now, as far as we can know: rooms you're in, then listed rooms.
        var whereNow: [String]
        var lastSeen: String?
        var lastSeenRoom: String?
        var isAdmin = false
    }

    /// Everyone saved, alphabetically by what you call them (petname, else name): a
    /// steady order, so rows don't jump about as people come and go.
    var contactRows: [ContactRow] {
        let book = ContactBook.shared
        return book.contacts.values.map { c in
            let name = c.name ?? identities[c.fingerprint]?.name ?? String(c.fingerprint.prefix(8))
            let whereNow = roomsWith(c.fingerprint)
            return ContactRow(identity: c.fingerprint, label: book.display(c.fingerprint, label: SafeText.clean(name)),
                              petname: c.petname, whereNow: whereNow,
                              lastSeen: whereNow.isEmpty ? c.lastSeen.map { RoomInfo.ago(-$0.timeIntervalSinceNow) } : "now",
                              lastSeenRoom: c.lastSeenRoom, isAdmin: isAdmin(c.fingerprint))
        }
        .sorted { a, b in
            let x = (a.petname ?? book.contact(a.identity)?.name ?? a.label).lowercased()
            let y = (b.petname ?? book.contact(b.identity)?.name ?? b.label).lowercased()
            return x != y ? x < y : a.identity < b.identity
        }
    }

    /// A room someone is in, as the person wall lists it.
    struct Place: Equatable {
        var id: String
        var name: String
        /// One of your rooms, or a listed room you're not in.
        var yours: Bool
        var access: String?
        var people: Int
        /// When they last spoke there, from the loaded history (your rooms only).
        var lastSpoke: String?
        /// Your side room with them.
        var isSide = false
        var shown: String { isSide ? "side room" : "#" + name + (yours ? "" : " (listed)") }
    }

    /// Rooms someone is in that we can see: the ones you're in (the one you're looking at
    /// first), then listed rooms, whose occupants the public listing shows. Unlisted rooms
    /// you aren't in can't be seen.
    func places(of fingerprint: String) -> [Place] {
        var found: [Place] = []
        var seen = Set<String>()
        let mine = rooms.filter { $0 == activeRoom } + rooms.filter { $0 != activeRoom }
        for room in mine {
            guard let s = state(room), s.occupants[fingerprint] != nil else { continue }
            let spoke = s.orderedMessages.last { $0.author.identity == fingerprint }?.createdAt
            found.append(Place(id: s.room.id, name: SafeText.clean(s.room.name), yours: true, access: s.room.access,
                               people: s.occupants.count, lastSpoke: spoke.map { RoomInfo.ago(-$0.timeIntervalSinceNow) },
                               isSide: s.room.isSide))
            seen.insert(s.room.id)
        }
        for room in listed where !seen.contains(room.id) && room.occupants?.contains(where: { $0.identity == fingerprint }) == true {
            found.append(Place(id: room.id, name: SafeText.clean(room.name), yours: false, access: room.access,
                               people: room.occupantCount ?? room.occupants?.count ?? 0, lastSpoke: nil))
        }
        return found
    }

    func roomsWith(_ fingerprint: String) -> [String] { places(of: fingerprint).map(\.shown) }

    /// The picked contact's own wall, if someone's picked.
    var contactCard: RoomInfoScene.Card? {
        guard let fp = selectedContact, let row = contactRows.first(where: { $0.identity == fp }),
              let contact = ContactBook.shared.contact(fp) else { return nil }
        return RoomInfoScene.Card(row: row, added: contact.added, status: identities[fp]?.status, places: places(of: fp))
    }

    /// The contacts walls: 0 your contacts, 1 the picked contact's own wall.
    var contactsPage = 0
    /// The room picked on a contact's wall (by room id).
    var selectedPlace: String?

    /// ←→ on the contacts walls; the contact's wall needs someone picked.
    func pageContacts(_ delta: Int) {
        if delta > 0, selectedContact == nil { return note(.info, "pick someone first (↑↓)") }
        contactsPage = max(0, min(1, contactsPage + delta))
        if contactsPage == 0 { selectedPlace = nil }
    }

    func movePlaceSelection(_ delta: Int) {
        guard let fp = selectedContact else { return }
        let list = places(of: fp)
        guard !list.isEmpty else { return }
        let i = list.firstIndex { $0.id == selectedPlace }.map { $0 + delta } ?? (delta > 0 ? 0 : list.count - 1)
        selectedPlace = list.indices.contains(i) ? list[i].id : nil
    }

    /// Return on a room on a contact's wall: go there (switching to it, or joining a
    /// listed room, asking for a key or invite code if it needs one).
    func goToPlace() {
        guard let fp = selectedContact, let place = places(of: fp).first(where: { $0.id == selectedPlace }) else { return }
        showingContacts = false
        if place.yours { return activate(place.id) }
        let target = RoomBrowser.Target(name: place.name, id: place.id)
        Task {
            switch await joinFromBrowser(target, key: RoomKeychain.key(for: place.id), invite: nil) {
            case .needsKey: browser.ask(.key(target, wrong: false))
            case .needsInvite: browser.ask(.invite(target, wrong: false))
            case .joined, .failed: break
            }
        }
    }

    /// Records where contacts are seen, so "last seen" means something later.
    func noteSightings() {
        let book = ContactBook.shared
        guard !book.contacts.isEmpty else { return }
        for room in rooms {
            guard let s = state(room) else { continue }
            for o in s.occupants.values where book.isContact(o.identity) { book.saw(o.identity, in: "#" + s.room.name, name: o.name) }
        }
        for room in listed {
            for o in room.occupants ?? [] where book.isContact(o.identity) { book.saw(o.identity, in: "#" + room.name, name: o.name) }
        }
    }

    func moveContactSelection(_ delta: Int) {
        let rows = contactRows
        guard !rows.isEmpty else { return }
        let i = rows.firstIndex { $0.identity == selectedContact }.map { $0 + delta } ?? (delta > 0 ? 0 : rows.count - 1)
        selectedContact = rows.indices.contains(i) ? rows[i].identity : nil
        if let selectedContact { lookUp([selectedContact]) }
    }

    /// Renaming or removing a contact right on the walls: the input line asks, Return
    /// answers, Esc cancels.
    enum ContactPrompt: Equatable {
        case rename(String, label: String)
        case remove(String, label: String)
        /// Deleting a message: yours, or (as an operator or admin) someone else's.
        case deleteMessage(Message, reason: String?, whose: String)
        /// The first message of a side room you're opening (the room is made when it's sent).
        case sideFirstMessage(String, label: String, warned: Bool)
        /// Someone opened a side room with you: join it?
        case joinSide(String, from: String, label: String, preview: String)
        /// Closing the side room you're in, for both of you.
        case closeSide(String, label: String)
        /// Identities: a new one's name; exporting (warn first); removing one.
        case newIdentity(incognito: Bool)
        /// A custom server's address.
        case addServer
        case exportIdentity(String, label: String)
        case removeIdentity(String, label: String, linked: Bool)

        var isIdentityPrompt: Bool {
            switch self {
            case .newIdentity, .exportIdentity, .removeIdentity: true
            default: false
            }
        }

        var prompt: String {
            switch self {
            case .rename(_, let label): "petname for \(label) › "
            case .remove(_, let label): "remove \(label) from contacts?  ⏎ yes · esc no "
            case .deleteMessage(let m, _, let whose):
                "delete \(whose) message [\(m.id)]? it can't be undone, and people may have seen it  ⏎ yes · esc no "
            case .sideFirstMessage(_, let label, _): "first message to \(label), in a side room › "
            case .joinSide(_, _, let label, let preview):
                "\(label) opened a side room with you: “\(preview)”  ⏎ join · esc later "
            case .closeSide(_, let label):
                "close the side room with \(label)? it's deleted for both of you, with everything in it  ⏎ yes · esc no "
            case .newIdentity(let incognito): "name for the new\(incognito ? " incognito" : "") identity › "
            case .addServer: "server address (e.g. https://api.example.com) › "
            case .exportIdentity(_, let label):
                "export \(label)? the file IS that identity: anyone with it can speak as it  ⏎ choose where · esc no "
            case .removeIdentity(_, let label, let linked):
                linked ? "forget the linked file for \(label)? the file stays where it is  ⏎ yes · esc no "
                    : "delete \(label) from this Mac? without an exported copy it's gone for good  ⏎ yes · esc no "
            }
        }

        /// A yes/no question: typing is ignored, only ⏎ or esc answer it.
        var isQuestion: Bool {
            switch self {
            case .rename, .sideFirstMessage, .newIdentity, .addServer: false
            case .remove, .deleteMessage, .joinSide, .closeSide, .exportIdentity, .removeIdentity: true
            }
        }
    }
    var contactPrompt: ContactPrompt?

    /// The person picked on whichever wall is up: contacts, or a room's people.
    private var pickedPerson: String? {
        if showingContacts { return selectedContact }
        if showingRoomInfo, infoPage == 1 { return selectedPerson }
        return nil
    }

    private func plainName(_ fp: String) -> String {
        let name = rooms.lazy.compactMap { self.state($0)?.occupants[fp]?.name }.first
            ?? ContactBook.shared.contact(fp)?.name ?? identities[fp]?.name
            ?? state?.orderedMessages.last(where: { $0.author.identity == fp })?.author.name
        return SafeText.clean(name ?? String(fp.prefix(8)))
    }

    /// Return on a picked person: name them (saving them first if they aren't a contact).
    /// Gives the text to start the input with: their current petname.
    func startRename() -> String? {
        guard let fp = pickedPerson else { return nil }
        if !ContactBook.shared.isContact(fp) { saveContact(fp, petname: nil, quietly: true) }
        contactPrompt = .rename(fp, label: plainName(fp))
        return ContactBook.shared.contact(fp)?.petname ?? ""
    }

    /// ⌘⌫ on a picked contact: ask before forgetting them.
    func askRemove() {
        guard let fp = pickedPerson, ContactBook.shared.isContact(fp) else {
            return note(.info, showingContacts || showingRoomInfo ? "pick a contact first (↑↓)" : "open your contacts (⌘K) and pick someone")
        }
        contactPrompt = .remove(fp, label: plainName(fp))
    }

    /// Return in a contact prompt.
    func answerContactPrompt(_ text: String, labels: [String: String] = [:]) {
        guard let prompt = contactPrompt else { return }
        switch prompt {
        case .sideFirstMessage(let fp, let label, let warned):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            // The mention is the notification: say so (once) if they took it out.
            let composed = MentionText.compose(text, labels: labels.merging([label: fp]) { _, new in new })
            if !composed.contains("<@\(fp)>"), !warned {
                contactPrompt = .sideFirstMessage(fp, label: label, warned: true)
                return note(.info, "\(label) won't be told about it without @\(label) · ⏎ again to send anyway")
            }
            contactPrompt = nil
            Task { await openSide(with: fp, first: composed) }
        case .joinSide(_, let fp, _, _):
            contactPrompt = nil
            Task { await joinSide(with: fp) }
        case .addServer:
            contactPrompt = nil
            serverCommand("add " + text)
        case .newIdentity(let incognito):
            let name = text.trimmingCharacters(in: .whitespaces)
            if let problem = DisplayName.problem(name) { return note(.error, problem) }
            contactPrompt = nil
            createIdentity(name: name, incognito: incognito)
        case .exportIdentity(let path, let label):
            contactPrompt = nil
            guard let entry = IdentityStore.all().first(where: { $0.url.path == path }) else { return }
            pickFile?("\(label).identity") { [weak self] url in
                guard let self, let url else { return }
                do {
                    try IdentityStore.export(entry, to: url)
                    self.note(.info, "exported \(label) to \(url.lastPathComponent): keep it like a password")
                } catch { self.note(.error, "couldn't export: \(error)") }
            }
        case .removeIdentity(let path, let label, _):
            contactPrompt = nil
            guard let entry = IdentityStore.all().first(where: { $0.url.path == path }) else { return }
            do {
                try IdentityStore.remove(entry)
                selectedIdentity = identityRows.first?.path
                note(.info, "\(label) removed from this Mac")
            } catch { note(.error, "couldn't remove it: \(error)") }
        case .closeSide(let room, _):
            contactPrompt = nil
            Task {
                do { try await session?.client.close(room: room) } catch let error as OSCError {
                    note(.error, "couldn't close it: \(error.message)")
                } catch { note(.error, "couldn't close it: \(error)") }
            }
        case .rename(let fp, _):
            let petname = text.trimmingCharacters(in: .whitespaces)
            if let problem = petname.isEmpty ? nil : DisplayName.problem(petname) { return note(.error, "petname: \(problem)") }
            contactPrompt = nil
            saveContact(fp, petname: petname)
        case .remove(let fp, _):
            contactPrompt = nil
            ContactBook.shared.remove(fp)
            if selectedContact == fp { selectedContact = nil }
            note(.info, "\(plainName(fp)) removed from contacts")
        case .deleteMessage(let m, let reason, _):
            contactPrompt = nil
            if focus == m.id { focus = nil }
            if let feed = demos[m.room] { return feed.delete(m.id, by: me, reason: reason) }
            Task {
                do {
                    try await session?.delete(m, reason: reason)
                    note(.info, "message [\(m.id)] deleted")
                } catch let error as OSCError {
                    note(.error, "couldn't delete [\(m.id)]: \(error.message)")
                } catch {
                    note(.error, "couldn't delete [\(m.id)]: \(error)")
                }
            }
        }
    }

    // MARK: identities

    /// The identities wall (⇧⌘I, /identity): yours, on this Mac.
    var showingIdentities = false {
        didSet {
            if !showingIdentities { if contactPrompt?.isIdentityPrompt == true { contactPrompt = nil } }
            guard showingIdentities else { return }
            if browser.isOpen { browser.close() }
            help = nil
            showingRoomInfo = false
            showingContacts = false
            if !oldValue { selectedIdentity = identityRows.first { $0.inUse }?.path ?? identityRows.first?.path }
        }
    }
    var selectedIdentity: String?
    /// Choosing which identity to start with: the room and server start() is waiting for.
    private(set) var choosingAtLaunch: (room: String?, server: URL)?

    /// File panels, from the app (open for import, save for export with a suggested name).
    var pickFile: ((_ saveAs: String?, _ done: @escaping @MainActor (URL?) -> Void) -> Void)?

    struct IdentityRow: Equatable {
        var path: String
        var fingerprint: String
        var label: String
        var inUse: Bool
        var notes: [String]
        var lastUsed: String?
    }

    var identityRows: [IdentityRow] {
        let current = choosingAtLaunch == nil ? identityURL.path : nil
        return IdentityStore.all().map { e in
            let inUse = e.url.path == current
            var notes: [String] = []
            if inUse { notes.append("in use") }
            if IdentityStore.defaultPath == e.url.path { notes.append("default") }
            if e.isIncognito { notes.append("incognito") }
            if e.isLinked { notes.append("linked file") }
            let name = inUse && demoMe == nil ? displayName : (e.name ?? DisplayName.unset)
            return IdentityRow(path: e.url.path, fingerprint: e.fingerprint, label: SafeText.clean(name), inUse: inUse, notes: notes,
                               lastUsed: e.lastUsed.map { RoomInfo.ago(-$0.timeIntervalSinceNow) })
        }
    }

    func moveIdentitySelection(_ delta: Int) {
        let rows = identityRows
        guard !rows.isEmpty else { return }
        let i = rows.firstIndex { $0.path == selectedIdentity }.map { $0 + delta } ?? 0
        selectedIdentity = rows[max(0, min(rows.count - 1, i))].path
    }

    private var pickedIdentity: IdentityStore.Entry? {
        IdentityStore.all().first { $0.url.path == selectedIdentity }
    }

    /// At launch with more than one identity and no default: ask which, then start.
    func chooseIdentityAtLaunch(room: String?, server: URL) {
        choosingAtLaunch = (room, server)
        showingIdentities = true
        note(.info, "which identity? ↑↓ pick · ⏎ use it · /identity default to stop asking")
    }

    /// ⏎ on the identities wall: start as, or switch to, the picked identity.
    func useSelectedIdentity() {
        guard let entry = pickedIdentity else { return }
        if let launch = choosingAtLaunch {
            choosingAtLaunch = nil
            Profile.defaults.set(entry.url.path, forKey: "identityPath")
            showingIdentities = false
            return start(room: launch.room, server: launch.server)
        }
        guard entry.url.path != identityURL.path else { return note(.info, "you're already using it") }
        showingIdentities = false
        useIdentity(at: entry.url)
    }

    /// `/identity [new [name] [incognito] | import | export | rename name | remove | default]`.
    private func identityCommand(_ rest: String) {
        let (verb, more) = split(rest.trimmingCharacters(in: .whitespaces))
        if verb.isEmpty { return showingIdentities = true }
        if IdentityStore.isPinned { return note(.error, "this Phosphor is pinned to one identity (PHOSPHOR_IDENTITY)") }
        switch verb {
        case "new":
            var words = more.split(separator: " ").map(String.init)
            let incognito = words.last == "incognito"
            if incognito { words.removeLast() }
            let name = words.joined(separator: " ")
            showingIdentities = true
            if name.isEmpty { return contactPrompt = .newIdentity(incognito: incognito) }
            createIdentity(name: name, incognito: incognito)
        case "import":
            pickFile?(nil) { [weak self] url in
                guard let self, let url else { return }
                do {
                    let entry = try IdentityStore.importFile(url)
                    self.showingIdentities = true
                    self.selectedIdentity = entry.url.path
                    self.note(.info, "imported \(SafeText.clean(entry.name ?? String(entry.fingerprint.prefix(8)))) · ⏎ to use it")
                } catch {
                    self.note(.error, "\(error)")
                }
            }
        case "export", "rename", "remove", "default":
            guard showingIdentities, let entry = pickedIdentity else {
                showingIdentities = true
                return note(.info, "pick one (↑↓), then /identity \(verb)\(verb == "rename" ? " name" : "")")
            }
            let label = SafeText.clean(entry.name ?? String(entry.fingerprint.prefix(8)))
            switch verb {
            case "export": contactPrompt = .exportIdentity(entry.url.path, label: label)
            case "rename":
                let name = more.trimmingCharacters(in: .whitespaces)
                if let problem = DisplayName.problem(name) { return note(.error, name.isEmpty ? "/identity rename name" : problem) }
                renameIdentity(entry, to: name)
            case "remove":
                if entry.url.path == identityURL.path, choosingAtLaunch == nil { return note(.error, "switch to another identity first") }
                if entry.isOriginal { return note(.error, "that's Phosphor's original identity; it stays (export it to keep a copy elsewhere)") }
                contactPrompt = .removeIdentity(entry.url.path, label: label, linked: entry.isLinked)
            default:
                IdentityStore.defaultPath = IdentityStore.defaultPath == entry.url.path ? nil : entry.url.path
                note(.info, IdentityStore.defaultPath == nil ? "no default: Phosphor asks at launch" : "\(label) is the default at launch (hold ⌥ while opening to choose)")
            }
        default:
            note(.error, "/identity new [name] [incognito] · import · export · rename name · remove · default")
        }
    }

    private func createIdentity(name: String, incognito: Bool) {
        if let problem = DisplayName.problem(name) { return note(.error, problem) }
        do {
            let entry = try IdentityStore.create(name: name, incognito: incognito)
            selectedIdentity = entry.url.path
            note(.info, "made \(SafeText.clean(name))\(incognito ? " (incognito: gone after 24 hours unused)" : "") · ⏎ to use it · /identity export to keep a copy")
        } catch {
            note(.error, "couldn't make it: \(error)")
        }
    }

    private func renameIdentity(_ entry: IdentityStore.Entry, to name: String) {
        if entry.url.path == identityURL.path, choosingAtLaunch == nil, demoMe == nil {
            Task {
                do {
                    try await session?.client.setName(name)
                    displayName = name
                    rememberName(name)
                    note(.info, "you're \(SafeText.clean(name))")
                } catch { note(.error, "couldn't rename: \(error)") }
            }
        } else if entry.isLinked {
            note(.error, "a linked file is left as it is: use it, then /nick")
        } else {
            IdentityStore.rename(entry, to: name)
            note(.info, "renamed: the server learns it next time you use it")
        }
    }

    // MARK: side rooms

    /// Text for the input line after a command: the side room prompt's ready-made mention.
    private(set) var pendingInput: String?
    func takePendingInput() -> String? { defer { pendingInput = nil } ; return pendingInput }
    /// Whether the input line is empty, so an offer can take it over without
    /// interrupting what someone's typing.
    var inputEmpty = true

    /// Side rooms you've been offered (room name, who opened it), newest last.
    private var sideOffers: [(room: String, from: String)] = []
    /// The conformance bot counts as a contact for side rooms (its `!side` test).
    private var conformanceBot: String?
    /// Who each side room you're in is with, kept for when it closes.
    private var sideWith: [String: String] = [:]

    /// How a room is named on screen: "#lobby", or "side room · neo".
    func title(_ room: Room) -> String {
        guard room.isSide, let other = SideRoom.other(in: room, me: me) else { return "#" + SafeText.clean(room.name) }
        return "side room · " + personLabel(other)
    }

    /// Someone's name as shown, with your petname if they're a contact.
    func personLabel(_ fp: String) -> String {
        let name = plainName(fp)
        return ContactBook.shared.display(fp, label: name, name: name)
    }

    /// `/side @who`, or with someone picked on a people or contacts wall: start a side
    /// room with them, beginning with its first message (the input fills with a mention
    /// of them, which you can see and change). `/side` alone joins the last one you were
    /// offered.
    private func sideCommand(_ rest: String, labels: [String: String]) {
        let arg = rest.trimmingCharacters(in: .whitespaces)
        var target: String?
        if arg.hasPrefix("@") {
            guard let fp = labels[String(arg.dropFirst())] else { return note(.error, "no one called \(arg) here (type @ to pick someone)") }
            target = fp
        } else if Identity.isFingerprint(arg) {
            target = arg
        } else if arg.isEmpty {
            target = pickedPerson
            if target == nil, let offer = sideOffers.last {
                Task { await self.joinSide(with: offer.from) }
                return
            }
        }
        guard let fp = target else { return note(.error, "/side @who, or pick someone on a people or contacts wall first") }
        guard fp != me else { return note(.error, "a side room needs someone else") }
        let label = plainName(fp)
        contactPrompt = .sideFirstMessage(fp, label: label, warned: false)
        pendingInput = "@" + label + " "
    }

    /// Joins, creating it if needed, the side room for you and `other`, after checking
    /// it's a proper one. Returns its state, or nil (having said why).
    private func enterSide(with other: String, create: Bool) async -> RoomState? {
        guard let session else { return nil }
        let name = SideRoom.name(me, other, server: origin)
        if let existing = rooms.first(where: { state($0)?.room.name == name }), let state = state(existing) {
            activate(existing)
            return state
        }
        // Check before joining: if it exists, it must be the two of you.
        if let found = try? await session.client.room(named: name), !SideRoom.isProper(found, me: me, other: other, server: origin) {
            note(.error, "this isn't a proper side room, so Phosphor won't join it")
            return nil
        }
        do {
            let state = try await session.join(name, create: create ? .side(with: other) : nil)
            guard SideRoom.isProper(state.room, me: me, other: other, server: origin) else {
                try? await session.leave(state.id)
                note(.error, "this isn't a proper side room, so Phosphor left it")
                return nil
            }
            sideWith[state.id] = other
            sideOffers.removeAll { $0.room == name }
            if case .joinSide = contactPrompt { contactPrompt = nil }
            knownRooms[name] = state.id
            if !rooms.contains(state.id) { rooms.append(state.id) }
            activate(state.id)
            persist()
            return state
        } catch let error as OSCError where error.code == "room_not_found" {
            note(.error, "that side room isn't there any more")
        } catch let error as OSCError {
            note(.error, "side room: \(error.message)")
        } catch {
            note(.error, "side room: \(error)")
        }
        return nil
    }

    private func openSide(with other: String, first text: String) async {
        guard let state = await enterSide(with: other, create: true) else { return }
        do {
            if let sent = try await session?.send(text, to: state.id, sign: signByDefault) { onOwnMessage?(state.id, sent, false) }
            note(.info, "side room with \(personLabel(other)): the server operator can read it, like any room · it closes after 7 days with nobody in it · either of you can /close it")
        } catch let error as OSCError {
            note(.error, "couldn't send the first message: \(error.message)")
        } catch {
            note(.error, "couldn't send the first message: \(error)")
        }
    }

    private func joinSide(with other: String) async {
        guard await enterSide(with: other, create: false) != nil else { return }
        note(.info, "side room with \(personLabel(other)) · it closes after 7 days with nobody in it · either of you can /close it")
    }

    /// A mention from a room you're not in: a side room offer if the room is the side room
    /// for you and its author, and they're a contact (or the conformance bot). Never joins
    /// by itself.
    private func offerIfSide(_ item: MentionItem) -> Bool {
        let author = item.message.author.identity
        guard item.room.name.hasPrefix("side-"), author != me,
              SideRoom.name(me, author, server: origin) == item.room.name,
              ContactBook.shared.isContact(author) || author == conformanceBot else { return false }
        offerSide(room: item.room.name, from: author,
                  preview: SafeText.clean(MentionText.display(item.message.text) { self.plainName($0) }))
        return true
    }

    private func offerSide(room: String, from: String, preview: String) {
        if !sideOffers.contains(where: { $0.room == room }) { sideOffers.append((room, from)) }
        var short = preview.replacingOccurrences(of: "\n", with: " ")
        if short.count > 60 { short = String(short.prefix(59)) + "…" }
        if contactPrompt == nil, inputEmpty, !browser.isOpen {
            contactPrompt = .joinSide(room, from: from, label: personLabel(from), preview: short)
        } else {
            note(.mention, "\(personLabel(from)) opened a side room with you · /side to join")
        }
    }

    /// At launch: any contact's side room that's open, in case its first message expired.
    private func lookForContactsSideRooms() async {
        guard let session else { return }
        for contact in ContactBook.shared.contacts.keys.prefix(50) {
            let name = SideRoom.name(me, contact, server: origin)
            guard !rooms.contains(where: { state($0)?.room.name == name }),
                  let room = try? await session.client.room(named: name),
                  SideRoom.isProper(room, me: me, other: contact, server: origin) else { continue }
            if !sideOffers.contains(where: { $0.room == name }) { sideOffers.append((name, contact)) }
            note(.mention, "\(personLabel(contact)) has a side room open with you · /side to join")
        }
    }

    /// `/close`: in a side room, close it for both of you (asks first).
    private func closeCommand() {
        guard let state, state.room.isSide, let other = SideRoom.other(in: state.room, me: me) else {
            return note(.error, "/close is for side rooms; to leave a room, /leave")
        }
        contactPrompt = .closeSide(state.id, label: personLabel(other))
    }

    /// `/delete [id] [reason]` or ⌘⌫: the given message, else the selected one, else your
    /// latest. Asks before deleting. Yours always; anyone's as an operator or admin.
    func askDelete(_ args: String) {
        guard let state else { return note(.error, "not in a room") }
        let (first, more) = split(args.trimmingCharacters(in: .whitespaces))
        let byID = Int(first).flatMap { state.messages[$0] }
        if Int(first) != nil, byID == nil { return note(.error, "no message [\(first)] here (it may have expired)") }
        let target = byID ?? focus.flatMap { state.messages[$0] }
            ?? state.orderedMessages.last { $0.author.identity == me && !$0.isDeleted }
        guard let target else { return note(.error, "no message to delete: select one (↑↓) or give its number") }
        guard !target.isDeleted else { return note(.info, "[\(target.id)] is already deleted") }
        let mine = target.author.identity == me
        guard mine || isOperator else { return note(.error, "only its author, an operator or a server admin can delete it") }
        let reason = (byID != nil ? more : args).trimmingCharacters(in: .whitespaces)
        if reason.utf8.count > 200 { return note(.error, "a reason can be 200 bytes at most") }
        let whose = mine ? "your" : SafeText.clean(state.labels[target.author.identity] ?? target.author.name) + "'s"
        contactPrompt = .deleteMessage(target, reason: reason.isEmpty ? nil : reason, whose: whose)
    }

    /// ⌘S on the people wall: save the selected person (no petname yet).
    func saveSelectedPerson() {
        guard showingRoomInfo, infoPage == 1, let fp = selectedPerson else {
            return note(.info, "pick someone on a room's people wall (⌘I, then →) to save them")
        }
        saveContact(fp, petname: nil)
    }

    private func saveContact(_ fp: String, petname: String?, quietly: Bool = false) {
        let occupant = rooms.lazy.compactMap { self.state($0)?.occupants[fp] }.first
        let name = occupant?.name ?? identities[fp]?.name ?? state?.orderedMessages.last(where: { $0.author.identity == fp })?.author.name
        let known = ContactBook.shared.isContact(fp)
        ContactBook.shared.save(fp, petname: petname, name: name, seenIn: occupant != nil ? state.map { "#" + $0.room.name } : nil)
        let shown = SafeText.clean(name ?? String(fp.prefix(8)))
        if quietly { return }
        if let petname, !petname.isEmpty {
            note(.info, "\(shown) saved as \(SafeText.clean(petname))")
        } else {
            note(.info, known ? "\(shown): no petname" : "\(shown) saved as a contact · ⏎ on them gives a petname")
        }
    }

    /// `/contact [@who | fingerprint] [petname]` and `/uncontact [@who | fingerprint]`.
    /// Without @who, the person picked on the people or contacts wall.
    private func contactCommand(_ head: String, _ rest: String, labels: [String: String]) {
        let (first, more) = split(rest.trimmingCharacters(in: .whitespaces))
        var target: String?
        var petname = rest.trimmingCharacters(in: .whitespaces)
        if first.hasPrefix("@") {
            let label = String(first.dropFirst())
            guard let fp = labels[label] else { return note(.error, "no one called @\(label) here (type @ to pick someone)") }
            target = fp
            petname = more
        } else if Identity.isFingerprint(first) {
            target = first
            petname = more
        } else if showingContacts, let selectedContact {
            target = selectedContact
        } else if showingRoomInfo, infoPage == 1, let selectedPerson {
            target = selectedPerson
        }
        guard let target else {
            return note(.error, "\(head) @who\(head == "/contact" ? " [petname]" : ""), or pick someone on a people wall first")
        }
        if head == "/uncontact" {
            guard ContactBook.shared.isContact(target) else { return note(.error, "they aren't a contact") }
            ContactBook.shared.remove(target)
            if selectedContact == target { selectedContact = nil }
            return note(.info, "contact removed")
        }
        if let problem = petname.isEmpty ? nil : DisplayName.problem(petname) { return note(.error, "petname: \(problem)") }
        saveContact(target, petname: petname)
    }

    /// ←→ on the info walls.
    func pageInfo(_ delta: Int) { infoPage = max(0, min(1, infoPage + delta)) }

    /// The person picked with ↑↓ on the people wall: their full fingerprint shows, and
    /// ⌘C copies it.
    var selectedPerson: String? { didSet { if selectedPerson != oldValue { contactPrompt = nil } } }

    func movePersonSelection(_ delta: Int) {
        guard let people = roomInfo?.everyone, !people.isEmpty else { return }
        let i = people.firstIndex { $0.identity == selectedPerson }.map { $0 + delta } ?? (delta > 0 ? 0 : people.count - 1)
        selectedPerson = people.indices.contains(i) ? people[i].identity : nil
        if let selectedPerson { lookUp([selectedPerson]) }        // for their status
    }

    /// The fingerprint ⌘C copies with the info walls up: the selected person's, else the room's.
    var fingerprintToCopy: String? {
        if showingContacts { return selectedContact }
        if showingIdentities { return identityRows.first { $0.path == selectedIdentity }?.fingerprint }
        guard showingRoomInfo, let info = roomInfo else { return nil }
        if infoPage == 1, let selectedPerson { return selectedPerson }
        return info.roomID
    }

    /// Names and statuses looked up by fingerprint (GET /v1/identities), kept for the session.
    private var identities: [String: IdentityInfo] = [:]
    /// Looked-up statuses (`active`, `retired`) by fingerprint.
    var identityStatuses: [String: String] { identities.compactMapValues(\.status) }
    private var lookingUp: Set<String> = []

    private func lookUp(_ fingerprints: [String]) {
        guard demoMe == nil, let client = session?.client else { return }
        for fp in fingerprints where identities[fp] == nil && !lookingUp.contains(fp) {
            lookingUp.insert(fp)
            Task {
                if let info = try? await client.identity(fp) {
                    identities[fp] = info
                    if let name = info.name, ContactBook.shared.isContact(fp), ContactBook.shared.contact(fp)?.name == nil {
                        ContactBook.shared.save(fp, petname: nil, name: name)
                    }
                }
                lookingUp.remove(fp)
            }
        }
    }

    /// Each room's role listing, fetched when its info wall opens and when a role changes.
    private var roomRoles: [String: [RoleEntry]] = [:]

    private func refreshRoles(_ room: String) {
        guard demoMe == nil, let client = session?.client else { return }
        Task {
            guard let roles = try? await client.roles(room: room) else { return }
            roomRoles[room] = roles
            // People with a role who aren't here may have no name we know: ask.
            let known = Set(state(room)?.occupants.keys.map { $0 } ?? []).union(state(room)?.orderedMessages.map(\.author.identity) ?? [])
            lookUp(roles.filter { $0.name == nil && !known.contains($0.identity) }.map(\.identity))
        }
    }

    /// What the info walls show for the active room.
    var roomInfo: RoomInfo? {
        guard let state, let activeRoom else { return nil }
        return RoomInfo(state: state, me: me, myName: displayName, signing: signByDefault, isOperator: isOperator,
                        roles: roomRoles[activeRoom] ?? demos[activeRoom]?.roles, identities: identities, admins: admins,
                        title: title(state.room))
    }

    /// ←→ in help: the next or previous topic, stopping at the ends.
    func pageHelp(_ delta: Int) {
        let topics = Help.Topic.allCases
        let current: Int = if case .topic(let t) = help { topics.firstIndex(of: t) ?? 0 } else { 0 }
        help = .topic(topics[max(0, min(topics.count - 1, current + delta))])
    }
    var me: String { demoMe ?? session?.me ?? "" }
    var origin: String { session?.client.origin ?? "" }
    var connection: EventSocket.Status { demoMe != nil ? .connected : session?.connection ?? .connecting }

    // MARK: persistence

    private struct SavedRoom: Codable {
        var name: String
        var id: String
    }

    /// Rooms to rejoin at launch, pinned to their fingerprints.
    private var savedRooms: [SavedRoom] {
        get { (Profile.identityDefaults.data(forKey: "joinedRooms")).flatMap { try? JSONDecoder().decode([SavedRoom].self, from: $0) } ?? [] }
        set { Profile.identityDefaults.set(try? JSONEncoder().encode(newValue), forKey: "joinedRooms") }
    }

    /// Fingerprints of rooms we've been in, by name, to spot a name taken over by a new room.
    private var knownRooms: [String: String] {
        get { Profile.identityDefaults.dictionary(forKey: "knownRooms") as? [String: String] ?? [:] }
        set { Profile.identityDefaults.set(newValue, forKey: "knownRooms") }
    }

    private func persist() {
        guard demoMe == nil else { return }
        savedRooms = rooms.compactMap { id in state(id).map { SavedRoom(name: $0.room.name, id: id) } }
        Profile.identityDefaults.set(activeRoom, forKey: "activeRoom")
    }

    // MARK: start

    /// Logs in, rejoins last session's rooms, and joins `room` too if one was asked for.
    /// With nothing to rejoin and no room asked for, nothing is joined: the overview opens
    /// so you can pick (being in a listed room is public, so that's your call).
    func start(room: String?, server: URL = OSCClient.defaultServer) {
        self.server = server
        // This identity's own rooms, room keys and signing setting.
        Profile.use(identityAt: identityURL, server: server)
        signByDefault = Profile.identityDefaults.object(forKey: "signMessages") as? Bool ?? true
        if room == nil, savedRooms.isEmpty {
            browser.open()
            note(.info, "pick a room to join, or type a name · esc to close")
        }
        startTask?.cancel()
        startTask = Task {
            do {
                let url = identityURL
                // Phosphor's own identity is created on first use; one you chose must exist.
                let (identity, file) = url == IdentityFile.defaultURL
                    ? try IdentityFile.loadOrCreate(at: url)
                    : try Self.loadChosenIdentity(url)
                let client = OSCClient(baseURL: server, identity: identity, displayName: file.name, client: Self.clientInfo,
                                       incognito: IdentityStore.isIncognito(identity.fingerprint))
                let session = ChatSession(client: client)
                session.onUpdate = { [weak self] in self?.handle($0) }
                self.session = session
                displayName = file.name ?? "anon"
                note(.info, "connecting as \(identity.fingerprint.prefix(8))…")
                // Keep trying if the server can't be reached (offline at launch, say).
                var wait: Double = 2
                while true {
                    do {
                        try await session.start()
                        break
                    } catch let error as OSCError {
                        throw error                     // the server answered and said no
                    } catch {
                        note(.error, "can't reach \(server.host ?? "the server") (\(Self.brief(error))); retrying in \(Int(wait))s")
                        try await Task.sleep(for: .seconds(wait))
                        wait = min(wait * 2, 30)
                    }
                }
                displayName = await client.displayName ?? displayName
                IdentityStore.markUsed(identity.fingerprint)
                await chooseNameIfUnset(fingerprint: identity.fingerprint)
                try Task.checkCancellation()

                let saved = savedRooms
                let lastActive = Profile.identityDefaults.string(forKey: "activeRoom")
                for room in saved {
                    // Keyed rooms rejoin with the key from the keychain; if there's none, or it
                    // no longer works, the overview asks for it instead of failing.
                    let key = RoomKeychain.key(for: room.id)
                    let target = RoomBrowser.Target(name: room.name, id: room.id)
                    switch await join(room.name, key: key, activate: room.id == lastActive || activeRoom == nil,
                                      pinnedTo: room.id, askForKey: true) {
                    case .needsKey:
                        if key != nil { RoomKeychain.remove(for: room.id) }
                        browser.ask(.key(target, wrong: key != nil))
                    case .needsInvite:
                        browser.ask(.invite(target, wrong: false))
                    case .joined, .failed:
                        break
                    }
                }
                if let room { await join(room) }
                conformanceBot = session.discovery?.conformanceBot
                await lookForContactsSideRooms()
                if browser.isOpen { await refreshListing(maxAge: 0, pages: 3) }

                // Keep the room listing fresh. It's public and cacheable for 10 s; once a
                // minute is plenty outside the browser.
                discoveredAdmins = Set(session.discovery?.admins ?? [])
                var minutes = 0
                while !Task.isCancelled {
                    await refreshListing()
                    // The admin list changes rarely: re-read it every 10 minutes.
                    if minutes > 0, minutes % 10 == 0, let d = try? await session.client.discover() {
                        discoveredAdmins = Set(d.admins ?? [])
                    }
                    minutes += 1
                    try? await Task.sleep(for: .seconds(60))
                }
            } catch is CancellationError {
            } catch {
                note(.error, "login failed: \(error)")
            }
        }
    }

    // MARK: identity

    private var startTask: Task<Void, Never>?
    private(set) var server = OSCClient.defaultServer

    /// An identity file for this launch only (`--identity path`).
    var launchIdentity: URL?

    /// The identity in use: this launch's, else the one chosen in the menu (remembered),
    /// else Phosphor's own. Chosen files are used in place, never copied.
    var identityURL: URL {
        launchIdentity
            ?? Profile.identityOverride                                  // PHOSPHOR_IDENTITY
            ?? Profile.defaults.string(forKey: "identityPath").map { URL(fileURLWithPath: $0) }
            ?? IdentityFile.defaultURL
    }

    private static func loadChosenIdentity(_ url: URL) throws -> (Identity, IdentityFile) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ChooseIdentityError(message: "no identity file at \(url.path)")
        }
        let file = try IdentityFile.read(from: url)
        return (try file.load(), file)
    }

    private struct ChooseIdentityError: Error, CustomStringConvertible {
        var message: String
        var description: String { message }
    }

    // MARK: display name

    private var nameWaiter: CheckedContinuation<String?, Never>?

    /// Identities that chose to stay anon (Esc at the name prompt), so they aren't asked again.
    private static let staysAnonKey = "staysAnon"

    /// The server calls you `anon` until you pick a name, so a new identity is asked for one
    /// before it joins anything.
    private func chooseNameIfUnset(fingerprint: String) async {
        guard displayName.isEmpty || displayName == DisplayName.unset,
              !(Profile.defaults.stringArray(forKey: Self.staysAnonKey) ?? []).contains(fingerprint) else { return }
        note(.info, "pick a name: it's shown with your messages, and you can change it later with /nick")
        var problem: String?
        while !Task.isCancelled {
            let answer = await withCheckedContinuation { waiter in
                nameWaiter = waiter
                browser.ask(.name(problem: problem))
            }
            guard !Task.isCancelled else { return }
            guard let name = answer else {
                Profile.defaults.set((Profile.defaults.stringArray(forKey: Self.staysAnonKey) ?? []) + [fingerprint],
                                          forKey: Self.staysAnonKey)
                return note(.info, "staying anon · /nick name to pick one later")
            }
            do {
                try await session?.client.setName(name)
                displayName = name
                rememberName(name)
                return note(.info, "you're \(SafeText.clean(name))")
            } catch let error as OSCError {
                problem = error.message                 // refused: ask again, saying why
            } catch {
                return note(.error, "couldn't set your name (\(Self.brief(error))) · try /nick name")
            }
        }
    }

    /// The browser's answer to the name prompt (nil: Esc, stay anon).
    func answerName(_ name: String?) {
        nameWaiter?.resume(returning: name)
        nameWaiter = nil
    }

    /// Keeps the name as the hint in Phosphor's own identity file, so an exported copy
    /// carries it. Identity files you chose are never written to.
    private func rememberName(_ name: String) {
        // Phosphor's own files only: a linked file (or one set by PHOSPHOR_IDENTITY) is left alone.
        guard let entry = IdentityStore.all().first(where: { $0.url == identityURL }), !entry.isLinked else { return }
        IdentityStore.rename(entry, to: name)
    }

    /// Switches to another identity file (nil: Phosphor's own). The file is checked first;
    /// then the current identity logs out (leaving its rooms) and the new one logs in and
    /// rejoins the saved rooms.
    /// The custom server you're on, for the status line; nil on the real one.
    var customServer: String? { ServerStore.isCustom(server) && demoMe == nil ? ServerStore.label(server) : nil }

    /// Switches server: logs out, then in again on `url`, rejoining your rooms there.
    func useServer(_ url: URL) {
        guard demoMe == nil else { return note(.info, "the server is used when not in demo mode") }
        guard OSCClient.origin(of: url) != OSCClient.origin(of: server) else { return note(.info, "already on it") }
        ServerStore.current = url
        note(.info, ServerStore.isCustom(url) ? "switching to \(ServerStore.label(url))…" : "switching back to OneShotChat…")
        restart(on: url)
    }

    /// Phosphor → Server → Add Server…: asks for the address in the input line.
    func askServerAddress() { contactPrompt = .addServer }

    /// `/server`, `/server add address`, `/server use address|main`, `/server remove address`.
    private func serverCommand(_ rest: String) {
        let (verb, more) = split(rest.trimmingCharacters(in: .whitespaces))
        switch verb {
        case "":
            let list = (["main (OneShotChat)"] + ServerStore.custom.map { ServerStore.label(URL(string: $0)!) }).joined(separator: " · ")
            note(.info, "on \(customServer ?? "OneShotChat") · servers: \(list)")
            note(.info, "/server add address · /server use address (or main) · /server remove address")
        case "add":
            guard let url = ServerStore.normalize(more) else {
                return note(.error, "that isn't a server address (https://…; plain http only for this Mac or the local network)")
            }
            guard ServerStore.isCustom(url) else { return useServer(url) }
            // Check it's a OneShotChat server before keeping it.
            Task {
                do {
                    let d = try await OSCClient(baseURL: url, identity: .generate(), displayName: nil, client: Self.clientInfo).discover()
                    ServerStore.add(url)
                    note(.info, "added \(ServerStore.label(url)) (\(SafeText.clean(d.name)), protocol \(SafeText.clean(d.protocol)))")
                    useServer(url)
                } catch {
                    note(.error, "couldn't reach a OneShotChat server at \(ServerStore.label(url)): \(Self.brief(error))")
                }
            }
        case "use":
            if more == "main" || more.isEmpty { return useServer(ServerStore.main) }
            guard let url = ServerStore.normalize(more) else { return note(.error, "/server use address, or main") }
            guard !ServerStore.isCustom(url) || ServerStore.custom.contains(OSCClient.origin(of: url)) else {
                return note(.error, "\(ServerStore.label(url)) isn't added: /server add \(more)")
            }
            useServer(url)
        case "remove":
            guard let url = ServerStore.normalize(more), ServerStore.custom.contains(OSCClient.origin(of: url)) else {
                return note(.error, "no custom server \(more)")
            }
            guard OSCClient.origin(of: url) != OSCClient.origin(of: server) else { return note(.error, "switch to another server first") }
            ServerStore.remove(url)
            note(.info, "removed \(ServerStore.label(url))")
        default:
            note(.error, "/server add address · use address|main · remove address")
        }
    }

    func useIdentity(at url: URL?) {
        if let url {
            do {
                let identity = try Self.loadChosenIdentity(url).0
                note(.info, "switching to \(identity.fingerprint.prefix(8))…")
            } catch {
                return note(.error, "that isn't a usable identity file: \(error)")
            }
            Profile.defaults.set(url.path, forKey: "identityPath")
        } else {
            Profile.defaults.removeObject(forKey: "identityPath")
        }
        launchIdentity = nil
        guard demoMe == nil else { return note(.info, "the identity is used when not in demo mode") }
        restart(on: server)
    }

    /// Logs out and starts again (as the identity now chosen, on `newServer`), rejoining
    /// that identity's saved rooms there.
    private func restart(on newServer: URL) {
        let old = session
        old?.onUpdate = nil
        old?.stop()
        startTask?.cancel()
        answerName(nil)                                 // a name prompt for the old identity
        // Clear the rooms without touching the saved list, which the new identity rejoins.
        let previous = activeRoom
        rooms = []
        activity = [:]
        activeRoom = nil
        focus = nil
        session = nil
        listed = []                                     // the old server's room listing
        listedAt = nil
        onActiveChanged?(previous, nil)
        Task {
            try? await old?.client.logout()
            start(room: nil, server: newServer)
        }
    }

    /// A short reason for a network error, not the whole NSError dump.
    private static func brief(_ error: Error) -> String {
        if let url = error as? URLError { return url.localizedDescription.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() }
        return String(String(describing: error).prefix(60))
    }

    /// `paceScale` below 1 makes every room chattier.
    func startDemo(speakers: Int, name: String, paceScale: Double = 1) {
        let me = DemoFeed.person(name).fp
        demoMe = me
        demoName = name
        displayName = name
        // #dev is the busy room with a long past (the tours end by flying up through it).
        let specs: [(String, String, Int, ClosedRange<Int>, Int)] = [
            ("lobby", "say hi · messages last 7 days", speakers, 1600...3600, 20),
            ("dev", "building OneShotChat clients", 6, 900...2200, 50),
            ("clients", "show and tell: new clients", 3, 4000...9000, 8),
            ("offtopic", "everything else", 1, 9000...20000, 8),
        ]
        // neo is about: in three of your rooms and a listed one, so a contact in several
        // rooms shows on the contacts wall.
        let neo = DemoFeed.person("neo")
        for (name, topic, speakers, pace, history) in specs {
            let scaled = Int(Double(pace.lowerBound) * paceScale)...Int(Double(pace.upperBound) * paceScale)
            let feed = DemoFeed(name: name, topic: topic, me: me, myName: self.demoName, speakers: speakers, pace: scaled,
                                history: history, regulars: name == "offtopic" ? [] : [neo])
            feed.onEvent = { [weak self, id = feed.roomID] in self?.handle(.event(room: id, $0)) }
            feed.onSent = { [weak self, id = feed.roomID] in self?.onOwnMessage?(id, $0, false) }
            demos[feed.roomID] = feed
            rooms.append(feed.roomID)
            feed.start()
        }
        activate(rooms[0])
        listed = DemoFeed.listing(regulars: [neo])
        // Demo contacts live in memory only: neo, about everywhere; someone here under a
        // petname; someone who's left; and someone in a listed room.
        var seeds: [ContactBook.Contact] = [.init(fingerprint: neo.fp, petname: "Thomas", name: neo.name, added: Date(),
                                                  lastSeen: Date(), lastSeenRoom: "#lobby")]
        if let lobby = demos[rooms[0]] {
            for (i, person) in lobby.contactSeeds().enumerated() {
                seeds.append(.init(fingerprint: person.fp, petname: i == 0 ? person.name.capitalized + " from work" : nil, name: person.name,
                                   added: Date(), lastSeen: Date().addingTimeInterval(-Double(i) * 7200), lastSeenRoom: "#lobby"))
            }
        }
        if let elsewhere = listed.first, let o = elsewhere.occupants?.first {
            seeds.append(.init(fingerprint: o.identity, petname: nil, name: o.name, added: Date(),
                               lastSeen: Date(), lastSeenRoom: "#" + elsewhere.name))
        }
        ContactBook.shared.useInMemory(seed: seeds)
        demoAdmins = Set([demos[rooms[0]]?.adminSeed].compactMap { $0 })
        note(.info, "demo mode · offline")
    }

    // MARK: rooms

    func activate(_ room: String) {
        guard rooms.contains(room), room != activeRoom else { return }
        let old = activeRoom
        activeRoom = room
        activity[room] = Activity()
        focus = nil
        persist()
        onActiveChanged?(old, room)
    }

    /// Leaves a room (⌘W or /leave): the server is told, the room drops out of the layout
    /// and the next one along becomes active. Leaving is per room; your roles are kept.
    func leave(_ room: String) {
        guard rooms.contains(room) else { return }
        let name = state(room)?.room.name ?? "?"
        if let demo = demos[room] {
            demo.stop()
            demos[room] = nil
            removeRoom(room)
            note(.info, "left #\(name)")
            return
        }
        Task {
            do {
                try await session?.leave(room)      // reports .left, which removes the room
            } catch {
                note(.error, "couldn't leave #\(name): \(error)")
            }
        }
    }

    func leaveActive() {
        if let activeRoom { leave(activeRoom) }
    }

    /// ⌘1…⌘9 (zero-based here).
    /// Demo: the room at `index` mentions you / someone reacts to your latest there.
    func demoMention(roomIndex: Int) {
        if rooms.indices.contains(roomIndex) { demos[rooms[roomIndex]]?.mentionYou() }
    }

    func demoReactToMine(_ reaction: String = "🔥") {
        if let activeRoom { demos[activeRoom]?.reactToYours(reaction) }
    }

    func activate(index: Int) {
        if rooms.indices.contains(index) { activate(rooms[index]) }
    }

    /// ⌘← / ⌘→, wrapping around.
    func cycle(_ delta: Int) {
        guard !rooms.isEmpty else { return }
        let i = activeRoom.flatMap { rooms.firstIndex(of: $0) } ?? 0
        activate(rooms[(i + delta + rooms.count) % rooms.count])
    }

    // MARK: room browser

    /// Fetches the public listing (`GET /v1/rooms`, no login, no presence) unless it's
    /// fresher than `maxAge`. Up to `pages` pages; the browser asks for more than the
    /// background refresh does.
    func refreshListing(maxAge: TimeInterval = 10, pages: Int = 1) async {
        guard demoMe == nil, let client = session?.client else { return }
        if let listedAt, -listedAt.timeIntervalSinceNow < maxAge { return }
        do {
            var all: [Room] = []
            var cursor: String?
            for _ in 0..<pages {
                let page = try await client.rooms(cursor: cursor)
                all += page.rooms
                cursor = page.next
                if cursor == nil { break }
            }
            listed = all
            listedAt = Date()
            noteSightings()
        } catch {
            note(.error, "couldn't load the room list: \(error)")
        }
    }

    /// Joins a room picked in the browser, pinned to the fingerprint we saw listed so a
    /// name that changed hands in the meantime isn't joined by mistake.
    enum JoinOutcome {
        case joined, needsKey, needsInvite, failed
    }

    /// A join started in the browser: the outcome tells it whether to close or ask for a
    /// key or invite code (which it does itself, so those aren't reported as errors).
    func joinFromBrowser(_ target: RoomBrowser.Target, key: String?, invite: String?) async -> JoinOutcome {
        if demoMe != nil {
            guard let room = listed.first(where: { $0.name == target.name }) else {
                note(.info, "the demo only has its listed rooms")
                return .failed
            }
            if room.access == "key", (key ?? "").isEmpty { return .needsKey }
            if room.access == "invite", (invite ?? "").isEmpty { return .needsInvite }
            joinDemo(room)
            return .joined
        }
        return await join(target.name, key: key, invite: invite, pinnedTo: target.id, askForKey: true)
    }

    /// In the demo, a listed room becomes another scripted feed (any key or code works).
    private func joinDemo(_ room: Room) {
        guard let me = demoMe else { return }
        let feed = DemoFeed(name: room.name, topic: room.topic ?? "", me: me, myName: demoName, speakers: 2, pace: 3000...8000)
        feed.onEvent = { [weak self, id = feed.roomID] in self?.handle(.event(room: id, $0)) }
        feed.onSent = { [weak self, id = feed.roomID] in self?.onOwnMessage?(id, $0, false) }
        demos[feed.roomID] = feed
        if !rooms.contains(feed.roomID) { rooms.append(feed.roomID) }
        feed.start()
        activate(feed.roomID)
        note(.info, "joined #\(room.name)")
    }

    // MARK: input

    /// The input line's Enter. Plain text goes to the active room; `/commands` act on the
    /// focused message.
    func submit(_ raw: String, labels: [String: String]) {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        let (head, rest) = split(line)
        if head == "/help" {
            let word = rest.trimmingCharacters(in: .whitespaces).lowercased()
            if word.isEmpty { return help = .all }
            guard let topic = Help.Topic(rawValue: word) ?? (word == "operators" ? .mod : nil) else {
                return note(.error, "no help on \(word) · try /help chat, rooms, mod or keys")
            }
            return help = .topic(topic)
        }
        // Contacts are local: they work the same live or in the demo.
        if head == "/contacts" { return showingContacts = true }
        if head == "/delete" { return askDelete(rest) }
        if head == "/identity" || head == "/identities" { return identityCommand(rest) }
        if head == "/server" { return serverCommand(rest) }
        if demoMe == nil, head == "/side" { return sideCommand(rest, labels: labels) }
        if demoMe == nil, head == "/close" { return closeCommand() }
        if head == "/contact" || head == "/uncontact" { return contactCommand(head, rest, labels: labels) }
        if head == "/room", rest.trimmingCharacters(in: .whitespaces).isEmpty {
            guard state != nil else { return note(.error, "not in a room") }
            return showingRoomInfo = true
        }
        if head == "/leave" || head == "/part" {
            let name = rest.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
            let target = name.isEmpty ? activeRoom : rooms.first { state($0)?.room.name == name }
            guard let target else { return note(.error, "not in #\(name)") }
            return leave(target)
        }
        if demoMe != nil {
            switch head {
            case "/nick":
                if let problem = DisplayName.problem(rest) { return note(.error, problem) }
                displayName = rest
                return note(.info, "you're \(rest) (in the demo)")
            case "/sign", "/unsigned":
                if let activeRoom, !rest.isEmpty { demos[activeRoom]?.input(MentionText.compose(rest, labels: labels), sign: head == "/sign") }
                return
            case "/unreact":
                let (target, typed) = unreactTarget(rest)
                guard let target, let activeRoom else { return note(.error, "no reaction of yours to take back") }
                demos[activeRoom]?.input("/unreact \(target.id) \(Emoji.expand(typed.trimmingCharacters(in: .whitespaces)))")
                return
            case "/react", "/edit":
                break
            default:
                if head.hasPrefix("/") {
                    let known = Help.commands.contains { $0.name == head }
                    return note(.error, known ? "\(head) needs the server: not in demo mode" : "unknown command \(head); /help")
                }
            }
            if let activeRoom { demos[activeRoom]?.input(MentionText.compose(line, labels: labels), sign: signByDefault) }
            return
        }
        Task {
            do {
                switch head {
                case "/unsigned":
                    try await send(rest, labels: labels, sign: false)
                case "/sign":
                    try await send(rest, labels: labels, sign: true)
                case "/edit", "/sedit":
                    let (target, text) = targetMessage(rest, mine: true)
                    guard let target else { return note(.error, "no message of yours to edit") }
                    guard !target.isDeleted else { return note(.error, "[\(target.id)] was deleted: it can't be edited") }
                    if let edited = try await session?.edit(target, to: MentionText.compose(text, labels: labels), sign: head == "/sedit" || signByDefault) {
                        onOwnMessage?(edited.room, edited, true)
                    }
                case "/react", "/unreact":
                    let (target, typed) = head == "/unreact" ? unreactTarget(rest) : targetMessage(rest, mine: false)
                    let reaction = Emoji.expand(typed.trimmingCharacters(in: .whitespaces))      // :+1: pasted whole
                    guard let target, !reaction.isEmpty else { return note(.error, "usage: /react [id] 👍") }
                    guard !target.isDeleted else { return note(.error, "[\(target.id)] was deleted: it can't be reacted to") }
                    if head == "/react" { try await session?.react(reaction, to: target) } else { try await session?.unreact(reaction, from: target) }
                case "/join":
                    // /join room [key]  or  /join room invite <code>
                    let (name, more) = split(rest.trimmingCharacters(in: .whitespaces))
                    let room = name.trimmingCharacters(in: CharacterSet(charactersIn: "#")).lowercased()
                    let (word, code) = split(more)
                    if word == "invite", !code.isEmpty {
                        await join(room, invite: code)
                    } else {
                        await join(room, key: more.isEmpty ? nil : more)
                    }
                case "/room":
                    try await roomCommand(rest)
                case "/topic":
                    try await updateActiveRoom(RoomUpdate(topic: rest), done: rest.isEmpty ? "topic cleared" : "topic set")
                case "/invite":
                    // /invite [uses] [how long], in either order: /invite 5 7d, /invite 2h.
                    guard let activeRoom else { return note(.error, "not in a room") }
                    var uses = 1, seconds = 86400
                    for word in rest.split(separator: " ").map(String.init) {
                        if let n = Int(word) {
                            guard n >= 1 else { return note(.error, "an invite needs at least 1 use") }
                            uses = n
                        } else if let d = Self.parseDuration(word), d > 0 {
                            seconds = d
                        } else {
                            return note(.error, "usage: /invite [uses] [how long, like 30m, 2h, 7d]")
                        }
                    }
                    let invite = try await session?.client.createInvite(room: activeRoom, uses: uses, expiresIn: seconds)
                    if let invite {
                        let left = invite.usesLeft ?? uses
                        let until = invite.expiresAt.map { RoomInfo.duration(Int($0.timeIntervalSinceNow.rounded())) }
                            ?? RoomInfo.duration(seconds)
                        note(.info, "invite code: \(invite.code)  (\(left) use\(left == 1 ? "" : "s"), good for \(until)) · they join with /join \(state?.room.name ?? "room") invite \(invite.code)")
                    }
                case "/op", "/deop", "/voice", "/devoice", "/mute", "/unmute", "/ban", "/unban", "/allow", "/disallow", "/kick":
                    try await memberCommand(head, rest, labels: labels)
                case "/nick":
                    if let problem = DisplayName.problem(rest) { return note(.error, problem) }
                    try await session?.client.setName(rest)
                    displayName = rest
                    rememberName(rest)
                default:
                    if head.hasPrefix("/") { note(.error, "unknown command \(head); /help") } else { try await send(line, labels: labels, sign: signByDefault) }
                }
            } catch let error as OSCError {
                note(.error, "\(error.code): \(error.message)")
            } catch {
                note(.error, "\(error)")
            }
        }
    }

    // MARK: operator commands

    /// `/room` shows the active room's settings; `/room <setting>…` changes them, e.g.
    /// `/room unlisted`, `/room key hunter2`, `/room invite`, `/room moderated`,
    /// `/room retention 24h` (or `forever`). Several can go in one command.
    private func roomCommand(_ args: String) async throws {
        guard state != nil else { return note(.error, "not in a room") }
        let words = args.split(separator: " ").map(String.init)
        if words.isEmpty { return showingRoomInfo = true }
        var update = RoomUpdate()
        var i = 0
        while i < words.count {
            switch words[i] {
            case "listed", "unlisted": update.visibility = words[i]
            case "open": update.access = "open"
            case "invite": update.access = "invite"
            case "key":
                guard i + 1 < words.count else { return note(.error, "usage: /room key <key>") }
                update.access = "key"
                update.key = words[i + 1]
                i += 1
            case "moderated": update.speaking = "moderated"
            case "unmoderated": update.speaking = "open"
            case "retention":
                guard i + 1 < words.count else { return note(.error, "usage: /room retention 24h|7d|forever") }
                if words[i + 1] == "forever" { update.retention = .forever } else {
                    guard let seconds = Self.parseDuration(words[i + 1]) else { return note(.error, "retention like 1h, 24h, 7d or forever") }
                    update.retention = .seconds(seconds)
                }
                i += 1
            default:
                return note(.error, "unknown room setting '\(words[i])'; /room for the list")
            }
            i += 1
        }
        try await updateActiveRoom(update, done: "room updated")
        showingRoomInfo = true                          // the wall shows the result, and glows what changed
    }

    private func updateActiveRoom(_ update: RoomUpdate, done: String) async throws {
        guard let activeRoom, let session else { return note(.error, "not in a room") }
        try await session.updateRoom(activeRoom, update)
        if let key = update.key { RoomKeychain.save(key, for: activeRoom) }
        if update.access == "open" { RoomKeychain.remove(for: activeRoom) }
        note(.info, done)
    }

    /// Roles and kicks for someone in view: `/op @sam#a7`, `/kick @sam spamming`.
    private func memberCommand(_ head: String, _ args: String, labels: [String: String]) async throws {
        guard let activeRoom, let client = session?.client else { return note(.error, "not in a room") }
        let (who, reason) = split(args.trimmingCharacters(in: .whitespaces))
        let label = who.hasPrefix("@") ? String(who.dropFirst()) : who
        guard let fp = labels[label] ?? (Identity.isFingerprint(label) ? label : nil) else {
            return note(.error, "no one called @\(label) here (type @ to pick someone)")
        }
        switch head {
        case "/op": try await client.setRole(room: activeRoom, identity: fp, role: "operator")
        case "/voice": try await client.setRole(room: activeRoom, identity: fp, role: "voice")
        case "/mute": try await client.setRole(room: activeRoom, identity: fp, role: "muted")
        case "/ban": try await client.setRole(room: activeRoom, identity: fp, role: "banned")
        case "/allow": try await client.setRole(room: activeRoom, identity: fp, role: "invited")
        case "/kick": try await client.kick(room: activeRoom, identity: fp, reason: reason.isEmpty ? nil : reason)
        case "/disallow":
            // Clearing a role clears whatever it is: only do it if it's really "invited",
            // so this never demotes an operator or takes someone's voice.
            let roles = try await client.roles(room: activeRoom)
            roomRoles[activeRoom] = roles
            guard let role = roles.first(where: { $0.identity == fp })?.role else {
                return note(.info, "@\(label) isn't on the invited list")
            }
            guard role == .invited else { return note(.error, "@\(label) is \(role.rawValue), not invited: nothing changed") }
            try await client.clearRole(room: activeRoom, identity: fp)
        default: try await client.clearRole(room: activeRoom, identity: fp)     // deop, devoice, unmute, unban
        }
        note(.info, "\(head.dropFirst()) @\(label): done")
    }

    static func parseDuration(_ s: String) -> Int? {
        guard let unit = s.last, let n = Int(s.dropLast()) else { return Int(s) }
        switch unit {
        case "h": return n * 3600
        case "m": return n * 60
        case "d": return n * 86400
        case "w": return n * 604800
        default: return nil
        }
    }

    static func duration(_ seconds: Int) -> String {
        seconds % 86400 == 0 ? "\(seconds / 86400)d" : seconds % 3600 == 0 ? "\(seconds / 3600)h" : "\(seconds)s"
    }

    /// Moves the selection through messages: older (-1) or newer (+1); nil clears.
    func moveFocus(_ direction: Int?) {
        guard let direction, let ids = state?.orderedMessages.map(\.id), !ids.isEmpty else {
            focus = nil
            return
        }
        guard let focus, let i = ids.firstIndex(of: focus) else {
            self.focus = direction < 0 ? ids.last : nil
            return
        }
        let next = i + direction
        self.focus = next >= ids.count ? nil : ids[max(0, next)]
    }

    private var loadingOlder = false
    private var historyExhausted: Set<String> = []

    /// Fetches the page before the active room's oldest loaded message, once at a time.
    func loadOlder() {
        guard demoMe == nil, !loadingOlder, let session, let room = activeRoom, !historyExhausted.contains(room) else { return }
        loadingOlder = true
        Task {
            defer { loadingOlder = false }
            do {
                if try await !session.loadOlder(room) { historyExhausted.insert(room) }
            } catch {
                historyExhausted.insert(room)
                note(.error, "couldn't load older messages: \(error)")
            }
        }
    }

    // MARK: private

    private func send(_ text: String, labels: [String: String], sign: Bool) async throws {
        guard let activeRoom else { return note(.error, "not in a room") }
        if let sent = try await session?.send(MentionText.compose(text, labels: labels), to: activeRoom, sign: sign) {
            onOwnMessage?(activeRoom, sent, false)
        }
    }

    /// `[id] rest`: an explicit message id if the first word is one, else the focused
    /// message, else the latest (of mine, for edits).
    /// Your reactions on the message `/unreact` would act on (an id in `args`, else the
    /// selected one, else the latest).
    func myReactions(_ args: String) -> [String] {
        let (target, _) = unreactTarget(args)
        return target.map(reactions(byMeOn:)) ?? []
    }

    private func reactions(byMeOn m: Message) -> [String] {
        (m.reactions ?? []).filter { $0.identities?.contains(me) == true }.map(\.reaction)
    }

    /// What /unreact acts on: an id in `args`, else the selected message, else the latest
    /// message you've reacted to (the latest message overall rarely has your reaction).
    private func unreactTarget(_ args: String) -> (Message?, String) {
        let (first, rest) = split(args)
        if let id = Int(first), let m = state?.messages[id] { return (m, rest) }
        if let focus, let m = state?.messages[focus] { return (m, args) }
        return (state?.orderedMessages.last { !reactions(byMeOn: $0).isEmpty }, args)
    }

    private func targetMessage(_ args: String, mine: Bool) -> (Message?, String) {
        let (first, rest) = split(args)
        if let id = Int(first), let m = state?.messages[id] { return (m, rest) }
        if let focus, let m = state?.messages[focus], !mine || m.author.identity == me { return (m, args) }
        let candidates = state?.orderedMessages.filter { (!mine || $0.author.identity == me) && !$0.isDeleted } ?? []
        return (candidates.last, args)
    }

    /// Joins (or, if already joined, just activates). `pinnedTo` is a remembered
    /// fingerprint from a previous launch: if the name now belongs to a different room,
    /// we say so and don't join the stranger's room.
    /// `askForKey`: the caller will ask for a missing or wrong key / invite code itself.
    @discardableResult
    private func join(_ name: String, key: String? = nil, invite: String? = nil, activate: Bool = true, pinnedTo: String? = nil,
                      askForKey: Bool = false) async -> JoinOutcome {
        guard let session, !name.isEmpty else { return .failed }
        if let existing = rooms.first(where: { state($0)?.room.name == name }) {
            if activate { self.activate(existing) }
            return .joined
        }
        do {
            let state: RoomState
            do {
                state = try await session.join(name, expect: pinnedTo ?? knownRooms[name], key: key, invite: invite)
            } catch let error as OSCError where error.code == "room_changed" {
                if pinnedTo != nil {
                    note(.error, "#\(name) now belongs to a different room (yours expired). /join \(name) to join the new one.")
                    savedRooms.removeAll { $0.name == name }
                    return .failed
                }
                note(.error, "#\(name) is a different room than the one you were in before (the old one expired). Joined the new one.")
                state = try await session.join(name, key: key, invite: invite)
            }
            knownRooms[name] = state.id
            if let key { RoomKeychain.save(key, for: state.id) }
            if !rooms.contains(state.id) { rooms.append(state.id) }
            if activate || activeRoom == nil { self.activate(state.id) }
            persist()
            note(.info, "joined #\(state.room.name)")
            return .joined
        } catch let error as OSCError where error.code == "key_required" {
            if key != nil { note(.error, "wrong key for #\(name) (too many wrong tries locks the room's key joins for a while)") }
            else if !askForKey { note(.error, "#\(name) needs a room key: /join \(name) <key>") }
            return .needsKey
        } catch let error as OSCError where error.code == "invite_required" {
            if invite != nil { note(.error, "that invite code didn't work for #\(name)") }
            else if !askForKey { note(.error, "#\(name) is invite-only: /join \(name) invite <code>") }
            return .needsInvite
        } catch let error as OSCError {
            note(.error, "join #\(name): \(error.code)")
            return .failed
        } catch {
            note(.error, "join #\(name): \(error)")
            return .failed
        }
    }

    private func removeRoom(_ room: String) {
        guard let i = rooms.firstIndex(of: room) else { return }
        rooms.remove(at: i)
        activity[room] = nil
        if activeRoom == room {
            let old = activeRoom
            activeRoom = rooms.isEmpty ? nil : rooms[min(i, rooms.count - 1)]
            focus = nil
            onActiveChanged?(old, activeRoom)
        }
        persist()
    }

    private func handle(_ update: ChatSession.Update) {
        switch update {
        case .event(let room, let event):
            if room != activeRoom, case .messageCreated(let m) = event.payload, m.author.identity != me {
                activity[room, default: Activity()].unread += 1
                if m.mentions?.contains(me) == true { activity[room, default: Activity()].mentioned = true }
            }
            if case .memberRoleChanged = event.payload, roomRoles[room] != nil { refreshRoles(room) }
            switch event.payload {
            case .memberJoined(let j) where ContactBook.shared.isContact(j.identity):
                ContactBook.shared.saw(j.identity, in: "#" + (state(room)?.room.name ?? "?"), name: j.name)
            case .messageCreated(let m) where ContactBook.shared.isContact(m.author.identity):
                ContactBook.shared.saw(m.author.identity, in: "#" + (state(room)?.room.name ?? "?"), name: m.author.name)
            default: break
            }
            onEvent?(room, event)
        case .reloaded(let room):
            onRoomReloaded?(room)
        case .left(let room, let name, let reason, let detail):
            // A room you left or were banned from won't be rejoined: forget its key.
            if reason == "left" || reason == "banned" || reason == "closed" { RoomKeychain.remove(for: room) }
            if reason == "closed" {
                note(.info, "the side room with \(sideWith[room].map(personLabel) ?? "them") was closed")
                sideWith[room] = nil
                savedRooms.removeAll { $0.id == room }
                return removeRoom(room)
            }
            let detail = detail.map { ": \($0)" } ?? ""
            switch reason {
            case "left": note(.info, "left #\(name)")
            case "kicked": note(.error, "you were kicked from #\(name)\(detail)")
            case "banned": note(.error, "you were banned from #\(name)\(detail)")
            case "rejoin_failed": note(.error, "lost #\(name), couldn't rejoin\(detail)")
            default: note(.error, "left #\(name) (\(reason))\(detail)")
            }
            removeRoom(room)
        case .mention(let item) where !rooms.contains(item.room.id):
            if !offerIfSide(item) { note(.mention, "\(item.message.author.name) mentioned you in #\(item.room.name)") }
        case .notice(_, let notice):
            // Only these come from the server itself; everything else is user content.
            note(.server, "SERVER \(notice.code): \(notice.text)")
        case .connection(.disconnected(let reason)):
            note(.error, "disconnected (\(reason.prefix(60))); reconnecting")
        case .error(let message):
            note(.error, message)
        default:
            break
        }
    }

    func note(_ kind: Notice.Kind, _ text: String) {
        notices.append(Notice(kind: kind, text: SafeText.clean(text), at: AppClock.now))
        if notices.count > 6 { notices.removeFirst(notices.count - 6) }
    }

    private func split(_ s: String) -> (String, String) {
        guard let space = s.firstIndex(of: " ") else { return (s, "") }
        return (String(s[..<space]), String(s[s.index(after: space)...]))
    }
}
