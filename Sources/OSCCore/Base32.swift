import Foundation

/// RFC 4648 base32 as OneShotChat uses it: lowercase alphabet, no padding.
public enum Base32 {
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)

    private static let decodeTable: [UInt8: UInt8] = {
        var table: [UInt8: UInt8] = [:]
        for (i, c) in "abcdefghijklmnopqrstuvwxyz234567".enumerated() {
            table[c.asciiValue!] = UInt8(i)
            table[Character(c.uppercased()).asciiValue!] = UInt8(i)
        }
        return table
    }()

    public static func encode<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        var out: [UInt8] = []
        var buffer: UInt64 = 0
        var bits = 0
        for byte in bytes {
            buffer = (buffer << 8) | UInt64(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[Int((buffer >> UInt64(bits)) & 31)])
            }
            buffer &= (1 << UInt64(bits)) - 1
        }
        if bits > 0 {
            out.append(alphabet[Int((buffer << UInt64(5 - bits)) & 31)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Accepts either case and ignores `=` padding. Returns nil on any other character.
    public static func decode(_ string: String) -> Data? {
        var out = Data()
        var buffer: UInt64 = 0
        var bits = 0
        for c in string.utf8 where c != UInt8(ascii: "=") {
            guard let value = decodeTable[c] else { return nil }
            buffer = (buffer << 5) | UInt64(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> UInt64(bits)) & 0xff))
            }
            buffer &= (1 << UInt64(bits)) - 1
        }
        return out
    }
}
