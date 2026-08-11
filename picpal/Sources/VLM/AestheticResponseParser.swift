// MARK: - AestheticResponseParser

/// Pure, strict parser that converts raw VLM response text into an `AestheticSignal`.
///
/// **Design principle: silence is the safe output.**
/// The parser rejects anything ambiguous rather than trying to salvage it. A quiet
/// coach is always better than a wrong one. Rejection rules apply in order; the
/// first matching rule wins.
///
/// **Rejection rules (applied in order)**
/// 1. Trimmed text is empty → `.nothingToSay`
/// 2. Text equals `NOTHING_TO_SAY` (case-insensitive) → `.nothingToSay`
/// 3. Text starts with `{` or `[` (malformed JSON/structured data) → `.nothingToSay`
/// 4. Word count exceeds `maxRemarkWords` → `.nothingToSay` (not truncated)
/// 5. Contains multiple sentences (>1 terminal punctuation ending a sentence) → `.nothingToSay`
/// 6. Contains hedging phrases (see `hedgingPhrases`) → `.nothingToSay`
/// 7. Otherwise → `AestheticSignal(remark: trimmed, confidence: remarkedConfidence, hint: .remark)`
public enum AestheticResponseParser {

    // MARK: - Named constants

    /// The exact token the model must return when it has no useful feedback.
    static let nothingToSayToken: String = "NOTHING_TO_SAY"

    /// Maximum number of words a valid remark may contain.
    /// Mirrors `AestheticPrompt.maxRemarkWords` — defined here as a named constant
    /// so the parser stays self-contained even if the prompt evolves.
    static let maxRemarkWords: Int = AestheticPrompt.maxRemarkWords

    /// Confidence value for successfully parsed remarks.
    private static let remarkedConfidence: Float = 1.0

    /// Confidence value for rejected remarks.
    private static let rejectedConfidence: Float = 0.0

    /// Phrases that signal model uncertainty or hedging. Any response containing
    /// one of these substrings (case-insensitive) is rejected as `.nothingToSay`.
    static let hedgingPhrases: [String] = [
        "i think",
        "maybe",
        "perhaps",
        "i'm not sure",
        "it seems",
        "you might",
        "could be",
        "if you",
        "consider"
    ]

    // MARK: - Public API

    /// Parse the raw VLM response text into an `AestheticSignal`.
    ///
    /// - Parameter response: The raw string returned by the VLM.
    /// - Returns: An `AestheticSignal` with `.remark` on success, or `.nothingToSay`
    ///   on any rejection. Never throws.
    public static func parse(_ response: String) -> AestheticSignal {
        // Rule 1: empty / whitespace-only
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .nothingToSay
        }

        // Rule 2: explicit nothing-to-say token (case-insensitive)
        if trimmed.uppercased() == nothingToSayToken {
            return .nothingToSay
        }

        // Rule 3: malformed JSON / structured data (starts with { or [)
        if trimmed.first == "{" || trimmed.first == "[" {
            return .nothingToSay
        }

        // Rule 4: over-length (reject; never truncate)
        let wordCount = trimmed
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .count
        guard wordCount <= maxRemarkWords else {
            return .nothingToSay
        }

        // Rule 5: multiple sentences
        // Count terminal-punctuation characters that end a word boundary
        // (period, exclamation mark, question mark). Two or more → multi-sentence.
        if hasMultipleSentences(trimmed) {
            return .nothingToSay
        }

        // Rule 6: hedging language (case-insensitive substring match)
        let lowered = trimmed.lowercased()
        for phrase in hedgingPhrases {
            if lowered.contains(phrase) {
                return .nothingToSay
            }
        }

        // Rule 7: valid remark
        return AestheticSignal(remark: trimmed, confidence: remarkedConfidence, hint: .remark)
    }

    // MARK: - Private helpers

    /// Returns `true` when `text` contains more than one sentence-terminating
    /// punctuation mark (`.`, `!`, `?`).
    ///
    /// Strategy: count runs of terminal punctuation rather than individual
    /// characters, so `"..."` or `"!!"` each count as one sentence end.
    private static func hasMultipleSentences(_ text: String) -> Bool {
        let terminators: Set<Character> = [".", "!", "?"]
        var sentenceEndCount = 0
        var previousWasTerminator = false

        for char in text {
            if terminators.contains(char) {
                if !previousWasTerminator {
                    sentenceEndCount += 1
                }
                previousWasTerminator = true
            } else {
                previousWasTerminator = false
            }
        }

        return sentenceEndCount > 1
    }
}
