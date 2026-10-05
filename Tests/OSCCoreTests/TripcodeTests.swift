import Testing
@testable import OSCCore

@Test func uniqueNameHasNoTripcode() {
    let labels = Tripcode.labels(for: [("sam", "a7fq"), ("ada", "a7cq")])
    #expect(labels == ["a7fq": "sam", "a7cq": "ada"])
}

@Test func sharedNamesGetShortestDistinctPrefix() {
    let labels = Tripcode.labels(for: [("sam", "a7fq"), ("sam", "a7cq"), ("sam", "bzzz"), ("ada", "a7fz")])
    #expect(labels["a7fq"] == "sam#a7f")
    #expect(labels["a7cq"] == "sam#a7c")
    #expect(labels["bzzz"] == "sam#b")
    #expect(labels["a7fz"] == "ada")
}

@Test func sameFingerprintTwiceIsOnePerson() {
    let labels = Tripcode.labels(for: [("sam", "a7fq"), ("sam", "a7fq")])
    #expect(labels == ["a7fq": "sam"])
}
