import Foundation

/// Four-gate authorization layer for VLM tier requests.
///
/// `shouldRequest(signature:isSettled:)` returns `true` only when **all four**
/// gates pass. Short-circuits on the first failure (cheapest gate first).
///
/// ## Gate order
/// 1. **Settle** — `isSettled` boolean supplied by the caller (no computation).
/// 2. **Novelty** — scene materially changed since the *last authorized request*,
///    not the current frame. Prevents asking the VLM about the same scene twice.
/// 3. **Cadence cap** — sufficient interval has elapsed since the last authorized
///    request. Limits VLM call rate without blocking camera delivery.
/// 4. **Budget** — `VLMSessionBudget.tryConsume()`. Called last because
///    budget depletion is permanent and irreversible.
///
/// ## Value-type design
/// `VLMRequestGate` is a `struct` because it holds no reference state of its
/// own — budget is injected as a class. The caller must ensure single-threaded
/// access to `shouldRequest` (same contract as `LandmarkCadenceController`).
///
/// ## Injectable clock
/// The `clock` closure mirrors `LandmarkCadenceController`'s pattern:
/// `@escaping @Sendable () -> TimeInterval`. Tests inject a `TestClock`; the
/// default uses `Date().timeIntervalSince1970`.
public struct VLMRequestGate: Sendable {

    // MARK: - Named constant

    /// Default minimum interval between authorized VLM requests (seconds).
    /// Changing this value is a one-line edit — no other callsites need updating.
    public static let defaultCadenceSeconds: TimeInterval = 8.0

    // MARK: - Dependencies

    private let cadenceSeconds: TimeInterval
    private let budget: VLMSessionBudget
    private let clock: @Sendable () -> TimeInterval

    // MARK: - Mutable gate state

    /// Scene signature at the time of the most recent authorized request.
    ///
    /// `nil` before the first authorization — the novelty gate is open on the
    /// very first call so there is always at least one authorized request.
    private var lastRequestSignature: SceneSignature?

    /// Wall-clock timestamp (`clock()`) of the most recent authorized request.
    ///
    /// Initialised to `0` so the cadence gate is open on the first call when
    /// the injected clock returns any positive value.
    private var lastAuthorizedTime: TimeInterval

    // MARK: - Init

    /// Creates a `VLMRequestGate` with the given cadence cap, budget, and clock.
    ///
    /// - Parameters:
    ///   - cadenceSeconds: Minimum seconds between authorized requests.
    ///     Defaults to `defaultCadenceSeconds`.
    ///   - budget: Shared session budget counter. Defaults to a fresh
    ///     `VLMSessionBudget` with the standard cap.
    ///   - clock: Returns the current time as a `TimeInterval`. Defaults to
    ///     `Date().timeIntervalSince1970`. Injectable for deterministic testing.
    public init(
        cadenceSeconds: TimeInterval = VLMRequestGate.defaultCadenceSeconds,
        budget: VLMSessionBudget = VLMSessionBudget(),
        clock: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.cadenceSeconds = cadenceSeconds
        self.budget = budget
        self.clock = clock
        self.lastRequestSignature = nil
        self.lastAuthorizedTime = -.infinity
    }

    var isBudgetExhausted: Bool { budget.isExhausted }
    mutating func consumeRetry() -> Bool { budget.tryConsume() }

    // MARK: - Public API

    /// Returns `true` only when all four gates pass.
    ///
    /// On a successful authorization the current `signature` is recorded as the
    /// new "last request signature" and the authorization timestamp is updated.
    /// This ensures subsequent calls enforce novelty and cadence from the correct
    /// baseline.
    ///
    /// The budget is consumed **only** when gates 1–3 all pass, so a depleted
    /// budget does not double-count calls that were blocked by earlier gates.
    ///
    /// - Parameters:
    ///   - signature: Scene fingerprint computed by the caller from the pixel
    ///     buffer (e.g. via `SceneSignature.compute(from:)`).
    ///   - isSettled: Whether the scene has settled, as reported by
    ///     `SceneGate` / `TiltMonitor`.
    /// - Returns: `true` when all four gates pass; `false` on first failure.
    /// Non-consuming eligibility, also used before cache delivery and image preparation.
    func isEligible(signature: SceneSignature?, isSettled: Bool, allowsVerification: Bool = false) -> Bool {
        guard isSettled else { return false }
        if !allowsVerification, let signature, let last = lastRequestSignature,
           !signature.isMateriallyDifferent(from: last) { return false }
        return clock() - lastAuthorizedTime >= cadenceSeconds
    }

    mutating func recordDelivery(signature: SceneSignature?) {
        lastRequestSignature = signature
        lastAuthorizedTime = clock()
    }

    /// Commit only at the actual transport boundary, after encoding and cancellation checks.
    mutating func consumeNetworkAttempt(signature: SceneSignature?) -> Bool {
        guard budget.tryConsume() else { return false }
        recordDelivery(signature: signature)
        return true
    }

    /// Convenience combined authorization for callers dispatching immediately.
    public mutating func shouldRequest(signature: SceneSignature, isSettled: Bool, allowsVerification: Bool = false) -> Bool {
        guard isEligible(signature: signature, isSettled: isSettled, allowsVerification: allowsVerification) else { return false }
        return consumeNetworkAttempt(signature: signature)
    }
}
