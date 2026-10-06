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

    enum Prompt {
        case key(Room)
        case invite(Room)
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

    func close() {
        isOpen = false
        prompt = nil
    }

    /// Esc: back out of a prompt first, then close.
    func cancel() {
        if prompt != nil { prompt = nil } else { close() }
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

    /// Enter. Joins the selection, or asks for its key or invite first; in a prompt, the
    /// text is that key or code.
    func submit(_ text: String) {
        if let prompt {
            let answer = text.trimmingCharacters(in: .whitespaces)
            guard !answer.isEmpty else { return }
            switch prompt {
            case .key(let room): controller.join(listed: room, key: answer)
            case .invite(let room): controller.join(listed: room, invite: answer)
            }
            close()
            return
        }
        switch selected {
        case .listed(let room) where room.access == "key":
            prompt = .key(room)
        case .listed(let room) where room.access == "invite":
            prompt = .invite(room)
        case .listed(let room):
            controller.join(listed: room)
            close()
        case .byName(let name):
            controller.join(named: name)
            close()
        case nil:
            break
        }
    }

    /// What the input line says before the text.
    var inputPrompt: String {
        switch prompt {
        case .key(let room): "key for #\(SafeText.clean(room.name)) › "
        case .invite(let room): "invite code for #\(SafeText.clean(room.name)) › "
        case nil: "find a room › "
        }
    }

    /// 1–32 of a-z 0-9 - _, starting with a letter or digit (protocol §6).
    static func isRoomName(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, s.count <= 32,
              CharacterSet.lowercaseLetters.union(.decimalDigits).contains(first) else { return false }
        return s.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_" }
    }
}
