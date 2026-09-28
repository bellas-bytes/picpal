# Photo Camera Implementation Plan

> **For agentic workers:** Use the dispatching-parallel-agents workflow for the independent capture and coaching modules; parent integrates and reviews the complete flow.

**Goal:** Take and save still photographs manually or once stable person framing is ready, with familiar camera controls and reference selection from Photos.

**Architecture:** Retain the AVFoundation camera and analysis pipeline. Add full-resolution photo output and a Photos writer, independent fresh person observations and a pure readiness gate, and a SwiftUI camera surface with controls outside the preview. Auto-capture is explicit, requires fresh sustained readiness, and disarms after one request.

**Tech Stack:** Swift 6, SwiftUI, AVFoundation, Vision, Photos, PhotosUI; iOS 17+.

**Spec:** `docs/camera-product-direction.md` plus user approval of shutter/auto-capture and Apple Camera-like bottom bar.

## Constraints

- Still photos only; video, Live Photos, and portrait effects excluded.
- Bottom-right Photos opens the system image picker for reference selection.
- Preserve uncommitted fixes, speech, and forgiving tilt thresholds.
- No claims of perfect photography or exact distance from a bounding box.
- Tests/builds run sequentially against shared DerivedData. Only parent regenerates Xcode project and runs Xcode.

## Capture and saving

Files: CameraCapture and camera extensions; new photo delegate and Photos writer; camera tests.
- [x] Add async `capturePhoto(flashMode:) -> Data` with retained delegates, a single-flight guard, and completion on success/error.
- [x] Add capability-checked continuous focus, exposure and white balance; bounded smooth zoom.
- [x] Save original photo data with add-only Photos permission. Denial and save errors must reach UI; preserve captured data for retry.
- [x] Fix active device bookkeeping on camera switch; preserve portrait capture orientation.
- [x] Verify capture-unavailable and busy/error behavior and build against real SDK.

## Subject/readiness

Files: new SubjectObservationMonitor, PersonShotCoach and AutoCaptureGate; dedicated tests.
- [x] Detect fresh person rectangles on a bounded cadence independently of the old change-only gate. Separate absence from analyzer failure.
- [x] Assess person presence, relative distance for full-body/closer-portrait, clipping, usable placement, tilt, exposure and stability.
- [x] Require a continuous ready interval with fresh observations. Reset on loss/staleness/motion; trigger once per explicit arming.
- [x] Write deterministic tests for absence, distance, stale input, interrupted readiness, and one-shot capture.

## UI/integration

Files: ContentView, session wiring, focused camera-control views/model, project.yml/Info.plist.
- [x] Provide black camera chrome, a large white shutter centered in bottom bar, camera flip left, reference Photos right, shot-style selection and Auto toggle.
- [x] Show one current subject-aware caption and readiness/progress. Keep diagnostics/settings accessible without obscuring shutter or reference dismissal.
- [x] Manual shutter and automatic trigger share capture/save operation; disable duplicates and show saving/saved/error feedback.
- [x] Reset auto-capture during sheets/background/camera or style changes; never capture behind a picker or consent screen.
- [x] Support zoom/flash/timer controls and conservative auto camera assistance without fighting user distance changes.
- [x] Verify non-camera simulator UI and picker flow, run all tests, review changes, build/sign/install on the paired phone.

Validation: 691 tests passed; code review approved; simulator Photos selection and auto-capture interruption verified; device build signed and installed. Real-world capture quality and optical readiness still require the phone camera.
