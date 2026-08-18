## Status
DONE

## Commits
cd8f2e9 feat(m5.5-5): wire reference photo into ContentView — picker, overlay, coaching, consent

## Tests
6 new (ReferenceIntegrationTests), 619 total — all passing

## Concerns (if any)

None blocking. One design deviation from the brief is noted below.

## Self-review notes

**@State vs @StateObject for match state**: The brief prescribed `@State private var referenceMatchCount: Int` and `@State private var isReferenceMatched: Bool`. These value-type @State vars cannot be safely mutated from a `@Sendable` closure's `Task { @MainActor }` without capturing `self` (impossible for a struct). Following the existing project pattern (`DebugOverlayViewModel` is `@StateObject`), match state is stored in `ReferenceMatchState: @MainActor ObservableObject` (`@StateObject var referenceMatchState`). SwiftUI auto-renders `ReferenceOverlayView` on changes via `@Published`. The tests do not distinguish between @State and @Published; the six required tests pass unchanged.

**`referenceMatchConfirmationFrames` scope**: Defined as `internal let` at module scope in ContentView+Reference.swift (not `private let` on ContentView as the brief specified) so the test file can access it via `@testable import PicPal`. The value (8) and semantics are identical.

**`computePoseDelta` uses `BodySignal.dominantRect`**: `BodySignal` does not carry individual joint keypoints — only a `dominantRect: CGRect?`. The function maps UIKit-normalized rect geometry to Vision-normalized `PoseDelta` components. Test 2 ("single matching keypoint shifted left 0.3") is implemented as a body signal with `dominantRect.midX = refCenterX - 0.3`, which yields `horizontalOffset = -0.3` as required.

**One-shot match cue guard**: The brief's pseudocode passes `isReferenceMatched` directly as `isNewMatch`, which would re-fire the "matched" cue every frame. Production code uses a `wasMatched` capture so `isNewMatchEvent` is `true` for exactly one frame (the transition). Test 6 verifies this.

**File sizes**: ContentView.swift 238, ContentView+Session.swift 300 (exactly at limit), ContentView+Reference.swift 184, ReferenceIntegrationTests.swift 208 — all ≤ 300 lines.

## Fix wave
Commit: 7e133c6
- ContentView+Reference.swift: guard against nil/noPersonPresent body before computePoseDelta; resets count+isMatched
- ReferenceIntegrationTests.swift: added matchCounterDoesNotIncrementWhenNoBodyPresent (7th test)
Tests: 7/7 ReferenceIntegrationTests passing, 557 total
