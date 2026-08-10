/// Placeholder type for the blur signal — replaced in M1-2.
///
/// M1-2 will provide a full implementation with a Laplacian sharpness score
/// and a `isBlurry` state. This stub exists so `SignalFrame` compiles in M1-1.
public struct BlurSignal: Sendable, Equatable {}
