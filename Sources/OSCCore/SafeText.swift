/// Chat text is written by strangers. Before showing it anywhere, replace control
/// characters (terminal escapes) and bidirectional overrides (which can make text
/// read differently from what was sent). Newlines survive; tabs become spaces.
public enum SafeText {
    public static func clean(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            switch scalar.value {
            case 0x0A: scalar
            case 0x09: " "
            case 0x00..<0x20, 0x7F..<0xA0, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: "\u{FFFD}"
            default: scalar
            }
        }))
    }
}
