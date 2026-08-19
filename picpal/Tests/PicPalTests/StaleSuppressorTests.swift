import Testing
@testable import PicPal

// MARK: - StaleSuppressorTests

/// Unit tests for `StaleSuppressor` — dual-tag stale-suppression.
///
/// Covers all five suppression rules:
///   1. Unchanged scene + same body hint + valid remark → passes through
///   2. Luminance shift (isMateriallyDifferent) → discarded
///   3. Body hint changed category → discarded
///   4. currentSignature == nil → discarded (ambiguity)
///   5. signal.hint == .nothingToSay → discarded (no filler cue)
@Suite("StaleSuppressor")
struct StaleSuppressorTests {

    // MARK: - Fixtures
    //
    // Swift Testing creates a fresh struct instance per `@Test`, so these `let`
    // stored properties act as per-test setup — no shared mutable state.

    /// A scene signature with "low, uniform" brightness.
    private let darkScene = SceneSignature(
        meanLuminance: 0.20,
        luminanceVariance: 0.001
    )

    /// A scene signature materially different from `darkScene`
    /// (meanLuminance delta > 0.03 threshold).
    private let brightScene = SceneSignature(
        meanLuminance: 0.80,
        luminanceVariance: 0.001
    )

    /// A scene signature nearly identical to `darkScene`
    /// (both deltas within thresholds — not materially different).
    private let darkSceneSimilar = SceneSignature(
        meanLuminance: 0.21,   // delta = 0.01, threshold = 0.03 → not different
        luminanceVariance: 0.0012 // delta = 0.0002, threshold = 0.005 → not different
    )

    /// A valid signal that the suppressor should pass through.
    private let validSignal = AestheticSignal(
        remark: "Step back to include the full arch.",
        confidence: 1.0,
        hint: .remark
    )

    // MARK: - Rule 1: unchanged scene → passes through

    @Test("Unchanged scene + same body hint + valid remark passes through")
    func unchangedSceneValidSignalPassesThrough() {
        let suppressor = StaleSuppressor()
        let tag = suppressor.makeTag(signature: darkScene, bodyHint: .goodBody)

        let result = suppressor.evaluate(
            signal: validSignal,
            tag: tag,
            currentSignature: darkSceneSimilar,
            currentBodyHint: .goodBody
        )

        #expect(result == validSignal)
    }

    // MARK: - Rule 2: luminance shift → discarded

    @Test("Luminance shift makes scene materially different → discarded")
    func luminanceShiftCausesDiscard() {
        let suppressor = StaleSuppressor()
        let tag = suppressor.makeTag(signature: darkScene, bodyHint: .goodBody)

        // Verify the two signatures are actually materially different (test guard)
        #expect(brightScene.isMateriallyDifferent(from: darkScene))

        let result = suppressor.evaluate(
            signal: validSignal,
            tag: tag,
            currentSignature: brightScene,
            currentBodyHint: .goodBody
        )

        #expect(result == nil)
    }

    // MARK: - Rule 3: body hint changed → discarded

    @Test("Body hint category change → discarded")
    func bodyHintChangeCausesDiscard() {
        let suppressor = StaleSuppressor()
        let tag = suppressor.makeTag(signature: darkScene, bodyHint: .goodBody)

        let result = suppressor.evaluate(
            signal: validSignal,
            tag: tag,
            currentSignature: darkSceneSimilar,
            currentBodyHint: .awkwardCrop   // changed from .goodBody
        )

        #expect(result == nil)
    }

    // MARK: - Rule 4: nil currentSignature → discarded (ambiguity)

    @Test("Nil currentSignature triggers discard-on-ambiguity")
    func nilCurrentSignatureCausesDiscard() {
        let suppressor = StaleSuppressor()
        let tag = suppressor.makeTag(signature: darkScene, bodyHint: .goodBody)

        let result = suppressor.evaluate(
            signal: validSignal,
            tag: tag,
            currentSignature: nil,
            currentBodyHint: .goodBody
        )

        #expect(result == nil)
    }

    // MARK: - Rule 5: nothingToSay signal → discarded (no filler)

    @Test("Signal with .nothingToSay hint → discarded even when scene unchanged")
    func nothingToSaySignalIsDiscarded() {
        let suppressor = StaleSuppressor()
        let tag = suppressor.makeTag(signature: darkScene, bodyHint: .goodBody)

        let result = suppressor.evaluate(
            signal: .nothingToSay,
            tag: tag,
            currentSignature: darkSceneSimilar,
            currentBodyHint: .goodBody
        )

        #expect(result == nil)
    }

    // MARK: - Rule 5 (variant): nothingToSay from remark perspective → discarded

    @Test("Explicit nothingToSay signal is discarded even with all other conditions met")
    func explicitNothingToSayDiscarded() {
        let suppressor = StaleSuppressor()
        let tag = suppressor.makeTag(signature: darkScene, bodyHint: .nudgeUpHeadroom)

        // Construct a signal that would look like a failed parse output
        let noopSignal = AestheticSignal(
            remark: "",
            confidence: 0.0,
            hint: .nothingToSay
        )

        let result = suppressor.evaluate(
            signal: noopSignal,
            tag: tag,
            currentSignature: darkSceneSimilar,
            currentBodyHint: .nudgeUpHeadroom
        )

        #expect(result == nil)
    }

    // MARK: - RequestTag equality

    @Test("Two tags with same signature and body hint are equal")
    func requestTagEquality() {
        let suppressor = StaleSuppressor()
        let tag1 = suppressor.makeTag(signature: darkScene, bodyHint: .gazeAway)
        let tag2 = suppressor.makeTag(signature: darkScene, bodyHint: .gazeAway)
        #expect(tag1 == tag2)
    }

    @Test("Two tags with different body hint are not equal")
    func requestTagInequalityBodyHint() {
        let suppressor = StaleSuppressor()
        let tag1 = suppressor.makeTag(signature: darkScene, bodyHint: .goodBody)
        let tag2 = suppressor.makeTag(signature: darkScene, bodyHint: .lensObstructed)
        #expect(tag1 != tag2)
    }

    // MARK: - Multiple independent suppressor instances

    @Test("Two suppressor instances behave independently")
    func independentInstances() {
        let s1 = StaleSuppressor()
        let s2 = StaleSuppressor()

        let tag1 = s1.makeTag(signature: darkScene, bodyHint: .goodBody)
        let tag2 = s2.makeTag(signature: brightScene, bodyHint: .goodBody)

        // s1 tag against bright current scene → discarded
        let result1 = s1.evaluate(
            signal: validSignal,
            tag: tag1,
            currentSignature: brightScene,
            currentBodyHint: .goodBody
        )
        #expect(result1 == nil)

        // s2 tag against bright current scene → passes (tag signature was bright)
        let result2 = s2.evaluate(
            signal: validSignal,
            tag: tag2,
            currentSignature: brightScene,
            currentBodyHint: .goodBody
        )
        #expect(result2 == validSignal)
    }
}
