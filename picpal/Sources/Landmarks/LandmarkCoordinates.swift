import CoreGraphics

// MARK: - Coordinate systems

/// Unified coordinate-conversion helpers that normalise landmark points from
/// both Vision and MediaPipe into the app's UIKit top-left convention.
///
/// ## Coordinate system reference
///
/// | Source     | Origin      | Y direction       |
/// |------------|-------------|-------------------|
/// | Vision     | bottom-left | increases upward  |
/// | MediaPipe  | top-left    | increases downward|
/// | App (UIKit)| top-left    | increases downward|
///
/// All inputs and outputs are **normalised** — coordinates in 0.0–1.0 for
/// each axis, independent of pixel dimensions. Scale to points/pixels only
/// at the rendering layer.
///
/// ## Usage
///
/// ```swift
/// // Vision landmark point → UIKit
/// let uiPt = LandmarkCoordinates.visionPointToUIKit(vnPoint)
///
/// // MediaPipe landmark point → UIKit (validated pass-through)
/// let uiPt = LandmarkCoordinates.mediapipePointToUIKit(mpPoint)
/// ```
public enum LandmarkCoordinates {

    // MARK: - Constants

    private enum Axis {
        /// Normalised maximum along any axis in UIKit/MediaPipe space.
        static let normalizedMax: CGFloat = 1.0
    }

    // MARK: - Vision → UIKit

    /// Converts a **Vision-normalised point** (origin bottom-left, Y increases
    /// upward) to a **UIKit-normalised point** (origin top-left, Y increases
    /// downward).
    ///
    /// The Y axis is flipped: `uiY = 1 − visionY`.
    ///
    /// - Parameter point: A `CGPoint` in Vision normalised space.
    /// - Returns: An equivalent `CGPoint` in UIKit normalised space.
    public static func visionPointToUIKit(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: Axis.normalizedMax - point.y)
    }

    /// Converts a **Vision-normalised rectangle** (origin bottom-left, Y
    /// increases upward) to a **UIKit-normalised rectangle** (origin top-left,
    /// Y increases downward).
    ///
    /// This mirrors the behaviour of `visionRectToSwiftUI(_:in:)` in
    /// `GuidesOverlayView.swift`, but returns a normalised rect (no scaling).
    ///
    /// - Parameter rect: A `CGRect` in Vision normalised space.
    /// - Returns: An equivalent `CGRect` in UIKit normalised space.
    public static func visionRectToUIKit(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: Axis.normalizedMax - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    // MARK: - MediaPipe → UIKit

    /// Returns a **MediaPipe-normalised point** in UIKit-normalised space.
    ///
    /// MediaPipe and UIKit share the same convention — top-left origin, Y
    /// increases downward — so this is a semantically validated pass-through.
    /// Call it explicitly rather than skipping the layer: the call site
    /// documents where the coordinate came from and makes future convention
    /// changes easier to find.
    ///
    /// - Parameter point: A `CGPoint` in MediaPipe normalised space.
    /// - Returns: The same `CGPoint` in UIKit normalised space.
    public static func mediapipePointToUIKit(_ point: CGPoint) -> CGPoint {
        // MediaPipe top-left origin matches UIKit — no transform needed.
        point
    }

    /// Returns a **MediaPipe-normalised rectangle** in UIKit-normalised space.
    ///
    /// Same convention as UIKit; validated pass-through.
    ///
    /// - Parameter rect: A `CGRect` in MediaPipe normalised space.
    /// - Returns: The same `CGRect` in UIKit normalised space.
    public static func mediapipeRectToUIKit(_ rect: CGRect) -> CGRect {
        // MediaPipe top-left origin matches UIKit — no transform needed.
        rect
    }
}
