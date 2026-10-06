/// What the demo rooms talk about: OneShotChat itself, mostly tongue in cheek. Edit freely;
/// nothing here leaves the machine. `{me}` becomes a real mention of you.
struct DemoScript {
    var lines: [String]
    /// Messages that mention you (they ripple the floor and beam to your glyph).
    var mentions: [String]
    /// Said back to you, sometimes, after you post.
    var replies: [String] = DemoScript.commonReplies

    static func forRoom(_ name: String) -> DemoScript {
        switch name {
        case "lobby": lobby
        case "dev", "protocol": dev
        case "clients", "showcase": clients
        case "offtopic", "late-night", "retro": offtopic
        default: general
        }
    }

    static let commonReplies = [
        "this ^", "ha, agreed", "100%", "big if true", "came here to say this", "noted ✦",
        "honestly yes", "can confirm", "ok this is the best take today",
    ]

    static let lobby = DemoScript(lines: [
        "just found OneShotChat. a chat where messages expire? finally, my bad takes have a shelf life",
        "the whole protocol fits in one doc. I read it on the bus",
        "no DMs, no read receipts, no typing indicators. it's so calm in here",
        "my identity is a keypair. my personality is also a keypair now",
        "is this the room where people say hi?",
        "hi 👋",
        "the lobby keeps messages for seven days, then poof",
        "just passed !test in #conformance 🎉",
        "every room is readable by the operator, so I only post my good opinions",
        "tripcodes are such a good idea. there are three sams here and I can tell them apart",
        "anyone else here because of the 3D client?",
        "I came for the chat, stayed for the Ed25519",
        "nothing lasts forever ✦ (except this room's topic)",
        "how do I get my name in colour?\noh wait, it's from my fingerprint. cool",
    ], mentions: [
        "{me} welcome! first time here?",
        "{me} have you tried the ring layout yet? ⌘G",
        "{me} which client are you on? that glow is incredible",
    ])

    static let dev = DemoScript(lines: [
        "reminder: seq can have gaps. don't assume +1",
        "after a laptop sleep: reconnect, then GET …/events?after=last. that's the whole recovery story",
        "signed message string is just lines joined with \\n, no trailing newline. took me a while",
        "base32, lowercase, no padding. say it with me",
        "if you get 409 version_conflict on an edit, someone edited from another device. refetch, retry",
        "mentions are <@fingerprint>, not @name. typed @name is just text",
        "presence lapses after 5 min. ping the socket every 2",
        "rate limited again. Retry-After is a gift, honour it",
        "CryptoKit signatures are randomised but still verify fine against the test vectors",
        "the protocol says: if a message looks like a system message, it isn't. only notices are",
        "who else verifies signatures client-side instead of trusting the server?",
        "pinning rooms by fingerprint with `expect` is such a nice touch",
        "PR idea: petnames keyed by full fingerprint",
        "events and the WebSocket send the same objects. one parser, two pipes",
        "anyone benchmarked the events endpoint? polling every 3s feels fine",
    ], mentions: [
        "{me} does phosphor sign messages by default?",
        "{me} how are you handling catch-up after a reconnect?",
        "{me} any tips for rendering mentions as names?",
    ])

    static let clients = DemoScript(lines: [
        "has anyone seen phosphor? it's a vector-display client. the whole thing glows",
        "messages beam up from your avatar and get written on like an oscilloscope",
        "leaving a room in phosphor vaporises it. I've left and rejoined #lobby six times just to watch",
        "it passed the conformance bot in 32 seconds apparently",
        "there's a ring mode and a row mode and I can't pick a favourite",
        "the mention ripple across the floor grid is very unnecessary and I love it",
        "my terminal client feels so flat now",
        "who knew a chat client needed bloom",
        "the room browser shows who's in a room before you join. very nice",
        "ok but does it run on my toaster",
        "native mac, metal, no electron. my fans are silent",
    ], mentions: [
        "{me} is that you on phosphor? your glyph is spinning",
        "{me} screenshot please, I need to see this ring mode",
    ])

    static let offtopic = DemoScript(lines: [
        "coffee count: 3",
        "it's raining here, perfect chat weather",
        "anyone watching the meteor shower tonight?",
        "I renamed my cat to ed25519",
        "brb, making toast",
        "back. the toast was great",
        "my plant has more uptime than my last job",
        "hot take: the best keyboard is the one you already own",
        "someone recommend a sci-fi book, I've run out",
        "the cat just walked across the keyboard and sent nothing. respect",
        "weekend plans: absolutely none, it's going to be great",
        "today's soundtrack: synthwave, obviously",
    ], mentions: [
        "{me} tea or coffee?",
    ])

    static let general = DemoScript(lines: [
        "hello from the other side of the overview",
        "nice room, cosy",
        "who picked this topic?",
        "first! (is that still a thing)",
        "OneShotChat appreciation post ✦",
    ], mentions: [
        "{me} welcome in!",
    ])
}
