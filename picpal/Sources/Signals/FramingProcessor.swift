import CoreGraphics

/// Pure computation: subject bounding box (Vision normalized coords) → `FramingSignal`.
///
/// `FramingProcessor` is a stateless, immutable value type. All configuration is fixed
/// at init time. `process(subjectBox:)` is safe to call from any thread concurrently.
///
/// ## Coordinate conventions
/// Vision bounding boxes use **bottom-left** origin (y = 0 at bottom, y = 1 at top).
/// This processor converts to **UIKit** / screen coords (top-left origin) before applying
/// the rule-of-thirds grid.
public struct FramingProcessor: Sendable {

    // MARK: - Thirds grid (named constants — no bare literals)

    private static let oneThird: Double  = 1.0 / 3.0
    private static let twoThirds: Double = 2.0 / 3.0

    // MARK: - Default constants

    /// Default directional dead-zone fraction (5% of the frame dimension).
    ///
    /// A subject whose center lies within this distance of a thirds intersection on an axis
    /// is considered correctly composed on that axis.
    public static let defaultDeadZoneFraction: Double = 0.05

    /// Default center dead-zone fraction (10% Euclidean radius around the frame centre).
    ///
    /// A subject whose centre lies within this radius of the frame centre (0.5, 0.5) is
    /// flagged as `tooCentered` regardless of thirds proximity.
    public static let defaultCenterDeadZoneFraction: Double = 0.10

    // MARK: - Instance configuration

    /// Directional dead-zone fraction in use.
    public let deadZoneFraction: Double

    /// Center dead-zone radius fraction in use.
    public let centerDeadZoneFraction: Double

    // MARK: - Init

    /// Creates a `FramingProcessor` with the given configuration.
    ///
    /// - Parameters:
    ///   - deadZoneFraction: Axis-aligned tolerance around each thirds intersection.
    ///   - centerDeadZoneFraction: Euclidean radius around (0.5, 0.5) that triggers
    ///     `.tooCentered`.
    public init(
        deadZoneFraction: Double = FramingProcessor.defaultDeadZoneFraction,
        centerDeadZoneFraction: Double = FramingProcessor.defaultCenterDeadZoneFraction
    ) {
        self.deadZoneFraction       = deadZoneFraction
        self.centerDeadZoneFraction = centerDeadZoneFraction
    }

    // MARK: - Public API

    /// Compute a `FramingSignal` from a Vision-normalized subject bounding box.
    ///
    /// **Hint priority:**
    /// 1. `subjectBox == nil` → `.noSubject`
    /// 2. Subject centre within `centerDeadZoneFraction` of (0.5, 0.5) → `.tooCentered`
    /// 3. Both axes within `deadZoneFraction` of nearest thirds intersection → `.goodFrame`
    /// 4. Dominant-axis nudge: `.nudgeLeft`, `.nudgeRight`, `.nudgeUp`, or `.nudgeDown`
    ///
    /// - Parameter subjectBox: Normalized bounding box in Vision coords (origin bottom-left).
    ///   Pass `nil` when saliency found no subject.
    public func process(subjectBox: CGRect?) -> FramingSignal {
        guard let box = subjectBox else {
            return FramingSignal(subjectBox: nil, hint: .noSubject)
        }

        // Convert Vision centre (bottom-left origin) to UIKit centre (top-left origin).
        let centerX = Double(box.midX)
        let centerY = 1.0 - Double(box.midY)

        // Priority 2: too centred.
        let distToFrameCenter = hypot(centerX - 0.5, centerY - 0.5)
        if distToFrameCenter < centerDeadZoneFraction {
            return FramingSignal(subjectBox: box, hint: .tooCentered)
        }

        // Find the nearest of the four rule-of-thirds intersection points (UIKit coords).
        let nearest = nearestThirds(to: centerX, y: centerY)

        let horizontalOffset = centerX - nearest.x
        let verticalOffset   = centerY - nearest.y

        let horizontalOK = abs(horizontalOffset) < deadZoneFraction
        let verticalOK   = abs(verticalOffset)   < deadZoneFraction

        // Priority 3: well composed.
        if horizontalOK && verticalOK {
            return FramingSignal(subjectBox: box, hint: .goodFrame)
        }

        // Priority 4: correct only one axis.
        if horizontalOK {
            let hint: FramingHint = verticalOffset > 0 ? .nudgeUp : .nudgeDown
            return FramingSignal(subjectBox: box, hint: hint)
        }
        if verticalOK {
            let hint: FramingHint = horizontalOffset > 0 ? .nudgeLeft : .nudgeRight
            return FramingSignal(subjectBox: box, hint: hint)
        }

        // Both axes need correction — emit the nudge for the dominant axis.
        if abs(horizontalOffset) >= abs(verticalOffset) {
            let hint: FramingHint = horizontalOffset > 0 ? .nudgeLeft : .nudgeRight
            return FramingSignal(subjectBox: box, hint: hint)
        } else {
            let hint: FramingHint = verticalOffset > 0 ? .nudgeUp : .nudgeDown
            return FramingSignal(subjectBox: box, hint: hint)
        }
    }

    // MARK: - Private helpers

    /// Returns the rule-of-thirds intersection (UIKit coords) closest to `(x, y)`.
    private func nearestThirds(to x: Double, y: Double) -> (x: Double, y: Double) {
        // Four intersections of x ∈ {oneThird, twoThirds} × y ∈ {oneThird, twoThirds}.
        let oneThird  = Self.oneThird
        let twoThirds = Self.twoThirds

        let candidates: [(x: Double, y: Double)] = [
            (oneThird,  oneThird),
            (oneThird,  twoThirds),
            (twoThirds, oneThird),
            (twoThirds, twoThirds)
        ]

        var best     = candidates[0]
        var bestDist = hypot(x - best.x, y - best.y)

        for candidate in candidates.dropFirst() {
            let dist = hypot(x - candidate.x, y - candidate.y)
            if dist < bestDist {
                bestDist = dist
                best     = candidate
            }
        }
        return best
    }
}
