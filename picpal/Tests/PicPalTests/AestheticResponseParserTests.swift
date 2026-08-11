import Testing
@testable import PicPal

// MARK: - AestheticResponseParserTests

/// Unit tests for `AestheticResponseParser`.
///
/// Each test maps to a named fixture response category. The parser is pure
/// (no I/O, no mutable state), so tests are isolated by construction.
@Suite("AestheticResponseParser")
struct AestheticResponseParserTests {

    // MARK: - Fixture 1: Good short remark → .remark

    @Test("Valid short remark parses to .remark with correct text")
    func validShortRemarkParsesToRemark() {
        let signal = AestheticResponseParser.parse("Move the camera left to centre the subject.")
        #expect(signal.hint == .remark)
        #expect(signal.remark == "Move the camera left to centre the subject.")
        #expect(signal.confidence == 1.0)
    }

    // MARK: - Fixture 2: NOTHING_TO_SAY token (upper-case) → .nothingToSay

    @Test("NOTHING_TO_SAY token returns .nothingToSay sentinel")
    func nothingToSayTokenUpperCase() {
        let signal = AestheticResponseParser.parse("NOTHING_TO_SAY")
        #expect(signal == .nothingToSay)
    }

    // MARK: - Fixture 3: nothing_to_say (lower-case) → .nothingToSay

    @Test("nothing_to_say in lower-case is accepted as the token")
    func nothingToSayTokenLowerCase() {
        let signal = AestheticResponseParser.parse("nothing_to_say")
        #expect(signal == .nothingToSay)
    }

    // MARK: - Fixture 4: Over-long response (> 15 words) → .nothingToSay

    @Test("Response exceeding 15 words is rejected as .nothingToSay")
    func overLongResponseRejected() {
        // 17 words
        let longRemark = "Move the camera slightly to the left so that the subject is nicely centred in the frame."
        let wordCount = longRemark
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .count
        #expect(wordCount > 15)  // guard: fixture is actually over-long
        let signal = AestheticResponseParser.parse(longRemark)
        #expect(signal == .nothingToSay)
    }

    // MARK: - Fixture 5: Multi-sentence response → .nothingToSay

    @Test("Multi-sentence response is rejected as .nothingToSay")
    func multiSentenceResponseRejected() {
        let signal = AestheticResponseParser.parse("Tilt left. Lower the camera slightly.")
        #expect(signal == .nothingToSay)
    }

    // MARK: - Fixture 6: Hedging language → .nothingToSay

    @Test("Response containing hedging language is rejected")
    func hedgingLanguageRejected() {
        let signal = AestheticResponseParser.parse("I think you should move the camera left.")
        #expect(signal == .nothingToSay)
    }

    // MARK: - Fixture 7: Empty string → .nothingToSay

    @Test("Empty string returns .nothingToSay")
    func emptyStringRejected() {
        let signal = AestheticResponseParser.parse("")
        #expect(signal == .nothingToSay)
    }

    // MARK: - Fixture 8: Whitespace-only string → .nothingToSay

    @Test("Whitespace-only string returns .nothingToSay")
    func whitespaceOnlyStringRejected() {
        let signal = AestheticResponseParser.parse("   \t\n  ")
        #expect(signal == .nothingToSay)
    }

    // MARK: - Fixture 9: Model refusal → .nothingToSay

    @Test("Model refusal is rejected as .nothingToSay")
    func modelRefusalRejected() {
        // Refusals are typically over-long; this one is 20 words — rejected by word-count rule.
        let refusal = "I cannot provide feedback on this image as it may contain sensitive content that is not appropriate for composition coaching."
        let wordCount = refusal
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .count
        #expect(wordCount > 15)  // guard: fixture is over-long
        let signal = AestheticResponseParser.parse(refusal)
        #expect(signal == .nothingToSay)
    }

    // MARK: - Fixture 10: Exactly 15-word remark (boundary) → .remark

    @Test("Remark of exactly 15 words is accepted (boundary test)")
    func exactlyFifteenWordRemarkAccepted() {
        // 15-word action-first remark (at the limit — must be accepted, not rejected)
        let remark = "Step back and tilt the camera down to include more of the interesting foreground scene"
        let wordCount = remark
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .count
        #expect(wordCount == 15)  // guard: fixture is exactly at the limit
        let signal = AestheticResponseParser.parse(remark)
        #expect(signal.hint == .remark)
        #expect(signal.remark == remark)
        #expect(signal.confidence == 1.0)
    }

    // MARK: - Additional edge cases

    @Test("Leading and trailing whitespace is trimmed before parsing")
    func leadingTrailingWhitespaceTrimmed() {
        let signal = AestheticResponseParser.parse("  Tilt left for a stronger diagonal.  ")
        #expect(signal.hint == .remark)
        #expect(signal.remark == "Tilt left for a stronger diagonal.")
    }

    @Test("Mixed-case NOTHING_TO_SAY variant is accepted")
    func nothingToSayMixedCase() {
        let signal = AestheticResponseParser.parse("Nothing_To_Say")
        #expect(signal == .nothingToSay)
    }

    @Test("Sentence ending with exclamation mark is accepted as single sentence")
    func singleSentenceWithExclamationAccepted() {
        let signal = AestheticResponseParser.parse("Step back to give the subject more space!")
        #expect(signal.hint == .remark)
    }

    @Test("Two sentences separated by question mark are rejected")
    func twoSentencesWithQuestionMarkRejected() {
        let signal = AestheticResponseParser.parse("Good framing? Try tilting left.")
        #expect(signal == .nothingToSay)
    }

    @Test("'maybe' hedging phrase triggers rejection")
    func maybePhraseRejected() {
        let signal = AestheticResponseParser.parse("Maybe tilt the camera slightly right.")
        #expect(signal == .nothingToSay)
    }

    @Test("'perhaps' hedging phrase triggers rejection")
    func perhapsPhraseRejected() {
        let signal = AestheticResponseParser.parse("Perhaps step back a little.")
        #expect(signal == .nothingToSay)
    }

    @Test("'consider' hedging phrase triggers rejection")
    func considerPhraseRejected() {
        let signal = AestheticResponseParser.parse("Consider moving the subject to the left third.")
        #expect(signal == .nothingToSay)
    }

    // MARK: - AestheticSignal sentinel shape

    @Test("nothingToSay sentinel has expected field values")
    func nothingToSaySentinelShape() {
        let sentinel = AestheticSignal.nothingToSay
        #expect(sentinel.remark == "")
        #expect(sentinel.confidence == 0.0)
        #expect(sentinel.hint == .nothingToSay)
    }
}
