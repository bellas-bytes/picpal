/// Blur / sharpness assessment for a single camera frame.
///
/// Produced by `BlurProcessor` for each analyzed frame and surfaced through
/// `SignalFrame.blur`. A higher `sharpnessScore` means a sharper image.
public struct BlurSignal: Sendable, Equatable {

    /// Laplacian-variance sharpness score. Higher = sharper.
    ///
    /// Typical range: < 50 = blurry, 50–200 = moderate, > 200 = sharp.
    /// These are guidance values; the threshold constant governs classification.
    public let sharpnessScore: Double

    /// Whether the frame is classified as blurry.
    ///
    /// `true` when `sharpnessScore` falls below the `BlurProcessor.blurThreshold`.
    public let isBlurry: Bool

    /// Creates a `BlurSignal`.
    ///
    /// - Parameters:
    ///   - sharpnessScore: Laplacian-variance score; higher values indicate a sharper frame.
    ///   - isBlurry: `true` when the score falls below the configured blur threshold.
    public init(sharpnessScore: Double, isBlurry: Bool) {
        self.sharpnessScore = sharpnessScore
        self.isBlurry = isBlurry
    }
}
