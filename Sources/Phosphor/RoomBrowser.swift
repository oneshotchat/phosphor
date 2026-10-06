import Foundation
import OSCCore

/// Browser mode (⌘L): the input line becomes a filter over the public room listing,
/// ↑↓ picks a room, Enter joins it. Rooms that need a key or an invite ask for one first;
/// a name that isn't listed (an unlisted room, or a new one) can be joined directly.
@MainActor
final class RoomBrowser {
    enum Entry: Equatable {
        case listed(Room)
        case byName(String)

        var id: String? { if case .listed(let room) = self { room.id } else { nil } }
    }

    /// A room to join: its name, and the fingerprint it was listed with (pinned, so a name
    /// that changed hands isn't joined by mistake).
    struct Target: Equatable {
        var name: String
        var id: String?
    }

    enum Prompt: Equatable {
        case key(Target, wrong: Bool)
        case invite(Target, wrong: Bool)
    }

    private(set) var isOpen = false
    private(set) var selection = 0
    /// Asking for a room key or invite code before joining.
    private(set) var prompt: Prompt?
    private var query = ""
    private let controller: ChatController

    init(controller: ChatController) {
        self.controller = controller
    }

    func open() {
        isOpen = true
        query = ""
        selection = 0
        prompt = nil
        Task { await controller.refreshListing(pages: 3) }
    }

    /// Prompts waiting their turn (several keyed rooms at launch, say).
    private var pending: [Prompt] = []

    /// Opens the browser at a key or invite prompt for a room the app couldn't join on its
    /// own, or queues it behind the one already showing.
    func ask(_ request: Prompt) {
        if isOpen, prompt != nil || joining != nil {
            if request != prompt, !pending.contains(request) { pending.append(request) }
            return
        }
        if !isOpen { open() }
        prompt = request
    }

    func close() {
        if !pending.isEmpty {
            prompt = pending.removeFirst()     // the next room still waiting for its key
            return
        }
        isOpen = false
        prompt = nil
    }

    /// Esc: skip this prompt (on to the next waiting one, else back to the list), then close.
    func cancel() {
        if prompt != nil { prompt = pending.isEmpty ? nil : pending.removeFirst() } else { close() }
    }

    func setQuery(_ text: String) {
        guard prompt == nil else { return }
        let q = text.trimmingCharacters(in: .whitespaces).lowercased()
        if q != query { selection = 0 }
        query = q
    }

    func move(_ delta: Int) {
        let count = entries.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    /// Listed rooms you haven't joined that match the filter (name or topic), then the
    /// typed name itself if it's a valid room name that isn't listed.
    var entries: [Entry] {
        let rooms = controller.unjoinedListed.filter {
            query.isEmpty || $0.name.contains(query) || ($0.topic ?? "").lowercased().contains(query)
        }
        var entries = rooms.map(Entry.listed)
        if Self.isRoomName(query), !rooms.contains(where: { $0.name == query }) {
            entries.append(.byName(query))
        }
        return entries
    }

    var selected: Entry? {
        let entries = entries
        return entries.indices.contains(selection) ? entries[selection] : nil
    }

    /// A join in flight; the browser stays open until it's done.
    private(set) var joining: String?

    /// Enter. Joins the selection, asking for a key or invite code first when the listing
    /// says one is needed, or when the server says so (unlisted rooms, a listing that's out
    /// of date, a wrong key). In a prompt, the text is that key or code.
    func submit(_ text: String) {
        guard joining == nil else { return }
        if let prompt {
            let answer = text.trimmingCharacters(in: .whitespaces)
            guard !answer.isEmpty else { return }
            switch prompt {
            case .key(let target, _): attempt(target, key: answer)
            case .invite(let target, _): attempt(target, invite: answer)
            }
            return
        }
        switch selected {
        case .listed(let room) where room.access == "key":
            prompt = .key(Target(name: room.name, id: room.id), wrong: false)
        case .listed(let room) where room.access == "invite":
            prompt = .invite(Target(name: room.name, id: room.id), wrong: false)
        case .listed(let room):
            attempt(Target(name: room.name, id: room.id))
        case .byName(let name):
            attempt(Target(name: name, id: nil))
        case nil:
            break
        }
    }

    private func attempt(_ target: Target, key: String? = nil, invite: String? = nil) {
        joining = target.name
        Task {
            let outcome = await controller.joinFromBrowser(target, key: key, invite: invite)
            joining = nil
            switch outcome {
            case .joined: close()
            case .needsKey: prompt = .key(target, wrong: key != nil)
            case .needsInvite: prompt = .invite(target, wrong: invite != nil)
            case .failed: prompt = nil                    // the error is in the notices; pick again
            }
        }
    }

    /// What the input line says before the text.
    var inputPrompt: String {
        if let joining { return "joining #\(SafeText.clean(joining))… " }
        switch prompt {
        case .key(let target, let wrong):
            return (wrong ? "wrong key · " : "") + "key for #\(SafeText.clean(target.name)) › "
        case .invite(let target, let wrong):
            return (wrong ? "that code didn't work · " : "") + "invite code for #\(SafeText.clean(target.name)) › "
        case nil:
            return "find a room › "
        }
    }

    /// 1–32 of a-z 0-9 - _, starting with a letter or digit (protocol §6).
    static func isRoomName(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, s.count <= 32,
              CharacterSet.lowercaseLetters.union(.decimalDigits).contains(first) else { return false }
        return s.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_" }
    }
}
