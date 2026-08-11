// MARK: - StaleSuppressor

/// Dual-tag stale-suppression for VLM responses.
///
/// At request time, a tag is built from the current `SceneSignature` and the
/// concurrent `BodySignal.hint`. At response time, the tag is re-evaluated
/// against the current scene state. If either changed, the response is discarded.
///
/// **Discard-on-ambiguity**: if the current signature cannot be computed, discard.
/// Discarding is silent — no cue, no error.
///
/// `StaleSuppressor` is a `final class` so that M3-5 can hold it by reference
/// in `VLMOrchestrator`. It has no internal mutable state, so `@unchecked Sendable`
/// is correct; no lock is needed.
public final class StaleSuppressor: @unchecked Sendable {

    // MARK: - Init

    public init() {}

    // MARK: - RequestTag

    /// Immutable snapshot captured at the moment a VLM request is dispatched.
    ///
    /// Both fields are value types (`SceneSignature` and `BodyHint` are structs/enums),
    /// so `RequestTag` itself is naturally `Sendable` and `Equatable`.
    public struct RequestTag: Sendable, Equatable {
        /// Scene fingerprint at request time.
        public let signature: SceneSignature

        /// Body-framing hint at request time.
        public let bodyHint: BodyHint
    }

    // MARK: - API

    /// Build a tag at the moment a VLM request is dispatched.
    ///
    /// Call this immediately before enqueuing the network request so the
    /// snapshot reflects the frame being sent.
    public func makeTag(signature: SceneSignature, bodyHint: BodyHint) -> RequestTag {
        RequestTag(signature: signature, bodyHint: bodyHint)
    }

    /// Evaluate whether a VLM response is still valid against the current scene state.
    ///
    /// Returns the signal unchanged if all suppression rules pass; returns `nil`
    /// silently if any rule triggers.
    ///
    /// **Suppression rules (evaluated in order):**
    /// 1. `currentSignature == nil` → discard (ambiguity — cannot compare).
    /// 2. `currentSignature.isMateriallyDifferent(from: tag.signature)` → discard
    ///    (the scene has changed).
    /// 3. `currentBodyHint != tag.bodyHint` → discard (body context has changed).
    /// 4. `signal.hint == .nothingToSay` → discard (parser already rejected it;
    ///    never emit a filler cue).
    /// 5. Otherwise → return `signal`.
    ///
    /// - Parameters:
    ///   - signal: The parsed `AestheticSignal` from the VLM.
    ///   - tag: The `RequestTag` captured when the request was dispatched.
    ///   - currentSignature: The `SceneSignature` NOW. `nil` → discard (ambiguity).
    ///   - currentBodyHint: The `BodySignal.hint` NOW.
    /// - Returns: `signal` if valid; `nil` if stale or ambiguous.
    public func evaluate(
        signal: AestheticSignal,
        tag: RequestTag,
        currentSignature: SceneSignature?,
        currentBodyHint: BodyHint
    ) -> AestheticSignal? {
        // Rule 1: ambiguity — cannot determine current scene state.
        guard let current = currentSignature else { return nil }

        // Rule 2: scene has changed materially since the request was dispatched.
        guard !current.isMateriallyDifferent(from: tag.signature) else { return nil }

        // Rule 3: body-framing context has changed category.
        guard currentBodyHint == tag.bodyHint else { return nil }

        // Rule 4: parser already rejected the response — never emit a filler cue.
        guard signal.hint != .nothingToSay else { return nil }

        // Rule 5: all checks passed — signal is valid.
        return signal
    }
}
