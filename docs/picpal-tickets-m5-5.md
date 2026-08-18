# PicPal — M5.5 Tickets (Reference Photo Mode)

**Companion to**: [picpal-build-order.md](picpal-build-order.md) · [picpal-reference-photo-prd.md](picpal-reference-photo-prd.md)
**Date**: 2026-08-11
**Platform**: iOS (Swift 6, SwiftUI, Vision, PHPickerViewController)
**Sizes**: S ≈ ≤0.5 day · M ≈ 1–2 days · L ≈ 3–5 days (rough, single dev)

> **Milestone target**: User picks a reference photo → sees it ghosted over the live camera → hears real-time coaching about what's different → ghost turns green when they've matched it. No new ML models; uses Vision on a still image plus the existing landmark pipeline.

## Locked decisions

1. **PHPickerViewController only** — no `UIImagePickerController`; no library access grant beyond the individual photo the user selects.
2. **ReferencePose extracted once on a background queue** — not per-frame. Vision runs on the reference still image at activation; result is stored as a `ReferencePose` struct.
3. **PoseDelta is pure arithmetic** — no new ML inference per frame. Comparison is keypoint geometry only.
4. **Two-image VLM calls bypass the M5 cache** — reference-mode calls carry a `referenceImage` and use `VLMPrompt.referenceMode`; they are never stored or retrieved from `VLMResponseCache`.
5. **Per-reference consent is session-scoped** — does not overwrite the user's global `VLMSettings.isOnDeviceOnly` preference. If user consents to the reference call, only reference-mode VLM calls are enabled for that session; standard aesthetic calls follow the global preference.
6. **Match threshold is named and constant** — `PoseDelta.defaultMatchThreshold: Float = 0.08` (normalized frame units). Tunable via `TuningSettings` in DEBUG.
7. **Ghost overlay opacity constants** — `ReferenceOverlay.defaultOpacity: Double = 0.30`, `ReferenceOverlay.matchOpacity: Double = 0.15`.

## Conventions (carried from M0–M4)

- Swift 6 strict concurrency; `@MainActor` for UI components; `@unchecked Sendable` + `OSAllocatedUnfairLock` for shared state.
- **Swift Testing only** (`import Testing`), ≥80% coverage on new logic.
- 300-line file limit; no magic numbers (named `static` constants).
- Tier-0 forwarding invariant: unchanged — `ReferenceCoach` is called inside the accumulator callback, after `CueEngine.process`, never inside a `CameraFrameDelegate` method.

## Execution order

```
M5.5-0 (ReferencePose + PoseDelta data types — pure, no deps)
  ↓
M5.5-1 (PHPickerViewController + ReferencePose extraction)
  ↓
M5.5-2 (ReferenceCoach: PoseDelta → Cue)        M5.5-3 (ReferenceOverlayView + match UI)
         ↓                                                ↓
M5.5-4 (two-image VLM + per-reference consent)
         ↓
M5.5-5 (ContentView wiring + integration)
```

M5.5-2 and M5.5-3 can be built in parallel after M5.5-1.

---

## M5.5-0 — ReferencePose + PoseDelta data types
**Size**: S · **Deps**: none

**Goal**: Define the two core data types used throughout Reference Photo Mode. Both are pure value types with no UIKit or Vision import — they work on normalized CGPoint/CGRect coordinates that Vision produces.

**File**: `picpal/Sources/Reference/ReferencePose.swift`

```swift
import Foundation

/// Keypoints and composition extracted from a reference still image.
/// All coordinates are in Vision's normalized coordinate space (origin bottom-left, y up).
/// Convert to UIKit (origin top-left, y down) before display comparisons.
public struct ReferencePose: Sendable {
    /// Body joint positions. Nil joints were not detected at sufficient confidence.
    public let bodyKeypoints: [String: CGPoint]  // VNHumanBodyPoseObservation.JointName.rawValue
    /// Face centroid in normalized coordinates. Nil if no face detected.
    public let faceCenter: CGPoint?
    /// Estimated face yaw in radians. Positive = turned right. Nil if no face detected.
    public let faceYaw: Float?
    /// Bounding box of the primary subject (union of body + face bounds).
    public let subjectBoundingBox: CGRect
    /// Horizontal center of subject, normalized 0–1 (0 = left edge).
    public let subjectCenterX: Float
    /// Vertical center of subject, normalized 0–1 (0 = bottom edge, Vision coords).
    public let subjectCenterY: Float
    /// Subject height as a fraction of the frame height (proxy for distance / zoom).
    public let subjectHeightFraction: Float
    /// Space above subject to top of frame, normalized.
    public let headroomFraction: Float
}
```

**File**: `picpal/Sources/Reference/PoseDelta.swift`

```swift
import Foundation

/// Per-frame difference between a ReferencePose and the live landmark output.
/// All fields are in normalized frame units; positive values indicate the live view
/// has too much of the named property relative to the reference.
public struct PoseDelta: Sendable {
    /// Subject is too far right in live view (+) or too far left (-).
    public let horizontalOffset: Float
    /// Subject is too high in live view (+) or too low (-).
    public let verticalOffset: Float
    /// Live view has more headroom than reference (+) or less (-).
    public let headroomDelta: Float
    /// Subject is smaller in live view than reference (+) → too far away; negative → too close.
    public let scaleDelta: Float
    /// Face yaw delta (radians). Positive = more turned-right in live view. Nil if no face in either.
    public let faceYawDelta: Float?

    /// Threshold below which each component is considered matched.
    public static let defaultMatchThreshold: Float = 0.08
    /// Threshold for scale (looser — framing distance is harder to match exactly).
    public static let defaultScaleMatchThreshold: Float = 0.15

    /// True when all components are within their thresholds.
    public var isWithinThreshold: Bool {
        abs(horizontalOffset) < Self.defaultMatchThreshold &&
        abs(verticalOffset) < Self.defaultMatchThreshold &&
        abs(headroomDelta) < Self.defaultMatchThreshold &&
        abs(scaleDelta) < Self.defaultScaleMatchThreshold &&
        (faceYawDelta.map { abs($0) < 0.15 } ?? true)
    }
}
```

**Acceptance criteria**

- [ ] `ReferencePose` and `PoseDelta` defined in a new `picpal/Sources/Reference/` directory.
- [ ] Both are `Sendable` structs with no UIKit, Vision, or AVFoundation imports — no framework coupling.
- [ ] `PoseDelta.isWithinThreshold` uses only named constants; no bare float literals.
- [ ] `ReferencePose.bodyKeypoints` uses `String` keys (raw values of `VNHumanBodyPoseObservation.JointName`) so the type does not import Vision.
- [ ] Unit tests: `PoseDeltaTests.swift` — `isWithinThreshold` true when all components < threshold, false when any component exceeds threshold, faceYawDelta nil is treated as matched.

---

## M5.5-1 — PHPickerViewController + ReferencePose extraction
**Size**: M · **Deps**: M5.5-0

**Goal**: Let the user pick a photo from their library; run Vision body pose + face analysis on the selected still image on a background queue; produce a `ReferencePose`.

**File**: `picpal/Sources/Reference/ReferenceSession.swift`

```swift
import UIKit
import Vision

/// Owns the active reference photo and its extracted pose.
/// Created when the user picks a reference; destroyed when dismissed.
@MainActor
final class ReferenceSession: ObservableObject {
    let image: UIImage
    @Published private(set) var pose: ReferencePose?
    @Published private(set) var isExtracting: Bool = false

    init(image: UIImage) {
        self.image = image
    }

    func extractPose() async {
        isExtracting = true
        defer { isExtracting = false }
        pose = await Task.detached(priority: .userInitiated) {
            ReferenceSession.runVision(on: image)
        }.value
    }

    private static func runVision(on image: UIImage) -> ReferencePose? {
        // Run VNDetectHumanBodyPoseRequest + VNDetectFaceRectanglesRequest
        // on image.cgImage. Compute subject bounding box, subjectCenterX/Y,
        // subjectHeightFraction, headroomFraction, faceYaw from face landmarks.
        // Return nil if no body detected.
    }
}
```

**File**: `picpal/Sources/Reference/ReferencePhotoPicker.swift`

A SwiftUI `View` wrapping `PHPickerViewController` via `UIViewControllerRepresentable`.

- Filter: `PHPickerFilter.images`, `selectionLimit: 1`.
- On selection: load as `UIImage` (full resolution is fine — Vision works on still; `FrameEncoder` resizes for VLM).
- On cancel: dismiss without creating a `ReferenceSession`.
- Callback: `onPick: (UIImage?) -> Void`.

**ContentView integration (minimal — wiring comes in M5.5-5)**

`ContentView` gains `@State private var showReferencePicker: Bool = false` and calls `ReferencePhotoPicker` from a `.sheet`. The session creation and pose extraction happen in M5.5-5.

**Acceptance criteria**

- [ ] `PHPickerViewController` is used (not `UIImagePickerController`).
- [ ] Selected image is delivered as `UIImage` via the `onPick` callback; picker sheet dismisses automatically.
- [ ] `ReferenceSession.extractPose()` runs Vision on a `Task.detached` background queue; `isExtracting` is `true` during extraction, `false` after.
- [ ] `extractPose()` sets `pose = nil` (not crash) when no body or face is detected in the reference photo.
- [ ] Body keypoints are stored as String raw values of `VNHumanBodyPoseObservation.JointName` (e.g. `"left_shoulder"`) — no Vision type leaks into `ReferencePose`.
- [ ] `subjectBoundingBox` is the union of the body observation's bounding box and the face bounding box (if detected). If only one is available, use that one.
- [ ] `headroomFraction` = distance from top of `subjectBoundingBox` to top of frame, in normalized coordinates.
- [ ] Unit tests: `ReferenceSessionTests.swift` — `extractPose()` completes within 500ms on a synthetic CGImage with a known body; `pose` is non-nil; nil returned for an image with no body.

---

## M5.5-2 — ReferenceCoach: PoseDelta → Cue
**Size**: M · **Deps**: M5.5-0

**Goal**: Stateless mapper from `PoseDelta` to coaching cues. Integrates into the existing `CueEngine` priority stack at `.bodyPositioning` priority. Silent when all components are within threshold.

**File**: `picpal/Sources/Reference/ReferenceCoach.swift`

```swift
import Foundation

/// Maps a PoseDelta to at most one coaching Cue.
/// Stateless — no retained state; the caller (ContentView) holds match confirmation state.
struct ReferenceCoach {

    /// Named constants for cue text strings.
    enum CueText {
        static let moveLeft         = "move them a bit to the left"
        static let moveRight        = "move them a bit to the right"
        static let tiltDown         = "tilt down slightly — they're a bit high in the reference"
        static let tiltUp           = "tilt up slightly — they're a bit low in the reference"
        static let moreHeadroom     = "leave a bit more space above their head"
        static let lessHeadroom     = "tighten up — less space above"
        static let stepCloser       = "step in a bit closer — the reference is tighter"
        static let stepBack         = "back up slightly — the reference has more space"
        static let faceCamera       = "have them turn back toward the camera"
        static let matched          = "nice — that looks like the reference shot"
    }

    /// Returns at most one cue for the most significant delta component.
    /// Returns nil when delta.isWithinThreshold (matched) or when no meaningful delta exists.
    func cue(from delta: PoseDelta, isNewMatch: Bool) -> Cue? {
        if isNewMatch {
            return Cue(text: CueText.matched, priority: .bodyPositioning, sourceTier: .tier05)
        }
        guard !delta.isWithinThreshold else { return nil }
        // Prioritize: face yaw > scale > horizontal > vertical > headroom
        // Return the cue for the largest magnitude delta component.
        // ...
    }
}
```

The priority ordering within `cue(from:)`: face yaw (most visible defect first) → scale (wrong distance is hard to fix without guidance) → horizontal position → vertical position → headroom.

**ContentView wiring (preliminary — full integration in M5.5-5)**

After `CueEngine.process(frame:)` in the `SignalFrameAccumulator` callback: if `referenceSession?.pose != nil` and a `poseDelta` is available, call `ReferenceCoach().cue(from: poseDelta, isNewMatch: isNewMatch)`. If non-nil, feed into the cue engine at `.bodyPositioning` priority — this replaces (not stacks with) the standard body-positioning cue for that frame when reference mode is active.

**Match confirmation state** (`ContentView`):
- `@State private var referenceMatchCount: Int = 0` — increments each frame `delta.isWithinThreshold`, resets when not.
- When `referenceMatchCount >= ReferenceOverlay.matchConfirmationFrames` (named constant: `8`): set `isReferenceMatched = true`.

**Acceptance criteria**

- [ ] `ReferenceCoach.cue(from:isNewMatch:)` returns `nil` when `delta.isWithinThreshold`.
- [ ] Returns exactly one cue — the highest-priority non-matched component.
- [ ] `isNewMatch == true` overrides all delta cues and returns the `matched` cue text.
- [ ] All cue text strings are named constants in `ReferenceCoach.CueText`; no bare string literals.
- [ ] `CuePriority.bodyPositioning` is used (same as M2 body cues) — reference cues do not invent a new priority level.
- [ ] Unit tests: `ReferenceCoachTests.swift` — nil returned when within threshold, correct cue returned for each dominant delta component, `matched` cue returned when `isNewMatch = true`.

---

## M5.5-3 — ReferenceOverlayView + match confirmation
**Size**: M · **Deps**: M5.5-1

**Goal**: SwiftUI view that composites the reference image over the live camera preview at 30% opacity, tints green and fades when a match is confirmed, and provides dismiss controls.

**File**: `picpal/Sources/UI/ReferenceOverlayView.swift`

```swift
import SwiftUI

struct ReferenceOverlayView: View {
    let image: UIImage
    let isMatched: Bool
    let isExtracting: Bool
    let onDismiss: () -> Void

    private enum Layout {
        static let defaultOpacity: Double = 0.30
        static let matchOpacity: Double = 0.15
        static let matchTint: Color = .green.opacity(0.35)
        static let dismissButtonSize: CGFloat = 32
        static let dismissButtonPadding: CGFloat = 16
        static let extractingOpacity: Double = 0.15
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(currentOpacity)
                .overlay(matchTintOverlay)
                .animation(.easeInOut(duration: 0.4), value: isMatched)
                .gesture(swipeToDismiss)

            dismissButton
        }
    }

    private var currentOpacity: Double {
        if isExtracting { return Layout.extractingOpacity }
        return isMatched ? Layout.matchOpacity : Layout.defaultOpacity
    }

    private var matchTintOverlay: some View {
        isMatched ? Layout.matchTint : Color.clear
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: Layout.dismissButtonSize))
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(Layout.dismissButtonPadding)
    }

    private var swipeToDismiss: some Gesture {
        DragGesture(minimumDistance: 40)
            .onEnded { value in
                if value.translation.height > 0 { onDismiss() }
            }
    }
}
```

The overlay is placed in `ContentView`'s ZStack between the camera preview layer and the debug overlay — above the camera, below the debug overlay and consent sheet.

An "extracting" loading state (`isExtracting == true`) renders the overlay at 15% opacity and shows a `ProgressView` in the center, indicating Vision is running. This state lasts <500ms on A15 Bionic.

**Acceptance criteria**

- [ ] `ReferenceOverlayView` is shown when `referenceSession != nil`; hidden otherwise.
- [ ] Image is displayed aspect-fit, not stretched or cropped.
- [ ] Default opacity is `Layout.defaultOpacity = 0.30`; matched opacity is `Layout.matchOpacity = 0.15`.
- [ ] When `isMatched` transitions to `true`: opacity animates to `matchOpacity`; green tint overlay appears — using `.animation(.easeInOut(duration: 0.4))`.
- [ ] X button tap calls `onDismiss`. Swipe-down (translation.height > 0) also calls `onDismiss`.
- [ ] When `isExtracting == true`: overlay renders at 15% opacity with a centered `ProgressView`.
- [ ] All numeric literals are replaced by `Layout` enum constants.
- [ ] No bare string literals for SF Symbol names (use `let xmarkSymbol = "xmark.circle.fill"`).
- [ ] View renders correctly in both light and dark mode (white X button is visible against any reference image).
- [ ] **No unit tests required** for pure SwiftUI view presentation — cover `isWithinThreshold` logic in `ReferenceCoach` and `PoseDelta` tests (already in M5.5-0/M5.5-2).

---

## M5.5-4 — Two-image VLM + per-reference consent
**Size**: M · **Deps**: M5.5-1

**Goal**: Extend the VLM call path to accept a reference image alongside the live frame; add a session-scoped consent prompt that gates reference-image cloud calls independently of the global `VLMSettings.isOnDeviceOnly` preference.

### FrameEncoder extension

Read `picpal/Sources/VLM/FrameEncoder.swift` before editing.

Add a new method (do not change the existing signature):

```swift
/// Encodes a live frame alongside a reference image for VLM comparison.
/// Reference image is resized to the same target dimension as the live frame.
/// Returns nil if either pixel buffer cannot be processed.
static func encode(pixelBuffer: CVPixelBuffer, referenceImage: UIImage) -> (liveData: Data, referenceData: Data)?
```

Both images are encoded at `FrameEncoder.targetDimension` and `FrameEncoder.jpegQuality` — no new constants needed.

### VLMPrompt extension

Read `picpal/Sources/VLM/VLMPrompt.swift`. Add a new static property:

```swift
static let referenceMode: String = """
You are helping a photographer replicate a reference shot. \
I'll show you the reference photo first, then the current live view from their phone. \
Describe one specific, concrete change that would bring the live view closer to the reference \
in terms of framing, subject placement, or lighting. \
Be brief (one sentence), action-first, and warm. \
If they've nearly matched it, say so.
"""
```

### VLMOrchestrator extension

`VLMOrchestrator` gains an optional reference image dependency. The cleanest approach: add `var referenceImage: UIImage?` as a settable property (not in `init` — reference mode can be toggled during a session). When non-nil:
- Skip the M5 cache lookup (`responseCache` is not consulted).
- Call `FrameEncoder.encode(pixelBuffer:referenceImage:)`.
- Use `VLMPrompt.referenceMode` as the system prompt.
- Use a separate `referenceModeConsented: Bool` flag (see below) to gate cloud calls.

### Per-reference consent

**File**: `picpal/Sources/UI/ReferenceConsentAlert.swift`

A simple SwiftUI `.alert` (not a full-screen sheet) shown once per session when:
- User picks a reference photo AND
- Global cloud VLM is enabled (`!VLMSettings.shared.isOnDeviceOnly`) AND
- `referenceCloudConsentGiven == false` (session-scoped `Bool` in `ContentView`, starts `false`)

Alert title: `"Send reference to cloud?"`
Alert message: `"To help match your shot, the reference photo will be sent to the coaching service along with your live camera frames."`
Buttons:
- `"Enable for this session"` → sets `referenceCloudConsentGiven = true`; sets `vlmOrchestrator.referenceModeConsented = true`
- `"On-device only"` → sets `referenceCloudConsentGiven = true` (prevents re-prompting); does NOT set `vlmOrchestrator.referenceModeConsented`; reference mode runs landmarks-only

`referenceCloudConsentGiven` is `@State` in `ContentView` — session-scoped, resets to `false` when app relaunches. It is not persisted to UserDefaults (no overwrite of global preference).

**Acceptance criteria**

- [ ] `FrameEncoder.encode(pixelBuffer:referenceImage:)` produces two JPEG `Data` values; both are sized within `FrameEncoder.targetDimension` bounds (asserted in tests).
- [ ] `VLMPrompt.referenceMode` is a named constant (no inline string in the call path).
- [ ] When `vlmOrchestrator.referenceImage != nil`, the M5 cache is bypassed (verified by unit test that mock client receives exactly 1 call per gate pass, regardless of cache state).
- [ ] When `vlmOrchestrator.referenceModeConsented == false`, reference-image VLM calls are suppressed even if global cloud consent is given. Landmark-based reference coaching still works.
- [ ] Reference consent alert appears exactly once per session — not on every reference pick after the first consent choice.
- [ ] Tapping "On-device only" does not write to `VLMSettings.isOnDeviceOnly`; global cloud preference is unchanged.
- [ ] Reference photos are never written to disk or logged by the proxy. (Verify proxy logging code does not log request body when reference mode is active.)
- [ ] Unit tests: `ReferenceVLMTests.swift` — two-image encoding produces two non-empty Data values; consent gate blocks call when `referenceModeConsented = false`; cache bypass confirmed.

---

## M5.5-5 — ContentView wiring + integration
**Size**: M · **Deps**: M5.5-2, M5.5-3, M5.5-4

**Goal**: Wire all reference photo components into `ContentView` and `ContentView+Session`. Add the reference mode button to the camera UI; connect picker → session → extraction → coaching → overlay → match feedback.

### ContentView additions (read `ContentView.swift` and `ContentView+Session.swift` before editing)

New `@State` properties:

```swift
@State private var showReferencePicker: Bool = false
@State private var referenceSession: ReferenceSession?
@State private var referenceMatchCount: Int = 0
@State private var isReferenceMatched: Bool = false
@State private var referenceCloudConsentGiven: Bool = false
```

Named constant (alongside existing button constants in `ContentView.swift`):
```swift
private let referenceMatchConfirmationFrames: Int = 8
```

**UI additions in `body`**:

1. Reference mode button — placed alongside the existing settings button (top-right cluster). Uses SF Symbol `"photo.on.rectangle"`. Tapping sets `showReferencePicker = true`.
2. `.sheet(isPresented: $showReferencePicker) { ReferencePhotoPicker { image in ... } }` — on image selection: create `ReferenceSession(image:)`, assign to `referenceSession`, call `Task { await referenceSession?.extractPose() }`.
3. `ReferenceOverlayView` in the ZStack when `referenceSession != nil`.
4. Reference consent alert (`.alert`) triggered when `referenceSession != nil && !referenceCloudConsentGiven && !VLMSettings.shared.isOnDeviceOnly`.

**Coaching integration** (in `ContentView+Session` accumulator callback, after `CueEngine.process`):

```swift
if let session = referenceSession, let pose = session.pose {
    let delta = computePoseDelta(referencePose: pose, liveLandmarks: currentBodySignal)
    let newMatch = delta.isWithinThreshold
    if newMatch {
        referenceMatchCount += 1
    } else {
        referenceMatchCount = 0
        isReferenceMatched = false
    }
    if referenceMatchCount >= referenceMatchConfirmationFrames && !isReferenceMatched {
        isReferenceMatched = true
        // ReferenceCoach.cue(from: delta, isNewMatch: true) will fire on next frame
    }
    if let cue = ReferenceCoach().cue(from: delta, isNewMatch: isReferenceMatched) {
        coach.speak(cue)
    }
}
```

`computePoseDelta(referencePose:liveLandmarks:)` is a private method on `ContentView+Session` that converts `BodySignal` keypoints to `PoseDelta` against `ReferencePose`. This is arithmetic on normalized coordinates.

**VLMOrchestrator update** (in `wireUp` and on `referenceSession` change):

```swift
vlmOrchestrator?.referenceImage = referenceSession?.image
```

**Dismiss flow**: `onDismiss` sets `referenceSession = nil`, `isReferenceMatched = false`, `referenceMatchCount = 0`, `vlmOrchestrator?.referenceImage = nil`.

**Background handling**: add `referenceSession = nil` (and nil out orchestrator reference image) in the `.background` case of `handleScenePhaseChange` — reference mode does not persist across background/foreground cycles.

**Acceptance criteria**

- [ ] Reference mode button visible in camera UI; tapping opens the PHPickerViewController sheet.
- [ ] Selecting a photo creates a `ReferenceSession`, starts extraction; `ReferenceOverlayView` appears immediately with extracting state (15% opacity + `ProgressView`).
- [ ] After `extractPose()` completes (<500ms): overlay updates to 30% opacity; coaching begins.
- [ ] When no body is detected in the reference photo: reference mode remains active (overlay shown) but `ReferenceCoach` emits no cues (`pose == nil` guard).
- [ ] `referenceMatchCount` increments each frame within threshold; resets when outside threshold.
- [ ] After `referenceMatchConfirmationFrames` consecutive matching frames: `isReferenceMatched = true`, `ReferenceOverlayView` transitions to green-tint/faded state, and the match cue fires once.
- [ ] Match cue fires at most once per match event (guarded by `isReferenceMatched` state).
- [ ] Dismissing (X button or swipe) clears all reference state and sets `vlmOrchestrator?.referenceImage = nil`.
- [ ] Reference consent alert appears once per session when conditions are met; subsequent picks in the same session skip the alert.
- [ ] Reference mode is cleared on app background.
- [ ] `referenceMatchConfirmationFrames = 8` is a named constant; no bare `8`.
- [ ] Integration test: `ReferenceIntegrationTests.swift` — with a mock `ReferenceSession` (pose set manually), simulate 8 consecutive within-threshold frames and verify `isReferenceMatched` becomes true and the match cue fires exactly once.
