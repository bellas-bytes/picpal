# Selfie and orientation implementation plan

> **For agentic workers:** Use subagent-driven-development and independent review. Preserve all existing changes; no commits or reset.

**Goal:** Recognize cropped selfie subjects and reference image format; support consistent landscape/portrait capture.

**Architecture:** Explicit face/person evidence domains and shared capture orientation; existing reference coordinator remains the authority for matching and capture.

**Tech Stack:** Swift 6, Vision, MediaPipe, AVFoundation, SwiftUI, iOS 17+.

**Spec:** `docs/superpowers/specs/2026-09-24-selfie-orientation-design.md`

## Constraints and review focus

- On-device face evidence; no new upload/permission.
- No matching face bounds against body bounds or confident pose from absent joints.
- Portrait/landscape means upright displayed image dimensions, not an unverifiable historic camera position.
- Preview/analysis/photo orientation agree; preserve front-camera unmirror/inference/display remap.
- Flat orientation, detector failures, multiple people, reference replacement, flips and rotation cannot retain stale capture-ready evidence.
- Source baseline `/tmp/picpal-selfie-baseline-20260924.tar.gz` includes prior work.

## Task 1: Selfie evidence (lead worker)

- [ ] Write failing ReferenceSession/comparator/coordinator integration tests for a single face with no body, absent face, ambiguous people, body tracker failure with valid face, and incompatible framing domains. Synthetic rectangle injection should exercise real selection logic.
- [ ] Add explicit optional face bounds and framing domain to ReferencePose/LivePoseObservation/LocalReferenceEvidence as needed; preserve existing initializers with defaults.
- [ ] Detect faces before the reference no-body guard; produce a usable face-domain reference. Live monitor detects face independently and does not erase it when body inference fails. Keep full-person rectangles for body references.
- [ ] Compare same-domain boxes; make close-up captions speak about face framing while leaving unseen body pose unknown. Ensure CameraScreenModel's no-reference-pose fallback recognizes visible face presence.
- [ ] Run focused red then green suites. Coordinate with Task 2 on shared geometry/ContentView+Reference interfaces.

## Task 2: Format and capture orientation (delegated bounded worker)

- [ ] Write failing orientation/aspect-fit tests for rotated and mirrored non-square images, both landscape directions, unknown/flat retention, landscape level signal and matching displayed reference bounds.
- [ ] Implement shared camera orientation state; camera/session connection, preview and photo use it. Update supported orientations and adaptive layout. Invalidate geometry and stop auto capture/audio on changes. Use real preview aspect ratio in syncReferenceAnalysis.
- [ ] Add reference-format indication based on normalized dimensions; apply aspect-fit geometry to comparator to match overlay. Do not use full-image box coordinates where an aspect-fit image is letterboxed.
- [ ] Read current official Apple orientation guidance if needed; avoid hardcoded sensor rotation angles. Preserve existing portrait and tap-to-focus behavior.
- [ ] Run targeted tests and communicate changed interfaces to lead; no simultaneous Xcode jobs using shared DerivedData.

## Task 3: Integration, review and device update (lead + root)

- [ ] Run full tests using `xcodebuild test -project PicPal.xcodeproj -scheme PicPal -destination 'platform=iOS Simulator,id=E74AD787-AAEC-4AEB-9AA7-5E65864D4023' -derivedDataPath /tmp/picpal-architecture-derived CODE_SIGNING_ALLOWED=NO -resultBundlePath /tmp/picpal-selfie-final.xcresult` with required escalation.
- [ ] Independent baseline-scoped review, fix confirmed issues, verify app layout in portrait/landscape when simulator tooling permits.
- [ ] Update docs/reference-pose-tracking.md with selfie/format behavior and verification limits. Signed device build, install and launch com.picpal.app on device A2FE2617-DFFF-549D-BBC2-04EE27BFF556. Root performs deployment after checks.

Execution assumes landscape capture (recommended option in optional question); user may steer that preference while work proceeds. No routine approval pauses under existing autonomous instruction.
