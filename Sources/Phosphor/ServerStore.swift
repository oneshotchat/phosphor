import Foundation
import OSCCore

/// Which server Phosphor talks to: the real one, built in, or a custom one you've added
/// yourself (a development or local server). Custom servers live only in your settings;
/// none ships with Phosphor.
@MainActor
enum ServerStore {
    static let main = OSCClient.defaultServer

    private static let defaults = Profile.defaults

    /// Custom servers you've added, as origins.
    static var custom: [String] {
        get { defaults.stringArray(forKey: "customServers") ?? [] }
        set { defaults.set(newValue, forKey: "customServers") }
    }

    /// The server to use: the one you last chose, else the real one.
    static var current: URL {
        get { defaults.string(forKey: "currentServer").flatMap(URL.init(string:)) ?? main }
        set { defaults.set(isCustom(newValue) ? OSCClient.origin(of: newValue) : nil, forKey: "currentServer") }
    }

    static func isCustom(_ url: URL) -> Bool { OSCClient.origin(of: url) != OSCClient.origin(of: main) }

    /// What to show for a custom server: its host (and port), e.g. "api.dev.oneshotchat.com".
    static func label(_ url: URL) -> String {
        let origin = OSCClient.origin(of: url)
        return origin.hasPrefix("https://") ? String(origin.dropFirst(8)) : origin
    }

    /// An address as typed (with or without https://) → its origin, or nil. Plain http is
    /// allowed only for this Mac or the local network, where there's no certificate.
    static func normalize(_ typed: String) -> URL? {
        var s = typed.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s), let host = url.host?.lowercased(), !host.isEmpty,
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        if scheme == "http" {
            let local = host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local") || host.hasSuffix(".localhost")
            guard local else { return nil }
        }
        return URL(string: OSCClient.origin(of: url))
    }

    static func add(_ url: URL) {
        let origin = OSCClient.origin(of: url)
        if isCustom(url), !custom.contains(origin) { custom.append(origin) }
    }

    static func remove(_ url: URL) {
        custom.removeAll { $0 == OSCClient.origin(of: url) }
    }
}
