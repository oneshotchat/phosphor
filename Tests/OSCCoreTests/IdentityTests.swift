import Foundation
import Testing
@testable import OSCCore

// Values from Appendix A of https://api.oneshotchat.com/v1/docs/protocol.md
private let server = "https://api.oneshotchat.com"
private let seed = "aaaqeayeaudaocajbifqydiob4ibceqtcqkrmfyydenbwha5dypq"
private let fingerprint = "aoqqpp7tzyil4hlq3umoos6atft6jvrqtosq2xy53sdgiesvgg4a"
private let challenge = "ucq2fi5euwtkpkfjvkv2zlnov6yldmvtws23nn5yxg5lxpf5x27q"
private let loginSignature = "z5zei344qrqbaniwwrydxop4am5obm7pha6bu5yk4572zcp3djplidm7kx53xablztzb4pbqkw2b7dl6e3cwegrjtudlwo5ggr3wacy"

@Test func base32EncodesSeedBytes() {
    #expect(Base32.encode((0..<32).map { UInt8($0) }) == seed)
    #expect(Base32.encode((0xa0...0xbf).map { UInt8($0) }) == challenge)
}

@Test func base32RoundTrips() {
    for length in 0..<70 {
        let bytes = (0..<length).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }
        let encoded = Base32.encode(bytes)
        #expect(Base32.decode(encoded) == Data(bytes))
        #expect(Base32.decode(encoded.uppercased() + "======") == Data(bytes))
    }
    #expect(Base32.decode("abc!") == nil)
}

@Test func fingerprintFromSeed() throws {
    #expect(try Identity(seed: seed).fingerprint == fingerprint)
}

@Test func loginVectorVerifies() {
    let string = SignedString.login(server: server, identity: fingerprint, challenge: challenge)
    #expect(Identity.verify(signature: loginSignature, of: string, fingerprint: fingerprint))
    #expect(!Identity.verify(signature: loginSignature, of: string + "x", fingerprint: fingerprint))
}

@Test func ourSignaturesVerify() throws {
    let id = try Identity(seed: seed)
    let string = SignedString.login(server: server, identity: id.fingerprint, challenge: challenge)
    let sig = try id.sign(string)
    #expect(sig.count == 103)
    #expect(Identity.verify(signature: sig, of: string, fingerprint: id.fingerprint))
}

// MARK: message, edit and retire vectors

private let room = "ibaueq2eivdeoscjjjfuytkoj4"
private let messageText = "hello <@\(fingerprint)> 👋\nsecond line"

@Test func roomVectorEncodes() {
    #expect(Base32.encode((0x40...0x4f).map { UInt8($0) }) == room)
}

@Test func messageVectorVerifies() {
    let string = SignedString.message(server: server, room: room, author: fingerprint, nonce: "01hzx7k2m9", version: 1, text: messageText)
    #expect(string == "oneshotchat/v1/message\nserver:https://api.oneshotchat.com\nroom:\(room)\nauthor:\(fingerprint)\nnonce:01hzx7k2m9\nversion:1\n\(messageText)")
    #expect(Identity.verify(signature: "eamc7n7p5zuvqvdy6vuazz4d4lpekvahyksxepseyhs6mgabla47weo543dnioirlotht72pjruybm4aprnjxbigyajzib4ket5iqcy",
                            of: string, fingerprint: fingerprint))
}

@Test func editVectorVerifies() {
    let string = SignedString.message(server: server, room: room, author: fingerprint, nonce: "01hzx7k2m9", version: 2, text: "hello again")
    #expect(Identity.verify(signature: "zuf66ul3m6lxwwqq6volbgle3wpflxzb7qkywqebtabb3y2d5mb7hbsrooq5lpp26qbcnxwfb3yfhufb4ocz332pkjmki7vs6sxrwcy",
                            of: string, fingerprint: fingerprint))
}

@Test func retireVectorVerifies() {
    #expect(Identity.verify(signature: "bxg36lyugvtkbbugavqgus5quohpfy7pwlimf7uf7oz4rwvhv4iz46stlrargyvr6bliw3g2unio76bbl4cjnq6rmxnx423ty5lxadi",
                            of: SignedString.retire(server: server, identity: fingerprint), fingerprint: fingerprint))
}

@Test func originIsNormalized() {
    #expect(OSCClient.origin(of: URL(string: "https://API.oneshotchat.com/v1/")!) == "https://api.oneshotchat.com")
    #expect(OSCClient.origin(of: URL(string: "https://api.oneshotchat.com:443")!) == "https://api.oneshotchat.com")
    #expect(OSCClient.origin(of: URL(string: "http://localhost:8080")!) == "http://localhost:8080")
    #expect(OSCClient.origin(of: URL(string: "http://localhost:80")!) == "http://localhost")
}

// MARK: identity file

@Test func identityFileRoundTripsWithOwnerOnlyPermissions() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("me.identity")

    let (created, _) = try IdentityFile.loadOrCreate(at: url, name: "sam")
    let (loaded, file) = try IdentityFile.loadOrCreate(at: url)
    #expect(loaded.fingerprint == created.fingerprint)
    #expect(file.name == "sam")
    let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    #expect(perms == 0o600)
}

@Test func identityFileRejectsMismatchedFingerprint() throws {
    var file = IdentityFile(identity: try Identity(seed: seed), name: nil)
    file.identity = Identity.generate().fingerprint
    #expect(throws: IdentityError.fingerprintMismatch) { try file.load() }
}
