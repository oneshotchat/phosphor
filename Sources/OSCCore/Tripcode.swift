/// Display labels for the people in view (protocol §3, "Tripcodes").
///
/// A name shared by several fingerprints gets `#` plus the shortest fingerprint prefix
/// that no one else with that name shares, like git's short hashes. A tripcode is a
/// convenience, not proof of identity.
public enum Tripcode {
    /// - Returns: label keyed by fingerprint.
    public static func labels(for people: [(name: String, fingerprint: String)]) -> [String: String] {
        var namesByFingerprint: [String: String] = [:]
        for person in people { namesByFingerprint[person.fingerprint] = person.name }

        let groups = Dictionary(grouping: namesByFingerprint.keys) { namesByFingerprint[$0]! }
        var labels: [String: String] = [:]
        for (name, fingerprints) in groups {
            guard fingerprints.count > 1 else {
                labels[fingerprints[0]] = name
                continue
            }
            for fingerprint in fingerprints {
                let others = fingerprints.filter { $0 != fingerprint }
                var length = 1
                while length < fingerprint.count,
                      others.contains(where: { $0.hasPrefix(fingerprint.prefix(length)) }) {
                    length += 1
                }
                labels[fingerprint] = "\(name)#\(fingerprint.prefix(length))"
            }
        }
        return labels
    }
}
