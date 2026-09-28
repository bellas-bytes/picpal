# Reference pose tracker implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development to implement and review this work. Preserve the existing dirty tree and do not commit unrelated work.

**Goal:** Replace generic reference-pose feedback with measured on-device limb corrections.

**Architecture:** MediaPipe Pose Landmarker shares a coordinate adapter between image reference extraction and bounded live video tracking. Existing comparator/coordinator produces specific supported instructions; Vision remains a graceful initialization fallback.

**Tech Stack:** Swift 6, iOS 17+, existing MediaPipeTasksVision 0.10.21 wrapper, Vision, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-24-pose-tracker-design.md`

## Global constraints

- Same reference/live joint identity, bottom-left image coordinates; retain aspect and mirroring correction.
- On-device only for tracking; preserve consent and cloud/capture policy.
- Serial/drop-if-busy inference; preserve current 3 Hz observation cadence.
- Missing/unreliable joints cannot become positive match evidence.
- No commits/deployment; baseline `/tmp/picpal-pose-baseline-20260924.tar.gz` includes all previous work.

## Review focus

1. Mirrored camera and rotated reference photos must not reverse anatomical limb instructions.
2. Multiple people must not merge skeletons or silently choose a matching bystander.
3. Occluded, nonfinite or crop-edge joints must not generate confident corrections.
4. Camera/geometry changes must invalidate old observations and reset video tracking.
5. Missing model/runtime failure must degrade safely; bundled real SDK must initialize.

## Task 1: Pose SDK and reference guidance (one integrated deliverable)

Files: add `picpal/Sources/Landmarks/ReferenceBodyTracker.swift` (or similarly scoped adapter), modify `SubjectObservationMonitor.swift`, `ReferenceSession.swift`, `ReferenceLocalComparator.swift`, `ReferenceCoachingCoordinator.swift`, associated tests; add `picpal/Resources/Models/pose_landmarker_lite.task` with provenance; register source/resource in `PicPal.xcodeproj/project.pbxproj` preserving existing entries. Add backend identity metadata only if needed to prevent incompatible comparisons.

- [ ] Add failing synthetic skeleton tests in ReferenceLocalComparatorTests: target bent left elbow vs straight live elbow yields subject bend-left-elbow instruction; reversed geometry yields straighten. Repeat for knees, arm horizontal placement and stance. Preserve existing raise/lower/lean tests. Assert anatomical sides survive mirrored pixels and low-confidence critical joints suppress advice.
- [ ] Add adapter tests with normalized MediaPipe points: index 11 maps leftShoulder, 12 rightShoulder, 13/14 elbows, 15/16 wrists, 23/24 hips, 25/26 knees, 27/28 ankles; `(x:0.2,y:0.3)` becomes `(0.2,0.7)`. Missing/nonfinite confidence and out-of-bounds values remain unsupported. Assert multi-person evidence cannot be associated as a single subject.
- [ ] Run focused tests and capture the failing evidence before production changes.
- [ ] Implement shared pose adapter and SDK wrapper using installed headers. Initialize image/video instances off-main with numPoses=2 and confidence gates. Use monotonically increasing video timestamps; reset on geometry changes. Compare reference and live joints in the same convention; preserve image orientation in MPImage.
- [ ] Wire tracker into reference extraction and existing live observation queue. Keep Vision rectangles and single-subject torso association; skip duplicate Vision body pose when MediaPipe succeeds. Runtime failure returns unavailable evidence rather than fabricated pose. Exercise actual bundled model initialization and a blank image/video inference safely in a simulator test where supported.
- [ ] Implement angle/position differences after framing checks with deterministic correction priority and existing temporal coordinator stability. Use explicit threshold constants and confidence gates. Caption examples: `Ask them to bend their left elbow more`, `Ask them to straighten their right knee slightly`, `Ask them to bring their feet closer together`. Never infer depth from 2D displacement.
- [ ] Add integration test confirming joint mismatch becomes visible reference caption; local-only aligned/unknown states are accurately described without full-match claims.
- [ ] Run focused suites then full command below. Inspect result summary and verify model inclusion. Document source URL/checksum, fallback and physical-device limitations in `docs/reference-pose-tracking.md` and concise README update.
- [ ] Independent task/final review of integrated implementation and fixes. Report verified improvements and remaining device checks.

Test command (run sequentially with same DerivedData):

```sh
xcodebuild test -project PicPal.xcodeproj -scheme PicPal -destination 'platform=iOS Simulator,id=E74AD787-AAEC-4AEB-9AA7-5E65864D4023' -derivedDataPath /tmp/picpal-architecture-derived CODE_SIGNING_ALLOWED=NO -resultBundlePath /tmp/picpal-pose-final.xcresult
```

Focused command appends `-only-testing:PicPalTests/ReferenceLocalComparatorTests` and the tracker/coordinator/integration suites, without reusing a result bundle path. Xcode/simulator access requires escalation. SDK headers are under `/tmp/picpal-architecture-derived/SourcePackages/checkouts/SwiftTasksVision/Dependencies/MediaPipeTasksVision.xcframework`.

## Execution record

- Design/plan created from inspected production flows. Autonomous delegated implementation follows the user's established workflow.
- Baseline: previous full Swift suite 749 tests passed, plus 16 follow-up assertions; no Swift product changes since that run. Snapshot preserved before this feature.
- Added regression tests first: initial red run executed 37 tests with expected missing tracker/cue/caption failures (`/tmp/picpal-pose-red.xcresult`).
- Implemented shared MediaPipe tracker, NV12-to-BGRA conversion, reference orientation normalization, conservative association/confidence filtering, backend identity, concrete limb/stance corrections and meaningful local-only captions. Model/source/tests registered without regenerating the existing project.
- Focused green run passed 53 tests in 4 suites (`/tmp/picpal-pose-green2.xcresult`), including real bundled-model inference.
- Review identified need for an explicit mirrored camera anatomical contract. New asymmetric pixel/landmark test failed as expected in `/tmp/picpal-pose-mirror-red2.xcresult`; fixed by unmirroring before MediaPipe/Vision pose inference and reflecting positions back without swapping joint keys. The first individual-test filter selected zero tests and was replaced with a suite-level run; that empty run was not treated as verification.
- Full final suite passed 762 tests in 86 suites (`/tmp/picpal-pose-final.xcresult`, `/tmp/picpal-pose-final.log`). Actual model image/video/NV12 inference and mirrored regression passed. Bundle model SHA matched pinned source. Independent review approved the integrated change with no findings (`docs/reference-pose-tracking-review.md`). Physical-device validation remains outstanding as documented; no commits or deployment performed.
