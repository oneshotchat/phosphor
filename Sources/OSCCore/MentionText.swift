import Foundation

/// Mentions on the wire are `<@fingerprint>` (§7). Typed `@name` text is not a mention,
/// so the client turns a picked person into a token, and tokens back into labels.
public enum MentionText {
    public enum Segment: Equatable, Sendable {
        case text(String)
        case mention(fingerprint: String)
    }

    private static let token = try! NSRegularExpression(pattern: "<@([a-z2-7]{52})>")

    public static func token(for fingerprint: String) -> String { "<@\(fingerprint)>" }

    /// Splits message text into plain runs and mentions. Anything that only looks like a
    /// mention (wrong length, bad alphabet) stays text.
    public static func segments(_ text: String) -> [Segment] {
        let ns = text as NSString
        var segments: [Segment] = []
        var cursor = 0
        for match in token.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor {
                segments.append(.text(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))))
            }
            segments.append(.mention(fingerprint: ns.substring(with: match.range(at: 1))))
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length { segments.append(.text(ns.substring(from: cursor))) }
        return segments
    }

    /// Replaces `@label` with `<@fingerprint>` for each label in `labels` (label → fingerprint).
    /// Labels should be tripcode labels, which are unique among the people in view, so a
    /// picked `@sam#a7` is never ambiguous. Longest labels win, so `@sam#a7` beats `@sam`.
    public static func compose(_ text: String, labels: [String: String]) -> String {
        var result = text
        for label in labels.keys.sorted(by: { $0.count > $1.count }) {
            let escaped = NSRegularExpression.escapedPattern(for: "@" + label)
            // Not followed by another name character, so `@sam` doesn't eat `@samwise`.
            guard let regex = try? NSRegularExpression(pattern: escaped + "(?![\\p{L}\\p{N}_#-])") else { continue }
            let template = NSRegularExpression.escapedTemplate(for: token(for: labels[label]!))
            result = regex.stringByReplacingMatches(in: result, range: NSRange(location: 0, length: (result as NSString).length),
                                                    withTemplate: template)
        }
        return result
    }

    /// Renders tokens as `@label` for display.
    public static func display(_ text: String, label: (String) -> String) -> String {
        segments(text).map {
            switch $0 {
            case .text(let s): s
            case .mention(let fingerprint): "@" + label(fingerprint)
            }
        }.joined()
    }
}
