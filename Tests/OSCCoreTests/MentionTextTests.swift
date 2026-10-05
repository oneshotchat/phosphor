import Testing
@testable import OSCCore

private let a = String(repeating: "a", count: 52)
private let b = "b" + String(repeating: "7", count: 51)

@Test func segmentsSplitMentionsAndText() {
    #expect(MentionText.segments("hi <@\(a)>!") == [.text("hi "), .mention(fingerprint: a), .text("!")])
    #expect(MentionText.segments("<@\(a)><@\(b)>") == [.mention(fingerprint: a), .mention(fingerprint: b)])
}

@Test func lookalikeTokensStayText() {
    #expect(MentionText.segments("<@short> <@\(a.uppercased())>") == [.text("<@short> <@\(a.uppercased())>")])
}

@Test func composeUsesLongestLabelAndWordBoundaries() {
    let labels = ["sam#a": a, "sam#b": b, "sa": a]
    #expect(MentionText.compose("@sam#a and @sam#b, not @samwise or sam#a", labels: labels)
        == "<@\(a)> and <@\(b)>, not @samwise or sam#a")
    #expect(MentionText.compose("hey @sa.", labels: labels) == "hey <@\(a)>.")
}

@Test func displayRendersLabels() {
    #expect(MentionText.display("hi <@\(a)>", label: { $0 == a ? "sam" : "?" }) == "hi @sam")
}

@Test func safeTextStripsEscapesAndBidiOverrides() {
    #expect(SafeText.clean("a\u{1B}[2Jb\tc\nd\u{202E}e") == "a\u{FFFD}[2Jb c\nd\u{FFFD}e")
}
