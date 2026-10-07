import Testing
@testable import OSCCore

@Test func ordinaryNamesAreFine() {
    for name in ["sam", "Ada Lovelace", "théo", "🦊", "👩‍💻 dev", String(repeating: "a", count: 64)] {
        #expect(DisplayName.problem(name) == nil, "\(name)")
    }
}

@Test func namesBreakingTheRulesAreRefused() {
    for name in ["", " sam", "sam ", "sam#a7", "@sam", "<sam>", "a\u{7}b", "a\u{202E}b", "x\u{2066}",
                 String(repeating: "é", count: 33)] {       // 66 bytes
        #expect(DisplayName.problem(name) != nil, "\(name)")
    }
}
