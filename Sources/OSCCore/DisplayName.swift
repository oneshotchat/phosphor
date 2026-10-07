import Foundation

/// Display name rules (protocol §3): 1–64 bytes of UTF-8, no control or
/// bidirectional-override characters, no leading or trailing whitespace, and none of
/// `#`, `@`, `<`, `>`. Names aren't unique; people are told apart by fingerprint.
public enum DisplayName {
    /// What the server calls someone who never set a name.
    public static let unset = "anon"

    /// Why `name` would be refused, as a short phrase, or nil if it's fine.
    public static func problem(_ name: String) -> String? {
        if name.isEmpty { return "a name can't be empty" }
        if name.utf8.count > 64 { return "that's too long (64 bytes at most)" }
        if name != name.trimmingCharacters(in: .whitespacesAndNewlines) { return "no spaces at the start or end" }
        if name.contains(where: { "#@<>".contains($0) }) { return "names can't contain # @ < >" }
        if name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || isBidiOverride($0) }) {
            return "no control characters"
        }
        return nil
    }

    private static func isBidiOverride(_ s: Unicode.Scalar) -> Bool {
        (0x202A...0x202E).contains(s.value) || (0x2066...0x2069).contains(s.value)
    }
}
