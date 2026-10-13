/// Emoji without hunting for them: the quick reactions `/react ` suggests, and the
/// `:shortcode:` names that turn into emoji as you type (in the input, where you see it
/// happen, so nothing is changed behind your back).
enum Emoji {
    /// What `/react ` suggests, most used first.
    static let quickReactions: [(emoji: String, name: String)] = [
        ("👍", "thumbs up"), ("❤️", "heart"), ("😂", "laughing"), ("🎉", "party"),
        ("👀", "eyes"), ("🔥", "fire"), ("🙏", "thanks"), ("✅", "done"),
    ]

    /// The usual GitHub and Slack names.
    static let shortcodes: [String: String] = [
        "+1": "👍", "thumbsup": "👍", "thumbs_up": "👍", "-1": "👎", "thumbsdown": "👎",
        "heart": "❤️", "joy": "😂", "laughing": "😆", "smile": "😄", "slightly_smiling_face": "🙂",
        "wink": "😉", "thinking": "🤔", "tada": "🎉", "party": "🎉", "eyes": "👀", "fire": "🔥",
        "pray": "🙏", "thanks": "🙏", "clap": "👏", "wave": "👋", "ok_hand": "👌", "100": "💯",
        "rocket": "🚀", "sparkles": "✨", "star": "⭐", "check": "✅", "white_check_mark": "✅",
        "x": "❌", "warning": "⚠️", "bug": "🐛", "zap": "⚡", "coffee": "☕", "cry": "😢",
        "sob": "😭", "sweat_smile": "😅", "grimacing": "😬", "shrug": "🤷", "facepalm": "🤦",
        "muscle": "💪", "raised_hands": "🙌", "skull": "💀", "heart_eyes": "😍", "sunglasses": "😎",
    ]

    /// `:name:` → its emoji, or the text unchanged.
    static func expand(_ s: String) -> String {
        guard s.count > 2, s.hasPrefix(":"), s.hasSuffix(":") else { return s }
        return shortcodes[String(s.dropFirst().dropLast()).lowercased()] ?? s
    }
}
